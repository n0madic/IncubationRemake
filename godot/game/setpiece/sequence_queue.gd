class_name SequenceQueue
extends RefCounted

## Blocking sequences, made non-blocking without changing what they mean.
##
## Every `aPlay*Sequence` in the original is a **blocking** routine: it does
## not queue an animation and return, it runs the animation itself in a loop
## whose body calls the frame tick `0x0040B6F0` once per displayed frame
## (docs/28 section 1.4). `aDoorOpenSequence` is the shape all of them have --
## load a wave, play it looping, run ten frames moving the door, kill the
## buffer.
##
## The remake's `core` has already applied the whole state change by the time
## anything gets here, which is the second slice's declared deviation. So what
## is left for a driver is **time and a picture**, never the right to change
## something: a queued sequence knows how many frames it lasts, what it looks
## like at each of them, and which sounds live for exactly that long.
##
## **The clock is 20 fps**, the same one the bodies use (docs/92 section 7.10).
## The original's blob tick and its sequence loop are both "once per displayed
## frame", and that frame is the one that was measured -- so the two cannot
## drift apart, and a set piece and a walking body finish in the same order
## they would have in the engine. It is a decision rather than a measurement,
## and it is written down as one.
##
## `skip()` keeps the meaning it has in [EventPlayback]: **stop drawing**, never
## stop simulating. Every queued step is snapped to its last frame, which is
## the state the world has held all along, and every sound the queue started
## is killed -- because a sound's lifetime is its sequence's, and a looping one
## left running is a stuck hum rather than a tail.

const FRAMES_PER_SECOND: float = 20.0
## The tag every sound this queue starts is filed under, so ending a sequence
## can end exactly its own sounds and nothing else's.
const TAG: String = "sequence"

## One queued sequence: `frames` displayed frames, and a callable that is given
## the frame index and paints that frame.
class Step extends RefCounted:
	var name: String = ""
	var frames: int = 0
	var paint: Callable = Callable()
	var cues: Array[Dictionary] = []
	var elapsed: int = 0
	var started: bool = false
	## An open-ended step ends on the first frame this answers true, or at
	## `frames` -- the engine's own bound -- whichever comes first.
	var until: Callable = Callable()
	## The routine's **last act**, run once however the step ended: at the
	## bound, on [member until], or because the showing was skipped. A
	## blocking routine's tail is not part of any frame it paints -- the
	## fly-past `0x00415E90` empties the pool at `0x004160B4` after its loop
	## has left, whatever left it -- so painting it at the last frame would
	## be right only for the one ending that reaches that frame.
	var on_end: Callable = Callable()

	func seconds() -> float:
		return float(frames) / FRAMES_PER_SECOND

	func done() -> bool:
		if elapsed >= frames:
			return true
		if until.is_valid():
			var stop: bool = until.call()
			return stop
		return false


var _steps: Array[Step] = []
var _index: int = 0
var _carry: float = 0.0
var _audio: AudioSystem = null
var _running: bool = false
## Frames actually painted, for a suite that has to tell "played" from
## "skipped without drawing".
var _painted: int = 0


static func create(audio: AudioSystem) -> SequenceQueue:
	var queue: SequenceQueue = SequenceQueue.new()
	queue._audio = audio
	return queue


## Add a sequence. `paint` is called with `(frame, frames)` once per frame,
## `frame` running 1..frames, so the last call is always the end state.
func enqueue(name: String, frames: int, paint: Callable,
		cues: Array[Dictionary] = []) -> void:
	if frames <= 0:
		return
	var step: Step = Step.new()
	step.name = name
	step.frames = frames
	step.paint = paint
	step.cues = cues.duplicate()
	_steps.append(step)
	_running = true


## Add a sequence that runs **until** `until` answers true, and for at most
## `frames` frames. This is what the original's "spin until the pool is
## empty" loops are (docs/42 sections 4.6 and 4.9): every one of them has a
## bound -- 100 frames for the round in flight, 20 for the numbers -- and
## the bound is what is passed here, never a number of the remake's.
##
## `paint` is called with `(frame, frames)` on every frame it runs, so a
## step that only waits passes an invalid callable.
func enqueue_until(name: String, frames: int, until: Callable,
		paint: Callable = Callable(), cues: Array[Dictionary] = [],
		on_end: Callable = Callable()) -> void:
	if frames <= 0:
		return
	var step: Step = Step.new()
	step.name = name
	step.frames = frames
	step.paint = paint
	step.until = until
	step.cues = cues.duplicate()
	step.on_end = on_end
	_steps.append(step)
	_running = true


## The name of the step now on screen, or `""`; for a suite.
func current() -> String:
	if not _running or _index >= _steps.size():
		return ""
	return _steps[_index].name


func is_running() -> bool:
	return _running


func remaining() -> int:
	return 0 if not _running else _steps.size() - _index


func painted() -> int:
	return _painted


## How long everything queued will take, in seconds. What [EventPlayback]'s step
## callback returns so a replay does not cut a set piece in half.
func seconds_left() -> float:
	var total: float = 0.0
	for index: int in range(_index, _steps.size()):
		total += _steps[index].seconds()
	return total


## Drive from `_process`. Answers true while the queue still holds the picture.
##
## Frames are whole: the sequences count in displayed frames and half a frame
## is not something any of them can paint, so the remainder is carried.
func advance(delta: float) -> bool:
	if not _running:
		return false
	_carry += delta * FRAMES_PER_SECOND
	var frames: int = int(_carry)
	_carry -= float(frames)
	for _frame: int in range(frames):
		if not _step_once():
			break
	return _running


func _step_once() -> bool:
	if _index >= _steps.size():
		_finish()
		return false
	var step: Step = _steps[_index]
	if not step.started:
		step.started = true
		if _audio != null and not step.cues.is_empty():
			var _slots: PackedInt32Array = _audio.play_cues(step.cues, TAG)
	step.elapsed += 1
	if step.paint.is_valid():
		step.paint.call(step.elapsed, step.frames)
		_painted += 1
	if step.done():
		_end_step(step)
		_index += 1
		if _index >= _steps.size():
			_finish()
			return false
	return true


## The end of one sequence: its last frame is painted and **its sounds stop**.
##
## This is docs/28 section 1.4 as a rule rather than as an observation. Nine of
## the fifty-eight play sites loop, and all nine are machinery whose sequence
## outlasts its sample -- the door, the lift, the platform, the drawbridge --
## so a queue that let the sample decide would either cut the door's hum short
## or leave it running for ever.
func _end_step(step: Step) -> void:
	if step.on_end.is_valid():
		step.on_end.call()
	if _audio == null or step.cues.is_empty():
		return
	var _killed: int = _audio.stop_tag(TAG)


## One key press ends the showing. Every remaining step is painted at its last
## frame -- which is the state the world has held since `core` returned -- and
## every sound the queue started is killed.
func skip() -> void:
	if not _running:
		return
	while _index < _steps.size():
		var step: Step = _steps[_index]
		if step.paint.is_valid():
			step.paint.call(step.frames, step.frames)
			_painted += 1
		# A skipped step still **ended**, so its last act runs -- the same
		# reason its last frame is painted.
		_end_step(step)
		_index += 1
	if _audio != null:
		var _killed: int = _audio.stop_tag(TAG)
	_finish()


func _finish() -> void:
	_running = false
	_steps.clear()
	_index = 0
	_carry = 0.0
	if _audio != null:
		var _killed: int = _audio.stop_tag(TAG)


func clear() -> void:
	_finish()
