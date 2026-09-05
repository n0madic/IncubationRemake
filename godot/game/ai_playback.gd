class_name AIPlayback
extends RefCounted

## Plays the computer's turn back, one event at a time.
##
## `core` decides the whole turn in one call and returns an ordered list of
## [AIEvent] dictionaries; nothing here changes the world. That split is the
## point: a playback that read the world *after* the turn would show the end
## of it at every step, so every event carries what it needs -- who acted,
## where they were, where they went, what they shot at and what came of it.
##
## Skipping is therefore free. It stops the timer and jumps to the last frame;
## the world is already in that state and was from the moment `core` returned.

## Seconds between events, and the **floor** rather than the whole rule. Slow
## enough to follow a unit across a 20x20 map, fast enough that a 39-alien turn
## does not outstay its welcome.
const STEP_SECONDS: float = 0.45
## The kinds worth stopping on. `end_unit_turn` and the refusals are
## bookkeeping and would triple the length of the replay for nothing.
const SHOWN_KINDS: Array[String] = ["move", "warp", "fire",
	"fire_heat_blocked", "door", "parabomb", "reactions", "promote_order"]

var _events: Array[Dictionary] = []
var _player: int = -1
var _index: int = 0
var _elapsed: float = 0.0
var _running: bool = false
var _note: String = ""
var _on_step: Callable = Callable()
## How long the event now on screen gets. [constant STEP_SECONDS] unless the
## step callback asked for longer -- see [method _step].
var _hold: float = STEP_SECONDS


## Start playing a finished turn. `on_step` is called with the event
## dictionary and a one-line note each time the playback advances, and with an
## empty dictionary when it ends.
func play(result: AITurnResult, on_step: Callable) -> void:
	_events = []
	_player = result.player
	for event: Dictionary in result.event_dicts():
		if SHOWN_KINDS.has(DictRead.as_string(event["kind"])):
			_events.append(event)
	_index = 0
	_elapsed = 0.0
	_hold = STEP_SECONDS
	_on_step = on_step
	_running = not _events.is_empty()
	if not _running:
		_finish()


func is_running() -> bool:
	return _running


## The side whose turn is being replayed. The world's own seat is no answer:
## the computer's turn hands over again inside the same call, so by the time
## the first event is drawn the rotation has moved on (docs/23 section 2).
func player() -> int:
	return _player


func remaining() -> int:
	return 0 if not _running else _events.size() - _index


## Drive from `_process`. Returns true while the playback still holds the input.
##
## `busy` is the picture's word: while a shot sequence, a walk, a set piece
## or a flight is still on screen the event's timer does not run, so the
## next event waits for the picture rather than for a number. [constant
## STEP_SECONDS] stays the floor *between* events -- the original's every
## `aPlay*` routine is blocking, and this is what blocking means here.
func advance(delta: float, busy: bool = false) -> bool:
	if not _running:
		return false
	if busy:
		return _running
	_elapsed += delta
	while _running and _elapsed >= _hold:
		_elapsed -= _hold
		_step()
	return _running


## One key press ends it. The world does not change, so this is exactly the
## state the last frame would have shown.
func skip() -> void:
	if not _running:
		return
	_index = _events.size()
	_finish()


## Where every unit whose move is still to come is **standing now**.
##
## `core` decides the whole turn before any of it is drawn, so the world holds
## every unit at the position it ends the turn on from the very first rebuild.
## A unit that has not walked yet was therefore already standing at the place
## it is about to walk to -- for as long as every event before its own takes --
## and then jumped back to its source and set off. Placing it on its first cell
## in [method UnitsView.start_walk] fixed the one-frame flash of that and not
## the rest of it.
##
## The events carry their own source cell (`AIEvent.make("move", slot, unit.x,
## unit.y, ...)`), so the picture can be told where each of them still is.
func pending_starts() -> Dictionary[int, Vector2i]:
	return starts_in(_events, _index)


## The same, as a function of its arguments, so a suite can ask it directly.
##
## The **first** event per slot wins: a unit that moves twice is held at the
## start of its next move, not of its last.
static func starts_in(events: Array[Dictionary],
		from_index: int) -> Dictionary[int, Vector2i]:
	var out: Dictionary[int, Vector2i] = {}
	for i: int in range(maxi(from_index, 0), events.size()):
		var event: Dictionary = events[i]
		var kind: String = DictRead.as_string(event["kind"])
		if kind != "move" and kind != "warp":
			continue
		var slot: int = DictRead.as_int(event["slot"])
		if out.has(slot):
			continue
		out[slot] = Vector2i(DictRead.as_int(event["x"]),
			DictRead.as_int(event["y"]))
	return out


## Every unit an unplayed event kills, as slots the caller may hold on screen.
##
## `core` decides the whole turn in one call, so the world has already lost
## everything the computer is about to kill from the first rebuild of the
## replay: a marine shot on the fourth event was gone before the first one was
## drawn, and came back only when [method SliceMain._mark_dying] held it for
## its own event. Marking the whole list up front is what keeps it standing
## until the shot that kills it.
##
## The answer is **candidates**, not casualties: the hit points are the
## world's business and the caller filters on them.
func pending_casualties() -> PackedInt32Array:
	return casualties_in(_events, _index)


## The same, as a function of its arguments, so a suite can ask it directly
## and one event can be passed as a list of one.
##
## The four shapes a payload carries a death in, and all four are here rather
## than in the caller: a shot's own `outcomes` (a `fire`, and a `parabomb`,
## whose payload **is** the blast), the drained `reactions` of a `reactions`
## event, the `mine_detonated` entries of a walk's `events`, and the `blast` a
## `warp` landed on.
static func casualties_in(events: Array[Dictionary],
		from_index: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in range(maxi(from_index, 0), events.size()):
		for slot: int in casualties_of(
				DictRead.as_dict(events[i].get("payload", {}))):
			if not out.has(slot):
				out.append(slot)
	return out


## The slots whose events the replay has already shown.
##
## The turn's progress bar (docs/43 section 7) counts the side's units that
## have spent movement, and `core` spent all of it before the first frame --
## so what the picture may count is what it has already played.
func played_slots() -> PackedInt32Array:
	return played_in(_events, _index)


## The same, as a function of its arguments, so a suite can ask it directly.
## Events `[0, from_index)` have been shown; the last of them is on screen.
static func played_in(events: Array[Dictionary],
		from_index: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in range(mini(from_index, events.size())):
		var slot: int = DictRead.as_int(events[i].get("slot", -1))
		if slot >= 0 and not out.has(slot):
			out.append(slot)
	return out


## The candidate slots one event's payload names.
static func casualties_of(payload: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	_slots_of(DictRead.as_array(payload.get("outcomes", [])), out)
	for item: Variant in DictRead.as_array(payload.get("reactions", [])):
		var entry: Dictionary = DictRead.as_dict(item)
		_slots_of(DictRead.as_array(DictRead.as_dict(
			entry.get("attack", {})).get("outcomes", [])), out)
	for item: Variant in DictRead.as_array(payload.get("events", [])):
		var entry: Dictionary = DictRead.as_dict(item)
		if DictRead.as_string(entry.get("kind", "")) != "mine_detonated":
			continue
		_slots_of(DictRead.as_array(DictRead.as_dict(
			entry.get("blast", {})).get("outcomes", [])), out)
	_slots_of(DictRead.as_array(DictRead.as_dict(
		payload.get("blast", {})).get("outcomes", [])), out)
	return out


static func _slots_of(outcomes: Array, out: PackedInt32Array) -> void:
	for item: Variant in outcomes:
		var slot: int = DictRead.as_int(
			DictRead.as_dict(item).get("slot", -1))
		if slot >= 0 and not out.has(slot):
			out.append(slot)


func _step() -> void:
	if _index >= _events.size():
		_finish()
		return
	var event: Dictionary = _events[_index]
	_index += 1
	_hold = STEP_SECONDS
	if _on_step.is_valid():
		# The callback may ask for longer, and a move does: a walk is paced at
		# the engine's own six frames a field ([constant
		# SliceMain.WALK_SECONDS_PER_STEP]), so a four-field move outlasts
		# [constant STEP_SECONDS] and the next event's rebuild would cut it
		# off half way. Anything shorter than the floor still gets the floor,
		# so the replay never speeds up.
		var asked: Variant = _on_step.call(event)
		if asked is float:
			_hold = maxf(STEP_SECONDS, DictRead.as_float(asked))
	if _index >= _events.size():
		_finish()


func _finish() -> void:
	_running = false
	if _on_step.is_valid():
		_on_step.call({})
