#!/usr/bin/env python3
"""Extract and check the combat tables described in ``docs/22``.

Three kinds of thing are verified:

**Static tables in ``Incubation.exe``.**  The weapon -> target-pattern dispatch
at ``0x0046B420`` / ``0x0046B3B0`` is a real two-level jump table with one
entry per weapon id, so it can be decoded and every id accounted for (48/48).
The same is done for the indirect-fire predicate at ``0x0047B600`` and the two
octant-neighbour tables at ``0x0046A930`` / ``0x0046A9A0``.

**Floating-point constants in ``.rdata``.**  The line-of-sight slope limit, the
three rounding biases, the two direction thresholds and the three RNG constants
are read out and compared against the values ``docs/22`` states.

**Derived arithmetic.**  ``aRandom`` is reimplemented from its constants; the
compiler's magic division at ``0x0046A35C`` is emulated bit-for-bit and
compared against ``n / 2400`` over the full height range the ``.lev`` corpus
contains; and the hit curve is evaluated for every shipped weapon at every
distance inside its range.

**Closure claims.**  Three statements in the documentation are of the form
"nothing else in the binary touches this", and each is checked by enumerating
every reference rather than by having failed to find one: the option blob's
eight rows and their help lines (``docs/20`` 7.6), the eleven sites that read
the ``special`` column (``docs/21`` 5), and the RNG's four globals, which must
lie inside ``aRandom``/``aRandomize`` in **both** game binaries.

Usage::

    python3 tools/combat_tables.py --check gog_incubation
    python3 tools/combat_tables.py --patterns gog_incubation
    python3 tools/combat_tables.py --hit-curve gog_incubation
    python3 tools/combat_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import struct
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lcl_parse  # noqa: E402
from inclib.lev import LevError, load_lev  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("combat_tables")

GAME_EXE = "Incubation.exe"

# --- addresses, all virtual, all in Incubation.exe ---------------------------

#: `0x0046AA10`, the routine that marks the cells a weapon covers.
AOE_FUNC = 0x0046AA10
AOE_FUNC_END = 0x0046B3AF
#: `movzx ecx, byte [eax + 0x46B420]` -- one index byte per weapon id.
AOE_INDEX = 0x0046B420
#: `jmp dword [ecx*4 + 0x46B3B0]` -- the handler addresses.
AOE_JUMP = 0x0046B3B0
#: `aGetCtrlMapElementPtr`'s writing sibling; the marker is its 4th argument.
SET_CELL_STATE = 0x0042F7D0

#: `0x0047B600`: weapon id -> 1 when the shot is traced one field higher.
ARC_FUNC = 0x0047B600
ARC_BIAS = 8          # `add eax, -8` before the range check
ARC_LIMIT = 0x26      # `cmp eax, 0x26; ja default`
ARC_INDEX = 0x0047B638
ARC_JUMP = 0x0047B624

#: The two octant-neighbour tables, `jmp dword [eax*4 + table]`, eax in 0..7.
OCTANT_TABLES = {"a930": 0x0046A974, "a9a0": 0x0046A9E4}

#: `.rdata` doubles.  The names are this project's, the addresses the engine's.
CONSTANTS = {
    "zero":             (0x004B15D0, 0.0),
    "dir_threshold_hi": (0x004B15D8, 1.5),
    "dir_threshold_lo": (0x004B15E0, 0.5),
    "los_slope_max":    (0x004B15E8, 4000.0),
    "los_slope_min":    (0x004B15F0, -4000.0),
    "one":              (0x004B15F8, 1.0),
    "minus_one":        (0x004B1600, -1.0),
    "rng_multiplier":   (0x004B1530, 62089911.0),
    "rng_modulus":      (0x004B1538, 2147483647.0),
    "rng_scale":        (0x004B1540, 1.0 / (2.0 ** 31 - 1)),
}

#: The rounding biases `aCheckLineOfSightEx` passes to `aCheckLineOfSight`,
#: as the little-endian halves of a double in the instruction stream.
LOS_BIASES = {
    0.5: (0x00000000, 0x3FE00000),
    0.4: (0x9999999A, 0x3FD99999),
    0.6: (0x33333333, 0x3FE33333),
}

#: Cell markers written by the target-pattern pass and what each is worth.
#: ``None`` means the resolver forces the damage to zero (see docs/22 7.2).
MARKER_DAMAGE = {
    0x50: "full",
    0x51: "70%",          # (d*70 + 1) / 100
    0x52: "50%",          # (d*50 + 1) / 100, never written -- docs/22 12
    0x53: "flat 100",
    0x54: "none, forced hit",
    0x55: "none, forced hit, target loses its turn",
}

#: Weapon ids whose dispatch entry is the handler that reports an error and
#: returns FALSE, i.e. weapons with no target pattern at all.  Decoded from the
#: binary; listed here so a change in the binary or in this decoder is a
#: failure rather than a silent difference.
EXPECTED_NO_PATTERN = {18, 19, 28, 33, 34, 35, 37, 38, 39}

#: `0x0047B600` returns 1 for exactly these -- the grenade launcher, the
#: enhanced mine thrower, and the B mode of each.
EXPECTED_ARCING = {8, 13, 42, 46}

#: Every marker any part of the binary ever writes into a cell.  ``0x52``
#: (50 % damage) is deliberately absent: the resolver has a case for it and
#: nothing reaches it -- see the closed items at the end of docs/22 12.
EXPECTED_WRITTEN_MARKERS = {0x50, 0x51, 0x53, 0x54, 0x55}

#: The distance rule at `0x0046A34E`: two adjacent cells more than this far
#: apart vertically count as further than one field.
HEIGHT_STEP = 2400

# --- Options\Game.opt (docs/20 7.6) -----------------------------------------

#: `aSaveOptions` / `aLoadOptions` transfer this many bytes from this address.
#: Both compile to `push 0x6C; push 0x005129D8`, which is what pins the file to
#: a single `.data` block.
OPT_BLOB = 0x005129D8
OPT_SIZE = 0x6C
OPT_IO = (0x004602E0, 0x00460390)

#: `jmp dword [ebx*4 + 0x00460EAC]` in the options screen's help-line switch:
#: row index -> a `push <textId>` stub.  The ids name the fields, and the row
#: order is the same one `0x00460520` hit-tests.
OPT_INIT = (0x004600AC, 0x004601C8)
"""The straight-line block in ``aInitOptions`` that installs the defaults."""
EXPECTED_OPT_DEFAULTS = {0x00: 1, 0x04: 25000, 0x08: 0, 0x0C: -512, 0x10: -512,
                         0x14: -512, 0x18: 0, 0x1C: 1, 0x20: 2, 0x24: 2,
                         0x28: 3}
"""docs/20 7.6.  ``+0x2C`` is the 64-byte player name, copied not stored."""
OPT_NAME_FIELD = 0x005129D8 + 0x2C
OPT_DEAD_FIELDS = (0x005129E0, 0x005129E8)
"""``+0x08`` and ``+0x10``: written by aInitOptions and read nowhere."""
OPT_ROW_TABLE = 0x00460EAC
EXPECTED_OPT_ROWS = [50, 51, 52, 57, 55, 54, 56, 58]
#: Row 7 is `aiLevel`, `Game.opt +0x18`, help line 58 "Set Difficulty Level ...".
OPT_DIFFICULTY_ROW = 7

# --- provably private globals -----------------------------------------------

#: `unitType[+0x07]`, the `special` column.  Every site that reads it, so that
#: a new consumer appearing in a re-analysis is a failure rather than a silent
#: gap.  docs/21 5 tabulates what each one does.
SPECIAL_COLUMN = 0x0051C027
EXPECTED_SPECIAL_SITES = {
    0x0040DB17, 0x0040DCCF,     # aPlayFightAnimation: death animations 12/13/16
    0x00430A64, 0x00430E5F,     # aBuildMoveMap: 1 and 14 immobile, 15 warps
    0x004416BB,                 # the SetUnitInfo handler -- the only writer
    0x0046BBA6, 0x0046BC2E, 0x0046BE6C,   # aAttackUnit: 10, 12, 13, 16
    0x0046F255,                 # the special hook itself
    0x004703EE,                 # aExecuteBomb: 12
    0x004753A9,                 # the warp-range accessor
}

#: The RNG's four globals and the address span of `aRandomize` + `aRandom`.
#: Every reference must fall inside that span -- that is what makes the two
#: instrumentation counters *provably* unread rather than merely unexplained.
RNG_GLOBALS = {
    "Incubation.exe": ((0x00514078, 0x0051407C, 0x00514080, 0x00514084),
                       (0x00463820, 0x004638D5)),
    "iDesigner.exe": ((0x004C4BE8, 0x004C4BEC, 0x004C4BF0, 0x004C4BF4),
                      (0x0042D980, 0x0042D9E5)),
}

WEAPON_COUNT = 48


# ---------------------------------------------------------------------------
# Static tables
# ---------------------------------------------------------------------------

class CombatTables:
    """Everything read straight out of ``Incubation.exe``."""

    def __init__(self, pe: PEFile) -> None:
        self.pe = pe
        self.aoe_index = [pe.u8(AOE_INDEX + i) for i in range(WEAPON_COUNT)]
        n_handlers = max(self.aoe_index) + 1
        self.aoe_jump = [pe.u32(AOE_JUMP + 4 * i) for i in range(n_handlers)]
        self.handler_of = {w: self.aoe_jump[self.aoe_index[w]]
                           for w in range(WEAPON_COUNT)}
        self.markers = self._markers()
        self.arcing = self._arcing()
        self.octants = {name: [self._const_return(pe.u32(base + 4 * i))
                               for i in range(8)]
                        for name, base in OCTANT_TABLES.items()}

    # -- the target-pattern handlers ----------------------------------------

    def _markers(self) -> dict[int, list[int]]:
        """``handler -> [marker, ...]`` in the order the handler writes them.

        A handler's extent is taken as the span up to the next handler entry,
        which is exact here because the compiler laid the switch bodies out in
        address order.  A marker reaches ``SET_CELL_STATE`` as its last
        argument, and arguments are pushed right to left, so it is the *first*
        of four pushes -- but how far ahead of the call that push sits varies:
        the weapon-13 handler loops eighteen times and calls ``aRandom`` twice
        for the coordinates in between, putting 54 bytes between the two.

        So the span is scanned for every ``push imm8`` in ``0x50..0x5F`` that
        precedes the last ``call SET_CELL_STATE`` in it, rather than for a
        push at a fixed distance.  A handler with no such call has no markers,
        which is how the error handler is recognised.
        """
        bounds = sorted(set(self.aoe_jump) | {AOE_FUNC_END})
        data = self.pe.data
        out: dict[int, list[int]] = {}
        for start, end in zip(bounds, bounds[1:]):
            lo = self.pe.va_to_off(start)
            hi = self.pe.va_to_off(end)
            if lo is None or hi is None:
                continue
            last_call = None
            i = lo
            while True:
                i = data.find(b"\xe8", i, hi)
                if i < 0:
                    break
                va = self.pe.off_to_va(i)
                if va is not None:
                    target = va + 5 + struct.unpack_from("<i", data, i + 1)[0]
                    if target == SET_CELL_STATE:
                        last_call = i
                i += 1
            markers: list[int] = []
            if last_call is not None:
                for q in range(lo, last_call):
                    if data[q] == 0x6A and 0x50 <= data[q + 1] <= 0x5F:
                        if data[q + 1] not in markers:
                            markers.append(data[q + 1])
            out[start] = markers
        return out

    def written_markers(self) -> dict[int, list[int]]:
        """``marker -> [call site, ...]`` over the **whole** ``.text`` section.

        The target-pattern handlers are not the only writers: the resolver and
        ``aExecuteBomb`` both stamp ``0x53`` on a victim's neighbours.  This
        sweep is what shows that ``0x52`` is never written at all.
        """
        _tva, _tvsize, traw, trawsize = self.pe.section(".text")
        data = self.pe.data
        out: dict[int, list[int]] = defaultdict(list)
        i = traw
        while True:
            i = data.find(b"\xe8", i, traw + trawsize)
            if i < 0:
                break
            va = self.pe.off_to_va(i)
            if va is not None:
                target = va + 5 + struct.unpack_from("<i", data, i + 1)[0]
                if target == SET_CELL_STATE:
                    for back in range(4, 80):
                        q = i - back
                        if q < traw:
                            break
                        if data[q] == 0x6A and 0x50 <= data[q + 1] <= 0x5F:
                            out[data[q + 1]].append(self.pe.off_to_va(q))
                            break
            i += 1
        return dict(out)

    @property
    def no_pattern_handler(self) -> int:
        """The handler shared by the weapon ids that have no pattern.

        It is the only one that writes no marker at all.
        """
        empty = [h for h in set(self.aoe_jump) if not self.markers.get(h)]
        if len(empty) != 1:
            raise PEError(f"expected exactly one marker-less handler, got {empty}")
        return empty[0]

    # -- the indirect-fire predicate ----------------------------------------

    def _arcing(self) -> set[int]:
        out = set()
        for weapon in range(WEAPON_COUNT):
            key = weapon - ARC_BIAS
            if not 0 <= key <= ARC_LIMIT:
                continue
            handler = self.pe.u32(ARC_JUMP + 4 * self.pe.u8(ARC_INDEX + key))
            if self._const_return(handler) == 1:
                out.add(weapon)
        return out

    def _const_return(self, va: int) -> int | None:
        """Decode ``mov eax, imm32; ret`` or ``xor eax, eax; ret`` at *va*."""
        head = self.pe.bytes_at(va, 6)
        if head[0] == 0xB8 and head[5] == 0xC3:
            return struct.unpack_from("<I", head, 1)[0]
        if head[:3] == b"\x33\xc0\xc3":
            return 0
        return None

    # -- constants -----------------------------------------------------------

    def constants(self) -> dict[str, float]:
        return {name: self.pe.f64(va) for name, (va, _want) in CONSTANTS.items()}

    # -- Game.opt ------------------------------------------------------------

    def option_io(self) -> list[tuple[int, int]]:
        """``(size, address)`` of each ``push size; push address`` in the two I/O
        routines.  Both must transfer the whole blob from the same place."""
        out = []
        for func in OPT_IO:
            off = self.pe.va_to_off(func)
            window = self.pe.data[off:off + 0x80]
            i = window.find(b"\x6a")
            while i >= 0:
                if window[i + 2] == 0x68:
                    out.append((window[i + 1],
                                struct.unpack_from("<I", window, i + 3)[0]))
                    break
                i = window.find(b"\x6a", i + 1)
        return out

    def option_defaults(self) -> dict[int, int]:
        """The blob offsets ``aInitOptions`` writes, and what it writes there.

        The block is straight-line code that loads a constant into a register
        and stores it several times, so the registers are tracked forward.  A
        store whose target is outside the blob is ignored.
        """
        lo, hi = OPT_INIT
        data = self.pe.data
        base = self.pe.va_to_off(lo)
        end = self.pe.va_to_off(hi)
        regs = {"eax": None, "esi": None, "ebp": None}
        stores = {"\xa3": "eax", "\x89\x35": "esi", "\x89\x2d": "ebp"}
        out: dict[int, int] = {}
        i = base
        while i < end:
            op = data[i]
            if op in (0xB8, 0xBE, 0xBD):
                name = {0xB8: "eax", 0xBE: "esi", 0xBD: "ebp"}[op]
                regs[name] = struct.unpack_from("<i", data, i + 1)[0]
                i += 5
                continue
            if op == 0x33 and data[i + 1] in (0xC0, 0xF6, 0xED):
                regs[{0xC0: "eax", 0xF6: "esi", 0xED: "ebp"}[data[i + 1]]] = 0
                i += 2
                continue
            if op == 0xC7 and data[i + 1] == 0x05:
                target = struct.unpack_from("<I", data, i + 2)[0]
                value = struct.unpack_from("<i", data, i + 6)[0]
                if OPT_BLOB <= target < OPT_BLOB + OPT_SIZE:
                    out[target - OPT_BLOB] = value
                i += 10
                continue
            for prefix, name in stores.items():
                raw = prefix.encode("latin-1")
                if data[i:i + len(raw)] == raw:
                    target = struct.unpack_from("<I", data, i + len(raw))[0]
                    if (OPT_BLOB <= target < OPT_BLOB + OPT_SIZE
                            and regs[name] is not None):
                        out[target - OPT_BLOB] = regs[name]
                    i += len(raw) + 4
                    break
            else:
                i += 1
        return out

    def option_rows(self) -> list[int | None]:
        """Help-line text id for each of the eight option rows, in row order."""
        out: list[int | None] = []
        for row in range(8):
            stub = self.pe.u32(OPT_ROW_TABLE + 4 * row)
            head = self.pe.bytes_at(stub, 2)
            out.append(head[1] if head[0] == 0x6A else None)
        return out

    # -- global reference sweeps --------------------------------------------

    def refs_to(self, address: int) -> list[int]:
        """Every ``.text`` site whose instruction stream embeds *address*."""
        _tva, _tvsize, traw, trawsize = self.pe.section(".text")
        data = self.pe.data
        pattern = struct.pack("<I", address)
        out, i = [], traw
        while True:
            i = data.find(pattern, i, traw + trawsize)
            if i < 0:
                return out
            out.append(self.pe.off_to_va(i))
            i += 1


# ---------------------------------------------------------------------------
# Derived arithmetic
# ---------------------------------------------------------------------------

class Random:
    """``aRandom`` (``0x00463870``) reimplemented from its own constants."""

    def __init__(self, multiplier: float, modulus: float, scale: float,
                 seed: float = 0.0) -> None:
        self.multiplier = multiplier
        self.modulus = modulus
        self.scale = scale
        self.seed = seed

    def __call__(self, base: int, span: int) -> int:
        self.seed = float(int(self.seed * self.multiplier) % int(self.modulus)) \
            if self.seed else 0.0
        return int(base + span * (self.seed * self.scale))


def magic_div_2400_plus_1(n: int) -> int:
    """The compiler's division at ``0x0046A35C``, emulated instruction by instruction.

    ``mov eax, 0x1B4E81B5; imul ecx; sar edx, 8; mov eax, edx; shr eax, 31;
    lea ecx, [edx + eax + 1]``
    """
    product = 0x1B4E81B5 * n
    if product < 0:
        product += 1 << 64
    hi = (product >> 32) & 0xFFFFFFFF
    if hi >= 1 << 31:
        hi -= 1 << 32
    hi >>= 8                      # sar
    sign = 1 if hi < 0 else (hi & 0xFFFFFFFF) >> 31
    return hi + sign + 1


def hit_percent(accuracy: int, range_max: int, distance: int) -> int:
    """``docs/22`` 5.4.  Integer division, and it truncates before multiplying."""
    return 100 - ((101 - accuracy) // range_max) * distance


# ---------------------------------------------------------------------------
# Info.lcl
# ---------------------------------------------------------------------------

class Weapon:
    __slots__ = ("id", "name", "range_min", "range_max", "accuracy", "damage",
                 "type", "mun", "heat", "special", "toggle", "wave")

    def __init__(self, wid: int) -> None:
        self.id = wid
        self.name = ""
        self.wave = ""
        self.range_min = self.range_max = 0
        self.accuracy = self.damage = self.type = 0
        self.mun = self.heat = self.special = self.toggle = 0

    def to_dict(self) -> dict:
        return {k: getattr(self, k) for k in self.__slots__}


def load_weapons(root: str) -> dict[int, Weapon]:
    """Parse ``DATA/Info.lcl``'s ``SetWeaponInfo`` / ``SetWeaponInfo2`` tables."""
    path = None
    for dirpath, _dirs, files in os.walk(root):
        for fname in files:
            if fname.lower() == "info.lcl":
                path = os.path.join(dirpath, fname)
                break
        if path:
            break
    if path is None:
        raise LevError(f"no Info.lcl under {root!r}")
    program = lcl_parse.parse_bytes(open(path, "rb").read(), path)

    def nums(stmt):
        return [a.value for a in stmt.args if a.kind == "number"]

    def strs(stmt):
        return [a.value for a in stmt.args if a.kind == "string"]

    out: dict[int, Weapon] = {}
    for stmt in program.statements():
        name = stmt.name
        if name == "SetWeaponInfo":
            n = nums(stmt)
            if len(n) < 18:
                continue
            w = out.setdefault(n[0], Weapon(n[0]))
            texts = strs(stmt)
            w.name = texts[0] if texts else ""
            (w.range_min, w.range_max, w.accuracy, w.damage) = n[1], n[2], n[3], n[4]
            w.type = n[11]
            w.mun, w.heat = n[13], n[14]
            w.special = n[16]
        elif name == "SetWeaponInfo2":
            n = nums(stmt)
            if len(n) < 4:
                continue
            w = out.setdefault(n[0], Weapon(n[0]))
            texts = strs(stmt)
            w.wave = texts[0] if texts else ""
            w.toggle = n[1]
            # `SetWeaponInfo2` copies strlen(wave)+1 bytes to +0x25 and the
            # next field starts at +0x2E, so a 9-character name zeroes
            # `range min`.  docs/21 lists the eight weapons this hits.
            if len(w.wave) == 9:
                w.range_min = 0
    return out


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

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


def corpus_height_range(root: str) -> tuple[int, int, int]:
    """``(min, max, files)`` of cell heights over every ``.lev`` under *root*."""
    lo, hi, files = None, None, 0
    for dirpath, _dirs, names in os.walk(root):
        for fname in names:
            if not fname.lower().endswith(".lev"):
                continue
            try:
                battle = load_lev(os.path.join(dirpath, fname))
            except LevError:
                continue
            files += 1
            for cell in battle.cells:
                h = cell.height
                lo = h if lo is None or h < lo else lo
                hi = h if hi is None or h > hi else hi
    return (0 if lo is None else lo, 0 if hi is None else hi, files)


def run_check(root: str) -> int:
    exe = os.path.join(root, GAME_EXE)
    if not os.path.isfile(exe):
        print(f"{GAME_EXE} not found under {root!r} -- nothing was checked, "
              f"which is a failure, not a pass")
        return 1
    tables = CombatTables(PEFile(exe))
    stats = Stats()

    # 1. the target-pattern dispatch covers every weapon id
    for wid in range(WEAPON_COUNT):
        stats.check("aoe.dispatch", wid in tables.handler_of,
                    f"weapon {wid} has no dispatch entry")
    no_pattern = {w for w, h in tables.handler_of.items()
                  if h == tables.no_pattern_handler}
    stats.check("aoe.no_pattern", no_pattern == EXPECTED_NO_PATTERN,
                f"weapons without a pattern are {sorted(no_pattern)}, "
                f"expected {sorted(EXPECTED_NO_PATTERN)}")
    for handler, markers in tables.markers.items():
        stats.check("aoe.markers", all(m in MARKER_DAMAGE for m in markers),
                    f"handler {handler:#010x} writes {markers}")

    written = tables.written_markers()
    stats.check("marker.written", set(written) == EXPECTED_WRITTEN_MARKERS,
                f"markers written anywhere in .text are "
                f"{sorted(hex(m) for m in written)}, expected "
                f"{sorted(hex(m) for m in EXPECTED_WRITTEN_MARKERS)}")

    # 1b. Game.opt: the file is one .data block, and the rows name themselves
    io = tables.option_io()
    stats.check("opt.io", io == [(OPT_SIZE, OPT_BLOB)] * len(OPT_IO),
                f"aSaveOptions/aLoadOptions transfer {io}, expected "
                f"{[(OPT_SIZE, OPT_BLOB)] * len(OPT_IO)}")
    rows = tables.option_rows()
    stats.check("opt.rows", rows == EXPECTED_OPT_ROWS,
                f"option help lines are {rows}, expected {EXPECTED_OPT_ROWS}")
    stats.check("opt.difficulty", rows[OPT_DIFFICULTY_ROW] == 58,
                f"the difficulty row points at text {rows[OPT_DIFFICULTY_ROW]}, not 58")
    defaults = tables.option_defaults()
    stats.check("opt.defaults", defaults == EXPECTED_OPT_DEFAULTS,
                f"aInitOptions installs {defaults}, expected "
                f"{EXPECTED_OPT_DEFAULTS}")
    stats.check("opt.name_field",
                any(tables.refs_to(OPT_NAME_FIELD)),
                f"nothing addresses the player name at {OPT_NAME_FIELD:#010x}")
    dead = {va: tables.refs_to(va) for va in OPT_DEAD_FIELDS}
    stats.check("opt.dead", all(len(sites) == 1 for sites in dead.values()),
                "the two dead dwords are referenced at "
                + ", ".join(f"{va:#010x}: {[hex(s) for s in sites]}"
                            for va, sites in dead.items()))

    # 1c. the special column has no consumer this documentation does not know
    sites = set(tables.refs_to(SPECIAL_COLUMN))
    stats.check("special.sites", sites == EXPECTED_SPECIAL_SITES,
                f"unitType[+0x07] is referenced at {sorted(hex(x) for x in sites)}, "
                f"expected {sorted(hex(x) for x in EXPECTED_SPECIAL_SITES)}")

    # 2. the indirect-fire predicate
    stats.check("arc.weapons", tables.arcing == EXPECTED_ARCING,
                f"arcing weapons are {sorted(tables.arcing)}, "
                f"expected {sorted(EXPECTED_ARCING)}")

    # 3. the octant tables are a consistent neighbour pair
    a930, a9a0 = tables.octants["a930"], tables.octants["a9a0"]
    for d in range(8):
        stats.check("octant.range", a930[d] in range(8) and a9a0[d] in range(8),
                    f"direction {d} maps to {a930[d]}/{a9a0[d]}")
        stats.check("octant.distinct",
                    a930[d] != a9a0[d] and a930[d] != d and a9a0[d] != d,
                    f"direction {d} maps to itself or to one neighbour twice")
    stats.check("octant.symmetric",
                all(d in (a930[a930[d]], a9a0[a930[d]]) for d in range(8)),
                "the neighbour relation is not symmetric")

    # 4. .rdata constants
    for name, (va, want) in CONSTANTS.items():
        got = tables.pe.f64(va)
        stats.check("const", got == want, f"{name} at {va:#010x} is {got}, expected {want}")
    for value, (lo, hi) in LOS_BIASES.items():
        got = struct.unpack("<d", struct.pack("<II", lo, hi))[0]
        stats.check("const.bias", got == value, f"bias halves decode to {got}, not {value}")

    # 5. the magic division, over the height range the corpus actually contains
    lo, hi, nlev = corpus_height_range(root)
    stats.check("lev.corpus", nlev > 0, f"no .lev parsed under {root!r}")
    span = hi - lo                       # the largest |dh| the corpus can produce
    bad = next((n for n in range(0, span + 1)
                if magic_div_2400_plus_1(n) != n // HEIGHT_STEP + 1), None)
    stats.check("magic.div", bad is None,
                f"emulation differs from n//{HEIGHT_STEP}+1 at n={bad}")

    # 6. aRandom: the constants form the documented Lehmer generator
    consts = tables.constants()
    stats.check("rng.modulus", consts["rng_modulus"] == 2.0 ** 31 - 1,
                f"modulus is {consts['rng_modulus']}")
    stats.check("rng.scale", consts["rng_scale"] == 1.0 / consts["rng_modulus"],
                f"scale is {consts['rng_scale']}, not 1/modulus")
    rng = Random(consts["rng_multiplier"], consts["rng_modulus"],
                 consts["rng_scale"], seed=1.0)
    draws = [rng(0, 100) for _ in range(1000)]
    stats.check("rng.range", all(0 <= d <= 99 for d in draws),
                "aRandom(0, 100) left 0..99")

    # 6b. the RNG globals are private to the generator, in both binaries
    for name, (globals_, (lo_va, hi_va)) in RNG_GLOBALS.items():
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            stats.check("rng.private", False, f"{name} not found under {root!r}")
            continue
        other = CombatTables.__new__(CombatTables)
        other.pe = PEFile(path)
        stray = [va for g in globals_ for va in other.refs_to(g)
                 if not lo_va <= va < hi_va]
        stats.check("rng.private", not stray,
                    f"{name}: the RNG globals are referenced outside "
                    f"{lo_va:#x}..{hi_va:#x} at {[hex(v) for v in stray]}")

    # 7. the hit curve over every shipped weapon
    weapons = load_weapons(root)
    stats.check("info.weapons", len(weapons) >= 40,
                f"Info.lcl yielded only {len(weapons)} weapons")
    clobbered = sorted(w.id for w in weapons.values() if len(w.wave) == 9)
    stats.check("info.wave_overrun", len(clobbered) == 8,
                f"{len(clobbered)} weapons have a 9-character wave name: {clobbered}")
    for w in sorted(weapons.values(), key=lambda x: x.id):
        if w.range_max <= 0:
            continue
        curve = [hit_percent(min(w.accuracy, 100), w.range_max, d)
                 for d in range(max(w.range_min, 1), w.range_max + 1)]
        stats.check("hit.monotonic", curve == sorted(curve, reverse=True),
                    f"weapon {w.id} {w.name!r} curve is not monotonic: {curve}")
        stats.check("hit.bounded", all(v <= 100 for v in curve),
                    f"weapon {w.id} {w.name!r} exceeds 100: {curve}")

    print(f"corpus: {GAME_EXE}, {nlev} .lev, {len(weapons)} weapons from Info.lcl")
    print("checks:")
    stats.report()
    if stats.failures:
        print(f"\n{len(stats.failures)} failure(s):")
        for line in stats.failures[:50]:
            print(f"  {line}")
        return 1
    print("\nall checks passed")
    return 0


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

def print_patterns(root: str) -> int:
    tables = CombatTables(PEFile(os.path.join(root, GAME_EXE)))
    weapons = load_weapons(root)
    groups: dict[int, list[int]] = defaultdict(list)
    for wid, handler in tables.handler_of.items():
        groups[handler].append(wid)
    print(f"{WEAPON_COUNT} weapon ids -> {len(groups)} target patterns")
    for handler in sorted(groups):
        markers = tables.markers.get(handler, [])
        tag = ("no pattern" if handler == tables.no_pattern_handler
               else " ".join(f"{m:#04x}({MARKER_DAMAGE[m]})" for m in markers))
        print(f"\n  {handler:#010x}  {tag}")
        for wid in groups[handler]:
            w = weapons.get(wid)
            arc = " [arcing]" if wid in tables.arcing else ""
            name = f"{w.name!r}" if w and w.name else "not in Info.lcl"
            print(f"      {wid:>3}  {name}{arc}")
    return 0


def print_hit_curve(root: str) -> int:
    weapons = load_weapons(root)
    print(f"{'id':>3}  {'weapon':<26} {'acc':>4} {'min':>4} {'max':>4} "
          f"{'slope':>6}  hit% at min .. max")
    for w in sorted(weapons.values(), key=lambda x: x.id):
        if w.range_max <= 0:
            print(f"{w.id:>3}  {w.name:<26} {w.accuracy:>4} {w.range_min:>4} "
                  f"{w.range_max:>4} {'-':>6}  never in range")
            continue
        acc = min(w.accuracy, 100)
        slope = (101 - acc) // w.range_max
        first = max(w.range_min, 1)
        print(f"{w.id:>3}  {w.name:<26} {w.accuracy:>4} {w.range_min:>4} "
              f"{w.range_max:>4} {slope:>6}  "
              f"{hit_percent(acc, w.range_max, first)} .. "
              f"{hit_percent(acc, w.range_max, w.range_max)}")
    return 0


def dump_json(root: str) -> int:
    tables = CombatTables(PEFile(os.path.join(root, GAME_EXE)))
    weapons = load_weapons(root)
    out = {
        "aoe": {
            str(wid): {
                "handler": f"{tables.handler_of[wid]:#010x}",
                "markers": tables.markers.get(tables.handler_of[wid], []),
                "arcing": wid in tables.arcing,
            }
            for wid in range(WEAPON_COUNT)
        },
        "octants": tables.octants,
        "constants": tables.constants(),
        "weapons": {str(w.id): w.to_dict() for w in weapons.values()},
    }
    json.dump(out, sys.stdout, indent=1)
    print()
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", nargs="?", default="gog_incubation",
                    help="the game directory (default: gog_incubation)")
    ap.add_argument("--check", metavar="ROOT", help="run the corpus checks")
    ap.add_argument("--patterns", action="store_true",
                    help="print the weapon -> target-pattern table")
    ap.add_argument("--hit-curve", action="store_true",
                    help="print the hit percentage of every weapon")
    ap.add_argument("--json", action="store_true", help="dump everything as JSON")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    root = args.check or args.root
    if not os.path.isdir(root):
        LOG.error("root %s is not a directory", root)
        return 2
    try:
        if args.check:
            return run_check(root)
        if args.patterns:
            return print_patterns(root)
        if args.hit_curve:
            return print_hit_curve(root)
        if args.json:
            return dump_json(root)
        return print_patterns(root)
    except (PEError, LevError) as exc:
        LOG.error("%s", exc)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
