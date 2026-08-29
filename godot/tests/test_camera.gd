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
