#!/usr/bin/env python3
"""Corpus validator for the Eng3d ``.3DW`` / ``.dir`` / ``.din`` formats.

Parses every ``.3DW``, ``.dir`` and ``.din`` file under the game data tree and
cross-checks the ASCII directory against its binary companion and against the
container it addresses (``prototyp.bin`` / ``texture.lib``).

Checks performed
----------------
3DW
  * strict grammar parse
  * every ``[GRP]`` member is used by a ``[CLO]`` and vice versa
  * every ``PROTOTYP`` reference resolves in the world set's ``prototyp.dir``

dir vs din
  * identical entry count, identical names, identical order
  * ``.dir`` index column equals the 0-based row position
  * texture: ``.dir`` offset/size equal ``.din`` offset/size

prototyp.bin addressing
  * offsets strictly increasing and inside the container
  * ``.dir`` column 4 equals the first ``u32`` of the record at that offset

texture.lib addressing
  * offsets strictly increasing, entries tile the container with no gaps
  * last entry ends exactly at EOF
  * ``VISN`` magic probe at every entry offset

engine capacity limits (compiled into Eng3d.dll, see docs 4.1 / 4.2)
  * prototyp: record count <= 2499, name length <= 65535
  * texture: record count <= 300

Usage::

    python3 tools/verify_3d_indices.py [--root gog_incubation] [-v]
"""

from __future__ import annotations

import argparse
import importlib.util
import logging
import os
import struct
import sys
from typing import Any, Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import eng3d, prototyp  # noqa: E402
from inclib.binio import ParseError  # noqa: E402
from inclib.eng3d import Eng3dError  # noqa: E402
from inclib.lev import FACING_ANGLES, FACING_STEPS, load_lev  # noqa: E402

LOG = logging.getLogger("verify3d")

_TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))


def _load(module_name: str, filename: str) -> Any:
    """Import a sibling tool module (needed because ``3dw_parse`` is not an identifier)."""
    spec = importlib.util.spec_from_file_location(module_name, os.path.join(_TOOLS_DIR, filename))
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        raise ImportError(filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


w3dw = _load("w3dw_parse", "3dw_parse.py")
dir3di = _load("dir3di_parse", "dir3di_parse.py")
din = _load("din_parse", "din_parse.py")

VISN_MAGIC = b"VISN"


class Stats:
    """Accumulates pass/fail counters and failure messages."""

    def __init__(self) -> None:
        self.counters: dict[str, list[int]] = {}
        self.failures: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        passed, total = self.counters.setdefault(name, [0, 0])
        total += 1
        if ok:
            passed += 1
        else:
            self.failures.append(f"[{name}] {detail}")
        self.counters[name] = [passed, total]
        return ok

    def report(self) -> None:
        width = max((len(k) for k in self.counters), default=0)
        for name in sorted(self.counters):
            passed, total = self.counters[name]
            flag = "OK " if passed == total else "FAIL"
            print(f"  {flag} {name.ljust(width)}  {passed}/{total}")


def find_files(root: str, suffix: str) -> list[str]:
    """Return every file under *root* whose name ends with *suffix* (case-insensitive)."""
    out: list[str] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fname in filenames:
            if fname.lower().endswith(suffix):
                out.append(os.path.join(dirpath, fname))
    return sorted(out)


def sibling(path: str, new_suffix: str) -> str | None:
    """Find a sibling file with the same stem and *new_suffix*, ignoring case."""
    directory = os.path.dirname(path)
    stem = os.path.splitext(os.path.basename(path))[0].lower()
    want = stem + new_suffix.lower()
    try:
        for fname in os.listdir(directory):
            if fname.lower() == want:
                return os.path.join(directory, fname)
    except OSError:
        return None
    return None


def verify_3dw(root: str, stats: Stats, notes: list[str],
                stale: list[str] | None = None) -> int:
    """Parse and validate every ``.3DW`` under *root*."""
    paths = find_files(root, ".3dw")
    proto_dirs = [p for p in find_files(root, ".dir") if "prototyp" in os.path.basename(p).lower()]
    names_cache: dict[str, set[str]] = {}
    for proto_path in proto_dirs:
        try:
            names_cache[proto_path] = {e["name"] for e in dir3di.parse_dir(proto_path)["entries"]}
        except ParseError as exc:  # pragma: no cover - dir.parse reports this too
            LOG.error("%s", exc)
            names_cache[proto_path] = set()
    all_proto_names: set[str] = set().union(*names_cache.values()) if names_cache else set()

    for path in paths:
        try:
            world = w3dw.parse_3dw(path, strict=True)
        except ParseError as exc:
            stats.check("3dw.parse", False, str(exc))
            continue
        stats.check("3dw.parse", True)

        clone_names = [c["name"] for c in world.clones]
        stats.check(
            "3dw.grp_matches_clo",
            world.group_members == clone_names,
            f"{path}: [GRP] members differ from [CLO] order/content",
        )
        stats.check(
            "3dw.clo_name_eq_prototyp",
            all(c["name"] == c.get("prototyp") for c in world.clones),
            f"{path}: some [CLO] name differs from its PROTOTYP value",
        )

        # PROTOTYP references should resolve in the owning world set's directory.
        world_root = os.path.dirname(os.path.dirname(path))
        local = [p for p in proto_dirs if os.path.normpath(p).startswith(os.path.normpath(world_root) + os.sep)]
        if not local:
            stats.check("3dw.proto_dir_present", False, f"{path}: no prototyp.dir in {world_root}")
            continue
        stats.check("3dw.proto_dir_present", True)

        wanted = {c["prototyp"] for c in world.clones}
        known: set[str] = set().union(*(names_cache[p] for p in local))
        missing = sorted(wanted - known)
        if missing:
            # Not a parser failure: the shipped data contains stale worlds whose
            # geometry lives in a different world set.  Reported as a note.
            elsewhere = not (set(missing) - all_proto_names)
            if stale is not None:
                stale.append(path)
            notes.append(
                f"{path}: {len(missing)} PROTOTYP names absent from its own world set "
                f"(resolvable in another world set: {elsewhere}); e.g. {missing[:3]}"
            )
        stats.check(
            "3dw.proto_refs_resolve_anywhere",
            not (set(missing) - all_proto_names),
            f"{path}: prototypes unknown to every prototyp.dir: "
            f"{sorted(set(missing) - all_proto_names)[:5]}",
        )
    return len(paths)


#: the one (world set, scene) a shipped ``.lev`` names for which no ``.3DW``
#: exists -- ``_I_001.lev``, a 07/02/97 development leftover that nothing
#: chains to and no binary names.  See docs/30 §8.
DANGLING_SCENES = [("Z00", "LOGOWALL")]


def world_key(path: str) -> tuple[str, str]:
    """``…/WorldSet/World_A00/Worlds/LEVEL03A.3DW`` -> ``("A00", "LEVEL03A")``."""
    world_dir = os.path.basename(os.path.dirname(os.path.dirname(path)))
    scene = os.path.splitext(os.path.basename(path))[0]
    prefix = "World_"
    if world_dir.startswith(prefix):
        world_dir = world_dir[len(prefix):]
    return world_dir.upper(), scene.upper()


def verify_stale_worlds(root: str, stats: Stats, stale: list[str]) -> int:
    """Is a ``.3DW`` whose prototypes live elsewhere ever loaded?

    Every mission header names a world set and a scene ([`10` §3]), so the set
    of scenes the shipping game can load is enumerable.  A ``.3DW`` that
    resolves its prototypes only in *another* world set is a stale copy if and
    only if no mission names it -- and that is what this asserts, with every
    mission-referenced scene resolving locally as the positive control.
    """
    missions = find_files(root, ".lev")
    if not missions:
        stats.check("stale.corpus", False, f"no .lev files under {root!r}")
        return 0
    stats.check("stale.corpus", True, f"{len(missions)} missions")

    referenced: set[tuple[str, str]] = set()
    for path in missions:
        try:
            battle = load_lev(path)
        except Exception as exc:  # noqa: BLE001 - lev_parse reports this too
            stats.check("stale.lev_parse", False, f"{path}: {exc}")
            continue
        referenced.add((battle.world_set.upper(), battle.world_scene.upper()))

    for path in stale:
        key = world_key(path)
        stats.check(
            "stale.unreferenced", key not in referenced,
            f"{path}: mission headers do name {key[0]}/{key[1]}")

    scenes = {world_key(p) for p in find_files(root, ".3dw")}
    stale_keys = {world_key(p) for p in stale}
    missing = sorted(referenced - scenes)
    stats.check("stale.dangling_scene_refs", missing == DANGLING_SCENES,
                f"missions naming a scene with no .3DW: {missing} "
                f"(expected {DANGLING_SCENES})")
    overlap = sorted(referenced & stale_keys)
    stats.check("stale.no_referenced_world_is_stale", not overlap,
                f"a referenced scene resolves only in another world set: {overlap}")
    return len(stale)


#: Prototype render opcodes that turn a part by a rotation triple, and the
#: matrix builder each reaches inside ``Eng3d.dll``.  Two of the builders
#: negate their angles before indexing the sine table and one does not, so
#: *which* opcode carries a placed object's heading decides which way the
#: world turns -- it cannot be assumed.  ``+0x411A59`` is the single-angle
#: builder that opcodes 9 and 10 branch into when the first two components of
#: the triple are zero (``or ax, cx / je``), and it agrees with ``+0x411BF6``
#: on a pure yaw.
ROTATION_OPCODES = {
    8: "+0x41204F, one angle",  # joint_rotate_1 (+0x405FCD)
    9: "+0x411A59 + +0x41204F fast path, else +0x411BF6",   # joint_rotate_3
    10: "+0x411A59 + +0x41204F fast path, else +0x411A93",  # joint_rotate_3_alt
    13: "+0x411BF6, first component only",  # matrix_from_angle
    14: "+0x411BF6",  # matrix_from_angles_b
    15: "+0x411A93",  # matrix_from_angles -- the one that does not negate
    18: "+0x411BF6",  # joint_place
}

#: The opcodes whose **pure-yaw** path answers the same rotation as
#: ``_E3D_init_matrix_RzRxRy``, which is what ``WorldSpace.yaw_basis`` in the
#: remake reproduces.  Opcode 15 is absent on purpose: it goes straight to
#: ``_E3D_init_matrix_RyRxRz`` with no fast path, and a heading through it
#: would turn the other way.
#:
#: The fast path is worth reading rather than assuming.  ``+0x411A59`` writes
#: ``[[c, -s, 0], [s, c, 0], [0, 0, 1]]`` from the table **without** negating
#: the angle, and ``+0x41204F`` then composes the parent matrix with a Z
#: rotation it builds *again* from the same two tables and the same signs --
#: it does not read ``+0x411A59``'s output at all.  Both therefore answer what
#: ``+0x411BF6`` answers for a triple whose first two components are zero,
#: which is every shipped record.
NEGATING_FOR_A_PURE_YAW = {8, 9, 10, 13, 14, 18}

#: The one shipped special object whose prototype carries no rotation opcode at
#: anim offset 0 although its record has a heading; the engine draws it
#: unturned.  Named so that a second one is a failure rather than a shrug.
UNTURNED_YAWED_PROTOTYPES = {"L096EF00.3DI": 1}


def verify_object_rotations(root: str, stats: Stats) -> int:
    """How a placed object's heading reaches a matrix, over the whole corpus.

    A ``.lev`` object record carries its heading in the third component of the
    rotation triple at ``+0x20`` ([`10` §6]), and **nothing in the engine turns
    the object with it directly**: the triple is the fallback source the
    prototype's own render program reads when the object has no joint buffer
    (``mov esi, [ebx+0x1c] / jne / lea esi, [ebx+0x20]``, seven opcode handlers
    in ``Eng3d.dll``).  So the heading's sign is a property of *which opcode the
    prototype uses*, and that is what this measures rather than assumes.

    It is the corpus half of the remake's ``WorldSpace.yaw_basis``; the
    arithmetic half is ``test_effects.gd``'s comparison against the natively
    verified matrix builder.
    """
    missions = find_files(root, ".lev")
    containers = prototyp.find_containers(root)
    if not missions or not containers:
        stats.check("rotation.corpus", False,
                    f"no .lev or no prototyp container under {root!r}")
        return 0
    stats.check("rotation.corpus", True,
                f"{len(missions)} missions, {len(containers)} containers")

    #: prototype name -> the rotation opcodes its render program uses at anim
    #: offset 0, which is where the object record's own triple sits.
    at_zero: dict[str, set[int]] = {}
    for din_path, bin_path in containers:
        for proto in prototyp.load_container(din_path, bin_path):
            found = {c.op for c in proto.render_cmds
                     if c.op in ROTATION_OPCODES and c.operand == 0}
            at_zero.setdefault(proto.name.upper(), set()).update(found)

    unturned: dict[str, int] = {}
    yawed = 0
    for path in missions:
        try:
            battle = load_lev(path)
        except Exception as exc:  # noqa: BLE001 - lev_parse reports this too
            stats.check("rotation.lev_parse", False, f"{path}: {exc}")
            continue
        for rec in battle.special:
            name = rec.prototype_name(battle.world_set).upper()
            if not stats.check("rotation.prototype_resolves", name in at_zero,
                               f"{path}: {name} is in no container"):
                continue
            if rec.rotation[2] % 4096 == 0:
                continue
            yawed += 1
            ops = at_zero[name]
            if not ops:
                unturned[name] = unturned.get(name, 0) + 1
                continue
            stats.check(
                "rotation.heading_negates_the_angle",
                ops <= NEGATING_FOR_A_PURE_YAW,
                f"{path}: {name} turns its heading with opcode(s) "
                f"{sorted(ops)}, one of which does not negate")

    # The scene clones go through the same `Scenery` code path in the remake,
    # and they are **not** in the `.lev`: only their count is saved ([`10` §9
    # item 5), so they are read back out of the `.3DW` the header names.  Their
    # `ROTATION` is in sixteenths of an engine angle unit -- `fcn.00407640`
    # multiplies by 16 on the way into `+0x20` -- so a heading is any value the
    # multiply does not send to a whole turn.
    for path in find_files(root, ".3dw"):
        try:
            world = w3dw.parse_3dw(path, strict=True)
        except ParseError:
            continue  # 3dw.parse reports it
        for clone in world.clones:
            name = str(clone["prototyp"]).upper()
            if name not in at_zero:
                continue  # 3dw.proto_refs_resolve_anywhere reports it
            if (clone["rotation"][2] * 16) % 4096 == 0:
                continue
            yawed += 1
            ops = at_zero[name]
            if not ops:
                unturned[name] = unturned.get(name, 0) + 1
                continue
            stats.check(
                "rotation.heading_negates_the_angle",
                ops <= NEGATING_FOR_A_PURE_YAW,
                f"{path}: clone {name} turns its heading with opcode(s) "
                f"{sorted(ops)}, one of which does not negate")

    # And the ground lattice, which is 181 337 of the 194 105 records and one
    # prototype: `S003_00X.3DI`, the editor's cell marker.  One check, not
    # 181 337 of them, because the name is a constant of the converter.
    lattice = prototyp.LATTICE_PROTOTYPE.upper()
    stats.check("rotation.lattice_negates_the_angle",
                bool(at_zero.get(lattice)) and
                at_zero[lattice] <= NEGATING_FOR_A_PURE_YAW,
                f"the lattice marker {lattice} rotates with "
                f"{sorted(at_zero.get(lattice, ()))}")

    stats.check("rotation.corpus_has_headings", yawed > 0,
                f"{yawed} placed objects carry a heading")
    stats.check("rotation.unturned_are_the_known_ones",
                unturned == UNTURNED_YAWED_PROTOTYPES,
                f"prototypes with a heading and no rotation opcode at offset 0: "
                f"{unturned} (expected {UNTURNED_YAWED_PROTOTYPES})")

    # The other half of the same claim, and the one a screenshot cannot make:
    # `docs/10` §5.10's eight facing angles, turned by the engine's own matrix
    # builder, must send an object's authored +Y along the step the unit takes.
    # With the angle un-negated only facings 0 and 2 -- the two a sign cannot
    # move -- agree.  `eng3d.matrix3` is `_E3D_init_matrix_RzRxRy`, reproduced
    # 8/8 inside a running `Incubation.exe` (docs/97 §18.1).
    try:
        tables = eng3d.load(root)
    except (OSError, Eng3dError) as exc:
        stats.check("rotation.trig_tables", False, f"{exc}")
        return len(missions)
    stats.check("rotation.trig_tables", True)
    for facing, angle in sorted(FACING_ANGLES.items()):
        turned = eng3d.transform(eng3d.matrix3(tables, 0, 0, angle), (0, 1600, 0))
        sign = tuple((v > 40) - (v < -40) for v in turned[:2])
        stats.check("rotation.facing_points_the_step",
                    sign == FACING_STEPS[facing],
                    f"facing {facing} (angle {angle}) turns +Y to {sign}, "
                    f"walks {FACING_STEPS[facing]}")
    return len(missions)


def verify_pairs(root: str, stats: Stats) -> tuple[int, int]:
    """Validate every ``.dir``/``.din`` pair and its container."""
    dir_paths = find_files(root, ".dir")
    din_paths = find_files(root, ".din")
    seen_din: set[str] = set()

    for dir_path in dir_paths:
        try:
            parsed_dir = dir3di.parse_dir(dir_path)
        except ParseError as exc:
            stats.check("dir.parse", False, str(exc))
            continue
        stats.check("dir.parse", True)

        entries = parsed_dir["entries"]
        stats.check(
            "dir.index_is_row",
            all(e["index"] == i for i, e in enumerate(entries)),
            f"{dir_path}: index column is not the row position",
        )

        din_path = sibling(dir_path, ".din")
        if din_path is None:
            stats.check("din.paired", False, f"{dir_path}: no matching .din")
            continue
        stats.check("din.paired", True)
        seen_din.add(os.path.normpath(din_path))

        try:
            parsed_din = din.parse_din(din_path)
        except ParseError as exc:
            stats.check("din.parse", False, str(exc))
            continue
        stats.check("din.parse", True)

        stats.check(
            "pair.kind_matches",
            parsed_din["kind"] == parsed_dir["kind"],
            f"{dir_path}: dir kind {parsed_dir['kind']} vs din kind {parsed_din['kind']}",
        )
        stats.check(
            "pair.count_matches",
            len(entries) == parsed_din["count"],
            f"{dir_path}: {len(entries)} rows vs {parsed_din['count']} din records",
        )
        dir_names = [e["name"] for e in entries]
        din_names = [e["name"] for e in parsed_din["entries"]]
        stats.check(
            "pair.names_match",
            dir_names == din_names,
            f"{dir_path}: name/order mismatch (first diff at "
            f"{next((i for i, (a, b) in enumerate(zip(dir_names, din_names)) if a != b), 'n/a')})",
        )

        if parsed_dir["kind"] == dir3di.KIND_TEXTURE:
            _verify_texture(dir_path, entries, parsed_din, stats)
        else:
            _verify_prototyp(dir_path, entries, parsed_din, stats)

    for din_path in din_paths:
        if os.path.normpath(din_path) not in seen_din:
            stats.check("din.orphan", False, f"{din_path}: no matching .dir")
    return len(dir_paths), len(din_paths)


def _verify_texture(
    dir_path: str, entries: list[dict[str, Any]], parsed_din: dict[str, Any], stats: Stats
) -> None:
    lib_path = sibling(dir_path, ".lib")
    din_entries = parsed_din["entries"]

    stats.check(
        "texture.din_fits_engine_cap",
        parsed_din["count"] <= din.ENGINE_MAX_TEXTURE_RECORDS,
        f"{dir_path}: {parsed_din['count']} textures exceeds the engine cap "
        f"of {din.ENGINE_MAX_TEXTURE_RECORDS}",
    )
    stats.check(
        "texture.din_index_is_row",
        all(e["index"] == i for i, e in enumerate(din_entries)),
        f"{dir_path}: din index field is not the row position",
    )
    stats.check(
        "texture.dir_eq_din_offsets",
        all(a["offset"] == b["offset"] and a["size"] == b["size"]
            for a, b in zip(entries, din_entries)),
        f"{dir_path}: dir offset/size differ from din",
    )
    stats.check(
        "texture.offsets_increasing",
        all(entries[i]["offset"] < entries[i + 1]["offset"] for i in range(len(entries) - 1)),
        f"{dir_path}: offsets not strictly increasing",
    )
    stats.check(
        "texture.tiles_container",
        all(entries[i]["offset"] + entries[i]["size"] == entries[i + 1]["offset"]
            for i in range(len(entries) - 1)),
        f"{dir_path}: entries do not tile contiguously",
    )

    if lib_path is None or not os.path.exists(lib_path):
        stats.check("texture.lib_present", False, f"{dir_path}: no texture.lib")
        return
    stats.check("texture.lib_present", True)
    lib_size = os.path.getsize(lib_path)
    last = entries[-1]
    stats.check(
        "texture.covers_container",
        last["offset"] + last["size"] == lib_size,
        f"{dir_path}: last entry ends at {last['offset'] + last['size']}, lib is {lib_size}",
    )
    stats.check(
        "texture.first_offset_zero",
        entries[0]["offset"] == 0,
        f"{dir_path}: first entry offset is {entries[0]['offset']}, not 0",
    )

    with open(lib_path, "rb") as fh:
        blob = fh.read()
    magics = {blob[e["offset"]:e["offset"] + 4] for e in entries}
    stats.check(
        "texture.entry_magic_visn",
        magics == {VISN_MAGIC},
        f"{dir_path}: entry start magics = {sorted(m.hex() for m in magics)[:4]}",
    )


def _verify_prototyp(
    dir_path: str, entries: list[dict[str, Any]], parsed_din: dict[str, Any], stats: Stats
) -> None:
    bin_path = sibling(dir_path, ".bin")
    din_entries = parsed_din["entries"]

    over_long = [e["name"] for e in din_entries
                 if len(e["name"]) > din.ENGINE_MAX_PROTOTYP_NAME_LEN]
    stats.check(
        "prototyp.din_fits_engine_cap",
        parsed_din["count"] <= din.ENGINE_MAX_PROTOTYP_RECORDS and not over_long,
        f"{dir_path}: {parsed_din['count']} records (cap "
        f"{din.ENGINE_MAX_PROTOTYP_RECORDS}), {len(over_long)} over-long names",
    )
    stats.check(
        "prototyp.offsets_increasing",
        all(din_entries[i]["offset"] < din_entries[i + 1]["offset"]
            for i in range(len(din_entries) - 1)),
        f"{dir_path}: din offsets not strictly increasing",
    )
    stats.check(
        "prototyp.first_offset_zero",
        bool(din_entries) and din_entries[0]["offset"] == 0,
        f"{dir_path}: first din offset is not 0",
    )

    if bin_path is None or not os.path.exists(bin_path):
        stats.check("prototyp.bin_present", False, f"{dir_path}: no prototyp.bin")
        return
    stats.check("prototyp.bin_present", True)
    bin_size = os.path.getsize(bin_path)
    stats.check(
        "prototyp.offsets_in_range",
        all(0 <= e["offset"] + 4 <= bin_size for e in din_entries),
        f"{dir_path}: some din offset falls outside the {bin_size}-byte container",
    )

    with open(bin_path, "rb") as fh:
        blob = fh.read()
    bad: list[str] = []
    for dir_entry, din_entry in zip(entries, din_entries):
        (first_u32,) = struct.unpack_from("<I", blob, din_entry["offset"])
        if first_u32 != dir_entry["bin_first_u32"]:
            bad.append(f"{dir_entry['name']}: dir={dir_entry['bin_first_u32']} bin={first_u32}")
    stats.check(
        "prototyp.dir_col4_eq_bin_u32",
        not bad,
        f"{dir_path}: {len(bad)} mismatches, e.g. {bad[:3]}",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate Eng3d 3DW/dir/din corpus.")
    parser.add_argument("--root", default="gog_incubation", help="game data root (read-only)")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )
    if not os.path.isdir(args.root):
        LOG.error("root %s is not a directory", args.root)
        return 2

    stats = Stats()
    notes: list[str] = []
    stale: list[str] = []
    n_3dw = verify_3dw(args.root, stats, notes, stale)
    verify_stale_worlds(args.root, stats, stale)
    verify_object_rotations(args.root, stats)
    n_dir, n_din = verify_pairs(args.root, stats)

    print(f"corpus: {n_3dw} .3DW, {n_dir} .dir, {n_din} .din under {args.root}")
    if not (n_3dw or n_dir or n_din):
        # Previously this printed an "OK din.orphan 1/1" line produced by an
        # unconditional `stats.check(..., True)` and then "all checks passed",
        # so a wrong --root looked identical to a clean run.
        print(f"\nno .3DW, .dir or .din found under {args.root!r} -- nothing "
              f"was checked, which is a failure, not a pass")
        return 1
    print("checks:")
    stats.report()
    if notes:
        print(f"\n{len(notes)} note(s) about the shipped data (not parser failures):")
        for line in notes:
            print(f"  {line}")
    if stats.failures:
        print(f"\n{len(stats.failures)} failure(s):")
        for line in stats.failures[:50]:
            print(f"  {line}")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
