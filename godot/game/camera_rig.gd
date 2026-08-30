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
## **The camera is kept inside the level.** The pivot sits on a map field and
## the eye is up and back from it, so at a wide zoom the eye leaves the map
## altogether or ends up inside a wall -- on `_C_140` the middle of the map is
## a support column 16 m tall, and the opening view was a close-up of it seen
## through a ceiling. [method _reachable_zoom] walks the ground between the
## pivot and the eye and stops the eye short of anything it would be inside.
##
## The rule uses the map's **own cell heights**, which is the same data the
## simulation uses, rather than a physics body built from the scenery: the
## walls are in the map, `MapResource.heights()` already carries them, and a
## collision mesh for 1642 scenery instances would be a second, disagreeing
## description of the level.
##
## Camera state is saved beside the simulation and **excluded** from its hash.

const PITCH_DEGREES: float = -48.0
const MIN_ZOOM: float = 4.0
const YAW_STEP_DEGREES: float = 90.0
const TWEEN_SECONDS: float = 0.18
const ZOOM_STEP: float = 1.15

## How far above the ground the eye must stay, in metres. A camera exactly on
## a surface still clips through it.
const GROUND_CLEARANCE: float = 0.6
## How finely the ground between the pivot and the eye is sampled, in map
## fields. Half a field cannot step over a one-field wall.
const MARCH_STEP: float = 0.5
## The closest the eye may come to the pivot when the level crowds it out, in
## metres. Not [constant MIN_ZOOM]: see [method _reachable_zoom].
const COLLAPSE_FLOOR: float = 1.0
## The metre, and the field, from the map's own units.
const METRE: float = 1600.0
const FIELD_METRES: float = 2.0

var max_zoom: float = 40.0

var _camera: Camera3D = null
var _yaw_step: int = 0
var _zoom: float = 20.0
var _tween: Tween = null
var _width: int = 0
var _height: int = 0
var _heights: PackedInt32Array = PackedInt32Array()


func setup(map_width: int, map_height: int, heights: PackedInt32Array,
		camera_height: int) -> void:
	# The height of the cell the pivot actually sits on.  `heights.size() / 2`
	# is the middle row's **left edge**, not the centre, and on a map whose
	# terrain slopes east-west that is a different height entirely.
	_width = map_width
	_height = map_height
	_heights = heights.duplicate()
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
	# The clearance depends on where the pivot is, so it is recomputed here as
	# well as on a zoom: moving the pivot under a low ceiling has to pull the
	# eye in just as zooming out does.
	_apply()


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


## Re-clamp while the yaw tween runs.
##
## Rotating does not change [member _zoom], but it swings the eye over
## different ground -- which is how a quarter turn used to bury the camera in a
## wall that was not there before the turn. The march is a few dozen array
## reads, so it is affordable every frame; nothing else here is.
func _process(_delta: float) -> void:
	if _camera != null and not _heights.is_empty():
		_apply()


func _apply() -> void:
	if _camera == null:
		return
	_camera.rotation = Vector3(deg_to_rad(PITCH_DEGREES), 0.0, 0.0)
	var distance: float = _reachable_zoom(_zoom)
	_camera.position = Vector3(0.0, -sin(deg_to_rad(PITCH_DEGREES)) * distance,
		cos(deg_to_rad(PITCH_DEGREES)) * distance)


## The largest distance up to `wanted` at which the **eye itself** is still
## inside the level and above the ground.
##
## What is tested is where the eye ends up, not the ground it passes over. The
## first version tested the whole path and pulled the eye in whenever anything
## tall stood between it and the pivot -- which on an interior map is almost
## always, so the view collapsed onto the unit. These levels have columns and
## ceilings everywhere and the camera is *meant* to look past them; what it may
## not do is end up outside the level or under the floor, which is the thing
## that kept happening.
##
## Returning the *distance* rather than changing [member _zoom] is deliberate:
## the zoom the player chose is what a save round-trips and what
## [method state] reports. The clamp is where the eye ends up, not what was
## asked for, so backing out of a corner restores the view instead of having
## quietly lost it.
func _reachable_zoom(wanted: float) -> float:
	if _heights.is_empty() or _width <= 0:
		return wanted
	var pitch: float = deg_to_rad(PITCH_DEGREES)
	var back: float = cos(pitch)
	var rise: float = -sin(pitch)
	if back <= 0.0:
		return wanted
	# The rig's heading, projected onto the ground. **Local** basis, not
	# `global_transform`: the rig is placed in world coordinates under a scene
	# root that never moves, and `global_transform` is only valid once the node
	# is inside the tree -- which it is not during `setup`, nor in a test that
	# drives the rig on its own.
	var heading: Vector3 = (transform.basis * Vector3(0.0, 0.0, 1.0))
	heading.y = 0.0
	if heading.length() < 0.001:
		return wanted
	heading = heading.normalized()

	var step: float = MARCH_STEP * FIELD_METRES
	var distance: float = wanted
	while distance > COLLAPSE_FLOOR:
		var here: float = distance * back
		# Off the map, `_ground_at` answers `INF` and the clearance test below
		# fails on its own -- no separate guard, because a redundant one reads
		# as if it were carrying the case.
		var ground: float = _ground_at(position + heading * here)
		if position.y + here * (rise / back) - ground >= GROUND_CLEARANCE:
			return distance
		distance -= step / back
	return COLLAPSE_FLOOR


## The height of the map field under a world position, or `INF` off the map.
func _ground_at(at: Vector3) -> float:
	var x: int = roundi(at.x / FIELD_METRES)
	var y: int = roundi(-at.z / FIELD_METRES)
	if x < 0 or y < 0 or x >= _width or y >= _height:
		return INF
	var index: int = y * _width + x
	if index < 0 or index >= _heights.size():
		return INF
	return float(_heights[index]) / METRE
