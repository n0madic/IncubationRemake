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
  the neighbour-cluster promotion.

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

#: The families this module actually applies.  The rest are named above and
#: raise: a model that marked nothing for them would look like a clean miss.
SIMULATED_FAMILIES = frozenset({
    "aim_cell_full", "aim_cell_70", "aim_and_neighbours",
    "neighbours_then_aim_70", "aim_cell_70_null_object",
    "aim_cell_full_null_object", "aim_cell_forced_hit", "aim_cell_stun",
})

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
    visibility: int = 0       # +0x4F
    order: int = 0            # +0x47
    order2: int = 0           # +0x49
    order2_param: int = 0     # +0x4A
    order_param: int = 0      # +0x48
    group: int = 0            # +0x4E
    turn_start_x: int = 0     # +0x51
    turn_start_y: int = 0     # +0x52
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
    #: §7.3).
    effect_state: list[int]
    units: dict[int, CombatUnit]
    tables: BalanceTables
    ai_level: int = 1
    #: ``docs/22`` §6.1 and §7.4 -- the two- vs four-ray choice and the
    #: three-quarter damage rule both key on this.
    human_players: int = 1
    game_mode: int = 1
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
    is the cap itself, so a weapon capped at 10 can never destroy its carrier
    and one capped at 31 or more can.
    """
    cap = max_heat(world, unit)
    if cap == 0xFF or unit.heat != cap:
        return OVERHEAT_NONE
    roll = world.rng(0, unit.heat)
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


def mark_cells(world: CombatWorld, weapon_id: int, tx: int,
               ty: int) -> list[tuple[int, int, int]]:
    """``0x0046AA10`` -- the covered cells and their markers, for the simple
    families.

    ``docs/22`` §7.2's other eight handlers -- the radius that widens with the
    shot, the line-of-sight sweep, the whole-map sweep, the 18-cell scatter,
    the re-centred explosion and the filtered spores -- raise instead of
    marking nothing, so a model that cannot resolve a shot says so.
    """
    family = pattern_family(weapon_id)
    if family == "none":
        return []
    if family not in SIMULATED_FAMILIES:
        raise CombatError(
            f"weapon {weapon_id} uses target pattern {family!r}, which this "
            f"model does not simulate; docs/22 section 7.2 describes it")

    neighbours = [(tx + dx, ty + dy)
                  for dy in (-1, 0, 1) for dx in (-1, 0, 1)
                  if (dx or dy) and world.in_bounds(tx + dx, ty + dy)]
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
        return out + [(x, y, MARKER_70) for x, y in neighbours]
    # neighbours_then_aim_70 -- the order is the handler's own.
    out = [(x, y, MARKER_70) for x, y in neighbours]
    return out + ([(tx, ty, MARKER_70)] if aim_in else [])


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
    result.marked = mark_cells(world, attacker.weapon, tx, ty)

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

        if chance + HIT_BONUS < roll:
            result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
                                    "marker": MARKER_MISS, "dealt": 0,
                                    "chance": chance, "roll": roll})
            continue

        if marker == MARKER_STUN:
            # No damage is rolled; unless a Damage Absorber charge is spent the
            # target's action state becomes 5 and its movement points 0 -- it
            # loses the rest of its turn.
            if target.absorber:
                target.absorber -= 1
            else:
                target.action_state = 5
                target.mp = 0
            result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
                                    "marker": MARKER_RESOLVED, "dealt": 0,
                                    "chance": chance, "roll": roll,
                                    "stunned": not target.absorber})
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
