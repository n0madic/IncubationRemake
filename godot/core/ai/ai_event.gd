class_name AIEvent
extends RefCounted

## One thing the computer did, in the order it did it.
##
## `game` replays these and `core` renders nothing. The shape is shared with
## `inclib.ai.AIEvent.to_dict` **from the first commit**: docs/94 section 8
## records what the other choice costs -- two documents of different shape
## compared by event name alone, with the arguments of 120 cases unchecked for
## a year.
##
## An event carries everything the playback needs, so the player never has to
## ask the world what happened. A playback that read state *after* the turn
## would show the end of it at every step.

var kind: String = ""
var slot: int = -1
var x: int = 0
var y: int = 0
## A second cell, where the event has one: a move's destination, a shot's aim.
var tx: int = 0
var ty: int = 0
## The order, kind, level, marker or movement cost the event is about.
var detail: int = 0
## Free text a check can assert on: a refusal, an order name.
var note: String = ""
## Nested results -- an [AttackResult] dictionary for a shot, the reactions a
## move drained.
var payload: Dictionary = {}


static func make(event_kind: String, unit_slot: int = -1, ex: int = 0,
		ey: int = 0, etx: int = 0, ety: int = 0, edetail: int = 0,
		enote: String = "", epayload: Dictionary = {}) -> AIEvent:
	var event: AIEvent = AIEvent.new()
	event.kind = event_kind
	event.slot = unit_slot
	event.x = ex
	event.y = ey
	event.tx = etx
	event.ty = ety
	event.detail = edetail
	event.note = enote
	event.payload = epayload
	return event


func to_dict() -> Dictionary:
	return {
		"kind": kind, "slot": slot, "x": x, "y": y, "tx": tx, "ty": ty,
		"detail": detail, "note": note, "payload": payload.duplicate(true),
	}
