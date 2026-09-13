class_name CharismaState
extends RefCounted

## What one body is playing, and when it stops.
##
## Three families, and each is here because its **call site** says what it is
## (docs/40 section 7.2), not because the letter suggests it:
##
## * `S` -- the idle. `fcn.004060B0` is called from the 3D-view refresh for
##   four slots, picks a unit at random and plays its `S` **once** at speed
##   1.5, then holds the last frame until the slot's countdown ends and frees
##   it -- on the next step the body is back in its bind pose (docs/42
##   section 6, measured). A body with no slot on it holds its bind pose.
##   [IdleScheduler] is the four slots; this state is what one body does.
## * `M` -- the movement. `fcn.0046E220` starts it at `0x0046E581`, the
##   tactical move routine, so it plays while the unit walks. It loops
##   (`+0x44(100000)` at `0x00405992`, docs/42 section 1.2).
## * `F` -- the combat. `fcn.0040BD70` starts it at `0x0040BE88`, the fire
##   routine, and `fcn.004055E0` registers a `StopAnimationAtNoteEventCallback`
##   on the note text `BREAK` (`0x0042C5D0`), so **the animation halts itself
##   at that marker**. The routine then resumes it past the note with
##   `aContCHAnimation` `0x004054D0` once the shot's effects are spent
##   (docs/42 section 4.9), and it plays out to its end.
##
## **The speeds are the engine's** (docs/42 section 1.2): every gameplay start
## goes through the animation interface's start slot with a speed literal --
## `M` at 2.0, `F` at 6.0, `S` at 1.5 -- and gameplay advances one key-time
## unit per rendered frame times that speed. So an `F` clip reaches its note in
## three to six frames and a walk cycle takes ten. `kind == 4` and its one fixed
## literal `P0_M2_000` (speed 1.0) are not implemented.
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
## 20)`. Twenty is therefore the rate the walk was paced against.
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

## docs/42 section 1.2 -- the speed literal each start passes, in key-time
## units per rendered frame: `push 0x40000000` at `0x0040599C` for the walk,
## `push 0x40C00000` at `0x00405B17` for the fight, `push 0x3FC00000` at
## `0x004063E3` for the idle (the last one measured as well, docs/42
## section 6.3). `presentation_tables.py` pins all three.
const SPEED_WALK: float = 2.0
const SPEED_FIGHT: float = 6.0
const SPEED_IDLE: float = 1.5

enum Mode {IDLE, MOVE, FIRE}

var body: CharismaBody = null
var mode: int = Mode.IDLE

## The clip the scheduler last started on this body, carried across a
## rebuild by name through [member clip_lookup].
var _idle: CharismaClip = null
var _move: CharismaClip = null
var _fire: CharismaClip = null
## The `F` clip **one shot** plays, when it is not the one the unit's own
## weapon named.  `aAttackUnit` calls `aPlayFightAnimation` at `0x0046C186`,
## inside the close-combat swap's window, so the selector `0x0042E220` reads
## the **bayonet** for a stab and the body plays `P0_F1_001` rather than the
## gun's `F0` (docs/21 section 6).  The swap lasts one shot in the engine and
## it lasts one shot here: [method rest] drops it, and every stage of a shot
## that measures or starts the clip sets it first, so it can neither leak into
## the next shot nor survive the body's return to its idle.
var _shot_fire: CharismaClip = null
var _shot_fire_set: bool = false
var _clip: CharismaClip = null
var _time: float = 0.0
var _speed: float = SPEED_IDLE
## Key time at which the current clip stops itself, or -1 when it runs to its
## end. Only `F` sets it, and only when the clip has a `BREAK` note: 29 of the
## 33 shipped `F` clips do, so the other four are a real case and not a
## defensive branch. [method resume_past_break] clears it.
var _stop_at: float = -1.0
var _looping: bool = true
## False once a one-shot clip has reached its stop. The clip is **kept** and
## the time is **kept**: the engine's callback halts the animation where the
## note is and leaves it there, so the body holds that pose until the shot
## resumes it or rests it. Dropping the clip instead would snap the figure
## back to its bind pose in the middle of a shot.
##
## It is also false the moment a **null** clip is entered. Nine unit types
## get fewer than three families and two get none, and a `FIRE` that left
## this true with no clip made [method advance] answer "still running" for
## ever: the body never came back to its idle. See [method fire].
var _running: bool = true
## Resolves a clip by name, for [method resume] to carry an idle across a
## rebuild; [UnitsView] hands it the library's own lookup.
var clip_lookup: Callable = Callable()
## True while a shot owns the pose: from [method fire] until [method rest].
## The engine's routine is blocking and the body is its for the whole shot --
## the clip to the note, the wait for the round, the resume and the play-out
## -- so "busy" is the sequence's word, not the clock's. Cleared by
## [method rest]; never set for a body with no `F` clip.
var _held: bool = false


## A body starts in its **bind pose**: `idle` is only what a scheduler may
## start on it later, never a loop.
static func create(unit_body: CharismaBody, idle: CharismaClip,
		move: CharismaClip, fire: CharismaClip) -> CharismaState:
	var state: CharismaState = CharismaState.new()
	state.body = unit_body
	state._idle = idle
	state._move = move
	state._fire = fire
	state._enter(Mode.IDLE, null, false, -1.0, SPEED_IDLE)
	return state


## `0x004060B0`'s start: play `clip` once at speed 1.5 (`0x004063E3`). Answers
## the clip's length in key units, which is the frames the slot counts down
## (docs/42 section 6.1 item 4); zero for no clip.
func start_idle(clip: CharismaClip) -> float:
	_idle = clip
	_enter(Mode.IDLE, clip, false, -1.0, SPEED_IDLE)
	return 0.0 if clip == null else clip.duration


## `aFreeCHAnimation` -- the slot lets go: on the next step the body is at
## its bind pose (docs/42 section 6.2, measured).
func detach_idle() -> void:
	if mode != Mode.IDLE:
		return
	_enter(Mode.IDLE, null, false, -1.0, SPEED_IDLE)


## True while an idle clip is attached -- playing, or finished and holding
## its last frame -- which is `+0x56` for the scheduler's guard.
func is_idling() -> bool:
	return mode == Mode.IDLE and _clip != null


## The idle clip attached, or null in the bind pose.
func idle_clip() -> CharismaClip:
	return _clip if mode == Mode.IDLE else null


## Whether the current clip is still advancing.
##
## A looping clip never stops, so this is how "the idle keeps playing" is
## observable at all: [member mode] stays `IDLE` whether or not the loop works.
func is_playing() -> bool:
	return _running and _clip != null


## True while a shot owns the body -- the clip running, or its pose held
## between the note and the resume -- so the caller may hold the turn open.
func is_busy() -> bool:
	return mode == Mode.FIRE and (_running or _held)


## True once the combat clip has stopped at its note and not yet been resumed.
func is_at_break() -> bool:
	return mode == Mode.FIRE and _clip != null and not _running \
		and _stop_at >= 0.0


## Start the walk cycle. Harmless when the type has no `M`: the body keeps
## whatever it was holding.
func walk() -> void:
	if mode == Mode.MOVE:
		return
	_enter(Mode.MOVE, _move, true, -1.0, SPEED_WALK)


## Start the combat animation at speed 6.0, once, halting at its `BREAK` note.
##
## Returns how many seconds the clip takes to reach its stop -- the note, or
## the end for the four clips without one -- so a caller driving a sequence
## can wait exactly that long. Zero when the type has no `F` clip, which is
## seven of the shipped types (docs/40 section 7.2.1): there is nothing to
## wait for, and [method is_busy] says so from the first frame.
func fire() -> float:
	var clip: CharismaClip = fire_clip()
	var stop: float = -1.0 if clip == null else clip.break_time()
	_enter(Mode.FIRE, clip, false, stop, SPEED_FIGHT)
	_held = clip != null
	if clip == null:
		return 0.0
	return float(frames_to_break()) / FRAMES_PER_SECOND


## The `F` clip the next shot plays: the override when one is set, the unit's
## own otherwise.  A **set** override of `null` is an answer -- the selector
## names nothing for that weapon -- and not a request to fall back.
func fire_clip() -> CharismaClip:
	return _shot_fire if _shot_fire_set else _fire


## Play the next shot with `clip` instead of the weapon's own; see
## [member _shot_fire].  Setting it twice for one shot is what the stages do
## and is harmless -- the value is the same both times.
func use_shot_clip(clip: CharismaClip) -> void:
	_shot_fire = clip
	_shot_fire_set = true


## Back to the unit's own `F` clip.
func clear_shot_clip() -> void:
	_shot_fire = null
	_shot_fire_set = false


## How many rendered frames the combat clip takes to reach its `BREAK` note
## at speed 6.0 -- the clock passes the note on the tick that reaches it.
## Zero with no clip.
func frames_to_break() -> int:
	var clip: CharismaClip = fire_clip()
	if clip == null:
		return 0
	var stop: float = clip.break_time()
	if stop < 0.0:
		stop = clip.duration
	return ceili(stop / SPEED_FIGHT)


## `int(length / 6) / 3` -- the frames the fight routine spins after the note
## (`0x0040BEC9`): the clip's length in frames at speed 6, a third of it.
func spin_frames() -> int:
	var clip: CharismaClip = fire_clip()
	if clip == null:
		return 0
	@warning_ignore("integer_division")
	return int(clip.duration / SPEED_FIGHT) / 3


## `aContCHAnimation` `0x004054D0` -- run the combat clip on past its note.
##
## Returns how many frames remain to its end (`0x00405460`), which is what
## the routine spins for. Zero when there is nothing to resume: no clip, not
## stopped at a note, or already past it.
func resume_past_break() -> int:
	if not is_at_break():
		return 0
	_stop_at = -1.0
	_running = true
	return remaining_frames()


## Frames left to the current clip's end at its speed; zero when it is not
## running to an end.
func remaining_frames() -> int:
	if _clip == null or _clip.duration <= 0.0:
		return 0
	return maxi(ceili((_clip.duration - _time) / _speed), 0)


## `aStopCHAnimation` -- the clip is detached and the body holds its bind
## pose until a scheduler slot picks it again. Releases the shot's hold.
func rest() -> void:
	_held = false
	clear_shot_clip()
	if mode == Mode.IDLE and _clip == null:
		return
	_enter(Mode.IDLE, null, false, -1.0, SPEED_IDLE)


## Advance by `delta` seconds and pose the body.
##
## Returns true while a shot still owns the body, so a caller driving a
## sequence knows when it is free again.
func advance(delta: float) -> bool:
	if _running and _clip != null:
		_time += delta * FRAMES_PER_SECOND * _speed
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
				# running out is a real end and not only a safety net; a
				# resumed clip ends here too, and so does an idle -- whose
				# clock clamps at the length and whose last frame is held
				# (docs/42 section 6.2).
				_time = _clip.duration
				_running = false
		if body != null:
			body.pose(_clip, _time, mode == Mode.MOVE)
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
	return {"mode": mode, "time": _time, "held": _held,
		"past_break": mode == Mode.FIRE and _stop_at < 0.0,
		"running": _running,
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
	var name: String = DictRead.as_string(saved.get("clip", ""))
	if want == Mode.IDLE and name == "":
		# The bind pose carries as itself.
		return true
	var clip: CharismaClip = _fire
	if want == Mode.IDLE:
		clip = _idle if _idle != null and _idle.name == name else null
		if clip == null and clip_lookup.is_valid():
			clip = clip_lookup.call(name)
		_idle = clip
	elif clip == null or clip.name != name:
		# **A shot's one-off clip** ([method use_shot_clip]): the bayonet's
		# `P0_F1_001` is not the weapon's `F0`, and a rebuild mid-stab -- the
		# victim's death frees every node -- put the stabber back in its
		# bind pose for the frame the blood appears in, with
		# [method resume_past_break] then answering 0. Found by name and
		# set as the override again, so [method fire_clip] and
		# [method rest] see the same shot they did before the rebuild.
		clip = null
		if clip_lookup.is_valid():
			clip = clip_lookup.call(name)
		if clip != null:
			use_shot_clip(clip)
	if clip == null or clip.name != name:
		return false
	var stop: float = clip.break_time() if want == Mode.FIRE else -1.0
	if DictRead.as_bool(saved.get("past_break", false)):
		stop = -1.0
	_enter(want, clip, false, stop,
		SPEED_FIGHT if want == Mode.FIRE else SPEED_IDLE)
	_time = DictRead.as_float(saved.get("time", 0.0))
	_held = DictRead.as_bool(saved.get("held", false))
	if _stop_at >= 0.0 and _time >= _stop_at:
		_time = _stop_at
		_running = false
	elif clip.duration > 0.0 and _time >= clip.duration:
		_time = clip.duration
		_running = false
	elif not DictRead.as_bool(saved.get("running", true)):
		_running = false
	if body != null:
		body.pose(_clip, _time, false)
	return true


func _enter(new_mode: int, clip: CharismaClip, looping: bool,
		stop_at: float, speed: float) -> void:
	mode = new_mode
	_clip = clip
	_looping = looping
	_stop_at = stop_at
	_speed = speed
	_time = 0.0
	# **Not unconditionally true.** A null clip has nothing to run, and
	# saying it does left a body with no `F` permanently busy.
	_running = clip != null
	_held = false
	if body != null:
		# The movement clip is the one that walks the body away from its own
		# node, because the walk itself is the node's ([method
		# CharismaBody.pose]). Nothing else moves under a clip.
		body.pose(_clip, _time, mode == Mode.MOVE)
