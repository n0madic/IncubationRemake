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
import json
import logging
import shutil
import sys
import tempfile
import time
import zlib
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import lev_parse  # noqa: E402
from inclib import cache as cachemod  # noqa: E402
from inclib.check import Checker  # noqa: E402
from inclib.convert import ConvertError, convert, mission_path  # noqa: E402
from inclib.lev import load_lev  # noqa: E402
from inclib import prototyp as protomod  # noqa: E402
from inclib.binio import ParseError  # noqa: E402

LOG = logging.getLogger("remake_convert")

#: The missions the two slices need (docs/92 §10, docs/93, docs/94).  `_C_140`
#: is the second slice's demonstration mission -- the first playable one, whose
#: squad and aliens are both in the `.lev` and which is *won by moving*;
#: `_C_115` is what the first slice rendered; `_C_141` is where the native
#: oracle is taken, because it is the mission the slot-6 save is on; `_C_100`
#: is the second entry that keeps determinism honest across two maps sharing a
#: world set and scene with `_C_141`.
SLICE_MISSIONS = ["_C_140", "_C_115", "_C_141", "_C_100"]

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
                   language: str) -> tuple[cachemod.Staging,
                                           dict[str, Any], Any]:
    """Convert into a fresh staging directory and build its manifest."""
    reader = _reader(root)
    staging = cachemod.Staging.create(caches_root)
    try:
        result = convert(root, missions, staging, reader, language)
    except Exception:
        staging.discard()
        raise
    inventory = cachemod.build_inventory(staging)
    manifest = cachemod.build_manifest(
        reader, inventory, language, result.warnings,
        {"missions": result.missions, "world_sets": result.world_sets,
         "prototypes": result.prototypes, "textures": result.textures,
         "text_entries": result.text_entries})
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
                        language: str) -> int:
    refuse_unsafe_output(root, out)
    caches_root = out
    started = time.perf_counter()
    staging, manifest, result = run_conversion(root, missions, caches_root,
                                               language)
    try:
        with cachemod.publish_lock(caches_root):
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
    LOG.info("missions %s, %d prototypes, %d textures",
             ", ".join(result.missions), result.prototypes, result.textures)
    for warning in manifest["warnings"]:
        LOG.warning("%s", warning)
    if removed:
        LOG.info("collected %d older cache(s)", len(removed))
    return 0


def dev_fixtures(root: Path, missions: list[str], out: Path,
                 language: str) -> int:
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
    staging, manifest, _result = run_conversion(root, missions, out, language)
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
        c.expect(f"beyond.{name}.geometry_complete",
                 geometry.get("missing", []), [],
                 "every prototype the placements name was found")
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


def run_checks(root: Path, missions: list[str], language: str) -> int:
    c = Checker()
    if not (root / "Missions").is_dir():
        c.check("root", False, f"no Missions/ under {root}")
        return c.report()
    check_png_stability(c)

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

        published, created = cachemod.publish(first, caches_root, manifest_a)
        c.check("publish.created", created, published.name)
        c.expect("publish.verifies", cachemod.verify_cache(published), [])
        second.discard()
        c.check("publish.no_staging_left",
                not any(p.name.startswith(cachemod.STAGING_PREFIX)
                        for p in caches_root.iterdir()),
                "no staging directory survives a completed run")
        size = sum(p.stat().st_size for p in published.rglob("*") if p.is_file())
        LOG.info("conversion of %d missions took %.2fs and produced %.0f KiB",
                 len(missions), elapsed, size / 1024)
    return c.report()


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
    ap.add_argument("--missions", type=str,
                    default=",".join(SLICE_MISSIONS),
                    help="comma-separated mission names")
    ap.add_argument("--language", default=cachemod.DEFAULT_LANGUAGE,
                    help="source language; part of the cache id (docs/92 §7.6)")
    ap.add_argument("--dev-fixtures", type=Path,
                    help="also materialise res://generated/ fixtures here")
    ap.add_argument("--check", action="store_true",
                    help="two conversions, the as_dict oracle, PNG stability")
    ap.add_argument("--check-cache", action="store_true",
                    help="partial cache refused, valid cache survives failure")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    missions = [m for m in args.missions.split(",") if m.strip()]

    try:
        if args.check_cache:
            return run_cache_checks()
        if args.check:
            if args.root is None:
                ap.error("--check needs the game root")
            return run_checks(args.root, missions, args.language)
        if args.root is None:
            ap.print_help()
            return 2
        if args.dev_fixtures:
            return dev_fixtures(args.root, missions, args.dev_fixtures,
                                args.language)
        if args.out is None:
            ap.error("give -o, the caches directory to publish into")
        return convert_and_publish(args.root, missions, args.out, args.language)
    except (ConvertError, cachemod.CacheError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
