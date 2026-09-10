#!/usr/bin/env python3
"""Convert a mission and its assets into the remake's cache.  See docs/92 §10.1.

The conversion itself is ``inclib.convert``; the transactional publish is
``inclib.cache``.  This is the CLI, and the place the exit criteria of
``docs/92`` §10.4 are mechanised.

Usage::

    python3 tools/remake_convert.py gog_incubation -o ~/Library/.../caches
    python3 tools/remake_convert.py gog_incubation --check
    python3 tools/remake_convert.py --check-cache
    python3 tools/remake_convert.py gog_incubation --dev-fixtures godot/generated

``--check`` runs the whole pipeline twice into two staging directories and
requires the inventories to be **byte-identical**, then diffs the emitted map
against ``lev_parse.as_dict`` -- which is used as an *oracle*, not as an
emitter: the new document carries what ``as_dict`` drops (the scene's clones,
the lattice prototype by name, the marker, the four effect bytes).

``--check-cache`` exercises the failure modes on a temporary directory: a
partial cache is refused, and a valid cache survives an update that dies
halfway.

Neither writes anything into the game installation, and the installation is the
only thing read (``docs/92`` §8).  In the first slice the converter is a CLI
rather than something the game launches: ``docs/92`` §9 defers the Python
packaging, and §10.1 only asks that the converter be pointed at an installation.
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import multiprocessing
import shutil
import struct
import sys
import tempfile
import time
import zlib
from pathlib import Path
from types import SimpleNamespace
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import interaction_tables  # noqa: E402
import lev_parse  # noqa: E402
import seq_parse  # noqa: E402
from inclib import cache as cachemod  # noqa: E402
from inclib.check import Checker  # noqa: E402
from inclib import charisma as chamod  # noqa: E402
from inclib import charisma_tables as chatables  # noqa: E402
from inclib import convert as convertmod  # noqa: E402
from inclib.convert import (ConvertError, animation_path,  # noqa: E402
                            convert, mission_path)
from inclib import sound as soundmod  # noqa: E402
from inclib.lev import load_lev  # noqa: E402
from inclib import prototyp as protomod  # noqa: E402
from inclib.binio import ParseError  # noqa: E402

LOG = logging.getLogger("remake_convert")

#: The missions the three slices need (docs/92 §10, docs/93, docs/94,
#: docs/95).  `_C_132` is the third slice's worst case -- 39 live aliens on a
#: 40x40 map, the largest product of "aliens x cells" in the corpus -- and is
#: what the AI replay cases and the turn measurement are taken on.  `_C_140`
#: is the second slice's demonstration mission -- the first playable one, whose
#: squad and aliens are both in the `.lev` and which is *won by moving*;
#: `_C_115` is what the first slice rendered; `_C_141` is where the native
#: oracle is taken, because it is the mission the slot-6 save is on; `_C_100`
#: is the second entry that keeps determinism honest across two maps sharing a
#: world set and scene with `_C_141`.  `_C_129` is the presentation slice's
#: (docs/97 §42): it is the only converted mission that plays a **`CrushWall`**
#: on its own -- its `NextTurn` fires three of them, each behind a
#: `MoveCamera`, when the turn counter reaches 3 -- and it places a hero, so
#: the set piece can be reached by pressing SPACE three times rather than only
#: in a suite.  It is also one of the three missions whose `CrushWall`
#: footprints are measured in the engine by `presentation_gold.py` (§41.7), so
#: what the build shows has a native capture behind it.
SLICE_MISSIONS = ["_C_140", "_C_115", "_C_141", "_C_100", "_C_132", "_C_129"]

#: The two maps the campaign *frame* is drawn on -- `docs/27` §2.1.  They are
#: not missions: they are the screen the missions are chosen from, and a cache
#: without them opens the location map onto nothing.  Which is what happened:
#: they arrived only with `--campaign-maps`, so the default six-mission cache
#: -- the one every developer has -- had a location map with no map in it.
#: Every selection carries them, including an explicit `--missions`.  They are
#: 40x40 `A00` maps and cost 1.1 MiB over a set that already has an `A00`
#: mission -- measured, both with and without the music.
CAMPAIGN_FRAME_MAPS = ["_C_XXX", "_C_YYY"]

#: Files the converter reads that are not reached through a mission, but whose
#: identity the manifest has to carry.
EXTRA_SOURCES = ["Incubation.exe"]


def _reader(root: Path) -> cachemod.SourceReader:
    reader = cachemod.SourceReader(root=root)
    for rel in EXTRA_SOURCES:
        path = root / rel
        if path.is_file():
            reader.record(path)
    return reader


def run_conversion(root: Path, missions: list[str], caches_root: Path,
                   language: str,
                   music: bool = True) -> tuple[cachemod.Staging,
                                                dict[str, Any], Any]:
    """Convert into a fresh staging directory and build its manifest."""
    reader = _reader(root)
    staging = cachemod.Staging.create(caches_root)
    try:
        result = convert(root, missions, staging, reader, language, music=music)
    except Exception:
        staging.discard()
        raise
    inventory = cachemod.build_inventory(staging)
    manifest = cachemod.build_manifest(
        reader, inventory, language, result.warnings,
        {"missions": result.missions, "world_sets": result.world_sets,
         "prototypes": result.prototypes, "textures": result.textures,
         "text_entries": result.text_entries,
         "waves": result.waves, "tracks": result.tracks,
         # Recorded in the manifest because the same input converts to two
         # different caches with and without it, and the cache id would
         # otherwise be the only place that difference showed.
         "music": music})
    return staging, manifest, result


def refuse_unsafe_output(root: Path, out: Path) -> None:
    """Refuse an output root that must never be written to, or deleted from.

    ``publish`` creates directories under ``out`` and ``collect`` removes the
    caches it finds there, so a mistyped ``-o`` is not a harmless mistake.  Two
    destinations are refused outright: anywhere inside the read-only game
    installation, and this repository itself.  Everything else is allowed --
    ``collect`` no longer deletes directories it did not write, so an ordinary
    wrong path costs a stray subdirectory and nothing more.
    """
    refuse_game_output(root, out)
    target = out.resolve()
    repo = Path(__file__).resolve().parent.parent
    for forbidden, why in ((repo, "converted assets are never committed"),):
        if target == forbidden or forbidden in target.parents:
            raise cachemod.CacheError(
                f"refusing to write the cache into {target}: {why}")


def refuse_game_output(root: Path, out: Path) -> None:
    """Keep both production caches and development fixtures out of the game."""
    target = out.resolve()
    game = root.resolve()
    if target == game or game in target.parents:
        raise cachemod.CacheError(
            f"refusing to write into {target}: the game installation is read-only")


def convert_and_publish(root: Path, missions: list[str], out: Path,
                        language: str, music: bool = True) -> int:
    refuse_unsafe_output(root, out)
    caches_root = out
    started = time.perf_counter()
    # Collection removes abandoned staging directories, so the same lock must
    # cover their whole lifetime.  Taking it only for publish let converter B
    # collect converter A's still-active staging tree while A was converting.
    with cachemod.publish_lock(caches_root):
        staging, manifest, result = run_conversion(
            root, missions, caches_root, language, music)
        try:
            target, created = cachemod.publish(staging, caches_root, manifest)
            cachemod.set_active(caches_root, manifest["cache_id"])
            removed = cachemod.collect(caches_root, manifest["cache_id"])
        except cachemod.CacheError:
            staging.discard()
            raise
    elapsed = time.perf_counter() - started
    size = sum(p.stat().st_size for p in target.rglob("*") if p.is_file())
    LOG.info("%s %s (%d files, %.1f KiB) in %.2fs",
             "published" if created else "already published", target.name,
             len(manifest["inventory"]), size / 1024, elapsed)
    LOG.info("missions %s, %d prototypes, %d textures, %d waves, %d track(s)",
             ", ".join(result.missions), result.prototypes, result.textures,
             result.waves, result.tracks)
    for warning in manifest["warnings"]:
        LOG.warning("%s", warning)
    if removed:
        LOG.info("collected %d older cache(s)", len(removed))
    return 0


def dev_fixtures(root: Path, missions: list[str], out: Path,
                 language: str, music: bool = True) -> int:
    """Materialise the same bytes into a gitignored ``res://generated/`` tree.

    ``docs/92`` §10.1 item 4 wants the development fixtures to describe the same
    decoded data as production and the diff to be of the portable logical data
    rather than of an incidental Godot serialisation.  Emitting the identical
    byte stream through the identical function makes that trivially true --
    there is no incidental serialisation to diff around.
    """
    refuse_game_output(root, out)
    # **Before** the conversion, not after it.  Both directories this replaces
    # are checked up front, so a mistyped `--dev-fixtures` costs a message
    # rather than several seconds of work followed by a message -- and, more
    # to the point, the `inspect/` refusal cannot fire after `cache/` has
    # already been replaced.
    _refuse_unowned(out / "cache", cachemod.is_cache_dir,
                    "it is not one of this converter's caches")
    _refuse_unowned(out / EYE_DIR, _is_eye_dir,
                    f"it carries no {EYE_MARKER} marker")
    staging, manifest, _result = run_conversion(root, missions, out, language,
                                                music)
    out.mkdir(parents=True, exist_ok=True)
    target = out / "cache"
    # The same rule `collect` follows, and for the same reason: this removes a
    # whole directory tree by a fixed name under a path the caller chose, so it
    # must first establish that the tree is one of ours.  `refuse_unsafe_output`
    # cannot help here -- the documented destination is `godot/generated`,
    # inside this repository, which that function exists to refuse.
    _remove_if_ours(target, cachemod.is_cache_dir,
                    "it is not one of this converter's caches")
    (staging.root / cachemod.MANIFEST_NAME).write_bytes(
        cachemod.dumps(manifest).encode("utf-8"))
    staging.root.rename(target)
    LOG.info("wrote %s (%d files)", target, len(manifest["inventory"]))
    written = write_eye_fixtures(root, missions, out, manifest)
    LOG.info("wrote %s (%d files for the eye, read by no code)",
             out / EYE_DIR, written)
    return 0


#: Marks a directory as one this tool wrote and may therefore delete.  The
#: cache directory is identified by its manifest; the eye fixtures have no
#: manifest, so they get this.
EYE_MARKER = ".incubation-eye-fixtures"
EYE_MARKER_BODY = cachemod.MANIFEST_SCHEMA + "\n"


def _is_eye_dir(entry: Path) -> bool:
    try:
        return (entry / EYE_MARKER).read_text(encoding="ascii") \
            == EYE_MARKER_BODY
    except (OSError, UnicodeDecodeError):
        return False


def _refuse_unowned(target: Path, owned: Any, why: str) -> None:
    """Raise unless ``target`` is absent, empty, or written by this tool.

    An empty directory is fine to take over -- somebody made the path by hand
    before the first run, which is the ordinary case.  Anything else is
    somebody's data, and a fixed name under a caller-chosen root is exactly
    where a mistyped path lands.
    """
    if not target.exists():
        return
    if not target.is_dir():
        raise cachemod.CacheError(
            f"refusing to replace {target}: it is not a directory")
    if owned(target) or not any(target.iterdir()):
        return
    raise cachemod.CacheError(
        f"refusing to delete {target}: {why}. Point --dev-fixtures somewhere "
        f"else, or remove it yourself if it really is disposable.")


def _remove_if_ours(target: Path, owned: Any, why: str) -> None:
    """:func:`_refuse_unowned`, then delete."""
    _refuse_unowned(target, owned, why)
    if target.exists():
        shutil.rmtree(target)


#: Where the by-eye comparison material goes.  docs/92 §10.4's fourth criterion
#: has an automated half (`test_render.gd`, `test_mesh.gd`: counts, positions,
#: materials) and a half only a person can do -- does the picture match the
#: inspection tools.  Nothing reads these; they exist so that half does not
#: require hunting for the right command line.
EYE_DIR = "inspect"


def write_eye_fixtures(root: Path, missions: list[str], out: Path,
                       manifest: dict[str, Any]) -> int:
    """`lev_parse --png` per mission and `prototyp_parse --obj` per prototype.

    Deliberately *not* part of the cache: they are derived from the same data
    but nothing loads them, so putting them in the inventory would make the
    manifest describe things the game never reads.
    """
    target = out / EYE_DIR
    _remove_if_ours(target, _is_eye_dir,
                    f"it carries no {EYE_MARKER} marker")
    (target / "maps").mkdir(parents=True, exist_ok=True)
    (target / EYE_MARKER).write_text(EYE_MARKER_BODY, encoding="ascii")
    # Godot's importer treats `.obj` as a mesh and `.png` as a texture, so
    # without this it imports all 91 of them on every `--import` pass and the
    # test export ships them.  `.gdignore` makes it skip the whole subtree --
    # which is right: nothing here is a resource, it is material for a person
    # to look at beside the running game.
    (target / ".gdignore").write_bytes(b"")
    written = 0
    for name in missions:
        bm = load_lev(str(mission_path(root, name)))
        lev_parse.render_png(bm, str(target / "maps" / f"{name}.png"))
        written += 1

    for world_set in manifest.get("world_sets", []):
        document = json.loads(
            (out / "cache" / "geometry" / f"{world_set}.json").read_text())
        source = document["source"]
        # The manifest records source paths relative to the game root.
        container = protomod.load_container(str(root / source["din"]),
                                            str(root / source["bin"]))
        directory = target / "meshes" / world_set
        directory.mkdir(parents=True, exist_ok=True)
        for prototype in sorted(document["prototypes"]):
            try:
                proto = container.parse(container.find(prototype))
            except (ParseError, KeyError, ValueError):
                continue
            path = directory / (prototype.replace(".3DI", "") + ".obj")
            path.write_text(protomod.to_obj(proto), encoding="utf-8")
            written += 1
    return written



# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def _inventory_map(manifest: dict[str, Any]) -> dict[str, str]:
    return {e["path"]: e["sha256"] for e in manifest["inventory"]}


def _float_paths(value: object, path: str = "$") -> list[str]:
    found: list[str] = []
    if isinstance(value, float):
        found.append(path)
    elif isinstance(value, dict):
        for key, item in value.items():
            found += _float_paths(item, f"{path}.{key}")
    elif isinstance(value, list):
        for i, item in enumerate(value):
            found += _float_paths(item, f"{path}[{i}]")
    return found


def check_png_stability(c: Checker) -> None:
    """PNG byte-stability, verified rather than assumed (slice risk 6).

    ``inclib.png`` must not write a ``tIME`` chunk and must pin the ``zlib``
    level; either would make two conversions differ for unchanged input, and
    the determinism check would then fail intermittently.
    """
    source = (Path(__file__).resolve().parent / "inclib" / "png.py").read_text()
    c.check("png.no_time_chunk", "tIME" not in source,
            "the writer emits no tIME chunk")
    c.check("png.fixed_zlib_level", "zlib.compress(bytes(raw), 9)" in source,
            "the writer pins the zlib level rather than taking the default")
    payload = bytes(range(256)) * 16
    c.check("png.deterministic",
            zlib.compress(payload, 9) == zlib.compress(payload, 9),
            "zlib at a fixed level is deterministic on this interpreter")


def check_against_as_dict(c: Checker, root: Path, cache_dir: Path,
                          missions: list[str]) -> None:
    """``lev_parse.as_dict`` as an oracle for every field the two share."""
    for name in missions:
        document = json.loads(
            (cache_dir / "missions" / name / "map.json").read_text())
        oracle = lev_parse.as_dict(load_lev(str(mission_path(root, name))))
        header = document["header"]
        geometry = json.loads(
            (cache_dir / "geometry"
             / f"{header['world_set']}.json").read_text())
        geometry_names = set(geometry["prototypes"])
        # A total name-lookup regression would otherwise publish a world with
        # no geometry at all and exit 0: the converter records misses as a
        # manifest warning, and nothing gated on the warning.
        c.check(f"beyond.{name}.geometry_present", len(geometry_names) > 0,
                f"{len(geometry_names)} prototypes emitted for "
                f"{header['world_set']}")
        # An effect model a world set does not carry is the original's own
        # behaviour (docs/28 7.5) and is recorded as `absent_effects`.  Every
        # *other* miss is still a regression, so the check subtracts the
        # recorded set rather than dropping the assertion.
        c.expect(f"beyond.{name}.geometry_complete",
                 [n for n in geometry.get("missing", [])
                  if n not in set(geometry.get("absent_effects", []))], [],
                 "every prototype the placements name was found, bar the "
                 f"{len(geometry.get('absent_effects', []))} effect model(s) "
                 "this world set does not have")
        c.expect(f"oracle.{name}.header",
                 [header["name"], header["next_map"], header["map_type"],
                  header["mission_id"], header["world_set"],
                  header["world_scene"], document["width"], document["height"],
                  header["camera_height"], header["equip_points"],
                  header["skill_level"], header["tech_level"]],
                 [oracle["map_name"], oracle["next_map"], oracle["map_type"],
                  oracle["mission_id"], oracle["world_set"],
                  oracle["world_scene"], oracle["width"], oracle["height"],
                  oracle["camera_height"], oracle["equip_points"],
                  oracle["skill_level"], oracle["tech_level"]])
        cells = document["cells"]
        c.expect(f"oracle.{name}.cells",
                 [cells["height"], cells["field_type"], cells["action_point"],
                  cells["unit"], cells["land"]],
                 [[cell["height"] for cell in oracle["cells"]],
                  [cell["field_type"] for cell in oracle["cells"]],
                  [cell["action_point"] for cell in oracle["cells"]],
                  [-1 if cell["unit"] is None else cell["unit"]
                   for cell in oracle["cells"]],
                  [cell["land"] for cell in oracle["cells"]]],
                 f"{len(cells['height'])} cells")
        c.expect(f"oracle.{name}.units",
                 [(u["slot"], u["name"], u["type_id"], u["player"], u["x"],
                   u["y"], u["hit_points"], u["action_points"], u["placed"])
                  for u in document["units"]],
                 [(u["slot"], u["name"], u["type_id"], u["player"], u["x"],
                   u["y"], u["hit_points"], u["action_points"], u["placed"])
                  for u in oracle["units"]],
                 f"{len(document['units'])} units")
        c.expect(f"oracle.{name}.special",
                 [o["prototype"] for o in document["special_objects"]],
                 [o["prototype_name"] for o in oracle["special_objects"]])
        # What the new emitter carries and as_dict drops.
        c.check(f"beyond.{name}.clones",
                bool(document["scene_clones"]),
                f"{len(document['scene_clones'])} scene clones, which as_dict "
                f"has no field for")
        # Not `endswith(".3DI")` -- that asserted a suffix on a constant this
        # file also chooses, so it could never fail.  What matters is that the
        # named prototype is one the emitted geometry actually contains, which
        # is the claim "resolved by name, not by the stale runtime index" makes.
        lattice = document["land"]["prototype"]
        c.check(f"beyond.{name}.lattice",
                lattice in geometry_names,
                f"the lattice prototype {lattice} is one of the "
                f"{len(geometry_names)} the converter emitted for this world "
                f"set, so the stale runtime index is not needed")
        c.expect(f"beyond.{name}.no_floats", _float_paths(document), [])


#: The cache is the player's disc, so the bodies' cost is bounded by a number
#: rather than by hope.  Measured for the three demo missions: bodies and clips
#: together come to about 3.1 MB against roughly 4.5 MB of map, scenery and
#: textures.  The ceiling is set at twice the measurement -- generous enough not
#: to fire on a mission with a wider roster, tight enough that closing over
#: "every model" (2.5 MB of mesh per world set, 4.6 MB of clips) trips it.
BODY_CACHE_CEILING_BYTES = 8 * 1024 * 1024


def check_bodies(c: Checker, root: Path, cache_dir: Path,
                 missions: list[str]) -> None:
    """The Charisma documents: closure, resolution, encoding and size."""
    models_index = json.loads((cache_dir / "models" / "index.json").read_text())
    anims_index = json.loads(
        (cache_dir / "animations" / "index.json").read_text())
    selectors = json.loads((cache_dir / "tables" / "charisma.json").read_text())
    units = json.loads((cache_dir / "geometry" / "units.json").read_text())

    emitted_models = {m["name"] for m in models_index["models"]}
    emitted_anims = {a["name"] for a in anims_index["animations"]}

    # The two indexes are exactly what the selector table can return -- neither
    # short (a body that cannot be drawn) nor long (a body nothing selects).
    from_table: dict[str, set[str]] = {
        selector: set(document["names"])
        for selector, document in selectors.items()
        if isinstance(document, dict) and "names" in document}
    c.expect("bodies.models_match_table", emitted_models,
             from_table.get("model", set()),
             f"{len(emitted_models)} bodies")
    # `docs/40` §7.2's fourth row is not a selector's: `fcn.004055e0`'s
    # `kind == 4` names one clip as a literal, and an upgrade base's marines
    # are the only thing that plays it (`docs/27` §2.7.1).  It is read back out
    # of the shipped executable rather than restated, so the cache and the
    # binary are two readings and not one.
    kind4 = seq_parse.PEFile(root / "Incubation.exe").cstring(
        chatables.KIND4_LITERAL_VA)
    c.expect("bodies.kind4_literal", kind4, chatables.KIND4_LITERAL_NAME,
             f"{chatables.KIND4_LITERAL_VA:#x}")
    c.expect("bodies.animations_match_table", emitted_anims,
             set().union(*(from_table[s] for s in ("move", "idle", "fire")))
             | {kind4},
             f"{len(emitted_anims)} clips, the kind-4 literal among them")

    # Every unit of every converted mission finds its key in the table.
    missing_keys: list[str] = []
    for name in missions:
        document = json.loads(
            (cache_dir / "missions" / name / "map.json").read_text())
        for unit in document["units"]:
            for weapon in range(chatables.WEAPON_LIMIT):
                key = f"{unit['type_id']},{weapon},{unit['player']}"
                if key not in selectors["model"]["entries"]:
                    missing_keys.append(f"{name}:{key}")
    c.expect("bodies.closure_covers_units", missing_keys[:4], [],
             f"{len(missions)} missions, every unit and every weapon")

    # Every part's mesh is emitted; every emitted mesh is used.
    named: set[str] = set()
    for entry in models_index["models"]:
        named.update(entry["meshes"])
    c.expect("bodies.meshes_resolve", sorted(named - set(units["prototypes"])),
             [], f"{len(named)} meshes named by {len(emitted_models)} bodies")
    c.expect("bodies.no_orphan_meshes",
             sorted(set(units["prototypes"]) - named), [])

    # docs/40 §7: a track whose target is no part must survive into the cache,
    # because ignoring it is a runtime rule the exported build has to exercise.
    parts_by_model: dict[str, set[str]] = {}
    for name in sorted(emitted_models):
        document = json.loads((cache_dir / "models" / f"{name}.json").read_text())
        parts_by_model[name] = {p["name"] for p in document["parts"]} \
            | {n["name"] for n in document["skeleton"]["nodes"]}
    every_part: set[str] = set().union(*parts_by_model.values()) \
        if parts_by_model else set()
    unbound: set[str] = set()
    for name in sorted(emitted_anims):
        document = json.loads(
            (cache_dir / "animations" / f"{name}.json").read_text())
        unbound |= {t["target"] for t in document["tracks"]
                    if t["target"] not in every_part}
    c.check("bodies.helper_tracks_kept", bool(unbound),
            f"{len(unbound)} targets a runtime must ignore: "
            + ", ".join(sorted(unbound)))

    # Textures are named, never numbered: the id is per world set and this
    # document is shared.
    world_sets = {json.loads((cache_dir / "missions" / m / "map.json")
                             .read_text())["header"]["world_set"]
                  for m in missions}
    wanted = {face["texture_name"]
              for proto in units["prototypes"].values()
              for face in proto["faces"] if face["texture_name"]}
    for world_set in sorted(world_sets):
        index = json.loads(
            (cache_dir / "textures" / world_set / "index.json").read_text())
        have = {entry["name"] for entry in index["textures"]}
        c.expect(f"bodies.textures.{world_set}", sorted(wanted - have), [],
                 f"{len(wanted)} unit texture names decoded for {world_set}")

    # The float rule, on the documents that actually carry floats.
    for relative in ["tables/charisma.json", "geometry/units.json",
                     "models/index.json", "animations/index.json"]:
        c.expect(f"bodies.no_floats.{relative}",
                 _float_paths(json.loads((cache_dir / relative).read_text())),
                 [])
    sample_model = sorted(emitted_models)[0]
    sample_anim = sorted(emitted_anims)[0]
    for relative in [f"models/{sample_model}.json",
                     f"animations/{sample_anim}.json"]:
        c.expect(f"bodies.no_floats.{relative}",
                 _float_paths(json.loads((cache_dir / relative).read_text())),
                 [])

    # The bit-pattern encoding is exact, checked against the source files.
    animation = chamod.parse_animation_file(str(animation_path(root, sample_anim)))
    document = json.loads(
        (cache_dir / "animations" / f"{sample_anim}.json").read_text())
    mismatches = 0
    total = 0
    for movement, track in zip(animation.movements, document["tracks"]):
        raw = base64.b64decode(track["keys"])
        values = struct.unpack(f"<{len(raw) // 4}f", raw)
        at = 0
        for key in movement.keys:
            want = (key.time,) + tuple(key.values)
            got = values[at:at + 1 + track["arity"]]
            at += 1 + track["arity"]
            total += len(want)
            mismatches += int(got != want)
    c.expect("bodies.keys_round_trip", mismatches, 0,
             f"{total} floats of {sample_anim} recovered bit-exactly")

    # The *single*-value encoding, which the blob check does not touch: a note's
    # time and a clip's duration are `u32` bit patterns rather than base64, so
    # that a document stays greppable. A mutation test found this uncovered.
    def from_bits(bits: int) -> float:
        return struct.unpack("<f", struct.pack("<I", bits))[0]

    c.expect("bodies.duration_round_trip",
             from_bits(document["duration_bits"]), animation.duration,
             f"{sample_anim} is {animation.duration:g} key-time units")
    note_times = [from_bits(n["time_bits"]) for n in document["notes"]]
    c.expect("bodies.note_times_round_trip", note_times,
             [n.time for n in animation.notes],
             f"{len(note_times)} note(s)")

    size = sum(path.stat().st_size
               for directory in ("models", "animations")
               for path in (cache_dir / directory).rglob("*.json")) \
        + (cache_dir / "geometry" / "units.json").stat().st_size
    c.check("bodies.cache_size", size <= BODY_CACHE_CEILING_BYTES,
            f"{size / 1024 / 1024:.2f} MiB of bodies and clips, ceiling "
            f"{BODY_CACHE_CEILING_BYTES / 1024 / 1024:.0f} MiB")


#: ``docs/60`` §5 -- the descent each font reserves below the baseline. The
#: two blank glyphs, space and NBSP, are exempt in ``font_0`` and ``font_2``,
#: which is why those two carry a second value.
FONT_DESCENTS: dict[str, list[int]] = {
    "font_0": [2, 3], "font_1": [2], "font_2": [2, 3], "font_3": [2],
}
#: ``docs/60`` §5 -- 224 elements, one per cp1252 code point from 32 to 255.
FONT_GLYPHS = 224


def check_fonts(c: Checker, cache_dir: Path) -> None:
    """The game's own bitmap fonts, against what ``docs/60`` §5 measured."""
    index = json.loads((cache_dir / "fonts" / "index.json").read_text())
    fonts = {f["name"]: f for f in index["fonts"]}
    c.expect("fonts.present", sorted(fonts), sorted(FONT_DESCENTS))
    for name in sorted(fonts):
        font = fonts[name]
        c.expect(f"fonts.{name}.glyphs", len(font["glyphs"]), FONT_GLYPHS,
                 "one per cp1252 code point from 32 to 255")
        # The descent is a property of the font, not of a glyph, and a font
        # whose glyphs disagreed about it would show up as an extra value
        # rather than as a baseline nobody noticed.
        c.expect(f"fonts.{name}.descents", font["descents"],
                 FONT_DESCENTS[name])
        c.expect(f"fonts.{name}.codepoints",
                 [font["glyphs"][0]["codepoint"], font["glyphs"][-1]["codepoint"]],
                 [32, 255])
        # Every glyph must lie inside the atlas it indexes into.
        overflow = [g["codepoint"] for g in font["glyphs"]
                    if g["x"] + g["width"] > font["atlas_width"]
                    or g["height"] > font["atlas_height"]]
        c.expect(f"fonts.{name}.inside_atlas", overflow, [],
                 f"{font['atlas_width']}x{font['atlas_height']}")
        c.check(f"fonts.{name}.png",
                (cache_dir / "fonts" / str(font["file"])).is_file(),
                str(font["file"]))
    c.expect("fonts.no_floats", _float_paths(index), [])


#: The cache's size, in KiB, with music and without it.  Named as two numbers
#: because music is 95 % of the difference and is behind a flag; a check that
#: quoted one would pass on the other by luck.  The ceilings are the measured
#: sizes rounded up to the next whole MiB -- close enough that a new asset
#: family shows, loose enough that one more converted texture does not.
#:
#: The music ceiling moved from 33 to 37 when `_C_129` joined the set: it is
#: the first mission here to name a **sixth** CD track, and one track is about
#: 4 MiB, so the cache went 33.0 -> 36.1 MiB while the silent one moved by the
#: 29 prototypes of its scene alone (10.5 MiB, well under its own ceiling).
#: That is the check working as intended -- the growth had a name before the
#: number was changed.
#:
#: They moved again for the sixth slice, 37 -> 42 and 13 -> 17, and the growth
#: has a name here too: the campaign layer's art.  1400 interface sprites and
#: 103 screen plates and briefing pictures are ~8 MiB, and they are **not**
#: per-mission -- the location graph, the briefings and the interface are the
#: same whichever missions were asked for, so this is a one-off step and not a
#: slope.
#:
#: The seventh slice added the shell's five top-level screens -- 103 plates and
#: pictures became 108 -- and **neither ceiling moved**: five 640x480 8-bit
#: images are ~0.2 MiB, which is the "one more converted texture" case these
#: numbers are deliberately loose enough to absorb.  Re-measured with them in,
#: the two are 41.5 and 15.4 MiB.
#:
#: Both moved when :data:`CAMPAIGN_FRAME_MAPS` joined every selection: two more
#: 40x40 maps and the `A00` scenery they stand on, 1.1 MiB either way --
#: measured at 42.6 and 16.5 MiB against 41.5 and 15.4.  Rounded up with the
#: same headroom the numbers above carry.
# Raised from 44/18 MiB on 2026-09-05, when the 233 speech files of docs/28
# 4.3 joined the closure: 5.4 MiB of wave, and the mission interface is
# silent without them.
#
#: The ninth slice (2026-09-08) is the first step since the campaign's that is
#: not a slope, and it is a large one: the twelve cutscene directories are 38
#: MiB of model, clip and geometry documents and 11 MiB of their own textures,
#: the 74 briefing voice-overs are 34 MiB of wave (speech, so unconditional),
#: and the eleven ``Track09..19.ogg`` the cutscenes loop are 20 MiB behind the
#: music flag.  Measured at 152.7 and 113.5 MiB against 42.6 and 16.5.  The
#: "music is the growth" check below became "the flag changes exactly the
#: music" at the same time, because music is no longer most of the difference.
CACHE_CEILING_KIB_MUSIC = 160 * 1024
CACHE_CEILING_KIB_SILENT = 120 * 1024
#: Sprite constructor calls that build a row, column or size in a
#: register instead of passing a literal (docs/28 7.3).
SPRITE_COMPUTED_CALLS = 18


def check_audio(c: Checker, root: Path, cache_dir: Path,
                music: bool) -> None:
    """The sound and effect documents, and the files they name."""
    import blob_tables  # noqa: PLC0415 -- one reader of the binary, see convert

    document = json.loads((cache_dir / "tables" / "sound.json").read_text())
    blobs = json.loads((cache_dir / "tables" / "blobs.json").read_text())
    c.expect("audio.schema", document["schema"],
             blob_tables.SOUND_DOCUMENT_SCHEMA)
    c.expect("audio.blob_schema", blobs["schema"],
             blob_tables.BLOB_DOCUMENT_SCHEMA)
    c.expect("audio.volume_ids", len(document["volumes"]),
             soundmod.INFO_VOLUME_IDS)
    c.expect("audio.play_slots", document["play_slots"], soundmod.PLAY_SLOTS)

    # Every wave the document can name is in the cache, under the lower-cased
    # name the document uses -- the case question is answered once, here.
    named = set(document["waves"])
    for event in document["events"].values():
        named |= {cue["wave"] for cue in event}
    named |= {w["wave"] for w in document["weapons"].values() if w["wave"]}
    named |= set(document["voices"]["human"] + document["voices"]["alien"]
                 + document["voices"]["second_human"])
    named |= {step["wave"] for step in document["footsteps"] if step["wave"]}
    missing = sorted(n for n in named
                     if not (cache_dir / "audio" / "waves" / n).is_file())
    c.expect("audio.waves_present", missing, [], f"{len(named)} named waves")
    c.check("audio.waves_lowercase", all(n == n.lower() for n in named),
            "every name the document uses is already resolved")

    shipped = sorted(p.name for p in (cache_dir / "audio" / "waves").iterdir())
    c.expect("audio.no_dead_waves",
             sorted(set(shipped) & {n.lower() for n in soundmod.DEAD_WAVES}),
             [], "no ambience or unreferenced wave reaches the cache")
    c.expect("audio.case_renames_resolved",
             sorted(n for n in blob_tables.CASE_MISMATCHED
                    if (cache_dir / "audio" / "waves" / n).is_file()),
             sorted(n for n in blob_tables.CASE_MISMATCHED if n in named),
             "the ten renames of docs/28 2.2 are files in the cache")

    # The one name that resolves to nothing is the recorded defect, and the
    # document says so rather than leaving a hole.
    c.expect("audio.unresolved_count", len(document["unresolved"]), 1,
             "; ".join(document["unresolved"]))
    c.expect("audio.weapon_35_silent",
             document["weapons"][str(soundmod.WEAPON_MISSING_SOUND)]["wave"],
             None, "reproduced by default (docs/28 3.1)")
    c.check("audio.weapon_35_correctable",
            document["weapons"][str(soundmod.WEAPON_MISSING_SOUND)]
            ["corrected"] is not None,
            "the correction names a file the cache carries")

    # Playlists and music.
    mission_lists = sorted(k for k in document["playlists"]
                           if not k.startswith("frontend/"))
    c.expect("audio.playlists", mission_lists,
             sorted(missions_in_cache(cache_dir)),
             f"{len(mission_lists)} missions name a playlist")
    # The front end's own programs (seq_parse.FRONTEND), so the menu, the
    # credits, mission control and the debriefing have their tracks in a
    # six-mission cache whose scripts never name 6, 7 or 8.
    c.expect("audio.frontend_playlists",
             {k: v for k, v in document["playlists"].items()
              if k.startswith("frontend/")},
             {f"frontend/{name}": soundmod.playlist(program)
              for name, (program, _va, _call)
              in seq_parse.FRONTEND["cd_programs"].items()})
    tracks = sorted({t for entry in document["playlists"].values()
                     for t in entry})
    c.check("audio.playlist_tracks", bool(tracks), str(tracks))
    if music:
        c.expect("audio.tracks_present",
                 sorted(t for t in tracks
                        if not (cache_dir / "audio" / "music"
                                / f"{t}.ogg").is_file()),
                 [], f"{len(tracks)} track(s)")
    else:
        c.expect("audio.no_music", (cache_dir / "audio" / "music").exists(),
                 False, "--no-music leaves the tracks out")

    # The effect tables and the atlas.
    c.expect("effects.kinds", len(blobs["kinds"]),
             blob_tables.KIND_COUNT)
    c.expect("effects.arms",
             len({k["arm_id"] for k in blobs["kinds"].values()}),
             blob_tables.KIND_ARMS)
    c.expect("effects.unreachable", tuple(blobs["unreachable"]),
             blob_tables.KIND_UNREACHABLE)
    c.expect("effects.calls", len(blobs["calls"]), blob_tables.BLOB_CTOR_CALLS)
    c.expect("effects.sprites", len(blobs["sprites"]),
             len(blob_tables.BLOB_SPRITE))
    c.expect("effects.models", len(blobs["models"]),
             blob_tables.BLOB_MODEL_COUNT)
    # Eighteen of the 54 sprite calls build a row, a column or a size in a
    # register; the document carries `null` for those rather than a guess, and
    # the runtime takes them from the arm.  The literal ones must be in range.
    grid = blobs["atlas"]["grid"]
    out_of_grid = sorted(site for site, v in blobs["sprites"].items()
                         for field in ("row", "col")
                         if v[field] is not None
                         and not 0 <= v[field] < grid)
    c.expect("effects.sprite_cells_in_grid", out_of_grid, [],
             f"every literal row and column is inside the {grid}x{grid} grid")
    c.expect("effects.sprite_computed",
             sum(1 for v in blobs["sprites"].values()
                 if None in (v["row"], v["col"], v["size"])),
             SPRITE_COMPUTED_CALLS,
             "calls whose row, column or size the arm supplies")

    atlases = {}
    for world_set in sorted(p.name for p in (cache_dir / "textures").iterdir()):
        # The cutscene directories' own texture sets carry no sprite atlas:
        # nothing draws a blob in a `Video/` scene (`check_sequences`).
        if world_set.startswith("video_"):
            continue
        index = json.loads((cache_dir / "textures" / world_set
                            / "index.json").read_text())
        entry = [t for t in index["textures"]
                 if t["name"] == convertmod.ATLAS_TEXTURE]
        c.expect(f"effects.atlas_{world_set}", len(entry), 1)
        if not entry:
            continue
        c.expect(f"effects.atlas_size_{world_set}",
                 (entry[0]["width"], entry[0]["height"]),
                 (blobs["atlas"]["size"], blobs["atlas"]["size"]))
        atlases[world_set] = (cache_dir / "textures" / world_set
                              / entry[0]["file"]).read_bytes()
    c.expect("effects.atlas_identical", len(set(atlases.values())), 1,
             f"one image across {len(atlases)} converted world set(s)")

    # Every effect model is either in the set or recorded as absent from it.
    for world_set in sorted(atlases):
        geometry = json.loads((cache_dir / "geometry"
                               / f"{world_set}.json").read_text())
        absent = set(geometry.get("absent_effects", []))
        unaccounted = sorted(n for n in blobs["models"]
                             if n not in geometry["prototypes"]
                             and n not in absent)
        c.expect(f"effects.models_{world_set}", unaccounted, [],
                 f"{len(blobs['models']) - len(absent)} present, "
                 f"{len(absent)} cancelled by docs/28 7.5")

    # The two jointed effect models, and the part structure that makes the
    # joint angles drawable (docs/28 7.8).  A prototype with no `part_push`
    # emits no `parts` key at all, which is why the count is checked and not
    # merely the presence.
    for world_set in sorted(atlases):
        geometry = json.loads((cache_dir / "geometry"
                               / f"{world_set}.json").read_text())
        found = {}
        for name, wanted in JOINTED_EFFECT_MODELS.items():
            proto = geometry["prototypes"].get(name)
            if proto is None:
                continue
            found[name] = [part["anim"] for part in proto.get("parts", [])]
        c.expect(f"effects.joints_{world_set}", found,
                 {n: list(v) for n, v in JOINTED_EFFECT_MODELS.items()
                  if n in found},
                 f"{len(found)} jointed model(s), by the operand each "
                 "part's joint_place names")
        # And the model whose arm turns the whole object has no parts at all.
        flat = geometry["prototypes"].get(UNJOINTED_EFFECT_MODEL)
        # Absent is a failure, not a skip: the contrast case only says
        # something if the model it names is one the set really carries.
        c.expect(f"effects.unjointed_{world_set}",
                 flat is not None and "parts" not in flat, True,
                 f"{UNJOINTED_EFFECT_MODEL} is present and turns as one object")


#: ``docs/28`` 7.8 -- the two effect models whose update arm writes joint
#: angles, and the ``joint_place`` operand of each of their parts.  The panel
#: has one moving plate; the fire has two billboards.
JOINTED_EFFECT_MODELS = {
    "A_PANEL.3DI": (6,),
    "A_FIRE3.3DI": (6, 12),
}
#: The contrast case: kind 41's model has no sub-object, and its arm turns
#: triple 0 -- the whole object -- instead.
UNJOINTED_EFFECT_MODEL = "A_FLIGHT.3DI"


def missions_in_cache(cache_dir: Path) -> list[str]:
    return sorted(p.name for p in (cache_dir / "missions").iterdir()
                  if p.is_dir())


def check_campaign(c: Checker, root: Path, cache_dir: Path) -> None:
    """The campaign tables, the briefings and the interface art.

    These three categories are **not** per-mission: whichever missions were
    asked for, the location graph, the 116 briefings and the 21 interface
    libraries are the same, so the campaign screens work off a six-mission
    slice as well as off a full bake.  That is what the first check states.
    """
    document = json.loads((cache_dir / "tables" / "campaign.json").read_text())
    c.expect("campaign.schema", document["schema"],
             convertmod.CAMPAIGN_SCHEMA)
    c.expect("campaign.missions", len(document["missions"]), 76,
             "the 75 shipped campaign missions plus _C_YYY, the mission id 255 "
             "_C_133 hands over to (docs/27 6.6, 2026-09-08)")
    c.expect("campaign.endings",
             {row["name"]: row["mission_id"] for row in document["missions"]
              if row["name"] in ("_C_YYY", "_C_180")},
             {"_C_YYY": 255, "_C_180": 180},
             "0x00456FC0's two ending arms both name a row")
    c.expect("campaign.map_names", len(document["map_names"]), 77)
    c.expect("campaign.unlock_graph", len(document["unlock_graph"]), 74,
             "79 arms less the five mission ids 35..39 have none")
    c.expect("campaign.upgrade_locations", len(document["upgrade"]), 15)
    # docs/27 section 5.2 -- the band each base sells, which is what a campaign
    # gates its shop on rather than the tech level.
    c.expect("campaign.upgrade_tech_bands",
             {row["location"]: (row["tech_low"], row["tech_high"])
              for row in document["upgrade"]},
             {1: (0, 0), 2: (0, 3), 3: (0, 5), 4: (1, 1), 5: (9, 9),
              6: (0, 4), 7: (0, 9), 8: (0, 2), 210: (0, 0), 211: (0, 1),
              212: (0, 2), 213: (0, 3), 214: (3, 3), 215: (0, 4),
              216: (0, 9)})
    c.expect("campaign.cut_locations",
             [row["mission"] for row in document["cut_locations"]],
             ["_C_134", "_C_135", "_C_136"])
    c.expect("campaign.unreachable", document["unreachable_locations"], [21, 50])

    # D12: every id-keyed table is a list of records with an integer id, so a
    # consumer never has to parse a key back out of a string.
    for table, key in (("map_names", "location"), ("unlock_graph", "mission"),
                       ("dialogue", "location"), ("upgrade", "location")):
        rows = document[table]
        c.check(f"campaign.records.{table}",
                isinstance(rows, list)
                and all(isinstance(row.get(key), int) for row in rows),
                f"{len(rows)} records keyed by an integer {key!r}")

    campaigns = {row["number"]: row for row in document["campaigns"]}
    c.expect("campaign.first_missions",
             (campaigns[1]["first_mission"], campaigns[2]["first_mission"]),
             ("_C_100", "_C_140"), "0x0043AF57 and 0x0043AF2A")
    c.expect("campaign.seeds",
             (campaigns[1]["seeds_a_squad"], campaigns[2]["seeds_a_squad"]),
             (True, False), "aCreateUnitPoolForCampaign(2) is a bare return")
    c.expect("campaign.economy_start",
             (document["economy"]["start_equipment_points"],
              document["economy"]["start_tech_level"],
              document["economy"]["start_skill_level"]),
             (100, 1, 0), "the campaign arm 0x0043AE76")
    c.expect("campaign.result_base_score",
             document["economy"]["result_base_score"],
             [0, 100, 200, 300, -100], "0x0043BBB8")

    with_cells = [row for row in document["missions"] if row["deployment_cells"]]
    c.expect("campaign.deployment_cells", len(with_cells), 73,
             "of 76; _C_131 ships its own squad, _C_180 is the epilogue and "
             "_C_YYY is campaign 2's map")
    over = [row["name"] for row in document["missions"]
            if len(row["deployment_cells"]) > 10]
    c.expect("campaign.deployment_ring", over, [],
             "the header's ring holds ten records")
    ships = [row["name"] for row in document["missions"] if row["ships_a_squad"]]
    c.expect("campaign.missions_shipping_a_squad", len(ships), 31,
             "the other 44 need the roster to deploy one")
    linked = [row for row in document["missions"] if row["next_map"]]
    names = {row["name"] for row in document["missions"]}
    dangling = sorted(row["next_map"] for row in linked
                      if row["next_map"] not in names
                      and not row["next_map"].upper().startswith("_C_Y")
                      and not row["next_map"].upper().startswith("_C_X"))
    c.expect("campaign.chain_resolves", dangling, [],
             f"{len(linked)} linked headers")

    # The briefings.
    briefings = sorted((cache_dir / "text" / "briefing").glob("*.json"))
    c.expect("campaign.briefings", len(briefings), 116)
    with_blocks = 0
    structured = True
    for path in briefings:
        brief = json.loads(path.read_text())
        if brief["blocks"]:
            with_blocks += 1
        for spans in brief["blocks"].values():
            for span in spans:
                if not isinstance(span.get("font"), int) \
                        or not isinstance(span.get("colour"), int) \
                        or not isinstance(span.get("text"), str):
                    structured = False
    c.check("campaign.briefing_blocks", with_blocks >= 110,
            f"{with_blocks} of {len(briefings)} carry A0/B0/C0")
    c.check("campaign.briefing_is_structured", structured,
            "docs/92 3.2: spans carry their font and colour, not a marked-up "
            "string the consumer would have to re-parse")

    # The pickup messages -- docs/26 section 3, `Events.txt`.
    events = json.loads(
        (cache_dir / "text" / "info" / "events.json").read_text())
    c.expect("info.schema", events["schema"], convertmod.INFO_SCHEMA)
    c.expect("info.labels", sorted(events["blocks"]),
             sorted(interaction_tables.EXPECTED_TEXT.values()),
             "the thirteen labels aExecuteUse's pickup arms name")
    # **The map itself, pair by pair.** The document carries the decoding of
    # the switch and the game side reads it, so this is the one place the two
    # can be compared against docs/26 section 3's own table -- a swapped pair
    # is what a check on the label *set* alone would let through.
    c.expect("info.action_points",
             {row["action_point"]: row["label"] for row in events["pickups"]},
             interaction_tables.EXPECTED_TEXT,
             "action point -> Events.txt label, out of the arm that pushes it")
    c.expect("info.every_arm_has_its_block",
             sorted(row["label"] for row in events["pickups"]
                    if row["label"] not in events["blocks"]), [])
    c.expect("info.speech",
             {row["action_point"]: row["speech"] for row in events["pickups"]},
             {ap: (interaction_tables.SPEECH_EVENT
                   if ap != interaction_tables.NO_SPEECH_ID else -1)
              for ap in interaction_tables.EXPECTED_TEXT},
             "twelve of the thirteen arms call 0x0047B660 with argument 9")
    empty = sorted(key for key, spans in events["blocks"].items()
                   if not "".join(span["text"] for span in spans).strip())
    c.expect("info.every_label_has_text", empty, [])
    c.check("info.is_structured",
            all(isinstance(span.get("font"), int)
                and isinstance(span.get("colour"), int)
                and isinstance(span.get("text"), str)
                for spans in events["blocks"].values() for span in spans),
            "docs/92 3.2, as the briefings are")

    # The art.
    art = json.loads((cache_dir / "art" / "index.json").read_text())
    c.expect("art.schema", art["schema"], convertmod.ART_SCHEMA)
    c.expect("art.plates", len(art["plates"]), 12,
             "the seven framed plates of GUI/ plus the five top-level screens")
    c.expect("art.briefing_pictures", len(art["briefing"]), 96)
    c.expect("art.libraries", len(art["libraries"]), 54,
             "21 interface libraries plus the 33 item ones")
    sprites = sum(1 for lib in art["libraries"] for s in lib["sprites"]
                  if s["file"])
    c.expect("art.sprites", sprites, 1400,
             "410 in the 21 interface libraries and 990 in the 33 item ones")
    missing = [lib["name"] for lib in art["libraries"]
               if lib["palette"] is None and not lib["unreferenced"]]
    c.expect("art.every_library_has_a_palette", missing, [],
             "addons and addons2 take the screen plate's, measured at "
             "0x0044B290/0x0044B2C4 and 0x0045D492/0x0045D4C9")
    unreferenced = [lib["name"] for lib in art["libraries"] if lib["unreferenced"]]
    c.expect("art.unreferenced", unreferenced, ["uicons2"],
             "named in no string of any shipped binary and in no .lcl")
    for entry in art["plates"] + art["briefing"]:
        path = cache_dir / ("art/plates" if entry in art["plates"]
                            else "art/briefing") / entry["file"]
        if not path.is_file():
            c.check(f"art.file.{entry['name']}", False, "declared but absent")
    c.check("art.files_present", True, f"{len(art['plates'])} plates, "
            f"{len(art['briefing'])} pictures")



def check_sequences(c: Checker, root: Path, cache_dir: Path,
                    music: bool = True) -> None:
    """The cutscenes and the front end -- docs/41 and docs/92 section 7.19.

    The manifest in the cache is `seq_parse`'s own document, so the two cannot
    disagree by a swapped arm; what is checked here is that the files it names
    are all there and resolve -- every model, every clip, every mesh a model
    names in its directory's geometry, every texture id a face names, every
    ``Cam<n>`` a ``Switch`` asks for -- plus the eleven tracks and the 75
    waves.
    """
    manifest = json.loads((cache_dir / "tables" / "sequences.json").read_text())
    pe = seq_parse.PEFile(root / "Incubation.exe")
    expected = seq_parse.manifest_document(pe)
    expected["directories"] = manifest.get("directories")
    expected["source"] = manifest.get("source")
    c.expect("sequences.manifest", manifest, expected,
             "the cache carries seq_parse's manifest verbatim")
    c.expect("sequences.directories", len(manifest["directories"]), 12)
    c.expect("sequences.pairs",
             sum(d["animations"] for d in manifest["directories"]), 130)
    c.expect("sequences.no_floats", _float_paths(manifest), [])
    # **A part's two lists are pairs, and the player indexes both.**  They are
    # built from one stem list so they cannot differ here, which is exactly why
    # the invariant is worth stating: `SequencePlayer._install_shot` bounds
    # itself on the shorter of the two, and a manifest that broke this would
    # otherwise reach that bound instead of this check.
    ragged = [f"{entry['id']}:{part['directory']}"
              for entry in manifest["sequences"]
              for part in entry["parts"]
              if len(part["models"]) != len(part["animations"])]
    c.expect("sequences.parts_are_pairs", ragged, [],
             f"{sum(len(e['parts']) for e in manifest['sequences'])} parts")

    models = clips = 0
    unresolved_meshes: list[str] = []
    unresolved_textures: list[str] = []
    unresolved_cameras: list[str] = []
    no_cam1: list[str] = []
    for entry in manifest["directories"]:
        directory = entry["directory"]
        base = cache_dir / "sequences" / directory
        index = json.loads((base / "index.json").read_text())
        c.expect(f"sequences.{directory}.schema", index["schema"],
                 convertmod.SEQUENCE_DIR_SCHEMA)
        geometry = json.loads((base / "geometry.json").read_text())
        textures = json.loads((cache_dir / "textures" / entry["texture_set"]
                               / "index.json").read_text())
        written = {t["id"] for t in textures["textures"]}
        for name in index["models"]:
            document = json.loads((base / "models" / f"{name}.json").read_text())
            models += 1
            nodes = {n["name"] for n in document["skeleton"]["nodes"]}
            if "Cam1" not in nodes:
                no_cam1.append(f"{directory}/{name}")
            for part in document["parts"]:
                if part["mesh"] and part["mesh"] not in geometry["prototypes"]:
                    unresolved_meshes.append(f"{directory}/{part['mesh']}")
        for name in index["animations"]:
            document = json.loads(
                (base / "animations" / f"{name}.json").read_text())
            clips += 1
            model_name = "Model_D09" if directory == "Dialog_09" \
                else "Model_" + name[len("Animation_"):]
            model = json.loads((base / "models" / f"{model_name}.json").read_text())
            nodes = {n["name"] for n in model["skeleton"]["nodes"]}
            for note in document["notes"]:
                for verb, value in seq_parse.parse_note_lines(note["text"]):
                    if verb == "Switch" and f"Cam{value}" not in nodes:
                        unresolved_cameras.append(f"{directory}/{name}: Cam{value}")
        for prototype in geometry["prototypes"].values():
            for face in prototype["faces"]:
                if face["texture"] >= 0 and face["texture"] not in written:
                    unresolved_textures.append(
                        f"{directory}: texture {face['texture']}")
        for texture in textures["textures"]:
            c.check(f"sequences.{directory}.texture_files",
                    (cache_dir / "textures" / entry["texture_set"]
                     / texture["file"]).is_file(), texture["file"])
            break
    # 113 and not 130: `Dialog_09`'s eighteen clips all drive `Model_D09`.
    c.expect("sequences.models", models, 113,
             "130 pairs less the seventeen that share Model_D09")
    c.expect("sequences.clips", clips, 130)
    c.expect("sequences.meshes_resolve", unresolved_meshes[:5], [])
    c.expect("sequences.textures_resolve", sorted(set(unresolved_textures))[:5],
             [])
    c.expect("sequences.switch_resolves", unresolved_cameras[:5], [])
    c.expect("sequences.cam1_everywhere", no_cam1[:5], [])

    frontend = json.loads((cache_dir / "tables" / "frontend.json").read_text())
    expected_frontend = seq_parse.frontend_document(pe)
    for key in ("voice_overs", "cd_family", "track_family_tracks",
                "music_converted"):
        expected_frontend[key] = frontend.get(key)
    c.expect("frontend.document", frontend, expected_frontend)
    c.expect("frontend.no_floats", _float_paths(frontend), [])
    c.expect("frontend.voice_overs", len(frontend["voice_overs"]), 74,
             "MB100..133 and MB140..179")
    missing_voices = [m for m in frontend["voice_overs"]
                      if not (cache_dir / "audio" / "briefing"
                              / f"{m}.wav").is_file()]
    c.expect("frontend.voice_files", missing_voices, [])
    c.check("frontend.extro_wave",
            (cache_dir / "audio" / "briefing" / "extro.wav").is_file(),
            "Briefing/extro.wav, the static extro's soundtrack")
    if music:
        c.expect("frontend.track_family", frontend["track_family_tracks"],
                 list(range(9, 20)), "Track09..19 for the eleven programs")
        missing_tracks = [t for t in frontend["track_family_tracks"]
                          if not (cache_dir / "audio" / "music" / "track"
                                  / f"{t}.ogg").is_file()]
        c.expect("frontend.track_files", missing_tracks, [])
    else:
        c.expect("frontend.no_track_music", frontend["track_family_tracks"], [],
                 "--no-music leaves the cutscene tracks out too")
    c.expect("frontend.holds", frontend["holds_ms"],
             {"logo": 1500, "after_sequence": 1000, "after_extro": 4000})


def check_mission_selection(c: Checker, root: Path) -> None:
    """What each form of the mission argument resolves to -- no conversion."""
    c.expect("select.default", missions_from_args(root, False, None),
             SLICE_MISSIONS + CAMPAIGN_FRAME_MAPS,
             "no argument is the slices' six, plus the campaign frame")
    c.expect("select.explicit",
             missions_from_args(root, False, "_C_140, _C_115 ,,"),
             ["_C_140", "_C_115"] + CAMPAIGN_FRAME_MAPS,
             "spaces trimmed, empty entries dropped, the frame added")
    c.expect("select.frame_is_not_doubled",
             missions_from_args(root, False, "_C_XXX,_C_140"),
             ["_C_XXX", "_C_140", "_C_YYY"],
             "a frame map named outright keeps its place in the list")
    c.expect("select.campaign_maps", missions_from_args(root, True, None),
             campaign_map_set(root),
             f"{CAMPAIGN_MAPS} maps, the set --check-campaign bakes")
    c.check("select.frame_is_in_the_full_set",
            all(n in campaign_map_set(root) for n in CAMPAIGN_FRAME_MAPS),
            "--campaign-maps already carries them")


def run_checks(root: Path, missions: list[str], language: str) -> int:
    c = Checker()
    if not (root / "Missions").is_dir():
        c.check("root", False, f"no Missions/ under {root}")
        return c.report()
    check_png_stability(c)
    check_mission_selection(c, root)

    with tempfile.TemporaryDirectory() as tmp:
        caches_root = Path(tmp) / "caches"
        started = time.perf_counter()
        first, manifest_a, result = run_conversion(root, missions, caches_root,
                                                   language)
        elapsed = time.perf_counter() - started
        second, manifest_b, _ = run_conversion(root, missions, caches_root,
                                               language)

        c.expect("determinism.inventory", _inventory_map(manifest_a),
                 _inventory_map(manifest_b),
                 f"{len(manifest_a['inventory'])} files, byte-identical")
        c.expect("determinism.cache_id", manifest_a["cache_id"],
                 manifest_b["cache_id"])
        c.expect("determinism.sources", manifest_a["sources"],
                 manifest_b["sources"],
                 f"{len(manifest_a['sources'])} source files fingerprinted")
        c.check("manifest.no_timestamp",
                "time" not in cachemod.dumps(manifest_a).lower()
                or "runtime" in cachemod.dumps(manifest_a).lower(),
                "the manifest records no clock reading")
        c.expect("manifest.edition", manifest_a["edition"] is not None, True,
                 str(manifest_a["edition"]))
        c.expect("manifest.language", manifest_a["language"], language)
        c.check("conversion.covers_missions",
                sorted(result.missions) == sorted(missions),
                ", ".join(result.missions))

        # Every file the converter read is declared, and nothing else.
        declared = set(manifest_a["sources"])
        c.check("sources.closed", all((root / rel).is_file() for rel in declared),
                f"{len(declared)} declared source files all exist")

        check_against_as_dict(c, root, first.root, missions)
        check_bodies(c, root, first.root, missions)
        check_fonts(c, first.root)
        check_audio(c, root, first.root, True)
        check_campaign(c, root, first.root)
        check_sequences(c, root, first.root)
        c.expect("bodies.cross_set_identical",
                 [w for w in result.warnings if "differs between" in w], [],
                 "unit meshes are the same geometry in every world set")

        published, created = cachemod.publish(first, caches_root, manifest_a)
        c.check("publish.created", created, published.name)
        c.expect("publish.verifies", cachemod.verify_cache(published), [])
        second.discard()
        c.check("publish.no_staging_left",
                not any(p.name.startswith(cachemod.STAGING_PREFIX)
                        for p in caches_root.iterdir()),
                "no staging directory survives a completed run")
        size = sum(p.stat().st_size for p in published.rglob("*") if p.is_file())
        c.check("cache.size_with_music", size / 1024 <= CACHE_CEILING_KIB_MUSIC,
                f"{size / 1024:.0f} KiB <= {CACHE_CEILING_KIB_MUSIC} KiB")
        LOG.info("conversion of %d missions took %.2fs and produced %.0f KiB",
                 len(missions), elapsed, size / 1024)

        # The same conversion without music: the flag has to change the cache
        # and nothing else, and the silent ceiling is what makes "95 % of the
        # growth is music" a measurement rather than a claim.
        silent, silent_manifest, _ = run_conversion(root, missions, caches_root,
                                                    language, music=False)
        check_audio(c, root, silent.root, False)
        check_sequences(c, root, silent.root, music=False)
        silent_size = sum(p.stat().st_size for p in silent.root.rglob("*")
                          if p.is_file())
        c.check("cache.size_without_music",
                silent_size / 1024 <= CACHE_CEILING_KIB_SILENT,
                f"{silent_size / 1024:.0f} KiB <= {CACHE_CEILING_KIB_SILENT} KiB")
        # The flag changes the music files and nothing else: every path in
        # one cache and not the other is under `audio/music/`, and the two
        # tables that record the flag are the only shared files that differ.
        def _files(base: Path) -> dict[str, int]:
            return {p.relative_to(base).as_posix(): p.stat().st_size
                    for p in base.rglob("*") if p.is_file()
                    and p.name not in (cachemod.MANIFEST_NAME,
                                       cachemod.STAGING_MARKER)}
        with_music = _files(published)
        without = _files(silent.root)
        only_one = sorted(set(with_music) ^ set(without))
        c.expect("cache.music_is_the_difference",
                 [p for p in only_one if not p.startswith("audio/music/")], [],
                 f"{len(only_one)} files differ between the two caches, all "
                 f"music; {size / 1024:.0f} KiB with, "
                 f"{silent_size / 1024:.0f} KiB without")
        c.expect("cache.flag_touches_two_tables",
                 sorted(p for p in set(with_music) & set(without)
                        if with_music[p] != without[p]),
                 ["tables/frontend.json", "tables/sound.json"],
                 "the two documents that record which cache this is")
        c.expect("cache.music_recorded",
                 (manifest_a["music"], silent_manifest["music"]), (True, False),
                 "the manifest says which of the two caches it is")
        silent.discard()
    return c.report()


#: The whole campaign set: 75 missions, the two campaign maps and the 15
#: upgrade screens.  It is behind its own flag rather than in `--check`
#: because `--check` runs **three** full conversions and this set is fifteen
#: times the slice -- 26 s and 86 MiB against 4 s and 42 MiB (docs/98).
CAMPAIGN_MAP_GLOBS = ("_C_*.lev", "upgrade_*.lev")
#: What a full bake must reach, measured: nine world sets and 31 distinct
#: scenes across 92 maps.
CAMPAIGN_WORLD_SETS = 9
CAMPAIGN_MAPS = 92
#: The full bake's own ceiling.  Measured at 85.9 MiB before 2026-09-08 and
#: at 199.5 MiB (204263 KiB, 30 s -- 57 s before the decode memo of 2026-09-09)
#: after the cutscenes, the voice-overs and
#: the eleven cutscene tracks joined every selection; this is that plus the
#: same headroom the slice ceilings carry (see :data:`CACHE_CEILING_KIB_MUSIC`).
CAMPAIGN_CEILING_KIB = 210 * 1024


def campaign_map_set(root: Path) -> list[str]:
    """Every map the campaign can load, in one sorted list."""
    names: set[str] = set()
    for pattern in CAMPAIGN_MAP_GLOBS:
        names |= {p.stem for p in (root / "Missions").glob(pattern)}
    return sorted(names)


def missions_from_args(root: Path | None, campaign_maps: bool,
                       missions: str | None) -> list[str]:
    """The mission list a command line asks for.

    ``--campaign-maps`` is the whole campaign -- the same set
    :func:`campaign_map_set` gives ``--check-campaign`` -- and replaces
    ``--missions`` rather than adding to it; without either, the six the
    slices need.  It is a separate function so ``--check`` can pin all three
    answers without a conversion behind them.
    """
    if campaign_maps:
        assert root is not None, "--campaign-maps is refused without a root"
        return campaign_map_set(root)
    text = ",".join(SLICE_MISSIONS) if missions is None else missions
    chosen = [name.strip() for name in text.split(",") if name.strip()]
    return chosen + [n for n in CAMPAIGN_FRAME_MAPS if n not in chosen]


def run_campaign_checks(root: Path, language: str) -> int:
    """One full bake of every campaign map -- D9.

    `--check`'s job is that the pipeline is deterministic and correct; this
    one's is that the **whole** campaign converts at all, which is a different
    question and fifteen times the work.  So it converts once.
    """
    c = Checker()
    if not (root / "Missions").is_dir():
        c.check("root", False, f"no Missions/ under {root}")
        return c.report()
    missions = campaign_map_set(root)
    c.expect("campaign_bake.map_count", len(missions), CAMPAIGN_MAPS,
             "75 campaign missions, two campaign maps, 15 upgrade screens")

    with tempfile.TemporaryDirectory() as tmp:
        caches_root = Path(tmp) / "caches"
        started = time.perf_counter()
        staged, manifest, result = run_conversion(root, missions, caches_root,
                                                  language)
        elapsed = time.perf_counter() - started
        c.check("campaign_bake.converts",
                sorted(result.missions) == missions,
                f"{len(result.missions)} maps in {elapsed:.1f}s")
        c.expect("campaign_bake.world_sets", len(result.world_sets),
                 CAMPAIGN_WORLD_SETS)
        scenes = set()
        for name in missions:
            document = json.loads(
                (staged.root / "missions" / name / "map.json").read_text())
            header = document["header"]
            scenes.add((header["world_set"], header["world_scene"]))
        c.check("campaign_bake.scenes", len(scenes) >= 31,
                f"{len(scenes)} distinct (world set, scene) pairs")

        # Nothing may be missing: a campaign that cannot load one of its own
        # maps is not a campaign.
        missing = [w for w in result.warnings if "absent from prototyp.din" in w]
        c.expect("campaign_bake.no_missing_prototypes", missing, [])
        check_campaign(c, root, staged.root)
        check_sequences(c, root, staged.root)

        size = sum(p.stat().st_size for p in staged.root.rglob("*")
                   if p.is_file())
        c.check("campaign_bake.size", size / 1024 <= CAMPAIGN_CEILING_KIB,
                f"{size / 1024:.0f} KiB <= {CAMPAIGN_CEILING_KIB} KiB")
        c.expect("campaign_bake.manifest_language", manifest["language"],
                 language)
        staged.discard()
    return c.report()


def _cache_race_worker(out: str, entered: Any, release: Any,
                       staging_path: Any, finished: Any, hold: bool) -> None:
    """Drive the production publish path with a tiny conversion in a process.

    A process is required: advisory file locks are process-scoped, so threads
    cannot reproduce two converter CLIs contending for the same destination.
    """
    global run_conversion

    def tiny_conversion(root: Path, _missions: list[str], caches_root: Path,
                        language: str, _music: bool = True) \
            -> tuple[cachemod.Staging, dict[str, Any], Any]:
        staging = cachemod.Staging.create(caches_root)
        staging.write_json("tables/race.json", {"complete": True})
        entered.set()
        if hold:
            staging_path.put(str(staging.root))
            release.wait(5.0)
        reader = cachemod.SourceReader(root=root)
        manifest = cachemod.build_manifest(
            reader, cachemod.build_inventory(staging), language, [])
        result = SimpleNamespace(missions=[], prototypes=0, textures=0,
                                 waves=0, tracks=0, warnings=[])
        return staging, manifest, result

    run_conversion = tiny_conversion
    try:
        code = convert_and_publish(Path(out) / "game", [], Path(out) / "caches",
                                   "English")
        finished.put(("ok", code))
    except Exception as exc:  # pragma: no cover - reported by the parent check
        finished.put(("error", str(exc)))


def run_cache_checks() -> int:
    """The two cache properties of docs/92 §10.4, on a temporary directory."""
    c = Checker()
    with tempfile.TemporaryDirectory() as tmp:
        caches_root = Path(tmp) / "caches"
        staging = cachemod.Staging.create(caches_root)
        staging.write_json("tables/balance.json", {"schema": "test", "rows": []})
        staging.write_bytes("data/blob.bin", b"0123456789")
        inventory = cachemod.build_inventory(staging)
        reader = cachemod.SourceReader(root=Path(tmp))
        manifest = cachemod.build_manifest(reader, inventory, "English", [])
        good, created = cachemod.publish(staging, caches_root, manifest)
        cachemod.set_active(caches_root, manifest["cache_id"])
        c.check("cache.published", created, good.name)
        c.expect("cache.verifies", cachemod.verify_cache(good), [])

        # A partial cache is never accepted: truncate one declared file.
        partial = cachemod.Staging.create(caches_root)
        partial.write_bytes("data/blob.bin", b"0123456789")
        partial_inventory = cachemod.build_inventory(partial)
        (partial.root / "data" / "blob.bin").write_bytes(b"012")
        partial_manifest = cachemod.build_manifest(
            reader, partial_inventory, "English", [])
        (partial.root / cachemod.MANIFEST_NAME).write_bytes(
            cachemod.dumps(partial_manifest).encode("utf-8"))
        c.check("cache.partial_refused",
                bool(cachemod.verify_cache(partial.root)),
                "; ".join(cachemod.verify_cache(partial.root)))
        try:
            cachemod.publish(partial, caches_root, partial_manifest)
            published_partial = True
        except cachemod.CacheError:
            published_partial = False
        c.check("cache.partial_not_published", not published_partial,
                "publish() validates before it renames")

        # A failed update leaves the previous cache intact and still pointed at.
        broken = cachemod.Staging.create(caches_root)
        broken.write_bytes("data/blob.bin", b"whatever")
        broken.files["data/missing.bin"] = "declared but never written"
        try:
            cachemod.build_inventory(broken)
            failed = False
        except cachemod.CacheError:
            failed = True
        broken.discard()
        c.check("cache.update_failed", failed,
                "a declared output that was never written is caught")
        c.expect("cache.survivor", cachemod.verify_cache(good), [],
                 "the previous cache is still complete")
        pointer = cachemod.read_active(caches_root)
        c.expect("cache.pointer", pointer and pointer["cache_id"],
                 manifest["cache_id"],
                 "and is still the one active.json names")
        c.check("cache.staging_invisible",
                all(not p.name.startswith(cachemod.STAGING_PREFIX)
                    for p in cachemod.iter_published(caches_root)),
                "iter_published never lists a staging directory")

        # Different output is a different immutable cache, even when every
        # source byte is unchanged.  No live target has to be renamed away.
        again = cachemod.Staging.create(caches_root)
        again.write_json("tables/balance.json", {"schema": "test", "rows": []})
        again.write_bytes("data/blob.bin", b"9876543210")
        again_manifest = cachemod.build_manifest(
            reader, cachemod.build_inventory(again), "English", [])
        c.check("cache.output_changes_id",
                again_manifest["cache_id"] != manifest["cache_id"],
                "the inventory digest is part of the id")

        # Simulate death before the one directory rename.  The old target and
        # pointer must remain usable; there is no two-rename replacement window.
        original_replace = cachemod.os.replace
        cachemod.os.replace = lambda _src, _dst: (_ for _ in ()).throw(
            SystemExit("simulated process death"))
        try:
            try:
                cachemod.publish(again, caches_root, again_manifest)
            except SystemExit:
                pass
        finally:
            cachemod.os.replace = original_replace
        c.check("cache.crash_keeps_active_target", good.is_dir(),
                "the active directory was never moved")
        c.expect("cache.crash_keeps_pointer",
                 cachemod.read_active(caches_root)["cache_id"],
                 manifest["cache_id"])
        again.discard()

        replacement = cachemod.Staging.create(caches_root)
        replacement.write_json("tables/balance.json",
                               {"schema": "test", "rows": []})
        replacement.write_bytes("data/blob.bin", b"9876543210")
        replacement_manifest = cachemod.build_manifest(
            reader, cachemod.build_inventory(replacement), "English", [])
        published_new, _created = cachemod.publish(
            replacement, caches_root, replacement_manifest)
        c.expect("cache.new_verifies", cachemod.verify_cache(published_new), [])

        identical = cachemod.Staging.create(caches_root)
        identical.write_json("tables/balance.json",
                             {"schema": "test", "rows": []})
        identical.write_bytes("data/blob.bin", b"9876543210")
        identical_manifest = cachemod.build_manifest(
            reader, cachemod.build_inventory(identical), "English", [])
        identical_root = identical.root
        reused, reused_created = cachemod.publish(
            identical, caches_root, identical_manifest)
        c.expect("cache.identical_reuses_target", reused, published_new)
        c.check("cache.identical_not_created", not reused_created,
                "content-addressed target already exists")
        c.check("cache.identical_staging_discarded", not identical_root.exists(),
                "the redundant staging tree is removed")

        # This is the stale interleaving from two converters: A wants to keep
        # the old id after B has activated the new one.  Collection must protect
        # the pointer it reads, independently of A's stale `keep` argument.
        cachemod.set_active(caches_root, replacement_manifest["cache_id"])
        cachemod.collect(caches_root, manifest["cache_id"])
        c.check("cache.concurrent_active_survives", published_new.is_dir(),
                "collection never deletes the cache active.json names")

        # `collect` removes only what this converter published.  It used to
        # remove every subdirectory it found, which turns a mistyped `-o` into
        # data loss.
        (caches_root / "someone_elses_photos").mkdir()
        (caches_root / "someone_elses_photos" / "keep.txt").write_bytes(b"hi")
        foreign_staging = caches_root / ".incubation-staging-family-photos"
        foreign_staging.mkdir()
        (foreign_staging / "keep.jpg").write_bytes(b"family")
        removed = cachemod.collect(caches_root,
                                   replacement_manifest["cache_id"])
        c.check("cache.collect_spares_strangers",
                (caches_root / "someone_elses_photos" / "keep.txt").is_file(),
                "a directory without one of our manifests is left alone")
        c.check("cache.collect_spares_foreign_staging",
                (foreign_staging / "keep.jpg").is_file(),
                "a name prefix without our exact UUID and marker is not ownership")
        c.expect("cache.collect_removed_old_cache", removed,
                 [manifest["cache_id"]],
                 "only the old published cache is collected")

        # Two production conversions to one destination are serialized before
        # either creates staging. With the old lock boundary the second one
        # entered conversion, published, and collected the first one's live
        # tree while it was still being written.
        race_root = Path(tmp) / "race"
        (race_root / "game").mkdir(parents=True)
        context = multiprocessing.get_context("spawn")
        first_entered = context.Event()
        release_first = context.Event()
        first_path = context.Queue()
        finished = context.Queue()
        first = context.Process(target=_cache_race_worker,
                                args=(str(race_root), first_entered,
                                      release_first, first_path, finished, True))
        first.start()
        first_ready = first_entered.wait(3.0)
        live_staging = Path(first_path.get(timeout=3.0)) if first_ready else None
        second_entered = context.Event()
        unused_release = context.Event()
        unused_path = context.Queue()
        second = context.Process(target=_cache_race_worker,
                                 args=(str(race_root), second_entered,
                                       unused_release, unused_path, finished,
                                       False))
        second.start()
        second_waited = not second_entered.wait(0.25)
        c.check("cache.concurrent_conversion_waits_before_staging",
                first_ready and second_waited,
                "the second converter entered before the first released")
        c.check("cache.concurrent_conversion_keeps_live_staging",
                live_staging is not None and live_staging.is_dir(),
                "another converter collected the active staging directory")
        release_first.set()
        first.join(5.0)
        second.join(5.0)
        outcomes = [finished.get(timeout=3.0), finished.get(timeout=3.0)] \
            if not first.is_alive() and not second.is_alive() else []
        c.expect("cache.concurrent_conversions_finish",
                 sorted(outcomes), [("ok", 0), ("ok", 0)])
        if first.is_alive():
            first.terminate()
        if second.is_alive():
            second.terminate()
        first.join()
        second.join()

        # And two destinations are refused outright rather than collected from.
        for destination, why in ((Path("gog_incubation"), "the game root"),
                                 (Path(__file__).resolve().parent,
                                  "this repository")):
            try:
                refuse_unsafe_output(Path("gog_incubation"), destination)
                refused = False
            except cachemod.CacheError:
                refused = True
            c.check("cache.refuses_%s" % destination.name, refused, why)

        game = Path(tmp) / "game"
        (game / "cache").mkdir(parents=True)
        sentinel = game / "cache" / "user-save.bin"
        sentinel.write_bytes(b"keep")
        try:
            dev_fixtures(game, [], game, "English")
            dev_refused = False
        except cachemod.CacheError:
            dev_refused = True
        c.check("cache.dev_fixtures_refuses_game", dev_refused,
                "development output obeys the read-only installation boundary")
        c.check("cache.dev_fixtures_keeps_existing", sentinel.is_file(),
                "the refusal happens before cache/ or inspect/ is removed")

        # A *legal* output root that already holds somebody's `cache/` or
        # `inspect/`.  The game-root refusal above does not cover it, and
        # `--dev-fixtures` used to `rmtree` both by name with no ownership
        # test at all -- the same shape of data loss `collect` was hardened
        # against in this very change, one function over.
        for name, note in (("cache", "a cache directory that is not ours"),
                           (EYE_DIR, "an inspect directory that is not ours")):
            elsewhere = Path(tmp) / f"dev-{name}"
            (elsewhere / name).mkdir(parents=True)
            theirs = elsewhere / name / "not-ours.txt"
            theirs.write_bytes(b"somebody's data")
            try:
                dev_fixtures(Path("gog_incubation"), [], elsewhere, "English")
                refused = False
            except cachemod.CacheError:
                refused = True
            c.check(f"cache.dev_fixtures_refuses_foreign_{name}", refused, note)
            c.check(f"cache.dev_fixtures_keeps_foreign_{name}",
                    theirs.is_file() and theirs.read_bytes() == b"somebody's data",
                    "and the data is still there afterwards")

        # An empty directory made by hand is the ordinary first run, and must
        # not be refused -- otherwise the guard above is unusable.
        empty_root = Path(tmp) / "dev-empty"
        (empty_root / "cache").mkdir(parents=True)
        (empty_root / EYE_DIR).mkdir(parents=True)
        try:
            _refuse_unowned(empty_root / "cache", cachemod.is_cache_dir, "")
            _refuse_unowned(empty_root / EYE_DIR, _is_eye_dir, "")
            empty_ok = True
        except cachemod.CacheError:
            empty_ok = False
        c.check("cache.dev_fixtures_takes_over_empty", empty_ok,
                "an empty directory made by hand before the first run is not "
                "somebody's data")

        # An unknown schema version is refused by name.
        stale = dict(replacement_manifest)
        stale["cache_schema_version"] = cachemod.CACHE_SCHEMA_VERSION + 1
        (published_new / cachemod.MANIFEST_NAME).write_bytes(
            cachemod.dumps(stale).encode("utf-8"))
        problems = cachemod.verify_cache(published_new)
        c.check("cache.schema_refused",
                any("cache schema" in p for p in problems),
                "; ".join(problems))
    return c.report()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", nargs="?", type=Path,
                    help="a read-only game installation")
    ap.add_argument("-o", "--out", type=Path,
                    help="the caches directory to publish into")
    ap.add_argument("--missions", type=str, default=None,
                    help="comma-separated mission names (default: the six the "
                         "slices need)")
    ap.add_argument("--campaign-maps", action="store_true",
                    help="every map the campaign can load -- 75 missions, two "
                         "campaign maps and 15 upgrade screens -- instead of "
                         "--missions")
    ap.add_argument("--language", default=cachemod.DEFAULT_LANGUAGE,
                    help="source language; part of the cache id (docs/92 §7.6)")
    ap.add_argument("--dev-fixtures", type=Path,
                    help="also materialise res://generated/ fixtures here")
    ap.add_argument("--check", action="store_true",
                    help="two conversions, the as_dict oracle, PNG stability")
    ap.add_argument("--check-cache", action="store_true",
                    help="partial cache refused, valid cache survives failure")
    ap.add_argument("--check-campaign", action="store_true",
                    help="bake every campaign map once and check the result")
    ap.add_argument("--no-music", dest="music", action="store_false",
                    help="leave the CD-audio tracks out of the cache; they are "
                         "most of its size and none of its rules")
    ap.set_defaults(music=True)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    if args.campaign_maps and args.missions is not None:
        ap.error("--campaign-maps replaces --missions; give one of them")
    if args.campaign_maps and args.root is None:
        ap.error("--campaign-maps needs the game root, to list its Missions/")
    missions = missions_from_args(args.root, args.campaign_maps, args.missions)

    try:
        if args.check_cache:
            return run_cache_checks()
        if args.check_campaign:
            if args.root is None:
                ap.error("--check-campaign needs the game root")
            return run_campaign_checks(args.root, args.language)
        if args.check:
            if args.root is None:
                ap.error("--check needs the game root")
            return run_checks(args.root, missions, args.language)
        if args.root is None:
            ap.print_help()
            return 2
        if args.dev_fixtures:
            return dev_fixtures(args.root, missions, args.dev_fixtures,
                                args.language, args.music)
        if args.out is None:
            ap.error("give -o, the caches directory to publish into")
        return convert_and_publish(args.root, missions, args.out, args.language,
                                   args.music)
    except (ConvertError, cachemod.CacheError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
