#!/usr/bin/env python3
"""Run the AI model over the corpus -- ``docs/23``.

The computer's turn is exercised against **every shipped mission that places a
live alien** and every alien on one.  What the check asserts is what
``docs/23`` states and a wrong implementation would violate:

* all eleven order arms are dispatched -- ten of them by shipped data and
  order 3 by a scene built for it, exactly as ``docs/94`` built one for the
  reaction fire that appears on no map;
* the six-level horizon is monotone: each level's reachable set contains the
  previous one, and level 2 -- the only one that may pass through friendly
  units -- is the only one whose set can include an occupied cell;
* the two refusals before the fill (``special`` 1 and 14) really do produce an
  empty map, and the corpus reaches both;
* target choice is *only* hit probability: the chosen cell always carries the
  numerically largest marker, and that marker is the band
  ``aGetHitProbability`` puts the chance in;
* a unit is never left owing action points, and a weapon whose heat cap is 0
  is never fired;
* a plan whose path runs through somebody moves **nothing**, and no path
  leaves the highlighted region;
* the turn **terminates**: a bad ``repeat`` condition hangs rather than
  answering wrongly, so the sweep count is bounded and the bound is checked;
* every alien in the corpus either resolves a shot or refuses for a **named**
  reason -- the counter that would have caught the missing ``spores_filtered``
  pattern;
* the three places a remake goes wrong silently: the later cell wins a target
  tie, the later direction wins a path tie, and the slots are swept 0…199.

Usage::

    ai_runtime.py --check gog_incubation
    ai_runtime.py --emit-cases tests/fixtures/ai/cases_ai.json --root gog_incubation
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

from inclib import ai                                              # noqa: E402
from inclib import combat as combatmod                             # noqa: E402
from inclib import movemap                                         # noqa: E402
from inclib.check import Checker                                   # noqa: E402
from inclib.info import BalanceTables, load_info_file              # noqa: E402
from inclib.lev import load_lev                                    # noqa: E402

LOG = logging.getLogger("ai_runtime")

#: ``docs/21`` §4 -- the two weapons whose heat cap is 0, which is the only
#: thing the heat gate in ``0x0040A440`` can express.
HEAT_CAP_ZERO_WEAPONS = (36, 37)

#: How many aliens the horizon and target checks sample per mission.  The
#: whole-turn check runs on **every** mission; these two are per-unit and
#: quadratic in the map, so they take a bounded slice of each.
SAMPLE_PER_MISSION = 4

#: Cells reached per horizon level, summed over the sampled movers of the whole
#: corpus.  Recorded from a run, like ``docs/23``'s order histogram: it pins the
#: six entries of ``0x0040AD70``'s table, which no relation between the levels
#: can.  Levels 4 and 5 agree because 100 points already reach everything 250
#: would.
HORIZON_REACH_CENSUS = {0: 9142, 1: 21154, 2: 87598, 3: 98564, 4: 104083,
                        5: 104083}

#: ``docs/23`` §6's bands, written out a second time and independently of
#: :data:`inclib.ai.TARGET_BANDS`, because a check that recomputes the band
#: with the same table it is checking proves only that the table is a
#: function.  ``(upper bound, marker)``; anything above the last is 34.
BAND_TABLE_FROM_THE_SPEC = ((20, 30), (50, 31), (70, 32), (90, 33))
BAND_ABOVE_ALL = 34

#: Every ordered attacker/target pair the corpus can resolve, by hit
#: percentage.  Recorded from a run.
PAIR_PERCENT_CENSUS = {10: 3, 19: 4, 20: 1, 28: 6, 32: 4, 37: 2, 42: 2, 44: 2,
                       46: 3, 48: 2, 52: 3, 55: 7, 56: 4, 60: 3, 64: 9, 68: 4,
                       72: 6, 73: 5, 76: 5, 80: 4, 82: 1, 84: 4, 86: 3, 88: 3,
                       92: 5, 94: 3, 96: 9, 99: 24, 100: 16}

#: How the approach census strides the map, and what it comes to.
APPROACH_STRIDE = 7
APPROACH_CENSUS = (67256, 1628, 3130292)

#: ``0x0042FF30``'s own refusal, mirrored from ``inclib.ai``'s ``>= 254``.
BAND_REFUSAL = 254

CASES_SCHEMA = "incubation.ai-cases/1"


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def mission_paths(root: Path) -> list[Path]:
    return sorted(root.rglob("*.lev"))


def delays_of(tables: BalanceTables) -> dict[int, int]:
    return {row.type: row.delay for row in tables.ctrlmap.values()}


def context_for(path: Path, tables: BalanceTables, delays: dict[int, int],
                seed: float = 1.0) -> ai.AIContext:
    """One mission as the world the computer's turn runs against.

    The fog pass runs first and for **player 255**, because the hand-over does
    (``docs/25`` §4, ``World.submit_end_turn``): ``unit[+0x4F]`` is recomputed
    from the incoming player's side, and ``0x0042FF30`` refuses a target that
    is not fully visible.  Skipping it would leave the authored bytes in place
    and quietly halve the number of shots.
    """
    bm = load_lev(path)
    world = combatmod.world_from_map(bm, tables, seed=seed)
    combatmod.build_visible_map(world, ai.PLAYER_COMPUTER)
    return ai.context_from_world(world, delays)


def aliens_of(ctx: ai.AIContext) -> list[combatmod.CombatUnit]:
    return [ctx.world.units[s] for s in sorted(ctx.world.units)
            if ctx.world.units[s].player == ai.PLAYER_COMPUTER
            and ctx.world.units[s].hp > 0]


# ---------------------------------------------------------------------------
# The corpus census -- what the rest of the checks are counted against
# ---------------------------------------------------------------------------

def check_census(c: Checker, root: Path, tables: BalanceTables,
                 delays: dict[int, int]) -> dict[str, Any]:
    """Count what the corpus holds, and assert the totals are not zero.

    The numbers are asserted as **exact** values, so a mistyped root, a lost
    mission or a changed `Info.lcl` all come out red rather than green.
    """
    missions = 0
    aliens = 0
    orders: dict[int, int] = {}
    specials: dict[int, int] = {}
    families: dict[str, int] = {}
    arms: dict[str, int] = {}
    paths = mission_paths(root)
    for path in paths:
        bm = load_lev(path)
        live = [u for u in bm.units
                if u.placed and u.player == ai.PLAYER_COMPUTER
                and u.hit_points > 0]
        if live:
            missions += 1
        for unit in live:
            aliens += 1
            orders[unit.order] = orders.get(unit.order, 0) + 1
            row = tables.units.get(unit.type_id)
            special = -1 if row is None else row.special
            specials[special] = specials.get(special, 0) + 1
            try:
                family = combatmod.pattern_family(unit.weapon)
            except combatmod.CombatError:
                family = "unknown"
            families[family] = families.get(family, 0) + 1
            arm = ai.overlay_arm(unit.weapon)
            arms[arm] = arms.get(arm, 0) + 1

    c.expect("corpus.missions", len(paths), 155)
    c.expect("corpus.missions_with_aliens", missions, 108)
    c.expect("corpus.aliens", aliens, 1594)
    c.expect("corpus.orders", dict(sorted(orders.items())),
             {0: 745, 1: 6, 2: 14, 4: 3, 5: 57, 6: 48, 7: 103, 8: 424,
              9: 122, 10: 72},
             "the primary order of every live alien")
    c.expect("corpus.specials", dict(sorted(specials.items())),
             {0: 1118, 1: 20, 2: 97, 6: 4, 9: 133, 14: 10, 15: 74, 16: 138},
             "docs/21 section 5's enumerator over the same population")
    c.expect("corpus.immobile", specials.get(1, 0) + specials.get(14, 0), 30,
             "aliens that cannot move at all -- the pre-fill refusal")
    c.expect("corpus.can_warp", specials.get(15, 0), 74)
    c.expect("corpus.patterns", dict(sorted(families.items())),
             {"aim_and_neighbours": 121, "aim_cell_70": 138,
              "aim_cell_full": 1025, "none": 92, "spores_filtered": 218},
             "the target pattern each alien's weapon reaches")
    c.check("corpus.patterns_simulated",
            all(f in combatmod.SIMULATED_FAMILIES or f == "none"
                for f in families),
            "every family a corpus alien reaches is simulated or is the "
            "no-pattern placeholder")
    c.expect("corpus.overlay_arms", dict(sorted(arms.items())),
             {"error": 92, "units": 1502},
             "which arm of 0x0042FF30 each alien's weapon reaches")
    return {"missions": missions, "aliens": aliens, "orders": orders,
            "specials": specials, "families": families, "arms": arms}


# ---------------------------------------------------------------------------
# The horizon -- docs/23 section 5.1
# ---------------------------------------------------------------------------

#: ``docs/23`` §5.1 -- the levels that flood with ``passFriendlies`` clear, in
#: the order their movement-point overrides increase.  The set a fill reaches
#: grows along **this** chain and not along 0…5: level 2 is the odd one out
#: twice over, with 30 points *and* permission to walk through friendly units,
#: and level 3 takes the permission away again.
HORIZON_CHAIN = (0, 1, 3, 4, 5)


def check_horizon(c: Checker, root: Path, tables: BalanceTables,
                  delays: dict[int, int]) -> None:
    """Six fills per unit, and what has to be true of the six together."""
    monotone = 0
    reach_totals: dict[int, int] = {level: 0 for level in range(ai.MAX_LEVEL + 1)}
    violations: list[str] = []
    friendly_levels: set[int] = set()
    hidden_levels: set[int] = set()
    sampled = 0
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx)[:SAMPLE_PER_MISSION]:
            row = ctx.world.tables.units.get(unit.type_id)
            if row is not None and row.special in movemap.SPECIAL_CANNOT_MOVE:
                continue
            sampled += 1
            reached: dict[int, set[int]] = {}
            for level in range(ai.MAX_LEVEL + 1):
                ai.reset_overlay(ctx)
                result = ai.build_move_map(ctx, unit, level)
                if result is None:
                    violations.append(f"{path.name} slot {unit.slot} "
                                      f"level {level}: the fill refused")
                    break
                reach = {i for i, s in enumerate(ctx.state)
                         if s == movemap.STATE_REACHABLE}
                reached[level] = reach
                reach_totals[level] += len(reach)
                for index in reach:
                    other = ctx.world.unit_at[index]
                    if other < 0 or other == unit.slot:
                        continue
                    occupant = ctx.world.units.get(other)
                    if occupant is None:
                        continue
                    if occupant.visibility == combatmod.VISIBLE_HIDDEN:
                        # docs/23 §7.3: a hidden unit is treated exactly like
                        # an empty cell at every level -- "the AI does not
                        # cheat about what it cannot see", and the price is
                        # that it plans through enemies it has not spotted.
                        hidden_levels.add(level)
                        continue
                    if occupant.player == unit.player:
                        friendly_levels.add(level)
            if len(reached) <= ai.MAX_LEVEL:
                continue
            previous: set[int] | None = None
            for level in HORIZON_CHAIN:
                reach = reached[level]
                if previous is not None and not previous <= reach:
                    violations.append(
                        f"{path.name} slot {unit.slot} level {level}: "
                        f"{len(previous - reach)} cells lost")
                else:
                    monotone += 1
                previous = reach
            if not reached[1] <= reached[2]:
                violations.append(f"{path.name} slot {unit.slot}: level 2 "
                                  f"does not contain level 1")
            else:
                monotone += 1
    c.check("horizon.sampled", sampled > 0, f"{sampled} movers")
    # **The census is what binds the six numbers themselves.**  Everything
    # else about the horizon is a *relation* -- monotone, contains, may pass a
    # friendly -- and a relation survives any table that keeps the same order.
    # A mutation battery found that: changing level 2's 30 points to 40 left
    # every other check in this file green, and left the native whole-turn
    # capture green too, because 30 points already floods a 20x20 map.  The
    # totals below move the moment any of the six does.
    c.expect("horizon.reach_census", reach_totals, HORIZON_REACH_CENSUS,
             "cells reached, summed over the sampled movers, per level")
    c.expect("horizon.monotone", violations, [],
             f"{monotone} transitions along {HORIZON_CHAIN} plus 1 -> 2, each "
             f"a superset of the last")
    c.expect("horizon.friendly_levels", sorted(friendly_levels), [2],
             "level 2 is the only one that may reach a visible friendly's cell")
    c.check("horizon.hidden_is_empty", bool(hidden_levels),
            f"a hidden unit's cell is enterable at levels "
            f"{sorted(hidden_levels)} -- docs/23 section 7.3")


def check_immobile(c: Checker, root: Path, tables: BalanceTables,
                   delays: dict[int, int]) -> None:
    """``special`` 1 and 14 leave the map empty -- and the corpus has both."""
    seen: dict[int, int] = {}
    bad: list[str] = []
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx):
            row = ctx.world.tables.units.get(unit.type_id)
            if row is None or row.special not in movemap.SPECIAL_CANNOT_MOVE:
                continue
            seen[row.special] = seen.get(row.special, 0) + 1
            ai.reset_overlay(ctx)
            ai.build_move_map(ctx, unit, 5)
            reach = [i for i, s in enumerate(ctx.state)
                     if s != movemap.STATE_RESET]
            if reach:
                bad.append(f"{path.name} slot {unit.slot}: {len(reach)} cells")
    c.expect("immobile.reached", dict(sorted(seen.items())), {1: 20, 14: 10})
    c.expect("immobile.empty_map", bad, [],
             "every immobile alien's widest fill marks nothing")


# ---------------------------------------------------------------------------
# Target choice -- docs/23 sections 4 and 6
# ---------------------------------------------------------------------------

def check_targets(c: Checker, root: Path, tables: BalanceTables,
                  delays: dict[int, int]) -> None:
    """The chosen cell carries the largest marker, and the marker is the band."""
    checked = 0
    not_max: list[str] = []
    wrong_band: list[str] = []
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx):
            ai.reset_overlay(ctx)
            if not ai.build_target_overlay(ctx, unit):
                continue
            ai.prune_objects(ctx, False)
            best, score, refused = ai.select_target(ctx, ai.FIRE_ANY, 0)
            if refused or best is None:
                continue
            checked += 1
            top = max(s for s in ctx.state
                      if ai.TARGET_MARKER_MIN <= s <= ai.TARGET_MARKER_MAX)
            if score != top:
                not_max.append(f"{path.name} slot {unit.slot}: "
                               f"{score} against {top}")
            slot = ctx.world.unit_at[best]
            target = ctx.world.units.get(slot) if slot >= 0 else None
            weapon = ai.effective_weapon(ctx, unit)
            if target is None or weapon is None:
                # A weapon with `special` 6 stamps the cell the target stood on
                # last turn, which may be empty now; the band cannot be
                # recomputed from an empty cell, and that is the mechanism
                # rather than a failure.
                continue
            chance = combatmod.hit_probability(ctx.world, unit, target, weapon,
                                               apply_los=True)
            if not chance.in_range:
                continue
            expected = ai._band_of(chance.percent)
            if expected != score:
                wrong_band.append(f"{path.name} slot {unit.slot}: "
                                  f"{score} for {chance.percent}%")
    c.check("target.sampled", checked > 0, f"{checked} target choices")
    c.expect("target.is_maximum", not_max, [],
             "the AI always shoots at its highest hit chance")
    c.expect("target.band_matches", wrong_band, [],
             "the marker is aGetHitProbability's band, 30..34")


def check_bands(c: Checker, root: Path, tables: BalanceTables,
                delays: dict[int, int]) -> None:
    """``0x0042FF30``'s five bands, against a table stated twice.

    :func:`check_targets` above asserts that the stamped marker is
    ``_band_of(percent)`` -- which is true of *any* boundary table, because it
    is the same table on both sides.  This one writes ``docs/23`` §6's
    boundaries out independently, and counts the whole corpus's ordered
    attacker/target pairs into them.

    **What the corpus cannot bind is recorded rather than implied.** The 147
    reachable pairs land on 29 distinct percentages, and the gaps between them
    are windows in which a boundary could move without any shipped situation
    noticing: nothing sits in 21..25, so the top of the ``<= 20`` band rests on
    the listing alone.  The check reports the windows it leaves open.
    """
    histogram: dict[int, int] = {}
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx):
            weapon = ai.effective_weapon(ctx, unit)
            if weapon is None:
                continue
            for other in ctx.world.units.values():
                if other.hp == 0 or other.player == unit.player:
                    continue
                chance = combatmod.hit_probability(ctx.world, unit, other,
                                                   weapon, apply_los=True)
                if not chance.in_range or chance.percent <= 0:
                    continue
                # `0x0042FF30` refuses anything at or above 254, which is how
                # the two forcing hooks (weapons 45 and 47) express "never".
                if chance.percent >= BAND_REFUSAL:
                    continue
                histogram[chance.percent] = histogram.get(chance.percent, 0) + 1
    c.expect("band.pair_census", dict(sorted(histogram.items())),
             PAIR_PERCENT_CENSUS,
             "every ordered attacker/target pair the corpus can resolve")

    wrong: list[str] = []
    for percent in sorted(histogram):
        expected = BAND_ABOVE_ALL
        for limit, marker in BAND_TABLE_FROM_THE_SPEC:
            if percent <= limit:
                expected = marker
                break
        if ai._band_of(percent) != expected:
            wrong.append(f"{percent}% -> {ai._band_of(percent)}, "
                         f"docs/23 section 6 says {expected}")
    # **The only guard the boundaries have.** The census above binds a boundary
    # only where a shipped pair sits on each side of it, and the report below
    # shows that none does: moving the first boundary from 20 to 25 reclassifies
    # nothing, because no situation in the corpus lands in 21..25. So the table
    # itself is stated twice -- the same treatment `CONVERTER_VERSION` gets --
    # and the two statements are compared directly.
    c.expect("band.table_is_the_spec_s",
             [tuple(entry) for entry in ai.TARGET_BANDS],
             [tuple(entry) for entry in BAND_TABLE_FROM_THE_SPEC],
             "docs/23 section 6's four boundaries, written down a second time")
    c.expect("band.matches_the_spec_table", wrong, [],
             f"{len(histogram)} distinct percentages, "
             f"{sum(histogram.values())} pairs")

    # Which boundaries the data actually pins, and how far each could move
    # before a shipped pair would notice.
    unbound: list[str] = []
    for limit, _marker in BAND_TABLE_FROM_THE_SPEC:
        below = [p for p in histogram if p <= limit]
        above = [p for p in histogram if p > limit]
        low = max(below) if below else None
        high = min(above) if above else None
        if low is None or high is None or high - low > 1:
            unbound.append(f"{limit}: nearest pairs {low} and {high}")
    c.check("band.boundaries_the_corpus_leaves_open", True,
            "; ".join(unbound) if unbound
            else "every boundary has a pair on each side of it")


def check_spores(c: Checker, root: Path, tables: BalanceTables,
                 delays: dict[int, int]) -> None:
    """``0x46ACCD`` -- the one target pattern this stage added.

    ``spores_filtered`` is ``aim_and_neighbours`` with one extra test: the
    neighbouring cell is stamped only if what stands on it is **not** owned by
    ``0xFC``, the neutral side (``docs/22`` §7.2).  The filter is the whole
    difference between the two families, and a mutation battery found that
    deleting it left every check in this file and the native capture green.

    The corpus exercises it heavily -- 806 situations in which a neutral unit
    stands next to a target a spores weapon can aim at -- so the check is a
    census over shipped data and not a scene.
    """
    aimers = 0
    marked = 0
    adjacent = 0
    leaked: list[str] = []
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx):
            if combatmod.pattern_family(unit.weapon) != "spores_filtered":
                continue
            aimers += 1
            for other in ctx.world.units.values():
                if other.hp == 0 or other.player == unit.player:
                    continue
                cells = combatmod.mark_cells(ctx.world, unit.weapon,
                                             other.x, other.y)
                marked += len(cells)
                stamped = {(x, y) for x, y, _m in cells}
                for dx, dy in combatmod.STEP_DIRECTIONS:
                    nx, ny = other.x + dx, other.y + dy
                    if not ctx.world.in_bounds(nx, ny):
                        continue
                    slot = ctx.world.unit_at[ctx.world.index(nx, ny)]
                    if slot < 0:
                        continue
                    occupant = ctx.world.units.get(slot)
                    if occupant is None \
                            or occupant.player != combatmod.PLAYER_NEUTRAL:
                        continue
                    adjacent += 1
                    if (nx, ny) in stamped:
                        leaked.append(f"{path.name}: ({nx},{ny}) beside "
                                      f"({other.x},{other.y})")
    c.expect("spores.aimers", aimers, 218,
             "aliens whose weapon uses the filtered-neighbour pattern")
    c.expect("spores.marked_census", marked, 835,
             "cells the pattern stamps, over the whole corpus")
    c.check("spores.the_filter_is_exercised", adjacent > 0,
            f"{adjacent} neutral units standing next to a reachable target")
    c.expect("spores.no_neutral_is_stamped", leaked[:4], [],
             f"0 of {adjacent} neutral neighbours were marked")


def check_approach(c: Checker, root: Path, tables: BalanceTables,
                   delays: dict[int, int]) -> None:
    """``0x0040ADC0``'s acceptance, as a census.

    A census and not a proof, and it says so: the routine's rules come from
    the listing (``docs/23`` §5.4) and from ``ai_gold.py``'s ``approach``
    phase, which compares the model against the engine over 10 probed targets.
    Those targets happen to contain no height step of exactly 2, so the climb
    threshold -- the one number that separates this transcription from the
    obvious wrong one -- is not pinned by the native capture.  A mutation
    battery found exactly that.  The totals below move when it changes.
    """
    accepted = 0
    scanned = 0
    best_total = 0
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx)[:SAMPLE_PER_MISSION]:
            row = ctx.world.tables.units.get(unit.type_id)
            if row is not None and row.special in movemap.SPECIAL_CANNOT_MOVE:
                continue
            ai.reset_overlay(ctx)
            if ai.build_move_map(ctx, unit, 0) is None:
                continue
            best = 0
            # Every seventh cell: the scan is quadratic in the map and the
            # stride keeps the corpus pass to seconds while still visiting
            # 67 thousand candidates.
            for index in range(0, len(ctx.state), APPROACH_STRIDE):
                found, best = ai.approach_cell(ctx, index, best, unit.slot)
                scanned += 1
                if found is not None:
                    accepted += 1
            best_total += best
    c.expect("approach.census", (scanned, accepted, best_total),
             APPROACH_CENSUS,
             "candidates scanned, candidates accepted, best scores summed")


def check_shot_reasons(c: Checker, root: Path, tables: BalanceTables,
                       delays: dict[int, int]) -> None:
    """Every alien resolves a shot or refuses for a reason with a name.

    This is the counter that would have caught the missing ``spores_filtered``
    pattern: an alien whose weapon reaches an unsimulated handler shows up
    under ``pattern not simulated`` instead of quietly never firing.
    """
    reasons: dict[str, int] = {}
    total = 0
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx):
            total += 1
            reason = shot_reason(ctx, unit)
            reasons[reason] = reasons.get(reason, 0) + 1
    c.expect("shot.population", total, 1594)
    c.expect("shot.accounted", sum(reasons.values()), total,
             "every alien lands in exactly one bucket")
    c.check("shot.no_unsimulated_pattern",
            reasons.get("target pattern not simulated", 0) == 0,
            f"buckets: {dict(sorted(reasons.items()))}")
    c.check("shot.some_resolve", reasons.get("resolves a shot", 0) > 0,
            f"{reasons.get('resolves a shot', 0)} aliens can shoot from where "
            f"they stand at the start of the mission")
    c.expect("shot.no_pattern_weapons",
             reasons.get("weapon has no target pattern", 0), 92,
             "the 0x0042FF30 arm that reports \"unknown weapon\"")


def shot_reason(ctx: ai.AIContext, unit: combatmod.CombatUnit) -> str:
    """Why this alien can or cannot resolve a shot, as a named bucket."""
    world = ctx.world
    weapon = world.tables.weapons.get(unit.weapon)
    if weapon is None:
        return "weapon id has no Info.lcl row"
    if combatmod.pattern_family(unit.weapon) == "none":
        return "weapon has no target pattern"
    if combatmod.pattern_family(unit.weapon) \
            not in combatmod.SIMULATED_FAMILIES:
        return "target pattern not simulated"
    if combatmod.max_heat(world, unit) == 0:
        return "the weapon's heat cap is 0, so the AI never fires it"
    if unit.mp < weapon.ap:
        return "not enough action points for one shot"
    if unit.fp <= ai.MIN_FITNESS_TO_AIM:
        return "too tired to aim"
    if ai.overlay_arm(unit.weapon) != "units":
        return "the overlay arm stamps no 30..34 band"
    if ai.effective_weapon(ctx, unit) is None:
        return "jammed or out of ammunition with no fallback weapon"
    ai.reset_overlay(ctx)
    ai.build_target_overlay(ctx, unit)
    ai.prune_objects(ctx, False)
    best, _score, refused = ai.select_target(ctx, ai.FIRE_ANY, 0)
    if refused:
        return "the marker fell on a cell with no unit"
    if best is None:
        return "no enemy in range, visible and unobstructed"
    return "resolves a shot"


# ---------------------------------------------------------------------------
# Firing -- docs/23 section 4
# ---------------------------------------------------------------------------

def check_fire(c: Checker, root: Path, tables: BalanceTables,
               delays: dict[int, int]) -> None:
    """No unit ends a shot owing points, and a cap-0 weapon never shoots."""
    owing: list[str] = []
    cap_zero_fired: list[str] = []
    fired = 0
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx):
            before = unit.mp
            if not ai.fire(ctx, unit):
                continue
            fired += 1
            if unit.mp < 0 or unit.mp > before:
                owing.append(f"{path.name} slot {unit.slot}: "
                             f"{before} -> {unit.mp}")
            if unit.weapon in HEAT_CAP_ZERO_WEAPONS:
                cap_zero_fired.append(f"{path.name} slot {unit.slot}")
    c.check("fire.sampled", fired > 0, f"{fired} shots resolved")
    c.expect("fire.never_owes", owing, [],
             "the eligibility test is mp < ap and the subtraction clamps")
    c.expect("fire.heat_cap_zero_never_fires", cap_zero_fired, [],
             "weapons 36 ParaBomb and 37 Mine")
    caps = {w: tables.weapons[w].heat for w in HEAT_CAP_ZERO_WEAPONS
            if w in tables.weapons}
    c.expect("fire.heat_cap_zero_table", caps, {36: 0, 37: 0},
             "and they are the only two")
    zero = sorted(w.id for w in tables.weapons.values()
                  if w.in_use and w.heat == 0)
    c.expect("fire.heat_cap_zero_ids", zero, list(HEAT_CAP_ZERO_WEAPONS))


# ---------------------------------------------------------------------------
# Committing -- docs/23 section 5.3
# ---------------------------------------------------------------------------

def check_commit(c: Checker, root: Path, tables: BalanceTables,
                 delays: dict[int, int]) -> None:
    """A blocked path moves nothing, and no path leaves the highlight."""
    outside: list[str] = []
    blocked_moved: list[str] = []
    walks = 0
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        for unit in aliens_of(ctx)[:SAMPLE_PER_MISSION]:
            ai.reset_overlay(ctx)
            if ai.build_move_map(ctx, unit, 0) is None:
                continue
            overlay = movemap.MoveMapResult(
                width=ctx.world.width, height=ctx.world.height,
                state=list(ctx.state), mp_left=list(ctx.mp_left),
                any_friendly_blocked=False, ret=True)
            for index, marker in enumerate(ctx.state):
                if marker != movemap.STATE_REACHABLE:
                    continue
                tx, ty = ctx.cell_x(index), ctx.cell_y(index)
                walked = movemap.walk(ctx.grid, overlay, unit.x, unit.y,
                                      tx, ty, ctx.delays, ctx.hooks())
                if not walked.ok:
                    continue
                walks += 1
                for cell in walked.path:
                    if ctx.state[cell] not in (movemap.STATE_REACHABLE,
                                               movemap.STATE_WARP):
                        outside.append(f"{path.name} slot {unit.slot} "
                                       f"cell {cell}")
                if walked.blocked != 0:
                    before = (unit.x, unit.y, unit.mp)
                    committed = ai._commit(ctx, unit, index)
                    if (unit.x, unit.y, unit.mp) != before:
                        blocked_moved.append(f"{path.name} slot {unit.slot}")
                    if not committed:
                        blocked_moved.append(f"{path.name} slot {unit.slot} "
                                             f"returned FALSE")
                break
    c.check("commit.sampled", walks > 0, f"{walks} paths reconstructed")
    c.expect("commit.path_inside_highlight", outside[:5], [],
             "docs/23 section 8 measured the same on 4587 paths")
    c.expect("commit.blocked_moves_nothing", blocked_moved[:5], [],
             "blocked != 0 zeroes the step count in the original")


# ---------------------------------------------------------------------------
# The whole turn -- docs/23 section 2
# ---------------------------------------------------------------------------

def check_turns(c: Checker, root: Path, tables: BalanceTables,
                delays: dict[int, int]) -> dict[str, Any]:
    """Every mission's computer turn, run end to end."""
    ran = 0
    worst = 0
    worst_name = ""
    failures: list[str] = []
    orders_seen: dict[int, int] = {}
    counters: dict[str, int] = {}
    refusals: dict[str, int] = {}
    slowest = 0.0
    slowest_name = ""
    for path in mission_paths(root):
        ctx = context_for(path, tables, delays)
        if not aliens_of(ctx):
            continue
        ran += 1
        started = time.perf_counter()
        result = ai.run_turn(ctx, ai.PLAYER_COMPUTER)
        elapsed = time.perf_counter() - started
        if elapsed > slowest:
            slowest, slowest_name = elapsed, path.name
        if not result.ok:
            failures.append(f"{path.name}: {result.reason}")
        if result.sweeps > worst:
            worst, worst_name = result.sweeps, path.name
        for order, count in result.orders_seen.items():
            orders_seen[order] = orders_seen.get(order, 0) + count
        for kind, count in result.counters.items():
            counters[kind] = counters.get(kind, 0) + count
        for reason, count in result.refusals.items():
            refusals[reason] = refusals.get(reason, 0) + count
        left = [u.slot for u in aliens_of(ctx) if u.mp != 0]
        if left:
            failures.append(f"{path.name}: slots {left} still hold points")
    c.expect("turn.missions", ran, 108)
    c.expect("turn.terminal", failures, [],
             f"worst sweep count {worst} on {worst_name}, ceiling "
             f"{ai.TURN_SWEEP_CEILING}")
    c.check("turn.sweeps_bounded", worst <= ai.TURN_SWEEP_CEILING,
            f"{worst} <= {ai.TURN_SWEEP_CEILING}")
    c.check("turn.everyone_spent", not failures,
            "the final sweep zeroes every live unit that still had points")
    c.check("turn.something_happened",
            counters.get("move", 0) > 0 and counters.get("fire", 0) > 0,
            f"{counters.get('move', 0)} moves and {counters.get('fire', 0)} "
            f"shots across the corpus")
    LOG.info("slowest turn: %s at %.3f s", slowest_name, slowest)
    return {"orders": orders_seen, "counters": counters,
            "refusals": refusals, "slowest": slowest,
            "slowest_name": slowest_name}


# ---------------------------------------------------------------------------
# All eleven order arms
# ---------------------------------------------------------------------------

def check_orders(c: Checker, root: Path, tables: BalanceTables,
                 delays: dict[int, int], seen: dict[int, int]) -> None:
    """Ten arms from shipped data, and one from a scene built for it.

    Order 3 ``Move (Group)`` is carried by no shipped unit as a primary order,
    so it is reached the way ``docs/94`` reached reaction fire: by building the
    situation the corpus does not contain.  The scene is a real mission with
    one alien's order byte rewritten, which is the same technique
    ``docs/93`` §11 used natively for the large-unit clearance.
    """
    ctx = context_for(root / "Missions" / "_C_132.lev", tables, delays)
    aliens = aliens_of(ctx)
    c.check("order.scene.aliens", len(aliens) >= 2,
            f"{len(aliens)} aliens on _C_132")
    mover = aliens[0]
    anchor = aliens[1]
    mover.order = ai.ORDER_MOVE_GROUP
    mover.order_param = anchor.group
    mover.order2 = ai.ORDER_BERSERK
    ctx.result = ai.AITurnResult()
    for level in range(ai.MAX_LEVEL + 1):
        ai.run_order(ctx, mover, level)
    c.expect("order.scene.dispatched",
             ctx.result.orders_seen.get(ai.ORDER_MOVE_GROUP, 0),
             ai.MAX_LEVEL + 1,
             "order 3 reached at every level")

    combined = dict(seen)
    combined[ai.ORDER_MOVE_GROUP] = combined.get(ai.ORDER_MOVE_GROUP, 0) \
        + ctx.result.orders_seen.get(ai.ORDER_MOVE_GROUP, 0)
    missing = [o for o in range(ai.ORDER_COUNT) if combined.get(o, 0) == 0]
    c.expect("order.all_eleven_arms", missing, [],
             ", ".join(f"{o} {ai.ORDER_NAMES[o]}: {combined.get(o, 0)}"
                       for o in range(ai.ORDER_COUNT)))

    # The out-of-range default: an order byte above 10 lands on order 8's arm,
    # which is the epilogue and does nothing.
    probe = aliens[0]
    probe.order = 200
    before = (probe.x, probe.y, probe.mp, probe.acted)
    ai.run_order(ctx, probe, 0)
    c.expect("order.above_ten_is_inert",
             (probe.x, probe.y, probe.mp, probe.acted), before,
             "values above 10 fall to the same arm as order 8")


# ---------------------------------------------------------------------------
# The three tie-breaks a remake gets wrong silently
# ---------------------------------------------------------------------------

def check_ties(c: Checker, root: Path, tables: BalanceTables,
               delays: dict[int, int]) -> None:
    ctx = context_for(root / "Missions" / "_C_140.lev", tables, delays)

    # 1. `s >= bestScore` -- the later cell wins a target tie.
    ai.reset_overlay(ctx)
    first = ctx.index(1, 1)
    second = ctx.index(5, 5)
    ctx.state[first] = ai.TARGET_MARKER_MAX
    ctx.state[second] = ai.TARGET_MARKER_MAX
    best, score, _ = ai.select_target(ctx, ai.FIRE_ANY, 0)
    c.expect("tie.target_later_cell_wins", best, second,
             f"two cells at marker {score}; the row-major later one is chosen")

    # 2. `v >= best` -- the later direction wins a path tie.  Two neighbours of
    # the source hold the same movement points, and directions 0..7 are
    # evaluated in order, so the *higher* direction index must be the step.
    width, height = ctx.world.width, ctx.world.height
    flat = movemap.Grid(width=width, height=height,
                        heights=[0] * (width * height),
                        field_types=[1] * (width * height),
                        action_points=[0] * (width * height))
    state = [movemap.STATE_NONE] * (width * height)
    mp_left = [0] * (width * height)
    for x in range(4):
        for y in range(4):
            state[y * width + x] = movemap.STATE_REACHABLE
            mp_left[y * width + x] = 8 - max(x, y)
    overlay = movemap.MoveMapResult(width=width, height=height, state=state,
                                    mp_left=mp_left,
                                    any_friendly_blocked=False, ret=True)
    empty = movemap.MoveMapHooks()
    walked = movemap.walk(flat, overlay, 0, 0, 2, 2, {1: 0, 0: 0}, empty)
    c.check("tie.walk_reconstructs", walked.ok, walked.reason or "ok")

    # A tie of its own: from (1,1) the two orthogonal neighbours (0,1) and
    # (1,0) carry the same movement points, and the diagonal to (0,0) is
    # refused because the corner check needs both components enterable and
    # (0,1) is a Wall.  Directions run 0…7 and acceptance is `v >= best`, so
    # direction 2 -- (0,-1), reaching (1,0) -- must beat direction 1's (0,1).
    tie_types = [1] * (width * height)
    tie_types[1 * width + 0] = 2
    tie_grid = movemap.Grid(width=width, height=height,
                            heights=[0] * (width * height),
                            field_types=tie_types,
                            action_points=[0] * (width * height))
    tie_state = [movemap.STATE_NONE] * (width * height)
    tie_mp = [0] * (width * height)
    for index, value in ((0, 9), (1, 5), (width, 5), (width + 1, 4)):
        tie_state[index] = movemap.STATE_REACHABLE
        tie_mp[index] = value
    tie_overlay = movemap.MoveMapResult(
        width=width, height=height, state=tie_state, mp_left=tie_mp,
        any_friendly_blocked=False, ret=True)
    tied = movemap.walk(tie_grid, tie_overlay, 0, 0, 1, 1,
                        {1: 0, 2: movemap.DELAY_IMPASSABLE}, empty)
    c.check("tie.walk_tied_reconstructs", tied.ok, tied.reason or "ok")
    c.expect("tie.walk_later_direction_wins", tied.path,
             [width + 1, 1, 0],
             "direction 2 reaches (1,0); direction 1's (0,1) scored the same "
             "and was overwritten")

    # 3. The slot sweep is 0…199 and in order.
    scene = context_for(root / "Missions" / "_C_132.lev", tables, delays)
    aliens = aliens_of(scene)
    result = ai.run_turn(scene, ai.PLAYER_COMPUTER)
    acting = [e.slot for e in result.events if e.slot >= 0]
    ends = [e.slot for e in result.events
            if e.kind == "end_unit_turn" and e.note == ai.CLOSING_SWEEP]
    c.check("tie.sweep_has_events", bool(acting), f"{len(acting)} events")
    c.expect("tie.final_sweep_in_slot_order", ends, sorted(ends),
             "the closing pass walks the 200 slots in order")
    handled = sorted({e.slot for e in result.events
                      if e.kind == "end_unit_turn"
                      and e.note != ai.CLOSING_SWEEP})
    c.expect("tie.final_sweep_is_disjoint",
             sorted(set(ends) & set(handled)), [],
             f"{len(handled)} units were ended inside a handler and so had no "
             f"points left for the closing pass to find")
    c.expect("tie.final_sweep_covers_the_rest",
             sorted(set(ends) | set(handled)),
             sorted(u.slot for u in aliens),
             "between them the two account for every live alien exactly once")


# ---------------------------------------------------------------------------
# Cases for the GDScript side
# ---------------------------------------------------------------------------

def emit_cases(root: Path, out: Path, tables: BalanceTables,
               delays: dict[int, int], missions: list[str]) -> int:
    """One document per mission: the world in, the event stream out.

    The **arguments** are compared and not only the event names -- ``docs/94``
    §8 records what the other choice cost.
    """
    cases: list[dict[str, Any]] = []
    for name in missions:
        path = root / "Missions" / f"{name}.lev"
        if not path.exists():
            LOG.error("no such mission: %s", path)
            return 1
        ctx = context_for(path, tables, delays)
        before = [_unit_case(u) for u in
                  (ctx.world.units[s] for s in sorted(ctx.world.units))]
        result = ai.run_turn(ctx, ai.PLAYER_COMPUTER)
        after = [_unit_case(u) for u in
                 (ctx.world.units[s] for s in sorted(ctx.world.units))]
        events = [{k: e[k] for k in
                   ("kind", "slot", "x", "y", "tx", "ty", "detail", "note")}
                  for e in result.to_dict()["events"]]
        cases.append({
            "mission": name,
            "seed": 1.0,
            "units_before": before,
            "units_after": after,
            # The **arguments**, not only the names: docs/94 §8 records what
            # comparing event names alone cost the last time.  The nested
            # payloads are deliberately not here -- an `AttackResult` is
            # already diffed by `test_combat_native.gd`, and carrying it twice
            # would make this fixture a copy of that one.
            "events": events,
            "sweeps": result.sweeps,
            "counters": result.counters,
            "orders_seen": {str(k): v for k, v in
                            sorted(result.orders_seen.items())},
            "seed_after": result.seed_after,
        })
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"schema": CASES_SCHEMA, "cases": cases},
                              indent=1, sort_keys=True))
    print(f"wrote {out} -- {len(cases)} case(s)")
    return 0


def _unit_case(unit: combatmod.CombatUnit) -> dict[str, Any]:
    """One unit record, complete enough to **rebuild** it on the other side.

    The GDScript suite applies this over the world it loaded from the cache
    before it runs anything, so the two implementations start from bit-identical
    rosters rather than from two loaders that agree by coincidence.  Everything
    ``inclib.ai`` reads or writes is here; nothing that is presentation is.
    """
    return {
        "slot": unit.slot, "type_id": unit.type_id, "player": unit.player,
        "x": unit.x, "y": unit.y, "hp": unit.hp, "mp": unit.mp,
        "fp": unit.fp, "facing": unit.facing, "acted": unit.acted,
        "action_state": unit.action_state, "heat": unit.heat,
        "ammo": unit.ammo, "malfunction": unit.malfunction,
        "absorber": unit.absorber, "visibility": unit.visibility,
        "armour_front": unit.armour_front, "armour_rear": unit.armour_rear,
        "order": unit.order, "order_param": unit.order_param,
        "order2": unit.order2, "order2_param": unit.order2_param,
        "group": unit.group, "weapon": unit.weapon, "ticket": unit.ticket,
        "walked": unit.walked, "turn_start_x": unit.turn_start_x,
        "turn_start_y": unit.turn_start_y,
        "equipment": sorted(unit.equipment_ids),
        "skills": list(unit.skills),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _require_corpus(root: Path) -> str | None:
    if not root.is_dir():
        return f"{root} is not a directory"
    if not (root / "DATA" / "Info.lcl").is_file():
        return f"{root}/DATA/Info.lcl is missing"
    if not mission_paths(root):
        return f"{root} holds no .lev files"
    return None


def run_check(root: Path) -> int:
    problem = _require_corpus(root)
    if problem:
        LOG.error("%s", problem)
        return 1
    tables = load_info_file(root / "DATA" / "Info.lcl")
    delays = delays_of(tables)
    c = Checker()
    census = check_census(c, root, tables, delays)
    check_horizon(c, root, tables, delays)
    check_immobile(c, root, tables, delays)
    check_targets(c, root, tables, delays)
    check_bands(c, root, tables, delays)
    check_spores(c, root, tables, delays)
    check_approach(c, root, tables, delays)
    check_shot_reasons(c, root, tables, delays)
    check_fire(c, root, tables, delays)
    check_commit(c, root, tables, delays)
    turns = check_turns(c, root, tables, delays)
    check_orders(c, root, tables, delays, turns["orders"])
    check_ties(c, root, tables, delays)
    LOG.info("census: %s", census["aliens"])
    return c.report()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", metavar="ROOT",
                        help="run every check against a game directory")
    parser.add_argument("--emit-cases", metavar="PATH",
                        help="write the GDScript case document")
    parser.add_argument("--root", default="gog_incubation",
                        help="game directory for --emit-cases")
    parser.add_argument("--missions", default="_C_140,_C_132",
                        help="comma-separated missions for --emit-cases")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING,
                        format="%(levelname)s %(message)s")
    if args.emit_cases:
        root = Path(args.root)
        problem = _require_corpus(root)
        if problem:
            LOG.error("%s", problem)
            return 1
        tables = load_info_file(root / "DATA" / "Info.lcl")
        return emit_cases(root, Path(args.emit_cases), tables,
                          delays_of(tables), args.missions.split(","))
    if args.check:
        return run_check(Path(args.check))
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
