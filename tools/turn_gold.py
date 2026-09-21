#!/usr/bin/env python3
"""Capture the turn, line of sight and hit probability from the live game.

The rank-1 oracle for the second slice, built on the session ``movemap_gold.py``
established: the same anchor inside ``aGameIntro`` (``Incubation.exe+0x4bd6f``),
the same save-slot-6 load by calling ``aSetSaveMode(0)`` and ``aLoadGame(6)``
rather than by patching anything, and the same retry loop, because Wine
start-up on this host is intermittent (``docs/91`` §1) and a run that never
reaches the anchor is an environment result rather than a failure.

``run_plan`` and the capture constants are **imported** from
``movemap_gold.py``, not copied: it is one session with two sets of probes.

What this captures, in the order it is safe to capture it:

1. **State** -- the control map, the 200-slot unit array and the AI level.
2. **Line of sight and hit probability** -- pure reads over a grid of unit
   pairs.  ``aCheckLineOfSightEx`` and ``aGetHitProbability`` change nothing,
   so they go first and a later probe crashing cannot cost them.
3. **The refresh** -- ``0x004781C0`` on one player, with the whole unit array
   read back afterwards, so every one of the 200 records is diffed field by
   field.  This is also what pins the correction to ``docs/25`` §5 natively:
   if ``+0x15`` comes back holding ``aGetMovePoints``'s answer, the movement
   points **are** stored and the refresh **does** restore them.
4. **The lone recompute** -- ``0x004759B0`` on a single unit whose ``+0x15``
   was first written to a sentinel, which separates that routine's own effect
   from everything else the refresh does.

``--check`` re-runs :mod:`inclib.combat` and :mod:`inclib.turn` against the
captured inputs and requires them to agree.  It is a check whose oracle is the
shipped engine, so it needs Wine and a copy of the game and stays outside the
always-run block.

Never run this against ``gog_incubation/``.  It needs a **copy** with
``Work/Saves2/_6_.sav`` in it, and the tool refuses a game directory inside
this repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import struct
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import movemap_gold as gold                                        # noqa: E402
from inclib.cache import is_within                                 # noqa: E402
from inclib import combat as combatmod                             # noqa: E402
from inclib import footprint as footprintmod                       # noqa: E402
from inclib import interact as interactmod                         # noqa: E402
from inclib import turn as turnmod                                 # noqa: E402
from inclib.check import Checker                                   # noqa: E402
from inclib.info import BalanceTables, load_info                   # noqa: E402
from inclib import lcl as lclmod
from inclib import lcl_runtime as lclmodrt
from inclib import lev as levmod
from inclib import movemap as movemapmod
from inclib import script as scriptmod
from inclib.rng import ARandom                                     # noqa: E402

LOG = logging.getLogger("turn_gold")

CAPTURE_SCHEMA = "incubation.turn-capture/3"

#: The mission the capture is taken on.
MISSION = "_C_141"

#: The routines this capture calls, as module-relative addresses.  The image
#: base is ``0x00400000``, so ``0x0046A270`` is ``+0x6A270``.
DECLARATIONS = """\
__cdecl void aSetSaveMode(i32)              = Incubation.exe+0x48770
__cdecl i32  aLoadGame(i32)                 = Incubation.exe+0x48e60
__cdecl ptr  aGetCtrlMapElementPtr(i32,i32) = Incubation.exe+0x2f730
__cdecl ptr  aGetUnitMapElementPtr(i32)     = Incubation.exe+0x77ae0
__cdecl i32  aGetAILevel()                  = Incubation.exe+0x60450
__cdecl i32  aCheckLineOfSightEx(i32,i32,i32,i32,i32,i32,i32,ptr) = Incubation.exe+0x6c460
__cdecl i32  aGetHitProbability(ptr,ptr,i32,i32,i32,ptr,ptr) = Incubation.exe+0x6a270
__cdecl i32  aGetUnitFullHeight(ptr)        = Incubation.exe+0x7ad70
__cdecl i32  aGetUnitEyeHeight(ptr)         = Incubation.exe+0x7ad30
__cdecl i32  aGetMovePoints(ptr)            = Incubation.exe+0x75160
__cdecl void aRefreshPlayer(i32)            = Incubation.exe+0x781c0
__cdecl void aRecomputeStats(ptr)           = Incubation.exe+0x759b0
__cdecl i32  aCheckWeaponDamage(ptr)        = Incubation.exe+0x6d1b0
__cdecl i32  aExecuteUse(ptr)               = Incubation.exe+0x6dc60
__cdecl i32  aAttackUnit(i32,i32,i32,i32,i32) = Incubation.exe+0x6b450
__fastcall void setb(ptr,i32)               = &setb
__cdecl u8   aGetTurn()                     = Incubation.exe+0x3b280
__cdecl u8   aGetCurrentPlayer()            = Incubation.exe+0x3b2c0
__cdecl u8   aGetPreviousPlayer()           = Incubation.exe+0x3b2d0
__cdecl i32  aGetPlayerCount()              = Incubation.exe+0x3b310
__cdecl i32  aGetHumanCount()               = Incubation.exe+0x3b700
__cdecl i32  aGetSoloFlag()                 = Incubation.exe+0x3b1e0
__cdecl i32  aGetPlayerKind(i32)            = Incubation.exe+0x3b6e0
__cdecl i32  aGetEndState(i32)              = Incubation.exe+0x3b930
__cdecl i32  aGetLclSlot(i32)               = Incubation.exe+0x3b160
__cdecl i32  aAnyPlayerLeftThisTurn()       = Incubation.exe+0x3b490
__cdecl i32  aAdvancePlayer()               = Incubation.exe+0x3b320
__cdecl i32  aSetEnvVar(i32,i32)            = Incubation.exe+0x402a0
__cdecl i32  aGetMissionProgram()           = Incubation.exe+0x19a40
__cdecl i32  aRunLCL(i32)                   = Incubation.exe+0x3f6e0
"""

#: ``0x00514078`` -- ``aRandom``'s seed, and a **qword**: the generator reads it
#: with ``fld qword`` and writes it back with ``fst qword``.  Captured rather
#: than poked, because a zero seed is a fixed point in that generator and the
#: retail global starts zeroed, so reading it says whether it was drawn at all.
SEED_ADDR = 0x00514078

#: ``_A`` selects the entry point; ``docs/20`` §5 gives 1 for ``NextPlayer``.
ENTRY_NEXT_PLAYER = 1

#: How many times the rotation is advanced.  Enough to wrap past the computer
#: and come back round on any player count this save can have, so the sequence
#: pins the wrap and not just the first step.
ROTATION_STEPS = 12

#: The same three-byte ``mov [ecx], dl; ret`` movemap_gold injects.  Here it
#: writes a sentinel into ``+0x15`` before the lone recompute, so that routine's
#: own write is distinguishable from the value that was already there.
SETB_CODE = "8811c3"

#: ``+0x15`` is a byte, so the sentinel has to be one.  200 is outside every
#: allowance the formula can produce (``0x0047521F`` zeroes anything above it),
#: which is exactly why it makes a good "nothing wrote here" marker.
MP_SENTINEL = 200

#: How many ordered unit pairs the read-only probes cover.  Every live pair on
#: this save would be a few hundred calls at ~400 calls/second, which is
#: affordable; the cap is here so a save with more units cannot make one
#: attempt exceed its timeout.
MAX_PAIRS = 240

#: The ``mode`` argument ``aCheckLineOfSightEx`` is probed with.  Mode 0 is the
#: single reversed centre ray; anything else fans out to two or four, and which
#: of those it is depends on engine globals rather than on the arguments
#: (``docs/22`` §6.1).  Probing 1 is what exercises the fan and therefore the
#: "keep the smallest" rule that the single-ray mode cannot distinguish.
LOS_MODE = 1

#: The neutral-prop owner.  ``docs/25`` §7 -- it is **never** stored in the
#: current-player byte, the setter would reject it, and nothing passes it, so
#: ``aRefreshPlayer(252)`` is a call the engine itself never makes.  Its
#: records are crates: no fatigue cap, no stimulant, no heat, no malfunction.
#: A refresh captured on them would have matched a model that did nothing.
PLAYER_PROPS = 252

#: ``docs/10`` §5.7 -- the aliens.  Named here because phase 10 needs a
#: mover the *player* owns: an alien's fill is the one that steps onto
#: mines, so choosing one would have made the mine probe unreachable
#: for the arm a squad actually walks into.
PLAYER_ALIEN = 255


class GoldError(Exception):
    """Raised when a capture cannot be produced or read."""


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _unit_addr(slot: int, offset: int = 0) -> str:
    return f"$u0+0x{slot * gold.UNIT_STRIDE + offset:x}"


def _live_slots(unit_bytes: bytes) -> list[int]:
    """Slots whose ``+0x16`` is non-zero -- the engine's own "is placed" test."""
    return [slot for slot in range(gold.UNIT_SLOTS)
            if unit_bytes[slot * gold.UNIT_STRIDE + gold.UNIT_HP]]


def _byte(unit_bytes: bytes, slot: int, offset: int) -> int:
    return unit_bytes[slot * gold.UNIT_STRIDE + offset]


# ---------------------------------------------------------------------------
# Plans
# ---------------------------------------------------------------------------

def state_plan() -> str:
    """Phase 1 -- load the save and dump everything the later plans index."""
    cells = gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    return "\n".join([
        "# Phase 1: load save slot 6 and dump the control map and unit array.",
        DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "c0 = aGetCtrlMapElementPtr(0,0)",
        "u0 = aGetUnitMapElementPtr(0)",
        f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        "# The AI level is an input to the allowance and to the damage roll.",
        "aGetAILevel()",
    ]) + "\n"


def sight_plan(pairs: list[tuple[int, int, int]],
               live: list[int], unit_bytes: bytes) -> str:
    """Phase 2 -- the read-only probes, over a grid of ordered unit pairs.

    Every call here is a pure function of the state phase 1 already captured,
    so the whole phase can be re-run without reloading anything.

    The two height helpers are called once per live slot and their results are
    **bound by name**, so the line-of-sight calls below can pass them as
    arguments (``$name`` is EAX of an earlier call).  That is what lets the
    heights and the rays they feed share one plan: the heights are computed by
    the engine, not stored, so they cannot be known when the plan is written.
    """
    cells = gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    lines = [
        "# Phase 2: line of sight and hit probability. Nothing here mutates.",
        DECLARATIONS,
        "--buf los:4",
        "--buf hit:4",
        "--buf dist:4",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "c0 = aGetCtrlMapElementPtr(0,0)",
        "u0 = aGetUnitMapElementPtr(0)",
        f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        "aGetAILevel()",
    ]
    for slot in live:
        lines.append(f"full{slot} = aGetUnitFullHeight({_unit_addr(slot)})")
        lines.append(f"eye{slot} = aGetUnitEyeHeight({_unit_addr(slot)})")
    for a, b, weapon in pairs:
        # The weapon id is a literal read out of phase 1's dump rather than an
        # `[address]` expression: `[expr]` reads a **dword**, and `+0x3F` is a
        # byte with three unrelated fields packed after it.
        lines.append(
            f"aGetHitProbability({_unit_addr(a)}, {_unit_addr(b)}, "
            f"{weapon}, 0, 1, &hit, &dist) --dump hit --dump dist")
    # Line of sight on its own, over the same pairs.  It used to be missing:
    # the plan declared a `los` buffer and never emitted a call for it, so the
    # rays were pinned only indirectly, through whatever aGetHitProbability
    # does with them internally.  The shooter looks from its eyes and the
    # target is hit anywhere up its body (``docs/22`` §6.2), which is
    # asymmetric -- so an ordered pair list gives both directions for free.
    for a, b, _w in pairs:
        lines.append(
            f"aCheckLineOfSightEx("
            f"{_byte(unit_bytes, a, gold.UNIT_X)}, "
            f"{_byte(unit_bytes, a, gold.UNIT_Y)}, $eye{a}, "
            f"{_byte(unit_bytes, b, gold.UNIT_X)}, "
            f"{_byte(unit_bytes, b, gold.UNIT_Y)}, $full{b}, "
            f"{LOS_MODE}, &los) --dump los")
    return "\n".join(lines) + "\n"


def refresh_plan(player: int) -> str:
    """Phase 3 -- the hand-over refresh, with the unit array read either side.

    Deliberately **without** the injected byte writer.  ``docs/91`` §1's
    intermittent start-up means a phase that needs several attempts costs
    several whole game launches, so the phase carrying the deliverable -- the
    field-by-field diff over 200 records -- is kept as small as it can be and
    the sentinel probe is a separate plan that may fail on its own.
    """
    cells = gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    return "\n".join([
        "# Phase 3: 0x004781C0, with the unit array read before and after.",
        DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "c0 = aGetCtrlMapElementPtr(0,0)",
        "u0 = aGetUnitMapElementPtr(0)",
        f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        "aGetAILevel()",
        f"aRefreshPlayer({player})",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
    ]) + "\n"


def recompute_plan(probe_slot: int) -> str:
    """Phase 4 -- the lone ``0x004759B0``, on a slot with a sentinel in ``+0x15``.

    ``docs/25`` §5 used to say the movement points are not stored at all, so
    the question this answers is narrow and sharp: does that routine write the
    byte?  Writing a sentinel first is what makes the answer unambiguous --
    without it, a ``+0x15`` that already held the right value would look like
    a write whether or not one happened.
    """
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    return "\n".join([
        "# Phase 4: a sentinel into +0x15, then the lone recompute.",
        DECLARATIONS,
        f"--code setb:{SETB_CODE}",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "u0 = aGetUnitMapElementPtr(0)",
        "aGetAILevel()",
        f"setb({_unit_addr(probe_slot, gold.UNIT_MP)}, {MP_SENTINEL})",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        f"want = aGetMovePoints({_unit_addr(probe_slot)})",
        f"aRecomputeStats({_unit_addr(probe_slot)})",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
    ]) + "\n"


def rotation_plan() -> str:
    """Phase 5 -- the turn state and the rotation, stepped one player at a time.

    Deliberately **not** the whole hand-over.  ``0x0047D600`` ends by calling
    ``aAISystemControl`` once the current player becomes 255 (``docs/25`` §4),
    which is the computer's entire turn -- out of this stage's scope, and not
    something to start inside a debugger probe.  ``0x0043B320`` is the part
    ``docs/25`` §3.1 actually specifies, and it is the part a remake's turn
    sits on.

    Every accessor here was checked in the disassembly first: each is a load
    from a fixed address with a bounds test, so a wrong arity would be a wrong
    answer rather than an error.  Three of them are ``mov al, [g]; ret`` and
    are declared ``u8`` for that reason -- read as ``i32`` the current player
    came back as 4436480 rather than 0, because only AL is the result and the
    rest of EAX is the caller's leftovers.  ``aGetLclSlot`` reads
    ``[eax*4 + 0x509f18]`` after rejecting an index of 12 or more, which is the
    twelve game-control slots ``docs/20`` §7 owns.
    """
    lines = [
        "# Phase 5: turn state, the twelve LCL slots, and the rotation.",
        DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "aGetAILevel()",
        "aGetTurn()",
        "aGetPlayerCount()",
        "aGetHumanCount()",
        "aGetSoloFlag()",
    ]
    for i in range(4):
        lines.append(f"aGetPlayerKind({i})")
        lines.append(f"aGetEndState({i})")
    for i in range(12):
        lines.append(f"aGetLclSlot({i})")
    # The rotation, one step at a time, reading the three bytes it maintains
    # after each.  aAnyPlayerLeftThisTurn is sampled alongside because it is
    # the predicate the hand-over uses to decide whether the turn advances.
    for _ in range(ROTATION_STEPS):
        lines.append("aGetCurrentPlayer()")
        lines.append("aGetPreviousPlayer()")
        lines.append("aAnyPlayerLeftThisTurn()")
        lines.append("aAdvancePlayer()")
    lines.append("aGetCurrentPlayer()")
    lines.append("aGetPreviousPlayer()")
    return "\n".join(lines) + "\n"


def lcl_plan() -> str:
    """Phase 6 -- one ``NextPlayer`` invocation of the mission script.

    The call chain is the one ``0x0047D600`` itself uses, read off the
    disassembly rather than taken from a doc: ``0x004402A0`` sets an
    environment variable (**letter first, value second**), ``0x00419A40``
    returns the loaded mission program's id from ``[0x4fd223]``, and
    ``0x0043F6E0`` runs it.  The plan's oracle table named ``0x004402A0`` as
    "the program is called"; it is the environment setter, and ``docs/20``'s
    own table says so.

    The turn and the current player are read live and bound by name rather
    than baked in, so this phase does not depend on phase 5 having run.

    **This phase mutates.**  ``_C_141``'s script carries four ``InsertUnit``
    and two ``SetVarRandom``, so it can both draw the generator and place
    units.  It is therefore last, and the seed is read either side to say
    whether it was drawn at all.
    """
    cells = gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    lines = [
        "# Phase 6: NEXT PLAYER through the real interpreter.",
        DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "c0 = aGetCtrlMapElementPtr(0,0)",
        "u0 = aGetUnitMapElementPtr(0)",
        f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        "aGetAILevel()",
        f"aGetTurn() --read {SEED_ADDR:#x}:8",
    ]
    lines += [f"aGetLclSlot({i})" for i in range(12)]
    lines += [
        f"turn = aGetTurn()",
        "player = aGetCurrentPlayer()",
        f"aSetEnvVar(0x41, {ENTRY_NEXT_PLAYER})",
        "aSetEnvVar(0x42, $turn)",
        "aSetEnvVar(0x43, $player)",
        "pid = aGetMissionProgram()",
        "ran = aRunLCL($pid)",
    ]
    lines += [f"aGetLclSlot({i})" for i in range(12)]
    lines += [
        f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        f"aGetPlayerCount() --read {SEED_ADDR:#x}:8",
    ]
    return "\n".join(lines) + "\n"


#: How many at-the-cap overheat probes to take.  Each advances the generator,
#: so the sequence walks different rolls rather than repeating one.
OVERHEAT_PROBES = 8

#: How many aAttackUnit probes phase 8 takes.  Each one changes the world
#: and draws the generator, so this is the expensive phase the plan warned
#: about; a handful is enough to cover a hit, a miss and a kill.
ATTACK_PROBES = 6


def overheat_plan(slot: int, cap: int) -> str:
    """Phase 7 -- ``aCheckWeaponDamage`` at and below the heat cap.

    ``docs/22`` §8: the routine does nothing unless ``+0x3E`` is **exactly**
    at the cap, and then rolls ``aRandom(0, heat)``.  So the phase probes both
    sides of that gate: one call one below the cap, which must change nothing
    and must not draw, then several at it, which must.  The seed is read after
    every call because it is the only way to say how many draws happened.
    """
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    heat = f"{_unit_addr(slot)}+0x3e"
    lines = [
        "# Phase 7: the overheat gate and its roll.",
        DECLARATIONS,
        f"--code setb:{SETB_CODE}",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "u0 = aGetUnitMapElementPtr(0)",
        "aGetAILevel()",
        f"aGetUnitMapElementPtr(0) --read $u0:{units} --read {SEED_ADDR:#x}:8",
        # Below the cap: the gate must hold.
        f"setb({heat}, {cap - 1})",
        f"aCheckWeaponDamage({_unit_addr(slot)})",
        f"aGetUnitMapElementPtr(0) --read $u0:{units} --read {SEED_ADDR:#x}:8",
    ]
    for _ in range(OVERHEAT_PROBES):
        lines += [
            f"setb({heat}, {cap})",
            f"aCheckWeaponDamage({_unit_addr(slot)})",
            f"aGetUnitMapElementPtr(0) --read $u0:{units} "
            f"--read {SEED_ADDR:#x}:8",
        ]
    return "\n".join(lines) + "\n"


def attack_plan(probes: list[tuple[int, int, int, int]]) -> str:
    """Phase 8 -- ``aAttackUnit``, the most destructive probe in the set.

    ``silent`` is **0**, which is what the game's own call site passes: the
    five pushes at ``0x00473191`` begin with ``push 0``, and arguments go
    right to left, so the last one is zero.

    Every probe changes the world -- a target loses hit points or dies, the
    attacker's heat and ammunition move, and the generator is drawn several
    times.  So the unit array and the seed are read after **every** call and
    the model is fed the state each probe actually started from, rather than
    the state the phase started from.
    """
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    lines = [
        "# Phase 8: aAttackUnit. Destructive; state is read after each call.",
        DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "u0 = aGetUnitMapElementPtr(0)",
        "aGetAILevel()",
        f"aGetUnitMapElementPtr(0) --read $u0:{units} --read {SEED_ADDR:#x}:8",
    ]
    for ax, ay, tx, ty in probes:
        lines += [
            f"aAttackUnit({ax}, {ay}, {tx}, {ty}, 0)",
            f"aGetUnitMapElementPtr(0) --read $u0:{units} "
            f"--read {SEED_ADDR:#x}:8",
        ]
    return "\n".join(lines) + "\n"


#: The action-point classes phase 9 writes into the probe cell.  ``docs/10``
#: §4.6: 12 is full munition, 17 is 20 equipment points, 39 is the crowbar.
#: All three exist on ``_C_141`` but none of them next to a unit, which is why
#: the class is written into a neighbour rather than the unit moved to it --
#: the same move ``docs/93`` §11 used for the large-unit clearance.
USE_CLASSES = (12, 17, 39)

#: The facing whose step is (+1, 0), from :data:`inclib.lev.FACING_STEPS`.
FACING_TO_EAST = 3


def use_plan(slot: int, cx: int, cy: int, width: int) -> str:
    """Phase 9 -- ``aExecuteUse`` over every facing, for three classes.

    ``aExecuteUse`` takes only the unit; the target is ``CellInFront``, so the
    facing byte ``+0x46`` is the whole input.  Sweeping all eight says which
    one points at the probe cell -- the convention is not documented anywhere
    in this repository as a direction, only as a rotation angle -- and the
    seven that miss are the control: they must leave the point standing.

    The phase was a recorded observation when it was taken -- there was no
    executable model of interaction to diff it against.  There is now:
    ``--check`` replays all 24 probes through :mod:`inclib.interact`, in order
    and without reloading, and compares the cell's action point, the mover's
    magazine and its equipment slots against the engine's own bytes.
    """
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    cells = width * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    ap = (f"$c0+0x{((cy * width + cx) * gold.CELL_STRIDE)
                   + gold.CELL_ACTION_POINT:x}")
    lines = [
        "# Phase 9: aExecuteUse, eight facings by three action-point classes.",
        DECLARATIONS,
        f"--code setb:{SETB_CODE}",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "c0 = aGetCtrlMapElementPtr(0,0)",
        "u0 = aGetUnitMapElementPtr(0)",
        "aGetAILevel()",
    ]
    for klass in USE_CLASSES:
        for facing in range(8):
            lines += [
                f"setb({ap}, {klass})",
                f"setb({_unit_addr(slot)}+0x46, {facing})",
                f"aExecuteUse({_unit_addr(slot)})",
                f"aGetUnitMapElementPtr(0) --read $u0:{units}",
                f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
            ]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Phase 10: aExecuteMove -- the walk, its cost, and what it leaves behind
# ---------------------------------------------------------------------------

#: The three routines a walk needs, in the order it needs them.  The fill
#: writes the gradient into ``cell[+0x0C]``, the walk marks the chosen path
#: into ``cell[+0x00]``, and only then does ``aExecuteMove`` have something to
#: follow.  ``movemap_gold.py`` declares the same three; they are repeated
#: rather than imported because a plan is one text and a declaration block is
#: how that text names its callees.
MOVE_DECLARATIONS = """\
__cdecl void aResetMoveOverlay()            = Incubation.exe+0x2ee90
__cdecl i32  aBuildMoveMap(ptr,i32,ptr,i32) = Incubation.exe+0x30a40
__cdecl i32  aWalkMoveMap(i32,i32,i32,i32,ptr,ptr) = Incubation.exe+0x305e0
__cdecl i32  aExecuteMove(i32,i32,i32,i32,ptr,i32,i32,i32) = Incubation.exe+0x6e220
"""

#: The three trailing literals, copied from the AI's own call site
#: (``0x0040AC43`` pushes eight dwords) rather than invented.
MOVE_TAIL = (1, 255, 0)

#: Seconds one attempt of this phase may take.  Every probe reloads the save
#: and then animates a walk with sound and the Charisma path, so it is the
#: slowest phase in the file by a wide margin and the one plausible hang.
MOVE_TIMEOUT = 600

#: Movement points written into the mover before the fill.  The fill spends
#: ``+0x15``, so this is what decides how far the highlight reaches; the walk
#: itself is asked for a fixed target either way.
MOVE_MP_MARGIN = 2

#: ``docs/26`` §6.1 -- the VictoryPoint band, and the value the phase writes.
#: 0x50 is *VictoryPoint A, unclaimed*: the arm under test rewrites it to
#: ``0x51 + player``, so writing 0x51 would make a no-op indistinguishable
#: from a correct capture by player 0.
VICTORY_POINT_UNCLAIMED = 0x50

#: ``cell[+0x10] == 2`` -- a mine.  ``docs/26`` §6.1.
OBSTACLE_MINE = 2

#: The field type the delay probes write.  Chosen from the control map at
#: plan time rather than hard-coded, because "which type has a delay" is a
#: property of the shipped table; this is only the fallback for a table where
#: nothing has one, and then the delay probes are skipped instead.
MOVE_DELAY_MIN, MOVE_DELAY_MAX = 1, 3


def move_probes(payload: dict[str, Any], tables: BalanceTables
                ) -> list[dict[str, Any]]:
    """One path, walked six ways.

    **Every mutation is written after the fill and after the walk**, and that
    is the whole design of the phase.  Writing a delay-bearing field type
    before the fill would change which cells are reachable and which path the
    gradient picks, so two probes would differ in two ways at once and neither
    cost could be attributed.  Written afterwards, the six probes walk the
    *identical* marked path and differ only in what ``aExecuteMove`` sees --
    which is the routine under test.

    The path is chosen by :mod:`inclib.movemap`, which is not circular: the
    model picks *what to ask*, the engine answers, and ``--check`` compares.
    It is the shortest path carrying **both** an orthogonal and a diagonal
    step, so one walk pins both base costs (1 and 2) and both distance
    increments (10 and 15) at once.
    """
    width, height = payload["width"], payload["height"]
    cells = gold.cells_of(bytes.fromhex(payload["cells"]), width, height)
    units = gold.units_of(bytes.fromhex(payload["units_before"]), tables,
                          payload["ai_level"])
    delays = tables.delay_table()

    movers = [u for u in units
              if u["player"] not in (PLAYER_PROPS, PLAYER_ALIEN)
              and u["mp_allowance"] > 0]
    if not movers:
        LOG.warning("no player-owned mover on this save; phase 10 has "
                    "nothing to walk")
        return []
    mover = movers[0]

    grid = gold.Grid(width, height, cells["height"], cells["field_type"],
                     cells["action_point"])
    hooks = gold.hooks_from_arrays(
        width, cells["unit"],
        visibility={u["slot"]: u["visibility"] for u in units},
        players={u["slot"]: u["player"] for u in units},
        obstacles=cells["obstacle"])
    mp = mover["mp_allowance"] + MOVE_MP_MARGIN
    fill = gold.build(grid, gold.Mover(
        slot=mover["slot"], x=mover["x"], y=mover["y"],
        player=mover["player"], mp=mp, special=mover["special"],
        size=mover["size"], has_jet_pack=mover["has_jet_pack"],
        mp_allowance=mover["mp_allowance"]), delays, hooks,
        pass_friendlies=False)

    chosen: tuple[int, list[tuple[int, int]]] | None = None
    for index in fill.reachable_cells():
        tx, ty = index % width, index // width
        if (tx, ty) == (mover["x"], mover["y"]):
            continue
        result = gold.walk(grid, fill, mover["x"], mover["y"], tx, ty,
                           delays, hooks)
        if not result.ok or result.blocked:
            continue
        # The engine marks the path target first; a walk reads better -- and
        # costs its steps in the right order -- source first.
        path = [(i % width, i // width) for i in reversed(list(result.path))]
        diagonal = sum(1 for a, b in zip(path, path[1:])
                       if a[0] != b[0] and a[1] != b[1])
        if diagonal == 0 or diagonal == result.steps:
            continue
        if chosen is None or result.steps < chosen[0]:
            chosen = (result.steps, path)
    if chosen is None:
        LOG.warning("no reachable path mixes an orthogonal step with a "
                    "diagonal one; phase 10 has nothing to walk")
        return []
    steps, path = chosen
    source, destination = path[0], path[-1]
    # A cell the walk steps *onto* and then leaves again.  The mine and one of
    # the delay probes need one, and a two-step path is the shortest that has
    # one at all.
    middle = path[1] if steps >= 2 else destination

    delay_type = next(
        (t for t, d in sorted(delays.items())
         if MOVE_DELAY_MIN <= d <= MOVE_DELAY_MAX), None)

    probes: list[dict[str, Any]] = [{"tag": "plain", "writes": []}]
    if delay_type is None:
        LOG.warning("no field type in the control map carries a delay in "
                    "%d..%d; the delay probes are skipped",
                    MOVE_DELAY_MIN, MOVE_DELAY_MAX)
    else:
        # Source, middle and destination separate three readings that two
        # cannot.  If only the entered cell is charged the bumps are 0/+1/+1;
        # if only the left cell is, +1/+1/0; if both, +1/+2/+1.  docs/26 §5
        # counts two field-type reads for the delay and does not say which
        # cells they are.
        for tag, cell in (("delay_source", source), ("delay_middle", middle),
                          ("delay_dest", destination)):
            probes.append({
                "tag": tag,
                "writes": [{"kind": "cell_field_type", "x": cell[0],
                            "y": cell[1], "value": delay_type}],
            })
    probes.append({
        "tag": "victory",
        "writes": [{"kind": "cell_action_point", "x": destination[0],
                    "y": destination[1], "value": VICTORY_POINT_UNCLAIMED}],
    })
    probes.append({
        "tag": "mine",
        "writes": [{"kind": "cell_obstacle", "x": middle[0], "y": middle[1],
                    "value": OBSTACLE_MINE}],
    })
    for probe in probes:
        probe.update({
            "slot": mover["slot"], "mp": mp,
            "mp_allowance": mover["mp_allowance"],
            "sx": source[0], "sy": source[1],
            "tx": destination[0], "ty": destination[1],
            "steps": steps,
            "path": [list(c) for c in path],
            "delay_type": delay_type,
        })
    return probes


def _cell_write(write: dict[str, Any], width: int) -> str:
    """The ``setb`` address for one cell mutation."""
    base = (write["y"] * width + write["x"]) * gold.CELL_STRIDE
    offset = {
        "cell_field_type": gold.CELL_FIELD_TYPE,
        "cell_action_point": gold.CELL_ACTION_POINT,
        "cell_obstacle": gold.CELL_OBSTACLE,
    }[write["kind"]]
    return f"$c0+0x{base + offset:x}"


def move_plan(probes: list[dict[str, Any]], width: int) -> str:
    """Phase 10 -- reload, fill, walk, mutate, and walk it for real.

    **Each probe reloads the save.**  A walk moves a unit, rewrites the cells
    it crossed and may detonate a mine; none of that is undone by writing the
    mutated bytes back, so reloading is the only restore that covers it.  This
    is the rule ``movemap_gold.py``'s fourth phase established.

    The unit array and the generator's seed are read **either side** of the
    call: the seed says whether the mine's shot drew at all, and reading
    ``+0x50`` before as well as after keeps a stale distance in the save from
    being mistaken for one this walk accumulated.
    """
    cells = width * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    tail = ", ".join(str(v) for v in MOVE_TAIL)
    lines = [
        "# Phase 10: aExecuteMove over one path, six times, differing only",
        "# in what is written between the walk and the call.",
        DECLARATIONS + MOVE_DECLARATIONS,
        "--buf scratch:4",
        "--buf wblocked:4",
        "--buf wsteps:4",
        "--buf ecost:4",
        f"--code setb:{SETB_CODE}",
        "",
    ]
    for i, probe in enumerate(probes):
        slot = probe["slot"]
        lines += [
            f"# probe {i}: {probe['tag']}, slot {slot} "
            f"({probe['sx']},{probe['sy']}) -> ({probe['tx']},{probe['ty']})",
            "aSetSaveMode(0)",
            f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
            "c0 = aGetCtrlMapElementPtr(0,0)",
            "u0 = aGetUnitMapElementPtr(0)",
            f"setb({_unit_addr(slot, gold.UNIT_MP)}, {probe['mp']})",
            "aResetMoveOverlay()",
            f"ue{i} = aGetUnitMapElementPtr({slot})",
            f"aBuildMoveMap($ue{i}, 0, &scratch, 0) --zero scratch",
            f"aWalkMoveMap({probe['sx']}, {probe['sy']}, {probe['tx']}, "
            f"{probe['ty']}, &wblocked, &wsteps) --zero wblocked "
            f"--zero wsteps --dump wblocked --dump wsteps",
        ]
        for write in probe["writes"]:
            lines.append(f"setb({_cell_write(write, width)}, "
                         f"{write['value']})")
        lines += [
            f"aGetUnitMapElementPtr(0) --read $u0:{units} "
            f"--read {SEED_ADDR:#x}:8",
            f"aExecuteMove({probe['sx']}, {probe['sy']}, {probe['tx']}, "
            f"{probe['ty']}, &ecost, {tail}) --zero ecost --dump ecost",
            f"aGetUnitMapElementPtr(0) --read $u0:{units} "
            f"--read {SEED_ADDR:#x}:8",
            f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
            "",
        ]
    return "\n".join(lines) + "\n"

# ---------------------------------------------------------------------------
# Phases 11..13 -- the reveals, the conversion, the platform ride
# ---------------------------------------------------------------------------

#: The unit-record bytes the probes below write or read back, beyond the
#: ones ``movemap_gold`` names.
UNIT_WEAPON = 0x3F
UNIT_MALFUNCTION = 0x40
UNIT_ABSORBER = 0x3A
#: ``+0x17``, ``+0x18`` and ``+0x53`` -- the three bytes the kill award of
#: ``docs/22`` §7.5 writes (``inclib.combat.award_kill``).
UNIT_EP = 0x17
UNIT_TP = 0x18
UNIT_KILLS = 0x53
#: Hit points written into the experience probes' victim: one, so the shot
#: that connects is a kill and the award block at ``0x0046BF53`` is entered.
EXPERIENCE_TARGET_HP = 1
#: ``+0x33`` -- equipment slot 18, the Damage Absorber, which ``0x00475590``
#: reads before it reads the charges.  Named by its origin, not its offset.
UNIT_ABSORBER_FLAG = gold.UNIT_EQUIPMENT + combatmod.EQUIP_DAMAGE_ABSORBER
UNIT_RESTED = 0x57

#: The *Enemy Move* option, the dword ``0x00460510`` returns (``docs/42``
#: §3.2).  Written one byte at a time and read back as the whole dword, so a
#: non-zero high byte cannot pass for "off".
ENEMY_MOVE_OPTION = 0x005129F4

#: Hit points written into the reveal probes' target so that a shot which
#: connects leaves a record to read: the save's alien has one point and the
#: player's rifle deals three.
PROBE_TARGET_HP = 10
#: Hit points for the conversion probe: weapon 47 deals one, and the arm at
#: ``0x0046BDC0`` needs the target alive afterwards.
CONVERSION_TARGET_HP = 2
#: Charges written into ``+0x3A`` for the absorber-gate probes -- any number
#: the shot can be seen to spend or ignore.
ABSORBER_PROBE_CHARGES = 5
#: Movement points written into the computer mover for the mode-3 probes;
#: one orthogonal step costs one.
PROBE_MOVER_MP = 3
#: Tiles the platform probe travels.  Three is the smallest shipped distance
#: and the smallest that keeps the source and destination blocks apart.
PLATFORM_PROBE_DIST = 3
#: The overlay's "movement points on arrival" is what the discard at
#: ``0x0046E357`` compares; the walk's fill supplies it.
PROBE_DECLARATIONS = """\
__cdecl i32  aRelocateUnit(i32,i32,i32,i32)        = Incubation.exe+0x7ad90
__cdecl i32  aPlayPlatformSequence(i32,i32,i32,i32) = Incubation.exe+0x12a00
"""
#: The eight neighbours, in the order a free cell next to the alien is tried.
NEIGHBOURS = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1),
              (-1, -1))

#: What ``+0x4F`` the engine must have left on the scene's human and alien,
#: per reveal probe -- the discrimination the phase exists for.  A capture on
#: which the shot revealed nobody would make "matches the model" a statement
#: about nothing, so the values are pinned.  ``mode3_off`` leaves the alien a
#: **contact**, not hidden: its own arrival pass promotes it
#: (``0x00479786``, the cluster rule inside ``aBuildVisibleMapForUnit``).
REVEAL_STATES: dict[str, tuple[int, int]] = {
    "attack_hidden": (combatmod.VISIBLE_FULL, combatmod.VISIBLE_FULL),
    "attack_jammed": (combatmod.VISIBLE_HIDDEN, combatmod.VISIBLE_HIDDEN),
    "relocate": (combatmod.VISIBLE_FULL, combatmod.VISIBLE_FULL),
    "mode3_on": (combatmod.VISIBLE_FULL, combatmod.VISIBLE_FULL),
    "mode3_off": (combatmod.VISIBLE_FULL, combatmod.VISIBLE_CONTACT),
}

#: ``aRandom``'s seed as the attack probes start: written, because
#: ``aLoadGame`` does not touch it and each probe would otherwise start from
#: the draw the one before left.  1.0 is the value after a load, and its first
#: ``aRandom(0, 100)`` is 2 -- a hit against any chance.
PROBE_SEED = 1.0
#: How many integer seeds the weapon-47 probe tries before giving up: the
#: weapon rolls the overheat table first (``0x0046B5DF``), and the seed has to
#: clear it *and* connect.
SEED_SEARCH_LIMIT = 200


def _unit_write(slot: int, offset: int, value: int) -> dict[str, int]:
    return {"slot": slot, "offset": offset, "value": value}


def _seed_write(seed: float) -> dict[str, float]:
    return {"seed": seed}


def _seed_blob(seed: float) -> tuple[str, str]:
    """The ``--blob`` name and hex of one seed value."""
    raw = struct.pack("<d", seed)
    return f"sd{raw.hex()}", raw.hex()


def conversion_seed(payload: dict[str, Any], scene: dict[str, Any],
                    tables: BalanceTables) -> float | None:
    """A seed under which the model's weapon-47 shot converts its target.

    Searched rather than chosen, because the shot draws the overheat roll
    first and then the hit roll, and both have to come out right.
    """
    for seed in range(1, SEED_SEARCH_LIMIT + 1):
        world = _world_from_capture(payload, payload["units_before"], tables)
        world.rng = ARandom(float(seed))
        human, alien = world.units[scene["human"]], world.units[scene["alien"]]
        human.weapon = combatmod.CONVERTER_WEAPON
        alien.hp = CONVERSION_TARGET_HP
        result = combatmod.attack_unit(world, human.x, human.y, alien.x, alien.y)
        if any(o.get("converted") for o in result.outcomes):
            return float(seed)
    return None


def experience_seed(payload: dict[str, Any], scene: dict[str, Any],
                    tables: BalanceTables) -> float | None:
    """A seed under which the model's shot kills the one-point alien.

    ``PROBE_SEED``'s first roll connects, but the armour subtraction can
    still leave a one-point target alive, so the seed is searched with the
    model rather than assumed.
    """
    for seed in range(1, SEED_SEARCH_LIMIT + 1):
        world = _world_from_capture(payload, payload["units_before"], tables)
        world.rng = ARandom(float(seed))
        human, alien = world.units[scene["human"]], world.units[scene["alien"]]
        alien.hp = EXPERIENCE_TARGET_HP
        combatmod.attack_unit(world, human.x, human.y, alien.x, alien.y)
        if not alien.alive:
            return float(seed)
    return None


def experience_probes(payload: dict[str, Any], scene: dict[str, Any],
                      tables: BalanceTables) -> list[dict[str, Any]]:
    """Phase 14 -- the kill award of ``docs/22`` §7.5, natively.

    No captured shot has killed anything but a case (species 2, which the
    award skips), so the three bytes it writes -- ``+0x17``, ``+0x18`` and
    ``+0x53`` -- were never seen to move.  Four probes, each a kill of the
    one-point alien: as loaded; with the shooter's experience written one
    short of what the gain would carry past 144, so ``0x0047B100`` caps and
    ``0x0047B090`` returns without touching the pool; with the pool written
    to 143, so it caps; and with the kill counter at 254, so it saturates.
    The campaign arm of ``0x0047AFD0`` is what these measure; the session
    ladder is pinned by instructions in ``combat_tables.py``.
    """
    human, alien = scene["human"], scene["alien"]
    hx, hy = scene["human_at"]
    ax, ay = scene["alien_at"]
    seed = experience_seed(payload, scene, tables)
    if seed is None:
        LOG.warning("no seed below %d kills the one-point alien; the "
                    "experience phase has no probes", SEED_SEARCH_LIMIT)
        return []
    world = _world_from_capture(payload, payload["units_before"], tables)
    exp = tables.units[world.units[alien].type_id].exp
    kill = [_unit_write(alien, gold.UNIT_HP, EXPERIENCE_TARGET_HP),
            _seed_write(seed)]
    call = [hx, hy, ax, ay]
    return [
        {"tag": "kill", "kind": "attack", "relocate": None,
         "writes": list(kill), "call": call},
        {"tag": "kill_ep_cap", "kind": "attack", "relocate": None,
         "writes": [_unit_write(human, UNIT_EP, 144 - exp + 1)] + kill,
         "call": call},
        {"tag": "kill_tp_cap", "kind": "attack", "relocate": None,
         "writes": [_unit_write(human, UNIT_TP, 143)] + kill, "call": call},
        {"tag": "kill_counter_cap", "kind": "attack", "relocate": None,
         "writes": [_unit_write(human, UNIT_KILLS, 254)] + kill, "call": call},
    ]


def _live_units(world: combatmod.CombatWorld) -> list[combatmod.CombatUnit]:
    return [u for _s, u in sorted(world.units.items()) if u.alive]


def probe_scene(payload: dict[str, Any], tables: BalanceTables
                ) -> dict[str, Any] | None:
    """The one arrangement phases 11..13 share.

    The save's aliens all stand out of the player's sight, so the routine that
    reveals a computer mover where it starts (mode 3) is unreachable as
    loaded.  Rather than write ``+0x42``/``+0x43`` and leave the map's unit
    index pointing at the old cell, the plan calls the engine's **own**
    relocation, ``0x0047AD90`` -- which is also the routine the platform ride
    uses, so the setup measures it.  The cell is chosen with the model:
    a free neighbour of the alien from which the human's pass sees the alien
    *and* the alien's pass sees the human, since mode 3 needs the second.
    """
    world = _world_from_capture(payload, payload["units_before"], tables)
    humans = [u for u in _live_units(world)
              if u.player not in (PLAYER_PROPS, PLAYER_ALIEN)]
    aliens = [u for u in _live_units(world) if u.player == PLAYER_ALIEN]
    if not humans or not aliens:
        return None
    human = humans[0]
    gate = payload.get("hit_returns") or []
    hittable = [b for i, (a, b, _w) in enumerate(payload.get("pairs") or [])
                if a == human.slot and i < len(gate) and gate[i]
                and b in {u.slot for u in aliens}]
    alien = world.units[hittable[0]] if hittable else aliens[0]
    cell: tuple[int, int] | None = None
    for ox, oy in NEIGHBOURS:
        cx, cy = alien.x + ox, alien.y + oy
        if not world.in_bounds(cx, cy) or world.unit_on(cx, cy) is not None:
            continue
        trial = _world_from_capture(payload, payload["units_before"], tables)
        trial.units[alien.slot].visibility = combatmod.VISIBLE_HIDDEN
        interactmod.relocate_unit(trial, trial.units[human.slot], cx, cy)
        if trial.units[alien.slot].visibility != combatmod.VISIBLE_FULL:
            continue
        seen = combatmod.build_visible_map_for_unit(
            trial, trial.units[alien.slot], alien.x, alien.y)
        if seen:
            cell = (cx, cy)
            break
    if cell is None:
        return None
    return {"human": human.slot, "alien": alien.slot,
            "human_at": [human.x, human.y], "alien_at": [alien.x, alien.y],
            "cell": list(cell), "player": human.player}


def _relocated_cells(payload: dict[str, Any], scene: dict[str, Any]
                     ) -> dict[str, list[int]]:
    width, height = payload["width"], payload["height"]
    cells = gold.cells_of(bytes.fromhex(payload["cells"]), width, height)
    hx, hy = scene["human_at"]
    cx, cy = scene["cell"]
    cells["unit"][hy * width + hx] = -1
    cells["unit"][cy * width + cx] = scene["human"]
    return cells


def _mode3_destination(payload: dict[str, Any], scene: dict[str, Any],
                       tables: BalanceTables) -> tuple[int, int] | None:
    """One reachable step for the alien, after the human has been moved."""
    width, height = payload["width"], payload["height"]
    cells = _relocated_cells(payload, scene)
    units = gold.units_of(bytes.fromhex(payload["units_before"]), tables,
                          payload["ai_level"])
    for u in units:
        if u["slot"] == scene["human"]:
            u["x"], u["y"] = scene["cell"]
    mover = next(u for u in units if u["slot"] == scene["alien"])
    grid = gold.Grid(width, height, cells["height"], cells["field_type"],
                     cells["action_point"])
    hooks = gold.hooks_from_arrays(
        width, cells["unit"],
        visibility={u["slot"]: u["visibility"] for u in units},
        players={u["slot"]: u["player"] for u in units},
        obstacles=cells["obstacle"])
    fill = gold.build(grid, gold.Mover(
        slot=mover["slot"], x=mover["x"], y=mover["y"],
        player=mover["player"], mp=PROBE_MOVER_MP, special=mover["special"],
        size=mover["size"], has_jet_pack=mover["has_jet_pack"],
        mp_allowance=mover["mp_allowance"]), tables.delay_table(), hooks,
        pass_friendlies=False)
    best: tuple[int, int, int] | None = None
    for index in fill.reachable_cells():
        tx, ty = index % width, index // width
        if (tx, ty) == (mover["x"], mover["y"]):
            continue
        result = gold.walk(grid, fill, mover["x"], mover["y"], tx, ty,
                           tables.delay_table(), hooks)
        if not result.ok or result.blocked:
            continue
        if best is None or result.steps < best[0]:
            best = (result.steps, tx, ty)
    if best is None:
        return None
    return best[1], best[2]


def reveal_probes(payload: dict[str, Any], scene: dict[str, Any],
                  tables: BalanceTables) -> list[dict[str, Any]]:
    """Phase 11 -- the three writers of ``+0x4F`` no earlier capture reached.

    Each probe reloads the save, writes the bytes that make the write
    observable -- both parties **hidden** first, so a 0 afterwards is the
    routine's -- and reads the whole unit array either side.  The jammed shot
    is the control: the shooter's reveal sits *after* the jam test
    (``0x0046B643``), which only a shot that jams can show.  The two mode-3
    probes differ in one dword, the *Enemy Move* option: the human going
    visible in both is the walk's passes, the alien going visible in one is
    the self-reveal at ``0x0046E4BB``.
    """
    human, alien = scene["human"], scene["alien"]
    hx, hy = scene["human_at"]
    ax, ay = scene["alien_at"]
    cx, cy = scene["cell"]
    hidden = [_unit_write(human, gold.UNIT_VISIBILITY, combatmod.VISIBLE_HIDDEN),
              _unit_write(alien, gold.UNIT_VISIBILITY, combatmod.VISIBLE_HIDDEN)]
    seeded = [_seed_write(PROBE_SEED)]
    probes: list[dict[str, Any]] = [
        {"tag": "attack_hidden", "kind": "attack", "relocate": None,
         "writes": [_unit_write(alien, gold.UNIT_HP, PROBE_TARGET_HP)]
                   + hidden + seeded,
         "call": [hx, hy, ax, ay]},
        {"tag": "attack_jammed", "kind": "attack", "relocate": None,
         "writes": [_unit_write(alien, gold.UNIT_HP, PROBE_TARGET_HP),
                    _unit_write(human, UNIT_MALFUNCTION, 2)] + hidden + seeded,
         "call": [hx, hy, ax, ay]},
        {"tag": "relocate", "kind": "relocate", "relocate": None,
         "writes": [_unit_write(alien, gold.UNIT_VISIBILITY,
                                combatmod.VISIBLE_HIDDEN)],
         "call": [hx, hy, cx, cy]},
    ]
    destination = _mode3_destination(payload, scene, tables)
    if destination is None:
        LOG.warning("no reachable step for the alien next to the relocated "
                    "human; the mode-3 probes are skipped")
        return probes
    tx, ty = destination
    for tag, option in (("mode3_on", 1), ("mode3_off", 0)):
        probes.append({
            "tag": tag, "kind": "move", "relocate": [hx, hy, cx, cy],
            "writes": [_unit_write(alien, gold.UNIT_MP, PROBE_MOVER_MP)]
                      + hidden + [{"option": option}],
            "slot": alien, "sx": ax, "sy": ay, "tx": tx, "ty": ty,
            "call": [ax, ay, tx, ty],
        })
    return probes


def conversion_probes(payload: dict[str, Any], scene: dict[str, Any],
                      tables: BalanceTables) -> list[dict[str, Any]]:
    """Phase 12 -- ``0x00475590``'s gate and weapon 47's arm, natively.

    No shipped unit carries weapon 47, so the byte is written; the target's
    hit points are set so the one point of damage leaves it alive, which is
    what the arm at ``0x0046BDC0`` requires; and the seed is one the model
    says clears the overheat roll the weapon always makes and then connects.
    The two absorber probes write the same charge count and differ only in
    ``+0x33``: the engine reads the charges behind the equipment flag, and
    the model's absorber used to read them without it.
    """
    human, alien = scene["human"], scene["alien"]
    hx, hy = scene["human_at"]
    ax, ay = scene["alien_at"]
    probes: list[dict[str, Any]] = []
    seed = conversion_seed(payload, scene, tables)
    if seed is None:
        LOG.warning("no seed below %d lets the weapon-47 shot convert; the "
                    "probe is skipped", SEED_SEARCH_LIMIT)
    else:
        probes.append(
            {"tag": "weapon47", "kind": "attack", "relocate": None,
             "writes": [_unit_write(human, UNIT_WEAPON,
                                    combatmod.CONVERTER_WEAPON),
                        _unit_write(alien, gold.UNIT_HP, CONVERSION_TARGET_HP),
                        _seed_write(seed)],
             "call": [hx, hy, ax, ay]})
    probes += [
        {"tag": "absorber_unflagged", "kind": "attack", "relocate": None,
         "writes": [_unit_write(alien, gold.UNIT_HP, PROBE_TARGET_HP),
                    _unit_write(alien, UNIT_ABSORBER, ABSORBER_PROBE_CHARGES),
                    _seed_write(PROBE_SEED)],
         "call": [hx, hy, ax, ay]},
        {"tag": "absorber_flagged", "kind": "attack", "relocate": None,
         "writes": [_unit_write(alien, gold.UNIT_HP, PROBE_TARGET_HP),
                    _unit_write(alien, UNIT_ABSORBER, ABSORBER_PROBE_CHARGES),
                    _unit_write(alien, UNIT_ABSORBER_FLAG, 1),
                    _seed_write(PROBE_SEED)],
         "call": [hx, hy, ax, ay]},
    ]
    return probes


def platform_probes(payload: dict[str, Any], scene: dict[str, Any],
                    tables: BalanceTables) -> list[dict[str, Any]]:
    """Phase 13 -- ``aPlayPlatformSequence`` with the human riding.

    The human is first relocated to a cell that can be a platform's centre:
    its 3x3 block and the block three tiles along the chosen direction both
    inside the map, and no unit on any of the eighteen cells but the rider.
    The nearest such centre to the alien is taken, so the ride ends where the
    rider's pass has something to see.  The alien is hidden first for the
    same reason as in phase 11.
    """
    width, height = payload["width"], payload["height"]
    world = _world_from_capture(payload, payload["units_before"], tables)
    human = world.units[scene["human"]]
    alien = world.units[scene["alien"]]
    best: tuple[int, int, int, int] | None = None
    for px in range(1, width - 1):
        for py in range(1, height - 1):
            for direction, (dx, dy) in sorted(interactmod.DIR_PLATFORM.items()):
                fx, fy = px + dx * PLATFORM_PROBE_DIST, py + dy * PLATFORM_PROBE_DIST
                if not (1 <= fx < width - 1 and 1 <= fy < height - 1):
                    continue
                clear = True
                for ox in (-1, 0, 1):
                    for oy in (-1, 0, 1):
                        for x, y in ((px + ox, py + oy), (fx + ox, fy + oy)):
                            occupant = world.unit_on(x, y)
                            if occupant is not None and occupant is not human:
                                clear = False
                if not clear:
                    continue
                d = abs(fx - alien.x) + abs(fy - alien.y)
                if best is None or d < best[0]:
                    best = (d, px, py, direction)
    if best is None:
        LOG.warning("no platform centre with two clear blocks; phase 13 has "
                    "nothing to ride")
        return []
    _d, px, py, direction = best
    return [{
        "tag": "ride", "kind": "platform",
        "relocate": [human.x, human.y, px, py],
        "writes": [_unit_write(alien.slot, gold.UNIT_VISIBILITY,
                               combatmod.VISIBLE_HIDDEN)],
        "call": [px, py, direction, PLATFORM_PROBE_DIST],
    }]


def _probe_write(write: dict[str, Any]) -> str:
    if "seed" in write:
        name, _hex = _seed_blob(write["seed"])
        return f"memcpy({SEED_ADDR:#x}, &{name}, 8)"
    if "option" in write:
        return gold.writeb(f"{ENEMY_MOVE_OPTION:#x}", write["option"])
    return gold.writeb(_unit_addr(write["slot"], write["offset"]),
                       write["value"])


def probe_plan(header: str, probes: list[dict[str, Any]], width: int) -> str:
    """One plan for a phase of reloading probes, phase 10's shape.

    Every probe reloads the save; its writes go through the game's own
    ``memcpy`` (:data:`movemap_gold.MEMCPY_DECL`) after any relocation; the
    unit array, the generator's seed, the option dword and the control map
    are read **either side** of the call.
    """
    cells = width * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    values: list[int] = []
    seeds: dict[str, str] = {}
    for probe in probes:
        for write in probe["writes"]:
            if "seed" in write:
                name, hex_bytes = _seed_blob(write["seed"])
                seeds[name] = hex_bytes
            else:
                values.append(write["option"] if "option" in write
                              else write["value"])
    snapshot = (f"aGetUnitMapElementPtr(0) --read $u0:{units} "
                f"--read {SEED_ADDR:#x}:8 --read {ENEMY_MOVE_OPTION:#x}:4\n"
                f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}")
    # No ``--code`` page here (``movemap_gold.MEMCPY_DECL`` says why), so
    # the ``setb`` declaration that phases 4 and 10 bind to one is left out.
    declarations = "\n".join(line for line in DECLARATIONS.splitlines()
                             if "setb" not in line)
    lines = [f"# {header}", declarations + "\n" + MOVE_DECLARATIONS
             + PROBE_DECLARATIONS + gold.MEMCPY_DECL]
    lines += gold.blob_lines(values)
    lines += [f"--blob {name}:{hex_bytes}" for name, hex_bytes in sorted(seeds.items())]
    lines += ["--buf scratch:4", "--buf wblocked:4", "--buf wsteps:4",
              "--buf ecost:4", ""]
    for i, probe in enumerate(probes):
        args = ", ".join(str(v) for v in probe["call"])
        lines += [
            f"# probe {i}: {probe['tag']} ({probe['kind']})",
            "aSetSaveMode(0)",
            f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
            "c0 = aGetCtrlMapElementPtr(0,0)",
            "u0 = aGetUnitMapElementPtr(0)",
        ]
        if probe["relocate"]:
            moved = ", ".join(str(v) for v in probe["relocate"])
            lines.append(f"aRelocateUnit({moved})")
        lines += [_probe_write(w) for w in probe["writes"]]
        if probe["kind"] == "move":
            lines += [
                "aResetMoveOverlay()",
                f"ue{i} = aGetUnitMapElementPtr({probe['slot']})",
                f"aBuildMoveMap($ue{i}, 0, &scratch, 0) --zero scratch",
                f"aWalkMoveMap({probe['sx']}, {probe['sy']}, {probe['tx']}, "
                f"{probe['ty']}, &wblocked, &wsteps) --zero wblocked "
                f"--zero wsteps --dump wblocked --dump wsteps",
            ]
        lines.append(snapshot)
        if probe["kind"] == "attack":
            lines.append(f"aAttackUnit({args}, 0)")
        elif probe["kind"] == "relocate":
            lines.append(f"aRelocateUnit({args})")
        elif probe["kind"] == "move":
            tail = ", ".join(str(v) for v in MOVE_TAIL)
            lines.append(f"aExecuteMove({args}, &ecost, {tail}) "
                         f"--zero ecost --dump ecost")
        else:
            lines.append(f"aPlayPlatformSequence({args})")
        lines += [snapshot, ""]
    return "\n".join(lines) + "\n"


#: Seconds one attempt of the platform phase may take: the ride animates for
#: ``dist * 10`` frames with sound, after a reload.
PLATFORM_TIMEOUT = MOVE_TIMEOUT

PROBE_PHASES: tuple[tuple[str, str, str], ...] = (
    ("reveal", "Phase 11: the reveals -- aAttackUnit hidden and jammed, "
               "0x0047AD90, and aExecuteMove in mode 3 with the option on "
               "and off.", "turn_reveal"),
    ("conversion", "Phase 12: weapon 47's conversion and 0x00475590's "
                   "equipment gate.", "turn_conversion"),
    ("platform", "Phase 13: aPlayPlatformSequence with a rider.",
     "turn_platform"),
    ("experience", "Phase 14: the kill award -- aAttackUnit killing the "
                   "one-point alien, with +0x17, +0x18 and +0x53 written to "
                   "reach the caps.", "turn_experience"),
)


def capture_probe_phase(game_copy: Path, dbgcall: Path, payload: dict[str, Any],
                        out: Path, key: str, header: str, name: str,
                        probes: list[dict[str, Any]], scene: dict[str, Any],
                        attempts: int) -> None:
    """Run one of phases 11..13 and merge its block into the capture."""
    rows = gold.run_plan(game_copy, dbgcall, probe_plan(header, probes,
                                                        payload["width"]),
                         name, attempts, timeout=PLATFORM_TIMEOUT)
    blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
    seeds = _reads(rows, "aGetUnitMapElementPtr", f"{SEED_ADDR:#x}")
    options = _reads(rows, "aGetUnitMapElementPtr", f"{ENEMY_MOVE_OPTION:#x}")
    cellb = _reads(rows, "aGetCtrlMapElementPtr", "$c0")
    wanted = 2 * len(probes)
    counts = {"unit dumps": len(blocks), "seeds": len(seeds),
              "options": len(options), "cell dumps": len(cellb)}
    bad = {k: n for k, n in counts.items() if n != wanted}
    if bad:
        raise GoldError(f"{name} read {counts} for {len(probes)} probe(s); "
                        f"wrong: {bad}")
    returns: dict[str, list[int]] = {}
    for call in ("aAttackUnit", "aRelocateUnit", "aExecuteMove",
                 "aPlayPlatformSequence"):
        returns[call] = _results(rows, call)
    payload[key] = {
        "scene": scene,
        "probes": probes,
        "returns": returns,
        "cost": _dumps(rows, "aExecuteMove", "ecost"),
        "walk_steps": _dumps(rows, "aWalkMoveMap", "wsteps"),
        "walk_blocked": _dumps(rows, "aWalkMoveMap", "wblocked"),
        "units_before": [b.hex() for b in blocks[0::2]],
        "units_after": [b.hex() for b in blocks[1::2]],
        "seeds_before": [b.hex() for b in seeds[0::2]],
        "seeds_after": [b.hex() for b in seeds[1::2]],
        "option_before": [b.hex() for b in options[0::2]],
        "option_after": [b.hex() for b in options[1::2]],
        "cells_before": [b.hex() for b in cellb[0::2]],
        "cells_after": [b.hex() for b in cellb[1::2]],
    }
    _write(payload, out)


# ---------------------------------------------------------------------------
# Reading a capture back
# ---------------------------------------------------------------------------

def _reads(rows: list[dict[str, Any]], call: str,
           name: str) -> list[bytes]:
    """Every ``--read`` a named call produced, in order, as raw bytes."""
    out: list[bytes] = []
    for row in rows:
        if row.get("call") != call:
            continue
        reads = row.get("reads")
        if not isinstance(reads, dict) or name not in reads:
            continue
        out.append(bytes.fromhex(reads[name].replace(" ", "")))
    return out


def _results(rows: list[dict[str, Any]], call: str) -> list[int]:
    return [int(row["result"], 0) for row in rows
            if row.get("call") == call and row.get("result") is not None]


def _dumps(rows: list[dict[str, Any]], call: str,
           name: str) -> list[int]:
    """The little-endian dword a named buffer held after each call.

    ``--dump`` and ``--read`` land in the **same** JSONL object.  ``dbgcall``
    emits one key, ``"reads"``, and fills it from its ``dumps`` vector
    (``dbgcall.cpp`` line 2640), so looking for a ``"dumps"`` key finds
    nothing -- silently, which is how an empty ``hit_percent`` once got
    written out as if the phase had succeeded.
    """
    return [int.from_bytes(raw[:4], "little")
            for raw in _reads(rows, call, name)]


def pairs_for(live: list[int],
              unit_bytes: bytes) -> list[tuple[int, int, int]]:
    """Ordered pairs of live units of **different** players, capped.

    Same-player pairs are excluded because ``aGetHitProbability``'s line of
    sight is the only part that would differ, and the fog pass already covers
    that; enemy pairs are what a shot is ever asked about.
    """
    out: list[tuple[int, int, int]] = []
    for a in live:
        for b in live:
            if a == b:
                continue
            if (_byte(unit_bytes, a, gold.UNIT_PLAYER)
                    == _byte(unit_bytes, b, gold.UNIT_PLAYER)):
                continue
            out.append((a, b, _byte(unit_bytes, a, 0x3F)))
            if len(out) >= MAX_PAIRS:
                return out
    return out


def attack_probes(payload: dict[str, Any]
                  ) -> list[tuple[int, int, int, int]]:
    """Attacker and aim cells for phase 8, chosen from phase 2's own gate.

    Only pairs the engine already reported as in range, only non-prop
    attackers, and deliberately a **mix** of hit chances: a zero-percent pair
    is as interesting as a ninety-nine, because the ``+10`` bonus is
    unconditional (``docs/22`` §7.2) so a 0 % weapon still connects on a roll
    of 0..9. A probe set that was all near-certain hits would never show that.
    """
    units = bytes.fromhex(payload["units_before"])
    simulated = payload.get("_simulated_attackers") or set()
    pairs = [tuple(x) for x in payload.get("pairs", [])]
    gate = payload.get("hit_returns") or []
    percent = payload.get("hit_percent") or []
    ranked: list[tuple[int, int, int, int, int]] = []
    for i, (a, b, _w) in enumerate(pairs):
        if i >= len(gate) or not gate[i]:
            continue
        if _byte(units, a, gold.UNIT_PLAYER) == PLAYER_PROPS:
            continue
        # Only attackers whose cover pattern the model actually simulates.
        # Eight of the sixteen families raise rather than silently marking
        # nothing (``docs/22`` §7.2), and a probe on one of those would make
        # the phase fail for a reason that is not a disagreement.
        if not simulated:
            continue
        if a not in simulated:
            continue
        ranked.append((percent[i] if i < len(percent) else 0, a, b, i, 0))
    if not ranked:
        return []
    ranked.sort(key=lambda r: -r[0])
    chosen = ranked[:ATTACK_PROBES - 1] + [ranked[-1]]
    out: list[tuple[int, int, int, int]] = []
    for _pc, a, b, _i, _z in chosen:
        out.append((_byte(units, a, gold.UNIT_X),
                    _byte(units, a, gold.UNIT_Y),
                    _byte(units, b, gold.UNIT_X),
                    _byte(units, b, gold.UNIT_Y)))
    return out


def use_probe_cell(payload: dict[str, Any]
                   ) -> tuple[int, int, int] | None:
    """A non-prop unit and a free neighbour to write an action point into.

    The neighbour must hold no unit and no action point of its own: the
    dispatch returns early on a cell with a unit on it (``docs/26`` §3, the
    push arm) and an existing class would make "did the probe consume it"
    ambiguous.
    """
    units = bytes.fromhex(payload["units_before"])
    cells = bytes.fromhex(payload["cells"])
    width, height = payload["width"], payload["height"]
    for slot in payload["live"]:
        if _byte(units, slot, gold.UNIT_PLAYER) == PLAYER_PROPS:
            continue
        ux = _byte(units, slot, gold.UNIT_X)
        uy = _byte(units, slot, gold.UNIT_Y)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                x, y = ux + dx, uy + dy
                if not (0 <= x < width and 0 <= y < height):
                    continue
                b = (y * width + x) * gold.CELL_STRIDE
                held = int.from_bytes(
                    cells[b + gold.CELL_UNIT:b + gold.CELL_UNIT + 2], "little")
                if held != 0xFFFF or cells[b + gold.CELL_ACTION_POINT]:
                    continue
                return slot, x, y
    return None


def _write(payload: dict[str, Any], out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, sort_keys=True, indent=1) + "\n",
                   encoding="utf-8")
    LOG.info("wrote %s (%d bytes)", out, out.stat().st_size)


def capture(game_copy: Path, dbgcall: Path, root: Path, out: Path,
            attempts: int) -> int:
    """Capture in phases, **writing after each one**.

    ``movemap_gold.py`` learned this the hard way and put its destructive phase
    last so its failure could not cost the three before it; the same rule
    applies here for a different reason.  Wine start-up on this host is
    intermittent (``docs/91`` §1), so any phase can lose all ten of its
    attempts to an environment that has nothing to do with the probe -- and a
    capture that threw away two phases of good data because a third never
    reached the anchor would make the retry loop pointless.  Re-running merges
    into whatever is already on disk.
    """
    repo = Path(__file__).resolve().parent.parent
    if is_within(game_copy, repo):
        raise GoldError(
            f"{game_copy} is inside this repository; the capture must run "
            f"from a copy of the game, never from gog_incubation/")
    save = game_copy / "Work" / "Saves2" / f"_{gold.CAPTURE_SLOT}_.sav"
    if not save.is_file():
        raise GoldError(f"the copy needs {save}")
    if not dbgcall.is_file():
        raise GoldError(f"no dbgcall at {dbgcall}")

    payload: dict[str, Any] = {}
    if out.is_file():
        payload = json.loads(out.read_text())
        LOG.info("merging into the existing %s", out)

    if "units_before" not in payload:
        state_rows = gold.run_plan(game_copy, dbgcall, state_plan(),
                                   "turn_state", attempts)
        unit_blocks = _reads(state_rows, "aGetUnitMapElementPtr", "$u0")
        cell_blocks = _reads(state_rows, "aGetCtrlMapElementPtr", "$c0")
        if not unit_blocks or not cell_blocks:
            raise GoldError("phase 1 produced no state")
        unit_bytes = unit_blocks[0]
        payload.update({
            "schema": CAPTURE_SCHEMA,
            "oracle": "0x004781C0, 0x004759B0, 0x0046A270 and the two height "
                      "helpers in a live Incubation.exe on _C_141",
            "source": {
                "exe_sha256": _sha256(game_copy / "Incubation.exe"),
                "save": f"Work/Saves2/_{gold.CAPTURE_SLOT}_.sav",
                "save_sha256": _sha256(save),
                "breakpoint": gold.BREAKPOINT,
            },
            "width": gold.CAPTURE_WIDTH,
            "height": gold.CAPTURE_HEIGHT,
            "ai_level": _results(state_rows, "aGetAILevel")[0],
            "cells": cell_blocks[0].hex(),
            "units_before": unit_bytes.hex(),
            "live": _live_slots(unit_bytes),
        })
        _write(payload, out)
    unit_bytes = bytes.fromhex(payload["units_before"])
    live = payload["live"]
    LOG.info("phase 1: %d live slot(s) at AI level %d -- %s",
             len(live), payload["ai_level"], live)

    # Truthiness, not presence: an earlier run that wrote the key empty must
    # re-take the phase rather than be merged past forever.
    if not payload.get("hit_percent"):
        pairs = pairs_for(live, unit_bytes)
        LOG.info("phase 2: %d ordered enemy pair(s)", len(pairs))
        if pairs:
            rows = gold.run_plan(game_copy, dbgcall,
                                 sight_plan(pairs, live, unit_bytes),
                                 "turn_sight", attempts)
            captured = {
                "pairs": [list(p) for p in pairs],
                "full_heights": _results(rows, "aGetUnitFullHeight"),
                "eye_heights": _results(rows, "aGetUnitEyeHeight"),
                "hit_returns": _results(rows, "aGetHitProbability"),
                "hit_percent": _dumps(rows, "aGetHitProbability", "hit"),
                "hit_distance": _dumps(rows, "aGetHitProbability", "dist"),
                # EAX is a plain success flag; the outcome **code** is what
                # the routine writes through its last argument (docs/22 §6.2:
                # `*out = 0xFF; ... return TRUE`).  Capturing only EAX made
                # every ray look like 1 and hid the codes entirely.
                "los_returns": _results(rows, "aCheckLineOfSightEx"),
                "los_out": _dumps(rows, "aCheckLineOfSightEx", "los"),
            }
            # A phase that extracted nothing must not be written out as if it
            # had succeeded: the merge would then skip it forever on re-run,
            # and --check would index an empty list rather than say so.  This
            # is how a wrong JSONL key stayed invisible until the gate ran.
            for key in ("hit_returns", "hit_percent", "hit_distance",
                        "los_returns", "los_out"):
                if len(captured[key]) != len(pairs):
                    raise GoldError(
                        f"phase 2 extracted {len(captured[key])} {key} for "
                        f"{len(pairs)} pair(s); the probe ran but nothing "
                        f"read it back")
            payload.update(captured)
            _write(payload, out)

    # **Every** player that owns a live unit, not just the owner of the lowest
    # live slot.  On this save that slot belongs to player 252 -- the crates --
    # whose records have no fatigue cap, no stimulant, no heat and no
    # malfunction, so a refresh over them is very nearly a no-op and would have
    # matched a model that did nothing at all.  The squad and the aliens are
    # where the routine has anything to restore.
    players = sorted({_byte(unit_bytes, slot, gold.UNIT_PLAYER)
                      for slot in live} - {PLAYER_PROPS})
    refreshes: dict[str, Any] = payload.get("refreshes") or {}
    for player in players:
        if str(player) in refreshes:
            continue
        LOG.info("phase 3: refresh for player %d", player)
        try:
            rows = gold.run_plan(game_copy, dbgcall, refresh_plan(player),
                                 f"turn_refresh_{player}", attempts)
            blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
            if len(blocks) < 2:
                raise GoldError(
                    f"phase 3 produced {len(blocks)} unit dumps, wanted 2")
            refreshes[str(player)] = {
                "before": blocks[0].hex(),
                "after": blocks[1].hex(),
            }
            payload["refreshes"] = refreshes
            _write(payload, out)
        except Exception as exc:  # noqa: BLE001 -- see the docstring
            LOG.warning("phase 3 for player %d did not complete (%s: %s); "
                        "that player's refresh stays unpinned and --check "
                        "will say so", player, type(exc).__name__, exc)

    # The recompute probe wants a unit with something to recompute.  A crate
    # has no movement allowance at all, so a sentinel overwritten with 0 on one
    # would be a weaker statement than the same sentinel overwritten with a
    # real allowance on a soldier.  Prefer a unit whose player is neither the
    # object owner nor an empty slot's default.
    real = [slot for slot in live
            if _byte(unit_bytes, slot, gold.UNIT_PLAYER) != PLAYER_PROPS]
    probe = real[0] if real else (live[0] if live else 0)

    if "units_recompute" not in payload:
        LOG.info("phase 4: lone recompute on slot %d", probe)
        try:
            rows = gold.run_plan(game_copy, dbgcall, recompute_plan(probe),
                                 "turn_recompute", attempts)
            blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
            if len(blocks) < 2:
                raise GoldError(
                    f"phase 4 produced {len(blocks)} unit dumps, wanted 2")
            payload.update({
                "probe_slot": probe,
                "units_sentinel": blocks[0].hex(),
                "units_recompute": blocks[1].hex(),
                "move_points_wanted": _results(rows, "aGetMovePoints"),
            })
            _write(payload, out)
        except Exception as exc:  # noqa: BLE001
            LOG.warning("phase 4 did not complete (%s: %s); the lone "
                        "recompute stays unpinned",
                        type(exc).__name__, exc)

    if not payload.get("rotation"):
        LOG.info("phase 5: turn state, LCL slots and %d rotation step(s)",
                 ROTATION_STEPS)
        try:
            rows = gold.run_plan(game_copy, dbgcall, rotation_plan(),
                                 "turn_rotation", attempts)
            captured = {
                "turn": _results(rows, "aGetTurn")[0],
                "player_count": _results(rows, "aGetPlayerCount")[0],
                "human_count": _results(rows, "aGetHumanCount")[0],
                "solo_flag": _results(rows, "aGetSoloFlag")[0],
                "player_kind": _results(rows, "aGetPlayerKind"),
                "end_state": _results(rows, "aGetEndState"),
                "lcl_slots": _results(rows, "aGetLclSlot"),
                "rotation": {
                    "current": _results(rows, "aGetCurrentPlayer"),
                    "previous": _results(rows, "aGetPreviousPlayer"),
                    "any_left": _results(rows, "aAnyPlayerLeftThisTurn"),
                    "advance": _results(rows, "aAdvancePlayer"),
                },
            }
            want = {"player_kind": 4, "end_state": 4, "lcl_slots": 12}
            for key, n in want.items():
                if len(captured[key]) != n:
                    raise GoldError(
                        f"phase 5 read {len(captured[key])} {key}, wanted {n}")
            if len(captured["rotation"]["advance"]) != ROTATION_STEPS:
                raise GoldError("phase 5 did not step the rotation")
            payload.update(captured)
            _write(payload, out)
        except Exception as exc:  # noqa: BLE001
            LOG.warning("phase 5 did not complete (%s: %s); the rotation "
                        "stays unpinned", type(exc).__name__, exc)

    if not payload.get("lcl"):
        LOG.info("phase 6: NEXT PLAYER through the real interpreter")
        try:
            rows = gold.run_plan(game_copy, dbgcall, lcl_plan(),
                                 "turn_lcl", attempts)
            slots = _results(rows, "aGetLclSlot")
            seeds = (_reads(rows, "aGetTurn", f"{SEED_ADDR:#x}")
                     + _reads(rows, "aGetPlayerCount", f"{SEED_ADDR:#x}"))
            cells = _reads(rows, "aGetCtrlMapElementPtr", "$c0")
            units = _reads(rows, "aGetUnitMapElementPtr", "$u0")
            if len(slots) != 24:
                raise GoldError(
                    f"phase 6 read {len(slots)} slot value(s), wanted 24")
            if len(cells) < 2 or len(units) < 2:
                raise GoldError("phase 6 did not read the world either side")
            payload["lcl"] = {
                "entry": ENTRY_NEXT_PLAYER,
                "program_id": _results(rows, "aGetMissionProgram")[0],
                "returned": _results(rows, "aRunLCL")[0],
                "slots_before": slots[:12],
                "slots_after": slots[12:],
                "cells_after": cells[-1].hex(),
                "units_after": units[-1].hex(),
                "seed_before": seeds[0].hex() if seeds else "",
                "seed_after": seeds[-1].hex() if len(seeds) > 1 else "",
            }
            _write(payload, out)
        except Exception as exc:  # noqa: BLE001
            LOG.warning("phase 6 did not complete (%s: %s); LCL execution "
                        "stays unpinned", type(exc).__name__, exc)

    if not payload.get("overheat"):
        world = _world_from_capture(payload, payload["units_before"],
                                    load_info(str(root)))
        caps = {slot: combatmod.max_heat(world, unit)
                for slot, unit in world.units.items()}
        # Not a crate.  Choosing the lowest live slot picked player 252 the
        # first time this ran -- the same accident that had the refresh
        # captured on props.
        candidates = [slot for slot, cap in sorted(caps.items())
                      if cap != 0xFF and cap >= 2
                      and world.units[slot].player != PLAYER_PROPS]
        if not candidates:
            LOG.warning("no unit on this save carries a weapon that can "
                        "overheat; phase 7 has nothing to probe")
        else:
            probe_slot = candidates[0]
            cap = caps[probe_slot]
            LOG.info("phase 7: overheat on slot %d, cap %d", probe_slot, cap)
            try:
                rows = gold.run_plan(game_copy, dbgcall,
                                     overheat_plan(probe_slot, cap),
                                     "turn_overheat", attempts)
                blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
                seeds = _reads(rows, "aGetUnitMapElementPtr",
                               f"{SEED_ADDR:#x}")
                wanted = OVERHEAT_PROBES + 2
                if len(blocks) != wanted or len(seeds) != wanted:
                    raise GoldError(
                        f"phase 7 read {len(blocks)} unit dump(s) and "
                        f"{len(seeds)} seed(s), wanted {wanted} of each")
                payload["overheat"] = {
                    "slot": probe_slot,
                    "cap": cap,
                    "returns": _results(rows, "aCheckWeaponDamage"),
                    "units": [b.hex() for b in blocks],
                    "seeds": [b.hex() for b in seeds],
                }
                _write(payload, out)
            except Exception as exc:  # noqa: BLE001
                LOG.warning("phase 7 did not complete (%s: %s); overheat "
                            "stays unpinned", type(exc).__name__, exc)

    if not payload.get("attack"):
        aworld = _world_from_capture(payload, payload["units_before"],
                                     load_info(str(root)))
        simulated = set()
        for slot, unit in aworld.units.items():
            try:
                combatmod.mark_cells(aworld, unit.weapon, unit.x, unit.y)
            except combatmod.CombatError:
                continue
            simulated.add(slot)
        payload["_simulated_attackers"] = simulated
        probes = attack_probes(payload)
        payload.pop("_simulated_attackers", None)
        LOG.info("phase 8: %d attack probe(s)", len(probes))
        if probes:
            try:
                rows = gold.run_plan(game_copy, dbgcall, attack_plan(probes),
                                     "turn_attack", attempts)
                blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
                seeds = _reads(rows, "aGetUnitMapElementPtr",
                               f"{SEED_ADDR:#x}")
                wanted = len(probes) + 1
                if len(blocks) != wanted or len(seeds) != wanted:
                    raise GoldError(
                        f"phase 8 read {len(blocks)} unit dump(s) and "
                        f"{len(seeds)} seed(s), wanted {wanted} of each")
                payload["attack"] = {
                    "probes": [list(p) for p in probes],
                    "returns": _results(rows, "aAttackUnit"),
                    "units": [b.hex() for b in blocks],
                    "seeds": [b.hex() for b in seeds],
                }
                _write(payload, out)
            except Exception as exc:  # noqa: BLE001
                LOG.warning("phase 8 did not complete (%s: %s); the shot "
                            "stays unpinned", type(exc).__name__, exc)

    if not payload.get("use"):
        spot = use_probe_cell(payload)
        if spot is None:
            LOG.warning("no free neighbour to write an action point into; "
                        "phase 9 has nowhere to probe")
        else:
            probe_slot, cx, cy = spot
            LOG.info("phase 9: aExecuteUse from slot %d onto (%d,%d)",
                     probe_slot, cx, cy)
            try:
                rows = gold.run_plan(
                    game_copy, dbgcall,
                    use_plan(probe_slot, cx, cy, payload["width"]),
                    "turn_use", attempts)
                blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
                cellb = _reads(rows, "aGetCtrlMapElementPtr", "$c0")
                wanted = len(USE_CLASSES) * 8
                # One dump per probe, on both arrays: the setup line that
                # binds $c0 carries no --read, so there is no baseline here.
                if len(blocks) != wanted or len(cellb) != wanted:
                    raise GoldError(
                        f"phase 9 read {len(blocks)} unit dump(s) and "
                        f"{len(cellb)} cell dump(s), wanted {wanted} of each")
                payload["use"] = {
                    "slot": probe_slot,
                    "cell": [cx, cy],
                    "classes": list(USE_CLASSES),
                    "returns": _results(rows, "aExecuteUse"),
                    "units": [b.hex() for b in blocks],
                    "cells": [b.hex() for b in cellb],
                }
                _write(payload, out)
            except Exception as exc:  # noqa: BLE001
                LOG.warning("phase 9 did not complete (%s: %s); interaction "
                            "stays unrecorded", type(exc).__name__, exc)

    # Last, and for the reason movemap_gold's fourth phase is last: this one
    # animates.  It is also the only phase that reloads *inside* itself, once
    # per probe, because a walk cannot be undone by writing bytes back.
    if not payload.get("move"):
        probes = move_probes(payload, load_info(str(root)))
        LOG.info("phase 10: %d aExecuteMove probe(s)", len(probes))
        if probes:
            try:
                rows = gold.run_plan(game_copy, dbgcall,
                                     move_plan(probes, payload["width"]),
                                     "turn_move", attempts,
                                     timeout=MOVE_TIMEOUT)
                blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
                seeds = _reads(rows, "aGetUnitMapElementPtr",
                               f"{SEED_ADDR:#x}")
                cellb = _reads(rows, "aGetCtrlMapElementPtr", "$c0")
                costs = _dumps(rows, "aExecuteMove", "ecost")
                walked = _dumps(rows, "aWalkMoveMap", "wsteps")
                blocked = _dumps(rows, "aWalkMoveMap", "wblocked")
                wanted = len(probes)
                counts = {"unit dumps": len(blocks) // 2,
                          "seeds": len(seeds) // 2, "cell dumps": len(cellb),
                          "costs": len(costs), "walk steps": len(walked),
                          "walk blocked": len(blocked)}
                bad = {k: n for k, n in counts.items() if n != wanted}
                if bad or len(blocks) != 2 * wanted or len(seeds) != 2 * wanted:
                    raise GoldError(
                        f"phase 10 read {counts} for {wanted} probe(s); "
                        f"wrong: {bad}")
                payload["move"] = {
                    "probes": probes,
                    "returns": _results(rows, "aExecuteMove"),
                    "cost": costs,
                    "walk_steps": walked,
                    "walk_blocked": blocked,
                    "units_before": [b.hex() for b in blocks[0::2]],
                    "units_after": [b.hex() for b in blocks[1::2]],
                    "seeds_before": [b.hex() for b in seeds[0::2]],
                    "seeds_after": [b.hex() for b in seeds[1::2]],
                    "cells_after": [b.hex() for b in cellb],
                }
                _write(payload, out)
            except Exception as exc:  # noqa: BLE001
                LOG.warning("phase 10 did not complete (%s: %s); the walk "
                            "stays unpinned", type(exc).__name__, exc)

    # Phases 11..13 share one arrangement, chosen with the model, and each
    # reloads per probe like phase 10.  The platform ride is last and alone
    # in its plan because it is the one that animates longest.
    if any(not payload.get(key) for key, _h, _n in PROBE_PHASES):
        tables = load_info(str(root))
        scene = probe_scene(payload, tables)
        if scene is None:
            LOG.warning("no human, alien and free cell between them on this "
                        "save; phases 11..13 have no scene")
        else:
            LOG.info("phases 11..13: human %d moves to %s next to alien %d",
                     scene["human"], scene["cell"], scene["alien"])
            builders = {
                "reveal": lambda: reveal_probes(payload, scene, tables),
                "conversion": lambda: conversion_probes(payload, scene, tables),
                "platform": lambda: platform_probes(payload, scene, tables),
                "experience": lambda: experience_probes(payload, scene, tables),
            }
            for key, header, name in PROBE_PHASES:
                if payload.get(key):
                    continue
                probes = builders[key]()
                LOG.info("%s: %d probe(s)", name, len(probes))
                if not probes:
                    continue
                try:
                    capture_probe_phase(game_copy, dbgcall, payload, out, key,
                                        header, name, probes, scene, attempts)
                except Exception as exc:  # noqa: BLE001
                    LOG.warning("%s did not complete (%s: %s); it stays "
                                "unpinned", name, type(exc).__name__, exc)
    return 0


# ---------------------------------------------------------------------------
# Re-expressing the capture for the GDScript side
# ---------------------------------------------------------------------------

CASES_SCHEMA = "incubation.turn-cases/1"

#: The unit columns a refresh case carries.  Every one is either an input the
#: refresh reads or an output it writes; a case that carried the whole 91-byte
#: record would invite treating the rest as validated.
CASE_UNIT_FIELDS = {
    "slot": None, "player": gold.UNIT_PLAYER, "type_id": 0x4C,
    "x": gold.UNIT_X, "y": gold.UNIT_Y, "hp": gold.UNIT_HP,
    # Every offset here is the one docs/10 section 5 records and
    # `inclib/lev.py` names.  `ep` was written 0x1B once; the native suite
    # caught it in one run, because a wrong experience value moves the fitness
    # cap and the refresh's fitness arm with it.
    "mp": gold.UNIT_MP, "fp": 0x19, "ep": 0x17, "rested": 0x57,
    "action_state": 0x41, "acted": 0x39, "ammo": 0x3D, "heat": 0x3E,
    "weapon": 0x3F, "malfunction": 0x40, "walked": 0x50,
    "turn_start_x": 0x51, "turn_start_y": 0x52, "stimulant": 0x58,
    "ticket": 0x59, "facing": 0x46, "visibility": gold.UNIT_VISIBILITY,
    "group": 0x4E,
}


def _case_unit(raw: bytes, slot: int) -> dict[str, int]:
    out: dict[str, int] = {"slot": slot}
    for name, offset in CASE_UNIT_FIELDS.items():
        if offset is None:
            continue
        out[name] = _byte(raw, slot, offset)
    return out


def emit_cases(capture_path: Path, out: Path, root: Path) -> int:
    """Re-express the capture in the shape ``godot/tests/`` reads.

    Each case carries the state the engine actually saw, so the GDScript side
    applies no mutations of its own: it builds a world from these numbers and
    compares against the numbers beside them.  That is what makes the two
    implementations receive byte-identical inputs by construction rather than
    by both following the same prose.
    """
    payload = json.loads(capture_path.read_text())
    if payload.get("schema") != CAPTURE_SCHEMA:
        raise GoldError(f"{capture_path} is not a {CAPTURE_SCHEMA} capture")

    refreshes: list[dict[str, Any]] = []
    for key in sorted(payload.get("refreshes", {}), key=int):
        block = payload["refreshes"][key]
        before = bytes.fromhex(block["before"])
        after = bytes.fromhex(block["after"])
        live = _live_slots(before)
        refreshes.append({
            "player": int(key),
            "before": [_case_unit(before, s) for s in live],
            "after": [_case_unit(after, s) for s in live],
        })
    if not refreshes:
        raise GoldError("the capture holds no refresh phase to emit")

    rot = payload.get("rotation") or {}
    document = {
        "schema": CASES_SCHEMA,
        "mission": MISSION,
        "oracle": payload.get("oracle", ""),
        "ai_level": payload["ai_level"],
        "turn": payload.get("turn", 0),
        "player_count": payload.get("player_count", 1),
        "human_count": payload.get("human_count", 1),
        "solo_flag": payload.get("solo_flag", 1),
        "player_kind": payload.get("player_kind", []),
        "end_state": payload.get("end_state", []),
        "lcl_slots": payload.get("lcl_slots", []),
        "refreshes": refreshes,
        "rotation": {
            "current": rot.get("current", []),
            "previous": rot.get("previous", []),
            "any_left": rot.get("any_left", []),
            "advance": rot.get("advance", []),
        },
        "types": _case_rows(payload, root),
        "moves": _move_cases(payload, root),
        "combat": _combat_cases(payload, root),
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(document, indent=1, sort_keys=True) + "\n",
                   encoding="utf-8")
    moves = document["moves"]
    combat_cases = document["combat"]
    LOG.info("wrote %s (%d refresh case(s), %d rotation step(s), "
             "%d move probe(s), %d hit pair(s), %d shot(s), %d use probe(s))",
             out, len(refreshes), len(document["rotation"]["advance"]),
             len(moves.get("probes", [])) if moves else 0,
             len(combat_cases.get("hit", [])),
             len((combat_cases.get("attack") or {}).get("probes", [])),
             len((combat_cases.get("use") or {}).get("probes", [])))
    return 0


def _move_cases(payload: dict[str, Any], root: Path) -> dict[str, Any]:
    """Phase 10 in the shape ``MoveMapCaseRunner.build_world`` already reads.

    One world, six probes.  The map and the unit array are emitted **once**:
    every probe starts from the same reloaded save with the same movement
    points written into the mover, and differs only in the cell bytes written
    between the walk and the call.  Repeating 400 cells six times would say
    otherwise.

    The expected values come from the engine's own answer -- the return, the
    cost it wrote through argument 5, and the unit record read back afterwards
    -- so the GDScript side is compared with the engine rather than with a
    second transcription of the same prose.
    """
    move = payload.get("move")
    if not move:
        return {}
    probes = move["probes"]
    width, height = payload["width"], payload["height"]
    cells = gold.cells_of(bytes.fromhex(payload["cells"]), width, height)
    tables = load_info(str(root))
    first = probes[0]
    # The unit array **as the probe saw it**: the plan writes the mover's
    # movement points before the fill, so the case has to carry that write
    # rather than the save's value, or the fill would spread differently.
    units = gold.units_of(bytes.fromhex(move["units_before"][0]), tables,
                          payload["ai_level"])
    first_before = bytes.fromhex(move["units_before"][0])
    records = [{
        "slot": u["slot"], "type_id": u["type_id"], "player": u["player"],
        "x": u["x"], "y": u["y"], "mp": u["mp"],
        "visibility": u["visibility"], "special": u["special"],
        "size": u["size"], "mp_allowance": u["mp_allowance"],
        "equipment_ids": u["equipment_ids"],
        # The walk's three visibility passes read and write these (docs/22
        # section 9.3), so the GDScript twin needs them to make the same
        # marks the engine's after-image holds.
        "order": _byte(first_before, u["slot"], 0x47),
        "order_param": _byte(first_before, u["slot"], 0x48),
        "order2": _byte(first_before, u["slot"], 0x49),
        "order2_param": _byte(first_before, u["slot"], 0x4A),
        "group": _byte(first_before, u["slot"], 0x4E),
    } for u in units]

    stride = gold.UNIT_STRIDE
    out: list[dict[str, Any]] = []
    for i, probe in enumerate(probes):
        before = bytes.fromhex(move["units_before"][i])
        after = bytes.fromhex(move["units_after"][i])
        at = probe["slot"] * stride
        cells_after = gold.cells_of(bytes.fromhex(move["cells_after"][i]),
                                    width, height)
        claimed = [[j, cells_after["action_point"][j]]
                   for j in range(width * height)
                   if cells_after["action_point"][j]
                   != cells["action_point"][j]]
        out.append({
            "tag": probe["tag"],
            "writes": probe["writes"],
            "expected": {
                "returns": int(bool(move["returns"][i])),
                "cost": move["cost"][i],
                "x": after[at + gold.UNIT_X],
                "y": after[at + gold.UNIT_Y],
                "walked": after[at + 0x50] - before[at + 0x50],
                "facing": after[at + 0x46],
                "mp_after": after[at + gold.UNIT_MP],
                "mp_before": before[at + gold.UNIT_MP],
                "action_points": claimed,
                # `+0x4F`, `+0x47`, `+0x48` of every live record after the
                # call -- what the three passes of docs/22 section 9.3 left.
                "records_after": [{
                    "slot": s, "visibility": _byte(after, s, 0x4F),
                    "order": _byte(after, s, 0x47),
                    "order_param": _byte(after, s, 0x48),
                } for s in payload["live"]],
            },
        })
    return {
        "name": f"{MISSION}_move",
        "width": width, "height": height,
        "cells": {k: list(v) for k, v in cells.items()},
        "delays": {str(t): d for t, d in sorted(tables.delay_table().items())},
        "units": records,
        "slot": first["slot"],
        "sx": first["sx"], "sy": first["sy"],
        "tx": first["tx"], "ty": first["ty"],
        "steps": first["steps"],
        "probes": out,
    }


#: The unit columns a combat case carries.  Every one is read by line of
#: sight, the hit curve, the damage roll, the fog pass or the reaction queue;
#: nothing else is emitted, on the same rule :data:`CASE_UNIT_FIELDS` follows.
COMBAT_UNIT_FIELDS = {
    "player": gold.UNIT_PLAYER, "type_id": 0x4C, "x": gold.UNIT_X,
    "y": gold.UNIT_Y, "hp": gold.UNIT_HP, "facing": 0x46, "fp": 0x19,
    "mp": gold.UNIT_MP, "weapon": 0x3F, "ammo": 0x3D, "heat": 0x3E,
    "malfunction": 0x40, "absorber": 0x3A, "rested": 0x57,
    "armour_front": 0x36,
    "armour_rear": 0x37, "action_state": 0x41, "acted": 0x39, "ticket": 0x59,
    "visibility": gold.UNIT_VISIBILITY, "order": 0x47, "order_param": 0x48,
    "order2": 0x49, "order2_param": 0x4A, "group": 0x4E,
    "turn_start_x": 0x51, "turn_start_y": 0x52,
    "ep": UNIT_EP, "tp": UNIT_TP, "kills": UNIT_KILLS,
}


def _combat_unit(raw: bytes, slot: int) -> dict[str, Any]:
    out: dict[str, Any] = {"slot": slot}
    for name, offset in COMBAT_UNIT_FIELDS.items():
        out[name] = _byte(raw, slot, offset)
    base = slot * gold.UNIT_STRIDE
    out["skills"] = list(raw[base + 0x1A:base + 0x20])
    out["equipment_ids"] = [i for i in range(gold.UNIT_EQUIPMENT_SLOTS)
                            if raw[base + gold.UNIT_EQUIPMENT + i]]
    return out


def _seed(hex_bytes: str) -> float:
    """The generator's eight raw bytes as the double they are.

    Emitted as a JSON **number**, not as the hex: every value the capture holds
    is ``float(int(...))`` below 2**31, so the round trip through JSON is
    exact, and a number is what ``IncRandom.seed`` takes.
    """
    return struct.unpack("<d", bytes.fromhex(hex_bytes))[0]


def _combat_cases(payload: dict[str, Any], root: Path) -> dict[str, Any]:
    """Phases 2, 7, 8 and 9 in the shape ``godot/tests/`` reads.

    One world, emitted once, and the probes beside it.  The **attack** probes
    are the exception: phase 8 does not reload between them, so each one starts
    from the world the one before it left behind, and each therefore carries
    its own unit array.  Emitting the array once and letting the GDScript side
    replay from it would compare a different experiment -- the same trap the
    hand-over cases documented from the other end.
    """
    if not payload.get("pairs"):
        return {}
    width, height = payload["width"], payload["height"]
    cells = gold.cells_of(bytes.fromhex(payload["cells"]), width, height)
    before = bytes.fromhex(payload["units_before"])
    live = list(payload["live"])

    hit: list[dict[str, Any]] = []
    los_out = payload.get("los_out") or []
    for i, (a, b, weapon) in enumerate(payload["pairs"]):
        entry = {
            "a": a, "b": b, "weapon": weapon,
            "in_range": int(payload["hit_returns"][i]),
            "percent": payload["hit_percent"][i],
            "distance": payload["hit_distance"][i],
        }
        if i < len(los_out):
            # Only the low byte: the routine writes a byte-sized code into a
            # dword buffer, so the upper three carry whatever the call before
            # it left there.
            entry["los"] = los_out[i] & 0xFF
        hit.append(entry)

    over = payload.get("overheat") or {}
    overheat: dict[str, Any] = {}
    if over:
        raw = [bytes.fromhex(h) for h in over["units"]]
        slot = over["slot"]
        overheat = {
            "slot": slot, "cap": over["cap"],
            # Probe 0 is the baseline read and probe 1 is one *below* the cap;
            # both are carried so the GDScript side can assert the gate as well
            # as the arms.
            "probes": [{
                "seed_before": _seed(over["seeds"][i - 1]),
                "seed_after": _seed(over["seeds"][i]),
                "malfunction_before": _byte(raw[i - 1], slot, 0x40),
                "malfunction_after": _byte(raw[i], slot, 0x40),
                "hp_after": _byte(raw[i], slot, gold.UNIT_HP),
                "at_the_cap": i >= 2,
            } for i in range(1, len(over["seeds"]))],
        }

    atk = payload.get("attack") or {}
    attack: dict[str, Any] = {}
    if atk:
        raw = [bytes.fromhex(h) for h in atk["units"]]
        attack = {"probes": [{
            "ax": probe[0], "ay": probe[1], "tx": probe[2], "ty": probe[3],
            "seed_before": _seed(atk["seeds"][i]),
            "seed_after": _seed(atk["seeds"][i + 1]),
            "units": [_combat_unit(raw[i], s) for s in live],
            "hp_after": [[s, _byte(raw[i + 1], s, gold.UNIT_HP)]
                         for s in live],
        } for i, probe in enumerate(atk["probes"])]}

    use = payload.get("use") or {}
    interaction: dict[str, Any] = {}
    if use:
        ux, uy = use["cell"]
        cell_off = ((uy * width + ux) * gold.CELL_STRIDE
                    + gold.CELL_ACTION_POINT)
        base = use["slot"] * gold.UNIT_STRIDE
        probes = []
        for i, klass in enumerate(use["classes"]):
            for facing in range(8):
                j = i * 8 + facing
                after_cells = bytes.fromhex(use["cells"][j])
                after_units = bytes.fromhex(use["units"][j])
                probes.append({
                    "class": klass, "facing": facing,
                    "action_point_after": after_cells[cell_off],
                    "ammo_after": after_units[base + 0x3D],
                    "equipment_after": [
                        k for k in range(gold.UNIT_EQUIPMENT_SLOTS)
                        if after_units[base + gold.UNIT_EQUIPMENT + k]],
                })
        interaction = {"cell": [ux, uy], "slot": use["slot"],
                       "classes": list(use["classes"]), "probes": probes}

    # The fog pass, per player, self-contained: the units as the refresh saw
    # them going in, and the `+0x4F` byte the engine left behind.  It is
    # emitted here rather than folded into the refresh cases because those
    # carry no map, and `aBuildVisibleMap` is nothing but a map walk.
    fog: list[dict[str, Any]] = []
    for key in sorted(payload.get("refreshes", {}), key=int):
        block = payload["refreshes"][key]
        raw_before = bytes.fromhex(block["before"])
        raw_after = bytes.fromhex(block["after"])
        slots = sorted({s for s in range(gold.UNIT_SLOTS)
                        if _byte(raw_before, s, gold.UNIT_HP)})
        fog.append({
            "player": int(key),
            "units": [_combat_unit(raw_before, s) for s in slots],
            "expect": [[s, _byte(raw_after, s, gold.UNIT_VISIBILITY)]
                       for s in slots],
        })

    # The LCL phase, for the GDScript interpreter: the same entry point, the
    # same seed, and the engine's own answers.  The mission's *world* is not
    # emitted here -- `lcl_runtime.py --emit-cases` carries `_C_141`'s -- but
    # the units the engine actually held are, because the shipped `.lev` is not
    # the world the save was taken on (ten crates and nothing else) and running
    # the model on that would take a different arm of the script.
    lcl_case: dict[str, Any] = {}
    lcl = payload.get("lcl")
    if lcl:
        lcl_case = {
            "entry": lcl["entry"],
            "player": lcl.get("player", 0),
            "turn": payload["turn"],
            "seed_before": _seed(lcl["seed_before"]),
            "seed_after": _seed(lcl["seed_after"]),
            "slots_before": list(lcl["slots_before"]),
            "slots_after": list(lcl["slots_after"]),
            # The engine's own statement that nothing moved: the cell block and
            # the unit array came back byte-identical, so the model must leave
            # them alone too.
            "world_unchanged": [lcl["cells_after"] == payload["cells"],
                                lcl["units_after"] == payload["units_before"]],
        }

    return {
        "name": f"{MISSION}_combat",
        "width": width, "height": height,
        "cells": {k: list(v) for k, v in cells.items()},
        "units": [_combat_unit(before, s) for s in live],
        "eye_heights": {str(s): h for s, h
                        in zip(live, payload.get("eye_heights") or [])},
        "full_heights": {str(s): h for s, h
                         in zip(live, payload.get("full_heights") or [])},
        # The two-vs-four-ray choice and the three-quarter damage rule both key
        # on these, and the capture is a single-player campaign.
        "human_players": payload.get("human_count", 1),
        "game_mode": 1,
        "los_mode": LOS_MODE,
        "hit": hit,
        "lcl": lcl_case,
        "fog": fog,
        "overheat": overheat,
        "attack": attack,
        "use": interaction,
        "probes": _probe_cases(payload),
    }


def _case_rows(payload: dict[str, Any], root: Path) -> dict[str, Any]:
    """Every unit and weapon row the cases reference, carried **with** them.

    The GDScript side must not reach for ``tables/balance.json``: a case whose
    unit records came from the capture and whose balance came from a separate
    file is not a byte-identical input, and a converter change could move one
    without the other.
    """
    tables = load_info(str(root))
    before = bytes.fromhex(payload["units_before"])
    type_ids: set[int] = set()
    weapon_ids: set[int] = set()
    for slot in payload["live"]:
        type_ids.add(_byte(before, slot, 0x4C))
        weapon_ids.add(_byte(before, slot, 0x3F))
    for block in payload.get("refreshes", {}).values():
        for raw_hex in (block["before"], block["after"]):
            raw = bytes.fromhex(raw_hex)
            for slot in _live_slots(raw):
                type_ids.add(_byte(raw, slot, 0x4C))
                weapon_ids.add(_byte(raw, slot, 0x3F))
    # The probe phases write a weapon id no shipped unit carries (47), so
    # their snapshots are scanned too; without its row the GDScript replay
    # fired a weapon with no heat cap and no hit rating and quietly missed.
    for key, _header, _name in PROBE_PHASES:
        for raw_hex in (payload.get(key) or {}).get("units_before", []):
            raw = bytes.fromhex(raw_hex)
            for slot in _live_slots(raw):
                type_ids.add(_byte(raw, slot, 0x4C))
                weapon_ids.add(_byte(raw, slot, 0x3F))

    units = []
    for type_id in sorted(type_ids):
        row = tables.units.get(type_id)
        if row is None:
            continue
        units.append({
            "id": type_id, "mp_max": row.mp_max, "fp_max": row.fp_max,
            "hp_max": row.hp_max, "special": row.special, "size": row.size,
            "species": row.species, "height": row.height,
            "exp": row.exp,
            "model": row.model, "description": row.description,
        })
    # The weapons a *shot* is asked about are not only the ones the live units
    # carry: phase 2's pairs name the weapon per pair, and a mine resolves as
    # weapon 36.  Missing one would make the GDScript side fall back to a
    # default row and agree with the engine for the wrong reason.
    for pair in payload.get("pairs", []):
        weapon_ids.add(pair[2])
    weapon_ids.add(combatmod.BOMB_WEAPON)

    weapons = []
    for weapon_id in sorted(weapon_ids):
        row = tables.weapons.get(weapon_id)
        if row is None:
            continue
        weapons.append({
            "id": weapon_id, "heat": row.heat, "toggle": row.toggle,
            "mun": row.mun, "hit": row.hit, "damage": row.damage,
            "range_min": row.range_min, "range_max": row.range_max,
            "type": row.type, "special": row.special,
            "def_mode": row.def_mode, "mun_per_fight": row.mun_per_fight,
        })
    return {"units": units, "weapons": weapons}


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

def _world_from_capture(payload: dict[str, Any], unit_hex: str,
                        tables: BalanceTables,
                        cells_hex: str | None = None) -> combatmod.CombatWorld:
    """A combat world from one unit dump and, by default, phase 1's cells.

    ``cells_hex`` is for the probes that read the control map either side of
    their call: a relocation moves a unit link before the snapshot, and a
    world built from phase 1's cells would put the unit back.
    """
    width, height = payload["width"], payload["height"]
    cells = bytes.fromhex(payload["cells"] if cells_hex is None else cells_hex)
    units_raw = bytes.fromhex(unit_hex)
    cell_height: list[int] = []
    unit_at: list[int] = []
    effect: list[int] = []
    action_point: list[int] = []
    field_type: list[int] = []
    for i in range(width * height):
        base = i * gold.CELL_STRIDE
        cell_height.append(int.from_bytes(
            cells[base + gold.CELL_HEIGHT:base + gold.CELL_HEIGHT + 4],
            "little", signed=True))
        slot = int.from_bytes(
            cells[base + gold.CELL_UNIT:base + gold.CELL_UNIT + 2], "little")
        unit_at.append(-1 if slot == 0xFFFF else slot)
        effect.append(cells[base + gold.CELL_OBSTACLE])
        action_point.append(cells[base + gold.CELL_ACTION_POINT])
        field_type.append(cells[base + gold.CELL_FIELD_TYPE])

    units: dict[int, combatmod.CombatUnit] = {}
    for slot in payload["live"]:
        b = slot * gold.UNIT_STRIDE
        equipment = frozenset(
            i for i in range(gold.UNIT_EQUIPMENT_SLOTS)
            if units_raw[b + gold.UNIT_EQUIPMENT + i])
        units[slot] = combatmod.CombatUnit(
            slot=slot, type_id=units_raw[b + 0x4C],
            player=units_raw[b + gold.UNIT_PLAYER],
            x=units_raw[b + gold.UNIT_X], y=units_raw[b + gold.UNIT_Y],
            hp=units_raw[b + gold.UNIT_HP], facing=units_raw[b + 0x46],
            fp=units_raw[b + 0x19], mp=units_raw[b + gold.UNIT_MP],
            weapon=units_raw[b + 0x3F], ammo=units_raw[b + 0x3D],
            heat=units_raw[b + 0x3E], malfunction=units_raw[b + 0x40],
            absorber=units_raw[b + 0x3A], rested=units_raw[b + 0x57],
            armour_front=units_raw[b + 0x36],
            armour_rear=units_raw[b + 0x37],
            action_state=units_raw[b + 0x41], visibility=units_raw[b + 0x4F],
            ep=units_raw[b + UNIT_EP], tp=units_raw[b + UNIT_TP],
            kills=units_raw[b + UNIT_KILLS],
            order=units_raw[b + 0x47], order_param=units_raw[b + 0x48],
            order2=units_raw[b + 0x49], order2_param=units_raw[b + 0x4A],
            group=units_raw[b + 0x4E], turn_start_x=units_raw[b + 0x51],
            turn_start_y=units_raw[b + 0x52],
            acted=units_raw[b + 0x39], ticket=units_raw[b + 0x59],
            skills=list(units_raw[b + 0x1A:b + 0x20]),
            equipment_ids=equipment)
    return combatmod.CombatWorld(
        width=width, height=height, cell_height=cell_height,
        unit_at=unit_at, effect_state=effect, action_point=action_point,
        field_type=field_type, units=units, tables=tables,
        ai_level=payload["ai_level"], rng=ARandom())


def _turn_units_from(payload: dict[str, Any],
                     unit_hex: str) -> list[turnmod.TurnUnit]:
    raw = bytes.fromhex(unit_hex)
    out: list[turnmod.TurnUnit] = []
    for slot in payload["live"]:
        b = slot * gold.UNIT_STRIDE
        equipment = frozenset(
            i for i in range(gold.UNIT_EQUIPMENT_SLOTS)
            if raw[b + gold.UNIT_EQUIPMENT + i])
        out.append(turnmod.TurnUnit(
            slot=slot, type_id=raw[b + 0x4C],
            player=raw[b + gold.UNIT_PLAYER], x=raw[b + gold.UNIT_X],
            y=raw[b + gold.UNIT_Y], hp=raw[b + gold.UNIT_HP],
            mp=raw[b + gold.UNIT_MP], fp=raw[b + 0x19], ep=raw[b + 0x17],
            acted=raw[b + 0x39], action_state=raw[b + 0x41],
            rested=raw[b + 0x57], walked=raw[b + 0x50],
            turn_start_x=raw[b + 0x51], turn_start_y=raw[b + 0x52],
            stimulant=raw[b + 0x58], ticket=raw[b + 0x59],
            heat=raw[b + 0x3E], malfunction=raw[b + 0x40],
            weapon=raw[b + 0x3F], equipment_ids=equipment))
    return out


def lcl_script_of(root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    """The cache document for the mission the capture was taken on."""
    name = payload.get("mission", "_C_141")
    path = Path(root) / "Missions" / f"{name}.lcl"
    if not path.is_file():
        raise GoldError(f"no {path} to compare the capture against")
    return scriptmod.script_document(lclmod.parse_file(str(path)),
                                     {"file": str(path), "mission": name})




def _use_model_checks(c: Checker, payload: dict[str, Any],
                      use: dict[str, Any], tables: BalanceTables) -> None:
    """Replay phase 9's 24 probes through :mod:`inclib.interact`.

    **The probes are sequential and this replay is too.**  ``use_plan`` loads
    the save once and then writes the class byte before every probe, so the
    *cell* is restored each time and the *unit* is not: the crowbar granted by
    the class-39 probe is still there for the ones after it.  Replaying each
    probe from the saved state would compare a different experiment.
    """
    width = payload["width"]
    ux, uy = use["cell"]
    cell_off = ((uy * width + ux) * gold.CELL_STRIDE
                + gold.CELL_ACTION_POINT)
    slot = use["slot"]
    base = slot * gold.UNIT_STRIDE
    world = _world_from_capture(payload, payload["units_before"], tables)
    unit = world.units[slot]
    at = world.index(ux, uy)

    ap_bad: list[str] = []
    ammo_bad: list[str] = []
    equip_bad: list[str] = []
    kinds: set[str] = set()
    compared = 0
    for i, klass in enumerate(use["classes"]):
        for facing in range(8):
            j = i * 8 + facing
            world.action_point[at] = klass
            unit.facing = facing
            result = interactmod.execute_use(world, unit)
            kinds.add(result.kind if result.ok else "refused")
            after_cells = bytes.fromhex(use["cells"][j])
            after_units = bytes.fromhex(use["units"][j])
            compared += 1
            if world.action_point[at] != after_cells[cell_off]:
                ap_bad.append(f"class {klass} facing {facing}: "
                              f"{world.action_point[at]} != "
                              f"{after_cells[cell_off]}")
            if unit.ammo != after_units[base + 0x3D]:
                ammo_bad.append(f"class {klass} facing {facing}: "
                                f"{unit.ammo} != {after_units[base + 0x3D]}")
            mine = sorted(unit.equipment_ids)
            theirs = sorted(
                k for k in range(gold.UNIT_EQUIPMENT_SLOTS)
                if after_units[base + gold.UNIT_EQUIPMENT + k])
            if mine != theirs:
                equip_bad.append(f"class {klass} facing {facing}: "
                                 f"{mine} != {theirs}")
    c.check("use.model_probes_replayed", compared == len(use["classes"]) * 8,
            f"{compared} probe(s)")
    c.expect("use.model_action_point_matches_native", ap_bad[:6], [])
    c.expect("use.model_ammunition_matches_native", ammo_bad[:6], [])
    c.expect("use.model_equipment_matches_native", equip_bad[:6], [])
    # Seven of every eight probes are refusals, so a model that refused
    # *everything* would agree with 21 of the 24.  This says it did not.
    c.check("use.model_reached_more_than_a_refusal", len(kinds) > 1,
            f"kinds reached: {sorted(kinds)}")
    c.check("use.model_granted_the_crowbar",
            interactmod.EQUIP_CROWBAR in unit.equipment_ids,
            "class 39 is the third of the three probed classes")


#: The record bytes the probe phases compare on every live slot: what the
#: reveals, the conversion and the ride write, plus the position and hit
#: points a shot or a ride moves.
PROBE_RECORD_FIELDS: tuple[tuple[int, str], ...] = (
    (gold.UNIT_VISIBILITY, "visibility"), (0x47, "order"),
    (0x48, "order_param"), (gold.UNIT_PLAYER, "player"),
    (gold.UNIT_MP, "mp"), (gold.UNIT_ACTION_STATE, "action_state"),
    (UNIT_ABSORBER, "absorber"), (gold.UNIT_HP, "hp"),
    (gold.UNIT_X, "x"), (gold.UNIT_Y, "y"),
    # The heat and the malfunction byte are what pin weapon 47 firing at its
    # cap and the jammed control: without them those two were a printout.
    (0x3E, "heat"), (UNIT_MALFUNCTION, "malfunction"),
    # The kill award's three bytes (docs/22 section 7.5): compared on every
    # probe, so the phases on which nothing died pin that nothing moved.
    (UNIT_EP, "ep"), (UNIT_TP, "tp"), (UNIT_KILLS, "kills"),
)


def _record_diff(world: combatmod.CombatWorld, after: bytes,
                 live: list[int]) -> list[str]:
    """Every live record's probe fields, model against the engine's image."""
    bad: list[str] = []
    for slot in live:
        rec = slot * gold.UNIT_STRIDE
        unit = world.units.get(slot)
        if unit is None or not unit.alive:
            if after[rec + gold.UNIT_HP] != 0:
                bad.append(f"slot {slot}: the model has it dead, the engine "
                           f"has hp {after[rec + gold.UNIT_HP]}")
            continue
        for offset, name in PROBE_RECORD_FIELDS:
            got = getattr(unit, name)
            if after[rec + offset] != got:
                bad.append(f"slot {slot} {name}: {got} against "
                           f"{after[rec + offset]}")
    return bad


def _flips(before: bytes, after: bytes, live: list[int]) -> list[int]:
    return [s for s in live
            if before[s * gold.UNIT_STRIDE + gold.UNIT_VISIBILITY]
            != after[s * gold.UNIT_STRIDE + gold.UNIT_VISIBILITY]]


def _dword(hex_bytes: str) -> int:
    return int.from_bytes(bytes.fromhex(hex_bytes), "little")


def _probe_returns(block: dict[str, Any]) -> list[int]:
    """The engine's return for each probe's **own** call.

    ``_results`` lists every ``aRelocateUnit`` in the plan, the setup ones
    included, so the list is walked in plan order.
    """
    names = {"attack": "aAttackUnit", "relocate": "aRelocateUnit",
             "move": "aExecuteMove", "platform": "aPlayPlatformSequence"}
    taken = {name: 0 for name in names.values()}
    out: list[int] = []
    for probe in block["probes"]:
        if probe["relocate"]:
            taken["aRelocateUnit"] += 1
        name = names[probe["kind"]]
        out.append(block["returns"][name][taken[name]])
        taken[name] += 1
    return out


def _probe_model(payload: dict[str, Any], block: dict[str, Any], i: int,
                 tables: BalanceTables
                 ) -> tuple[combatmod.CombatWorld, dict[str, Any]]:
    """Replay probe ``i`` through the models; the world it leaves, and notes."""
    probe = block["probes"][i]
    width = payload["width"]
    world = _world_from_capture(payload, block["units_before"][i], tables,
                                cells_hex=block["cells_before"][i])
    world.rng = ARandom(struct.unpack(
        "<d", bytes.fromhex(block["seeds_before"][i]))[0])
    notes: dict[str, Any] = {}
    kind = probe["kind"]
    if kind == "attack":
        ax, ay, tx, ty = probe["call"]
        result = combatmod.attack_unit(world, ax, ay, tx, ty)
        notes["fired"] = result.fired
        notes["converted"] = [o["slot"] for o in result.outcomes
                              if o.get("converted")]
    elif kind == "relocate":
        _sx, _sy, tx, ty = probe["call"]
        unit = world.unit_on(_sx, _sy)
        notes["saw"] = (unit is not None
                        and interactmod.relocate_unit(world, unit, tx, ty))
    elif kind == "move":
        before = bytes.fromhex(block["units_before"][i])
        cells = gold.cells_of(bytes.fromhex(block["cells_before"][i]), width,
                              payload["height"])
        units = gold.units_of(before, tables, payload["ai_level"])
        grid = gold.Grid(width, payload["height"], cells["height"],
                         cells["field_type"], cells["action_point"])
        hooks = gold.hooks_from_arrays(
            width, cells["unit"],
            visibility={u["slot"]: u["visibility"] for u in units},
            players={u["slot"]: u["player"] for u in units},
            obstacles=cells["obstacle"])
        row = next(u for u in units if u["slot"] == probe["slot"])
        mover = gold.Mover(
            slot=probe["slot"], x=row["x"], y=row["y"], player=row["player"],
            mp=row["mp"], special=row["special"], size=row["size"],
            has_jet_pack=row["has_jet_pack"],
            mp_allowance=row["mp_allowance"])
        delays = tables.delay_table()
        fill = gold.build(grid, mover, delays, hooks, pass_friendlies=False)
        walked = gold.walk(grid, fill, probe["sx"], probe["sy"], probe["tx"],
                           probe["ty"], delays, hooks)
        moved = movemapmod.execute(grid, hooks, delays, mover, walked)
        walker = world.units[probe["slot"]]
        option = _dword(block["option_before"][i])
        arrival = fill.mp_left[probe["ty"] * width + probe["tx"]]
        notes["seen"] = combatmod.look_before_walk(
            world, walker, probe["tx"], probe["ty"], arrival,
            enemy_move=option != 0)
        if moved.steps:
            world.unit_at[world.index(walker.x, walker.y)] = -1
            world.unit_at[world.index(moved.x, moved.y)] = walker.slot
            walker.x, walker.y, walker.facing = moved.x, moved.y, moved.facing
        combatmod.look_after_walk(world, walker)
        notes["ok"] = moved.ok
        notes["cost"] = moved.cost
        notes["steps"] = walked.steps
        notes["option"] = option
    else:
        px, py, direction, dist = probe["call"]
        notes["riders"] = interactmod.platform_ride(world, px, py, direction,
                                                    dist)
    return world, notes


def _probe_checks(c: Checker, payload: dict[str, Any], key: str,
                  block: dict[str, Any], tables: BalanceTables) -> None:
    """Phases 11..13 against the models, probe by probe.

    Two kinds of check per probe.  The **agreement** ones compare every live
    record's probe fields -- and, for the relocation and the ride, every
    cell's height, type and unit link -- with the engine's after-image.  The
    **discrimination** ones pin what the engine itself did, so that a capture
    on which a routine changed nothing cannot pass as agreement.
    """
    width, height = payload["width"], payload["height"]
    live = payload["live"]
    scene = block["scene"]
    probes = block["probes"]
    returns = _probe_returns(block)
    c.check(f"{key}.probed", len(probes) > 0, f"{len(probes)} probe(s)")
    c.expect(f"{key}.every_relocation_succeeded",
             sorted(set(block["returns"]["aRelocateUnit"])),
             [1] if block["returns"]["aRelocateUnit"] else [],
             "0x0047AD90 returns TRUE for every setup and probe call")
    moves = 0
    for i, probe in enumerate(probes):
        tag = probe["tag"]
        label = f"{key}.{tag}"
        before = bytes.fromhex(block["units_before"][i])
        after = bytes.fromhex(block["units_after"][i])
        world, notes = _probe_model(payload, block, i, tables)
        c.expect(f"{label}.records_match_native",
                 _record_diff(world, after, live), [],
                 f"{', '.join(n for _o, n in PROBE_RECORD_FIELDS)} of every "
                 f"live record after the call; notes {notes}")
        flips = _flips(before, after, live)
        if tag in REVEAL_STATES:
            human_rec = scene["human"] * gold.UNIT_STRIDE
            alien_rec = scene["alien"] * gold.UNIT_STRIDE
            c.expect(f"{label}.engine_left_human_and_alien_at",
                     (after[human_rec + gold.UNIT_VISIBILITY],
                      after[alien_rec + gold.UNIT_VISIBILITY]),
                     REVEAL_STATES[tag],
                     f"+0x4F of the human and the alien after the call "
                     f"(written 3 first, except the human of `relocate`); "
                     f"the engine changed +0x4F on {flips}")
        if probe["kind"] == "attack":
            seed_after = struct.unpack(
                "<d", bytes.fromhex(block["seeds_after"][i]))[0]
            c.check(f"{label}.seed_matches_native",
                    abs(world.rng.seed - seed_after) <= 0.5,
                    f"{world.rng.seed} against {seed_after}")
            c.expect(f"{label}.returns", returns[i], 1,
                     "aAttackUnit's BOOL, 1 for a jam as well")
        elif probe["kind"] == "relocate":
            cells_after = gold.cells_of(bytes.fromhex(block["cells_after"][i]),
                                        width, height)
            c.expect(f"{label}.unit_links_match_native", world.unit_at,
                     cells_after["unit"], "cell +0x07 of every cell")
            c.expect(f"{label}.returns", returns[i], 1)
        elif probe["kind"] == "move":
            moves += 1
            c.expect(f"{label}.returns", int(notes["ok"]), int(bool(returns[i])))
            c.expect(f"{label}.cost", notes["cost"], block["cost"][moves - 1])
            c.expect(f"{label}.walk_found_a_path", block["walk_blocked"][moves - 1],
                     0)
            intended = next(w["option"] for w in probe["writes"]
                            if "option" in w)
            c.expect(f"{label}.option_dword_reads_back", 
                     (_dword(block["option_before"][i]),
                      _dword(block["option_after"][i])),
                     (intended, intended),
                     "the whole dword at 0x005129F4, so a stale high byte "
                     "cannot pass for the value written")
            c.expect(f"{label}.drew_nothing", block["seeds_after"][i],
                     block["seeds_before"][i])
        else:
            cells_after = gold.cells_of(bytes.fromhex(block["cells_after"][i]),
                                        width, height)
            px, py, direction, dist = probe["call"]
            dx, dy = interactmod.DIR_PLATFORM[direction]
            rider = scene["human"]
            c.expect(f"{label}.cells_match_native",
                     [world.cell_height, world.field_type, world.unit_at],
                     [cells_after["height"], cells_after["field_type"],
                      cells_after["unit"]],
                     "height, field type and unit link of every cell")
            c.expect(f"{label}.the_rider_travelled",
                     (after[rider * gold.UNIT_STRIDE + gold.UNIT_X],
                      after[rider * gold.UNIT_STRIDE + gold.UNIT_Y]),
                     (px + dx * dist, py + dy * dist))
            c.expect(f"{label}.the_source_is_a_deep_hole",
                     cells_after["field_type"][py * width + px],
                     interactmod.CTRL_TYPE_DEEP_HOLE)
            c.expect(f"{label}.returns", returns[i], 1)
            # The order question: the rider's pass before the cell copy sees
            # the destination block's old heights.  Replayed the other way
            # round, does the image still agree?  Reported either way; the
            # gate above is the engine's order.
            other = _world_from_capture(payload, block["units_before"][i],
                                        tables,
                                        cells_hex=block["cells_before"][i])
            _ride_copy_first(other, px, py, direction, dist)
            # What this probe can and cannot settle. The engine's order --
            # the rider's pass **before** the cell copy -- is what
            # `cells_match_native` above is replayed with and is therefore the
            # thing the phase pins. Replaying the other way round on this
            # scene produces the same records, so the probe does **not**
            # discriminate between the two orders; asserting the agreement is
            # what it actually proves, and a literal `True` here once asserted
            # nothing at all.
            other_diff = _record_diff(other, after, live)
            c.check(f"{label}.copy_then_pass_also_agrees", not other_diff,
                    "this scene does not discriminate the two orders"
                    if not other_diff
                    else f"copy-then-pass disagrees: {other_diff[:3]}")
        if probe["kind"] == "attack" and tag == "weapon47":
            alien = scene["alien"] * gold.UNIT_STRIDE
            c.expect(f"{label}.engine_converted_the_target",
                     (after[alien + gold.UNIT_PLAYER],
                      after[alien + gold.UNIT_ACTION_STATE]),
                     (scene["player"], 0),
                     "+0x45 is the shooter's and +0x41 is cleared")
            c.expect(f"{label}.model_converted_the_same_record",
                     notes["converted"], [scene["alien"]])
        if key == "experience":
            human_rec = scene["human"] * gold.UNIT_STRIDE
            alien_rec = scene["alien"] * gold.UNIT_STRIDE
            c.expect(f"{label}.engine_killed_the_alien",
                     after[alien_rec + gold.UNIT_HP], 0)
            c.check(f"{label}.engine_moved_the_award_bytes",
                    (after[human_rec + UNIT_EP], after[human_rec + UNIT_TP],
                     after[human_rec + UNIT_KILLS])
                    != (before[human_rec + UNIT_EP], before[human_rec + UNIT_TP],
                        before[human_rec + UNIT_KILLS]),
                    f"ep {before[human_rec + UNIT_EP]} -> "
                    f"{after[human_rec + UNIT_EP]}, tp "
                    f"{before[human_rec + UNIT_TP]} -> {after[human_rec + UNIT_TP]}, "
                    f"kills {before[human_rec + UNIT_KILLS]} -> "
                    f"{after[human_rec + UNIT_KILLS]}")
            if tag == "kill_ep_cap":
                c.expect(f"{label}.engine_capped_ep_and_left_tp",
                         (after[human_rec + UNIT_EP],
                          after[human_rec + UNIT_TP] == before[human_rec + UNIT_TP]),
                         (144, True))
            if tag == "kill_tp_cap":
                c.expect(f"{label}.engine_capped_tp", after[human_rec + UNIT_TP], 144)
            if tag == "kill_counter_cap":
                c.expect(f"{label}.engine_saturated_the_counter",
                         after[human_rec + UNIT_KILLS], 255)
        if tag == "absorber_unflagged":
            alien = scene["alien"] * gold.UNIT_STRIDE
            c.check(f"{label}.engine_ignored_the_charges",
                    after[alien + gold.UNIT_HP] < before[alien + gold.UNIT_HP]
                    and after[alien + UNIT_ABSORBER] == ABSORBER_PROBE_CHARGES,
                    f"hp {before[alien + gold.UNIT_HP]} -> "
                    f"{after[alien + gold.UNIT_HP]}, charges "
                    f"{after[alien + UNIT_ABSORBER]} with +0x33 clear")
        if tag == "absorber_flagged":
            alien = scene["alien"] * gold.UNIT_STRIDE
            c.expect(f"{label}.engine_spent_one_charge",
                     (after[alien + gold.UNIT_HP], after[alien + UNIT_ABSORBER]),
                     (before[alien + gold.UNIT_HP], ABSORBER_PROBE_CHARGES - 1),
                     "the damage is nullified and +0x3A drops by one")
    if key == "conversion":
        # The phase's headline claim is weapon 47's conversion arm, and
        # :func:`conversion_probes` writes the phase anyway when
        # :func:`conversion_seed` finds no seed -- so without this the two
        # absorber probes alone would pass as a captured `conversion`.
        c.check("conversion.weapon47_probe_present",
                "weapon47" in {p["tag"] for p in probes},
                "no seed cleared the always-at-the-cap overheat roll; "
                "re-take the phase")
    if key == "reveal":
        c.check("reveal.mode3_probes_present",
                {"mode3_on", "mode3_off"} <= {p["tag"] for p in probes},
                "both option settings were walked")


def _ride_copy_first(world: combatmod.CombatWorld, x: int, y: int,
                     direction: int, dist: int) -> None:
    """The ride with the cell copy **before** the riders' passes -- the order
    the interpreters use on the script world, replayed to report whether the
    capture can tell the two apart."""
    dx, dy = interactmod.DIR_PLATFORM[direction]
    dx, dy = dx * dist, dy * dist
    block = [(x + ox, y + oy) for ox in (-1, 0, 1) for oy in (-1, 0, 1)]
    riders = [world.unit_on(sx, sy) for sx, sy in block
              if world.in_bounds(sx, sy)]
    for sx, sy in block:
        tx, ty = sx + dx, sy + dy
        if not (world.in_bounds(sx, sy) and world.in_bounds(tx, ty)):
            continue
        src, dst = world.index(sx, sy), world.index(tx, ty)
        world.cell_height[dst] = world.cell_height[src]
        world.field_type[dst] = world.field_type[src]
        world.field_type[src] = interactmod.CTRL_TYPE_DEEP_HOLE
    for rider in riders:
        if rider is not None:
            interactmod.relocate_unit(world, rider, rider.x + dx, rider.y + dy)


def _probe_cases(payload: dict[str, Any]) -> dict[str, Any]:
    """Phases 11..13 in the shape ``test_combat_native.gd`` replays.

    Every probe reloads and writes, so each carries its own unit array **and**
    its own cell arrays -- the relocation moves a unit link before the
    snapshot -- and the engine's after-image as the expectation.
    """
    width, height = payload["width"], payload["height"]
    out: dict[str, Any] = {}
    for key, _header, _name in PROBE_PHASES:
        block = payload.get(key)
        if not block:
            continue
        returns = _probe_returns(block)
        cases: list[dict[str, Any]] = []
        moves = 0
        for i, probe in enumerate(block["probes"]):
            before = bytes.fromhex(block["units_before"][i])
            after = bytes.fromhex(block["units_after"][i])
            cells = gold.cells_of(bytes.fromhex(block["cells_before"][i]),
                                  width, height)
            cells_after = gold.cells_of(bytes.fromhex(block["cells_after"][i]),
                                        width, height)
            case: dict[str, Any] = {
                "tag": probe["tag"], "kind": probe["kind"],
                "call": list(probe["call"]),
                "option": _dword(block["option_before"][i]),
                "seed_before": _seed(block["seeds_before"][i]),
                "seed_after": _seed(block["seeds_after"][i]),
                "cells": {k: list(v) for k, v in cells.items()},
                "units": [_combat_unit(before, s) for s in payload["live"]],
                "expected": {
                    "returns": returns[i],
                    "records_after": [dict(
                        {"slot": s},
                        **{name: _byte(after, s, offset)
                           for offset, name in PROBE_RECORD_FIELDS})
                        for s in payload["live"]],
                    "cells_after": {k: list(cells_after[k])
                                    for k in ("height", "field_type", "unit")},
                },
            }
            if probe["kind"] == "move":
                case["move"] = {"slot": probe["slot"], "sx": probe["sx"],
                                "sy": probe["sy"], "tx": probe["tx"],
                                "ty": probe["ty"],
                                "steps": block["walk_steps"][moves]}
                case["expected"]["cost"] = block["cost"][moves]
                moves += 1
            cases.append(case)
        out[key] = {"scene": block["scene"], "probes": cases}
    return out


def run_check(capture_path: Path, root: Path) -> int:
    c = Checker()
    payload = json.loads(capture_path.read_text())
    c.expect("capture.schema", payload.get("schema"), CAPTURE_SCHEMA)
    tables = load_info(str(root))

    # --- line of sight and hit probability --------------------------------
    if payload.get("pairs"):
        world = _world_from_capture(payload, payload["units_before"], tables)
        pairs = [tuple(p) for p in payload["pairs"]]
        want_percent = payload["hit_percent"]
        want_distance = payload["hit_distance"]
        want_return = payload["hit_returns"]
        percent_bad: list[str] = []
        distance_bad: list[str] = []
        gate_bad: list[str] = []
        for i, (a, b, weapon) in enumerate(pairs):
            att, dfn = world.units[a], world.units[b]
            got = combatmod.hit_probability(world, att, dfn, weapon)
            if got.distance != want_distance[i]:
                distance_bad.append(
                    f"{a}->{b}: {got.distance} != {want_distance[i]}")
            if got.percent != want_percent[i]:
                percent_bad.append(
                    f"{a}->{b}: {got.percent} != {want_percent[i]}")
            if int(got.in_range) != want_return[i]:
                gate_bad.append(f"{a}->{b}: {got.in_range} != {want_return[i]}")
        c.check("hit.pairs_captured", bool(pairs), f"{len(pairs)} pair(s)")
        c.expect("hit.distance_matches_native", distance_bad[:5], [])
        c.expect("hit.range_gate_matches_native", gate_bad[:5], [])
        c.expect("hit.percent_matches_native", percent_bad[:5], [])

        heights = payload.get("full_heights") or []
        c.check("heights.captured", bool(heights),
                f"{len(heights)} fullHeight call(s)")

        # Line of sight on its own, over the same ordered pairs.  The eye
        # height is the source and the full height is the target, which is
        # asymmetric -- so the ordered list exercises both directions.
        # The outcome is the **out-parameter**, not the return value.  EAX is
        # a success flag that is 1 for a clear ray and 1 for a blocked one
        # alike (docs/22 §6.2), so comparing the model against it made every
        # disagreement look like the model was wrong about everything.
        want_los = payload.get("los_out") or []
        want_flag = payload.get("los_returns") or []
        c.check("los.captured", len(want_los) == len(pairs),
                f"{len(want_los)} ray(s) for {len(pairs)} pair(s)")
        c.expect("los.return_is_a_success_flag",
                 sorted(set(want_flag)), [1],
                 "docs/22 section 6.2: the routine returns TRUE and reports "
                 "through its last argument")
        los_bad: list[str] = []
        eye = dict(zip(payload["live"], payload["eye_heights"]))
        full = dict(zip(payload["live"], payload["full_heights"]))
        for i, (a, b, _w) in enumerate(pairs[:len(want_los)]):
            att, dfn = world.units[a], world.units[b]
            got = combatmod.check_line_of_sight_ex(
                world, att.x, att.y, eye[a], dfn.x, dfn.y, full[b], LOS_MODE)
            # Only the low byte: the buffer is a dword and the routine writes
            # a byte-sized code into it, so the upper three carry whatever the
            # previous call left there.
            if got != (want_los[i] & 0xFF):
                los_bad.append(f"{a}->{b}: {got} != {want_los[i] & 0xFF}")
        c.expect("los.matches_native", los_bad[:5], [])

    # --- the refresh, once per player that owns a live unit ---------------
    refreshes = payload.get("refreshes") or {}
    if not refreshes:
        # Not a pass and not a silent skip: the capture is incomplete, and a
        # check that examined nothing is not a check that passed.
        c.check("refresh.captured", False,
                "the capture holds no refresh phase; re-run --game-copy, and "
                "expect the anchor to need several attempts (docs/91 section 1)")
        return c.report()

    fields = {"mp": gold.UNIT_MP, "fp": 0x19, "acted": 0x39,
              "action_state": 0x41, "rested": 0x57, "walked": 0x50,
              "turn_start_x": 0x51, "turn_start_y": 0x52,
              "stimulant": 0x58, "ticket": 0x59, "heat": 0x3E,
              "malfunction": 0x40, "weapon": 0x3F}
    for key in sorted(refreshes, key=int):
        player = int(key)
        c.expect(f"refresh.p{player}.is_a_rotation_member",
                 player != PLAYER_PROPS, True,
                 "docs/25 section 7: 252 is never stored in the current-player "
                 "byte, so the engine never passes it here")
        before_hex = refreshes[key]["before"]
        after_raw = bytes.fromhex(refreshes[key]["after"])
        before_raw = bytes.fromhex(before_hex)
        before = _turn_units_from(payload, before_hex)
        state = turnmod.TurnState(turn=1, current_player=player,
                                  ai_level=payload["ai_level"])
        world = _world_from_capture(payload, before_hex, tables)

        def banner_of(unit: turnmod.TurnUnit, _w: Any = world) -> bool:
            return combatmod.banner_nearby(_w, _w.units[unit.slot])

        turnmod.refresh_player(state, player, before, tables, banner_of)

        mismatches: list[str] = []
        compared = 0
        owned = 0
        for unit in before:
            if unit.player != player:
                continue
            owned += 1
            b = unit.slot * gold.UNIT_STRIDE
            for name, offset in fields.items():
                compared += 1
                got, want = getattr(unit, name), after_raw[b + offset]
                if got != want:
                    mismatches.append(
                        f"slot {unit.slot} {name}: {got} != {want}")
        c.check(f"refresh.p{player}.fields_compared", compared > 0,
                f"{compared} comparison(s) over {owned} owned record(s)")
        c.expect(f"refresh.p{player}.matches_native", mismatches[:8], [])

        # The other half of acceptance item 4: the refresh is for *one*
        # player, so every record that does not belong to it has to come back
        # untouched -- comparing only the refreshed player would pass a
        # routine that quietly rewrote the other slots.
        #
        # With one documented exception, found by asserting the strict form
        # first.  ``+0x4F`` **does** change on foreign records, because
        # 0x004781C0 runs the fog pass and that is where an enemy is marked
        # visible, hidden or a contact *for the refreshing player*.  So the
        # strict invariance holds for every other offset, and ``+0x4F`` gets a
        # check of its own below -- the aBuildVisibleMap row of the oracle
        # table, captured here for free rather than in a phase of its own.
        foreign: list[str] = []
        foreign_slots = 0
        for slot in range(gold.UNIT_SLOTS):
            b = slot * gold.UNIT_STRIDE
            if _byte(before_raw, slot, gold.UNIT_PLAYER) == player:
                continue
            foreign_slots += 1
            offsets = [f"+0x{i:02X}"
                       for i in range(gold.UNIT_STRIDE)
                       if before_raw[b + i] != after_raw[b + i]
                       and i != gold.UNIT_VISIBILITY]
            if offsets:
                foreign.append(f"slot {slot}: {', '.join(offsets)}")
        c.check(f"refresh.p{player}.foreign_slots_examined", foreign_slots > 0,
                f"{foreign_slots} record(s) outside player {player}")
        c.expect(f"refresh.p{player}.touches_only_visibility_elsewhere",
                 foreign[:8], [])

        # --- the fog pass, pinned natively -------------------------------
        fog = _world_from_capture(payload, before_hex, tables)
        combatmod.build_visible_map(fog, player)
        fog_bad: list[str] = []
        fog_compared = 0
        for slot, unit in sorted(fog.units.items()):
            fog_compared += 1
            want = after_raw[slot * gold.UNIT_STRIDE + gold.UNIT_VISIBILITY]
            if unit.visibility != want:
                fog_bad.append(f"slot {slot}: {unit.visibility} != {want}")
        c.check(f"fog.p{player}.slots_compared", fog_compared > 0,
                f"{fog_compared} visibility byte(s)")
        c.expect(f"fog.p{player}.matches_native", fog_bad[:8], [])

    # --- the rotation and the twelve game-control slots -------------------
    rot = payload.get("rotation")
    if not rot:
        c.check("rotation.captured", False,
                "the capture holds no rotation phase; re-run --game-copy")
        return c.report()

    # The turn counter is an *input* to the rotation, not something the model
    # derives, so there is nothing to compare it against -- what matters is
    # that it is non-zero, because `g_turn == 0` disables the whole skip rule
    # (docs/25 section 3.1) and a capture taken at turn 0 would exercise none
    # of it.
    c.check("state.turn_is_past_the_first_handover", payload["turn"] > 0,
            f"turn {payload['turn']}, so the skip rule is live")
    c.expect("state.lcl_slots_captured", len(payload["lcl_slots"]), 12,
             "0x0043B160 reads [eax*4 + 0x509f18] after rejecting an index of "
             "12 or more -- docs/20 section 7's twelve slots")

    state = turnmod.TurnState(
        turn=payload["turn"],
        current_player=rot["current"][0],
        previous_player=rot["previous"][0],
        player_count=payload["player_count"],
        player_kind=list(payload["player_kind"]),
        end_state=list(payload["end_state"]),
        solo_flag=bool(payload["solo_flag"]),
        ai_level=payload["ai_level"],
    )
    c.expect("state.human_count_matches_native",
             state.human_count(), payload["human_count"])

    # The live-unit count the skip rule consults, straight off phase 1's dump.
    before_units = bytes.fromhex(payload["units_before"])

    def live_units(player: int) -> int:
        return sum(1 for slot in payload["live"]
                   if _byte(before_units, slot, gold.UNIT_PLAYER) == player)

    rot_bad: list[str] = []
    for i in range(len(rot["advance"])):
        if state.current_player != rot["current"][i]:
            rot_bad.append(
                f"step {i} current: {state.current_player} != "
                f"{rot['current'][i]}")
        if state.previous_player != rot["previous"][i]:
            rot_bad.append(
                f"step {i} previous: {state.previous_player} != "
                f"{rot['previous'][i]}")
        got_left = turnmod.any_player_left_this_turn(state, live_units)
        if int(got_left) != rot["any_left"][i]:
            rot_bad.append(
                f"step {i} any_left: {int(got_left)} != {rot['any_left'][i]}")
        got_adv = turnmod.advance_player(state, live_units)
        if int(got_adv) != rot["advance"][i]:
            rot_bad.append(
                f"step {i} advance: {int(got_adv)} != {rot['advance'][i]}")
    c.check("rotation.steps_compared", len(rot["advance"]) > 0,
            f"{len(rot['advance'])} step(s)")
    c.expect("rotation.matches_native", rot_bad[:8], [])
    c.expect("rotation.final_player_matches_native",
             [state.current_player, state.previous_player],
             [rot["current"][-1], rot["previous"][-1]])

    # A rotation that never moved would agree with a model that never moved.
    c.check("rotation.is_not_stationary", len(set(rot["current"])) > 1,
            f"visits {sorted(set(rot['current']))}")

    # --- LCL: one NEXT PLAYER through the real interpreter ----------------
    lcl = payload.get("lcl")
    if not lcl:
        c.check("lcl.captured", False,
                "the capture holds no LCL phase; re-run --game-copy")
        return c.report()

    c.expect("lcl.program_returned_ok", lcl["returned"], 1,
             f"aRunLCL({lcl['program_id']}) -- the mission program is loaded "
             f"and ran to its end")
    c.expect("lcl.slots_match_native", lcl["slots_after"], lcl["slots_before"],
             "NEXT PLAYER on this save writes no game-control slot")

    # The generator is the sharp part.  Two SetVarRandom in _C_141's script,
    # and the engine's seed advances by exactly two draws -- which pins the
    # arithmetic *and* says the interpreter reached both of them.
    seed_before = struct.unpack("<d", bytes.fromhex(lcl["seed_before"]))[0]
    seed_after = struct.unpack("<d", bytes.fromhex(lcl["seed_after"]))[0]
    c.check("lcl.seed_was_drawn", seed_before != seed_after,
            f"{seed_before} -> {seed_after}")
    rng = ARandom(seed_before)
    draws = 0
    while draws < 16 and rng.seed != seed_after:
        rng.raw(0, 1)
        draws += 1
    c.expect("lcl.seed_after_matches_native", rng.seed, seed_after,
             f"reached in {draws} draw(s) of ARandom from {seed_before}")

    # Everything above is native-only.  This is where the *model* is run: the
    # same entry point, on the shipped mission, seeded with what the engine
    # actually held -- and it has to draw the generator the same number of
    # times and leave the same slots alone.  Without it the block would pin
    # ARandom and the engine, and say nothing about inclib/lcl_runtime.py.
    script = lcl_script_of(root, payload)
    bm = levmod.load_lev(str(Path(root) / "Missions" / f"{MISSION}.lev"))
    world = lclmodrt.LclWorld(bm, tables, turn=payload["turn"],
                              player=lcl.get("player", 0),
                              ai_level=payload["ai_level"],
                              seed=seed_before)
    world.object_cells = footprintmod.index_for_mission(root, bm)
    # **The shipped .lev is not the world the engine ran on.** _C_141 ships
    # with ten crates and nothing else -- the squad and the aliens exist only
    # in the save. Left as loaded, GetUnits(player 0) answers 0 here and 1
    # there, and the script's "squad wiped out" arm fires in the model and not
    # in the engine. Comparing those would have reported a model bug that is
    # really a different world.
    units_raw = bytes.fromhex(payload["units_before"])
    world.units = {}
    for slot in payload["live"]:
        b = slot * gold.UNIT_STRIDE
        world.units[slot] = lclmodrt.RuntimeUnit(
            slot=slot,
            player=units_raw[b + gold.UNIT_PLAYER],
            type_id=units_raw[b + 0x4C],
            x=units_raw[b + gold.UNIT_X],
            y=units_raw[b + gold.UNIT_Y],
            hit_points=units_raw[b + gold.UNIT_HP],
            group=units_raw[b + 0x4E],
            ammo=units_raw[b + 0x3D])
    world.unit_at = [-1] * (payload["width"] * payload["height"])
    for slot, unit in world.units.items():
        if 0 <= unit.x < payload["width"] and 0 <= unit.y < payload["height"]:
            world.unit_at[unit.y * payload["width"] + unit.x] = slot
    # The environment is indexed from zero: the engine's setter is
    # `letter - 'A'` (0x004402A0), so _A is slot 0, not ord('A').
    outcome = lclmodrt.run(script, world, {0: lcl["entry"],
                                           1: payload["turn"],
                                           2: lcl.get("player", 0)})
    c.expect("lcl.model_runs_to_the_end", outcome.ok, True,
             f"{outcome.kind}: {outcome.reason or 'no abort'}")
    c.expect("lcl.model_draws_match_native", world.rng.calls, draws,
             f"the model drew {world.rng.calls} time(s); the engine's seed "
             f"advanced {draws}")
    c.expect("lcl.model_seed_matches_native", world.rng.seed, seed_after)
    c.expect("lcl.model_writes_no_slot", world.game_control,
             list(lcl["slots_after"]))

    # Nothing the script did is visible in the world it ran on.
    c.expect("lcl.world_unchanged_natively",
             [lcl["cells_after"] == payload["cells"],
              lcl["units_after"] == payload["units_before"]],
             [True, True],
             "the NEXT PLAYER path on this save places nothing and moves "
             "nothing, so InsertUnit never fires and the MSVC generator it "
             "would draw from is not exercised")

    # --- overheat: the gate, the roll and the four arms -------------------
    over = payload.get("overheat")
    if not over:
        c.check("overheat.captured", False,
                "the capture holds no overheat phase; re-run --game-copy")
        return c.report()

    # A CombatWorld of its own: `world` is the LclWorld from the block above,
    # and reusing that name would silently hand this one a unit record with no
    # weapon field.
    over_world = _world_from_capture(payload, over["units"][0], tables)
    over_seeds = [struct.unpack("<d", bytes.fromhex(h))[0]
                  for h in over["seeds"]]
    over_units = [bytes.fromhex(h) for h in over["units"]]
    ob = over["slot"] * gold.UNIT_STRIDE
    c.expect("overheat.probe_is_not_a_prop",
             _byte(over_units[0], over["slot"], gold.UNIT_PLAYER)
             != PLAYER_PROPS, True)
    # Probe 0 is the baseline read, probe 1 is one *below* the cap: the gate.
    c.expect("overheat.gate_holds_below_the_cap",
             [over_seeds[1] == over_seeds[0],
              over_units[1][ob + 0x40] == over_units[0][ob + 0x40]],
             [True, True],
             "one below the cap draws nothing and writes nothing")

    over_bad: list[str] = []
    arms: set[str] = set()
    for i in range(2, len(over_seeds)):
        rng = ARandom(over_seeds[i - 1])
        roll = rng(0, combatmod.OVERHEAT_SPAN)
        if abs(rng.seed - over_seeds[i]) > 0.5:
            over_bad.append(f"probe {i}: seed {rng.seed} != {over_seeds[i]}")
            continue
        probe = over_world.units[over["slot"]]
        probe.heat = over["cap"]
        probe.malfunction = over_units[i - 1][ob + 0x40]
        over_world.rng = ARandom(over_seeds[i - 1])
        arms.add(combatmod.check_weapon_damage(over_world, probe))
        want = over_units[i][ob + 0x40]
        if probe.malfunction != want:
            over_bad.append(
                f"probe {i}: roll {roll} -> +0x40 "
                f"{probe.malfunction} != {want}")
    c.check("overheat.probes_compared", len(over_seeds) > 2,
            f"{len(over_seeds) - 2} at-the-cap probe(s)")
    c.expect("overheat.matches_native", over_bad[:6], [])
    c.check("overheat.reached_more_than_one_arm", len(arms) > 1,
            f"arms reached: {sorted(arms)}")

    # --- the shot: aAttackUnit, probe by probe ----------------------------
    atk = payload.get("attack")
    if not atk:
        c.check("attack.captured", False,
                "the capture holds no attack phase; re-run --game-copy")
        return c.report()

    atk_seeds = [struct.unpack("<d", bytes.fromhex(h))[0]
                 for h in atk["seeds"]]
    atk_units = [bytes.fromhex(h) for h in atk["units"]]
    hp_bad: list[str] = []
    seed_bad: list[str] = []
    fired_bad: list[str] = []
    kills = 0
    for i, (ax, ay, tx, ty) in enumerate(atk["probes"]):
        # Each probe starts from the world the one before it left behind.
        before = _world_from_capture(payload, atk["units"][i], tables)
        before.rng = ARandom(atk_seeds[i])
        got = combatmod.attack_unit(before, ax, ay, tx, ty)
        # The BOOL is **not** "did it fire": it comes back 1 for a jam too,
        # and 0 was only ever seen when the attacker was already dead. So the
        # model's `fired` is compared against the world and the generator
        # below, and the return value gets the one assertion it can carry.
        if atk["returns"][i] not in (0, 1):
            fired_bad.append(f"probe {i}: return {atk['returns'][i]}")
        if abs(before.rng.seed - atk_seeds[i + 1]) > 0.5:
            seed_bad.append(
                f"probe {i}: seed {before.rng.seed} != {atk_seeds[i + 1]}")
        after = atk_units[i + 1]
        for slot in payload["live"]:
            want = _byte(after, slot, gold.UNIT_HP)
            unit = before.units.get(slot)
            mine = 0 if unit is None else unit.hp
            if mine != want:
                hp_bad.append(f"probe {i} slot {slot}: {mine} != {want}")
            if want == 0 and _byte(atk_units[i], slot, gold.UNIT_HP):
                kills += 1
    c.check("attack.probes_compared", len(atk["probes"]) > 0,
            f"{len(atk['probes'])} probe(s)")
    c.expect("attack.return_is_boolean", fired_bad[:6], [])
    c.expect("attack.seed_matches_native", seed_bad[:6], [])
    c.expect("attack.hit_points_match_native", hp_bad[:8], [])
    c.check("attack.something_actually_died", kills > 0,
            f"{kills} unit(s) killed across the probes")
    # The probe set must contain a shot that connects *and* one that does not,
    # or "matches native" would only ever have exercised one arm.
    outcomes = []
    for i, (ax, ay, tx, ty) in enumerate(atk["probes"]):
        w = _world_from_capture(payload, atk["units"][i], tables)
        w.rng = ARandom(atk_seeds[i])
        outcomes.append(combatmod.attack_unit(w, ax, ay, tx, ty))
    markers = {o["marker"] for r in outcomes for o in r.outcomes}
    c.check("attack.reached_a_hit_and_a_miss",
            combatmod.MARKER_MISS in markers and len(markers) > 1,
            f"markers seen: {sorted(markers)}")
    c.check("attack.overheat_was_exercised_inside_the_shot",
            any(r.overheat != combatmod.OVERHEAT_NONE for r in outcomes),
            f"{sum(1 for r in outcomes if r.overheat != combatmod.OVERHEAT_NONE)}"
            f" probe(s) rolled the weapon")

    # --- interaction: recorded, not gated --------------------------------
    use = payload.get("use")
    if not use:
        c.check("use.captured", False,
                "the capture holds no interaction phase; re-run --game-copy")
        return c.report()

    width = payload["width"]
    ux, uy = use["cell"]
    cell_off = (uy * width + ux) * gold.CELL_STRIDE + gold.CELL_ACTION_POINT
    sl = use["slot"] * gold.UNIT_STRIDE
    consumed: dict[int, list[int]] = {}
    zero_returns: list[int] = []
    for i, klass in enumerate(use["classes"]):
        for facing in range(8):
            j = i * 8 + facing
            after = bytes.fromhex(use["cells"][j])
            if after[cell_off] != klass:
                consumed.setdefault(klass, []).append(facing)
            if i == 0 and use["returns"][j] == 0:
                zero_returns.append(facing)
    c.check("use.classes_probed", len(use["classes"]) > 0,
            f"{len(use['classes'])} class(es) x 8 facings")
    c.expect("use.exactly_one_facing_consumes_the_point",
             {k: v for k, v in consumed.items() if len(v) != 1}, {},
             "the other seven are the control: they must leave it standing")
    c.expect("use.the_same_facing_every_time",
             sorted({tuple(v) for v in consumed.values()}),
             [(FACING_TO_EAST,)])

    # The convention this settles: FACING_ANGLES gives a rotation, not a
    # direction.  Taking 0 degrees as +y makes 2, 4 and 7 the facings with a
    # -y step -- and the probe unit stands on the top row, so those are
    # exactly the ones whose CellInFront runs off the map and answers 0.
    off_map = sorted(f for f, (_dx, dy) in levmod.FACING_STEPS.items()
                     if dy < 0)
    c.expect("use.facing_convention_matches_the_map_edge",
             sorted(zero_returns), off_map,
             "0 degrees is +y and the angle grows toward +x")

    # docs/26 section 3.1: class 12 sets the magazine.  It is a visible no-op
    # here because the soldier's rifle holds 10 and it already had 10 -- said
    # so that a later reader does not take the unchanged byte for a defect.
    mag = tables.weapons[
        _byte(bytes.fromhex(payload["units_before"]), use["slot"], 0x3F)].mun
    ammo_after = bytes.fromhex(use["cells"] and use["units"][FACING_TO_EAST])
    c.expect("use.full_munition_leaves_the_magazine_full",
             ammo_after[sl + 0x3D], mag,
             f"weapon magazine is {mag}")

    # Everything above is native-only.  This is where `inclib/interact.py` is
    # run: the same 24 probes, in the same order, on a world built from the
    # engine's own bytes -- so the phase is a **gate** now rather than the
    # recorded observation `use_plan`'s docstring described.
    _use_model_checks(c, payload, use, tables)

    # --- the walk: aExecuteMove, probe by probe ---------------------------
    move = payload.get("move")
    if not move:
        c.check("move.captured", False,
                "the capture holds no aExecuteMove phase")
    else:
        _move_checks(c, payload, move, tables)

    # --- the reveals, the conversion and the ride: phases 11..13 ----------
    for key, _header, _name in PROBE_PHASES:
        block = payload.get(key)
        if not block:
            c.check(f"{key}.captured", False,
                    f"the capture holds no {key} phase; re-run --game-copy")
        else:
            _probe_checks(c, payload, key, block, tables)

    # --- the lone recompute, and the correction to docs/25 section 5 ------
    if "units_recompute" not in payload:
        c.check("recompute.captured", False,
                "the capture holds no lone-recompute phase; the refresh diff "
                "above already shows +0x15 being rewritten, but the sentinel "
                "is what isolates 0x004759B0's own write")
        return c.report()
    sentinel = bytes.fromhex(payload["units_sentinel"])
    recomputed = bytes.fromhex(payload["units_recompute"])
    probe = payload["probe_slot"]
    at = probe * gold.UNIT_STRIDE + gold.UNIT_MP
    c.expect("recompute.sentinel_was_written", sentinel[at], MP_SENTINEL,
             "the injected mov [ecx], dl reached +0x15")
    c.check("recompute.overwrote_the_sentinel", recomputed[at] != MP_SENTINEL,
            f"+0x15 is {recomputed[at]} after 0x004759B0, not {MP_SENTINEL} -- "
            f"so the movement points ARE stored and the routine DOES write "
            f"them, which is the correction to docs/25 section 5")
    wanted = payload.get("move_points_wanted") or []
    if wanted:
        c.expect("recompute.stores_aGetMovePoints", recomputed[at],
                 wanted[-1],
                 "+0x15 holds exactly what aGetMovePoints returned")
    return c.report()


def _move_checks(c: Checker, payload: dict[str, Any], move: dict[str, Any],
                 tables: BalanceTables) -> None:
    """Phase 10 against :func:`inclib.movemap.execute`, probe by probe.

    Every probe walks the *same* reconstructed path and differs only in one
    byte written between the walk and the call, so a disagreement names the
    arm that caused it rather than "something about movement".
    """
    width, height = payload["width"], payload["height"]
    base = gold.cells_of(bytes.fromhex(payload["cells"]), width, height)
    delays = tables.delay_table()
    stride = gold.UNIT_STRIDE
    probes = move["probes"]

    c.check("move.probed", len(probes) > 0,
            f"{len(probes)} aExecuteMove probe(s) on one path")
    c.expect("move.the_walk_found_the_same_path",
             sorted(set(move["walk_steps"])), [probes[0]["steps"]],
             "every probe re-fills and re-walks, and must get the same path")
    c.expect("move.nothing_was_in_the_way", sorted(set(move["walk_blocked"])),
             [0])

    costs: dict[str, int] = {}
    for i, probe in enumerate(probes):
        tag = probe["tag"]
        slot = probe["slot"]
        before = bytes.fromhex(move["units_before"][i])
        after = bytes.fromhex(move["units_after"][i])
        at = slot * stride
        costs[tag] = move["cost"][i]

        cells = dict(base)
        for key in ("field_type", "action_point", "obstacle"):
            cells[key] = list(base[key])
        for write in probe["writes"]:
            key = {"cell_field_type": "field_type",
                   "cell_action_point": "action_point",
                   "cell_obstacle": "obstacle"}[write["kind"]]
            cells[key][write["y"] * width + write["x"]] = write["value"]

        grid = gold.Grid(width, height, cells["height"], cells["field_type"],
                         cells["action_point"])
        units = gold.units_of(before, tables, payload["ai_level"])
        hooks = gold.hooks_from_arrays(
            width, cells["unit"],
            visibility={u["slot"]: u["visibility"] for u in units},
            players={u["slot"]: u["player"] for u in units},
            obstacles=cells["obstacle"])
        mover_row = next(u for u in units if u["slot"] == slot)
        mover = gold.Mover(
            slot=slot, x=mover_row["x"], y=mover_row["y"],
            player=mover_row["player"], mp=mover_row["mp"],
            special=mover_row["special"], size=mover_row["size"],
            has_jet_pack=mover_row["has_jet_pack"],
            mp_allowance=mover_row["mp_allowance"])
        # The fill and the walk ran on the **unmutated** map, which is what
        # the plan does: every write lands after them.
        clean = gold.Grid(width, height, base["height"], base["field_type"],
                          base["action_point"])
        clean_hooks = gold.hooks_from_arrays(
            width, base["unit"],
            visibility={u["slot"]: u["visibility"] for u in units},
            players={u["slot"]: u["player"] for u in units},
            obstacles=base["obstacle"])
        fill = gold.build(clean, mover, delays, clean_hooks,
                          pass_friendlies=False)
        walked = gold.walk(clean, fill, probe["sx"], probe["sy"],
                           probe["tx"], probe["ty"], delays, clean_hooks)
        model = movemapmod.execute(grid, hooks, delays, mover, walked)

        c.expect(f"move.{tag}.returns", int(model.ok),
                 int(bool(move["returns"][i])))
        c.expect(f"move.{tag}.cost", model.cost, move["cost"][i])
        c.expect(f"move.{tag}.position", (model.x, model.y),
                 (after[at + gold.UNIT_X], after[at + gold.UNIT_Y]))
        c.expect(f"move.{tag}.walked",
                 before[at + 0x50] + model.walked, after[at + 0x50],
                 "unit[+0x50], in tenths of a field")
        c.expect(f"move.{tag}.facing", model.facing, after[at + 0x46])
        # The three visibility passes of `aExecuteMove` (docs/22 §9.3): from
        # the destination before the first step, from the source for a
        # computer mover, and from the arrival cell -- each a **writing**
        # pass, so `+0x4F` and the promoted orders of every live record are
        # what the engine's after-image has to agree with.  The probe's
        # mover is the player's, so the source pass and the mode-3
        # self-reveal are the arms this capture cannot reach.
        world = _world_from_capture(payload, move["units_before"][i], tables)
        walker = world.units[slot]
        arrival_points = fill.mp_left[probe["ty"] * width + probe["tx"]]
        seen = combatmod.look_before_walk(world, walker, probe["tx"],
                                          probe["ty"], arrival_points)
        world.unit_at[world.index(walker.x, walker.y)] = -1
        world.unit_at[world.index(model.x, model.y)] = slot
        walker.x, walker.y, walker.facing = model.x, model.y, model.facing
        combatmod.look_after_walk(world, walker)
        fog_bad: list[str] = []
        for other_slot, other in sorted(world.units.items()):
            rec = other_slot * stride
            for offset, name, got in ((0x4F, "visibility", other.visibility),
                                      (0x47, "order", other.order),
                                      (0x48, "order_param",
                                       other.order_param)):
                if after[rec + offset] != got:
                    fog_bad.append(f"slot {other_slot} {name}: {got} against "
                                   f"{after[rec + offset]}")
        revealed = [other_slot for other_slot in payload["live"]
                    if before[other_slot * stride + 0x4F]
                    != after[other_slot * stride + 0x4F]]
        c.expect(f"move.{tag}.passes_write_what_the_engine_wrote", fog_bad,
                 [], f"+0x4F, +0x47 and +0x48 of every live record after "
                     f"the walk; the engine changed +0x4F on {revealed} "
                     f"(destination {seen[0]}, source {seen[1]})")
        # The seam docs/23 §5.3 draws: the routine reports and the caller
        # spends.  The one exception is the mine, which zeroes +0x15 itself.
        if model.movement_zeroed:
            c.expect(f"move.{tag}.movement_zeroed", after[at + gold.UNIT_MP],
                     0, "a mine zeroes +0x15 inside aExecuteMove")
        else:
            c.expect(f"move.{tag}.reports_without_spending",
                     after[at + gold.UNIT_MP], before[at + gold.UNIT_MP],
                     "u->mp is untouched by the call")
        c.expect(f"move.{tag}.drew_nothing", move["seeds_after"][i],
                 move["seeds_before"][i],
                 "aRandom's seed is bit-identical either side: a walk draws "
                 "nothing at all")

        cells_after = gold.cells_of(bytes.fromhex(move["cells_after"][i]),
                                    width, height)
        if any(e.kind == "mine" for e in model.events):
            # The other half of the evidence that no bomb resolver ran.  Its
            # hit is guaranteed, its applyDamage call advances the effect RNG,
            # and a mine that went off would not still stand on the cell.
            mine = next(e for e in model.events if e.kind == "mine")
            c.expect(f"move.{tag}.the_mover_is_unhurt",
                     after[at + gold.UNIT_HP], before[at + gold.UNIT_HP],
                     "docs/26 §6.1 predicts a guaranteed bomb resolution here")
            c.expect(f"move.{tag}.the_mine_is_still_there",
                     cells_after["obstacle"][mine.y * width + mine.x],
                     movemapmod.OBSTACLE_MINE,
                     "cell[+0x10] is untouched by the walk that stopped on it")
        for index, value in model.action_point_writes:
            c.expect(f"move.{tag}.claimed_{index}",
                     cells_after["action_point"][index], value,
                     "docs/26 §6.1 -- 0x51 + player")

    # The three delay probes are the phase's own experiment, and they are read
    # as differences from the control rather than as absolutes.
    if {"plain", "delay_source", "delay_middle", "delay_dest"} <= costs.keys():
        c.expect("move.delay_is_charged_on_the_cell_entered",
                 (costs["delay_source"] - costs["plain"],
                  costs["delay_middle"] - costs["plain"],
                  costs["delay_dest"] - costs["plain"]),
                 (0, 1, 1),
                 "source +0, middle +1, destination +1 -- the cell being "
                 "left is not charged, which docs/26 §5 could not say")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--game-copy", type=Path,
                    help="a copy of the game holding Work/Saves2/_6_.sav")
    ap.add_argument("--dbgcall", type=Path, help="path to dbgcall.exe")
    ap.add_argument("--root", type=Path, default=Path("gog_incubation"),
                    help="the read-only installation, for Info.lcl")
    ap.add_argument("-o", "--out", type=Path,
                    default=Path("tests/fixtures/turn/_C_141.json"))
    ap.add_argument("--check", metavar="ROOT",
                    help="re-run the models against a capture")
    ap.add_argument("--capture", type=Path,
                    default=Path("tests/fixtures/turn/_C_141.json"),
                    help="with --check, the capture to read")
    ap.add_argument("--attempts", type=int, default=gold.DEFAULT_ATTEMPTS)
    ap.add_argument("--emit-cases", metavar="PATH", type=Path,
                    help="re-express the capture for godot/tests/; the balance "
                         "rows it carries come from --root")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s")

    if args.emit_cases:
        if not args.capture.is_file():
            LOG.error("%s is missing; run --game-copy to produce it",
                      args.capture)
            return 1
        return emit_cases(args.capture, args.emit_cases, args.root)
    if args.check:
        if not args.capture.is_file():
            LOG.error("%s is missing; run --game-copy to produce it",
                      args.capture)
            return 1
        return run_check(args.capture, Path(args.check))
    if not args.game_copy or not args.dbgcall:
        ap.error("--game-copy and --dbgcall are required for a capture")
    return capture(args.game_copy, args.dbgcall, args.root, args.out,
                   args.attempts)


if __name__ == "__main__":
    raise SystemExit(main())
