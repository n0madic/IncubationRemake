class_name CameraRig
extends Node3D

## The original's framing (docs/92 section 7.5): a pivot at the map's centre,
## yaw snapped to four ninety-degree steps with a short tween, a fixed pitch,
## and free zoom.
##
## The zoom's far limit is the mission's own `camera_height` -- 40 m for the
## slice's lead mission, 12 m for `_C_141` -- because that is the number the
## editor's dialog edits, and it is **not arbitrary**: raising it to frame the
## whole map puts the camera above the ceiling of an interior level, which is
## presumably why the authors set it low there. The view opens at that limit.
##
## Camera state is saved beside the simulation and **excluded** from its hash.

const PITCH_DEGREES: float = -48.0
const MIN_ZOOM: float = 4.0
const YAW_STEP_DEGREES: float = 90.0
const TWEEN_SECONDS: float = 0.18
const ZOOM_STEP: float = 1.15

var max_zoom: float = 40.0

var _camera: Camera3D = null
var _yaw_step: int = 0
var _zoom: float = 20.0
var _tween: Tween = null


func setup(map_width: int, map_height: int, heights: PackedInt32Array,
		camera_height: int) -> void:
	# The height of the cell the pivot actually sits on.  `heights.size() / 2`
	# is the middle row's **left edge**, not the centre, and on a map whose
	# terrain slopes east-west that is a different height entirely.
	var cx: int = map_width / 2
	var cy: int = map_height / 2
	var mid_h: int = 0
	var centre: int = cy * map_width + cx
	if centre >= 0 and centre < heights.size():
		mid_h = heights[centre]
	position = WorldSpace.cell_centre(cx, cy, mid_h)
	var authored: float = float(camera_height) / WorldSpace.WORLD_UNITS_PER_METRE
	max_zoom = maxf(MIN_ZOOM + 1.0, authored)
	# Open as far out as the mission allows, which is as much of it as the
	# original was willing to show at once.
	_zoom = max_zoom
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_apply()


func camera() -> Camera3D:
	return _camera


## Move the pivot onto one map field, keeping the yaw and the zoom.
func focus_on(x: int, y: int, h: int) -> void:
	position = WorldSpace.cell_centre(x, y, h)


func set_zoom(metres: float) -> void:
	_zoom = clampf(metres, MIN_ZOOM, max_zoom)
	_apply()


## One ninety-degree step, always the short way round.
##
## `_yaw_step` counts modulo four, and tweening straight to
## `_yaw_step * 90` unwinds the whole circle whenever that counter wraps: from
## 270 degrees the next step targets 0, so the camera spins 270 degrees
## backwards instead of 90 forwards. The angle is therefore chosen as the
## representative of the target that is nearest the camera's **current**
## heading. For a single step "nearest" and "the direction asked for" are the
## same thing, and it self-corrects if a previous tween was killed part-way.
func rotate_step(direction: int) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_yaw_step = posmod(_yaw_step + direction, 4)

	# Wrapping the current angle first keeps `rotation.y` inside one turn, so
	# it cannot drift into the range where a 32-bit float loses the precision
	# a ninety-degree step needs.
	var from: float = wrapf(rotation.y, 0.0, TAU)
	rotation.y = from
	var target: float = short_way(from, _yaw_step)

	_tween = create_tween()
	var _step: PropertyTweener = _tween.tween_property(self, "rotation:y",
		target, TWEEN_SECONDS)


static func step_angle(step: int) -> float:
	return deg_to_rad(float(step) * YAW_STEP_DEGREES)


## The angle to tween to: the representative of `step`'s angle nearest `from`.
##
## Pure, and separate from [method rotate_step], because a tween needs a node
## in the scene tree and this is the part worth a test.
static func short_way(from: float, step: int) -> float:
	var target: float = step_angle(step)
	while target - from > PI:
		target -= TAU
	while from - target > PI:
		target += TAU
	return target


## The step the camera is actually resting on, for tests and for the save.
func yaw_step() -> int:
	return _yaw_step


func zoom_by(steps: float) -> void:
	_zoom = clampf(_zoom * pow(ZOOM_STEP, steps), MIN_ZOOM, max_zoom)
	_apply()


func state() -> Dictionary:
	return {"yaw_step": _yaw_step, "zoom": _zoom,
		"pivot": [position.x, position.y, position.z]}


func apply_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	_yaw_step = DictRead.as_int(data.get("yaw_step", 0))
	_zoom = clampf(DictRead.as_float(data.get("zoom", _zoom)), MIN_ZOOM,
		max_zoom)
	rotation.y = step_angle(_yaw_step)
	_apply()


func _apply() -> void:
	if _camera == null:
		return
	_camera.rotation = Vector3(deg_to_rad(PITCH_DEGREES), 0.0, 0.0)
	_camera.position = Vector3(0.0, 0.0, 0.0)
	_camera.position = Vector3(0.0, -sin(deg_to_rad(PITCH_DEGREES)) * _zoom,
		cos(deg_to_rad(PITCH_DEGREES)) * _zoom)
