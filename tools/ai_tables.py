#!/usr/bin/env python3
"""Verify the AI turn described in ``docs/23`` against the binary and the corpus.

Three kinds of thing are checked:

**Jump tables in ``Incubation.exe``.**  The AI is a switch on the unit's order
byte whose eleven arms are themselves switches on a level counter, so the whole
control structure is five layers of jump table and can be read out rather than
inferred: the order table at ``0x0040A37C``, the six per-order level tables,
the planner's horizon table ``0x0040AD70`` and kind table ``0x0040AD88``, the
eight-direction stepper table ``0x00430A20`` and the diagonal corner table
``0x004305D0``.

**Thresholds compiled in as immediates.**  The five hit-probability bands that
become cell markers 30..34, the movement-cost reads against ``Info.lcl``'s
``delay`` column, the move map's stack frame and queue guard, the magic divide
by 1600 that limits climbing, and the three warp ranges.

**Corpus counts.**  Every number ``docs/23`` quotes about the 155 shipped
missions -- the order histograms, the field-type histogram, the height-blocked
neighbour count, the action-point-31 cells, the Jet Pack carriers -- is
recounted here, so the prose cannot drift away from the data.

Every check fails on an empty corpus: a check that examined nothing is not a
check that passed.

Usage::

    python3 tools/ai_tables.py --check gog_incubation
    python3 tools/ai_tables.py --orders gog_incubation
    python3 tools/ai_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import lcl  # noqa: E402
from inclib.lev import LevError, load_lev  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("ai_tables")

GAME_EXE = "Incubation.exe"

# --- aAISystemControl, 0x00409940 -------------------------------------------

#: `jmp dword [eax*4 + 0x0040A37C]` at 0x00409A14, on `unit[+0x47]`.
ORDER_TABLE = 0x0040A37C
ORDER_COUNT = 11
#: The `ja` at 0x00409A0E that guards it; its target is the default arm.
ORDER_GUARD = 0x00409A0E
EXPECTED_ORDER_TABLE = [
    0x00409E1A,   # 0  Berserk
    0x00409FFE,   # 1  Move (ActPt)
    0x00409FFE,   # 2  Attack (ActPt) -- the same block
    0x0040A08D,   # 3  Move (Group)
    0x0040A175,   # 4  Attack (Group)
    0x00409F1C,   # 5  Turn (Wait)
    0x00409F8D,   # 6  Range (Wait)
    0x0040A10B,   # 7  Defend
    0x00409BC8,   # 8  Visibility (Wait) -- also the default arm
    0x00409A1B,   # 9  Clever small units
    0x0040A28B,   # 10 Disturb
]

#: order -> (level table, the six arms).  docs/23 3.1.
LEVEL_TABLES = {
    0:  (0x0040A3A8, [0x00409E2A, 0x00409E2A, 0x00409E2A,
                      0x00409E80, 0x00409EAA, 0x00409ED5]),
    1:  (0x0040A3C0, [0x0040A00E, 0x0040A00E, 0x0040A00E,
                      0x0040A00E, 0x0040A044, 0x0040A00E]),
    3:  (0x0040A3D8, [0x0040A09D, 0x0040A09D, 0x0040A09D,
                      0x0040A09D, 0x0040A0C0, 0x0040A0E4]),
    7:  (0x0040A3F0, [0x0040A117, 0x0040A117, 0x0040A117,
                      0x0040A117, 0x0040A139, 0x0040A15B]),
    4:  (0x0040A408, [0x0040A1A3, 0x0040A1A3, 0x0040A1A3,
                      0x0040A1A3, 0x0040A1F6, 0x0040A246]),
    10: (0x0040A420, [0x0040A29B, 0x0040A29B, 0x0040A29B,
                      0x0040A2EE, 0x0040A312, 0x0040A336]),
}
#: order -> the epilogue its level switch's default arm reaches.  Four of the
#: six share one; orders 7 and 4 have their own variant of the same two lines.
EXPECTED_LEVEL_DEFAULT = {0: 0x0040A364, 1: 0x0040A364, 3: 0x0040A364,
                          7: 0x0040A164, 4: 0x0040A274, 10: 0x0040A364}
#: The `cmp ebp, 5` / `ja` that guards each level switch.
LEVEL_GUARD = {0: 0x00409E1D, 1: 0x0040A001, 3: 0x0040A090,
               7: 0x0040A10E, 4: 0x0040A196, 10: 0x0040A28E}

# --- the planner, 0x0040A750 ------------------------------------------------

PLAN_LEVEL_TABLE = 0x0040AD70
EXPECTED_PLAN_LEVELS = [0x0040A7A7, 0x0040A7E2, 0x0040A822,
                        0x0040A861, 0x0040A8A0, 0x0040A8DB]
#: level -> the MP the flood fill is run with.  ``None`` = the unit's own MP,
#: ``"x2"`` = doubled by the `shl al, 1` at 0x0040A7E2.  docs/23 5.1.
EXPECTED_PLAN_MP = [None, "x2", 30, 50, 100, 250]
#: level -> the `passFriendlies` argument aBuildMoveMap is called with.
EXPECTED_PLAN_PASS = [0, 0, 1, 0, 0, 0]

PLAN_KIND_TABLE = 0x0040AD88
PLAN_KIND_COUNT = 12
#: kind - 1 indexes this.  docs/23 5.2.
EXPECTED_PLAN_KINDS = [
    0x0040AA17, 0x0040A95F, 0x0040A9E8, 0x0040AB2D, 0x0040AB2D, 0x0040AA9B,
    0x0040AACE, 0x0040AB2D, 0x0040AB2D, 0x0040AB16, 0x0040A9CD, 0x0040A99A,
]
#: Kinds with no block of their own; they share the loop's fall-through.
UNIMPLEMENTED_KINDS = {4, 5, 8, 9}

# --- aCtrlMap.cpp -----------------------------------------------------------

#: `jmp dword [eax*4 + 0x00430A20]` in the eight-direction stepper 0x004308C0.
DIR_TABLE = 0x00430A20
EXPECTED_DIR_TABLE = [0x004308F0, 0x004308D6, 0x00430917, 0x004308FD,
                      0x00430965, 0x0043092E, 0x00430989, 0x00430941]
#: dir -> (dx, dy).  docs/23 8.
EXPECTED_DIR_DELTA = {0: (0, 1), 1: (-1, 0), 2: (0, -1), 3: (1, 0),
                      4: (1, -1), 5: (-1, 1), 6: (1, 1), 7: (-1, -1)}

#: The diagonal corner check 0x004303E0; four arms, one per diagonal.
CORNER_TABLE = 0x004305D0
EXPECTED_CORNER_TABLE = [0x004304DD, 0x0043041D, 0x0043045E, 0x0043049F]
#: dir -> the two orthogonal components it requires, in the order pushed.
EXPECTED_CORNER_PARTS = {4: (2, 3), 5: (0, 1), 6: (0, 3), 7: (2, 1)}

#: aBuildMoveMap, 0x00430A40.
BUILD_MOVE_MAP = 0x00430A40
#: ``0x0040ADC0`` -- the approach cell's two candidate tests (docs/23 §5.2):
#: the large arm's ``cmp ecx, eax; jle`` at ``0x0040AF03`` keeps the incumbent
#: on a tie, the small arm's ``cmp ecx, eax; jl`` at ``0x0040AF8D`` lets a later
#: tied cell win.  ``ai_gold``'s ``approach.tie.*`` measures both; this pins
#: the bytes the reading rests on.
APPROACH_LARGE_TEST = (0x0040AF03, b"\x3b\xc8\x7e")
APPROACH_SMALL_TEST = (0x0040AF8D, b"\x3b\xc8\x7c")
#: `mov eax, 0x3EE0` -- the __chkstk argument, i.e. the stack frame.
MOVE_MAP_FRAME = 0x3EE0
#: `mov ebp, 0x7D3` -- the stride between the two ping-ponged queues.
MOVE_MAP_QUEUE_STRIDE = 0x7D3
#: `cmp eax, 0x7D0` -- writing this entry is the overflow error.
MOVE_MAP_QUEUE_GUARD = 0x7D0
#: `mov cl, byte [edx + 0x004FEB81]` -- SetCtrlMapInfo base + 0x01, the `delay`.
COST_TABLE_READ = 0x004FEB81
CTRL_MAP_INFO_BASE = 0x004FEB80
CTRL_MAP_INFO_STRIDE = 23
#: The ladder-to-ladder special case tests this field type on both cells;
#: `cmp cl, 8` on the destination and `cmp byte [eax + 0x0D], 8` on the source.
LADDER_TYPE = 8
#: `Info.lcl`'s `delay` column, and the resulting cost of one step (delay + 1).
#: 255 means the field cannot be entered at all.  docs/23 7.4.
EXPECTED_DELAYS = {0: 0, 1: 0, 2: 255, 3: 255, 4: 255,
                   5: 1, 6: 0, 7: 255, 8: 0, 9: 0, 10: 255}

#: The magic multiply that limits climbing: (n * MAGIC) >> (32 + SHIFT).
CLIMB_MAGIC = 0x51EB851F
CLIMB_SHIFT = 9
CLIMB_DIVISOR = 1600
#: `cmp edx, 1` / `jle` -- the quotient must not exceed this.
CLIMB_MAX_QUOTIENT = 1
#: One map field, docs/22 2.2.  The first blocked difference.
WORLD_UNITS_PER_FIELD = 3200

# --- the target overlay -----------------------------------------------------

#: `0x0042F790(x, y, value)` is the only writer of markers 30..34.
MARKER_WRITER = 0x0042F790
#: (hit percentage upper bound, marker).  The last band has no upper bound.
EXPECTED_HIT_BANDS = [(20, 30), (50, 31), (70, 32), (90, 33), (None, 34)]
HIT_BAND_SPAN = (0x004302C0, 0x00430334)

# --- warping ----------------------------------------------------------------

WARP_RANGE = 0x00475380
#: `unit[+0x21 + id]`; equipment id 7 is the Jet Pack.
JET_PACK_EQUIP_ID = 7
JET_PACK_UNIT_OFFSET = 0x28
EXPECTED_WARP_JET_PACK = 5
EXPECTED_WARP_SPECIAL = 7
#: `unitInfo[+0x07] == 15` is the other way to warp.
WARP_SPECIAL_VALUE = 15

# --- corpus expectations ----------------------------------------------------

EXPECTED_MISSIONS = 155
EXPECTED_PLACED_UNITS = 1863
EXPECTED_CELLS = 184162
#: docs/10 5.6 and docs/23 3.
EXPECTED_PRIMARY_ORDERS = {0: 1000, 1: 6, 2: 14, 4: 3, 5: 57,
                           6: 51, 7: 103, 8: 427, 9: 130, 10: 72}
EXPECTED_SECONDARY_ORDERS = {0: 1647, 1: 2, 6: 29, 7: 76, 9: 72, 10: 37}
#: docs/23 7.4.  Types 7 and 8 appear on no shipped cell.
EXPECTED_FIELD_TYPES = {0: 61840, 1: 48292, 2: 26891, 3: 2241, 4: 44653,
                        5: 12, 6: 191, 7: 0, 8: 0, 9: 22, 10: 20}
EXPECTED_NEIGHBOUR_PAIRS = 357854
EXPECTED_HEIGHT_BLOCKED = 40609
EXPECTED_ACTPT31_CELLS = 278
EXPECTED_JET_PACK_UNITS = 5
#: `cell[+0x10]`, the byte aBuildMoveMap tests against 1, 2 and 3.
EXPECTED_EFFECT_STATE = {0xFF: EXPECTED_CELLS}
#: Action points 80..89 block a warp target; 80..85 are the deployment fields.
WARP_BLOCKED_ACTPT = range(80, 90)

#: `aAISystemControl`'s second argument is stashed here and never read back.
DEAD_PASS_GLOBAL = 0x004FAE3C
EXPECTED_DEAD_PASS_SITES = [0x00409948]
#: A weapon whose heat cap is 0 never gets past `0x0040A440`'s gate.  These are
#: the placed explosives, and 36 is unit type 31's default weapon.
EXPECTED_ZERO_HEAT_WEAPONS = {36: "ParaBomb", 37: "Mine"}
#: `SetUnitInfo` column 10, the default weapon, for the Parabomb.
EXPECTED_PARABOMB_WEAPON = 36

# --- the action-point legend, docs/10 4.6 -----------------------------------

#: The span of `push <string>` instructions that make up the legend.
LEGEND_SPAN = (0x0046838D, 0x004687A0)
EXPECTED_LEGEND_ENTRIES = 45          # 38 values + 7 section headings
#: A few the other documents now depend on, by value.
EXPECTED_LEGEND_NAMES = {
    31: "31 - standard Door - CLOSED",
    71: "71 - destroyed entry point",
    80: "80 - VictoryPoint A - neutral",
    85: "85 - VictoryPoint B - neutral",
}
#: Every action-point value the engine compares `cell[+0x0B]` against.  249 and
#: 254 are the editor's `+= 5` / `+= 1` overflow guards, not values.
EXPECTED_TESTED_ACTPT = {1, 10, 12, 31, 70, 71, 80, 85, 249, 254}
#: The two sites that test 31 are both inside the AI turn.
EXPECTED_ACTPT31_SITES = {0x0040A65F, 0x0040A9CD}
#: `0x0040A600` plays this; two independent trace names call it a door sequence.
DOOR_SEQUENCE = 0x00410A20
EXPECTED_DOOR_NAMES = {"aDoorOpenSequence", "aPlayDoorOpenSequence"}

# --- cell[+0x10], docs/23 7.1 ----------------------------------------------

#: maker -> (the model it inserts, the value it writes into `cell[+0x10]`)
OBSTACLE_MAKERS = {
    0x0042F840: (("A_FIRE1.3DI", "A_FIRE2.3DI", "A_FIRE3.3DI"), 1),
    0x0042FA70: (("A_MINE.3DI",), 2),
    0x0042FB90: (("A_SHILD.3DI",), 3),
}
#: The ground fire's glow phase writes `+0x0E`/`+0x12`/`+0x13`, never `+0x10`.
GLOW_MAKER = 0x0042FCB0
#: Byte length of each maker, so one is never read into the next.
MAKER_SIZES = {0x0042F840: 539, 0x0042FA70: 281, 0x0042FB90: 287, 0x0042FCB0: 382}
GLOW_MODELS = ("GLOW1.3DI", "GLOW2.3DI")

# --- the unit array, docs/23 5.2 -------------------------------------------

INIT_UNIT_MAP = 0x00477750
#: `push 0x4718` -- the byte count aInitUnitMap asks malloc for.
EXPECTED_UNIT_ARRAY_BYTES = 0x4718
#: `mov ecx, 0x11C6` -- the dword count it then clears.
EXPECTED_UNIT_ARRAY_DWORDS = 0x11C6
UNIT_SLOTS = 200
UNIT_STRIDE = 0x5B
#: The cover score reads these two offsets off the pointer one slot past the end.
COVER_OOB_OFFSETS = (0x42, 0x43)

# --- provably absent, docs/23 1.2 ------------------------------------------

#: `Game.opt +0x18`, the difficulty.  None of its call sites is in the AI.
AI_LEVEL = 0x00460450
EXPECTED_AI_LEVEL_SITES = 11
AI_MODULE = (0x00409910, 0x0040B3F0)
MOVE_MAP_MODULE = (0x00430000, 0x00431000)
#: `0x0040B4D0` is aAnimations.cpp's init; exactly one caller, and aMain reaches
#: the AI module only through the may-fire setter.
ANIM_INIT = 0x0040B4D0
MAY_FIRE_SETTER = 0x0040B360
A_MAIN = (0x00449000, 0x0044B000)
#: Written and never read: one reference each in the whole of `.text`.
WRITE_ONLY_GLOBALS = (0x004FAE3C, 0x004FAE5C, 0x004FCEC0, 0x004FCEC8, 0x004FCECC)

#: SetUnitInfo 31, the unit aAI_SpecialPlayerControl drives.
PARABOMB_TYPE = 31
#: (name, py, HP max, special, species) -- columns 2, 4, 6, 11 and 12.
EXPECTED_PARABOMB = ("Parabomb", 252, 1, 12, 2)
#: docs/22 5.5 already fixes these; docs/23 3.2 depends on the same predicate.
ARCING_PREDICATE = 0x0047B600
EXPECTED_ARCING = {8, 13, 42, 46}


# ---------------------------------------------------------------------------
# Reading the binary
# ---------------------------------------------------------------------------

def _rel_target(pe: PEFile, va: int) -> int | None:
    """Resolve a near jump at ``va``; ``None`` when it is not one."""
    op = pe.u8(va)
    if op == 0xE9:
        return va + 5 + pe.i32(va + 1)
    if op == 0xEB or 0x70 <= op <= 0x7F:
        d = pe.u8(va + 1)
        return va + 2 + (d - 256 if d > 127 else d)
    if op == 0x0F and 0x80 <= pe.u8(va + 1) <= 0x8F:
        return va + 6 + pe.i32(va + 2)
    return None


def _find_imm32(pe: PEFile, lo: int, hi: int, opcode: bytes, value: int) -> list[int]:
    """Sites in ``[lo, hi)`` where ``opcode`` is followed by ``value`` as imm32."""
    out = []
    n = len(opcode)
    for va in range(lo, hi - n - 4):
        if bytes(pe.u8(va + i) for i in range(n)) == opcode and pe.u32(va + n) == value:
            out.append(va)
    return out


def _push_imms(pe: PEFile, lo: int, hi: int) -> list[tuple[int, int]]:
    """Every ``6A imm8`` in ``[lo, hi)`` as ``(site, value)``."""
    return [(va, pe.u8(va + 1)) for va in range(lo, hi) if pe.u8(va) == 0x6A]


class AITables:
    """Everything read straight out of ``Incubation.exe``."""

    def __init__(self, pe: PEFile) -> None:
        self.pe = pe
        self.text_lo, self.text_hi = self._text_span()
        self.order_table = [pe.u32(ORDER_TABLE + 4 * i) for i in range(ORDER_COUNT)]
        self.order_default = _rel_target(pe, ORDER_GUARD)
        self.level_tables = {
            order: [pe.u32(base + 4 * i) for i in range(6)]
            for order, (base, _) in LEVEL_TABLES.items()
        }
        self.plan_levels = [pe.u32(PLAN_LEVEL_TABLE + 4 * i) for i in range(6)]
        self.plan_kinds = [pe.u32(PLAN_KIND_TABLE + 4 * i)
                           for i in range(PLAN_KIND_COUNT)]
        self.dir_table = [pe.u32(DIR_TABLE + 4 * i) for i in range(8)]
        self.corner_table = [pe.u32(CORNER_TABLE + 4 * i) for i in range(4)]

    def _text_span(self) -> tuple[int, int]:
        for name, vaddr, vsize, _raw, _rawsize in self.pe.sections:
            if name.startswith(".text"):
                base = self.pe.image_base + vaddr
                return base, base + vsize
        raise PEError("no .text section")

    def in_text(self, va: int) -> bool:
        return self.text_lo <= va < self.text_hi

    # -- the planner's six horizons -----------------------------------------

    def plan_mp_overrides(self) -> list[object]:
        """For each level arm, what it writes into ``unit[+0x15]``.

        Level 0 writes nothing, level 1 doubles with ``shl al, 1`` (``D0 E0``),
        the rest store an immediate with ``mov byte [edi + 0x15], imm8``
        (``C6 47 15 imm8``).
        """
        out: list[object] = []
        for i, arm in enumerate(self.plan_levels):
            end = self.plan_levels[i + 1] if i + 1 < len(self.plan_levels) else arm + 0x40
            found: object = None
            va = arm
            while va < end - 3:
                if self.pe.u8(va) == 0xD0 and self.pe.u8(va + 1) == 0xE0:
                    found = "x2"
                    break
                if (self.pe.u8(va) == 0xC6 and self.pe.u8(va + 1) == 0x47
                        and self.pe.u8(va + 2) == 0x15):
                    found = self.pe.u8(va + 3)
                    break
                va += 1
            out.append(found)
        return out

    def plan_pass_flags(self) -> list[int]:
        """The ``passFriendlies`` argument each level arm hands aBuildMoveMap.

        The call is ``push 0; push <ptr>; push imm8; push edi; call``, so the
        flag is the third ``6A imm8`` counting backwards from the call.
        """
        out = []
        for i, arm in enumerate(self.plan_levels):
            end = self.plan_levels[i + 1] if i + 1 < len(self.plan_levels) else arm + 0x40
            call = None
            for va in range(arm, end - 5):
                if self.pe.u8(va) == 0xE8 and va + 5 + self.pe.i32(va + 1) == BUILD_MOVE_MAP:
                    call = va
                    break
            if call is None:
                out.append(-1)
                continue
            imms = [v for _, v in _push_imms(self.pe, arm, call)]
            out.append(imms[-1] if imms else -1)
        return out

    # -- the two direction tables -------------------------------------------

    def corner_parts(self) -> dict[int, tuple[int, ...]]:
        """``dir -> the two direction indices its arm passes to the stepper``."""
        out = {}
        for i, arm in enumerate(self.corner_table):
            end = arm + 0x60
            imms = []
            va = arm
            while va < end:
                if self.pe.u8(va) == 0x6A:
                    imms.append(self.pe.u8(va + 1))
                    va += 2
                    continue
                if self.pe.u8(va) == 0xE8:
                    tgt = va + 5 + self.pe.i32(va + 1)
                    if tgt == 0x004308C0 and imms:
                        out.setdefault(4 + i, []).append(imms[-1])
                        if len(out[4 + i]) == 2:
                            break
                    va += 5
                    continue
                va += 1
            out[4 + i] = tuple(out.get(4 + i, []))
        return out

    # -- the hit-probability bands ------------------------------------------

    def hit_bands(self) -> list[tuple[int | None, int]]:
        """``(threshold, marker)`` pairs, read from the band ladder.

        Each band is ``cmp ecx, imm8`` (``83 F9 imm8``) followed by the
        ``push imm8`` that reaches ``0x0042F790``.
        """
        lo, hi = HIT_BAND_SPAN
        out: list[tuple[int | None, int]] = []
        pending: int | None = None
        va = lo
        while va < hi:
            if self.pe.u8(va) == 0x83 and self.pe.u8(va + 1) == 0xF9:
                pending = self.pe.u8(va + 2)
                va += 3
                continue
            if self.pe.u8(va) == 0x6A:
                marker = self.pe.u8(va + 1)
                # the marker push is the one directly before the call
                nxt = va + 2
                seen_call = False
                while nxt < va + 16:
                    if self.pe.u8(nxt) == 0xE8:
                        seen_call = (nxt + 5 + self.pe.i32(nxt + 1)) == MARKER_WRITER
                        break
                    nxt += 1
                if seen_call:
                    out.append((pending, marker))
                    pending = None
                va += 2
                continue
            va += 1
        if out:
            out[-1] = (None, out[-1][1])
        return out

    # -- warping -------------------------------------------------------------

    def warp_constants(self) -> dict[str, int]:
        """The three returns of ``0x00475380`` plus the two fields it tests.

        Found by pattern, not by counting offsets: ``38 48 disp8`` is the
        equipment test, ``B8 imm32`` the Jet Pack range, ``80 3C 55 <base>
        imm8`` the `special` comparison and ``83 E0 imm8`` the mask that turns
        its `setne`/`dec` into 7 or 0.
        """
        pe, out = self.pe, {}
        for va in range(WARP_RANGE, WARP_RANGE + 0x40):
            if pe.u8(va) == 0x38 and pe.u8(va + 1) == 0x48 and "equip_offset" not in out:
                out["equip_offset"] = pe.u8(va + 2)
            elif pe.u8(va) == 0xB8 and "jet_pack_range" not in out:
                out["jet_pack_range"] = pe.u32(va + 1)
            elif (pe.u8(va) == 0x80 and pe.u8(va + 1) == 0x3C
                  and pe.u8(va + 2) == 0x55 and "special_value" not in out):
                out["special_column"] = pe.u32(va + 3)
                out["special_value"] = pe.u8(va + 7)
            elif pe.u8(va) == 0x83 and pe.u8(va + 1) == 0xE0 and "special_mask" not in out:
                out["special_mask"] = pe.u8(va + 2)
        return out


    # -- the action-point legend --------------------------------------------

    def legend(self) -> list[str]:
        """Every string the legend block pushes, in push order."""
        lo, hi = LEGEND_SPAN
        out = []
        for va in range(lo, hi):
            if self.pe.u8(va) != 0x68:
                continue
            target = self.pe.u32(va + 1)
            if not 0x004B0000 <= target <= 0x004D8000:
                continue
            text = self.pe.cstring(target, 80)
            if text and text.strip():
                out.append(text)
        return out

    def tested_action_points(self) -> set[int]:
        """Every immediate the engine compares ``cell[+0x0B]`` against.

        Two encodings: ``80 /r 0B imm8`` compares the memory directly, and
        ``8A /r 0B`` loads it into a byte register that a ``cmp`` within the
        next dozen bytes tests.
        """
        pe, out = self.pe, {}
        for va in range(self.text_lo, self.text_hi - 8):
            modrm = pe.u8(va + 1)
            if (modrm >> 6) != 1 or (modrm & 7) == 4 or pe.u8(va + 2) != 0x0B:
                continue
            if pe.u8(va) == 0x80:
                out.setdefault(pe.u8(va + 3), []).append(va)
            elif pe.u8(va) == 0x8A:
                for k in range(3, 14):
                    if pe.u8(va + k) == 0x3C:                       # cmp al, imm8
                        out.setdefault(pe.u8(va + k + 1), []).append(va)
                        break
                    if pe.u8(va + k) == 0x80 and (pe.u8(va + k + 1) & 0xF8) == 0xF8:
                        out.setdefault(pe.u8(va + k + 2), []).append(va)
                        break
        self._actpt_sites = out
        return set(out)

    # -- the three obstacle makers ------------------------------------------

    def obstacle_makers(self) -> dict[int, tuple[tuple[str, ...], set[int]]]:
        """``maker -> (the models it names, the values it writes into +0x10)``.

        The models reach the inserter in ``mov edi, imm32``; the tag is
        ``C6 /r 10 imm8`` on whatever register holds the cell, and the ``0xFF``
        each maker writes first to clear the field is not a value.
        """
        pe = self.pe
        out = {}
        for maker in list(OBSTACLE_MAKERS) + [GLOW_MAKER]:
            end = maker + MAKER_SIZES[maker]
            models, values = [], set()
            for va in range(maker, end):
                if pe.u8(va) == 0xBF:                               # mov edi, imm32
                    text = pe.cstring(pe.u32(va + 1), 40)
                    if text and text.endswith(".3DI") and text not in models:
                        models.append(text)
                if (pe.u8(va) == 0xC6 and (pe.u8(va + 1) >> 6) == 1
                        and (pe.u8(va + 1) & 7) != 4 and pe.u8(va + 2) == 0x10
                        and pe.u8(va + 3) != 0xFF):
                    values.add(pe.u8(va + 3))
            out[maker] = (tuple(sorted(models)), values)
        return out


    # -- calls ---------------------------------------------------------------

    def callers_of(self, target: int) -> list[int]:
        pe = self.pe
        return [va for va in range(self.text_lo, self.text_hi - 5)
                if pe.u8(va) == 0xE8 and va + 5 + pe.i32(va + 1) == target]

    def refs_to(self, value: int) -> list[int]:
        pe = self.pe
        return [va for va in range(self.text_lo, self.text_hi - 4)
                if pe.u32(va) == value]

    def check_names_for(self, target: int) -> set[str]:
        """The hand-written names pushed by ``CHECK`` blocks guarding ``target``.

        The macro compiles to ``call target; …; push FILE; push LINE; push NAME``
        so the name is the third ``push imm32`` after the call, and the only one
        of the three that points at a bare identifier.
        """
        out = set()
        for site in self.callers_of(target):
            for va in range(site, site + 0x40):
                if self.pe.u8(va) != 0x68:
                    continue
                text = self.pe.cstring(self.pe.u32(va + 1), 64)
                if text and text.startswith("a") and " " not in text and "\\" not in text:
                    out.add(text)
        return out

    # -- the indirect-fire predicate ----------------------------------------

    def arcing(self) -> set[int]:
        """Weapon ids for which ``0x0047B600`` returns 1 (docs/22 5.5).

        ``add eax, -8`` biases the id, ``cmp eax, 0x26`` bounds it, a byte
        table picks one of five arms and one of the five is ``mov eax, 1``.
        All four are read out of the prologue rather than assumed.
        """
        pe = self.pe
        base = ARCING_PREDICATE
        bias = pe.u8(base + 6)
        bias = bias - 256 if bias > 127 else bias        # 83 C0 F8 -> -8
        span = pe.u8(base + 9) + 1                       # 83 F8 26
        index = pe.u32(base + 0x10)                      # 8A 88 <u32>
        jump = pe.u32(base + 0x17)                       # FF 24 8D <u32>
        yes = base + 0x1B                                # B8 01 00 00 00
        targets = [pe.u32(jump + 4 * i) for i in range(5)]
        return {-bias + i for i in range(span)
                if pe.u8(index + i) < len(targets)
                and targets[pe.u8(index + i)] == yes}


# ---------------------------------------------------------------------------
# Reading the corpus
# ---------------------------------------------------------------------------

class CorpusCounts:
    def __init__(self, root: str) -> None:
        self.paths = sorted(Path(root).rglob("*.lev"))
        self.missions = len(self.paths)
        self.placed = 0
        self.jet_pack = 0
        self.cells = 0
        self.primary: Counter[int] = Counter()
        self.secondary: Counter[int] = Counter()
        self.field_types: Counter[int] = Counter()
        self.effect_state: Counter[int] = Counter()
        self.actpt: Counter[int] = Counter()
        self.pairs = 0
        self.height_blocked = 0
        for path in self.paths:
            self._count(path)

    def _count(self, path: Path) -> None:
        battle = load_lev(path)
        for unit in battle.units:
            if unit.hit_points == 0:
                continue
            self.placed += 1
            self.primary[unit.raw[0x47]] += 1
            self.secondary[unit.raw[0x49]] += 1
            if unit.equipment[JET_PACK_EQUIP_ID]:
                self.jet_pack += 1
        grid = {(c.x, c.y): c for c in battle.cells}
        for cell in battle.cells:
            self.cells += 1
            self.field_types[cell.field_type] += 1
            self.effect_state[cell.effect_state] += 1
            self.actpt[cell.action_point] += 1
            for dx, dy in ((1, 0), (0, 1)):
                other = grid.get((cell.x + dx, cell.y + dy))
                if other is None:
                    continue
                self.pairs += 1
                if abs(cell.height - other.height) >= WORLD_UNITS_PER_FIELD:
                    self.height_blocked += 1


def _magic_div(n: int) -> int:
    """The compiler's signed divide, emulated bit for bit."""
    prod = (abs(n) * CLIMB_MAGIC) >> 32
    q = prod >> CLIMB_SHIFT
    return q


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

class Checker:
    def __init__(self) -> None:
        self.failed = 0
        self.passed = 0

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            self.passed += 1
            LOG.info("  ok    %-22s %s", name, detail)
        else:
            self.failed += 1
            LOG.error("  FAIL  %-22s %s", name, detail)

    def equal(self, name: str, got, want, fmt=str) -> None:
        self.check(name, got == want,
                   f"{fmt(got)}" if got == want else f"got {fmt(got)} want {fmt(want)}")


def _hexlist(values) -> str:
    return "[" + ", ".join(f"0x{v:08X}" for v in values) + "]"


def run_check(root: str) -> int:
    exe = os.path.join(root, GAME_EXE)
    if not os.path.isfile(exe):
        LOG.error("%s not found under %s", GAME_EXE, root)
        return 2
    pe = PEFile(exe)
    t = AITables(pe)
    c = Checker()

    LOG.info("aAISystemControl -- the order dispatch")
    c.equal("order.table", t.order_table, EXPECTED_ORDER_TABLE, _hexlist)
    c.check("order.in_text", all(t.in_text(v) for v in t.order_table),
            f"{ORDER_COUNT}/{ORDER_COUNT} arms inside .text")
    c.check("order.shared", t.order_table[1] == t.order_table[2],
            "orders 1 and 2 share one block")
    c.equal("order.default", t.order_default, EXPECTED_ORDER_TABLE[8],
            lambda v: f"0x{v:08X}")

    LOG.info("the six per-order level tables")
    for order in sorted(LEVEL_TABLES):
        _, expected = LEVEL_TABLES[order]
        c.equal(f"level.order{order}", t.level_tables[order], expected, _hexlist)
    defaults = {order: _rel_target(pe, guard) for order, guard in LEVEL_GUARD.items()}
    c.equal("level.default", defaults, EXPECTED_LEVEL_DEFAULT,
            lambda d: "{" + ", ".join(f"{k}:0x{v:08X}" for k, v in sorted(d.items())) + "}")

    LOG.info("the planner")
    c.equal("plan.levels", t.plan_levels, EXPECTED_PLAN_LEVELS, _hexlist)
    c.equal("plan.mp", t.plan_mp_overrides(), EXPECTED_PLAN_MP)
    c.equal("plan.pass", t.plan_pass_flags(), EXPECTED_PLAN_PASS)
    c.equal("plan.kinds", t.plan_kinds, EXPECTED_PLAN_KINDS, _hexlist)
    fallthrough = {t.plan_kinds[k - 1] for k in UNIMPLEMENTED_KINDS}
    c.check("plan.unused", len(fallthrough) == 1,
            f"kinds {sorted(UNIMPLEMENTED_KINDS)} share 0x{t.plan_kinds[3]:08X}")

    LOG.info("the two direction tables")
    c.equal("dir.table", t.dir_table, EXPECTED_DIR_TABLE, _hexlist)
    gated = {d for d, arm in enumerate(t.dir_table)
             if any(pe.u8(arm + i) == 0x85 and pe.u8(arm + i + 1) == 0xC0
                    for i in range(0, 10))}
    c.equal("dir.diagonal", sorted(gated), [4, 5, 6, 7])
    c.equal("corner.table", t.corner_table, EXPECTED_CORNER_TABLE, _hexlist)
    c.equal("corner.parts", t.corner_parts(),
            {d: v for d, v in EXPECTED_CORNER_PARTS.items()})

    LOG.info("aBuildMoveMap")
    c.equal("queue.frame", pe.u32(BUILD_MOVE_MAP + 1), MOVE_MAP_FRAME,
            lambda v: f"0x{v:04X}")
    stride = _find_imm32(pe, BUILD_MOVE_MAP, BUILD_MOVE_MAP + 0x200,
                         b"\xbd", MOVE_MAP_QUEUE_STRIDE)
    c.check("queue.stride", len(stride) == 1,
            f"mov ebp, {MOVE_MAP_QUEUE_STRIDE} at {_hexlist(stride)}")
    guard = _find_imm32(pe, BUILD_MOVE_MAP, BUILD_MOVE_MAP + 0x400,
                        b"\x3d", MOVE_MAP_QUEUE_GUARD)
    c.check("queue.guard", len(guard) == 1,
            f"cmp eax, {MOVE_MAP_QUEUE_GUARD} at {_hexlist(guard)}")
    cost = _find_imm32(pe, BUILD_MOVE_MAP, BUILD_MOVE_MAP + 0x400,
                       b"\x8a\x9a", COST_TABLE_READ)
    c.check("cost.read", len(cost) == 1,
            f"delay column 0x{COST_TABLE_READ:08X} read at {_hexlist(cost)}")
    c.check("cost.offset",
            COST_TABLE_READ - CTRL_MAP_INFO_BASE == 1,
            "SetCtrlMapInfo +0x01 is `delay`")

    LOG.info("the approach cell's tie-break")
    for name, (at, want) in (("large_keeps_the_incumbent", APPROACH_LARGE_TEST),
                             ("small_takes_a_later_tie", APPROACH_SMALL_TEST)):
        got = pe.bytes_at(at, len(want))
        c.check(f"approach.{name}", got == want,
                f"{got.hex()} at 0x{at:08X}, want {want.hex()}")

    LOG.info("the climb limit")
    magic = _find_imm32(pe, BUILD_MOVE_MAP, BUILD_MOVE_MAP + 0x400,
                        b"\xb8", CLIMB_MAGIC)
    c.check("climb.magic", len(magic) == 1,
            f"mov eax, 0x{CLIMB_MAGIC:08X} at {_hexlist(magic)}")
    exact = all(_magic_div(n) == n // CLIMB_DIVISOR for n in range(0, 200001))
    c.check("climb.div", exact, f"emulated multiply == n // {CLIMB_DIVISOR}")
    first = next(n for n in range(0, 200001)
                 if _magic_div(n) > CLIMB_MAX_QUOTIENT)
    c.equal("climb.threshold", first, WORLD_UNITS_PER_FIELD)

    LOG.info("the target overlay")
    c.equal("hit.bands", t.hit_bands(), EXPECTED_HIT_BANDS)

    LOG.info("warping")
    w = t.warp_constants()
    c.equal("warp.equip", w["equip_offset"], JET_PACK_UNIT_OFFSET,
            lambda v: f"unit[+0x{v:02X}] = equipment id {v - 0x21}")
    c.equal("warp.jetpack", w["jet_pack_range"], EXPECTED_WARP_JET_PACK)
    c.equal("warp.special", w["special_value"], WARP_SPECIAL_VALUE)
    c.equal("warp.mask", w["special_mask"], EXPECTED_WARP_SPECIAL)


    LOG.info("the action-point legend (docs/10 4.6)")
    legend = t.legend()
    c.equal("legend.entries", len(legend), EXPECTED_LEGEND_ENTRIES)
    named = {int(x.split(" - ")[0]): x for x in legend if x.split(" - ")[0].isdigit()}
    c.check("legend.names",
            all(named.get(k) == v for k, v in EXPECTED_LEGEND_NAMES.items()),
            ", ".join(f"{k}={named.get(k)!r}" for k in sorted(EXPECTED_LEGEND_NAMES)))
    c.check("legend.control", "*** Placefields ***" in legend,
            "the section headings are in the same block")
    tested = t.tested_action_points()
    c.equal("legend.tested", tested, EXPECTED_TESTED_ACTPT,
            lambda v: str(sorted(v)))
    c.equal("legend.door_sites", set(t._actpt_sites.get(31, [])),
            EXPECTED_ACTPT31_SITES, lambda v: _hexlist(sorted(v)))
    c.check("door.sequence", DOOR_SEQUENCE in
            [va + 5 + pe.i32(va + 1) for va in range(0x0040A600, 0x0040A6E0)
             if pe.u8(va) == 0xE8],
            f"0x0040A600 calls 0x{DOOR_SEQUENCE:08X}")
    c.check("door.name", EXPECTED_DOOR_NAMES <= t.check_names_for(DOOR_SEQUENCE),
            f"0x{DOOR_SEQUENCE:08X} is named {sorted(EXPECTED_DOOR_NAMES)}")

    LOG.info("cell[+0x10] -- the three obstacle makers")
    makers = t.obstacle_makers()
    for maker, (models, value) in sorted(OBSTACLE_MAKERS.items(),
                                         key=lambda kv: kv[1][1]):
        c.equal(f"obstacle.{value}", makers[maker], (tuple(sorted(models)), {value}))
    c.equal("obstacle.glow", makers[GLOW_MAKER],
            (tuple(sorted(GLOW_MODELS)), set()))

    LOG.info("the unit array and the read past its end")
    alloc = _find_imm32(pe, INIT_UNIT_MAP, INIT_UNIT_MAP + 0x20,
                        b"\x68", EXPECTED_UNIT_ARRAY_BYTES)
    clear = _find_imm32(pe, INIT_UNIT_MAP, INIT_UNIT_MAP + 0x80,
                        b"\xb9", EXPECTED_UNIT_ARRAY_DWORDS)
    c.check("unitmap.alloc", len(alloc) == 1 and len(clear) == 1,
            f"malloc {EXPECTED_UNIT_ARRAY_BYTES} at {_hexlist(alloc)}, "
            f"clear {EXPECTED_UNIT_ARRAY_DWORDS} dwords at {_hexlist(clear)}")
    c.equal("unitmap.exact", EXPECTED_UNIT_ARRAY_BYTES, UNIT_SLOTS * UNIT_STRIDE)
    c.equal("unitmap.cleared", EXPECTED_UNIT_ARRAY_DWORDS * 4,
            EXPECTED_UNIT_ARRAY_BYTES)
    oob = [pe.u8(va + 2) for va in range(0x0040B1A4, 0x0040B1E7)
           if pe.u8(va) == 0x8A and (pe.u8(va + 1) >> 6) == 1
           and (pe.u8(va + 1) & 7) == 6]                    # mov r8, [esi + disp8]
    c.equal("cover.oob", sorted(set(oob)), sorted(COVER_OOB_OFFSETS))

    LOG.info("provably absent (docs/23 1.2)")
    ai_sites = t.callers_of(AI_LEVEL)
    c.equal("ailevel.sites", len(ai_sites), EXPECTED_AI_LEVEL_SITES)
    intruders = [va for va in ai_sites
                 if AI_MODULE[0] <= va < AI_MODULE[1]
                 or MOVE_MAP_MODULE[0] <= va < MOVE_MAP_MODULE[1]]
    c.check("ailevel.absent", not intruders,
            "the difficulty is never read by the AI or the move map")
    c.equal("init.one_caller", t.callers_of(ANIM_INIT), [0x0044A05F], _hexlist)
    into_ai = [va for va in range(*A_MAIN)
               if pe.u8(va) == 0xE8
               and AI_MODULE[0] <= va + 5 + pe.i32(va + 1) < AI_MODULE[1]]
    c.check("init.no_ai_init",
            [va + 5 + pe.i32(va + 1) for va in into_ai] == [MAY_FIRE_SETTER],
            f"aMain reaches the AI module only through 0x{MAY_FIRE_SETTER:08X}")
    for g in WRITE_ONLY_GLOBALS:
        c.equal(f"dead.{g:08x}", len(t.refs_to(g)), 1)

    LOG.info("shared with docs/22")
    c.equal("arcing", t.arcing(), EXPECTED_ARCING, lambda v: str(sorted(v)))

    LOG.info("Info.lcl -- the movement costs")
    info = _load_info(root)
    costs = {nums[0]: nums[2] for nums, _ in info["SetCtrlMapInfo"]}
    c.equal("cost.table", costs, EXPECTED_DELAYS)
    ladder = [va for va in range(BUILD_MOVE_MAP, BUILD_MOVE_MAP + 0x400)
              if pe.u8(va) == 0x80 and pe.u8(va + 1) == 0x78
              and pe.u8(va + 2) == 0x0D and pe.u8(va + 3) == LADDER_TYPE]
    c.check("cost.ladder", len(ladder) == 1,
            f"the source cell's `cmp byte [eax + 0x0D], {LADDER_TYPE}` "
            f"at {_hexlist(ladder)}")
    parabomb = next((row for row in info["SetUnitInfo"]
                     if row[0][0] == PARABOMB_TYPE), None)
    got = None if parabomb is None else (
        parabomb[1][0], parabomb[0][1], parabomb[0][3],
        parabomb[0][8], parabomb[0][9])
    c.equal("parabomb", got, EXPECTED_PARABOMB)
    c.equal("parabomb.weapon", None if parabomb is None else parabomb[0][7],
            EXPECTED_PARABOMB_WEAPON)
    zero_heat = {nums[0]: strs[0] for nums, strs in info["SetWeaponInfo"]
                 if len(nums) > 14 and nums[14] == 0}
    c.equal("heat.zero", zero_heat, EXPECTED_ZERO_HEAT_WEAPONS)
    c.check("heat.parabomb", EXPECTED_PARABOMB_WEAPON in zero_heat,
            f"weapon {EXPECTED_PARABOMB_WEAPON} is never fired by the AI")

    LOG.info("provably dead")
    sites = [va for va in range(t.text_lo, t.text_hi - 4)
             if pe.u32(va) == DEAD_PASS_GLOBAL]
    c.equal("global.write_only", sites, EXPECTED_DEAD_PASS_SITES, _hexlist)

    LOG.info("the .lev corpus")
    counts = CorpusCounts(root)
    c.equal("corpus.missions", counts.missions, EXPECTED_MISSIONS)
    if counts.missions == 0:
        LOG.error("empty corpus -- nothing was examined")
        return 1
    c.equal("corpus.units", counts.placed, EXPECTED_PLACED_UNITS)
    c.equal("corpus.cells", counts.cells, EXPECTED_CELLS)
    c.equal("corpus.primary", dict(sorted(counts.primary.items())),
            EXPECTED_PRIMARY_ORDERS)
    c.equal("corpus.secondary", dict(sorted(counts.secondary.items())),
            EXPECTED_SECONDARY_ORDERS)
    c.equal("corpus.fields",
            {k: counts.field_types.get(k, 0) for k in EXPECTED_FIELD_TYPES},
            EXPECTED_FIELD_TYPES)
    c.equal("corpus.pairs", counts.pairs, EXPECTED_NEIGHBOUR_PAIRS)
    c.equal("corpus.blocked", counts.height_blocked, EXPECTED_HEIGHT_BLOCKED)
    c.equal("corpus.actpt31", counts.actpt.get(31, 0), EXPECTED_ACTPT31_CELLS)
    c.equal("corpus.jetpack", counts.jet_pack, EXPECTED_JET_PACK_UNITS)
    c.equal("corpus.effect_state", dict(counts.effect_state),
            EXPECTED_EFFECT_STATE)
    c.check("corpus.orders_range",
            all(0 <= v <= 10 for v in counts.primary)
            and all(0 <= v <= 10 for v in counts.secondary),
            "every shipped order byte is 0..10")

    total = c.passed + c.failed
    LOG.info("%d/%d checks passed", c.passed, total)
    return 1 if c.failed else 0


def _load_info(root: str) -> dict[str, list[tuple[list[int], list[str]]]]:
    """``SetCtrlMapInfo`` and ``SetUnitInfo`` rows from ``DATA/Info.lcl``.

    Each row is ``(numbers, strings)`` in source order, which is how
    ``docs/21`` numbers the columns.
    """
    path = os.path.join(root, "DATA", "Info.lcl")
    if not os.path.isfile(path):
        raise LevError(f"no DATA/Info.lcl under {root!r}")
    with open(path, "rb") as handle:
        program = lcl.parse_bytes(handle.read(), path)
    out: dict[str, list[tuple[list[int], list[str]]]] = {
        "SetCtrlMapInfo": [], "SetUnitInfo": [], "SetWeaponInfo": []}
    for stmt in program.statements():
        if stmt.name in out:
            nums = [a.value for a in stmt.args if a.kind == "number"]
            strs = [a.value for a in stmt.args if a.kind == "string"]
            out[stmt.name].append((nums, strs))
    return out


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

ORDER_NAMES = ["Berserk", "Move (ActPt)", "Attack (ActPt)", "Move (Group)",
               "Attack (Group)", "Turn (Wait)", "Range (Wait)", "Defend",
               "Visibility (Wait)", "Clever small units", "Disturb"]


def print_orders(root: str) -> int:
    pe = PEFile(os.path.join(root, GAME_EXE))
    t = AITables(pe)
    print(f"{'#':>2}  {'name':<20} {'handler':<12} level arms")
    for i, target in enumerate(t.order_table):
        arms = t.level_tables.get(i if i != 2 else 1)
        arms_s = " ".join(f"{a:06X}" for a in arms) if arms else "-"
        print(f"{i:>2}  {ORDER_NAMES[i]:<20} 0x{target:08X}  {arms_s}")
    print()
    print("planner horizons:")
    for level, (arm, mp, flag) in enumerate(zip(t.plan_levels,
                                                t.plan_mp_overrides(),
                                                t.plan_pass_flags())):
        mp_s = "own MP" if mp is None else ("MP x 2" if mp == "x2" else str(mp))
        print(f"  level {level}: 0x{arm:08X}  mp={mp_s:<7} passFriendlies={flag}")
    print()
    print("hit-probability bands:")
    for threshold, marker in t.hit_bands():
        bound = "  > previous" if threshold is None else f"<= {threshold:3d}"
        print(f"  hit {bound}  ->  marker {marker}")
    return 0


def dump_json(root: str) -> int:
    pe = PEFile(os.path.join(root, GAME_EXE))
    t = AITables(pe)
    counts = CorpusCounts(root)
    out = {
        "order_table": [f"0x{v:08X}" for v in t.order_table],
        "level_tables": {str(k): [f"0x{v:08X}" for v in arms]
                         for k, arms in t.level_tables.items()},
        "plan_levels": [f"0x{v:08X}" for v in t.plan_levels],
        "plan_mp": t.plan_mp_overrides(),
        "plan_pass": t.plan_pass_flags(),
        "plan_kinds": [f"0x{v:08X}" for v in t.plan_kinds],
        "dir_table": [f"0x{v:08X}" for v in t.dir_table],
        "corner_parts": {str(k): list(v) for k, v in t.corner_parts().items()},
        "hit_bands": t.hit_bands(),
        "warp": t.warp_constants(),
        "arcing": sorted(t.arcing()),
        "corpus": {
            "missions": counts.missions,
            "placed_units": counts.placed,
            "cells": counts.cells,
            "primary_orders": dict(sorted(counts.primary.items())),
            "secondary_orders": dict(sorted(counts.secondary.items())),
            "field_types": dict(sorted(counts.field_types.items())),
            "neighbour_pairs": counts.pairs,
            "height_blocked": counts.height_blocked,
            "jet_pack_units": counts.jet_pack,
        },
    }
    json.dump(out, sys.stdout, indent=1)
    print()
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", nargs="?", default="gog_incubation",
                    help="the game directory (default: gog_incubation)")
    ap.add_argument("--check", metavar="ROOT", help="run every check")
    ap.add_argument("--orders", action="store_true",
                    help="print the order and level tables")
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
        if args.json:
            return dump_json(root)
        return print_orders(root)
    except (PEError, LevError) as exc:
        LOG.error("%s", exc)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
