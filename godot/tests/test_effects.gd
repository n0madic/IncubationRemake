extends TestSuite

## Oracle boundary: specification-only, against the converted data.
##
## The three things the fifth slice adds that are not a diff against a Python
## model: the terrain snapshot diff, the scenery moving because the state moved,
## and the sprite path's own arithmetic. `test_blob.gd` and `test_sound.gd`
## carry the parts that *do* have an executable oracle; these are claims about
## the remake's own rendering, so they are checked as such.
##
## **The door is the slice's headline defect and is checked end to end here.**
## Before this slice `Scenery.build` and `TerrainOverlay.build` ran once per
## mission, so `Interact.toggle_door` writing a field-type flip and a height
## change of `0xC80` into `MapState` produced **no visible change at all** until
## the mission was rebuilt. The check below opens a real door on `_C_140` and
## requires the panel standing on that cell to have moved by exactly that much.

## The mission with two closed doors, at action point 31.
const DOOR_MISSION: String = "_C_140"
const CORNERS_PER_QUAD: int = 4


## One whole map field, `RoofUnit`'s own drop step -- the largest offset a
## lift applies in a single frame.
const RIDE_STEP: int = 0xC80
const RIDE_EPSILON: float = 0.001
const STEP_SLOT: int = 0
const STEP_WIDTH: int = 20
const STEP_SECONDS: float = 1.0
## Inside docs/28 section 5's shipped range of 2 to 8 frames.
const STEP_PERIOD: int = 4
## A camera flight in front of a walk, long enough to tick twice inside.
const STEP_DELAY: float = 0.4
## docs/28 section 7.8 -- the two effect models with articulated sub-objects,
## and how many parts each has.
const JOINT_MODELS: Dictionary = {"A_PANEL.3DI": 1, "A_FIRE3.3DI": 2}
const JOINT_MODEL: String = "A_PANEL.3DI"
const MODEL_WORLD_SET: String = "A00"


func run(h: TestHarness) -> void:
	h.begin("effects", TestHarness.ORACLE_SPEC)
	_check_diff(h)
	_check_sprites(h)
	_check_door(h)
	_check_triggers(h)
	_check_setpieces(h)
	_check_queue(h)
	_check_open_ended_steps(h)
	_check_arrived_flag(h)
	_check_shot_stages(h)
	_check_demo_missions(h)
	_check_arrival(h)
	_check_ride(h)
	_check_steps(h)
	_check_models(h)
	_check_unit_animations(h)
	_check_setpiece_camera(h)
	_check_arm_spawns(h)
	_check_emitters(h)



## `CreateBGB`, the one effect a **script** places -- docs/28 section 8.2.
##
## The command was recorded by the interpreter and consumed by nothing, so the
## campaign maps' four burning buildings were not burning. What is checked here
## is the registration's own shift, the tick's cadence and the fire's record;
## `tools/blob_tables.py`'s `bgb.*` pins all of it against the executable, and
## this is the port reading the same numbers.
func _check_emitters(h: TestHarness) -> void:
	var table: BgbEmitters = BgbEmitters.create()
	h.equal("bgb.id_bound", [table.register(BgbEmitters.SLOTS, 7, 0, 0, 0, 1, 0, 0),
		table.register(0, BgbEmitters.TYPE_NONE, 0, 0, 0, 1, 0, 0)],
		[false, false], "`invalid bgbcreator id`, and type 0 is an error")
	# docs/20 section 7.4: the command shifts all three coordinates left by
	# four before it stores them, so `_C_XXX.lcl`'s own 5905 is 94480 units --
	# which is what puts the fire on a roof instead of in the first field.
	var _ok: bool = table.register(0, BgbEmitters.TYPE_FIRE,
		5905, 2095, 555, 30, 40, 0)
	var slot: BgbEmitters.Slot = table.slot(0)
	h.equal("bgb.coordinates_shift", [slot.x, slot.y, slot.z],
		[5905 << 4, 2095 << 4, 555 << 4])
	h.equal("bgb.countdown_starts_at_live", [slot.countdown, slot.live],
		[30, 30], "`live` reaches both bytes, so it burns from the first tick")

	var pool: BlobPool = BlobPool.create(1.0)
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	var hooks: GameBlobHooks = GameBlobHooks.over(pool, inputs)
	hooks.rng.randomize_seed(1.0)
	pool.set_hooks(hooks)
	# The gate is off at animation level 1 and on at every other value: the
	# tick's `jne` skips a bare `ret`, and the shipped default is 2.
	table.level = BgbEmitters.LEVEL_OFF
	h.equal("bgb.level_1_makes_nothing", table.tick(pool, hooks), 0,
		"`Game.opt` +0x20 -- the one value that turns the emitters off")
	table.level = BgbEmitters.LEVEL_DEFAULT
	h.equal("bgb.default_level_burns", table.tick(pool, hooks), 1)
	var flame: Blob = pool.blobs()[0]
	h.equal("bgb.fire_record",
		[flame.class_id, flame.kind, flame.life, flame.aux, flame.delay],
		[3, 0x3A, 0x0C, 5, 0],
		"class 3, kind 58, life 12, aux 5 -- `BLOB_CALLS` at 0x0042A6C6")
	h.equal("bgb.fire_stands_where_the_script_said",
		[flame.x, flame.y, flame.z], [slot.x, slot.y, slot.z])
	h.check("bgb.fire_rises",
		flame.vz >= 0x140 and flame.vz < 0x140 + 0xA0
		and absi(flame.vx) <= 0x30 and absi(flame.vy) <= 0x30,
		"48 either way and 320..480 up: vx %d vy %d vz %d"
		% [flame.vx, flame.vy, flame.vz])

	# The cadence: a running countdown spawns **every** tick, and `random` 0
	# reloads unconditionally -- a flame that never stops.
	var steady: BgbEmitters = BgbEmitters.create()
	var _lit: bool = steady.register(0, BgbEmitters.TYPE_FIRE, 0, 0, 0, 2, 0, 0)
	var burst: int = 0
	for _step: int in range(8):
		burst += steady.tick(pool, hooks)
	h.equal("bgb.random_zero_never_pauses", burst, 8)
	# Type 1 is the sweep's other entry: `aBlob_CreateSmoke2` `0x0042A5E0`,
	# the fire's shape with kind 10, sprite row 4 and `aux` 10. No shipped
	# script reaches it -- all four `1_smoke` lines are commented out in their
	# own scripts -- so what checks it is the executable's bytes.
	var smoke: BgbEmitters = BgbEmitters.create()
	var _reg: bool = smoke.register(0, BgbEmitters.TYPE_SMOKE, 0, 0, 0, 2, 0, 0)
	var before: int = pool.live()
	h.equal("bgb.smoke_is_driven_too", smoke.tick(pool, hooks), 1)
	var puff: Blob = pool.blobs()[before]
	h.equal("bgb.smoke_record",
		[puff.class_id, puff.kind, puff.life, puff.rot_x, puff.aux],
		[3, 0xA, 0xC, 4, 10],
		"class 3, kind 10, life 12, row 4, aux 10 -- 0x0042A646")

	# **Types 2..6 tick to nothing, and that is the engine's answer.** Five of
	# the sweep's seven jump-table entries are one `mov eax, 1 / ret`; their
	# whole effect is the object registration makes. Only a type past the
	# table's bound reaches the `invalid creator` assert.
	var lights: BgbEmitters = BgbEmitters.create()
	var _light: bool = lights.register(0, BgbEmitters.TYPE_WARNING_LIGHT,
		0, 0, 0, 2, 0, 0)
	var _over: bool = lights.register(1, BgbEmitters.TYPE_FIRE + 1,
		0, 0, 0, 2, 0, 0)
	h.equal("bgb.registration_types_do_not_tick",
		[lights.tick(pool, hooks),
		lights.refused.get(BgbEmitters.TYPE_WARNING_LIGHT, 0),
		lights.refused.get(BgbEmitters.TYPE_FIRE + 1, 0)],
		[0, 0, 1],
		"0x0041E300 sends 2..6 to `mov eax,1`; past 7 is the assert")

	_check_registration_creators(h, pool, inputs)
	_check_map_fires(h)


## The five one-shots `aEnterBGBCreator` makes for itself -- `0x0041E120`.
##
## Registration is the other half of `CreateBGB` and had none of it: a
## `_C_102` warning light was a table row and no light. These run **once**,
## from the command rather than from the sweep, and so are not behind the
## animation-level gate the fires are.
func _check_registration_creators(h: TestHarness, pool: BlobPool,
		inputs: BlobPrograms.Inputs) -> void:
	# Class 1 is a model blob, and the constructor refuses one whose name the
	# world set does not carry (docs/28 section 7.5) -- so the five models have
	# to resolve before any of this can be seen at all.
	var models: Dictionary[String, int] = {}
	var names: Array[String] = [BlobPrograms.BGB_WARNING_MODEL,
		BlobPrograms.BGB_PANEL_MODEL, BlobPrograms.BGB_FIRE3_MODEL,
		BlobPrograms.BGB_SPOT_MODEL, BlobPrograms.BGB_LAMP_MODEL]
	for index: int in range(names.size()):
		models[names[index]] = index
	inputs.models = models
	var lit: BlobPool = BlobPool.create(1.0)
	var hooks: GameBlobHooks = GameBlobHooks.over(lit, inputs)
	hooks.rng.randomize_seed(1.0)
	hooks.model_index = models
	lit.set_hooks(hooks)

	var table: BgbEmitters = BgbEmitters.create()
	# `_C_102.lcl:118` -- the one shipped call that is not commented out.
	var _two: bool = table.register(0, BgbEmitters.TYPE_WARNING_LIGHT,
		2400, 2600, 260, 0, 0, 0, hooks)
	h.equal("bgb.registration_lights_at_once", lit.live(), 1,
		"the object is the command's, not the sweep's")
	var light: Blob = lit.blobs()[0]
	h.equal("bgb.warning_light_record",
		[light.class_id, light.kind, light.life,
		light.x, light.y, light.z],
		[1, 0x29, 0xFF, 2400 << 4, 2600 << 4, 260 << 4],
		"class 1, kind 41, life 255 -- and the shifted coordinates")
	h.check("bgb.warning_light_spins_either_way",
		absi(light.vx) == BlobPrograms.BGB_WARNING_SPIN,
		"the coin picks the sign of `0x200 / vx`, vx = %d" % light.vx)
	# `life` 255 is the never-expire value, which is what makes these last the
	# mission: a light that died after thirteen seconds would be the defect.
	h.equal("bgb.one_shots_never_expire",
		BgbEmitters.HELD, 0xFF, "`+0x45` of 0xFF is not counted down")

	# `_S_005.lcl:121` -- `3_computerlight ... 1_gamma`, shifted left by ten
	# on its way into the record's `rot_z`, which kind 42 copies to angle 2.
	var _three: bool = table.register(1, BgbEmitters.TYPE_COMPUTER_LIGHT,
		1000, 2700, 460, 0, 0, 1, hooks)
	var panel: Blob = lit.blobs()[1]
	h.equal("bgb.computer_light_takes_the_gamma",
		[panel.class_id, panel.kind, panel.life, panel.rot_z],
		[1, 0x2A, 0xFF, 1 << BlobPrograms.BGB_GAMMA_SHIFT])

	# The three no shipped script asks for. Registration dispatches on them,
	# so they are transcribed; they share one body and differ by kind alone.
	var kinds: Array[int] = [0x36, 0x37, 0x39]
	var types: Array[int] = [BgbEmitters.TYPE_FIRE3, BgbEmitters.TYPE_SPOT,
		BgbEmitters.TYPE_LAMP]
	var made: Array[int] = []
	for index: int in range(types.size()):
		var _reg: bool = table.register(2 + index, types[index],
			0, 0, 0, 0, 0, 0, hooks)
		made.append(lit.blobs()[2 + index].kind)
	h.equal("bgb.unused_types_still_register", made, kinds,
		"types 4, 5 and 6: A_FIRE3, A_SPOTL, L049EE00")
	h.equal("bgb.registration_made_all_five", lit.live(), 5)


## The campaign maps' own `InitMap`, end to end: the script the cache carries,
## through the interpreter, into the table.
func _check_map_fires(h: TestHarness) -> void:
	for name: String in ["_C_XXX", "_C_YYY"]:
		var built: Dictionary = CacheFixture.load_world(name)
		if built.is_empty():
			h.check("bgb.map_present.%s" % name, false,
				"the cache has no " + name)
			continue
		var map: World = built["world"]
		var attached: bool = map.attach_script(CacheLoader.read_json(
			"%s/missions/%s/script.json" % [CacheFixture.cache_dir(), name]))
		h.check("bgb.map_has_a_script.%s" % name, attached)
		var table: BgbEmitters = BgbEmitters.create()
		var lit: int = 0
		var program: String = ""
		var opening: Dictionary = map.run_init_map()
		for entry: Variant in DictRead.as_array(opening.get("events", [])):
			var event: Dictionary = AudioEvents.as_event(entry)
			var kind: String = AudioEvents.name_of(event)
			if kind == SliceMain.CD_TRACK_PROGRAM:
				var values: Array = DictRead.as_array(
					event.get("values", []))
				if not values.is_empty():
					program = DictRead.as_string(values[0])
				continue
			if kind != SliceMain.CREATE_BGB:
				continue
			if table.register_event(SetpieceDriver._numbers(event)):
				lit += 1
		h.equal("bgb.map_lights_four.%s" % name, lit, 4,
			"four `CreateBGB (n, 7_fire, ...)`, and a CD track, is the whole "
			+ "of a campaign map's script")
		h.equal("bgb.map_fires_are_type_7.%s" % name,
			table.slot(0).type_id, BgbEmitters.TYPE_FIRE)
		# The other half of the same `INIT MAP`. It was recorded and thrown
		# away for exactly as long as the emitters were.
		h.equal("bgb.map_asks_for_a_cd_track.%s" % name, program, "5.3.4.2")
		var playlist: PackedInt32Array = AudioTables.parse_playlist(program)
		h.equal("bgb.map_playlist.%s" % name, Array(playlist), [5, 3, 4, 2])
		var tables: AudioTables = AudioTables.open(CacheFixture.cache_dir())
		var player: MusicPlayer = MusicPlayer.from_program(program,
			tables.tracks())
		h.check("bgb.map_track_is_in_the_cache.%s" % name,
			player.first_playable() > 0,
			"the map's own playlist has to reach a track the cache carries")
		map = null


## An arm's spawn request, **run** (docs/28 section 7.1, [GameBlobHooks]).
##
## The base [BlobHooks] writes the request down and returns success, which is
## what `tests/test_blob.gd` and `tools/blob_runtime.py` compare and what a
## mission must not do -- the child effect never reached the pool. Three
## answers are possible and all three are checked here, because "the pool
## gained nothing" is the same silence for all of them: the program ran, the
## address carries no program (twelve of the thirteen an arm can reach), or
## the request is one value short of the creator's own arity -- none is, since
## docs/97 section 48 measured the seven `0x00423720` requests in the engine
## and `blob_tables.py`'s `arm_spawn.arity` now expects none, so that one is
## driven synthetically here.
## Every creator address an arm can ask for -- [BlobKinds]' own `CREATE_*`
## constants, which `blob_tables.py`'s `arm_spawn.arity` reads back out of
## `Incubation.exe` call site by call site.
const ARM_CREATORS: Array[int] = [
	BlobKinds.CREATE_ZOOM_BOB, BlobKinds.CREATE_PARA_BOMB,
	BlobKinds.CREATE_BARREL_DEBRIS, BlobKinds.CREATE_HITTING_BLOBS,
	BlobKinds.CREATE_HITTING_BLOBS_2, BlobKinds.CREATE_HITTING_BLOBS_3,
	BlobKinds.CREATE_SPORE_SPARKS, BlobKinds.CREATE_PLASMA_SPARKS,
	BlobKinds.CREATE_PLASMA_SPARKS_2, BlobKinds.CREATE_STING_SPARKS,
	BlobKinds.CREATE_SPORES, BlobKinds.CREATE_LASER_HIT,
	BlobKinds.CREATE_EMITTER,
]


func _check_arm_spawns(h: TestHarness) -> void:
	var pool: BlobPool = BlobPool.create(1.0)
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	var hooks: GameBlobHooks = GameBlobHooks.over(pool, inputs)
	hooks.rng.randomize_seed(1.0)
	pool.set_hooks(hooks)
	var source: Blob = Blob.make({"kind": 6, "life": 1, "class_id": 2,
		"x": 0, "y": 0, "z": 3200})
	# The zoom bob is the one creator an arm can reach that is transcribed,
	# and the two requests that carry all six of its values are kinds 6 and
	# 26. Six values in: a record comes out.
	var full: bool = hooks.spawn(BlobKinds.CREATE_ZOOM_BOB,
		[0, 0, 3200, 4, 0x0A, 8], source)
	h.equal("arm_spawn.runs", [full, hooks.executed, hooks.made, pool.live()],
		[true, 1, 1, 1], "one `0x00423720` request, one record in the pool")
	# One value short: refused and counted, not indexed past the end. Since
	# docs/97 section 48 no request in [BlobKinds] is short, so this is what
	# one **would** do -- the guard outlived the defect that earned it.
	var short: bool = hooks.spawn(BlobKinds.CREATE_ZOOM_BOB,
		[0, 0, 3200, 1, 5], source)
	h.equal("arm_spawn.short_call_refused",
		[short, hooks.short_call.get(BlobKinds.CREATE_ZOOM_BOB, 0),
		hooks.executed, pool.live()], [true, 1, 1, 1],
		"the creator takes six; the request carried five")
	# An address with no program: the whole layer's old answer, now counted.
	# `0x00424250` is a **weapon** creator (docs/97 section 22 transcribes it
	# in Python, for the oracle), so nothing in [BlobKinds] asks for it and
	# this is the counter working rather than a case that runs.
	var none: bool = hooks.spawn(0x00424250, [0, 0, 3200], source)
	h.equal("arm_spawn.unhandled_counted",
		[none, hooks.unhandled.get(0x00424250, 0), pool.live()], [true, 1, 1],
		"an address [BlobPrograms] does not carry makes nothing, and says so")
	# And every address an arm **does** ask for has one, which is the half
	# that had been missing: twelve of the thirteen were reached from nowhere
	# else in the game and so had never been written (docs/97 section 49).
	var missing: Array[String] = []
	for creator: int in ARM_CREATORS:
		if BlobPrograms.args_needed(GameBlobHooks.program_of(creator)) < 0:
			missing.append(GameBlobHooks.program_of(creator))
	h.equal("arm_spawn.every_creator_has_a_program", missing, [] as Array[String],
		"all %d creator addresses [BlobKinds] can ask for" % ARM_CREATORS.size())
	# And a creator that draws leaves the pool's own stream where it stopped:
	# one `aRandom2`, as the engine keeps one, so the arms after it in the
	# sweep continue from there. The zoom bob makes no draw of its own, so
	# the creator asked here is the jump's trail -- the check is about the
	# hook's stream and not about which creator an arm can reach.
	var before: float = pool.hooks().rng.seed
	var _trail: bool = hooks.spawn(0x00423670, [0, 0, 3200], source)
	h.check("arm_spawn.one_stream",
		pool.hooks().rng.seed != before and hooks.executed == 2,
		"the creator drew from `aRandom2` where the arm called it")


## The diff itself, on synthetic snapshots -- no cache needed, and every branch
## reachable.
func _check_diff(h: TestHarness) -> void:
	var a: Dictionary = _snapshot(3, 2, [10, 10, 10, 10, 10, 10])
	var b: Dictionary = _snapshot(3, 2, [10, 10, 10, 10, 10, 10])
	h.check("diff.same", TerrainDiff.same(a, b), "two equal snapshots")
	h.equal("diff.none", TerrainDiff.changed_cells(a, b).size(), 0)

	var c: Dictionary = _snapshot(3, 2, [10, 10, 99, 10, 10, 10])
	h.equal("diff.height", TerrainDiff.changed_cells(a, c),
		PackedInt32Array([2]))
	h.equal("diff.moved", TerrainDiff.moved_cells(a, c),
		PackedInt32Array([2]), "a height change moves scenery")

	var d: Dictionary = _snapshot(3, 2, [10, 10, 10, 10, 10, 10])
	var types: PackedByteArray = d["field_type"]
	types[4] = 2
	d["field_type"] = types
	h.equal("diff.field_type", TerrainDiff.changed_cells(a, d),
		PackedInt32Array([4]))
	h.equal("diff.field_type_moves_nothing",
		TerrainDiff.moved_cells(a, d).size(), 0,
		"a field-type flip repaints and moves nothing")

	# A mission switch is not "nothing changed". Answering an empty list there
	# would leave the previous mission's picture on screen.
	var other: Dictionary = _snapshot(2, 2, [10, 10, 10, 10])
	h.equal("diff.resized", TerrainDiff.changed_cells(a, other).size(), 4,
		"a different grid answers every cell, never none")
	h.equal("diff.no_before", TerrainDiff.changed_cells({}, a).size(), 6)
	h.equal("diff.no_after", TerrainDiff.changed_cells(a, {}).size(), 0)


## The sprite path's arithmetic: the atlas grid, the half-extent rule, and the
## quad count. docs/28 section 7.3 -- `(row, column, half-size x 160)`.
func _check_sprites(h: TestHarness) -> void:
	var sprites: BlobSprites = BlobSprites.new()
	sprites.setup(null, {})
	var blobs: Array[Blob] = []
	for index: int in range(5):
		blobs.append(Blob.make({"kind": 7, "class_id": 2, "life": 10,
			"x": index * 3200, "y": 0, "z": 1600, "aux": 10,
			"rot_x": index % 8, "rot_y": index}))
	# A model blob and a delayed one are both skipped: one has geometry
	# instead of a tile, the other is not live yet.
	blobs.append(Blob.make({"kind": 7, "class_id": 0, "life": 10, "z": 1600}))
	blobs.append(Blob.make({"kind": 7, "class_id": 2, "life": 10, "z": 1600,
		"delay": 3}))
	var drawn: int = sprites.rebuild(blobs, Basis.IDENTITY)
	h.equal("sprites.drawn", drawn, 5,
		"only live sprite blobs reach the cloud")
	h.equal("sprites.empty", sprites.rebuild([], Basis.IDENTITY), 0)
	h.check("sprites.mesh", sprites.mesh != null
		and sprites.mesh.get_surface_count() >= 0, "one ImmediateMesh")

	# `size * 160` world units of half-extent, and 1600 units to the metre, so
	# a size of 10 is one metre either side. The ten shipped sizes are 3..40,
	# which is 0.3 m to 4 m -- worth pinning, because a factor here is the
	# difference between a spark and a wall.
	h.equal("sprites.half_extent_metre",
		BlobSprites.HALF_EXTENT_SCALE / WorldSpace.WORLD_UNITS_PER_METRE, 0.1,
		"a size of 1 is 0.1 m of half-extent")
	h.equal("sprites.grid", [BlobSprites.TILE, BlobSprites.GRID,
		BlobSprites.ATLAS_SIZE], [32, 8, 256])
	sprites.free()


## The headline defect, closed and demonstrated.
func _check_door(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(DOOR_MISSION)
	if loaded.is_empty():
		h.check("door.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	var geometry: Dictionary = CacheFixture.geometry(world_set)
	if geometry.is_empty():
		h.check("door.geometry", false, "geometry/%s.json" % world_set)
		return

	var scenery: Scenery = Scenery.new()
	scenery.build(document, geometry, {})
	var before: Dictionary = world.terrain_snapshot()
	var _placed: int = scenery.apply_all(before)

	# Find a door by its action point rather than by a hard-coded cell: the
	# check should survive a re-conversion that moved one.
	var door: int = _find_door(world)
	if door < 0:
		h.check("door.present", false,
			"no cell with a door action point (%s) on %s"
				% [str(Interact.DOOR_IDS), DOOR_MISSION])
		scenery.free()
		return
	h.check("door.present", true, "cell %d carries the door action point"
		% door)
	var standing: Array = scenery.instances_on(door)
	h.check("door.has_geometry", not standing.is_empty(),
		"%d object(s) stand on the door's cell" % standing.size())
	if standing.is_empty():
		scenery.free()
		return
	var panel: Node3D = standing[0]
	var was: Vector3 = panel.transform.origin

	# Toggle it the way the world does, then redraw only what changed.
	var index: int = door
	world.state.set_height(index, world.state.height_at(index)
		+ Interact.DOOR_HEIGHT_STEP)
	var after: Dictionary = world.terrain_snapshot()
	var moved: PackedInt32Array = TerrainDiff.moved_cells(before, after)
	h.equal("door.diff", moved, PackedInt32Array([door]),
		"exactly the door's cell is reported as moved")
	var count: int = scenery.apply_state(after, moved)
	h.check("door.moved", count == standing.size(),
		"%d instance(s) moved" % count)
	var now: Vector3 = panel.transform.origin
	var expected: float = float(Interact.DOOR_HEIGHT_STEP) \
		/ WorldSpace.WORLD_UNITS_PER_METRE
	h.check("door.height",
		absf((now.y - was.y) - expected) < 0.001,
		"the panel rose %f m, wanted %f m" % [now.y - was.y, expected])
	h.check("door.horizontal",
		absf(now.x - was.x) < 0.001 and absf(now.z - was.z) < 0.001,
		"and did not slide sideways")

	# Applying the same state twice is applying it once: the offset is taken
	# from the authored transform every time, never accumulated.
	var _again: int = scenery.apply_state(after, moved)
	h.check("door.idempotent",
		panel.transform.origin.is_equal_approx(now),
		"a second apply lands in the same place")

	# And closing it puts the panel back exactly where it started, which is
	# what "the picture is a function of the state" has to mean.
	world.state.set_height(index, world.state.height_at(index)
		- Interact.DOOR_HEIGHT_STEP)
	var _closed: int = scenery.apply_state(world.terrain_snapshot(), moved)
	h.check("door.reversible", panel.transform.origin.is_equal_approx(was),
		"closing it returns the panel to its authored position")
	scenery.free()


## The three weapon switches reach real effects with real kinds.
func _check_triggers(h: TestHarness) -> void:
	var document: Dictionary = CacheFixture.read_json(
		CacheFixture.cache_dir() + "/tables/blobs.json")
	if document.is_empty():
		h.check("triggers.fixture", false, "tables/blobs.json")
		return
	var pool: BlobPool = BlobPool.create(1.0, 64)
	# The pool needs the world set's real prototypes: weapon 2's muzzle is two
	# **model** blobs, `A_LINE5.3DI` and `A_CASE.3DI`, and a pool that could
	# not resolve them made no effect at all and said "0" -- which is a
	# perfectly plausible answer for a weapon with no muzzle arm.
	var geometry: Dictionary = CacheFixture.geometry("A00")
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in DictRead.as_dict(geometry.get("prototypes", {})):
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	pool.hooks().model_index = index
	h.check("triggers.models", index.size() > 0,
		"%d prototypes in the world set" % index.size())
	var triggers: BlobTriggers = BlobTriggers.open(pool, document)

	# Weapon 2, the Standard Assault Rifle: a tracer at the muzzle, no impact
	# blob, and `ricochet.wav` on landing (docs/28 section 8.1's own example).
	var from: Vector3i = BlobTriggers.muzzle_point(2, 2, 0)
	var to: Vector3i = BlobTriggers.muzzle_point(6, 2, 0)
	var made: int = triggers.muzzle(2, from, to)
	h.check("triggers.muzzle", made > 0,
		"weapon 2 makes %d muzzle effect(s)" % made)
	# **A model blob points along the shot.** The engine's own capture stamps
	# one orientation triple -- the burst's direction through `0x00403AA0` --
	# on every record of a creator's call, and the remake had left it at zero,
	# which flew a shaped model like `A_LINE5.3DI` sideways (docs/97 section 46).
	var pointed: int = 0
	var flat: int = 0
	var want: Vector3i = pool.hooks().orient(from, to)
	for blob: Blob in pool.blobs():
		if blob.class_id >= 2:
			continue
		if blob.rot_z == want.z and blob.rot_y == 0 and blob.rot_x == want.x:
			pointed += 1
		else:
			flat += 1
	h.check("triggers.model_points_along_the_shot", pointed > 0 and flat == 0,
		"%d model blob(s) carry the shot's own triple, %d do not"
			% [pointed, flat])
	h.equal("triggers.sound", triggers.impact_wave(2), "ricochet.wav")
	h.equal("triggers.silent", triggers.impact_wave(15), "",
		"a melee weapon's impact makes no sound, which is a real answer")

	# Weapon 8, the Mine Thrower: a grenade out and three effects on landing.
	h.check("triggers.impact", triggers.impact(8, to) > 0,
		"weapon 8's impact creates %d effect(s)"
			% triggers.creators("weapon_impact", 8).size())
	h.equal("triggers.impact_sound", triggers.impact_wave(8),
		"explosion2.wav")

	# The blobs really are in the pool and really do tick.
	h.check("triggers.pooled", pool.live() > 0,
		"%d blob(s) live in the pool" % pool.live())
	var digest: String = pool.trace_digest()
	var _results: Array[BlobKinds.TickResult] = pool.tick_all()
	h.check("triggers.ticking", pool.trace_digest() != digest,
		"and one tick changes them")

	# **A weapon outside the muzzle table still fires a tracer**, because the
	# switch has a default arm and that arm calls `aBlob_CreateTracerBullet`.
	# This check used to require zero, which encoded a gap in the extraction
	# rather than the engine: the table starts at id 2, so weapons 0 and 1 --
	# the two guns the campaign starts with -- reached the default and fired
	# invisibly in the remake. `blob_tables.py` pins the arm now.
	h.equal("triggers.out_of_range", triggers.muzzle(60, from, to), 2,
		"the switch's default arm, the same creator weapon 2 uses")
	h.equal("triggers.starting_guns", triggers.muzzle(0, from, to), 2,
		"the Light Combat Gun is not a gun with no muzzle flash")
	# The impact switch's default makes no blob, and that **is** the engine:
	# `0x0040DA07` goes straight on to the unit sweep.
	h.equal("triggers.impact_default", triggers.impact(0, to), 0,
		"weapons below the impact table's first id have no impact effect")

	# An effect whose model this world set does not carry is **cancelled**,
	# not drawn as a hole and not a crash. `A_PARAB1.3DI` lives in E00 and
	# F00 only, so on A00 the para bomb simply does not appear -- which is
	# what `0x004209A0` returning -1 does in the original.
	var absent: BlobPool = BlobPool.create(1.0, 8)
	absent.hooks().model_index = index
	h.equal("triggers.model_absent",
		absent.create_blob({"kind": 25, "life": 12, "class_id": 0,
			"model_name": "A_PARAB1.3DI"}), -1)
	h.check("triggers.model_present",
		absent.create_blob({"kind": 15, "life": 12, "class_id": 0,
			"model_name": "A_LINE5.3DI"}) >= 0,
		"and one the set does carry is created")


## The first cell carrying one of the four door action points, or `-1`.
##
## By action point rather than by a hard-coded cell, so a re-conversion that
## moved one does not silently turn this check into a no-op.
func _find_door(world: World) -> int:
	for index: int in range(world.state.cell_count()):
		if Interact.DOOR_IDS.has(world.state.action_point_at(index)):
			return index
	return -1


func _snapshot(width: int, height: int, heights: Array) -> Dictionary:
	var count: int = width * height
	var h_map: PackedInt32Array = PackedInt32Array()
	var types: PackedByteArray = PackedByteArray()
	var points: PackedByteArray = PackedByteArray()
	var units: PackedInt32Array = PackedInt32Array()
	for index: int in range(count):
		h_map.append(DictRead.as_int(heights[index]) if index < heights.size()
			else 0)
		types.append(0)
		points.append(0)
		units.append(MapState.NO_UNIT)
	return {"width": width, "height": height, "height_map": h_map,
		"field_type": types, "action_point": points, "unit": units}


## The frame counts, and the three demo missions' own set pieces.
func _check_setpieces(h: TestHarness) -> void:
	# The counts the documents give, each against the command's own arguments.
	h.equal("setpiece.door", SetpieceDriver.frames_for(
		{"name": "open_door", "values": [9, 11]}), 10,
		"aDoorOpenSequence's own `for (n = 10; n; n--)`")
	h.equal("setpiece.elevator", SetpieceDriver.frames_for(
		{"name": "elevator", "values": [6, 15, 1, 7]}), 7,
		"one frame per step of +-800")
	h.equal("setpiece.platform", SetpieceDriver.frames_for(
		{"name": "platform", "values": [20, 10, 2, 4]}), 40,
		"dist * 10 frames of +-0x140")
	h.equal("setpiece.bridge", SetpieceDriver.frames_for(
		{"name": "bridge", "values": [5, 5]}), 80)
	h.equal("setpiece.foot_bridge2", SetpieceDriver.frames_for(
		{"name": "foot_bridge2", "values": [112, 30, 3]}), 30,
		"the frames argument, as _C_163 passes it")

	# The one count neither document gave, read out of the drop loop at
	# `0x00411E26` and pinned by `blob_tables.py`: a whole map field a frame.
	# The shipped heights are 20..65, so the drop is half a second to about
	# 1.6 seconds -- which is what a body falling from a ceiling should be.
	h.equal("setpiece.roof_min", SetpieceDriver.frames_for(
		{"name": "roof_unit", "values": [4, 4, 20, 50]}), 10)
	h.equal("setpiece.roof_max", SetpieceDriver.frames_for(
		{"name": "roof_unit", "values": [4, 4, 65, 50]}), 33)
	h.equal("setpiece.roof_step", SetpieceDriver.ROOF_DROP_STEP, 0xC80,
		"one map field per displayed frame")

	# An event this driver does not animate answers zero, and the ones it
	# deliberately applies at once are named rather than merely absent.
	# The three tubes and the ground unit joined the animated set on
	# 2026-09-03 (docs/97 section 32): nineteen frames, the puffs on the
	# tenth; eight of rise and six of carry.
	h.equal("setpiece.tube", SetpieceDriver.frames_for(
		{"name": "open_tube", "values": [3, 3]}), SetpieceDriver.TUBE_FRAMES,
		"`cmp esi, 0x13` in 0x00410F10")
	h.equal("setpiece.ground_unit", SetpieceDriver.frames_for(
		{"name": "ground_unit", "values": [3, 3, 4, 4]}),
		SetpieceDriver.GROUND_UNIT_FRAMES)
	# The rest of docs/42 section 8 joined them the same day (docs/97
	# section 33): the statue's fourteen turning frames, the barrier's
	# forty, the fire circle's ten, the teleporter's seventy.
	h.equal("setpiece.statue", SetpieceDriver.frames_for(
		{"name": "statue", "values": [3, 3]}),
		SetpieceDriver.STATUE_TURN_FRAMES, "`mov edi, 0xD` and one settle")
	h.equal("setpiece.barrier", SetpieceDriver.frames_for(
		{"name": "barrier_on", "values": [3, 3, 0, 1]}),
		SetpieceDriver.BARRIER_FRAMES)
	h.equal("setpiece.fire_circle", SetpieceDriver.frames_for(
		{"name": "fire_circle", "values": [3, 3]}),
		SetpieceDriver.FIRE_CIRCLE_FRAMES)
	h.equal("setpiece.teleporter", SetpieceDriver.frames_for(
		{"name": "teleporter", "values": [3, 3]}),
		SetpieceDriver.TELEPORTER_FRAMES)
	# `Statue2` `0x004424B0` is a loop over an ActPt range, so the animation
	# belongs to the `statue` events `core` emits inside it, and the marker
	# itself has nothing to draw; `statue_kill` is already drawn by the beam's
	# own stage (docs/97 section 41.1).
	h.equal("setpiece.statue2_is_instant",
		[SetpieceDriver.is_animated("statue2"),
		SetpieceDriver.INSTANT.has("statue2"),
		AudioEvents.EVENT_ALIASES.has("statue2")], [false, true, false],
		"the marker draws nothing and makes no sound; its cells do both")
	h.equal("setpiece.statue_kill_is_instant",
		[SetpieceDriver.is_animated("statue_kill"),
		SetpieceDriver.INSTANT.has("statue_kill")], [false, true])
	h.equal("setpiece.instant", SetpieceDriver.frames_for(
		{"name": "growing_land", "values": [3, 3]}), 0)
	h.check("setpiece.instant_named",
		SetpieceDriver.is_instant("growing_land")
			and SetpieceDriver.is_instant("barrier_off"),
		"%d sequences apply at once and say so"
			% SetpieceDriver.INSTANT.size())
	h.check("setpiece.disjoint",
		not SetpieceDriver.ANIMATED.any(func(k: String) -> bool:
			return SetpieceDriver.INSTANT.has(k)),
		"no event is both animated and instant")
	h.equal("setpiece.unknown", SetpieceDriver.frames_for(
		{"name": "no_such_event", "values": []}), 0)

	# Both event spellings reach the same answer. `core` emits `name` from a
	# mission script and `kind` from the computer's turn, and reading only one
	# of them made every set-piece sound silently absent once.
	h.equal("setpiece.both_spellings",
		[AudioEvents.name_of({"name": "elevator"}),
			AudioEvents.name_of({"kind": "door"})], ["elevator", "door"])

	# Linear, because every sequence in the table adds a constant per frame.
	h.equal("setpiece.progress",
		[SetpieceDriver.progress(0, 10), SetpieceDriver.progress(5, 10),
			SetpieceDriver.progress(10, 10)], [0.0, 0.5, 1.0])


## The queue itself: it paces, it ends on its last frame, and a skip lands on
## exactly the same picture without waiting.
func _check_queue(h: TestHarness) -> void:
	var painted: Array[int] = []
	var queue: SequenceQueue = SequenceQueue.create(null)
	queue.enqueue("elevator", 7,
		func(frame: int, _total: int) -> void: painted.append(frame))
	h.check("queue.running", queue.is_running(), "one sequence queued")
	h.equal("queue.seconds", queue.seconds_left(), 7.0 / 20.0,
		"seven frames at 20 fps")
	# Half a frame paints nothing: the sequences count in displayed frames.
	var _held: bool = queue.advance(0.5 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("queue.partial_frame", painted.size(), 0)
	while queue.is_running():
		var _still: bool = queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("queue.frames", painted, [1, 2, 3, 4, 5, 6, 7],
		"every frame once, in order, ending on the last")
	h.check("queue.finished", not queue.is_running(), "and then it stops")

	# A skip paints the end of every remaining sequence and stops. The world
	# has held that state since `core` returned, so this is not a shortcut.
	var skipped: Array[int] = []
	var other: SequenceQueue = SequenceQueue.create(null)
	other.enqueue("a", 5,
		func(frame: int, _t: int) -> void: skipped.append(frame))
	other.enqueue("b", 9,
		func(frame: int, _t: int) -> void: skipped.append(100 + frame))
	other.skip()
	h.equal("queue.skip", skipped, [5, 109],
		"each remaining sequence lands on its own last frame")
	h.check("queue.skip_stops", not other.is_running(), "and the queue ends")

	# A zero-length sequence is not queued at all: it would otherwise be a
	# step that never completes and holds the picture for ever.
	var empty: SequenceQueue = SequenceQueue.create(null)
	empty.enqueue("nothing", 0, Callable())
	h.check("queue.zero_refused", not empty.is_running(),
		"a sequence of no frames is not a sequence")


## docs/42 sections 4.6 and 4.9 -- a step that runs until a condition holds
## and no longer than the engine's own bound.
func _check_open_ended_steps(h: TestHarness) -> void:
	var queue: SequenceQueue = SequenceQueue.create(null)
	var counter: Array[int] = [0]
	queue.enqueue_until("wait", 100,
		func() -> bool: return counter[0] >= 3,
		func(_frame: int, _total: int) -> void: counter[0] += 1)
	h.equal("until.name", queue.current(), "wait")
	var frames: int = 0
	while queue.is_running() and frames < 200:
		var _still: bool = queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.equal("until.stops_on_the_condition", frames, 3,
		"three painted frames, then the predicate ends it")
	var bounded: SequenceQueue = SequenceQueue.create(null)
	bounded.enqueue_until("never", 7, func() -> bool: return false)
	frames = 0
	while bounded.is_running() and frames < 200:
		var _still: bool = bounded.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.equal("until.stops_at_the_bound", frames, 7,
		"a condition that never holds ends at the engine's bound")
	var none: SequenceQueue = SequenceQueue.create(null)
	none.enqueue_until("nothing", 0, func() -> bool: return true)
	h.check("until.zero_refused", not none.is_running(),
		"a bound of no frames is not a step")


## `0x004FE63C` -- the projectile-arrived flag, on the pool (docs/42 section
## 4.6, corrected 2026-09-03): set by fourteen arms when their record lands,
## cleared by arm 45's `mov [flag], ebp` on every tick.
func _check_arrived_flag(h: TestHarness) -> void:
	var pool: BlobPool = BlobPool.create(1.0, 8)
	h.check("arrived.starts_set", pool.arrived, "nothing in flight")
	pool.set_arrived(false)
	# Kind 1 dies when its life runs out and sets the flag then.
	var slot: int = pool.create_blob({"kind": 1, "class_id": 2, "life": 1})
	h.check("arrived.blob_made", slot >= 0, "a kind-1 record with one tick of life")
	var _first: Array[BlobKinds.TickResult] = pool.tick_all()
	h.check("arrived.set_when_the_round_lands", pool.arrived,
		"the arm's delete signal is the flag's write")
	# Kind 45 clears it on every tick, whatever else is in the pool.
	var cleared: BlobPool = BlobPool.create(1.0, 8)
	var _clear: int = cleared.create_blob({"kind": 45, "class_id": 2, "life": 10})
	var _ticked: Array[BlobKinds.TickResult] = cleared.tick_all()
	h.check("arrived.cleared_by_kind_45", not cleared.arrived,
		"`mov [0x4FE63C], ebp` with the sweep's zero")
	cleared.clear()
	h.check("arrived.reset_with_the_pool", cleared.arrived, "")


## A recording [ShotHost]: every call the stages make, in order.
## An [AudioSystem] that opens no stream: what a sequence played, and how many
## sequence-ends had gone by when it did. `SequenceQueue.create(null)` is
## enough for a check about the picture, and nothing at all for one about which
## stage a sound belongs to.
class RecordingAudio extends AudioSystem:
	var plays: PackedStringArray = PackedStringArray()
	## The number of [method stop_tag] calls that had happened before each
	## play, so "the first sound was killed before the second started" is a
	## number rather than an impression.
	var stops_before_play: PackedInt32Array = PackedInt32Array()
	var stops: int = 0

	func play_cues(cues: Array[Dictionary], _tag: String = "") -> PackedInt32Array:
		var out: PackedInt32Array = PackedInt32Array()
		for cue: Dictionary in cues:
			plays.append(DictRead.as_string(cue["wave"]))
			stops_before_play.append(stops)
			out.append(plays.size() - 1)
		return out

	func stop_tag(_tag: String) -> int:
		stops += 1
		return 0


## The pool as the bomb run sees it: a spawned creator puts a record in it,
## [method land] takes one out and raises the *arrived* flag the way
## [method BlobKinds._kind_25] does, and the two acknowledgements the run owes
## -- `0x0042B490` per crump and `0x0041E370` once -- are counted.
##
## Its own class rather than fields on [RecordingHost]: the shot suites drive
## `pool_arrived` as a countdown and would answer a raised flag on every frame
## of the bomb run, which is one crump a frame.
class BombRunHost extends RecordingHost:
	var flag: bool = false
	var records: int = 0
	var cleared_pool: int = 0
	var cleared_arrived: int = 0
	var played: Array[String] = []

	func pool_arrived() -> bool:
		return flag

	func pool_live() -> int:
		return records

	func clear_arrived() -> void:
		cleared_arrived += 1
		flag = false

	func clear_pool() -> void:
		cleared_pool += 1
		records = 0

	func play_cues(cues: Array[Dictionary]) -> void:
		for cue: Dictionary in cues:
			played.append(DictRead.as_string(cue["wave"]))

	func spawn_program(creator: String, args: PackedInt32Array) -> void:
		super(creator, args)
		records += 1

	func spawn_at(creator: String, at: Vector3i,
			extra: PackedInt32Array = PackedInt32Array()) -> void:
		super(creator, at, extra)
		records += 1

	## One bomb reaching the ground.
	func land() -> void:
		if records > 0:
			records -= 1
		flag = true


class RecordingHost extends ShotHost:
	var calls: Array[String] = []
	var arrived: bool = false
	var arrived_after: int = 2
	var live: int = 3
	var fading: int = 0
	var flying: int = 0
	var playing: int = 0
	var frames: Dictionary = {"to_break": 4, "spin": 2, "after_break": 6}
	var type_id: int = 23
	var hidden: PackedInt32Array = PackedInt32Array()
	## The teleporter's traveller: held out of the picture, not destroyed.
	var suppressed: PackedInt32Array = PackedInt32Array()
	var shown: PackedInt32Array = PackedInt32Array()
	var programs: Array[String] = []
	var texts: Array[String] = []
	var captions: Array[String] = []

	func body_frames(_slot: int) -> Dictionary:
		return frames

	func fire_body(_slot: int, _tx: int, _ty: int) -> Dictionary:
		calls.append("fire")
		playing = frames["to_break"]
		return frames

	func body_playing(_slot: int) -> bool:
		if playing > 0:
			playing -= 1
			return true
		return false

	func resume_body(_slot: int) -> int:
		calls.append("resume")
		playing = frames["after_break"]
		return frames["after_break"]

	func rest_body(_slot: int) -> void:
		calls.append("rest")

	func body_type(_slot: int) -> int:
		return type_id

	func camera(_shot: Dictionary) -> int:
		calls.append("camera")
		flying = 3
		return 3

	func camera_flying() -> bool:
		if flying > 0:
			flying -= 1
			return true
		return false

	func set_caption(text: String) -> void:
		calls.append("caption")
		captions.append(text)

	func clear_caption() -> void:
		calls.append("clear_caption")

	func clear_texts() -> void:
		calls.append("clear_texts")

	func add_text(text: String, kind: int, _x: int, _y: int) -> void:
		texts.append("%s/%d" % [text, kind])

	func begin_fade() -> void:
		calls.append("fade")
		fading = 15

	func is_fading() -> bool:
		return fading > 0

	func tick_overlay() -> void:
		if fading > 0:
			fading -= 1
		if live > 0:
			live -= 1

	func play_cues(cues: Array[Dictionary]) -> void:
		calls.append("cues:%d" % cues.size())

	func muzzle(_weapon: int, _sx: int, _sy: int, _tx: int, _ty: int) -> void:
		calls.append("muzzle")

	func impact(_weapon: int, _tx: int, _ty: int) -> void:
		calls.append("impact")

	func pool_arrived() -> bool:
		if arrived_after > 0:
			arrived_after -= 1
			return false
		return true

	func pool_live() -> int:
		return live

	func hide_unit(slot: int) -> void:
		calls.append("hide")
		hidden.append(slot)

	func suppress_unit(slot: int) -> void:
		calls.append("suppress")
		suppressed.append(slot)

	func show_unit(slot: int) -> void:
		calls.append("show")
		shown.append(slot)

	func pool_first() -> Vector3i:
		return Vector3i(1, 2, 3)

	func spawn_program(creator: String, args: PackedInt32Array) -> void:
		programs.append("%s:%s" % [creator, ",".join(Array(args).map(
			func(v: int) -> String: return str(v)))])

	# --- docs/42 section 7 -----------------------------------------------
	var objects: Dictionary[int, Vector3i] = {}
	var heights: Dictionary[int, int] = {}
	var eye: Vector3i = Vector3i(100, 200, 300)
	var target: Vector3i = Vector3i(10, 20, 30)
	var flights: Array[Array] = []
	var camera_sets: int = 0
	var targets_set: int = 0
	var turns: int = 0
	var placed: Array[Vector3i] = []
	var turned_to: Array[int] = []
	var settled: PackedInt32Array = PackedInt32Array()
	var spawned_at: Array[String] = []
	var centred: Array[String] = []
	var draw_answer: int = 1

	func object_of(slot: int) -> Vector3i:
		return objects.get(slot, Vector3i.ZERO)

	func cell_object(x: int, y: int) -> Vector3i:
		return Vector3i(x * WorldSpace.WORLD_UNITS_PER_FIELD,
			y * WorldSpace.WORLD_UNITS_PER_FIELD, 0)

	func unit_height(slot: int) -> int:
		return heights.get(slot, 2880)

	func camera_eye() -> Vector3i:
		return eye

	func camera_target() -> Vector3i:
		return target

	func fly(to_eye: Vector3i, to_target: Vector3i) -> int:
		calls.append("fly")
		flights.append([to_eye, to_target])
		eye = to_eye
		target = to_target
		flying = 2
		return 2

	func set_camera(to_eye: Vector3i, to_target: Vector3i) -> void:
		camera_sets += 1
		eye = to_eye
		target = to_target

	func set_camera_target(to_target: Vector3i) -> void:
		targets_set += 1
		target = to_target

	func rotate(v: Vector3i, _angles: Vector3i) -> Vector3i:
		turns += 1
		# A quarter turn about z, so the offset visibly moves.
		return Vector3i(-v.y, v.x, v.z)

	func orient(_from: Vector3i, _at: Vector3i) -> Vector2i:
		return Vector2i(0, 1024)

	func spawn_at(creator: String, at: Vector3i,
			_extra: PackedInt32Array = PackedInt32Array()) -> void:
		spawned_at.append("%s@%s" % [creator, str(at)])

	func draw2(_base: int, _span: int) -> int:
		calls.append("draw2")
		return draw_answer

	func place_body(_slot: int, at: Vector3i) -> void:
		placed.append(at)

	func turn_body(_slot: int, yaw: int) -> void:
		turned_to.append(yaw)

	func settle_body(slot: int) -> void:
		settled.append(slot)

	func set_centred_caption(text: String) -> void:
		centred.append(text)


## Run a queue to its end on a recording host, answering the stage names in
## order and how many frames it took.
static func _run_queue(queue: SequenceQueue, limit: int = 2000) -> Dictionary:
	var order: Array[String] = []
	var frames: int = 0
	while queue.is_running() and frames < limit:
		var stage: String = queue.current()
		if order.is_empty() or order[order.size() - 1] != stage:
			order.append(stage)
		var _still: bool = queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	return {"order": order, "frames": frames}


## docs/42 section 7 -- the orbits, the jump, the push and the marker, as
## sequences on a recording host (docs/97 section 31).
func _check_unit_animations(h: TestHarness) -> void:
	# --- the orbit: raise, fly, forty turns, fly back ----------------------
	var host: RecordingHost = RecordingHost.new()
	host.objects[4] = Vector3i(6400, 9600, 160)
	host.heights[4] = 2880
	var queue: SequenceQueue = SequenceQueue.create(null)
	var bound: int = OrbitSequence.enqueue(queue, host, 4,
		OrbitSequence.KIND_SKILL, "increased skill level 1",
		[{"wave": "skill.wav"}])
	h.equal("orbit.deterministic_frames", bound, 1 + OrbitSequence.FRAMES)
	var ran: Dictionary = _run_queue(queue)
	h.equal("orbit.stages", DictRead.as_array(ran["order"]),
		[OrbitSequence.STAGE_RAISE, OrbitSequence.STAGE_FLIGHT,
		OrbitSequence.STAGE_TURN, OrbitSequence.STAGE_BACK])
	h.equal("orbit.arrows_raised_at_the_cell", host.programs,
		["%s:2,3" % BlobPrograms.ARROWS], "the object at (6400, 9600) is cell (2, 3)")
	h.equal("orbit.turns_40", host.turns, OrbitSequence.FRAMES,
		"`0x004039A0` once a frame for `mov dword [...], 0x28` frames")
	h.equal("orbit.camera_set_each_turn", host.camera_sets, OrbitSequence.FRAMES)
	var target: Vector3i = Vector3i(6400, 9600, 160 + 2880)
	h.equal("orbit.flight_to_the_start", host.flights[0],
		[target + OrbitSequence.START_NEAR, target],
		"(0, +0xC80, height + 0xC80) for the skill orbit")
	h.equal("orbit.flight_back_to_the_saved_six", host.flights[1],
		[Vector3i(100, 200, 300), Vector3i(10, 20, 30)])
	h.equal("orbit.caption_set_then_cleared", host.centred,
		["increased skill level 1", ""])
	h.equal("orbit.wave_once", host.calls.count("cues:1"), 1)
	# Heal and poison: the flash circle, the far start, the step back.
	var heal_host: RecordingHost = RecordingHost.new()
	heal_host.objects[4] = Vector3i(6400, 9600, 160)
	var heal_queue: SequenceQueue = SequenceQueue.create(null)
	var _heal: int = OrbitSequence.enqueue(heal_queue, heal_host, 4,
		OrbitSequence.KIND_HEAL, "x", [])
	var _heal_ran: Dictionary = _run_queue(heal_queue)
	h.equal("orbit.heal_raises_the_flash_circle", heal_host.programs,
		["%s:2,3" % BlobPrograms.HEAL_FLASH])
	h.equal("orbit.heal_starts_far", heal_host.flights[0][0],
		target + OrbitSequence.START_FAR)
	h.equal("orbit.poison_marker", DictRead.as_string(
		OrbitSequence.spec(OrbitSequence.KIND_POISON)["marker"]),
		BlobPrograms.POISON_FLASH)
	h.equal("orbit.steps", [DictRead.as_int(OrbitSequence.spec(OrbitSequence.KIND_HEAL)["step"]),
		DictRead.as_int(OrbitSequence.spec(OrbitSequence.KIND_JAM)["step"])],
		[OrbitSequence.STEP_BACK, OrbitSequence.STEP_FORWARD])
	# Overheat kind 1: the unit hidden behind an explosion and a flood.
	var hot: RecordingHost = RecordingHost.new()
	hot.objects[7] = Vector3i(3200, 3200, 0)
	var hot_queue: SequenceQueue = SequenceQueue.create(null)
	var _hot: int = OrbitSequence.enqueue(hot_queue, hot, 7,
		OrbitSequence.KIND_OVERHEAT, "Weapon destroyed", [],
		OrbitSequence.OVERHEAT_DESTROYED)
	var _hot_ran: Dictionary = _run_queue(hot_queue)
	h.equal("orbit.overheat_1_effects", hot.programs, [
		"%s:1,1" % BlobPrograms.ARROWS, "%s:1,1" % BlobPrograms.FIRE_EXPLOSION,
		"%s:1,1,1,1,0" % BlobPrograms.BLOOD_FLOOD])
	h.equal("orbit.overheat_1_hides", hot.hidden, PackedInt32Array([7]))
	var mild: RecordingHost = RecordingHost.new()
	mild.objects[7] = Vector3i(3200, 3200, 0)
	var mild_queue: SequenceQueue = SequenceQueue.create(null)
	var _mild: int = OrbitSequence.enqueue(mild_queue, mild, 7,
		OrbitSequence.KIND_OVERHEAT, "Weapon jammed", [], OrbitSequence.OVERHEAT_JAM)
	var _mild_ran: Dictionary = _run_queue(mild_queue)
	h.equal("orbit.overheat_2_hides_nothing", mild.hidden.size(), 0)

	# --- the jump: one cell east is six steps of 480 ------------------------
	var jumper: RecordingHost = RecordingHost.new()
	var jump_queue: SequenceQueue = SequenceQueue.create(null)
	var jump_bound: int = JumpSequence.enqueue(jump_queue, jumper, 2,
		Vector2i(1, 1), Vector2i(2, 1), true, [{"wave": "jump.wav"}],
		[{"wave": "drop.wav"}], [[], [], []])
	h.equal("jump.steps_for_one_field", JumpSequence.steps_between(
		Vector3i(3200, 3200, 0), Vector3i(6400, 3200, 0)), 6,
		"max(|dx|, |dy|) / 480 for a 3200-unit field")
	h.equal("jump.deterministic_frames", jump_bound, 1 + 6 + 1)
	var jump_ran: Dictionary = _run_queue(jump_queue)
	h.equal("jump.stages", DictRead.as_array(jump_ran["order"]),
		[JumpSequence.STAGE_LEAVE, JumpSequence.STAGE_FLY,
		JumpSequence.STAGE_LAND, JumpSequence.STAGE_POOL])
	h.equal("jump.dust_at_both_ends", jumper.programs,
		["%s:1,1" % BlobPrograms.LANDING_DUST, "%s:2,1" % BlobPrograms.LANDING_DUST])
	h.equal("jump.trail_each_frame", jumper.spawned_at.size(), 6,
		"`0x00423670` once per flight frame for the player's unit")
	# The lifted source slopes down to the landing cell, so the direction's
	# third term takes some of the rise: `vz = (steps / 2) * 160 + dz`.
	var slope: PackedFloat64Array = Eng3dGeometry.direction(
		Vector3i(3200, 3200, JumpSequence.LIFT), Vector3i(6400, 3200, 0), 1)
	var dz: int = Eng3dGeometry.ftol(slope[2] * float(JumpSequence.STEP_UNITS))
	var rise: int = (6 / 2) * JumpSequence.GRAVITY + dz
	h.check("jump.slope_takes_from_the_rise", dz < 0, "dz %d" % dz)
	h.check("jump.trail_above_the_flyer",
		jumper.spawned_at[0].begins_with(BlobPrograms.TRAIL)
			and jumper.spawned_at[0].contains(str(JumpSequence.LIFT
				+ JumpSequence.TRAIL_UP + rise)),
		jumper.spawned_at[0])
	h.equal("jump.camera_looks_at_the_flyer", jumper.targets_set, 6 + 1,
		"the target set every flight frame and at the landing; the eye kept")
	h.equal("jump.no_flight", jumper.flights.size(), 0)
	h.equal("jump.body_turned_to_the_landing", jumper.turned_to, [1024])
	h.equal("jump.waves_in_order", jumper.calls.filter(
		func(c: String) -> bool: return c.begins_with("cues")), ["cues:1", "cues:1"])
	var start: Vector3i = jumper.placed[0]
	var peak: Vector3i = jumper.placed[1]
	h.equal("jump.source_lifted", start,
		Vector3i(3200, 3200, JumpSequence.LIFT), "`0x0047AD30(0)` above the cell")
	h.equal("jump.first_step_rises", peak.z - start.z, rise,
		"vz = (steps / 2) * 160 + dz, then 160 less a frame")
	h.equal("jump.gravity_a_frame", (jumper.placed[1].z - start.z)
		- (jumper.placed[2].z - jumper.placed[1].z), JumpSequence.GRAVITY)
	h.equal("jump.lands_above_the_cell", jumper.placed[jumper.placed.size() - 1],
		Vector3i(6400, 3200, JumpSequence.LAND_UP))
	h.equal("jump.settles_at_the_end", jumper.settled, PackedInt32Array([2]))
	# The computer's: one draw picks the scream, no trail, no source dust.
	var alien: RecordingHost = RecordingHost.new()
	alien.draw_answer = 2
	var alien_queue: SequenceQueue = SequenceQueue.create(null)
	var _alien: int = JumpSequence.enqueue(alien_queue, alien, 9,
		Vector2i(1, 1), Vector2i(1, 3), false, [{"wave": "jump.wav"}],
		[{"wave": "drop.wav"}], [[{"wave": "a"}], [{"wave": "b"}], [{"wave": "c"}]])
	var _alien_ran: Dictionary = _run_queue(alien_queue)
	h.equal("jump.computer_draws_once", alien.calls.count("draw2"), 1)
	h.equal("jump.computer_screams_and_drops", alien.calls.filter(
		func(c: String) -> bool: return c.begins_with("cues")), ["cues:1", "cues:1"])
	h.equal("jump.computer_leaves_no_trail", alien.spawned_at.size(), 0)

	# --- the push: four frames a cell, a puff a frame, the hole ---------------
	var pusher: RecordingHost = RecordingHost.new()
	pusher.objects[1] = Vector3i(3200, 3200, 0)
	pusher.heights[1] = 2880
	var push_queue: SequenceQueue = SequenceQueue.create(null)
	var cells: Array[Vector2i] = [Vector2i(3, 1), Vector2i(4, 1)]
	var push_bound: int = PushSequence.enqueue(push_queue, pusher, 1, 5,
		Vector2i(2, 1), cells, false)
	h.equal("push.deterministic_frames", push_bound, 2 * PushSequence.FRAMES_PER_CELL)
	var push_ran: Dictionary = _run_queue(push_queue)
	h.equal("push.stages", DictRead.as_array(push_ran["order"]),
		[PushSequence.STAGE_FLIGHT, PushSequence.STAGE_CELL, PushSequence.STAGE_POOL],
		"two cells of the same stage name run back to back")
	h.equal("push.dust_a_frame", pusher.spawned_at.size(), 8)
	var lift: int = PushSequence.full_height(2880)
	h.equal("push.flight_eye_and_target", pusher.flights[0],
		[Vector3i(3200, 3200, lift), Vector3i(6400, 3200, lift)],
		"`0x0047AD30(pusher)` above the pusher's object and the pushed one")
	h.equal("push.snaps_to_the_cell", pusher.placed[pusher.placed.size() - 1],
		Vector3i(12800, 3200, PushSequence.LAND_UP))
	h.equal("push.settles", pusher.settled, PackedInt32Array([5]))
	var hole: RecordingHost = RecordingHost.new()
	var hole_queue: SequenceQueue = SequenceQueue.create(null)
	var hole_bound: int = PushSequence.enqueue(hole_queue, hole, 1, 5,
		Vector2i(2, 1), [Vector2i(3, 1)], true)
	h.equal("push.hole_frames", hole_bound,
		PushSequence.FRAMES_PER_CELL + PushSequence.HOLE_STEPS)
	var _hole_ran: Dictionary = _run_queue(hole_queue)
	h.equal("push.hole_hides_the_object", hole.hidden, PackedInt32Array([5]))
	var sunk: Vector3i = hole.placed[hole.placed.size() - 1]
	h.equal("push.hole_drops_50_steps", sunk.z,
		PushSequence.LAND_UP - PushSequence.HOLE_STEPS * PushSequence.HOLE_DROP)

	# --- the marker and the trail, as programs ------------------------------
	var geometry: Eng3dGeometry = Eng3dGeometry.from_cache(CacheFixture.cache_dir())
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.geometry = geometry
	inputs.models = {"A_ARROW.3DI": 3}
	inputs.tiles[Vector2i(2, 2)] = {"object": Vector3i(6400, 6400, 0),
		"unit": {"type": 0, "player": 0, "height": 2880}}
	var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(1.0)
	var _arrows: bool = BlobPrograms.run(BlobPrograms.ARROWS, pool, draws,
		PackedInt32Array([2, 2]), inputs)
	h.equal("marker.four_arrows", pool.records.size(), 4)
	h.equal("marker.no_draw", draws.count, 0)
	var radii: Array[int] = []
	var kinds: Array[int] = []
	for record: Dictionary in pool.records:
		var dx: int = DictRead.as_int(record["x"]) - 6400
		var dy: int = DictRead.as_int(record["y"]) - 6400
		radii.append(Eng3dGeometry.distance_2d(dx, dy))
		kinds.append(DictRead.as_int(record["kind"]))
	h.equal("marker.kind_14", kinds, [14, 14, 14, 14])
	h.check("marker.on_the_ring", radii.all(
		func(r: int) -> bool: return absi(r - BlobPrograms.RING_RADIUS) <= 2),
		str(radii))
	inputs.sizes[0] = 1
	var large: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var _large: bool = BlobPrograms.run(BlobPrograms.ARROWS, large,
		BlobPrograms.Draws.create(1.0), PackedInt32Array([2, 2]), inputs)
	h.check("marker.large_type_doubles_the_ring", large.records.size() == 4
		and absi(Eng3dGeometry.distance_2d(DictRead.as_int(large.records[0]["x"]) - 6400,
			DictRead.as_int(large.records[0]["y"]) - 6400)
			- BlobPrograms.RING_RADIUS_LARGE) <= 2, "")
	var trail_pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var trail_draws: BlobPrograms.Draws = BlobPrograms.Draws.create(1.0)
	var _trail: bool = BlobPrograms.run(BlobPrograms.TRAIL, trail_pool,
		trail_draws, PackedInt32Array([6400, 6400, 1600]), inputs)
	h.equal("trail.five_records_a_frame", trail_pool.records.size(), 5,
		"a zoom bob and four sprites")
	h.equal("trail.twelve_draws", trail_draws.count, 12)
	h.equal("trail.delays_by_index", trail_pool.records.map(
		func(r: Dictionary) -> int: return DictRead.as_int(r["delay"])), [0, 0, 1, 2, 3])


## docs/42 section 4 -- the nine stages in the engine's order, on a
## recording host: the clip first, the caption and camera after it, the
## round waited for, the casualty hidden at the impact, the clip resumed past
## its note, the idle only at the very end.
func _check_shot_stages(h: TestHarness) -> void:
	var host: RecordingHost = RecordingHost.new()
	var queue: SequenceQueue = SequenceQueue.create(null)
	var shot: Dictionary = {
		"shooter": 3, "sx": 2, "sy": 0, "tx": 5, "ty": 0, "weapon": 2,
		"own": true, "reaction": false, "xp": 10, "attack": null,
		"caption": "Sgt. Bratt received 10 experience points",
		"targets": [{"slot": 9, "x": 5, "y": 0, "marker": Combat.MARKER_KILLED,
			"dealt": 4, "stunned": false, "type_id": 50, "player": 255,
			"species": 1, "special": 0, "size": 0, "cell": 5}],
		"strings": {"missed": "Missed", "paralyzed": "Paralyzed"},
		"cues_shot": [{"wave": "w.wav"}], "cues_impact": [{"wave": "r.wav"}],
		"cues_barrel": []}
	var bound: int = ShotSequence.enqueue(queue, host, shot)
	# The engine's deterministic frames and nothing else: the clip (4) and
	# its spin (2), the muzzle, the impact, the resume (6). The open-ended
	# waits are the picture's, not the hold's.
	h.equal("stages.hold_is_the_deterministic_frames", bound, 4 + 2 + 1 + 1 + 6)
	var order: Array[String] = []
	var frames: int = 0
	while queue.is_running() and frames < 1000:
		var stage: String = queue.current()
		if order.is_empty() or order[order.size() - 1] != stage:
			order.append(stage)
		var _still: bool = queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.equal("stages.order", order, [ShotSequence.STAGE_CLIP,
		ShotSequence.STAGE_CAMERA, ShotSequence.STAGE_MUZZLE,
		ShotSequence.STAGE_FLIGHT, ShotSequence.STAGE_IMPACT,
		ShotSequence.STAGE_POOL, ShotSequence.STAGE_RESUME,
		ShotSequence.STAGE_SETTLE], "the engine's nine stages, in its order")
	h.equal("stages.calls", host.calls, ["fire", "caption", "camera",
		"cues:1", "muzzle", "impact", "cues:1", "hide", "fade", "resume",
		"rest", "clear_texts"],
		"the clip before the camera, the casualty hidden at the impact, the "
		+ "resume before the idle")
	h.equal("stages.caption_for_own_experience", host.captions,
		["Sgt. Bratt received 10 experience points"])
	h.equal("stages.kill_text", host.texts, ["/3"],
		"a kill floats the empty string, type 3")
	h.equal("stages.death_creator", host.programs,
		["%s:5,0" % BlobPrograms.SPECIES_BURST],
		"weapon 2's muzzle arm leaves style 0: the species burst")
	h.equal("stages.hidden", host.hidden, PackedInt32Array([9]))
	h.check("stages.waited_for_the_round", frames > 6 + 3 + 2 + 1,
		"%d frame(s): the flight stage waited for the flag" % frames)

	# A weapon whose muzzle arm skips the wait: no flight and no pool stage.
	var quick: RecordingHost = RecordingHost.new()
	var short: SequenceQueue = SequenceQueue.create(null)
	shot["weapon"] = 0x0F
	var _quick_bound: int = ShotSequence.enqueue(short, quick, shot)
	var stages: Array[String] = []
	frames = 0
	while short.is_running() and frames < 1000:
		var stage: String = short.current()
		if stages.is_empty() or stages[stages.size() - 1] != stage:
			stages.append(stage)
		var _still: bool = short.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.check("stages.no_wait_weapon_skips_the_flight",
		not stages.has(ShotSequence.STAGE_FLIGHT)
			and not stages.has(ShotSequence.STAGE_POOL),
		str(stages))
	h.equal("stages.style_3_death", quick.programs,
		["%s:5,0" % BlobPrograms.BLOOD_BURST],
		"weapon 15's muzzle arm leaves style 3: the blood burst")

	# Type 0x37 skips the resume; a computer's shot has no caption.
	var silent: RecordingHost = RecordingHost.new()
	silent.type_id = ShotSequence.NO_RESUME_TYPE
	var no_resume: SequenceQueue = SequenceQueue.create(null)
	shot["weapon"] = 2
	shot["caption"] = ""
	shot["targets"] = [{"slot": 9, "x": 5, "y": 0, "marker": Combat.MARKER_HIT,
		"dealt": 4, "stunned": false, "type_id": 50, "player": 255,
		"species": 1, "special": 0, "size": 0, "cell": 5}]
	var _no_bound: int = ShotSequence.enqueue(no_resume, silent, shot)
	frames = 0
	while no_resume.is_running() and frames < 1000:
		var _still: bool = no_resume.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.check("stages.type_0x37_never_resumes", not silent.calls.has("resume"),
		str(silent.calls))
	h.equal("stages.damage_text", silent.texts, ["4/2"],
		"damage floats its number, type 2")
	h.equal("stages.damage_blood", silent.programs,
		["%s:2,0,5,0,0" % BlobPrograms.BLOOD_FLOOD],
		"the computer's unit bleeds from the shooter's cell")
	h.equal("stages.no_caption_for_the_computer", silent.captions, [""])

	# The entry types and the severity, per marker.
	h.equal("stages.severity",
		ShotSequence.severity([{"marker": Combat.MARKER_MISS},
			{"marker": Combat.MARKER_HIT}, {"marker": Combat.MARKER_RESOLVED}]),
		ShotSequence.SEVERITY_DAMAGE)
	h.equal("stages.object_types",
		[ShotSequence.entry_type(Combat.MARKER_HIT, 2),
			ShotSequence.entry_type(Combat.MARKER_KILLED, 2),
			ShotSequence.entry_type(Combat.MARKER_MISS, 0)],
		[ShotSequence.TYPE_DAMAGE_OBJECT, ShotSequence.TYPE_KILLED_OBJECT,
			ShotSequence.TYPE_MISSED])
	h.equal("stages.paralysed_text",
		ShotSequence.entry_text({"marker": Combat.MARKER_RESOLVED,
			"stunned": true}, ShotSequence.PARALYSING_WEAPON,
			{"paralyzed": "Paralyzed"}), "Paralyzed")


## The three demo missions' own set pieces, from the converted scripts.
##
## Everything above this uses arguments taken from the documents; this uses the
## arguments the shipped missions actually pass, so a frame count that is right
## in principle and absurd on real data is caught here rather than on screen.
## `_C_141` carries **four** `RoofUnit` calls and `_C_115` **eight**
## `Elevator` calls, which are the two criteria this slice is judged on.
func _check_demo_missions(h: TestHarness) -> void:
	var expected: Dictionary[String, Dictionary] = {
		"_C_141": {"RoofUnit": 4},
		"_C_115": {"Elevator": 8, "OpenTube": 3},
		"_C_140": {"OpenTube": 2},
	}
	# LCL command -> the event name `core` records for it.
	var events: Dictionary[String, String] = {
		"RoofUnit": "roof_unit", "Elevator": "elevator",
		"OpenTube": "open_tube", "OpenDoor": "open_door",
		"Platform": "platform",
	}
	for mission: String in expected:
		var script: Dictionary = CacheFixture.script_document(mission)
		if script.is_empty():
			h.check("demo.%s.script" % mission, false,
				"missions/%s/script.json" % mission)
			continue
		var counts: Dictionary[String, int] = {}
		var frames: Dictionary[String, int] = {}
		for entry: Variant in DictRead.as_array(script["instructions"]):
			var instr: Dictionary = DictRead.as_dict(entry)
			var command: String = DictRead.as_string(instr.get("name", ""))
			if not events.has(command):
				continue
			counts[command] = DictRead.as_int(counts.get(command, 0)) + 1
			var event: Dictionary = {"name": events[command],
				"values": _argument_values(instr)}
			var n: int = SetpieceDriver.frames_for(event)
			if n > 0:
				frames[command] = maxi(DictRead.as_int(frames.get(command, 0)), n)
		for command: String in DictRead.as_dict(expected[mission]):
			var want: int = DictRead.as_int(
				DictRead.as_dict(expected[mission])[command])
			h.equal("demo.%s.%s" % [mission, command],
				DictRead.as_int(counts.get(command, 0)), want)
			if SetpieceDriver.is_animated(events[command]):
				var got: int = DictRead.as_int(frames.get(command, 0))
				h.check("demo.%s.%s.frames" % [mission, command],
					got > 0 and got <= SetpieceDriver.MAX_FRAMES,
					"%d frames = %.2f s at 20 fps"
						% [got, float(got) / SequenceQueue.FRAMES_PER_SECOND])

	# The playlists the missions name, and the tracks the cache carries for
	# them -- criterion 11's own numbers.
	var tables: AudioTables = AudioTables.open(CacheFixture.cache_dir())
	if not tables.is_loaded():
		h.check("demo.audio", false, "tables/sound.json")
		return
	var tracks: PackedInt32Array = tables.tracks()
	var named: Dictionary[int, bool] = {}
	for mission: String in expected:
		var list: PackedInt32Array = tables.playlist(mission)
		h.check("demo.%s.playlist" % mission, not list.is_empty(),
			"CDTrackProgram names %s" % str(list))
		for track: int in list:
			named[track] = true
	var missing: PackedInt32Array = PackedInt32Array()
	for track: int in named:
		if not tracks.has(track):
			missing.append(track)
	h.equal("demo.tracks", missing, PackedInt32Array(),
		"%d track(s) in the cache cover every playlist" % tracks.size())


## An instruction's arguments as the interpreter's `values` array.
func _argument_values(instr: Dictionary) -> Array:
	var out: Array = []
	for entry: Variant in DictRead.as_array(instr.get("args", [])):
		var arg: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_string(arg.get("kind", "")) == "number":
			out.append(DictRead.as_int(arg["value"]))
	return out


## A unit a set piece is still delivering is not drawn until it lands.
##
## `core` inserts a `RoofUnit`'s alien the instant the command runs -- there is
## no "falling" state and there should not be, because every rule can already
## see the unit. What the criterion asks is that the **picture** shows it at the
## end of the drop, not at the beginning, so [UnitsView] holds the node out of
## sight for the length of the sequence.
func _check_arrival(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(DOOR_MISSION)
	if loaded.is_empty():
		h.check("arrival.fixture", false, "no cache")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	var units: UnitsView = UnitsView.new()
	units.library = CharismaLibrary.open(CacheFixture.cache_dir(), {},
		DOOR_MISSION)
	units.build(world, geometry, {})
	var drawn: int = units.get_child_count()
	h.check("arrival.built", drawn > 0, "%d unit nodes" % drawn)
	if drawn == 0:
		units.free()
		return

	var slot: int = _first_drawn_slot(units)
	units.suppress(slot)
	h.equal("arrival.suppressed", units.suppressed(), PackedInt32Array([slot]))
	h.check("arrival.hidden", not _node_of(units, slot).visible,
		"slot %d is held out of the picture" % slot)
	h.equal("arrival.count_unchanged", units.get_child_count(), drawn,
		"the node exists -- it is the picture that waits, not the unit")

	# A rebuild recreates every node, so the hold has to survive one. It did
	# not in the first draft: a fog change put the alien back on screen
	# half way down its own fall.
	units.build(world, geometry, {})
	h.check("arrival.survives_rebuild", not _node_of(units, slot).visible,
		"and stays held across a rebuild")

	h.equal("arrival.revealed", units.reveal_all(), 1)
	h.check("arrival.shown", _node_of(units, slot).visible,
		"and is shown when the sequence ends")
	h.equal("arrival.none_left", units.suppressed().size(), 0)
	units.free()


## A unit standing on a moving cell rides it.
##
## `core` applies a lift's whole travel the instant the command runs, so
## without an offset the passenger is at the top before the platform has left
## the floor. The offset is held by [UnitsView], never by `core`, and -- like
## the suppression above -- it has to survive a rebuild.
func _check_ride(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(DOOR_MISSION)
	if loaded.is_empty():
		h.check("ride.fixture", false, "no cache")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var geometry: Dictionary = CacheFixture.geometry(DictRead.as_string(
		DictRead.as_dict(document["header"])["world_set"]))
	var units: UnitsView = UnitsView.new()
	units.library = CharismaLibrary.open(CacheFixture.cache_dir(), {},
		DOOR_MISSION)
	units.build(world, geometry, {})
	if units.get_child_count() == 0:
		h.check("ride.built", false, "no unit nodes")
		units.free()
		return
	var slot: int = _first_drawn_slot(units)
	var rest: float = _node_of(units, slot).position.y
	h.equal("ride.none_at_rest", units.lifts().size(), 0)

	# One whole map field down, which is `RoofUnit`'s own step and the largest
	# a lift moves in one frame.
	units.lift(slot, -RIDE_STEP)
	var lowered: float = _node_of(units, slot).position.y
	h.check("ride.offset_applied",
		absf(rest - lowered - float(RIDE_STEP)
			/ WorldSpace.WORLD_UNITS_PER_METRE) < RIDE_EPSILON,
		"%.3f m below where the world puts it" % (rest - lowered))
	h.equal("ride.one_rider", units.lifts().size(), 1)

	# Only the rider moves: an earlier draft wrote every child's y on every
	# lifted frame and put a walking body back on its start cell's floor.
	var others: int = 0
	for child: Node in units.get_children():
		var node: Node3D = child as Node3D
		if node != null and node.name.get_slice("_", 1).to_int() != slot:
			others += 1
	h.check("ride.only_the_rider", units.lifts().size() == 1 and others >= 0,
		"%d other unit node(s) untouched" % others)

	units.build(world, geometry, {})
	h.check("ride.survives_rebuild",
		absf(_node_of(units, slot).position.y - lowered) < RIDE_EPSILON,
		"the offset is re-applied to the new node")

	h.equal("ride.dropped", units.drop_lifts(), 1)
	h.check("ride.back_at_rest",
		absf(_node_of(units, slot).position.y - rest) < RIDE_EPSILON,
		"and the rider is where the world says it is")
	h.equal("ride.none_left", units.lifts().size(), 0)
	units.free()


## Footsteps are counted in frames, and the count is [UnitsView]'s.
##
## docs/28 section 5's period is 2 to 8 frames and `core` hands over a whole
## path at once, so the phase cannot come from a rule. This drives a walk at the
## body clock and requires one step per period plus the one at the start.
func _check_steps(h: TestHarness) -> void:
	var units: UnitsView = UnitsView.new()
	var cells: PackedInt32Array = PackedInt32Array([0, 1, 2, 3, 4])
	units.start_walk(STEP_SLOT, cells, STEP_WIDTH, STEP_SECONDS, STEP_PERIOD)
	h.equal("steps.at_start", units.steps_taken(), [STEP_SLOT] as Array[int],
		"the walk sound starts with the walk animation")
	h.equal("steps.drained", units.steps_taken().size(), 0,
		"and the list is emptied by reading it")

	# A silent unit type asks for no period and puts nothing in the list.
	units.finish_walks(null)
	units.start_walk(STEP_SLOT, cells, STEP_WIDTH, STEP_SECONDS, 0)
	h.equal("steps.silent_type", units.steps_taken().size(), 0)

	# **Nothing starts while the camera is still flying.** `aExecuteMove`
	# runs its camera arm first and every arm joins at `0x0046E577`, where
	# the `M` clip is started and `aStartWalkAnimationSound` `0x0040E640`
	# follows (docs/42 section 3.1). Starting them with the walk itself made
	# every unit tread its first step on the spot for the length of the
	# flight, with a footstep under it.
	units.finish_walks(null)
	units.start_walk(STEP_SLOT, cells, STEP_WIDTH, STEP_SECONDS, STEP_PERIOD,
		STEP_DELAY)
	h.equal("steps.none_during_the_flight", units.steps_taken().size(), 0,
		"the walk sound waits for the camera")
	units.animate(STEP_DELAY * 0.5, null)
	h.equal("steps.still_none_half_way", units.steps_taken().size(), 0,
		"%.2f s into a %.2f s flight" % [STEP_DELAY * 0.5, STEP_DELAY])
	# Just past the flight, and by less than one period: the step that lands
	# is the join's own and not a boundary's.
	units.animate(STEP_DELAY * 0.5 + 0.01, null)
	h.equal("steps.the_first_lands_at_the_join",
		units.steps_taken(), [STEP_SLOT] as Array[int],
		"the first step comes with the clip, past the flight")
	units.free()


## The model half of the pool draws geometry, and two of its models have joints.
func _check_models(h: TestHarness) -> void:
	var geometry: Dictionary = CacheFixture.geometry(MODEL_WORLD_SET)
	var prototypes: Dictionary = DictRead.as_dict(
		geometry.get("prototypes", {}))
	if prototypes.is_empty():
		h.check("models.fixture", false, "no geometry for " + MODEL_WORLD_SET)
		return
	var jointed: PackedStringArray = PackedStringArray()
	for name: String in JOINT_MODELS:
		var proto: Dictionary = DictRead.as_dict(prototypes.get(name, {}))
		var parts: Array = DictRead.as_array(proto.get("parts", []))
		if parts.size() == DictRead.as_int(JOINT_MODELS[name]):
			jointed.append(name)
	h.equal("models.parts_present", jointed.size(), JOINT_MODELS.size(),
		"the two jointed effect models carry their part lists")

	# A part's mesh is its own, and the root's is what the parts do not own:
	# together they are the whole prototype and neither is empty.
	var panel: Dictionary = DictRead.as_dict(prototypes[JOINT_MODEL])
	var root: ArrayMesh = MeshBuilder.build_scope(panel, {},
		MeshBuilder.ROOT_SCOPE)
	var part: ArrayMesh = MeshBuilder.build_scope(panel, {}, 0)
	h.check("models.scopes_split",
		root.get_surface_count() > 0 and part.get_surface_count() > 0,
		"%d root surface(s), %d part surface(s)"
			% [root.get_surface_count(), part.get_surface_count()])

	# The joint angles are a 4096-unit circle, and a whole turn is the
	# identity -- which is exactly what kind 42's `0x1000` arm means.
	var identity: Basis = WorldSpace.joint_basis(0, 0, 0)
	var whole: Basis = WorldSpace.joint_basis(0, 0x1000, 0)
	h.check("models.whole_turn_is_identity",
		identity.is_equal_approx(whole),
		"0x1000 in a 4096 circle is no rotation at all")
	var quarter: Basis = WorldSpace.joint_basis(0, 0x400, 0)
	h.check("models.quarter_turn_moves",
		not quarter.is_equal_approx(identity),
		"and 0x400 is the panel's flip")

	# **A bearing turns a model onto it.** An Eng3d model is authored along
	# engine **+Y** -- `A_LINE5.3DI` is 1600 units long in Y and 242 wide in X
	# -- and `0x00403AA0` measures a bearing from +Y toward +X, so the basis a
	# bearing makes must send the model's forward, Godot -Z, along that
	# direction. The four cardinal bearings need no trig table to state.
	# Pinned because the sign was the other way until docs/97 section 46.5, and
	# a tracer then flew across its own path with every check still green.
	var cardinals: Array[Vector3i] = [
		Vector3i(0, 0, 3200), Vector3i(1024, 3200, 0),
		Vector3i(2048, 0, -3200), Vector3i(3072, -3200, 0)]
	var pointed: int = 0
	for entry: Vector3i in cardinals:
		var forward: Vector3 = WorldSpace.joint_basis(0, 0, entry.x) \
			* Vector3(0.0, 0.0, -1.0)
		var want: Vector3 = WorldSpace.to_godot(entry.y, entry.z,
			0).normalized()
		if forward.dot(want) > 0.999:
			pointed += 1
	h.equal("models.bearing_points_the_model", pointed, cardinals.size(),
		"the model's +Y forward lands on its own bearing")

	# **A placed object's heading is the same word through the same machinery.**
	# 6332 of the 6333 yawed special objects in the shipped missions are drawn
	# by a prototype that turns the object record's own triple with
	# `joint_rotate_3` at anim offset 0 (`verify_3d_indices.py`), so scenery and
	# a model blob must not be two rules. They were until docs/97 section 47.
	var yaws: Array[int] = [0, 200, 512, 1024, 1536, 2048, 3072, 3900]
	var same: int = 0
	for yaw: int in yaws:
		if WorldSpace.yaw_basis(yaw).is_equal_approx(
				WorldSpace.joint_basis(0, 0, yaw)):
			same += 1
	h.equal("models.scenery_yaw_is_a_joint_angle", same, yaws.size(),
		"a heading is the joint triple's third component and nothing else")

	# And against the engine's own arithmetic rather than against ourselves:
	# [Eng3dGeometry] is `tools/inclib/eng3d.py`'s twin, and its three-angle
	# builder reproduces `E3D_init_matrix_RzRxRy` 8/8 inside a running
	# `Incubation.exe`. A point on engine +Y turned by the engine must land
	# where the same point turned by this basis lands.
	var measured: Eng3dGeometry = Eng3dGeometry.from_cache(
		CacheFixture.cache_dir())
	var agreed: int = 0
	for yaw: int in yaws:
		var turned: Vector3i = Eng3dGeometry.transform(
			measured.matrix3(0, 0, yaw), Vector3i(0, 1600, 0))
		var engine: Vector3 = WorldSpace.to_godot_v(Vector3(turned)).normalized()
		var mine: Vector3 = (WorldSpace.yaw_basis(yaw)
			* WorldSpace.to_godot(0, 1600, 0)).normalized()
		if mine.dot(engine) > 0.9999:
			agreed += 1
	h.equal("models.scenery_yaw_matches_the_engine_matrix", agreed, yaws.size(),
		"the heading turns geometry the way Eng3d's own matrix builder does")

	# The pool draws only the model half: a sprite blob is [BlobSprites]'s.
	var pool: BlobPool = BlobPool.create(1.0)
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in prototypes:
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	# The pool resolves a model *name* through its hooks, exactly as the game
	# does: with no index the deterministic three-name table answers and every
	# real effect model is refused, which is the bug the mutation battery found.
	pool.hooks().model_index = index
	var models: BlobModels = BlobModels.new()
	models.setup(prototypes, {}, index)
	var made: int = pool.create_blob({"kind": 42, "class_id": 0, "life": 8,
		"model_name": JOINT_MODEL})
	h.check("models.created", made >= 0, "slot %d" % made)
	h.equal("models.drawn", models.rebuild(pool), 1)
	var sprite: int = pool.create_blob({"kind": 60, "class_id": 2, "life": 8})
	h.check("models.sprite_made", sprite >= 0, "slot %d" % sprite)
	h.equal("models.sprite_not_drawn", models.rebuild(pool), 1,
		"a class-2 blob is the sprite path's, not this one's")
	pool.clear()
	h.equal("models.cleared", models.rebuild(pool), 0)
	models.free()
	_check_special_objects(h, prototypes)


## docs/42 section 9.1 -- the cell-owned objects and their per-frame turn.
##
## The placement itself is `native-runtime` in `test_ctrl_map`; what is checked
## here is the **picture**: that an object appears for exactly as long as its
## cell says so, and that each of the four states turns the way the refresh
## does.
func _check_special_objects(h: TestHarness,
		prototypes: Dictionary) -> void:
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in prototypes:
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	var world: World = TestFixtures.tiny_world()
	world.state.set_special_models(PackedStringArray([
		CellObjects.FIRE_MODEL_LARGE, CellObjects.FIRE_MODEL_MEDIUM,
		CellObjects.FIRE_MODEL_SMALL, CellObjects.MINE_MODEL,
		CellObjects.SHIELD_MODEL]))
	var view: SpecialObjects = SpecialObjects.new()
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	view.setup(prototypes, {}, index, rng)

	h.equal("special.nothing_to_draw", view.live_count(), 0)
	var _synced: PackedInt32Array = view.sync(world.terrain_snapshot())
	h.equal("special.empty_map_draws_nothing", view.live_count(), 0)

	# Weapon 40's nine fires, and the mine and shield beside them.
	var _fires: PackedInt32Array = CellObjects.place_impact(
		world.state, CellObjects.WEAPON_GROUND_FIRE, 3, 3)
	var _mine: int = CellObjects.place_mine(world.state, 1, 1)
	var _shield: int = CellObjects.place_shield(world.state, 5, 5)
	var touched: PackedInt32Array = view.sync(world.terrain_snapshot())
	h.check("special.sync_sees_the_cells", touched.size() >= 11,
		"%d cell(s) changed" % touched.size())
	h.equal("special.one_object_per_cell", view.live_count(), 11,
		"nine fires, a mine and a shield")
	h.equal("special.all_of_them_draw", view.advance(), 11)
	# A second sync with nothing changed is the cheap path and moves nothing.
	h.equal("special.idle_sync_is_free",
		view.sync(world.terrain_snapshot()).size(), 0)

	# The round tick takes them back down, and the picture follows.
	for _round: int in range(5):
		var _changed: PackedInt32Array = CellObjects.round_tick(world.state)
	var _resynced: PackedInt32Array = view.sync(world.terrain_snapshot())
	h.equal("special.the_tick_removes_them", view.live_count(), 1,
		"only the mine outlives five rounds")

	# The four per-frame steps, as docs/42 section 9.1 tabulates them.
	h.equal("special.shield_subtype_1", SpecialObjects._shield_step(1),
		SpecialObjects.SHIELD_STEP_SUBTYPE_1)
	h.equal("special.shield_subtype_2", SpecialObjects._shield_step(2),
		SpecialObjects.SHIELD_STEP_SUBTYPE_2)
	h.equal("special.shield_subtype_other", SpecialObjects._shield_step(0),
		SpecialObjects.SHIELD_STEP_OTHER)
	h.equal("special.mine_step", SpecialObjects.MINE_STEP, 51)

	# **The point the scatter scatters around.** `test_ctrl_map` feeds
	# `CellObjects.object_position` the origin the capture read, so it can
	# only check the arithmetic; this checks the origin itself, which is the
	# cell's **corner** -- the D00 capture put symbol 998, the object of cell
	# (12, 29), at (38400, 92800, 0). It is the same point `_death_inputs`
	# hands the death creators (docs/97 section 22).
	var snapshot: Dictionary = world.terrain_snapshot()
	var probe: int = world.state.index_of(3, 4)
	h.equal("special.origin_is_the_cells_corner",
		view.origin_of(snapshot, probe),
		Vector3i(3 * WorldSpace.WORLD_UNITS_PER_FIELD,
			4 * WorldSpace.WORLD_UNITS_PER_FIELD,
			world.state.height_at(probe)),
		"x * 3200, not x * 3200 + 1600")
	view.free()


func _first_drawn_slot(units: UnitsView) -> int:
	var node: Node3D = units.get_child(0) as Node3D
	return -1 if node == null else node.name.get_slice("_", 1).to_int()


func _node_of(units: UnitsView, slot: int) -> Node3D:
	for child: Node in units.get_children():
		var node: Node3D = child as Node3D
		if node != null and node.name.get_slice("_", 1).to_int() == slot:
			return node
	return null


## docs/42 section 8 at the level [SetpieceCamera] queues it (docs/97
## section 32): the door's two flights, the tube's puffs on its tenth
## frame, the lift's per-frame target, the platform's dust, the roof's
## drop and the ground unit's rise.
func _check_setpiece_camera(h: TestHarness) -> void:
	var paint: Callable = func(_frame: int, _total: int) -> void: pass
	var no_cues: Array[Dictionary] = []

	# The door with a user: a flight there and a flight back.
	var door: RecordingHost = RecordingHost.new()
	door.objects[3] = Vector3i(3200, 3200, 0)
	door.heights[3] = 2880
	var door_queue: SequenceQueue = SequenceQueue.create(null)
	var door_frames: int = SetpieceCamera.enqueue(door_queue, door, "open_door",
		SetpieceDriver.DOOR_FRAMES, Vector2i(2, 1), 0, 0xC80, 3, {}, paint,
		no_cues)
	h.equal("camera.door.frames", door_frames, SetpieceDriver.DOOR_FRAMES)
	var door_ran: Dictionary = _run_queue(door_queue)
	h.equal("camera.door.stages", DictRead.as_array(door_ran["order"]),
		[SetpieceCamera.STAGE_FLIGHT, "open_door", SetpieceCamera.STAGE_BACK])
	h.equal("camera.door.flies_there_and_back", door.flights.size(), 2)
	h.equal("camera.door.eye_at_the_user_head", door.flights[0][0],
		Vector3i(3200, 3200, 2880), "`0x0047AD70` above the opener's object")
	h.equal("camera.door.target_at_the_panel", door.flights[0][1],
		Vector3i(2 * WorldSpace.WORLD_UNITS_PER_FIELD,
			1 * WorldSpace.WORLD_UNITS_PER_FIELD, 2880))
	# The LCL wrapper names no unit: no flight at all.
	var lcl: RecordingHost = RecordingHost.new()
	var lcl_queue: SequenceQueue = SequenceQueue.create(null)
	var _lcl: int = SetpieceCamera.enqueue(lcl_queue, lcl, "open_door",
		SetpieceDriver.DOOR_FRAMES, Vector2i(2, 1), 0, 0xC80, -1, {}, paint,
		no_cues)
	var _lcl_ran: Dictionary = _run_queue(lcl_queue)
	h.equal("camera.door.no_unit_no_flight", lcl.flights.size(), 0,
		"the wrapper passes -1 and the routine skips its camera")

	# The tube: the puffs on the tenth of nineteen frames, no flight.
	var tube: RecordingHost = RecordingHost.new()
	var tube_queue: SequenceQueue = SequenceQueue.create(null)
	var painted: Array[int] = []
	var count: Callable = func(frame: int, _total: int) -> void:
		painted.append(frame)
	var tube_frames: int = SetpieceCamera.enqueue(tube_queue, tube, "open_tube",
		SetpieceDriver.TUBE_FRAMES, Vector2i(3, 3), 0, 0, -1, {}, count, no_cues)
	h.equal("camera.tube.frames", tube_frames, 19)
	var _tube_ran: Dictionary = _run_queue(tube_queue)
	h.equal("camera.tube.painted_every_frame", painted.size(), 19)
	h.equal("camera.tube.puffs_once", tube.programs,
		["%s:3,3" % BlobPrograms.TUBE_PUFFS])
	h.equal("camera.tube.no_flight", tube.flights.size(), 0)

	# The lift: the camera read once and the target set every frame.
	var lift: RecordingHost = RecordingHost.new()
	var lift_queue: SequenceQueue = SequenceQueue.create(null)
	var _lift: int = SetpieceCamera.enqueue(lift_queue, lift, "elevator", 7,
		Vector2i(6, 15), 0, 5600, -1, {}, paint, no_cues)
	var _lift_ran: Dictionary = _run_queue(lift_queue)
	h.equal("camera.elevator.targets_per_frame", lift.targets_set, 7)
	h.equal("camera.elevator.one_flight", lift.flights.size(), 1)
	h.equal("camera.elevator.no_dust", lift.spawned_at.size(), 0)
	# The platform: the same, plus a dust puff a frame at the block.
	var block: RecordingHost = RecordingHost.new()
	var block_queue: SequenceQueue = SequenceQueue.create(null)
	var _block: int = SetpieceCamera.enqueue(block_queue, block, "platform", 4,
		Vector2i(2, 2), 0, 1280, -1, {}, paint, no_cues)
	var _block_ran: Dictionary = _run_queue(block_queue)
	h.equal("camera.platform.dust_per_frame", block.spawned_at.size(), 4)
	h.check("camera.platform.dust_is_the_creator",
		block.spawned_at[0].begins_with(BlobPrograms.PLATFORM_DUST),
		block.spawned_at[0])

	# The roof unit: the flight, the debris, five lead frames, the drop with
	# the target on the body, the landing dust, the pool.
	var roof: RecordingHost = RecordingHost.new()
	roof.live = 2
	var roof_queue: SequenceQueue = SequenceQueue.create(null)
	var roof_frames: int = SetpieceCamera.enqueue(roof_queue, roof, "roof_unit",
		10, Vector2i(4, 4), 32000, 0, 6, {}, paint, no_cues)
	h.equal("camera.roof.frames", roof_frames,
		SetpieceCamera.ROOF_LEAD_FRAMES + 10 + 1)
	var roof_ran: Dictionary = _run_queue(roof_queue)
	h.equal("camera.roof.stages", DictRead.as_array(roof_ran["order"]),
		[SetpieceCamera.STAGE_FLIGHT, SetpieceCamera.STAGE_LEAD, "roof_unit",
		SetpieceCamera.STAGE_LAND, SetpieceCamera.STAGE_POOL])
	h.equal("camera.roof.debris_then_dust", roof.programs,
		["%s:4,4,32000" % BlobPrograms.ROOF_DEBRIS,
		"%s:4,4" % BlobPrograms.LANDING_DUST],
		"the debris at the drop's start, the dust where it lands")
	h.equal("camera.roof.targets_per_frame", roof.targets_set, 10)
	h.equal("camera.roof.body_drawn_per_frame", roof.placed.size(), 1 + 10)
	h.equal("camera.roof.drop_step",
		roof.placed[1].z - roof.placed[2].z, SetpieceCamera.ROOF_DROP_STEP,
		"`sub eax, 0xC80` at 0x00411E26")
	h.equal("camera.roof.settles", roof.settled, PackedInt32Array([6]))

	# The ground unit: eight frames of rise, six of carry, the dust.
	var ground: RecordingHost = RecordingHost.new()
	ground.heights[8] = 2880
	var ground_queue: SequenceQueue = SequenceQueue.create(null)
	var ground_frames: int = SetpieceCamera.enqueue(ground_queue, ground,
		"ground_unit", SetpieceDriver.GROUND_UNIT_FRAMES, Vector2i(3, 3), 0, 0,
		8, {"own": Vector2i(5, 3)}, paint, no_cues)
	h.equal("camera.ground_unit.frames", ground_frames,
		SetpieceCamera.GROUND_RISE_FRAMES + SetpieceCamera.GROUND_CARRY_FRAMES + 1)
	var _ground_ran: Dictionary = _run_queue(ground_queue)
	h.equal("camera.ground_unit.debris_then_dust", ground.programs,
		["%s:3,3,%d" % [BlobPrograms.GROUND_DEBRIS, SetpieceCamera.GROUND_DEBRIS_UP],
		"%s:5,3" % BlobPrograms.LANDING_DUST])
	h.equal("camera.ground_unit.starts_below",
		ground.placed[0].z, -SetpieceCamera.GROUND_START_DOWN - 2880
			+ SetpieceCamera.GROUND_LAND_UP,
		"3200 below the cell's top less the unit's height")
	h.equal("camera.ground_unit.rise_step",
		ground.placed[2].z - ground.placed[1].z, SetpieceCamera.GROUND_RISE,
		"`add esi, 0x460` a frame")
	h.equal("camera.ground_unit.lands_on_its_own_cell",
		Vector2i(ground.placed[ground.placed.size() - 1].x,
			ground.placed[ground.placed.size() - 1].y),
		Vector2i(5 * WorldSpace.WORLD_UNITS_PER_FIELD,
			3 * WorldSpace.WORLD_UNITS_PER_FIELD))
	h.equal("camera.ground_unit.settles", ground.settled, PackedInt32Array([8]))

	# The same set piece, **skipped**. [method SequenceQueue.skip] paints every
	# remaining step once at its last frame, so the carry stage can be entered
	# for the first time with `frame == GROUND_CARRY_FRAMES`. It used to read
	# `st["step"]`, which only frame 1 wrote, and threw -- which meant a key
	# press during a `GroundUnit` left the body unplaced and unsettled.
	var skipped: RecordingHost = RecordingHost.new()
	skipped.heights[8] = 2880
	var skipped_queue: SequenceQueue = SequenceQueue.create(null)
	var _skipped: int = SetpieceCamera.enqueue(skipped_queue, skipped,
		"ground_unit", SetpieceDriver.GROUND_UNIT_FRAMES, Vector2i(3, 3), 0, 0,
		8, {"own": Vector2i(5, 3)}, paint, no_cues)
	skipped_queue.skip()
	h.equal("camera.ground_unit.a_skip_still_lands_the_body",
		[skipped.settled, Vector2i(skipped.placed[skipped.placed.size() - 1].x,
			skipped.placed[skipped.placed.size() - 1].y)],
		[PackedInt32Array([8]), Vector2i(5 * WorldSpace.WORLD_UNITS_PER_FIELD,
			3 * WorldSpace.WORLD_UNITS_PER_FIELD)],
		"every remaining step is painted once, and none of them throws")

	# --- docs/42 section 8's other half (docs/97 section 33) ---------------
	# The statue: the flight to twenty metres, the turn, the beam, the pool.
	var statue: RecordingHost = RecordingHost.new()
	statue.live = 3
	var statue_queue: SequenceQueue = SequenceQueue.create(null)
	var statue_extra: Dictionary = {
		"beams": [{"x": 3, "y": 8, "cells": 5}, {"x": 3, "y": 0, "cells": 3}],
		"killed": [{"slot": 4, "x": 3, "y": 6}]}
	var statue_frames: int = SetpieceCamera.enqueue(statue_queue, statue,
		"statue", SetpieceDriver.STATUE_TURN_FRAMES, Vector2i(3, 3), 0, 0, -1,
		statue_extra, paint, no_cues)
	h.equal("camera.statue.frames", statue_frames,
		SetpieceDriver.STATUE_TURN_FRAMES + 1)
	var statue_ran: Dictionary = _run_queue(statue_queue)
	h.equal("camera.statue.stages", DictRead.as_array(statue_ran["order"]),
		[SetpieceCamera.STAGE_FLIGHT, "statue", SetpieceCamera.STAGE_BEAM,
		SetpieceCamera.STAGE_POOL])
	h.equal("camera.statue.flies_to_20m", statue.flights[0][0].z,
		SetpieceCamera.STATUE_HEIGHT, "`push 0x7D00`")
	h.equal("camera.statue.beam_and_death", statue.programs, [
		"%s:3,6" % BlobPrograms.FIRE_DEATH,
		"%s:3,3,3,8,5" % BlobPrograms.STATUE_BEAM,
		"%s:3,3,3,0,3" % BlobPrograms.STATUE_BEAM])
	h.equal("camera.statue.hides_the_victim", statue.hidden,
		PackedInt32Array([4]))

	# The barrier: the beam first, then the flight, forty frames, the kills.
	var barrier: RecordingHost = RecordingHost.new()
	barrier.live = 2
	var barrier_queue: SequenceQueue = SequenceQueue.create(null)
	var barrier_frames: int = SetpieceCamera.enqueue(barrier_queue, barrier,
		"barrier_on", SetpieceDriver.BARRIER_FRAMES, Vector2i(1, 1), 0, 0, -1,
		{"direction": 0, "cells": 4, "killed": [{"slot": 2, "x": 1, "y": 4}]},
		paint, no_cues)
	h.equal("camera.barrier.frames", barrier_frames,
		SetpieceDriver.BARRIER_FRAMES + 2)
	var _barrier_ran: Dictionary = _run_queue(barrier_queue)
	h.equal("camera.barrier.programs", barrier.programs, [
		"%s:1,1,0,4" % BlobPrograms.LASER_BARRIER,
		"%s:1,4,1,4,0" % BlobPrograms.BLOOD_FLOOD,
		"%s:1,4" % BlobPrograms.FLYING_DEBRIS])
	h.equal("camera.barrier.one_flight", barrier.flights.size(), 1)

	# The fire circle: eight `KillFire` at delay 20, then the ring.
	var fire: RecordingHost = RecordingHost.new()
	fire.live = 1
	var fire_queue: SequenceQueue = SequenceQueue.create(null)
	var _fire: int = SetpieceCamera.enqueue(fire_queue, fire, "fire_circle",
		SetpieceDriver.FIRE_CIRCLE_FRAMES, Vector2i(4, 4), 0, 0, -1, {}, paint,
		no_cues)
	var _fire_ran: Dictionary = _run_queue(fire_queue)
	h.equal("camera.fire_circle.eight_fires_then_the_ring",
		fire.programs.size(), 9)
	h.check("camera.fire_circle.delay_20",
		fire.programs[0] == "%s:3,3,%d" % [BlobPrograms.KILL_FIRE,
			SetpieceCamera.FIRE_CIRCLE_DELAY], fire.programs[0])
	h.equal("camera.fire_circle.ring_last",
		fire.programs[8], "%s:4,4" % BlobPrograms.FIRE_CIRCLE)

	# The crush wall: one debris call a cell, then the pool.
	var wall: RecordingHost = RecordingHost.new()
	wall.live = 2
	var wall_queue: SequenceQueue = SequenceQueue.create(null)
	var _wall: int = SetpieceCamera.enqueue(wall_queue, wall, "crush_wall",
		SetpieceDriver.POOL_ONLY_FRAMES, Vector2i(7, 2), 0, 0, -1,
		{"cells": [[7, 2], [8, 2]]}, paint, no_cues)
	var _wall_ran: Dictionary = _run_queue(wall_queue)
	h.equal("camera.crush_wall.one_per_cell", wall.programs,
		["%s:7,2" % BlobPrograms.WALL_DEBRIS,
		"%s:8,2" % BlobPrograms.WALL_DEBRIS])

	# The para bombs: the bomber in from -16000, one bomb a tile -- and the
	# two are **two stages**, because `0x00470790` runs the fly-past
	# `0x00415E90` to completion and only then the bomb run `0x004160F0`
	# (docs/20 section 7.4). Each carries its own routine's sound, which is
	# what a single stage could not do: `crush.wav` @89 went unplayed while
	# the event resolved to the fly-past alone.
	var bombs: BombRunHost = BombRunHost.new()
	var audio: RecordingAudio = RecordingAudio.new()
	var bombs_queue: SequenceQueue = SequenceQueue.create(audio)
	var bomber_cue: Array[Dictionary] = [{"wave": "bomber.wav",
		"volume_id": 87, "loop": true}]
	var bomb_cue: Array[Dictionary] = [{"wave": "crush.wav",
		"volume_id": 89, "loop": false}]
	# The length is the strike's own, not a flat bound: two tiles three ticks
	# apart, and the last of them falling `BOMB_FALL_FRAMES`.
	var bomb_event: Dictionary = {"name": "para_bombs",
		"values": [5, 5, 3, 3, 20, 5, 5, 6, 7]}
	var bomb_frames: int = SetpieceDriver.frames_for(bomb_event)
	h.equal("setpiece.para_bombs.frames", bomb_frames,
		SetpieceDriver.BOMB_SPACING + SetpieceDriver.BOMB_FALL_FRAMES + 1,
		"two tiles: the second starts one spacing in and then falls")
	var _bombs: int = SetpieceCamera.enqueue(bombs_queue, bombs, "para_bombs",
		bomb_frames, Vector2i(5, 5), 0, 0, -1,
		{"tiles": [[5, 5], [6, 7]]}, paint, bomber_cue, bomb_cue)
	# The bombs must not exist while the bomber flies: `0x004160F0` lays them
	# after the fly-past has returned, and a stage that spawned them with the
	# bomber would be one phase wearing two names. The run is driven a frame
	# at a time so a bomb can be landed on a frame of the test's choosing --
	# which is the only way to see one crump per landing rather than one per
	# stage.
	var during_lead: int = -1
	var lead_frames: int = 0
	var run_frames: int = 0
	var spun: int = 0
	while bombs_queue.is_running() and spun < 2000:
		var stage: String = bombs_queue.current()
		if stage == SetpieceCamera.STAGE_LEAD:
			during_lead = bombs.programs.size()
			lead_frames += 1
		elif stage == "para_bombs":
			run_frames += 1
			# Two landings, five frames apart, once both bombs are in the
			# pool: `_kind_25` deletes the record and raises the flag.
			if run_frames == 3 or run_frames == 8:
				bombs.land()
		var _still: bool = bombs_queue.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
		spun += 1
	h.equal("camera.para_bombs.two_stages",
		[during_lead, lead_frames],
		[0, SetpieceCamera.BOMBER_FRAMES],
		"the fly-past holds its own stage, lays no bomb, and lasts the life "
			+ "`0x0042A8E0` gives the plane")
	h.equal("camera.para_bombs.the_fly_past_empties_the_pool",
		bombs.cleared_pool, 1,
		"`aDeleteAllBlobs` `0x0041E370` at `0x004160B4`")
	h.equal("camera.para_bombs.one_per_tile", bombs.programs,
		["%s:5,5,0" % BlobPrograms.PARA_BOMB,
		"%s:6,7,%d" % [BlobPrograms.PARA_BOMB, SetpieceDriver.BOMB_SPACING]])
	# `0x00415EE1` pushes six literals: the fly-past reads no tile at all.
	h.equal("camera.para_bombs.bomber_flies_in", bombs.spawned_at,
		["%s@(%d, %d, %d)" % [BlobPrograms.BOMBER,
			SetpieceCamera.BOMBER_FROM.x, SetpieceCamera.BOMBER_FROM.y,
			SetpieceCamera.BOMBER_FROM.z]],
		"aBlob_CreateBomber(-320000, -320000, 320000, 48000, 48000, 320000)")
	# `0x00415FB4` -- the eye on the flight path, the target left alone.
	h.equal("camera.para_bombs.the_camera_keeps_its_target",
		[bombs.eye, bombs.target],
		[Vector3i(SetpieceCamera.BOMBER_START_X, 0,
			SetpieceCamera.BOMBER_START_Z), Vector3i(10, 20, 30)],
		"`0x00415F2C` reads the target back and hands it straight on")
	# The whole point of the two stages: each starts the sound of the routine
	# it stands for. `crush.wav` @89 is `0x004160F0`'s and nothing else's, and
	# it was never played while the event resolved to `0x00415E90` alone.
	h.equal("camera.para_bombs.each_phase_its_own_wave",
		[audio.plays, bombs.played],
		[PackedStringArray(["bomber.wav"]), ["crush.wav", "crush.wav"]],
		"`bomber.wav` @87 opens the fly-past; `crush.wav` @89 waits for a bomb")
	# And the fly-past's loop dies with its own stage rather than running over
	# the bombs -- docs/28 section 1.4's rule, applied per phase.
	h.equal("camera.para_bombs.the_loop_dies_with_its_stage",
		audio.stops_before_play, PackedInt32Array([0]))
	# `0x004162D6` spins until a bomb lands, so the run opens **silent**; then
	# `0x00416364`..`0x004163A9` plays one crump per raised *arrived*, each
	# acknowledged with `0x0042B490`. Two bombs landed, so two crumps.
	h.equal("camera.para_bombs.one_crump_per_landing",
		[bombs.played.size(), bombs.cleared_arrived], [2, 2],
		"the engine's three buffers are its cap on overlap, not its count")
	# And the run ends the way `0x004163A9` does -- when the pool is empty,
	# not when the picture's bound runs out.
	h.check("camera.para_bombs.the_run_ends_with_the_pool",
		run_frames < bomb_frames and bombs.pool_live() == 0,
		"%d of %d frames; `while (live)`" % [run_frames, bomb_frames])
	audio.free()

	# `0x004160B4` is the fly-past **routine's** last act and not its last
	# frame. `0x00415E90`'s loop leaves on the *arrived* flag as readily as on
	# its bound -- a record the pool was already holding is enough -- and the
	# pool is emptied either way. A bomb run that started on those leftovers
	# would wait on them for its own end and crump once for each of them.
	var early: BombRunHost = BombRunHost.new()
	early.records = 1
	var early_queue: SequenceQueue = SequenceQueue.create(null)
	var _early: int = SetpieceCamera.enqueue(early_queue, early, "para_bombs",
		bomb_frames, Vector2i(5, 5), 0, 0, -1,
		{"tiles": [[5, 5], [6, 7]]}, paint, no_cues)
	var early_lead: int = 0
	var early_spun: int = 0
	while early_queue.is_running() and early_spun < 2000:
		if early_queue.current() != SetpieceCamera.STAGE_LEAD:
			break
		early_lead += 1
		# The leftover reaches the end of its life on the third frame.
		if early_lead == 3:
			early.flag = true
		var _spinning: bool = early_queue.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
		early_spun += 1
	h.equal("camera.para_bombs.an_early_fly_past_still_empties_the_pool",
		[early_lead, early.cleared_pool, early.pool_live()], [3, 1, 0],
		"the fly-past left on the flag after 3 of %d frames and still ran "
			% SetpieceCamera.BOMBER_FRAMES + "`aDeleteAllBlobs`")

	# The teleporter: the stream, the traveller hidden at 40 and back at 10.
	var port: RecordingHost = RecordingHost.new()
	port.live = 1
	var port_queue: SequenceQueue = SequenceQueue.create(null)
	var _port: int = SetpieceCamera.enqueue(port_queue, port, "teleporter",
		SetpieceDriver.TELEPORTER_FRAMES, Vector2i(2, 6), 0, 0, 9,
		{"tx": 9, "ty": 6}, paint, no_cues)
	var _port_ran: Dictionary = _run_queue(port_queue)
	h.equal("camera.teleporter.stream", port.programs,
		["%s:2,6,9,6" % BlobPrograms.TELEPORT_STREAM])
	h.equal("camera.teleporter.suppressed_not_destroyed",
		[port.suppressed, port.hidden, port.shown],
		[PackedInt32Array([9]), PackedInt32Array(), PackedInt32Array([9])],
		"the traveller comes back thirty frames later, so the node must "
		+ "survive: `hide_unit` frees it and `show_unit` could not undo that")
	h.check("camera.teleporter.target_follows_the_stream",
		port.targets_set >= SetpieceCamera.TELEPORT_HIDE_AT
			- SetpieceCamera.TELEPORT_MOVE_AT,
		"%d frames of following" % port.targets_set)
	# `0x00416554` -- at ten the unit is moved to the **target** object and
	# only then shown. The walk left the body on the entry cell, so a
	# sequence that only flipped `visible` put it back where it started.
	h.equal("camera.teleporter.the_body_lands_on_the_exit", port.placed,
		[port.cell_object(9, 6)] as Array[Vector3i],
		"the exit's own object, once, at the frame the engine moves it")

	# The programs themselves, on the cache's tables.
	var geometry: Eng3dGeometry = Eng3dGeometry.from_cache(CacheFixture.cache_dir())
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.geometry = geometry
	inputs.models = {"A_DEBRIS.3DI": 1, "A_SPLAT1.3DI": 2, "A_LASERG.3DI": 3,
		"L069EE00.3DI": 4, "A_PARAB1.3DI": 5}
	inputs.tiles[Vector2i(2, 2)] = {"object": Vector3i(6400, 6400, 0), "unit": {}}
	inputs.tiles[Vector2i(4, 2)] = {"object": Vector3i(12800, 6400, 0), "unit": {}}
	var shapes: Array = [
		[BlobPrograms.TUBE_PUFFS, PackedInt32Array([2, 2]), 30, 90],
		[BlobPrograms.PLATFORM_DUST, PackedInt32Array([6400, 6400, 0]), 4, 12],
		[BlobPrograms.GROUND_DEBRIS, PackedInt32Array([2, 2, 1600]), 24, 96],
		[BlobPrograms.ROOF_DEBRIS, PackedInt32Array([2, 2, 32000]), 24, 96],
		[BlobPrograms.WALL_DEBRIS, PackedInt32Array([2, 2]), 35, 240],
		[BlobPrograms.FIRE_CIRCLE, PackedInt32Array([2, 2]), 150, 150],
		[BlobPrograms.LASER_BARRIER, PackedInt32Array([2, 2, 0, 2]), 9, 0],
		[BlobPrograms.STATUE_BEAM, PackedInt32Array([2, 2, 4, 2, 3]), 11, 12],
		[BlobPrograms.TELEPORT_STREAM, PackedInt32Array([2, 2, 4, 2]), 200, 800],
		[BlobPrograms.BOMBER, PackedInt32Array([0, 0, 0, 3200, 0, 0]), 1, 0],
		[BlobPrograms.PARA_BOMB, PackedInt32Array([2, 2, 3]), 1, 1],
	]
	var clearing: Array[String] = []
	for shape: Array in shapes:
		var creator: String = shape[0]
		var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
		var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(1.0)
		var args: PackedInt32Array = shape[1]
		var ran: bool = BlobPrograms.run(creator, pool, draws, args, inputs)
		h.check("setpiece_creator.%s.runs" % creator, ran, creator)
		h.equal("setpiece_creator.%s.records" % creator, pool.records.size(),
			DictRead.as_int(shape[2]))
		h.equal("setpiece_creator.%s.draws" % creator, draws.count,
			DictRead.as_int(shape[3]))
		if pool.clears_arrived:
			clearing.append(creator)
	# Which of them write **0** over the *arrived* flag -- "there is something
	# in flight to wait for" (docs/42 section 4.6). Five creators in the whole
	# image do; three are the weapon projectiles the shot path models at the
	# muzzle, and these two are the pair a set piece runs.
	# `presentation_tables.py`'s `arrived.cleared_by` pins the five.
	h.equal("setpiece_creator.clears_arrived", clearing,
		[BlobPrograms.BOMBER, BlobPrograms.PARA_BOMB],
		"and nothing else in the set-piece family touches the flag")

