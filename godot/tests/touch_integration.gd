extends SceneTree

## Real viewport dispatch and rendered hit targets. Run separately because the
## corpus harness is synchronous. Use -- --mission=_C_140; no player saves used.
##
## Its scratch files go to `user://` under names of its own: an absolute macOS
## temp path would have made the screenshot check fail on Linux for an
## environment reason rather than a real one.
var game: ProbeMain = null
var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 960)
	root.content_scale_size = Vector2i(640, 480)
	game = ProbeMain.new()
	game.settings.path = "user://inc-touch-integration-settings.json"
	game.settings.control_mode = GameSettings.ControlMode.TOUCH
	game._debug_build = false
	root.add_child(game)
	await _frames()
	_check("mission loaded", game.world != null)
	if game.world == null:
		quit(1)
		return
	game.campaign.save_dir = "user://inc-touch-integration-saves"
	game.settings.control_mode = GameSettings.ControlMode.TOUCH
	await _frames()
	_check("touch Menu visible", game._touch._menu.visible)
	var before: String = game.world.canonical_hash_hex()
	var centre: Vector2 = game._hud.window().get_center()
	_down(0, centre)
	_check("down does not issue a command", game.world.canonical_hash_hex() == before)
	_drag(0, centre + Vector2(25, 0))
	_up(0, centre + Vector2(25, 0))
	_check("drag does not issue a command", game.world.canonical_hash_hex() == before)
	await _frames()
	_down(0, centre)
	game._touch.gestures.tick(0.5)
	_up(0, centre)
	_check("hold does not issue a command", game.world.canonical_hash_hex() == before)
	await _frames()
	# A real Control consumes exactly one synthesized click and a drag consumes
	# none, even though both begin on the same button.
	var button: Button = Button.new()
	button.position = Vector2(200, 100)
	button.size = Vector2(100, 40)
	var layer: CanvasLayer = CanvasLayer.new()
	layer.layer = 30
	layer.add_child(button)
	root.add_child(layer)
	var presses: Array[int] = [0]
	button.pressed.connect(func() -> void: presses[0] += 1)
	await _frames()
	_tap(Vector2(240, 120))
	_check("GUI tap exactly once", presses[0] == 1)
	_down(0, Vector2(240, 120))
	_drag(0, Vector2(270, 120))
	_up(0, Vector2(270, 120))
	_check("GUI drag never presses", presses[0] == 1)
	var hint: HintControl = HintControl.over(button, "Touch fixture", null, 10, Color.WHITE)
	await _frames()
	_down(0, Vector2(240, 120))
	game._touch.gestures.tick(0.5)
	_up(0, Vector2(240, 120))
	_check("hold shows existing tooltip", game._touch._tooltip != null)
	_check("hold on GUI never presses", presses[0] == 1)
	_tap(Vector2(240, 120))
	_check("tooltip dismissal consumes tap", presses[0] == 1 and game._touch._tooltip == null)
	hint.queue_free()
	var slider: HSlider = HSlider.new()
	slider.position = Vector2(200, 180)
	slider.size = Vector2(150, 30)
	layer.add_child(slider)
	await _frames()
	_down(0, Vector2(210, 195))
	_drag(0, Vector2(330, 195))
	_up(0, Vector2(330, 195))
	_check("slider drag changes value", slider.value > 50)
	layer.queue_free()
	await _frames()
	_tap(game._touch._menu.position + game._touch._menu.size * 0.5)
	await _frames()
	_check("Menu opens pause shell", game.shell.is_up())
	game.close_shell()
	await _frames()
	game._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	_check("system Back opens menu without quitting", game.shell.is_up() and not game._quitting and not quit_on_go_back)
	# Back inside the shell is the shell's own Back button. It used to be
	# `_toggle_shell`, which refuses whenever the shell is up with nothing
	# behind it -- so every screen the boot menu leads to answered nothing.
	game._on_shell_choice("options")
	await _frames()
	game._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await _frames()
	_check("system Back leaves a shell screen",
		game.shell.screen == ShellHost.SCREEN_MENU and not game._quitting)
	game._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await _frames()
	_check("system Back leaves the shell over a mission",
		not game.shell.is_up() and not game._quitting)
	game.close_shell()
	await _frames()
	# Select a real friendly unit through a touch ray, not a direct callback.
	var slot: int = SliceMain.next_friendly_slot(game.world, -1)
	var _selected: MoveMapResult = game.select_unit(slot, false)
	game._set_view(CameraRig.View.MAP)
	game._rig.settle()
	await _frames()
	var view: Dictionary = game.world.unit_view(slot)
	var at: Vector2 = _cell(DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))
	game._deselect()
	print("TOUCH PICK: slot=%d at=%s window=%s hit=%d" % [slot, at, game._hud.window(), game._unit_under(game._ray_at(at))])
	_tap(at)
	print("TOUCH PICK RESULT: selected=%d region=%s control=%s mode=%s" % [game._selected, game._touch._region, game._touch._control, game._touch.gestures.state])
	_check("touch selects friendly", game._selected == slot)
	_tap(at)
	await _frames()
	_check("second tap opens original ring", game._hud.ring.is_up())
	var letter: Array = game._hud.ring.report()
	if letter.size() == DirectionRing.RECORDS:
		var cancel_letter: Array = letter[DirectionRing.CANCEL_RECORD]
		_tap(Vector2(DictRead.as_float(cancel_letter[0]), DictRead.as_float(cancel_letter[1])) + Vector2(2, 2))
		_check("ring cancel is touchable", not game._hud.ring.is_up())
	# Inspect a visible alien, then feed both negative controls and a tap to
	# the same real ray. The overridden counter still calls the production shot.
	var enemy: int = -1
	for candidate: int in game.world.unit_slots():
		var unit: Dictionary = game.world.unit_view(candidate)
		if not SliceMain.is_a_target(unit, game.turn_player()):
			continue
		var _flight: float = game._director.view_map(game.world,
			DictRead.as_int(unit["x"]), DictRead.as_int(unit["y"]))
		game._rig.settle()
		at = _cell(DictRead.as_int(unit["x"]), DictRead.as_int(unit["y"]))
		if game._unit_under(game._ray_at(at)) == candidate and game._hud.window().has_point(at):
			enemy = candidate
			break
	_check("visible enemy fixture available", enemy >= 0)
	if enemy >= 0:
		await _frames()
		before = game.world.canonical_hash_hex()
		var camera_state: Dictionary = game._rig.state()
		_down(0, at)
		game._touch.gestures.tick(0.5)
		_up(0, at)
		_check("enemy hold spends nothing", game.attacks == 0 and game.world.canonical_hash_hex() == before)
		_down(0, at)
		_drag(0, at + Vector2(30, 0))
		_up(0, at + Vector2(30, 0))
		_check("enemy drag spends nothing", game.attacks == 0 and game.world.canonical_hash_hex() == before)
		game._rig.apply_state(camera_state)
		await _frames()
		_tap(at)
		_check("enemy tap invokes exactly one production attack", game.attacks == 1)
		await _idle()
	# The live list rebuilds its controls during a swipe; releasing the finger
	# must not select whichever row has replaced the original one.
	var list: MissionSelectScreen = game.open_shell(ShellHost.SCREEN_MISSION_SELECT) as MissionSelectScreen
	list.missions = game._missions
	list.refresh()
	await _frames()
	var selection: String = list.selected
	_down(0, Vector2(250, 230))
	_drag(0, Vector2(250, 170))
	_up(0, Vector2(250, 170))
	_check("list swipes without selecting", list.first_row > 0 and list.selected == selection)
	game.close_shell()
	await _frames()
	# A context change between down/up cannot click through the new screen.
	_down(0, centre)
	var _options: CampaignScreen = game.open_shell(ShellHost.SCREEN_OPTIONS)
	_up(0, centre)
	_check("screen transition cancels pending tap", game._screen == _options)
	game.close_shell()
	await _frames()
	for canvas: Vector2i in [Vector2i(640, 480), Vector2i(768, 480)]:
		root.size = canvas * 2
		root.content_scale_size = canvas
		await _frames()
		_check("Menu clear of hint %s" % str(canvas), game._touch._menu.get_rect().end.x <= 60)
		print("TOUCH MENU: ", game._touch._menu.get_rect())
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			var screenshot: Image = root.get_texture().get_image()
			var saved: Error = screenshot.save_png("user://inc-touch-%dx%d.png" % [canvas.x, canvas.y])
			_check("screenshot written", saved == OK)
	await _campaign_flow()
	print("TOUCH-INTEGRATION: %d checks, %d failures" % [checks, failures])
	var _shutdown_frames: int = await game._audio.shutdown()
	game.queue_free()
	await _frames()
	quit(0 if failures == 0 else 1)


func _idle() -> void:
	for _frame: int in range(1800):
		if not game._playback.is_running() and not game._picture_busy():
			return
		await process_frame
	_check("playback completed before timeout", false)


func _campaign_flow() -> void:
	game._end_campaign()
	await _frames()
	await _press("campaign")
	await _press("start:1")
	for _frame: int in range(600):
		if game._screen is CampaignMapScreen:
			break
		if game._screen is SequenceScreen:
			_tap(Vector2(320, 240))
		await process_frame
	_check("campaign map reached by touch", game._screen is CampaignMapScreen)
	if not (game._screen is CampaignMapScreen):
		return
	var map: CampaignMapScreen = game._screen as CampaignMapScreen
	var location: int = -1
	for id: int in game.campaign.open_locations():
		if game.campaign.tables.kind_of(id) == CampaignMap.KIND_BATTLE and map.location_cells.has(id):
			location = id
			break
	_check("battle location exists", location >= 0)
	if location < 0:
		return
	var cell: Vector2i = map.location_cells[location]
	var view: Dictionary = game._backdrop_world.cell_view(cell.x, cell.y)
	var point: Vector2 = game._backdrop_rig.camera().unproject_position(
		WorldSpace.cell_centre(cell.x, cell.y, DictRead.as_int(view["height"])))
	_tap(point)
	await _frames()
	print("TOUCH MAP: location=%d point=%s region=%s screen=%s" % [location, point, game._touch._region, game._screen])
	_check("map location opens briefing", game._screen is BriefingScreen)
	if not (game._screen is BriefingScreen):
		return
	await _press("enter")
	_check("briefing leads to deployment", game._screen is SelectUnitsScreen)
	if not (game._screen is SelectUnitsScreen):
		return
	var landings: Array[Vector2i] = game._free_landings()
	var placed: int = 0
	for landing: Vector2i in landings:
		var deploy: SelectUnitsScreen = game._screen as SelectUnitsScreen
		if deploy.selected == Roster.NO_SLOT:
			break
		_tap(_cell(landing.x, landing.y))
		placed += 1
		await _frames()
	_check("squad deployed with touches", placed > 0)
	await _press("start")
	await _idle()
	_check("touch campaign entered mission", game._screen == null and game.in_mission())
	if game._screen != null:
		return
	await _move_and_end_turn()
	_tap(game._touch._menu.get_rect().get_center())
	await _frames()
	await _press("save")
	await _press("slot:0")
	var slots: SaveSlotsScreen = game._screen as SaveSlotsScreen
	_check("save name editor accepts touch", slots != null and slots.naming == 0)
	if slots == null or slots.naming != 0:
		return
	# The software keyboard itself needs device validation. Deliver its text
	# and submit through the same LineEdit signal, without a hardware key.
	slots._field.text = "Touch integration"
	slots._field.text_submitted.emit(slots._field.text)
	await _frames()
	_check("touch save reached disk", game.campaign.has_save(0))
	await _press("back")
	await _press("load")
	await _press("slot:0")
	await _frames()
	_check("touch load restores mission", game.in_mission() and not game.shell.is_up())


func _move_and_end_turn() -> void:
	await _hud_press(HudTables.EVENT_MAP_VIEW)
	game._rig.settle()
	await _frames()
	var selected: int = game._selected
	_check("campaign selects a deployed marine", selected >= 0)
	if selected < 0 or game._last_query == null:
		return
	var before: Dictionary = game.world.unit_view(selected)
	var destination: Vector2i = Vector2i(-1, -1)
	var best: int = 1000000
	for y: int in range(game._last_query.height):
		for x: int in range(game._last_query.width):
			if not game._last_query.is_reachable(x, y):
				continue
			var cost: int = game._last_query.cost_to(x, y)
			var point: Vector2 = _cell(x, y)
			if cost > 0 and cost < best and game._hud.window().has_point(point) \
					and game._unit_under(game._ray_at(point)) < 0:
				destination = Vector2i(x, y)
				best = cost
	_check("visible reachable destination", destination.x >= 0)
	if destination.x < 0:
		return
	_tap(_cell(destination.x, destination.y))
	await _frames()
	_check("destination opens direction ring", game._hud.ring.is_up())
	if not game._hud.ring.is_up():
		return
	var letter: TextureRect = game._hud.ring._letters[0]
	_tap(letter.get_global_rect().get_center())
	var committed: String = game.world.canonical_hash_hex()
	var playing: bool = game._playback.is_running()
	_tap(game._hud.window().get_center())
	_check("own movement cannot be skipped by touch", playing and game._playback.is_running()
		and game.world.canonical_hash_hex() == committed)
	await _idle()
	var after: Dictionary = game.world.unit_view(selected)
	_check("movement reached requested cell", Vector2i(DictRead.as_int(after["x"]),
		DictRead.as_int(after["y"])) == destination)
	_check("movement spent action points", DictRead.as_int(after["mp"]) < DictRead.as_int(before["mp"]))
	var turn: int = game.world.turn.turn
	await _hud_press(HudTables.EVENT_NEXT_PLAYER)
	if game._playback.is_running() and game._watching_the_computer():
		committed = game.world.canonical_hash_hex()
		_tap(game._hud.window().get_center())
		_check("enemy replay skip preserves resolved world", not game._playback.is_running()
			and game.world.canonical_hash_hex() == committed)
	await _idle()
	_check("end turn advances game", game.world.turn.turn > turn)


func _hud_press(event: int) -> void:
	for slot: Vector2i in game._hud.columns._events:
		if game._hud.columns._events[slot] == event:
			var button: TextureButton = game._hud.columns._buttons[slot]
			_check("HUD event available %d" % event, not button.disabled)
			_tap(button.get_global_rect().get_center())
			await _frames()
			return
	_check("HUD event exists %d" % event, false)


func _press(action: String) -> void:
	var button: Button = _action_button(game._screen, action)
	_check("button available: " + action, button != null)
	if button != null:
		_tap(button.get_global_rect().get_center())
	await _frames()


func _action_button(node: Node, action: String) -> Button:
	if node == null:
		return null
	if node is Button:
		var button: Button = node
		for entry: Dictionary in button.pressed.get_connections():
			var callback: Callable = entry["callable"]
			if callback.get_bound_arguments().has(action) and not button.disabled:
				return button
	for child: Node in node.get_children():
		var found: Button = _action_button(child, action)
		if found != null:
			return found
	return null


class ProbeMain extends SliceMain:
	var attacks: int = 0

	func attack_cell(x: int, y: int) -> AttackResult:
		attacks += 1
		return super.attack_cell(x, y)


func _cell(x: int, y: int) -> Vector2:
	var view: Dictionary = game.world.cell_view(x, y)
	return game._rig.camera().unproject_position(WorldSpace.cell_centre(x, y,
		DictRead.as_int(view["height"])))


func _frames() -> void:
	for _frame: int in range(3):
		await process_frame


func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
	print("TOUCH %s: %s" % ["OK" if passed else "FAIL", label])


func _tap(at: Vector2) -> void:
	_down(0, at)
	_up(0, at)


func _down(index: int, at: Vector2) -> void:
	var event: InputEventScreenTouch = InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = true
	root.push_input(event, true)


func _up(index: int, at: Vector2) -> void:
	var event: InputEventScreenTouch = InputEventScreenTouch.new()
	event.index = index
	event.position = at
	root.push_input(event, true)


func _drag(index: int, at: Vector2) -> void:
	var event: InputEventScreenDrag = InputEventScreenDrag.new()
	event.index = index
	event.position = at
	root.push_input(event, true)
