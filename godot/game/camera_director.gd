class_name CameraDirector
extends RefCounted

## What moves the camera and when -- docs/42 sections 2.3, 2.4, 3.2 and 4.3
## as decisions over a [World], with the arithmetic left to [CameraRig].
##
## Every method here reads views and writes the rig; none of them touches the
## simulation. The rig's placements are the engine's; the decisions of which
## placement to make, and with which arguments, are the call-site table of
## docs/42 section 2.3 and the mode tables of sections 3.2 and 4.3, and each
## method names the row it implements. Where the remake decides for itself
## it says so.

## docs/42 section 2.3 -- the `(dist, height, mode)` triples, by call site.
const CYCLE_PLACEMENT: Vector3i = Vector3i(8, 7, 0)
const WALK_PLACEMENT: Vector3i = Vector3i(6, 4, 0)
const SHOT_SAME_CELL: Vector3i = Vector3i(5, 2, 1)
const SHOT_BEHIND_SHOOTER: Vector3i = Vector3i(9, 5, 1)
const SHOT_BEHIND_VICTIM: Vector3i = Vector3i(5, 3, 1)
## Section 4.3 -- the far shot: back from the shooter along the line, one
## field (a large type 5600), 1 m over its head.
const SHOT_BACK: int = 0xC80
const SHOT_BACK_LARGE: int = 0x15E0
const SHOT_UP: int = 0x640
## -- the near test: within three fields and 0x12C0 in height.
const SHOT_NEAR_FIELDS: int = 4
const SHOT_NEAR_HEIGHT: int = 0x12C0
## -- the projection test on the shooter and the target: the screen y as a
## fraction of the view, 21..99 for the shooter and up to 99 for the target.
## **The unit of `0x00403960`'s y is UNVERIFIED**; a hundredth of the view
## height is what makes 99 mean "not below the bottom".
const SCREEN_Y_LOW: float = 0.21
const SCREEN_Y_HIGH: float = 0.99
## Section 4.3 -- the reaction camera, read out of `0x0040C08E`: 2400 back
## along the line's horizontal direction (5600 for a large type), and the
## height is the unit's minus 4800 (8000) times the line's slope, then raised
## to the local floor by `0x00453730`. docs/42's first reading had the two
## numbers the other way round.
const REACTION_BACK: int = 0x960
const REACTION_BACK_LARGE: int = 0x15E0
const REACTION_SLOPE: int = 0x12C0
const REACTION_SLOPE_LARGE: int = 0x1F40
const REACTION_COIN: float = 5.0
const REACTION_COIN_SPAN: int = 10
## `0x00453730` -- the floor helper's own margin over the highest neighbour.
const FLOOR_MARGIN: int = 800
const FLOOR_IGNORE_ABOVE: int = 16000
const FLOOR_NO_UNIT: int = 0xC80

## Section 3.2 -- the walk's presentation modes.
enum WalkMode { NONE = 0, OWN = 1, ARRIVING = 2, SEEN = 3 }
var rig: CameraRig = null
## The reaction coin's stream: `aRandom2`, seeded from the clock like the
## effects' (docs/22 section 3.2), and **never** [member World.rng].
var rng: IncRandom = IncRandom.new()


static func create(camera_rig: CameraRig) -> CameraDirector:
	var out: CameraDirector = CameraDirector.new()
	out.rig = camera_rig
	out.rng.randomize_seed(float(Time.get_ticks_msec()))
	return out


## What `0x004529D0` reads about a unit: its placed object's position, its
## type's height and its facing's gradient -- plus its size, for the shot
## cameras. Empty when the slot has no view.
static func unit_inputs(world: World, slot: int) -> Dictionary:
	var view: Dictionary = world.unit_view(slot)
	if view.is_empty():
		return {}
	return inputs_at(world, view, DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))


## The same, with the unit standing on another cell -- where the picture has
## it during a replay, or where a walk will take it.
static func inputs_at(world: World, view: Dictionary, x: int,
		y: int) -> Dictionary:
	if not world.state.in_bounds(x, y):
		return {}
	var types: UnitTypeTable = world.unit_types()
	var type_id: int = DictRead.as_int(view["type_id"])
	return {
		"obj": CameraRig.cell_object(x, y,
			world.state.height_at(world.state.index_of(x, y))),
		"height": types.body_height_world(type_id),
		"gradient": _lift(gradient_of(DictRead.as_int(view["facing"]))),
		"large": types.unit_size(type_id) != 0,
		"x": x, "y": y,
	}


## A gradient as the dictionary carries it: a [Vector3i] with a zero third
## component, because [method DictRead.as_vector3i] is the typed way back out.
static func _lift(step: Vector2i) -> Vector3i:
	return Vector3i(step.x, step.y, 0)


## `0x0047ABD0` -- a facing's gradient, the step it points along.
static func gradient_of(facing: int) -> Vector2i:
	for step: Vector2i in ExecuteMove.FACING_OF_STEP:
		if DictRead.as_int(ExecuteMove.FACING_OF_STEP[step]) == facing:
			return step
	return Vector2i(0, 1)


func _object_of(world: World, x: int, y: int) -> Vector3i:
	return CameraRig.cell_object(x, y,
		world.state.height_at(world.state.index_of(x, y)))


# --- the player's view -------------------------------------------------------

## A selection: the target flies to the unit, the eye's offset kept. The
## remake's, as [method CameraRig.focus_on] says. Returns seconds.
func select(world: World, slot: int) -> float:
	var inputs: Dictionary = unit_inputs(world, slot)
	if inputs.is_empty() or rig == null:
		return 0.0
	var obj: Vector3i = DictRead.as_vector3i(inputs["obj"])
	return _seconds(rig.focus_on(DictRead.as_int(inputs["x"]),
		DictRead.as_int(inputs["y"]), obj.z))


## `fcn.004533D0` -- re-apply the **current view mode** on a unit's cell.
##
## docs/43 section 4.5's table, which is what the engine runs after every
## successful select. [method select] is the remake's softer version of it --
## a pivot that keeps the player's own arrangement -- and that is right for a
## click, because the arrangement is worth keeping. It is **wrong on the way
## back from the computer's turn**: the replay's own camera (section 4.3's
## shot and reaction placements) leaves the eye a metre and a half behind
## whichever alien fired last, and a pivot that keeps *that* offset hands the
## turn back with the camera in a marine's boots or, for a shot taken across
## the map, somewhere off the edge of it. Returns seconds.
func apply_view_mode(world: World, slot: int) -> float:
	if rig == null or world == null:
		return 0.0
	match rig.view_mode():
		CameraRig.View.SCRIPT:
			return view_overview()
		CameraRig.View.EYES:
			return view_eyes(world, slot)
		CameraRig.View.MAP:
			var view: Dictionary = world.unit_view(slot)
			if view.is_empty():
				return 0.0
			return view_map(world, DictRead.as_int(view["x"]),
				DictRead.as_int(view["y"]))
		_:
			return _place(world, slot, CYCLE_PLACEMENT)


## Section 2.3's cycle row: `0x00453D42`, `(8, 7, 0)` on the next own unit.
## Returns seconds.
func cycle(world: World, slot: int) -> float:
	return _place(world, slot, CYCLE_PLACEMENT)


## Section 2.4 -- view mode 1, through the unit's eyes.
func view_eyes(world: World, slot: int) -> float:
	var inputs: Dictionary = unit_inputs(world, slot)
	if inputs.is_empty() or rig == null:
		return 0.0
	return _seconds(rig.view_eyes(DictRead.as_vector3i(inputs["obj"]),
		DictRead.as_int(inputs["height"]),
		Vector2i(DictRead.as_vector3i(inputs["gradient"]).x,
			DictRead.as_vector3i(inputs["gradient"]).y)))


## Section 2.4 -- view mode 2, on the unit: `(8, 7, 0)`.
func view_unit(world: World, slot: int) -> float:
	if rig != null:
		rig.set_view_mode(CameraRig.View.UNIT)
	return _place(world, slot, CYCLE_PLACEMENT)


## docs/43 section 2 -- view mode 0, the overview map: the whole box from
## above, with no unit in it and nothing else on screen changed.
func view_overview() -> float:
	if rig == null:
		return 0.0
	return _seconds(rig.view_overview())


## Section 2.4 -- view mode 4, the map, 15 m over a cell.
func view_map(world: World, x: int, y: int) -> float:
	if rig == null or not world.state.in_bounds(x, y):
		return 0.0
	return _seconds(rig.view_map(_object_of(world, x, y)))


func _place(world: World, slot: int, args: Vector3i) -> float:
	var inputs: Dictionary = unit_inputs(world, slot)
	return _place_inputs(inputs, args)


func _place_inputs(inputs: Dictionary, args: Vector3i) -> float:
	if inputs.is_empty() or rig == null:
		return 0.0
	var gradient: Vector3i = DictRead.as_vector3i(inputs["gradient"])
	return _seconds(rig.place(DictRead.as_vector3i(inputs["obj"]),
		DictRead.as_int(inputs["height"]), Vector2i(gradient.x, gradient.y),
		args.x, args.y, args.z))


static func _seconds(frames: int) -> float:
	return float(frames) / CameraRig.FRAMES_PER_SECOND


# --- the walk ----------------------------------------------------------------

## Section 3.2's mode byte, decided at the top of `aExecuteMove`.
##
## `aExecuteMove`'s top (`0x0046E320`..`0x0046E3E7`), docs/42 section 3.2.
##
## The player's own unit walks in mode 1. A computer unit walks in mode 3 when
## it would see an enemy from where it stands, in mode 2 when it would see one
## only from where it is going, and in mode 0 -- no frames at all -- from
## neither. The *Enemy Move* option is not in the remake and is taken as on.
##
## The two flags are the routine's own locals as `core` reports them on the
## move event ([member MoveResult.seen_source], [member MoveResult.seen_destination]):
## the passes are writing ones and belong to `core`, and so does the
## `+0x0C > 6` discard of the destination's answer
## ([constant ExecuteMove.ARRIVAL_POINTS_LIMIT]) -- a unit that will arrive
## with more than six points to spend is not shown arriving.
static func walk_mode(own: bool, seen_at_source: bool,
		seen_at_destination: bool) -> WalkMode:
	if own:
		return WalkMode.OWN
	if seen_at_source:
		return WalkMode.SEEN
	if seen_at_destination:
		return WalkMode.ARRIVING
	return WalkMode.NONE


## The camera before the first step, by mode. Returns the seconds the walk
## must wait -- the engine's flight blocks and the walk starts after it.
##
## * mode 1 -- `0x0040EDB0`: in a view that is neither script, eyes nor map,
##   the target flies to the unit and the eye stays;
## * mode 3 -- if the unit is off screen (no clear line from the eye to its
##   object plus a field) or the eye is at or under 12 800: the map view on
##   its cell when the view is the map, else `(6, 4, 0)`; otherwise as mode 1;
## * mode 2 -- a flight from the unit's own position at head height to its
##   destination, looking 160 under its head there; the ride follows.
func before_walk(world: World, view: Dictionary, from_x: int, from_y: int,
		to_x: int, to_y: int, mode: WalkMode) -> float:
	if rig == null:
		return 0.0
	var inputs: Dictionary = inputs_at(world, view, from_x, from_y)
	if inputs.is_empty():
		return 0.0
	var obj: Vector3i = DictRead.as_vector3i(inputs["obj"])
	var unit_height: int = DictRead.as_int(inputs["height"])
	match mode:
		WalkMode.OWN:
			return _target_to_unit(obj, unit_height)
		WalkMode.SEEN:
			var seen_here: bool = rig.line_is_clear(rig.eye(),
				obj + Vector3i(0, 0, CameraRig.AXIS_EXTRA))
			if seen_here and rig.eye().z > CameraRig.LOW_CAMERA:
				return _target_to_unit(obj, unit_height)
			if rig.view_mode() == CameraRig.View.MAP:
				return _seconds(rig.view_map(obj))
			return _place_inputs(inputs, WALK_PLACEMENT)
		WalkMode.ARRIVING:
			if not world.state.in_bounds(to_x, to_y):
				return 0.0
			var there: Vector3i = _object_of(world, to_x, to_y)
			return _seconds(rig.fly(
				Vector3i(obj.x, obj.y, obj.z + unit_height),
				Vector3i(there.x, there.y, there.z + unit_height - 0xA0)))
		_:
			return 0.0


## `0x0040EDB0`: the position stays, the target flies to the unit -- in view
## modes other than script, eyes and map.
func _target_to_unit(obj: Vector3i, unit_height: int) -> float:
	var view: CameraRig.View = rig.view_mode()
	if view == CameraRig.View.SCRIPT or view == CameraRig.View.EYES \
			or view == CameraRig.View.MAP:
		return 0.0
	return _seconds(rig.fly(rig.eye(),
		Vector3i(obj.x, obj.y, obj.z + unit_height)))


## Whether a walk in `mode` is shown from the unit's own eyes: mode 2 always,
## modes 1 and 3 when the view is the eyes view (`0x0046E8BC`).
func rides(mode: WalkMode) -> bool:
	if rig == null:
		return false
	if mode == WalkMode.ARRIVING:
		return true
	return (mode == WalkMode.OWN or mode == WalkMode.SEEN) \
		and rig.view_mode() == CameraRig.View.EYES


## Whether a walk in `mode` is tracked -- the target on the walker each
## frame (`0x0040EBB0`): modes 1 and 3 in a view that is neither script nor
## map, and not when it rides.
func tracks(mode: WalkMode) -> bool:
	if rig == null or rides(mode):
		return false
	if mode != WalkMode.OWN and mode != WalkMode.SEEN:
		return false
	var view: CameraRig.View = rig.view_mode()
	return view != CameraRig.View.SCRIPT and view != CameraRig.View.MAP


## One frame of a walk: the target on the walker's head, or the ride.
## `destination` is the walk's last cell's object, for the ride's look-at.
##
## **Nothing is written while the rig is flying.** The engine's pre-walk
## flight blocks and the first step comes after it; here the walk waits on
## its delay, and a tracking write in the meantime would cancel the target's
## half of the flight the walk is waiting for.
func track(at: Vector3i, unit_height: int, mode: WalkMode,
		destination: Vector3i) -> void:
	if rig == null or rig.is_flying():
		return
	if rides(mode):
		rig.ride(at, unit_height, destination)
	elif tracks(mode):
		rig.set_target_now(Vector3i(at.x, at.y, at.z + unit_height))


# --- the shot ----------------------------------------------------------------

## Section 4.3 for a **computer** shooter that is not reacting. The player's
## own shot moves nothing and does not come here. Returns seconds.
##
## `shooter` and `target` are [method inputs_at] dictionaries for the two
## cells -- the target's is the cell's own object with the shooter's height,
## because the engine reads the shooter's record for both (`0x0040C4A9` and
## `0x0040C4CE`). `victim` is whether a unit stands on the target cell.
func computer_shot(shooter: Dictionary, target: Dictionary,
		victim: bool) -> float:
	if rig == null or shooter.is_empty() or target.is_empty():
		return 0.0
	var sobj: Vector3i = DictRead.as_vector3i(shooter["obj"])
	var tobj: Vector3i = DictRead.as_vector3i(target["obj"])
	var height: int = DictRead.as_int(shooter["height"])
	var shooter_seen: bool = _on_screen(sobj, SCREEN_Y_LOW)
	var target_seen: bool = _on_screen(tobj, 0.0)
	var same_cell: bool = DictRead.as_int(shooter["x"]) \
		== DictRead.as_int(target["x"]) and DictRead.as_int(shooter["y"]) \
		== DictRead.as_int(target["y"])
	if same_cell:
		if shooter_seen:
			return _place_inputs(shooter, SHOT_SAME_CELL)
		return 0.0
	if shooter_seen and target_seen \
			and rig.view_mode() != CameraRig.View.MAP:
		return 0.0
	var fields: int = Eng3dGeometry.distance_2d(
		DictRead.as_int(shooter["x"]) - DictRead.as_int(target["x"]),
		DictRead.as_int(shooter["y"]) - DictRead.as_int(target["y"]))
	if fields < SHOT_NEAR_FIELDS and absi(sobj.z - tobj.z) <= SHOT_NEAR_HEIGHT:
		if not victim:
			return _place_inputs(shooter, SHOT_BEHIND_SHOOTER)
		return _place_inputs(target, SHOT_BEHIND_VICTIM)
	var back: int = SHOT_BACK_LARGE if DictRead.as_bool(shooter["large"]) \
		else SHOT_BACK
	var dir: PackedFloat64Array = Eng3dGeometry.direction(sobj, tobj, 1)
	var eye_at: Vector3i = Vector3i(sobj.x - Eng3dGeometry.ftol(dir[0] * back),
		sobj.y - Eng3dGeometry.ftol(dir[1] * back), sobj.z + height + SHOT_UP)
	return _seconds(rig.fly(eye_at, Vector3i(tobj.x, tobj.y, tobj.z + height)))


## Section 4.3 for a reaction, on either turn: a coin decides whether the
## camera goes behind the reactor looking at the mover or behind the mover
## looking at the reactor. Both heights are the reactor's; the back-off is
## sized by the unit the camera stands behind. `floor_at` is `0x00453730`'s
## answer for a position, from [method floor_height]. Returns seconds.
func reaction_shot(world: World, reactor: Dictionary, mover: Dictionary,
		coin: int) -> float:
	if rig == null or reactor.is_empty() or mover.is_empty():
		return 0.0
	var behind_reactor: bool = coin >= int(REACTION_COIN)
	var behind: Dictionary = reactor if behind_reactor else mover
	var ahead: Dictionary = mover if behind_reactor else reactor
	var bobj: Vector3i = DictRead.as_vector3i(behind["obj"])
	var aobj: Vector3i = DictRead.as_vector3i(ahead["obj"])
	var height: int = DictRead.as_int(reactor["height"])
	var large: bool = DictRead.as_bool(behind["large"])
	var back: int = REACTION_BACK_LARGE if large else REACTION_BACK
	var slope: int = REACTION_SLOPE_LARGE if large else REACTION_SLOPE
	var dir: PackedFloat64Array = Eng3dGeometry.direction(bobj, aobj, 1)
	var eye_at: Vector3i = Vector3i(bobj.x - Eng3dGeometry.ftol(dir[0] * back),
		bobj.y - Eng3dGeometry.ftol(dir[1] * back),
		height + (bobj.z - Eng3dGeometry.ftol(dir[2] * slope)))
	eye_at.z = floor_height(world, eye_at)
	return _seconds(rig.fly(eye_at, Vector3i(aobj.x, aobj.y, aobj.z + height)))


## The coin: `aRandom2(0, 10) < 5` sends the camera behind the mover.
func toss() -> int:
	return rng.draw(0, REACTION_COIN_SPAN)


## `0x00453730` -- a height no lower than the cell under a position plus the
## unit on it, nor than any of its four neighbours under 16 000, plus 800.
static func floor_height(world: World, at: Vector3i) -> int:
	var field: int = WorldSpace.WORLD_UNITS_PER_FIELD
	var cx: int = IncInt.div_trunc(at.x + field / 2, field)
	var cy: int = IncInt.div_trunc(at.y + field / 2, field)
	var z: int = at.z
	if world.state.in_bounds(cx, cy):
		var index: int = world.state.index_of(cx, cy)
		var here: int = world.state.height_at(index)
		var slot: int = world.state.unit_at(index)
		if slot >= 0:
			var view: Dictionary = world.unit_view(slot)
			if view.is_empty():
				here += FLOOR_NO_UNIT
			else:
				here += world.unit_types().body_height_world(
					DictRead.as_int(view["type_id"]))
		z = maxi(z, here)
	for step: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1),
			Vector2i(0, 1)]:
		var nx: int = cx + step.x
		var ny: int = cy + step.y
		if not world.state.in_bounds(nx, ny):
			continue
		var h: int = world.state.height_at(world.state.index_of(nx, ny))
		if h > FLOOR_IGNORE_ABOVE:
			continue
		z = maxi(z, h)
	return z + FLOOR_MARGIN


## Section 4.3's projection test: on screen with y at least `low` of the
## view, and a clear line from the eye to the object plus a field.
func _on_screen(obj: Vector3i, low: float) -> bool:
	var on: Dictionary = rig.screen_position(obj)
	if not DictRead.as_bool(on["visible"]):
		return false
	var y: float = DictRead.as_float(on["y"])
	if y < low or y > SCREEN_Y_HIGH:
		return false
	return rig.line_is_clear(rig.eye(), obj + Vector3i(0, 0, CameraRig.AXIS_EXTRA))
