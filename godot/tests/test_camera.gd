extends TestSuite

## Oracle boundary: specification-only.  docs/92 section 7.5 -- the original's
## framing, four ninety-degree steps and a free zoom.
##
## The step arithmetic is here because it had a real bug: the yaw counter runs
## modulo four, and tweening straight to `step * 90` unwinds the whole circle
## whenever that counter wraps.  Going 270 -> 0 spun the camera 270 degrees
## backwards instead of 90 forwards, once per turn, in one direction only --
## which is exactly the shape of bug a test catches and an eye does not, since
## the other three steps look right.

const STEPS: int = 4
const QUARTER: float = PI / 2.0
const EPSILON: float = 0.000001


func run(h: TestHarness) -> void:
	h.begin("camera", TestHarness.ORACLE_SPEC)
	_check_full_turns(h)
	_check_recovery(h)
	_check_zoom(h)
	_check_zoom_inputs(h)
	_check_pivot(h)
	_inside_the_level(h)


## Four presses in either direction must be four equal quarter turns, and the
## camera must end up exactly where it started.
func _check_full_turns(h: TestHarness) -> void:
	for direction: int in [1, -1]:
		var label: String = "cw" if direction > 0 else "ccw"
		var angle: float = 0.0
		var step: int = 0
		var deltas: PackedFloat64Array = PackedFloat64Array()
		for _i: int in range(STEPS):
			step = posmod(step + direction, STEPS)
			var target: float = CameraRig.short_way(
				wrapf(angle, 0.0, TAU), step)
			deltas.append(target - wrapf(angle, 0.0, TAU))
			angle = target
		var wrong: PackedStringArray = PackedStringArray()
		for i: int in range(deltas.size()):
			if absf(deltas[i] - float(direction) * QUARTER) > EPSILON:
				wrong.append("step %d moved %.4f rad" % [i, deltas[i]])
		h.equal("turn.%s.quarter_steps" % label, ", ".join(wrong), "",
			"no step takes the long way round")
		h.equal("turn.%s.returns_to_start" % label,
			absf(wrapf(angle, 0.0, TAU)) < EPSILON
				or absf(wrapf(angle, 0.0, TAU) - TAU) < EPSILON, true)
		h.equal("turn.%s.counter" % label, step, 0)

	# The specific case that was broken: the wrap from the last step to the
	# first must go forwards, not 270 degrees backwards.
	var at_270: float = 3.0 * QUARTER
	h.check("wrap.forwards",
		CameraRig.short_way(at_270, 0) > at_270,
		"270 -> 0 tweens to %.4f, past 270 rather than back to zero"
			% CameraRig.short_way(at_270, 0))
	h.check("wrap.backwards",
		CameraRig.short_way(0.0, 3) < 0.0,
		"0 -> 270 tweens to %.4f, before zero rather than forward to 270"
			% CameraRig.short_way(0.0, 3))


## A tween killed part-way leaves the camera off the grid; the next step must
## still land on the grid rather than compound the error.
func _check_recovery(h: TestHarness) -> void:
	var mid: float = QUARTER * 0.37
	var target: float = CameraRig.short_way(mid, 1)
	h.equal("recovery.lands_on_grid",
		absf(target - QUARTER) < EPSILON, true,
		"from %.4f rad the next step ends at %.4f" % [mid, target])
	h.check("recovery.short", absf(target - mid) < PI,
		"and gets there the short way")


func _check_zoom(h: TestHarness) -> void:
	var rig: CameraRig = CameraRig.new()
	var heights: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
	# docs/10: camera_height is in world units; 19200 is _C_141's 12 metres.
	rig.setup(2, 2, heights, 19200)
	h.equal("zoom.max_from_camera_height", rig.max_zoom, 12.0,
		"the mission's own number is the far limit")
	h.equal("zoom.opens_at_the_limit",
		DictRead.as_float(rig.state()["zoom"]), 12.0)
	rig.zoom_by(40.0)
	h.equal("zoom.clamped_far", DictRead.as_float(rig.state()["zoom"]), 12.0)
	rig.zoom_by(-40.0)
	h.equal("zoom.clamped_near", DictRead.as_float(rig.state()["zoom"]),
		CameraRig.MIN_ZOOM)
	rig.free()


## Every device that can zoom, and in the right direction.
##
## The wheel worked and the trackpad did not: a macOS trackpad and a Magic
## Mouse send [InputEventPanGesture], not `MOUSE_BUTTON_WHEEL_*`, so a handler
## that knows only the wheel looks dead on the hardware this was written on.
## Negative means zoom in, matching [method CameraRig.zoom_by].
func _check_zoom_inputs(h: TestHarness) -> void:
	h.check("input.wheel_up_in",
		SliceMain.zoom_delta_for(_wheel(MOUSE_BUTTON_WHEEL_UP, true)) < 0.0,
		"a wheel notch up zooms in")
	h.check("input.wheel_down_out",
		SliceMain.zoom_delta_for(_wheel(MOUSE_BUTTON_WHEEL_DOWN, true)) > 0.0,
		"a wheel notch down zooms out")
	h.equal("input.wheel_release_ignored",
		SliceMain.zoom_delta_for(_wheel(MOUSE_BUTTON_WHEEL_UP, false)), 0.0,
		"the release half of a wheel event must not zoom a second time")
	h.equal("input.left_click_not_zoom",
		SliceMain.zoom_delta_for(_wheel(MOUSE_BUTTON_LEFT, true)), 0.0)

	# The pan direction is fixed by what the hardware actually does, reported
	# from the trackpad: a two-finger push away from the body is a positive
	# `delta.y` and zooms in.  The first version had it the other way round,
	# reasoned from the backend rather than measured.
	h.check("input.pan_push_in", SliceMain.zoom_delta_for(_pan(3.0)) < 0.0,
		"a two-finger push away from the body zooms in")
	h.check("input.pan_pull_out", SliceMain.zoom_delta_for(_pan(-3.0)) > 0.0,
		"and pulling towards the body zooms out")
	h.check("input.pinch_out_in", SliceMain.zoom_delta_for(_pinch(1.3)) < 0.0,
		"a spread zooms in")
	h.check("input.pinch_in_out", SliceMain.zoom_delta_for(_pinch(0.8)) > 0.0,
		"a pinch zooms out")

	h.check("input.key_equal_in",
		SliceMain.zoom_delta_for(_key(KEY_EQUAL, true)) < 0.0,
		"and there is a keyboard fallback that needs no gesture at all")
	h.check("input.key_minus_out",
		SliceMain.zoom_delta_for(_key(KEY_MINUS, true)) > 0.0)
	h.equal("input.key_q_not_zoom",
		SliceMain.zoom_delta_for(_key(KEY_Q, true)), 0.0,
		"the rotation keys must fall through to their own handling")


## The pivot sits on the centre **cell**, not on the middle row's left edge.
## `heights[size / 2]` is the latter, and on terrain that slopes east to west
## the two are different heights.
func _check_pivot(h: TestHarness) -> void:
	var w: int = 5
	var hgt: int = 5
	var heights: PackedInt32Array = PackedInt32Array()
	for y: int in range(hgt):
		for x: int in range(w):
			heights.append(x * 3200)
	var rig: CameraRig = CameraRig.new()
	rig.setup(w, hgt, heights, 40 * WorldSpace.WORLD_UNITS_PER_METRE)
	var centre: Vector3 = WorldSpace.cell_centre(w / 2, hgt / 2,
		heights[(hgt / 2) * w + w / 2])
	h.check("pivot.centre_cell", rig.position.is_equal_approx(centre),
		"pivot %s, centre cell %s" % [rig.position, centre])
	rig.free()


func _wheel(index: int, pressed: bool) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	return event


func _pan(dy: float) -> InputEventPanGesture:
	var event: InputEventPanGesture = InputEventPanGesture.new()
	event.delta = Vector2(0.0, dy)
	return event


func _pinch(factor: float) -> InputEventMagnifyGesture:
	var event: InputEventMagnifyGesture = InputEventMagnifyGesture.new()
	event.factor = factor
	return event


func _key(code: int, pressed: bool) -> InputEventKey:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.pressed = pressed
	return event


## A rotation that would take the eye out of the level is **refused**.
##
## The rule changed shape once, and the reason is worth keeping. The first
## version pulled the eye in every frame until it was clear. It satisfied
## "never inside geometry" everywhere -- and it was horrible to use: beside a
## wall the eye collapsed onto the unit's feet, and during a yaw tween the
## clearance changed every frame, so the view snapped back out to the ceiling
## the moment the wall passed. A continuous clamp on a discrete camera reads as
## the camera fighting the player.
##
## So the contract is no longer "the eye is never inside geometry". It is:
##
## * a rotation is allowed **only** if it ends with the eye inside the level,
##   unless no yaw would -- in which case refusing every direction would only
##   trap the player;
## * the opening yaw is chosen to be one that fits, when one does;
## * following a unit does **not** re-choose the yaw, because a camera that
##   turned by itself whenever the selection moved would be worse than one that
##   occasionally looks through a wall.
##
## Over every field of `_C_140` at all four steps -- 1600 combinations.
func _inside_the_level(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("bounds.mission", false, "_C_140 is not in the cache")
		return
	var world: World = loaded["world"]
	var heights: PackedInt32Array = world.resource.heights()
	var width: int = world.resource.width
	var height: int = world.resource.height

	var rig: CameraRig = CameraRig.new()
	rig.setup(width, height, heights,
		DictRead.as_int(DictRead.as_dict(
			DictRead.as_dict(loaded["document"])["header"])["camera_height"]))
	rig.set_zoom(8.0)

	var tested: int = 0
	var refused: int = 0
	var allowed_but_outside: int = 0
	var crowded: int = 0
	var opened_outside: int = 0
	for y: int in range(height):
		for x: int in range(width):
			rig.focus_on(x, y, heights[y * width + x])
			var fits: bool = false
			for step: int in range(4):
				if rig.eye_is_inside(step, 8.0):
					fits = true
			if not fits:
				crowded += 1
			for step: int in range(4):
				tested += 1
				if not rig.may_rotate_to(step):
					refused += 1
				elif not rig.eye_is_inside(step, 8.0) and fits:
					allowed_but_outside += 1
			rig.choose_yaw()
			if fits and not rig.eye_is_inside(rig.yaw_step(), 8.0):
				opened_outside += 1

	h.check("bounds.tested", tested == width * height * 4,
		"%d pivot and yaw combinations" % tested)
	h.equal("bounds.no_rotation_leaves_the_level", allowed_but_outside, 0,
		"every accepted turn ends with the eye inside")
	var note: String = "%d of %d turns refused; %d fields where no yaw fits" \
		% [refused, tested, crowded]
	h.check("bounds.the_guard_bites", refused > 0, note)
	h.equal("bounds.opening_yaw_fits", opened_outside, 0,
		"the one place the rig turns by itself lands inside")
	rig.free()
	_rotation_honours_the_guard(h, world, heights, width, height)


## [method CameraRig.rotate_step] actually obeys [method CameraRig.may_rotate_to].
##
## Checking the predicate alone leaves the *wiring* untested, and a mutation
## proved it: deleting the guard from `rotate_step` left every other check in
## this suite green. So this drives the real method -- which needs a tween, and
## so a scene tree -- and watches [method CameraRig.yaw_step].
func _rotation_honours_the_guard(h: TestHarness, world: World,
		heights: PackedInt32Array, width: int, height: int) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		h.check("bounds.tree", false, "no scene tree to hold the rig")
		return
	var rig: CameraRig = CameraRig.new()
	tree.root.add_child(rig)
	rig.setup(width, height, heights, 12800)
	rig.set_zoom(8.0)

	var obeyed: int = 0
	var disobeyed: int = 0
	var refusals: int = 0
	for y: int in range(height):
		for x: int in range(width):
			rig.focus_on(x, y, heights[y * width + x])
			for direction: int in [1, -1]:
				var before: int = rig.yaw_step()
				var wanted: int = posmod(before + direction, 4)
				var allowed: bool = rig.may_rotate_to(wanted)
				rig.rotate_step(direction)
				var moved: bool = rig.yaw_step() != before
				if allowed == moved:
					obeyed += 1
				else:
					disobeyed += 1
				if not allowed:
					refusals += 1
	tree.root.remove_child(rig)
	rig.free()
	h.equal("bounds.rotate_step_obeys_the_guard", disobeyed, 0,
		"%d turns, and the ones the guard refused did not happen" % obeyed)
	h.check("bounds.refusals_were_exercised", refusals > 0,
		"%d refusals actually reached rotate_step" % refusals)
	_crowded_and_zoom(h)


## The two rules no shipped mission reaches, on a map built to reach them.
##
## Both survived the mutation battery -- not because they are wrong but because
## nothing exercised them, which for a check is the same thing. On `_C_140`
## neither can fire: a field near a corner fails for one yaw and the **opposite**
## yaw always fits, so no field is ever crowded, and the eye never leaves the
## level on the next zoom step either.
##
## So they are exercised on a synthetic map, and this comment is here so that
## nobody reads the corpus checks above as covering them:
##
## * **the crowded-pivot escape hatch.** When no yaw would keep the eye inside,
##   refusing every direction traps the player, so every turn is allowed. A
##   pivot ringed by 100 m walls is such a field.
## * **the zoom guard.** Zooming out is refused on the same terms as a turn,
##   and zooming in is always allowed -- it can only bring the eye nearer a
##   pivot that is on the map by definition. A narrow map gives a pivot whose
##   eye leaves sideways while another yaw still fits, which is what makes the
##   guard bite rather than the escape hatch.
func _crowded_and_zoom(h: TestHarness) -> void:
	# Ringed by walls: the pivot is the one field at ground level.
	var walls: PackedInt32Array = PackedInt32Array()
	walls.resize(9)
	walls.fill(100 * 1600)
	walls[4] = 0
	var boxed: CameraRig = CameraRig.new()
	boxed.setup(3, 3, walls, 32000)
	boxed.set_zoom(8.0)
	boxed.focus_on(1, 1, 0)
	var fits: bool = false
	for step: int in range(4):
		if boxed.eye_is_inside(step, 8.0):
			fits = true
	h.check("bounds.crowded_field_built", not fits,
		"a pivot ringed by 100 m walls: no yaw keeps the eye inside")
	var all_allowed: bool = true
	for step: int in range(4):
		if not boxed.may_rotate_to(step):
			all_allowed = false
	h.check("bounds.crowded_never_traps", all_allowed,
		"where nothing fits, every turn is allowed rather than none")
	boxed.free()

	# A wall on one side only, so that one yaw is refused while another fits --
	# which is what makes the *guard* bite rather than the escape hatch. The
	# map edge cannot serve here: [constant CameraRig.MIN_ZOOM] is 4 m, and at
	# 4 m the eye is already past the edge of any map small enough to reach.
	var slab: PackedInt32Array = PackedInt32Array()
	slab.resize(9 * 9)
	slab.fill(0)
	for cell: int in range(81):
		if cell % 9 >= 6:
			slab[cell] = 100 * 1600
	var narrow: CameraRig = CameraRig.new()
	narrow.setup(9, 9, slab, 32000)
	narrow.focus_on(4, 4, 0)
	var refused_at: int = -1
	for step: int in range(4):
		narrow.set_zoom(CameraRig.MIN_ZOOM)
		if not narrow.eye_is_inside(step, CameraRig.MIN_ZOOM):
			continue
		if narrow.eye_is_inside(step,
				CameraRig.MIN_ZOOM * CameraRig.ZOOM_STEP):
			continue
		refused_at = step
		break
	h.check("bounds.zoom_guard_reachable", refused_at >= 0,
		"a yaw whose next zoom step leaves the map")
	if refused_at >= 0:
		narrow.rotation.y = CameraRig.step_angle(refused_at)
		while narrow.yaw_step() != refused_at:
			narrow.rotate_step(1)
		narrow.set_zoom(CameraRig.MIN_ZOOM)
		var before: float = DictRead.as_float(narrow.state()["zoom"])
		narrow.zoom_by(1.0)
		h.equal("bounds.zoom_out_refused",
			DictRead.as_float(narrow.state()["zoom"]), before,
			"a step that would leave the level does not happen")
		# Zooming in from the floor cannot go lower, so the "in is always
		# allowed" half is checked from a wider setting.
		narrow.set_zoom(CameraRig.MIN_ZOOM * 2.0)
		var wide: float = DictRead.as_float(narrow.state()["zoom"])
		narrow.zoom_by(-1.0)
		h.check("bounds.zoom_in_allowed",
			DictRead.as_float(narrow.state()["zoom"]) < wide,
			"zooming in is never refused")
	narrow.free()
