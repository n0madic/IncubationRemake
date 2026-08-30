class_name TurnResult
extends RefCounted

## What one hand-over did -- a value, like every other result in `core`.
##
## The shape matches `inclib.turn.HandOverResult.to_dict`, so the two
## implementations are diffed document against document.

## docs/25 section 4 -- what `0x0047D600` returns; the caller dispatches on it.
const STOPPED: int = 0
"""The mission script returned zero, the mission ended, or no player is left."""
const OK: int = 1
const REMOTE: int = 2
"""Net session: the incoming player is somebody else's."""
const FIRST_NET: int = 3

var code: int = STOPPED
var turn: int = 0
var player: int = 0
var previous_player: int = 0
## The `NEXT TURN` invocation's result, and whether it happened at all. It does
## not on every hand-over: a turn advances only when nobody is left to move.
var turn_script: Dictionary = {}
var ran_turn_script: bool = false
var player_script: Dictionary = {}
var ran_player_script: bool = false
var mission_ended: bool = false
var refreshed: PackedInt32Array = PackedInt32Array()
## Whether the incoming player is 255 -- that is, whether the computer's turn
## is what comes next. docs/23's planner runs it, and [member ai_result]
## carries what it did.
var ai_turn: bool = false
## The computer's turn, when [member ai_turn] was true and [World] ran it.
## `null` otherwise; `game` plays the events back and `core` renders nothing.
var ai_result: AITurnResult = null
## True when the caller rebuilt the fog for the player that now holds the turn.
## It is the *caller's* job (docs/22 section 9 is a map walk and [Refresh] is a
## unit walk), so this records that the caller did it rather than asserting it.
var fog_rebuilt: bool = false


func ok() -> bool:
	return code != STOPPED


func to_dict() -> Dictionary:
	return {
		"code": code,
		"turn": turn,
		"player": player,
		"previous_player": previous_player,
		"turn_script": turn_script.duplicate(true) if ran_turn_script else {},
		"player_script": player_script.duplicate(true) if ran_player_script
			else {},
		"mission_ended": mission_ended,
		"refreshed": refreshed.duplicate(),
		"ai_turn": ai_turn,
		"ai_result": {} if ai_result == null else ai_result.to_dict(),
		"fog_rebuilt": fog_rebuilt,
	}
