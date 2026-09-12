#!/usr/bin/env python3
"""Extract and check the combat tables described in ``docs/22``.

Three kinds of thing are verified:

**Static tables in ``Incubation.exe``.**  The weapon -> target-pattern dispatch
at ``0x0046B420`` / ``0x0046B3B0`` is a real two-level jump table with one
entry per weapon id, so it can be decoded and every id accounted for (48/48).
The same is done for the indirect-fire predicate at ``0x0047B600`` and the two
octant-neighbour tables at ``0x0046A930`` / ``0x0046A9A0``.

**Floating-point constants in ``.rdata``.**  The line-of-sight slope limit, the
three rounding biases, the two direction thresholds and the three RNG constants
are read out and compared against the values ``docs/22`` states.

**Derived arithmetic.**  ``aRandom`` is reimplemented from its constants; the
compiler's magic division at ``0x0046A35C`` is emulated bit-for-bit and
compared against ``n / 2400`` over the full height range the ``.lev`` corpus
contains; and the hit curve is evaluated for every shipped weapon at every
distance inside its range.

**Closure claims.**  Three statements in the documentation are of the form
"nothing else in the binary touches this", and each is checked by enumerating
every reference rather than by having failed to find one: the option blob's
eight rows and their help lines (``docs/20`` 7.6), the eleven sites that read
the ``special`` column (``docs/21`` 5), and the RNG's four globals, which must
lie inside ``aRandom``/``aRandomize`` in **both** game binaries.

Usage::

    python3 tools/combat_tables.py --check gog_incubation
    python3 tools/combat_tables.py --patterns gog_incubation
    python3 tools/combat_tables.py --hit-curve gog_incubation
    python3 tools/combat_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import struct
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import lcl  # noqa: E402
from inclib.combat import hit_percent, magic_div_2400_plus_1  # noqa: E402
from inclib.lev import LevError, load_lev  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("combat_tables")

GAME_EXE = "Incubation.exe"

# --- addresses, all virtual, all in Incubation.exe ---------------------------

#: `0x0046AA10`, the routine that marks the cells a weapon covers.
AOE_FUNC = 0x0046AA10
AOE_FUNC_END = 0x0046B3AF
#: `movzx ecx, byte [eax + 0x46B420]` -- one index byte per weapon id.
AOE_INDEX = 0x0046B420
#: `jmp dword [ecx*4 + 0x46B3B0]` -- the handler addresses.
AOE_JUMP = 0x0046B3B0
#: `aGetCtrlMapElementPtr`'s writing sibling; the marker is its 4th argument.
SET_CELL_STATE = 0x0042F7D0
#: The two guards inside it: an absolute height delta must be below 0x640
#: unless the supplied height is -1, and an existing 0x50..0x5E marker wins.
SET_CELL_STATE_GUARDS = (
    (0x0042F806,
     "8b44310103ce8b7424102bc69933c22bc23d400600007c0583feff7510",
     "absolute height delta below 0x640, or source height -1"),
    (0x0042F823, "8a013c5072043c5e76068a4424148801",
     "existing markers 0x50..0x5E refuse the write"),
)

#: `0x0047B600`: weapon id -> 1 when the shot is traced one field higher.
ARC_FUNC = 0x0047B600
ARC_BIAS = 8          # `add eax, -8` before the range check
ARC_LIMIT = 0x26      # `cmp eax, 0x26; ja default`
ARC_INDEX = 0x0047B638
ARC_JUMP = 0x0047B624

#: The two octant-neighbour tables, `jmp dword [eax*4 + table]`, eax in 0..7.
OCTANT_TABLES = {"a930": 0x0046A974, "a9a0": 0x0046A9E4}

#: `.rdata` doubles.  The names are this project's, the addresses the engine's.
CONSTANTS = {
    "zero":             (0x004B15D0, 0.0),
    "dir_threshold_hi": (0x004B15D8, 1.5),
    "dir_threshold_lo": (0x004B15E0, 0.5),
    "los_slope_max":    (0x004B15E8, 4000.0),
    "los_slope_min":    (0x004B15F0, -4000.0),
    "one":              (0x004B15F8, 1.0),
    "minus_one":        (0x004B1600, -1.0),
    "rng_multiplier":   (0x004B1530, 62089911.0),
    "rng_modulus":      (0x004B1538, 2147483647.0),
    "rng_scale":        (0x004B1540, 1.0 / (2.0 ** 31 - 1)),
}

#: The rounding biases `aCheckLineOfSightEx` passes to `aCheckLineOfSight`,
#: as the little-endian halves of a double in the instruction stream.
LOS_BIASES = {
    0.5: (0x00000000, 0x3FE00000),
    0.4: (0x9999999A, 0x3FD99999),
    0.6: (0x33333333, 0x3FE33333),
}

#: Cell markers written by the target-pattern pass and what each is worth.
#: ``None`` means the resolver forces the damage to zero (see docs/22 7.2).
MARKER_DAMAGE = {
    0x50: "full",
    0x51: "70%",          # (d*70 + 1) / 100
    0x52: "50%",          # (d*50 + 1) / 100, never written -- docs/22 12
    0x53: "flat 100",
    0x54: "none, forced hit",
    0x55: "none, forced hit, target loses its turn",
}

#: Weapon ids whose dispatch entry is the handler that reports an error and
#: returns FALSE, i.e. weapons with no target pattern at all.  Decoded from the
#: binary; listed here so a change in the binary or in this decoder is a
#: failure rather than a silent difference.
EXPECTED_NO_PATTERN = {18, 19, 28, 33, 34, 35, 37, 38, 39}

#: `0x0047B600` returns 1 for exactly these -- the grenade launcher, the
#: enhanced mine thrower, and the B mode of each.
EXPECTED_ARCING = {8, 13, 42, 46}

#: Every marker any part of the binary ever writes into a cell.  ``0x52``
#: (50 % damage) is deliberately absent: the resolver has a case for it and
#: nothing reaches it -- see the closed items at the end of docs/22 12.
EXPECTED_WRITTEN_MARKERS = {0x50, 0x51, 0x53, 0x54, 0x55}

#: The distance rule at `0x0046A34E`: two adjacent cells more than this far
#: apart vertically count as further than one field.
HEIGHT_STEP = 2400

# --- Options\Game.opt (docs/20 7.6) -----------------------------------------

#: `aSaveOptions` / `aLoadOptions` transfer this many bytes from this address.
#: Both compile to `push 0x6C; push 0x005129D8`, which is what pins the file to
#: a single `.data` block.
OPT_BLOB = 0x005129D8
OPT_SIZE = 0x6C
OPT_IO = (0x004602E0, 0x00460390)

#: `jmp dword [ebx*4 + 0x00460EAC]` in the options screen's help-line switch:
#: row index -> a `push <textId>` stub.  The ids name the fields, and the row
#: order is the same one `0x00460520` hit-tests.
OPT_INIT = (0x004600AC, 0x004601C8)
"""The straight-line block in ``aInitOptions`` that installs the defaults."""
EXPECTED_OPT_DEFAULTS = {0x00: 1, 0x04: 25000, 0x08: 0, 0x0C: -512, 0x10: -512,
                         0x14: -512, 0x18: 0, 0x1C: 1, 0x20: 2, 0x24: 2,
                         0x28: 3}
"""docs/20 7.6.  ``+0x2C`` is the 64-byte player name, copied not stored."""
OPT_NAME_FIELD = 0x005129D8 + 0x2C
OPT_DEAD_FIELDS = (0x005129E0, 0x005129E8)
"""``+0x08`` and ``+0x10``: written by aInitOptions and read nowhere."""
OPT_ROW_TABLE = 0x00460EAC
EXPECTED_OPT_ROWS = [50, 51, 52, 57, 55, 54, 56, 58]
#: Row 7 is `aiLevel`, `Game.opt +0x18`, help line 58 "Set Difficulty Level ...".
OPT_DIFFICULTY_ROW = 7

# --- docs/21 6: the close-combat swap ---------------------------------------

#: ``aWeaponSpecial`` -- the weapon ``special`` dispatcher ``aAttackUnit``
#: calls three times.  The phase is its fourth argument, pushed first.
WEAPON_SPECIAL = 0x0046F7E0
#: ``(call site, phase, the byte pushed at the site)``.  Phase 0 runs before
#: the shot, phase 2 on each unit it hit, phase 1 at the very end -- **after**
#: the ammunition subtraction, which is why a bayonet's ``mun`` of 255 is what
#: the subtraction reads and no round is spent.
WEAPON_SPECIAL_CALLS = {0x0046B5C7: 0, 0x0046BE1C: 2, 0x0046C325: 1}
#: The gates in front of the two close-combat phases: both read
#: ``aAttackUnit``'s fifth argument -- the flag [`25` 6]'s reaction drain
#: passes as 1 -- and jump past the call.  ``mov eax, [esp+0x84] / test eax,
#: eax / jne``.
WEAPON_SPECIAL_REACTION_GATES = {
    0x0046B581: b"\x8b\x84\x24\x84\x00\x00\x00",
    0x0046C310: b"\x8b\x84\x24\x84\x00\x00\x00",
}
#: The ammunition subtraction, and the phase-1 call that follows it: the two
#: are 0x23 bytes apart and in that order.
AMMO_SUBTRACT = 0x0046C302
#: ``aPlayFightAnimation`` and ``aAttackUnit``'s call to it.  The call is
#: **inside** the routine, between the close-combat swap and the revert, so
#: everything the animation dispatches on a weapon id takes the *bayonet's*
#: arm during a stab -- the `F` clip `P0_F1_001`, the wave ``W_BAYO_0`` and
#: the muzzle switch (docs/21 6, docs/42 4).
FIGHT_ANIMATION = 0x0040BD70
FIGHT_ANIMATION_CALL = 0x0046C186
#: ``cmp cl, 0x1E`` / ``0x1F`` / ``0x20`` at ``0x0046F8E8`` -- the three ids
#: the revert arm accepts, read out of its own comparisons.
CLOSE_COMBAT_REVERT_TEST = 0x0046F8E8
CLOSE_COMBAT_WEAPONS = (0x1E, 0x1F, 0x20)
#: ``cmp eax, 1`` at ``0x0046FA1B`` -- the distance, after a field is taken
#: off for each large participant.
CLOSE_COMBAT_DISTANCE_TEST = 0x0046FA1B
#: ``cmp edx, 0x10`` at ``0x0046FAAC`` -- the height gate, over the reciprocal
#: multiply ``0x66666667`` with ``sar edx, 6``, which is a truncating divide
#: by 160.
CLOSE_COMBAT_HEIGHT_TEST = 0x0046FAAC
CLOSE_COMBAT_HEIGHT_MAGIC = 0x66666667
CLOSE_COMBAT_HEIGHT_MAGIC_AT = 0x0046FA98
CLOSE_COMBAT_HEIGHT_SHIFT = 6
CLOSE_COMBAT_HEIGHT_SHIFT_AT = 0x0046FAA2
CLOSE_COMBAT_HEIGHT_LEVELS = 0x10
#: ``mov al, byte [ebx + 0x51B2FB]`` at ``0x0046F823`` -- the dispatcher's
#: own read of the ``special`` column, and ``mov dl, byte [ebx + 0x51B2FF]``
#: at ``0x0046FAB1``, the swap's write of ``param``.  Both are indexed by
#: ``67 * weapon id``, the record's size.
SPECIAL_COLUMN_READ = 0x0046F825
PARAM_COLUMN_WRITE = 0x0046FAB3
#: The weapon record's base, so ``special`` (+0x3B) and ``param`` (+0x3F) can
#: be read back out of the arm's own displacements.
WEAPON_TABLE_BASE = 0x0051B2C0


# --- provably private globals -----------------------------------------------

#: `unitType[+0x07]`, the `special` column.  Every site that reads it, so that
#: a new consumer appearing in a re-analysis is a failure rather than a silent
#: gap.  docs/21 5 tabulates what each one does.
SPECIAL_COLUMN = 0x0051C027
EXPECTED_SPECIAL_SITES = {
    0x0040DB17, 0x0040DCCF,     # aPlayFightAnimation: death animations 12/13/16
    0x00430A64, 0x00430E5F,     # aBuildMoveMap: 1 and 14 immobile, 15 warps
    0x004416BB,                 # the SetUnitInfo handler -- the only writer
    0x0046BBA6, 0x0046BC2E, 0x0046BE6C,   # aAttackUnit: 10, 12, 13, 16
    0x0046F255,                 # the special hook itself
    0x004703EE,                 # aExecuteBomb: 12
    0x004753A9,                 # the warp-range accessor
}

#: The two explosive-object resolvers.  ``aAttackUnit`` has Bea'Coo's
#: type-2 vulnerability; ``aExecuteBomb`` has no hit roll, starts at 30 damage
#: and gives ``special`` 12 literal 1000 before applyDamage narrows it to u8.
BEACOO_TYPE_TEST = 0x0046BBD4
BEACOO_WEAPON_TYPE_TEST = 0x0046BBE5
BEACOO_DAMAGE_WRITE = 0x0046BBEF
EXECUTE_BOMB = 0x004702C0
EXECUTE_BOMB_END = 0x004705E6
BOMB_BASE_DAMAGE = 0x004703D3
BOMB_SPECIAL_DAMAGE = 0x0047041D
RANDOM = 0x00463870

#: The two damage resolvers are cell-array sweeps, not queues of target
#: records.  These instruction blocks pin the marker band, the 23-byte cell
#: stride, and the conditional jump back to the head after a complete pass.
#: That distinction is observable when two explosive rings overlap: the first
#: CtrlMap byte survives for the shared cell, then a requested repeat sweeps
#: newly marked earlier cells.
RESOLVER_SWEEPS = (
    (0x0046B9B6, "8a013c500f826f0600003c590f8767060000",
     "aAttackUnit reads cell[0] and accepts only markers 0x50..0x59"),
    (0x0046C033, "83c717",
     "aAttackUnit advances one 23-byte CtrlMap cell"),
    (0x0046C054,
     "8b4c24308b4424344185c0894c24300f84e1000000e924f9ffff",
     "aAttackUnit tests the repeat flag and jumps back to the sweep head"),
    (0x0047033E, "8a033c500f82eb0100003c590f87e3010000",
     "aExecuteBomb reads cell[0] and accepts only markers 0x50..0x59"),
    (0x00470537, "83c317",
     "aExecuteBomb advances one 23-byte CtrlMap cell"),
    (0x0047054C,
     "8b4c2418413bfd894c24180f8489000000e9c2fdffff",
     "aExecuteBomb tests the repeat condition and jumps back to the sweep head"),
)

#: Killed units still occupy their CtrlMap cells while the fight animation
#: walks its marker bands.  Each routine has exactly one removal call in this
#: tail, and it follows the animation call.
REMOVE_UNIT_ELEMENT = 0x004779C0
ATTACK_REMOVE_CALL = 0x0046C1F9
BOMB_FIGHT_ANIMATION_CALL = 0x004705F5
BOMB_REMOVE_CALL = 0x0047063F

#: `aPlayFightAnimation` rebuilds its result arrays from the completed CtrlMap
#: before the voice and death switches consume them.  This is why presentation
#: order is row-major even when an earlier cell was discovered on a repeat.
PRESENTATION_RESULT_SWEEP = (
    (0x0040C519, "e8323102008bf8895c2414e837310200",
     "load the CtrlMap base and its cell count"),
    (0x0040C549, "8a073c5a0f82340200003c5d0f872c020000",
     "accept final markers 0x5A..0x5D"),
    (0x0040C569, "8a5709889054be4f008a4f0a888872be4f00",
     "append the cell x/y to the presentation arrays"),
    (0x0040C787,
     "8b54241483c7174289542414e8c82e0200394424140f8ca7fdffff",
     "advance by 23 bytes and loop over the whole CtrlMap"),
)

#: ``docs/22`` §9.4 -- ``aBuildVisibleMap``, and the pair that brackets the
#: **probes**.  Nineteen call sites, each verified by disassembling it: only
#: four sit inside a `save; build; look; restore` bracket, and the other
#: fifteen change the fog for good.  radare2's ``axt`` after ``aa`` reports
#: only eight of them -- it misses every site in a function its analysis did
#: not reach -- which is why this check sweeps the whole ``.text`` for the
#: encoded ``call`` instead, and why it compares an exact set: a twentieth hit
#: is a failure, not a silent addition.
BUILD_VISIBLE_MAP = 0x004798C0
SAVE_VISIBILITY = 0x00479AA0
RESTORE_VISIBILITY = 0x00479AC0
#: ``address -> (enclosing routine, the player it rebuilds for)``.
EXPECTED_FOG_SITES = {
    # -- permanent -------------------------------------------------------
    0x0040D6BD,   # aPlayFightAnimation, aAnimations.cpp:2752 -- current
    0x00410C6A,   # aDoorOpenSequence -- the door opens; current, not 0xFF
    0x00410D60,   # aDoorOpenSequence -- the door closes; current, not 0xFF
    0x00412905,   # aPlayElevatorSequence, cpp:8215 -- the rider's player
    0x004130E6,   # aPlayPlatformSequence, cpp:8694 -- the rider's player
    0x004149C7,   # the spore hatch 0x004147D0, cpp:10602 -- literal player 0
    0x004419B6,   # the InsertUnit handler -- current
    0x00441F55,   # the BuildVisibleMap command -- current
    0x004490A9,   # aLoad.cpp:1649 -- current
    0x00457926,   # the mission-control GUI build -- current
    0x0046F144,   # aExecuteWarp -- the warping unit's own player
    0x0046F3A8,   # 0x0046F210 case 4, `special` 9 -- current
    0x004781C6,   # refreshCurrentPlayer, aUnitMap.cpp:1240 -- its argument
    0x00478DE4,   # aTransferUnitFromPoolToMap -- current
    0x0047DCCF,   # aNextPlayerHandling -- literal 0, under game mode 1
    # -- probes: bracketed by the save/restore pair ----------------------
    0x0047CBED,   # aViewPlayer.cpp:1051 -- the own player
    0x0047CF8B,   # aViewPlayer.cpp:992  -- the own player
    0x0047CFB5,   # aViewPlayer.cpp:998  -- 0x0043B2D0
    0x00481FE3,   # lNetwork.cpp:1461    -- the per-command probe
}
EXPECTED_SAVE_SITES = {0x0047CBD2, 0x0047CF5D, 0x00481F05}
EXPECTED_RESTORE_SITES = {
    0x0047CEA5, 0x0047D011,
    0x00481F49, 0x00481F87, 0x00481FB4, 0x00481FD2,
}
#: The two door arms, and the guard both carry.  ``ebx`` is -100 on the arm
#: that opens the panel and +100 on the one that closes it, so the two
#: conditional jumps are opposites; each is followed by the 0xFF test.
DOOR_ARMS = (
    (0x00410B8B, "bb9cffffff", "mov ebx, -100 -- the door opens"),
    (0x00410BAE, "bb64000000", "mov ebx, 100 -- the door closes"),
    (0x00410C52, "85db7d1c", "test ebx,ebx / jge -- only the opening arm"),
    (0x00410D48, "85db7e1c", "test ebx,ebx / jle -- only the closing arm"),
    (0x00410C5B, "3cff", "cmp al, 0xff -- not during the computer's turn"),
    (0x00410D51, "3cff", "cmp al, 0xff -- not during the computer's turn"),
)

#: ``docs/21`` §5's ``special`` 9, byte for byte out of ``0x0046F210``'s
#: ``case 4``.  Each entry is ``(virtual address, bytes, what it is)``.
HATCH_ARM = (
    (0x0046F279, "80fa09", "cmp dl, 9 -- the special enumerator"),
    (0x0046F282, "807e1605", "cmp byte [esi+0x16], 5 -- the hit-point bound"),
    (0x0046F2A3, "3c01", "cmp al, 1 -- weapon type"),
    (0x0046F2A7, "3c02", "cmp al, 2 -- weapon type"),
    (0x0046F2AB, "3c04", "cmp al, 4 -- weapon type"),
    (0x0046F2B3, "8a4642", "mov al, byte [esi+0x42] -- the carrier's x"),
    (0x0046F2B6, "8a4e43", "mov cl, byte [esi+0x43] -- the carrier's y"),
    (0x0046F2F6, "8a5e4e", "mov bl, byte [esi+0x4e] -- the AI group"),
    (0x0046F32B, "6a01", "push 1 -- aGenerateUnitElement's `exact` flag"),
    (0x0046F338, "6a36", "push 0x36 -- the replacement unit type"),
    (0x0046F33A, "68ff000000", "push 0xff -- the replacement's player"),
    (0x0046F39A, "88584e", "mov byte [eax+0x4e], bl -- the group is inherited"),
)
#: The two calls the arm makes after it has rewritten the roster.
HATCH_CURRENT_PLAYER_CALL = (0x0046F39D, 0x0043B2C0)
HATCH_FOG_CALL = (0x0046F3A8, BUILD_VISIBLE_MAP)

#: The **other ten** permanent rebuilds -- ``docs/22`` §9.4's table, with the
#: player argument each one passes pinned byte for byte.  The instruction just
#: before the ``call`` is what decides *whose* fog moves, and three of the ten
#: do not pass the current player at all.
FOG_ARGUMENTS = (
    (0x0040D67A, "e841dc0200",
     "aPlayFightAnimation's Spidy arm: call aGetCurrentPlayer for the spawn"),
    (0x0040D6B2, "e809dc0200",
     "and again for the rebuild -- the current player"),
    (0x00412901, "8a4845",
     "aPlayElevatorSequence: mov cl, byte [eax+0x45] -- the *rider's* player"),
    (0x004128fd, "7433",
     "je -- and nothing is rebuilt when the elevator tile is empty"),
    (0x004130E2, "8a5045",
     "aPlayPlatformSequence: mov dl, byte [eax+0x45] -- and `eax` is the unit "
     "0x00471F70 named, which is the *selected* unit, not the rider"),
    (0x00413098, "e8d3ee0500",
     "call 0x00471F70 -- the interface's own selection, from 0x005162F8"),
    (0x004149C5, "6a00",
     "the spore hatch 0x004147D0 (§9.4.3, *not* aPlayStatueSequence): push 0 "
     "-- a literal player, not the current one"),
    (0x004149B1, "68ff000000",
     "and the unit it spawns first is a neutral (player 0xFF)"),
    (0x0044909E, "e81d22ffff",
     "aLoad.cpp:1649: call aGetCurrentPlayer"),
    (0x0045791B, "e8a039feff",
     "aMissionControl's GUI build: call aGetCurrentPlayer, not the own player"),
    (0x0046F140, "8a5645",
     "aExecuteWarp: mov dl, byte [esi+0x45] -- the warping unit's own player"),
    (0x0046F133, "8a4616",
     "guarded by the unit's +0x16 being non-zero"),
    (0x004781C0, "558b6c240855",
     "0x004781C0 is a forwarder: push ebp; call aBuildVisibleMap(arg)"),
    (0x00478DD9, "e8e224fcff",
     "aTransferUnitFromPoolToMap: call aGetCurrentPlayer"),
    (0x0047DCAC, "a1d0295200",
     "aNextPlayerHandling: mov eax, [0x005229D0] -- the one-shot latch"),
    (0x0047DCC4, "e877dafbff",
     "call 0x0043B740, the game-mode getter"),
    (0x0047DCC9, "3bc3", "cmp eax, ebx -- ebx is 1, i.e. a campaign"),
    (0x0047DCCD, "6a00", "push 0 -- a literal player 0"),
)

#: ``docs/22`` §7.5 -- the kill award, byte for byte: the three routines
#: ``0x0047AFD0`` / ``0x0047B090`` / ``0x0047B100``, the counter
#: ``0x0047AF90``, and their one caller in ``aAttackUnit``.  ``inclib.combat``
#: transcribes them; this is what keeps the transcription honest without a
#: capture, and the campaign arm is measured by ``turn_gold.py``'s
#: ``experience`` phase besides.
EXPERIENCE_SITES = (
    # 0x0047AFD0 -- experience_gain
    (0x0047AFD2, "e86907fcff", "call 0x0043B740, the game-mode getter"),
    (0x0047AFD7, "83f801", "cmp eax, 1 -- the campaign returns exp unchanged"),
    (0x0047AFE0, "25ff000000", "and eax, 0xFF -- the exp byte"),
    (0x0047AFF0, "be02000000", "mov esi, 2 -- the default multiplier"),
    (0x0047AFF5, "e85654feff", "call 0x00460450, aiLevel()"),
    (0x0047B005, "be01000000", "mov esi, 1 -- difficulty 2"),
    (0x0047B00C, "be03000000", "mov esi, 3 -- difficulty 1"),
    (0x0047B013, "be04000000", "mov esi, 4 -- difficulty 0"),
    (0x0047B032, "8a4217", "mov al, [edx+0x17] -- the attacker's experience"),
    (0x0047B035, "83f848", "cmp eax, 0x48 -- the 72 band"),
    (0x0047B045, "b8398ee338", "mov eax, 0x38E38E39 -- a divide by 72"),
    (0x0047B04C, "c1fa04", "sar edx, 4 -- the shift of that divide"),
    (0x0047B067, "83f86c", "cmp eax, 0x6C -- the 108 band"),
    (0x0047B06C, "80f901", "cmp cl, 1 -- the argument byte, not the unit"),
    (0x0047B073, "d90538164b00", "fld [0x004B1638] -- 0.0 for exp 1 above 108"),
    (0x0047B07C, "d80d3c164b00", "fmul [0x004B163C] -- 0.5 above 108"),
    # 0x0047B090 -- award_training
    (0x0047B0A5, "8a4e17", "mov cl, [esi+0x17] -- ep before the award"),
    (0x0047B0B2, "d81d40164b00", "fcomp [0x004B1640] -- ep + gain against 144"),
    (0x0047B0CA, "8a5618", "mov dl, [esi+0x18] -- the pool"),
    (0x0047B0E4, "c6461890", "mov byte [esi+0x18], 0x90 -- the pool capped"),
    (0x0047B0F4, "884618", "mov [esi+0x18], al -- the pool plus the gain"),
    # 0x0047B100 -- award_experience
    (0x0047B120, "d81540164b00", "fcom [0x004B1640] -- ep + gain against 144"),
    (0x0047B12F, "c6461790", "mov byte [esi+0x17], 0x90 -- ep capped"),
    (0x0047B13F, "884617", "mov [esi+0x17], al -- ep plus the gain"),
    # 0x0047AF90 -- count_kill
    (0x0047AF9A, "8a4a53", "mov cl, [edx+0x53] -- the kill counter"),
    (0x0047AFAF, "81feff000000", "cmp esi, 0xFF -- saturation"),
    (0x0047AFB7, "c64253ff", "mov byte [edx+0x53], 0xFF"),
    # aAttackUnit's kill block
    (0x0046B588, "8a5618", "mov dl, [esi+0x18] -- the pool saved at entry"),
    (0x0046BF47, "85ed", "test ebp, ebp -- the damage argument gates the award"),
    (0x0046BF4D, "0f8edc000000", "jle -- no award without damage"),
    (0x0046BF5F, "803c4d99c0510002", "cmp byte [ecx*2+0x51C099], 2 -- species 2"),
    (0x0046BF7C, "3ad0", "cmp dl, al -- the victim's player against the shooter's"),
    (0x0046BFA2, "8a144d9ac05100", "mov dl, [ecx*2+0x51C09A] -- the victim type's exp"),
    (0x0046BFAB, "e820f00000", "call 0x0047AFD0"),
    (0x0046BFB3, "e8fe270400", "call _ftol -- the gain truncated into the total"),
    (0x0046BFD7, "e8b4f00000", "call 0x0047B090"),
    (0x0046BFF4, "e807f10000", "call 0x0047B100"),
    (0x0046BFFC, "6a01", "push 1 -- one kill"),
    (0x0046BFFF, "e88cef0000", "call 0x0047AF90"),
    # the skill orbit's gate, after the animation
    (0x0046C216, "8a4616", "mov al, [esi+0x16] -- the attacker still alive"),
    (0x0046C223, "b8abaaaa2a", "mov eax, 0x2AAAAAAB -- a divide by 12"),
    (0x0046C228, "8a4e18", "mov cl, [esi+0x18] -- the pool after"),
    (0x0046C254, "7d35", "jge -- no orbit unless the level rose"),
    (0x0046C262, "8a044d99c05100", "mov al, [ecx*2+0x51C099] -- the attacker's species"),
    (0x0046C26B, "751e", "jne -- species 0 only"),
    (0x0046C283, "e8083ffaff", "call 0x00410190, the skill orbit"),
)
#: The three single-precision constants the award reads.
EXPERIENCE_FLOATS = ((0x004B1638, 0.0), (0x004B163C, 0.5), (0x004B1640, 144.0))

#: ``0x0043BA00`` -- the player record: ``lea eax,[eax+eax*4]`` then
#: ``lea eax,[eax*8 + 0x00509F48]``, i.e. base ``0x00509F48`` and stride 40.
#: ``0x0043B770``'s loop runs its pointer at ``record + 8`` -- it starts at
#: ``0x00509F50`` and its first store is ``[eax-8]`` -- so the bound
#: ``0x00509FF0`` is ``0x00509F48 + 40*4 + 8`` and the **last** store is the
#: hero counter of ``docs/22`` §9.5, cleared at the width it is incremented.
PLAYER_RECORD = (
    (0x0043BA04, "8d0480", "lea eax, [eax + eax*4]"),
    (0x0043BA07, "8d04c5489f5000", "lea eax, [eax*8 + 0x00509F48]"),
    (0x0043B772, "b8509f5000", "mov eax, 0x00509F50 -- the record plus 8"),
    (0x0043B77E, "8958f8", "mov [eax-8], ebx -- record +0x00"),
    (0x0043B789, "897018", "mov [eax+0x18], esi -- record +0x20 = 1"),
    (0x0043B78C, "88581c", "mov byte [eax+0x1c], bl -- record +0x24 = 0"),
    (0x0043B78F, "83c028", "add eax, 0x28 -- a stride of 40"),
    (0x0043B792, "3df09f5000", "cmp eax, 0x00509FF0 -- four records of 40"),
)
#: The one-shot latch is **in a save block**: both sides transfer 0x44C bytes
#: from ``0x005229D0``.  ``0x0047BCD0`` is the two-instruction reset.
VIEW_PLAYER_BLOCK = (
    (0x0047DBE4, "684c04000068d0295200",
     "aSaveViewPlayer: push 0x44C; push 0x005229D0"),
    (0x0047DC24, "684c04000068d0295200",
     "aLoadViewPlayer: push 0x44C; push 0x005229D0"),
    (0x0047BCD0, "c705d0295200000000 00".replace(" ", ""),
     "mov dword [0x005229D0], 0 -- the new-mission reset"),
)

#: ``docs/22`` §9.5 -- the hero counter inside ``aRemoveUnitElement``, and the
#: predicate that reads it.  These twelve bytes are the whole mechanic.
HERO_COUNTER = (
    (0x00477A34, "8a44514d",
     "mov al, byte [ecx+edx*2+0x4d] -- the removed unit's +0x4D"),
    (0x00477A3B, "3c02", "cmp al, 2 -- 'hero'"),
    (0x00477A3D, "7221", "jb -- below 2 skips the whole block"),
    (0x00477A44, "84c0", "test al, al -- the turn counter"),
    (0x00477A46, "7618", "jbe -- turn 0 does not count"),
    (0x00477A4A, "8a5645", "mov dl, byte [esi+0x45] -- the unit's player"),
    (0x00477A53, "8a4824", "mov cl, byte [eax+0x24] -- the counter"),
    (0x00477A56, "83c024", "add eax, 0x24"),
    (0x00477A5C, "fec1", "inc cl -- one byte, so it wraps at 256"),
    (0x00477A5E, "8808", "mov byte [eax], cl"),
    (0x004409EB, "8a5024", "HeroKilled: mov dl, byte [eax+0x24]"),
    (0x004409F5, "0f95c1", "setne cl -- it answers non-zero, not the count"),
)
#: The two calls the counter makes, and the one call site of the predicate.
HERO_COUNTER_CALLS = (
    (0x00477A3F, 0x0043B280, "the turn-counter getter"),
    (0x00477A4E, 0x0043BA00, "the player record"),
    (0x004409E6, 0x0043BA00, "HeroKilled's own record lookup"),
)
#: ``0x00444BA3`` is the only caller of the predicate, and the string compared
#: immediately before it is the command's name.
HERO_KILLED_NAME = (0x004409E0, 0x00444BA3, 0x004C5818, b"HeroKilled\x00")

#: ``aPlayFightAnimation``'s impact switch -- ``docs/28`` §8.1.  The key is the
#: attacker's **weapon id**, biased by 7; the byte table selects the arm.
IMPACT_INDEX_TABLE = 0x0040E614
IMPACT_JUMP_TABLE = 0x0040E5D4
IMPACT_KEY_BIAS = 7
#: The arm that spawns a unit instead of a blob, and what it spawns.
SPIDY_WEAPON = 46
SPIDY_ARM = 0x0040D65C
SPIDY_SPAWN = (
    (0x0040D678, "6a18", "push 0x18 -- unit type 24, `Spider`"),
    (0x0040D673, "68080f4c00", "push \"Spidy\" -- the name it is given"),
    (0x0040D66F, "6a00", "push 0 -- rank"),
    (0x0040D671, "6a00", "push 0 -- pool flag"),
)

#: ``docs/22`` §9.4.3 -- the routine that owns the ``0x004149C7`` rebuild.  It
#: is **not** ``aPlayStatueSequence``.  That routine is ``0x00414000``, and it
#: ends at ``0x00414346`` with its own jump table at ``0x00414348``; the spawn
#: and the rebuild belong to ``0x004147D0``, the spore hatch
#: (``msqueether.wav``, ``docs/28`` §2).  No ``CHECK`` names it, so it is
#: identified by what calls it rather than by a symbol.
GENERATE_UNIT_ELEMENT = 0x00479CF0
SPORE_HATCH = 0x004147D0
SPORE_HATCH_CALLERS = frozenset({0x0046FC66, 0x0046FE18})
#: Its frame is ``0x24`` of locals plus **three** saved registers, so the
#: settled esp is ``ret - 0x30`` and the arguments sit at ``+0x34``, ``+0x38``
#: and ``+0x3C``.  Both epilogues free exactly ``0x30``, and that is what says
#: this is not the routine starting at ``0x00414000``, whose prologue is
#: ``0x28`` plus **four** pushes.  ``aGetCtrlMapElementPtr(arg1, arg2)`` then
#: fixes arguments 1 and 2 as ``(x, y)``.
SPORE_HATCH_FRAME = (
    (0x004147D0, "83ec24", "sub esp, 0x24"),
    (0x004147D3, "555657", "push ebp; push esi; push edi -- three, not four"),
    (0x00414826, "5f5e5d83c424c3", "the early epilogue frees 0x0c + 0x24"),
    (0x00414A5E, "5f5eb8010000005d83c424c3", "and so does the tail one"),
    (0x004147F5, "8b442438", "mov eax, [esp+0x38] -- argument 2"),
    (0x004147F9, "8b4c2434", "mov ecx, [esp+0x34] -- argument 1"),
    (0x004147FF, "e82caf0100", "call aGetCtrlMapElementPtr(arg1, arg2) = (x, y)"),
    (0x00414000, "83ec28", "aPlayStatueSequence, for contrast: sub esp, 0x28"),
    (0x00414003, "53555657", "push ebx; push ebp; push esi; push edi -- four"),
    (0x0041408B, "83c428c3", "and its epilogue frees 0x10 + 0x28"),
)
#: The spawn itself.  ``[esp+0x40]`` at ``0x0041499F`` has exactly one push in
#: flight, so it reads ``base + 0x3C``: **argument 3**.  The nine arguments and
#: their order are the same as the Spidy site's, where ``push 0x18`` pins
#: argument 2 as the unit type.
SPORE_SPAWN = (
    (0x0041499E, "52", "push edx -- the ninth argument, a local"),
    (0x0041499F, "8b542440", "mov edx, [esp+0x40] -- base+0x3C, argument 3"),
    (0x004149AB, "6824a54f00", "push 0x004FA524 -- the shared name buffer"),
    (0x004149B0, "52", "push edx -- argument 2: the unit type"),
    (0x004149B1, "68ff000000", "push 0xff -- argument 1: the player"),
    (0x004149BD, "e82e530600", "call aGenerateUnitElement"),
    (0x004149C2, "83c424", "add esp, 0x24 -- nine cdecl arguments"),
    (0x0040D68A, "83c424", "the Spidy site cleans the same nine"),
)
#: ``Spores``' arm: the type comes straight from the script's third numeric
#: argument, ``num[2]`` at ``0x0050BF00`` (``docs/20`` §3.2).
SPORES_ARM = (
    (0x00441FF0, "a100bf5000", "the Spores handler: mov eax, [0x0050BF00]"),
    (0x00441FF5, "8a0dfcbe5000", "mov cl, [0x0050BEFC] -- num[1]"),
    (0x00441FFB, "8a15f8be5000", "mov dl, [0x0050BEF8] -- num[0]"),
    (0x00442004, "e827dc0200", "call 0x0046FC30 with (num[0], num[1], num[2])"),
    (0x0046FC51, "8a06", "the sweep: mov al, byte [esi] -- the cell's +0x0B"),
    (0x0046FC53, "3ac3", "cmp al, bl -- against num[0]"),
    (0x0046FC57, "3a442418", "cmp al, byte [esp+0x18] -- and against num[1]"),
    (0x0046FC63, "55", "push ebp -- the third argument, straight through"),
    (0x0046FC64, "50", "push eax -- [esi+0x0A], the cell's y"),
    (0x0046FC65, "51", "push ecx -- [esi+0x09], its x"),
    (0x0046FC66, "e8654bfaff", "call 0x004147D0"),
    (0x0046FC6E, "83c617", "add esi, 0x17 -- a CtrlMap cell is 23 bytes"),
)
#: ``MoveSpores``' arm of ``0x0046FC90`` is the one path where the type is a
#: constant: 50, ``Ray'Ther`` in ``Info.lcl``'s ``SetUnitInfo`` table.  The
#: three ``Move*`` commands are one routine with kind 0, 1 and 2, and only kind
#: 2 reaches the spore hatch.
MOVE_SPORES_TYPE = 50
MOVE_SPORES_ARM = (
    (0x0044253B, "6a00", "MoveObjects pushes kind 0"),
    (0x0044255B, "6a01", "MoveFireCircles pushes kind 1"),
    (0x0044257B, "6a02", "MoveSpores pushes kind 2"),
    (0x0046FE03, "83e800", "sub eax, 0 -- kind 0 falls straight through"),
    (0x0046FE08, "48", "dec eax -- kind 1"),
    (0x0046FE0B, "48", "dec eax -- kind 2"),
    (0x0046FE14, "6a32", "push 0x32 -- unit type 50"),
    (0x0046FE16, "50", "push eax -- [edi+0x0A], the destination cell's y"),
    (0x0046FE17, "51", "push ecx -- [edi+0x09], its x"),
    (0x0046FE18, "e8b349faff", "call 0x004147D0"),
    (0x0046FE2A, "e89133faff", "kind 1 calls 0x004131C0, the fire circle"),
)
#: The LCL dispatcher's ``mov eax, <name>`` sits exactly ``0x36`` bytes before
#: the ``call`` its comparison guards, so the pairing is mechanical rather than
#: read off by eye.
DISPATCH_STRIDE = 0x36
SPORE_DISPATCH = (
    (0x00444649, 0x00441FF0, 0x004C5348, b"Spores\x00"),
    (0x00443C71, 0x00442530, 0x004C5524, b"MoveObjects\x00"),
    (0x00443CB7, 0x00442550, 0x004C5514, b"MoveFireCircles\x00"),
    (0x00443CFD, 0x00442570, 0x004C5508, b"MoveSpores\x00"),
    (0x004432D7, 0x00442370, 0x004C5710, b"FixedStatue\x00"),
)
#: ``FixedStatue``'s own routine, for contrast: it spawns nothing and rebuilds
#: no fog.  What it *does* call is ``aRemoveUnitElement`` -- it petrifies a
#: unit, which is why §9.5's counter is in its call graph and a spawn is not.
STATUE_BODY = (0x00414000, 0x00414347)
STATUE_MUST_NOT_CALL = (GENERATE_UNIT_ELEMENT, BUILD_VISIBLE_MAP)
STATUE_MUST_CALL = 0x004779C0
#: The three unit types the two paths can hatch, as ``Info.lcl`` names them.
SPORE_UNIT_NAMES = {50: "Ray'Ther", 65: "Bea'Ther", 66: "Bea'Coo"}
#: What the corpus holds: three ``Spores`` calls, all in one mission, and not a
#: single use of the ``Move*`` trio.
SPORES_CORPUS_CALLS = (
    ("_C_174.lcl", (100, 102, 66)),
    ("_C_174.lcl", (120, 121, 66)),
    ("_C_174.lcl", (120, 121, 65)),
)
SPORES_CORPUS_UNUSED = ("MoveObjects", "MoveFireCircles", "MoveSpores")

#: The RNG's four globals and the address span of `aRandomize` + `aRandom`.
#: Every reference must fall inside that span -- that is what makes the two
#: instrumentation counters *provably* unread rather than merely unexplained.
RNG_GLOBALS = {
    "Incubation.exe": ((0x00514078, 0x0051407C, 0x00514080, 0x00514084),
                       (0x00463820, 0x004638D5)),
    "iDesigner.exe": ((0x004C4BE8, 0x004C4BEC, 0x004C4BF0, 0x004C4BF4),
                      (0x0042D980, 0x0042D9E5)),
}

WEAPON_COUNT = 48


# ---------------------------------------------------------------------------
# Static tables
# ---------------------------------------------------------------------------

class CombatTables:
    """Everything read straight out of ``Incubation.exe``."""

    def __init__(self, pe: PEFile) -> None:
        self.pe = pe
        self.aoe_index = [pe.u8(AOE_INDEX + i) for i in range(WEAPON_COUNT)]
        n_handlers = max(self.aoe_index) + 1
        self.aoe_jump = [pe.u32(AOE_JUMP + 4 * i) for i in range(n_handlers)]
        self.handler_of = {w: self.aoe_jump[self.aoe_index[w]]
                           for w in range(WEAPON_COUNT)}
        self.markers = self._markers()
        self.arcing = self._arcing()
        self.octants = {name: [self._const_return(pe.u32(base + 4 * i))
                               for i in range(8)]
                        for name, base in OCTANT_TABLES.items()}

    # -- the target-pattern handlers ----------------------------------------

    def _markers(self) -> dict[int, list[int]]:
        """``handler -> [marker, ...]`` in the order the handler writes them.

        A handler's extent is taken as the span up to the next handler entry,
        which is exact here because the compiler laid the switch bodies out in
        address order.  A marker reaches ``SET_CELL_STATE`` as its last
        argument, and arguments are pushed right to left, so it is the *first*
        of four pushes -- but how far ahead of the call that push sits varies:
        the weapon-13 handler loops eighteen times and calls ``aRandom`` twice
        for the coordinates in between, putting 54 bytes between the two.

        So the span is scanned for every ``push imm8`` in ``0x50..0x5F`` that
        precedes the last ``call SET_CELL_STATE`` in it, rather than for a
        push at a fixed distance.  A handler with no such call has no markers,
        which is how the error handler is recognised.
        """
        bounds = sorted(set(self.aoe_jump) | {AOE_FUNC_END})
        data = self.pe.data
        out: dict[int, list[int]] = {}
        for start, end in zip(bounds, bounds[1:]):
            lo = self.pe.va_to_off(start)
            hi = self.pe.va_to_off(end)
            if lo is None or hi is None:
                continue
            last_call = None
            i = lo
            while True:
                i = data.find(b"\xe8", i, hi)
                if i < 0:
                    break
                va = self.pe.off_to_va(i)
                if va is not None:
                    target = va + 5 + struct.unpack_from("<i", data, i + 1)[0]
                    if target == SET_CELL_STATE:
                        last_call = i
                i += 1
            markers: list[int] = []
            if last_call is not None:
                for q in range(lo, last_call):
                    if data[q] == 0x6A and 0x50 <= data[q + 1] <= 0x5F:
                        if data[q + 1] not in markers:
                            markers.append(data[q + 1])
            out[start] = markers
        return out

    def written_markers(self) -> dict[int, list[int]]:
        """``marker -> [call site, ...]`` over the **whole** ``.text`` section.

        The target-pattern handlers are not the only writers: the resolver and
        ``aExecuteBomb`` both stamp ``0x53`` on a victim's neighbours.  This
        sweep is what shows that ``0x52`` is never written at all.
        """
        _tva, _tvsize, traw, trawsize = self.pe.section(".text")
        data = self.pe.data
        out: dict[int, list[int]] = defaultdict(list)
        i = traw
        while True:
            i = data.find(b"\xe8", i, traw + trawsize)
            if i < 0:
                break
            va = self.pe.off_to_va(i)
            if va is not None:
                target = va + 5 + struct.unpack_from("<i", data, i + 1)[0]
                if target == SET_CELL_STATE:
                    for back in range(4, 80):
                        q = i - back
                        if q < traw:
                            break
                        if data[q] == 0x6A and 0x50 <= data[q + 1] <= 0x5F:
                            out[data[q + 1]].append(self.pe.off_to_va(q))
                            break
            i += 1
        return dict(out)

    @property
    def no_pattern_handler(self) -> int:
        """The handler shared by the weapon ids that have no pattern.

        It is the only one that writes no marker at all.
        """
        empty = [h for h in set(self.aoe_jump) if not self.markers.get(h)]
        if len(empty) != 1:
            raise PEError(f"expected exactly one marker-less handler, got {empty}")
        return empty[0]

    # -- the indirect-fire predicate ----------------------------------------

    def _arcing(self) -> set[int]:
        out = set()
        for weapon in range(WEAPON_COUNT):
            key = weapon - ARC_BIAS
            if not 0 <= key <= ARC_LIMIT:
                continue
            handler = self.pe.u32(ARC_JUMP + 4 * self.pe.u8(ARC_INDEX + key))
            if self._const_return(handler) == 1:
                out.add(weapon)
        return out

    def _const_return(self, va: int) -> int | None:
        """Decode ``mov eax, imm32; ret`` or ``xor eax, eax; ret`` at *va*."""
        head = self.pe.bytes_at(va, 6)
        if head[0] == 0xB8 and head[5] == 0xC3:
            return struct.unpack_from("<I", head, 1)[0]
        if head[:3] == b"\x33\xc0\xc3":
            return 0
        return None

    # -- constants -----------------------------------------------------------

    def constants(self) -> dict[str, float]:
        return {name: self.pe.f64(va) for name, (va, _want) in CONSTANTS.items()}

    # -- Game.opt ------------------------------------------------------------

    def option_io(self) -> list[tuple[int, int]]:
        """``(size, address)`` of each ``push size; push address`` in the two I/O
        routines.  Both must transfer the whole blob from the same place."""
        out = []
        for func in OPT_IO:
            off = self.pe.va_to_off(func)
            window = self.pe.data[off:off + 0x80]
            i = window.find(b"\x6a")
            while i >= 0:
                if window[i + 2] == 0x68:
                    out.append((window[i + 1],
                                struct.unpack_from("<I", window, i + 3)[0]))
                    break
                i = window.find(b"\x6a", i + 1)
        return out

    def option_defaults(self) -> dict[int, int]:
        """The blob offsets ``aInitOptions`` writes, and what it writes there.

        The block is straight-line code that loads a constant into a register
        and stores it several times, so the registers are tracked forward.  A
        store whose target is outside the blob is ignored.
        """
        lo, hi = OPT_INIT
        data = self.pe.data
        base = self.pe.va_to_off(lo)
        end = self.pe.va_to_off(hi)
        regs = {"eax": None, "esi": None, "ebp": None}
        stores = {"\xa3": "eax", "\x89\x35": "esi", "\x89\x2d": "ebp"}
        out: dict[int, int] = {}
        i = base
        while i < end:
            op = data[i]
            if op in (0xB8, 0xBE, 0xBD):
                name = {0xB8: "eax", 0xBE: "esi", 0xBD: "ebp"}[op]
                regs[name] = struct.unpack_from("<i", data, i + 1)[0]
                i += 5
                continue
            if op == 0x33 and data[i + 1] in (0xC0, 0xF6, 0xED):
                regs[{0xC0: "eax", 0xF6: "esi", 0xED: "ebp"}[data[i + 1]]] = 0
                i += 2
                continue
            if op == 0xC7 and data[i + 1] == 0x05:
                target = struct.unpack_from("<I", data, i + 2)[0]
                value = struct.unpack_from("<i", data, i + 6)[0]
                if OPT_BLOB <= target < OPT_BLOB + OPT_SIZE:
                    out[target - OPT_BLOB] = value
                i += 10
                continue
            for prefix, name in stores.items():
                raw = prefix.encode("latin-1")
                if data[i:i + len(raw)] == raw:
                    target = struct.unpack_from("<I", data, i + len(raw))[0]
                    if (OPT_BLOB <= target < OPT_BLOB + OPT_SIZE
                            and regs[name] is not None):
                        out[target - OPT_BLOB] = regs[name]
                    i += len(raw) + 4
                    break
            else:
                i += 1
        return out

    def option_rows(self) -> list[int | None]:
        """Help-line text id for each of the eight option rows, in row order."""
        out: list[int | None] = []
        for row in range(8):
            stub = self.pe.u32(OPT_ROW_TABLE + 4 * row)
            head = self.pe.bytes_at(stub, 2)
            out.append(head[1] if head[0] == 0x6A else None)
        return out

    # -- global reference sweeps --------------------------------------------

    def calls_to(self, address: int) -> set[int]:
        """Every ``.text`` site holding a near ``call`` to *address*.

        A plain byte sweep for ``E8`` plus the displacement that lands on the
        target.  It can in principle match a displacement that is really an
        operand, so the callers compare against a written-down set rather than
        counting: a spurious hit is then a failure and not a silent one.
        """
        _tva, _tvsize, traw, trawsize = self.pe.section(".text")
        data = self.pe.data
        out: set[int] = set()
        for i in range(traw, traw + trawsize - 5):
            if data[i] != 0xE8:
                continue
            rel = struct.unpack_from("<i", data, i + 1)[0]
            if self.pe.off_to_va(i) + 5 + rel == address:
                out.add(self.pe.off_to_va(i))
        return out

    def call_targets(self, lo: int, hi: int) -> set[int]:
        """Every near-``call`` target reached from the span ``[lo, hi)``.

        The same byte sweep as :meth:`calls_to`, run the other way round.  A
        displacement that is really an operand can add a target, so this is
        useful for asserting a call is **absent**: a spurious hit then fails
        the check rather than hiding one.
        """
        out: set[int] = set()
        for va in range(lo, hi - 4):
            if self.pe.u8(va) != 0xE8:
                continue
            out.add((va + 5 + self.pe.i32(va + 1)) & 0xFFFFFFFF)
        return out

    def image_refs_to(self, address: int) -> list[int]:
        """Every **file** offset holding *address* as a little-endian dword.

        :meth:`refs_to` sweeps ``.text`` only, which cannot see a dispatch
        table in ``.rdata`` or ``.data``.  A routine with no reference
        anywhere in the image is reachable only through the ``call`` sites
        :meth:`calls_to` finds -- which is what makes "reachable only from
        these two commands" a checked claim and not an assumption.
        """
        pattern = struct.pack("<I", address)
        data, out, i = self.pe.data, [], 0
        while True:
            i = data.find(pattern, i)
            if i < 0:
                return out
            out.append(i)
            i += 1

    def refs_to(self, address: int) -> list[int]:
        """Every ``.text`` site whose instruction stream embeds *address*."""
        _tva, _tvsize, traw, trawsize = self.pe.section(".text")
        data = self.pe.data
        pattern = struct.pack("<I", address)
        out, i = [], traw
        while True:
            i = data.find(pattern, i, traw + trawsize)
            if i < 0:
                return out
            out.append(self.pe.off_to_va(i))
            i += 1


# ---------------------------------------------------------------------------
# Derived arithmetic
# ---------------------------------------------------------------------------

class Random:
    """``aRandom`` (``0x00463870``) reimplemented from its own constants."""

    def __init__(self, multiplier: float, modulus: float, scale: float,
                 seed: float = 0.0) -> None:
        self.multiplier = multiplier
        self.modulus = modulus
        self.scale = scale
        self.seed = seed

    def __call__(self, base: int, span: int) -> int:
        self.seed = float(int(self.seed * self.multiplier) % int(self.modulus)) \
            if self.seed else 0.0
        return int(base + span * (self.seed * self.scale))


# `magic_div_2400_plus_1` and `hit_percent` moved into `inclib.combat`, where
# the executable model of docs/22 needs them too.  One definition, imported
# here rather than kept in both.


# ---------------------------------------------------------------------------
# Info.lcl
# ---------------------------------------------------------------------------

class Weapon:
    __slots__ = ("id", "name", "range_min", "range_max", "accuracy", "damage",
                 "type", "mun", "heat", "special", "toggle", "wave")

    def __init__(self, wid: int) -> None:
        self.id = wid
        self.name = ""
        self.wave = ""
        self.range_min = self.range_max = 0
        self.accuracy = self.damage = self.type = 0
        self.mun = self.heat = self.special = self.toggle = 0

    def to_dict(self) -> dict:
        return {k: getattr(self, k) for k in self.__slots__}


def load_weapons(root: str) -> dict[int, Weapon]:
    """Parse ``DATA/Info.lcl``'s ``SetWeaponInfo`` / ``SetWeaponInfo2`` tables."""
    path = None
    for dirpath, _dirs, files in os.walk(root):
        for fname in files:
            if fname.lower() == "info.lcl":
                path = os.path.join(dirpath, fname)
                break
        if path:
            break
    if path is None:
        raise LevError(f"no Info.lcl under {root!r}")
    program = lcl.parse_bytes(open(path, "rb").read(), path)

    def nums(stmt):
        return [a.value for a in stmt.args if a.kind == "number"]

    def strs(stmt):
        return [a.value for a in stmt.args if a.kind == "string"]

    out: dict[int, Weapon] = {}
    for stmt in program.statements():
        name = stmt.name
        if name == "SetWeaponInfo":
            n = nums(stmt)
            if len(n) < 18:
                continue
            w = out.setdefault(n[0], Weapon(n[0]))
            texts = strs(stmt)
            w.name = texts[0] if texts else ""
            (w.range_min, w.range_max, w.accuracy, w.damage) = n[1], n[2], n[3], n[4]
            w.type = n[11]
            w.mun, w.heat = n[13], n[14]
            w.special = n[16]
        elif name == "SetWeaponInfo2":
            n = nums(stmt)
            if len(n) < 4:
                continue
            w = out.setdefault(n[0], Weapon(n[0]))
            texts = strs(stmt)
            w.wave = texts[0] if texts else ""
            w.toggle = n[1]
            # `SetWeaponInfo2` copies strlen(wave)+1 bytes to +0x25 and the
            # next field starts at +0x2E, so a 9-character name zeroes
            # `range min`.  docs/21 lists the eight weapons this hits.
            if len(w.wave) == 9:
                w.range_min = 0
    return out


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

class Stats:
    """Accumulates pass/fail counters and failure messages."""

    def __init__(self) -> None:
        self.counters: dict[str, list[int]] = {}
        self.failures: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        passed, total = self.counters.setdefault(name, [0, 0])
        total += 1
        if ok:
            passed += 1
        else:
            self.failures.append(f"[{name}] {detail}")
        self.counters[name] = [passed, total]
        return ok

    def report(self) -> None:
        width = max((len(k) for k in self.counters), default=0)
        for name in sorted(self.counters):
            passed, total = self.counters[name]
            flag = "OK " if passed == total else "FAIL"
            print(f"  {flag} {name.ljust(width)}  {passed}/{total}")


def corpus_height_range(root: str) -> tuple[int, int, int]:
    """``(min, max, files)`` of cell heights over every ``.lev`` under *root*."""
    lo, hi, files = None, None, 0
    for dirpath, _dirs, names in os.walk(root):
        for fname in names:
            if not fname.lower().endswith(".lev"):
                continue
            try:
                battle = load_lev(os.path.join(dirpath, fname))
            except LevError:
                continue
            files += 1
            for cell in battle.cells:
                h = cell.height
                lo = h if lo is None or h < lo else lo
                hi = h if hi is None or h > hi else hi
    return (0 if lo is None else lo, 0 if hi is None else hi, files)


def corpus_weapon_ids(root: str) -> tuple[set[int], int, int]:
    """``(ids, placed units, files)`` over every ``.lev`` under *root*.

    The upper half of the weapon table is reachable only through the campaign
    armoury, which no ``.lev`` carries, so this is what says whether an arm
    keyed on a weapon id can fire from authored data at all.
    """
    ids: set[int] = set()
    placed = files = 0
    for dirpath, _dirs, names in os.walk(root):
        for fname in names:
            if not fname.lower().endswith(".lev"):
                continue
            try:
                battle = load_lev(os.path.join(dirpath, fname))
            except LevError:
                continue
            files += 1
            for unit in battle.units:
                if not unit.placed:
                    continue
                placed += 1
                ids.add(unit.weapon)
    return ids, placed, files


def corpus_actpt_family(root: str) -> tuple[dict[str, list], int]:
    """``(command -> [(file, numeric args), ...], scripts)`` over every script.

    ``docs/22`` §9.4.3's claim is about which *authored* data can reach the
    spore hatch, so it is answered by parsing the shipped scripts rather than
    by grepping them: an argument that is not a plain number would be a
    different claim, and the parser is what says so.
    """
    wanted = ("Spores",) + SPORES_CORPUS_UNUSED
    out: dict[str, list] = {name: [] for name in wanted}
    scripts = 0
    for dirpath, _dirs, names in os.walk(root):
        for fname in sorted(names):
            path = os.path.join(dirpath, fname)
            if not fname.lower().endswith(lcl.SCRIPT_EXTENSIONS):
                continue
            try:
                if not lcl.is_script(path):
                    continue
                program = lcl.parse_file(path)
            except (OSError, lcl.LclSyntaxError):
                continue
            scripts += 1
            for stmt in program.statements():
                if stmt.name not in out:
                    continue
                # A non-numeric argument is not skipped: it would make the
                # call invisible to a check whose claim is about *every*
                # shipped use, so it is recorded as its raw text instead.
                out[stmt.name].append(
                    (fname, tuple(a.value if a.kind == "number" else a.raw
                                  for a in stmt.args)))
    return out, scripts


def corpus_unit_names(root: str) -> dict[int, str]:
    """``id -> name`` from ``DATA/Info.lcl``'s ``SetUnitInfo`` table."""
    out: dict[int, str] = {}
    for dirpath, _dirs, files in os.walk(root):
        for fname in files:
            if fname.lower() != "info.lcl":
                continue
            program = lcl.parse_file(os.path.join(dirpath, fname))
            for stmt in program.statements():
                if stmt.name != "SetUnitInfo":
                    continue
                nums = [a.value for a in stmt.args if a.kind == "number"]
                texts = [a.value for a in stmt.args if a.kind == "string"]
                if nums and texts:
                    out[nums[0]] = texts[0]
            return out
    return out


def _check_close_combat(tables: "CombatTables", stats: "Stats") -> None:
    """``docs/21`` 6's ``special`` 1 -- the bayonet -- as bytes.

    Nothing in the corpus exercises it: a swap needs a ``special`` 1 gun
    standing next to what it fires at, which is a *runtime* arrangement and
    not a field in any file.  So what is pinned here is the arm itself -- the
    three call sites and their phases, the gate that keeps a reaction out, the
    order against the ammunition subtraction, and the four constants
    ``Combat.close_combat_swap`` transcribes.
    """
    pe = tables.pe

    # The three calls, and the phase each pushes first.
    for site, phase in sorted(WEAPON_SPECIAL_CALLS.items()):
        rel = struct.unpack("<i", pe.bytes_at(site + 1, 4))[0]
        stats.check("close.dispatcher",
                    pe.u8(site) == 0xE8 and site + 5 + rel == WEAPON_SPECIAL,
                    f"{site:#010x} does not call {WEAPON_SPECIAL:#010x}")
        # The push block is five or six bytes and the phase is its first
        # push, `6a XX`, because the fourth argument goes on the stack first.
        block = pe.bytes_at(site - 6, 6)
        head = block[0:2] if block[0] == 0x6A else block[1:3]
        stats.check("close.phase", head == bytes((0x6A, phase)),
                    f"{site:#010x} pushes {head.hex()} where phase {phase} "
                    f"wants {bytes((0x6A, phase)).hex()}")

    # Both close-combat phases are behind aAttackUnit's fifth argument.
    for site, want in sorted(WEAPON_SPECIAL_REACTION_GATES.items()):
        stats.check("close.reaction_gate", pe.bytes_at(site, len(want)) == want,
                    f"{site:#010x} does not read [esp+0x84]")

    # Phase 1 runs **after** the round is subtracted, which is the whole of
    # "a stab costs no ammunition": the subtraction reads the bayonet's own
    # `mun` of 255 and is skipped.
    stats.check("close.revert_follows_the_ammo",
                AMMO_SUBTRACT < 0x0046C325 < AMMO_SUBTRACT + 0x40,
                f"the subtraction at {AMMO_SUBTRACT:#010x} and the phase-1 "
                f"call are not in that order")
    stats.check("close.ammo_reads_the_held_weapon",
                pe.bytes_at(AMMO_SUBTRACT - 0x1E, 5)
                == b"\x33\xc0\x8a\x46\x3f",
                "the subtraction indexes on something other than unit[+0x3F]")

    # The revert arm's own three comparisons, and the swap's two constants.
    revert = pe.bytes_at(CLOSE_COMBAT_REVERT_TEST, 13)
    want_ids = tuple(revert[i] for i in (2, 7, 12))
    stats.check("close.revert_ids", want_ids == CLOSE_COMBAT_WEAPONS,
                f"the revert arm compares {want_ids}, not {CLOSE_COMBAT_WEAPONS}")
    stats.check("close.distance",
                pe.bytes_at(CLOSE_COMBAT_DISTANCE_TEST, 3) == b"\x83\xf8\x01",
                "the swap does not test `cmp eax, 1`")
    stats.check("close.height_levels",
                pe.bytes_at(CLOSE_COMBAT_HEIGHT_TEST, 3)
                == bytes((0x83, 0xFA, CLOSE_COMBAT_HEIGHT_LEVELS)),
                f"the height gate is not `cmp edx, {CLOSE_COMBAT_HEIGHT_LEVELS:#x}`")
    # `mov eax, 0x66666667 ... sar edx, 6` -- a truncating divide by 160, the
    # same height unit `unitinfo[+0x7C]` counts in.
    stats.check("close.height_divisor",
                pe.u32(CLOSE_COMBAT_HEIGHT_MAGIC_AT)
                == CLOSE_COMBAT_HEIGHT_MAGIC
                and pe.bytes_at(CLOSE_COMBAT_HEIGHT_SHIFT_AT, 3)
                == bytes((0xC1, 0xFA, CLOSE_COMBAT_HEIGHT_SHIFT)),
                "the reciprocal multiply is not 0x66666667 >> 6, i.e. not /160")
    # **The fight animation runs between the two phases**, which is what makes
    # the swap visible: `aPlayFightAnimation` selects the clip, the wave and
    # the muzzle from `unit[+0x3F]`, and at `0x0046C186` that byte is still
    # the bayonet.  Pinned as the call itself plus its position, because the
    # position is the whole claim.
    rel = struct.unpack("<i", pe.bytes_at(FIGHT_ANIMATION_CALL + 1, 4))[0]
    stats.check("close.animation_call",
                pe.u8(FIGHT_ANIMATION_CALL) == 0xE8
                and FIGHT_ANIMATION_CALL + 5 + rel == FIGHT_ANIMATION,
                f"{FIGHT_ANIMATION_CALL:#010x} does not call "
                f"{FIGHT_ANIMATION:#010x}")
    swap = min(site for site, phase in WEAPON_SPECIAL_CALLS.items()
               if phase == 0)
    stats.check("close.animation_precedes_the_revert",
                swap < FIGHT_ANIMATION_CALL < AMMO_SUBTRACT < 0x0046C325,
                "the animation call does not sit between the swap and the "
                "subtraction, so a stab would be drawn with its gun")

    # The two weapon columns the arm reads, by their own displacements.
    stats.check("close.reads_special",
                pe.u32(SPECIAL_COLUMN_READ) == WEAPON_TABLE_BASE + 0x3B,
                "the dispatcher does not index the `special` column")
    stats.check("close.writes_param",
                pe.u32(PARAM_COLUMN_WRITE) == WEAPON_TABLE_BASE + 0x3F,
                "the swap does not write the `param` column")


def run_check(root: str) -> int:
    exe = os.path.join(root, GAME_EXE)
    if not os.path.isfile(exe):
        print(f"{GAME_EXE} not found under {root!r} -- nothing was checked, "
              f"which is a failure, not a pass")
        return 1
    tables = CombatTables(PEFile(exe))
    stats = Stats()

    # 1. the target-pattern dispatch covers every weapon id
    for wid in range(WEAPON_COUNT):
        stats.check("aoe.dispatch", wid in tables.handler_of,
                    f"weapon {wid} has no dispatch entry")
    no_pattern = {w for w, h in tables.handler_of.items()
                  if h == tables.no_pattern_handler}
    stats.check("aoe.no_pattern", no_pattern == EXPECTED_NO_PATTERN,
                f"weapons without a pattern are {sorted(no_pattern)}, "
                f"expected {sorted(EXPECTED_NO_PATTERN)}")
    for handler, markers in tables.markers.items():
        stats.check("aoe.markers", all(m in MARKER_DAMAGE for m in markers),
                    f"handler {handler:#010x} writes {markers}")

    written = tables.written_markers()
    stats.check("marker.written", set(written) == EXPECTED_WRITTEN_MARKERS,
                f"markers written anywhere in .text are "
                f"{sorted(hex(m) for m in written)}, expected "
                f"{sorted(hex(m) for m in EXPECTED_WRITTEN_MARKERS)}")
    for va, want, what in SET_CELL_STATE_GUARDS:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("marker.write_guard", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")

    # 1b. Game.opt: the file is one .data block, and the rows name themselves
    io = tables.option_io()
    stats.check("opt.io", io == [(OPT_SIZE, OPT_BLOB)] * len(OPT_IO),
                f"aSaveOptions/aLoadOptions transfer {io}, expected "
                f"{[(OPT_SIZE, OPT_BLOB)] * len(OPT_IO)}")
    rows = tables.option_rows()
    stats.check("opt.rows", rows == EXPECTED_OPT_ROWS,
                f"option help lines are {rows}, expected {EXPECTED_OPT_ROWS}")
    stats.check("opt.difficulty", rows[OPT_DIFFICULTY_ROW] == 58,
                f"the difficulty row points at text {rows[OPT_DIFFICULTY_ROW]}, not 58")
    defaults = tables.option_defaults()
    stats.check("opt.defaults", defaults == EXPECTED_OPT_DEFAULTS,
                f"aInitOptions installs {defaults}, expected "
                f"{EXPECTED_OPT_DEFAULTS}")
    stats.check("opt.name_field",
                any(tables.refs_to(OPT_NAME_FIELD)),
                f"nothing addresses the player name at {OPT_NAME_FIELD:#010x}")
    dead = {va: tables.refs_to(va) for va in OPT_DEAD_FIELDS}
    stats.check("opt.dead", all(len(sites) == 1 for sites in dead.values()),
                "the two dead dwords are referenced at "
                + ", ".join(f"{va:#010x}: {[hex(s) for s in sites]}"
                            for va, sites in dead.items()))

    # 1c. the special column has no consumer this documentation does not know
    sites = set(tables.refs_to(SPECIAL_COLUMN))
    stats.check("special.sites", sites == EXPECTED_SPECIAL_SITES,
                f"unitType[+0x07] is referenced at {sorted(hex(x) for x in sites)}, "
                f"expected {sorted(hex(x) for x in EXPECTED_SPECIAL_SITES)}")
    pe = tables.pe
    stats.check("special.beacoo_type",
                pe.bytes_at(BEACOO_TYPE_TEST, 3) == b"\x80\xf9\x42",
                "aAttackUnit does not compare the target type with 0x42")
    stats.check("special.beacoo_weapon_type",
                pe.bytes_at(BEACOO_WEAPON_TYPE_TEST, 8)
                == b"\x80\xbc\x48\xf7\xb2\x51\x00\x02",
                "Bea'Coo's arm does not compare weapon type with 2")
    stats.check("special.beacoo_damage",
                pe.bytes_at(BEACOO_DAMAGE_WRITE, 5)
                == b"\xbd\xe8\x03\x00\x00",
                "Bea'Coo's arm does not write literal damage 1000")
    stats.check("bomb.base_damage", pe.u32(BOMB_BASE_DAMAGE) == 30,
                f"aExecuteBomb starts from {pe.u32(BOMB_BASE_DAMAGE)}, not 30")
    stats.check("bomb.special_damage", pe.u32(BOMB_SPECIAL_DAMAGE) == 1000,
                "aExecuteBomb's special-12 arm does not write literal 1000")
    bomb_ring = {site for site in tables.calls_to(SET_CELL_STATE)
                 if EXECUTE_BOMB <= site < EXECUTE_BOMB_END}
    stats.check("bomb.special_ring", len(bomb_ring) == 8,
                f"aExecuteBomb's special-12 arm has {len(bomb_ring)} ring writes")
    bomb_random = {site for site in tables.calls_to(RANDOM)
                   if EXECUTE_BOMB <= site < EXECUTE_BOMB_END}
    stats.check("bomb.no_hit_roll", not bomb_random,
                f"aExecuteBomb unexpectedly calls aRandom at {sorted(bomb_random)}")

    for va, want, what in RESOLVER_SWEEPS:
        got = pe.bytes_at(va, len(want) // 2).hex()
        stats.check("resolver.sweep", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    for va, want, what in PRESENTATION_RESULT_SWEEP:
        got = pe.bytes_at(va, len(want) // 2).hex()
        stats.check("presentation.result_sweep", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")

    attack_removals = {site for site in tables.calls_to(REMOVE_UNIT_ELEMENT)
                       if 0x0046B9B6 <= site <= ATTACK_REMOVE_CALL}
    stats.check(
        "resolver.attack_animation_before_removal",
        FIGHT_ANIMATION_CALL in tables.calls_to(FIGHT_ANIMATION)
        and attack_removals == {ATTACK_REMOVE_CALL}
        and FIGHT_ANIMATION_CALL < ATTACK_REMOVE_CALL,
        f"attack animation/removal sites are {FIGHT_ANIMATION_CALL:#010x} / "
        f"{sorted(hex(site) for site in attack_removals)}",
    )
    bomb_removals = {site for site in tables.calls_to(REMOVE_UNIT_ELEMENT)
                     if 0x00470326 <= site <= BOMB_REMOVE_CALL}
    stats.check(
        "resolver.bomb_animation_before_removal",
        BOMB_FIGHT_ANIMATION_CALL in tables.calls_to(FIGHT_ANIMATION)
        and bomb_removals == {BOMB_REMOVE_CALL}
        and BOMB_FIGHT_ANIMATION_CALL < BOMB_REMOVE_CALL,
        f"bomb animation/removal sites are "
        f"{BOMB_FIGHT_ANIMATION_CALL:#010x} / "
        f"{sorted(hex(site) for site in bomb_removals)}",
    )

    # 1d. the fog: which call sites are permanent and which are probes
    fog_sites = tables.calls_to(BUILD_VISIBLE_MAP)
    stats.check("fog.sites", fog_sites == EXPECTED_FOG_SITES,
                f"aBuildVisibleMap is called from "
                f"{sorted(hex(x) for x in fog_sites)}, expected "
                f"{sorted(hex(x) for x in EXPECTED_FOG_SITES)}")
    saves = tables.calls_to(SAVE_VISIBILITY)
    stats.check("fog.saves", saves == EXPECTED_SAVE_SITES,
                f"the visibility save is called from "
                f"{sorted(hex(x) for x in saves)}, expected "
                f"{sorted(hex(x) for x in EXPECTED_SAVE_SITES)}")
    restores = tables.calls_to(RESTORE_VISIBILITY)
    stats.check("fog.restores", restores == EXPECTED_RESTORE_SITES,
                f"the visibility restore is called from "
                f"{sorted(hex(x) for x in restores)}, expected "
                f"{sorted(hex(x) for x in EXPECTED_RESTORE_SITES)}")

    # 1e. `special` 9, the one arm that rewrites the roster (docs/21 §5)
    for va, want, what in HATCH_ARM:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("hatch.arm", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    for site, target in (HATCH_CURRENT_PLAYER_CALL, HATCH_FOG_CALL):
        stats.check("hatch.call", site in tables.calls_to(target),
                    f"{site:#010x} does not call {target:#010x}")

    # 1f. the door, whose two arms are what docs/22 §9.4 calls the use path
    for va, want, what in DOOR_ARMS:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("door.fog", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")

    # 1g. the other ten permanent rebuilds -- whose fog each one moves
    for va, want, what in FOG_ARGUMENTS:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("fog.argument", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    for va, want, what in PLAYER_RECORD:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("fog.player_record", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    # 1f-bis. docs/22 section 7.5 -- the kill award, instruction by instruction
    for va, want, what in EXPERIENCE_SITES:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("experience.site", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    for va, value in EXPERIENCE_FLOATS:
        got = struct.unpack("<f", tables.pe.bytes_at(va, 4))[0]
        stats.check("experience.float", got == value,
                    f"{va:#010x} is {got}, expected {value}")
    for va, want, what in VIEW_PLAYER_BLOCK:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("fog.view_player_block", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")

    # 1h. docs/22 §9.5 -- the hero counter, and the predicate that reads it
    for va, want, what in HERO_COUNTER:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("hero.counter", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    for site, target, what in HERO_COUNTER_CALLS:
        stats.check("hero.call", site in tables.calls_to(target),
                    f"{site:#010x} does not call {target:#010x} ({what})")
    predicate, only_site, name_va, name = HERO_KILLED_NAME
    callers = tables.calls_to(predicate)
    stats.check("hero.predicate", callers == {only_site},
                f"{predicate:#010x} is called from "
                f"{sorted(hex(x) for x in callers)}, expected "
                f"{[hex(only_site)]}")
    stats.check("hero.predicate_name",
                tables.pe.bytes_at(name_va, len(name)) == name,
                f"{name_va:#010x} is not {name!r} -- the string the dispatcher "
                f"compares immediately before calling {predicate:#010x}")

    # 1i. the Spidy arm: an impact that spawns a unit rather than a blob
    key = SPIDY_WEAPON - IMPACT_KEY_BIAS
    arm = tables.pe.u32(IMPACT_JUMP_TABLE
                        + 4 * tables.pe.u8(IMPACT_INDEX_TABLE + key))
    stats.check("spidy.arm", arm == SPIDY_ARM,
                f"weapon {SPIDY_WEAPON} selects {arm:#010x}, expected "
                f"{SPIDY_ARM:#010x}")
    for va, want, what in SPIDY_SPAWN:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("spidy.spawn", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")

    # 1j. docs/22 §9.4.3 -- the `0x004149C7` rebuild belongs to the spore
    #     hatch, not to `FixedStatue`.  The frame is what makes `[esp+0x40]`
    #     mechanically re-checkable as argument 3.
    for va, want, what in SPORE_HATCH_FRAME:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("spore.frame", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    for va, want, what in SPORE_SPAWN:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("spore.spawn", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    stats.check("spore.callers",
                tables.calls_to(SPORE_HATCH) == SPORE_HATCH_CALLERS,
                f"{SPORE_HATCH:#010x} is called from "
                f"{sorted(hex(x) for x in tables.calls_to(SPORE_HATCH))}, "
                f"expected {sorted(hex(x) for x in SPORE_HATCH_CALLERS)}")
    for target in (SPORE_HATCH, 0x0046FC30, 0x0046FC90):
        refs = tables.image_refs_to(target)
        stats.check("spore.no_pointer", not refs,
                    f"{target:#010x} appears as a little-endian dword at file "
                    f"{[hex(o) for o in refs]} -- something may reach it "
                    f"through a table rather than through a call")
    for va, want, what in SPORES_ARM + MOVE_SPORES_ARM:
        got = tables.pe.bytes_at(va, len(want) // 2).hex()
        stats.check("spore.arm", got == want,
                    f"{va:#010x} is {got}, expected {want} ({what})")
    for site, handler, name_va, name in SPORE_DISPATCH:
        stats.check("spore.dispatch",
                    site in tables.calls_to(handler),
                    f"{site:#010x} does not call {handler:#010x}")
        head = site - DISPATCH_STRIDE
        stats.check("spore.dispatch",
                    tables.pe.u8(head) == 0xB8
                    and tables.pe.u32(head + 1) == name_va
                    and tables.pe.bytes_at(name_va, len(name)) == name,
                    f"the mov at {head:#010x} does not load {name!r} from "
                    f"{name_va:#010x} -- the name paired with {handler:#010x}")
    statue_calls = tables.call_targets(*STATUE_BODY)
    for target in STATUE_MUST_NOT_CALL:
        stats.check("spore.statue", target not in statue_calls,
                    f"aPlayStatueSequence calls {target:#010x} after all -- "
                    f"§9.4.3 says it spawns nothing and rebuilds no fog")
    stats.check("spore.statue", STATUE_MUST_CALL in statue_calls,
                f"aPlayStatueSequence does not call {STATUE_MUST_CALL:#010x}, "
                f"aRemoveUnitElement")

    # 2. the indirect-fire predicate
    stats.check("arc.weapons", tables.arcing == EXPECTED_ARCING,
                f"arcing weapons are {sorted(tables.arcing)}, "
                f"expected {sorted(EXPECTED_ARCING)}")

    # 3. the octant tables are a consistent neighbour pair
    a930, a9a0 = tables.octants["a930"], tables.octants["a9a0"]
    for d in range(8):
        stats.check("octant.range", a930[d] in range(8) and a9a0[d] in range(8),
                    f"direction {d} maps to {a930[d]}/{a9a0[d]}")
        stats.check("octant.distinct",
                    a930[d] != a9a0[d] and a930[d] != d and a9a0[d] != d,
                    f"direction {d} maps to itself or to one neighbour twice")
    stats.check("octant.symmetric",
                all(d in (a930[a930[d]], a9a0[a930[d]]) for d in range(8)),
                "the neighbour relation is not symmetric")

    # 4. .rdata constants
    for name, (va, want) in CONSTANTS.items():
        got = tables.pe.f64(va)
        stats.check("const", got == want, f"{name} at {va:#010x} is {got}, expected {want}")
    for value, (lo, hi) in LOS_BIASES.items():
        got = struct.unpack("<d", struct.pack("<II", lo, hi))[0]
        stats.check("const.bias", got == value, f"bias halves decode to {got}, not {value}")

    # 5. the magic division, over the height range the corpus actually contains
    lo, hi, nlev = corpus_height_range(root)
    stats.check("lev.corpus", nlev > 0, f"no .lev parsed under {root!r}")

    # 5a. the Spidy arm cannot fire from authored data
    weapon_ids, placed, wfiles = corpus_weapon_ids(root)
    stats.check("spidy.corpus", wfiles > 0 and placed > 0,
                f"no placed unit found under {root!r}")
    stats.check("spidy.unreachable", SPIDY_WEAPON not in weapon_ids,
                f"weapon {SPIDY_WEAPON} is carried by a placed unit after all")
    stats.check("spidy.armoury_half",
                max(weapon_ids) < 30,
                f"a placed unit carries weapon {max(weapon_ids)}; the whole "
                f"upper half of the table was thought to be the campaign "
                f"armoury's")
    # 5b. docs/22 §9.4.3 -- what authored data can actually reach the hatch
    family, nscripts = corpus_actpt_family(root)
    stats.check("spore.corpus", nscripts > 0,
                f"no LCL script parsed under {root!r}")
    got = tuple((f, a) for f, a in family["Spores"])
    stats.check("spore.corpus_spores", got == SPORES_CORPUS_CALLS,
                f"the shipped Spores calls are {got}, expected "
                f"{SPORES_CORPUS_CALLS}")
    for command in SPORES_CORPUS_UNUSED:
        stats.check("spore.corpus_unused", not family[command],
                    f"{command} is used after all: {family[command]}")
    unit_names = corpus_unit_names(root)
    for uid, want in SPORE_UNIT_NAMES.items():
        stats.check("spore.unit_type", unit_names.get(uid) == want,
                    f"unit type {uid} is {unit_names.get(uid)!r} in Info.lcl, "
                    f"expected {want!r}")

    span = hi - lo                       # the largest |dh| the corpus can produce
    bad = next((n for n in range(0, span + 1)
                if magic_div_2400_plus_1(n) != n // HEIGHT_STEP + 1), None)
    stats.check("magic.div", bad is None,
                f"emulation differs from n//{HEIGHT_STEP}+1 at n={bad}")

    # 6. aRandom: the constants form the documented Lehmer generator
    consts = tables.constants()
    stats.check("rng.modulus", consts["rng_modulus"] == 2.0 ** 31 - 1,
                f"modulus is {consts['rng_modulus']}")
    stats.check("rng.scale", consts["rng_scale"] == 1.0 / consts["rng_modulus"],
                f"scale is {consts['rng_scale']}, not 1/modulus")
    rng = Random(consts["rng_multiplier"], consts["rng_modulus"],
                 consts["rng_scale"], seed=1.0)
    draws = [rng(0, 100) for _ in range(1000)]
    stats.check("rng.range", all(0 <= d <= 99 for d in draws),
                "aRandom(0, 100) left 0..99")

    # 6b. the RNG globals are private to the generator, in both binaries
    for name, (globals_, (lo_va, hi_va)) in RNG_GLOBALS.items():
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            stats.check("rng.private", False, f"{name} not found under {root!r}")
            continue
        other = CombatTables.__new__(CombatTables)
        other.pe = PEFile(path)
        stray = [va for g in globals_ for va in other.refs_to(g)
                 if not lo_va <= va < hi_va]
        stats.check("rng.private", not stray,
                    f"{name}: the RNG globals are referenced outside "
                    f"{lo_va:#x}..{hi_va:#x} at {[hex(v) for v in stray]}")

    # 6c. docs/21 6: the close-combat swap, read out of the dispatcher
    _check_close_combat(tables, stats)

    # 7. the hit curve over every shipped weapon
    weapons = load_weapons(root)
    stats.check("info.weapons", len(weapons) >= 40,
                f"Info.lcl yielded only {len(weapons)} weapons")
    clobbered = sorted(w.id for w in weapons.values() if len(w.wave) == 9)
    stats.check("info.wave_overrun", len(clobbered) == 8,
                f"{len(clobbered)} weapons have a 9-character wave name: {clobbered}")
    for w in sorted(weapons.values(), key=lambda x: x.id):
        if w.range_max <= 0:
            continue
        curve = [hit_percent(min(w.accuracy, 100), w.range_max, d)
                 for d in range(max(w.range_min, 1), w.range_max + 1)]
        stats.check("hit.monotonic", curve == sorted(curve, reverse=True),
                    f"weapon {w.id} {w.name!r} curve is not monotonic: {curve}")
        stats.check("hit.bounded", all(v <= 100 for v in curve),
                    f"weapon {w.id} {w.name!r} exceeds 100: {curve}")

    print(f"corpus: {GAME_EXE}, {nlev} .lev, {len(weapons)} weapons from Info.lcl")
    print("checks:")
    stats.report()
    if stats.failures:
        print(f"\n{len(stats.failures)} failure(s):")
        for line in stats.failures[:50]:
            print(f"  {line}")
        return 1
    print("\nall checks passed")
    return 0


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

def print_patterns(root: str) -> int:
    tables = CombatTables(PEFile(os.path.join(root, GAME_EXE)))
    weapons = load_weapons(root)
    groups: dict[int, list[int]] = defaultdict(list)
    for wid, handler in tables.handler_of.items():
        groups[handler].append(wid)
    print(f"{WEAPON_COUNT} weapon ids -> {len(groups)} target patterns")
    for handler in sorted(groups):
        markers = tables.markers.get(handler, [])
        tag = ("no pattern" if handler == tables.no_pattern_handler
               else " ".join(f"{m:#04x}({MARKER_DAMAGE[m]})" for m in markers))
        print(f"\n  {handler:#010x}  {tag}")
        for wid in groups[handler]:
            w = weapons.get(wid)
            arc = " [arcing]" if wid in tables.arcing else ""
            name = f"{w.name!r}" if w and w.name else "not in Info.lcl"
            print(f"      {wid:>3}  {name}{arc}")
    return 0


def print_hit_curve(root: str) -> int:
    weapons = load_weapons(root)
    print(f"{'id':>3}  {'weapon':<26} {'acc':>4} {'min':>4} {'max':>4} "
          f"{'slope':>6}  hit% at min .. max")
    for w in sorted(weapons.values(), key=lambda x: x.id):
        if w.range_max <= 0:
            print(f"{w.id:>3}  {w.name:<26} {w.accuracy:>4} {w.range_min:>4} "
                  f"{w.range_max:>4} {'-':>6}  never in range")
            continue
        acc = min(w.accuracy, 100)
        slope = (101 - acc) // w.range_max
        first = max(w.range_min, 1)
        print(f"{w.id:>3}  {w.name:<26} {w.accuracy:>4} {w.range_min:>4} "
              f"{w.range_max:>4} {slope:>6}  "
              f"{hit_percent(acc, w.range_max, first)} .. "
              f"{hit_percent(acc, w.range_max, w.range_max)}")
    return 0


def dump_json(root: str) -> int:
    tables = CombatTables(PEFile(os.path.join(root, GAME_EXE)))
    weapons = load_weapons(root)
    out = {
        "aoe": {
            str(wid): {
                "handler": f"{tables.handler_of[wid]:#010x}",
                "markers": tables.markers.get(tables.handler_of[wid], []),
                "arcing": wid in tables.arcing,
            }
            for wid in range(WEAPON_COUNT)
        },
        "octants": tables.octants,
        "constants": tables.constants(),
        "weapons": {str(w.id): w.to_dict() for w in weapons.values()},
    }
    json.dump(out, sys.stdout, indent=1)
    print()
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", nargs="?", default="gog_incubation",
                    help="the game directory (default: gog_incubation)")
    ap.add_argument("--check", metavar="ROOT", help="run the corpus checks")
    ap.add_argument("--patterns", action="store_true",
                    help="print the weapon -> target-pattern table")
    ap.add_argument("--hit-curve", action="store_true",
                    help="print the hit percentage of every weapon")
    ap.add_argument("--json", action="store_true", help="dump everything as JSON")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    root = args.check or args.root
    if not os.path.isdir(root):
        LOG.error("root %s is not a directory", root)
        return 2
    try:
        if args.check:
            return run_check(root)
        if args.patterns:
            return print_patterns(root)
        if args.hit_curve:
            return print_hit_curve(root)
        if args.json:
            return dump_json(root)
        return print_patterns(root)
    except (PEError, LevError) as exc:
        LOG.error("%s", exc)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
