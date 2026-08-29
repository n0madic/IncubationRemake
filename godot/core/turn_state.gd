class_name TurnState
extends RefCounted

## The turn half of the block `aSaveGameControl` writes -- docs/25 section 3.
##
## Only what a turn reads is here, on the same rule [UnitState] follows: the
## 720-byte block carries more, and carrying fields nothing reads would invite
## treating them as validated.
##
## The rotation this drives is pinned natively: `tools/turn_gold.py` phase 5
## steps `0x0043B320` twelve times inside the live engine and diffs the current
## player, the previous player, the any-player-left predicate and the return
## code at every step.

## docs/25 section 3 -- the counter wraps at 200 (`0x0043B2A0`).
const TURN_WRAP: int = 200
## docs/10 section 5.7 -- the alien side, a full member of the rotation.
const PLAYER_COMPUTER: int = 255
## docs/25 section 7 -- the neutral-prop owner. **Never** stored in the
## current-player byte: the setter rejects it and nothing passes it, which is
## why `advance_player` can never produce it.
const PLAYER_PROPS: int = 252
## docs/25 section 3 -- `5` takes a slot out of the rotation.
const END_STATE_OUT: int = 5
const PLAYER_SLOTS: int = 4

## `0x00509E1D`. Zero means no hand-over has happened yet, and that is the test
## the hand-over itself uses to recognise the first one -- at zero the whole
## skip rule is disabled (docs/25 section 3.1).
var turn: int = 0
var current_player: int = 0
var previous_player: int = 0
## `0x0043B310` -- the rotation's upper bound; 1 in the campaign.
var player_count: int = 1
## `0x0043B6E0` -- 0 means the slot is not in the game, 1 means a human.
var player_kind: PackedInt32Array = PackedInt32Array([1, 0, 0, 0])
## `0x0043B930`.
var end_state: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## `0x00509F08` -- "the computer side plays". Always set in a campaign.
var solo_flag: bool = true
## `0x00460450`. docs/93 section 11 left this to the campaign layer; this slice
## chooses **1, normal**, and carries it here so it enters the canonical hash
## rather than sitting in a constant.
var ai_level: int = 1
## `0x00517F50` -- zeroed by the refresh, so ticket numbering restarts every
## hand-over (docs/25 section 6).
var reaction_counter: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])


static func create() -> TurnState:
	return TurnState.new()


func human_count() -> int:
	var n: int = 0
	for i: int in range(mini(player_count, PLAYER_SLOTS)):
		if player_kind[i] == 1:
			n += 1
	return n


## `0x0043B2A0` -- five instructions, and the wrap is the whole of the fifth.
func advance_turn() -> int:
	turn += 1
	if turn == TURN_WRAP:
		turn = 0
	return turn


## A fresh dictionary of scalars, never this object.
func view() -> Dictionary:
	return {
		"turn": turn,
		"current_player": current_player,
		"previous_player": previous_player,
		"player_count": player_count,
		"player_kind": player_kind.duplicate(),
		"end_state": end_state.duplicate(),
		"solo_flag": solo_flag,
		"ai_level": ai_level,
		"reaction_counter": reaction_counter.duplicate(),
	}


func clone() -> TurnState:
	var copy: TurnState = TurnState.new()
	copy.turn = turn
	copy.current_player = current_player
	copy.previous_player = previous_player
	copy.player_count = player_count
	copy.player_kind = player_kind.duplicate()
	copy.end_state = end_state.duplicate()
	copy.solo_flag = solo_flag
	copy.ai_level = ai_level
	copy.reaction_counter = reaction_counter.duplicate()
	return copy
