#!/usr/bin/env python3
"""Run the interaction model over the corpus -- ``docs/26``.

``interaction_tables.py`` checks the dispatch tables in the binary; this checks
the behaviour those tables reach, against every shipped map.  What it asserts:

* **every action point the corpus carries is dispatched** -- to a class arm, to
  the script-only default, or refused by the gate; the model raises rather than
  quietly doing nothing, so an unhandled id is a failure and not a silence;
* the gate is the band 10..49 minus the two door exceptions, and no more;
* class 12 **assigns** the magazine -- a unit that has not fired sees ``+0x3D``
  unchanged while the point is still consumed (``docs/26`` §3.2);
* class 16 raises Technical Skills while guarding on **Battle Fitness**, so it
  stops working at ``CON == 6`` and can push ``TS`` past its cap
  (``docs/26`` §3.3, reproduced deliberately);
* the door toggle round-trips: 31 -> 30 -> 31 restores the field type and the
  height, and a jammed door opens once and never closes;
* a push moves at most four cells, refuses the ``Parabomb``, tests the flanks
  on a diagonal, and ends on a mine or in a hole;
* a defuse removes the mine, explodes nothing, and -- like a push -- **never
  reaches the LCL event**.

Usage::

    interact_runtime.py --check gog_incubation
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib import combat, interact                                 # noqa: E402
from inclib.check import Checker                                    # noqa: E402
from inclib.info import BalanceTables, load_info_file               # noqa: E402
from inclib.lev import load_lev                                     # noqa: E402
from inclib.rng import ARandom                                      # noqa: E402

LOG = logging.getLogger("interact_runtime")

#: The mission the focused checks run on.  ``_C_141`` carries the crowbar
#: pickup (``docs/26`` §2) and both sides' units, and it is the map every other
#: native capture in this repository was taken on.
FOCUS_MISSION = "_C_141"

#: The editor's template map.  It is the only file carrying a random supply
#: box, and it is a mission file like any other as far as the loader is
#: concerned -- which is why the census names it rather than skipping it.
TEMPLATE_MISSION = "_C_XXX"

#: ``docs/26`` §3.1 -- the ids the switch has an arm for.  Written out here and
#: not imported from the model, for the same reason ``movemap_runtime.py``
#: writes its step costs out: importing the model's own table and comparing
#: against it re-derives the model's answer and passes whatever it is.
HANDLED_IDS = frozenset({11, 12, 13, 14, 15, 16, 17, 18,
                         30, 31, 32, 33, 36, 37, 38, 39, 40, 41, 42, 70})


def _blank(width: int, height: int, tables: BalanceTables,
           seed: float = 1.0) -> combat.CombatWorld:
    """Flat ground with nothing on it -- the scene the focused checks build on."""
    n = width * height
    return combat.CombatWorld(
        width=width, height=height, cell_height=[0] * n, unit_at=[-1] * n,
        effect_state=[0] * n, action_point=[0] * n,
        field_type=[interact.FIELD_TYPE_FREE] * n, units={}, tables=tables,
        rng=ARandom(seed))


def _place(world: combat.CombatWorld, slot: int, type_id: int, x: int, y: int,
           **kw: Any) -> combat.CombatUnit:
    fields: dict[str, Any] = dict(slot=slot, type_id=type_id, player=0, x=x,
                                  y=y, hp=10, facing=3)
    fields.update(kw)
    unit = combat.CombatUnit(**fields)
    world.units[slot] = unit
    world.unit_at[world.index(x, y)] = slot
    return unit


def check_census(c: Checker, root: Path, tables: BalanceTables) -> None:
    """Every action point on every shipped map, through the gate and the switch."""
    missions = sorted((root / "Missions").glob("*.lev"))
    seen: dict[int, int] = {}
    random_box_in: set[str] = set()
    accepted: set[int] = set()
    refused: set[int] = set()
    unhandled: list[str] = []
    maps = 0
    for path in missions:
        bm = load_lev(str(path))
        maps += 1
        world = combat.world_from_map(bm, tables)
        for index, cell in enumerate(bm.cells):
            ap = cell.action_point
            if ap == 0:
                continue
            seen[ap] = seen.get(ap, 0) + 1
            if ap == interact.RANDOM_BOX:
                random_box_in.add(path.stem)
            x, y = index % bm.width, index // bm.width
            # A probe standing west of the cell and looking east at it, with no
            # crowbar: the gate's own inputs and nothing else.
            if x == 0:
                continue
            probe = combat.CombatUnit(slot=0, type_id=0, player=0, x=x - 1,
                                      y=y, hp=10, facing=3)
            if world.unit_at[index] >= 0:
                continue
            got = interact.use_target(world, probe)
            (accepted if got >= 0 else refused).add(ap)
            if got >= 0 and ap not in HANDLED_IDS and ap not in range(10, 50):
                unhandled.append(f"{path.name}: accepted {ap}")
    c.check("census.missions_read", maps > 0, f"{maps} mission(s)")
    c.check("census.action_points_found", len(seen) > 0,
            f"{len(seen)} distinct id(s), {sum(seen.values())} cell(s)")
    c.expect("census.gate_accepts_only_the_band",
             sorted(a for a in accepted if a not in range(10, 50)), [])
    c.expect("census.gate_refuses_everything_outside_the_band",
             sorted(a for a in refused if a in range(10, 50)),
             [interact.DOOR_JAMMED_CLOSED],
             "docs/26 section 2: the only in-band id a crowbar-less unit is "
             "refused is the jammed, closed door; jammed-open never ships")
    c.expect("census.no_accepted_id_is_unhandled", unhandled[:5], [])
    c.expect("census.the_random_box_is_only_on_the_template_map",
             sorted(random_box_in), [TEMPLATE_MISSION],
             "docs/26 section 3: no shipped mission contains one, so the roll "
             "below is the only thing that can ever produce ids 11..13 at "
             "runtime")

    # And the roll itself: base 11 span 3, written into the cell **before** the
    # switch runs, so the box's identity is fixed the moment it is opened.
    rolled: set[int] = set()
    for seed in range(1, 40):
        world = _blank(4, 4, tables, seed=float(seed))
        unit = _place(world, 0, 0, 1, 1, weapon=0)
        world.action_point[world.index(2, 1)] = interact.RANDOM_BOX
        result = interact.execute_use(world, unit)
        rolled.add(result.action_point)
    c.expect("census.the_random_box_rolls_into_three_ids",
             sorted(rolled), [11, 12, 13])

    # Every handled id must actually run, on a world built for it, without the
    # model raising -- which is the difference between "dispatched" and
    # "silently did nothing".
    kinds: dict[int, str] = {}
    for ap in sorted(HANDLED_IDS):
        world = _blank(4, 4, tables)
        unit = _place(world, 0, 0, 1, 1, weapon=0, fp=1,
                      equipment_ids=frozenset({interact.EQUIP_CROWBAR}))
        world.action_point[world.index(2, 1)] = ap
        kinds[ap] = interact.execute_use(world, unit).kind
    c.expect("census.every_handled_id_reaches_an_arm",
             sorted(ap for ap, k in kinds.items()
                    if k in ("", "script_only")), [])
    c.check("census.arms_are_distinct", len(set(kinds.values())) >= 8,
            f"kinds reached: {sorted(set(kinds.values()))}")

    # And one the switch does not handle must reach the default arm, which is
    # the LCL event and nothing else.
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0)
    world.action_point[world.index(2, 1)] = 25
    result = interact.execute_use(world, unit)
    c.expect("census.an_unhandled_in_band_id_is_script_only",
             [result.kind, result.fires_script_event, world.action_point[
                 world.index(2, 1)]],
             ["script_only", True, 25],
             "docs/26 section 2: 19..29, 34, 35 and 43..49 are offered, fire "
             "the event and change nothing")


def check_pickups(c: Checker, tables: BalanceTables) -> None:
    """The class arms, one scene each."""
    # --- class 12: assign, do not add ------------------------------------
    magazine = tables.weapons[0].mun
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0, ammo=magazine)
    world.action_point[world.index(2, 1)] = 12
    result = interact.execute_use(world, unit)
    c.expect("munition.a_full_magazine_is_a_visible_no_op",
             [unit.ammo, world.action_point[world.index(2, 1)], result.kind],
             [magazine, 0, "full_munition"],
             "docs/26 section 3.2: a test written as 'ammunition increased' "
             "fails on correct behaviour")
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0, ammo=1)
    world.action_point[world.index(2, 1)] = 12
    interact.execute_use(world, unit)
    c.expect("munition.an_empty_magazine_is_filled", unit.ammo, magazine)
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0, ammo=0,
                  equipment_ids=frozenset({interact.EQUIP_DOUBLE_MUNITION}))
    world.action_point[world.index(2, 1)] = 12
    interact.execute_use(world, unit)
    c.expect("munition.equipment_6_doubles_it", unit.ammo, magazine * 2)

    # --- classes 13, 17, 18: the equipment-point bonus --------------------
    for ap, worth in ((13, 50), (17, 20), (18, 10)):
        world = _blank(4, 4, tables)
        unit = _place(world, 0, 0, 1, 1, weapon=0)
        world.action_point[world.index(2, 1)] = ap
        interact.execute_use(world, unit)
        c.expect(f"points.class_{ap}_adds_{worth}",
                 world.game_control[interact.GAME_CONTROL_EQUIPMENT_POINTS],
                 worth)

    # --- classes 14, 15, 16: the implants, and the copy-paste bug ---------
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0)
    unit.skills = [0, 5, 6, 0, 0, 0]
    world.action_point[world.index(2, 1)] = 14
    interact.execute_use(world, unit)
    c.expect("implant.each_weapon_skill_is_capped_on_itself",
             [unit.skills[interact.SKILL_LW], unit.skills[interact.SKILL_HW]],
             [6, 6], "LW rose from 5, HW was already at the cap")

    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0)
    unit.skills = [3, 0, 0, 9, 0, 0]
    world.action_point[world.index(2, 1)] = 16
    interact.execute_use(world, unit)
    c.expect("implant.technical_pushes_past_the_cap",
             unit.skills[interact.SKILL_TS], 10,
             "docs/26 section 3.3: the guard reads CON, so nothing bounds TS")

    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0)
    unit.skills = [6, 0, 0, 1, 0, 0]
    world.action_point[world.index(2, 1)] = 16
    interact.execute_use(world, unit)
    c.expect("implant.technical_stops_when_condition_is_capped",
             unit.skills[interact.SKILL_TS], 1,
             "the box is inert for a unit whose Battle Fitness is 6, which is "
             "the bug and not a modelling choice")

    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0)
    unit.skills = [6, 0, 0, 0, 0, 0]
    world.action_point[world.index(2, 1)] = 15
    interact.execute_use(world, unit)
    c.expect("implant.condition_guards_itself_correctly",
             unit.skills[interact.SKILL_CON], 6)

    # --- the equipment pickups -------------------------------------------
    for ap, equip in ((38, interact.EQUIP_DAMAGE_ABSORBER),
                      (39, interact.EQUIP_CROWBAR),
                      (40, interact.EQUIP_COOLER),
                      (42, interact.EQUIP_EXPLOSION_PACK)):
        world = _blank(4, 4, tables)
        unit = _place(world, 0, 0, 1, 1, weapon=0)
        world.action_point[world.index(2, 1)] = ap
        interact.execute_use(world, unit)
        c.check(f"equipment.class_{ap}_grants_{equip}", unit.has(equip),
                f"carries {sorted(unit.equipment_ids)}")
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0)
    world.action_point[world.index(2, 1)] = 38
    interact.execute_use(world, unit)
    c.expect("equipment.the_absorber_arrives_with_four_charges",
             unit.absorber, interact.ABSORBER_CHARGES)

    # --- 11 and 41: the two inert ones ------------------------------------
    for ap in (11, 41):
        world = _blank(4, 4, tables)
        unit = _place(world, 0, 0, 1, 1, weapon=0, ammo=3)
        unit.skills = [1, 1, 1, 1, 1, 1]
        world.action_point[world.index(2, 1)] = ap
        result = interact.execute_use(world, unit)
        c.expect(f"inert.class_{ap}_consumes_the_cell_and_nothing_else",
                 [world.action_point[world.index(2, 1)], unit.ammo,
                  unit.skills, sorted(unit.equipment_ids), result.kind],
                 [0, 3, [1, 1, 1, 1, 1, 1], [], "message_only"])

    # --- 70: the entry point ----------------------------------------------
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0, fp=1,
                  equipment_ids=frozenset({interact.EQUIP_EXPLOSION_PACK}))
    world.action_point[world.index(2, 1)] = interact.ENTRY_POINT
    world.cell_height[world.index(2, 1)] = 0x200
    c.check("entry.the_gate_needs_fitness_and_the_pack",
            interact.may_use(world, unit), "predicate 3")
    unit.fp = 0
    c.check("entry.no_fitness_no_entry_point",
            not interact.may_use(world, unit),
            "0x0047B410 reads +0x19 as well as the equipment slot")
    unit.fp = 1
    interact.execute_use(world, unit)
    c.expect("entry.it_burns_and_becomes_71",
             [world.action_point[world.index(2, 1)],
              world.effect_state[world.index(2, 1)],
              world.cell_height[world.index(2, 1)]],
             [interact.ENTRY_POINT_DESTROYED, interact.ENTRY_POINT_EFFECT,
              0x200 - interact.ENTRY_POINT_Z_DROP])


def check_doors(c: Checker, tables: BalanceTables) -> None:
    """``docs/26`` §3.4 -- one toggle, keyed on the low bit."""
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0)
    at = world.index(2, 1)
    world.action_point[at] = 31                    # standard door, closed
    world.field_type[at] = interact.FIELD_TYPE_WALL
    world.cell_height[at] = interact.DOOR_HEIGHT_STEP
    interact.execute_use(world, unit)
    c.expect("door.opening_drops_it_to_the_floor",
             [world.action_point[at], world.field_type[at],
              world.cell_height[at]],
             [30, interact.FIELD_TYPE_FREE, 0])
    interact.execute_use(world, unit)
    c.expect("door.closing_raises_it_one_tile",
             [world.action_point[at], world.field_type[at],
              world.cell_height[at]],
             [31, interact.FIELD_TYPE_WALL, interact.DOOR_HEIGHT_STEP],
             "the round trip restores every byte it touched")

    # The jammed pair: the crowbar is the key, and it opens exactly once.
    world = _blank(4, 4, tables)
    bare = _place(world, 0, 0, 1, 1, weapon=0)
    at = world.index(2, 1)
    world.action_point[at] = interact.DOOR_JAMMED_CLOSED
    c.expect("door.jammed_needs_the_crowbar",
             interact.use_target(world, bare), -1)
    bare.equipment_ids = frozenset({interact.EQUIP_CROWBAR})
    c.expect("door.the_crowbar_opens_it",
             interact.use_target(world, bare), interact.DOOR_JAMMED_CLOSED)
    interact.execute_use(world, bare)
    c.expect("door.a_jammed_door_becomes_jammed_open",
             world.action_point[at], interact.DOOR_JAMMED_OPEN)
    c.expect("door.and_can_never_be_closed_again",
             interact.use_target(world, bare), -1,
             "docs/26 section 2: id 32 is refused unconditionally, which is "
             "why the corpus census finds zero cells carrying it")


def check_levers(c: Checker, tables: BalanceTables) -> None:
    world = _blank(4, 4, tables)
    unit = _place(world, 0, 0, 1, 1, weapon=0)
    at = world.index(2, 1)
    world.action_point[at] = interact.LEVER_UP
    r1 = interact.execute_use(world, unit)
    down = world.action_point[at]
    interact.execute_use(world, unit)
    c.expect("lever.toggles_and_returns",
             [down, world.action_point[at], r1.kind],
             [interact.LEVER_DOWN, interact.LEVER_UP, "lever"])
    c.check("lever.still_fires_the_script_event", r1.fires_script_event,
            "a lever is a class arm, so it reaches the default tail")


def check_push_and_mines(c: Checker, tables: BalanceTables) -> None:
    """``docs/26`` §4 and §4.1 -- the two branches that skip the script."""
    pushable_type = sorted(interact.PUSHABLE_TYPES)[0]

    world = _blank(10, 10, tables)
    unit = _place(world, 0, 0, 1, 5, weapon=0, facing=3)
    _place(world, 1, pushable_type, 2, 5, player=252)
    result = interact.execute_use(world, unit)
    c.expect("push.slides_at_most_four_cells", len(result.pushed),
             interact.PUSH_MAX_STEPS)
    c.expect("push.the_object_ends_where_the_slide_did",
             [world.units[1].x, world.units[1].y], [6, 5])
    c.expect("push.the_pusher_does_not_move", [unit.x, unit.y], [1, 5],
             "0x0046D530 re-tests with the object's coordinates; a model that "
             "walked the unit along behind it would be a different game")
    c.check("push.never_reaches_the_script", not result.fires_script_event,
            "docs/26 section 3: a push returns before the default arm")

    # The Parabomb sits in the middle of the pushable run and is not one.
    world = _blank(10, 10, tables)
    unit = _place(world, 0, 0, 1, 5, weapon=0, facing=3)
    _place(world, 1, 31, 2, 5, player=252)
    c.check("push.the_parabomb_is_not_pushable",
            not interact.can_push(world, 2, 5, 3),
            "type 31 sits between 30 and 32 and is deliberately excluded")

    # A wall, a higher cell and an occupied cell each stop it.
    for name, apply in (
            ("a_wall", lambda w: w.field_type.__setitem__(
                w.index(3, 5), interact.FIELD_TYPE_WALL)),
            ("a_step_up", lambda w: w.cell_height.__setitem__(
                w.index(3, 5), 1)),
            ("an_occupied_cell", lambda w: w.unit_at.__setitem__(
                w.index(3, 5), 9))):
        world = _blank(10, 10, tables)
        _place(world, 0, 0, 1, 5, weapon=0, facing=3)
        _place(world, 1, pushable_type, 2, 5, player=252)
        apply(world)
        c.check(f"push.{name}_stops_it",
                not interact.can_push(world, 2, 5, 3), name)

    # A diagonal push tests the two flanking cells as well.
    world = _blank(10, 10, tables)
    _place(world, 0, 0, 1, 1, weapon=0, facing=6)
    _place(world, 1, pushable_type, 2, 2, player=252)
    c.check("push.a_clear_diagonal_is_allowed",
            interact.can_push(world, 2, 2, 6), "facing 6 is (+1, +1)")
    world.field_type[world.index(3, 2)] = interact.FIELD_TYPE_WALL
    c.check("push.a_blocked_flank_stops_a_diagonal",
            not interact.can_push(world, 2, 2, 6),
            "only the flank changed; the destination is still clear")

    # Into a hole.
    world = _blank(10, 10, tables)
    unit = _place(world, 0, 0, 1, 5, weapon=0, facing=3)
    obj = _place(world, 1, pushable_type, 2, 5, player=252)
    world.field_type[world.index(3, 5)] = interact.FIELD_TYPE_DEEP_HOLE
    result = interact.execute_use(world, unit)
    c.expect("push.a_hole_swallows_it",
             [result.kind, obj.hp, world.unit_at[world.index(3, 5)]],
             ["push_into_hole", 0, -1])

    # Onto a mine.
    world = _blank(10, 10, tables)
    unit = _place(world, 0, 0, 1, 5, weapon=0, facing=3)
    _place(world, 1, pushable_type, 2, 5, player=252)
    victim = _place(world, 2, 0, 3, 6, player=0, hp=200, weapon=0)
    world.effect_state[world.index(3, 5)] = interact.EFFECT_MINE
    result = interact.execute_use(world, unit)
    c.expect("push.a_mine_detonates_under_it",
             [result.kind, world.effect_state[world.index(3, 5)]],
             ["push_onto_mine", interact.EFFECT_NONE])
    c.check("push.the_detonation_reaches_a_neighbour", victim.hp < 200,
            f"the ParaBomb's neighbour marker took {200 - victim.hp}")

    # Defusing one instead.
    world = _blank(10, 10, tables)
    unit = _place(world, 0, 0, 1, 5, weapon=0, facing=3)
    bystander = _place(world, 2, 0, 2, 6, player=0, hp=200, weapon=0)
    world.effect_state[world.index(2, 5)] = interact.EFFECT_MINE
    c.check("mine.the_gate_offers_a_defuse", interact.may_use(world, unit),
            "predicate 4 reads +0x10")
    result = interact.execute_use(world, unit)
    c.expect("mine.defusing_removes_it_without_an_explosion",
             [result.kind, world.effect_state[world.index(2, 5)],
              bystander.hp, result.fires_script_event],
             ["defuse_mine", interact.EFFECT_NONE, 200, False])


def check_facing(c: Checker, root: Path, tables: BalanceTables) -> None:
    """``docs/26`` §2 -- a unit uses what it is facing, and nothing else."""
    bm = load_lev(str(root / "Missions" / f"{FOCUS_MISSION}.lev"))
    world = combat.world_from_map(bm, tables)
    c.check("facing.focus_mission_loaded",
            len(world.action_point) == bm.width * bm.height,
            f"{FOCUS_MISSION}: {bm.width}x{bm.height}")

    world = _blank(5, 5, tables)
    unit = _place(world, 0, 0, 2, 2, weapon=0)
    world.action_point[world.index(3, 2)] = 17
    hits = [f for f in range(8)
            if (unit.__setattr__("facing", f) or
                interact.use_target(world, unit) >= 0)]
    c.expect("facing.exactly_one_facing_reaches_the_point", hits, [3],
             "FACING_STEPS[3] is (+1, 0), which docs/26's native sweep over "
             "all eight facings confirmed")
    edge = combat.CombatUnit(slot=1, type_id=0, player=0, x=4, y=2, hp=1,
                             facing=3)
    c.expect("facing.off_the_map_is_none",
             interact.cell_in_front(world, edge), None)
    c.expect("facing.off_the_map_refuses_the_use",
             interact.execute_use(world, edge).ok, False)


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
    check_census(c, root, tables)
    check_pickups(c, tables)
    check_doors(c, tables)
    check_levers(c, tables)
    check_push_and_mines(c, tables)
    check_facing(c, root, tables)
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
