class_name TouchInputController
extends Node

## Own touch sequences before GUI input. Mouse presses are deliberately delayed:
## a finger beginning a camera gesture must never spend a soldier's points.
## Physical mouse input still follows the original path.
var host: SliceMain = null
var gestures: Gesture = Gesture.new()
var _available: bool = false
var _sending: bool = false
var _region: String = ""
var _control: Control = null
var _context: Array = []
var _slider_down: bool = false
var _scroll_carry: float = 0.0
var _layer: CanvasLayer = null
var _menu: Button = null
var _tooltip: Control = null
var _font_choice: int = -1
## The engine height a one-finger pan holds, fixed when the finger lands.
##
## One plane for the whole drag: a cell's own height changes from field to
## field, and re-reading it under a moving finger would make the ground swim.
var _pan_plane: float = 0.0


func _ready() -> void:
	_available = DisplayServer.is_touchscreen_available()
	gestures.action.connect(_action)
	_layer = CanvasLayer.new()
	_layer.layer = MissionHud.HUD_LAYER + 1
	add_child(_layer)
	_menu = Button.new()
	_menu.text = host._strings.text("touch.menu")
	_menu.position = Vector2(8, 8)
	_menu.size = Vector2(44, 24)
	_menu.add_theme_font_size_override("font_size", 10)
	# Use the same field face as Options, fitted into the unused left corner.
	var decorator: CampaignScreen = CampaignScreen.new()
	decorator.art = host._art
	var _width: float = decorator.dress_button(_menu, 44, Art.BUTTON_BASE_FIELD)
	decorator.free()
	# Full menu fields reserve wide end caps as text padding. This compact
	# field occupies the corner before x=60, where the HUD hint begins.
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		var box: StyleBox = _menu.get_theme_stylebox(state)
		# A cache with no art leaves `dress_button` with nothing to override,
		# and the box then answered is the **default theme's**, shared by every
		# `Button` in the project. Writing margins into it would repad all of
		# them, so take a copy of that one and own it.
		if not _menu.has_theme_stylebox_override(state):
			box = box.duplicate()
			_menu.add_theme_stylebox_override(state, box)
		box.content_margin_left = 4
		box.content_margin_right = 4
		box.content_margin_top = 2
		box.content_margin_bottom = 2
		if box is StyleBoxTexture:
			var texture: StyleBoxTexture = box
			texture.texture_margin_left = 8
			texture.texture_margin_right = 8
	_menu.size = Vector2(44, 24)
	_layer.add_child(_menu)
	_menu.pressed.connect(host._toggle_shell)
	get_viewport().size_changed.connect(cancel)
	_sync_menu()


func enabled() -> bool:
	return host != null and (host.settings.control_mode == GameSettings.ControlMode.TOUCH \
		or (host.settings.control_mode == GameSettings.ControlMode.AUTO and _available))


func _sync_menu() -> void:
	var choice: int = int(host.settings.game_font)
	if choice != _font_choice:
		_font_choice = choice
		if choice == 1 and host._hud._text_font != null:
			_menu.add_theme_font_override("font", host._hud._text_font)
		else:
			_menu.remove_theme_font_override("font")
	_menu.size = Vector2(44, 24)
	_menu.visible = enabled() and host._screen == null and host.in_mission() \
		and not host._hud.info_visible()


func _current_context() -> Array:
	return [host._screen, host.world, host._playback.is_running(),
		host._hud != null and host._hud.info_visible(), host.settings.control_mode]


func _process(delta: float) -> void:
	_sync_menu()
	if not _context.is_empty() and _context != _current_context():
		cancel()
	gestures.tick(delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_APPLICATION_PAUSED:
		cancel()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN \
			or what == NOTIFICATION_APPLICATION_RESUMED:
		# Some platforms discard releases while suspended. Unknown drags/releases
		# after resume are ignored; only a new press may begin another gesture.
		gestures.reset()


func cancel() -> void:
	gestures.cancel()
	if _slider_down:
		# Release outside every control to cancel GUI capture without activating it.
		_mouse_button(Vector2(-1000, -1000), false)
	_slider_down = false
	_control = null
	_context = []
	_hide_tooltip()


func _input(event: InputEvent) -> void:
	if _sending:
		return
	if not (event is InputEventScreenTouch or event is InputEventScreenDrag):
		# Native touch backends can also send gesture events. Do not zoom twice;
		# genuine trackpad gestures with no fingers owned here retain their path.
		if (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION) \
				or (not gestures.fingers.is_empty() and (event is InputEventPanGesture \
				or event is InputEventMagnifyGesture \
				)):
			get_viewport().set_input_as_handled()
		return
	get_viewport().set_input_as_handled()
	if not _context.is_empty() and _context != _current_context():
		cancel()
	if event is InputEventScreenTouch:
		var touch: InputEventScreenTouch = event
		if touch.pressed and gestures.fingers.is_empty():
			if event.device != InputEvent.DEVICE_ID_EMULATION:
				_available = true
			_begin(touch.position)
		gestures.touch(touch.index, touch.position, touch.pressed, touch.canceled)
	else:
		var drag: InputEventScreenDrag = event
		gestures.drag(drag.index, drag.position)


func _begin(at: Vector2) -> void:
	_context = _current_context()
	_scroll_carry = 0.0
	gestures.reset()
	gestures.allow_hold = enabled()
	gestures.allow_camera = false
	if _tooltip != null:
		_hide_tooltip()
		_region = "dismiss"
		return
	_motion(at)
	_control = get_viewport().gui_get_hovered_control()
	_region = "gui"
	var ancestor: Node = _control
	while ancestor != null:
		if ancestor is Slider:
			_control = ancestor as Control
			_region = "slider"
			gestures.allow_hold = false
			return
		ancestor = ancestor.get_parent()
	if host._screen != null:
		var screen: CampaignScreen = host._screen
		var view_size: Vector2 = get_viewport().get_visible_rect().size
		var plate_at: Vector2 = at * CampaignScreen.PLATE_SIZE / view_size
		if screen.takes_world_clicks() and screen.plate_window().has_point(plate_at) \
				and _control == null:
			_region = "world"
		elif screen.scrolls() and plate_at.y >= 60.0 and plate_at.y < 400.0 \
				and not (_control is LineEdit):
			_region = "list"
	elif host._hud != null and not host._hud.info_visible():
		var on_ring: bool = _control != null and host._hud.ring.is_ancestor_of(_control)
		if on_ring or (_control == null and host._hud.window().has_point(at)):
			_region = "world"
		if host._playback.is_running() and _control != _menu:
			_region = "replay" if host._watching_the_computer() else "blocked"
	gestures.allow_camera = enabled() and _region == "world"
	if gestures.allow_camera:
		_pan_plane = _plane_under(at)


## The engine height a pan holds: the floor of the cell the finger came down
## on, and the camera target's own height where it came down on no cell.
func _plane_under(at: Vector2) -> float:
	var rig: CameraRig = host._backdrop_rig if host._screen != null else host._rig
	if rig == null:
		return 0.0
	var world: World = host._backdrop_world if host._screen != null else host.world
	if world != null:
		var cell: Vector2i = SliceMain.cell_under(rig.camera(), world, at, 1.0)
		if cell.x >= 0:
			return float(DictRead.as_int(world.cell_view(cell.x, cell.y)["height"]))
	return float(rig.target().z)


func _action(kind: String, value: Vector2) -> void:
	if kind == "end":
		if _slider_down:
			_mouse_button(value, false)
			_slider_down = false
		_release_pointer()
		return
	if _region in ["dismiss", "blocked"]:
		return
	if kind == "tap":
		if _region == "replay":
			var key: InputEventKey = InputEventKey.new()
			key.keycode = KEY_SPACE
			key.pressed = true
			host._unhandled_input(key)
			return
		if _control != null and (not is_instance_valid(_control) \
				or not _control.is_visible_in_tree()):
			return
		_motion(value)
		_mouse_button(value, true)
		_mouse_button(value, false)
	elif kind == "hold":
		if _region != "replay":
			_show_hint(value)
	elif kind == "drag":
		if _region == "slider":
			if not _slider_down:
				_mouse_button(gestures.origin, true)
				_slider_down = true
			_motion(gestures.position, MOUSE_BUTTON_MASK_LEFT)
		elif enabled() and _region == "list" and host._screen != null:
			_scroll_carry -= value.y / 24.0
			var rows: int = int(_scroll_carry)
			_scroll_carry -= rows
			if rows != 0:
				host._screen.step_rows(rows)
				host._remember_slot_page()
		elif gestures.allow_camera:
			_camera("pan", value)
	elif gestures.allow_camera:
		_camera(kind, value)


## Take the synthetic pointer off the screen when the finger leaves it.
##
## A [Button] wears its hover face until a motion moves off it, and the faces
## composed out of `buttons.LIB` draw `hover` and `pressed` with the **same**
## lit picture ([method CampaignScreen._face_onto]) -- so the row a finger last
## touched went on looking exactly as selected as the row that actually was,
## and running a finger down a list left a picture reading as several
## selections at once. Nothing rests anywhere on a touch screen; this says so.
func _release_pointer() -> void:
	if not enabled():
		return
	_motion(Vector2(-1000.0, -1000.0))


func _camera(kind: String, value: Vector2) -> void:
	if host._playback.is_running():
		return
	var backdrop: bool = host._screen != null and host._backdrop_root != null
	var rig: CameraRig = host._backdrop_rig if backdrop else host._rig
	if rig == null:
		return
	match kind:
		"zoom":
			rig.zoom_by(value.x)
		"turn":
			if not backdrop:
				rig.rotate_step(int(value.x))
		"twist":
			if backdrop:
				host._swing_backdrop(Vector2(value.x * 64.0, 0))
		"pan":
			if backdrop:
				host._swing_backdrop(value)
			elif rig.view_mode() == CameraRig.View.EYES:
				# **First person is an anchor, not a viewpoint that slides.**
				# The pan moves eye and target together, so in the eyes view a
				# finger drag walked the camera off the soldier it belongs to
				# -- and one direction parked it behind him, looking at the
				# back of his head. A mouse reaches that only through a middle
				# drag nobody makes in first person; a finger drag is the
				# gesture. Here it turns the head instead, which is what the
				# two-finger look already does and what the view is for.
				rig.look_by(value)
			else:
				_drag_ground(rig, value)
		"look":
			if backdrop:
				host._swing_backdrop(value)
			else:
				rig.look_by(value)


## One finger on the ground is **direct manipulation**: the field the finger
## came down on stays under it.
##
## [method CameraRig.pan] is the original's rate -- 400 engine units a pixel,
## docs/42 section 2.5 -- and it is the *pointer's*: the camera follows the
## mouse, so the picture slides the other way, and at 3200 units to a field
## eight pixels of travel move the world a whole field. Both of those are
## right for a pointer and wrong for a finger, which is holding the ground and
## not the camera. So the shift is measured instead: where the two ends of this
## frame's travel meet the plane the target stands on, carried back.
func _drag_ground(rig: CameraRig, delta: Vector2) -> void:
	var render: Vector2 = get_viewport().get_visible_rect().size
	var to: Vector2 = gestures.position
	var here: PackedVector2Array = rig.ground_point(to, render, _pan_plane)
	var was: PackedVector2Array = rig.ground_point(to - delta, render, _pan_plane)
	if here.is_empty() or was.is_empty():
		# Edge-on, or the plane is behind the eye: there is no ground under the
		# finger to hold. Keep the pointer's rate, negated, so the direction is
		# still the finger's.
		rig.pan(-delta, render.x)
		return
	var shift: Vector2i = Vector2i(roundi(was[0].x - here[0].x),
		roundi(was[0].y - here[0].y))
	if rig.pan_units(shift):
		return
	# At the map's edge the box refuses the pair as one thing, and a diagonal
	# drag along the border then moved nothing at all. Offer the components
	# separately: the one that is still inside is still the finger's.
	var _x: bool = rig.pan_units(Vector2i(shift.x, 0))
	var _y: bool = rig.pan_units(Vector2i(0, shift.y))


func _motion(at: Vector2, mask: int = 0) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	motion.button_mask = mask
	motion.relative = at - host._pointer
	_push(motion)


func _mouse_button(at: Vector2, pressed: bool) -> void:
	var button: InputEventMouseButton = InputEventMouseButton.new()
	button.position = at
	button.global_position = at
	button.button_index = MOUSE_BUTTON_LEFT
	button.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	button.pressed = pressed
	_push(button)


func _push(event: InputEvent) -> void:
	_sending = true
	get_viewport().push_input(event, true)
	_sending = false


func _show_hint(at: Vector2) -> void:
	_motion(at)
	var area: Control = _control if is_instance_valid(_control) else null
	while area != null:
		if area is HintControl and not area.tooltip_text.is_empty():
			var hint: HintControl = area
			_tooltip = hint._make_custom_tooltip(hint.tooltip_text) as Control
			_layer.add_child(_tooltip)
			_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var limits: Vector2 = get_viewport().get_visible_rect().size
			var extent: Vector2 = _tooltip.get_combined_minimum_size()
			_tooltip.position = Vector2(clampf(at.x - extent.x * 0.5, 0, maxf(0, limits.x - extent.x)),
				maxf(0, at.y - extent.y - 24))
			# End the engine's hover timer; otherwise its transient popup appears
			# on top of our persistent copy a moment after the finger is lifted.
			_motion(Vector2(-1000, -1000))
			return
		area = area.get_parent() as Control
	# HUD buttons already publish their caption into the original top hint line.
	# A world hold likewise keeps the existing hover overlay; neither clicks.


func _hide_tooltip() -> void:
	if is_instance_valid(_tooltip):
		_tooltip.queue_free()
	_tooltip = null


class Gesture extends RefCounted:
	signal action(kind: String, value: Vector2)
	const SLOP: float = 8.0
	const HOLD: float = 0.45
	## A pair is a twist rather than a pinch past this much rotation, and a
	## pinch rather than a twist past this much change of separation.
	##
	## The twist is tested **first and at a lower bar**: two fingers turning
	## about their centre cannot hold their separation to better than a few per
	## cent, so at the old 15 degrees against 8 per cent almost every turn was
	## classified as a zoom before it had turned far enough to say otherwise --
	## which is what made the camera step "almost never work".
	const TWIST_RADIANS: float = deg_to_rad(8.0)
	const PINCH_FRACTION: float = 0.15
	## How far a pair already reading as a pinch or a parallel drag has to turn
	## before it is read as a twist after all.
	##
	## The first classification used to be final, so a turn that opened with a
	## few per cent of separation change -- which is most of them -- was a
	## pinch for the rest of the gesture and the camera could not be turned
	## without lifting both fingers and trying again. The bar is well above
	## [constant TWIST_RADIANS] because this one overrides a reading that has
	## already been made.
	const ESCALATE_RADIANS: float = deg_to_rad(20.0)
	## How far a twist turns before it asks the camera for another quarter.
	##
	## Measured from the span at the **last** step rather than from the one the
	## pair began with, so a continued turn keeps stepping. It used to latch
	## after one, which left a gesture good for a single quarter and -- with
	## [method CameraRig.may_rotate_to] free to refuse that one -- looked like a
	## turn that only worked one way round.
	const TURN_RADIANS: float = deg_to_rad(18.0)
	var fingers: Dictionary[int, Vector2] = {}
	var origin: Vector2 = Vector2.ZERO
	var position: Vector2 = Vector2.ZERO
	var allow_camera: bool = false
	var allow_hold: bool = true
	var state: String = "idle"
	var _age: float = 0.0
	var _centre: Vector2 = Vector2.ZERO
	var _span: Vector2 = Vector2.ZERO
	var _last_centre: Vector2 = Vector2.ZERO
	var _last_span: Vector2 = Vector2.ZERO
	## The separation at the last quarter-turn this twist asked for.
	var _turn_anchor: Vector2 = Vector2.ZERO
	var _pair_dirty: bool = false

	func reset() -> void:
		fingers.clear()
		state = "idle"
		_age = 0.0
		_turn_anchor = Vector2.ZERO
		_pair_dirty = false

	func cancel() -> void:
		# Keep ids until their releases arrive: resuming with a finger still down
		# must not turn its eventual release into a fresh click.
		state = "canceled"

	func touch(index: int, at: Vector2, pressed: bool, canceled: bool = false) -> void:
		if canceled:
			cancel()
		if pressed:
			fingers[index] = at
			if state == "canceled":
				return
			if fingers.size() == 1:
				origin = at
				position = at
				state = "tap"
				_age = 0.0
			elif fingers.size() == 2 and allow_camera:
				state = "two"
				var points: Array[Vector2] = fingers.values()
				_span = points[1] - points[0]
				_centre = (points[0] + points[1]) * 0.5
				_last_span = _span
				_last_centre = _centre
			else:
				cancel()
			return
		if not fingers.has(index):
			return
		_flush_pair()
		if fingers.size() == 1 and state == "tap" and at.distance_to(origin) <= SLOP:
			action.emit("tap", at)
		var _erased: bool = fingers.erase(index)
		if fingers.is_empty():
			action.emit("end", at)
			state = "idle"
		else:
			cancel()

	func tick(delta: float) -> void:
		_flush_pair()
		if state != "tap" or not allow_hold:
			return
		_age += delta
		if _age >= HOLD:
			state = "hold"
			action.emit("hold", position)

	func drag(index: int, at: Vector2) -> void:
		if not fingers.has(index):
			return
		fingers[index] = at
		if state in ["canceled", "hold", "idle"]:
			return
		if fingers.size() == 1:
			var previous: Vector2 = position
			position = at
			if state == "tap" and origin.distance_to(at) > SLOP:
				state = "drag"
				previous = origin
			if state == "drag":
				action.emit("drag", at - previous)
			return
		_pair_dirty = true

	func _flush_pair() -> void:
		if not _pair_dirty or fingers.size() != 2 or state in ["canceled", "idle"]:
			return
		_pair_dirty = false
		# Platforms deliver one finger's motion at a time. Classify a frame's
		# pair together, otherwise a parallel drag first looks like a pinch.
		var points: Array[Vector2] = fingers.values()
		var span: Vector2 = points[1] - points[0]
		var centre: Vector2 = (points[0] + points[1]) * 0.5
		var angle: float = _span.angle_to(span)
		if state == "two":
			if absf(angle) >= TWIST_RADIANS:
				state = "twist"
				_turn_anchor = _span
			elif _span.length() > 1 \
					and absf(span.length() / _span.length() - 1) >= PINCH_FRACTION:
				state = "zoom"
			elif centre.distance_to(_centre) > SLOP:
				state = "look"
		elif state in ["zoom", "look"] and absf(angle) >= ESCALATE_RADIANS:
			state = "twist"
			_turn_anchor = _span
		match state:
			"zoom":
				if span.length() > 1 and _last_span.length() > 1:
					action.emit("zoom", Vector2(-6.0 * log(span.length() / _last_span.length()), 0))
			"look":
				action.emit("look", centre - _last_centre)
			"twist":
				action.emit("twist", Vector2(_last_span.angle_to(span), 0))
				var since: float = _turn_anchor.angle_to(span)
				if absf(since) >= TURN_RADIANS:
					_turn_anchor = span
					action.emit("turn", Vector2(signf(since), 0))
		if state != "two":
			_last_centre = centre
			_last_span = span
