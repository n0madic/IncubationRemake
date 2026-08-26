#!/usr/bin/env python3
"""List the PE export tables of the shipped binaries, and keep committed
listings of them under ``tools/exports/`` in step with ``gog_incubation/``.

Why this exists: the headless Wine harnesses (see ``tools/wine_visn/``) call
the game's own code by name, so the exact set of exported symbols — and which
of them are game logic rather than Windows plumbing — is load-bearing
documentation.  The findings behind it: every shipped ``.exe`` has an empty
export directory; all directly callable engine entry points live in
``Eng3d.dll`` / ``ENG3DFX.DLL`` (E3D_*), with Blue Byte's utility classes in
``NewToolsR.dll`` / ``aWin.dll`` (BB:: RNGs, containers) and the GUI framework
in ``BGLWin*.dll``.

Usage::

    pe_exports.py gog_incubation              # summary for every binary
    pe_exports.py gog_incubation/Eng3d.dll    # full table of one binary
    pe_exports.py --write gog_incubation      # regenerate tools/exports/*.lst
    pe_exports.py --check gog_incubation      # verify listings match binaries

Listings exist only for the seven original Blue Byte libraries.  Everything
else is deliberately excluded as system or third-party plumbing that a harness
would never call by name: the ``winmm`` shims ``audio.dll`` / ``sound.dll``
(186 of 192 exports are forwarders), the GOG-era wrappers (``glide*.dll``,
``3DfxSpl*.dll``, ``audiere.dll``, ``libogg``/``libvorbis*``), and the CRT
(``MSVCRT.DLL``, ``msvcirt.dll``).  Binaries without exports get no listing.

The canonical listing files contain only raw facts read from the image
(ordinal, RVA, name, forwarder string), so ``--check`` is deterministic and
needs no external tooling.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from inclib.pe import PEFile, PEError

LISTINGS_DIR = Path(__file__).resolve().parent / "exports"

# Top-level binaries of the retail install.  Install/ holds installer parts,
# which never ship code the game loads, so they stay out of the corpus.
PATTERNS = ("*.exe", "*.dll", "*.DLL")

# The original Blue Byte libraries whose exports are worth listing.  Everything
# else under the game root is system or third-party plumbing (winmm shims,
# Glide/GOG wrappers, CRT) — see LISTED in binaries_in().
ORIGINAL_BINARIES = {
    "eng3d.dll": "engine",
    "eng3dfx.dll": "engine",
    "newtoolsr.dll": "support",
    "awin.dll": "support",
    "bglwin.dll": "gui framework",
    "bglwinr.dll": "gui framework",
}


def all_binaries(root: Path) -> list[Path]:
    """Every top-level PE image of the game directory, in a stable order."""
    out = []
    for pat in PATTERNS:
        out.extend(p for p in sorted(root.glob(pat)) if p.is_file())
    # dedupe case-insensitively (a *.dll glob already caught *.DLL on macOS)
    seen, unique = set(), []
    for p in out:
        key = p.name.lower()
        if key not in seen:
            seen.add(key)
            unique.append(p)
    return unique


def binaries_in(root: Path) -> list[Path]:
    """Only the original-engine images that get committed listings."""
    return [p for p in all_binaries(root) if p.name.lower() in ORIGINAL_BINARIES]


def read_exports(path: Path):
    """``(machine, timestamp, dll_name, entries)`` or ``None`` without exports."""
    pe = PEFile(path)
    result = pe.exports()
    if result is None:
        return None
    return pe.machine, pe.timestamp, result[0], result[1]


def cmd_summary(targets: list[tuple[Path, object]]) -> int:
    for path, info in targets:
        if info is None:
            print(f"{path.name}: no export directory")
            continue
        _machine, _stamp, dll_name, entries = info
        named = sum(1 for e in entries if e[2] is not None)
        fwd = sum(1 for e in entries if e[3] is not None)
        extra = f" dll_name={dll_name}" if dll_name else ""
        print(f"{path.name}: {len(entries)} slots ({named} named, {fwd} forwarders){extra}")
    return 0


def cmd_one(path: Path) -> int:
    info = read_exports(path)
    if info is None:
        print(f"{path}: no export directory")
        return 1
    _machine, _stamp, _dll_name, entries = info
    for ordinal, rva, name, forwarder in entries:
        row = f"[{ordinal:4d}] {rva:#010x}  {name if name is not None else '(anonymous)'}"
        if forwarder is not None:
            row += f"  -> {forwarder}"
        print(row)
    return 0


def cmd_write(root: Path, listings: Path) -> int:
    listings.mkdir(parents=True, exist_ok=True)
    targets = []
    for path in binaries_in(root):
        info = read_exports(path)
        if info is None:
            continue
        machine, timestamp, dll_name, entries = info
        text = render_listing_text(path, machine, timestamp, dll_name, entries)
        out = listings / f"{path.name}.lst"
        out.write_text(text)
        print(f"wrote {out.relative_to(listings.parent)} ({len(entries)} entries)")
        targets.append((path, len(entries)))
    if not targets:
        print("error: no exported symbol found in the whole corpus — refusing to "
              "write empty listings", file=sys.stderr)
        return 1
    return 0


def render_listing_text(path: Path, machine: int, timestamp: int,
                        dll_name: str | None, entries) -> str:
    lines = [
        f"# PE exports of gog_incubation/{path.name}",
        f"# machine={machine:#06x} timestamp={timestamp:#010x} "
        f"image_dll_name={dll_name!r} entries={len(entries)}",
        "# ordinal  rva        name [-> forwarder]",
    ]
    for ordinal, rva, name, forwarder in entries:
        row = f"{ordinal:7d}  {rva:#010x}  {name if name is not None else '(anonymous)'}"
        if forwarder is not None:
            row += f" -> {forwarder}"
        lines.append(row)
    return "\n".join(lines) + "\n"


def cmd_check(root: Path, listings: Path) -> int:
    ok = True
    checked = 0
    for path in binaries_in(root):
        info = read_exports(path)
        if info is None:
            continue
        expected = render_listing_text(path, *info[:3], info[3])
        out = listings / f"{path.name}.lst"
        if not out.exists():
            print(f"FAIL {out.name}: no committed listing for a binary that "
                  f"exports {len(info[3])} symbols")
            ok = False
            continue
        actual = out.read_text()
        if actual != expected:
            # point at the first divergent line to make diffs cheap
            exp_lines = expected.splitlines()
            act_lines = actual.splitlines()
            bad = next((i for i, (a, b) in enumerate(zip(act_lines, exp_lines))
                        if a != b), min(len(act_lines), len(exp_lines)))
            print(f"FAIL {out.name}: differs from the binary at line {bad + 1}")
            ok = False
        else:
            checked += 1
            print(f"OK  {out.name}  {len(info[3])} entries")
    if checked == 0:
        print("error: check examined nothing — no binary with exports found or "
              "no listings present", file=sys.stderr)
        return 1
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("target", nargs="?", help="a .exe/.dll file, or the game directory")
    ap.add_argument("--check", metavar="ROOT",
                    help="verify tools/exports/*.lst against every binary under ROOT")
    ap.add_argument("--write", action="store_true", dest="write_",
                    help="regenerate listings from the target game directory")
    ap.add_argument("--listings", type=Path, default=LISTINGS_DIR,
                    help=f"listing directory (default: {LISTINGS_DIR})")
    args = ap.parse_args()

    if args.check is None and args.target is None:
        ap.error("either a target or --check ROOT is required")

    target = Path(args.target) if args.target else None
    try:
        if args.write_:
            if target is None:
                ap.error("--write needs the game directory as target")
            return cmd_write(target, args.listings)
        if args.check:
            return cmd_check(Path(args.check), args.listings)
        if target.is_dir():
            infos = []
            for p in binaries_in(target):
                try:
                    infos.append((p, read_exports(p)))
                except PEError as e:
                    print(f"{p.name}: {e}", file=sys.stderr)
                    return 1
            if not infos:
                print("error: no PE images under the given root", file=sys.stderr)
                return 1
            return cmd_summary(infos)
        return cmd_one(target)
    except PEError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
