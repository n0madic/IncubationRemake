class_name SliceMain
extends Node3D

## The slice, end to end: load the cache, build a [World], draw it, and let a
## click submit a movement query.
##
## docs/92 section 10.2 item 4: `game` renders terrain, placed scenery and
## units, then highlights the result -- and **scene nodes never become the
## authoritative position, occupancy or movement state**.  Every rebuild reads
## the world's views; nothing is read back off a node.

## The mission shown when nothing else is asked for.  Every mission the cache
## contains can be shown; `--mission=NAME` on the command line picks one, and
## `[` / `]` step through them at run time.
## `_C_140` is the mission this stage plays: the first one whose squad, aliens
## and win conditions are all in the `.lev`, so it can be won without the
## campaign layer (docs/94).
const DEFAULT_MISSION: String = "_C_140"
const MISSION_ARG: String = "--mission="
## Where a development run finds the same bytes production reads from `user://`.
const DEV_CACHE: String = "res://generated/cache"

var world: World = null

var _missions: PackedStringArray = PackedStringArray()
var _mission: String = ""
var _geometry_cache: Dictionary = {}
var _texture_cache: Dictionary = {}
var _scene_root: Node3D = null
var _scenery: Scenery = null
var _overlay: TerrainOverlay = null
var _highlight: Highlight = null
var _units: UnitsView = null
var _rig: CameraRig = null
## How far out the view opens, in metres. Chosen to clear the ceiling of the
## interiors the demo missions are: see [method _frame_units].
const OPENING_ZOOM_METRES: float = 8.0
## docs/60 section 5 -- the largest of the four shipped fonts, 17 px.
const GAME_FONT: String = "font_2"
## How many rendered frames the engine spends crossing one map field.
##
## **Measured, and it was a guess before.** `aExecuteMove`'s two walk helpers,
## `0x0040EA30` and `0x0040EBB0`, take the vector between the two cells,
## divide each axis by **six** (`0x2AAAAAAB`, the signed magic for a division
## by 6), set a loop counter to six, and per iteration set the object's
## position and call `fcn.0040B6F0` -- the gameplay frame routine, the one the
## skip controller caps at `(10, 20)` fps (docs/40 section 4.8). A field is six
## frames, and since gameplay advances animation time by one key unit per
## rendered frame it is also six frames of the walk cycle.
const FRAMES_PER_FIELD: int = 6

## How long a body takes to cross one map field while walking.
##
## Not a taste setting any more: it is the six frames above, at the rate
## [constant CharismaState.FRAMES_PER_SECOND] plays gameplay clips, which is
## the same loop's own nominal cap. 0.3 s a field is 6.7 m/s over the 2 m a
## field is.
##
## It was 0.16 through slice 4, which is within rounding of what the original's
## **epoch bug** produced (the cap enforced every other frame, so ~40 fps and
## ~0.15 s a field). Following the bug made every walk read as a sprint.
const WALK_SECONDS_PER_STEP: float = \
	float(FRAMES_PER_FIELD) / CharismaState.FRAMES_PER_SECOND
var _status: Label = null
var _hud: Hud = null
var _strings: Localization = null
var _selected: int = -1
var _cache_dir: String = ""
var _geometry: Dictionary = {}
var _textures: Dictionary = {}
## The computer's turn, played back one event at a time. `core` decided the
## whole thing before this exists; the playback only shows it.
var _playback: AIPlayback = AIPlayback.new()
var _ai_note: String = ""


## An exported build made with the `run_tests` custom feature runs the suites
## and quits, so docs/92 section 10.4's "demonstrated in an exported build" is
## the same suites against the same cache rather than a second, weaker claim.
const TEST_FEATURE: String = "run_tests"
const TEST_RUNNER: String = "res://tests/runner.gd"


func _ready() -> void:
	if OS.has_feature(TEST_FEATURE) and _run_tests_and_quit():
		return
	_status = Label.new()
	# Below the HUD, which owns the top of the screen.
	_status.position = Vector2(12.0, 120.0)
	var layer: CanvasLayer = CanvasLayer.new()
	layer.add_child(_status)
	add_child(layer)

	var opened: Dictionary = CacheLoader.open_active()
	if DictRead.as_bool(opened["ok"]):
		_cache_dir = DictRead.as_string(opened["cache_dir"])
	elif DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DEV_CACHE)) \
			or FileAccess.file_exists(DEV_CACHE + "/manifest.json"):
		_cache_dir = DEV_CACHE
	else:
		_fail(DictRead.as_string(opened["reason"]))
		return

	var manifest: Dictionary = CacheLoader.read_json(
		_cache_dir + "/manifest.json")
	var problems: PackedStringArray = CacheLoader.verify(_cache_dir, manifest)
	if not problems.is_empty():
		_fail("cache refused: " + ", ".join(problems))
		return
	_missions = _missions_in(manifest)
	if _missions.is_empty():
		_fail("the cache at %s contains no missions" % _cache_dir)
		return
	# The strings come before anything that says one. docs/92 section 7.6: a
	# localization seam retrofitted later means finding every literal.
	_strings = Localization.from_cache(_cache_dir, manifest)
	_hud = Hud.new(_strings)
	# docs/60 -- the game's own bitmap font, the 17 px one. A cache built by an
	# older converter has no fonts and the HUD stays on Godot's default.
	_hud.use_font(GameFont.load_from(_cache_dir, GAME_FONT))
	add_child(_hud)
	_build(_wanted_mission())


## The missions the manifest declares, in the order the converter emitted them.
func _missions_in(manifest: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var names: Array = DictRead.as_array(manifest.get("missions", []))
	for entry: Variant in names:
		out.append(DictRead.as_string(entry))
	return out


## `--mission=NAME`, from either side of a `--` separator, else the default.
## An unknown name falls back rather than failing: the cache is the authority
## on what exists, and it names them in the status line.
func _wanted_mission() -> String:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for arg: String in args:
		if arg.begins_with(MISSION_ARG):
			var name: String = arg.substr(MISSION_ARG.length())
			if _missions.has(name):
				return name
			push_warning("no mission %s in the cache; showing %s"
				% [name, DEFAULT_MISSION])
	if _missions.has(DEFAULT_MISSION):
		return DEFAULT_MISSION
	return _missions[0]


## The runner is loaded by path, never named as a class: the shipping preset
## excludes `tests/`, and a `TestRunner` identifier here would stop `main.gd`
## itself from compiling in that build -- which is exactly what happened once,
## and is why the shipping export is now launched as part of verifying a change.
func _run_tests_and_quit() -> bool:
	if not ResourceLoader.exists(TEST_RUNNER):
		push_warning("%s asked for tests, but %s is not in this build"
			% [TEST_FEATURE, TEST_RUNNER])
		return false
	var script: GDScript = ResourceLoader.load(TEST_RUNNER, "GDScript") \
		as GDScript
	if script == null or not script.can_instantiate():
		push_warning("%s did not load" % TEST_RUNNER)
		return false
	get_tree().quit(DictRead.as_int(script.call("run_all")))
	return true


func _fail(reason: String) -> void:
	_status.text = reason
	push_error(reason)


## Builds one mission.  Called again for every mission switch, so it frees the
## previous scene first: the whole visible tree is rebuilt from the world's
## views, and nothing is carried across.  Geometry and textures are kept per
## world set, because two of the slice's three missions share `A00`.
func _build(mission: String) -> void:
	if _scene_root != null:
		remove_child(_scene_root)
		_scene_root.free()
	# `queue_free` is deferred, so the tree is torn down with `free()` -- which
	# means every handle into it is dangling the instant it returns.  They are
	# cleared here rather than only reassigned at the end, because `_build` has
	# an early return: leaving them set while `world` still held the previous
	# mission let `_unhandled_input`'s `world == null` guard pass and then call
	# into a freed node.
	_scene_root = null
	_scenery = null
	_overlay = null
	_highlight = null
	_units = null
	_rig = null
	world = null
	_selected = -1
	_mission = mission

	var balance: Dictionary = CacheLoader.read_json(
		_cache_dir + "/tables/balance.json")
	var map_document: Dictionary = CacheLoader.read_json(
		"%s/missions/%s/map.json" % [_cache_dir, mission])
	if balance.is_empty() or map_document.is_empty():
		_fail("cache does not contain %s" % mission)
		return

	world = World.create(map_document, balance, 1.0)
	# The mission's own program, so the turn runs the script the way the engine
	# does. A mission with none still plays: `attach_script` returns false and
	# `World`'s default runner lets every hand-over through.
	var attached: bool = world.attach_script(CacheLoader.read_json(
		"%s/missions/%s/script.json" % [_cache_dir, mission]))
	# `INIT MAP` is the entry point the loader runs once, before any turn
	# (docs/20 section 5), and it is what names the successor map.
	if attached:
		var _init_map: Dictionary = world.run_init_map()
	var header: Dictionary = DictRead.as_dict(map_document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	var geometry: Dictionary = _geometry_for(world_set)
	var textures: Dictionary = _textures_for(world_set)
	_geometry = geometry
	_textures = textures

	_scene_root = Node3D.new()
	_scene_root.name = "Mission_" + mission
	add_child(_scene_root)

	_scenery = Scenery.new()
	_scenery.name = "Scenery"
	_scene_root.add_child(_scenery)
	_scenery.build(map_document, geometry, textures)

	_overlay = TerrainOverlay.new()
	_overlay.name = "TerrainOverlay"
	_scene_root.add_child(_overlay)
	_overlay.build(world.terrain_snapshot())

	_highlight = Highlight.new()
	_highlight.name = "Highlight"
	_scene_root.add_child(_highlight)

	_units = UnitsView.new()
	_units.name = "Units"
	# The bodies and their clips, opened once per mission. `UnitsView.build`
	# runs on every fog change, and re-parsing a 26-part body or re-building
	# its meshes each time would be a cost this slice invented for itself.
	_units.library = CharismaLibrary.open(_cache_dir, textures, mission)
	_scene_root.add_child(_units)
	_units.build(world, geometry, textures)

	_rig = CameraRig.new()
	_rig.name = "CameraRig"
	_scene_root.add_child(_rig)
	_rig.setup(world.resource.width, world.resource.height,
		world.resource.heights(), world.resource.camera_height)
	_rig.camera().current = true
	_frame_units(world)

	var environment: WorldEnvironment = WorldEnvironment.new()
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color8(18, 20, 26)
	environment.environment = env
	_scene_root.add_child(environment)

	_refresh_status()


func _geometry_for(world_set: String) -> Dictionary:
	if not _geometry_cache.has(world_set):
		_geometry_cache[world_set] = CacheLoader.read_json(
			"%s/geometry/%s.json" % [_cache_dir, world_set])
	return DictRead.as_dict(_geometry_cache[world_set])


func _textures_for(world_set: String) -> Dictionary:
	if not _texture_cache.has(world_set):
		var index: Dictionary = CacheLoader.read_json(
			"%s/textures/%s/index.json" % [_cache_dir, world_set])
		_texture_cache[world_set] = MeshBuilder.load_textures(
			_cache_dir, world_set, index)
	return DictRead.as_dict(_texture_cache[world_set])


## Steps to another mission in the cache, wrapping at both ends.
func show_mission(step: int) -> void:
	if _missions.size() < 2:
		return
	var at: int = _missions.find(_mission)
	_build(_missions[posmod(at + step, _missions.size())])


## Submits the movement query for one slot and highlights the answer.
## Public because a screenshot or a demo run drives the same path a click does;
## the scene never becomes the source of the selection either way.
func select_unit(slot: int, pass_friendlies: bool) -> MoveMapResult:
	_selected = slot
	var result: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(slot, pass_friendlies))
	_highlight.show_result(result, world.resource.heights())
	var view: Dictionary = world.unit_view(slot)
	# docs/29 section 3's command 2 is "execute the selected-unit/map **focus**
	# path": selecting a unit puts the camera on it. The yaw and the zoom are
	# the player's and are kept -- [method CameraRig.focus_on] moves the pivot
	# and nothing else -- so a selection re-centres the view without throwing
	# away how the player had arranged it.
	_focus_on_unit(view)
	_refresh_status("slot %d %s: %d reachable, %d warp, mp %d, pf %s" % [
		slot, DictRead.as_string(view["name"]), result.reachable_count(),
		result.warp_count(), result.mp, str(pass_friendlies)])
	return result


func selected_slot() -> int:
	return _selected


## Select the next unit the current player owns, and look at it.
##
## docs/29 section 3's command 14. It is the only way to reach a unit that is
## off screen: the view has no pan, so a squad member the camera is not
## pointing at cannot be clicked. Returns the slot, or -1 when there is none.
func cycle_friendly() -> int:
	var slot: int = next_friendly_slot(world, _selected)
	if slot < 0:
		return -1
	var _map: MoveMapResult = select_unit(slot, false)
	return slot


## Put the camera pivot on a unit, from the view dictionary that names it.
##
## One place, because three callers want it: a selection, the AI playback
## stepping to the next thing the computer did, and a mission switch.
func _focus_on_unit(view: Dictionary) -> void:
	if _rig == null or view.is_empty():
		return
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	if not world.state.in_bounds(x, y):
		return
	_rig.focus_on(x, y, world.state.height_at(world.state.index_of(x, y)))


func camera_rig() -> CameraRig:
	return _rig


## Open the camera on the player's squad rather than on the map's centre.
##
## [method CameraRig.setup] parks the pivot on the middle cell, which is where
## the mission happens to have put its geometry and not where the player's
## units are: on `_C_140` the centre is inside a support column, so the first
## frame of the game is a close-up of a pillar.
##
## This is what the original does: on load it shows the squad, close, rather
## than the middle of the map from under the ceiling.
##
## Two things were wrong with the old opening view and each had to be fixed
## separately, which is why the first attempt made it worse rather than better:
##
## * **the pivot.** `CameraRig.setup` parks it on the middle cell, which is
##   where the mission happens to have put its geometry -- on `_C_140` that is
##   inside a support column. The squad is what the player is about to act
##   with, so the view opens there instead. It is **one unit's cell, not the
##   squad's centroid**: a centroid is not a cell anybody stands on, and the
##   mean of `_C_140`'s four marines lands inside the wall between them;
## * **the zoom.** `setup` opens at the mission's authored `camera_height`,
##   20 m on `_C_140`, and at 20 m the camera sits **above the level's roof**
##   and looks down through it -- these maps are interiors. So moving the pivot
##   alone still showed a ceiling, and 12 m still showed the dark side of one.
##   [constant OPENING_ZOOM_METRES] puts the camera under it.
##
## The maximum is untouched: the player can still pull out to what the mission
## authored. This is where the view *starts*. The yaw is left alone too -- it
## is the player's, on Q and E.
##
## Nothing here is authoritative and nothing here is simulation: a camera that
## opened somewhere else would change no hash and no result.
func _frame_units(mission_world: World) -> void:
	# **One unit's cell, not the squad's centroid.** The centroid is not a cell
	# anybody stands on: on `_C_140` the mean of four marines lands inside the
	# wall between them, and the camera opens in the dark. A unit's own cell is
	# somewhere the simulation has already agreed is standable and open.
	if focus_on_friendly(_rig, mission_world) < 0:
		return
	_rig.set_zoom(minf(_rig.max_zoom, OPENING_ZOOM_METRES))
	# The one place the rig turns by itself: at load there is no previous view
	# to preserve, so an opening yaw that puts the eye inside a wall is simply
	# replaced by the nearest one that does not.
	_rig.choose_yaw()


## The next unit the current player may command, after `after` and wrapping.
##
## docs/29 section 3's command **14** -- "cycle the selected friendly unit"
## (`0x00453CF0`) -- which the engine binds to a key and which this remake did
## not have at all. `after` of -1 asks for the first; -1 comes back when the
## current player has nothing on the map it may command.
##
## **The gate is [method World.may_command], the same one a click goes
## through**, because `0x00453CF0` walks `0x00477DF0` and that is what
## `0x00477DF0` is. Owner alone is not enough: a dead squad member stays in
## `unit_slots()` and the fog pass leaves an own corpse fully visible, so a
## cycle that filtered on the player byte would offer a body the mouse
## refuses -- and the hand-back below would park the camera on it.
##
## A contact is excluded on top of that even though a friendly one cannot
## occur: the rule is "a cell the player can click", and [method
## Fog.is_contact] is what decides that everywhere else.
static func next_friendly_slot(mission_world: World, after: int) -> int:
	var slots: PackedInt32Array = mission_world.unit_slots()
	var start: int = slots.find(after) + 1
	for step: int in range(slots.size()):
		var slot: int = slots[(start + step) % slots.size()]
		if not mission_world.may_command(slot):
			continue
		var view: Dictionary = mission_world.unit_view(slot)
		if view.is_empty() or not Fog.is_drawn(view) or Fog.is_contact(view):
			continue
		return slot
	return -1


## Put the camera pivot on the current player's first unit. Returns the slot,
## or -1 when there is nothing to look at and the view is left alone.
##
## **This is what ends the computer's turn**, and it is the remake's decision
## rather than a traced one: docs/29 section 3's command 2 is the engine's
## selected-unit/map focus path, but that the engine runs it on hand-over is
## **UNVERIFIED**. What is not a decision is the problem it solves.
##
## The replay leads the camera to every alien it shows ([method _on_ai_step]),
## and there is no way to pan -- the only things that move the pivot are a
## selection and this. So a replay that finished at the far corner of the map
## left the player looking at an empty floor with their own squad off screen
## and nothing on it to click: the turn had been handed back, and the game
## looked frozen. Measured on `_C_140` with the replay driven from a script:
## from turn 4 on, **0 of 4** of the squad were inside the viewport when the
## player got the turn back, and 4 of 4 with this in place.
##
## Static, and taking the rig, so the suite can check it against a real world
## without standing a scene up.
##
## The zoom and the yaw are **not** touched. They are the player's, on Q, E and
## the wheel; only [method _frame_units] sets them, and only at load.
static func focus_on_friendly(rig: CameraRig, mission_world: World) -> int:
	if rig == null:
		return -1
	var slot: int = next_friendly_slot(mission_world, -1)
	if slot < 0:
		return -1
	var view: Dictionary = mission_world.unit_view(slot)
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	if not mission_world.state.in_bounds(x, y):
		return -1
	rig.focus_on(x, y,
		mission_world.state.height_at(mission_world.state.index_of(x, y)))
	return slot


## Give the computer's event to the body it is about.
##
## This is why the `move` event carries its route (`docs/96`): by the time the
## playback reaches event *i* the world is already at the end of the turn, so
## the path cannot be re-derived here -- it would be derived against the wrong
## state. The event brought it.
##
## It is called **after** `_on_ai_step`'s own rebuild, never before: that
## rebuild frees every unit node and clears the bodies, the states and the
## walks. The *next* event's rebuild ending this walk is the design; this
## event's rebuild ending it was a bug that made the computer's units teleport
## and never play `F`.
## Returns how long the event needs on screen, which for a move is its walk.
func _play_event_body(event: Dictionary, kind: String) -> float:
	if _units == null:
		return 0.0
	var slot: int = DictRead.as_int(event["slot"])
	if kind == "move":
		var payload: Dictionary = DictRead.as_dict(event["payload"])
		if payload.has("path"):
			return _walk_body(slot, DictRead.to_int32(payload["path"]),
				DictRead.as_int(payload.get("steps", 0)))
	elif kind == "fire" and _units.states.has(slot):
		_units.states[slot].fire()
	return 0.0


## Walk a body along the cells a move actually entered.
##
## The duration is [constant WALK_SECONDS_PER_STEP] a step, so a long walk
## takes longer than a short one. It is presentation: the world has already
## moved the unit, and a walk that were interrupted would leave nothing behind.
##
## Returns that duration, so the computer's playback can wait for it.
func _walk_body(slot: int, route: PackedInt32Array, steps: int) -> float:
	if _units == null or steps <= 0 or route.size() < 2:
		return 0.0
	var seconds: float = float(steps) * WALK_SECONDS_PER_STEP
	_units.start_walk(slot, route, world.resource.width, seconds)
	return seconds


## The unit views, and through them this mission's bodies and their library.
func units_view() -> UnitsView:
	return _units


func scenery_count() -> int:
	return 0 if _scenery == null else _scenery.built_count()


## The developer line: the cache, the scene and the hash. **Not** user-facing
## text, which is why it is not in [Localization] -- it names a mission file, a
## world set and a digest, and translating any of those would be wrong.
func _refresh_status(extra: String = "") -> void:
	if world == null:
		return
	var line: String = "%s (%d/%d)  %dx%d  %s/%s  %d units  scenery %d  hash %s" % [
		world.resource.mission, _missions.find(_mission) + 1, _missions.size(),
		world.resource.width, world.resource.height,
		world.resource.world_set, world.resource.world_scene,
		world.unit_slots().size(), _scenery.built_count(),
		world.canonical_hash_hex().substr(0, 12)]
	line += "\nQ/E rotate, wheel or pinch or +/- zooms, T the field-type " \
		+ "overlay, G the editor's cell markers" \
		+ "\n[ and ] switch mission: " + ", ".join(_missions)
	_status.text = line
	if _hud != null:
		_hud.refresh(world, _selected, extra)


## How far one trackpad pan event moves the zoom.  Pan deltas arrive in "lines"
## and a flick sends many, so this is deliberately small.
const PAN_ZOOM: float = 0.25
## Pinch: `factor` above 1 is a spread, which zooms in.
const MAGNIFY_ZOOM: float = 6.0


## How much one input moves the zoom, or zero when it is not a zoom input.
##
## Pure and static so it can be tested without a scene tree, which is the whole
## reason it is separate: the wheel worked and the trackpad did not, and the
## difference is which event class the platform sends.
static func zoom_delta_for(event: InputEvent) -> float:
	if event is InputEventMouseButton:
		var click: InputEventMouseButton = event
		if not click.pressed:
			return 0.0
		if click.button_index == MOUSE_BUTTON_WHEEL_UP:
			return -1.0
		if click.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return 1.0
		return 0.0
	if event is InputEventPanGesture:
		# A wheel mouse sends WHEEL_UP/WHEEL_DOWN; a macOS trackpad and a Magic
		# Mouse send this instead, and handling only the former makes the zoom
		# look dead on exactly the hardware this was developed on.
		#
		# The sign is **measured, not derived**.  A first version reasoned from
		# the macOS backend's scroll handling that a negative `delta.y` matched
		# a wheel-up; on the hardware it is the other way round, so a
		# two-finger push away from the body zooms in.
		var pan: InputEventPanGesture = event
		return -pan.delta.y * PAN_ZOOM
	if event is InputEventMagnifyGesture:
		# `factor` above 1 is a spread, which zooms in.
		var pinch: InputEventMagnifyGesture = event
		return (1.0 - pinch.factor) * MAGNIFY_ZOOM
	if event is InputEventKey:
		var key: InputEventKey = event
		if not key.pressed:
			return 0.0
		if key.keycode == KEY_MINUS or key.keycode == KEY_KP_SUBTRACT:
			return 1.0
		if key.keycode == KEY_EQUAL or key.keycode == KEY_PLUS \
				or key.keycode == KEY_KP_ADD:
			return -1.0
	return 0.0


func _process(delta: float) -> void:
	if _playback.is_running():
		_playback.advance(delta)
	if _units != null:
		_units.animate(delta, world)


## One event of the computer's turn: lead the camera to it and say what it was.
##
## An empty dictionary means the playback is over. Nothing here touches the
## world: it has held the post-turn state since [method World.submit_end_turn]
## returned, which is what makes skipping free.
##
## Returns how long this event should stay on screen; see
## [method AIPlayback._step].
func _on_ai_step(event: Dictionary) -> float:
	if event.is_empty():
		_ai_note = ""
		# The turn is the player's again, so the view goes back to the player's
		# own units -- see [method focus_on_friendly] for what it was like
		# without this.
		var _back: int = focus_on_friendly(_rig, world)
		_after_command("")
		return 0.0
	var kind: String = DictRead.as_string(event["kind"])
	var to_x: int = DictRead.as_int(event["tx"])
	var to_y: int = DictRead.as_int(event["ty"])
	var at_x: int = DictRead.as_int(event["x"])
	var at_y: int = DictRead.as_int(event["y"])
	if kind == "move" or kind == "warp":
		at_x = to_x
		at_y = to_y
	if world.state.in_bounds(at_x, at_y):
		_rig.focus_on(at_x, at_y,
			world.state.height_at(world.state.index_of(at_x, at_y)))

	_ai_note = "%s -- %s %d  (%s)" % [_strings.text("hud.ai_turn"),
		_strings.text("ai." + kind) if _strings.has("ai." + kind) else kind,
		DictRead.as_int(event["slot"]), _strings.text("hud.ai_skip")]
	_units.build(world, _geometry, _textures)
	# **After** the rebuild, not before. `UnitsView.build` frees every unit
	# node and clears the bodies, the states and the walks, so an event handed
	# to the bodies first started a walk on nodes that were freed microseconds
	# later: the computer's units teleported and `F` never played. The *next*
	# event's rebuild ending this one is the design; this event's rebuild
	# ending it is the bug.
	var hold: float = _play_event_body(event, kind)
	_refresh_status(_ai_note)
	return hold


func _unhandled_input(event: InputEvent) -> void:
	if world == null:
		return
	# The computer's turn holds the input while it is being shown. One key
	# ends the showing; the world does not change either way.
	if _playback.is_running():
		if event is InputEventKey and event.is_pressed():
			# The bodies are snapped first: `skip()` means "stop drawing the
			# turn", and a body half way between two cells is not the state
			# the last frame would have shown.
			if _units != null:
				_units.finish_walks(world)
			_playback.skip()
		return
	var zoom: float = zoom_delta_for(event)
	if not is_zero_approx(zoom):
		_rig.zoom_by(zoom)
		return
	if event is InputEventKey and event.is_pressed():
		var key: InputEventKey = event
		if key.keycode == KEY_TAB:
			var _cycled: int = cycle_friendly()
		elif key.keycode == KEY_Q:
			_rig.rotate_step(-1)
		elif key.keycode == KEY_E:
			_rig.rotate_step(1)
		elif key.keycode == KEY_T:
			_overlay.toggle()
		elif key.keycode == KEY_G:
			_scenery.toggle_lattice()
		elif key.keycode == KEY_BRACKETRIGHT:
			show_mission(1)
		elif key.keycode == KEY_BRACKETLEFT:
			show_mission(-1)
		elif key.keycode == KEY_SPACE:
			if _may_command_now():
				end_turn()
		elif key.keycode == KEY_U:
			if _may_command_now():
				use_in_front()
		elif key.keycode == KEY_D:
			if _may_command_now():
				hold_fire()
	elif event is InputEventMouseButton and event.is_pressed():
		var click: InputEventMouseButton = event
		if click.button_index == MOUSE_BUTTON_LEFT and _may_command_now():
			_pick(click.position, click.shift_pressed)


## Whether the mission has ended -- in which case no command is taken any more.
##
## [method World.may_command] is the rule and refuses every slot once the
## game-control slots are set; this is the same rule read once, so that a click
## on a friendly unit does not fall through to the "not yours, so shoot it"
## branch and so that the three keyed commands stop with it. Rotating, zooming
## and the two overlays keep working: the map is still worth looking at.
func _mission_over() -> bool:
	return world != null and world.game_control.mission_ended()


## Whether a command may be given at all: the mission is running **and the
## turn is not the computer's**.
##
## The second half is this remake's stand-in for a thing the engine has and it
## does not. `0x0047D600` sets **view state 2** the moment the rotation reaches
## player 255 (docs/25 section 4), and `aNextPlayerHandling` only leaves the
## state that accepts input -- 0 -- when a human holds the turn. There is no
## view state here, so the same refusal is written out.
##
## It should now be unreachable through the normal rotation:
## [method World.submit_end_turn] turns until a human holds the turn, which is
## the engine's own `while (g_currentPlayer == 255 && result == 1)`. It stays
## because a **stopped** hand-over can still leave player 255 holding -- every
## player out, with no mission end behind it -- and what that used to allow was
## not a cosmetic slip: [method World.may_command] compares against whoever
## holds the turn, so the player could select the aliens and spend their turn
## for them.
func _may_command_now() -> bool:
	if world == null or _mission_over():
		return false
	return world.turn.current_player != TurnState.PLAYER_COMPUTER


## Turns a screen position into a map field, then asks the world about it.
## The scene tree is used to find *which* cell was clicked and for nothing else.
func _pick(screen: Vector2, pass_friendlies: bool) -> void:
	var camera: Camera3D = _rig.camera()
	var origin: Vector3 = camera.project_ray_origin(screen)
	var direction: Vector3 = camera.project_ray_normal(screen)
	if absf(direction.y) < 0.0001:
		return
	var best_slot: int = -1
	var best_distance: float = INF
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		var cell: Dictionary = world.cell_view(x, y)
		var centre: Vector3 = WorldSpace.cell_centre(x, y,
			DictRead.as_int(cell["height"]))
		var t: float = (centre.y - origin.y) / direction.y
		if t <= 0.0:
			continue
		var hit: Vector3 = origin + direction * t
		var distance: float = hit.distance_to(centre)
		if distance < 1.2 and distance < best_distance:
			best_distance = distance
			best_slot = slot
	if best_slot >= 0:
		var view: Dictionary = world.unit_view(best_slot)
		# **Only the current player's own units can be selected.**
		# `0x00477DF0(player)` -- which `0x00453CF0`, the game's own "cycle
		# the selected friendly unit", walks -- accepts a slot on exactly
		# three tests: hit points non-zero, `+0x45` equal to
		# `aGetCurrentPlayer`, and `+0x4F` zero. Anything else is a target,
		# not a selection.
		#
		# Selection used to be unconditional, and the owner was consulted only
		# to decide "attack or select". That was invisible while the aliens
		# never acted; with docs/23's planner in place it meant a player could
		# click a purple pill and take the computer's turn for it.
		#
		# **"Cannot be commanded" is not the same as "is a target."**
		# [method World.may_command] also refuses a *friendly* record with no
		# hit points, and a dead squad member stays in `unit_slots()` and stays
		# on screen -- the fog pass leaves an own corpse fully visible. Routing
		# every refusal into the attack branch therefore let a player spend a
		# soldier's action points, and drain the reaction queue, shooting at
		# the body of the soldier who died during the alien turn. So the attack
		# branch asks the question it means: is this somebody else's live unit?
		if not world.may_command(best_slot):
			if _selected >= 0 and is_a_target(view, turn_player()):
				attack_cell(DictRead.as_int(view["x"]),
					DictRead.as_int(view["y"]))
			else:
				_refresh_status(_strings.text("hud.not_yours"))
			return
		var _result: MoveMapResult = select_unit(best_slot, pass_friendlies)
		return

	# No unit under the ray: if a unit is selected and the cell is one the
	# query highlighted, walk there. `core` re-fills and re-walks; the overlay
	# is a picture and is never trusted as the answer.
	var cell: Vector2i = _cell_under(screen)
	if _selected < 0 or cell.x < 0:
		_selected = -1
		_highlight.clear()
		_refresh_status(_strings.text("hud.no_selection"))
		return
	move_selected(cell.x, cell.y)


## Whether a picked unit is something to shoot at rather than something to
## select: alive, and not the current player's own.
##
## The owner test alone is what `game` used before docs/23's planner, and the
## liveness test is what the corpse case needs. A hidden unit never reaches
## here -- the picker only sees what is drawn.
##
## Static, and taking the player rather than reading it, so a suite can ask it
## the question directly: the rule is small enough that the only way to get it
## wrong is not to have checked it.
static func is_a_target(view: Dictionary, current_player: int) -> bool:
	if DictRead.as_int(view["hp"]) == 0:
		return false
	return DictRead.as_int(view["player"]) != current_player


## The player the world says is holding the turn, or -1 with no world.
func turn_player() -> int:
	return -1 if world == null else world.turn.current_player


## The map cell a screen ray lands on, or `(-1, -1)`.
##
## The plane is the *cell's own* height, so a ray is tested against every cell
## rather than against one flat plane -- the map is not flat, and a single-plane
## test picks the wrong cell on anything raised.
func _cell_under(screen: Vector2) -> Vector2i:
	var camera: Camera3D = _rig.camera()
	var origin: Vector3 = camera.project_ray_origin(screen)
	var direction: Vector3 = camera.project_ray_normal(screen)
	if absf(direction.y) < 0.0001:
		return Vector2i(-1, -1)
	var best: Vector2i = Vector2i(-1, -1)
	var best_distance: float = INF
	for y: int in range(world.resource.height):
		for x: int in range(world.resource.width):
			var cell: Dictionary = world.cell_view(x, y)
			var centre: Vector3 = WorldSpace.cell_centre(x, y,
				DictRead.as_int(cell["height"]))
			var t: float = (centre.y - origin.y) / direction.y
			if t <= 0.0:
				continue
			var distance: float = (origin + direction * t).distance_to(centre)
			if distance < 0.7 and distance < best_distance:
				best_distance = distance
				best = Vector2i(x, y)
	return best


## Walks the selected unit. Public for the same reason [method select_unit] is:
## a demo run drives the path a click drives.
func move_selected(x: int, y: int) -> MoveResult:
	var slot: int = _selected
	var moved: MoveResult = world.submit_move(
		MoveCommand.create(slot, x, y))
	_after_command(moved.reason if not moved.ok else "%d %s" % [
		moved.reactions.size(), _strings.text("hud.reactions")])
	# `MoveResult.route` is the walk's own -- source first, truncated where it
	# actually stopped rather than where it was planned to. It is not in
	# `to_dict()` and does not need to be: the player's move hands `game` the
	# object itself.
	_walk_body(slot, moved.route, moved.steps)
	return moved


func attack_cell(x: int, y: int) -> AttackResult:
	var slot: int = _selected
	var shot: AttackResult = world.submit_attack(
		AttackCommand.create(slot, x, y))
	# The reaction count belongs on screen for the same reason
	# [method move_selected] puts it there: a shot that drew return fire is
	# the player's business, and `World.submit_attack` has been filling
	# `reactions` with nobody reading it.
	_after_command(shot.reason if not shot.fired
		else "%d, %d %s" % [shot.outcomes.size(), shot.reactions.size(),
			_strings.text("hud.reactions")])
	# After `_after_command`, for the same reason `move_selected` walks after
	# it: the rebuild is what creates the state this drives.
	if shot.fired and _units != null and _units.states.has(slot):
		_units.states[slot].fire()
	return shot


func use_in_front() -> UseResult:
	if _selected < 0:
		return UseResult.refused("")
	var used: UseResult = world.submit_use(UseCommand.create(_selected))
	_after_command(used.kind if used.ok else used.reason)
	return used


func hold_fire() -> int:
	if _selected < 0:
		return 0
	var ticket: int = world.submit_defend(DefendCommand.create(_selected))
	_after_command(_strings.text("hud.overwatch") if ticket > 0 else "")
	return ticket


## Ends the current player's turn. The computer's turn runs **inside**
## [method World.submit_end_turn] now (docs/23), and hands over again by itself
## when it is done, so what comes back has already passed the rotation on. The
## loop that used to sit here would have run `NEXT PLAYER` a second time per
## round -- which on `_C_140` is the script's reinforcement roll firing twice
## as often as the mission intends.
func end_turn() -> TurnResult:
	var result: TurnResult = world.submit_end_turn(EndTurnCommand.create())
	if result.ai_result != null:
		_playback.play(result.ai_result, Callable(self, "_on_ai_step"))
	_selected = -1
	_highlight.clear()
	# A turn with nothing to replay hands back here rather than through
	# [method _on_ai_step], and the view has to come back either way.
	if not _playback.is_running():
		var _back: int = focus_on_friendly(_rig, world)
	_after_command("")
	return result


## Everything a command changes is redrawn from the world, never patched.
func _after_command(note: String) -> void:
	_units.build(world, _geometry, _textures)
	if _selected >= 0 and world.has_unit(_selected):
		var again: MoveMapResult = world.submit_move_query(
			MoveQueryCommand.create(_selected))
		_highlight.show_result(again, world.resource.heights())
	_refresh_status(note)
