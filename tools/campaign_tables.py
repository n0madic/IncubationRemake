#!/usr/bin/env python3
"""Verify the campaign layer described in ``docs/27`` against the binary and
the corpus.

Six kinds of thing are checked:

**The location model.**  A campaign position is one byte -- the ``.lev``
header's mission id at ``+0x223`` -- and the campaign map's cells carry
*location* ids in their action-point byte.  The two are one addition apart:
``location = missionId + 50``, an ``add eax, 0x32`` that appears at two sites.
``aMapName`` ``0x0045C200`` is the inverse table, read out of the compiler's
own jump table, and the round trip is replayed over every shipped campaign
mission.

**The unlock graph.**  ``aCreateLocationMap`` ``0x00431420`` is a 79-arm
``switch`` whose arms are straight-line calls to one setter.  Decoding them
gives the complete campaign graph -- which locations the map offers once a
given mission is next -- and every location it names is required to exist as a
cell of the right campaign map.

**The unit pool.**  ``docs/10`` §5.11 and ``docs/11`` §5.7 own the storage;
what is checked here is the *runtime*: the three named soldiers a new campaign
starts with, the recruit seeding, the survival gate, and the two directions the
working row is copied in.

**The economy.**  Equipment points are one ``u32[4]``; the recruit price is
weapon 0's cost plus fifty, which is cross-checked against ``Info.lcl``.

**Mission end.**  The result-to-score table, the two payouts that are campaign
only, and the two debriefing buttons that carry state forward.

**The chain.**  Every ``.lev`` header's next-map name and every
``EnterNameOfNextMap`` argument must name a shipped mission.

Every check fails on an empty corpus: a check that examined nothing is not a
check that passed.  Nothing here reads ``tests/fixtures/saves``.

Usage::

    python3 tools/campaign_tables.py --check gog_incubation
    python3 tools/campaign_tables.py --locations gog_incubation
    python3 tools/campaign_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import struct
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import lcl  # noqa: E402
from inclib.lev import load_lev  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("campaign_tables")

GAME_EXE = "Incubation.exe"

# --- the persistent roster (docs/10 §5.11, docs/11 §5.7) --------------------
POOL_BASE = 0x0051F2A0
POOL_STRIDE = 0x5B
POOL_SLOTS = 30
HP_OFFSET = 0x16

# --- location <-> mission id ------------------------------------------------
LOCATION_BIAS = 50
#: `add eax, 0x32`, imm8 at +2.
LOCATION_BIAS_SITES = (0x00455486, 0x004541D5)
LEV_HEADER_BASE = 0x004FCED0
HEADER_BASE_GETTER = 0x00419B10
#: getter -> (offset of the imm32 inside it, the header offset it reads).
HEADER_GETTERS = {
    0x00419B30: (3, 0x223),     # mission id -- `xor eax,eax; mov al,[imm32]`
    0x00419B50: (1, 0x21A),     # skill level
    0x00419B70: (1, 0x21E),     # tech level
}
#: `mov eax, [eax*4 + 0x4FD0DA]`, u32 at +7.
EQUIP_POINTS_GETTER = 0x00419B00
EQUIP_POINTS_OFFSET = 0x20A

# --- aMapName ---------------------------------------------------------------
MAP_NAME = 0x0045C200
MAP_NAME_BIAS_SITE = 0x0045C205         # `add eax, -0x33`, imm8 at +2
MAP_NAME_BIAS = 0x33
MAP_NAME_LIMIT_SITE = 0x0045C209        # `cmp eax, 0x4E`, imm8 at +2
MAP_NAME_TABLE = 0x0045C538
MAP_NAME_ENTRIES = 0x4F
MAP_NAME_DEFAULT = 0x0045C52D
#: The one campaign mission no location names: the epilogue.
MAP_NAME_ORPHAN = ("_C_180", 180)
#: Table entries that name missions the release does not ship.
CUT_MISSIONS = {85: "_C_134", 86: "_C_135", 87: "_C_136"}
#: Locations 88 and 89 fall through to the default arm.
MAP_NAME_UNNAMED = [88, 89]

# --- aCreateLocationMap -----------------------------------------------------
CREATE_LOCATION_MAP = 0x00431420
LOCATION_MAP_CLEAR = 0x00431E00
LOCATION_MAP_SET = 0x00431350
LOCATION_MAP_TABLE = 0x00431CB8
LOCATION_MAP_ENTRIES = 0x4F
LOCATION_MAP_DEFAULT = 0x00431C98
LOCATION_MAP_LIMIT_SITE = 0x0043142A    # `cmp eax, 0x4E`, imm8 at +2
LOCATION_MAP_GAPS = (35, 36, 37, 38, 39)
LOCATION_MAP_BRANCHES = ((21, 22), (43, 44), (54, 55), (59, 60), (69, 70))
#: The (location, flag) pairs the 74 live arms hold, in total.
LOCATION_MAP_PAIRS = 156
#: How often each location is enabled across the whole graph -- the graph
#: itself, in a form one changed `push` cannot survive.
LOCATION_MAP_COUNTS = {
    1: 6, 2: 4, 3: 2, 4: 4, 5: 1, 6: 7, 7: 2, 8: 6,
    10: 1, 11: 1, 15: 1, 22: 1, 23: 1, 51: 1, 52: 1, 53: 2,
    54: 2, 55: 1, 56: 1, 57: 1, 58: 1, 59: 2, 60: 2, 61: 1,
    62: 1, 63: 1, 64: 1, 65: 1, 66: 1, 67: 1, 68: 1, 69: 1,
    70: 1, 71: 2, 72: 2, 73: 1, 74: 1, 75: 1, 76: 1, 77: 1,
    78: 1, 79: 1, 80: 1, 81: 1, 82: 1, 83: 1, 84: 1, 90: 1,
    91: 1, 92: 1, 93: 2, 94: 2, 95: 1, 96: 1, 97: 1, 98: 1,
    99: 1, 100: 1, 101: 1, 102: 1, 103: 1, 104: 2, 105: 2, 106: 1,
    107: 1, 108: 1, 109: 2, 110: 2, 111: 1, 112: 1, 113: 1, 114: 1,
    115: 1, 116: 1, 117: 1, 118: 1, 119: 2, 120: 2, 121: 1, 122: 1,
    123: 1, 124: 1, 125: 1, 126: 1, 127: 1, 128: 1, 129: 1, 210: 4,
    211: 6, 212: 5, 213: 2, 214: 5, 215: 5, 216: 4,
}
#: Two cells of `_C_XXX` no arm ever opens -- `Campaign.lcl` calls them
#: `TEST EXTRO` and `<<Invalid Location>>`.
UNREACHABLE_LOCATIONS = {21, 50}
#: `0x00431350` walks the cell array with the `.lev` stride and writes `+0x00`.
#: `neg ecx; sbb cl,cl; and cl,2; inc cl` -- 3 when the flag is set, 1 when not.
CELL_STATE_AND_SITE = 0x00431388        # `and cl, 2`, imm8 at +2
CELL_STATE_INC_SITE = 0x0043138B        # `inc cl`
CELL_STATE_STORE_SITE = 0x0043138D      # `mov [esi], cl`
CELL_STRIDE_SITE = 0x0043138F           # `add esi, 0x17`, imm8 at +2
CELL_STRIDE = 0x17
CELL_AP_SITE = 0x00431372               # `mov al, [esi+0x0B]`, imm8 at +2
CELL_AP_OFFSET = 0x0B
CELL_STATE_ENABLED = 3
CELL_STATE_DISABLED = 1

# --- the campaign maps ------------------------------------------------------
#: `mov edi, imm32`, u32 at +1.
CAMPAIGN_MAP_SITES = {1: 0x00457603, 2: 0x004575F5}
CAMPAIGN_MAP_NAMES = {1: "_C_xxx", 2: "_C_yyy"}
CAMPAIGN_NUMBER_GETTER = 0x0043B760     # `mov al, [0x509EE9]`, u32 at +1
CAMPAIGN_NUMBER_SETTER = 0x0043B750
GAME_CONTROL_BASE = 0x00509D18
CAMPAIGN_NUMBER_OFFSET = 0x1D1
UPGRADE_ANIMATION = 0x00417510
UPGRADE_FORMAT_SITE = 0x00417541        # `push "upgrade_%d"`, u32 at +1
UPGRADE_FORMAT = "upgrade_%d"
CREATE_BATTLE_MAP = 0x00417BD0

# --- aLocationHandling ------------------------------------------------------
LOCATION_HANDLING = 0x0045C7D0
HANDLING_INDEX_TABLE = 0x0045CF8C
HANDLING_INDEX_LEN = 0xD8               # locations 1 .. 216
HANDLING_JUMP_TABLE = 0x0045CF2C
HANDLING_JUMP_LEN = 24
#: two of the 24 slots hold the same address -- the shared battle arm.
HANDLING_DISTINCT_ARMS = 23
HANDLING_DEFAULT = 0x0045CE75
UPGRADE_LOCATIONS = (1, 2, 3, 4, 5, 6, 7, 8,
                     210, 211, 212, 213, 214, 215, 216)
#: location -> the number its arm passes to `aPlayLocationAnimation_Upgrade`,
#: i.e. the `upgrade_N.lev` it loads.  **Locations 3 and 6 are crossed**: the
#: id is the map's, not the location's, for those two alone.
UPGRADE_MAPS = {1: 1, 2: 2, 3: 6, 4: 4, 5: 5, 6: 3, 7: 7, 8: 8,
                210: 210, 211: 211, 212: 212, 213: 213, 214: 214,
                215: 215, 216: 216}
#: The catalogue limits an upgrade location's arm writes -- the low end and
#: the high, in that order.  `0x0045BF2A`'s campaign arm copies the pair into
#: `0x00510A34`/`0x00510A35`, so a base's shop is its own band of tech levels.
UPGRADE_BAND_SITES = (0x00510C5C, 0x00510C5D)
#: How far past an arm's entry the two writes sit.  The arms are ~0x70 bytes.
UPGRADE_BAND_WINDOW = 0xC0
#: `xor ebx, ebx` in `aPlayLocationAnimation`'s prologue, which is why
#: `mov byte [addr], bl` writes a zero.
UPGRADE_BAND_ZERO_SITE = 0x0045C7E0
#: Decoded from the fifteen arms: location -> `(low, high)`.  Location 5 sells
#: only tech 9 and location 4 only tech 1; 214 only tech 3.
UPGRADE_TECH_BANDS = {
    1: (0, 0), 2: (0, 3), 3: (0, 5), 4: (1, 1), 5: (9, 9),
    6: (0, 4), 7: (0, 9), 8: (0, 2),
    210: (0, 0), 211: (0, 1), 212: (0, 2), 213: (0, 3),
    214: (3, 3), 215: (0, 4), 216: (0, 9),
}
#: The two pairs of locations whose bodies the compiler **tail-merged**, so
#: both members sell the same band.  Reading these arms linearly walked into
#: the next location's body and gave 1 the band of 2 and 7 the band of 8 --
#: which is what made base 7 sell seven weapons instead of sixteen.
UPGRADE_SHARED_BODIES = ((1, 210), (7, 216))
# -- the Recruit window's five categories, docs/27 section 3.2 ---------------
#: `0x0045615F` clears these five to -1 before `0x004561C9`'s jump table fills
#: the chosen category's, one `mov dword [slot], imm32` per row.
RECRUIT_SLOTS = tuple(0x00510A14 + 4 * k for k in range(5))
RECRUIT_RESET_SITE = 0x0045615F           # `xor ebx, ebx` / `or ebp, -1`
RECRUIT_SWITCH_SITE = 0x004561C9          # `jmp dword [eax*4 + imm32]`
RECRUIT_JUMP_TABLE = 0x00456624
RECRUIT_ARM_END = 0x0045657B
#: Read out of the arms.  **Not five bases of five**: categories 0 and 2 fill
#: four slots and leave the fifth at -1, and category 3's fifth is 35.
RECRUIT_CATEGORY_TYPES = {
    0: (0, 1, 2, 3),
    1: (10, 11, 12, 13, 14),
    2: (20, 21, 22, 23),
    3: (30, 31, 32, 33, 35),
    4: (40, 41, 42, 43, 44),
}

# -- the base's own camera, docs/27 section 2.7 ------------------------------
#: `aPlayLocationAnimation_Upgrade` `0x00417510` builds `upgrade_N` and hands
#: it to this, which flies the eye down the script's own waypoints.
LOCATION_ANIMATION = 0x00417000
#: `aGetCameraPath` and its writer, `CreateCameraPath`'s handler.
CAMERA_PATH_GET = 0x004173E0
CAMERA_PATH_SET = 0x00416ED0
#: The five 140-byte records: `count`, `cursor`, nine waypoints of 12 from
#: `+0x08`, and the look-at target at `+0x80`.
CAMERA_PATH_TABLE = 0x004FCBE8
CAMERA_PATH_TABLE_SITE = 0x00416F21      # `mov ecx, [eax + imm32]`, u32 at +2
CAMERA_PATH_CAP_SITE = 0x00416F27        # `cmp ecx, 9`, imm8 at +2
CAMERA_PATH_CAP = 9
CAMERA_PATH_SHIFT_SITE = 0x00416F52      # `shl edx, 4`, imm8 at +2
CAMERA_PATH_SHIFT = 4
#: The window the fly-in renders into, and the one it puts back on the way
#: out.  The first is the location map's (docs/27 section 2.6); the second is
#: a mission's.  `push h; push w; push y; push x`, so they read backwards.
LOCATION_ANIMATION_WINDOW_SITES = (0x00417023, 0x00417021, 0x0041701C,
                                   0x00417017)
LOCATION_ANIMATION_WINDOW = (65, 57, 518, 306)
LOCATION_ANIMATION_EXIT_SITES = (0x00417190, 0x0041718E, 0x00417189,
                                 0x00417184)
LOCATION_ANIMATION_EXIT_WINDOW = (60, 34, 520, 340)
#: The flight's own step law, `0x00417000` read whole (docs/27 section 2.7).
#: It is an exponential approach and not a constant step: the eye's velocity
#: closes on `_ftol(direction * 800)` by `(want - velocity) / n`, with `n`
#: reset to 40 on every leg and falling by one a frame to a floor of 5.  A leg
#: ends when the eye is within 3200 of its waypoint on every axis; the **last**
#: leg counts `800 * remaining / leg` down and lands under 80.
FLY_SPEED = 800
FLY_SPEED_SITE = 0x004171DE               # `mov [esp+0x20], 0x320`, u32 at +4
FLY_SMOOTH_START = 40
FLY_SMOOTH_START_SITE = 0x004171C9        # `mov ebp, 0x28`, u32 at +1
FLY_SMOOTH_FLOOR = 5
FLY_SMOOTH_FLOOR_SITE = 0x00417316        # `cmp <n>, 5`
FLY_ARRIVAL = 3200
FLY_ARRIVAL_SITES = (0x004171FF, 0x00417212, 0x00417224)  # `cmp eax, 0xc80`
FLY_LANDED_SHARE = 80
FLY_LANDED_SITE = 0x0041729E              # `cmp [esp+0x20], 0x50`, imm8 at +4
#: The direction helper `0x0046d400`: the two horizontal components are
#: divided by the larger of them, and the vertical is the height difference
#: over the horizontal distance `0x0044ae10` -- with **all six** coordinates
#: shifted right by three first, not the two heights alone.  The helper has
#: two arms and the shift is the one the flight asks for: its last argument is
#: the `push 1` at `0x004172b1`, and the zero arm passes the coordinates
#: whole.  Shifting only the rise divides by eight times the distance, which
#: leaves the eye a few hundred units off the ground for a whole flight
#: (docs/27 section 2.7).
FLY_DIRECTION = 0x0046D400
FLY_DIRECTION_SHIFT = 3
#: `push 1` -- the first push of the ten-argument call, so the last argument.
FLY_DIRECTION_ARM_SITE = 0x004172B1
FLY_DIRECTION_ARM = 1
#: The six `sar reg, 3` of that arm, in the order the listing has them:
#: `goal.z`, `eye.z`, `goal.y`, `goal.x`, `eye.y`, `eye.x`.  Each coordinate
#: is shifted on its own -- `sar` floors, so this is not the difference
#: shifted: the two readings part wherever the operands' remainders cross.
FLY_DIRECTION_SHIFT_SITES = (0x0046D4EC, 0x0046D4EF, 0x0046D4F2,
                             0x0046D4F5, 0x0046D4FB, 0x0046D504)
FLY_FLAT_DISTANCE = 0x0044AE10
FLY_FLAT_DISTANCE_SITE = 0x0046D508
#: The front end's frame, and the limiter it ends on -- `min, max` frames a
#: second, so the whole flight is stepped at 20.
FRONT_END_FRAME = 0x0040B6F0
FRAME_LIMITER = 0x0047F2E0
FRAME_LIMITER_SITE = 0x0040B82D           # `push 0x14; push 0x0a`
FRAME_LIMIT = (10, 20)
#: `0x004fcbdc`, which `0x0040b6f0` sets on a key or a click and the flight
#: reads to land early.
FRONT_END_INPUT_FLAG = 0x004FCBDC

# -- the base's own marines, docs/27 section 2.7.1 ---------------------------
#: Between `aCreateBattleMap(3)` and the flight, `0x00417510` walks **player
#: 0's living units** and starts one animation on each.  `upgrade_N.lev` places
#: two or three of them, so the landing pad the fly-in crosses is not empty:
#: the marines march down it.
#:
#: The loop is `aUnitMap.cpp`'s own pair.  `0x00477C20(player)` scans the 200
#: slots of 91 bytes for the first with `+0x16` (hit points) non-zero and
#: `+0x45` (owning player) equal, and `0x00477C60(player, id)` continues from
#: `id + 1`; both answer `0xFFFF` when there is none.  `0x00477AE0(id)` is the
#: record pointer and refuses a dead slot, which is the same test again.
UPGRADE_UNIT_FIRST = 0x00477C20
UPGRADE_UNIT_NEXT = 0x00477C60
UPGRADE_UNIT_POINTER = 0x00477AE0
UPGRADE_UNIT_FIRST_SITE = 0x00417609      # `push 0` then the call
UPGRADE_UNIT_NEXT_SITE = 0x00417641
UPGRADE_UNIT_POINTER_SITE = 0x00417623
#: The player the loop asks for -- `push 0` at `0x00417607` and `push 0` again
#: at `0x0041763F`, the argument both halves of the pair take.
UPGRADE_UNIT_PLAYER = 0
UPGRADE_UNIT_PLAYER_SITES = (0x00417607, 0x0041763F)
#: The unit record, from docs/10 section 5: 91 bytes, hit points at `+0x16`
#: (zero means the slot holds nobody) and the owning player at `+0x45`.
UNIT_RECORD_STRIDE = 91
UNIT_RECORD_HP = 0x16
UNIT_RECORD_PLAYER = 0x45
#: `fcn.004055e0(slot, unit, kind)`, docs/40 section 7.2's start-animation
#: entry point.  The upgrade arm passes `kind = 4` and `slot = id + 7`.
START_ANIMATION = 0x004055E0
START_ANIMATION_SITE = 0x00417636
UPGRADE_ANIM_KIND = 4
UPGRADE_ANIM_KIND_SITE = 0x0041762F       # `push 4`, imm8 at +1
UPGRADE_ANIM_SLOT_BIAS = 7
UPGRADE_ANIM_SLOT_SITE = 0x00417631       # `lea ecx, [esi + 7]`, imm8 at +2
#: `kind == 4`'s own playback arm, `0x00405B88`, reached through the second of
#: `fcn.004055e0`'s two jump tables (`0x00405C94`).  It is the one arm that
#: names its clip as a literal instead of asking a selector, and the one that
#: starts the clip at a **random** time: `aRandom2(0, 10)` returns a float and
#: goes straight into the animation's own time setter, so three marines
#: started in the same frame are not in step.  `aRandom2` `0x004638E0` is the
#: GetTickCount-seeded generator of docs/22 section 3.2, which is what says
#: this is cosmetic and outside every hash.
UPGRADE_ANIM_ARM = 0x00405B88
UPGRADE_ANIM_TABLE = 0x00405C94
UPGRADE_ANIM_LOOPS = 100000
UPGRADE_ANIM_LOOPS_SITE = 0x00405BDE      # `push 0x186a0`, u32 at +1
UPGRADE_ANIM_SPEED = 1.0
UPGRADE_ANIM_SPEED_SITE = 0x00405BE8      # `push 0x3f800000`, u32 at +1
UPGRADE_ANIM_START_MAX = 10
UPGRADE_ANIM_START_SITE = 0x00405BF2      # `push 10; push 0`, imm8 at +1
UPGRADE_ANIM_RANDOM = 0x004638E0
UPGRADE_ANIM_RANDOM_SITE = 0x00405BF6
#: The clip itself, `docs/40` section 7.2's fourth row: a fixed literal no
#: selector returns.  452 frames long, and its top-level bone travels 3017.7
#: skeleton units down its own -Y, so the walk is the clip's and no command
#: moves the unit.
UPGRADE_ANIM_CLIP_SITE = 0x004056D2        # `mov edi, 0x4c030c`, u32 at +1
UPGRADE_ANIM_CLIP_VA = 0x004C030C
UPGRADE_ANIM_CLIP = "P0_M2_000"

#: `aGetCameraPosition` into six globals, called by every upgrade arm right
#: after the fly-in; `0x00455A40`'s zero arm pushes the same six back into
#: `aSetCameraPosition` on every Mission Control frame, which is why the
#: menus sit over the resting point of the flight.
CAMERA_SAVE = 0x00403780
CAMERA_SAVED = (0x00510D2C, 0x00510D30, 0x00510D34,
                0x00510D38, 0x00510D3C, 0x00510D40)
CAMERA_RESTORE_SITE = 0x00455A40
CAMERA_RESTORE_READS = (0x00455A6C, 0x00455A71, 0x00455A77,
                        0x00455A7E, 0x00455A84, 0x00455A8B)

BATTLE_LOCATIONS = tuple(range(51, 89)) + tuple(range(90, 130))
#: location -> the number `0x00456FC0` is called with.  What that number picks
#: inside `Video/` belongs to package G -- see docs/27 §2.3.
DIALOGUE_LOCATIONS = {10: 2, 11: 3, 12: 7, 13: 7, 14: 7, 15: 7,
                      16: 1, 17: 1, 18: 1, 19: 1, 20: 1, 21: 1,
                      22: 14, 23: 15}
DIALOGUE_SCREEN = 0x00456FC0

# --- aCreateUnitPoolForCampaign --------------------------------------------
CREATE_POOL = 0x00478710
POOL_CAMPAIGN2_SITE = 0x00478716        # `cmp eax, 2`, imm8 at +2
POOL_CAMPAIGN2 = 2
ENLARGE_POOL = 0x004789B0
POOL_SEED_CALLS = (0x00478720, 0x0047874B, 0x00478776)
TEXT_BANK_SITE = 0x004787A6             # `push 3`, imm8 at +1
TEXT_BANK = 3
TEXT_SET_BANK = 0x00471090
TEXT_GET = 0x00470FE0
SQUAD_NAME_SITES = (0x004787B2, 0x004787C9, 0x004787F5)
SQUAD_NAME_IDS = (0x3C, 0x3D, 0x3E)
SQUAD_NAMES = ("Bratt", "West", "Maxon")
SQUAD_TEXT_FILE = "Txtmod_h.lcl"
SQUAD_RECORDS = (0x0051F2A0, 0x0051F2FB, 0x0051F356)
SQUAD_WRITE_BLOCK = (0x0047883B, 0x004788A5)
SQUAD_AL_SITE = 0x00478831              # `mov al, 0x0C`, imm8 at +1
#: (record, offset) -> value, decoded from the block above.
SQUAD_FIELDS = {
    (0, 0x4D): 2,     (0, 0x18): 0,     (0, 0x17): 0x11,
    (0, 0x1B): 1,     (0, 0x1F): 2,     (0, 0x4C): 0x17,  (0, 0x55): 0x0A,
    (1, 0x18): 0,     (1, 0x17): 0x0C,  (1, 0x1E): 2,
    (1, 0x30): 1,     (1, 0x55): 3,
    (2, 0x18): 0x0C,  (2, 0x17): 0x0C,  (2, 0x1C): 1,     (2, 0x55): 4,
}
HERO_UNIT_TYPE = 0x17
HERO_UNIT_NAME = "Sgt. Bratt"
HERO_FLAG_OFFSET = 0x4D
HERO_FLAG = 2
EQUIPMENT_BASE = 0x21
MEDIC_EQUIPMENT_ID = 15
MEDIC_EQUIPMENT_NAME = "Small Medic Kit"

# --- aEnlargeUnitPool -------------------------------------------------------
ENLARGE_SLOTS_SITE = 0x004789F5          # `cmp edi, 0x1E`, imm8 at +2
#: `mov bl, [eax + ecx*2 + 0x51F2B6]` -- the free-slot scan, u32 at +3.
FREE_SLOT_SITES = (0x004789E4, 0x00478C43)
USED_SLOT_SITES = (0x004788E8, 0x00478988)
GAME_MODE_GETTER = 0x0043B740
HUMAN_COUNT = 0x0043B700
MODE_CAMPAIGN = 1
ENLARGE_MODE_CMP_SITE = 0x00478A07       # `cmp eax, 1`, imm8 at +2
ENLARGE_RANK_CALL = 0x00478A13           # `call 0x0043B0D0`
SKILL_LEVEL_GLOBAL = 0x00509F00
SKILL_LEVEL_GET = 0x0043B0D0
SKILL_LEVEL_SET = 0x0043B0E0
TECH_LEVEL_GLOBAL = 0x00509F04
#: Every ``.text`` reference to the tech-level global: the multiplayer init
#: arm, the campaign init arm, and the setter's and getter's own stores.  Four,
#: which is what says a campaign's tech level cannot move (``docs/27`` §5.2).
TECH_LEVEL_GLOBAL_REFS = (0x0043ADAB, 0x0043AEBD, 0x0043AF95, 0x0043AFA1)
#: ``setTechLevel``'s five call sites, all in ``aMenuSystem.cpp``.
TECH_LEVEL_SETTER_SITES = (0x0044D816, 0x0044EDAA, 0x0044EE36, 0x0044FDB4,
                           0x0044FFF2)

# --- aInitGameControl 0x0043AD20: two arms, and the campaign's is 0x0043AE76 -
#: ``mov byte [0x509F04], 4`` in the multiplayer arm; imm8 at +6.
GAME_CONTROL_TECH_MP_SITE = 0x0043ADA9
GAME_CONTROL_TECH_MP = 4
#: ``mov byte [0x509F04], 1`` in the campaign arm.
GAME_CONTROL_TECH_CAMPAIGN_SITE = 0x0043AEBB
GAME_CONTROL_TECH_CAMPAIGN = 1
#: ``mov dword [ebx + 0xCC], 0x64`` -- the campaign's 100 equipment points.
GAME_CONTROL_POINTS_CAMPAIGN_SITE = 0x0043AE96
GAME_CONTROL_POINTS_CAMPAIGN = 0x64
#: ``mov byte [0x509E30], 1`` -- the campaign's player count, which is also the
#: loop bound, so the arm writes player 0 alone.
GAME_CONTROL_PLAYERS_CAMPAIGN_SITE = 0x0043AE76
GAME_CONTROL_PLAYERS_CAMPAIGN = 1
#: ``push str._C_100`` / ``push str._C_140`` -- ``mov edi, imm32``, u32 at +1.
GAME_CONTROL_FIRST_MISSION_SITES = {1: 0x0043AF57, 2: 0x0043AF2A}
CAMPAIGN_FIRST_MISSION = {1: "_C_100", 2: "_C_140"}

# --- the purchase catalogue's filter -- docs/27 5.2, closed by docs/98 3.1 ---
#: ``mov byte [0x00510A34], 0`` -- the **low** limit; imm8 at +6.
CATALOGUE_LOW_SITE = 0x0045BF44
CATALOGUE_LOW = 0
#: ``call getTechLevel`` immediately after it -- the **high** limit, stored
#: into ``0x00510A35``.  So the pair is one range and not two limits of
#: different kinds, which is what §5.2 marked UNVERIFIED.
CATALOGUE_HIGH_CALL_SITE = 0x0045BF4B
#: The two iterators the screens page the catalogue with: each walks its table
#: backwards, skips a record whose name is empty and yields the first whose
#: requirement byte is ``low <= b <= high``.  ``(site of the `sub edi, imm8`,
#: the record stride, the name's offset inside the record)``.
#: ``(site of the `sub edi, imm8`, site of the `lea eax, [edi - imm8]`,
#: the record stride, the name's offset inside the record)``.
CATALOGUE_BUILDERS = {
    "equipment": (0x0047A0B0, 0x0047A0BD, 42, 0x1F),
    "weapons":   (0x0047A1CD, 0x0047A1DA, 67, 0x37),
}
#: The buffer both compare a record's name against.  It is in ``.bss``, so the
#: file carries no bytes for it and it is zero at load -- the empty string.
CATALOGUE_EMPTY_STRING = 0x004FA524
#: The **third** test, and the one that keeps the aliens out of the shop.  It
#: is in the *forward* stepper only, three instructions past the range: ``cmp
#: edi, imm32`` / ``jl accept``, with ``edi`` the record's ``+0x38`` (weapons)
#: or ``+0x20`` (equipment).  The backward twin does without it because its
#: caller starts it at 18 and it only walks down.  ``(the site, the u32 at +2,
#: the base the iterator counts from, the stride, the resulting id bound)``.
#: Equipment's is the walk's own stop rather than an accept test, so it is the
#: ``cmp edi, imm32`` at the head of the loop.
CATALOGUE_BOUNDS = {
    "weapons": (0x0047A18B, 0x0051B2F8, 67, 20),
    "equipment": (0x0047A023, 0x00517BD1, 42, 21),
}
#: ``push 0x12`` in front of each backward stepper's call -- the id the wrap
#: to the top of the catalogue starts from.
CATALOGUE_WRAP_SITES = {"weapons": 0x0045AF71, "equipment": 0x0045B023}
CATALOGUE_WRAP_FROM = 0x12

# -- the Upgrade Menu's shared action button, docs/27 section 5.3 -------------
#: ``mov [addr], 0`` and ``mov [addr], 1`` over the gadget's own enable word.
GADGET_DISABLE = 0x0043AAF0
GADGET_ENABLE = 0x0043AB30
BUY_GADGET = 0
UNDO_GADGET = 18
#: The item window's refresh, one per catalogue half. Both re-gate gadget 0 on
#: the row that is up and disable gadget 18 when it passes.
ITEM_WINDOW_REFRESH = {"equipment": 0x00457B00, "weapons": 0x00457DA0}
#: Every call site of each, so a reading that thinks the swap is per visit
#: rather than per row fails here: the two arrows, *Buy Item*, *Undo* and the
#: window's build.
ITEM_WINDOW_REFRESH_CALLERS = {
    "equipment": (0x0045AA77, 0x0045AF49, 0x0045B04F, 0x0045B06A,
                  0x0045B0C1, 0x0045B1AF, 0x0045B4E5, 0x0045C08F),
    "weapons": (0x0045AB7F, 0x0045AF9C, 0x0045AFB7, 0x0045AFFB,
                0x0045B116, 0x0045B15A, 0x0045B4F6, 0x0045C096),
}
#: ``push imm8`` + ``call``: the refresh's own pair, per half.
ITEM_WINDOW_GATE_PASSES = {
    "equipment": (0x00457CFD, 0x00457D07),
    "weapons": (0x004580D9, 0x004580E3),
}
#: The three tests in front of that pair, as ``(site, absolute)`` for the
#: displacement each reads. The unit record is 91 bytes from ``UNIT_RECORD_BASE``
#: and both catalogue records are their own table's.
UNIT_RECORD_BASE = 0x0051F2A0
CATALOGUE_RECORD_BASE = {"weapons": 0x0051B2C0, "equipment": 0x00517BB0}
ITEM_WINDOW_GATE_READS = {
    ("equipment", "carried"): (0x00457C51, UNIT_RECORD_BASE, 0x21),
    ("equipment", "cost"): (0x00457C85, CATALOGUE_RECORD_BASE["equipment"],
                            0x20),
    ("equipment", "skills"): (0x00457CF2, UNIT_RECORD_BASE, 0x18),
    ("weapons", "carried"): (0x0045802B, UNIT_RECORD_BASE, 0x3F),
    ("weapons", "cost"): (0x00458061, CATALOGUE_RECORD_BASE["weapons"], 0x3E),
    ("weapons", "skills"): (0x004580CE, UNIT_RECORD_BASE, 0x18),
}
#: Gadget 18's own writers -- ``push 0x12`` + ``call``. *Buy Item* arms it as
#: the arm's first instruction, *Commend Unit* past the decrement, and the
#: window's build clears it. *Undo* (``0x0045B507``) writes neither gadget,
#: which is why it is absent here.
UNDO_GADGET_WRITERS = {
    0x0045A970: GADGET_ENABLE,
    0x0045AEC3: GADGET_ENABLE,
    0x0045C075: GADGET_DISABLE,
}
#: The *Item List*'s painter has no row bound: it wraps at an x of 500 with a
#: step of 250 from 80, and drops 35 down. ``add edi, imm32`` / ``cmp edi,
#: imm32`` / ``add esi, imm8``.
ITEM_LIST_COLUMN_STEP_SITE = 0x0045A13B
ITEM_LIST_COLUMN_WRAP_SITE = 0x0045A141
ITEM_LIST_ROW_STEP_SITE = 0x0045A149
ITEM_LIST_COLUMN_STEP = 250
ITEM_LIST_COLUMN_WRAP = 500
ITEM_LIST_ROW_STEP = 35
TECH_LEVEL_GET = 0x0043AFA0
TECH_LEVEL_SET = 0x0043AF90
ENLARGE_RANK_SCALE_SITE = 0x00478A6C     # `mov dl, 0x0C`, imm8 at +1
RANK_SCALE = 12
#: `mov [esi + imm32], r8` -- u32 at +2; the absolute is `POOL_BASE + offset`.
ENLARGE_STORES = {
    0x00478A5B: 0x4C,     # unit type   = player
    0x00478A75: 0x17,     # EP          = rank * 12
    0x00478A7E: 0x18,     # TP          = rank * 12
    0x00478A86: 0x19,     # FP          = 3 when rank < 3
    0x00478A8F: 0x19,     # FP          = rank otherwise
    0x00478AC6: 0x45,     # owning player
    0x00478ACE: 0x3F,     # weapon id   = 0
    0x00478AFF: 0x4D,     # pool candidate = 1
    0x00478B30: 0x5A,     # cached resale value
    0x00478B44: 0x55,     # speech set
}
ENLARGE_FP_FLOOR_SITE = 0x00478A7B       # `cmp cl, 3`, imm8 at +2
ENLARGE_FP_VALUE_SITE = 0x00478A86       # `mov byte [esi+…], 3`, imm8 at +6
FP_FLOOR = 3
ENLARGE_WEAPON_SITE = 0x00478ACE         # imm8 at +6
ENLARGE_CANDIDATE_SITE = 0x00478AFF      # imm8 at +6
POOL_CANDIDATE_FLAG = 1
ENLARGE_NAME_SITE = 0x00478A47           # `push "Soldier %d"`, u32 at +1
ENLARGE_NAME = "Soldier %d"
RANDOM_ROUTINE = 0x004638E0
SPEECH_BASE_SITE = 0x00478AEB            # `push 1`, imm8 at +1
SPEECH_SPAN_SITE = 0x00478AE3            # `push 6`, imm8 at +1
SPEECH_CALL_SITE = 0x00478B36
SPEECH_BASE, SPEECH_SPAN = 1, 6
#: `unitType = player` is deliberate: `Info.lcl` names types 0..3 this way.
PLAYER_UNIT_TYPES = {0: "Human Soldier (1)", 1: "Human Soldier (2)",
                     2: "Human Soldier (3)", 3: "Human Soldier (4)"}

# --- the weapon and equipment tables (docs/21) ------------------------------
WEAPON_TABLE = 0x0051B2C0
WEAPON_STRIDE = 0x43
WEAPON_COST_OFFSET = 0x3E
#: `mov r8, [reg + reg*2 + 0x51B2FE]` -- u32 at +3.
WEAPON_COST_SITES = (0x00478B13, 0x0045AAB4, 0x0045AADD)
EQUIP_TABLE = 0x00517BB0
EQUIP_STRIDE = 42
EQUIP_COST_OFFSET = 0x20
EQUIP_COST_SITE = 0x0045A9D6             # u32 at +3
RECRUIT_COST_SITE = 0x0045B821           # `mov al, [0x51B2FE]`, u32 at +1
RECRUIT_MARKUP_SITE = 0x0045B826         # `lea esi, [eax + 0x32]`, imm8 at +2
RECRUIT_MARKUP = 50
RESALE_MARKUP_SITE = 0x00478B21          # `add ecx, 0x32`, imm8 at +2
RECRUIT_SPEND_SITE = 0x0045B850
RECRUIT_CALL_SITE = 0x0045B863

# --- the money --------------------------------------------------------------
MONEY_ARRAY = 0x00509EEC
MONEY_GET = 0x0043AFF0
MONEY_ADD = 0x0043B010
MONEY_SPEND = 0x0043B060
MONEY_SET = 0x0043B0A0
MONEY_CAP = 10000
MONEY_CAP_SITE = 0x0043B03E              # `cmp ecx, 0x2710`, u32 at +2
MONEY_SPEND_GUARD_SITE = 0x0043B083      # `cmp eax, edx` / `jl`
COMMENDATIONS_ARRAY = 0x00509EFC

# --- the end of a mission ---------------------------------------------------
PAYOUT = 0x0043BA10
PAYOUT_TABLE = 0x0043BBB8
PAYOUT_RESULTS = 5
#: mission result (the scoreboard's `+0x20`, 1-based) -> base score.  Read
#: through the compiler's jump table, which is *not* in address order --
#: `docs/11` §5.5 had the five arms shifted by one.
PAYOUT_SCORES = (0, 100, 200, 300, -100)
#: NOT the solo flag: `docs/25` §3.1 decodes it as the gate in front of the
#: player-skip rule, true only in a `net session` / `pbm session` with one
#: human.  It is false in the campaign, so the base score always applies.
SKIP_RULE_GATE = 0x0043B1F0
DIFFICULTY_GETTER = 0x00460450
DIFFICULTY_GLOBAL = 0x005129F0
DIFFICULTY_MULTIPLIERS = (1, 2, 3)
END_STATE_GETTER = 0x0043B930
END_STATE_ARRAY = 0x00509F68              # GameControl + 0x250 = scoreboard+0x20
END_STATE_OUT = 5
END_STATE_GATE_SITE = 0x0043BB17          # `cmp eax, 5`, imm8 at +2
GAME_CONTROL_SLOT_GET = 0x0043B160
#: slot -> the `push <slot>` that precedes the read, imm8 at +1.
PAYOUT_SLOT_SITES = {10: 0x0043BB1C, 11: 0x0043BB3A}
SCOREBOARD_BASE = 0x00509F48              # GameControl + 0x230
SCOREBOARD_STRIDE = 0x28
#: `mov edi, 0x509F50` -- the scorer walks the scoreboard from record 0 + 8.
SCOREBOARD_CURSOR_SITE = 0x0043BA2C
SKILL_LEVEL_SETTER_SITES = (0x0044D824, 0x0044EDB9, 0x0044EE44,
                            0x0044FDC2, 0x0044FFE5)

# --- who writes the mission result ------------------------------------------
MISSION_RESULT_SET = 0x0043B960
MISSION_RESULT_RESET = 0x0043B990
#: `mov dword [eax + 0x509F68], 1` -- address at +2, value at +6.
RESULT_RESET_SITE = 0x0043B9D5
RESULT_RESET_VALUE = 1
#: `push 4; call aGetGameControl` -- LCL slot 4 is the computer's outcome.
DEFEAT_SLOT_SITE = 0x0047D8C3
DEFEAT_SLOT = 4
#: four `push 5; push <player>; call aSetMissionResult`
DEFEAT_SITES = (0x0047D8D1, 0x0047D8DD, 0x0047D8E9, 0x0047D8F5)
DEFEAT_RESULT = 5
#: the win-grade switch: LCL slot value -> mission result
RESULT_JUMP_TABLE = 0x0047D9EC
RESULT_GRADE_ARMS = {1: (0x0047D939, 2), 2: (0x0047D946, 3), 3: (0x0047D953, 4)}
RESULT_NOTHING_ARM = 0x0047D981
#: the short-circuit OR over LCL slots 0..4 that gates the defeat stamp:
#: `push <slot>; call aGetGameControl; test eax,eax; jne <stamp>`
OUTCOME_PROBE_SITES = (0x0047D88B, 0x0047D899, 0x0047D8A7,
                       0x0047D8B5, 0x0047D8C3)
#: the hand-over's other stamp: the rotation could not advance
HANDOVER = 0x0047D600
ADVANCE_PLAYER = 0x0043B320
ROTATION_FAIL_CALL = 0x0047D996
ROTATION_FAIL_SITES = (0x0047D9A7, 0x0047D9B3, 0x0047D9BF, 0x0047D9CB)

# --- the in-battle command dispatcher, aBattleSystem.cpp --------------------
COMMAND_DISPATCH = 0x0041DA20
COMMAND_TABLE = 0x0041DE04
COMMAND_COUNT = 10
#: command 1 -- give up.  With one human and the solo flag set (the campaign,
#: docs/25 §3) it takes the simple arm and stamps result 5 on every human.
GIVE_UP_ARM = 0x0041DB08
GIVE_UP_HUMANS_SITE = 0x0041DB0D         # `cmp eax, 1`, imm8 at +2
GIVE_UP_SOLO_ARM = 0x0041DB78
GIVE_UP_SITE = 0x0041DB83                # `push 5; push esi; call`
#: command 2 -- end the turn.  Its four arms are keyed on `gameMode() - 1`.
END_TURN_MODE_TABLE = 0x0041DE2C
END_TURN_MODE_ARMS = (0x0041DD61, 0x0041DD2E, 0x0041DD61, 0x0041DC2E)
#: the campaign arm: no living units and the turn counter past zero -> defeat
WIPEOUT_ARM = 0x0041DD61
LIVING_UNITS = 0x00477BF0
LIVING_UNITS_SITE = 0x0041DD6C
TURN_COUNTER_GET = 0x0043B280
TURN_COUNTER_SITE = 0x0041DD78
WIPEOUT_SITE = 0x0041DD81                # `push 5; push <player>; call`

# --- every setMissionResult site, classified --------------------------------
#: `0x0045FDB0` -- `aMultiPlayer.cpp` computes a player's result.  The twelve
#: sites that pair with it are the multiplayer scorer, out of scope (91 §9).
MULTIPLAYER_RESULT = 0x0045FDB0
MULTIPLAYER_PAIRS = ((0x0041DB45, 0x0041DB58), (0x00453C04, 0x00453C17),
                     (0x0047D44D, 0x0047D460), (0x0047D827, 0x0047D83A),
                     (0x0047E144, 0x0047E157), (0x00481203, 0x00481216))
#: the four in `aMissionControl.cpp` sit behind a flag only the DirectPlay
#: message dispatcher sets -- see `MP_FLAG_*` below.
NETWORK_ONLY_SITES = (0x00454C8D, 0x00454C99, 0x00454CA5, 0x00454CB1)
#: command 2's `pbm session` arm
PBM_ONLY_SITES = (0x0041DC79,)
#: the thirteen a campaign can reach
CAMPAIGN_RESULT_SITES = (0x0041DB86, 0x0041DD8E,
                         0x0047D8D5, 0x0047D8E1, 0x0047D8ED, 0x0047D8F9,
                         0x0047D93C, 0x0047D949, 0x0047D956,
                         0x0047D9A7, 0x0047D9B3, 0x0047D9BF, 0x0047D9CB)
RESULT_SITE_COUNT = 30
#: `0x00524008` -- zeroed by one initialiser, set by the DirectPlay message
#: dispatcher, read by the one `aMissionControl.cpp` site that gates the four.
MP_FLAG = 0x00524008
MP_FLAG_INIT_SITE = 0x00480C97           # `mov [imm32], eax` in the zeroing block
MP_FLAG_SET_SITE = 0x004812A2            # `mov [imm32], edi` in the dispatcher
MP_FLAG_READ_SITE = 0x00481A61           # the accessor `0x00481A60`
MP_FLAG_ACCESSOR_SITES = (0x00481A61, 0x00481A75)
MP_DISPATCHER = 0x004810C0
MP_DISPATCHER_RECV = 0x004810CB          # `call aDPlay receive`
DPLAY_LO, DPLAY_HI = 0x004348C4, 0x00436BB3
#: the two pairs whose arm is skipped when `humanCount() == 1`
MP_HUMAN_GUARDS = {0x0041DB45: 0x0041DB0D, 0x0047D827: 0x0047D80B}
#: the four preceded, within 48 bytes, by a call into `aDPlay.cpp`
MP_DPLAY_PAIRS = (0x00453C04, 0x0047D44D, 0x0047E144, 0x00481203)
MP_DPLAY_WINDOW = 48
#: both "nobody can take a turn" exits jump into the same four-stamp block
SEARCH_FIRST_PLAYER = 0x0043B410
SEARCH_FIRST_CALL = 0x0047D615
SEARCH_FAIL_SITE = 0x0047D61C
ROTATION_FAIL_BLOCK = 0x0047D9A3
MISSION_END_TRANSFER_SITE = 0x0045D46A
TRANSFER_ALL = 0x00478E50
TRANSFER_TO_POOL = 0x00478F20
TRANSFER_TO_MAP = 0x00478D10
COPY_POOL = 0x00478910
COPY_POOL_ENTRY_SITE = 0x0045A914         # aCopyUnitPool(0, 1)
COPY_POOL_EXIT_SITE = 0x0045E9D9          # aCopyUnitPool(1, 0)
COPY_POOL_LEN_SITE = 0x00478949           # `mov ecx, 0x2AA`, u32 at +1
COPY_POOL_DWORDS = 0x2AA
ADD_TO_POOL = 0x00478C10
REMOVE_FROM_POOL = 0x00478B70
POOL_SORT = 0x00478630
POOL_SORT_KEY_SITE = 0x00478663           # `mov cl, [eax-0x5B]`
POOL_MAX_TP = 0x004786E0
POOL_MAX_TP_SITE = 0x00478705             # `mov byte [eax], 0x78`, imm8 at +2
POOL_MAX_TP_VALUE = 0x78
SURVIVE_GATE_SITE = 0x00478FC8            # `mov cl, [eax+0x4D]`, imm8 at +2
OWNER_GATE_SITE = 0x00478E99              # `mov cl, [eax+0x45]`, imm8 at +2
OWNER_OFFSET = 0x45
DEBRIEF_GADGETS = 0x0045EA50
DEBRIEF_GADGET_COUNT = 4
NEXT_MAP_ARM = 0x0045E986
NEXT_MAP_HEADER_CALL = 0x0045E990
POOL_WRITEBACK_ARM = 0x0045E9CB
MAP_NAME_BUFFER_GETTER = 0x0043B150

# --- the text banks ---------------------------------------------------------
INIT_TEXT_SYSTEM = 0x00470B50
#: (call site, bank, file, zero site) -- every `aInitTextSystem` call in the
#: image.  Three of them pass bank 0 in a register the prologue has just
#: cleared; the zero site is that `xor r32, r32`.
TEXT_BANKS = (
    (0x00419DAD, 0, "txtmod_e.lcl", 0x00419D9F),
    (0x00447BE6, 2, "txtmod_f.lcl", None),
    (0x00449CBF, 3, "txtmod_h.lcl", None),
    (0x00449CF8, 4, "mission.lcl", None),
    (0x0044B22C, 0, "txtmod_a.lcl", 0x0044B224),
    (0x00453F8E, 0, "txtmod_b.lcl", 0x00453F86),
    (0x00454082, 1, "campaign.lcl", None),
    (0x0045D3FE, 0, "txtmod_d.lcl", None),
    (0x00462460, 2, "txtmod_f.lcl", None),
    (0x0047BCFF, 0, "txtmod_g.lcl", None),
)
GUI_TEXT_DIR = os.path.join("DATA", "TXT", "English", "GUI")
CAMPAIGN_LCL = "Campaign.lcl"

# --- the corpus -------------------------------------------------------------
EXPECTED_MISSIONS = 155
EXPECTED_CAMPAIGN_MISSIONS = 75
EXPECTED_UPGRADE_MAPS = 15
MAP_TYPE_CAMPAIGN = 1
MAP_TYPE_SPECIAL = 4
EXPECTED_XXX_LOCATIONS = 49
EXPECTED_YYY_LOCATIONS = 47
EXPECTED_NEXT_MAP_CALLS = 74
EXPECTED_MISSION_SCRIPTS = 153
#: `_C_YYY` is entered from `_C_133`; both campaign maps are map type 4.
CAMPAIGN_MAPS = {1: "_C_XXX", 2: "_C_YYY"}


# ---------------------------------------------------------------------------
# Reading the binary
# ---------------------------------------------------------------------------

class Binary:
    """``Incubation.exe``, read by virtual address."""

    def __init__(self, root: str) -> None:
        path = os.path.join(root, GAME_EXE)
        if not os.path.isfile(path):
            raise SystemExit(f"{path}: not found -- is {root!r} the game root?")
        self.root = root
        self.pe = PEFile(path)
        base, size, _raw, _rawsize = self.pe.section(".text")
        self.text_lo, self.text_hi = base, base + size

    # -- primitives ---------------------------------------------------------

    def u8(self, va: int) -> int:
        return self.pe.u8(va)

    def u32(self, va: int) -> int:
        return self.pe.u32(va)

    def i32(self, va: int) -> int:
        return self.pe.i32(va)

    def i8(self, va: int) -> int:
        value = self.pe.u8(va)
        return value - 0x100 if value > 0x7F else value

    def string(self, va: int, limit: int = 120) -> str | None:
        try:
            return self.pe.cstring(va, limit)
        except PEError:
            return None

    def call_target(self, va: int) -> int | None:
        try:
            if self.pe.u8(va) != 0xE8:
                return None
            return va + 5 + self.pe.i32(va + 1)
        except PEError:
            return None

    def calls_to(self, target: int) -> list[int]:
        """Every ``call rel32`` in ``.text`` that reaches *target*."""
        out: list[int] = []
        for va in range(self.text_lo, self.text_hi - 5):
            if self.pe.u8(va) != 0xE8:
                continue
            if va + 5 + self.pe.i32(va + 1) == target:
                out.append(va)
        return out

    def absolute_refs(self, address: int) -> list[int]:
        """Every 4-byte little-endian occurrence of *address* in the image."""
        pattern = struct.pack("<I", address)
        out: list[int] = []
        offset = 0
        while True:
            offset = self.pe.data.find(pattern, offset)
            if offset < 0:
                break
            va = self.pe.off_to_va(offset)
            if va is not None:
                out.append(va)
            offset += 1
        return out

    # -- the tables ---------------------------------------------------------

    def location_map(self) -> dict[int, list[tuple[int, int]] | None]:
        """``aCreateLocationMap``: mission id -> [(location, flag), ...].

        ``None`` marks a mission id that falls through to the default arm.
        """
        out: dict[int, list[tuple[int, int]] | None] = {}
        for i in range(LOCATION_MAP_ENTRIES):
            arm = self.u32(LOCATION_MAP_TABLE + 4 * i)
            if arm == LOCATION_MAP_DEFAULT:
                out[i + 1] = None
                continue
            try:
                out[i + 1] = self._arm(arm)
            except (ValueError, PEError):
                out[i + 1] = []             # malformed -- locmap.pairs catches it
        return out

    def location_map_arms(self) -> dict[int, int]:
        return {i + 1: self.u32(LOCATION_MAP_TABLE + 4 * i)
                for i in range(LOCATION_MAP_ENTRIES)}

    def _arm(self, va: int) -> list[tuple[int, int]]:
        pairs: list[tuple[int, int]] = []
        cur, guard = va, 0
        while guard < 64:
            guard += 1
            op = self.u8(cur)
            if op == 0xEB:
                cur = cur + 2 + self.i8(cur + 1)
                continue
            if op == 0xB8 and self.u32(cur + 1) == 1 and self.u8(cur + 5) == 0xC3:
                return pairs
            flag, cur = self._push_imm(cur)
            if flag is None:
                raise ValueError(f"unexpected byte at {cur:#010x}")
            location, cur = self._push_imm(cur)
            if location is None:
                raise ValueError(f"unexpected byte at {cur:#010x}")
            if self.u8(cur) == 0xEB:
                cur = cur + 2 + self.i8(cur + 1)
            if self.call_target(cur) != LOCATION_MAP_SET:
                raise ValueError(f"not the setter at {cur:#010x}")
            cur += 5
            if self.u8(cur) == 0x83:        # add esp, 8
                cur += 3
            pairs.append((location, flag))
        raise ValueError(f"runaway arm at {va:#010x}")

    def _push_imm(self, va: int) -> tuple[int | None, int]:
        op = self.u8(va)
        if op == 0x6A:
            return self.u8(va + 1), va + 2
        if op == 0x68:
            return self.u32(va + 1), va + 5
        return None, va

    def map_names(self) -> dict[int, str]:
        """``aMapName``: location -> mission basename."""
        out: dict[int, str] = {}
        for i in range(MAP_NAME_ENTRIES):
            arm = self.u32(MAP_NAME_TABLE + 4 * i)
            if arm == MAP_NAME_DEFAULT:
                continue
            if self.u8(arm) != 0xBF:        # mov edi, imm32
                out[i + MAP_NAME_BIAS] = None
                continue
            out[i + MAP_NAME_BIAS] = self.string(self.u32(arm + 1), 20)
        return out

    def location_arms(self) -> dict[int, int]:
        """``aLocationHandling``: location -> the arm it dispatches to."""
        out: dict[int, int] = {}
        for i in range(HANDLING_INDEX_LEN):
            slot = self.u8(HANDLING_INDEX_TABLE + i)
            out[i + 1] = (self.u32(HANDLING_JUMP_TABLE + 4 * slot)
                          if slot < HANDLING_JUMP_LEN else 0)
        return out

    def dialogue_numbers(self) -> dict[int, int]:
        """location -> the number its arm passes to the dialogue screen."""
        out: dict[int, int] = {}
        for location, arm in self.location_arms().items():
            if not self.text_lo <= arm < self.text_hi:
                continue
            value, cur = self._push_imm(arm)
            if value is None or self.call_target(cur) != DIALOGUE_SCREEN:
                continue
            out[location] = value
        return out

    def upgrade_arms(self) -> dict[int, int]:
        """location -> the id its arm passes to the upgrade animation."""
        out: dict[int, int] = {}
        for location, arm in self.location_arms().items():
            if not self.text_lo <= arm < self.text_hi:
                continue
            value, cur = self._push_imm(arm)
            if value is None or self.call_target(cur) != UPGRADE_ANIMATION:
                continue
            out[location] = value
        return out

    def recruit_categories(self) -> dict[int, tuple[int, ...]]:
        """The five *Recruit* buttons' unit-type lists (``docs/27`` §3.2)."""
        slots = {slot: k for k, slot in enumerate(RECRUIT_SLOTS)}
        arms = [self.u32(RECRUIT_JUMP_TABLE + 4 * i) for i in range(5)]
        edges = sorted(arms + [RECRUIT_ARM_END])
        out: dict[int, tuple[int, ...]] = {}
        for index, start in enumerate(arms):
            end = min(e for e in edges if e > start)
            found: dict[int, int] = {}
            va = start
            while va < end:
                if self.u8(va) == 0xC7 and self.u8(va + 1) == 0x05:
                    address = self.u32(va + 2)
                    if address in slots:
                        found.setdefault(slots[address], self.u32(va + 6))
                elif self.u8(va) == 0x89 and self.u8(va + 1) == 0x1D:
                    # `mov [slot], ebx`, and `ebx` is zeroed at the head.
                    address = self.u32(va + 2)
                    if address in slots:
                        found.setdefault(slots[address], 0)
                va += 1
            out[index] = tuple(v for _, v in sorted(found.items()))
        return out

    def _arm_body(self, arm: int) -> int:
        """Where an upgrade arm's body starts, which is **not** always the arm.

        Every arm opens with the `CHECK` macro --
        ``push id; call aPlayLocationAnimation_Upgrade; add esp, 4;
        test eax, eax; jne body`` -- and the report block sits *inline* on the
        failure path, so for most arms the body is simply what follows it.
        For two pairs it is not: the compiler **tail-merged** the identical
        bodies of locations 1 and 210 (``0x0045CB26``) and of 7 and 216
        (``0x0045CDAB``), and those arms reach them with a ``0F 85`` far jump.
        Scanning forward from the arm instead walks straight into the *next*
        location's body, which is how locations 1 and 7 once carried the bands
        of 2 and 8.
        """
        va = arm
        while va < min(arm + 0x40, self.text_hi - 8):
            if self.u8(va) == 0x85 and self.u8(va + 1) == 0xC0:
                if self.u8(va + 2) == 0x75:
                    return va + 4 + self.i8(va + 3)
                if self.u8(va + 2) == 0x0F and self.u8(va + 3) == 0x85:
                    return va + 8 + self.i32(va + 4)
                return arm
            va += 1
        return arm

    def upgrade_tech_bands(self) -> dict[int, tuple[int, int]]:
        """location -> the ``(low, high)`` tech band its arm writes.

        ``0x0045BF2A``'s campaign arm copies this pair into the catalogue
        limits ``0x00510A34``/``0x00510A35``, so **each base sells its own
        band** rather than everything up to the campaign's tech level
        (``docs/27`` §5.2).  Three encodings appear:

        * ``mov byte [addr], imm8`` -- the literal;
        * ``mov byte [addr], bl`` -- ``bl`` is zero for the whole dispatcher,
          which :data:`UPGRADE_BAND_ZERO_SITE` pins;
        * ``mov byte [addr], al`` after a ``mov al, imm8`` in the same arm.

        The sweep starts at :meth:`_arm_body` and stops at the next body above
        it, so an arm that writes no band of its own yields **no entry**
        rather than its neighbour's pair.
        """
        bodies = {location: self._arm_body(arm)
                  for location, arm in self.location_arms().items()
                  if self.text_lo <= arm < self.text_hi}
        edges = sorted(set(bodies.values()))
        out: dict[int, tuple[int, int]] = {}
        for location, body in bodies.items():
            after = [e for e in edges if e > body]
            stop = min(body + UPGRADE_BAND_WINDOW,
                       after[0] if after else self.text_hi,
                       self.text_hi - 8)
            found: dict[int, int] = {}
            al: int | None = None
            va = body
            while va < stop:
                op = self.u8(va)
                if op == 0xB0:                      # mov al, imm8
                    al = self.u8(va + 1)
                elif op == 0xC6 and self.u8(va + 1) == 0x05:
                    address = self.u32(va + 2)
                    if address in UPGRADE_BAND_SITES:
                        found.setdefault(address, self.u8(va + 6))
                elif op == 0x88 and self.u8(va + 1) == 0x1D:
                    address = self.u32(va + 2)
                    if address in UPGRADE_BAND_SITES:
                        found.setdefault(address, 0)
                elif op == 0xA2:
                    address = self.u32(va + 1)
                    if address in UPGRADE_BAND_SITES and al is not None:
                        found.setdefault(address, al)
                va += 1
            low, high = UPGRADE_BAND_SITES
            if low in found and high in found:
                out[location] = (found[low], found[high])
        return out

    def squad_fields(self) -> dict[tuple[int, int], int]:
        """The starting squad's field writes, keyed ``(record, offset)``."""
        al = self.u8(SQUAD_AL_SITE + 1) if self.u8(SQUAD_AL_SITE) == 0xB0 else None
        out: dict[tuple[int, int], int] = {}
        va, hi = SQUAD_WRITE_BLOCK
        while va < hi:
            op = self.u8(va)
            if op == 0xC6 and self.u8(va + 1) == 0x05:
                address, value, size = self.u32(va + 2), self.u8(va + 6), 7
            elif op == 0xA2:
                address, value, size = self.u32(va + 1), al, 5
            else:
                va += 1
                continue
            for index, base in enumerate(SQUAD_RECORDS):
                offset = address - base
                if 0 <= offset < POOL_STRIDE:
                    out[(index, offset)] = value
                    break
            va += size
        return out

    def payout_scores(self) -> list[int]:
        """The five ``mov ebx, imm32`` arms of the mission-result switch."""
        out: list[int] = []
        for i in range(PAYOUT_RESULTS):
            arm = self.u32(PAYOUT_TABLE + 4 * i)
            if self.u8(arm) == 0xBB:            # mov ebx, imm32
                out.append(self.i32(arm + 1))
            elif self.u8(arm) == 0x33 and self.u8(arm + 1) == 0xDB:
                out.append(0)                   # xor ebx, ebx
            else:
                out.append(None)
        return out


# ---------------------------------------------------------------------------
# Reading the corpus
# ---------------------------------------------------------------------------

class Corpus:
    """The shipped data every corpus check reads."""

    def __init__(self, root: str) -> None:
        self.root = root
        self.missions = sorted(Path(root).rglob("*.lev"))
        self.scripts = sorted(Path(root).rglob("*.lcl"))

        self.headers: dict[str, dict] = {}
        self.campaign_cells: dict[str, set[int]] = {}
        #: `upgrade_N` -> the units `0x00417510`'s loop would reach, in slot
        #: order: `(type, weapon, facing)` per living player-0 record.
        self.upgrade_marines: dict[int, list[tuple[int, int, int]]] = {}
        for path in self.missions:
            self._read(path)

        self.mission_scripts = [p for p in self.scripts
                                if p.parent.name.lower() == "missions"]
        self.next_map_calls: list[tuple[str, str]] = []
        for path in self.mission_scripts:
            self._read_script(path)

        self.text: dict[str, dict[int, str]] = {}
        for name in (CAMPAIGN_LCL, SQUAD_TEXT_FILE):
            entries = self._read_text(os.path.join(root, GUI_TEXT_DIR, name))
            if entries is not None:
                self.text[name] = entries

        self.weapons: dict[int, list] = {}
        self.units: dict[int, list] = {}
        self.equipment: dict[int, list] = {}
        self._read_info()

    # -- readers ------------------------------------------------------------

    def _read(self, path: Path) -> None:
        battle = load_lev(path)
        stem = path.stem
        self.headers[stem] = {
            "next": battle.next_map,
            "name": battle.map_name,
            "type": battle.map_type,
            "mission_id": battle.mission_id,
            "skill": battle.skill_level,
            "tech": battle.tech_level,
            "equip": tuple(battle.equip_points),
        }
        if stem.upper() in CAMPAIGN_MAPS.values():
            self.campaign_cells[stem.upper()] = {
                c.action_point for c in battle.cells if c.action_point}
        if stem.startswith("upgrade_"):
            self.upgrade_marines[int(stem.split("_")[1])] = [
                (u.type_id, u.weapon, u.facing) for u in battle.units
                if u.hit_points != 0 and u.player == UPGRADE_UNIT_PLAYER]

    def _read_script(self, path: Path) -> None:
        with open(path, "rb") as handle:
            program = lcl.parse_bytes(handle.read(), str(path))
        for routine in program.routines:
            for stmt in _walk(routine.body):
                if stmt.name != "EnterNameOfNextMap":
                    continue
                for arg in stmt.args:
                    if arg.kind == "string" and arg.value:
                        self.next_map_calls.append((path.stem, arg.value))

    def _read_text(self, path: str) -> dict[int, str] | None:
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as handle:
            program = lcl.parse_bytes(handle.read(), path)
        out: dict[int, str] = {}
        for routine in program.routines:
            for node in routine.body:
                if isinstance(node, lcl.TextEntry):
                    out[node.index] = node.text
        return out

    def _read_info(self) -> None:
        path = os.path.join(self.root, "DATA", "Info.lcl")
        if not os.path.isfile(path):
            return
        with open(path, "rb") as handle:
            program = lcl.parse_bytes(handle.read(), path)
        table = {"SetWeaponInfo": self.weapons,
                 "SetUnitInfo": self.units,
                 "SetEquipInfo": self.equipment}
        for routine in program.routines:
            for stmt in _walk(routine.body):
                target = table.get(stmt.name)
                if target is None or not stmt.args:
                    continue
                first = stmt.args[0]
                if first.kind == "number":
                    target[first.value] = stmt.args

    # -- derived ------------------------------------------------------------

    def campaign_missions(self) -> dict[int, str]:
        """mission id -> basename, for every shipped campaign-type mission."""
        return {h["mission_id"]: stem
                for stem, h in sorted(self.headers.items())
                if h["type"] == MAP_TYPE_CAMPAIGN}

    def stems(self) -> set[str]:
        return {s.upper() for s in self.headers}


def _hexlist(values) -> str:
    return "[" + ", ".join(f"0x{v:08X}" for v in values) + "]"


def numbers(args) -> list:
    return [a.value for a in args if a.kind == "number"]


def strings(args) -> list:
    return [a.value for a in args if a.kind == "string"]


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
        self.names: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        self.names.append(name)
        if ok:
            self.passed += 1
            LOG.info("  ok    %-32s %s", name, detail)
        else:
            self.failed += 1
            LOG.error("  FAIL  %-32s %s", name, detail)

    def equal(self, name: str, got, want, fmt=str) -> None:
        self.check(name, got == want,
                   fmt(got) if got == want else f"got {fmt(got)} want {fmt(want)}")



# --- the campaign screen's own camera and window (docs/27 section 2.6) ------
#: `aMissionControl.cpp`'s campaign-screen entry, which writes the camera.
SCREEN_ENTRY = 0x00453F80
#: `xor ebx, ebx` at the top of it: the function's zero register, which is
#: what the target's z is written from.
SCREEN_ENTRY_ZERO = 0x00453F86
#: `aSetCameraPosition(px, py, pz, tx, ty, tz)`, `a3DEngine.cpp`.
SET_CAMERA_POSITION = 0x00403560
#: The 3D viewport setter and the six camera globals it is fed from.
SET_VIEWPORT = 0x0040B670
CAMERA_EYE_GLOBAL = 0x00510BB8
CAMERA_TARGET_GLOBAL = 0x00510BC4
#: The three `mov dword [global], imm32` that write the eye, in order.
CAMERA_EYE_WRITES = (0x004541B2, 0x004541BC, 0x004541C6)
#: `mov eax, 0xDDE0` and the two `mov [global], eax` that spend it, then the
#: `mov [global], ebx` that writes the target's z.
CAMERA_TARGET_LOAD = 0x0045414B
CAMERA_TARGET_STORES = (0x004541A2, 0x004541A7)
CAMERA_TARGET_Z_STORE = 0x004541AC
#: Where the map screen loads all six and hands them to `aSetCameraPosition`.
CAMERA_HANDOVER_BLOCK = 0x00457673
CAMERA_HANDOVER = 0x0045769E
#: What they come to.
CAMPAIGN_EYE = (-19088, 98112, 9088)
CAMPAIGN_TARGET = (56800, 56800, 0)
#: The initial eye is immediately replaced through these three pointers by
#: `0x0045D130(current location, &x, &y, &z)`. The 71 selector bytes cover
#: locations 59..129; every value outside that span takes the default arm.
CAMERA_PRESET_CALL = 0x004541D9
CAMERA_PRESET = 0x0045D130
CAMERA_PRESET_POINTER_PUSHES = (0x0045413F, 0x00454153, 0x0045415F)
CAMERA_PRESET_POINTERS = (CAMERA_EYE_GLOBAL + 8, CAMERA_EYE_GLOBAL + 4,
                          CAMERA_EYE_GLOBAL)
CAMERA_PRESET_BIAS_SITE = 0x0045D13E
CAMERA_PRESET_FIRST = 59
CAMERA_PRESET_LIMIT_SITE = 0x0045D141
CAMERA_PRESET_LAST = 129
CAMERA_PRESET_ARM_TABLE = 0x0045D354
CAMERA_PRESET_SELECTOR_TABLE = 0x0045D38C
CAMERA_PRESET_ARMS = (
    0x0045D159, 0x0045D17D, 0x0045D1A1, 0x0045D1C5,
    0x0045D1E9, 0x0045D20D, 0x0045D231, 0x0045D255,
    0x0045D279, 0x0045D29D, 0x0045D2C1, 0x0045D2E5,
    0x0045D309,
)
CAMERA_PRESET_DEFAULT = 0x0045D32D
CAMERA_PRESET_EYES = (
    (-19072, 98096, 19088),
    (79968, 140032, 19088),
    (15248, -18944, 18848),
    (101984, -16800, 19184),
    (-15072, 104672, 19200),
    (14320, 132016, 18592),
    (56912, 143168, 3984),
    (73664, -27904, 19200),
    (-21072, -21840, 19136),
    (143104, 53360, 19200),
    (121856, 0, 19200),
    (74176, -27792, 19200),
    (-3776, -4736, 14336),
)
CAMERA_PRESET_DEFAULT_EYE = (-19072, 98096, 9088)
CAMERA_PRESET_SELECTORS = (
    [0] * 7 + [1] * 4 + [2] + [3] * 6 + [4] * 4 + [5] * 3 + [6]
    + [13] * 5 + [7] * 7 + [8] * 4 + [9] * 4 + [10] * 11
    + [11] * 4 + [12] * 10
)
#: `0x0040B670(x, y, w, h)` on the way into the campaign screens.
VIEWPORT_SITE = 0x00454102
CAMPAIGN_VIEWPORT = (65, 57, 518, 306)
#: `0x004558F0`'s clamp on the eye's height, `cmp eax, 0x4B00` and
#: `cmp eax, 0xFFFFDA80`.
CAMERA_HEIGHT_CLAMP = (0x00455991, 0x004559A7)
CAMPAIGN_HEIGHT_BAND = (-9600, 19200)

#: docs/27 §2.6 -- **what turns the map, and by how much.**  This was the
#: document's fourth open question, and the answer is a cursor drag:
#: `0x00455566` runs only while the screen id `0x00510A38` is 6 and the button
#: byte `0x00511B09` is 1, and it writes the two deltas `0x004558F0` reads.
#: The cursor is warped back to the drag's anchor every frame
#: (`0x0045EEF0`'s `SetCursorPos`), so what it reads is per-frame travel.
ROTATE_INPUT = 0x00455560
ROTATE_SCREEN_SITE = 0x00455566
ROTATE_SCREEN_CMP = 0x0045556E
ROTATE_SCREEN_ID = 6
SCREEN_ID_GLOBAL = 0x00510A38
ROTATE_BUTTON_GETTER = 0x0045F000
ROTATE_BUTTON_BYTE = 0x00511B09
#: docs/27 §2.6.1 -- **which button that byte is.**  The message pump
#: `0x0040B6F0` dispatches `WM_LBUTTONUP` .. `WM_RBUTTONDBLCLK`
#: (`0x0202`..`0x0206`) through the five-entry table below, and the two
#: setters it calls are one instruction each: `0x0045EFC0` writes
#: `0x00511B08` and `0x0045EFD0` writes `0x00511B09`.  The right button's
#: three arms are the ones that reach the second, so the byte the map's drag
#: gates on is the **right** button's.  The prologue's `xor ebx, ebx` and
#: `mov ebp, 1` are what make the pushed register the pressed state.
MESSAGE_PUMP = 0x0040B6F0
MESSAGE_TABLE = 0x0040BD58
#: The dispatch itself: `add eax, -0x202` biases the message onto the table,
#: `cmp eax, 4` bounds it at five entries and the `jmp dword [eax*4 + table]`
#: carries the table's address -- so the first message and the table are read
#: out of the instructions rather than asserted.
MESSAGE_BIAS_SITE = 0x0040B778
MESSAGE_BOUND_SITE = 0x0040B77D
MESSAGE_JUMP_SITE = 0x0040B782
MESSAGE_TABLE_FIRST = 0x0202
#: `cmp eax, 0x201 / je` -- `WM_LBUTTONDOWN`, which shares the double-click's
#: arm and so is the left button's own press.
MESSAGE_LBUTTONDOWN_CMP = 0x0040B75B
MESSAGE_LBUTTONDOWN_JE = 0x0040B762
MESSAGE_LBUTTONDOWN_ARM = 0x0040B7A2
#: `(message, arm, setter, pushed register)`, the register being `ebp` for a
#: press and `ebx` for a release.
MESSAGE_BUTTON_ARMS = (
    (0x0202, 0x0040B7BB, 0x0045EFC0, "ebx"),   # WM_LBUTTONUP
    (0x0203, 0x0040B7A2, 0x0045EFC0, "ebp"),   # WM_LBUTTONDBLCLK
    (0x0204, 0x0040B789, 0x0045EFD0, "ebp"),   # WM_RBUTTONDOWN
    (0x0205, 0x0040B7B3, 0x0045EFD0, "ebx"),   # WM_RBUTTONUP
    (0x0206, 0x0040B789, 0x0045EFD0, "ebp"),   # WM_RBUTTONDBLCLK
)
LEFT_BUTTON_SETTER = 0x0045EFC0
LEFT_BUTTON_BYTE = 0x00511B08
#: `push ebp` and `push ebx`, and the prologue that gives them their values.
PUSH_OPCODES = {"ebp": 0x55, "ebx": 0x53}
MESSAGE_PUMP_ZERO = 0x0040B6FA
MESSAGE_PUMP_ONE = 0x0040B70E
#: `call 0x0045EF30 / shl eax, 1` -- the horizontal travel doubled, in Eng3d's
#: 4096ths, into `0x00510C44`.
ROTATE_DX_CALL = 0x00455587
ROTATE_DX_SHIFT_SITE = 0x0045558C
ROTATE_TURN_PER_PIXEL = 2
ROTATE_DELTA_STORE = 0x0045558E
ROTATE_DELTA_GLOBAL = 0x00510C44
#: `neg / shl 2 / sub / lea [ecx+ecx*4] / shl 1` -- the vertical travel by
#: **-50**, in world units, into `0x00510C48`.  Written out as five
#: instructions because the compiler had no multiply worth using.
ROTATE_DY_CALL = 0x00455593
ROTATE_RISE_SITES = (0x0045559A, 0x0045559C, 0x0045559F, 0x004555A1,
                     0x004555A4)
ROTATE_RISE_PER_PIXEL = -50
ROTATE_HEIGHT_STORE = 0x004555A6
ROTATE_HEIGHT_GLOBAL = 0x00510C48
#: The pointer accessors themselves: current minus anchor, and the warp back.
ROTATE_DX_GETTER = 0x0045EF30
ROTATE_DY_GETTER = 0x0045EF40
ROTATE_WARP = 0x0045EEF0
ROTATE_CURSOR = (0x00511AF8, 0x00511AFC)
ROTATE_ANCHOR = (0x00511B00, 0x00511B04)
#: The two call sites of `0x004558F0` inside the map's own loop: the drag's,
#: and the frame callback's own **zero**, which is what decays the step.
ROTATE_APPLY = 0x004558F0
ROTATE_APPLY_SITES = (0x00454E6C, 0x00454EEF)
ROTATE_IDLE_PUSHES = (0x00454EE4, 0x00454EE6)
#: `0x004558F0`'s inertia: `cmp ebx, eax / jle` takes the request when its
#: magnitude is the larger and **halves** the step otherwise -- `sar eax, 1`
#: after a `cdq / sub`, so it truncates toward zero.
ROTATE_INERTIA_CMP = 0x0045593A
ROTATE_INERTIA_JLE = 0x0045593C
ROTATE_HALVE_SITE = 0x00455947
#: The accumulator and the step, and the three sites that clear the first.
ROTATE_ANGLE_GLOBAL = 0x00510C50
ROTATE_STEP_GLOBAL = 0x00510D28
ROTATE_ANGLE_READ = 0x00455949
ROTATE_ANGLE_STORE = 0x0045595A
ROTATE_STEP_STORE = 0x0045594F
ROTATE_ANGLE_CLEARS = (0x004541F7, 0x004554C9, 0x0045D134)
#: `mov word [esp+0xc], cx` -- the accumulator's **low word**, handed to
#: `0x004039A0` as the **third** angle, which is what says the units are
#: Eng3d's 4096ths and the turn is about z.
ROTATE_ANGLE_WORD_SITE = 0x00455960
ROTATE_MATRIX_CALL = 0x0045597E
ROTATE_MATRIX = 0x004039A0
#: `SetCameraPosition` `0x00403560` writes **none** of the globals back, and
#: the eye's own x is written only by the screen's initialiser -- so the turn
#: rotates the location-selected base eye by the accumulated angle rather than
#: nudging the eye it has. Reading it the other way makes the map run away.
CAMERA_EYE_X_GLOBAL = 0x00510BB8
CAMERA_EYE_Z_GLOBAL = 0x00510BC0
ROTATE_CAMERA_CALL = 0x004559DC

#: docs/27 §2.6 -- **Eng3d's own perspective.**  `0x00403460` is the wrapper
#: `aInit3dScreen`, and the focal length is not a field of view at all: it is
#: the window's width times the double at `0x004B1010`, truncated.  The DLL
#: stores it at `Eng3d.dll+0x14FE8` beside `1/f`, whose own initialiser is
#: 256.  A non-zero zoom divisor `0x004FA500` replaces it with `width /
#: divisor`; five sites write that, with 0 and with 4, and none is on the
#: mission or map path.
PROJECTION_INIT = 0x00403460
PROJECTION_CONSTANT_SITE = 0x0040348E
PROJECTION_CONSTANT = 10.0 / 13.0
PROJECTION_FTOL_SITE = 0x00403494
PROJECTION_ZOOM_GLOBAL = 0x004FA500
PROJECTION_ZOOM_SETTER = 0x004034E0
PROJECTION_WIDTH_SITE = 0x0040346C
PROJECTION_ENG3D_ENTRY = "_E3D_init_3d_screen"
PROJECTION_ENG3D_DEFAULT = 256
#: `_ftol` -- the same import thunk `blob_tables.py` names.
FTOL = 0x004AE7B6
#: Where `Eng3d.dll` keeps the focal length, as an RVA off its own image base
#: (0x00400000, which it never loads at -- the loader relocates it, so this is
#: read out of the file rather than out of a running process).
ENG3D_DLL = "Eng3d.dll"
ENG3D_FOCAL_RVA = 0x00014FE8
#: The map's own `aInit3dScreen` call, and the viewport it names -- the same
#: rectangle `0x00454102` sets, read a second way.
PROJECTION_MAP_SITE = 0x00455A16
PROJECTION_MAP_PUSHES = (0x004559FA, 0x004559F8, 0x004559F0, 0x004559EB)



# --- what a purchase costs besides points (docs/27 section 5.3) ------------
#: `aBuyWeapon` and `aBuyEquipment`, the two the Upgrade Menu's buttons reach.
BUY_WEAPON = 0x00475680
BUY_EQUIPMENT = 0x004755D0
#: The two shortfall routines they end with, `f(id, unit, apply)`.
WEAPON_SHORTFALL = 0x0047A600
EQUIPMENT_SHORTFALL = 0x0047A6E0
#: The `call` site in each buyer, and the `add esp, 0xc` that follows it.
WEAPON_SHORTFALL_CALL = 0x00475699
EQUIPMENT_SHORTFALL_CALL = 0x0047564C
#: The epilogue both share: `lea eax, [eax + eax*2]` / `shl eax, 2`, which is
#: `short * 12`, subtracted from the unit's `+0x18` as a **byte**.
WEAPON_EPILOGUE = (0x004756A5, 0x004756AB, 0x0047569E, 0x004756B1)
EQUIPMENT_EPILOGUE = (0x00475658, 0x0047565E, 0x00475651, 0x00475664)
#: The unit record's training points, and the flag strip the equipment ids
#: index: `unit + 0x21 + id`.
UNIT_TRAINING_POINTS = 0x18
UNIT_EQUIPMENT_FLAGS = 0x21
#: The catalogue limits each buyer refuses past.
WEAPON_ID_MAX = 0x32
EQUIPMENT_ID_MAX = 0x15
#: `cmp eax, 7` then `mov byte [esi + 0x22], 1` -- the Jet Pack grants item 1.
JET_PACK_TEST = 0x004755FE
JET_PACK_GRANT = 0x00475603
#: The four exclusive ranges, as (low test, high test or None, clearing write,
#: width in bytes). A `mov word` clears two ids, a `mov dword` four.
EXCLUSIVE_RANGES = (
    (0x00475618, None, 0x0047561D, 2),
    (0x00475623, 0x00475628, 0x0047562D, 2),
    (0x00475607, 0x0047560C, 0x00475611, 4),
    (0x00475633, 0x00475638, 0x0047563D, 2),
)
#: What those four come to, which is what `core/campaign/upgrade.gd` carries.
EXCLUSIVE_GROUPS = ([0, 1], [3, 4], [10, 11, 12, 13], [15, 16])
#: **What the Upgrade Menu's *i* shows.** `0x00432B70` (equipment) and
#: `0x00432BD0` (a weapon) read a letter out of the record, refuse when it is
#: `#`, and open `DATA/TXT/<language>/Info/Data.txt` at that letter plus a
#: digit naming the family -- `0` a unit, `1` equipment, `2` a weapon. The
#: letter is `Info.lcl`'s own last string column, which `inclib.info` parses
#: as `key`.
INFO_EQUIPMENT_WRAPPER = 0x00432B70
INFO_WEAPON_WRAPPER = 0x00432BD0
INFO_UNIT_WRAPPER = 0x00432B20
#: `mov cl, byte [eax + 0x517BD9]` and `mov al, byte [ecx + 0x51B300]` -- the
#: letter's absolute address at record 0, and what that is as a field offset.
INFO_EQUIPMENT_LETTER = (0x00432B80, 0x00517BD9)
INFO_WEAPON_LETTER = (0x00432BDE, 0x0051B300)
INFO_EQUIPMENT_LETTER_FIELD = 0x29
INFO_WEAPON_LETTER_FIELD = 0x40
#: The `cmp al, '#'` each makes before opening anything.
INFO_NO_PAGE_TESTS = (0x00432B86, 0x00432BE4)
INFO_NO_PAGE = ord("#")
#: The digit each family appends, and the file all three name.
INFO_FAMILY_DIGITS = ((INFO_UNIT_WRAPPER, 0x00432B27, ord("0")),
                      (INFO_EQUIPMENT_WRAPPER, 0x00432BA9, ord("1")),
                      (INFO_WEAPON_WRAPPER, 0x00432C06, ord("2")))
INFO_FILE_PUSH = 0x00432B51
INFO_FILE = "Data"
#: `0x00458B2D` and `0x004587A6` -- where the item panel opens it, and the
#: rectangle it hands over: the item window's own interior.
INFO_ITEM_CALLS = ((0x00458B2D, INFO_EQUIPMENT_WRAPPER),
                   (0x004587A6, INFO_WEAPON_WRAPPER))
INFO_ITEM_BOX_PUSHES = (0x00458B27, 0x00458B22, 0x00458B1D, 0x00458B1B)
INFO_ITEM_BOX = (405, 140, 170, 110)

#: The skill columns each shortfall reads, as (unit offset, table address).
#: A weapon record is 65 bytes and its four skills are `+0x33..+0x36`; an
#: equipment record is 42 and its six are `+0x23..+0x28`.
WEAPON_SKILL_READS = ((0x1B, 0x51B2F3), (0x1C, 0x51B2F4), (0x1D, 0x51B2F5),
                      (0x1A, 0x51B2F6))
EQUIPMENT_SKILL_READS = ((0x1B, 0x517BD4), (0x1C, 0x517BD5), (0x1D, 0x517BD6),
                         (0x1A, 0x517BD3), (0x1F, 0x517BD8), (0x1E, 0x517BD7))
WEAPON_RECORD_STRIDE = 65
EQUIPMENT_RECORD_STRIDE = 42
WEAPON_SKILL_FIELD = 0x33
EQUIPMENT_SKILL_FIELD = 0x23


def _mov_cl_disp8(b: Binary, va: int) -> int | None:
    """``mov cl, byte [edi + disp8]`` at *va*, as the displacement."""
    if b.pe.bytes_at(va, 2) != b"\x8a\x4f":
        return None
    return b.u8(va + 2)


def _mov_dl_absolute(b: Binary, va: int, window: int = 12) -> int | None:
    """The first ``mov dl, byte [esi + disp32]`` at or after *va*.

    The compiler interleaves the two loads with whatever else the block is
    doing -- `shl esi, 1` and a `push` sit between them in the equipment
    routine -- so the table read is found rather than counted to.
    """
    for step in range(window):
        if b.pe.bytes_at(va + step, 2) == b"\x8a\x96":
            return b.u32(va + step + 2)
    return None


def check_upgrade_purchase(ck: Checker, b: Binary) -> None:
    """docs/27 section 5.3 -- the other half of a purchase's price.

    Equipment points are what the Upgrade Menu counts down; the training
    points at `+0x18` are the half nothing had pinned.  Both buyers end the
    same way -- raise every skill the item wants to the item's own number,
    add up what was raised, and subtract twelve of `+0x18` per point -- and
    `aBuyEquipment` is a **toggle** with four exclusive ranges and one grant
    in front of that.  Every claim below is read back out of the shipped
    executable rather than asserted.
    """
    # The two buyers reach the two shortfall routines.
    ck.equal("buy.weapon_shortfall", b.call_target(WEAPON_SHORTFALL_CALL),
             WEAPON_SHORTFALL, hex)
    ck.equal("buy.equipment_shortfall",
             b.call_target(EQUIPMENT_SHORTFALL_CALL), EQUIPMENT_SHORTFALL, hex)

    # The catalogue limits: `cmp eax, imm8` then a `jg`/`jle` out.
    ck.check("buy.weapon_id_max",
             b.pe.bytes_at(0x00475689, 3) == b"\x83\xf8" + bytes([WEAPON_ID_MAX]),
             f"cmp eax, {WEAPON_ID_MAX}")
    ck.check("buy.equipment_id_max",
             b.pe.bytes_at(0x004755DD, 3)
             == b"\x83\xf8" + bytes([EQUIPMENT_ID_MAX]),
             f"cmp eax, {EQUIPMENT_ID_MAX}")

    # `short * 12`, and the subtraction is a byte.
    for name, (triple, dbl, load, store) in (
            ("weapon", WEAPON_EPILOGUE), ("equipment", EQUIPMENT_EPILOGUE)):
        ck.check(f"buy.{name}_times_three",
                 b.pe.bytes_at(triple, 3) == b"\x8d\x04\x40",
                 f"{triple:#x}: lea eax, [eax + eax*2]")
        ck.check(f"buy.{name}_times_four",
                 b.pe.bytes_at(dbl, 3) == b"\xc1\xe0\x02",
                 f"{dbl:#x}: shl eax, 2")
        ck.check(f"buy.{name}_reads_tp",
                 b.pe.bytes_at(load, 3)
                 == b"\x8a\x56" + bytes([UNIT_TRAINING_POINTS]),
                 f"{load:#x}: mov dl, byte [esi + {UNIT_TRAINING_POINTS:#x}]")
        ck.check(f"buy.{name}_writes_tp",
                 b.pe.bytes_at(store, 3)
                 == b"\x88\x56" + bytes([UNIT_TRAINING_POINTS]),
                 f"{store:#x}: mov byte [esi + {UNIT_TRAINING_POINTS:#x}], dl")

    # The toggle: an id already carried is cleared and the routine returns
    # before it ever reaches the price.
    ck.check("buy.equipment_is_a_toggle",
             b.pe.bytes_at(0x004755EA, 4)
             == b"\x8a\x4c\x30" + bytes([UNIT_EQUIPMENT_FLAGS])
             and b.pe.bytes_at(0x004755F2, 5)
             == b"\xc6\x44\x30" + bytes([UNIT_EQUIPMENT_FLAGS]) + b"\x00",
             "mov cl, [eax+esi+0x21] / mov byte [eax+esi+0x21], 0")
    ck.check("buy.equipment_toggle_is_before_the_price",
             0x004755EA < EXCLUSIVE_RANGES[0][0] < EQUIPMENT_SHORTFALL_CALL,
             "the clear returns without spending anything")

    # The Jet Pack's grant.
    ck.check("buy.jet_pack_test",
             b.pe.bytes_at(JET_PACK_TEST, 3) == b"\x83\xf8\x07",
             f"{JET_PACK_TEST:#x}: cmp eax, 7")
    ck.check("buy.jet_pack_grant",
             b.pe.bytes_at(JET_PACK_GRANT, 4)
             == b"\xc6\x46" + bytes([UNIT_EQUIPMENT_FLAGS + 1]) + b"\x01",
             f"{JET_PACK_GRANT:#x}: mov byte [esi + 0x22], 1 -- item 1")

    # The four exclusive ranges, read off their own tests and writes.
    groups: list[list[int]] = []
    for low_site, high_site, write_site, width in EXCLUSIVE_RANGES:
        ck.check(f"buy.range_low_{low_site:#x}",
                 b.pe.bytes_at(low_site, 2) == b"\x83\xf8",
                 f"{low_site:#x}: cmp eax, imm8")
        low = b.u8(low_site + 2)
        if high_site is None:
            # `cmp eax, 1 / jg` -- the range is 0..1, the low test being the
            # only one because ids below zero were refused at the top.
            high = low
            low = 0
        else:
            ck.check(f"buy.range_high_{high_site:#x}",
                     b.pe.bytes_at(high_site, 2) == b"\x83\xf8",
                     f"{high_site:#x}: cmp eax, imm8")
            high = b.u8(high_site + 2)
        opcode = b.pe.bytes_at(write_site, 1)
        want = b"\x66\xc7\x46" if width == 2 else b"\xc7\x46"
        ck.check(f"buy.range_clear_{write_site:#x}",
                 b.pe.bytes_at(write_site, len(want)) == want,
                 f"{write_site:#x}: mov {'word' if width == 2 else 'dword'}"
                 f" [esi + disp8], 0")
        disp = b.u8(write_site + len(want))
        ck.equal(f"buy.range_base_{write_site:#x}",
                 disp - UNIT_EQUIPMENT_FLAGS, low)
        ck.equal(f"buy.range_width_{write_site:#x}", high - low + 1, width,
                 lambda v: str(v))
        groups.append(list(range(low, high + 1)))
        assert opcode  # the read above is what the check used
    ck.equal("buy.exclusive_groups", sorted(groups),
             sorted(list(g) for g in EXCLUSIVE_GROUPS), str)

    # The skill columns, and the record strides that reach them.
    ck.check("buy.weapon_stride",
             b.pe.bytes_at(0x0047A615, 3) == b"\xc1\xe2\x05"
             and b.pe.bytes_at(0x0047A622, 3) == b"\x8d\x34\x51",
             f"shl edx, 5 / lea esi, [ecx + edx*2] -- {WEAPON_RECORD_STRIDE}"
             " bytes a weapon")
    weapon_base = WEAPON_SKILL_READS[0][1] - WEAPON_SKILL_FIELD
    for index, (unit_off, table) in enumerate(WEAPON_SKILL_READS):
        site = (0x0047A625, 0x0047A648, 0x0047A66E, 0x0047A694)[index]
        ck.equal(f"buy.weapon_skill{index}_unit", _mov_cl_disp8(b, site) or -1,
                 unit_off, hex)
        ck.equal(f"buy.weapon_skill{index}_table",
                 _mov_dl_absolute(b, site) or -1, table, hex)
        # The four columns are consecutive in the record, whatever order the
        # compiler visits them in.
        ck.equal(f"buy.weapon_skill{index}_field", table - weapon_base,
                 WEAPON_SKILL_FIELD + index, hex)
    item_base = EQUIPMENT_SKILL_READS[3][1] - EQUIPMENT_SKILL_FIELD
    for index, (unit_off, table) in enumerate(EQUIPMENT_SKILL_READS):
        site = (0x0047A704, 0x0047A72A, 0x0047A750, 0x0047A776, 0x0047A79C,
                0x0047A7C2)[index]
        ck.equal(f"buy.equipment_skill{index}_unit",
                 _mov_cl_disp8(b, site) or -1, unit_off, hex)
        ck.equal(f"buy.equipment_skill{index}_table",
                 _mov_dl_absolute(b, site) or -1, table, hex)
        ck.equal(f"buy.equipment_skill{index}_field", table - item_base,
                 EQUIPMENT_SKILL_FIELD + unit_off - 0x1A, hex)
    # --- what the *i* opens ------------------------------------------------
    for site, target in INFO_ITEM_CALLS:
        ck.equal(f"info.item_call_{site:#x}", b.call_target(site), target, hex)
    ck.equal("info.item_box",
             tuple(b.u32(va + 1) if b.u8(va) == 0x68 else b.u8(va + 1)
                   for va in INFO_ITEM_BOX_PUSHES),
             INFO_ITEM_BOX, str)
    ck.check("info.file",
             b.pe.bytes_at(INFO_FILE_PUSH, 1) == b"\x68"
             and b.string(b.u32(INFO_FILE_PUSH + 1), 16) == INFO_FILE,
             f"push \"{INFO_FILE}\"")
    for entry, site, digit in INFO_FAMILY_DIGITS:
        ck.check(f"info.family_{entry:#x}",
                 b.pe.bytes_at(site, 2) == bytes([0x6A, digit]),
                 f"{site:#x}: push '{chr(digit)}'")
    for name, (site, table), field in (
            ("equipment", INFO_EQUIPMENT_LETTER, INFO_EQUIPMENT_LETTER_FIELD),
            ("weapon", INFO_WEAPON_LETTER, INFO_WEAPON_LETTER_FIELD)):
        ck.check(f"info.{name}_letter_read",
                 b.pe.bytes_at(site, 2) in (b"\x8a\x88", b"\x8a\x81")
                 and b.u32(site + 2) == table,
                 f"{site:#x}: the record's letter at {table:#x}")
    ck.equal("info.equipment_letter_field",
             INFO_EQUIPMENT_LETTER[1] - item_base, INFO_EQUIPMENT_LETTER_FIELD,
             hex)
    ck.equal("info.weapon_letter_field",
             INFO_WEAPON_LETTER[1] - weapon_base, INFO_WEAPON_LETTER_FIELD,
             hex)
    for site in INFO_NO_PAGE_TESTS:
        ck.check(f"info.no_page_{site:#x}",
                 b.pe.bytes_at(site, 3) in (bytes([0x80, 0xF9, INFO_NO_PAGE]),
                                            bytes([0x3C, INFO_NO_PAGE, 0x00])[:2]
                                            + b.pe.bytes_at(site + 2, 1)),
                 f"{site:#x}: cmp <letter>, '#'")

    # The record's own layout: the skills sit at `+0x33..+0x36` of a weapon and
    # `+0x23..+0x28` of an item, which is what docs/27 section 5.3 says.
    ck.equal("buy.weapon_skill_field", WEAPON_SKILL_FIELD, 0x33, hex)
    ck.equal("buy.equipment_skill_field", EQUIPMENT_SKILL_FIELD, 0x23, hex)
    # Four columns for a weapon and six for an item, which is the whole of the
    # difference between the two: `WEAPON_SKILL_ORDER` against
    # `EQUIPMENT_SKILL_ORDER` in `core/campaign/upgrade.gd`.
    ck.equal("buy.weapon_skill_count", len(WEAPON_SKILL_READS), 4)
    ck.equal("buy.equipment_skill_count", len(EQUIPMENT_SKILL_READS), 6)
    ck.equal("buy.skill_order_is_the_same_prefix",
             [off for off, _ in WEAPON_SKILL_READS],
             [off for off, _ in EQUIPMENT_SKILL_READS][:4], str)


def check_screen_camera(ck: Checker, b: Binary) -> None:
    """docs/27 section 2.6 -- the campaign screen's camera setup.

    The remake computed a view over the open locations because nothing said
    where the original stands. `aMissionControl.cpp` writes six initial
    globals, then selects the eye from the current location in
    :func:`check_camera_presets`; the resulting six values are handed to
    `aSetCameraPosition` when the map is raised.
    """
    for i, (site, want) in enumerate(zip(CAMERA_EYE_WRITES, CAMPAIGN_EYE)):
        head = b.pe.bytes_at(site, 6)
        ck.equal(f"screen.eye{i}_target",
                 struct.unpack("<I", head[2:6])[0], CAMERA_EYE_GLOBAL + 4 * i,
                 hex)
        ck.check(f"screen.eye{i}_is_an_immediate", head[:2] == b"\xc7\x05",
                 f"{site:#x}: mov dword [global], imm32")
        ck.equal(f"screen.eye{i}", b.i32(site + 6), want)

    ck.check("screen.target_load",
             b.pe.bytes_at(CAMERA_TARGET_LOAD, 5)
             == b"\xb8" + struct.pack("<I", CAMPAIGN_TARGET[0]),
             f"{CAMERA_TARGET_LOAD:#x}: mov eax, {CAMPAIGN_TARGET[0]:#x}")
    for i, site in enumerate(CAMERA_TARGET_STORES):
        ck.check(f"screen.target{i}_store",
                 b.pe.bytes_at(site, 5)
                 == b"\xa3" + struct.pack("<I", CAMERA_TARGET_GLOBAL + 4 * i),
                 f"{site:#x}: mov [{CAMERA_TARGET_GLOBAL + 4 * i:#x}], eax")
    ck.equal("screen.target_x_equals_y", CAMPAIGN_TARGET[0],
             CAMPAIGN_TARGET[1])
    # The z is the register the prologue cleared, so it is zero rather than a
    # number anybody chose.
    ck.check("screen.target_z_store",
             b.pe.bytes_at(CAMERA_TARGET_Z_STORE, 6)
             == b"\x89\x1d" + struct.pack("<I", CAMERA_TARGET_GLOBAL + 8),
             f"{CAMERA_TARGET_Z_STORE:#x}: mov [global], ebx")
    ck.check("screen.ebx_is_zero",
             b.pe.bytes_at(SCREEN_ENTRY_ZERO, 2) == b"\x33\xdb"
             and SCREEN_ENTRY < SCREEN_ENTRY_ZERO < CAMERA_TARGET_Z_STORE,
             f"xor ebx, ebx at {SCREEN_ENTRY_ZERO:#x}")
    ck.equal("screen.target_z", CAMPAIGN_TARGET[2], 0)

    # The map screen pushes all six, eye first, and calls the setter.
    ck.equal("screen.camera_handover", b.call_target(CAMERA_HANDOVER),
             SET_CAMERA_POSITION, hex)
    pushes = _pushed_globals(b, CAMERA_HANDOVER_BLOCK, CAMERA_HANDOVER)
    ck.equal("screen.camera_argument_order", pushes,
             [CAMERA_EYE_GLOBAL + 4 * i for i in range(6)],
             lambda v: str([hex(x) for x in v]))

    # The window the plate leaves clear.
    ck.equal("screen.viewport_call", b.call_target(VIEWPORT_SITE),
             SET_VIEWPORT, hex)
    ck.equal("screen.viewport", _pushed_literals(b, VIEWPORT_SITE, 4),
             list(CAMPAIGN_VIEWPORT))

    # `0x004558F0` is what moves the eye afterwards; its height clamp is the
    # band the constant sits in.
    for i, (site, want) in enumerate(zip(CAMERA_HEIGHT_CLAMP,
                                         reversed(CAMPAIGN_HEIGHT_BAND))):
        ck.check(f"screen.height_clamp{i}",
                 b.pe.bytes_at(site, 1) == b"\x3d"
                 and b.i32(site + 1) == want,
                 f"{site:#x}: cmp eax, {want}")
    ck.check("screen.eye_inside_the_band",
             CAMPAIGN_HEIGHT_BAND[0] < CAMPAIGN_EYE[2] < CAMPAIGN_HEIGHT_BAND[1],
             f"eye z {CAMPAIGN_EYE[2]}")


def check_camera_presets(ck: Checker, b: Binary) -> None:
    """The authored campaign-map eye selected by current location.

    `0x004541D9` passes `missionId + 50` and pointers to the three eye
    globals. `0x0045D130` maps locations 59..129 through a byte selector onto
    thirteen arms; everything else takes the default. This is what keeps each
    campaign's current open locations in the initial frame without a manual
    turn.
    """
    ck.equal("camera_preset.call", b.call_target(CAMERA_PRESET_CALL),
             CAMERA_PRESET, hex)
    ck.equal("camera_preset.eye_pointers",
             tuple(b.u32(site + 1) for site in CAMERA_PRESET_POINTER_PUSHES),
             CAMERA_PRESET_POINTERS,
             lambda values: str([hex(v) for v in values]))
    ck.check("camera_preset.location_bias",
             b.pe.bytes_at(CAMERA_PRESET_BIAS_SITE, 3)
             == bytes([0x83, 0xC0, (-CAMERA_PRESET_FIRST) & 0xFF]),
             f"location - {CAMERA_PRESET_FIRST}")
    ck.check("camera_preset.location_limit",
             b.pe.bytes_at(CAMERA_PRESET_LIMIT_SITE, 3)
             == bytes([0x83, 0xF8,
                       CAMERA_PRESET_LAST - CAMERA_PRESET_FIRST]),
             f"locations {CAMERA_PRESET_FIRST}..{CAMERA_PRESET_LAST}")

    arms = tuple(b.u32(CAMERA_PRESET_ARM_TABLE + 4 * i)
                 for i in range(len(CAMERA_PRESET_ARMS) + 1))
    ck.equal("camera_preset.arms", arms,
             CAMERA_PRESET_ARMS + (CAMERA_PRESET_DEFAULT,),
             lambda values: str([hex(v) for v in values]))
    selectors = tuple(b.pe.bytes_at(
        CAMERA_PRESET_SELECTOR_TABLE,
        CAMERA_PRESET_LAST - CAMERA_PRESET_FIRST + 1))
    ck.equal("camera_preset.selectors", selectors,
             tuple(CAMERA_PRESET_SELECTORS))

    eyes = tuple((b.i32(arm + 14), b.i32(arm + 20), b.i32(arm + 26))
                 for arm in CAMERA_PRESET_ARMS)
    ck.equal("camera_preset.eyes", eyes, CAMERA_PRESET_EYES)
    default_eye = (b.i32(CAMERA_PRESET_DEFAULT + 14),
                   b.i32(CAMERA_PRESET_DEFAULT + 20),
                   b.i32(CAMERA_PRESET_DEFAULT + 26))
    ck.equal("camera_preset.default", default_eye,
             CAMERA_PRESET_DEFAULT_EYE)
    ck.check("camera_preset.heights_are_clamped",
             all(CAMPAIGN_HEIGHT_BAND[0] <= eye[2]
                 <= CAMPAIGN_HEIGHT_BAND[1]
                 for eye in CAMERA_PRESET_EYES + (CAMERA_PRESET_DEFAULT_EYE,)),
             "all thirteen authored eyes and the default fit the turn's band")


def check_screen_rotation(ck: Checker, b: Binary) -> None:
    """docs/27 §2.6 -- what turns the map, and by how much.

    This was the document's fourth open question, and both halves of it are
    here: the **source** is a cursor drag with the pointer warped back to its
    anchor every frame, and the **delta** is that travel doubled for the turn
    and multiplied by -50 for the height.  The units follow from where the
    angle goes -- `0x004039A0`'s third angle, so Eng3d's 4096ths.
    """
    ck.equal("rotate.screen_id", _cmp_imm(b, ROTATE_SCREEN_CMP),
             ROTATE_SCREEN_ID, str)
    ck.equal("rotate.screen_global", b.u32(ROTATE_SCREEN_SITE + 1),
             SCREEN_ID_GLOBAL, hex)
    ck.equal("rotate.button_getter", b.call_target(ROTATE_INPUT + 0x18),
             ROTATE_BUTTON_GETTER, hex)
    ck.check("rotate.button_is_a_byte",
             b.pe.bytes_at(ROTATE_BUTTON_GETTER, 2) == b"\x33\xc0"
             and b.u32(ROTATE_BUTTON_GETTER + 3) == ROTATE_BUTTON_BYTE,
             "0x0045F000 answers with one byte of state")
    # **Which button.**  The message pump's own table, and the setter each of
    # its five button arms calls: the right button's three write the byte the
    # drag reads, the left button's two write the byte beside it.
    ck.equal("rotate.message_table",
             [hex(b.u32(MESSAGE_TABLE + 4 * index))
              for index, _ in enumerate(MESSAGE_BUTTON_ARMS)],
             [hex(arm) for _, arm, _, _ in MESSAGE_BUTTON_ARMS])
    ck.equal("rotate.message_dispatch",
             (-b.i32(MESSAGE_BIAS_SITE + 1), b.u8(MESSAGE_BOUND_SITE + 2) + 1,
              hex(b.u32(MESSAGE_JUMP_SITE + 3))),
             (MESSAGE_TABLE_FIRST, len(MESSAGE_BUTTON_ARMS),
              hex(MESSAGE_TABLE)))
    ck.equal("rotate.left_button_press_arm",
             (hex(b.u32(MESSAGE_LBUTTONDOWN_CMP + 1)),
              hex(MESSAGE_LBUTTONDOWN_JE + 2
                  + b.i8(MESSAGE_LBUTTONDOWN_JE + 1))),
             (hex(0x0201), hex(MESSAGE_LBUTTONDOWN_ARM)))
    ck.equal("rotate.button_setters",
             [(hex(message), hex(_arm_setter(b, arm)), _arm_push(b, arm))
              for message, arm, _, _ in MESSAGE_BUTTON_ARMS],
             [(hex(message), hex(setter), push)
              for message, _, setter, push in MESSAGE_BUTTON_ARMS])
    ck.check("rotate.left_button_is_the_other_byte",
             b.pe.bytes_at(LEFT_BUTTON_SETTER, 4) == b"\x8a\x44\x24\x04"
             and b.u32(LEFT_BUTTON_SETTER + 5) == LEFT_BUTTON_BYTE,
             "0x0045EFC0 writes 0x00511B08, the left button's own byte")
    ck.check("rotate.pushed_registers_are_the_state",
             b.pe.bytes_at(MESSAGE_PUMP_ZERO, 2) == b"\x33\xdb"
             and b.pe.bytes_at(MESSAGE_PUMP_ONE, 5)
             == b"\xbd\x01\x00\x00\x00",
             "`xor ebx, ebx` and `mov ebp, 1` -- released and pressed")
    # The two deltas.  The horizontal is a shift; the vertical is five
    # instructions that come to a multiply by -50.
    ck.equal("rotate.dx_source", b.call_target(ROTATE_DX_CALL),
             ROTATE_DX_GETTER, hex)
    # `d1 e0` -- `shl eax, 1`, whose count is in the opcode and not in an
    # immediate, so the doubling is read off the encoding.
    ck.equal("rotate.turn_per_pixel",
             2 if b.pe.bytes_at(ROTATE_DX_SHIFT_SITE, 2) == b"\xd1\xe0"
             else 0, ROTATE_TURN_PER_PIXEL)
    ck.equal("rotate.turn_store", b.u32(ROTATE_DELTA_STORE + 1),
             ROTATE_DELTA_GLOBAL, hex)
    ck.equal("rotate.dy_source", b.call_target(ROTATE_DY_CALL),
             ROTATE_DY_GETTER, hex)
    ck.equal("rotate.rise_per_pixel", _rise_factor(b), ROTATE_RISE_PER_PIXEL)
    ck.equal("rotate.rise_store", b.u32(ROTATE_HEIGHT_STORE + 2),
             ROTATE_HEIGHT_GLOBAL, hex)
    # The pointer itself: current minus anchor, and the warp that makes the
    # next frame's reading fresh.
    ck.equal("rotate.dx_is_travel",
             (b.u32(ROTATE_DX_GETTER + 1), b.u32(ROTATE_DX_GETTER + 7)),
             (ROTATE_CURSOR[0], ROTATE_ANCHOR[0]))
    ck.equal("rotate.dy_is_travel",
             (b.u32(ROTATE_DY_GETTER + 1), b.u32(ROTATE_DY_GETTER + 7)),
             (ROTATE_CURSOR[1], ROTATE_ANCHOR[1]))
    ck.check("rotate.cursor_is_warped_back",
             b.u32(ROTATE_WARP + 2) == ROTATE_ANCHOR[1]
             and b.u32(ROTATE_WARP + 7) == ROTATE_ANCHOR[0],
             "0x0045EEF0 puts the pointer back on the anchor")
    # `0x004558F0` itself.
    ck.equal("rotate.apply_sites",
             [hex(b.call_target(site)) for site in ROTATE_APPLY_SITES],
             [hex(ROTATE_APPLY)] * len(ROTATE_APPLY_SITES))
    ck.equal("rotate.idle_call_asks_for_nothing",
             tuple(_push_value(b, site) for site in ROTATE_IDLE_PUSHES),
             (0, 0))
    ck.check("rotate.inertia_halves_the_step",
             b.pe.bytes_at(ROTATE_INERTIA_CMP, 2) == b"\x3b\xd8"
             and b.u8(ROTATE_INERTIA_JLE) == 0x7E
             and b.pe.bytes_at(ROTATE_HALVE_SITE, 2) == b"\xd1\xf8",
             "`cmp ebx, eax / jle` then `sar eax, 1` -- decay, not a clamp")
    ck.equal("rotate.accumulator",
             (b.u32(ROTATE_ANGLE_READ + 2), b.u32(ROTATE_ANGLE_STORE + 2),
              b.u32(ROTATE_STEP_STORE + 1)),
             (ROTATE_ANGLE_GLOBAL, ROTATE_ANGLE_GLOBAL, ROTATE_STEP_GLOBAL))
    ck.check("rotate.angle_is_a_word",
             b.pe.bytes_at(ROTATE_ANGLE_WORD_SITE, 3) == b"\x66\x89\x4c",
             "the accumulator's low word is what becomes the angle")
    ck.equal("rotate.angle_goes_through_eng3d",
             b.call_target(ROTATE_MATRIX_CALL), ROTATE_MATRIX, hex)
    # And the reason the turn is absolute: the camera call writes nothing
    # back, so the eye it rotates is the constant one.
    ck.equal("rotate.camera_call", b.call_target(ROTATE_CAMERA_CALL),
             SET_CAMERA_POSITION, hex)
    ck.check("rotate.eye_is_never_written_back",
             all(site < SET_CAMERA_POSITION or site > SET_CAMERA_POSITION + 0x80
                 for site in b.absolute_refs(CAMERA_EYE_X_GLOBAL)),
             "0x00403560 hands the eye to Eng3d and keeps no copy")
    ck.check("rotate.height_is_the_one_that_accumulates",
             b.u32(CAMERA_HEIGHT_CLAMP[0] - 0xE + 1) == CAMERA_EYE_Z_GLOBAL,
             "0x00510BC0 is read, added to and written back")


def check_projection(ck: Checker, b: Binary) -> None:
    """docs/27 §2.6 -- Eng3d's perspective is a constant, not a field of view.

    `0x00403460` computes the focal length from the **window's width alone**,
    `_ftol(width * 10 / 13)`, and hands it to `_E3D_init_3d_screen` as its
    fifth argument; the DLL keeps it at `+0x14FE8` with its reciprocal beside
    it, which is the divide a projection is.  The remake had a default 75
    degree `Camera3D` with its axis through the middle of the render, and the
    engine's axis is the **window's** centre.
    """
    ck.check("projection.constant_is_ten_thirteenths",
             b.pe.bytes_at(PROJECTION_CONSTANT_SITE, 2) == b"\xdc\x0d"
             and abs(b.pe.f64(b.u32(PROJECTION_CONSTANT_SITE + 2))
                     - PROJECTION_CONSTANT) < 1e-12,
             f"fmul qword -- {PROJECTION_CONSTANT!r}")
    ck.equal("projection.truncates", b.call_target(PROJECTION_FTOL_SITE),
             FTOL, hex)
    ck.check("projection.width_is_the_only_input",
             b.pe.bytes_at(PROJECTION_WIDTH_SITE, 4) == b"\x8b\x74\x24\x20",
             "the fifth argument -- the window's width -- and nothing else")
    ck.equal("projection.zoom_divisor",
             (b.u32(PROJECTION_INIT + 2), b.u32(PROJECTION_ZOOM_SETTER + 5)),
             (PROJECTION_ZOOM_GLOBAL, PROJECTION_ZOOM_GLOBAL))
    eng3d = PEFile(os.path.join(b.root, ENG3D_DLL))
    listing = eng3d.exports()
    names = [name for _ordinal, _rva, name, _fwd in (listing[1] if listing
                                                     else [])]
    ck.check("projection.entry_point", PROJECTION_ENG3D_ENTRY in names,
             "Eng3d.dll ordinal 3 takes the focal length as its fifth")
    ck.equal("projection.eng3d_default",
             eng3d.u32(eng3d.image_base + ENG3D_FOCAL_RVA),
             PROJECTION_ENG3D_DEFAULT,
             lambda v: f"{v} at Eng3d.dll+{ENG3D_FOCAL_RVA:#x}")
    # The map's own call names the same rectangle 0x00454102 does, which is
    # the viewport read a second way.
    ck.equal("projection.map_window",
             tuple(_push_value(b, site) for site in PROJECTION_MAP_PUSHES),
             CAMPAIGN_VIEWPORT)
    ck.equal("projection.map_focal_length",
             int(CAMPAIGN_VIEWPORT[2] * PROJECTION_CONSTANT), 398)


def _cmp_imm(b: Binary, va: int) -> int | None:
    """`cmp r32, imm` in either of the two encodings the compiler uses."""
    op = b.u8(va)
    if op == 0x83:
        return b.i8(va + 2)
    if op == 0x3D:
        return b.i32(va + 1)
    return None


def _push_value(b: Binary, va: int) -> int | None:
    return b._push_imm(va)[0]


def _arm_setter(b: Binary, arm: int) -> int:
    """The setter a button arm calls, found past its single `push`."""
    return b.call_target(arm + _push_offset(b, arm))


def _arm_push(b: Binary, arm: int) -> str:
    """The register a button arm pushes -- `ebp` pressed, `ebx` released."""
    opcode = b.u8(arm + _push_offset(b, arm) - 1)
    for name, code in PUSH_OPCODES.items():
        if code == opcode:
            return name
    return hex(opcode)


def _push_offset(b: Binary, arm: int) -> int:
    """Where the arm's `call` stands: right after its `push`, but the
    right button's arms compare a global first (`cmp dword [..], ebx` and a
    `jne`, eight bytes) before they push."""
    for offset in (1, 9):
        if b.u8(arm + offset) == 0xE8:
            return offset
    return 1


def _rise_factor(b: Binary) -> int:
    """`0x0045559A`'s five instructions, as the number they multiply by.

    `neg / shl 2 / sub / lea [ecx+ecx*4] / shl 1` is `-50`, and no single
    instruction in the block says so -- which is why it is replayed here
    rather than read off an immediate.
    """
    forms = (b"\xf7\xd9", b"\xc1\xe1\x02", b"\x2b\xc8",
             b"\x8d\x0c\x89", b"\xd1\xe1")
    for site, form in zip(ROTATE_RISE_SITES, forms):
        if b.pe.bytes_at(site, len(form)) != form:
            return 0
    value, original = 1, 1
    value = -value                      # neg ecx
    value <<= 2                         # shl ecx, 2
    value -= original                   # sub ecx, eax
    value += value * 4                  # lea ecx, [ecx + ecx*4]
    return value << 1                   # shl ecx, 1


def _pushed_globals(b: Binary, start: int, call_site: int) -> list[int]:
    """The globals pushed between *start* and *call_site*, in argument order.

    The compiler interleaves `mov r32, [imm32]` with the pushes that spend
    them, so this decodes **forwards** over the four instruction forms the
    block is made of and pairs each `push r32` with the global that register
    was last loaded from.  A cdecl call takes its first argument from the last
    push, so the answer is the push order reversed.
    """
    loads: dict[int, int] = {}
    pushed: list[int] = []
    va = start
    while va < call_site:
        head = b.pe.bytes_at(va, 6)
        if head[0] == 0xA1:                                   # mov eax, [m32]
            loads[0] = struct.unpack("<I", head[1:5])[0]
            va += 5
        elif head[0] == 0x8B and (head[1] & 0xC7) == 0x05:     # mov r32, [m32]
            loads[(head[1] >> 3) & 7] = struct.unpack("<I", head[2:6])[0]
            va += 6
        elif 0x50 <= head[0] <= 0x57:                          # push r32
            pushed.append(loads.get(head[0] - 0x50, -1))
            va += 1
        elif head[0] == 0x83 and head[1] == 0xC4:              # add esp, imm8
            va += 3
        else:
            return []                                # an unexpected form: fail
    pushed.reverse()
    return pushed


def _pushed_literals(b: Binary, call_site: int, count: int) -> list[int]:
    """The `push imm` chain before *call_site*, in argument order."""
    out: list[int] = []
    va = call_site
    while len(out) < count:
        if b.pe.bytes_at(va - 5, 1) == b"\x68":
            out.append(b.i32(va - 4))
            va -= 5
        elif b.pe.bytes_at(va - 2, 1) == b"\x6a":
            out.append(b.i8(va - 1))
            va -= 2
        else:
            break
    return out


def run_checks(root: str) -> Checker:
    ck = Checker()
    b = Binary(root)
    c = Corpus(root)

    # -- 1. the corpus is there ---------------------------------------------
    ck.check("corpus.missions", len(c.missions) == EXPECTED_MISSIONS,
             f"{len(c.missions)}/{EXPECTED_MISSIONS} .lev files under {root!r}")
    campaign = c.campaign_missions()
    ck.check("corpus.campaign_missions",
             len(campaign) == EXPECTED_CAMPAIGN_MISSIONS,
             f"{len(campaign)}/{EXPECTED_CAMPAIGN_MISSIONS} map-type-1 missions")
    ck.check("corpus.campaign_maps",
             all(name in c.campaign_cells for name in CAMPAIGN_MAPS.values()),
             f"{sorted(c.campaign_cells)}")
    ck.check("corpus.campaign_lcl", CAMPAIGN_LCL in c.text,
             f"{len(c.text.get(CAMPAIGN_LCL, ()))} text entries")
    ck.check("corpus.squad_text", SQUAD_TEXT_FILE in c.text,
             f"{len(c.text.get(SQUAD_TEXT_FILE, ()))} text entries")
    ck.check("corpus.info_lcl", bool(c.weapons) and bool(c.units),
             f"{len(c.weapons)} weapons, {len(c.units)} unit types")
    ck.equal("corpus.mission_scripts", len(c.mission_scripts),
             EXPECTED_MISSION_SCRIPTS)

    # -- 2. location = missionId + 50 ---------------------------------------
    for i, site in enumerate(LOCATION_BIAS_SITES):
        ck.equal(f"location.bias_site{i}", b.u8(site + 2), LOCATION_BIAS)
    ck.equal("location.header_base", b.u32(HEADER_BASE_GETTER + 1),
             LEV_HEADER_BASE, hex)
    for getter, (at, offset) in sorted(HEADER_GETTERS.items()):
        ck.equal(f"location.header_{offset:#05x}",
                 b.u32(getter + at) - LEV_HEADER_BASE, offset, hex)
    ck.equal("location.equip_points_offset",
             b.u32(EQUIP_POINTS_GETTER + 7) - LEV_HEADER_BASE,
             EQUIP_POINTS_OFFSET, hex)

    # -- 3. aMapName, the inverse table -------------------------------------
    ck.equal("mapname.bias", -b.i8(MAP_NAME_BIAS_SITE + 2), MAP_NAME_BIAS, hex)
    ck.equal("mapname.limit", b.u8(MAP_NAME_LIMIT_SITE + 2),
             MAP_NAME_ENTRIES - 1)
    names = b.map_names()
    ck.check("mapname.arms_well_formed", all(names.values()),
             f"{len(names)} arms, each a `mov edi, <name>`")
    ck.equal("mapname.entries", len(names), MAP_NAME_ENTRIES - 2)
    #: the default arm returns TRUE without writing the caller's buffer
    ck.check("mapname.default_writes_nothing",
             b.u8(MAP_NAME_DEFAULT) == 0x5F
             and b.u8(MAP_NAME_DEFAULT + 1) == 0xB8
             and b.u32(MAP_NAME_DEFAULT + 2) == 1,
             f"pop edi; mov eax,1 at {MAP_NAME_DEFAULT:#010x}")
    ck.equal("mapname.default_locations",
             sorted(set(range(MAP_NAME_BIAS,
                              MAP_NAME_BIAS + MAP_NAME_ENTRIES)) - set(names)),
             MAP_NAME_UNNAMED)
    bad = sorted((stem, mid) for mid, stem in campaign.items()
                 if names.get(mid + LOCATION_BIAS) != stem)
    _ = bad
    ck.check("mapname.round_trip", bad == [MAP_NAME_ORPHAN],
             f"{len(campaign) - len(bad)}/{len(campaign)} missions; "
             f"the only exception is {MAP_NAME_ORPHAN[0]} "
             f"(id {MAP_NAME_ORPHAN[1]}, outside the table)")
    stems = c.stems()
    cut = {loc: name for loc, name in names.items()
           if name and name.upper() not in stems}
    ck.equal("mapname.cut_missions", cut, CUT_MISSIONS)

    # -- 4. aCreateLocationMap, the unlock graph ----------------------------
    ck.equal("locmap.limit", b.u8(LOCATION_MAP_LIMIT_SITE + 2),
             LOCATION_MAP_ENTRIES - 1)
    ck.equal("locmap.clear_call", b.call_target(CREATE_LOCATION_MAP),
             LOCATION_MAP_CLEAR, hex)
    graph = b.location_map()
    ck.equal("locmap.pairs",
             sum(len(v) for v in graph.values() if v), LOCATION_MAP_PAIRS)
    ck.equal("locmap.counts",
             {loc: sum(1 for v in graph.values() if v
                       for l, _f in v if l == loc)
              for loc in {l for v in graph.values() if v for l, _f in v}},
             LOCATION_MAP_COUNTS, lambda d: f"{len(d)} locations")
    ck.equal("locmap.gaps",
             tuple(sorted(k for k, v in graph.items() if v is None)),
             LOCATION_MAP_GAPS)
    ck.check("locmap.every_flag_is_one",
             all(flag == 1 for v in graph.values() if v for _loc, flag in v),
             "every arm enables, none disables")
    missing = sorted(mid for mid, stem in campaign.items()
                     if graph.get(mid) is not None
                     and mid + LOCATION_BIAS not in
                     {loc for loc, _f in graph[mid]})
    ck.check("locmap.arm_names_own_location", not missing,
             f"{sum(1 for m in campaign if graph.get(m))} arms each enable "
             f"their own location")
    orphan = c.headers.get(MAP_NAME_ORPHAN[0], {}).get("mission_id")
    ck.check("locmap.orphan_outside",
             orphan == MAP_NAME_ORPHAN[1] > LOCATION_MAP_ENTRIES,
             f"{MAP_NAME_ORPHAN[0]} carries mission id {orphan}, outside "
             f"1..{LOCATION_MAP_ENTRIES}")
    arms = b.location_map_arms()
    shared = [(a, z) for a, z in LOCATION_MAP_BRANCHES if arms[a] == arms[z]]
    ck.equal("locmap.branch_pairs", tuple(shared), LOCATION_MAP_BRANCHES)
    ck.check("locmap.branches_are_the_only_shares",
             sorted(k for k, v in arms.items()
                    if v != LOCATION_MAP_DEFAULT
                    and sum(1 for w in arms.values() if w == v) > 1)
             == sorted(x for pair in LOCATION_MAP_BRANCHES for x in pair),
             "five pairs, nothing else")
    ck.equal("locmap.setter_stride", b.u8(CELL_STRIDE_SITE + 2), CELL_STRIDE)
    ck.equal("locmap.setter_action_point", b.u8(CELL_AP_SITE + 2),
             CELL_AP_OFFSET)
    ck.equal("locmap.setter_and", b.u8(CELL_STATE_AND_SITE + 2),
             CELL_STATE_ENABLED - CELL_STATE_DISABLED)
    ck.check("locmap.setter_states",
             b.u8(CELL_STATE_AND_SITE) == 0x80
             and b.u8(CELL_STATE_INC_SITE) == 0xFE
             and b.u8(CELL_STATE_INC_SITE + 1) == 0xC1
             and b.u8(CELL_STATE_STORE_SITE) == 0x88,
             f"enabled {CELL_STATE_ENABLED}, disabled {CELL_STATE_DISABLED}")

    # -- 5. the graph against the campaign maps -----------------------------
    xxx = c.campaign_cells.get(CAMPAIGN_MAPS[1], set())
    yyy = c.campaign_cells.get(CAMPAIGN_MAPS[2], set())
    ck.equal("cells.xxx", len(xxx), EXPECTED_XXX_LOCATIONS)
    ck.equal("cells.yyy", len(yyy), EXPECTED_YYY_LOCATIONS)
    ck.check("cells.disjoint", not (xxx & yyy),
             "the two campaign maps share no location id")
    enabled_1 = {loc for mid, pairs in graph.items() if pairs and mid < 40
                 for loc, _f in pairs}
    enabled_2 = {loc for mid, pairs in graph.items() if pairs and mid >= 40
                 for loc, _f in pairs}
    ck.equal("cells.graph1_resolves", xxx - enabled_1, UNREACHABLE_LOCATIONS)
    ck.check("cells.graph1_no_stray", enabled_1 <= xxx,
             f"{len(enabled_1)} campaign-1 locations, all present in "
             f"{CAMPAIGN_MAPS[1]}")
    ck.equal("cells.graph2_resolves", enabled_2, yyy)
    ck.check("cells.battles_resolve",
             {mid + LOCATION_BIAS for mid in campaign
              if graph.get(mid) is not None} <= (xxx | yyy),
             "every reachable mission has a cell on a campaign map")
    ck.check("cells.map_types",
             all(c.headers[s]["type"] == MAP_TYPE_SPECIAL
                 for s in c.headers if s.upper() in CAMPAIGN_MAPS.values()),
             f"both campaign maps are map type {MAP_TYPE_SPECIAL}")

    # -- 6. Campaign.lcl names every location -------------------------------
    labels = c.text.get(CAMPAIGN_LCL, {})
    unnamed = sorted((xxx | yyy) - set(labels))
    ck.check("labels.every_cell_named", not unnamed,
             f"{len(xxx | yyy)} location cells, all named in {CAMPAIGN_LCL}")
    ck.check("labels.upgrade", all(loc in labels for loc in UPGRADE_LOCATIONS),
             f"{len(UPGRADE_LOCATIONS)} upgrade locations named")
    ck.check("labels.dialogue",
             all(loc in labels for loc in DIALOGUE_LOCATIONS),
             f"{len(DIALOGUE_LOCATIONS)} dialogue locations named")

    # -- 7. the two campaign maps and the campaign number -------------------
    for number, site in sorted(CAMPAIGN_MAP_SITES.items()):
        ck.equal(f"campaign.map{number}", b.string(b.u32(site + 1), 20),
                 CAMPAIGN_MAP_NAMES[number])
    ck.equal("campaign.number_offset",
             b.u32(CAMPAIGN_NUMBER_GETTER + 3) - GAME_CONTROL_BASE,
             CAMPAIGN_NUMBER_OFFSET, hex)
    ck.equal("campaign.number_setter",
             b.u32(CAMPAIGN_NUMBER_SETTER + 5) - GAME_CONTROL_BASE,
             CAMPAIGN_NUMBER_OFFSET, hex)
    seeders = b.calls_to(CREATE_POOL)
    ck.equal("campaign.pool_seed_sites", len(seeders), 4)
    ck.check("campaign.number_readers",
             sorted(b.calls_to(CAMPAIGN_NUMBER_GETTER)) ==
             [0x0043AF1F, 0x004575E3],
             "the reader that picks the campaign map, plus the reset")

    # -- 8. upgrade locations are maps of their own -------------------------
    ck.equal("upgrade.format", b.string(b.u32(UPGRADE_FORMAT_SITE + 1), 20),
             UPGRADE_FORMAT)
    ck.equal("upgrade.create_call", b.call_target(0x00417557),
             CREATE_BATTLE_MAP, hex)
    upgrade_arms = b.upgrade_arms()
    ck.equal("upgrade.arms", tuple(sorted(upgrade_arms)), UPGRADE_LOCATIONS)
    ck.equal("upgrade.maps", upgrade_arms, UPGRADE_MAPS)
    ck.equal("recruit.categories", b.recruit_categories(),
             RECRUIT_CATEGORY_TYPES, str)
    ck.equal("recruit.slots_are_cleared_first",
             (b.u8(RECRUIT_RESET_SITE), b.u8(RECRUIT_RESET_SITE + 1),
              b.u8(RECRUIT_RESET_SITE + 2)), (0x33, 0xDB, 0x83), str)
    ck.equal("recruit.jump_table", b.u32(RECRUIT_SWITCH_SITE + 3),
             RECRUIT_JUMP_TABLE, hex)
    ck.equal("upgrade.animation_window",
             tuple(b.u8(site + 1) if b.u8(site) == 0x6A else b.u32(site + 1)
                   for site in LOCATION_ANIMATION_WINDOW_SITES),
             LOCATION_ANIMATION_WINDOW, str)
    ck.equal("upgrade.animation_exit_window",
             tuple(b.u8(site + 1) if b.u8(site) == 0x6A else b.u32(site + 1)
                   for site in LOCATION_ANIMATION_EXIT_SITES),
             LOCATION_ANIMATION_EXIT_WINDOW, str)
    ck.equal("upgrade.fly_speed", b.u32(FLY_SPEED_SITE + 4), FLY_SPEED)
    ck.equal("upgrade.fly_smooth_start", b.u32(FLY_SMOOTH_START_SITE + 1),
             FLY_SMOOTH_START)
    # `cmp eax, imm32` is `3d imm32`; `cmp ecx, imm32` is `81 f9 imm32`.
    ck.equal("upgrade.fly_arrival",
             tuple(b.u32(site + (1 if b.u8(site) == 0x3D else 2))
                   for site in FLY_ARRIVAL_SITES),
             (FLY_ARRIVAL,) * len(FLY_ARRIVAL_SITES), str)
    ck.equal("upgrade.fly_landed_share", b.u8(FLY_LANDED_SITE + 4),
             FLY_LANDED_SHARE)
    ck.equal("upgrade.fly_direction_call", b.call_target(0x004172D0),
             FLY_DIRECTION, hex)
    ck.equal("upgrade.fly_flat_distance_is_a_hypotenuse",
             (b.u8(FLY_FLAT_DISTANCE + 0x24), b.u8(FLY_FLAT_DISTANCE + 0x25),
              b.u8(FLY_FLAT_DISTANCE + 0x28), b.u8(FLY_FLAT_DISTANCE + 0x29)),
             (0xDB, 0x44, 0xD9, 0xFA), str)
    # `6a 01` -- which of `0x0046d400`'s two arms the flight takes.  Without
    # this the six shifts below would be pinned on an arm nothing reaches.
    ck.equal("upgrade.fly_direction_arm",
             (b.u8(FLY_DIRECTION_ARM_SITE), b.u8(FLY_DIRECTION_ARM_SITE + 1)),
             (0x6A, FLY_DIRECTION_ARM), str)
    # `c1 /7 ib` is `sar reg, imm8`: the opcode, the reg field of the modrm
    # byte and the count, for each of the six coordinates.
    ck.equal("upgrade.fly_direction_shifts_all_six",
             tuple((b.u8(site), (b.u8(site + 1) >> 3) & 7, b.u8(site + 2))
                   for site in FLY_DIRECTION_SHIFT_SITES),
             ((0xC1, 7, FLY_DIRECTION_SHIFT),) * len(FLY_DIRECTION_SHIFT_SITES),
             str)
    ck.equal("upgrade.fly_flat_distance_call",
             b.call_target(FLY_FLAT_DISTANCE_SITE), FLY_FLAT_DISTANCE, hex)
    ck.equal("upgrade.fly_frame_limit",
             (b.u8(FRAME_LIMITER_SITE + 3), b.u8(FRAME_LIMITER_SITE + 1)),
             FRAME_LIMIT, str)
    ck.equal("upgrade.fly_frame_limiter_call",
             b.call_target(FRAME_LIMITER_SITE + 4), FRAME_LIMITER, hex)
    ck.equal("upgrade.camera_path_table", b.u32(CAMERA_PATH_TABLE_SITE + 2),
             CAMERA_PATH_TABLE, hex)
    ck.equal("upgrade.camera_path_cap", b.u8(CAMERA_PATH_CAP_SITE + 2),
             CAMERA_PATH_CAP)
    ck.equal("upgrade.camera_path_shift", b.u8(CAMERA_PATH_SHIFT_SITE + 2),
             CAMERA_PATH_SHIFT)
    ck.equal("upgrade.camera_saved",
             tuple(b.u32(site + (1 if b.u8(site) == 0xA1 else 2))
                   for site in CAMERA_RESTORE_READS),
             tuple(reversed(CAMERA_SAVED)), str)
    ck.equal("upgrade.camera_restore_call", b.call_target(0x00455A94),
             SET_CAMERA_POSITION, hex)
    # The base's own marines (section 2.7.1).  Both halves of the loop, the
    # player they ask for, the record fields they test, and the kind-4 arm's
    # three playback constants -- all read at their own instructions.
    ck.equal("upgrade.marine_loop_calls",
             (b.call_target(UPGRADE_UNIT_FIRST_SITE),
              b.call_target(UPGRADE_UNIT_NEXT_SITE),
              b.call_target(UPGRADE_UNIT_POINTER_SITE)),
             (UPGRADE_UNIT_FIRST, UPGRADE_UNIT_NEXT, UPGRADE_UNIT_POINTER),
             lambda t: tuple(hex(v) for v in t))
    ck.equal("upgrade.marine_loop_player",
             tuple(b.u8(site + 1) for site in UPGRADE_UNIT_PLAYER_SITES),
             (UPGRADE_UNIT_PLAYER,) * len(UPGRADE_UNIT_PLAYER_SITES), str)
    # `add ecx, 0x45` then `mov dl, [ecx - 0x2f]` -- the player byte and, 0x2f
    # before it, the hit points -- and `add ecx, 0x5b`, the record stride.
    # All three immediates are read at their own instruction.
    ck.equal("upgrade.marine_record_fields",
             (b.u8(UPGRADE_UNIT_FIRST + 0x10), b.u8(UPGRADE_UNIT_FIRST + 0x13),
              b.u8(UPGRADE_UNIT_FIRST + 0x22)),
             (UNIT_RECORD_PLAYER, 0x100 - (UNIT_RECORD_PLAYER
                                           - UNIT_RECORD_HP),
              UNIT_RECORD_STRIDE), str)
    ck.equal("upgrade.marine_start_call", b.call_target(START_ANIMATION_SITE),
             START_ANIMATION, hex)
    ck.equal("upgrade.marine_start_kind", b.u8(UPGRADE_ANIM_KIND_SITE + 1),
             UPGRADE_ANIM_KIND)
    ck.equal("upgrade.marine_start_slot", b.u8(UPGRADE_ANIM_SLOT_SITE + 2),
             UPGRADE_ANIM_SLOT_BIAS)
    ck.equal("upgrade.marine_arm", b.u32(UPGRADE_ANIM_TABLE
                                         + 4 * UPGRADE_ANIM_KIND),
             UPGRADE_ANIM_ARM, hex)
    ck.equal("upgrade.marine_loops", b.u32(UPGRADE_ANIM_LOOPS_SITE + 1),
             UPGRADE_ANIM_LOOPS)
    ck.equal("upgrade.marine_speed",
             struct.unpack("<f", struct.pack(
                 "<I", b.u32(UPGRADE_ANIM_SPEED_SITE + 1)))[0],
             UPGRADE_ANIM_SPEED)
    ck.equal("upgrade.marine_start_time_max",
             b.u8(UPGRADE_ANIM_START_SITE + 1), UPGRADE_ANIM_START_MAX)
    ck.equal("upgrade.marine_start_time_random",
             b.call_target(UPGRADE_ANIM_RANDOM_SITE), UPGRADE_ANIM_RANDOM, hex)
    ck.equal("upgrade.marine_clip",
             b.string(b.u32(UPGRADE_ANIM_CLIP_SITE + 1), 20),
             UPGRADE_ANIM_CLIP)
    ck.equal("upgrade.marine_clip_address", b.u32(UPGRADE_ANIM_CLIP_SITE + 1),
             UPGRADE_ANIM_CLIP_VA, hex)
    # Corpus: every upgrade map places marines for that loop to find, and they
    # are all the plain type-0 unarmed marine.  Two maps carry two and the rest
    # three; `upgrade_4` also carries six *dead* alien records, which is what
    # the hit-point test in both iterators is for.
    ck.equal("upgrade.marine_maps", sorted(c.upgrade_marines),
             sorted(set(UPGRADE_MAPS.values())), str)
    ck.check("upgrade.marine_counts",
             all(2 <= len(v) <= 3 for v in c.upgrade_marines.values()),
             str({k: len(v) for k, v in sorted(c.upgrade_marines.items())}))
    ck.equal("upgrade.marine_kinds",
             sorted({(t, w) for v in c.upgrade_marines.values()
                     for t, w, _ in v}), [(0, 0)], str)

    ck.equal("upgrade.tech_bands", b.upgrade_tech_bands(),
             {k: tuple(v) for k, v in UPGRADE_TECH_BANDS.items()}, str)
    arms = b.location_arms()
    for first, second in UPGRADE_SHARED_BODIES:
        ck.equal(f"upgrade.shared_body_{first}_{second}",
                 b._arm_body(arms[first]), b._arm_body(arms[second]), hex)
    ck.equal("upgrade.band_zero_is_a_cleared_register",
             (b.u8(UPGRADE_BAND_ZERO_SITE), b.u8(UPGRADE_BAND_ZERO_SITE + 1)),
             (0x33, 0xDB), str)
    files = {int(s.split("_")[1]) for s in c.headers if s.startswith("upgrade_")}
    ck.equal("upgrade.files", len(files), EXPECTED_UPGRADE_MAPS)
    ck.check("upgrade.files_match_locations",
             files == set(UPGRADE_LOCATIONS),
             f"{sorted(files)}")

    # -- 9. aLocationHandling ------------------------------------------------
    handling = b.location_arms()
    ck.check("handling.index_in_range",
             max(b.u8(HANDLING_INDEX_TABLE + i)
                 for i in range(HANDLING_INDEX_LEN)) == HANDLING_JUMP_LEN - 1,
             f"{HANDLING_INDEX_LEN} index bytes, all < {HANDLING_JUMP_LEN}")
    ck.equal("handling.distinct_arms",
             len({b.u32(HANDLING_JUMP_TABLE + 4 * i)
                  for i in range(HANDLING_JUMP_LEN)}), HANDLING_DISTINCT_ARMS)
    battle_arms = {handling[loc] for loc in BATTLE_LOCATIONS}
    ck.equal("handling.one_battle_arm", len(battle_arms), 1)
    ck.check("handling.battle_arm_calls_mapname",
             b.call_target(next(iter(battle_arms)) + 6) == MAP_NAME,
             f"the battle arm calls aMapName {MAP_NAME:#010x}")
    ck.equal("handling.dialogue", b.dialogue_numbers(), DIALOGUE_LOCATIONS)
    ck.check("handling.default",
             all(handling[loc] == HANDLING_DEFAULT
                 for loc in range(1, HANDLING_INDEX_LEN + 1)
                 if loc not in UPGRADE_LOCATIONS
                 and loc not in DIALOGUE_LOCATIONS
                 and loc not in BATTLE_LOCATIONS),
             "everything else falls through")

    # -- 10. the text banks --------------------------------------------------
    for site, bank, name, zero in TEXT_BANKS:
        named = any(b.u8(va) == 0x68 and b.string(b.u32(va + 1), 60) == name
                    for va in range(site - 24, site))
        if zero is None:
            passed = any(b.u8(va) == 0x6A and b.u8(va + 1) == bank
                         for va in range(site - 24, site))
        else:
            passed = bank == 0 and b.u8(zero) == 0x33 \
                and b.u8(zero + 1) in (0xDB, 0xF6)
        ck.check(f"bank.{name[:-4]}_{bank}_{site:08x}",
                 b.call_target(site) == INIT_TEXT_SYSTEM and named and passed,
                 f"aInitTextSystem({bank}, {name!r}) at {site:#010x}")
    for name in {n for _s, _b, n, _z in TEXT_BANKS}:
        ck.check(f"bank.file_{name[:-4]}",
                 os.path.isfile(os.path.join(root, GUI_TEXT_DIR, name)),
                 os.path.join(GUI_TEXT_DIR, name))

    # -- 11. the starting squad ---------------------------------------------
    ck.equal("squad.campaign2_noop", b.u8(POOL_CAMPAIGN2_SITE + 2),
             POOL_CAMPAIGN2)
    ck.check("squad.seed_calls",
             all(b.call_target(site + 2) == ENLARGE_POOL
                 and b.u8(site) == 0x6A and b.u8(site + 1) == 0
                 for site in POOL_SEED_CALLS),
             f"{len(POOL_SEED_CALLS)} x aEnlargeUnitPool(0)")
    ck.equal("squad.text_bank", b.u8(TEXT_BANK_SITE + 1), TEXT_BANK)
    ck.equal("squad.text_bank_call", b.call_target(TEXT_BANK_SITE + 4),
             TEXT_SET_BANK, hex)
    for index, site in enumerate(SQUAD_NAME_SITES):
        ck.equal(f"squad.name_id{index}", b.u8(site + 1),
                 SQUAD_NAME_IDS[index])
    ck.check("squad.name_lookups",
             len([va for va in b.calls_to(TEXT_GET)
                  if CREATE_POOL <= va < CREATE_POOL + 0x200])
             == len(SQUAD_NAME_SITES),
             f"{len(SQUAD_NAME_SITES)} text lookups inside "
             f"aCreateUnitPoolForCampaign")
    entries = c.text.get(SQUAD_TEXT_FILE, {})
    for index, text_id in enumerate(SQUAD_NAME_IDS):
        ck.equal(f"squad.name{index}", entries.get(text_id),
                 SQUAD_NAMES[index])
    fields = b.squad_fields()
    ck.equal("squad.fields", fields, SQUAD_FIELDS)
    ck.equal("squad.hero_flag", fields.get((0, HERO_FLAG_OFFSET)), HERO_FLAG)
    hero = c.units.get(HERO_UNIT_TYPE)
    ck.equal("squad.hero_type_name",
             strings(hero)[0] if hero else None, HERO_UNIT_NAME)
    medic = c.equipment.get(MEDIC_EQUIPMENT_ID)
    ck.equal("squad.medic_equipment",
             strings(medic)[0] if medic else None, MEDIC_EQUIPMENT_NAME)
    ck.equal("squad.medic_slot",
             fields.get((1, EQUIPMENT_BASE + MEDIC_EQUIPMENT_ID)), 1)

    # -- 12. aEnlargeUnitPool ------------------------------------------------
    ck.equal("recruit.slots", b.u8(ENLARGE_SLOTS_SITE + 2), POOL_SLOTS)
    for site in FREE_SLOT_SITES + USED_SLOT_SITES:
        ck.equal(f"recruit.hp_probe_{site:08x}",
                 b.u32(site + 3) - POOL_BASE, HP_OFFSET, hex)
    ck.equal("recruit.mode_getter",
             b.call_target(ENLARGE_MODE_CMP_SITE - 5), GAME_MODE_GETTER, hex)
    ck.equal("recruit.mode_campaign", b.u8(ENLARGE_MODE_CMP_SITE + 2),
             MODE_CAMPAIGN)
    ck.equal("recruit.rank_call", b.call_target(ENLARGE_RANK_CALL),
             SKILL_LEVEL_GET, hex)
    ck.equal("recruit.rank_global", b.u32(SKILL_LEVEL_GET + 1),
             SKILL_LEVEL_GLOBAL, hex)
    ck.equal("recruit.rank_scale", b.u8(ENLARGE_RANK_SCALE_SITE + 1),
             RANK_SCALE)
    for site, offset in sorted(ENLARGE_STORES.items()):
        ck.equal(f"recruit.store_{offset:#04x}_{site:08x}",
                 b.u32(site + 2) - POOL_BASE, offset, hex)
    ck.equal("recruit.fp_floor", b.u8(ENLARGE_FP_FLOOR_SITE + 2), FP_FLOOR)
    ck.equal("recruit.fp_value", b.u8(ENLARGE_FP_VALUE_SITE + 6), FP_FLOOR)
    ck.equal("recruit.weapon_zero", b.u8(ENLARGE_WEAPON_SITE + 6), 0)
    ck.equal("recruit.candidate_flag", b.u8(ENLARGE_CANDIDATE_SITE + 6),
             POOL_CANDIDATE_FLAG)
    ck.equal("recruit.name", b.string(b.u32(ENLARGE_NAME_SITE + 1), 20),
             ENLARGE_NAME)
    ck.equal("recruit.speech_base", b.u8(SPEECH_BASE_SITE + 1), SPEECH_BASE)
    ck.equal("recruit.speech_span", b.u8(SPEECH_SPAN_SITE + 1), SPEECH_SPAN)
    ck.equal("recruit.speech_call", b.call_target(SPEECH_CALL_SITE),
             RANDOM_ROUTINE, hex)
    for type_id, name in sorted(PLAYER_UNIT_TYPES.items()):
        record = c.units.get(type_id)
        ck.equal(f"recruit.unit_type{type_id}",
                 strings(record)[0] if record else None, name)

    # -- 13. the economy -----------------------------------------------------
    ck.equal("money.array", b.u32(MONEY_GET + 16), MONEY_ARRAY, hex)
    ck.equal("money.cap", b.u32(MONEY_CAP_SITE + 2), MONEY_CAP)
    ck.check("money.spend_refuses_debt",
             b.u8(MONEY_SPEND_GUARD_SITE) == 0x3B
             and b.u8(MONEY_SPEND_GUARD_SITE + 2) == 0x7C,
             "cmp eax, edx; jl -- a purchase never goes negative")
    for site in WEAPON_COST_SITES:
        ck.equal(f"cost.weapon_{site:08x}",
                 b.u32(site + 3) - WEAPON_TABLE, WEAPON_COST_OFFSET, hex)
    ck.equal("cost.equipment", b.u32(EQUIP_COST_SITE + 3) - EQUIP_TABLE,
             EQUIP_COST_OFFSET, hex)
    ck.equal("cost.recruit_reads_weapon0",
             b.u32(RECRUIT_COST_SITE + 1) - WEAPON_TABLE, WEAPON_COST_OFFSET,
             hex)
    ck.equal("cost.recruit_markup", b.u8(RECRUIT_MARKUP_SITE + 2),
             RECRUIT_MARKUP)
    ck.equal("cost.resale_markup", b.u8(RESALE_MARKUP_SITE + 2),
             RECRUIT_MARKUP)
    ck.equal("cost.recruit_spend", b.call_target(RECRUIT_SPEND_SITE),
             MONEY_SPEND, hex)
    ck.equal("cost.recruit_call", b.call_target(RECRUIT_CALL_SITE),
             ENLARGE_POOL, hex)
    weapon0 = c.weapons.get(0)
    price = numbers(weapon0)[15] if weapon0 and len(numbers(weapon0)) > 15 else None
    ck.check("cost.recruit_price", price is not None
             and price + RECRUIT_MARKUP == 60,
             f"weapon 0 costs {price}, a recruit "
             f"{None if price is None else price + RECRUIT_MARKUP}")

    # -- 14. skill and tech level are the campaign's, not the mission's -----
    ck.equal("level.skill_global", b.u32(SKILL_LEVEL_SET + 5),
             SKILL_LEVEL_GLOBAL, hex)
    ck.equal("level.tech_global", b.u32(TECH_LEVEL_SET + 5),
             TECH_LEVEL_GLOBAL, hex)
    ck.equal("level.skill_writers", tuple(b.calls_to(SKILL_LEVEL_SET)),
             SKILL_LEVEL_SETTER_SITES, _hexlist)
    ck.check("level.skill_readers",
             ENLARGE_RANK_CALL in b.calls_to(SKILL_LEVEL_GET),
             "the recruit seeding is the one game-side reader")
    ck.equal("level.tech_writers", tuple(b.calls_to(TECH_LEVEL_SET)),
             TECH_LEVEL_SETTER_SITES, _hexlist)
    # The whole image holds exactly four instruction-level references to the
    # tech-level global: the two init arms and the setter's and getter's own.
    # That is what says a campaign's tech level cannot move -- docs/27 5.2.
    tech_refs = tuple(va for va in b.absolute_refs(TECH_LEVEL_GLOBAL)
                      if b.text_lo <= va < b.text_hi)
    ck.equal("level.tech_global_refs", tech_refs, TECH_LEVEL_GLOBAL_REFS,
             _hexlist)
    ck.equal("level.multiplayer_arm_tech", b.u8(GAME_CONTROL_TECH_MP_SITE + 6),
             GAME_CONTROL_TECH_MP, str)
    ck.equal("level.campaign_arm_tech", b.u8(GAME_CONTROL_TECH_CAMPAIGN_SITE + 6),
             GAME_CONTROL_TECH_CAMPAIGN, str)
    ck.equal("level.campaign_arm_points",
             b.u32(GAME_CONTROL_POINTS_CAMPAIGN_SITE + 6),
             GAME_CONTROL_POINTS_CAMPAIGN, str)
    ck.equal("level.campaign_arm_players",
             b.u8(GAME_CONTROL_PLAYERS_CAMPAIGN_SITE + 6),
             GAME_CONTROL_PLAYERS_CAMPAIGN, str)
    # The catalogue filter -- docs/27 5.2, which this closed.
    ck.equal("catalogue.low_limit_write", b.u8(CATALOGUE_LOW_SITE + 6),
             CATALOGUE_LOW, str)
    ck.equal("catalogue.high_limit_is_tech",
             b.call_target(CATALOGUE_HIGH_CALL_SITE), TECH_LEVEL_GET, hex)
    for name, entry in sorted(CATALOGUE_BUILDERS.items()):
        step_site, name_site, stride, offset = entry
        # `sub edi, imm8` -- the record stride the iterator steps back by.
        ck.equal(f"catalogue.{name}_stride", b.u8(step_site + 2), stride, str)
        # `lea eax, [edi - imm8]` -- where the name it compares against "" is.
        ck.equal(f"catalogue.{name}_name_offset",
                 -b.i8(name_site + 2), offset, str)
        # ...and that "" is a `.bss` buffer, so it really is empty.
        # The `mov esi, imm32` immediately before it names that buffer.
        ck.equal(f"catalogue.{name}_empty_string",
                 b.u32(name_site - 4), CATALOGUE_EMPTY_STRING, hex)
    for name, (site, base, stride, bound) in sorted(CATALOGUE_BOUNDS.items()):
        ck.equal(f"catalogue.{name}_id_bound",
                 (b.u32(site + 2) - base) // stride, bound, str)
        ck.equal(f"catalogue.{name}_bound_is_aligned",
                 (b.u32(site + 2) - base) % stride, 0, str)
    for name, site in sorted(CATALOGUE_WRAP_SITES.items()):
        ck.equal(f"catalogue.{name}_wraps_from", b.u8(site + 1),
                 CATALOGUE_WRAP_FROM, str)

    # The shared *Buy Item* / *Undo* position -- docs/27 section 5.3. The
    # swap is per catalogue row, not per visit, and these are what say so.
    for name, sites in sorted(ITEM_WINDOW_REFRESH_CALLERS.items()):
        for site in sites:
            ck.equal(f"action.{name}_refresh_call_{site:08x}",
                     b.call_target(site), ITEM_WINDOW_REFRESH[name], hex)
    for name, (buy, undo) in sorted(ITEM_WINDOW_GATE_PASSES.items()):
        ck.equal(f"action.{name}_gate_enables_buy",
                 (b.u8(buy + 1), b.call_target(buy + 2)),
                 (BUY_GADGET, GADGET_ENABLE), str)
        ck.equal(f"action.{name}_gate_disables_undo",
                 (b.u8(undo + 1), b.call_target(undo + 2)),
                 (UNDO_GADGET, GADGET_DISABLE), str)
    for (name, test), (site, base, offset) in sorted(
            ITEM_WINDOW_GATE_READS.items()):
        ck.equal(f"action.{name}_gate_reads_{test}", b.u32(site + 3) - base,
                 offset, hex)
    for site, writer in sorted(UNDO_GADGET_WRITERS.items()):
        ck.equal(f"action.undo_gadget_{site:08x}",
                 (b.u8(site + 1), b.call_target(site + 2)),
                 (UNDO_GADGET, writer), str)
    ck.equal("action.item_list_column_step",
             b.u32(ITEM_LIST_COLUMN_STEP_SITE + 2), ITEM_LIST_COLUMN_STEP, str)
    ck.equal("action.item_list_column_wrap",
             b.u32(ITEM_LIST_COLUMN_WRAP_SITE + 2), ITEM_LIST_COLUMN_WRAP, str)
    ck.equal("action.item_list_row_step",
             b.u8(ITEM_LIST_ROW_STEP_SITE + 2), ITEM_LIST_ROW_STEP, str)

    for number, site in sorted(GAME_CONTROL_FIRST_MISSION_SITES.items()):
        ck.equal(f"level.campaign_{number}_first_mission",
                 b.string(b.u32(site + 1)), CAMPAIGN_FIRST_MISSION[number])
    skills = {h["skill"] for h in c.headers.values()}
    techs = {h["tech"] for h in c.headers.values()}
    ck.check("level.skill_range", max(skills) <= 12,
             f"skill levels observed: {sorted(skills)}")
    ck.check("level.tech_range", max(techs) <= 12,
             f"tech levels observed: {sorted(techs)}")

    # -- 15. the mission-end payout -----------------------------------------
    ck.equal("payout.scores", tuple(b.payout_scores()), PAYOUT_SCORES)
    ck.equal("payout.end_state_array", b.u32(END_STATE_GETTER + 0x1E),
             END_STATE_ARRAY, hex)
    ck.equal("payout.scoreboard_cursor", b.u32(SCOREBOARD_CURSOR_SITE + 1),
             SCOREBOARD_BASE + 8, hex)
    ck.equal("payout.out_of_game", b.u8(END_STATE_GATE_SITE + 2),
             END_STATE_OUT)
    for slot, site in sorted(PAYOUT_SLOT_SITES.items()):
        ck.equal(f"payout.slot{slot}", b.u8(site + 1), slot)
        ck.equal(f"payout.slot{slot}_call", b.call_target(site + 2),
                 GAME_CONTROL_SLOT_GET, hex)
    ck.equal("payout.base_gate", b.call_target(0x0043BAAF),
             SKIP_RULE_GATE, hex)
    ck.equal("payout.difficulty", b.call_target(0x0043BAC8),
             DIFFICULTY_GETTER, hex)
    ck.equal("payout.difficulty_global", b.u32(DIFFICULTY_GETTER + 0x1E),
             DIFFICULTY_GLOBAL, hex)
    ck.check("payout.multipliers",
             tuple(b.u32(va + 1) for va in (0x0043BAE6, 0x0043BADF, 0x0043BAD8))
             == DIFFICULTY_MULTIPLIERS,
             f"{DIFFICULTY_MULTIPLIERS}")
    ck.check("payout.one_caller", b.calls_to(PAYOUT) == [0x0045D48D],
             "the debriefing screen is the only caller")

    # -- 15.1 who writes the mission result ---------------------------------
    ck.equal("result.reset_target", b.u32(RESULT_RESET_SITE + 2),
             END_STATE_ARRAY, hex)
    ck.equal("result.reset_value", b.u32(RESULT_RESET_SITE + 6),
             RESULT_RESET_VALUE)
    ck.equal("result.setter_target", b.u32(MISSION_RESULT_SET + 0x22),
             END_STATE_ARRAY, hex)
    #: the stamp is gated on a short-circuit OR over *all five* outcome slots,
    #: not on slot 4 alone -- slot 4 is merely the last one tested.
    for slot, site in enumerate(OUTCOME_PROBE_SITES):
        ck.check(f"result.outcome_probe{slot}",
                 b.u8(site) == 0x6A and b.u8(site + 1) == slot
                 and b.call_target(site + 2) == GAME_CONTROL_SLOT_GET,
                 f"LCL slot {slot} tested at {site:#010x}")
    ck.equal("result.defeat_slot", b.u8(DEFEAT_SLOT_SITE + 1), DEFEAT_SLOT)
    ck.equal("result.defeat_slot_call", b.call_target(DEFEAT_SLOT_SITE + 2),
             GAME_CONTROL_SLOT_GET, hex)
    for player, site in enumerate(DEFEAT_SITES):
        ck.check(f"result.defeat{player}",
                 b.u8(site) == 0x6A and b.u8(site + 1) == DEFEAT_RESULT
                 and b.u8(site + 2) == 0x6A and b.u8(site + 3) == player
                 and b.call_target(site + 4) == MISSION_RESULT_SET,
                 f"aSetMissionResult({player}, {DEFEAT_RESULT})")
    ck.equal("result.grade_nothing", b.u32(RESULT_JUMP_TABLE),
             RESULT_NOTHING_ARM, hex)
    for value, (site, result) in sorted(RESULT_GRADE_ARMS.items()):
        ck.check(f"result.grade{value}",
                 b.u32(RESULT_JUMP_TABLE + 4 * value) == site
                 and b.u8(site) == 0x6A and b.u8(site + 1) == result
                 and b.call_target(site + 3) == MISSION_RESULT_SET,
                 f"LCL slot value {value} -> mission result {result}")

    # -- 15.2 the hand-over's other stamp: the rotation ran out --------------
    ck.equal("rotation.advance_call", b.call_target(ROTATION_FAIL_CALL),
             ADVANCE_PLAYER, hex)
    ck.equal("rotation.search_first_call", b.call_target(SEARCH_FIRST_CALL),
             SEARCH_FIRST_PLAYER, hex)
    ck.check("rotation.shared_block",
             b.u8(SEARCH_FAIL_SITE) == 0x0F
             and b.u8(SEARCH_FAIL_SITE + 1) == 0x84
             and SEARCH_FAIL_SITE + 6 + b.i32(SEARCH_FAIL_SITE + 2)
             == ROTATION_FAIL_BLOCK
             and ROTATION_FAIL_SITES[0] - 4 == ROTATION_FAIL_BLOCK,
             "both exits jump into the same four-stamp block")
    for player, site in enumerate(ROTATION_FAIL_SITES):
        ck.check(f"rotation.stamp{player}",
                 b.u8(site - 4) == 0x6A and b.u8(site - 3) == DEFEAT_RESULT
                 and b.u8(site - 2) == 0x6A and b.u8(site - 1) == player
                 and b.call_target(site) == MISSION_RESULT_SET,
                 f"setMissionResult({player}, {DEFEAT_RESULT})")

    # -- 15.3 the in-battle command dispatcher ------------------------------
    ck.equal("battle.command_table",
             tuple(b.u32(COMMAND_TABLE + 4 * i) for i in range(COMMAND_COUNT))
             [:2],
             (0x0041DDE7, GIVE_UP_ARM), _hexlist)
    ck.equal("battle.give_up_humans", b.u8(GIVE_UP_HUMANS_SITE + 2), 1)
    ck.equal("battle.give_up_gate", b.call_target(GIVE_UP_ARM + 0x0A),
             SKIP_RULE_GATE, hex)
    ck.check("battle.give_up_stamp",
             b.u8(GIVE_UP_SITE) == 0x6A
             and b.u8(GIVE_UP_SITE + 1) == DEFEAT_RESULT
             and b.call_target(GIVE_UP_SITE + 3) == MISSION_RESULT_SET,
             f"giving up stamps result {DEFEAT_RESULT}")
    ck.equal("battle.end_turn_modes",
             tuple(b.u32(END_TURN_MODE_TABLE + 4 * i) for i in range(4)),
             END_TURN_MODE_ARMS, _hexlist)
    ck.equal("battle.wipeout_units", b.call_target(LIVING_UNITS_SITE),
             LIVING_UNITS, hex)
    ck.equal("battle.wipeout_turn", b.call_target(TURN_COUNTER_SITE),
             TURN_COUNTER_GET, hex)
    ck.check("battle.wipeout_stamp",
             b.u8(WIPEOUT_SITE) == 0x6A
             and b.u8(WIPEOUT_SITE + 1) == DEFEAT_RESULT
             and b.call_target(WIPEOUT_SITE + 0x0D) == MISSION_RESULT_SET,
             f"a wiped-out player gets result {DEFEAT_RESULT}")

    # -- 15.4 the whole setter sweep, classified ----------------------------
    sites = b.calls_to(MISSION_RESULT_SET)
    ck.equal("result.sites", len(sites), RESULT_SITE_COUNT)
    classified = (set(CAMPAIGN_RESULT_SITES) | set(NETWORK_ONLY_SITES)
                  | set(PBM_ONLY_SITES)
                  | {s for pair in MULTIPLAYER_PAIRS for s in pair})
    ck.equal("result.classified", sorted(set(sites)), sorted(classified),
             lambda v: f"{len(v)} sites")
    #: what is left once the multiplayer, network-only and PBM sites are taken
    #: out is the set a campaign can reach.
    reachable = sorted(set(sites) - set(NETWORK_ONLY_SITES)
                       - set(PBM_ONLY_SITES)
                       - {s for pair in MULTIPLAYER_PAIRS for s in pair})
    ck.equal("result.campaign_sites", reachable,
             sorted(CAMPAIGN_RESULT_SITES), lambda v: f"{len(v)} sites")
    for first, second in MULTIPLAYER_PAIRS:
        between = [va for va in range(first, second)
                   if b.call_target(va) == MULTIPLAYER_RESULT]
        ck.check(f"result.mp_pair_{first:08x}", len(between) == 1,
                 f"{first:#010x} .. {second:#010x} brackets one call to "
                 f"aMultiPlayer's scorer {MULTIPLAYER_RESULT:#010x}")
    for first, site in sorted(MP_HUMAN_GUARDS.items()):
        ck.check(f"result.mp_human_guard_{first:08x}",
                 b.u8(site) == 0x83 and b.u8(site + 1) == 0xF8
                 and b.u8(site + 2) == 1
                 and b.call_target(site - 5) == HUMAN_COUNT,
                 f"the arm holding {first:#010x} is skipped when "
                 f"humanCount() == 1")
    for first in MP_DPLAY_PAIRS:
        near = [va for va in range(first - MP_DPLAY_WINDOW, first)
                if DPLAY_LO <= (b.call_target(va) or 0) < DPLAY_HI]
        ck.check(f"result.mp_dplay_{first:08x}", len(near) == 1,
                 f"one aDPlay.cpp call in the {MP_DPLAY_WINDOW} bytes before "
                 f"{first:#010x}")
    ck.check("result.mp_flag_writers",
             sorted(va for va in b.absolute_refs(MP_FLAG)
                    if b.text_lo <= va < b.text_hi)
             == sorted([MP_FLAG_INIT_SITE + 1, MP_FLAG_SET_SITE + 2]
                       + list(MP_FLAG_ACCESSOR_SITES)),
             "one initialiser, one writer, one accessor pair")
    ck.check("result.mp_flag_is_network",
             b.text_lo <= MP_FLAG_SET_SITE < b.text_hi
             and DPLAY_LO <= (b.call_target(MP_DISPATCHER_RECV) or 0) < DPLAY_HI,
             "the only writer is inside the DirectPlay message dispatcher")
    ck.check("result.network_only_gate",
             b.call_target(0x00454BDE) == 0x00481A60
             and all(b.u8(s - 4) == 0x6A and b.u8(s - 3) == DEFEAT_RESULT
                     for s in NETWORK_ONLY_SITES[1:]),
             f"the {len(NETWORK_ONLY_SITES)} aMissionControl.cpp stamps sit "
             f"behind that flag")

    # -- 16. what a mission hands back --------------------------------------
    ck.equal("end.transfer_call", b.call_target(MISSION_END_TRANSFER_SITE),
             TRANSFER_ALL, hex)
    ck.equal("end.transfer_mode_getter",
             b.call_target(MISSION_END_TRANSFER_SITE - 12), GAME_MODE_GETTER,
             hex)
    ck.equal("end.transfer_mode", b.u8(MISSION_END_TRANSFER_SITE - 5),
             MODE_CAMPAIGN)
    ck.check("end.transfer_one_caller",
             b.calls_to(TRANSFER_ALL) == [MISSION_END_TRANSFER_SITE],
             "aTransferAllUnitsFromMapToPool has exactly one caller")
    ck.equal("end.survive_gate", b.u8(SURVIVE_GATE_SITE + 2), HERO_FLAG_OFFSET)
    ck.equal("end.owner_gate", b.u8(OWNER_GATE_SITE + 2), OWNER_OFFSET)
    ck.equal("end.copy_len", b.u32(COPY_POOL_LEN_SITE + 1), COPY_POOL_DWORDS)
    ck.check("end.copy_tail",
             b.u8(COPY_POOL_LEN_SITE + 5) == 0xF3
             and b.u8(COPY_POOL_LEN_SITE + 6) == 0xA5
             and b.u8(COPY_POOL_LEN_SITE + 7) == 0x66
             and b.u8(COPY_POOL_LEN_SITE + 8) == 0xA5
             and COPY_POOL_DWORDS * 4 + 2 == POOL_SLOTS * POOL_STRIDE,
             f"rep movsd + movsw = {POOL_SLOTS * POOL_STRIDE} bytes")
    ck.check("end.copy_entry",
             b.call_target(COPY_POOL_ENTRY_SITE) == COPY_POOL
             and b.u8(COPY_POOL_ENTRY_SITE - 4) == 0x6A
             and b.u8(COPY_POOL_ENTRY_SITE - 3) == 1
             and b.u8(COPY_POOL_ENTRY_SITE - 2) == 0x6A
             and b.u8(COPY_POOL_ENTRY_SITE - 1) == 0,
             "aCopyUnitPool(0, 1) on the way in")
    ck.check("end.copy_exit",
             b.call_target(COPY_POOL_EXIT_SITE) == COPY_POOL
             and b.u8(COPY_POOL_EXIT_SITE - 4) == 0x6A
             and b.u8(COPY_POOL_EXIT_SITE - 3) == 0
             and b.u8(COPY_POOL_EXIT_SITE - 2) == 0x6A
             and b.u8(COPY_POOL_EXIT_SITE - 1) == 1,
             "aCopyUnitPool(1, 0) on the way out")
    ck.check("end.copy_two_callers",
             sorted(b.calls_to(COPY_POOL)) ==
             [COPY_POOL_ENTRY_SITE, COPY_POOL_EXIT_SITE],
             "the working row is copied in exactly two places")
    ck.equal("end.next_map_call", b.call_target(NEXT_MAP_HEADER_CALL),
             HEADER_BASE_GETTER, hex)
    ck.equal("end.next_map_buffer", b.call_target(NEXT_MAP_HEADER_CALL + 7),
             MAP_NAME_BUFFER_GETTER, hex)
    ck.check("end.debrief_gadgets",
             tuple(b.u32(DEBRIEF_GADGETS + 4 * i)
                   for i in range(DEBRIEF_GADGET_COUNT))
             == (0x0045E95F, NEXT_MAP_ARM, POOL_WRITEBACK_ARM, 0x0045EA11),
             f"{DEBRIEF_GADGET_COUNT} buttons")
    ck.equal("end.max_tp_value", b.u8(POOL_MAX_TP_SITE + 2), POOL_MAX_TP_VALUE)
    ck.check("end.sort_key",
             b.u8(POOL_SORT_KEY_SITE) == 0x8A
             and b.i8(POOL_SORT_KEY_SITE + 2) == -POOL_STRIDE,
             "the roster sort compares adjacent records")

    # -- 17. the chain -------------------------------------------------------
    chained = {stem: h["next"] for stem, h in c.headers.items() if h["next"]}
    dangling = sorted((s, n) for s, n in chained.items()
                      if n.upper() not in stems)
    ck.check("chain.next_map_resolves", not dangling,
             f"{len(chained)} headers name a next map, all shipped")
    ck.equal("chain.script_calls", len(c.next_map_calls),
             EXPECTED_NEXT_MAP_CALLS)
    unresolved = sorted({n for _s, n in c.next_map_calls
                         if n.upper() not in stems})
    ck.check("chain.script_calls_resolve", not unresolved,
             f"{len(c.next_map_calls)} EnterNameOfNextMap arguments, all shipped")
    ck.check("chain.ids_unique",
             len(campaign) == sum(1 for h in c.headers.values()
                                  if h["type"] == MAP_TYPE_CAMPAIGN),
             "no two campaign missions share a mission id")
    ck.check("chain.own_name",
             all(h["name"].upper() == stem.upper()
                 for stem, h in c.headers.items() if h["name"]),
             "every header's own-name field matches its filename")
    check_screen_camera(ck, b)
    check_camera_presets(ck, b)
    check_upgrade_purchase(ck, b)
    check_screen_rotation(ck, b)
    check_projection(ck, b)

    ck.check("chain.last_mission",
             chained.get(MAP_NAME_ORPHAN[0]) is None,
             f"{MAP_NAME_ORPHAN[0]} names no successor")

    return ck


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

def report_locations(root: str) -> None:
    b = Binary(root)
    c = Corpus(root)
    labels = c.text.get(CAMPAIGN_LCL, {})
    names = b.map_names()
    print("mission  map       location  unlocks")
    for mission, pairs in sorted(b.location_map().items()):
        location = mission + LOCATION_BIAS
        if pairs is None:
            print(f"{mission:7d}  {'-':9s} {location:8d}  (unknown missionid)")
            continue
        opened = ", ".join(
            f"{loc} {labels.get(loc, '?')!r}" for loc, _f in sorted(pairs))
        print(f"{mission:7d}  {names.get(location, '-'):9s} {location:8d}  "
              f"{opened}")


def tables_document(root: str) -> dict:
    """The decoded tables, as the JSON document ``--json`` prints.

    Split out of :func:`report_json` so the converter and
    ``campaign_runtime.py`` read the same tables through the same code rather
    than each re-deriving them from the binary.
    """
    b = Binary(root)
    graph = {str(k): (None if v is None else [list(p) for p in v])
             for k, v in b.location_map().items()}
    return {
        "location_bias": LOCATION_BIAS,
        "map_names": {str(k): v for k, v in b.map_names().items()},
        "unlock_graph": graph,
        "dialogue": {str(k): v for k, v in b.dialogue_numbers().items()},
        "upgrade": {str(k): v for k, v in b.upgrade_arms().items()},
        "tech_bands": {str(k): list(v)
                       for k, v in b.upgrade_tech_bands().items()},
        "squad_fields": {f"{r}:{o:#04x}": v
                         for (r, o), v in sorted(b.squad_fields().items())},
        "payout_scores": b.payout_scores(),
    }


def report_json(root: str) -> None:
    print(json.dumps(tables_document(root), indent=2))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", metavar="ROOT",
                        help="verify docs/27 against ROOT")
    parser.add_argument("--locations", metavar="ROOT",
                        help="print the campaign unlock graph")
    parser.add_argument("--json", metavar="ROOT",
                        help="dump the decoded tables as JSON")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if args.locations:
        report_locations(args.locations)
        return 0
    if args.json:
        report_json(args.json)
        return 0
    if not args.check:
        parser.error("one of --check, --locations, --json is required")

    ck = run_checks(args.check)
    total = ck.passed + ck.failed
    if ck.failed:
        LOG.error("%d/%d checks failed", ck.failed, total)
        return 1
    LOG.info("%d/%d checks passed", ck.passed, total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
