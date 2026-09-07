#!/usr/bin/env python3
"""Pin ``docs/42`` -- the mission's presentation layer -- to ``Incubation.exe``.

Every number ``docs/42`` quotes about the camera, the walk, the shot, the
idle scheduler, the set pieces and the scenery objects is a literal in the
shipped executable, and this tool reads each one back: an immediate inside a
named routine, the argument bytes a call site pushes, a jump table, a string
push, or the set of update arms that write one flag.  A claim the binary does
not carry fails here rather than surviving as prose.

Every ``--check`` run must find the executable and inspect every site; an
empty root is a failure, not zero work.

Usage::

    python3 tools/presentation_tables.py --check gog_incubation
    python3 tools/presentation_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("presentation_tables")

GAME_EXE = "Incubation.exe"

# --- the routines docs/42 names, as (start, end) virtual-address ranges ------
FLIGHT = (0x0040EEE0, 0x0040F226)            # docs/42 §2.2
UNIT_CAMERA = (0x004529D0, 0x00452E90)       # docs/42 §2.3
FREE_POSITION = (0x00453510, 0x004536C3)     # docs/42 §2.3
EYE_VIEW = (0x00452E90, 0x0045304E)          # docs/42 §2.4
MAP_VIEW_HEIGHT = (0x00453270, 0x00453297)   # docs/42 §2.4
ROTATE_CAMERA = (0x00403600, 0x00403717)     # docs/42 §2.1
SET_CAMERA = (0x00403560, 0x004035F9)
MOVE_CAMERA = (0x004037D0, 0x004038E6)
MOUSE_ROTATE = (0x00451000, 0x00451060)      # docs/42 §2.5
MOUSE_PAN = (0x004511A0, 0x00451200)
MAIN_LOOP = (0x0041C010, 0x0041D2A0)
VIEW_ON_UNIT = (0x004510A0, 0x00451150)      # GUI event 4
VIEW_EYES = (0x00451150, 0x004511A0)         # GUI event 2
VIEW_MAP = (0x00450F60, 0x00451000)          # GUI event 3
CYCLE = (0x00453CF0, 0x00453DB0)             # command 14
WALK_STEP = (0x0040EBB0, 0x0040ED90)         # docs/42 §3.2, the tracking step
RIDE_STEP = (0x0040EA30, 0x0040EBA0)         # the first-person step
SELECT_ANIMATION = (0x0040EDB0, 0x0040EEDA)
EXECUTE_MOVE = (0x0046E220, 0x0046EF50)
START_ANIMATION = (0x004055E0, 0x00405CB0)   # docs/42 §1.2
IDLE_STARTER = (0x004060B0, 0x004064F0)      # docs/42 §6.1
VIEW_REFRESH = (0x00406FC0, 0x00407250)      # docs/42 §1.3
FIGHT = (0x0040BD70, 0x0040E300)             # docs/42 §4
FRAME_TICK = (0x0040B6F0, 0x0040BD70)        # docs/42 §1.1
ATTACK_UNIT = (0x0046B450, 0x0046C400)
JUMP = (0x00411460, 0x004118E0)              # docs/42 §7.1
PUSH = (0x0046D530, 0x0046DA00)              # docs/42 §7.2
PUSH_DUST = (0x0042A6E0, 0x0042A760)
ARROW_MARKER = (0x00422D40, 0x00422ED0)      # docs/42 §7.3
ORBIT_SKILL = (0x00410190, 0x004104A0)       # docs/42 §7.5
ORBIT_JAM = (0x004104A0, 0x00410780)
ORBIT_HEAL = (0x0040FBE0, 0x0040FF30)
ORBIT_POISON = (0x0040F8F0, 0x0040FBE0)
ORBIT_OVERHEAT = (0x0040F420, 0x0040F8F0)
ORBIT_ROTATING = (0x0040FF30, 0x00410190)
#: `0x0043B740` -- the game-mode getter of `docs/25` §2; 1 is the campaign.
GAME_MODE_GETTER = 0x0043B740
# docs/42 §7 -- the creators the unit animations call, measured by
# `presentation_gold.py`'s seven `death_*` phases of 2026-09-03.
ARROWS = (0x00422D40, 0x00422EF1)
LANDING_DUST = (0x004227C0, 0x004228E8)
FLASH_HEAL = (0x00423030, 0x004232CF)
FLASH_POISON = (0x004232E0, 0x004234B2)
TRAIL = (0x00423670, 0x0042371E)
# docs/42 §7.3 -- who raises the marker: the select routine and the command
# pad, never the frame loop.
MARKER_RAISE = (0x00473920, 0x0047394B)
#: The whole of `.text`, for a count that must hold across the image.
TEXT_SECTION = (0x00401000, 0x004AF000)
SELECT_UNIT = (0x00471E00, 0x00471F63)
COMMAND_PAD = (0x004714B0, 0x00471AC2)
# docs/42 §7.4 / docs/25 §6 -- the drain's jam arm, in both of its loops.
DRAIN = (0x0046CCA0, 0x0046D162)
# docs/29 §1.1 button 2 -- the heal command and its three helpers, and the
# pad arm that charges it; the warp arm of the same pad.
HEAL_COMMAND = (0x00470890, 0x00470AA4)
HEAL_POWER = (0x004753C0, 0x004753E0)
MAX_HIT_POINTS = (0x00475240, 0x00475299)
HEAL_APPLY = (0x0047B180, 0x0047B1D8)
HEAL_PAD_ARM = (0x004733BB, 0x00473410)
# The pad's offer of button 2 (`case 2` of `0x00472570`) and its gate.
HEAL_OFFER = (0x0047261C, 0x00472641)
MAY_HEAL = (0x0047B4C0, 0x0047B5BC)
WARP_PAD = (0x00472F10, 0x00473072)
DOOR = (0x00410A20, 0x00410DA0)              # docs/42 §8
TUBE = (0x00410F10, 0x00411150)
ROOF_UNIT = (0x00411B00, 0x00411FB0)
# docs/42 §8 -- the set pieces' creators, measured 2026-09-03 (docs/97 §32).
TUBE_PUFFS = (0x00423770, 0x004238BF)
PLATFORM_DUST = (0x004234C0, 0x00423668)
ROOF_DEBRIS = (0x00422460, 0x00422603)
WALL_DEBRIS = (0x004238C0, 0x00423ABF)
FIRE_CIRCLE_RING = (0x00422F00, 0x00423024)
LASER_BEAM = (0x00428990, 0x00428BCD)
BOMBER_CREATOR = (0x0042A8E0, 0x0042A9BA)
PARA_BOMB_CREATOR = (0x0042B070, 0x0042B149)
ELEVATOR = (0x004125D0, 0x00412A00)
PLATFORM = (0x00412A00, 0x004131C0)
BARRIER = (0x00413560, 0x00413A40)
GROUND_FIRE = (0x004157B0, 0x00415C70)
CRUSH_WALL = (0x00415C70, 0x00415E90)
#: `ParaBombs` `0x00415E90` -- the bomber's fly-past and one bomb per tile.
PARA_BOMBS = (0x00415E90, 0x004160F0)
#: `0x004160F0` -- the bomb run, the **second** of the two routines the
#: `ParaBombs` handler drives (`docs/20` §7.4).
PARA_BOMB_RUN = (0x004160F0, 0x00416470)
#: `0x00470790` -- the handler itself, which runs the two in order.
PARA_BOMBS_HANDLER = (0x00470790, 0x00470AB0)
#: The two creators the set piece runs, and the two the remake models as
#: clearing the *arrived* flag.
PARA_BOMBS_CREATORS = (0x0042A8E0, 0x0042B070)
#: `0x0042F410(object, fieldType, keepHeight, mark)` -- the four-probe sweep
#: that decides which cells a scene object stands on (`docs/97` §41.4).
MARK_UNDER_OBJECT = (0x0042F410, 0x0042F650)
#: `0x0047C2C0` -- the between-players screen the AI's redraw callback draws
#: (`docs/23` §2, `docs/97` §35.1 and §41.5).
BETWEEN_PLAYERS = (0x0047C2C0, 0x0047D064)
MINE_PLACER = (0x0042FA70, 0x0042FB90)       # docs/42 §9.1
FIRE_PLACER = (0x0042F840, 0x0042FA70)
GLOW_PLACER = (0x0042FCB0, 0x0042FE80)
#: ``0x0042ED60`` -- the round tick the hand-over runs (``docs/25`` §4), and
#: ``0x00470AB0`` -- the ignition sweep just before it.
GROUND_TICK = (0x0042ED60, 0x0042EE90)
GROUND_IGNITE = (0x00470AB0, 0x00470B50)
#: ``aPlayGroundFireAnimation`` -- what an ignited glow does.
GROUND_FIRE_ANIM = (0x004157B0, 0x00415C70)
A_GROUND_FIRE_ANIM = 0x004157B0
A_STEP = 0x004308C0
A_REMOVE_UNIT = 0x004779C0
A_DELETE_SPECIAL = 0x00406960
A_FIRE_PLACER = 0x0042F840
A_MINE_PLACER = 0x0042FA70
A_GLOW_PLACER = 0x0042FCB0
A_GROUND_TICK = 0x0042ED60
A_GROUND_IGNITE = 0x00470AB0
#: ``0x0047D600``, the hand-over (``docs/25`` §4).
HAND_OVER = (0x0047D600, 0x0047DA00)
#: The victory-point marker placer of ``aCtrlMap.cpp`` (``docs/42`` §9.3): a
#: static ``A_MK_*`` object on every cell whose action point is 80..89, its
#: slot written into the cell's ``+0x14``.
VP_MARKER_PLACER = (0x00431E30, 0x00431FF8)
A_VP_MARKER_PLACER = 0x00431E30
VP_MARKER_JUMP = 0x00432000
A_SYMBOL_OBJECT = 0x00404C40
A_CREATE_SPECIAL = 0x004069C0
#: ``aBuild3DSpecialObjects`` (load) and ``aExecuteMove`` (a capture) are its
#: two callers.
BUILD_SPECIAL_OBJECTS = (0x004079D0, 0x00407A9F)
EXECUTE_MOVE = (0x0046E220, 0x0046EF00)
VP_MARKER_CALL_SITES = (0x00407A86, 0x0046E9E7)
VP_MARKER_MODELS = tuple(f"A_MK_{player}{band}.3DI"
                         for band in "AB" for player in range(5))
#: ``"A_MK_0A.3DI"`` at ``0x004C2E58``, then every 12 bytes down to
#: ``"A_MK_4B.3DI"`` at ``0x004C2DEC``.
VP_MARKER_STRINGS_LAST = 0x004C2E58
#: What action point 87's arm loads instead of ``0x004C2E04``.
VP_MARKER_BROKEN_POINTER = 0x00752E04
#: ``aCheckInBlobObjects``'s live count ``0x004FE640`` (``docs/42`` §4.9):
#: ``mov al, [esi+0x56] / test al, al / je / cmp al, 2 / jne / inc [count]``.
SWEEP_LIVE_COUNT_TEST = 0x0041E41A
SWEEP_LIVE_COUNT_BYTES = bytes.fromhex("8a465684c074043c027506ff0540e64f00")
#: The impact arms of the three weapons that change the map, and the switch
#: that selects them.
IMPACT_PLACER_WEAPONS = {40: 0x0040D93D, 42: 0x0040D76A, 43: 0x0040D5F8}
#: ``0x0040D962``..``0x0040D9FF`` -- (call site, subtype) in call order.
NINE_FIRE_SITES = ((0x0040D962, 3), (0x0040D975, 3), (0x0040D988, 3),
                   (0x0040D99B, 3), (0x0040D9B1, 3), (0x0040D9CB, 3),
                   (0x0040D9DB, 4), (0x0040D9EB, 3), (0x0040D9FF, 3))
CREATE_SPECIAL = (0x004069C0, 0x00406A40)
FREE_ANIMATION = (0x00406000, 0x00406070)
TEXT_BANKS = (0x00449CA0, 0x00449D10)        # docs/42 §4.2
BLOB_UPDATE = (0x0041E500, 0x00420814)       # docs/42 §4.6
BLOB_JUMP_TABLE = 0x00420814
BLOB_KINDS = 78
ARRIVED_FLAG = 0x004FE63C
#: The arms that **set** the flag (`mov dword [0x004FE63C], 1`), by control
#: flow rather than by which arm's start precedes the store: kind 2 falls
#: into kind 49's tail (`0x0041E842` -> `0x0041E84E`) and kind 61's seeker
#: runs straight into kind 28's arm at `0x004204D2`, whose store is at
#: `0x004204DD`.  The first
#: reading of this table attributed each store to the nearest preceding arm
#: start and so missed both and counted arm 45 -- which writes **`ebp`**,
#: the zero the sweep keeps as `aRandom2`'s base, i.e. it *clears* the flag
#: (`docs/42` §4.6, corrected 2026-09-03).  `tools/blob_runtime.py` had it
#: right all along: fourteen `_request_delete` sites and one
#: `global_signal_clear`.
ARRIVED_KINDS = frozenset({1, 2, 15, 25, 26, 27, 28, 32, 47, 49, 61, 69, 71, 74})
ARRIVED_CLEAR_KIND = 45
ARRIVED_SET_STORES = 12
#: Where kind 2's arm tests its life and where the shared store is.
ARRIVED_KIND_2_TAIL = (0x0041E842, 0x0041E84E)
ARRIVED_KIND_61_STORE = 0x004204DD
ARRIVED_KIND_61_FALLS_INTO_28 = 0x004204CE
ARRIVED_KIND_45_STORE = 0x0041F65D
#: The creators' own writes, outside the update: eight literal 1s (nothing
#: to wait for), six literal 0s (a flight begins), and twelve register
#: stores whose value is `steps <= 0` -- a `setle` or a `jle` around the
#: record count the creator just computed, so an adjacent target arrives at
#: once.  Counted so the inventory cannot shrink unnoticed.
ARRIVED_CREATOR_WRITES = {"set": 8, "clear": 6, "computed": 12}
#: The blob constructor every creator allocates through -- 116 call sites.
A_BLOB_CTOR = 0x00420950
#: Every creator-side store to the flag, mapped to the start of the function
#: that makes it.  Read 2026-09-03 by walking back to the instruction after
#: the previous `ret`; the three the named-symbol table gets wrong are marked.
#: The point of the table is the ordering claim below it: a creator clears
#: the flag **before** it allocates, so a refusal -- a full pool -- leaves it
#: down and the caller waits its hundred frames.
ARRIVED_CREATOR_STORES = {
    0x00420AC2: 0x00420AC2, 0x00424079: 0x00423FB1,
    0x0042420D: 0x00423D80,  # `aBlob_CreateTracerBullet`, inside its loop
    0x0042455D: 0x0042448D, 0x00424568: 0x0042448D,
    0x00424AB7: 0x004249F1, 0x00424AC3: 0x004249F1,
    0x0042500B: 0x00424FE2, 0x00425017: 0x00424FE2,
    0x0042573B: 0x0042567A, 0x00425AD6: 0x00425A8A,
    0x00425F97: 0x00425F63, 0x004263B7: 0x004261DC,
    0x004267D7: 0x0042672A, 0x00426A97: 0x00426A1E,
    0x00426E67: 0x00426E33, 0x004272D2: 0x00427293,
    0x00427690: 0x004275D8, 0x004279FF: 0x0042797D,
    0x00427EFF: 0x00427E69, 0x0042846F: 0x00428433,
    0x004287D3: 0x00428745, 0x004287E8: 0x00428745,
    0x0042A938: 0x0042A8E0,
    0x0042B0E3: 0x0042B0D0,  # an unnamed creator behind the `ret` at 0x0042B0CF
    0x0042B490: 0x0042B490,  # ditto, behind the flag's own getter at 0x0042B480
}
#: The one store that follows an allocation, and what it writes.  It sits
#: inside `aBlob_CreateTracerBullet`'s record loop and writes **1** -- a
#: tracer has nothing to arrive -- so it creates no wait at any pool state.
ARRIVED_STORE_AFTER_ALLOCATION = (0x0042420D, 1)
#: Reads of the flag outside the update, one of which is its whole getter.
ARRIVED_READS_OUTSIDE = (0x00424727, 0x004250E0, 0x0042B480)
ARRIVED_GETTER = 0x0042B480

#: docs/23 §5.3 and docs/42 §4 -- where the mine's blast is drawn.
EXECUTE_WARP = (0x0046EF50, 0x00470150)
EXECUTE_BOMB = (0x004702C0, 0x004706A0)
A_EXECUTE_BOMB = 0x004702C0
A_PLAY_FIGHT = 0x0040BD70

#: Every call site of `aRemoveUnitElement`, by the routine that makes it
#: (`trace_names.py`'s symbol table, read 2026-09-03).  Its own last
#: instruction is `mov byte [esi+0x16], 0` at `0x00477ABD`, so removal kills:
#: the split below is between the sites that arrive with the victim already
#: dead and the sites where this write **is** the death.
REMOVE_UNIT_KILL_PATH = {
    0x0046C1F9: "aAttackUnit",
    0x0046D34C: "aCheckWeaponDamage",
    0x0046D95C: "aCheckWeaponDamage",
    0x0047063F: "aExecuteBomb",
    0x0047296E: "aKillUnit",
}
REMOVE_UNIT_LIVE = {
    0x0040B316: "aAI_SpecialPlayerControl",
    0x00413459: "aPlayRotateStatueSequence",
    0x00413903: "aPlayLaserBarrier",
    0x00413F5E: "aPlayStatueSequence",
    0x00413FA4: "aPlayStatueSequence",
    0x004142EC: "aPlayStatueSequence",
    0x00414F9C: "aPlayFootBridgeSequence",
    0x00415663: "aPlayFootBridgeSequence",
    0x00415B8D: "aPlayGroundFireAnimation",
    0x0041CA5E: "aBattleSystem.cpp:3999",
    0x0046F2FB: "the hatch arm of 0x0046F210",
    0x00470208: "aExecuteTeleporter",
    0x00478420: "aUI_KillUnit",
    0x00478465: "aUI_KillUnit",
    0x0047BCA0: "lKillPlayerUnits",
}
#: The two loops whose own gate says the victim is alive.
UI_KILL_UNIT = (0x004783D0, 0x004784A0)
KILL_PLAYER_UNITS = (0x0047BC60, 0x0047BCCD)
#: `docs/42` §4.6 -- the muzzle arms that write 0 over the wait flag
#: (`[esp+0x10]`, initialised to 1 at `0x0040CC4D`).
WAIT_SKIPPED_WEAPONS = frozenset({0x0F, 0x11, 0x14, 0x15, 0x1B, 0x1E, 0x1F, 0x20,
                                  0x24, 0x25})
#: `docs/42` §4.8 (corrected 2026-09-03) -- the death switch does not branch
#: on the severity: `[esp+0x1C]` is zeroed at `0x0040CC49`, just before the
#: muzzle switch, and the muzzle arms write the value the death switch reads
#: at `0x0040DD05`.  So the "style" is the weapon's: 3 for the four sniper
#: arms, 1 for five, 2 for weapon 40 (FireDeath), and 0 -- the default arm
#: of the switch -- for every other weapon.
DEATH_STYLE_BY_WEAPON = {**{w: 3 for w in (15, 30, 31, 32)},
                         **{w: 1 for w in (9, 11, 17, 22, 44)}, 40: 2}
MUZZLE_INDEX = 0x0040E5A4
MUZZLE_JUMP = 0x0040E524
#: The impact switch: the byte index table, its jump table, and the weapon id
#: the first entry stands for (``lea eax, [edx - 7]`` at ``0x0040D4DF``).
IMPACT_INDEX = 0x0040E614
IMPACT_JUMP = 0x0040E5D4
IMPACT_FIRST_WEAPON = 7
IMPACT_ENTRIES = 0x28
MUZZLE_WEAPON_FIRST = 2
MUZZLE_WEAPONS = 46
MUZZLE_ARMS = 32
MUZZLE_DEFAULT_ARM = 0x0040D42C
IMPACT_SWITCH_ENTRY = 0x0040D472
#: `KillFire`, `FireDeath` and `FlyingUnit` -- the three death creators the
#: second capture reached (`blob_creators.DEATH_PROGRAMS`).
KILL_FIRE = (0x00423AD0, 0x00423C20)
FIRE_DEATH = (0x0042B1D0, 0x0042B2F0)
FLYING_UNIT = (0x00429700, 0x004297F0)
EMPTY_CAPTION = 0x004FA524
TEXT = (0x00401000, 0x004B0000)

# Callees, for `call rel32` pins.
A_SET_CAMERA = 0x00403560
A_CAMERA_POSITION = 0x00403750
A_ROTATE = 0x00403600
A_MOVE = 0x004037D0
A_FLIGHT = 0x0040EEE0
A_UNIT_CAMERA = 0x004529D0
A_FREE_POSITION = 0x00453510
A_CLAMP = 0x00453420
A_GRADIENTS = 0x0047ABD0
A_FRAME = 0x0040B6F0
A_VIEW_MODE = 0x004536D0
A_ON_SCREEN = 0x00453050
A_MAP_CAMERA = 0x00453150
A_EYE_CAMERA = 0x00452E90
A_SELECT_ANIM = 0x0040EDB0
A_START_ANIM = 0x004055E0
A_CONT_ANIM = 0x004054D0
A_REMAINING = 0x00405460
A_FREE_ANIM = 0x00406000
A_IDLE_START = 0x004060B0
A_HIDE = 0x00405320
A_RANDOM2 = 0x004638E0
A_DISTANCE = 0x0044AE10
A_DIRECTION = 0x0046D400
A_REACTION_POS = 0x00453730
REACTION_POS = (0x00453730, 0x00453900)
#: `0x00453320` fills the camera box; `0x00419B90/A50/A60` read the loaded
#: `.lev` header at `0x004FCED0` (`+0x224` camera height, `+0x357` rows,
#: `+0x35B` columns -- docs/10 section 3).
CAMERA_BOX_INIT = (0x00453320, 0x00453390)
HEADER_BASE = 0x004FCED0
A_CAMERA_HEIGHT = 0x00419B90
#: `0x0047ABD0`'s facing jump table and its eight `(gx, gy)` arms, in facing
#: order -- the inverse of docs/10 section 5.10's step table.
GRADIENT_TABLE = 0x0047AD04
GRADIENTS = [(0, 1), (-1, 0), (0, -1), (1, 0), (1, -1), (-1, 1), (1, 1),
             (-1, -1)]
#: `0x004794B0` -- the walk's "would the unit be seen at this cell" probe.
SEEN_AT = (0x004794B0, 0x00479700)
A_SEEN_AT = 0x004794B0
A_LOS_EX = 0x0046C460
FREE_ROTATION = (0x00451000, 0x00451092)
A_ARRIVED = 0x0042B480
A_ALIVE = 0x0042B4A0
A_BLOB_SWEEP = 0x0041E3D0
A_NOTE_CALLBACK = 0x0042C5D0
A_ENEMY_MOVE = 0x00460510
A_ANIM_LEVEL = 0x004604D0
A_IDLE_SELECT = 0x0042DDF0
#: `docs/42` §6.3 -- the unit record's `+0x56`, the running animation handle.
#: `aUnitMap.cpp`'s three one-line accessors: write, clear, read.
UNIT_ANIMATION_SET = 0x00477970
UNIT_ANIMATION_CLEAR = 0x00477980
UNIT_ANIMATION_READ = 0x00477990
#: `and eax, 0xFF / push eax / call aContCHAnimation`, the site that says
#: what the byte is for.
UNIT_ANIMATION_TO_CONT = 0x0040E2A3
A_CONT_ANIMATION = 0x004054D0
A_RIDE = 0x0040EA30
A_TRACK = 0x0040EBB0
A_FIGHT = 0x0040BD70
A_ARROWS = 0x00422D40
A_ROTATE_VECTOR = 0x004039A0
A_DUST = 0x0042A6E0
A_TRAIL = 0x00423670
A_LANDING_DUST = 0x004227C0
A_CTOR = 0x00420950
A_CREATE_SPECIAL = 0x004069C0
A_FLASH_CIRCLE_HEAL = 0x00423030
A_FLASH_CIRCLE_POISON = 0x004232E0
A_ORIENT = 0x00403AA0
A_ZOOMBOB = 0x00423720
A_MARKER_RAISE = 0x00473920
A_JAM_ORBIT = 0x004104A0
A_HEAT_CAP = 0x00475340
A_ATTACK_UNIT = 0x0046B450
A_HEAL_COMMAND = 0x00470890
A_HEAL_POWER = 0x004753C0
A_MAX_HIT_POINTS = 0x00475240
A_HEAL_APPLY = 0x0047B180
A_HEAL_ORBIT = 0x0040FBE0
A_MAY_HEAL = 0x0047B4C0
A_TUBE_PUFFS = 0x00423770
A_ROOF_DEBRIS = 0x00422460
A_READ_CAMERA = 0x00403780
A_UNIT_HEIGHT = 0x0047AD70
A_CELL_IN_FRONT = 0x004308C0
A_EXECUTE_WARP = 0x0046EF50
A_DRAIN = 0x0046CCA0
A_BEAM = 0x00428990
A_BARRIER_HIT_A = 0x0042AB40
A_BARRIER_HIT_B = 0x0042A9D0
A_TUBE_SMOKE = 0x00423C20
A_WALL_DEBRIS = 0x004238C0
A_PLATFORM_DUST = 0x004234C0
#: The creators the death switch of docs/42 §4.8 reaches.  Four carry no
#: developer name (`blob_tables.BLOB_CREATOR_NAMES` holds `None` for them);
#: their names here are this project's, from what the code does, and
#: `tools/inclib/blob_creators.py`'s `DEATH_PROGRAMS` transcribes them.
DEATH_CREATORS = {
    "BloodFlood": 0x00420D80, "blood_spray_large": 0x00421360,
    "KillFire": 0x00423AD0, "FireExplosion": 0x00429A80,
    "FlyingDebris": 0x004216D0, "blood_burst": 0x00420B80,
    "species_burst": 0x00421C50, "FireDeath": 0x0042B1D0,
    "FlyingUnit": 0x00429700, "barrel_burst": 0x004298D0,
}
DEATH_PUFF = (0x004297F0, 0x004298D0)
BLOOD_BURST = (0x00420B80, 0x00420D80)
BLOOD_FLOOD = (0x00420D80, 0x00421360)
BLOOD_SPRAY_LARGE = (0x00421360, 0x004216D0)
FLYING_DEBRIS = (0x004216D0, 0x00421C50)
SPECIES_BURST = (0x00421C50, 0x00422460)
BARREL_BURST = (0x004298D0, 0x00429A80)
#: `0x004604A0` reads the gore level, dword 10 of `Game.opt` (`docs/20` §8).
A_GORE_LEVEL = 0x004604A0
GORE_PLAYER_TEST = b"\x80\x7f\x45\xff"      # cmp byte [edi+0x45], -1
GORE_READERS = {0x004169CE, 0x00420B84, 0x00420C13, 0x00420FE2, 0x00421C5A, 0x00421D42}
GORE_READER_RANGES = (TELEPORT_KILL := (0x00416840, 0x00416AD0), BLOOD_BURST,
                      BLOOD_FLOOD, SPECIES_BURST)
#: The doubles the blood sprays and the species coin read (`blob_creators`).
BLOOD_DOUBLES = {0x004B1248: 16.0, 0x004B1250: 160.0, 0x004B1258: -1280.0,
                 0x004B1260: 48.0, 0x004B1268: 6.0}
#: The set pieces docs/42 §8 transcribes line by line.
STATUE = (0x00413A40, 0x00414000)
STATUE_2 = (0x00414000, 0x00414360)
STATUE_BEAM = (0x00428BF0, 0x00428E30)
#: `0x00413500` -- `Statue2`'s ActPt sweep, which calls the rotating sequence
#: once per matched cell (`docs/97` §41).
STATUE_2_BATCH = (0x00413500, 0x00413560)
#: `aExecuteTeleporter` `0x00470150` (`docs/26` §5), reached from
#: `aExecuteMove`'s epilogue at `0x0046EE03`.
EXECUTE_TELEPORTER = (0x00470150, 0x004702C0)
FOOTBRIDGE = (0x00414A70, 0x00415110)
FOOTBRIDGE_2 = (0x00415110, 0x004157B0)
GROUND_UNIT = (0x00411FB0, 0x004125D0)
GROUND_UNIT_DEBRIS = (0x00422610, 0x004227C0)
TELEPORTER = (0x004164F0, 0x00416840)
TELEPORTER_STREAM = (0x0042A120, 0x0042A2F0)
#: docs/42 §9.1 -- the shield placer and its two callers.
SHIELD_PLACER = (0x0042FB90, 0x0042FCB0)
OBJECT_SEEDING = (0x004079D0, 0x00407A90)
A_SHIELD_PLACER = 0x0042FB90
#: docs/42 §1.2 -- the length chain and the interface the starts go through.
ANIMATION_INIT = (0x004A0A01, 0x004A0C50)
KEYFRAMED_INTERFACE_VTABLE = 0x004B1DDC     # KeyFramedAnimation, sub-object +80
KEYFRAMED_INTERFACE_ABSTRACT = 0x004B1E7C   # KeyFramedAnimationInterface
INTERFACE_SLOTS = {0x18: 0x004A0E1A, 0x24: 0x004A0E83, 0x2C: 0x004A0EBB}
MOVEMENT_LENGTH_SLOT = 0x2C
MOVEMENT_VTABLES = {"LinearVectorMovement": (0x004B2634, 0x004A8873),
                    "LinearRotationMovement": (0x004B2704, 0x004A97A4)}
KEY_TIME_SLOT = 0x14
KEY_VTABLES = {"LinearVectorKey": (0x004B3A3C, 0x004A9667),
               "LinearRotationKey": (0x004B3A9C, 0x004AA57E)}
PART_VTABLE = 0x004B1FEC
MODEL_VTABLE = 0x004B2244
#: docs/42 §6.1 -- the starter's type search never advances.
STARTER_LOOP = 0x0040616C
STARTER_LOOP_BYTES = bytes.fromhex("3bc5740b4181f9c80000007cf3")
STARTER_RANDOM_PUSHES = 0x00406182


class Checker:
    def __init__(self) -> None:
        self.passed = 0
        self.failed: list[str] = []
        self.lines: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            self.passed += 1
            self.lines.append(f"ok   {name}")
        else:
            self.failed.append(name)
            self.lines.append(f"FAIL {name}" + (f" -- {detail}" if detail else ""))


class Binary:
    def __init__(self, path: str) -> None:
        self.pe = PEFile(path)  # type: ignore[arg-type]

    def span(self, lo: int, hi: int) -> bytes:
        return self.pe.bytes_at(lo, hi - lo)

    def count(self, rng: tuple[int, int], pattern: bytes) -> int:
        blob = self.span(*rng)
        n, start = 0, 0
        while True:
            i = blob.find(pattern, start)
            if i < 0:
                return n
            n += 1
            start = i + 1

    def calls(self, rng: tuple[int, int], target: int) -> list[int]:
        """Every ``call rel32`` inside the range that lands on ``target``."""
        lo, hi = rng
        blob = self.span(lo, hi)
        out = []
        for i in range(len(blob) - 4):
            if blob[i] != 0xE8:
                continue
            rel = struct.unpack_from("<i", blob, i + 1)[0]
            if lo + i + 5 + rel == target:
                out.append(lo + i)
        return out

    def u32(self, va: int) -> int:
        return self.pe.u32(va)


def _pin_calls(ck: Checker, b: Binary, name: str, rng: tuple[int, int],
               target: int, expect: int) -> list[int]:
    sites = b.calls(rng, target)
    ck.check(f"{name}.calls_0x{target:08X}", len(sites) == expect,
             f"{len(sites)} != {expect}: {[hex(s) for s in sites]}")
    return sites


def _pin_bytes(ck: Checker, b: Binary, name: str, rng: tuple[int, int],
               pattern: bytes, expect: int, at_least: bool = False) -> None:
    n = b.count(rng, pattern)
    ok = n >= expect if at_least else n == expect
    ck.check(name, ok, f"{pattern.hex()} found {n} times, expected "
                       f"{'>= ' if at_least else ''}{expect}")


def _pin_at(ck: Checker, b: Binary, name: str, va: int, expect: bytes) -> None:
    got = b.pe.bytes_at(va, len(expect))
    ck.check(name, got == expect, f"{got.hex()} at {va:#x}, expected {expect.hex()}")


def _rtti_name(b: Binary, vtable: int) -> tuple[str, int]:
    """The class name and sub-object offset MSVC's RTTI records for a vtable:
    the complete-object locator sits in the dword before the table and names
    the type descriptor, whose mangled name follows its two pointers."""
    locator = b.u32(vtable - 4)
    offset = b.u32(locator + 4)
    descriptor = b.u32(locator + 12)
    return b.pe.cstring(descriptor + 8), offset


def _push8(value: int) -> bytes:
    return bytes([0x6A, value & 0xFF])


def _push32(value: int) -> bytes:
    return b"\x68" + struct.pack("<I", value & 0xFFFFFFFF)


def _check_camera(ck: Checker, b: Binary) -> None:
    # §2.1 -- the primitives refuse under the lock, pitch is clamped to ±1024.
    lock_string = _push32(0x004BFCFC)
    for name, rng in (("set", SET_CAMERA), ("rotate", ROTATE_CAMERA),
                      ("move", MOVE_CAMERA)):
        _pin_bytes(ck, b, f"camera.{name}.locked_message", rng, lock_string, 1)
    _pin_bytes(ck, b, "camera.rotate.pitch_min", ROTATE_CAMERA,
               b"\x66\x3d\x00\xfc", 1)                      # cmp ax, -1024
    _pin_bytes(ck, b, "camera.rotate.pitch_max", ROTATE_CAMERA,
               b"\x66\x3d\x00\x04", 1)                      # cmp ax, 1024

    # §2.2 -- the flight.
    _pin_bytes(ck, b, "flight.snap_20m", FLIGHT, b"\x3d\x00\x7d\x00\x00", 1)
    _pin_bytes(ck, b, "flight.snap_reads_new_pos_z", FLIGHT,
               b"\x8b\x4c\x24\x54", 1)                       # [esp+0x54] = arg 3
    _pin_bytes(ck, b, "flight.snap_reads_cur_pos_z", FLIGHT,
               b"\x8b\x5c\x24\x28", 1)                       # the read-back posZ
    _pin_bytes(ck, b, "flight.fast_threshold_500_x6", FLIGHT,
               b"\x3d\xf4\x01\x00\x00", 6)
    _pin_bytes(ck, b, "flight.stop_threshold_30_x6", FLIGHT, b"\x83\xf8\x1e", 6)
    _pin_bytes(ck, b, "flight.third_x6", FLIGHT, b"\xb8\x56\x55\x55\x55", 6)
    _pin_bytes(ck, b, "flight.sixth_x6", FLIGHT, b"\xb8\xab\xaa\xaa\x2a", 6)
    _pin_calls(ck, b, "flight", FLIGHT, A_SET_CAMERA, 2)
    _pin_calls(ck, b, "flight", FLIGHT, A_FRAME, 1)
    # The fast/slow choice is made before the loop head: the back edge at
    # 0x0040F214 lands at 0x0040F019, after the six threshold tests.
    back_edge = b.pe.bytes_at(0x0040F214, 5)
    rel = struct.unpack("<i", back_edge[1:])[0]
    ck.check("flight.choice_made_once", back_edge[0] == 0xE9
             and 0x0040F214 + 5 + rel == 0x0040F019,
             f"back edge lands at {0x0040F214 + 5 + rel:#x}")

    # §2.3 -- placing the camera on a unit.
    _pin_bytes(ck, b, "unit_camera.mode_switch_bound", UNIT_CAMERA,
               b"\x83\xf8\x03", 1)
    table = [b.u32(0x00452E80 + 4 * i) for i in range(4)]
    ck.check("unit_camera.quadrant_table",
             all(UNIT_CAMERA[0] <= t < UNIT_CAMERA[1] for t in table)
             and len(set(table)) == 4, str([hex(t) for t in table]))
    _pin_bytes(ck, b, "unit_camera.axis_offset_3200", UNIT_CAMERA,
               b"\xc1\xe3\x07", 1)                           # gx*25 << 7
    _pin_bytes(ck, b, "unit_camera.target_plus_1m_x2", UNIT_CAMERA,
               b"\x40\x06\x00\x00", 2)
    _pin_bytes(ck, b, "unit_camera.near_test_6m_x2", UNIT_CAMERA,
               b"\x80\x25\x00\x00", 2)
    _pin_bytes(ck, b, "unit_camera.near_lowering_12800", UNIT_CAMERA,
               b"\x8d\x84\x0a\x00\xce\xff\xff", 1)
    _pin_calls(ck, b, "unit_camera", UNIT_CAMERA, A_GRADIENTS, 1)
    _pin_calls(ck, b, "unit_camera", UNIT_CAMERA, A_FREE_POSITION, 1)
    _pin_calls(ck, b, "unit_camera", UNIT_CAMERA, A_CLAMP, 1)
    _pin_calls(ck, b, "unit_camera", UNIT_CAMERA, A_FLIGHT, 1)
    _pin_bytes(ck, b, "free_position.tries_70", FREE_POSITION,
               b"\x83\xfd\x46", 1)
    _pin_bytes(ck, b, "free_position.second_ray_plus_2400", FREE_POSITION,
               b"\x81\xc1\x60\x09\x00\x00", 1)
    # The cap inside the placement multiplies the header's camera height --
    # already world units -- by 1600 (`lea eax,[eax+eax*4]` twice, `shl 6`)
    # and so never bites; the box clamp below is the cap that does. Both
    # modes call the search: the `jmp` at `0x00452E11` joins mode 1 to it.
    _pin_calls(ck, b, "unit_camera.cap_reads_camera_height", UNIT_CAMERA,
               A_CAMERA_HEIGHT, 4)
    _pin_bytes(ck, b, "unit_camera.cap_x1600_dead", UNIT_CAMERA,
               b"\x8d\x04\x80\x8d\x04\x80\xc1\xe0\x06", 2, at_least=True)
    _pin_at(ck, b, "camera_height.is_header_0x224", A_CAMERA_HEIGHT,
            b"\xa1" + struct.pack("<I", HEADER_BASE + 0x224) + b"\xc3")
    _pin_at(ck, b, "map_rows.is_header_0x357", 0x00419A50,
            b"\xa1" + struct.pack("<I", HEADER_BASE + 0x357) + b"\xc3")
    _pin_at(ck, b, "map_columns.is_header_0x35b", 0x00419A60,
            b"\xa1" + struct.pack("<I", HEADER_BASE + 0x35B) + b"\xc3")
    # §2.1 -- the box: 800 on every low side, `(n - 1) * 3200` on x and y,
    # the header's camera height on z.
    _pin_at(ck, b, "camera_box.low_800_x3", CAMERA_BOX_INIT[0],
            b"\xb8\x20\x03\x00\x00\xa3\x60\x07\x51\x00\xa3\x64\x07\x51\x00"
            b"\xa3\x68\x07\x51\x00")
    _pin_bytes(ck, b, "camera_box.x25x128_x2", CAMERA_BOX_INIT,
               b"\x8d\x04\x80", 2, at_least=True)
    _pin_at(ck, b, "camera_box.x_high_minus_3200", 0x00453342,
            b"\x2d\x80\x0c\x00\x00\xa3\x6c\x07\x51\x00")
    _pin_at(ck, b, "camera_box.y_high_minus_3200", 0x0045335A,
            b"\x81\xe9\x80\x0c\x00\x00\x89\x0d\x70\x07\x51\x00")
    _pin_calls(ck, b, "camera_box.z_high", CAMERA_BOX_INIT, A_CAMERA_HEIGHT, 1)
    _pin_at(ck, b, "camera_box.z_high_store", 0x0045336B,
            b"\xa3\x74\x07\x51\x00")
    _pin_calls(ck, b, "camera_box.columns", CAMERA_BOX_INIT, 0x00419A60, 1)
    _pin_calls(ck, b, "camera_box.rows", CAMERA_BOX_INIT, 0x00419A50, 1)
    # `0x0047ABD0` -- the gradient of a facing, arm by arm out of the table.
    arms = [b.u32(GRADIENT_TABLE + 4 * i) for i in range(8)]
    decoded = []
    for arm in arms:
        head = b.pe.bytes_at(arm, 12)
        ok = head[0:2] == b"\xc7\x00" and head[6:8] == b"\xc7\x01"
        gx = struct.unpack_from("<i", head, 2)[0]
        gy = struct.unpack_from("<i", head, 8)[0]
        decoded.append((gx, gy) if ok else None)
    ck.check("gradients.table_is_facing_inverse", decoded == GRADIENTS,
             str(decoded))
    # §2.5 -- the pan's axes are `(0, -10, 0)` turned by the camera's angles,
    # written by the free rotation, and the drag is `* 40` on top.
    _pin_at(ck, b, "pan.forward_is_minus_10", 0x00451044,
            b"\xc7\x44\x24\x14\xf6\xff\xff\xff")
    _pin_calls(ck, b, "pan.forward_turned", FREE_ROTATION, 0x004039A0, 1)
    _pin_bytes(ck, b, "pan.forward_stored_at_0x50fe64", FREE_ROTATION,
               b"\x68\x64\xfe\x50\x00", 1)
    _pin_bytes(ck, b, "free_position.step_17x3", FREE_POSITION,
               b"\xc1\xe0\x04", 1)
    _pin_bytes(ck, b, "free_position.step_17x3_b", FREE_POSITION,
               b"\x8d\x04\x40", 1)
    _pin_calls(ck, b, "free_position", FREE_POSITION, A_CLAMP, 1)

    # The call sites and the (dist, height) bytes they push, docs/42 §2.3.
    sites = {
        "execute_move": (EXECUTE_MOVE, (4, 6)),
        "cycle": (CYCLE, (7, 8)),
        "view_on_unit": (VIEW_ON_UNIT, (7, 8)),
        "fight_behind_shooter": (FIGHT, (5, 9)),
        "fight_behind_victim": (FIGHT, (3, 5)),
        "bomb": ((0x004702C0, 0x00470790), (2, 5)),
        "lcl_a": ((0x00482130, 0x004821A0), (5, 6)),
        "lcl_b": ((0x004821A0, 0x00482250), (5, 6)),
    }
    for name, (rng, (height, dist)) in sites.items():
        _pin_bytes(ck, b, f"unit_camera.args.{name}", rng,
                   _push8(height) + _push8(dist), 1, at_least=True)
    # Two sites interleave the pushes with the coordinate loads.
    _pin_at(ck, b, "unit_camera.args.ground_fire_height_7", 0x00415B24, _push8(7))
    _pin_at(ck, b, "unit_camera.args.ground_fire_dist_9", 0x00415B2C, _push8(9))
    _pin_at(ck, b, "unit_camera.args.teleporter_height_5", 0x00470248, _push8(5))
    _pin_at(ck, b, "unit_camera.args.teleporter_dist_5", 0x00470250, _push8(5))
    calls = {"execute_move": (EXECUTE_MOVE, 1), "cycle": (CYCLE, 2),
             "view_on_unit": (VIEW_ON_UNIT, 1), "ground_fire": (GROUND_FIRE, 1),
             "fight": (FIGHT, 2),
             "teleporter": ((0x00470150, 0x004702C0), 1),
             "bomb": ((0x004702C0, 0x00470790), 1),
             "lcl_a": ((0x00482130, 0x004821A0), 1),
             "lcl_b": ((0x004821A0, 0x00482250), 1)}
    for name, (rng, n) in calls.items():
        _pin_calls(ck, b, f"unit_camera.site.{name}", rng, A_UNIT_CAMERA, n)

    # §2.4 -- the three views.
    mode = lambda v: b"\xc7\x05\xd8\x06\x51\x00" + struct.pack("<I", v)
    _pin_bytes(ck, b, "views.on_unit_sets_mode_2", VIEW_ON_UNIT, mode(2), 1)
    _pin_bytes(ck, b, "views.eyes_sets_mode_1", VIEW_EYES, mode(1), 1)
    _pin_bytes(ck, b, "views.map_sets_mode_4", VIEW_MAP, mode(4), 1)
    _pin_calls(ck, b, "views.eyes", VIEW_EYES, A_EYE_CAMERA, 1)
    _pin_calls(ck, b, "views.map", VIEW_MAP, A_MAP_CAMERA, 1)
    _pin_bytes(ck, b, "views.map_height_24000", MAP_VIEW_HEIGHT,
               struct.pack("<I", 24000), 1)
    _pin_bytes(ck, b, "views.map_target_ahead_3200", MAP_VIEW_HEIGHT,
               b"\x81\xc1\x80\x0c\x00\x00", 1)
    _pin_bytes(ck, b, "views.eyes_offset_800", EYE_VIEW, b"\xc1\xe0\x05", 1)
    _pin_bytes(ck, b, "views.eyes_height_640", EYE_VIEW,
               b"\x8d\x8c\x08\x80\x02\x00\x00", 1)
    _pin_bytes(ck, b, "views.eyes_target_minus_320", EYE_VIEW,
               b"\x81\xc1\xc0\xfe\xff\xff", 1)

    # §2.5 -- free control.
    _pin_bytes(ck, b, "mouse.rotate_x8_x2", MOUSE_ROTATE, b"\xc1\xe0\x03", 2)
    _pin_calls(ck, b, "mouse.rotate", MOUSE_ROTATE, A_ROTATE, 1)
    _pin_bytes(ck, b, "mouse.pan_x40", MOUSE_PAN, b"\x8d\x04\x80\xc1\xe0\x03", 1)
    _pin_calls(ck, b, "mouse.pan", MOUSE_PAN, A_MOVE, 1)
    _pin_calls(ck, b, "main_loop.rotate_on_right_drag", MAIN_LOOP, 0x00451000, 1)
    _pin_calls(ck, b, "main_loop.pan_on_middle_drag", MAIN_LOOP, 0x004511A0, 1)
    _pin_bytes(ck, b, "main_loop.height_key_plus_2000", MAIN_LOOP,
               _push32(2000), 1)
    _pin_bytes(ck, b, "main_loop.height_key_minus_2000", MAIN_LOOP,
               _push32(-2000), 1)
    _pin_calls(ck, b, "main_loop.height_key", MAIN_LOOP, A_MOVE, 1)


def _check_walk(ck: Checker, b: Binary) -> None:
    # §3.2 -- the tracking step keeps the position and re-aims the target.
    _pin_calls(ck, b, "walk.track.set_camera", WALK_STEP, A_SET_CAMERA, 1)
    _pin_calls(ck, b, "walk.track.view_mode", WALK_STEP, A_VIEW_MODE, 3)
    _pin_bytes(ck, b, "walk.track.not_in_map_view", WALK_STEP, b"\x83\xf8\x04", 1)
    _pin_bytes(ck, b, "walk.track.plus_0xa0", WALK_STEP, b"\x05\xa0\x00\x00\x00", 1)
    _pin_calls(ck, b, "walk.track.frame", WALK_STEP, A_FRAME, 1)
    _pin_bytes(ck, b, "walk.ride.sixths_x3", RIDE_STEP, b"\xb8\xab\xaa\xaa\x2a", 3)
    _pin_calls(ck, b, "walk.ride.set_camera", RIDE_STEP, A_SET_CAMERA, 1)
    _pin_calls(ck, b, "walk.ride.frame", RIDE_STEP, A_FRAME, 1)
    # The mode byte's branches inside aExecuteMove.
    _pin_calls(ck, b, "walk.mode.enemy_move_option", EXECUTE_MOVE, A_ENEMY_MOVE, 2)
    _pin_calls(ck, b, "walk.mode.on_screen_test", EXECUTE_MOVE, A_ON_SCREEN, 1)
    _pin_bytes(ck, b, "walk.mode.camera_low_12800", EXECUTE_MOVE,
               b"\x81\x7c\x24\x68\x00\x32\x00\x00", 1)
    _pin_calls(ck, b, "walk.mode.select_animation", EXECUTE_MOVE, A_SELECT_ANIM, 2)
    _pin_calls(ck, b, "walk.mode.map_camera", EXECUTE_MOVE, A_MAP_CAMERA, 1)
    _pin_calls(ck, b, "walk.step.ride", EXECUTE_MOVE, A_RIDE, 2)
    _pin_calls(ck, b, "walk.step.track", EXECUTE_MOVE, A_TRACK, 1)
    # The mode byte's inputs: `0x004794B0` asked at the destination and at
    # the source, the destination's answer dropped when the cell's `+0x0C`
    # is over 6. The probe is one `aCheckLineOfSightEx` per other-player unit
    # at `0x0047AD70` heights, skipping the beacon types 0x3D and 0x3E.
    _pin_calls(ck, b, "walk.mode.seen_probe_x3", EXECUTE_MOVE, A_SEEN_AT, 3)
    _pin_at(ck, b, "walk.mode.seen_probe_at_destination", 0x0046E330,
            b"\xe8" + struct.pack("<i", A_SEEN_AT - 0x0046E335))
    _pin_at(ck, b, "walk.mode.seen_probe_at_source", 0x0046E385,
            b"\xe8" + struct.pack("<i", A_SEEN_AT - 0x0046E38A))
    _pin_at(ck, b, "walk.mode.destination_plus_0x0c_over_6", 0x0046E357,
            b"\x80\x78\x0c\x06")
    _pin_calls(ck, b, "seen_at.line_of_sight", SEEN_AT, A_LOS_EX, 1)
    _pin_calls(ck, b, "seen_at.unit_height_x2", SEEN_AT, 0x0047AD70, 2)
    _pin_bytes(ck, b, "seen_at.skips_0x3d", SEEN_AT, b"\x3c\x3d", 1)
    _pin_bytes(ck, b, "seen_at.skips_0x3e", SEEN_AT, b"\x3c\x3e", 1)
    _pin_calls(ck, b, "walk.step.hide_rider", EXECUTE_MOVE, A_HIDE, 4)
    _pin_calls(ck, b, "walk.clip_started_once", EXECUTE_MOVE, A_START_ANIM, 1)
    # The selection animation only re-aims in view modes 2 and 3.
    _pin_calls(ck, b, "walk.select.view_mode", SELECT_ANIMATION, A_VIEW_MODE, 3)
    _pin_calls(ck, b, "walk.select.flight", SELECT_ANIMATION, A_FLIGHT, 1)


def _check_clocks(ck: Checker, b: Binary) -> None:
    # §1.2 -- the four start speeds and the loop counts.
    _pin_bytes(ck, b, "speed.walk_2_0", START_ANIMATION, _push32(0x40000000), 1)
    _pin_bytes(ck, b, "speed.fight_6_0", START_ANIMATION, _push32(0x40C00000), 1)
    _pin_bytes(ck, b, "speed.m2_1_0", START_ANIMATION, _push32(0x3F800000), 1)
    _pin_bytes(ck, b, "speed.idle_1_5", IDLE_STARTER, _push32(0x3FC00000), 1)
    _pin_bytes(ck, b, "loops.walk_and_m2_100000_x2", START_ANIMATION,
               _push32(100000), 2)
    _pin_bytes(ck, b, "speed.start_slot_0x2c_x3", START_ANIMATION,
               b"\xff\x55\x2c", 1)
    _pin_bytes(ck, b, "speed.start_slot_0x2c_x3_b", START_ANIMATION,
               b"\xff\x57\x2c", 2)
    _pin_bytes(ck, b, "speed.idle_start_slot_0x2c", IDLE_STARTER, b"\xff\x55\x2c", 1)
    _pin_bytes(ck, b, "fight.break_note", START_ANIMATION, _push32(0x004C0268), 1)
    _pin_calls(ck, b, "fight.break_callback", START_ANIMATION, A_NOTE_CALLBACK, 1)
    # §1.3 -- the refresh: four idle slots, the 60 m freeze, the sweep.
    idle_calls = _pin_calls(ck, b, "refresh.idle_slots", VIEW_REFRESH,
                            A_IDLE_START, 4)
    slots = []
    for site in idle_calls:
        # the slot is the second-to-last push: `push type; push slot`? no --
        # `push slot` is the last before the call for slots 2, 4, 5 and the
        # type-carrying slot 1 pushes `push 0x3d`/`-1` first.
        window = b.pe.bytes_at(site - 12, 12)
        pushes = [window[i + 1] for i in range(len(window) - 1) if window[i] == 0x6A]
        slots.append(pushes[-1] if pushes else None)
    ck.check("refresh.idle_slots_are_1_2_4_5", slots == [1, 2, 4, 5], str(slots))
    _pin_bytes(ck, b, "refresh.boss_type_61_in_C118", VIEW_REFRESH, _push8(0x3D), 1)
    _pin_bytes(ck, b, "refresh.C118_string", VIEW_REFRESH, b"\xbe\x70\x04\x4c\x00", 1)
    _pin_bytes(ck, b, "refresh.freeze_above_96000", VIEW_REFRESH,
               b"\x3d\x00\x77\x01\x00", 1)
    # What is compared is the third output of `0x00403750(&px, &py, &pz)`
    # -- the camera **eye's z**: the three locals are pushed x, y, z and
    # `[esp+0x10]`, the last, is the one the compare reads.
    _pin_calls(ck, b, "refresh.freeze_reads_camera_position", VIEW_REFRESH,
               A_CAMERA_POSITION, 1)
    _pin_at(ck, b, "refresh.freeze_compares_third_output", 0x0040703F,
            b"\x8d\x44\x24\x10\x8d\x4c\x24\x14\x8d\x54\x24\x18\x50\x51\x52")
    _pin_at(ck, b, "refresh.freeze_reads_esp_0x10", 0x004070EC, b"\x8b\x44\x24\x14")
    _pin_bytes(ck, b, "refresh.simulate_1_0", VIEW_REFRESH, _push32(0x3F800000), 1)
    _pin_bytes(ck, b, "refresh.simulate_slot_0x40", VIEW_REFRESH, b"\xff\x50\x40", 1)
    _pin_bytes(ck, b, "refresh.knocked_down_model", VIEW_REFRESH,
               _push32(0x004C0464), 1)                       # "A_BLIB.3DI"
    _pin_calls(ck, b, "refresh.blob_sweep", VIEW_REFRESH, A_BLOB_SWEEP, 1)
    # §6.1 -- the starter.
    _pin_calls(ck, b, "idle.animation_level_option", IDLE_STARTER, A_ANIM_LEVEL, 1)
    _pin_calls(ck, b, "idle.frees_the_slot", IDLE_STARTER, A_FREE_ANIM, 1)
    _pin_calls(ck, b, "idle.random_unit", IDLE_STARTER, A_RANDOM2, 1)
    _pin_calls(ck, b, "idle.selector", IDLE_STARTER, A_IDLE_SELECT, 1)
    _pin_bytes(ck, b, "idle.length_stored", IDLE_STARTER,
               b"\xd9\x9f\x44\xa8\x4f\x00", 1)               # fstp [edi+0x4fa844]
    _pin_bytes(ck, b, "idle.length_slot_0x24", IDLE_STARTER, b"\xff\x55\x24", 1)
    # §6.2 -- freeing detaches through the model's slot 2.
    _pin_bytes(ck, b, "idle.free_calls_model_slot_2", FREE_ANIMATION,
               b"\xff\x50\x08", 1)
    _pin_calls(ck, b, "idle.free_clears_unit_slot", FREE_ANIMATION,
               UNIT_ANIMATION_CLEAR, 1)
    # §6.3 -- **what `+0x56` is.**  `docs/10`:596 read the byte as a runtime
    # sound-channel back-reference; it is the unit's running **Charisma
    # animation handle**.  Three accessors and three witnesses, all here:
    # the starter writes it, `aFreeCHAnimation` clears it, and the reader's
    # answer is handed straight to `aContCHAnimation` `0x004054D0` as its
    # only argument -- an animation call, not a sound one.  Nothing in the
    # image passes it to a sound routine.  The burst creators of `docs/28`
    # §8.1.1 read the same byte as "is this shooter animating", which is the
    # same fact from the other side.
    _pin_at(ck, b, "idle.slot_writer", UNIT_ANIMATION_SET,
            bytes.fromhex("8b4c24048a442408884156c3"))
    _pin_at(ck, b, "idle.slot_clearer", UNIT_ANIMATION_CLEAR,
            bytes.fromhex("8b442404c640560" "0c3"))
    _pin_calls(ck, b, "idle.starter_sets_unit_slot", IDLE_STARTER,
               UNIT_ANIMATION_SET, 1)
    _pin_at(ck, b, "idle.slot_feeds_cont_animation", UNIT_ANIMATION_TO_CONT,
            bytes.fromhex("25ff00000050"))
    ck.check("idle.slot_is_continued_as_an_animation",
             b.pe.u8(UNIT_ANIMATION_TO_CONT + 6) == 0xE8
             and UNIT_ANIMATION_TO_CONT + 11
             + b.pe.i32(UNIT_ANIMATION_TO_CONT + 7) == A_CONT_ANIMATION,
             "the byte read from +0x56 is aContCHAnimation's argument")
    # §6.1 -- the type search compares unit 0's type two hundred times and
    # never advances, so the argument is dead and the draw decides (measured
    # by presentation_gold's idle_random phase).
    _pin_at(ck, b, "idle.type_search_does_not_advance", STARTER_LOOP, STARTER_LOOP_BYTES)
    _pin_at(ck, b, "idle.draw_is_0_200", STARTER_RANDOM_PUSHES, _push32(200) + _push8(0))
    # §1.2 -- the length: KeyFramedAnimation::Init asks the first movement
    # (slot 0xC of its own list, index 0) for IMovement slot 0x2C and stores
    # the answer at +0x60; the movement classes answer the last key's +4.
    _pin_at(ck, b, "length.first_movement_slot_0x0c", 0x004A0B6C, b"\xff\x50\x0c")
    _pin_at(ck, b, "length.movement_slot_0x2c", 0x004A0B8D, b"\xff\x50\x2c")
    _pin_at(ck, b, "length.stored_at_0x60", 0x004A0B90, b"\x8b\x45\xcc\xd9\x58\x60")
    for name, (vtable, fn) in MOVEMENT_VTABLES.items():
        ck.check(f"length.{name}_slot_0x2c", b.u32(vtable + MOVEMENT_LENGTH_SLOT) == fn,
                 hex(b.u32(vtable + MOVEMENT_LENGTH_SLOT)))
        ck.check(f"length.{name}_rtti", _rtti_name(b, vtable)[0] == f".?AV{name}@@",
                 str(_rtti_name(b, vtable)))
    # the last key: `(count - 1) * stride` through +0x74 / +0x78, then the
    # key's slot 0x14, which is `fld dword [ecx + 4]` -- its time.
    _pin_bytes(ck, b, "length.last_key_count_at_0x74", (0x004A8873, 0x004A88CB),
               b"\x8b\x40\x74", 1)
    _pin_bytes(ck, b, "length.keys_at_0x78", (0x004A8873, 0x004A88CB), b"\x03\x41\x78", 1)
    _pin_bytes(ck, b, "length.key_slot_0x14", (0x004A8873, 0x004A88CB), b"\xff\x52\x14", 1)
    for name, (vtable, fn) in KEY_VTABLES.items():
        ck.check(f"length.{name}_slot_0x14", b.u32(vtable + KEY_TIME_SLOT) == fn,
                 hex(b.u32(vtable + KEY_TIME_SLOT)))
        _pin_bytes(ck, b, f"length.{name}_time_is_plus_4", (fn, fn + 0x20), b"\xd9\x40\x04", 1)
    # §1.2 -- the start slot's class: the starters cast to
    # KeyFramedAnimationInterface, implemented by KeyFramedAnimation's
    # sub-object at +80; its slot 0x2C writes +0x14 of that sub-object --
    # +0x64, the speed -- and re-runs Update(0); 0x24 reads +0x10 (+0x60,
    # the length); 0x18 zeroes +8 (+0x58, the time).
    ck.check("interface.abstract_rtti",
             _rtti_name(b, KEYFRAMED_INTERFACE_ABSTRACT) == (".?AVKeyFramedAnimationInterface@@", 0),
             str(_rtti_name(b, KEYFRAMED_INTERFACE_ABSTRACT)))
    ck.check("interface.implementation_rtti",
             _rtti_name(b, KEYFRAMED_INTERFACE_VTABLE) == (".?AVKeyFramedAnimation@@", 80),
             str(_rtti_name(b, KEYFRAMED_INTERFACE_VTABLE)))
    for slot, fn in INTERFACE_SLOTS.items():
        ck.check(f"interface.slot_0x{slot:02x}", b.u32(KEYFRAMED_INTERFACE_VTABLE + slot) == fn,
                 hex(b.u32(KEYFRAMED_INTERFACE_VTABLE + slot)))
    _pin_bytes(ck, b, "interface.set_speed_writes_0x14", (0x004A0EBB, 0x004A0EED),
               b"\x8b\x4d\x08\x89\x48\x14", 1)
    _pin_bytes(ck, b, "interface.set_speed_updates", (0x004A0EBB, 0x004A0EED),
               b"\x83\xe9\x50\xff\x50\x38", 1)
    _pin_bytes(ck, b, "interface.get_length_reads_0x10", (0x004A0E83, 0x004A0E9F), b"\xd9\x40\x10", 1)
    _pin_bytes(ck, b, "interface.rewind_zeroes_0x08", (0x004A0E1A, 0x004A0E4B),
               b"\xc7\x40\x08\x00\x00\x00\x00", 1)
    ck.check("interface.part_and_model_rtti",
             _rtti_name(b, PART_VTABLE) == (".?AVV100Part@@", 0)
             and _rtti_name(b, MODEL_VTABLE) == (".?AVV100Model@@", 0), "")


def _check_fight(ck: Checker, b: Binary) -> None:
    # §4 -- the reaction flag is aAttackUnit's fifth argument.
    _pin_at(ck, b, "fight.reaction_flag_forwarded", 0x0046C16A,
            b"\x8b\x84\x24\x84\x00\x00\x00")
    _pin_calls(ck, b, "fight.called_by_attack", ATTACK_UNIT, A_FIGHT, 1)
    # §4.1
    _pin_calls(ck, b, "fight.clip_started", FIGHT, A_START_ANIM, 1)
    _pin_calls(ck, b, "fight.adjacent_test", FIGHT, A_DISTANCE, 2)
    _pin_calls(ck, b, "fight.remaining_frames", FIGHT, A_REMAINING, 3)
    # §4.2 -- the caption format and the text ids.
    _pin_bytes(ck, b, "fight.caption_format", FIGHT, _push32(0x004C11D4), 1)
    for name, tid in (("received", 0x11), ("experience_points", 0x12),
                      ("missed", 0x0A), ("paralyzed", 0x13)):
        _pin_bytes(ck, b, f"fight.text_{name}", FIGHT, _push8(tid), 1, at_least=True)
    _pin_bytes(ck, b, "text_bank_3_is_txtmod_h", TEXT_BANKS,
               _push32(0x004C5F74) + _push8(3), 1)
    off = b.pe.va_to_off(EMPTY_CAPTION)
    ck.check("fight.empty_caption_is_zero",
             off is None or b.pe.bytes_at(EMPTY_CAPTION, 4) == b"\0\0\0\0")
    # §4.3 -- the camera.
    _pin_bytes(ck, b, "fight.screen_y_max_99", FIGHT, b"\x83\xf8\x64", 1)
    _pin_at(ck, b, "fight.screen_y_min_21", 0x0040C2C3, b"\x83\xf8\x14")
    _pin_bytes(ck, b, "fight.height_gap_0x12c0", FIGHT, b"\x3d\xc0\x12\x00\x00", 1)
    _pin_bytes(ck, b, "fight.large_type_5600_x3", FIGHT, b"\xb8\xe0\x15\x00\x00", 3)
    _pin_calls(ck, b, "fight.direction", FIGHT, A_DIRECTION, 3)
    _pin_calls(ck, b, "fight.reaction_position", FIGHT, A_REACTION_POS, 2)
    _pin_calls(ck, b, "fight.reaction_coin", FIGHT, A_RANDOM2, 1)
    # The reaction camera's numbers, both arms (`0x0040C08E`, `0x0040C1C8`):
    # 2400 in `eax` is what the horizontal direction is scaled by (`fild
    # [esp+0x14]`, `fmul [esp+0x34]`), 4800 in `[esp+0x1c]` what the slope
    # is (`fild [esp+0x20]` after the push, `fmul [esp+0x60]`); 5600 and
    # 8000 for a large type behind.
    for name, va in (("first", 0x0040C08E), ("second", 0x0040C1C8)):
        _pin_at(ck, b, f"fight.reaction_{name}.back_2400_slope_4800", va,
                b"\xb8\x60\x09\x00\x00\xc7\x44\x24\x1c\xc0\x12\x00\x00")
    for name, va in (("first", 0x0040C0A5), ("second", 0x0040C1DF)):
        _pin_at(ck, b, f"fight.reaction_{name}.large_5600_8000", va,
                b"\xb8\xe0\x15\x00\x00\xc7\x44\x24\x1c\x40\x1f\x00\x00")
    _pin_at(ck, b, "fight.reaction_first.back_scales_direction", 0x0040C0BA,
            b"\xdb\x44\x24\x14\xdc\x4c\x24\x34")
    _pin_at(ck, b, "fight.reaction_first.slope_term", 0x0040C0E8,
            b"\xdb\x44\x24\x20")
    _pin_at(ck, b, "fight.reaction_first.slope_times_third", 0x0040C0F3,
            b"\xdc\x4c\x24\x60")
    _pin_bytes(ck, b, "reaction_pos.neighbour_limit_16000", REACTION_POS,
               b"\x80\x3e\x00\x00", 1, at_least=True)
    _pin_bytes(ck, b, "reaction_pos.plus_800", REACTION_POS,
               b"\x20\x03\x00\x00", 1, at_least=True)
    _pin_bytes(ck, b, "reaction_pos.no_unit_plus_3200", REACTION_POS,
               b"\x80\x0c\x00\x00", 1, at_least=True)
    _pin_calls(ck, b, "fight.flight", FIGHT, A_FLIGHT, 1)
    # §4.4 -- the markers and the colour.
    _pin_bytes(ck, b, "fight.marker_0x5a_x2", FIGHT, b"\x3c\x5a", 2)
    _pin_bytes(ck, b, "fight.marker_0x5d_x2", FIGHT, b"\x3c\x5d", 2)
    _pin_bytes(ck, b, "fight.text_colour_0x5acb_x5", FIGHT,
               b"\x66\xc7\x06\xcb\x5a", 5)
    # §4.5 -- the death screams.
    for name, va in (("SP_HUM_0", 0x004C1124), ("SP_HUM_1", 0x004C1134),
                     ("SP_HUM_2", 0x004C1144)):
        _pin_bytes(ck, b, f"fight.scream_{name}_x2", FIGHT, _push32(va), 2)
    # docs/42 §4.5 -- the three unit types the voice arm silences, read at
    # `+0x4C` **after** the round robin that picked the wave, so the cursor
    # moves and only the play is skipped.
    _pin_at(ck, b, "fight.voice_reads_the_type", 0x0040CBDF, b"\x8a\x40\x4c")
    _pin_at(ck, b, "fight.voice_mutes_22", 0x0040CBE2, b"\x3c\x16")
    _pin_at(ck, b, "fight.voice_mutes_25_and_26", 0x0040CBE6,
            b"\x3c\x18\x76\x06\x3c\x1a\x77\x02")
    _pin_bytes(ck, b, "fight.scream_species_3_explosion", FIGHT,
               _push32(0x004C1154), 1, at_least=True)
    # §4.6 -- the projectile wait and the flag.
    _pin_bytes(ck, b, "fight.wait_100_frames", FIGHT, b"\x83\xf9\x64", 1)
    _pin_calls(ck, b, "fight.arrived_flag", FIGHT, A_ARRIVED, 1)
    # The flag's writers are pinned by control flow in
    # `_check_fight_corrections`: the nearest-arm-start attribution that
    # stood here counted arm 45's *clear* and missed the two arms that enter
    # a store from another arm's tail.
    # §4.8 -- the death switch's creators and the hide.
    for name, va in DEATH_CREATORS.items():
        n = len(b.calls(FIGHT, va))
        ck.check(f"fight.death.{name}", n >= 1, f"{n} calls")
    _pin_calls(ck, b, "fight.death.hide_x2", FIGHT, A_HIDE, 2)
    # §4.8 -- what the four unnamed creators build (docs/42 §4.8.1).
    _pin_bytes(ck, b, "death.blood_burst.kind_17_life_15", BLOOD_BURST, _push8(0xF) + _push8(0x11), 1)
    _pin_bytes(ck, b, "death.blood_burst.kind_43_life_15", BLOOD_BURST, _push8(0xF) + _push8(0x2B), 1)
    _pin_bytes(ck, b, "death.blood_burst.model", BLOOD_BURST, _push32(0x004C22B4), 2)   # A_BLUT4
    _pin_calls(ck, b, "death.blood_burst.gore_x2", BLOOD_BURST, A_GORE_LEVEL, 2)
    _pin_calls(ck, b, "death.blood_burst.puff", BLOOD_BURST, DEATH_PUFF[0], 2)
    _pin_bytes(ck, b, "death.puff.kind_59_life_20", DEATH_PUFF, _push8(0x14) + _push8(0x3B), 1)
    _pin_bytes(ck, b, "death.barrel_burst.kind_5_life_100", BARREL_BURST, _push8(0x64) + _push8(0x05), 1)
    _pin_bytes(ck, b, "death.blood_spray_large.kind_50_life_8", BLOOD_SPRAY_LARGE, _push8(0x08) + _push8(0x32), 1)
    _pin_bytes(ck, b, "death.blood_flood.kind_60_life_8_x2", BLOOD_FLOOD, _push8(0x08) + _push8(0x3C), 2)
    _pin_bytes(ck, b, "death.blood_flood.kind_17_life_8_x2", BLOOD_FLOOD, _push8(0x08) + _push8(0x11), 2)
    _pin_calls(ck, b, "death.blood_flood.gore", BLOOD_FLOOD, A_GORE_LEVEL, 1)
    _pin_bytes(ck, b, "death.species_burst.splat5_kind_18_life_30_x3", SPECIES_BURST,
               _push8(0x1E) + _push8(0x12), 3)
    _pin_bytes(ck, b, "death.species_burst.puffs_kind_51_life_16_x2", SPECIES_BURST,
               _push8(0x10) + _push8(0x33), 2)
    _pin_bytes(ck, b, "death.species_burst.piece_kind_18_life_50", SPECIES_BURST,
               _push8(0x32) + _push8(0x12), 1)
    _pin_at(ck, b, "death.species_burst.coin_6_0", 0x00421DFB, b"\xdc\x1d\x68\x12\x4b\x00")
    _pin_calls(ck, b, "death.species_burst.gore_x2", SPECIES_BURST, A_GORE_LEVEL, 2)
    _pin_calls(ck, b, "death.species_burst.blood_flood_x2", SPECIES_BURST, 0x00420D80, 2)
    _pin_calls(ck, b, "death.species_burst.flying_debris_x2", SPECIES_BURST, 0x004216D0, 2)
    for name, va in (("A_50A", 0x004C2388), ("A_51A", 0x004C2364), ("A_56A", 0x004C2340),
                     ("A_57A", 0x004C2334)):
        _pin_bytes(ck, b, f"death.species_burst.model_{name}", SPECIES_BURST,
                   struct.pack("<I", va), 1)
    _pin_bytes(ck, b, "death.flying_debris.kind_18_life_50_x2", FLYING_DEBRIS,
               _push8(0x32) + _push8(0x12), 1, at_least=True)
    _pin_bytes(ck, b, "death.flying_debris.kind_18_life_30", FLYING_DEBRIS,
               _push8(0x1E) + _push8(0x12), 1, at_least=True)
    for va, value in BLOOD_DOUBLES.items():
        ck.check(f"death.double_{va:08x}_is_{value}", b.pe.f64(va) == value, str(b.pe.f64(va)))
    # The gore level: six reads in four routines, and what level 2 tests.
    sites = set(b.calls(TEXT, A_GORE_LEVEL))
    ck.check("gore.readers", sites == GORE_READERS, str(sorted(hex(x) for x in sites)))
    ck.check("gore.readers_in_four_routines",
             all(any(lo <= site < hi for lo, hi in GORE_READER_RANGES) for site in sites), "")
    _pin_bytes(ck, b, "gore.level_2_tests_player_0xff", BLOOD_BURST, GORE_PLAYER_TEST, 1)
    _pin_bytes(ck, b, "gore.level_1_test", BLOOD_BURST, b"\x83\xf8\x01", 1)
    _pin_bytes(ck, b, "gore.level_2_test", BLOOD_BURST, b"\x83\xf8\x02", 1)
    # §4.9 -- the end.
    _pin_at(ck, b, "fight.end_min_20_frames", 0x0040E256, b"\x83\xf8\x14")
    _pin_calls(ck, b, "fight.end_pool_empty", FIGHT, A_ALIVE, 2)
    _pin_calls(ck, b, "fight.end_resumes_clip", FIGHT, A_CONT_ANIM, 1)
    # §1.1 -- the tick's overlay: caption at (80, 54), rise by 2, fade.
    _pin_bytes(ck, b, "tick.caption_at_80_54", FRAME_TICK, _push8(0x36) + _push8(0x50), 1)
    _pin_bytes(ck, b, "tick.text_rises_2px", FRAME_TICK, b"\x83\xc2\xfe", 1)
    _pin_bytes(ck, b, "tick.fade_reads_countdown", FRAME_TICK,
               b"\xa1\xa0\xc0\x4f\x00", 3)
    _pin_bytes(ck, b, "tick.skip_controller_10_20", FRAME_TICK,
               _push8(0x14) + _push8(0x0A), 1)


def _muzzle_arm_writes(b: Binary) -> dict[int, tuple[int | None, int | None]]:
    """Per muzzle arm: what it writes over `[esp+0x1C]` and `[esp+0x10]`.

    Scans each arm up to the next arm's start for the compiler's two forms --
    an immediate store and a register store of the `1` in `ebx` or the `0` in
    `edi` -- which is exact here because every arm is laid out contiguously
    and ends in a `jmp` to one of the two exits.
    """
    arms = sorted({b.u32(MUZZLE_JUMP + 4 * i) for i in range(MUZZLE_ARMS)})
    ends = arms[1:] + [IMPACT_SWITCH_ENTRY]
    out: dict[int, tuple[int | None, int | None]] = {}
    for start, end in zip(arms, ends):
        code = b.span(start, end)
        style: int | None = None
        wait: int | None = None
        for i in range(len(code) - 3):
            if code[i:i + 4] == b"\xc7\x44\x24\x1c":
                style = struct.unpack_from("<i", code, i + 4)[0]
            elif code[i:i + 4] == b"\x89\x5c\x24\x1c":       # mov [esp+0x1c], ebx (1)
                style = 1
            elif code[i:i + 4] == b"\xc7\x44\x24\x10":
                wait = struct.unpack_from("<i", code, i + 4)[0]
            elif code[i:i + 4] == b"\x89\x7c\x24\x10":       # mov [esp+0x10], edi (0)
                wait = 0
        out[start] = (style, wait)
    return out


def _check_fight_corrections(ck: Checker, b: Binary) -> None:
    """What a second reading of `aPlayFightAnimation` corrected on 2026-09-03."""
    # --- the arrived flag: fourteen setters, one clearer ----------------
    lo, hi = BLOB_UPDATE
    blob = b.span(lo, hi)
    one = b"\xc7\x05" + struct.pack("<I", ARRIVED_FLAG) + struct.pack("<I", 1)
    sets = []
    start = 0
    while True:
        i = blob.find(one, start)
        if i < 0:
            break
        sets.append(lo + i)
        start = i + 1
    ck.check("arrived.update_stores_of_1", len(sets) == ARRIVED_SET_STORES,
             str([hex(x) for x in sets]))
    _pin_at(ck, b, "arrived.kind_45_stores_ebp", ARRIVED_KIND_45_STORE,
            b"\x89\x2d" + struct.pack("<I", ARRIVED_FLAG))
    # `ebp` is the sweep's zero: arm 2 pushes it as `aRandom2(0, 0x1000)`'s
    # base three times over.
    _pin_at(ck, b, "arrived.ebp_is_the_zero_base", 0x0041E7A7,
            b"\x68\x00\x10\x00\x00\x55")
    _pin_at(ck, b, "arrived.kind_2_tests_life_then_shares_49s_store",
            ARRIVED_KIND_2_TAIL[0], b"\x0f\x85\xbd\x1f\x00\x00\x68\x90\x01\x00\x00\x55" + one)
    arms = [b.u32(BLOB_JUMP_TABLE + 4 * i) for i in range(BLOB_KINDS)]
    starts = sorted(set(arms))
    def arm_of(site: int) -> set[int]:
        arm = max(s for s in starts if s <= site)
        return {k for k, a in enumerate(arms) if a == arm}
    ck.check("arrived.kind_61_shares_28s_store", arm_of(ARRIVED_KIND_61_STORE) == {28},
             str(arm_of(ARRIVED_KIND_61_STORE)))
    # Arm 61's last instruction is a plain store, and the next byte is arm
    # 28's start: the seeker falls into the tail that sets the flag.
    _pin_at(ck, b, "arrived.kind_61_falls_into_28", ARRIVED_KIND_61_FALLS_INTO_28,
            b"\xc6\x46\x45\x00\x8a\x46\x45\x84\xc0\x0f\x85\x28\x03\x00\x00" + one)
    ck.check("arrived.kind_28_starts_at_the_shared_tail",
             b.u32(BLOB_JUMP_TABLE + 4 * 28) == ARRIVED_KIND_61_FALLS_INTO_28 + 4,
             hex(b.u32(BLOB_JUMP_TABLE + 4 * 28)))
    ck.check("arrived.kind_45_owns_the_clear", arm_of(ARRIVED_KIND_45_STORE) == {ARRIVED_CLEAR_KIND},
             str(arm_of(ARRIVED_KIND_45_STORE)))
    by_start = set()
    for site in sets:
        by_start |= arm_of(site)
    # The nearest-start attribution reaches every setter but the two that
    # enter a store from another arm; with those added the set is pinned.
    ck.check("arrived.setters_by_flow", by_start | {2, 61} == ARRIVED_KINDS
             and not by_start & {2, 61}, str(sorted(by_start)))
    # The creators' writes, outside the update's range.
    text = b.span(*TEXT)
    stores = {"set": 0, "clear": 0, "computed": 0}
    flag = struct.pack("<I", ARRIVED_FLAG)
    i = 0
    while True:
        i = text.find(flag, i)
        if i < 0:
            break
        va = TEXT[0] + i
        if not lo <= va < hi:
            head = text[i - 2:i]
            if head == b"\xc7\x05":
                value = struct.unpack_from("<I", text, i + 4)[0]
                stores["set" if value == 1 else "clear"] += 1
            elif head[1:] in (b"\x2d", b"\x3d", b"\x1d", b"\x0d") and head[0] == 0x89:
                stores["computed"] += 1
            elif text[i - 1] == 0xA3:
                stores["computed"] += 1
        i += 4
    ck.check("arrived.creator_writes", stores == ARRIVED_CREATOR_WRITES, str(stores))

    # --- the death style is the muzzle arm's, not the severity ----------
    _pin_at(ck, b, "fight.severity_slot_zeroed_before_muzzle", 0x0040CC3C,
            b"\x33\xff\x83\xc0\xfe\xbb\x01\x00\x00\x00\x83\xf8\x2d\x89\x7c\x24\x1c\x89\x5c\x24\x10")
    _pin_at(ck, b, "fight.death_switch_reads_the_slot", 0x0040DD05,
            b"\x8b\x4c\x24\x1c\x49")
    _pin_at(ck, b, "fight.wait_flag_read_before_the_loop", 0x0040D4B1,
            b"\x8b\x44\x24\x14")
    writes = _muzzle_arm_writes(b)
    index = list(b.span(MUZZLE_INDEX, MUZZLE_INDEX + MUZZLE_WEAPONS))
    style_by_weapon = {}
    wait_skipped = set()
    for w in range(MUZZLE_WEAPON_FIRST, MUZZLE_WEAPON_FIRST + MUZZLE_WEAPONS):
        arm = b.u32(MUZZLE_JUMP + 4 * index[w - MUZZLE_WEAPON_FIRST])
        style, wait = writes[arm]
        if style:
            style_by_weapon[w] = style
        if wait == 0:
            wait_skipped.add(w)
    ck.check("fight.death_style_by_weapon", style_by_weapon == DEATH_STYLE_BY_WEAPON,
             str(sorted(style_by_weapon.items())))
    ck.check("fight.wait_skipped_weapons", wait_skipped == WAIT_SKIPPED_WEAPONS,
             str(sorted(wait_skipped)))
    ck.check("fight.muzzle_default_arm_writes_nothing",
             writes.get(MUZZLE_DEFAULT_ARM) == (None, None), str(writes.get(MUZZLE_DEFAULT_ARM)))
    # The damage arm reads the **last marked unit's** player and type
    # (`ebp` is `[esp+0x34]`, the sweep's unit), not a stale local: the
    # encodings are `[ebp+0x45]` and `[ebp+0x4C]`.
    _pin_at(ck, b, "fight.damage_arm_reads_target_player", 0x0040E01D, b"\x80\x7d\x45\xff")
    _pin_at(ck, b, "fight.damage_arm_reads_target_type", 0x0040E025, b"\x8a\x45\x4c")
    _pin_at(ck, b, "fight.damage_arm_large_flag", 0x0040E02F, b"\x8a\x04\x55\x9b\xc0\x51\x00")
    # The death switch's own tests: special 0x10, 0x0C and 0x0D, and the
    # size flag `bl`.
    _pin_at(ck, b, "fight.death_special_0x10", 0x0040DCCD, b"\x80\xb8\x27\xc0\x51\x00\x10")
    _pin_at(ck, b, "fight.death_special_0x0c_0x0d", 0x0040DB1B, b"\x83\xe8\x0c\x74\x39\x48")
    _pin_at(ck, b, "fight.death_size_flag", 0x0040DC95, b"\x8a\x1c\x4d\x9b\xc0\x51\x00")
    # The end: at most twenty ticks while the pool lives, then the resume
    # unless type 0x37 or slot 0x0B, then ticks while the pool, the clip or
    # the fade is still going.
    _pin_at(ck, b, "fight.end_wait_is_at_most_20_while_alive", 0x0040E256,
            b"\x83\xf8\x14\x7d\x09\xe8\x40\xd2\x01\x00\x85\xc0\x75\xea")
    _pin_at(ck, b, "fight.end_resume_skips_type_0x37", 0x0040E272, b"\x80\x7e\x4c\x37")
    _pin_at(ck, b, "fight.end_resume_skips_slot_0x0b", 0x0040E28E, b"\x3c\x0b")
    _pin_at(ck, b, "fight.end_loop_pool_clip_fade", 0x0040E2F8,
            b"\xe8\xa3\xd1\x01\x00\x85\xc0\x75\xf1\x85\xff\x7f\xed\xa1\xa0\xc0\x4f\x00\x85\xc0\x7f\xe4")
    # --- the three creators the second capture reached ------------------
    _pin_bytes(ck, b, "death.kill_fire.kind_10_life_20", KILL_FIRE, _push8(0x14) + _push8(0x0A), 1)
    _pin_bytes(ck, b, "death.kill_fire.aux_20", KILL_FIRE, b"\x50\x6a\x14\x53\x55\x57", 1)
    _pin_bytes(ck, b, "death.kill_fire.ten_flames", KILL_FIRE, b"\xc7\x44\x24\x18\x0a\x00\x00\x00", 1)
    _pin_bytes(ck, b, "death.kill_fire.drift_x2", KILL_FIRE, _push8(0x60) + _push8(-0x30 & 0xFF), 2)
    _pin_bytes(ck, b, "death.kill_fire.rise", KILL_FIRE, _push32(0xA0) + _push32(0x140), 1)
    _pin_bytes(ck, b, "death.kill_fire.delay_draw", KILL_FIRE, _push8(3) + _push8(0), 1)
    _pin_bytes(ck, b, "death.kill_fire.scatter_x3", KILL_FIRE,
               _push32(0x640) + _push32(0xFFFFFCE0), 3)
    _pin_at(ck, b, "death.kill_fire.delay_adds_argument", 0x00423B91, b"\x02\x44\x24\x1c")
    _pin_at(ck, b, "fight.kill_fire_delay_0", 0x0040DCE2, b"\x6a\x00\x50\x51\xe8\xe5\x5d\x01\x00")
    _pin_at(ck, b, "fire_circle.kill_fire_delay_20", 0x0041332C, b"\x6a\x14\x52\x50\xe8")
    _pin_bytes(ck, b, "death.fire_death.kind_60_life_8", FIRE_DEATH, _push8(8) + _push8(0x3C), 1)
    _pin_bytes(ck, b, "death.fire_death.row_4", FIRE_DEATH, b"\x6a\x00\x6a\x00\x03\xd7\x6a\x04", 1)
    _pin_bytes(ck, b, "death.fire_death.drift_x2", FIRE_DEATH, _push32(0x3C0) + _push32(0xFFFFFE20), 2)
    _pin_bytes(ck, b, "death.fire_death.rise", FIRE_DEATH, _push32(0x640) + _push32(0xA0), 1)
    _pin_bytes(ck, b, "death.fire_death.aux_5_20", FIRE_DEATH, _push8(0x14) + _push8(5), 1)
    _pin_at(ck, b, "death.fire_death.step_20_to_400", 0x0042B2D5,
            b"\x83\xc7\x14\x42\x81\xff\x90\x01\x00\x00")
    _pin_bytes(ck, b, "death.flying_unit.kind_3_life_10_up_800", FLYING_UNIT,
               _push32(0x320) + _push8(0) + _push8(0) + _push8(0x0A) + _push8(3), 1)
    _pin_at(ck, b, "death.flying_unit.model_is_the_types", 0x004297CA,
            b"\x8d\x04\x55\x8c\xc0\x51\x00")
    _pin_at(ck, b, "fight.flying_unit_delay_is_size_x2", 0x0040DB68,
            b"\xd0\xe1\x51\x52\x50\xe8\x8e\xbb\x01\x00")
    # FireExplosion's third argument is pushed by all twelve callers and read
    # by none: the routine's frame names two (`[esp+8]` and `[esp+4]` only).
    ck.check("death.fire_explosion_callers_push_3",
             len(b.calls(TEXT, 0x00429A80)) == 13, str(len(b.calls(TEXT, 0x00429A80))))


def _check_others(ck: Checker, b: Binary) -> None:
    # §7.1 -- the jump.
    _pin_calls(ck, b, "jump.trail", JUMP, A_TRAIL, 1)
    _pin_calls(ck, b, "jump.landing_dust_x2", JUMP, A_LANDING_DUST, 2)
    _pin_calls(ck, b, "jump.camera_looks_at_flyer", JUMP, A_SET_CAMERA, 1)
    _pin_bytes(ck, b, "jump.gravity_160", JUMP, b"\x2d\xa0\x00\x00\x00", 1)
    _pin_bytes(ck, b, "jump.wave", JUMP, _push32(0x004C1384), 1)
    _pin_bytes(ck, b, "jump.drop_wave", JUMP, _push32(0x004C1378), 1)
    # §7.2 -- the push.
    _pin_calls(ck, b, "push.flight", PUSH, A_FLIGHT, 1)
    _pin_calls(ck, b, "push.dust_per_frame", PUSH, A_DUST, 1)
    _pin_bytes(ck, b, "push.four_frames_per_cell", PUSH, b"\x83\xf8\x04", 1)
    _pin_bytes(ck, b, "push.hole_50_steps", PUSH, b"\x83\xff\x32", 1)
    _pin_calls(ck, b, "push.dust_is_a_blob", PUSH_DUST, A_CTOR, 1)
    _pin_bytes(ck, b, "push.dust_life_20", PUSH_DUST, _push8(0x14), 1)
    # §7.3 -- the arrows.
    _pin_bytes(ck, b, "marker.model", ARROW_MARKER, _push32(0x004C2404), 1)
    _pin_bytes(ck, b, "marker.kind_14_life_15", ARROW_MARKER, _push8(0x0F) + _push8(0x0E), 1)
    _pin_bytes(ck, b, "marker.radius_large_9600", ARROW_MARKER, b"\xbf\x80\x25\x00\x00", 1)
    _pin_calls(ck, b, "marker.is_a_blob", ARROW_MARKER, A_CTOR, 1)
    # §7.5 -- the orbits: 40 frames, arrows or flash circle, a rotation step.
    for name, rng, arrows in (("skill", ORBIT_SKILL, True), ("jam", ORBIT_JAM, True),
                              ("overheat", ORBIT_OVERHEAT, True),
                              ("rotating", ORBIT_ROTATING, True),
                              ("heal", ORBIT_HEAL, False), ("poison", ORBIT_POISON, False)):
        _pin_bytes(ck, b, f"orbit.{name}.frames_40", rng, b"\x28\x00\x00\x00", 1, at_least=True)
        _pin_calls(ck, b, f"orbit.{name}.rotate_step", rng, A_ROTATE_VECTOR, 1)
        _pin_calls(ck, b, f"orbit.{name}.arrows", rng, A_ARROWS, 1 if arrows else 0)
    _pin_calls(ck, b, "orbit.heal.flash_circle", ORBIT_HEAL, A_FLASH_CIRCLE_HEAL, 1)
    _pin_calls(ck, b, "orbit.poison.flash_circle", ORBIT_POISON, A_FLASH_CIRCLE_POISON, 1)
    _pin_bytes(ck, b, "orbit.heal.step_minus_40", ORBIT_HEAL, b"\xd8\xff", 1, at_least=True)
    _pin_bytes(ck, b, "orbit.poison.step_minus_40", ORBIT_POISON, b"\xd8\xff", 1, at_least=True)
    _pin_bytes(ck, b, "orbit.heal.offset_0x1900", ORBIT_HEAL, b"\x81\xc6\x00\x19\x00\x00", 1)
    _pin_bytes(ck, b, "orbit.poison.offset_0x1900", ORBIT_POISON, b"\x81\xc6\x00\x19\x00\x00", 1)
    _pin_bytes(ck, b, "orbit.rotating.offset_0xc80", ORBIT_ROTATING, b"\x8d\xaf\x80\x0c\x00\x00", 1)
    for name, rng, tid in (("skill", ORBIT_SKILL, 3), ("heal", ORBIT_HEAL, 4),
                           ("poison", ORBIT_POISON, 5)):
        _pin_bytes(ck, b, f"orbit.{name}.text_id", rng, _push8(tid), 1, at_least=True)
    for tid in (0x0E, 0x0F, 0x10):
        _pin_bytes(ck, b, f"orbit.overheat.text_{tid}", ORBIT_OVERHEAT, _push8(tid), 1, at_least=True)
    _pin_calls(ck, b, "orbit.overheat.fire_explosion", ORBIT_OVERHEAT, 0x00429A80, 1)
    _pin_calls(ck, b, "orbit.overheat.blood", ORBIT_OVERHEAT, 0x00420D80, 1)
    _pin_calls(ck, b, "orbit.overheat.hide", ORBIT_OVERHEAT, A_HIDE, 1)
    _check_unit_animation_creators(ck, b)
    _check_marker_sites(ck, b)
    _check_command_arms(ck, b)
    _check_setpiece_cameras(ck, b)
    _check_setpiece_creators(ck, b)
    # §8 -- set pieces: the camera and the effects.
    _pin_calls(ck, b, "setpiece.door.flights_x2", DOOR, A_FLIGHT, 2)
    _pin_bytes(ck, b, "setpiece.door.frames_10", DOOR, b"\xbd\x0a\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.door.no_camera_on_minus_1", DOOR, b"\x83\xfe\xff", 2)
    _pin_calls(ck, b, "setpiece.elevator.flight", ELEVATOR, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.elevator.camera_per_frame", ELEVATOR, A_SET_CAMERA, 1)
    _pin_calls(ck, b, "setpiece.platform.flight", PLATFORM, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.platform.camera_per_frame", PLATFORM, A_SET_CAMERA, 1)
    _pin_calls(ck, b, "setpiece.platform.dust_per_frame", PLATFORM, A_PLATFORM_DUST, 1)
    _pin_calls(ck, b, "setpiece.barrier.flights_x2", BARRIER, A_FLIGHT, 2)
    _pin_calls(ck, b, "setpiece.barrier.beam", BARRIER, A_BEAM, 1)
    _pin_calls(ck, b, "setpiece.barrier.kill_effects", BARRIER, A_BARRIER_HIT_A, 1)
    _pin_calls(ck, b, "setpiece.barrier.kill_effects_b", BARRIER, A_BARRIER_HIT_B, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.free_position", GROUND_FIRE, A_FREE_POSITION, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.hide", GROUND_FIRE, A_HIDE, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.blood", GROUND_FIRE, 0x00420D80, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.debris", GROUND_FIRE, 0x004216D0, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.smoke", GROUND_FIRE, A_TUBE_SMOKE, 1)
    _pin_calls(ck, b, "setpiece.crush_wall.debris", CRUSH_WALL, A_WALL_DEBRIS, 1)
    # §8 -- the four set pieces transcribed line by line (docs/42 §8.1).
    _pin_bytes(ck, b, "setpiece.statue.box_10000_x3", STATUE, _push32(0x2710), 3)
    _pin_bytes(ck, b, "setpiece.statue.height_32000", STATUE, _push32(0x7D00), 1)
    _pin_bytes(ck, b, "setpiece.statue.frames_13", STATUE, b"\x0d\x00\x00\x00", 1, at_least=True)
    _pin_bytes(ck, b, "setpiece.statue.settle_plus_0x400", STATUE, b"\x81\xc2\x00\x04\x00\x00", 1)
    # §8.1 as corrected by §41: the walk examines **six** cells each way, not
    # five, and the counter is only advanced past the null and field-type-2
    # tests.  The rule half of both is `LclInterpreter._statue`.
    _pin_bytes(ck, b, "setpiece.statue.path_6_x2", STATUE, b"\x83\x7c\x24\x3c\x06", 2)
    # `0x00413C31`..`0x00413C40` -- the statue's own action-point byte toggles
    # bit 0, and the new bit picks the axis.
    _pin_at(ck, b, "setpiece.statue.actpt_toggle", 0x00413C31,
            b"\x8a\x43\x0b\xa8\x01\x74\x04\xfe\xc8\xeb\x02\xfe\xc0"
            b"\xa8\x01\x88\x43\x0b")
    # Two loss bookings, one per arm, beside the two `aRemoveUnitElement`
    # calls: the beam takes at most **one** unit each way.
    _pin_calls(ck, b, "setpiece.statue.loss_x2", STATUE, 0x0043B8D0, 2)
    _pin_calls(ck, b, "setpiece.statue.flight", STATUE, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.statue.fire_death_x2", STATUE, 0x0042B1D0, 2)
    _pin_calls(ck, b, "setpiece.statue.beam_x2", STATUE, 0x00428BF0, 2)
    _pin_calls(ck, b, "setpiece.statue.hide_x2", STATUE, A_HIDE, 2)
    _pin_calls(ck, b, "setpiece.statue.remove_x2", STATUE, 0x004779C0, 2)
    _pin_bytes(ck, b, "setpiece.statue2.height_32000", STATUE_2, _push32(0x7D00), 1)
    _pin_bytes(ck, b, "setpiece.statue2.path_10", STATUE_2, b"\x83\xf8\x0a", 1)
    # `Statue2` `0x004424B0` is a loop over an ActPt range, not a sequence of
    # its own: `0x00413500` calls `aPlayRotateStatueSequence` per matched cell.
    _pin_calls(ck, b, "setpiece.statue2.batch_loop", STATUE_2_BATCH,
               0x00413A40, 1)
    _pin_bytes(ck, b, "setpiece.statue2.batch_stride_23", STATUE_2_BATCH,
               b"\x83\xc6\x17", 1)
    _pin_calls(ck, b, "setpiece.statue2.beam", STATUE_2, 0x00428BF0, 1)
    _pin_bytes(ck, b, "setpiece.statue_beam.kind_62_life_7", STATUE_BEAM, _push8(0x07) + _push8(0x3E), 2)
    _pin_bytes(ck, b, "setpiece.statue_beam.dots_z_3200", STATUE_BEAM, _push32(0xC80), 2)
    _pin_bytes(ck, b, "setpiece.statue_beam.spark_spread_6000_x2", STATUE_BEAM, _push32(0x1770), 2)
    _pin_bytes(ck, b, "setpiece.statue_beam.spark_vz_800", STATUE_BEAM, _push32(0x320), 1)
    _pin_bytes(ck, b, "setpiece.statue_beam.sparks_6", STATUE_BEAM, b"\x83\xf8\x06", 1)
    for name, rng in (("footbridge", FOOTBRIDGE), ("footbridge2", FOOTBRIDGE_2)):
        _pin_bytes(ck, b, f"setpiece.{name}.tilt_draw_minus2_4", rng, _push8(4) + _push8(0xFE), 1)
        _pin_bytes(ck, b, f"setpiece.{name}.block_drop_3360", rng, b"\x81\xe9\x20\x0d\x00\x00", 1)
        _pin_bytes(ck, b, f"setpiece.{name}.camera_drop_2400", rng, b"\x81\xea\x60\x09\x00\x00", 1)
        _pin_bytes(ck, b, f"setpiece.{name}.rider_drop_3200", rng, b"\x2d\x80\x0c\x00\x00", 1)
        _pin_bytes(ck, b, f"setpiece.{name}.rider_drawn_160_up", rng, b"\x05\xa0\x00\x00\x00",
                   1 if name == "footbridge" else 3)
        _pin_bytes(ck, b, f"setpiece.{name}.rider_tilt_25_12", rng, b"\xbb\x0c\x00\x00\x00", 1)
        _pin_calls(ck, b, f"setpiece.{name}.flights_x2", rng, A_FLIGHT, 2)
        _pin_calls(ck, b, f"setpiece.{name}.camera_per_frame", rng, A_SET_CAMERA, 2)
        _pin_calls(ck, b, f"setpiece.{name}.rotation_read_write", rng, 0x00405180, 1)
        _pin_calls(ck, b, f"setpiece.{name}.rotation_write", rng, 0x004051E0, 1)
        _pin_calls(ck, b, f"setpiece.{name}.riders_removed", rng, 0x004779C0, 1)
        _pin_calls(ck, b, f"setpiece.{name}.tilt_draw", rng, A_RANDOM2, 1)
    _pin_bytes(ck, b, "setpiece.footbridge.tilt_x17", FOOTBRIDGE, b"\xc1\xe7\x04", 1)
    _pin_bytes(ck, b, "setpiece.footbridge2.tilt_x17", FOOTBRIDGE_2, b"\xc1\xe0\x04", 1)
    _pin_bytes(ck, b, "setpiece.footbridge2.box_500_500_12800", FOOTBRIDGE_2,
               _push32(0x3200) + _push32(0x1F4) + _push32(0x1F4), 2)
    _pin_bytes(ck, b, "setpiece.ground_unit.rise_1120", GROUND_UNIT, b"\x81\xc6\x60\x04\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.start_3200_down", GROUND_UNIT, b"\x81\xee\x80\x0c\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.frames_8", GROUND_UNIT, b"\x83\xfb\x07", 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.fifths_x3", GROUND_UNIT, b"\xb8\x67\x66\x66\x66", 3)
    _pin_bytes(ck, b, "setpiece.ground_unit.scream_wait_4", GROUND_UNIT,
               b"\xc7\x44\x24\x2c\x04\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.exit_model", GROUND_UNIT, _push32(0x004C13F8), 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.debris_1600_up", GROUND_UNIT, b"\x81\xc1\x40\x06\x00\x00", 1)
    _pin_calls(ck, b, "setpiece.ground_unit.flight", GROUND_UNIT, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.ground_unit.debris", GROUND_UNIT, 0x00422610, 1)
    _pin_calls(ck, b, "setpiece.ground_unit.landing_dust", GROUND_UNIT, A_LANDING_DUST, 1)
    _pin_calls(ck, b, "setpiece.ground_unit.object_inserted", GROUND_UNIT, 0x00404E30, 1)
    _pin_bytes(ck, b, "setpiece.ground_debris.debris_20", GROUND_UNIT_DEBRIS, _push8(0x28), 2)
    _pin_bytes(ck, b, "setpiece.ground_debris.splats_4", GROUND_UNIT_DEBRIS,
               b"\xc7\x44\x24\x18\x04\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.teleporter.frames_70", TELEPORTER, b"\xbe\x46\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.teleporter.hide_at_40_x2", TELEPORTER, b"\x83\xfe\x28", 2)
    _pin_bytes(ck, b, "setpiece.teleporter.move_at_10_x2", TELEPORTER, b"\x83\xfe\x0a", 2)
    _pin_calls(ck, b, "setpiece.teleporter.camera_follows", TELEPORTER, 0x0042B4B0, 1)
    _pin_calls(ck, b, "setpiece.teleporter.stream", TELEPORTER, 0x0042A120, 1)
    _pin_bytes(ck, b, "setpiece.teleporter_stream.200_x16", TELEPORTER_STREAM, b"\x81\xff\xc8\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.teleporter_stream.rise_16", TELEPORTER_STREAM, b"\x83\xc6\x10", 1)
    _pin_bytes(ck, b, "setpiece.teleporter_stream.kind_65_life_70", TELEPORTER_STREAM,
               _push8(0x46) + _push8(0x41), 1)
    _pin_bytes(ck, b, "setpiece.teleport_kill.frames_10", TELEPORT_KILL, b"\x0a\x00\x00\x00", 1, at_least=True)
    _pin_calls(ck, b, "setpiece.teleport_kill.gore", TELEPORT_KILL, A_GORE_LEVEL, 1)
    _pin_calls(ck, b, "setpiece.teleport_kill.puff", TELEPORT_KILL, DEATH_PUFF[0], 1)
    _pin_calls(ck, b, "setpiece.teleport_kill.debris", TELEPORT_KILL, 0x004216D0, 1)
    # §9.1 -- the special-object state byte.
    _pin_calls(ck, b, "objects.mine_placer", MINE_PLACER, A_CREATE_SPECIAL, 1)
    _pin_calls(ck, b, "objects.fire_placer", FIRE_PLACER, A_CREATE_SPECIAL, 1)
    _pin_calls(ck, b, "objects.glow_placer", GLOW_PLACER, A_CREATE_SPECIAL, 1)
    # aCreateSpecialObject writes its last two arguments to +0x40 and +0x41.
    _pin_bytes(ck, b, "objects.free_slot_is_0xff", CREATE_SPECIAL, b"\xb0\xff\x38\x46\x40", 1)
    _pin_bytes(ck, b, "objects.slots_80", CREATE_SPECIAL, b"\x83\xff\x50", 1)
    # The refresh's per-state rotation increments (docs/42 §9.1).
    _pin_bytes(ck, b, "objects.array_of_80", VIEW_REFRESH, b"\xbb\x50\x00\x00\x00", 1)
    _pin_bytes(ck, b, "objects.state_2_turns_51", VIEW_REFRESH, b"\x66\x83\x06\x33", 1, at_least=True)
    arms = (VIEW_REFRESH[0], 0x00407400)
    _pin_bytes(ck, b, "objects.state_3_turns_25", arms, b"\x66\x83\x06\x19", 1)
    _pin_bytes(ck, b, "objects.state_3_turns_102", arms, b"\x66\x83\x06\x66", 1)
    # State 3 is the shield (docs/23 §7.1): `0x0042FB90` creates `A_SHILD.3DI`
    # with state 3 and subtype from the cell's `+0x0E`, which it sets to 2
    # first -- so a shield turns by 51 a frame.  Two callers: the object
    # seeding for a cell marked 3 and the fight routine's weapon-43 arm.
    _pin_calls(ck, b, "objects.shield_placer", SHIELD_PLACER, A_CREATE_SPECIAL, 1)
    _pin_at(ck, b, "objects.shield_state_3", 0x0042FC63, _push8(3))
    _pin_bytes(ck, b, "objects.shield_subtype_2", SHIELD_PLACER, b"\xc6\x45\x0e\x02", 1)
    _pin_bytes(ck, b, "objects.shield_model", SHIELD_PLACER, struct.pack("<I", 0x004C2D14), 1)
    _pin_calls(ck, b, "objects.shield_from_seeding", OBJECT_SEEDING, A_SHIELD_PLACER, 1)
    _pin_calls(ck, b, "objects.shield_from_fight", FIGHT, A_SHIELD_PLACER, 1)
    _pin_bytes(ck, b, "objects.seeding_cases_1_2_3", OBJECT_SEEDING, b"\x48\x74\x38\x48\x74\x1f\x48\x75\x4e", 1)
    # The call-site counts docs/42 quotes, over the whole text section.
    for name, va, n in (("flight", A_FLIGHT, 45), ("set_camera", A_SET_CAMERA, 43),
                        ("unit_camera", A_UNIT_CAMERA, 11), ("frame_tick", A_FRAME, 70)):
        sites = b.calls(TEXT, va)
        ck.check(f"call_sites.{name}_{n}", len(sites) == n, str(len(sites)))
    _pin_bytes(ck, b, "objects.random_heading_range_4096_x2", VIEW_REFRESH,
               _push32(0x1000) + _push8(0), 2)
    _pin_calls(ck, b, "objects.random_headings", VIEW_REFRESH, A_RANDOM2, 2)


def _check_ground_objects(ck: Checker, b: Binary) -> None:
    """docs/42 §9.1 -- who lays a transient object, and what clears it.

    Three of ``aPlayFightAnimation``'s impact arms change the map; the
    hand-over's two sweeps take it back.  Everything here is read out of the
    instructions: no capture reaches the placers, which is why
    ``inclib/ctrlmap.py`` is a transcription.
    """
    # The impact switch selects the three arms, by weapon id.
    arms = {}
    for n in range(IMPACT_ENTRIES):
        arm = b.u32(IMPACT_JUMP + 4 * b.pe.u8(IMPACT_INDEX + n))
        arms[IMPACT_FIRST_WEAPON + n] = arm
    for weapon, expect in sorted(IMPACT_PLACER_WEAPONS.items()):
        ck.check(f"objects.impact_arm_{weapon}", arms.get(weapon) == expect,
                 f"{arms.get(weapon, 0):#010x} != {expect:#010x}")
    # Weapon 40 calls the fire placer nine times, and the subtype each call
    # pushes is the byte after its `push`.
    sites = tuple(b.calls(FIGHT, A_FIRE_PLACER))
    want = tuple(site for site, _ in NINE_FIRE_SITES)
    ck.check("objects.fight_lays_nine_fires", sites == want,
             f"{[hex(v) for v in sites]}")
    def pushed_subtype(site: int) -> int:
        """The last `push imm8` before the call -- the placer's third argument.

        Its distance from the call varies with how the compiler ordered the
        `lea`s around it, so it is searched for rather than read at a fixed
        offset.
        """
        window = b.pe.bytes_at(site - 16, 16)
        for i in range(len(window) - 2, -1, -1):
            if window[i] == 0x6A:
                return window[i + 1]
        return -1

    got = tuple((site, pushed_subtype(site)) for site, _ in NINE_FIRE_SITES)
    ck.check("objects.nine_fire_subtypes", got == NINE_FIRE_SITES,
             f"{[(hex(a), n) for a, n in got]}")
    _pin_calls(ck, b, "objects.fight_lays_one_mine", FIGHT, A_MINE_PLACER, 1)
    _pin_calls(ck, b, "objects.fight_lays_one_shield", FIGHT, A_SHIELD_PLACER,
               1)
    # The fire placer's two gates and its three cell writes.
    _pin_at(ck, b, "objects.fire_gate_is_action_point_71", 0x0042F894,
            b"\x3c\x47")
    _pin_at(ck, b, "objects.fire_height_window_0x640", 0x0042F8C9,
            b"\x3d\x40\x06\x00\x00")
    _pin_at(ck, b, "objects.fire_refuses_a_shield", 0x0042F8DB, b"\x3c\x03")
    _pin_at(ck, b, "objects.fire_writes_state_1", 0x0042FA4F,
            b"\xc6\x45\x10\x01")
    _pin_at(ck, b, "objects.fire_failure_writes_255", 0x0042FA36,
            b"\xc6\x45\x10\xff")
    _pin_calls(ck, b, "objects.fire_deletes_what_stood_there", FIRE_PLACER,
               A_DELETE_SPECIAL, 1)
    _pin_at(ck, b, "objects.mine_writes_state_2", 0x0042FB7E,
            b"\xc6\x45\x10\x02")
    _pin_calls(ck, b, "objects.mine_deletes_nothing", MINE_PLACER,
               A_DELETE_SPECIAL, 0)
    _pin_at(ck, b, "objects.shield_writes_state_3", 0x0042FCA4,
            b"\xc6\x45\x10\x03")
    _pin_at(ck, b, "objects.shield_already_there_returns", 0x0042FC2A,
            b"\x80\x7d\x10\x03")
    # The glow's own three bytes -- +0x11, +0x12 and +0x13, not +0x0E.
    _pin_at(ck, b, "objects.glow_writes_slot_0x11", 0x0042FE15,
            b"\x88\x45\x11")
    _pin_at(ck, b, "objects.glow_writes_state_4", 0x0042FE1F,
            b"\xc6\x45\x13\x04")
    _pin_at(ck, b, "objects.glow_writes_phase_0x12", 0x0042FE23,
            b"\x88\x45\x12")
    # The two script sources: SetGroundFire lays a glow, ParaBombs a mine.
    _pin_calls(ck, b, "objects.set_ground_fire_lays_a_glow",
               (0x00442730, 0x004428B0), A_GLOW_PLACER, 1)
    _pin_calls(ck, b, "objects.para_bombs_lay_a_mine", (0x00470790, 0x00470AB0),
               A_MINE_PLACER, 1)
    _pin_at(ck, b, "objects.para_bombs_need_an_empty_cell", 0x0047083D,
            b"\x80\x78\x10\xff")
    # The round tick: a fire loses one level and goes out at 1, a shield loses
    # one from its countdown and the object's subtype with it.
    _pin_calls(ck, b, "objects.tick_relights_the_fire", GROUND_TICK,
               A_FIRE_PLACER, 1)
    _pin_calls(ck, b, "objects.tick_decays_the_glow", GROUND_TICK,
               A_GLOW_PLACER, 1)
    _pin_calls(ck, b, "objects.tick_deletes_three_ways", GROUND_TICK,
               A_DELETE_SPECIAL, 3)
    _pin_at(ck, b, "objects.tick_fire_goes_out_at_1", 0x0042EE6D, b"\x3c\x01")
    _pin_at(ck, b, "objects.tick_shield_expires_at_1", 0x0042EDDE,
            b"\x80\x7e\xfb\x01")
    _pin_at(ck, b, "objects.tick_shield_counts_down", 0x0042EE29,
            b"\xfe\x4e\xfb")
    _pin_at(ck, b, "objects.tick_shield_object_subtype", 0x0042EE3A,
            b"\xfe\x48\x41")
    _pin_at(ck, b, "objects.tick_glow_decays_at_phase_2", 0x0042ED8D,
            b"\x83\xe8\x02")
    # The ignition sweep, and what an ignited glow does.
    _pin_at(ck, b, "objects.ignite_reads_state_4", 0x00470AD0, b"\x80\x3e\x04")
    _pin_at(ck, b, "objects.ignite_clears_the_state", 0x00470B10,
            b"\xc6\x06\xff")
    _pin_calls(ck, b, "objects.ignite_plays_the_fire", GROUND_IGNITE,
               A_GROUND_FIRE_ANIM, 1)
    _pin_bytes(ck, b, "objects.ground_fire_walks_eight_directions",
               GROUND_FIRE_ANIM, b"\x83\xfe\x08", 1)
    _pin_calls(ck, b, "objects.ground_fire_steps", GROUND_FIRE_ANIM, A_STEP, 1)
    _pin_at(ck, b, "objects.ground_fire_step_takes_diagonals", 0x00415963,
            b"\x6a\x01")
    _pin_at(ck, b, "objects.ground_fire_spares_a_shield", 0x004159AE,
            b"\x80\x78\x10\x03")
    _pin_calls(ck, b, "objects.ground_fire_removes_the_units",
               GROUND_FIRE_ANIM, A_REMOVE_UNIT, 1)
    # The hand-over runs the two sweeps between the counter and NEXT TURN.
    for name, va in (("ignite", A_GROUND_IGNITE), ("tick", A_GROUND_TICK)):
        _pin_calls(ck, b, f"objects.hand_over_runs_the_{name}", HAND_OVER, va,
                   1)


def _check_between_players(ck: Checker, b: Binary) -> None:
    """``0x0047C2C0`` -- the between-players screen, and when it draws nothing.

    ``docs/97`` §35.1 read it as "the between-players screen, read and not
    built".  Its **case 0** -- the arm a mission hand-over takes -- opens with

    .. code-block:: c

       if (humanPlayerCount() == 1 && !multiHumanSession())   /* 0x0047C3FF */
           { SendMessage(hwnd, WM_LBUTTONDOWN, 0, 0); return 1; }

    ``0x0043B700`` is ``docs/25`` §2's human-player count -- the slots at
    ``0x00509E20`` whose kind is exactly 1 -- and ``0x0043B1F0`` is
    ``0x00509F08`` non-zero **and** the game mode among 2, 3 and 4, a network,
    local or play-by-mail session.  So in a **one-human campaign** the screen
    posts its own
    left-button-down and returns before it draws a line: the remake, which is
    a one-human campaign, is faithful by not having it (`docs/97` §41.5).
    """
    _pin_at(ck, b, "screen.between_players.human_count_gate", 0x0047C3FF,
            b"\xe8\xfc\xf2\xfb\xff\x83\xf8\x01\x75")
    _pin_at(ck, b, "screen.between_players.session_gate", 0x0047C409,
            b"\xe8\x72\xee\xfb\xff\xe8\xdd\xed\xfb\xff\x85\xc0"
            b"\x75")
    # `push 0x201` is WM_LBUTTONDOWN: the arm dismisses itself.
    _pin_at(ck, b, "screen.between_players.dismisses_itself", 0x0047C41F,
            b"\x68\x01\x02\x00\x00")
    _pin_calls(ck, b, "screen.between_players.blanks_the_frame",
               BETWEEN_PLAYERS, 0x00447B80, 1)
    _pin_bytes(ck, b, "screen.between_players.blank_is_640x480",
               BETWEEN_PLAYERS,
               _push32(0x1DF) + _push32(0x27F) + _push8(0) + _push8(0), 1)


def _check_crush_wall(ck: Checker, b: Binary) -> None:
    """``aPlayCrushWallAnimation`` ``0x00415C70`` -- which cells it reaches.

    ``docs/42`` §8 said only "``0x004238C0`` on every cell".  The cells are
    **marked first**: ``0x00415D6D`` calls ``0x0042F410(obj, 1, 0, 1)``, which
    sweeps the whole control map and, for each cell, casts four probes from
    the cell's own symbol object at ``x +/- 200`` and ``y +/- 200`` (from
    ``z = 0x186A0``) against the wall's land object.  A cell any probe hits
    has its object dropped to ``z 0``, its height ``+0x01`` set to 0, its
    field type ``+0x0D`` set to **1** (`Free Place`) and its state byte
    ``+0x00`` set to 2.  ``0x00415D87`` then sweeps for state 2, spawns
    ``0x004238C0`` there and puts the byte back to 1.

    So the footprint is a **3D query against the scene**, not a control-map
    one, which is why `core` cannot derive it: see `docs/97` §41.4.
    """
    _pin_calls(ck, b, "setpiece.crush_wall.marks_the_footprint", CRUSH_WALL,
               0x0042F410, 1)
    _pin_at(ck, b, "setpiece.crush_wall.mark_arguments", 0x00415D66,
            b"\x6a\x01\x6a\x00\x6a\x01\x56")
    # `0x00415D87` -- the state-2 sweep, the debris and the byte going back.
    _pin_at(ck, b, "setpiece.crush_wall.state_2_sweep", 0x00415D87,
            b"\x80\x3f\x02")
    _pin_at(ck, b, "setpiece.crush_wall.puts_the_state_back", 0x00415DA4,
            b"\xc6\x07\x01")
    _pin_calls(ck, b, "setpiece.crush_wall.debris", CRUSH_WALL, 0x004238C0, 1)
    _pin_bytes(ck, b, "setpiece.crush_wall.sweep_stride_23", CRUSH_WALL,
               b"\x83\xc7\x17", 1)
    # The probe itself: +/- 200 in x and y, cast from 100000 up.
    # Four probes: two add 200 and two subtract it, one pair per axis.
    _pin_bytes(ck, b, "special.probe.offset_plus_200", MARK_UNDER_OBJECT,
               b"\x81\xc2\xc8\x00\x00\x00", 2)
    _pin_bytes(ck, b, "special.probe.offset_minus_200", MARK_UNDER_OBJECT,
               b"\x81\xe9\xc8\x00\x00\x00", 2)
    _pin_bytes(ck, b, "special.probe.from_100000", MARK_UNDER_OBJECT,
               b"\xc7\x44\x24\x24\xa0\x86\x01\x00", 4)
    # `0x0042F609` / `0x0042F612` -- the field type and the height it writes.
    _pin_at(ck, b, "special.probe.writes_field_type_and_height", 0x0042F602,
            b"\x8a\x44\x24\x50\x8b\x56\x18\x88\x43\x0d")
    _pin_calls(ck, b, "special.probe.marks_the_state", MARK_UNDER_OBJECT,
               0x0042F780, 1)


def _check_bomber_arguments(ck: Checker, b: Binary) -> None:
    """``ParaBombs`` ``0x00415E90`` -- the six arguments it hands the creator,
    and the camera triple ``docs/97`` §32 left UNVERIFIED.

    ``0x00415EE1``..``0x00415EFF`` pushes six **literals**:
    ``aBlob_CreateBomber(-320000, -320000, 320000, 48000, 48000, 320000)`` --
    the fly-past is a fixed diagonal across the scene and reads no tile at all.

    The camera is a separate call and is where the two untraced locals were:
    ``0x00415F2C`` reads all six of the camera's own numbers back through
    ``0x00403780`` **before** the flight-path arm picks the eye, and
    ``0x00415FB4`` sets position ``(-16000, 0, 320000 | 80000)`` with the
    **target it just read**.  So the bomber does not aim the camera anywhere:
    it slides the eye and keeps looking at whatever the scene was looking at.
    """
    _pin_at(ck, b, "setpiece.bomber.creator_arguments", 0x00415EE1,
            _push32(0x0004E200) + _push32(0x0000BB80) + _push32(0x0000BB80)
            + _push32(0x0004E200) + _push32(0xFFFB1E00)
            + _push32(0xFFFB1E00))
    _pin_calls(ck, b, "setpiece.bomber.creator", PARA_BOMBS, 0x0042A8E0, 1)
    # The camera getter runs before the flight-path switch, and its last three
    # out-parameters are the setter's last three arguments.
    _pin_calls(ck, b, "setpiece.bomber.reads_the_camera_back", PARA_BOMBS,
               A_READ_CAMERA, 1)
    _pin_at(ck, b, "setpiece.bomber.keeps_the_camera_target", 0x00415FA2,
            b"\x8b\x4c\x24\x1c\x8b\x54\x24\x14\x8b\x44\x24\x10"
            b"\x51\x52\x50\x55\x53\x57")
    # Twice: `0x00415FB4` puts the eye on the flight path and `0x00416014`
    # puts all six numbers back afterwards.
    _pin_calls(ck, b, "setpiece.bomber.sets_the_camera", PARA_BOMBS,
               A_SET_CAMERA, 2)


def _check_para_bombs_phases(ck: Checker, b: Binary) -> None:
    """``ParaBombs`` ``0x00470790`` runs **two** routines, in order.

    ``docs/20`` §7.4 says so and ``docs/28`` §2 gives each its own wave --
    ``bomber.wav`` @87 looping under the fly-past ``0x00415E90`` and
    ``crush.wav`` @89 under the bomb run ``0x004160F0`` -- but nothing pinned
    the pairing, and the remake's sound layer mapped the whole command to the
    fly-past alone, so the second wave was never played.  These are the three
    facts that reading holds: the handler calls each routine once, the
    fly-past is the one that comes first, and the two are separate blocking
    routines rather than one with two sounds.

    The last is what ``0x004160B4`` settles: the fly-past's own last act is
    ``aDeleteAllBlobs`` ``0x0041E370``, so the bombs cannot already be in the
    pool when it returns.

    ``0x00416271``'s ``mov edi, 3`` is recorded here for the scale-down it
    bounds: the bomb run loads **three** ``crush.wav`` buffers and plays them
    round-robin, one per landing (``0x00416364``..``0x004163A9``), where the
    remake plays the wave once as its stage opens.
    """
    fly = _pin_calls(ck, b, "setpiece.para_bombs.fly_past",
                     PARA_BOMBS_HANDLER, PARA_BOMBS[0], 1)
    run = _pin_calls(ck, b, "setpiece.para_bombs.bomb_run",
                     PARA_BOMBS_HANDLER, PARA_BOMB_RUN[0], 1)
    ck.check("setpiece.para_bombs.fly_past_first",
             bool(fly) and bool(run) and fly[0] < run[0],
             f"0x{fly[0]:08X} < 0x{run[0]:08X}" if fly and run
             else "one of the two calls is missing")
    _pin_calls(ck, b, "setpiece.para_bombs.fly_past_empties_the_pool",
               PARA_BOMBS, 0x0041E370, 1)
    _pin_calls(ck, b, "setpiece.para_bombs.bomb_run_lays_the_bombs",
               PARA_BOMB_RUN, PARA_BOMB_CREATOR[0], 1)
    _pin_at(ck, b, "setpiece.para_bombs.three_crush_buffers", 0x00416271,
            b"\xbf\x03\x00\x00\x00")
    # The bomb run's own loops, which are what "one crump per landing" is.
    # `0x0042B480` is read in **two** of them: `0x0041632F` spins until the
    # first bomb lands -- the run opens silent, with the camera on the first
    # live record -- and `0x00416369` is the crump loop proper. The first
    # landing therefore reaches `0x0041633F`'s play and then the loop's own
    # on the next frame, both on `buffer[0]`, so it restarts one buffer
    # rather than making two sounds. `0x0042B490` acknowledges, and
    # `0x0042B4A0` -- the **live count**, not the flag -- is what ends it.
    _pin_calls(ck, b, "setpiece.para_bombs.spins_for_the_first_landing",
               PARA_BOMB_RUN, ARRIVED_READ, 2)
    _pin_calls(ck, b, "setpiece.para_bombs.acknowledges_each_crump",
               PARA_BOMB_RUN, ARRIVED_CLEAR, 1)
    _pin_calls(ck, b, "setpiece.para_bombs.ends_on_the_live_count",
               PARA_BOMB_RUN, LIVE_COUNT, 1)
    _pin_at(ck, b, "setpiece.para_bombs.live_count_reads_0x004FE640",
            LIVE_COUNT, b"\xa1\x40\xe6\x4f\x00\xc3")
    _check_arrived_writers(ck, b)


#: `0x004FE63C` -- the *arrived* flag of `docs/42` §4.6, and the three
#: one-line helpers a sequence reaches it through.
ARRIVED_FLAG = 0x004FE63C
ARRIVED_READ = 0x0042B480
ARRIVED_CLEAR = 0x0042B490
#: `0x004FE640` -- the live-record count, read by `0x0042B4A0`.
LIVE_COUNT = 0x0042B4A0
#: Every site in `.text` that writes a **zero** to the flag, and the routine
#: it is in.  Five are creators; the sixth is the clear helper itself.
ARRIVED_CLEARED_BY: dict[int, tuple[int, str]] = {
    0x004263B7: (0x00426070, "aBlob_CreateGrenade"),
    0x004267D7: (0x004264A0, "aBlob_EnergyCannon"),
    0x004287D3: (0x00428570, "aBlob_CreateLaser"),
    0x0042A938: (0x0042A8E0, "aBlob_CreateBomber"),
    0x0042B0E3: (0x0042B070, "the para bomb"),
    0x0042B490: (0x0042B490, "the clear helper"),
}


def _check_arrived_writers(ck: Checker, b: Binary) -> None:
    """Who writes a **zero** over the *arrived* flag, and who therefore has
    something in flight to wait for (`docs/42` §4.6).

    The flag starts raised -- "nothing to wait for" -- and a creator that
    makes something worth waiting on writes a zero before it returns.  There
    are exactly **six** such sites in `.text` and five of them are inside a
    creator: the three weapon projectiles, which the remake's shot path
    models at the muzzle instead of per creator, and the two `ParaBombs`
    runs, which are the pair `game/fx/blob_programs.gd` and
    `inclib/blob_creators.py` carry as `clears_arrived`.

    Counting them matters as much as naming them: modelling two of five is a
    decision, and a decision that nothing counted would look like an
    oversight the first time somebody added a sixth.
    """
    blob = b.span(0x00401000, 0x004B0000)
    store = struct.pack("<HI I", 0x05C7, ARRIVED_FLAG, 0)
    found: list[int] = []
    start = 0
    while True:
        i = blob.find(store, start)
        if i < 0:
            break
        found.append(0x00401000 + i)
        start = i + 1
    want = sorted(ARRIVED_CLEARED_BY)
    ck.check("arrived.cleared_by", found == want,
             f"{[hex(v) for v in found]} != {[hex(v) for v in want]}")
    # And each really is inside the routine the table names.
    bad = [f"0x{site:08X}" for site, (owner, _) in sorted(ARRIVED_CLEARED_BY.items())
           if not owner <= site < owner + 0x400]
    ck.check("arrived.sites_inside_their_creator", not bad,
             f"{len(ARRIVED_CLEARED_BY)} sites, each in its own routine: "
             f"{', '.join(bad) if bad else 'all'}")
    # The two the remake models, spelled out so a rename on either side of
    # the pair shows up here rather than as a set piece that never ends.
    modelled = sorted({owner for owner, _ in ARRIVED_CLEARED_BY.values()
                       if owner in PARA_BOMBS_CREATORS})
    ck.check("arrived.modelled_pair", modelled == sorted(PARA_BOMBS_CREATORS),
             f"{[hex(v) for v in modelled]} of the five creators are the "
             f"pair `blob_programs.gd` carries")


def _check_orbit_gate(ck: Checker, b: Binary) -> None:
    """``0x00410190`` -- the skill orbit plays in the campaign and nowhere else.

    Its first five instructions are the gate: ``call 0x0043B740`` (the game
    mode getter, ``docs/25`` §2) and ``cmp eax, 1``.  ``main.gd`` reads
    ``TurnState.mode`` for it.
    """
    # The gate itself, at the skill orbit's own first instruction past its
    # seven-byte prologue: `call 0x0043B740 / cmp eax, 1 / jne`.
    _pin_at(ck, b, "orbit.skill.campaign_gate", 0x00410197,
            b"\xe8\xa4\xb5\x02\x00\x83\xf8\x01\x0f\x85")
    # And that it is the **only** orbit that asks. Counting the calls over
    # each routine's own range is the test; reading a fixed offset was not --
    # every one of the six opens with `83 ec XX`, so a byte compare against
    # `E8` at the entry passed whatever the routine went on to do.
    _pin_calls(ck, b, "orbit.skill.asks_the_game_mode_once", ORBIT_SKILL,
               GAME_MODE_GETTER, 1)
    for name, rng in (("overheat", ORBIT_OVERHEAT), ("jam", ORBIT_JAM),
                      ("heal", ORBIT_HEAL), ("poison", ORBIT_POISON),
                      ("rotating", ORBIT_ROTATING)):
        _pin_calls(ck, b, f"orbit.{name}.never_asks_the_game_mode", rng,
                   GAME_MODE_GETTER, 0)


def _check_teleporter(ck: Checker, b: Binary) -> None:
    """``aExecuteTeleporter`` ``0x00470150`` -- ``docs/26`` §5, the rule half.

    Four instructions decide everything: the entry's action point is the key,
    the exit is the first cell in a row-major sweep whose field type is 10 and
    whose key matches, an unpaired entry is inert, and an **occupied** exit
    kills the traveller.  ``ExecuteMove._teleport`` and
    :func:`inclib.ai._teleport` are the twins.
    """
    # `0x00470199` -- `mov bl, byte [ebp+0x0B]`, the key.
    _pin_at(ck, b, "teleporter.key_is_the_action_point", 0x00470199,
            b"\x8a\x5d\x0b")
    # `0x004701B2` -- field type 10, then the key, over a stride-23 sweep.
    _pin_at(ck, b, "teleporter.exit_is_field_type_10", 0x004701B2,
            b"\x80\x7e\x0d\x0a\x75\x05\x38\x5e\x0b")
    _pin_bytes(ck, b, "teleporter.sweep_stride_23", EXECUTE_TELEPORTER,
               b"\x83\xc6\x17", 1)
    # `0x004701D4`..`0x004701DD` -- the exit's unit word against 0xFFFF.
    _pin_at(ck, b, "teleporter.blocked_exit_test", 0x004701D4,
            b"\xbb\xff\xff\x00\x00\x66\x39\x5e\x07")
    # The blocked arm books a loss and removes the traveller; the clear arm
    # moves the cell link and plays the sequence.
    _pin_calls(ck, b, "teleporter.blocked_books_a_loss", EXECUTE_TELEPORTER,
               0x0043B8D0, 1)
    _pin_calls(ck, b, "teleporter.blocked_removes_the_unit",
               EXECUTE_TELEPORTER, 0x004779C0, 1)
    _pin_calls(ck, b, "teleporter.plays_the_sequence", EXECUTE_TELEPORTER,
               0x004164F0, 1)
    # `0x00470260`/`0x00470264` -- the link moves from the entry to the exit.
    _pin_at(ck, b, "teleporter.moves_the_cell_link", 0x00470260,
            b"\x66\x89\x56\x07\x66\x89\x5d\x07")
    # `0x0046EA73` -- the walk's only field-type test besides the delay
    # column, and the break it takes.
    _pin_at(ck, b, "teleporter.the_walk_breaks_on_it", 0x0046EA73,
            b"\x8a\x46\x0d\x3c\x09\x74\x66")
    # `0x0046EDDC`..`0x0046EE03` -- the alive gate, then the call.
    _pin_at(ck, b, "teleporter.sits_behind_the_alive_gate", 0x0046EDDC,
            b"\x8a\x47\x16\x84\xc0")
    _pin_calls(ck, b, "teleporter.called_once_from_the_walk",
               EXECUTE_MOVE, 0x00470150, 1)


def _check_bomb_picture(ck: Checker, b: Binary) -> None:
    """Where the mine's explosion is drawn, and therefore when.

    `aExecuteBomb` `0x004702C0` ends by calling `aPlayFightAnimation`
    `0x0040BD70` itself, and both the walk and the jump reach `aExecuteBomb`
    from **inside** their own routine -- `0x0046EDAF` and `0x0046F109`.
    `aExecuteFight`, which drains the reactions, is the caller's and runs only
    after `aExecuteMove` has returned (docs/23 section 5.3).  So the blast is
    over before the first reaction shot, which is the order `game` queues in.
    """
    _pin_calls(ck, b, "bomb.plays_its_own_fight_animation", EXECUTE_BOMB,
               A_PLAY_FIGHT, 1)
    # **Two** in the walk, which is the pair of arms `0x0046EC25` picks
    # between by the mover's `size`: `0x0046ECA4` walks the eight neighbours
    # of a large unit and `0x0046EDAF` is the stop cell's (docs/26 6.2 item 8).
    _pin_calls(ck, b, "bomb.the_walk_detonates_inside_itself", EXECUTE_MOVE,
               A_EXECUTE_BOMB, 2)
    _pin_calls(ck, b, "bomb.the_jump_detonates_inside_itself", EXECUTE_WARP,
               A_EXECUTE_BOMB, 1)
    # Neither routine draws a fight of its own, so the blast's picture can
    # only be the one `aExecuteBomb` played before returning.
    _pin_calls(ck, b, "bomb.the_walk_draws_no_fight_itself", EXECUTE_MOVE,
               A_PLAY_FIGHT, 0)
    _pin_calls(ck, b, "bomb.the_jump_draws_no_fight_itself", EXECUTE_WARP,
               A_PLAY_FIGHT, 0)


def _check_remove_unit_sites(ck: Checker, b: Binary) -> None:
    """The twenty call sites of `aRemoveUnitElement`, split by what reaches it.

    `0x00477ABD` -- `mov byte [esi+0x16], 0` -- is the routine's own last
    instruction, so removal kills.  Five sites arrive with the hit points
    already down; at the other fifteen this write **is** the death.
    """
    sites = set(b.calls(TEXT, A_REMOVE_UNIT))
    declared = set(REMOVE_UNIT_KILL_PATH) | set(REMOVE_UNIT_LIVE)
    ck.check("remove_unit.every_site_is_accounted_for", sites == declared,
             f"only in the image: {sorted(hex(a) for a in sites - declared)}; "
             f"only in the table: {sorted(hex(a) for a in declared - sites)}")
    ck.check("remove_unit.five_arrive_dead_and_fifteen_alive",
             (len(REMOVE_UNIT_KILL_PATH), len(REMOVE_UNIT_LIVE)) == (5, 15),
             f"{len(REMOVE_UNIT_KILL_PATH)} + {len(REMOVE_UNIT_LIVE)}")
    _pin_at(ck, b, "remove_unit.its_last_instruction_kills", 0x00477ABD,
            b"\xc6\x46\x16\x00")
    # The two sweeps that reach it with a live unit and say so themselves:
    # `lKillPlayerUnits` gates on `+0x16` being non-zero, and `aUI_KillUnit`
    # on the slot carrying a player at all.
    _pin_at(ck, b, "remove_unit.kill_player_units_gates_on_hp", 0x0047BC74,
            b"\x8a\x46\xd3\x84\xc0")
    _pin_at(ck, b, "remove_unit.ui_kill_unit_gates_on_the_player", 0x004783FE,
            b"\x80\x3e\xff")
    for name, rng, expect in (("ui_kill_unit", UI_KILL_UNIT, 2),
                              ("kill_player_units", KILL_PLAYER_UNITS, 1),
                              ("execute_bomb", EXECUTE_BOMB, 1)):
        _pin_calls(ck, b, f"remove_unit.{name}", rng, A_REMOVE_UNIT, expect)


def _check_arrived_ordering(ck: Checker, b: Binary) -> None:
    """A creator clears the *arrived* flag **before** it allocates.

    Which is what says a **full pool** leaves the flag down and the caller
    waits its hundred frames -- so the remake reproducing that wait is
    faithful, and cutting it short is only right for a refusal the engine
    could not have had (docs/97 section 40.6).
    """
    flag = struct.pack("<I", ARRIVED_FLAG)
    text = b.span(*TEXT)
    found: set[int] = set()
    i = 0
    while True:
        i = text.find(flag, i)
        if i < 0:
            break
        va = TEXT[0] + i
        if not BLOB_UPDATE[0] <= va - 2 < BLOB_UPDATE[1]:
            if text[i - 2:i] == b"\xc7\x05" or (
                    text[i - 2] == 0x89 and text[i - 1] in
                    (0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D)):
                found.add(va - 2)
            elif text[i - 1] == 0xA3:
                found.add(va - 1)
        i += 4
    ck.check("arrived.creator_stores_are_the_table_ones",
             found == set(ARRIVED_CREATOR_STORES),
             f"image {sorted(hex(a) for a in found - set(ARRIVED_CREATOR_STORES))}, "
             f"table {sorted(hex(a) for a in set(ARRIVED_CREATOR_STORES) - found)}")
    after = []
    for store, start in sorted(ARRIVED_CREATOR_STORES.items()):
        if b.calls((start, store), A_BLOB_CTOR):
            after.append(store)
    ck.check("arrived.only_one_store_follows_an_allocation",
             after == [ARRIVED_STORE_AFTER_ALLOCATION[0]],
             f"{[hex(a) for a in after]}")
    # And that one writes 1, so it can never be the reason anybody waits.
    _pin_at(ck, b, "arrived.the_one_that_follows_writes_one",
            ARRIVED_STORE_AFTER_ALLOCATION[0],
            b"\xc7\x05" + flag + struct.pack("<I",
                                              ARRIVED_STORE_AFTER_ALLOCATION[1]))
    _pin_at(ck, b, "arrived.the_flag_has_its_own_getter", ARRIVED_GETTER,
            b"\xa1" + flag + b"\xc3")


def _check_victory_markers(ck: Checker, b: Binary) -> None:
    """docs/42 §9.3 -- the marker on a victory-point cell, and what a play-out
    counts.

    ``0x00431E30`` walks the control map (stride ``0x17``), and on a cell whose
    action point is in 80..89 frees the object the cell's ``+0x14`` names,
    places a static (state 5) object of the model ``action point - 0x50``
    selects through the jump table at ``0x00432000``, and writes the slot back
    into ``+0x14``; any other cell gets ``0xFF`` there.  It runs once per load
    and once per capture.  The sweep's live count -- what every play-out spins
    on -- takes only classes 0 and 2, which is why a warning light (class 1,
    life 255) never holds a shot.
    """
    names = []
    pointers = []
    for n in range(len(VP_MARKER_MODELS)):
        arm = b.u32(VP_MARKER_JUMP + 4 * n)
        # `lea edx, [esp+0x14]` (4 bytes), then `mov edi, imm32`.
        ok = b.pe.bytes_at(arm, 5) == b"\x8d\x54\x24\x14\xbf"
        ptr = b.u32(arm + 5) if ok else 0
        pointers.append(ptr)
        try:
            raw = b.pe.bytes_at(ptr, 12) if ok else b""
        except PEError:
            raw = b""
        names.append(raw.split(b"\0", 1)[0].decode("ascii", "replace"))
    # The ten strings sit 12 bytes apart in `.data`, 4B first ...
    expect = [VP_MARKER_STRINGS_LAST - 12 * n for n in range(len(VP_MARKER_MODELS))]
    held = tuple(b.pe.bytes_at(va, 12).split(b"\0", 1)[0].decode("ascii")
                 for va in expect)
    ck.check("vp_marker.ten_strings_in_data", held == VP_MARKER_MODELS, str(held))
    # ... and nine of the arms point at their own.  **Action point 87's arm
    # does not**: `mov edi, 0x00752E04` at `0x00431F06` where the pattern
    # says `0x004C2E04` -- one byte off, into no section of the image.  No
    # shipped cell carries 86..89 (`docs/26` §6.1), so nothing reaches it,
    # but a *B* point claimed by player 1 in a multiplayer game would.
    ck.check("vp_marker.nine_arms_name_their_model",
             names[:7] == list(VP_MARKER_MODELS[:7])
             and names[8:] == list(VP_MARKER_MODELS[8:]), str(names))
    ck.check("vp_marker.arm_87_points_off_the_image",
             pointers[7] == VP_MARKER_BROKEN_POINTER and names[7] == "",
             f"{pointers[7]:#010x} -> {names[7]!r}")
    _pin_at(ck, b, "vp_marker.band_low_0x50", 0x00431E59, b"\x3c\x50")
    _pin_at(ck, b, "vp_marker.band_high_0x59", 0x00431E61, b"\x3c\x59")
    _pin_at(ck, b, "vp_marker.index_is_ap_minus_0x50", 0x00431E9F,
            b"\x8a\x45\x00\x83\xc0\xb0\x83\xf8\x09")
    _pin_at(ck, b, "vp_marker.cell_stride_0x17", 0x00431F81, b"\x83\xc5\x17")
    _pin_at(ck, b, "vp_marker.state_5_pushed", 0x00431F45, b"\x6a\x05")
    _pin_at(ck, b, "vp_marker.slot_written_to_0x14", 0x00431F74,
            b"\x88\x45\x09")
    _pin_at(ck, b, "vp_marker.other_cells_get_0xFF", 0x00431F79,
            b"\xc6\x45\x09\xff")
    _pin_calls(ck, b, "vp_marker.symbol_object", VP_MARKER_PLACER,
               A_SYMBOL_OBJECT, 1)
    _pin_calls(ck, b, "vp_marker.frees_the_old_one", VP_MARKER_PLACER,
               A_DELETE_SPECIAL, 1)
    _pin_calls(ck, b, "vp_marker.places_through_aCreateSpecialObject",
               VP_MARKER_PLACER, A_CREATE_SPECIAL, 1)
    sites = tuple(b.calls(TEXT_SECTION, A_VP_MARKER_PLACER))
    ck.check("vp_marker.two_callers", sites == VP_MARKER_CALL_SITES,
             str([hex(v) for v in sites]))
    _pin_calls(ck, b, "vp_marker.after_the_cell_objects", BUILD_SPECIAL_OBJECTS,
               A_VP_MARKER_PLACER, 1)
    _pin_calls(ck, b, "vp_marker.after_a_walk", EXECUTE_MOVE,
               A_VP_MARKER_PLACER, 1)
    # A free slot is `+0x40 == 0xFF`, scanned from 0 -- so the marker takes the
    # first free one, and a freed marker takes its own slot back.
    _pin_at(ck, b, "vp_marker.first_free_slot", 0x004069CB,
            b"\xb0\xff\x38\x46\x40\x74\x10\x83\xc6\x42\x47\x83\xff\x50")
    _pin_at(ck, b, "sweep.live_count_classes_0_and_2", SWEEP_LIVE_COUNT_TEST,
            SWEEP_LIVE_COUNT_BYTES)


def _check_corpus(ck: Checker, root: str) -> None:
    """The two corpus facts docs/42 §1.2 and §6.1 lean on, and the placer's
    residue in the shipped control maps (§9.3)."""
    import glob
    from inclib import charisma, lev, prototyp
    # §1.2 -- the length is the first movement's last key time, and in every
    # shipped clip every movement ends at the same time, so it is the clip's.
    paths = sorted(glob.glob(os.path.join(root, "CHData", "Animations", "*.cha")))
    with_movements = 0
    uneven: list[str] = []
    for path in paths:
        clip = charisma.parse_animation_file(path)
        if not clip.movements:
            continue
        with_movements += 1
        ends = {movement.keys[-1].time for movement in clip.movements}
        if len(ends) != 1 or clip.movements[0].keys[-1].time != max(ends):
            uneven.append(clip.name)
    ck.check("corpus.cha_files_113", len(paths) == 113, str(len(paths)))
    ck.check("corpus.cha_with_movements_112", with_movements == 112, str(with_movements))
    ck.check("corpus.every_movement_ends_together", with_movements > 0 and not uneven,
             str(uneven[:5]))
    # §6.1 -- the one shipped use of the starter's type argument works only
    # because _C_118's unit 0 is the boss it asks for.
    boss = lev.load_lev(os.path.join(root, "Missions", "_C_118.lev"))
    ck.check("corpus.C118_unit_0_is_type_61",
             bool(boss.units) and boss.units[0].type_id == 0x3D,
             str(boss.units[0].type_id if boss.units else None))
    # §9.3 -- the shipped `+0x14` is the editor's own run of the placer into
    # an empty array: in every file the cells that carry one, taken in cell
    # order, are numbered 0, 1, 2, ... whatever their action point says today
    # (`_C_133` carries 0..2 on three cells the designer later cleared), and
    # a victory point set after that build carries 0xFF.
    files = 0
    ids = 0
    uneven_ids: list[str] = []
    stale_vp = 0
    for path in sorted(glob.glob(os.path.join(root, "Missions", "*.lev"))):
        mission = lev.load_lev(path)
        run = [c.start_index for c in mission.cells if c.start_index != lev.NO_LINK]
        if run:
            files += 1
            ids += len(run)
            if run != list(range(len(run))):
                uneven_ids.append(os.path.basename(path))
        stale_vp += sum(1 for c in mission.cells
                        if 0x50 <= c.action_point <= 0x59
                        and c.start_index == lev.NO_LINK)
    ck.check("corpus.vp_marker_ids_92_files_304", (files, ids) == (92, 304),
             f"{files} files, {ids} ids")
    ck.check("corpus.vp_marker_ids_are_one_placer_run", files > 0 and not uneven_ids,
             str(uneven_ids[:5]))
    ck.check("corpus.vp_cells_without_a_marker_id_19", stale_vp == 19, str(stale_vp))
    # ...and every world set carries all ten models the placer can name.
    sets = sorted(glob.glob(os.path.join(root, "WorldSet", "World_*", "Objects",
                                         "prototyp.din")))
    short: list[str] = []
    for din in sets:
        held = {name.upper() for name in prototyp.load_container(din).names}
        if any(name.upper() not in held for name in VP_MARKER_MODELS):
            short.append(din)
    ck.check("corpus.vp_markers_in_all_9_world_sets", len(sets) == 9 and not short,
             f"{len(sets)} sets, missing in {short}")


def run_check(root: str) -> Checker:
    ck = Checker()
    path = os.path.join(root, GAME_EXE)
    if not os.path.isfile(path):
        ck.check("binary.present", False, f"{path} not found")
        return ck
    b = Binary(path)
    ck.check("binary.present", True)
    _check_camera(ck, b)
    _check_walk(ck, b)
    _check_clocks(ck, b)
    _check_fight(ck, b)
    _check_fight_corrections(ck, b)
    _check_others(ck, b)
    _check_ground_objects(ck, b)
    _check_bomb_picture(ck, b)
    _check_remove_unit_sites(ck, b)
    _check_arrived_ordering(ck, b)
    _check_teleporter(ck, b)
    _check_orbit_gate(ck, b)
    _check_bomber_arguments(ck, b)
    _check_para_bombs_phases(ck, b)
    _check_crush_wall(ck, b)
    _check_between_players(ck, b)
    _check_victory_markers(ck, b)
    _check_corpus(ck, root)
    return ck


def document(root: str) -> dict:
    b = Binary(os.path.join(root, GAME_EXE))
    table = [b.u32(0x00452E80 + 4 * i) for i in range(4)]
    return {
        "schema": "presentation-tables/2",
        "flight": {"snap_units": 0x7D00, "fast_threshold": 500, "stop_threshold": 30,
                   "fast_divisor": 3, "slow_divisor": 6},
        "unit_camera": {"quadrant_arms": [f"0x{t:08X}" for t in table],
                        "axis_extra": 3200, "target_up": 1600, "near": 9600,
                        "free_position_tries": 70, "free_position_step": 51},
        "speeds": {"walk": 2.0, "fight": 6.0, "idle": 1.5, "m2": 1.0},
        "idle_slots": [1, 2, 4, 5],
        "orbit_frames": 40,
        "orbit_text_ids": {"skill": 3, "heal": 4, "jam_hot": 6, "jam_ammo": 7,
                           "overheat": {"1": 14, "2": 15, "3": 16}},
        "marker_life": 15,
        "heal": {"power_large_kit": 3, "power_small_kit": 1, "max_hp_cap": 15,
                 "equipment_small_kit": 15, "equipment_large_kit": 16},
        "warp_acted": 5,
        "arrived_flag_kinds": sorted(ARRIVED_KINDS),
        "arrived_flag_clear_kind": ARRIVED_CLEAR_KIND,
        "death_style_by_weapon": {str(k): v for k, v in sorted(DEATH_STYLE_BY_WEAPON.items())},
        "wait_skipped_weapons": sorted(WAIT_SKIPPED_WEAPONS),
    }


def _check_setpiece_cameras(ck: Checker, b: Binary) -> None:
    """docs/42 §8 as `SetpieceCamera` reads it (docs/97 §32): the door's
    two heights and two flights, the tube's puffs at its tenth of nineteen
    frames, the lift's and the block's camera read once and set per frame,
    the roof's flight, debris, lead, drop and dust."""
    _pin_calls(ck, b, "setpiece.door.unit_height_x2", DOOR, A_UNIT_HEIGHT, 2)
    _pin_calls(ck, b, "setpiece.door.nearest_object_x2", DOOR, 0x00406F20, 2)
    _pin_calls(ck, b, "setpiece.door.camera_read", DOOR, A_READ_CAMERA, 1)
    _pin_bytes(ck, b, "setpiece.tube.puff_frame_10", TUBE, b"\x83\xfe\x0a", 1)
    _pin_bytes(ck, b, "setpiece.tube.frames_19", TUBE, b"\x83\xfe\x13", 1)
    _pin_calls(ck, b, "setpiece.tube.puffs", TUBE, A_TUBE_PUFFS, 1)
    _pin_calls(ck, b, "setpiece.tube.no_flight", TUBE, A_FLIGHT, 0)
    _pin_calls(ck, b, "setpiece.elevator.camera_read", ELEVATOR, A_READ_CAMERA, 1)
    _pin_calls(ck, b, "setpiece.platform.camera_read", PLATFORM, A_READ_CAMERA, 1)
    _pin_calls(ck, b, "setpiece.roof.camera_read", ROOF_UNIT, A_READ_CAMERA, 1)
    _pin_calls(ck, b, "setpiece.roof.flight", ROOF_UNIT, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.roof.debris", ROOF_UNIT, A_ROOF_DEBRIS, 1)
    _pin_bytes(ck, b, "setpiece.roof.lead_5", ROOF_UNIT, b"\xbf\x05\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.roof.scream_wait_4", ROOF_UNIT, b"\xbf\x04\x00\x00\x00", 1)
    _pin_calls(ck, b, "setpiece.roof.camera_per_frame", ROOF_UNIT, A_SET_CAMERA, 1)
    _pin_bytes(ck, b, "setpiece.roof.drawn_160_up", ROOF_UNIT, b"\x05\xa0\x00\x00\x00", 1)
    _pin_calls(ck, b, "setpiece.roof.landing_dust", ROOF_UNIT, A_LANDING_DUST, 1)


def _check_setpiece_creators(ck: Checker, b: Binary) -> None:
    """The eleven set-piece creators' shape, as the programs read them."""
    _pin_bytes(ck, b, "creator.tube_puffs.pairs_15", TUBE_PUFFS, b"\x83\xff\x0f", 1)
    _pin_calls(ck, b, "creator.tube_puffs.ctor_x2", TUBE_PUFFS, A_CTOR, 2)
    _pin_calls(ck, b, "creator.platform_dust.ctor_x4", PLATFORM_DUST, A_CTOR, 4)
    _pin_calls(ck, b, "creator.platform_dust.draws_x12", PLATFORM_DUST, A_RANDOM2, 12)
    _pin_bytes(ck, b, "creator.ground_debris.twenty", GROUND_UNIT_DEBRIS, b"\xc7\x44\x24\x18\x14\x00\x00\x00", 1)
    _pin_bytes(ck, b, "creator.ground_debris.kind_29_life_50", GROUND_UNIT_DEBRIS, _push8(0x32) + _push8(0x1D), 2)
    _pin_bytes(ck, b, "creator.ground_debris.discarded_draw_x2", GROUND_UNIT_DEBRIS, b"\xdd\xd8", 2)
    _pin_bytes(ck, b, "creator.roof_debris.kind_0_life_50", ROOF_DEBRIS, _push8(0x32) + _push8(0), 2)
    _pin_bytes(ck, b, "creator.roof_debris.span_40_minus_100", ROOF_DEBRIS, _push8(0x9C) + _push8(0x28), 2)
    _pin_bytes(ck, b, "creator.wall_debris.thirty", WALL_DEBRIS, b"\xc7\x44\x24\x18\x1e\x00\x00\x00", 1)
    _pin_bytes(ck, b, "creator.wall_debris.five", WALL_DEBRIS, b"\xbd\x05\x00\x00\x00", 1)
    _pin_calls(ck, b, "creator.wall_debris.draws_x13", WALL_DEBRIS, A_RANDOM2, 13)
    _pin_bytes(ck, b, "creator.fire_circle.kind_67_life_6", FIRE_CIRCLE_RING, _push8(6) + _push8(0x43), 1)
    _pin_calls(ck, b, "creator.fire_circle.rotate", FIRE_CIRCLE_RING, A_ROTATE_VECTOR, 1)
    _pin_bytes(ck, b, "creator.laser.three_x2", LASER_BEAM, b"\xc7\x44\x24\x38\x03\x00\x00\x00", 2)
    _pin_calls(ck, b, "creator.laser.direction", LASER_BEAM, A_DIRECTION, 1)
    _pin_calls(ck, b, "creator.laser.orient", LASER_BEAM, A_ORIENT, 1)
    _pin_bytes(ck, b, "creator.laser.kind_51_life_16", LASER_BEAM, _push8(0x10) + _push8(0x33), 1)
    _pin_bytes(ck, b, "creator.laser.model_kind_1_life_9", LASER_BEAM, _push8(9) + _push8(1), 1)
    _pin_bytes(ck, b, "creator.laser.down_2400", LASER_BEAM, b"\x81\xed\x60\x09\x00\x00", 1)
    _pin_bytes(ck, b, "creator.stream.kind_65_life_70", TELEPORTER_STREAM, _push8(0x46) + _push8(0x41), 1)
    _pin_calls(ck, b, "creator.stream.draws_x4", TELEPORTER_STREAM, A_RANDOM2, 4)
    _pin_bytes(ck, b, "creator.bomber.kind_52_life_150", BOMBER_CREATOR,
               _push32(0x96) + _push8(0x34), 1)
    _pin_calls(ck, b, "creator.bomber.direction", BOMBER_CREATOR, A_DIRECTION, 1)
    _pin_bytes(ck, b, "creator.bomber.clears_arrived", BOMBER_CREATOR, b"\xc7\x05\x3c\xe6\x4f\x00\x00\x00\x00\x00", 1)
    _pin_bytes(ck, b, "creator.para_bomb.kind_25", PARA_BOMB_CREATOR, _push8(0x19), 1)
    _pin_bytes(ck, b, "creator.para_bomb.rot_y_64", PARA_BOMB_CREATOR, _push8(0x40), 1)
    _pin_bytes(ck, b, "creator.para_bomb.clears_arrived", PARA_BOMB_CREATOR, b"\xc7\x05\x3c\xe6\x4f\x00\x00\x00\x00\x00", 1)


def _check_unit_animation_creators(ck: Checker, b: Binary) -> None:
    """docs/42 §7 -- the seven creators' literals, as the programs in
    `blob_creators.py` read them (docs/97 §31)."""
    word = lambda disp, value: b"\x66\xc7\x44\x24" + bytes([disp]) + struct.pack("<H", value)
    # The marker: two radii, a quarter turn, one orientation, one constructor.
    _pin_bytes(ck, b, "creator.arrows.radius_large", ARROWS, b"\xbf\x80\x25\x00\x00", 1)
    _pin_bytes(ck, b, "creator.arrows.radius", ARROWS, b"\xbf\xc0\x12\x00\x00", 1)
    _pin_bytes(ck, b, "creator.arrows.quarter_turn", ARROWS, word(0x28, 0x400), 1)
    _pin_calls(ck, b, "creator.arrows.rotate", ARROWS, A_ROTATE_VECTOR, 1)
    _pin_calls(ck, b, "creator.arrows.orient", ARROWS, A_ORIENT, 1)
    _pin_calls(ck, b, "creator.arrows.ctor", ARROWS, A_CTOR, 1)
    # The landing dust: 3200 out, 204 a puff, rising 800.
    _pin_bytes(ck, b, "creator.landing_dust.radius", LANDING_DUST, b"\xbf\x80\x0c\x00\x00", 1)
    _pin_bytes(ck, b, "creator.landing_dust.turn", LANDING_DUST, word(0x20, 0xCC), 1)
    _pin_bytes(ck, b, "creator.landing_dust.rise", LANDING_DUST, b"\x68\x20\x03\x00\x00", 1)
    _pin_calls(ck, b, "creator.landing_dust.ctor", LANDING_DUST, A_CTOR, 1)
    # The heal flash: the flash radii, a twelfth of a turn, two constructors
    # (the cross and its mirror image).
    _pin_bytes(ck, b, "creator.flash_heal.radius_large", FLASH_HEAL, b"\xbd\x00\x19\x00\x00", 1)
    _pin_bytes(ck, b, "creator.flash_heal.radius", FLASH_HEAL, b"\xbd\x40\x06\x00\x00", 1)
    _pin_bytes(ck, b, "creator.flash_heal.twelfth_turn", FLASH_HEAL, word(0x34, 0x155), 1)
    _pin_calls(ck, b, "creator.flash_heal.ctor_x2", FLASH_HEAL, A_CTOR, 2)
    # The poison flash: the **flash** radii, not the marker's, a quarter turn.
    _pin_bytes(ck, b, "creator.flash_poison.radius_large", FLASH_POISON, b"\xbf\x00\x19\x00\x00", 1)
    _pin_bytes(ck, b, "creator.flash_poison.radius", FLASH_POISON, b"\xbf\x40\x06\x00\x00", 1)
    _pin_bytes(ck, b, "creator.flash_poison.quarter_turn", FLASH_POISON, word(0x28, 0x400), 1)
    _pin_calls(ck, b, "creator.flash_poison.ctor", FLASH_POISON, A_CTOR, 1)
    # The trail: one zoom bob, four sprites falling from 640, delayed by index.
    _pin_calls(ck, b, "creator.trail.zoombob", TRAIL, A_ZOOMBOB, 1)
    _pin_bytes(ck, b, "creator.trail.fall_640", TRAIL, b"\x2d\x80\x02\x00\x00", 1)
    _pin_bytes(ck, b, "creator.trail.four", TRAIL, b"\x83\xfe\x04", 1)
    _pin_calls(ck, b, "creator.trail.ctor", TRAIL, A_CTOR, 1)


def _check_marker_sites(ck: Checker, b: Binary) -> None:
    """docs/42 §7.3 -- the marker is raised **on a selection and after a pad
    command**, never per frame: `0x00473920` gates on the animation level and
    a selected unit, and its three callers are the select routine and the
    command pad.  The frame loop calls neither it nor the creator."""
    _pin_calls(ck, b, "marker.raise.anim_level_gate", MARKER_RAISE, A_ANIM_LEVEL, 1)
    _pin_bytes(ck, b, "marker.raise.selected_gate", MARKER_RAISE,
               b"\x66\x81\x3d\xf8\x62\x51\x00\xff\xff", 1)
    _pin_calls(ck, b, "marker.raise.creator", MARKER_RAISE, A_ARROWS, 1)
    _pin_calls(ck, b, "marker.select_raises", SELECT_UNIT, A_MARKER_RAISE, 1)
    _pin_calls(ck, b, "marker.pad_raises_x2", COMMAND_PAD, A_MARKER_RAISE, 2)
    sites = len(b.calls(TEXT_SECTION, A_MARKER_RAISE))
    ck.check("marker.raise_sites", sites == 3, f"{sites} call site(s) in .text")
    _pin_calls(ck, b, "marker.frame_loop_never", MAIN_LOOP, A_ARROWS, 0)
    _pin_calls(ck, b, "marker.frame_loop_never_raises", MAIN_LOOP, A_MARKER_RAISE, 0)
    # The four orbits raise it themselves (docs/42 §7.5).
    for name, rng in (("skill", ORBIT_SKILL), ("jam", ORBIT_JAM),
                      ("overheat", ORBIT_OVERHEAT), ("rotating", ORBIT_ROTATING)):
        _pin_calls(ck, b, f"marker.orbit_{name}_raises", rng, A_ARROWS, 1)


def _check_command_arms(ck: Checker, b: Binary) -> None:
    """The three `core` rules slice C found missing (docs/97 §31): the drain's
    jam arm, the heal command, and the pad's warp arm."""
    # docs/25 §6 -- after a reaction shot, an empty magazine or a heat counter
    # at the cap plays the jam orbit and clears the ticket, in **both** loops.
    _pin_calls(ck, b, "drain.attack_x2", DRAIN, A_ATTACK_UNIT, 2)
    _pin_bytes(ck, b, "drain.ammo_read_x4", DRAIN, b"\x8a\x46\x3d", 4)
    _pin_calls(ck, b, "drain.heat_cap_x4", DRAIN, A_HEAT_CAP, 4)
    _pin_calls(ck, b, "drain.jam_orbit_x2", DRAIN, A_JAM_ORBIT, 2)
    _pin_bytes(ck, b, "drain.ticket_cleared_x2", DRAIN, b"\xc6\x46\x59\x00", 2)
    # docs/29 §1.1 button 2 -- the heal command.
    _pin_bytes(ck, b, "heal.power.large_kit_is_3", HEAL_POWER, b"\x38\x48\x31", 1)
    _pin_bytes(ck, b, "heal.power.small_kit_is_1", HEAL_POWER, b"\x8a\x58\x30", 1)
    _pin_bytes(ck, b, "heal.power.three", HEAL_POWER, b"\xb8\x03\x00\x00\x00", 1)
    _pin_bytes(ck, b, "heal.max_hp.alien_is_type", MAX_HIT_POINTS, b"\x80\x79\x45\xff", 1)
    _pin_bytes(ck, b, "heal.max_hp.ep_over_12", MAX_HIT_POINTS, b"\xb8\xab\xaa\xaa\x2a", 1)
    _pin_bytes(ck, b, "heal.max_hp.cap_15", MAX_HIT_POINTS, b"\x83\xf8\x0f", 1)
    _pin_calls(ck, b, "heal.apply.reads_max", HEAL_APPLY, A_MAX_HIT_POINTS, 2)
    _pin_bytes(ck, b, "heal.apply.adds_power", HEAL_APPLY, b"\x02\xc3\x88\x46\x16", 1)
    _pin_bytes(ck, b, "heal.command.mp_gate", HEAL_COMMAND, b"\x8a\x46\x15", 1)
    _pin_calls(ck, b, "heal.command.power", HEAL_COMMAND, A_HEAL_POWER, 1)
    _pin_calls(ck, b, "heal.command.cell_in_front", HEAL_COMMAND, A_CELL_IN_FRONT, 1)
    _pin_calls(ck, b, "heal.command.max_x2", HEAL_COMMAND, A_MAX_HIT_POINTS, 2)
    _pin_calls(ck, b, "heal.command.apply_x2", HEAL_COMMAND, A_HEAL_APPLY, 2)
    _pin_calls(ck, b, "heal.command.orbit_x2", HEAL_COMMAND, A_HEAL_ORBIT, 2)
    _pin_bytes(ck, b, "heal.command.other_player_skipped", HEAL_COMMAND, b"\x8a\x4e\x45\x8a\x47\x45", 1)
    # The pad arm: one movement point off only when the command answered 1,
    # `+0x39 = 3` **unconditionally** -- the join at 0x004733F3.
    _pin_calls(ck, b, "heal.pad.command", HEAL_PAD_ARM, A_HEAL_COMMAND, 1)
    _pin_bytes(ck, b, "heal.pad.charge_one", HEAL_PAD_ARM, b"\xfe\xc8\x88\x46\x15", 1)
    _pin_bytes(ck, b, "heal.pad.acted_3", HEAL_PAD_ARM, b"\xc6\x46\x39\x03", 1)
    # The offer: `0x0047B4C0` (a kit, a patient or self under the ceiling)
    # and `cmp byte [esi + 0x15], 1 / jb`.
    _pin_calls(ck, b, "heal.offer.gate", HEAL_OFFER, A_MAY_HEAL, 1)
    _pin_bytes(ck, b, "heal.offer.needs_a_point", HEAL_OFFER, b"\x80\x7e\x15\x01", 1)
    _pin_calls(ck, b, "heal.gate.power", MAY_HEAL, A_HEAL_POWER, 1)
    _pin_calls(ck, b, "heal.gate.cell_in_front", MAY_HEAL, A_CELL_IN_FRONT, 1)
    _pin_calls(ck, b, "heal.gate.max_x2", MAY_HEAL, A_MAX_HIT_POINTS, 2)
    # The warp arm: `aExecuteWarp`, then for a mover still alive `mp = 0`,
    # `+0x39 = 5` and the drain.
    _pin_calls(ck, b, "warp.pad.execute", WARP_PAD, A_EXECUTE_WARP, 1)
    _pin_bytes(ck, b, "warp.pad.mp_zeroed", WARP_PAD, b"\xc6\x46\x15\x00", 1)
    _pin_bytes(ck, b, "warp.pad.acted_5", WARP_PAD, b"\xc6\x46\x39\x05", 1)
    _pin_calls(ck, b, "warp.pad.drain", WARP_PAD, A_DRAIN, 1)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", metavar="ROOT")
    ap.add_argument("--json", metavar="ROOT")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s")
    if args.json:
        json.dump(document(args.json), sys.stdout, indent=1)
        sys.stdout.write("\n")
        return 0
    if not args.check:
        ap.error("--check ROOT or --json ROOT")
    try:
        ck = run_check(args.check)
    except PEError as exc:
        LOG.error("%s", exc)
        return 1
    for line in ck.lines:
        if line.startswith("FAIL") or args.verbose:
            print(line)
    total = ck.passed + len(ck.failed)
    print(f"presentation_tables: {ck.passed}/{total} checks passed")
    return 0 if ck.failed == [] and ck.passed > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
