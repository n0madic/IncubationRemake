"""An executable model of ``aExecuteUse`` and its gate -- ``docs/26``.

``interaction_tables.py`` proves the *dispatch* in the binary: the 60-byte index
table at ``0x0046E1DC``, the 18-entry jump table at ``0x0046E194``, and the
census of which action-point ids the shipped maps actually carry.  This module
is the other half -- what those arms **do**, as code that can be run against a
map and diffed against the engine.

What is here, in the order ``docs/26`` puts them:

* ``CellInFront`` (``0x004308C0``) and the four Use predicates (§2), of which
  ``0x0047A530`` is the interesting one: the band is 10..49, the *jammed,
  closed* door needs equipment 17 and the *jammed, open* door is refused
  outright;
* the dispatch (``0x0046DC60``, §3) with its two early returns -- a push and a
  mine defuse never reach the script;
* the seventeen class arms (§3.1), including the two the documentation is at
  pains about: class 12 **assigns** the magazine rather than adding to it, and
  class 16 raises Technical Skills while guarding on **Battle Fitness**, which
  is a copy-paste bug in the original and is reproduced here (§3.3);
* the door toggle (``0x00410A20``, §3.4), which keys on the action point's low
  bit and moves the cell's height by exactly one tile;
* the push (``0x0046D530``, §4) and the mine defuse (``0x0046DB80``, §4.1).

Three things this model is deliberately literal about:

**A unit uses what it is facing.**  There is no reach and no selection.  The
whole input is the facing byte ``+0x46``, which is what makes ``docs/26``'s
native sweep over all eight facings a complete test of the convention.

**The random supply box rolls once, into the cell.**  Id 10 becomes 11, 12 or
13 *before* the switch runs, so the box's identity is fixed the moment it is
opened.  No shipped mission contains one; only the editor's template map does.

**Ids the switch does not handle are still accepted by the gate.**  19..29, 34,
35 and 43..49 are offered to the player, consume the movement point and fire
the LCL ``Use`` event, and change nothing else.  Every button in the game is
script state built on that.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from .combat import CombatUnit, CombatWorld, PLAYER_COMPUTER  # noqa: F401
from .lev import FACING_STEPS

LOG = logging.getLogger("interact")

#: ``0x0047A530`` -- the band the Use button lights for.
USE_BAND = range(10, 50)

#: ``docs/26`` §3 -- the random supply box, and the three ids it rolls into.
#: ``aRandom(11, 3)`` is base 11 span 3, so 11, 12 or 13.
RANDOM_BOX = 10
RANDOM_BOX_BASE, RANDOM_BOX_SPAN = 11, 3

#: The four door ids.  The toggle keys on the low bit: even is open, odd is
#: closed, and nothing in it distinguishes the jammed pair from the standard
#: one -- that lives entirely in the gate.
DOOR_IDS = frozenset({30, 31, 32, 33})
DOOR_JAMMED_CLOSED = 33
DOOR_JAMMED_OPEN = 32
#: ``docs/10`` §4 -- one tile of cell height, the amount a closing door rises.
DOOR_HEIGHT_STEP = 0xC80
#: ``docs/10`` §4.1 -- the two field types the toggle writes.
FIELD_TYPE_WALL = 2
FIELD_TYPE_FREE = 1

#: The lever pair; the arm plays a sequence and flips the id.
LEVER_UP, LEVER_DOWN = 36, 37

#: The entry point and what it becomes.  ``0x0042F840(x, y, 6, height - 0xA0)``
#: sets the cell on fire (``docs/23`` §7.1) before the sequence plays.
ENTRY_POINT, ENTRY_POINT_DESTROYED = 70, 71
ENTRY_POINT_EFFECT = 6
ENTRY_POINT_Z_DROP = 0xA0

#: ``docs/26`` §3.1 -- the equipment ids the pickups grant, and the one that
#: doubles a magazine.
EQUIP_DOUBLE_MUNITION = 6
EQUIP_EXPLOSION_PACK = 9
EQUIP_CROWBAR = 17
EQUIP_DAMAGE_ABSORBER = 18
EQUIP_COOLER = 19
#: The absorber pickup hands out four charges.
ABSORBER_CHARGES = 4

#: ``docs/20`` §5.3 -- the mission's equipment-point bonus.
GAME_CONTROL_EQUIPMENT_POINTS = 10

#: ``docs/10`` §5.3 -- ``+0x1A..+0x1F``.  The three implant boxes read and
#: write these by index, and ``docs/26`` §3.3's copy-paste bug is entirely a
#: matter of which index the *guard* uses.
SKILL_CON, SKILL_LW, SKILL_HW, SKILL_TS = 0, 1, 2, 3
SKILL_CAP = 6

#: ``0x0047B250`` -- the unit types a Use may push.  ``31``, ``Parabomb``, sits
#: in the middle of the run and is **not** one of them.
PUSHABLE_TYPES = frozenset({30, 32, 33, 34, 35})
#: ``0x0046D530`` -- how far one push slides an object, re-testing each step.
PUSH_MAX_STEPS = 4
#: ``docs/10`` §4.1 -- a pushed object that reaches one of these falls out of
#: the world.
FIELD_TYPE_HOLE, FIELD_TYPE_DEEP_HOLE = 3, 4
#: ``docs/10`` §5.10 -- facings 4..7 are the diagonals, and a diagonal push
#: tests the two flanking neighbours as well.
DIAGONAL_FACINGS = frozenset({4, 5, 6, 7})

#: ``+0x10`` -- the runtime effect object that makes a cell a mine.
EFFECT_MINE = 2
EFFECT_NONE = 0xFF
#: The weapon a detonating mine fires as (``docs/26`` §4).
MINE_WEAPON = 36


class InteractError(Exception):
    """Raised when the model is asked for something it does not simulate."""


@dataclass
class UseResult:
    """What one ``aExecuteUse`` did -- a value, like every other result here."""

    ok: bool
    kind: str = ""
    reason: str = ""
    #: The cell the unit was facing, or ``None`` when it was facing off the map.
    cell: tuple[int, int] | None = None
    #: The action point as the switch saw it, **after** a random box rolled.
    action_point: int = 0
    #: True when the default arm was reached, i.e. when the LCL ``Use`` event
    #: fires.  A push and a defuse never reach it (``docs/26`` §3).
    fires_script_event: bool = False
    #: ``(x, y)`` of every cell a push moved an object through.
    pushed: list[tuple[int, int]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok, "kind": self.kind, "reason": self.reason,
            "cell": list(self.cell) if self.cell else None,
            "action_point": self.action_point,
            "fires_script_event": self.fires_script_event,
            "pushed": [list(p) for p in self.pushed],
        }


def cell_in_front(world: CombatWorld, unit: CombatUnit) -> tuple[int, int] | None:
    """``0x004308C0(facing, x, y)`` -- the neighbour a unit is looking at.

    ``None`` off the map, which is the dispatch's first early return.
    """
    step = FACING_STEPS.get(unit.facing)
    if step is None:
        raise InteractError(f"facing {unit.facing} is not one of the eight")
    x, y = unit.x + step[0], unit.y + step[1]
    return (x, y) if world.in_bounds(x, y) else None


def _require_cells(world: CombatWorld) -> None:
    n = world.width * world.height
    for name in ("action_point", "field_type"):
        got = len(getattr(world, name))
        if got != n:
            raise InteractError(
                f"the world carries {got} {name} cell(s) for a {world.width}x"
                f"{world.height} map; interaction reads +0x0B and +0x0D, so a "
                f"world built for combat alone cannot answer it")


def use_target(world: CombatWorld, unit: CombatUnit) -> int:
    """``0x0047A530`` -- predicate 1, returning the action point or ``-1``.

    Four comparisons and nothing else: an empty cell, the band 10..49, the
    crowbar for a *jammed, closed* door, and an outright refusal of *jammed,
    open* -- which is why a jammed door can be pried open exactly once.
    """
    _require_cells(world)
    at = cell_in_front(world, unit)
    if at is None:
        return -1
    index = world.index(*at)
    if world.unit_at[index] >= 0:
        return -1
    ap = world.action_point[index]
    if ap not in USE_BAND:
        return -1
    if ap == DOOR_JAMMED_CLOSED and not unit.has(EQUIP_CROWBAR):
        return -1
    if ap == DOOR_JAMMED_OPEN:
        return -1
    return ap


def can_push(world: CombatWorld, x: int, y: int, facing: int) -> bool:
    """``0x0047B250`` -- predicate 2, taking the **object's** cell.

    The executor re-tests it before every one of its four steps, and it does so
    with the object's coordinates rather than the pusher's -- the pusher does
    not move.  Writing this as a predicate on the unit instead would slide the
    unit along behind the object, which is a different game.

    The occupant's *type* must be one of five, the destination must be empty,
    not a ``Wall`` and not higher than the source -- and a **diagonal** push
    tests the two flanking neighbours as well, which is what stops an object
    being squeezed between two corners.
    """
    _require_cells(world)
    if not world.in_bounds(x, y):
        return False
    at = (x, y)
    source = world.index(x, y)
    slot = world.unit_at[source]
    if slot < 0:
        return False
    occupant = world.units.get(slot)
    if occupant is None or occupant.type_id not in PUSHABLE_TYPES:
        return False
    step = FACING_STEPS[facing]
    destination = (at[0] + step[0], at[1] + step[1])
    if not world.in_bounds(*destination):
        return False
    into = world.index(*destination)
    if world.unit_at[into] >= 0:
        return False
    if world.field_type[into] == FIELD_TYPE_WALL:
        return False
    if world.cell_height[into] > world.cell_height[source]:
        return False
    if facing in DIAGONAL_FACINGS:
        for flank in ((at[0] + step[0], at[1]), (at[0], at[1] + step[1])):
            if not world.in_bounds(*flank):
                return False
            side = world.index(*flank)
            if world.unit_at[side] >= 0:
                return False
            if world.field_type[side] == FIELD_TYPE_WALL:
                return False
    return True


def may_use(world: CombatWorld, unit: CombatUnit) -> bool:
    """``docs/26`` §2 -- the Use button lights when **any** predicate accepts."""
    _require_cells(world)
    if use_target(world, unit) >= 0:
        return True
    at = cell_in_front(world, unit)
    if at is None:
        return False
    if can_push(world, at[0], at[1], unit.facing):
        return True
    index = world.index(*at)
    if (world.action_point[index] == ENTRY_POINT and unit.fp != 0
            and unit.has(EQUIP_EXPLOSION_PACK)):
        return True
    return world.effect_state[index] == EFFECT_MINE


def _consume(world: CombatWorld, index: int) -> None:
    """Every pickup arm ends the same way: the cell becomes 0."""
    world.action_point[index] = 0


def _raise_skill(unit: CombatUnit, which: int, guard: int) -> None:
    """One implant box.

    ``guard`` is the skill index the arm actually compares against, which is
    the whole of ``docs/26`` §3.3: id 15 guards ``CON`` on ``CON`` and id 16
    guards ``TS`` on ``CON``, so the technical box can push ``TS`` past its cap
    and stops working once ``CON`` reaches 6.  Reproduced, not corrected.
    """
    if unit.skills[guard] < SKILL_CAP:
        unit.skills[which] += 1


def defuse_mine(world: CombatWorld, index: int) -> UseResult:
    """``0x0046DB80`` -- the effect object is freed and nothing explodes."""
    world.effect_state[index] = EFFECT_NONE
    return UseResult(True, "defuse_mine",
                     cell=(index % world.width, index // world.width))


def push_object(world: CombatWorld, unit: CombatUnit) -> UseResult:
    """``0x0046D530`` -- slide the object up to four cells, re-testing each.

    Two ways the slide ends other than running out of steps, and both can kill
    the pusher, which is what ``docs/26`` §1.1's ``hp == 0`` test is for: the
    object reaches a mine and detonates it as a weapon-36 shot centred on the
    cell, or it reaches a ``Hole`` and falls out of the world.

    The detonation used to be the documentation's claim rather than a
    measurement (``docs/26`` §10 item 7).  It is read now: ``0x0046D8DD``
    carries the same ``aDeleteSpecialObject`` guard every other cell-based
    detonation does, so this arm is no weaker than the walk's -- ``docs/26``
    §6.2.
    """
    from . import combat as combatmod

    result = UseResult(True, "push")
    at = cell_in_front(world, unit)
    if at is None:
        return UseResult(False, "push", "the cell in front is off the map")
    result.cell = at
    step = FACING_STEPS[unit.facing]
    for _ in range(PUSH_MAX_STEPS):
        if not can_push(world, at[0], at[1], unit.facing):
            break
        source = world.index(*at)
        slot = world.unit_at[source]
        obj = world.units[slot]
        at = (at[0] + step[0], at[1] + step[1])
        into = world.index(*at)
        world.unit_at[source] = -1
        world.unit_at[into] = slot
        obj.x, obj.y = at
        result.pushed.append(at)
        if world.effect_state[into] == EFFECT_MINE:
            world.effect_state[into] = EFFECT_NONE
            combatmod.execute_bomb(world, at[0], at[1])
            result.kind = "push_onto_mine"
            break
        if world.field_type[into] in (FIELD_TYPE_HOLE, FIELD_TYPE_DEEP_HOLE):
            world.unit_at[into] = -1
            obj.hp = 0
            result.kind = "push_into_hole"
            break
    return result


def execute_use(world: CombatWorld, unit: CombatUnit) -> UseResult:
    """``aExecuteUse`` ``0x0046DC60`` -- ``docs/26`` §3, in the order it runs.

    The two early returns come first and never reach the script; only the
    action-point classes do.  Every arm that is a pickup clears the cell, and
    every id the switch does not handle falls through to the default arm, which
    *is* the LCL event and nothing else.
    """
    _require_cells(world)
    at = cell_in_front(world, unit)
    if at is None:
        return UseResult(False, "refused", "the cell in front is off the map")
    index = world.index(*at)
    if world.unit_at[index] >= 0:
        return push_object(world, unit)
    if world.effect_state[index] == EFFECT_MINE:
        return defuse_mine(world, index)

    if world.action_point[index] == RANDOM_BOX:
        world.action_point[index] = world.rng(RANDOM_BOX_BASE, RANDOM_BOX_SPAN)
    ap = world.action_point[index]
    result = UseResult(True, "class", cell=at, action_point=ap,
                       fires_script_event=True)

    if ap == 11 or ap == 41:
        _consume(world, index)
        result.kind = "message_only"
    elif ap == 12:
        # `.get`, not `[]`: `Info.lcl` defines no row for ids 18, 19, 33, 34,
        # 38, 39 or anything from 48 up, and a unit can carry one of those
        # bytes out of a save or a script.  A bare `KeyError` here would be the
        # one place in this module that fails with something other than
        # :class:`InteractError`, and `godot/core/interact.gd` falls back to 0.
        weapon = world.tables.weapons.get(unit.weapon)
        magazine = 0 if weapon is None else weapon.mun
        if unit.has(EQUIP_DOUBLE_MUNITION):
            magazine *= 2
        unit.ammo = magazine
        _consume(world, index)
        result.kind = "full_munition"
    elif ap in (13, 17, 18):
        world.game_control[GAME_CONTROL_EQUIPMENT_POINTS] += {
            13: 50, 17: 20, 18: 10}[ap]
        _consume(world, index)
        result.kind = "equipment_points"
    elif ap == 14:
        _raise_skill(unit, SKILL_LW, SKILL_LW)
        _raise_skill(unit, SKILL_HW, SKILL_HW)
        _consume(world, index)
        result.kind = "weapon_skills"
    elif ap == 15:
        _raise_skill(unit, SKILL_CON, SKILL_CON)
        _consume(world, index)
        result.kind = "condition"
    elif ap == 16:
        _raise_skill(unit, SKILL_TS, SKILL_CON)
        _consume(world, index)
        result.kind = "technical"
    elif ap in DOOR_IDS:
        toggle_door(world, index)
        result.kind = "door"
    elif ap in (LEVER_UP, LEVER_DOWN):
        world.action_point[index] = (LEVER_DOWN if ap == LEVER_UP
                                     else LEVER_UP)
        result.kind = "lever"
    elif ap in (38, 39, 40, 42):
        granted = {38: EQUIP_DAMAGE_ABSORBER, 39: EQUIP_CROWBAR,
                   40: EQUIP_COOLER, 42: EQUIP_EXPLOSION_PACK}[ap]
        unit.equipment_ids = frozenset(unit.equipment_ids | {granted})
        if ap == 38:
            unit.absorber = ABSORBER_CHARGES
        _consume(world, index)
        result.kind = "equipment"
    elif ap == ENTRY_POINT:
        world.effect_state[index] = ENTRY_POINT_EFFECT
        world.cell_height[index] -= ENTRY_POINT_Z_DROP
        world.action_point[index] = ENTRY_POINT_DESTROYED
        result.kind = "entry_point"
    else:
        # The default arm: 19..29, 34, 35, 43..49 and everything outside the
        # switch's own 11..70 band.  It is the LCL event and nothing else.
        result.kind = "script_only"
    return result


def toggle_door(world: CombatWorld, index: int) -> None:
    """``0x00410A20`` -- one toggle for all four door ids, on the low bit.

    A door is a wall panel that rises out of the floor: closing it raises the
    cell by exactly one tile and makes it a ``Wall``, opening it drops the cell
    to height 0 and makes it a ``Free Place``.
    """
    ap = world.action_point[index]
    if ap % 2 == 0:                      # even: 30, 32 -- it is open
        world.cell_height[index] += DOOR_HEIGHT_STEP
        world.action_point[index] = ap + 1
        world.field_type[index] = FIELD_TYPE_WALL
    else:                                # odd: 31, 33 -- it is closed
        world.field_type[index] = FIELD_TYPE_FREE
        world.action_point[index] = ap - 1
        world.cell_height[index] = 0
