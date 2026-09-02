class_name CameraRig
extends Node3D

## The mission camera, on the engine's own state: an **eye** and a **target**
## in engine units (docs/42 section 2.1, `0x004FA430` and `0x004FA43C`), and
## the flight that moves them (section 2.2). Every move of the view goes
## through [method fly], which is `0x0040EEE0` transcribed: the six deltas
## eased by thirds or sixths in integer arithmetic, one step per frame at the
## gameplay rate, stopped when every delta is within 30 units, and skipped
## outright when the eye's height would change by more than 20 m.
##
## **Model A** (docs/92 section 7.5, as corrected on 2026-09-02): the tactical
## view keeps a discrete orientation and adds everything else the engine does.
## The orientation is the engine's own view quadrant `0x00510700` -- one of the
## four corners of the `(dist + 6) x dist` rectangle `0x004529D0` places the
## eye on -- so a quarter turn on Q or E is a step round that rectangle, not a
## free rotation, and the only rotations the eye ever makes are the ones the
## engine makes: the quadrant table, a unit's facing (mode 1, behind the
## unit), and the free-position search's own +-51 units a try. The right-drag
## free rotation of section 2.5 is the one thing left out, by decision.
##
## Two views are **not** tactical and take the unit's facing directly: the
## eyes view of section 2.4 and the ride of section 3.2. The rule about
## composed faces is about looking at the map, not out of a unit's head.
##
## Everything here is a picture. The rig never reads a node back into the
## simulation and nothing in it reaches the canonical hash; its state is saved
## beside the simulation and excluded from the hash.

## The gameplay frame the flight steps at (docs/92 section 7.10).
const FRAMES_PER_SECOND: float = 20.0
## docs/42 section 2.2 -- stop when every one of the six deltas is this close.
const FLIGHT_STOP: int = 30
## -- fast (thirds) when any delta starts at least this far away, else sixths.
const FLIGHT_FAST: int = 500
const FLIGHT_FAST_DIVISOR: int = 3
const FLIGHT_SLOW_DIVISOR: int = 6
## -- a height change past 20 m is set at once rather than flown.
const FLIGHT_SNAP_HEIGHT: int = 0x7D00
## A bound on [method settle]: a flight that has not stopped after this many
## steps is stopped, which no shipped map can reach (a 200 m delta stops in
## under thirty).
const SETTLE_LIMIT: int = 256
## A height no field has, for "off the map".
const INF_HEIGHT: int = 0x7FFFFFFF

## docs/42 section 2.3, `0x004529D0`: the quadrant offsets are
## `(dist + 6) * 1600` along x and `dist * 1600` along y, and the height is
## `(height + 3) * 1600` above the unit's head. Mode 1 adds one field behind
## an axis-aligned facing.
const QUADRANT_LONG_EXTRA: int = 6
const QUADRANT_HEIGHT_EXTRA: int = 3
const AXIS_EXTRA: int = 0xC80
## Mode 0's raise: when either horizontal offset is under 9600 the height is
## changed by `|dx| - 12800`.
const NEAR_AXIS: int = 0x2580
const NEAR_LIFT: int = 0x3200
## The sign pairs of the four quadrants, in the jump table's order.
const QUADRANT_SIGNS: Array[Vector2i] = [Vector2i(1, 1), Vector2i(1, -1),
	Vector2i(-1, -1), Vector2i(-1, 1)]

## `0x00453510`, the free-position search: up to 70 tries, each rotating the
## offset by `+-51 * n` angle units alternately, until the line to the target
## and to the target 1.5 m higher is clear.
const SEARCH_TRIES: int = 70
const SEARCH_STEP: int = 51
const SEARCH_LOOK_UP: int = 0x960

## `0x00453320`: the box every computed position is clamped into is 800 units
## in from the map's origin, one field in from its far edges, and the header's
## camera height in z.
const BOX_MARGIN: int = 800

## Section 2.4 -- the eyes view and the map view.
const EYES_FORWARD: int = 800
const EYES_UP: int = 0x280
const EYES_LOOK_AHEAD: int = 0x640
const EYES_LOOK_DOWN: int = 0x140
const MAP_VIEW_HEIGHT: int = 24000
const MAP_VIEW_AHEAD: int = 0xC80

## Section 2.5 -- the middle-drag pan is `0x004037D0` by `(mouse delta) * 40`
## along the view's forward and right, where the forward is the vector
## `(0, -10, 0)` turned by the camera's angles (`0x00451000` writes it) -- so
## one pixel is 400 units at the original's 640-pixel width.
const PAN_UNITS_PER_PIXEL: int = 400
const PAN_REFERENCE_WIDTH: float = 640.0

## Section 3.2 -- a computer walker is re-placed when the camera is at or
## below this height.
const LOW_CAMERA: int = 0x3200

## The remake's zoom: the eye offset scaled by this per wheel notch, never
## nearer than [constant MIN_DISTANCE]. The engine's own height keys move by
## 2000 units; a scaled offset keeps the placement's proportions instead.
const ZOOM_STEP: float = 1.15
const MIN_DISTANCE: int = 6400

## The clear-line test samples the segment this often, a quarter field.
const LINE_SAMPLE: int = 800
## How far above the field under it the eye must stay -- an eye exactly on a
## surface still clips through it.
const GROUND_CLEARANCE: int = 960

## docs/42 section 2.1 -- the view mode `0x005106D8`.
enum View { SCRIPT = 0, EYES = 1, UNIT = 2, MAP = 4 }

## The engine's fixed-point geometry, for the search's rotation. Optional: a
## rig without it turns the offset in floating point, which the search only
## needs to within a fraction of a degree.
var eng3d: Eng3dGeometry = null

var _camera: Camera3D = null
var _eye: Vector3i = Vector3i.ZERO
var _target: Vector3i = Vector3i.ZERO
var _eye_goal: Vector3i = Vector3i.ZERO
var _target_goal: Vector3i = Vector3i.ZERO
var _flying: bool = false
var _fast: bool = false
var _carry: float = 0.0
var _quadrant: int = 0
var _view: View = View.UNIT
var _width: int = 0
var _height: int = 0
var _heights: PackedInt32Array = PackedInt32Array()
var _camera_height: int = 0
var _box_lo: Vector3i = Vector3i.ZERO
var _box_hi: Vector3i = Vector3i.ZERO


func setup(map_width: int, map_height: int, heights: PackedInt32Array,
		camera_height: int) -> void:
	_width = map_width
	_height = map_height
	_heights = heights.duplicate()
	_camera_height = camera_height
	# `0x00453320`: 800 in from the origin on every axis, a field in from the
	# far edges, and the header's own camera height (docs/10, world units) as
	# the ceiling. This clamp is the height cap that actually bites: the one
	# inside `0x004529D0` compares against the header value times 1600 and
	# can never be reached.
	_box_lo = Vector3i(BOX_MARGIN, BOX_MARGIN, BOX_MARGIN)
	_box_hi = Vector3i(map_width * WorldSpace.WORLD_UNITS_PER_FIELD
		- WorldSpace.WORLD_UNITS_PER_FIELD,
		map_height * WorldSpace.WORLD_UNITS_PER_FIELD
		- WorldSpace.WORLD_UNITS_PER_FIELD, camera_height)
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	# Somewhere to start: the middle cell from quadrant 0 at the "on the unit"
	# distance. Whoever loads the mission places it properly.
	var cx: int = map_width / 2
	var cy: int = map_height / 2
	var centre: Vector3i = cell_object(cx, cy, height_at(cx, cy))
	var goal: Dictionary = place_on_unit(centre, 0, Vector2i(0, 1), 8, 7, 0)
	set_now(DictRead.as_vector3i(goal["eye"]),
		DictRead.as_vector3i(goal["target"]))


func camera() -> Camera3D:
	return _camera


## The height of a map field, in world units, or zero off the map.
func height_at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= _width or y >= _height:
		return 0
	var index: int = y * _width + x
	if index < 0 or index >= _heights.size():
		return 0
	return _heights[index]


## Where the engine's placed object for a cell stands: the cell's centre at
## its height (`aGetSymbolObjectPtr`'s `+0x10/14/18`).
static func cell_object(x: int, y: int, h: int) -> Vector3i:
	return Vector3i(x * WorldSpace.WORLD_UNITS_PER_FIELD,
		y * WorldSpace.WORLD_UNITS_PER_FIELD, h)


# --- the six numbers ---------------------------------------------------------

func eye() -> Vector3i:
	return _eye


func target() -> Vector3i:
	return _target


func eye_goal() -> Vector3i:
	return _eye_goal


func target_goal() -> Vector3i:
	return _target_goal


func is_flying() -> bool:
	return _flying


func quadrant() -> int:
	return _quadrant


func view_mode() -> View:
	return _view


func set_view_mode(mode: View) -> void:
	_view = mode


## `0x00403560` -- set the eye and the target at once, no flight.
func set_now(eye_at: Vector3i, target_at: Vector3i) -> void:
	_eye = eye_at
	_target = target_at
	_eye_goal = eye_at
	_target_goal = target_at
	_flying = false
	_apply()


## The walk's tracking (docs/42 section 3.2): the target is set and the eye
## is kept, every frame, with no flight. A flight in progress keeps flying its
## eye; its target half is overridden.
func set_target_now(target_at: Vector3i) -> void:
	_target = target_at
	_target_goal = target_at
	if _flying and _deltas_stopped():
		_flying = false
	_apply()


## `0x0040EEE0` -- start a flight to `(eye_at, target_at)`.
##
## Returns how many frames it will take, so a caller that has to wait for the
## camera -- every animation driver in the original does, because the flight
## blocks -- can hold for exactly that long.
func fly(eye_at: Vector3i, target_at: Vector3i) -> int:
	if absi(eye_at.z - _eye.z) > FLIGHT_SNAP_HEIGHT:
		set_now(eye_at, target_at)
		return 0
	var frames: int = flight_frames(_eye, _target, eye_at, target_at)
	_eye_goal = eye_at
	_target_goal = target_at
	_fast = _is_fast(_eye, _target, eye_at, target_at)
	_flying = not _deltas_stopped()
	_carry = 0.0
	return frames


## The flight's length in frames, as a function of its arguments: the same
## loop [method advance] runs, simulated to its stop.
static func flight_frames(eye_from: Vector3i, target_from: Vector3i,
		eye_to: Vector3i, target_to: Vector3i) -> int:
	if absi(eye_to.z - eye_from.z) > FLIGHT_SNAP_HEIGHT:
		return 0
	var fast: bool = _is_fast(eye_from, target_from, eye_to, target_to)
	var eye_at: Vector3i = eye_from
	var target_at: Vector3i = target_from
	var frames: int = 0
	while frames < SETTLE_LIMIT:
		if _stopped(eye_at, target_at, eye_to, target_to):
			break
		eye_at = flight_step(eye_at, eye_to, fast)
		target_at = flight_step(target_at, target_to, fast)
		frames += 1
	return frames


## One component's step: a third or a sixth of what is left, truncating
## toward zero like the compiler's signed division by magic number does.
static func flight_step(at: Vector3i, goal: Vector3i, fast: bool) -> Vector3i:
	var divisor: int = FLIGHT_FAST_DIVISOR if fast else FLIGHT_SLOW_DIVISOR
	return Vector3i(at.x + IncInt.div_trunc(goal.x - at.x, divisor),
		at.y + IncInt.div_trunc(goal.y - at.y, divisor),
		at.z + IncInt.div_trunc(goal.z - at.z, divisor))


static func _is_fast(eye_from: Vector3i, target_from: Vector3i,
		eye_to: Vector3i, target_to: Vector3i) -> bool:
	return _largest(eye_from, target_from, eye_to, target_to) >= FLIGHT_FAST


static func _stopped(eye_at: Vector3i, target_at: Vector3i, eye_to: Vector3i,
		target_to: Vector3i) -> bool:
	return _largest(eye_at, target_at, eye_to, target_to) <= FLIGHT_STOP


static func _largest(eye_at: Vector3i, target_at: Vector3i, eye_to: Vector3i,
		target_to: Vector3i) -> int:
	var d: Vector3i = (eye_to - eye_at).abs()
	var t: Vector3i = (target_to - target_at).abs()
	return maxi(maxi(maxi(d.x, d.y), d.z), maxi(maxi(t.x, t.y), t.z))


func _deltas_stopped() -> bool:
	return _stopped(_eye, _target, _eye_goal, _target_goal)


## Drive from `_process`. Steps the flight at the gameplay frame rate with the
## remainder carried, like the effects. Returns true while still flying.
func advance(delta: float) -> bool:
	if not _flying:
		return false
	_carry += delta * FRAMES_PER_SECOND
	while _flying and _carry >= 1.0:
		_carry -= 1.0
		_step()
	_apply()
	return _flying


func _step() -> void:
	if _deltas_stopped():
		_flying = false
		return
	_eye = flight_step(_eye, _eye_goal, _fast)
	_target = flight_step(_target, _target_goal, _fast)
	# The engine tests at the top of its loop; testing after the move as well
	# means a frame is never spent finding out that the last one was the last.
	if _deltas_stopped():
		_flying = false


## Finish the flight now: where it would have stopped, not the goal -- the
## engine's loop leaves up to 30 units either side, and a skipped replay lands
## where the last frame would have.
func settle() -> void:
	var steps: int = 0
	while _flying and steps < SETTLE_LIMIT:
		_step()
		steps += 1
	_flying = false
	_carry = 0.0
	_apply()


# --- the player's own moves --------------------------------------------------

## Move the target onto a map field, keeping the eye's offset from it.
##
## The remake's selection and hand-back: the engine's select path is not
## traced and its hand-over calls no camera routine (docs/42 section 2.6), so
## this is a pivot move with nothing else changed -- the player's arrangement
## survives -- done as a flight rather than the snap it used to be. Returns
## the flight's frames.
func focus_on(x: int, y: int, h: int) -> int:
	var to: Vector3i = cell_object(x, y, h)
	return fly(to + (_eye_goal - _target_goal), to)


## A step round the quadrant rectangle: the next sign pair of
## [constant QUADRANT_SIGNS] applied to the current offset's magnitudes.
##
## **Refused, not shortened** (docs/92 section 7.5.2): a turn whose eye would
## end under the map's own heights does not happen, unless no quadrant fits
## at all -- refusing every direction there would trap the player for no gain.
func rotate_step(direction: int) -> void:
	var wanted: int = posmod(_quadrant + direction, QUADRANT_SIGNS.size())
	if not may_rotate_to(wanted):
		return
	_quadrant = wanted
	var _frames: int = fly(_target_goal + _offset_in_quadrant(wanted,
		_eye_goal - _target_goal), _target_goal)


## Whether a turn onto `wanted` is allowed, on the terms above.
func may_rotate_to(wanted: int) -> bool:
	var offset: Vector3i = _eye_goal - _target_goal
	return eye_is_inside(_target_goal + _offset_in_quadrant(wanted, offset)) \
		or not _any_quadrant_fits(offset)


func _any_quadrant_fits(offset: Vector3i) -> bool:
	for q: int in range(QUADRANT_SIGNS.size()):
		if eye_is_inside(_target_goal + _offset_in_quadrant(q, offset)):
			return true
	return false


static func _offset_in_quadrant(q: int, offset: Vector3i) -> Vector3i:
	var signs: Vector2i = QUADRANT_SIGNS[posmod(q, QUADRANT_SIGNS.size())]
	return Vector3i(signs.x * absi(offset.x), signs.y * absi(offset.y),
		offset.z)


## Whether an eye would be inside the level: over a field that exists, and
## above it by [constant GROUND_CLEARANCE]. The map's own heights, not a
## collision mesh (docs/92 section 7.5.2).
func eye_is_inside(at: Vector3i) -> bool:
	if _heights.is_empty() or _width <= 0:
		return true
	var ground: int = _ground_under(at)
	if ground == INF_HEIGHT:
		return false
	return at.z - ground >= GROUND_CLEARANCE


func _ground_under(at: Vector3i) -> int:
	var x: int = _field_of(at.x)
	var y: int = _field_of(at.y)
	if x < 0 or y < 0 or x >= _width or y >= _height:
		return INF_HEIGHT
	var index: int = y * _width + x
	if index < 0 or index >= _heights.size():
		return INF_HEIGHT
	return _heights[index]


## The field a world coordinate lies on: the nearest centre, as the engine's
## own `(v + 1600) / 3200` in `0x00453730` has it.
static func _field_of(v: int) -> int:
	return IncInt.div_trunc(v + WorldSpace.WORLD_UNITS_PER_FIELD / 2,
		WorldSpace.WORLD_UNITS_PER_FIELD) if v >= 0 else -1


## The remake's zoom: scale the offset. In is always allowed down to
## [constant MIN_DISTANCE]; out is refused on the same terms as a turn, and
## when the scaled eye would leave the box.
##
## **Applied at once, like the pan.** The zoom is the remake's own input and
## not one of the engine's camera moves, so it does not go through
## [method fly]: that loop steps at 20 frames a second and takes a sixth of
## the remainder per frame, which turned a wheel notch into a lagging,
## stepped approach (it did, for one revision).
func zoom_by(steps: float) -> void:
	var offset: Vector3i = _eye_goal - _target_goal
	var factor: float = pow(ZOOM_STEP, steps)
	var length: float = Vector3(offset).length()
	if length * factor < float(MIN_DISTANCE):
		factor = float(MIN_DISTANCE) / maxf(length, 1.0)
	if factor <= 1.0 and length <= float(MIN_DISTANCE):
		return
	var scaled: Vector3i = Vector3i((Vector3(offset) * factor).round())
	var wanted: Vector3i = _target_goal + scaled
	if factor > 1.0:
		if clamp_box(wanted) != wanted:
			return
		if not eye_is_inside(wanted) and _any_quadrant_fits(scaled):
			return
	set_now(wanted, _target_goal)


## Section 2.5's pan, at once: eye and target together along the view's
## forward and right, by `pixels * 400` units scaled to the original's width.
## Refused when the target would leave the map's box.
func pan(pixels: Vector2, viewport_width: float) -> void:
	var scale: float = PAN_REFERENCE_WIDTH / maxf(viewport_width, 1.0)
	var offset: Vector3i = _eye_goal - _target_goal
	var forward: Vector2 = Vector2(-float(offset.x), -float(offset.y))
	if forward.length_squared() < 1.0:
		forward = Vector2(0.0, 1.0)
	forward = forward.normalized()
	var right: Vector2 = Vector2(forward.y, -forward.x)
	var move: Vector2 = (right * pixels.x - forward * pixels.y) \
		* float(PAN_UNITS_PER_PIXEL) * scale
	var shift: Vector3i = Vector3i(roundi(move.x), roundi(move.y), 0)
	var target_at: Vector3i = _target_goal + shift
	# The engine's pan is not clamped at all; refusing a target off the map is
	# the remake's, on the same terms as a turn. Only the map's extent counts:
	# a target on the floor of a cell is under the box's 800-unit z floor.
	var boxed: Vector3i = clamp_box(target_at)
	if boxed.x != target_at.x or boxed.y != target_at.y:
		return
	set_now(_eye_goal + shift, target_at)


# --- the engine's placements -------------------------------------------------

## `0x004529D0(x, y, dist, height, mode)`, as a function of what it reads:
## the placed object's position, the type's height (`0x0047AD70`), the
## facing's gradient (`0x0047ABD0`) and the view quadrant.
##
## Mode 1 puts the eye behind the unit along its facing, `dist` metres back
## and `height` metres above its head, one field further back when the facing
## is axis-aligned. Mode 0 puts it on the current quadrant's corner of the
## `(dist + 6) x dist` rectangle, `(height + 3)` metres up, clamps it into the
## box and applies the near-axis raise. Both then run the free-position
## search. The flight's target is the object plus the unit's height; the
## search looks at the object plus one metre.
##
## Returns `{"eye": Vector3i, "target": Vector3i}` **without flying**, so the
## arithmetic can be checked on its own; [method place] flies it.
func place_on_unit(obj: Vector3i, unit_height: int, gradient: Vector2i,
		dist: int, height: int, mode: int) -> Dictionary:
	var target_at: Vector3i = Vector3i(obj.x, obj.y, obj.z + unit_height)
	var eye_at: Vector3i = Vector3i.ZERO
	var metre: int = int(WorldSpace.WORLD_UNITS_PER_METRE)
	if mode == 1:
		var extra: Vector2i = Vector2i.ZERO
		if gradient.x == 0 or gradient.y == 0:
			extra = gradient * AXIS_EXTRA
		eye_at = Vector3i(obj.x - gradient.x * dist * metre - extra.x,
			obj.y - gradient.y * dist * metre - extra.y,
			obj.z + unit_height + height * metre)
	else:
		var signs: Vector2i = QUADRANT_SIGNS[posmod(_quadrant,
			QUADRANT_SIGNS.size())]
		eye_at = Vector3i(obj.x + signs.x * (dist + QUADRANT_LONG_EXTRA) * metre,
			obj.y + signs.y * dist * metre,
			obj.z + unit_height + (height + QUADRANT_HEIGHT_EXTRA) * metre)
		eye_at = clamp_box(eye_at)
		var dx: int = absi(eye_at.x - obj.x)
		var dy: int = absi(eye_at.y - obj.y)
		if dx < NEAR_AXIS or dy < NEAR_AXIS:
			eye_at.z += dx - NEAR_LIFT
	eye_at = free_position(eye_at, Vector3i(obj.x, obj.y, obj.z + metre))
	return {"eye": eye_at, "target": target_at}


## [method place_on_unit], flown. Returns the flight's frames.
func place(obj: Vector3i, unit_height: int, gradient: Vector2i, dist: int,
		height: int, mode: int) -> int:
	var goal: Dictionary = place_on_unit(obj, unit_height, gradient, dist,
		height, mode)
	return fly(DictRead.as_vector3i(goal["eye"]),
		DictRead.as_vector3i(goal["target"]))


## `0x00453510` -- rotate the eye about the look point until the lines to it
## and to 1.5 m above it are clear, up to 70 tries of `+-51 * n` alternating.
## Every try is clamped into the box; an eye that never clears is left as it
## was, which is what the engine does too.
func free_position(eye_at: Vector3i, look: Vector3i) -> Vector3i:
	var at: Vector3i = eye_at
	var sign: int = 1
	for n: int in range(1, SEARCH_TRIES + 1):
		if line_is_clear(at, look) and line_is_clear(at,
				look + Vector3i(0, 0, SEARCH_LOOK_UP)):
			return at
		var offset: Vector3i = at - look
		at = look + _turned(offset, sign * n * SEARCH_STEP)
		at = clamp_box(at)
		sign = -sign
	return eye_at


## `0x004039A0` on `(0, 0, angle)`: the offset turned about the vertical.
func _turned(offset: Vector3i, angle: int) -> Vector3i:
	if eng3d != null and eng3d.is_loaded():
		return eng3d.rotate(offset, Vector3i(0, 0, angle))
	var turn: float = float(angle) / float(WorldSpace.ANGLE_FULL_TURN) * TAU
	var flat: Vector2 = Vector2(float(offset.x), float(offset.y)).rotated(turn)
	return Vector3i(roundi(flat.x), roundi(flat.y), offset.z)


## `0x00453420` -- the box.
func clamp_box(at: Vector3i) -> Vector3i:
	return Vector3i(clampi(at.x, _box_lo.x, _box_hi.x),
		clampi(at.y, _box_lo.y, _box_hi.y),
		clampi(at.z, _box_lo.z, _box_hi.z))


## Whether a segment crosses the map's own heights.
##
## The engine walks the special-object and clone arrays with a line-box test
## (`0x00453490`); the remake tests the segment against the cell heights, the
## same data every other guard here reads, a quarter field at a time, both
## ends included. A roof that is scenery and not a height is therefore not an
## obstacle to this test, exactly as it is not to [method eye_is_inside].
func line_is_clear(from: Vector3i, to: Vector3i) -> bool:
	if _heights.is_empty():
		return true
	var span: Vector3 = Vector3(to - from)
	var length: float = Vector2(span.x, span.y).length()
	var samples: int = maxi(int(length / float(LINE_SAMPLE)), 1)
	for i: int in range(samples + 1):
		var t: float = float(i) / float(samples)
		var at: Vector3i = from + Vector3i((span * t).round())
		var ground: int = _ground_under(at)
		if ground == INF_HEIGHT or at.z <= ground:
			return false
	return true


## Section 2.4, view mode 1: from the unit's own eyes. Returns the frames.
func view_eyes(obj: Vector3i, unit_height: int, gradient: Vector2i) -> int:
	_view = View.EYES
	var eye_at: Vector3i = Vector3i(obj.x + gradient.x * EYES_FORWARD,
		obj.y + gradient.y * EYES_FORWARD, obj.z + unit_height + EYES_UP)
	var target_at: Vector3i = Vector3i(eye_at.x + gradient.x * EYES_LOOK_AHEAD,
		eye_at.y + gradient.y * EYES_LOOK_AHEAD, eye_at.z - EYES_LOOK_DOWN)
	return fly(eye_at, target_at)


## Section 2.4, view mode 4: 15 m above a cell's object, looking a field
## further along y. Returns the frames.
func view_map(obj: Vector3i) -> int:
	_view = View.MAP
	var at: Vector3i = clamp_box(obj)
	var target_at: Vector3i = Vector3i(at.x, at.y + MAP_VIEW_AHEAD, at.z)
	return fly(Vector3i(at.x, at.y, MAP_VIEW_HEIGHT), target_at)


## Section 3.2 -- the ride: the eye on the walker's head, the target on the
## walk's destination at the same height, no flight.
func ride(at: Vector3i, unit_height: int, destination: Vector3i) -> void:
	set_now(Vector3i(at.x, at.y, at.z + unit_height),
		Vector3i(destination.x, destination.y, destination.z + unit_height))


## Where a world point falls on the view: `{"visible": bool, "y": float}`,
## with `y` the fraction of the viewport height from the top. Behind the
## camera or without a viewport it is not visible.
func screen_position(point: Vector3i) -> Dictionary:
	if _camera == null or not _camera.is_inside_tree():
		return {"visible": false, "y": -1.0}
	var at: Vector3 = WorldSpace.to_godot(point.x, point.y, point.z)
	if _camera.is_position_behind(at):
		return {"visible": false, "y": -1.0}
	var size: Vector2 = _camera.get_viewport().get_visible_rect().size
	if size.y <= 0.0:
		return {"visible": false, "y": -1.0}
	var on: Vector2 = _camera.unproject_position(at)
	var fraction: float = on.y / size.y
	return {"visible": on.x >= 0.0 and on.x <= size.x and fraction >= 0.0
		and fraction <= 1.0, "y": fraction}


# --- persistence -------------------------------------------------------------

func state() -> Dictionary:
	return {"eye": [_eye_goal.x, _eye_goal.y, _eye_goal.z],
		"target": [_target_goal.x, _target_goal.y, _target_goal.z],
		"quadrant": _quadrant, "view": int(_view)}


func apply_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	_quadrant = posmod(DictRead.as_int(data.get("quadrant", 0)),
		QUADRANT_SIGNS.size())
	match DictRead.as_int(data.get("view", int(View.UNIT))):
		0:
			_view = View.SCRIPT
		1:
			_view = View.EYES
		4:
			_view = View.MAP
		_:
			_view = View.UNIT
	if data.has("eye") and data.has("target"):
		set_now(_triple(data["eye"], _eye_goal),
			_triple(data["target"], _target_goal))


static func _triple(value: Variant, fallback: Vector3i) -> Vector3i:
	var parts: Array = DictRead.as_array(value)
	if parts.size() != 3:
		return fallback
	return Vector3i(DictRead.as_int(parts[0]), DictRead.as_int(parts[1]),
		DictRead.as_int(parts[2]))


# --- the picture -------------------------------------------------------------

## The node sits on the target; the camera child looks at it from the eye.
func _apply() -> void:
	position = WorldSpace.to_godot(_target.x, _target.y, _target.z)
	if _camera == null:
		return
	var eye_at: Vector3 = WorldSpace.to_godot(_eye.x, _eye.y, _eye.z)
	var local: Vector3 = eye_at - position
	if local.length_squared() < 0.000001:
		local = Vector3(0.0, 0.0, 0.001)
	var forward: Vector3 = -local.normalized()
	var up: Vector3 = Vector3.UP
	if absf(forward.dot(up)) > 0.9999:
		up = Vector3.BACK
	_camera.transform = Transform3D(Basis.looking_at(forward, up), local)
