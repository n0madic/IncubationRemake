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
  switches of the button columns, the command pad's availability gate;
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
PAD_KEYS = {"D": 1, "H": 2, "S": 3, "W": 5, "R": 7, "U": 8}

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
COLUMN_KEYS = {"Tab": 12, "Backspace": 15, "F1": 7, "F2": 8, "F3": 6,
               "F4": 5, "1": 1, "2": 2, "3": 3, "4": 4, "B": 11, "H": 13,
               "T": 14}

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
                "mouse", "inv", "umun", "uweapons")
LIB_SHAPES = {("mp1", 0): (9, 9, 4, 4), ("dir", 0): (13, 15, 6, 7),
              ("dir", 4): (9, 11, 4, 5), ("mp", 43): (25, 16, 12, 5),
              ("mp", 48): (19, 19, 9, 9), ("mp", 51): (20, 20, 9, 9),
              ("mp", 49): (7, 9, 3, 3), ("mp", 50): (8, 8, 3, 3),
              ("mp", 54): (9, 9, 4, 4), ("mp", 0): (3, 5, 1, 2),
              ("map", 0): (10, 10, 4, 4), ("sm", 0): (5, 5, 2, 2)}

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
#: How the remake cuts the plate (docs/43 §7).  A `fixed` piece keeps its
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
        except (OSError, lcl.ParseError) as exc:
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
    check_ring(ck, pe)
    check_clicks(ck, pe)
    check_pad(ck, pe)
    check_panel(ck, pe)
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
            "keys": PAD_KEYS,
        },
        "panel": {
            "origin": list(PANEL_ORIGIN),
            "name_y": PANEL_NAME_Y,
            "blocks": PANEL_BLOCKS,
            "icons": PANEL_ICONS,
            "status_text": PANEL_STATUS_TEXT,
        },
        "columns": {
            "rect": COLUMN_RECT,
            "right_shift": COLUMN_RIGHT_SHIFT,
            "events": COLUMN_EVENTS,
            "sprites": {str(k): v for k, v in COLUMN_SPRITES.items()},
            "empty_sprite": COLUMN_EMPTY_SPRITE,
            "captions": {str(k): v for k, v in COLUMN_CAPTIONS.items()},
            "caption_pos": [60, 22],
            "keys": COLUMN_KEYS,
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
