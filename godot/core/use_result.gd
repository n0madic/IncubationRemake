class_name UseResult
extends RefCounted

## What one `aExecuteUse` did -- a value, the same shape as
## `inclib.interact.UseResult.to_dict()`.

var ok: bool = false
var kind: String = ""
var reason: String = ""
## The cell the unit was facing, `[]` when it was facing off the map.
var cell: PackedInt32Array = PackedInt32Array()
## The action point as the switch saw it, **after** a random box rolled.
var action_point: int = 0
## True when the default arm was reached, i.e. when the LCL `Use` event fires.
## A push and a defuse never reach it (docs/26 section 3).
var fires_script_event: bool = false
## `[x, y]` of every cell a push moved an object through.
var pushed: Array[PackedInt32Array] = []


static func refused(why: String) -> UseResult:
	var out: UseResult = UseResult.new()
	out.kind = "refused"
	out.reason = why
	return out


func to_dict() -> Dictionary:
	var moved: Array = []
	for p: PackedInt32Array in pushed:
		moved.append(Array(p))
	return {"ok": ok, "kind": kind, "reason": reason,
		"cell": Array(cell) if not cell.is_empty() else [],
		"action_point": action_point,
		"fires_script_event": fires_script_event, "pushed": moved}
