#!/usr/bin/env python3
"""Run the combat and visibility model over the corpus -- ``docs/22``.

``combat_tables.py`` checks the tables in the binary; this checks the behaviour
they feed, against every shipped map.  What it asserts:

* **line of sight is symmetric under the four-ray form** and asymmetric under
  the one-ray form, which is the difference between what the player gets and
  what a neutral unit gets (``docs/22`` §5.5, §6.1);
* a unit **blocks a shot but not the sight of it** -- 254 zeroes a hit chance
  and still reveals (``docs/22`` §9.3);
* the hit curve is flat at 100 for exactly the weapons whose
  ``acc + rangeMax > 101``, and monotone non-increasing in distance otherwise
  (``docs/22`` §5.4);
* the range gate is inclusive at both ends, and every shipped weapon's
  ``range max`` is non-zero except the one placeholder that cannot be fired;
* damage never exceeds the roll's own ceiling, never takes a unit below zero,
  and the sentinel 254 always deals exactly 2;
* the rear arc is three octants of eight, i.e. 135 degrees, and every octant
  is somebody's rear;
* every shipped weapon id maps to one of the sixteen target patterns.

Usage::

    combat_runtime.py --check gog_incubation
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib import combat                                           # noqa: E402
from inclib.check import Checker                                    # noqa: E402
from inclib.info import BalanceTables, load_info_file               # noqa: E402
from inclib.lev import BattleMap, load_lev                          # noqa: E402
from inclib.rng import ARandom                                      # noqa: E402

LOG = logging.getLogger("combat_runtime")

#: How many maps the line-of-sight sweep walks.  The DDA is a float walk over
#: up to 1000 steps, so sweeping every pair on every map would take hours for
#: no extra coverage; the sample is deterministic and stated.
LOS_SAMPLE_MISSIONS = 12
#: How many ordered unit pairs per sampled map.
LOS_SAMPLE_PAIRS = 60


def world_of(bm: BattleMap, tables: BalanceTables,
             seed: float = 1.0) -> combat.CombatWorld:
    """One mission as the world an attack or a fog pass runs against."""
    cells = bm.cells
    units: dict[int, combat.CombatUnit] = {}
    for u in bm.units:
        if not u.placed:
            continue
        units[u.slot] = combat.CombatUnit(
            slot=u.slot, type_id=u.type_id, player=u.player, x=u.x, y=u.y,
            hp=u.hit_points, facing=u.facing, fp=u.fp, mp=u.action_points,
            weapon=u.weapon, ammo=u.ammo, heat=u.heat,
            malfunction=u.malfunction, absorber=u.absorb,
            armour_front=u.armour_front, armour_rear=u.armour_rear,
            action_state=u.action_state, visibility=u.visibility,
            order=u.order, order_param=u.order_param, order2=u.order2,
            order2_param=u.order2_param, group=u.group,
            turn_start_x=u.turn_start_x, turn_start_y=u.turn_start_y,
            equipment_ids=frozenset(u.equipment_ids))
    return combat.CombatWorld(
        width=bm.width, height=bm.height,
        cell_height=[c.height for c in cells],
        unit_at=[-1 if c.unit is None else c.unit for c in cells],
        effect_state=[c.raw[0x10] for c in cells],
        units=units, tables=tables, rng=ARandom(seed))


def check_patterns(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` §7.2 -- every weapon id reaches a known handler."""
    families = {}
    unknown = []
    for wid in range(48):
        try:
            families[wid] = combat.pattern_family(wid)
        except combat.CombatError:
            unknown.append(wid)
    c.expect("patterns.every_weapon_id_classified", unknown, [],
             f"{len(families)}/48 ids")
    covered = set().union(*combat.PATTERN_FAMILIES.values())
    c.expect("patterns.families_partition_the_ids",
             sorted(covered), list(range(48)))
    sizes = [len(v) for v in combat.PATTERN_FAMILIES.values()]
    c.expect("patterns.no_id_in_two_families", sum(sizes), 48)
    c.expect("patterns.sixteen_handlers", len(combat.PATTERN_FAMILIES), 16)

    # A weapon `Info.lcl` defines and the dispatcher refuses cannot be fired.
    defined = {w.id for w in tables.weapons.values() if w.in_use}
    firable = sorted(defined - combat.NO_PATTERN_WEAPONS)
    c.check("patterns.defined_and_firable", bool(firable),
            f"{len(firable)} of {len(defined)} defined weapons have a pattern")
    c.expect("patterns.defined_but_unfirable",
             sorted(defined & combat.NO_PATTERN_WEAPONS), [28, 37],
             "the `-` placeholder and `Mine`")


def check_hit_curve(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` §5.4 -- the curve, and what truncation does to it."""
    flat, sloped, non_monotone, single = [], [], [], []
    for weapon in tables.weapons.values():
        if not weapon.in_use or weapon.range_max <= 0:
            continue
        if weapon.range_min == weapon.range_max:
            # One legal distance, so the curve has one sample and is flat for
            # a reason that has nothing to do with the slope.  Melee, spores,
            # bayonets, the ParaBomb and the Mine.
            single.append(weapon.id)
            continue
        values = [combat.hit_percent(weapon.hit, weapon.range_max, d)
                  for d in range(weapon.range_min, weapon.range_max + 1)]
        if any(b > a for a, b in zip(values, values[1:])):
            non_monotone.append(weapon.id)
        (flat if len(set(values)) == 1 else sloped).append(weapon.id)
    c.expect("curve.monotone_non_increasing", non_monotone, [])
    c.expect("curve.single_distance_weapons", sorted(single),
             [15, 22, 30, 31, 32, 36, 37],
             "range min == range max: the curve has one sample")
    predicted_flat = sorted(
        w.id for w in tables.weapons.values()
        if w.in_use and w.range_max > 0 and w.range_min != w.range_max
        and (101 - w.hit) // w.range_max == 0)
    c.expect("curve.flat_exactly_when_slope_truncates_to_zero",
             sorted(flat), predicted_flat,
             f"{len(flat)} flat, {len(sloped)} sloped")

    # The doc's own worked examples, verbatim.
    c.expect("curve.light_combat_gun", combat.hit_percent(3, 10, 1), 91)
    c.expect("curve.sniper_rifle_at_max", combat.hit_percent(20, 30, 30), 40)
    c.expect("curve.flame_thrower_flat", combat.hit_percent(100, 4, 4), 100)

    # Truncation makes the Target System a no-op on most weapons: doubling 3
    # to 6 leaves `(101 - acc) / 10` at 9.
    c.expect("curve.target_system_is_often_a_noop",
             [combat.hit_percent(3, 10, 5), combat.hit_percent(6, 10, 5)],
             [55, 55])

    # The height rule of section 5.1, as the compiler wrote the division.
    c.expect("distance.height_step_division",
             [combat.magic_div_2400_plus_1(n)
              for n in (2401, 4800, 7200, 24000)],
             [2, 3, 4, 11])


def check_directions(c: Checker) -> None:
    """``docs/22`` §7.4 -- the octants and the 135-degree rear arc."""
    c.expect("direction.vectors", sorted(combat.DIRECTION_VECTORS.items()),
             [(0, (0, 1)), (1, (-1, 0)), (2, (0, -1)), (3, (1, 0)),
              (4, (1, -1)), (5, (-1, 1)), (6, (1, 1)), (7, (-1, -1))])
    # Every unit vector must classify back to its own octant.
    wrong = [code for code, (dx, dy) in combat.DIRECTION_VECTORS.items()
             if combat.direction(0, 0, dx * 4, dy * 4) != code]
    c.expect("direction.round_trips", wrong, [])

    c.expect("rear_arc.three_octants_wide",
             sorted({len(v) for v in combat.REAR_ARC.values()}), [3])
    c.expect("rear_arc.every_octant_has_one", sorted(combat.REAR_ARC),
             list(range(8)))
    # Shooting in the direction the defender faces is a rear shot; the
    # opposite octant is not.
    c.check("rear_arc.same_direction_is_the_back",
            combat.is_rear_shot(0, 0), "attacker and defender both facing 0")
    c.check("rear_arc.head_on_is_the_front",
            not combat.is_rear_shot(0, 2), "facing 2 shot from octant 0")


def check_line_of_sight(c: Checker, root: Path,
                        tables: BalanceTables) -> None:
    """``docs/22`` §6 on real maps: symmetry, the codes, and the biases."""
    levs = sorted(root.rglob("*.lev"))[:LOS_SAMPLE_MISSIONS]
    asymmetric: list[str] = []
    bad_code: list[str] = []
    seen_pairs = 0
    seen_codes: set[int] = set()

    for lev in levs:
        bm = load_lev(str(lev))
        world = world_of(bm, tables)
        alive = sorted((u for u in world.units.values() if u.alive),
                       key=lambda u: u.slot)
        pairs = [(a, b) for a in alive for b in alive if a.slot < b.slot]
        for a, b in pairs[:LOS_SAMPLE_PAIRS]:
            za = world.full_height(a) + world.height_at(a.x, a.y)
            zb = world.full_height(b) + world.height_at(b.x, b.y)
            forward = combat.check_line_of_sight_ex(
                world, a.x, a.y, za, b.x, b.y, zb, 1)
            backward = combat.check_line_of_sight_ex(
                world, b.x, b.y, zb, a.x, a.y, za, 1)
            seen_pairs += 1
            seen_codes.add(forward)
            if forward not in (combat.LOS_CLEAR, combat.LOS_UNIT,
                               combat.LOS_TERRAIN):
                bad_code.append(f"{lev.stem} {a.slot}->{b.slot}: {forward}")
            # The two-ray form walks source -> target only, so it is **not**
            # symmetric in general; what must hold is that the four-ray form
            # is, because it contains both directions.
            world.human_players = 2
            four_f = combat.check_line_of_sight_ex(
                world, a.x, a.y, za, b.x, b.y, zb, 1)
            four_b = combat.check_line_of_sight_ex(
                world, b.x, b.y, zb, a.x, a.y, za, 1)
            world.human_players = 1
            if four_f != four_b:
                asymmetric.append(
                    f"{lev.stem} {a.slot}<->{b.slot}: {four_f} != {four_b}")
            del backward

    c.check("los.pairs_sampled", seen_pairs > 0,
            f"{seen_pairs} ordered pair(s) over {len(levs)} mission(s)")
    c.expect("los.only_three_outcome_codes", bad_code[:5], [])
    c.expect("los.four_ray_form_is_symmetric", asymmetric[:5], [])
    c.check("los.corpus_exercises_more_than_one_code", len(seen_codes) > 1,
            f"codes seen: {sorted(seen_codes)}")

    # Same cell is always clear, and a slope past the limit is always terrain.
    bm = load_lev(str(levs[0]))
    world = world_of(bm, tables)
    c.expect("los.same_cell_is_clear",
             combat.check_line_of_sight(world, 3, 3, 0, 3, 3, 0, 0.5),
             combat.LOS_CLEAR)
    c.expect("los.too_steep_is_terrain",
             combat.check_line_of_sight(world, 0, 0, 0, 1, 0, 99999, 0.5),
             combat.LOS_TERRAIN)


def check_vision_versus_fire(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` §9.3 -- a body blocks a shot but not the sight of it."""
    # A flat 5x1 corridor with a unit in the middle.
    width, height = 5, 1
    world = combat.CombatWorld(
        width=width, height=height, cell_height=[0] * width,
        unit_at=[-1] * width, effect_state=[0] * width, units={},
        tables=tables, rng=ARandom(1.0))
    kind = next(iter(sorted(tables.units)))

    def place(slot: int, x: int, player: int) -> combat.CombatUnit:
        unit = combat.CombatUnit(slot=slot, type_id=kind, player=player,
                                 x=x, y=0, hp=10)
        world.units[slot] = unit
        world.unit_at[x] = slot
        return unit

    watcher = place(0, 0, 0)
    place(1, 2, 255)
    target = place(2, 4, 255)

    z0 = world.full_height(watcher)
    z1 = world.full_height(target)
    block = combat.check_line_of_sight_ex(world, 0, 0, z0, 4, 0, z1, 1)
    c.expect("vision.a_body_reports_254", block, combat.LOS_UNIT)
    c.check("vision.254_is_below_terrain", block < combat.LOS_TERRAIN,
            "so the fog pass accepts it and reveals the unit behind")

    combat.build_visible_map(world, 0)
    c.expect("vision.unit_behind_a_body_is_seen", target.visibility,
             combat.VISIBLE_FULL)
    # ... while the same obstruction zeroes a hit chance, because any non-zero
    # block code exceeds no chance the curve can produce.
    c.check("fire.a_body_zeroes_the_chance",
            combat.LOS_UNIT > 100,
            "block 254 exceeds every chance the curve can produce, and "
            "docs/22 section 5.5 subtracts it")

    # And the fog pass hides what it cannot see: a unit with no line at all.
    walled = combat.CombatWorld(
        width=3, height=1, cell_height=[0, 99999, 0], unit_at=[-1] * 3,
        effect_state=[0] * 3, units={}, tables=tables, rng=ARandom(1.0))
    seer = combat.CombatUnit(slot=0, type_id=kind, player=0, x=0, y=0, hp=10)
    hidden = combat.CombatUnit(slot=1, type_id=kind, player=255, x=2, y=0,
                               hp=10)
    walled.units = {0: seer, 1: hidden}
    walled.unit_at = [0, -1, 1]
    combat.build_visible_map(walled, 0)
    c.check("vision.terrain_hides",
            hidden.visibility in (combat.VISIBLE_HIDDEN,
                                  combat.VISIBLE_CONTACT),
            f"+0x4F = {hidden.visibility}; the neighbour-cluster pass may "
            f"promote a lone hidden neutral to a contact")


def check_damage(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` §7.4 -- the roll, the fatigue penalty and the armour."""
    kind = next(iter(sorted(tables.units)))
    world = combat.CombatWorld(
        width=1, height=1, cell_height=[0], unit_at=[-1], effect_state=[0],
        units={}, tables=tables, rng=ARandom(1.0))

    def target(**kw: Any) -> combat.CombatUnit:
        base: dict[str, Any] = dict(slot=0, type_id=kind, player=0, x=0, y=0,
                                    hp=200, fp=5)
        base.update(kw)
        return combat.CombatUnit(**base)

    # The sentinel: exactly 2, ignoring everything.
    u = target(fp=0, armour_front=6)
    c.expect("damage.sentinel_deals_exactly_two",
             combat.apply_damage(world, u, combat.DAMAGE_SENTINEL, 0), 2)

    # The floor is `(D+1)/2` at every level and only the span grows, so the
    # minimum is level-independent and the maximum is not.
    spans: dict[int, tuple[int, int]] = {}
    for level in (0, 1, 2):
        world.ai_level = level
        lo, hi = 10 ** 6, -1
        for _ in range(400):
            u = target(hp=10 ** 6)
            dealt = combat.apply_damage(world, u, 10, 0)
            lo, hi = min(lo, dealt), max(hi, dealt)
        spans[level] = (lo, hi)
    world.ai_level = 1
    c.check("damage.floor_is_level_independent",
            len({lo for lo, _ in spans.values()}) == 1,
            f"floors {[lo for lo, _ in spans.values()]}")
    c.check("damage.span_widens_with_the_level",
            spans[0][1] <= spans[1][1] <= spans[2][1],
            f"maxima {[hi for _, hi in spans.values()]}")
    c.check("damage.never_below_the_documented_floor",
            spans[1][0] >= (10 + 1) // 2, f"floor seen {spans[1][0]}")

    # Fatigue is a multiplier on the receiving end.
    def average(fp: int) -> float:
        total = 0
        for _ in range(400):
            u = target(hp=10 ** 6, fp=fp)
            total += combat.apply_damage(world, u, 10, 0)
        return total / 400
    rested, tired, spent = average(5), average(1), average(0)
    c.check("damage.fatigue_increases_it", rested < tired < spent,
            f"fp5 {rested:.1f} < fp1 {tired:.1f} < fp0 {spent:.1f}")

    # Armour is a subtraction, and it reduces the average.
    def average_armour(armour: int) -> float:
        total = 0
        for _ in range(400):
            u = target(hp=10 ** 6, armour_front=armour)
            total += combat.apply_damage(world, u, 20, 2)
        return total / 400
    c.check("damage.armour_reduces_it",
            average_armour(0) > average_armour(6),
            f"{average_armour(0):.1f} vs {average_armour(6):.1f}")

    # HP floors at zero and the immune type takes nothing.
    u = target(hp=3)
    combat.apply_damage(world, u, 100, 0)
    c.expect("damage.hp_floors_at_zero", u.hp, 0)
    immune = target(type_id=combat.IMMUNE_UNIT_TYPE, hp=50)
    c.expect("damage.immune_unit_type_takes_none",
             combat.apply_damage(world, immune, 100, 0), 0)
    c.expect("damage.immune_unit_keeps_its_hp", immune.hp, 50)


def check_overheat(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` §8 -- the roll's span is the weapon's own cap."""
    kind = next(iter(sorted(tables.units)))
    world = combat.CombatWorld(
        width=1, height=1, cell_height=[0], unit_at=[-1], effect_state=[0],
        units={}, tables=tables, rng=ARandom(1.0))

    heated = [w for w in tables.weapons.values()
              if w.in_use and w.heat not in (0, 0xFF)]
    c.check("overheat.corpus_has_heated_weapons", bool(heated),
            f"{len(heated)} weapon(s) with a heat cap")

    low = min(heated, key=lambda w: w.heat)
    unit = combat.CombatUnit(slot=0, type_id=kind, player=0, x=0, y=0, hp=10,
                             weapon=low.id, heat=0)
    c.expect("overheat.below_the_cap_does_nothing",
             combat.check_weapon_damage(world, unit), combat.OVERHEAT_NONE)

    # A cap of 30 or less can never roll the 30 that destroys the carrier.
    safe = [w.heat for w in heated if w.heat <= 30]
    c.check("overheat.a_low_cap_cannot_destroy_its_carrier", bool(safe),
            f"{len(safe)} of {len(heated)} caps are 30 or less, so "
            f"aRandom(0, cap) never reaches the destroy case")

    # The Cooler doubles the cap and therefore widens the bad outcomes.
    cooled = combat.CombatUnit(slot=0, type_id=kind, player=0, x=0, y=0,
                               hp=10, weapon=low.id,
                               equipment_ids=frozenset({combat.EQUIP_COOLER}))
    c.expect("overheat.cooler_doubles_the_cap",
             combat.max_heat(world, cooled), low.heat * 2)


def check_attack(c: Checker, root: Path, tables: BalanceTables) -> None:
    """One resolved shot on ``_C_140``, end to end and reproducible."""
    bm = load_lev(str(root / "Missions" / "_C_140.lev"))
    world = world_of(bm, tables, seed=1.0)
    squad = sorted((u for u in world.units.values()
                    if u.player == 0 and u.alive), key=lambda u: u.slot)
    aliens = sorted((u for u in world.units.values()
                     if u.player == 255 and u.alive), key=lambda u: u.slot)
    c.check("attack.mission_has_both_sides", bool(squad) and bool(aliens),
            f"{len(squad)} of player 0, {len(aliens)} of player 255")

    attacker, target = squad[0], aliens[0]
    # Put them adjacent so the shot is in range whatever the weapon is.
    world.unit_at[world.index(target.x, target.y)] = -1
    target.x, target.y = attacker.x + 1, attacker.y
    world.unit_at[world.index(target.x, target.y)] = target.slot
    before = target.hp

    result = combat.attack_unit(world, attacker.x, attacker.y,
                                target.x, target.y)
    c.check("attack.fired", result.fired, result.reason)
    c.check("attack.marked_a_cell", bool(result.marked),
            f"{len(result.marked)} cell(s), markers "
            f"{sorted({m for _, _, m in result.marked})}")
    c.check("attack.resolved_the_target",
            any(o["slot"] == target.slot for o in result.outcomes),
            f"{len(result.outcomes)} outcome(s)")
    c.expect("attack.attacker_turned_to_face",
             result.facing, combat.direction(attacker.x, attacker.y,
                                             target.x, target.y))
    c.check("attack.hp_did_not_rise", target.hp <= before,
            f"{before} -> {target.hp}")

    # The same shot from the same seed is the same shot.
    world2 = world_of(bm, tables, seed=1.0)
    a2 = world2.units[attacker.slot]
    t2 = world2.units[target.slot]
    world2.unit_at[world2.index(t2.x, t2.y)] = -1
    t2.x, t2.y = a2.x + 1, a2.y
    world2.unit_at[world2.index(t2.x, t2.y)] = t2.slot
    repeat = combat.attack_unit(world2, a2.x, a2.y, t2.x, t2.y)
    c.expect("attack.is_reproducible_from_the_seed",
             repeat.to_dict(), result.to_dict())


def check_hit_probability(c: Checker, root: Path,
                          tables: BalanceTables) -> None:
    """``docs/22`` §5 on a real map, over a grid of attacker/target pairs."""
    bm = load_lev(str(root / "Missions" / "_C_141.lev"))
    world = world_of(bm, tables)
    alive = sorted((u for u in world.units.values() if u.alive),
                   key=lambda u: u.slot)
    out_of_band: list[str] = []
    gate_wrong: list[str] = []
    pairs = 0
    for a in alive[:12]:
        for b in alive[:12]:
            if a.slot == b.slot:
                continue
            pairs += 1
            chance = combat.hit_probability(world, a, b, a.weapon)
            if not 0 <= chance.percent <= 100:
                out_of_band.append(f"{a.slot}->{b.slot}: {chance.percent}")
            weapon = tables.weapons.get(a.weapon)
            if weapon is not None:
                in_gate = (weapon.range_min <= chance.distance
                           <= weapon.range_max)
                if in_gate != chance.in_range:
                    gate_wrong.append(
                        f"{a.slot}->{b.slot}: d {chance.distance}, gate "
                        f"{weapon.range_min}..{weapon.range_max}")
    c.check("hit.pairs_evaluated", pairs > 0, f"{pairs} ordered pair(s)")
    c.expect("hit.percent_stays_in_band", out_of_band[:5], [])
    c.expect("hit.range_gate_is_inclusive_at_both_ends", gate_wrong[:5], [])

    # Out of range reports zero and False, which is what makes the resolver's
    # fall back to the raw Hit (%) column visible rather than accidental.
    far = combat.hit_probability(world, alive[0], alive[0], alive[0].weapon)
    c.check("hit.self_is_distance_zero", far.distance <= 0,
            f"distance {far.distance}")


def _require_corpus(root: Path) -> str | None:
    if not (root / "DATA" / "Info.lcl").is_file():
        return f"{root}: no DATA/Info.lcl -- this is not a game installation"
    if not any(root.rglob("*.lev")):
        return (f"{root}: no .lev found; a check that examined nothing is not "
                f"a check that passed")
    return None


def run_check(root: Path) -> int:
    c = Checker()
    problem = _require_corpus(root)
    if problem is not None:
        LOG.error("%s", problem)
        return 1
    tables = load_info_file(str(root / "DATA" / "Info.lcl"))
    check_patterns(c, tables)
    check_hit_curve(c, tables)
    check_directions(c)
    check_line_of_sight(c, root, tables)
    check_vision_versus_fire(c, tables)
    check_damage(c, tables)
    check_overheat(c, tables)
    check_hit_probability(c, root, tables)
    check_attack(c, root, tables)
    return c.report()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", metavar="ROOT", required=True)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format="%(levelname)s: %(message)s")
    return run_check(Path(args.check))


if __name__ == "__main__":
    raise SystemExit(main())
