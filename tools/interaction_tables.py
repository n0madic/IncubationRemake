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

from inclib import eng3d, footprint, lcl, prototyp  # noqa: E402
from inclib.brieftext import BriefError, block  # noqa: E402
from inclib.convert import (parse_3dw_clones, scene_clones,  # noqa: E402
                            world_paths)
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
#: The land marker: `mov cx, [edi+0x05]` -> `aGetSymbolObjectPtr` -> `ebp`,
#: whose `+0x18` the toggle writes (`landObject->z`, docs/26 §3.4).  The cell's
#: `+0x05` is its land-lattice slot (docs/10 §4), not the special object.
DOOR_MARKER_LOAD = 0x00410B41            # mov cx, word [edi+0x05]
DOOR_MARKER_CALL = 0x00410B46            # call aGetSymbolObjectPtr
DOOR_MARKER_Z_SITES = (0x00410B88, 0x00410BB3)   # mov [ebp+0x18], ...
SYMBOL_OBJECT_PTR = 0x00404C40
#: The leaves: `mov ebx, -100` opening, `mov ebx, 100` closing, and the ten
#: frames adding `bx` to `[esi+0x2A]` and subtracting it from `[esi+0x30]` --
#: the z angles of joints 6 and 12 in docs/28 §7.2's record layout.
DOOR_LEAF_OPEN_SITE = 0x00410B8B         # mov ebx, 0xFFFFFF9C
DOOR_LEAF_CLOSE_SITE = 0x00410BAE        # mov ebx, 0x64
DOOR_LEAF_STEP = 100
DOOR_FRAMES_SITE = 0x00410CFC            # mov ebp, 0x0A
DOOR_FRAMES = 10
DOOR_LEAF_FIRST_SITE = 0x00410D05        # add word [esi+0x2A], bx
DOOR_LEAF_SECOND_SITE = 0x00410D09       # sub word [esi+0x30], bx
DOOR_LEAF_FIRST, DOOR_LEAF_SECOND = 0x2A, 0x30
DOOR_LEAF_SWING = DOOR_LEAF_STEP * DOOR_FRAMES
#: What the `.lev` authors for every door's leaves: open doors at the swing,
#: closed ones at rest.
DOOR_JOINTS_OPEN = ((0, 0, -DOOR_LEAF_SWING), (0, 0, DOOR_LEAF_SWING))
DOOR_JOINTS_CLOSED = ((0, 0, 0), (0, 0, 0))
EXPECTED_DOOR_OBJECTS = 302
EXPECTED_DOOR_PROTOTYPES = ("L100EX00.3DI", "L108EX00.3DI", "L111EX00.3DI")
DOOR_IDS = (30, 31, 32, 33)
FIELD_SIZE = 3200                        # world units per map field, docs/10
FIELD_FREE_PLACE = 1
EXPECTED_DOOR_CALLERS = (0x0040A6B5, 0x00442122, 0x0046D184)
DOOR_LCL_HANDLER = 0x004420C0            # the OpenDoor command, docs/20 §7.3
DOOR_USE_WRAPPER = 0x0046D170

# --- the door's family: docs/42 §8.3 ----------------------------------------
# Nine more routines write the joint words `+0x26..+0x30` or the rotation
# words `+0x20..+0x24` of the object `0x00406F20` finds beside the cell's
# marker, and the remake draws none of them until 2026-09-06.  Each is pinned
# by its loop counter, its step and the `add word [obj+0x2X], reg` site,
# plus the box search it shares with the door.
NEAREST_OBJECT = 0x00406F20              # the 5 000-unit box search
NEAREST_OBJECT_BOX = 0x1388
DELETE_LAND = 0x00406C30                 # aDeleteLand, docs/42 §8.1/§8.2
POOL_ARRIVED = 0x0042B4A0                # the *arrived* flag, docs/42 §4.6
A_RANDOM2 = 0x004638E0                   # the effects' generator, docs/22 §3.2
OBJ_POS_X, OBJ_POS_Y, OBJ_POS_Z = 0x10, 0x14, 0x18      # own position
OBJ_ROT_X, OBJ_ROT_Y, OBJ_ROT_Z = 0x20, 0x22, 0x24      # own rotation
OBJ_J6_X, OBJ_J6_Y, OBJ_J6_Z = 0x26, 0x28, 0x2A         # joint 6
OBJ_J12_X, OBJ_J12_Y, OBJ_J12_Z = 0x2C, 0x2E, 0x30      # joint 12

PICKUP_SEQUENCE = 0x00410780
PICKUP_BOX_SITE = 0x004108F9             # push 0x1388 (x3) before the search
PICKUP_SEARCH_CALL = 0x0041090B
PICKUP_EYE_UP_SITE = 0x004108DA          # add ecx, 0xFA0 -- the user's marker
PICKUP_EYE_UP = 0xFA0
PICKUP_TARGET_UP_SITE = 0x004108C5       # add edx, 0x320 -- the box's marker
PICKUP_TARGET_UP = 0x320
PICKUP_LID_FRAMES_SITE = 0x00410990      # mov ebx, 0x14 -- frames *and* step
PICKUP_LID_FRAMES = 0x14
PICKUP_LID_SITE = 0x0041099A             # add word [esi+0x26], bx
PICKUP_HOLD_SITE = 0x004109A6            # mov esi, 0xF
PICKUP_HOLD_FRAMES = 0xF

LEVER_SEQUENCE = 0x00416AD0
LEVER_SEARCH_CALL = 0x00416BB0
LEVER_CAMERA_UP_SITE = 0x00416BCB        # add eax, 0xC80
LEVER_CAMERA_UP = 0xC80
LEVER_FRAMES_SITE = 0x00416C5E           # mov dword [esp+0x34], 0xA
LEVER_FRAMES = 10
LEVER_STEP_UP_SITE = 0x00416C66          # mov ebp, 0x50 (direction 1)
LEVER_STEP_DOWN_SITE = 0x00416C6B        # mov ebx, -0x50 (direction 0)
LEVER_STEP = 0x50
LEVER_DIR1_SITE = 0x00416C7A             # add word [esi+0x26], bp
LEVER_DIR0_SITE = 0x00416C80             # add word [esi+0x26], bx
LEVER_THROW = LEVER_STEP * LEVER_FRAMES
LEVER_UP, LEVER_DOWN = 36, 37

TUBE_SEQUENCE = 0x00410F10               # OpenTube
TUBE_SEARCH_CALL = 0x00410FA0
TUBE_STEP_SITE = 0x00411094              # mov ebx, 0x33
TUBE_STEP = 0x33
TUBE_HATCH_SITE = 0x00411099             # add word [edi+0x26], bx
TUBE_PUFF_SITE = 0x004110A2              # cmp esi, 0xA
TUBE_PUFF_FRAME = 10
TUBE_FRAMES_SITE = 0x004110E0            # cmp esi, 0x13
TUBE_FRAMES = 0x13
PLANT_TUBE_SEQUENCE = 0x00411150         # OpenPlantTube
PLANT_TUBE_FRAMES_SITE = 0x00411281      # mov edi, 0x13
PLANT_TUBE_STEP_SITES = (0x00411286, 0x0041128B)   # mov ebp, 0x33 / ebx, -0x33
PLANT_TUBE_HATCH_SITES = (0x00411290, 0x00411294)  # +0x26 += bp, +0x2C += bx
FRONT_DOOR_SEQUENCE = 0x004112E0         # OpenFrontDoor
FRONT_DOOR_FRAMES_SITE = 0x0041140F
FRONT_DOOR_STEP_SITES = (0x00411414, 0x00411419)
FRONT_DOOR_LEAF_SITES = (0x0041141E, 0x00411422)   # +0x2A += bp, +0x30 += bx

BRIDGE_SEQUENCE = 0x00410DA0
BRIDGE_READ_SITE = 0x00410EA2            # mov di, word [esi+0x26]
BRIDGE_NEG_SITE = 0x00410EA8             # neg di
BRIDGE_LEA_SITE = 0x00410EB6             # lea edi, [edi+2*edi]
BRIDGE_SHL_SITE = 0x00410EBC             # shl edi, 2
BRIDGE_FRAMES_SITE = 0x00410EBF          # mov ebx, 0x50
BRIDGE_FRAMES = 80
BRIDGE_STEP = 12
BRIDGE_HALF_SITES = (0x00410EC4, 0x00410EC8)       # +0x26 += di, +0x2C -= di
BRIDGE_SWING = BRIDGE_STEP * BRIDGE_FRAMES
BRIDGE_JOINTS_RAISED = ((BRIDGE_SWING, 0, 0), (-BRIDGE_SWING, 0, 0))

BARRIER_SEQUENCE = 0x00413560
BARRIER_ZERO_SITE = 0x0041357B           # xor ebx, ebx
BARRIER_OFF_SITE = 0x00413653            # mov word [edi+0x2A], 0x800
BARRIER_EMITTER_OFF = 0x800
BARRIER_ON_SITE = 0x00413670             # mov word [edi+0x2A], bx
BARRIER_ON_ID, BARRIER_OFF_ID = 90, 91   # every shipped call's two arguments
BARRIER_EMITTERS = ("L002EG00.3DI", "L023EG00.3DI", "L024EG00.3DI",
                    "L025EG00.3DI")

CRUSH_WALL_SEQUENCE = 0x00415C70
CRUSH_TURN_SITE = 0x00415DDE             # mov ebx, 0x66
CRUSH_TURN_STEP = 0x66
CRUSH_DROP_SITE = 0x00415DE3             # mov edi, -0x1E0
CRUSH_DROP_STEP = 0x1E0
CRUSH_ROT_SITE = 0x00415DEB              # add word [esi+0x20], bx
CRUSH_SPIN_CALL = 0x00415DF9             # call 0x0042B4A0
CRUSH_DELETE_CALL = 0x00415E07           # call aDeleteLand

FOOTBRIDGE_SEQUENCE = 0x00414A70
FOOTBRIDGE_TILT_ARGS = (0x00414D03, 0x00414D05)    # push 4 / push -2
FOOTBRIDGE_TILT_CALL = 0x00414D07        # call aRandom2
FOOTBRIDGE_ROT_SITES = (0x00414D5B, 0x00414D5F)    # +0x24 += dx, +0x22 += di
FOOTBRIDGE_DROP_SITE = 0x00414D63        # add ecx, -0xD20
FOOTBRIDGE_DROP_STEP = 0xD20
FOOTBRIDGE_DELETE_CALL = 0x00414F49
FOOTBRIDGE2_ROT_SITES = (0x00415421, 0x00415435)   # +0x22 += ax, +0x24 += cx
FOOTBRIDGE2_DELETE_CALL = 0x00415610
# Both footbridges list the units on their cells before the loop and, after
# it, take each one off the map: `addLoss` (docs/26 §5, the scoreboard's
# losses pair) then aRemoveUnitElement, whose last instruction kills
# (docs/42 §12). `FootBridge2` reads the group byte, writes it back zero as
# it scans, and finds its block in a 500 x 500 x 12 800 box 160 beside and
# 4 800 below the first matched cell's object, then the second's.
ADD_LOSS = 0x0043B8D0
REMOVE_UNIT_ELEMENT = 0x004779C0
FOOTBRIDGE_LOSS_CALL = 0x00414F8C
FOOTBRIDGE_REMOVE_CALL = 0x00414F9C
FOOTBRIDGE2_GROUP_READ_SITE = 0x004151C5           # mov al, [esi+0x0B]
FOOTBRIDGE2_GROUP_CLEAR_SITE = 0x004151EB          # mov byte [esi+0x0B], 0
FOOTBRIDGE2_BOX_DOWN_SITE = 0x00415303             # sub ecx, 0x12C0
FOOTBRIDGE2_BOX_PUSH_SITE = 0x0041530D             # push 0x3200 / 0x1F4 / 0x1F4
FOOTBRIDGE2_BOX_SIDE_SITE = 0x0041531C             # add edx, 0xA0
FOOTBRIDGE2_BOX = (0x3200, 0x1F4, 0x1F4)           # z, y, x half extents
FOOTBRIDGE2_BOX_DOWN = 0x12C0
FOOTBRIDGE2_BOX_SIDE = 0xA0
FOOTBRIDGE2_SEARCH_CALL = 0x0041532A
FOOTBRIDGE2_LOSS_CALL = 0x00415653
FOOTBRIDGE2_REMOVE_CALL = 0x00415663
# The riders while they fall, in both loops and instruction for instruction.
# Each one's `+0x4B` names a standard object; the loop reads its position
# (0x00405100), subtracts 0xC80 from the z, adds 0xA0 back and writes it
# (0x004050A0) -- so a rider drops 0xBE0 a frame, not the map field the
# stored copy suggests -- then reads its own rotation words (0x00405180),
# adds 25 to the third and 12 to the second and writes them back
# (0x004051E0). The sign of both is the rider's **index** parity: `test
# bl, 1` on the loop counter, negative for an odd one.
GET_OBJECT_POSITION = 0x00405100
SET_OBJECT_POSITION = 0x004050A0
GET_OBJECT_ROTATION = 0x00405180
SET_OBJECT_ROTATION = 0x004051E0
# What those four accessors touch, which is what makes the third argument
# the z of one and joint-less `+0x24` of the other.
POSITION_READ_SITES = (0x00405151, 0x0040515A, 0x00405163)   # +0x10/+0x14/+0x18
POSITION_WRITE_SITES = (0x004050D5, 0x004050D8, 0x004050DB)  # the same three
ROTATION_READ_SITES = (0x004051AC, 0x004051B7, 0x004051BE)   # +0x20/+0x22/+0x24
ROTATION_WRITE_SITES = (0x00405218, 0x0040521C, 0x00405220)  # the same three
# A unit is drawn by Charisma, so its object carries a node at `+0x45` and
# both accessors take their **second** arm: the getter asks the node and
# multiplies by 16, the setter divides by 16 and tells it. That pair is the
# inverse of itself, which is what makes the loop's `-0xC80 +0xA0` a net
# 0xBE0 for a rider and not a drop of a map field with a fixed offset.
OBJECT_NODE_FIELD = 0x45
POSITION_NODE_TEST_SITES = (0x00405128, 0x004050DE)   # mov r32, [eax+0x45]
POSITION_NODE_GET_CALL = 0x0040513F
POSITION_NODE_SET_CALL = 0x004050E9
CHARISMA_POSITION_GET = 0x0042C820
CHARISMA_POSITION_SET = 0x0042C890
CHARISMA_SCALE_UP = 0x004B1330                        # 16.0f, coming back
CHARISMA_SCALE_DOWN = 0x004B1334                      # 0.0625f, going in
CHARISMA_SCALE_UP_BITS = 0x41800000
CHARISMA_SCALE_DOWN_BITS = 0x3D800000
RIDER_DROP_STEP = 0xC80
RIDER_DROP_BACK = 0xA0
RIDER_TURN_Z = 25
RIDER_TURN_Y = 12
# Per routine: the position getter and setter calls with the drop and the
# raise between them; the parity test and its two pairs of immediates; the
# rotation getter and setter calls; and the four stack displacements that
# say **which** word each step is about -- the `lea` that gave the getter
# its third out-pointer and the `mov` that adds 25 to what came back name
# the same slot, and so do the second's and the 12.
FOOTBRIDGE_RIDER_FALL = (0x00414DC1, 0x00414DD9, 0x00414DE7, 0x00414DF4)
FOOTBRIDGE_RIDER_TURN = (0x00414DFC, 0x00414E01, 0x00414E06, 0x00414E0D,
                         0x00414E12, 0x00414E2C, 0x00414E44, 0x00414E46,
                         0x00414E5D)
FOOTBRIDGE_RIDER_SLOTS = (0x00414E17, 0x00414E3C, 0x00414E1B, 0x00414E40)
FOOTBRIDGE2_RIDER_FALL = (0x0041548C, 0x004154A4, 0x004154B2, 0x004154BF)
FOOTBRIDGE2_RIDER_TURN = (0x004154C7, 0x004154CC, 0x004154D1, 0x004154D8,
                          0x004154DD, 0x004154F7, 0x0041550F, 0x00415511,
                          0x00415528)
FOOTBRIDGE2_RIDER_SLOTS = (0x004154E2, 0x00415507, 0x004154E6, 0x0041550B)
# aPlayRotateStatueSequence: the nearest object in a 10 000-unit box of the
# cell's marker, its `+0x2A` -- joint 6's z word -- read once, turned by
# 0x50 thirteen times, then written back as the start plus 0x400
# (presentation_tables.py pins the counts; this pins the **word**).
STATUE_SEQUENCE = 0x00413A40
STATUE_BOX_SITE = 0x00413B55                       # push 0x2710 (x3)
STATUE_BOX = 0x2710
STATUE_SEARCH_CALL = 0x00413B67
STATUE_READ_SITE = 0x00413BFB                      # movsx ecx, word [esi+0x2A]
STATUE_TURN_SITE = 0x00413C10                      # add word [esi+0x2A], bp
STATUE_SETTLE_SITE = 0x00413C26                    # mov word [esi+0x2A], dx

# The corpus half: what the shipped records carry for each mechanism's
# state, the way `door.corpus_joints` reads the door's.
LEVER_PROTOTYPE = "L109EX00.3DI"
EXPECTED_LEVER_OBJECTS = 69              # every special object on a lever cell
EXPECTED_BARRIER_SEEDED = 13             # emitters on a cell already at 90/91
BRIDGE_PROTOTYPE = "L026ED00.3DI"
EXPECTED_BRIDGE_OBJECTS = 3              # two the scripts move and one they never do
EXPECTED_BRIDGE_RAISED = 2
# The rotating statue is reached by one shipped call, `Statue2 (110,112)` in
# `_C_178.lcl`, and the three cells in that range carry `L014EH00` -- one
# part, which is what the `+0x2A` write turns. `FixedStatue`'s 21 cells carry
# the partless `L012EH00`, and `aPlayStatueSequence` writes no word at all.
EXPECTED_STATUE2_CALLS = (("_C_178", 110, 112),)
STATUE_PROTOTYPE = "L014EH00.3DI"
FIXED_STATUE_PROTOTYPE = "L012EH00.3DI"
EXPECTED_STATUE_OBJECTS = 3
# `FootBridge2`'s 31 shipped calls, all in `_C_163.lcl`: thirty name a group
# of two cells with exactly one block -- the one the box search finds -- on
# one of them. The thirty-first, `FootBridge2 (139,30,12)` on turn 13, names
# a tag no cell carries, and the map's group 130 at (16,12)/(16,13) is the
# one no call names: a typo in the script, so that bridge never falls.
FOOTBRIDGE2_BLOCK = "L069EI00.3DI"
#: The two commands that name a cell and move **the object standing on it**:
#: the remake turns and frees per cell rather than per object, which is only
#: the engine's own behaviour while a named cell carries one.
CELL_SETPIECES = ("CrushWall", "FootBridge")
#: ...and the action points whose own cell the family reaches: the door and
#: its jammed siblings, the lever either way, the barrier emitter either way.
FAMILY_ACTION_POINTS = frozenset(DOOR_IDS) | {LEVER_UP, LEVER_DOWN,
                                             BARRIER_ON_ID, BARRIER_OFF_ID}
EXPECTED_FAMILY_CELLS = 400
#: ...and the family cells the scene's own ``.3DW`` geometry stands on as
#: well, which is the case ``docs/42`` §8.3 calls "which object on the cell".
#: A clone is not in the special-object table ``0x00406F20`` searches and is
#: placed **before** the special objects, so a remake that answers "the object
#: on this cell" with the first thing it placed answers with the level's own
#: geometry.  Eleven cells over nine missions are shipped that way, so it is
#: not one map's accident.
EXPECTED_CLONE_SHARED_CELLS = (
    ("_C_142", 14, 14, 2),
    ("_C_142", 24, 24, 1),
    ("_C_147", 14, 14, 2),
    ("_C_148", 13, 14, 1),
    ("_C_163", 19, 16, 1),
    ("_C_166", 14, 14, 1),
    ("_M_019", 7, 12, 1),
    ("_M_025", 7, 12, 1),
    ("_M_025", 8, 6, 1),
    ("_M_035", 7, 12, 1),
    ("_O_060", 18, 17, 1),
)
#: The two the remake was measured wrong on, with what each cell carries:
#: mission, cell, the **first** clone placed there and its z, and the special
#: object the search would have found and its z.  On ``_C_142`` the flight
#: aimed at a piece of the level's own hall instead of the panel; on
#: ``_C_163`` it aimed 13 760 world units below the block, which is a
#: footbridge dropping from under the floor.
EXPECTED_CLONE_WITNESSES = (
    ("_C_142", 14, 14, "LEVEL01D.004", 0, "L100EX00.3DI", 0),
    ("_C_163", 19, 16, "LEVEL09C.002", -13760, "L069EI00.3DI", 0),
)
EXPECTED_FOOTBRIDGE2_CALLS = 31
EXPECTED_FOOTBRIDGE2_GROUPS = 30
EXPECTED_FOOTBRIDGE2_UNMATCHED = (("_C_163", 139),)
EXPECTED_FOOTBRIDGE2_UNCALLED = (("_C_163", 130),)

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

# --- the guard in front of every detonation --------------------------------
#
# `docs/26` section 10 item 6 asked why a mine on a walked path did not fire
# when the native probe wrote ``+0x10 = 2`` onto the cell and walked over it.
# The answer is a second test the probe could not satisfy: **every** cell-based
# detonation first calls `aDeleteSpecialObject` on the cell's object id at
# ``+0x0F`` and fires only if it succeeds.  The routine accepts ids 0..80 and
# rejects anything else, so a cell carrying the effect byte and no object is
# inert -- and that is a state the engine itself never produces, because the
# creator writes the id and the effect byte in adjacent instructions.
DELETE_SPECIAL_OBJECT = 0x00406960
CREATE_SPECIAL_OBJECT = 0x004069C0
SPECIAL_OBJECT_MAX_SITE = 0x00406968     # cmp eax, 0x50
SPECIAL_OBJECT_MAX = 0x50
SPECIAL_OBJECT_ARRAY_SITE = 0x0040696D   # mov edx, [0x4FA828]
SPECIAL_OBJECT_ARRAY = 0x004FA828
SPECIAL_OBJECT_DEAD_SITE = 0x0040697F    # mov byte [edx+ecx*2+0x40], 0xFF
SPECIAL_OBJECT_DEAD_FIELD = 0x40
#: the cell field that names the special object the effect belongs to
CELL_OBJECT_ID = 0x0F
#: The four cell-based detonations, as ``(name, the ``mov r8, [cell+0x0F]``,
#: the guard call, the ``+0x10 = 0xFF`` store, the `aExecuteBomb` call)``.
#: Two are in `aExecuteMove` -- one per arm of the size branch below -- one is
#: in `aExecuteWarp` and one on the push path.  The fifth `aExecuteBomb` call
#: site, `0x0040B300`, is the `ParaBomb` fuse and is unit-based, so it has no
#: cell object to delete and is not listed here.
MINE_DETONATIONS: tuple[tuple[str, int, int, int, int], ...] = (
    ("move_single_cell", 0x0046ED6A, 0x0046ED6E, 0x0046EDA7, 0x0046EDAF),
    ("move_neighbours", 0x0046EC80, 0x0046EC84, 0x0046EC9C, 0x0046ECA4),
    ("warp", 0x0046F0C7, 0x0046F0CB, 0x0046F101, 0x0046F109),
    ("push", 0x0046D8A8, 0x0046D8AC, 0x0046D8BC, 0x0046D8DD),
)
#: ``cmp byte [edx*2 + unitinfo+0x7B], 1`` -- which arm of the two the walk
#: takes.  Not equal to 1 detonates the cell the mover stopped on; equal to 1
#: sweeps the eight neighbours through `FIND_ADJACENT_MINE`.
MINE_SIZE_BRANCH_SITE = 0x0046EC25
MINE_LARGE_SIZE = 1
#: `0x0042FB30` -- where a mine is made.  The id and the effect byte are two
#: adjacent stores, and a creation that fails writes ``+0x10 = 0xFF`` instead
#: of 2, so ``+0x10 == 2`` with no object at ``+0x0F`` is unreachable.
MINE_CREATE_CALL = 0x0042FB5F
MINE_CREATE_ID_STORE = 0x0042FB7B        # mov [ebp+0x0F], al
MINE_CREATE_STATE_STORE = 0x0042FB7E     # mov byte [ebp+0x10], 2
MINE_CREATE_FAIL_STORE = 0x0042FB70      # mov byte [ebp+0x10], 0xFF
MINE_NO_EFFECT = 0xFF
#: `0x0040B300` -- the `ParaBomb` fuse, the fifth and only unit-based
#: `aExecuteBomb` call site (`docs/23` section 1).
PARABOMB_FUSE_SITE = 0x0040B300
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
        #: (prototype, action point, joints match the parity rule) -> count,
        #: over every special object standing on a door cell.
        self.door_objects: Counter[tuple[str, int, bool]] = Counter()
        #: (prototype, action point, joints match the lever rule) -> count,
        #: over every special object standing on a lever cell (docs/42 §8.3):
        #: 36 is up and zero, 37 is down and `(-800, 0, 0)`.
        self.lever_objects: Counter[tuple[str, int, bool]] = Counter()
        #: (prototype, action point, joints match the barrier rule) -> count,
        #: over the four emitter prototypes on a cell already seeded 90 or
        #: 91: on is zero, off is `(0, 0, 0x800)`.
        self.barrier_objects: Counter[tuple[str, int, bool]] = Counter()
        #: (prototype, raised, raised or lowered) -> count, over every bridge:
        #: the pair the loop ends on, or zero, and nothing in between.
        self.bridge_objects: Counter[tuple[str, bool, bool]] = Counter()
        #: (mission, action point) -> the special objects on cells carrying
        #: it, and how many cells carry it -- what a range command's box
        #: search lands on (the statue, the second footbridge).
        self.objects_by_ap: dict[tuple[str, int], list[str]] = defaultdict(list)
        #: mission -> the cells a `CrushWall`/`FootBridge` call names, and
        #: mission -> cell -> the special objects standing on it.  The two
        #: together say whether "the object on the cell" is one object.
        self.setpiece_cells: dict[str, set[tuple[int, int]]] = defaultdict(set)
        #: `(mission, x, y)` for every shipped `CrushWall` call -- the nine
        #: `docs/42` §8.2 measured, on their own rather than mixed with
        #: `FootBridge`'s cells.
        self.crush_wall_calls: set[tuple[str, int, int]] = set()
        self.objects_by_cell: dict[tuple[str, int, int], list[str]] = \
            defaultdict(list)
        #: ...and each of those objects' authored z, for the comparison
        #: against the clone standing on the same field.
        self.object_z_by_cell: dict[tuple[str, int, int], list[int]] = \
            defaultdict(list)
        #: (world set, scene) -> cell -> the scene's own `.3DW` clones on it,
        #: as (prototype, z) in placement order.  Filled on demand: it is one
        #: parse per scene, and only the family's cells are ever asked about.
        self._scene_clones: dict[tuple[str, str],
                                 dict[tuple[int, int], list[tuple[str, int]]]] = {}
        self.ap_by_cell: dict[tuple[str, int, int], int] = {}
        self.cells_by_ap: Counter[tuple[str, int]] = Counter()
        #: mission -> (world set, scene), for the prototype container.
        self.scene_of: dict[str, tuple[str, str]] = {}
        #: `Statue2 (lo, hi)` and `FootBridge2 (actpt, ...)` calls, by script.
        self.statue2_calls: list[tuple[str, int, int]] = []
        self.foot_bridge2_groups: dict[str, set[int]] = defaultdict(set)
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
        self.scene_of[path.stem] = (battle.world_set, battle.world_scene)
        entries: Counter[int] = Counter()
        exits: Counter[int] = Counter()
        for cell in battle.cells:
            self.cells += 1
            self.action_points[cell.action_point] += 1
            if cell.action_point:
                self.ap_files[cell.action_point].add(path.name)
                self.cells_by_ap[(path.stem, cell.action_point)] += 1
            self.field_types[cell.field_type] += 1
            if cell.field_type == FIELD_TELEPORT_IN:
                entries[cell.action_point] += 1
            elif cell.field_type == FIELD_TELEPORT_OUT:
                exits[cell.action_point] += 1
        if entries or exits:
            self.teleporters[path.name] = (entries, exits)
        for obj in battle.special:
            cx, cy = obj.x // FIELD_SIZE, obj.y // FIELD_SIZE
            if not (0 <= cx < battle.width and 0 <= cy < battle.height):
                continue
            cell = battle.cell_at(cx, cy)
            name = obj.prototype_name(battle.world_set)
            ap = cell.action_point
            if ap:
                self.objects_by_ap[(path.stem, ap)].append(name)
            self.objects_by_cell[(path.stem, cx, cy)].append(name)
            self.object_z_by_cell[(path.stem, cx, cy)].append(obj.z)
            self.ap_by_cell[(path.stem, cx, cy)] = ap
            if ap in DOOR_IDS:
                want = DOOR_JOINTS_CLOSED if ap & 1 else DOOR_JOINTS_OPEN
                self.door_objects[(name, ap, obj.joints == want)] += 1
            elif ap in (LEVER_UP, LEVER_DOWN):
                thrown = ((-LEVER_THROW, 0, 0), (0, 0, 0))
                want = thrown if ap == LEVER_DOWN else DOOR_JOINTS_CLOSED
                self.lever_objects[(name, ap, obj.joints == want)] += 1
            if name in BARRIER_EMITTERS and ap in (BARRIER_ON_ID, BARRIER_OFF_ID):
                off = ((0, 0, BARRIER_EMITTER_OFF), (0, 0, 0))
                want = off if ap == BARRIER_OFF_ID else DOOR_JOINTS_CLOSED
                self.barrier_objects[(name, ap, obj.joints == want)] += 1
            if name == BRIDGE_PROTOTYPE:
                raised = obj.joints == BRIDGE_JOINTS_RAISED
                lowered = obj.joints == DOOR_JOINTS_CLOSED
                self.bridge_objects[(name, raised, raised or lowered)] += 1

    def _count_script(self, path: Path) -> None:
        with open(path, "rb") as handle:
            program = lcl.parse_bytes(handle.read(), str(path))
        self.script_files.add(path.name)
        for routine in program.routines:
            for stmt in _walk(routine.body):
                numbers = [a.value for a in stmt.args if a.kind == "number"]
                if stmt.name == "Statue2" and len(numbers) >= 2:
                    self.statue2_calls.append((path.stem, numbers[0], numbers[1]))
                elif stmt.name == "FootBridge2" and numbers:
                    self.foot_bridge2_groups[path.stem].add(numbers[0])
                elif stmt.name in CELL_SETPIECES and len(numbers) >= 2:
                    self.setpiece_cells[path.stem].add((numbers[0], numbers[1]))
                    if stmt.name == "CrushWall":
                        self.crush_wall_calls.add(
                            (path.stem, numbers[0], numbers[1]))
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

    def objects_in_range(self, mission: str, low: int, high: int) -> list[str]:
        """The special objects on `mission`'s cells with an action point in
        the inclusive range -- what `0x00413500`'s sweep hands the statue."""
        out: list[str] = []
        for ap in range(low, high + 1):
            out.extend(self.objects_by_ap.get((mission, ap), []))
        return out

    def clones_on(self, mission: str, x: int, y: int) -> list[tuple[str, int]]:
        """The scene's own ``.3DW`` clones standing on one of `mission`'s
        cells, as (prototype, z) in placement order.

        This is the *other* half of "what is on this cell".  The engine's
        ``0x00406F20`` searches the special-object table alone, and a clone is
        never in it -- but a clone is drawn on the field just the same, and is
        placed first, so anything that answers by placement order answers with
        the level's geometry (``docs/42`` §8.3).
        """
        if mission not in self.scene_of:
            return []
        key = self.scene_of[mission]
        if key not in self._scene_clones:
            by_cell: dict[tuple[int, int], list[tuple[str, int]]] = defaultdict(list)
            try:
                paths = world_paths(Path(self.root), key[0], key[1])
                for clone in scene_clones(parse_3dw_clones(paths["dw"])):
                    by_cell[(clone["x"] // FIELD_SIZE,
                             clone["y"] // FIELD_SIZE)].append(
                        (clone["prototype"], clone["z"]))
            except (OSError, KeyError, ValueError):
                by_cell = defaultdict(list)
            self._scene_clones[key] = by_cell
        return list(self._scene_clones[key].get((x, y), []))

    def part_count(self, mission: str, name: str) -> int | None:
        """How many parts `name` has in `mission`'s world set, or `None`."""
        if mission not in self.scene_of:
            return None
        world_set, scene = self.scene_of[mission]
        try:
            paths = world_paths(Path(self.root), world_set, scene)
            container = prototyp.load_container(str(paths["din"]), str(paths["bin"]))
            return len(container.parse(container.find(name)).parts)
        except (OSError, KeyError, ValueError):
            return None

    def object_footprints(self, mission: str) -> list[list[int]] | None:
        """``0x0042F410``'s sweep for every special object of *mission*.

        One cell list per record of ``bm.special``, in placement order --
        :mod:`inclib.footprint`, which is the same call the converter makes.
        ``None`` where the world set's meshes cannot be read.
        """
        if mission not in self.scene_of:
            return None
        world_set, scene = self.scene_of[mission]
        try:
            paths = world_paths(Path(self.root), world_set, scene)
            container = prototyp.load_container(str(paths["din"]),
                                                str(paths["bin"]))
            battle = load_lev(Path(self.root) / "Missions" / f"{mission}.lev")
            return footprint.special_object_cells(
                battle, container, eng3d.load(self.root))
        except (OSError, KeyError, ValueError, LevError):
            return None

    def crush_wall_footprints(self) -> dict[tuple[str, int, int],
                                            tuple[tuple[int, int], ...]]:
        """The cells each shipped ``CrushWall`` crushes, by call.

        The call names one cell and ``0x00406F20`` finds the object standing
        near it, so the run is looked up by the cell the call names.  On all
        nine shipped calls that is the record's own placement cell, so the
        lookup and a search by position cannot be told apart here.
        """
        out: dict[tuple[str, int, int], tuple[tuple[int, int], ...]] = {}
        widths: dict[str, int] = {}
        index_of: dict[str, dict[int, list[int]]] = {}
        for mission, x, y in sorted(self.crush_wall_calls):
            if mission not in index_of:
                lists = self.object_footprints(mission)
                if lists is None:
                    continue
                battle = load_lev(
                    Path(self.root) / "Missions" / f"{mission}.lev")
                widths[mission] = battle.width
                index_of[mission] = footprint.footprint_index(lists)
            width = widths[mission]
            run = index_of[mission].get(y * width + x, [])
            out[(mission, x, y)] = tuple(
                sorted((cell % width, cell // width) for cell in run))
        return out

    def cells_under_two_objects(self, mission: str) -> list[tuple[int, int]]:
        """The cells of *mission* that more than one special object covers."""
        lists = self.object_footprints(mission)
        if lists is None:
            return []
        battle = load_lev(Path(self.root) / "Missions" / f"{mission}.lev")
        seen: Counter[int] = Counter()
        for cells in lists:
            seen.update(cells)
        return sorted((cell % battle.width, cell // battle.width)
                      for cell, count in seen.items() if count > 1)

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


#: ``docs/42`` §8.2 -- the footprint of every shipped ``CrushWall``, measured
#: cell by cell inside the running engine on 2026-09-03 (``docs/97`` §41.7,
#: ``presentation_gold --check``).  The table is repeated here as a literal so
#: that :mod:`inclib.footprint`'s projection is checked against the engine's own
#: answer rather than against itself.
EXPECTED_CRUSH_WALL_FOOTPRINTS = {
    ("_C_129", 16, 18): ((16, 18), (16, 19)),
    ("_C_129", 16, 20): ((16, 20), (16, 21), (16, 22)),
    ("_C_129", 18, 23): ((17, 23), (18, 23)),
    ("_C_142", 22, 11): ((22, 11), (22, 12)),
    ("_O_061", 11, 19): ((10, 19), (11, 19)),
    ("_O_061", 11, 23): ((10, 23), (11, 23)),
    ("_O_061", 13, 19): ((12, 19), (13, 19)),
    ("_O_061", 14, 19): ((14, 19), (15, 19), (16, 19)),
    ("_O_061", 16, 23): ((15, 23), (16, 23)),
}


def _check_crush_wall_footprints(c: "Checker", corpus: "Corpus") -> None:
    """``0x0042F410``'s sweep, replayed on the shipped ``.lev`` files.

    ``docs/97`` §41.7 and ``docs/42`` §8.2 as first written called the
    footprint underivable from the shipped files: the object ``0x00406F20``
    answers with is a **standard object**, and that array was read as something
    the engine builds when it expands the scene.  It is not.  ``docs/99`` §10.1
    already says the search walks the special-object table and nothing else,
    and a ``.lev``'s special objects are exactly what is in it -- so the wall
    piece is a record naming a prototype whose mesh is in ``prototyp.bin``, the
    probe is vertical, and the sweep is arithmetic.

    Three claims, and the first is the one that matters: the projection
    reproduces the engine's nine measured footprints cell for cell.
    """
    measured = corpus.crush_wall_footprints()
    c.equal("corpus.crush_wall_calls", tuple(sorted(corpus.crush_wall_calls)),
            tuple(sorted(EXPECTED_CRUSH_WALL_FOOTPRINTS)),
            lambda v: f"{len(v)} shipped CrushWall call(s)")
    c.equal("corpus.crush_wall_footprints", measured,
            EXPECTED_CRUSH_WALL_FOOTPRINTS,
            lambda v: f"{sum(len(cells) for cells in v.values())} cell(s) over "
                      f"{len(v)} call(s), against what the engine marked")
    # The tie-break in `footprint_index` decides nothing in play: two objects
    # do share a field on the shipped maps -- railings and pillars -- but never
    # on a cell a `CrushWall` names.
    ambiguous = tuple(sorted(
        (mission, x, y)
        for mission in sorted({m for m, _, _ in corpus.crush_wall_calls})
        for x, y in corpus.cells_under_two_objects(mission)
        if (mission, x, y) in corpus.crush_wall_calls))
    c.equal("corpus.crush_wall_cells_carry_one_object", ambiguous, (),
            lambda v: f"{len(v)} CrushWall cell(s) under more than one object")


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
    c.check("door.marker_is_the_land_link",
            (pe.bytes_at(DOOR_MARKER_LOAD, 4) == b"\x66\x8b\x4f\x05"
             and t.call_target(DOOR_MARKER_CALL) == SYMBOL_OBJECT_PTR
             and all(pe.bytes_at(va, 3) in (b"\x89\x5d\x18", b"\x89\x4d\x18")
                     for va in DOOR_MARKER_Z_SITES)),
            "`landObject` is cell[+0x05] through aGetSymbolObjectPtr, and "
            "its +0x18 is what the toggle writes -- the marker, not the panel")
    c.check("door.leaf_step",
            (pe.u8(DOOR_LEAF_OPEN_SITE) == 0xBB
             and pe.i32(DOOR_LEAF_OPEN_SITE + 1) == -DOOR_LEAF_STEP
             and pe.u8(DOOR_LEAF_CLOSE_SITE) == 0xBB
             and pe.i32(DOOR_LEAF_CLOSE_SITE + 1) == DOOR_LEAF_STEP),
            f"ebx = -{DOOR_LEAF_STEP} opening, +{DOOR_LEAF_STEP} closing")
    c.check("door.leaf_frames",
            pe.u8(DOOR_FRAMES_SITE) == 0xBD
            and pe.u32(DOOR_FRAMES_SITE + 1) == DOOR_FRAMES,
            f"{DOOR_FRAMES} frames, so the leaves reach +-{DOOR_LEAF_SWING}")
    c.check("door.leaf_joints",
            (pe.bytes_at(DOOR_LEAF_FIRST_SITE, 4) == b"\x66\x01\x5e\x2a"
             and pe.bytes_at(DOOR_LEAF_SECOND_SITE, 4) == b"\x66\x29\x5e\x30"),
            f"add [obj+0x{DOOR_LEAF_FIRST:02X}], bx / sub [obj+0x"
            f"{DOOR_LEAF_SECOND:02X}], bx -- the z angles of joints 6 and 12")

    # -- the door's family, docs/42 §8.3 ------------------------------------
    LOG.info("the door's family: nine more routines that turn the object")

    def imm32(site: int, opcode: int) -> int | None:
        return pe.i32(site + 1) if pe.u8(site) == opcode else None

    def word_add(site: int, opcode: int, modrm: int, offset: int) -> bool:
        return pe.bytes_at(site, 4) == bytes((0x66, opcode, modrm, offset))

    c.check("family.search_is_the_door_search",
            all(t.call_target(va) == NEAREST_OBJECT for va in
                (PICKUP_SEARCH_CALL, LEVER_SEARCH_CALL, TUBE_SEARCH_CALL))
            and all(pe.u8(PICKUP_BOX_SITE + 5 * i) == 0x68
                    and pe.u32(PICKUP_BOX_SITE + 5 * i + 1) == NEAREST_OBJECT_BOX
                    for i in range(3)),
            f"the box, the lever and the tube find their object through "
            f"0x{NEAREST_OBJECT:08X} in the door's {NEAREST_OBJECT_BOX}-unit box")
    c.check("family.pickup.lid",
            imm32(PICKUP_LID_FRAMES_SITE, 0xBB) == PICKUP_LID_FRAMES
            and word_add(PICKUP_LID_SITE, 0x01, 0x5E, OBJ_J6_X)
            and imm32(PICKUP_HOLD_SITE, 0xBE) == PICKUP_HOLD_FRAMES,
            f"mov ebx, {PICKUP_LID_FRAMES} is the frame count *and* the step: "
            f"add [esi+0x{OBJ_J6_X:02X}], bx opens the lid to "
            f"{PICKUP_LID_FRAMES ** 2}, then {PICKUP_HOLD_FRAMES} frames of nothing")
    c.check("family.pickup.camera",
            (pe.bytes_at(PICKUP_EYE_UP_SITE, 2) == b"\x81\xc1"
             and pe.u32(PICKUP_EYE_UP_SITE + 2) == PICKUP_EYE_UP
             and pe.bytes_at(PICKUP_TARGET_UP_SITE, 2) == b"\x81\xc2"
             and pe.u32(PICKUP_TARGET_UP_SITE + 2) == PICKUP_TARGET_UP),
            f"the flight starts 0x{PICKUP_EYE_UP:X} above the user's marker and "
            f"aims 0x{PICKUP_TARGET_UP:X} above the box's")
    c.check("family.lever.handle",
            (pe.bytes_at(LEVER_FRAMES_SITE, 4) == b"\xc7\x44\x24\x34"
             and pe.u32(LEVER_FRAMES_SITE + 4) == LEVER_FRAMES
             and imm32(LEVER_STEP_UP_SITE, 0xBD) == LEVER_STEP
             and imm32(LEVER_STEP_DOWN_SITE, 0xBB) == -LEVER_STEP
             and word_add(LEVER_DIR1_SITE, 0x01, 0x6E, OBJ_J6_X)
             and word_add(LEVER_DIR0_SITE, 0x01, 0x5E, OBJ_J6_X)),
            f"{LEVER_FRAMES} frames of +-{LEVER_STEP} on [esi+0x{OBJ_J6_X:02X}] "
            f"-- the handle's x angle -- direction 0 taking the negative step")
    c.check("family.lever.camera",
            pe.u8(LEVER_CAMERA_UP_SITE) == 0x05
            and pe.u32(LEVER_CAMERA_UP_SITE + 1) == LEVER_CAMERA_UP,
            f"add eax, 0x{LEVER_CAMERA_UP:X}: both ends of the flight a tile "
            "above the marker")
    c.check("family.tube.hatch",
            (imm32(TUBE_STEP_SITE, 0xBB) == TUBE_STEP
             and word_add(TUBE_HATCH_SITE, 0x01, 0x5F, OBJ_J6_X)
             and pe.bytes_at(TUBE_FRAMES_SITE, 3) == bytes((0x83, 0xFE, TUBE_FRAMES))
             and pe.bytes_at(TUBE_PUFF_SITE, 3) == bytes((0x83, 0xFE, TUBE_PUFF_FRAME))),
            f"OpenTube: {TUBE_FRAMES} frames of +{TUBE_STEP} on "
            f"[edi+0x{OBJ_J6_X:02X}], the puffs at frame {TUBE_PUFF_FRAME}")
    c.check("family.plant_tube.hatches",
            (imm32(PLANT_TUBE_FRAMES_SITE, 0xBF) == TUBE_FRAMES
             and imm32(PLANT_TUBE_STEP_SITES[0], 0xBD) == TUBE_STEP
             and imm32(PLANT_TUBE_STEP_SITES[1], 0xBB) == -TUBE_STEP
             and word_add(PLANT_TUBE_HATCH_SITES[0], 0x01, 0x6E, OBJ_J6_X)
             and word_add(PLANT_TUBE_HATCH_SITES[1], 0x01, 0x5E, OBJ_J12_X)),
            f"OpenPlantTube: {TUBE_FRAMES} frames of +{TUBE_STEP} on joint 6's x "
            f"and -{TUBE_STEP} on joint 12's")
    c.check("family.front_door.leaves",
            (imm32(FRONT_DOOR_FRAMES_SITE, 0xBF) == TUBE_FRAMES
             and imm32(FRONT_DOOR_STEP_SITES[0], 0xBD) == TUBE_STEP
             and imm32(FRONT_DOOR_STEP_SITES[1], 0xBB) == -TUBE_STEP
             and word_add(FRONT_DOOR_LEAF_SITES[0], 0x01, 0x6E, OBJ_J6_Z)
             and word_add(FRONT_DOOR_LEAF_SITES[1], 0x01, 0x5E, OBJ_J12_Z)),
            f"OpenFrontDoor: the same {TUBE_FRAMES} frames on the **z** angles "
            "of joints 6 and 12 -- a door's leaves, not a hatch")
    c.check("family.bridge.halves",
            (imm32(BRIDGE_FRAMES_SITE, 0xBB) == BRIDGE_FRAMES
             and pe.bytes_at(BRIDGE_LEA_SITE, 3) == b"\x8d\x3c\x7f"
             and pe.bytes_at(BRIDGE_SHL_SITE, 3) == b"\xc1\xe7\x02"
             and word_add(BRIDGE_HALF_SITES[0], 0x01, 0x7E, OBJ_J6_X)
             and word_add(BRIDGE_HALF_SITES[1], 0x29, 0x7E, OBJ_J12_X)),
            f"{BRIDGE_FRAMES} frames of (3 << 2) = {BRIDGE_STEP} on joint 6's x "
            f"and its negative on joint 12's: +-{BRIDGE_SWING} in all")
    c.check("family.bridge.toggles_on_the_pose",
            pe.bytes_at(BRIDGE_READ_SITE, 4) == bytes((0x66, 0x8B, 0x7E, OBJ_J6_X))
            and pe.bytes_at(BRIDGE_NEG_SITE, 3) == b"\x66\xf7\xdf",
            "the sign comes from `mov di, [esi+0x26]` / `neg di` / `sbb`: a "
            "raised bridge lowers and a lowered one rises")
    c.check("family.barrier.emitter",
            (pe.bytes_at(BARRIER_ZERO_SITE, 2) == b"\x33\xdb"
             and pe.bytes_at(BARRIER_OFF_SITE, 4) == bytes((0x66, 0xC7, 0x47, OBJ_J6_Z))
             and int.from_bytes(pe.bytes_at(BARRIER_OFF_SITE + 4, 2), 'little') == BARRIER_EMITTER_OFF
             and pe.bytes_at(BARRIER_ON_SITE, 4) == bytes((0x66, 0x89, 0x5F, OBJ_J6_Z))),
            f"[edi+0x{OBJ_J6_Z:02X}] = 0x{BARRIER_EMITTER_OFF:X} going off, bx "
            "(zeroed in the prologue) coming on -- half a turn of the emitter")
    c.check("family.crush_wall.falls",
            (imm32(CRUSH_TURN_SITE, 0xBB) == CRUSH_TURN_STEP
             and imm32(CRUSH_DROP_SITE, 0xBF) == -CRUSH_DROP_STEP
             and word_add(CRUSH_ROT_SITE, 0x01, 0x5E, OBJ_ROT_X)
             and t.call_target(CRUSH_SPIN_CALL) == POOL_ARRIVED
             and t.call_target(CRUSH_DELETE_CALL) == DELETE_LAND),
            f"+{CRUSH_TURN_STEP} on the wall's own x word and -{CRUSH_DROP_STEP} "
            f"on its z every frame until 0x{POOL_ARRIVED:08X} clears, then "
            f"aDeleteLand 0x{DELETE_LAND:08X}")
    c.check("family.footbridge.falls",
            (pe.bytes_at(FOOTBRIDGE_TILT_ARGS[0], 2) == b"\x6a\x04"
             and pe.bytes_at(FOOTBRIDGE_TILT_ARGS[1], 2) == b"\x6a\xfe"
             and t.call_target(FOOTBRIDGE_TILT_CALL) == A_RANDOM2
             and word_add(FOOTBRIDGE_ROT_SITES[0], 0x01, 0x56, OBJ_ROT_Z)
             and word_add(FOOTBRIDGE_ROT_SITES[1], 0x01, 0x7E, OBJ_ROT_Y)
             and pe.bytes_at(FOOTBRIDGE_DROP_SITE, 2) == b"\x81\xc1"
             and pe.i32(FOOTBRIDGE_DROP_SITE + 2) == -FOOTBRIDGE_DROP_STEP
             and t.call_target(FOOTBRIDGE_DELETE_CALL) == DELETE_LAND),
            f"a tilt drawn once from aRandom2(-2, 4) turns the block's own y "
            f"and z words while its z drops {FOOTBRIDGE_DROP_STEP} a frame; "
            "then aDeleteLand")
    c.check("family.footbridge2.falls",
            (word_add(FOOTBRIDGE2_ROT_SITES[0], 0x01, 0x46, OBJ_ROT_Y)
             and word_add(FOOTBRIDGE2_ROT_SITES[1], 0x01, 0x4E, OBJ_ROT_Z)
             and t.call_target(FOOTBRIDGE2_DELETE_CALL) == DELETE_LAND),
            "FootBridge2 is the same fall on the block its box search finds")
    c.check("family.footbridge2.finds_the_block_beside_the_cell",
            (pe.bytes_at(FOOTBRIDGE2_GROUP_READ_SITE, 3) == b"\x8a\x46\x0b"
             and pe.bytes_at(FOOTBRIDGE2_GROUP_CLEAR_SITE, 4) == b"\xc6\x46\x0b\x00"
             and pe.bytes_at(FOOTBRIDGE2_BOX_DOWN_SITE, 2) == b"\x81\xe9"
             and pe.u32(FOOTBRIDGE2_BOX_DOWN_SITE + 2) == FOOTBRIDGE2_BOX_DOWN
             and all(pe.u8(FOOTBRIDGE2_BOX_PUSH_SITE + 5 * i) == 0x68
                     and pe.u32(FOOTBRIDGE2_BOX_PUSH_SITE + 5 * i + 1) == extent
                     for i, extent in enumerate(FOOTBRIDGE2_BOX))
             and pe.bytes_at(FOOTBRIDGE2_BOX_SIDE_SITE, 2) == b"\x81\xc2"
             and pe.u32(FOOTBRIDGE2_BOX_SIDE_SITE + 2) == FOOTBRIDGE2_BOX_SIDE
             and t.call_target(FOOTBRIDGE2_SEARCH_CALL) == NEAREST_OBJECT),
            f"the group byte is read and zeroed as the cells are scanned, and "
            f"the block is 0x{NEAREST_OBJECT:08X}'s find in a "
            f"{FOOTBRIDGE2_BOX[2]} x {FOOTBRIDGE2_BOX[1]} x {FOOTBRIDGE2_BOX[0]} "
            f"box {FOOTBRIDGE2_BOX_SIDE} beside and {FOOTBRIDGE2_BOX_DOWN} below "
            "the first cell's object")
    c.check("family.footbridges.remove_the_riders",
            (t.call_target(FOOTBRIDGE_LOSS_CALL) == ADD_LOSS
             and t.call_target(FOOTBRIDGE_REMOVE_CALL) == REMOVE_UNIT_ELEMENT
             and t.call_target(FOOTBRIDGE2_LOSS_CALL) == ADD_LOSS
             and t.call_target(FOOTBRIDGE2_REMOVE_CALL) == REMOVE_UNIT_ELEMENT),
            f"after the loop both routines call addLoss 0x{ADD_LOSS:08X} and "
            f"aRemoveUnitElement 0x{REMOVE_UNIT_ELEMENT:08X} per rider -- "
            "and removal kills")

    def esp_slot(site: int, opcode: int) -> int | None:
        """The `[esp + disp8]` a `lea`/`mov` at `site` names, or None."""
        head = pe.bytes_at(site, 3)
        if len(head) != 3 or head[0] != opcode or head[2] != 0x24:
            return None
        return pe.u8(site + 3)

    def rider_falls(sites: tuple[int, ...]) -> bool:
        get_call, drop, raise_, set_call = sites
        return (t.call_target(get_call) == GET_OBJECT_POSITION
                and pe.u8(drop) == 0x2D and pe.u32(drop + 1) == RIDER_DROP_STEP
                and pe.u8(raise_) == 0x05
                and pe.u32(raise_ + 1) == RIDER_DROP_BACK
                and t.call_target(set_call) == SET_OBJECT_POSITION)

    def rider_turns(sites: tuple[int, ...], slots: tuple[int, ...]) -> bool:
        (parity, neg_z, neg_y, pos_z, pos_y, get_call, add_z, add_y,
         set_call) = sites
        lea_z, mov_z, lea_y, mov_y = slots
        return (pe.bytes_at(parity, 3) == b"\xf6\xc3\x01"
                and all(pe.u8(va) == 0xBD and pe.i32(va + 1) == sign * RIDER_TURN_Z
                        for va, sign in ((pos_z, 1), (neg_z, -1)))
                and all(pe.u8(va) == 0xBB and pe.i32(va + 1) == sign * RIDER_TURN_Y
                        for va, sign in ((pos_y, 1), (neg_y, -1)))
                and t.call_target(get_call) == GET_OBJECT_ROTATION
                and pe.bytes_at(add_z, 2) == b"\x03\xc5"
                and pe.bytes_at(add_y, 2) == b"\x03\xcb"
                and t.call_target(set_call) == SET_OBJECT_ROTATION
                and esp_slot(lea_z, 0x8D) is not None
                and esp_slot(lea_z, 0x8D) == esp_slot(mov_z, 0x8B)
                and esp_slot(lea_y, 0x8D) is not None
                and esp_slot(lea_y, 0x8D) == esp_slot(mov_y, 0x8B))

    c.check("family.footbridges.the_accessors_name_the_words",
            (all(pe.u8(va + 2) == off
                 for va, off in zip(POSITION_READ_SITES,
                                    (OBJ_POS_X, OBJ_POS_Y, OBJ_POS_Z)))
             and all(pe.u8(va + 3) == off
                     for va, off in zip(ROTATION_READ_SITES,
                                        (OBJ_ROT_X, OBJ_ROT_Y, OBJ_ROT_Z)))
             and all(pe.u8(va + 3) == off
                     for va, off in zip(ROTATION_WRITE_SITES,
                                        (OBJ_ROT_X, OBJ_ROT_Y, OBJ_ROT_Z)))
             and all(pe.u8(va + 2) == off
                     for va, off in zip(POSITION_WRITE_SITES,
                                        (OBJ_POS_X, OBJ_POS_Y, OBJ_POS_Z)))),
            f"0x{GET_OBJECT_ROTATION:08X} and 0x{SET_OBJECT_ROTATION:08X} take "
            f"+0x{OBJ_ROT_X:02X}/+0x{OBJ_ROT_Y:02X}/+0x{OBJ_ROT_Z:02X} in "
            f"argument order, and 0x{SET_OBJECT_POSITION:08X} the three "
            "coordinates -- so a rider's third argument is its z and its own "
            "heading word")
    c.check("family.footbridges.the_bodied_arm_is_symmetric",
            (all(pe.bytes_at(va, 2) in (b"\x8b\x48", b"\x8b\x40")
                 and pe.u8(va + 2) == OBJECT_NODE_FIELD
                 for va in POSITION_NODE_TEST_SITES)
             and t.call_target(POSITION_NODE_GET_CALL) == CHARISMA_POSITION_GET
             and t.call_target(POSITION_NODE_SET_CALL) == CHARISMA_POSITION_SET
             and pe.u32(CHARISMA_SCALE_UP) == CHARISMA_SCALE_UP_BITS
             and pe.u32(CHARISMA_SCALE_DOWN) == CHARISMA_SCALE_DOWN_BITS),
            f"a rider has a body, so `+0x{OBJECT_NODE_FIELD:02X}` sends both "
            f"accessors to 0x{CHARISMA_POSITION_GET:08X} / "
            f"0x{CHARISMA_POSITION_SET:08X}, which scale by 16 and by a "
            "sixteenth -- one is the other's inverse, so the loop's read-back "
            "loses nothing and the fall is the difference of its own two steps")
    c.check("family.footbridges.drop_the_riders",
            rider_falls(FOOTBRIDGE_RIDER_FALL)
            and rider_falls(FOOTBRIDGE2_RIDER_FALL),
            f"both loops read each rider's object, subtract "
            f"{RIDER_DROP_STEP} from its z and put it back {RIDER_DROP_BACK} "
            f"higher -- {RIDER_DROP_STEP - RIDER_DROP_BACK} a frame")
    c.check("family.footbridges.turn_the_riders",
            rider_turns(FOOTBRIDGE_RIDER_TURN, FOOTBRIDGE_RIDER_SLOTS)
            and rider_turns(FOOTBRIDGE2_RIDER_TURN, FOOTBRIDGE2_RIDER_SLOTS),
            f"and turn it {RIDER_TURN_Z} about z and {RIDER_TURN_Y} about y a "
            "frame, negative for an odd rider index (`test bl, 1`)")
    c.check("family.statue.turns_a_joint",
            (all(pe.u8(STATUE_BOX_SITE + 5 * i) == 0x68
                 and pe.u32(STATUE_BOX_SITE + 5 * i + 1) == STATUE_BOX
                 for i in range(3))
             and t.call_target(STATUE_SEARCH_CALL) == NEAREST_OBJECT
             and pe.bytes_at(STATUE_READ_SITE, 4) == bytes((0x0F, 0xBF, 0x4E, OBJ_J6_Z))
             and word_add(STATUE_TURN_SITE, 0x01, 0x6E, OBJ_J6_Z)
             and pe.bytes_at(STATUE_SETTLE_SITE, 4) == bytes((0x66, 0x89, 0x56, OBJ_J6_Z))),
            f"aPlayRotateStatueSequence reads, adds to and writes back "
            f"[esi+0x{OBJ_J6_Z:02X}] -- joint 6's z word, not the object's own "
            f"rotation -- on 0x{NEAREST_OBJECT:08X}'s find in a {STATUE_BOX}-unit box")
    c.check("family.one_record_layout",
            pe.bytes_at(DOOR_LEAF_FIRST_SITE, 4) == bytes((0x66, 0x01, 0x5E, OBJ_J6_Z))
            and pe.bytes_at(DOOR_LEAF_SECOND_SITE, 4) == bytes((0x66, 0x29, 0x5E, OBJ_J12_Z)),
            "the door's +0x2A / +0x30 are the joint-6 and joint-12 z words the "
            "front door and the barrier write too -- one layout, docs/28 §7.2")

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

    # -- the guard in front of the detonation, docs/26 section 10 item 6 ----
    text_base, text_size, _raw, _rawsize = pe.section(".text")
    text_lo, text_hi = text_base, text_base + text_size
    c.equal("mine.size_branch",
            (pe.u32(MINE_SIZE_BRANCH_SITE + 3),
             pe.u8(MINE_SIZE_BRANCH_SITE + 7)),
            (UNIT_INFO_BASE + UNIT_INFO_SIZE, MINE_LARGE_SIZE),
            lambda v: f"unitinfo[+0x{UNIT_INFO_SIZE:02X}] == {v[1]} picks the "
                      "eight-neighbour arm, anything else the single cell")
    shapes = []
    for name, load, guard, store, blast in MINE_DETONATIONS:
        shapes.append((
            name,
            pe.u8(load) == 0x8A and pe.u8(load + 2) == CELL_OBJECT_ID,
            t.call_target(guard) == DELETE_SPECIAL_OBJECT,
            (pe.u8(store) == 0xC6 and pe.u8(store + 2) == CELL_EFFECT_STATE
             and pe.u8(store + 3) == MINE_NO_EFFECT),
            t.call_target(blast) == MINE_BLAST,
            load < guard < store < blast))
    c.equal("mine.detonation_guard", shapes,
            [(name, True, True, True, True, True)
             for name, *_rest in MINE_DETONATIONS],
            lambda v: f"{len(v)} detonation(s), each reading the cell's "
                      f"+0x{CELL_OBJECT_ID:02X} object id, calling "
                      "aDeleteSpecialObject on it and only then marking the "
                      "cell and firing")
    c.check("mine.detonations_are_all_of_them",
            sorted(blast for _n, _l, _g, _s, blast in MINE_DETONATIONS)
            == sorted(va for va in range(text_lo, text_hi)
                      if pe.u8(va) == 0xE8 and t.call_target(va) == MINE_BLAST
                      and va != PARABOMB_FUSE_SITE),
            "the four are every aExecuteBomb call site but the ParaBomb fuse, "
            "which is unit-based and has no cell object")
    c.check("mine.delete_object_range",
            pe.u8(SPECIAL_OBJECT_MAX_SITE) == 0x83
            and pe.u8(SPECIAL_OBJECT_MAX_SITE + 2) == SPECIAL_OBJECT_MAX
            and pe.u32(SPECIAL_OBJECT_ARRAY_SITE + 2) == SPECIAL_OBJECT_ARRAY
            and pe.u8(SPECIAL_OBJECT_DEAD_SITE) == 0xC6
            and pe.u8(SPECIAL_OBJECT_DEAD_SITE + 3)
            == SPECIAL_OBJECT_DEAD_FIELD
            and pe.u8(SPECIAL_OBJECT_DEAD_SITE + 4) == MINE_NO_EFFECT,
            f"aDeleteSpecialObject takes ids 0..{SPECIAL_OBJECT_MAX} and marks "
            f"the object dead at +0x{SPECIAL_OBJECT_DEAD_FIELD:02X} of "
            f"0x{SPECIAL_OBJECT_ARRAY:08X}; anything else returns 0")
    c.check("mine.creation_writes_both",
            t.call_target(MINE_CREATE_CALL) == CREATE_SPECIAL_OBJECT
            and pe.u8(MINE_CREATE_ID_STORE) == 0x88
            and pe.u8(MINE_CREATE_ID_STORE + 2) == CELL_OBJECT_ID
            and MINE_CREATE_STATE_STORE == MINE_CREATE_ID_STORE + 3
            and pe.u8(MINE_CREATE_STATE_STORE) == 0xC6
            and pe.u8(MINE_CREATE_STATE_STORE + 2) == CELL_EFFECT_STATE
            and pe.u8(MINE_CREATE_STATE_STORE + 3) == MINE_STATE
            and pe.u8(MINE_CREATE_FAIL_STORE + 3) == MINE_NO_EFFECT,
            f"a mine's object id and its +0x{CELL_EFFECT_STATE:02X} = "
            f"{MINE_STATE} are adjacent stores, and a failed creation writes "
            f"0x{MINE_NO_EFFECT:02X} instead -- so an effect byte with no "
            "object is a state the engine never leaves")
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
    door_total = sum(corpus.door_objects.values())
    door_agree = sum(n for (_, _, ok), n in corpus.door_objects.items() if ok)
    c.equal("corpus.door_objects", door_total, EXPECTED_DOOR_OBJECTS,
            lambda v: f"{v} special objects stand on door cells")
    c.check("corpus.door_joints", door_total > 0 and door_agree == door_total,
            f"{door_agree}/{door_total} carry the leaves the toggle leaves -- "
            f"{DOOR_JOINTS_OPEN} at an even action point, "
            f"{DOOR_JOINTS_CLOSED} at an odd one")
    c.equal("corpus.door_prototypes",
            tuple(sorted({name for name, _, _ in corpus.door_objects})),
            EXPECTED_DOOR_PROTOTYPES,
            lambda v: f"{len(v)} door prototypes, all two-leaf")
    lever_total = sum(corpus.lever_objects.values())
    lever_agree = sum(n for (_, _, ok), n in corpus.lever_objects.items() if ok)
    c.equal("corpus.lever_objects", lever_total, EXPECTED_LEVER_OBJECTS,
            lambda v: f"{v} special objects stand on lever cells")
    c.check("corpus.lever_joints",
            lever_total > 0 and lever_agree == lever_total
            and any(ap == LEVER_DOWN for _, ap, _ in corpus.lever_objects),
            f"{lever_agree}/{lever_total} carry the handle the sequence leaves "
            f"-- zero at {LEVER_UP}, (-{LEVER_THROW}, 0, 0) at {LEVER_DOWN} -- "
            "and at least one ships thrown")
    c.equal("corpus.lever_prototype",
            tuple(sorted({name for name, _, _ in corpus.lever_objects
                          if name.startswith("L1")})),
            (LEVER_PROTOTYPE,),
            lambda v: f"the cross-set lever prototype is {v}")
    barrier_total = sum(corpus.barrier_objects.values())
    barrier_agree = sum(n for (_, _, ok), n in corpus.barrier_objects.items()
                        if ok)
    c.equal("corpus.barrier_seeded", barrier_total, EXPECTED_BARRIER_SEEDED,
            lambda v: f"{v} emitters stand on a cell already at 90 or 91")
    c.check("corpus.barrier_joints",
            barrier_total > 0 and barrier_agree == barrier_total
            and {ap for _, ap, _ in corpus.barrier_objects}
            == {BARRIER_ON_ID, BARRIER_OFF_ID},
            f"{barrier_agree}/{barrier_total} carry the emitter the sequence "
            f"leaves -- zero at {BARRIER_ON_ID}, (0, 0, 0x{BARRIER_EMITTER_OFF:X}) "
            f"at {BARRIER_OFF_ID} -- with both states in the corpus")
    bridge_total = sum(corpus.bridge_objects.values())
    bridge_raised = sum(n for (_, up, _) , n in corpus.bridge_objects.items() if up)
    bridge_agree = sum(n for (_, _, ok), n in corpus.bridge_objects.items() if ok)
    c.equal("corpus.bridge_objects", (bridge_total, bridge_raised),
            (EXPECTED_BRIDGE_OBJECTS, EXPECTED_BRIDGE_RAISED),
            lambda v: f"{v[0]} bridges in the shipped missions, {v[1]} raised")
    c.check("corpus.bridge_joints", bridge_total > 0 and bridge_agree == bridge_total,
            f"{bridge_agree}/{bridge_total} stand at +-{BRIDGE_SWING} = "
            f"{BRIDGE_FRAMES} frames of {BRIDGE_STEP} or at zero -- the two poses "
            "the loop ends on, so a raised one lowers on its first call")
    c.equal("corpus.statue2_calls", tuple(sorted(corpus.statue2_calls)),
            EXPECTED_STATUE2_CALLS,
            lambda v: f"the shipped Statue2 call(s): {v}")
    statue_objects: list[str] = []
    for mission, low, high in corpus.statue2_calls:
        statue_objects.extend(corpus.objects_in_range(mission, low, high))
    c.equal("corpus.statue_objects",
            (len(statue_objects), tuple(sorted(set(statue_objects)))),
            (EXPECTED_STATUE_OBJECTS, (STATUE_PROTOTYPE,)),
            lambda v: f"{v[0]} special object(s) on the range's cells, all {v[1]}")
    statue_mission = corpus.statue2_calls[0][0] if corpus.statue2_calls else ""
    c.equal("corpus.statue_prototype_has_a_part",
            (corpus.part_count(statue_mission, STATUE_PROTOTYPE),
             corpus.part_count(statue_mission, FIXED_STATUE_PROTOTYPE)),
            (1, 0),
            lambda v: f"{STATUE_PROTOTYPE} has {v[0]} part for the +0x2A write to "
                      f"turn; FixedStatue's {FIXED_STATUE_PROTOTYPE} has {v[1]}")
    calls = [(mission, ap) for mission, aps in sorted(corpus.foot_bridge2_groups.items())
             for ap in sorted(aps)]
    matched = [key for key in calls if corpus.cells_by_ap[key] > 0]
    two_cells = sum(1 for key in matched if corpus.cells_by_ap[key] == 2)
    one_block = sum(1 for key in matched
                    if corpus.objects_by_ap.get(key, []) == [FOOTBRIDGE2_BLOCK])
    c.equal("corpus.footbridge2_groups",
            (len(calls), len(matched), two_cells, one_block),
            (EXPECTED_FOOTBRIDGE2_CALLS,) + (EXPECTED_FOOTBRIDGE2_GROUPS,) * 3,
            lambda v: f"{v[0]} calls, {v[1]} name a group, {v[2]} of two cells, "
                      f"{v[3]} with exactly one {FOOTBRIDGE2_BLOCK} on one of them")
    unmatched = tuple(key for key in calls if corpus.cells_by_ap[key] == 0)
    uncalled = tuple(sorted(
        (mission, ap) for (mission, ap), names in corpus.objects_by_ap.items()
        if mission in corpus.foot_bridge2_groups and names == [FOOTBRIDGE2_BLOCK]
        and ap not in corpus.foot_bridge2_groups[mission]))
    # Every cell the family reaches: the ones a `CrushWall`/`FootBridge`
    # call names by coordinate, and the ones its own action point names --
    # a door, a lever, a barrier emitter. The remake turns, poses and frees
    # **per cell** where the engine does it per object, and this is what
    # says the two are the same thing on the shipped maps.
    family_cells = {(mission, x, y)
                    for mission, cells in corpus.setpiece_cells.items()
                    for x, y in cells}
    family_cells |= {key for key, ap in corpus.ap_by_cell.items()
                     if ap in FAMILY_ACTION_POINTS}
    family_objects = sorted({len(corpus.objects_by_cell[key])
                             for key in family_cells})
    c.equal("corpus.setpiece_cells_carry_one_object",
            (len(family_cells), family_objects),
            (EXPECTED_FAMILY_CELLS, [1]),
            lambda v: f"{v[0]} cell(s) a CrushWall/FootBridge call or a "
                      f"door, lever or barrier action point names, each "
                      f"carrying {v[1]} special object -- so turning, posing "
                      "and freeing per cell is per object on the shipped maps")
    _check_crush_wall_footprints(c, corpus)
    # ...and the other half of "which object on the cell": the scene's own
    # `.3DW` geometry stands on some of those fields too. It is in no table
    # `0x00406F20` reads and it is placed **before** the special objects, so
    # a remake that answers by placement order aims its flight, its joint, its
    # pose and its `aDeleteLand` at the level instead of at the door panel or
    # the bridge block. `FootBridge2`'s cells are counted with the rest here:
    # its call names a group rather than a coordinate, so its cells are the
    # ones whose action point a call carries.
    fb2_cells = {key for key, ap in corpus.ap_by_cell.items()
                 if key[0] in corpus.foot_bridge2_groups
                 and ap in corpus.foot_bridge2_groups[key[0]]}
    shared = tuple(sorted(
        (mission, x, y, len(corpus.clones_on(mission, x, y)))
        for mission, x, y in family_cells | fb2_cells
        if corpus.clones_on(mission, x, y)))
    c.equal("corpus.family_cells_share_fields_with_clones", shared,
            EXPECTED_CLONE_SHARED_CELLS,
            lambda v: f"{len(v)} family cell(s) over "
                      f"{len({row[0] for row in v})} mission(s) carry the "
                      "scene's own geometry beside the object the search "
                      "finds")
    witnesses = tuple(
        (mission, x, y) + corpus.clones_on(mission, x, y)[0]
        + (corpus.objects_by_cell[(mission, x, y)][0],
           corpus.object_z_by_cell[(mission, x, y)][0])
        for mission, x, y, *_ in EXPECTED_CLONE_WITNESSES)
    c.equal("corpus.the_clone_is_not_where_the_object_is", witnesses,
            EXPECTED_CLONE_WITNESSES,
            lambda v: "; ".join(
                f"{row[0]} ({row[1]},{row[2]}): {row[3]} at z {row[4]} "
                f"before {row[5]} at z {row[6]}" for row in v))
    c.equal("corpus.footbridge2_typo", (unmatched, uncalled),
            (EXPECTED_FOOTBRIDGE2_UNMATCHED, EXPECTED_FOOTBRIDGE2_UNCALLED),
            lambda v: f"the call {v[0]} names a tag no cell carries and the block "
                      f"tagged {v[1]} is never called: 139 for 130, so that bridge "
                      "never falls")

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
