#!/usr/bin/env python3
"""Capture ``aBuildMoveMap`` from the live game and normalise it to a fixture.

This is the rank-1 oracle for the remake's flood fill (docs/92 §5): the engine's
own routine, called inside a running ``Incubation.exe`` with its globals
initialised, on mission ``_C_141`` loaded from save slot 6.

How the mission gets loaded without a human and without a patched executable
was the awkward part, and the answer is worth stating because it is not what
``docs/91`` reached for:

* the anchor is **inside ``aGameIntro``** (``Incubation.exe+0x4bd6f``).  By the
  time the intro runs, the front end has initialised and ``Info.lcl`` is loaded,
  but no screen has been built -- and, unlike ``aMainController`` or the
  main-menu builder, it is reached before the start-up path that this Wine
  build faults on;
* the save is loaded by **calling the game's own routines** --
  ``aSetSaveMode(0)`` then ``aLoadGame(6)`` -- rather than by patching the
  controller dispatch.  No ``--poke``, no ``--resume``, no patched copy.

Two properties of the capture are not optional:

* **The overlay is reset before every fill.**  ``aResetMoveOverlay``
  (``0x0042EE90``) writes ``cell[+0x00] = 1`` and ``cell[+0x0C] = 0`` over the
  whole grid.  The freshly loaded save already carries states 10, 32 and 50
  from the previous session, so without the reset the first fill would be
  compared against someone else's overlay.
* **The unmarked value is 1, not 0.**  The reset writes 1; the fill only ever
  writes 10 and 60.  The capture keeps the raw byte and the comparison maps
  :data:`inclib.movemap.STATE_RESET` onto :data:`inclib.movemap.STATE_NONE`.

Usage::

    python3 tools/movemap_gold.py --game-copy /path/to/game-copy \\
        --dbgcall /path/to/dbgcall.exe -o tests/fixtures/movemap/_C_141.json
    python3 tools/movemap_gold.py --check gog_incubation \\
        --fixture tests/fixtures/movemap/_C_141.json

``--check`` re-runs ``inclib.movemap`` against the captured inputs and requires
the reachable set and the movement points left to agree cell for cell.  It is
the only check in this repository whose oracle is the shipped engine itself.

Never run this against ``gog_incubation/``.  It needs a **copy** with
``Work/Saves2/_6_.sav`` in it, and the tool refuses a game directory that is
inside this repository.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import signal
import shutil
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib.allowance import (  # noqa: E402
    AllowanceUnit,
    EQUIP_BANNER,
    EQUIP_HEAVY_ARMOR,
    EQUIP_SERVO_SYSTEM,
    movement_allowance,
)
from inclib.cache import is_within  # noqa: E402
from inclib.check import Checker  # noqa: E402
from inclib.info import InfoError, load_info  # noqa: E402
from inclib.movemap import (  # noqa: E402
    cases_document,
    make_case,
    Grid,
    JET_PACK_EQUIP_ID,
    Mover,
    OBSTACLE_FIRE,
    SIZE_LARGE,
    VISIBILITY_HIDDEN,
    STATE_NONE,
    STATE_REACHABLE,
    STATE_RESET,
    build,
    hooks_from_arrays,
    walk,
    STATE_PATH,
)

LOG = logging.getLogger("movemap_gold")

FIXTURE_SCHEMA = "incubation.movemap-capture/1"

#: The mission save slot 6 holds, and the map it embeds.
CAPTURE_MISSION = "_C_141"
CAPTURE_SLOT = 6
CAPTURE_WIDTH = 20
CAPTURE_HEIGHT = 20

#: docs/21 §8 -- the runtime record strides.
CELL_STRIDE = 23
UNIT_STRIDE = 91
UNIT_SLOTS = 200

#: Cell field offsets, docs/21 §8 and docs/23 §7.
CELL_STATE = 0x00
CELL_HEIGHT = 0x01
CELL_UNIT = 0x07
CELL_ACTION_POINT = 0x0B
CELL_MP_LEFT = 0x0C
CELL_FIELD_TYPE = 0x0D
CELL_EFFECT0 = 0x0E
CELL_OBSTACLE = 0x10

#: Unit field offsets, docs/10 §5.
UNIT_NAME = 0x00
UNIT_MP = 0x15
UNIT_HP = 0x16
UNIT_EQUIPMENT = 0x21
UNIT_EQUIPMENT_SLOTS = 21
UNIT_FP = 0x19
UNIT_ACTION_STATE = 0x41
UNIT_X = 0x42
UNIT_Y = 0x43
UNIT_PLAYER = 0x45
UNIT_TYPE = 0x4C
UNIT_VISIBILITY = 0x4F
UNIT_RESTED = 0x57

#: The unit-record bytes ``unit_byte`` mutations write, by the name the
#: fixture's unit records use for them.  Everything here is read by
#: ``aGetMovePoints``; none of it is read by ``aBuildMoveMap`` itself.
FIELD_BY_OFFSET = {
    UNIT_FP: "fp",
    UNIT_RESTED: "rested",
    UNIT_ACTION_STATE: "action_state",
    UNIT_X: "x",
    UNIT_Y: "y",
    UNIT_PLAYER: "player",
}

#: Where the anchor and the routines live, as module-relative addresses.
BREAKPOINT = "Incubation.exe+0x4bd6f"

#: **The byte writer that needs no injected code page.**  The ``--code``
#: option that this file's own ``setb`` uses makes ``Incubation.exe`` fault
#: before it reaches the anchor on some hosts -- ten attempts out of ten,
#: against the same plan succeeding on the second attempt with the option
#: removed (``ai_gold.py`` found it).  So every later gold tool writes bytes
#: with the game's **own imported** ``memcpy``, reached through its IAT slot,
#: with the value to write sitting in a plain ``--blob``: no executable page
#: and no page-protection change.  ``memcpy`` is the only one of the three
#: block routines this image imports, and the bracket form is a dereference
#: of the import thunk's slot -- the address is read per call, so it works
#: whatever the loader put there.  Shared here because ``ai_gold``,
#: ``blob_gold``, ``presentation_gold`` and ``turn_gold`` all write through
#: it, and one slot address is one fewer to keep in step.
MEMCPY_SLOT = 0x00525634
MEMCPY_DECL = f"__cdecl ptr memcpy(ptr,ptr,i32) = [{MEMCPY_SLOT:#x}]"


def blob_name(value: int) -> str:
    """The ``--blob`` that holds one byte value, named by the value."""
    return f"bv{value & 0xFF:02x}"


def blob_lines(values: tuple[int, ...] | list[int]) -> list[str]:
    """One ``--blob`` line per distinct byte value a plan will write."""
    return [f"--blob {blob_name(v)}:{v & 0xFF:02x}" for v in sorted(set(values))]


def writeb(address: str, value: int) -> str:
    """One byte into the live process, through the game's own ``memcpy``."""
    return f"memcpy({address}, &{blob_name(value)}, 1)"
DECLARATIONS = """\
__cdecl void aSetSaveMode(i32)              = Incubation.exe+0x48770
__cdecl i32  aLoadGame(i32)                 = Incubation.exe+0x48e60
__cdecl ptr  aGetCtrlMapElementPtr(i32,i32) = Incubation.exe+0x2f730
__cdecl ptr  aGetUnitMapElementPtr(i32)     = Incubation.exe+0x77ae0
__cdecl void aResetMoveOverlay()            = Incubation.exe+0x2ee90
__cdecl i32  aBuildMoveMap(ptr,i32,ptr,i32) = Incubation.exe+0x30a40
__cdecl i32  aWalkMoveMap(i32,i32,i32,i32,ptr,ptr) = Incubation.exe+0x305e0
__cdecl i32  aGetMovePoints(ptr)            = Incubation.exe+0x75160
__cdecl i32  aGetAILevel()                  = Incubation.exe+0x60450
__fastcall void setb(ptr,i32)               = &setb
"""

#: A three-byte injected function, `mov [ecx], dl; ret`, declared __fastcall so
#: ECX takes the address and EDX the byte.  It is how the capture reaches the
#: branches the shipped campaign never exercises: the transient obstacle byte
#: is 255 in all 184162 shipped cells, no unit in _C_141 carries a Jet Pack,
#: and no type there has the `special` that refuses to move or warps.  Writing
#: those fields with the engine's own layout, then calling the engine's own
#: fill, turns three specification-only branches into native evidence.
SETB_CODE = "8811c3"

#: docs/21 §1 -- SetUnitInfo's static table, so a type's `special` (+0x07) and
#: `size` (+0x7B) have fixed addresses that a --poke-free byte write can reach.
UNITINFO_BASE = 0x0051C020
UNITINFO_STRIDE = 126
UNITINFO_SPECIAL = 0x07
UNITINFO_SIZE = 0x7B

#: Wine start-up on this host is intermittent (docs/91 §1): a run that never
#: reaches the anchor is an environment result, so the launcher retries.
DEFAULT_ATTEMPTS = 10
#: Seconds one attempt may take before it is abandoned and retried.
#:
#: The outer bound, and deliberately not the only one: ``dbgcall`` itself now
#: gives up if the anchor is not reached (``--anchor-timeout``, 60 s by
#: default), so a start-up that wedges costs a minute rather than this whole
#: budget.  Observed cost of an attempt that *works* is single-digit seconds --
#: one capture ran seven attempts of a phase, six failures and a success, in
#: under a minute -- so this leaves well over an order of magnitude of headroom
#: for a plan far larger than any taken so far.
ATTEMPT_TIMEOUT = 180
WINE_DESKTOP = "incdbg,640x480"
WINE_OVERRIDES = "krnl386.exe16=d"
#: Seconds ``wineserver -k`` may take before it is itself abandoned.  It is a
#: cleanup, so a hang in it must not become the hang it exists to prevent.
TEARDOWN_TIMEOUT = 30


class CaptureError(Exception):
    """Raised when a capture cannot be produced or read."""


# ---------------------------------------------------------------------------
# Plan generation
# ---------------------------------------------------------------------------

def _load_prologue() -> list[str]:
    return [
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({CAPTURE_SLOT})",
        "c0 = aGetCtrlMapElementPtr(0,0)",
        "u0 = aGetUnitMapElementPtr(0)",
    ]


def state_plan() -> str:
    """A plan that loads the save and dumps the whole live state."""
    cells = CAPTURE_WIDTH * CAPTURE_HEIGHT * CELL_STRIDE
    units = UNIT_SLOTS * UNIT_STRIDE
    lines = [
        "# Phase 1: load save slot 6 and dump the control map and unit array.",
        "# Both reads need the raised --read cap.",
        DECLARATIONS,
        *_load_prologue(),
        f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        "# 0x00460450, asked here and not only in phase 3: every allowance the",
        "# *planner* computes depends on it, and a wrong one moves the ladder",
        "# sweep's boundary probes off the boundary they exist to bracket.",
        "aGetAILevel()",
    ]
    return "\n".join(lines) + "\n"


def _cell_addr(index: int) -> str:
    return f"$c0+0x{index * CELL_STRIDE:x}"


def _unit_addr(slot: int, offset: int) -> str:
    return f"$u0+0x{slot * UNIT_STRIDE + offset:x}"


def mutation_writes(m: dict[str, Any], width: int) -> tuple[str, int, int]:
    """``(address expression, offset-free target, byte)`` for one mutation."""
    kind = m["kind"]
    if kind == "unit_mp":
        return _unit_addr(m["slot"], UNIT_MP), 0, m["value"]
    if kind == "unit_equipment":
        return (_unit_addr(m["slot"], UNIT_EQUIPMENT + m["id"]), 0, m["value"])
    if kind == "cell_obstacle":
        index = m["y"] * width + m["x"]
        return f"{_cell_addr(index)}+0x{CELL_OBSTACLE:x}", 0, m["value"]
    if kind == "cell_field_type":
        index = m["y"] * width + m["x"]
        return f"{_cell_addr(index)}+0x{CELL_FIELD_TYPE:x}", 0, m["value"]
    if kind == "unit_byte":
        return _unit_addr(m["slot"], m["offset"]), 0, m["value"]
    if kind == "type_special":
        addr = UNITINFO_BASE + m["type_id"] * UNITINFO_STRIDE + UNITINFO_SPECIAL
        return f"0x{addr:08x}", 0, m["value"]
    if kind == "type_size":
        addr = UNITINFO_BASE + m["type_id"] * UNITINFO_STRIDE + UNITINFO_SIZE
        return f"0x{addr:08x}", 0, m["value"]
    raise CaptureError(f"unknown mutation {kind!r}")


def apply_mutation(m: dict[str, Any], cells: dict[str, list[int]],
                   units: dict[int, dict[str, Any]], width: int) -> None:
    """Apply one mutation to the model's copy of the captured state."""
    kind = m["kind"]
    if kind == "unit_mp":
        units[m["slot"]]["mp"] = m["value"]
    elif kind == "unit_equipment":
        unit = units[m["slot"]]
        ids = set(unit["equipment_ids"])
        ids.add(m["id"]) if m["value"] else ids.discard(m["id"])
        unit["equipment_ids"] = sorted(ids)
        if m["id"] == JET_PACK_EQUIP_ID:
            unit["has_jet_pack"] = bool(m["value"])
    elif kind == "cell_obstacle":
        cells["obstacle"][m["y"] * width + m["x"]] = m["value"]
    elif kind == "cell_field_type":
        cells["field_type"][m["y"] * width + m["x"]] = m["value"]
    elif kind == "unit_byte":
        units[m["slot"]][FIELD_BY_OFFSET[m["offset"]]] = m["value"]
    elif kind == "type_special":
        for unit in units.values():
            if unit["type_id"] == m["type_id"]:
                unit["special"] = m["value"]
    elif kind == "type_size":
        # The write lands in the shared SetUnitInfo row, so every unit of the
        # type sees it -- and the emitted case builds its unit-type table from
        # these records, so all of them have to carry the written value or the
        # GDScript side would build a table the engine never had.
        for unit in units.values():
            if unit["type_id"] == m["type_id"]:
                unit["size"] = m["value"]
    else:
        raise CaptureError(f"unknown mutation {kind!r}")


def fill_plan(runs: list[dict[str, Any]], width: int = CAPTURE_WIDTH) -> str:
    """A plan that repeats the load, then runs every planned fill.

    Each run may carry ``mutations`` that are written before the fill and undone
    after it, so the runs stay independent and the base state stays the one the
    fixture records.
    """
    cells = width * CAPTURE_HEIGHT * CELL_STRIDE
    units = UNIT_SLOTS * UNIT_STRIDE
    lines = [
        "# Phase 2: the same load, then the planned fills.",
        "# The overlay is reset before every fill: a freshly loaded save still",
        "# carries the previous session's cell states.",
        DECLARATIONS,
        "--buf scratch:4",
        f"--code setb:{SETB_CODE}",
        "",
        *_load_prologue(),
        f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        "",
    ]
    for i, run in enumerate(runs):
        slot, flag = run["slot"], int(run["pass_friendlies"])
        tag = f"r{i}"
        lines.append(f"# run {i}: slot {slot}, pass_friendlies={flag}"
                     + (f", {len(run.get('mutations', []))} mutation(s)"
                        if run.get("mutations") else ""))
        for m in run.get("mutations", []):
            addr, _, value = mutation_writes(m, width)
            lines.append(f"setb({addr}, {value})")
        lines += [
            "aResetMoveOverlay()",
            f"u{tag} = aGetUnitMapElementPtr({slot})",
            f"aBuildMoveMap($u{tag}, {flag}, &scratch, 0) "
            f"--zero scratch --dump scratch",
            f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        ]
        for m in run.get("mutations", []):
            addr, _, _value = mutation_writes(m, width)
            lines.append(f"setb({addr}, {m['restore']})")
    return "\n".join(lines) + "\n"


#: Movement-point values the sweep gives a mover.  4 and 6 are what shipped
#: units actually carry; 1 exercises the single-wave case and 8 pushes the
#: fill past anything the campaign produces.
MP_SWEEP = (1, 2, 4, 6, 8)
#: Movement points given to a mover whose branch is being exercised.
MP_FOR_BRANCH = 4

#: docs/23 §7.1 -- the two `special` values that return an empty map, and the
#: one that warps at range 7.
SPECIAL_CASES = (1, 14, 15)
#: docs/23 §7.1 -- the three transient obstacles, none of which occurs on any
#: shipped cell.
OBSTACLES = (1, 2, 3)

#: docs/21 §2 -- the field type no shipped cell in any of the 155 missions
#: carries, and the only one whose step costs a whole movement allowance.
LADDER_TYPE = 8
#: Movement points a ladder run gives its mover.  A ladder step costs
#: ``allowance - 1`` plus the per-step 1, so the sweep brackets that: one value
#: comfortably above it, one exactly on the boundary, one just below.
LADDER_MP_SWEEP = (12, 0, -1)


def plan_runs(cells: dict[str, list[int]], units: list[dict[str, Any]],
              tables: Any, width: int, height: int) -> list[dict[str, Any]]:
    """Every fill the capture asks the engine for, in plan order.

    The first block is the mission as it stands.  Everything after it writes a
    field the engine itself writes -- movement points, a Jet Pack, a type's
    `special`, a cell's obstacle byte -- and restores it afterwards, so that
    branches with no corpus coverage still get a rank-1 oracle instead of only
    a synthetic one.
    """
    by_slot = {u["slot"]: u for u in units}
    runs: list[dict[str, Any]] = []

    # 1. The mission as loaded.
    for unit in units:
        for flag in (False, True):
            runs.append({"slot": unit["slot"], "pass_friendlies": flag,
                         "mutations": []})

    # 2. A movement-point sweep, on a player unit and on an alien, so both
    #    sides of the mine rule and of the friendly rule are represented.
    movers = [u for u in units if u["player"] == 0][:1]
    movers += [u for u in units if u["player"] == 255][:1]
    for unit in movers:
        for mp in MP_SWEEP:
            for flag in (False, True):
                runs.append({
                    "slot": unit["slot"], "pass_friendlies": flag,
                    "mutations": [_mp(unit, mp)]})

    if not movers:
        return runs
    mover = movers[0]
    original_special = mover["special"]

    # 3. The Jet Pack, which is the equipment path into the warp pass.
    for flag in (False, True):
        runs.append({
            "slot": mover["slot"], "pass_friendlies": flag,
            "mutations": [
                _mp(mover, MP_FOR_BRANCH),
                {"kind": "unit_equipment", "slot": mover["slot"],
                 "id": JET_PACK_EQUIP_ID, "value": 1,
                 "restore": int(JET_PACK_EQUIP_ID in mover["equipment_ids"])},
            ]})

    # 4. The `special` enumerator: both refusals and the innate warp.
    for special in SPECIAL_CASES:
        runs.append({
            "slot": mover["slot"], "pass_friendlies": False,
            "mutations": [
                _mp(mover, MP_FOR_BRANCH),
                {"kind": "type_special", "type_id": mover["type_id"],
                 "value": special, "restore": original_special},
            ]})

    # 5. The transient obstacle byte, on the mover's own cell (the shield
    #    refusal) and on a walkable neighbour (fire and the mine).
    here = mover["y"] * width + mover["x"]
    runs.append({
        "slot": mover["slot"], "pass_friendlies": False,
        "mutations": [
            _mp(mover, MP_FOR_BRANCH),
            _obstacle(cells, mover["x"], mover["y"], 3, width),
        ]})
    # **Per mover, not per `movers[0]`.**  The neighbour list used to be
    # computed once, for the first mover, while the runs were issued for each
    # mover in turn -- so the alien's obstacle was written next to somebody
    # else's unit and its fill never met it.  That left the one branch the
    # player id exists for, `mine blocks everyone except player 255`
    # (docs/23 §7.1), with no evidence at all: deleting the exemption from the
    # model still passed every check here.
    for obstacle in OBSTACLES:
        for unit in movers:
            near = _walkable_neighbours(cells, unit, tables, width, height)
            if not near:
                continue
            nx, ny = near[0]
            runs.append({
                "slot": unit["slot"], "pass_friendlies": False,
                "obstacle": f"{obstacle}.player{unit['player']}",
                "obstacle_cell": [nx, ny],
                "mutations": [
                    _mp(unit, MP_FOR_BRANCH),
                    _obstacle(cells, nx, ny, obstacle, width),
                ]})
    assert here >= 0

    # 6. The ladder.  No shipped cell in any of the 155 missions is field type
    #    8 (docs/23 §7.4), so the ladder-to-ladder step has never had an oracle
    #    of any kind -- not even a corpus one.  Writing the field type of a
    #    mover's own cell and of one neighbour makes the engine take the branch
    #    and reports what it actually costs.  Two neighbours are chosen where
    #    the map allows: one the height rule blocks, which is what proves the
    #    rule is skipped, and one flat, which pins the cost on its own.
    runs += _ladder_runs(cells, units, tables, width, height)

    # 7. The large-unit clearance test.  `unitInfo[type].size` is 1 on exactly
    #    ComBot, Tr'Yn and Al'Coo (docs/21 §5), none of which is on this
    #    mission -- so 0x0047A410 has never been reached natively, and its five
    #    conditions stood on the disassembly alone.  Writing the type's size
    #    byte reaches it without changing anything else the fill reads: the
    #    mover keeps its own movement points, its `special` and its position.
    runs += _clearance_runs(cells, units, tables, width, height)

    # 8. A hidden unit's cell, actually reached.  `visibility == 3` makes a
    #    unit count as empty ground (docs/23 §7.3), and the only evidence for
    #    that used to be that a hidden unit *existed* in the roster -- no
    #    captured fill went anywhere near it, and making hidden units block
    #    like any other still passed every check.
    runs += _hidden_runs(cells, units, tables, width, height)
    return runs


#: Movement points a hidden-cell run gives its mover.  Large on purpose: the
#: point is to reach a particular cell, not to be plausible.
HIDDEN_MP = 40


def _hidden_runs(cells: dict[str, list[int]], units: list[dict[str, Any]],
                 tables: Any, width: int, height: int
                 ) -> list[dict[str, Any]]:
    """A fill whose reach includes a hidden unit's cell.

    Chosen with the model, answered by the engine, and the check asserts the
    engine marked that cell -- which is the whole content of "a hidden unit is
    treated exactly like an empty cell".
    """
    delays = tables.delay_table()
    hidden = [u for u in units if u["visibility"] == VISIBILITY_HIDDEN]
    if not hidden:
        LOG.warning("no hidden unit on this mission; the visibility-3 branch "
                    "stays specification-only")
        return []
    runs: list[dict[str, Any]] = []
    for target in hidden:
        index = target["y"] * width + target["x"]
        best: tuple[int, dict[str, Any]] | None = None
        for unit in units:
            if unit["slot"] == target["slot"]:
                continue
            state = _model_fill(cells, units, unit, delays, width, height,
                                HIDDEN_MP, unit["size"])
            if state[index] != STATE_REACHABLE:
                continue
            distance = abs(unit["x"] - target["x"]) \
                + abs(unit["y"] - target["y"])
            if best is None or distance < best[0]:
                best = (distance, unit)
        if best is None:
            LOG.warning("no mover can reach hidden slot %d at (%d,%d) even "
                        "with %d movement points", target["slot"],
                        target["x"], target["y"], HIDDEN_MP)
            continue
        mover = best[1]
        LOG.info("hidden: slot %d reaches slot %d at (%d,%d)",
                 mover["slot"], target["slot"], target["x"], target["y"])
        runs.append({
            "slot": mover["slot"], "pass_friendlies": False,
            "hidden": {"slot": target["slot"],
                       "cell": [target["x"], target["y"]]},
            "mutations": [_mp(mover, HIDDEN_MP)]})
    return runs


#: Movement points a clearance run gives its mover.  The rule only shows
#: itself where the fill is wide enough to offer candidates whose neighbours
#: differ, and 8 is past anything the campaign hands out.
CLEARANCE_MP = 8
#: How many movers the clearance block asks for, best discriminator first.
CLEARANCE_MOVERS = 3


def _clearance_runs(cells: dict[str, list[int]], units: list[dict[str, Any]],
                    tables: Any, width: int, height: int
                    ) -> list[dict[str, Any]]:
    """Fills by a mover written large, plus the fire arm and a control.

    The slots are **chosen with the model and answered by the engine**, which
    is the same division of labour as the walk targets: the model says where
    the rule would decide something, and a run where it decided nothing would
    prove nothing.  A slot qualifies only when the large fill both loses cells
    to the test and keeps cells past it -- one arm alone is half a check.
    """
    delays = tables.delay_table()
    scored: list[tuple[int, int, dict[str, Any]]] = []
    for unit in units:
        small = _model_fill(cells, units, unit, delays, width, height,
                            CLEARANCE_MP, 0)
        large = _model_fill(cells, units, unit, delays, width, height,
                            CLEARANCE_MP, SIZE_LARGE)
        lost = sum(1 for i in range(width * height)
                   if small[i] == STATE_REACHABLE
                   and large[i] != STATE_REACHABLE)
        kept = sum(1 for v in large if v == STATE_REACHABLE)
        if lost and kept > 1:
            scored.append((lost, kept, unit))
    if not scored:
        LOG.warning("no slot makes the clearance test decide; that branch "
                    "stays specification-only")
        return []
    scored.sort(key=lambda row: (row[0], row[1]), reverse=True)

    runs: list[dict[str, Any]] = []
    for lost, kept, unit in scored[:CLEARANCE_MOVERS]:
        LOG.info("clearance: slot %d loses %d cells and keeps %d",
                 unit["slot"], lost, kept)
        # Both flags on the best mover.  The clearance test's occupancy
        # condition has no pass_friendlies arm -- a friendly next to a
        # candidate blocks a large unit either way -- and that is an assertion
        # about the engine, so it is asked rather than assumed.
        flags = (False, True) if unit is scored[0][2] else (False,)
        for flag in flags:
            runs.append({
                "slot": unit["slot"], "pass_friendlies": flag,
                "clearance": "large",
                "mutations": [_mp(unit, CLEARANCE_MP), _size(unit, SIZE_LARGE)],
            })

    # The fire condition is the one no natural cell exercises: the obstacle
    # byte is 255 in all 184162 shipped cells.  A fire written **diagonally**
    # from a candidate cannot be what stopped the 4-connected fill from
    # entering that candidate, so if the cell goes away, the clearance test is
    # what took it -- and the small-unit control with the same fire in place
    # is what makes that a difference rather than an assertion.
    found = _clearance_fire_cell(cells, units, scored[0][2], delays, width,
                                 height)
    if found is None:
        LOG.warning("no diagonal fire cell isolates the clearance fire arm")
        return runs
    unit, (fx, fy) = found
    # A 2x2: {large, small} x {fire, no fire}, all four native, so the fire
    # condition is the *difference of differences* rather than a difference
    # between two movers.  The large-versus-small gap is the whole clearance
    # test and would be satisfied by a dead fire arm; what only the fire arm
    # can explain is the large mover losing far more to one written byte than
    # the small mover loses to the same byte.  The `large` run above is the
    # fourth cell of the square, so only three are added here.
    for size, tag in ((SIZE_LARGE, "fire"), (0, "fire_control"),
                      (0, "fire_control_dry")):
        mutations = [_mp(unit, CLEARANCE_MP)]
        if tag != "fire_control_dry":
            mutations.append(_obstacle(cells, fx, fy, OBSTACLE_FIRE, width))
        if size:
            mutations.append(_size(unit, size))
        runs.append({"slot": unit["slot"], "pass_friendlies": False,
                     "clearance": tag, "mutations": mutations})
    return runs


def _model_fill(cells: dict[str, list[int]], units: list[dict[str, Any]],
                unit: dict[str, Any], delays: Mapping[int, int], width: int,
                height: int, mp: int, size: int,
                pass_friendlies: bool = False) -> list[int]:
    """The executable model's state array for one hypothetical fill."""
    grid = Grid(width, height, cells["height"], cells["field_type"],
                cells["action_point"])
    hooks = hooks_from_arrays(
        width, cells["unit"],
        visibility={u["slot"]: u["visibility"] for u in units},
        players={u["slot"]: u["player"] for u in units},
        obstacles=cells["obstacle"])
    mover = Mover(slot=unit["slot"], x=unit["x"], y=unit["y"],
                  player=unit["player"], mp=mp, special=unit["special"],
                  size=size, has_jet_pack=unit["has_jet_pack"],
                  mp_allowance=unit["mp_allowance"])
    return build(grid, mover, delays, hooks,
                 pass_friendlies=pass_friendlies).state


#: The four diagonal offsets.  A cell diagonally adjacent to a candidate is in
#: the candidate's clearance ring but is never the cell a 4-connected fill
#: steps through to reach it.
DIAGONAL_DELTA = ((1, 1), (1, -1), (-1, 1), (-1, -1))


def _clearance_fire_cell(cells: dict[str, list[int]],
                         units: list[dict[str, Any]], unit: dict[str, Any],
                         delays: Mapping[int, int], width: int, height: int
                         ) -> tuple[dict[str, Any], tuple[int, int]] | None:
    """A fire placement that only the clearance test can react to.

    Wanted: a cell the large fill reaches, and a diagonal neighbour of it such
    that writing fire there costs the large fill that cell while the small fill
    keeps it.
    """
    large = _model_fill(cells, units, unit, delays, width, height,
                        CLEARANCE_MP, SIZE_LARGE)
    best: tuple[int, tuple[int, int]] | None = None
    for index, value in enumerate(large):
        if value != STATE_REACHABLE:
            continue
        cx, cy = index % width, index // width
        for dx, dy in DIAGONAL_DELTA:
            fx, fy = cx + dx, cy + dy
            if not (0 <= fx < width and 0 <= fy < height):
                continue
            burnt = {k: list(v) for k, v in cells.items()}
            burnt["obstacle"][fy * width + fx] = OBSTACLE_FIRE
            with_fire = _model_fill(burnt, units, unit, delays, width, height,
                                    CLEARANCE_MP, SIZE_LARGE)
            if with_fire[index] == STATE_REACHABLE:
                continue
            control = _model_fill(burnt, units, unit, delays, width, height,
                                  CLEARANCE_MP, 0)
            if control[index] != STATE_REACHABLE:
                continue
            lost = sum(1 for i in range(width * height)
                       if large[i] == STATE_REACHABLE
                       and with_fire[i] != STATE_REACHABLE)
            if best is None or lost > best[0]:
                best = (lost, (fx, fy))
    if best is None:
        return None
    LOG.info("clearance fire at %s costs the large fill %d cells",
             best[1], best[0])
    return unit, best[1]


def _ladder_runs(cells: dict[str, list[int]], units: list[dict[str, Any]],
                 tables: Any, width: int, height: int) -> list[dict[str, Any]]:
    """Ladder-to-ladder fills, over a cliff where the map offers one."""
    runs: list[dict[str, Any]] = []
    for tag, over_cliff in (("cliff", True), ("flat", False)):
        found = _ladder_pair(cells, units, tables, width, height, over_cliff)
        if found is None:
            LOG.warning("no %s ladder pair on this map; that branch stays "
                        "specification-only", tag)
            continue
        unit, (nx, ny) = found
        allowance = int(unit["mp_allowance"])
        for delta in LADDER_MP_SWEEP:
            mp = delta if delta > 0 else allowance + delta
            if mp < 0:
                continue
            runs.append({
                "slot": unit["slot"], "pass_friendlies": False,
                "ladder": tag,
                "mutations": [
                    _mp(unit, mp),
                    _field_type(cells, unit["x"], unit["y"], LADDER_TYPE,
                                width),
                    _field_type(cells, nx, ny, LADDER_TYPE, width),
                ]})
    return runs


def _ladder_pair(cells: dict[str, list[int]], units: list[dict[str, Any]],
                 tables: Any, width: int, height: int, over_cliff: bool,
                 same_delay_as_ladder: bool = False
                 ) -> tuple[dict[str, Any], tuple[int, int]] | None:
    """A live unit and an orthogonal neighbour to turn into a ladder.

    ``over_cliff`` picks a neighbour the height rule would block, which is the
    pair that shows the rule being skipped; otherwise it picks one within the
    climb limit, where the cost stands alone.
    """
    for unit in units:
        # A mover whose allowance is 0 or 1 makes a degenerate ladder run --
        # the boundary sweep collapses onto a single value -- so prefer one
        # with room on both sides of the cost.
        if int(unit["mp_allowance"]) < 2:
            continue
        here = unit["y"] * width + unit["x"]
        for dx, dy in ((0, 1), (-1, 0), (0, -1), (1, 0)):
            nx, ny = unit["x"] + dx, unit["y"] + dy
            if not (0 <= nx < width and 0 <= ny < height):
                continue
            index = ny * width + nx
            if cells["unit"][index] != -1:
                continue
            delta = abs(cells["height"][index] - cells["height"][here])
            blocked = delta // 1600 > 1
            if blocked != over_cliff:
                continue
            if same_delay_as_ladder and tables.delay(
                    cells["field_type"][index]) != tables.delay(LADDER_TYPE):
                # The aExecuteMove probes compare a ladder step against the
                # *same* step with the field types left alone, so the terrain
                # under them has to cost what a ladder costs.  Without this a
                # Debris neighbour (delay 1) makes the control cost 2 against
                # the ladder's 1 and the check reports docs/26 §5 as broken
                # when only the ground differed.
                continue
            return unit, (nx, ny)
    return None


def _field_type(cells: dict[str, list[int]], x: int, y: int, value: int,
                width: int) -> dict[str, Any]:
    return {"kind": "cell_field_type", "x": x, "y": y, "value": value,
            "restore": cells["field_type"][y * width + x]}


def _size(unit: dict[str, Any], value: int) -> dict[str, Any]:
    return {"kind": "type_size", "type_id": unit["type_id"], "value": value,
            "restore": unit["size"]}


def _mp(unit: dict[str, Any], value: int) -> dict[str, Any]:
    return {"kind": "unit_mp", "slot": unit["slot"], "value": value,
            "restore": unit["mp"]}


def _obstacle(cells: dict[str, list[int]], x: int, y: int, value: int,
              width: int) -> dict[str, Any]:
    return {"kind": "cell_obstacle", "x": x, "y": y, "value": value,
            "restore": cells["obstacle"][y * width + x]}


def _walkable_neighbours(cells: dict[str, list[int]], unit: dict[str, Any],
                         tables: Any, width: int,
                         height: int) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    for dx, dy in ((0, 1), (-1, 0), (0, -1), (1, 0)):
        nx, ny = unit["x"] + dx, unit["y"] + dy
        if not (0 <= nx < width and 0 <= ny < height):
            continue
        i = ny * width + nx
        if cells["unit"][i] != -1:
            continue
        if tables.delay(cells["field_type"][i]) == 255:
            continue
        out.append((nx, ny))
    return out


# ---------------------------------------------------------------------------
# Phase 3: the movement allowance and the path walk
# ---------------------------------------------------------------------------

#: Offsets from the mover, in fields, at which a Banner carrier is parked.
#: ``(3, 3)`` is the one that decides the metric: floor-Euclidean makes it 4,
#: which is out of range, while Chebyshev makes it 3, which is in.  One
#: placement therefore settles what docs/10 §5.5 left as "within 4 fields".
BANNER_PLACEMENTS = ((0, 0), (3, 0), (0, 3), (2, 2), (3, 3), (4, 0), (0, 5))

#: Fitness points the allowance sweep tries.  0 and 1 are the two overrides;
#: 2 is the first value that does not override, so it shows the overrides are
#: the only special cases.
FP_SWEEP = (0, 1, 2)
#: ``unit[+0x41]`` -- both suppressing states, and one that does not suppress.
ACTION_STATE_SWEEP = (0, 5, 6, 7)


def plan_allowance_runs(units: list[dict[str, Any]], width: int, height: int
                        ) -> list[dict[str, Any]]:
    """Every ``aGetMovePoints`` call the capture asks for.

    Writing ``unit[+0x42]``/``+0x43`` moves a unit **without** updating the
    control map's cell links, which would corrupt a fill.  It is safe here and
    only here: ``aGetMovePoints`` and its Banner scan read the unit array and
    nothing else, and every write is undone before the next call.
    """
    runs: list[dict[str, Any]] = [
        {"slot": u["slot"], "tag": f"asis.slot{u['slot']}", "mutations": []}
        for u in units]
    movers = [u for u in units if u["player"] == 0][:1] or units[:1]
    if not movers:
        return runs
    mover = movers[0]

    for equipment_id in (EQUIP_SERVO_SYSTEM, EQUIP_HEAVY_ARMOR):
        for value in (1, 0):
            runs.append({
                "slot": mover["slot"], "tag": f"equip{equipment_id}={value}",
                "mutations": [_equip(mover, equipment_id, value)]})
    # Both together: the byte accumulator adds then subtracts, so the pair is
    # the check that neither is applied twice.
    runs.append({
        "slot": mover["slot"], "tag": "servo+armor",
        "mutations": [_equip(mover, EQUIP_SERVO_SYSTEM, 1),
                      _equip(mover, EQUIP_HEAVY_ARMOR, 1)]})

    for fp in FP_SWEEP:
        runs.append({"slot": mover["slot"], "tag": f"fp{fp}",
                     "mutations": [_byte(mover, UNIT_FP, fp)]})
    # Rested on its own, and rested with an override in front of it: the
    # override wins, which is what makes the branch an `elif` and not an `if`.
    runs.append({"slot": mover["slot"], "tag": "rested",
                 "mutations": [_byte(mover, UNIT_RESTED, 1)]})
    runs.append({"slot": mover["slot"], "tag": "rested+fp1",
                 "mutations": [_byte(mover, UNIT_RESTED, 1),
                               _byte(mover, UNIT_FP, 1)]})
    for state in ACTION_STATE_SWEEP:
        runs.append({"slot": mover["slot"], "tag": f"action{state}",
                     "mutations": [_byte(mover, UNIT_ACTION_STATE, state)]})

    # _C_141 fields exactly one player-0 unit, so the carrier is borrowed from
    # another slot and given the mover's player for the duration of the call.
    # The scan reads the unit array only, and every byte is put back.
    carrier = next((u for u in units if u["slot"] != mover["slot"]), None)
    if carrier is not None:
        for dx, dy in BANNER_PLACEMENTS:
            x, y = mover["x"] + dx, mover["y"] + dy
            if not (0 <= x < width and 0 <= y < height):
                continue
            runs.append({
                "slot": mover["slot"], "tag": f"banner+{dx},{dy}",
                "mutations": [_equip(carrier, EQUIP_BANNER, 1),
                              _byte(carrier, UNIT_PLAYER, mover["player"]),
                              _byte(carrier, UNIT_X, x),
                              _byte(carrier, UNIT_Y, y)]})
        # The same carrier in range but owned by someone else: the
        # single-player arm of 0x0046FAD0 tests the owner exactly.
        runs.append({
            "slot": mover["slot"], "tag": "banner+0,0.other_player",
            "mutations": [_equip(carrier, EQUIP_BANNER, 1),
                          _byte(carrier, UNIT_PLAYER, 200),
                          _byte(carrier, UNIT_X, mover["x"]),
                          _byte(carrier, UNIT_Y, mover["y"])]})
    # The carrier is the mover itself: the scan does not skip the unit it was
    # asked about, so this must add one.
    runs.append({"slot": mover["slot"], "tag": "banner=self",
                 "mutations": [_equip(mover, EQUIP_BANNER, 1)]})
    return runs


def _equip(unit: dict[str, Any], equipment_id: int,
           value: int) -> dict[str, Any]:
    return {"kind": "unit_equipment", "slot": unit["slot"], "id": equipment_id,
            "value": value,
            "restore": int(equipment_id in unit["equipment_ids"])}


def _byte(unit: dict[str, Any], offset: int, value: int) -> dict[str, Any]:
    return {"kind": "unit_byte", "slot": unit["slot"], "offset": offset,
            "value": value, "restore": unit[FIELD_BY_OFFSET[offset]]}


#: How many walk targets one fill contributes.  The spread is by distance from
#: the mover, so a short path, a long one and the ones between all appear.
WALK_TARGETS = 8


def plan_walk_runs(cells: dict[str, list[int]], units: list[dict[str, Any]],
                   tables: Any, width: int, height: int
                   ) -> list[dict[str, Any]]:
    """Walks to a spread of reachable cells, and one to an unreachable cell.

    The target set is chosen with the model, which is not circular: the model
    picks *what to ask*, and the engine answers.  A target the fill never
    marked is asked for on purpose -- gradient ascent from a cell holding zero
    movement points is the "no direction found" arm, and it returns FALSE.
    """
    runs: list[dict[str, Any]] = []
    delays = tables.delay_table()
    for unit in units:
        if unit["player"] != 0:
            continue
        grid = Grid(width, height, cells["height"], cells["field_type"],
                    cells["action_point"])
        hooks = hooks_from_arrays(
            width, cells["unit"],
            visibility={u["slot"]: u["visibility"] for u in units},
            players={u["slot"]: u["player"] for u in units},
            obstacles=cells["obstacle"])
        mover = Mover(slot=unit["slot"], x=unit["x"], y=unit["y"],
                      player=unit["player"], mp=unit["mp"],
                      special=unit["special"], size=unit["size"],
                      has_jet_pack=unit["has_jet_pack"],
                      mp_allowance=unit["mp_allowance"])
        result = build(grid, mover, delays, hooks, pass_friendlies=False)
        reachable = [i for i in result.reachable_cells()
                     if i != grid.index(unit["x"], unit["y"])]
        if not reachable:
            continue
        reachable.sort(key=lambda i: (
            abs(i % width - unit["x"]) + abs(i // width - unit["y"]), i))
        step = max(1, len(reachable) // WALK_TARGETS)
        chosen = reachable[::step][:WALK_TARGETS]
        for index in chosen:
            runs.append({"slot": unit["slot"], "sx": unit["x"],
                         "sy": unit["y"], "tx": index % width,
                         "ty": index // width, "reachable": True})
        unreached = [i for i in range(width * height)
                     if result.state[i] == STATE_NONE]
        if unreached:
            index = unreached[len(unreached) // 2]
            runs.append({"slot": unit["slot"], "sx": unit["x"],
                         "sy": unit["y"], "tx": index % width,
                         "ty": index // width, "reachable": False})
        break
    return runs


def extra_plan(allowance_runs: list[dict[str, Any]],
               walk_runs: list[dict[str, Any]],
               width: int = CAPTURE_WIDTH) -> str:
    """Phase 3: the same load, then the allowance calls and the walks."""
    cells = width * CAPTURE_HEIGHT * CELL_STRIDE
    units = UNIT_SLOTS * UNIT_STRIDE
    lines = [
        "# Phase 3: aGetMovePoints for the movement allowance (docs/10 5.5),",
        "# then aWalkMoveMap for the reconstructed path (docs/23 8).",
        "# Every walk re-fills first: the walk's own final sweep destroys the",
        "# overlay it read, so a second walk over the same fill reads rubble.",
        DECLARATIONS,
        "--buf scratch:4",
        "--buf wblocked:4",
        "--buf wsteps:4",
        f"--code setb:{SETB_CODE}",
        "",
        *_load_prologue(),
        f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"aGetUnitMapElementPtr(0) --read $u0:{units}",
        "# 0x00460450, which aGetMovePoints consults for unit type 0x32 only.",
        "aGetAILevel()",
        "",
    ]
    for i, run in enumerate(allowance_runs):
        lines.append(f"# allowance {i}: slot {run['slot']}, {run['tag']}")
        for m in run["mutations"]:
            addr, _, value = mutation_writes(m, width)
            lines.append(f"setb({addr}, {value})")
        lines += [
            f"ua{i} = aGetUnitMapElementPtr({run['slot']})",
            f"aGetMovePoints($ua{i})",
        ]
        for m in run["mutations"]:
            addr, _, _value = mutation_writes(m, width)
            lines.append(f"setb({addr}, {m['restore']})")
    lines.append("")
    for i, run in enumerate(walk_runs):
        lines += [
            f"# walk {i}: slot {run['slot']} "
            f"({run['sx']},{run['sy']}) -> ({run['tx']},{run['ty']})",
            "aResetMoveOverlay()",
            f"uw{i} = aGetUnitMapElementPtr({run['slot']})",
            f"aBuildMoveMap($uw{i}, 0, &scratch, 0) --zero scratch",
            f"aWalkMoveMap({run['sx']}, {run['sy']}, {run['tx']}, "
            f"{run['ty']}, &wblocked, &wsteps) "
            f"--zero wblocked --zero wsteps --dump wblocked --dump wsteps",
            f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        ]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Phase 4: aExecuteMove, the other half of the ladder rule
# ---------------------------------------------------------------------------

#: ``aExecuteMove`` (``0x0046E220``), the routine that actually walks a unit.
#: The arity is read off its only call site: ``0x0040AC43`` pushes eight
#: dwords and cleans them with ``add esp, 0x20``.  Arguments 1-4 are the two
#: cell coordinates, 5 is where the cost is written back (``lea ecx,
#: [esp+0x1c]`` at ``0x0040AC29``), and 6-8 are the literals the AI passes.
EXECUTE_MOVE_DECL = (
    "__cdecl i32 aExecuteMove(i32,i32,i32,i32,ptr,i32,i32,i32)"
    " = Incubation.exe+0x6e220\n")
#: The three trailing literals, copied from the AI's call rather than invented.
EXECUTE_MOVE_TAIL = (1, 255, 0)
#: Seconds one aExecuteMove attempt may take.  It animates, plays sound and
#: runs the Charisma path -- 3364 bytes and dozens of calls -- so unlike the
#: fills it is a plausible hang, and each attempt is bounded well below
#: :data:`ATTEMPT_TIMEOUT`.
EXECUTE_TIMEOUT = 240
#: How many times phase 4 may try -- as many as every other phase.  Limiting
#: it looked prudent against a hang and was simply wrong: the hang is already
#: bounded by :data:`EXECUTE_TIMEOUT`, while the failure that actually occurs
#: is the intermittent start-up fault of docs/91 §1 (an access violation
#: before the anchor), which costs seconds and wants retrying.  Four attempts
#: lost a probe that had already succeeded once.
EXECUTE_ATTEMPTS = DEFAULT_ATTEMPTS
#: How many movement points a probe hands its mover: enough that the ladder
#: step leaves a non-zero remainder, so the gradient the walk ascends exists.
EXECUTE_MP_MARGIN = 2


def plan_execute_runs(cells: dict[str, list[int]], units: list[dict[str, Any]],
                      tables: Any, width: int, height: int
                      ) -> list[dict[str, Any]]:
    """One walked step over a ladder pair, and the same step without it.

    docs/26 §5 reads three field-type tests out of ``aExecuteMove`` -- two for
    the delay and one for the teleporter -- and concludes it has no ladder case
    at all, so a ladder step would be *offered* by the move map at the price of
    a whole allowance and then *charged* like any other step.  That is a claim
    about a routine nothing has ever run on a ladder.  These two runs are the
    same geometry with only the field type differing, so whatever the engine
    charges is a difference and not an absolute reading.
    """
    found = _ladder_pair(cells, units, tables, width, height, over_cliff=False,
                         same_delay_as_ladder=True)
    if found is None:
        LOG.warning("no flat ladder pair; aExecuteMove stays unexercised")
        return []
    unit, (nx, ny) = found
    # The ladder probe overwrites the pair's field type, but the control does
    # not -- so the neighbour has to be somewhere a unit can walk to anyway,
    # or the control would be asking for an unreachable cell and the two
    # probes would not be the same step.
    if tables.delay(cells["field_type"][ny * width + nx]) == 255:
        LOG.warning("the ladder pair's neighbour is impassable without the "
                    "written field type; aExecuteMove stays unexercised")
        return []
    mp = int(unit["mp_allowance"]) + EXECUTE_MP_MARGIN
    runs: list[dict[str, Any]] = []
    for tag, ladder in (("ladder", True), ("control", False)):
        mutations = [_mp(unit, mp)]
        if ladder:
            mutations += [
                _field_type(cells, unit["x"], unit["y"], LADDER_TYPE, width),
                _field_type(cells, nx, ny, LADDER_TYPE, width),
            ]
        runs.append({
            "slot": unit["slot"], "tag": tag,
            "sx": unit["x"], "sy": unit["y"], "tx": nx, "ty": ny,
            "mp": mp, "mp_allowance": int(unit["mp_allowance"]),
            "mutations": mutations,
        })
    return runs


def execute_plan(runs: list[dict[str, Any]],
                 width: int = CAPTURE_WIDTH) -> str:
    """Phase 4: reload before every probe, then walk one step for real.

    **Each probe reloads the save.**  Every other phase restores what it wrote
    and leaves the process where it found it; this one moves a unit, zeroes its
    movement points and rewrites the cells it walked over, and none of that is
    undone by writing the mutated bytes back.  Reloading is the only restore
    that covers it, so the two probes cannot contaminate one another.
    """
    cells = width * CAPTURE_HEIGHT * CELL_STRIDE
    units = UNIT_SLOTS * UNIT_STRIDE
    lines = [
        "# Phase 4: aExecuteMove over a written ladder, and the same step",
        "# without one.  docs/26 section 5 -- the half of the ladder rule that",
        "# the move map's own capture cannot reach.",
        DECLARATIONS + EXECUTE_MOVE_DECL,
        "--buf scratch:4",
        "--buf wblocked:4",
        "--buf wsteps:4",
        "--buf ecost:4",
        f"--code setb:{SETB_CODE}",
        "",
    ]
    tail = ", ".join(str(v) for v in EXECUTE_MOVE_TAIL)
    for i, run in enumerate(runs):
        lines += [
            f"# probe {i}: {run['tag']}, slot {run['slot']} "
            f"({run['sx']},{run['sy']}) -> ({run['tx']},{run['ty']})",
            *_load_prologue(),
        ]
        for m in run["mutations"]:
            addr, _, value = mutation_writes(m, width)
            lines.append(f"setb({addr}, {value})")
        lines += [
            "aResetMoveOverlay()",
            f"ue{i} = aGetUnitMapElementPtr({run['slot']})",
            f"aBuildMoveMap($ue{i}, 0, &scratch, 0) --zero scratch",
            f"aWalkMoveMap({run['sx']}, {run['sy']}, {run['tx']}, "
            f"{run['ty']}, &wblocked, &wsteps) "
            f"--zero wblocked --zero wsteps --dump wblocked --dump wsteps",
            f"aExecuteMove({run['sx']}, {run['sy']}, {run['tx']}, "
            f"{run['ty']}, &ecost, {tail}) --zero ecost --dump ecost",
            f"aGetUnitMapElementPtr(0) --read $u0:{units}",
            f"aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
            "",
        ]
    return "\n".join(lines) + "\n"


def _normalise_execute(rows: list[dict[str, Any]],
                       planned: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """What each ``aExecuteMove`` probe cost, and where the unit ended up."""
    calls = [r for r in rows if r.get("call") == "aExecuteMove"]
    blocks = _reads(rows, "aGetUnitMapElementPtr", "$u0")
    if len(calls) != len(planned):
        raise CaptureError(
            f"{len(calls)} aExecuteMove calls but {len(planned)} were planned")
    if len(blocks) != len(planned):
        raise CaptureError(
            f"{len(blocks)} post-move unit arrays but {len(planned)} probes")
    out: list[dict[str, Any]] = []
    for plan, call, block in zip(planned, calls, blocks):
        reads = call.get("reads", {})
        if "ecost" not in reads:
            raise CaptureError(
                f"probe {plan['tag']} reported no cost dump")
        base = plan["slot"] * UNIT_STRIDE
        raw = block[base:base + UNIT_STRIDE]
        out.append({
            **{k: plan[k] for k in ("slot", "tag", "sx", "sy", "tx", "ty",
                                    "mp", "mp_allowance")},
            "mutations": plan["mutations"],
            "expected": {
                "ret": int(call["result"], 0),
                "cost": struct.unpack("<i", _hex(reads["ecost"]))[0],
                "mp_after": raw[UNIT_MP],
                "x_after": raw[UNIT_X],
                "y_after": raw[UNIT_Y],
            },
        })
    return out



# ---------------------------------------------------------------------------
# Running dbgcall under Wine
# ---------------------------------------------------------------------------

def _windows_path(path: Path) -> str:
    return "Z:" + str(path.resolve()).replace("/", "\\")


def _command_name(dbgcall: Path, game_copy: Path) -> str:
    """How to name the debugger to a ``cmd`` whose directory is the copy.

    A bare filename when it lives in the copy, which is where the README puts
    it.  Anywhere else it has to be an absolute Windows path -- and this cmd
    will not run one that is quoted, so a space in it has nowhere to hide and
    is refused here rather than silently mis-parsed at the far end.
    """
    dbgcall, game_copy = dbgcall.resolve(), game_copy.resolve()
    if dbgcall.parent == game_copy:
        return dbgcall.name
    windows = _windows_path(dbgcall)
    if " " in windows:
        raise CaptureError(
            f"{dbgcall} has a space in its path and is outside {game_copy}; "
            f"put the debugger in the game copy or move it somewhere "
            f"without one")
    return windows


def _reset_wine(env: dict[str, str]) -> None:
    """Tear the Wine session down between attempts.

    ``_run_scoped`` kills the attempt's own process **group**, which is what
    keeps a timed-out run from outliving its attempt -- but ``wineserver`` and
    the ``winedevice.exe`` processes it owns are deliberately detached from
    that group, so they survive it.  A half-dead session left behind that way
    poisons every later attempt in the same phase and in the phases after it:
    the symptom is a phase that loses **all** of its attempts to "did not
    reach the anchor" immediately after a phase that succeeded, which reads
    like docs/91 §1 start-up flakiness and is not.

    ``-k`` is followed by ``-k9`` because the polite form does not always
    finish the job: a phase once lost all ten of its attempts with ``-k``
    running after each one, and a hard kill by hand recovered the host
    immediately.  Both are scoped to the Wine prefix, which a ``pkill`` by
    process name would not be -- that would reach an unrelated Wine
    application the user happened to be running.

    Failures here are ignored on purpose.  There may be no session to kill,
    and a cleanup that raises would throw away the retry it is preparing.
    """
    for flag in ("-k", "-k9"):
        try:
            subprocess.run(["wineserver", flag], env=env,
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL,
                           timeout=TEARDOWN_TIMEOUT, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            LOG.debug("wineserver %s did not complete cleanly: %s", flag, exc)


def _run_scoped(command: list[str], *, env: dict[str, str] | None,
                timeout: float, cwd: Path | None = None) -> None:
    """Run one attempt in its own Unix process group and bound its lifetime."""
    process = subprocess.Popen(
        command, env=env, cwd=None if cwd is None else str(cwd),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True)
    try:
        process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise


#: The ``[!]`` lines ``dbgcall`` prints for an **environment** result rather
#: than a bad plan.  Everything else it refuses on is a plan or harness error,
#: and the retry loop must not swallow it: see :func:`run_plan`.
#: ``DieWin`` (``dbgcall.cpp``) prints ``[!] <what>`` and then an indented
#: ``error=<n>: <text>`` continuation, and every one of its call sites is a
#: Win32 API failure -- ``CreateProcessW``, ``WaitForDebugEvent``,
#: ``OpenThread``, ``GetThreadContext``, ``ContinueDebugEvent``.  Those are
#: exactly the intermittent Wine start-up failures ``docs/91`` §1 says to retry,
#: so the continuation line is what tells an **environment** result apart from a
#: plan the harness refused.  Matching on the shape rather than on a list of
#: message names is deliberate: a list would rot the next time ``dbgcall`` grows
#: a call site.
WIN32_ERROR_CONTINUATION = re.compile(r"^\s*error=\d+")

TRANSIENT_ERRORS = (
    "the anchor was not reached within",
    "Target exited before any breakpoint was",
    "Target exited with",
    "Cannot restore the thread context",
)


def run_plan(game_copy: Path, dbgcall: Path, plan_text: str, name: str,
             attempts: int = DEFAULT_ATTEMPTS,
             timeout: float = ATTEMPT_TIMEOUT) -> list[dict[str, Any]]:
    """Write a plan into the copy, run it under Wine, return the JSONL rows."""
    plan_path = game_copy / f"{name}.plan"
    out_path = game_copy / f"{name}.jsonl"
    log_path = game_copy / f"{name}.log"
    plan_path.write_text(plan_text, encoding="ascii")

    # **No path inside the command line, and no `cd`.**  The working directory
    # comes from the Unix side, which Wine maps to the current drive, so every
    # name below is a bare filename with no space in it to quote around.
    #
    # It used to be `cd /d "<copy>" && "<dbgcall>" ...`, and two separate
    # things broke it.  A copy under a path with a space made the `>` redirect
    # parse as a truncated filename; quoting fixed that, and then a Wine
    # update made `cd /d` return a non-zero exit status even where it worked,
    # so `&&` short-circuited and *nothing* ran -- the log was never created,
    # `"breakpoint hit"` was never found, and ten attempts reported the anchor
    # as unreachable.  A quoted absolute path is also not a command this cmd
    # will run.  Setting the directory outside the Wine world removes all
    # three at once.  `explorer /desktop` detaches the console, so the `cmd`
    # wrapper and its redirect stay: they are how the output reaches a file.
    inner = (
        f'{_command_name(dbgcall, game_copy)} Incubation.exe '
        f'--bp {BREAKPOINT} '
        f'--plan {name}.plan --out jsonl -o {name}.jsonl -- -english '
        f'> {name}.log 2>&1'
    )
    env = dict(os.environ, WINEDLLOVERRIDES=WINE_OVERRIDES)
    for attempt in range(1, attempts + 1):
        for path in (out_path, log_path):
            path.unlink(missing_ok=True)
        try:
            _run_scoped(
                ["wine", "explorer", f"/desktop={WINE_DESKTOP}", "cmd", "/c",
                 inner],
                env=env,
                timeout=timeout,
                cwd=game_copy)
        except subprocess.TimeoutExpired:
            # A hang is an environment result like any other, and the retry
            # loop exists for exactly that (docs/91 §1).  Letting it escape
            # crashed the capture with a traceback and threw away the phases
            # that had already succeeded.
            LOG.warning("%s: attempt %d timed out after %ds",
                        name, attempt, timeout)
            _reset_wine(env)
            continue
        log = log_path.read_text(errors="replace") if log_path.exists() else ""
        # A plan dbgcall **refuses** is not an environment result, and retrying
        # it ten times reports "did not reach the anchor" ten times for a
        # reason that has nothing to do with Wine.  A stale dbgcall.exe that
        # did not yet know the `u8` return type cost one capture exactly that,
        # and the log said so on line one the whole time.
        lines = log.splitlines()
        fatal = []
        for i, line in enumerate(lines):
            if not line.lstrip().startswith("[!]"):
                continue
            if any(t in line for t in TRANSIENT_ERRORS):
                continue
            following = lines[i + 1] if i + 1 < len(lines) else ""
            if WIN32_ERROR_CONTINUATION.match(following):
                # `DieWin`: a Win32 call failed, which on this host is an
                # environment result and is what the ten attempts are for.
                continue
            fatal.append(line)
        if fatal:
            raise CaptureError(
                f"{name}: dbgcall refused the plan -- {fatal[0].strip()}; "
                f"see {log_path}")
        if "breakpoint hit" in log and out_path.exists():
            failed = [line for line in log.splitlines() if "failed" in line]
            LOG.info("%s: attempt %d reached the anchor -- %s",
                     name, attempt, failed[-1] if failed else "no summary")
            if ", 0 failed," not in log:
                raise CaptureError(f"{name}: some calls failed; see {log_path}")
            return [json.loads(line) for line in out_path.read_text().splitlines()
                    if line.strip()]
        LOG.warning("%s: attempt %d did not reach the anchor", name, attempt)
        _reset_wine(env)
    raise CaptureError(
        f"{name}: no attempt reached {BREAKPOINT} in {attempts} tries; "
        f"see {log_path}")


def selftest_process_scope() -> int:
    """A timed-out attempt must not kill an unrelated matching process."""
    sleeper = [sys.executable, "-c", "import time; time.sleep(60)"]
    survivor = subprocess.Popen(sleeper)
    timed_out = False
    try:
        try:
            _run_scoped(sleeper, env=None, timeout=0.05)
        except subprocess.TimeoutExpired:
            timed_out = True
        survived = survivor.poll() is None
    finally:
        survivor.terminate()
        survivor.wait(timeout=5)
    if timed_out and survived:
        print("process-scope selftest passed: timed-out group killed, survivor alive")
        return 0
    print("process-scope selftest FAILED", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# Normalising a run into the fixture
# ---------------------------------------------------------------------------

def _hex(value: str) -> bytes:
    return bytes.fromhex(value.replace(" ", ""))


def _reads(rows: list[dict[str, Any]], call: str, key: str) -> list[bytes]:
    out: list[bytes] = []
    for row in rows:
        if row.get("call") == call and key in row.get("reads", {}):
            out.append(_hex(row["reads"][key]))
    return out


def cells_of(ctrlmap: bytes, width: int, height: int) -> dict[str, list[int]]:
    """The cell arrays, in the schema ``missions/<name>/map.json`` uses."""
    n = width * height
    if len(ctrlmap) != n * CELL_STRIDE:
        raise CaptureError(
            f"control map is {len(ctrlmap)} bytes, expected {n * CELL_STRIDE}")

    def field(offset: int) -> list[int]:
        return [ctrlmap[i * CELL_STRIDE + offset] for i in range(n)]

    units: list[int] = []
    heights: list[int] = []
    for i in range(n):
        base = i * CELL_STRIDE
        link = struct.unpack_from("<H", ctrlmap, base + CELL_UNIT)[0]
        units.append(-1 if link == 0xFFFF else link)
        heights.append(struct.unpack_from("<i", ctrlmap, base + CELL_HEIGHT)[0])
    return {
        "height": heights,
        "field_type": field(CELL_FIELD_TYPE),
        "action_point": field(CELL_ACTION_POINT),
        "unit": units,
        "obstacle": field(CELL_OBSTACLE),
        "effect0": field(CELL_EFFECT0),
        "effect1": field(CELL_EFFECT0 + 1),
        "effect2": field(CELL_EFFECT0 + 2),
        "effect3": field(CELL_EFFECT0 + 3),
    }


def overlay_of(ctrlmap: bytes, n: int) -> dict[str, list[int]]:
    """The overlay a fill left behind: ``+0x00`` and ``+0x0C``."""
    return {
        "state": [ctrlmap[i * CELL_STRIDE + CELL_STATE] for i in range(n)],
        "mp_left": [ctrlmap[i * CELL_STRIDE + CELL_MP_LEFT] for i in range(n)],
    }


def units_of(block: bytes, tables: Any,
             ai_level: int = 1) -> list[dict[str, Any]]:
    """Every slot the engine holds live, with what the fill reads from it.

    ``mp_allowance`` is **computed** by :func:`inclib.allowance.movement_allowance`
    rather than taken as ``mpMax``.  The fill asks ``aGetMovePoints`` for it at
    the ladder step, so a capture that fed the model the raw table value would
    disagree with the engine on any unit wearing a Servo System -- and the same
    routine is called natively in phase 3, which is what makes this a
    computation and not a guess.
    """
    out: list[dict[str, Any]] = []
    for slot in range(UNIT_SLOTS):
        raw = block[slot * UNIT_STRIDE:(slot + 1) * UNIT_STRIDE]
        if not raw[UNIT_HP]:
            continue
        type_id = raw[UNIT_TYPE]
        row = tables.units.get(type_id)
        equipment = raw[UNIT_EQUIPMENT:UNIT_EQUIPMENT + UNIT_EQUIPMENT_SLOTS]
        out.append({
            "slot": slot,
            "name": raw[:UNIT_MP].split(b"\0")[0].decode("cp1252", "replace"),
            "type_id": type_id,
            "player": raw[UNIT_PLAYER],
            "x": raw[UNIT_X],
            "y": raw[UNIT_Y],
            "mp": raw[UNIT_MP],
            "hp": raw[UNIT_HP],
            "fp": raw[UNIT_FP],
            "rested": raw[UNIT_RESTED],
            "action_state": raw[UNIT_ACTION_STATE],
            "visibility": raw[UNIT_VISIBILITY],
            "special": 0 if row is None else row.special,
            "size": 0 if row is None else row.size,
            "mp_max": 0 if row is None else row.mp_max,
            "has_jet_pack": bool(equipment[JET_PACK_EQUIP_ID]),
            "equipment_ids": [i for i, v in enumerate(equipment) if v],
        })
    for record in out:
        record["mp_allowance"] = allowance_of(record, out, ai_level)
    return out


def allowance_unit(record: Mapping[str, Any]) -> AllowanceUnit:
    """One fixture unit record as the allowance formula's input."""
    return AllowanceUnit(
        slot=int(record["slot"]), type_id=int(record["type_id"]),
        player=int(record["player"]), x=int(record["x"]), y=int(record["y"]),
        hp=int(record["hp"]), fp=int(record.get("fp", 255)),
        rested=int(record.get("rested", 0)),
        action_state=int(record.get("action_state", 0)),
        equipment_ids=frozenset(int(i) for i in record["equipment_ids"]))


def allowance_of(record: Mapping[str, Any], units: Sequence[Mapping[str, Any]],
                 ai_level: int = 1) -> int:
    """``aGetMovePoints`` for one record, given every live slot around it."""
    return movement_allowance(allowance_unit(record), int(record["mp_max"]),
                              [allowance_unit(u) for u in units], ai_level)


def normalise(state_rows: list[dict[str, Any]], fill_rows: list[dict[str, Any]],
              tables: Any, source: dict[str, Any],
              planned: list[dict[str, Any]],
              extra_rows: list[dict[str, Any]] | None = None,
              allowance_runs: list[dict[str, Any]] | None = None,
              walk_runs: list[dict[str, Any]] | None = None,
              execute_rows: list[dict[str, Any]] | None = None,
              execute_runs: list[dict[str, Any]] | None = None
              ) -> dict[str, Any]:
    """Turn two dbgcall runs into the committed capture shape."""
    width, height = CAPTURE_WIDTH, CAPTURE_HEIGHT
    n = width * height

    state_maps = _reads(state_rows, "aGetCtrlMapElementPtr", "$c0")
    fill_maps = _reads(fill_rows, "aGetCtrlMapElementPtr", "$c0")
    if not state_maps or not fill_maps:
        raise CaptureError("no control-map reads in the run")
    unit_blocks = _reads(fill_rows, "aGetUnitMapElementPtr", "$u0")
    if not unit_blocks:
        raise CaptureError("no unit-array read in the fill run")

    baseline = fill_maps[0]
    # The two runs load the same save in the same way; if their pre-fill state
    # differs, the capture is not reproducible and nothing below is worth
    # keeping.
    if cells_of(state_maps[0], width, height) != cells_of(baseline, width, height):
        raise CaptureError(
            "the two runs disagree about the loaded map -- the load is not "
            "deterministic, so the capture cannot stand as an oracle")

    fills = [row for row in fill_rows if row.get("call") == "aBuildMoveMap"]
    overlays = fill_maps[1:]
    if len(fills) != len(overlays):
        raise CaptureError(
            f"{len(fills)} fills but {len(overlays)} overlay reads")

    if len(planned) != len(fills):
        raise CaptureError(
            f"{len(fills)} fills but {len(planned)} were planned")

    runs: list[dict[str, Any]] = []
    for plan, call, ctrlmap in zip(planned, fills, overlays):
        slot, flag = plan["slot"], plan["pass_friendlies"]
        # dbgcall reports the callee's name, not the binding, so the slot comes
        # from the plan order; the flag argument is the cross-check that the
        # order is the one that ran.
        if bool(int(call["args"][1])) != flag:
            raise CaptureError(
                f"fill for slot {slot} ran with pass_friendlies="
                f"{call['args'][1]}, expected {int(flag)}")
        reads = call.get("reads", {})
        if "scratch" not in reads:
            # Silently defaulting this wrote `any_friendly_blocked: False` into
            # the fixture and then asserted it as engine ground truth.  Every
            # sibling read raises; so does this one now.
            raise CaptureError(
                f"fill for slot {slot} reported no scratch dump; the capture "
                f"cannot stand as an oracle")
        scratch = reads["scratch"]
        runs.append({
            "slot": slot,
            "pass_friendlies": flag,
            "mutations": plan.get("mutations", []),
            # The tags the coverage checks read.  Losing one does not change a
            # single captured byte, so nothing else notices -- which is why
            # `coverage.clearance` counts tagged runs rather than trusting the
            # plan it was generated from.
            **{key: plan[key] for key in ("ladder", "clearance", "obstacle",
                                          "obstacle_cell", "hidden")
               if key in plan},
            "expected": {
                **overlay_of(ctrlmap, n),
                "any_friendly_blocked": bool(
                    struct.unpack("<I", _hex(scratch))[0]),
                "ret": int(call["result"], 0) if "result" in call else None,
            },
        })

    ai_level = 1
    if extra_rows is not None:
        extra_maps = _reads(extra_rows, "aGetCtrlMapElementPtr", "$c0")
        if not extra_maps:
            raise CaptureError("phase 3 produced no control map")
        if cells_of(extra_maps[0], width, height) != \
                cells_of(baseline, width, height):
            raise CaptureError(
                "phase 3 loaded a different map from phase 2; the walks would "
                "be compared against the wrong cells")
        level = [r for r in extra_rows if r.get("call") == "aGetAILevel"]
        if not level:
            raise CaptureError("phase 3 did not report the AI level")
        # 0x00460450 is asked rather than assumed: it decides the base
        # allowance of unit type 0x32, and this save answers 0, not the 1 a
        # reasonable default would have picked.
        ai_level = int(level[0]["result"], 0)

    payload = {
        "schema": FIXTURE_SCHEMA,
        "mission": CAPTURE_MISSION,
        "width": width,
        "height": height,
        "source": source,
        "state_reset_value": STATE_RESET,
        "ai_level": ai_level,
        "cells": cells_of(baseline, width, height),
        "units": units_of(unit_blocks[0], tables, ai_level),
        "runs": runs,
    }
    if extra_rows is not None:
        payload["allowances"] = _normalise_allowances(
            extra_rows, allowance_runs or [])
        payload["walks"] = _normalise_walks(
            extra_rows, walk_runs or [], width, height)
    # Phase 4 is opportunistic: aExecuteMove animates, and an attempt that
    # never returns is an environment result rather than a finding.  The key
    # is present and empty when it did not run, so a reader can tell "not
    # captured" from "captured nothing".
    payload["execute_move"] = (
        _normalise_execute(execute_rows, execute_runs or [])
        if execute_rows is not None else [])
    return payload


def _normalise_allowances(rows: list[dict[str, Any]],
                          planned: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """``aGetMovePoints`` results, paired with the mutations that produced them.

    The routine returns its answer in ``AL`` and leaves the rest of ``EAX``
    holding whatever the fitness-point arithmetic left there (``0x00475233``
    is ``mov al, bl``), so only the low byte is the answer.
    """
    calls = [r for r in rows if r.get("call") == "aGetMovePoints"]
    if len(calls) != len(planned):
        raise CaptureError(
            f"{len(calls)} allowance calls but {len(planned)} were planned")
    out: list[dict[str, Any]] = []
    for plan, call in zip(planned, calls):
        out.append({
            "slot": plan["slot"],
            "tag": plan["tag"],
            "mutations": plan["mutations"],
            "expected": int(call["result"], 0) & 0xFF,
        })
    return out


def _normalise_walks(rows: list[dict[str, Any]], planned: list[dict[str, Any]],
                     width: int, height: int) -> list[dict[str, Any]]:
    """``aWalkMoveMap`` results, each with the overlay it left behind."""
    calls = [r for r in rows if r.get("call") == "aWalkMoveMap"]
    maps = _reads(rows, "aGetCtrlMapElementPtr", "$c0")[1:]
    if len(calls) != len(planned):
        raise CaptureError(
            f"{len(calls)} walks but {len(planned)} were planned")
    if len(maps) != len(planned):
        raise CaptureError(
            f"{len(maps)} post-walk control maps but {len(planned)} walks")
    n = width * height
    out: list[dict[str, Any]] = []
    for plan, call, ctrlmap in zip(planned, calls, maps):
        reads = call.get("reads", {})
        out.append({
            **{k: plan[k] for k in ("slot", "sx", "sy", "tx", "ty")},
            "reachable": plan["reachable"],
            "expected": {
                "ret": int(call["result"], 0),
                "blocked": struct.unpack("<i", _hex(reads["wblocked"]))[0],
                "steps": struct.unpack("<i", _hex(reads["wsteps"]))[0],
                "state": [ctrlmap[i * CELL_STRIDE + CELL_STATE]
                          for i in range(n)],
            },
        })
    return out


# ---------------------------------------------------------------------------
# Checking a capture against the executable model
# ---------------------------------------------------------------------------

def check_fixture(root: Path, fixture_path: Path) -> int:
    c = Checker()
    if not fixture_path.is_file():
        c.check("capture.present", False,
                f"{fixture_path} is missing; run --game-copy to produce it")
        return c.report()
    fixture = json.loads(fixture_path.read_text())
    c.expect("capture.schema", fixture.get("schema"), FIXTURE_SCHEMA)
    try:
        tables = load_info(str(root))
    except InfoError as exc:
        c.check("info.load", False, str(exc))
        return c.report()
    delays = tables.delay_table()

    units = {u["slot"]: u for u in fixture["units"]}
    reset = fixture.get("state_reset_value", STATE_RESET)
    n = fixture["width"] * fixture["height"]

    c.check("capture.runs", bool(fixture["runs"]),
            f"{len(fixture['runs'])} native fills over {len(units)} live slots")

    state_bad = 0
    mp_bad = 0
    scratch_bad = 0
    for run in fixture["runs"]:
        cells = {k: list(v) for k, v in fixture["cells"].items()}
        run_units = {s: dict(u) for s, u in units.items()}
        for mutation in run.get("mutations", []):
            apply_mutation(mutation, cells, run_units, fixture["width"])
        grid = Grid(fixture["width"], fixture["height"], cells["height"],
                    cells["field_type"], cells["action_point"])
        hooks = hooks_from_arrays(
            fixture["width"], cells["unit"],
            visibility={s: u["visibility"] for s, u in run_units.items()},
            players={s: u["player"] for s, u in run_units.items()},
            obstacles=cells["obstacle"])
        unit = run_units[run["slot"]]
        mover = Mover(
            slot=unit["slot"], x=unit["x"], y=unit["y"], player=unit["player"],
            mp=unit["mp"], special=unit["special"], size=unit["size"],
            has_jet_pack=unit["has_jet_pack"],
            mp_allowance=unit["mp_allowance"])
        # The capture zeroes the scratch buffer before every call, so the
        # value the engine sees on entry is 0 -- which is what the `special`
        # refusal leaves behind, since it returns without touching it.
        result = build(grid, mover, delays, hooks,
                       pass_friendlies=run["pass_friendlies"],
                       any_friendly_blocked=False)
        want_state = [STATE_NONE if v == reset else v
                      for v in run["expected"]["state"]]
        if result.state != want_state:
            state_bad += sum(1 for i in range(n)
                             if result.state[i] != want_state[i])
        if result.mp_left != run["expected"]["mp_left"]:
            mp_bad += sum(1 for i in range(n)
                          if result.mp_left[i] != run["expected"]["mp_left"][i])
        if result.any_friendly_blocked != run["expected"]["any_friendly_blocked"]:
            scratch_bad += 1

    c.expect("native.state", state_bad, 0,
             f"{len(fixture['runs'])} fills x {n} cells")
    c.expect("native.mp_left", mp_bad, 0,
             f"{len(fixture['runs'])} fills x {n} cells")
    c.expect("native.any_friendly_blocked", scratch_bad, 0)
    # State what the capture actually covers, so nobody reads it as more.
    kinds: dict[str, set[int]] = {}
    for run in fixture["runs"]:
        for mutation in run.get("mutations", []):
            kinds.setdefault(mutation["kind"], set()).add(
                int(mutation.get("value", 0)))
    warp_native = (JET_PACK_EQUIP_ID in kinds.get("unit_equipment", set())
                   or 15 in kinds.get("type_special", set()))
    _check_hidden(c, fixture, reset)
    c.check("coverage.warp", warp_native,
            "the warp pass is reached natively by writing the Jet Pack and "
            "special 15 that no shipped unit on this mission carries")
    c.expect("coverage.obstacle", sorted(kinds.get("cell_obstacle", set())),
             [1, 2, 3],
             "fire, mine and shield are written into cells that hold 255 in "
             "all 184162 shipped ones")
    c.expect("coverage.refusals",
             sorted(v for v in kinds.get("type_special", set()) if v in (1, 14)),
             [1, 14], "both aBuildMoveMap refusals are exercised natively")
    c.check("coverage.mp_sweep",
            len(kinds.get("unit_mp", set())) >= 4,
            f"movement points swept over {sorted(kinds.get('unit_mp', set()))}")
    ladder = [r for r in fixture["runs"] if r.get("ladder")]
    c.check("coverage.ladder", bool(ladder),
            f"{len(ladder)} fills over a written field type 8 -- the branch no "
            f"shipped cell in any of the 155 missions can reach")
    c.check("coverage.ladder_cliff",
            any(r.get("ladder") == "cliff" for r in ladder),
            "one ladder pair straddles a height difference the climb rule "
            "would otherwise block, which is what shows the rule is skipped")
    _check_clearance(c, fixture, delays)
    _check_obstacles(c, fixture, reset)
    _check_execute_move(c, fixture)

    _check_allowances(c, fixture)
    _check_walks(c, fixture, delays)
    return c.report()



def _check_hidden(c: Checker, fixture: dict[str, Any], reset: int) -> None:
    """A hidden unit's cell was **reached**, not merely present in the roster.

    This used to be `bool([u for u in units if u["visibility"] == 3])`, which
    is a fact about the save and not about any fill: making a hidden unit
    block like every other unit left the model agreeing with all 73 captured
    fills, and the report still printed "the visibility-3 branch is native".
    """
    width = fixture["width"]
    runs = [r for r in fixture["runs"] if r.get("hidden")]
    if not runs:
        c.check("coverage.hidden", False,
                "no captured fill reaches a hidden unit's cell, so the "
                "visibility-3 branch of docs/23 §7.3 is specification-only")
        return
    for run in runs:
        target: dict[str, Any] = run["hidden"]
        x, y = target["cell"]
        state = run["expected"]["state"]
        value = STATE_NONE if state[y * width + x] == reset \
            else state[y * width + x]
        c.expect(f"coverage.hidden.slot{target['slot']}", value,
                 STATE_REACHABLE,
                 f"slot {run['slot']} walks onto ({x},{y}) where hidden slot "
                 f"{target['slot']} stands, so the engine treats a hidden "
                 f"unit as empty ground")


def _check_obstacles(c: Checker, fixture: dict[str, Any], reset: int) -> None:
    """The mine's owner test, which is the only reason the player id matters.

    docs/23 §7.1: fire stops everyone, a mine stops everyone **except** units
    owned by player 255.  The runs used to write every obstacle beside the
    *first* mover while issuing the fill for each mover in turn, so the alien
    never met a mine and deleting the exemption from the model changed
    nothing here.  These compare the two owners on their own cells.
    """
    width = fixture["width"]
    tagged = [r for r in fixture["runs"] if r.get("obstacle")]
    if not tagged:
        c.check("coverage.mine_owner", False,
                "no tagged obstacle runs; re-take the capture")
        return

    def entered(run: dict[str, Any]) -> bool:
        x, y = run["obstacle_cell"]
        value = run["expected"]["state"][y * width + x]
        return (STATE_NONE if value == reset else value) == STATE_REACHABLE

    by_tag = {r["obstacle"]: r for r in tagged}
    mine = {tag: run for tag, run in by_tag.items() if tag.startswith("2.")}
    fire = {tag: run for tag, run in by_tag.items() if tag.startswith("1.")}
    aliens = [run for tag, run in mine.items() if tag.endswith(".player255")]
    others = [run for tag, run in mine.items() if not tag.endswith(".player255")]
    c.check("coverage.mine_owner", bool(aliens) and bool(others),
            f"a mine written beside a player-255 mover and beside one owned "
            f"by somebody else: {sorted(mine)}")
    for run in aliens:
        c.check(f"mine.alien_passes.slot{run['slot']}", entered(run),
                "a mine does not stop a unit owned by player 255")
    for run in others:
        c.check(f"mine.stops.slot{run['slot']}", not entered(run),
                "a mine stops a unit owned by anybody else")
    for run in fire.values():
        c.check(f"fire.stops.slot{run['slot']}", not entered(run),
                "fire stops every owner, player 255 included")


def _check_clearance(c: Checker, fixture: dict[str, Any],
                     delays: Mapping[int, int]) -> None:
    """The large-unit clearance test, ``0x0047A410`` (docs/23 §7.3).

    The fills above already require the model to reproduce every captured
    overlay cell for cell, so these do not re-check the arithmetic.  What they
    check is that the capture **exercised** the rule: a run where the engine
    behaved exactly as it would for a small unit would satisfy `native.state`
    and prove nothing at all.
    """
    runs = [r for r in fixture["runs"] if r.get("clearance")]
    c.check("coverage.clearance", bool(runs),
            f"{len(runs)} fills by a mover written large -- size is 1 on only "
            f"ComBot, Tr'Yn and Al'Coo, and none is on this mission")
    if not runs:
        return
    width, height = fixture["width"], fixture["height"]
    reset = fixture.get("state_reset_value", STATE_RESET)
    units = {u["slot"]: u for u in fixture["units"]}

    decided = 0
    kept = 0
    for run in runs:
        if run["clearance"] != "large":
            continue
        cells = {k: list(v) for k, v in fixture["cells"].items()}
        run_units = {slot: dict(u) for slot, u in units.items()}
        for mutation in run.get("mutations", []):
            apply_mutation(mutation, cells, run_units, width)
        native = [STATE_NONE if v == reset else v
                  for v in run["expected"]["state"]]
        # The same inputs, with only the size byte back to 0.  Every other
        # mutation stays applied, so the difference is the clearance test and
        # nothing else.
        small = _model_fill(cells, list(run_units.values()),
                            run_units[run["slot"]], delays, width, height,
                            run_units[run["slot"]]["mp"], 0,
                            run["pass_friendlies"])
        decided += sum(1 for i in range(width * height)
                       if small[i] == STATE_REACHABLE
                       and native[i] != STATE_REACHABLE)
        kept += sum(1 for v in native if v == STATE_REACHABLE) - 1
    c.check("clearance.blocks", decided > 0,
            f"{decided} cells a small unit reaches are refused to a large one")
    c.check("clearance.passes", kept > 0,
            f"{kept} cells past the mover's own still pass the test, so the "
            f"capture covers both arms and not only the refusal")

    # The 2x2.  `large` is the no-fire corner of the large row; the other
    # three are the tagged fire runs.
    square = {"large": None, "fire": None, "fire_control": None,
              "fire_control_dry": None}
    for run in runs:
        tag = run["clearance"]
        if tag in square and square[tag] is None \
                and run["pass_friendlies"] is False:
            square[tag] = run
    if any(run is None for run in square.values()):
        c.check("clearance.fire", False,
                "the fire arm of 0x0047A410 was not captured: "
                + ", ".join(sorted(k for k, v in square.items() if v is None))
                + " missing")
        return

    def reachable(run: dict[str, Any]) -> int:
        return sum(1 for v in run["expected"]["state"]
                   if v == STATE_REACHABLE)

    big_dry = reachable(square["large"])
    big_wet = reachable(square["fire"])
    small_dry = reachable(square["fire_control_dry"])
    small_wet = reachable(square["fire_control"])
    c.check("clearance.fire",
            big_dry - big_wet > small_dry - small_wet,
            f"one fire written diagonally from a candidate costs a large "
            f"mover {big_dry - big_wet} cells ({big_dry} -> {big_wet}) and a "
            f"small one on the identical map {small_dry - small_wet} "
            f"({small_dry} -> {small_wet}); the excess is the clearance "
            f"test's own fire condition, which the obstacle byte being 255 "
            f"in all 184162 shipped cells leaves without any other evidence")



def _check_execute_move(c: Checker, fixture: dict[str, Any]) -> None:
    """The ``aExecuteMove`` probes of phase 4, when the phase ran.

    The phase is opportunistic -- the routine animates and can hang under Wine
    -- so an empty list is reported rather than failed.  It is still a check:
    the key must exist, and the detail says in words whether the branch has
    evidence, so "not captured" cannot be read as "captured and fine".
    """
    probes = fixture.get("execute_move")
    if probes is None:
        c.check("coverage.execute_move", False,
                "the capture predates phase 4; re-take it with --game-copy")
        return
    if not probes:
        c.check("coverage.execute_move", True,
                "0 probes -- aExecuteMove's half of the ladder rule "
                "(docs/26 §5) is still unexercised")
        return
    c.check("coverage.execute_move", True,
            f"{len(probes)} walked steps, one over a written field type 8")
    by_tag = {p["tag"]: p for p in probes}
    for tag, probe in sorted(by_tag.items()):
        got = probe["expected"]
        c.expect(f"execute.{tag}.arrived", [got["x_after"], got["y_after"]],
                 [probe["tx"], probe["ty"]],
                 "the unit stands on the target cell afterwards")
        # **aExecuteMove reports the cost and does not spend it.**  The unit's
        # `+0x15` is untouched by the call; docs/23 §5.3's tail does the
        # subtraction -- `u->mp = (cost > u->mp) ? 0 : u->mp - cost` -- in the
        # *caller*, after aExecuteFight and after the death test.  A remake
        # that put the charge inside its own move routine would double-charge
        # the AI path and leave the player's path uncharged.
        c.expect(f"execute.{tag}.does_not_charge", got["mp_after"],
                 probe["mp"],
                 f"mp is still {probe['mp']} although the call reported a "
                 f"cost of {got['cost']}; the caller spends it")
        c.check(f"execute.{tag}.reports_a_cost", got["cost"] > 0,
                f"cost {got['cost']} written back through argument 5")
    if "ladder" in by_tag and "control" in by_tag:
        ladder = by_tag["ladder"]["expected"]["cost"]
        control = by_tag["control"]["expected"]["cost"]
        allowance = by_tag["ladder"]["mp_allowance"]
        # The two halves of the engine disagree or they do not, and this is
        # the number that says which.  aBuildMoveMap charges a ladder step the
        # whole allowance; docs/26 §5 reads aExecuteMove as having no ladder
        # case at all, which would make these two equal.
        c.expect("execute.ladder_charges_the_same", ladder, control,
                 f"a ladder step costs {ladder} and the same step over plain "
                 f"ground {control}, against an allowance of {allowance} -- "
                 f"docs/26 §5's reading of aExecuteMove holds")


def _check_allowances(c: Checker, fixture: dict[str, Any]) -> None:
    """The formula against ``aGetMovePoints`` in the live process."""
    runs = fixture.get("allowances")
    if not runs:
        c.check("allowance.present", False,
                "the capture holds no aGetMovePoints calls; re-take it")
        return
    units = {u["slot"]: u for u in fixture["units"]}
    bad: list[str] = []
    for run in runs:
        live = {s: dict(u) for s, u in units.items()}
        cells: dict[str, list[int]] = {"obstacle": [], "field_type": [],
                                       "unit": []}
        for mutation in run["mutations"]:
            apply_mutation(mutation, cells, live, fixture["width"])
        record = live[run["slot"]]
        got = allowance_of(record, list(live.values()),
                           int(fixture.get("ai_level", 1)))
        if got != run["expected"]:
            bad.append(f"{run['tag']}: model {got}, engine {run['expected']}")
    c.expect("allowance.formula", bad, [],
             f"{len(runs)} aGetMovePoints calls in the live process")

    tags = {run["tag"] for run in runs}
    c.check("allowance.coverage.equipment",
            any(t.startswith("equip") for t in tags)
            and "servo+armor" in tags,
            "the Servo System and the Heavy Armor are written and called")
    c.check("allowance.coverage.fitness",
            {"fp0", "fp1", "fp2"} <= tags and "rested+fp1" in tags,
            "both fitness overrides, and one against the rested bonus")
    c.check("allowance.coverage.suppressed",
            {"action5", "action6"} <= tags,
            "both action states that zero the allowance")
    banner = sorted(t for t in tags if t.startswith("banner"))
    c.check("allowance.coverage.banner", len(banner) >= 4,
            f"the Banner scan at {len(banner)} placements: {banner}")
    # The metric question docs/10 5.5 left open, decided by one placement.
    c.check("allowance.coverage.banner_owner",
            any(t.endswith("other_player") for t in tags),
            "a Banner in range but owned by someone else must not count")
    at33 = next((r for r in runs if r["tag"] == "banner+3,3"), None)
    at30 = next((r for r in runs if r["tag"] == "banner+3,0"), None)
    if at33 is not None and at30 is not None:
        c.check("allowance.banner_metric",
                at30["expected"] > at33["expected"],
                "(3,0) is in range and (3,3) is not, so the reach is "
                "floor-Euclidean and strictly below 4 -- Chebyshev would put "
                "both in range")


def _check_walks(c: Checker, fixture: dict[str, Any],
                 delays: Mapping[int, int]) -> None:
    """The path model against ``aWalkMoveMap`` in the live process."""
    runs = fixture.get("walks")
    if not runs:
        c.check("walk.present", False,
                "the capture holds no aWalkMoveMap calls; re-take it")
        return
    units = {u["slot"]: u for u in fixture["units"]}
    cells = fixture["cells"]
    width, height = fixture["width"], fixture["height"]
    reset = fixture.get("state_reset_value", STATE_RESET)
    grid = Grid(width, height, cells["height"], cells["field_type"],
                cells["action_point"])
    hooks = hooks_from_arrays(
        width, cells["unit"],
        visibility={s: u["visibility"] for s, u in units.items()},
        players={s: u["player"] for s, u in units.items()},
        obstacles=cells["obstacle"])
    ret_bad: list[str] = []
    step_bad: list[str] = []
    path_bad = 0
    diagonals = 0
    for run in runs:
        unit = units[run["slot"]]
        mover = Mover(slot=unit["slot"], x=unit["x"], y=unit["y"],
                      player=unit["player"], mp=unit["mp"],
                      special=unit["special"], size=unit["size"],
                      has_jet_pack=unit["has_jet_pack"],
                      mp_allowance=unit["mp_allowance"])
        fill = build(grid, mover, delays, hooks, pass_friendlies=False)
        got = walk(grid, fill, run["sx"], run["sy"], run["tx"], run["ty"],
                   delays, hooks)
        want = run["expected"]
        tag = f"({run['sx']},{run['sy']})->({run['tx']},{run['ty']})"
        if int(got.ok) != int(want["ret"]):
            ret_bad.append(f"{tag}: model {int(got.ok)}, engine {want['ret']}")
            continue
        if not got.ok:
            continue
        if got.steps != want["steps"] or got.blocked != want["blocked"]:
            step_bad.append(
                f"{tag}: model {got.steps}/{got.blocked}, "
                f"engine {want['steps']}/{want['blocked']}")
        engine_state = [STATE_PATH if v == STATE_PATH else reset
                        for v in want["state"]]
        if got.state != engine_state:
            path_bad += sum(1 for i in range(width * height)
                            if got.state[i] != engine_state[i])
        for a, b in zip(got.path, got.path[1:]):
            if abs(a % width - b % width) == 1 and abs(a // width
                                                       - b // width) == 1:
                diagonals += 1
    c.expect("walk.ret", ret_bad, [], f"{len(runs)} native walks")
    c.expect("walk.steps_and_blocked", step_bad, [])
    c.expect("walk.overlay", path_bad, 0,
             "every cell of every reconstructed path, and the sweep that "
             "clears the rest")
    c.check("walk.failure_arm",
            any(not r["expected"]["ret"] for r in runs),
            "a walk to a cell the fill never marked returns FALSE, which is "
            "the 'no direction found' arm")
    c.check("walk.diagonals", diagonals > 0,
            f"{diagonals} diagonal steps appear in paths the 4-connected fill "
            f"costed -- docs/23 8's asymmetry, now measured rather than "
            f"warned about")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _dump(payload: dict[str, Any], out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                              separators=(",", ":"), allow_nan=False) + "\n",
                   encoding="utf-8")
    LOG.info("wrote %s (%d bytes, sha256 %s)", out, out.stat().st_size,
             _sha256(out)[:16])


def capture(game_copy: Path, dbgcall: Path, root: Path, out: Path,
            attempts: int) -> int:
    repo = Path(__file__).resolve().parent.parent
    if is_within(game_copy, repo):
        raise CaptureError(
            f"{game_copy} is inside this repository; the capture must run "
            f"from a copy of the game, never from gog_incubation/")
    save = game_copy / "Work" / "Saves2" / f"_{CAPTURE_SLOT}_.sav"
    if not save.is_file():
        raise CaptureError(f"the copy needs {save}")
    if not dbgcall.is_file():
        raise CaptureError(f"no dbgcall at {dbgcall}")
    tables = load_info(str(root))

    state_rows = run_plan(game_copy, dbgcall, state_plan(), "gold_state",
                          attempts)
    unit_blocks = _reads(state_rows, "aGetUnitMapElementPtr", "$u0")
    if not unit_blocks:
        raise CaptureError("phase 1 produced no unit array")
    state_maps = _reads(state_rows, "aGetCtrlMapElementPtr", "$c0")
    if not state_maps:
        raise CaptureError("phase 1 produced no control map")
    base_cells = cells_of(state_maps[0], CAPTURE_WIDTH, CAPTURE_HEIGHT)
    # The AI level is an **input to the allowance**, and the planner computes
    # allowances.  It used to take the `ai_level=1` default here while this
    # save's engine answers 0, which is one movement point on unit type 0x32 --
    # enough to put the ladder sweep's "just below the boundary" probe on the
    # wrong side of the boundary it exists to establish.
    level_rows = [r for r in state_rows if r.get("call") == "aGetAILevel"]
    if not level_rows:
        raise CaptureError("phase 1 did not report the AI level")
    ai_level = int(level_rows[0]["result"], 0)
    live = units_of(unit_blocks[0], tables, ai_level)
    LOG.info("phase 1: %d live slots at AI level %d -- %s",
             len(live), ai_level, [u["slot"] for u in live])

    planned = plan_runs(base_cells, live, tables, CAPTURE_WIDTH, CAPTURE_HEIGHT)
    LOG.info("phase 2: %d fills, %d of them with mutations", len(planned),
             sum(1 for r in planned if r["mutations"]))
    fill_rows = run_plan(game_copy, dbgcall, fill_plan(planned), "gold_fill",
                         attempts)

    allowance_runs = plan_allowance_runs(live, CAPTURE_WIDTH, CAPTURE_HEIGHT)
    walk_runs = plan_walk_runs(base_cells, live, tables, CAPTURE_WIDTH,
                               CAPTURE_HEIGHT)
    LOG.info("phase 3: %d allowance calls, %d walks",
             len(allowance_runs), len(walk_runs))
    extra_rows = run_plan(game_copy, dbgcall,
                          extra_plan(allowance_runs, walk_runs), "gold_extra",
                          attempts)
    # Phase 4 last, and last on purpose: it is the only phase that moves a
    # unit, so a failure here must not cost the three that already succeeded.
    execute_runs = plan_execute_runs(base_cells, live, tables, CAPTURE_WIDTH,
                                     CAPTURE_HEIGHT)
    execute_rows: list[dict[str, Any]] | None = None
    if execute_runs:
        LOG.info("phase 4: %d aExecuteMove probes", len(execute_runs))
        try:
            execute_rows = run_plan(game_copy, dbgcall,
                                    execute_plan(execute_runs), "gold_execute",
                                    attempts=EXECUTE_ATTEMPTS,
                                    timeout=EXECUTE_TIMEOUT)
        except Exception as exc:  # noqa: BLE001 -- see below
            # Deliberately every exception, not just CaptureError.  Phase 4 is
            # the opportunistic one and it runs last precisely so that its
            # failure costs nothing; a narrow clause let a bug in *building*
            # its plan throw away three phases that had already succeeded,
            # which is the whole thing the ordering was for.
            LOG.warning("phase 4 did not complete (%s: %s); aExecuteMove's "
                        "half of the ladder rule stays unexercised",
                        type(exc).__name__, exc)
            execute_rows = None

    source = {
        "exe_sha256": _sha256(game_copy / "Incubation.exe"),
        "save": f"Work/Saves2/_{CAPTURE_SLOT}_.sav",
        "save_sha256": _sha256(save),
        "breakpoint": BREAKPOINT,
    }
    payload = normalise(state_rows, fill_rows, tables, source, planned,
                        extra_rows, allowance_runs, walk_runs, execute_rows,
                        execute_runs)
    _dump(payload, out)
    return 0


def emit_cases(fixture_path: Path, out: Path, root: Path) -> int:
    """Re-express a capture in the shared case shape the GDScript side reads.

    Each case carries the state **after** its mutations, so the GDScript test
    applies nothing: the inputs it builds a world from are the inputs the engine
    actually saw.
    """
    fixture = json.loads(fixture_path.read_text())
    delays = load_info(str(root)).delay_table()
    units = {u["slot"]: u for u in fixture["units"]}
    width, height = fixture["width"], fixture["height"]
    reset = fixture.get("state_reset_value", STATE_RESET)
    cases: list[dict[str, Any]] = []
    for i, run in enumerate(fixture["runs"]):
        cells = {k: list(v) for k, v in fixture["cells"].items()}
        run_units = {s: dict(u) for s, u in units.items()}
        for mutation in run.get("mutations", []):
            apply_mutation(mutation, cells, run_units, width)
        grid = Grid(width, height, cells["height"], cells["field_type"],
                    cells["action_point"])
        unit_list = [run_units[s] for s in sorted(run_units)]
        expected_state = [0 if v == reset else v
                          for v in run["expected"]["state"]]
        tag = "+".join(m["kind"] for m in run.get("mutations", [])) or "asis"
        case = make_case(
            f"{fixture['mission']}.{i:02d}.slot{run['slot']}."
            f"pf{int(run['pass_friendlies'])}.{tag}",
            grid, unit_list, delays, run["slot"], run["pass_friendlies"],
            _StubResult(expected_state, run["expected"]["mp_left"],
                        run["expected"]["any_friendly_blocked"]),
            cells["obstacle"])
        case["cells"]["unit"] = cells["unit"]
        # Attach the native walks to the fill they were taken over.  The
        # capture re-fills before every walk with pass_friendlies = 0 and no
        # mutations, so the matching case is that slot's plain fill.
        if not run.get("mutations") and not run["pass_friendlies"]:
            attached = [w for w in fixture.get("walks", [])
                        if w["slot"] == run["slot"]]
            if attached:
                case["expected"]["walks"] = [{
                    "tx": w["tx"], "ty": w["ty"],
                    "ok": bool(w["expected"]["ret"]),
                    "steps": w["expected"]["steps"],
                    "blocked": w["expected"]["blocked"],
                    "path": _path_of(w["expected"]["state"], width),
                } for w in attached]
        cases.append(case)
    payload = cases_document(
        "native-runtime",
        f"aBuildMoveMap in a live Incubation.exe on {fixture['mission']}",
        cases)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                              separators=(",", ":"), allow_nan=False) + "\n",
                   encoding="utf-8")
    LOG.info("wrote %s (%d cases, %d bytes)", out, len(cases),
             out.stat().st_size)
    return 0


def _path_of(state: list[int], width: int) -> list[int]:
    """The cells a walk left marked, in index order.

    The engine's overlay records the path as a *set* -- 100 on every cell it
    stepped on -- and not as an order, so this is the set, sorted.  The
    GDScript side compares the same way; the order is checked against the
    executable model, where it is available.
    """
    del width
    return [i for i, v in enumerate(state) if v == STATE_PATH]


ALLOWANCE_CASES_SCHEMA = "incubation.allowance-cases/1"


def emit_allowance_cases(fixture_path: Path, out: Path) -> int:
    """Re-express the captured ``aGetMovePoints`` calls as a case file.

    Each case carries the **whole** roster it was measured against, after its
    mutations, so the GDScript side applies nothing: the Banner scan reads the
    same unit array the engine read.
    """
    fixture = json.loads(fixture_path.read_text())
    units = {u["slot"]: u for u in fixture["units"]}
    cases: list[dict[str, Any]] = []
    for run in fixture.get("allowances", []):
        live = {s: dict(u) for s, u in units.items()}
        scratch: dict[str, list[int]] = {"obstacle": [], "field_type": [],
                                         "unit": []}
        for mutation in run["mutations"]:
            apply_mutation(mutation, scratch, live, fixture["width"])
        cases.append({
            "name": f"{fixture['mission']}.{run['tag']}",
            "slot": run["slot"],
            "units": [{
                "slot": u["slot"], "type_id": u["type_id"],
                "player": u["player"], "x": u["x"], "y": u["y"],
                "hp": u["hp"], "fp": u["fp"], "rested": u["rested"],
                "action_state": u["action_state"],
                "mp_max": u["mp_max"],
                "equipment_ids": sorted(int(i) for i in u["equipment_ids"]),
            } for u in sorted(live.values(), key=lambda r: r["slot"])],
            "expected": run["expected"],
        })
    payload = {
        "schema": ALLOWANCE_CASES_SCHEMA,
        "oracle": "native-runtime",
        "source": f"aGetMovePoints in a live Incubation.exe on "
                  f"{fixture['mission']}",
        "ai_level": fixture.get("ai_level", 1),
        "cases": cases,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                              separators=(",", ":"), allow_nan=False) + "\n",
                   encoding="utf-8")
    LOG.info("wrote %s (%d cases, %d bytes)", out, len(cases),
             out.stat().st_size)
    return 0


class _StubResult:
    """Just enough of a result for :func:`make_case` to read the answer off."""

    def __init__(self, state: list[int], mp_left: list[int],
                 blocked: bool) -> None:
        self.state = state
        self.mp_left = mp_left
        self.any_friendly_blocked = blocked


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--game-copy", type=Path,
                    help="a copy of the game holding Work/Saves2/_6_.sav")
    ap.add_argument("--dbgcall", type=Path, help="the built dbgcall.exe")
    ap.add_argument("--root", type=Path, default=Path("gog_incubation"),
                    help="game root for Info.lcl (read-only)")
    ap.add_argument("--attempts", type=int, default=DEFAULT_ATTEMPTS,
                    help="Wine start-up retries before giving up")
    ap.add_argument("--emit-plan", choices=("state", "fill"),
                    help="print a plan instead of running anything")
    ap.add_argument("--slots", type=str, default="",
                    help="comma-separated slots for --emit-plan fill")
    ap.add_argument("--check", metavar="GAME_ROOT", type=Path,
                    help="diff the executable model against a capture")
    ap.add_argument("--fixture", type=Path,
                    default=Path("tests/fixtures/movemap/_C_141.json"))
    ap.add_argument("--emit-cases", metavar="PATH", type=Path,
                    help="re-express --fixture in the shared case shape")
    ap.add_argument("--emit-allowance-cases", metavar="PATH", type=Path,
                    help="re-express --fixture's aGetMovePoints calls")
    ap.add_argument("--selftest-process-scope", action="store_true",
                    help="timeout cleanup leaves an unrelated process alive")
    ap.add_argument("-o", "--out", type=Path,
                    default=Path("tests/fixtures/movemap/_C_141.json"))
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    try:
        if args.emit_plan == "state":
            print(state_plan(), end="")
            return 0
        if args.emit_plan == "fill":
            slots = [int(s) for s in args.slots.split(",") if s.strip()]
            if not slots:
                raise CaptureError("--emit-plan fill needs --slots")
            print(fill_plan([{"slot": s, "pass_friendlies": bool(f),
                              "mutations": []}
                             for s in slots for f in (0, 1)]), end="")
            return 0
        if args.emit_allowance_cases:
            return emit_allowance_cases(args.fixture,
                                        args.emit_allowance_cases)
        if args.selftest_process_scope:
            return selftest_process_scope()
        if args.emit_cases:
            return emit_cases(args.fixture, args.emit_cases, args.root)
        if args.check:
            return check_fixture(args.check, args.fixture)
        if args.game_copy and args.dbgcall:
            return capture(args.game_copy, args.dbgcall, args.root, args.out,
                           args.attempts)
    except (CaptureError, InfoError) as exc:
        LOG.error("%s", exc)
        return 1
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
