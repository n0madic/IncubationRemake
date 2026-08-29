"""An executable model of ``aGetMovePoints`` (``0x00475160``).  docs/10 §5.5.

The routine is the **single source** of a unit's movement points: nothing stores
them between turns (docs/25 §5), so every turn refresh and every ladder step
asks this function again.  The first vertical slice treated its answer as an
input; this module computes it, which is what closes docs/93 §9 item 2.

Two properties are transcription, not design, and a remake gets them wrong by
accident:

**The accumulator is a byte.**  ``bl`` holds the running total through the whole
routine, so ``dec bl`` on a zero wraps to 255 and the ``> 200`` guard at
``0x0047521F`` is what catches it.  Modelling the total as an unbounded integer
turns that guard into dead code and changes the answer for a type with
``mpMax == 0`` wearing Heavy Armor.

**The Banner scan does not exclude the carrier.**  ``0x0046FAD0`` walks all 200
slots without skipping the unit it was asked about, so a unit carrying its own
Banner gets the +1 from itself.

The distance metric was read off the code rather than assumed: the scan calls
``aGetDistance`` (``0x0044AE10``, ``floor(sqrt(dx^2+dy^2))``) and accepts
``< 4``, so the reach is **three fields, Euclidean** -- not four, and not
Chebyshev.  docs/10 §5.5 said "within 4 fields"; see :data:`BANNER_RANGE`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Sequence

from .movemap import distance

#: docs/10 §5 -- equipment ids the formula reads, as offsets into ``unit[+0x21]``.
EQUIP_BANNER = 8
EQUIP_HEAVY_ARMOR = 13
EQUIP_SERVO_SYSTEM = 14

#: ``0x0046FB31`` / ``0x0046FB6B`` -- ``cmp eax, 4; jl``, so a Banner counts at
#: a floor-Euclidean distance of 0, 1, 2 or 3 fields.
BANNER_RANGE = 4

#: ``0x0047521F`` -- ``cmp bl, 200; ja`` zeroes the byte accumulator.  This is
#: the underflow guard: a wrapped ``dec`` lands at 255 and is caught here.
ALLOWANCE_GUARD = 200

#: ``0x00475226`` -- action states that suppress movement entirely.
ACTION_STATE_SUPPRESSED = (5, 6)

#: ``0x00475207`` -- fitness points that override the whole computation.
FP_FORCED = {0: 1, 1: 2}

#: ``0x0047520F`` -- ``unit[+0x57]``, "did not act last turn".
RESTED = 1

#: ``0x0047516B`` -- the one unit type whose base allowance depends on the AI
#: level.  ``0x00460450`` returns 0, 1 or 2; anything else raises
#: "incorrect ai level!" and leaves the accumulator at zero.
DIFFICULTY_TWEAK_TYPE = 0x32
AI_LEVELS = (0, 1, 2)


class AllowanceError(Exception):
    """Raised when the formula is handed state it cannot evaluate."""


@dataclass(frozen=True)
class AllowanceUnit:
    """Everything ``0x00475160`` and its Banner scan read from a unit record."""

    slot: int
    type_id: int
    player: int
    x: int
    y: int
    #: ``+0x16``; zero means the slot is not live and the Banner scan skips it.
    hp: int = 1
    #: ``+0x19``.
    fp: int = 255
    #: ``+0x57``.
    rested: int = 0
    #: ``+0x41``.
    action_state: int = 0
    #: The 21 bytes at ``+0x21``, as the ids that are set.
    equipment_ids: frozenset[int] = field(default_factory=frozenset)

    def has(self, equipment_id: int) -> bool:
        return equipment_id in self.equipment_ids


def banner_in_range(mover: AllowanceUnit,
                    units: Iterable[AllowanceUnit]) -> bool:
    """``0x0046FAD0`` in its single-player form.

    The routine has two arms, chosen by ``0x0043B1F0``, which is true only for
    network game types 2, 3 and 4.  Single player takes the arm at
    ``0x0046FB38``: a live unit of the **same player** carrying the Banner,
    within :data:`BANNER_RANGE`.  The multiplayer arm relaxes the owner test to
    ``player <= 4`` and additionally refuses a mover owned by 255; it is not
    modelled here because nothing in this project runs a network game.
    """
    for other in units:
        if not other.hp:
            continue
        if other.player != mover.player:
            continue
        if not other.has(EQUIP_BANNER):
            continue
        if distance(mover.x, mover.y, other.x, other.y) < BANNER_RANGE:
            return True
    return False


def movement_allowance(mover: AllowanceUnit, mp_max: int,
                       units: Sequence[AllowanceUnit] = (),
                       ai_level: int = 1) -> int:
    """``aGetMovePoints(u)`` -- the movement points the unit has this turn.

    ``mp_max`` is ``SetUnitInfo[type].mpMax`` (docs/21 §4, ``+0x01``).  ``units``
    is the live unit array, needed only for the Banner scan.  ``ai_level`` is
    what ``0x00460450`` returns and matters only for type
    :data:`DIFFICULTY_TWEAK_TYPE`.
    """
    if mover.type_id == DIFFICULTY_TWEAK_TYPE:
        if ai_level not in AI_LEVELS:
            # The engine asserts "incorrect ai level!" and falls through with
            # the accumulator still zero.
            return 0
        # AI level 0 is the only arm that changes the base, and it takes one
        # off before any modifier applies.
        total = (mp_max - 1) & 0xFF if ai_level == 0 else mp_max & 0xFF
    else:
        total = mp_max & 0xFF

    if mover.has(EQUIP_SERVO_SYSTEM):
        total = (total + 1) & 0xFF
    if banner_in_range(mover, units):
        total = (total + 1) & 0xFF
    if mover.has(EQUIP_HEAVY_ARMOR):
        total = (total - 1) & 0xFF

    if mover.fp in FP_FORCED:
        # Exhaustion overrides everything above it, including the equipment.
        total = FP_FORCED[mover.fp]
    elif mover.rested == RESTED:
        total = (total + 1) & 0xFF

    if total > ALLOWANCE_GUARD:
        total = 0
    if mover.action_state in ACTION_STATE_SUPPRESSED:
        total = 0
    return total


def unit_from_record(raw: bytes, slot: int, *, offsets: dict[str, int],
                     equipment_slots: int) -> AllowanceUnit:
    """One live ``unit`` record from the engine's array into :class:`AllowanceUnit`."""
    equipment = raw[offsets["equipment"]:offsets["equipment"] + equipment_slots]
    return AllowanceUnit(
        slot=slot,
        type_id=raw[offsets["type"]],
        player=raw[offsets["player"]],
        x=raw[offsets["x"]],
        y=raw[offsets["y"]],
        hp=raw[offsets["hp"]],
        fp=raw[offsets["fp"]],
        rested=raw[offsets["rested"]],
        action_state=raw[offsets["action_state"]],
        equipment_ids=frozenset(i for i, v in enumerate(equipment) if v),
    )
