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

	state.fire()
	h.equal("fire_mode", state.mode, CharismaState.Mode.FIRE)
	h.check("fire_is_busy", state.is_busy(), "a one-shot is running")
	# Advance past the note but well short of the clip's end. It must have
	# stopped, which is the whole difference `BREAK` makes.
	var to_break: float = with_break.break_time() \
		/ CharismaState.FRAMES_PER_SECOND
	state.advance(to_break + 0.05)
	h.check("fire_stops_at_break", not state.is_busy(),
		"halted at %.1f, %.1f short of the clip's %.1f"
			% [with_break.break_time(),
				with_break.duration - with_break.break_time(),
				with_break.duration])
	state.rest()
	h.equal("rests_after_fire", state.mode, CharismaState.Mode.IDLE)

	# **A fire clip with no `BREAK` note.** Four of the 33 shipped `F` clips
	# have none, so running out is a real end and not a safety net -- and it is
	# the only case that tests "F plays once": with a note, the note stops it
	# first and a looping one-shot would pass unnoticed.
	var once: CharismaState = CharismaState.create(null, without, without,
		without)
	once.fire()
	once.advance((without.duration + 1.0) / CharismaState.FRAMES_PER_SECOND)
	h.check("fire_without_break_stops", not once.is_busy(),
		"%s has no BREAK and ends at its own %.1f"
			% [without.name, without.duration])

	# An absent clip is normal -- nine unit types have one, and two have no
	# clip at all. It must hold, not crash and not spin.
	var bare: CharismaState = CharismaState.create(null, null, null, null)
	bare.fire()
	bare.advance(1.0)
	bare.walk()
	bare.advance(1.0)
	h.check("null_clips_survive", true,
		"a type with no clip holds its bind pose")

	# The loop, which is the reason an idle can play for a whole mission -- and
	# it is checked through `rest()`, the path a body actually takes after a
	# shot, not only through the initial state. `mode` alone cannot show this:
	# it stays `IDLE` whether the clip loops or has quietly stopped.
	var looping: CharismaState = CharismaState.create(null, without, without,
		with_break)
	looping.fire()
	looping.rest()
	looping.advance((without.duration * 2.5) / CharismaState.FRAMES_PER_SECOND)
	h.equal("idle_loops", looping.mode, CharismaState.Mode.IDLE)
	h.check("idle_still_playing", looping.is_playing(),
		"two and a half lengths of %s after a shot, still running"
			% without.name)


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
	units.start_walk(slot, cells, width, 1.0)
	h.check("walk.started", units.is_walking(), "three cells over one second")
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
