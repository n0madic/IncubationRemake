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
const DEFAULT_MISSION: String = "_C_115"
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
var _status: Label = null
var _selected: int = -1
var _cache_dir: String = ""


## An exported build made with the `run_tests` custom feature runs the suites
## and quits, so docs/92 section 10.4's "demonstrated in an exported build" is
## the same suites against the same cache rather than a second, weaker claim.
const TEST_FEATURE: String = "run_tests"
const TEST_RUNNER: String = "res://tests/runner.gd"


func _ready() -> void:
	if OS.has_feature(TEST_FEATURE) and _run_tests_and_quit():
		return
	_status = Label.new()
	_status.position = Vector2(12.0, 8.0)
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
	var header: Dictionary = DictRead.as_dict(map_document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	var geometry: Dictionary = _geometry_for(world_set)
	var textures: Dictionary = _textures_for(world_set)

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
	_scene_root.add_child(_units)
	_units.build(world, geometry, textures)

	_rig = CameraRig.new()
	_rig.name = "CameraRig"
	_scene_root.add_child(_rig)
	_rig.setup(world.resource.width, world.resource.height,
		world.resource.heights(), world.resource.camera_height)
	_rig.camera().current = true

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
	_refresh_status("slot %d %s: %d reachable, %d warp, mp %d, pf %s" % [
		slot, DictRead.as_string(view["name"]), result.reachable_count(),
		result.warp_count(), result.mp, str(pass_friendlies)])
	return result


func selected_slot() -> int:
	return _selected


func camera_rig() -> CameraRig:
	return _rig


func scenery_count() -> int:
	return 0 if _scenery == null else _scenery.built_count()


func _refresh_status(extra: String = "") -> void:
	if world == null:
		return
	var line: String = "%s (%d/%d)  %dx%d  %s/%s  %d units  scenery %d  hash %s" % [
		world.resource.mission, _missions.find(_mission) + 1, _missions.size(),
		world.resource.width, world.resource.height,
		world.resource.world_set, world.resource.world_scene,
		world.unit_slots().size(), _scenery.built_count(),
		world.canonical_hash_hex().substr(0, 12)]
	if extra != "":
		line += "\n" + extra
	line += "\nclick a unit to see where it can go; shift-click passes " \
		+ "through friendlies; Q/E rotate, wheel or pinch or +/- zooms, " \
		+ "T shows the field-type overlay, G the editor's cell markers" \
		+ "\n[ and ] switch mission: " + ", ".join(_missions)
	_status.text = line


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


func _unhandled_input(event: InputEvent) -> void:
	if world == null:
		return
	var zoom: float = zoom_delta_for(event)
	if not is_zero_approx(zoom):
		_rig.zoom_by(zoom)
		return
	if event is InputEventKey and event.is_pressed():
		var key: InputEventKey = event
		if key.keycode == KEY_Q:
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
	elif event is InputEventMouseButton and event.is_pressed():
		var click: InputEventMouseButton = event
		if click.button_index == MOUSE_BUTTON_LEFT:
			_pick(click.position, click.shift_pressed)


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
	if best_slot < 0:
		_selected = -1
		_highlight.clear()
		_refresh_status("nothing selected")
		return
	var _result: MoveMapResult = select_unit(best_slot, pass_friendlies)
