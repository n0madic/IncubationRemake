"""The computer's turn -- ``docs/23``, executable.

Like :mod:`inclib.combat` this is **behaviour, not a file format**: nothing
here is stored on disk.  It is the third of the executable models
(``docs/94``), and the one the second slice named as missing -- an opponent
that moves, closes and shoots.

The shape is the engine's, function for function:

``aAISystemControl`` (:func:`run_turn`) sweeps the 200-slot unit array twice,
once for ranged weapons and once for everyone, with a six-level search horizon
inside each pass and a ``repeat`` that re-runs a sweep whenever something
actually committed.  Each unit dispatches on its order byte to one of eleven
handlers (:func:`run_order`), and those handlers do two things: shoot
(:func:`fire`) and plan one action (:func:`plan`).

Three properties this module keeps deliberately, because a paraphrase loses
them and the loss is silent:

* **the overlay is state, not a return value.**  ``cell[+0x00]`` and
  ``cell[+0x0C]`` are written by the fill, read by the scoring pass, read
  again by the approach-cell scan and by the path walk, and order 9 reads a
  *target* overlay left by a pass over the enemies.  :class:`AIContext` holds
  the two arrays for exactly that reason;
* **the tie-breaks are part of the answer.**  ``s >= bestScore`` in the target
  scan (the later cell wins), ``v >= best`` in the path walk (the later
  direction wins), ``mp >= best`` in the approach scan for a small mover but
  ``mp > best`` for a large one, and slots swept 0…199.  Each is marked where
  it happens;
* **every ``aRandom`` draw is the engine's.**  The turn is a long chain of
  them -- order 9's coin flip, and one per damage roll inside every shot --
  and a single extra or missing draw makes every later comparison meaningless.

Two deliberate departures from ``docs/23``'s C sketch, both because the
disassembly says otherwise, and both re-checked against ``0x0040B0D0`` and
``0x0040A750`` while writing this:

* the cover score's two float conversions go through ``MSVCRT._ftol``, which
  **truncates**; the document writes them as ``+ 0.5`` rounding.  See
  :func:`cover_score`;
* ``plan`` returns TRUE, not FALSE, when the reconstructed path has zero
  steps.  See :func:`plan`.

``tools/ai_runtime.py --check`` runs all of it over every shipped mission that
places an alien; ``tools/ai_gold.py`` pins the pieces against the live engine.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Sequence

from . import combat as combatmod
from . import movemap
from .allowance import AllowanceUnit, movement_allowance
from .combat import CombatUnit, CombatWorld

LOG = logging.getLogger("ai")


class AIError(Exception):
    """Raised when the model is handed state it cannot run against."""


# ---------------------------------------------------------------------------
# Names -- docs/23 sections 3, 5 and 6
# ---------------------------------------------------------------------------

#: ``docs/10`` §5.6 -- the eleven order names, in the editor's own order.
ORDER_NAMES = (
    "Berserk", "Move (ActPt)", "Attack (ActPt)", "Move (Group)",
    "Attack (Group)", "Turn (Wait)", "Range (Wait)", "Defend",
    "Visibility (Wait)", "Clever small units", "Disturb",
)
ORDER_COUNT = len(ORDER_NAMES)

#: ``docs/23`` §3 -- the arm every order above 10 lands on, which is also
#: order 8's and the common epilogue.
ORDER_DEFAULT = 8

ORDER_BERSERK = 0
ORDER_MOVE_ACTPT = 1
ORDER_ATTACK_ACTPT = 2
ORDER_MOVE_GROUP = 3
ORDER_ATTACK_GROUP = 4
ORDER_TURN_WAIT = 5
ORDER_RANGE_WAIT = 6
ORDER_DEFEND = 7
ORDER_VISIBILITY_WAIT = 8
ORDER_CLEVER = 9
ORDER_DISTURB = 10

#: ``docs/23`` §2 -- two passes and six levels, and nothing selects either.
PASSES = 2
MAX_LEVEL = 5

#: ``0x0040A440``'s two modes: 8 is "any enemy", 9 restricts to one group.
FIRE_ANY = 8
FIRE_GROUP = 9

#: ``docs/23`` §5.2 -- ``kind - 1`` indexes twelve entries.
KIND_ALLY = 1
KIND_ENEMY = 2
KIND_ALLY_SHORT = 3
KIND_ACTION_POINT = 6
KIND_GROUP = 7
KIND_COVER = 10
KIND_DOOR = 11
KIND_ENEMY_READY = 12
#: The four the planner's table reserves as fall-through.  8 and 9 belong to
#: :func:`fire`; 4 and 5 have no code in either shipped binary.
KIND_FALL_THROUGH = frozenset({4, 5, 8, 9})
KIND_MIN = 1
KIND_MAX = 12

#: ``docs/23`` §5.1 -- ``(movement points, may pass friendly units)`` per
#: level.  ``None`` means "the unit's own", and level 1 doubles it.
HORIZON_MP: tuple[int | None, ...] = (None, None, 30, 50, 100, 250)
HORIZON_PASS_FRIENDLIES = (False, False, True, False, False, False)

#: ``docs/10`` §4.6 -- *standard Door — CLOSED*, the action point kind 11 and
#: the door opener both look for.
ACTION_POINT_CLOSED_DOOR = 31

#: ``docs/23`` §6 -- the five markers, and the hit-percentage thresholds that
#: choose between them.  ``bisect``-free on purpose: the engine writes the
#: comparisons out and so does this.
TARGET_MARKER_MIN = 30
TARGET_MARKER_MAX = 34
TARGET_BANDS = ((20, 30), (50, 31), (70, 32), (90, 33))
TARGET_MARKER_TOP = 34

#: The three markers ``0x0042FF30``'s other three arms write, which the fire
#: routine's ``30 <= s <= 34`` window then ignores.  Named so that "weapon 40
#: never finds an AI target" reads as a fact about this table rather than as an
#: omission.
MARKER_SPECIAL_OBJECT = 35
MARKER_EMPTY_GROUND = 36
MARKER_ANY_UNIT = 37

#: ``0x004303A8`` -- which arm of ``0x0042FF30`` each weapon id reaches.
#: Index by weapon id; the value indexes :data:`OVERLAY_ARMS`.
OVERLAY_FAMILY = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    10, 10, 1, 1, 1, 1, 1, 1, 1, 1, 10, 2, 2, 2, 2,
    10, 10, 10, 10, 10, 10, 10, 3, 4, 5, 6, 7, 7, 8, 9,
)
#: ``0x0040437C`` -- what each family does.  ``"units"`` is the hit-probability
#: sweep of §6; the other three stamp markers outside the AI's window, and
#: ``"error"`` is the ``"unknown weapon"`` arm.
#: The three kinds of work worth counting -- the three a turn is made of, and
#: the three `godot/bench.gd` measures the cost of one of.
WORK_FILL = "fills"
WORK_OVERLAY = "target_overlays"
WORK_HIT_CHANCE = "hit_chances"
WORK_PLAN = "plans"
WORK_FIRE = "fires"

OVERLAY_ARMS = ("units", "units", "units", "special_objects", "units",
                "empty_ground", "any_unit", "units", "empty_ground", "units",
                "error")

#: ``0x0042FF30``'s first gate: a unit this tired stamps nothing at all.
MIN_FITNESS_TO_AIM = 1
#: The id ``0x0042FF30`` returns TRUE on before it dispatches -- "No Weapon".
WEAPON_NONE = 28

#: ``0x0042FE90`` -- the species whose markers the prune pass clears.
SPECIES_OBJECT = 2
#: ``0x0040B080`` -- the species kinds 1 and 3 regroup with.
SPECIES_ALIEN = 1

#: ``docs/22`` §9.1 -- overlay stamping only ever considers a fully visible
#: target.
VISIBILITY_VISIBLE = 0

#: The two unit types ``0x0042FF30`` refuses to aim at outright.
TYPE_NEVER_TARGET = 0x3D
TYPE_IMMUNE = 0x23

#: ``docs/23`` §5.2 -- ``0x0040B080``'s three movement-point caps, in the order
#: kinds 1 and 3 try them.
ALLY_CAPS_FULL = (0, 2, 255)
ALLY_CAPS_SHORT = (0, 255)

#: ``0x0040ADC0`` -- the height difference an approach cell may have from the
#: target, **after** the divide by 1600.  Looser than the movement rule's 1.
APPROACH_CLIMB_MAX = 2
#: What the scan returns for the cell the mover is already standing on.
APPROACH_OWN_CELL_SCORE = 10000

#: ``0x0040B0D0`` -- the wall field type each neighbour of a candidate adds a
#: point for, and the multiplier on the distance to the furthest enemy.
COVER_WALL_FIELD_TYPE = 2
COVER_DISTANCE_NUMERATOR = 3
COVER_DISTANCE_DENOMINATOR = 2
#: The alignment term the three out-of-bounds reads add.  ``docs/23`` §5.2
#: proves the two bytes are 66 past the end of an 18200-byte ``malloc`` block
#: and therefore heap history rather than game state; what the term computes is
#: +10 for every cell except one map row and one map column, so **on a map no
#: larger than 40x40 it is this constant** whenever either byte is >= 40.
#: Reproducing it as a constant is exact in that case and is not the same as
#: dropping it: the maximiser's incumbent starts at 0, so a candidate whose
#: score is 0 is selected with the term and refused without it.
#: ``ai_gold.py`` reads the two bytes and checks they are off the map.
COVER_ALIGNMENT_BONUS = 10

#: ``0x00475340`` -- the heat cap that turns the mechanic off.
HEAT_DISABLED = 255

#: ``0x0040A600`` -- the door opener refuses below this many movement points.
DOOR_MIN_MP = 2
DOOR_MP_COST = 1

#: ``0x00409A1B`` -- what order 9 lends every enemy while it stamps the threat
#: map, and takes back afterwards.
THREAT_MP_BONUS = 10
#: The order-9 coin flip: ``aRandom(0, 20)``, and the side that takes cover.
CLEVER_COIN_MAX = 20
CLEVER_COIN_THRESHOLD = 10
#: The hit points below which order 9 runs for cover instead of shooting first.
CLEVER_LOW_HP = 3
#: The movement points order 9's melee arm lends itself and takes back.
CLEVER_MELEE_MP = 2

#: ``docs/23`` §3.3 -- what a shot or an interaction writes into ``+0x39``.
ACTED = 3
#: ``0x0040A5A3`` -- what a shot writes into ``+0x41``.
ACTION_STATE_FIRED = 4
#: ``0x0040A710`` -- the two ``def_mode`` values that enter defence, and the
#: action state that says it worked.
DEF_MODE_AUTOMATIC = frozenset({1, 4})
ACTION_STATE_WAITING = 1

#: ``docs/23`` §9 -- the pseudo-player, its unit type, and the fuse.
PSEUDO_PLAYER = 0xFC
PARABOMB_TYPE = 31
PARABOMB_FUSE_HP = 1

#: ``docs/10`` §5.7 -- the computer's own player id.
PLAYER_COMPUTER = 0xFF

#: ``docs/10`` §5.4 -- the four armour equipment ids, and what each is worth to
#: ``0x00475490`` / ``0x004754F0``, in the order those routines test them.
ARMOUR_EQUIPMENT = ((13, 6, 4), (12, 5, 0), (11, 4, 2), (10, 3, 2))
#: The unit-type armour column value that means "derive it from equipment".
ARMOUR_DERIVED = 255

#: What the closing sweep of ``aAISystemControl`` tags its ``endUnitTurn``
#: events with, so a check can tell the turn's own calls apart from the
#: handlers'.
CLOSING_SWEEP = "closing sweep"

#: A hard ceiling on the ``repeat`` re-sweeps of one level.  The engine has
#: none: ``repeat`` is set whenever a unit ended a sweep with zero movement
#: points, and a sweep that changes nothing clears it, so the loop terminates
#: because movement points only ever fall.  A model that got the condition
#: wrong would **hang** rather than answer wrongly, which is why the ceiling
#: exists and why exceeding it is an error rather than a truncation.
SWEEP_CEILING = 512
#: The same, for the whole turn: passes x levels x sweeps.
TURN_SWEEP_CEILING = PASSES * (MAX_LEVEL + 1) * SWEEP_CEILING


# ---------------------------------------------------------------------------
# The event stream -- one AI action as a value
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class AIEvent:
    """One thing the computer did, in the order it did it.

    ``game`` replays these; nothing in ``core`` renders.  The shape is shared
    with ``godot/core/ai/ai_event.gd`` **from the first commit**, because
    ``docs/94`` §8 records what happens when two documents of different shape
    are compared by event name alone: the arguments of 120 cases went
    unchecked for a year.
    """

    kind: str
    slot: int = -1
    x: int = 0
    y: int = 0
    #: A second cell, where the event has one: the destination of a move, the
    #: aim point of a shot.
    tx: int = 0
    ty: int = 0
    #: The order, kind, level, marker or movement cost the event is about.
    detail: int = 0
    #: Free text a check can assert on: a refusal reason, an order name.
    note: str = ""
    #: Nested results -- an :class:`inclib.combat.AttackResult` dictionary for
    #: a shot, the reaction list for a move.
    payload: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind, "slot": self.slot,
            "x": self.x, "y": self.y, "tx": self.tx, "ty": self.ty,
            "detail": self.detail, "note": self.note,
            "payload": dict(self.payload),
        }


@dataclass
class AITurnResult:
    """What one ``aAISystemControl`` did, as a value."""

    ok: bool = True
    player: int = PLAYER_COMPUTER
    events: list[AIEvent] = field(default_factory=list)
    #: How many sweeps of the 200 slots ran, in total.
    sweeps: int = 0
    #: ``kind -> count`` over :attr:`events`, so a check can assert an arm ran.
    counters: dict[str, int] = field(default_factory=dict)
    #: Orders that were dispatched, by order byte.
    orders_seen: dict[int, int] = field(default_factory=dict)
    #: Refusals the model made rather than the engine: a target pattern it does
    #: not simulate, a weapon family whose overlay arm stamps no AI marker.
    refusals: dict[str, int] = field(default_factory=dict)
    #: The generator's state either side of the turn, so a diff that goes wrong
    #: says *where* rather than only *that*.
    seed_before: float = 0.0
    seed_after: float = 0.0
    reason: str = ""
    #: How much work the turn cost, by kind -- fills, target overlays, hit
    #: probabilities. **Not part of** :meth:`to_dict`, on purpose: the diffed
    #: document says what the turn *decided*, and coupling it to how many
    #: times either implementation reached for a flood fill would make an
    #: optimisation a test failure.
    work: dict[str, int] = field(default_factory=dict)

    def did(self, kind: str, times: int = 1) -> None:
        self.work[kind] = self.work.get(kind, 0) + times

    def add(self, event: AIEvent) -> None:
        self.events.append(event)
        self.counters[event.kind] = self.counters.get(event.kind, 0) + 1

    def refuse(self, reason: str) -> None:
        self.refusals[reason] = self.refusals.get(reason, 0) + 1

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "player": self.player,
            "events": [e.to_dict() for e in self.events],
            "sweeps": self.sweeps,
            "counters": dict(self.counters),
            "orders_seen": {str(k): v for k, v in
                            sorted(self.orders_seen.items())},
            "refusals": dict(self.refusals),
            "seed_before": self.seed_before,
            "seed_after": self.seed_after,
            "reason": self.reason,
        }


# ---------------------------------------------------------------------------
# The context -- the world plus the overlay the engine keeps in its cells
# ---------------------------------------------------------------------------

@dataclass
class AIContext:
    """The live state one AI turn runs against.

    ``world`` is the same :class:`inclib.combat.CombatWorld` the attack and fog
    models use, so a mission builds **one** world and every model reads it.
    ``state`` and ``mp_left`` are ``cell[+0x00]`` and ``cell[+0x0C]``: the
    engine keeps them in the cell records, and so does this, because the AI
    reads back what the fill wrote.
    """

    world: CombatWorld
    grid: movemap.Grid
    delays: dict[int, int]
    state: list[int] = field(default_factory=list)
    mp_left: list[int] = field(default_factory=list)
    result: AITurnResult = field(default_factory=AITurnResult)
    #: ``0x004FAE40`` via ``0x0040B370``.  Always 1 in a shipped run: it is an
    #: engine debug global with a setter and a getter and no product option
    #: behind it.  Kept as a field so a check can turn shooting off and watch
    #: the movement alone.
    may_fire: bool = True
    #: ``0x00460450`` -- the difficulty, which the AI module never reads.  It
    #: reaches the movement allowance and the damage roll, both of which the
    #: AI calls into.
    ai_level: int = 1

    def __post_init__(self) -> None:
        n = self.world.width * self.world.height
        if not self.state:
            self.state = [movemap.STATE_RESET] * n
        if not self.mp_left:
            self.mp_left = [0] * n

    # --- cells ------------------------------------------------------------

    def index(self, x: int, y: int) -> int:
        return y * self.world.width + x

    def in_bounds(self, x: int, y: int) -> bool:
        return 0 <= x < self.world.width and 0 <= y < self.world.height

    def cell_x(self, index: int) -> int:
        return index % self.world.width

    def cell_y(self, index: int) -> int:
        return index // self.world.width

    # --- units ------------------------------------------------------------

    def unit(self, slot: int) -> CombatUnit | None:
        return self.world.units.get(slot)

    def hooks(self) -> movemap.MoveMapHooks:
        """Live hooks over the world, rebuilt per fill.

        Closures rather than arrays: a unit that moved or died between two
        fills has to be visible to the second one, and ``hooks_from_arrays``
        would have snapshotted the first.
        """
        world = self.world

        def unit_at(x: int, y: int) -> int:
            if not self.in_bounds(x, y):
                return movemap.NO_UNIT
            return world.unit_at[self.index(x, y)]

        def unit_player(slot: int) -> int:
            unit = world.units.get(slot)
            return 0 if unit is None else unit.player

        def unit_visibility(slot: int) -> int:
            unit = world.units.get(slot)
            return 0 if unit is None else unit.visibility

        def obstacle_at(x: int, y: int) -> int:
            if not self.in_bounds(x, y):
                return movemap.OBSTACLE_NONE
            return world.effect_state[self.index(x, y)]

        return movemap.MoveMapHooks(
            unit_at=unit_at, unit_visibility=unit_visibility,
            unit_player=unit_player,
            # `aGetUnitMapElementPtr` reports "unit id out of area" above 200
            # and the fill then skips the neighbour; every slot below that
            # exists as a record whether or not the mission placed one.
            unit_exists=lambda slot: 0 <= slot < 200,
            obstacle_at=obstacle_at)

    def mover(self, unit: CombatUnit, mp: int) -> movemap.Mover:
        """The fill's view of a unit, with ``mp`` overridden by the horizon."""
        row = self.world.tables.units.get(unit.type_id)
        return movemap.Mover(
            slot=unit.slot, x=unit.x, y=unit.y, player=unit.player, mp=mp,
            special=0 if row is None else row.special,
            size=0 if row is None else row.size,
            has_jet_pack=unit.has(movemap.JET_PACK_EQUIP_ID),
            mp_allowance=self.allowance(unit))

    def allowance(self, unit: CombatUnit) -> int:
        """``aGetMovePoints`` -- only the ladder-to-ladder step spends it."""
        row = self.world.tables.units.get(unit.type_id)
        if row is None:
            return 0
        return movement_allowance(_allowance_unit(unit), row.mp_max,
                                  [_allowance_unit(u)
                                   for u in self.world.units.values()],
                                  self.ai_level)

    def emit(self, event: AIEvent) -> None:
        self.result.add(event)


def _allowance_unit(unit: CombatUnit) -> AllowanceUnit:
    return AllowanceUnit(slot=unit.slot, type_id=unit.type_id,
                         player=unit.player, x=unit.x, y=unit.y, hp=unit.hp,
                         fp=unit.fp, rested=0, action_state=unit.action_state,
                         equipment_ids=unit.equipment_ids)


def context_from_world(world: CombatWorld, delays: dict[int, int],
                       ai_level: int = 1) -> AIContext:
    """Build a context from a world the other models already made."""
    if not world.field_type or not world.action_point:
        raise AIError("the world carries no field types or action points; "
                      "inclib.combat.world_from_map fills both")
    grid = movemap.Grid(width=world.width, height=world.height,
                        heights=list(world.cell_height),
                        field_types=list(world.field_type),
                        action_points=list(world.action_point))
    return AIContext(world=world, grid=grid, delays=dict(delays),
                     ai_level=ai_level)


# ---------------------------------------------------------------------------
# The overlay -- 0x0042EE90, 0x0042F790, 0x0042FE90
# ---------------------------------------------------------------------------

def reset_overlay(ctx: AIContext) -> None:
    """``0x0042EE90`` -- ``cell[+0x00] = 1`` and ``cell[+0x0C] = 0``, and
    nothing else."""
    for i in range(len(ctx.state)):
        ctx.state[i] = movemap.STATE_RESET
        ctx.mp_left[i] = 0


def write_marker(ctx: AIContext, x: int, y: int, value: int) -> None:
    """``0x0042F790(x, y, value)`` -- bounds-checked, and the only writer of
    the five target markers."""
    if not ctx.in_bounds(x, y):
        return
    ctx.state[ctx.index(x, y)] = value


def prune_objects(ctx: AIContext, keep: bool = False) -> None:
    """``0x0042FE90(keep)`` -- drop the markers standing on inanimate objects.

    The AI always passes 0, so a barrel never becomes a target.  The argument
    is kept because the routine has one and because "the AI passes 0" is a fact
    about the call site rather than about the routine.
    """
    if keep:
        return
    for i, marker in enumerate(ctx.state):
        if marker < TARGET_MARKER_MIN or marker > TARGET_MARKER_MAX:
            continue
        slot = ctx.world.unit_at[i]
        if slot < 0:
            continue
        target = ctx.world.units.get(slot)
        if target is None:
            continue
        if ctx.world.species(target) == SPECIES_OBJECT:
            ctx.state[i] = movemap.STATE_RESET


def overlay_arm(weapon_id: int) -> str:
    """Which arm of ``0x0042FF30`` a weapon id reaches."""
    if weapon_id < 0 or weapon_id >= len(OVERLAY_FAMILY):
        return "error"
    return OVERLAY_ARMS[OVERLAY_FAMILY[weapon_id]]


def effective_weapon(ctx: AIContext, unit: CombatUnit) -> int | None:
    """``0x0042FF30``'s weapon substitution, or ``None`` when it refuses.

    A jammed or empty weapon whose ``special`` column is 1 falls back to its
    ``param`` id; one without does not aim at all.  The **dispatch** below
    still uses the unit's original weapon -- ``edx`` is loaded before the
    substitution and never reloaded -- which is why this returns the aiming
    weapon and the caller keeps the original for :func:`overlay_arm`.
    """
    weapons = ctx.world.tables.weapons
    original = weapons.get(unit.weapon)
    if original is None:
        return None
    weapon_id = unit.weapon
    if unit.malfunction != 0 or unit.ammo == 0:
        if original.special != 1:
            return None
        weapon_id = original.param
    row = weapons.get(weapon_id)
    if row is None:
        return None
    if unit.mp < row.ap:
        return None
    if row.mun != 0xFF and unit.ammo < row.mun_per_fight:
        return None
    return weapon_id


def build_target_overlay(ctx: AIContext, unit: CombatUnit) -> bool:
    """``0x0042FF30`` -- stamp every reachable enemy with its hit-chance band.

    Returns the routine's own answer.  FALSE means "this unit cannot aim at
    all"; TRUE with nothing stamped means "it can aim and found nobody", and
    the two are different to the caller only through the overlay.
    """
    ctx.result.did(WORK_OVERLAY)
    if unit.fp <= MIN_FITNESS_TO_AIM:
        return False
    if unit.weapon == WEAPON_NONE:
        # The routine returns TRUE here without dispatching, so "No Weapon"
        # stamps nothing and is not an error.
        return True
    weapon_id = effective_weapon(ctx, unit)
    if weapon_id is None:
        return False

    arm = overlay_arm(unit.weapon)
    if arm != "units":
        # `special_objects`, `empty_ground` and `any_unit` stamp markers 35, 36
        # and 37, which the fire routine's `30 <= s <= 34` window never
        # selects, so a unit carrying one of those four weapon ids can never
        # find an AI target.  `error` is the "unknown weapon" arm, which also
        # returns TRUE.  Recorded rather than simulated: the markers are
        # unreachable by every reader in the module.
        ctx.result.refuse(f"overlay arm {arm!r} stamps no AI target band")
        return True

    world = ctx.world
    original = world.tables.weapons.get(unit.weapon)
    for slot in range(200):
        other = world.units.get(slot)
        if other is None or other.hp == 0:
            continue
        if slot == unit.slot:
            continue
        if other.player == unit.player:
            continue
        # `0x0043B1F0` gates the "both players are human" skip that follows it
        # in the engine.  It is the network-game test (docs/25 §3.1), false in
        # the campaign, so that skip never fires here.  Named rather than
        # dropped: a remake that quietly omitted it would have nothing to point
        # at when a network mode arrives.
        if not _special_hook_allows(ctx, unit, other):
            continue
        if other.visibility != VISIBILITY_VISIBLE:
            continue
        if other.type_id in (TYPE_NEVER_TARGET, TYPE_IMMUNE):
            continue
        ctx.result.did(WORK_HIT_CHANCE)
        chance = combatmod.hit_probability(world, unit, other, weapon_id,
                                           apply_los=True)
        if not chance.in_range:
            continue
        percent = chance.percent
        percent = _weapon_47_override(world, unit, other, percent)
        percent = _weapon_45_override(world, unit, other, percent)
        if percent <= 0 or percent >= 254:
            continue
        tx, ty = other.x, other.y
        # The **original** weapon's `special`, not the substituted one's:
        # `0x004302A8` indexes the table with `al`, which was reloaded from
        # `u->+0x3F` at `0x0043021B` and never from the fallback.
        if original is not None and original.special == 6:
            tx, ty = other.turn_start_x, other.turn_start_y
        write_marker(ctx, tx, ty, _band_of(percent))
    return True


def _band_of(percent: int) -> int:
    for limit, marker in TARGET_BANDS:
        if percent <= limit:
            return marker
    return TARGET_MARKER_TOP


def _special_hook_allows(ctx: AIContext, unit: CombatUnit,
                         other: CombatUnit) -> bool:
    """``0x0046F210(u, o, 2)`` -- ``docs/21`` §5's ``special`` dispatcher.

    The switch keys on the **aiming** unit's type, not the target's, and phase
    2's arm handles exactly one value: ``special`` 4, *"may attack only while
    its per-turn counter is 2 or less"*.  Every other value -- including 0,
    which returns before the switch -- lands on the default, and the default
    returns TRUE (``0x0046F797``).

    No shipped ``SetUnitInfo`` line carries 4, so this is TRUE for every unit
    in the corpus.  It exists because the alternative is an unnamed omission:
    the gate is real and a mod could reach it.
    """
    row = ctx.world.tables.units.get(unit.type_id)
    if row is None or row.special != 4:
        return True
    ctx.result.refuse("special 4 gates the target overlay; unshipped")
    # `unit[+0x50]`, the tenths of a field walked this turn, is not carried by
    # `CombatUnit` -- nothing in docs/22 or docs/26 reads it -- so refusing
    # here is honest where inventing a zero would not be.
    return True


def _weapon_47_override(world: CombatWorld, unit: CombatUnit,
                        other: CombatUnit, percent: int) -> int:
    """``0x0043021B`` -- weapon 47 forces 255 against most targets.

    255 is above the ``>= 254`` refusal, so the effect is that
    ``Laser Enhanced`` finds a target *only* where the override does not fire.
    """
    if unit.weapon != 47:
        return percent
    if other.hp >= 4:
        return 255
    row = world.tables.units.get(other.type_id)
    if row is None:
        return percent
    if row.size == 1 or row.species == SPECIES_OBJECT:
        return 255
    return percent


def _weapon_45_override(world: CombatWorld, unit: CombatUnit,
                        other: CombatUnit, percent: int) -> int:
    """``0x00430257`` -- weapon 45 forces 255 against species 3."""
    if unit.weapon != 45:
        return percent
    row = world.tables.units.get(other.type_id)
    if row is not None and row.species == 3:
        return 255
    return percent


# ---------------------------------------------------------------------------
# The three unit predicates -- 0x0040B000, 0x0040B040, 0x0040B080
# ---------------------------------------------------------------------------

def is_enemy(world: CombatWorld, unit: CombatUnit, other: CombatUnit) -> bool:
    """``0x0040B000`` -- another player's, and not an inanimate object."""
    if other.player == unit.player:
        return False
    return world.species(other) != SPECIES_OBJECT


def is_enemy_ready(world: CombatWorld, unit: CombatUnit,
                   other: CombatUnit) -> bool:
    """``0x0040B040`` -- :func:`is_enemy` plus "no reaction pending"."""
    if not is_enemy(world, unit, other):
        return False
    return other.action_state != ACTION_STATE_WAITING


def is_ally(world: CombatWorld, unit: CombatUnit, other: CombatUnit,
            cap: int) -> bool:
    """``0x0040B080`` -- a live alien of ours with at most ``cap`` points left.

    The cap is why kinds 1 and 3 call this up to three times: first look for an
    ally that has spent everything, then one nearly spent, then any.
    """
    if other.hp == 0:
        return False
    if other is unit:
        return False
    if other.mp > cap:
        return False
    if other.player != unit.player:
        return False
    return world.species(other) == SPECIES_ALIEN


# ---------------------------------------------------------------------------
# The cover score -- 0x0040B0D0
# ---------------------------------------------------------------------------

def cover_score(ctx: AIContext, index: int, unit: CombatUnit,
                best: int) -> tuple[int | None, int]:
    """``0x0040B0D0(cell, u, *best)`` -- the only place the AI weighs terrain.

    Returns ``(cell index or None, best)``.  The distance to the furthest
    enemy is **Euclidean and truncated**: the engine computes it in x87 and
    converts with ``MSVCRT._ftol``, which truncates toward zero, and so does
    the ``* 1.5``.  ``docs/23`` §5.2 writes both as ``+ 0.5`` rounding, which
    would differ by one on every odd ``far``.
    """
    cx, cy = ctx.cell_x(index), ctx.cell_y(index)
    far = 0
    for slot in range(200):
        other = ctx.world.units.get(slot)
        if other is None or other.hp == 0:
            continue
        if other.player == unit.player:
            continue
        dx = other.x - cx
        dy = other.y - cy
        d = _isqrt_trunc(dx * dx + dy * dy)
        if d > far:
            far = d
    score = far * COVER_DISTANCE_NUMERATOR // COVER_DISTANCE_DENOMINATOR

    for dx, dy in movemap.WALK_DIR_DELTA:
        nx, ny = cx + dx, cy + dy
        if not ctx.in_bounds(nx, ny):
            continue
        if ctx.grid.field_types[ctx.index(nx, ny)] == COVER_WALL_FIELD_TYPE:
            score += 1

    score += COVER_ALIGNMENT_BONUS
    if score > best:
        return index, score
    return None, best


def _isqrt_trunc(value: int) -> int:
    """``(int)sqrt((double)value)`` -- the truncation ``_ftol`` performs."""
    if value <= 0:
        return 0
    root = 0
    # `math.isqrt` is the same answer for every value a 40x40 map can produce
    # (the largest is 39^2 + 39^2 = 3042, far inside a double's exact range),
    # and is written out here so the truncation is visible rather than assumed.
    root = int(value ** 0.5)
    while (root + 1) * (root + 1) <= value:
        root += 1
    while root * root > value:
        root -= 1
    return root


# ---------------------------------------------------------------------------
# The approach cell -- 0x0040ADC0
# ---------------------------------------------------------------------------

def approach_cell(ctx: AIContext, target: int, best: int,
                  my_slot: int) -> tuple[int | None, int]:
    """``0x0040ADC0(target, *best, myUnitIndex)`` -- stand *next to* a cell.

    The eight neighbours of ``target``, and for a **large** mover the eight
    neighbours of each of those instead -- a second ring, with the first ring
    itself never a candidate.  A cell already holding the mover returns at once
    with :data:`APPROACH_OWN_CELL_SCORE`.

    The two rings do not break ties the same way, and the asymmetry is the
    engine's: the small path accepts ``mp >= best`` (a later cell wins) and the
    large path requires ``mp > best`` (the incumbent keeps it).
    """
    mover = ctx.world.units.get(my_slot)
    if mover is None:
        return None, best
    row = ctx.world.tables.units.get(mover.type_id)
    large = row is not None and row.size == movemap.SIZE_LARGE

    tx, ty = ctx.cell_x(target), ctx.cell_y(target)
    target_height = ctx.grid.heights[target]
    found: int | None = None
    for dx, dy in movemap.WALK_DIR_DELTA:
        nx, ny = tx + dx, ty + dy
        if not ctx.in_bounds(nx, ny):
            continue
        if not large:
            hit, best, own = _approach_candidate(ctx, nx, ny, target_height,
                                                 best, my_slot, False)
            if own:
                return ctx.index(nx, ny), APPROACH_OWN_CELL_SCORE
            if hit is not None:
                found = hit
            continue
        for dx2, dy2 in movemap.WALK_DIR_DELTA:
            mx, my = nx + dx2, ny + dy2
            if not ctx.in_bounds(mx, my):
                continue
            hit, best, own = _approach_candidate(ctx, mx, my, target_height,
                                                 best, my_slot, True)
            if own:
                return ctx.index(mx, my), APPROACH_OWN_CELL_SCORE
            if hit is not None:
                found = hit
    return found, best


def _approach_candidate(ctx: AIContext, x: int, y: int, target_height: int,
                        best: int, my_slot: int,
                        large: bool) -> tuple[int | None, int, bool]:
    index = ctx.index(x, y)
    standing = ctx.world.unit_at[index]
    if standing == my_slot:
        return index, APPROACH_OWN_CELL_SCORE, True
    if standing >= 0:
        return None, best, False
    if movemap.climb_quotient(ctx.grid.heights[index] - target_height) \
            > APPROACH_CLIMB_MAX:
        return None, best, False
    left = ctx.mp_left[index]
    # The one place the two rings differ: `jle` for a large mover, `jl` for a
    # small one.
    if left < best or (large and left == best):
        return None, best, False
    if ctx.state[index] not in (movemap.STATE_REACHABLE, movemap.STATE_WARP):
        return None, best, False
    return index, left, False


# ---------------------------------------------------------------------------
# Armour, recomputed after every shot -- 0x00475490 and 0x004754F0
# ---------------------------------------------------------------------------

def armour_of(world: CombatWorld, unit: CombatUnit) -> tuple[int, int]:
    """``(front, rear)`` -- ``docs/10`` §5.4's two routines.

    The unit type's column wins unless it is 255, in which case the four
    armour equipment ids decide, tested heaviest first.  Carrying none gives
    **0 / 0**, which is what both routines' shared
    ``(-(rec[+0x2B] != 1) & mask) + k`` idiom yields.
    """
    row = world.tables.units.get(unit.type_id)
    if row is None:
        return unit.armour_front, unit.armour_rear
    front = row.armour_front
    rear = row.armour_rear
    for equip, front_value, rear_value in ARMOUR_EQUIPMENT:
        if not unit.has(equip):
            continue
        if front == ARMOUR_DERIVED:
            front = front_value
        if rear == ARMOUR_DERIVED:
            rear = rear_value
        break
    if front == ARMOUR_DERIVED:
        front = 0
    if rear == ARMOUR_DERIVED:
        rear = 0
    return front, rear


# ---------------------------------------------------------------------------
# Firing -- 0x0040A440
# ---------------------------------------------------------------------------

def fire(ctx: AIContext, unit: CombatUnit, mode: int = FIRE_ANY,
         group: int = 0) -> bool:
    """``0x0040A440(u, mode, group)`` -- one shot, or the reason there was none.

    Returns the routine's own answer, and the callers use it as
    ``while (fire(u)) ;`` -- *shoot until you cannot*.  Two things make that
    loop terminate: the eligibility test ``mp < ap`` at the top, and the
    unconditional subtraction at the bottom, which runs **even when the shot
    did not** -- a weapon whose heat cap is 0 spends its points and draws no
    rolls.  A model that skipped the subtraction on that arm would hang.
    """
    ctx.result.did(WORK_FIRE)
    world = ctx.world
    weapon = world.tables.weapons.get(unit.weapon)
    ap = 0 if weapon is None else weapon.ap
    if unit.hp == 0:
        return False
    if unit.mp < ap:
        return False

    reset_overlay(ctx)
    build_target_overlay(ctx, unit)
    prune_objects(ctx, False)

    best, best_score, refused = select_target(ctx, mode, group)
    if refused:
        return False
    if best is None:
        return False
    if unit.mp == 0:
        return False

    bx, by = ctx.cell_x(best), ctx.cell_y(best)
    if ctx.may_fire:
        cap = combatmod.max_heat(world, unit)
        # The gate collapses: 255 disables the mechanic, and any other non-zero
        # cap reaches the attack whether the unit is over it or not.  The only
        # effect is that a weapon whose cap is 0 is never fired at all.
        blocked = cap != HEAT_DISABLED and unit.heat >= cap and cap == 0
        if not blocked:
            try:
                attack = combatmod.attack_unit(world, unit.x, unit.y, bx, by)
                ctx.emit(AIEvent("fire", unit.slot, unit.x, unit.y, bx, by,
                                 detail=best_score, note=str(unit.weapon),
                                 payload=attack.to_dict()))
            except combatmod.CombatError as exc:
                # The engine fires; this model cannot resolve the pattern.
                # The points are still spent below, so the loop still ends and
                # the refusal is counted rather than silently absorbed.
                ctx.result.refuse(str(exc))
                ctx.emit(AIEvent("fire_unresolved", unit.slot, unit.x, unit.y,
                                 bx, by, detail=best_score, note=str(exc)))
            unit.acted = ACTED
        else:
            ctx.emit(AIEvent("fire_heat_blocked", unit.slot, unit.x, unit.y,
                             bx, by, detail=cap, note=str(unit.weapon)))

    unit.mp = unit.mp - ap if unit.mp > ap else 0
    unit.action_state = ACTION_STATE_FIRED
    if unit.hp > 0:
        reactions = combatmod.drain_reactions(world, unit)
        if reactions:
            ctx.emit(AIEvent("reactions", unit.slot, unit.x, unit.y,
                             detail=len(reactions),
                             payload={"reactions": [r.to_dict()
                                                    for r in reactions]}))
    unit.armour_front, unit.armour_rear = armour_of(world, unit)
    return True


def select_target(ctx: AIContext, mode: int,
                  group: int) -> tuple[int | None, int, bool]:
    """``0x0040A440``'s middle stage: the numerically largest marker.

    Returns ``(cell index or None, marker, refused)``.  Two properties are
    checks of their own in ``ai_runtime.py`` rather than comments here:
    acceptance is ``s >= bestScore``, so **the later cell wins a tie**, and the
    scan is row-major over the whole grid, so "later" means "further down and
    to the right".  There is no weighting by the target's health, threat or
    value: the AI always shoots at its highest hit chance.
    """
    world = ctx.world
    best: int | None = None
    best_score = 0
    for index, marker in enumerate(ctx.state):
        if marker < TARGET_MARKER_MIN or marker > TARGET_MARKER_MAX:
            continue
        if mode == FIRE_GROUP:
            slot = world.unit_at[index]
            target = world.units.get(slot) if slot >= 0 else None
            if target is None:
                # `GetUnitPtr(0xFFFF)` reports "unit id out of area" and the
                # routine returns FALSE.  Reachable: weapon `special` 6 stamps
                # the target's cell of *last* turn, which may now be empty.
                ctx.result.refuse("group fire found a marker on an empty cell")
                return None, 0, True
            if target.group != group:
                continue
        elif mode != FIRE_ANY:
            continue
        if marker >= best_score:
            best = index
            best_score = marker
    return best, best_score, False


def fire_until_empty(ctx: AIContext, unit: CombatUnit, mode: int = FIRE_ANY,
                     group: int = 0) -> int:
    """``while (fire(u, mode, group)) ;`` -- how many times it answered TRUE."""
    shots = 0
    while fire(ctx, unit, mode, group):
        shots += 1
        if shots > SWEEP_CEILING:
            raise AIError("the fire loop did not terminate; "
                          "0x0040A440 always spends its action points")
    return shots


# ---------------------------------------------------------------------------
# Planning one action -- 0x0040A750
# ---------------------------------------------------------------------------

def horizon_mp(level: int, mp: int) -> int:
    """``0x0040AD70``'s six arms: the movement points the fill pretends to."""
    override = HORIZON_MP[level]
    if override is not None:
        return override
    # Level 1 doubles, and `shl al, 1` is a **byte** shift, so 130 points
    # becomes 4 rather than 260.
    return (mp * 2) & 0xFF if level == 1 else mp


def build_move_map(ctx: AIContext, unit: CombatUnit,
                   level: int) -> movemap.MoveMapResult | None:
    """One of ``0x0040A750``'s six ``aBuildMoveMap`` calls, into the overlay.

    The engine writes the fill's answer **into the cells**, over what
    ``resetOverlay`` just put there, which is why this copies rather than
    returning.  A cell the fill never reached keeps its 1 and its 0.
    """
    ctx.result.did(WORK_FILL)
    saved = unit.mp
    mp = horizon_mp(level, saved)
    unit.mp = mp & 0xFF
    try:
        result = movemap.build(ctx.grid, ctx.mover(unit, unit.mp), ctx.delays,
                               ctx.hooks(),
                               pass_friendlies=HORIZON_PASS_FRIENDLIES[level])
    finally:
        unit.mp = saved
    if not result.ret:
        return None
    for index, marker in enumerate(result.state):
        if marker != movemap.STATE_NONE:
            ctx.state[index] = marker
        ctx.mp_left[index] = result.mp_left[index]
    return result


def plan(ctx: AIContext, unit: CombatUnit, kind: int, param: int,
         level: int) -> bool:
    """``0x0040A750(u, kind, param, level)`` -- fill, score, commit.

    Returns the routine's own answer.  **It is TRUE far more often than
    ``docs/23``'s sketch suggests**: a dead unit, a spent unit, a walk of zero
    steps and a blocked path all return TRUE.  FALSE comes back only from a
    failed fill, a failed path reconstruction, no candidate cell at all, and a
    failed ``aExecuteWarp`` / ``aExecuteMove``.
    """
    ctx.result.did(WORK_PLAN)
    if unit.hp == 0 or unit.mp == 0:
        return True

    own_cell = ctx.index(unit.x, unit.y)
    own_slot = ctx.world.unit_at[own_cell]
    reset_overlay(ctx)
    if 0 <= level <= MAX_LEVEL:
        if build_move_map(ctx, unit, level) is None:
            return False
    # A level outside 0…5 skips the fill entirely -- the switch's default arm
    # is the restore-and-scan tail -- leaving an overlay of plain cells that
    # the approach scan can never accept.  No handler passes one.

    best_cell, _score = _score_cells(ctx, unit, kind, param, own_slot)
    if best_cell is None:
        return False
    return _commit(ctx, unit, best_cell)


def _score_cells(ctx: AIContext, unit: CombatUnit, kind: int, param: int,
                 own_slot: int) -> tuple[int | None, int]:
    """``0x0040A750``'s middle stage -- the twelve-arm scan over every cell."""
    world = ctx.world
    best_cell: int | None = None
    best = 0
    if kind < KIND_MIN or kind > KIND_MAX or kind in KIND_FALL_THROUGH:
        # Kinds 8 and 9 belong to `fire`; 4 and 5 have no code in either
        # binary.  The table reserves all four as fall-through, so the scan
        # runs and selects nothing.
        return None, 0

    for index in range(len(ctx.state)):
        if ctx.state[index] == movemap.STATE_NONE:
            continue
        approach = False

        if kind == KIND_ENEMY or kind == KIND_ENEMY_READY:
            slot = world.unit_at[index]
            if slot < 0:
                continue
            other = world.units.get(slot)
            if other is None:
                return None, best
            ready = (is_enemy(world, unit, other) if kind == KIND_ENEMY
                     else is_enemy_ready(world, unit, other))
            if not ready:
                continue
            approach = True
        elif kind in (KIND_ALLY, KIND_ALLY_SHORT):
            slot = world.unit_at[index]
            if slot < 0:
                continue
            other = world.units.get(slot)
            if other is None:
                return None, best
            caps = ALLY_CAPS_FULL if kind == KIND_ALLY else ALLY_CAPS_SHORT
            if not any(is_ally(world, unit, other, cap) for cap in caps):
                continue
            approach = True
        elif kind == KIND_DOOR:
            if ctx.grid.action_points[index] != ACTION_POINT_CLOSED_DOOR:
                continue
            approach = True
        elif kind == KIND_ACTION_POINT:
            if ctx.grid.action_points[index] != param:
                continue
            if world.unit_at[index] >= 0:
                approach = True
            else:
                left = ctx.mp_left[index]
                # `jl` -- **the later cell wins a tie**, and the incumbent's
                # score is doubled on the way in, which is why an occupied
                # match has to beat twice the free one.
                if left < best:
                    continue
                best_cell = index
                best = left * 2
                continue
        elif kind == KIND_GROUP:
            slot = world.unit_at[index]
            if slot < 0:
                continue
            other = world.units.get(slot)
            if other is None:
                return None, best
            if other.group != param:
                continue
            approach = True
        elif kind == KIND_COVER:
            found, best = cover_score(ctx, index, unit, best)
            if found is not None:
                best_cell = found
            continue

        if approach:
            found, best = approach_cell(ctx, index, best, own_slot)
            if found is not None:
                best_cell = found
    return best_cell, best


def _commit(ctx: AIContext, unit: CombatUnit, best_cell: int) -> bool:
    """``0x0040A750``'s tail -- walk to the chosen cell and pay for it."""
    world = ctx.world
    tx, ty = ctx.cell_x(best_cell), ctx.cell_y(best_cell)
    warping = ctx.state[best_cell] == movemap.STATE_WARP

    steps = 0
    blocked = 0
    walked: movemap.WalkResult | None = None
    if warping:
        steps = unit.mp
    else:
        overlay = movemap.MoveMapResult(
            width=world.width, height=world.height,
            state=list(ctx.state), mp_left=list(ctx.mp_left),
            any_friendly_blocked=False, ret=True)
        walked = movemap.walk(ctx.grid, overlay, unit.x, unit.y, tx, ty,
                              ctx.delays, ctx.hooks())
        if not walked.ok:
            return False
        steps = walked.steps
        blocked = walked.blocked
    if steps == 0:
        # `je 0x40acbc` -- TRUE, not FALSE.  docs/23 §5.3's sketch has this
        # one wrong, and the difference is visible to the callers that test the
        # answer.
        return True

    cost = 0
    if blocked == 0:
        if warping:
            if not execute_warp(ctx, unit, tx, ty):
                return False
            # A jump always ends the unit's movement.
            cost = unit.mp
        else:
            assert walked is not None
            # The mover's **real** points bound the walk: `0x0040A750`
            # restores `u->+0x15` before it commits, and the wider horizons
            # are a search radius rather than a movement allowance.
            moved = movemap.execute(ctx.grid, ctx.hooks(), ctx.delays,
                                    ctx.mover(unit, unit.mp), walked,
                                    budget=unit.mp)
            if not moved.ok and not moved.movement_zeroed:
                return False
            _apply_move(ctx, unit, moved)
            cost = moved.cost
            if moved.movement_zeroed:
                unit.mp = 0
        unit.acted = ACTED
        if unit.hp > 0:
            reactions = combatmod.drain_reactions(world, unit)
            if reactions:
                ctx.emit(AIEvent("reactions", unit.slot, unit.x, unit.y,
                                 detail=len(reactions),
                                 payload={"reactions": [r.to_dict()
                                                        for r in reactions]}))
        if unit.hp == 0:
            return True
    if cost == 0:
        return True
    unit.mp = 0 if cost > unit.mp else unit.mp - cost
    return True


def _apply_move(ctx: AIContext, unit: CombatUnit,
                moved: movemap.ExecuteResult) -> None:
    """What the caller of ``aExecuteMove`` does with the result it reports."""
    world = ctx.world
    world.unit_at[ctx.index(unit.x, unit.y)] = movemap.NO_UNIT
    world.unit_at[ctx.index(moved.x, moved.y)] = unit.slot
    ctx.emit(AIEvent("move", unit.slot, unit.x, unit.y, moved.x, moved.y,
                     detail=moved.cost,
                     payload={"steps": moved.steps, "facing": moved.facing,
                              "events": [e.to_dict() for e in moved.events]}))
    unit.x, unit.y = moved.x, moved.y
    unit.facing = moved.facing
    # `+0x50` is written by `aExecuteMove` itself, not by its caller, and the
    # engine adds into one byte -- so it wraps rather than saturating.
    unit.walked = (unit.walked + moved.walked) & 0xFF
    for index, value in moved.action_point_writes:
        ctx.grid.action_points[index] = value
        world.action_point[index] = value


def execute_warp(ctx: AIContext, unit: CombatUnit, tx: int, ty: int) -> bool:
    """``aExecuteWarp(sx, sy, tx, ty, 1)`` ``0x0046EF50``, reduced to its state.

    The routine plays a jump animation, clears the source cell's unit id,
    writes the mover's into the target's, and moves the record.  Its one other
    arm fires when the **target** carries a mine (``cell[+0x10] == 2``), which
    no shipped cell does -- ``docs/23`` §7.1 measures the byte as 255 in all
    184162 of them -- so it is named here and not simulated.
    """
    world = ctx.world
    source = ctx.index(unit.x, unit.y)
    if world.unit_at[source] != unit.slot:
        # "no unit on start path field" -- the routine's own refusal.
        ctx.result.refuse("warp from a cell that does not hold the mover")
        return False
    target = ctx.index(tx, ty)
    if world.effect_state[target] == movemap.OBSTACLE_MINE:
        ctx.result.refuse("a warp onto a mine is not simulated")
    world.unit_at[source] = movemap.NO_UNIT
    world.unit_at[target] = unit.slot
    ctx.state[source] = movemap.STATE_RESET
    ctx.emit(AIEvent("warp", unit.slot, unit.x, unit.y, tx, ty))
    unit.x, unit.y = tx, ty
    return True


# ---------------------------------------------------------------------------
# The per-unit helpers -- 0x0040B380, 0x0040A600, 0x0040A6E0, 0x0040B210,
# 0x0040B250, 0x0047A810, 0x0040A710
# ---------------------------------------------------------------------------

def end_unit_turn(ctx: AIContext, unit: CombatUnit,
                  note: str = "") -> bool:
    """``0x0040B380`` -- face a direction, then zero the movement points.

    The facing comes from ``0x0047A8E0(x, y, 2)``, which is not modelled: it
    picks a direction from the map and answers ``0xFF`` when there is none, and
    the write is skipped then.  **The movement points are zeroed either way**,
    which is the half every caller depends on, so the facing is recorded as an
    unmodelled refusal rather than guessed at.
    """
    if unit.hp == 0:
        return False
    ctx.result.refuse("0x0047A8E0's end-of-turn facing is not modelled")
    unit.mp = 0
    ctx.emit(AIEvent("end_unit_turn", unit.slot, unit.x, unit.y, note=note))
    return True


def open_door(ctx: AIContext, unit: CombatUnit) -> bool:
    """``0x0040A600`` -- step up to a closed door and play the sequence.

    The sequence itself is presentation; what survives it is the facing, one
    movement point and the *acted* flag, so those are what this applies.  The
    door's own cell is **not** changed by this routine -- ``aDoorOpenSequence``
    (``0x00410A20``) is what rewrites the action point, and it is a set-piece,
    recorded as an event exactly as ``docs/94`` recorded the others.
    """
    if unit.hp == 0:
        return False
    if unit.mp < DOOR_MIN_MP:
        return False
    for dx, dy in movemap.WALK_DIR_DELTA:
        nx, ny = unit.x + dx, unit.y + dy
        if not ctx.in_bounds(nx, ny):
            continue
        if ctx.grid.action_points[ctx.index(nx, ny)] \
                != ACTION_POINT_CLOSED_DOOR:
            continue
        unit.facing = combatmod.direction(unit.x, unit.y, nx, ny)
        unit.acted = ACTED
        unit.mp -= DOOR_MP_COST
        ctx.emit(AIEvent("door", unit.slot, unit.x, unit.y, nx, ny,
                         detail=ACTION_POINT_CLOSED_DOOR))
        return True
    return False


def countdown(unit: CombatUnit) -> bool:
    """``0x0040A6E0`` -- order 5's wait, one turn shorter each time.

    At zero the secondary order is promoted; otherwise the parameter falls by
    one and **the unit's turn ends**.
    """
    if unit.order_param == 0:
        unit.order = unit.order2
        unit.order_param = unit.order2_param
        return True
    unit.order_param = (unit.order_param - 1) & 0xFF
    unit.mp = 0
    return True


def group_alive(ctx: AIContext, group: int) -> bool:
    """``0x0040B210`` -- is any of the 200 slots a live member of this group?"""
    for slot in range(200):
        other = ctx.world.units.get(slot)
        if other is None or other.hp == 0:
            continue
        if other.group == group:
            return True
    return False


def alert_group(ctx: AIContext, group: int) -> int:
    """``0x0047A810`` -- promote the secondary order of a whole squad."""
    woken = 0
    for slot in range(200):
        other = ctx.world.units.get(slot)
        if other is None or other.hp == 0:
            continue
        if other.group != group:
            continue
        other.order = other.order2
        other.order_param = other.order2_param
        woken += 1
    ctx.emit(AIEvent("alert_group", -1, detail=group, note=str(woken)))
    return woken


def distance_trigger(ctx: AIContext, unit: CombatUnit) -> bool:
    """``0x0040B250`` -- order 6's tripwire.

    The **first** slot of another player within ``u->+0x48`` fields wakes the
    whole squad and ends the scan; the order parameter is a radius in fields
    and the distance is ``aGetDistance``.
    """
    for slot in range(200):
        other = ctx.world.units.get(slot)
        if other is None or other.hp == 0:
            continue
        if other.player == unit.player:
            continue
        if movemap.distance(other.x, other.y, unit.x, unit.y) \
                <= unit.order_param:
            alert_group(ctx, unit.group)
            return True
    return False


def defence_mode(ctx: AIContext, unit: CombatUnit) -> bool:
    """``0x0040A710`` -- the end-of-turn overwatch pass.

    Only weapons whose ``def_mode`` column is 1 or 4 can go on overwatch; the
    entry itself is ``0x00478500``, which ``inclib.combat.enter_defence``
    models.  ``+0x39`` is set **after** the call and the points are zeroed only
    when the entry took, which is what ``+0x41 == 1`` reports.
    """
    weapon = ctx.world.tables.weapons.get(unit.weapon)
    if weapon is None or weapon.def_mode not in DEF_MODE_AUTOMATIC:
        return True
    ticket = combatmod.enter_defence(ctx.world, unit)
    unit.acted = ACTED
    if unit.action_state == ACTION_STATE_WAITING:
        unit.mp = 0
    ctx.emit(AIEvent("defence", unit.slot, unit.x, unit.y, detail=ticket))
    return True


# ---------------------------------------------------------------------------
# The pseudo-player -- 0x0040B2D0
# ---------------------------------------------------------------------------

def special_player_control(ctx: AIContext) -> bool:
    """``aAI_SpecialPlayerControl`` -- parabomb fuses, once, before the loop.

    A unit of type 31 owned by player 252 with one hit point detonates; one
    with more loses a point.  Nothing shipped uses the longer fuse: `Info.lcl`
    gives the `Parabomb` `HP max` 1, so it goes off at the start of the very
    next computer turn.
    """
    for slot in range(200):
        unit = ctx.world.units.get(slot)
        if unit is None or unit.hp == 0:
            continue
        if unit.player != PSEUDO_PLAYER:
            continue
        if unit.type_id != PARABOMB_TYPE:
            continue
        if unit.hp == PARABOMB_FUSE_HP:
            x, y = unit.x, unit.y
            try:
                blast = combatmod.execute_bomb(ctx.world, x, y)
            except combatmod.CombatError as exc:
                ctx.result.refuse(str(exc))
                continue
            ctx.emit(AIEvent("parabomb", slot, x, y,
                             payload=blast.to_dict()))
            if unit.hp != 0:
                # `aRemoveUnitElement(x, y)` -- the bomb survived its own
                # blast, which the guaranteed-hit rule of docs/22 §7 makes
                # impossible for the shipped `Parabomb`.
                unit.hp = 0
                index = ctx.index(x, y)
                if ctx.world.unit_at[index] == slot:
                    ctx.world.unit_at[index] = movemap.NO_UNIT
        else:
            unit.hp -= 1
    return True


# ---------------------------------------------------------------------------
# The eleven orders -- docs/23 section 3
# ---------------------------------------------------------------------------

#: ``docs/23`` §3.3 -- the three tails a handler can reach.  ``ACTED_END`` is
#: the shared copy at ``0x0040A364`` (and order 4's own at ``0x0040A274``,
#: which differs only in which epilogue label the *not acted* arm jumps to);
#: ``ACTED_ZERO_MP`` is order 7's at ``0x0040A164``, which writes the byte
#: rather than calling ``endUnitTurn`` -- so a defender never turns.
TAIL_EPILOGUE = "epilogue"
TAIL_ACTED_END = "acted_end_unit_turn"
TAIL_ACTED_ZERO_MP = "acted_zero_mp"


def run_order(ctx: AIContext, unit: CombatUnit, level: int) -> None:
    """``0x0040A37C``'s eleven arms plus the common epilogue.

    Values above 10 land on order 8's arm, which is the epilogue itself.
    """
    order = unit.order
    param = unit.order_param
    ctx.result.orders_seen[order] = ctx.result.orders_seen.get(order, 0) + 1

    if order == ORDER_BERSERK:
        tail = _order_berserk(ctx, unit, level)
    elif order in (ORDER_MOVE_ACTPT, ORDER_ATTACK_ACTPT):
        tail = _order_action_point(ctx, unit, param, level)
    elif order == ORDER_MOVE_GROUP:
        tail = _order_move_group(ctx, unit, param, level)
    elif order == ORDER_ATTACK_GROUP:
        tail = _order_attack_group(ctx, unit, param, level)
    elif order == ORDER_TURN_WAIT:
        tail = _order_turn_wait(ctx, unit, param, level)
    elif order == ORDER_RANGE_WAIT:
        tail = _order_range_wait(ctx, unit, param, level)
    elif order == ORDER_DEFEND:
        tail = _order_defend(ctx, unit, level)
    elif order == ORDER_CLEVER:
        tail = _order_clever(ctx, unit, level)
    elif order == ORDER_DISTURB:
        tail = _order_disturb(ctx, unit, level)
    else:
        # Order 8 `Visibility (Wait)` and every byte above 10.
        tail = TAIL_EPILOGUE

    if tail == TAIL_ACTED_END and unit.acted != 0:
        end_unit_turn(ctx, unit)
    elif tail == TAIL_ACTED_ZERO_MP and unit.acted != 0:
        unit.mp = 0


def _order_berserk(ctx: AIContext, unit: CombatUnit, level: int) -> str:
    """0 -- the aliens' default: close on the best enemy and shoot.

    Levels 3 and 5 look for a **friendly alien** instead (kinds 3 and 1), so
    the escalation reads *"if you found nobody to kill, go and join the pack"*.
    """
    if level <= 2:
        fire_until_empty(ctx, unit)
        plan(ctx, unit, KIND_ENEMY, 0, level)
        fire_until_empty(ctx, unit)
        return TAIL_ACTED_END
    if level == 3:
        fire_until_empty(ctx, unit)
        plan(ctx, unit, KIND_ALLY_SHORT, 0, 3)
        return TAIL_ACTED_END
    if level == 4:
        fire_until_empty(ctx, unit)
        plan(ctx, unit, KIND_ENEMY, 0, 4)
        return TAIL_ACTED_END
    fire_until_empty(ctx, unit)
    plan(ctx, unit, KIND_ALLY, 0, 5)
    # Level 5 carries its own copy of the shared preamble at `0x00409F00`.
    return TAIL_ACTED_END


def _order_action_point(ctx: AIContext, unit: CombatUnit, param: int,
                        level: int) -> str:
    """1 and 2 -- one block, whatever the editor's two labels say.

    Kind 6 selects the free cell whose action point equals the parameter.
    """
    plan(ctx, unit, KIND_ACTION_POINT, param, 4 if level == 4 else level)
    fire_until_empty(ctx, unit)
    return TAIL_ACTED_END


def _order_move_group(ctx: AIContext, unit: CombatUnit, param: int,
                      level: int) -> str:
    """3 -- walk to a unit whose group id is the parameter.

    Level 5 is the one arm with **no** fire loop in front of the plan.
    """
    if level <= 4:
        fire_until_empty(ctx, unit)
    plan(ctx, unit, KIND_GROUP, param,
         4 if level == 4 else (5 if level == 5 else level))
    return TAIL_ACTED_END


def _order_attack_group(ctx: AIContext, unit: CombatUnit, param: int,
                        level: int) -> str:
    """4 -- the group orders' aggressive half, with its own promotion.

    When no live unit carries the group id the secondary order is promoted on
    the spot and the turn ends here; this is the promotion ``docs/10`` §5.6
    describes, and it is the *only* place a handler rewrites its own order.
    """
    if not group_alive(ctx, param):
        unit.order = unit.order2
        unit.order_param = unit.order2_param
        ctx.emit(AIEvent("promote_order", unit.slot, unit.x, unit.y,
                         detail=unit.order, note="group empty"))
        return TAIL_EPILOGUE
    if level <= 4:
        fire_until_empty(ctx, unit, FIRE_GROUP, param)
        plan(ctx, unit, KIND_GROUP, param, 4 if level == 4 else level)
        fire_until_empty(ctx, unit, FIRE_GROUP, param)
    else:
        fire_until_empty(ctx, unit)
        plan(ctx, unit, KIND_ALLY, param, 5)
    return TAIL_ACTED_END


def _order_turn_wait(ctx: AIContext, unit: CombatUnit, param: int,
                     level: int) -> str:
    """5 -- one chance to shoot from where it stands, then sit the turn out."""
    if level == 0:
        fire_until_empty(ctx, unit)
        plan(ctx, unit, KIND_ENEMY, param, 0)
        fire_until_empty(ctx, unit)
        return TAIL_EPILOGUE
    if level == 1:
        countdown(unit)
    return TAIL_EPILOGUE


def _order_range_wait(ctx: AIContext, unit: CombatUnit, param: int,
                      level: int) -> str:
    """6 -- the same as order 5 at level 0, a tripwire at level 1.

    Unlike order 5 this does **not** zero the movement points, so a woken
    group acts on the next sweep.
    """
    if level == 0:
        fire_until_empty(ctx, unit)
        plan(ctx, unit, KIND_ENEMY, param, 0)
        fire_until_empty(ctx, unit)
        return TAIL_EPILOGUE
    if level == 1:
        distance_trigger(ctx, unit)
    return TAIL_EPILOGUE


def _order_defend(ctx: AIContext, unit: CombatUnit, level: int) -> str:
    """7 -- a defender never moves, and never turns either."""
    if level <= 4:
        fire_until_empty(ctx, unit)
    else:
        defence_mode(ctx, unit)
    return TAIL_ACTED_ZERO_MP


def _order_disturb(ctx: AIContext, unit: CombatUnit, level: int) -> str:
    """10 -- *Berserk* without the friendly-alien fallbacks."""
    fire_until_empty(ctx, unit)
    plan(ctx, unit, KIND_ENEMY, 0, level)
    if level <= 2:
        fire_until_empty(ctx, unit)
    return TAIL_ACTED_END


def _order_clever(ctx: AIContext, unit: CombatUnit, level: int) -> str:
    """9 -- the largest handler, and the only one with logic of its own.

    Four things happen before the level is looked at: a threat map is built by
    running the target overlay from **every enemy's** side with ten extra
    movement points, the unit decides whether it is a melee unit, levels
    outside 0…3 stop, and a melee unit with points to spare closes and shoots.
    Then the branch that matters: *am I standing where an enemy can hit me?*
    """
    _refresh_threat_map(ctx, unit)
    weapon = ctx.world.tables.weapons.get(unit.weapon)
    melee = weapon is not None and weapon.range_max == 1
    if level < 0 or level > 3:
        return TAIL_EPILOGUE

    here = ctx.index(unit.x, unit.y)
    if melee and unit.mp >= CLEVER_MELEE_MP:
        unit.mp -= CLEVER_MELEE_MP
        plan(ctx, unit, KIND_ENEMY, 0, 0)
        unit.mp = (unit.mp + CLEVER_MELEE_MP) & 0xFF
        fire_until_empty(ctx, unit)
        end_unit_turn(ctx, unit)

    marker = ctx.state[here]
    if TARGET_MARKER_MIN <= marker <= TARGET_MARKER_MAX:
        if unit.hp < CLEVER_LOW_HP:
            plan(ctx, unit, KIND_COVER, 0, 2)
            fire_until_empty(ctx, unit)
            return _clever_tail(ctx, unit, defence=True)
        fire_until_empty(ctx, unit)
        plan(ctx, unit, KIND_COVER, 0, 3)
        fire_until_empty(ctx, unit)
        return _clever_tail(ctx, unit, defence=True)
    return _clever_door(ctx, unit, melee)


def _refresh_threat_map(ctx: AIContext, unit: CombatUnit) -> None:
    """``0x00409A1B`` -- every enemy's reach, stamped over the same overlay.

    The ten movement points are lent and taken back literally; reading them as
    *"as if they had another turn"* is interpretation.  Weapons ``isArcing``
    reaches are skipped, and the pass does **not** reset the overlay first, so
    the bands accumulate from all of them.
    """
    for slot in range(200):
        other = ctx.world.units.get(slot)
        if other is None or other.hp == 0:
            continue
        if other.player == unit.player:
            continue
        if other.weapon in combatmod.ARCING_WEAPONS:
            continue
        other.mp = (other.mp + THREAT_MP_BONUS) & 0xFF
        build_target_overlay(ctx, other)
        other.mp = (other.mp - THREAT_MP_BONUS) & 0xFF


def _clever_tail(ctx: AIContext, unit: CombatUnit, defence: bool) -> str:
    """``0x00409DFD`` / ``0x00409E03`` / ``0x00409E0C`` -- the shared exits."""
    if defence and unit.mp >= CLEVER_MELEE_MP:
        defence_mode(ctx, unit)
    end_unit_turn(ctx, unit)
    return TAIL_EPILOGUE


def _clever_door(ctx: AIContext, unit: CombatUnit, melee: bool) -> str:
    """``0x00409CB4`` -- nobody has a shot at me, so go and open a door.

    Then a coin flip, ``aRandom(0, 20) > 10``, and four combinations of it with
    ``melee``.  The **ranged** side is the one that lends itself two movement
    points, which is the opposite way round from the melee arm above.
    """
    plan(ctx, unit, KIND_DOOR, 0, 0)
    open_door(ctx, unit)
    fire_until_empty(ctx, unit)
    open_door(ctx, unit)
    coin = ctx.world.rng(0, CLEVER_COIN_MAX)
    ctx.emit(AIEvent("clever_coin", unit.slot, unit.x, unit.y, detail=coin,
                     note="melee" if melee else "ranged"))
    if coin > CLEVER_COIN_THRESHOLD:
        if melee:
            plan(ctx, unit, KIND_COVER, 0, 2)
            fire_until_empty(ctx, unit)
            end_unit_turn(ctx, unit)
            return TAIL_EPILOGUE
        return _clever_tail(ctx, unit, defence=True)

    fire(ctx, unit)
    if not melee and unit.mp >= CLEVER_MELEE_MP:
        unit.mp -= CLEVER_MELEE_MP
    if melee:
        plan(ctx, unit, KIND_COVER, 0, 2)
    else:
        plan(ctx, unit, KIND_ENEMY, 0, 3)
        unit.mp = (unit.mp + CLEVER_MELEE_MP) & 0xFF
    fire_until_empty(ctx, unit)
    if not melee:
        return _clever_tail(ctx, unit, defence=True)
    plan(ctx, unit, KIND_COVER, 0, 2)
    fire_until_empty(ctx, unit)
    end_unit_turn(ctx, unit)
    return TAIL_EPILOGUE


# ---------------------------------------------------------------------------
# The shape of a turn -- aAISystemControl 0x00409940
# ---------------------------------------------------------------------------

def run_turn(ctx: AIContext, player: int = PLAYER_COMPUTER) -> AITurnResult:
    """``aAISystemControl(player, pass, redraw)`` -- the whole computer turn.

    Two passes, six levels inside each, and a ``repeat`` that re-runs the sweep
    of the 200 slots whenever some unit ended it with no movement points left.
    The redraw callback is not modelled -- ``core`` draws nothing -- and its
    only other effect, being invoked twice at each of three sites, is
    presentation.
    """
    result = ctx.result
    result.player = player
    result.seed_before = ctx.world.rng.seed

    special_player_control(ctx)

    for pass_index in range(PASSES):
        level = 0
        more = True
        while more:
            repeat = True
            while repeat:
                repeat = False
                result.sweeps += 1
                if result.sweeps > TURN_SWEEP_CEILING:
                    result.ok = False
                    result.reason = (
                        "the AI turn did not terminate within "
                        f"{TURN_SWEEP_CEILING} sweeps")
                    result.seed_after = ctx.world.rng.seed
                    return result
                for slot in range(200):
                    unit = ctx.world.units.get(slot)
                    if unit is None or unit.hp == 0:
                        continue
                    if unit.player != player:
                        continue
                    if unit.mp == 0:
                        continue
                    if pass_index == 0 and not _is_ranged(ctx, unit):
                        continue
                    run_order(ctx, unit, level)
                    # The common epilogue, and it is also order 8's arm and the
                    # out-of-range default: a unit that ended with nothing left
                    # earns the sweep another run.
                    if unit.mp == 0:
                        repeat = True
            if level == MAX_LEVEL:
                more = False
            else:
                level += 1

    reset_overlay(ctx)
    for slot in range(200):
        unit = ctx.world.units.get(slot)
        if unit is None or unit.hp == 0:
            continue
        if unit.player != player or unit.mp == 0:
            continue
        end_unit_turn(ctx, unit, CLOSING_SWEEP)
    result.seed_after = ctx.world.rng.seed
    return result


def _is_ranged(ctx: AIContext, unit: CombatUnit) -> bool:
    """Pass 0's gate: ``weaponInfo[u->weapon].rangeMax > 1``."""
    weapon = ctx.world.tables.weapons.get(unit.weapon)
    return weapon is not None and weapon.range_max > 1
