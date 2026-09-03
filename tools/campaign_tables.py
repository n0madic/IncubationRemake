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
