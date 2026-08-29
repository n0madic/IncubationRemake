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
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import movemap_gold as gold                                        # noqa: E402
from inclib import combat as combatmod                             # noqa: E402
from inclib import turn as turnmod                                 # noqa: E402
from inclib.check import Checker                                   # noqa: E402
from inclib.info import BalanceTables, load_info                   # noqa: E402
from inclib.rng import ARandom                                     # noqa: E402

LOG = logging.getLogger("turn_gold")

CAPTURE_SCHEMA = "incubation.turn-capture/3"

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
"""

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
    resolved = game_copy.resolve()
    if repo == resolved or repo in resolved.parents:
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
    return 0


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

def _world_from_capture(payload: dict[str, Any], unit_hex: str,
                        tables: BalanceTables) -> combatmod.CombatWorld:
    width, height = payload["width"], payload["height"]
    cells = bytes.fromhex(payload["cells"])
    units_raw = bytes.fromhex(unit_hex)
    cell_height: list[int] = []
    unit_at: list[int] = []
    effect: list[int] = []
    for i in range(width * height):
        base = i * gold.CELL_STRIDE
        cell_height.append(int.from_bytes(
            cells[base + gold.CELL_HEIGHT:base + gold.CELL_HEIGHT + 4],
            "little", signed=True))
        slot = int.from_bytes(
            cells[base + gold.CELL_UNIT:base + gold.CELL_UNIT + 2], "little")
        unit_at.append(-1 if slot == 0xFFFF else slot)
        effect.append(cells[base + gold.CELL_OBSTACLE])

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
            absorber=units_raw[b + 0x3A],
            armour_front=units_raw[b + 0x36],
            armour_rear=units_raw[b + 0x37],
            action_state=units_raw[b + 0x41], visibility=units_raw[b + 0x4F],
            order=units_raw[b + 0x47], order_param=units_raw[b + 0x48],
            order2=units_raw[b + 0x49], order2_param=units_raw[b + 0x4A],
            group=units_raw[b + 0x4E], turn_start_x=units_raw[b + 0x51],
            turn_start_y=units_raw[b + 0x52], equipment_ids=equipment)
    return combatmod.CombatWorld(
        width=width, height=height, cell_height=cell_height,
        unit_at=unit_at, effect_state=effect, units=units, tables=tables,
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
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s")

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
