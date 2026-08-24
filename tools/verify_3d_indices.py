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

from inclib.binio import ParseError  # noqa: E402

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


def verify_3dw(root: str, stats: Stats, notes: list[str]) -> int:
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
    n_3dw = verify_3dw(args.root, stats, notes)
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
