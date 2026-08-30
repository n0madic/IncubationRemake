"""An executable model of line of sight, visibility and combat -- ``docs/22``.

``combat_tables.py`` proves the *tables* in the binary: the 28 target-pattern
handlers, the 48 weapon ids, the octant tables, the constants.  This module is
the other half -- the **behaviour** those tables feed, as code that can be run
against a map and diffed against the engine.

What is here, in the order ``docs/22`` §10 puts them:

* ``aGetDistance``, ``eyeHeight`` and ``fullHeight`` -- the geometry everything
  else measures in;
* ``setupStep`` / ``aCheckLineOfSight`` / ``aCheckLineOfSightEx`` -- the DDA,
  its three outcome codes, and the one-, two- or four-ray sampling;
* ``aGetHitProbability`` -- the distance rule, the range gate, the accuracy
  curve and the cover subtraction;
* ``applyDamage`` -- the difficulty-widened roll, the fatigue penalty, the
  armour subtraction and the 135-degree rear arc;
* ``aCheckWeaponDamage`` -- the overheat roll;
* ``aBuildVisibleMap`` and its per-unit pass, including the two scanners and
  the neighbour-cluster promotion;
* the reaction queue -- ``0x004753E0`` and ``0x0040A710``'s two disagreeing Def
  gates, ``0x00478500``'s ticket, ``0x004790F0``'s 135-degree front arc and
  ``0x0046CCA0``'s drain (``docs/25`` §6).  Nothing in the drain clears
  ``+0x41``, and this model does not either.

Three things this model is deliberately literal about, because ``docs/22`` says
a remake gets them wrong by accident:

**The line-of-sight outcomes are codes, not costs.**  0 clear, 254 a body, 255
terrain; terrain wins, and the walk runs to the target cell rather than
stopping at the first block.

**Vision and fire are different tests.**  Vision measures from ``fullHeight``
and accepts 254; a shot measures from ``eyeHeight`` and any obstruction zeroes
the chance.  A unit standing in the way blocks a shot but not the sight of it.

**The floats stay floats.**  The DDA is a ``double`` walk with a rounding bias
added before truncation, and the bias is what lets a shot slip past a corner.
Reimplementing it in integers would produce a different, plausible answer --
the same trap ``inclib.rng`` documents for the generator.

The target patterns (``docs/22`` §7.2) are classified but not all simulated:
the sixteen handlers are named here and the five simple families are applied,
because those are the ones ``_C_140``'s and ``_C_141``'s weapons use.  The rest
raise rather than silently marking nothing.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Sequence

from .info import BalanceTables
from .movemap import distance
from .rng import ARandom

LOG = logging.getLogger("combat")

# ---------------------------------------------------------------------------
# Geometry -- docs/22 sections 4, 5.1 and 5.5
# ---------------------------------------------------------------------------

#: ``docs/22`` §5.1 -- two adjacent cells more than 1.5 m apart vertically count
#: as further apart than one field.  The rule fires only at ``d == 1``.
HEIGHT_STEP = 2400

#: ``docs/22`` §5.5 -- ``unitType[+0x7C] * 160``; the eye is half that plus 800.
HEIGHT_LEVEL_UNITS = 160
EYE_BASE = 800
#: A null unit pointer yields this from both height helpers.
NULL_UNIT_HEIGHT = 2400

#: ``docs/22`` §5.5 -- one field, added to **both** endpoints for an arcing
#: weapon, which lifts the ray without changing its slope.  That is the whole
#: indirect-fire mechanic.
ARC_Z_OFFSET = 3200
#: ``0x0047B600`` returns 1 for exactly these: the Grenade Launcher, the Mine
#: Thrower Enhanced, and the B mode of each.
ARCING_WEAPONS = frozenset({8, 13, 42, 46})

#: ``docs/22`` §6.2 -- the three outcome codes.  They are codes, not costs.
LOS_CLEAR = 0
LOS_UNIT = 0xFE
LOS_TERRAIN = 0xFF

#: ``docs/22`` §6.2 -- ``dz`` is per field stepped, so this is a slope limit of
#: ``4000 / 3200``, about 51 degrees.
LOS_SLOPE_LIMIT = 4000.0
#: ``0x0046C720``'s own loop bound.
LOS_MAX_STEPS = 1000

#: ``docs/22`` §6.1 -- the biases each ray form uses.  0.4 and 0.6 walk the
#: *same* geometric line and break ties on opposite sides of it.
BIAS_CENTRE = 0.5
BIAS_LOW = 0.4
BIAS_HIGH = 0.6

#: ``docs/22`` §5.5 -- a neutral unit whose primary order is not 9 gets the
#: single-ray form; everything else gets the two- or four-ray one.
CLEVER_SMALL_UNITS_ORDER = 9
PLAYER_COMPUTER = 0xFF
#: ``docs/10`` §5.7 -- the neutral-prop owner.  ``0x0046ACCD`` refuses to mark a
#: neighbour whose occupant belongs to it, which is what makes weapon 22's
#: pattern differ from weapon 8's.
PLAYER_NEUTRAL = 0xFC

#: ``docs/22`` §9.2 -- permanently visible whatever the fog says.
ALWAYS_VISIBLE_TYPES = frozenset({0x3D, 0x3E, 0x3F})
SPECIES_OBJECT = 2

#: ``docs/22`` §9.1 -- ``+0x4F``.
VISIBLE_FULL = 0
VISIBLE_CONTACT = 1
VISIBLE_HIDDEN = 3

#: ``docs/22`` §9.3 -- equipment 0 and 1, and their ranges.
EQUIP_SCAN_MODULE = 0
EQUIP_LONG_RANGE_SCAN = 1
SCAN_RANGE = 6
LONG_SCAN_RANGE = 8

#: ``docs/22`` §9.3 -- seeing a neutral unit on one of these orders wakes its
#: whole AI group.
ALERTING_ORDERS = frozenset({5, 6, 8})

#: ``docs/22`` §5.3 -- equipment 5, ``"Target System"``, doubles the accuracy
#: rating before the curve; and ``docs/22`` §7.3's Banner doubles the chance
#: after it.
EQUIP_TARGET_SYSTEM = 5
EQUIP_BANNER = 8
EQUIP_DAMAGE_ABSORBER = 18
EQUIP_COOLER = 19
BANNER_RANGE = 4

#: ``docs/22`` §7.3 -- the roll is ``aRandom(0, 100)`` and the comparison is
#: ``chance + 10 < roll``, so a weapon at 0 % still connects 11 % of the time.
HIT_BONUS = 10

#: ``docs/22`` §7 -- target ``special`` values that force the hit and the
#: damage.  12 is ``Barrel`` and ``Parabomb``, 13 is ``Case``.  Pinned
#: natively for 13 (``tools/turn_gold.py`` phase 8); 12 carries the same rule
#: in the specification but no shipped unit of that kind stands on ``_C_141``,
#: so it rides on the documentation rather than on a capture.
#:
#: TODO: ``special`` 12 also marks the eight neighbours ``0x53`` (it explodes
#: when hit) and ``special`` 16 (``Bea'Coo``) does the same on death.  Neither
#: is modelled here, and neither can be reached on the captured save.
GUARANTEED_HIT_SPECIALS = frozenset({12, 13})
GUARANTEED_HIT_DAMAGE = 255


def _target_special(world: CombatWorld, unit: CombatUnit) -> int:
    """``unitType[+0x07]`` of a target, or -1 when the type is unknown."""
    info = world.tables.units.get(unit.type_id)
    return -1 if info is None else info.special


#: ``docs/22`` §7.4 -- the sentinel damage value and the one immune unit type.
DAMAGE_SENTINEL = 0xFE
SENTINEL_DAMAGE_DEALT = 2
IMMUNE_UNIT_TYPE = 0x23
#: ``docs/22`` §7.3 and §7.5 -- the one unit type that is exempt from spending
#: ammunition, and that takes a flat 1000 from a type-2 weapon.
NO_AMMO_UNIT_TYPE = 0x42

#: ``docs/22`` §7.2 -- what each cell marker is worth.
MARKER_FULL = 0x50
MARKER_70 = 0x51
MARKER_50 = 0x52
MARKER_FLAT_100 = 0x53
MARKER_FORCED_HIT = 0x54
MARKER_STUN = 0x55
#: ``docs/22`` §7.3 -- the markers the resolver writes back.
MARKER_MISS = 0x5A
MARKER_RESOLVED = 0x5B
MARKER_HIT = 0x5C
MARKER_KILLED = 0x5D

#: ``docs/22`` §7.2 -- the weapon ids whose dispatch entry reports an error.
#: 28 is the ``"-"`` placeholder and 37 is ``Mine``; the other seven are ids
#: ``Info.lcl`` never defines.
NO_PATTERN_WEAPONS = frozenset({18, 19, 28, 33, 34, 35, 37, 38, 39})

#: ``docs/22`` §7.2 -- the sixteen handlers, by the weapon ids that reach them.
#: Named here so a weapon whose family this module does not simulate is a
#: refusal rather than a shot that quietly marks nothing.
PATTERN_FAMILIES: dict[str, frozenset[int]] = {
    "aim_cell_full": frozenset({0, 1, 2, 3, 4, 6, 10, 14, 15, 16, 20, 21,
                                23, 24, 25, 27, 29, 30, 31, 32, 47}),
    "aim_cell_70": frozenset({7}),
    "aim_and_neighbours": frozenset({8, 12, 26, 36}),
    "neighbours_then_aim_70": frozenset({40}),
    "aim_cell_70_null_object": frozenset({42}),
    "aim_cell_full_null_object": frozenset({46}),
    "aim_cell_forced_hit": frozenset({43}),
    "aim_cell_stun": frozenset({45}),
    "explosives_recentred": frozenset({17}),
    "spores_filtered": frozenset({22}),
    "radius_by_range": frozenset({5, 41}),
    "line_of_sight_from_aim": frozenset({9}),
    "special_objects": frozenset({11}),
    "every_unit": frozenset({44}),
    "scatter_18": frozenset({13}),
    "none": NO_PATTERN_WEAPONS,
}

#: The families this module applies.  **All sixteen**, since the third slice;
#: ``"none"`` is the arm that reports an error and returns FALSE, which is
#: modelled as an empty list rather than as a refusal.
SIMULATED_FAMILIES = frozenset(PATTERN_FAMILIES) - {"none"}

#: ``0x0046AE0B`` (weapons 8, 12, 26, 36) -- the eight neighbours in the order
#: the **unrolled** handler writes them.  The order is the order the damage
#: rolls come out in, so it is not a set.
AIM_NEIGHBOUR_ORDER = ((-1, 0), (-1, -1), (-1, 1), (0, -1),
                       (1, -1), (1, 1), (1, 0), (0, 1))

#: ``0x0046AA66`` (weapon 40) -- a *different* unrolled eight, and then the aim
#: cell.  The two differ in their last four entries.
FLAME_B_NEIGHBOUR_ORDER = ((-1, 0), (-1, -1), (-1, 1), (1, 0),
                           (1, -1), (1, 1), (0, 1), (0, -1))

#: ``0x0046B1C7`` -- the radius grows with the range of the shot.
RADIUS_BY_RANGE = ((2, 1), (25, 2))
RADIUS_BEYOND = 3

#: ``0x0046AED2`` (weapon 44) and ``0x0046AF38`` / ``0x0046B0D8`` (weapons 9
#: and 11): the two distance limits, and they are **not the same test** --
#: 44 uses ``< 4`` and the other two ``<= 4``.
EVERY_UNIT_MAX_DISTANCE = 4
ARC_SWEEP_MAX_DISTANCE = 4

#: ``0x0046B0D8`` -- the action-point band weapon 11 hunts for; the same
#: multiplayer victory points ``docs/10`` §4.6 names.
SPECIAL_OBJECT_BAND = (30, 34)

#: ``0x0046AD9F`` -- the scatter: 18 cells, each offset drawn as
#: ``aRandom(-2, 5)``, which is ``base`` and ``span`` and not a closed range.
SCATTER_COUNT = 18
SCATTER_BASE = -2
SCATTER_SPAN = 5

#: ``0x0042FF30``'s refusal, mirrored: a hit chance at or above this is "never".
PATTERN_CHANCE_REFUSED = 254

#: ``0x004308C0``'s direction table (``docs/23`` §8), in the order
#: ``0x0046ACCD`` sweeps it with ``allowDiagonal`` set.  It is **not**
#: :data:`DIRECTION_VECTORS`, which is the facing encoding, and it is not the
#: ``dy``-then-``dx`` order the unrolled handler at ``0x0046AE0B`` writes its
#: eight neighbours in -- so the two patterns cover the same cells in
#: different orders, and the order is what the damage rolls are drawn in.
STEP_DIRECTIONS = ((0, 1), (-1, 0), (0, -1), (1, 0),
                   (1, -1), (-1, 1), (1, 1), (-1, -1))

#: ``docs/22`` §7.4 -- the eight direction codes, from the shooter to the
#: target.  The layout is the doc's own diagram; the rear arc is these three
#: octants wide, which makes it 135 degrees.
DIRECTION_VECTORS = {
    0: (0, 1), 1: (-1, 0), 2: (0, -1), 3: (1, 0),
    4: (1, -1), 5: (-1, 1), 6: (1, 1), 7: (-1, -1),
}
#: ``0x0046A930`` / ``0x0046A9A0`` -- a facing and its two neighbouring octants.
REAR_ARC = {
    0: (0, 5, 6), 1: (1, 5, 7), 2: (2, 4, 7), 3: (3, 4, 6),
    4: (4, 2, 3), 5: (5, 0, 1), 6: (6, 0, 3), 7: (7, 1, 2),
}


class CombatError(Exception):
    """Raised when the model is asked for something it does not simulate."""


def magic_div_2400_plus_1(n: int) -> int:
    """``0x0046A35C`` -- ``n / 2400 + 1``, as the compiler wrote it.

    ``mov eax, 0x1B4E81B5; imul ecx; sar edx, 8; mov eax, edx; shr eax, 31;
    lea ecx, [edx + eax + 1]``.  ``combat_tables.py`` checks this against the
    full height range the 155-file corpus contains, which is why it is written
    out rather than replaced by ``n // 2400 + 1``.
    """
    product = 0x1B4E81B5 * n
    if product < 0:
        product += 1 << 64
    hi = (product >> 32) & 0xFFFFFFFF
    if hi >= 1 << 31:
        hi -= 1 << 32
    hi >>= 8
    sign = 1 if hi < 0 else (hi & 0xFFFFFFFF) >> 31
    return hi + sign + 1


def hit_percent(accuracy: int, range_max: int, distance_fields: int) -> int:
    """``docs/22`` §5.4 -- ``100 - ((101 - acc) / rangeMax) * d``.

    The slope is truncated **before** it is multiplied, which is what makes
    every weapon with ``acc + rangeMax > 101`` flat at 100 %, and what makes
    the Target System a no-op on most weapons.
    """
    return 100 - ((101 - accuracy) // range_max) * distance_fields


def direction(x0: int, y0: int, x1: int, y1: int) -> int:
    """``0x0046A760`` -- the octant from the shooter to the target.

    The thresholds are ``|dy/dx|`` at 0.5 and 1.5 (``0x004B15E0`` and
    ``0x004B15D8``), which is what makes the eight sectors unequal: the four
    axis-aligned ones span 53 degrees and the diagonals 37.
    """
    dx, dy = x1 - x0, y1 - y0
    if dx == 0 and dy == 0:
        return 0
    if dx == 0:
        return 0 if dy > 0 else 2
    ratio = abs(dy / dx)
    if ratio < 0.5:
        return 3 if dx > 0 else 1
    if ratio > 1.5:
        return 0 if dy > 0 else 2
    if dx > 0:
        return 6 if dy > 0 else 4
    return 5 if dy > 0 else 7


#: ``0x0047A8E0``'s three modes.  Only mode 2 is reached from ``endUnitTurn``;
#: mode 0 looks for an action point in the multiplayer band and mode 1 is
#: mode 2 **plus a visibility test**.  The three are modelled together because
#: the difference between 1 and 2 is the interesting part.
FACING_MODE_ACTION_POINT = 0
FACING_MODE_VISIBLE_ENEMY = 1
FACING_MODE_ANY_ENEMY = 2

#: ``0x0047A8E0``'s answer when it finds nobody: the caller skips the write.
FACING_NONE = 0xFF

#: The action-point band mode 0 accepts -- the multiplayer victory points
#: (``docs/10`` §4.6).
FACING_ACTION_POINT_BAND = (30, 34)


def end_turn_facing(world: "CombatWorld", x: int, y: int,
                    mode: int = FACING_MODE_ANY_ENEMY,
                    net_gate: bool = False) -> int:
    """``0x0047A8E0(x, y, mode)`` -- which way the unit on a cell turns.

    ``endUnitTurn`` (``0x0040B380``) calls this with mode 2 and writes the
    answer into ``unit[+0x44]`` unless it is ``0xFF``.  What it does:

    * take the unit standing on ``(x, y)``; no cell or no unit is ``0xFF``;
    * sweep the **whole control map in index order** for a candidate;
    * mode 2 accepts any cell holding a unit of another player, mode 1 the
      same **plus** ``other[+0x4F] == 0`` -- so **the end-of-turn facing does
      not care whether the enemy can be seen.**  A unit turns towards
      something it has no line of sight to, which is the sort of thing a
      remake invents a fog test for and gets wrong;
    * either way the candidate's *species* must not be 2: the table read at
      ``0x51C099 + type * 0x7E`` is ``SetUnitInfo``'s ``+0x79`` column, and
      the three accepted values 0, 1 and 3 are human, alien and machine.
      Props do not attract a turn;
    * the winner is chosen by a **ratchet**: a candidate must have an action
      point byte ``>=`` the best so far **and** be strictly nearer than the
      best so far.  Both halves matter and neither is a plain minimum -- a
      candidate that is nearer but sits on a lower action point loses, and a
      later candidate at the same distance loses to the earlier one.

    The net-session gate (``0x0043B1F0``) suppresses the whole thing between
    two human players; it is false in a campaign, so it defaults to false here
    the way it does everywhere else in this package.
    """
    if not world.in_bounds(x, y):
        return FACING_NONE
    slot = world.unit_at[world.index(x, y)]
    me = world.units.get(slot) if slot >= 0 else None
    if me is None:
        return FACING_NONE
    if not world.action_point:
        raise CombatError(
            "end_turn_facing needs the control map's action points; this "
            "world was built without them")

    best_index = -1
    best_action_point = 0
    best_distance = 0xFFFFFFFF
    low, high = FACING_ACTION_POINT_BAND
    for index in range(world.width * world.height):
        occupant_slot = world.unit_at[index]
        other = world.units.get(occupant_slot) if occupant_slot >= 0 else None
        matched = False
        if mode == FACING_MODE_ACTION_POINT:
            matched = low <= world.action_point[index] <= high
        elif mode in (FACING_MODE_VISIBLE_ENEMY, FACING_MODE_ANY_ENEMY):
            if other is not None and other.player != me.player:
                both_human = (net_gate and other.player <= 4
                              and me.player <= 4)
                if not both_human:
                    matched = (mode == FACING_MODE_ANY_ENEMY
                               or other.visibility == VISIBLE_FULL)
        else:
            raise CombatError(f"0x0047A8E0 has no mode {mode}")
        if not matched:
            continue
        # The routine reads the cell's unit again here **outside** the mode
        # arms, and an empty cell ends the whole scan rather than skipping it.
        # Mode 0 is the only arm that can reach this with an empty cell.
        if other is None:
            return FACING_NONE
        if world.species(other) == SPECIES_OBJECT:
            continue
        cell_x, cell_y = index % world.width, index // world.width
        gap = distance(cell_x, cell_y, x, y)
        if world.action_point[index] >= best_action_point \
                and gap < best_distance:
            best_action_point = world.action_point[index]
            best_distance = gap
            best_index = index
    if best_index < 0:
        return FACING_NONE
    return direction(me.x, me.y, best_index % world.width,
                     best_index // world.width)


def is_rear_shot(attacker_facing: int, defender_facing: int) -> bool:
    """``docs/22`` §7.4 -- the defender is shot in the back.

    True when the attacker is firing **in the same direction the defender is
    looking**, or in either neighbouring octant: three of eight, i.e. a rear
    arc 135 degrees wide.
    """
    return attacker_facing in REAR_ARC.get(defender_facing, ())


def pattern_family(weapon_id: int) -> str:
    """Which of the sixteen handlers ``0x0046AA10`` dispatches this weapon to."""
    for name, ids in PATTERN_FAMILIES.items():
        if weapon_id in ids:
            return name
    raise CombatError(f"weapon {weapon_id} reaches no known target pattern; "
                      f"0x0046AA10 bounds-checks id > 0x2F")


# ---------------------------------------------------------------------------
# The world a shot is resolved against
# ---------------------------------------------------------------------------

@dataclass
class CombatUnit:
    """One unit, reduced to what ``docs/22``'s routines read and write."""

    slot: int
    type_id: int              # +0x4C
    player: int               # +0x45
    x: int                    # +0x42
    y: int                    # +0x43
    hp: int                   # +0x16
    facing: int = 0           # +0x46
    fp: int = 255             # +0x19
    mp: int = 0               # +0x15
    weapon: int = 0           # +0x3F
    ammo: int = 0             # +0x3D
    heat: int = 0             # +0x3E
    malfunction: int = 0      # +0x40
    absorber: int = 0         # +0x3A
    armour_front: int = 0     # +0x36
    armour_rear: int = 0      # +0x37
    action_state: int = 0     # +0x41
    acted: int = 0            # +0x39
    ticket: int = 0           # +0x59
    visibility: int = 0       # +0x4F
    order: int = 0            # +0x47
    order2: int = 0           # +0x49
    order2_param: int = 0     # +0x4A
    order_param: int = 0      # +0x48
    group: int = 0            # +0x4E
    turn_start_x: int = 0     # +0x51
    turn_start_y: int = 0     # +0x52
    #: ``+0x50`` -- tenths of a field walked this turn.  ``aExecuteMove``
    #: writes it, ``docs/21`` §5's ``special`` 4 reads it, and the refresh
    #: zeroes it; nothing in ``docs/22`` touches it, which is why it arrived
    #: here only when the AI started walking units.
    walked: int = 0
    #: ``+0x1A..+0x1F`` in :data:`inclib.lev.SKILL_NAMES` order -- CON, LW, HW,
    #: TS, MS, LS.  A **list**, because the three implant boxes write to it.
    skills: list[int] = field(default_factory=lambda: [0] * 6)
    equipment_ids: frozenset[int] = field(default_factory=frozenset)

    @property
    def alive(self) -> bool:
        return self.hp > 0

    def has(self, equipment_id: int) -> bool:
        return equipment_id in self.equipment_ids


@dataclass
class CombatWorld:
    """The cells and units one attack or one fog pass runs against."""

    width: int
    height: int
    #: Cell heights in world units, row-major.
    cell_height: list[int]
    #: The unit slot standing on each cell, ``-1`` for none.
    unit_at: list[int]
    #: ``+0x10``; a cell whose effect state is 3 takes no damage (``docs/22``
    #: §7.3).  ``2`` is a mine (``docs/26`` §4.1).
    effect_state: list[int]
    units: dict[int, CombatUnit]
    tables: BalanceTables
    ai_level: int = 1
    #: ``docs/22`` §6.1 and §7.4 -- the two- vs four-ray choice and the
    #: three-quarter damage rule both key on this.
    human_players: int = 1
    game_mode: int = 1
    #: ``0x00517F50`` -- one ticket counter per player slot, zeroed by the
    #: hand-over's refresh (``docs/25`` §5), so numbering restarts every turn.
    reaction_counter: list[int] = field(default_factory=lambda: [0, 0, 0, 0])
    #: ``+0x0B`` and ``+0x0D`` -- the two cell bytes interaction reads
    #: (``docs/26``).  Empty by default: nothing in ``docs/22`` touches them,
    #: and :mod:`inclib.interact` refuses a world that did not fill them rather
    #: than reading an index off the end of a list.
    action_point: list[int] = field(default_factory=list)
    field_type: list[int] = field(default_factory=list)
    #: ``0x00509F18`` -- the twelve game-control slots.  Slot 10 is the
    #: mission's equipment-point bonus, which three pickup arms add to.
    game_control: list[int] = field(default_factory=lambda: [0] * 12)
    rng: ARandom = field(default_factory=ARandom)

    def in_bounds(self, x: int, y: int) -> bool:
        return 0 <= x < self.width and 0 <= y < self.height

    def index(self, x: int, y: int) -> int:
        return y * self.width + x

    def height_at(self, x: int, y: int) -> int:
        if not self.in_bounds(x, y):
            return 0
        return self.cell_height[self.index(x, y)]

    def unit_on(self, x: int, y: int) -> CombatUnit | None:
        if not self.in_bounds(x, y):
            return None
        slot = self.unit_at[self.index(x, y)]
        if slot < 0:
            return None
        unit = self.units.get(slot)
        return unit if unit is not None and unit.alive else None

    # --- heights ----------------------------------------------------------

    def full_height(self, unit: CombatUnit | None) -> int:
        """``0x0047AD70`` -- ``unitType[+0x7C] * 160``; 2400 for a null unit."""
        if unit is None:
            return NULL_UNIT_HEIGHT
        row = self.tables.units.get(unit.type_id)
        if row is None:
            return NULL_UNIT_HEIGHT
        return row.height * HEIGHT_LEVEL_UNITS

    def eye_height(self, unit: CombatUnit | None) -> int:
        """``0x0047AD30`` -- half the full height plus 800."""
        if unit is None:
            return NULL_UNIT_HEIGHT
        row = self.tables.units.get(unit.type_id)
        if row is None:
            return NULL_UNIT_HEIGHT
        return row.height * HEIGHT_LEVEL_UNITS // 2 + EYE_BASE

    def size(self, unit: CombatUnit) -> int:
        """``unitType[+0x7B]`` -- the ``size`` column; 1 for a large unit."""
        row = self.tables.units.get(unit.type_id)
        return 0 if row is None else row.size

    def species(self, unit: CombatUnit) -> int:
        row = self.tables.units.get(unit.type_id)
        return 0 if row is None else row.species


# ---------------------------------------------------------------------------
# Line of sight -- docs/22 section 6
# ---------------------------------------------------------------------------

def setup_step(x0: int, y0: int, z0: int, x1: int, y1: int,
               z1: int) -> tuple[float, float, float]:
    """``0x0046D400`` -- a plain DDA, one whole field on the dominant axis.

    ``dz`` is divided by the **Euclidean** distance while the walk advances
    along the dominant axis, so on a perfect diagonal the ray climbs about
    1.41x more slowly than its endpoints imply and arrives low.  That is the
    engine's arithmetic, not a rounding artefact, and a remake that "fixes" it
    changes which shots are blocked.
    """
    slope = abs((y1 - y0) / (x1 - x0)) if x1 != x0 else 1.0
    sy = slope if y1 > y0 else (0.0 if y1 == y0 else -slope)
    sx = 1.0 if x1 > x0 else (0.0 if x1 == x0 else -1.0)
    m = max(abs(sy), abs(sx))
    dz = 0.0
    if z1 != z0:
        d = distance(x0, y0, x1, y1)
        dz = (z1 - z0) / d if d else 0.0
    return sx / m, sy / m, dz


def check_line_of_sight(world: CombatWorld, x0: int, y0: int, z0: int,
                        x1: int, y1: int, z1: int, bias: float) -> int:
    """``0x0046C720`` -- one ray, returning 0, 254 or 255.

    The walk does **not** stop at a block: it runs to the target cell and
    reports the worst thing it met, and terrain wins -- once 255 is set the
    unit test cannot lower it.
    """
    if x0 == x1 and y0 == y1:
        return LOS_CLEAR                        # same cell: always clear
    dx, dy, dz = setup_step(x0, y0, z0, x1, y1, z1)
    if dz > LOS_SLOPE_LIMIT or dz < -LOS_SLOPE_LIMIT:
        return LOS_TERRAIN                      # too steep
    out = LOS_CLEAR
    x, y, z = float(x0), float(y0), float(z0)
    for _ in range(LOS_MAX_STEPS + 1):
        x += dx
        y += dy
        z += dz
        cx, cy = int(x + bias), int(y + bias)
        if cx == x1 and cy == y1:
            return out
        if not world.in_bounds(cx, cy):
            # `aGetCtrlMapElementPtr` off the map is not something the shipped
            # data reaches -- the endpoints are always cells -- but a ray that
            # left the grid has nothing to be blocked by either.
            continue
        cell_h = world.cell_height[world.index(cx, cy)]
        if z < cell_h:
            out = LOS_TERRAIN
        blocker = world.unit_on(cx, cy)
        if (blocker is not None and blocker.x == cx and blocker.y == cy
                and z <= world.full_height(blocker) + cell_h
                and out < LOS_TERRAIN):
            out = LOS_UNIT
    return out


def check_line_of_sight_ex(world: CombatWorld, x0: int, y0: int, z0: int,
                           x1: int, y1: int, z1: int, mode: int) -> int:
    """``0x0046C460`` -- up to four rays, **keeping the smallest** result.

    ``docs/22`` §6.1: a target is visible if any sampled walk is clear, which
    is how the engine lets a shot past a corner without tracing a cone.
    """
    rays: list[tuple[int, int, int, int, int, int, float]]
    if mode == 0:
        rays = [(x1, y1, z1, x0, y0, z0, BIAS_CENTRE)]   # target -> source
    elif world.human_players == 1 and world.game_mode != 2:
        rays = [(x0, y0, z0, x1, y1, z1, BIAS_LOW),
                (x0, y0, z0, x1, y1, z1, BIAS_HIGH)]
    else:
        rays = [(x0, y0, z0, x1, y1, z1, BIAS_LOW),
                (x0, y0, z0, x1, y1, z1, BIAS_HIGH),
                (x1, y1, z1, x0, y0, z0, BIAS_LOW),
                (x1, y1, z1, x0, y0, z0, BIAS_HIGH)]
    best = LOS_TERRAIN
    for ax, ay, az, bx, by, bz, bias in rays:
        best = min(best, check_line_of_sight(world, ax, ay, az, bx, by, bz,
                                             bias))
    return best


# ---------------------------------------------------------------------------
# Hit probability -- docs/22 section 5
# ---------------------------------------------------------------------------

@dataclass
class HitChance:
    """What ``aGetHitProbability`` reports through its two out-parameters."""

    in_range: bool
    percent: int
    distance: int
    blocked: int = LOS_CLEAR

    def to_dict(self) -> dict[str, Any]:
        return {"in_range": self.in_range, "percent": self.percent,
                "distance": self.distance, "blocked": self.blocked}


def combat_distance(world: CombatWorld, attacker: CombatUnit,
                    defender: CombatUnit, weapon_id: int) -> int:
    """``docs/22`` §5.1 -- the distance the range gate and the curve use.

    A large participant costs one field each, and two adjacent cells more than
    ``HEIGHT_STEP`` apart vertically count as further than one field.
    """
    ax, ay = attacker.x, attacker.y
    weapon = world.tables.weapons.get(weapon_id)
    if weapon is not None and weapon.special == 6:
        # "attack the defender's position of the last turn" -- the only
        # consumer of unit +0x51/+0x52, and the confirmation of what they mean.
        bx, by = defender.turn_start_x, defender.turn_start_y
    else:
        bx, by = defender.x, defender.y
    d = distance(ax, ay, bx, by)
    if world.size(attacker) == 1:
        d -= 1
    if world.size(defender) == 1:
        d -= 1
    dh = abs(world.height_at(ax, ay) - world.height_at(bx, by))
    if dh > HEIGHT_STEP and d == 1:
        d = magic_div_2400_plus_1(dh)
    return d


def accuracy_of(world: CombatWorld, attacker: CombatUnit,
                weapon_id: int) -> int:
    """``0x004752E0`` -- the Hit (%) column, doubled by the Target System."""
    weapon = world.tables.weapons.get(weapon_id)
    acc = 0 if weapon is None else weapon.hit
    if acc > 99:
        return 100
    if attacker.has(EQUIP_TARGET_SYSTEM):
        acc *= 2
        if acc > 100:
            acc = 100
    return acc


def banner_nearby(world: CombatWorld, unit: CombatUnit) -> bool:
    """``0x0046FAD0`` in its single-player form -- ``docs/22`` §7.3.

    The scan does not skip the unit it was asked about, so a unit carrying its
    own Banner counts itself.  :mod:`inclib.allowance` documents the same
    routine for the movement allowance; it is one function with two consumers.
    """
    for other in world.units.values():
        if not other.alive or other.player != unit.player:
            continue
        if not other.has(EQUIP_BANNER):
            continue
        if distance(unit.x, unit.y, other.x, other.y) < BANNER_RANGE:
            return True
    return False


def hit_probability(world: CombatWorld, attacker: CombatUnit,
                    defender: CombatUnit, weapon_id: int,
                    apply_los: bool = True) -> HitChance:
    """``aGetHitProbability`` ``0x0046A270`` -- ``docs/22`` §5."""
    d = combat_distance(world, attacker, defender, weapon_id)
    weapon = world.tables.weapons.get(weapon_id)
    if weapon is None:
        return HitChance(False, 0, d)
    if d < weapon.range_min or d > weapon.range_max:
        return HitChance(False, 0, d)

    acc = accuracy_of(world, attacker, weapon_id)
    chance = hit_percent(acc, weapon.range_max, d)
    if not apply_los:
        return HitChance(True, chance, d)

    zoff = ARC_Z_OFFSET if weapon_id in ARCING_WEAPONS else 0
    mode = 0 if (attacker.player == PLAYER_COMPUTER
                 and attacker.order != CLEVER_SMALL_UNITS_ORDER) else 1
    block = check_line_of_sight_ex(
        world, attacker.x, attacker.y,
        world.eye_height(attacker) + zoff + world.height_at(attacker.x,
                                                            attacker.y),
        defender.x, defender.y,
        world.eye_height(defender) + zoff + world.height_at(defender.x,
                                                            defender.y),
        mode)
    if chance < block:
        # Cover is binary: `block` is 0, 254 or 255 and `chance` never exceeds
        # 100, so any obstruction zeroes it.  The subtraction below is not a
        # partial-cover penalty; it can only ever run with `block == 0`.
        return HitChance(True, 0, d, block)
    return HitChance(True, chance - block, d, block)


# ---------------------------------------------------------------------------
# Damage -- docs/22 section 7.4
# ---------------------------------------------------------------------------

def apply_damage(world: CombatWorld, defender: CombatUnit, damage: int,
                 attacker_facing: int) -> int:
    """``0x0046C960`` -- returns the damage actually dealt.

    ``docs/22`` §7.4: the difficulty level **widens the roll upward** rather
    than scaling it -- the floor ``(D+1)/2`` is the same at every level and only
    the span grows -- and fatigue is a multiplier on the receiving end.
    """
    if defender.type_id == IMMUNE_UNIT_TYPE:
        return 0
    if damage == DAMAGE_SENTINEL:
        # Weapon 14, `Enhanced Laser Gun`: exactly 2 HP, ignoring the roll,
        # fatigue, armour and the difficulty level.
        defender.hp = max(defender.hp - SENTINEL_DAMAGE_DEALT, 0)
        return SENTINEL_DAMAGE_DEALT

    # `aRandom` is `(base, span)`, not `(min, max)` -- docs/22 section 3 calls
    # that out precisely because it "changes what every call below means".  So
    # the roll spans `damage` values from the floor upward, and the difficulty
    # level adds one to the **span**: the floor is identical at every level.
    base = (damage + 1) // 2
    if world.ai_level == 0:
        dealt = world.rng(base, damage)
    elif world.ai_level == 1:
        dealt = world.rng(base, damage + 1)
    elif world.ai_level == 2:
        dealt = world.rng(base, damage + 2)
    else:
        raise CombatError("incorrect ai level!")

    if defender.fp == 0:
        dealt += world.rng(0, damage + 1)
        dealt += world.rng(0, damage + 1)
    elif defender.fp == 1:
        dealt += world.rng(0, damage + 1)

    armour = (defender.armour_rear
              if is_rear_shot(attacker_facing, defender.facing)
              else defender.armour_front)
    # `aRandom(armour/2, armour)`: base `armour/2`, span `armour`, so the
    # magnitude lands in `armour/2 .. 3*armour/2 - 1` -- a subtraction, not a
    # percentage.  The engine's second, guarded roll is dead code: the first
    # cannot return less than its own base.
    absorbed = world.rng(armour // 2, armour) if armour else 0
    dealt = dealt - absorbed if dealt > absorbed else 0

    if world.human_players > 1 or world.game_mode == 2:
        # `!isNetworkTurn()` -- this model never runs a network turn.
        dealt = dealt * 3 // 4

    defender.hp = defender.hp - dealt if dealt < defender.hp else 0
    return dealt


# ---------------------------------------------------------------------------
# Overheating -- docs/22 section 8
# ---------------------------------------------------------------------------

#: ``0x0046D1B0``'s outcomes, as names rather than as bare numbers.
OVERHEAT_NONE = "none"
OVERHEAT_JAM = "jam"
OVERHEAT_DAMAGE = "damage"
OVERHEAT_DESTROYED = "destroyed"
OVERHEAT_CLEARED = "cleared"

#: ``docs/22`` §8 -- weapon types whose overheat damages rather than jams.
DAMAGING_WEAPON_TYPES = frozenset({0, 2, 3, 4})


#: ``0x0046D1D6`` -- the span of the overheat roll, a constant and not the
#: weapon's heat cap.  ``docs/22`` §8 said the cap for most of this project's
#: life; the native capture is what settled it.
OVERHEAT_SPAN = 40


def max_heat(world: CombatWorld, unit: CombatUnit) -> int:
    """``0x00475340`` -- ``weapon[+0x3A]``, doubled by the ``Cooler``.

    The Cooler is not purely protective: doubling the cap widens the span of
    ``aRandom(0, heat)`` and therefore the range of bad outcomes (``docs/22``
    §8).
    """
    weapon = world.tables.weapons.get(unit.weapon)
    if weapon is None or weapon.heat == 0xFF:
        return 0xFF
    return weapon.heat * 2 if unit.has(EQUIP_COOLER) else weapon.heat


def check_weapon_damage(world: CombatWorld, unit: CombatUnit) -> str:
    """``aCheckWeaponDamage`` ``0x0046D1B0`` -- called once per attack.

    Does nothing unless the weapon is **exactly** at its cap.  The roll's span
    is the constant :data:`OVERHEAT_SPAN`, **not** the cap: ``0x0046D1D6``
    pushes ``0x28``.  The cap appears only in the gate.  So every weapon that
    can overheat at all can also be destroyed by it, and the ``Cooler`` only
    makes the gate harder to reach.

    A roll above 30 lands on the *same* instruction as the 11-20 / 25-29 arm
    (``0x0046D3B8``), which clears ``+0x40`` -- so it is a clear, not a
    no-op.  Pinned natively over eight probes at the cap.
    """
    cap = max_heat(world, unit)
    if cap == 0xFF or unit.heat != cap:
        return OVERHEAT_NONE
    roll = world.rng(0, OVERHEAT_SPAN)
    weapon = world.tables.weapons.get(unit.weapon)
    weapon_type = 0 if weapon is None else weapon.type
    if 0 <= roll <= 10:
        if weapon_type in DAMAGING_WEAPON_TYPES:
            unit.malfunction = 5
            return OVERHEAT_DAMAGE
        unit.malfunction = 2
        return OVERHEAT_JAM
    if 21 <= roll <= 24:
        unit.malfunction = 5
        return OVERHEAT_DAMAGE
    if roll == 30:
        unit.hp = 0
        return OVERHEAT_DESTROYED
    unit.malfunction = 0
    return OVERHEAT_CLEARED


# ---------------------------------------------------------------------------
# Visibility -- docs/22 section 9
# ---------------------------------------------------------------------------

def set_visible_state(unit: CombatUnit, state: int) -> bool:
    """``aSetVisibleStateForUnit`` -- the only writer of ``+0x4F``.

    State 2 is accepted and ignored; there is no fourth state.
    """
    if not unit.alive:
        return False
    if state in (VISIBLE_FULL, VISIBLE_CONTACT, VISIBLE_HIDDEN):
        unit.visibility = state
        return True
    return False


def build_visible_map_for_unit(world: CombatWorld, observer: CombatUnit,
                               alert: Callable[[int], None] | None = None
                               ) -> bool:
    """``aBuildVisibleMapForUnit`` ``0x00479370`` -- ``docs/22`` §9.3.

    Vision measures from ``fullHeight`` at both ends and accepts ``0xFE``: a
    unit standing in the way blocks a shot but not the sight of it.
    """
    scan = 0
    if observer.has(EQUIP_SCAN_MODULE):
        scan = 1
    if observer.has(EQUIP_LONG_RANGE_SCAN):
        scan = 2

    saw_something = False
    for unit in world.units.values():
        if not unit.alive:
            continue
        if unit.type_id in (0x3D, 0x3E):
            set_visible_state(unit, VISIBLE_FULL)
            continue
        if unit.player == observer.player:
            continue
        if world.species(unit) == SPECIES_OBJECT:
            continue

        block = check_line_of_sight_ex(
            world, observer.x, observer.y,
            world.full_height(observer) + world.height_at(observer.x,
                                                          observer.y),
            unit.x, unit.y,
            world.full_height(unit) + world.height_at(unit.x, unit.y), 1)
        if block < LOS_TERRAIN:
            saw_something = True
            set_visible_state(unit, VISIBLE_FULL)
            if (unit.player == PLAYER_COMPUTER
                    and unit.order in ALERTING_ORDERS and alert is not None):
                alert(unit.group)
        elif unit.visibility != VISIBLE_FULL:
            d = distance(observer.x, observer.y, unit.x, unit.y)
            if scan >= 1 and d < SCAN_RANGE:
                set_visible_state(
                    unit, VISIBLE_CONTACT if scan == 1 else VISIBLE_FULL)
            elif scan == 2 and d < LONG_SCAN_RANGE:
                set_visible_state(unit, VISIBLE_CONTACT)
    return saw_something


def alert_group(world: CombatWorld, group: int) -> int:
    """``0x0047A810`` -- promote the secondary order for a whole AI group.

    Copies ``+0x49``/``+0x4A`` over ``+0x47``/``+0x48``, which is what the
    secondary order in ``docs/10`` §5.6 is *for*.
    """
    woken = 0
    for unit in world.units.values():
        if unit.alive and unit.group == group:
            unit.order, unit.order_param = unit.order2, unit.order2_param
            woken += 1
    return woken


def build_visible_map(world: CombatWorld, player: int) -> None:
    """``aBuildVisibleMap`` ``0x004798C0`` -- the whole fog pass.

    Everything is hidden first and then revealed, so visibility is recomputed
    from scratch on every call: there is no incremental fog state to persist,
    which is why a save carries only ``+0x4F`` and not a fog map.
    """
    for unit in world.units.values():
        if not unit.alive:
            continue
        always = (unit.player == player
                  or world.species(unit) == SPECIES_OBJECT
                  or unit.type_id in ALWAYS_VISIBLE_TYPES)
        set_visible_state(unit, VISIBLE_FULL if always else VISIBLE_HIDDEN)

    for unit in world.units.values():
        if unit.alive and unit.player == player:
            build_visible_map_for_unit(
                world, unit, lambda group: alert_group(world, group))

    # The second pass: a still-hidden neutral unit is promoted to a contact
    # unless one of its eight neighbours is already one -- which shows one blip
    # per cluster instead of one per alien.
    for unit in world.units.values():
        if (not unit.alive or unit.visibility != VISIBLE_HIDDEN
                or unit.player != PLAYER_COMPUTER):
            continue
        neighbour_contact = False
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                other = world.unit_on(unit.x + dx, unit.y + dy)
                if other is not None and other.visibility == VISIBLE_CONTACT:
                    neighbour_contact = True
        if not neighbour_contact:
            set_visible_state(unit, VISIBLE_CONTACT)


# ---------------------------------------------------------------------------
# Resolving an attack -- docs/22 section 7
# ---------------------------------------------------------------------------

@dataclass
class AttackResult:
    """What one ``aAttackUnit`` did -- a value, like every other result here."""

    fired: bool
    reason: str = ""
    overheat: str = OVERHEAT_NONE
    facing: int = 0
    marked: list[tuple[int, int, int]] = field(default_factory=list)
    """``(x, y, marker)`` for every cell the weapon covers."""
    outcomes: list[dict[str, Any]] = field(default_factory=list)
    """One entry per marked cell that held a unit."""

    def to_dict(self) -> dict[str, Any]:
        return {
            "fired": self.fired, "reason": self.reason,
            "overheat": self.overheat, "facing": self.facing,
            "marked": [list(m) for m in self.marked],
            "outcomes": self.outcomes,
        }


def mark_cells(world: CombatWorld, weapon_id: int, tx: int, ty: int,
               shooter: "CombatUnit | None" = None,
               rng: ARandom | None = None) -> list[tuple[int, int, int]]:
    """``0x0046AA10(weapon, aimX, aimY, shooterX, shooterY, shooterFacing)``.

    All sixteen handlers, in the order they write their markers -- which is
    the order the damage rolls come out in, so it is not a set.

    The dispatcher takes **six** arguments and not three.  Its two call sites
    settle what they are: the shot resolver at ``0x0046B6AC`` pushes the
    shooter's ``+0x42``, ``+0x43`` and ``+0x46``, and ``aExecuteBomb``
    (``0x00470318``) passes one value for all three because weapon 36 reads
    none of them.  ``shooter`` therefore carries the last three, and a family
    that needs them refuses when it is absent rather than inventing a default.

    Four things a reading of ``docs/22`` §7.2's table alone gets wrong, all
    cross-checked between the raw listing and Ghidra:

    * **weapons 17 and 22 blast the shooter's own cell**, not the aim cell.
      Both handlers reload ``ebx``/``ebp`` from the argument slots the
      prologue overwrote with the *shooter's* cell pointer and coordinates.
      For ``Explosives`` that is the weapon working as its name says -- a
      charge goes off where it is planted -- and the aim cell is simply
      unused;
    * **weapon 44 is not "every unit on the map"**: it is every unit within
      ``aGetDistance < 4`` of the aim point, and it stamps each cell with
      *that cell's* object id rather than the aim cell's;
    * **weapon 13 falls through** into weapon 42's arm, so the eighteen
      scattered cells are followed by the aim cell at ``0x51``;
    * the two unrolled eight-neighbour handlers write their neighbours in
      **two different orders**, and neither is ``dy``-then-``dx``.
    """
    family = pattern_family(weapon_id)
    if family == "none":
        return []
    if family not in SIMULATED_FAMILIES:                      # pragma: no cover
        raise CombatError(
            f"weapon {weapon_id} uses target pattern {family!r}, which this "
            f"model does not simulate; docs/22 section 7.2 describes it")

    aim_in = world.in_bounds(tx, ty)
    if family in ("aim_cell_full", "aim_cell_full_null_object"):
        return [(tx, ty, MARKER_FULL)] if aim_in else []
    if family in ("aim_cell_70", "aim_cell_70_null_object"):
        return [(tx, ty, MARKER_70)] if aim_in else []
    if family == "aim_cell_forced_hit":
        return [(tx, ty, MARKER_FORCED_HIT)] if aim_in else []
    if family == "aim_cell_stun":
        return [(tx, ty, MARKER_STUN)] if aim_in else []
    if family == "aim_and_neighbours":
        out = [(tx, ty, MARKER_FULL)] if aim_in else []
        return out + _ring(world, tx, ty, AIM_NEIGHBOUR_ORDER, MARKER_70)
    if family == "neighbours_then_aim_70":
        out = _ring(world, tx, ty, FLAME_B_NEIGHBOUR_ORDER, MARKER_70)
        return out + ([(tx, ty, MARKER_70)] if aim_in else [])
    if family == "scatter_18":
        return _scatter(world, tx, ty, rng)
    if family == "every_unit":
        return _every_unit(world, tx, ty)
    if family in ("spores_filtered", "explosives_recentred"):
        return _self_centred_ring(world, family, _shooter(family, shooter))
    if family == "radius_by_range":
        return _radius_by_range(world, tx, ty,
                                _shooter(family, shooter))
    if family == "line_of_sight_from_aim":
        return _arc_sweep(world, tx, ty, _shooter(family, shooter), True)
    # special_objects
    return _arc_sweep(world, tx, ty, _shooter(family, shooter), False)


def _shooter(family: str, shooter: "CombatUnit | None") -> "CombatUnit":
    if shooter is None:
        raise CombatError(
            f"target pattern {family!r} reads the shooter's position and "
            f"facing (0x0046AA10's arguments 4, 5 and 6); none was given")
    return shooter


def _ring(world: CombatWorld, x: int, y: int,
          order: tuple[tuple[int, int], ...],
          marker: int) -> list[tuple[int, int, int]]:
    """The eight neighbours of a cell, in a handler's own write order."""
    return [(x + dx, y + dy, marker) for dx, dy in order
            if world.in_bounds(x + dx, y + dy)]


def _scatter(world: CombatWorld, tx: int, ty: int,
             rng: ARandom | None) -> list[tuple[int, int, int]]:
    """``0x0046AD9F`` -- eighteen cells, then the aim cell.

    **The y offset is drawn before the x offset.**  The two ``aRandom`` calls
    carry source lines 978 and 977 in that order, so the compiler evaluated
    the arguments right to left and the draw order is the reverse of the
    source's.  A model that draws x first agrees on the cells and disagrees on
    every roll that follows in the same turn.

    The draws happen for all eighteen iterations whether or not the cell is on
    the map: the write is bounds-checked and the draw is not.
    """
    if rng is None:
        raise CombatError(
            "target pattern 'scatter_18' draws from aRandom; no generator "
            "was given")
    out: list[tuple[int, int, int]] = []
    for _ in range(SCATTER_COUNT):
        dy = rng(SCATTER_BASE, SCATTER_SPAN)
        dx = rng(SCATTER_BASE, SCATTER_SPAN)
        if world.in_bounds(tx + dx, ty + dy):
            out.append((tx + dx, ty + dy, MARKER_FULL))
    # The fall-through into weapon 42's arm.
    if world.in_bounds(tx, ty):
        out.append((tx, ty, MARKER_70))
    return out


def _every_unit(world: CombatWorld, tx: int,
                ty: int) -> list[tuple[int, int, int]]:
    """``0x0046AED2`` -- every occupied cell within ``< 4`` of the aim."""
    out: list[tuple[int, int, int]] = []
    for index in range(world.width * world.height):
        if world.unit_at[index] < 0:
            continue
        cx, cy = index % world.width, index // world.width
        if distance(tx, ty, cx, cy) < EVERY_UNIT_MAX_DISTANCE:
            out.append((cx, cy, MARKER_FULL))
    return out


def _self_centred_ring(world: CombatWorld, family: str,
                       shooter: "CombatUnit") -> list[tuple[int, int, int]]:
    """``0x0046ACCD`` (spores) and ``0x0046ABD5`` (explosives).

    Both stamp the **shooter's own cell** at ``0x50`` and then walk the
    stepper's eight directions from it.  A neighbour is stamped only when it
    holds a unit -- the ``cell->unit == 0xFFFF`` test comes first in both --
    and then:

    * spores skip an occupant owned by ``0xFC``, the neutral side;
    * explosives stamp a **large** occupant's own ``+0x42``/``+0x43`` instead
      of the stepped cell, because a large unit's record carries the centre of
      the three-by-three it stands on.
    """
    x, y = shooter.x, shooter.y
    out: list[tuple[int, int, int]] = []
    if world.in_bounds(x, y):
        out.append((x, y, MARKER_FULL))
    for dx, dy in STEP_DIRECTIONS:
        nx, ny = x + dx, y + dy
        if not world.in_bounds(nx, ny):
            continue
        slot = world.unit_at[world.index(nx, ny)]
        if slot < 0:
            continue
        occupant = world.units.get(slot)
        if occupant is None:
            continue
        if family == "spores_filtered":
            if occupant.player == PLAYER_NEUTRAL:
                continue
            out.append((nx, ny, MARKER_70))
            continue
        if world.size(occupant) == 1:
            out.append((occupant.x, occupant.y, MARKER_70))
        else:
            out.append((nx, ny, MARKER_70))
    return out


def _radius_by_range(world: CombatWorld, tx: int, ty: int,
                     shooter: "CombatUnit") -> list[tuple[int, int, int]]:
    """``0x0046B1C7`` (weapons 5 and 41) -- a blast that grows with the range.

    The radius comes from how far the shot went, not from the weapon: 1 up to
    two fields, 2 up to twenty-five, 3 beyond.  Inside it, a cell is stamped
    only when it holds a unit, the octant from the shooter to that cell is
    **exactly the shooter's facing**, and ``aGetHitProbability`` answers with
    a chance in ``1..253`` -- the routine calls it with the shooter's own
    weapon and refuses the cell when it fails.
    """
    reach = distance(shooter.x, shooter.y, tx, ty)
    radius = RADIUS_BEYOND
    for limit, value in RADIUS_BY_RANGE:
        if reach <= limit:
            radius = value
            break
    out: list[tuple[int, int, int]] = []
    for index in range(world.width * world.height):
        cx, cy = index % world.width, index // world.width
        if distance(cx, cy, tx, ty) > radius:
            continue
        slot = world.unit_at[index]
        if slot < 0:
            continue
        target = world.units.get(slot)
        if target is None:
            continue
        if direction(shooter.x, shooter.y, cx, cy) != shooter.facing:
            continue
        chance = hit_probability(world, shooter, target, shooter.weapon,
                                 apply_los=True)
        if 0 < chance.percent < PATTERN_CHANCE_REFUSED:
            out.append((cx, cy, MARKER_FULL))
    return out


def _arc_sweep(world: CombatWorld, tx: int, ty: int, shooter: "CombatUnit",
               by_line_of_sight: bool) -> list[tuple[int, int, int]]:
    """``0x0046AF38`` (weapon 9) and ``0x0046B0D8`` (weapon 11).

    The two share a shape and differ in what they look for: weapon 9 wants a
    unit the shooter can **see**, weapon 11 wants a cell whose action point is
    in the multiplayer band 30..34 and does not care what stands on it.  Both
    then require the octant from the shooter to the cell to lie in the
    **three-octant arc** around the shooter's facing -- ``0x0046A9A0`` and
    ``0x0046A930`` are the two neighbours -- and the cell to be within four
    fields of the aim point.
    """
    low, high = SPECIAL_OBJECT_BAND
    out: list[tuple[int, int, int]] = []
    for index in range(world.width * world.height):
        cx, cy = index % world.width, index // world.width
        if by_line_of_sight:
            slot = world.unit_at[index]
            if slot < 0:
                continue
            target = world.units.get(slot)
            if target is None:
                continue
            blocked = check_line_of_sight_ex(
                world, cx, cy,
                world.cell_height[index] + world.eye_height(target),
                shooter.x, shooter.y,
                world.cell_height[world.index(shooter.x, shooter.y)]
                + world.eye_height(shooter), 1)
            if blocked >= LOS_TERRAIN:
                continue
        else:
            if not world.action_point:
                raise CombatError(
                    "target pattern 'special_objects' reads the control "
                    "map's action points; this world was built without them")
            if not low <= world.action_point[index] <= high:
                continue
        octant = direction(shooter.x, shooter.y, cx, cy)
        if shooter.facing not in REAR_ARC[octant]:
            continue
        if distance(cx, cy, tx, ty) > ARC_SWEEP_MAX_DISTANCE:
            continue
        out.append((cx, cy, MARKER_FULL))
    return out


def marker_damage(world: CombatWorld, marker: int, weapon_id: int) -> int:
    """``docs/22`` §7.2 -- what the marker is worth at that cell."""
    weapon = world.tables.weapons.get(weapon_id)
    full = 0 if weapon is None else weapon.damage
    if marker == MARKER_FULL:
        return full
    if marker == MARKER_70:
        return (full * 70 + 1) // 100
    if marker == MARKER_50:
        return (full * 50 + 1) // 100
    if marker == MARKER_FLAT_100:
        return 100
    return 0                          # 0x54 and 0x55 roll no damage at all


def attack_unit(world: CombatWorld, x: int, y: int, tx: int,
                ty: int) -> AttackResult:
    """``aAttackUnit`` ``0x0046B450`` -- ``docs/22`` §7, in the order it runs.

    Three things the code gives that the data files cannot:

    * **line of sight is not re-checked** in the resolver -- ``applyLOS`` is
      false there, so a target the marking pass accepted is hit without a
      second cover test;
    * **a target outside the weapon's range still resolves**, using the raw
      ``Hit (%)`` column as its chance, which is how splash reaches past
      ``range max``;
    * **the ``+10`` bonus is unconditional**, so a weapon at 0 % connects on a
      roll of 0..9.
    """
    attacker = world.unit_on(x, y)
    if attacker is None:
        return AttackResult(False, "no attacker on that cell")

    # If a unit stands on the aim point, the aim point becomes **that unit's
    # own** cell -- which matters for units occupying more than one field.
    standing = world.unit_on(tx, ty)
    if standing is not None:
        tx, ty = standing.x, standing.y

    result = AttackResult(True)
    result.overheat = check_weapon_damage(world, attacker)
    if attacker.malfunction != 0 or attacker.hp == 0:
        result.fired = False
        result.reason = ("the weapon jammed or was destroyed"
                         if attacker.malfunction else "the attacker is dead")
        return result

    attacker.facing = direction(x, y, tx, ty)
    result.facing = attacker.facing
    result.marked = mark_cells(world, attacker.weapon, tx, ty,
                               shooter=attacker, rng=world.rng)

    weapon = world.tables.weapons.get(attacker.weapon)
    banner = banner_nearby(world, attacker)
    for cx, cy, marker in result.marked:
        target = world.unit_on(cx, cy)
        if target is None:
            continue
        if world.effect_state[world.index(cx, cy)] == 3:
            # docs/22 section 7.3: a cell whose effect state is 3 takes nothing.
            result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
                                    "marker": MARKER_RESOLVED, "dealt": 0,
                                    "chance": 0, "roll": 0})
            continue

        chance_result = hit_probability(world, attacker, target,
                                        attacker.weapon, apply_los=False)
        chance = (chance_result.percent if chance_result.in_range
                  else (0 if weapon is None else weapon.hit))
        if banner:
            chance *= 2
        damage = marker_damage(world, marker, attacker.weapon)
        roll = world.rng(0, 100)
        if marker == MARKER_FORCED_HIT:
            chance, roll = 0, 1
        elif marker == MARKER_STUN:
            chance, roll = 1, 0
        if _target_special(world, target) in GUARANTEED_HIT_SPECIALS:
            # docs/22 section 7: `special` 12 (Barrel, Parabomb) and 13 (Case)
            # force the hit and the damage.  The roll is still **drawn** -- the
            # native capture shows two draws against a Case whether or not the
            # roll would have connected, against one for a miss on an ordinary
            # target -- so this overrides the comparison, not the generator.
            chance, roll = 0, 1
            damage = GUARANTEED_HIT_DAMAGE

        if chance + HIT_BONUS < roll:
            result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
                                    "marker": MARKER_MISS, "dealt": 0,
                                    "chance": chance, "roll": roll})
            continue

        if marker == MARKER_STUN:
            # No damage is rolled; unless a Damage Absorber charge is spent the
            # target's action state becomes 5 and its movement points 0 -- it
            # loses the rest of its turn.
            # **Read before the charge is spent.**  With exactly one charge
            # the unit spends it and is *not* stunned, and `not
            # target.absorber` evaluated after the decrement said the
            # opposite.  `godot/core/combat.gd` had it right, which is how the
            # two came to disagree.
            stunned = not target.absorber
            if target.absorber:
                target.absorber -= 1
            else:
                target.action_state = 5
                target.mp = 0
            result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
                                    "marker": MARKER_RESOLVED, "dealt": 0,
                                    "chance": chance, "roll": roll,
                                    "stunned": stunned})
            continue

        if target.absorber:
            # docs/22 section 7.5: a charge nullifies the damage entirely.
            target.absorber -= 1
            dealt = 0
        else:
            dealt = apply_damage(world, target, damage, attacker.facing)
        killed = not target.alive
        if killed:
            world.unit_at[world.index(target.x, target.y)] = -1
        result.outcomes.append({
            "slot": target.slot, "x": cx, "y": cy,
            "marker": MARKER_KILLED if killed else MARKER_HIT,
            "dealt": dealt, "chance": chance, "roll": roll})

    # After the shot: ammunition and heat.
    if weapon is not None:
        # docs/22 section 7.5 gates on **both** halves: a weapon whose `mun`
        # column is 255 spends nothing, and neither does unit type 0x42.
        # Dropping the second half would quietly disarm that one type.
        if weapon.mun != 0xFF and attacker.type_id != NO_AMMO_UNIT_TYPE:
            # The engine's `+0x3D` is a `u8` and wraps; this model keeps the
            # signed value, so a negative count is visible rather than
            # arriving as 250-something.  Nothing in this stage fires often
            # enough to reach it, and a native capture is what would settle
            # whether the wrap is ever observed.
            attacker.ammo -= weapon.mun_per_fight
        cap = max_heat(world, attacker)
        if cap != 0xFF and attacker.heat < cap:
            attacker.heat += 1
    return result


# ---------------------------------------------------------------------------
# aExecuteBomb -- docs/26 section 4
# ---------------------------------------------------------------------------

#: ``docs/21`` §4 -- ``ParaBomb``.  A mine resolves as a shot from this weapon.
BOMB_WEAPON = 36


def execute_bomb(world: CombatWorld, x: int, y: int) -> AttackResult:
    """``aExecuteBomb`` ``0x004702C0`` -- a weapon-36 shot with no shooter.

    ``docs/26`` §4 quotes the push's own call site: an object pushed onto a
    mine frees the effect object and detonates it here.  The marking pass is
    ``0x0046AA10`` exactly as an attack uses it, so the footprint is the
    ``aim_and_neighbours`` family -- full damage on the centre and 70 % around
    it.

    **UNVERIFIED in one respect, and it is the same one ``docs/26`` §10 item 6
    records.**  The sibling path -- a mine *stepped* on during a walk -- was
    probed natively and did **not** detonate: the seed, the mover's hit points
    and the cell's ``+0x10`` were all unchanged.  The push path has never been
    probed.  What is modelled here is the documented arm; if a later capture
    shows the push behaves like the step, this is the function to delete.

    The rear-arc test needs a facing and a bomb has no shooter, so the heading
    from the centre to each target is used.  Nothing in the disassembly names
    the value the engine passes; a target standing *on* the centre gets
    heading 0 either way, which is the only case the shipped data reaches.
    """
    result = AttackResult(True, "bomb")
    # aExecuteBomb (0x00470318) passes one value for all three of the
    # shooter arguments because weapon 36 reads none of them.
    result.marked = mark_cells(world, BOMB_WEAPON, x, y)
    weapon = world.tables.weapons.get(BOMB_WEAPON)
    for cx, cy, marker in result.marked:
        target = world.unit_on(cx, cy)
        if target is None:
            continue
        if world.effect_state[world.index(cx, cy)] == 3:
            continue
        chance = 0 if weapon is None else weapon.hit
        damage = marker_damage(world, marker, BOMB_WEAPON)
        roll = world.rng(0, 100)
        if chance + HIT_BONUS < roll:
            result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
                                    "marker": MARKER_MISS, "dealt": 0,
                                    "chance": chance, "roll": roll})
            continue
        if target.absorber:
            target.absorber -= 1
            dealt = 0
        else:
            dealt = apply_damage(world, target, damage,
                                 direction(x, y, cx, cy))
        killed = not target.alive
        if killed:
            world.unit_at[world.index(target.x, target.y)] = -1
        result.outcomes.append({
            "slot": target.slot, "x": cx, "y": cy,
            "marker": MARKER_KILLED if killed else MARKER_HIT,
            "dealt": dealt, "chance": chance, "roll": roll})
    return result


# ---------------------------------------------------------------------------
# Reaction fire -- docs/25 section 6
# ---------------------------------------------------------------------------

#: ``docs/21`` §4 -- ``weapon[+0x32]``.  The **Def** button's eligibility test
#: is ``def_mode & 1``; the AI's automatic end-of-turn pass tests
#: ``== 1 || == 4``.  The two disagree only on 4, which the shipped table never
#: uses, so both are written out rather than folded into one predicate.
DEF_MODE_AUTOMATIC = frozenset({1, 4})

#: ``0x004753E0`` -- the movement points a unit must still hold, and the
#: ``+0x39`` value ``0x00478500`` stamps.
OVERWATCH_MIN_MP = 2
OVERWATCH_ACTED = 3

#: ``+0x41 == 1`` -- a reaction is pending.  ``docs/21`` §5's table for the
#: field; ``docs/25`` §6 for what does and does not clear it.
ACTION_WAITING = 1

#: ``docs/25`` §6 -- the drain fires in ticket order in ``campaign`` mode and
#: in slot order in every other.  The tickets are written either way.
GAME_MODE_CAMPAIGN = 1


def may_enter_defence(world: CombatWorld, unit: CombatUnit) -> bool:
    """``0x004753E0`` -- the **Def** button's own eligibility test.

    Four gates and then the flag: two movement points, no malfunction, some
    ammunition, and not already waiting.  The return is ``def_mode & 1``, so a
    weapon whose column is 4 is refused *here* and accepted by the automatic
    pass -- see :func:`auto_enter_defence`.
    """
    if unit.mp < OVERWATCH_MIN_MP:
        return False
    if unit.malfunction != 0:
        return False
    if unit.ammo == 0:
        return False
    if unit.action_state == ACTION_WAITING:
        return False
    weapon = world.tables.weapons.get(unit.weapon)
    return bool(0 if weapon is None else weapon.def_mode & 1)


def auto_enter_defence(world: CombatWorld, unit: CombatUnit) -> bool:
    """``0x0040A710`` -- the AI's end-of-turn pass, as a predicate.

    ``0x00409940`` walks all 200 slots and calls this for every unit that still
    holds two movement points; the test here is on the weapon column alone.
    """
    if unit.mp < OVERWATCH_MIN_MP:
        return False
    weapon = world.tables.weapons.get(unit.weapon)
    return weapon is not None and weapon.def_mode in DEF_MODE_AUTOMATIC


def enter_defence(world: CombatWorld, unit: CombatUnit) -> int:
    """``0x00478500`` -- put a unit on overwatch and hand it a ticket.

    Returns the ticket.  ``docs/21`` §4: a unit that was **already** waiting
    loses its remaining movement points, which is what makes pressing Def twice
    an act rather than a no-op.  The order matters -- the old state is read
    before the new one is written.
    """
    was_waiting = unit.action_state == ACTION_WAITING
    unit.action_state = ACTION_WAITING
    unit.acted = OVERWATCH_ACTED
    world.reaction_counter[unit.player & 3] += 1
    unit.ticket = world.reaction_counter[unit.player & 3]
    if was_waiting:
        unit.mp = 0
    return unit.ticket


def in_front_arc(reactor: CombatUnit, mover: CombatUnit) -> bool:
    """``0x004790F0`` -- is the mover inside the reactor's 135 degree front?

    The heading from the reactor to the mover (``0x0046A760``) and its two
    neighbouring octants; true when the reactor's own facing is one of the
    three.  The same shape ``docs/22`` §7.4 uses for rear armour, read from the
    other end.
    """
    heading = direction(reactor.x, reactor.y, mover.x, mover.y)
    return reactor.facing in REAR_ARC.get(heading, ())


@dataclass
class Reaction:
    """One shot the drain took, as a value."""

    reactor: int
    ticket: int
    attack: AttackResult

    def to_dict(self) -> dict[str, Any]:
        return {"reactor": self.reactor, "ticket": self.ticket,
                "attack": self.attack.to_dict()}


def reaction_candidates(world: CombatWorld,
                        mover: CombatUnit) -> list[CombatUnit]:
    """``0x0046CCA0``'s six conditions, in the order ``docs/25`` §6 lists them.

    The chance test is the expensive one and stays last, exactly as the engine
    orders it: a reactor that is dead, unwaiting, empty or overheated never
    reaches the line-of-sight walk.
    """
    out: list[CombatUnit] = []
    for reactor in world.units.values():
        if not reactor.alive or reactor.player == mover.player:
            continue
        if reactor.action_state != ACTION_WAITING:
            continue
        if reactor.ammo == 0:
            continue
        cap = max_heat(world, reactor)
        if cap != 0xFF and reactor.heat >= cap:
            continue
        chance = hit_probability(world, reactor, mover, reactor.weapon)
        if not chance.in_range or chance.percent <= 0:
            continue
        if not (banner_nearby(world, reactor) or in_front_arc(reactor, mover)):
            continue
        out.append(reactor)
    return out


def drain_reactions(world: CombatWorld, mover: CombatUnit) -> list[Reaction]:
    """``0x0046CCA0`` -- every enemy on overwatch shoots the unit that moved.

    Two branches, and the difference is the **order**, never the membership.
    In ``campaign`` mode the queue is drained by ticket from 1 upward -- the
    unit that went on overwatch first shoots first -- and in every other mode
    the 200 slots are walked in index order.  The tickets are written either
    way, so a save carries them whatever the mode.

    Three rules this is deliberately literal about, because ``docs/25`` §6 says
    an implementation is most likely to get them wrong:

    * **nothing here clears ``+0x41``.**  A unit stays on overwatch and fires at
      every enemy that walks past, until the hand-over clears it or it runs out
      of ammunition;
    * the reactor's facing is saved before the shot and restored after it, so
      overwatch does not end up staring at whatever it last shot at;
    * if the mover dies the drain returns immediately -- the reactors behind it
      in the queue keep their tickets and their turn comes round again.
    """
    fired: list[Reaction] = []
    if not mover.alive:
        return fired
    candidates = reaction_candidates(world, mover)
    by_slot = sorted(candidates, key=lambda u: u.slot)
    if world.game_mode == GAME_MODE_CAMPAIGN:
        # **The ticket loop starts at 1, not at 0.**  A waiting unit whose
        # ticket is 0 is therefore never found by it, and no shipped path
        # produces one -- `enter_defence` always stamps at least 1 -- but a
        # save or a script can, and the two branches disagree about it.
        highest = max((u.ticket for u in by_slot), default=0)
        order: list[CombatUnit] = []
        for ticket in range(1, highest + 1):
            order += [u for u in by_slot if u.ticket == ticket]
    else:
        order = by_slot
    for reactor in order:
        facing = reactor.facing
        result = attack_unit(world, reactor.x, reactor.y, mover.x, mover.y)
        reactor.facing = facing
        fired.append(Reaction(reactor.slot, reactor.ticket, result))
        if not mover.alive:
            break
    return fired


# ---------------------------------------------------------------------------
# Building one from a mission
# ---------------------------------------------------------------------------

def world_from_map(bm: Any, tables: BalanceTables,
                   seed: float = 1.0) -> CombatWorld:
    """One mission as the world an attack, a fog pass or a Use runs against.

    Fills the interaction cells (``+0x0B`` and ``+0x0D``) as well as the combat
    ones, so ``combat_runtime.py`` and ``interact_runtime.py`` build **the
    same** world from the same ``.lev`` rather than two that agree by
    coincidence.  ``bm`` is an :class:`inclib.lev.BattleMap`; it is typed
    loosely here because importing ``lev`` would make this module depend on the
    file format it is deliberately independent of.
    """
    cells = bm.cells
    units: dict[int, CombatUnit] = {}
    for u in bm.units:
        if not u.placed:
            continue
        units[u.slot] = CombatUnit(
            slot=u.slot, type_id=u.type_id, player=u.player, x=u.x, y=u.y,
            hp=u.hit_points, facing=u.facing, fp=u.fp, mp=u.action_points,
            weapon=u.weapon, ammo=u.ammo, heat=u.heat,
            malfunction=u.malfunction, absorber=u.absorb,
            armour_front=u.armour_front, armour_rear=u.armour_rear,
            action_state=u.action_state, acted=u.acted, ticket=u.ticket,
            visibility=u.visibility,
            order=u.order, order_param=u.order_param, order2=u.order2,
            order2_param=u.order2_param, group=u.group,
            turn_start_x=u.turn_start_x, turn_start_y=u.turn_start_y,
            walked=u.walked,
            skills=list(u.skills), equipment_ids=frozenset(u.equipment_ids))
    return CombatWorld(
        width=bm.width, height=bm.height,
        cell_height=[c.height for c in cells],
        unit_at=[-1 if c.unit is None else c.unit for c in cells],
        effect_state=[c.raw[0x10] for c in cells],
        action_point=[c.action_point for c in cells],
        field_type=[c.field_type for c in cells],
        units=units, tables=tables, rng=ARandom(seed))
