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

## The fifth slice's two presentation layers. Both are `game`'s alone: `core`
## emits the events they read and knows about neither, which is docs/28
## section 8's structural fact -- effects are driven by the animation
## routines, and the simulation only calls those.
var _audio: AudioSystem = null
var _events: AudioEvents = null
var _fx: BlobPool = null
var _sprites: BlobSprites = null
var _models: BlobModels = null
var _triggers: BlobTriggers = null
var _sequences: SequenceQueue = null
var _eng3d: Eng3dGeometry = null
var _blob_tables: Dictionary = {}
## The effect clock, in seconds carried over from the last frame. Blobs tick
## once per displayed frame in the original, and docs/92 section 7.10 measured
## that frame at 20 fps for gameplay animation -- the same frame the bodies
## use, so the two cannot drift apart.
var _fx_carry: float = 0.0
## The terrain the picture currently shows. `game` keeps it and diffs two
## immutable snapshots; `core` has no dirty flag and neither did the original.
var _drawn_terrain: Dictionary = {}
## True once the close request has been accepted, so a second one is ignored
## while the audio server is being given its frames.
var _quitting: bool = false
## Slot -> the walk cue that slot's type set up, kept for as long as the walk
## lasts so every step of one walk sounds the same.
var _footstep_cues: Dictionary[int, Dictionary] = {}
## Return fire waiting to be shown, one batch per command that drew it:
## `{"entries": Array, "x": int, "y": int}`, where the cell is the mover's.
##
## `core` resolves a whole move's reactions in one call at the end of the
## move (`World.submit_move`) and the walk that follows is only the picture,
## so the return fire is held until the picture has caught up. It is drained
## from [method _process] on a **state** test -- nothing walking, no body
## still shooting -- rather than on the edge of a walk ending, because a
## refused or zero-step move drains reactions in `core` and never walks.
var _pending_reactions: Array[Dictionary] = []


## An exported build made with the `run_tests` custom feature runs the suites
## and quits, so docs/92 section 10.4's "demonstrated in an exported build" is
## the same suites against the same cache rather than a second, weaker claim.
## The `anim` sprite atlas, by the name the texture index carries.
const ATLAS_TEXTURE: String = "anim"
## The most effect ticks one displayed frame may run. A long stall should not
## fast-forward every particle in the pool to its death.
const MAX_EFFECT_TICKS: int = 4

## How long a unit a shot killed is still drawn for, in seconds.
##
## **The remake's number, with no engine number behind it.** `aKillUnit`
## (`0x00472920`) is a network message and `aRemoveUnitElement`: the object
## goes at once and Charisma has no death clip to play instead (docs/40
## section 7.2.1). What the engine does have is the *order* -- the shot is
## drawn and then the unit is gone -- and the rebuild that drops it runs
## **before** the event that killed it is presented, so without this a marine
## vanished and the sound of what killed it arrived afterwards.
const DEATH_LINGER_SECONDS: float = 0.7

const TEST_FEATURE: String = "run_tests"
const TEST_RUNNER: String = "res://tests/runner.gd"


func _ready() -> void:
	if OS.has_feature(TEST_FEATURE) and _run_tests_and_quit():
		return
	# The window's close button must not end the process on the spot: the audio
	# server needs a few more frames to let go of a playing Ogg stream, and a
	# quit in the same frame leaks it. See [method AudioSystem.shutdown].
	get_tree().auto_accept_quit = false
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
## Closing the window, and the platform gestures that mean the same thing.
##
## `auto_accept_quit` is off (see `_ready`), so nothing quits until this does.
## The guard matters: on macOS a Cmd-Q while the shutdown is already awaiting
## delivers the notification again, and two overlapping shutdowns would call
## `quit` twice.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST \
			or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_quit()


func _quit() -> void:
	if _quitting:
		return
	_quitting = true
	if _audio != null:
		var _frames: int = await _audio.shutdown()
	get_tree().quit()


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
	var opening_script: Dictionary = {}
	if attached:
		opening_script = world.run_init_map()
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
	# The scenery is placed from the `.lev`, so a mission resumed from a save
	# with a door already open needs the offset applied before the first
	# frame -- otherwise the picture would be right only after something
	# changed, which is the defect this closes rather than a version of it.
	var _placed: int = _scenery.apply_all(world.terrain_snapshot())

	_overlay = TerrainOverlay.new()
	_overlay.name = "TerrainOverlay"
	_scene_root.add_child(_overlay)
	_drawn_terrain = world.terrain_snapshot()
	_overlay.build(_drawn_terrain)

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

	_build_effects(mission, world_set, textures)
	# `INIT MAP` is where every shipped mission puts its `CDTrackProgram`, and
	# the return value was being discarded. The set pieces it may also run are
	# applied by `core` before this point, so what is left for `game` is the
	# sound and the picture.
	_present_script(opening_script)

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


## The sound layer and the blob pool, per mission.
##
## Both read the cache and nothing else; a cache converted with `--no-music`,
## or one whose world set has no `anim` texture, makes the mission quieter or
## plainer rather than making it fail. That is the same policy the original
## has for an effect whose model is missing (docs/28 section 7.5) and for a
## sound that finds no free buffer (section 7.1).
func _build_effects(mission: String, world_set: String,
		textures: Dictionary) -> void:
	var tables: AudioTables = AudioTables.open(_cache_dir)
	_blob_tables = CacheLoader.read_json(_cache_dir + "/tables/blobs.json")
	_events = AudioEvents.open(tables, _blob_tables)
	if _audio == null:
		_audio = AudioSystem.new()
		_audio.name = "Audio"
		add_child(_audio)
		_audio.setup(tables, _events)
	else:
		_audio.stop_all()
		_audio.stop_music()
	_audio.start_music(mission)

	# The pool is seeded from the mission name, so a mission's particles look
	# the same every run without any of it reaching `World.rng` -- which is
	# item 5 of the canonical hash and must not learn about the frame rate.
	_footstep_cues.clear()
	_fx = BlobPool.create(float(hash(mission) % 1000000 + 1))
	# The pool resolves a model name against **this world set's** prototypes.
	# A blob model the set does not carry comes back -1 and the effect is
	# cancelled, which is the original's own behaviour: four of the thirty
	# exist in one or two sets only (docs/28 section 7.5).
	var prototypes: Dictionary = DictRead.as_dict(
		_geometry.get("prototypes", {}))
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in prototypes:
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	_fx.hooks().model_index = index
	# The engine's own sine and arctangent tables, so the orientation service
	# is `0x00403AA0`'s **measured** arithmetic -- a 4096-unit yaw and a pitch
	# measured from level -- rather than the 65536ths substitute docs/28
	# section 12 item 1 had to stand in with. Read once and shared: the tables
	# are one content across all 21 world sets.
	if _eng3d == null:
		_eng3d = Eng3dGeometry.from_cache(_cache_dir)
	_fx.hooks().geometry = _eng3d
	_triggers = BlobTriggers.open(_fx, _blob_tables)
	_sequences = SequenceQueue.create(_audio)
	_fx_carry = 0.0
	_sprites = BlobSprites.new()
	_sprites.name = "Effects"
	_scene_root.add_child(_sprites)
	# The other half of the pool: the class-0 and class-1 blobs, which draw
	# geometry and -- for kinds 42 and 54 -- move their models' joints.
	_models = BlobModels.new()
	_models.name = "EffectModels"
	_scene_root.add_child(_models)
	_models.setup(prototypes, textures, index)
	var by_name: Dictionary = DictRead.as_dict(
		textures.get(MeshBuilder.BY_NAME, {}))
	var plain: Dictionary = DictRead.as_dict(
		textures.get(MeshBuilder.PLAIN, {}))
	var atlas_id: int = DictRead.as_int(by_name.get(ATLAS_TEXTURE, -1))
	var atlas: Texture2D = plain.get(atlas_id) if plain.has(atlas_id) else null
	if atlas == null:
		push_warning("effects: %s has no '%s' texture; sprite effects will "
			% [world_set, ATLAS_TEXTURE] + "not be drawn")
	_sprites.setup(atlas, _blob_tables)


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
##
## **It owns the shot as well as the body.** The effects and the sounds of a
## shot used to be a second, partial copy in [method _present_ai_event] that
## dropped the pain screams, while the body was started here -- two owners
## for one event, and only one of them could report a length.
##
## Returns how long the event needs on screen, which for a move is its walk.
func _play_event_body(event: Dictionary, kind: String) -> float:
	var slot: int = DictRead.as_int(event["slot"])
	if kind == "move":
		if _units == null:
			return 0.0
		var payload: Dictionary = DictRead.as_dict(event["payload"])
		if payload.has("path"):
			return _walk_body(slot, DictRead.to_int32(payload["path"]),
				DictRead.as_int(payload.get("steps", 0)))
	elif kind == "fire":
		# **The weapon comes from the event, not from the world.** The
		# playback runs after the turn, so an alien killed by reaction fire
		# after its own shot has no view left and the shot was presented as
		# nothing at all. `AIFire` writes the weapon into the note as it was
		# when the trigger was pulled, which is both accurate and always
		# there.
		return _present_attack(slot, DictRead.as_int(event["x"]),
			DictRead.as_int(event["y"]), DictRead.as_int(event["tx"]),
			DictRead.as_int(event["ty"]),
			DictRead.as_string(event["note"]).to_int(),
			AttackResult.from_dict(DictRead.as_dict(event["payload"])))
	elif kind == "reactions":
		# The event's own cell is the **mover's**: `AIFire` and `AIPlan` emit
		# this for the unit that drew the fire, and the reactors are in the
		# payload. There is nothing to wait for the mover to do, so it is
		# shown at once and its longest clip is what the playback holds on.
		var drained: Dictionary = DictRead.as_dict(event["payload"])
		return _present_reactions(
			DictRead.as_array(drained.get("reactions", [])),
			DictRead.as_int(event["x"]), DictRead.as_int(event["y"]))
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
	# docs/28 section 5. The wave and the volume id are the unit type's; the
	# *period* is a global the call writes, so asking for it here -- once, at
	# the start of the walk, in the order the walks happen -- is what makes the
	# Squeether's missing period behave the way the original's does.
	_units.start_walk(slot, route, world.resource.width, seconds,
		_footstep_period(slot))
	return seconds


## The step period for a walk about to start, and the cue cached beside it.
##
## Zero for the 39 silent unit types, and zero for a Squeether that walks
## before anything else has: the period is one global and it starts at zero.
func _footstep_period(slot: int) -> int:
	if _events == null or world == null:
		return 0
	var view: Dictionary = world.unit_view(slot)
	if view.is_empty():
		return 0
	var cue: Dictionary = _events.footstep(DictRead.as_int(view["type_id"]))
	if cue.is_empty():
		return 0
	_footstep_cues[slot] = cue
	return DictRead.as_int(cue["period"])


## Play a wave for every foot that came down this frame.
##
## [method UnitsView.steps_taken] counts frames and knows nothing about sound;
## this turns each slot into the cue its type set up when the walk began. The
## cue is the one taken at `start_walk`, not a fresh lookup: the period global
## may have moved on since, and a walk sounds like what it started as.
func _play_footsteps() -> void:
	if _audio == null:
		return
	for slot: int in _units.steps_taken():
		if _footstep_cues.has(slot):
			var _played: int = _audio.play_cue(_footstep_cues[slot])


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
		_play_footsteps()
		var _waiting: int = _drain_pending_reactions()
	if _sequences != null and _sequences.is_running():
		# The picture is held, never the world: `core` returned the finished
		# state before any of this was queued.
		var still: bool = _sequences.advance(delta)
		if not still:
			_redraw_terrain_now()
			# Whoever the queue was delivering has arrived.
			if _units != null:
				var _shown: int = _units.reveal_all()
				var _dropped: int = _units.drop_lifts()
	_advance_effects(delta)


## The blob pool at the engine's own frame, and the sprite cloud from it.
##
## The pool is ticked a **whole** number of times per displayed frame and the
## remainder is carried, so a slow frame runs the arms twice rather than
## stretching them: the arms count in ticks, not in seconds, and half a tick is
## not a thing any of them can do.
func _advance_effects(delta: float) -> void:
	if _fx == null:
		return
	_fx_carry += delta * CharismaState.FRAMES_PER_SECOND
	var ticks: int = int(_fx_carry)
	_fx_carry -= float(ticks)
	# A frame that lost a second to a rebuild should not run three hundred
	# particle ticks to catch up; the effect is cosmetic and the cap is the
	# same shape as the walk's own.
	ticks = mini(ticks, MAX_EFFECT_TICKS)
	for _step: int in range(ticks):
		var _results: Array[BlobKinds.TickResult] = _fx.tick_all()
	if _sprites != null and _rig != null and _rig.camera() != null:
		var _drawn: int = _sprites.rebuild(_fx.blobs(),
			_rig.camera().global_transform.basis)
	if _models != null:
		var _shown: int = _models.rebuild(_fx)


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
		# The replay is over, so nobody is held at an old cell any more. It is
		# cleared **before** the rebuild `_after_command` does, which is what
		# puts everyone back; a skipped replay comes through here too.
		if _units != null:
			_units.hold_at({} as Dictionary[int, Vector2i])
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
	# **Before the rebuild**, for the same reason the player's shot does it:
	# this event's own casualties must still be on screen while the event is
	# presented, and the rebuild below is what takes them away.
	var payload: Dictionary = DictRead.as_dict(event["payload"])
	if kind == "fire":
		var _held: int = _linger_the_killed(
			DictRead.as_array(payload.get("outcomes", [])))
	elif kind == "reactions":
		var _held_back: int = _linger_the_killed_by(
			DictRead.as_array(payload.get("reactions", [])))
	# Where every unit whose move is still to come is standing. The world has
	# held the end of the turn since `submit_end_turn` returned, so without
	# this a unit stood at its destination until its own event came round and
	# only then walked there.
	_units.hold_at(_playback.pending_starts())
	_units.build(world, _geometry, _textures)
	# **After** the rebuild, not before. `UnitsView.build` frees every unit
	# node and clears the bodies, the states and the walks, so an event handed
	# to the bodies first started a walk on nodes that were freed microseconds
	# later: the computer's units teleported and `F` never played. The *next*
	# event's rebuild ending this one is the design; this event's rebuild
	# ending it is the bug.
	var hold: float = _play_event_body(event, kind)
	_present_ai_event(event, kind)
	_refresh_status(_ai_note)
	return hold


## The computer's door and para bomb, heard.
##
## **The shot is not here.** It was a partial copy of the player's own
## presentation -- no pain scream, and the weapon read out of the post-turn
## world -- and it returned nothing, so the playback could not wait for it.
## [method _play_event_body] owns every attack now; what is left here is the
## sound-only half of the replay.
##
## The player watching a replay should hear what they would have heard live;
## an effect that only fired on the player's own turn would be worse than
## none at all.
func _present_ai_event(_event: Dictionary, kind: String) -> void:
	if _audio == null or _events == null:
		return
	match kind:
		"door":
			var _door: PackedInt32Array = _audio.play_cues(
				_events.for_event_kind("open_door"), "ai")
		"parabomb":
			# The LCL command runs two routines in order, so the driver asks
			# for both phases rather than letting the alias hide the second.
			var _bomber: PackedInt32Array = _audio.play_cues(
				_events.for_event_kind("bomber"), "ai")
			var _bomb: PackedInt32Array = _audio.play_cues(
				_events.for_event_kind("para_bomb"), "ai")
		"fire_heat_blocked":
			var _jam: PackedInt32Array = _audio.play_cues(
				_events.for_event_kind("reaction_jam"), "ai")


func _unhandled_input(event: InputEvent) -> void:
	if world == null:
		return
	# The computer's turn holds the input while it is being shown. One key
	# ends the showing; the world does not change either way.
	if _playback.is_running():
		if event is InputEventKey and event.is_pressed():
			if _sequences != null:
				_sequences.skip()
			if _units != null:
				var _shown: int = _units.reveal_all()
				var _dropped: int = _units.drop_lifts()
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
	# A move that drew return fire can lose the mover to it; the same order
	# applies, and the walk still plays because the body is still there.
	var _held: int = _linger_the_killed_by(moved.reactions)
	_after_command(moved.reason if not moved.ok else "%d %s" % [
		moved.reactions.size(), _strings.text("hud.reactions")])
	# `MoveResult.route` is the walk's own -- source first, truncated where it
	# actually stopped rather than where it was planned to. It is not in
	# `to_dict()` and does not need to be: the player's move hands `game` the
	# object itself.
	_walk_body(slot, moved.route, moved.steps)
	# **After** the walk starts and after `_after_command`, which clears the
	# queue: `World.submit_move` resolves the whole move's reactions in one
	# call at its end, so the end of the walk is where the picture reaches
	# the state `core` already returned.
	_queue_reactions(moved.reactions, x, y)
	return moved


func attack_cell(x: int, y: int) -> AttackResult:
	var slot: int = _selected
	var shot: AttackResult = world.submit_attack(
		AttackCommand.create(slot, x, y))
	# **Before `_after_command`**, which rebuilds and would otherwise drop the
	# body this shot is about to be drawn hitting.
	var _held: int = _linger_the_killed(shot.outcomes)
	var _held_back: int = _linger_the_killed_by(shot.reactions)
	# The reaction count belongs on screen for the same reason
	# [method move_selected] puts it there: a shot that drew return fire is
	# the player's business, and `World.submit_attack` has been filling
	# `reactions` with nobody reading it.
	_after_command(shot.reason if not shot.fired
		else "%d, %d %s" % [shot.outcomes.size(), shot.reactions.size(),
			_strings.text("hud.reactions")])
	# After `_after_command`, for the same reason `move_selected` walks after
	# it: the rebuild is what creates the state this drives -- and after it
	# for a second reason now, because `_after_command` clears the pending
	# return fire and this command's own is queued below it.
	var view: Dictionary = world.unit_view(slot)
	if not view.is_empty():
		var _hold: float = _present_attack(slot, DictRead.as_int(view["x"]),
			DictRead.as_int(view["y"]), x, y,
			DictRead.as_int(view["weapon"]), shot)
	# The shooter's own cell is where the return fire is aimed, and it is
	# queued rather than shown: the shot's own clip runs first.
	_queue_reactions(shot.reactions, DictRead.as_int(view.get("x", x)),
		DictRead.as_int(view.get("y", y)))
	return shot


## Keep every unit this attack killed on screen until its shot has been shown.
##
## Called **before** the rebuild, because the rebuild is what drops them and
## for the computer's replay it runs ahead of the event's own presentation.
## Returns how many were held, for a caller and a suite.
func _linger_the_killed(outcomes: Array) -> int:
	if _units == null or world == null:
		return 0
	var held: int = 0
	for entry: Variant in outcomes:
		var outcome: Dictionary = DictRead.as_dict(entry)
		var slot: int = DictRead.as_int(outcome.get("slot", -1))
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) != 0:
			continue
		_units.linger(slot, DEATH_LINGER_SECONDS)
		held += 1
	return held


## The same, for every reaction one command drained.
func _linger_the_killed_by(entries: Array) -> int:
	var held: int = 0
	for item: Variant in entries:
		var entry: Dictionary = DictRead.as_dict(item)
		var attack: Dictionary = DictRead.as_dict(entry.get("attack", {}))
		held += _linger_the_killed(DictRead.as_array(
			attack.get("outcomes", [])))
	return held

## The audible and visible half of one shot, and the shooter's own body.
##
## **One presenter for every shot in the game** -- the player's, the
## computer's, and every reaction on either turn. There were three before this,
## and each was missing something the others had: the computer's dropped the
## pain screams, and reaction fire had no presentation at all, so the HUD
## counted return fire that nothing drew.
##
## Three switches decide the effects and nothing else does (docs/28 section
## 8.1): the muzzle blob at the shooter, the impact blob and its sound at the
## target. The weapon's own fire sound and the overheat trio come from
## [AudioEvents], which reads the same weapon id.
##
## `(sx, sy)` is where the shot came **from**, and it is passed rather than
## read back out of the world: the computer's playback runs after its turn, so
## the shooter may have moved or died since. The three layers are optional
## separately, because a body animates whether or not there is an audio server
## behind it.
##
## Returns how long the shooter's body is occupied ([method UnitsView.fire]),
## so the computer's playback can hold the event for its clip.
func _present_attack(shooter: int, sx: int, sy: int, tx: int, ty: int,
		weapon: int, attack: AttackResult) -> float:
	if attack == null or not attack.fired or world == null:
		return 0.0
	var hold: float = 0.0
	if _units != null:
		hold = _units.fire(shooter, tx, ty)
	if _triggers != null:
		var from: Vector3i = _muzzle_of(sx, sy)
		var to: Vector3i = _muzzle_of(tx, ty)
		var _muzzle: int = _triggers.muzzle(weapon, from, to)
		var _impact: int = _triggers.impact(weapon, to)
	if _audio == null or _events == null:
		return hold
	var _slots: PackedInt32Array = _audio.play_cues(
		_events.for_attack(attack, weapon), "shot")
	# One scream per unit the shot actually resolved on, off that species'
	# own cursor -- which is why the two species interleave rather than each
	# running its own sequence.
	for entry: Variant in attack.outcomes:
		var outcome: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_int(outcome.get("dealt", 0)) <= 0:
			continue
		var hurt: Dictionary = world.unit_view(
			DictRead.as_int(outcome["slot"]))
		if hurt.is_empty():
			continue
		var species: int = world.unit_types().species(
			DictRead.as_int(hurt["type_id"]))
		var _voice: int = _audio.play_cue(_events.pain(species), "shot")
	return hold


## Every reaction one command drained, shown at the cell that drew them.
##
## `Reaction.drain` returns `{"reactor": slot, "ticket": int, "attack": ...}`
## and the target is always the mover, whose cell the caller has. Returns the
## longest of the shots, so a caller pacing a replay can wait for all of them.
##
## A reactor the fog does not draw has no body this rebuild and animates
## nothing; its shot is still heard and its blobs still fly, which is what the
## player would have had from an unseen shooter in the original.
func _present_reactions(entries: Array, tx: int, ty: int) -> float:
	if world == null or entries.is_empty():
		return 0.0
	var longest: float = 0.0
	for item: Variant in entries:
		var entry: Dictionary = DictRead.as_dict(item)
		var reactor: int = DictRead.as_int(entry.get("reactor", -1))
		var view: Dictionary = world.unit_view(reactor)
		if view.is_empty():
			continue
		var attack: AttackResult = AttackResult.from_dict(
			DictRead.as_dict(entry.get("attack", {})))
		longest = maxf(longest, _present_attack(reactor,
			DictRead.as_int(view["x"]), DictRead.as_int(view["y"]), tx, ty,
			DictRead.as_int(view["weapon"]), attack))
	return longest


## Hold return fire until the picture has caught up with what `core` did.
func _queue_reactions(entries: Array, tx: int, ty: int) -> void:
	if entries.is_empty():
		return
	_pending_reactions.append({"entries": entries.duplicate(true),
		"x": tx, "y": ty})


## Show one waiting batch of return fire, when there is room for it.
##
## The condition is a **state** test and deliberately not an edge: a move that
## was refused or that walked no steps still drained reactions in `core`, and
## an edge on a walk ending would never fire for it. Returns how many batches
## are still waiting, for a suite.
func _drain_pending_reactions() -> int:
	if _pending_reactions.is_empty() or _units == null:
		return _pending_reactions.size()
	if _units.is_walking() or _units.any_busy():
		return _pending_reactions.size()
	var batch: Dictionary = _pending_reactions[0]
	_pending_reactions.remove_at(0)
	var _hold: float = _present_reactions(DictRead.as_array(batch["entries"]),
		DictRead.as_int(batch["x"]), DictRead.as_int(batch["y"]))
	return _pending_reactions.size()


## The sounds one run of a mission script asks for.
##
## `core` has already applied every state change these events record -- the
## door is open, the lift has moved -- so what reaches here is the half the
## simulation does not own: docs/28's `aPlay*Sequence` sounds, keyed by the
## routine that owns them.
func _present_script(outcome: Dictionary) -> int:
	if outcome.is_empty() or _audio == null or _events == null:
		return 0
	var played: int = 0
	for entry: Variant in DictRead.as_array(outcome.get("events", [])):
		var event: Dictionary = AudioEvents.as_event(entry)
		if event.is_empty():
			continue
		var cues: Array[Dictionary] = _events.for_event(event)
		var frames: int = SetpieceDriver.frames_for(event)
		if frames > 0 and _sequences != null:
			# An animated set piece: the picture is interpolated over the
			# frames the original's own loop ran for, and its sound lives for
			# exactly that long rather than for the length of its sample.
			_queue_setpiece(event, frames, cues)
			played += cues.size()
			continue
		if cues.is_empty():
			continue
		var slots: PackedInt32Array = _audio.play_cues(cues, "script")
		played += slots.size()
	return played


## Queue one set piece: hold the cell where it was drawn, and walk it to where
## `core` has already put it.
##
## The offset is against the **drawn** snapshot, not against the authored
## height, so a lift that has moved twice starts its second trip from where the
## first one left it. `core` is never read for anything but the destination.
func _queue_setpiece(event: Dictionary, frames: int,
		cues: Array[Dictionary]) -> void:
	var cell: Vector2i = SetpieceDriver.cell_of(event)
	if world == null or not world.state.in_bounds(cell.x, cell.y):
		if not cues.is_empty() and _audio != null:
			var _slots: PackedInt32Array = _audio.play_cues(cues, "script")
		return
	var index: int = world.state.index_of(cell.x, cell.y)
	var was: PackedInt32Array = _drawn_terrain["height_map"] \
		if _drawn_terrain.has("height_map") else PackedInt32Array()
	var from: int = was[index] if index < was.size() \
		else world.state.height_at(index)
	var to: int = world.state.height_at(index)
	var name: String = AudioEvents.name_of(event)
	# A `RoofUnit` inserts its alien the instant the command runs, so the unit
	# is on the map before its fall has started. The body is held out of the
	# picture for the length of the sequence and shown at the end: the criterion
	# is that the unit **appears at the end of the drop, not at the beginning**,
	# and `core` is never asked to delay anything.
	if name == "roof_unit" and _units != null:
		var arriving: int = world.state.unit_at(index)
		if arriving != MapState.NO_UNIT:
			_units.suppress(arriving)
	# Anyone standing on the cell rides it. `core` has already moved them to
	# the destination height, so the passenger is captured **now**, at the
	# start, and carried by the same offset the cell's objects are: without
	# this a unit on a lift is at the top before the lift has left the floor.
	# `roof_unit` is the one animated set piece whose unit is not a passenger
	# -- it is the cargo, and it is suppressed above instead.
	var rider: int = MapState.NO_UNIT
	if name != "roof_unit" and _units != null:
		rider = world.state.unit_at(index)
	_sequences.enqueue(name, frames,
		func(frame: int, total: int) -> void:
			_paint_setpiece(index, from, to, frame, total)
			_carry_rider(rider, from, to, frame, total),
		cues)


## Hold a unit riding a moving cell at the height the cell has reached.
##
## The offset is against where `core` already put it -- `to` -- so it starts at
## `from - to` and reaches zero on the last frame, whatever direction the lift
## went in.
func _carry_rider(slot: int, from: int, to: int, frame: int,
		frames: int) -> void:
	if slot == MapState.NO_UNIT or _units == null:
		return
	var at: int = from + roundi(float(to - from)
		* SetpieceDriver.progress(frame, frames))
	_units.lift(slot, at - to)


## One frame of a set piece: the cell's objects at the height the original
## would have had them at after `frame` of its own ticks.
func _paint_setpiece(index: int, from: int, to: int, frame: int,
		frames: int) -> void:
	if _scenery == null or world == null:
		return
	var at: int = from + roundi(float(to - from)
		* SetpieceDriver.progress(frame, frames))
	var partial: Dictionary = world.terrain_snapshot()
	var heights: PackedInt32Array = partial["height_map"]
	if index >= heights.size():
		return
	heights[index] = at
	partial["height_map"] = heights
	var _moved: int = _scenery.apply_state(partial, PackedInt32Array([index]))


## Move and repaint whatever the last command changed about the terrain.
##
## Before this, `_scenery.build` and `_overlay.build` ran **once per mission**,
## so a door that changed its cell's field type and raised it by
## [constant Interact.DOOR_HEIGHT_STEP] produced no visible change at all until
## the mission was rebuilt with `[` or `]`. That was the slice's headline
## defect, and closing it needed no new concept in `core`: two immutable
## snapshots and the difference between them.
##
## Answers how many cells changed, so a caller and a suite can tell "nothing
## moved" from "nothing was checked".
func _redraw_terrain() -> int:
	# A queued set piece owns the cells it is animating: snapping them to the
	# finished state now would show the end of the lift before the lift.
	# `_process` calls `_redraw_terrain_now` when the queue drains.
	if _sequences != null and _sequences.is_running():
		return 0
	return _redraw_terrain_now()


func _redraw_terrain_now() -> int:
	if world == null or _scenery == null or _overlay == null:
		return 0
	var now: Dictionary = world.terrain_snapshot()
	var changed: PackedInt32Array = TerrainDiff.changed_cells(
		_drawn_terrain, now)
	if changed.is_empty():
		return 0
	var moved: PackedInt32Array = TerrainDiff.moved_cells(_drawn_terrain, now)
	if not moved.is_empty():
		var _n: int = _scenery.apply_state(now, moved)
	_overlay.rebuild_cells(now, changed)
	_drawn_terrain = now
	return changed.size()


func _muzzle_of(x: int, y: int) -> Vector3i:
	var height: int = 0
	if world != null and world.state.in_bounds(x, y):
		height = world.state.height_at(world.state.index_of(x, y))
	return BlobTriggers.muzzle_point(x, y, height)


func use_in_front() -> UseResult:
	if _selected < 0:
		return UseResult.refused("")
	var used: UseResult = world.submit_use(UseCommand.create(_selected))
	_after_command(used.kind if used.ok else used.reason)
	# The player's own door emits **no event** -- `Interact.toggle_door` writes
	# the state change and returns, and only the LCL `OpenDoor` path records
	# one. So the sound is driven from the result, not from the event stream,
	# and this is why [method AudioEvents.for_use] exists at all.
	if _audio != null and _events != null:
		var _slots: PackedInt32Array = _audio.play_cues(
			_events.for_use(used), "use")
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
	if result.ran_turn_script:
		var _turn_sounds: int = _present_script(result.turn_script)
	if result.ran_player_script:
		var _player_sounds: int = _present_script(result.player_script)
	if result.ai_result != null:
		_playback.play(result.ai_result, Callable(self, "_on_ai_step"))
	# **Before the rebuild `_after_command` does below.** [method
	# AIPlayback.play] does not take its first step -- that waits for
	# [constant AIPlayback.STEP_SECONDS] -- so without this every unit the
	# computer is about to walk stands at its destination for the first half
	# second of the replay, and then jumps back to walk there. That window is
	# the half of the defect that placing the body on its first cell in
	# [method UnitsView.start_walk] does not reach.
	if _units != null:
		var owed: Dictionary[int, Vector2i] = {}
		if _playback.is_running():
			owed = _playback.pending_starts()
		_units.hold_at(owed)
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
	# A new command supersedes whatever return fire was still waiting: it
	# was drawn by a command the player has already moved on from.
	_pending_reactions.clear()
	_units.build(world, _geometry, _textures)
	_redraw_terrain()
	if _selected >= 0 and world.has_unit(_selected):
		var again: MoveMapResult = world.submit_move_query(
			MoveQueryCommand.create(_selected))
		_highlight.show_result(again, world.resource.heights())
	_refresh_status(note)
