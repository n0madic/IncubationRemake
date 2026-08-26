#!/usr/bin/env python3
"""Verify the effect and sound layers described in ``docs/28`` against the
binary and the corpus.

Two subsystems, one trigger point:

**Sound** (``aDSound.cpp`` + the three ``aAnimations.cpp`` wrappers).  Twenty
DirectSound buffers, a 121-entry volume-control table filled from ``Info.lcl``,
and one idiom -- load a named wave into a free slot, play it, kill the slot.
Every wave the engine names is pinned to its call site here, together with the
volume-control id that scales it, and every name is required to resolve against
the shipped ``Waves/`` directory.

**Blobs** (``aBlobs.cpp``).  Four hundred and fifty 88-byte records, one
fifteen-argument constructor and a 78-arm update switch.  A record is an Eng3d
``object_3d`` with eight fields bolted on, which is checked against the
world-object builder that shares the same 64-byte layout.  The 116 constructor
calls are pinned with the model, class, kind and lifetime each passes; the 30
models are required to resolve against the shipped ``prototyp.dir`` indices;
and the 54 sprite calls are pinned with the atlas row, column and size they
give the one 256x256 texture -- ``anim``, an 8x8 grid of 32x32 tiles -- that
every model-less blob is drawn from.

**The kinds.**  Each of the 78 update kinds is tied to the creators that pass
it, its spawn list is decoded from its arm, and the two calls that compute a
kind, the one arm that rewrites its own and the eleven kinds no call can reach
are all pinned.

**The join.**  Three compiler-generated switches inside ``aPlayFightAnimation``
map a weapon id to its muzzle blob, its impact blob and its impact sound.  Those
three tables are what a remake needs in order to make a shot look and sound
right, and they are read out of the compiler's own index and jump tables rather
than inferred.

Every check fails on an empty corpus: a check that examined nothing is not a
check that passed.

Usage::

    python3 tools/blob_tables.py --check gog_incubation
    python3 tools/blob_tables.py --waves gog_incubation
    python3 tools/blob_tables.py --blobs gog_incubation
    python3 tools/blob_tables.py --kinds gog_incubation
    python3 tools/blob_tables.py --json  gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import bisect
import struct
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lcl_parse  # noqa: E402
import cho_parse  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402
from inclib.visn import parse_header  # noqa: E402
from inclib import lev as levlib  # noqa: E402
from inclib import prototyp  # noqa: E402

LOG = logging.getLogger("blob_tables")

GAME_EXE = "Incubation.exe"
WAVES_DIR = "Waves"
SPEECH_DIR = os.path.join("Waves", "Speech")
BRIEFING_DIR = "Briefing"
INFO_LCL = os.path.join("DATA", "Info.lcl")

# -- aDSound.cpp: the DirectSound wrapper ---------------------------------

DSOUND_LOAD = 0x00436B60
DSOUND_PLAY = 0x00436EF0
DSOUND_SET = 0x00436FD0
DSOUND_KILL = 0x004370D0
DSOUND_FILL = 0x00437350

BUFFER_TABLE = 0x0050491C
BUFFER_STRIDE = 152
BUFFER_NAME = 0x04          # the wave's path, copied into the record
BUFFER_IFACE = 0x68         # LPDIRECTSOUNDBUFFER
BUFFER_DESC = 0x6C          # DSBUFFERDESC: dwSize then dwFlags
BUFFER_FREQ = 0x88
BUFFER_VOLUME = 0x8C
BUFFER_PAN = 0x90

# `cmp cl, 0x14` / `cmp eax, 0x13` / `cmp eax, 0x14` -- the three slot bounds.
LOAD_BOUND_SITE = 0x00436B8A
LOAD_BOUND = 0x14
PLAY_BOUND_SITE = 0x00436F0E
PLAY_BOUND = 0x13
SET_BOUND_SITE = 0x00436FEB
SET_BOUND = 0x14
KILL_BOUND_SITE = 0x004370EA
KILL_BOUND = 0x14

DESC_SIZE_SITE = 0x00436D4B
DESC_SIZE = 0x14
DESC_FLAGS_SITE = 0x00436D51
DESC_FLAGS = 0xE2

# aAnimations.cpp forwards to all three.
ANIM_LOAD = 0x004176C0
ANIM_PLAY = 0x00417710
ANIM_KILL = 0x00417750
ANIM_FORWARD = {ANIM_LOAD: (0x004176D9, DSOUND_LOAD),
                ANIM_PLAY: (0x0041771A, DSOUND_PLAY),
                ANIM_KILL: (0x00417755, DSOUND_KILL)}
ANIM_LOAD_SITES = 62
ANIM_PLAY_SITES = 58
ANIM_KILL_SITES = 55
DIRECT_LOAD_SITES = 17

# -- the volume-control table ---------------------------------------------

VOLUME_TABLE = 0x00504638
VOLUME_SETTER = 0x00437500
VOLUME_SETTER_BOUND_SITE = 0x00437508
VOLUME_SCALE = 0x00437480
VOLUME_SCALE_BOUND_SITE = 0x0043749C
VOLUME_BOUND = 0x78                 # `cmp eax, 0x78` in both, inclusive
VOLUME_LOAD_BOUND_SITE = 0x00436E86  # `cmp eax, 0x78` -- but `jge` rejects
VOLUME_FLOOR_SITE = 0x00437485
VOLUME_FLOOR = -2000                # base volume below this is silence
VOLUME_SILENCE_SITE = 0x0043748D
VOLUME_SILENCE = -10000
VOLUME_MUL_SITE = 0x004374B6        # `shl ecx, 4` after two `*5` and one `*5`
VOLUME_OFFSET_SITE = 0x004374C5     # `lea eax, [edx + esi - 0x7d0]`
VOLUME_OFFSET = -0x7D0              # = -2000
VOLUME_PER_PERCENT = 20             # 2000/100 hundredths of a dB
FX_VOLUME_GETTER = 0x00460440       # docs/20 sec.8: options record +0x0C
FX_VOLUME_GLOBAL = 0x005129E4

INFO_VOLUME_IDS = 103               # SetVolumeCtrl 0..102 in Info.lcl
INFO_VOLUME_SPECIAL = {62: 50, 90: 80, 91: 50, 92: 50, 93: 50, 96: 70, 102: 101}
WEAPON_VOLUME_BAND = 50             # ids 0..49 are "see weapons"
VOLUME_IDS_UNUSED = (53, 54, 55)    # defined in Info.lcl, named by no call site

# -- path building ---------------------------------------------------------

PATH_BUILDER = 0x004632B0
PATH_FORMAT = "%s%s"
PATH_FORMAT_SITE = 0x004632C3
WAVES_DIR_ID = 8

# -- aPlayFightAnimation: the weapon's own sound --------------------------

FIGHT = 0x0040BD70
WEAPON_TABLE = 0x0051B2C0
WEAPON_STRIDE = 0x43
WEAPON_WAVE_OFFSET = 0x25
WEAPON_WAVE_SITE = 0x0040C7C4        # lea eax, [edi + edx*2 + 0x51B2E5]
WEAPON_WAVE_OPERAND = WEAPON_TABLE + WEAPON_WAVE_OFFSET
WEAPON_WAVE_FORMAT = "%s.wav"
WEAPON_WAVE_FORMAT_SITE = 0x0040C7CC
WEAPON_WAVE_VOLUME_SITE = 0x0040C7D7  # `push edi` -- the weapon id itself
INFO_WEAPONS = 41              # SetWeaponInfo records in the shipped Info.lcl
INFO_WEAPON_WAVES = 42         # SetWeaponInfo2 records -- one more than that
WEAPON_TABLE_SLOTS = 50
WEAPON_WAVE_TYPO = (35,)       # "W_BAY0_0": a zero for the letter O, and no
                               # SetWeaponInfo ever created record 35

# the three weapon switches, as (index table, entries, jump table, first id)
MUZZLE_SWITCH = (0x0040E5A4, 0x2E, 0x0040E524, 2)
IMPACT_SWITCH = (0x0040E614, 0x28, 0x0040E5D4, 7)
IMPACT_SOUND_SWITCH = (0x0040E4F4, 0x2D, 0x0040E4C8, 0)
MUZZLE_BOUND_SITE = 0x0040CC46
IMPACT_BOUND_SITE = 0x0040D4E2
IMPACT_SOUND_BOUND_SITE = 0x0040C81B

# -- the pain voice --------------------------------------------------------

SPECIES_OFFSET = 0x79                # SetUnitInfo record, docs/21 sec.5
UNIT_INFO_TABLE = 0x0051C020
UNIT_INFO_STRIDE = 0x7E
UNIT_TYPE_OFFSET = 0x4C              # unit record, docs/21 sec.7
VOICE_SPECIES_SITE = 0x0040CAC5      # mov al, [edx*2 + 0x51C099]
VOICE_SPECIES_OPERAND = UNIT_INFO_TABLE + SPECIES_OFFSET
VOICE_CURSOR_HUMAN = 0x004FC018
VOICE_CURSOR_ALIEN = 0x004FC01C

# -- aStartWalkAnimationSound ---------------------------------------------

WALK_START = 0x0040E640
WALK_STOP = 0x0040E9E0
WALK_TYPE_SITE = 0x0040E666          # mov cl, [eax + 0x4C]
WALK_BOUND_SITE = 0x0040E66B
WALK_BOUND = 0x44
WALK_INDEX_TABLE = 0x0040E938
WALK_JUMP_TABLE = 0x0040E8F4
WALK_PERIOD_GLOBAL = 0x004FAECC
WALK_SILENT_ARM = 0x0040E8CC

# -- aAmbience.cpp: present, and never fed --------------------------------

AMBIENCE_INIT = 0x0040B3F0
AMBIENCE_FREE = 0x0040B470
AMBIENCE_SLOTS = (0x004FAE60, 0x004FAE64, 0x004FAE68, 0x004FAE6C, 0x004FAE70)
AMBIENCE_STUB_SITE = 0x0040B439
AMBIENCE_STUB = 0x0042C490           # `mov eax, 1; ret`, COMDAT-folded
AMBIENCE_FILES = ("amb_a_0.wav", "amb_a_1.wav", "amb_a_2.wav", "amb_a_3.wav",
                  "amb_a_4.wav", "amb_b_0.wav", "amb_b_1.wav", "amb_b_2.wav",
                  "amb_b_3.wav", "amb_b_4.wav")

# -- speech, briefing, music ----------------------------------------------

SPEECH_FORMAT = "%sSpeech\\%s\\%s%02d%02d.wav"
SPEECH_FORMAT_SITES = (0x0047BB12, 0x0047BB4F)
SPEECH_SUBDIRS = ("1", "2", "3", "4", "5", "6", "7", "8", "9", "A")
BRIEFING_FORMAT = "%smb%daif.wav"
BRIEFING_FORMAT_SITES = (0x00456E6F, 0x00456E92)
EXTRO_FORMAT = "%sextro.wav"
EXTRO_FORMAT_SITE = 0x004574B6
CD_VOLUME = 0x0042C330
CD_DEVICE = "cdaudio"
CD_DEVICE_SITE = 0x0042BDDE

# -- aBlobs.cpp: the pool --------------------------------------------------

BLOB_INIT = 0x0041DE40
BLOB_KILL = 0x0041DE90
BLOB_DELETE_ALL = 0x0041E370
BLOB_UPDATE = 0x0041E500
BLOB_CTOR = 0x00420950
BLOB_HANDLE = 0x004FE638
BLOB_LABEL = "aInitBlobObjects (Blob-Objects-CLONELIST)"
BLOB_LABEL_SITE = 0x0041DE40
BLOB_BYTES_SITE = 0x0041DE45
BLOB_BYTES = 0x9B08
BLOB_SLOTS = 450
BLOB_STRIDE = 0x58
BLOB_SLOTS_SITES = (0x0041E39C, 0x0042097D)
BLOB_STRIDE_SITES = (0x0041E398, 0x00420979)
BLOB_NAME_SCRATCH = 0x004FA524       # the buffer classes 2 and 3 pass and ignore

# constructor argument -> record offset, taken from the stores themselves
BLOB_CTOR_STORES = {
    0x004209CE: (3, 0x14), 0x004209D5: (4, 0x18), 0x004209E4: (5, 0x1C),
    0x004209EC: (6, 0x24), 0x004209FC: (7, 0x26), 0x00420A04: (8, 0x28),
    0x004209F5: (9, 0x44), 0x00420A2E: (10, 0x45), 0x00420A13: (11, 0x48),
    0x00420A1A: (12, 0x4C), 0x00420A0C: (13, 0x50), 0x00420A2B: (14, 0x54),
    0x00420A21: (15, 0x55), 0x00420A31: (2, 0x56), 0x004209DD: (1, 0x0C),
}
BLOB_CTOR_GUARD_SITE = 0x00420950     # mov al, [esp+0x28] -- arg10 must be set
BLOB_CTOR_MODELLESS = (2, 3)
BLOB_CTOR_MODELLESS_SITES = (0x00420991, 0x00420996)
BLOB_LOOKUP = 0x004038F0
BLOB_LOOKUP_SITE = 0x004209A0
BLOB_LOOKUP_TEST_SITE = 0x004209A8      # cmp eax, -1 / jne -- otherwise it bails
BLOB_LOOKUP_ERROR_SITE = 0x004209AE
BLOB_LOOKUP_ERROR = "unknown object!\n'%s'" 

BLOB_DELETE = 0x0041E320
BLOB_DELAY = 0x55
BLOB_LIFE = 0x45
BLOB_KIND = 0x44
BLOB_PHASE = 0x54
BLOB_CLASS = 0x56
BLOB_IMMORTAL = 0xFF
BLOB_IMMORTAL_SITE = 0x0041E53C
BLOB_DELAY_SITE = 0x0041E50D
BLOB_LIFE_SITE = 0x0041E526
BLOB_KIND_SITE = 0x0041E547
BLOB_KIND_BOUND_SITE = 0x0041E54A
BLOB_KIND_BOUND = 0x4D
BLOB_UPDATE_TABLE = 0x00420814
BLOB_UPDATE_ENTRIES = 0x4E
BLOB_UPDATE_DEFAULT = 0x00420805
BLOB_GRAVITY_HIGH_SITE = 0x0041E5DA
BLOB_GRAVITY_HIGH = -0x280
BLOB_GRAVITY_LOW_SITE = 0x0041E5E1
BLOB_GRAVITY_LOW = -0x20
BLOB_GRAVITY_SPLIT_SITE = 0x0041E5CF
BLOB_GRAVITY_SPLIT = 0x0A

BLOB_CREATORS = 81
BLOB_CTOR_CALLS = 116
BLOB_FOREIGN_CALLERS = {0x00473942: "aUI.cpp", 0x0046D85F: "aTacTools.cpp"}
BLOB_MODEL_WORLDS = 9
BLOB_MODELS_EVERYWHERE = 26
BLOB_MODELS_RARE = {"A_PARAB1.3DI": ("World_E00", "World_F00"),
                    "A_SPOTL.3DI": ("World_E00",),
                    "L049EE00.3DI": ("World_E00",),
                    "L069EE00.3DI": ("World_E00",)}

# -- CreateBGB: the LCL emitter, docs/20 sec.7.3 --------------------------

BGB_ENTER = 0x0041DF10
BGB_LCL = 0x004425F0
BGB_TABLE = 0x004FE408
BGB_SLOTS = 20
BGB_STRIDE = 28
BGB_TYPE_BOUND_SITE = 0x0041DFA7
BGB_TYPE_BOUND = 6
BGB_JUMP_TABLE = 0x0041E120
BGB_TICK = 0x0041E1A0
BGB_TICK_BOUND_SITE = 0x0041E24E
BGB_TICK_JUMP_TABLE = 0x0041E300

# -- .cha note callbacks: exactly one kind is ever registered -------------

NOTE_CALLBACK_REGISTER = 0x0042C5D0
NOTE_CALLBACK_SITE = 0x00405B54

# -- values the checks compare against, measured once ---------------------

ANIMATIONS_LO, ANIMATIONS_HI = 0x0040B5AD, 0x004177BA
BLOBS_LO, BLOBS_HI = 0x0041DE40, 0x0042B517
WALK_SILENT_TYPES = 39
VOICE_CURSOR_REFS = (8, 9)
AMBIENCE_SLOT_REFS = (2, 1, 1, 1, 1)
AMBIENCE_CONTROL = "door.wav"      # positive control for the same search
WALK_STRAY_VOLUME = (45,)          # the one footstep scaled by a weapon-band id
INFO_WEAPON_TOP = 47
# The three sites that pass a computed volume-control id in a register.
DYNAMIC_VOLUME_PUSHES = (0x0040C7D7, 0x0040CBF4, 0x0040E857)
DYNAMIC_VOLUME_OPCODES = (0x57, 0x57, 0x57)
WEAPON_SWITCH_TOP = (47, 46, 44)   # the top weapon id each switch covers

# Shipped waves that no string literal and no Info.lcl field names.
WAVES_UNREFERENCED = ("W_CHS_0.wav", "W_HSR_0.wav",
                      "amb_a_0.wav", "amb_a_1.wav", "amb_a_2.wav",
                      "amb_a_3.wav", "amb_a_4.wav",
                      "amb_b_0.wav", "amb_b_1.wav", "amb_b_2.wav",
                      "amb_b_3.wav", "amb_b_4.wav",
                      "bridge.wav", "splash.wav")

# The ten literal wave names whose case does not match the shipped file.
CASE_MISMATCHED = ('alarm.wav', 'bridge2.wav', 'explosion2.wav', 'firecircle.wav',
                   'lbarrier.wav', 'moveland.wav', 'planttube.wav', 'progress.wav',
                   'teleport.wav', 'teleport2.wav')

# Volume-control ids an immediate at some call site actually names.
VOLUME_IDS_USED = [50, 59, 60, 61, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73,
                   74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88,
                   89, 94, 95, 96, 97, 98, 99, 100, 101, 102]
BLOB_MODEL_COUNT = 30

# -- the pinned tables, generated from the binary -------------------------

SOUND_SITES = {
    0x0040c7f8: ((0x40c7cc, '%s.wav'), None),   # aPlayFightAnimation
    0x0040c856: ((0x40c841, 'ricochet.wav'), (0x40c837, 80)),   # aPlayFightAnimation
    0x0040c891: ((0x40c87c, 'explosion2.wav'), (0x40c872, 81)),   # aPlayFightAnimation
    0x0040c8c8: ((0x40c8b3, 'aexplosion.wav'), (0x40c8a9, 95)),   # aPlayFightAnimation
    0x0040cc15: ((0x40cbbc, 'S_HUM_0.wav'), None),   # aPlayFightAnimation
    0x0040dbf1: ((0x40dbdc, 'explosion2.wav'), (0x40dbd2, 81)),   # aPlayFightAnimation
    0x0040e871: (None, None),   # aStartWalkAnimationSound
    0x0040f267: ((0x40f252, 'platform.wav'), (0x40f248, 74)),   # 0x40f230
    0x0040f2ad: ((0x40f298, 'platform2.wav'), (0x40f28a, 75)),   # 0x40f230
    0x0040f611: ((0x40f5fc, 'damage.wav'), (0x40f5dd, 65)),   # aPlayWeaponExplosionAnimation
    0x0040f680: ((0x40f66b, 'jammed.wav'), (0x40f64c, 64)),   # aPlayWeaponExplosionAnimation
    0x0040f6ef: ((0x40f6da, 'explosion.wav'), (0x40f6bb, 63)),   # aPlayWeaponExplosionAnimation
    0x0040fa08: ((0x40f9f3, 'jammed.wav'), (0x40f9e9, 64)),   # aPlayPoisonAnimation
    0x0040fd39: ((0x40fd24, 'heal.wav'), (0x40fd1a, 85)),   # aPlayHealAnimation
    0x00410016: ((0x410001, 'skill.wav'), (0x40fff7, 73)),   # 0x40ff30
    0x004102fb: ((0x4102e6, 'skill.wav'), (0x4102dc, 73)),   # 0x410190
    0x004105d1: ((0x4105bc, 'jammed.wav'), (0x4105b2, 64)),   # 0x4104a0
    0x0041093c: ((0x410927, 'box.wav'), (0x41091d, 66)),   # 0x410780
    0x00410c91: ((0x410c7c, 'door.wav'), (0x410c72, 67)),   # aDoorOpenSequence
    0x00410e55: ((0x410e40, 'drawbridge.wav'), (0x410e36, 79)),   # 0x410da0
    0x00410ff5: ((0x410fe0, 'tube.wav'), (0x410fd2, 71)),   # 0x410f10
    0x0041103b: ((0x411026, 'air_current.wav'), (0x411018, 72)),   # 0x410f10
    0x0041122a: ((0x411215, 'planttube.wav'), (0x411203, 71)),   # 0x411150
    0x004113b8: ((0x4113a3, 'tube.wav'), (0x411391, 71)),   # 0x4112e0
    0x00411736: ((0x411721, 'jump.wav'), (0x411717, 69)),   # aPlayJumpAnimaion
    0x004118af: ((0x41189a, 'drop.wav'), (0x411890, 70)),   # aPlayJumpAnimaion
    0x00411986: ((0x411971, 'S_ALI_2.wav'), (0x411967, 61)),   # aPlayJumpAnimaion
    0x00411a0a: ((0x4119f5, 'S_ALI_1.wav'), (0x4119eb, 60)),   # aPlayJumpAnimaion
    0x00411a8e: ((0x411a79, 'S_ALI_0.wav'), (0x411a6f, 59)),   # aPlayJumpAnimaion
    0x00411c58: ((0x411c43, 'alien_scream.wav'), (0x411c35, 83)),   # 0x411b00
    0x00411ca8: ((0x411c93, 'crush.wav'), (0x411c85, 82)),   # 0x411b00
    0x00411cf8: ((0x411ce3, 'drop.wav'), (0x411cd5, 70)),   # 0x411b00
    0x004121c6: ((0x4121b1, 'alien_scream.wav'), (0x41219f, -1)),   # 0x411fb0
    0x0041221a: ((0x412205, 'crush.wav'), (0x4121f3, -1)),   # 0x411fb0
    0x004125fd: ((0x4125e8, 'elevator.wav'), (0x4125da, 76)),   # aPlayElevatorSequence
    0x00412643: ((0x41262e, 'elevator2.wav'), (0x412620, 77)),   # aPlayElevatorSequence
    0x00412a30: ((0x412a1b, 'platform.wav'), (0x412a0d, 74)),   # aPlayPlatformSequence
    0x00412a76: ((0x412a61, 'platform2.wav'), (0x412a53, 75)),   # aPlayPlatformSequence
    0x00413201: ((0x4131ec, 'firecircle.wav'), (0x4131d6, 74)),   # aPlayRotateStatueSequence
    0x004137ad: ((0x413798, 'lbarrier.wav'), (0x41378e, 101)),   # aPlayLaserBarrier
    0x00413a6d: ((0x413a58, 'stone.wav'), (0x413a4a, 74)),   # aPlayRotateStatueSequence
    0x00413ab3: ((0x413a9e, 'stonefire.wav'), (0x413a90, 84)),   # aPlayRotateStatueSequence
    0x0041402d: ((0x414018, 'stonefire.wav'), (0x41400a, 84)),   # aPlayStatueSequence
    0x00414386: ((0x414371, 'moveland.wav'), (0x414367, 102)),   # 0x414360
    0x0041460e: ((0x4145f9, 'drop.wav'), (0x4145ef, 70)),   # 0x414550
    0x0041487f: ((0x41486a, 'msqueether.wav'), (0x414860, 99)),   # 0x4147d0
    0x00414ab0: ((0x414a9b, 'bridge2.wav'), (0x414a91, 100)),   # aPlayFootBridgeSequence
    0x00414ae7: ((0x414ad2, 'bridge2.wav'), (0x414ac8, 78)),   # aPlayFootBridgeSequence
    0x00415141: ((0x41512c, 'bridge2.wav'), (0x41511a, 100)),   # aPlayFootBridgeSequence
    0x004157eb: ((0x4157d6, 'gfire.wav'), (0x4157cc, 84)),   # aPlayGroundFireAnimation
    0x00415837: ((0x415822, 'gfire.wav'), (0x415818, 84)),   # aPlayGroundFireAnimation
    0x00415d39: ((0x415d24, 'crushwall.wav'), (0x415d12, 86)),   # aPlayCrushWallAnimation
    0x00415ebe: ((0x415ea9, 'bomber.wav'), (0x415e97, 87)),   # 0x415e90
    0x00416291: ((0x416280, 'crush.wav'), (0x416276, 89)),   # 0x4160f0
    0x0041648f: ((0x41647a, 'bomber.wav'), (0x416470, 88)),   # 0x416470
    0x00416586: ((0x416571, 'teleport.wav'), (0x416567, 97)),   # aPlayTeleporterSequence
    0x004165c8: ((0x4165b3, 'teleport2.wav'), (0x4165a9, 98)),   # 0x41658c
    0x004168d4: ((0x4168bf, 'teleport.wav'), (0x4168b5, 97)),   # 0x416840
    0x00416916: ((0x416901, 'SP_HUM_0.wav'), (0x4168f7, 50)),   # 0x416840
    0x00416c03: ((0x416bee, 'lever.wav'), (0x416be4, 68)),   # aPlayUseLeverSequence
    0x00416d10: ((0x416cfb, 'explosion2.wav'), (0x416cf1, 81)),   # aPlayDestryoEntrypointSequence
    0x00416e00: ((0x416deb, 'mine.wav'), (0x416de1, 94)),   # aPlayDestroyMineSequence
}

BLOB_CALLS = {
    0x0041ead4: ((0x41eacf, BLOB_NAME_SCRATCH), (0x41eacd, 2), (0x41eac5, 75), None),
    0x00420147: ((0x420142, BLOB_NAME_SCRATCH), (0x420140, 2), (0x420137, 60), (0x420135, 8)),
    0x004201ae: ((0x4201a9, BLOB_NAME_SCRATCH), (0x4201a7, 2), (0x420195, 60), (0x420193, 8)),
    0x00420b59: ((0x420b54, BLOB_NAME_SCRATCH), (0x420b52, 2), (0x420b49, 47), (0x420b47, 16)),
    0x00420cee: ((0x420ce9, 'A_BLUT4.3DI'), (0x420ce7, 0), (0x420cc4, 17), (0x420cc2, 15)),
    0x00420d50: ((0x420d4b, 'A_BLUT4.3DI'), (0x420d49, 0), (0x420d26, 43), (0x420d24, 15)),
    0x00421335: ((0x421330, BLOB_NAME_SCRATCH), (0x42132e, 2), (0x4212e2, 60), (0x4212e0, 8)),
    0x004216b2: ((0x4216ad, BLOB_NAME_SCRATCH), (0x4216ab, 2), (0x42165e, 50), (0x42165c, 8)),
    0x00421978: (None, (0x421975, 0), (0x421964, 18), (0x421962, 50)),
    0x00421a05: (None, (0x421a02, 0), (0x4219ee, 18), (0x4219ec, 30)),
    0x00421be4: (None, (0x421be1, 0), (0x421bd0, 18), (0x421bce, 30)),
    0x00421f11: ((0x421f0c, 'A_SPLAT5.3DI'), (0x421f0a, 0), (0x421ef8, 18), (0x421ef6, 30)),
    0x00421f9a: ((0x421f95, 'A_SPLAT5.3DI'), (0x421f93, 0), (0x421f7b, 18), (0x421f79, 30)),
    0x00421fcd: ((0x421fc8, BLOB_NAME_SCRATCH), (0x421fc6, 2), (0x421fb6, 51), (0x421fb4, 16)),
    0x00422003: ((0x421ffe, BLOB_NAME_SCRATCH), (0x421ffc, 2), (0x421fe7, 51), (0x421fe5, 16)),
    0x0042235d: (None, (0x42235a, 0), (0x42233d, 18), (0x42233b, 50)),
    0x004223f0: (None, (0x4223ed, 0), (0x4223d7, 18), (0x4223d5, 30)),
    0x0042254b: ((0x422546, 'A_DEBRIS.3DI'), (0x422544, 0), (0x422539, 0), (0x422537, 50)),
    0x004225e4: ((0x4225df, 'A_SPLAT1.3DI'), (0x4225dd, 0), (0x4225d2, 0), (0x4225d0, 50)),
    0x004226fd: ((0x4226f8, 'A_DEBRIS.3DI'), (0x4226f6, 0), (0x4226eb, 29), (0x4226e9, 50)),
    0x00422791: ((0x42278c, 'A_SPLAT1.3DI'), (0x42278a, 0), (0x42277f, 29), (0x42277d, 50)),
    0x004228c4: ((0x4228bf, BLOB_NAME_SCRATCH), (0x4228bd, 2), (0x4228b4, 9), (0x4228b2, 10)),
    0x00422a44: ((0x422a3f, BLOB_NAME_SCRATCH), (0x422a3d, 2), (0x422a32, 44), (0x422a30, 16)),
    0x00422b52: (None, (0x422b4f, 0), (0x422b3a, 36), (0x422b38, 15)),
    0x00422d0e: ((0x422d09, 'A_EXPL05.3DI'), None, (0x422cfa, 13), None),
    0x00422ebb: ((0x422eb6, 'A_ARROW.3DI'), None, (0x422ea2, 14), (0x422ea0, 15)),
    0x00423007: ((0x423002, BLOB_NAME_SCRATCH), (0x423000, 2), (0x422fcf, 67), (0x422fcd, 6)),
    0x00423248: (None, (0x423245, 0), (0x423204, 37), (0x423202, 40)),
    0x004232a5: (None, (0x4232a2, 0), (0x423268, 37), (0x423266, 40)),
    0x0042348e: ((0x423489, 'A_SKULL.3DI'), (0x423487, 0), (0x42344f, 37), (0x42344d, 40)),
    0x00423535: ((0x423530, BLOB_NAME_SCRATCH), (0x42352e, 2), (0x423523, 10), (0x423521, 12)),
    0x00423596: ((0x423591, BLOB_NAME_SCRATCH), (0x42358f, 2), (0x423584, 10), (0x423582, 12)),
    0x004235fb: ((0x4235f6, BLOB_NAME_SCRATCH), (0x4235f4, 2), (0x4235e9, 10), (0x4235e7, 12)),
    0x00423656: ((0x423651, BLOB_NAME_SCRATCH), (0x42364f, 2), (0x423644, 10), (0x423642, 12)),
    0x00423706: ((0x423701, BLOB_NAME_SCRATCH), (0x4236ff, 2), (0x4236f4, 10), (0x4236f2, 11)),
    0x00423755: ((0x423750, BLOB_NAME_SCRATCH), (0x42374e, 2), (0x423740, 50), None),
    0x0042383b: ((0x423836, BLOB_NAME_SCRATCH), (0x423834, 2), (0x423829, 10), (0x423827, 20)),
    0x004238a3: ((0x42389e, BLOB_NAME_SCRATCH), (0x42389c, 2), (0x423891, 10), (0x42388f, 20)),
    0x004239e9: ((0x4239e4, BLOB_NAME_SCRATCH), (0x4239e2, 2), (0x423989, 10), (0x423987, 20)),
    0x00423aa8: ((0x423aa3, 'A_DEBRIS.3DI'), (0x423aa1, 0), (0x423a54, 5), (0x423a52, 100)),
    0x00423bfd: ((0x423bf8, BLOB_NAME_SCRATCH), (0x423bf6, 2), (0x423b9d, 10), (0x423b9b, 20)),
    0x00423d4f: (None, (0x423d4c, 0), (0x423d3d, 31), (0x423d3b, 5)),
    0x0042414b: ((0x424146, BLOB_NAME_SCRATCH), (0x424144, 2), (0x424117, 69), None),
    0x004246f9: ((0x4246f0, BLOB_NAME_SCRATCH), (0x4246ee, 2), None, None),
    0x00424bd2: ((0x424bcd, 'A_LINE5.3DI'), (0x424bcb, 0), (0x424bb0, 15), None),
    0x00424c5d: ((0x424c58, 'A_CASE.3DI'), (0x424c56, 0), (0x424c25, 11), (0x424c23, 20)),
    0x00425185: ((0x425180, 'A_LINE5.3DI'), (0x42517e, 0), (0x42510b, 15), None),
    0x0042522c: ((0x425227, 'A_LINE5.3DI'), (0x425225, 0), (0x4251b2, 15), None),
    0x004252d3: ((0x4252ce, 'A_CASE.3DI'), (0x4252cc, 0), (0x4252aa, 11), (0x4252a8, 20)),
    0x0042534d: ((0x425348, 'A_CASE.3DI'), (0x425346, 0), (0x425326, 11), (0x425324, 20)),
    0x004257c7: ((0x4257c2, BLOB_NAME_SCRATCH), (0x4257c0, 2), (0x4257a7, 32), None),
    0x00425c5d: ((0x425c58, BLOB_NAME_SCRATCH), (0x425c56, 2), (0x425c05, 46), (0x425c03, 8)),
    0x00426048: ((0x426043, 'A_MINE1.3DI'), (0x426041, 0), (0x42602a, 6), None),
    0x00426463: (None, (0x426460, 0), None, (0x426418, 100)),
    0x0042687c: (None, (0x426879, 0), (0x42686a, 61), (0x426868, 100)),
    0x00426b52: ((0x426b4d, BLOB_NAME_SCRATCH), (0x426b4b, 2), (0x426b34, 22), None),
    0x00426f18: ((0x426f13, 'A_MINE2.3DI'), (0x426f11, 0), (0x426efa, 77), None),
    0x004273a9: ((0x4273a2, 'A_LASERG.3DI'), (0x4273a0, 0), (0x427358, 1), (0x427356, 4)),
    0x004277b7: ((0x4277b0, 'A_BLASER.3DI'), (0x4277ae, 0), (0x427765, 38), (0x427761, 5)),
    0x00427b16: ((0x427b11, 'A_PLSMA1.3DI'), (0x427b0f, 0), (0x427aaf, 1), None),
    0x00427bcf: ((0x427bca, 'A_BLIZ02.3DI'), (0x427bc8, 0), (0x427b5c, 12), (0x427b5a, 10)),
    0x00427c5a: ((0x427c55, 'A_BLIZ03.3DI'), (0x427c53, 0), (0x427be7, 12), (0x427be5, 10)),
    0x00428168: ((0x428163, BLOB_NAME_SCRATCH), (0x428161, 2), (0x428141, 49), None),
    0x004284d3: ((0x4284ce, BLOB_NAME_SCRATCH), (0x4284cc, 2), (0x4284c1, 70), (0x4284bf, 20)),
    0x00428544: ((0x42853f, BLOB_NAME_SCRATCH), (0x42853d, 2), (0x428532, 71), (0x428530, 20)),
    0x004288d6: ((0x4288d1, BLOB_NAME_SCRATCH), (0x4288cf, 2), (0x4288c4, 63), None),
    0x0042896b: ((0x428966, BLOB_NAME_SCRATCH), (0x428964, 2), (0x428959, 64), None),
    0x00428ae8: ((0x428ae3, BLOB_NAME_SCRATCH), (0x428ae1, 2), (0x428aba, 51), (0x428ab8, 16)),
    0x00428b9d: ((0x428b98, 'A_LASERG.3DI'), (0x428b96, 0), (0x428b8d, 1), (0x428b8b, 9)),
    0x00428d70: ((0x428d6b, BLOB_NAME_SCRATCH), (0x428d69, 2), (0x428d58, 62), (0x428d56, 7)),
    0x00428dff: ((0x428dfa, BLOB_NAME_SCRATCH), (0x428df8, 2), (0x428deb, 62), (0x428de9, 7)),
    0x00428eb1: ((0x428eac, BLOB_NAME_SCRATCH), (0x428eaa, 2), (0x428e9f, 23), None),
    0x00428f51: ((0x428f4c, 'A_FUNKE.3DI'), (0x428f4a, 0), (0x428f3f, 23), None),
    0x00429150: ((0x42914b, 'A_SPARK.3DI'), (0x429149, 0), (0x429140, 72), None),
    0x0042936b: ((0x429366, 'A_LINE6.3DI'), (0x429364, 0), (0x42935b, 72), None),
    0x0042940e: ((0x429409, BLOB_NAME_SCRATCH), (0x429407, 2), (0x4293fc, 40), (0x4293fa, 8)),
    0x00429484: ((0x42947f, BLOB_NAME_SCRATCH), (0x42947d, 2), (0x429472, 33), (0x429470, 8)),
    0x004294cc: ((0x4294c7, BLOB_NAME_SCRATCH), (0x4294c5, 2), (0x4294ba, 33), (0x4294b8, 8)),
    0x004295bb: ((0x4295b6, 'A_FUNKE.3DI'), (0x4295b4, 0), (0x4295a9, 24), (0x4295a7, 60)),
    0x004296e4: ((0x4296df, 'A_DEBRIS.3DI'), (0x4296dd, 0), (0x429690, 5), (0x42968e, 100)),
    0x004297d2: (None, (0x4297bf, 0), (0x4297ac, 3), (0x4297aa, 10)),
    0x004298b3: ((0x4298ae, BLOB_NAME_SCRATCH), (0x4298ac, 2), (0x4298a1, 59), (0x42989f, 20)),
    0x00429a59: (None, (0x429a56, 0), (0x429a05, 5), (0x429a03, 100)),
    0x00429bdf: ((0x429bda, BLOB_NAME_SCRATCH), (0x429bd8, 2), (0x429bc4, 50), (0x429bc2, 8)),
    0x00429cbf: ((0x429cba, BLOB_NAME_SCRATCH), (0x429cb8, 2), (0x429ca8, 75), (0x429ca6, 10)),
    0x00429cf6: ((0x429cf1, BLOB_NAME_SCRATCH), (0x429cef, 2), (0x429cdf, 75), (0x429cdd, 6)),
    0x00429d2d: ((0x429d28, BLOB_NAME_SCRATCH), (0x429d26, 2), (0x429d16, 75), (0x429d14, 5)),
    0x00429e72: ((0x429e6d, BLOB_NAME_SCRATCH), (0x429e6b, 2), (0x429e55, 50), (0x429e53, 8)),
    0x00429efa: ((0x429ef5, BLOB_NAME_SCRATCH), (0x429ef3, 2), (0x429edf, 10), (0x429edd, 12)),
    0x0042a0d1: ((0x42a0cc, BLOB_NAME_SCRATCH), (0x42a0ca, 2), (0x42a0b6, 50), (0x42a0b4, 8)),
    0x0042a2c9: ((0x42a2c4, BLOB_NAME_SCRATCH), (0x42a2c2, 2), (0x42a27e, 65), (0x42a27c, 70)),
    0x0042a3e3: ((0x42a3de, BLOB_NAME_SCRATCH), (0x42a3dc, 2), (0x42a39b, 66), (0x42a399, 20)),
    0x0042a46a: ((0x42a465, 'A_HIT1.3DI'), (0x42a463, 0), (0x42a458, 16), (0x42a456, 4)),
    0x0042a4ad: ((0x42a4a8, 'A_EXPL04.3DI'), (0x42a4a6, 0), (0x42a49b, 16), (0x42a499, 4)),
    0x0042a50e: ((0x42a509, 'A_FLIGHT.3DI'), (0x42a507, 1), (0x42a4fc, 41), (0x42a4f7, 255)),
    0x0042a54d: ((0x42a548, 'A_FIRE3.3DI'), (0x42a546, 1), (0x42a53b, 54), (0x42a536, 255)),
    0x0042a58d: ((0x42a588, 'L049EE00.3DI'), (0x42a586, 1), (0x42a57b, 57), (0x42a576, 255)),
    0x0042a5cd: ((0x42a5c8, 'A_SPOTL.3DI'), (0x42a5c6, 1), (0x42a5bb, 55), (0x42a5b6, 255)),
    0x0042a646: ((0x42a641, BLOB_NAME_SCRATCH), (0x42a63f, 3), (0x42a634, 10), (0x42a632, 12)),
    0x0042a6c6: ((0x42a6c1, BLOB_NAME_SCRATCH), (0x42a6bf, 3), (0x42a6b4, 58), (0x42a6b2, 12)),
    0x0042a746: ((0x42a741, BLOB_NAME_SCRATCH), (0x42a73f, 2), (0x42a734, 10), (0x42a732, 20)),
    0x0042a790: ((0x42a78b, 'A_PANEL.3DI'), (0x42a789, 1), (0x42a77b, 42), (0x42a776, 255)),
    0x0042a8b6: ((0x42a8b1, 'A_LINE2.3DI'), (0x42a8af, 0), (0x42a8a6, 19), None),
    0x0042a9ad: ((0x42a9a8, 'L069EE00.3DI'), (0x42a9a6, 0), (0x42a99d, 52), (0x42a998, 150)),
    0x0042aa04: ((0x42a9ff, BLOB_NAME_SCRATCH), (0x42a9fd, 2), (0x42a9f2, 51), (0x42a9f0, 16)),
    0x0042ab17: ((0x42ab12, 'A_SPARK.3DI'), (0x42ab10, 0), (0x42ab07, 34), None),
    0x0042acc8: ((0x42acc3, 'A_SPARK.3DI'), (0x42acc1, 0), (0x42acb8, 34), None),
    0x0042adbd: ((0x42adb8, 'A_FUNKE.3DI'), (0x42adb6, 0), (0x42ada6, 20), (0x42ada4, 30)),
    0x0042aedb: (None, (0x42aed8, 0), (0x42aecd, 20), None),
    0x0042afde: ((0x42afd9, 'A_PLSMA1.3DI'), (0x42afd7, 0), (0x42afc8, 8), (0x42afc6, 10)),
    0x0042b04f: ((0x42b04a, 'A_BLIZ01.3DI'), (0x42b048, 0), (0x42aff7, 8), (0x42aff5, 20)),
    0x0042b13c: ((0x42b137, 'A_PARAB1.3DI'), (0x42b135, 0), (0x42b10d, 25), None),
    0x0042b1c2: ((0x42b1bd, 'A_PARAB1.3DI'), (0x42b1bb, 0), (0x42b18e, 25), (0x42b189, 200)),
    0x0042b2c9: ((0x42b2c4, BLOB_NAME_SCRATCH), (0x42b2c2, 2), (0x42b2b5, 60), (0x42b2b3, 8)),
    0x0042b389: ((0x42b384, 'A_DEBRIS.3DI'), (0x42b382, 0), (0x42b37a, 39), (0x42b378, 50)),
    0x0042b45c: ((0x42b457, BLOB_NAME_SCRATCH), (0x42b455, 2), (0x42b44a, 68), (0x42b448, 40)),
}

DIRECT_SITES = {
    0x004176d9: (None, None),   # aAnimations.cpp
    0x00417a1e: ((0x417a09, 'click_3.wav'), (0x4179ff, -1)),   # aBattleMap.cpp
    0x00419f11: ((0x419efc, 'click_1.wav'), (0x419ef2, 96)),   # aBattleSystem.cpp
    0x00419f60: ((0x419f4b, 'click_2.wav'), (0x419f41, 96)),   # aBattleSystem.cpp
    0x00419faf: ((0x419f9a, 'click_5.wav'), (0x419f90, 96)),   # aBattleSystem.cpp
    0x00419ffe: ((0x419fe9, 'select.wav'), (0x419fdf, 96)),   # aBattleSystem.cpp
    0x0043bf4f: ((0x43bf3a, 'click_1.wav'), (0x43bf30, 96)),   # aGameControl.cpp
    0x0043bf94: ((0x43bf7f, 'click_2.wav'), (0x43bf75, 96)),   # aGUI.cpp
    0x0043bfd9: ((0x43bfc4, 'textbeep.wav'), (0x43bfba, 96)),   # aGUI.cpp
    0x00447c50: ((0x447c3b, 'click_4.wav'), (0x447c31, -1)),   # aLoad.cpp
    0x00447c92: ((0x447c7d, 'click_3.wav'), (0x447c73, -1)),   # aLoad.cpp
    0x00456eb8: ((0x456e92, '%smb%daif.wav'), (0x456ea1, -1)),   # aMissionControl.cpp
    0x004574d9: ((0x4574b6, '%sextro.wav'), (0x4574c5, -1)),   # aMissionControl.cpp
    0x00460043: ((0x46002e, 'click_3.wav'), (0x460024, -1)),   # aMultiPlayer.cpp
    0x0047bb89: ((0x47bb4f, '%sSpeech\\%s\\%s%02d%02d.wav'), (0x47bb72, -1)),   # aUnitMap.cpp
    0x0047c054: ((0x47c03f, 'progress.wav'), (0x47c035, -1)),   # aViewPlayer.cpp
    0x0047c0a1: ((0x47c08c, 'alarm.wav'), (0x47c082, -1)),   # aViewPlayer.cpp
}

BGB_ARMS = {
    0: (0x41dfbd, None),   # none
    1: (0x41e119, None),   # none
    2: (0x41e021, 0x42a4c0),   # aBlob_CreateWarningLight
    3: (0x41dfdd, 0x42a760),   # aBlob_CreateComputerLight
    4: (0x41e061, 0x42a520),   # aBlob_CreateCreateFire
    5: (0x41e0a1, 0x42a5a0),   # aBlob_CreateSpot
    6: (0x41e0dd, 0x42a560),   # aBlob_CreateCreateFire
}

BGB_TICK_ARMS = {
    1: (0x41e25e, 0x42a5e0),   # aBlob_CreateSmoke2
    2: (0x41e2d6, None),   # none
    3: (0x41e2d6, None),   # none
    4: (0x41e2d6, None),   # none
    5: (0x41e2d6, None),   # none
    6: (0x41e2d6, None),   # none
    7: (0x41e29a, 0x42a660),   # aBlob_CreateMainMapFire
}

UPDATE_ARMS = {
    0x41feaf: (0,),
    0x41f5cb: (1,),
    0x41e792: (2,),
    0x42004d: (3,),
    0x42022f: (4,),
    0x4202c8: (5,),
    0x41f8b6: (6,),
    0x41e971: (7,),
    0x4204f4: (8,),
    0x41e9b6: (9,),
    0x41f08c: (10,),
    0x4207b6: (11,),
    0x41f0fb: (12,),
    0x41f117: (13,),
    0x41ed5a: (14,),
    0x420734: (15,),
    0x420291: (16,),
    0x4201c3: (17,),
    0x41ff28: (18,),
    0x41f2d3: (19,),
    0x41fd7f: (20,),
    0x420260: (21, 24),
    0x41f6ec: (22,),
    0x41f870: (23, 40),
    0x41e725: (25,),
    0x41f92f: (26,),
    0x41fb8a: (27,),
    0x4204d2: (28,),
    0x41fdb0: (29,),
    0x41f82c: (30,),
    0x41efa6: (31,),
    0x41f52b: (32,),
    0x41f4e3: (33,),
    0x41f37c: (34,),
    0x41e9a4: (35,),
    0x41f1ea: (36,),
    0x41ef0e: (37,),
    0x41f6c4: (38,),
    0x41fe6c: (39,),
    0x41e55a: (41,),
    0x41e574: (42,),
    0x41e5b4: (43,),
    0x41f166: (44,),
    0x41f60a: (45,),
    0x41f66b: (46,),
    0x41f241: (47,),
    0x420805: (48, 53),
    0x41e7fc: (49,),
    0x41effb: (50,),
    0x41efd9: (51,),
    0x41e631: (52,),
    0x41e6ce: (54,),
    0x41e713: (55,),
    0x41ff6a: (56,),
    0x41e709: (57,),
    0x41f0ac: (58,),
    0x4200c7: (59,),
    0x41f018: (60,),
    0x42030a: (61,),
    0x41e8ad: (62,),
    0x41f495: (63,),
    0x41f4c0: (64,),
    0x41ebf9: (65,),
    0x41f427: (66, 70),
    0x41ee47: (67,),
    0x41fe29: (68,),
    0x42059a: (69,),
    0x41f448: (71,),
    0x41f3ab: (72,),
    0x420634: (73,),
    0x4206d1: (74,),
    0x41e9f8: (75,),
    0x41eb2e: (76,),
    0x41f75d: (77,),
}

WALK_ARMS = {
    0x40e683: ((0, 1, 2, 3, 4, 5, 6, 21, 22, 23, 25, 26), (0x40e683, 'mhuman.wav'), (0x40e6ba, 62), (0x40e697, 4)),
    0x40e6ca: ((24,), (0x40e6ca, 'mdecther.wav'), (0x40e701, 45), (0x40e6de, 2)),
    0x40e711: ((20,), (0x40e711, 'mcombot.wav'), (0x40e748, 90), (0x40e725, 8)),
    0x40e758: ((52, 65, 66), (0x40e758, 'mdecther.wav'), (0x40e78f, 91), (0x40e76c, 2)),
    0x40e79f: ((54,), (0x40e79f, 'msqueether.wav'), (0x40e7c5, 93), None),
    0x40e7cc: ((59,), (0x40e7cc, 'malien.wav'), (0x40e803, 92), (0x40e7e0, 7)),
    0x40e810: ((50, 51, 53, 55, 56, 57, 58, 60, 64, 67, 68), (0x40e810, 'malien.wav'), (0x40e836, 92), (0x40e842, 5)),
    0x40e8cc: ((7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 61, 62, 63), None, None, None),
}

VOICE_ARMS = (
    (0x40ca52, 'SP_HUM_2.wav', 0x40ca5d, 52),
    (0x40ca78, 'SP_HUM_1.wav', 0x40ca83, 51),
    (0x40ca9e, 'SP_HUM_0.wav', 0x40caa9, 50),
    (0x40caf7, 'S_ALI_2.wav', 0x40cb02, 58),
    (0x40cb1d, 'S_ALI_1.wav', 0x40cb28, 57),
    (0x40cb43, 'S_ALI_0.wav', 0x40cb4e, 56),
    (0x40cb76, 'S_HUM_2.wav', 0x40cb81, 58),
    (0x40cb99, 'S_HUM_1.wav', 0x40cba4, 57),
    (0x40cbbc, 'S_HUM_0.wav', 0x40cbc7, 56),
)






WEAPON_MUZZLE = {
    2: (0x40ced3, ((0x40cef4, 0x4247c0),)),
    3: (0x40ced3, ((0x40cef4, 0x4247c0),)),
    4: (0x40d3ee, ((0x40d407, 0x424d20),)),
    5: (0x40ced3, ((0x40cef4, 0x4247c0),)),
    6: (0x40ced3, ((0x40cef4, 0x4247c0),)),
    7: (0x40cff9, ((0x40d014, 0x427c80),)),
    8: (0x40d160, ((0x40d17a, 0x425ca0),)),
    9: (0x40cf65, ((0x40cfb1, 0x4264a0),)),
    10: (0x40d364, ((0x40d37d, 0x426f90),)),
    11: (0x40d077, ((0x40d0b6, 0x426070),)),
    12: (0x40d1eb, ((0x40d20d, 0x4247c0), (0x40d23d, 0x4247c0))),
    13: (0x40d1a6, ((0x40d1bf, 0x426b70),)),
    14: (0x40d2d8, ((0x40d2f2, 0x428570),)),
    15: (0x40ccb4, ()),
    16: (0x40cc66, ((0x40cc88, 0x424250),)),
    17: (0x40ccc5, ((0x40cccf, 0x429a80), (0x40ccf4, 0x42acf0), (0x40cd19, 0x4295d0), (0x40cd40, 0x422b80))),
    18: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    19: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    20: (0x40ceca, ()),
    21: (0x40ceca, ()),
    22: (0x40cd74, ((0x40cd7d, 0x420a50),)),
    23: (0x40cdee, ((0x40ce09, 0x425400),)),
    24: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    25: (0x40cda9, ((0x40cdc2, 0x4268b0),)),
    26: (0x40ce35, ((0x40ce51, 0x425810),)),
    27: (0x40ceca, ()),
    28: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    29: (0x40ce7d, ((0x40ce9e, 0x423d80),)),
    30: (0x40ccb4, ()),
    31: (0x40ccb4, ()),
    32: (0x40ccb4, ()),
    33: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    34: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    35: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    36: (0x40ceca, ()),
    37: (0x40ceca, ()),
    38: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    39: (0x40d42c, ((0x40d44d, 0x4247c0),)),
    40: (0x40d02c, ((0x40d047, 0x427c80),)),
    41: (0x40d269, ((0x40d2a3, 0x4247c0),)),
    42: (0x40d160, ((0x40d17a, 0x425ca0),)),
    43: (0x40cf20, ((0x40cf39, 0x427810),)),
    44: (0x40d0fd, ((0x40d125, 0x426070),)),
    45: (0x40d3a9, ((0x40d3c2, 0x427410),)),
    46: (0x40d1a6, ((0x40d1bf, 0x426b70),)),
    47: (0x40d31e, ((0x40d338, 0x428200),)),
}

WEAPON_IMPACT = {
    7: (0x40d927, ()),
    8: (0x40d803, ((0x40d807, 0x429a80), (0x40d82c, 0x42acf0), (0x40d851, 0x4295d0))),
    9: (0x40d590, ((0x40d5c3, 0x42af10),)),
    10: (0x40da07, ()),
    11: (0x40da07, ()),
    12: (0x40da07, ()),
    13: (0x40d63a, ((0x40d643, 0x429180), (0x40d64f, 0x429c30))),
    14: (0x40d70b, ((0x40d736, 0x42a9d0),)),
    15: (0x40da07, ()),
    16: (0x40da07, ()),
    17: (0x40da07, ()),
    18: (0x40da07, ()),
    19: (0x40da07, ()),
    20: (0x40da07, ()),
    21: (0x40da07, ()),
    22: (0x40da07, ()),
    23: (0x40d52c, ((0x40d532, 0x429f40),)),
    24: (0x40da07, ()),
    25: (0x40d4fa, ((0x40d500, 0x429f40),)),
    26: (0x40d55e, ((0x40d564, 0x429f40),)),
    27: (0x40da07, ()),
    28: (0x40da07, ()),
    29: (0x40da07, ()),
    30: (0x40da07, ()),
    31: (0x40da07, ()),
    32: (0x40da07, ()),
    33: (0x40da07, ()),
    34: (0x40da07, ()),
    35: (0x40da07, ()),
    36: (0x40d7ac, ((0x40d7b0, 0x422b80), (0x40d7d7, 0x429a80))),
    37: (0x40d8ad, ((0x40d8b1, 0x429a80), (0x40d8d6, 0x42acf0), (0x40d8fb, 0x4295d0))),
    38: (0x40da07, ()),
    39: (0x40da07, ()),
    40: (0x40d93d, ()),
    41: (0x40da07, ()),
    42: (0x40d76a, ((0x40d780, 0x4227c0),)),
    43: (0x40d5f8, ((0x40d60e, 0x4294e0),)),
    44: (0x40d87d, ((0x40d881, 0x4228f0),)),
    45: (0x40da07, ()),
    46: (0x40d65c, ((0x40d68f, 0x4227c0),)),
}

WEAPON_IMPACT_SOUND = {
    0: (0x40c837, (0x40c841, 'ricochet.wav')),
    1: (0x40c837, (0x40c841, 'ricochet.wav')),
    2: (0x40c837, (0x40c841, 'ricochet.wav')),
    3: (0x40c837, (0x40c841, 'ricochet.wav')),
    4: (0x40c837, (0x40c841, 'ricochet.wav')),
    5: (0x40c837, (0x40c841, 'ricochet.wav')),
    6: (0x40c837, (0x40c841, 'ricochet.wav')),
    7: (0x40c8eb, None),
    8: (0x40c872, (0x40c87c, 'explosion2.wav')),
    9: (0x40c8eb, None),
    10: (0x40c8eb, None),
    11: (0x40c872, (0x40c87c, 'explosion2.wav')),
    12: (0x40c837, (0x40c841, 'ricochet.wav')),
    13: (0x40c872, (0x40c87c, 'explosion2.wav')),
    14: (0x40c8eb, None),
    15: (0x40c8eb, None),
    16: (0x40c8eb, None),
    17: (0x40c8eb, None),
    18: (0x40c8eb, None),
    19: (0x40c8eb, None),
    20: (0x40c8eb, None),
    21: (0x40c8eb, None),
    22: (0x40c8eb, None),
    23: (0x40c8a9, (0x40c8b3, 'aexplosion.wav')),
    24: (0x40c8eb, None),
    25: (0x40c8a9, (0x40c8b3, 'aexplosion.wav')),
    26: (0x40c8a9, (0x40c8b3, 'aexplosion.wav')),
    27: (0x40c8eb, None),
    28: (0x40c8eb, None),
    29: (0x40c8a9, (0x40c8b3, 'aexplosion.wav')),
    30: (0x40c8eb, None),
    31: (0x40c8eb, None),
    32: (0x40c8eb, None),
    33: (0x40c8eb, None),
    34: (0x40c8eb, None),
    35: (0x40c8eb, None),
    36: (0x40c8eb, None),
    37: (0x40c8eb, None),
    38: (0x40c8eb, None),
    39: (0x40c8eb, None),
    40: (0x40c8eb, None),
    41: (0x40c837, (0x40c841, 'ricochet.wav')),
    42: (0x40c8eb, None),
    43: (0x40c8eb, None),
    44: (0x40c872, (0x40c87c, 'explosion2.wav')),
}


# Developer names, recovered the way tools/trace_names.py recovers them:
# the caller pushes the callee's name on the error path.  The value is
# the address of that push, so every name is read back from the image.
BLOB_CREATOR_NAMES = {
    0x0041e500: None,
    0x00420a50: (0x40cd93, 'aBlob_CreateSpores'),
    0x00420b80: None,
    0x00420d80: (0x40dd64, 'aBlob_CreateBloodFlood'),
    0x00421360: None,
    0x004216d0: (0x415a6d, 'aBlob_CreateFlyingDebris'),
    0x00421c50: None,
    0x00422460: None,
    0x00422610: None,
    0x004227c0: (0x40d6a5, 'aBlob_CreateLandingDust'),
    0x004228f0: (0x40d89b, 'aBlob_CreateFireWheel'),
    0x00422b80: (0x40cd56, 'aBlob_CreateShockWave'),
    0x00422d40: None,
    0x00422f00: (0x413416, 'aBlob_CreateFireCircle'),
    0x00423030: (0x40fd0d, 'aBlob_CreateFlashCircle'),
    0x004232e0: (0x40fa43, 'aBlob_CreateFlashCircle'),
    0x004234c0: None,
    0x00423670: None,
    0x00423720: (0x41f7d8, 'aBlob_CreateZoomBob'),
    0x00423770: None,
    0x004238c0: None,
    0x00423ad0: (0x413346, 'aBlob_CreateKillFire'),
    0x00423c20: (0x415aa6, 'aBlob_CreateTubeSmoke'),
    0x00423d80: (0x40ceb8, 'aBlob_CreateTracerBullet'),
    0x00424250: (0x40cca2, 'aBlob_CreateNeedles'),
    0x004247c0: (0x40cf0e, 'aBlob_CreateTracerBullet'),
    0x00424d20: (0x40d41d, 'aBlob_CreateDoubleFire'),
    0x00425400: (0x40ce23, 'aBlob_CreateTracerBullet'),
    0x00425810: (0x40ce6b, 'aBlob_CreateFlash'),
    0x00425ca0: (0x40d194, 'aBlob_CreateGrenade'),
    0x00426070: (0x40d0cc, 'aBlob_CreateGrenade'),
    0x004264a0: (0x40cfc7, 'aBlob_EnergyCannon'),
    0x004268b0: (0x40cddc, 'aBlob_CreateSporeCannon'),
    0x00426b70: (0x40d1d9, 'aBlob_CreateSpidyMines'),
    0x00426f90: (0x40d397, 'aBlob_CreateLaser'),
    0x00427410: (0x40d3dc, 'aBlob_CreateLaser'),
    0x00427810: (0x40cf53, 'aBlob_CreateFlash'),
    0x00427c80: (0x40d05d, 'aBlob_CreateFlameStream'),
    0x00428200: (0x40d352, 'aBlob_CreateLaser'),
    0x00428570: (0x40d30c, 'aBlob_CreateLaser'),
    0x00428990: (0x413774, 'aBlob_CreateLaserBarrier'),
    0x00428bf0: None,
    0x00428e30: (0x41f74b, 'aBlob_CreateSporeSparks'),
    0x00428ed0: (0x41e942, 'aBlob_CreatePlasmaSparks'),
    0x00428f70: None,
    0x00429180: None,
    0x00429390: None,
    0x00429430: (0x41f5b1, 'aBlob_CreateStingSparks'),
    0x004294e0: (0x40d628, 'aBlob_CreatePlasmaBallImpact'),
    0x004295d0: (0x40cd2f, 'aBlob_CreateExplosion2'),
    0x00429700: (0x40db83, 'aBlob_CreateFlyingUnit'),
    0x004297f0: None,
    0x004298d0: None,
    0x00429a80: (0x40cce5, 'aBlob_CreateFireExplosion'),
    0x00429c30: None,
    0x00429d40: (0x416e6f, 'aBlob_CreateSmallFireExplosion'),
    0x00429f40: (0x40d51a, 'aBlob_CreateSporeExplosion'),
    0x0042a120: None,
    0x0042a2f0: None,
    0x0042a410: (0x41f365, 'aBlob_CreateHittingBlobs'),
    0x0042a480: (0x41f22a, 'aBlob_CreateHittingBlobs'),
    0x0042a4c0: (0x41e050, 'aBlob_CreateWarningLight'),
    0x0042a520: (0x41e090, 'aBlob_CreateCreateFire'),
    0x0042a560: (0x41e108, 'aBlob_CreateCreateFire'),
    0x0042a5a0: (0x41e0cc, 'aBlob_CreateSpot'),
    0x0042a5e0: (0x41e289, 'aBlob_CreateSmoke2'),
    0x0042a660: (0x41e2c5, 'aBlob_CreateMainMapFire'),
    0x0042a6e0: None,
    0x0042a760: (0x41e010, 'aBlob_CreateComputerLight'),
    0x0042a7a0: (0x41fb73, 'aBlob_CreateHittingBlobs'),
    0x0042a8e0: (0x415f15, 'aBlob_CreateBomber'),
    0x0042a9d0: (0x40d750, 'aBlob_CreateLaserHit2'),
    0x0042ab40: None,
    0x0042acf0: (0x40cd0a, 'aBlob_SparkingPlug'),
    0x0042add0: (0x42a43c, 'aBlob_SparkingRain'),
    0x0042af10: (0x40d5d9, 'aBlob_CreatePlasmaExplosion2'),
    0x0042b070: None,
    0x0042b150: (0x41e6b7, 'aBlob_CreateParaBomb'),
    0x0042b1d0: (0x413e5a, 'aBlob_CreateFireDeath'),
    0x0042b300: (0x4200b0, 'aBlob_CreateBarrelDebris'),
    0x0042b3b0: None,
}

BLOB_CREATOR_NAMED = 57


# -- the embedded Eng3d object (docs/30) ----------------------------------
#
# A blob is an ``object_3d`` with a header word and eight fields of its own.
# ``0x00404F80`` builds the same 64-byte record for a world object, which is
# where the layout and the ``shl esi, 6`` stride come from.

WORLD_OBJECT_BUILDER = 0x00404F80
WORLD_OBJECT_STRIDE_SITE = 0x00404FB5      # shl esi, 6
WORLD_OBJECT_STRIDE_SHIFT = 6
WORLD_OBJECT_CAP_SITE = 0x00404F86
WORLD_OBJECT_CAP = 0x96
WORLD_OBJECT_LOOKUP_SITE = 0x00404FC5      # the same 0x004038F0 the blob uses
WORLD_OBJECT_RADIUS_SITE = 0x0040502D      # E3D_get_prototype_collision_radius
WORLD_OBJECT_RADIUS_STORE = 0x00405036     # mov [esi+0x0C], eax
WORLD_OBJECT_STORES = {                    # site -> object_3d offset
    0x00404FFA: 0x10, 0x00404FF6 + 11: 0x14, 0x00405009: 0x18,
    0x00405011: 0x20, 0x00405022: 0x22, 0x00405026: 0x24,
    0x0040501B: 0x1C, 0x0040502A: 0x08, 0x00405036: 0x0C,
}
BLOB_ZERO_SITE = 0x00420A24                # mov dword [esi+0x20], 0
OBJECT_3D_AT = 0x04                        # where the object starts in a blob
OBJECT_3D_SIZE = 0x40
CHECK_IN = 0x00403CC0
CHECK_IN_SITE = 0x0041E441                 # aCheckInBlobObjects hands it blob+4
CHECK_IN_ORDINAL = 9                       # "Function Id 9 not found!"
CHECK_IN_ORDINAL_SITE = 0x00401320
ALLOCATOR = 0x0044AF30                     # aGetMemory -> malloc, no zero fill
ALLOCATOR_CALL_SITE = 0x0044AF84           # call dword [malloc], not calloc
ALLOCATOR_IMPORT = 0x005256C8
ALLOCATOR_ENTRY = bytes.fromhex("51555657")   # push ecx, ebp, esi, edi

# -- the joint-angle buffer: object_3d +0x1c .. +0x3f ---------------------
#
# The last 36 bytes of the record are a union, and which reading applies is
# decided by the prototype's render program, not by the record:
#
#   * ``matrix_clone`` / ``matrix_clone_compose`` read +0x1c as an inline
#     3x3 i32 matrix -- the Charisma character parts;
#   * the six ``anim`` opcodes read +0x1c as a *pointer* to a joint-angle
#     buffer and fall back to the inline area at +0x20 when it is null.
#
# Both hosts always write null, so world objects and blobs always use the
# inline area, which the shipped programs address at byte offsets 0, 6 and 12
# -- three Euler triples.  That is what blob +0x2a/+0x2c/+0x2e/+0x34 are.

ENG3D_DLL = "Eng3d.dll"
ENG3D_GLIDE = "ENG3DFX.DLL"
HOST_BINARIES = ("Incubation.exe", "iDesigner.exe", "Editor.exe")
#: ``mov esi,[ebx+0x1c]; test esi,esi; jne +3; lea esi,[ebx+0x20]; add esi,eax``
JOINT_IDIOM = bytes.fromhex("8B731C85F675038D732003F0")
JOINT_IDIOM_SITES = 7
#: The hosts write these fields and never read them back.
HOST_IDIOM_COUNTS = {"Incubation.exe": 0, "iDesigner.exe": 0, "Editor.exe": 0}
JOINT_DISPATCH = 0x0041408C        # Eng3d.dll: the render-opcode handler table
JOINT_SLOTS = (8, 9, 10, 13, 14, 15, 18)
JOINT_PTR = 0x1C                   # object_3d: external buffer, or 0
WORLD_OBJECT_PTR_SITE = 0x0040501B  # mov dword [esi+0x1c], 0
JOINT_INLINE = 0x20                # object_3d: the inline buffer
JOINT_TRIPLE = 6                   # bytes per Euler triple
JOINT_OFFSETS = (0, 6, 12)         # every operand the shipped programs use
JOINT_BUFFER_BYTES = 18            # three triples ...
JOINT_BUFFER_ROOM = 32             # ... in the 32 bytes after +0x20
JOINT_PLACE = 18                   # the opcode that poses a sub-object
MATRIX_SLOTS = (35, 36)            # the other reading of the same 36 bytes
#: ``mov esi, [0x414084]; lea esi, [esi+0x1c]`` -- the matrix reading's own
#: idiom, and the reason it is a *reading* and not a pointer dereference.
MATRIX_IDIOM = bytes.fromhex("8B358440410 08D761C".replace(" ", ""))
MATRIX_IDIOM_SITES = 2
ANGLE_MASK_SITES = (0x00411BFD, 0x00411C03, 0x00411C09)
ANGLE_MASK = 0xFFF                 # docs/70: TRIG.IMG, a 4096-unit circle
TRIG_SIN = 0x0048E6C0
TRIG_COS = 0x0048EEC0
TRIG_QUARTER = 1024                # cos is sin advanced by a quarter turn
CURRENT_OBJECT = 0x00414084        # Eng3d: the object being drawn
CURRENT_OBJECT_REFS = 15
#: ``0F BF 84 1B <disp32>`` -- the sine and cosine lookups in the builder.
TRIG_SIN_SITE = 0x00411C0F
TRIG_COS_SITE = 0x00411C1C
#: The one export that hands the buffer out, and its whole body: a clone keeps
#: its joint array immediately past the embedded 64-byte object.
JOINT_GETTER = "_E3D_get_object_joint_data_ptr"
JOINT_GETTER_ORDINAL = 59
JOINT_GETTER_BODY = bytes.fromhex("8D4040C3")   # lea eax,[eax+0x40]; ret
#: blob kind -> (model, the ``joint_place`` operands its render program uses,
#: the ``object_3d`` offsets the kind's update arm writes)
JOINT_KINDS = {
    41: ("A_FLIGHT.3DI", (), (0x24,)),
    42: ("A_PANEL.3DI", (6,), (0x26, 0x28, 0x2A)),
    54: ("A_FIRE3.3DI", (6, 12), (0x2A, 0x30)),
}
#: Every ``anim`` operand in every shipped render program, by opcode slot.
JOINT_OPERANDS = {9: {0: 1959}, 10: {0: 367}, 18: {6: 135, 12: 78}}
#: The part-info stream of the same records asks for the same angles, with
#: slots 14 and 15 standing in for 9 and 10.  Its start is the header pointer.
PARTINFO_PTR_AT = 0x2E
JOINT_OPERANDS_PARTINFO = {14: {0: 1959}, 15: {0: 367}, 18: {6: 135, 12: 78}}
#: How the render programs split between the two readings of +0x1c.
JOINT_FAMILIES = {"matrix": 16974, "euler": 2326, "other": 149}
JOINT_FAMILIES_MIXED = 0           # no program uses both readings
#: Distinct prototype names in each family, over all nine world sets.
JOINT_FAMILY_NAMES = {"matrix": 1886, "euler": 1448, "other": 20}
#: The prototypes the missions place as special objects are all joint-family;
#: the two exceptions carry no transform opcode at all and are the pair
#: ``typ_parse.py`` already knows was compiled without ``USE_MATRIX``.
LEV_SPECIAL_FAMILIES = {"euler": 393, "other": 2}
LEV_SPECIAL_OTHER = ("L096EE00.3DI", "L096EF00.3DI")
#: Prototypes with an articulated sub-object, and how often they are placed.
#: Nothing in either host writes triples 1 and 2 of a *world* object, so these
#: are the records whose parts draw at whatever the allocation left.
JOINT_PART_MODELS = 29
JOINT_PART_PLACED_NAMES = 21
JOINT_PART_PLACED = 1276
#: The matrix family is the Charisma character parts: every mesh the 114 ``.cho``
#: models name is matrix-family or absent, and none is joint-family.
CHO_DIR = os.path.join("CHData", "Objects")
CHO_MODELS = 114
CHO_MESHES = 1985
CHO_MESH_FAMILIES = {"matrix": 1877, "?": 108}
#: The matrix-family prototypes no ``.cho`` names -- one unused model set.
CHO_ORPHANS = ("PS_M0_024_BOX01", "PS_M0_024_CYLINDER01", "PS_M0_024_CYLINDER02",
               "PS_M0_024_CYLINDER03", "PS_M0_024_CYLINDER04",
               "PS_M0_024_CYLINDER05", "PS_M0_024_CYLINDER06",
               "PS_M0_024_CYLINDER07", "PS_M0_024_CYLINDER08")


# -- the zoom bob: one texture atlas, 8x8 tiles of 32x32 -----------------

ZOOM_DRAW = 0x004040A0
ZOOM_DRAW_IMPORT = 0x004F9F20              # Eng3d ordinal 63
ZOOM_DRAW_NAME = "E3D_draw_zoom_bob_alpha_plus"
ZOOM_DRAW_NAME_SITE = 0x0040416A
ZOOM_DRAW_ORDINAL_SITE = 0x004023B8        # "Function Id 63 not found!"
ZOOM_BLOBS = 0x0041E490                    # aDrawZoomBlobs
# The engine resolves three zoom-bob blend entry points and calls exactly one.
ZOOM_BLEND_SLOTS = {0x004F9F20: 2,         # ordinal 63, alpha_plus -- resolver + call
                    0x004F84D0: 1,         # ordinal 64, alpha_minus -- resolver only
                    0x004F9F2C: 1}         # ordinal 65, masked      -- resolver only
ZOOM_CLASSES = (2, 3)
ZOOM_CLASS_SITES = (0x0041E4B8, 0x0041E4BC)
ZOOM_ROW_SITE = 0x0041E4CA                 # mov al, [esi + 0x24]
ZOOM_COL_SITE = 0x0041E4C6                 # mov dl, [esi + 0x26]
ZOOM_DEAD_SITE = 0x0041E4C3                # mov cl, [esi + 0x28] -- never read
ZOOM_SIZE_SITE = 0x0041E4C0                # mov al, [esi + 0x54]
TILE_SPAN_CONST = 0x004B1018               # -31.0: the tile is 32 texels wide
TILE_SPAN = -31.0
TILE_SHIFT_SITE = 0x00404108               # shl eax, 5 -- 32 texels per step
TILE_SHIFT = 5
SIZE_SCALE_SITE = 0x004040F3               # (v*5)<<5 = v*160 world units
SIZE_SCALE_SHIFT = 5
SIZE_SCALE = 160
ATLAS_TEXTURE = "anim"
ATLAS_NAME_SITES = (0x0040301E, 0x00403270)
ATLAS_HANDLE = 0x004F9F70
ATLAS_LOOKUP_IMPORT = 0x004FA4EC           # Eng3d ordinal 66
ATLAS_LOOKUP_ORDINAL_SITE = 0x004024A4     # "Function Id 66 not found!"
ATLAS_SIZE = 256
ATLAS_TILE = 32
ATLAS_GRID = 8
SPRITE_SIZE_RANGE = (3, 40)      # half-size in 160-unit steps: 0.3 m to 4 m

# -- the 78 update kinds --------------------------------------------------

KIND_COUNT = 0x4E
KIND_MORPH_SITE = 0x0041E89C               # kind 49 rewrites its own kind
KIND_MORPH_TO = 7
KIND_MORPH_LIFE_SITE = 0x0041E898
KIND_MORPH_LIFE = 6
KIND_COMPUTED = {                          # the two calls that build a kind
    0x004246F9: (0x004246CA, 0x49, (73, 74)),   # aBlob_CreateNeedles: setne + 0x49
    0x00426463: (0x004263CE, 0x1A, (26, 27)),   # aBlob_CreateGrenade: sete  + 0x1A
}
KIND_UNREACHABLE = (2, 4, 21, 28, 30, 35, 45, 48, 53, 56, 76)

# What individual arms do, pinned instruction by instruction.  These are the
# claims docs/28 makes about particular kinds; the rest of the 74 arms are
# characterised only by the fields they touch, which no byte scan can read
# reliably, and by the spawn graph below, which it can.
KIND_EVIDENCE = {
    "k14.mark_free": (0x0041ED9D, "bytes", b"\x89\x2e"),
    "k41.spin_step": (0x0041E55A, "mov_imm32", 0x200),
    "k41.spin_store": (0x0041E563, "word_add", 0x28),
    "k42.slow": (0x0041E589, "word_imm", (0x2C, 0x400)),
    "k42.fast": (0x0041E591, "word_imm", (0x2C, 0x1000)),
    "k42.copy_x": (0x0041E59F, "word_store", 0x2A),
    "k42.copy_z": (0x0041E5A3, "word_store", 0x2E),
    "k54.range_a": (0x0041E6CE, "push", 0x1000),
    "k54.range_b": (0x0041E6E1, "push", 0x1000),
    "k54.store_a": (0x0041E6E7, "word_store", 0x2E),
    "k54.store_b": (0x0041E6F8, "word_store", 0x34),
    "k49.morph_life": (0x0041E898, "byte_imm", (0x45, 6)),
    "k49.morph_kind": (0x0041E89C, "byte_imm", (0x44, 7)),
    "k16.model_swap": (0x004202A7, "call", 0x004038F0),
    "k17.model_swap": (0x004201F7, "call", 0x004038F0),
    "k62.spark_arg10": (0x0041E8D7, "push", 10),
    "k62.spark_arg1": (0x0041E8D9, "push", 1),
    "k65.far_col": (0x0041ECEC, "word_imm", (0x26, 3)),
    "k65.far_aux": (0x0041ECF6, "byte_imm", (0x54, 5)),
    "k67.spark_arg10": (0x0041EE85, "push", 10),
    "k67.spark_arg1": (0x0041EE87, "push", 1),
}
# The three arms that ask the unit map where a target is.
KIND_SEEKERS = {26: 0x0041F935, 27: 0x0041FB90, 61: 0x00420310}
UNIT_MAP_LOOKUP = 0x00477AE0

# class 2/3 call -> ((row push, row), (col push, col), (size push, size))
BLOB_SPRITE = {
    0x0041ead4: (None, None, None),
    0x00420147: ((0x42013b, 1), None, None),
    0x004201ae: ((0x420199, 1), None, None),
    0x00420b59: ((0x420b4d, 3), None, (0x420b3a, 10)),
    0x00421335: ((0x4212e8, 5), (0x4212e6, 0), None),
    0x004216b2: ((0x421664, 1), (0x421662, 0), (0x421613, 10)),
    0x00421fcd: ((0x421fc1, 7), (0x421fba, 0), (0x421fac, 25)),
    0x00422003: ((0x421ff7, 7), (0x421feb, 0), (0x421fdd, 30)),
    0x004228c4: ((0x4228b8, 4), None, (0x422890, 10)),
    0x00422a44: ((0x422a38, 0), (0x422a36, 0), (0x4229e3, 10)),
    0x00423007: (None, (0x422fd3, 0), (0x422fc5, 20)),
    0x00423535: ((0x423529, 4), (0x423527, 0), (0x4234d2, 10)),
    0x00423596: ((0x42358a, 4), (0x423588, 0), (0x423545, 10)),
    0x004235fb: ((0x4235ef, 4), (0x4235ed, 0), (0x4235aa, 10)),
    0x00423656: ((0x42364a, 4), (0x423648, 0), (0x423605, 10)),
    0x00423706: ((0x4236fa, 4), (0x4236f8, 0), (0x4236b5, 11)),
    0x00423755: (None, (0x423744, 0), None),
    0x0042383b: ((0x42382f, 4), (0x42382d, 0), (0x423819, 10)),
    0x004238a3: ((0x423897, 4), (0x423895, 0), (0x423881, 10)),
    0x004239e9: ((0x42398f, 4), (0x42398d, 0), (0x423982, 30)),
    0x00423bfd: ((0x423ba3, 0), (0x423ba1, 0), (0x423b96, 20)),
    0x0042414b: ((0x42413b, 6), None, (0x424111, 5)),
    0x004246f9: ((0x4246e9, 1), (0x4246e7, 0), None),
    0x004257c7: ((0x4257b1, 3), (0x4257ab, 0), (0x42579d, 40)),
    0x00425c5d: ((0x425c0b, 6), (0x425c09, 0), (0x425bf8, 5)),
    0x00426b52: ((0x426b3c, 3), (0x426b38, 0), (0x426b0a, 15)),
    0x00428168: ((0x42815c, 0), None, None),
    0x004284d3: ((0x4284c7, 5), (0x4284c5, 0), (0x4284b7, 8)),
    0x00428544: ((0x428538, 5), (0x428536, 0), (0x428528, 8)),
    0x004288d6: ((0x4288ca, 5), (0x4288c8, 0), (0x428897, 8)),
    0x0042896b: ((0x42895f, 5), (0x42895d, 0), (0x42892c, 8)),
    0x00428ae8: ((0x428ac0, 5), (0x428abe, 0), (0x428ab0, 10)),
    0x00428d70: ((0x428d60, 0), (0x428d5c, 3), (0x428d4e, 25)),
    0x00428dff: (None, None, (0x428dae, 30)),
    0x00428eb1: ((0x428ea5, 6), (0x428ea3, 0), (0x428e91, 3)),
    0x0042940e: ((0x429402, 3), (0x429400, 0), (0x4293f1, 3)),
    0x00429484: ((0x429478, 3), (0x429476, 0), (0x429449, 5)),
    0x004294cc: ((0x4294c0, 3), (0x4294be, 0), (0x42949c, 5)),
    0x004298b3: ((0x4298a7, 1), (0x4298a5, 0), None),
    0x00429bdf: (None, (0x429bc8, 0), None),
    0x00429cbf: ((0x429cb3, 0), (0x429cac, 0), (0x429c95, 30)),
    0x00429cf6: ((0x429cea, 0), (0x429ce3, 0), (0x429cd2, 25)),
    0x00429d2d: ((0x429d21, 0), (0x429d1a, 0), (0x429d09, 20)),
    0x00429e72: (None, (0x429e59, 0), None),
    0x00429efa: ((0x429eec, 4), (0x429ee3, 0), (0x429ed2, 10)),
    0x0042a0d1: ((0x42a0bd, 3), None, None),
    0x0042a2c9: ((0x42a287, 5), (0x42a282, 0), (0x42a243, 5)),
    0x0042a3e3: ((0x42a3a1, 5), (0x42a39f, 0), (0x42a391, 5)),
    0x0042a646: ((0x42a63a, 4), (0x42a638, 0), (0x42a621, 10)),
    0x0042a6c6: ((0x42a6ba, 0), (0x42a6b8, 0), (0x42a6a1, 5)),
    0x0042a746: ((0x42a73a, 4), (0x42a738, 0), (0x42a721, 10)),
    0x0042aa04: ((0x42a9f8, 5), (0x42a9f6, 0), (0x42a9e0, 40)),
    0x0042b2c9: ((0x42b2bd, 4), (0x42b2b9, 0), None),
    0x0042b45c: ((0x42b450, 6), (0x42b44e, 0), None),
}

KIND_SPAWNS = {
    3: (0x42b300,),
    6: (0x423720,),
    11: (0x41e320,),
    15: (0x423720,),
    19: (0x42a410,),
    22: (0x428e30,),
    25: (0x42b300,),
    26: (0x423720, 0x42a7a0),
    32: (0x429430,),
    36: (0x42a480,),
    44: (0x428ed0,),
    47: (0x429390,),
    52: (0x42b150,),
    56: (0x423720,),
    59: (0x420950,),
    62: (0x428ed0,),
    67: (0x428ed0,),
    69: (0x423720,),
    71: (0x42a9d0,),
    73: (0x423720, 0x428f70),
    74: (0x428f70,),
    75: (0x420950, 0x428ed0),
    77: (0x423720,),
}

# -- the blocking sequence loop (what gates a sound) ---------------------

FRAME_TICK = 0x0040B6F0
FRAME_TICK_SITES = 70
PLAY_LOOPING = 1                           # DSBPLAY_LOOPING
PLAY_TICKS_MAX = 3
PLAY_TICKS_ZERO = 39
PLAY_LOOPING_SITES = 9
PLAY_TICK_HISTOGRAM = {0: 39, 1: 9, 2: 6, 3: 4}

# play site -> (loop-flag push site, flag, frame ticks before it in the routine)
PLAY_SITES = {
    0x0040d487: (0x40d484, 0, 1),
    0x0040dc1b: (0x40dc18, 0, 2),
    0x0040e1e8: (0x40e1e5, 0, 2),
    0x0040e217: (0x40e214, 0, 2),
    0x0040e98f: (0x40e985, 0, 0),
    0x0040f2d7: (0x40f2d4, 1, 0),
    0x0040f3b5: (0x40f3b2, 0, 1),
    0x0040f7ad: (0x40f7aa, 0, 0),
    0x0040fa5c: (0x40fa59, 0, 0),
    0x0040fd68: (0x40fd65, 0, 0),
    0x00410045: (0x410042, 0, 0),
    0x0041032a: (0x410327, 0, 0),
    0x00410600: (0x4105fd, 0, 0),
    0x00410966: (0x410963, 0, 0),
    0x00410cc5: (0x410cc2, 1, 0),
    0x00410e7f: (0x410e7c, 1, 0),
    0x00411065: (0x411062, 0, 0),
    0x004110ae: (0x4110ab, 0, 1),
    0x00411254: (0x411251, 0, 0),
    0x004113e2: (0x4113df, 0, 0),
    0x0041176a: (0x411767, 0, 0),
    0x004118d9: (0x4118d6, 0, 2),
    0x004119ba: (0x4119b7, 0, 3),
    0x00411a3e: (0x411a3b, 0, 3),
    0x00411ac2: (0x411abf, 0, 3),
    0x00411d32: (0x411d2f, 0, 0),
    0x00411d9c: (0x411d99, 0, 1),
    0x00411e5c: (0x411e59, 0, 3),
    0x00412258: (0x412255, 0, 0),
    0x004122d4: (0x4122d1, 0, 1),
    0x004127b2: (0x4127af, 1, 0),
    0x004128d4: (0x4128d1, 0, 1),
    0x00412c86: (0x412c83, 1, 0),
    0x00412ec8: (0x412ec5, 0, 1),
    0x004133d5: (0x4133d2, 0, 0),
    0x004137d7: (0x4137d4, 0, 0),
    0x00413bd1: (0x413bce, 1, 0),
    0x00413ee7: (0x413ee4, 0, 2),
    0x00414275: (0x414272, 0, 0),
    0x0041447f: (0x41447c, 1, 0),
    0x00414762: (0x41475f, 0, 1),
    0x00414a05: (0x414a02, 0, 0),
    0x00414ce0: (0x414cdd, 0, 0),
    0x004153a5: (0x4153a2, 0, 0),
    0x00415acc: (0x415ac1, 0, 0),
    0x00415ae9: (0x415ac1, 0, 0),
    0x00415dbb: (0x415db8, 0, 0),
    0x00415fc3: (0x415fc0, 1, 0),
    0x0041633f: (0x41633c, 0, 1),
    0x00416379: (0x416376, 0, 2),
    0x004164bd: (0x4164ba, 1, 0),
    0x0041665e: (0x41665b, 0, 0),
    0x0041671d: (0x41671a, 0, 0),
    0x00416940: (0x41693d, 0, 0),
    0x00416980: (0x41697d, 0, 0),
    0x00416c2d: (0x416c2a, 0, 0),
    0x00416d3a: (0x416d37, 0, 0),
    0x00416e2a: (0x416e27, 0, 0),
}

# -- the overheat catastrophe (docs/22 sec.8) ----------------------------

WEAPON_EXPLOSION = 0x0040F420
OVERHEAT = 0x0046D1B0                      # aCheckWeaponDamage
OVERHEAT_SITES = (0x0046D22B, 0x0046D26C, 0x0046D2A9, 0x0046D2E6)




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

    def mapped(self, va: int, size: int = 1) -> bool:
        """Whether *va* is inside the image, so a decode can be attempted.

        A mutated address is the normal way a check is shown to fail; reading
        one must return "not the instruction I expected", not an exception.
        """
        off = self.pe.va_to_off(va)
        return off is not None and off + size <= len(self.pe.data)

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

    def call_map(self) -> dict[int, list[int]]:
        """target -> every ``call rel32`` site in ``.text`` that reaches it.

        One sweep, cached: the checks ask about ninety different targets.
        """
        if getattr(self, "_call_map", None) is None:
            out: dict[int, list[int]] = {}
            lo, hi = self.text_lo, self.text_hi
            data = self.pe.data
            base = self.pe.va_to_off(lo)
            end = base + (hi - lo)
            pos = base
            while True:
                pos = data.find(b"\xe8", pos, end - 5)
                if pos < 0:
                    break
                va = lo + (pos - base)
                target = va + 5 + struct.unpack_from("<i", data, pos + 1)[0]
                if lo <= target < hi:
                    out.setdefault(target, []).append(va)
                pos += 1
            self._call_map = out
        return self._call_map

    def calls_to(self, target: int) -> list[int]:
        """Every ``call rel32`` in ``.text`` that reaches *target*."""
        return list(self.call_map().get(target, ()))

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

    # -- tiny instruction readers ------------------------------------------
    #
    # Every site these read is pinned by address in the constants above, so
    # they only have to recognise the one encoding that is actually there.

    def push_imm(self, va: int) -> int | None:
        op = self.u8(va)
        if op == 0x6A:
            return self.i8(va + 1)
        if op == 0x68:
            return self.u32(va + 1)
        return None

    def push_str(self, va: int) -> str | None:
        if self.u8(va) != 0x68:
            return None
        return self.string(self.u32(va + 1))

    def cmp_imm(self, va: int) -> int | None:
        """``cmp r/m8, imm8`` (0x80), ``cmp r/m32, imm8`` (0x83), ``cmp al``."""
        if not self.mapped(va, 6):
            return None
        op = self.u8(va)
        if op == 0x3C:
            return self.i8(va + 1)
        if op == 0x3D:
            return self.i32(va + 1)
        if op in (0x80, 0x83):
            return self.i8(va + 2)
        if op == 0x81:
            return self.i32(va + 2)
        return None

    def mov_imm32(self, va: int) -> int | None:
        """``mov r32, imm32`` (0xB8+r) or ``mov [disp32], imm32`` (0xC7 05)."""
        if not self.mapped(va, 10):
            return None
        op = self.u8(va)
        if 0xB8 <= op <= 0xBF:
            return self.i32(va + 1)
        if op == 0xC7:
            modrm = self.u8(va + 1)
            if modrm == 0x05:
                return self.i32(va + 6)
            if modrm & 0xC7 == 0x06:        # mov [reg], imm32
                return self.i32(va + 2)
            if modrm & 0xC0 == 0x80:        # mov [reg + disp32], imm32
                return self.i32(va + 6)
        return None

    def add_imm(self, va: int) -> int | None:
        if not self.mapped(va, 6):
            return None
        op = self.u8(va)
        if op == 0x05:
            return self.i32(va + 1)
        if op == 0x83:
            return self.i8(va + 2)
        if op == 0x81:
            return self.i32(va + 2)
        return None

    def mem_operand(self, va: int) -> int | None:
        """The disp32 of the pinned ``lea``/``mov`` forms this tool reads."""
        if not self.mapped(va, 7):
            return None
        op = self.u8(va)
        if op == 0x8D:                       # lea r32, [base + index*s + d32]
            modrm = self.u8(va + 1)
            if modrm & 0xC0 == 0x80 and modrm & 0x07 == 0x04:
                return self.u32(va + 3)
        if op == 0x8A:                       # mov r8, [index*s + d32]
            modrm = self.u8(va + 1)
            if modrm & 0xC0 == 0x00 and modrm & 0x07 == 0x04:
                return self.u32(va + 3)
        return None

    # -- the switches -------------------------------------------------------

    def switch(self, table: tuple[int, int, int, int]) -> dict[int, int]:
        """``index table`` + ``jump table`` -> {case value: arm address}."""
        index, count, jump, first = table
        out = {}
        for k in range(count):
            if not self.mapped(index + k):
                continue
            target = jump + 4 * self.u8(index + k)
            if self.mapped(target, 4):
                out[first + k] = self.u32(target)
        return out

    def jump_table(self, base: int, count: int) -> list[int]:
        return [self.u32(base + 4 * k) for k in range(count)
                if self.mapped(base + 4 * k, 4)]

    @staticmethod
    def _extent(arm: int, arms, limit: int) -> int:
        """Where an arm's own code ends: at the next arm, in address order.

        The arms of a compiler-generated switch are laid out contiguously, so
        the next arm address is an exact upper bound.  Bounding the scan this
        way is what makes a disassembler unnecessary: within one arm every
        ``E8`` whose rel32 lands on a known function *is* that call, and no
        scan can run into the neighbouring arm and pick up its calls.
        """
        later = [a for a in arms if a > arm]
        return min(later) if later else arm + limit

    def arm_calls(self, arm: int, targets: set[int], arms=(),
                  limit: int = 320) -> list[int]:
        """Every ``call rel32`` to one of *targets* inside the arm at *arm*."""
        out: list[int] = []
        end = self._extent(arm, arms, limit)
        if not self.mapped(arm) or not self.mapped(end - 1):
            return out
        va = arm
        while va < end - 5:
            if self.u8(va) == 0xE8:
                target = va + 5 + self.i32(va + 1)
                if target in targets:
                    out.append(target)
                    va += 5
                    continue
            va += 1
        return out

    def arm_string(self, arm: int, suffix: str, arms=(),
                   limit: int = 320) -> str | None:
        end = self._extent(arm, arms, limit)
        va = arm
        while va < end - 5:
            if self.u8(va) == 0x68:
                text = self.string(self.u32(va + 1), 64)
                if text and text.lower().endswith(suffix):
                    return text
            va += 1
        return None

    # -- derived tables -----------------------------------------------------

    def creator_names(self) -> dict[int, str | None]:
        return {creator: (self.push_str(pinned[0]) if pinned else None)
                for creator, pinned in BLOB_CREATOR_NAMES.items()}

    def blob_creators(self) -> set[int]:
        """Every function in ``aBlobs.cpp`` that calls the constructor.

        Derived from ``BLOB_CALLS`` rather than from a function map: the calls
        are pinned, and the creator is the nearest call target at or below one.
        """
        entries = sorted(self.call_entries())
        out = set()
        for site in BLOB_CALLS:
            index = bisect.bisect_right(entries, site) - 1
            if index >= 0:
                out.add(entries[index])
        return out

    def call_entries(self) -> set[int]:
        return set(self.call_map())

    def sound_sites(self) -> dict[int, tuple[str | None, int | None]]:
        """The pinned ``aAnimationCreateSoundBuffer`` sites, decoded."""
        out = {}
        for site, (wave, volume) in SOUND_SITES.items():
            name = self.push_str(wave[0]) if wave else None
            vol = self.push_imm(volume[0]) if volume else None
            out[site] = (name, vol)
        return out

    def direct_sites(self) -> dict[int, tuple[str | None, int | None]]:
        out = {}
        for site, (wave, volume) in DIRECT_SITES.items():
            name = self.push_str(wave[0]) if wave else None
            vol = self.push_imm(volume[0]) if volume else None
            out[site] = (name, vol)
        return out

    def blob_calls(self) -> dict[int, tuple]:
        out = {}
        for site, (model, cls, kind, life) in BLOB_CALLS.items():
            name = None
            if model is not None:
                value = self.push_imm(model[0])
                name = self.string(value, 40) if value else None
                if name is None:
                    name = value
            out[site] = (name,
                         self.push_imm(cls[0]) if cls else None,
                         self.push_imm(kind[0]) if kind else None,
                         self.push_imm(life[0]) if life else None)
        return out

    def walk_arms(self) -> dict[int, tuple]:
        """``aStartWalkAnimationSound``: arm -> (types, wave, volume, period)."""
        arms: dict[int, list[int]] = {}
        for unit_type in range(WALK_BOUND + 1):
            entry = self.u8(WALK_INDEX_TABLE + unit_type)
            arms.setdefault(self.u32(WALK_JUMP_TABLE + 4 * entry),
                            []).append(unit_type)
        out = {}
        for arm, types in arms.items():
            pinned = WALK_ARMS.get(arm)
            wave = volume = period = None
            if pinned:
                _types, wave_site, vol_site, per_site = pinned
                if wave_site:
                    wave = self.string(self.mov_imm32(wave_site[0]) or 0, 40)
                if vol_site:
                    volume = self.mov_imm32(vol_site[0])
                if per_site:
                    period = self.mov_imm32(per_site[0])
            out[arm] = (tuple(types), wave, volume, period)
        return out

    def voice_arms(self) -> list[tuple[str | None, int | None]]:
        return [(self.push_str(site), self.mov_imm32(vol_site))
                for site, _name, vol_site, _vol in VOICE_ARMS]

    def weapon_effects(self, table, pinned) -> dict[int, tuple]:
        """{weapon: (arm, ((call site, creator), ...))}, read from the binary."""
        cases = self.switch(table)
        out = {}
        for case, arm in cases.items():
            _arm, calls = pinned[case]
            out[case] = (arm, tuple((site, self.call_target(site))
                                    for site, _creator in calls))
        return out

    def weapon_sounds(self) -> dict[int, tuple]:
        out = {}
        for case, arm in self.switch(IMPACT_SOUND_SWITCH).items():
            _arm, wave = WEAPON_IMPACT_SOUND[case]
            out[case] = (arm, (wave[0], self.push_str(wave[0])) if wave else None)
        return out

    def kind_arms(self) -> dict[int, int]:
        """kind -> the address of the arm the switch selects for it."""
        return {k: self.u32(BLOB_UPDATE_TABLE + 4 * k) for k in range(KIND_COUNT)}

    def kind_spawns(self) -> dict[int, tuple[int, ...]]:
        """kind -> the blob routines its arm calls.

        The arms are contiguous, so each one's extent is bounded by the next
        in address order; within that the ``E8`` scan of :meth:`arm_calls`
        applies unchanged.
        """
        table = self.kind_arms()
        arms = set(table.values()) | {BLOB_UPDATE_TABLE}
        targets = self.blob_creators() | {BLOB_CTOR, BLOB_DELETE}
        return {kind: tuple(sorted(set(self.arm_calls(arm, targets, arms, 620))))
                for kind, arm in table.items()}

    def sprite_params(self) -> dict[int, tuple]:
        """class 2/3 call -> (atlas row, atlas column, sprite half-size)."""
        return {site: tuple(None if f is None else self.push_imm(f[0])
                            for f in fields)
                for site, fields in BLOB_SPRITE.items()}

    def play_sites(self) -> dict[int, tuple[int, int]]:
        """play site -> (loop-flag push site, the flag it pushes)."""
        return {site: (flag_site, self.push_imm(flag_site))
                for site, (flag_site, _flag, _ticks) in PLAY_SITES.items()}

    def frame_ticks_before(self, site: int, entry: int) -> int:
        """How many frame ticks the routine issues ahead of *site*."""
        return len([t for t in self.calls_to(FRAME_TICK) if entry <= t < site])

    def word_store(self, site: int) -> int | None:
        """``66 89 4e dd`` / ``66 89 46 dd`` -- a 16-bit store to ``[esi+dd]``."""
        if self.u8(site) != 0x66 or self.u8(site + 1) != 0x89:
            return None
        if self.u8(site + 2) & 0xC7 != 0x46:
            return None
        return self.u8(site + 3)

    def word_add(self, site: int) -> int | None:
        """``66 01 46 dd`` -- a 16-bit add into ``[esi+dd]``."""
        if self.u8(site) != 0x66 or self.u8(site + 1) != 0x01:
            return None
        if self.u8(site + 2) & 0xC7 != 0x46:
            return None
        return self.u8(site + 3)

    def word_imm(self, site: int) -> tuple[int, int] | None:
        """``66 c7 46 dd ii ii`` -- a 16-bit immediate into ``[esi+dd]``."""
        if self.u8(site) != 0x66 or self.u8(site + 1) != 0xC7:
            return None
        if self.u8(site + 2) & 0xC7 != 0x46:
            return None
        return self.u8(site + 3), self.u32(site + 4) & 0xFFFF

    def byte_imm(self, site: int) -> tuple[int, int] | None:
        """``c6 46 dd ii`` -- an 8-bit immediate into ``[esi+dd]``."""
        if self.u8(site) != 0xC6 or self.u8(site + 1) & 0xC7 != 0x46:
            return None
        return self.u8(site + 2), self.u8(site + 3)

    def bgb_arms(self) -> dict[int, tuple[int, int | None]]:
        out = {}
        creators = self.blob_creators()
        arms = {self.u32(BGB_JUMP_TABLE + 4 * k)
                for k in range(BGB_TYPE_BOUND + 1)}
        for case in range(BGB_TYPE_BOUND + 1):
            arm = self.u32(BGB_JUMP_TABLE + 4 * case)
            calls = self.arm_calls(arm, creators, arms, 200)
            out[case] = (arm, calls[0] if calls else None)
        return out

    def bgb_tick_arms(self) -> dict[int, tuple[int, int | None]]:
        out = {}
        creators = self.blob_creators()
        arms = {self.u32(BGB_TICK_JUMP_TABLE + 4 * k)
                for k in range(BGB_TYPE_BOUND + 1)}
        for case in range(BGB_TYPE_BOUND + 1):
            arm = self.u32(BGB_TICK_JUMP_TABLE + 4 * case)
            calls = self.arm_calls(arm, creators, arms, 200)
            out[case + 1] = (arm, calls[0] if calls else None)
        return out


class Engine:
    """One Eng3d build, read by virtual address.

    ``Eng3d.dll`` (software) and ``ENG3DFX.DLL`` (Glide) are separate
    compilations of the same source, so an address that is pinned in one is
    not pinned in the other; only pattern counts are compared across them.
    """

    CODE = "BEGTEXT"

    def __init__(self, root: str, name: str) -> None:
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            raise SystemExit(f"{path}: not found -- is {root!r} the game root?")
        self.name = name
        self.pe = PEFile(path)
        self.code_lo, _vsize, self._raw, self._rawsize = self.pe.section(self.CODE)

    def occurrences(self, pattern: bytes) -> list[int]:
        """Every virtual address in the code section that starts *pattern*."""
        out: list[int] = []
        data = self.pe.data
        pos = self._raw
        end = self._raw + self._rawsize
        while True:
            pos = data.find(pattern, pos, end)
            if pos < 0:
                return out
            out.append(self.code_lo + (pos - self._raw))
            pos += 1

    def handler(self, slot: int) -> int:
        """The render-opcode handler the dispatch table holds for *slot*."""
        return self.pe.u32(JOINT_DISPATCH + 4 * slot)

    def and_imm32(self, va: int) -> int | None:
        """The immediate of ``and r32, imm32`` (``81 /4 id``)."""
        if self.pe.u8(va) != 0x81 or self.pe.u8(va + 1) & 0x38 != 0x20:
            return None
        return self.pe.u32(va + 2)

    def absolute_refs(self, address: int) -> int:
        """How many times the code section spells *address* out in full."""
        return len(self.occurrences(struct.pack("<I", address)))

    def sib_disp32(self, va: int) -> int | None:
        """The disp32 of ``movsx r32, word [b + b*1 + disp32]`` (0F BF /r)."""
        if self.pe.u8(va) != 0x0F or self.pe.u8(va + 1) != 0xBF:
            return None
        modrm = self.pe.u8(va + 2)
        if modrm & 0xC7 != 0x84:            # mod=10, r/m=100 (SIB), disp32
            return None
        return self.pe.u32(va + 4)

    def exports(self) -> dict[int, tuple[str, int]]:
        """``{ordinal: (name, virtual address)}`` from the export directory."""
        data = self.pe.data
        rva, _size = self.pe.dirs[0]
        off = self.pe.rva_to_off(rva)
        if off is None:
            raise PEError(f"{self.name}: no export directory")
        (_flags, _stamp, _major, _minor, _name, base, nfunc, nname,
         addrs, names, ords) = struct.unpack_from("<IIHHIIIIIII", data, off)
        table = [struct.unpack_from("<I", data, self.pe.rva_to_off(addrs) + 4 * i)[0]
                 for i in range(nfunc)]
        out: dict[int, tuple[str, int]] = {}
        for i in range(nname):
            name_rva = struct.unpack_from("<I", data, self.pe.rva_to_off(names) + 4 * i)[0]
            index = struct.unpack_from("<H", data, self.pe.rva_to_off(ords) + 2 * i)[0]
            text = data[self.pe.rva_to_off(name_rva):]
            out[index + base] = (text[:text.index(b"\0")].decode("latin-1"),
                                 self.pe.image_base + table[index])
        return out


def count_pattern(path: str, pattern: bytes) -> int:
    """Occurrences of *pattern* anywhere in a file."""
    with open(path, "rb") as handle:
        data = handle.read()
    total = 0
    pos = 0
    while True:
        pos = data.find(pattern, pos)
        if pos < 0:
            return total
        total += 1
        pos += 1


class Corpus:
    """The shipped data every corpus check reads."""

    def __init__(self, root: str) -> None:
        self.root = root
        waves = Path(root) / WAVES_DIR
        self.waves = sorted(p.name for p in waves.glob("*")
                            if p.is_file() and p.suffix.lower() == ".wav")
        self.wave_index = {name.lower(): name for name in self.waves}

        speech = Path(root) / SPEECH_DIR
        self.speech: dict[str, list[str]] = {}
        if speech.is_dir():
            for sub in sorted(p for p in speech.iterdir() if p.is_dir()):
                self.speech[sub.name] = sorted(
                    p.name for p in sub.glob("*") if p.suffix.lower() == ".wav")

        briefing = Path(root) / BRIEFING_DIR
        self.briefing = sorted(p.name for p in briefing.glob("*")
                               if p.suffix.lower() == ".wav") \
            if briefing.is_dir() else []

        self.volumes: dict[int, int] = {}
        self.weapons: dict[int, list] = {}
        self.weapon_waves: dict[int, str] = {}
        self._read_info()

        self._textures: dict[str, dict[str, tuple[int, int]]] = {}
        for lib in sorted((Path(root) / "WorldSet").glob("World_*/TEXTURES/texture.lib")):
            world = lib.parent.parent.name
            for name, size in _visn_sizes(lib):
                self._textures.setdefault(name.lower(), {})[world] = size

        self.prototypes: dict[str, set[str]] = {}
        for index in sorted((Path(root) / "WorldSet").glob("World_*/Objects/prototyp.dir")):
            world = index.parent.parent.name
            with open(index, "r", errors="replace") as handle:
                self.prototypes[world] = {line.split()[0].upper()
                                          for line in handle if line.split()}

        self._read_geometry()
        self._read_missions()
        self._read_models()

    def _read_geometry(self) -> None:
        """Classify every shipped render program by how it transforms.

        A program either composes the inline 3x3 matrix at ``object_3d+0x1c``
        (``matrix_clone*``) or reads Euler triples out of the joint buffer at
        ``+0x20`` (the ``anim`` opcodes).  No shipped program does both.
        """
        self.family: dict[str, str] = {}
        self.family_records = {"matrix": 0, "euler": 0, "other": 0}
        self.family_mixed = 0
        self.joint_operands: dict[int, dict[int, int]] = {}
        self.partinfo_operands: dict[int, dict[int, int]] = {}
        self.model_joints: dict[str, tuple[int, ...]] = {}
        for index in sorted((Path(self.root) / "WorldSet")
                            .glob("World_*/Objects/prototyp.din")):
            container = prototyp.load_container(str(index))
            for slot in range(len(container)):
                cmds = prototyp.read_commands(container.record_bytes(slot))
                ops = {cmd.op for cmd in cmds}
                if ops & set(MATRIX_SLOTS) and ops & set(JOINT_SLOTS):
                    self.family_mixed += 1
                if ops & set(MATRIX_SLOTS):
                    kind = "matrix"
                elif ops & set(JOINT_SLOTS):
                    kind = "euler"
                else:
                    kind = "other"
                self.family_records[kind] += 1
                name = container.names[slot].upper()
                self.family[name] = kind
                places = tuple(sorted(cmd.operand for cmd in cmds
                                      if cmd.op == JOINT_PLACE))
                if places:
                    self.model_joints.setdefault(name, places)
                record = container.record_bytes(slot)
                try:
                    start = PARTINFO_PTR_AT + struct.unpack_from(
                        "<i", record, PARTINFO_PTR_AT)[0]
                    partinfo = prototyp.read_commands(record, start)
                except (struct.error, prototyp.ParseError, IndexError):
                    partinfo = []
                for stream, into in ((cmds, self.joint_operands),
                                     (partinfo, self.partinfo_operands)):
                    for cmd in stream:
                        if cmd.operand_kind != "anim":
                            continue
                        bucket = into.setdefault(cmd.op, {})
                        bucket[cmd.operand] = bucket.get(cmd.operand, 0) + 1

    def _read_models(self) -> None:
        """Every mesh the Charisma models name, to identify the matrix family."""
        self.cho_models = 0
        self.cho_meshes: set[str] = set()
        for path in sorted((Path(self.root) / CHO_DIR).rglob("*.cho")):
            self.cho_models += 1
            for part in cho_parse.parse(str(path)).parts:
                if part.mesh:
                    self.cho_meshes.add(part.mesh.upper())

    def _read_missions(self) -> None:
        """Every prototype the shipped missions place as a special object."""
        self.lev_specials: set[str] = set()
        self.lev_placements: dict[str, int] = {}
        for path in sorted((Path(self.root) / "Missions").glob("*.lev")):
            battle = levlib.load_lev(str(path))
            for obj in battle.special:
                name = obj.prototype_name(battle.world_set).upper()
                self.lev_specials.add(name)
                self.lev_placements[name] = self.lev_placements.get(name, 0) + 1

    def _read_info(self) -> None:
        path = os.path.join(self.root, INFO_LCL)
        if not os.path.isfile(path):
            return
        with open(path, "rb") as handle:
            program = lcl_parse.parse_bytes(handle.read(), path)
        for routine in program.routines:
            for stmt in _walk(routine.body):
                args = numbers(stmt.args)
                if stmt.name == "SetVolumeCtrl" and len(args) >= 2:
                    self.volumes[args[0]] = args[1]
                elif stmt.name == "SetWeaponInfo" and args:
                    self.weapons.setdefault(args[0], stmt.args)
                elif stmt.name == "SetWeaponInfo2" and args:
                    texts = strings(stmt.args)
                    if texts:
                        self.weapon_waves[args[0]] = texts[0]

    def texture(self, name: str) -> dict[str, tuple[int, int]]:
        """world set -> the named texture's pixel size, read from its header."""
        return dict(self._textures.get(name.lower(), {}))

    def resolves(self, name: str) -> str | None:
        return self.wave_index.get(name.lower())

    def worlds_with(self, model: str) -> list[str]:
        return sorted(world for world, names in self.prototypes.items()
                      if model.upper() in names)


def _visn_sizes(lib: Path):
    """``(name, (width, height))`` for every record a ``texture.dir`` names."""
    index = lib.with_name("texture.dir")
    if not index.is_file():
        for candidate in lib.parent.glob("*.dir"):
            index = candidate
            break
    if not index.is_file():
        return
    data = lib.read_bytes()
    with open(index, "r", errors="replace") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) != 6:
                continue
            try:
                offset = int(parts[3])
            except ValueError:
                continue
            if offset + 10 > len(data):
                continue
            width, height, _quality, _mode = parse_header(data, offset)
            yield parts[0], (width, height)


def numbers(args) -> list:
    return [a.value for a in args if a.kind == "number"]


def strings(args) -> list:
    return [a.value for a in args if a.kind == "string"]


def _walk(nodes):
    for node in nodes:
        if isinstance(node, lcl_parse.Statement):
            yield node
        elif isinstance(node, lcl_parse.Conditional):
            for term in node.terms:
                yield term.call
            yield from _walk(node.body)
            yield from _walk(node.else_body)


class Checker:
    def __init__(self) -> None:
        self.failed = 0
        self.passed = 0
        self.names: list[str] = []
        #: Names of the checks that failed, for the mutation harness.
        self.failures: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        self.names.append(name)
        if ok:
            self.passed += 1
            LOG.info("  ok    %-34s %s", name, detail)
        else:
            self.failed += 1
            self.failures.append(name)
            LOG.error("  FAIL  %-34s %s", name, detail)

    @staticmethod
    def brief(value) -> str:
        if isinstance(value, dict):
            return f"{len(value)} entries"
        if isinstance(value, (list, tuple, set)) and len(value) > 12:
            return f"{len(value)} items"
        return str(value)

    @staticmethod
    def _format(value, fmt) -> str:
        """Format for the log, tolerating a value the formatter cannot take.

        A failing check often carries ``None`` where an address was expected;
        the failure is the finding, and a formatter that raises on it would
        hide the check name behind a traceback.
        """
        try:
            return fmt(value)
        except (TypeError, ValueError):
            return repr(value)

    def equal(self, name: str, got, want, fmt=str) -> None:
        if got == want:
            self.check(name, True, self._format(got, fmt))
            return
        detail = f"got {self._format(got, fmt)} want {self._format(want, fmt)}"
        if isinstance(got, dict) and isinstance(want, dict):
            keys = sorted(set(got) | set(want))
            diff = [f"{k if isinstance(k, str) else hex(k)}: "
                    f"{got.get(k)!r} != {want.get(k)!r}"
                    for k in keys if got.get(k) != want.get(k)]
            detail += " -- " + "; ".join(diff[:6])
        self.check(name, False, detail)


def run_checks(root: str) -> Checker:
    ck = Checker()
    b = Binary(root)
    c = Corpus(root)

    # ---- the corpus is there at all ------------------------------------
    ck.check("corpus.waves", len(c.waves) > 0, f"{len(c.waves)} wave files")
    ck.check("corpus.info", len(c.volumes) > 0,
             f"{len(c.volumes)} SetVolumeCtrl, {len(c.weapons)} weapons")
    ck.check("corpus.prototypes", len(c.prototypes) == BLOB_MODEL_WORLDS,
             f"{len(c.prototypes)} world object indices")
    if not c.waves or not c.volumes or not c.prototypes:
        return ck

    # ---- aDSound.cpp: the wrapper --------------------------------------
    ck.equal("dsound.buffer_table", b.u32(0x00436BA7), BUFFER_TABLE, hex)
    ck.equal("dsound.load_bound", b.cmp_imm(LOAD_BOUND_SITE), LOAD_BOUND)
    ck.equal("dsound.play_bound", b.cmp_imm(PLAY_BOUND_SITE), PLAY_BOUND)
    ck.equal("dsound.set_bound", b.cmp_imm(SET_BOUND_SITE), SET_BOUND)
    ck.equal("dsound.kill_bound", b.cmp_imm(KILL_BOUND_SITE), KILL_BOUND)
    ck.check("dsound.slot_gap",
             b.cmp_imm(LOAD_BOUND_SITE) == b.cmp_imm(SET_BOUND_SITE)
             == b.cmp_imm(KILL_BOUND_SITE) == _plus(b.cmp_imm(PLAY_BOUND_SITE), 1),
             "load/set/kill take 21 slots, play takes 20")
    ck.equal("dsound.desc_size", b.mov_imm32(DESC_SIZE_SITE), DESC_SIZE)
    ck.equal("dsound.desc_flags", b.mov_imm32(DESC_FLAGS_SITE), DESC_FLAGS, hex)
    for wrapper, (site, target) in ANIM_FORWARD.items():
        ck.equal(f"dsound.wrapper_{wrapper:08x}", b.call_target(site), target, hex)
    ck.equal("dsound.load_sites", len(b.calls_to(ANIM_LOAD)), ANIM_LOAD_SITES)
    ck.equal("dsound.play_sites", len(b.calls_to(ANIM_PLAY)), ANIM_PLAY_SITES)
    ck.equal("dsound.kill_sites", len(b.calls_to(ANIM_KILL)), ANIM_KILL_SITES)
    ck.equal("dsound.direct_sites", len(b.calls_to(DSOUND_LOAD)),
             DIRECT_LOAD_SITES)

    # ---- the volume-control table --------------------------------------
    ck.equal("volume.table", b.u32(0x00437514), VOLUME_TABLE, hex)
    ck.equal("volume.setter_bound", b.cmp_imm(VOLUME_SETTER_BOUND_SITE),
             VOLUME_BOUND)
    ck.equal("volume.scale_bound", b.cmp_imm(VOLUME_SCALE_BOUND_SITE),
             VOLUME_BOUND)
    ck.equal("volume.load_bound", b.cmp_imm(VOLUME_LOAD_BOUND_SITE),
             VOLUME_BOUND)
    ck.check("volume.load_is_exclusive", b.u8(VOLUME_LOAD_BOUND_SITE + 3) == 0x7D
             and b.u8(VOLUME_SETTER_BOUND_SITE + 3) == 0x7F,
             "the load path rejects id 120, the setter accepts it")
    ck.equal("volume.floor", b.cmp_imm(VOLUME_FLOOR_SITE), VOLUME_FLOOR)
    ck.equal("volume.silence", b.mov_imm32(VOLUME_SILENCE_SITE), VOLUME_SILENCE)
    ck.equal("volume.shift", b.u8(VOLUME_MUL_SITE + 2), 4)
    ck.equal("volume.offset", b.i32(VOLUME_OFFSET_SITE + 3), VOLUME_OFFSET)
    ck.equal("volume.fx_global", b.u32(FX_VOLUME_GETTER + 1),
             FX_VOLUME_GLOBAL, hex)
    ck.equal("volume.info_ids", len(c.volumes), INFO_VOLUME_IDS)
    ck.equal("volume.info_range", (min(c.volumes), max(c.volumes)),
             (0, INFO_VOLUME_IDS - 1))
    ck.equal("volume.info_special",
             {i: v for i, v in sorted(c.volumes.items()) if v != 100},
             INFO_VOLUME_SPECIAL)

    # ---- the wave call sites -------------------------------------------
    sites = b.sound_sites()
    ck.equal("wave.site_count", tuple(sorted(b.calls_to(ANIM_LOAD))),
             tuple(sorted(SOUND_SITES)), Checker.brief)
    ck.equal("wave.names", {s: n for s, (n, _v) in sites.items()},
             {s: (w[1] if w else None) for s, (w, _v) in SOUND_SITES.items()}, Checker.brief)
    ck.equal("wave.volumes", {s: v for s, (_n, v) in sites.items()},
             {s: (v[1] if v else None) for s, (_w, v) in SOUND_SITES.items()}, Checker.brief)
    ck.equal("wave.dynamic_sites",
             tuple(b.u8(site) for site in DYNAMIC_VOLUME_PUSHES),
             DYNAMIC_VOLUME_OPCODES)

    direct = b.direct_sites()
    ck.equal("wave.direct_names", {s: n for s, (n, _v) in direct.items()},
             {s: (w[1] if w else None) for s, (w, _v) in DIRECT_SITES.items()}, Checker.brief)
    ck.equal("wave.direct_volumes", {s: v for s, (_n, v) in direct.items()},
             {s: (v[1] if v else None) for s, (_w, v) in DIRECT_SITES.items()}, Checker.brief)

    named = sorted({n for n, _v in sites.values() if n and "%" not in n} |
                   {n for n, _v in direct.values() if n and "%" not in n})
    missing = [n for n in named if not c.resolves(n)]
    ck.check("wave.resolve", not missing,
             f"{len(named) - len(missing)}/{len(named)} literal wave names resolve")
    mismatched = sorted(n for n in named
                        if c.resolves(n) and c.resolves(n) != n)
    ck.equal("wave.case_mismatch", tuple(mismatched), CASE_MISMATCHED,
             Checker.brief)

    used_ids = sorted({v for _n, v in sites.values() if v is not None and v >= 0} |
                      {v for _n, v in direct.values() if v is not None and v >= 0})
    ck.check("wave.volume_ids_defined",
             all(i in c.volumes for i in used_ids),
             f"{len(used_ids)} distinct ids, all defined in Info.lcl")
    ck.equal("wave.volume_ids", used_ids, VOLUME_IDS_USED)

    named_waves = {n.lower() for n, _v in sites.values() if n and "%" not in n}
    named_waves |= {n.lower() for n, _v in direct.values() if n and "%" not in n}
    named_waves |= {n.lower() + ".wav" for n in c.weapon_waves.values()}
    named_waves |= {n.lower() for _s, n, _vs, _v in VOICE_ARMS}
    named_waves |= {a[1][1].lower() for a in WALK_ARMS.values() if a[1]}
    unreferenced = tuple(sorted(w for w in c.waves
                                if w.lower() not in named_waves))
    ck.equal("wave.unreferenced", unreferenced, WAVES_UNREFERENCED,
             Checker.brief)

    # ---- the weapon's own fire sound -----------------------------------
    ck.equal("weapon.wave_operand", b.mem_operand(WEAPON_WAVE_SITE),
             WEAPON_WAVE_OPERAND, hex)
    ck.equal("weapon.wave_format", b.push_str(WEAPON_WAVE_FORMAT_SITE),
             WEAPON_WAVE_FORMAT)
    ck.check("weapon.wave_volume_is_id", b.u8(WEAPON_WAVE_VOLUME_SITE) == 0x57,
             "push edi -- the weapon id doubles as the volume-control id")
    ck.equal("weapon.info_count", len(c.weapons), INFO_WEAPONS)
    ck.equal("weapon.info_ids", (min(c.weapons), max(c.weapons)),
             (0, INFO_WEAPON_TOP))
    ck.equal("weapon.wave_count", len(c.weapon_waves), INFO_WEAPON_WAVES)
    ck.check("weapon.band", max(c.weapon_waves) < WEAPON_VOLUME_BAND,
             f"weapon ids 0..{max(c.weapon_waves)} fit the 0..49 volume band")
    weapon_missing = sorted(i for i, n in c.weapon_waves.items()
                            if not c.resolves(n + ".wav"))
    ck.equal("weapon.waves_resolve", tuple(weapon_missing), WEAPON_WAVE_TYPO)
    ck.equal("weapon.orphan_wave",
             tuple(i for i in sorted(c.weapon_waves) if i not in c.weapons),
             WEAPON_WAVE_TYPO)

    # ---- the pain voice -------------------------------------------------
    ck.equal("voice.species_operand", b.mem_operand(VOICE_SPECIES_SITE),
             VOICE_SPECIES_OPERAND, hex)
    ck.equal("voice.arms", b.voice_arms(),
             [(name, volume) for _s, name, _vs, volume in VOICE_ARMS])
    ck.check("voice.alien_shares_human_ids",
             {v for n, v in b.voice_arms() if n.startswith("S_ALI")} ==
             {v for n, v in b.voice_arms() if n.startswith("S_HUM")},
             "the alien scream is scaled by the human ids 56..58")
    ck.equal("voice.cursors",
             tuple(len([r for r in b.absolute_refs(cursor)
                        if b.text_lo <= r < b.text_hi])
                   for cursor in (VOICE_CURSOR_HUMAN, VOICE_CURSOR_ALIEN)),
             VOICE_CURSOR_REFS)
    voiced = {v for _n, v in b.voice_arms()} | set(used_ids)
    ck.equal("voice.unused_ids",
             tuple(i for i in sorted(c.volumes)
                   if i not in voiced and 50 <= i < 62), VOLUME_IDS_UNUSED)

    # ---- the walk sound -------------------------------------------------
    ck.equal("walk.type_offset", b.u8(WALK_TYPE_SITE + 2), UNIT_TYPE_OFFSET, hex)
    ck.equal("walk.bound", b.cmp_imm(WALK_BOUND_SITE), WALK_BOUND)
    arms = b.walk_arms()
    ck.equal("walk.arm_count", len(arms), len(WALK_ARMS))
    ck.equal("walk.types", {a: t for a, (t, _w, _v, _p) in arms.items()},
             {a: t for a, (t, _w, _v, _p) in WALK_ARMS.items()}, Checker.brief)
    ck.equal("walk.waves", {a: w for a, (_t, w, _v, _p) in arms.items()},
             {a: (w[1] if w else None) for a, (_t, w, _v, _p) in WALK_ARMS.items()}, Checker.brief)
    ck.equal("walk.volumes", {a: v for a, (_t, _w, v, _p) in arms.items()},
             {a: (v[1] if v else None) for a, (_t, _w, v, _p) in WALK_ARMS.items()}, Checker.brief)
    ck.equal("walk.periods", {a: p for a, (_t, _w, _v, p) in arms.items()},
             {a: (p[1] if p else None) for a, (_t, _w, _v, p) in WALK_ARMS.items()}, Checker.brief)
    ck.check("walk.silent_types",
             WALK_SILENT_ARM in arms
             and len(arms[WALK_SILENT_ARM][0]) == WALK_SILENT_TYPES,
             f"{WALK_SILENT_TYPES} unit types have no walk sound")
    ck.equal("walk.stray_volume_id",
             tuple(sorted(v for _t, _w, v, _p in arms.values()
                          if v is not None and v < WEAPON_VOLUME_BAND)),
             WALK_STRAY_VOLUME)

    # ---- ambience: present, never fed ----------------------------------
    for slot, expected in zip(AMBIENCE_SLOTS, AMBIENCE_SLOT_REFS):
        refs = [r for r in b.absolute_refs(slot) if b.text_lo <= r < b.text_hi]
        ck.equal(f"ambience.slot_{slot:08x}", len(refs), expected)
    ck.equal("ambience.stub", b.call_target(AMBIENCE_STUB_SITE), AMBIENCE_STUB, hex)
    ck.check("ambience.stub_body",
             b.u8(AMBIENCE_STUB) == 0xB8 and b.u32(AMBIENCE_STUB + 1) == 1
             and b.u8(AMBIENCE_STUB + 5) == 0xC3,
             "mov eax, 1; ret")
    present = [n for n in AMBIENCE_FILES if c.resolves(n)]
    ck.equal("ambience.files_shipped", len(present), len(AMBIENCE_FILES))
    ck.check("ambience.files_unnamed",
             _names_string(b, AMBIENCE_CONTROL) and
             not any(_names_string(b, n) for n in AMBIENCE_FILES),
             f"the same search finds {AMBIENCE_CONTROL} and none of the ten")

    # ---- speech, briefing, music ---------------------------------------
    for site in SPEECH_FORMAT_SITES:
        ck.equal(f"speech.format_{site:08x}", b.push_str(site), SPEECH_FORMAT)
    ck.equal("speech.dirs", tuple(sorted(c.speech)), SPEECH_SUBDIRS)
    ck.check("speech.files", all(c.speech[d] for d in c.speech),
             f"{sum(len(v) for v in c.speech.values())} speech waves")
    for site in BRIEFING_FORMAT_SITES:
        ck.equal(f"briefing.format_{site:08x}", b.push_str(site), BRIEFING_FORMAT)
    ck.check("briefing.files", len(c.briefing) > 0,
             f"{len(c.briefing)} briefing waves")
    ck.equal("extro.format", b.push_str(EXTRO_FORMAT_SITE), EXTRO_FORMAT)
    ck.equal("cd.device", b.string(b.mov_imm32(CD_DEVICE_SITE) or 0), CD_DEVICE)

    # ---- the blob pool ---------------------------------------------------
    ck.equal("blob.label", b.push_str(BLOB_LABEL_SITE), BLOB_LABEL)
    ck.equal("blob.bytes", b.push_imm(BLOB_BYTES_SITE), BLOB_BYTES, hex)
    for site in BLOB_SLOTS_SITES:
        ck.equal(f"blob.slots_{site:08x}", b.cmp_imm(site), BLOB_SLOTS)
    for site in BLOB_STRIDE_SITES:
        ck.equal(f"blob.stride_{site:08x}", b.add_imm(site), BLOB_STRIDE)
    ck.check("blob.pool_fits",
             b.push_imm(BLOB_BYTES_SITE) ==
             (b.cmp_imm(BLOB_SLOTS_SITES[0]) + 1) * b.add_imm(BLOB_STRIDE_SITES[0]),
             "450 records plus one spare of 88 bytes = 0x9B08")

    # ---- the constructor -------------------------------------------------
    for site, (arg, offset) in sorted(BLOB_CTOR_STORES.items()):
        ck.equal(f"ctor.arg{arg:02d}", _store_offset(b, site), offset, hex)
    ck.check("ctor.guard", b.u8(BLOB_CTOR_GUARD_SITE) == 0x8A
             and b.u8(BLOB_CTOR_GUARD_SITE + 3) == 0x28,
             "arg10 is read before the prologue and a zero aborts the call")
    ck.equal("ctor.modelless",
             tuple(b.cmp_imm(s) for s in BLOB_CTOR_MODELLESS_SITES),
             BLOB_CTOR_MODELLESS)
    ck.equal("ctor.lookup", b.call_target(BLOB_LOOKUP_SITE), BLOB_LOOKUP, hex)
    ck.equal("ctor.lookup_error", b.push_str(BLOB_LOOKUP_ERROR_SITE),
             BLOB_LOOKUP_ERROR)
    ck.check("ctor.lookup_aborts",
             b.cmp_imm(BLOB_LOOKUP_TEST_SITE) == -1 and
             b.u8(BLOB_LOOKUP_TEST_SITE + 3) == 0x75,
             "a failed model lookup returns -1 without touching the pool")
    ck.equal("ctor.calls", len(b.calls_to(BLOB_CTOR)), BLOB_CTOR_CALLS)

    calls = b.blob_calls()
    ck.equal("blob.models", {s: m for s, (m, _c, _k, _l) in calls.items()},
             {s: (m[1] if m else None) for s, (m, _c, _k, _l) in BLOB_CALLS.items()}, Checker.brief)
    ck.equal("blob.classes", {s: v for s, (_m, v, _k, _l) in calls.items()},
             {s: (v[1] if v else None) for s, (_m, v, _k, _l) in BLOB_CALLS.items()}, Checker.brief)
    ck.equal("blob.kinds", {s: v for s, (_m, _c, v, _l) in calls.items()},
             {s: (v[1] if v else None) for s, (_m, _c, v, _l) in BLOB_CALLS.items()}, Checker.brief)
    ck.equal("blob.lives", {s: v for s, (_m, _c, _k, v) in calls.items()},
             {s: (v[1] if v else None) for s, (_m, _c, _k, v) in BLOB_CALLS.items()}, Checker.brief)
    kinds = sorted({v for _m, _c, v, _l in calls.values() if isinstance(v, int)})
    ck.check("blob.kinds_in_range", max(kinds) <= BLOB_KIND_BOUND,
             f"{len(kinds)} distinct kinds, max {max(kinds)} <= {BLOB_KIND_BOUND}")
    ck.check("blob.class_values",
             {v for _m, v, _k, _l in calls.values() if isinstance(v, int)} <= {0, 1, 2, 3},
             "classes 0..3 only")
    ck.check("blob.modelless_scratch",
             all(m == BLOB_NAME_SCRATCH
                 for m, cls, _k, _l in calls.values() if cls in BLOB_CTOR_MODELLESS),
             "classes 2 and 3 all pass the same unused buffer")

    models = sorted({m for m, _c, _k, _l in calls.values() if isinstance(m, str)})
    ck.equal("blob.model_count", len(models), BLOB_MODEL_COUNT)
    everywhere = [m for m in models
                  if len(c.worlds_with(m)) == BLOB_MODEL_WORLDS]
    ck.equal("blob.models_everywhere", len(everywhere), BLOB_MODELS_EVERYWHERE)
    rare = {m: tuple(c.worlds_with(m)) for m in models
            if len(c.worlds_with(m)) != BLOB_MODEL_WORLDS}
    ck.equal("blob.models_rare", rare, BLOB_MODELS_RARE, Checker.brief)

    # ---- the update switch ----------------------------------------------
    ck.equal("update.delay_field", b.u8(BLOB_DELAY_SITE + 2), BLOB_DELAY, hex)
    ck.equal("update.life_field", b.u8(BLOB_LIFE_SITE + 2), BLOB_LIFE, hex)
    ck.equal("update.kind_field", b.u8(BLOB_KIND_SITE + 2), BLOB_KIND, hex)
    immortal = b.cmp_imm(BLOB_IMMORTAL_SITE)
    ck.equal("update.immortal", immortal & 0xFF if immortal is not None else None,
             BLOB_IMMORTAL, hex)
    ck.equal("update.kind_bound", b.cmp_imm(BLOB_KIND_BOUND_SITE),
             BLOB_KIND_BOUND, hex)
    table = b.jump_table(BLOB_UPDATE_TABLE, BLOB_UPDATE_ENTRIES)
    ck.equal("update.arm_count", len(set(table)), len(UPDATE_ARMS))
    ck.equal("update.arms",
             {arm: tuple(k for k, a in enumerate(table) if a == arm)
              for arm in sorted(set(table), key=lambda a: table.index(a))},
             UPDATE_ARMS, Checker.brief)
    ck.equal("update.gravity_high", b.add_imm(BLOB_GRAVITY_HIGH_SITE),
             BLOB_GRAVITY_HIGH)
    ck.equal("update.gravity_low", b.add_imm(BLOB_GRAVITY_LOW_SITE),
             BLOB_GRAVITY_LOW)
    ck.equal("update.gravity_split", b.cmp_imm(BLOB_GRAVITY_SPLIT_SITE),
             BLOB_GRAVITY_SPLIT)

    # ---- who triggers a blob --------------------------------------------
    creators = b.blob_creators()
    ck.equal("trigger.creators", len(creators), BLOB_CREATORS)
    foreign = {}
    for creator in creators:
        for site in b.calls_to(creator):
            if not (ANIMATIONS_LO <= site < ANIMATIONS_HI) and \
               not (BLOBS_LO <= site < BLOBS_HI):
                foreign[site] = creator
    ck.equal("trigger.foreign", sorted(foreign), sorted(BLOB_FOREIGN_CALLERS),
             lambda xs: ", ".join(f"0x{v:08X}" for v in xs))

    ck.equal("trigger.creator_set", tuple(sorted(creators)),
             tuple(sorted(BLOB_CREATOR_NAMES)), Checker.brief)
    recovered = b.creator_names()
    ck.equal("trigger.names", recovered,
             {k: (v[1] if v else None) for k, v in BLOB_CREATOR_NAMES.items()},
             Checker.brief)
    ck.equal("trigger.named_count",
             sum(1 for v in recovered.values() if v), BLOB_CREATOR_NAMED)
    ck.equal("wave.path_format", b.push_str(PATH_FORMAT_SITE), PATH_FORMAT)

    # ---- the embedded object_3d (docs/30) ------------------------------
    ck.equal("object.stride_shift", b.u8(WORLD_OBJECT_STRIDE_SITE + 2),
             WORLD_OBJECT_STRIDE_SHIFT)
    ck.equal("object.size", 1 << b.u8(WORLD_OBJECT_STRIDE_SITE + 2),
             OBJECT_3D_SIZE, hex)
    ck.equal("object.cap", b.cmp_imm(WORLD_OBJECT_CAP_SITE), WORLD_OBJECT_CAP)
    ck.equal("object.lookup", b.call_target(WORLD_OBJECT_LOOKUP_SITE),
             BLOB_LOOKUP, hex)
    ck.equal("object.radius_import", b.u32(WORLD_OBJECT_RADIUS_SITE + 2),
             0x004F9F38, hex)
    ck.equal("object.check_in", b.call_target(CHECK_IN_SITE), CHECK_IN, hex)
    ck.check("object.check_in_arg",
             b.u8(CHECK_IN_SITE - 4) == 0x8D and b.u8(CHECK_IN_SITE - 2) == OBJECT_3D_AT,
             "aCheckInBlobObjects passes blob + 4, the object it embeds")
    ordinal = b.string(b.push_imm(CHECK_IN_ORDINAL_SITE) or 0, 40)
    ck.equal("object.check_in_ordinal", ordinal,
             f"Function Id {CHECK_IN_ORDINAL} not found!")
    # aGetMemory's one allocation is an indirect call to the CRT import, and
    # the routine it lands in is never followed by a fill: the block comes
    # back exactly as malloc left it.
    ck.equal("object.allocator_does_not_clear",
             (b.pe.bytes_at(ALLOCATOR, len(ALLOCATOR_ENTRY)),
              b.u8(ALLOCATOR_CALL_SITE), b.u8(ALLOCATOR_CALL_SITE + 1),
              b.u32(ALLOCATOR_CALL_SITE + 2)),
             (ALLOCATOR_ENTRY, 0xFF, 0x15, ALLOCATOR_IMPORT),
             lambda v: f"call dword [0x{v[3]:08X}] at the one allocation site")
    # the blob constructor and the world-object builder agree, four bytes apart
    world = {offset for offset in WORLD_OBJECT_STORES.values()}
    blob = {offset - OBJECT_3D_AT for _arg, offset in BLOB_CTOR_STORES.values()
            if offset - OBJECT_3D_AT in world}
    ck.equal("object.builder_stores",
             {site: _store_offset(b, site) for site in WORLD_OBJECT_STORES},
             WORLD_OBJECT_STORES, Checker.brief)
    world_fields = {_store_offset(b, site) for site in WORLD_OBJECT_STORES}
    shared = world_fields - {0x0C}
    from_blob = {offset - OBJECT_3D_AT
                 for _a, offset in BLOB_CTOR_STORES.values()}
    from_blob.add(_plus(_store_offset(b, BLOB_ZERO_SITE), -OBJECT_3D_AT))
    ck.equal("object.shared_fields", sorted(shared - from_blob), [],
             Checker.brief)
    ck.equal("object.blob_zero", _store_offset(b, BLOB_ZERO_SITE), 0x20, hex)
    ck.equal("object.radius_field",
             _store_offset(b, WORLD_OBJECT_RADIUS_STORE), 0x0C, hex)
    ck.equal("object.radius_only_world", sorted(world_fields - from_blob),
             [0x0C], Checker.brief)

    # ---- the zoom bob: one atlas, 8x8 tiles of 32x32 -------------------
    ck.equal("zoom.draw_name", b.push_str(ZOOM_DRAW_NAME_SITE), ZOOM_DRAW_NAME)
    ck.equal("zoom.draw_ordinal", b.string(b.push_imm(ZOOM_DRAW_ORDINAL_SITE) or 0, 40),
             "Function Id 63 not found!")
    ck.equal("zoom.classes", tuple(b.cmp_imm(s) for s in ZOOM_CLASS_SITES),
             ZOOM_CLASSES)
    ck.equal("zoom.blend_slots",
             {slot: len([r for r in b.absolute_refs(slot)
                         if b.text_lo <= r < b.text_hi])
              for slot in ZOOM_BLEND_SLOTS}, ZOOM_BLEND_SLOTS, Checker.brief)
    ck.equal("zoom.row_field", b.u8(ZOOM_ROW_SITE + 2), 0x24, hex)
    ck.equal("zoom.col_field", b.u8(ZOOM_COL_SITE + 2), 0x26, hex)
    ck.equal("zoom.size_field", b.u8(ZOOM_SIZE_SITE + 2), BLOB_PHASE, hex)
    ck.equal("zoom.dead_field", b.u8(ZOOM_DEAD_SITE + 2), 0x28, hex)
    ck.equal("zoom.tile_shift", b.u8(TILE_SHIFT_SITE + 2), TILE_SHIFT)
    ck.equal("zoom.tile_span", struct.unpack("<d", b.pe.bytes_at(TILE_SPAN_CONST, 8))[0],
             TILE_SPAN)
    ck.check("zoom.tile_size", (1 << b.u8(TILE_SHIFT_SITE + 2)) == ATLAS_TILE
             and -TILE_SPAN + 1 == ATLAS_TILE,
             f"the quad spans one {ATLAS_TILE}x{ATLAS_TILE} tile")
    ck.equal("zoom.size_shift", b.u8(SIZE_SCALE_SITE + 2), SIZE_SCALE_SHIFT)
    for site in ATLAS_NAME_SITES:
        ck.equal(f"zoom.atlas_name_{site:08x}", b.push_str(site), ATLAS_TEXTURE)
    ck.equal("zoom.atlas_lookup_ordinal",
             b.string(b.push_imm(ATLAS_LOOKUP_ORDINAL_SITE) or 0, 40),
             "Function Id 66 not found!")
    atlas = c.texture(ATLAS_TEXTURE)
    ck.equal("zoom.atlas_worlds", len(atlas), BLOB_MODEL_WORLDS)
    ck.check("zoom.atlas_square", all(w == ATLAS_SIZE and h == ATLAS_SIZE
                                      for w, h in atlas.values()),
             f"{ATLAS_TEXTURE} is {ATLAS_SIZE}x{ATLAS_SIZE} in every world set")
    width = next(iter(atlas.values()))[0] if atlas else 0
    ck.equal("zoom.atlas_grid", width // (1 << b.u8(TILE_SHIFT_SITE + 2)),
             ATLAS_GRID)
    sprite = b.sprite_params()
    ck.equal("zoom.sprite_params", sprite,
             {s: tuple(None if f is None else f[1] for f in fields)
              for s, fields in BLOB_SPRITE.items()}, Checker.brief)
    rows = sorted({r for r, _c, _z in sprite.values() if r is not None})
    ck.check("zoom.rows_in_grid", rows and all(0 <= r < ATLAS_GRID for r in rows),
             f"{len(rows)} distinct atlas rows, all inside the "
             f"{ATLAS_GRID}x{ATLAS_GRID} grid")
    cols = {c for _r, c, _z in sprite.values() if c is not None}
    ck.check("zoom.cols_start_left", cols <= {0, 3},
             "every sprite starts at the left of its row but one")
    sizes = sorted({z for _r, _c, z in sprite.values() if z is not None})
    ck.equal("zoom.sizes", (min(sizes), max(sizes)), SPRITE_SIZE_RANGE)

    # ---- the 78 kinds ---------------------------------------------------
    kind_arms = b.kind_arms()
    ck.equal("kind.count", _plus(b.cmp_imm(BLOB_KIND_BOUND_SITE), 1), KIND_COUNT)
    ck.equal("kind.spawns", {k: v for k, v in b.kind_spawns().items() if v},
             KIND_SPAWNS, Checker.brief)
    for name, (site, how, want) in sorted(KIND_EVIDENCE.items()):
        got = {"bytes": lambda site: b.pe.bytes_at(site, len(want)),
               "mov_imm32": b.mov_imm32, "word_store": b.word_store,
               "word_add": b.word_add,
               "word_imm": b.word_imm, "byte_imm": b.byte_imm,
               "push": b.push_imm, "call": b.call_target}[how](site)
        ck.equal(f"kind.{name}", got, want)
    for kind, site in sorted(KIND_SEEKERS.items()):
        ck.equal(f"kind.seeker_{kind}", b.call_target(site), UNIT_MAP_LOOKUP, hex)
    for site, (imm_site, base, produces) in sorted(KIND_COMPUTED.items()):
        decoded = b.add_imm(imm_site)
        ck.equal(f"kind.computed_{site:08x}",
                 tuple(range(decoded, decoded + 2)), produces)
    literal = {v for _m, _c, v, _l in calls.values() if isinstance(v, int)}
    computed = {k for _s, (_i, _b, ks) in KIND_COMPUTED.items() for k in ks}
    morph_imm = b.byte_imm(KIND_MORPH_SITE)
    morph = {morph_imm[1] if morph_imm else None}
    ck.equal("kind.unreachable",
             tuple(k for k in range(KIND_COUNT)
                   if k not in literal | computed | morph), KIND_UNREACHABLE)

    # ---- what gates a sound (the blocking sequence loop) ---------------
    ck.equal("play.frame_tick_sites", len(b.calls_to(FRAME_TICK)), FRAME_TICK_SITES)
    ck.equal("play.flags", b.play_sites(),
             {s: (f, v) for s, (f, v, _t) in PLAY_SITES.items()}, Checker.brief)
    flags = [v for _f, v in b.play_sites().values()]
    ck.equal("play.looping", flags.count(PLAY_LOOPING), PLAY_LOOPING_SITES)
    entries = sorted(b.call_entries())
    ticks = {}
    for site in PLAY_SITES:
        entry = entries[bisect.bisect_right(entries, site) - 1]
        ticks[site] = b.frame_ticks_before(site, entry)
    ck.equal("play.ticks", ticks, {s: t for s, (_f, _v, t) in PLAY_SITES.items()},
             Checker.brief)
    histogram = {n: sum(1 for t in ticks.values() if t == n)
                 for n in range(PLAY_TICKS_MAX + 1)}
    ck.check("play.tick_histogram", histogram == PLAY_TICK_HISTOGRAM
             and sum(histogram.values()) == len(PLAY_SITES),
             f"{histogram} -- every one of the {len(PLAY_SITES)} sites accounted "
             f"for, and none waits longer than {PLAY_TICKS_MAX} frame ticks")
    ck.equal("play.ticks_zero", histogram[0], PLAY_TICKS_ZERO)

    # ---- explosion.wav is the overheat catastrophe (docs/22 sec.8) -----
    ck.equal("overheat.callers", tuple(b.calls_to(WEAPON_EXPLOSION)),
             OVERHEAT_SITES, lambda xs: _hexlist(xs))
    ck.equal("overheat.owner",
             sum(1 for s in b.calls_to(WEAPON_EXPLOSION)
                 if OVERHEAT <= s < OVERHEAT + 0x200), len(OVERHEAT_SITES))

    # ---- the three weapon switches --------------------------------------
    ck.equal("weapon.muzzle_bound", b.cmp_imm(MUZZLE_BOUND_SITE),
             MUZZLE_SWITCH[1] - 1, hex)
    ck.equal("weapon.impact_bound", b.cmp_imm(IMPACT_BOUND_SITE),
             IMPACT_SWITCH[1] - 1, hex)
    ck.equal("weapon.impact_sound_bound", b.cmp_imm(IMPACT_SOUND_BOUND_SITE),
             IMPACT_SOUND_SWITCH[1] - 1, hex)
    ck.equal("weapon.muzzle", b.weapon_effects(MUZZLE_SWITCH, WEAPON_MUZZLE),
             WEAPON_MUZZLE, Checker.brief)
    ck.equal("weapon.impact", b.weapon_effects(IMPACT_SWITCH, WEAPON_IMPACT),
             WEAPON_IMPACT, Checker.brief)
    ck.equal("weapon.impact_sound", b.weapon_sounds(), WEAPON_IMPACT_SOUND,
             Checker.brief)
    decoded = (list(b.weapon_effects(MUZZLE_SWITCH, WEAPON_MUZZLE).values()) +
               list(b.weapon_effects(IMPACT_SWITCH, WEAPON_IMPACT).values()))
    ck.check("weapon.calls_are_creators",
             all(target in creators for _arm, calls in decoded
                 for _site, target in calls),
             "every arm's call lands on a blob creator")
    ck.check("weapon.calls_inside_arm",
             all(arm <= site < arm + 400 for arm, calls in decoded
                 for site, _t in calls),
             "every call site lies inside the arm its switch entry selects")
    ck.equal("weapon.switch_range",
             (_plus(b.cmp_imm(MUZZLE_BOUND_SITE), MUZZLE_SWITCH[3]),
              _plus(b.cmp_imm(IMPACT_BOUND_SITE), IMPACT_SWITCH[3]),
              _plus(b.cmp_imm(IMPACT_SOUND_BOUND_SITE), IMPACT_SOUND_SWITCH[3])),
             WEAPON_SWITCH_TOP)

    # ---- CreateBGB -------------------------------------------------------
    ck.equal("bgb.type_bound", b.cmp_imm(BGB_TYPE_BOUND_SITE), BGB_TYPE_BOUND)
    ck.equal("bgb.arms", b.bgb_arms(), BGB_ARMS, Checker.brief)
    ck.equal("bgb.tick_bound", b.cmp_imm(BGB_TICK_BOUND_SITE), BGB_TYPE_BOUND)
    ck.equal("bgb.tick_arms", b.bgb_tick_arms(), BGB_TICK_ARMS, Checker.brief)

    # ---- .cha notes never drive an effect --------------------------------
    ck.equal("notes.callback_sites",
             tuple(b.calls_to(NOTE_CALLBACK_REGISTER)), (NOTE_CALLBACK_SITE,),
             lambda xs: _hexlist(xs))

    # ---- the joint-angle buffer (docs/28 7.8, docs/30 2.12) --------------
    eng = Engine(root, ENG3D_DLL)
    glide = Engine(root, ENG3D_GLIDE)

    # The buffer is read by one idiom, present in both renderer builds and in
    # none of the three hosts: they write it, they never read it back.
    sites = eng.occurrences(JOINT_IDIOM)
    ck.equal("joint.idiom_sites", len(sites), JOINT_IDIOM_SITES)
    ck.equal("joint.idiom_glide", len(glide.occurrences(JOINT_IDIOM)),
             JOINT_IDIOM_SITES)
    ck.equal("joint.idiom_hosts",
             {name: count_pattern(os.path.join(root, name), JOINT_IDIOM)
              for name in HOST_BINARIES},
             HOST_IDIOM_COUNTS, Checker.brief)

    # Each site sits in the handler of one render opcode.  Bounding by the
    # nearest preceding table entry is what makes the owner unambiguous.
    handlers = {slot: eng.handler(slot) for slot in sorted(prototyp.OPCODES)}
    entries = sorted(set(handlers.values()))
    owners = {entries[bisect.bisect_right(entries, site) - 1] for site in sites}
    ck.equal("joint.handler_slots",
             tuple(slot for slot, addr in sorted(handlers.items())
                   if addr in owners),
             JOINT_SLOTS)
    # The other reading of the same bytes has its own idiom, and the two slots
    # that carry it come out of the DLL the same way.
    matrix_sites = set(eng.occurrences(MATRIX_IDIOM))
    ck.equal("joint.matrix_idiom_sites", len(matrix_sites), MATRIX_IDIOM_SITES)
    ck.equal("joint.matrix_slots",
             tuple(slot for slot in sorted(prototyp.OPCODES)
                   if eng.handler(slot) in matrix_sites),
             MATRIX_SLOTS)
    # ... and our own opcode table says exactly those take an ``anim`` operand.
    ck.equal("joint.opcode_table",
             tuple(slot for slot, (_name, kind) in sorted(prototyp.OPCODES.items())
                   if kind == "anim"),
             JOINT_SLOTS)

    # The angles are binary degrees indexing TRIG.IMG (docs/70): the mask and
    # the two table addresses come out of the builder's own instructions, and
    # the cosine window is a quarter turn into the same table.
    ck.equal("joint.angle_mask",
             tuple(eng.and_imm32(site) for site in ANGLE_MASK_SITES),
             (ANGLE_MASK,) * len(ANGLE_MASK_SITES))
    sine, cosine = eng.sib_disp32(TRIG_SIN_SITE), eng.sib_disp32(TRIG_COS_SITE)
    ck.equal("joint.trig_tables", (sine, cosine), (TRIG_SIN, TRIG_COS),
             _hexlist)
    mask = eng.and_imm32(ANGLE_MASK_SITES[0])
    window = (cosine - sine) // 2 if (sine is not None and cosine is not None) else None
    ck.equal("joint.trig_quarter",
             (window, mask + 1 if mask is not None else None),
             (TRIG_QUARTER, 4 * TRIG_QUARTER),
             lambda v: f"cosine window {v[0]} entries into a {v[1]}-unit circle")

    # Nothing else in the renderer reaches the record: every reference to the
    # "object being drawn" is accounted for.
    ck.equal("joint.current_object_refs", eng.absolute_refs(CURRENT_OBJECT),
             CURRENT_OBJECT_REFS)

    # Both hosts null the pointer word, so the inline area is always the one
    # the handlers fall back to.
    world_ptr = _store_offset(b, WORLD_OBJECT_PTR_SITE)
    blob_ptr = _store_offset(b, BLOB_ZERO_SITE)
    ck.equal("joint.pointer_zeroed",
             (world_ptr,
              blob_ptr - OBJECT_3D_AT if blob_ptr is not None else None),
             (JOINT_PTR, JOINT_PTR), _hexlist)

    # One export hands the buffer out and there is no setter; its whole body
    # says a clone's joint array begins just past the embedded object.
    exports = eng.exports()
    ck.equal("joint.getter_ordinal",
             tuple(sorted(o for o, (name, _a) in exports.items()
                          if "joint" in name)),
             (JOINT_GETTER_ORDINAL,))
    ck.equal("joint.getter_name",
             (exports.get(JOINT_GETTER_ORDINAL) or (None,))[0], JOINT_GETTER)
    for build in (eng, glide):
        found = build.exports().get(JOINT_GETTER_ORDINAL)
        body = None
        if found:
            entry = found[1]
            body = build.pe.bytes_at(entry + 4 + 5 + build.pe.i32(entry + 5),
                                     len(JOINT_GETTER_BODY))
        ck.equal(f"joint.getter_body_{build.name.split('.')[0].lower()}",
                 body, JOINT_GETTER_BODY,
                 lambda v: v.hex() if isinstance(v, bytes) else str(v))

    # ---- what the shipped data asks for ---------------------------------
    ck.equal("joint.operands", c.joint_operands, JOINT_OPERANDS, Checker.brief)
    ck.equal("joint.operands_partinfo", c.partinfo_operands,
             JOINT_OPERANDS_PARTINFO, Checker.brief)
    used = sorted({op for buckets in
                   list(c.joint_operands.values()) + list(c.partinfo_operands.values())
                   for op in buckets})
    ck.equal("joint.operand_set", tuple(used), JOINT_OFFSETS)
    ck.equal("joint.buffer_span",
             ((max(used) + JOINT_TRIPLE) if used else 0,
              OBJECT_3D_SIZE - JOINT_INLINE),
             (JOINT_BUFFER_BYTES, JOINT_BUFFER_ROOM),
             lambda v: f"{v[0]} bytes of Euler triples in {v[1]}")
    ck.equal("joint.families", (c.family_records, c.family_mixed),
             (JOINT_FAMILIES, JOINT_FAMILIES_MIXED),
             lambda v: f"{len(v[0])} entries, {v[1]} mixed")
    names = {"matrix": 0, "euler": 0, "other": 0}
    for kind in c.family.values():
        names[kind] += 1
    ck.equal("joint.family_names", names, JOINT_FAMILY_NAMES, Checker.brief)

    # Everything the missions place reads its angles out of the buffer; the
    # two exceptions carry no transform opcode at all.
    placed: dict[str, int] = {}
    for name in c.lev_specials:
        kind = c.family.get(name, "?")
        placed[kind] = placed.get(kind, 0) + 1
    ck.equal("joint.lev_specials", placed, LEV_SPECIAL_FAMILIES, Checker.brief)
    ck.equal("joint.lev_special_other",
             tuple(sorted(n for n in c.lev_specials
                          if c.family.get(n) == "other")),
             LEV_SPECIAL_OTHER)

    # The matrix reading belongs to Charisma: every mesh a .cho names is in
    # that family or in no container at all, and no joint-family name is.
    ck.equal("joint.cho_models", c.cho_models, CHO_MODELS)
    ck.equal("joint.cho_meshes", len(c.cho_meshes), CHO_MESHES)
    mesh_families: dict[str, int] = {}
    for name in c.cho_meshes:
        key = c.family.get(name, "?")
        mesh_families[key] = mesh_families.get(key, 0) + 1
    ck.equal("joint.cho_mesh_families", mesh_families, CHO_MESH_FAMILIES,
             Checker.brief)
    ck.equal("joint.cho_orphans",
             tuple(sorted(n for n, k in c.family.items()
                          if k == "matrix" and n not in c.cho_meshes)),
             CHO_ORPHANS, Checker.brief)

    # World objects get triple 0 and nothing else, so every articulated
    # fitting the missions place draws its parts from an unwritten triple.
    ck.equal("joint.part_models", len(c.model_joints), JOINT_PART_MODELS)
    placed = {n: k for n, k in c.lev_placements.items() if n in c.model_joints}
    ck.equal("joint.part_models_placed", len(placed), JOINT_PART_PLACED_NAMES)
    ck.equal("joint.part_placements", sum(placed.values()), JOINT_PART_PLACED)

    # The three arms that write the buffer write their own model's joints.
    models: dict[int, tuple] = {}
    for _site, (model, _cls, kind, _life) in b.blob_calls().items():
        if kind in JOINT_KINDS and isinstance(model, str):
            models[kind] = tuple(sorted(set(models.get(kind, ())) | {model}))
    ck.equal("joint.kind_models", models,
             {k: (v[0],) for k, v in sorted(JOINT_KINDS.items())}, Checker.brief)
    ck.equal("joint.kind_places",
             {k: c.model_joints.get(v[0], ()) for k, v in sorted(JOINT_KINDS.items())},
             {k: v[1] for k, v in sorted(JOINT_KINDS.items())}, Checker.brief)
    ck.equal("joint.kind_writes",
             {k: _kind_writes(k) for k in sorted(JOINT_KINDS)},
             {k: v[2] for k, v in sorted(JOINT_KINDS.items())}, Checker.brief)
    # Every offset an arm writes is a component of a triple its model asks for:
    # the start, the middle or the end, and nothing in between.
    landings = {}
    for kind, (model, _places, _writes) in sorted(JOINT_KINDS.items()):
        triples = (0,) + tuple(c.model_joints.get(model, ()))
        for off in _kind_writes(kind):
            deltas = [off - JOINT_INLINE - t for t in triples]
            landings[(kind, off)] = sorted(d for d in deltas
                                           if d in (0, 2, JOINT_TRIPLE - 2))
    ck.check("joint.writes_are_components",
             bool(landings) and all(len(v) == 1 for v in landings.values()),
             f"{len(landings)} stores, each exactly one component of one triple")


    return ck


def _kind_writes(kind: int) -> tuple[int, ...]:
    """The ``object_3d`` offsets the pinned evidence for *kind* stores into."""
    out = set()
    for key, (_site, how, want) in KIND_EVIDENCE.items():
        if not key.startswith(f"k{kind}."):
            continue
        if how in ("word_store", "word_add"):
            out.add(want - OBJECT_3D_AT)
        elif how == "word_imm":
            out.add(want[0] - OBJECT_3D_AT)
    return tuple(sorted(out))


def _creator(address: int) -> str:
    pinned = BLOB_CREATOR_NAMES.get(address)
    return pinned[1] if pinned else f"0x{address:08X}"


def _store_offset(b: Binary, site: int) -> int | None:
    """The displacement of the pinned ``mov [esi + d8], r`` stores."""
    op = b.u8(site)
    if op in (0x88, 0x89, 0xC6, 0xC7):
        modrm = b.u8(site + 1)
        if modrm & 0xC0 == 0x40:
            return b.u8(site + 2)
    if op == 0x66:
        modrm = b.u8(site + 2)
        if modrm & 0xC0 == 0x40:
            return b.u8(site + 3)
    return None


def _names_string(b: Binary, text: str) -> bool:
    return b.pe.data.find(text.encode("latin-1") + b"\0") >= 0


def _plus(value: int | None, delta: int) -> int | None:
    """``value + delta``, or None when the decode failed.

    Decoders return None when the bytes at a pinned address are not the
    instruction the address is documented to hold. Propagating that keeps the
    check reporting its own name instead of raising out of ``run_checks``.
    """
    return None if value is None else value + delta


def _hexlist(values) -> str:
    return "[" + ", ".join("None" if v is None else f"0x{v:08X}"
                           for v in values) + "]"


def report_waves(root: str) -> None:
    b = Binary(root)
    c = Corpus(root)
    print("volume  wave                 site        creator")
    for site, (name, volume) in sorted(b.sound_sites().items()):
        shipped = c.resolves(name) if name and "%" not in name else name
        print(f"{'' if volume is None else volume:>6}  {name or '-':<20} "
              f"0x{site:08X}  {shipped or 'MISSING'}")
    print()
    print("walk sounds")
    for arm, (types, wave, volume, period) in sorted(b.walk_arms().items()):
        print(f"  arm 0x{arm:08X}  vol {'' if volume is None else volume:>3}  "
              f"period {'' if period is None else period:>2}  "
              f"{wave or '(silent)':<16} unit types {list(types)}")
    print()
    named = {n for n, _v in b.sound_sites().values() if n and "%" not in n}
    named |= {n for n, _v in b.direct_sites().values() if n and "%" not in n}
    named |= {n + ".wav" for n in c.weapon_waves.values()}
    for arm in b.walk_arms().values():
        if arm[1]:
            named.add(arm[1])
    for _s, name, _vs, _v in VOICE_ARMS:
        named.add(name)
    unreferenced = sorted(w for w in c.waves if w.lower() not in
                          {n.lower() for n in named})
    print(f"{len(unreferenced)} shipped waves no literal in the image names:")
    for name in unreferenced:
        print(f"  {name}")


def report_blobs(root: str) -> None:
    b = Binary(root)
    c = Corpus(root)
    print("site        model          class kind life")
    for site, (model, cls, kind, life) in sorted(b.blob_calls().items()):
        shown = model if isinstance(model, str) else "-"
        print(f"0x{site:08X}  {shown:<14} {'' if cls is None else cls:>5} "
              f"{'' if kind is None else kind:>4} {'' if life is None else life:>4}")
    print()
    print("weapon    muzzle blob                     impact blob")
    for weapon in sorted(set(WEAPON_MUZZLE) | set(WEAPON_IMPACT)):
        name = strings(c.weapons[weapon])[0] if weapon in c.weapons else "?"
        muzzle = WEAPON_MUZZLE.get(weapon, (0, ()))[1]
        impact = WEAPON_IMPACT.get(weapon, (0, ()))[1]
        sound = WEAPON_IMPACT_SOUND.get(weapon)
        print(f"{weapon:>3} {name[:22]:<24} "
              f"{' '.join(_creator(t) for _s, t in muzzle):<30} "
              f"{' '.join(_creator(t) for _s, t in impact):<26} "
              f"{sound[1][1] if sound and sound[1] else ''}")
    print()
    for model in sorted({m for m, _c, _k, _l in b.blob_calls().values()
                         if isinstance(m, str)}):
        worlds = c.worlds_with(model)
        print(f"  {model:<14} {len(worlds)}/{BLOB_MODEL_WORLDS} world sets"
              f"{'' if len(worlds) == BLOB_MODEL_WORLDS else '  ' + ', '.join(worlds)}")


def report_kinds(root: str) -> None:
    b = Binary(root)
    calls = b.blob_calls()
    entries = sorted(b.call_entries())
    owner: dict[int, set[str]] = {}
    klass: dict[int, set[int]] = {}
    for site, (_m, cls, kind, _l) in calls.items():
        if not isinstance(kind, int):
            continue
        creator = entries[bisect.bisect_right(entries, site) - 1]
        owner.setdefault(kind, set()).add(_creator(creator))
        if isinstance(cls, int):
            klass.setdefault(kind, set()).add(cls)
    spawns = b.kind_spawns()
    print("kind  arm         class  spawns                     created by")
    for kind, arm in sorted(b.kind_arms().items()):
        made = " ".join(_creator(t) for t in spawns.get(kind, ()))
        by = ", ".join(sorted(owner.get(kind, ())))
        if not by:
            computed = [ks for _s, (_i, _b, ks) in KIND_COMPUTED.items() if kind in ks]
            by = "(computed)" if computed else (
                "(morph from kind 49)" if kind == KIND_MORPH_TO else "(unreachable)")
        print(f"{kind:>4}  0x{arm:08X}  {str(sorted(klass.get(kind, ()))):>6}  "
              f"{made[:25]:<25}  {by[:70]}")


def report_joints(root: str) -> None:
    eng = Engine(root, ENG3D_DLL)
    c = Corpus(root)
    b = Binary(root)

    print("object_3d +0x1c .. +0x3f, the two readings of the same 36 bytes")
    print(f"  matrix : 3x3 i32 at +0x{JOINT_PTR:02X}      "
          f"{c.family_records['matrix']:>6} render programs, "
          f"{sum(1 for k in c.family.values() if k == 'matrix'):>5} prototypes")
    print(f"  joint  : ptr at +0x{JOINT_PTR:02X}, then     "
          f"{c.family_records['euler']:>6} render programs, "
          f"{sum(1 for k in c.family.values() if k == 'euler'):>5} prototypes")
    print(f"           Euler triples at +0x{JOINT_INLINE:02X}")
    print(f"  neither                     "
          f"{c.family_records['other']:>6} render programs, "
          f"{sum(1 for k in c.family.values() if k == 'other'):>5} prototypes")
    print()

    print("the joint buffer, as the shipped programs address it")
    for offset in JOINT_OFFSETS:
        first = JOINT_INLINE + offset
        print(f"  triple {offset // JOINT_TRIPLE}  anim operand {offset:>2}  "
              f"object +0x{first:02X}/+0x{first + 2:02X}/+0x{first + 4:02X}  "
              f"blob +0x{first + OBJECT_3D_AT:02X}/"
              f"+0x{first + OBJECT_3D_AT + 2:02X}/"
              f"+0x{first + OBJECT_3D_AT + 4:02X}")
    print()

    print("the opcodes that read it")
    handlers = {slot: eng.handler(slot) for slot in sorted(prototyp.OPCODES)}
    for slot in JOINT_SLOTS:
        name = prototyp.OPCODES[slot][0]
        counts = c.joint_operands.get(slot, {})
        part = c.partinfo_operands.get(slot, {})
        used = ", ".join(f"operand {op}: {n}"
                         for op, n in sorted(counts.items())) or "-"
        also = ", ".join(f"operand {op}: {n}"
                         for op, n in sorted(part.items())) or "-"
        print(f"  slot {slot:>2}  0x{handlers[slot]:08X}  {name:<22} "
              f"render {used:<28} partinfo {also}")
    print()

    print("the three update arms that write it")
    for kind, (model, places, _writes) in sorted(JOINT_KINDS.items()):
        stored = _kind_writes(kind)
        print(f"  kind {kind:>2}  {model:<14} joint_place {list(places)!s:<8} "
              f"writes object {_hexlist(stored)}")
    print()
    print(f"angles are binary degrees: mask 0x{eng.and_imm32(ANGLE_MASK_SITES[0]):03X}, "
          f"TRIG.IMG sine at 0x{eng.sib_disp32(TRIG_SIN_SITE):08X}, "
          f"cosine window 0x{eng.sib_disp32(TRIG_COS_SITE):08X} (docs/70)")
    print(f"reads of the buffer in {GAME_EXE}: "
          f"{count_pattern(os.path.join(root, GAME_EXE), JOINT_IDIOM)} "
          f"-- the host writes these fields and never reads them back "
          f"({len(b.blob_calls())} blob calls)")


def report_json(root: str) -> None:
    b = Binary(root)
    c = Corpus(root)
    print(json.dumps({
        "waves": {f"0x{s:08X}": {"name": n, "volume": v}
                  for s, (n, v) in sorted(b.sound_sites().items())},
        "direct": {f"0x{s:08X}": {"name": n, "volume": v}
                   for s, (n, v) in sorted(b.direct_sites().items())},
        "walk": {f"0x{a:08X}": {"types": list(t), "wave": w,
                                "volume": v, "period": p}
                 for a, (t, w, v, p) in sorted(b.walk_arms().items())},
        "volumes": {str(i): v for i, v in sorted(c.volumes.items())},
        "kinds": {str(k): {"arm": f"0x{a:08X}",
                           "spawns": [_creator(t) for t in b.kind_spawns().get(k, ())]}
                  for k, a in sorted(b.kind_arms().items())},
        "sprites": {f"0x{s:08X}": {"row": r, "col": co, "size": z}
                    for s, (r, co, z) in sorted(b.sprite_params().items())},
        "play": {f"0x{s:08X}": {"loop": v, "ticks_before": PLAY_SITES[s][2]}
                 for s, (_f, v) in sorted(b.play_sites().items())},
        "blobs": {f"0x{s:08X}": {"model": m if isinstance(m, str) else None,
                                 "class": cl, "kind": k, "life": l}
                  for s, (m, cl, k, l) in sorted(b.blob_calls().items())},
        "weapon_muzzle": {str(k): [_creator(t) for _s, t in calls]
                          for k, (_a, calls) in sorted(WEAPON_MUZZLE.items())},
        "weapon_impact": {str(k): [_creator(t) for _s, t in calls]
                          for k, (_a, calls) in sorted(WEAPON_IMPACT.items())},
        "weapon_impact_sound": {str(k): (w[1] if w else None)
                                for k, (_a, w) in sorted(WEAPON_IMPACT_SOUND.items())},
        "creators": {f"0x{k:08X}": (v[1] if v else None)
                     for k, v in sorted(BLOB_CREATOR_NAMES.items())},
    }, indent=2))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Verify the effect and sound layers against docs/28.")
    ap.add_argument("--check", metavar="ROOT", help="run every check")
    ap.add_argument("--waves", metavar="ROOT", help="the event -> wave table")
    ap.add_argument("--blobs", metavar="ROOT", help="the blob and weapon tables")
    ap.add_argument("--kinds", metavar="ROOT", help="the 78 update kinds")
    ap.add_argument("--joints", metavar="ROOT",
                    help="the object_3d joint-angle buffer")
    ap.add_argument("--json", metavar="ROOT", help="dump everything as JSON")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.INFO if (args.check or args.verbose)
                        else logging.WARNING,
                        format="%(message)s")

    if args.waves:
        report_waves(args.waves)
        return 0
    if args.blobs:
        report_blobs(args.blobs)
        return 0
    if args.kinds:
        report_kinds(args.kinds)
        return 0
    if args.joints:
        report_joints(args.joints)
        return 0
    if args.json:
        report_json(args.json)
        return 0
    if not args.check:
        ap.print_help()
        return 2

    ck = run_checks(args.check)
    LOG.info("")
    LOG.info("%d checks, %d passed, %d failed", len(ck.names), ck.passed, ck.failed)
    return 1 if ck.failed else 0


if __name__ == "__main__":
    sys.exit(main())
