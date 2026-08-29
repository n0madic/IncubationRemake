class_name TurnSequence
extends RefCounted

## `0x0047D600` -- the hand-over, in the order the body has it.
##
## Transcribed from `tools/inclib/turn.py`'s `hand_over` rather than
## re-derived from docs/25, deliberately: the composition of this routine is
## **code-read, not natively run** (it ends by invoking `aAISystemControl`, the
## computer's whole turn, which is not something to start inside a debugger
## probe). The strongest check available is therefore the two implementations
## agreeing on identical documents, and that is only worth anything if one was
## written from the other.
##
## The order settles two things a remake would otherwise guess at:
##
## * **a turn advances when nobody is left to move**, not at a fixed point --
##   so `NEXT TURN` fires from the *last* player's hand-over, not the first;
## * **the two events carry different environments**: `NEXT TURN` sets only
##   `_B`, `NEXT PLAYER` sets `_B` and `_C`.
##
## Both script runs are checked. A refusal stops the hand-over where it stands,
## leaving the current player unchanged -- which is what docs/20 section 2.2's
## "report, then return 0" costs at this level.
##
## Two things are **not** here, and both are the caller's:
##
## * **reaction fire** ([Reaction]). docs/23 section 5.3's tail calls
##   `aExecuteFight` after `aExecuteMove`, five times in the binary and never
##   from the hand-over -- so the drain belongs to a move, and
##   [method World.submit_move] runs it;
## * **the fog pass** ([Visibility]). `aBuildVisibleMap` is a map walk and this
##   routine has no map; [method World.submit_end_turn] runs it after this
##   returns, and reports it as `fog_rebuilt`.
##
## Both are named rather than silently absent, because an omission nobody wrote
## down is an omission nobody finds.


## One hand-over.
##
## `run_script` is the [MissionScript] seam; `banner_of` and `live_units` are
## the two counts the caller already has. `arg` is the engine's own second
## argument: non-zero means "this is the first hand-over of a mission", which
## searches from slot 0 instead of advancing.
static func hand_over(state: TurnState, units: Dictionary,
		control: GameControl, types: UnitTypeTable, weapons: WeaponTable,
		run_script: Callable, banner_of: Callable, live_units: Callable,
		arg: int = 0) -> TurnResult:
	var result: TurnResult = TurnResult.new()
	result.code = TurnResult.OK
	result.turn = state.turn
	result.player = state.current_player
	result.previous_player = state.previous_player

	if arg == 0:
		if not Rotation.any_player_left_this_turn(state, live_units):
			state.advance_turn()
			result.turn = state.turn
			result.ran_turn_script = true
			result.turn_script = DictRead.as_dict(run_script.call(
				MissionScript.CALL_NEXT_TURN,
				MissionScript.env(MissionScript.CALL_NEXT_TURN, state.turn)))
			if not DictRead.as_bool(result.turn_script["ok"]):
				result.code = TurnResult.STOPPED
				return result
		if state.turn != 0:
			result.ran_player_script = true
			result.player_script = DictRead.as_dict(run_script.call(
				MissionScript.CALL_NEXT_PLAYER,
				MissionScript.env(MissionScript.CALL_NEXT_PLAYER, state.turn,
					state.current_player)))
			if not DictRead.as_bool(result.player_script["ok"]):
				result.code = TurnResult.STOPPED
				return result
			if control.mission_ended():
				result.mission_ended = true
				result.code = TurnResult.STOPPED
				return result
		if not Rotation.advance_player(state, live_units):
			result.code = TurnResult.STOPPED
			return result
	else:
		if not Rotation.search_first_player(state, live_units):
			result.code = TurnResult.STOPPED
			return result
		if state.mode == TurnState.MODE_NET and state.turn == 0:
			result.code = TurnResult.FIRST_NET

	result.refreshed = Refresh.player(state, state.current_player, units,
		types, weapons, banner_of)
	result.turn = state.turn
	result.player = state.current_player
	result.previous_player = state.previous_player
	# `turn != 0` as well as the player: at turn zero the mission has not
	# started and the planner does not run, however the rotation reads.
	result.ai_turn = state.current_player == TurnState.PLAYER_COMPUTER \
		and state.turn != 0
	return result
