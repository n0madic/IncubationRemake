extends TestSuite

## Oracle boundary: specification-only. docs/42 section 2 -- the engine's
## camera state, its flight, its placements, its three views and its pan --
## and sections 3.2 and 4.3 for what a walk and a shot do with it, under
## docs/92 section 7.5's model A: the tactical orientation stays discrete.
##
## Every number here is docs/42's, and each check names the row it pins. What
## a suite cannot reach is the picture -- whether the eye is above the roof --
## and docs/97's addendum records the by-hand half.

const EPSILON: float = 0.000001
const METRE: int = 1600
const FIELD: int = 3200
## An 18-unit type: `0x0047AD70`'s `18 * 160`.
const BODY: int = 2880
## A 20 m camera height, the header's world units.
const CEILING: int = 32000


func run(h: TestHarness) -> void:
	h.begin("camera", TestHarness.ORACLE_SPEC)
	_check_flight(h)
	_check_placement(h)
	_check_search(h)
	_check_views(h)
	_check_selection_views(h)
	_check_deployment_view_keys(h)
	_check_free_look(h)
	_check_pan_and_zoom(h)
	_check_zoom_inputs(h)
	_check_walk_modes(h)
	_check_shots(h)
	_inside_the_level(h)
	_hands_the_view_back(h)
	_check_orbits(h)


## A flat map with one rig on it, no tree needed.
static func _flat_rig(w: int, hgt: int, ceiling: int = CEILING) -> CameraRig:
	var heights: PackedInt32Array = PackedInt32Array()
	heights.resize(w * hgt)
	heights.fill(0)
	var rig: CameraRig = CameraRig.new()
	rig.setup(w, hgt, heights, ceiling)
	return rig


static func _v(x: int, y: int, z: int) -> Vector3i:
	return Vector3i(x, y, z)


func _check_free_look(h: TestHarness) -> void:
	var rig: CameraRig = _flat_rig(20, 20)
	var eye: Vector3i = _v(32000, 32000, 3200)
	rig.set_view_mode(CameraRig.View.EYES)
	rig.set_now(eye, eye + _v(0, 3200, 0))
	rig.look_by(Vector2(64, 0))
	h.equal("look.eye_stays", rig.eye(), eye)
	h.equal("look.eighth_turn", rig.target(), eye + _v(2263, 2263, 0))
	h.equal("look.mode_stays", rig.view_mode(), CameraRig.View.EYES)
	h.check("look.immediate", not rig.is_flying())
	rig.look_by(Vector2(0, -1000))
	h.equal("look.pitch_clamped_up", rig.target(), eye + _v(0, 0, 3200))
	h.check("look.pole_basis_finite", rig.camera().basis.is_finite())
	var saved: Dictionary = rig.state()
	var twin: CameraRig = _flat_rig(20, 20)
	twin.apply_state(saved)
	rig.look_by(Vector2(32, 1))
	twin.look_by(Vector2(32, 1))
	h.equal("look.pole_save_continuation", rig.state(), twin.state())
	# One pixel changes the angle even when integer rounding keeps z equal.
	h.check("look.leaves_pole", rig.target().x != eye.x or rig.target().y != eye.y)
	rig.look_by(Vector2(0, 1000))
	h.equal("look.pitch_clamped_down", rig.target().z, eye.z - 3200)
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if not loaded.is_empty():
		var main: SliceMain = SliceMain.new()
		main.world = loaded["world"]
		main._rig = rig
		var hash_before: String = main.world.canonical_hash_hex()
		rig.set_now(eye, eye + _v(0, 3200, 0))
		var motion: InputEventMouseMotion = InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_RIGHT
		motion.relative = Vector2(64, 0)
		main._unhandled_input(motion)
		var mouse_view: Dictionary = rig.state()
		h.equal("look.input_right_drag", rig.target(), eye + _v(2263, 2263, 0))
		var release: InputEventMouseButton = InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_RIGHT
		main._unhandled_input(release)
		h.equal("look.release_no_extra_turn", rig.state(), mouse_view)
		rig.set_now(eye, eye + _v(0, 3200, 0))
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.alt_pressed = true
		main._unhandled_input(motion)
		h.equal("look.trackpad_primary_drag", rig.state(), mouse_view)
		rig.set_now(eye, eye + _v(0, 3200, 0))
		var gesture: InputEventPanGesture = InputEventPanGesture.new()
		gesture.alt_pressed = true
		gesture.delta = Vector2(8, 0)
		main._unhandled_input(gesture)
		h.equal("look.trackpad_gesture", rig.state(), mouse_view)
		gesture.delta = Vector2(0, 2)
		main._unhandled_input(gesture)
		h.equal("look.trackpad_vertical_does_not_zoom", rig.eye(), eye)
		mouse_view = rig.state()
		var press: InputEventMouseButton = InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.alt_pressed = true
		main._unhandled_input(press)
		h.equal("look.trackpad_press_does_not_select", main.selected_slot(), -1)
		gesture.alt_pressed = false
		h.equal("look.unmodified_scroll_not_rotation", SliceMain.look_delta_for(gesture), Vector2.ZERO)
		var events: Array[Dictionary] = [{"kind": "move"}]
		main._playback.play(events, func(_event: Dictionary) -> float: return 1.0)
		main._unhandled_input(motion)
		h.equal("look.blocked_during_playback", rig.state(), mouse_view)
		main._playback.cancel()
		h.equal("look.simulation_unchanged", main.world.canonical_hash_hex(), hash_before)
		main.free()
	else:
		h.check("look.cache", false, "no _C_140 in cache")
	twin.free()
	rig.free()


func _check_selection_views(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("select.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var slot: int = SliceMain.first_friendly_slot(world)
	var view: Dictionary = world.unit_view(slot)
	var rig: CameraRig = _flat_rig(world.resource.width, world.resource.height)
	var expected: CameraRig = _flat_rig(world.resource.width, world.resource.height)
	var director: CameraDirector = CameraDirector.create(rig)
	var reference: CameraDirector = CameraDirector.create(expected)
	var before: String = world.canonical_hash_hex()
	for mode: CameraRig.View in [CameraRig.View.UNIT, CameraRig.View.EYES,
			CameraRig.View.MAP, CameraRig.View.SCRIPT]:
		# A long walk leaves the eye far from the target. Selection must
		# use the view's own placement, independent of that old distance.
		rig.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
		rig.set_view_mode(mode)
		var _placed: float = 0.0
		match mode:
			CameraRig.View.UNIT:
				_placed = reference.view_unit(world, slot)
			CameraRig.View.EYES:
				_placed = reference.view_eyes(world, slot)
			CameraRig.View.MAP:
				_placed = reference.view_map(world,
					DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))
			CameraRig.View.SCRIPT:
				_placed = reference.view_overview()
		_placed = director.select(world, slot)
		h.equal("select.view_%d" % int(mode), rig.state(), expected.state())
	h.equal("select.leaves_simulation_unchanged", world.canonical_hash_hex(), before)
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._rig = rig
	main._director = director
	main._strings = Localization.new()
	var hud: MissionHud = MissionHud.new()
	hud.setup(null, main._strings, null, null, null)
	main._hud = hud
	for mode: CameraRig.View in [CameraRig.View.UNIT, CameraRig.View.EYES,
			CameraRig.View.MAP, CameraRig.View.SCRIPT]:
		rig.set_view_mode(mode)
		expected.set_view_mode(mode)
		var _placed: float = reference.apply_view_mode(world, slot)
		var _query: MoveMapResult = main.select_unit(slot, false)
		h.equal("select.click_view_%d" % int(mode), rig.state(), expected.state())
		main._selected = -1
		h.equal("select.cycle_slot_%d" % int(mode), main.cycle_friendly(), slot)
		h.equal("select.cycle_view_%d" % int(mode), rig.state(), expected.state())
	# The original key numbers are event numbers, and the event reaches the
	# corresponding measured placement rather than merely changing a label.
	var keyed_views: Array[Array] = [
		[KEY_1, HudTables.EVENT_FREE_CAMERA, CameraRig.View.SCRIPT],
		[KEY_2, HudTables.EVENT_UNIT_VIEW, CameraRig.View.EYES],
		[KEY_3, HudTables.EVENT_MAP_VIEW, CameraRig.View.MAP],
		[KEY_4, HudTables.EVENT_USER_VIEW, CameraRig.View.UNIT],
	]
	for row: Array in keyed_views:
		var keycode: int = DictRead.as_int(row[0])
		var event: int = DictRead.as_int(row[1])
		var mode: int = DictRead.as_int(row[2])
		rig.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
		expected.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
		var _placed: float = 0.0
		match mode:
			CameraRig.View.SCRIPT:
				_placed = reference.view_overview()
			CameraRig.View.EYES:
				_placed = reference.view_eyes(world, slot)
			CameraRig.View.MAP:
				_placed = reference.view_map(world, DictRead.as_int(view["x"]),
					DictRead.as_int(view["y"]))
			CameraRig.View.UNIT:
				_placed = reference.view_unit(world, slot)
		h.equal("select.key_%s_event" % OS.get_keycode_string(keycode),
			HudTables.event_for_key(keycode), event)
		main._on_hud_event(event)
		h.equal("select.key_%s_view" % OS.get_keycode_string(keycode),
			rig.state(), expected.state())
	# Space is not End Turn: outside eyes it centres through the eyes view;
	# from eyes it centres through the on-unit view, exactly as 0x0041BAB0.
	rig.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
	expected.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
	rig.set_view_mode(CameraRig.View.MAP)
	expected.set_view_mode(CameraRig.View.MAP)
	var _eyes: float = reference.view_eyes(world, slot)
	main._unhandled_input(_key(KEY_SPACE, true))
	h.equal("select.space_centres_in_eyes", rig.state(), expected.state())
	rig.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
	expected.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
	var _unit: float = reference.view_unit(world, slot)
	main._unhandled_input(_key(KEY_SPACE, true))
	h.equal("select.space_centres_on_unit", rig.state(), expected.state())
	h.equal("select.classic_keys_leave_simulation_unchanged",
		world.canonical_hash_hex(), before)
	hud.free()
	main.free()
	rig.free()
	expected.free()


## The deployment plate owns input through `_screen_input`, not the mission's
## ordinary `_unhandled_input` path. Keep keys 2 and 4 distinct both before
## the first soldier lands and after there is a unit for the directors to use.
func _check_deployment_view_keys(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_141")
	if loaded.is_empty():
		h.check("deploy_view.cache", false, "no _C_141 in the cache")
		return
	var world: World = loaded["world"]
	var _cleared: int = world.clear_units_of(0)
	var rig: CameraRig = _flat_rig(world.resource.width, world.resource.height)
	var expected: CameraRig = _flat_rig(world.resource.width, world.resource.height)
	var main: SliceMain = SliceMain.new()
	main.world = world
	main._rig = rig
	main._director = CameraDirector.create(rig)
	main.campaign = CampaignHost.new()
	main.campaign._mission_world = world
	var screen: SelectUnitsScreen = SelectUnitsScreen.new()
	main._screen = screen
	var at: Vector2i = main._deployment_centre()
	h.check("deploy_view.has_centre", at.x >= 0, str(at))
	if at.x >= 0:
		var cell: Dictionary = world.cell_view(at.x, at.y)
		var centre: Vector3i = CameraRig.cell_object(at.x, at.y,
			DictRead.as_int(cell["height"]))
		rig.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
		expected.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
		var _eyes: int = expected.view_eyes(centre, 0, Vector2i(0, 1))
		expected.settle()
		main._screen_input(_key(KEY_2, true))
		h.equal("deploy_view.empty_key_2_is_eyes", rig.state(), expected.state())

		rig.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
		expected.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
		var goal: Dictionary = expected.place_on_unit(
			centre, 0, Vector2i(0, 1), 8, 7, 0)
		expected.set_view_mode(CameraRig.View.UNIT)
		expected.set_now(DictRead.as_vector3i(goal["eye"]),
			DictRead.as_vector3i(goal["target"]))
		main._screen_input(_key(KEY_4, true))
		h.equal("deploy_view.empty_key_4_is_unit", rig.state(), expected.state())

		var marine: UnitState = UnitState.new()
		marine.name = "Camera probe"
		marine.pool_flag = Roster.POOL_CANDIDATE
		marine.type_id = 0
		marine.hp = 9
		var placed: Dictionary = world.deploy_from_pool(0, marine, at.x, at.y)
		var slot: int = DictRead.as_int(placed["slot"])
		h.equal("deploy_view.probe_deployed",
			DictRead.as_string(placed["result"]), World.DEPLOY_OK)
		if slot >= 0:
			var reference: CameraDirector = CameraDirector.create(expected)
			rig.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
			expected.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
			var _unit_eyes: float = reference.view_eyes(world, slot)
			expected.settle()
			main._screen_input(_key(KEY_2, true))
			h.equal("deploy_view.placed_key_2_is_eyes",
				rig.state(), expected.state())

			rig.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
			expected.set_now(_v(8000, 8000, 16000), _v(48000, 16000, BODY))
			var _unit_view: float = reference.view_unit(world, slot)
			expected.settle()
			main._screen_input(_key(KEY_4, true))
			h.equal("deploy_view.placed_key_4_is_unit",
				rig.state(), expected.state())
	main._screen = null
	screen.free()
	main.free()
	rig.free()
	expected.free()


# --- docs/42 section 2.2 -----------------------------------------------------

func _check_flight(h: TestHarness) -> void:
	var origin: Vector3i = Vector3i.ZERO
	# Thirds when any delta starts at 500 or more; sixths below it.
	h.equal("flight.fast_is_thirds",
		CameraRig.flight_step(origin, _v(3000, 0, 0), true), _v(1000, 0, 0))
	h.equal("flight.slow_is_sixths",
		CameraRig.flight_step(origin, _v(300, 0, 0), false), _v(50, 0, 0))
	h.equal("flight.truncates_toward_zero",
		CameraRig.flight_step(origin, _v(-100, -100, -100), true),
		_v(-33, -33, -33), "the compiler's signed magic division, not floor")
	# The stop: every one of the six deltas within 30.
	h.equal("flight.stops_at_30", CameraRig.flight_frames(origin, origin,
		_v(30, -30, 30), _v(0, 30, -30)), 0)
	h.check("flight.31_still_flies", CameraRig.flight_frames(origin, origin,
		_v(31, 0, 0), origin) > 0)
	# The fast choice is made once, before the loop: 600 is fast, and after
	# the first third the remaining 400 is still stepped by a third.
	var rig: CameraRig = _flat_rig(40, 40)
	rig.set_now(origin, origin)
	var _frames: int = rig.fly(_v(600, 0, 0), origin)
	var _one: bool = rig.advance(1.0 / CameraRig.FRAMES_PER_SECOND)
	h.equal("flight.first_third", rig.eye(), _v(200, 0, 0))
	_one = rig.advance(1.0 / CameraRig.FRAMES_PER_SECOND)
	h.equal("flight.fast_decided_once", rig.eye(), _v(333, 0, 0),
		"400 left is under 500 but the flight stays on thirds")
	# The 20 m rule: a height change past 0x7D00 is set at once.
	rig.set_now(origin, origin)
	var snap: int = rig.fly(_v(0, 0, CameraRig.FLIGHT_SNAP_HEIGHT + 1), origin)
	h.equal("flight.snap_over_20m", snap, 0)
	h.equal("flight.snap_is_immediate", rig.eye(),
		_v(0, 0, CameraRig.FLIGHT_SNAP_HEIGHT + 1))
	h.check("flight.20m_exactly_flies",
		CameraRig.flight_frames(origin, origin,
			_v(0, 0, CameraRig.FLIGHT_SNAP_HEIGHT), origin) > 0)
	# The target flies by the same rule as the eye.
	rig.set_now(origin, origin)
	_frames = rig.fly(origin, _v(0, 3000, 0))
	_one = rig.advance(1.0 / CameraRig.FRAMES_PER_SECOND)
	h.equal("flight.target_same_rule", rig.target(), _v(0, 1000, 0))
	# 20 fps with a carried remainder: 0.1 s is two steps, 0.04 s none yet.
	rig.set_now(origin, origin)
	_frames = rig.fly(_v(3000, 0, 0), origin)
	_one = rig.advance(0.04)
	h.equal("flight.no_step_under_a_frame", rig.eye(), origin)
	_one = rig.advance(0.07)
	h.equal("flight.two_steps_in_a_tenth", rig.eye(), _v(1666, 0, 0),
		"0.8 + 1.4 frames carried is two steps")
	# `settle` lands where the loop would have stopped: within 30, not on it.
	rig.settle()
	h.check("flight.settle_stops", not rig.is_flying())
	h.check("flight.settle_residual",
		absi(rig.eye().x - 3000) <= CameraRig.FLIGHT_STOP
		and rig.eye().x != 3000,
		"eye at %d for a goal of 3000" % rig.eye().x)
	# The frame count is the loop's own: a 16 m move is in the ten-to-twenty
	# frame band docs/42 describes as typical, and the pre-computation agrees
	# with the stepping.
	var far: int = CameraRig.flight_frames(origin, origin, _v(25600, 0, 0),
		_v(25600, 0, 0))
	h.check("flight.typical_length", far >= 8 and far <= 20,
		"%d frames for 16 m" % far)
	rig.set_now(origin, origin)
	var promised: int = rig.fly(_v(25600, 0, 0), _v(25600, 0, 0))
	var stepped: int = 0
	while rig.is_flying() and stepped < 100:
		_one = rig.advance(1.0 / CameraRig.FRAMES_PER_SECOND)
		stepped += 1
	h.equal("flight.promise_matches_steps", stepped, promised)
	rig.free()


# --- docs/42 section 2.3 -----------------------------------------------------

func _check_placement(h: TestHarness) -> void:
	var rig: CameraRig = _flat_rig(20, 20)
	var obj: Vector3i = CameraRig.cell_object(10, 10, 0)
	h.equal("place.object_is_cell_centre", obj, _v(32000, 32000, 0))
	# Mode 1, facing 0 (gradient +y, axis-aligned): 5 m back along the facing
	# plus one field, 3 m over the head; the target is the head.
	var g: Dictionary = rig.place_on_unit(obj, BODY, Vector2i(0, 1), 5, 3, 1)
	h.equal("place.mode1_axis_eye", DictRead.as_vector3i(g["eye"]),
		_v(32000, 32000 - 5 * METRE - FIELD, BODY + 3 * METRE))
	h.equal("place.mode1_target_is_head", DictRead.as_vector3i(g["target"]),
		_v(32000, 32000, BODY))
	# Mode 1, facing 6 (gradient +x +y): no field added on a diagonal.
	g = rig.place_on_unit(obj, BODY, Vector2i(1, 1), 5, 3, 1)
	h.equal("place.mode1_diagonal_no_extra", DictRead.as_vector3i(g["eye"]),
		_v(32000 - 5 * METRE, 32000 - 5 * METRE, BODY + 3 * METRE))
	# Mode 0, quadrant 0: `(dist + 6)` along x, `dist` along y, `(height + 3)`
	# up -- the corner of a 14 x 8 rectangle, not a quarter turn.
	g = rig.place_on_unit(obj, BODY, Vector2i(0, 1), 8, 7, 0)
	h.equal("place.mode0_quadrant0", DictRead.as_vector3i(g["eye"]),
		_v(32000 + 14 * METRE, 32000 + 8 * METRE, BODY + 10 * METRE))
	# Mode 0's near-axis rule on the teleporter's `(5, 5, 0)`: dy of 8000 is
	# under 9600, so the height moves by `|dx| - 12800` = +4800 -- a raise,
	# where docs/42's first reading said "reduced".
	g = rig.place_on_unit(obj, BODY, Vector2i(0, 1), 5, 5, 0)
	h.equal("place.mode0_near_axis_raises", DictRead.as_vector3i(g["eye"]).z,
		BODY + 8 * METRE + (11 * METRE - CameraRig.NEAR_LIFT))
	# The cap that bites is the box: with a 5 m ceiling `(8, 7, 0)` is held
	# to 8000, where `0x004529D0`'s own cap of "height x 1600" never could.
	var low: CameraRig = _flat_rig(20, 20, 8000)
	g = low.place_on_unit(obj, BODY, Vector2i(0, 1), 8, 7, 0)
	h.equal("place.box_caps_height", DictRead.as_vector3i(g["eye"]).z, 8000)
	low.free()
	# The quadrant signs, in the jump table's order, and a step round them.
	var seen: Array[Vector2i] = []
	for q: int in range(4):
		rig.set_now(obj + _v(14 * METRE, 8 * METRE, 10 * METRE), obj)
		while rig.quadrant() != q:
			rig.rotate_step(1)
			rig.settle()
		var e: Vector3i = DictRead.as_vector3i(
			rig.place_on_unit(obj, BODY, Vector2i(0, 1), 8, 7, 0)["eye"])
		seen.append(Vector2i(signi(e.x - obj.x), signi(e.y - obj.y)))
	h.equal("place.quadrant_signs", seen, CameraRig.QUADRANT_SIGNS,
		"(+,+), (+,-), (-,-), (-,+) -- `0x00452E80`")
	# `place` flies to what `place_on_unit` computed.
	rig.set_now(obj, obj + _v(0, -FIELD, 0))
	var frames: int = rig.place(obj, BODY, Vector2i(0, 1), 8, 7, 0)
	h.check("place.flies", frames > 0 and rig.is_flying())
	h.equal("place.goal_is_the_placement", rig.eye_goal(),
		DictRead.as_vector3i(
			rig.place_on_unit(obj, BODY, Vector2i(0, 1), 8, 7, 0)["eye"]))
	rig.free()
	# The gradients are the facing table's own inverse (`0x0047ABD0`).
	var wrong: PackedStringArray = PackedStringArray()
	for step: Vector2i in ExecuteMove.FACING_OF_STEP:
		var facing: int = DictRead.as_int(ExecuteMove.FACING_OF_STEP[step])
		if CameraDirector.gradient_of(facing) != step:
			wrong.append("facing %d" % facing)
	h.equal("place.gradient_is_facing_inverse", ", ".join(wrong), "")


## `0x00453510` and `0x00453420`.
func _check_search(h: TestHarness) -> void:
	# A 20 m column one field east of the unit, between it and quadrant 0's
	# eye: the search turns the offset until the line clears.
	var w: int = 20
	var heights: PackedInt32Array = PackedInt32Array()
	heights.resize(w * w)
	heights.fill(0)
	for dy: int in range(-1, 2):
		heights[(10 + dy) * w + 11] = 20 * METRE
		heights[(10 + dy) * w + 12] = 20 * METRE
	var rig: CameraRig = CameraRig.new()
	rig.setup(w, w, heights, CEILING)
	var obj: Vector3i = CameraRig.cell_object(10, 10, 0)
	var raw: Vector3i = obj + _v(14 * METRE, 8 * METRE, BODY + 10 * METRE)
	h.check("search.raw_is_blocked",
		not rig.line_is_clear(raw, obj + _v(0, 0, METRE)),
		"the column stands on the line")
	var found: Vector3i = DictRead.as_vector3i(
		rig.place_on_unit(obj, BODY, Vector2i(0, 1), 8, 7, 0)["eye"])
	h.check("search.moved_the_eye", found != raw)
	h.check("search.found_is_clear",
		rig.line_is_clear(found, obj + _v(0, 0, METRE))
		and rig.line_is_clear(found, obj + _v(0, 0, METRE + CameraRig.SEARCH_LOOK_UP)))
	var kept: float = Vector2(float(found.x - obj.x), float(found.y - obj.y)).length()
	var was: float = Vector2(float(raw.x - obj.x), float(raw.y - obj.y)).length()
	h.check("search.keeps_the_distance", absf(kept - was) < 64.0,
		"%.0f after, %.0f before -- a rotation about the look point" % [kept, was])
	# An eye nothing clears is left where it was.
	heights.fill(20 * METRE)
	heights[10 * w + 10] = 0
	var boxed: CameraRig = CameraRig.new()
	boxed.setup(w, w, heights, CEILING)
	h.equal("search.gives_up_unchanged",
		boxed.free_position(raw, obj + _v(0, 0, METRE)), raw)
	boxed.free()
	# The box: 800 in from the origin, a field in from the far edges, the
	# header's height on z.
	h.equal("box.low", rig.clamp_box(_v(-5, 0, -5)), _v(800, 800, 800))
	h.equal("box.high", rig.clamp_box(_v(999999, 999999, 999999)),
		_v(19 * FIELD, 19 * FIELD, CEILING))
	rig.free()


# --- docs/42 section 2.4 -----------------------------------------------------

func _check_views(h: TestHarness) -> void:
	var rig: CameraRig = _flat_rig(20, 20)
	var obj: Vector3i = CameraRig.cell_object(4, 6, 0)
	var _frames: int = rig.view_eyes(obj, BODY, Vector2i(1, 0))
	h.equal("view.eyes_mode", rig.view_mode(), CameraRig.View.EYES)
	h.equal("view.eyes_eye", rig.eye_goal(),
		_v(obj.x + 800, obj.y, BODY + 0x280))
	h.equal("view.eyes_target", rig.target_goal(),
		_v(obj.x + 800 + 0x640, obj.y, BODY + 0x280 - 0x140))
	_frames = rig.view_map(obj)
	h.equal("view.map_mode", rig.view_mode(), CameraRig.View.MAP)
	h.equal("view.map_eye", rig.eye_goal(), _v(obj.x, obj.y, 24000),
		"15 m over the cell")
	h.equal("view.map_target", rig.target_goal(),
		_v(obj.x, obj.y + 0xC80, CameraRig.BOX_MARGIN),
		"a field further along y, at the object's height as the box clamps it")
	# docs/43 section 2's mode 0, the overview map: `fcn.004532A0` reads the
	# **box's** own centre and a constant height the box does not clamp. On a
	# 20x20 the box is 800..60800 on both axes, so the centre is 30800.
	_frames = rig.view_overview()
	h.equal("view.overview_mode", rig.view_mode(), CameraRig.View.SCRIPT)
	h.equal("view.overview_eye", rig.eye_goal(),
		_v(30800, 30800 - CameraRig.OVERVIEW_LEAN, CameraRig.OVERVIEW_HEIGHT),
		"the box's centre, a hundred units short on y, at 0x23A50")
	h.equal("view.overview_target", rig.target_goal(), _v(30800, 30800, 0),
		"straight down at the centre, and the target's z is a literal zero")
	h.check("view.overview_stands_above_the_ceiling",
		rig.eye_goal().z > CEILING,
		"the one placement the header's camera height does not cap")
	# The ride: the eye on the head, the target on the destination's head.
	rig.ride(obj, BODY, CameraRig.cell_object(7, 6, 0))
	h.equal("view.ride_eye", rig.eye(), _v(obj.x, obj.y, BODY))
	h.equal("view.ride_target", rig.target(), _v(7 * FIELD, 6 * FIELD, BODY))
	h.check("view.ride_is_immediate", not rig.is_flying())
	# Tracking sets the target and keeps the eye.
	rig.set_now(_v(0, 0, 8000), obj)
	rig.set_target_now(_v(100, 200, 300))
	h.equal("view.track_target", rig.target(), _v(100, 200, 300))
	h.equal("view.track_keeps_eye", rig.eye(), _v(0, 0, 8000))
	# The state round-trips, quadrant and view included.
	rig.set_now(_v(1, 2, 3), _v(4, 5, 6))
	rig.set_view_mode(CameraRig.View.MAP)
	var other: CameraRig = _flat_rig(20, 20)
	other.apply_state(rig.state())
	h.equal("view.state_eye", other.eye(), _v(1, 2, 3))
	h.equal("view.state_target", other.target(), _v(4, 5, 6))
	h.equal("view.state_mode", other.view_mode(), CameraRig.View.MAP)
	other.free()
	rig.free()


# --- docs/42 section 2.5, and the remake's zoom -----------------------------

func _check_pan_and_zoom(h: TestHarness) -> void:
	var rig: CameraRig = _flat_rig(20, 20)
	var obj: Vector3i = CameraRig.cell_object(10, 10, 0)
	# Looking along +y from the south: right is +x. Ten pixels at the
	# original's width are 4000 units, eye and target together, at once.
	rig.set_now(obj + _v(0, -8000, 6000), obj)
	rig.pan(Vector2(10.0, 0.0), 640.0)
	h.equal("pan.target_moves_right", rig.target(), obj + _v(4000, 0, 0))
	h.equal("pan.eye_moves_with_it", rig.eye(), obj + _v(4000, -8000, 6000))
	h.check("pan.is_immediate", not rig.is_flying())
	# Dragging down pulls the view back toward the eye.
	rig.set_now(obj + _v(0, -8000, 6000), obj)
	rig.pan(Vector2(0.0, 10.0), 640.0)
	h.equal("pan.drag_down_moves_back", rig.target(), obj + _v(0, -4000, 0))
	# Scaled to the window: twice the width, half the distance a pixel.
	rig.set_now(obj + _v(0, -8000, 6000), obj)
	rig.pan(Vector2(10.0, 0.0), 1280.0)
	h.equal("pan.scaled_to_width", rig.target(), obj + _v(2000, 0, 0))
	# Refused when the target would leave the box.
	rig.set_now(_v(1000, 900, 6000), _v(1000, 900 + 8000, 0))
	var before: Vector3i = rig.target()
	rig.pan(Vector2(0.0, 25.0), 640.0)
	h.equal("pan.refused_off_map", rig.target(), before,
		"10 000 units back would put the target under the map's edge")

	# Zoom scales the offset; in is always allowed down to 6400.
	rig.set_now(obj + _v(0, -8000, 6000), obj)
	rig.zoom_by(-1.0)
	rig.settle()
	var near: float = Vector3(rig.eye() - rig.target()).length()
	h.check("zoom.in_scales_offset", absf(near - 10000.0 / 1.15) < 40.0,
		"%.0f after one notch in from 10000" % near)
	for _i: int in range(20):
		rig.zoom_by(-1.0)
		rig.settle()
	var floor_d: float = Vector3(rig.eye() - rig.target()).length()
	h.check("zoom.never_under_min",
		floor_d >= float(CameraRig.MIN_DISTANCE) - 40.0,
		"%.0f, the floor is %d" % [floor_d, CameraRig.MIN_DISTANCE])
	# Out is refused when the eye would leave the box.
	rig.set_now(_v(1000, 900, 6000), _v(1000, 900 + 8000, 0))
	var eye_before: Vector3i = rig.eye_goal()
	rig.zoom_by(1.0)
	h.equal("zoom.out_refused_off_map", rig.eye_goal(), eye_before)
	rig.set_now(obj + _v(0, -8000, 6000), obj)
	rig.zoom_by(1.0)
	h.check("zoom.out_allowed_inside", rig.eye_goal() != obj + _v(0, -8000, 6000))
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
		"an ordinary letter is not a zoom input")
	h.equal("input.arrow_pan",
		[SliceMain.pan_delta_for_key(KEY_UP, false),
		SliceMain.pan_delta_for_key(KEY_DOWN, false),
		SliceMain.pan_delta_for_key(KEY_LEFT, true),
		SliceMain.pan_delta_for_key(KEY_RIGHT, true)],
		[Vector2(0.0, -SliceMain.PAN_KEY_PIXELS),
		Vector2(0.0, SliceMain.PAN_KEY_PIXELS),
		Vector2(-SliceMain.PAN_KEY_PIXELS, 0.0),
		Vector2(SliceMain.PAN_KEY_PIXELS, 0.0)])
	var wasd_moves: bool = false
	for keycode: int in [KEY_W, KEY_A, KEY_S, KEY_D]:
		wasd_moves = wasd_moves \
			or not SliceMain.pan_delta_for_key(keycode, false).is_zero_approx()
	h.check("input.wasd_is_not_camera_pan", not wasd_moves,
		"D/S/W belong to the command pad and A is unbound")


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


# --- docs/42 section 3.2 -----------------------------------------------------

func _check_walk_modes(h: TestHarness) -> void:
	h.equal("walk.own_is_1", CameraDirector.walk_mode(true, false, false),
		CameraDirector.WalkMode.OWN)
	h.equal("walk.seen_at_source_is_3",
		CameraDirector.walk_mode(false, true, true), CameraDirector.WalkMode.SEEN)
	h.equal("walk.seen_only_arriving_is_2",
		CameraDirector.walk_mode(false, false, true),
		CameraDirector.WalkMode.ARRIVING)
	h.equal("walk.unseen_is_0", CameraDirector.walk_mode(false, false, false),
		CameraDirector.WalkMode.NONE)
	# The `+0x0C > 6` discard of the destination's answer is `core`'s
	# (`test_execute_move.gd`): the two flags arrive here already decided.

	var rig: CameraRig = _flat_rig(20, 20)
	var director: CameraDirector = CameraDirector.create(rig)
	# Modes 1 and 3 track in the unit view, ride in the eyes view, and do
	# neither in the script and map views; mode 2 always rides.
	rig.set_view_mode(CameraRig.View.UNIT)
	h.check("walk.own_tracks_in_unit_view",
		director.tracks(CameraDirector.WalkMode.OWN)
		and not director.rides(CameraDirector.WalkMode.OWN))
	h.check("walk.seen_tracks_in_unit_view",
		director.tracks(CameraDirector.WalkMode.SEEN))
	rig.set_view_mode(CameraRig.View.EYES)
	h.check("walk.own_rides_in_eyes_view",
		director.rides(CameraDirector.WalkMode.OWN)
		and not director.tracks(CameraDirector.WalkMode.OWN))
	rig.set_view_mode(CameraRig.View.MAP)
	h.check("walk.map_view_neither",
		not director.tracks(CameraDirector.WalkMode.SEEN)
		and not director.rides(CameraDirector.WalkMode.SEEN))
	rig.set_view_mode(CameraRig.View.SCRIPT)
	h.check("walk.script_view_neither",
		not director.tracks(CameraDirector.WalkMode.OWN))
	h.check("walk.arriving_always_rides",
		director.rides(CameraDirector.WalkMode.ARRIVING))
	h.check("walk.none_neither",
		not director.tracks(CameraDirector.WalkMode.NONE)
		and not director.rides(CameraDirector.WalkMode.NONE))

	# Before the walk. Mode 1 in the unit view: the target flies to the
	# unit's head and the eye stays.
	var world: World = TestFixtures.tiny_world()
	var view: Dictionary = world.unit_view(0)
	var obj: Vector3i = CameraRig.cell_object(2, 2, 0)
	rig.set_view_mode(CameraRig.View.UNIT)
	rig.set_now(obj + _v(0, -8000, 6000), obj + _v(FIELD, 0, 0))
	var wait: float = director.before_walk(world, view, 2, 2, 4, 2,
		CameraDirector.WalkMode.OWN)
	h.check("walk.own_waits_for_flight", wait > 0.0, "%.2f s" % wait)
	h.equal("walk.own_target_to_head", rig.target_goal(), obj + _v(0, 0, BODY))
	h.equal("walk.own_eye_stays", rig.eye_goal(), obj + _v(0, -8000, 6000))
	# Mode 1 in the map view: nothing.
	rig.set_view_mode(CameraRig.View.MAP)
	rig.set_now(obj + _v(0, -8000, 6000), obj + _v(FIELD, 0, 0))
	wait = director.before_walk(world, view, 2, 2, 4, 2,
		CameraDirector.WalkMode.OWN)
	h.equal("walk.own_map_view_nothing", wait, 0.0)
	# Mode 3 with the camera low: `(6, 4, 0)` on the unit.
	rig.set_view_mode(CameraRig.View.UNIT)
	rig.set_now(obj + _v(0, -8000, 6000), obj)
	wait = director.before_walk(world, view, 2, 2, 4, 2,
		CameraDirector.WalkMode.SEEN)
	var expected: Dictionary = rig.place_on_unit(obj, BODY, Vector2i(0, 1),
		6, 4, 0)
	h.equal("walk.seen_low_camera_places", rig.eye_goal(),
		DictRead.as_vector3i(expected["eye"]),
		"the eye was at 6000, under 12 800")
	# Mode 3 with the camera high and the unit in sight: the target flight.
	rig.set_now(obj + _v(0, 8000, 16000), obj + _v(FIELD, 0, 0))
	wait = director.before_walk(world, view, 2, 2, 4, 2,
		CameraDirector.WalkMode.SEEN)
	h.equal("walk.seen_high_camera_tracks", rig.eye_goal(),
		obj + _v(0, 8000, 16000))
	h.equal("walk.seen_high_camera_target", rig.target_goal(),
		obj + _v(0, 0, BODY))
	# Mode 2: the eye to the unit's head, the target 160 under the head at
	# the destination.
	rig.set_now(obj + _v(0, -8000, 6000), obj)
	wait = director.before_walk(world, view, 2, 2, 4, 2,
		CameraDirector.WalkMode.ARRIVING)
	h.equal("walk.arriving_eye_at_head", rig.eye_goal(), obj + _v(0, 0, BODY))
	h.equal("walk.arriving_target", rig.target_goal(),
		CameraRig.cell_object(4, 2, 0) + _v(0, 0, BODY - 0xA0))
	# Tracking waits for the flight the walk is waiting for: a write during
	# it would cancel the target's half of `0x0040EDB0`.
	rig.set_view_mode(CameraRig.View.UNIT)
	rig.set_now(obj + _v(0, -8000, 6000), obj + _v(FIELD, 0, 0))
	wait = director.before_walk(world, view, 2, 2, 4, 2,
		CameraDirector.WalkMode.OWN)
	director.track(obj, BODY, CameraDirector.WalkMode.OWN,
		CameraRig.cell_object(4, 2, 0))
	h.check("walk.track_waits_for_flight", rig.is_flying()
		and rig.target() == obj + _v(FIELD, 0, 0)
		and rig.target_goal() == obj + _v(0, 0, BODY),
		"the target is still flying to the head, not snapped onto it")
	rig.settle()
	# Tracking and the ride, one frame each.
	rig.set_now(obj + _v(0, -8000, 6000), obj)
	director.track(_v(7000, 6400, 0), BODY, CameraDirector.WalkMode.OWN,
		CameraRig.cell_object(4, 2, 0))
	h.equal("walk.track_sets_target", rig.target(), _v(7000, 6400, BODY))
	h.equal("walk.track_keeps_eye", rig.eye(), obj + _v(0, -8000, 6000))
	director.track(_v(7000, 6400, 0), BODY, CameraDirector.WalkMode.ARRIVING,
		CameraRig.cell_object(4, 2, 0))
	h.equal("walk.ride_eye_on_head", rig.eye(), _v(7000, 6400, BODY))
	h.equal("walk.ride_looks_at_destination", rig.target(),
		CameraRig.cell_object(4, 2, 0) + _v(0, 0, BODY))
	rig.free()


# --- docs/42 section 4.3 -----------------------------------------------------

func _check_shots(h: TestHarness) -> void:
	var rig: CameraRig = _flat_rig(20, 20)
	var director: CameraDirector = CameraDirector.create(rig)
	var world: World = TestFixtures.tiny_world()
	var shooter: Dictionary = CameraDirector.unit_inputs(world, 0)
	var sobj: Vector3i = DictRead.as_vector3i(shooter["obj"])
	h.equal("shot.inputs_height", DictRead.as_int(shooter["height"]), BODY)
	h.equal("shot.inputs_not_large", DictRead.as_bool(shooter["large"]), false)

	# Without a viewport nothing projects, so the shooter is "not seen" and
	# the near branch decides: a victim two fields away puts the camera
	# behind the victim with `(5, 3, 1)`.
	var victim_cell: Dictionary = CameraDirector.inputs_at(world,
		world.unit_view(0), 4, 2)
	rig.set_now(sobj + _v(0, -8000, 6000), sobj)
	var wait: float = director.computer_shot(shooter, victim_cell, true)
	var behind_victim: Dictionary = rig.place_on_unit(
		DictRead.as_vector3i(victim_cell["obj"]), BODY, Vector2i(0, 1), 5, 3, 1)
	h.check("shot.near_victim_flies", wait > 0.0)
	h.equal("shot.near_behind_victim", rig.eye_goal(),
		DictRead.as_vector3i(behind_victim["eye"]))
	# An empty target cell: `(9, 5, 1)` behind the shooter.
	rig.set_now(sobj + _v(0, -8000, 6000), sobj)
	wait = director.computer_shot(shooter, victim_cell, false)
	var behind_shooter: Dictionary = rig.place_on_unit(sobj, BODY,
		Vector2i(0, 1), 9, 5, 1)
	h.equal("shot.near_empty_behind_shooter", rig.eye_goal(),
		DictRead.as_vector3i(behind_shooter["eye"]))
	# Same cell: only when the shooter is seen, which it cannot be here.
	rig.set_now(sobj + _v(0, -8000, 6000), sobj)
	wait = director.computer_shot(shooter, shooter, true)
	h.equal("shot.same_cell_unseen_nothing", wait, 0.0)
	# Far: four fields along x, the last cell of the 7-wide map. Back one
	# field from the shooter along the line, 1 m over its head, looking at
	# the target at the shooter's height.
	var far_cell: Dictionary = CameraDirector.inputs_at(world,
		world.unit_view(0), 2 + 4, 2)
	h.check("shot.far_cell_on_map", not far_cell.is_empty())
	rig.set_now(sobj + _v(0, -8000, 6000), sobj)
	wait = director.computer_shot(shooter, far_cell, true)
	h.equal("shot.far_eye", rig.eye_goal(),
		_v(sobj.x - 0xC80, sobj.y, sobj.z + BODY + 0x640))
	h.equal("shot.far_target", rig.target_goal(),
		DictRead.as_vector3i(far_cell["obj"]) + _v(0, 0, BODY))
	# A large shooter backs off 5600.
	var big: Dictionary = shooter.duplicate()
	big["large"] = true
	rig.set_now(sobj + _v(0, -8000, 6000), sobj)
	wait = director.computer_shot(big, far_cell, true)
	h.equal("shot.far_large_back", rig.eye_goal().x, sobj.x - 0x15E0)

	# The reaction: coin 5 and over goes behind the reactor, under 5 behind
	# the mover. Reactor at (2,2) facing the mover at (4,2), on a flat map,
	# so the slope is zero and the floor helper gives cell + body + 800.
	var mover: Dictionary = CameraDirector.unit_inputs(world, 1)
	var mobj: Vector3i = DictRead.as_vector3i(mover["obj"])
	rig.set_now(sobj + _v(0, -8000, 6000), sobj)
	wait = director.reaction_shot(world, shooter, mover, 5)
	h.equal("reaction.coin_5_behind_reactor", rig.eye_goal(),
		_v(sobj.x - 0x960, sobj.y, BODY + 800), "2400 back, raised to the floor")
	h.equal("reaction.coin_5_looks_at_mover", rig.target_goal(),
		mobj + _v(0, 0, BODY))
	wait = director.reaction_shot(world, shooter, mover, 4)
	h.equal("reaction.coin_4_behind_mover", rig.eye_goal(),
		_v(mobj.x + 0x960, mobj.y, BODY + 800))
	h.equal("reaction.coin_4_looks_at_reactor", rig.target_goal(),
		sobj + _v(0, 0, BODY))
	# The slope term: 4800 times the line's rise per unit of run. Put the
	# mover 3200 higher and the eye behind the reactor drops by 4800 * 1 --
	# and the floor helper then lifts it back to the floor.
	var raised: Dictionary = mover.duplicate()
	raised["obj"] = mobj + _v(0, 0, 3200)
	wait = director.reaction_shot(world, shooter, raised, 5)
	h.equal("reaction.slope_then_floor", rig.eye_goal().z, BODY - 2400 + 800,
		"BODY - 4800 * (3200 / 6400), over an empty floor cell, plus 800")
	# A large unit behind: 5600 back.
	var big_mover: Dictionary = mover.duplicate()
	big_mover["large"] = true
	wait = director.reaction_shot(world, shooter, big_mover, 4)
	h.equal("reaction.large_back", rig.eye_goal().x, mobj.x + 0x15E0)
	# The coin draws from the second stream, never the world's.
	var before: Dictionary = world.rng.state()
	var draws: Array[int] = []
	for _i: int in range(20):
		draws.append(director.toss())
	h.equal("reaction.coin_leaves_world_rng", world.rng.state(), before)
	var in_range: bool = true
	for d: int in draws:
		if d < 0 or d >= 10:
			in_range = false
	h.check("reaction.coin_in_0_10", in_range, str(draws))
	# `0x00453730`: the floor helper takes the highest of the cell and its
	# four neighbours under 16 000, plus the unit on the cell, plus 800.
	h.equal("reaction.floor_flat", CameraDirector.floor_height(world,
		_v(3 * FIELD, 3 * FIELD, 0)), 800)
	h.equal("reaction.floor_under_unit", CameraDirector.floor_height(world,
		_v(2 * FIELD, 2 * FIELD, 0)), BODY + 800)
	rig.free()


# --- docs/92 section 7.5.2 ---------------------------------------------------

## A turn that would take the eye out of the level is **refused** -- unless
## no quadrant fits at all, where refusing every direction would only trap
## the player. Over every field of `_C_140` at all four quadrants.
## A [ShotHost] over a real rig and the engine's tables, so an orbit's
## forty turns run the same arithmetic the camera does.
class RigHost extends ShotHost:
	var rig: CameraRig = null
	var geometry: Eng3dGeometry = null
	var object: Vector3i = Vector3i.ZERO
	var height: int = 0
	var last_offset: Vector3i = Vector3i.ZERO
	var sets: int = 0

	func object_of(_slot: int) -> Vector3i:
		return object

	func unit_height(_slot: int) -> int:
		return height

	func camera_eye() -> Vector3i:
		return rig.eye()

	func camera_target() -> Vector3i:
		return rig.target()

	func fly(eye_at: Vector3i, target_at: Vector3i) -> int:
		return rig.fly(eye_at, target_at)

	func camera_flying() -> bool:
		return rig.is_flying()

	func set_camera(eye_at: Vector3i, target_at: Vector3i) -> void:
		rig.set_now(eye_at, target_at)
		last_offset = eye_at - target_at
		sets += 1

	func rotate(v: Vector3i, angles: Vector3i) -> Vector3i:
		return geometry.rotate(v, angles)


## docs/42 section 7.5 -- the orbits' forty turns through `0x004039A0`
## on a real rig: `+100 * 40 = 4000` of 4096 for the skill orbit, `-40 *
## 40 = -1600` for the heal's, and the flight back to the six numbers
## read at the start (docs/97 section 31).
func _check_orbits(h: TestHarness) -> void:
	var geometry: Eng3dGeometry = Eng3dGeometry.from_cache(CacheFixture.cache_dir())
	if geometry == null or not geometry.is_loaded():
		h.check("orbit.tables", false, "no Eng3d tables in the cache")
		return
	for kind: String in [OrbitSequence.KIND_SKILL, OrbitSequence.KIND_HEAL]:
		var rig: CameraRig = _flat_rig(20, 20)
		var host: RigHost = RigHost.new()
		host.rig = rig
		host.geometry = geometry
		host.object = _v(5 * FIELD, 5 * FIELD, 0)
		host.height = BODY
		var eye0: Vector3i = host.object + _v(-9000, -12000, 8000)
		rig.set_now(eye0, host.object)
		var queue: SequenceQueue = SequenceQueue.create(null)
		var _bound: int = OrbitSequence.enqueue(queue, host, 0, kind, "", [])
		var frames: int = 0
		while queue.is_running() and frames < 2000:
			var _still: bool = queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
			var _flying: bool = rig.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
			frames += 1
		var spec: Dictionary = OrbitSequence.spec(kind)
		var start: Vector3i = spec["start"]
		var step: int = DictRead.as_int(spec["step"])
		h.equal("orbit.%s.sets_40" % kind, host.sets, OrbitSequence.FRAMES)
		h.equal("orbit.%s.offset_after_40_turns" % kind, host.last_offset,
			OrbitSequence.turned(host, start, step, OrbitSequence.FRAMES),
			"the same accumulation the sequence runs")
		var from: int = geometry.angle(start.x, start.y)
		var to: int = geometry.angle(host.last_offset.x, host.last_offset.y)
		var swept: int = posmod(to - from, WorldSpace.ANGLE_FULL_TURN)
		var expected: int = posmod(step * OrbitSequence.FRAMES,
			WorldSpace.ANGLE_FULL_TURN)
		h.check("orbit.%s.sweeps_%d" % [kind, step * OrbitSequence.FRAMES],
			absi(swept - expected) <= 8 or absi(swept - expected)
				>= WorldSpace.ANGLE_FULL_TURN - 8,
			"swept %d of 4096, expected %d" % [swept, expected])
		h.equal("orbit.%s.radius_kept" % kind,
			Eng3dGeometry.distance_2d(host.last_offset.x, host.last_offset.y)
				>= Eng3dGeometry.distance_2d(start.x, start.y) - 40, true,
			"the table arithmetic loses a little each turn, never a lot")
		h.equal("orbit.%s.flies_back" % kind, rig.eye_goal(), eye0,
			"the six numbers read at the start")
		h.check("orbit.%s.ends" % kind, not queue.is_running(),
			"%d frames" % frames)
		rig.free()


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
	var offset: Vector3i = _v(14 * METRE, 8 * METRE, 10 * METRE)
	var tested: int = 0
	var refused: int = 0
	var allowed_but_outside: int = 0
	var crowded: int = 0
	for y: int in range(height):
		for x: int in range(width):
			var obj: Vector3i = CameraRig.cell_object(x, y, heights[y * width + x])
			rig.set_now(obj + offset, obj)
			var fits: bool = false
			for q: int in range(4):
				var signs: Vector2i = CameraRig.QUADRANT_SIGNS[q]
				if rig.eye_is_inside(obj + _v(signs.x * offset.x,
						signs.y * offset.y, offset.z)):
					fits = true
			if not fits:
				crowded += 1
			for q: int in range(4):
				tested += 1
				var signs: Vector2i = CameraRig.QUADRANT_SIGNS[q]
				var eye_at: Vector3i = obj + _v(signs.x * offset.x,
					signs.y * offset.y, offset.z)
				if not rig.may_rotate_to(q):
					refused += 1
				elif not rig.eye_is_inside(eye_at) and fits:
					allowed_but_outside += 1
	h.check("bounds.tested", tested == width * height * 4,
		"%d field and quadrant combinations" % tested)
	h.equal("bounds.no_rotation_leaves_the_level", allowed_but_outside, 0,
		"every accepted turn ends with the eye inside")
	h.check("bounds.the_guard_bites", refused > 0,
		"%d of %d turns refused; %d fields where no quadrant fits"
			% [refused, tested, crowded])
	# `rotate_step` obeys the predicate, and a refused turn keeps the
	# quadrant -- a mutation once deleted the guard from the wiring and every
	# predicate check stayed green.
	var disobeyed: int = 0
	var refusals: int = 0
	for y: int in range(height):
		for x: int in range(width):
			var obj: Vector3i = CameraRig.cell_object(x, y, heights[y * width + x])
			rig.set_now(obj + offset, obj)
			for direction: int in [1, -1]:
				var before: int = rig.quadrant()
				var wanted: int = posmod(before + direction, 4)
				var allowed: bool = rig.may_rotate_to(wanted)
				rig.rotate_step(direction)
				if allowed != (rig.quadrant() != before):
					disobeyed += 1
				if not allowed:
					refusals += 1
				rig.settle()
	h.equal("bounds.rotate_step_obeys_the_guard", disobeyed, 0)
	h.check("bounds.refusals_were_exercised", refusals > 0,
		"%d refusals reached rotate_step" % refusals)
	rig.free()
	# The crowded escape hatch, on a map built to reach it: a pivot ringed by
	# 100 m walls, where every turn is allowed rather than none.
	var walls: PackedInt32Array = PackedInt32Array()
	walls.resize(9)
	walls.fill(100 * METRE)
	walls[4] = 0
	var boxed: CameraRig = CameraRig.new()
	boxed.setup(3, 3, walls, CEILING)
	var centre: Vector3i = CameraRig.cell_object(1, 1, 0)
	boxed.set_now(centre + _v(3000, 2000, 4000), centre)
	var all_allowed: bool = true
	var any_fits: bool = false
	for q: int in range(4):
		if not boxed.may_rotate_to(q):
			all_allowed = false
		var signs: Vector2i = CameraRig.QUADRANT_SIGNS[q]
		if boxed.eye_is_inside(centre + _v(signs.x * 3000, signs.y * 2000, 4000)):
			any_fits = true
	h.check("bounds.crowded_field_built", not any_fits)
	h.check("bounds.crowded_never_traps", all_allowed)
	boxed.free()


# --- docs/92 section 7.5.3 ---------------------------------------------------

## The view comes back to the player's own units when the computer is done,
## by a flight of the target with the eye's offset kept -- and the cycle on
## TAB offers exactly what a click may select.
func _hands_the_view_back(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("handback.mission", false, "_C_140 is not in the cache")
		return
	var world: World = loaded["world"]
	var rig: CameraRig = CameraRig.new()
	rig.setup(world.resource.width, world.resource.height,
		world.resource.heights(),
		DictRead.as_int(DictRead.as_dict(
			DictRead.as_dict(loaded["document"])["header"])["camera_height"]))
	# Where the replay left it: the corner opposite the squad.
	var corner: Vector3i = CameraRig.cell_object(0, 0, world.resource.heights()[0])
	var offset: Vector3i = _v(-9000, 7000, 12000)
	rig.set_now(corner + offset, corner)
	var slot: int = SliceMain.focus_on_friendly(rig, world)
	h.check("handback.found_a_unit", slot >= 0)
	var view: Dictionary = world.unit_view(slot)
	h.equal("handback.the_unit_is_the_players",
		DictRead.as_int(view["player"]), world.turn.current_player)
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	var cell: Vector3i = CameraRig.cell_object(x, y,
		world.state.height_at(world.state.index_of(x, y)))
	h.check("handback.flies", rig.is_flying() or rig.target() == cell,
		"a flight, not a snap")
	h.equal("handback.on_the_unit", rig.target_goal(), cell)
	h.equal("handback.offset_is_the_players", rig.eye_goal() - rig.target_goal(),
		offset, "the hand-over moves the target and nothing else")
	rig.settle()
	h.check("handback.arrives",
		absi(rig.target().x - cell.x) <= CameraRig.FLIGHT_STOP
		and absi(rig.target().y - cell.y) <= CameraRig.FLIGHT_STOP)

	# docs/29 section 3 command 14: the cycle.
	var seen: PackedInt32Array = PackedInt32Array()
	var at: int = -1
	for _i: int in range(8):
		at = SliceMain.next_friendly_slot(world, at)
		if at < 0 or seen.has(at):
			break
		seen.append(at)
	h.check("handback.cycle_reaches_the_squad", seen.size() >= 4,
		"%d units reachable by cycling: %s" % [seen.size(), str(seen)])
	var foreign: PackedInt32Array = PackedInt32Array()
	for reached: int in seen:
		if DictRead.as_int(world.unit_view(reached)["player"]) \
				!= world.turn.current_player:
			foreign.append(reached)
	h.equal("handback.cycle_stays_friendly", foreign.size(), 0)
	h.equal("handback.cycle_wraps",
		SliceMain.next_friendly_slot(world, seen[seen.size() - 1]), seen[0])
	var nobody: int = world.turn.current_player
	world.turn.current_player = 7
	h.equal("handback.no_units_no_view",
		SliceMain.next_friendly_slot(world, -1), -1)
	world.turn.current_player = nobody
	# The cycle's own placement is the engine's `(8, 7, 0)`.
	var director: CameraDirector = CameraDirector.create(rig)
	var wait: float = director.cycle(world, slot)
	var inputs: Dictionary = CameraDirector.unit_inputs(world, slot)
	var g: Vector3i = DictRead.as_vector3i(inputs["gradient"])
	var expected: Dictionary = rig.place_on_unit(
		DictRead.as_vector3i(inputs["obj"]), DictRead.as_int(inputs["height"]),
		Vector2i(g.x, g.y), 8, 7, 0)
	h.check("handback.cycle_places_8_7_0",
		rig.eye_goal() == DictRead.as_vector3i(expected["eye"]) and wait >= 0.0)
	rig.free()
	_cycle_is_the_click_gate(h)


## The cycle offers exactly what a click may select, and nothing else.
##
## Owner alone is not the rule: [method World.may_command] -- `0x00477DF0`,
## which `0x00453CF0` walks -- also refuses a friendly record with no hit
## points and a hidden one, and a dead squad member stays in `unit_slots()`
## with the fog pass leaving an own corpse fully visible. A cycle filtered on
## the player byte would therefore step to a body the mouse refuses, and the
## hand-back would park the camera on it. A synthetic map, because `_C_140`
## opens with four live marines and would not tell the two apart.
func _cycle_is_the_click_gate(h: TestHarness) -> void:
	var units: Array = [
		TestFixtures.unit(0, 2, 2),
		TestFixtures.unit(1, 3, 2),
		TestFixtures.unit(2, 4, 2, 0, 0, 4, UnitState.VISIBILITY_HIDDEN),
		TestFixtures.unit(3, 5, 2, 0, 1),
	]
	var world: World = World.create(TestFixtures.map_document(7, 7, units),
		TestFixtures.balance(), 1.0)
	world.turn.current_player = 0
	# **The corpse is made here rather than authored.** `World.create` drops a
	# record with no hit points -- [method UnitState.is_placed] is `hp != 0` --
	# so a squad member that is dead in the map document never enters
	# `unit_slots()` at all and would not exercise this. One that dies during
	# play does, which is the case that matters, and reaching it through the
	# combat model would make a camera check depend on a die roll.
	world._units[1].hp = 0
	var offered: PackedInt32Array = PackedInt32Array()
	var at: int = -1
	for _i: int in range(6):
		at = SliceMain.next_friendly_slot(world, at)
		if at < 0 or offered.has(at):
			break
		offered.append(at)
	h.equal("handback.cycle_is_the_click_gate", offered,
		PackedInt32Array([0]),
		"the live own unit only: not the corpse (slot 1), not the hidden "
		+ "one (slot 2), not the other player's (slot 3)")
	var refused: PackedInt32Array = PackedInt32Array()
	for slot: int in [1, 2, 3]:
		if world.may_command(slot):
			refused.append(slot)
	h.equal("handback.the_gate_agrees_with_the_click", refused,
		PackedInt32Array(),
		"World.may_command refuses the same three, so the two paths cannot "
		+ "drift apart")
