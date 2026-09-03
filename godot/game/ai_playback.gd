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
