#!/usr/bin/env python3
"""Run the turn model over the corpus -- ``docs/25``.

The refresh and the rotation are exercised against **every shipped unit on
every shipped map**: all 155 ``.lev`` files, including the two in
``Missions/backup``, and every unit placed on them.  What the check asserts is
what ``docs/25`` states and a wrong implementation would violate:

* fitness never exceeds the cap ``0x00475120`` returns, and never moves by more
  than three in one turn;
* movement points after a refresh equal ``aGetMovePoints`` -- which is the
  corrected §5: the refresh **stores** them (``0x004759C9``), it does not leave
  them to be computed;
* heat falls by exactly one, or by two for the three rapid-fire weapon ids, and
  never below zero;
* the malfunction ladder is monotone and no value falls twice in one turn;
* the per-turn bookkeeping is reset: ``+0x50`` to zero, ``+0x51``/``+0x52`` to
  the unit's position, ``+0x59`` to zero, ``+0x41`` to zero, and ``+0x58``'s
  "spent" marker back to 0;
* the rotation of a campaign has exactly two members and never skips a slot.

Usage::

    turn_runtime.py --check gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib import lcl                                              # noqa: E402
from inclib import lcl_runtime as lclrt                             # noqa: E402
from inclib import turn as turnmod                                  # noqa: E402
from inclib.allowance import banner_in_range, movement_allowance    # noqa: E402
from inclib.check import Checker                                    # noqa: E402
from inclib.info import BalanceTables, load_info_file               # noqa: E402
from inclib.lev import BattleMap, load_lev                          # noqa: E402
from inclib.script import script_document                           # noqa: E402

LOG = logging.getLogger("turn_runtime")

#: ``docs/25`` §5 -- one for standing down plus two for a Banner.
MAX_FITNESS_GAIN_PER_TURN = 3


def units_of(bm: BattleMap) -> list[turnmod.TurnUnit]:
    """Every placed slot, as the record the hand-over reads and writes."""
    out: list[turnmod.TurnUnit] = []
    for u in bm.units:
        if not u.placed:
            continue
        out.append(turnmod.TurnUnit(
            slot=u.slot, type_id=u.type_id, player=u.player, x=u.x, y=u.y,
            hp=u.hit_points, mp=u.action_points, fp=u.fp, ep=u.ep,
            acted=u.acted, action_state=u.action_state, rested=u.rested,
            walked=u.walked, turn_start_x=u.turn_start_x,
            turn_start_y=u.turn_start_y, stimulant=u.stimulant,
            ticket=u.ticket, heat=u.heat, malfunction=u.malfunction,
            weapon=u.weapon, equipment_ids=frozenset(u.equipment_ids)))
    return out


def _banner_of(units: list[turnmod.TurnUnit]):
    allowance = [u.to_allowance() for u in units]

    def test(unit: turnmod.TurnUnit) -> bool:
        return banner_in_range(unit.to_allowance(), allowance)

    return test


def _campaign_state() -> turnmod.TurnState:
    """``docs/25`` §2 and §3: mode 1 gives one player slot and sets the flag."""
    return turnmod.TurnState(turn=0, current_player=0, player_count=1,
                             player_kind=[1, 0, 0, 0], solo_flag=True,
                             mode=turnmod.MODE_CAMPAIGN)


def check_refresh(c: Checker, root: Path, tables: BalanceTables) -> int:
    """Refresh every placed unit of every mission and assert the invariants."""
    # Recursive, so the two files in `Missions/backup` are covered too: every
    # other corpus check in this repository states 155/155, and one that
    # quietly examined 153 would not be the same claim.
    levs = sorted(root.rglob("*.lev"))
    total_units = 0
    fp_over_cap: list[str] = []
    fp_jumped: list[str] = []
    mp_wrong: list[str] = []
    heat_wrong: list[str] = []
    malfunction_wrong: list[str] = []
    bookkeeping_wrong: list[str] = []
    action_wrong: list[str] = []

    for lev in levs:
        bm = load_lev(str(lev))
        units = units_of(bm)
        if not units:
            continue
        state = _campaign_state()
        banner = _banner_of(units)
        by_player: dict[int, list[turnmod.TurnUnit]] = {}
        for unit in units:
            by_player.setdefault(unit.player, []).append(unit)

        for player, group in sorted(by_player.items()):
            before = {u.slot: (u.fp, u.heat, u.malfunction, u.action_state)
                      for u in group}
            caps = {u.slot: turnmod.max_fp(u, tables) for u in group}
            turnmod.refresh_player(state, player, units, tables, banner)
            total_units += len(group)

            for unit in group:
                where = f"{lev.stem}:{unit.slot}"
                fp0, heat0, malf0, action0 = before[unit.slot]
                cap = caps[unit.slot]

                if cap != turnmod.FP_NONE and unit.fp > cap:
                    fp_over_cap.append(f"{where} fp {unit.fp} > cap {cap}")
                if unit.fp != turnmod.FP_NONE and fp0 != turnmod.FP_NONE:
                    if unit.fp - fp0 > MAX_FITNESS_GAIN_PER_TURN:
                        fp_jumped.append(
                            f"{where} fp {fp0} -> {unit.fp}")
                    if unit.fp < fp0:
                        fp_jumped.append(f"{where} fp fell {fp0} -> {unit.fp}")

                # The corrected docs/25 §5: the refresh stores what
                # `aGetMovePoints` returns.  Recomputing it here against the
                # state the refresh left is the whole point -- the allowance
                # reads `+0x19`, `+0x57` and `+0x41`, all of which the refresh
                # has just rewritten.
                row = tables.units.get(unit.type_id)
                want = movement_allowance(
                    unit.to_allowance(), 0 if row is None else row.mp_max,
                    [u.to_allowance() for u in units], state.ai_level)
                if unit.mp != want:
                    mp_wrong.append(f"{where} mp {unit.mp} != {want}")

                weapon = tables.weapons.get(unit.weapon)
                if weapon is not None and weapon.heat != turnmod.HEAT_NONE:
                    step = 2 if unit.weapon in turnmod.RAPID_FIRE_WEAPONS else 1
                    want_heat = max(heat0 - step, 0) if heat0 else 0
                    if heat0 == 1 and step == 2:
                        want_heat = 0
                    if unit.heat != want_heat:
                        heat_wrong.append(
                            f"{where} heat {heat0} -> {unit.heat}, "
                            f"expected {want_heat}")
                if unit.heat < 0:
                    heat_wrong.append(f"{where} heat went negative")

                want_malf = turnmod.MALFUNCTION_LADDER.get(malf0, malf0)
                if unit.malfunction != want_malf:
                    malfunction_wrong.append(
                        f"{where} malfunction {malf0} -> {unit.malfunction}, "
                        f"expected {want_malf}")
                if unit.malfunction > malf0:
                    malfunction_wrong.append(f"{where} malfunction rose")

                if (unit.walked != 0 or unit.ticket != 0
                        or unit.turn_start_x != unit.x
                        or unit.turn_start_y != unit.y
                        or unit.stimulant == turnmod.STIMULANT_SPENT):
                    bookkeeping_wrong.append(where)
                if unit.action_state != 0:
                    action_wrong.append(f"{where} action {unit.action_state}")
                if unit.rested != (1 if action0
                                   == turnmod.ACTION_STOOD_DOWN else 0):
                    action_wrong.append(f"{where} rested {unit.rested}")

    c.check("refresh.units_seen", total_units > 0,
            f"{total_units} placed unit(s) over {len(levs)} mission(s)")
    c.expect("refresh.fp_within_cap", fp_over_cap[:5], [])
    c.expect("refresh.fp_moves_at_most_three", fp_jumped[:5], [])
    c.expect("refresh.mp_equals_allowance", mp_wrong[:5], [])
    c.expect("refresh.heat_falls_by_one_or_two", heat_wrong[:5], [])
    c.expect("refresh.malfunction_ladder", malfunction_wrong[:5], [])
    c.expect("refresh.per_turn_bookkeeping_reset", bookkeeping_wrong[:5], [])
    c.expect("refresh.action_state_and_rested", action_wrong[:5], [])
    return total_units


def check_ladder(c: Checker) -> None:
    """The two per-unit ladders, as tables rather than as behaviour."""
    ladder = turnmod.MALFUNCTION_LADDER
    c.expect("ladder.malfunction_values", sorted(ladder.items()),
             [(1, 0), (2, 1), (3, 0), (4, 3), (5, 4)])
    c.check("ladder.monotone", all(v < k for k, v in ladder.items()),
            "every jam state falls, and none falls twice in one turn")
    # docs/10 §5.12: a light jam is 2 and a heavy one 5; two turns and three.
    def turns_to_clear(value: int) -> int:
        steps = 0
        while value:
            value = ladder.get(value, value)
            steps += 1
            if steps > 10:
                return steps
        return steps
    c.expect("ladder.light_jam_costs_two_turns", turns_to_clear(2), 2)
    c.expect("ladder.heavy_jam_costs_three_turns", turns_to_clear(5), 3)


def check_rotation(c: Checker) -> None:
    """``docs/25`` §3.1 -- the campaign's rotation and the skip rule's gate."""
    def live(_slot: int) -> int:
        return 0                      # nobody has any units: the harshest case

    state = _campaign_state()
    c.check("rotation.campaign_never_skips", not turnmod.skip_rule_applies(state),
            "mode 1 fails 0x0043B1F0, so a shipped campaign never skips a slot")

    # 0, 255, 0, 255, ... -- two members, forever.
    seen: list[int] = []
    for _ in range(6):
        turnmod.advance_player(state, live)
        seen.append(state.current_player)
    c.expect("rotation.campaign_cycle", seen, [255, 0, 255, 0, 255, 0])

    # `0x0043B490`: the computer moves last, so it is never "someone left".
    state = _campaign_state()
    state.current_player = turnmod.PLAYER_COMPUTER
    c.check("rotation.computer_is_last",
            not turnmod.any_player_left_this_turn(state, live),
            "a hand-over from 255 always advances the turn counter")
    state = _campaign_state()
    c.check("rotation.solo_flag_owes_the_computer_a_turn",
            turnmod.any_player_left_this_turn(state, live),
            "no later human slot, but the solo flag says 255 still owes one")

    # The skip rule needs a network mode *and* the solo flag.
    net = turnmod.TurnState(mode=turnmod.MODE_NET, solo_flag=True,
                            player_count=4, player_kind=[1, 1, 0, 0])
    c.check("rotation.skip_rule_in_net_session",
            turnmod.skip_rule_applies(net), "mode 2 with the solo flag")
    local = turnmod.TurnState(mode=turnmod.MODE_LOCAL, solo_flag=True,
                              player_count=4, player_kind=[1, 1, 0, 0])
    c.check("rotation.skip_rule_local_needs_two_humans",
            turnmod.skip_rule_applies(local), "mode 3 with two humans")
    local_one = turnmod.TurnState(mode=turnmod.MODE_LOCAL, solo_flag=True,
                                  player_count=4, player_kind=[1, 0, 0, 0])
    c.check("rotation.skip_rule_local_one_human",
            not turnmod.skip_rule_applies(local_one), "mode 3, one human")

    # A slot that is out (end state 5) is skipped even when the rule does not
    # apply: that test sits before the gate.
    out = turnmod.TurnState(mode=turnmod.MODE_LOCAL, solo_flag=False,
                            player_count=4, player_kind=[1, 1, 1, 1],
                            end_state=[0, 5, 0, 0], current_player=0)
    turnmod.advance_player(out, live)
    c.expect("rotation.end_state_5_is_out", out.current_player, 2)

    # The very first hand-over never skips anybody: turn 0 escapes the rule.
    first = turnmod.TurnState(mode=turnmod.MODE_NET, solo_flag=True, turn=0,
                              player_count=4, player_kind=[1, 1, 1, 1],
                              current_player=0)
    turnmod.advance_player(first, live)
    c.expect("rotation.turn_zero_never_skips", first.current_player, 1)
    later = turnmod.TurnState(mode=turnmod.MODE_NET, solo_flag=True, turn=3,
                              player_count=4, player_kind=[1, 1, 1, 1],
                              current_player=0)
    turnmod.advance_player(later, live)
    c.expect("rotation.later_turns_skip_the_unitless", later.current_player,
             turnmod.PLAYER_COMPUTER)

    # The counter wraps at 200 and nothing else touches it.
    wrap = turnmod.TurnState(turn=199)
    c.expect("rotation.turn_wraps_at_200", wrap.advance_turn(), 0)
    step = turnmod.TurnState(turn=5)
    c.expect("rotation.turn_advances_by_one", step.advance_turn(), 6)


def check_per_unit(c: Checker, tables: BalanceTables) -> None:
    """``docs/25`` §8 -- stand down, the stimulant, and ending a unit's turn."""
    def unit(**kw: Any) -> turnmod.TurnUnit:
        base = dict(slot=0, type_id=0, player=0, x=0, y=0, hp=10)
        base.update(kw)
        return turnmod.TurnUnit(**base)  # type: ignore[arg-type]

    u = unit(mp=4)
    turnmod.stand_down(u)
    c.expect("stand_down.zeroes_mp", u.mp, 0)
    c.expect("stand_down.sets_action_7", u.action_state, 7)

    u = unit(mp=3, stimulant=2)
    c.check("stimulant.spends", turnmod.spend_stimulant(u))
    c.expect("stimulant.adds_the_old_value", u.mp, 5)
    c.expect("stimulant.marks_spent", u.stimulant, turnmod.STIMULANT_SPENT)
    c.check("stimulant.only_once_a_turn", not turnmod.spend_stimulant(u),
            "255 refuses a second spend in the same turn")
    # ... and the refresh gives it back, which is what makes it a button.
    state = _campaign_state()
    turnmod.refresh_player(state, 0, [u], tables, lambda _u: False)
    c.expect("stimulant.refresh_restores_the_button", u.stimulant, 0)

    u = unit(mp=6)
    turnmod.end_unit_turn(u)
    c.expect("end_unit_turn.zeroes_mp", u.mp, 0)

    # docs/25 §7: the revert gate is `>= 20`, so a base weapon is left alone.
    pairs = [(w.id, w.toggle) for w in tables.weapons.values()
             if w.toggle and w.toggle != w.id]
    c.check("weapon.toggle_is_an_involution",
            all(tables.weapons[b].toggle == a for a, b in pairs
                if b in tables.weapons),
            f"{len(pairs)} paired weapon id(s)")
    alternates = [b for a, b in pairs if b > a]
    c.check("weapon.alternates_are_all_at_least_20",
            bool(alternates) and min(alternates) >= turnmod.WEAPON_ALTERNATE_MIN,
            f"alternates {sorted(alternates)}")
    bases = [a for a, b in pairs if b > a]
    c.check("weapon.bases_are_all_below_20",
            bool(bases) and max(bases) < turnmod.WEAPON_ALTERNATE_MIN,
            f"bases {sorted(bases)}")
    for base, alt in sorted((a, b) for a, b in pairs if b > a)[:1]:
        u = unit(weapon=alt)
        turnmod.revert_weapon_mode(u, tables)
        c.expect("weapon.alternate_reverts_to_base", u.weapon, base)
        u = unit(weapon=base)
        turnmod.revert_weapon_mode(u, tables)
        c.expect("weapon.base_is_left_alone", u.weapon, base)


def check_hand_over(c: Checker, root: Path, tables: BalanceTables) -> None:
    """``docs/25`` §4 on ``_C_140`` -- the five steps, in order.

    The hand-over is the one place the turn and the mission script meet, so
    this is also where ``inclib.lcl_runtime`` is exercised as the engine calls
    it rather than as a corpus sweep.
    """
    name = "_C_140"
    bm = load_lev(str(root / "Missions" / f"{name}.lev"))
    document = script_document(
        lcl.parse_file(str(root / "Missions" / f"{name}.lcl")), {})
    units = units_of(bm)
    state = _campaign_state()
    world = lclrt.LclWorld(bm, tables, turn=state.turn, player=0,
                           ai_level=state.ai_level)
    calls: list[int] = []
    player_env_c: list[int] = []

    def run_script(call_type: int, env: dict[int, int]) -> Any:
        calls.append(call_type)
        if call_type == lclrt.CALL_NEXT_PLAYER:
            player_env_c.append(env[ord("C") - ord("A")])
        world.turn = state.turn
        world.player = state.current_player
        return lclrt.run(document, world, env)

    def step() -> Any:
        calls.clear()
        return turnmod.hand_over(state, units, tables, world.game_control,
                                 run_script, _banner_of(units))

    # Hand-over 1, from player 0.  `0x0043B490` answers with the solo flag
    # because the computer still owes a turn, so the counter does **not**
    # advance -- and with it still 0, the `if (g_turn != 0)` guard skips
    # NEXT PLAYER too.  The first hand-over of a campaign therefore runs no
    # script at all; it just gives the turn to the computer.
    first = step()
    c.expect("handover.first.runs_no_script", calls, [])
    c.expect("handover.first.turn_counter", first.turn, 0)
    c.expect("handover.first.player", first.player, turnmod.PLAYER_COMPUTER)
    c.check("handover.first.ai_turn_not_on_turn_zero", not first.ai_turn,
            "0x0047D600 gates aAISystemControl on g_turn != 0")

    # Hand-over 2, from 255.  The computer moves last, so now the counter
    # advances and both events fire, in this order.
    second = step()
    c.expect("handover.second.calls", calls,
             [lclrt.CALL_NEXT_TURN, lclrt.CALL_NEXT_PLAYER])
    c.expect("handover.second.turn_counter", second.turn, 1)
    c.expect("handover.second.player", second.player, 0)
    c.expect("handover.second.previous_player", second.previous_player,
             turnmod.PLAYER_COMPUTER)
    c.expect("handover.second.scripts_ended_cleanly",
             [second.turn_script.kind, second.player_script.kind],
             [lclrt.OUTCOME_END, lclrt.OUTCOME_END])
    c.check("handover.second.refreshed_the_squad",
            len(second.refreshed) == 4,
            f"{len(second.refreshed)} unit(s) of player 0")

    # Hand-over 3, back from player 0.  The counter is 1 now, so the
    # `if (g_turn != 0)` guard passes and NEXT PLAYER fires -- but the computer
    # still owes a turn, so NEXT TURN does not.  That is the vocabulary of
    # docs/25 §1 made mechanical: **NEXT PLAYER is once per player's slice and
    # NEXT TURN is once per pass through everybody.**
    third = step()
    c.expect("handover.third.calls", calls, [lclrt.CALL_NEXT_PLAYER])
    c.expect("handover.third.player", third.player, turnmod.PLAYER_COMPUTER)
    c.expect("handover.third.turn_counter", third.turn, 1)

    # The rotation is two members wide and the counter goes up once per full
    # cycle, not once per hand-over.
    fourth = step()
    c.expect("handover.fourth.calls", calls,
             [lclrt.CALL_NEXT_TURN, lclrt.CALL_NEXT_PLAYER])
    c.expect("handover.fourth.turn_counter", fourth.turn, 2)
    c.expect("handover.cycle", [first.player, second.player, third.player,
                                fourth.player],
             [turnmod.PLAYER_COMPUTER, 0, turnmod.PLAYER_COMPUTER, 0])

    # NEXT PLAYER carries the **outgoing** player, because `0x0047D600` runs the
    # script before `advancePlayer`.  So `_C` alternates 255, 0, 255 rather than
    # naming whose turn is about to start -- which is a good reason no shipped
    # script reads it: docs/20 §5.1's census finds 153 reads of `_B` in
    # NextPlayer and not one of `_C`.
    c.expect("handover.next_player_carries_the_outgoing_player",
             player_env_c, [turnmod.PLAYER_COMPUTER, 0,
                            turnmod.PLAYER_COMPUTER])

    # And the mission end: with the squad in the evacuation zone the script
    # sets game-control slot 0, and the hand-over stops there rather than
    # advancing the player.
    zone = [(3, 18), (4, 18), (5, 18), (6, 18)]
    squad = sorted((u for u in units if u.player == 0 and u.alive),
                   key=lambda u: u.slot)
    for unit, (tx, ty) in zip(squad, zone):
        world.unit_at[world.index(unit.x, unit.y)] = -1
        unit.x, unit.y = tx, ty
        for live in world.units.values():
            if live.slot == unit.slot:
                live.x, live.y = tx, ty
        world.unit_at[world.index(tx, ty)] = unit.slot
    step()                          # from player 0: no script, hands to 255
    ended = step()                  # from 255: NEXT PLAYER sees the win
    c.check("handover.mission_ends_on_the_win", ended.mission_ended,
            f"game control {world.game_control[:5]}")
    c.expect("handover.mission_end_stops_the_hand_over", ended.code,
             turnmod.HANDOVER_STOPPED)
    c.expect("handover.win_is_game_control_slot_0", world.game_control[0], 1)


#: The document ``godot/tests/test_handover.gd`` replays.
HANDOVER_CASES_SCHEMA = "incubation.handover-cases/1"

#: Where ``_C_140``'s squad has to stand for the mission to be won -- the
#: evacuation zone ``docs/27`` names and the mission's own script tests.
EVACUATION_ZONE = ((3, 18), (4, 18), (5, 18), (6, 18))

#: How many ordinary hand-overs the emitted trace runs before the win.
#:
#: Eight is four full cycles of the campaign's two-member rotation, which
#: reaches **turn 4** -- the turn ``_C_140``'s ``NextTurn`` opens its two tubes
#: on and sets an action point.  It is also one short of where the trace stops
#: being able to say anything, and that boundary is checked rather than
#: trusted: see :func:`_check_one_unit_array`.
HANDOVER_STEPS = 8


class _Refused:
    """A mission script that reported and returned zero -- ``docs/20`` §2.2.

    ``hand_over`` reads nothing but ``ok``, so this is the whole of it.  It
    exists because **no shipped script refuses**: every one of the 153 ends
    cleanly, so a trace taken from the corpus alone leaves the abort arm of
    ``if (!runProgram()) return 0;`` untested on both sides.  Mutation testing
    found that -- removing the check from ``core/turn_sequence.gd`` left the
    replay green.
    """

    ok = False
    kind = "refused"

    def to_dict(self) -> dict[str, Any]:
        return {"kind": self.kind, "ok": self.ok}


#: What the trace writes into the squad before it starts, so the refresh has
#: something to restore.  Every one is a field ``0x004781C0`` touches, and all
#: four are zero on a freshly authored ``.lev`` -- a trace taken from the file
#: as shipped compares a no-op against a no-op.
#: What the trace writes into the squad before it starts, one variant per unit.
#:
#: **A seed that is the same for every unit only reaches one arm of each
#: branch.** Mutation testing found four places where it did not reach any:
#: ``stimulant`` is cleared only when it already reads *spent* (255, not 1 --
#: ``docs/25`` §8), ``rested`` is set only from action state 7, and
#: ``turn_start_x``/``turn_start_y`` re-anchor invisibly when they already hold
#: the unit's own position. So the four squad members get four different
#: states, chosen to put each branch on both sides at once.
SEEDED_VARIANTS = (
    # Stood down, spent stimulant, a malfunction rung that steps to another.
    {"walked": 40, "heat": 3, "stimulant": turnmod.STIMULANT_SPENT,
     "action_state": turnmod.ACTION_STOOD_DOWN, "malfunction": 4, "acted": 3,
     "ticket": 7, "fp": 1, "turn_start_x": 0, "turn_start_y": 0},
    # Not stood down, a stimulant still in hand, a rung that clears.
    {"walked": 15, "heat": 1, "stimulant": 2, "action_state": 6,
     "malfunction": 1, "acted": 1, "ticket": 3, "fp": 2,
     "turn_start_x": 1, "turn_start_y": 1},
    # Heat below the shed, no malfunction, no stimulant.
    {"walked": 10, "heat": 0, "stimulant": 0, "action_state": 0,
     "malfunction": 0, "acted": 0, "ticket": 1, "fp": 3,
     "turn_start_x": 2, "turn_start_y": 2},
    # Fitness already at the cap, so the regeneration arm has nothing to add.
    {"walked": 55, "heat": 5, "stimulant": turnmod.STIMULANT_SPENT,
     "action_state": turnmod.ACTION_STOOD_DOWN, "malfunction": 5, "acted": 3,
     "ticket": 9, "fp": 255, "turn_start_x": 3, "turn_start_y": 3},
)

#: The reaction tickets the refresh zeroes (``docs/25`` §6). Seeded non-zero
#: for the same reason: from zero, zeroing them is a no-op.
SEEDED_REACTION = [1, 2, 3, 4]


def _check_one_unit_array(units: list[turnmod.TurnUnit],
                          world: Any, step: int) -> None:
    """The premise this trace rests on, asserted instead of assumed.

    **The engine has one unit array and this harness has two.**
    ``units_of(bm)`` builds the records ``hand_over`` reads and writes, and
    :class:`inclib.lcl_runtime.LclWorld` builds its own from the same ``.lev``
    for the interpreter to touch.  They are different record types, so nothing
    keeps them in step -- and ``InsertUnit`` (``0x004418C0``) writes into the
    engine's single array, where the very next refresh and the rotation both
    see the new unit immediately.

    Measured on ``_C_140``: the two agree for the first nine hand-overs and
    diverge on the tenth, when the turn-5 ``NextPlayer`` inserts the first
    reinforcement.  From there the interpreter's world holds up to 20 units
    while the turn model still holds 10.

    So a trace that ran past that point would be comparing a hand-over against
    a unit set the mission has already changed, and the GDScript replay -- whose
    unit set is the trace's -- would inherit the error without a symptom.  This
    raises instead.  **The remake itself is not split**: ``core/World`` owns one
    ``_units`` dictionary and ``core/lcl/`` will mutate that one, which is why
    this is a limit on what the *trace* can say and not a defect in the model.
    """
    theirs = sorted(world.units.keys())
    ours = sorted(u.slot for u in units)
    if theirs != ours:
        raise ValueError(
            f"step {step}: the mission script changed the unit array "
            f"({len(theirs)} slots) and the turn model did not ({len(ours)}). "
            f"The trace cannot describe hand-overs past this point; see "
            f"_check_one_unit_array")
    moved = [u.slot for u in units
             if (u.x, u.y, u.hp) != (world.units[u.slot].x,
                                     world.units[u.slot].y,
                                     world.units[u.slot].hit_points)]
    if moved:
        raise ValueError(
            f"step {step}: the mission script moved or damaged slot(s) "
            f"{moved} in its own world and the turn model did not see it")


def _unit_case(unit: turnmod.TurnUnit) -> dict[str, Any]:
    return {
        "slot": unit.slot, "type_id": unit.type_id, "player": unit.player,
        "x": unit.x, "y": unit.y, "hp": unit.hp, "mp": unit.mp,
        "fp": unit.fp, "ep": unit.ep, "acted": unit.acted,
        "action_state": unit.action_state, "rested": unit.rested,
        "walked": unit.walked, "turn_start_x": unit.turn_start_x,
        "turn_start_y": unit.turn_start_y, "stimulant": unit.stimulant,
        "ticket": unit.ticket, "heat": unit.heat,
        "malfunction": unit.malfunction, "weapon": unit.weapon,
        "equipment_ids": sorted(unit.equipment_ids),
    }


def _state_case(state: turnmod.TurnState) -> dict[str, Any]:
    return {
        "turn": state.turn, "current_player": state.current_player,
        "previous_player": state.previous_player,
        "player_count": state.player_count,
        "player_kind": list(state.player_kind),
        "end_state": list(state.end_state),
        "solo_flag": bool(state.solo_flag), "ai_level": state.ai_level,
        "mode": state.mode,
        "reaction_counter": list(state.reaction_counter),
    }


def emit_handover_cases(root: Path, out: Path) -> int:
    """Trace ``hand_over`` on ``_C_140`` into a document GDScript can replay.

    ``core/`` has no LCL interpreter yet, so the two implementations cannot be
    given the same *program*.  They can be given the same **transcript**: each
    step records what the mission script was asked, in order, what it answered,
    and what it left in the game-control slots, and the GDScript side installs
    a runner that replays exactly that.  What is then compared is the
    hand-over's own behaviour -- when each event fires, what environment it
    carries, whether a refusal stops the sequence, and every unit field the
    refresh touched.

    This is the strongest check available for ``0x0047D600``, whose
    *composition* is code-read rather than natively run: it ends by invoking
    the computer's entire turn, which is not something to start inside a
    debugger probe.  So the two implementations agreeing on identical documents
    is the gate, and it is only worth anything because one was written from the
    other.
    """
    tables = load_info_file(str(root / "DATA" / "Info.lcl"))
    name = "_C_140"
    bm = load_lev(str(root / "Missions" / f"{name}.lev"))
    document = script_document(
        lcl.parse_file(str(root / "Missions" / f"{name}.lcl")), {})
    units = units_of(bm)
    state = _campaign_state()
    world = lclrt.LclWorld(bm, tables, turn=state.turn, player=0,
                           ai_level=state.ai_level)

    # Seed the squad, so the refresh has work to do.  A `.lev` as authored has
    # every one of these at zero, and a trace taken from it would compare a
    # no-op against a no-op -- which mutation testing showed: removing the
    # `walked = 0` from the refresh left the replay green.
    squad_slots = sorted(u.slot for u in units if u.player == 0)
    for index, slot in enumerate(squad_slots):
        unit = next(u for u in units if u.slot == slot)
        # **Not `name`.**  That is the mission, set above and read by the
        # payload's `"mission"` key at the end of this function; rebinding it
        # here put `"turn_start_y"` in the fixture, which `test_handover.gd`
        # prints as the trace's provenance.
        for field, value in SEEDED_VARIANTS[
                index % len(SEEDED_VARIANTS)].items():
            setattr(unit, field, value)
    state.reaction_counter = list(SEEDED_REACTION)
    initial_units = [_unit_case(u) for u in units]
    initial_state = _state_case(state)
    calls: list[dict[str, Any]] = []

    refuse_at: list[int] = []

    def run_script(call_type: int, env: dict[int, int]) -> Any:
        world.turn = state.turn
        world.player = state.current_player
        if call_type in refuse_at:
            outcome: Any = _Refused()
        else:
            outcome = lclrt.run(document, world, env)
        calls.append({
            "call_type": call_type,
            "env": {str(k): v for k, v in sorted(env.items())},
            "ok": bool(outcome.ok),
            # What the script left behind, replayed rather than re-derived:
            # the mission-end test reads these and a canned runner that did not
            # carry them could never reach the win.
            "game_control": list(world.game_control),
        })
        return outcome

    steps: list[dict[str, Any]] = []

    def step(arg: int = 0, place: tuple[tuple[int, int, int], ...] = (),
             refuse: tuple[int, ...] = (),
             force: dict[str, Any] | None = None) -> None:
        # **Anything forced between steps is recorded, not done on the side.**
        # Setting the current player here and leaving the trace to say only
        # what came out made the replay ask a different question than the
        # emitter did, and it showed up as the wrong script event firing.
        forced = dict(force or {})
        for name, value in forced.items():
            if name == "game_control":
                world.game_control[:] = list(value)
            else:
                setattr(state, name, value)
        refuse_at.clear()
        refuse_at.extend(refuse)
        for slot, tx, ty in place:
            for unit in units:
                if unit.slot != slot:
                    continue
                world.unit_at[world.index(unit.x, unit.y)] = -1
                unit.x, unit.y = tx, ty
                for live in world.units.values():
                    if live.slot == slot:
                        live.x, live.y = tx, ty
                world.unit_at[world.index(tx, ty)] = slot
        calls.clear()
        # `arg` goes **into the call**, not only into the trace.  It is 0 in
        # every step today, and `godot/tests/test_handover.gd` already passes
        # the recorded value through -- so the first `step(arg=1)` would have
        # made the replay run a different branch than the one that produced
        # these expectations (`inclib/turn.py`: a non-zero arg skips the whole
        # advance and searches from slot 0).
        result = turnmod.hand_over(state, units, tables, world.game_control,
                                   run_script, _banner_of(units), arg)
        _check_one_unit_array(units, world, len(steps))
        steps.append({
            "arg": arg,
            "slots": sorted(u.slot for u in units),
            "place": [list(p) for p in place],
            "refuse": list(refuse),
            "force": {k: (list(v) if isinstance(v, list) else v)
                      for k, v in forced.items()},
            "calls": list(calls),
            "expected": {
                "code": result.code, "turn": result.turn,
                "player": result.player,
                "previous_player": result.previous_player,
                "mission_ended": result.mission_ended,
                "ai_turn": result.ai_turn,
                "refreshed": list(result.refreshed),
            },
            "units_after": [_unit_case(u) for u in units],
            "state_after": _state_case(state),
        })

    for _ in range(HANDOVER_STEPS):
        step()
    # The win: put the squad in the evacuation zone and hand over.  The
    # rotation has just come back to player 0, so `0x0043B490` answers with the
    # solo flag, no NEXT TURN fires, and NEXT PLAYER is where the script sees
    # the squad standing in the zone and sets game-control slot 0.  The step
    # after it shows the mission staying ended.
    squad = sorted((u for u in units if u.player == 0 and u.alive),
                   key=lambda u: u.slot)
    step(place=tuple((u.slot, tx, ty)
                     for u, (tx, ty) in zip(squad, EVACUATION_ZONE)))
    step()

    # The abort arm, on both events.  The mission is already over by here, so
    # these two say only what a refusal costs -- the sequence stops where it
    # stands, the current player does not move and the refresh does not run --
    # which is the whole of `if (!runProgram()) return 0;`.
    zeroed = [0] * len(world.game_control)
    step(refuse=(lclrt.CALL_NEXT_TURN,),
         force={"game_control": zeroed, "turn": 1,
                "current_player": turnmod.PLAYER_COMPUTER})
    step(refuse=(lclrt.CALL_NEXT_PLAYER,), force={"current_player": 0})

    type_ids = sorted({u.type_id for u in units})
    weapon_ids = sorted({u.weapon for u in units})
    payload = {
        "schema": HANDOVER_CASES_SCHEMA,
        "mission": name,
        "oracle": "tools/inclib/turn.py hand_over, with the real interpreter "
                  "driving the mission script",
        "state": initial_state,
        "units": initial_units,
        "types": {
            "units": [{
                "id": t, "mp_max": tables.units[t].mp_max,
                "fp_max": tables.units[t].fp_max,
                "hp_max": tables.units[t].hp_max,
                "special": tables.units[t].special,
                "size": tables.units[t].size,
                "species": tables.units[t].species,
                "height": tables.units[t].height,
                "model": tables.units[t].model,
                "description": tables.units[t].description,
            } for t in type_ids if t in tables.units],
            "weapons": [{
                "id": w, "heat": tables.weapons[w].heat,
                "toggle": tables.weapons[w].toggle,
                "mun": tables.weapons[w].mun,
            } for w in weapon_ids if w in tables.weapons],
        },
        "steps": steps,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n",
                   encoding="utf-8")
    LOG.info("wrote %s (%d step(s), %d script call(s))", out, len(steps),
             sum(len(s["calls"]) for s in steps))
    return 0


def _require_corpus(root: Path) -> str | None:
    """Refuse a root that is not a game installation, cleanly.

    An empty corpus must fail -- ``CLAUDE.md`` requires it of every check in
    the always-run block -- but it should fail by saying so, not by unwinding
    a stack from three modules down.
    """
    if not (root / "DATA" / "Info.lcl").is_file():
        return f"{root}: no DATA/Info.lcl -- this is not a game installation"
    if not any(root.rglob("*.lev")):
        return f"{root}: no .lev found; a check that examined nothing is not a check that passed"
    return None


def run_check(root: Path) -> int:
    c = Checker()
    problem = _require_corpus(root)
    if problem is not None:
        LOG.error("%s", problem)
        return 1
    tables = load_info_file(str(root / "DATA" / "Info.lcl"))
    check_refresh(c, root, tables)
    check_ladder(c)
    check_rotation(c)
    check_per_unit(c, tables)
    check_hand_over(c, root, tables)
    return c.report()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", metavar="ROOT", required=True,
                    help="game root")
    ap.add_argument("--emit-handover-cases", metavar="FILE", type=Path,
                    help="also write the _C_140 hand-over trace "
                         "godot/tests/test_handover.gd replays")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(levelname)s: %(message)s")
    root = Path(args.check)
    code = run_check(root)
    if args.emit_handover_cases is not None:
        try:
            code = emit_handover_cases(root, args.emit_handover_cases) or code
        except ValueError as exc:
            # The single-unit-array premise, reported the way every other
            # failure in this file is rather than as a traceback.
            LOG.error("%s", exc)
            return 1
    return code


if __name__ == "__main__":
    raise SystemExit(main())
