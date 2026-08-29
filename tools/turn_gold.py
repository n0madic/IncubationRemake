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

CAPTURE_SCHEMA = "incubation.turn-capture/1"

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
"""

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


def sight_plan(pairs: list[tuple[int, int, int]]) -> str:
    """Phase 2 -- the read-only probes, over a grid of ordered unit pairs.

    Every call here is a pure function of the state phase 1 already captured,
    so the whole phase can be re-run without reloading anything.
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
    seen: set[int] = set()
    for a, b, _w in pairs:
        for slot in (a, b):
            if slot in seen:
                continue
            seen.add(slot)
            lines.append(f"aGetUnitFullHeight({_unit_addr(slot)})")
            lines.append(f"aGetUnitEyeHeight({_unit_addr(slot)})")
    for a, b, weapon in pairs:
        # The weapon id is a literal read out of phase 1's dump rather than an
        # `[address]` expression: `[expr]` reads a **dword**, and `+0x3F` is a
        # byte with three unrelated fields packed after it.
        lines.append(
            f"aGetHitProbability({_unit_addr(a)}, {_unit_addr(b)}, "
            f"{weapon}, 0, 1, &hit, &dist) --dump hit --dump dist")
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
    """The little-endian dword a named buffer held after each call."""
    out: list[int] = []
    for row in rows:
        if row.get("call") != call:
            continue
        dumps = row.get("dumps")
        if not isinstance(dumps, dict) or name not in dumps:
            continue
        raw = bytes.fromhex(dumps[name].replace(" ", ""))
        out.append(int.from_bytes(raw[:4], "little"))
    return out


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

    if "hit_percent" not in payload:
        pairs = pairs_for(live, unit_bytes)
        LOG.info("phase 2: %d ordered enemy pair(s)", len(pairs))
        if pairs:
            rows = gold.run_plan(game_copy, dbgcall, sight_plan(pairs),
                                 "turn_sight", attempts)
            payload["pairs"] = [list(p) for p in pairs]
            payload["full_heights"] = _results(rows, "aGetUnitFullHeight")
            payload["eye_heights"] = _results(rows, "aGetUnitEyeHeight")
            payload["hit_returns"] = _results(rows, "aGetHitProbability")
            payload["hit_percent"] = _dumps(rows, "aGetHitProbability", "hit")
            payload["hit_distance"] = _dumps(rows, "aGetHitProbability",
                                             "dist")
            _write(payload, out)

    player = _byte(unit_bytes, live[0], gold.UNIT_PLAYER) if live else 0
    probe = live[0] if live else 0

    if "units_refresh_after" not in payload:
        LOG.info("phase 3: refresh for player %d", player)
        try:
            rows = gold.run_plan(game_copy, dbgcall, refresh_plan(player),
                                 "turn_refresh", attempts)
            blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
            if len(blocks) < 2:
                raise GoldError(
                    f"phase 3 produced {len(blocks)} unit dumps, wanted 2")
            payload.update({
                "refresh_player": player,
                "units_refresh_before": blocks[0].hex(),
                "units_refresh_after": blocks[1].hex(),
            })
            _write(payload, out)
        except Exception as exc:  # noqa: BLE001 -- see the docstring
            LOG.warning("phase 3 did not complete (%s: %s); the refresh stays "
                        "unpinned and --check will say so",
                        type(exc).__name__, exc)

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

    # --- the refresh ------------------------------------------------------
    if "units_refresh_after" not in payload:
        # Not a pass and not a silent skip: the capture is incomplete, and a
        # check that examined nothing is not a check that passed.
        c.check("refresh.captured", False,
                "the capture holds no refresh phase; re-run --game-copy, and "
                "expect the anchor to need several attempts (docs/91 section 1)")
        return c.report()
    before = _turn_units_from(payload, payload["units_refresh_before"])
    after_raw = bytes.fromhex(payload["units_refresh_after"])
    state = turnmod.TurnState(turn=1, current_player=payload["refresh_player"],
                              ai_level=payload["ai_level"])
    world = _world_from_capture(payload, payload["units_refresh_before"],
                                tables)

    def banner_of(unit: turnmod.TurnUnit) -> bool:
        return combatmod.banner_nearby(world, world.units[unit.slot])

    turnmod.refresh_player(state, payload["refresh_player"], before, tables,
                           banner_of)
    fields = {"mp": gold.UNIT_MP, "fp": 0x19, "acted": 0x39,
              "action_state": 0x41, "rested": 0x57, "walked": 0x50,
              "turn_start_x": 0x51, "turn_start_y": 0x52,
              "stimulant": 0x58, "ticket": 0x59, "heat": 0x3E,
              "malfunction": 0x40, "weapon": 0x3F}
    mismatches: list[str] = []
    compared = 0
    for unit in before:
        if unit.player != payload["refresh_player"]:
            continue
        b = unit.slot * gold.UNIT_STRIDE
        for name, offset in fields.items():
            compared += 1
            got, want = getattr(unit, name), after_raw[b + offset]
            if got != want:
                mismatches.append(f"slot {unit.slot} {name}: {got} != {want}")
    c.check("refresh.fields_compared", compared > 0,
            f"{compared} field comparison(s)")
    c.expect("refresh.matches_native", mismatches[:8], [])

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
