extends TestSuite

## Oracle boundary: **executable Python**.
##
## `tools/inclib/pose.py` is `V100Part::Update` (`0x004A6807`) in Python -- the
## model that draws `tools/out/skeletons/*.png`, the four contact sheets that
## are the by-eye proof of docs/40 sections 5.2 and 6. This suite replays its
## output and requires [CharismaSkeleton] to agree bone by bone.
##
## **There is no native oracle for animation, and that is structural rather
## than an omission.** `tools/wine_visn/` works because VISN lives in
## `Eng3d.dll` and is *exported*; Charisma is statically linked into
## `Incubation.exe`, and `Eng3d.dll`'s 89 exports are all `E3D_*` renderer
## entry points with no `V100`, no skeleton and no animation among them.
## `tools/dbgcall/` can reach code inside a live process, but `V100Part::Update`
## takes a constructed part with a loaded descriptor and a bound movement --
## pointers, not values -- so standing one up is most of a loader.
## `tests/fixtures/charisma/README.md` records this.
##
## **The tolerance.** This is the project's first diff that is not exact
## integers: `slerp` and `squad` go through libm transcendentals, so Python and
## GDScript cannot promise bit equality. Every error the suite exists to catch
## is two to four orders of magnitude above [constant TOLERANCE], and all of
## them are measured in docs/40:
##
## * a transposed or `(w, x, y, z)` quaternion -- gross, whole limbs;
## * slerp where the engine uses squad -- up to **0.246** per component;
## * dropping the 0.25/0.5 hold rule -- changes **5.2 %** of all intervals;
## * skipping `quat_to_matrix`'s squared-norm division -- mis-scales the 1 169
##   shipped keys that are over 1 % off unit, by up to 40 %;
## * adding the bind translation on the top-level bone -- moves the whole
##   figure, for `P0_000` from z = 29 to z = 129.

const CASES: String = "res://generated/charisma/pose.json"

## **The tolerance is absolute, in engine world units, and it is flat.**
##
## Two earlier attempts are worth recording, because each was wrong in a way
## that looked reasonable:
##
## * a flat **1e-4** failed at 1.2e-4 over 22 890 positions. That was real, and
##   it was mine: the sampler returned `PackedFloat32Array`, so every
##   intermediate quaternion was rounded to single precision while
##   `inclib/pose.py` kept doubles. Widening the arithmetic -- which is also
##   what the original did, on an x87 FPU with 80-bit intermediates -- cut the
##   disagreement ninefold;
## * a **relative** bound then failed at 2.1e-5, on a joint coordinate of
##   magnitude 0.0102 inside a body spanning ~10 000 units. That is
##   cancellation, not error: a coordinate that near zero carries no relative
##   precision to compare. A relative bound measures the wrong thing here.
##
## So: no element of any bone's local matrix, and no joint coordinate, may
## differ from the Python reference by more than [constant TOLERANCE] engine
## world units anywhere. At 1600 units to the metre that is **0.6 micrometres
## of body**, and it is four to six orders of magnitude below every error the
## diff exists to catch -- slerp instead of squad displaces a joint by tens of
## units, a transposed quaternion by hundreds.
const TOLERANCE: float = 1e-3

## The interpolators the fixture must exercise. A fixture of only the two
## linear paths would still look broad and would pin neither `squad` nor the
## cubic Bezier vector -- the two places the engine's maths is not the
## textbook's.
const REQUIRED_KEY_CLASSES: Array[String] = ["LinearRotationKey",
	"LinearVectorKey", "BezierRotationKey", "BezierVectorKey"]


func run(h: TestHarness) -> void:
	h.begin("charisma", TestHarness.ORACLE_PYTHON)
	# **Before the fixture gate**, because this one needs no oracle: a model
	# either builds or it does not.
	_unnamed_part(h)
	if not FileAccess.file_exists(CASES):
		h.check("fixture", false,
			"run python3 tools/charisma_tables.py gog_incubation "
			+ "--emit-pose-cases tests/fixtures/charisma/cases_pose.json")
		return
	var document: Dictionary = CacheLoader.read_json(CASES)
	if document.is_empty():
		h.check("fixture", false, "%s did not parse" % CASES)
		return
	var cases: Array = DictRead.as_array(document["cases"])
	h.check("fixture", not cases.is_empty(), "%d (model, clip) pairs" % cases.size())

	var models: Dictionary[String, CharismaModel] = {}
	var clips: Dictionary[String, CharismaClip] = {}
	var seen_classes: Dictionary[String, bool] = {}
	var pairs: int = 0
	var skipped: int = 0
	var frames: int = 0
	var bones: int = 0
	var worst: float = 0.0
	## The magnitude of the value the worst absolute delta was measured on --
	## without it, "off by 1e-4" says nothing about whether that is close.
	var worst_magnitude: float = 0.0
	var bad: PackedStringArray = PackedStringArray()
	var bad_locals: PackedStringArray = PackedStringArray()
	var ignored_targets: Dictionary[String, bool] = {}

	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var model_name: String = DictRead.as_string(kase["model"])
		var clip_name: String = DictRead.as_string(kase["animation"])
		for value: Variant in DictRead.as_array(kase["key_classes"]):
			seen_classes[DictRead.as_string(value)] = true
		var model: CharismaModel = _model(models, model_name)
		var clip: CharismaClip = _clip(clips, clip_name)
		if model == null or clip == null:
			# The fixture covers every pairing the selectors can produce; the
			# cache carries only the converted missions' closure. A pair the
			# cache does not have is skipped and counted, never failed --
			# `pairs` is what keeps that from hollowing the suite out.
			skipped += 1
			continue
		pairs += 1

		# docs/40 section 7: a track whose target is no part of this body is an
		# authoring helper and the runtime **ignores** it. Counting them here
		# is what makes "ignored, not fatal" an assertion instead of a hope.
		for target: String in clip.targets():
			if not model.bind_of.has(target):
				ignored_targets[target] = true

		var order: PackedStringArray = _strings(kase["bones"])
		for frame_entry: Variant in DictRead.as_array(kase["frames"]):
			var frame: Dictionary = DictRead.as_dict(frame_entry)
			var want: Array = DictRead.as_array(frame["joints"])
			var posed: CharismaSkeleton = CharismaSkeleton.pose(
				model, clip, DictRead.as_float(frame["time"]))
			frames += 1
			for i: int in range(order.size()):
				var got: Vector3 = posed.joint(order[i])
				bones += 1
				for axis: int in range(3):
					var expected: float = DictRead.as_float(want[i * 3 + axis])
					var delta: float = absf(got[axis] - expected)
					if delta > worst:
						worst = delta
						worst_magnitude = absf(expected)
					if delta > TOLERANCE and bad.size() < 8:
						bad.append("%s/%s @%.3f %s.%d off by %.9f"
							% [model_name, clip_name,
								DictRead.as_float(frame["time"]),
								order[i], axis, delta])

		# The full local matrix of every bone at one frame. A rotation error on
		# a **childless leaf** moves no joint at all, so positions alone would
		# pass it.
		var locals: Array = DictRead.as_array(kase["locals"])
		var at: CharismaSkeleton = CharismaSkeleton.pose(
			model, clip, DictRead.as_float(kase["local_time"]))
		for i: int in range(order.size()):
			var mine: PackedFloat64Array = at.local_matrix(order[i])
			for e: int in range(16):
				var target_value: float = DictRead.as_float(locals[i * 16 + e])
				var off: float = absf(mine[e] - target_value)
				if off > worst:
					worst = off
					worst_magnitude = absf(target_value)
				if off > TOLERANCE and bad_locals.size() < 8:
					bad_locals.append("%s/%s %s[%d] off by %.9f"
						% [model_name, clip_name, order[i], e, off])

	h.check("pairs", pairs >= 24,
		"%d pairs posed against the cache, %d outside its closure"
			% [pairs, skipped])
	h.equal("joints", ", ".join(bad), "",
		"%d bone positions over %d frames, worst delta %.9f"
			% [bones, frames, worst])
	h.equal("locals", ", ".join(bad_locals), "",
		"every bone's full local matrix at one frame per pair")
	h.check("within_tolerance", worst <= TOLERANCE,
		"worst delta %.9f engine units, on a value of %.3f; tolerance %.9f"
			% [worst, worst_magnitude, TOLERANCE])

	# The fixture's own coverage, asserted rather than assumed.
	for key_class: String in REQUIRED_KEY_CLASSES:
		h.check("covers." + key_class, seen_classes.has(key_class),
			"a fixture without it pins neither squad nor the Bezier vector")
	h.check("ignores_helper_tracks", not ignored_targets.is_empty(),
		"%d target(s) with no part, ignored rather than fatal: %s"
			% [ignored_targets.size(),
				", ".join(PackedStringArray(ignored_targets.keys()))])
	_state_machine(h, clips)
	_walking(h)
	_facing(h)
	_stride(h, cases, models, clips)
	_shooting(h, clips)
	_pacing(h)


## How fast a body walks, and that the computer's replay waits for it.
##
## The pace is not a taste setting: `aExecuteMove` crosses a field in **six**
## rendered frames ([constant SliceMain.FRAMES_PER_FIELD], measured off the two
## walk helpers), and gameplay advances animation time by one key unit per
## rendered frame, so a field is six frames of the clip at whatever rate the
## loop runs.
## Both halves of that are asserted here, because the two constants drifted
## apart once already -- 0.16 s a field against 30 fps was the original's
## **epoch bug**, not its design.
func _pacing(h: TestHarness) -> void:
	h.equal("pacing.frames_per_field", SliceMain.FRAMES_PER_FIELD, 6,
		"aExecuteMove divides the step by six and loops six times")
	var derived: float = float(SliceMain.FRAMES_PER_FIELD) \
		/ CharismaState.FRAMES_PER_SECOND
	h.check("pacing.derived",
		absf(SliceMain.WALK_SECONDS_PER_STEP - derived) < 0.000001,
		"%.4f s a field, six frames at %.0f fps"
			% [SliceMain.WALK_SECONDS_PER_STEP, CharismaState.FRAMES_PER_SECOND])

	# And the replay holds for the walk it started. A four-field move outlasts
	# `STEP_SECONDS`, and the next event's rebuild would cut it off half way.
	var result: AITurnResult = AITurnResult.new()
	result.add(AIEvent.make("move", 1, 0, 0, 1, 1, 0, ""))
	result.add(AIEvent.make("move", 2, 0, 0, 2, 2, 0, ""))
	var seen: Array[int] = [0]
	var playback: AIPlayback = AIPlayback.new()
	playback.play(result, func(event: Dictionary) -> float:
		if event.is_empty():
			return 0.0
		seen[0] += 1
		return 1.0 if seen[0] == 1 else 0.0)
	playback.advance(AIPlayback.STEP_SECONDS)
	h.equal("pacing.replay.first", seen[0], 1, "one event shown")
	playback.advance(0.5)
	h.equal("pacing.replay.waits", seen[0], 1,
		"half a second later the walk it asked a second for is still running")
	playback.advance(0.6)
	h.equal("pacing.replay.resumes", seen[0], 2,
		"and the next event follows once the walk is over")


## Which way a body faces, over all eight facings.
##
## This is the check that would have caught units walking backwards.  It is
## pure arithmetic over three things that already exist -- the facing table
## `docs/10` section 5.10, the step-to-facing table `aExecuteMove` confirmed
## natively twice, and the direction a Charisma model is authored facing --
## so it needs no cache and no body, and it fails on any convention but the
## one [method WorldSpace.charisma_yaw_basis] states.
func _facing(h: TestHarness) -> void:
	var steps: Dictionary[int, Vector2i] = {}
	for step: Vector2i in ExecuteMove.FACING_OF_STEP:
		steps[DictRead.as_int(ExecuteMove.FACING_OF_STEP[step])] = step
	h.equal("facing.table", steps.size(), UnitsView.FACING_ANGLES.size(),
		"eight facings, each reached by exactly one step")

	var wrong: PackedStringArray = PackedStringArray()
	var marker: PackedStringArray = PackedStringArray()
	var geometry: PackedStringArray = PackedStringArray()
	var units: UnitsView = UnitsView.new()
	var node: Node3D = Node3D.new()
	var body: CharismaBody = CharismaBody.new()
	node.add_child(body)
	units.add_child(node)
	for facing: int in range(UnitsView.FACING_ANGLES.size()):
		var step: Vector2i = steps[facing]
		# The step as a Godot direction: `cell_centre` sends map +y to -z.
		var want: Vector3 = Vector3(float(step.x), 0.0,
			-float(step.y)).normalized()
		var angle: int = UnitsView.FACING_ANGLES[facing]
		units._face(node, body, facing)
		var faces: Vector3 = (node.basis * body.basis
			* CharismaBody.AUTHORED_FORWARD).normalized()
		if faces.distance_to(want) > 0.0001:
			wrong.append("facing %d walks %s facing %s"
				% [facing, str(want), str(faces)])
		# And the node itself is left on the engine's own yaw, which is what
		# the ground marker under it is drawn with.
		if not node.basis.is_equal_approx(WorldSpace.yaw_basis(angle)):
			marker.append("facing %d" % facing)
		# The Eng3d half of the same table, and the half that fails on a wrong
		# sign: Eng3d geometry is authored along engine **+Y**, so an object
		# turned by this facing's own angle must point where the step goes.
		# The body's half above cannot catch that on its own -- it went on
		# agreeing while [method WorldSpace.yaw_basis] turned the wrong way,
		# because the correction it carries absorbed the error (docs/97 §47).
		var eng3d: Vector3 = (WorldSpace.yaw_basis(angle)
			* WorldSpace.to_godot(0, 1600, 0)).normalized()
		if eng3d.distance_to(want) > 0.0001:
			geometry.append("facing %d points %s, walks %s"
				% [facing, str(eng3d), str(want)])
	units.free()
	h.equal("facing.body_walks_forwards", ", ".join(wrong), "",
		"all eight facings, body forward against the step it takes")
	h.equal("facing.marker_keeps_engine_yaw", ", ".join(marker), "",
		"the node stays on docs/10 section 5.10's own angle")
	h.equal("facing.eng3d_forward_walks_forwards", ", ".join(geometry), "",
		"all eight facings, an object's +Y against the step it takes")


## The stride a movement clip carries, and that a walk takes it back out.
##
## A movement clip is authored walking: `P0_M0_000` moves its top-level bone
## one map field over its 20 frames, and 94 of the 99 pairings the selectors
## produce stride at all.  [method UnitsView.start_walk] moves the
## node itself, so a clip played untouched adds a second field per loop and the
## body slides out of its own square -- which is why [method CharismaBody.pose]
## takes `in_place`.  Both halves are asserted: that the stride is really there
## in the shipped data, and that cancelling it leaves nothing behind.
func _stride(h: TestHarness, cases: Array,
		models: Dictionary[String, CharismaModel],
		clips: Dictionary[String, CharismaClip]) -> void:
	var strides: int = 0
	var worst_cancelled: float = 0.0
	var worst_free: float = 0.0
	var largest: float = 0.0
	var name: String = ""
	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var clip_name: String = DictRead.as_string(kase["animation"])
		if not clip_name.contains("_M0_"):
			continue
		var model: CharismaModel = _model(models,
			DictRead.as_string(kase["model"]))
		var clip: CharismaClip = _clip(clips, clip_name)
		if model == null or clip == null or clip.duration <= 0.0:
			continue
		var start: CharismaSkeleton = CharismaSkeleton.pose(model, clip, 0.0)
		var end: CharismaSkeleton = CharismaSkeleton.pose(model, clip,
			clip.duration)
		var travel: Vector2 = CharismaBody.stride(model, start, end)
		if travel.length() > largest:
			largest = travel.length()
			name = "%s/%s" % [DictRead.as_string(kase["model"]), clip_name]
		if travel.length() * CharismaBody.SKELETON_TO_WORLD <= 1000.0:
			continue
		strides += 1
		# Measured on what the body would actually draw. The probe stands in
		# for a mesh on the top-level bone -- half a biped's bones carry none,
		# and which node moves is not the point: every part of a body carries
		# its top-level bone's translation.
		var bone: String = CharismaBody.top_level_bone(model)
		var body: CharismaBody = CharismaBody.new()
		body._model = model
		var probe: MeshInstance3D = MeshInstance3D.new()
		body.add_child(probe)
		body._nodes[bone] = probe
		body.pose(clip, 0.0, true)
		var held: Vector3 = probe.position
		body.pose(clip, clip.duration, true)
		worst_cancelled = maxf(worst_cancelled,
			Vector2(probe.position.x - held.x,
				probe.position.z - held.z).length())
		body.pose(clip, 0.0, false)
		held = probe.position
		body.pose(clip, clip.duration, false)
		worst_free = maxf(worst_free,
			Vector2(probe.position.x - held.x,
				probe.position.z - held.z).length())
		body.free()
	h.check("stride.present", strides > 0,
		"%d movement pairing(s) walk more than 1000 world units; largest %s "
		% [strides, name]
		+ "at %.0f" % (largest * CharismaBody.SKELETON_TO_WORLD))
	h.check("stride.travels_when_played_raw", worst_free > 1.0,
		"a movement clip left alone carries the body %.2f m" % worst_free)
	h.check("stride.cancelled", worst_cancelled < 0.0001,
		"in place, the same clip moves it %.6f m" % worst_cancelled)


## What [CharismaState] plays and when it stops.
##
## The three rules that come from call sites rather than from the letters:
## `S` loops because it is what plays when nothing else does, `M` loops for as
## long as the walk lasts, and `F` plays **once** and halts at its `BREAK`
## note because `fcn.004055E0` registers a stop callback on that text.
func _state_machine(h: TestHarness, clips: Dictionary[String, CharismaClip]) -> void:
	# A clip with a BREAK note and one without, taken from what the cache has
	# rather than constructed, so the test is about shipped data.
	var with_break: CharismaClip = null
	var without: CharismaClip = null
	for clip_name: String in clips:
		var clip: CharismaClip = clips[clip_name]
		if clip == null:
			continue
		if clip.break_time() >= 0.0 and with_break == null:
			with_break = clip
		elif clip.break_time() < 0.0 and clip.duration > 0.0 and without == null:
			without = clip
	h.check("break_note_found", with_break != null,
		"" if with_break == null
			else "%s breaks at %.1f of %.1f"
				% [with_break.name, with_break.break_time(), with_break.duration])
	if with_break == null:
		return

	# A body is not needed to test the clock, and not having one also proves
	# the state machine tolerates a null body -- which is what a unit whose
	# type has no model gets.
	var state: CharismaState = CharismaState.create(null, without, without,
		with_break)
	h.equal("starts_idle", state.mode, CharismaState.Mode.IDLE)
	h.check("idle_is_not_busy", not state.is_busy(), "nothing to wait for")

	var length: float = state.fire()
	h.equal("fire_mode", state.mode, CharismaState.Mode.FIRE)
	h.check("fire_is_busy", state.is_busy(), "a one-shot is running")
	# docs/42 section 1.2 -- the `F` clip runs at speed 6.0, so the note at
	# 17..36 key units is reached in three to six frames, not in 0.85 s.
	var frames_to_break: int = ceili(with_break.break_time()
		/ CharismaState.SPEED_FIGHT)
	h.equal("fire_frames_to_break", state.frames_to_break(), frames_to_break,
		"%s breaks at %.1f: %d frame(s) at speed 6"
			% [with_break.name, with_break.break_time(), frames_to_break])
	h.check("fire_reports_frames_at_speed_6",
		absf(length - float(frames_to_break) / CharismaState.FRAMES_PER_SECOND)
			< 0.000001, "%.3f s to the note" % length)
	h.equal("fire_spin_frames", state.spin_frames(),
		int(with_break.duration / CharismaState.SPEED_FIGHT) / 3,
		"int(len / 6) / 3 -- a third of the clip's length in frames")

	# Advance to the note. It must have stopped, which is the whole
	# difference `BREAK` makes -- and it takes speed 6 into account.
	state.advance(float(frames_to_break) / CharismaState.FRAMES_PER_SECOND)
	h.check("fire_stops_at_break", not state.is_playing(),
		"halted at %.1f, %.1f short of the clip's %.1f"
			% [with_break.break_time(),
				with_break.duration - with_break.break_time(),
				with_break.duration])
	h.check("fire_is_at_break", state.is_at_break(), "stopped at the note")

	# **The pose is held for the shot.** The engine's routine is blocking
	# and the body is its until the resume (docs/42 section 4.9); a body
	# rested the frame its clip stopped snapped to idle frame 0.
	h.check("break_pose_is_held", state.is_busy(),
		"a frame past the note, the body is still the shot's")
	state.advance(1.0 / CharismaState.FRAMES_PER_SECOND)
	h.equal("break_pose_does_not_advance", state._time, with_break.break_time(),
		"the callback halts the animation at the note and leaves it there")
	h.check("break_pose_still_held", state.is_busy(),
		"and it is still held a frame later")

	# `aContCHAnimation` -- the clip runs on past the note to its end.
	var left: int = state.resume_past_break()
	h.equal("resume_reports_remaining_frames", left,
		ceili((with_break.duration - with_break.break_time())
			/ CharismaState.SPEED_FIGHT),
		"the frames from the note to the end at speed 6")
	h.check("resume_plays", state.is_playing(), "the clip advances again")
	state.advance(float(left) / CharismaState.FRAMES_PER_SECOND)
	h.check("resume_plays_out", not state.is_playing(),
		"and stops at its own end, %.1f" % with_break.duration)
	h.equal("resume_reaches_the_end", state._time, with_break.duration)
	h.check("resume_still_held", state.is_busy(),
		"held until the routine rests it")
	state.rest()
	h.check("rest_releases", not state.is_busy(), "the shot is over")
	h.equal("rests_after_fire", state.mode, CharismaState.Mode.IDLE)

	# **A fire clip with no `BREAK` note.** Four of the 33 shipped `F` clips
	# have none, so running out is a real end and not a safety net -- and it is
	# the only case that tests "F plays once": with a note, the note stops it
	# first and a looping one-shot would pass unnoticed.
	var once: CharismaState = CharismaState.create(null, without, without,
		without)
	var once_length: float = once.fire()
	once.advance((without.duration / CharismaState.SPEED_FIGHT + 1.0)
		/ CharismaState.FRAMES_PER_SECOND)
	h.check("fire_without_break_plays_out", not once.is_playing(),
		"%s has no BREAK and ends at its own %.1f"
			% [without.name, without.duration])
	h.check("fire_without_break_holds", once.is_busy(),
		"and is the shot's until it is rested, like a clip with a note")
	h.equal("fire_without_break_has_nothing_to_resume",
		once.resume_past_break(), 0, "it ran to its end already")
	once.rest()
	h.check("fire_without_break_stops", not once.is_busy(),
		"%s has no BREAK and ends at its own %.1f"
			% [without.name, without.duration])
	h.check("fire_without_break_length",
		absf(once_length - float(ceili(without.duration
			/ CharismaState.SPEED_FIGHT)) / CharismaState.FRAMES_PER_SECOND)
			< 0.000001,
		"a clip with no note reports its whole length at speed 6, %.3f s"
			% once_length)

	# **A type with no `F` clip at all** -- seven of the shipped ones (docs/40
	# section 7.2.1: Spider, Dec'Ther, Norc'Yn, Bea'Ther, Bea'Coo and types 62
	# and 63). `fire()` used to leave the state running with no clip, so
	# `advance()` answered "still running" for ever and the body never came
	# back to its idle. There is nothing to wait for and the length says so.
	var unarmed: CharismaState = CharismaState.create(null, without, without,
		null)
	var nothing: float = unarmed.fire()
	h.equal("null_fire_length", nothing, 0.0, "no clip, no wait")
	h.check("null_fire_is_not_busy", not unarmed.is_busy(),
		"a body with no `F` is free from the first frame")
	h.check("null_fire_does_not_spin", not unarmed.advance(1.0),
		"and `advance` agrees with `is_busy` about it")

	# An absent clip is normal -- nine unit types have one, and two have no
	# clip at all. It must hold, not crash and not spin.
	var bare: CharismaState = CharismaState.create(null, null, null, null)
	bare.fire()
	bare.advance(1.0)
	bare.walk()
	bare.advance(1.0)
	h.check("null_clips_survive", true,
		"a type with no clip holds its bind pose")

	# docs/42 section 6 -- the idle is a scheduler's, not a loop's: a fresh
	# body holds its bind pose, a started `S` plays **once** at speed 1.5
	# (two thirds of its length in frames), holds its last frame, and the
	# free snaps it back to bind. `rest()` after a shot is the bind pose too.
	var idle: CharismaState = CharismaState.create(null, without, without,
		with_break)
	h.check("idle_starts_in_bind", not idle.is_idling() and not idle.is_playing(),
		"no clip attached until a slot starts one")
	var idle_length: float = idle.start_idle(without)
	h.equal("idle_start_reports_length", idle_length, without.duration,
		"the countdown the slot stores is the clip's length")
	h.check("idle_plays_once", idle.is_playing() and idle.is_idling(), "")
	var frame: float = 1.0 / CharismaState.FRAMES_PER_SECOND
	var half: int = ceili(without.duration / CharismaState.SPEED_IDLE / 2.0)
	for _i: int in range(half):
		idle.advance(frame)
	h.check("idle_advances_1_5_a_frame",
		absf(idle._time - minf(float(half) * CharismaState.SPEED_IDLE,
			without.duration)) < 0.001,
		"%.1f key units after %d frames" % [idle._time, half])
	for _i: int in range(ceili(without.duration / CharismaState.SPEED_IDLE) + 2):
		idle.advance(frame)
	h.check("idle_holds_its_last_frame",
		not idle.is_playing() and idle.is_idling()
			and absf(idle._time - without.duration) < 0.001,
		"finished at %.1f and still attached" % idle._time)
	idle.detach_idle()
	h.check("idle_free_snaps_to_bind", not idle.is_idling(),
		"aFreeCHAnimation: the bind pose on the next step")
	idle.fire()
	idle.rest()
	h.check("rest_is_the_bind_pose", not idle.is_idling() and not idle.is_playing(),
		"aStopCHAnimation detaches the clip; no loop takes over")


func _strings(value: Variant) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for item: Variant in DictRead.as_array(value):
		out.append(DictRead.as_string(item))
	return out


func _model(cache: Dictionary[String, CharismaModel],
		model_name: String) -> CharismaModel:
	if cache.has(model_name):
		return cache[model_name]
	var document: Dictionary = _read("models/%s.json" % model_name)
	var model: CharismaModel = null if document.is_empty() \
		else CharismaModel.from_document(document)
	cache[model_name] = model
	return model


func _clip(cache: Dictionary[String, CharismaClip],
		clip_name: String) -> CharismaClip:
	if cache.has(clip_name):
		return cache[clip_name]
	var document: Dictionary = _read("animations/%s.json" % clip_name)
	var clip: CharismaClip = null if document.is_empty() \
		else CharismaClip.from_document(document)
	cache[clip_name] = clip
	return clip


## Read one document out of the published cache.
##
## The fixture covers every pairing the selectors can produce, but the cache
## only carries the closure of the converted missions -- so a pair that is not
## there is skipped, not a failure. What must not happen is the reverse: a
## cache entry the suite fails to load, which `pairs` and `joints` would catch.
func _read(relative: String) -> Dictionary:
	var opened: Dictionary = CacheLoader.open_active()
	if not DictRead.as_bool(opened["ok"]):
		return {}
	var path: String = DictRead.as_string(opened["cache_dir"]) + "/" + relative
	if not FileAccess.file_exists(path):
		return {}
	return CacheLoader.read_json(path)


## One shot, end to end, at the level the game drives: turn the body, play the
## clip, hold the struck pose, and come back to the idle.
##
## **The defect this pins.** [method UnitsView.animate] used to rest the body on
## the frame the `BREAK` note stopped the clip, so the pose the engine holds was
## thrown away as soon as it was struck and a shot read as nothing having
## happened. The second half is the type with no `F` clip, which the same edit
## covers: it is never busy for a frame, so an edge test never returned it to
## its idle and it stayed in `FIRE` for the rest of the mission.
func _shooting(h: TestHarness, clips: Dictionary[String, CharismaClip]) -> void:
	var with_break: CharismaClip = null
	var without: CharismaClip = null
	for clip_name: String in clips:
		var clip: CharismaClip = clips[clip_name]
		if clip == null:
			continue
		if clip.break_time() >= 0.0 and with_break == null:
			with_break = clip
		elif clip.break_time() < 0.0 and clip.duration > 0.0 and without == null:
			without = clip
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if with_break == null or without == null or loaded.is_empty():
		h.check("shot.fixture", false, "no clips, or no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var slot: int = -1
	for candidate: int in world.unit_slots():
		var view: Dictionary = world.unit_view(candidate)
		if not view.is_empty() and DictRead.as_int(view["player"]) == 0:
			slot = candidate
			break
	if slot < 0:
		h.check("shot.unit", false, "no player unit on _C_140")
		return

	var units: UnitsView = UnitsView.new()
	units.world_ref = world
	var node: Node3D = Node3D.new()
	node.name = "unit_%d" % slot
	units.add_child(node)
	units.states[slot] = CharismaState.create(null, without, without, with_break)

	# A target four fields east of the shooter: far enough that the neighbour
	# step table [method UnitsView._facing_of] reads would not answer at all,
	# which is why the turn goes through `Combat.direction` instead.
	var view: Dictionary = world.unit_view(slot)
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	var step: int = 4 if x + 4 < world.resource.width else -4
	var length: float = units.fire(slot, x + step, y)
	h.equal("shot.mode", units.states[slot].mode, CharismaState.Mode.FIRE,
		"the body is playing its combat clip")
	h.check("shot.length", length > 0.0,
		"%.3f s of clip and held pose" % length)
	var facing: int = Combat.direction(x, y, x + step, y)
	h.check("shot.faces_the_target",
		node.basis.is_equal_approx(WorldSpace.yaw_basis(
			UnitsView.FACING_ANGLES[facing])),
		"turned to facing %d, four fields away" % facing)

	# Driven the way `_process` drives it: fixed steps, and the body is not
	# free until the whole reported length has passed.
	var elapsed: float = 0.0
	var tick: float = 1.0 / CharismaState.FRAMES_PER_SECOND
	while elapsed < length - tick:
		units.animate(tick, world)
		elapsed += tick
		if units.states[slot].mode != CharismaState.Mode.FIRE:
			break
	h.check("shot.holds_for_its_length",
		units.states[slot].mode == CharismaState.Mode.FIRE,
		"%.3f s in, the body is still the shot's" % elapsed)
	for _i: int in range(3):
		units.animate(tick, world)
		elapsed += tick
	# The body is the shot's until the routine rests it (docs/42 section
	# 4.9): the note holds the pose, nothing on a timer takes it away.
	h.equal("shot.held_past_the_note", units.states[slot].mode,
		CharismaState.Mode.FIRE,
		"%.3f s in, the pose is still the shot's" % elapsed)
	units.rest(slot)
	h.equal("shot.returns_to_the_idle", units.states[slot].mode,
		CharismaState.Mode.IDLE,
		"rested by the shot's end -- which is what plays when nothing else does")

	# The type with no `F`: nothing to wait for, and back to the idle on the
	# very next frame rather than never.
	units.states[slot] = CharismaState.create(null, without, without, null)
	h.equal("shot.null_clip_length", units.fire(slot, x + step, y), 0.0,
		"a type with no combat clip asks for no time at all")
	h.check("shot.null_clip_is_not_busy", not units.any_busy(),
		"and nothing is waiting on it")
	units.animate(tick, world)
	h.equal("shot.null_clip_returns_to_the_idle", units.states[slot].mode,
		CharismaState.Mode.IDLE,
		"the body a missing clip left in FIRE for ever comes back")
	units.free()


## The walk: a body between two cells while it runs, and **on** its last cell
## when it stops.
##
## The second half is why this exists. `finish_walks` at first only called
## `rest()` on the state and never touched the node, so a finished walk left
## the body wherever the previous interpolated frame put it -- short of its
## destination. For the player that off-centre idle sits there until the next
## command; for `AIPlayback.skip()` it strands bodies between cells, which is
## exactly the state `skip()` promises cannot happen. Nothing else in the
## suite looks at a unit node's position.
func _walking(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("walk.mission", false, "_C_140 is not in the cache")
		return
	var world: World = loaded["world"]
	var slot: int = -1
	for candidate: int in world.unit_slots():
		var view: Dictionary = world.unit_view(candidate)
		if not view.is_empty() and DictRead.as_int(view["player"]) == 0:
			slot = candidate
			break
	if slot < 0:
		h.check("walk.unit", false, "no player unit on _C_140")
		return

	var units: UnitsView = UnitsView.new()
	units.name = "unit_%d_holder" % slot
	var node: Node3D = Node3D.new()
	node.name = "unit_%d" % slot
	units.add_child(node)

	# Three cells in a row from the unit's own, which is somewhere standable.
	# The step is chosen to stay in the row: `+1` on a cell index is `+1` in x
	# only while x stays below the width, and past it the index wraps onto the
	# next row -- which the first version of this test did, landing the body a
	# full map width away and blaming the code.
	var view: Dictionary = world.unit_view(slot)
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	var width: int = world.resource.width
	var step: int = 1 if x + 2 < width else -1
	var cells: PackedInt32Array = PackedInt32Array([
		y * width + x, y * width + x + step, y * width + x + step * 2])
	var last: Vector3 = WorldSpace.cell_centre(x + step * 2, y,
		world.state.height_at(cells[2]))

	# The node starts **on its first cell**. Leaving it at the origin made
	# `walk.moves` pass for free -- the origin is metres from any cell centre,
	# so "it is not where it started" was true before the walk ran at all.
	var first: Vector3 = WorldSpace.cell_centre(x, y,
		world.state.height_at(cells[0]))
	node.position = first
	units.world_ref = world
	node.position = Vector3(99.0, 99.0, 99.0)
	units.start_walk(slot, cells, width, 1.0)
	h.check("walk.started", units.is_walking(), "three cells over one second")
	# **On its first cell before a single frame is drawn.** `_advance_walk`
	# writes the position on the frame *after* the walk starts, so the body was
	# left wherever the rebuild put it for one rendered frame -- and for the
	# computer's replay that is where the unit stands at the end of the whole
	# turn, which made an alien appear at its destination and then walk to it.
	h.check("walk.starts_on_its_first_cell",
		node.position.distance_to(first) < 0.001,
		"%.3f m from the source centre" % node.position.distance_to(first))
	units.animate(0.5, world)
	var midway: Vector3 = node.position
	h.check("walk.moves", midway.distance_to(first) > 0.1,
		"half way along, the body has left its first cell")
	h.check("walk.not_arrived", midway.distance_to(last) > 0.1,
		"and has not reached the last one")

	units.finish_walks(world)
	h.check("walk.stopped", not units.is_walking(), "the walk is over")
	h.check("walk.lands_on_the_last_cell",
		node.position.distance_to(last) < 0.001,
		"%.3f m from the destination centre" % node.position.distance_to(last))
	units.free()


## `PC_011.cho` has a part with **no name at all**, and it must still build.
##
## Part 2 of that model is authored with an empty name and the mesh `PC_011_`;
## Godot refuses an empty node name outright (`Condition "p_name.is_empty()"
## is true`), so the body used to be built with an engine error printed for it
## and the mesh left unnamed. Unit type 61 selects this model and `_C_118` is
## the one shipped mission that places one, so `[`/`]` or *Instant Action*
## reaches it.
func _unnamed_part(h: TestHarness) -> void:
	var cache_dir: String = CacheFixture.cache_dir()
	var document: Dictionary = CacheFixture.read_json(
		"%s/models/PC_011.json" % cache_dir)
	if document.is_empty():
		h.check("unnamed.model_present", false,
			"the cache carries no PC_011 -- publish one with --campaign-maps")
		return
	var model: CharismaModel = CharismaModel.from_document(document)
	var empty: int = 0
	for bone: String in model.bones:
		if bone.is_empty():
			empty += 1
	h.equal("unnamed.the_shipped_model_has_one", empty, 1,
		"authored data, not a converter defect")

	var library: CharismaLibrary = CharismaLibrary.open(cache_dir,
		CacheFixture.texture_index("A00"), "_C_118")
	var body: CharismaBody = CharismaBody.create(model, library)
	if body == null:
		h.check("unnamed.body_builds", false,
			"no mesh for PC_011 in this cache")
		return
	var blank: PackedStringArray = PackedStringArray()
	for child: Node in body.get_children():
		if String(child.name).is_empty():
			blank.append("(empty)")
	h.equal("unnamed.no_node_is_unnamed", blank, PackedStringArray(),
		"an unnamed part takes a positional name and is still drawn")
	h.check("unnamed.the_part_is_still_drawn",
		body.get_child_count() >= empty,
		"%d node(s) built" % body.get_child_count())
	body.free()
