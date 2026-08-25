#!/usr/bin/env python3
"""Verify the turn and the round described in ``docs/25`` against the binary
and the corpus.

Four kinds of thing are checked:

**The game-control accessor bank in ``Incubation.exe``.**  ``aGameControl.cpp``
keeps the whole turn state in one struct reached through one-line accessors,
so the player count, the current player, the turn counter and the per-player
equipment-point pool can be read straight out of the accessors that touch
them, together with the bounds they enforce -- the 200-turn wrap, the 10000
equipment-point cap, the 500-point floor, and the ``0..4`` / ``255`` the
current-player setter admits.

**The hand-over state machine.**  ``0x0047D600`` decides whose turn is next and
returns a code that ``aNextPlayerHandling``'s four-arm switch dispatches on;
the table, its guard and all four arms are read out rather than inferred.

**Per-unit turn arithmetic.**  The start-of-turn refresh ``0x004781C0``, the
reaction-fire ticket ``0x00478500`` / ``0x0046CCA0`` pair, the stand-down and
stimulant helpers and the weapon-mode revert are pinned byte by byte: the
offsets they write, the constants they compare against, and -- for the
reaction queue -- the direction it drains in.

**Corpus counts.**  ``Info.lcl``'s ``weapon toggle`` column is checked to be an
involution over every shipped weapon, its eight non-trivial pairs are checked
to have exactly one member at or above the id the engine gates on, and the
fitness cap the refresh clamps to is replayed against every placed unit in all
155 shipped missions.

Every check fails on an empty corpus: a check that examined nothing is not a
check that passed.

Usage::

    python3 tools/turn_tables.py --check gog_incubation
    python3 tools/turn_tables.py --rotation gog_incubation
    python3 tools/turn_tables.py --json gog_incubation
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

import lcl_parse  # noqa: E402
from combat_tables import load_weapons  # noqa: E402
from inclib.lev import LevError, load_lev  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("turn_tables")

GAME_EXE = "Incubation.exe"

# ---------------------------------------------------------------------------
# aGameControl.cpp -- the state the turn runs on
# ---------------------------------------------------------------------------

#: The struct `aSaveGameControl` writes, and its size.  docs/11 §5.2 tabulates
#: it as save-file offsets; every address below is `GAME_CONTROL + offset`.
GAME_CONTROL = 0x00509D18
GAME_CONTROL_SIZE = 0x2D0

#: `aGameControl.cpp`'s accessors, taken from the first and last `CHECK` site
#: in the module.  Every global below must be referenced only from inside it.
GAME_CONTROL_LO = 0x0043AD00
GAME_CONTROL_HI = 0x0043BF20

#: `aSaveGameControl` pushes the size then the base.
GAME_CONTROL_SIZE_SITE = 0x0043BC3F
GAME_CONTROL_BASE_SITE = 0x0043BC44

#: turn counter, `+0x0105`.  getter / setter / advance.
TURN_COUNTER = 0x00509E1D
TURN_GET = 0x0043B280
TURN_SET = 0x0043B290
TURN_ADVANCE = 0x0043B2A0
#: `mov al, [turn]; inc al; cmp al, 200; mov [turn], al; jne; mov [turn], 0`.
TURN_ADVANCE_READ = 0x0043B2A1     # the imm32 of the load
TURN_ADVANCE_INC = 0x0043B2A5      # `fe c0`
TURN_WRAP_CMP = 0x0043B2A8         # the imm8 of `cmp al, 200`
TURN_ADVANCE_STORE = 0x0043B2AA    # the imm32 of the store
TURN_ADVANCE_ZERO = 0x0043B2B2     # the imm32 of `mov byte [turn], 0`
TURN_ADVANCE_ZERO_VALUE = 0x0043B2B6
TURN_WRAP = 200

#: per-player kind, `+0x0108`; `1` is the kind `0x0043B700` counts.
PLAYER_KIND = 0x00509E20
PLAYER_KIND_GET = 0x0043B6E0
PLAYER_KIND_SET = 0x0043B6A0
PLAYER_KIND_COUNT = 0x0043B700
#: `cmp dword [edi], 1` inside that count loop.
PLAYER_KIND_COUNT_CMP = 0x0043B717
PLAYER_KIND_HUMAN = 1

#: number of player slots, `+0x0118`.
PLAYER_COUNT = 0x00509E30
PLAYER_COUNT_GET = 0x0043B310
#: previous / current player, `+0x0119` / `+0x011A`.
PREVIOUS_PLAYER = 0x00509E31
CURRENT_PLAYER = 0x00509E32
CURRENT_PLAYER_GET = 0x0043B2C0
CURRENT_PLAYER_SET = 0x0043B2E0
#: the setter's bounds: `jl` / `cmp eax, 4` / `jle`, then `cmp eax, 255` / `je`.
CURRENT_PLAYER_MAX = 0x0043B2EA      # the imm8 of `cmp eax, 4`
CURRENT_PLAYER_ESCAPE = 0x0043B2EE   # the imm32 of `cmp eax, 0xff`
PSEUDO_PLAYER = 0xFF

#: player names, `+0x011B`: four 20-byte slots.
PLAYER_NAME = 0x00509E33
PLAYER_NAME_SET = 0x0043B5C0
PLAYER_NAME_GET = 0x0043B600
PLAYER_NAME_STRIDE = 20
#: the `strncpy` length pushed by the setter.
PLAYER_NAME_LEN_SITE = 0x0043B5D4

#: game mode, `+0x01D0`.
GAME_MODE = 0x00509EE8
GAME_MODE_GET = 0x0043B740
GAME_MODE_SET = 0x0043B730
#: `0x0043AD20` re-reads the mode and lays out the player slots from it.
PLAYER_SLOT_INIT = 0x0043AD20
#: `mov byte [PLAYER_COUNT], 1` in the mode-1 arm, `, 4` in the 2..4 arm.
SLOT_COUNT_CAMPAIGN_SITE = 0x0043AE7C
SLOT_COUNT_OTHER_SITE = 0x0043AD4A
SLOT_COUNT_CAMPAIGN = 1
SLOT_COUNT_OTHER = 4
#: the arm reached when the mode is outside 1..4.
NO_GAMETYPE_STRING = 0x004C4290
NO_GAMETYPE_SITE = 0x0043AE5C
#: the literals the ten mode setter sites push; three push nothing readable.
EXPECTED_MODE_LITERALS = {1: 4, 2: 1, 3: 2, None: 3}
MODE_CAMPAIGN = 1
MODE_NETWORK = 2
#: `0x00433DC0` formats the mode for a diagnostic line and so names all four.
#: The switch is `cmp eax, 4; ja default; jmp [eax*4 + table]`, and every arm
#: is `lea edx, [esp+0x10]; mov edi, <string>`.
GAME_MODE_NAME_GUARD = 0x00433DDC
GAME_MODE_NAME_TABLE = 0x00433FC8
GAME_MODE_NAME_STRING = 5          # the arm-relative offset of the imm32
EXPECTED_MODE_NAMES = {0: "undefined", 1: "campaign", 2: "net session",
                       3: "local session", 4: "pbm session"}

#: equipment points, `+0x01D4`: `u32[4]`, added to with a cap.
EQUIP_POINTS = 0x00509EEC
EQUIP_POINTS_ADD = 0x0043B010
EQUIP_POINTS_CAP_SITE = 0x0043B040
EQUIP_POINTS_CAP = 10000
#: the hand-over's own floor under the share it hands each player.
EQUIP_POINTS_FLOOR_SITE = 0x0047DD57
EQUIP_POINTS_FLOOR = 500
#: the floating-point arm of the split, `pool * (1.0 + 0.1 * humans) / humans`.
#: `fmul` takes -0.1 and `fsubr` subtracts the product from 1.0.
EQUIP_SHARE_SCALE_SITE = 0x0047DD1D    # the disp32 of `fmul qword [.]`
EQUIP_SHARE_BASE_SITE = 0x0047DD23     # the disp32 of `fsubr qword [.]`
EQUIP_SHARE_SCALE = -0.1
EQUIP_SHARE_BASE = 1.0

#: commendations, `+0x01E4`: `u8[4]`, decremented by `aDecDecorations`.
DECORATIONS = 0x00509EFC
DECORATIONS_DEC = 0x0043B120

#: "one human player" flag, `+0x01F0`.  Written by one setter only.
SOLO_FLAG = 0x00509F08
SOLO_FLAG_SET = 0x0043B1D0
SOLO_FLAG_GET = 0x0043B1E0
EXPECTED_SOLO_SETTERS = 4
#: the three sites that store into it, and the value each writes: the campaign
#: arm of the slot init, the arm for the other three modes, and the setter --
#: which `0x0043B770` calls with 1 when the human count is at most one.
EXPECTED_SOLO_WRITERS = (0x0043AE2B, 0x0043AF0D, 0x0043B1D5)
SOLO_CAMPAIGN_SITE = 0x0043AF11     # the imm32 of `mov dword [flag], 1`
SOLO_CAMPAIGN_VALUE = 1
#: `0x0043B1F0` -- the gate in front of the skip rule and the point split.
SKIP_GATE = 0x0043B1F0
SKIP_GATE_MODES = (0x0043B200, 0x0043B20A)   # the imm8s of `cmp eax, 2` / `4`
SKIP_GATE_LOCAL = 0x0043B214                 # and of `cmp eax, 3`
EXPECTED_SKIP_MODES = (2, 4, 3)

#: the twelve LCL game-control slots, `+0x0200`.  docs/20 owns their meaning.
LCL_SLOTS = 0x00509F18
LCL_SLOT_GET = 0x0043B160
LCL_SLOT_COUNT = 12

#: per-player scoreboard, `+0x0230`: four 40-byte records.  `0x0043B770`
#: initialises them, and `+0x20` is the state `0x0043B930` reads.
SCOREBOARD = 0x00509F48
SCOREBOARD_STRIDE = 40
SCOREBOARD_COUNT = 4
SCOREBOARD_STATE = 0x00509F68
SCOREBOARD_STATE_GET = 0x0043B930
SCOREBOARD_STATE_SET = 0x0043B960
STATE_OUT = 5
#: `0x0043B770`'s loop: base, stride, limit, and the `+0x20 = 1` it writes.
GAME_START = 0x0043B770
GAME_START_BASE = 0x0043B773      # the imm32 of `mov eax, 0x509F50`
GAME_START_STRIDE = 0x0043B791    # the imm8 of `add eax, 40`
GAME_START_LIMIT = 0x0043B793     # the imm32 of `cmp eax, 0x509FF0`
GAME_START_TURN_RESET = 0x0043B79E   # the imm32 of `mov byte [turn], bl`

#: every global above is private to `aGameControl.cpp`.
PRIVATE_GLOBALS = (TURN_COUNTER, PLAYER_KIND, PLAYER_COUNT, PREVIOUS_PLAYER,
                   CURRENT_PLAYER, GAME_MODE, SOLO_FLAG, SCOREBOARD_STATE)
#: the positive control: the reaction-ticket bank, which the same sweep does
#: find outside `aGameControl.cpp` -- and only inside `aUnitMap.cpp`.
SHARED_GLOBAL = 0x00517F50
EXPECTED_SHARED_SITES = (0x004781F1, 0x004784DD, 0x004784E6,
                         0x00478544, 0x0047854C, 0x00478558)
UNIT_MAP_LO = 0x00477750
UNIT_MAP_HI = 0x0047A900

# ---------------------------------------------------------------------------
# The hand-over
# ---------------------------------------------------------------------------

NEXT_PLAYER_HANDLING = 0x0047DC60
HAND_OVER = 0x0047D600
ADVANCE_PLAYER = 0x0043B320
SEARCH_FIRST_PLAYER = 0x0043B410
#: `aSearchFirstPlayer` starts at slot 0 and stops at the count.
SEARCH_FIRST_START = 0x0043B415     # xor cl, cl

#: `cmp esi, 3; ja default; jmp [esi*4 + table]` in `aNextPlayerHandling`.
RESULT_GUARD = 0x0047DDC4           # the imm of `cmp esi, 3`
RESULT_MAX = 3
RESULT_TABLE = 0x0047DE78
EXPECTED_RESULT_TABLE = [0x0047DE3C, 0x0047DDE5, 0x0047DDD2, 0x0047DDE5]
RESULT_DEFAULT = 0x0047DE6C

#: `aViewPlayer.cpp` -- every caller of `aNextPlayerHandling` is inside it.
VIEW_PLAYER_LO = 0x0047BC00
VIEW_PLAYER_HI = 0x0047EB70
EXPECTED_HANDOVER_CALLERS = 4

#: the view-state selector the four arms set, ViewPlayer `+0x04`.
VIEW_MODE_SET = 0x0047DBC0
VIEW_MODE_GET = 0x0047DBD0
#: three arms push a literal; the fourth pushes `ebx`, loaded with 1 at the
#: top of `aNextPlayerHandling`.
VIEW_MODE_ARMS = {0x0047DDD2: 3, 0x0047DDE5: 0}
VIEW_MODE_ARM_REGISTER = 0x0047DE3C
VIEW_MODE_EBX_SITE = 0x0047DCA7        # `mov ebx, 1`
VIEW_MODE_EBX = 1
#: and the hand-over itself sets 2 before it runs the AI.
VIEW_MODE_AI_SITE = 0x0047D658

#: `aRunLCL`'s environment slots.  docs/20 §5 names the call types; the value
#: is `None` where the site pushes a register rather than a literal.
LCL_ENTRY = 0x004402A0
LCL_SLOT_A, LCL_SLOT_B, LCL_SLOT_C = 0x41, 0x42, 0x43
LCL_CALL_NEXT_PLAYER, LCL_CALL_NEXT_TURN = 1, 5
LCL_EVENT_SITES = {
    0x0047D73F: (LCL_SLOT_A, LCL_CALL_NEXT_TURN),
    0x0047D754: (LCL_SLOT_B, None),
    0x0047D7A2: (LCL_SLOT_A, LCL_CALL_NEXT_PLAYER),
    0x0047D7B7: (LCL_SLOT_B, None),
    0x0047D7CC: (LCL_SLOT_C, None),
}
#: `CheckCurrentTurn` reads the same counter the hand-over advances.
CHECK_CURRENT_TURN = 0x004409A0

#: the block `aSaveViewPlayer` writes, and the module that owns it.
VIEW_PLAYER_BLOCK = 0x005229D0
VIEW_PLAYER_SIZE = 0x44C
VIEW_PLAYER_SAVE = 0x0047DBE0
EXPECTED_VIEW_PLAYER_OFFSETS = (0x000, 0x004, 0x00C, 0x010, 0x014, 0x018,
                                0x01C, 0x020, 0x024, 0x028, 0x02C, 0x030,
                                0x034, 0x038, 0x43C, 0x440, 0x444, 0x448)
EXPECTED_VIEW_PLAYER_SITES = 73
#: the unaddressed span between the two clusters.
VIEW_PLAYER_GAP = (0x03C, 0x43C)

# ---------------------------------------------------------------------------
# Weapon modes
# ---------------------------------------------------------------------------

#: `SetWeaponInfo` records: base, stride, and the `weapon toggle` column.
#: docs/21 §4 gives the record layout; `+0x3D` is the developers' own name.
WEAPON_INFO = 0x0051B2C0
WEAPON_STRIDE = 0x43
WEAPON_TOGGLE = 0x3D
WEAPON_DEFENCE = 0x32
WEAPON_HEAT = 0x3A

#: the three sites that revert an alternate mode.  Two compare the unit's
#: weapon id against its own `weapon toggle` column first; the third -- unit
#: creation -- gates on the id alone, which is a no-op for a fixed point.
TOGGLE_ROUTINE = 0x0047A8C0
TOGGLE_COLUMN_SITES = (0x0047DC8D,    # aNextPlayerHandling, over all 200 slots
                       0x00478371)    # the refresh, the incoming player's units
TOGGLE_GATE_SITES = (0x0047DC95,      # aNextPlayerHandling
                     0x0047837A,      # the refresh
                     0x00477607)      # unit creation
TOGGLE_GATE_ID = 20
EXPECTED_TOGGLE_CALLERS = 4
#: `aToggleWeaponModes` itself: `unit[+0x3F] = weapon[unit[+0x3F]].toggle`.
TOGGLE_UNIT_READ = 0x0047A8C8         # the disp8 of `mov al, [ecx + 0x3F]`
TOGGLE_SHIFT = 0x0047A8CD             # the imm8 of `shl edx, 5`
TOGGLE_COLUMN = 0x0047A8D3            # the disp32 of the table read
TOGGLE_UNIT_WRITE = 0x0047A8D9        # the disp8 of the store back
UNIT_WEAPON = 0x3F

# ---------------------------------------------------------------------------
# Reaction fire
# ---------------------------------------------------------------------------

MARK_REACTION = 0x00478500
REACTION_DRAIN = 0x0046CCA0
CAN_ATTACK = 0x004753E0
#: the per-player ticket counters the refresh zeroes.
TICKET_COUNTER = 0x00517F50
TICKET_COUNTER_SLOTS = 4
#: `unit[+0x41] = 1` and `unit[+0x59] = ++counter[player]`.
ACTION_STATE = 0x41
REACTION_PENDING = 1
TICKET = 0x59
REACTION_GUARD_CALL = 0x0047852A      # `call 0x004753E0`
REACTION_STATE_SITE = 0x0047853C      # the disp8 of `mov byte [esi+0x41], 1`
REACTION_TICKET_SITE = 0x00478544     # the disp32 of the counter read
#: `0x00478500`'s two callers, and the defence-mode values that admit them.
EXPECTED_REACTION_CALLERS = 2
REACTION_DEFENCE_SITES = (0x0040A729, 0x0040A72D)
EXPECTED_REACTION_DEFENCE = (1, 4)
#: `0x004790F0(unit, x, y)` -- the reactor's firing arc.  It takes the heading
#: to the target and its two neighbouring octants and compares all three against
#: the unit's own facing, so the arc is 135 degrees wide.
FIRING_ARC = 0x004790F0
ARC_HEADING = 0x0046A760
ARC_NEIGHBOURS = (0x0046A930, 0x0046A9A0)
ARC_FACING_SITE = 0x0047912F        # the disp8 of `mov cl, [edi + 0x46]`
UNIT_FACING = 0x46
ARC_COMPARES = (0x00479130, 0x00479134, 0x00479138)

#: the drain: campaign-only ticket order, starting at 1 and counting up.
DRAIN_MODE_SITE = 0x0046CCAE
DRAIN_FIRST_TICKET_SITE = 0x0046CCF9
DRAIN_FIRST_TICKET = 1
#: `inc ebx` after a match and after an empty sweep, and the terminator
#: `cmp [max], ebx; jle` -- so the queue is walked from the lowest ticket up.
DRAIN_INC_SITES = (0x0046CD67, 0x0046CEB7)
DRAIN_TERMINATOR = 0x0046CEAD
EXPECTED_DRAIN_CALLERS = 5
#: how far the sweep for ``unit[+0x41]`` stores runs -- past the routine's end.
DRAIN_SPAN = 0x500

# ---------------------------------------------------------------------------
# The start-of-turn refresh
# ---------------------------------------------------------------------------

TURN_REFRESH = 0x004781C0
TURN_REFRESH_CALLER = 0x00419D5B
#: the ticket bank it zeroes before walking the units.
REFRESH_TICKET_SITE = 0x004781F1
#: the fields it writes, as `(site of the disp8, offset, value or None)`.
REFRESH_WRITES = (
    (0x004782D9, 0x19, None),   # fitness, from the cap below
    (0x004782DC, 0x58, 0xFF),   # `cmp byte [esi+0x58], 0xFF` -- stimulant spent
    (0x004782E2, 0x58, 0x00),   # ... reset so it can be used again
    (0x004782EC, 0x52, None),   # y at the start of the turn
    (0x004782F4, 0x50, 0x00),
    (0x004782F8, 0x51, None),   # x at the start of the turn
    (0x004782FD, 0x57, 0x01),   # rested
    (0x00478303, 0x57, 0x00),
    (0x0047830F, 0x41, 0x00),   # the action state is cleared here
    (0x0047835E, 0x59, 0x00),   # and the reaction ticket with it
)
#: and the test that decides `rested`: `mov al, [esi+0x41]; cmp al, 7`.
REFRESH_STOOD_DOWN_SITE = 0x004782EF
REFRESH_STOOD_DOWN_CMP = 0x004782F1

FP_CAP = 0x00475120
#: fitness is `max(3, EP / 12)` unless the type's `FP max` column is 255.
FP_FLOOR = 3
FP_DIVISOR = 12
FP_DISABLED = 255
#: `SetUnitInfo` records: the `FP max` column `0x00475120` tests (docs/21 §3).
UNIT_INFO_FP_MAX_TABLE = 0x0051C023
UNIT_INFO_STRIDE = 0x7E
#: `shl edx, 6; sub edx, eax` then a `*2` scale -- the record stride.
FP_CAP_SHIFT_SITE = 0x0047512D
FP_CAP_TABLE_SITE = 0x00475135
#: the compiler's `/ 12`: multiply high by 0x2AAAAAAB, then `sar 1`.
FP_CAP_MAGIC_SITE = 0x00475143
FP_CAP_MAGIC = 0x2AAAAAAB
FP_CAP_FLOOR_SITE = 0x00475155
FP_CAP_FLOOR_VALUE_SITE = 0x00475159

#: the heat column, and the 255 that disables cooling altogether.
HEAT_GUARD_SITE = 0x00478321          # the disp32 of the column read
HEAT_GUARD_VALUE_SITE = 0x00478325
HEAT_DISABLED = 0xFF
#: `sub eax, n; je two` three times -- the running sum names the weapon ids
#: whose heat falls by two a turn rather than one.
HEAT_DECAY_SITES = (0x0047832F, 0x00478334, 0x00478339)
EXPECTED_HEAT_DECAY_IDS = (4, 6, 0x29)
#: the malfunction ladder, read as `cmp`/`mov` pairs in source order.
MALFUNCTION_SITES = (0x00478386, 0x00478390, 0x0047839A,
                     0x004783A4, 0x004783AE)
MALFUNCTION = 0x40
EXPECTED_MALFUNCTION = {1: 0, 2: 1, 3: 0, 4: 3, 5: 4}

#: `aExecuteMove`'s per-step accumulator into `unit[+0x50]`.  The step
#: direction picks the increment: 4..7 are the diagonal headings of
#: [`10` §5.10], and cost half a field more than the orthogonal ones.
WALK_COUNTER = 0x50
WALK_DIR_LO_SITE = 0x0046E7A3       # the imm8 of `cmp eax, 4`
WALK_DIR_HI_SITE = 0x0046E7A8       # the imm8 of `cmp eax, 7`
WALK_DIAGONAL_SITE = 0x0046E7AF     # the imm8 of `add al, 15`
WALK_ORTHOGONAL_SITE = 0x0046E7B6   # the imm8 of `add al, 10`
WALK_STORE_SITE = 0x0046E7B9        # the disp8 of `mov [edi+0x50], al`
EXPECTED_WALK_DIRS = (4, 7)
EXPECTED_WALK_COST = (15, 10)
#: the only two byte stores into `unit[+0x50]` anywhere: this one and the
#: refresh's reset.  Every other `[reg+0x50]` store in `.text` is a different
#: struct in a different module.
UNIT_MODULES = ((0x0046A000, 0x00471000),   # aTacTools.cpp
                (0x00477750, 0x0047A900))   # aUnitMap.cpp
EXPECTED_WALK_STORES = (0x0046E7B7, 0x004782F2)

#: stand down, and the stimulant that pays movement points back.
STAND_DOWN = 0x00478570
STAND_DOWN_STATE_SITE = 0x00478599     # `mov byte [eax+0x41], 7`
STAND_DOWN_MP_SITE = 0x0047859D        # `mov byte [eax+0x15], 0`
STOOD_DOWN = 7
STIMULANT_SPEND = 0x004785B0
STIMULANT_READ_SITE = 0x004785D9
STIMULANT_SPENT_CMP = 0x004785E3
STIMULANT_MARK_SITE = 0x004785EE
STIMULANT_MP_SITE = 0x004785F4
STIMULANT = 0x58
STIMULANT_SPENT = 0xFF
MOVEMENT_POINTS = 0x15
#: the AI's per-unit epilogue.
END_UNIT_TURN = 0x0040B380

# ---------------------------------------------------------------------------
# Corpus expectations
# ---------------------------------------------------------------------------

EXPECTED_MISSIONS = 155
EXPECTED_SCRIPTS = 176
#: `Info.lcl`'s weapon table, and what the toggle column looks like in it.
EXPECTED_TOGGLE_PAIRS = {6: 41, 7: 40, 8: 42, 9: 43,
                         10: 45, 11: 44, 13: 46, 14: 47}
#: how many records carry each `defence mode` value.
EXPECTED_DEFENCE = {0: 31, 1: 10}
#: `CheckCurrentTurn` sites across the shipped scripts.
EXPECTED_CHECK_TURN_SITES = 2
EXPECTED_CHECK_TURN_FILES = ["_C_153.lcl"]
EXPECTED_CHECK_TURN_BOUNDS = {(3, 15): 1, (15, 25): 1}


# ---------------------------------------------------------------------------
# Reading the binary
# ---------------------------------------------------------------------------

class TurnTables:
    """Everything ``docs/25`` claims about ``Incubation.exe``."""

    def __init__(self, pe: PEFile) -> None:
        self.pe = pe
        self.text_lo, self.text_hi = self._text_span()

    def _text_span(self) -> tuple[int, int]:
        vaddr, vsize, _raw, _rawsize = self.pe.section(".text")
        return vaddr, vaddr + vsize

    def in_text(self, va: int) -> bool:
        return self.text_lo <= va < self.text_hi

    # -- call and reference sweeps ------------------------------------------

    def callers_of(self, target: int) -> list[int]:
        pe = self.pe
        return [va for va in range(self.text_lo, self.text_hi - 5)
                if pe.u8(va) == 0xE8 and va + 5 + pe.i32(va + 1) == target]

    def refs_to(self, value: int) -> list[int]:
        pe = self.pe
        return [va for va in range(self.text_lo, self.text_hi - 4)
                if pe.u32(va) == value]

    def pushed_before(self, site: int) -> int | None:
        """The immediate of a ``push`` that ends exactly at ``site``."""
        pe = self.pe
        if pe.u8(site - 2) == 0x6A:
            return pe.u8(site - 1)
        if pe.u8(site - 5) == 0x68:
            return pe.u32(site - 4)
        return None

    # -- the game-control bank ----------------------------------------------

    def mode_literals(self) -> Counter:
        """What the ten ``set game mode`` call sites push."""
        return Counter(self.pushed_before(site)
                       for site in self.callers_of(GAME_MODE_SET))

    def mode_names(self) -> dict[int, str]:
        """``mode -> the word the binary prints for it``."""
        pe = self.pe
        out = {}
        for i in range(len(EXPECTED_MODE_NAMES)):
            arm = pe.u32(GAME_MODE_NAME_TABLE + 4 * i)
            out[i] = pe.cstring(pe.u32(arm + GAME_MODE_NAME_STRING), 32)
        return out

    def private_globals(self) -> dict[int, list[int]]:
        """Sites outside ``aGameControl.cpp`` that name a turn-state global."""
        out = {}
        for value in PRIVATE_GLOBALS:
            out[value] = [va for va in self.refs_to(value)
                          if not GAME_CONTROL_LO <= va < GAME_CONTROL_HI]
        return out

    def scoreboard_init(self) -> tuple[int, int, int]:
        """``(base, stride, limit)`` of ``0x0043B770``'s clear loop.

        The loop counts from the record's ``+0x08`` rather than its start, so
        the base it loads is ``SCOREBOARD + 8``.
        """
        pe = self.pe
        return (pe.u32(GAME_START_BASE), pe.u8(GAME_START_STRIDE),
                pe.u32(GAME_START_LIMIT))

    # -- the hand-over -------------------------------------------------------

    @property
    def result_table(self) -> list[int]:
        return [self.pe.u32(RESULT_TABLE + 4 * i) for i in range(4)]

    def view_modes(self) -> dict[int, int | None]:
        """``arm -> literal`` for the switch arms that set the view state."""
        out = {arm: self.pushed_before(arm + 2) for arm in VIEW_MODE_ARMS}
        out[VIEW_MODE_ARM_REGISTER] = (
            self.pe.u32(VIEW_MODE_EBX_SITE + 1)
            if self.pe.u8(VIEW_MODE_EBX_SITE) == 0xBB else None)
        return out

    def lcl_events(self) -> dict[int, tuple[int, int | None]]:
        """``site -> (slot, literal)`` for the hand-over's ``aRunLCL`` calls.

        The convention is ``push value; push slot; call``, so the slot is the
        ``push imm8`` that ends at the call and the value the one before it.
        """
        pe = self.pe
        out = {}
        for site in self.callers_of(LCL_ENTRY):
            if not HAND_OVER <= site < NEXT_PLAYER_HANDLING:
                continue
            if pe.u8(site - 2) != 0x6A:
                continue
            out[site] = (pe.u8(site - 1),
                         pe.u8(site - 3) if pe.u8(site - 4) == 0x6A else None)
        return out

    def view_player_block(self) -> tuple[int, int]:
        """``(base, size)`` as ``aSaveViewPlayer`` pushes them."""
        pe = self.pe
        return pe.u32(VIEW_PLAYER_SAVE + 0x0A), pe.u32(VIEW_PLAYER_SAVE + 0x05)

    def view_player_offsets(self) -> dict[int, list[int]]:
        """Absolute-displacement references into the ViewPlayer block.

        A raw ``u32`` sweep also hits the displacement of a ``call`` whose
        opcode byte happens to precede a matching address, so a hit is kept
        only when the four bytes are not the tail of a ``call rel32``.
        """
        pe = self.pe
        base, size = VIEW_PLAYER_BLOCK, VIEW_PLAYER_SIZE
        out: dict[int, list[int]] = {}
        for va in range(self.text_lo, self.text_hi - 4):
            value = pe.u32(va)
            if base <= value < base + size and self._is_disp32(va):
                out.setdefault(value - base, []).append(va)
        return out

    def _is_disp32(self, va: int) -> bool:
        """Is the dword at ``va`` an absolute displacement, not a coincidence?

        A raw ``u32`` sweep also hits the four bytes that start at the opcode
        of a ``call rel32``.  Requiring the preceding byte to be one of the
        forms MSVC uses for an absolute address -- ``A1``/``A3`` (accumulator
        moves), ``push imm32``, a ModRM with ``mod=00, rm=101``, or a SIB with
        no base -- keeps every real access and drops the coincidences.
        """
        prev, prev2 = self.pe.u8(va - 1), self.pe.u8(va - 2)
        if prev in (0xA1, 0xA3, 0x68):
            return True
        if (prev & 0xC7) == 0x05:
            return True
        return prev == 0x85 and (prev2 & 0xC7) == 0x04

    # -- weapon modes --------------------------------------------------------

    def toggle_columns(self) -> tuple[int, ...]:
        """The record column each revert site compares the weapon id against.

        Each is ``cmp byte [eax + edx*2 + disp], cl``: the compiler builds the
        67-byte record stride as ``eax + (eax * 33) * 2``, so ``disp`` is
        ``WEAPON_INFO + column``.
        """
        return tuple(self.pe.u32(site) - WEAPON_INFO
                     for site in TOGGLE_COLUMN_SITES)

    def toggle_gates(self) -> tuple[int, ...]:
        return tuple(self.pe.u8(site) for site in TOGGLE_GATE_SITES)

    def toggle_body(self) -> tuple[int, int, int, int]:
        """``(read offset, column, stride, write offset)`` of the toggle."""
        pe = self.pe
        stride = 2 * ((1 << pe.u8(TOGGLE_SHIFT)) + 1) + 1
        return (pe.u8(TOGGLE_UNIT_READ), pe.u32(TOGGLE_COLUMN) - WEAPON_INFO,
                stride, pe.u8(TOGGLE_UNIT_WRITE))

    # -- reaction fire -------------------------------------------------------

    def reaction_defence_values(self) -> tuple[int, ...]:
        return tuple(self.pe.u8(site) for site in REACTION_DEFENCE_SITES)

    def drain_writes_action_state(self) -> list[int]:
        """Sites inside the drain that store into ``unit[+0x41]``.

        ``C6 /0 ib`` (store an immediate) and ``88 /r`` (store a register),
        both with a one-byte displacement of ``0x41``, are the forms the
        compiler uses for this field everywhere else in the binary; an empty
        result is the claim being checked.
        """
        pe = self.pe
        out = []
        for va in range(REACTION_DRAIN, REACTION_DRAIN + DRAIN_SPAN):
            if (pe.u8(va) in (0x88, 0xC6) and (pe.u8(va + 1) >> 6) == 1
                    and (pe.u8(va + 1) & 7) != 4
                    and pe.u8(va + 2) == ACTION_STATE):
                out.append(va)
        return out

    # -- the refresh ---------------------------------------------------------

    def heat_decay_ids(self) -> tuple[int, ...]:
        """The three ``sub eax, n`` steps, as the weapon ids they select."""
        ids, running = [], 0
        for site in HEAT_DECAY_SITES:
            running += self.pe.u8(site)
            ids.append(running)
        return tuple(ids)

    def malfunction_ladder(self) -> dict[int, int]:
        """``cmp byte [esi+0x40], n`` / ``mov byte [esi+0x40], m`` pairs."""
        pe = self.pe
        out = {}
        for site in MALFUNCTION_SITES:
            if pe.u8(site + 2) != MALFUNCTION or pe.u8(site + 8) != MALFUNCTION:
                continue
            out[pe.u8(site + 3)] = pe.u8(site + 9)
        return out

    def walk_counter_stores(self) -> list[int]:
        """Byte stores into ``unit[+0x50]`` inside the two unit-owning modules."""
        pe = self.pe
        out = []
        for lo, hi in UNIT_MODULES:
            for va in range(lo, hi):
                if (pe.u8(va) in (0x88, 0xC6) and (pe.u8(va + 1) >> 6) == 1
                        and (pe.u8(va + 1) & 7) != 4
                        and pe.u8(va + 2) == WALK_COUNTER):
                    out.append(va)
        return out

    def refresh_writes(self) -> tuple[tuple[int, int, int | None], ...]:
        """``(site, offset, value)`` for every field the refresh touches."""
        pe = self.pe
        return tuple((site, pe.u8(site),
                      None if value is None else pe.u8(site + 1))
                     for site, _off, value in REFRESH_WRITES)


# ---------------------------------------------------------------------------
# Reading the corpus
# ---------------------------------------------------------------------------

def load_info(root: str) -> dict[str, list[tuple[list[int], list[str]]]]:
    """``SetUnitInfo`` / ``SetWeaponInfo`` / ``SetWeaponInfo2`` rows."""
    path = os.path.join(root, "DATA", "Info.lcl")
    if not os.path.isfile(path):
        raise LevError(f"no DATA/Info.lcl under {root!r}")
    with open(path, "rb") as handle:
        program = lcl_parse.parse_bytes(handle.read(), path)
    out: dict[str, list[tuple[list[int], list[str]]]] = {
        "SetUnitInfo": [], "SetWeaponInfo": [], "SetWeaponInfo2": []}
    for stmt in program.statements():
        if stmt.name in out:
            nums = [a.value for a in stmt.args if a.kind == "number"]
            strs = [a.value for a in stmt.args if a.kind == "string"]
            out[stmt.name].append((nums, strs))
    return out


class Corpus:
    """The shipped data every corpus check reads."""

    def __init__(self, root: str) -> None:
        self.root = root
        self.info = load_info(root)
        self.weapons = load_weapons(root)

        #: weapon id -> `defence mode` (`SetWeaponInfo` column 5, record +0x32)
        self.defence = {n[0]: n[5] for n, _s in self.info["SetWeaponInfo"]
                        if len(n) >= 18}
        #: weapon id -> `icon` (`SetWeaponInfo2` column 3, record +0x42)
        self.icon = {n[0]: n[3] for n, _s in self.info["SetWeaponInfo2"]
                     if len(n) >= 4}
        #: weapon id -> `key` (`SetWeaponInfo2` string 1, record +0x40)
        self.key = {n[0]: (s[1] if len(s) > 1 else "")
                    for n, s in self.info["SetWeaponInfo2"] if len(n) >= 4}
        #: unit type -> `FP max`, the column `0x00475120` tests against 255
        self.fp_max = {n[0]: n[4] for n, _s in self.info["SetUnitInfo"]
                       if len(n) >= 5}

        self.missions = sorted(Path(root).rglob("*.lev"))
        self.scripts = sorted(Path(root).rglob("*.lcl"))
        self.placed = 0
        self.fp_ok = 0
        self.fp_disabled = 0
        self.alternate_carriers = 0
        self.action_state: Counter[int] = Counter()
        for path in self.missions:
            self._count(path)

        self.check_turn_sites = 0
        self.check_turn_files: set[str] = set()
        self.check_turn_bounds: Counter[tuple[int, int]] = Counter()
        for path in self.scripts:
            self._count_script(path)

    def _count(self, path: Path) -> None:
        battle = load_lev(path)
        for unit in battle.units:
            if unit.hit_points == 0:
                continue
            self.placed += 1
            self.action_state[unit.raw[ACTION_STATE]] += 1
            if self.weapons.get(unit.weapon) is not None:
                base = self.weapons[unit.weapon].toggle
                if base != unit.weapon and unit.weapon >= TOGGLE_GATE_ID:
                    self.alternate_carriers += 1
            cap = self.fp_max.get(unit.type_id, FP_DISABLED)
            if cap == FP_DISABLED:
                self.fp_disabled += 1
                if unit.fp == FP_DISABLED:
                    self.fp_ok += 1
            else:
                if unit.fp <= max(FP_FLOOR, unit.ep // FP_DIVISOR):
                    self.fp_ok += 1

    def _count_script(self, path: Path) -> None:
        with open(path, "rb") as handle:
            program = lcl_parse.parse_bytes(handle.read(), str(path))
        for stmt in program.statements():
            if stmt.name != "CheckCurrentTurn":
                continue
            nums = [a.value for a in stmt.args if a.kind == "number"]
            self.check_turn_sites += 1
            self.check_turn_files.add(path.name)
            if len(nums) >= 2:
                self.check_turn_bounds[(nums[0], nums[1])] += 1


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
            LOG.info("  ok    %-26s %s", name, detail)
        else:
            self.failed += 1
            LOG.error("  FAIL  %-26s %s", name, detail)

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
    t = TurnTables(pe)
    corpus = Corpus(root)
    c = Checker()

    if not corpus.missions:
        LOG.error("no .lev files under %s -- nothing to check", root)
        return 2
    if not corpus.weapons:
        LOG.error("no weapons in Info.lcl under %s", root)
        return 2

    # -- the game-control bank ----------------------------------------------
    LOG.info("aGameControl.cpp -- the state a turn runs on")

    c.equal("gc.block",
            (pe.u32(GAME_CONTROL_BASE_SITE), pe.u32(GAME_CONTROL_SIZE_SITE)),
            (GAME_CONTROL, GAME_CONTROL_SIZE),
            lambda v: f"0x{v[0]:08X} + {v[1]:#x}")

    c.equal("turn.wrap", pe.u8(TURN_WRAP_CMP), TURN_WRAP)
    c.check("turn.advance",
            (pe.u8(TURN_ADVANCE_INC) == 0xFE
             and pe.u32(TURN_ADVANCE_READ) == TURN_COUNTER
             and pe.u32(TURN_ADVANCE_STORE) == TURN_COUNTER
             and pe.u32(TURN_ADVANCE_ZERO) == TURN_COUNTER
             and pe.u8(TURN_ADVANCE_ZERO_VALUE) == 0),
            "read, inc, compare, store, zero on wrap")
    c.check("turn.getter", pe.u32(TURN_GET + 1) == TURN_COUNTER,
            f"0x{TURN_GET:08X} reads 0x{TURN_COUNTER:08X}")
    c.check("turn.reset", pe.u32(GAME_START_TURN_RESET) == TURN_COUNTER,
            f"0x{GAME_START:08X} zeroes it at game start")

    c.equal("player.count_campaign", pe.u8(SLOT_COUNT_CAMPAIGN_SITE),
            SLOT_COUNT_CAMPAIGN)
    c.equal("player.count_other", pe.u8(SLOT_COUNT_OTHER_SITE),
            SLOT_COUNT_OTHER)
    c.check("player.no_gametype",
            t.pushed_before(NO_GAMETYPE_SITE + 5) == NO_GAMETYPE_STRING
            and pe.cstring(NO_GAMETYPE_STRING, 64) == "no gametype selected",
            "the out-of-range arm names the mode")
    c.equal("player.setter_max", pe.u8(CURRENT_PLAYER_MAX), 4)
    c.equal("player.setter_escape", pe.u32(CURRENT_PLAYER_ESCAPE),
            PSEUDO_PLAYER)
    c.check("player.kind_count", pe.u8(PLAYER_KIND_COUNT_CMP + 2)
            == PLAYER_KIND_HUMAN,
            f"0x{PLAYER_KIND_COUNT:08X} counts kind {PLAYER_KIND_HUMAN}")
    c.equal("player.name_stride", pe.u8(PLAYER_NAME_LEN_SITE + 1),
            PLAYER_NAME_STRIDE)

    modes = t.mode_literals()
    c.equal("mode.literals", dict(modes), EXPECTED_MODE_LITERALS)
    c.equal("mode.names", t.mode_names(), EXPECTED_MODE_NAMES)
    c.equal("mode.name_guard", pe.u8(GAME_MODE_NAME_GUARD),
            max(EXPECTED_MODE_NAMES),
            lambda v: f"the name switch bounds the mode at {v}")

    c.equal("ep.cap", pe.u32(EQUIP_POINTS_CAP_SITE), EQUIP_POINTS_CAP)
    c.equal("ep.floor", pe.u32(EQUIP_POINTS_FLOOR_SITE), EQUIP_POINTS_FLOOR)
    c.equal("ep.share",
            (pe.f64(pe.u32(EQUIP_SHARE_SCALE_SITE)),
             pe.f64(pe.u32(EQUIP_SHARE_BASE_SITE))),
            (EQUIP_SHARE_SCALE, EQUIP_SHARE_BASE),
            lambda v: f"pool * ({v[1]} - {v[0]} * humans) / humans")

    base, stride, limit = t.scoreboard_init()
    c.equal("scoreboard.init", (base, stride, limit),
            (SCOREBOARD + 8, SCOREBOARD_STRIDE,
             SCOREBOARD + SCOREBOARD_STRIDE * SCOREBOARD_COUNT + 8),
            lambda v: f"0x{v[0]:08X} step {v[1]} to 0x{v[2]:08X}")

    solo = t.callers_of(SOLO_FLAG_SET)
    c.equal("solo.setters", len(solo), EXPECTED_SOLO_SETTERS,
            lambda n: f"{n} call sites")
    c.equal("solo.campaign", pe.u32(SOLO_CAMPAIGN_SITE), SOLO_CAMPAIGN_VALUE,
            lambda v: f"the campaign arm sets the solo flag to {v}")
    c.equal("solo.gate_modes",
            (pe.u8(SKIP_GATE_MODES[0]), pe.u8(SKIP_GATE_MODES[1]),
             pe.u8(SKIP_GATE_LOCAL)), EXPECTED_SKIP_MODES,
            lambda v: f"the skip gate admits modes {list(v)}")
    writers = tuple(va for va in t.refs_to(SOLO_FLAG)
                    if pe.u8(va - 1) == 0xA3
                    or (pe.u8(va - 1) == 0x05 and pe.u8(va - 2) == 0xC7))
    c.equal("solo.writers", writers, EXPECTED_SOLO_WRITERS, _hexlist)

    private = t.private_globals()
    leaked = {v: sites for v, sites in private.items() if sites}
    c.check("gc.private", not leaked,
            "eight turn globals, no reference outside aGameControl.cpp"
            if not leaked else f"leaked: { {hex(k): [hex(s) for s in v] for k, v in leaked.items()} }")
    outside = tuple(va for va in t.refs_to(SHARED_GLOBAL)
                    if not GAME_CONTROL_LO <= va < GAME_CONTROL_HI)
    c.equal("gc.private_control", outside, EXPECTED_SHARED_SITES, _hexlist)
    c.check("gc.control_module",
            all(UNIT_MAP_LO <= va < UNIT_MAP_HI for va in outside),
            f"and all {len(outside)} are inside aUnitMap.cpp")

    # -- the rotation --------------------------------------------------------
    LOG.info("the rotation")

    c.equal("rotate.callers", sorted(t.callers_of(ADVANCE_PLAYER)),
            [0x00454C81, 0x0047D996], _hexlist)
    c.check("rotate.first_start", pe.u8(SEARCH_FIRST_START) == 0x32,
            "aSearchFirstPlayer starts at slot 0")
    c.check("rotate.first_bound",
            pe.u32(SEARCH_FIRST_PLAYER + 1) == PLAYER_COUNT,
            "and stops at the player count")
    c.check("rotate.pseudo",
            pe.u32(ADVANCE_PLAYER + 0x1E) == CURRENT_PLAYER
            and pe.u8(ADVANCE_PLAYER + 0x22) == PSEUDO_PLAYER,
            f"the exhausted rotation stores {PSEUDO_PLAYER}")

    handover = t.callers_of(NEXT_PLAYER_HANDLING)
    c.equal("handover.callers", len(handover), EXPECTED_HANDOVER_CALLERS,
            lambda n: f"{n} call sites")
    c.check("handover.module",
            all(VIEW_PLAYER_LO <= va < VIEW_PLAYER_HI for va in handover),
            "all inside aViewPlayer.cpp")
    c.equal("handover.guard", pe.u8(RESULT_GUARD), RESULT_MAX)
    c.equal("handover.table", t.result_table, EXPECTED_RESULT_TABLE, _hexlist)
    c.check("handover.arms", all(t.in_text(v) for v in t.result_table),
            "4/4 arms inside .text")
    modes = t.view_modes()
    c.equal("handover.view_modes", modes,
            {**VIEW_MODE_ARMS, VIEW_MODE_ARM_REGISTER: VIEW_MODE_EBX},
            lambda v: str(sorted(v.values())))
    c.equal("handover.view_ai", t.pushed_before(VIEW_MODE_AI_SITE), 2,
            lambda v: f"the AI arm sets view state {v}")

    c.equal("lcl.events", t.lcl_events(), LCL_EVENT_SITES,
            lambda v: ", ".join(
                f"_{chr(ord('A') + s - LCL_SLOT_A)}="
                f"{'reg' if n is None else n}" for s, n in v.values()))
    c.check("lcl.turn_getter",
            CHECK_CURRENT_TURN + 5 + pe.i32(CHECK_CURRENT_TURN + 1) == TURN_GET,
            "CheckCurrentTurn reads the turn counter")

    # -- ViewPlayer ----------------------------------------------------------
    LOG.info("aViewPlayer.cpp -- the block the save carries")

    c.equal("vp.block", t.view_player_block(),
            (VIEW_PLAYER_BLOCK, VIEW_PLAYER_SIZE),
            lambda v: f"0x{v[0]:08X} + {v[1]:#x}")
    offsets = t.view_player_offsets()
    sites = sum(len(v) for v in offsets.values())
    c.equal("vp.offsets", tuple(sorted(offsets)), EXPECTED_VIEW_PLAYER_OFFSETS,
            lambda v: f"{len(v)} distinct offsets: "
                      + " ".join(f"+0x{o:03X}" for o in v))
    c.equal("vp.sites", sites, EXPECTED_VIEW_PLAYER_SITES,
            lambda n: f"{n} reference sites")
    c.check("vp.module",
            all(VIEW_PLAYER_LO <= va < VIEW_PLAYER_HI
                for group in offsets.values() for va in group),
            "every one inside aViewPlayer.cpp")
    lo, hi = VIEW_PLAYER_GAP
    c.check("vp.gap", not any(lo <= off < hi for off in offsets),
            f"{hi - lo} bytes at +0x{lo:03X} are never addressed absolutely")

    # -- weapon modes --------------------------------------------------------
    LOG.info("weapon modes")

    columns = t.toggle_columns()
    c.check("mode.gate_column",
            all(col == WEAPON_TOGGLE for col in columns),
            f"{len(columns)}/{len(columns)} sites read the `weapon toggle` "
            f"column +0x{WEAPON_TOGGLE:02X}")
    gates = t.toggle_gates()
    c.check("mode.gate_id", all(g == TOGGLE_GATE_ID for g in gates),
            f"{len(gates)}/{len(gates)} gate on weapon id >= {TOGGLE_GATE_ID}")
    c.equal("mode.toggle_body", t.toggle_body(),
            (UNIT_WEAPON, WEAPON_TOGGLE, WEAPON_STRIDE, UNIT_WEAPON),
            lambda v: f"unit[+0x{v[3]:02X}] = weapon[+0x{v[1]:02X}], "
                      f"stride {v[2]:#x}")
    c.equal("mode.toggle_callers", len(t.callers_of(TOGGLE_ROUTINE)),
            EXPECTED_TOGGLE_CALLERS, lambda n: f"{n} call sites")

    toggle = {w.id: w.toggle for w in corpus.weapons.values()}
    involution = {i: v for i, v in toggle.items()
                  if v not in toggle or toggle[v] != i}
    c.check("mode.involution", not involution,
            f"{len(toggle)}/{len(toggle)} weapons: toggle(toggle(w)) == w"
            if not involution else f"broken at {sorted(involution)}")
    pairs = {i: v for i, v in sorted(toggle.items()) if v != i and i < v}
    c.equal("mode.pairs", pairs, EXPECTED_TOGGLE_PAIRS)
    c.check("mode.one_alternate",
            all((a < TOGGLE_GATE_ID) != (b < TOGGLE_GATE_ID)
                for a, b in pairs.items()),
            f"{len(pairs)}/{len(pairs)} pairs have exactly one member "
            f">= {TOGGLE_GATE_ID}")
    c.check("mode.shared_icon",
            all(corpus.icon.get(a) == corpus.icon.get(b) == a
                for a, b in pairs.items()),
            f"{len(pairs)}/{len(pairs)} pairs share the base weapon's icon")
    c.check("mode.alternate_key",
            all(corpus.key.get(b) == "*" for b in pairs.values()),
            f"{len(pairs)}/{len(pairs)} alternates carry the key '*'")
    c.equal("mode.corpus", corpus.alternate_carriers, 0,
            lambda n: f"{n} of {corpus.placed} placed units start on an alternate")

    # -- reaction fire -------------------------------------------------------
    LOG.info("reaction fire")

    reaction = t.callers_of(MARK_REACTION)
    c.equal("react.callers", len(reaction), EXPECTED_REACTION_CALLERS,
            lambda n: f"{n} call sites")
    c.check("react.guard",
            REACTION_GUARD_CALL + 5 + pe.i32(REACTION_GUARD_CALL + 1)
            == CAN_ATTACK,
            f"guarded by the can-attack gate 0x{CAN_ATTACK:08X}")
    c.check("react.fields",
            pe.u8(REACTION_STATE_SITE) == ACTION_STATE
            and pe.u8(REACTION_STATE_SITE + 1) == REACTION_PENDING,
            f"unit[+0x{ACTION_STATE:02X}] = {REACTION_PENDING}")
    c.check("react.ticket",
            pe.u32(REACTION_TICKET_SITE) == TICKET_COUNTER,
            f"stamped from the counter bank 0x{TICKET_COUNTER:08X}")
    c.equal("react.defence", t.reaction_defence_values(),
            EXPECTED_REACTION_DEFENCE,
            lambda v: f"defence mode in {list(v)}")

    c.equal("react.drain_mode", pe.u8(DRAIN_MODE_SITE), MODE_CAMPAIGN)
    c.equal("react.drain_first", pe.u32(DRAIN_FIRST_TICKET_SITE),
            DRAIN_FIRST_TICKET)
    c.check("react.drain_ascends",
            all(pe.u8(site) == 0x43 for site in DRAIN_INC_SITES)
            and pe.u8(DRAIN_TERMINATOR) == 0x39,
            "and counts up (`inc ebx`) to the highest -- lowest ticket first")
    c.equal("react.drain_callers", len(t.callers_of(REACTION_DRAIN)),
            EXPECTED_DRAIN_CALLERS, lambda n: f"{n} call sites")
    c.check("react.arc",
            pe.u8(ARC_FACING_SITE) == UNIT_FACING
            and all(pe.u8(site) == 0x3B for site in ARC_COMPARES)
            and ARC_HEADING == FIRING_ARC + 0x22 + pe.i32(FIRING_ARC + 0x1E)
            and ARC_NEIGHBOURS[0] == FIRING_ARC + 0x2D + pe.i32(FIRING_ARC + 0x29)
            and ARC_NEIGHBOURS[1] == FIRING_ARC + 0x38 + pe.i32(FIRING_ARC + 0x34),
            f"a reaction needs the mover within one octant of unit[+0x{UNIT_FACING:02X}]")

    stores = t.drain_writes_action_state()
    c.check("react.persist", not stores,
            "the drain never clears unit[+0x41]"
            if not stores else f"writes at {[hex(s) for s in stores]}")

    defence = Counter(corpus.defence.values())
    c.equal("react.defence_corpus", dict(defence), EXPECTED_DEFENCE)

    # -- the refresh ---------------------------------------------------------
    LOG.info("the start-of-turn refresh")

    refresh = t.callers_of(TURN_REFRESH)
    c.equal("refresh.callers", refresh, [TURN_REFRESH_CALLER], _hexlist)
    c.check("refresh.tickets",
            pe.u32(REFRESH_TICKET_SITE) == TICKET_COUNTER,
            f"zeroes the {TICKET_COUNTER_SLOTS} ticket counters first")
    c.equal("refresh.writes", t.refresh_writes(), REFRESH_WRITES,
            lambda v: ", ".join(f"+0x{off:02X}"
                                + ("" if val is None else f"={val:#04x}")
                                for _s, off, val in v))
    c.check("refresh.rested",
            pe.u8(REFRESH_STOOD_DOWN_SITE) == ACTION_STATE
            and pe.u8(REFRESH_STOOD_DOWN_CMP) == STOOD_DOWN,
            f"unit[+0x57] = (unit[+0x{ACTION_STATE:02X}] == {STOOD_DOWN})")
    c.check("refresh.heat_guard",
            pe.u32(HEAT_GUARD_SITE) - WEAPON_INFO == WEAPON_HEAT
            and pe.u8(HEAT_GUARD_VALUE_SITE) == HEAT_DISABLED,
            f"heat {HEAT_DISABLED} disables cooling")
    c.equal("refresh.heat_decay", t.heat_decay_ids(), EXPECTED_HEAT_DECAY_IDS,
            lambda v: f"weapon ids {list(v)} cool by 2")
    c.equal("refresh.malfunction", t.malfunction_ladder(), EXPECTED_MALFUNCTION)

    c.equal("walk.dirs",
            (pe.u8(WALK_DIR_LO_SITE), pe.u8(WALK_DIR_HI_SITE)),
            EXPECTED_WALK_DIRS,
            lambda v: f"step directions {v[0]}..{v[1]} take the larger cost")
    c.equal("walk.cost",
            (pe.u8(WALK_DIAGONAL_SITE), pe.u8(WALK_ORTHOGONAL_SITE)),
            EXPECTED_WALK_COST,
            lambda v: f"unit[+0x{WALK_COUNTER:02X}] += {v[0]} diagonal, "
                      f"{v[1]} orthogonal")
    c.check("walk.store", pe.u8(WALK_STORE_SITE) == WALK_COUNTER,
            f"stored back into unit[+0x{WALK_COUNTER:02X}]")
    c.equal("walk.stores", tuple(t.walk_counter_stores()),
            EXPECTED_WALK_STORES, _hexlist)

    c.check("standdown",
            pe.u8(STAND_DOWN_STATE_SITE) == ACTION_STATE
            and pe.u8(STAND_DOWN_STATE_SITE + 1) == STOOD_DOWN
            and pe.u8(STAND_DOWN_MP_SITE) == MOVEMENT_POINTS
            and pe.u8(STAND_DOWN_MP_SITE + 1) == 0,
            f"unit[+0x{ACTION_STATE:02X}] = {STOOD_DOWN}, "
            f"unit[+0x{MOVEMENT_POINTS:02X}] = 0")
    c.check("stimulant",
            pe.u8(STIMULANT_READ_SITE) == STIMULANT
            and pe.u8(STIMULANT_SPENT_CMP) == STIMULANT_SPENT
            and pe.u8(STIMULANT_MARK_SITE) == STIMULANT
            and pe.u8(STIMULANT_MARK_SITE + 1) == STIMULANT_SPENT
            and pe.u8(STIMULANT_MP_SITE) == MOVEMENT_POINTS,
            f"unit[+0x{STIMULANT:02X}] pays into "
            f"unit[+0x{MOVEMENT_POINTS:02X}], then reads {STIMULANT_SPENT}")

    stride = 2 * ((1 << pe.u8(FP_CAP_SHIFT_SITE)) - 1)
    c.check("fp.cap",
            stride == UNIT_INFO_STRIDE
            and pe.u32(FP_CAP_TABLE_SITE) == UNIT_INFO_FP_MAX_TABLE
            and pe.u32(FP_CAP_MAGIC_SITE) == FP_CAP_MAGIC
            and pe.u8(FP_CAP_FLOOR_SITE) == FP_FLOOR
            and pe.u8(FP_CAP_FLOOR_VALUE_SITE) == FP_FLOOR,
            f"max({FP_FLOOR}, EP / {FP_DIVISOR}) over a {stride:#x}-byte record")
    c.equal("fp.corpus", (corpus.fp_ok, corpus.placed),
            (corpus.placed, corpus.placed),
            lambda v: f"{v[0]}/{v[1]} placed units within the fitness cap")

    # -- the corpus ----------------------------------------------------------
    LOG.info("the corpus")

    c.equal("corpus.missions", len(corpus.missions), EXPECTED_MISSIONS,
            lambda n: f"{n} .lev")
    c.equal("corpus.scripts", len(corpus.scripts), EXPECTED_SCRIPTS,
            lambda n: f"{n} .lcl")
    c.equal("corpus.check_turn",
            (corpus.check_turn_sites, sorted(corpus.check_turn_files),
             dict(corpus.check_turn_bounds)),
            (EXPECTED_CHECK_TURN_SITES, EXPECTED_CHECK_TURN_FILES,
             EXPECTED_CHECK_TURN_BOUNDS),
            lambda v: f"{v[0]} CheckCurrentTurn sites in {v[1]}, bounds "
                      f"{sorted(v[2])}")
    c.check("corpus.action_state",
            set(corpus.action_state) == {0},
            f"every placed unit ships with unit[+0x41] = 0 "
            f"({corpus.placed} units)")

    total = c.passed + c.failed
    LOG.info("%d/%d checks passed", c.passed, total)
    return 1 if c.failed else 0


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def print_rotation(root: str) -> int:
    pe = PEFile(os.path.join(root, GAME_EXE))
    t = TurnTables(pe)
    names = t.mode_names()
    print("game modes set in the binary:")
    for value, count in sorted(t.mode_literals().items(),
                               key=lambda kv: (kv[0] is None, kv[0])):
        shown = "(register)" if value is None else str(value)
        print(f"  mode {shown:<10} {count} site(s)  {names.get(value, '')}")
    print()
    print("player slots per mode:")
    print(f"  mode {MODE_CAMPAIGN}      {pe.u8(SLOT_COUNT_CAMPAIGN_SITE)} slot")
    print(f"  modes 2..4  {pe.u8(SLOT_COUNT_OTHER_SITE)} slots")
    print()
    print(f"turn counter wraps at {pe.u8(TURN_WRAP_CMP)}")
    print(f"the rotation ends on pseudo-player {PSEUDO_PLAYER}")
    print()
    print("aNextPlayerHandling switch on the hand-over's result:")
    labels = ["mission over", "local turn", "remote turn", "first search"]
    for i, target in enumerate(t.result_table):
        print(f"  {i}  0x{target:08X}   {labels[i]}")
    print(f"  default 0x{RESULT_DEFAULT:08X}")
    return 0


def dump_json(root: str) -> int:
    pe = PEFile(os.path.join(root, GAME_EXE))
    t = TurnTables(pe)
    corpus = Corpus(root)
    toggle = {w.id: w.toggle for w in corpus.weapons.values()}
    payload = {
        "game_control": {"base": GAME_CONTROL, "size": GAME_CONTROL_SIZE},
        "turn_wrap": pe.u8(TURN_WRAP_CMP),
        "player_slots": {"campaign": pe.u8(SLOT_COUNT_CAMPAIGN_SITE),
                         "other": pe.u8(SLOT_COUNT_OTHER_SITE)},
        "mode_literals": {str(k): v for k, v in t.mode_literals().items()},
        "mode_names": t.mode_names(),
        "result_table": [f"0x{v:08X}" for v in t.result_table],
        "view_modes": sorted(t.view_modes()),
        "view_player": {"base": VIEW_PLAYER_BLOCK, "size": VIEW_PLAYER_SIZE,
                        "offsets": sorted(t.view_player_offsets())},
        "weapon_toggle": toggle,
        "weapon_pairs": {str(a): b for a, b in sorted(toggle.items())
                         if a != b and a < b},
        "defence": dict(Counter(corpus.defence.values())),
        "heat_decay_ids": list(t.heat_decay_ids()),
        "malfunction": t.malfunction_ladder(),
        "corpus": {"missions": len(corpus.missions),
                   "scripts": len(corpus.scripts),
                   "placed": corpus.placed,
                   "check_turn_sites": corpus.check_turn_sites},
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", nargs="?", default="gog_incubation",
                    help="the game root (default: gog_incubation)")
    ap.add_argument("--check", metavar="ROOT", help="run every check")
    ap.add_argument("--rotation", action="store_true",
                    help="print the player rotation and the hand-over switch")
    ap.add_argument("--json", action="store_true", help="dump everything as JSON")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO,
                        format="%(message)s", stream=sys.stdout)

    root = args.check or args.root
    try:
        if args.check:
            return run_check(root)
        if args.rotation:
            return print_rotation(root)
        if args.json:
            return dump_json(root)
        return print_rotation(root)
    except (PEError, LevError) as exc:
        LOG.error("%s", exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
