class_name WarpResult
extends RefCounted

## What one jump did (docs/97 section 31), as a value.

var ok: bool = false
var reason: String = ""
## Where the unit stood before, and where it landed.
var from_x: int = 0
var from_y: int = 0
var x: int = 0
var y: int = 0
## The `MoveUnit` script call `aExecuteWarp` fires (`0x0046F196`, var 0x41
## written 2), as [member MoveResult.script_result] is for a walk.
var script_result: Dictionary = {}
## The reaction queue, drained at the landing cell by the pad arm.
## What a mine under the landing cell did, empty when there was none.
var blast: Dictionary = {}
var reactions: Array[Dictionary] = []


static func failed(fx: int, fy: int, why: String) -> WarpResult:
	var result: WarpResult = WarpResult.new()
	result.from_x = fx
	result.from_y = fy
	result.x = fx
	result.y = fy
	result.reason = why
	return result


func to_dict() -> Dictionary:
	var out: Dictionary = {"ok": ok, "reason": reason, "from_x": from_x,
		"from_y": from_y, "x": x, "y": y,
		"reactions": reactions.duplicate(true)}
	if not blast.is_empty():
		out["blast"] = blast.duplicate(true)
	return out
