class_name CharismaState
extends RefCounted

## What one body is playing, and when it stops.
##
## Three families, and each is here because its **call site** says what it is
## (docs/40 section 7.2), not because the letter suggests it:
##
## * `S` -- the idle. `fcn.004060B0` is called from the 3D-view refresh, so it
##   is what plays when nothing else does. It loops.
## * `M` -- the movement. `fcn.0046E220` starts it at `0x0046E581`, the
##   tactical move routine, so it plays while the unit walks. It loops for as
##   long as the walk lasts.
## * `F` -- the combat. `fcn.0040BD70` starts it at `0x0040BE88`, the fire
##   routine, and `fcn.004055E0` registers a `StopAnimationAtNoteEventCallback`
##   on the note text `BREAK` (`0x0042C5D0`), so **the animation halts itself
##   at that marker**. It plays once.
##
## **What is not recovered is said to be a choice.** docs/40 section 7.2 marks
## the playback set-up of `kind` 0 and `kind` 4 UNVERIFIED -- the interface
## slots `+0x44`, `+0x2C` and `+0x34` are not decompiled -- so "M loops" and
## "S resumes when nothing else plays" are this remake's decisions, recorded in
## docs/96, not behaviour read out of the binary. `kind == 4` and its one fixed
## literal `P0_M2_000` are not implemented at all.
##
## **An absent clip is normal.** Nine unit types get fewer than three families
## and two get none: the Spider walks with no idle and no fire, and the
## Norc'Yn's detachable arms have no clip at all. A null clip holds the bind
## pose, silently, because that is what the engine does with them.

## docs/40 section 4.8 -- **a decision, not a measurement.**
##
## The document proves 30 fps for cutscenes, and proves that gameplay advanced
## key time by one unit per *rendered* frame under a nominal 20 fps cap whose
## epoch bug roughly doubled it. There is no number to recover, so the remake
## fixes one and says which of the original's numbers it is not. The visible
## consequence is that a walk cycle plays at a steady rate instead of at
## whatever a 1997 machine managed.
const FRAMES_PER_SECOND: float = 30.0

enum Mode {IDLE, MOVE, FIRE}

var body: CharismaBody = null
var mode: int = Mode.IDLE

var _idle: CharismaClip = null
var _move: CharismaClip = null
var _fire: CharismaClip = null
var _clip: CharismaClip = null
var _time: float = 0.0
## Key time at which the current clip stops itself, or -1 when it runs to its
## end. Only `F` sets it, and only when the clip has a `BREAK` note: 29 of the
## 33 shipped `F` clips do, so the other four are a real case and not a
## defensive branch.
var _stop_at: float = -1.0
var _looping: bool = true
## False once a one-shot clip has reached its stop. The clip is **kept** and
## the time is **kept**: the engine's callback halts the animation where the
## note is and leaves it there, so the body holds that pose. Dropping the clip
## instead would snap the figure back to its bind pose in the middle of a shot.
var _running: bool = true


static func create(unit_body: CharismaBody, idle: CharismaClip,
		move: CharismaClip, fire: CharismaClip) -> CharismaState:
	var state: CharismaState = CharismaState.new()
	state.body = unit_body
	state._idle = idle
	state._move = move
	state._fire = fire
	state._enter(Mode.IDLE, idle, true, -1.0)
	return state


## Whether the current clip is still advancing.
##
## A looping clip never stops, so this is how "the idle keeps playing" is
## observable at all: [member mode] stays `IDLE` whether or not the loop works.
func is_playing() -> bool:
	return _running and _clip != null


## True while a one-shot clip is still running -- the caller may want to hold
## the turn open for it.
func is_busy() -> bool:
	return mode == Mode.FIRE and _running


## Start the walk cycle. Harmless when the type has no `M`: the body keeps
## whatever it was holding.
func walk() -> void:
	if mode == Mode.MOVE:
		return
	_enter(Mode.MOVE, _move, true, -1.0)


## Start the combat animation, once, halting at its `BREAK` note.
func fire() -> void:
	var stop: float = -1.0 if _fire == null else _fire.break_time()
	_enter(Mode.FIRE, _fire, false, stop)


## Back to the idle, which is what plays when nothing else does.
func rest() -> void:
	if mode == Mode.IDLE:
		return
	_enter(Mode.IDLE, _idle, true, -1.0)


## Advance by `delta` seconds and pose the body.
##
## Returns true while a one-shot clip is still running, so a caller driving a
## sequence knows when the body is free again.
func advance(delta: float) -> bool:
	if _running and _clip != null:
		_time += delta * FRAMES_PER_SECOND
		if _stop_at >= 0.0 and _time >= _stop_at:
			# The engine's callback stops the animation *at* the note and
			# leaves it there: it does not rewind and does not continue.
			_time = _stop_at
			_running = false
		elif _clip.duration > 0.0 and _time >= _clip.duration:
			if _looping:
				_time = fmod(_time, _clip.duration)
			else:
				# Four of the 33 shipped `F` clips carry no `BREAK` note, so
				# running out is a real end and not only a safety net.
				_time = _clip.duration
				_running = false
		if body != null:
			body.pose(_clip, _time, mode == Mode.MOVE)
	return mode == Mode.FIRE and _running


func _enter(new_mode: int, clip: CharismaClip, looping: bool,
		stop_at: float) -> void:
	mode = new_mode
	_clip = clip
	_looping = looping
	_stop_at = stop_at
	_time = 0.0
	_running = true
	if body != null:
		# The movement clip is the one that walks the body away from its own
		# node, because the walk itself is the node's ([method
		# CharismaBody.pose]). Nothing else moves under a clip.
		body.pose(_clip, _time, mode == Mode.MOVE)
