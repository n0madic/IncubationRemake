class_name MoveResult
extends RefCounted

## What one walk did, as a value -- the sibling of [MoveMapResult].
##
## The shape matches `inclib.movemap.ExecuteResult.to_dict`, so the two
## implementations are diffed document against document rather than field by
## field at each call site.

## `aExecuteMove`'s own return value. **FALSE does not mean nothing happened**:
## a mine ends the walk with the unit moved, its distance accumulated and its
## facing turned, and the routine still answers FALSE. [member steps] is what
## says how far it got.
var ok: bool = false
var x: int = 0
var y: int = 0
## What argument 5 receives -- **0** on the mine arm, which is not the cost of
## the steps that were taken.
var cost: int = 0
var steps: int = 0
## The increment to `unit[+0x50]`, in tenths of a field.
var walked: int = 0
## `unit[+0x46]` after the walk: the facing of the last step taken.
var facing: int = 0
## `[cell index, new action point]` for every VictoryPoint claimed.
var action_point_writes: Array[Vector2i] = []
## `{"kind": String, "x": int, "y": int, "detail": int}` per event.
var events: Array[Dictionary] = []
## Set when a mine stopped the walk. The engine zeroes `+0x15` itself on that
## arm, so the caller must not also subtract [member cost].
var movement_zeroed: bool = false
var reason: String = ""
## What the `MoveUnit` event returned, or an empty dictionary when the walk
## never got far enough to fire it. docs/20 section 5: the event fires **after**
## the walk, so a refusal here cannot un-walk it.
var script_result: Dictionary = {}


static func failed(fx: int, fy: int, why: String) -> MoveResult:
	var result: MoveResult = MoveResult.new()
	result.x = fx
	result.y = fy
	result.reason = why
	return result


func to_dict() -> Dictionary:
	var writes: Array = []
	for write: Vector2i in action_point_writes:
		writes.append([write.x, write.y])
	return {
		"ok": ok,
		"x": x,
		"y": y,
		"cost": cost,
		"steps": steps,
		"walked": walked,
		"facing": facing,
		"action_point_writes": writes,
		"events": events.duplicate(true),
		"movement_zeroed": movement_zeroed,
	}
