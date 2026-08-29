#!/usr/bin/env python3
"""Verify the interaction rules described in ``docs/26`` against the binary
and the corpus.

Five kinds of thing are checked:

**The ``aExecuteUse`` dispatch.**  ``0x0046DC60`` is a single ``switch`` over
the cell's action-point byte, so the complete list of interaction classes is
not inferred -- it is *read out of the compiler's own tables*: a 60-byte index
table at ``0x0046E1DC`` and an 18-entry jump table at ``0x0046E194``.  Every
case body is then decoded structurally (the ``Events.txt`` label it shows, the
speech event it plays, the byte it writes back into the cell, the unit fields
it touches), so a changed immediate cannot pass.

**The availability gate.**  A command is offered by ``0x00472570`` and executed
by ``0x00473250``; between them they fix what Use costs (one movement point),
what it requires (a species that is not a machine, movement points left) and
which four kinds of target it accepts.  ``aGetUseTarget`` ``0x0047A530`` holds
the action-point band and the two jammed-door exceptions.

**The executors.**  The door toggle ``0x00410A20``, the object push
``0x0046D530``, the mine defuse ``0x0046DB80`` and the teleporter
``0x00470150`` are pinned byte by byte -- the parity rule, the one-tile rise,
the four-cell slide limit, the hole types an object falls into, the exit-key
match and the death the blocked exit deals.

**The movement path.**  Two interactions happen while walking rather than on
the Use button: mines detonate and VictoryPoints change hands.  Both are read
off ``aExecuteMove``.

**Corpus counts.**  Every action-point value the switch handles is counted over
all 155 shipped missions; the teleporter pairing rule is replayed over all
seven maps that carry one; the ``Events.txt`` labels the 13 pickup cases name
are resolved; and the ``:Use`` section of every shipped mission script is swept
for what it compares the action point against.

Every check fails on an empty corpus: a check that examined nothing is not a
check that passed.

Usage::

    python3 tools/interaction_tables.py --check gog_incubation
    python3 tools/interaction_tables.py --classes gog_incubation
    python3 tools/interaction_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import lcl  # noqa: E402
from inclib.brieftext import BriefError, block  # noqa: E402
from inclib.lev import LevError, load_lev  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402
from inclib.lcl import decode, is_encoded  # noqa: E402

LOG = logging.getLogger("interaction_tables")

GAME_EXE = "Incubation.exe"

# --- aExecuteUse -- the dispatch -------------------------------------------
EXECUTE_USE = 0x0046DC60
USE_FILE_SITE = 0x0046DD2E              # push "…aTacTools.cpp"
USE_FILE = "C:\\aProject\\Project\\Sources\\Game\\GameTools\\aTacTools.cpp"
#: `cmp byte [cell+0x0B], 10` -- the random supply box
RANDOM_BOX_SITE = 0x0046DD28
RANDOM_BOX_ID = 10
RANDOM_SPAN_SITE = 0x0046DD39           # push 3
RANDOM_BASE_SITE = 0x0046DD3B           # push 11
RANDOM_ROUTINE = 0x00463870             # aRandom(base, span) -> base..base+span-1
RANDOM_BASE, RANDOM_SPAN = 11, 3
RANDOM_STORE_SITE = 0x0046DD44          # mov [ebp+0x0B], al
#: `add eax, -11` / `cmp eax, 0x3B` -- the switch covers ids 11..70
SWITCH_BIAS_SITE = 0x0046DD4E           # the imm8 of `add eax, 0xF5`
SWITCH_SPAN_SITE = 0x0046DD51           # the imm8 of `cmp eax, 0x3B`
SWITCH_BIAS, SWITCH_SPAN = 0xF5, 0x3B   # -11, 59  -> ids 11 .. 70
INDEX_TABLE = 0x0046E1DC
INDEX_TABLE_LEN = 60
JUMP_TABLE = 0x0046E194
JUMP_TABLE_LEN = 18

EXPECTED_INDEX = [
    0, 1, 2, 3, 4, 5, 6, 7, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17,
    8, 8, 8, 8, 17, 17, 9, 10, 11, 12, 13, 14, 15, 17, 17, 17, 17, 17,
    17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17,
    17, 17, 17, 17, 17, 16,
]
EXPECTED_JUMP = [
    0x0046DD67, 0x0046DD88, 0x0046DDC1, 0x0046DE90, 0x0046DED9, 0x0046DF16,
    0x0046DE06, 0x0046DE4B, 0x0046E112, 0x0046E046, 0x0046E084, 0x0046DF51,
    0x0046DFB7, 0x0046DF86, 0x0046DFE8, 0x0046E015, 0x0046E0BF, 0x0046E126,
]
DEFAULT_ARM = 0x0046E126
#: action-point id -> the arm that handles it.  Everything else is the default.
EXPECTED_CLASSES = {
    11: 0x0046DD67, 12: 0x0046DD88, 13: 0x0046DDC1, 14: 0x0046DE90,
    15: 0x0046DED9, 16: 0x0046DF16, 17: 0x0046DE06, 18: 0x0046DE4B,
    30: 0x0046E112, 31: 0x0046E112, 32: 0x0046E112, 33: 0x0046E112,
    36: 0x0046E046, 37: 0x0046E084, 38: 0x0046DF51, 39: 0x0046DFB7,
    40: 0x0046DF86, 41: 0x0046DFE8, 42: 0x0046E015, 70: 0x0046E0BF,
}
#: the two ids the picker legend calls buttons -- offered, never consumed
BUTTON_IDS = (34, 35)
#: and the pair the engine toggles for the script
LEVER_IDS = (36, 37)

# --- the case bodies -------------------------------------------------------
SUPPLY_SEQUENCE = 0x00410780            # the "Examine..." box + box.wav
UNIT_SPEECH = 0x0047B660                # the unit's voice line
SPEECH_EVENT = 9
GET_GAME_CONTROL = 0x0043B160
SET_GAME_CONTROL = 0x0043B180
EQUIP_POINT_SLOT = 10                   # docs/20 §5.3
MAX_AMMO = 0x004752A0
MAKE_FIRE = 0x0042F840                   # the fire maker, docs/23 §7.1
LEVER_SEQUENCE = 0x00416AD0
ENTRY_SEQUENCE = 0x00416CF0
MINE_SEQUENCE = 0x00416DE0

#: id -> the ``Events.txt`` label its arm shows
EXPECTED_TEXT = {
    11: "E0", 12: "E1", 13: "E2", 14: "E3", 15: "E4", 16: "E5", 17: "E6",
    18: "E7", 38: "E8", 39: "E9", 40: "EA", 41: "EB", 42: "EC",
}
#: the one pickup that plays no voice line
NO_SPEECH_ID = 11
#: id -> equipment-point delta paid into game-control slot 10
EXPECTED_EQUIP_POINTS = {13: 50, 17: 20, 18: 10}
#: id -> (unit offset, value) stores
EXPECTED_UNIT_STORES = {
    38: [(0x33, 1), (0x3A, 4)],         # equipment 18 + four absorber charges
    39: [(0x32, 1)],                    # equipment 17, Hydraulic Crowbar
    40: [(0x34, 1)],                    # equipment 19, Cooler
    42: [(0x2A, 1)],                    # equipment  9, Explosion Pack
}
#: id -> [(guard offset, cap), …] and the offsets actually incremented
EXPECTED_SKILL_GUARDS = {14: [(0x1B, 6), (0x1C, 6)], 15: [(0x1A, 6)],
                         16: [(0x1A, 6)]}
EXPECTED_SKILL_INCS = {14: [0x1B, 0x1C], 15: [0x1A], 16: [0x1D]}
#: the arms that write a new action point back into the cell
EXPECTED_AP_STORES = {
    11: 0, 12: 0, 13: 0, 14: 0, 15: 0, 16: 0, 17: 0, 18: 0,
    36: 37, 37: 36, 38: 0, 39: 0, 40: 0, 41: 0, 42: 0, 70: 71,
}
UNIT_AMMO = 0x3D
ENTRY_FIRE_KIND_SITE = 0x0046E0D5        # push 6 -- the effect countdown
ENTRY_FIRE_KIND = 6
ENTRY_FIRE_DROP_SITE = 0x0046E0CE        # sub edx, 0xA0
ENTRY_FIRE_DROP = 0xA0

# --- the LCL Use event -----------------------------------------------------
SET_ENV_VAR = 0x004402A0
LCL_CALLTYPE_SITE = 0x0046E126           # push 4  (call type Use)
LCL_SLOT_A_SITE = 0x0046E128
LCL_USE_CALLTYPE = 4
LCL_SLOT_B_SITE = 0x0046E137
LCL_SLOT_C_SITE = 0x0046E146             # push 'C'
LCL_D_REREAD = 0x0046E152                # mov dl, [ebp+0x0B]  -- after the switch
LCL_SLOT_D_SITE = 0x0046E156             # push 'D'
LCL_SLOTS = (0x41, 0x42, 0x43, 0x44)

# --- the command pad and the gate ------------------------------------------
COMMAND_FROM_BUTTON = 0x00472120
COMMAND_AVAILABLE = 0x00472570
EXECUTE_COMMAND = 0x00473250
#: (column, row) -> command id, read off ``0x00472120``
EXPECTED_PAD = {(0, 0): 1, (0, 1): 3, (1, 0): 2, (1, 1): 7,
                (2, 0): 5, (2, 1): 8}
#: the ladder that maps a pad position onto a command id
PAD_BODY = (0x00472136, 0x00472154)
USE_COMMAND = 8
UNIT_INFO_BASE = 0x0051C020
UNIT_INFO_STRIDE = 0x7E
UNIT_INFO_SPECIES = 0x79                 # docs/21 §5
UNIT_INFO_SIZE = 0x7B
SPECIES_MACHINE = 3
GATE_SPECIES_SITE = 0x00472697           # cmp byte [ecx*2 + 0x0051C099], 3
GATE_MP_SITE = 0x004726A5                # mov al, [esi+0x15]
UNIT_MP = 0x15
UNIT_HP = 0x16
UNIT_ACTED = 0x39
USE_ARM_CALL = 0x004734EA                # call aExecuteUse
#: the two callers of the command executor -- aUI.cpp and aViewPlayer.cpp
EXPECTED_COMMAND_CALLERS = (0x00471324, 0x0047E4F2)
INTERFACE_MODULES = ((0x00471101, 0x00473A41),      # aUI.cpp, docs/91 §1
                     (0x0047BD0B, 0x0047EB70))      # aViewPlayer.cpp
USE_ARM_HP_SITE = 0x00473537             # mov al, [esi+0x16]
USE_ARM_MP_SITE = 0x00473553             # mov al, [esi+0x15]
USE_ARM_DEC_SITE = 0x0047355A            # dec al
USE_ARM_STORE_SITE = 0x0047355C          # mov [esi+0x15], al
USE_ARM_ACTED_SITE = 0x0047355F          # mov byte [esi+0x39], 3
USE_ARM_ACTED = 3

# --- the four Use targets --------------------------------------------------
GET_USE_TARGET = 0x0047A530
CAN_BLOW_ENTRY = 0x0047B410
IS_MINE_CELL = 0x0047B480
CAN_PUSH = 0x0047B250
STEP_BY_FACING = 0x004308C0              # the neighbour in a direction
USE_TARGET_SITES = (GET_USE_TARGET, CAN_PUSH, CAN_BLOW_ENTRY, IS_MINE_CELL)
USE_BAND_LO_SITE = 0x0047A5C3            # cmp cl, 10
USE_BAND_HI_SITE = 0x0047A5C8            # cmp cl, 49
USE_BAND = (10, 49)
USE_JAMMED_CLOSED_SITE = 0x0047A5CD      # cmp cl, 33
USE_CROWBAR_SITE = 0x0047A5D2            # cmp byte [eax+0x32], 1
USE_JAMMED_OPEN_SITE = 0x0047A5D8        # cmp cl, 32
JAMMED_CLOSED, JAMMED_OPEN = 33, 32
UNIT_EQUIP_BASE = 0x21                   # docs/10 §5.4
EQUIP_CROWBAR = 17
EQUIP_EXPLOSION_PACK = 9
ENTRY_FP_SITE = 0x0047B414               # mov cl, [eax+0x19]
ENTRY_PACK_SITE = 0x0047B41E             # mov cl, [eax+0x2A]
ENTRY_AP_SITE = 0x0047B463               # mov cl, [eax+0x0B]
ENTRY_AP_CMP_SITE = 0x0047B468           # cmp cl, 0x46
ENTRY_POINT_ID = 70
UNIT_FP = 0x19
CELL_EFFECT_STATE = 0x10
MINE_STATE = 2
MINE_CELL_LOAD = 0x0047B4B0              # mov cl, [eax+0x10]
MINE_CELL_CMP = 0x0047B4B5               # cmp cl, 2

# --- pushing ---------------------------------------------------------------
PUSH_OBJECT = 0x0046D530
PUSH_TYPE_LOAD = 0x0047B2D9              # mov al, [eax+0x4C]
PUSH_TYPE_SITES = (0x0047B2DC, 0x0047B2E0, 0x0047B2E4, 0x0047B2E8, 0x0047B2EC)
PUSH_TYPES = (30, 32, 33, 34, 35)
PUSH_DIAGONAL_SITE = 0x0047B371          # cmp reg, 4 -- only 4..7 push sideways
PUSH_WALL_SITE = 0x0047B3AF              # cmp eax, 2 -- destination is a Wall
FIELD_WALL, FIELD_HOLE, FIELD_DEEP_HOLE = 2, 3, 4
FIELD_LADDER, FIELD_TELEPORT_IN, FIELD_TELEPORT_OUT = 8, 9, 10
PUSH_LIMIT_SITE = 0x0046D6A0             # mov dword [esp+0x30], 4
PUSH_LIMIT = 4
PUSH_DEEP_HOLE_SITE = 0x0046D908         # cmp eax, 4
PUSH_HOLE_SITE = 0x0046D916              # cmp eax, 3
PUSH_FALL_STEP_SITE = 0x0046D948         # sub esi, 0x140
PUSH_FALL_STEP = 0x140
PUSH_FALL_COUNT_SITE = 0x0046D94F        # cmp edi, 0x32
PUSH_FALL_COUNT = 0x32

# --- doors -----------------------------------------------------------------
DOOR_SEQUENCE = 0x00410A20
DOOR_AP_LOAD = 0x00410B75                # mov al, [edi+0x0B]
DOOR_PARITY_SITE = 0x00410B78            # test al, 1
DOOR_OPEN_TYPE_SITE = 0x00410B7E         # mov byte [edi+0x0D], 1
DOOR_CLOSE_TYPE_SITE = 0x00410BA0        # mov byte [edi+0x0D], 2
DOOR_RISE_SITE = 0x00410B99              # the imm32 of `add edx, 0xC80`
DOOR_RISE = 0xC80                        # one tile, docs/10 §4
FIELD_FREE_PLACE = 1
EXPECTED_DOOR_CALLERS = (0x0040A6B5, 0x00442122, 0x0046D184)
DOOR_LCL_HANDLER = 0x004420C0            # the OpenDoor command, docs/20 §7.3
DOOR_USE_WRAPPER = 0x0046D170

# --- what the computer does ------------------------------------------------
AI_INTERACT = 0x0040A600
AI_HP_SITE = 0x0040A608                  # mov al, [ebx+0x16]
AI_MP_SITE = 0x0040A614                  # cmp byte [ebx+0x15], 2
AI_MP_MINIMUM = 2
AI_DOOR_SITE = 0x0040A65F                # cmp byte [eax+0x0B], 31
AI_DOOR_ID = 31
AI_DIRS_SITE = 0x0040A666                # cmp esi, 7
AI_DIRS_LAST = 7
AI_DEC_SITE = 0x0040A6C0                 # dec al
AI_ACTED_SITE = 0x0040A6C2               # mov byte [ebx+0x39], 3
AI_MODULE = (0x00409984, 0x0040A800)     # aAISystem.cpp, docs/91

# --- teleporters -----------------------------------------------------------
EXECUTE_TELEPORTER = 0x00470150
TELEPORT_OCCUPIED_SITE = 0x0047018A      # cmp word [ebp+7], 0xFFFF
TELEPORT_KEY_SITE = 0x00470199           # mov bl, [ebp+0x0B]
TELEPORT_EXIT_TYPE_SITE = 0x004701B2     # cmp byte [esi+0x0D], 10
TELEPORT_KEY_CMP_SITE = 0x004701B8       # cmp [esi+0x0B], bl
TELEPORT_STRIDE_SITE = 0x004701BD        # add esi, 0x17
CELL_SIZE = 0x17
TELEPORT_BLOCKED_SITE = 0x004701D9       # cmp [esi+7], bx
TELEPORT_LOSS_CALL = 0x004701E4          # call aAddLoss
TELEPORT_DEATH_SITE = 0x00470232         # mov byte [esi+0x16], 0
ADD_LOSS = 0x0043B8D0
TELEPORT_SEQUENCE = 0x004164F0

# --- the movement path -----------------------------------------------------
EXECUTE_MOVE = 0x0046E220
EXECUTE_WARP = 0x0046EF50
MOVE_STEP_BASE_SITE = 0x0046EA4B         # mov cl, [eax+1] -- the delay column
MOVE_ORTHOGONAL, MOVE_DIAGONAL = 1, 2
MOVE_BASE_DIAGONAL_SITE = 0x0046E63B     # mov dword [esp+0x20], 2
MOVE_BASE_ORTHOGONAL_SITE = 0x0046E645   # mov dword [esp+0x20], 1
MOVE_COST_ADD_SITE = 0x0046EA4E          # add ecx, ebp -- delay + base
MOVE_TELEPORT_SITE = 0x0046EA73          # cmp al, 9 -- Teleporter Entry
VICTORY_LOAD_SITE = 0x0046E99F           # mov al, [esi+0x0B]
VICTORY_LO_SITE = 0x0046E9AE             # cmp al, 0x50
VICTORY_HI_SITE = 0x0046E9BE             # cmp al, 0x59
VICTORY_NEUTRAL_SITE = 0x0046E9C5        # cmp cl, 0xFF -- the pseudo player
VICTORY_A_SPLIT_SITE = 0x0046E9CA        # cmp al, 0x54
VICTORY_A_BASE_SITE = 0x0046E9CE         # add cl, 0x51
VICTORY_B_LO_SITE = 0x0046E9D7           # cmp al, 0x55
VICTORY_B_HI_SITE = 0x0046E9DB           # cmp al, 0x59
VICTORY_B_BASE_SITE = 0x0046E9E2         # add al, 0x56
VICTORY_BAND = (0x50, 0x59)
VICTORY_A_BASE, VICTORY_B_BASE = 0x51, 0x56
PSEUDO_PLAYER = 0xFF
MOVE_SIZE_SITE = 0x0046E9FB              # unitinfo[+0x7B] -- small or large
FIND_ADJACENT_MINE = 0x0047A4B0
MINE_BLAST = 0x004702C0                  # aExecuteBomb
MINE_WEAPON_SITE = 0x00470316            # push 0x24
MINE_WEAPON = 36                         # SetWeaponInfo 36, "ParaBomb"
FIRE_WEAPON_AT = 0x0046AA10

# --- the control-map info table --------------------------------------------
CTRL_MAP_INFO = 0x004FEB80
CTRL_MAP_INFO_STRIDE = 0x17
CTRL_MAP_INFO_ACCESSOR = 0x0042F690
CTRL_MAP_TYPE_ACCESSOR = 0x0042F6D0       # returns record +0x00
CTRL_MAP_DELAY_ACCESSOR = 0x0042F6B0      # returns record +0x01
#: the fourth ``SetCtrlMapInfo`` argument lands here and nothing reads it
CTRL_MAP_INFO_DEAD = (CTRL_MAP_INFO + 2, CTRL_MAP_INFO + 3)

# --- the corpus ------------------------------------------------------------
EXPECTED_MISSIONS = 155
EXPECTED_SCRIPTS = 176
EXPECTED_USE_SECTIONS = 153
#: the only action-point values a shipped ``:Use`` section tests ``_D`` against
EXPECTED_USE_TESTS = {34, 35, 36, 37}
#: ``SetActPt`` calls inside those sections -- the scripts' own cell state
EXPECTED_SETACTPT = 226
#: cells per handled action point, over all 155 shipped missions
EXPECTED_AP_CELLS = {
    10: 1, 11: 2, 12: 160, 13: 169, 14: 7, 15: 8, 16: 4, 17: 93, 18: 40,
    30: 17, 31: 278, 32: 0, 33: 8, 34: 28, 35: 2, 36: 70, 37: 1, 38: 13,
    39: 3, 40: 6, 41: 1, 42: 5, 70: 209, 71: 1,
}
#: the template map the editor ships; it carries one of everything
TEMPLATE_MAP = "_C_XXX.lev"
#: the mission that carries both the crowbar and the jammed doors it opens
CROWBAR_MISSION = "_C_142.lev"
#: VictoryPoint B captured by a player -- written at runtime, never authored
RUNTIME_ONLY_APS = (86, 87, 88, 89)
EVENTS_TXT = os.path.join("DATA", "TXT", "English", "Info", "Events.txt")
#: every ``Events.txt`` label must contain the word the pickup is named after
EXPECTED_EVENT_WORDS = {
    "E0": "nothing", "E1": "Ammunition", "E2": "50 Equipment points",
    "E3": "Light weapon skills", "E4": "Battle Fitness",
    "E5": "Technical skills", "E6": "20 Equipment points",
    "E7": "10 Equipment points", "E8": "Absorber", "E9": "Hydraulic Crowbar",
    "EA": "Cooler", "EB": "Batteries", "EC": "Explosion Pack",
}
#: the teleporter maps, and the entry keys each one carries
EXPECTED_TELEPORT_MAPS = 7
EXPECTED_TELEPORT_ENTRIES = 22
EXPECTED_TELEPORT_EXITS = 20
#: the one authored entry whose partner exit was left at action point 0
UNPAIRED_ENTRY = ("_C_156.lev", 104)

# --- the sweep -------------------------------------------------------------
#: every instruction in ``.text`` that reads or compares ``cell[+0x0B]``
EXPECTED_AP_SITES = 44
EXPECTED_AP_MODULES = {
    "aAISystem.cpp": 3, "aAnimations.cpp": 4, "aBattleMap.cpp": 6,
    "aBattleSystem.cpp": 4, "aCtrlMap.cpp": 7, "aLCL_Com.cpp": 4,
    "aMissionControl.cpp": 1, "aTacTools.cpp": 12, "aUnitMap.cpp": 3,
}


# ---------------------------------------------------------------------------
# Reading the binary
# ---------------------------------------------------------------------------

class InteractionTables:
    """Everything ``docs/26`` claims about ``Incubation.exe``."""

    def __init__(self, pe: PEFile) -> None:
        self.pe = pe
        lo, size, _, _ = pe.section(".text")
        self.text_lo, self.text_hi = lo, lo + size

    # -- primitives ---------------------------------------------------------

    def call_target(self, va: int) -> int | None:
        if self.pe.u8(va) != 0xE8:
            return None
        return va + 5 + self.pe.i32(va + 1)

    def callers_of(self, target: int) -> list[int]:
        pe = self.pe
        return [va for va in range(self.text_lo, self.text_hi - 5)
                if pe.u8(va) == 0xE8 and va + 5 + pe.i32(va + 1) == target]

    def refs_to(self, value: int) -> list[int]:
        pe = self.pe
        return [va for va in range(self.text_lo, self.text_hi - 4)
                if pe.u32(va) == value]

    # -- the switch ---------------------------------------------------------

    def index_table(self) -> list[int]:
        return [self.pe.u8(INDEX_TABLE + i) for i in range(INDEX_TABLE_LEN)]

    def jump_table(self) -> list[int]:
        return [self.pe.u32(JUMP_TABLE + 4 * i) for i in range(JUMP_TABLE_LEN)]

    def classes(self) -> dict[int, int]:
        """action-point id -> the arm that handles it, default arm excluded."""
        index, jump = self.index_table(), self.jump_table()
        first = self.pe.u8(SWITCH_BIAS_SITE)
        base = (0x100 - first) if first > 0x7F else -first
        out: dict[int, int] = {}
        for i, slot in enumerate(index):
            if slot >= len(jump):
                continue
            target = jump[slot]
            if target != DEFAULT_ARM:
                out[base + i] = target
        return out

    def case_bodies(self) -> dict[int, tuple[int, int]]:
        """arm -> (start, end); the arms are laid out in address order."""
        arms = sorted(set(self.classes().values()) | {DEFAULT_ARM})
        return {arms[i]: (arms[i], arms[i + 1]) for i in range(len(arms) - 1)}

    def decode_case(self, start: int, end: int) -> dict:
        """Read one switch arm without executing it."""
        pe = self.pe
        out: dict = {"ap_store": [], "unit_store": [], "skill_inc": [],
                     "skill_guard": [], "calls": []}
        i = start
        while i < end:
            b = pe.u8(i)
            if b == 0xE8:
                target = i + 5 + pe.i32(i + 1)
                out["calls"].append(target)
                if target == UNIT_SPEECH and pe.u8(i - 4) == 0x6A:
                    out["speech"] = pe.u8(i - 3)
                if target == SUPPLY_SEQUENCE:
                    for j in range(i - 32, i):
                        if pe.u8(j) == 0x6A and pe.u8(j + 2) == 0x6A \
                                and pe.u8(j + 3) == ord("E"):
                            out["text"] = "E" + chr(pe.u8(j + 1))
                if target == SET_GAME_CONTROL:
                    for j in range(i - 16, i):
                        if pe.u8(j) == 0x83 and pe.u8(j + 1) == 0xC0:
                            out["equip_points"] = pe.u8(j + 2)
            if b == 0xC6 and pe.u8(i + 1) == 0x45 and pe.u8(i + 2) == 0x0B:
                out["ap_store"].append(pe.u8(i + 3))
            if b == 0xC6 and pe.u8(i + 1) == 0x43:
                out["unit_store"].append((pe.u8(i + 2), pe.u8(i + 3)))
            if b == 0x88 and pe.u8(i + 1) == 0x43:
                out.setdefault("reg_store", []).append(pe.u8(i + 2))
            if b == 0xFE and pe.u8(i + 1) == 0xC0 and pe.u8(i + 2) == 0x88 \
                    and pe.u8(i + 3) == 0x43:
                out["skill_inc"].append(pe.u8(i + 4))
            if b == 0xFE and pe.u8(i + 1) == 0x43:
                out["skill_inc"].append(pe.u8(i + 2))
            if b == 0x8A and pe.u8(i + 1) == 0x43:
                offset = pe.u8(i + 2)
                for j in range(i + 3, min(i + 12, end)):
                    if pe.u8(j) == 0x3C:
                        out["skill_guard"].append((offset, pe.u8(j + 1)))
                        break
            i += 1
        return out

    def cases(self) -> dict[int, dict]:
        """action-point id -> the decoded arm."""
        bodies = self.case_bodies()
        out = {}
        for ap, arm in sorted(self.classes().items()):
            if arm in bodies:
                out[ap] = self.decode_case(*bodies[arm])
        return out

    # -- the command pad ----------------------------------------------------

    def command_pad(self) -> dict[tuple[int, int], int]:
        """(column, row) -> command id, read out of ``0x00472120``.

        The routine is one ``sub``/``dec`` ladder per axis and every leaf is a
        ``jz`` to a three-instruction ``mov eax, imm32; ret``.  Following the
        six ``jz`` sites in address order therefore yields the pad row by row,
        with no assumption about which literal the compiler emitted first.
        """
        pe = self.pe
        out: dict[tuple[int, int], int] = {}
        order = [(0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (2, 1)]
        leaves: list[int] = []
        for va in range(PAD_BODY[0], PAD_BODY[1]):
            if pe.u8(va) != 0x74:
                continue
            disp = pe.u8(va + 1)
            target = va + 2 + (disp - 0x100 if disp > 0x7F else disp)
            if pe.u8(target) == 0xB8 and pe.u8(target + 5) == 0xC3:
                leaves.append(pe.u32(target + 1))
        for key, value in zip(order, leaves):
            out[key] = value
        return out

    def use_target_predicates(self) -> set[int]:
        """the predicates ``0x00472570``'s Use arm consults."""
        pe = self.pe
        out = set()
        for va in range(COMMAND_AVAILABLE, COMMAND_AVAILABLE + 0x220):
            if pe.u8(va) != 0xE8:
                continue
            target = va + 5 + pe.i32(va + 1)
            if target in USE_TARGET_SITES:
                out.add(target)
        return out

    # -- the sweep ----------------------------------------------------------

    def action_point_sites(self) -> list[int]:
        """Every instruction in ``.text`` that touches ``cell[+0x0B]``.

        Two encodings reach the byte: ``mov r8, [reg+0x0B]`` and
        ``cmp byte [reg+0x0B], imm8``.  ``rm == 4`` (a SIB byte) is excluded
        because the displacement would then not be the third byte.
        """
        pe = self.pe
        out = []
        for va in range(self.text_lo, self.text_hi - 8):
            b, modrm = pe.u8(va), pe.u8(va + 1)
            if modrm >> 6 != 1 or modrm & 7 == 4 or pe.u8(va + 2) != 0x0B:
                continue
            if b == 0x8A:
                out.append(va)
            elif b == 0x80 and (modrm >> 3) & 7 == 7:
                out.append(va)
        return out

    def module_map(self) -> tuple[list[int], list[str]]:
        """``__FILE__`` pushes, in address order -- see docs/91 §1."""
        pe = self.pe
        addrs: list[int] = []
        names: list[str] = []
        for va in range(self.text_lo, self.text_hi - 5):
            if pe.u8(va) != 0x68:
                continue
            pointer = pe.u32(va + 1)
            if not 0x004B0000 <= pointer <= 0x004E0000:
                continue
            try:
                text = pe.cstring(pointer, 120)
            except PEError:
                continue
            if text and text.endswith(".cpp"):
                addrs.append(va)
                names.append(text.split("\\")[-1])
        return addrs, names

    def sites_by_module(self) -> dict[str, int]:
        import bisect
        addrs, names = self.module_map()
        out: Counter[str] = Counter()
        for site in self.action_point_sites():
            i = bisect.bisect_right(addrs, site) - 1
            out[names[i] if i >= 0 else "?"] += 1
        return dict(out)

    # -- the info tables ----------------------------------------------------

    def unit_info(self, type_id: int, offset: int) -> int:
        return self.pe.u8(UNIT_INFO_BASE + type_id * UNIT_INFO_STRIDE + offset)


# ---------------------------------------------------------------------------
# Reading the corpus
# ---------------------------------------------------------------------------

class Corpus:
    """The shipped data every corpus check reads."""

    def __init__(self, root: str) -> None:
        self.root = root
        self.missions = sorted(Path(root).rglob("*.lev"))
        self.scripts = sorted(Path(root).rglob("*.lcl"))

        self.action_points: Counter[int] = Counter()
        self.ap_files: dict[int, set[str]] = defaultdict(set)
        self.field_types: Counter[int] = Counter()
        #: file -> {entry key: count}, {exit key: count}
        self.teleporters: dict[str, tuple[Counter, Counter]] = {}
        self.cells = 0
        for path in self.missions:
            self._count(path)

        self.use_sections = 0
        self.use_tests: Counter[int] = Counter()
        self.use_commands: Counter[str] = Counter()
        self.script_files: set[str] = set()
        for path in self.scripts:
            self._count_script(path)

        self.events = self._load_events()

    def _count(self, path: Path) -> None:
        battle = load_lev(path)
        entries: Counter[int] = Counter()
        exits: Counter[int] = Counter()
        for cell in battle.cells:
            self.cells += 1
            self.action_points[cell.action_point] += 1
            if cell.action_point:
                self.ap_files[cell.action_point].add(path.name)
            self.field_types[cell.field_type] += 1
            if cell.field_type == FIELD_TELEPORT_IN:
                entries[cell.action_point] += 1
            elif cell.field_type == FIELD_TELEPORT_OUT:
                exits[cell.action_point] += 1
        if entries or exits:
            self.teleporters[path.name] = (entries, exits)

    def _count_script(self, path: Path) -> None:
        with open(path, "rb") as handle:
            program = lcl.parse_bytes(handle.read(), str(path))
        self.script_files.add(path.name)
        for routine in program.routines:
            if routine.name != "Use":
                continue
            self.use_sections += 1
            for stmt in _walk(routine.body):
                self.use_commands[stmt.name] += 1
                if stmt.name != "EnvVarCmpNum":
                    continue
                args = stmt.args
                if len(args) < 2 or args[0].kind != "var":
                    continue
                if (args[0].slot or "").upper() != "D":
                    continue
                if args[1].kind == "number":
                    self.use_tests[args[1].value] += 1

    def _load_events(self) -> str | None:
        path = os.path.join(self.root, EVENTS_TXT)
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as handle:
            data = handle.read()
        if is_encoded(data):
            data = decode(data)
        return data.decode("latin-1")

    # -- derived ------------------------------------------------------------

    def teleporter_pairs(self) -> tuple[int, int, list[tuple[str, int]]]:
        """(entries, exits, the entries with no matching exit key)."""
        entries = exits = 0
        unpaired: list[tuple[str, int]] = []
        for name, (ent, exi) in sorted(self.teleporters.items()):
            entries += sum(ent.values())
            exits += sum(exi.values())
            for key, count in sorted(ent.items()):
                if key not in exi:
                    unpaired.extend([(name, key)] * count)
        return entries, exits, unpaired


def _walk(nodes):
    for node in nodes:
        if isinstance(node, lcl.Statement):
            yield node
        elif isinstance(node, lcl.Conditional):
            for term in node.terms:
                yield term.call
            yield from _walk(node.body)
            yield from _walk(node.else_body)


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
            LOG.info("  ok    %-28s %s", name, detail)
        else:
            self.failed += 1
            LOG.error("  FAIL  %-28s %s", name, detail)

    def equal(self, name: str, got, want, fmt=str) -> None:
        self.check(name, got == want,
                   f"{fmt(got)}" if got == want
                   else f"got {fmt(got)} want {fmt(want)}")


def _hexlist(values) -> str:
    return "[" + ", ".join(f"0x{v:08X}" for v in values) + "]"


def run_check(root: str) -> int:  # noqa: C901 -- a checklist, not an algorithm
    exe = os.path.join(root, GAME_EXE)
    if not os.path.isfile(exe):
        LOG.error("%s not found under %s", GAME_EXE, root)
        return 2
    pe = PEFile(exe)
    t = InteractionTables(pe)
    corpus = Corpus(root)
    c = Checker()

    if not corpus.missions:
        LOG.error("no .lev files under %s -- nothing to check", root)
        return 2
    if not corpus.scripts:
        LOG.error("no .lcl scripts under %s -- nothing to check", root)
        return 2
    if corpus.events is None:
        LOG.error("no %s under %s -- nothing to check", EVENTS_TXT, root)
        return 2

    # -- the dispatch -------------------------------------------------------
    LOG.info("aExecuteUse 0x%08X -- the dispatch", EXECUTE_USE)

    c.check("use.module",
            pe.u32(USE_FILE_SITE + 1) and
            pe.cstring(pe.u32(USE_FILE_SITE + 1), 96) == USE_FILE,
            "the arm's CHECK site names aTacTools.cpp")
    c.equal("use.switch_bias", pe.u8(SWITCH_BIAS_SITE), SWITCH_BIAS,
            lambda v: f"add eax, {v:#04x} (ids from {0x100 - v})")
    c.equal("use.switch_span", pe.u8(SWITCH_SPAN_SITE), SWITCH_SPAN,
            lambda v: f"cmp eax, {v:#04x} (to id {0x100 - SWITCH_BIAS + v})")
    c.equal("use.index_table", t.index_table(), EXPECTED_INDEX,
            lambda v: f"{len(v)} bytes")
    c.equal("use.jump_table", t.jump_table(), EXPECTED_JUMP, _hexlist)
    c.equal("use.classes", t.classes(), EXPECTED_CLASSES,
            lambda v: f"{len(v)} handled ids")
    c.check("use.buttons_default",
            all(ap not in t.classes() for ap in BUTTON_IDS),
            f"ids {BUTTON_IDS} fall through to 0x{DEFAULT_ARM:08X}")
    c.check("use.gaps_default",
            not (set(range(19, 30)) | set(range(43, 70))) & set(t.classes()),
            "19..29 and 43..69 are script space, not engine classes")

    c.equal("use.random_id", pe.u8(RANDOM_BOX_SITE + 3), RANDOM_BOX_ID)
    c.check("use.random_range",
            (pe.u8(RANDOM_BASE_SITE) == RANDOM_BASE
             and pe.u8(RANDOM_SPAN_SITE) == RANDOM_SPAN
             and t.call_target(RANDOM_BOX_SITE + 20) == RANDOM_ROUTINE),
            f"aRandom({RANDOM_BASE}, {RANDOM_SPAN}) -> "
            f"{RANDOM_BASE}..{RANDOM_BASE + RANDOM_SPAN - 1}")
    c.check("use.random_store", pe.u8(RANDOM_STORE_SITE) == 0x88
            and pe.u8(RANDOM_STORE_SITE + 2) == 0x0B,
            "the roll is written back into the cell before the switch")

    # -- the case bodies ----------------------------------------------------
    LOG.info("aExecuteUse -- the seventeen arms")

    cases = t.cases()
    c.equal("case.count", len(cases), len(EXPECTED_CLASSES))
    c.equal("case.text", {ap: v["text"] for ap, v in cases.items()
                          if "text" in v}, EXPECTED_TEXT,
            lambda v: f"{len(v)} Events.txt labels")
    c.check("case.speech",
            all(cases.get(ap, {}).get("speech") == SPEECH_EVENT
                for ap in EXPECTED_TEXT if ap != NO_SPEECH_ID)
            and "speech" not in cases.get(NO_SPEECH_ID, {"speech": None}),
            f"speech event {SPEECH_EVENT} on every pickup but {NO_SPEECH_ID}")
    c.equal("case.ap_store",
            {ap: v["ap_store"][0] for ap, v in cases.items() if v["ap_store"]},
            EXPECTED_AP_STORES, lambda v: f"{len(v)} arms rewrite the cell")
    c.equal("case.equip_points",
            {ap: v["equip_points"] for ap, v in cases.items()
             if "equip_points" in v}, EXPECTED_EQUIP_POINTS)
    pool_sites = [va for va in range(EXECUTE_USE, DEFAULT_ARM)
                  if t.call_target(va) == GET_GAME_CONTROL]
    c.check("case.equip_slot",
            len(pool_sites) == len(EXPECTED_EQUIP_POINTS)
            and all(pe.u8(va - 2) == 0x6A
                    and pe.u8(va - 1) == EQUIP_POINT_SLOT
                    for va in pool_sites),
            f"{len(pool_sites)} arms pay into game-control slot "
            f"{EQUIP_POINT_SLOT}")
    c.equal("case.unit_stores",
            {ap: v["unit_store"] for ap, v in cases.items() if v["unit_store"]},
            EXPECTED_UNIT_STORES,
            lambda v: ", ".join(f"{ap}->" + "+".join(f"[{o:#04x}]={x}"
                                                    for o, x in s)
                                for ap, s in sorted(v.items())))
    picked_up = sorted(off - UNIT_EQUIP_BASE
                       for v in cases.values() for off, val in v["unit_store"]
                       if val == 1 and off >= UNIT_EQUIP_BASE)
    c.equal("case.equip_ids", picked_up, [EQUIP_EXPLOSION_PACK, EQUIP_CROWBAR,
                                          18, 19],
            lambda v: f"the four pickups set equipment {v}")
    c.equal("case.skill_guards",
            {ap: v["skill_guard"] for ap, v in cases.items()
             if v["skill_guard"]}, EXPECTED_SKILL_GUARDS)
    c.equal("case.skill_incs",
            {ap: v["skill_inc"] for ap, v in cases.items() if v["skill_inc"]},
            EXPECTED_SKILL_INCS)
    c.check("case.technical_bug",
            cases.get(16, {}).get("skill_guard", []) == [(0x1A, 6)]
            and cases.get(16, {}).get("skill_inc", []) == [0x1D],
            "id 16 guards on CON +0x1A and increments TS +0x1D")
    c.check("case.ammo",
            MAX_AMMO in cases.get(12, {}).get("calls", [])
            and UNIT_AMMO in cases.get(12, {}).get("reg_store", []),
            f"id 12 refills unit[+0x{UNIT_AMMO:02X}] from 0x{MAX_AMMO:08X}")
    c.check("case.batteries",
            cases.get(41, {}).get("text") == "EB" and not cases.get(41, {}).get("unit_store", [])
            and not cases.get(41, {}).get("skill_inc", []),
            "id 41 shows EB and changes nothing")
    c.check("case.lever",
            LEVER_SEQUENCE in cases.get(36, {}).get("calls", [])
            and LEVER_SEQUENCE in cases.get(37, {}).get("calls", []),
            f"36 and 37 both run 0x{LEVER_SEQUENCE:08X}")
    c.check("case.doors",
            t.call_target(0x0046E11E) == DOOR_USE_WRAPPER,
            f"30..33 share one arm into 0x{DOOR_USE_WRAPPER:08X}")
    c.check("case.entry_point",
            MAKE_FIRE in cases.get(70, {}).get("calls", [])
            and ENTRY_SEQUENCE in cases.get(70, {}).get("calls", [])
            and pe.u8(ENTRY_FIRE_KIND_SITE + 1) == ENTRY_FIRE_KIND
            and pe.u32(ENTRY_FIRE_DROP_SITE + 2) == ENTRY_FIRE_DROP,
            f"id 70 lights a fire and becomes {EXPECTED_AP_STORES[70]}")

    # -- the LCL event ------------------------------------------------------
    LOG.info("aExecuteUse -- the LCL Use event")

    c.equal("lcl.calltype", pe.u8(LCL_CALLTYPE_SITE + 1), LCL_USE_CALLTYPE)
    c.equal("lcl.slots",
            tuple(pe.u8(va + 1) for va in
                  (LCL_SLOT_A_SITE, LCL_SLOT_B_SITE, LCL_SLOT_C_SITE,
                   LCL_SLOT_D_SITE)), LCL_SLOTS,
            lambda v: "".join(chr(x) for x in v))
    c.check("lcl.setter",
            all(t.call_target(va + 2) == SET_ENV_VAR
                for va in (LCL_SLOT_A_SITE, LCL_SLOT_B_SITE)),
            f"through 0x{SET_ENV_VAR:08X}")
    c.check("lcl.d_is_post_mutation",
            (pe.u8(LCL_D_REREAD) == 0x8A and pe.u8(LCL_D_REREAD + 2) == 0x0B
             and LCL_D_REREAD > max(EXPECTED_CLASSES.values())),
            "_D is re-read from the cell after the switch has rewritten it")

    # -- the command pad and the gate ---------------------------------------
    LOG.info("aUI.cpp -- what is offered and what it costs")

    c.equal("gate.pad", t.command_pad(), EXPECTED_PAD,
            lambda v: " ".join(f"({a},{b})={x}" for (a, b), x in sorted(v.items())))
    c.check("gate.use_arm", t.call_target(USE_ARM_CALL) == EXECUTE_USE,
            f"command {USE_COMMAND} runs 0x{EXECUTE_USE:08X}")
    command_callers = t.callers_of(EXECUTE_COMMAND)
    c.equal("gate.callers", tuple(command_callers), EXPECTED_COMMAND_CALLERS,
            _hexlist)
    c.check("gate.callers_are_interface",
            command_callers and all(
                any(lo <= va < hi for lo, hi in INTERFACE_MODULES)
                for va in command_callers),
            "both are in aUI.cpp / aViewPlayer.cpp -- the interface, not the AI")
    c.check("gate.species",
            (pe.u32(GATE_SPECIES_SITE + 3)
             == UNIT_INFO_BASE + UNIT_INFO_SPECIES
             and pe.u8(GATE_SPECIES_SITE + 7) == SPECIES_MACHINE),
            f"species {SPECIES_MACHINE} (machine) may not use anything")
    c.check("gate.movement_points",
            pe.u8(GATE_MP_SITE) == 0x8A and pe.u8(GATE_MP_SITE + 2) == UNIT_MP,
            "the button is dark at zero movement points")
    c.equal("gate.targets", t.use_target_predicates(), set(USE_TARGET_SITES),
            lambda v: _hexlist(sorted(v)))
    c.check("gate.cost",
            (pe.u8(USE_ARM_MP_SITE + 2) == UNIT_MP
             and pe.u8(USE_ARM_DEC_SITE) == 0xFE
             and pe.u8(USE_ARM_STORE_SITE + 2) == UNIT_MP),
            "a use costs exactly one movement point")
    c.check("gate.survivor",
            pe.u8(USE_ARM_HP_SITE + 2) == UNIT_HP,
            "no charge when the unit did not survive its own action")
    c.check("gate.acted",
            (pe.u8(USE_ARM_ACTED_SITE + 2) == UNIT_ACTED
             and pe.u8(USE_ARM_ACTED_SITE + 3) == USE_ARM_ACTED),
            f"unit[+0x{UNIT_ACTED:02X}] = {USE_ARM_ACTED}")

    LOG.info("aGetUseTarget 0x%08X -- what may be used", GET_USE_TARGET)
    c.equal("target.band",
            (pe.u8(USE_BAND_LO_SITE + 2), pe.u8(USE_BAND_HI_SITE + 2)),
            USE_BAND, lambda v: f"action points {v[0]}..{v[1]}")
    c.check("target.jammed_closed",
            (pe.u8(USE_JAMMED_CLOSED_SITE + 2) == JAMMED_CLOSED
             and pe.u8(USE_CROWBAR_SITE + 2)
             == UNIT_EQUIP_BASE + EQUIP_CROWBAR
             and pe.u8(USE_CROWBAR_SITE + 3) == 1),
            f"id {JAMMED_CLOSED} needs equipment {EQUIP_CROWBAR}")
    c.equal("target.jammed_open", pe.u8(USE_JAMMED_OPEN_SITE + 2), JAMMED_OPEN,
            lambda v: f"id {v} is never offered")
    c.check("target.entry_point",
            (pe.u8(ENTRY_FP_SITE + 2) == UNIT_FP
             and pe.u8(ENTRY_PACK_SITE + 2)
             == UNIT_EQUIP_BASE + EQUIP_EXPLOSION_PACK
             and pe.u8(ENTRY_AP_CMP_SITE + 2) == ENTRY_POINT_ID),
            f"id {ENTRY_POINT_ID} needs fitness and equipment "
            f"{EQUIP_EXPLOSION_PACK}")
    c.check("target.mine",
            (pe.u8(MINE_CELL_LOAD + 2) == CELL_EFFECT_STATE
             and pe.u8(MINE_CELL_CMP + 2) == MINE_STATE),
            f"cell[+0x{CELL_EFFECT_STATE:02X}] == {MINE_STATE}")
    c.check("target.push_types",
            (pe.u8(PUSH_TYPE_LOAD + 2) == 0x4C
             and tuple(pe.u8(va + 1) for va in PUSH_TYPE_SITES) == PUSH_TYPES),
            f"unit types {PUSH_TYPES}")
    c.equal("target.push_diagonal", pe.u8(PUSH_DIAGONAL_SITE + 2), 4,
            lambda v: f"facings 0..{v - 1} push straight only")
    c.equal("target.push_wall", pe.u8(PUSH_WALL_SITE + 2), FIELD_WALL,
            lambda v: f"the destination may not be field type {v}")

    # -- the executors ------------------------------------------------------
    LOG.info("aDoorOpenSequence 0x%08X", DOOR_SEQUENCE)
    c.check("door.parity",
            (pe.u8(DOOR_AP_LOAD) == 0x8A and pe.u8(DOOR_AP_LOAD + 2) == 0x0B
             and pe.u8(DOOR_PARITY_SITE) == 0xA8
             and pe.u8(DOOR_PARITY_SITE + 1) == 1),
            "the low bit of the action point is the closed flag")
    c.equal("door.open_type", pe.u8(DOOR_OPEN_TYPE_SITE + 3), FIELD_FREE_PLACE,
            lambda v: f"opening sets field type {v}")
    c.equal("door.close_type", pe.u8(DOOR_CLOSE_TYPE_SITE + 3), FIELD_WALL,
            lambda v: f"closing sets field type {v}")
    c.equal("door.rise", pe.u32(DOOR_RISE_SITE), DOOR_RISE,
            lambda v: f"{v} world units, one tile")
    c.equal("door.callers", tuple(t.callers_of(DOOR_SEQUENCE)),
            EXPECTED_DOOR_CALLERS, _hexlist)
    c.check("door.jammed_shares_code",
            all(t.classes()[ap] == t.classes()[30] for ap in (31, 32, 33)),
            "30..33 all reach the same toggle")

    LOG.info("aPushObject 0x%08X", PUSH_OBJECT)
    c.equal("push.limit", pe.u32(PUSH_LIMIT_SITE + 4), PUSH_LIMIT,
            lambda v: f"an object slides at most {v} cells")
    c.check("push.holes",
            (pe.u8(PUSH_DEEP_HOLE_SITE + 2) == FIELD_DEEP_HOLE
             and pe.u8(PUSH_HOLE_SITE + 2) == FIELD_HOLE),
            f"field types {FIELD_HOLE} and {FIELD_DEEP_HOLE} swallow it")
    c.check("push.fall",
            (pe.u32(PUSH_FALL_STEP_SITE + 2) == PUSH_FALL_STEP
             and pe.u8(PUSH_FALL_COUNT_SITE + 2) == PUSH_FALL_COUNT),
            f"{PUSH_FALL_COUNT} steps of {PUSH_FALL_STEP} world units down")
    c.check("push.predicate",
            CAN_PUSH in [t.call_target(va)
                         for va in range(PUSH_OBJECT, PUSH_OBJECT + 0x400)
                         if pe.u8(va) == 0xE8],
            f"each step is re-tested through 0x{CAN_PUSH:08X}")
    c.check("push.mine",
            MINE_BLAST in [t.call_target(va)
                           for va in range(PUSH_OBJECT, PUSH_OBJECT + 0x400)
                           if pe.u8(va) == 0xE8],
            "an object pushed onto a mine sets it off")

    LOG.info("aExecuteTeleporter 0x%08X", EXECUTE_TELEPORTER)
    c.check("telep.key",
            pe.u8(TELEPORT_KEY_SITE) == 0x8A
            and pe.u8(TELEPORT_KEY_SITE + 2) == 0x0B,
            "the entry's action point is the pairing key")
    c.equal("telep.exit_type", pe.u8(TELEPORT_EXIT_TYPE_SITE + 3),
            FIELD_TELEPORT_OUT, lambda v: f"field type {v}")
    c.check("telep.key_match",
            pe.u8(TELEPORT_KEY_CMP_SITE) == 0x38
            and pe.u8(TELEPORT_KEY_CMP_SITE + 2) == 0x0B,
            "the exit must carry the same action point")
    c.equal("telep.scan_stride", pe.u8(TELEPORT_STRIDE_SITE + 2), CELL_SIZE,
            lambda v: f"a linear scan at stride {v}, first match wins")
    c.check("telep.blocked_kills",
            (pe.u8(TELEPORT_BLOCKED_SITE) == 0x66
             and t.call_target(TELEPORT_LOSS_CALL) == ADD_LOSS
             and pe.u8(TELEPORT_DEATH_SITE + 2) == UNIT_HP
             and pe.u8(TELEPORT_DEATH_SITE + 3) == 0),
            "a blocked exit kills the traveller and books a loss")
    c.check("telep.sequence",
            TELEPORT_SEQUENCE in [t.call_target(va)
                                  for va in range(EXECUTE_TELEPORTER,
                                                  EXECUTE_TELEPORTER + 0x140)
                                  if pe.u8(va) == 0xE8],
            f"0x{TELEPORT_SEQUENCE:08X}")
    c.equal("telep.trigger", pe.u8(MOVE_TELEPORT_SITE + 4),
            FIELD_TELEPORT_IN,
            lambda v: f"stepping onto field type {v}, not a use")
    c.equal("telep.callers", tuple(t.callers_of(EXECUTE_TELEPORTER)),
            (0x0046EE03,), _hexlist)

    # -- the movement path --------------------------------------------------
    LOG.info("aExecuteMove 0x%08X -- interaction while walking", EXECUTE_MOVE)
    c.equal("move.victory_band",
            (pe.u8(VICTORY_LO_SITE + 1), pe.u8(VICTORY_HI_SITE + 1)),
            VICTORY_BAND, lambda v: f"action points {v[0]}..{v[1]}")
    c.equal("move.victory_a", pe.u8(VICTORY_A_BASE_SITE + 2), VICTORY_A_BASE,
            lambda v: f"A becomes {v} + player")
    c.equal("move.victory_b", pe.u8(VICTORY_B_BASE_SITE + 1), VICTORY_B_BASE,
            lambda v: f"B becomes {v} + player")
    c.equal("move.victory_neutral", pe.u8(VICTORY_NEUTRAL_SITE + 2),
            PSEUDO_PLAYER, lambda v: f"player {v} captures nothing")
    c.check("move.mine_size",
            pe.u32(MOVE_SIZE_SITE) == UNIT_INFO_BASE + UNIT_INFO_SIZE,
            f"unitinfo[+0x{UNIT_INFO_SIZE:02X}] picks the mine radius")
    c.check("move.mine_neighbours",
            FIND_ADJACENT_MINE in [t.call_target(va)
                                   for va in range(EXECUTE_MOVE,
                                                   EXECUTE_MOVE + 0xD00)
                                   if pe.u8(va) == 0xE8],
            "a large unit sets off a mine on any of its eight neighbours")
    c.check("move.mine_weapon",
            (pe.u8(MINE_WEAPON_SITE) == 0x6A
             and pe.u8(MINE_WEAPON_SITE + 1) == MINE_WEAPON
             and t.call_target(MINE_WEAPON_SITE + 2) == FIRE_WEAPON_AT),
            f"a mine resolves as weapon {MINE_WEAPON}")
    c.check("move.step_base",
            pe.u8(MOVE_STEP_BASE_SITE) == 0x8A
            and pe.u8(MOVE_STEP_BASE_SITE + 2) == 1,
            "the step cost adds the field type's delay column")
    c.equal("move.step_base_cost",
            (pe.u32(MOVE_BASE_ORTHOGONAL_SITE + 4),
             pe.u32(MOVE_BASE_DIAGONAL_SITE + 4)),
            (MOVE_ORTHOGONAL, MOVE_DIAGONAL),
            lambda v: f"{v[0]} orthogonal, {v[1]} diagonal, on top of the delay")
    c.check("move.step_sum",
            pe.u8(MOVE_COST_ADD_SITE) == 0x03
            and pe.u8(MOVE_COST_ADD_SITE + 2) == 0x2B,
            "the two are added and subtracted from the allowance in one go")

    # -- the computer -------------------------------------------------------
    LOG.info("aAISystem.cpp -- what the computer does with the world")
    c.equal("ai.door_id", pe.u8(AI_DOOR_SITE + 3), AI_DOOR_ID,
            lambda v: f"the only action point the AI acts on is {v}")
    c.equal("ai.minimum_mp", pe.u8(AI_MP_SITE + 3), AI_MP_MINIMUM,
            lambda v: f"it needs {v} movement points to try")
    c.equal("ai.directions", pe.u8(AI_DIRS_SITE + 2), AI_DIRS_LAST,
            lambda v: f"it scans all {v + 1} neighbours, not just the front")
    c.check("ai.cost",
            (pe.u8(AI_DEC_SITE) == 0xFE
             and pe.u8(AI_ACTED_SITE + 2) == UNIT_ACTED
             and pe.u8(AI_ACTED_SITE + 3) == USE_ARM_ACTED),
            "and pays one movement point")
    c.check("ai.hp", pe.u8(AI_HP_SITE + 2) == UNIT_HP, "a live unit only")
    callers = t.callers_of(EXECUTE_USE)
    c.equal("ai.no_use", tuple(callers), (USE_ARM_CALL,), _hexlist)
    c.check("ai.enumerated",
            not any(AI_MODULE[0] <= va < AI_MODULE[1] for va in callers),
            "nothing in aAISystem.cpp reaches aExecuteUse")

    # -- the control-map info table -----------------------------------------
    LOG.info("SetCtrlMapInfo 0x%08X -- the field-type record", CTRL_MAP_INFO)
    c.check("ctrlinfo.accessors",
            (pe.u32(CTRL_MAP_TYPE_ACCESSOR + 0x15) == CTRL_MAP_INFO
             and pe.u32(CTRL_MAP_DELAY_ACCESSOR + 0x15) == CTRL_MAP_INFO + 1),
            "+0x00 is the type echo, +0x01 the movement delay")
    live = {offset: len(t.refs_to(CTRL_MAP_INFO + offset))
            for offset in (0, 1, 2, 3)}
    c.check("ctrlinfo.column4_dead",
            live[0] > 0 and live[1] > 0 and live[2] == 0 and live[3] == 0,
            f"+0x00 {live[0]} refs, +0x01 {live[1]} refs, "
            f"+0x02 {live[2]}, +0x03 {live[3]} -- the fourth argument is dead")

    # -- the sweep ----------------------------------------------------------
    LOG.info("the sweep -- every consumer of cell[+0x0B]")
    sites = t.action_point_sites()
    c.equal("sweep.sites", len(sites), EXPECTED_AP_SITES)
    c.equal("sweep.modules", t.sites_by_module(), EXPECTED_AP_MODULES,
            lambda v: ", ".join(f"{k} {n}" for k, n in sorted(v.items())))
    c.check("sweep.covers_dispatch",
            RANDOM_BOX_SITE in sites and LCL_D_REREAD in sites
            and AI_DOOR_SITE in sites and TELEPORT_KEY_SITE in sites,
            "the sweep finds the sites this document pins")

    # -- the corpus ---------------------------------------------------------
    LOG.info("the corpus -- %d missions, %d scripts",
             len(corpus.missions), len(corpus.scripts))
    c.equal("corpus.missions", len(corpus.missions), EXPECTED_MISSIONS)
    c.equal("corpus.scripts", len(corpus.scripts), EXPECTED_SCRIPTS)
    c.equal("corpus.action_points",
            {ap: corpus.action_points.get(ap, 0) for ap in EXPECTED_AP_CELLS},
            EXPECTED_AP_CELLS,
            lambda v: f"{sum(v.values())} cells over {len(v)} classes")
    c.check("corpus.jammed_open_absent",
            corpus.action_points.get(JAMMED_OPEN, 0) == 0,
            f"id {JAMMED_OPEN} is a runtime state, never authored")
    c.check("corpus.random_box",
            corpus.ap_files.get(RANDOM_BOX_ID) == {TEMPLATE_MAP},
            f"id {RANDOM_BOX_ID} appears only in {TEMPLATE_MAP}")
    c.check("corpus.crowbar_mission",
            CROWBAR_MISSION in corpus.ap_files.get(39, set())
            and CROWBAR_MISSION in corpus.ap_files.get(JAMMED_CLOSED, set()),
            f"{CROWBAR_MISSION} carries both the crowbar and a jammed door")
    c.check("corpus.victory_runtime",
            all(corpus.action_points.get(ap, 0) == 0
                for ap in RUNTIME_ONLY_APS),
            f"ids {RUNTIME_ONLY_APS[0]}..{RUNTIME_ONLY_APS[-1]} are written "
            "on capture, never authored")

    entries, exits, unpaired = corpus.teleporter_pairs()
    c.equal("corpus.teleport_maps", len(corpus.teleporters),
            EXPECTED_TELEPORT_MAPS)
    c.equal("corpus.teleport_cells", (entries, exits),
            (EXPECTED_TELEPORT_ENTRIES, EXPECTED_TELEPORT_EXITS),
            lambda v: f"{v[0]} entries, {v[1]} exits")
    c.equal("corpus.teleport_pairing", unpaired, [UNPAIRED_ENTRY],
            lambda v: (f"{entries - len(v)}/{entries} entries reach an exit; "
                       + (f"unpaired {v}" if v else "none unpaired")))
    keys = sorted({k for ent, exi in corpus.teleporters.values()
                   for k in list(ent) + list(exi)})
    c.check("corpus.teleport_keys",
            all(k not in t.classes() for k in keys),
            f"the keys in use are {keys} -- none collides with an "
            "interaction class")
    c.check("corpus.no_ladders",
            corpus.field_types.get(FIELD_LADDER, 0) == 0,
            f"field type {FIELD_LADDER} is unused in the shipped campaign")

    # -- the scripts --------------------------------------------------------
    LOG.info("the mission scripts -- the Use hook")
    c.equal("lcl.use_sections", corpus.use_sections, EXPECTED_USE_SECTIONS)
    c.equal("lcl.use_tests", set(corpus.use_tests), EXPECTED_USE_TESTS,
            lambda v: f"_D is compared against {sorted(v)} and nothing else")
    c.check("lcl.buttons_are_scripted",
            all(corpus.use_tests.get(ap, 0) > 0 and ap not in t.classes()
                for ap in BUTTON_IDS),
            f"ids {BUTTON_IDS} are read by the scripts and by nothing else")
    c.check("lcl.levers_are_shared",
            all(corpus.use_tests.get(ap, 0) > 0 and ap in t.classes()
                for ap in LEVER_IDS),
            f"ids {LEVER_IDS} are read by both")
    c.equal("lcl.setactpt", corpus.use_commands.get("SetActPt", 0),
            EXPECTED_SETACTPT,
            lambda v: f"{v} SetActPt calls -- the scripts keep their own "
                      "cell state")

    # -- the event texts ----------------------------------------------------
    LOG.info("Events.txt -- what each pickup says")
    resolved = {}
    for key, want in EXPECTED_EVENT_WORDS.items():
        try:
            body = block(corpus.events, key)
        except BriefError:
            body = None
        resolved[key] = body is not None and want in body
    c.check("text.labels", all(resolved.values()),
            f"{sum(resolved.values())}/{len(resolved)} labels resolve and name "
            "their pickup")
    c.equal("text.coverage",
            sorted(v["text"] for v in cases.values() if "text" in v),
            sorted(EXPECTED_EVENT_WORDS),
            lambda v: f"{len(v)} labels, one per pickup arm")

    LOG.info("")
    LOG.info("%d checks, %d failed", c.passed + c.failed, c.failed)
    return 1 if c.failed else 0


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

def print_classes(root: str) -> int:
    pe = PEFile(os.path.join(root, GAME_EXE))
    t = InteractionTables(pe)
    corpus = Corpus(root)
    cases = t.cases()
    print(f"aExecuteUse 0x{EXECUTE_USE:08X} -- {len(cases)} interaction classes")
    print()
    print(f"  {'id':>3}  {'arm':<10} {'text':<5} {'->ap':>4}  {'cells':>6}  effect")
    for ap, arm in sorted(t.classes().items()):
        body = cases.get(ap, {})
        effect = []
        if body.get("equip_points"):
            effect.append(f"+{body['equip_points']} equipment points")
        for off, val in body.get("unit_store", []):
            if off >= UNIT_EQUIP_BASE and val == 1:
                effect.append(f"equipment {off - UNIT_EQUIP_BASE}")
            else:
                effect.append(f"unit[+0x{off:02X}] = {val}")
        for off in body.get("skill_inc", []):
            effect.append(f"skill +0x{off:02X} += 1")
        if not effect:
            effect.append({30: "toggle", 31: "toggle", 32: "toggle",
                           33: "toggle", 36: "lever", 37: "lever",
                           70: "demolish"}.get(ap, "none"))
        store = body.get("ap_store") or [None]
        print(f"  {ap:>3}  0x{arm:08X} {body.get('text', ''):<5} "
              f"{'' if store[0] is None else store[0]:>4}  "
              f"{corpus.action_points.get(ap, 0):>6}  {', '.join(effect)}")
    print()
    print("teleporters (paired by action point):")
    for name, (ent, exi) in sorted(corpus.teleporters.items()):
        keys = sorted(set(ent) | set(exi))
        rows = ", ".join(f"{k}:{ent.get(k, 0)}->{exi.get(k, 0)}" for k in keys)
        print(f"  {name:<14} {rows}")
    return 0


def dump_json(root: str) -> int:
    pe = PEFile(os.path.join(root, GAME_EXE))
    t = InteractionTables(pe)
    corpus = Corpus(root)
    entries, exits, unpaired = corpus.teleporter_pairs()
    payload = {
        "classes": {str(k): f"0x{v:08X}" for k, v in sorted(t.classes().items())},
        "cases": {str(k): {**v, "calls": [f"0x{c:08X}" for c in v["calls"]]}
                  for k, v in sorted(t.cases().items())},
        "command_pad": {f"{a},{b}": v for (a, b), v in
                        sorted(t.command_pad().items())},
        "use_band": [pe.u8(USE_BAND_LO_SITE + 2), pe.u8(USE_BAND_HI_SITE + 2)],
        "sweep": {"sites": len(t.action_point_sites()),
                  "modules": t.sites_by_module()},
        "corpus": {
            "missions": len(corpus.missions),
            "scripts": len(corpus.scripts),
            "action_points": {str(k): v for k, v in
                              sorted(corpus.action_points.items()) if k},
            "use_sections": corpus.use_sections,
            "use_tests": {str(k): v for k, v in sorted(corpus.use_tests.items())},
            "teleporters": {"entries": entries, "exits": exits,
                            "unpaired": unpaired},
        },
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("root", nargs="?", default="gog_incubation",
                    help="the game root (default: gog_incubation)")
    ap.add_argument("--check", metavar="ROOT", help="run every check")
    ap.add_argument("--classes", action="store_true",
                    help="print the interaction classes and their corpus counts")
    ap.add_argument("--json", action="store_true", help="dump everything as JSON")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(message)s",
                        stream=sys.stdout)

    root = args.check or args.root
    try:
        if args.check:
            return run_check(root)
        if args.json:
            return dump_json(root)
        return print_classes(root)
    except (PEError, LevError, BriefError) as exc:
        LOG.error("%s", exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
