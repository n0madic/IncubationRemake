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
## **The camera is kept inside the level by refusing moves, not by shortening
## them.** The pivot sits on a map field and the eye is up and back from it, so
## at a wide zoom the eye left the map altogether or ended up inside a wall.
##
## The first fix pulled the eye in every frame until it was clear. It worked --
## and it was horrible to use: beside a wall the eye collapsed onto the unit's
## feet, and during a yaw tween the clearance changed every frame, so the view
## snapped back out to the ceiling the moment the wall passed. A continuous
## clamp on a discrete camera reads as the camera fighting you.
##
## So a move that would take the eye out of the level is **refused**. A
## rotation that would end outside simply does not happen, and neither does a
## zoom step; the view stays exactly where it was, which is a thing a player
## can understand and work with. The only place the rig chooses for itself is
## the opening yaw, where there is no previous view to keep.
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
	# The yaw is **not** re-chosen here. Following a unit must not spin the
	# view: a camera that turned by itself whenever the selection moved would
	# be worse than one that occasionally looks through a wall.
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
	var wanted: int = posmod(_yaw_step + direction, 4)
	if not may_rotate_to(wanted):
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_yaw_step = wanted

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
	var wanted: float = clampf(_zoom * pow(ZOOM_STEP, steps), MIN_ZOOM,
		max_zoom)
	# Zooming **in** is always allowed -- it can only bring the eye closer to a
	# pivot that is by definition on the map. Zooming out is refused when it
	# would leave the level, on the same terms as a rotation.
	if wanted > _zoom and not eye_is_inside(_yaw_step, wanted) \
			and _any_yaw_fits(wanted):
		return
	_zoom = wanted
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
	_camera.position = _eye_offset(_zoom)


## Where the eye sits relative to the pivot, at a given distance.
func _eye_offset(distance: float) -> Vector3:
	var pitch: float = deg_to_rad(PITCH_DEGREES)
	return Vector3(0.0, -sin(pitch) * distance, cos(pitch) * distance)


## Whether the eye would be inside the level for a given yaw step and distance.
##
## "Inside" is two things and both are the map's own: the field under the eye
## must exist, and it must be lower than the eye by [constant
## GROUND_CLEARANCE]. What is tested is where the eye **ends up** -- not the
## ground it passes over on the way. Testing the path refuses almost every view
## on an interior map, because these levels have columns and ceilings
## everywhere and the camera is meant to look past them.
func eye_is_inside(step: int, distance: float) -> bool:
	if _heights.is_empty() or _width <= 0:
		return true
	var eye: Vector3 = position + Basis(Vector3.UP, step_angle(step)) \
		* _eye_offset(distance)
	var ground: float = _ground_at(eye)
	return eye.y - ground >= GROUND_CLEARANCE


## Whether a quarter turn onto `step` is allowed.
##
## **Refused, not shortened.** If the turn would end with the eye outside the
## level it does not happen and the view stays where it is. The exception is a
## pivot where no yaw fits at all: refusing every direction there would trap
## the player for no gain.
##
## Separate from [method rotate_step] because that one needs a tween and so a
## scene tree, and this is the part worth a test.
func may_rotate_to(step: int) -> bool:
	return eye_is_inside(step, _zoom) or not _any_yaw_fits(_zoom)


## Whether **any** of the four yaw steps keeps the eye inside at `distance`.
##
## When none does, a refusal would only trap the player: there is no better
## view to protect, so the move is allowed and the level is simply crowded.
func _any_yaw_fits(distance: float) -> bool:
	for step: int in range(4):
		if eye_is_inside(step, distance):
			return true
	return false


## The yaw step to open on: the current one if it fits, else the nearest that
## does.
##
## This is the one place the rig picks for itself, and it is the one place with
## nothing to preserve -- at load there is no previous view. Everywhere else a
## bad move is refused rather than corrected, so the camera never turns on its
## own while the player is using it.
func choose_yaw() -> void:
	if eye_is_inside(_yaw_step, _zoom) or not _any_yaw_fits(_zoom):
		return
	for offset: int in [1, -1, 2]:
		var candidate: int = posmod(_yaw_step + offset, 4)
		if eye_is_inside(candidate, _zoom):
			_yaw_step = candidate
			rotation.y = step_angle(candidate)
			_apply()
			return


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
