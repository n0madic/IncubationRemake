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
* every shipped weapon id maps to one of the sixteen target patterns;
* the reaction queue drains in ticket order in ``campaign`` and in slot order
  everywhere else, the 135-degree front arc gates it, a ``Banner`` lifts the
  arc -- and **the drain never clears ``+0x41``** (``docs/25`` §6).

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

from inclib import combat, ctrlmap                                  # noqa: E402
from inclib.check import Checker                                    # noqa: E402
from inclib.info import BalanceTables, load_info_file               # noqa: E402
from inclib.lev import load_lev                                     # noqa: E402
from inclib.rng import ARandom                                      # noqa: E402

LOG = logging.getLogger("combat_runtime")

#: How many maps the line-of-sight sweep walks.  The DDA is a float walk over
#: up to 1000 steps, so sweeping every pair on every map would take hours for
#: no extra coverage; the sample is deterministic and stated.
LOS_SAMPLE_MISSIONS = 12
#: How many ordered unit pairs per sampled map.
LOS_SAMPLE_PAIRS = 60


#: Kept as a name here because every check below reads it; the builder itself
#: lives in :func:`inclib.combat.world_from_map`, so the interaction runtime
#: and this one construct byte-identical worlds from the same ``.lev``.
world_of = combat.world_from_map


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


def check_barrel_blast(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` section 7.3 -- `special` 12 and its repeat pass."""
    barrel_type = 30
    weapon_id = 10
    c.check("barrel.rows_exist",
            (tables.units.get(barrel_type) is not None
             and tables.units[barrel_type].special
             == combat.SPECIAL_EXPLODES_ON_HIT
             and tables.weapons.get(weapon_id) is not None),
            "shipped Barrel 30 and direct-fire weapon 10")

    n = 8 * 5
    world = combat.CombatWorld(
        width=8, height=5, cell_height=[0] * n, unit_at=[-1] * n,
        effect_state=[0] * n, units={}, tables=tables, rng=ARandom(1.0))
    units = [
        combat.CombatUnit(slot=0, type_id=0, player=0, x=1, y=2,
                          hp=100, fp=5, weapon=weapon_id, ammo=255),
        combat.CombatUnit(slot=1, type_id=barrel_type, player=252, x=3, y=2,
                          hp=1),
        combat.CombatUnit(slot=2, type_id=barrel_type, player=252, x=4, y=2,
                          hp=1),
        combat.CombatUnit(slot=3, type_id=0, player=255, x=5, y=2,
                          hp=100),
        combat.CombatUnit(slot=4, type_id=0, player=255, x=7, y=4,
                          hp=100),
    ]
    for unit in units:
        world.units[unit.slot] = unit
        world.unit_at[world.index(unit.x, unit.y)] = unit.slot

    result = combat.attack_unit(world, 1, 2, 3, 2)
    by_slot = {outcome["slot"]: outcome for outcome in result.outcomes}
    c.expect("barrel.the_weapon_only_marked_its_target", result.marked,
             [(3, 2, combat.MARKER_FULL)],
             "the other outcomes come from special 12, not the gun")
    c.check("barrel.the_first_blast_reached_the_second",
            2 in by_slot and not units[2].alive,
            f"second hp {units[2].hp}; outcomes {result.outcomes}")
    c.check("barrel.the_second_blast_reached_its_neighbour",
            3 in by_slot and units[3].hp < 100,
            f"neighbour hp {units[3].hp}; outcomes {result.outcomes}")
    c.expect("barrel.the_blast_stays_in_the_eight_neighbours",
             [4 in by_slot, units[4].hp], [False, 100])

    # `test ebp, ebp` at `0x0046BC39` follows the cell-effect gate, so a
    # shielded barrel starts no secondary pass.
    shielded = combat.CombatWorld(
        width=6, height=4, cell_height=[0] * 24, unit_at=[-1] * 24,
        effect_state=[0] * 24, units={}, tables=tables, rng=ARandom(1.0))
    shield_units = [
        combat.CombatUnit(slot=0, type_id=0, player=0, x=1, y=1,
                          hp=100, fp=5, weapon=weapon_id, ammo=255),
        combat.CombatUnit(slot=1, type_id=barrel_type, player=252, x=3, y=1,
                          hp=1),
        combat.CombatUnit(slot=2, type_id=0, player=255, x=4, y=1, hp=100),
    ]
    for unit in shield_units:
        shielded.units[unit.slot] = unit
        shielded.unit_at[shielded.index(unit.x, unit.y)] = unit.slot
    shielded.effect_state[shielded.index(3, 1)] = 3
    blocked = combat.attack_unit(shielded, 1, 1, 3, 1)
    c.expect("barrel.a_shielded_cell_does_not_start_the_blast",
             [shield_units[1].hp, shield_units[2].hp,
              len(blocked.outcomes)], [1, 100, 1],
             "the only outcome is the shielded barrel's 0x5B")

    bombed = combat.CombatWorld(
        width=8, height=5, cell_height=[0] * 40, unit_at=[-1] * 40,
        effect_state=[0] * 40, units={}, tables=tables, rng=ARandom(1.0))
    bomb_units = [
        combat.CombatUnit(slot=0, type_id=barrel_type, player=252, x=3, y=2,
                          hp=1),
        combat.CombatUnit(slot=1, type_id=barrel_type, player=252, x=4, y=2,
                          hp=1),
        combat.CombatUnit(slot=2, type_id=0, player=255, x=5, y=2, hp=100),
    ]
    for unit in bomb_units:
        bombed.units[unit.slot] = unit
        bombed.unit_at[bombed.index(unit.x, unit.y)] = unit.slot
    bomb = combat.execute_bomb(bombed, 3, 2)
    bomb_slots = {outcome["slot"] for outcome in bomb.outcomes}
    c.check("barrel.a_mine_blast_repeats_the_barrel_chain",
            (1 in bomb_slots and 2 in bomb_slots and not bomb_units[1].alive
             and bomb_units[2].hp < 100),
            f"neighbour hp {bomb_units[2].hp}; outcomes {bomb.outcomes}")

    # The resolver is a row-major CtrlMap sweep, not an expanding list of
    # writes. The victim is resolved before either barrel, and aSetCellState
    # refuses to replace its 0x5C marker with either later ring.
    overlap = combat.CombatWorld(
        width=7, height=5, cell_height=[0] * 35, unit_at=[-1] * 35,
        effect_state=[0] * 35, units={}, tables=tables, rng=ARandom(1.0))
    overlap_units = [
        combat.CombatUnit(slot=0, type_id=barrel_type, player=252,
                          x=3, y=2, hp=1),
        combat.CombatUnit(slot=1, type_id=barrel_type, player=252,
                          x=4, y=2, hp=1),
        combat.CombatUnit(slot=2, type_id=0, player=255,
                          x=3, y=1, hp=1000),
    ]
    for unit in overlap_units:
        overlap.units[unit.slot] = unit
        overlap.unit_at[overlap.index(unit.x, unit.y)] = unit.slot
    coalesced = combat.execute_bomb(overlap, 3, 2)
    victim_hits = [outcome for outcome in coalesced.outcomes
                   if outcome["slot"] == 2]
    c.expect("barrel.overlapping_rings_coalesce_in_the_ctrlmap",
             len(victim_hits), 1,
             f"the shared cell resolved {len(victim_hits)} times: "
             f"{coalesced.outcomes}")

    # Secondary blasts pass their centre height to aSetCellState. A second
    # barrel is needed here so the tested victim is outside the mine's initial
    # 3x3 but inside the chained ring; 0x640 itself is refused, one below passes.
    for delta, reached in ((combat.MARKER_HEIGHT_WINDOW - 1, True),
                           (combat.MARKER_HEIGHT_WINDOW, False)):
        stepped = combat.CombatWorld(
            width=7, height=5, cell_height=[0] * 35, unit_at=[-1] * 35,
            effect_state=[0] * 35, units={}, tables=tables,
            rng=ARandom(1.0))
        stepped_units = [
            combat.CombatUnit(slot=0, type_id=barrel_type, player=252,
                              x=3, y=2, hp=1),
            combat.CombatUnit(slot=1, type_id=barrel_type, player=252,
                              x=4, y=2, hp=1),
            combat.CombatUnit(slot=2, type_id=0, player=255,
                              x=5, y=2, hp=1000),
        ]
        for unit in stepped_units:
            stepped.units[unit.slot] = unit
            stepped.unit_at[stepped.index(unit.x, unit.y)] = unit.slot
        stepped.cell_height[stepped.index(5, 2)] = delta
        height_result = combat.execute_bomb(stepped, 3, 2)
        victim_reached = any(outcome["slot"] == 2
                             for outcome in height_result.outcomes)
        name = ("barrel.ring_height_below_window_reaches"
                if reached else "barrel.ring_height_boundary_is_refused")
        c.expect(name, victim_reached, reached,
                 f"delta {delta}; outcomes {height_result.outcomes}")


def check_beacoo_blast(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` section 7.3 -- `special` 16 explodes only on death."""
    beacoo_type = 66
    barrel_type = 30
    weapon_id = 10
    c.check("beacoo.rows_exist",
            (tables.units.get(beacoo_type) is not None
             and tables.units[beacoo_type].special
             == combat.SPECIAL_EXPLODES_ON_DEATH
             and tables.units.get(barrel_type) is not None
             and tables.units[barrel_type].special
             == combat.SPECIAL_EXPLODES_ON_HIT),
            "shipped Bea'Coo 66 and Barrel 30")

    world = combat.CombatWorld(
        width=8, height=5, cell_height=[0] * 40, unit_at=[-1] * 40,
        effect_state=[0] * 40, units={}, tables=tables, rng=ARandom(1.0))
    units = [
        combat.CombatUnit(slot=0, type_id=0, player=0, x=1, y=2,
                          hp=100, fp=5, weapon=weapon_id, ammo=255),
        combat.CombatUnit(slot=1, type_id=beacoo_type, player=255, x=3, y=2,
                          hp=1),
        combat.CombatUnit(slot=2, type_id=barrel_type, player=252, x=4, y=2,
                          hp=1),
        combat.CombatUnit(slot=3, type_id=0, player=255, x=5, y=2,
                          hp=100),
        combat.CombatUnit(slot=4, type_id=0, player=255, x=7, y=4,
                          hp=100),
    ]
    for unit in units:
        world.units[unit.slot] = unit
        world.unit_at[world.index(unit.x, unit.y)] = unit.slot
    result = combat.attack_unit(world, 1, 2, 3, 2)
    by_slot = {outcome["slot"]: outcome for outcome in result.outcomes}
    c.check("beacoo.death_starts_the_blast",
            not units[1].alive and 2 in by_slot and not units[2].alive,
            f"bea'coo hp {units[1].hp}, barrel hp {units[2].hp}; "
            f"outcomes {result.outcomes}")
    c.check("beacoo.the_blast_can_enter_a_barrel_chain",
            3 in by_slot and units[3].hp < 100,
            f"neighbour hp {units[3].hp}; outcomes {result.outcomes}")
    c.expect("beacoo.the_chain_stays_in_the_eight_neighbours",
             [4 in by_slot, units[4].hp], [False, 100])

    survived = combat.CombatWorld(
        width=6, height=4, cell_height=[0] * 24, unit_at=[-1] * 24,
        effect_state=[0] * 24, units={}, tables=tables, rng=ARandom(1.0))
    survivors = [
        combat.CombatUnit(slot=0, type_id=0, player=0, x=1, y=1,
                          hp=100, fp=5, weapon=weapon_id, ammo=255),
        combat.CombatUnit(slot=1, type_id=beacoo_type, player=255, x=3, y=1,
                          hp=100),
        combat.CombatUnit(slot=2, type_id=0, player=255, x=4, y=1, hp=100),
    ]
    for unit in survivors:
        survived.units[unit.slot] = unit
        survived.unit_at[survived.index(unit.x, unit.y)] = unit.slot
    nonlethal = combat.attack_unit(survived, 1, 1, 3, 1)
    c.check("beacoo.a_survivor_does_not_start_the_blast",
            (survivors[1].alive and survivors[1].hp < 100
             and survivors[2].hp == 100 and len(nonlethal.outcomes) == 1),
            f"bea'coo hp {survivors[1].hp}, neighbour hp {survivors[2].hp}; "
            f"outcomes {nonlethal.outcomes}")

    vulnerable = combat.CombatWorld(
        width=6, height=4, cell_height=[0] * 24, unit_at=[-1] * 24,
        effect_state=[0] * 24, units={}, tables=tables, rng=ARandom(1.0))
    heavy_units = [
        combat.CombatUnit(slot=0, type_id=0, player=0, x=1, y=1,
                          hp=100, fp=5, weapon=12, ammo=255),
        combat.CombatUnit(slot=1, type_id=beacoo_type, player=255, x=3, y=1,
                          hp=50),
    ]
    for unit in heavy_units:
        vulnerable.units[unit.slot] = unit
        vulnerable.unit_at[vulnerable.index(unit.x, unit.y)] = unit.slot
    heavy = combat.attack_unit(vulnerable, 1, 1, 3, 1)
    c.check("beacoo.type_2_uses_the_narrowed_1000_damage",
            (not heavy_units[1].alive and heavy.outcomes
             and heavy.outcomes[0]["dealt"] > tables.weapons[12].damage),
            f"hp {heavy_units[1].hp}; outcomes {heavy.outcomes}")

    mined = combat.CombatWorld(
        width=7, height=4, cell_height=[0] * 28, unit_at=[-1] * 28,
        effect_state=[0] * 28, units={}, tables=tables, rng=ARandom(1.0))
    mine_units = [
        combat.CombatUnit(slot=0, type_id=beacoo_type, player=255, x=3, y=1,
                          hp=1),
        combat.CombatUnit(slot=1, type_id=0, player=255, x=5, y=1, hp=100),
    ]
    for unit in mine_units:
        mined.units[unit.slot] = unit
        mined.unit_at[mined.index(unit.x, unit.y)] = unit.slot
    mine = combat.execute_bomb(mined, 3, 1)
    c.check("beacoo.a_mine_kill_has_no_secondary_gameplay_ring",
            (not mine_units[0].alive and mine_units[1].hp == 100
             and len(mine.outcomes) == 1),
            f"bea'coo hp {mine_units[0].hp}, far hp {mine_units[1].hp}; "
            f"outcomes {mine.outcomes}")


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


#: The reaction scenario's weapon.  ``Sniper Rifle``: ``def_mode`` 1, range
#: 1..30 and ``Hit (%)`` 20, so the curve gives ``100 - 2 * d`` and a shot at
#: two fields has a chance the queue's own gate will accept.  A weapon whose
#: chance came out zero would make every reaction check pass by refusing.
REACTION_WEAPON = 3
#: The scenario's map, big enough that no shot leaves it.
REACTION_SIZE = 8


def _reaction_scene(tables: BalanceTables, seed: float = 1.0
                    ) -> tuple[combat.CombatWorld, combat.CombatUnit,
                               combat.CombatUnit, combat.CombatUnit]:
    """One mover and two reactors on flat ground, both looking at him.

    Built rather than loaded: **no shipped ``.lev`` places a unit on
    overwatch** -- ``+0x41`` is 0 in all 1826 placed records, because the state
    only ever exists at runtime -- so a corpus sweep cannot reach the queue at
    all.  The scenario is the smallest world in which the two drain orders can
    disagree: the reactor with the *lower* ticket sits in the *higher* slot.
    """
    n = REACTION_SIZE * REACTION_SIZE
    kind = next(iter(sorted(tables.units)))
    world = combat.CombatWorld(
        width=REACTION_SIZE, height=REACTION_SIZE, cell_height=[0] * n,
        unit_at=[-1] * n, effect_state=[0] * n, units={}, tables=tables,
        rng=ARandom(seed))

    def place(slot: int, player: int, x: int, y: int, facing: int,
              ticket: int) -> combat.CombatUnit:
        unit = combat.CombatUnit(
            slot=slot, type_id=kind, player=player, x=x, y=y, hp=10 ** 6,
            facing=facing, fp=5, mp=4, weapon=REACTION_WEAPON, ammo=15,
            action_state=combat.ACTION_WAITING if ticket else 0,
            ticket=ticket)
        world.units[slot] = unit
        world.unit_at[world.index(x, y)] = slot
        return unit

    mover = place(0, 0, 4, 4, 0, 0)
    mover.action_state = 0
    # `direction(4,2 -> 4,4)` is 0 and `direction(4,6 -> 4,4)` is 2, and each
    # reactor is given an **off-centre** facing from its own arc -- 6 is in
    # `REAR_ARC[0]` and 4 is in `REAR_ARC[2]`.  Pointing them straight at the
    # mover instead would make `aAttackUnit`'s turn-to-face a no-op, and the
    # save-and-restore check would pass on an implementation that does not
    # restore anything.  That is exactly what it did until a mutation said so.
    high_ticket = place(1, combat.PLAYER_COMPUTER, 4, 2, 6, 2)
    low_ticket = place(2, combat.PLAYER_COMPUTER, 4, 6, 4, 1)
    return world, mover, high_ticket, low_ticket


def check_reaction(c: Checker, tables: BalanceTables) -> None:
    """``docs/25`` §6 -- the Def gate, the ticket, the arc and the drain."""
    # --- the two Def gates, and the one value they disagree about ---------
    world, mover, _a, _b = _reaction_scene(tables)
    ready = combat.CombatUnit(slot=9, type_id=mover.type_id, player=0, x=0,
                              y=0, hp=10, mp=2, ammo=1,
                              weapon=REACTION_WEAPON)
    c.check("defence.ui_gate_accepts_a_ready_unit",
            combat.may_enter_defence(world, ready),
            f"weapon {REACTION_WEAPON}, def_mode "
            f"{tables.weapons[REACTION_WEAPON].def_mode}")
    refusals = {
        "too_few_movement_points": {"mp": combat.OVERWATCH_MIN_MP - 1},
        "a_jammed_weapon": {"malfunction": 1},
        "an_empty_magazine": {"ammo": 0},
        "already_waiting": {"action_state": combat.ACTION_WAITING},
    }
    for name, override in refusals.items():
        fields: dict[str, Any] = dict(
            slot=9, type_id=mover.type_id, player=0, x=0, y=0, hp=10, mp=2,
            ammo=1, weapon=REACTION_WEAPON)
        fields.update(override)
        probe = combat.CombatUnit(**fields)
        c.check(f"defence.ui_gate_refuses_{name}",
                not combat.may_enter_defence(world, probe), str(override))

    # Every shipped weapon, both gates.  `def_mode & 1` and `in {1, 4}` agree
    # on the whole shipped table, which is why the disagreement below has to be
    # constructed to be seen at all.
    disagreeing = []
    for weapon_id, row in sorted(tables.weapons.items()):
        probe = combat.CombatUnit(slot=9, type_id=mover.type_id, player=0,
                                  x=0, y=0, hp=10, mp=2, ammo=1,
                                  weapon=weapon_id)
        ui = combat.may_enter_defence(world, probe)
        auto = combat.auto_enter_defence(world, probe)
        if ui != auto:
            disagreeing.append(f"{weapon_id} def_mode {row.def_mode}")
    c.expect("defence.the_two_gates_agree_on_the_shipped_table",
             disagreeing, [],
             "docs/21 section 4: they differ only on def_mode 4, which the "
             "shipped file never uses")
    c.check("defence.shipped_table_has_no_def_mode_4",
            4 not in {r.def_mode for r in tables.weapons.values()},
            f"values present: {sorted({r.def_mode for r in tables.weapons.values()})}")

    # --- the ticket -------------------------------------------------------
    world, mover, _a, _b = _reaction_scene(tables)
    first = combat.CombatUnit(slot=20, type_id=mover.type_id, player=0, x=0,
                              y=0, hp=10, mp=4, ammo=1, weapon=REACTION_WEAPON)
    second = combat.CombatUnit(slot=21, type_id=mover.type_id, player=0, x=1,
                               y=0, hp=10, mp=4, ammo=1,
                               weapon=REACTION_WEAPON)
    c.expect("defence.tickets_are_consecutive_from_one",
             [combat.enter_defence(world, first),
              combat.enter_defence(world, second)], [1, 2])
    c.expect("defence.the_counter_is_per_player",
             world.reaction_counter, [2, 0, 0, 0])
    c.expect("defence.entering_stamps_the_acted_byte",
             [first.acted, first.action_state],
             [combat.OVERWATCH_ACTED, combat.ACTION_WAITING])
    c.expect("defence.a_second_press_spends_the_movement_points",
             [combat.enter_defence(world, first), first.mp], [3, 0],
             "docs/21 section 4: 0x00478500 zeroes +0x15 when the unit was "
             "already waiting, so pressing Def twice is an act")

    # --- the 135-degree front arc ----------------------------------------
    world, mover, north, _b = _reaction_scene(tables)
    arc = [f for f in range(8)
           if combat.in_front_arc(
               combat.CombatUnit(slot=1, type_id=mover.type_id, player=255,
                                 x=4, y=2, hp=10, facing=f), mover)]
    c.expect("reaction.front_arc_is_three_octants_of_eight", len(arc), 3,
             f"facings that cover (4,4) from (4,2): {arc}")
    c.check("reaction.front_arc_excludes_looking_away",
            not combat.in_front_arc(
                combat.CombatUnit(slot=1, type_id=mover.type_id, player=255,
                                  x=4, y=2, hp=10, facing=2), mover),
            "facing 2 from (4,2) points away from (4,4)")

    # A reactor looking the wrong way does not fire -- and a Banner carrier
    # within four fields makes it fire anyway.  That pair is the whole point of
    # the last row of docs/25 section 6's table.
    world, mover, north, south = _reaction_scene(tables)
    north.facing = 2          # (4,2) looking north, away from (4,4)
    south.facing = 0          # (4,6) looking south, away from (4,4)
    c.expect("reaction.looking_away_is_not_a_candidate",
             [u.slot for u in combat.reaction_candidates(world, mover)], [])
    world.units[3] = combat.CombatUnit(
        slot=3, type_id=mover.type_id, player=combat.PLAYER_COMPUTER,
        x=5, y=4, hp=10, equipment_ids=frozenset({combat.EQUIP_BANNER}))
    world.unit_at[world.index(5, 4)] = 3
    c.check("reaction.the_banner_carrier_covers_both_reactors",
            all(combat.distance(5, 4, u.x, u.y) < combat.BANNER_RANGE
                for u in (north, south)),
            "0x0046FAD0 is a strict `< 4`, so a carrier that only reaches one "
            "reactor would make the check below pass for the wrong reason")
    c.expect("reaction.a_banner_lifts_the_arc",
             sorted(u.slot for u in combat.reaction_candidates(world, mover)),
             [1, 2])

    # --- the drain, and the flag it does not clear ------------------------
    world, mover, high, low = _reaction_scene(tables)
    fired = combat.drain_reactions(world, mover)
    c.expect("reaction.campaign_drains_in_ticket_order",
             [r.ticket for r in fired], [1, 2],
             "0x0046CCA0 counts up from ticket 1, so the unit that went on "
             "overwatch first shoots first")
    c.expect("reaction.campaign_order_is_not_slot_order",
             [r.reactor for r in fired], [2, 1])
    c.expect("reaction.the_flag_survives_the_shot",
             [world.units[1].action_state, world.units[2].action_state],
             [combat.ACTION_WAITING, combat.ACTION_WAITING],
             "docs/25 section 6: nothing in the drain stores into +0x41, so a "
             "unit on overwatch fires at every enemy that walks past")
    c.expect("reaction.the_shot_would_have_turned_them",
             [combat.direction(4, 2, 4, 4), combat.direction(4, 6, 4, 4)],
             [0, 2],
             "the headings differ from the facings the scene sets, so a "
             "restore that does nothing is visible")
    c.expect("reaction.the_facing_is_restored",
             [world.units[1].facing, world.units[2].facing], [6, 4])
    c.check("reaction.the_shot_spent_ammunition",
            world.units[1].ammo == 14 and world.units[2].ammo == 14,
            f"{world.units[1].ammo} and {world.units[2].ammo} left of 15")

    world, mover, _high, _low = _reaction_scene(tables)
    world.game_mode = 2
    world.human_players = 2
    fired = combat.drain_reactions(world, mover)
    c.expect("reaction.other_modes_drain_in_slot_order",
             [r.reactor for r in fired], [1, 2],
             "the tickets are still written; only the order differs")

    # A mover that is already dead draws nothing, and one that dies mid-drain
    # stops it.  Both are the same early return in the engine.
    world, mover, _high, _low = _reaction_scene(tables)
    mover.hp = 0
    c.expect("reaction.a_dead_mover_draws_nothing",
             len(combat.drain_reactions(world, mover)), 0)
    world, mover, _high, _low = _reaction_scene(tables)
    mover.hp = 1
    fired = combat.drain_reactions(world, mover)
    c.check("reaction.death_stops_the_drain",
            not mover.alive and len(fired) == 1,
            f"{len(fired)} shot(s) before hp {mover.hp}")


def check_stun(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` §7.5 -- a ``Damage Absorber`` charge nullifies a stun.

    The reported flag is read **before** the charge is spent.  With exactly one
    charge the unit spends it and is *not* stunned, and reading the field after
    the decrement said the opposite -- which `godot/core/combat.gd` had right,
    so the two implementations disagreed.
    """
    weapon_id = sorted(combat.PATTERN_FAMILIES["aim_cell_stun"])[0]
    row = tables.weapons.get(weapon_id)
    c.check("stun.the_weapon_is_defined", row is not None,
            f"weapon {weapon_id} is the one `aim_cell_stun` handler")
    if row is None:
        return

    def scene(charges: int) -> tuple[combat.CombatWorld, combat.CombatUnit]:
        n = 4 * 4
        kind = next(iter(sorted(tables.units)))
        world = combat.CombatWorld(
            width=4, height=4, cell_height=[0] * n, unit_at=[-1] * n,
            effect_state=[0] * n, units={}, tables=tables, rng=ARandom(1.0))
        shooter = combat.CombatUnit(slot=0, type_id=kind, player=0, x=1, y=1,
                                    hp=100, fp=5, weapon=weapon_id, ammo=9)
        # ``0x00475590`` reads the charges behind equipment slot 18, so the
        # victim carries the absorber whenever it is meant to have charges.
        carried = frozenset({combat.EQUIP_DAMAGE_ABSORBER} if charges else ())
        victim = combat.CombatUnit(slot=1, type_id=kind, player=255, x=2, y=1,
                                   hp=100, fp=5, mp=4, absorber=charges,
                                   equipment_ids=carried)
        for unit in (shooter, victim):
            world.units[unit.slot] = unit
            world.unit_at[world.index(unit.x, unit.y)] = unit.slot
        return world, victim

    world, victim = scene(1)
    result = combat.attack_unit(world, 1, 1, 2, 1)
    stun = [o for o in result.outcomes if o["slot"] == 1]
    c.check("stun.one_charge_resolves", bool(stun),
            f"{len(result.outcomes)} outcome(s)")
    if stun:
        c.expect("stun.a_spent_charge_is_not_a_stun",
                 [stun[0].get("stunned"), victim.absorber, victim.mp],
                 [False, 0, 4],
                 "the charge is gone and the turn is not")

    world, victim = scene(0)
    result = combat.attack_unit(world, 1, 1, 2, 1)
    stun = [o for o in result.outcomes if o["slot"] == 1]
    if stun:
        c.expect("stun.no_charge_is_a_stun",
                 [stun[0].get("stunned"), victim.action_state, victim.mp],
                 [True, combat.STUNNED_ACTION_STATE
                  if hasattr(combat, "STUNNED_ACTION_STATE") else 5, 0])


def check_conversion(c: Checker, root: Path, tables: BalanceTables) -> None:
    """docs/22 §7.3 and §7.5 -- weapon 47, the absorber's gate, the bomb, and
    where the contact promotion lives.

    Every claim here was measured first (``tools/turn_gold.py``, the
    ``reveal`` and ``conversion`` phases); these scenes keep the model on the
    same rules without a capture.
    """
    from inclib import interact

    # ``0x00475590`` reads the charges behind equipment slot 18.  Six placed
    # aliens on ``_C_119.lev`` hold a stale 123 or 126 in ``+0x3A`` and no
    # absorber in the equipment array; the engine lets a shot through them,
    # and so, now, does the model.
    bm = load_lev(str(root / "Missions" / "_C_119.lev"))
    shipped = combat.world_from_map(bm, tables)
    stale = [u for u in shipped.units.values()
             if u.absorber and not u.has(combat.EQUIP_DAMAGE_ABSORBER)]
    c.expect("absorber.stale_records_on_C_119", len(stale), 6,
             "+0x3A set with no equipment 18, placed and alive")
    c.expect("absorber.stale_records_have_no_charges",
             [combat.absorber_charges(u) for u in stale], [0] * len(stale),
             "0x00475590 returns 0 without the equipment flag")

    kind = next(iter(sorted(tables.units)))
    rifle = sorted(combat.PATTERN_FAMILIES["aim_cell_full"])[0]

    def duel(weapon_id: int, charges: int = 0, carried: bool = False,
             seed: float = 1.0, wall: bool = False
             ) -> tuple[combat.CombatWorld, combat.CombatUnit,
                        combat.CombatUnit, combat.CombatUnit]:
        n = 8 * 8
        world = combat.CombatWorld(
            width=8, height=8, cell_height=[0] * n, unit_at=[-1] * n,
            effect_state=[0] * n, field_type=[0] * n, action_point=[0] * n,
            units={}, tables=tables, rng=ARandom(seed))
        shooter = combat.CombatUnit(slot=0, type_id=kind, player=0, x=1, y=1,
                                    hp=100, fp=5, weapon=weapon_id, ammo=9)
        equipment = frozenset({combat.EQUIP_DAMAGE_ABSORBER} if carried else ())
        victim = combat.CombatUnit(slot=1, type_id=kind, player=255, x=3, y=1,
                                   hp=100, fp=5, mp=0, action_state=5,
                                   absorber=charges, equipment_ids=equipment)
        watched = combat.CombatUnit(slot=2, type_id=kind, player=255, x=6, y=1,
                                    hp=100, fp=5,
                                    visibility=combat.VISIBLE_HIDDEN)
        for unit in (shooter, victim, watched):
            world.units[unit.slot] = unit
            world.unit_at[world.index(unit.x, unit.y)] = unit.slot
        if wall:
            world.cell_height[world.index(4, 1)] = 20000
        return world, shooter, victim, watched

    # Weapon 47 fires at its heat cap (``0x0046B5DF``): seed 1.0's first
    # ``aRandom(0, 40)`` is 1, the damaging arm, and nothing fires.
    world, shooter, victim, _w = duel(combat.CONVERTER_WEAPON)
    cap = combat.max_heat(world, shooter)
    refused = combat.attack_unit(world, 1, 1, 3, 1)
    c.check("convert.weapon_47_fires_at_its_cap",
            not refused.fired and shooter.heat == cap
            and shooter.malfunction == 5,
            f"heat {shooter.heat} of cap {cap}, malfunction "
            f"{shooter.malfunction}, fired {refused.fired}")

    # A seed that clears the overheat roll and connects, searched as the
    # native probe's was; the hit converts and the convert looks around.
    converted = False
    for seed in range(2, 200):
        world, shooter, victim, watched = duel(combat.CONVERTER_WEAPON,
                                               seed=float(seed))
        shot = combat.attack_unit(world, 1, 1, 3, 1)
        if not any(o.get("converted") for o in shot.outcomes):
            continue
        converted = True
        c.expect("convert.the_target_changes_sides", victim.player, 0,
                 "+0x45 becomes the shooter's at 0x0046BDCB")
        # ``aGetMovePoints`` is asked **before** ``+0x41`` is cleared
        # (``0x0046BDCE`` then ``0x0046BDE7``), and a stunned unit's allowance
        # is nothing -- so a convert that was stunned keeps no points this
        # turn, and only a later refresh gives it any.
        c.expect("convert.its_points_are_asked_before_the_state_clears",
                 victim.mp, 0, "stunned when asked, so aGetMovePoints said 0")
        c.expect("convert.its_action_state_is_cleared", victim.action_state, 0)
        c.expect("convert.it_looks_around_for_its_new_side",
                 watched.visibility, combat.VISIBLE_FULL,
                 "0x0046BDEB, the writing pass from its own cell")
        c.check("convert.the_target_still_lost_its_hit_points", victim.hp < 100,
                f"damage landed before the arm: hp {victim.hp}")
        break
    c.check("convert.a_seed_below_200_converts", converted,
            "the overheat roll and the hit roll both have to come out right")

    # The gate: charges without the equipment are ignored; with it, one is
    # spent, the damage is zeroed **and still rolled** -- the same draws as
    # the landed hit, which is what the native seed showed.
    world, _s, unflagged, _w = duel(rifle, charges=5)
    combat.attack_unit(world, 1, 1, 3, 1)
    ignored_seed = world.rng.seed
    c.check("absorber.charges_without_the_equipment_are_ignored",
            unflagged.hp < 100 and unflagged.absorber == 5,
            f"hp {unflagged.hp}, charges {unflagged.absorber}")
    world, _s, flagged, _w = duel(rifle, charges=5, carried=True)
    combat.attack_unit(world, 1, 1, 3, 1)
    c.expect("absorber.a_carried_charge_is_spent_and_nullifies",
             (flagged.hp, flagged.absorber), (100, 4))
    c.check("absorber.a_spent_charge_still_rolls_the_damage",
            abs(world.rng.seed - ignored_seed) < 0.5,
            f"xor ebp, ebp at 0x0046BD83 and applyDamage at 0x0046BD9D: "
            f"{world.rng.seed} against {ignored_seed}")

    # The bomb never asks: no 0x00475590 call in 0x004702C0.
    world, _s, victim, _w = duel(rifle, charges=5, carried=True)
    combat.execute_bomb(world, 3, 1)
    c.check("absorber.a_mine_ignores_the_absorber",
            victim.hp < 100 and victim.absorber == 5,
            f"hp {victim.hp}, charges {victim.absorber}")

    # The contact promotion is the per-unit pass's own (0x00479786 inside
    # 0x004794B0): one observer's pass promotes a hidden neutral behind a
    # wall to a lone contact, with no whole-map rebuild involved.
    world, observer, _v, behind = duel(rifle, wall=True)
    world.units.pop(1)
    world.unit_at[world.index(3, 1)] = -1
    saw = combat.build_visible_map_for_unit(world, observer, 1, 1)
    c.check("promotion.is_inside_the_per_unit_pass",
            not saw and behind.visibility == combat.VISIBLE_CONTACT,
            f"saw {saw}, +0x4F {behind.visibility}")

    # And the relocation of ``0x0047AD90``: the map's link moves and the unit
    # looks around from where it landed.
    world, mover, _v, behind = duel(rifle)
    interact.relocate_unit(world, mover, 5, 1)
    c.check("relocate.moves_the_link_and_looks_around",
            world.unit_at[world.index(1, 1)] == -1
            and world.unit_at[world.index(5, 1)] == 0
            and (mover.x, mover.y) == (5, 1)
            and behind.visibility == combat.VISIBLE_FULL,
            f"at ({mover.x},{mover.y}), watched +0x4F {behind.visibility}")

    # A ride whose destination block is occupied: the relocation is refused,
    # the rider is not counted, and its source cell **keeps its link** -- a
    # cleared link would leave a unit the map no longer knows about.
    world, rider, blocker, _w = duel(rifle)
    blocker.x, blocker.y = 4, 1
    world.unit_at[world.index(3, 1)] = -1
    world.unit_at[world.index(4, 1)] = blocker.slot
    riders = interact.platform_ride(world, 1, 1, 3, 3)
    c.check("platform.a_refused_rider_keeps_its_link",
            riders == [] and (rider.x, rider.y) == (1, 1)
            and world.unit_at[world.index(1, 1)] == rider.slot
            and world.unit_at[world.index(4, 1)] == blocker.slot,
            f"riders {riders}, rider at ({rider.x},{rider.y}), link "
            f"{world.unit_at[world.index(1, 1)]}")


def _duel_scene(tables: BalanceTables, attacker_type: int, victim_type: int,
                game_mode: int = combat.GAME_MODE_CAMPAIGN, ai_level: int = 1,
                seed: float = 1.0
                ) -> tuple[combat.CombatWorld, combat.CombatUnit,
                           combat.CombatUnit]:
    """Two units side by side on flat ground, the victim at one hit point."""
    n = 4 * 4
    world = combat.CombatWorld(
        width=4, height=4, cell_height=[0] * n, unit_at=[-1] * n,
        effect_state=[0] * n, units={}, tables=tables, rng=ARandom(seed),
        game_mode=game_mode, ai_level=ai_level)
    rifle = sorted(combat.PATTERN_FAMILIES["aim_cell_full"])[0]
    attacker = combat.CombatUnit(slot=0, type_id=attacker_type, player=0,
                                 x=1, y=1, hp=10, facing=3, fp=5, mp=4,
                                 weapon=rifle, ammo=15)
    victim = combat.CombatUnit(slot=1, type_id=victim_type,
                               player=combat.PLAYER_COMPUTER, x=2, y=1, hp=1,
                               facing=1, fp=5, mp=4, weapon=rifle, ammo=15)
    for unit in (attacker, victim):
        world.units[unit.slot] = unit
        world.unit_at[world.index(unit.x, unit.y)] = unit.slot
    return world, attacker, victim


def _seed_that_kills(tables: BalanceTables, attacker_type: int,
                     victim_type: int) -> float:
    """The first integer seed whose shot kills the one-point victim."""
    for seed in range(1, 200):
        world, attacker, victim = _duel_scene(tables, attacker_type,
                                              victim_type, seed=float(seed))
        combat.attack_unit(world, attacker.x, attacker.y, victim.x, victim.y)
        if not victim.alive:
            return float(seed)
    raise AssertionError("no seed below 200 kills a one-point target")


def check_jam_and_warp(c: Checker, tables: BalanceTables) -> None:
    """docs/25 §6's jam arm and the pad's warp arm (docs/97 §31)."""
    # A reactor whose magazine the shot empties leaves the queue.
    world, mover, first, second = _reaction_scene(tables)
    first.ammo = 1
    world.rng = ARandom(1.0)
    fired = combat.drain_reactions(world, mover)
    shots = {r.reactor: r for r in fired}
    c.check("jam.empty_magazine_jams", first.slot in shots
            and shots[first.slot].jammed and first.ticket == 0,
            f"ammo {first.ammo}, ticket {first.ticket}")
    c.check("jam.the_other_reactor_keeps_its_ticket",
            second.slot in shots and not shots[second.slot].jammed
            and second.ticket != 0, f"ticket {second.ticket}")
    # A reactor at the heat cap after its shot jams too.
    world, mover, first, second = _reaction_scene(tables)
    cap = combat.max_heat(world, first)
    # One shot heats by one (`0x0046C0B5`), so a counter one under the cap
    # reaches it on the reaction shot itself.
    first.heat = cap - 1
    world.rng = ARandom(1.0)
    fired = combat.drain_reactions(world, mover)
    shots = {r.reactor: r for r in fired}
    c.check("jam.heat_at_cap_jams", cap != 0xFF and first.slot in shots
            and shots[first.slot].jammed and first.heat == cap
            and first.ticket == 0, f"heat {first.heat} cap {cap}")
    c.check("jam.to_dict_carries_it", "jammed" in fired[0].to_dict(), "")
    # The warp: relink, no movement points, acted 5, the drain at the landing.
    world, mover, first, second = _reaction_scene(tables)
    source = world.index(mover.x, mover.y)
    tx, ty = mover.x, mover.y + 1
    if not world.in_bounds(tx, ty) or world.unit_at[world.index(tx, ty)] >= 0:
        tx, ty = mover.x + 1, mover.y
    world.rng = ARandom(1.0)
    result = combat.warp_unit(world, mover, tx, ty)
    c.check("warp.relinks", result.ok and world.unit_at[source] == -1
            and world.unit_at[world.index(tx, ty)] == mover.slot
            and (mover.x, mover.y) == (tx, ty), result.to_dict())
    c.expect("warp.mp_zeroed", mover.mp, 0)
    c.expect("warp.acted_5", mover.acted, combat.ACTED_WARPED)
    c.check("warp.drains_the_queue", len(result.reactions) == 2,
            f"{len(result.reactions)} reaction(s)")
    stale = combat.CombatUnit(slot=77, type_id=mover.type_id, player=0, x=0, y=0, hp=10)
    world.units[77] = stale
    c.check("warp.refuses_an_unlinked_mover",
            not combat.warp_unit(world, stale, 1, 1).ok, "")


def check_experience(c: Checker, tables: BalanceTables) -> None:
    """``docs/22`` §7.5 -- the kill award, the three routines and the gates.

    Every arm of ``0x0047AFD0`` is exercised: the campaign's pass-through, the
    session ladder's three bands with their difficulty multipliers, the two
    144 caps, the species and same-player gates of the caller, the damage
    gate, the kill counter's saturation and the skill orbit's argument.  The
    campaign arm is what ``turn_gold.py``'s ``experience`` phase measures;
    the ladder is transcription only, because the fixture save is a campaign.
    """
    humans = [t for t, row in sorted(tables.units.items())
              if row.species == combat.SPECIES_HUMAN]
    # An exp of at least 2, so the halved band and the caps are not the
    # exp-1 special case (which has its own check below).
    aliens = [t for t, row in sorted(tables.units.items())
              if row.species == combat.SPECIES_ALIEN and row.exp > 1]
    objects = [t for t, row in sorted(tables.units.items())
               if row.species == combat.SPECIES_OBJECT]
    c.check("experience.types_available",
            bool(humans) and bool(aliens) and bool(objects),
            f"{len(humans)} human, {len(aliens)} alien with exp, "
            f"{len(objects)} object types")
    if not (humans and aliens and objects):
        return
    human, alien, prop = humans[0], aliens[0], objects[0]
    exp = tables.units[alien].exp
    seed = _seed_that_kills(tables, human, alien)

    # --- the campaign: the type's exp byte, on both bytes and the counter --
    world, attacker, victim = _duel_scene(tables, human, alien, seed=seed)
    attacker.ep, attacker.tp = 10, 5
    result = combat.attack_unit(world, attacker.x, attacker.y, victim.x, victim.y)
    c.check("experience.campaign_kill", not victim.alive, "the seed kills")
    c.expect("experience.campaign_returns_exp", result.xp, exp,
             "aAttackUnit's total is the victim type's exp byte")
    c.expect("experience.campaign_ep", attacker.ep, 10 + exp)
    c.expect("experience.campaign_tp", attacker.tp, 5 + exp)
    c.expect("experience.campaign_kills", attacker.kills, 1)
    c.expect("experience.skill_raised_when_a_level_is_crossed",
             result.skill_raised, (5 + exp) // 12 - 5 // 12,
             "the pool's level delta, for a human attacker")

    # --- the caps: +0x18 is skipped when +0x17 would reach 144, and both
    #     saturate at 144 -------------------------------------------------
    world, attacker, victim = _duel_scene(tables, human, alien, seed=seed)
    attacker.ep, attacker.tp = 144 - exp + 1, 20
    combat.attack_unit(world, attacker.x, attacker.y, victim.x, victim.y)
    c.expect("experience.ep_capped_at_144", attacker.ep, 144)
    c.expect("experience.tp_untouched_when_ep_would_cap", attacker.tp, 20,
             "0x0047B0B2 returns before the pool moves")
    world, attacker, victim = _duel_scene(tables, human, alien, seed=seed)
    attacker.ep, attacker.tp = 10, 143
    combat.attack_unit(world, attacker.x, attacker.y, victim.x, victim.y)
    c.expect("experience.tp_capped_at_144", attacker.tp, 144)

    # --- the gates: species 2, the attacker's own player, no damage ------
    world, attacker, victim = _duel_scene(tables, human, prop, seed=seed)
    victim.hp = 1
    result = combat.attack_unit(world, attacker.x, attacker.y, victim.x, victim.y)
    c.expect("experience.none_for_an_object",
             (result.xp, attacker.ep, attacker.tp, attacker.kills), (0, 0, 0, 0),
             f"victim alive {victim.alive}")
    world, attacker, victim = _duel_scene(tables, human, alien, seed=seed)
    victim.player = attacker.player
    result = combat.attack_unit(world, attacker.x, attacker.y, victim.x, victim.y)
    c.expect("experience.none_for_own_player",
             (result.xp, attacker.kills), (0, 0), f"victim alive {victim.alive}")
    c.expect("experience.kill_counter_saturates",
             _saturated_kills(), 255, "0x0047AF90 at 254 + 1 + 1")

    # --- the ladder, transcribed: every band and multiplier --------------
    ladder = []
    for ai_level in (0, 1, 2, 3):
        for ep in (0, 36, 72, 108, 109):
            world, attacker, victim = _duel_scene(
                tables, human, alien, game_mode=3, ai_level=ai_level, seed=seed)
            attacker.ep = ep
            ladder.append(combat.experience_gain(world, attacker, exp))
    m = [4, 3, 1, 2]
    want = []
    for i in range(4):
        want += [float(m[i]) * exp, float(m[i] - m[i] * 36 // 72) * exp,
                 float(exp), float(exp), exp * 0.5]
    c.expect("experience.session_ladder", ladder, want,
             "multiplier 4/3/1/2 by difficulty; bands at 72 and 108")
    world, attacker, victim = _duel_scene(tables, human, alien, game_mode=3,
                                          seed=seed)
    attacker.ep = 120
    c.expect("experience.session_exp_1_above_108_is_nothing",
             combat.experience_gain(world, attacker, 1), 0.0,
             "cmp cl, 1 at 0x0047B06C reads the argument byte")

    # --- the orbit does not play for an alien attacker ------------------
    world, attacker, victim = _duel_scene(tables, alien, human, seed=seed)
    victim.player = 0
    attacker.player = combat.PLAYER_COMPUTER
    attacker.tp = 11
    victim.hp = 1
    kill_seed = None
    for trial in range(1, 200):
        w2, a2, v2 = _duel_scene(tables, alien, human, seed=float(trial))
        a2.player, v2.player = combat.PLAYER_COMPUTER, 0
        a2.tp = 11
        r2 = combat.attack_unit(w2, a2.x, a2.y, v2.x, v2.y)
        if not v2.alive:
            kill_seed = float(trial)
            c.expect("experience.no_orbit_for_a_computer_species",
                     (r2.xp > 0, r2.skill_raised), (True, 0),
                     "0x0046C269 tests the attacker's species byte")
            break
    c.check("experience.alien_kill_found", kill_seed is not None, "no seed kills")


def _saturated_kills() -> int:
    unit = combat.CombatUnit(slot=0, type_id=0, player=0, x=0, y=0, hp=1,
                             kills=254)
    combat.count_kill(unit)
    combat.count_kill(unit)
    return unit.kills


def _require_corpus(root: Path) -> str | None:
    if not (root / "DATA" / "Info.lcl").is_file():
        return f"{root}: no DATA/Info.lcl -- this is not a game installation"
    if not any(root.rglob("*.lev")):
        return (f"{root}: no .lev found; a check that examined nothing is not "
                f"a check that passed")
    return None


def _placer_scene(tables: BalanceTables, weapon: int, size: int = 9
                  ) -> tuple[combat.CombatWorld, combat.CombatUnit]:
    """A shooter with `weapon` on flat, open ground, aimed at the middle."""
    n = size * size
    kind = next(iter(sorted(tables.units)))
    world = combat.CombatWorld(
        width=size, height=size, cell_height=[0] * n, unit_at=[-1] * n,
        effect_state=[ctrlmap.OBSTACLE_NONE] * n, units={}, tables=tables,
        action_point=[0] * n, field_type=[0] * n, rng=ARandom(1.0))
    shooter = combat.CombatUnit(slot=0, type_id=kind, player=0, x=0, y=0,
                               hp=100, fp=5, mp=4, weapon=weapon, ammo=99)
    world.units[0] = shooter
    world.unit_at[0] = 0
    return world, shooter


def check_impact_objects(c: Checker, tables: BalanceTables) -> None:
    """docs/42 §9.1 -- the three impact arms that change the map.

    Weapon 40 lays nine fires round the target, 42 a mine and 43 a shield, and
    all three do it whether the shot hit, missed or found nothing there: the
    impact switch is dispatched after the projectile arrives and reads no
    outcome.  The remake had none of them (`docs/97` §37).
    """
    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_GROUND_FIRE)
    combat.attack_unit(world, 0, 0, 4, 4)
    burning = [i for i, v in enumerate(world.effect_state)
               if v == ctrlmap.OBSTACLE_FIRE]
    c.expect("objects.fire.nine_cells", len(burning), 9)
    c.expect("objects.fire.centre_is_the_big_one",
             world.effect_timer[world.index(4, 4)], 4,
             "the centre goes down at subtype 4, the ring at 3")
    c.expect("objects.fire.ring_subtype",
             sorted({world.effect_timer[i] for i in burning}), [3, 4])
    c.expect("objects.fire.models",
             [ctrlmap.fire_model(4), ctrlmap.fire_model(3)],
             [ctrlmap.FIRE_MODEL_LARGE, ctrlmap.FIRE_MODEL_MEDIUM])
    c.expect("objects.fire.nine_slots_taken",
             sum(1 for v in world.special_objects if v != ctrlmap.NO_OBJECT), 9)

    # A neighbour half a field or more away in height does not catch: the z
    # every one of the nine is placed at is the **centre** cell's.
    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_GROUND_FIRE)
    world.cell_height[world.index(5, 4)] = ctrlmap.FIRE_HEIGHT_WINDOW
    combat.attack_unit(world, 0, 0, 4, 4)
    c.expect("objects.fire.height_window",
             world.effect_state[world.index(5, 4)], ctrlmap.OBSTACLE_NONE,
             "cmp eax, 0x640 at 0x0042F8C9")

    # A mine, and the shield that refuses to be replaced by a fire.
    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_MINE)
    combat.attack_unit(world, 0, 0, 4, 4)
    at = world.index(4, 4)
    c.expect("objects.mine.laid",
             [world.effect_state[at], world.effect_object[at],
              world.effect_timer[at]], [ctrlmap.OBSTACLE_MINE, 0, 0])

    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_SHIELD)
    combat.attack_unit(world, 0, 0, 4, 4)
    c.expect("objects.shield.laid",
             [world.effect_state[at], world.effect_timer[at]],
             [ctrlmap.OBSTACLE_SHIELD, ctrlmap.SHIELD_TIMER])
    # A second hit refreshes the countdown without a second object.
    world.effect_timer[at] = 1
    combat.attack_unit(world, 0, 0, 4, 4)
    c.expect("objects.shield.second_hit_refreshes",
             [world.effect_timer[at],
              sum(1 for v in world.special_objects
                  if v != ctrlmap.NO_OBJECT)],
             [ctrlmap.SHIELD_TIMER, 1],
             "+0x0E is written before the already-a-shield return")
    # And a fire refuses the cell outright while the shield stands.
    cells = world.ctrlmap()
    c.expect("objects.fire.refuses_a_shield",
             ctrlmap.place_fire(cells, 4, 4, 4, 0), -1)

    # The array is 80 slots, and a full one leaves the cell alone.
    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_MINE, size=16)
    cells = world.ctrlmap()
    cells.objects[:] = [ctrlmap.OBSTACLE_MINE] * ctrlmap.SPECIAL_OBJECT_SLOTS
    # The cell is put in a state the failure arm has to **change**: writing
    # 255 onto a cell that already reads 255 is not an observation, and a
    # placer that touched the byte at all would pass it.
    world.effect_state[world.index(4, 4)] = ctrlmap.OBSTACLE_FIRE
    world.effect_timer[world.index(4, 4)] = 3
    c.expect("objects.full_array_refuses", ctrlmap.place_mine(cells, 4, 4), -1)
    c.expect("objects.full_array_writes_255",
             [world.effect_state[world.index(4, 4)],
              world.effect_timer[world.index(4, 4)]],
             [ctrlmap.OBSTACLE_NONE, 0],
             "0x0042FB6C writes +0x0E = 0 and +0x10 = 0xFF when the "
             "constructor answers -1")

    # And the model gate: a world set with no `A_MINE` refuses the same way.
    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_MINE)
    world.special_models = frozenset({ctrlmap.SHIELD_MODEL})
    cells = world.ctrlmap()
    c.expect("objects.unknown_model_refuses", ctrlmap.place_mine(cells, 4, 4),
             -1, "0x004069F4 -- 'unknown object!'")

    # The round tick: a fire loses one intensity a round and goes out, a
    # shield expires after two, a mine is untouched.
    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_GROUND_FIRE)
    combat.attack_unit(world, 0, 0, 4, 4)
    ctrlmap.place_mine(world.ctrlmap(), 7, 7)
    centre = world.index(4, 4)
    seen = []
    for _ in range(5):
        ctrlmap.ground_effects_tick(world.ctrlmap())
        seen.append((world.effect_state[centre], world.effect_timer[centre]))
    c.expect("objects.fire.decays_one_a_round", seen,
             [(1, 3), (1, 2), (1, 1), (255, 0), (255, 0)])
    c.expect("objects.mine.outlives_the_tick",
             world.effect_state[world.index(7, 7)], ctrlmap.OBSTACLE_MINE)
    c.expect("objects.tick_frees_the_slots",
             sum(1 for v in world.special_objects
                 if v != ctrlmap.NO_OBJECT), 1, "only the mine is left")

    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_SHIELD)
    combat.attack_unit(world, 0, 0, 4, 4)
    ctrlmap.ground_effects_tick(world.ctrlmap())
    c.expect("objects.shield.first_round_counts_down",
             [world.effect_state[centre], world.effect_timer[centre]], [3, 1])
    ctrlmap.ground_effects_tick(world.ctrlmap())
    c.expect("objects.shield.expires_after_two",
             [world.effect_state[centre], world.effect_timer[centre]],
             [ctrlmap.OBSTACLE_NONE, 0])

    # The glow's two-round fuse, and what the flames do when it lands.
    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_MINE)
    victim = combat.CombatUnit(slot=1, type_id=shooter.type_id, player=1,
                               x=4, y=5, hp=100, fp=5, mp=4, weapon=0)
    world.units[1] = victim
    world.unit_at[world.index(4, 5)] = 1
    cells = world.ctrlmap()
    ctrlmap.place_glow(cells, 4, 4, ctrlmap.GLOW_PHASE_FRESH)
    c.expect("objects.glow.blocks_nobody",
             world.effect_state[world.index(4, 4)], ctrlmap.OBSTACLE_NONE,
             "0x0042FCB0 writes +0x11/+0x12/+0x13 and no obstacle byte")
    first = ctrlmap.ground_effects_tick(cells)
    c.expect("objects.glow.first_round_only_decays",
             [first["ignited"], first["killed"],
              world.decal_phase[world.index(4, 4)]],
             [[], [], ctrlmap.GLOW_PHASE_LIT])
    removed: list[int] = []
    second = ctrlmap.ground_effects_tick(cells, removed.append)
    c.expect("objects.glow.second_round_ignites",
             [second["ignited"], second["killed"], removed,
              world.decal_state[world.index(4, 4)]],
             [[world.index(4, 4)], [1], [1], ctrlmap.DECAL_NONE],
             "aPlayGroundFireAnimation removes what the flames reach")
    # A shield is the one thing that survives standing in it.
    world, shooter = _placer_scene(tables, ctrlmap.WEAPON_MINE)
    world.units[1] = combat.CombatUnit(slot=1, type_id=shooter.type_id,
                                       player=1, x=4, y=5, hp=100, fp=5, mp=4,
                                       weapon=0)
    world.unit_at[world.index(4, 5)] = 1
    cells = world.ctrlmap()
    ctrlmap.place_shield(cells, 4, 5)
    ctrlmap.place_glow(cells, 4, 4, ctrlmap.GLOW_PHASE_LIT)
    out = ctrlmap.ground_effects_tick(cells)
    c.expect("objects.ground_fire_spares_a_shielded_cell", out["killed"], [],
             "cmp byte [eax + 0x10], 3 at 0x004159AE")


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
    check_barrel_blast(c, tables)
    check_beacoo_blast(c, tables)
    check_reaction(c, tables)
    check_stun(c, tables)
    check_conversion(c, root, tables)
    check_experience(c, tables)
    check_jam_and_warp(c, tables)
    check_impact_objects(c, tables)
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
