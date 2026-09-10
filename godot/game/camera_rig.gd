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
## free rotation. Right-drag separately turns the view at the fixed eye,
## as section 2.5 does, without changing the placement quadrant.
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

## The campaign map's camera, **read out of the executable** rather than
## computed.
##
## `aMissionControl.cpp`'s screen entry `0x00453F80` writes six globals before
## anything else happens on that screen -- `0x00510BB8/BC/C0` the eye and
## `0x00510BC4/C8/CC` the target, as three `mov dword` immediates and one
## `mov eax, 0xDDE0` used twice -- and `0x00457695` hands all six to
## `aSetCameraPosition` `0x00403560` when the map is raised. Both chains share
## the target, while the current mission's location selects the authored eye;
## it is not a fit to whichever locations happen to be open.
##
## Those six writes are only the starting values. Immediately afterwards
## `0x004541D9` calls `0x0045D130(current location, &eye.x, &eye.y, &eye.z)`:
## the current location selects one of thirteen authored eyes, or the default
## arm. That missing second half left late campaign-2 locations below the
## frame until the player rotated the remake's map by hand.
##
## The target is field `(17.75, 17.75)` of a 40x40 map at height 0. The eyes
## are not clamped; several deliberately stand outside the map.
const CAMPAIGN_EYE_INITIAL: Vector3i = Vector3i(-19088, 98112, 9088)
const CAMPAIGN_EYE_DEFAULT: Vector3i = Vector3i(-19072, 98096, 9088)
const CAMPAIGN_EYE_PRESETS: Array[Vector3i] = [
	Vector3i(-19072, 98096, 19088),
	Vector3i(79968, 140032, 19088),
	Vector3i(15248, -18944, 18848),
	Vector3i(101984, -16800, 19184),
	Vector3i(-15072, 104672, 19200),
	Vector3i(14320, 132016, 18592),
	Vector3i(56912, 143168, 3984),
	Vector3i(73664, -27904, 19200),
	Vector3i(-21072, -21840, 19136),
	Vector3i(143104, 53360, 19200),
	Vector3i(121856, 0, 19200),
	Vector3i(74176, -27792, 19200),
	Vector3i(-3776, -4736, 14336),
]
const CAMPAIGN_TARGET: Vector3i = Vector3i(56800, 56800, 0)
## `0x004558F0` is what moves it: it turns the eye about the target by an
## angle it accumulates, and clamps the eye's height into this pair. The map's
## own frame callback calls it with zero deltas every frame, so the step
## decays and the selected preset is where it rests -- [method swing_map] is
## the whole routine.
const CAMPAIGN_HEIGHT_LOW: int = -0x2580
const CAMPAIGN_HEIGHT_HIGH: int = 0x4B00

## What a drag on the map asks for, per pixel of pointer movement:
## `0x0045558C`'s `shl eax, 1` on the horizontal delta, and `0x0045559A`'s
## `neg / shl 2 / sub / lea *5 / shl 1` -- which is -50 -- on the vertical.
##
## The horizontal one is in Eng3d's 4096ths, because the accumulator's low
## word is handed straight to `0x004039A0` as its **third** angle; the
## vertical one is in world units and is added to the eye's own height. So
## about 180 pixels of drag is a quarter turn, and one pixel raises the eye
## by 50.
const MAP_TURN_PER_PIXEL: int = 2
const MAP_RISE_PER_PIXEL: int = -50
## How much pointer travel a keypress stands in for. The original offers the
## map no key at all -- the drag is the whole of it -- so this is the remake's
## own, sized so that `Q` and `E` turn it at about the rate a comfortable drag
## does rather than at a mission's quarter-turn step.
const MAP_KEY_TURN: float = 6.0

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
## 0x00451000: both pointer deltas are multiplied by eight.
const LOOK_RADIANS_PER_PIXEL: float = TAU * 8.0 / 4096.0

## Section 2.4 -- view mode 0, the overview map: `fcn.004532A0` puts the eye
## at `0x23A50` over the **box's** own centre, looking straight down at it
## from a hundred units short on y (which is what gives the view its up).
const OVERVIEW_HEIGHT: int = 0x23A50
const OVERVIEW_LEAN: int = 100

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
## The campaign map's turn: `0x00510C50` the accumulated angle, `0x00510D28`
## the step it is growing by and `0x00510BC0` the eye's own height, which is
## the one coordinate the turn carries forward.
var _map_angle: int = 0
var _map_step: int = 0
var _map_eye: Vector3i = CAMPAIGN_EYE_DEFAULT
var _map_height: int = CAMPAIGN_EYE_DEFAULT.z
var _eye: Vector3i = Vector3i.ZERO
var _target: Vector3i = Vector3i.ZERO
var _eye_goal: Vector3i = Vector3i.ZERO
var _target_goal: Vector3i = Vector3i.ZERO
var _flying: bool = false
var _fast: bool = false
var _carry: float = 0.0
var _quadrant: int = 0
var _view: View = View.UNIT
## Yaw must survive the pitch poles, where an integer eye/target pair
## cannot encode it. Normal placements and tracking replace these angles.
var _free_looking: bool = false
var _look_angles: Vector2 = Vector2.ZERO
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


## The campaign map's own turn -- `0x004558F0`, in full.
##
## docs/27 section 2.6. Three things about it are worth stating, because two
## of them read backwards:
##
## **The eye it turns is the selected base eye.** `SetCameraPosition`
## `0x00403560` hands its arguments to Eng3d and writes none of the globals
## back, so the routine rotates the eye selected by [method campaign_eye] by the
## **accumulated** angle every frame rather than nudging where the eye already
## is. Reading it the other way makes the map spin away.
##
## **The step has inertia.** A request whose magnitude exceeds the current
## step replaces it; anything smaller **halves** the step instead, truncating
## toward zero. So the map keeps turning after the pointer stops and comes to
## rest in about ten frames, and the frame callback's own zero request is what
## drives that decay.
##
## **Only the height accumulates.** `0x00510BC0` is read, added to and written
## back inside the clamp; x and y are recomputed from the constants each time.
##
## Returns the eye to place, with the target unchanged.
func swing_map(turn: int, rise: int) -> Vector3i:
	if absi(turn) > absi(_map_step):
		_map_step = turn
	else:
		# `cdq / sub eax, edx / sar eax, 1` -- an arithmetic halving biased so
		# that it truncates toward zero rather than toward minus infinity.
		_map_step = int(float(_map_step) / 2.0)
	_map_angle = IncInt.i32(_map_angle + _map_step)
	_map_height = clampi(_map_height + rise, CAMPAIGN_HEIGHT_LOW,
		CAMPAIGN_HEIGHT_HIGH)
	var arm: Vector3i = Vector3i(_map_eye.x - CAMPAIGN_TARGET.x,
		_map_eye.y - CAMPAIGN_TARGET.y, 0)
	var turned: Vector3i = arm
	if eng3d != null:
		# The angles are `(0, 0, accumulator)` -- the low **word** of it, so
		# the accumulator wraps through the 4096-unit circle on its own.
		turned = eng3d.rotate(arm, Vector3i(0, 0, IncInt.u16(_map_angle)))
	return Vector3i(CAMPAIGN_TARGET.x + turned.x,
		CAMPAIGN_TARGET.y + turned.y, _map_height)


## Put the map's turn on the eye `0x0045D130` chooses for *location*.
## The helper and the screen entry zero the accumulator, and `0x00454203`
## zeroes the step.
func reset_map_swing(location: int) -> void:
	_map_eye = campaign_eye(location)
	_map_angle = 0
	_map_step = 0
	_map_height = _map_eye.z


## `0x0045D130`'s 71-byte selector table, expressed as its contiguous ranges.
## Locations outside 59..129, including campaign 1's opening locations and
## the unused 85..89 gap, take the function's default arm.
static func campaign_eye(location: int) -> Vector3i:
	if location >= 59 and location <= 65:
		return CAMPAIGN_EYE_PRESETS[0]
	if location >= 66 and location <= 69:
		return CAMPAIGN_EYE_PRESETS[1]
	if location == 70:
		return CAMPAIGN_EYE_PRESETS[2]
	if location >= 71 and location <= 76:
		return CAMPAIGN_EYE_PRESETS[3]
	if location >= 77 and location <= 80:
		return CAMPAIGN_EYE_PRESETS[4]
	if location >= 81 and location <= 83:
		return CAMPAIGN_EYE_PRESETS[5]
	if location == 84:
		return CAMPAIGN_EYE_PRESETS[6]
	if location >= 90 and location <= 96:
		return CAMPAIGN_EYE_PRESETS[7]
	if location >= 97 and location <= 100:
		return CAMPAIGN_EYE_PRESETS[8]
	if location >= 101 and location <= 104:
		return CAMPAIGN_EYE_PRESETS[9]
	if location >= 105 and location <= 115:
		return CAMPAIGN_EYE_PRESETS[10]
	if location >= 116 and location <= 119:
		return CAMPAIGN_EYE_PRESETS[11]
	if location >= 120 and location <= 129:
		return CAMPAIGN_EYE_PRESETS[12]
	return CAMPAIGN_EYE_DEFAULT


func map_angle() -> int:
	return _map_angle


func map_step() -> int:
	return _map_step


## Eng3d's own perspective, as `0x00403460` computes it.
##
## The engine's screen is set up by `_E3D_init_3d_screen` (`Eng3d.dll`
## ordinal 3), and the **focal length is the fifth argument**: the wrapper at
## `0x00403460` computes it from the window's width alone --
## `_ftol(width * 10 / 13)` through the double at `0x004B1010` -- and the DLL
## stores it at `0x414FE8` (whose own default is 256) beside its reciprocal at
## `0x414FF0`, which is the divide a projection is. So a point projects to
## `centre + coord * focal / depth`, and the constant is 10/13 rather than a
## field of view.
##
## The one thing that can change it is the zoom divisor `0x004FA500`: when it
## is non-zero the focal length is `width / divisor` instead. Five sites write
## it, with 0 and with 4, and none of them is on the mission or map path --
## the fours are in the dialogue screens -- so 10/13 is what a played game
## sees. The divisor is a parameter here rather than an assumption.
const FOCAL_NUMERATOR: float = 10.0
const FOCAL_DENOMINATOR: float = 13.0
## `[0x414FE8]`'s own initialiser inside `Eng3d.dll` -- what the projection
## would be if nothing set it. Nothing in a played game leaves it there; it is
## here so the check has the engine's own default to compare against.
const FOCAL_ENG3D_DEFAULT: float = 256.0


static func focal_length(window_width: float, zoom_divisor: int = 0) -> float:
	if zoom_divisor != 0:
		return floorf(window_width / float(zoom_divisor))
	return floorf(window_width * FOCAL_NUMERATOR / FOCAL_DENOMINATOR)


## Where the engine would put a camera-space point on the screen, in the
## render's own pixels: `window centre + coord * focal / depth`.
##
## *at* is in the camera's own space, x right, y up, **depth positive
## forward** -- which is Godot's `-z`. The answer is in the same top-left
## pixel space [method Camera3D.unproject_position] answers in, so the two can
## be compared directly, which is what pins the frustum below.
static func project(at: Vector3, window: Rect2, zoom_divisor: int = 0
		) -> Vector2:
	if at.z <= 0.0:
		return Vector2.ZERO
	var focal: float = focal_length(window.size.x, zoom_divisor)
	var centre: Vector2 = window.position + window.size * 0.5
	return Vector2(centre.x + at.x * focal / at.z,
		centre.y - at.y * focal / at.z)


## Give *camera* the engine's projection for a 3D window of *window* inside a
## render of *render* pixels.
##
## Two things are wrong with a plain [Camera3D] here and both are visible.
## Its default field of view is 75 degrees where the engine's works out at
## about 62, so everything was too small and too wide; and its principal
## point is the render's centre, `(320, 240)`, where the engine's is the
## **window's** -- `(324, 210)` for the campaign map, which is thirty pixels
## up. The 3D fills the whole render and the plate is drawn as four strips
## around the window ([CampaignScreen]), so the window's centre is not the
## render's and the difference does not cancel.
##
## A frustum projection carries both: the height gives the focal length and
## the offset moves the axis off the render's centre.
##
## *focal_width* names the window width the focal length is taken from when
## it is not *window*'s own: the battle interface widens its window with the
## canvas (docs/43 section 8) and keeps the original's 400, so a wider
## screen shows more world at the same scale rather than a larger picture.
static func frame_projection(camera: Camera3D, window: Rect2,
		render: Vector2, zoom_divisor: int = 0, focal_width: float = 0.0) -> void:
	if camera == null or render.x <= 0.0 or render.y <= 0.0:
		return
	frame_projection_focal(camera, window, render, focal_length(
		focal_width if focal_width > 0.0 else window.size.x, zoom_divisor))


## The same frustum for an explicit focal length in the window's pixels --
## what the sequence player's `Focus` notes hand it (docs/41 section 4).
static func frame_projection_focal(camera: Camera3D, window: Rect2,
		render: Vector2, focal: float) -> void:
	if camera == null or render.x <= 0.0 or render.y <= 0.0:
		return
	if focal <= 0.0:
		return
	# The frustum is stated at the near plane, so every length here is a
	# pixel count divided by the focal length and multiplied by `near`.
	var near: float = camera.near
	var height: float = render.y * near / focal
	# Where the engine's axis lands, as a fraction of the render's own half
	# extents: positive x right, positive y **up**, so the pixel delta in y
	# is negated once here and nowhere else.
	var centre: Vector2 = window.position + window.size * 0.5
	var axis: Vector2 = Vector2(centre.x - render.x * 0.5,
		render.y * 0.5 - centre.y)
	# Shifting the frustum by `+o` moves the image by `-o`, so the offset is
	# the axis's own displacement negated.
	camera.projection = Camera3D.PROJECTION_FRUSTUM
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.frustum_offset = Vector2(-axis.x * near / focal,
		-axis.y * near / focal)
	camera.size = height


## The world-space ray through a screen point, as `[origin, direction]`.
##
## Not [method Camera3D.project_ray_origin] and [method
## Camera3D.project_ray_normal]: for a frustum projection Godot builds the
## origin with the orthogonal formula and the normal from the near plane's
## half extents **without the frustum offset**, so with the axis 36 units
## above the render's centre ([method frame_projection]) the ray it answered
## landed about a cell away from the pixel it was asked about -- a unit
## clicked at its own cell was missed, and its neighbour taken. This inverts
## the camera's actual projection instead, so the ray through a pixel meets
## the point [method Camera3D.unproject_position] put there. *render* is the
## viewport's visible rectangle in the same units as *screen*.
static func ray_through(camera: Camera3D, screen: Vector2, render: Vector2
		) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	if camera == null or render.x <= 0.0 or render.y <= 0.0:
		return out
	var matrix: Projection = projection_of(camera, render)
	var inverse: Projection = matrix.inverse()
	var ndc: Vector2 = Vector2(screen.x / render.x * 2.0 - 1.0,
		1.0 - screen.y / render.y * 2.0)
	var near_clip: Vector4 = inverse * Vector4(ndc.x, ndc.y, -1.0, 1.0)
	var far_clip: Vector4 = inverse * Vector4(ndc.x, ndc.y, 1.0, 1.0)
	if is_zero_approx(near_clip.w) or is_zero_approx(far_clip.w):
		return out
	var near_point: Vector3 = Vector3(near_clip.x, near_clip.y, near_clip.z) / near_clip.w
	var far_point: Vector3 = Vector3(far_clip.x, far_clip.y, far_clip.z) / far_clip.w
	# The global transform needs a tree; a camera a suite holds on its own has
	# only its local one, which is the same thing for a camera with no parent.
	var placement: Transform3D = camera.global_transform if camera.is_inside_tree() \
		else camera.transform
	var origin: Vector3 = placement * near_point
	var direction: Vector3 = (placement * far_point - origin).normalized()
	out.append(origin)
	out.append(direction)
	return out


## The [Projection] a camera set up by [method frame_projection] renders
## with, for a render of *render* units -- what [method Camera3D.get_camera_projection]
## answers inside a tree, built here from the four properties so a suite
## without a viewport gets the same matrix.
static func projection_of(camera: Camera3D, render: Vector2) -> Projection:
	if camera.projection == Camera3D.PROJECTION_FRUSTUM:
		return Projection.create_frustum_aspect(camera.size, render.x / render.y,
			camera.frustum_offset, camera.near, camera.far,
			camera.keep_aspect == Camera3D.KEEP_WIDTH)
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return Projection.create_orthogonal_aspect(camera.size, render.x / render.y,
			camera.near, camera.far, camera.keep_aspect == Camera3D.KEEP_WIDTH)
	return Projection.create_perspective(camera.fov, render.x / render.y,
		camera.near, camera.far, camera.keep_aspect == Camera3D.KEEP_WIDTH)


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
	if target_at - eye_at != _target - _eye:
		_free_looking = false
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
	_free_looking = false
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
	_free_looking = false
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
## Used by the optional compatibility hand-back (docs/42 section 2.6).
## Normal selection re-applies its view through CameraDirector instead.
## Returns the flight's frames.
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


## 0x00403600 turns at the fixed eye and clamps pitch to +/-90 degrees.
## Reconstruct a target for the remake's eye/target consumers; the original
## stores its camera angles independently.
func look_by(pixels: Vector2) -> void:
	if pixels.is_zero_approx():
		return
	var direction: Vector3 = Vector3(_target - _eye)
	var distance: float = maxf(direction.length(), 1.0)
	if not _free_looking:
		_look_angles = Vector2(atan2(direction.x, direction.y),
			atan2(direction.z, Vector2(direction.x, direction.y).length()))
	_look_angles.x = wrapf(_look_angles.x + pixels.x * LOOK_RADIANS_PER_PIXEL, -PI, PI)
	_look_angles.y = clampf(_look_angles.y - pixels.y * LOOK_RADIANS_PER_PIXEL, -PI / 2.0, PI / 2.0)
	var angles: Vector2 = _look_angles
	var horizontal: float = cos(angles.y)
	direction = Vector3(sin(angles.x) * horizontal,
		cos(angles.x) * horizontal, sin(angles.y))
	set_now(_eye, _eye + Vector3i((direction * distance).round()))
	_look_angles = angles
	_free_looking = true
	_apply()


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


## Section 2.4, view mode 0: the whole map from above, with no unit in it.
##
## `fcn.004532A0` reads the clamp box of section 2.1 rather than the map's
## dimensions -- so the centre is `(lo + hi) / 2` on each axis, truncated
## toward zero -- and the height is a constant `0x23A50` that the box does
## **not** clamp: this is the one placement in the game that may stand above
## the header's own camera ceiling. Returns the flight's frames.
func view_overview() -> int:
	_view = View.SCRIPT
	var cx: int = IncInt.div_trunc(_box_lo.x + _box_hi.x, 2)
	var cy: int = IncInt.div_trunc(_box_lo.y + _box_hi.y, 2)
	return fly(Vector3i(cx, cy - OVERVIEW_LEAN, OVERVIEW_HEIGHT),
		Vector3i(cx, cy, 0))


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


## `0x00403960` -- a world point on the screen, in pixels of the viewport,
## for the floating texts of docs/42 section 4.4. `visible` is false behind
## the camera or with no viewport, and the engine's own answer to a failed
## projection is a y of 0, which is what [FloatingTexts] draws it at.
func screen_point(point: Vector3i) -> Dictionary:
	if _camera == null or not _camera.is_inside_tree():
		return {"visible": false, "x": 0.0, "y": 0.0}
	var at: Vector3 = WorldSpace.to_godot(point.x, point.y, point.z)
	if _camera.is_position_behind(at):
		return {"visible": false, "x": 0.0, "y": 0.0}
	var on: Vector2 = _camera.unproject_position(at)
	return {"visible": true, "x": on.x, "y": on.y}


# --- persistence -------------------------------------------------------------

func state() -> Dictionary:
	var out: Dictionary = {"eye": [_eye_goal.x, _eye_goal.y, _eye_goal.z],
		"target": [_target_goal.x, _target_goal.y, _target_goal.z],
		"quadrant": _quadrant, "view": int(_view)}
	if _free_looking:
		out["look_angles"] = [_look_angles.x, _look_angles.y]
	return out


func apply_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	_free_looking = false
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
	var angles: Array = DictRead.as_array(data.get("look_angles", []))
	if angles.size() == 2:
		_look_angles = Vector2(DictRead.as_float(angles[0]), DictRead.as_float(angles[1]))
		_free_looking = true
		_apply()


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
	if _free_looking:
		var yaw: float = _look_angles.x
		var pitch: float = _look_angles.y
		forward = Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
		up = Vector3(-sin(yaw) * sin(pitch), cos(pitch), cos(yaw) * sin(pitch))
	elif absf(forward.dot(up)) > 0.9999:
		up = Vector3.BACK
	_camera.transform = Transform3D(Basis.looking_at(forward, up), local)
