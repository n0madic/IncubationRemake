class_name Rotation
extends RefCounted

## Whose turn is next -- docs/25 section 3.1, `0x0043B320` and `0x0043B410`.
##
## Pinned natively over twelve steps (`tools/turn_gold.py` phase 5): on a
## campaign save the rotation has exactly two members and cycles 0, 255, 0, ...
## and `any_player_left_this_turn` alternates with it, because the computer
## moves last.
##
## A live-unit count is passed in as a [Callable] rather than read from a world:
## `core` keeps this file free of everything but the rule, and the count is
## `0x00477BF0`, which the caller already has.


## The shared clause of `0x0043B320` and `aSearchFirstPlayer`.
##
## The `turn == 0` escape is the one that matters for a remake: the very first
## hand-over never skips anybody, because units can still be placed by the
## mission script after the map loads.
static func slot_qualifies(state: TurnState, slot: int,
		live_units: Callable) -> bool:
	if slot < 0 or slot >= TurnState.PLAYER_SLOTS:
		return false
	if state.player_kind[slot] == 0:
		return false
	if state.end_state[slot] == TurnState.END_STATE_OUT:
		return false
	if state.turn == 0:
		return true
	return DictRead.as_int(live_units.call(slot)) > 0


## `aSearchFirstPlayer` `0x0043B410` -- the same loop, from slot 0.
static func search_first_player(state: TurnState,
		live_units: Callable) -> bool:
	for slot: int in range(state.player_count):
		if slot_qualifies(state, slot, live_units):
			state.current_player = slot
			return true
	return false


## `0x0043B320`.
##
## Player 255 is a full member and takes its turn after the last human slot,
## and only when the solo flag is set. In the campaign the rotation therefore
## has exactly two members.
static func advance_player(state: TurnState, live_units: Callable) -> bool:
	state.previous_player = state.current_player
	if state.current_player == TurnState.PLAYER_COMPUTER:
		if search_first_player(state, live_units):
			return true
		state.current_player = TurnState.PLAYER_COMPUTER
		return true
	while state.current_player < state.player_count - 1:
		state.current_player += 1
		if slot_qualifies(state, state.current_player, live_units):
			return true
	if state.solo_flag:
		state.current_player = TurnState.PLAYER_COMPUTER
		return true
	return search_first_player(state, live_units)


## `0x0043B490` -- the same skip rule over the slots *after* this one.
##
## Two extra clauses docs/25 section 4 records: it answers **no** outright when
## the computer is already the current player, because the computer moves last;
## and when no later slot qualifies it answers with the solo flag, because the
## computer still owes a turn.
static func any_player_left_this_turn(state: TurnState,
		live_units: Callable) -> bool:
	if state.current_player == TurnState.PLAYER_COMPUTER:
		return false
	for slot: int in range(state.current_player + 1, state.player_count):
		if slot_qualifies(state, slot, live_units):
			return true
	return state.solo_flag
