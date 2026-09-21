#!/usr/bin/env python3
"""Verify the battle interface of ``docs/43`` against the game and its art.

The battle screen is a 640x480 plate (``Graphics/GUI/plate_5.bmp``) with a
520x340 hole, two columns of nine buttons, a unit panel, a 3x2 command pad
and a radar, and on the ground a pass of 2D sprites -- the remaining movement
points, the hit bands, the direction ring.  None of it is a file format, so
none of the format parsers pin it.  This tool does, in three readings that
share no code with the remake:

* the **tables** `Incubation.exe` dispatches on, read out of the bytes -- the
  100-byte state map and the 16 arms of the ground overlay, the letter table
  of the direction ring, the row-to-event, event-to-sprite and event-to-caption
  switches of the button columns, the command pad's availability gate, and
  both keyboard switches after the Windows message translators;
* the **constants** the routines carry as immediates -- window and panel
  origins, click rectangles, the radar's clip and scale, the zoom gate, the
  blink counter's period -- each at the instruction the document quotes;
* the **art** -- element counts and anchors of the interface libraries, and
  the plate's own geometry measured from its pixels: the radar screen, the pad
  sockets, the button slots, the turn window and the panel inset.

``--emit-cases`` writes the same tables as data for ``godot/tests/test_hud.gd``,
so the GDScript layout is compared against the binary's tables and not against
a Python twin (``docs/92`` §5.1).  Every ``--check`` fails on an empty or
partial corpus: a check that examined nothing did not pass.

Usage::

    python3 tools/hud_tables.py --check gog_incubation
    python3 tools/hud_tables.py --emit-cases tests/fixtures/hud/cases_hud.json \\
        --root gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import bmp, lcl, liblib  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402
from interface_tables import Checker, call_target  # noqa: E402

LOG = logging.getLogger("hud_tables")

GAME_EXE = "Incubation.exe"
PLATE = Path("Graphics") / "GUI" / "plate_5.bmp"
TEXT_DIR = Path("DATA") / "TXT" / "English" / "GUI"
LIB_DIR = Path("Libs")

# --------------------------------------------------------------------------
# aBattleMap.cpp -- the ground overlay `fcn.00417E70`
# --------------------------------------------------------------------------

OVERLAY = 0x00417E70
#: `state - 1` indexes this 100-byte map; the value picks the arm below.
STATE_MAP = 0x00418EA8
STATE_MAP_LEN = 100
#: Sixteen code addresses; index 15 is "nothing".
ARM_TABLE = 0x00418E68
ARM_COUNT = 16
ARMS = [0x004182DA, 0x00418263, 0x004182CC, 0x0041827E, 0x00418288,
        0x00418292, 0x0041829C, 0x004182A6, 0x004182B0, 0x004182B7,
        0x004182BE, 0x00418274, 0x00418254, 0x004182C5, 0x00418274,
        0x004182DA]
#: Cell state -> arm index, as the 100-byte map encodes it.
STATE_TO_ARM = {1: 0, 10: 1, 27: 2, 30: 3, 31: 4, 32: 5, 33: 6, 34: 7,
                35: 8, 36: 9, 37: 10, 50: 11, 60: 12, 70: 13, 71: 13,
                72: 13, 73: 13, 100: 14}
#: What each arm blits: (library, element).  `mp1` digits take the cell's
#: `+0x0C` as the element; arms 1 and 12 draw only while the pointer is over a
#: reachable or warp cell (`var_34h`).
ARM_SPRITES = {
    1: ("mp1", "cell+0x0C"), 2: ("mp", 17), 3: ("mp", 43), 4: ("mp", 44),
    5: ("mp", 45), 6: ("mp", 46), 7: ("mp", 47), 8: ("mp1", 20),
    9: ("mp1", 21), 10: ("mp1", 19), 11: ("mp", 51), 12: ("mp1", 17),
    13: ("mp1", 18), 14: ("mp", 51),
}
# Arms 1, 8..10 and 12..13 load `edi` (the `mp1` element); arms 2..7, 11 and
# 14 write `[ebp-0x10]` (the `mp` element) -- the two registers the blit
# epilogue reads for the two libraries.
#: `mov edi, imm32` (mp1 element) and `mov [ebp-0x10], imm32` (mp element).
ARM_MP1_IMM = {0x0041825C: 17, 0x004182B0: 20, 0x004182B7: 21,
               0x004182BE: 19, 0x004182C5: 18}
ARM_MP_IMM = {0x00418274: 51, 0x0041827E: 43, 0x00418288: 44,
              0x00418292: 45, 0x0041829C: 46, 0x004182A6: 47,
              0x004182CC: 17}
ARM_HOVER_GATE = (0x00418254, 0x00418263)      # mov eax, [esp+0x2C]; test
ARM_DIGIT_LOAD = 0x0041826D                    # mov dl, [esi+0x0C]
HOVER_STATE_REACHABLE = 0x00417ED7             # cmp al, 10
HOVER_STATE_WARP = 0x00417EDB                  # cmp al, 60
HOVER_LEGAL_STORE = 0x00417F23                 # mov [ebp-0x34], 1
HOVER_BLINK_TEST = 0x00418329                  # test byte [0x523068], 1
HOVER_FRAME_STORE = 0x00418334                 # mov [esp+0x24], 48
VP_ZOOM_GATE = 0x00418343                      # cmp ecx, 0x17700
VP_LETTER_BASE = 0x00418358                    # sub eax, 63
FAR_ZOOM_GATE = 0x00418439                     # cmp [esp+0x40], 0x17700
FAR_BLINK_TEST = 0x004185D4                    # test byte [0x4fe264], 1
UNIT_HP_CAP = (0x004186D3, 0x004186F9)         # cmp al, 15
UNIT_HP_CAP_STORE = 0x00418708                 # mov [ebp-0x10], 15
UNIT_PATH_BLINK = 0x004186C3                   # test byte [0x523068], 1
UNIT_PATH_FRAME = 0x004186BA                   # mov eax, 51
UNIT_PATH_ALT = 0x004186EC                     # mov [ebp-0x10], 52
UNIT_DEFENDING_TEST = 0x00418710               # cmp byte [esi+0x41], 1
UNIT_DEFENDING_SPRITE = 0x00418716             # mov [ebp-0x10], 49
UNIT_MALFUNCTION_SPRITE = 0x00418727           # mov [ebp-0x10], 50
UNIT_PANIC_TEST = 0x0041872F                   # cmp byte [esi+0x41], 5
UNIT_PANIC_SPRITE = 0x00418735                 # mov [esp+0x24], 54
# Who writes cell state 100 and what draws it (docs/43 section 3.1). The two
# movers of the whole game: `fcn.0040A750`, which `aAISystemControl`
# `fcn.00409940` calls nineteen times, and `fcn.00472D40`, `aUI.cpp`'s move
# command. Each marks the path and then walks it; only the second redraws in
# between, and that redraw is before the walk.
WALK_MOVE_MAP = 0x004305E0
EXECUTE_MOVE = 0x0046E220
EXECUTE_MOVE_SIZE = 3364
HUD_REDRAW = 0x0041A980
GROUND_OVERLAY = 0x00417E70
AI_MOVE_MARK = 0x0040AB95                      # fcn.0040A750 -> aWalkMoveMap
AI_MOVE_WALK = 0x0040AC43                      # fcn.0040A750 -> aExecuteMove
UI_MOVE_MARK = 0x00472DCA                      # fcn.00472D40 -> aWalkMoveMap
UI_MOVE_WALK = 0x00472E61                      # fcn.00472D40 -> aExecuteMove
UI_MOVE_REDRAW = (0x00472E2E, 0x00472E38)      # fcn.00472D40 -> the HUD redraw
# `fcn.0047DE90` is reached only with the mode global at 2 -- the **network**
# command dispatcher, not the computer's. docs/43 read this arm as the AI's
# once, which is what put the computer's steps on the ground.
NET_MODE_READ = 0x0047C985                     # call fcn.0043B740
NET_MODE_CMP = 0x0047C98A                      # cmp eax, 2
NET_DISPATCH = 0x0047C9A1                      # call fcn.0047DE90
NET_MOVE = 0x0047E3C1                          # fcn.0047DE90 -> fcn.00472D40
GAME_MODE_READ = 0x0043B740                    # mov eax, [0x509EE8] & 0xFF
GAME_MODE_GLOBAL = 0x00509EE8
NETWORK_MODE = 2
# The one function pointer in the picture (docs/43 section 3.1): `fcn.0047D600`
# hands `fcn.0047C2C0` to `aAISystemControl`, which stores it and calls it
# between its own commands. Nothing else in the image names either address.
AI_SYSTEM_CONTROL = 0x00409940
AI_SYSTEM_CONTROL_SIZE = 2619
FRAME_ROUTINE = 0x0047C2C0
FRAME_ROUTINE_PUSH = 0x0047D68F                # push fcn.0047C2C0
CALLBACK_GLOBAL = 0x004FAE38
CALLBACK_STORE = 0x00409956                    # mov [0x4FAE38], esi
CALLBACK_CALLS = (0x00409971, 0x00409BE0, 0x00409C92)
OVERLAY_CALL_SITES = (0x0041AD8B, 0x004567A5, 0x004568BD, 0x0047CC8E)
ZOOM_GATE = 0x17700
TICK_COUNTER = 0x00523068
DRAW_COUNTER = 0x004FE264
UNIT_MARKERS = {"hp_digit_max": 15, "defending": 49, "malfunction": 50,
                "panic": 54, "path_frame": 51, "path_frame_alt": 52,
                "hover_frame": 48, "vp_letter_base": 17,
                "vp_action_point_range": [80, 89]}
FAR_MARKERS = {"owner_flags": [0, 1, 2, 3], "neutral_flag": 4,
               "hidden_flag": 6, "hidden_anchor_from": 4, "blink_flag": 5,
               "blink_state_range": [80, 94]}

# The direction ring.
RING_LETTER_TABLE = 0x00418F1C                 # eight code addresses
RING_LETTERS = [0, 2, 1, 3, 4, 4, 4, 4]        # dir -> dir.LIB element
RING_LETTER_XOR = 0x00418B58                   # arm 0: xor ebx, ebx
RING_CANCEL_ELEMENT = 5
RING_TIER_HOVER = 6
RING_TIER_BLOCKED = 12
RING_TIER_HOVER_LEA = 0x00418C51               # lea edi, [ebx+6]
RING_TIER_BLOCKED_ADD = 0x00418CFE             # add bl, 6 (on top of +6)
RING_HIT_RADIUS_PUSH = (0x00418A3D, 0x00418A42)  # push 600 (twice)
RING_HIT_RADIUS = 600
RING_HOVER_DISTANCE = 0x00418CE0               # cmp [esp+0x44], 20
RING_HOVER_DISTANCE_MAX = 20
RING_CLAMP_LOW = 0x00418CB9                    # add eax, -4
RING_CLAMP = {"low": -4, "high": -9}
RING_BUILD = 0x00406AA0
RING_BUILD_STRAIGHT = 0x00406AFE               # lea edx, [ecx+0xDDE]
RING_BUILD_DIAGONAL = 0x00406B34               # lea edx, [eax-0x93E]
RING_STRAIGHT = 0xDDE
RING_DIAGONAL = 0x93E
RING_HIT_TEST = 0x00406CA0
RING_RECORDS = 0x004FA52C
RING_RECORD_STRIDE = 0x40
RING_RECORD_COUNT = 10
RING_PLACED_FLAG = 0x004FA528
#: Record d -> (dx, dy) in world units around the clicked object.
RING_OFFSETS = [(0, RING_STRAIGHT), (-RING_STRAIGHT, 0), (0, -RING_STRAIGHT),
                (RING_STRAIGHT, 0), (RING_DIAGONAL, -RING_DIAGONAL),
                (-RING_DIAGONAL, RING_DIAGONAL), (RING_DIAGONAL, RING_DIAGONAL),
                (-RING_DIAGONAL, -RING_DIAGONAL), (0, 0)]

# Facing -> neighbour cell (`fcn.004308C0`, jump table 0x00430A20) and
# facing -> 4096-unit angle (`fcn.0046A6E0`, jump table 0x0046A73C).
DIRECTION_DELTA_DISPATCH = 0x004308C0
DIRECTION_DELTA_TABLE = 0x00430A20
DIRECTION_DELTA_CMP = 0x004308C5               # cmp eax, 7
FACING_DELTAS = [(0, 1), (-1, 0), (0, -1), (1, 0), (1, -1), (-1, 1), (1, 1),
                 (-1, -1)]
DIRECTION_ANGLE_DISPATCH = 0x0046A6E0
DIRECTION_ANGLE_TABLE = 0x0046A73C
DIRECTION_ANGLE_CMP = 0x0046A6E4               # cmp eax, 7
FACING_ANGLES = [0, 0xC00, 0x800, 0x400, 0x600, 0xE00, 0x200, 0xA00]

# The 100 ms counter the overlay blinks on (`fcn.0047F190`).
TICK_ROUTINE = 0x0047F190
TICK_PERIODS = {0x0047F1A0: 5, 0x0047F1C2: 20, 0x0047F1E4: 100,
                0x0047F206: 300}
TICK_STORE = 0x0047F1F6                        # mov byte [0x523068], cl

# --------------------------------------------------------------------------
# aUI.cpp -- clicks, the ring, the command pad, the unit panel
# --------------------------------------------------------------------------

CLICK = 0x004714B0
CLICK_PAD_ARG = 0x004714D4                     # push 42
CLICK_PAD_HIT = (0x004714E2, 0x00473680)
CLICK_PAD_RUN = (0x004714EF, 0x00471310)
CLICK_STATE_WARP = 0x00471615                  # cmp dl, 60
CLICK_STATE_REACHABLE = 0x00471668             # cmp dl, 10
CLICK_BAND_LOW = 0x004715E1                    # cmp al, 30
CLICK_BAND_HIGH = 0x004715ED                   # cmp al, 37
RING_MODE = 0x00516310
RING_MODE_STORES = {0x00471645: 3, 0x00471698: 1, 0x004718B5: 2}
CLICK_ATTACK = (0x00471777, 0x00473080)
CLICK_TURN_TO_TARGET = (0x0047181C, 0x0047A8E0)
CLICK_ROTATE = (0x00471839, 0x004735D0)
CLICK_RESELECT = (0x00471805, 0x00472990)
CLICK_RING_BUILD = (0x00471659, 0x004721A0)
RING_CLICK = 0x00471AD0
RING_CLICK_HIT = (0x00471B2A, RING_HIT_TEST)
RING_CLICK_CANCEL = 0x00471B36                 # cmp eax, 8
RING_CLICK_WARP = (0x00471BDA, 0x00472F10)
RING_CLICK_MOVE = (0x00471C03, 0x00472D40)
RING_CLICK_ROTATE = (0x00471C63, 0x004735D0)
RING_CLICK_RESELECT = (0x00471C79, 0x00472990)
RING_CLICK_MP_TEST = 0x00471CB6                # cmp byte [eax+0x15], bl
RING_CLICK_DESELECT = (0x00471CD9, 0x00471E00)
ROTATE_WRAPPER = 0x004735D0
ROTATE = 0x004792A0                            # aChangeUnitViewDirection
ROTATE_REFUSE_LOW = 0x00479330                 # cmp al, 61
ROTATE_REFUSE_HIGH = 0x00479334                # cmp al, 63
ROTATE_FACING_STORE = 0x00479345               # mov byte [esi+0x46], al
ROTATE_ANGLE_CALL = (0x0047934E, DIRECTION_ANGLE_DISPATCH)

# The place interface, aPI.cpp (docs/43 section 5.5).  interface_tables.py
# already pins the marker band 70..73, the `+0x4D` candidate test and the two
# transfer calls under its own `deploy.*` names; these are the rest.
PLACE_INIT_CALL = (0x0041A663, 0x004632E0)     # aInitBattleGround -> aInitPlaceInterface
PLACE_INIT_POOL_COUNT = (0x00463355, 0x00478960)
PLACE_INIT_SELECT_STORE = 0x00463364           # mov [0x514064], eax
PLACE_SELECT_GLOBAL = 0x00514064
PLACE_CLICK = 0x00463380
PLACE_NORMAL_CLICK_CALL = (0x0041BE0D, 0x004714B0)
PLACE_CLICK_CALL = (0x0041BEC8, PLACE_CLICK)
PLACE_TURN_GATE = (0x00463382, 0x0043B280)
PLACE_BAND = 0x004637C0
PLACE_BAND_Y_HIGH = 0x004637C5                 # cmp eax, 459 ; jae out
PLACE_BAND_Y_LOW = 0x004637D1                  # cmp eax, 385 ; jbe out
PLACE_BAND_PREV_X_HIGH = 0x004637DD            # cmp eax, 220 ; jae next
PLACE_BAND_PREV_X_LOW = 0x004637E9             # cmp eax, 47  ; jbe out
PLACE_BAND_PREV_RESULT = 0x004637EE            # mov eax, 2
PLACE_BAND_NEXT_X_LOW = 0x004637F9             # cmp eax, 220 ; jbe out
PLACE_BAND_NEXT_X_HIGH = 0x00463805            # cmp eax, 394 ; jae out
PLACE_BAND_NEXT_RESULT = 0x0046380C            # mov eax, 1
PLACE_BAND_Y = [386, 458]
PLACE_BAND_PREV_X = [48, 219]
PLACE_BAND_NEXT_X = [221, 393]
PLACE_SCREEN_W = (0x00463552, 0x00419A50)
PLACE_SCREEN_H = (0x00463560, 0x00419A60)
PLACE_FACING_LEFT = (0x00463572, 0x00463575)   # and edx, 2 ; add edx, 4
PLACE_FACING_RIGHT = (0x0046358E, 0x00463591)  # and ecx, -2 ; add ecx, 7
PLACE_FACING_BY_QUADRANT = {"0,1": 4, "0,0": 6, "1,0": 5, "1,1": 7}
PLACE_FROM_POOL_CALL = (0x004635AB, 0x00478D10)
PLACE_FROM_POOL_ARGS = 0x004635B0              # add esp, 0x14 -- five arguments
PLACE_TO_POOL_CALL = (0x004634C7, 0x00478F20)
PLACE_SELECT_NONE_STORE = 0x004635EF           # mov [0x514064], -1
PLACE_PREV_ARM = 0x0046363D
PLACE_NEXT_ARM = 0x004636B7
PLACE_COUNT_CALLS = (0x0046369C, 0x00463700)   # both arms -> poolCount
PLACE_SOUND_PLACE = 0x00514068                 # <- [0x4FE340] click_1
PLACE_SOUND_CYCLE = 0x0051406C                 # <- [0x4FE344] click_2
PLACE_SOUND_SITES = {0x0046348F: PLACE_SOUND_PLACE, 0x00463526: PLACE_SOUND_PLACE,
                     0x0046364A: PLACE_SOUND_CYCLE, 0x004636C0: PLACE_SOUND_CYCLE}

PAD_HIT = 0x00473680
PAD_RECT = {"x": [404, 494], "y": [382, 478], "stride": [30, 48]}
PAD_X_LOW = 0x004736A0                         # cmp eax, 404
PAD_X_HIGH = 0x004736AB                        # cmp eax, 494
PAD_Y_LOW = 0x004736BA                         # cmp esi, 382
PAD_Y_HIGH = 0x004736C6                        # cmp esi, 478
PAD_DIV_30 = 0x004736D8                        # mov eax, 0x88888889
PAD_DIV_48 = 0x004736EB                        # mov eax, 0x2AAAAAAB
PAD_HIT_GATE = (0x00473712, 0x00472570)
PAD_HIT_COMMAND = (0x00473736, 0x00472120)
PAD_GATE = 0x00472570
PAD_GATE_TABLE = 0x0047275C
#: command -> ui.LIB element of the *available* icon; hover is element + 1,
#: an unavailable command draws element 0 (the empty socket).
PAD_SPRITES = {1: 2, 2: 4, 3: 8, 5: 6, 7: 10, 8: 12}
PAD_UNAVAILABLE = 0x00472755                   # the -1 arm
PAD_GATE_DEFENCE = (0x004725DA, 0x004753E0)
PAD_GATE_HEAL = (0x0047261D, 0x0047B4C0)
PAD_GATE_HEAL_MP = 0x0047262D                  # cmp byte [esi+0x15], 1
PAD_GATE_WEAPON = (0x00472671, 0x00475430)
PAD_GATE_CLASS = 0x00472658                    # cmp byte [edx*2+0x51C099], 3
PAD_GATE_USE_TARGET = (0x004726C2, 0x0047A530)
PAD_GATE_USE_ALT = ((0x0047270C, 0x0047B250), (0x00472728, 0x0047B410),
                    (0x00472744, 0x0047B480))
PAD_DRAW = 0x00472330
PAD_DRAW_GATE = (0x00472375, PAD_GATE)
PAD_DRAW_BLIT = (0x004723AA, 0x004475D0)
#: (column, row) -> command, docs/29 §1.1 (pinned by interface_tables too).
PAD_COMMANDS = {(0, 0): 1, (0, 1): 3, (1, 0): 2, (1, 1): 7, (2, 0): 5,
                (2, 1): 8}
#: The command pad's ASCII switch, `D` through `W`.  The index table selects
#: one of six command arms or the zero arm.
PAD_KEY_INDEX = 0x004737F0
PAD_KEY_ARMS = 0x004737D4
PAD_KEY_LOW = ord("D")
PAD_KEY_HIGH = ord("W")
PAD_KEY_TARGETS = {0x0047375A: 1, 0x00473761: 2, 0x0047376F: 7,
                   0x0047377D: 3, 0x00473776: 8, 0x00473768: 5,
                   0x00473784: 0}
ORIGINAL_COMMAND_KEYS = {"D": 1, "H": 2, "S": 3, "W": 5, "R": 7,
                         "U": 8}

PANEL_CALLER = 0x00473960
PANEL_RESTORE = (0x004739C3, 0x004758F0)
PANEL_CALL = (0x004739E9, 0x004756D0)
PANEL_ORIGIN_PUSH = 0x004739B9                 # push 415; push 60
PANEL_ORIGIN = (60, 415)
PANEL_NAME_Y = 397
PANEL = 0x004756D0
PANEL_HP_BLOCK = (0x004757A4, 0x00474DD0)      # (x, y + 10)
PANEL_XP_BLOCK = (0x004757E0, 0x00474850)      # (x + 75, y - 10)
PANEL_XP_OFFSET = 0x004757D9                   # lea edx, [ebx+0x4B]
PANEL_WEAPON_BLOCK = (0x00475893, 0x00474220)  # (x + 145, y)
PANEL_WEAPON_OFFSET = 0x0047588A               # lea ecx, [ebx+0x91]
PANEL_MP_BLOCK = (0x004758B9, 0x00474AF0)      # (x + 235, y + 15)
PANEL_MP_OFFSET = 0x004758B0                   # lea ecx, [ebx+0xEB]
PANEL_SKILLS_BLOCK = (0x004758D6, 0x00475A60)  # (x + 275, y - 10)
PANEL_SKILLS_OFFSET = 0x004758C9               # add ebx, 0x113
PANEL_HP_MAX = (0x00475774, 0x00475240)
PANEL_HEAT_LIMIT = (0x00475721, 0x00475340)
PANEL_AMMO_MAX = (0x00475862, 0x004752A0)
PANEL_TIER = (0x004757C0, 0x00475550)
PANEL_ALIEN_TEST = 0x004757F4                  # cmp byte [ecx*2+0x51C099], 1
PANEL_BLOCKS = {"hp": [0, 10], "experience": [75, -10], "weapon": [145, 0],
                "movement": [235, 15], "skills": [275, -10]}
PANEL_ICONS = {"hp_frame": 11, "class_marine": 12, "class_alien": 13,
               "class_robot": 26, "armour_rung": 9, "wound_dot": 10,
               "experience_frame": 8, "tier_disc": 18, "decoration_first": 16,
               "weapon_frame": 7, "lamp_a": 25, "lamp_b": 24,
               "malfunction_first": 21, "movement_disc": 17}
PANEL_STATUS_TEXT = {"panic": 70, "light_panic": 71, "hot": 72,
                     "no_ammo": 73}

# --------------------------------------------------------------------------
# aMI.cpp -- button columns, radar, the frame
# --------------------------------------------------------------------------

COLUMN_HIT = 0x00451240
COLUMN_RECT = {"x": [[11, 49], [594, 632]], "y": [66, 345], "row_height": 31}
COLUMN_Y_LOW = 0x00451255                      # cmp eax, 66
COLUMN_Y_HIGH = 0x0045125A                     # cmp eax, 345
COLUMN_X0_LOW = 0x00451261                     # cmp esi, 11
COLUMN_X0_HIGH = 0x00451266                    # cmp esi, 49
COLUMN_X1_LOW = 0x0045126B                     # cmp esi, 594
COLUMN_X1_HIGH = 0x00451273                    # cmp esi, 632
COLUMN_DIV_31 = 0x0045127E                     # mov eax, 0x08421085
COLUMN_HIT_SPRITE = (0x004512B4, 0x00451A70)
COLUMN_HIT_EVENT = (0x004512D7, 0x00451490)
COLUMN_EVENT_DISPATCH = 0x00451490
#: Column 0 (left) dispatches through the second table, column 1 through
#: the first: `sub eax, 0; je` picks the left column's arms.
COLUMN_EVENT_TABLES = (0x00451548, 0x00451524)
#: (column, row) -> interface event of `0x00453900`; 0 is an empty slot.
COLUMN_EVENTS = [[8, 7, 6, 5, 11, 15, 16, 0, 9], [1, 3, 4, 2, 12, 14, 13, 0, 10]]
COLUMN_SPRITE_DISPATCH = 0x00451A70
COLUMN_SPRITE_TABLE = 0x00451D0C
#: event -> mi.LIB element of the available (dim) icon; hover is element + 1.
COLUMN_SPRITES = {1: 20, 2: 28, 3: 24, 4: 26, 5: 4, 6: 2, 7: 8, 8: 6, 9: 16,
                  10: 12, 11: 14, 12: 10, 13: 18, 14: 22, 15: 33, 16: 35}
COLUMN_EMPTY_SPRITE = 31
COLUMN_CAPTION_DISPATCH = 0x00451770
COLUMN_CAPTION_TABLE = 0x004518A0
#: event -> Txtmod_h id (module 3) of the hint drawn at (60, 22).
COLUMN_CAPTIONS = {1: [38], 2: [34], 3: [36], 4: [35], 5: [25], 6: [24],
                   7: [27], 8: [26], 9: [29], 10: [28], 11: [31], 12: [30],
                   13: [32, 33], 14: [37], 15: [39], 16: [46]}
COLUMN_CAPTION_POS = (0x00451878, 0x00451872)  # push 60; push 22
COLUMN_CAPTION_COLOUR = 0x00451866             # push 0x632C
COLUMN_CAPTION_PRINT = (0x0045187C, 0x00439610)
COLUMN_DRAW = 0x00451D50
COLUMN_DRAW_X = 0x00451DAA                     # add ecx, 11
COLUMN_DRAW_EMPTY = 0x00451DBE                 # push 31
COLUMN_DRAW_BLIT = (0x00451DD3, 0x004475D0)
COLUMN_DRAW_Y_END = 0x00451DDF                 # cmp esi, 345
COLUMN_RIGHT_SHIFT = 0x247                     # 583 = 594 - 11
COLUMN_HOVER = 0x004518E0
COLUMN_HOVER_Y = 0x00451927                    # add edx, 66
COLUMN_HOVER_X = 0x0045192A                    # add eax, 11
#: The keyboard translator consumes the normalized byte written by the two
#: Windows message translators below.  Its table covers 0..`T`; Left and
#: Right take camera arms directly, while the other named entries produce an
#: interface event.
COLUMN_KEY_INDEX = 0x00451430
COLUMN_KEY_ARMS = 0x004513E4
COLUMN_KEY_HIGH = ord("T")
COLUMN_KEY_TARGETS = {
    0x00451357: 12, 0x00451373: 15, 0x00451350: 10,
    0x0045135E: 9, 0x00451312: "left", 0x00451328: "right",
    0x00451349: 16, 0x0045133B: 8, 0x00451342: 7,
    0x0045139D: 6, 0x00451396: 5, 0x0045137A: 1,
    0x00451381: 2, 0x00451388: 3, 0x0045138F: 4,
    0x004513A4: 11, 0x00451365: 13, 0x0045136C: 14,
    0x004513AB: 0,
}
ORIGINAL_EVENT_KEYS = {1: "1", 2: "2", 3: "3", 4: "4", 5: "F4",
                       6: "F3", 7: "F2", 8: "F1", 9: "ESCAPE",
                       10: "ENTER", 11: "B", 12: "TAB", 13: "G",
                       14: "T", 15: "BACKSPACE", 16: "DELETE"}
ORIGINAL_NORMALIZED_ACTIONS = {
    0: 12, 1: 15, 2: 10, 5: 9, 8: "left", 10: "right", 12: 16,
    15: 8, 16: 7, 17: 6, 18: 5, ord("1"): 1, ord("2"): 2,
    ord("3"): 3, ord("4"): 4, ord("B"): 11, ord("G"): 13,
    ord("T"): 14,
}
#: `WM_KEYDOWN` maps virtual keys to the normalized byte above; `WM_CHAR`
#: maps the control characters and passes printable ASCII through.
KEYDOWN_INDEX = 0x0047EF78
KEYDOWN_ARMS = 0x0047EF48
KEYDOWN_TARGETS = {0x0047EEFF: 8, 0x0047EEEB: 10, 0x0047EF13: 12}
KEYDOWN_F_RANGE = 0x0047EF31
CHAR_INDEX = 0x0047F020
CHAR_ARMS = 0x0047F008
CHAR_TARGETS = {0x0047EFBB: 1, 0x0047EFE2: 0, 0x0047EFEF: 2,
                0x0047EFD5: 5}
CHAR_PASSTHROUGH = 0x0047EFFC
#: Space is handled by the mission loop after neither interface translator
#: answers.  It alternates the selected unit between views 1 and 2.
SPACE_TEST = 0x0041BAB0
SPACE_MODE_CALL = (0x0041BABB, 0x004536D0)
SPACE_EYES_CALL = (0x0041BAC5, 0x00451150)
SPACE_UNIT_CALL = (0x0041BADA, 0x004510A0)
RADAR = 0x00451E50
RADAR_CLIP_PUSH = 0x00451E72                   # push 66; push 90; push 389; push 501
RADAR_CLIP = (501, 389, 90, 66)
RADAR_CENTRE = (546, 422)
RADAR_CENTRE_SUB = (0x00451EF2, 0x00451EF7)    # sub eax, 546; sub ecx, 422
RADAR_SCALE = 0x005106DC
RADAR_SCALE_READ = 0x00452055                  # mov ecx, [0x5106DC]
RADAR_SCALE_DEFAULT_STORE = 0x004533BD         # mov [0x5106DC], 40
RADAR_SCALE_DEFAULT = 40
RADAR_SCALE_STEP = 5
RADAR_SCALE_RANGE = (20, 80)
RADAR_SCALE_SPLIT = 546
RADAR_NEUTRAL_TEST = 0x004521AE                # cmp cl, 0xFC
RADAR_VISIBLE_CELL_TEST = 0x004521B7           # cmp byte [eax], 1
RADAR_LAMP_PUSH = (0x00452329, 0x0045234D)     # push 453; push 616; push 11 / 10
RADAR_LAMP = (616, 453)
RADAR_LAMP_SPRITES = {"enemy_visible": 11, "enemy_detected": 10}
RADAR_COMPASS_TABLE = 0x0050FE40
RADAR_COMPASS_TABLE_LOAD = 0x00451EE3           # mov esi, 0x50FE44
RADAR_COMPASS_WRITES = {0x00450C65: 397, 0x00450C6F: 447, 0x00450C79: 521,
                        0x00450C83: 571}
RADAR_ZOOM_CLICK = 0x00452390
RADAR_CLICK_RECT = (501, 591, 389, 455)
RADAR_XY = 0x00451E00
RADAR_XY_CONSTANTS = (90, 66, 501, 455)
RADAR_COMPASS = {"N": [546, 397], "S": [546, 447], "W": [521, 422],
                 "E": [571, 422]}
RADAR_COMPASS_SPRITES = {"N": 6, "S": 7, "W": 8, "E": 9}
RADAR_UNIT_SPRITES = {"own": 0, "own_no_mp": 1, "own_selected": 4,
                      "other_seen": 2, "other": 3, "hidden": 5}

FRAME = 0x0041A980
WINDOW = (60, 34, 520, 340)
WINDOW_STORE = 0x0041A49E                      # mov [0x4FE330..3C], 60/34/520/340
WINDOW_GLOBALS = (0x004FE330, 0x004FE334, 0x004FE338, 0x004FE33C)
PLATE_STRIPS = [(0, 0, 640, 34), (0, 374, 640, 106), (0, 34, 60, 340),
                (580, 34, 60, 340)]
FRAME_PUSH_34 = 0x0041AAA6                     # push 34
FRAME_PUSH_106 = 0x0041AADD                    # push 106
FRAME_PUSH_340 = (0x0041AB4B, 0x0041ABB9)      # push 340
FRAME_TURN_RED = 0x0041B1D1                    # mov [esp+0x10], 0xF800
FRAME_TURN_POS = (0x0041B20B, 0x0041B202)      # push 560; push 22
FRAME_TURN = (560, 22)
FRAME_TURN_RED_WITHIN = 3
FRAME_TURN_LIMIT_FLAG = 0x0043BE70
FRAME_TURN_LIMIT_VALUE = 0x0043BDE0
FRAME_TURN_LIMIT_TEXT = 0x0043BDD0

# --------------------------------------------------------------------------
# LibMaker.cpp -- the blitter and the anchors
# --------------------------------------------------------------------------

BLITTER = 0x004475D0
BLITTER_ELEMENT_STRIDE = 36
BLITTER_LEA_9 = 0x004475E4                     # lea ecx, [eax+eax*8]
BLITTER_TABLE_OFFSET = 0x004475EA              # mov edx, [eax+0x0C]
BLITTER_DATA_OFFSET = 0x004475F0               # mov edi, [ecx+eax+0x10]
BLITTER_PIXELS_BASE = 0x004475FB               # mov ecx, [eax+0x10]
BLITTER_TRANSPARENT_TEST = 0x0044772D          # cmp al, 0
ANCHOR_X = 0x00446200
ANCHOR_Y = 0x00446220
ANCHOR_OFFSETS = (0x1C, 0x20)
REMAP_SET = 0x00447BB0
CLIP_SET = 0x00447B20

# --------------------------------------------------------------------------
# Loaders and libraries
# --------------------------------------------------------------------------

BATTLE_MAP_INIT = (0x00417790, 700)
BATTLE_MAP_LIBS = {"mp.lib": 0x004FD234, "mp1.lib": 0x004FD640,
                   "map.lib": 0x004FDA4C, "dir.lib": 0x004FDE58}
MAP_INTERFACE_INIT = (0x00450A80, 532)
MAP_INTERFACE_LIBS = {"mi.lib": 0x0050FEA0, "sm.lib": 0x005102AC}
UI_ICONS_INIT = (0x00473A20, 748)
UI_ICON_LIBS = {"uicons.lib": 0x00517B98, "inv.lib": 0x00517B9C,
                "uweapons.lib": 0x00517BA0, "umun.lib": 0x00517BA4,
                "uequip.lib": 0x00517BA8}
UI_INIT = (0x004710E0, 335)
UI_LIBS = {"ui.lib": 0x0051632C}

LIB_COUNTS = {"mp": 55, "mp1": 22, "dir": 18, "sm": 12, "ui": 14, "mi": 37,
              "uicons": 27, "map": 16, "mouse": 11, "umun": 5,
              "uweapons": 17, "uequip": 17, "inv": 12, "vp": 2}
#: Libraries whose every element the fixture carries with its anchor.
FIXTURE_LIBS = ("mp", "mp1", "dir", "sm", "ui", "mi", "uicons", "map",
                "mouse", "inv", "umun", "uweapons", "vp")
LIB_SHAPES = {("mp1", 0): (9, 9, 4, 4), ("dir", 0): (13, 15, 6, 7),
              ("dir", 4): (9, 11, 4, 5), ("mp", 43): (25, 16, 12, 5),
              ("mp", 48): (19, 19, 9, 9), ("mp", 51): (20, 20, 9, 9),
              ("mp", 49): (7, 9, 3, 3), ("mp", 50): (8, 8, 3, 3),
              ("mp", 54): (9, 9, 4, 4), ("mp", 0): (3, 5, 1, 2),
              ("map", 0): (10, 10, 4, 4), ("sm", 0): (5, 5, 2, 2),
              ("vp", 0): (15, 34, 320, 259), ("vp", 1): (15, 34, 320, 259)}

# --------------------------------------------------------------------------
# aViewPlayer.cpp -- the watched player's progress bar
# --------------------------------------------------------------------------

#: ``aInitViewPlayer`` -- the engine names itself at 0x0047BD5A, "aInitViewPlayer
#: (Render_BMP)".  It loads a whole-screen bitmap out of `plate_5.bmp`, `vp.lib`
#: with its own `vp.pal` remap, and two waves.
VIEW_PLAYER_INIT = (0x0047BCF0, 1176)
VIEW_PLAYER_PLATE = 0x0047BDB1               # push "GUI\plate_5.bmp"
VIEW_PLAYER_LIB_HANDLE = 0x0047BF43          # push &0x00522A04
VIEW_PLAYER_LIB_NAME = 0x0047BF52            # push "vp.lib"
VIEW_PLAYER_LIB = 0x00522A04
VIEW_PLAYER_SOUND_NAME = 0x0047C03F          # push "progress.wav"
VIEW_PLAYER_SOUND_HANDLE = 0x0047C04F        # push &0x00522E10
VIEW_PLAYER_SOUND = 0x00522E10
VIEW_PLAYER_PREV_RESET = 0x0047C0CF          # mov dword [0x00522E18], 0
#: ``fcn.0047DA00`` -- the bar itself, and ``fcn.0047D090``'s last call.
#: ``fcn.0047D090`` -- the frame the watcher draws: the plate's four strips
#: out of the whole-screen bitmap, then the bar. Twice a frame, once per
#: buffer (``0x0047D026``, ``0x0047D045``).
VIEW_PLAYER_FRAME = 0x0047D090
VIEW_PLAYER_FRAME_CALLS = (0x0047D026, 0x0047D045)
STRIP_COPY = 0x0044B1B0
VIEW_PLAYER_STRIPS = (0x0047D0C9, 0x0047D13A, 0x0047D1A8, 0x0047D240)
#: The rows each strip copies: the top band, the bottom band and the two
#: columns -- the same 34, 106 and 340 the interface's own redraw pushes.
VIEW_PLAYER_STRIP_ROWS = ((0x0047D09E, 34), (0x0047D0DC, 106),
                          (0x0047D14A, 340), (0x0047D1B8, 340))
PROGRESS_BAR = (0x0047DA00, 444)
PROGRESS_CALL = 0x0047D25A                   # call 0x0047DA00
PROGRESS_PLAYER = 0x0047D24F                 # call 0x0043B2C0, the seat
CURRENT_PLAYER_READ = 0x0043B2C0
#: The two gates, in call order: the turn counter must have moved and the
#: seat must not be a second human's.
PROGRESS_GATE_TURN = 0x0047DA04
PROGRESS_GATE_SEAT = 0x0047DA11
TURN_COUNTER_READ = 0x0043B280
SEAT_READ = 0x0043B240
#: The two sweeps of the 200-unit array, both at stride 91.
PROGRESS_LIVE_CALL = 0x0047DA23
PROGRESS_ACTED_CALL = 0x0047DA2E
COUNT_LIVE = 0x00477BF0
COUNT_ACTED = 0x00477FB0
UNIT_ARRAY_BASE = 0x00477AD0
UNIT_STRIDE = 0x5B
UNIT_COUNT = 0xC8
ALLOWANCE = 0x00475160
#: ``0x0047DA3E``: `shl ecx, 3 / sub ecx, eax / lea eax, [ecx+ecx*2]` is
#: `acted * 21`, and `div edi` divides by the live count.
PROGRESS_SCALE = 0x0047DA3E
PROGRESS_DIV = 0x0047DA46
#: ``0x00522E18`` -- last frame's fill, drawn when it is the larger.
PROGRESS_PREV = 0x00522E18
#: `mov esi, 0x3B` before the lit run and `add esi, 0x3B` before the dark one.
PROGRESS_X = (0x0047DB05, 0x0047DB5C)
PROGRESS_ORIGIN_X = 0x3B
#: `push 0x196` -- the row both runs blit on.
PROGRESS_Y = (0x0047DB1A, 0x0047DB88)
PROGRESS_ORIGIN_Y = 0x196
#: `cmp esi, 0x15` skips the dark run, `mov eax, 0x16` counts it.
PROGRESS_LIMIT = 0x0047DB4B
PROGRESS_SEGMENTS_AT = 0x0047DB57
PROGRESS_SEGMENTS = 22
PROGRESS_STEPS = 21
#: `push 0` in the lit run, `push 1` in the dark one.
PROGRESS_ELEMENTS = (0x0047DB25, 0x0047DB93)
#: `fcn.004461C0(0, lib)` -- element 0's width, the step between capsules.
PROGRESS_WIDTH_CALL = 0x0047DADC
ELEMENT_WIDTH = 0x004461C0
#: Both runs go through the same blitter, and neither reads an anchor.
PROGRESS_BLITS = (0x0047DB32, 0x0047DB9D)

# --------------------------------------------------------------------------
# The selection is a global, and the interface refills it -- aUI.cpp
# --------------------------------------------------------------------------

#: `[0x005162F0]` is the selected unit's slot, `0xFFFF` for none, with its
#: cell cached beside it in `[0x005162E8]`/`[0x005162EC]`.
SELECTION = 0x005162F0
SELECTION_X = 0x005162E8
SELECTION_Y = 0x005162EC
SELECTION_NONE = 0xFFFF
#: Every write to it in the whole image.  **Three clear it and two set it**,
#: and the hand-over is none of the five: the marine the player last had is
#: still selected when the computer is done.
SELECTION_WRITES = ((0x00471220, SELECTION_NONE), (0x00472320, SELECTION_NONE),
                    (0x00472CFB, SELECTION_NONE),
                    (0x0047225B, None), (0x00472305, None))
#: The two that write the sentinel as an immediate.
SELECTION_CLEAR_IMM = (0x00471220, 0x00472320)
#: And the one that writes it out of `cx`: `fcn.00472CC0`, the tail every
#: player command runs, which is docs/43 section 4's "a unit that has spent
#: its movement is dropped after its command".  Its four callers are command
#: executors of `aUI.cpp`, reached from the click, the ring and `0x00471310`
#: -- and, for a remote player's command, from the network pump.
SELECTION_CLEAR_REG = 0x00472CFB
COMMAND_TAIL = 0x00472CC0
COMMAND_TAIL_SENTINEL = 0x00472CF3            # mov ecx, 0xFFFF
COMMAND_TAIL_CALLERS = (0x00472EF0, 0x0047305D, 0x00473233, 0x0047353E)
#: The one that runs once, from `aInitBattleGround`.
SELECTION_RESET = 0x004710E0
SELECTION_RESET_CALL = 0x0041A54C
BATTLE_GROUND_INIT = 0x00419D90
#: Every instruction in `.text` that names the global at all: the five writes
#: plus the two reads, `0x00471E49` and `0x004721F0`.  This is what "the
#: hand-over does not touch it" actually rests on, so it is counted rather
#: than taken from one `axt`.
SELECTION_REFERENCES = 7

#: `fcn.004721F0(mode)` -- move the selection.  Its **first** branch is the
#: one that matters here: with nothing selected it takes `fcn.00477CE0`'s
#: answer and returns, whatever the mode was.
MOVE_SELECTION = 0x004721F0
MOVE_SELECTION_EMPTY_TEST = 0x004721F0        # cmp word [0x5162F0], 0xFFFF
MOVE_SELECTION_FIRST_CALL = 0x00472207        # call fcn.00477CE0
FIRST_UNIT = 0x00477CE0
#: The two searches the modes select: 0 is `fcn.00477EC0`, 1 `fcn.00477D40`.
MOVE_SELECTION_MODES = ((0x004722AF, 0x00477EC0), (0x0047228B, 0x00477D40))
#: `fcn.00471E00(mode)` is what every caller actually calls; it refuses before
#: the first hand-over and when the side has no live unit.
SELECT_ENTRY = 0x00471E00
SELECT_ENTRY_GATES = ((0x00471E01, TURN_COUNTER_READ),
                      (0x00471E1C, COUNT_LIVE))
SELECT_ENTRY_CALL = 0x00471E34
#: `aInitBattleGround`'s own call, mode 1, at the start of the first turn.
#: With the `SelectNextUnit` script command below, the only two places that
#: ask for a selection without a click.
SELECT_AT_START = (0x0041A738, 1)
#: `SelectNextUnit` -- `fcn.00441270` calls `fcn.00471E00(0)`, and the LCL
#: dispatcher `fcn.00442DE0` reaches it from the command name at `0x0044438D`.
#: **No shipped script uses it**, which is why it changes nothing here.
SCRIPT_SELECT_NEXT = 0x00441270
SCRIPT_SELECT_NEXT_MODE = 0x00441270          # push 0
SCRIPT_SELECT_NEXT_CALL = 0x00441272
SCRIPT_SELECT_NEXT_NAME = 0x004C53C0          # "SelectNextUnit"
#: **The camera follows the selection**, and it is not a routine of its own:
#: every caller that gets a `1` back from `fcn.00471E00` calls `fcn.004533D0`,
#: which re-applies the *current view mode* on the selection's cell.  The cell
#: comes from `fcn.00471F70`, which reads the **current** selection
#: `[0x005162F8]` and its cell `[0x005162FC]`/`[0x00516300]` -- the word
#: `fcn.00472990`, the select itself, writes.
VIEW_APPLY = 0x004533D0
VIEW_MODE = 0x005106D8
#: `[0x005106D8]` -> the placer, out of the `sub/dec/dec` cascade at
#: `0x004533D8`..`0x004533E0`.  Mode 2 is the default a mission opens in
#: (`fcn.00452940`) and is `(8, 7, 0)` on the unit -- the same placement
#: `docs/42` section 2.3 recorded for the cycle.
VIEW_MODE_ARMS = ((0, 0x00453410), (1, 0x00451150), (2, 0x004510A0),
                  (3, 0x00450F60))
VIEW_UNIT_PLACE = 0x00451141                  # call fcn.004529D0(x, y, 8,7,0)
VIEW_UNIT_ARGS = 0x00451131                   # push 7 / push 8
VIEW_UNIT_MODE_WRITE = 0x00451137             # mov [0x005106D8], 2
VIEW_DEFAULT_MODE = 0x00452940                # mov [0x005106D8], 2 at start
VIEW_SELECTION_READ = 0x00471F74              # mov cx, word [0x005162F8]
SELECTION_CURRENT = 0x005162F8
SELECTION_CURRENT_CELL = (0x005162FC, 0x00516300)
SELECT_CELL = 0x00472990                      # writes it at 0x00472A90
SELECT_CELL_WRITE = 0x00472A90
#: The callers that re-apply the view after a select: `aInitBattleGround`,
#: `SelectNextUnit`, the click, the ring, and the drop of a spent unit.
VIEW_APPLY_AFTER_SELECT = (0x0041A754, 0x0044127E, 0x0047149B, 0x004717E8,
                           0x00471C42)

#: `fcn.00477CE0`'s two passes: alive at `+0x16`, owned at `+0x45`, and -- in
#: the first pass only -- movement left at `+0x15`.
FIRST_UNIT_PASSES = (0x00477CF1, 0x00477D1E)
FIRST_UNIT_MOVEMENT_TEST = 0x00477D00
FIRST_UNIT_NONE = 0x00477D38

# --------------------------------------------------------------------------
# aViewPlayer.cpp -- the screen the whole watched turn is drawn on
# --------------------------------------------------------------------------

#: `fcn.0047C2C0` and its length.  It is not an overlay on the battle screen
#: but a whole game state: `fcn.0044AAE0`'s dispatcher runs it as one arm, and
#: `fcn.0047D600` hands it to `aAISystemControl` as the per-frame callback --
#: which is why the computer's turn is drawn on it at all.
VIEW_PLAYER_SCREEN = (0x0047C2C0, 3490)
#: `[0x005229D4]`, the screen's own state; `fcn.0047DBD0` reads it and
#: `fcn.0047DBC0` writes it.
VIEW_PLAYER_STATE = 0x005229D4
VIEW_PLAYER_STATE_READ = 0x0047DBD0
VIEW_PLAYER_STATE_WRITE = 0x0047DBC0
#: `jmp dword [eax*4 + 0x0047D064]`, and the seven arms it names.  States 2, 3
#: and 4 share an entry point and separate later; 0 is the hand-over pause,
#: 1 the end of the game, 5 and 6 the two network aborts.
VIEW_PLAYER_STATE_SWITCH = 0x0047D064
VIEW_PLAYER_STATE_DISPATCH = 0x0047C350
VIEW_PLAYER_STATE_ARMS = (0x0047C3FF, 0x0047C357, 0x0047C985, 0x0047C985,
                          0x0047C985, 0x0047C8AE, 0x0047C7E5)

#: `aTxtSys.cpp`: set the active module, read it back, fetch a string, open a
#: module into a slot.
TEXT_MODULE_SET = 0x00471090
TEXT_MODULE_GET = 0x004710D0
TEXT_STRING = 0x00470FE0
TEXT_MODULE_OPEN = 0x00470B50
#: `(the site that pushes the slot, the slot, the site that pushes the name,
#: the name)`.  Slot 0 is the ViewPlayer's own bank -- `_ViewPlayers`, whose
#: header names Andreas Nitsche and October 1996 -- and slot 3 is `aMain`'s,
#: the shared one every network caption comes out of.
VIEW_PLAYER_MODULES = ((0x0047BCFD, 0, 0x0047BCF8, "txtmod_g.lcl"),
                       (0x00449CB7, 3, 0x00449CB2, "txtmod_h.lcl"))

#: Every string id the screen fetches, at the instruction that pushes it.
#: Eighteen sites, twenty ids -- the three of state 1 share one call.
VIEW_PLAYER_STRINGS = (
    (0x0047C37A, 26), (0x0047C37E, 25), (0x0047C382, 22),
    (0x0047C444, 20), (0x0047C469, 12), (0x0047C4D7, 132),
    (0x0047C505, 128), (0x0047C6A1, 125), (0x0047C719, 2),
    (0x0047C728, 128), (0x0047C812, 127), (0x0047C882, 125),
    (0x0047C8DB, 128), (0x0047C8E9, 126), (0x0047C959, 125),
    (0x0047CA11, 197), (0x0047CCB3, 128), (0x0047CCD5, 129),
    (0x0047CD8C, 196), (0x0047CDD8, 193),
)

#: The two waves the screen owns, by the name the cache writes them under.
VIEW_PLAYER_CUE_WAVE = "progress.wav"
VIEW_PLAYER_ALARM_WAVE = "alarm.wav"

#: The one call the three ids of state 1 share; each is pushed on its own arm
#: and every arm jumps here.
VIEW_PLAYER_STRING_JOIN = 0x0047C384

#: What those ids say, read back out of the two shipped banks.  This is the
#: half of the reading the disassembly cannot give: the ids alone would let a
#: document invent any meaning for them.
VIEW_PLAYER_CAPTIONS = {
    ("Txtmod_g.lcl", 12): "Turn",
    ("Txtmod_g.lcl", 20): "Prepare for battle",
    ("Txtmod_g.lcl", 22): "End of game",
    ("Txtmod_g.lcl", 25): "Mission completed",
    ("Txtmod_g.lcl", 26): "Mission failed",
    ("Txtmod_h.lcl", 125): "(Press left mouse button to continue)",
    ("Txtmod_h.lcl", 126): "Game stopped by",
    ("Txtmod_h.lcl", 127): "Game canceled by",
    ("Txtmod_h.lcl", 128): "Player",
    ("Txtmod_h.lcl", 129): "Waiting for",
    ("Txtmod_h.lcl", 132): "Scay'Ger (Computer)",
}

#: The four `wsprintf` templates the screen composes its lines with.
VIEW_PLAYER_FORMATS = ((0x0047C47B, "%s %d"), (0x0047C52E, "%s (%s %d)"),
                       (0x0047C747, "%s (%s %d) - %s"),
                       (0x0047CCEA, "%s %s (%s %d)"))

#: `aPrintLibText`, and the two centred lines state 0 puts in the window.
PRINT_TEXT = 0x00439610
VIEW_PLAYER_LINES = ((0x0047C5E7, 320, 0x0047C5DB, 190),
                     (0x0047C65B, 320, 0x0047C64F, 160))

#: `fcn.0043B740` -- `[0x00509EE8] & 0xFF`, the game mode.  1 is the
#: single-player campaign; 2 is the network game, which the captions of the
#: same screen name aloud.  3 and 4 are the other two multi-player forms and
#: are **UNVERIFIED**.
GAME_MODE_READ = 0x0043B740
GAME_MODE_WRITE = 0x0043B730
GAME_MODE = 0x00509EE8
NETWORK_MODE = 2

#: `fcn.0047D600`, the step that decides whose turn it is next, and the two
#: states it sets.  `push 2` immediately precedes `aAISystemControl`: **the
#: computer's turn is state 2**, and `fcn.0047C2C0` is passed to it as the
#: callback that draws every frame of it.
NEXT_PLAYER = (0x0047D600, 986)
WATCHED_STATE_PUSH = 0x0047D656
WATCHED_STATE = 2
AI_TURN_CALLBACK = 0x0047D68F
AI_TURN_CALL = 0x0047D6A0
AI_SYSTEM_CONTROL = 0x00409940

#: `fcn.0047DC60`, the hand-over, and its three state writes.  Its case 1 is
#: the one the alert hangs off.
HANDOVER = (0x0047DC60, 533)
HANDOVER_STATE_WRITES = ((0x0047DDD2, 3), (0x0047DDE5, 0), (0x0047DE3C, None))
#: The alarm's gate, instruction by instruction: the mode is read and compared
#: with 2, the turn counter must be non-zero, and only then is the second
#: buffer handed to `aDirectSoundPlay`.
ALARM_MODE_CALL = 0x0047DDEF
ALARM_MODE_CMP = 0x0047DDF4
ALARM_TURN_CALL = 0x0047DDF9
ALARM_HANDLE_READ = 0x0047DE02
ALARM_PLAY = 0x0047DE0B
VIEW_PLAYER_ALARM_NAME = 0x0047C08C           # push "alarm.wav"
VIEW_PLAYER_ALARM_HANDLE_PUSH = 0x0047C09C    # push &0x00522E14
VIEW_PLAYER_ALARM = 0x00522E14
DIRECT_SOUND_PLAY = 0x00436EF0
#: And the bar's own play site, with the compare that silences an unchanged
#: fill two instructions above it.
PROGRESS_PLAY_GATE = 0x0047DA61
PROGRESS_PLAY = 0x0047DA6B

#: State 3 -- a network peer is moving -- draws the battle map and the ground
#: overlay and prints one caption over it; state 2, the computer's turn, draws
#: the map through `fcn.00417E10` and prints **nothing at all**.
PEER_ARM = 0x0047CBD2
PEER_OVERLAY_CALL = 0x0047CC8E
PEER_CAPTION_ORIGIN = (0x0047CD61, 54)
WATCHED_ARM = (0x0047CF5D, 0x0047D016)
WATCHED_MAP_CALL = 0x0047D009
BATTLE_MAP_DRAW = 0x00417E10
NETWORK_ONLY_GATE = 0x0047C98D
#: The peer caption's colour is picked per side out of a four-arm switch and
#: packed as RGB565 -- red in bits 11..15, green in 5..10, blue in 0..4.
CAPTION_COLOUR_SWITCH = 0x0047CD04
CAPTION_COLOUR_TABLE = 0x0047D080
CAPTION_COLOUR_ARMS = (0x0047CD0B, 0x0047CD33, 0x0047CD19, 0x0047CD25)
CAPTION_COLOUR_PACK = 0x0047CD3F

#: Mode 1 -- a mission played alone -- takes its own arm of state 0 and leaves
#: the player's line empty, so neither *Player N* nor *Scay'Ger (Computer)* is
#: reachable there; and the pause dismisses itself by posting `WM_LBUTTONDOWN`
#: to the game's own window when there is exactly one player.
SOLO_LINE_BRANCH = 0x0047C48E
SOLO_LINE_ARM = 0x0047C549
SOLO_DISMISS_PUSH = 0x0047C41F
WM_LBUTTONDOWN = 0x201

TEXT_BANKS = {"Txtmod_h.lcl": list(range(20, 47)) + list(range(50, 59))
              + [70, 71, 72, 73],
              "Txtmod_g.lcl": [11, 12, 13]}

# --------------------------------------------------------------------------
# The plate, measured
# --------------------------------------------------------------------------

PLATE_SIZE = (640, 480)
#: Mean luminance below this is "the dark inside of a socket or the inset".
DARK = 40
#: The window hole is darker still -- the plate paints a texture in it that
#: the engine overwrites, and it never reaches the frame's brightness.
WINDOW_MAX_MEAN = 15
FRAME_MIN_MEAN = 18
PLATE_FEATURES = {
    #: Dark runs across the pad at y 443..463 (three sockets) and down it at
    #: x 410..425 (two rows); the click grid is (404, 382) by (30, 48).
    "pad_socket_columns": [[401, 428], [430, 458], [460, 487]],
    "pad_socket_rows": [[377, 413], [425, 460]],
    #: The slot interiors of the two button columns at y 70..90.
    "column_slot_x": [[17, 40], [600, 623]],
    #: The turn window at the top right: dark columns at rows 12..26.
    "turn_window_x": [525, 590],
    "turn_window_y": [7, 24],
    #: The unit panel's dark inset: columns at y 400..460, rows at x 100..300.
    "inset_x": [42, 397],
    "inset_y": [378, 462],
    #: The radar screen: the green bounding box inside the bottom-right block.
    #: A hair inside the engine's clip (501, 389, 90, 66).
    "radar_screen": [503, 392, 89, 63],
}
#: How the remake cuts the plate (docs/43 §8).  A `fixed` piece keeps its
#: pixel size at the canvas scale and sits at its corner; a `band` is drawn in
#: place and tiled across whatever width the canvas has beyond 640; a `filler`
#: is a slice of the column tiled down whatever height it has beyond 480.
#: Each entry is `(name, x, y, w, h, anchor, kind)`.
PLATE_SEGMENTS = [
    ("top_left", 0, 0, 200, 34, "top_left", "fixed"),
    ("top_band", 200, 0, 64, 34, "top_left", "band"),
    ("top_right", 264, 0, 376, 34, "top_right", "fixed"),
    ("left_column", 0, 34, 60, 340, "top_left", "fixed"),
    ("left_filler", 0, 205, 60, 1, "top_left", "filler"),
    ("right_column", 580, 34, 60, 340, "top_right", "fixed"),
    ("right_filler", 580, 205, 60, 1, "top_right", "filler"),
    ("bottom_left", 0, 374, 300, 106, "bottom_left", "fixed"),
    ("bottom_band", 300, 374, 40, 106, "bottom_left", "band"),
    ("bottom_right", 340, 374, 300, 106, "bottom_right", "fixed"),
]


# --------------------------------------------------------------------------
# Byte helpers
# --------------------------------------------------------------------------

def mov_store_imm32(pe: PEFile, va: int) -> int | None:
    """Immediate of `mov dword [ebp+d8|esp+d8|abs32], imm32` at `va`."""
    if pe.u8(va) != 0xC7:
        return None
    modrm = pe.u8(va + 1)
    if modrm == 0x45:
        return pe.u32(va + 3)
    if modrm == 0x44 and pe.u8(va + 2) == 0x24:
        return pe.u32(va + 4)
    if modrm == 0x05:
        return pe.u32(va + 6)
    return None


def cmp_imm(pe: PEFile, va: int) -> int | None:
    """Immediate of a `cmp` at `va` in the encodings the routines use."""
    op = pe.u8(va)
    if op == 0x3C:                                  # cmp al, ib
        return pe.u8(va + 1)
    if op == 0x3D:                                  # cmp eax, id
        return pe.u32(va + 1)
    if op == 0x80:                                  # cmp r/m8, ib
        modrm = pe.u8(va + 1)
        if modrm & 0xC0 == 0xC0:
            return pe.u8(va + 2)
        if modrm & 0xC7 == 0x04:                    # SIB
            return pe.u8(va + 3 + (4 if modrm & 0xC0 == 0x80 else
                                   1 if modrm & 0xC0 == 0x40 else 0))
        if modrm & 0xC0 == 0x40:
            return pe.u8(va + 3)
        if modrm & 0xC0 == 0x00:
            return pe.u8(va + 2)
    if op == 0x83:                                  # cmp r/m32, ib
        modrm = pe.u8(va + 1)
        if modrm & 0xC0 == 0xC0:
            return pe.u8(va + 2)
        if modrm == 0x7C and pe.u8(va + 2) == 0x24:
            return pe.u8(va + 4)
        if modrm & 0xC0 == 0x40:
            return pe.u8(va + 3)
    if op == 0x81:                                  # cmp r/m32, id
        modrm = pe.u8(va + 1)
        if modrm & 0xC0 == 0xC0:
            return pe.u32(va + 2)
        if modrm == 0x7C and pe.u8(va + 2) == 0x24:
            return pe.u32(va + 4)
        if modrm & 0xC0 == 0x40:
            return pe.u32(va + 3)
    return None


def u16(pe: PEFile, va: int) -> int:
    """A little-endian word; `PEFile` reads bytes, dwords and doubles only."""
    return int.from_bytes(pe.bytes_at(va, 2), "little")


def mov_store_imm16(pe: PEFile, va: int) -> tuple[int, int] | None:
    """`(target, immediate)` of `mov word [abs32], imm16` at *va*."""
    if pe.bytes_at(va, 3) != b"\x66\xC7\x05":
        return None
    return pe.u32(va + 3), u16(pe, va + 7)


def mov_store_word_target(pe: PEFile, va: int) -> int | None:
    """Target of a 16-bit store to an absolute address at *va*.

    Two encodings: `66 89 /r` with a `disp32` mod-r/m, and `66 A3 disp32`,
    the short form the assembler picks for `ax`.
    """
    if pe.bytes_at(va, 2) == b"\x66\xA3":
        return pe.u32(va + 2)
    if pe.bytes_at(va, 2) != b"\x66\x89":
        return None
    if pe.u8(va + 2) & 0xC7 != 0x05:
        return None
    return pe.u32(va + 3)


def branch_target(pe: PEFile, va: int) -> int | None:
    """Target of a near `call` or `jmp` at *va*; both are rel32."""
    if pe.u8(va) not in (0xE8, 0xE9):
        return None
    return (va + 5 + pe.i32(va + 1)) & 0xFFFFFFFF


def push_imm(pe: PEFile, va: int) -> int | None:
    op = pe.u8(va)
    if op == 0x6A:
        return pe.u8(va + 1)
    if op == 0x68:
        return pe.u32(va + 1)
    return None


def signed8(value: int) -> int:
    return value - 256 if value >= 128 else value


def table(pe: PEFile, va: int, count: int) -> list[int]:
    return [pe.u32(va + 4 * i) for i in range(count)]


def reg_imm32_values(pe: PEFile, va: int, size: int, opcode: int) -> list[int]:
    """Every `mov r32, imm32` of one register (opcode B8+r) in a byte window.

    A byte-wise scan, not a disassembly: it can only add values, never lose
    one, so a caller checks that the expected value is *among* them.
    """
    data = pe.bytes_at(va, size)
    return [int.from_bytes(data[i + 1:i + 5], "little")
            for i in range(len(data) - 4) if data[i] == opcode]


def push_imm8_values(pe: PEFile, va: int, size: int) -> list[int]:
    data = pe.bytes_at(va, size)
    return [data[i + 1] for i in range(len(data) - 1) if data[i] == 0x6A]


def contains(pe: PEFile, va: int, size: int, needle: bytes) -> bool:
    return needle in pe.bytes_at(va, size)


def cstring_pushes(pe: PEFile, va: int, size: int) -> set[str]:
    """Lower-cased C strings pushed as `push imm32` inside a routine."""
    data = pe.bytes_at(va, size)
    names: set[str] = set()
    for i in range(len(data) - 4):
        if data[i] != 0x68:
            continue
        target = int.from_bytes(data[i + 1:i + 5], "little")
        if pe.va_to_off(target) is None:
            continue
        text = pe.cstring(target, 64)
        if text and text.isprintable():
            names.add(text.lower())
    return names


# --------------------------------------------------------------------------
# The plate, measured
# --------------------------------------------------------------------------

def luminance_rows(image: bmp.Image, x0: int, x1: int) -> list[float]:
    pal = image.palette
    width = image.width
    return [sum(sum(pal[image.pixels[y * width + x]]) / 3
                for x in range(x0, x1)) / (x1 - x0)
            for y in range(image.height)]


def luminance_columns(image: bmp.Image, y0: int, y1: int) -> list[float]:
    pal = image.palette
    width = image.width
    return [sum(sum(pal[image.pixels[y * width + x]]) / 3
                for y in range(y0, y1)) / (y1 - y0)
            for x in range(image.width)]


def dark_runs(values: list[float], threshold: float,
              min_len: int = 4) -> list[list[int]]:
    runs: list[list[int]] = []
    start: int | None = None
    for i, value in enumerate(values):
        if value < threshold and start is None:
            start = i
        elif value >= threshold and start is not None:
            if i - start > min_len:
                runs.append([start, i - 1])
            start = None
    if start is not None and len(values) - start > min_len:
        runs.append([start, len(values) - 1])
    return runs


def mean_luminance(image: bmp.Image, x0: int, y0: int, w: int, h: int) -> float:
    pal = image.palette
    width = image.width
    total = 0.0
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            total += sum(pal[image.pixels[y * width + x]]) / 3
    return total / (w * h)


def green_box(image: bmp.Image, x0: int, y0: int, x1: int, y1: int
              ) -> list[int] | None:
    pal = image.palette
    width = image.width
    xs: list[int] = []
    ys: list[int] = []
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = pal[image.pixels[y * width + x]]
            if g > r + 25 and g > b + 15:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return [min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1]


def measure_plate(image: bmp.Image) -> dict:
    """Every feature of `PLATE_FEATURES`, read off the pixels."""
    within = lambda runs, lo, hi: [r for r in runs if lo <= r[0] and r[1] <= hi]
    pad_cols = luminance_columns(image, 443, 463)
    pad_rows = luminance_rows(image, 410, 425)
    slot_cols = luminance_columns(image, 70, 90)
    top_cols = luminance_columns(image, 12, 26)
    top_rows = luminance_rows(image, 540, 600)
    inset_cols = luminance_columns(image, 400, 460)
    inset_rows = luminance_rows(image, 100, 300)
    return {
        "pad_socket_columns": within(dark_runs(pad_cols, DARK), 395, 500),
        "pad_socket_rows": within(dark_runs(pad_rows, DARK), 375, 462),
        "column_slot_x": [r for r in within(dark_runs(slot_cols, DARK), 11, 49)
                          + within(dark_runs(slot_cols, DARK), 594, 632)
                          if r[1] - r[0] > 10],
        "turn_window_x": next(iter(within(dark_runs(top_cols, DARK), 520,
                                          600)), None),
        "turn_window_y": next(iter([r for r in dark_runs(top_rows, DARK)
                                    if r[1] - r[0] > 10]), None),
        "inset_x": next(iter(within(dark_runs(inset_cols, 45), 40, 400)),
                        None),
        "inset_y": next(iter([r for r in dark_runs(inset_rows, 45)
                              if r[0] >= WINDOW[1] + WINDOW[3]]), None),
        "radar_screen": green_box(image, 495, 380, 600, 470),
    }


def segments_cover(segments: list[tuple]) -> bool:
    """The fixed pieces and the bands tile the frame around the window exactly
    once; every filler lies inside a fixed piece."""
    placed = [s for s in segments if s[6] in ("fixed", "band")]
    fixed = [s for s in segments if s[6] == "fixed"]
    for _name, x, y, w, h, _anchor, kind in segments:
        if kind == "filler" and not any(
                f[1] <= x and x + w <= f[1] + f[3] and f[2] <= y
                and y + h <= f[2] + f[4] for f in fixed):
            return False
    covered = [[False] * PLATE_SIZE[0] for _ in range(PLATE_SIZE[1])]
    for _name, x, y, w, h, _anchor, _kind in placed:
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                if covered[yy][xx]:
                    return False
                covered[yy][xx] = True
    window_x0, window_y0, window_w, window_h = WINDOW
    for yy in range(PLATE_SIZE[1]):
        for xx in range(PLATE_SIZE[0]):
            inside = (window_x0 <= xx < window_x0 + window_w
                      and window_y0 <= yy < window_y0 + window_h)
            if covered[yy][xx] == inside:
                return False
    return True


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def check_overlay(ck: Checker, pe: PEFile) -> None:
    ck.equal("overlay.arm_table", table(pe, ARM_TABLE, ARM_COUNT), ARMS,
             "16 arms at 0x00418E68")
    state_map = list(pe.bytes_at(STATE_MAP, STATE_MAP_LEN))
    want = [15] * STATE_MAP_LEN
    for state, arm in STATE_TO_ARM.items():
        want[state - 1] = arm
    want[0] = 0
    ck.equal("overlay.state_map", state_map, want,
             "state-1 -> arm; 15 draws nothing")
    ck.equal("overlay.arm_mp1_elements",
             {hex(va): pe.u32(va + 1) if pe.u8(va) == 0xBF else None
              for va in ARM_MP1_IMM},
             {hex(va): element for va, element in ARM_MP1_IMM.items()},
             "mov edi, element (mp1)")
    ck.equal("overlay.arm_mp_elements",
             {hex(va): mov_store_imm32(pe, va) for va in ARM_MP_IMM},
             {hex(va): element for va, element in ARM_MP_IMM.items()},
             "mov [ebp-0x10], element (mp)")
    ck.check("overlay.arm_hover_gate",
             all(pe.bytes_at(va, 7) == b"\x8B\x44\x24\x2C\x85\xC0\x74"
                 for va in ARM_HOVER_GATE),
             "states 10 and 60 draw only while the hover cell is legal")
    ck.check("overlay.arm_digit", pe.bytes_at(ARM_DIGIT_LOAD, 3) == b"\x8A\x56\x0C",
             "state 10 blits mp1[cell+0x0C]")
    ck.equal("overlay.hover_states",
             (cmp_imm(pe, HOVER_STATE_REACHABLE), cmp_imm(pe, HOVER_STATE_WARP),
              mov_store_imm32(pe, HOVER_LEGAL_STORE)), (10, 60, 1),
             "the hover cell is legal in state 10 or 60")
    ck.check("overlay.hover_blink",
             pe.bytes_at(HOVER_BLINK_TEST, 7) == b"\xF6\x05\x68\x30\x52\x00\x01"
             and mov_store_imm32(pe, HOVER_FRAME_STORE) == UNIT_MARKERS["hover_frame"],
             "blink on tick bit 0; frame mp[48]")
    ck.equal("overlay.zoom_gate",
             (cmp_imm(pe, VP_ZOOM_GATE), cmp_imm(pe, FAR_ZOOM_GATE)),
             (ZOOM_GATE, ZOOM_GATE), "camera z >= 0x17700 is the far view")
    ck.check("overlay.vp_letters", pe.bytes_at(VP_LETTER_BASE, 3) == b"\x83\xE8\x3F",
             "action point 80..89 -> mp[17..26]")
    ck.check("overlay.far_blink",
             pe.bytes_at(FAR_BLINK_TEST, 7) == b"\xF6\x05\x64\xE2\x4F\x00\x01",
             "far markers blink on the draw counter")
    ck.equal("overlay.unit_markers", {
        "hp_cap": [cmp_imm(pe, va) for va in UNIT_HP_CAP]
        + [mov_store_imm32(pe, UNIT_HP_CAP_STORE)],
        "path": [reg_imm32_values(pe, UNIT_PATH_FRAME, 5, 0xB8),
                 mov_store_imm32(pe, UNIT_PATH_ALT)],
        "defending": [pe.bytes_at(UNIT_DEFENDING_TEST, 4),
                      mov_store_imm32(pe, UNIT_DEFENDING_SPRITE)],
        "malfunction": mov_store_imm32(pe, UNIT_MALFUNCTION_SPRITE),
        "panic": [pe.bytes_at(UNIT_PANIC_TEST, 4),
                  mov_store_imm32(pe, UNIT_PANIC_SPRITE)],
    }, {
        "hp_cap": [15, 15, 15],
        "path": [[51], 52],
        "defending": [b"\x80\x7E\x41\x01", 49],
        "malfunction": 50,
        "panic": [b"\x80\x7E\x41\x05", 54],
    }, "HP digit <= 15, path frames 51/52, +0x41==1 -> 49, +0x40 -> 50, +0x41==5 -> 54")
    ck.check("overlay.path_blink",
             pe.bytes_at(UNIT_PATH_BLINK, 7) == b"\xF6\x05\x68\x30\x52\x00\x01",
             "a unit on its path blinks the frame on the tick")
    check_path_marks(ck, pe)


def calls_between(pe: PEFile, start: int, end: int, target: int) -> list[int]:
    """Every `E8 rel32` in [start, end) that reaches *target*.

    A byte scan, so it may read an immediate as an opcode -- which can only
    add a call, never hide one, and the checks below ask for emptiness.
    """
    return [va for va in range(start, end)
            if pe.u8(va) == 0xE8 and call_target(pe, va) == target]


def image_hits(pe: PEFile, needle: bytes) -> list[int]:
    """Every virtual address in `.text` holding *needle*."""
    base, size, raw, _rawsize = pe.section(".text")
    body = pe.data[raw:raw + size]
    out: list[int] = []
    at = body.find(needle)
    while at >= 0:
        out.append(base + at)
        at = body.find(needle, at + 1)
    return out


def direct_calls(pe: PEFile) -> list[tuple[int, int]]:
    """Every `E8 rel32` in `.text` as `(site, target)`, targets in `.text`.

    A linear byte sweep, so an immediate that happens to read as `E8` adds an
    edge; it never hides one. Both readers below want that direction -- one
    asks for an exact caller set and would fail loudly on a stray edge, the
    other asks whether a target is **un**reachable, which extra edges can
    only make harder to claim.
    """
    base, size, raw, _rawsize = pe.section(".text")
    body = pe.data[raw:raw + size]
    out: list[tuple[int, int]] = []
    at = body.find(b"\xE8")
    while at >= 0:
        if at + 5 <= len(body):
            site = base + at
            target = site + 5 + int.from_bytes(body[at + 1:at + 5],
                                               "little", signed=True)
            if base <= target < base + size:
                out.append((site, target))
        at = body.find(b"\xE8", at + 1)
    return out


def all_calls_to(pe: PEFile, target: int) -> list[int]:
    """Every `E8 rel32` in `.text` that reaches *target*."""
    return [site for site, to in direct_calls(pe) if to == target]


def check_path_marks(ck: Checker, pe: PEFile) -> None:
    """Cell state 100 is written by every move and drawn by none.

    docs/43 section 3.1 said it was the computer's own path, on a reading that
    made `fcn.0047DE90` the AI's command dispatcher. It is the network's, and
    the second writer is the player's own move command, so the state belongs
    to both sides -- and neither shows it while a body walks.
    """
    ck.equal("path.both_movers_mark",
             [call_target(pe, AI_MOVE_MARK), call_target(pe, UI_MOVE_MARK)],
             [WALK_MOVE_MAP, WALK_MOVE_MAP],
             "aWalkMoveMap's two call sites: the AI's mover and aUI.cpp's")
    ck.equal("path.both_movers_walk",
             [call_target(pe, AI_MOVE_WALK), call_target(pe, UI_MOVE_WALK)],
             [EXECUTE_MOVE, EXECUTE_MOVE],
             "and both go straight on to aExecuteMove")
    ck.equal("path.the_ai_does_not_redraw",
             calls_between(pe, AI_MOVE_MARK, AI_MOVE_WALK, HUD_REDRAW)
             + calls_between(pe, AI_MOVE_MARK, AI_MOVE_WALK, GROUND_OVERLAY),
             [], "nothing draws between the computer's mark and its walk")
    ck.equal("path.the_player_redraws_before_the_walk",
             [call_target(pe, va) for va in UI_MOVE_REDRAW]
             + [va < UI_MOVE_WALK for va in UI_MOVE_REDRAW],
             [HUD_REDRAW, HUD_REDRAW, True, True],
             "the player's mark is painted once, and before aExecuteMove")
    ck.check("path.the_walk_never_reblits",
             not [site for site in all_calls_to(pe, GROUND_OVERLAY)
                  if EXECUTE_MOVE <= site < EXECUTE_MOVE + EXECUTE_MOVE_SIZE]
             and not [site for site in all_calls_to(pe, HUD_REDRAW)
                      if EXECUTE_MOVE <= site
                      < EXECUTE_MOVE + EXECUTE_MOVE_SIZE],
             "no redraw is called from inside aExecuteMove")
    ck.equal("path.the_second_dispatcher_is_the_network",
             [call_target(pe, NET_MODE_READ), cmp_imm(pe, NET_MODE_CMP),
              pe.bytes_at(NET_MODE_CMP + 3, 2), call_target(pe, NET_DISPATCH),
              call_target(pe, NET_MOVE)],
             [GAME_MODE_READ, NETWORK_MODE, b"\x0F\x85", 0x0047DE90,
              0x00472D40],
             "fcn.0047DE90 runs only with the mode global at 2")
    ck.equal("path.the_callback_is_handed_over_once",
             [pe.bytes_at(FRAME_ROUTINE_PUSH, 5),
              image_hits(pe, FRAME_ROUTINE.to_bytes(4, "little"))],
             [b"\x68" + FRAME_ROUTINE.to_bytes(4, "little"),
              [FRAME_ROUTINE_PUSH + 1]],
             "fcn.0047C2C0's address is written once, as fcn.0047D600's push")
    ck.equal("path.the_callback_lives_in_the_ai_system",
             [pe.bytes_at(CALLBACK_STORE, 6),
              [pe.bytes_at(va, 6) for va in CALLBACK_CALLS],
              all(AI_SYSTEM_CONTROL <= va
                  < AI_SYSTEM_CONTROL + AI_SYSTEM_CONTROL_SIZE
                  for va in image_hits(
                      pe, CALLBACK_GLOBAL.to_bytes(4, "little")))],
             [b"\x89\x35" + CALLBACK_GLOBAL.to_bytes(4, "little"),
              [b"\xFF\x15" + CALLBACK_GLOBAL.to_bytes(4, "little")] * 3,
              True],
             "stored and called only inside aAISystemControl")
    ck.equal("path.the_overlay_has_four_callers",
             sorted(all_calls_to(pe, GROUND_OVERLAY)),
             sorted(OVERLAY_CALL_SITES),
             "the HUD redraw, aMissionControl twice, and the frame routine")
    ck.check("path.the_mode_global",
             pe.bytes_at(GAME_MODE_READ, 5)
             == b"\xA1" + GAME_MODE_GLOBAL.to_bytes(4, "little"),
             "fcn.0043B740 is a read of [0x00509EE8]")


def check_progress(ck: Checker, pe: PEFile) -> None:
    """The watched player's progress bar -- `aViewPlayer.cpp`, docs/43 section 7.

    A computer or network turn is drawn by `fcn.0047C2C0`, and what it puts
    over the plate is not the battle interface: `aInitViewPlayer` loads
    `plate_5.bmp` whole and `fcn.0047D090` blits it back, so no column icon,
    no pad face and no panel is on screen while another player moves. The one
    thing drawn on top is `fcn.0047DA00`'s bar of twenty-two `vp.LIB` capsules.
    """
    ck.equal("progress.library",
             [pe.cstring(push_imm(pe, VIEW_PLAYER_LIB_NAME) or 0, 32),
              push_imm(pe, VIEW_PLAYER_LIB_HANDLE)],
             ["vp.lib", VIEW_PLAYER_LIB],
             "aInitViewPlayer loads vp.lib into 0x00522A04")
    ck.check("progress.bare_plate",
             pe.cstring(push_imm(pe, VIEW_PLAYER_PLATE) or 0, 32).lower()
             == "gui\\plate_5.bmp",
             "and the whole plate into a bitmap of its own -- the icons go")
    ck.equal("progress.sound",
             [pe.cstring(push_imm(pe, VIEW_PLAYER_SOUND_NAME) or 0, 32),
              push_imm(pe, VIEW_PLAYER_SOUND_HANDLE)],
             ["progress.wav", VIEW_PLAYER_SOUND],
             "progress.wav is the click a step of the bar makes")
    ck.equal("progress.four_strips",
             [call_target(pe, va) for va in VIEW_PLAYER_STRIPS]
             + [push_imm(pe, va) for va, _rows in VIEW_PLAYER_STRIP_ROWS],
             [STRIP_COPY] * 4 + [rows for _va, rows in VIEW_PLAYER_STRIP_ROWS],
             "top 34, bottom 106 and both columns 340 -- the whole interface")
    ck.equal("progress.both_buffers",
             [call_target(pe, va) for va in VIEW_PLAYER_FRAME_CALLS],
             [VIEW_PLAYER_FRAME, VIEW_PLAYER_FRAME],
             "the watcher's frame is drawn once per buffer")
    ck.equal("progress.is_drawn_by_the_watcher",
             [call_target(pe, PROGRESS_CALL), call_target(pe, PROGRESS_PLAYER)],
             [PROGRESS_BAR[0], CURRENT_PLAYER_READ],
             "fcn.0047D090 draws it for the seat 0x00509E32 names")
    ck.equal("progress.gates",
             [call_target(pe, PROGRESS_GATE_TURN),
              call_target(pe, PROGRESS_GATE_SEAT)],
             [TURN_COUNTER_READ, SEAT_READ],
             "nothing before the first hand-over, nothing in a hot seat")
    ck.equal("progress.counts",
             [call_target(pe, PROGRESS_LIVE_CALL),
              call_target(pe, PROGRESS_ACTED_CALL)],
             [COUNT_LIVE, COUNT_ACTED],
             "the live units divide, the ones that spent movement multiply")
    ck.check("progress.live_predicate",
             call_target(pe, COUNT_LIVE + 2) == UNIT_ARRAY_BASE
             and contains(pe, COUNT_LIVE, 48, b"\x8A\x51\xD1")
             and contains(pe, COUNT_LIVE, 48,
                          b"\x83\xC1" + bytes([UNIT_STRIDE]))
             and pe.u8(COUNT_LIVE + 0x10) == 0xB8
             and pe.u32(COUNT_LIVE + 0x11) == UNIT_COUNT,
             "alive at +0x16 and owned at +0x45, 200 records of 91 bytes")
    ck.check("progress.acted_predicate",
             call_target(pe, COUNT_ACTED + 4) == UNIT_ARRAY_BASE
             and contains(pe, COUNT_ACTED, 68, b"\x8A\x46\x16")
             and contains(pe, COUNT_ACTED, 68, b"\x8A\x46\x45")
             and contains(pe, COUNT_ACTED, 68, b"\x8A\x4E\x15")
             and any(call_target(pe, COUNT_ACTED + i) == ALLOWANCE
                     for i in range(68))
             and pe.u8(COUNT_ACTED + 0x11) == 0xBF
             and pe.u32(COUNT_ACTED + 0x12) == UNIT_COUNT,
             "and +0x15 read back against 0x00475160's own allowance")
    ck.check("progress.scale",
             pe.bytes_at(PROGRESS_SCALE, 8)
             == b"\xC1\xE1\x03\x2B\xC8\x8D\x04\x49"
             and pe.bytes_at(PROGRESS_DIV, 2) == b"\xF7\xF7",
             "fill = acted * 21 / live, in that order")
    ck.check("progress.previous",
             mov_store_imm32(pe, VIEW_PLAYER_PREV_RESET) == 0
             and pe.u32(VIEW_PLAYER_PREV_RESET + 2) == PROGRESS_PREV,
             "0x00522E18 keeps last frame's fill and is zeroed once, at init")
    ck.equal("progress.geometry",
             [pe.u32(PROGRESS_X[0] + 1), pe.u8(PROGRESS_X[1] + 2),
              push_imm(pe, PROGRESS_Y[0]), push_imm(pe, PROGRESS_Y[1])],
             [PROGRESS_ORIGIN_X, PROGRESS_ORIGIN_X,
              PROGRESS_ORIGIN_Y, PROGRESS_ORIGIN_Y],
             "both runs start at x 59 and blit on row 406")
    ck.equal("progress.segments",
             [pe.u8(PROGRESS_LIMIT + 2), pe.u32(PROGRESS_SEGMENTS_AT + 1)],
             [PROGRESS_SEGMENTS - 1, PROGRESS_SEGMENTS],
             "twenty-two capsules; the dark run is skipped past twenty-one")
    ck.equal("progress.elements",
             [push_imm(pe, PROGRESS_ELEMENTS[0]),
              push_imm(pe, PROGRESS_ELEMENTS[1])],
             [0, 1], "element 0 is lit, element 1 is not")
    ck.check("progress.step",
             call_target(pe, PROGRESS_WIDTH_CALL) == ELEMENT_WIDTH
             and pe.bytes_at(ELEMENT_WIDTH + 0x12, 4) == b"\x8B\x44\x91\x04",
             "the step between capsules is element 0's own width")
    ck.equal("progress.blits",
             [call_target(pe, va) for va in PROGRESS_BLITS]
             + [any(call_target(pe, PROGRESS_BAR[0] + i) == ANCHOR_X
                    for i in range(PROGRESS_BAR[1]))],
             [BLITTER, BLITTER, False],
             "one blitter for both runs, and no anchor is subtracted")


def check_selection(ck: Checker, pe: PEFile) -> None:
    """The selection is a global the hand-over does not touch -- docs/43 §4.5.

    Reported as "after the computer's turn the original has one of my soldiers
    selected and the remake has nobody".  It is not a hand-over routine: the
    slot lives in `[0x005162F0]`, nothing on the turn's path writes it, and
    anything that asks to move a selection that is not there takes
    `fcn.00477CE0`'s first unit instead.
    """
    ck.equal("selection.cleared_by_an_immediate",
             [mov_store_imm16(pe, va) for va in SELECTION_CLEAR_IMM],
             [(SELECTION, SELECTION_NONE)] * 2,
             "init and the empty side write 0xFFFF straight in")
    ck.check("selection.cleared_by_the_command_tail",
             mov_store_word_target(pe, SELECTION_CLEAR_REG) == SELECTION
             and pe.u8(COMMAND_TAIL_SENTINEL) == 0xB9
             and pe.u32(COMMAND_TAIL_SENTINEL + 1) == SELECTION_NONE
             and all(call_target(pe, va) == COMMAND_TAIL
                     for va in COMMAND_TAIL_CALLERS),
             "and fcn.00472CC0 clears it out of cx after every command")
    ck.check("selection.is_a_word",
             all(mov_store_word_target(pe, va) == SELECTION
                 for va, want in SELECTION_WRITES if want is None),
             "the two that select a unit write the same word")
    va, size, _raw, _rawsize = pe.section(".text")
    ck.equal("selection.reference_count",
             pe.bytes_at(va, size).count(SELECTION.to_bytes(4, "little")),
             SELECTION_REFERENCES,
             "five writes and two reads name it, and nothing else does")
    ck.check("selection.cleared_once_at_init",
             call_target(pe, SELECTION_RESET_CALL) == SELECTION_RESET
             and BATTLE_GROUND_INIT < SELECTION_RESET_CALL,
             "aInitBattleGround is the only caller of the reset")
    ck.check("selection.empty_takes_the_first",
             pe.bytes_at(MOVE_SELECTION_EMPTY_TEST, 3) == b"\x66\x81\x3D"
             and pe.u32(MOVE_SELECTION_EMPTY_TEST + 3) == SELECTION
             and u16(pe, MOVE_SELECTION_EMPTY_TEST + 7) == SELECTION_NONE
             and call_target(pe, MOVE_SELECTION_FIRST_CALL) == FIRST_UNIT,
             "0x004721F0 fills an empty selection before it reads its mode")
    ck.equal("selection.modes",
             [call_target(pe, va) for va, _t in MOVE_SELECTION_MODES],
             [t for _va, t in MOVE_SELECTION_MODES],
             "mode 0 and mode 1 are the two searches")
    ck.equal("selection.entry_gates",
             [call_target(pe, va) for va, _t in SELECT_ENTRY_GATES],
             [t for _va, t in SELECT_ENTRY_GATES],
             "nothing before the first hand-over, nothing for an empty side")
    ck.check("selection.entry_calls_the_mover",
             call_target(pe, SELECT_ENTRY_CALL) == MOVE_SELECTION,
             "fcn.00471E00 is the door every caller uses")
    ck.check("selection.first_turn_asks_for_one",
             push_imm(pe, SELECT_AT_START[0]) == SELECT_AT_START[1]
             and call_target(pe, SELECT_AT_START[0] + 2) == SELECT_ENTRY,
             "aInitBattleGround asks for a selection once, with mode 1")
    ck.check("selection.the_script_can_ask_too",
             push_imm(pe, SCRIPT_SELECT_NEXT_MODE) == 0
             and call_target(pe, SCRIPT_SELECT_NEXT_CALL) == SELECT_ENTRY
             and pe.cstring(SCRIPT_SELECT_NEXT_NAME, 32) == "SelectNextUnit",
             "SelectNextUnit is the other caller, and no shipped script uses it")
    ck.check("selection.first_unit_two_passes",
             pe.bytes_at(FIRST_UNIT_PASSES[0], 3) == b"\x8A\x51\xD1"
             and pe.bytes_at(FIRST_UNIT_PASSES[1], 3) == b"\x8A\x51\xD1"
             and pe.bytes_at(FIRST_UNIT_MOVEMENT_TEST, 3) == b"\x8A\x51\xD0"
             and not contains(pe, FIRST_UNIT_PASSES[1],
                              FIRST_UNIT_NONE - FIRST_UNIT_PASSES[1],
                              b"\x8A\x51\xD0"),
             "the second pass drops the +0x15 test the first one makes")
    ck.check("selection.first_unit_answers_none",
             pe.u8(FIRST_UNIT_NONE) == 0xB8
             and pe.u32(FIRST_UNIT_NONE + 1) == SELECTION_NONE,
             "and a side with no live unit answers 0xFFFF")
    ck.equal("selection.view_modes",
             [pe.u32(VIEW_MODE + 0) if False else call_target(pe, va)
              for _mode, va in
              ((0, 0x004533EB), (1, 0x004533F6), (2, 0x00453401),
               (3, 0x004533E0))],
             [0x004510A0, 0x00451150, 0x00453410, 0x00450F60],
             "0x004533D0's cascade names one placer per view mode")
    ck.check("selection.view_reads_the_selection",
             pe.u32(VIEW_APPLY + 1) == VIEW_MODE
             and pe.u32(VIEW_SELECTION_READ + 3) == SELECTION_CURRENT
             and mov_store_word_target(pe, SELECT_CELL_WRITE)
             == SELECTION_CURRENT,
             "the placers take the cell fcn.00472990 left, not a camera global")
    ck.check("selection.the_camera_follows",
             all(branch_target(pe, va) == VIEW_APPLY
                 for va in VIEW_APPLY_AFTER_SELECT),
             f"{len(VIEW_APPLY_AFTER_SELECT)} callers re-apply the view after "
             "a select")
    ck.equal("selection.unit_view_is_8_7_0",
             [push_imm(pe, VIEW_UNIT_ARGS), push_imm(pe, VIEW_UNIT_ARGS + 2),
              call_target(pe, VIEW_UNIT_PLACE),
              mov_store_imm32(pe, VIEW_UNIT_MODE_WRITE),
              mov_store_imm32(pe, VIEW_DEFAULT_MODE)],
             [7, 8, 0x004529D0, 2, 2],
             "mode 2 is the default and places the camera at (8, 7, 0)")
    ck.check("selection.the_hand_over_leaves_it_alone",
             not any(pe.u8(NEXT_PLAYER[0] + i) == 0xE8
                     and call_target(pe, NEXT_PLAYER[0] + i)
                     in (SELECT_ENTRY, MOVE_SELECTION, SELECTION_RESET,
                         COMMAND_TAIL)
                     for i in range(NEXT_PLAYER[1]))
             and not any(pe.u8(HANDOVER[0] + i) == 0xE8
                         and call_target(pe, HANDOVER[0] + i)
                         in (SELECT_ENTRY, MOVE_SELECTION, SELECTION_RESET,
                             COMMAND_TAIL)
                         for i in range(HANDOVER[1])),
             "neither fcn.0047D600 nor fcn.0047DC60 touches the selection")


def check_view_player(ck: Checker, pe: PEFile, root: Path) -> None:
    """The watched player's screen itself -- `aViewPlayer.cpp`, docs/43 §7.3.

    The bar above is only what is drawn on top.  The screen under it is a
    whole game state with seven arms, two text banks and one alert, and the
    two facts a remake needs out of it are that **the computer's turn is state
    2 and prints nothing at all**, and that `alarm.wav` is the network game's
    "it is your turn" alert rather than anything a single-player mission can
    reach.
    """
    ck.equal("view_player.state",
             [pe.u32(VIEW_PLAYER_STATE_READ + 1),
              pe.u32(VIEW_PLAYER_STATE_WRITE + 5)],
             [VIEW_PLAYER_STATE, VIEW_PLAYER_STATE],
             "0x005229D4 is read by fcn.0047DBD0 and written by fcn.0047DBC0")
    ck.equal("view_player.state_arms",
             [pe.u32(VIEW_PLAYER_STATE_SWITCH + 4 * i)
              for i in range(len(VIEW_PLAYER_STATE_ARMS))],
             list(VIEW_PLAYER_STATE_ARMS),
             "seven arms, states 2..4 sharing an entry point")
    ck.check("view_player.state_is_the_index",
             pe.bytes_at(VIEW_PLAYER_STATE_DISPATCH, 3) == b"\xFF\x24\x85"
             and pe.u32(VIEW_PLAYER_STATE_DISPATCH + 3)
             == VIEW_PLAYER_STATE_SWITCH,
             "the switch is indexed by the state and by nothing else")
    ck.equal("view_player.modules",
             [(push_imm(pe, slot_at),
               pe.cstring(push_imm(pe, name_at) or 0, 32).lower())
              for slot_at, _slot, name_at, _name in VIEW_PLAYER_MODULES],
             [(slot, name) for _s, slot, _n, name in VIEW_PLAYER_MODULES],
             "txtmod_g into slot 0, txtmod_h into slot 3")
    ck.check("view_player.modules_are_opened",
             all(any(pe.u8(site + i) == 0xE8
                     and call_target(pe, site + i) == TEXT_MODULE_OPEN
                     for i in range(2, 24))
                 for site, _slot, _n, _name in VIEW_PLAYER_MODULES),
             "both slot pushes are arguments to aTxtSys's own open")
    ck.equal("view_player.string_ids",
             [push_imm(pe, va) for va, _id in VIEW_PLAYER_STRINGS],
             [ident for _va, ident in VIEW_PLAYER_STRINGS],
             f"{len(VIEW_PLAYER_STRINGS)} caption ids at their own pushes")
    reaches = []
    for va, _ident in VIEW_PLAYER_STRINGS:
        after = va + (2 if pe.u8(va) == 0x6A else 5)
        reaches.append(
            (pe.u8(after) == 0xE8 and call_target(pe, after) == TEXT_STRING)
            or (pe.u8(after) == 0xEB
                and after + 2 + signed8(pe.u8(after + 1))
                == VIEW_PLAYER_STRING_JOIN))
    ck.check("view_player.strings_are_fetched", all(reaches),
             "each id is the argument of aTxtSys's string fetch")
    ck.equal("view_player.formats",
             [pe.cstring(push_imm(pe, va) or 0, 32)
              for va, _text in VIEW_PLAYER_FORMATS],
             [text for _va, text in VIEW_PLAYER_FORMATS],
             "the four wsprintf templates the lines are composed with")
    ck.check("view_player.solo_prints_no_player",
             pe.bytes_at(SOLO_LINE_BRANCH, 2) == b"\x0F\x84"
             and SOLO_LINE_BRANCH + 6 + pe.u32(SOLO_LINE_BRANCH + 2)
             == SOLO_LINE_ARM
             and push_imm(pe, SOLO_DISMISS_PUSH) == WM_LBUTTONDOWN,
             "mode 1 takes its own arm and the pause clicks itself away")
    ck.equal("view_player.centred_lines",
             [(push_imm(pe, x_at), push_imm(pe, y_at))
              for x_at, _x, y_at, _y in VIEW_PLAYER_LINES],
             [(x, y) for _xa, x, _ya, y in VIEW_PLAYER_LINES],
             "state 0 centres its two lines at x 320, rows 190 and 160")

    # ---- the computer's turn is state 2, and it is silent ----------------
    ck.equal("view_player.watched_state",
             [push_imm(pe, WATCHED_STATE_PUSH),
              call_target(pe, WATCHED_STATE_PUSH + 2)],
             [WATCHED_STATE, VIEW_PLAYER_STATE_WRITE],
             "fcn.0047D600 sets state 2 before it runs the computer's turn")
    ck.equal("view_player.frame_is_the_ai_callback",
             [push_imm(pe, AI_TURN_CALLBACK), call_target(pe, AI_TURN_CALL)],
             [VIEW_PLAYER_SCREEN[0], AI_SYSTEM_CONTROL],
             "and hands this very screen to aAISystemControl as the callback")
    ck.check("view_player.watched_turn_draws_the_map",
             call_target(pe, WATCHED_MAP_CALL) == BATTLE_MAP_DRAW,
             "state 2 still draws the battle map under the bare plate")
    span = WATCHED_ARM[1] - WATCHED_ARM[0]
    ck.check("view_player.watched_turn_prints_nothing",
             not any(pe.u8(WATCHED_ARM[0] + i) == 0xE8
                     and call_target(pe, WATCHED_ARM[0] + i) == PRINT_TEXT
                     for i in range(span)),
             f"and no aPrintLibText in the {span} bytes of its arm")
    ck.check("view_player.captions_are_network_only",
             pe.bytes_at(NETWORK_ONLY_GATE, 2) == b"\x0F\x85"
             and pe.bytes_at(NETWORK_ONLY_GATE - 3, 3) == b"\x83\xF8"
             + bytes([NETWORK_MODE]),
             "the arm states 2..4 share leaves at once unless the mode is 2")
    ck.check("view_player.peer_turn_prints_one",
             call_target(pe, PEER_OVERLAY_CALL) == OVERLAY
             and push_imm(pe, PEER_CAPTION_ORIGIN[0])
             == PEER_CAPTION_ORIGIN[1],
             "state 3 -- a network peer -- captions the map on row 54")
    ck.equal("view_player.caption_colours",
             [pe.u32(CAPTION_COLOUR_TABLE + 4 * i)
              for i in range(len(CAPTION_COLOUR_ARMS))],
             list(CAPTION_COLOUR_ARMS),
             "one colour arm per side, chosen by 0x00509E32")
    ck.check("view_player.caption_colour_is_rgb565",
             pe.bytes_at(CAPTION_COLOUR_PACK, 2) == b"\x25\xF8"
             and pe.bytes_at(CAPTION_COLOUR_PACK + 5, 2) == b"\x81\xE1"
             and contains(pe, CAPTION_COLOUR_PACK, 32, b"\x66\xC1\xEA\x03"),
             "red masked to five bits, green to six, blue shifted down three")

    # ---- the two sounds --------------------------------------------------
    ck.equal("view_player.alarm_buffer",
             [pe.cstring(push_imm(pe, VIEW_PLAYER_ALARM_NAME) or 0, 32),
              push_imm(pe, VIEW_PLAYER_ALARM_HANDLE_PUSH)],
             ["alarm.wav", VIEW_PLAYER_ALARM],
             "aInitViewPlayer loads a second buffer beside progress.wav")
    ck.check("view_player.alarm_gate",
             call_target(pe, ALARM_MODE_CALL) == GAME_MODE_READ
             and pe.bytes_at(ALARM_MODE_CMP, 3)
             == b"\x83\xF8" + bytes([NETWORK_MODE])
             and call_target(pe, ALARM_TURN_CALL) == TURN_COUNTER_READ
             and pe.u32(ALARM_HANDLE_READ + 2) == VIEW_PLAYER_ALARM
             and call_target(pe, ALARM_PLAY) == DIRECT_SOUND_PLAY,
             "the alert needs mode 2 and a turn already played -- network only")
    ck.equal("view_player.alarm_is_the_handover",
             [push_imm(pe, va) for va, want in HANDOVER_STATE_WRITES
              if want is not None],
             [want for _va, want in HANDOVER_STATE_WRITES
              if want is not None],
             "and it rides the write that opens the next player's screen")
    ck.check("view_player.progress_is_played",
             pe.u8(PROGRESS_PLAY_GATE) == 0x74
             and pe.u32(PROGRESS_PLAY - 7) == VIEW_PLAYER_SOUND
             and call_target(pe, PROGRESS_PLAY) == DIRECT_SOUND_PLAY,
             "an unchanged fill is silent; a changed one ticks progress.wav")
    ck.check("view_player.game_mode",
             pe.u32(GAME_MODE_READ + 1) == GAME_MODE
             and pe.u32(GAME_MODE_WRITE + 5) == GAME_MODE,
             "the mode is one byte at 0x00509EE8, written by fcn.0043B730")

    # ---- and what the ids actually say, out of the shipped banks ---------
    banks: dict[str, dict[int, str]] = {}
    for bank in sorted({b for b, _i in VIEW_PLAYER_CAPTIONS}):
        path = root / TEXT_DIR / bank
        try:
            program = lcl.parse_bytes(path.read_bytes(), str(path))
        except (OSError, lcl.LclSyntaxError) as exc:
            ck.check(f"view_player.captions.{bank}", False, str(exc))
            return
        banks[bank] = {n.index: n.text for r in program.routines
                       for n in r.body if isinstance(n, lcl.TextEntry)}
    ck.equal("view_player.captions",
             [banks[bank].get(ident)
              for bank, ident in sorted(VIEW_PLAYER_CAPTIONS)],
             [VIEW_PLAYER_CAPTIONS[key]
              for key in sorted(VIEW_PLAYER_CAPTIONS)],
             f"{len(VIEW_PLAYER_CAPTIONS)} captions read back out of the banks")


def check_ring(ck: Checker, pe: PEFile) -> None:
    letters = table(pe, RING_LETTER_TABLE, 8)
    got: list[int | None] = []
    for target in letters:
        if pe.bytes_at(target, 2) == b"\x33\xDB":
            got.append(0)
        elif pe.u8(target) == 0xBB:
            got.append(pe.u32(target + 1))
        else:
            got.append(None)
    ck.equal("ring.letters", got, RING_LETTERS,
             "dir -> dir.LIB element: N S W E and the dot")
    ck.check("ring.tiers",
             pe.bytes_at(RING_TIER_HOVER_LEA, 3) == b"\x8D\x7B\x06"
             and pe.bytes_at(RING_TIER_BLOCKED_ADD, 3) == b"\x80\xC3\x06",
             "hover tier +6, blocked tier +12")
    ck.equal("ring.hit_radius",
             [push_imm(pe, va) for va in RING_HIT_RADIUS_PUSH],
             [RING_HIT_RADIUS] * 2, "nearest record within 600 px")
    ck.equal("ring.hover_distance", cmp_imm(pe, RING_HOVER_DISTANCE),
             RING_HOVER_DISTANCE_MAX, "a hovered entry farther than 20 px is dim")
    ck.check("ring.clamp", pe.bytes_at(RING_CLAMP_LOW, 3) == b"\x83\xC0\xFC",
             "screen position clamped from window origin - 4")
    ck.check("ring.geometry",
             pe.bytes_at(RING_BUILD_STRAIGHT, 6) == b"\x8D\x91\xDE\x0D\x00\x00"
             and pe.bytes_at(RING_BUILD_DIAGONAL, 6) == b"\x8D\x90\xC2\xF6\xFF\xFF",
             "0xDDE straight, 0x93E diagonal")
    deltas = table(pe, DIRECTION_DELTA_TABLE, 8)
    ck.check("ring.delta_table",
             cmp_imm(pe, DIRECTION_DELTA_CMP) == 7
             and all(DIRECTION_DELTA_DISPATCH <= t < DIRECTION_DELTA_DISPATCH + 352
                     for t in deltas),
             "eight facings dispatch inside fcn.004308C0")
    angles = table(pe, DIRECTION_ANGLE_TABLE, 8)
    got_angles = [0 if pe.bytes_at(t, 2) == b"\x33\xC0"
                  else pe.u32(t + 1) if pe.u8(t) == 0xB8 else None
                  for t in angles]
    ck.equal("ring.angles", got_angles, FACING_ANGLES,
             "facing -> 4096-unit angle")
    ck.equal("ring.tick_periods",
             {hex(va): cmp_imm(pe, va) for va in TICK_PERIODS},
             {hex(va): period for va, period in TICK_PERIODS.items()},
             "5/20/100/300 ms counters")
    ck.check("ring.tick_store",
             pe.bytes_at(TICK_STORE, 6) == b"\x88\x0D\x68\x30\x52\x00",
             "the 100 ms counter is the blink source")


def check_clicks(ck: Checker, pe: PEFile) -> None:
    ck.equal("click.pad", (push_imm(pe, CLICK_PAD_ARG),
                           call_target(pe, CLICK_PAD_HIT[0]),
                           call_target(pe, CLICK_PAD_RUN[0])),
             (42, CLICK_PAD_HIT[1], CLICK_PAD_RUN[1]),
             "the pad is tested first")
    ck.equal("click.cell_states",
             (cmp_imm(pe, CLICK_STATE_WARP), cmp_imm(pe, CLICK_STATE_REACHABLE),
              cmp_imm(pe, CLICK_BAND_LOW), cmp_imm(pe, CLICK_BAND_HIGH)),
             (60, 10, 30, 37), "warp, reachable and the target bands")
    ck.equal("click.ring_modes",
             {hex(va): mov_store_imm32(pe, va) for va in RING_MODE_STORES},
             {hex(va): mode for va, mode in RING_MODE_STORES.items()},
             "mode 3 warp, 1 move, 2 turn in place")
    ck.equal("click.calls", [call_target(pe, va) for va, _ in (
        CLICK_ATTACK, CLICK_TURN_TO_TARGET, CLICK_ROTATE, CLICK_RESELECT,
        CLICK_RING_BUILD)], [t for _, t in (
            CLICK_ATTACK, CLICK_TURN_TO_TARGET, CLICK_ROTATE, CLICK_RESELECT,
            CLICK_RING_BUILD)],
        "attack, aGetDirectionTo, rotate, reselect, ring build")
    ck.equal("ring_click.calls", [call_target(pe, va) for va, _ in (
        RING_CLICK_HIT, RING_CLICK_WARP, RING_CLICK_MOVE, RING_CLICK_ROTATE,
        RING_CLICK_RESELECT, RING_CLICK_DESELECT)], [t for _, t in (
            RING_CLICK_HIT, RING_CLICK_WARP, RING_CLICK_MOVE, RING_CLICK_ROTATE,
            RING_CLICK_RESELECT, RING_CLICK_DESELECT)],
        "hit test, warp, move, rotate, reselect, deselect")
    ck.check("ring_click.cancel", cmp_imm(pe, RING_CLICK_CANCEL) == 8,
             "record 8 is the X")
    ck.check("ring_click.deselect_on_zero_mp",
             pe.bytes_at(RING_CLICK_MP_TEST, 3) == b"\x38\x58\x15",
             "mp == 0 after the command deselects")
    ck.check("rotate.wrapper",
             any(call_target(pe, ROTATE_WRAPPER + i) == ROTATE
                 for i in range(165)),
             "fcn.004735D0 calls aChangeUnitViewDirection")
    ck.check("rotate.writes_facing",
             cmp_imm(pe, ROTATE_REFUSE_LOW) == 61
             and cmp_imm(pe, ROTATE_REFUSE_HIGH) == 63
             and pe.bytes_at(ROTATE_FACING_STORE, 3) == b"\x88\x46\x46"
             and call_target(pe, ROTATE_ANGLE_CALL[0]) == ROTATE_ANGLE_CALL[1],
             "types 61..63 refuse; +0x46 written; the object turns")


def check_pad(ck: Checker, pe: PEFile) -> None:
    ck.equal("pad.rect", (cmp_imm(pe, PAD_X_LOW), cmp_imm(pe, PAD_X_HIGH),
                          cmp_imm(pe, PAD_Y_LOW), cmp_imm(pe, PAD_Y_HIGH)),
             (404, 494, 382, 478), "click rectangle")
    ck.check("pad.strides",
             reg_imm32_values(pe, PAD_DIV_30, 5, 0xB8) == [0x88888889]
             and reg_imm32_values(pe, PAD_DIV_48, 5, 0xB8) == [0x2AAAAAAB],
             "column = dx / 30, row = dy / 48")
    ck.equal("pad.hit_calls", (call_target(pe, PAD_HIT_GATE[0]),
                               call_target(pe, PAD_HIT_COMMAND[0])),
             (PAD_HIT_GATE[1], PAD_HIT_COMMAND[1]),
             "availability gate and (col, row) -> command")
    # The table is indexed by `command - 1` (`dec eax; cmp eax, 7`).
    arms = table(pe, PAD_GATE_TABLE, 8)
    ends = sorted(set(arms) | {PAD_GATE_TABLE})
    sprites: dict[int, int | None] = {}
    for index, target in enumerate(arms):
        if target == PAD_UNAVAILABLE:
            continue
        limit = min(e for e in ends if e > target) - target
        values = reg_imm32_values(pe, target, limit, 0xBF)
        want = PAD_SPRITES.get(index + 1)
        sprites[index + 1] = want if want in values else None
    ck.equal("pad.sprites", sprites, dict(PAD_SPRITES),
             "command -> ui.LIB element (mov edi, imm)")
    ck.equal("pad.unavailable_arm",
             [i + 1 for i, t in enumerate(arms) if t == PAD_UNAVAILABLE],
             [c for c in range(1, 9) if c not in PAD_SPRITES],
             "commands 4 and 6 have no socket")
    ck.equal("pad.gate_calls", [call_target(pe, va) for va, _ in (
        PAD_GATE_DEFENCE, PAD_GATE_HEAL, PAD_GATE_WEAPON, PAD_GATE_USE_TARGET,
        *PAD_GATE_USE_ALT)], [t for _, t in (
            PAD_GATE_DEFENCE, PAD_GATE_HEAL, PAD_GATE_WEAPON, PAD_GATE_USE_TARGET,
            *PAD_GATE_USE_ALT)],
        "defence, heal, weapon mode and the four use targets")
    ck.check("pad.gate_tests",
             pe.bytes_at(PAD_GATE_HEAL_MP, 4) == b"\x80\x7E\x15\x01"
             and pe.bytes_at(PAD_GATE_CLASS, 8) == b"\x80\x3C\x55\x99\xC0\x51\x00\x03",
             "heal needs a point; class 3 has no stand down or use")
    ck.equal("pad.draw_calls", (call_target(pe, PAD_DRAW_GATE[0]),
                                call_target(pe, PAD_DRAW_BLIT[0])),
             (PAD_GATE, BLITTER), "the pad redraw asks the gate and blits")
    ck.check("pad.draw_origin",
             0x194 in reg_imm32_values(pe, PAD_DRAW, 164, 0xBF)
             and 0x17E in reg_imm32_values(pe, PAD_DRAW, 164, 0xBE),
             "sockets drawn from (404, 382)")


def check_keyboard(ck: Checker, pe: PEFile) -> None:
    pad_keys = {}
    unknown_pad_targets = []
    for code in range(PAD_KEY_LOW, PAD_KEY_HIGH + 1):
        arm = pe.u8(PAD_KEY_INDEX + code - PAD_KEY_LOW)
        target = pe.u32(PAD_KEY_ARMS + arm * 4)
        if target not in PAD_KEY_TARGETS:
            unknown_pad_targets.append((chr(code), f"0x{target:08X}"))
            continue
        command = PAD_KEY_TARGETS[target]
        if command:
            pad_keys[chr(code)] = command
    ck.equal("keyboard.pad_targets_known", unknown_pad_targets, [],
             "every indexed arm is the default or one of the six commands")
    ck.equal("keyboard.pad_commands", pad_keys, ORIGINAL_COMMAND_KEYS,
             "D/H/S/W/R/U -> defend/heal/stimulant/weapon/rest/use")

    normalized = {}
    unknown_column_targets = []
    for code in range(COLUMN_KEY_HIGH + 1):
        arm = pe.u8(COLUMN_KEY_INDEX + code)
        target = pe.u32(COLUMN_KEY_ARMS + arm * 4)
        if target not in COLUMN_KEY_TARGETS:
            unknown_column_targets.append((code, f"0x{target:08X}"))
            continue
        action = COLUMN_KEY_TARGETS[target]
        if action:
            normalized[code] = action
    ck.equal("keyboard.column_targets_known", unknown_column_targets, [],
             "every indexed arm is the default, an event, or a camera turn")
    ck.equal("keyboard.column_events", normalized,
             ORIGINAL_NORMALIZED_ACTIONS,
             "1..4 keep event numbers; F1..F4, B/G/T and control keys")

    translated = {}
    unknown_message_targets = []
    for name, raw in (("BACKSPACE", 8), ("TAB", 9), ("ENTER", 13),
                      ("ESCAPE", 27)):
        arm = pe.u8(CHAR_INDEX + raw - 8)
        target = pe.u32(CHAR_ARMS + arm * 4)
        if target not in CHAR_TARGETS:
            unknown_message_targets.append((name, f"0x{target:08X}"))
            continue
        translated[name] = CHAR_TARGETS[target]
    for name, virtual_key in (("LEFT", 0x25), ("RIGHT", 0x27),
                              ("DELETE", 0x2E)):
        arm = pe.u8(KEYDOWN_INDEX + virtual_key - 0x10)
        target = pe.u32(KEYDOWN_ARMS + arm * 4)
        if target not in KEYDOWN_TARGETS:
            unknown_message_targets.append((name, f"0x{target:08X}"))
            continue
        translated[name] = KEYDOWN_TARGETS[target]
    translated.update({"F1": 15, "F2": 16, "F3": 17, "F4": 18})
    ck.equal("keyboard.message_targets_known", unknown_message_targets, [],
             "every sampled WM_CHAR/WM_KEYDOWN arm has a known target")
    ck.equal("keyboard.message_tokens", translated,
             {"BACKSPACE": 1, "TAB": 0, "ENTER": 2, "ESCAPE": 5,
              "LEFT": 8, "RIGHT": 10, "DELETE": 12,
              "F1": 15, "F2": 16, "F3": 17, "F4": 18},
             "WM_CHAR controls and WM_KEYDOWN arrows/Delete/F1..F4")
    ck.check("keyboard.message_passthrough",
             pe.bytes_at(KEYDOWN_F_RANGE, 15)
             == b"\x83\xF9\x70\x72\x0A\x83\xF9\x7B\x77\x05\x80\xE9\x61\x88\x08"
             and pe.bytes_at(CHAR_PASSTHROUGH, 12)
             == b"\x8B\x54\x24\x0C\xB8\x01\x00\x00\x00\x88\x0A\xC3",
             "F1..F12 subtract 0x61; printable WM_CHAR keeps its byte")
    ck.check("keyboard.space_recentre",
             pe.bytes_at(SPACE_TEST, 5) == b"\x80\x7C\x24\x10\x20"
             and call_target(pe, SPACE_MODE_CALL[0]) == SPACE_MODE_CALL[1]
             and pe.bytes_at(SPACE_MODE_CALL[0] + 5, 3) == b"\x83\xF8\x01"
             and call_target(pe, SPACE_EYES_CALL[0]) == SPACE_EYES_CALL[1]
             and call_target(pe, SPACE_UNIT_CALL[0]) == SPACE_UNIT_CALL[1],
             "Space centres the selection, toggling eyes <-> on-unit")


def je_target(pe: PEFile, va: int) -> int | None:
    """Target of a near `je rel32` (`0F 84`) at *va*."""
    if pe.bytes_at(va, 2) != b"\x0F\x84":
        return None
    return (va + 6 + pe.i32(va + 2)) & 0xFFFFFFFF


def mov_eax_imm32(pe: PEFile, va: int) -> int | None:
    """Immediate of `mov eax, imm32` at `va`."""
    return pe.u32(va + 1) if pe.u8(va) == 0xB8 else None


def mov_eax_abs32(pe: PEFile, va: int) -> int | None:
    """Address of `mov eax, [abs32]` / `mov ecx|edx, [abs32]` at `va`."""
    op = pe.u8(va)
    if op == 0xA1:
        return pe.u32(va + 1)
    if op == 0x8B and pe.u8(va + 1) in (0x0D, 0x15):
        return pe.u32(va + 2)
    return None


def check_place_interface(ck: Checker, pe: PEFile) -> None:
    ck.equal("place.init_call", call_target(pe, PLACE_INIT_CALL[0]),
             PLACE_INIT_CALL[1], "aInitBattleGround raises the place interface")
    ck.check("place.init_selects_the_first",
             call_target(pe, PLACE_INIT_POOL_COUNT[0]) == PLACE_INIT_POOL_COUNT[1]
             and pe.bytes_at(PLACE_INIT_SELECT_STORE, 5)
             == b"\xA3" + PLACE_SELECT_GLOBAL.to_bytes(4, "little"),
             "[0x514064] = 0 when the pool has anyone, else -1")
    ck.equal("place.click_calls",
             (call_target(pe, PLACE_NORMAL_CLICK_CALL[0]),
              call_target(pe, PLACE_CLICK_CALL[0])),
             (PLACE_NORMAL_CLICK_CALL[1], PLACE_CLICK_CALL[1]),
             "the ordinary click handler first, then the place interface's")
    ck.equal("place.turn_gate", call_target(pe, PLACE_TURN_GATE[0]),
             PLACE_TURN_GATE[1], "the counter alone, at the top of the handler")
    ck.equal("place.band_y",
             [cmp_imm(pe, PLACE_BAND_Y_LOW) + 1, cmp_imm(pe, PLACE_BAND_Y_HIGH) - 1],
             PLACE_BAND_Y, "y strictly between 385 and 459")
    ck.equal("place.band_prev_x",
             [cmp_imm(pe, PLACE_BAND_PREV_X_LOW) + 1,
              cmp_imm(pe, PLACE_BAND_PREV_X_HIGH) - 1],
             PLACE_BAND_PREV_X, "x strictly between 47 and 220")
    ck.equal("place.band_next_x",
             [cmp_imm(pe, PLACE_BAND_NEXT_X_LOW) + 1,
              cmp_imm(pe, PLACE_BAND_NEXT_X_HIGH) - 1],
             PLACE_BAND_NEXT_X, "x strictly between 220 and 394")
    ck.equal("place.band_results",
             (mov_eax_imm32(pe, PLACE_BAND_PREV_RESULT),
              mov_eax_imm32(pe, PLACE_BAND_NEXT_RESULT)), (2, 1),
             "2 is the previous soldier, 1 the next")
    ck.equal("place.band_arms",
             (je_target(pe, PLACE_CLICK + 0x16), je_target(pe, PLACE_CLICK + 0x1D)),
             (PLACE_NEXT_ARM, PLACE_PREV_ARM),
             "dec eax; je next-arm; dec eax; je previous-arm")
    ck.equal("place.arms_wrap_on_the_pool_count",
             [call_target(pe, va) for va in PLACE_COUNT_CALLS],
             [PLACE_INIT_POOL_COUNT[1]] * 2,
             "previous wraps to count - 1, next to 0")
    ck.equal("place.facing_screen_halves",
             (call_target(pe, PLACE_SCREEN_W[0]), call_target(pe, PLACE_SCREEN_H[0])),
             (PLACE_SCREEN_W[1], PLACE_SCREEN_H[1]),
             "the screen's width and height, halved -- not the window's")
    ck.check("place.facing_arithmetic",
             pe.bytes_at(PLACE_FACING_LEFT[0], 6) == b"\x83\xE2\x02\x83\xC2\x04"
             and pe.bytes_at(PLACE_FACING_RIGHT[0], 6) == b"\x83\xE1\xFE\x83\xC1\x07",
             "left: 4 + 2 * (y < half); right: 7 - 2 * (y < half)")
    ck.check("place.five_arguments",
             call_target(pe, PLACE_FROM_POOL_CALL[0]) == PLACE_FROM_POOL_CALL[1]
             and pe.bytes_at(PLACE_FROM_POOL_ARGS, 3) == b"\x83\xC4\x14",
             "aTransferUnitFromPoolToMap(player, slot, x, y, facing)")
    ck.check("place.take_back",
             call_target(pe, PLACE_TO_POOL_CALL[0]) == PLACE_TO_POOL_CALL[1]
             and mov_store_imm32(pe, PLACE_SELECT_NONE_STORE) == 0xFFFFFFFF,
             "aTransferUnitFromMapToPool; an emptied pool selects nobody")
    ck.equal("place.sounds",
             {hex(va): mov_eax_abs32(pe, va) for va in PLACE_SOUND_SITES},
             {hex(va): buf for va, buf in PLACE_SOUND_SITES.items()},
             "click_1 for a placement or a take-back, click_2 for the band")


def check_panel(ck: Checker, pe: PEFile) -> None:
    ck.check("panel.origin",
             push_imm(pe, PANEL_ORIGIN_PUSH) == 415
             and push_imm(pe, PANEL_ORIGIN_PUSH + 5) == 60
             and call_target(pe, PANEL_RESTORE[0]) == PANEL_RESTORE[1]
             and call_target(pe, PANEL_CALL[0]) == PANEL_CALL[1],
             "background restored, then drawn at (60, 415)")
    ck.equal("panel.blocks", [call_target(pe, va) for va, _ in (
        PANEL_HP_BLOCK, PANEL_XP_BLOCK, PANEL_WEAPON_BLOCK, PANEL_MP_BLOCK,
        PANEL_SKILLS_BLOCK)], [t for _, t in (
            PANEL_HP_BLOCK, PANEL_XP_BLOCK, PANEL_WEAPON_BLOCK, PANEL_MP_BLOCK,
            PANEL_SKILLS_BLOCK)], "five sub-renderers")
    ck.check("panel.block_offsets",
             pe.bytes_at(PANEL_XP_OFFSET, 3) == b"\x8D\x53\x4B"
             and pe.bytes_at(PANEL_WEAPON_OFFSET, 6) == b"\x8D\x8B\x91\x00\x00\x00"
             and pe.bytes_at(PANEL_MP_OFFSET, 6) == b"\x8D\x8B\xEB\x00\x00\x00"
             and pe.bytes_at(PANEL_SKILLS_OFFSET, 6) == b"\x81\xC3\x13\x01\x00\x00",
             "x + 75, x + 145, x + 235, x + 275")
    ck.equal("panel.helpers", [call_target(pe, va) for va, _ in (
        PANEL_HP_MAX, PANEL_HEAT_LIMIT, PANEL_AMMO_MAX, PANEL_TIER)],
        [t for _, t in (PANEL_HP_MAX, PANEL_HEAT_LIMIT, PANEL_AMMO_MAX,
                        PANEL_TIER)], "hp max, heat limit, ammo max, tier")
    ck.check("panel.alien_skips_weapon",
             pe.bytes_at(PANEL_ALIEN_TEST, 8) == b"\x80\x3C\x4D\x99\xC0\x51\x00\x01",
             "class 1 draws no weapon block")


def check_columns(ck: Checker, pe: PEFile) -> None:
    ck.equal("columns.rect", (cmp_imm(pe, COLUMN_Y_LOW), cmp_imm(pe, COLUMN_Y_HIGH),
                              cmp_imm(pe, COLUMN_X0_LOW), cmp_imm(pe, COLUMN_X0_HIGH),
                              cmp_imm(pe, COLUMN_X1_LOW), cmp_imm(pe, COLUMN_X1_HIGH)),
             (66, 345, 11, 49, 594, 632), "two click columns")
    ck.check("columns.row_height",
             reg_imm32_values(pe, COLUMN_DIV_31, 5, 0xB8) == [0x08421085],
             "row = (y - 66) / 31")
    ck.equal("columns.hit_calls", (call_target(pe, COLUMN_HIT_SPRITE[0]),
                                   call_target(pe, COLUMN_HIT_EVENT[0])),
             (COLUMN_HIT_SPRITE[1], COLUMN_HIT_EVENT[1]),
             "sprite (availability) and event lookups")
    events = []
    for column, tab in enumerate(COLUMN_EVENT_TABLES):
        got = []
        for target in table(pe, tab, 9):
            if pe.bytes_at(target, 2) == b"\x33\xC0":
                got.append(0)
            elif pe.u8(target) == 0xB8:
                got.append(pe.u32(target + 1))
            else:
                got.append(None)
        events.append(got)
    ck.equal("columns.events", events, COLUMN_EVENTS,
             "(column, row) -> interface event")
    sprite_arms = table(pe, COLUMN_SPRITE_TABLE, 16)
    sprites = {}
    for event, target in enumerate(sprite_arms, start=1):
        values = reg_imm32_values(pe, target, 0x60, 0xBE)
        sprites[event] = COLUMN_SPRITES[event] if COLUMN_SPRITES[event] in values else None
    ck.equal("columns.sprites", sprites, dict(COLUMN_SPRITES),
             "event -> mi.LIB element")
    caption_arms = table(pe, COLUMN_CAPTION_TABLE, 16)
    captions = {}
    for event, target in enumerate(caption_arms, start=1):
        values = push_imm8_values(pe, target, 0x20)
        captions[event] = sorted(v for v in COLUMN_CAPTIONS[event] if v in values)
    ck.equal("columns.captions", captions, dict(COLUMN_CAPTIONS),
             "event -> Txtmod_h id")
    ck.check("columns.caption_draw",
             push_imm(pe, COLUMN_CAPTION_POS[0]) == 60
             and push_imm(pe, COLUMN_CAPTION_POS[1]) == 22
             and push_imm(pe, COLUMN_CAPTION_COLOUR) == 0x632C
             and call_target(pe, COLUMN_CAPTION_PRINT[0]) == COLUMN_CAPTION_PRINT[1],
             "hint at (60, 22)")
    ck.check("columns.draw",
             pe.bytes_at(COLUMN_DRAW_X, 3) == b"\x83\xC1\x0B"
             and push_imm(pe, COLUMN_DRAW_EMPTY) == COLUMN_EMPTY_SPRITE
             and call_target(pe, COLUMN_DRAW_BLIT[0]) == BLITTER
             and cmp_imm(pe, COLUMN_DRAW_Y_END) == 345
             and contains(pe, COLUMN_DRAW, 166, b"\x47\x02\x00\x00"),
             "x 11 (+583 for the right column), empty slot mi[31], rows to 345")
    ck.check("columns.hover",
             pe.bytes_at(COLUMN_HOVER_Y, 3) == b"\x83\xC2\x42"
             and pe.bytes_at(COLUMN_HOVER_X, 3) == b"\x83\xC0\x0B",
             "hover redraw at (11, 66) + grid")


def check_radar(ck: Checker, pe: PEFile) -> None:
    ck.equal("radar.clip", (push_imm(pe, RADAR_CLIP_PUSH + 9),
                            push_imm(pe, RADAR_CLIP_PUSH + 4),
                            push_imm(pe, RADAR_CLIP_PUSH + 2),
                            push_imm(pe, RADAR_CLIP_PUSH)),
             RADAR_CLIP, "the green screen")
    ck.check("radar.centre",
             pe.bytes_at(RADAR_CENTRE_SUB[0], 5) == b"\x2D\x22\x02\x00\x00"
             and pe.bytes_at(RADAR_CENTRE_SUB[1], 6) == b"\x81\xE9\xA6\x01\x00\x00",
             "rotation about (546, 422)")
    ck.check("radar.scale",
             pe.bytes_at(RADAR_SCALE_READ, 6) == b"\x8B\x0D\xDC\x06\x51\x00"
             and mov_store_imm32(pe, RADAR_SCALE_DEFAULT_STORE) == RADAR_SCALE_DEFAULT,
             "scale global, default 40")
    ck.check("radar.xy",
             contains(pe, RADAR_XY, 0x50, b"\x8D\x04\x80\x8D\x04\xC0\xD1\xE0")
             and contains(pe, RADAR_XY, 0x50, b"\xC1\xE0\x05\x03\xC1\xD1\xE0")
             and contains(pe, RADAR_XY, 0x50, b"\x05\xF5\x01\x00\x00")
             and contains(pe, RADAR_XY, 0x50, b"\xBA\xC7\x01\x00\x00"),
             "ox = cx*90/scale + 501, oy = 455 - cy*66/scale")
    ck.check("radar.relations",
             cmp_imm(pe, RADAR_NEUTRAL_TEST) == 0xFC
             and pe.bytes_at(RADAR_VISIBLE_CELL_TEST, 3) == b"\x80\x38\x01",
             "player 0xFC is nobody's; a state-1 cell shows the other side's unit")
    ck.check("radar.lamp",
             push_imm(pe, RADAR_LAMP_PUSH[0]) == 453
             and push_imm(pe, RADAR_LAMP_PUSH[0] + 5) == 616
             and push_imm(pe, RADAR_LAMP_PUSH[0] + 12) == 11
             and push_imm(pe, RADAR_LAMP_PUSH[1] + 12) == 10,
             "sm[11] enemy visible, sm[10] detected at (616, 453)")
    ck.equal("radar.compass",
             {hex(va): mov_store_imm32(pe, va) for va in RADAR_COMPASS_WRITES},
             {hex(va): v for va, v in RADAR_COMPASS_WRITES.items()},
             "letters at (546, 397) (546, 447) (521, 422) (571, 422)")
    ck.check("radar.compass_table",
             pe.bytes_at(RADAR_COMPASS_TABLE_LOAD, 5)
             == b"\xBE" + (RADAR_COMPASS_TABLE + 4).to_bytes(4, "little"),
             "four (x, y) pairs at 0x0050FE40, rotated about the centre")
    ck.check("radar.zoom_click",
             contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x81\xFE\xF5\x01\x00\x00")
             and contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x81\xFE\x4F\x02\x00\x00")
             and contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x3D\x85\x01\x00\x00")
             and contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x3D\xC7\x01\x00\x00")
             and contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x81\xFE\x22\x02\x00\x00")
             and contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x83\xF8\x50\x7D")
             and contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x83\xC0\x05")
             and contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x83\xF8\x14\x7E")
             and contains(pe, RADAR_ZOOM_CLICK, 0x80, b"\x83\xE8\x05"),
             "click in (501..591, 389..455): x >= 546 scale +5 to 80, else -5 to 20")


def check_frame(ck: Checker, pe: PEFile) -> None:
    ck.equal("frame.window", [mov_store_imm32(pe, WINDOW_STORE + 10 * i)
                              for i in range(4)], list(WINDOW),
             "(60, 34) 520x340 written to 0x4FE330..3C")
    ck.check("frame.window_globals",
             all(pe.u32(WINDOW_STORE + 10 * i + 2) == WINDOW_GLOBALS[i]
                 for i in range(4)), "the four window globals")
    ck.check("frame.strips",
             push_imm(pe, FRAME_PUSH_34) == 34 and push_imm(pe, FRAME_PUSH_106) == 106
             and all(push_imm(pe, va) == 340 for va in FRAME_PUSH_340),
             "plate strips 34 high, 106 high and 340 tall (374 and 580 derived)")
    ck.check("frame.turn_text",
             push_imm(pe, FRAME_TURN_POS[0]) == 560
             and push_imm(pe, FRAME_TURN_POS[1]) == 22
             and mov_store_imm32(pe, FRAME_TURN_RED) == 0xF800,
             "turn at (560, 22), red 0xF800 near the limit")
    ck.check("frame.turn_limit",
             all(any(call_target(pe, FRAME + i) == t for i in range(3394))
                 for t in (FRAME_TURN_LIMIT_FLAG, FRAME_TURN_LIMIT_VALUE,
                           FRAME_TURN_LIMIT_TEXT)),
             "\"%d/%s\" when SetTurnControl set a par")
    ck.check("frame.calls",
             all(any(call_target(pe, FRAME + i) == t for i in range(3394))
                 for t in (OVERLAY, RADAR)),
             "one redraw draws the overlay and the radar directly")


def check_blitter(ck: Checker, pe: PEFile) -> None:
    ck.check("blitter.element",
             pe.bytes_at(BLITTER_LEA_9, 3) == b"\x8D\x0C\xC0"
             and pe.bytes_at(BLITTER_TABLE_OFFSET, 3) == b"\x8B\x50\x0C"
             and pe.bytes_at(BLITTER_DATA_OFFSET, 4) == b"\x8B\x7C\x01\x10"
             and pe.bytes_at(BLITTER_PIXELS_BASE, 3) == b"\x8B\x48\x10",
             "element = lib + [lib+0xC] + 36*index; data at +0x10")
    ck.check("blitter.transparent",
             pe.bytes_at(BLITTER_TRANSPARENT_TEST, 2) == b"\x3C\x00",
             "index 0 is skipped in every library")
    ck.check("blitter.anchors",
             pe.bytes_at(ANCHOR_X, 4) == b"\x8B\x44\x24\x08"
             and contains(pe, ANCHOR_X, 23, b"\x1C")
             and contains(pe, ANCHOR_Y, 23, b"\x20"),
             "+0x1C and +0x20 read by fcn.00446200/220 only")
    ck.check("blitter.anchor_callers",
             any(call_target(pe, OVERLAY + i) == ANCHOR_X for i in range(4041))
             and not any(call_target(pe, COLUMN_DRAW + i) == ANCHOR_X
                         for i in range(166))
             and not any(call_target(pe, PAD_DRAW + i) == ANCHOR_X
                         for i in range(164)),
             "the overlay subtracts anchors; columns and pad blit top-left")


def check_loaders(ck: Checker, pe: PEFile) -> None:
    for name, (routine, size), libs in (
            ("battle_map", BATTLE_MAP_INIT, BATTLE_MAP_LIBS),
            ("map_interface", MAP_INTERFACE_INIT, MAP_INTERFACE_LIBS),
            ("ui_icons", UI_ICONS_INIT, UI_ICON_LIBS),
            ("ui", UI_INIT, UI_LIBS)):
        names = cstring_pushes(pe, routine, size)
        ck.check(f"loaders.{name}.names",
                 all(any(n.endswith(lib) for n in names) for lib in libs),
                 " ".join(sorted(libs)))
        ck.check(f"loaders.{name}.handles",
                 all(contains(pe, routine, size, b"\x68" + h.to_bytes(4, "little"))
                     for h in libs.values()),
                 "&handle pushed for each library")


def check_libraries(ck: Checker, root: Path) -> dict[str, liblib.ShapeLibrary]:
    libs: dict[str, liblib.ShapeLibrary] = {}
    for name, count in LIB_COUNTS.items():
        path = root / LIB_DIR / f"{name}.LIB"
        try:
            lib = liblib.load_lib(str(path))
        except (OSError, liblib.LibError) as exc:
            ck.check(f"lib.{name}", False, str(exc))
            continue
        libs[name] = lib
        ck.equal(f"lib.{name}.count", len(lib), count)
    for (name, index), shape in LIB_SHAPES.items():
        lib = libs.get(name)
        if lib is None:
            continue
        e = lib.elements[index]
        ck.equal(f"lib.{name}[{index}]", (e.width, e.height, e.delta_x, e.delta_y),
                 shape)
    return libs


def check_texts(ck: Checker, root: Path) -> None:
    for bank, ids in TEXT_BANKS.items():
        path = root / TEXT_DIR / bank
        try:
            program = lcl.parse_bytes(path.read_bytes(), str(path))
        except (OSError, lcl.LclSyntaxError) as exc:
            ck.check(f"text.{bank}", False, str(exc))
            continue
        present = {n.index for r in program.routines for n in r.body
                   if isinstance(n, lcl.TextEntry)}
        ck.check(f"text.{bank}", all(i in present for i in ids),
                 f"{len(ids)} caption ids present")


def check_plate(ck: Checker, root: Path) -> dict | None:
    try:
        image = bmp.load(str(root / PLATE))
    except (OSError, bmp.BmpError) as exc:
        ck.check("plate.open", False, str(exc))
        return None
    ck.equal("plate.size", (image.width, image.height), PLATE_SIZE)
    ck.check("plate.window_dark",
             mean_luminance(image, *WINDOW) < WINDOW_MAX_MEAN
             and all(mean_luminance(image, *strip) > FRAME_MIN_MEAN
                     for strip in PLATE_STRIPS),
             "the hole is dark, the four strips are metal")
    measured = measure_plate(image)
    for key, want in PLATE_FEATURES.items():
        ck.equal(f"plate.{key}", measured[key], want)
    ck.check("plate.segments", segments_cover(PLATE_SEGMENTS),
             "fixed pieces and bands tile the frame; fillers lie inside a piece")
    # A filler repeats down the height a taller canvas has, so anything but a
    # single row of it shows as a stripe every time the pattern comes round.
    ck.check("plate.fillers_are_one_row",
             all(s[4] == 1 for s in PLATE_SEGMENTS if s[6] == "filler"),
             "a vertical filler is one pixel tall and extrudes seamlessly")
    # The painted screen runs one pixel past the clip on the right (x 592
    # against 591); everything else the engine draws lands on green.
    green = measured["radar_screen"]
    ck.check("plate.radar_inside_clip",
             green is not None
             and green[0] >= RADAR_CLIP[0] and green[1] >= RADAR_CLIP[1]
             and green[0] + green[2] <= RADAR_CLIP[0] + RADAR_CLIP[2] + 1
             and green[1] + green[3] <= RADAR_CLIP[1] + RADAR_CLIP[3],
             "the green screen lies inside the engine's clip (+1 px right)")
    return measured


def run_checks(root_name: str) -> Checker:
    root = Path(root_name)
    ck = Checker()
    try:
        pe = PEFile(root / GAME_EXE)
    except (OSError, PEError) as exc:
        ck.check("binary.open", False, str(exc))
        return ck
    check_overlay(ck, pe)
    check_progress(ck, pe)
    check_view_player(ck, pe, root)
    check_selection(ck, pe)
    check_ring(ck, pe)
    check_clicks(ck, pe)
    check_pad(ck, pe)
    check_keyboard(ck, pe)
    check_panel(ck, pe)
    check_place_interface(ck, pe)
    check_columns(ck, pe)
    check_radar(ck, pe)
    check_frame(ck, pe)
    check_blitter(ck, pe)
    check_loaders(ck, pe)
    check_libraries(ck, root)
    check_texts(ck, root)
    check_plate(ck, root)
    return ck


# --------------------------------------------------------------------------
# The fixture
# --------------------------------------------------------------------------

def emit_cases(root_name: str, out_path: str) -> int:
    root = Path(root_name)
    ck = run_checks(root_name)
    if ck.failed:
        LOG.error("refusing to emit: %d checks failed", ck.failed)
        return 1
    pe = PEFile(root / GAME_EXE)
    libs = {name: liblib.load_lib(str(root / LIB_DIR / f"{name}.LIB"))
            for name in FIXTURE_LIBS}
    image = bmp.load(str(root / PLATE))
    state_map = list(pe.bytes_at(STATE_MAP, STATE_MAP_LEN))
    overlay_states = {}
    for state, arm in STATE_TO_ARM.items():
        sprite = ARM_SPRITES.get(arm)
        if sprite is None:
            continue
        overlay_states[str(state)] = {"lib": sprite[0], "element": sprite[1],
                                      "hover_gated": arm in (1, 12)}
    doc = {
        "source": f"{GAME_EXE} + plate_5.bmp + Libs (hud_tables.py)",
        "overlay": {
            "state_map": state_map,
            "states": overlay_states,
            "unit_markers": UNIT_MARKERS,
            "far_markers": FAR_MARKERS,
            "zoom_gate": ZOOM_GATE,
            "blink_period_ms": 100,
        },
        "ring": {
            "letters": RING_LETTERS,
            "cancel_element": RING_CANCEL_ELEMENT,
            "tier_hover": RING_TIER_HOVER,
            "tier_blocked": RING_TIER_BLOCKED,
            "hit_radius": RING_HIT_RADIUS,
            "hover_distance_max": RING_HOVER_DISTANCE_MAX,
            "clamp": RING_CLAMP,
            "offsets": [list(o) for o in RING_OFFSETS],
            "facing_deltas": [list(d) for d in FACING_DELTAS],
            "facing_angles": FACING_ANGLES,
            "modes": {"move": 1, "turn": 2, "warp": 3},
        },
        "pad": {
            "rect": PAD_RECT,
            "commands": [[c, r, cmd] for (c, r), cmd in sorted(PAD_COMMANDS.items())],
            "sprites": {str(k): v for k, v in PAD_SPRITES.items()},
        },
        "input": {
            "events": {str(k): v for k, v in ORIGINAL_EVENT_KEYS.items()},
            "commands": {str(v): k for k, v in ORIGINAL_COMMAND_KEYS.items()},
            "camera": {"centre": "SPACE", "turn_left": "LEFT",
                       "turn_right": "RIGHT"},
        },
        "panel": {
            "origin": list(PANEL_ORIGIN),
            "name_y": PANEL_NAME_Y,
            "blocks": PANEL_BLOCKS,
            "icons": PANEL_ICONS,
            "status_text": PANEL_STATUS_TEXT,
        },
        # docs/43 section 5.5: the place interface, aPI.cpp.  The band of
        # the panel a click cycles the pool in (inclusive, plate units; x 220
        # answers nobody), what each half answers, the facing a placement
        # takes from the screen quadrant of the click, and the marker states
        # the overlay draws the landing cells in.
        "place": {
            "band_y": PLACE_BAND_Y,
            "prev_x": PLACE_BAND_PREV_X,
            "next_x": PLACE_BAND_NEXT_X,
            "prev_result": 2,
            "next_result": 1,
            "facing_by_quadrant": PLACE_FACING_BY_QUADRANT,
            "split": "screen halves",
            "marker_states": [70, 73],
            "turn_gated": True,
            "arguments": 5,
        },
        "columns": {
            "rect": COLUMN_RECT,
            "right_shift": COLUMN_RIGHT_SHIFT,
            "events": COLUMN_EVENTS,
            "sprites": {str(k): v for k, v in COLUMN_SPRITES.items()},
            "empty_sprite": COLUMN_EMPTY_SPRITE,
            "captions": {str(k): v for k, v in COLUMN_CAPTIONS.items()},
            "caption_pos": [60, 22],
        },
        "radar": {
            "clip": list(RADAR_CLIP),
            "centre": list(RADAR_CENTRE),
            "xy": list(RADAR_XY_CONSTANTS),
            "scale_default": RADAR_SCALE_DEFAULT,
            "scale_step": RADAR_SCALE_STEP,
            "scale_range": list(RADAR_SCALE_RANGE),
            "scale_split": RADAR_SCALE_SPLIT,
            "click_rect": list(RADAR_CLICK_RECT),
            "compass": RADAR_COMPASS,
            "compass_sprites": RADAR_COMPASS_SPRITES,
            "unit_sprites": RADAR_UNIT_SPRITES,
            "lamp": list(RADAR_LAMP),
            "lamp_sprites": RADAR_LAMP_SPRITES,
        },
        "frame": {
            "window": list(WINDOW),
            "strips": [list(s) for s in PLATE_STRIPS],
            "turn_text": list(FRAME_TURN),
            "turn_red_within": FRAME_TURN_RED_WITHIN,
        },
        "progress": {
            "origin": [PROGRESS_ORIGIN_X, PROGRESS_ORIGIN_Y],
            "segments": PROGRESS_SEGMENTS,
            "steps": PROGRESS_STEPS,
            "lit_element": 0,
            "dark_element": 1,
            "library": "vp",
            "wave": VIEW_PLAYER_CUE_WAVE,
        },
        # docs/43 section 4.5: the selection survives the hand-over, and an
        # empty one is refilled with the side's first unit -- two passes, the
        # second without the movement test.
        "selection": {
            "none": SELECTION_NONE,
            "kept_over_the_hand_over": True,
            "empty_takes_the_first_unit": True,
            "first_unit_passes": 2,
            "second_pass_ignores_movement": True,
        },
        # docs/43 section 7.3: the screen the bar is drawn on.  The remake
        # needs three things out of it -- which state the computer's turn is,
        # that the state prints nothing, and that the alert belongs to a mode
        # the remake has no way to be in.
        "view_player": {
            "watched_state": WATCHED_STATE,
            "prints_nothing": True,
            "captions": {str(ident): text for (_bank, ident), text
                         in sorted(VIEW_PLAYER_CAPTIONS.items())},
            "alarm_wave": VIEW_PLAYER_ALARM_WAVE,
            "alarm_mode": NETWORK_MODE,
            "peer_caption_row": PEER_CAPTION_ORIGIN[1],
        },
        "plate": {
            "size": list(PLATE_SIZE),
            "features": measure_plate(image),
            "segments": [{"name": n, "region": [x, y, w, h], "anchor": a,
                          "kind": k} for n, x, y, w, h, a, k in PLATE_SEGMENTS],
        },
        "libs": {
            name: [{"w": e.width, "h": e.height, "dx": e.delta_x, "dy": e.delta_y}
                   for e in lib.elements]
            for name, lib in libs.items()
        },
        "texts": {bank.split(".")[0]: ids for bank, ids in TEXT_BANKS.items()},
    }
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, sort_keys=True)
        fh.write("\n")
    LOG.info("wrote %s (%d libraries, %d overlay states)", out, len(libs),
             len(overlay_states))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", metavar="ROOT")
    parser.add_argument("--emit-cases", metavar="PATH")
    parser.add_argument("--root", metavar="ROOT")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO if args.verbose or args.check
                        else logging.WARNING, format="%(message)s")
    if args.emit_cases:
        if not args.root:
            parser.error("--emit-cases needs --root ROOT")
        return emit_cases(args.root, args.emit_cases)
    if not args.check:
        parser.error("one of --check or --emit-cases is required")
    ck = run_checks(args.check)
    total = ck.passed + ck.failed
    if ck.failed:
        LOG.error("%d/%d checks failed: %s", ck.failed, total, ", ".join(ck.failures))
        return 1
    LOG.info("%d/%d checks passed", ck.passed, total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
