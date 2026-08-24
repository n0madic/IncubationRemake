#!/usr/bin/env python3
"""Recover function names from Blue Byte's compiled-out error macro.

Every ``Incubation.exe`` / ``iDesigner.exe`` build ships the arguments of an
error-reporting macro that was itself reduced to a single ``ret``::

    call  X                          ; the thing being checked
    add   esp, imm                   ; optional
    test  eax, eax
    jcc   ok
    push  "…\\GameTools\\aTacTools.cpp"     ; __FILE__
    push  1623                              ; __LINE__
    push  "aCheckWeaponDamage"              ; a hand-written name
    call  0x00453E00                        ; -> ret

The name is the **callee's**, not the enclosing function's.  The decisive case
is ``0x0040104B``, which pushes ``LoadLibrary`` -- a Win32 import.  Pairing
each push site with the ``call`` that precedes it therefore names the target of
that call, and doing it over the whole ``.text`` section recovers a partial
symbol table.

Two caveats, both visible in the output:

* the name is written by hand, so it is occasionally the wrong one
  (``0x0046EF50`` collects both ``aExecuteWarp`` and ``aExecuteMove``).  The
  report votes across call sites; ``--all`` shows the losing names too.
* a programmer sometimes pastes the *enclosing* function's name instead, which
  is why ``0x0046B450`` -- independently named ``aAttackUnit`` from
  ``aUI.cpp`` -- also collects ``aExecuteFight`` from inside ``0x0046CCA0``.
  Those show up as targets with two unrelated names.

**This is why ``izz`` + ``axt`` on one of these strings lands on the caller.**

Usage::

    python3 tools/trace_names.py gog_incubation/Incubation.exe
    python3 tools/trace_names.py gog_incubation/Incubation.exe --json
    python3 tools/trace_names.py --check gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import struct
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("trace_names")

#: The compiled-out reporter in ``Incubation.exe``.  Located by the fact that
#: it is the target of every ``push FILE; push LINE; push NAME; call`` triple;
#: :func:`find_reporters` rediscovers it rather than hard-coding the address,
#: because ``iDesigner.exe`` uses a different one.
PUSH_IMM32 = 0x68
CALL_REL32 = 0xE8

#: Bytes allowed between the checked ``call`` and the first ``push`` of the
#: macro: an optional stack cleanup, a zero test, and a conditional jump.
#: Anything else means the push block is a merged error exit that several
#: checks jump to, and the callee cannot be attributed.
CHECK_GAP = re.compile(
    rb"^(?:\x83\xc4.|\x81\xc4....)?"          # add esp, imm8 / imm32
    rb"(?:\x85\xc0|\x0b\xc0|\x3b\xc3|\x85\xdb)"  # test eax,eax / or / cmp / test ebx,ebx
    rb"(?:\x74.|\x75.|\x0f\x84....|\x0f\x85....)$"  # jz / jnz, short or near
)

#: How far back from the push block a ``call`` may sit.
MAX_LOOKBACK = 32

#: A file path pushed by the macro always looks like this.
SOURCE_PATH = re.compile(r"^[A-Za-z]:\\.*\.(?:cpp|c|h)$", re.IGNORECASE)

#: A plausible identifier.  The macro is also used with free-text messages
#: (``"LOS building failed"``), which must not be mistaken for a name.
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class Site:
    """One ``push FILE; push LINE; push NAME`` block."""

    __slots__ = ("va", "name", "line", "source", "callee")

    def __init__(self, va: int, name: str, line: int, source: str) -> None:
        self.va = va
        self.name = name
        self.line = line
        self.source = source
        self.callee: int | None = None

    def to_dict(self) -> dict:
        return {
            "va": f"{self.va:#010x}",
            "name": self.name,
            "line": self.line,
            "source": self.source,
            "callee": None if self.callee is None else f"{self.callee:#010x}",
        }


def find_sites(pe: PEFile) -> list[Site]:
    """Every macro push block in ``.text``, with the call it guards resolved."""
    tva, tvsize, traw, trawsize = pe.section(".text")
    data = pe.data
    lo, hi = traw, traw + trawsize

    # Pass 1: locate the reporter.  It is the call target shared by the largest
    # number of `push imm32 x3; call rel32` sequences.
    votes: Counter[int] = Counter()
    triples: list[tuple[int, int]] = []          # (file offset of first push, call target)
    i = lo
    while True:
        i = data.find(b"\xe8", i, hi)
        if i < 0:
            break
        va = pe.off_to_va(i)
        p = i - 15
        if (va is not None and p >= lo
                and data[p] == PUSH_IMM32
                and data[p + 5] == PUSH_IMM32
                and data[p + 10] == PUSH_IMM32):
            target = va + 5 + struct.unpack_from("<i", data, i + 1)[0]
            triples.append((p, target))
            votes[target] += 1
        i += 1
    if not votes:
        return []
    reporter, _n = votes.most_common(1)[0]
    LOG.debug("reporter at %#010x (%d sites)", reporter, votes[reporter])

    # Pass 2: keep the blocks whose three immediates really are FILE/LINE/NAME.
    sites: list[Site] = []
    for p, target in triples:
        if target != reporter:
            continue
        source = pe.cstring(struct.unpack_from("<I", data, p + 1)[0])
        line = struct.unpack_from("<I", data, p + 6)[0]
        name = pe.cstring(struct.unpack_from("<I", data, p + 11)[0])
        if not source or not name:
            continue
        if not SOURCE_PATH.match(source) or not (0 < line < 100000):
            continue
        sites.append(Site(pe.off_to_va(p), name, line, source))

    # Pass 3: attribute each block to the call it guards.
    for site in sites:
        off = pe.va_to_off(site.va)
        for back in range(5, MAX_LOOKBACK + 1):
            q = off - back
            if q < lo or data[q] != CALL_REL32:
                continue
            if not CHECK_GAP.match(data[q + 5:off]):
                continue
            qva = pe.off_to_va(q)
            if qva is None:
                continue
            target = qva + 5 + struct.unpack_from("<i", data, q + 1)[0]
            if tva <= target < tva + tvsize:
                site.callee = target
            break
    return sites


def vote(sites: list[Site]) -> dict[int, list[tuple[str, int]]]:
    """``callee -> [(name, count), ...]`` most frequent first."""
    tally: dict[int, Counter[str]] = defaultdict(Counter)
    for s in sites:
        if s.callee is not None and IDENTIFIER.match(s.name):
            tally[s.callee][s.name] += 1
    return {addr: c.most_common() for addr, c in tally.items()}


def source_modules(sites: list[Site]) -> dict[str, int]:
    out: Counter[str] = Counter()
    for s in sites:
        out[s.source.rsplit("\\", 1)[-1]] += 1
    return dict(out.most_common())


def report(pe: PEFile, sites: list[Site], show_all: bool) -> None:
    names = vote(sites)
    attributed = sum(1 for s in sites if s.callee is not None)
    print(f"{pe.path}: {len(sites)} trace sites, {attributed} attributed to a "
          f"call, {len(names)} functions named")
    width = 10
    for addr in sorted(names):
        cands = names[addr]
        best, n = cands[0]
        extra = ""
        if len(cands) > 1:
            if show_all:
                extra = "   [also " + ", ".join(f"{m}({k})" for m, k in cands[1:]) + "]"
            else:
                extra = f"   [+{len(cands) - 1} other name(s)]"
        print(f"  {addr:#0{width}x}  {best:<40} {n:>3}{extra}")


def run_check(root: str) -> int:
    """Both game binaries must yield a symbol table, and the known names must hold."""
    binaries = ["Incubation.exe", "iDesigner.exe"]
    expected = {
        "Incubation.exe": {
            0x0046B450: "aAttackUnit",
            0x0046C460: "aCheckLineOfSightEx",
            0x0046C720: "aCheckLineOfSight",
            0x0046D1B0: "aCheckWeaponDamage",
            0x00479370: "aSetVisibleStateForUnit",
            0x004794B0: "aBuildVisibleMapForUnit",
            0x004798C0: "aBuildVisibleMap",
            0x0047ABD0: "aGetGradientsOfUnitView",
            0x0042F730: "aGetCtrlMapElementPtr",
            0x00477AE0: "aGetUnitMapElementPtr",
        },
        "iDesigner.exe": {},
    }
    failures: list[str] = []
    checked = 0
    for name in binaries:
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            failures.append(f"{name}: not found under {root!r}")
            continue
        pe = PEFile(path)
        sites = find_sites(pe)
        names = vote(sites)
        checked += 1
        if not sites:
            failures.append(f"{name}: no trace sites found")
            continue
        if len(names) < 50:
            failures.append(f"{name}: only {len(names)} functions named, expected >= 50")
        attributed = sum(1 for s in sites if s.callee is not None)
        print(f"  {name:<16} {len(sites):>5} sites  {attributed:>5} attributed  "
              f"{len(names):>4} named")
        for addr, want in expected[name].items():
            got = names.get(addr)
            if not got:
                failures.append(f"{name}: {addr:#010x} has no name at all")
            elif got[0][0] != want:
                failures.append(f"{name}: {addr:#010x} voted {got[0][0]!r}, "
                                f"expected {want!r}")
    if checked == 0:
        print(f"\nno game binary found under {root!r} -- nothing was checked, "
              f"which is a failure, not a pass")
        return 1
    if failures:
        print(f"\n{len(failures)} failure(s):")
        for line in failures:
            print(f"  {line}")
        return 1
    print("\nall checks passed")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("binary", nargs="?", help="a PE image to read")
    ap.add_argument("--check", metavar="ROOT",
                    help="verify both game binaries under ROOT")
    ap.add_argument("--json", action="store_true", help="dump every site as JSON")
    ap.add_argument("--modules", action="store_true",
                    help="count sites per source module instead")
    ap.add_argument("--all", action="store_true",
                    help="show the losing names of ambiguous targets")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    if args.check:
        return run_check(args.check)
    if not args.binary:
        ap.error("give a binary or --check ROOT")
    try:
        pe = PEFile(args.binary)
    except PEError as exc:
        LOG.error("%s", exc)
        return 2
    sites = find_sites(pe)
    if args.json:
        json.dump([s.to_dict() for s in sites], sys.stdout, indent=1)
        print()
    elif args.modules:
        for mod, n in source_modules(sites).items():
            print(f"  {n:>5}  {mod}")
    else:
        report(pe, sites, args.all)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
