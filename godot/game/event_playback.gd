class_name EventPlayback
extends RefCounted

## Plays a command back, one event at a time.
##
## `core` resolves a whole command -- and the whole computer turn -- before it
## returns and hands `game` an ordered list of events, each carrying the state
## it changed as its `delta` ([EventJournal]). This walks that list: it presents
## an event, holds for as long as the presentation asks, and **lands the
## event's delta on the picture's mirror** at the moment the animation reaches
## the change. Nothing here touches the truth.
##
## The same object plays the computer's turn and the player's own commands, so
## there is one place where "what happened" becomes "what is on screen". What
## differs between the two is the **pacing**, and it is the caller's: the
## computer's turn keeps a gap between its events so a 39-alien turn can be
## followed, and a player's command runs at the picture's own speed -- the
## original's `aPlay*` routines block for exactly as long as they draw, and
## then return (docs/100 section 3).
##
## Skipping applies every delta that is left, in order, and stops drawing. The
## world was in that state from the moment `core` returned; the mirror catches
## up in one step.

## The gap the computer's turn keeps between two shown events, in seconds of
## the picture standing free. Slow enough to follow a unit across a 20x20
## map, fast enough that a 39-alien turn does not outstay its welcome. A
## player's command passes 0: nothing of theirs waits on a number.
const STEP_SECONDS: float = 0.45

## The kinds a presenter has an arm for. The bookkeeping ones -- `end_unit_turn`,
## the refusals, the fog probe, the rotation of a ring, the hand-over, the two
## opening passes of a walk -- have no picture, so their deltas land as the
## playback passes them, in the same frame as the next shown event.
const SHOWN_KINDS: Array[String] = ["move", "mine", "teleport", "warp", "fire",
	"reaction", "fire_heat_blocked", "door", "use", "heal", "parabomb",
	"promote_order", "script"]

## Every event, in order -- the ones with a hold and the ones without.
##
## The bookkeeping kinds are **kept** rather than filtered out: each carries a
## delta, and dropping the event would drop the state with it.
var _events: Array[Dictionary] = []
## Which of them have had their delta applied.
var _applied: Array[bool] = []
## What lands a delta on the picture's mirror.
var _apply: Callable = Callable()
var _index: int = 0
## Seconds since the event on screen was presented. Runs whether or not the
## picture is busy: the hold a presenter asks for is the length of what it
## queued, and waiting it out a second time after the queue drained was the
## empty second the player saw after every shot.
var _elapsed: float = 0.0
## Seconds the picture has stood free since the last shown event, or since it
## last went busy. The gap is measured on this and not on [member _elapsed].
var _quiet: float = 0.0
var _running: bool = false
var _on_step: Callable = Callable()
## How long the event now on screen gets: what the presenter asked, and
## nothing added to it.
var _hold: float = 0.0
## The pause between two shown events, once the picture is free.
var _gap: float = 0.0
## The picture's own word on whether it is busy, asked right after a presenter
## returns: an event whose presenter asked for nothing and queued nothing is
## quiet, and the playback goes on in the same frame.
var _busy: Callable = Callable()


## Start playing a command's events.
##
## `on_step` is called with each event as it comes on screen and answers how
## long to hold it; it is called once more with an empty dictionary when the
## list runs out. `apply` lands one event's delta on the mirror, and the
## playback calls it as it advances past an event a presenter did not already
## land ([method apply_current]). `gap` is the pause between two shown events
## and `busy` the picture's probe -- see [method advance].
##
## **The first shown event is presented inside this call.** The frame the
## button was pressed in is the frame the shot starts in, as it was when the
## presentation was synchronous; a step later would be an empty frame.
func play(events: Array[Dictionary], on_step: Callable,
		apply: Callable = Callable(), gap: float = 0.0,
		busy: Callable = Callable()) -> void:
	# **A command started over one still being drawn ends the first.** Its
	# deltas land and its finish runs, as a skip would do them; replacing the
	# list under it would leave the mirror short of every delta that had not
	# landed and the first command's finish never run. The input is held while
	# a playback runs, so this is for the callers that do not go through it.
	if _running:
		skip()
	_events = events.duplicate()
	_applied = []
	for _event: Dictionary in _events:
		_applied.append(false)
	_index = 0
	_elapsed = 0.0
	_quiet = 0.0
	_hold = 0.0
	_gap = maxf(gap, 0.0)
	_busy = busy
	_on_step = on_step
	_apply = apply
	_running = not _events.is_empty()
	if not _running:
		_finish()
		return
	# The bookkeeping in front of the first shown event -- a fog probe, the
	# hand-over that opened the turn -- has no picture, so its state lands now
	# rather than making the player wait a step for nothing.
	_land_quiet_prefix()
	# Then the first event that has one, and every quiet one behind it.
	while _running and not _step():
		pass


## Land every leading event nobody stops on, so the first held event opens on
## the state it actually begins from.
func _land_quiet_prefix() -> void:
	while _index < _events.size() and not _is_shown(_events[_index]):
		_land(_index)
		_index += 1
	if _index >= _events.size():
		_finish()


static func _is_shown(event: Dictionary) -> bool:
	return SHOWN_KINDS.has(DictRead.as_string(event["kind"]))


## Land the delta of the event now on screen, if it has not landed already.
##
## This is what a presenter with a moment of its own calls: the death stage of
## a shot, the frame a teleporter moves its traveller on, the first frame of a
## roof unit's fall. Idempotent, so a presenter and the playback may both ask.
func apply_current() -> bool:
	var at: int = _index - 1
	if at < 0 or at >= _events.size() or _applied[at]:
		return false
	_land(at)
	return true


## The event now on screen, or an empty dictionary.
func current() -> Dictionary:
	var at: int = _index - 1
	if at < 0 or at >= _events.size():
		return {}
	return _events[at]


func _land(at: int) -> void:
	if at < 0 or at >= _events.size() or _applied[at]:
		return
	_applied[at] = true
	if _apply.is_valid():
		_apply.call(_events[at])


func is_running() -> bool:
	return _running


func remaining() -> int:
	return 0 if not _running else _events.size() - _index


## Drive from `_process`. Returns true while the playback still holds the input.
##
## `busy` is the picture's word: while a shot sequence, a walk, a set piece
## or a flight is still on screen no event ends, so the next one waits for
## the picture rather than for a number. The hold keeps running underneath --
## it is the length of what was queued, not a second wait after it -- and
## the gap is counted from the moment the picture stands free.
func advance(delta: float, busy: bool = false) -> bool:
	if not _running:
		return false
	_elapsed += delta
	if busy:
		_quiet = 0.0
		return _running
	_quiet += delta
	while _running and _elapsed >= _hold and _quiet >= _gap:
		if _step():
			break
	return _running


## One key press ends it: every delta that is left lands, in order, and the
## drawing stops. The truth has been in that state since `core` returned, so
## this is exactly the state the last frame would have shown.
func skip() -> void:
	if not _running:
		return
	for at: int in range(_events.size()):
		_land(at)
	_index = _events.size()
	_finish()


## Present the next shown event. Answers whether it **took the picture** --
## asked for a hold, or left the queue running -- and so has to be waited
## for. A quiet answer means the caller may go straight on to the next one.
func _step() -> bool:
	# **The event that was on screen is over, so its state lands now** -- one
	# frame after the animation that drew it, and not before. A presenter with
	# a moment of its own has already landed it ([method apply_current]) and
	# this is then a no-op.
	_land(_index - 1)
	# The bookkeeping between two shown events: no picture, so no wait, but
	# the state still has to reach the mirror.
	while _index < _events.size() and not _is_shown(_events[_index]):
		_land(_index)
		_index += 1
	if _index >= _events.size():
		_finish()
		return false
	var event: Dictionary = _events[_index]
	_index += 1
	var asked: float = 0.0
	if _on_step.is_valid():
		# A move asks for its walk: it is paced at the engine's own six frames
		# a field ([constant SliceMain.WALK_SECONDS_PER_STEP]), so a four-field
		# move outlasts any floor and the next event's rebuild would cut it
		# off half way. A shot asks for its deterministic frames; the
		# open-ended stages are the picture's business, through `busy`.
		var answer: Variant = _on_step.call(event)
		if answer is float:
			asked = DictRead.as_float(answer)
	# The probe is fresh: what the presenter just queued is what it answers.
	var taken: bool = asked > 0.0 \
		or (_busy.is_valid() and DictRead.as_bool(_busy.call()))
	if not taken:
		return false
	_hold = asked
	_elapsed = 0.0
	_quiet = 0.0
	return true


## Drop the playback without landing or presenting anything: the mission it
## was drawing is being torn down, so there is no mirror left to land on and
## no finish callback that could run without a world.
func cancel() -> void:
	_events = []
	_applied = []
	_index = 0
	_running = false
	_on_step = Callable()
	_apply = Callable()
	_busy = Callable()


func _finish() -> void:
	# Nothing may be left unlanded: a playback that ended with a delta still
	# in hand would leave the mirror behind the truth for good.
	for at: int in range(_events.size()):
		_land(at)
	_running = false
	if _on_step.is_valid():
		_on_step.call({})
