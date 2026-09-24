class_name EventJournal
extends RefCounted

## The ordered record of what a command changed, and where the picture may
## catch up with it.
##
## `core` resolves a whole command -- and the whole computer turn -- before it
## returns, so the world `game` reads always stands at the *end* of the last
## command. The picture used to compensate with eighteen separate holds: the
## positions units end the turn on, the fog computed from where they end it,
## the casualties the rebuild had already dropped, the terrain a set piece was
## still animating. Each new mechanic added another.
##
## The original needs none of that because its frame tick `0x0040B6F0` sits
## **inside** the mutating routines -- 70 call sites, docs/28 section 1.4 --
## so everything written between two ticks is one visible change and the
## picture reads the state of the moment for free. What transfers is not the
## blocking loop but that atomicity: **an event boundary goes wherever the
## original would have drawn a frame between two writes**, and the state
## written since the previous boundary rides on the event as its `delta`.
##
## `game` then keeps a lagging clone of the world and advances it one delta at
## a time, at the moment each animation reaches the change it is drawing. The
## standing check is that after the last delta of a command the mirror's
## canonical hash equals the truth's: a field nobody thought to carry fails
## there deterministically, which is what replaces the per-family holds.
##
## The journal is **opt-in** (`World.enable_journal`). A world without
## one pays a boolean test per `MapState` setter and nothing else, so the case
## suites that replay whole missions are unaffected.

## The kinds whose own routine marks them, because the boundary is inside it:
## `ExecuteMove` and `ExecuteWarp` mark `move`/`warp` between their passes and
## `Reaction.drain` marks one `reaction` per shot. `AIContext.emit`
## therefore does not stamp them a second time -- the planner emits its own
## `move`, `warp` and `reactions` events for the fixture the case suite
## compares against, and those are a different document.
const SELF_MARKED: Array[String] = ["move", "warp", "reactions"]

## The kind a residual write is folded into when a command marked nothing at
## all. It holds no picture of its own.
const KIND_SYNC: String = "sync"

var _state: MapState = null
var _units: Dictionary = {}
var _turn: TurnState = null
var _control: GameControl = null
var _rng: IncRandom = null
var _crand: CRandom = null
## The unit views as of the last boundary, slot to view dictionary.
var _seen: Dictionary[int, Dictionary] = {}
var _events: Array[Dictionary] = []
var _open: bool = false
## The scalar half of the state -- the turn, the game control, the two
## generators -- as of the last [method take], for a command that marked no
## event at all: with nothing to compare the residue against, a generator
## moved by an unmarked command was dropped from the delta.
var _baseline: Dictionary = {}


## Bind to a world's components.
##
## It holds the six pieces and **never the `World`**: the world owns the
## journal, so a reference back would be a cycle, and Godot never collects one
## -- the run then ends in `resources still in use at exit` with every check
## green.
func bind(state: MapState, units: Dictionary, turn: TurnState,
		control: GameControl, rng: IncRandom, crand: CRandom) -> void:
	_state = state
	_units = units
	_turn = turn
	_control = control
	_rng = rng
	_crand = crand
	_events = []
	_open = true
	_state.track_writes(true)
	_snap_units()
	_baseline = _scalars(delta_now())


func is_open() -> bool:
	return _open


## Close one boundary and open the next: the state written since the last mark
## becomes this event's `delta`.
func mark(kind: String, slot: int = -1, x: int = 0, y: int = 0,
		tx: int = 0, ty: int = 0, detail: int = 0, note: String = "",
		payload: Dictionary = {}) -> Dictionary:
	if not _open:
		return {}
	var event: Dictionary = {
		"kind": kind, "slot": slot, "x": x, "y": y, "tx": tx, "ty": ty,
		"detail": detail, "note": note, "payload": payload.duplicate(true),
		"delta": delta_now(),
	}
	_events.append(event)
	return event


## The computer's own events, which arrive already built.
##
## Returns the event dictionary, or an empty one for a kind whose routine has
## already marked it ([constant SELF_MARKED]) and for a closed journal.
func stamp(event: AIEvent) -> Dictionary:
	if not _open or SELF_MARKED.has(event.kind):
		return {}
	return mark(event.kind, event.slot, event.x, event.y, event.tx, event.ty,
		event.detail, event.note, event.payload)


func has_events() -> bool:
	return not _events.is_empty()


## The events since the last call, with the residue folded in.
##
## **A write after the last mark still has to reach the mirror.** A command
## charges its movement points after the routine that moved the unit, and the
## computer's fire charges after the event the planner emitted; folding the
## residue into the last event is what keeps the hash invariant true. With no
## event at all -- a command that changed something and drew nothing -- the
## residue becomes one [constant KIND_SYNC] event, which the playback applies
## without presenting.
func take() -> Array[Dictionary]:
	if not _open:
		return []
	var residue: Dictionary = delta_now()
	if not _is_empty_delta(residue):
		if _events.is_empty():
			_events.append({
				"kind": KIND_SYNC, "slot": -1, "x": 0, "y": 0,
				"tx": 0, "ty": 0, "detail": 0, "note": "",
				"payload": {}, "delta": residue,
			})
		else:
			_fold(_events[_events.size() - 1], residue)
	_baseline = _scalars(residue)
	var out: Array[Dictionary] = _events
	_events = []
	return out


## Everything written since the previous boundary.
##
## Reads only: it draws from no generator (the case suites pin `seed_after`)
## and writes no record. The cell half comes from `MapState`'s own dirty set,
## the unit half from a comparison against the views taken at the last
## boundary -- a `UnitState` has thirty-eight fields written directly, with no
## setter to hook, so the diff is the honest price of the design.
func delta_now() -> Dictionary:
	var dirty: Dictionary = _state.take_dirty()
	var indices: PackedInt32Array = DictRead.as_int32_array(dirty["cells"])
	var cells: Dictionary = {}
	for index: int in indices:
		cells[index] = _state.cell_record(index)
	var delta: Dictionary = {
		"cells": cells,
		"units": _unit_diff(),
		"turn": _turn.view(),
		"game_control": _control.values(),
		"rng": _rng.state(),
		"crand": _crand.state(),
	}
	if DictRead.as_bool(dirty["objects"]):
		delta["objects"] = _state.objects()
	# The special-object table, whole: at most a hundred and fifty records,
	# and a move is rare -- a growth, a drop, a hatch, a crushed wall.
	if DictRead.as_bool(dirty["land"]):
		delta["land_objects"] = {"records": _state.land_objects(),
			"next": _state.next_land_id()}
	return delta


## The slots whose record moved, and `{}` for one the turn took off the map.
func _unit_diff() -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in _units:
		var slot: int = DictRead.as_int(key)
		var unit: UnitState = _units[key]
		var view: Dictionary = unit.view()
		if not _seen.has(slot) or not _same_view(_seen[slot], view):
			out[slot] = view
		_seen[slot] = view
	for slot: int in _seen.keys():
		if not _units.has(slot):
			out[slot] = {}
			var _gone: bool = _seen.erase(slot)
	return out


func _snap_units() -> void:
	_seen.clear()
	for key: Variant in _units:
		var unit: UnitState = _units[key]
		_seen[DictRead.as_int(key)] = unit.view()


## `==` on two dictionaries of scalars and packed arrays compares by value in
## Godot 4.7, but only at the top level for the nested arrays; this walks them
## so a skills or equipment write is seen.
static func _same_view(was: Dictionary, now: Dictionary) -> bool:
	if was.size() != now.size():
		return false
	for key: Variant in now:
		if not was.has(key):
			return false
		var a: Variant = was[key]
		var b: Variant = now[key]
		if typeof(a) != typeof(b):
			return false
		if a is PackedInt32Array:
			var left: PackedInt32Array = a
			var right: PackedInt32Array = b
			if left != right:
				return false
		elif a is PackedByteArray:
			var lbytes: PackedByteArray = a
			var rbytes: PackedByteArray = b
			if lbytes != rbytes:
				return false
		elif a != b:
			return false
	return true


## Whether a delta would change nothing: no cell, no unit, and the scalars
## equal to the previous event's. The cheap half is tested here; the scalar
## half is compared by the caller through `_fold`.
func _is_empty_delta(delta: Dictionary) -> bool:
	if not DictRead.as_dict(delta["cells"]).is_empty():
		return false
	if not DictRead.as_dict(delta["units"]).is_empty():
		return false
	if delta.has("objects") or delta.has("land_objects"):
		return false
	var last: Dictionary = _baseline
	if not _events.is_empty():
		last = DictRead.as_dict(_events[_events.size() - 1]["delta"])
	return _same_view(DictRead.as_dict(last["turn"]),
			DictRead.as_dict(delta["turn"])) \
		and DictRead.as_int32_array(last["game_control"]) \
			== DictRead.as_int32_array(delta["game_control"]) \
		and _same_view(DictRead.as_dict(last["rng"]),
			DictRead.as_dict(delta["rng"])) \
		and _same_view(DictRead.as_dict(last["crand"]),
			DictRead.as_dict(delta["crand"]))


## The scalar half of a delta, for [member _baseline].
static func _scalars(delta: Dictionary) -> Dictionary:
	return {
		"turn": delta["turn"],
		"game_control": delta["game_control"],
		"rng": delta["rng"],
		"crand": delta["crand"],
	}


## Merge a later delta into an event's own. The later value wins everywhere,
## which is what "the residue rides on the last event" means.
static func _fold(event: Dictionary, residue: Dictionary) -> void:
	var delta: Dictionary = DictRead.as_dict(event["delta"])
	var cells: Dictionary = DictRead.as_dict(delta["cells"])
	for index: Variant in DictRead.as_dict(residue["cells"]):
		cells[index] = DictRead.as_dict(residue["cells"])[index]
	var units: Dictionary = DictRead.as_dict(delta["units"])
	for slot: Variant in DictRead.as_dict(residue["units"]):
		units[slot] = DictRead.as_dict(residue["units"])[slot]
	delta["turn"] = residue["turn"]
	delta["game_control"] = residue["game_control"]
	delta["rng"] = residue["rng"]
	delta["crand"] = residue["crand"]
	if residue.has("objects"):
		delta["objects"] = residue["objects"]
	if residue.has("land_objects"):
		delta["land_objects"] = residue["land_objects"]
