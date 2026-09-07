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
## What the mission program answered to the LCL `Use` event (docs/26 section
## 6), `{}` when the event did not fire or no program is attached. Outside
## [method to_dict], as [member MoveResult.script_result] is: the script's own
## run marks its boundary and the `use` event's payload is the arm's alone.
var script_result: Dictionary = {}


static func refused(why: String) -> UseResult:
	var out: UseResult = UseResult.new()
	out.kind = "refused"
	out.reason = why
	return out


## The result back from the document [method to_dict] wrote -- the `use`
## event's payload, which the picture presents after the fact.
static func from_dict(document: Dictionary) -> UseResult:
	var out: UseResult = UseResult.new()
	out.ok = DictRead.as_bool(document.get("ok", false))
	out.kind = DictRead.as_string(document.get("kind", ""))
	out.reason = DictRead.as_string(document.get("reason", ""))
	out.cell = DictRead.to_int32(document.get("cell", []))
	out.action_point = DictRead.as_int(document.get("action_point", 0))
	out.fires_script_event = DictRead.as_bool(
		document.get("fires_script_event", false))
	for step: Variant in DictRead.as_array(document.get("pushed", [])):
		out.pushed.append(DictRead.to_int32(step))
	return out


func to_dict() -> Dictionary:
	var moved: Array = []
	for p: PackedInt32Array in pushed:
		moved.append(Array(p))
	return {"ok": ok, "kind": kind, "reason": reason,
		"cell": Array(cell) if not cell.is_empty() else [],
		"action_point": action_point,
		"fires_script_event": fires_script_event, "pushed": moved}
