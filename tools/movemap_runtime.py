#!/usr/bin/env python3
"""Run the executable model of ``aBuildMoveMap`` over the corpus.  See docs/23 §7.

``inclib.movemap`` is the reference the remake's GDScript fill is diffed
against, and which is itself pinned to a native capture on ``_C_141``
(``tools/movemap_gold.py``).  This CLI is the thin front for it.

Usage::

    python3 tools/movemap_runtime.py --check gog_incubation
    python3 tools/movemap_runtime.py gog_incubation/Missions/_C_115.lev --slot 0
    python3 tools/movemap_runtime.py gog_incubation/Missions/_C_115.lev --slot 0 --json

``--check`` runs the fill for **every placed unit of every shipped ``.lev``**,
with ``pass_friendlies`` both ways, and tests eight invariants that need no
oracle.  It states its own oracle boundary: the *inputs* are the authored
``.lev`` fields, so the corpus check is verified-static evidence about the
algorithm's self-consistency, not about the engine's output.  The engine's
output is what the native capture supplies, on ``_C_141`` only.

Two branches have **no corpus coverage and cannot acquire any**: the transient
obstacle byte ``cell[+0x10]`` is 255 in all 184162 shipped cells, and no
shipped map carries a Ladder or an Enormous Obs field.  Those live in the
synthetic cases only.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib.allowance import (  # noqa: E402
    AllowanceUnit,
    movement_allowance,
)
from inclib.check import Checker  # noqa: E402
from inclib.info import InfoError, load_info  # noqa: E402
from inclib.lev import BattleMap, LevError, load_lev  # noqa: E402
from inclib.movemap import (  # noqa: E402
    cases_document,
    make_case,
    DELAY_IMPASSABLE,
    OBSTACLE_FIRE,
    OBSTACLE_MINE,
    OBSTACLE_NONE,
    OBSTACLE_SHIELD,
    PLAYER_ALIEN,
    JET_PACK_EQUIP_ID,
    MoveMapError,
    MoveMapHooks,
    MoveMapResult,
    Grid,
    Mover,
    QUEUE_HARD_LIMIT,
    STATE_PATH,
    WALK_DIR_DELTA,
    CORNER_COMPONENTS,
    FIRST_DIAGONAL,
    climb_quotient,
    is_enterable,
    walk,
    execute,
    FACING_OF_STEP,
    VICTORY_BAND,
    STATE_REACHABLE,
    build,
    check_invariants,
    hooks_from_arrays,
)

LOG = logging.getLogger("movemap_runtime")

#: The oracle boundary this tool's own evidence reaches (docs/92 §5).
ORACLE_BOUNDARY = "verified-static (inputs are authored .lev fields)"

#: docs/10 §6 -- every shipped mission lives here, two of them in a `backup`
#: subdirectory, which is why the walk is recursive.
MISSIONS_REL = "Missions"
EXPECTED_MISSIONS = 155

#: A corpus finding, pinned so a change in behaviour is caught rather than
#: rediscovered: ``pass_friendlies`` is **not** monotone in reachability.  The
#: fill is first-write-wins-except-zero, not a shortest-path search, so a
#: shorter route through a friendly can reach an intermediate cell with zero
#: movement points left -- where the longer route around would have arrived
#: with one -- and that cell then cannot expand.  In ``_O_055`` two units show
#: it: cell (14,2) holds mp_left 1 without the flag and 0 with it, which costs
#: the loose run (14,1) and (15,2).
EXPECTED_PASS_FRIENDLIES_VIOLATIONS = {
    ("_O_055.lev", 32): 2,
    ("_O_055.lev", 33): 1,
}

#: ``unit[+0x15]`` is a *saved runtime* field, not an authored constant: the
#: turn refresh overwrites it with what ``0x00475160`` returns (docs/25 §5).
#: Over the corpus the two agree on 1822 of 1863 placed units; the 41 that
#: disagree are two designer values the engine would replace on the first
#: refresh, and they are pinned so that a change in the formula shows up as a
#: change in this set rather than hiding inside it.  Keyed by
#: ``(type_id, stored mp, computed allowance)``.
EXPECTED_ALLOWANCE_OVERRIDES = {
    (56, 6, 5): 40,   # Pyr'Coo, mpMax 5, authored 6
    (50, 1, 6): 1,    # Ray'Ther in _C_105, authored 1
}

#: Corpus totals the check **pins**, rather than merely printing.  A number
#: that is only logged is not a check: replacing the warp pass with a bare
#: `return` left the run reporting 15/15 green while marking none of these.
EXPECTED_WARP_CELLS = 13168
#: Diagonal steps across every reconstructed path.  Pinned because it is what
#: docs/23 §8's tie-break produces: accepting `v > best` instead of `v >= best`
#: moves it, and a mere "greater than zero" would not notice.
EXPECTED_WALK_DIAGONALS = 2772

#: How many walk targets each fill contributes to the corpus check.  Walking
#: to every reachable cell of every fill would multiply the run time by the
#: size of the reachable set for no extra coverage of the routine's branches.
WALK_TARGETS_PER_FILL = 3


def grid_of(bm: BattleMap) -> Grid:
    return Grid(
        width=bm.width,
        height=bm.height,
        heights=[c.height for c in bm.cells],
        field_types=[c.field_type for c in bm.cells],
        action_points=[c.action_point for c in bm.cells],
    )


def hooks_of(bm: BattleMap) -> MoveMapHooks:
    """Occupancy taken from the **cell links**, which is what the engine reads."""
    units = [-1 if c.unit is None else c.unit for c in bm.cells]
    return hooks_from_arrays(
        bm.width, units,
        visibility={u.slot: u.visibility for u in bm.active_units},
        players={u.slot: u.player for u in bm.active_units},
    )


def mover_of(bm: BattleMap, slot: int, unit_types: dict) -> Mover:
    unit = next(u for u in bm.active_units if u.slot == slot)
    row = unit_types.get(unit.type_id)
    return Mover(
        slot=unit.slot, x=unit.x, y=unit.y, player=unit.player,
        mp=unit.action_points,
        special=0 if row is None else row.special,
        size=0 if row is None else row.size,
        has_jet_pack=JET_PACK_EQUIP_ID in unit.equipment_ids,
        # The allowance is **computed** (docs/10 §5.5), not taken as mp_max:
        # the fill asks 0x00475160 for it at the ladder step, and that routine
        # adds the Servo System, the Banner and the rest.
        mp_allowance=allowance_of(bm, unit, unit_types),
    )


def allowance_units(bm: BattleMap) -> list[AllowanceUnit]:
    """Every placed unit, in the shape the allowance formula reads."""
    return [_allowance_unit(u) for u in bm.active_units if u.placed]


def _allowance_unit(unit: Any) -> AllowanceUnit:
    return AllowanceUnit(
        slot=unit.slot, type_id=unit.type_id, player=unit.player,
        x=unit.x, y=unit.y, hp=unit.hit_points, fp=unit.fp,
        rested=unit.rested, action_state=unit.action_state,
        equipment_ids=frozenset(unit.equipment_ids))


def allowance_of(bm: BattleMap, unit: Any, unit_types: dict) -> int:
    """``0x00475160`` for one placed unit of one mission."""
    row = unit_types.get(unit.type_id)
    if row is None:
        return 0
    return movement_allowance(_allowance_unit(unit), row.mp_max,
                              allowance_units(bm))


def _iter_missions(root: Path):
    directory = root / MISSIONS_REL
    if not directory.is_dir():
        return
    # Two of the 155 shipped missions live in Missions/backup, which is why
    # the walk is recursive: 153 would silently under-cover the corpus.
    for path in sorted(directory.rglob("*.lev")):
        yield path


def run_checks(root: Path) -> int:
    c = Checker()
    started = time.perf_counter()
    try:
        tables = load_info(str(root))
    except InfoError as exc:
        c.check("info.load", False, str(exc))
        return c.report()
    delays = tables.delay_table()

    paths = list(_iter_missions(root))
    if not paths:
        c.check("corpus.missions", False,
                f"no {MISSIONS_REL}/*.lev under {root}")
        return c.report()

    files = 0
    fills = 0
    marked_total = 0
    warp_total = 0
    max_queue = 0
    max_waves = 0
    failures: list[str] = []
    subset_violations: dict[tuple[str, int], int] = {}
    nondeterministic: list[str] = []
    zero_rewrites = 0
    ladder_steps = 0
    allowance_agree = 0
    #: Placed units whose type is in `Info.lcl`, so the allowance could be
    #: recomputed at all.  Counted rather than inferred from `fills // 2`:
    #: `fills` is incremented per *fill* and is decremented by a raising
    #: build, and units whose type is missing never reach the comparison, so
    #: the two quantities are only equal by an unstated coincidence -- and
    #: when they stop being equal the check fails with a number that points
    #: nowhere near the cause.
    allowance_checked = 0
    allowance_overrides: dict[tuple[int, int, int], int] = {}
    #: Placed units whose type `Info.lcl` does not define.  Zero in the
    #: shipped corpus, and stated so that it cannot become non-zero silently.
    allowance_untyped = 0
    walks = 0
    walk_ok = 0
    walk_diagonals = 0
    walk_outside = 0
    walk_failures: list[str] = []
    executed = 0
    exec_tenths = 0
    exec_victory = 0
    exec_mines = 0
    exec_failures: list[str] = []

    for path in paths:
        try:
            bm = load_lev(str(path))
        except LevError as exc:
            failures.append(f"{path.name}: {exc}")
            continue
        files += 1
        grid = grid_of(bm)
        hooks = hooks_of(bm)
        for unit in bm.active_units:
            if not unit.placed:
                continue
            if unit.type_id not in tables.units:
                allowance_untyped += 1
            else:
                allowance_checked += 1
                computed = allowance_of(bm, unit, tables.units)
                if computed == unit.action_points:
                    allowance_agree += 1
                else:
                    key = (unit.type_id, unit.action_points, computed)
                    allowance_overrides[key] = \
                        allowance_overrides.get(key, 0) + 1
            mover = mover_of(bm, unit.slot, tables.units)
            results: dict[bool, MoveMapResult] = {}
            for pass_friendlies in (False, True):
                try:
                    result = build(grid, mover, delays, hooks,
                                   pass_friendlies=pass_friendlies)
                except MoveMapError as exc:
                    failures.append(f"{path.name} slot {unit.slot}: {exc}")
                    continue
                fills += 1
                results[pass_friendlies] = result
                report = check_invariants(grid, mover, delays, result, hooks)
                if not report.ok:
                    failures.append(
                        f"{path.name} slot {unit.slot} pf={pass_friendlies}: "
                        + "; ".join(report.failures))
                marked_total += len(result.reachable_cells())
                warp_total += len(result.warp_cells())
                max_queue = max(max_queue, result.max_queue)
                max_waves = max(max_waves, result.waves)
                # A cell whose mp_left is 0 but which is marked is the
                # rewrite quirk in the making; counting them proves the
                # corpus actually exercises it.
                start = grid.index(mover.x, mover.y)
                zero_rewrites += sum(
                    1 for i, s in enumerate(result.state)
                    if s == STATE_REACHABLE and result.mp_left[i] == 0
                    and i != start)
                # Determinism: the same input twice.
                again = build(grid, mover, delays, hooks,
                              pass_friendlies=pass_friendlies)
                if again.state != result.state or again.mp_left != result.mp_left:
                    nondeterministic.append(
                        f"{path.name} slot {unit.slot} pf={pass_friendlies}")
            if False in results:
                stats = _walk_checks(grid, mover, delays, hooks,
                                     results[False], path.name)
                walks += stats["walks"]
                walk_ok += stats["ok"]
                walk_diagonals += stats["diagonals"]
                walk_outside += stats["outside"]
                walk_failures += stats["failures"]
                executed += stats["executed"]
                exec_tenths += stats["tenths"]
                exec_victory += stats["victory"]
                exec_mines += stats["mines"]
                exec_failures += stats["exec_failures"]
            if len(results) == 2:
                strict = set(results[False].reachable_cells())
                loose = set(results[True].reachable_cells())
                if not strict <= loose:
                    subset_violations[(path.name, unit.slot)] = \
                        len(strict - loose)
        ladder_steps += sum(1 for c_ in bm.cells if c_.field_type == 8)

    elapsed = time.perf_counter() - started
    c.expect("corpus.missions", len(paths), EXPECTED_MISSIONS)
    c.expect("corpus.files", files, len(paths))
    c.check("corpus.fills", fills > 0, f"{fills} fills over {files} missions")
    c.expect("invariants", failures[:3], [],
             f"{len(failures)} failures" if failures else "all fills clean")
    c.expect("determinism", nondeterministic[:3], [],
             f"{len(nondeterministic)} differing repeats"
             if nondeterministic else f"{fills} repeated fills identical")
    c.check("queue.bound", max_queue < QUEUE_HARD_LIMIT,
            f"largest wave {max_queue} entries, the original aborts at "
            f"{QUEUE_HARD_LIMIT}")
    # A corpus-decidable hypothesis that the corpus **refuted**; the finding is
    # pinned rather than asserted away.  See EXPECTED_PASS_FRIENDLIES_VIOLATIONS.
    c.expect("pass_friendlies.not_monotone", subset_violations,
             EXPECTED_PASS_FRIENDLIES_VIOLATIONS,
             "pass_friendlies is not monotone in reachability")
    # State the two branches the corpus cannot reach, so nobody reads this
    # check as covering them.
    c.expect("allowance.matches_stored_mp", allowance_agree,
             allowance_checked - sum(EXPECTED_ALLOWANCE_OVERRIDES.values()),
             f"0x00475160 recomputed against the saved unit[+0x15] over "
             f"{allowance_checked} placed units")
    c.expect("allowance.every_placed_type_is_defined", allowance_untyped, 0,
             "placed units whose type Info.lcl does not define")
    c.expect("allowance.designer_overrides", allowance_overrides,
             EXPECTED_ALLOWANCE_OVERRIDES,
             "the units whose saved movement points the first turn refresh "
             "would replace")
    c.check("walk.corpus", walks > 0,
            f"{walks} paths reconstructed, {walk_ok} of them successfully")
    # A **pinned corpus fact**, not an invariant.  A walk is allowed to fail:
    # gradient ascent wanders across a plateau of equal `mp_left` cells and can
    # spend its 300-step budget, which is exactly what a target the fill never
    # marked produces.  What the corpus says is that at budget 300 no target
    # the fill *did* mark ever provokes it -- so a change here is a finding,
    # the same way EXPECTED_PASS_FRIENDLIES_VIOLATIONS is.
    c.expect("walk.all_succeed", walk_ok, walks,
             "at budget 300 every marked target is reached; halving the budget "
             "moves this, which is what makes it a measurement")
    c.expect("walk.invariants", walk_failures[:3], [],
             f"{len(walk_failures)} failures" if walk_failures
             else f"{walks} paths clean")
    c.expect("walk.diagonals", walk_diagonals, EXPECTED_WALK_DIAGONALS,
             "diagonal steps in paths a 4-connected fill costed -- docs/23 "
             "§8's asymmetry, measured rather than merely present")
    c.check("execute.corpus", executed == walk_ok,
            f"{executed} paths walked for real, one per reconstructed path")
    c.expect("execute.invariants", exec_failures[:3], [],
             f"{len(exec_failures)} failures" if exec_failures
             else f"{executed} walks clean")
    c.check("execute.distance_accumulates", exec_tenths > 0,
            f"{exec_tenths} tenths of a field walked over the corpus")
    # Stated as an equality, not as "few": the corpus reaches **neither** arm,
    # and saying so out loud is what keeps the two synthetic cases below from
    # looking like belt and braces.  A fill that started offering mine cells,
    # or a mission that authored a VictoryPoint where a squad walks, would
    # move these off zero and this check would say so.
    c.expect("execute.corpus_reaches_no_path_event",
             (exec_victory, exec_mines), (0, 0),
             f"{exec_victory} VictoryPoint claim(s) and {exec_mines} mine(s) "
             f"on {executed} corpus paths -- the fill refuses a mine cell "
             f"(docs/23 §7.1) and no shipped VictoryPoint sits where a squad "
             f"walks, so both arms are exercised synthetically and natively")
    _execute_arm_checks(c, delays)
    c.check("walk.stays_inside", walk_outside == 0,
            f"{walk_outside} of {walk_ok} paths leave the highlighted region; "
            f"the walk is 8-connected but every cell it steps on was marked "
            f"by the 4-connected fill")
    c.expect("warp.cells", warp_total, EXPECTED_WARP_CELLS,
             "cells the warp pass marked across the corpus")
    c.expect("coverage.ladder_cells", ladder_steps, 0,
             "no shipped cell is a Ladder; the ladder step has a native "
             "oracle instead (tools/movemap_gold.py)")
    c.check("coverage.zero_rewrite", zero_rewrites > 0,
            f"{zero_rewrites} cells marked with mp_left 0 -- the rewrite "
            f"quirk is exercised by the corpus")

    LOG.info("%d fills over %d missions in %.1fs (%d cells marked, %d warp)",
             fills, files, elapsed, marked_total, warp_total)
    LOG.info("oracle boundary: %s", ORACLE_BOUNDARY)
    for line in failures[:10]:
        LOG.error("%s", line)
    return c.report()


def _execute_arm_checks(c: Checker, delays: dict[int, int]) -> None:
    """The two arms of ``aExecuteMove`` the shipped corpus never reaches.

    Both are written **after** the fill and the walk, which is not a
    convenience: the fill refuses to step a non-alien mover onto a mine
    (docs/23 §7.1), so a mine placed before it would simply be routed around
    and the arm would stay untested.  ``tools/turn_gold.py`` phase 10 writes
    them at the same point for the same reason, so the synthetic case and the
    native probe are asking the engine the same question.
    """
    width = 5
    start, middle, target = (0, 0), (1, 0), (2, 0)
    units = [_unit(0, *start, mp=6)]
    open_cells = [-1] * (width * width)
    open_cells[0] = 0

    def scenario(player: int, action_point: int, index: int,
                 mine_at: tuple[int, int] | None = None) -> Any:
        grid = _synthetic_grid(width, width)
        grid.action_points[index] = action_point
        hooks = hooks_from_arrays(width, open_cells, visibility={0: 0},
                                  players={0: player})
        mover = Mover(slot=0, x=start[0], y=start[1], player=player, mp=6,
                      special=0, size=0, has_jet_pack=False, mp_allowance=6)
        result = build(grid, mover, delays, hooks, pass_friendlies=False)
        answer = walk(grid, result, start[0], start[1], target[0], target[1],
                      delays, hooks)
        if mine_at is not None:
            obstacles = [OBSTACLE_NONE] * (width * width)
            obstacles[mine_at[1] * width + mine_at[0]] = OBSTACLE_MINE
            hooks = hooks_from_arrays(width, open_cells, visibility={0: 0},
                                      players={0: player},
                                      obstacles=obstacles)
        return execute(grid, hooks, delays, mover, answer)

    index = target[1] * width + target[0]
    claimed = scenario(0, 0x50, index)
    c.expect("execute.victory_point_a", claimed.action_point_writes,
             [(index, 0x51)],
             "action point 0x50 walked onto by player 0 becomes 0x51")
    band_b = scenario(3, 0x55, index)
    c.expect("execute.victory_point_b", band_b.action_point_writes,
             [(index, 0x59)],
             "action point 0x55 walked onto by player 3 becomes 0x59")
    neutral = scenario(PLAYER_ALIEN, 0x50, index)
    c.expect("execute.victory_point_neutral", neutral.action_point_writes, [],
             "player 255 claims nothing -- docs/26 §6.1")
    mined = scenario(0, 0, index, mine_at=middle)
    c.check("execute.mine_stops_the_walk",
            mined.movement_zeroed and mined.steps == 1
            and (mined.x, mined.y) == middle
            and [e.kind for e in mined.events] == ["mine"],
            f"a mine on the second cell ends the walk there: "
            f"{mined.steps} step(s), at ({mined.x},{mined.y}), "
            f"movement zeroed {mined.movement_zeroed}")
    clean = scenario(0, 0, index)
    c.check("execute.mine_is_what_stopped_it",
            not clean.movement_zeroed and clean.steps == 2
            and (clean.x, clean.y) == target,
            f"the same walk without the mine runs to the target: "
            f"{clean.steps} step(s), at ({clean.x},{clean.y})")
    # `docs/26` §6.2 -- the whole detonation block is the caller's
    # (`0x0046EC0F` gates it and `0x0046EC25` picks the arm by the type's
    # size), so what the walk reports is that it stopped on one.
    c.check("execute.mine_stop_is_reported_for_the_caller",
            not mined.ok and mined.stopped_on_mine
            and [e.kind for e in mined.events] == ["mine"]
            and mined.detonate == [],
            "the routine says a mine ended it; `inclib.ai._detonate` is the "
            "arm that fires, and `ai_runtime.check_mine` runs it")


def _walk_checks(grid: Grid, mover: Mover, delays: dict[int, int],
                 hooks: MoveMapHooks, result: MoveMapResult,
                 mission: str) -> dict[str, Any]:
    """Reconstruct a few paths out of one fill and check what must hold.

    The invariants need no oracle: they are properties the routine's own code
    forces.  What they are *for* is docs/23 §8's asymmetry -- the fill costs
    only orthogonal steps while the walk may take diagonal ones -- so the last
    one asks the question a remake actually has to answer: does a path ever
    leave the region the fill highlighted?
    """
    out: dict[str, Any] = {"walks": 0, "ok": 0, "diagonals": 0, "outside": 0,
                           "failures": [], "executed": 0, "tenths": 0,
                           "victory": 0, "mines": 0, "exec_failures": []}
    start = grid.index(mover.x, mover.y)
    targets = [i for i in result.reachable_cells() if i != start]
    if not targets:
        return out
    # Farthest first, then a spread, so a long path and a short one both run.
    targets.sort(key=lambda i: -(abs(i % grid.width - mover.x)
                                 + abs(i // grid.width - mover.y)))
    step = max(1, len(targets) // WALK_TARGETS_PER_FILL)
    for index in targets[::step][:WALK_TARGETS_PER_FILL]:
        tx, ty = index % grid.width, index // grid.width
        out["walks"] += 1
        answer = walk(grid, result, mover.x, mover.y, tx, ty, delays, hooks)
        where = f"{mission} slot {mover.slot} -> ({tx},{ty})"
        if not answer.ok:
            # A failure is legitimate -- gradient ascent can wander until the
            # budget runs out -- but then nothing below is defined.
            continue
        out["ok"] += 1
        if answer.path[0] != index or answer.path[-1] != start:
            out["failures"].append(f"{where}: path does not run target->source")
            continue
        if answer.steps != len(answer.path) - 1:
            out["failures"].append(
                f"{where}: {answer.steps} steps for {len(answer.path)} cells")
        marked = sum(1 for v in answer.state if v == STATE_PATH)
        if marked != len(set(answer.path)):
            out["failures"].append(
                f"{where}: {marked} cells marked for {len(set(answer.path))}")
        for a, b in zip(answer.path, answer.path[1:]):
            ax, ay = a % grid.width, a // grid.width
            bx, by = b % grid.width, b // grid.width
            dx, dy = bx - ax, by - ay
            if (dx, dy) not in WALK_DIR_DELTA:
                out["failures"].append(f"{where}: step ({dx},{dy}) is not one "
                                       f"of the eight directions")
                break
            if climb_quotient(grid.heights[b] - grid.heights[a]) > 1:
                out["failures"].append(
                    f"{where}: step ({ax},{ay})->({bx},{by}) climbs too far")
                break
            direction = WALK_DIR_DELTA.index((dx, dy))
            if direction >= FIRST_DIAGONAL:
                out["diagonals"] += 1
                for component in CORNER_COMPONENTS[direction]:
                    cdx, cdy = WALK_DIR_DELTA[component]
                    if not is_enterable(grid, hooks, delays,
                                        ax + cdx, ay + cdy):
                        out["failures"].append(
                            f"{where}: diagonal cuts a blocked corner at "
                            f"({ax + cdx},{ay + cdy})")
                        break
        if any(result.state[i] != STATE_REACHABLE for i in answer.path):
            out["outside"] += 1
        _execute_checks(grid, mover, delays, hooks, answer, where, out)
    return out


def _execute_checks(grid: Grid, mover: Mover, delays: dict[int, int],
                    hooks: MoveMapHooks, answer: Any, where: str,
                    out: dict[str, Any]) -> None:
    """Walk the reconstructed path for real and check the arithmetic.

    ``aExecuteMove`` has no oracle over the corpus -- calling it needs Wine and
    a save -- so what is checked here is what its own code forces: the distance
    is the step count in tenths, the cost is at least one per step, the facing
    is the last step's, and a VictoryPoint is only ever rewritten inside its
    band.  The *values* those rules use are pinned natively by
    ``tools/turn_gold.py`` phase 10; this is the corpus half.
    """
    moved = execute(grid, hooks, delays, mover, answer)
    out["executed"] += 1
    # **Counted before the early return.**  The mine arm is exactly the one
    # that comes back `ok=False` (``inclib/movemap.py``), so counting it below
    # made the tally structurally zero and the invariant that reads it a claim
    # about nothing.
    out["mines"] += sum(1 for e in moved.events if e.kind == "mine")
    if not moved.ok:
        out["exec_failures"].append(f"{where}: {moved.reason}")
        return
    target = answer.path[0]
    stopped = moved.movement_zeroed
    if not stopped and (moved.x, moved.y) != (target % grid.width,
                                              target // grid.width):
        out["exec_failures"].append(
            f"{where}: ended at ({moved.x},{moved.y}), not the target")
    if not stopped and moved.steps != answer.steps:
        out["exec_failures"].append(
            f"{where}: walked {moved.steps} of {answer.steps} steps")
    route = list(reversed(answer.path))[:moved.steps + 1]
    diagonal = sum(1 for a, b in zip(route, route[1:])
                   if (a % grid.width) != (b % grid.width)
                   and (a // grid.width) != (b // grid.width))
    orthogonal = moved.steps - diagonal
    # **The numbers are written out here on purpose.**  Importing the model's
    # own constants and multiplying by them re-derives the model's answer with
    # the model's arithmetic, and the check passes whatever they are: setting
    # the diagonal distance to 14 left this green.  A check has to carry its
    # own copy of what it is checking.  These four are docs/10 §5.10 and
    # docs/26 §5, and the native oracle for them is tools/turn_gold.py phase
    # 10, where one path cost 3 and walked 25.
    tenths = diagonal * 15 + orthogonal * 10
    if moved.walked != tenths:
        out["exec_failures"].append(
            f"{where}: walked {moved.walked} tenths, wanted {tenths}")
    # The full cost, not a floor: the delay column of the cell **entered** is
    # added to each step's base, and nothing is charged for the cell left.
    # Phase 10 measured that by writing a delay-1 field type onto the source,
    # the middle and the destination of one path -- +0, +1, +1.
    cost = diagonal * 2 + orthogonal * 1
    for step_to in route[1:]:
        cost += delays.get(grid.field_types[step_to], DELAY_IMPASSABLE)
    if moved.cost != cost:
        out["exec_failures"].append(
            f"{where}: cost {moved.cost}, wanted {cost}")
    if moved.steps:
        last, end = route[-2], route[-1]
        step = (end % grid.width - last % grid.width,
                end // grid.width - last // grid.width)
        if moved.facing != FACING_OF_STEP[step]:
            out["exec_failures"].append(
                f"{where}: facing {moved.facing} is not the last step's "
                f"{FACING_OF_STEP[step]}")
    for index, value in moved.action_point_writes:
        if grid.action_points[index] not in VICTORY_BAND:
            out["exec_failures"].append(
                f"{where}: rewrote action point "
                f"{grid.action_points[index]} at {index}, outside the band")
        if value not in VICTORY_BAND:
            out["exec_failures"].append(
                f"{where}: claimed as {value}, outside the band")
    out["tenths"] += moved.walked
    out["victory"] += len(moved.action_point_writes)


def run_one(path: Path, slot: int, pass_friendlies: bool, root: Path | None,
            as_json: bool) -> int:
    search = root if root is not None else path.parent.parent
    try:
        tables = load_info(str(search))
    except InfoError as exc:
        LOG.error("%s", exc)
        return 1
    try:
        bm = load_lev(str(path))
    except LevError as exc:
        LOG.error("%s", exc)
        return 1
    if not any(u.slot == slot for u in bm.active_units):
        LOG.error("no unit in slot %d; placed slots are %s", slot,
                  [u.slot for u in bm.active_units if u.placed])
        return 1
    grid = grid_of(bm)
    mover = mover_of(bm, slot, tables.units)
    result = build(grid, mover, tables.delay_table(), hooks_of(bm),
                   pass_friendlies=pass_friendlies)
    if as_json:
        payload = result.to_dict()
        payload["mission"] = bm.map_name
        payload["slot"] = slot
        payload["pass_friendlies"] = pass_friendlies
        payload["mp"] = mover.mp
        payload["oracle_boundary"] = ORACLE_BOUNDARY
        print(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                         separators=(",", ":"), allow_nan=False))
        return 0
    print(f"{bm.map_name}  {bm.width}x{bm.height}  slot {slot} "
          f"at ({mover.x},{mover.y}) mp {mover.mp} "
          f"pass_friendlies={pass_friendlies}")
    print(f"  {len(result.reachable_cells())} reachable, "
          f"{len(result.warp_cells())} warp targets, {result.waves} waves, "
          f"any_friendly_blocked={result.any_friendly_blocked}")
    for y in range(grid.height):
        row = []
        for x in range(grid.width):
            i = grid.index(x, y)
            if x == mover.x and y == mover.y:
                row.append("@")
            elif result.state[i] == STATE_REACHABLE:
                row.append(str(result.mp_left[i]))
            elif result.state[i] != 0:
                row.append("w")
            else:
                row.append("." if grid.field_types[i] in (0, 1) else "#")
        print("  " + "".join(row))
    print(f"  oracle boundary: {ORACLE_BOUNDARY}")
    return 0


# ---------------------------------------------------------------------------
# Fixtures for the GDScript side
# ---------------------------------------------------------------------------

#: docs/21 §2 -- the shipped delay column, so a synthetic case can reach the
#: field types no mission uses: Debris (12 cells in the whole corpus), Poison
#: (191), Teleporter Entry (22) and the Ladder (**0**).
SYNTHETIC_UNIT_TYPES = [
    {"id": 0, "special": 0, "size": 0, "mp_max": 6},
    {"id": 1, "special": 1, "size": 0, "mp_max": 6},
    {"id": 14, "special": 14, "size": 0, "mp_max": 6},
    {"id": 15, "special": 15, "size": 0, "mp_max": 6},
    {"id": 99, "special": 0, "size": 1, "mp_max": 6},
]


def _unit(slot: int, x: int, y: int, type_id: int = 0, player: int = 0,
          mp: int = 4, visibility: int = 0,
          equipment: list[int] | None = None) -> dict:
    row = next(r for r in SYNTHETIC_UNIT_TYPES if r["id"] == type_id)
    return {
        "slot": slot, "x": x, "y": y, "type_id": type_id, "player": player,
        "mp": mp, "visibility": visibility,
        "equipment_ids": list(equipment or []),
        "special": row["special"], "size": row["size"],
        "mp_allowance": row["mp_max"],
        "has_jet_pack": JET_PACK_EQUIP_ID in (equipment or []),
    }


def _synthetic_grid(w: int, h: int, field_types: list[int] | None = None,
                    heights: list[int] | None = None) -> Grid:
    n = w * h
    return Grid(w, h,
                heights if heights is not None else [0] * n,
                field_types if field_types is not None else [1] * n,
                [0] * n)


def _run_case(name: str, grid: Grid, units: list[dict], delays: dict[int, int],
              slot: int, pass_friendlies: bool,
              obstacles: list[int] | None = None) -> dict:
    unit_cells = [-1] * (grid.width * grid.height)
    for u in units:
        unit_cells[u["y"] * grid.width + u["x"]] = u["slot"]
    hooks = hooks_from_arrays(
        grid.width, unit_cells,
        visibility={u["slot"]: u["visibility"] for u in units},
        players={u["slot"]: u["player"] for u in units},
        obstacles=obstacles)
    mover = next(u for u in units if u["slot"] == slot)
    result = build(grid, Mover(
        slot=slot, x=mover["x"], y=mover["y"], player=mover["player"],
        mp=mover["mp"], special=mover["special"], size=mover["size"],
        has_jet_pack=mover["has_jet_pack"],
        mp_allowance=mover["mp_allowance"]), delays, hooks,
        pass_friendlies=pass_friendlies)
    case = make_case(name, grid, units, delays, slot, pass_friendlies, result,
                     obstacles, walks=_walk_answers(
                         grid, result, mover["x"], mover["y"], delays, hooks))
    cells = case["cells"]
    cells["unit"] = unit_cells
    return case


def _walk_answers(grid: Grid, result: MoveMapResult, sx: int, sy: int,
                  delays: dict[int, int], hooks: MoveMapHooks,
                  limit: int = WALK_TARGETS_PER_FILL) -> list[dict]:
    """``aWalkMoveMap`` over one fill, for the case file the GDScript reads."""
    start = grid.index(sx, sy)
    targets = [i for i in result.reachable_cells() if i != start]
    targets.sort(key=lambda i: -(abs(i % grid.width - sx)
                                 + abs(i // grid.width - sy)))
    step = max(1, len(targets) // limit)
    out: list[dict] = []
    for index in targets[::step][:limit]:
        tx, ty = index % grid.width, index // grid.width
        answer = walk(grid, result, sx, sy, tx, ty, delays, hooks)
        out.append({"tx": tx, "ty": ty, **answer.to_dict()})
    return out


def synthetic_cases(delays: dict[int, int]) -> list[dict]:
    """The branches the corpus cannot reach, and the quirks that look like bugs."""
    cases: list[dict] = []
    flat = _synthetic_grid(9, 9)

    # A plain fill, both flags, with a friendly and an enemy in the way.
    units = [_unit(0, 4, 4), _unit(1, 5, 4, player=0), _unit(2, 3, 4, player=1)]
    for flag in (False, True):
        cases.append(_run_case(f"plain.pf{int(flag)}", flat, units, delays, 0,
                               flag))

    # A hidden unit is treated exactly like an empty cell.
    hidden = [_unit(0, 4, 4), _unit(1, 5, 4, player=1, visibility=3)]
    cases.append(_run_case("hidden_enemy", flat, hidden, delays, 0, False))

    # The cost table, on the field types no shipped mission carries.
    ft = [1] * 81
    ft[4 * 9 + 5] = 5     # Debris, delay 1
    ft[4 * 9 + 3] = 6     # Poison, delay 0
    ft[3 * 9 + 4] = 9     # Teleporter Entry, delay 0
    ft[5 * 9 + 4] = 10    # Teleporter Exit, impassable
    ft[2 * 9 + 4] = 7     # Enormous Obs, impassable
    costs = _synthetic_grid(9, 9, ft)
    cases.append(_run_case("cost_table", costs, [_unit(0, 4, 4, mp=6)], delays,
                           0, False))

    # Ladder to ladder: the whole allowance, and the height test skipped.
    ladder_ft = [1] * 81
    ladder_heights = [0] * 81
    for y in range(9):
        ladder_ft[y * 9 + 4] = 8
        ladder_heights[y * 9 + 4] = y * 6400
    ladder = _synthetic_grid(9, 9, ladder_ft, ladder_heights)
    cases.append(_run_case("ladder", ladder, [_unit(0, 4, 4, mp=6)], delays, 0,
                           False))

    # The climb rule: 3199 passes, 3200 blocks, in both directions.
    climb_heights = [0] * 81
    climb_heights[4 * 9 + 5] = 3199
    climb_heights[4 * 9 + 3] = -3200
    climb_heights[3 * 9 + 4] = 3200
    climb = _synthetic_grid(9, 9, None, climb_heights)
    cases.append(_run_case("climb", climb, [_unit(0, 4, 4)], delays, 0, False))

    # The rewrite quirk: a cell reached with zero left is still writable.
    quirk_ft = [2] * 81
    for x, y in ((4, 4), (5, 4), (6, 4), (6, 3), (5, 3), (4, 3)):
        quirk_ft[y * 9 + x] = 1
    quirk = _synthetic_grid(9, 9, quirk_ft)
    cases.append(_run_case("zero_rewrite", quirk, [_unit(0, 4, 4, mp=3)],
                           delays, 0, False))

    # A large unit needs a flat, clear 3x3 for every cell of its path.
    large_heights = [0] * 81
    large_heights[4 * 9 + 6] = 1600
    large = _synthetic_grid(9, 9, None, large_heights)
    cases.append(_run_case("clearance_3x3", large,
                           [_unit(0, 4, 4, type_id=99)], delays, 0, False))

    # The two refusals, and the warp at both ranges.
    cases.append(_run_case("special_1", flat, [_unit(0, 4, 4, type_id=1)],
                           delays, 0, False))
    cases.append(_run_case("special_14", flat, [_unit(0, 4, 4, type_id=14)],
                           delays, 0, False))
    cases.append(_run_case("warp_special_15", flat,
                           [_unit(0, 4, 4, type_id=15)], delays, 0, False))
    cases.append(_run_case("warp_jet_pack", flat,
                           [_unit(0, 4, 4, equipment=[JET_PACK_EQUIP_ID])],
                           delays, 0, False))
    # A unit that has spent its turn cannot warp with the Jet Pack.
    cases.append(_run_case("warp_jet_pack_no_mp", flat,
                           [_unit(0, 4, 4, mp=0,
                                  equipment=[JET_PACK_EQUIP_ID])],
                           delays, 0, False))
    # A victory point is not a warp destination.
    vp_grid = _synthetic_grid(9, 9)
    vp_points = list(vp_grid.action_points)
    vp_points[4 * 9 + 6] = 0x50
    vp_points[4 * 9 + 2] = 0x59
    vp = Grid(9, 9, list(vp_grid.heights), list(vp_grid.field_types), vp_points)
    cases.append(_run_case("warp_victory_point", vp,
                           [_unit(0, 4, 4, type_id=15)], delays, 0, False))

    # The obstacle byte, which is 255 in all 184162 shipped cells.
    none = [OBSTACLE_NONE] * 81
    fire = list(none)
    fire[4 * 9 + 5] = OBSTACLE_FIRE
    cases.append(_run_case("obstacle_fire", flat, [_unit(0, 4, 4)], delays, 0,
                           False, fire))
    mine = list(none)
    mine[4 * 9 + 5] = OBSTACLE_MINE
    cases.append(_run_case("obstacle_mine", flat, [_unit(0, 4, 4)], delays, 0,
                           False, mine))
    cases.append(_run_case("obstacle_mine_alien", flat,
                           [_unit(0, 4, 4, player=255)], delays, 0, False,
                           mine))
    shield = list(none)
    shield[4 * 9 + 4] = OBSTACLE_SHIELD
    cases.append(_run_case("obstacle_shield", flat, [_unit(0, 4, 4)], delays, 0,
                           False, shield))
    return cases


def slice_cases(root: Path, mission: str,
                tables) -> list[dict]:
    """Every placed unit of the slice's lead mission, both flags."""
    bm = load_lev(str(root / MISSIONS_REL / f"{mission}.lev"))
    grid = grid_of(bm)
    hooks = hooks_of(bm)
    delays = tables.delay_table()
    unit_cells = [-1 if c.unit is None else c.unit for c in bm.cells]
    units = []
    for unit in bm.active_units:
        if not unit.placed:
            continue
        row = tables.units.get(unit.type_id)
        units.append({
            "slot": unit.slot, "x": unit.x, "y": unit.y,
            "type_id": unit.type_id, "player": unit.player,
            "mp": unit.action_points, "visibility": unit.visibility,
            "equipment_ids": list(unit.equipment_ids),
            "special": 0 if row is None else row.special,
            "size": 0 if row is None else row.size,
            "mp_allowance": allowance_of(bm, unit, tables.units),
            "has_jet_pack": JET_PACK_EQUIP_ID in unit.equipment_ids,
        })
    cases: list[dict] = []
    for unit in units:
        for flag in (False, True):
            mover = mover_of(bm, unit["slot"], tables.units)
            result = build(grid, mover, delays, hooks, pass_friendlies=flag)
            case = make_case(f"{mission}.slot{unit['slot']}.pf{int(flag)}",
                             grid, units, delays, unit["slot"], flag, result,
                             walks=_walk_answers(grid, result, unit["x"],
                                                 unit["y"], delays, hooks))
            cells = case["cells"]
            cells["unit"] = unit_cells
            cases.append(case)
    return cases


def emit_cases(root: Path, out_dir: Path, mission: str) -> int:
    tables = load_info(str(root))
    delays = tables.delay_table()
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, payload in (
        ("cases_synthetic.json", cases_document(
            "executable-Python", "tools/inclib/movemap.py synthetic cases",
            synthetic_cases(delays))),
        ("cases_slice.json", cases_document(
            "executable-Python", f"tools/inclib/movemap.py on {mission}",
            slice_cases(root, mission, tables))),
    ):
        path = out_dir / name
        path.write_text(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                                   separators=(",", ":"), allow_nan=False)
                        + "\n", encoding="utf-8")
        cases = payload["cases"]
        LOG.info("wrote %s (%d cases, %d bytes)", path, len(cases),
                 path.stat().st_size)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("path", nargs="?", type=Path, help="one .lev file")
    ap.add_argument("--check", metavar="GAME_ROOT", type=Path,
                    help="run the fill over every placed unit of every mission")
    ap.add_argument("--slot", type=int, default=0,
                    help="unit slot to fill from (default 0)")
    ap.add_argument("--pass-friendlies", action="store_true",
                    help="let the fill pass through units of the same player")
    ap.add_argument("--root", type=Path,
                    help="game root for Info.lcl when it is not the parent")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--emit-cases", metavar="DIR", type=Path,
                    help="write the GDScript-side fixtures into DIR")
    ap.add_argument("--mission", default="_C_115",
                    help="the mission --emit-cases uses for slice.json")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    if args.emit_cases:
        if args.root is None:
            ap.error("--emit-cases needs --root")
        return emit_cases(args.root, args.emit_cases, args.mission)
    if args.check:
        return run_checks(args.check)
    if args.path is None:
        ap.print_help()
        return 2
    return run_one(args.path, args.slot, args.pass_friendlies, args.root,
                   args.json)


if __name__ == "__main__":
    sys.exit(main())
