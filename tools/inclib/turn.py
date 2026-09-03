"""An executable model of the turn and the hand-over -- ``docs/25``.

Three routines and the state they run on:

* the **rotation**, ``0x0043B320`` with ``aSearchFirstPlayer`` ``0x0043B410``
  and the "is anyone left this turn" test ``0x0043B490`` (``docs/25`` §3.1);
* the **hand-over**, ``0x0047D600``, whose five steps include *running the
  mission script twice* -- which is why ``docs/20``'s interpreter had to exist
  before this file could (``docs/25`` §4);
* the **refresh**, ``0x004781C0``, and the short stat recompute ``0x004759B0``
  it calls (``docs/25`` §5).

Two corrections this module is built on, both read out of the shipped binary
rather than inherited from the prose:

**The refresh does restore the movement points.**  ``0x004759B0`` calls
``aGetMovePoints`` and stores the answer into ``+0x15``.  An earlier edition of
``docs/25`` §5 said the field was not stored at all; the corrected text quotes
the eight instructions.  The practical consequence is pleasant --
:mod:`inclib.allowance`, already pinned by 37 native calls, is exactly what the
hand-over restores from, so the first slice's work is what the second one
stands on.

**``0x004759B0`` and ``0x004759E0`` are different functions.**  ``docs/25``
named the first and ``docs/10`` the second, and the refresh calls the **short**
one (``0x00478306  call 0x4759b0``).  ``0x004759E0`` is the full derived-stat
rewrite the equipment system funnels through, and the hand-over never calls it.

What is deliberately **not** here: the AI's own turn (``docs/23`` -- the
computer gets the turn and ends it), the campaign layer's end-of-mission
scoring (``docs/27``), and the reaction queue (``docs/25`` §6), which is its own
module.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Callable, Sequence

from .allowance import AllowanceUnit, movement_allowance
from .info import BalanceTables

LOG = logging.getLogger("turn")

#: ``docs/25`` §2 -- the four game modes the binary names itself.
MODE_CAMPAIGN = 1
MODE_NET = 2
MODE_LOCAL = 3
MODE_PBM = 4

#: ``docs/25`` §3 -- ``0x0043B2A0``: ``u8 turn = ++g_turn; if (turn == 200)
#: g_turn = 0;``.  A guard, not a mechanic: a campaign resets the counter per
#: mission and never comes near it.
TURN_WRAP = 200

#: ``docs/25`` §3.1 -- the alien side is a full member of the rotation; the
#: neutral-prop owner never is, and the setter would reject it.
PLAYER_COMPUTER = 255

#: ``docs/25`` §3 -- ``0x0043B930`` returns 5 for a slot that is out.
END_STATE_OUT = 5

#: ``docs/25`` §5 -- ``+0x41``; 7 is "stood down without acting", which is what
#: earns the extra point of fitness and sets ``+0x57``.
ACTION_STOOD_DOWN = 7

#: ``docs/25`` §5 -- the fitness cap ``0x00475120`` returns for a type whose
#: ``FP max`` column is 255, i.e. one outside the fitness system altogether.
FP_NONE = 255
#: ``docs/21`` §5 column 7 -- ``max(rank, 3)`` for everything else.
FP_CAP_FLOOR = 3
#: ``docs/10`` §5 -- rank is ``EP / 12``.
EP_PER_RANK = 12

#: ``docs/25`` §5 -- heat falls by **two** for these three weapon ids and by one
#: for the rest.  They are *Double Fire*, *Rapid Fire Machine Gun* and its
#: alternate mode: the compiler wrote three successive ``sub eax, n; je``, so
#: the ids are the running sums 4, 4+2 and 6+35.
RAPID_FIRE_WEAPONS = (4, 6, 41)
#: ``docs/21`` §4 -- a weapon whose ``heat`` column is 255 never heats, so it
#: never cools either.
HEAT_NONE = 255

#: ``docs/25`` §5 -- five independent tests in ascending order, so no value
#: falls twice in one turn.  A light jam (2) costs two turns, a heavy one (5)
#: three.
MALFUNCTION_LADDER = {1: 0, 2: 1, 3: 0, 4: 3, 5: 4}

#: ``docs/25`` §7 -- the three revert sites all gate on ``>= 20``, and in every
#: shipped pair the base is at most 14 and the alternate at least 40.  So the
#: gate selects exactly the alternate member, and the engine only ever reverts.
WEAPON_ALTERNATE_MIN = 20

#: ``docs/25`` §8 -- ``+0x58``: 1 Light, 2 Heavy, and **255 means "spent this
#: turn"**.  The refresh turns 255 back into 0, so a stimulant is a
#: once-a-turn button rather than a consumable.
STIMULANT_SPENT = 255


class TurnError(Exception):
    """Raised when the model is handed turn state it cannot advance."""


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

@dataclass
class TurnState:
    """The turn half of the 720-byte block ``aSaveGameControl`` writes.

    ``docs/11`` §5.2 owns the file offsets; ``docs/25`` §3 owns the behaviour.
    Only what a turn reads is here.
    """

    #: ``0x00509E1D`` -- one byte.  0 means no hand-over has happened yet, and
    #: that is the test the hand-over itself uses to recognise the first one.
    turn: int = 0
    current_player: int = 0
    previous_player: int = 0
    #: ``0x0043B310`` -- the rotation's upper bound; 1 in the campaign.
    player_count: int = 1
    #: ``0x0043B6E0`` -- ``u32[4]``; 0 means the slot is not in the game and 1
    #: means a human.
    player_kind: list[int] = field(default_factory=lambda: [1, 0, 0, 0])
    #: ``0x0043B930`` -- ``5`` takes the slot out of the rotation.
    end_state: list[int] = field(default_factory=lambda: [0, 0, 0, 0])
    #: ``0x00509F08`` -- "the computer side plays".  Always set in a campaign.
    solo_flag: bool = True
    mode: int = MODE_CAMPAIGN
    #: ``0x00517F50`` -- zeroed by the refresh, so ticket numbering restarts
    #: every hand-over (``docs/25`` §6).
    reaction_counter: list[int] = field(default_factory=lambda: [0, 0, 0, 0])
    #: ``0x00460450``.  ``docs/93`` §11 left this to the campaign layer; the
    #: second slice chooses **1, normal**, and carries it in the turn state so
    #: it enters the canonical hash rather than sitting in a constant.
    ai_level: int = 1

    def human_count(self) -> int:
        """``0x0043B700`` -- slots whose kind is exactly 1."""
        return sum(1 for kind in self.player_kind if kind == 1)

    def advance_turn(self) -> int:
        """``0x0043B2A0``."""
        self.turn += 1
        if self.turn == TURN_WRAP:
            self.turn = 0
        return self.turn

    def to_dict(self) -> dict[str, Any]:
        return {
            "turn": self.turn,
            "current_player": self.current_player,
            "previous_player": self.previous_player,
            "player_count": self.player_count,
            "player_kind": list(self.player_kind),
            "end_state": list(self.end_state),
            "solo_flag": self.solo_flag,
            "mode": self.mode,
            "reaction_counter": list(self.reaction_counter),
            "ai_level": self.ai_level,
        }


@dataclass
class TurnUnit:
    """One unit slot, reduced to what the hand-over reads and writes.

    Every field is named for its record offset in ``docs/10`` §5, because that
    is what a native diff compares against.
    """

    slot: int
    type_id: int              # +0x4C
    player: int               # +0x45
    x: int                    # +0x42
    y: int                    # +0x43
    hp: int                   # +0x16
    mp: int = 0               # +0x15
    fp: int = 255             # +0x19
    ep: int = 0               # +0x17
    acted: int = 0            # +0x39
    action_state: int = 0     # +0x41
    rested: int = 0           # +0x57
    walked: int = 0           # +0x50
    turn_start_x: int = 0     # +0x51
    turn_start_y: int = 0     # +0x52
    stimulant: int = 0        # +0x58
    ticket: int = 0           # +0x59
    heat: int = 0             # +0x3E
    malfunction: int = 0      # +0x40
    weapon: int = 0           # +0x3F
    equipment_ids: frozenset[int] = field(default_factory=frozenset)

    @property
    def alive(self) -> bool:
        return self.hp > 0

    def to_allowance(self) -> AllowanceUnit:
        return AllowanceUnit(
            slot=self.slot, type_id=self.type_id, player=self.player,
            x=self.x, y=self.y, hp=self.hp, fp=self.fp, rested=self.rested,
            action_state=self.action_state, equipment_ids=self.equipment_ids)

    def to_dict(self) -> dict[str, Any]:
        return {
            "slot": self.slot, "mp": self.mp, "fp": self.fp,
            "acted": self.acted, "action_state": self.action_state,
            "rested": self.rested, "walked": self.walked,
            "turn_start_x": self.turn_start_x,
            "turn_start_y": self.turn_start_y,
            "stimulant": self.stimulant, "ticket": self.ticket,
            "heat": self.heat, "malfunction": self.malfunction,
            "weapon": self.weapon,
        }


# ---------------------------------------------------------------------------
# The per-unit routines -- docs/25 sections 5, 7 and 8
# ---------------------------------------------------------------------------

def max_fp(unit: TurnUnit, tables: BalanceTables) -> int:
    """``0x00475120`` -- the fitness cap, which is a **flag plus the rank**.

    ``docs/21`` §5 column 7: the stored ``FP max`` is never used as a value,
    only tested against 255.  The shipped file sets it to 0 for every human
    type and 255 for everything else, so aliens, machines and objects have no
    fitness and humans get ``max(3, EP / 12)``.
    """
    row = tables.units.get(unit.type_id)
    if row is None or row.fp_max == FP_NONE:
        return FP_NONE
    rank = unit.ep // EP_PER_RANK
    return FP_CAP_FLOOR if rank < FP_CAP_FLOOR else rank


def recompute_stats(unit: TurnUnit, tables: BalanceTables,
                    units: Sequence[TurnUnit], ai_level: int) -> None:
    """``0x004759B0`` -- three actions, in this order.

    Clear ``+0x39`` when it is set, ask ``aGetMovePoints`` and **store** the
    answer in ``+0x15``, then call ``0x0046F210``.  The third is the effect
    dispatcher and is outside this model; the first two are the whole reason a
    hand-over gives a unit its movement back.
    """
    if unit.acted > 0:
        unit.acted = 0
    row = tables.units.get(unit.type_id)
    mp_max = 0 if row is None else row.mp_max
    unit.mp = movement_allowance(unit.to_allowance(), mp_max,
                                 [u.to_allowance() for u in units], ai_level)


def revert_weapon_mode(unit: TurnUnit, tables: BalanceTables) -> None:
    """``aToggleWeaponModes`` ``0x0047A8C0`` behind the three sites' ``>= 20``.

    ``docs/25`` §7: the toggle column is an involution, the base of every pair
    is at most 14 and the alternate at least 40, so the gate means "revert".
    The engine never switches *into* a mode here; only the player's own command
    does, and it does not survive the hand-over.
    """
    if unit.weapon < WEAPON_ALTERNATE_MIN:
        return
    row = tables.weapons.get(unit.weapon)
    if row is not None and row.toggle != unit.weapon:
        unit.weapon = row.toggle


def cool_weapon(unit: TurnUnit, tables: BalanceTables) -> None:
    """``docs/25`` §5 -- heat falls by one, or by two for the rapid-fire ids."""
    row = tables.weapons.get(unit.weapon)
    if row is None or row.heat == HEAT_NONE:
        return
    if unit.weapon in RAPID_FIRE_WEAPONS:
        if unit.heat > 1:
            unit.heat -= 2
        elif unit.heat:
            unit.heat -= 1
    elif unit.heat:
        unit.heat -= 1


def regenerate_fitness(unit: TurnUnit, cap: int, banner: bool) -> None:
    """``docs/25`` §5 -- at most +3 in one turn, snapping to the cap.

    One for having stood down, then one or two for a Banner in range.  The
    order matters: the stand-down point is added first and only when there is
    room for it, and the Banner arm then snaps rather than overshooting.
    """
    if unit.fp == FP_NONE or unit.fp == cap:
        return
    if unit.action_state == ACTION_STOOD_DOWN and unit.fp + 1 < cap:
        unit.fp += 1
    if banner:
        unit.fp = unit.fp + 2 if unit.fp + 2 < cap else cap
    elif unit.fp != 0:
        unit.fp = unit.fp + 1 if unit.fp + 1 < cap else cap


def stand_down(unit: TurnUnit) -> None:
    """``0x00478570`` -- spend the rest of the turn, for one point of fitness."""
    unit.action_state = ACTION_STOOD_DOWN
    unit.mp = 0


def spend_stimulant(unit: TurnUnit) -> bool:
    """``0x004785B0`` -- once a turn, and **not** consumed.

    ``docs/25`` §8: 255 means "spent this turn" and the refresh turns it back
    into 0.  The movement points go up by the **old** value, which is what
    makes the Heavy Stimulant worth two.
    """
    if unit.stimulant in (0, STIMULANT_SPENT):
        return False
    unit.mp += unit.stimulant
    unit.stimulant = STIMULANT_SPENT
    return True


def end_unit_turn(unit: TurnUnit) -> None:
    """``0x0040B380`` -- the computer's per-unit epilogue; zero the points."""
    unit.mp = 0


# ---------------------------------------------------------------------------
# The refresh -- docs/25 section 5
# ---------------------------------------------------------------------------

def refresh_player(state: TurnState, player: int, units: Sequence[TurnUnit],
                   tables: BalanceTables,
                   banner_of: Callable[[TurnUnit], bool]) -> list[int]:
    """``0x004781C0`` -- what a hand-over restores for the incoming player.

    Returns the slots it touched.  ``banner_of`` is the Banner test
    (``0x0046FAD0``), passed in rather than recomputed so a caller that already
    has the live unit array does not pay for it twice.

    ``aBuildVisibleMap`` is the routine's first act and belongs to
    ``docs/22`` §9; the caller runs it, because visibility is not this module's.
    """
    for index in range(len(state.reaction_counter)):
        state.reaction_counter[index] = 0

    touched: list[int] = []
    for unit in units:
        if unit.player != player or not unit.alive:
            continue
        touched.append(unit.slot)

        regenerate_fitness(unit, max_fp(unit, tables), banner_of(unit))

        if unit.stimulant == STIMULANT_SPENT:
            unit.stimulant = 0
        unit.turn_start_x, unit.turn_start_y = unit.x, unit.y
        unit.walked = 0
        unit.rested = 1 if unit.action_state == ACTION_STOOD_DOWN else 0
        recompute_stats(unit, tables, units, state.ai_level)
        # After the recompute, not before: `0x004759B0` reads `+0x41` through
        # `aGetMovePoints`, where states 5 and 6 zero the allowance.
        unit.action_state = 0

        cool_weapon(unit, tables)
        unit.ticket = 0
        revert_weapon_mode(unit, tables)
        unit.malfunction = MALFUNCTION_LADDER.get(unit.malfunction,
                                                  unit.malfunction)
    return touched


# ---------------------------------------------------------------------------
# The rotation -- docs/25 section 3.1
# ---------------------------------------------------------------------------

def skip_rule_applies(state: TurnState) -> bool:
    """``0x0043B1F0`` -- the gate in front of the "no units left" skip.

    True **only** in a net or pbm session, or a local session with more than
    one human.  A shipped single-player campaign fails it, so it never skips a
    player -- which is why the first hand-over of a mission reaches every slot
    even before the script has placed anybody.
    """
    if not state.solo_flag:
        return False
    if state.mode in (MODE_NET, MODE_PBM):
        return True
    return state.mode == MODE_LOCAL and state.human_count() > 1


def _slot_qualifies(state: TurnState, slot: int,
                    live_units: Callable[[int], int]) -> bool:
    if state.player_kind[slot] == 0:
        return False
    if state.end_state[slot] == END_STATE_OUT:
        return False
    if not skip_rule_applies(state):
        return True
    if state.turn == 0:
        # The very first hand-over never skips anybody: units can still be
        # placed by the mission script after the map loads.
        return True
    return live_units(slot) > 0


def search_first_player(state: TurnState,
                        live_units: Callable[[int], int]) -> bool:
    """``aSearchFirstPlayer`` ``0x0043B410`` -- the same loop, from slot 0."""
    for slot in range(state.player_count):
        if _slot_qualifies(state, slot, live_units):
            state.current_player = slot
            return True
    return False


def advance_player(state: TurnState,
                   live_units: Callable[[int], int]) -> bool:
    """``0x0043B320`` -- whose turn is next.

    ``docs/25`` §3.1: player 255 is a full member and takes its turn after the
    last human slot, and only when the solo flag is set.  In the campaign the
    rotation therefore has exactly two members and cycles 0, 255, 0, ...
    """
    state.previous_player = state.current_player
    if state.current_player == PLAYER_COMPUTER:
        if search_first_player(state, live_units):
            return True
        state.current_player = PLAYER_COMPUTER
        return True
    while state.current_player < state.player_count - 1:
        state.current_player += 1
        if _slot_qualifies(state, state.current_player, live_units):
            return True
    if state.solo_flag:
        state.current_player = PLAYER_COMPUTER
        return True
    return search_first_player(state, live_units)


def any_player_left_this_turn(state: TurnState,
                              live_units: Callable[[int], int]) -> bool:
    """``0x0043B490`` -- the same skip rule over the slots *after* this one.

    Two extra clauses ``docs/25`` §4 records: it answers **no** outright when
    the computer is already the current player, because the computer moves
    last; and when no later slot qualifies it answers with the solo flag,
    because the computer still owes a turn.
    """
    if state.current_player == PLAYER_COMPUTER:
        return False
    for slot in range(state.current_player + 1, state.player_count):
        if _slot_qualifies(state, slot, live_units):
            return True
    return state.solo_flag


# ---------------------------------------------------------------------------
# The hand-over -- docs/25 section 4
# ---------------------------------------------------------------------------

#: What ``0x0047D600`` returns; ``aNextPlayerHandling`` dispatches on it.
HANDOVER_STOPPED = 0
"""The mission script returned zero, the mission ended, or no player is left."""
HANDOVER_OK = 1
HANDOVER_REMOTE = 2
"""Net session: the incoming player is somebody else's."""
HANDOVER_FIRST_NET = 3


@dataclass
class HandOverResult:
    """What one hand-over did -- a value, like every other result here."""

    code: int
    turn: int
    player: int
    previous_player: int
    turn_script: Any = None
    """The ``NEXT TURN`` invocation's outcome, or ``None`` if it did not run."""
    ground: Any = None
    """What the two ground sweeps did, or ``None`` when the round did not turn.

    ``0x00470AB0`` and ``0x0042ED60`` run between the turn counter going up and
    the ``NEXT TURN`` event, so they are a **round** tick: glows ignite and
    kill, then glows, fires and shields decay (``docs/42`` §9.1)."""
    player_script: Any = None
    """The ``NEXT PLAYER`` invocation's outcome, or ``None``."""
    mission_ended: bool = False
    refreshed: list[int] = field(default_factory=list)
    ai_turn: bool = False
    """Whether the incoming player is 255, i.e. whether ``docs/23`` runs."""

    @property
    def ok(self) -> bool:
        return self.code != HANDOVER_STOPPED

    def to_dict(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "turn": self.turn,
            "player": self.player,
            "previous_player": self.previous_player,
            "turn_script": (None if self.turn_script is None
                            else self.turn_script.to_dict()),
            "ground": self.ground,
            "player_script": (None if self.player_script is None
                              else self.player_script.to_dict()),
            "mission_ended": self.mission_ended,
            "refreshed": list(self.refreshed),
            "ai_turn": self.ai_turn,
        }


#: ``docs/20`` §7.4 and ``docs/27`` §6.3 -- the hand-over's mission-end test is
#: a short-circuit OR over game-control slots 0..4, inlined at ``0x0047D88B``.
MISSION_END_SLOTS = range(0, 5)


def mission_ended(game_control: Sequence[int]) -> bool:
    """``0x0047D88B`` -- any of slots 0..4 set ends the mission."""
    return any(game_control[slot] for slot in MISSION_END_SLOTS)


def hand_over(state: TurnState, units: Sequence[TurnUnit],
              tables: BalanceTables,
              game_control: Sequence[int],
              run_script: Callable[[int, dict[int, int]], Any],
              banner_of: Callable[[TurnUnit], bool],
              arg: int = 0,
              ground_tick: Callable[[], Any] | None = None) -> HandOverResult:
    """``0x0047D600`` -- the five steps, in the order the body has them.

    ``run_script(call_type, env)`` runs the mission program and returns
    something with an ``ok`` property: :class:`inclib.lcl_runtime.Outcome` in
    the corpus check, the engine itself in a native capture.  Passing it in is
    what keeps this module free of the interpreter, and what makes "the
    hand-over runs the script twice" visible rather than buried.

    The order settles two things a remake would otherwise guess at
    (``docs/25`` §4):

    * **a turn advances when nobody is left to move**, not at a fixed point --
      so ``NEXT TURN`` fires from the *last* player's hand-over, not the first;
    * **the two events carry different environments**: ``NEXT TURN`` sets only
      ``_B``, ``NEXT PLAYER`` sets ``_B`` and ``_C``.

    Both script runs are checked: a zero return stops the hand-over where it
    stands, leaving the current player unchanged.  That is what
    ``docs/20`` §2.2's "report, then return 0" costs at this level.
    """
    from .lcl_runtime import (CALL_NEXT_PLAYER, CALL_NEXT_TURN,  # noqa: PLC0415
                              mission_env)

    def live_units(slot: int) -> int:
        return sum(1 for u in units if u.player == slot and u.alive)

    result = HandOverResult(code=HANDOVER_OK, turn=state.turn,
                            player=state.current_player,
                            previous_player=state.previous_player)

    if arg == 0:
        if not any_player_left_this_turn(state, live_units):
            state.advance_turn()
            result.turn = state.turn
            # `0x00470AB0(); 0x0042ED60();` -- between the counter and the
            # event, which is what makes the ground effects a round tick.
            if ground_tick is not None:
                result.ground = ground_tick()
            result.turn_script = run_script(
                CALL_NEXT_TURN, mission_env(CALL_NEXT_TURN, turn=state.turn))
            if not result.turn_script.ok:
                result.code = HANDOVER_STOPPED
                return result
        if state.turn != 0:
            result.player_script = run_script(
                CALL_NEXT_PLAYER,
                mission_env(CALL_NEXT_PLAYER, turn=state.turn,
                            player=state.current_player))
            if not result.player_script.ok:
                result.code = HANDOVER_STOPPED
                return result
            if mission_ended(game_control):
                result.mission_ended = True
                result.code = HANDOVER_STOPPED
                return result
        if not advance_player(state, live_units):
            result.code = HANDOVER_STOPPED
            return result
    else:
        if not search_first_player(state, live_units):
            result.code = HANDOVER_STOPPED
            return result
        if state.mode == MODE_NET and state.turn == 0:
            result.code = HANDOVER_FIRST_NET

    result.refreshed = refresh_player(state, state.current_player, units,
                                      tables, banner_of)
    result.turn = state.turn
    result.player = state.current_player
    result.previous_player = state.previous_player
    result.ai_turn = (state.current_player == PLAYER_COMPUTER
                      and state.turn != 0)
    return result
