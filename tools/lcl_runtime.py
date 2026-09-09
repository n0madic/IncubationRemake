#!/usr/bin/env python3
"""Run the LCL interpreter model over the corpus -- ``docs/20``.

``lcl_parse.py`` proves the corpus *parses*; this proves it **runs**.  Every
mission script is executed once per call type the engine can enter it with
(``docs/20`` §5), against the world its own ``.lev`` describes, and every other
shipped script is executed once the way the loader runs it.

The check is a claim about coverage, not about plausibility:

* every command and predicate the corpus uses is **implemented or explicitly
  recorded** -- an unknown name is a failure, printed as ``N/N``;
* no run aborts except at a defect ``docs/20`` §8 already documents;
* no run hits the step cap, i.e. no ``Goto`` loop is unbounded;
* the flag mechanics of §2 hold on hand-built programs, because the corpus
  cannot exercise the cases it happens not to contain.

Usage::

    lcl_runtime.py --check gog_incubation      # the corpus
    lcl_runtime.py --check DIR --stats         # ... plus per-command counts
    lcl_runtime.py FILE --root gog_incubation  # run one mission, print the run
"""

from __future__ import annotations

import argparse
import collections
import json
import logging
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib import ctrlmap                                          # noqa: E402
from inclib import interact as interactmod                          # noqa: E402
from inclib import lcl                                              # noqa: E402
from inclib import lcl_runtime as runtime                           # noqa: E402
from inclib.check import Checker                                    # noqa: E402
from inclib.info import load_info_file                              # noqa: E402
from inclib.lev import load_lev                                     # noqa: E402
from inclib.script import script_document                           # noqa: E402

LOG = logging.getLogger("lcl_runtime")

#: ``docs/20`` §8 -- the aborts the shipped corpus really contains.  Anything
#: else aborting is a model bug or a new defect, and either way a failure.
#: Keyed by file basename; the value is the line the abort must land on.
KNOWN_ABORTS = {
    "J00.lcl": 23,
}

#: Two things that look like they belong above and do **not**.
#:
#: ``docs/20`` §8.4's seven ``9o`` typos in `_C_166.lcl` are not aborts: the
#: parameter classifier is ``atoi``, which reads ``9`` and ignores everything
#: from the first non-digit, so ``9o`` is 9 with a stray label.  The defect is
#: that the barrier is seeded with 9 rather than 90, not that the run stops.
#:
#: A label sharing its line with a following instruction would need one, since
#: ``0x00440e00`` skips to the end of the line after matching and the flat
#: stream cannot express "skipped on a jump, executed on fall-through".  The
#: corpus has **zero** such lines, checked below, so the flat form is exact.


def _mission_world(root: Path, name: str, tables: Any, turn: int = 1,
                   player: int = 0,
                   seed: float = 0.0) -> runtime.LclWorld:
    bm = load_lev(str(root / "Missions" / f"{name}.lev"))
    return runtime.LclWorld(bm, tables, turn=turn, player=player, seed=seed)


def _script_paths(root: Path) -> list[Path]:
    return [Path(p) for p in lcl.iter_inputs([str(root)]) if lcl.is_script(p)]


def _document(path: Path) -> dict[str, Any]:
    """The cache document, which is what the interpreter consumes."""
    return script_document(lcl.parse_file(str(path)), {"lcl": path.name})


def _run_all(root: Path) -> tuple[list[dict[str, Any]], collections.Counter,
                                  collections.Counter, list[str]]:
    """Execute every shipped script; return the runs and what they used."""
    tables = load_info_file(str(root / "DATA" / "Info.lcl"))
    runs: list[dict[str, Any]] = []
    used_commands: collections.Counter = collections.Counter()
    used_predicates: collections.Counter = collections.Counter()
    unknown: list[str] = []

    for path in _script_paths(root):
        document = _document(path)
        for instr in document["instructions"]:
            if instr["kind"] == "command":
                used_commands[instr["name"]] += 1
            elif instr["kind"] == "cond":
                used_predicates[instr["name"]] += 1

        is_mission = path.parent.name.lower() == "missions"
        name = path.stem
        if is_mission and (root / "Missions" / f"{name}.lev").exists():
            entries = [(call, runtime.mission_env(call, turn=1, player=0))
                       for call in runtime.MISSION_CALL_TYPES]
            world_of = lambda: _mission_world(root, name, tables)  # noqa: E731
        else:
            # docs/20 §5.4: the data-only programs have no labels and are run
            # once for their side effects.  The GUI menus select a window with
            # `_A`, but nothing here depends on which one, so they run with the
            # environment the loader leaves: all zero.
            entries = [(0, {})]
            # A fresh world per run: one shared instance would let game
            # control, the turn control byte and the generator state leak from
            # one file's run into the next one's.
            world_of = lambda: runtime.LclWorld(_EmptyMap(), tables)  # noqa: E731

        for call, env in entries:
            world = world_of()
            try:
                outcome = runtime.run(document, world, env)
            except runtime.RuntimeError_ as exc:
                unknown.append(f"{path.name} call {call}: {exc}")
                continue
            runs.append({"file": path.name, "call": call,
                         "outcome": outcome, "world": world})
    return runs, used_commands, used_predicates, unknown


class _EmptyMap:
    """A map of the given size with nothing on it, for the synthetic checks.

    ``docs/20`` §5.4's data-only programs and the GUI menus reach no cell and
    no unit, so they run against the 0x0 form; giving them a real map would
    make the check depend on which map, which is exactly the kind of accident a
    corpus check should not have.  Every array is built per instance -- a class
    attribute here would be one list shared by every world.
    """

    def __init__(self, width: int = 0, height: int = 0) -> None:
        self.width = width
        self.height = height
        self.cells: list[Any] = []
        self.units: list[Any] = []
        self.next_map = ""


class _FlatCell:
    """One open, flat cell -- the shape ``LclWorld`` reads out of a ``.lev``."""

    def __init__(self) -> None:
        self.action_point = 0
        self.field_type = 0
        self.height = 0
        self.unit: int | None = None
        self.raw = bytes([0] * 0x0E + [0, 0xFF, 0xFF, 0xFF, 0, 0xFF]
                         + [0] * 3)


class _FlatMap(_EmptyMap):
    """`_EmptyMap` with cells: what the two ground commands need."""

    def __init__(self, width: int, height: int) -> None:
        super().__init__(width, height)
        self.cells = [_FlatCell() for _ in range(width * height)]


def _ground_checks(c: Checker) -> None:
    """``SetGroundFire`` and ``ParaBombs`` -- ``docs/20``, ``docs/42`` §9.1.

    Both were modelled as draws with no cell write until 2026-09-03
    (``docs/97`` §37).  Reading their handlers settles which is a rule: the
    bomber's mines are ``+0x10 = 2`` and stop a walk, while the ground fire
    lays a **glow** in its own three bytes and reaches nobody until it ignites
    two rounds later.
    """
    def command(name: str, *values: int) -> dict[str, Any]:
        return {"kind": "command", "line": 1, "name": name,
                "args": [{"kind": "number", "value": v} for v in values]}

    def run(world: runtime.LclWorld, *instructions: dict[str, Any]) -> None:
        runtime.run({"instructions": list(instructions)
                     + [{"kind": "end", "line": 9}], "labels": {}}, world)

    # SetGroundFire (x, y, height, w, h, tries) over a 3x3 block, 40 tries.
    w = runtime.LclWorld(_FlatMap(8, 8), _TABLES, seed=1.0)
    run(w, command("SetGroundFire", 2, 2, 0, 3, 3, 40))
    glowing = [i for i, v in enumerate(w.decal_state)
               if v == ctrlmap.DECAL_GLOW]
    c.check("ground_fire.lays_glows", bool(glowing),
            f"{len(glowing)} cell(s) of the 9 in the block")
    c.expect("ground_fire.phase_is_2",
             sorted({w.decal_phase[i] for i in glowing}),
             [ctrlmap.GLOW_PHASE_FRESH])
    c.expect("ground_fire.blocks_nobody",
             sorted({w.effect_state[i] for i in glowing}),
             [ctrlmap.OBSTACLE_NONE],
             "0x0042FCB0 writes +0x11/+0x12/+0x13 and no obstacle byte")
    c.expect("ground_fire.inside_the_block",
             sorted({(i % 8, i // 8) for i in glowing})[:1] and
             all(2 <= i % 8 < 5 and 2 <= i // 8 < 5 for i in glowing), True)
    c.expect("ground_fire.one_glow_per_cell",
             len(glowing),
             len({w.decal_object[i] for i in glowing}),
             "+0x13 == 255 is the handler's own gate, so no cell is re-lit")

    # ParaBombs (x, y, w, h, a, b) -- 60 attempts, a mine on each free tile.
    w = runtime.LclWorld(_FlatMap(8, 8), _TABLES, seed=1.0)
    run(w, command("ParaBombs", 2, 2, 3, 3, 20, 0))
    mined = [i for i, v in enumerate(w.effect_state)
             if v == ctrlmap.OBSTACLE_MINE]
    c.check("para_bombs.lay_mines", bool(mined), f"{len(mined)} mine(s)")
    c.expect("para_bombs.every_mine_names_an_object",
             sorted({w.effect_object[i] == ctrlmap.NO_OBJECT for i in mined}),
             [False],
             "docs/26 §6.2: +0x10 == 2 with no object is unreachable")
    c.expect("para_bombs.inside_the_block",
             all(2 <= i % 8 < 5 and 2 <= i // 8 < 5 for i in mined), True)
    c.expect("para_bombs.at_most_nine", len(mined) <= 9, True,
             "60 attempts over a 3x3 block, and a mined cell is skipped")


def _flat_world(size: int, points: dict[tuple[int, int], int],
                walls: set[tuple[int, int]],
                units: dict[int, tuple[int, int]],
                turn: int = 1) -> runtime.LclWorld:
    """A ``size`` x ``size`` flat map with action points, walls and units.

    The synthetic world the set-piece checks below share with their
    ``test_lcl.gd`` twins, which build the same grid through
    ``_run_synthetic``.
    """
    w = runtime.LclWorld(_FlatMap(size, size), _TABLES, turn=turn, seed=1.0)
    for (x, y), value in points.items():
        w.actpt[w.index(x, y)] = value
    for x, y in walls:
        w.ctrl_type[w.index(x, y)] = 2
    for slot, (x, y) in units.items():
        w.units[slot] = runtime.RuntimeUnit(slot=slot, player=0, type_id=0,
                                            x=x, y=y, hit_points=10)
        w.unit_at[w.index(x, y)] = slot
    return w


def _run_synthetic(w: runtime.LclWorld, *instructions: dict[str, Any]):
    return runtime.run({"instructions": list(instructions)
                        + [{"kind": "end", "line": 9}], "labels": {}}, w)


def _alive(w: runtime.LclWorld, *slots: int) -> list[bool]:
    return [w.units[s].alive for s in slots]


def _foot_bridge_checks(c: Checker) -> None:
    """``FootBridge`` / ``FootBridge2`` -- ``0x00414A70``, ``0x00415110``.

    The twin of ``test_lcl.gd``'s ``foot_bridge.*`` block: the ``minUnits``
    gate, the nine cells becoming deep holes, the riders taken off the map
    **dead** and carried on the event; and for ``FootBridge2`` the exact-turn
    gate, the group byte cleared, the matched cells on the event before the
    riders (``docs/42`` §8.3).
    """
    def command(name: str, *values: int) -> dict[str, Any]:
        return {"kind": "command", "line": 1, "name": name,
                "args": [{"kind": "number", "value": v} for v in values]}

    def events(out, name: str) -> list[list[int]]:
        return [list(values) for kind, values in out.events if kind == name]

    def types(w: runtime.LclWorld, cells: list[tuple[int, int]]) -> list[int]:
        return [w.ctrl_type[w.index(x, y)] for x, y in cells]

    block = [(x, y) for y in (3, 4, 5) for x in (3, 4, 5)]
    # One unit on the block and `minUnits` 1: the count is not **more than**
    # the argument, and nothing happens.
    w = _flat_world(9, {}, set(), {0: (4, 4)}, turn=3)
    out = _run_synthetic(w, command("FootBridge", 4, 4, 30, 1))
    c.expect("foot_bridge.needs_more_than_min_units",
             (types(w, block), _alive(w, 0), events(out, "foot_bridge")),
             ([0] * 9, [True], []),
             "0x00442650 compares the count with `jle`")
    # Two units: the nine cells become deep holes, both riders die and leave
    # their cells, and the event names them after the count.
    w = _flat_world(9, {}, set(), {0: (4, 4), 1: (5, 5), 2: (7, 7)}, turn=3)
    out = _run_synthetic(w, command("FootBridge", 4, 4, 30, 1))
    c.expect("foot_bridge.the_block_becomes_a_deep_hole", types(w, block),
             [4] * 9, "mov byte [esi+0x0D], 4 on all nine")
    c.expect("foot_bridge.the_riders_die", _alive(w, 0, 1, 2),
             [False, False, True],
             "0x00414F9C is aRemoveUnitElement, and removal kills")
    c.expect("foot_bridge.the_riders_leave_the_map",
             [w.unit_at[w.index(4, 4)], w.unit_at[w.index(5, 5)]], [-1, -1])
    c.expect("foot_bridge.the_event_carries_the_riders",
             events(out, "foot_bridge"), [[4, 4, 30, 2, 0, 1]],
             "x, y, frames, standing, then the slots in block order")

    # FootBridge2 on the wrong turn does nothing at all.
    group = {(2, 2): 112, (6, 2): 112, (4, 6): 113}
    w = _flat_world(9, group, set(), {0: (2, 2)}, turn=3)
    out = _run_synthetic(w, command("FootBridge2", 112, 30, 4))
    c.expect("foot_bridge2.needs_the_exact_turn",
             (w.actpt[w.index(2, 2)], _alive(w, 0), events(out, "foot_bridge2")),
             (112, [True], []), "0x004426D0 compares GetTurn's answer with `jne`")
    # On its turn: both matched cells become deep holes with the byte
    # cleared, the other group is untouched, the rider dies, and the event
    # carries the cells before the rider.
    w = _flat_world(9, group, set(), {0: (2, 2), 1: (4, 6)}, turn=3)
    out = _run_synthetic(w, command("FootBridge2", 112, 30, 3))
    c.expect("foot_bridge2.clears_the_group",
             (types(w, [(2, 2), (6, 2), (4, 6)]),
              [w.actpt[w.index(2, 2)], w.actpt[w.index(6, 2)],
               w.actpt[w.index(4, 6)]]),
             ([4, 4, 0], [0, 0, 113]),
             "mov byte [esi+0x0B], 0 and [esi+0x0D], 4 on the matches only")
    c.expect("foot_bridge2.the_riders_die", _alive(w, 0, 1), [False, True],
             "0x00415663 is aRemoveUnitElement on every rider")
    c.expect("foot_bridge2.the_event_carries_the_cells",
             events(out, "foot_bridge2"), [[112, 30, 2, 2, 2, 6, 2, 0]],
             "actpt, frames, hit, the cells row-major, then the riders")


def _statue_checks(c: Checker) -> None:
    """``Statue`` / ``Statue2`` -- ``0x00413A40``, ``docs/97`` §41.1.

    The twin of ``test_lcl.gd``'s ``statue.*`` block, on the same 9x9 world
    and the same eight facts: the action-point toggle in both directions, the
    axis the **new** bit picks, one victim per arm, the field-type-2 stop, the
    six-cell reach and the seventh cell out of it, and ``Statue2`` running the
    sequence on every cell in its range.
    """
    def command(name: str, *values: int) -> dict[str, Any]:
        return {"kind": "command", "line": 1, "name": name,
                "args": [{"kind": "number", "value": v} for v in values]}

    def world(points: dict[tuple[int, int], int],
              walls: set[tuple[int, int]],
              units: dict[int, tuple[int, int]]) -> runtime.LclWorld:
        return _flat_world(9, points, walls, units)

    run = _run_synthetic
    alive = _alive

    # An even action point toggles **up**, so the axis is x.
    w = world({}, set(), {0: (6, 4), 1: (1, 4), 2: (4, 7)})
    run(w, command("Statue", 4, 4))
    c.expect("statue.toggles_the_action_point", w.actpt[w.index(4, 4)], 1,
             "0x00413C31 flips bit 0 of the statue's own +0x0B")
    c.expect("statue.the_beam_kills_one_each_way", alive(w, 0, 1, 2),
             [False, False, True],
             "the new bit picks x, so the unit off the axis is spared")
    c.expect("statue.the_victims_leave_the_map",
             [w.unit_at[w.index(6, 4)], w.unit_at[w.index(1, 4)]], [-1, -1])

    # One kill site per direction, not one per cell.
    w = world({}, set(), {0: (5, 4), 1: (7, 4)})
    run(w, command("Statue", 4, 4))
    c.expect("statue.only_the_first_unit_on_an_arm_dies", alive(w, 0, 1),
             [False, True], "0x00413D67 re-enters only on the no-unit branch")

    # Field type 2 stops the walk before the unit behind it.
    w = world({}, {(6, 4)}, {0: (7, 4)})
    run(w, command("Statue", 4, 4))
    c.expect("statue.a_wall_stops_the_beam", alive(w, 0), [True],
             "cmp byte [esi+0x0D], 2 at 0x00413CCA")

    # Six cells is in reach and seven is not.
    w = world({}, set(), {0: (1, 4)})
    run(w, command("Statue", 7, 4))
    c.expect("statue.the_sixth_cell_is_in_reach", alive(w, 0), [False],
             "cmp dword [esp+0x3c], 6 at 0x00413C97")
    w = world({}, set(), {0: (1, 4)})
    run(w, command("Statue", 8, 4))
    c.expect("statue.the_seventh_is_not", alive(w, 0), [True])

    # An odd action point toggles **down**, which picks the other axis.
    w = world({(4, 4): 5}, set(), {0: (6, 4), 1: (4, 6)})
    run(w, command("Statue", 4, 4))
    c.expect("statue.an_odd_point_toggles_down", w.actpt[w.index(4, 4)], 4,
             "0x00413C38 is `dec al`, so 5 becomes 4 and the axis is y")
    c.expect("statue.the_axis_follows_the_new_bit", alive(w, 0, 1),
             [True, False])

    # `Statue2` runs the sequence on every cell in the inclusive range.
    w = world({(1, 1): 40, (6, 6): 41}, set(), {0: (3, 1), 1: (6, 4)})
    out = run(w, command("Statue2", 40, 41))
    c.expect("statue2.runs_every_matched_cell", alive(w, 0, 1),
             [False, False],
             "40 toggles to 41 and walks x; 41 toggles to 40 and walks y")
    c.expect("statue2.runs_once_per_cell",
             [name for name, _ in out.events].count("statue"), 2,
             "0x00413500 sweeps row-major and calls the sequence per match")
    c.expect("statue2.the_event_carries_fifteen_numbers",
             sorted({len(values) for name, values in out.events
                     if name == "statue"}),
             [15], "cell, axis, both endpoints and both victims")


def _crush_wall_checks(c: Checker) -> None:
    """``CrushWall`` -- ``0x00415c70`` through ``0x0042f410``, ``docs/42`` §8.2.

    The lasting writes are the height and the field type; the state byte the
    mark leaves at 2 is put back to 1 by the debris sweep, so it is not
    modelled.  The footprint is the wall piece's own geometry and this model
    reaches only the command's cell (``docs/97`` §41.7).
    """
    def command(name: str, *values: int) -> dict[str, Any]:
        return {"kind": "command", "line": 1, "name": name,
                "args": [{"kind": "number", "value": v} for v in values]}

    w = runtime.LclWorld(_FlatMap(8, 8), _TABLES, seed=1.0)
    cell = w.index(3, 4)
    w.ctrl_type[cell] = 2
    w.cell_height[cell] = 3280
    out = runtime.run({"instructions": [command("CrushWall", 3, 4),
                                        {"kind": "end", "line": 9}],
                       "labels": {}}, w)
    c.expect("crush_wall.becomes_free_place_at_ground",
             [w.ctrl_type[cell], w.cell_height[cell]], [1, 0],
             "0x0042F410 writes the field type argument and a zero height")
    c.expect("crush_wall.the_event_carries_the_cells",
             [values for name, values in out.events if name == "crush_wall"],
             [[3, 4, 3, 4]],
             "the command's cell, then every cell it changed")
    # Off the map: no write, and the event still records the call.
    w = runtime.LclWorld(_FlatMap(8, 8), _TABLES, seed=1.0)
    out = runtime.run({"instructions": [command("CrushWall", 99, 99),
                                        {"kind": "end", "line": 9}],
                       "labels": {}}, w)
    c.expect("crush_wall.off_the_map_changes_nothing",
             [values for name, values in out.events if name == "crush_wall"],
             [[99, 99]])


def _open_door_checks(c: Checker) -> None:
    """``OpenDoor`` -- ``0x004420c0`` through ``aDoorOpenSequence`` ``0x00410A20``.

    A **toggle** on the low bit of the action point (``docs/26`` §3.4), and a
    unit on the tile makes it do nothing at all.  It wrote no cell field until
    2026-09-09, which is what made ``_C_116``'s three lever-worked doors
    impossible to open in the remake -- the panel's leaves are painted from the
    cell's parity, so the animation was undone the frame after it played.
    """
    def command(name: str, *values: int) -> dict[str, Any]:
        return {"kind": "command", "line": 1, "name": name,
                "args": [{"kind": "number", "value": v} for v in values]}

    def run_once(actpt: int, ctrl_type: int, height: int,
                 occupied: bool = False) -> tuple[runtime.LclWorld, Any]:
        w = runtime.LclWorld(_FlatMap(8, 8), _TABLES, seed=1.0)
        at = w.index(3, 4)
        w.actpt[at] = actpt
        w.ctrl_type[at] = ctrl_type
        w.cell_height[at] = height
        if occupied:
            w.units[0] = runtime.RuntimeUnit(slot=0, player=0, type_id=0,
                                             x=3, y=4, hit_points=10)
            w.unit_at[at] = 0
        return w, runtime.run({"instructions": [command("OpenDoor", 3, 4),
                                               {"kind": "end", "line": 9}],
                               "labels": {}}, w)

    w, out = run_once(31, interactmod.FIELD_TYPE_WALL, 3193)
    at = w.index(3, 4)
    c.expect("open_door.opens_a_closed_door",
             [w.actpt[at], w.ctrl_type[at], w.cell_height[at]], [30, 1, 0],
             "31 is closed: the toggle drops the cell to a Free Place at ground")
    c.expect("open_door.records_the_animation",
             [values for name, values in out.events if name == "open_door"],
             [[3, 4]], "the picture still gets its event")
    w, _out = run_once(30, interactmod.FIELD_TYPE_FREE, 0)
    c.expect("open_door.closes_an_open_one",
             [w.actpt[at], w.ctrl_type[at], w.cell_height[at]],
             [31, 2, interactmod.DOOR_HEIGHT_STEP],
             "30 is open: it rises one tile and becomes a Wall")
    w, out = run_once(31, interactmod.FIELD_TYPE_WALL, 3193, occupied=True)
    c.expect("open_door.a_unit_on_the_tile_refuses",
             [w.actpt[at], w.ctrl_type[at], w.cell_height[at],
              [values for name, values in out.events if name == "open_door"]],
             [31, 2, 3193, []], "0x004420C0 returns before the sequence")


def _synthetic_checks(c: Checker) -> None:
    """The mechanics of ``docs/20`` §2 that the corpus does not exercise.

    Every one of these is a rule the document states and no shipped script
    depends on, which is precisely why they need a test: a wrong one would pass
    the corpus and break the first mission that used the construct.
    """
    def program(*instructions: dict[str, Any]) -> dict[str, Any]:
        flat = list(instructions)
        labels: dict[str, int] = {}
        for n, i in enumerate(flat):
            if i["kind"] == "label":
                # First occurrence wins, the way `label_index` builds it.
                labels.setdefault(i["name"], n)
        return {"instructions": flat, "labels": labels}

    def cond(op: str, name: str, slot: int, value: int) -> dict[str, Any]:
        return {"kind": "cond", "line": 1, "op": op, "name": name,
                "args": [{"kind": "var", "slot_index": slot},
                         {"kind": "number", "value": value}]}

    def setvar(slot: int, value: int) -> dict[str, Any]:
        return {"kind": "command", "line": 1, "name": "SetVarNum",
                "args": [{"kind": "var", "slot_index": slot},
                         {"kind": "number", "value": value}]}

    def gc(slot: int, value: int) -> dict[str, Any]:
        return {"kind": "command", "line": 1, "name": "SetGameControl",
                "args": [{"kind": "number", "value": slot},
                         {"kind": "number", "value": value}]}

    end = {"kind": "end", "line": 9}
    close = {"kind": "close", "line": 1}
    els = {"kind": "else", "line": 1}

    def world() -> runtime.LclWorld:
        return runtime.LclWorld(_EmptyMap(), _TABLES)

    # `#` is an else: the false branch runs and the true branch does not.
    w = world()
    runtime.run(program(cond(">", "VarCmpNum", 0, 5), gc(0, 1), els,
                        gc(1, 1), close, end), w)
    c.expect("else.true_branch_skipped", w.game_control[0], 0)
    c.expect("else.false_branch_runs", w.game_control[1], 1)

    # Folding is left to right with no precedence: `>A &B |C` is `((A&B)|C)`.
    # `_A` is -1, so `VarCmpNum(_A,0)` is false and `VarLowerNum(_A,0)` true.
    w = world()
    runtime.run(program(cond(">", "VarCmpNum", 0, 0),
                        cond("&", "VarCmpNum", 0, 0),
                        cond("|", "VarLowerNum", 0, 0), gc(0, 7), close, end), w)
    c.expect("fold.or_after_and", w.game_control[0], 7)

    # ... and `>A |B &C` is `((A|B)&C)`, not `A|(B&C)`.
    w = world()
    runtime.run(program(cond(">", "VarLowerNum", 0, 0),
                        cond("|", "VarCmpNum", 0, 0),
                        cond("&", "VarCmpNum", 0, 0), gc(0, 7), close, end), w)
    c.expect("fold.and_after_or", w.game_control[0], 0)

    # A predicate runs even when the flag is already false -- no short-circuit.
    # Predicates have no side effect, so the only way to observe the second one
    # running is to make it fail: an unknown name is what the engine's
    # dispatcher rejects, and rejecting it inside an already-false chain is
    # exactly the property.
    w = world()
    reached = False
    try:
        runtime.run(program(cond(">", "VarCmpNum", 0, 0),
                            cond("&", "NotAPredicate", 1, 0), close, end), w)
    except runtime.RuntimeError_:
        reached = True
    c.check("fold.no_short_circuit", reached,
            "the '&' term is evaluated although the flag is already false")

    # `<` is unconditional: it sets a false flag true.
    w = world()
    runtime.run(program(cond(">", "VarCmpNum", 0, 0), close, gc(0, 3), end), w)
    c.expect("close.unconditional", w.game_control[0], 3)

    # `[END]` is not gated by the flag.
    w = world()
    out = runtime.run(program(cond(">", "VarCmpNum", 0, 0), end,
                              gc(0, 4), close), w)
    c.expect("end.ungated", out.kind, runtime.OUTCOME_END)
    c.expect("end.stops_there", w.game_control[0], 0)

    # Locals start at -1, not 0, and do not persist between invocations.
    w = world()
    runtime.run(program(cond(">", "VarCmpNum", 0, -1), gc(0, 5), close,
                        setvar(0, 42), end), w)
    c.expect("locals.initial_minus_one", w.game_control[0], 5)
    runtime.run(program(cond(">", "VarCmpNum", 0, 42), gc(1, 6), close, end), w)
    c.expect("locals.not_persistent", w.game_control[1], 0)

    # `Goto` is gated by the flag like any other command.
    label = {"kind": "label", "line": 1, "name": "L"}
    goto = {"kind": "command", "line": 1, "name": "Goto",
            "args": [{"kind": "name", "value": "L"}]}
    w = world()
    out = runtime.run(program(cond(">", "VarCmpNum", 0, 0), goto, close,
                              end, label, gc(0, 8), end), w)
    c.expect("goto.gated_by_flag", w.game_control[0], 0)
    c.expect("goto.gated_reaches_end", out.kind, runtime.OUTCOME_END)

    # ... and a missing label aborts the invocation.
    w = world()
    out = runtime.run(program(goto, end), w)
    c.expect("goto.missing_label_aborts", out.kind, runtime.OUTCOME_ABORT)

    # ... and it takes the *first* label of that name.
    w = world()
    runtime.run(program(goto, label, gc(0, 1), end, label, gc(0, 2), end), w)
    c.expect("goto.first_match_wins", w.game_control[0], 1)

    # An unbounded loop is stopped by the cap rather than hanging the check.
    w = world()
    out = runtime.run(program(label, goto, end), w, None, 500)
    c.expect("goto.step_cap", out.kind, runtime.OUTCOME_ABORT)
    c.check("goto.step_cap_reason", "steps" in out.reason, out.reason)

    # A program with no `[END]` runs off the end; that is not an abort.
    w = world()
    out = runtime.run(program(gc(0, 1)), w)
    c.expect("fell_off.not_an_abort", out.kind, runtime.OUTCOME_FELL_OFF)

    # An `abort` instruction stops the run wherever it sits, ungated.
    w = world()
    out = runtime.run(program(cond(">", "VarCmpNum", 0, 0),
                              {"kind": "abort", "line": 3, "name": "boom"},
                              gc(0, 1), end), w)
    c.expect("abort.ungated", out.kind, runtime.OUTCOME_ABORT)
    c.expect("abort.line", out.line, 3)

    # `SetActPt` writes a byte, so the two-argument form stores 255 (docs/20
    # §7.4) -- the one shipped short call, reproduced on a synthetic map.
    w = runtime.LclWorld(_EmptyMap(2, 2), _TABLES)
    w.actpt = [0, 0, 0, 0]
    w.ctrl_type = [0, 0, 0, 0]
    w.cell_height = [0, 0, 0, 0]
    w.unit_at = [-1, -1, -1, -1]
    runtime.run(program({"kind": "command", "line": 1, "name": "SetActPt",
                         "args": [{"kind": "number", "value": 1},
                                  {"kind": "number", "value": 1}]}, end), w)
    c.expect("setactpt.short_form_writes_255", w.actpt[3], 255)


_TABLES: Any


def _corpus_shape_checks(c: Checker, root: Path) -> None:
    """Assumptions the model makes about the shipped data, asserted.

    Each of these is a shortcut the model is allowed to take only for as long
    as the corpus stays the shape it is; asserting them here is what keeps
    "allowed" from quietly becoming "assumed".
    """
    same_line = 0
    platform_min: int | None = None
    for path in _script_paths(root):
        previous = None
        for instr in _document(path)["instructions"]:
            if (previous is not None and previous["kind"] == "label"
                    and instr["line"] == previous["line"]):
                same_line += 1
            if instr["kind"] == "command" and instr["name"] == "Platform":
                nums = [a["value"] for a in instr.get("args", [])
                        if a["kind"] == "number"]
                if len(nums) >= 4:
                    platform_min = (nums[3] if platform_min is None
                                    else min(platform_min, nums[3]))
            previous = instr

    # docs/20 §2.3: `Goto` skips to the end of the line after matching, so an
    # instruction sharing a line with the label it follows would run on
    # fall-through and be skipped on a jump.  The flat stream cannot express
    # that, and does not have to.
    c.expect("corpus.no_instruction_shares_a_label_line", same_line, 0)

    # `Platform` copies its 3x3 block in place; that is only safe while source
    # and destination cannot overlap.
    c.check("corpus.platform_distance_at_least_3",
            platform_min is not None and platform_min >= 3,
            f"smallest shipped distance {platform_min}")

    # `GetHeight` divides, and the sign of the dividend decides whether the
    # division has to truncate toward zero rather than floor.
    negative = 0
    for lev in sorted((root / "Missions").glob("*.lev")):
        negative += sum(1 for cell in load_lev(str(lev)).cells
                        if cell.height < 0)
    c.check("corpus.negative_cell_heights_exist", negative > 0,
            f"{negative} cells; GetHeight must truncate toward zero, not floor")
    c.expect("getheight.truncates_toward_zero",
             [runtime.div_trunc(-161, 160), runtime.div_trunc(-160, 160),
              runtime.div_trunc(-1, 160), runtime.div_trunc(321, 160)],
             [-1, -1, 0, 2])


def _require_corpus(root: Path) -> str | None:
    """Refuse a root that is not a game installation, cleanly.

    An empty corpus must fail -- ``CLAUDE.md`` requires it of every check in
    the always-run block -- but it should fail by saying so, not by unwinding
    a stack from three modules down.
    """
    if not (root / "DATA" / "Info.lcl").is_file():
        return f"{root}: no DATA/Info.lcl -- this is not a game installation"
    if not any(root.rglob("*.lev")):
        return f"{root}: no .lev found; a check that examined nothing is not a check that passed"
    return None


def run_check(root: Path, show_stats: bool = False) -> int:
    global _TABLES
    c = Checker()
    problem = _require_corpus(root)
    if problem is not None:
        LOG.error("%s", problem)
        return 1
    _TABLES = load_info_file(str(root / "DATA" / "Info.lcl"))

    runs, used_commands, used_predicates, unknown = _run_all(root)

    c.check("corpus.ran", bool(runs), f"{len(runs)} invocation(s)")
    if not runs:
        return c.report()

    c.expect("dispatch.no_unknown_name", unknown, [])

    known = sorted(set(used_commands) - set(runtime.COMMANDS))
    c.expect("commands.all_implemented", known, [],
             f"{len(set(used_commands)) - len(known)}/{len(set(used_commands))}"
             f" commands the corpus uses")
    missing_p = sorted(set(used_predicates) - set(runtime.PREDICATES))
    c.expect("predicates.all_implemented", missing_p, [],
             f"{len(set(used_predicates)) - len(missing_p)}/"
             f"{len(set(used_predicates))} predicates the corpus uses")

    aborts = [(r["file"], r["call"], r["outcome"])
              for r in runs if r["outcome"].kind == runtime.OUTCOME_ABORT]
    unexpected = [f"{f} call {call} line {o.line}: {o.reason}"
                  for f, call, o in aborts
                  if KNOWN_ABORTS.get(f) != o.line]
    c.expect("runs.no_undocumented_abort", unexpected, [],
             f"{len(aborts)} abort(s), all at a docs/20 §8 defect")
    for name, line in sorted(KNOWN_ABORTS.items()):
        hit = [o for f, _call, o in aborts if f == name and o.line == line]
        c.check(f"runs.known_abort.{name}", bool(hit),
                f"{name}:{line} still aborts, as docs/20 §8 records")

    capped = [f"{r['file']} call {r['call']}" for r in runs
              if r["outcome"].steps >= runtime.MAX_STEPS]
    c.expect("runs.no_step_cap_hit", capped, [])

    missions = {r["file"] for r in runs if r["call"] != 0}
    c.check("missions.every_entry_point", len(missions) > 0,
            f"{len(missions)} mission script(s) x "
            f"{len(runtime.MISSION_CALL_TYPES)} call types")
    per_file = collections.Counter(r["file"] for r in runs if r["call"] != 0)
    c.expect("missions.six_call_types_each",
             sorted(set(per_file.values())),
             [len(runtime.MISSION_CALL_TYPES)])

    # The dispatcher must actually route: entering with a call type has to
    # reach a different part of the program than entering with another.  A
    # model whose `Goto` silently did nothing would pass everything above.
    routed = collections.defaultdict(set)
    for r in runs:
        if r["call"]:
            routed[r["file"]].add(r["outcome"].line)
    branching = sum(1 for lines in routed.values() if len(lines) > 1)
    c.check("missions.dispatcher_routes", branching > 0,
            f"{branching}/{len(routed)} scripts end at more than one line "
            f"across the six call types")

    _corpus_shape_checks(c, root)
    _synthetic_checks(c)
    _ground_checks(c)
    _statue_checks(c)
    _foot_bridge_checks(c)
    _crush_wall_checks(c)
    _open_door_checks(c)

    if show_stats:
        print("\ncommand usage (corpus / implemented):")
        for name, count in used_commands.most_common():
            mark = " " if name in runtime.COMMANDS else "!"
            print(f"{count:6d} {mark} {name}")
        print("\npredicates:")
        for name, count in used_predicates.most_common():
            mark = " " if name in runtime.PREDICATES else "!"
            print(f"{count:6d} {mark} {name}")
    return c.report(quiet_ok=False)


# ---------------------------------------------------------------------------
# Re-expressing a run for the GDScript side
# ---------------------------------------------------------------------------

CASES_SCHEMA = "incubation.lcl-cases/1"

#: The missions the converter ships, and therefore the ones the GDScript replay
#: can reach.  Corpus-wide ``N/N`` stays here, in Python: the cache holds four
#: maps and running 153 scripts on the GDScript side would need 153 maps in it.
DEFAULT_MISSIONS = ("_C_140", "_C_115", "_C_141", "_C_100")

#: The `(turn, player)` settings each call type is replayed with.
#:
#: **Not just turn 1.**  `_C_140`'s `NEXT TURN` opens two tubes on turn 4 and
#: its `NEXT PLAYER` inserts reinforcements from turn 5; a case file emitted at
#: turn 1 alone reaches neither, so every run comes back with an empty cell
#: delta and the replay compares nothing to nothing.
CASE_TURNS = ((1, 0), (4, 0), (4, 255), (5, 0), (8, 0))

#: The seed every case starts from.  **Not 0**: zero is a fixed point in
#: `aRandom` (``inclib.rng``), so `SetVarRandom` would return its base on every
#: draw and a script that branches on one would take the same arm every time.
CASE_SEED = 1.0

#: The unit columns a case carries.  ``docs/20``'s commands read or write every
#: one of them; ``hp`` doubles as the "is this slot live" test the queries use.
CASE_UNIT_FIELDS = ("slot", "player", "type_id", "x", "y", "hit_points",
                    "group", "ammo", "ep", "tp", "pool_flag", "speech", "name")


def _case_units(world: runtime.LclWorld) -> list[dict[str, Any]]:
    out = []
    for slot in sorted(world.units):
        unit = world.units[slot]
        out.append({name: getattr(unit, name) for name in CASE_UNIT_FIELDS})
    return out


def _case_cells(world: runtime.LclWorld) -> dict[str, list[int]]:
    return {"height": list(world.cell_height),
            "field_type": list(world.ctrl_type),
            "action_point": list(world.actpt),
            "unit": list(world.unit_at)}


def _delta(before: dict[str, list[int]],
           after: dict[str, list[int]]) -> list[list[int]]:
    """``[array, index, value]`` for every cell the run changed.

    A delta and not a second copy of the map: `_C_115` is 33x30, and six call
    types times four missions times four arrays of 990 is a megabyte of JSON
    saying almost nothing.
    """
    names = sorted(before)
    out: list[list[int]] = []
    for i, name in enumerate(names):
        old, new = before[name], after[name]
        for index in range(len(old)):
            if old[index] != new[index]:
                out.append([i, index, new[index]])
    return out


def emit_cases(root: Path, out: Path, missions: list[str]) -> int:
    """One document per mission, with every entry point replayed on it.

    Each case carries **the world it ran on**, not a reference to one: the
    `.lev` a mission ships and the `map.json` the converter writes are built
    from the same file but not from the same *set* of records -- `active_units`
    is "has a name" and this model's roster is "has hit points", and `_C_140`
    differs by two slots.  Comparing two worlds that disagree about the roster
    would report an interpreter bug that is really a loading difference.
    """
    tables = load_info_file(str(root / "DATA" / "Info.lcl"))
    documents: list[dict[str, Any]] = []
    for name in missions:
        lev = root / "Missions" / f"{name}.lev"
        script = root / "Missions" / f"{name}.lcl"
        if not (lev.is_file() and script.is_file()):
            raise SystemExit(f"{name}: no {lev.name} or no {script.name}")
        document = _document(script)
        world = _mission_world(root, name, tables)
        base_cells = _case_cells(world)
        entry = {
            "mission": name,
            "script": document,
            "width": world.width,
            "height": world.height,
            "cells": base_cells,
            "units": _case_units(world),
            "types": _case_types(world, tables),
            # The header's own successor. `EnterNameOfNextMap` overwrites it,
            # and a mission that never calls the command still names one, so a
            # replay that started from an empty string would disagree with
            # every case that does not write it.
            "next_map": world.next_map,
            "cases": [],
        }
        for call in runtime.MISSION_CALL_TYPES:
            for turn, player in CASE_TURNS:
                fresh = _mission_world(root, name, tables, turn=turn,
                                       player=player, seed=CASE_SEED)
                env = runtime.mission_env(call, turn=turn, player=player)
                outcome = runtime.run(document, fresh, env)
                entry["cases"].append({
                    "call": call,
                    "turn": turn,
                    "player": player,
                    "env": {str(k): v for k, v in env.items()},
                    "outcome": outcome.to_dict(),
                    "game_control": list(fresh.game_control),
                    "next_map": fresh.next_map,
                    "turn_control": fresh.turn_control,
                    "rng": {"seed": fresh.rng.seed,
                            "calls": fresh.rng.calls},
                    "crand": {"seed": fresh.crand.seed,
                              "calls": fresh.crand.calls},
                    "cell_delta": _delta(base_cells, _case_cells(fresh)),
                    "units_after": _case_units(fresh),
                })
        documents.append(entry)
    payload = {"schema": CASES_SCHEMA,
               "ai_level": runtime.DEFAULT_AI_LEVEL,
               "cell_arrays": sorted(_case_cells(
                   _mission_world(root, missions[0], tables))),
               "missions": documents}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n",
                   encoding="utf-8")
    cases = sum(len(d["cases"]) for d in documents)
    LOG.info("wrote %s (%d mission(s), %d case(s))", out, len(documents),
             cases)
    return 0


def _case_types(world: runtime.LclWorld,
                tables: Any) -> list[dict[str, Any]]:
    """The unit rows the cases reference, carried **with** them.

    ``hp_max`` is what a spawn writes and ``species`` is what ``UnitOnField``
    filters on, so a case whose units came from the capture and whose columns
    came from a separate file would not be a byte-identical input.  Every type
    the script can insert is in here as well as every type already placed,
    because a spawn of an unknown type is a different unit.
    """
    ids = {u.type_id for u in world.units.values()}
    ids |= set(tables.units)
    rows = []
    for type_id in sorted(ids):
        row = tables.units.get(type_id)
        if row is None:
            continue
        rows.append({"id": type_id, "mp_max": row.mp_max,
                     "fp_max": row.fp_max, "hp_max": row.hp_max,
                     "special": row.special, "size": row.size,
                     "species": row.species, "height": row.height,
                     "exp": row.exp,
                     "model": row.model, "description": row.description})
    return rows


def run_one(path: Path, root: Path, call: int, as_json: bool) -> int:
    tables = load_info_file(str(root / "DATA" / "Info.lcl"))
    document = _document(path)
    lev = root / "Missions" / f"{path.stem}.lev"
    if not lev.is_file():
        raise SystemExit(f"{lev} not found; --root must be the game root")
    world = runtime.LclWorld(load_lev(str(lev)), tables)
    outcome = runtime.run(document, world, runtime.mission_env(call))
    if as_json:
        json.dump(outcome.to_dict(), sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        print(f"{path.name} call {call}: {outcome.kind} at line "
              f"{outcome.line} after {outcome.steps} step(s), "
              f"{outcome.dispatched} dispatched")
        if outcome.reason:
            print(f"  reason: {outcome.reason}")
        for name, values in outcome.events:
            print(f"  event {name} {values}")
        print(f"  game control: {world.game_control}")
        print(f"  next map: {world.next_map!r}")
    return 0 if outcome.ok else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("script", nargs="?", help="one .lcl to run")
    ap.add_argument("--check", metavar="ROOT",
                    help="corpus mode: run every shipped script")
    ap.add_argument("--root", default="gog_incubation",
                    help="game root, for the .lev and the balance tables")
    ap.add_argument("--call", type=int, default=runtime.CALL_NEXT_TURN,
                    help="call type to enter with (docs/20 section 5)")
    ap.add_argument("--emit-cases", metavar="OUT",
                    help="write the GDScript replay case file")
    ap.add_argument("--missions", default=",".join(DEFAULT_MISSIONS),
                    help="which missions --emit-cases replays")
    ap.add_argument("--stats", action="store_true",
                    help="with --check, print per-command usage")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format="%(levelname)s: %(message)s")

    if args.emit_cases:
        return emit_cases(Path(args.root), Path(args.emit_cases),
                          [m for m in args.missions.split(",") if m])
    if args.check:
        return run_check(Path(args.check), args.stats)
    if not args.script:
        ap.error("give a script to run, or --check ROOT")
    return run_one(Path(args.script), Path(args.root), args.call, args.json)


if __name__ == "__main__":
    raise SystemExit(main())
