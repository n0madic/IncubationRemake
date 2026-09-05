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
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import lcl  # noqa: E402
import cho_parse  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402
from inclib.visn import parse_header  # noqa: E402
from inclib import lev as levlib  # noqa: E402
from inclib import prototyp  # noqa: E402
from inclib import sound  # noqa: E402

LOG = logging.getLogger("blob_tables")

GAME_EXE = "Incubation.exe"
WAVES_DIR = "Waves"
SPEECH_DIR = os.path.join("Waves", "Speech")
BRIEFING_DIR = "Briefing"
MUSIC_DIR = "music"

#: How far the import walkers below will read before giving up.  A PE with a
#: damaged directory must terminate rather than run off the end of the image;
#: the shipped tree's largest descriptor count is 12 and its largest thunk list
#: is 56, so both bounds are two orders of magnitude clear.
_IMPORT_DESCRIPTOR_LIMIT = 256
_IMPORT_THUNK_LIMIT = 4096

#: The two music families overlap on 02..08 and diverge on 09..14; `Arack`
#: stops at 14 and `Track` runs on to 20.  These bound the comparison, and the
#: divergence point is itself a check.
MUSIC_TRACK_LO = 2
MUSIC_SHARED_HI = 8
MUSIC_TRACK_HI = 14
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
VOLUME_IDS_UNUSED = ()              # 53..55 are the alien death scream's (VOICE_ARMS)

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

# The muzzle switch's **default** arm, and why it is not an optional extra.
#
# The compiler emits `add eax, -2 / cmp eax, 0x2D / ja <default>`, so the table
# covers weapons 2..47 and weapons **0 and 1** -- `Light Combat Gun` and
# `Advanced Combat Gun`, the two the campaign starts with -- fall past it.  The
# default is not a join point: it pushes 5 and calls `aBlob_CreateTracerBullet`,
# the same creator weapon 2 uses, so those two guns fire a visible tracer in the
# original.  Reading the jump table alone left them with no muzzle effect at
# all, which is what "you cannot see the shot" looked like in the remake.
#
# The other two switches' defaults were read the same way and make no blob:
# `IMPACT_SWITCH`'s (`0x0040DA07`) goes straight on to `aGetUnitMapElementPtr`
# and the unit sweep, so weapons 0..6 having no impact effect is the engine's
# own answer rather than a second gap.
MUZZLE_DEFAULT_JA = 0x0040CC51
MUZZLE_DEFAULT = (0x0040D42C, ((0x0040D44D, 0x004247C0),))

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

# -- the set pieces' own frame counts -------------------------------------
#
# docs/20 sec.7.4 gives most of them from the LCL side -- `Elevator` is `steps`
# frames of +-800, `Platform` is `dist*10` frames of +-0x140, `Bridge` is 80
# frames of +-12, `FootBridge`/`FootBridge2` take their count as an argument --
# and docs/28 sec.1.4 quotes `aDoorOpenSequence`'s own `for (n = 10; n; n--)`.
# `RoofUnit` is the one the three demo missions need and neither document
# gives, so it is read here: the drop loop at 0x00411DF3 subtracts a whole map
# field from the falling object's z on every frame tick and stops when it
# reaches the floor, so the count is the height divided by that step.

ROOF_UNIT = 0x00411B00
ROOF_DROP_SITE = 0x00411E26          # sub eax, 0xC80
ROOF_DROP_STEP = 0xC80               # one map field per displayed frame
ROOF_DRAW_OFFSET_SITE = 0x00411E2F   # add eax, 0xA0 -- the draw offset
ROOF_DRAW_OFFSET = 0xA0
ROOF_TICK_SITE = 0x00411E15          # the frame tick the loop is paced by
DOOR_SEQUENCE_FRAMES = 10            # docs/28 sec.1.4
ELEVATOR_STEP = 800                  # docs/20 sec.7.4, per frame
PLATFORM_STEP = 0x140                # per frame, `dist * 10` of them
PLATFORM_FRAMES_PER_FIELD = 10
BRIDGE_FRAMES = 80
BRIDGE_STEP = 12

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
BLOB_MODELS_EVERYWHERE = 30
#: The heal flash's four crosses (`aBlob_CreateFlashCircle` `0x00423030`,
#: docs/42 §7.3) reach the constructor through `mov edi, str` rather than a
#: `push`, one per quarter of its loop, so :data:`BLOB_CALLS`'s push reader
#: never sees them.  Read at their own sites, and in all nine world sets.
BLOB_MODEL_MOV_SITES = {0x004231A9: "A_CROSS3.3DI", 0x004231B4: "A_CROSS2.3DI",
                        0x004231BF: "A_CROSS1.3DI", 0x004231CA: "A_CROSS.3DI"}
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

#: The emitter tick's own gate.  `0x0041E1A0` opens
#: `call 0x004604D0 / cmp eax, 1 / jne body` -- so the **animation level**
#: (`Game.opt` +0x20, `docs/20` §8.2, default 2, forced 2 by the accelerated
#: renderer) turns the emitters *off* at level 1 and leaves them on at every
#: other value.  The sense is the easy thing to get backwards, so the `jne`'s
#: target is pinned as well as the comparison.
BGB_LEVEL_GETTER = 0x004604D0
BGB_TICK_GATE_CALL = 0x0041E1A1
BGB_TICK_GATE_CMP = 0x0041E1A6
BGB_TICK_GATE_JNE = 0x0041E1A9
BGB_TICK_GATE_LEVEL = 1
BGB_TICK_BODY = 0x0041E1AD
BGB_TICK_ID_BOUND_SITE = 0x0041E1B1
#: The three bytes of a record the tick reads, as `field -> the site that
#: reads it`: the countdown, the reload it takes and the gate's span.
BGB_COUNTDOWN_SITE = 0x0041E1E4
BGB_RANDOM_SITE = 0x0041E1F2
BGB_LIVE_SITES = (0x0041E219, 0x0041E227)
BGB_TYPE_SITE = 0x0041E247
BGB_COUNTDOWN_OFFSET = 0x10
BGB_LIVE_OFFSET = 0x11
BGB_RANDOM_OFFSET = 0x12
#: `aRandom2(0, random)` -- the gate's own draw, and `0xFF` is the countdown
#: that never decrements.
BGB_GATE_DRAW_BASE_SITE = 0x0041E202
BGB_HELD = 0xFF
BGB_HELD_SITES = (0x0041E1EE, 0x0041E239)
#: Where the two live arms read the position from, in the order they push it:
#: z, y, x.
BGB_POSITION_SITES = {1: (0x0041E25E, 0x0041E264, 0x0041E26A),
                      7: (0x0041E29A, 0x0041E2A0, 0x0041E2A6)}
BGB_POSITION_OFFSETS = (0x0C, 0x08, 0x04)

#: `aBlob_CreateMainMapFire` `0x0042A660` -- what `CreateBGB` type 7 spawns,
#: and the only creator the campaign maps' own scripts reach.  Its constructor
#: call `0x0042A6C6` is already in :data:`BLOB_CALLS` (the scratch name,
#: class 3, kind 58, life 12) and in :data:`BLOB_SPRITE` (both rotations 0,
#: `aux` 5); what is pinned here is the three velocity draws it takes first
#: and the zero `delay` it ends with.
MAIN_MAP_FIRE = 0x0042A660
#: `(base site, span site, call site, base, span)` per draw, in the order the
#: compiler emitted them: two horizontal, then the rising one.  A `__cdecl`
#: call takes its first argument from the **last** push, so the base is the
#: later site; the call is named outright because the compiler slid a `mov`
#: between the pushes and the call in two of the three.
MAIN_MAP_FIRE_DRAWS = ((0x0042A664, 0x0042A662, 0x0042A666, -0x30, 0x60),
                       (0x0042A675, 0x0042A673, 0x0042A679, -0x30, 0x60),
                       (0x0042A68B, 0x0042A686, 0x0042A692, 0x140, 0xA0))
MAIN_MAP_FIRE_DELAY_SITE = 0x0042A69F
MAIN_MAP_FIRE_DELAY = 0
MAIN_MAP_FIRE_CONSTRUCTOR = 0x0042A6C6

#: `aBlob_CreateSmoke2` `0x0042A5E0` -- the sweep's **other** live arm, and
#: the one nothing in the corpus reaches: all four `1_smoke` lines are
#: commented out in `_C_XXX.lcl` and `_C_YYY.lcl`.  It is the same three
#: draws and the same shape as the fire (its constructor call `0x0042A646`
#: is in :data:`BLOB_CALLS` as scratch/class 3/kind 10/life 12 and in
#: :data:`BLOB_SPRITE` as row 4, rotation 0, `aux` 10), which is why
#: transcribing it needs no capture: what differs from a verified creator is
#: three literals, and these pin them.
SMOKE2 = 0x0042A5E0
SMOKE2_DRAWS = ((0x0042A5E4, 0x0042A5E2, 0x0042A5E6, -0x30, 0x60),
                (0x0042A5F5, 0x0042A5F3, 0x0042A5F9, -0x30, 0x60),
                (0x0042A60B, 0x0042A606, 0x0042A612, 0x140, 0xA0))
SMOKE2_DELAY_SITE = 0x0042A61F
SMOKE2_DELAY = 0
SMOKE2_CONSTRUCTOR = 0x0042A646

#: `aBlob_CreateWarningLight` `0x0042A4C0` -- `CreateBGB` type 2, and the one
#: of the five registration creators that draws at all.  `aRandom2(0, 100)`
#: against 50 picks the sign of the `vx` kind 41 divides `0x200` by, so the
#: coin is which way the light sweeps.  `and ecx, 0xFFFFFFF6 / add ecx, 5`
#: turns the `setge`'s 0/-1 into +5/-5 without a branch.
WARNING_LIGHT = 0x0042A4C0
WARNING_LIGHT_DRAW = (0x0042A4C2, 0x0042A4C0, 0x0042A4C4, 0, 100)
WARNING_LIGHT_COIN_SITE = 0x0042A4D3
WARNING_LIGHT_COIN = 50
WARNING_LIGHT_MASK_SITE = 0x0042A4DC
WARNING_LIGHT_MASK = -10
WARNING_LIGHT_BIAS_SITE = 0x0042A4E3
WARNING_LIGHT_BIAS = 5
WARNING_LIGHT_CONSTRUCTOR = 0x0042A50E

#: `aBlob_CreateComputerLight` `0x0042A760` -- type 3, the only one of the
#: seven that reads a fourth argument.  The **shift is the command's**, not
#: the creator's: `0x0041DFE3` shifts the script's `gamma` left by ten on its
#: way into the call, and the creator hands it straight to the record's
#: third rotation, which kind 42 copies into the model's `angle2`.
COMPUTER_LIGHT = 0x0042A760
COMPUTER_LIGHT_GAMMA_SHIFT_SITE = 0x0041DFE3
COMPUTER_LIGHT_GAMMA_SHIFT = 10
COMPUTER_LIGHT_ROT_SITE = 0x0042A77D
COMPUTER_LIGHT_CONSTRUCTOR = 0x0042A790

#: The three registration creators no shipped script asks for -- types 4, 5
#: and 6 -- as `type -> (creator, constructor call)`.  They share one body
#: byte for byte and differ only in the model and the kind, so what is pinned
#: is that they are that body: no draw, and the same `push` shape.
#: :data:`BLOB_CALLS` carries the models and kinds.
BGB_STILL_CREATORS = {4: (0x0042A520, 0x0042A54D),
                      5: (0x0042A5A0, 0x0042A5CD),
                      6: (0x0042A560, 0x0042A58D)}

#: `0x0041E140` -- **not** the ticker.  `docs/20` §7.3 named it as the
#: per-frame half; it walks the same twenty records freeing the sound handle
#: at `+0x14` and clearing the type, which is the teardown.  The ticker is
#: :data:`BGB_TICK`, reached from the sweep at `0x0041E3DF`.
BGB_CLEAR = 0x0041E140
BGB_SWEEP = 0x0041E3D0
BGB_SWEEP_TICK_SITE = 0x0041E3DF
BGB_SOUND_OFFSET = 0x14
#: `aRandom2` `0x004638E0`, not `aRandom`: the effects' own stream
#: (`docs/22` §3.2).
RANDOM2 = 0x004638E0

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
#: The one arm that writes no period, the type that seeds the global after it,
#: and the period that type sets.
WALK_CARRY_TYPE = 54
WALK_CARRY_AFTER = 20
WALK_CARRY_PERIOD = 8
INFO_WEAPON_TOP = 47
# The three sites that pass a computed volume-control id in a register.
DYNAMIC_VOLUME_PUSHES = (0x0040C7D7, 0x0040CBF4, 0x0040E857)
DYNAMIC_VOLUME_OPCODES = (0x57, 0x57, 0x57)
WEAPON_SWITCH_TOP = (47, 46, 44)   # the top weapon id each switch covers
#: Weapon ids the third switch leaves silent -- the melee arms and every one
#: whose impact makes no noise of its own, out of the 45 the switch covers.
IMPACT_SOUND_SILENT = 28
#: Distinct literal wave names **pushed at a load call site** -- the 50 of
#: docs/28 section 2.2, and the population the ten renames were counted over.
CASE_CALL_LITERALS = 50
#: Every literal wave name the sound layer can name, which is the call sites'
#: 50 plus the four voice and four footstep names the arms build in a register.
#: The wider set is what the conversion has to resolve.
CASE_LITERALS = 58
#: The base volumes the attenuation is swept over.  The options field is a
#: DirectSound attenuation in hundredths of a decibel, so 0 is full scale;
#: below the floor every percentage is silence, so the identity sweep starts
#: at the floor and the silence gate is checked either side of it separately.
BASE_SWEEP_LO, BASE_SWEEP_HI, BASE_SWEEP_STEP = VOLUME_FLOOR, 0, 100

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
BLOB_MODEL_COUNT = 34

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
    # The death scream, severity 3 (docs/42 section 4.5): a machine explodes,
    # an alien screams SP_HUM off its own cursor at 53..55.
    (0x40c99c, 'explosion.wav', 0x40c9a7, 63),
    (0x40c9cc, 'SP_HUM_2.wav', 0x40c9d7, 55),
    (0x40c9f2, 'SP_HUM_1.wav', 0x40c9fd, 54),
    (0x40ca18, 'SP_HUM_0.wav', 0x40ca23, 53),
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

# ``docs/30`` 2.5 left one thing open about these angles: *which* of Eng3d's two
# three-axis matrix builders runs, "because the composition order is prototype
# data, not a format constant".  It is prototype data, and it is readable --
# each ``anim`` handler calls one of them outright, so the opcode decides and
# the opcode is in the record.  Both handlers the shipped joint programs reach,
# ``joint_rotate_3`` (slot 9) and ``joint_place`` (slot 18), call the **same**
# one.
MATRIX_BUILDER_RZRXRY = 0x00411BF6
MATRIX_BUILDER_RYRXRZ = 0x00411A93
#: ``joint_rotate_1``'s, which takes one angle rather than three.
MATRIX_BUILDER_ONE_ANGLE = 0x0041204F
#: opcode slot -> (the ``call`` inside its handler, the builder it names).
JOINT_BUILDERS = {
    8:  (0x00405FEC, MATRIX_BUILDER_ONE_ANGLE),
    9:  (0x00406025, MATRIX_BUILDER_RZRXRY),
    10: (0x0040609A, MATRIX_BUILDER_RYRXRZ),
    13: (0x00405F0A, MATRIX_BUILDER_RZRXRY),
    14: (0x00405F3C, MATRIX_BUILDER_RZRXRY),
    15: (0x00405F6E, MATRIX_BUILDER_RYRXRZ),
    18: (0x00406138, MATRIX_BUILDER_RZRXRY),
}
#: The two the shipped joint data actually reaches (``JOINT_OPERANDS``).
JOINT_BUILDERS_USED = (9, 18)
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
ATLAS_TILE = 32
ATLAS_GRID = 8
#: Derived, and deliberately so: the corpus check compares it against the
#: `anim` record's own header in every world set, which is the independent
#: reading.  There used to be a second `ATLAS_SIZE = 256` further down that
#: shadowed a literal here, so perturbing the literal changed nothing -- a pin
#: that documented nothing and looked like one.
ATLAS_SIZE = ATLAS_TILE * ATLAS_GRID
SPRITE_SIZE_RANGE = (3, 40)      # half-size in 160-unit steps: 0.3 m to 4 m

# -- the set-piece animation routines (docs/20 sec.7.4) --------------------
#
# `docs/20` read the frame counts and the per-frame steps out of these
# routines; the constants below were quoted from it and, until this pass, read
# by nothing here -- six pins with no second reading, which the mutation
# battery reported as six misses.  These are that second reading: the loop
# counter's `mov imm32` and its `dec`, and the shift/`lea` pairs the compiler
# emitted for each step.
DOOR_SEQUENCE = 0x00410A20               # aDoorOpenSequence
DOOR_FRAMES_SITE = 0x00410CFC            # mov ebp, 0xa
DOOR_FRAMES_DEC = 0x00410D17             # dec ebp
ELEVATOR_SEQUENCE = 0x004125D0
#: `lea eax,[esi+esi*4]; lea esi,[eax+eax*4]; shl esi,5` -- 5 * 5 * 32.
ELEVATOR_STEP_SITES = (0x004127F3, 0x004127F6, 0x004127F9)
PLATFORM_SEQUENCE = 0x00412A00
#: `lea eax,[esi+esi*4]; shl eax,1` -- the frame count, `dist * 10`.
PLATFORM_FRAMES_SITES = (0x00412CBE, 0x00412CC1)
#: `lea eax,[edi+edi*4]; shl eax,6` -- the per-frame step, 5 * 64.
PLATFORM_STEP_SITES = (0x00412CCF, 0x00412CD6)
#: The same step for the other axis, from `ebp` instead of `edi`; it is a
#: `mod=01` `lea` with a zero `disp8`, which is why the decoder takes both
#: forms rather than only the one the first three sites use.
PLATFORM_STEP_SITES_Y = (0x00412CD2, 0x00412CD9)
BRIDGE_SEQUENCE = 0x00410DA0
BRIDGE_FRAMES_SITE = 0x00410EBF           # mov ebx, 0x50
BRIDGE_FRAMES_DEC = 0x00410ED1            # dec ebx
#: `lea edi,[edi+edi*2]; shl edi,2` -- 3 * 4.
BRIDGE_STEP_SITES = (0x00410EB6, 0x00410EBC)
#: `and eax,0xff; lea eax,[eax+eax*4]; shl eax,5` in the zoom-draw wrapper --
#: the sprite half-extent, 5 * 32.  `SIZE_SCALE_SITE` already pinned the shift
#: alone, which left the factor of five unread.
SIZE_SCALE_SITES = (0x004040F0, 0x004040F3)
#: `shl eax,5` and `shl ecx,5` in the same wrapper -- the atlas row and column
#: on their way to the draw call, both scaled by the tile size.
ATLAS_ROW_SCALE_SITE = 0x00404108
ATLAS_COL_SCALE_SITE = 0x0040412F

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
#: Distinct destinations in the 78-entry jump table (docs/28 7.4).
KIND_ARMS = 74

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

    def lea_scale(self, va: int) -> int | None:
        """The multiplier of ``lea r32, [b + b*n]``, or ``None``.

        The compiler turns a small constant multiply into one or two of these
        plus a shift, and that is the only place the set-piece steps of
        ``docs/20`` 7.4 exist as numbers.  **Base and index must be the same
        register**, or the instruction is an address computation and not a
        multiply, and this answers ``None`` -- a perturbed site must read as
        "not the instruction I expected" rather than as a wrong multiplier.
        """
        try:
            if self.u8(va) != 0x8D:
                return None
            modrm = self.u8(va + 1)
            if modrm & 0x07 != 0x04:            # r/m = 100 -> a SIB follows
                return None
            mod = modrm >> 6
            sib = self.u8(va + 2)
            base, index = sib & 0x07, (sib >> 3) & 0x07
            if index == 0x04 or base != index:  # no index, or not b + b*n
                return None
            if mod == 0x00:
                if base == 0x05:                # disp32, no base register
                    return None
            elif mod == 0x01:
                if self.u8(va + 3) != 0:        # a real displacement
                    return None
            else:
                return None
            return 1 + (1 << (sib >> 6))
        except PEError:
            return None

    def shl_scale(self, va: int) -> int | None:
        """The multiplier of ``shl r32, imm8`` (``C1 /4 ib``) or ``shl r32, 1``
        (``D1 /4``), or ``None`` when the bytes are something else."""
        try:
            opcode = self.u8(va)
            modrm = self.u8(va + 1)
            if modrm >> 6 != 0x03 or (modrm >> 3) & 0x07 != 0x04:
                return None
            if opcode == 0xD1:
                return 2
            if opcode == 0xC1:
                return 1 << self.u8(va + 2)
            return None
        except PEError:
            return None

    def is_dec_reg(self, va: int) -> bool:
        """``dec r32`` -- ``48+r``.  What makes a ``mov imm`` a loop counter."""
        try:
            return 0x48 <= self.u8(va) <= 0x4F
        except PEError:
            return False

    def cleanup_dwords(self, site: int) -> int | None:
        """``add esp, K`` right after the five-byte ``call rel32`` at *site*.

        For a ``__cdecl`` callee this is the only place the arity exists: the
        callee pops nothing, so a debugger's own signature probe cannot recover
        it and the caller's cleanup can.
        """
        after = site + 5
        try:
            if self.u8(after) == 0x83 and self.u8(after + 1) == 0xC4:
                return self.u8(after + 2) // 4
            if self.u8(after) == 0x81 and self.u8(after + 1) == 0xC4:
                return self.pe.u32(after + 2) // 4
        except PEError:
            return None
        return None

    def call_target(self, va: int) -> int | None:
        try:
            if self.pe.u8(va) != 0xE8:
                return None
            return va + 5 + self.pe.i32(va + 1)
        except PEError:
            return None

    def ja_target(self, va: int) -> int | None:
        """``ja rel32`` (0x0F 0x87) -> where it goes, for a switch default."""
        try:
            if self.pe.u8(va) != 0x0F or self.pe.u8(va + 1) != 0x87:
                return None
            return va + 6 + self.pe.i32(va + 2)
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

    def abs_load(self, va: int) -> tuple[int, int] | None:
        """``mov r32, dword [disp32]`` -> ``(disp32, instruction length)``.

        Both encodings the interface uses: ``A1 disp32`` for ``eax`` and
        ``8B /r`` with ``mod = 00`` and ``r/m = 101`` for any register.
        """
        if not self.mapped(va, 6):
            return None
        if self.u8(va) == 0xA1:
            return self.u32(va + 1), 5
        if self.u8(va) == 0x8B and self.u8(va + 1) & 0xC7 == 0x05:
            return self.u32(va + 2), 6
        return None

    def cmp_abs_imm(self, va: int) -> tuple[int, int] | None:
        """``cmp dword [disp32], imm8`` -- ``83 3D disp32 ii``."""
        if not self.mapped(va, 7):
            return None
        if self.u8(va) != 0x83 or self.u8(va + 1) != 0x3D:
            return None
        return self.u32(va + 2), self.u8(va + 6)

    def esp_byte_imm(self, va: int) -> tuple[int, int] | None:
        """``mov byte [esp + dd], ii`` -- ``C6 44 24 dd ii``."""
        if not self.mapped(va, 5):
            return None
        if self.u8(va) != 0xC6 or self.u8(va + 1) != 0x44 \
                or self.u8(va + 2) != 0x24:
            return None
        return self.u8(va + 3), self.u8(va + 4)

    def mov_reg_imm32(self, va: int) -> int | None:
        """``mov r32, imm32`` -- ``B8+r imm32``."""
        if not self.mapped(va, 5):
            return None
        if 0xB8 <= self.u8(va) <= 0xBF:
            return self.u32(va + 1)
        return None

    def arm_strings(self, arm: int, arms=(), limit: int = 200) -> list[str]:
        """Every string a ``mov r32, imm32`` inside one switch arm names."""
        end = self._extent(arm, arms, limit)
        out: list[str] = []
        va = arm
        while va < end:
            value = self.mov_reg_imm32(va)
            if value is not None:
                text = self.string(value, 16)
                if text:
                    out.append(text)
                va += 5
                continue
            va += 1
        return out

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
            program = lcl.parse_bytes(handle.read(), path)
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
        if isinstance(node, lcl.Statement):
            yield node
        elif isinstance(node, lcl.Conditional):
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


def _bgb_field(b: Binary, site: int) -> int | None:
    """The record offset a ``mov r8/r32, [esi + disp32]`` at *site* reads."""
    if b.u8(site) not in (0x8A, 0x8B):
        return None
    if b.u8(site + 1) & 0xC0 != 0x80:
        return None
    return b.u32(site + 2) - BGB_TABLE


def _calls_between(b: Binary, start: int, end: int) -> set:
    """Every `call rel32` target in `[start, end]`.

    Used to say what a routine does **not** do: types 4, 5 and 6 reach their
    constructor with no draw in front of it, which is the difference between
    them and type 2 and is not visible in a table of literals.
    """
    out = set()
    va = start
    while va <= end:
        if b.u8(va) == 0xE8:
            target = b.call_target(va)
            if target is not None:
                out.add(target)
            va += 5
            continue
        va += 1
    return out


def check_bgb_tick(ck: Checker, b: Binary) -> None:
    """`0x0041E1A0`, the per-frame half of `CreateBGB` -- docs/28 sec.8.2.

    The switch itself is pinned above; this is the cadence around it, which
    is what a port has to reproduce and what `docs/28` only summarised.  The
    gate's **sense** is pinned by the `jne`'s target rather than by the
    comparison alone: the fall-through is a bare `ret`, so level 1 is the
    value that turns the emitters off.
    """
    ck.equal("bgb.tick_gate_getter", b.call_target(BGB_TICK_GATE_CALL),
             BGB_LEVEL_GETTER, hex)
    ck.equal("bgb.tick_gate_level", b.cmp_imm(BGB_TICK_GATE_CMP),
             BGB_TICK_GATE_LEVEL)
    ck.check("bgb.tick_gate_skips_on_that_level",
             b.u8(BGB_TICK_GATE_JNE) == 0x75
             and BGB_TICK_GATE_JNE + 2 + b.i8(BGB_TICK_GATE_JNE + 1)
             == BGB_TICK_BODY
             and b.u8(BGB_TICK_GATE_JNE + 2) == 0x5E
             and b.u8(BGB_TICK_GATE_JNE + 3) == 0xC3,
             "jne body over a pop/ret: the emitters run at every level but 1")
    ck.equal("bgb.tick_id_bound", b.cmp_imm(BGB_TICK_ID_BOUND_SITE), BGB_SLOTS)
    ck.equal("bgb.record_countdown", _bgb_field(b, BGB_COUNTDOWN_SITE),
             BGB_COUNTDOWN_OFFSET, hex)
    ck.equal("bgb.record_random", _bgb_field(b, BGB_RANDOM_SITE),
             BGB_RANDOM_OFFSET, hex)
    ck.equal("bgb.record_live",
             tuple(_bgb_field(b, site) for site in BGB_LIVE_SITES),
             (BGB_LIVE_OFFSET,) * len(BGB_LIVE_SITES), Checker.brief)
    ck.equal("bgb.record_type", _bgb_field(b, BGB_TYPE_SITE), 0, hex)
    ck.equal("bgb.gate_draw", b.call_target(BGB_GATE_DRAW_BASE_SITE + 2),
             RANDOM2, hex)
    ck.equal("bgb.gate_draw_base", b.push_imm(BGB_GATE_DRAW_BASE_SITE), 0)
    ck.equal("bgb.countdown_held",
             tuple(b.cmp_imm(site) for site in BGB_HELD_SITES),
             (BGB_HELD - 0x100,) * len(BGB_HELD_SITES), Checker.brief)
    for arm, sites in sorted(BGB_POSITION_SITES.items()):
        ck.equal("bgb.position_arm%d" % arm,
                 tuple(_bgb_field(b, site) for site in sites),
                 BGB_POSITION_OFFSETS, Checker.brief)

    # ---- aBlob_CreateMainMapFire ----------------------------------------
    ck.equal("bgb.fire_constructor",
             b.call_target(MAIN_MAP_FIRE_CONSTRUCTOR), BLOB_CTOR, hex)
    for i, (base_site, span_site, call_site, base, span) in enumerate(
            MAIN_MAP_FIRE_DRAWS):
        ck.equal("bgb.fire_draw%d" % i,
                 (b.push_imm(base_site), b.push_imm(span_site)),
                 (base, span), Checker.brief)
        ck.equal("bgb.fire_draw%d_stream" % i,
                 b.call_target(call_site), RANDOM2, hex)
    ck.equal("bgb.fire_delay", b.push_imm(MAIN_MAP_FIRE_DELAY_SITE),
             MAIN_MAP_FIRE_DELAY)

    # The sweep reaches the tick, and the routine `docs/20` named as the
    # ticker is the teardown beside it.
    ck.equal("bgb.sweep_calls_the_tick", b.call_target(BGB_SWEEP_TICK_SITE),
             BGB_TICK, hex)
    ck.check("bgb.clear_is_not_the_tick",
             BGB_CLEAR != BGB_TICK
             and b.u32(BGB_CLEAR + 3) == BGB_TABLE + BGB_SOUND_OFFSET,
             "0x0041E140 walks the sound handles, it does not spawn")

    # `aBlob_CreateSmoke2`: the same three draws as the fire, one delay, and
    # the constructor `BLOB_CALLS` already carries.
    ck.equal("bgb.smoke_constructor", b.call_target(SMOKE2_CONSTRUCTOR),
             BLOB_CTOR, hex)
    for i, (base_site, span_site, call_site, base, span) in enumerate(
            SMOKE2_DRAWS):
        ck.equal("bgb.smoke_draw%d" % i,
                 (b.push_imm(base_site), b.push_imm(span_site)),
                 (base, span), Checker.brief)
        ck.equal("bgb.smoke_draw%d_stream" % i,
                 b.call_target(call_site), RANDOM2, hex)
    ck.equal("bgb.smoke_delay", b.push_imm(SMOKE2_DELAY_SITE), SMOKE2_DELAY)

    # The five one-shots registration makes for itself.
    base_site, span_site, call_site, base, span = WARNING_LIGHT_DRAW
    ck.equal("bgb.warning_light_draw",
             (b.push_imm(base_site), b.push_imm(span_site)), (base, span),
             Checker.brief)
    ck.equal("bgb.warning_light_stream", b.call_target(call_site), RANDOM2,
             hex)
    ck.equal("bgb.warning_light_coin", b.cmp_imm(WARNING_LIGHT_COIN_SITE),
             WARNING_LIGHT_COIN)
    # `83 e1 f6` / `83 c1 05` -- both sign-extended byte forms, which is why
    # the mask reads as -10 rather than as 0xFFFFFFF6.
    ck.equal("bgb.warning_light_spin",
             (b.i8(WARNING_LIGHT_MASK_SITE + 2),
              b.i8(WARNING_LIGHT_BIAS_SITE + 2)),
             (WARNING_LIGHT_MASK, WARNING_LIGHT_BIAS), Checker.brief)
    ck.equal("bgb.warning_light_constructor",
             b.call_target(WARNING_LIGHT_CONSTRUCTOR), BLOB_CTOR, hex)
    ck.equal("bgb.computer_light_gamma_shift",
             b.u8(COMPUTER_LIGHT_GAMMA_SHIFT_SITE + 2),
             COMPUTER_LIGHT_GAMMA_SHIFT)
    ck.equal("bgb.computer_light_constructor",
             b.call_target(COMPUTER_LIGHT_CONSTRUCTOR), BLOB_CTOR, hex)
    ck.check("bgb.computer_light_passes_the_gamma",
             b.u8(COMPUTER_LIGHT_ROT_SITE) == 0x50,
             "`push eax` -- the shifted gamma, into the third rotation")
    for type_id, (creator, constructor) in sorted(BGB_STILL_CREATORS.items()):
        ck.equal("bgb.still%d_constructor" % type_id,
                 b.call_target(constructor), BLOB_CTOR, hex)
        ck.equal("bgb.still%d_is_the_registration_arm" % type_id,
                 BGB_ARMS[type_id][1], creator, hex)
        ck.check("bgb.still%d_draws_nothing" % type_id,
                 RANDOM2 not in _calls_between(b, creator, constructor),
                 "types 4, 5 and 6 have no draw at all")



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

    # The period is one global, not a field of the walker.  Six of the seven
    # sounding arms write it with `mov dword [0x004FAECC], imm32`; the
    # `msqueether` arm writes the wave and the volume id and leaves it, so type
    # 54 walks at whatever the last walker set.
    stores = [site for _a, (_t, _w, _v, period) in WALK_ARMS.items()
              if period for site in (period[0],)]
    ck.check("walk.period_is_one_global",
             bool(stores) and all(b.u8(site) == 0xC7 and b.u8(site + 1) == 0x05
                                  and b.u32(site + 2) == WALK_PERIOD_GLOBAL
                                  for site in stores),
             f"{len(stores)} arms store to 0x{WALK_PERIOD_GLOBAL:08X}")
    ck.equal("walk.period_global", sound.FOOTSTEP_PERIOD_GLOBAL,
             WALK_PERIOD_GLOBAL, hex)
    # It is past the end of `.data`'s raw bytes, in the tail the loader
    # zero-fills, so a Squeether walking first has no period at all.
    ck.check("walk.period_starts_zero",
             not b.mapped(WALK_PERIOD_GLOBAL, 4)
             and sound.FOOTSTEP_PERIOD_INITIAL == 0,
             "0x%08X is in the zero-filled tail of .data" % WALK_PERIOD_GLOBAL)
    carry = sound.WalkPeriod()
    first = carry.start(WALK_CARRY_TYPE)
    seeded = carry.start(WALK_CARRY_AFTER)
    later = carry.start(WALK_CARRY_TYPE)
    ck.equal("walk.period_carries",
             (first.period, seeded.period, later.period),
             (sound.FOOTSTEP_PERIOD_INITIAL, WALK_CARRY_PERIOD,
              WALK_CARRY_PERIOD))

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

    models = blob_models(b)
    ck.equal("blob.model_mov_sites",
             {s: (b.string(b.mov_imm32(s) or 0, 40) if b.mov_imm32(s) else None)
              for s in BLOB_MODEL_MOV_SITES},
             BLOB_MODEL_MOV_SITES, Checker.brief)
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
    # The default arm, which the jump table cannot show.  Weapons 0 and 1 reach
    # it and it makes a tracer -- see MUZZLE_DEFAULT.
    ck.equal("weapon.muzzle_default_arm", b.ja_target(MUZZLE_DEFAULT_JA),
             MUZZLE_DEFAULT[0], hex)
    ck.equal("weapon.muzzle_default_call",
             b.call_target(MUZZLE_DEFAULT[1][0][0]), MUZZLE_DEFAULT[1][0][1],
             hex)
    ck.check("weapon.muzzle_default_is_a_creator",
             MUZZLE_DEFAULT[1][0][1] in creators,
             "the default arm's call lands on a blob creator")
    ck.check("weapon.muzzle_default_is_outside_the_table",
             all(w >= MUZZLE_SWITCH[3] for w in WEAPON_MUZZLE),
             "weapons below %d are the ones it answers for" % MUZZLE_SWITCH[3])
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
    check_bgb_tick(ck, b)

    # ---- the mission interface's own sounds (docs/28 2.5 and 4.3) -------
    check_mission_sound(ck, b)

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

    # Which matrix builder each handler calls -- `docs/30` 2.5's last open
    # item about the joint family, and it is a `call rel32` away.
    builders = {slot: _eng_call(eng, site)
                for slot, (site, _want) in sorted(JOINT_BUILDERS.items())}
    ck.equal("joint.matrix_builders", builders,
             {slot: want for slot, (_site, want) in JOINT_BUILDERS.items()},
             Checker.brief)
    ck.check("joint.builders_agree",
             all(builders.get(slot) == MATRIX_BUILDER_RZRXRY
                 for slot in JOINT_BUILDERS_USED),
             "the two opcodes the shipped joint programs use -- "
             f"{JOINT_BUILDERS_USED} -- both build RzRxRy")
    ck.check("joint.builders_differ",
             MATRIX_BUILDER_RZRXRY != MATRIX_BUILDER_RYRXRZ
             and sorted({want for _s, want in JOINT_BUILDERS.values()})
             == sorted({MATRIX_BUILDER_ONE_ANGLE, MATRIX_BUILDER_RYRXRZ,
                        MATRIX_BUILDER_RZRXRY}),
             "the choice is real: three distinct builders across seven arms")

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

    _sound_model_checks(ck, b, c)
    _music_shim_checks(ck, c)
    _creator_reach_checks(ck, b)
    _creator_constant_checks(ck, b)
    _tracer_axis_checks(ck, b)
    _output_system_checks(ck, b)
    _surface_lock_checks(ck, b)
    _generator_checks(ck, b)
    _setpiece_timing_checks(ck, b)
    _check_arm_spawn_arity(ck, b)
    _check_zoom_bob_arguments(ck, b)

    return ck


# --------------------------------------------------------------------------
# The executable sound model (tools/inclib/sound.py)
# --------------------------------------------------------------------------
#
# These check the *model* against the tables above, which were read out of the
# binary.  The two share no code: `sound.py` opens nothing, and everything it
# is compared against here comes from `Binary`/`Corpus`.  A mutation of a pin
# in this file that the model does not carry, or of a constant in the model
# that this file does not carry, breaks one of them.

# --------------------------------------------------------------------------
# Which music family the shipped build plays (docs/28 6.1)
# --------------------------------------------------------------------------
#
# `music/` ships two families, `Track02..20` and `Arack02..14`, and 09-14 are
# audibly different recordings.  For most of this project's life which one the
# game plays was an open question, because the CD player is an MCI shim and no
# tool here read it.  The import table settles it without reading the shim's
# code at all: the 1997 build called `winmm`, and the shipped import descriptor
# names `audio.dll` instead, carrying exactly the nine `winmm` entry points the
# game used.  That DLL is the shim built with `Arack`.  `sound.dll` is the same
# shim built with `Track`, and nothing imports it.

#: Every PE in the game root, so "nothing imports the other one" is a sweep and
#: not an assertion about one file.
def _imports(path: str) -> dict[str, list[str]]:
    """``dll name -> imported symbol names``, from a PE's import directory.

    Returns ``{}`` for a file that is not a readable PE: the sweep below runs
    over everything in the root, and a data file must not raise.
    """
    try:
        pe = PEFile(path)
    except (PEError, OSError, ValueError):
        return {}
    if len(pe.dirs) <= 1:
        return {}
    rva, _size = pe.dirs[1]
    if not rva:
        return {}
    off = pe.rva_to_off(rva)
    if off is None:
        return {}
    table: dict[str, list[str]] = {}
    for i in range(_IMPORT_DESCRIPTOR_LIMIT):
        entry = pe.data[off + i * 20:off + i * 20 + 20]
        if len(entry) < 20 or entry == b"\0" * 20:
            break
        oft, _ts, _fc, name_rva, ft = struct.unpack("<5I", entry)
        if not name_rva:
            break
        name = pe.cstring(pe.image_base + name_rva)
        thunk = pe.rva_to_off(oft or ft)
        names: list[str] = []
        if thunk is not None:
            for j in range(_IMPORT_THUNK_LIMIT):
                raw = pe.data[thunk + j * 4:thunk + j * 4 + 4]
                if len(raw) < 4:
                    break
                value = struct.unpack("<I", raw)[0]
                if value == 0:
                    break
                if value & 0x80000000:
                    names.append(f"ord#{value & 0xFFFF}")
                else:
                    names.append(pe.cstring(pe.image_base + value + 2))
        table[name.lower()] = names
    return table


def _shipped_playlist_tracks(root: Path) -> set[int]:
    """Every track number a shipped ``CDTrackProgram`` names, over all missions.

    ``docs/20`` 7.3: the argument is a dot-separated list the mission loops.
    Reading all of them rather than the five converted ones is deliberate --
    the question the flip raises is whether the family the shim plays is long
    enough for the *game*, not for the slice.
    """
    tracks: set[int] = set()
    for path in sorted((root / "Missions").glob("*.lcl")):
        with open(path, "rb") as handle:
            program = lcl.parse_bytes(handle.read(), str(path))
        for routine in program.routines:
            for stmt in _walk(routine.body):
                if stmt.name != "CDTrackProgram":
                    continue
                for text in strings(stmt.args):
                    tracks.update(sound.playlist(text))
    return tracks


def _music_shim_checks(ck: "Checker", c: Corpus) -> None:
    root = Path(c.root)
    exe = root / GAME_EXE
    table = _imports(str(exe))
    ck.check("music.shim_imported", sound.MUSIC_SHIM.lower() in table,
             f"{GAME_EXE} imports {sound.MUSIC_SHIM} "
             f"(of {len(table)} descriptors)")
    ck.equal("music.shim_entry_points",
             sorted(table.get(sound.MUSIC_SHIM.lower(), [])),
             sorted(sound.MUSIC_SHIM_IMPORTS))
    ck.check("music.shim_replaces_winmm",
             not any(name.startswith("winmm") for name in table),
             f"{GAME_EXE} names no winmm descriptor -- "
             f"{sound.MUSIC_SHIM} stands in its place")

    # The other build of the same shim is imported by nothing in the tree.
    importers = []
    for path in sorted(root.glob("*")):
        if not path.is_file():
            continue
        if sound.MUSIC_SHIM_UNUSED.lower() in _imports(str(path)):
            importers.append(path.name)
    ck.equal("music.alternate_shim_unimported", importers, [])

    # Each shim carries its family verbatim, and only that family.
    for dll, wanted in sorted(sound.MUSIC_SHIM_STRINGS.items()):
        blob = (root / dll).read_bytes()
        other = sound.MUSIC_SHIM_STRINGS[
            sound.MUSIC_SHIM_UNUSED if dll == sound.MUSIC_SHIM
            else sound.MUSIC_SHIM]
        tag = "shim" if dll == sound.MUSIC_SHIM else "alternate"
        ck.check(f"music.{tag}_names_family",
                 wanted.encode("ascii") in blob
                 and other.encode("ascii") not in blob,
                 f"{dll} carries {wanted!r} and not {other!r}")

    ck.equal("music.format", sound.MUSIC_FORMAT,
             sound.MUSIC_SHIM_STRINGS[sound.MUSIC_SHIM].split("\\")[-1])
    ck.equal("music.alternate_format", sound.MUSIC_ALTERNATE_FORMAT,
             sound.MUSIC_SHIM_STRINGS[sound.MUSIC_SHIM_UNUSED].split("\\")[-1])

    # Every track any shipped playlist can name exists in the family the shim
    # plays.  The two families are not the same length -- Track runs to 20 and
    # Arack stops at 14 -- so this is the check that the flip did not silently
    # cost a mission its music.
    wanted_tracks = sorted(_shipped_playlist_tracks(root))
    absent = [t for t in wanted_tracks
              if not (root / MUSIC_DIR / (sound.MUSIC_FORMAT % t)).is_file()]
    ck.check("music.playlists_resolve", bool(wanted_tracks) and not absent,
             f"{len(wanted_tracks)} track(s) named by shipped playlists, "
             f"{max(wanted_tracks or [0])} the highest, all present")

    # 02-08 are byte-identical between the families and 09-14 are not, which is
    # why the question was worth settling: the choice is audible exactly where
    # the missions reach past 8.
    # The low end is the shipped tree's, not this file's: deriving both sides
    # of the comparison below from the same constant would make it agree with
    # itself.
    present = sorted(t for t in range(0, 100)
                     if (root / MUSIC_DIR / (sound.MUSIC_FORMAT % t)).is_file())
    ck.equal("music.family_range",
             (MUSIC_TRACK_LO, MUSIC_TRACK_HI),
             (min(present), max(present)) if present else (None, None))

    same, differ = [], []
    for track in range(MUSIC_TRACK_LO, MUSIC_TRACK_HI + 1):
        a = root / MUSIC_DIR / (sound.MUSIC_FORMAT % track)
        t = root / MUSIC_DIR / (sound.MUSIC_ALTERNATE_FORMAT % track)
        if not (a.is_file() and t.is_file()):
            continue
        (same if a.read_bytes() == t.read_bytes() else differ).append(track)
    ck.equal("music.families_diverge_at", (same, differ),
             (list(range(MUSIC_TRACK_LO, MUSIC_SHARED_HI + 1)),
              list(range(MUSIC_SHARED_HI + 1, MUSIC_TRACK_HI + 1))))


# --------------------------------------------------------------------------
# How much of the creator layer a shot can actually reach
# --------------------------------------------------------------------------
#
# `docs/28` 7.6 lists 81 creators and 7.2 lists 116 constructor calls, and the
# remake transcribes **none** of the creators' own placement and velocity
# arithmetic -- their positions and velocities are its own.  That is a real
# limit, and a limit is only honest if it is measured.  These checks say
# exactly how large it is: how many creators a shot can reach through the two
# geometry switches of 8.1, how many constructor calls sit inside them, and how
# many of those calls carry a literal lifetime rather than one the creator
# computes.  The last is what makes the remake's trajectory *timing* extracted
# rather than invented (`blob_triggers.gd`).

#: Creators reachable from `weapon_muzzle` and `weapon_impact` together.
REACHABLE_CREATORS = 30
#: The constructor calls inside them.
REACHABLE_CALLS = 43
#: Of those, the ones whose lifetime is a literal at the call site.
REACHABLE_CALLS_WITH_LIFE = 27
#: creator -> its dword arity, from each caller's `add esp, K`.  `tools/
#: blob_gold.py` needs this before it can call one, and `--probe` cannot
#: recover it: the creators are `__cdecl`, so the callee pops nothing.
CREATOR_ARITIES = {
    "0x00420A50": 2, "0x004227C0": 2, "0x004228F0": 3, "0x00422B80": 3,
    "0x00423D80": 7, "0x00424250": 7, "0x004247C0": 7, "0x00424D20": 4,
    "0x00425400": 6, "0x00425810": 6, "0x00425CA0": 5, "0x00426070": 6,
    "0x004264A0": 5, "0x004268B0": 4, "0x00426B70": 4, "0x00426F90": 4,
    "0x00427410": 4, "0x00427810": 4, "0x00427C80": 5, "0x00428200": 5,
    "0x00428570": 5, "0x00429180": 4, "0x004294E0": 2, "0x004295D0": 2,
    "0x00429A80": 3, "0x00429C30": 3, "0x00429F40": 4, "0x0042A9D0": 4,
    "0x0042ACF0": 2, "0x0042AF10": 2,
}

# --------------------------------------------------------------------------
# The two Lehmer streams
# --------------------------------------------------------------------------
#
# `docs/22` 3 recovered `aRandom` at `0x00463870` and `inclib/rng.py` pins it
# natively.  There is a **second entry point** eleven `nop`s later whose body
# is that one byte for byte -- same multiplier, same modulus, same x87
# sequence -- over a **different seed global**, and without the call counter
# and running sum `aRandom` keeps.  It is not a variant and not a wrapper: it
# is the same generator over a second stream, and it is the busier of the two
# by a factor of eleven.
#
# This matters because `docs/97` 15.5 wrote the blob creators' velocities down
# as "drawn from `aRandom` ... and **not** replayed".  They are not drawn from
# `aRandom` at all: reading its seed either side of all thirty creators shows
# it never moves.  These checks are the static half of that finding, and they
# need no capture.

#: The counted stream: seed, call counter and running sum.
ARANDOM_ENTRY = 0x00463870
ARANDOM_SEED = 0x00514078
ARANDOM_COUNTER = 0x00514080
ARANDOM_SUM = 0x00514084
#: The uncounted stream, and the one nearly everything draws from.
ARANDOM2_ENTRY = 0x004638E0
ARANDOM2_SEED = 0x00514070
#: How long the shared body is, up to and including the second stream's `ret`.
ARANDOM_SHARED_BYTES = 0x45
#: Where the two differ inside that span, as offsets from each entry: the low
#: byte of the seed global in the `fld` and again in the `fst`, the two
#: `call rel32` displacements to `__ftol` and its neighbour (same targets,
#: different origins), and the two bytes where `aRandom` goes on to its
#: counter while the second stream pops and returns.
ARANDOM_BODY_DIFFERENCES = (0x03, 0x14, 0x19, 0x1A, 0x31, 0x43, 0x44)
#: Call sites reaching each, across `.text`.
ARANDOM_SITES = 32
ARANDOM2_SITES = 372
#: creator -> how many `call` sites in its closure reach the uncounted stream.
#: Reach, not use: a creator with sites on an untaken branch draws nothing,
#: which is exactly what the capture measures against this.
CREATOR_DRAW_SITES = {
    "0x00420A50": 7, "0x004227C0": 3, "0x004228F0": 3, "0x00422B80": 1,
    "0x00423D80": 34, "0x00424250": 52, "0x004247C0": 30, "0x00424D20": 30,
    "0x00425400": 0, "0x00425810": 3, "0x00425CA0": 0, "0x00426070": 5,
    "0x004264A0": 3, "0x004268B0": 0, "0x00426B70": 26, "0x00426F90": 14,
    "0x00427410": 17, "0x00427810": 3, "0x00427C80": 2, "0x00428200": 0,
    "0x00428570": 26, "0x00429180": 20, "0x004294E0": 18, "0x004295D0": 16,
    "0x00429A80": 11, "0x00429C30": 11, "0x00429F40": 10, "0x0042A9D0": 14,
    "0x0042ACF0": 15, "0x0042AF10": 20,
}
#: How many creators can reach the generator at all.
CREATORS_THAT_CAN_DRAW = 26

#: How many functions call each stream, and which of the uncounted one's
#: callers are **not** in the blob module.  The split is nearly the line the
#: remake draws between `core/` and `game/` -- the counted stream is the
#: gameplay one (`aAISystemControl`, `aAttackUnit`, `aCheckWeaponDamage`,
#: `aExecuteUse`, `aComputeMissionObjectives`), the uncounted one is
#: `aBlobs.cpp` and the animation drivers -- but it is **not clean**, and the
#: exceptions are pinned rather than rounded off.  Three of them are in the
#: unit pool (`aEnlargeUnitPool`, `aAddUnitToUnitPool`,
#: `aGenerateUnitElement`) and one function draws from **both**.
#:
#: Neither is a leak, and `POOL_DRAW_SITES` below is why.  All three pool
#: sites roll `aRandom(1, 6)` into `unit[+0x55]` -- the **speech-set id** of
#: `docs/20` 7.4, which of the shipped voice sets a recruited soldier talks
#: with, and which no rule reads.  The one that draws from both does two jobs
#: and uses the right stream for each.  `docs/22` 3.2 has the whole reading;
#: `docs/20` 7.4's `InsertUnit` spawn *count* from the C runtime's `rand` is
#: on the same side of the line, being a count and not a rule.
RANDOM_OWNERS_UNCOUNTED = 75
RANDOM_OWNERS_COUNTED = 17
#: Callers of the uncounted stream outside `aBlobs.cpp`'s own address range.
RANDOM_BLOB_MODULE = (0x0041E500, 0x0042B3B0)
RANDOM_UNCOUNTED_OUTSIDE = (
    0x004055E0, 0x00405F70, 0x004060B0, 0x00406FC0, 0x0040BD70, 0x00411460,
    0x00414550, 0x00414A70, 0x00415110, 0x004160F0, 0x0041E1A0, 0x0042DDF0,
    0x0042F840, 0x0042FCB0, 0x0044DCD0, 0x004789B0, 0x00478C10, 0x00479CF0,
    0x0047B660,
)
#: The one function that draws from both streams.
RANDOM_BOTH_STREAMS = (0x004160F0,)

#: **What the unit pool draws the clock-seeded stream for**, which was the
#: question `docs/22` §12 opened and the reason it opened it: a draw from a
#: wall-clock-seeded generator inside `aUnitMap.cpp` looks like simulation
#: escaping the determinism argument of `docs/22` §3.1.
#:
#: It is not simulation.  All three sites do the identical thing --
#: `aRandom(1, 6)`, `__ftol`, and a **byte** store -- and the byte is
#: `unit[+0x55]`, which `docs/20` §7.4 and `docs/21` §5 already identify as
#: the **speech-set id**: which of the shipped `Waves/Speech/` voice sets the
#: recruited soldier talks with.  `docs/10` §5.8 already said the value was
#: rolled; what was missing was *which generator*, and it is the presentation
#: one.  Nothing in the rule set reads the byte.
#:
#: The one thing that follows and is worth writing down: the roster is
#: **saved** (`docs/11` §5.11), so a clock-seeded byte does reach the save
#: file.  A remake must therefore keep it out of a canonical hash rather than
#: keep it out of the save.
POOL_DRAW_SITES = {
    0x00478B36: 0x004789B0,     # aEnlargeUnitPool
    0x00478CC8: 0x00478C10,     # aAddUnitToUnitPool
    0x00479F5D: 0x00479CF0,     # aGenerateUnitElement
}
#: The arguments every one of them pushes: `aRandom(1, 6)`, so 1..6.
POOL_DRAW_ARGUMENTS = (1, 6)
#: `docs/20` §7.4 -- the speech-set byte in the 91-byte unit record.
POOL_DRAW_FIELD = 0x55
#: The persistent roster two of the three write into (`docs/11` §5.11).
UNIT_ROSTER = 0x0051F2A0
#: `aGenerateUnitElement`'s exception: unit type 24 is given a **fixed** set
#: rather than a rolled one, and 12 is `spidy` -- the only non-human voice in
#: `docs/20` §7.4's table.
POOL_SPEECH_FIXED_TYPE = 0x18
POOL_SPEECH_FIXED_VALUE = 12
#: How far back a draw's two pushes are looked for.  `aEnlargeUnitPool`
#: separates them from the call by seventy-five bytes of unrelated work.
POOL_DRAW_WINDOW = 0x60
#: The highest id the roll can produce, and the last human set in that table.
POOL_SPEECH_MAX = 6

#: **The function that draws from both streams, and why that is correct.**
#: `0x004160F0` is in `aAnimations.cpp`.  It draws **twice from the counted
#: stream** to pick a candidate tile, retried up to five times and tested by
#: `aGenerateUnitElement`'s placement helper -- that is simulation, and it is
#: on the gameplay generator.  It then draws **once from the uncounted one**
#: and hands the result to a routine inside `aBlobs.cpp` -- that is an effect,
#: and it is on the presentation generator.  One function doing both jobs is
#: not one function mixing generators: the split `docs/22` §3.2 describes is
#: kept inside it, argument by argument.
BOTH_STREAMS_COUNTED_SITES = (0x004161BA, 0x004161D0)
BOTH_STREAMS_UNCOUNTED_SITE = 0x00416238
#: What each result is handed to.
BOTH_STREAMS_PLACEMENT_TEST = 0x00479C60
BOTH_STREAMS_EFFECT = 0x0042B070
#: `__ftol`, which follows every draw that is stored as an integer.
FTOL = 0x004AE7B6

#: **How each stream is seeded, and it is the whole story.**  At start-up,
#: inside `0x004494C0`, the engine does this and nothing else:
#:
#:     eax = GetTickCount()
#:     fild qword [esp+0x1c]        ; (double) of it
#:     seed_uncounted(that)         ; 0x00463850 -> 0x00514070
#:     aRandomize(1.0)              ; 0x00463820 -> 0x00514078
#:
#: So the **effects** stream is seeded from the wall clock and the
#: **gameplay** stream is seeded to a constant.  `docs/22` 3.1 already
#: records what the constant means -- a mission plays out identically every
#: time it is loaded -- and this is the other half of it: the *effects* were
#: never meant to repeat, which is why a shot's velocities differ run to run
#: while its damage does not.
RANDOM_UNCOUNTED_SEEDER = 0x00463850
RANDOM_SEEDING_SITE = 0x00449919
RANDOM_COUNTED_SEEDING_SITE = 0x00449927
RANDOM_TICK_COUNT_SITE = 0x00449901
#: The high dword of the IEEE double 1.0, pushed at the counted seed site.
RANDOM_COUNTED_START_SEED_HI = 0x3FF00000

# --------------------------------------------------------------------------
# Where a creator's origin comes from
# --------------------------------------------------------------------------
#
# `docs/97` 15.5 left "absolute z" and "floor plus a constant" undecided,
# because every occupied tile in the captured save is at height zero and the
# two are the same number there.  The disassembly decides it for all thirty
# without a capture, and the answer is **neither**.  A creator opens with
#
#     eax = aGetCtrlMapElementPtr(y, x)
#     dx  = word [eax + 5]                ; the symbol standing on the cell
#     eax = aGetSymbolObjectPtr(dx)
#     ecx = [eax + 0x10]  edx = [eax + 0x14]  eax = [eax + 0x18]
#
# so the origin is the **placed object's own position**, and `z` is that plus
# a constant the creator carries.  The control map's height dword at `+1` --
# the floor -- is read by **no creator at all**, which is the check below and
# the reason the native probe that raises it is a confirmation rather than the
# evidence.

#: The symbol lookup every creator goes through.
GET_SYMBOL_OBJECT = 0x00404C40
#: The object's position fields, as disp8 reads off the returned pointer.
SYMBOL_ORIGIN_FIELDS = (0x10, 0x14, 0x18)
#: The control map's height field.  `movemap_gold.CELL_HEIGHT`, and the one
#: displacement no creator reads.
CELL_HEIGHT_DISP = 0x01

#: How far past its entry a creator's body is scanned for calls to other
#: creators.  The same window `tools/blob_gold.py` scans with, kept here
#: because the table below is what pins it.  **This is a bound, not a
#: measurement**: widening it by a byte changes nothing, so a mutation battery
#: cannot show it is read.  The measurement is the line under it -- the
#: furthest offset at which a nested call actually appears -- and the check
#: requires the bound to clear it, which is what makes both live.
CREATOR_EXTENT = 1400
#: The furthest a creator's own body reaches to call another, and where.
#: `0x00424250` calls `0x00428F70` 1 349 bytes in, which is what decides how
#: wide the window above has to be.
CREATOR_NESTING_REACH = 1349
CREATOR_NESTING_FURTHEST = (0x00424250, 0x00428F70, 0x00424795)
#: creator -> the creators its own body calls.  A creator may build its effect
#: by running **another** creator, and the records that one leaves are in the
#: pool too: a cross-validation that collected only the constructor calls
#: whose nearest preceding entry was the creator itself missed them, and the
#: engine came back with a triple the static tables "did not have".  That
#: looked like the two readings disagreeing and was a missing edge.  Only the
#: eight creators below have one.
CREATOR_NESTED = {
    "0x00423D80": ["0x00423720"],
    "0x00424250": ["0x00423720", "0x00428F70"],
    "0x004247C0": ["0x00423720"],
    "0x00424D20": ["0x00423720"],
    "0x00426B70": ["0x00423720"],
    "0x00426F90": ["0x0042A9D0"],
    "0x00427410": ["0x0042A9D0"],
    "0x00428570": ["0x00423720"],
}
#: Whether the graph above is **flat**: no creator a creator calls calls a
#: third.  Pinned rather than assumed, because "one level of nesting is enough
#: for every creator here" was an observation about the fifteen that had run
#: and this makes it a statement about all thirty, with no capture involved.
CREATOR_NESTING_IS_FLAT = True


#: Where every numeric constant of `tools/inclib/blob_creators.py` lives in
#: `Incubation.exe`.  The ten transcribed creators were read out of their own
#: instructions, but *"read out of the disassembly"* is only a claim until
#: something re-reads it: `blob_gold.py`'s capture discriminates seven of the
#: thirteen and cannot reach the other six, and a constant no record exercises
#: is checked by nothing at all.  This is that something, and it needs **no
#: Wine and no capture** -- the same reason `CREATOR_ARITIES` lives here.
#:
#: Each entry names the site *and how the site encodes the number*, because
#: they are not all doubles:
#:
#: * ``f64`` -- a cell in the constant block at `0x004B12xx`, reached by an
#:   ``fmul qword [cell]`` inside the named creator.  Two names share
#:   `0x004B12B0`: the blue beam's dot speed and the machine gun's casing
#:   speed are **one cell read by two creators**, so thirteen names stand
#:   over twelve distinct cells.
#: * ``lea`` / ``add`` -- an immediate the creator subtracts, held negated as
#:   the instruction's own disp32.
#: * ``magic`` -- a divisor the compiler turned into a reciprocal multiply.
#:   There is no ``0x960`` anywhere in these bytes; the check recovers the
#:   divisor by **replaying the multiply** over a swept dividend and requiring
#:   it to agree with a truncating divide everywhere.
#: * ``scale`` -- `TRACER_LEAN`'s 200, which is a ``lea``/``lea``/``shl``
#:   product over a ``sar``: `5 * 5 * 32 >> 2`.
#:
#: The fourth element is the value the *site* holds, signed as the binary
#: holds it; the check requires its magnitude to equal the Python constant's,
#: so a creator that reads the negative cell and one that reads the positive
#: are both pinned without giving the module two names for one number.
CREATOR_CONSTANT_SITES: dict[str, tuple[tuple[str, int, object, float], ...]] = {
    "SPARK_SPEED":   (("f64", 0x0042A9D0, 0x004B12B8, 1600.0),),
    "SHARD_SPEED":   (("f64", 0x004264A0, 0x004B12D0, 1920.0),),
    "DOT_SPEED":     (("f64", 0x00427410, 0x004B12B0, 80.0),),
    "CASING_SPEED":  (("f64", 0x00424D20, 0x004B12A8, -80.0),
                      ("f64", 0x00424D20, 0x004B12B0, 80.0)),
    "TRACER_SPREAD": (("f64", 0x00424D20, 0x004B1298, -640.0),
                      ("f64", 0x00424D20, 0x004B12A0, 640.0)),
    "BEAM_STEP":     (("f64", 0x00424D20, 0x004B1278, -2400.0),),
    "HEAD_STEP":     (("f64", 0x00427810, 0x004B12E0, -3200.0),),
    "HEAD_SPEED":    (("f64", 0x00427810, 0x004B12E8, 4800.0),),
    "TRAIL_STEP":    (("f64", 0x00425810, 0x004B12C0, -960.0),),
    "BEAM_BASE":     (("lea", 0x00426F90, 0x004272A0, -0xC80),
                      ("add", 0x00425810, 0x00425AAC, -0xC80)),
    "BEAM_UNIT":     (("lea", 0x00427810, 0x004279DA, -0x960),
                      ("magic", 0x00426F90, 0x004272A6, 0x960)),
    "TRAIL_UNIT":    (("magic", 0x00425810, 0x00425AB2, 0x3C0),),
    "TRACER_LEAN":   (("scale", 0x00424D20,
                       (0x00425117, 0x0042511E, 0x00425121, 0x00425132), 200),),
    # The death and damage creators' doubles (`docs/42` §4.8.1): the blood
    # sprays' velocity, lift and step terms and the species coin, read by
    # `fmul` or -- the coin -- `fcomp` inside the creator each is attributed
    # to.  `presentation_gold.py` measures them; this reads them back.
    "BLOOD_VELOCITY":       (("f64", 0x00420D80, 0x004B1248, 16.0),),
    "BLOOD_VELOCITY_LARGE": (("f64", 0x00421360, 0x004B1260, 48.0),),
    "BLOOD_LIFT":           (("f64", 0x00420D80, 0x004B1250, 160.0),
                             ("f64", 0x00421360, 0x004B1250, 160.0)),
    "BLOOD_STEP":           (("f64", 0x00420D80, 0x004B1258, -1280.0),
                             ("f64", 0x00421360, 0x004B1258, -1280.0)),
    "SPECIES_COIN":         (("f64", 0x00421C50, 0x004B1268, 6.0),),
    # `docs/97` §49 -- the scratch **name** buffer, which an arm hands the
    # constructor for a class-2 record and which the constructor ignores.  It
    # is an address, so the two creators below push it rather than compute
    # with it; `BLOB_NAME_SCRATCH` above is the same number read from the
    # constructor's own guard.
    "NAME_SCRATCH":         (("push", 0x00428E30, 0x00428EAC, 0x004FA524),
                             ("push", 0x00429390, 0x00429409, 0x004FA524)),
    # docs/42 §7 -- the unit animations' creators (docs/97 §31): the radii
    # are `mov r32, imm32` and the turns `mov word [esp+d], imm16`, read
    # at their own instructions.
    "RING_RADIUS":          (("mov", 0x00422D40, 0x00422E13, 0x12C0),),
    "RING_RADIUS_LARGE":    (("mov", 0x00422D40, 0x00422E0C, 0x2580),),
    "FLASH_RADIUS":         (("mov", 0x00423030, 0x00423117, 0x640),
                             ("mov", 0x004232E0, 0x004233BF, 0x640)),
    "FLASH_RADIUS_LARGE":   (("mov", 0x00423030, 0x0042310C, 0x1900),
                             ("mov", 0x004232E0, 0x004233B0, 0x1900)),
    "DUST_RADIUS":          (("mov", 0x004227C0, 0x00422834, 0xC80),),
    "DUST_TURN":            (("word", 0x004227C0, 0x00422868, 0xCC),),
    # docs/42 §8 -- the set pieces' creators (docs/97 §32).
    "LASER_OFFSET":         (("f64", 0x00428990, 0x004B1270, -1600.0),),
    "LASER_STEP":           (("f64", 0x00428990, 0x004B12E0, -3200.0),),
    "BOMBER_SPEED":         (("f64", 0x0042A8E0, 0x004B1300, 3200.0),),
    "TUBE_PAIRS":           (("cmp", 0x00423770, 0x004238AC, 15),),
    "PLATFORM_DUST_SPREAD": (("lea", 0x004234C0, 0x004234DE, -0x12C0),),
    "PLATFORM_DUST_UP":     (("lea", 0x004234C0, 0x004234D8, 0x640),),
    "FIRE_CIRCLE_FLAMES":   (("cmp32", 0x00422F00, 0x00423010, 150),),
    "FIRE_CIRCLE_TURN":     (("word", 0x00422F00, 0x00422FA2, 0x3C),),
    "FIRE_CIRCLE_RADIUS":   (("mov", 0x00422F00, 0x00422F74, 0xC80),),
    "STREAM_RECORDS":       (("cmp32", 0x0042A120, 0x0042A2D5, 200),),
    "STREAM_STEP":          (("add8", 0x0042A120, 0x0042A2D1, 16),),
    "BOMB_CEILING":         (("mov", 0x0042B070, 0x0042B0D3, 0x8980),),
    "BOMB_DROP":            (("push", 0x0042B070, 0x0042B12E, 0xBB80),),
    "BOMB_FALL":            (("push", 0x0042B070, 0x0042B103, -800),),
}
#: The death creators are not in `CREATOR_DRAW_SITES` (no weapon switch
#: reaches them), so their extents are written down: each ends where the
#: next routine begins.
DEATH_CREATOR_EXTENTS = {
    0x00423770: (0x00423770, 0x004238BF),
    0x004234C0: (0x004234C0, 0x00423668),
    0x00422610: (0x00422610, 0x004227B0),
    0x00422460: (0x00422460, 0x00422603),
    0x004238C0: (0x004238C0, 0x00423ABF),
    0x00422F00: (0x00422F00, 0x00423024),
    0x00428990: (0x00428990, 0x00428BCD),
    0x00428BF0: (0x00428BF0, 0x00428E21),
    0x0042A120: (0x0042A120, 0x0042A2E9),
    0x0042A8E0: (0x0042A8E0, 0x0042A9BA),
    0x0042B070: (0x0042B070, 0x0042B149),
    0x00422D40: (0x00422D40, 0x00422EF1),
    0x004227C0: (0x004227C0, 0x004228E8),
    0x00423030: (0x00423030, 0x004232CF),
    0x004232E0: (0x004232E0, 0x004234B2),
    0x00420D80: (0x00420D80, 0x00421360),
    0x00421360: (0x00421360, 0x004216D0),
    0x00421C50: (0x00421C50, 0x00422460),
    # `docs/97` §49 -- the twelve an update **arm** calls.  Ends are the
    # function's own last byte, as above.
    0x00420950: (0x00420950, 0x00420A49),
    0x00428E30: (0x00428E30, 0x00428ECD),
    0x00428ED0: (0x00428ED0, 0x00428F6D),
    0x00428F70: (0x00428F70, 0x00429173),
    0x00429390: (0x00429390, 0x0042942A),
    0x00429430: (0x00429430, 0x004294DD),
    0x0042A410: (0x0042A410, 0x0042A47A),
    0x0042A480: (0x0042A480, 0x0042A4BA),
    0x0042A7A0: (0x0042A7A0, 0x0042A8D9),
    0x0042ADD0: (0x0042ADD0, 0x0042AF00),
    0x0042B150: (0x0042B150, 0x0042B1CF),
    0x0042B300: (0x0042B300, 0x0042B3AA),
}
#: How many dividends the ``magic`` replay sweeps.  A reciprocal multiply that
#: agrees with a truncating divide over this many values, negative and
#: positive, is that divisor.
MAGIC_SWEEP = range(-300000, 300001, 7)

# --------------------------------------------------------------------------
# The output system, because kind 59's arm branches on it
# --------------------------------------------------------------------------
#
# `docs/97` §23.3 named `0x00512A78` -- the byte kind 59's arm asks
# `0x00461E80` for -- as the display mode, and tabulated what each of
# `aCreateOutputSystem`'s five cases writes beside it.  Two columns of that
# table were **interpretations**: `0x00512A9C` was called a pitch and
# `0x00512A60` a bytes-per-pixel because their values looked like it.  A
# number named by its value is a guess with good handwriting, which is the
# rule this layer has been bitten by twice.  These pins are the reading.

#: The globals `aCreateOutputSystem` `0x00461310` writes and the drawing code
#: reads.  Named, not inferred -- see the checks below for which reading
#: names which.
OUTPUT_MODE_GLOBAL = 0x00512A78
OUTPUT_WIDTH = 0x00512A54
OUTPUT_HEIGHT = 0x00512A58
OUTPUT_BPP = 0x00512A60
OUTPUT_BASE = 0x00512A98
OUTPUT_STRIDE = 0x00512A9C
OUTPUT_FORMAT = 0x00512AA0

#: The five cases, each field as ``(how the value is encoded, where the value
#: is, where it is stored)``.  ``load`` is a ``mov r32, imm32`` feeding a
#: later store; ``store_imm``/``store_imm8`` carry the value in the store
#: itself; ``xor`` is the zeroed register two cases store.  The store site is
#: checked to target the global its column names, so a pinned value that
#: stopped feeding that global fails rather than being read anyway.
OUTPUT_MODE_CASES: tuple[dict[str, Any], ...] = (
    {"name": "windowed_640",
     "height": ("load", 0x0046135E, 0x0046136A),
     "mode":   ("xor", 0x0046133F, 0x0046138B),
     "width":  ("load", 0x00461375, 0x0046137A),
     "bpp":    ("load", 0x00461347, 0x0046137F),
     "stride": ("load", 0x00461375, 0x004613A7)},
    {"name": "windowed_320",
     "height": ("load", 0x004613CF, 0x004613EB),
     "mode":   ("xor", 0x004613C8, 0x004613FC),
     "width":  ("load", 0x004613CA, 0x004613E5),
     "bpp":    ("load", 0x004613D4, 0x004613F0),
     "stride": ("store_imm", 0x0046141F, 0x0046141F)},
    {"name": "directdraw_8",
     "height": ("load", 0x00461455, 0x0046146D),
     "mode":   ("load", 0x00461444, 0x0046147F),
     "width":  ("load", 0x00461450, 0x00461468),
     "bpp":    ("load", 0x00461444, 0x00461473),
     "stride": ("load", 0x00461450, 0x0046149B)},
    {"name": "directdraw_16",
     "height": ("load", 0x0046150C, 0x0046152A),
     "mode":   ("load", 0x00461511, 0x0046153C),
     "width":  ("load", 0x00461507, 0x00461525),
     "bpp":    ("load", 0x00461511, 0x00461530),
     "stride": ("store_imm", 0x00461569, 0x00461569)},
    {"name": "card_3d",
     "height": ("load", 0x004615B2, 0x004615B9),
     "mode":   ("store_imm", 0x004615F4, 0x004615F4),
     "width":  ("load", 0x004615CB, 0x004615E2),
     "bpp":    ("store_imm8", 0x004615E7, 0x004615E7),
     "stride": ("store_imm", 0x0046161F, 0x0046161F)},
)
#: ``(name, mode, width, height, bpp, stride)`` as the five cases hold them.
OUTPUT_MODE_TABLE = (
    ("windowed_640", 0, 640, 480, 1, 640),
    ("windowed_320", 0, 320, 200, 1, 640),
    ("directdraw_8", 1, 640, 480, 1, 640),
    ("directdraw_16", 2, 640, 480, 2, 1280),
    ("card_3d", 3, 640, 480, 2, 1280),
)
#: The cases whose stride is **not** ``width * bpp``.  This one line is why
#: `0x00512A9C` cannot be a derived quantity: the 320x200 mode reserves 640
#: bytes a row for a 320-byte row.  A padded row is a stride and nothing else.
OUTPUT_STRIDE_NOT_DERIVED = ("windowed_320",)

#: `0x00463C40` -- the pixel plot, and the reading that settles what the
#: stride *is*.  It takes ``(base, x, y, colour, stride, format)`` on the
#: stack at ``+4 +8 +0x0C +0x10 +0x14 +0x18`` and has three arms.  Each entry
#: is ``(arm, stride displacement, row displacement, stride halved first,
#: store width in bytes, index scale)``.
#:
#: The eight-bit arm multiplies the stride by the row and stores a **byte**
#: at ``base + that + x``; the two sixteen-bit arms **halve** it first and
#: store a **word** through an index scaled by two -- the same address.  One
#: number can only behave both ways if it counts *bytes* per row.
PLOT_ROUTINE = (0x00463C40, 0x00463CB1, "c54b4922322da7cf")
PLOT_PATHS: tuple[tuple[str, int, int], ...] = (
    ("palette_8", 0x00463C4A, 0x00463C65),
    ("rgb565_to_555", 0x00463C65, 0x00463C92),
    ("rgb_word", 0x00463C92, 0x00463CB1),
)
PLOT_EXPECTED = (
    ("palette_8", 0x14, 0x0C, False, 1, 1),
    ("rgb565_to_555", 0x14, 0x0C, True, 2, 2),
    ("rgb_word", 0x14, 0x0C, True, 2, 2),
)
#: The two one-instruction getters.
OUTPUT_GETTERS = (
    ("stride", 0x00461E60, OUTPUT_STRIDE),
    ("format", 0x00461E70, OUTPUT_FORMAT),
)
#: The five cases' byte ranges, digested.  `output.mode_stores` proves each
#: pinned store writes the global its column names, but not that the register
#: it stores is still the one the pinned ``mov r32, imm32`` filled -- nothing
#: touches those registers in between, and this is what keeps that true.
OUTPUT_MODE_RANGES = (
    ("windowed_640", 0x00461339, 0x004613C8, "3bb0bf387de39bdb"),
    ("windowed_320", 0x004613C8, 0x0046143A, "14cc686da71a9ff0"),
    ("directdraw_8", 0x0046143A, 0x004614F1, "28e4587692e72ab7"),
    ("directdraw_16", 0x004614F1, 0x004615B2, "8e98fbfc2808a182"),
    ("card_3d", 0x004615B2, 0x0046163C, "a40e3822252d2ac2"),
)

#: `0x00461E90` is the six-way output-info getter -- **not** a recovered
#: symbol; nothing names it, and its own error string for an index above five
#: is ``"unknown infotype"``.  Its arms are reached through a jump table at
#: `OUTPUT_INFO_TABLE`, and the table's order is **not** the arms' order in
#: the code, which is exactly the trap that makes reading it rather than
#: eyeballing it worth the twenty lines.
OUTPUT_INFO_GETTER = 0x00461E90
OUTPUT_INFO_TABLE = 0x00461EE8
#: What each index returns, read out of that table.
OUTPUT_INFO_GLOBALS = (0x00512A4C, 0x00512A50, OUTPUT_BPP, OUTPUT_HEIGHT,
                       OUTPUT_WIDTH, 0x00512A5C)
#: The index that is the bytes-per-pixel byte, and the only arm of the six
#: that masks its dword down to one.
OUTPUT_INFO_BPP_INDEX = 2
#: `0x004479DC` -- ``push 2 / call the getter / cmp eax, 1 / jne``: a caller
#: branching on "is this one byte a pixel", which is what settles what index
#: 2 holds.  `0x00447A70` is where the far side of that branch multiplies a
#: clipped horizontal extent by the same byte.
OUTPUT_BPP_GATE_SITE = 0x004479DC
OUTPUT_BPP_SCALE_SITE = 0x00447A70

# --------------------------------------------------------------------------
# Where the stride the lock copies actually comes from
# --------------------------------------------------------------------------
#
# `docs/97` §23.4 named `0x00512A9C` a stride from the drawing code's
# arithmetic and then said, in as many words, that the *source* was not read:
# the lock `0x004617B0` takes it from ``[obj + 0x28]`` of whatever
# `0x00432C30` returns, and nothing here had a reading of that object.
#
# There is no object.  `0x00432C30` is ``mov eax, 0x004FEC80 / ret`` -- it
# returns the **address of a static block**, aLIB's DirectDraw module state,
# and every routine that touches it pushes ``"C:\aProject\aLIB\aDDraw.cpp"``
# on its error path.  At ``+0x18`` of that block sits a `DDSURFACEDESC`: both
# lock helpers write ``dwSize = 0x6C`` into it -- 108, ``sizeof(DDSURFACEDESC)``
# -- hand its address to the vtable slot at ``+0x64`` and, on failure, push
# the label ``"DD_Lock"``.  Slot ``0x64`` is index 25, which is
# ``IDirectDrawSurface::Lock``.
#
# So the two numbers are fields of a **public ABI**, not readings of an
# unknown layout: ``+0x28`` is ``0x4FEC98 + 0x10``, `DDSURFACEDESC.lPitch`,
# documented as the distance in bytes to the start of the next line; and the
# pointer those same helpers return, `0x004FECBC`, is ``+0x24``,
# `DDSURFACEDESC.lpSurface` -- which is what `OUTPUT_BASE` gets.  Neither is
# written by an instruction anywhere in the image, which is the check below
# that would look strangest without this paragraph.

#: aLIB's DirectDraw module state, and the accessor that hands out its
#: address.  The accessor is two instructions and they are pinned whole.
DDRAW_MODULE = 0x004FEC80
DDRAW_ACCESSOR = 0x00432C30
DDRAW_ACCESSOR_BYTES = bytes.fromhex("b880ec4f00" "c3")
#: The `DDSURFACEDESC` embedded at ``+0x18``, and the three offsets of the
#: public structure that matter here.  ``dwSize`` is what identifies it.
DDRAW_DESC_OFFSET = 0x18
DDRAW_DESC = DDRAW_MODULE + DDRAW_DESC_OFFSET
DDSURFACEDESC_SIZE = 0x6C
DDSURFACEDESC_PITCH = 0x10
DDSURFACEDESC_SURFACE = 0x24
#: ``IDirectDrawSurface::Lock`` -- vtable index 25, IUnknown's three then
#: ``AddAttachedSurface`` through ``IsLost``.  The same slot in the v1, v2
#: and v3 interfaces.
SURFACE_LOCK_SLOT = 0x64
#: The two lock helpers, as ``(name, entry, the module field the entry loads,
#: desc push, dwSize store, vtable call, file push, label push, success
#: arm)``.  The entry's own ``mov eax, [module field]`` is read too, so the
#: entry address is a claim rather than a label.  One locks the surface the
#: module holds at ``+0x0C``; the other locks entry *n* of the twenty-byte
#: table at `0x004FEDE8`.  Neither surface is named here -- this file has no
#: reading of where either was created.
DDRAW_LOCK_HELPERS: tuple[
    tuple[str, int, int, int, int, int, int, int, int], ...] = (
    ("table_surface", 0x00433550, 0x004FEC88, 0x00433580, 0x0043358A,
     0x0043359E, 0x004335A5, 0x004335AF, 0x004335BF),
    ("module_surface", 0x004335D0, 0x004FEC8C, 0x004335D9, 0x004335E3,
     0x004335ED, 0x004335F4, 0x004335FE, 0x0043360E),
)
DDRAW_SOURCE_FILE = "C:\\aProject\\aLIB\\aDDraw.cpp"
DDRAW_LOCK_LABEL = "DD_Lock"

#: `0x004617B0`'s four-way dispatch on the display mode, and the span of each
#: arm.  Only two of the four take the stride from `lPitch`; naming the whole
#: table a DirectDraw pitch would overclaim by half.
LOCK_ENTRY = 0x004617B0
LOCK_JUMP_TABLE = 0x00461864
#: ``(mode, arm)`` -- modes 1 and 2 share one arm, so the span belongs to the
#: arm and is kept beside it rather than repeated here.
LOCK_ARMS: tuple[tuple[int, int], ...] = (
    (0, 0x00461844), (1, 0x004617EE), (2, 0x004617EE), (3, 0x004617D0),
)
#: ``arm -> (span end, where the stride comes from, the span digested)``.  The
#: source is **derived** from the arm's bytes by `_lock_arm_source`, not
#: asserted; the digest is what makes the span a claim, so a window quietly
#: widened past its arm fails.
LOCK_ARM_SPANS: dict[int, tuple[int, str, str]] = {
    0x00461844: (0x00461860, "unchanged", "c48e7e33c94c0742"),
    0x004617EE: (0x00461844, "lPitch", "dba015a454b42bdc"),
    0x004617D0: (0x004617EE, "eng3d", "b5138c18119b46e1"),
}
#: The indirect the third arm calls instead of locking anything: an Eng3d
#: entry point, which fills the stride through a pointer argument.
LOCK_ENG3D_SLOT = 0x004FA420
#: The two ``mov r32, [eax + disp]`` the `lPitch` arm reaches after calling
#: the accessor.  The displacement is **read** from them, so the arithmetic
#: below is a reading of the code and not of the constants beside it.
LOCK_PITCH_READS = (0x00461805, 0x00461831)


#: `aBlob_CreateMachineGun`'s two tracers, term by term -- the one place in
#: the ten transcriptions where a coordinate is built from a **different
#: axis'** ratio, and the one whose component-to-axis mapping was originally
#: fixed by matching records rather than read.  It is read now, off the stack:
#:
#: ``0x00424FC6`` hands the direction service three out-pointers and the
#: creator's frame settles back to one baseline ``S`` after the
#: ``add esp, 0x24`` at ``0x004250E5``, so ``d0``, ``d1`` and ``d2`` live at
#: ``S+0x20``, ``S+0x28`` and ``S+0x38``.  Each term below names the
#: ``fld qword [esp+disp]`` that loads its component and the stack **depth**
#: at that instruction, and ``disp - depth`` is the component's slot.  Two
#: roles: ``lean`` is the ``lea``/``lea``/``shl``-over-``sar`` product of 200,
#: ``spread`` the ``fmul`` by the named +-640 cell.
#:
#: ``(record, coordinate, role, fld site, disp, depth, cell)``
TRACER_AXIS_TERMS: tuple[tuple[int, str, str, int, int, int, int | None], ...] = (
    (0, "y", "lean",   0x00425100, 0x2C, 0x0C, None),
    (0, "y", "spread", 0x0042511A, 0x54, 0x2C, 0x004B1298),
    (0, "x", "lean",   0x0042513A, 0x54, 0x2C, None),
    (0, "x", "spread", 0x00425152, 0x50, 0x30, 0x004B12A0),
    (1, "y", "lean",   0x0042519F, 0x20, 0x00, None),
    (1, "y", "spread", 0x004251C1, 0x54, 0x2C, 0x004B12A0),
    (1, "x", "lean",   0x004251E1, 0x54, 0x2C, None),
    (1, "x", "spread", 0x004251F9, 0x50, 0x30, 0x004B1298),
)
#: The direction service's three out-slots, relative to that baseline.
TRACER_DIRECTION_SLOTS = {0x20: 0, 0x28: 1, 0x38: 2}
#: The two blocks the terms were read out of, so a change anywhere in them --
#: including one this table has no column for -- re-opens the reading rather
#: than passing under it.  ``(lo, hi, sha256 prefix)``.
TRACER_AXIS_BLOCKS = (
    (0x004250F0, 0x0042518A, "599903f18ce9fd0f"),
    (0x0042519B, 0x00425231, "71593e821b2e71f5"),
)


# --------------------------------------------------------------------------
# The set-piece frame counts and steps, read a second time
# --------------------------------------------------------------------------
#
# `docs/20` 7.4 recovered these out of the four animation routines, and this
# file quoted the numbers.  A quoted number is not a pin: the mutation battery
# perturbed all six and nothing noticed, because nothing here had a **second**
# reading to compare against.  These decode the routines themselves -- the loop
# counter's `mov imm32` proved to be a counter by the `dec` that follows it,
# and the `lea`/`shl` pairs the compiler emitted for each per-frame step.

def _scaled(b: Binary, sites) -> int | None:
    """The product of a run of `lea r,[b+b*n]` / `shl r,imm` multipliers.

    ``None`` if any site is not one of those two forms, so a moved or mutated
    address reads as "not the instruction I expected".
    """
    total = 1
    for va in sites:
        factor = b.lea_scale(va)
        if factor is None:
            factor = b.shl_scale(va)
        if factor is None:
            return None
        total *= factor
    return total


def check_mission_sound(ck: Checker, b: Binary) -> None:
    """docs/28 2.5 and 4.3 -- the mission interface's clicks and unit speech.

    Two readings that share no code with ``inclib.sound``: every claim here is
    decoded out of ``Incubation.exe``'s bytes at the address the table names.
    """
    # ---- 2.5  the four buffers aInitBattleGround loads -------------------
    ck.equal("mission_sound.interface_loads",
             {wave: (b.push_str(push), b.push_imm(push + 0x10))
              for wave, (push, _global) in sorted(sound.INTERFACE_LOADS.items())},
             {wave: (wave, handle)
              for wave, (_push, handle) in sorted(sound.INTERFACE_LOADS.items())},
             Checker.brief)
    # The id-96 set of 2.1 minus the two the mission never reaches.
    ck.equal("mission_sound.interface_partition",
             tuple(sorted(sound.INTERFACE_LOADS)),
             tuple(sorted(w.lower() for w in sound.INTERFACE_WAVES
                          if w not in sound.INTERFACE_OUTSIDE_THE_MISSION
                          and w != "textbeep.wav")),
             Checker.brief)
    # ---- 2.5  every play site, and the handle it really loads ------------
    ck.equal("mission_sound.interface_cues",
             {name: (b.abs_load(cue.load) or (None, 0))[0]
              for name, cue in sorted(sound.INTERFACE_CUES.items())},
             {name: cue.buffer
              for name, cue in sorted(sound.INTERFACE_CUES.items())},
             Checker.brief)
    ck.check("mission_sound.interface_load_feeds_play",
             all(cue.load < cue.site <= cue.load
                 + (b.abs_load(cue.load) or (0, 0))[1] + 4
                 for cue in sound.INTERFACE_CUES.values()),
             "each load is the play call's own, three pushes in front of it")
    ck.equal("mission_sound.interface_play_targets",
             sorted({b.call_target(cue.site)
                     for cue in sound.INTERFACE_CUES.values()}),
             [SOUND_PLAY], _hexlist)
    # Every buffer a cue names is one of the six the two modules were handed,
    # and every one of the six is used by at least one cue.
    ck.equal("mission_sound.interface_buffers",
             sorted({cue.buffer for cue in sound.INTERFACE_CUES.values()}),
             sorted(sound.INTERFACE_BUFFERS), _hexlist)
    ck.equal("mission_sound.interface_buffer_waves",
             sorted({sound.INTERFACE_BUFFERS[cue.buffer]
                     for cue in sound.INTERFACE_CUES.values()}),
             sorted(sound.INTERFACE_LOADS), Checker.brief)

    # ---- 4.3  the speech routine's two switches --------------------------
    ck.equal("speech.category_bound", b.cmp_imm(sound.SPEECH_CATEGORY_BOUND_SITE),
             sound.SPEECH_CATEGORY_CASES - 1)
    ck.equal("speech.set_bound", b.cmp_imm(sound.SPEECH_SET_BOUND_SITE),
             sound.SPEECH_SET_CASES - 1)
    arms = b.jump_table(sound.SPEECH_CATEGORY_TABLE, sound.SPEECH_CATEGORY_CASES)
    ck.equal("speech.category_arms",
             {i: a for i, a in enumerate(arms) if i in sound.SPEECH_ARMS},
             {i: arm.site for i, arm in sorted(sound.SPEECH_ARMS.items())},
             _hexmap)
    # The three arguments that print `0000`: their entries are the arm the
    # bound test jumps to, so they are the switch's own default.
    default = {a for i, a in enumerate(arms) if i not in sound.SPEECH_ARMS}
    ck.equal("speech.silent_arguments",
             tuple(sorted(i for i, a in enumerate(arms)
                          if i not in sound.SPEECH_ARMS)),
             sound.SPEECH_SILENT_ARGUMENTS)
    ck.check("speech.silent_arguments_share_one_arm", len(default) == 1,
             "the three send the switch to one address")
    # Each arm's own category immediate, read at the `mov byte [esp+0x10]`
    # the arm ends with.
    ck.equal("speech.categories",
             {i: _speech_category(b, arm)
              for i, arm in sorted(sound.SPEECH_ARMS.items())},
             {i: arm.category for i, arm in sorted(sound.SPEECH_ARMS.items())},
             Checker.brief)
    # The cursor arms: the global, and the value that wraps it.
    ck.equal("speech.cursors",
             {i: _speech_cursor(b, arm.site)
              for i, arm in sorted(sound.SPEECH_ARMS.items())
              if arm.cursor is not None},
             {i: (arm.cursor, arm.modulus)
              for i, arm in sorted(sound.SPEECH_ARMS.items())
              if arm.cursor is not None}, Checker.brief)
    ck.equal("speech.unused_cursor",
             b.cmp_abs_imm(sound.SPEECH_ARMS[0].site),
             sound.SPEECH_UNUSED_CURSOR)
    # The drawing arms: `push span / push base / call aRandom2`.
    ck.equal("speech.draws",
             {i: _speech_draw(b, arm.site)
              for i, arm in sorted(sound.SPEECH_ARMS.items())
              if arm.draw is not None},
             {i: arm.draw for i, arm in sorted(sound.SPEECH_ARMS.items())
              if arm.draw is not None}, Checker.brief)
    ck.check("speech.draws_are_the_presentation_generator",
             all(b.call_target(_speech_draw_site(b, arm.site))
                 == sound.SPEECH_RANDOM
                 for arm in sound.SPEECH_ARMS.values() if arm.draw),
             "every index draw goes to aRandom2 and not to aRandom")
    # ---- 4.3  the twelve speech sets -------------------------------------
    set_arms = b.jump_table(sound.SPEECH_SET_TABLE, sound.SPEECH_SET_CASES)
    named = {i + 1: a for i, a in enumerate(set_arms)}
    ck.equal("speech.sets",
             {i: _speech_set(b, named[i], set_arms)
              for i in sorted(sound.SPEECH_SETS)},
             {i: (prefix, directory)
              for i, (directory, prefix) in sorted(sound.SPEECH_SETS.items())},
             Checker.brief)
    ck.equal("speech.silent_sets",
             tuple(i for i in range(1, sound.SPEECH_SET_CASES + 1)
                   if i not in sound.SPEECH_SETS), (8, 9))
    ck.equal("speech.random_set_gate",
             b.cmp_imm(SPEECH_RANDOM_GATE), sound.SPEECH_RANDOM_SET)
    ck.equal("speech.random_set_draw",
             _speech_draw(b, SPEECH_RANDOM_GATE), sound.SPEECH_RANDOM_DRAW)
    # ---- 4.3  the format, the buffer and the gates -----------------------
    ck.equal("speech.format",
             tuple(b.push_str(site) for site in sound.SPEECH_FORMAT_SITES),
             (sound.SPEECH_FORMAT,) * len(sound.SPEECH_FORMAT_SITES),
             Checker.brief)
    ck.equal("speech.buffer",
             sorted({b.push_imm(SPEECH_BUFFER_PUSH)}), [sound.SPEECH_BUFFER],
             _hexlist)
    ck.equal("speech.hurt_threshold",
             sorted({b.u8(site + 1) for site in SPEECH_HURT_SITES}),
             [sound.SPEECH_HURT_THRESHOLD])
    ck.equal("speech.mute_type", b.u8(SPEECH_MUTE_SITE + 3),
             sound.SPEECH_MUTE_TYPE)
    ck.equal("speech.unowned", b.u8(SPEECH_UNOWNED_SITE + 3),
             sound.SPEECH_UNOWNED)
    # ---- 4.3  who asks, and for what -------------------------------------
    ck.equal("speech.calls",
             sorted(site for sites in sound.SPEECH_CALLS.values()
                    for site in sites),
             sorted(b.calls_to(SPEECH_ROUTINE)), _hexlist)
    ck.equal("speech.arguments",
             {event: tuple(sorted({b.push_imm(site) for site in sites}))
              for event, sites in sorted(sound.SPEECH_ARGUMENT_SITES.items())},
             {event: tuple(sorted(args)) for event, args
              in sorted(sound.SPEECH_EVENT_ARGUMENTS.items())},
             Checker.brief)
    # Two whole shipped categories nothing asks for: 6 wants argument 6 and 7
    # wants argument 7, and no site pushes either.
    asked = {b.push_imm(site)
             for sites in sound.SPEECH_ARGUMENT_SITES.values() for site in sites}
    reached = {arm.category for i, arm in sound.SPEECH_ARMS.items()
               if i in asked}
    ck.equal("speech.dead_categories",
             tuple(c for c in sound.SPEECH_SHIPPED_CATEGORIES
                   if c not in reached),
             sound.SPEECH_DEAD_CATEGORIES)


#: ``aDirectSoundPlay`` -- the one routine every play site above calls.
SOUND_PLAY = 0x00436EF0
#: ``fcn.0047B660``, the speech routine itself.
SPEECH_ROUTINE = 0x0047B660
#: ``cmp dl, 0x0C`` -- the random set's own test, past the name build.
SPEECH_RANDOM_GATE = 0x0047BAD5
#: ``push 0x00518350`` -- the buffer handed to the create call.
SPEECH_BUFFER_PUSH = 0x0047BB84
#: The two ``mov al, 3`` / ``cmp`` pairs the selection sites gate on.
SPEECH_HURT_SITES = (0x00471A15, 0x00471F19)
#: ``cmp byte [esi + 0x4C], 0x14`` and ``cmp byte [esi + 0x45], 0xFF``.
SPEECH_MUTE_SITE = 0x0047B872
SPEECH_UNOWNED_SITE = 0x0047B868


def _speech_category(b: Binary, arm: sound.SpeechArm) -> int | None:
    """The ``mov byte [esp + 0x10], ii`` an arm leaves the category in."""
    found = b.esp_byte_imm(arm.category_site)
    if found is None or found[0] != sound.SPEECH_CATEGORY_SLOT:
        return None
    return found[1]


def _speech_cursor(b: Binary, arm: int) -> tuple[int, int] | None:
    """``mov eax, [cursor] / cmp eax, N`` -> ``(cursor, N)``."""
    load = b.abs_load(arm)
    if load is None:
        return None
    return load[0], b.cmp_imm(arm + load[1])


def _speech_draw_site(b: Binary, arm: int) -> int:
    """The ``call aRandom2`` inside one drawing arm."""
    for va in range(arm, arm + 0x40):
        if b.u8(va) == 0xE8 and b.call_target(va) == sound.SPEECH_RANDOM:
            return va
    return arm


def _speech_draw(b: Binary, arm: int) -> tuple[int, int] | None:
    """``push span / push base / call aRandom2`` -> ``(base, span)``."""
    site = _speech_draw_site(b, arm)
    if site == arm:
        return None
    return b.push_imm(site - 2), b.push_imm(site - 4)


def _speech_set(b: Binary, arm: int, arms) -> tuple[str, str] | None:
    """One set arm's ``(file prefix, directory)``, both as ``mov`` immediates."""
    strings = b.arm_strings(arm, arms)
    if len(strings) < 2:
        return None
    return strings[0], strings[-1]


def _hexmap(value) -> str:
    return "{" + ", ".join("%d: 0x%08X" % (k, v)
                           for k, v in sorted(value.items())) + "}"


def _sites_with_volume(sites: dict, volume_id: int) -> set[str]:
    """The wave names among *sites* scaled by *volume_id*."""
    return {name.lower() for name, volume in sites.values()
            if name and volume == volume_id}


#: Where the remake spells the compatibility flag names. Resolved against this
#: file rather than the working directory: a check that cannot find its input
#: must fail, not quietly pass.
REMAKE_AUDIO_DIR = Path(__file__).resolve().parent.parent / "godot" / "game" / "audio"


#: Where the remake keeps the arms and the creator programs.
REMAKE_FX_DIR = Path(__file__).resolve().parent.parent / "godot" / "game" / "fx"

#: `blob_kinds.gd` requests that carry **fewer values than the creator takes**,
#: as `creator constant -> (values passed, how many sites)`.  **Empty**, and
#: the emptiness is the point.
#:
#: It was not, for one day.  Wiring the arms' spawn requests to the creator
#: programs for the first time (`godot/game/fx/game_blob_hooks.gd`) made the
#: count load-bearing, and five of the seven `0x00423720` requests turned out
#: to be one value short: the callee reads six arguments -- `x` at `+0x04`
#: through `life` at `+0x18` -- and all fourteen of its call sites clean six
#: dwords.  Both twins carried the same shortfall, so the arm capture could
#: not see it: it compared the stepped record's fields and the request list,
#: GDScript against Python, and never a request against the engine's own push
#: block.
#:
#: The five were settled by **stepping the arms inside `Incubation.exe`**
#: (2026-09-04, `docs/97` §48): a donor record poked to each kind, one
#: `aBlob_Update`, and the child's `rot_x`, `aux` and `life` read back out of
#: the pool.  That measured two things a static reading had wrong as well --
#: kind 77's `row` is the sweep's own zero rather than a literal five, and
#: kind 56 has no `life` test at all -- and it is why this table is a table
#: rather than a comment: a request that goes short again fails here.
KNOWN_SHORT_ARM_SPAWNS: dict[str, tuple[int, int]] = {}


def _arm_spawn_counts() -> dict[str, list[int]] | None:
    """`blob_kinds.gd`'s `_spawn` requests as `creator constant -> [values]`."""
    path = REMAKE_FX_DIR / "blob_kinds.gd"
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")
    out: dict[str, list[int]] = {}
    for match in re.finditer(r"_spawn\(b, h, r, (CREATE_[A-Z0-9_]+),\s*(\[.*?\])",
                             text, re.S):
        name, args = match.group(1), match.group(2)
        depth, count = 0, 1
        for ch in args[1:-1]:
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            elif ch == "," and depth == 0:
                count += 1
        out.setdefault(name, []).append(count)
    return out


def _arm_creator_addresses() -> dict[str, int] | None:
    """`blob_kinds.gd`'s `CREATE_*` constants."""
    path = REMAKE_FX_DIR / "blob_kinds.gd"
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")
    return {name: int(value, 16) for name, value in
            re.findall(r"^const (CREATE_[A-Z0-9_]+): int = (0x[0-9A-Fa-f]+)",
                       text, re.M)}


def _program_args_needed() -> dict[int, int] | None:
    """`blob_programs.gd`'s `ARGS_NEEDED`, keyed by the creator's address.

    The table the remake actually gates on: `GameBlobHooks` refuses a request
    carrying fewer values than the entry says, so an entry raised above the
    creator's real arity turns an effect into a silently counted refusal and
    an entry below it lets a program index past the end of its array.  Its
    keys are the constant names three hundred lines above it, so both are
    read and joined here.
    """
    path = REMAKE_FX_DIR / "blob_programs.gd"
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8")
    addresses = {name: int(value, 16) for name, value in
                 re.findall(r'^const ([A-Z0-9_]+): String = "(0x[0-9A-Fa-f]+)"',
                            text, re.M)}
    body = re.search(r"const ARGS_NEEDED: Dictionary\[String, int\] = \{(.*?)^\}",
                     text, re.S | re.M)
    if body is None:
        return {}
    out: dict[int, int] = {}
    for name, count in re.findall(r"([A-Z][A-Z0-9_]*):\s*(\d+)", body.group(1)):
        if name in addresses:
            out[addresses[name]] = int(count)
    return out


def _check_arm_spawn_arity(ck: "Checker", b: Binary) -> None:
    """Does an arm's spawn request carry the number of values the creator takes?

    The creators are `__cdecl`, so the count lives at the **call site**, in its
    own `add esp, K`.  Every site of every creator an arm can reach agrees,
    which is what makes it a measurement rather than a reading of one site;
    the request the remake's arm writes must carry the same number, or the
    creator runs on values that are not there.

    Nothing checked this while an arm's request was only ever written down.
    `godot/game/fx/game_blob_hooks.gd` runs it, and `ARGS_NEEDED` in
    `blob_programs.gd` refuses a short one -- so the count stopped being
    documentation and started being load-bearing.  **Both** ends are compared
    with the engine here, the request the arm writes and the arity the gate
    reads: they can disagree with each other silently, an over-stated
    `ARGS_NEEDED` turning every request for that creator into a counted
    refusal with every other check still green.
    """
    passed = _arm_spawn_counts()
    addresses = _arm_creator_addresses()
    needed = _program_args_needed()
    if passed is None or addresses is None or needed is None:
        ck.check("arm_spawn.source", False,
                 f"{REMAKE_FX_DIR} has no blob_kinds.gd / blob_programs.gd")
        return
    text_lo, text_hi = b.text_lo, b.text_hi
    blob = b.pe.bytes_at(text_lo, text_hi - text_lo)
    sites: dict[int, list[int]] = {}
    wanted = set(addresses.values())
    for offset in range(len(blob) - 5):
        if blob[offset] != 0xE8:
            continue
        rel = struct.unpack_from("<i", blob, offset + 1)[0]
        target = text_lo + offset + 5 + rel
        if target in wanted:
            sites.setdefault(target, []).append(text_lo + offset)
    disagree = []
    short: dict[str, tuple[int, int]] = {}
    gate: list[str] = []
    checked = 0
    gated = 0
    for name, counts in sorted(passed.items()):
        address = addresses[name]
        cleanups = {b.cleanup_dwords(site) for site in sites.get(address, [])}
        cleanups.discard(None)
        if len(cleanups) != 1:
            disagree.append(f"{name}: sites clean {sorted(cleanups)}")
            continue
        engine = cleanups.pop()
        checked += 1
        bad = [n for n in counts if n != engine]
        if bad:
            short[name] = (bad[0], len(bad))
        if address in needed:
            gated += 1
            if needed[address] != engine:
                gate.append(f"{name}: ARGS_NEEDED {needed[address]} != {engine}")
        else:
            gate.append(f"{name}: no ARGS_NEEDED entry")
    ck.check("arm_spawn.sites_agree", not disagree and checked > 0,
             f"{checked} creators, every call site cleaning the same; "
             f"{'; '.join(disagree) if disagree else 'all'}")
    ck.equal("arm_spawn.arity", short, KNOWN_SHORT_ARM_SPAWNS, Checker.brief)
    ck.check("arm_spawn.args_needed", not gate and gated > 0,
             f"{gated} creator(s) an arm can reach carry the engine's own "
             f"`add esp, K` in `ARGS_NEEDED`; "
             f"{'; '.join(gate) if gate else 'all'}")


#: The seven arm call sites of `aBlob_CreateZoomBob` `0x00423720`, as
#: `kind -> (call site, arm entry, the three pushes that were in doubt)`.
#:
#: `row`, `aux` and `life` are the creator's fourth, fifth and sixth
#: arguments, and each entry gives the byte at the site that supplies it --
#: `None` where the value is computed rather than pushed as an immediate.
#: Measured against the engine on 2026-09-04 by stepping each arm
#: (`docs/97` §48); pinned here because the reading, not the measurement, is
#: what a later edit would break.
ZOOM_BOB_PUSHES: dict[int, tuple[int, int, dict[str, tuple[int, bytes]]]] = {
    6:  (0x0041F8C5, 0x0041F8B6, {"row": (0x0041F8BD, b"\x6a\x04"),
                                  "aux": (0x0041F8BB, b"\x6a\x0a"),
                                  "life": (0x0041F8B9, b"\x6a\x08")}),
    15: (0x00420789, 0x00420734, {"row": (0x00420784, b"\x6a\x01"),
                                  "life": (0x0042075D, b"\x6a\x08")}),
    26: (0x0041FB1E, 0x0041F92F, {"row": (0x0041FB19, b"\x6a\x00"),
                                  "aux": (0x0041FB17, b"\x6a\x1e"),
                                  "life": (0x0041FB15, b"\x6a\x10")}),
    56: (0x0042000A, 0x0041FF6A, {"row": (0x0041FFCC, b"\x6a\x07"),
                                  "life": (0x0041FFA3, b"\x6a\x07")}),
    69: (0x00420603, 0x0042059A, {"row": (0x004205FE, b"\x6a\x06"),
                                  "life": (0x004205D7, b"\x6a\x08")}),
    73: (0x0042067F, 0x00420634, {"row": (0x0042067A, b"\x6a\x01"),
                                  "life": (0x0042065D, b"\x6a\x08")}),
    # `push ebp`, and `ebp` is the sweep's own zero (`xor ebp, ebp` at
    # `0x0041E50A`) -- which is what a static reading called a literal five.
    77: (0x0041F7C2, 0x0041F75D, {"row": (0x0041F776, b"\x55"),
                                  "life": (0x0041F75D, b"\x6a\x08")}),
}

#: `mov al, byte [esi+0x45]` -- the `life` read an arm makes before a guarded
#: spawn.  The kinds whose zoom bob is **unconditional** have none between
#: their entry and their call, and kind 56 is one of them, which is the half
#: of the correction no push block could show.
LIFE_READ = b"\x8a\x46\x45"
#: **How each arm adds a draw to a coordinate**, as the three instructions
#: that do it.  Four arms jitter a spawn's position and they do not agree:
#: three add the coordinate to the draw and truncate the **sum** (`fiadd`,
#: with the record offset in the modrm byte), and one truncates the draw and
#: adds the coordinate through a sign-extended sixteen-bit move.  The two
#: readings differ only where a draw is negative with a fraction, so a capture
#: settles it only on a seed chosen to land there (`docs/97` §49 does exactly
#: that); this is the same fact read out of the bytes, which needs no Wine.
JITTER_SITES: dict[int, tuple[str, tuple[tuple[int, bytes], ...]]] = {
    56: ("fiadd", ((0x0041FFD6, b"\xda\x46\x1c"), (0x0041FFEA, b"\xda\x46\x18"),
                   (0x0041FFFE, b"\xda\x46\x14"))),
    62: ("fiadd", ((0x0041E8EA, b"\xda\x46\x1c"), (0x0041E905, b"\xda\x46\x18"),
                   (0x0041E920, b"\xda\x46\x14"))),
    67: ("fiadd", ((0x0041EE98, b"\xda\x46\x1c"), (0x0041EEB3, b"\xda\x46\x18"),
                   (0x0041EECE, b"\xda\x46\x14"))),
    77: ("movsx", ((0x0041F78A, b"\x0f\xbf\xc8"), (0x0041F7A3, b"\x0f\xbf\xd0"),
                   (0x0041F7BC, b"\x0f\xbf\xc0"))),
}
ZOOM_BOB_UNCONDITIONAL: tuple[int, ...] = (6, 56, 77)

#: **Kind 59's two emitters, where their `vz` argument comes from.**  Both
#: branches are `call _ftol` / `push eax` / `push ebp`: the truncated draw is
#: the emitter's `aux` and the vertical velocity is `ebp`, the sweep's own
#: zero (`xor ebp, ebp` at `0x0041E50A`), so the arm takes **two** velocity
#: draws and not three.  The ordinary branch `0x0042015C` is measured -- the
#: `spawn_*` family compares the child it makes -- and the special one
#: `0x004200FB` is not, because it runs only under an output mode the capture
#: writes for a plan whose window holds no child (`blob_gold.py`'s
#: `mode.special_draws` measures how many draws it takes, not where they go).
#: These bytes are the evidence for the half that has none.
EMITTER_VZ_SITES: dict[str, int] = {
    "special": 0x004200FB,
    "ordinary": 0x0042015C,
}
#: `push eax` (the truncated draw) then `push ebp` (the literal zero).
EMITTER_VZ_PUSHES = b"\x50\x55"


def _check_zoom_bob_arguments(ck: "Checker", b: Binary) -> None:
    """The three arguments the arms hand `aBlob_CreateZoomBob`.

    All seven sites push six dwords -- `arm_spawn.arity` says so -- but which
    six was wrong in both twins until the arms were stepped inside the engine
    (`docs/97` §48).  Two of the errors were beyond a push block's reach: kind
    77's `row` is a register the wrapper zeroes, and kind 56's spawn is not
    guarded at all, so the arm drops a zoom bob every tick rather than on its
    last.  Both are pinned here as bytes, because bytes are what an edit to
    this file would have to disagree with.
    """
    wrong = []
    for kind, (site, entry, pushes) in sorted(ZOOM_BOB_PUSHES.items()):
        for name, (address, expect) in sorted(pushes.items()):
            got = b.pe.bytes_at(address, len(expect))
            if got != expect:
                wrong.append(f"kind {kind} {name}: {got.hex()} != {expect.hex()}")
        if not entry <= site:
            wrong.append(f"kind {kind}: call 0x{site:08X} before its arm")
    ck.check("zoom_bob.pushes", not wrong,
             f"{sum(len(p) for _s, _e, p in ZOOM_BOB_PUSHES.values())} bytes "
             f"over {len(ZOOM_BOB_PUSHES)} arms; "
             f"{'; '.join(wrong) if wrong else 'all'}")
    guarded = []
    for kind, (site, entry, _pushes) in sorted(ZOOM_BOB_PUSHES.items()):
        reads = b.pe.bytes_at(entry, site - entry).count(LIFE_READ)
        if (reads == 0) != (kind in ZOOM_BOB_UNCONDITIONAL):
            guarded.append(f"kind {kind}: {reads} life read(s)")
    ck.check("zoom_bob.unconditional", not guarded,
             f"kinds {list(ZOOM_BOB_UNCONDITIONAL)} spawn on every tick; "
             f"{'; '.join(guarded) if guarded else 'all as measured'}")
    forms = []
    for kind, (form, sites) in sorted(JITTER_SITES.items()):
        for address, expect in sites:
            got = b.pe.bytes_at(address, len(expect))
            if got != expect:
                forms.append(f"kind {kind} 0x{address:08X}: {got.hex()} "
                             f"!= {expect.hex()} ({form})")
    ck.check("spawn.jitter_forms", not forms,
             f"{sum(len(s) for _f, s in JITTER_SITES.values())} instruction(s) "
             f"over {len(JITTER_SITES)} arms -- three `fiadd` and one "
             f"`movsx`; {'; '.join(forms) if forms else 'all as measured'}")
    emitters = []
    for name, site in sorted(EMITTER_VZ_SITES.items()):
        if b.call_target(site) != FTOL:
            emitters.append(f"{name} 0x{site:08X}: not a call to _ftol")
        got = b.pe.bytes_at(site + 5, len(EMITTER_VZ_PUSHES))
        if got != EMITTER_VZ_PUSHES:
            emitters.append(f"{name} 0x{site + 5:08X}: {got.hex()} "
                            f"!= {EMITTER_VZ_PUSHES.hex()}")
    ck.check("spawn.emitter_vz_is_ebp", not emitters,
             f"kind 59's {len(EMITTER_VZ_SITES)} emitter site(s) truncate a "
             "draw into the `aux` and push `ebp` for `vz`; "
             f"{'; '.join(emitters) if emitters else 'both'}")


def _flag_names_in_remake() -> str | None:
    """Every `.gd` under `game/audio/`, concatenated, or ``None``."""
    if not REMAKE_AUDIO_DIR.is_dir():
        return None
    parts = [path.read_text(encoding="utf-8")
             for path in sorted(REMAKE_AUDIO_DIR.glob("*.gd"))]
    return "\n".join(parts) if parts else None


def _setpiece_timing_checks(ck: "Checker", b: Binary) -> None:
    ck.equal("setpiece.door_frames", b.mov_imm32(DOOR_FRAMES_SITE),
             DOOR_SEQUENCE_FRAMES)
    ck.check("setpiece.door_is_a_loop", b.is_dec_reg(DOOR_FRAMES_DEC),
             f"0x{DOOR_FRAMES_SITE:08X}'s immediate is counted down at "
             f"0x{DOOR_FRAMES_DEC:08X}")
    ck.equal("setpiece.bridge_frames", b.mov_imm32(BRIDGE_FRAMES_SITE),
             BRIDGE_FRAMES)
    ck.check("setpiece.bridge_is_a_loop", b.is_dec_reg(BRIDGE_FRAMES_DEC),
             f"counted down at 0x{BRIDGE_FRAMES_DEC:08X}")
    ck.equal("setpiece.bridge_step", _scaled(b, BRIDGE_STEP_SITES), BRIDGE_STEP)
    ck.equal("setpiece.elevator_step", _scaled(b, ELEVATOR_STEP_SITES),
             ELEVATOR_STEP)
    ck.equal("setpiece.platform_frames", _scaled(b, PLATFORM_FRAMES_SITES),
             PLATFORM_FRAMES_PER_FIELD)
    ck.equal("setpiece.platform_step",
             (_scaled(b, PLATFORM_STEP_SITES), _scaled(b, PLATFORM_STEP_SITES_Y)),
             (PLATFORM_STEP, PLATFORM_STEP), _hexlist)
    # And each site really is inside the routine `docs/20` names, bounded by
    # the next call entry -- otherwise the immediates above would be read out
    # of whatever function happened to follow it.
    entries = sorted(b.call_entries())
    routines = {
        "door": (DOOR_SEQUENCE, (DOOR_FRAMES_SITE, DOOR_FRAMES_DEC)),
        "bridge": (BRIDGE_SEQUENCE,
                   (BRIDGE_FRAMES_SITE, BRIDGE_FRAMES_DEC) + BRIDGE_STEP_SITES),
        "elevator": (ELEVATOR_SEQUENCE, ELEVATOR_STEP_SITES),
        "platform": (PLATFORM_SEQUENCE,
                     PLATFORM_FRAMES_SITES + PLATFORM_STEP_SITES
                     + PLATFORM_STEP_SITES_Y),
    }
    for name, (entry, sites) in sorted(routines.items()):
        after = [e for e in entries if e > entry]
        end = min(after) if after else entry + 0x1000
        ck.check(f"setpiece.{name}_sites_inside",
                 entry in set(entries)
                 and all(entry < site < end for site in sites),
                 f"0x{entry:08X} is a routine and holds all {len(sites)} site(s)")

    # The sprite half-extent: `SIZE_SCALE_SITE` pinned the shift and left the
    # factor of five unread, so `160` was a literal nothing checked.
    ck.equal("zoom.size_scale", _scaled(b, SIZE_SCALE_SITES), SIZE_SCALE)
    ck.equal("zoom.half_extent_scale", ATLAS_HALF_EXTENT_SCALE, SIZE_SCALE)


def _creator_of_call(b: Binary) -> dict[int, int | None]:
    """Constructor call site -> the creator whose body contains it.

    The same bounding rule :meth:`Binary.blob_creators` uses, kept as its own
    function because the reach checks need the mapping and not only the set.
    """
    entries = sorted(b.call_entries())
    out: dict[int, int | None] = {}
    for site in BLOB_CALLS:
        index = bisect.bisect_right(entries, site) - 1
        out[site] = entries[index] if index >= 0 else None
    return out


def _generator_checks(ck: "Checker", b: Binary) -> None:
    """The two Lehmer streams, and which one the creators can reach."""
    # The bodies, byte for byte.  Anything but the six named offsets differing
    # means these are no longer the same generator, and the whole finding
    # rests on their being one.
    span = ARANDOM_SHARED_BYTES
    if not (b.mapped(ARANDOM_ENTRY, span) and b.mapped(ARANDOM2_ENTRY, span)):
        ck.check("random.entries_mapped", False, "an entry is outside .text")
        return
    first = bytes(b.u8(ARANDOM_ENTRY + i) for i in range(span))
    second = bytes(b.u8(ARANDOM2_ENTRY + i) for i in range(span))
    differ = tuple(i for i in range(span) if first[i] != second[i])
    ck.equal("random.same_body", differ, ARANDOM_BODY_DIFFERENCES,
             lambda d: f"{span - len(d)} of {span} bytes identical")
    # The seed each one keeps, read out of the `fld` the body opens with.
    ck.equal("random.counted_seed", b.u32(ARANDOM_ENTRY + 0x03),
             ARANDOM_SEED, hex)
    ck.equal("random.uncounted_seed", b.u32(ARANDOM2_ENTRY + 0x03),
             ARANDOM2_SEED, hex)
    # Only the counted one keeps a call counter and a running sum, which is
    # the one behavioural difference between them.
    ck.equal("random.counter_globals",
             (b.u32(ARANDOM_ENTRY + 0x4A), b.u32(ARANDOM_ENTRY + 0x50)),
             (ARANDOM_SUM, ARANDOM_COUNTER),
             lambda v: f"aRandom alone writes {tuple(hex(x) for x in v)}")

    # The seeder each stream has, and where the seed comes from.
    ck.equal("random.uncounted_seeder_globals",
             (b.u32(RANDOM_UNCOUNTED_SEEDER + 0x09),
              b.u32(RANDOM_UNCOUNTED_SEEDER + 0x0F)),
             (ARANDOM2_SEED, ARANDOM2_SEED + 4),
             lambda v: "0x%08X writes the qword at %s"
                       % (RANDOM_UNCOUNTED_SEEDER,
                          tuple(hex(x) for x in v)))
    ck.check("random.effects_seed_is_the_clock",
             b.u8(RANDOM_TICK_COUNT_SITE) == 0xFF
             and b.u8(RANDOM_TICK_COUNT_SITE + 1) == 0x15
             and b.u8(RANDOM_SEEDING_SITE) == 0xE8
             and RANDOM_SEEDING_SITE + 5 + b.i32(RANDOM_SEEDING_SITE + 1)
             == RANDOM_UNCOUNTED_SEEDER,
             "GetTickCount feeds the uncounted stream's seeder")
    ck.check("random.gameplay_seed_is_a_constant",
             b.u8(RANDOM_COUNTED_SEEDING_SITE - 6) == 0x68
             and b.u32(RANDOM_COUNTED_SEEDING_SITE - 5)
             == RANDOM_COUNTED_START_SEED_HI
             and b.u8(RANDOM_COUNTED_SEEDING_SITE) == 0xE8
             and RANDOM_COUNTED_SEEDING_SITE + 5
             + b.i32(RANDOM_COUNTED_SEEDING_SITE + 1) == 0x00463820,
             "aRandomize(1.0) eight bytes later -- docs/22 3.1's constant")

    sites = {ARANDOM_ENTRY: 0, ARANDOM2_ENTRY: 0}
    va = b.text_lo
    while va < b.text_hi - 5:
        if b.u8(va) == 0xE8:
            target = va + 5 + b.i32(va + 1)
            if target in sites:
                sites[target] += 1
                va += 5
                continue
        va += 1
    ck.equal("random.counted_sites", sites[ARANDOM_ENTRY], ARANDOM_SITES)
    owners = _stream_owners(b)
    ck.equal("random.owners",
             (len(owners[ARANDOM2_ENTRY]), len(owners[ARANDOM_ENTRY])),
             (RANDOM_OWNERS_UNCOUNTED, RANDOM_OWNERS_COUNTED),
             lambda v: f"{v[0]} functions draw from the uncounted stream, "
                       f"{v[1]} from the counted one")
    ck.equal("random.streams_that_mix",
             tuple(sorted(owners[ARANDOM_ENTRY] & owners[ARANDOM2_ENTRY])),
             RANDOM_BOTH_STREAMS,
             lambda v: f"{len(v)} function(s) draw from both streams")
    lo, hi = RANDOM_BLOB_MODULE
    outside = tuple(sorted(f for f in owners[ARANDOM2_ENTRY]
                           if not lo <= f <= hi))
    ck.equal("random.uncounted_outside_the_blob_module", outside,
             RANDOM_UNCOUNTED_OUTSIDE,
             lambda v: f"{len(v)} of {len(owners[ARANDOM2_ENTRY])} callers "
                       "sit outside aBlobs.cpp -- the animation drivers and "
                       "the unit pool")
    ck.equal("random.uncounted_sites", sites[ARANDOM2_ENTRY], ARANDOM2_SITES,
             lambda n: f"{n} call sites against aRandom's "
                       f"{sites[ARANDOM_ENTRY]} -- the uncounted stream is "
                       "the one the game draws from")

    creators = b.blob_creators()
    entries = sorted(b.call_entries())

    def closure(creator: int) -> set[int]:
        seen, stack = {creator}, [creator]
        while stack:
            for nxt in b.arm_calls(stack.pop(), creators, entries,
                                   CREATOR_EXTENT):
                if nxt not in seen:
                    seen.add(nxt)
                    stack.append(nxt)
        return seen

    def draws(entry: int) -> int:
        count, va = 0, entry
        while va < entry + CREATOR_EXTENT - 5:
            if b.u8(va) == 0xE8 and va + 5 + b.i32(va + 1) == ARANDOM2_ENTRY:
                count += 1
                va += 5
                continue
            va += 1
        return count

    reached = _reachable_creators(b)
    _origin_checks(ck, b, reached)
    table = {f"0x{c:08X}": sum(draws(f) for f in closure(c))
             for c in sorted(reached)}
    ck.equal("random.creator_draw_sites", table, CREATOR_DRAW_SITES,
             Checker.brief)
    ck.equal("random.creators_that_can_draw",
             sum(1 for n in table.values() if n), CREATORS_THAT_CAN_DRAW,
             lambda n: f"{n} of {len(table)} creators reach the generator")
    _pool_draw_checks(ck, b, owners)


def _pool_draw_checks(ck: "Checker", b: Binary,
                      owners: dict[int, set[int]]) -> None:
    """What the three unit-pool draws are for -- `docs/22` §12's question.

    Every claim here is one instruction's bytes.  The three sites push the
    same pair, truncate the same way and store one byte, and the byte's
    displacement is what identifies it: two of them address the persistent
    roster at ``UNIT_ROSTER + 0x55`` outright, so the field is read off the
    encoding rather than inferred from what the value looks like.
    """
    ck.equal("pool.draw_owners",
             tuple(sorted(set(POOL_DRAW_SITES.values()))),
             tuple(sorted(f for f in owners[ARANDOM2_ENTRY]
                          if f in set(POOL_DRAW_SITES.values()))),
             lambda v: f"{len(v)} unit-pool routines draw from the "
                       "clock-seeded stream")
    base, span = POOL_DRAW_ARGUMENTS
    for site in sorted(POOL_DRAW_SITES):
        tag = f"0x{site:08X}"
        # The two pushes are the last two before the call, but not always
        # adjacent to it **or to each other**: in `aEnlargeUnitPool` the
        # compiler puts eight bytes of unrelated work between them and
        # seventy-five before the call.  So the check is that both immediate
        # pushes appear in that order inside the window and nothing else
        # pushes in between -- which is what `add esp, 8` already tells us.
        window = [b.u8(site - n) for n in range(POOL_DRAW_WINDOW, 0, -1)]
        order = [n for n in range(len(window) - 1)
                 if window[n] == 0x6A and window[n + 1] in (base, span)]
        pushed = [window[n + 1] for n in order]
        ck.check(f"pool.draw_arguments.{tag}",
                 pushed[-2:] == [span, base],
                 f"push {span}; push {base} -- aRandom({base}, {span})")
        ck.check(f"pool.draw_truncates.{tag}",
                 b.u8(site + 5) == 0x83 and b.u8(site + 6) == 0xC4
                 and b.u8(site + 7) == 0x08 and b.u8(site + 8) == 0xE8
                 and site + 13 + b.i32(site + 9) == FTOL,
                 "add esp, 8 then __ftol -- the draw is stored as an integer")
    # `mov [reg + 0x0051F2F5], al` -- opcode 0x88, modrm mod=10 with a
    # dword displacement, and the displacement is the roster plus the
    # speech-set offset.  Both writers of the roster copy use it.
    roster_field = UNIT_ROSTER + POOL_DRAW_FIELD
    for site in (0x00478B36, 0x00478CC8):
        ck.check(f"pool.draw_stores_speech.0x{site:08X}",
                 any(b.u8(va) == 0x88 and (b.u8(va + 1) >> 6) == 2
                     and b.u8(va + 1) & 7 != 4
                     and b.u32(va + 2) == roster_field
                     for va in range(site + 13, site + 22)),
                 f"the byte lands at unit[+0x{POOL_DRAW_FIELD:02X}] of the "
                 f"roster at 0x{UNIT_ROSTER:08X} -- the speech set")
    # `aGenerateUnitElement` writes into a record it is still building, so
    # its store is `mov byte [esp+disp8], al` and the field is identified by
    # the branch above it instead: type 24 skips the roll and takes 12.
    fixed = 0x00479F4B
    ck.check("pool.speech_fixed_for_type_24",
             b.u8(fixed) == 0x80 and b.u8(fixed + 4) == POOL_SPEECH_FIXED_TYPE
             and b.u8(fixed + 7) == 0xC6
             and b.u8(fixed + 11) == POOL_SPEECH_FIXED_VALUE,
             f"unit type {POOL_SPEECH_FIXED_TYPE} takes speech set "
             f"{POOL_SPEECH_FIXED_VALUE} without drawing")
    ck.check("pool.speech_roll_is_in_range",
             base >= 1 and base + span - 1 == POOL_SPEECH_MAX
             and POOL_SPEECH_MAX < POOL_SPEECH_FIXED_VALUE,
             "the roll cannot leave docs/20 7.4's shipped table")
    for site in BOTH_STREAMS_COUNTED_SITES:
        ck.check(f"pool.both_streams_counted.0x{site:08X}",
                 b.u8(site) == 0xE8 and site + 5 + b.i32(site + 1)
                 == ARANDOM_ENTRY,
                 "the tile candidate comes from the gameplay generator")
    ck.check("pool.both_streams_placement",
             b.u8(0x004161E1) == 0xE8
             and 0x004161E1 + 5 + b.i32(0x004161E2)
             == BOTH_STREAMS_PLACEMENT_TEST,
             "and is handed to the placement test, five tries at most")
    site = BOTH_STREAMS_UNCOUNTED_SITE
    ck.check("pool.both_streams_uncounted",
             b.u8(site) == 0xE8 and site + 5 + b.i32(site + 1) == ARANDOM2_ENTRY
             and b.u8(0x00416248) == 0xE8
             and 0x00416248 + 5 + b.i32(0x00416249) == BOTH_STREAMS_EFFECT,
             "the effect argument comes from the presentation generator")
    lo, hi = RANDOM_BLOB_MODULE
    ck.check("pool.both_streams_effect_is_a_blob",
             lo <= BOTH_STREAMS_EFFECT <= hi,
             f"0x{BOTH_STREAMS_EFFECT:08X} is inside aBlobs.cpp")


def _origin_checks(ck: "Checker", b: Binary, reached: set[int]) -> None:
    """Where a creator's origin comes from -- and where it does not."""

    def disp8_reads(entry: int) -> set[int]:
        """Every ``mov r32, [base+disp8]`` displacement in the body."""
        out: set[int] = set()
        va = entry
        while va < entry + CREATOR_EXTENT - 3:
            if b.u8(va) == 0x8B:
                modrm = b.u8(va + 1)
                if modrm >> 6 == 1 and modrm & 7 != 4:
                    out.add(b.u8(va + 2))
            va += 1
        return out

    def calls_symbol(entry: int) -> bool:
        va = entry
        while va < entry + CREATOR_EXTENT - 5:
            if b.u8(va) == 0xE8 and va + 5 + b.i32(va + 1) == GET_SYMBOL_OBJECT:
                return True
            va += 1
        return False

    reads = {c: disp8_reads(c) for c in sorted(reached)}
    ck.equal("origin.every_creator_asks_the_symbol",
             sum(1 for c in reads if calls_symbol(c)), len(reads),
             lambda n: f"{n} creator(s) go through aGetSymbolObjectPtr")
    missing = [f"0x{c:08X}" for c, seen in reads.items()
               if not set(SYMBOL_ORIGIN_FIELDS) <= seen]
    ck.equal("origin.is_the_objects_position", missing, [],
             lambda v: "every creator reads the object's "
                       f"{tuple(hex(f) for f in SYMBOL_ORIGIN_FIELDS)} triple"
                       if not v else f"{len(v)} do not: {v}")
    # **The negative, and it is what settles the open question.**  The control
    # map's height sits at +1 and no creator reads a dword there, so the floor
    # cannot enter a creator's `z` however the ground is shaped.
    floor = [f"0x{c:08X}" for c, seen in reads.items()
             if CELL_HEIGHT_DISP in seen]
    ck.equal("origin.floor_is_never_read", floor, [],
             lambda v: "no creator reads the control map's height"
                       if not v else f"{len(v)} do: {v}")


def _stream_owners(b: Binary) -> dict[int, set[int]]:
    """Which function each call to either stream sits in."""
    entries = sorted(b.call_entries())
    out: dict[int, set[int]] = {ARANDOM_ENTRY: set(), ARANDOM2_ENTRY: set()}
    va = b.text_lo
    while va < b.text_hi - 5:
        if b.u8(va) == 0xE8:
            target = va + 5 + b.i32(va + 1)
            if target in out:
                index = bisect.bisect_right(entries, va) - 1
                if index >= 0:
                    out[target].add(entries[index])
                va += 5
                continue
        va += 1
    return out


def _reachable_creators(b: Binary) -> set[int]:
    out: set[int] = set()
    for table, pinned in ((MUZZLE_SWITCH, WEAPON_MUZZLE),
                          (IMPACT_SWITCH, WEAPON_IMPACT)):
        for _weapon, (_arm, calls) in b.weapon_effects(table, pinned).items():
            for _site, creator in calls:
                if creator is not None:
                    out.add(creator)
    return out


def _creator_reach_checks(ck: "Checker", b: Binary) -> None:
    muzzle = b.weapon_effects(MUZZLE_SWITCH, WEAPON_MUZZLE)
    impact = b.weapon_effects(IMPACT_SWITCH, WEAPON_IMPACT)
    reached: set[int] = set()
    for table in (muzzle, impact):
        for _weapon, (_arm, calls) in table.items():
            for _site, creator in calls:
                if creator is not None:
                    reached.add(creator)
    ck.equal("creators.reachable", len(reached), REACHABLE_CREATORS,
             lambda n: f"{n} of {len(b.blob_creators())} creators can be "
                       "reached by firing a weapon")
    calls = b.blob_calls()
    owners = _creator_of_call(b)
    inside = [site for site, owner in owners.items() if owner in reached]
    ck.equal("creators.reachable_calls", len(inside), REACHABLE_CALLS,
             lambda n: f"{n} of {len(calls)} constructor calls sit inside them")
    # The arity of every reachable creator, from the **caller's** own stack
    # cleanup.  `--probe` cannot answer this -- the creators are `__cdecl`, the
    # caller cleans up, and the callee's `ret` pops nothing whatever the arity
    # -- so `tools/blob_gold.py` has to know it before it can call one, and
    # this is the reading it uses.  Every creator called from more than one
    # site has sites that agree, which is what makes it a measurement.
    arity: dict[int, set[int]] = {}
    for table, pinned in ((MUZZLE_SWITCH, WEAPON_MUZZLE),
                          (IMPACT_SWITCH, WEAPON_IMPACT)):
        for _weapon, (_arm, sites) in b.weapon_effects(table, pinned).items():
            for site, creator in sites:
                if creator is not None:
                    arity.setdefault(creator, set()).add(b.cleanup_dwords(site))
    ck.check("creators.arity_agrees",
             bool(arity) and all(len(w) == 1 and None not in w
                                 for w in arity.values()),
             f"{len(arity)} creators, every call site agreeing")
    ck.equal("creators.arity_table",
             {f"0x{c:08X}": sorted(w)[0] for c, w in sorted(arity.items())},
             CREATOR_ARITIES, Checker.brief)

    # **The call graph among the creators, and its depth.**  Transitive, by
    # worklist, so the answer does not depend on how deep anyone guessed.
    creators = b.blob_creators()
    entries = sorted(b.call_entries())

    def direct(creator: int) -> set[int]:
        return set(b.arm_calls(creator, creators, entries,
                               CREATOR_EXTENT)) - {creator}

    def closure(creator: int) -> set[int]:
        seen, stack = {creator}, [creator]
        while stack:
            for nxt in direct(stack.pop()):
                if nxt not in seen:
                    seen.add(nxt)
                    stack.append(nxt)
        return seen

    # How far the window actually has to reach, measured -- and the bound
    # required to clear it.  Without this pair `CREATOR_EXTENT` is a number no
    # check can be shown to read.
    reach, furthest = 0, (0, 0, 0)
    for creator in sorted(reached):
        va = creator
        while va < creator + CREATOR_EXTENT - 5:
            if b.u8(va) == 0xE8:
                target = va + 5 + b.i32(va + 1)
                if target in creators and target != creator \
                        and va - creator > reach:
                    reach, furthest = va - creator, (creator, target, va)
            va += 1
    ck.equal("creators.nesting_reach", reach, CREATOR_NESTING_REACH,
             lambda n: f"the furthest nested call is {n} bytes in")
    ck.equal("creators.nesting_furthest", furthest, CREATOR_NESTING_FURTHEST,
             lambda v: "0x%08X calls 0x%08X at 0x%08X" % v)
    ck.check("creators.nesting_window_clears_it",
             CREATOR_EXTENT > CREATOR_NESTING_REACH,
             f"the {CREATOR_EXTENT}-byte window clears the "
             f"{CREATOR_NESTING_REACH}-byte reach")

    nested = {f"0x{c:08X}": sorted(f"0x{n:08X}" for n in direct(c))
              for c in sorted(reached) if direct(c)}
    ck.equal("creators.nesting_table", nested, CREATOR_NESTED, Checker.brief)
    flat = all(closure(c) == {c} | direct(c) for c in reached)
    ck.equal("creators.nesting_is_flat", flat, CREATOR_NESTING_IS_FLAT,
             lambda v: f"one level reaches every nested creator: {v}")

    with_life = [site for site in inside if calls[site][3] is not None]
    ck.equal("creators.reachable_lifetimes", len(with_life),
             REACHABLE_CALLS_WITH_LIFE,
             lambda n: f"{n} of {len(inside)} carry a literal lifetime -- "
                       "what paces the remake's tracers")


def _creator_extents() -> dict[int, tuple[int, int]]:
    """Every creator's half-open byte range, from the creator table itself.

    The boundary is the *next* creator's entry, so a site attributed to one
    creator cannot silently belong to the routine after it.
    """
    starts = sorted(int(k, 16) for k in CREATOR_DRAW_SITES)
    return {a: (a, starts[i + 1] if i + 1 < len(starts) else a + 0x1000)
            for i, a in enumerate(starts)}


def _fmul_sites(b: Binary, lo: int, hi: int, cell: int) -> list[int]:
    """Every ``fmul qword [cell]`` (``DC 0D`` + m32) -- or ``fcomp qword
    [cell]`` (``DC 1D``), which is how the species coin reads its double --
    in ``[lo, hi)``."""
    out: list[int] = []
    for va in range(lo, hi - 6):
        if b.u8(va) == 0xDC and b.u8(va + 1) in (0x0D, 0x1D) and b.u32(va + 2) == cell:
            out.append(va)
    return out


def _magic_divisor(b: Binary, va: int) -> int | None:
    """The divisor of the reciprocal multiply starting at ``mov eax, imm32``.

    The candidate comes from the multiplier -- the compiler chose
    ``ceil(2 ** (32 + shift) / d)`` -- and is then confirmed by **replay**
    rather than by trusting the arithmetic: the multiply, the optional
    ``add edx, r32`` of the two-term form, the ``sar`` and the ``shr``/``add``
    sign fixup are run over `MAGIC_SWEEP` and required to equal a truncating
    divide for every dividend in it.  A perturbed magic, shift or form fails
    that and this answers ``None``, which is what makes a mutated site read as
    "not the sequence I expected" instead of as a different divisor.
    """
    if not b.mapped(va, 5) or b.u8(va) != 0xB8:
        return None
    magic, shift, two_term = b.i32(va + 1), None, False
    for probe in range(va + 5, va + 0x28):
        if not b.mapped(probe, 3):
            return None
        if b.u8(probe) == 0xC1 and b.u8(probe + 1) == 0xFA:
            shift = b.u8(probe + 2)
            break
        # `add edx, r32` -- the form whose multiplier does not fit in 32 bits.
        if b.u8(probe) == 0x03 and 0xD0 <= b.u8(probe + 1) <= 0xD7:
            two_term = True
    if shift is None:
        return None

    def quotient(n: int) -> int:
        high = (magic * n) >> 32
        if two_term:
            high = _as_i32(high + n)
        value = high >> shift
        return _as_i32(value + ((value >> 31) & 1))

    # The divisor comes from the multiplier itself -- the compiler picked
    # `ceil(2 ** (32 + shift) / d)` -- and is then **verified** over the
    # sweep.  Deriving it from one quotient instead (`N // (N // d)`) is off
    # by more than a couple for many divisors, so it happened to work for
    # these two and would not for the next site added.
    scale = magic + (1 << 32 if two_term else 0)
    if scale <= 0:
        return None
    candidate = round(2 ** (32 + shift) / scale)
    if candidate < 1:
        return None
    if all(quotient(n) == _trunc_div(n, candidate) for n in MAGIC_SWEEP):
        return candidate
    return None


def _as_i32(value: int) -> int:
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value >> 31 else value


def _trunc_div(value: int, divisor: int) -> int:
    quotient = abs(value) // abs(divisor)
    return quotient if (value < 0) == (divisor < 0) else -quotient


def _constant_site_value(b: Binary, kind: str, where: object) -> object:
    """What the binary holds at one site, in the site's own encoding."""
    if kind == "f64":
        cell = int(where)                       # type: ignore[arg-type]
        return b.pe.f64(cell) if b.mapped(cell, 8) else None
    if kind in ("lea", "add"):
        va = int(where)                         # type: ignore[arg-type]
        if not b.mapped(va, 6):
            return None
        # `lea r32, [r32 + disp32]` is `8D` + mod=10; `add r32, imm32` is
        # `81` + /0.  Anything else is not the instruction claimed.
        if kind == "lea" and (b.u8(va) != 0x8D or b.u8(va + 1) >> 6 != 0b10):
            return None
        if kind == "add" and (b.u8(va) != 0x81
                              or (b.u8(va + 1) >> 3) & 0x07 != 0):
            return None
        return b.i32(va + 2)
    if kind == "mov":
        return b.mov_imm32(int(where))          # type: ignore[arg-type]
    if kind == "cmp":
        # `cmp r32, imm8` is `83 /7 ib`.
        va = int(where)                         # type: ignore[arg-type]
        if not b.mapped(va, 3) or b.u8(va) != 0x83 or (b.u8(va + 1) >> 3) & 7 != 7:
            return None
        v = b.u8(va + 2)
        return v - 0x100 if v >= 0x80 else v
    if kind == "cmp32":
        # `cmp r32, imm32` is `81 /7 id`.
        va = int(where)                         # type: ignore[arg-type]
        if not b.mapped(va, 6) or b.u8(va) != 0x81 or (b.u8(va + 1) >> 3) & 7 != 7:
            return None
        return b.i32(va + 2)
    if kind == "add8":
        # `add r32, imm8` is `83 /0 ib`.
        va = int(where)                         # type: ignore[arg-type]
        if not b.mapped(va, 3) or b.u8(va) != 0x83 or (b.u8(va + 1) >> 3) & 7 != 0:
            return None
        v = b.u8(va + 2)
        return v - 0x100 if v >= 0x80 else v
    if kind == "push":
        va = int(where)                         # type: ignore[arg-type]
        v = b.push_imm(va) if b.mapped(va, 5) else None
        return None if v is None else (v - (1 << 32) if v >= 0x80000000 else v)
    if kind == "word":
        # `mov word [esp + disp8], imm16` is `66 C7 44 24 dd ww ww`.
        va = int(where)                         # type: ignore[arg-type]
        if not b.mapped(va, 7) or bytes(b.u8(va + i) for i in range(4)) != b"\x66\xc7\x44\x24":
            return None
        return b.u8(va + 5) | (b.u8(va + 6) << 8)
    if kind == "magic":
        return _magic_divisor(b, int(where))    # type: ignore[arg-type]
    if kind == "scale":
        first, second, shl, sar = where         # type: ignore[misc]
        left, right = b.lea_scale(first), b.lea_scale(second)
        if left is None or right is None:
            return None
        if not (b.u8(shl) == 0xC1 and b.u8(shl + 1) == 0xE0):
            return None
        if not (b.u8(sar) == 0xC1 and (b.u8(sar + 1) & 0xF8) == 0xF8):
            return None
        return (left * right * (1 << b.u8(shl + 2))) >> b.u8(sar + 2)
    return None


def _creator_constant_checks(ck: "Checker", b: Binary) -> None:
    """Read every creator constant back out of `Incubation.exe`.

    `tools/blob_gold.py` measures which of them a *capture* can tell apart
    from a neighbour, and seven of thirteen is the honest answer there.  This
    is the other half, and it is the half that needs no game running: the
    value is at a named address in the shipped executable, the instruction
    that reads it is inside the creator the transcription attributes it to,
    and both are compared here.  What the capture adds on top is that the
    constant reaches the *field* -- which is a different claim, and stays a
    different check.
    """
    from inclib import blob_creators

    named = sorted(name for name in vars(blob_creators)
                   if name.isupper() and not name.startswith("_")
                   and isinstance(vars(blob_creators)[name], (int, float))
                   and not isinstance(vars(blob_creators)[name], bool))
    ck.equal("creators.constant_sites_cover_module", named,
             sorted(CREATOR_CONSTANT_SITES),
             lambda v: f"all {len(v)} numeric constant(s) of blob_creators.py "
                       "have a named site in the binary")

    extents = dict(_creator_extents())
    extents.update(DEATH_CREATOR_EXTENTS)
    read: list[tuple[str, str, str, object]] = []
    magnitudes: list[str] = []
    contained: list[str] = []
    for name, sites in sorted(CREATOR_CONSTANT_SITES.items()):
        wanted = abs(getattr(blob_creators, name, None) or 0)
        for kind, creator, where, expected in sites:
            value = _constant_site_value(b, kind, where)
            tag = (f"0x{where:08X}" if isinstance(where, int)
                   else "+".join(f"0x{w:08X}" for w in where))
            read.append((name, kind, tag, value))
            if value is None or abs(value) != wanted:
                magnitudes.append(f"{name}@{tag}")
            lo, hi = extents.get(creator, (0, 0))
            addresses = [where] if isinstance(where, int) else list(where)
            if kind == "f64":
                addresses = _fmul_sites(b, lo, hi, int(where))
                if not addresses:
                    contained.append(f"{name}@{tag}")
                    continue
            if not all(lo <= va < hi for va in addresses):
                contained.append(f"{name}@{tag}")

    ck.equal("creators.constant_values",
             [(n, k, t, v) for n, k, t, v in read],
             [(n, k, (f"0x{w:08X}" if isinstance(w, int)
                      else "+".join(f"0x{x:08X}" for x in w)), e)
              for n, sites in sorted(CREATOR_CONSTANT_SITES.items())
              for k, _c, w, e in sites],
             lambda v: f"{len(v)} creator constant site(s) read back out of "
                       "Incubation.exe -- doubles, subtracted immediates, two "
                       "reciprocal multiplies replayed over "
                       f"{len(MAGIC_SWEEP)} dividends, and one lea/shl product")
    ck.equal("creators.constant_magnitudes", magnitudes, [],
             lambda v: "every site holds the magnitude blob_creators.py uses"
                       if not v else f"{len(v)} site(s) disagree: {v}")
    ck.equal("creators.constant_sites_contained", contained, [],
             lambda v: "every site is inside the creator the transcription "
                       "attributes it to, bounded by the next creator's entry"
                       if not v else f"{len(v)} site(s) are elsewhere: {v}")


def _tracer_axis_checks(ck: "Checker", b: Binary) -> None:
    """The machine gun's perpendicular tracers, read rather than matched.

    Three separate statements, and the first two are what "perpendicular" and
    "exchanged" mean once the components are named:

    * every term loads the component `TRACER_AXIS_TERMS` says it does, and
      multiplies by the cell it says;
    * inside one record, a coordinate's two terms name **different**
      components -- an axis-by-axis recipe cannot write that, which is why the
      fit had a residue here;
    * the second record is the first with its two spread cells **exchanged**,
      not negated: same components, same roles, the +-640 swapped between x
      and y.
    """
    import hashlib

    sites: list[tuple[int, str, str, str, int | None]] = []
    for record, coord, role, va, disp, _depth, cell in TRACER_AXIS_TERMS:
        loads = (b.mapped(va, 4) and b.u8(va) == 0xDD and b.u8(va + 1) == 0x44
                 and b.u8(va + 2) == 0x24 and b.u8(va + 3) == disp)
        found = None
        if cell is not None:
            # The `fmul` is the first one after the load; the compiler slides
            # one or two integer instructions of the other term in between,
            # so the window is scanned rather than a fixed offset assumed.
            for probe in range(va + 4, va + 0x10):
                if (b.mapped(probe, 6) and b.u8(probe) == 0xDC
                        and b.u8(probe + 1) == 0x0D):
                    found = b.u32(probe + 2)
                    break
        sites.append((record, coord, role,
                      f"fld [esp+0x{disp:02X}]" if loads else "not an fld",
                      found))
    ck.equal("creators.tracer_term_sites", sites,
             [(r, c, role, f"fld [esp+0x{d:02X}]", cell)
              for r, c, role, _va, d, _depth, cell in TRACER_AXIS_TERMS],
             lambda v: f"{len(v)} tracer term(s) load the component and "
                       "multiply by the cell the reading names")

    def component(disp: int, depth: int) -> int | None:
        return TRACER_DIRECTION_SLOTS.get(disp - depth)

    parts: dict[tuple[int, str], dict[str, tuple[int | None, int | None]]] = {}
    for record, coord, role, _va, disp, depth, cell in TRACER_AXIS_TERMS:
        parts.setdefault((record, coord), {})[role] = (
            component(disp, depth), cell)
    crossed = sorted(key for key, roles in parts.items()
                     if len(roles) == 2
                     and roles["lean"][0] is not None
                     and roles["lean"][0] != roles["spread"][0])
    ck.equal("creators.tracer_terms_perpendicular", crossed,
             sorted(parts),
             lambda v: f"all {len(v)} coordinate(s) of both tracers take "
                       "their two terms from different direction components")
    mirror = all(parts[(0, coord)][role][0] == parts[(1, coord)][role][0]
                 for coord in ("x", "y") for role in ("lean", "spread"))
    exchanged = (parts[(0, "x")]["spread"][1] == parts[(1, "y")]["spread"][1]
                 and parts[(0, "y")]["spread"][1]
                 == parts[(1, "x")]["spread"][1]
                 and parts[(0, "x")]["spread"][1]
                 != parts[(0, "y")]["spread"][1])
    ck.check("creators.tracer_records_mirror", mirror and exchanged,
             "the second tracer keeps the first's components and exchanges "
             "its two spread cells -- it does not negate them")

    digests = [(f"0x{lo:08X}", hashlib.sha256(
        _span_bytes(b, lo, hi)).hexdigest()[:16])
        for lo, hi, _want in TRACER_AXIS_BLOCKS]
    ck.equal("creators.tracer_blocks_unchanged", digests,
             [(f"0x{lo:08X}", want) for lo, _hi, want in TRACER_AXIS_BLOCKS],
             lambda v: f"{len(v)} tracer block(s) byte for byte as read")


def _span_bytes(b: Binary, lo: int, hi: int) -> bytes:
    """``[lo, hi)`` of the image, or empty when the range is not mapped.

    Every digest and every scan below goes through this.  A pin perturbed to
    an address outside the image has to read as "not what I expected"; the
    raw accessor raises, and an exception is not a failing check -- it is a
    battery that stops early and a coverage figure that never gets printed.
    """
    if hi <= lo or not b.mapped(lo, hi - lo):
        return b""
    return b.pe.bytes_at(lo, hi - lo)


def _stores_to(b: Binary, va: int, target: int) -> bool:
    """Whether the instruction at *va* writes the global at *target*.

    The five forms `aCreateOutputSystem` uses: ``mov [m32], eax`` (``A3``),
    ``mov [m32], r32`` and ``mov [m32], r8`` (``89``/``88`` with mod 00 and
    r/m 101), and the two immediate stores.  Anything else answers ``False``,
    so a pinned value that stopped feeding its global is a failure rather
    than a number read out of the right address by accident.
    """
    if not b.mapped(va, 6):
        return False
    opcode = b.u8(va)
    if opcode == 0xA3:                                  # mov [m32], eax
        return b.u32(va + 1) == target
    if opcode in (0x88, 0x89):                          # mov [m32], r8 / r32
        modrm = b.u8(va + 1)
        return (modrm >> 6 == 0 and modrm & 0x07 == 0x05
                and b.u32(va + 2) == target)
    if opcode in (0xC6, 0xC7):                          # mov [m32], imm
        return b.u8(va + 1) == 0x05 and b.u32(va + 2) == target
    return False


def _output_value(b: Binary, kind: str, va: int) -> int | None:
    """One field of an output-system case, in the encoding it is written in."""
    if not b.mapped(va, 6):
        return None
    if kind == "xor":                                   # xor r32, r32
        modrm = b.u8(va + 1)
        if b.u8(va) not in (0x31, 0x33) or modrm >> 6 != 3:
            return None
        return 0 if (modrm >> 3) & 7 == modrm & 7 else None
    if kind == "load":                                  # mov r32, imm32
        return b.i32(va + 1) if 0xB8 <= b.u8(va) <= 0xBF else None
    if kind == "store_imm":                             # mov [m32], imm32
        return (b.i32(va + 6) if b.u8(va) == 0xC7 and b.u8(va + 1) == 0x05
                else None)
    if kind == "store_imm8":                            # mov [m32], imm8
        return (b.u8(va + 6) if b.u8(va) == 0xC6 and b.u8(va + 1) == 0x05
                else None)
    return None


def _esp_disp(b: Binary, va: int, opcode_length: int) -> tuple[int, int] | None:
    """``(register, disp8)`` of a ``[esp + disp8]`` operand, or ``None``."""
    if not b.mapped(va, opcode_length + 3):
        return None
    modrm = b.u8(va + opcode_length)
    if modrm >> 6 != 0x01 or modrm & 0x07 != 0x04:
        return None
    if b.u8(va + opcode_length + 1) != 0x24:            # SIB: esp, no index
        return None
    return (modrm >> 3) & 0x07, b.u8(va + opcode_length + 2)


def _plot_path(b: Binary, lo: int, hi: int) -> tuple[Any, ...] | None:
    """Decode one arm of the pixel plot into what it does with the stride.

    Finds the ``imul r32, [esp+disp]`` -- the row multiply -- then looks back
    for the ``mov r32, [esp+disp]`` that loaded *that* register and for a
    ``shr r32, 1`` between them, and forward for the store.  Nothing here is
    matched against an expected displacement; the arm is read and the answer
    compared afterwards.
    """
    if not _span_bytes(b, lo, hi):
        return None
    imul = None
    for va in range(lo, hi):
        if not b.mapped(va, 5):
            break
        if b.u8(va) == 0x0F and b.u8(va + 1) == 0xAF:
            found = _esp_disp(b, va, 2)
            if found is not None:
                imul = (va, ) + found
                break
    if imul is None:
        return None
    site, register, row_disp = imul
    stride_disp, halved = None, False
    for va in range(lo, site):
        if not b.mapped(va, 4):
            break
        if b.u8(va) == 0x8B:
            found = _esp_disp(b, va, 1)
            if found is not None and found[0] == register:
                stride_disp = found[1]
        if b.u8(va) == 0xD1 and b.u8(va + 1) == 0xE8 + register:
            halved = True
    if stride_disp is None:
        return None
    for va in range(site, hi):
        if not b.mapped(va, 4):
            break
        word = b.u8(va) == 0x66 and b.u8(va + 1) == 0x89
        if not word and b.u8(va) != 0x88:
            continue
        modrm = b.u8(va + (2 if word else 1))
        if modrm >> 6 != 0 or modrm & 0x07 != 0x04:
            continue
        sib = b.u8(va + (3 if word else 2))
        return (stride_disp, row_disp, halved, 2 if word else 1,
                1 << (sib >> 6))
    return None


def _lock_arm_source(b: Binary, lo: int, hi: int) -> str | None:
    """Where the arm at *lo* gets `OUTPUT_STRIDE` from, read off its bytes.

    Three shapes, and the classification is by what the span contains rather
    than by where it sits: an arm that **stores** the global after calling
    `DDRAW_ACCESSOR` and reading ``[eax + 0x28]`` takes it from the locked
    surface; an arm that passes the global's *address* to an indirect and
    stores nothing takes it from that callee; an arm that neither stores nor
    passes it leaves whatever `aCreateOutputSystem` wrote.
    """
    span = _span_bytes(b, lo, hi)
    if not span:
        return None
    cell = struct.pack("<I", OUTPUT_STRIDE)
    stores = b"\xA3" + cell in span or b"\x89\x0D" + cell in span
    passes = b"\x68" + cell in span
    reads_pitch = b"\x8B\x48\x28" in span or b"\x8B\x40\x28" in span
    calls = any(lo + i + 5 + int.from_bytes(span[i + 1:i + 5], "little",
                                            signed=True) == DDRAW_ACCESSOR
                for i in range(len(span) - 4) if span[i] == 0xE8)
    indirect = b"\xFF\x15" + struct.pack("<I", LOCK_ENG3D_SLOT) in span
    if stores:
        return "lPitch" if reads_pitch and calls else "elsewhere"
    if passes:
        return "eng3d" if indirect else "elsewhere"
    return "unchanged"


def _surface_lock_checks(ck: "Checker", b: Binary) -> None:
    """What `0x00512A9C` is *filled from* -- the half `docs/97` §23.4 left.

    §23.4 read the stride's meaning out of the drawing code and said openly
    that its source was not read: the lock takes it from ``[obj + 0x28]`` of
    whatever `0x00432C30` returns, and nothing had a reading of that object.

    There is no object to read.  `0x00432C30` returns the **address of a
    static block** -- aLIB's DirectDraw module state, `C:\\aProject\\aLIB\\aDDraw.cpp`
    -- and ``+0x18`` of that block is a `DDSURFACEDESC`, identified by the
    ``dwSize = 0x6C`` both lock helpers write into it before handing its
    address to vtable slot ``+0x64``, ``IDirectDrawSurface::Lock``, under the
    error label ``"DD_Lock"``.  ``+0x28`` is therefore ``desc + 0x10``,
    `lPitch`; the pointer those helpers return is ``desc + 0x24`,
    `lpSurface`, and it is what `OUTPUT_BASE` gets.  Both are fields of a
    public ABI, so the stride is no longer named by its value.

    The scope is checked with it: **two** of the four display modes take the
    stride from `lPitch`.  Mode 0 never rewrites it -- which is why the
    320x200 case's 640 survives -- and mode 3 has an Eng3d entry point fill
    it through a pointer.
    """
    import hashlib

    ck.equal("ddraw.accessor_returns_a_static_block",
             _span_bytes(b, DDRAW_ACCESSOR, DDRAW_ACCESSOR + 6),
             DDRAW_ACCESSOR_BYTES,
             lambda v: f"0x{DDRAW_ACCESSOR:08X} is mov eax, "
                       f"0x{DDRAW_MODULE:08X} / ret -- an address, not an "
                       "allocation, so there is a layout to read")

    read: list[tuple[Any, ...]] = []
    want: list[tuple[Any, ...]] = []
    for (name, entry, field, desc_push, size_store, call,
         file_push, label_push, success) in DDRAW_LOCK_HELPERS:
        guard = (b.u32(entry + 1)
                 if b.mapped(entry, 5) and b.u8(entry) == 0xA1 else None)
        pushes = (b.u32(desc_push + 1)
                  if b.mapped(desc_push, 5) and b.u8(desc_push) == 0x68
                  else None)
        sized = (b.u32(size_store + 6)
                 if b.mapped(size_store, 10) and b.u8(size_store) == 0xC7
                 and b.u8(size_store + 1) == 0x05
                 and b.u32(size_store + 2) == DDRAW_DESC
                 else None)
        slot = (b.u8(call + 2)
                if b.mapped(call, 3) and b.u8(call) == 0xFF
                and b.u8(call + 1) == 0x51 else None)
        source = (b.string(b.u32(file_push + 1))
                  if b.mapped(file_push, 5) and b.u8(file_push) == 0x68
                  else None)
        label = (b.string(b.u32(label_push + 1))
                 if b.mapped(label_push, 5) and b.u8(label_push) == 0x68
                 else None)
        returns = (b.u32(success + 1)
                   if b.mapped(success, 6) and b.u8(success) == 0xA1
                   and b.u8(success + 5) == 0xC3 else None)
        read.append((name, guard, pushes, sized, slot, source, label, returns))
        want.append((name, field, DDRAW_DESC, DDSURFACEDESC_SIZE,
                     SURFACE_LOCK_SLOT, DDRAW_SOURCE_FILE, DDRAW_LOCK_LABEL,
                     DDRAW_DESC + DDSURFACEDESC_SURFACE))
    ck.equal("ddraw.lock_helpers", read, want,
             lambda v: f"{len(v)} helper(s) fill a DDSURFACEDESC of "
                       f"0x{DDSURFACEDESC_SIZE:X} bytes and hand it to vtable "
                       f"+0x{SURFACE_LOCK_SLOT:02X}, returning its lpSurface")

    # The displacement comes off the instruction, so this is the code's
    # arithmetic and not the constants' own.
    # The `call` five bytes in front is what makes the base register the
    # accessor's return rather than any pointer that happens to be in `eax`.
    landings = [DDRAW_MODULE + b.u8(va + 2)
                if b.mapped(va - 5, 8) and b.u8(va) == 0x8B
                and b.u8(va + 1) in (0x40, 0x48)
                and b.u8(va - 5) == 0xE8
                and va + b.i32(va - 4) == DDRAW_ACCESSOR else None
                for va in LOCK_PITCH_READS]
    ck.equal("ddraw.field_offsets",
             landings + [b.u32(helper[8] + 1)
                         if b.mapped(helper[8], 6) else None
                         for helper in DDRAW_LOCK_HELPERS],
             [DDRAW_DESC + DDSURFACEDESC_PITCH] * len(LOCK_PITCH_READS)
             + [DDRAW_DESC + DDSURFACEDESC_SURFACE] * len(DDRAW_LOCK_HELPERS),
             lambda v: f"{len(LOCK_PITCH_READS)} read(s) through the "
                       "accessor's return -- each five bytes past the "
                       "call -- land on the descriptor's lPitch, "
                       "and both helpers return its lpSurface")

    # Neither field is written by an instruction: DirectDraw fills the
    # descriptor.  The only absolute references to either are the two
    # `mov eax, [lpSurface]` the helpers end on.
    pitch = DDRAW_DESC + DDSURFACEDESC_PITCH
    surface = DDRAW_DESC + DDSURFACEDESC_SURFACE
    refs = {pitch: [], surface: []}
    for cell, sites in refs.items():
        needle = struct.pack("<I", cell)
        start = b.pe.va_to_off(b.text_lo)
        blob = b.pe.data[start:start + (b.text_hi - b.text_lo)]
        index = blob.find(needle)
        while index >= 0:
            sites.append(b.text_lo + index)
            index = blob.find(needle, index + 1)
    ck.equal("ddraw.fields_are_filled_by_directdraw",
             (refs[pitch],
              [va - 1 for va in refs[surface]]),
             ([], [helper[8] for helper in DDRAW_LOCK_HELPERS]),
             lambda v: "no instruction names lPitch at all, and lpSurface "
                       f"only in the {len(v[1])} helper return(s) -- the "
                       "descriptor is written by the API")

    arms = []
    for mode, _arm in LOCK_ARMS:
        slot = LOCK_JUMP_TABLE + 4 * mode
        arm = b.u32(slot) if b.mapped(slot, 4) else 0
        end = LOCK_ARM_SPANS.get(arm, (arm + 0x10, None, None))[0]
        arms.append((mode, arm, _lock_arm_source(b, arm, end),
                     hashlib.sha256(
                         _span_bytes(b, arm, end)).hexdigest()[:16]))
    ck.equal("ddraw.lock_arms", arms,
             [(mode, arm) + LOCK_ARM_SPANS.get(arm, (0, None, None))[1:]
              for mode, arm in LOCK_ARMS],
             lambda v: f"{len(v)} display mode(s) through the jump table at "
                       f"0x{LOCK_JUMP_TABLE:08X}: "
                       + ", ".join(f"{mode}={source}"
                                   for mode, _arm, source, _d in v))


def _output_system_checks(ck: "Checker", b: Binary) -> None:
    """What `0x00512A9C` and `0x00512A60` are, read rather than inferred.

    `docs/97` §23.3 tabulated the display modes kind 59's arm branches on and
    marked two of its columns as interpretations -- a stride and a
    bytes-per-pixel named from their values.  Three readings replace that,
    and the first is the one that rules out the alternative:

    * the 320x200 case writes a stride of **640** for a 320-pixel row at one
      byte a pixel.  Whatever the number is, it is not ``width * bpp``;
    * the pixel plot `0x00463C40` multiplies it by the row and adds the
      column, storing a **byte**; its two sixteen-bit arms **halve** it first
      and store a **word** through an index scaled by two.  Both arms reach
      the same address only if the number counts bytes per row;
    * the bytes-per-pixel byte is used as one at `0x00447A70`, where a pixel
      count is multiplied by it.

    Not checked here, and deliberately: which surface field the *lock*
    `0x004617B0` copies the stride out of.  That routine takes it from
    `[obj + 0x28]` of whatever `0x00432C30` returns, and this file has no
    reading of that object's layout.
    """
    import hashlib

    read: list[tuple[Any, ...]] = []
    misplaced: list[str] = []
    for case in OUTPUT_MODE_CASES:
        values: list[Any] = [case["name"]]
        for column, target in (("mode", OUTPUT_MODE_GLOBAL),
                               ("width", OUTPUT_WIDTH),
                               ("height", OUTPUT_HEIGHT),
                               ("bpp", OUTPUT_BPP),
                               ("stride", OUTPUT_STRIDE)):
            kind, value_va, store_va = case[column]
            values.append(_output_value(b, kind, value_va))
            if not _stores_to(b, store_va, target):
                misplaced.append(f"{case['name']}.{column}")
        read.append(tuple(values))
    ck.equal("output.mode_table", read, list(OUTPUT_MODE_TABLE),
             lambda v: f"{len(v)} display mode(s) of aCreateOutputSystem, "
                       "each field read from the instruction that carries it")
    ck.equal("output.mode_stores", misplaced, [],
             lambda v: "every pinned value is stored into the global its "
                       "column names" if not v
                       else f"{len(v)} store(s) target something else: {v}")

    # **From what was read**, not from the pin beside it: computing this out
    # of `OUTPUT_MODE_TABLE` would compare a constant with itself.
    derived = tuple(row[0] for row in read
                    if None not in row[1:] and row[5] != row[2] * row[4])
    ck.equal("output.stride_is_not_derived", derived,
             OUTPUT_STRIDE_NOT_DERIVED,
             lambda v: f"{len(v)} mode(s) reserve more bytes a row than the "
                       "row holds -- so 0x00512A9C is a stride and not "
                       "width times bytes-per-pixel")

    paths = [(name, ) + (_plot_path(b, lo, hi) or ())
             for name, lo, hi in PLOT_PATHS]
    ck.equal("output.plot_arithmetic", paths, list(PLOT_EXPECTED),
             lambda v: f"{len(v)} arm(s) of the pixel plot: the stride "
                       "multiplies the row, the sixteen-bit arms halve it "
                       "and index words")
    lo, hi, want = PLOT_ROUTINE
    ck.equal("output.plot_unchanged",
             hashlib.sha256(_span_bytes(b, lo, hi)).hexdigest()[:16], want,
             lambda v: f"0x{lo:08X}..0x{hi:08X} byte for byte as read")

    getters = [(name, va,
                b.u32(va + 1) if b.mapped(va, 6) and b.u8(va) == 0xA1
                else None,
                b.mapped(va, 6) and b.u8(va + 5) == 0xC3)
               for name, va, _global in OUTPUT_GETTERS]
    ck.equal("output.getters", getters,
             [(name, va, target, True) for name, va, target in OUTPUT_GETTERS],
             lambda v: f"{len(v)} one-instruction getter(s): mov eax, "
                       "[global] / ret, and nothing else")
    ranges = [(name, hashlib.sha256(
        _span_bytes(b, lo, hi)).hexdigest()[:16])
        for name, lo, hi, _want in OUTPUT_MODE_RANGES]
    ck.equal("output.mode_ranges", ranges,
             [(name, want) for name, _lo, _hi, want in OUTPUT_MODE_RANGES],
             lambda v: f"{len(v)} case(s) byte for byte -- so the register a "
                       "pinned store writes is still the one the pinned load "
                       "filled")

    arms = []
    for index in range(len(OUTPUT_INFO_GLOBALS)):
        slot = OUTPUT_INFO_TABLE + 4 * index
        arm = b.u32(slot) if b.mapped(slot, 4) else 0
        # The table can be perturbed to garbage, and the address it then
        # names is not in the image at all.  Both reads are guarded for that
        # and not for tidiness.
        plain = b.mapped(arm, 6) and b.u8(arm) == 0xA1
        masks = (b.mapped(arm, 11) and b.u8(arm + 5) == 0x25
                 and b.u32(arm + 6) == 0xFF)
        arms.append((index, b.u32(arm + 1) if plain else None, masks))
    ck.equal("output.info_getter_arms", arms,
             [(index, target, index == OUTPUT_INFO_BPP_INDEX)
              for index, target in enumerate(OUTPUT_INFO_GLOBALS)],
             lambda v: f"{len(v)} arm(s) of the six-way output-info getter, "
                       "read through its jump table -- whose order is not the "
                       "arms' order in the code -- and only index "
                       f"{OUTPUT_INFO_BPP_INDEX} masks its dword to a byte")
    gate, scale = OUTPUT_BPP_GATE_SITE, OUTPUT_BPP_SCALE_SITE
    ck.check("output.bpp_gates_and_scales",
             b.mapped(gate, 13) and b.mapped(scale, 12)
             and b.u8(gate) == 0x6A and b.u8(gate + 1) == OUTPUT_INFO_BPP_INDEX
             and b.u8(gate + 2) == 0xE8
             and gate + 7 + b.i32(gate + 3) == OUTPUT_INFO_GETTER
             and b.u8(gate + 10) == 0x83 and b.u8(gate + 11) == 0xF8
             and b.u8(gate + 12) == 0x01
             and b.u8(scale) == 0xA1 and b.u32(scale + 1) == OUTPUT_BPP
             and b.u8(scale + 5) == 0x25 and b.u32(scale + 6) == 0xFF
             and b.u8(scale + 10) == 0x0F and b.u8(scale + 11) == 0xAF,
             f"0x{gate:08X} asks the getter for index "
             f"{OUTPUT_INFO_BPP_INDEX} and branches on it being 1; "
             f"0x{scale:08X} multiplies a clipped horizontal extent by the "
             "same byte -- a count of bytes each pixel takes")


def _eng_call(eng: "Engine", va: int) -> int | None:
    """The target of the ``call rel32`` at *va* in an Eng3d build."""
    try:
        if eng.pe.u8(va) != 0xE8:
            return None
        return va + 5 + eng.pe.i32(va + 1)
    except PEError:
        return None


def _sound_model_checks(ck: "Checker", b: Binary, c: Corpus) -> None:
    ck.equal("sound.play_slots", sound.PLAY_SLOTS, b.cmp_imm(PLAY_BOUND_SITE) + 1)
    ck.equal("sound.loader_slots", sound.LOADER_SLOTS,
             b.cmp_imm(LOAD_BOUND_SITE) + 1)
    ck.equal("sound.set_id_max", sound.SET_ID_MAX, b.cmp_imm(VOLUME_SETTER_BOUND_SITE))
    ck.equal("sound.load_id_max", sound.LOAD_ID_MAX,
             b.cmp_imm(VOLUME_LOAD_BOUND_SITE) - 1)

    # ---- 1.3: the attenuation, against the four constants the binary holds
    ck.equal("sound.volume_floor", sound.BASE_VOLUME_FLOOR,
             b.cmp_imm(VOLUME_FLOOR_SITE))
    ck.equal("sound.volume_silence", sound.SILENCE, VOLUME_SILENCE)
    ck.equal("sound.volume_offset", sound.ATTENUATION_OFFSET, VOLUME_OFFSET)
    ck.equal("sound.volume_per_percent", sound.HUNDREDTHS_PER_PERCENT,
             VOLUME_PER_PERCENT)

    # 100 % is the identity, and every point below it costs exactly 0.2 dB.
    bases = list(range(BASE_SWEEP_LO, BASE_SWEEP_HI + 1, BASE_SWEEP_STEP))
    # **The sweep has to reach both ends.**  Its step is a sampling density
    # rather than a measured value, so no perturbation of it can make the
    # identity below false -- the identity holds for every base.  What a
    # coarser step *can* do is stop short of full scale, which is the one
    # place the identity is interesting, so that is what is asserted.
    ck.equal("sound.sweep_spans_the_range",
             (bases[0], bases[-1]) if bases else (None, None),
             (BASE_SWEEP_LO, BASE_SWEEP_HI),
             lambda v: f"the sweep runs {v[0]} to {v[1]} -- the floor and "
                       "full scale, both included")
    ck.check("sound.percent_100_identity",
             all(sound.attenuation(v, 100) == min(v, 0) for v in bases),
             f"{len(bases)} base volumes, 100 % changes none of them")
    ck.check("sound.percent_step",
             all(sound.attenuation(0, p) - sound.attenuation(0, p - 1)
                 == VOLUME_PER_PERCENT for p in range(1, 101)),
             f"each point is {VOLUME_PER_PERCENT} hundredths of a dB")
    ck.equal("sound.silence_gate",
             (sound.attenuation(VOLUME_FLOOR, 100),
              sound.attenuation(VOLUME_FLOOR - 1, 100)),
             (VOLUME_FLOOR + VOLUME_PER_PERCENT * 100 + VOLUME_OFFSET,
              VOLUME_SILENCE))
    ck.check("sound.no_boost",
             sound.attenuation(0, INFO_VOLUME_SPECIAL[102]) == 0
             and sound.attenuation(0, 100) == 0,
             "id 102's 101 % is clipped at 0, exactly like 100 %")
    ck.equal("sound.passthrough",
             sound.scaled_volume(-1234, sound.NO_SCALING, c.volumes), -1234)

    # ---- 1.3: the model agrees with Info.lcl on all 103 ids
    ck.equal("sound.info_ids", len(c.volumes), sound.INFO_VOLUME_IDS)
    ck.equal("sound.info_ids_dense", sorted(c.volumes),
             list(range(sound.INFO_VOLUME_IDS)), Checker.brief)
    ck.equal("sound.scaled_all_ids",
             {i: sound.scaled_volume(BASE_SWEEP_HI, i, c.volumes)
              for i in sorted(c.volumes)},
             {i: min(BASE_SWEEP_HI + VOLUME_PER_PERCENT * p + VOLUME_OFFSET, 0)
              for i, p in sorted(c.volumes.items())}, Checker.brief)
    ck.check("sound.rejects_undefined",
             _raises(sound.scaled_volume, 0, sound.INFO_VOLUME_IDS, c.volumes)
             and _raises(sound.scaled_volume, 0, sound.LOAD_ID_MAX + 1, c.volumes),
             "an undefined id and one past the load bound are both refused")

    # ---- 1.1: the pool drops rather than growing
    pool = sound.SoundPool()
    got = [pool.load("w", 0, sound.NO_SCALING, c.volumes)
           for _ in range(sound.PLAY_SLOTS + 2)]
    ck.equal("sound.pool_drops", got,
             list(range(sound.PLAY_SLOTS)) + [-1, -1], Checker.brief)
    ck.equal("sound.pool_drop_count", pool.drops, 2)
    pool.kill(7)
    ck.equal("sound.pool_kill_frees",
             pool.load("w", 0, sound.NO_SCALING, c.volumes), 7)

    # ---- 2: the partition of the 62 sites
    sites = b.sound_sites()
    owned = [a for addresses in sound.EVENT_SITES.values() for a in addresses]
    ck.equal("sound.sites_partition", sorted(owned), sorted(sites),
             Checker.brief)
    ck.equal("sound.sites_disjoint", len(owned), len(set(owned)))
    ck.equal("sound.event_routines", sorted(sound.EVENT_ROUTINES),
             sorted(sound.EVENT_SITES), Checker.brief)
    entries = sorted(b.call_entries())
    owners = {}
    for event, addresses in sound.EVENT_SITES.items():
        found = {entries[bisect.bisect_right(entries, a) - 1] for a in addresses}
        owners[event] = sorted(found)
    ck.check("sound.sites_in_one_routine",
             all(len(v) == 1 for v in owners.values()),
             f"each of the {len(owners)} events' sites lie in one routine")
    ck.equal("sound.event_owner",
             {e: v[0] for e, v in owners.items()},
             dict(sound.EVENT_ROUTINES), Checker.brief)

    # ---- 1.4: which loads loop, derived from the play sites
    plays = sorted(PLAY_SITES)
    derived = tuple(a for a in sorted(sites)
                    if PLAY_SITES[plays[bisect.bisect_right(plays, a)]][1]
                    == PLAY_LOOPING)
    ck.equal("sound.looping_loads", tuple(sorted(sound.LOOPING_LOADS)), derived,
             Checker.brief)
    ck.equal("sound.looping_plays",
             len({plays[bisect.bisect_right(plays, a)]
                  for a in sound.LOOPING_LOADS}),
             sound.LOOPING_PLAY_SITES)

    # ---- 2: the catalogue the converter writes
    table = sound.catalogue(sites)
    cues = [cue for group in table.values() for cue in group]
    ck.equal("sound.catalogue_size", len(cues),
             len(sites) - len(sound.COMPUTED_SITES))
    ck.equal("sound.computed_sites", sorted(sound.COMPUTED_SITES),
             sorted(a for a, (w, v) in sites.items() if w is None or v is None
                    or w.startswith("%")), Checker.brief)
    ck.check("sound.catalogue_volume_ids",
             all(sound.load_id_valid(cue.volume_id) for cue in cues),
             f"all {len(cues)} cue ids pass the load bound")
    ck.check("sound.catalogue_ids_defined",
             all(cue.volume_id == sound.NO_SCALING or cue.volume_id in c.volumes
                 for cue in cues),
             "every id a cue carries is defined by Info.lcl")

    # ---- 2.2: case
    index = sound.wave_index(c.waves)
    ck.equal("sound.case_index", len(index), len(c.waves))
    # Every literal name in the image, not only the ones this slice plays:
    # the ten renames of section 2.2 are only ten when the direct sites are
    # counted too, and a check over a subset would find eight and look right.
    literal = sorted({cue.wave for cue in cues}
                     | {n for n, _v in b.voice_arms() if n}
                     | {w for _t, w, _v, _p in b.walk_arms().values() if w}
                     | {w for w, _v in b.direct_sites().values()
                        if w and "%" not in w})
    ck.equal("sound.case_literals", len(literal), CASE_LITERALS)
    ck.equal("sound.case_call_literals",
             len({w for w, _v in b.sound_sites().values() if w and "%" not in w}
                 | {w for w, _v in b.direct_sites().values()
                    if w and "%" not in w}),
             CASE_CALL_LITERALS)
    ck.check("sound.case_resolves",
             all(sound.resolve_wave(n, index) for n in literal),
             f"{len(literal)}/{len(literal)} literal names resolve")
    ck.equal("sound.case_mismatched",
             tuple(sorted(n for n in literal
                          if sound.resolve_wave(n, index) != n)),
             CASE_MISMATCHED, Checker.brief)

    # ---- 3: the weapon's own fire sound
    ck.equal("sound.weapon_format", sound.WEAPON_WAVE_FORMAT,
             WEAPON_WAVE_FORMAT)
    ck.equal("sound.weapon_band", sound.WEAPON_VOLUME_BAND, WEAPON_VOLUME_BAND)
    fires = {w: sound.weapon_fire(w, c.weapon_waves, index)
             for w in sorted(c.weapon_waves)}
    ck.equal("sound.weapon_waves", len(fires), INFO_WEAPON_WAVES)
    ck.equal("sound.weapon_unresolved",
             tuple(w for w, cue in fires.items() if cue is None),
             WEAPON_WAVE_TYPO)
    ck.check("sound.weapon_volume_is_id",
             all(cue.volume_id == w for w, cue in fires.items() if cue),
             f"{sum(1 for cue in fires.values() if cue)} weapons, each scaled "
             "by its own id")
    ck.check("sound.weapon_35_corrected",
             sound.weapon_fire(sound.WEAPON_MISSING_SOUND, c.weapon_waves,
                               index, faithful=False) is not None,
             "the correction resolves the name the Faithful preset does not")

    # ---- 4.1: the two cursors
    voices = sound.VoiceCursors()
    human = [voices.pain(sound.SPECIES_HUMAN) for _ in range(3)]
    alien = [voices.pain(sound.SPECIES_ALIEN) for _ in range(3)]
    ck.equal("sound.voice_human",
             [(cue.wave, cue.volume_id) for cue in human],
             [(n, v) for _s, n, _vs, v in reversed(VOICE_ARMS[10:13])],
             Checker.brief)
    ck.equal("sound.voice_alien_fixed",
             [cue.volume_id for cue in alien],
             list(sound.ALIEN_PAIN_VOLUME_IDS))
    ck.equal("sound.voice_alien_original",
             [c2.volume_id for c2 in
              [sound.VoiceCursors(fix_alien_volume=False)
               .pain(sound.SPECIES_ALIEN) for _ in range(1)]],
             [sound.PAIN_VOLUME_IDS[0]])
    ck.equal("sound.voice_wraps",
             [voices.pain(sound.SPECIES_HUMAN).wave for _ in range(4)],
             [sound.PAIN_WAVES[0][i] for i in (0, 1, 2, 0)], Checker.brief)
    shared = sound.VoiceCursors()
    shared.pain(sound.SPECIES_HUMAN)
    ck.equal("sound.voice_shared_cursor", shared.second_human().wave,
             sound.SECOND_HUMAN_WAVES[1])
    ck.equal("sound.voice_silent_species",
             sound.VoiceCursors().pain(2), None)
    death = sound.VoiceCursors()
    ck.equal("sound.death_alien_ids",
             [death.death(sound.SPECIES_ALIEN).volume_id for _ in range(3)],
             list(sound.DEATH_ALIEN_VOLUME_IDS))
    ck.equal("sound.death_machine_explodes",
             (death.death(sound.SPECIES_MACHINE).wave,
              death.death(sound.SPECIES_MACHINE).volume_id),
             (sound.DEATH_EXPLOSION_WAVE, sound.DEATH_EXPLOSION_VOLUME_ID))
    ck.equal("sound.death_object_is_silent", death.death(2), None)
    # The mute covers the **explosion**: `0x0040C9AC` jumps into the same
    # `0x0040CBD6` every scream does, and `0x0040CBDB` is the next thing.
    ck.equal("sound.death_machine_is_muted",
             death.death(sound.SPECIES_MACHINE, 0x1A), None)
    muted = sound.VoiceCursors()
    ck.equal("sound.death_mute_still_moves_the_cursor",
             (muted.death(sound.SPECIES_HUMAN, 0x16),
              muted.death(sound.SPECIES_HUMAN).wave),
             (None, sound.SECOND_HUMAN_WAVES[1]),
             "the gate at 0x0040CBF2 is past the round robin")
    ck.equal("sound.death_shares_the_pain_cursor",
             sound.VoiceCursors().death(sound.SPECIES_HUMAN).wave,
             sound.SECOND_HUMAN_WAVES[0])

    # ---- 5: the eight footstep arms
    walk = b.walk_arms()
    ck.equal("sound.footstep_arms", sorted(sound.FOOTSTEP_ARMS), sorted(walk),
             Checker.brief)
    ck.equal("sound.footstep_types",
             sorted(t for types, _s in sound.FOOTSTEP_ARMS.values()
                    for t in types),
             list(range(sound.FOOTSTEP_TYPES)), Checker.brief)
    ck.equal("sound.footstep_table",
             {t: ((s.wave, s.volume_id, s.period) if s else None)
              for t in range(sound.FOOTSTEP_TYPES)
              for s in (sound.footstep(t),)},
             {t: ((wave, volume, period) if wave else None)
              for types, wave, volume, period in walk.values()
              for t in types},
             Checker.brief)
    ck.equal("sound.footstep_silent",
             sum(1 for t in range(sound.FOOTSTEP_TYPES)
                 if sound.footstep(t) is None), WALK_SILENT_TYPES)
    ck.equal("sound.footstep_24_faithful",
             sound.footstep(sound.FOOTSTEP_STRAY_TYPE).volume_id,
             WALK_STRAY_VOLUME[0])
    ck.equal("sound.footstep_24_corrected",
             sound.footstep(sound.FOOTSTEP_STRAY_TYPE,
                            faithful=False).volume_id,
             sound.FOOTSTEP_FIXED_VOLUME_ID)
    ck.check("sound.footstep_24_is_louder",
             c.volumes[WALK_STRAY_VOLUME[0]] > c.volumes[
                 sound.FOOTSTEP_FIXED_VOLUME_ID],
             f"id {WALK_STRAY_VOLUME[0]} is "
             f"{c.volumes[WALK_STRAY_VOLUME[0]]} %, id "
             f"{sound.FOOTSTEP_FIXED_VOLUME_ID} is "
             f"{c.volumes[sound.FOOTSTEP_FIXED_VOLUME_ID]} %")

    # ---- 2.3 and 8.1: the named outcome sets
    ck.equal("sound.overheat_cues",
             {k: (v.wave, v.volume_id)
              for k, v in sorted(sound.OVERHEAT_CUES.items())},
             {k: sites[v.site] for k, v in sorted(sound.OVERHEAT_CUES.items())},
             Checker.brief)
    ck.equal("sound.overheat_sites",
             sorted(cue.site for cue in sound.OVERHEAT_CUES.values()),
             sorted(sound.EVENT_SITES["overheat"]), Checker.brief)
    switch_waves = {name for _arm, wave in b.weapon_sounds().values()
                    if wave for _site, name in (wave,)}
    ck.equal("sound.impact_cues",
             {cue.wave for cue in sound.IMPACT_CUES.values()}, switch_waves,
             Checker.brief)
    ck.equal("sound.impact_silent_weapons",
             sum(1 for _arm, wave in b.weapon_sounds().values() if wave is None),
             IMPACT_SOUND_SILENT)

    # ---- the one set-piece frame count the documents do not give
    #
    # A remake has to pace `RoofUnit` at *some* rate, and the difference
    # between a guess and this is one `sub` instruction.
    ck.equal("roof.drop_step", b.i32(ROOF_DROP_SITE + 1), ROOF_DROP_STEP, hex)
    ck.equal("roof.draw_offset", b.i32(ROOF_DRAW_OFFSET_SITE + 1),
             ROOF_DRAW_OFFSET, hex)
    ck.equal("roof.tick", b.call_target(ROOF_TICK_SITE), FRAME_TICK, hex)
    ck.check("roof.step_is_one_field", ROOF_DROP_STEP == 3200,
             "the falling unit drops a whole map field per displayed frame")
    # The three sites really are inside `RoofUnit`'s own routine, bounded by
    # the next call entry -- otherwise the constants above would be read out
    # of whatever function happened to follow it.
    entries = sorted(b.call_entries())
    # And the address itself is a routine somebody calls, not an offset into
    # one: the containment test below tolerates a wrong byte, this does not.
    ck.check("roof.is_a_routine", ROOF_UNIT in set(entries),
             f"0x{ROOF_UNIT:08X} is the target of a call")
    after = [e for e in entries if e > ROOF_UNIT]
    end = min(after) if after else ROOF_UNIT + 0x600
    ck.check("roof.sites_inside",
             all(ROOF_UNIT < site < end for site in
                 (ROOF_DROP_SITE, ROOF_DRAW_OFFSET_SITE, ROOF_TICK_SITE)),
             f"the drop, the draw offset and the tick all lie in "
             f"0x{ROOF_UNIT:08X}..0x{end:08X}")

    # ---- 6: nothing dead reaches the cache
    wanted, missing = sound.wanted_waves(sites, c.weapon_waves, index)
    ck.check("sound.wanted_resolve",
             all(w in c.waves for w in wanted),
             f"{len(wanted)} shipped waves in the closure")
    ck.equal("sound.wanted_missing", tuple(missing),
             (WEAPON_WAVE_FORMAT % c.weapon_waves[WEAPON_WAVE_TYPO[0]],))
    # docs/43 section 7: the watched player's screen is the one place outside
    # `aAnimations.cpp` and the id-96 set that names a wave, and a cache built
    # before it existed was silent under the whole computer turn.
    ck.check("sound.view_player_in_closure",
             all(index.get(cue.wave.lower()) in wanted
                 for cue in sound.VIEW_PLAYER_CUES.values()),
             f"{len(sound.VIEW_PLAYER_CUES)} aViewPlayer waves are copied")
    ck.check("sound.wanted_excludes_dead",
             not (set(wanted) & {c.resolves(n) for n in sound.DEAD_WAVES}),
             f"none of the {len(sound.DEAD_WAVES)} unreferenced waves is wanted")
    ck.equal("sound.dead_waves", tuple(sorted(sound.DEAD_WAVES)),
             tuple(sorted(WAVES_UNREFERENCED)), Checker.brief)

    # ---- the pins the mutation battery found nothing reading -------------
    #
    # Every one of these was silent under a one-step perturbation until the
    # check beside it existed.  Each compares the model against **decoded**
    # data rather than against a second copy of itself.
    ck.equal("sound.weapon_missing_id", sound.WEAPON_MISSING_SOUND,
             WEAPON_WAVE_TYPO[0])
    # The alien scream's corrected ids are the ones the *fall* sequence loads
    # with `S_ALI_0/1/2`, read back out of `aPlayJumpAnimaion`'s own sites.
    fall = {name: volume for name, volume in
            (sites[a] for a in sound.EVENT_SITES["jump"])
            if name and name.startswith("S_ALI_")}
    ck.equal("sound.alien_ids_from_fall",
             tuple(sound.ALIEN_PAIN_VOLUME_IDS),
             tuple(fall[n] for n in sorted(fall)))
    # The second human set's ids are the human death arms', decoded; the
    # alien death arms carry the same waves at 53..55, and a machine's death
    # is `explosion.wav` @63 (docs/42 section 4.5).
    ck.equal("sound.second_human_ids",
             tuple(sound.SECOND_HUMAN_VOLUME_IDS),
             tuple(v for _n, v in reversed(b.voice_arms()[4:7])))
    ck.equal("sound.second_human_waves",
             tuple(sound.SECOND_HUMAN_WAVES),
             tuple(n for n, _v in reversed(b.voice_arms()[4:7])))
    ck.equal("sound.death_alien_ids_decoded",
             tuple(sound.DEATH_ALIEN_VOLUME_IDS),
             tuple(v for _n, v in reversed(b.voice_arms()[1:4])))
    ck.equal("sound.death_alien_waves_decoded",
             tuple(sound.SECOND_HUMAN_WAVES),
             tuple(n for n, _v in reversed(b.voice_arms()[1:4])))
    ck.equal("sound.death_explosion_decoded",
             (sound.DEATH_EXPLOSION_WAVE, sound.DEATH_EXPLOSION_VOLUME_ID),
             b.voice_arms()[0])
    ck.equal("sound.cursor_modulus", sound.PAIN_CURSOR_MODULUS,
             len(sound.PAIN_WAVES[sound.SPECIES_HUMAN]))
    ck.equal("sound.footstep_stray_id", sound.FOOTSTEP_STRAY_VOLUME_ID,
             walk[[a for a, (t, _w, _v, _p) in walk.items()
                   if t == (sound.FOOTSTEP_STRAY_TYPE,)][0]][2])
    # The corrected id is its twin's -- the other `mdecther.wav` arm, which is
    # what makes 45 recognisable as a typo rather than a choice.
    twin = [v for _t, w, v, _p in walk.values()
            if w == sound.footstep(sound.FOOTSTEP_STRAY_TYPE).wave
            and v != sound.FOOTSTEP_STRAY_VOLUME_ID]
    ck.equal("sound.footstep_fixed_id", [sound.FOOTSTEP_FIXED_VOLUME_ID], twin)
    # Id 96 and its five waves, from the seventeen direct sites.
    direct = b.direct_sites()
    ck.equal("sound.interface_id", sound.INTERFACE_VOLUME_ID,
             sorted({v for _n, v in direct.values()
                     if v is not None and v != sound.NO_SCALING})[0])
    # **Equality against the sites that carry id 96, not containment against
    # every direct site.** Containment tolerated a perturbed name that happened
    # to be some *other* direct site's, which is exactly what the mutation
    # battery found: `click_2.wav` -> `click_3.wav` stayed inside the set and
    # nothing failed. Filtering the sites by the volume id is a second reading
    # -- it derives the tuple from the binary rather than checking it is a
    # subset of something larger -- and it re-pins 96 in the same breath.
    ck.equal("sound.interface_waves",
             tuple(sorted(_sites_with_volume(direct,
                                             sound.INTERFACE_VOLUME_ID))),
             tuple(sorted(w.lower() for w in sound.INTERFACE_WAVES)),
             Checker.brief)
    ck.equal("sound.impact_cue_ids",
             {k: v.volume_id for k, v in sorted(sound.IMPACT_CUES.items())},
             {k: sites[v.site][1]
              for k, v in sorted(sound.IMPACT_CUES.items())}, Checker.brief)
    ck.equal("sound.atlas_name_present",
             sorted(c.texture(ATLAS_NAME)), sorted(c.prototypes),
             Checker.brief)
    ck.equal("sound.atlas_size",
             sorted({size for size in c.texture(ATLAS_NAME).values()}),
             [(ATLAS_SIZE, ATLAS_SIZE)])
    # The grid really is square in the *binary* too: the row and the column
    # bytes are both scaled by the same shift on the way to the draw call, and
    # that shift is the tile size. Comparing `ATLAS_TILE * ATLAS_GRID` with
    # `ATLAS_SIZE` was comparing a definition with itself once the duplicate
    # literal was removed.
    ck.equal("sound.atlas_grid_squares",
             (b.shl_scale(ATLAS_ROW_SCALE_SITE),
              b.shl_scale(ATLAS_COL_SCALE_SITE)),
             (ATLAS_TILE, ATLAS_TILE))
    ck.equal("kind.arm_count", len(set(b.kind_arms().values())), KIND_ARMS)

    # ---- the playlist, and the compatibility flags
    ck.equal("sound.playlist", sound.playlist("3.5.7.3.4.5"), [3, 5, 7, 3, 4, 5],
             Checker.brief)
    ck.equal("sound.playlist_drops_junk", sound.playlist("3..x.5"), [3, 5])
    ck.equal("sound.compat_flags", sound.COMPAT_FLAGS,
             (sound.COMPAT_WEAPON_35, sound.COMPAT_FOOTSTEP_24))
    # A flag *name* has one independent reading and it is not in this binary:
    # the remake spells the same two strings, by hand, in `game/audio/`. A
    # rename on one side and not the other silently gives the player a preset
    # that toggles nothing, which is the whole failure this catches.
    spelled = _flag_names_in_remake()
    ck.check("sound.compat_flags_spelled",
             spelled is not None
             and all(flag in spelled for flag in sound.COMPAT_FLAGS),
             f"both flag names appear in {REMAKE_AUDIO_DIR}"
             if spelled is not None else f"{REMAKE_AUDIO_DIR} is not readable")


#: The fixture `godot/tests/test_sound.gd` replays.  Bumped when its shape
#: changes, so a stale copy is refused by name rather than silently read.
SOUND_CASES_SCHEMA = "incubation.sound-cases/1"


def emit_sound_cases(root: str, out: str) -> int:
    """Write the trace the GDScript sound layer is compared against.

    The oracle boundary is **executable-Python**: every expectation here is
    produced by `inclib/sound.py`, which is itself checked against the binary
    by `--check`.  Nothing in this file claims native parity, and the fixture
    says so in its own schema note.
    """
    b = Binary(root)
    c = Corpus(root)
    if not c.waves or not c.volumes:
        raise SystemExit(f"{root}: no Waves/ or no Info.lcl -- is that the "
                         "game root?")
    sites = b.sound_sites()
    index = sound.wave_index(c.waves)

    attenuations = []
    for base in range(VOLUME_FLOOR - 500, 1, 100):
        for percent in (0, 1, 50, 99, 100, 101, 120):
            attenuations.append({"base": base, "percent": percent,
                                 "want": sound.attenuation(base, percent)})

    scaled = []
    for volume_id in sorted(c.volumes) + [sound.NO_SCALING]:
        for base in (0, -1000, VOLUME_FLOOR, VOLUME_FLOOR - 1):
            scaled.append({"base": base, "volume_id": volume_id,
                           "want": sound.scaled_volume(base, volume_id,
                                                       c.volumes)})

    # The pool, as an op log the twin replays step for step.
    pool = sound.SoundPool()
    pool_ops = []
    for step in range(sound.PLAY_SLOTS + 3):
        got = pool.load("w%d.wav" % step, 0, sound.NO_SCALING, c.volumes)
        pool.play(got, step % 4 == 0)
        pool_ops.append({"op": "load", "want": got, "drops": pool.drops,
                         "loop": step % 4 == 0})
    for slot in (0, 7, 19):
        pool_ops.append({"op": "kill", "slot": slot,
                         "want": 1 if pool.kill(slot) else 0,
                         "drops": pool.drops, "loop": False})
    pool_ops.append({"op": "kill_looping", "want": pool.kill_looping(),
                     "drops": pool.drops, "loop": False})
    pool_ops.append({"op": "live", "want": len(pool.live()),
                     "drops": pool.drops, "loop": False})

    voices = sound.VoiceCursors()
    voice_trace = []
    # The type id each call is made with.  Two of the eleven are in
    # :attr:`sound.VoiceCursors.MUTE_TYPES` so the trace exercises the gate at
    # ``0x0040CBDB`` rather than only the waves: one of them lands on a
    # ``death`` step of species 3, which is the machine's explosion arm -- the
    # one whose mute both twins used to skip.
    voice_types = (1, 0x16, 2, 3, 4, 5, 0x1A, 7, 8, 9, 10)
    for step, species in enumerate((0, 1, 0, 1, 0, 2, 1, 0, 1, 0, 1)):
        type_id = voice_types[step]
        cue = voices.pain(species, type_id)
        voice_trace.append({"call": "pain", "species": species,
                            "type_id": type_id,
                            "wave": cue.wave.lower() if cue else "",
                            "volume_id": cue.volume_id if cue else 0})
        if step % 4 == 3:
            second = voices.second_human()
            voice_trace.append({"call": "second_human", "species": 0,
                                "type_id": -1,
                                "wave": second.wave.lower(),
                                "volume_id": second.volume_id})
        if step % 3 == 2:
            died = voices.death(species if species != 2 else 3, type_id)
            voice_trace.append({"call": "death",
                                "species": species if species != 2 else 3,
                                "type_id": type_id,
                                "wave": died.wave.lower() if died else "",
                                "volume_id": died.volume_id if died else 0})

    footsteps = []
    for unit_type in range(sound.FOOTSTEP_TYPES):
        for faithful in (True, False):
            step = sound.footstep(unit_type, faithful=faithful)
            footsteps.append({
                "type": unit_type, "faithful": faithful,
                "wave": step.wave.lower() if step else "",
                "volume_id": step.volume_id if step else 0,
                "period": -1 if step is None or step.period is None
                          else step.period})

    # The period global, as an ordered trace: type 54 writes none, so what it
    # walks at depends on who walked before it.
    carry = sound.WalkPeriod()
    walk_trace = []
    for unit_type in (54, 0, 54, 20, 54, 7, 54, 24, 54):
        step = carry.start(unit_type)
        walk_trace.append({"type": unit_type,
                           "wave": step.wave.lower() if step else "",
                           "period": step.period if step else -1,
                           "global": carry.frames})

    weapons = []
    for weapon in sorted(c.weapon_waves):
        for faithful in (True, False):
            cue = sound.weapon_fire(weapon, c.weapon_waves, index,
                                    faithful=faithful)
            weapons.append({"weapon": weapon, "faithful": faithful,
                            "wave": cue.wave.lower() if cue else "",
                            "volume_id": cue.volume_id if cue else -1})

    table = sound.catalogue(sites)
    wanted, missing = sound.wanted_waves(sites, c.weapon_waves, index)
    payload = {
        "schema": SOUND_CASES_SCHEMA,
        "oracle": "executable-Python (tools/inclib/sound.py); a transcription "
                  "of the sound layer's tables compared against a "
                  "transcription, not a recording of the engine playing",
        # The very document the cache carries, so the suite builds its tables
        # from the same input the game does rather than from a second shape
        # that could drift away from it.
        "document": sound_document(root),
        "play_slots": sound.PLAY_SLOTS,
        "volume_table": {str(k): v for k, v in sorted(c.volumes.items())},
        "attenuation": attenuations,
        "scaled": scaled,
        "pool": pool_ops,
        "voices": voice_trace,
        "footsteps": footsteps,
        "walk_period": {"initial": sound.FOOTSTEP_PERIOD_INITIAL,
                        "trace": walk_trace},
        "weapons": weapons,
        "catalogue": {event: [{"wave": cue.wave.lower(),
                               "volume_id": cue.volume_id,
                               "loop": cue.loop}
                              for cue in cues]
                      for event, cues in sorted(table.items())},
        "case_map": {name.lower(): name for name in sorted(wanted)},
        "wanted": wanted,
        "unresolved": missing,
        "overheat": {name: {"wave": cue.wave.lower(),
                            "volume_id": cue.volume_id}
                     for name, cue in sorted(sound.OVERHEAT_CUES.items())},
        "impact": {name: {"wave": cue.wave.lower(),
                          "volume_id": cue.volume_id}
                   for name, cue in sorted(sound.IMPACT_CUES.items())},
        "playlists": [{"program": text, "want": sound.playlist(text)}
                      for text in ("3.5.7.3.4.5", "6.3.5", "3.7.5.4",
                                   "3.5.4", "7.4.5", "3..x.5", "")],
    }
    path = Path(out)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n",
                    encoding="utf-8")
    LOG.warning("wrote %s (%d attenuations, %d scaled, %d footsteps, "
                "%d weapons, %d events)", out, len(attenuations), len(scaled),
                len(footsteps), len(weapons), len(table))
    return 0


def _raises(fn, *args) -> bool:
    try:
        fn(*args)
    except sound.SoundError:
        return True
    return False


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


#: The two documents the converter writes into the cache.  They are built here
#: rather than in ``inclib/convert.py`` so the binary has exactly one reader.
SOUND_DOCUMENT_SCHEMA = "incubation.sound/1"
BLOB_DOCUMENT_SCHEMA = "incubation.blobs/1"

#: The sprite atlas: one 256x256 VISN record named ``anim``, an 8x8 grid of
#: 32x32 tiles, drawn as a camera-facing quad of half-extent ``size * 160``
#: world units (docs/28 section 7.3).
ATLAS_NAME = ATLAS_TEXTURE
#: The half-extent scale is `SIZE_SCALE`, not a second copy of 160: it used to
#: be one, and nothing read it.
ATLAS_HALF_EXTENT_SCALE = SIZE_SCALE


def _speech_document(root: str) -> dict:
    """docs/28 4.3 as data: the sets, the arms, the gates and the tree."""
    files: dict[str, str] = {}
    speech_root = Path(root) / WAVES_DIR / sound.SPEECH_DIRECTORY
    for entry in sorted(speech_root.glob("*/*")):
        # `.wav` only.  The tree is browsed by hand often enough that a stray
        # `.DS_Store` would otherwise join the closure, be copied into the
        # cache and move the file count the suites pin -- with nothing here
        # failing first.
        if not entry.is_file() or entry.suffix.lower() != ".wav":
            continue
        key = ("%s/%s" % (entry.parent.name, entry.name)).lower()
        files[key] = "%s/%s" % (entry.parent.name, entry.name)
    return {
        "volume_id": sound.SPEECH_VOLUME_ID,
        "sets": {str(i): {"directory": directory, "prefix": prefix}
                 for i, (directory, prefix) in sorted(sound.SPEECH_SETS.items())},
        "arms": {str(i): {"category": arm.category,
                          "cursor": ("0x%08X" % arm.cursor) if arm.cursor else "",
                          "modulus": arm.modulus if arm.modulus is not None else -1,
                          "draw": list(arm.draw) if arm.draw else []}
                 for i, arm in sorted(sound.SPEECH_ARMS.items())},
        "events": {event: list(args) for event, args
                   in sorted(sound.SPEECH_EVENT_ARGUMENTS.items())},
        "hurt_threshold": sound.SPEECH_HURT_THRESHOLD,
        "mute_type": sound.SPEECH_MUTE_TYPE,
        "unowned": sound.SPEECH_UNOWNED,
        "random_set": sound.SPEECH_RANDOM_SET,
        "random_category": sound.SPEECH_RANDOM_CATEGORY,
        "random_draw": list(sound.SPEECH_RANDOM_DRAW),
        "dead_categories": list(sound.SPEECH_DEAD_CATEGORIES),
        "files": files,
    }


def sound_document(root: str) -> dict:
    """The sound layer as portable data, waves named by their cache file.

    Case is resolved **here, once**: the document names every wave in lower
    case and the converter writes the file under that name, so the runtime
    never does a case-insensitive search and docs/28 section 2.2's hazard
    cannot recur on a case-sensitive filesystem.
    """
    b = Binary(root)
    c = Corpus(root)
    sites = b.sound_sites()
    index = sound.wave_index(c.waves)
    table = sound.catalogue(sites)

    def cue(entry) -> dict:
        return {"wave": entry.wave.lower(), "volume_id": entry.volume_id,
                "loop": entry.loop, "site": f"0x{entry.site:08X}"}

    weapons = {}
    for weapon in sorted(c.weapon_waves):
        fire = sound.weapon_fire(weapon, c.weapon_waves, index)
        corrected = sound.weapon_fire(weapon, c.weapon_waves, index,
                                      faithful=False)
        weapons[str(weapon)] = {
            "wave": fire.wave.lower() if fire else None,
            "corrected": corrected.wave.lower() if corrected else None,
            "volume_id": weapon,
            "declared": sound.WEAPON_WAVE_FORMAT % c.weapon_waves[weapon],
        }

    wanted, missing = sound.wanted_waves(sites, c.weapon_waves, index)
    return {
        "schema": SOUND_DOCUMENT_SCHEMA,
        "source": {"exe": GAME_EXE, "info": INFO_LCL},
        "play_slots": sound.PLAY_SLOTS,
        "attenuation": {
            "base_floor": sound.BASE_VOLUME_FLOOR,
            "silence": sound.SILENCE,
            "offset": sound.ATTENUATION_OFFSET,
            "per_percent": sound.HUNDREDTHS_PER_PERCENT,
            "ceiling": sound.ATTENUATION_CEILING,
            "no_scaling": sound.NO_SCALING,
            "load_id_max": sound.LOAD_ID_MAX,
            "set_id_max": sound.SET_ID_MAX,
        },
        "volumes": {str(i): v for i, v in sorted(c.volumes.items())},
        "events": {event: [cue(entry) for entry in entries]
                   for event, entries in sorted(table.items())},
        "weapons": weapons,
        "voices": {
            "human": [w.lower() for w in sound.PAIN_WAVES[sound.SPECIES_HUMAN]],
            "alien": [w.lower() for w in sound.PAIN_WAVES[sound.SPECIES_ALIEN]],
            "second_human": [w.lower() for w in sound.SECOND_HUMAN_WAVES],
            "volume_ids": list(sound.PAIN_VOLUME_IDS),
            "alien_volume_ids": list(sound.ALIEN_PAIN_VOLUME_IDS),
            "second_human_volume_ids": list(sound.SECOND_HUMAN_VOLUME_IDS),
            "death_alien_volume_ids": list(sound.DEATH_ALIEN_VOLUME_IDS),
            "death_explosion": {"wave": sound.DEATH_EXPLOSION_WAVE.lower(),
                                "volume_id": sound.DEATH_EXPLOSION_VOLUME_ID},
            "cursor_modulus": sound.PAIN_CURSOR_MODULUS,
        },
        "footsteps": [
            {"arm": f"0x{arm:08X}", "types": list(types),
             "wave": step.wave.lower() if step else None,
             "volume_id": step.volume_id if step else -1,
             "period": step.period if step and step.period is not None else -1}
            for arm, (types, step) in sorted(sound.FOOTSTEP_ARMS.items())],
        "footstep_period_initial": sound.FOOTSTEP_PERIOD_INITIAL,
        "footstep_fix": {"type": sound.FOOTSTEP_STRAY_TYPE,
                         "original": sound.FOOTSTEP_STRAY_VOLUME_ID,
                         "corrected": sound.FOOTSTEP_FIXED_VOLUME_ID},
        "overheat": {name: cue(entry)
                     for name, entry in sorted(sound.OVERHEAT_CUES.items())},
        "impact": {name: cue(entry)
                   for name, entry in sorted(sound.IMPACT_CUES.items())},
        "interface": {"volume_id": sound.INTERFACE_VOLUME_ID,
                      "waves": [w.lower() for w in sound.INTERFACE_WAVES]},
        # docs/28 2.5: the mission interface's own clicks.  The wave is
        # reached through the module global the handle lives in, so the
        # document joins the two here and the remake never repeats an address.
        "mission_interface": {
            name: {"wave": sound.INTERFACE_BUFFERS[cue.buffer].lower(),
                   "volume_id": sound.INTERFACE_VOLUME_ID}
            for name, cue in sorted(sound.INTERFACE_CUES.items())},
        # docs/28 4.3: unit speech.  `files` is the whole shipped tree keyed
        # as the cache names it, because the original builds a name and asks
        # the filesystem -- a name that resolves to nothing is silence.
        "speech": _speech_document(root),
        # docs/43 section 7: the watched player's own two buffers.  Neither is
        # scaled by the volume table, and only `progress` is reachable outside
        # a network game.
        "view_player": {name: cue(entry) for name, entry
                        in sorted(sound.VIEW_PLAYER_CUES.items())},
        "view_player_alarm_mode": sound.VIEW_PLAYER_ALARM_MODE,
        "compat_flags": list(sound.COMPAT_FLAGS),
        "weapon_missing_sound": sound.WEAPON_MISSING_SOUND,
        "music": {"format": sound.MUSIC_FORMAT,
                  "alternate": sound.MUSIC_ALTERNATE_FORMAT},
        "waves": {name.lower(): name for name in wanted},
        "unresolved": missing,
    }


def blob_models(b: Binary) -> list:
    """Every ``.3DI`` name the 116 constructor calls pass, plus the four the
    heal flash loads by ``mov`` (:data:`BLOB_MODEL_MOV_SITES`), sorted."""
    names = {model for model, _cl, _k, _l in b.blob_calls().values()
             if isinstance(model, str)}
    for site in BLOB_MODEL_MOV_SITES:
        value = b.mov_imm32(site)
        name = b.string(value, 40) if value else None
        if name:
            names.add(name)
    return sorted(names)


def blob_document(root: str) -> dict:
    """The effect tables as portable data: the pool, the kinds, the creators,
    the sprite parameters, the three weapon switches and ``CreateBGB``."""
    b = Binary(root)
    arms = b.kind_arms()
    order: list = []
    for kind in sorted(arms):
        if arms[kind] not in order:
            order.append(arms[kind])
    spawns = b.kind_spawns()
    return {
        "schema": BLOB_DOCUMENT_SCHEMA,
        "source": {"exe": GAME_EXE},
        "pool": {
            "slots": BLOB_SLOTS,
            "stride": BLOB_STRIDE,
            "immortal_life": BLOB_IMMORTAL,
            "kind_bound": BLOB_KIND_BOUND,
            "gravity_split": BLOB_GRAVITY_SPLIT,
            "gravity_high": BLOB_GRAVITY_HIGH,
            "gravity_low": BLOB_GRAVITY_LOW,
        },
        "atlas": {"name": ATLAS_NAME, "tile": ATLAS_TILE, "grid": ATLAS_GRID,
                  "size": ATLAS_SIZE,
                  "half_extent_scale": ATLAS_HALF_EXTENT_SCALE},
        "kinds": {str(k): {"arm": f"0x{a:08X}", "arm_id": order.index(a),
                           "spawns": [_creator(t) for t in spawns.get(k, ())],
                           "unreachable": k in KIND_UNREACHABLE}
                  for k, a in sorted(arms.items())},
        "morph": {"kind": KIND_MORPH_TO, "life": KIND_MORPH_LIFE},
        "computed_kinds": {f"0x{s:08X}": list(produces)
                           for s, (_i, _b, produces) in
                           sorted(KIND_COMPUTED.items())},
        "unreachable": list(KIND_UNREACHABLE),
        "models": blob_models(b),
        "models_rare": {k: list(v) for k, v in
                        sorted(BLOB_MODELS_RARE.items())},
        "calls": {f"0x{s:08X}": {
            "model": m if isinstance(m, str) else None,
            "class": cl, "kind": k, "life": l,
            "creator": _creator_address(s)}
            for s, (m, cl, k, l) in sorted(b.blob_calls().items())},
        "sprites": {f"0x{s:08X}": {"row": r, "col": co, "size": z}
                    for s, (r, co, z) in sorted(b.sprite_params().items())},
        "creators": {f"0x{k:08X}": (v[1] if v else None)
                     for k, v in sorted(BLOB_CREATOR_NAMES.items())},
        # The switches name creators **by address**, not by name: several
        # names appear at more than one address (`aBlob_CreateLaser` at four),
        # which is what C++ overloads look like once the linker is done, and
        # keying by name would merge two different effects.
        "weapon_muzzle": {str(k): [f"0x{t:08X}" for _s, t in calls]
                          for k, (_a, calls) in sorted(WEAPON_MUZZLE.items())},
        # The arm every weapon the jump table does not cover reaches -- ids 0
        # and 1, the two starting guns.  See MUZZLE_DEFAULT.
        "weapon_muzzle_default": [f"0x{t:08X}"
                                  for _s, t in MUZZLE_DEFAULT[1]],
        "weapon_impact": {str(k): [f"0x{t:08X}" for _s, t in calls]
                          for k, (_a, calls) in sorted(WEAPON_IMPACT.items())},
        "weapon_impact_sound": {str(k): (w[1].lower() if w else None)
                                for k, (_a, w) in
                                sorted(WEAPON_IMPACT_SOUND.items())},
        "bgb": {"slots": BGB_SLOTS, "stride": BGB_STRIDE,
                "register": {str(k): _creator(target) if target else None
                             for k, (_site, target) in sorted(BGB_ARMS.items())},
                "tick": {str(k): _creator(target) if target else None
                         for k, (_site, target) in
                         sorted(BGB_TICK_ARMS.items())}},
        "joints": {str(k): {"model": model, "places": list(places),
                            "writes": [f"0x{w:02X}" for w in writes]}
                   for k, (model, places, writes) in
                   sorted(JOINT_KINDS.items())},
    }


def _creator_address(site: int):
    """The creator whose body contains constructor call *site*, as an address.

    Bounded by the nearest creator entry at or below the site.  Two of the 116
    calls sit outside every creator (docs/28 section 8's two foreign callers),
    and those come back ``None`` rather than being attributed to whichever
    function happens to precede them.
    """
    best = None
    for address in BLOB_CREATOR_NAMES:
        if address <= site and (best is None or address > best):
            best = address
    return None if best is None else f"0x{best:08X}"


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
        # The switches name creators **by address**, not by name: several
        # names appear at more than one address (`aBlob_CreateLaser` at four),
        # which is what C++ overloads look like once the linker is done, and
        # keying by name would merge two different effects.
        "weapon_muzzle": {str(k): [f"0x{t:08X}" for _s, t in calls]
                          for k, (_a, calls) in sorted(WEAPON_MUZZLE.items())},
        # The arm every weapon the jump table does not cover reaches -- ids 0
        # and 1, the two starting guns.  See MUZZLE_DEFAULT.
        "weapon_muzzle_default": [f"0x{t:08X}"
                                  for _s, t in MUZZLE_DEFAULT[1]],
        "weapon_impact": {str(k): [f"0x{t:08X}" for _s, t in calls]
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
    ap.add_argument("--emit-sound-cases", metavar="OUT",
                    help="write the sound-layer fixture the Godot suite reads")
    ap.add_argument("--root", metavar="ROOT",
                    help="the game root --emit-sound-cases reads")
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
    if args.emit_sound_cases:
        if not args.root:
            ap.error("--emit-sound-cases needs --root")
        return emit_sound_cases(args.root, args.emit_sound_cases)
    if not args.check:
        ap.print_help()
        return 2

    ck = run_checks(args.check)
    LOG.info("")
    LOG.info("%d checks, %d passed, %d failed", len(ck.names), ck.passed, ck.failed)
    return 1 if ck.failed else 0


if __name__ == "__main__":
    sys.exit(main())
