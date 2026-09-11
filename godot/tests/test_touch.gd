extends TestSuite

## Remake input contract, not an oracle for the original executable.
func run(h: TestHarness) -> void:
	h.begin("touch", TestHarness.ORACLE_SPEC)
	var g: TouchInputController.Gesture = TouchInputController.Gesture.new()
	var events: Array[String] = []
	var values: Array[Vector2] = []
	g.action.connect(func(kind: String, value: Vector2) -> void:
		events.append(kind)
		values.append(value))
	g.touch(0, Vector2(100, 100), true)
	h.equal("down.does_not_click", events.size(), 0)
	g.drag(0, Vector2(103, 100))
	g.touch(0, Vector2(103, 100), false)
	h.equal("tap.once_after_release", events, ["tap", "end"])
	events.clear()
	g.touch(0, Vector2(100, 100), true)
	g.drag(0, Vector2(120, 100))
	g.touch(0, Vector2(120, 100), false)
	h.equal("drag.never_clicks", events, ["drag", "end"])
	events.clear()
	g.touch(0, Vector2(100, 100), true)
	g.tick(0.44)
	h.equal("hold.waits", events.size(), 0)
	g.tick(0.02)
	g.tick(1)
	g.touch(0, Vector2(100, 100), false)
	h.equal("hold.inspect_without_click", events, ["hold", "end"])
	events.clear()
	g.touch(0, Vector2.ZERO, true)
	g.touch(0, Vector2.ZERO, false, true)
	h.equal("os_cancel.no_click", events, ["end"])
	events.clear()
	g.touch(0, Vector2.ZERO, true)
	g.cancel()
	g.touch(1, Vector2(100, 0), true)
	g.touch(0, Vector2.ZERO, false)
	g.touch(1, Vector2(100, 0), false)
	h.equal("focus_loss.all_fingers_must_lift", events, ["end"])
	events.clear()
	g.allow_camera = true
	g.touch(0, Vector2.ZERO, true)
	g.touch(1, Vector2(100, 0), true)
	g.drag(1, Vector2(120, 0))
	g.tick(0)
	h.check("pinch.zoom", events.has("zoom"))
	var zoom: Vector2 = values.back()
	h.check("spread.zooms_in", zoom.x < 0)
	g.touch(1, Vector2(120, 0), false)
	g.drag(0, Vector2(100, 100))
	g.touch(0, Vector2(100, 100), false)
	h.check("pinch.remainder_never_clicks", not events.has("tap") and not events.has("drag"))
	events.clear()
	g.touch(0, Vector2.ZERO, true)
	g.touch(1, Vector2(100, 0), true)
	g.drag(1, Vector2(100, 0).rotated(deg_to_rad(12)))
	g.tick(0)
	h.check("twist.deadzone_before_quadrant", not events.has("turn"))
	g.drag(1, Vector2(100, 0).rotated(deg_to_rad(30)))
	g.tick(0)
	g.drag(1, Vector2(100, 0).rotated(deg_to_rad(70)))
	g.tick(0)
	# **A quadrant per step of the turn, not one per gesture.** The step is
	# measured from the separation at the last one, so a finger that keeps
	# turning keeps asking; it used to latch after the first, which left the
	# camera reachable only as far as one quarter a gesture.
	h.equal("twist.quadrant_per_step", events.count("turn"), 2)
	h.check("twist.does_not_zoom", not events.has("zoom"))
	# `values` is not cleared beside `events`, so the quadrants are collected
	# on their own rather than read out of it by index.
	var turns: Array[float] = []
	g.action.connect(func(kind: String, value: Vector2) -> void:
		if kind == "turn":
			turns.append(value.x))
	g.drag(1, Vector2(100, 0).rotated(deg_to_rad(110)))
	g.tick(0)
	h.equal("twist.turns_with_the_fingers", turns.size(), 1)
	# ...and back the other way, in the same gesture: both signs reach the rig.
	g.drag(1, Vector2(100, 0).rotated(deg_to_rad(60)))
	g.tick(0)
	h.equal("twist.reverses", turns, [turns[0], -turns[0]] as Array[float],
		"a turn back is the other quadrant, not a second one the same way")
	g.touch(0, Vector2.ZERO, false)
	g.touch(1, Vector2(100, 0).rotated(deg_to_rad(20)), false)
	events.clear()
	# **The twist is read before the pinch and at a lower bar.** Two fingers
	# turning about their centre cannot hold their separation to better than a
	# few per cent, so the old 15 degrees against 8 per cent classified almost
	# every turn as a zoom before it had turned far enough to say otherwise.
	g.touch(0, Vector2.ZERO, true)
	g.touch(1, Vector2(100, 0), true)
	g.drag(1, Vector2(105, 0).rotated(deg_to_rad(12)))
	g.tick(0)
	h.check("twist.survives_a_small_pinch",
		events.has("twist") and not events.has("zoom"))
	g.touch(0, Vector2.ZERO, false)
	g.touch(1, Vector2(105, 0).rotated(deg_to_rad(12)), false)
	events.clear()
	g.touch(0, Vector2.ZERO, true)
	g.touch(1, Vector2(100, 0), true)
	g.drag(1, Vector2(118, 0).rotated(deg_to_rad(4)))
	g.tick(0)
	h.check("pinch.survives_a_small_twist",
		events.has("zoom") and not events.has("twist"))
	g.touch(0, Vector2.ZERO, false)
	g.touch(1, Vector2(118, 0).rotated(deg_to_rad(4)), false)
	events.clear()
	turns.clear()
	# **A pinch that turns far enough becomes a turn.** The first reading used
	# to be final, so a turn opening with a few per cent of separation change
	# -- which is most of them -- stayed a pinch until both fingers lifted.
	g.touch(0, Vector2.ZERO, true)
	g.touch(1, Vector2(100, 0), true)
	g.drag(1, Vector2(118, 0))
	g.tick(0)
	h.check("escalate.begins_as_a_pinch", events.has("zoom"))
	g.drag(1, Vector2(118, 0).rotated(deg_to_rad(25)))
	g.tick(0)
	h.equal("escalate.a_turned_pinch_is_a_twist", turns.size(), 1)
	g.touch(0, Vector2.ZERO, false)
	g.touch(1, Vector2(118, 0).rotated(deg_to_rad(25)), false)
	events.clear()
	g.touch(0, Vector2.ZERO, true)
	g.touch(1, Vector2(200, 0), true)
	for step: int in range(1, 8):
		g.drag(0, Vector2(step * 25, 0))
		g.drag(1, Vector2(200 + step * 25, 0))
		g.tick(0)
	h.check("parallel_drag.look", events.has("look"))
	h.check("parallel_drag.no_zoom_or_turn", not events.has("zoom") and not events.has("turn"))
	g.touch(2, Vector2(100, 100), true)
	events.clear()
	g.drag(1, Vector2(400, 0))
	g.touch(0, Vector2.ZERO, false)
	g.touch(1, Vector2(400, 0), false)
	g.touch(2, Vector2(100, 100), false)
	h.equal("third_finger.cancels", events, ["end"])
	# A touch setting changes no deterministic world or campaign state.
	var settings: GameSettings = GameSettings.new()
	h.equal("settings.default_auto", int(settings.control_mode), 0)
	settings.path = "user://touch-settings-test.json"
	settings.control_mode = GameSettings.ControlMode.TOUCH
	h.check("settings.written", settings.save_to_disk())
	var loaded: GameSettings = GameSettings.new()
	loaded.path = settings.path
	h.check("settings.read", loaded.load_from_disk())
	h.equal("settings.mode_persists", loaded.control_mode, GameSettings.ControlMode.TOUCH)
	var legacy: Dictionary = settings.view()
	var _erased: bool = legacy.erase("control_mode")
	var file: FileAccess = FileAccess.open(settings.path, FileAccess.WRITE)
	file.store_string(JSON.stringify(legacy))
	file.close()
	h.check("settings.legacy_read", loaded.load_from_disk())
	h.equal("settings.legacy_defaults_auto", loaded.control_mode, GameSettings.ControlMode.AUTO)
	legacy["control_mode"] = 999
	file = FileAccess.open(settings.path, FileAccess.WRITE)
	file.store_string(JSON.stringify(legacy))
	file.close()
	h.check("settings.invalid_mode_read", loaded.load_from_disk())
	h.equal("settings.invalid_mode_defaults_auto", loaded.control_mode, GameSettings.ControlMode.AUTO)
	var _removed: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(settings.path))
	var host: SliceMain = SliceMain.new()
	var controller: TouchInputController = TouchInputController.new()
	controller.host = host
	h.check("auto.desktop", not controller.enabled())
	controller._available = true
	h.check("auto.touch_available", controller.enabled())
	host.settings.control_mode = GameSettings.ControlMode.MOUSE
	h.check("manual.mouse_wins", not controller.enabled())
	host.settings.control_mode = GameSettings.ControlMode.TOUCH
	controller._available = false
	h.check("manual.touch_wins", controller.enabled())
	controller.free()
	host.free()
