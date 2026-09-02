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

## docs/40 section 4.8 -- the **nominal cap of the gameplay loop**, which is a
## measurement of the original's intent even though its render rate was not one.
##
## Gameplay advances key time by one unit per *rendered* frame, and the routine
## that renders those frames -- `fcn.0040B6F0`, the one `aExecuteMove` calls
## six times per map field (docs/40 section 4.8, and [constant
## SliceMain.FRAMES_PER_FIELD]) -- is capped by the skip controller at `(10,
## 20)`.
## Twenty is therefore the rate the walk was paced against.
##
## **This was 30 in slices 1 to 4**, taken from the proven cutscene rate for
## consistency, and at 30 a walking body moves half again too fast for the
## distance it covers. Cutscenes keep 30: that one is proven outright
## (`0.03` frames/ms at `0x004B157C`) and is a different clock.
##
## The original's own rate was whatever the machine rendered at, and its skip
## controller does not reset its epoch on the branch that waits, so the cap was
## enforced on every *other* frame and the effective rate was roughly double.
## That is an engine bug (docs/40 section 4.8), and the remake follows the
## nominal cap rather than the bug.
const FRAMES_PER_SECOND: float = 20.0

## How long the `BREAK` pose is held before the idle resumes, in seconds.
##
## **This number is the remake's, and there is no engine number behind it.**
## `fcn.004055E0`'s callback halts the combat clip at the note and leaves the
## body there; what puts `S` back is the 3D-view refresh, and that refresh
## rate is not recovered -- docs/40 section 7.2 marks the `kind` 0 / `kind` 4
## playback set-up UNVERIFIED. It is **not** the `int(len / 6) / 3` spin of
## docs/40 section 4.8: that one runs *while* the clip plays toward `BREAK`
## and is three or four iterations, not a wait after it.
##
## What it is for is the defect it fixes. The pose used to be thrown away on
## the very frame it was struck -- the clip stopped at its note and the body
## snapped to idle frame 0 in the same `animate()` call -- so a shot read as
## nothing having happened.
const HOLD_SECONDS: float = 0.35

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
##
## It is also false the moment a **null** clip is entered. Nine unit types
## get fewer than three families and two get none, and a `FIRE` that left
## this true with no clip made [method advance] answer "still running" for
## ever: the body never came back to its idle. See [method fire].
var _running: bool = true
## Seconds of the `BREAK` pose still owed, counted down once the clip has
## stopped. [constant HOLD_SECONDS] at the moment [member _running] goes
## false in `FIRE`, and zero everywhere else.
##
## **The hold belongs here and not in the caller.** A view holding the pose
## on its own clock would report a length that covered only the clip, and
## the computer's next event would rebuild the state part way through the
## hold.
var _hold_left: float = 0.0


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


## True while a one-shot clip is still running **or its end pose is still
## being held** -- the caller may want to hold the turn open for it.
##
## The hold is inside the answer rather than beside it, so a caller that
## rests the body when this goes false rests it at the end of the shot
## rather than on the frame the note stopped the clip.
func is_busy() -> bool:
	return mode == Mode.FIRE and (_running or _hold_left > 0.0)


## Start the walk cycle. Harmless when the type has no `M`: the body keeps
## whatever it was holding.
func walk() -> void:
	if mode == Mode.MOVE:
		return
	_enter(Mode.MOVE, _move, true, -1.0)


## Start the combat animation, once, halting at its `BREAK` note.
##
## Returns how many seconds the whole shot occupies the body -- the clip up
## to its stop plus [constant HOLD_SECONDS] -- so a caller driving a
## sequence can wait exactly that long. Zero when the type has no `F` clip,
## which is seven of the shipped types (docs/40 section 7.2.1): there is
## nothing to wait for, and [method is_busy] says so from the first frame.
func fire() -> float:
	var stop: float = -1.0 if _fire == null else _fire.break_time()
	_enter(Mode.FIRE, _fire, false, stop)
	if _fire == null:
		return 0.0
	var frames: float = stop if stop >= 0.0 else _fire.duration
	return frames / FRAMES_PER_SECOND + HOLD_SECONDS


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
		if not _running and mode == Mode.FIRE:
			_hold_left = HOLD_SECONDS
		if body != null:
			body.pose(_clip, _time, mode == Mode.MOVE)
	elif _hold_left > 0.0:
		# The pose is struck and the clip is not advancing: what is left is
		# the wait before the idle resumes. It is spent on the frames
		# *after* the one that stopped the clip, so a single long step
		# never consumes both.
		_hold_left = maxf(_hold_left - delta, 0.0)
	return is_busy()


## What this state is playing and how far into it, so a rebuild can put it back.
##
## **A rebuild is not a reason to restart an animation.** `UnitsView.build`
## frees every node on every command and on every fog change, and a fresh state
## begins its idle at frame 0 -- so every body on the map visibly snapped each
## time the player did anything, and a shot in flight was thrown away. The
## clock is presentation and not world state, so carrying it across is not a
## scene node becoming authoritative.
func playback() -> Dictionary:
	return {"mode": mode, "time": _time, "hold": _hold_left,
		"clip": "" if _clip == null else _clip.name}


## Put [method playback]'s answer back, when it still names this body's clip.
##
## Refuses a `MOVE`: the walk itself lives in [UnitsView] and a rebuild clears
## it, so a movement clip carried across would loop on the spot for ever. The
## idle is what a body with no walk plays, and that is what it gets.
func resume(saved: Dictionary) -> bool:
	var want: int = DictRead.as_int(saved.get("mode", Mode.IDLE))
	if want == Mode.MOVE:
		return false
	var clip: CharismaClip = _fire if want == Mode.FIRE else _idle
	if clip == null or clip.name != DictRead.as_string(saved.get("clip", "")):
		return false
	var stop: float = clip.break_time() if want == Mode.FIRE else -1.0
	_enter(want, clip, want != Mode.FIRE, stop)
	_time = DictRead.as_float(saved.get("time", 0.0))
	_hold_left = DictRead.as_float(saved.get("hold", 0.0))
	if _stop_at >= 0.0 and _time >= _stop_at:
		_time = _stop_at
		_running = false
	elif want == Mode.FIRE and clip.duration > 0.0 and _time >= clip.duration:
		_time = clip.duration
		_running = false
	if body != null:
		body.pose(_clip, _time, false)
	return true

func _enter(new_mode: int, clip: CharismaClip, looping: bool,
		stop_at: float) -> void:
	mode = new_mode
	_clip = clip
	_looping = looping
	_stop_at = stop_at
	_time = 0.0
	# **Not unconditionally true.** A null clip has nothing to run, and
	# saying it does left a body with no `F` permanently busy.
	_running = clip != null
	_hold_left = 0.0
	if body != null:
		# The movement clip is the one that walks the body away from its own
		# node, because the walk itself is the node's ([method
		# CharismaBody.pose]). Nothing else moves under a clip.
		body.pose(_clip, _time, mode == Mode.MOVE)
