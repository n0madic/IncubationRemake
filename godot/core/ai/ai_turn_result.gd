class_name AITurnResult
extends RefCounted

## What one `aAISystemControl` did -- a value, like every other result in
## `core`.
##
## The shape matches `inclib.ai.AITurnResult.to_dict`, so the two
## implementations are diffed document against document.

var ok: bool = true
var player: int = UnitState.PLAYER_ALIEN
var events: Array[AIEvent] = []
## How many sweeps of the 200 slots ran, in total. A `repeat` condition that
## is wrong **hangs** rather than answering wrongly, so this is bounded and
## the bound is checked.
var sweeps: int = 0
var counters: Dictionary = {}
var orders_seen: Dictionary = {}
## Refusals this model made rather than the engine: a target pattern it does
## not simulate, an overlay arm that stamps no band the AI reads.
var refusals: Dictionary = {}
## The generator's state either side of the turn, so a diff that goes wrong
## says *where* and not only *that*.
var seed_before: float = 0.0
var seed_after: float = 0.0
var reason: String = ""


func add(event: AIEvent) -> void:
	events.append(event)
	counters[event.kind] = DictRead.as_int(counters.get(event.kind, 0)) + 1


func refuse(reason_text: String) -> void:
	refusals[reason_text] = DictRead.as_int(refusals.get(reason_text, 0)) + 1


func saw_order(order: int) -> void:
	orders_seen[order] = DictRead.as_int(orders_seen.get(order, 0)) + 1


## Copies, never the array itself: `game` walks this and must not be able to
## reach into the turn that produced it.
func event_dicts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for event: AIEvent in events:
		out.append(event.to_dict())
	return out


func to_dict() -> Dictionary:
	var orders: Dictionary = {}
	var keys: Array = orders_seen.keys()
	keys.sort()
	for key: Variant in keys:
		orders[str(DictRead.as_int(key))] = DictRead.as_int(orders_seen[key])
	return {
		"ok": ok,
		"player": player,
		"events": event_dicts(),
		"sweeps": sweeps,
		"counters": counters.duplicate(true),
		"orders_seen": orders,
		"refusals": refusals.duplicate(true),
		"seed_before": seed_before,
		"seed_after": seed_after,
		"reason": reason,
	}
