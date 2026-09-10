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
## requires the panel standing on that cell to **draw** and its two leaves to
## **swing** -- by the ∓1000 `aDoorOpenSequence` writes into their joints
## (docs/26 section 3.4) -- while the panel itself stays put. Until 2026-09-06
## it required the panel to *rise* by `0xC80`, and passed: the "panel" it
## measured was the lattice marker, because the real one had no root-scope
## geometry and was never built.

## The mission with two closed doors, at action point 31.
const DOOR_MISSION: String = "_C_140"
## The one dev fixture with a `CrushWall`, and the wall it crushes.
const WALL_MISSION: String = "_C_129"
## The dev fixture whose turn-two script calls `GroundUnit` four times.
const GROUND_MISSION: String = "_C_143"
## The dev fixture whose levers are `L109EX00` -- `_C_140`'s one lever stands
## on a partless `L042EA00`, which is the corpus's odd record out.
const LEVER_MISSION: String = "_C_115"
## `_C_140`'s two `OpenTube` objects, on cells with no action point at all.
const TUBE_PROTOTYPE: String = "L045EA00"
const WALL_PROTOTYPE: String = "L040EA00"
## `_C_129`'s other crush wall, the one standing on a `.3DW` clone's field.
const CLONE_SHARED_PROTOTYPE: String = "L041EA00"
const CORNERS_PER_QUAD: int = 4
## Where the save seam's own check writes. Its own corner, because the slot
## screen shows what is on disk and a suite must not write where a player's
## game is.
const RESUME_SCRATCH: String = "user://tests/effects"
## The numbered slot the check writes the mission into.
const RESUME_SLOT: int = 0
## `_C_115`'s lift, as its `Use` section rides it: 44 `Elevator` steps of
## 800 world units (docs/20 section 7.4). Staged on a loaded save's cell
## rather than ridden, to make the height the authored map has not got.
const LIFT_RISE: int = 44 * 800
## A short fall, and the bound on the frames the queue is walked for.
const QUEUED_FALL_FRAMES: int = 6
## The frames the hand-built `MoveUnit` hook's bridge falls for.
const MOVE_HOOK_FRAMES: int = 30
## Where the mover walks to on [method Fixtures.tiny_world], and
## the cell its bridge is centred on.
const MOVE_HOOK_CELL: Vector2i = Vector2i(2, 3)
## Where the jet-pack jump of [method _check_warp_script_seam] lands: three
## fields from the mover with one movement point, which is past its walk
## and inside the pack's range of five -- a cell the walk fill already
## marked keeps its 10 and is not a warp target (`0x00430EE0`).
const WARP_HOOK_CELL: Vector2i = Vector2i(2, 5)
const QUEUED_GUARD: int = 60
## Two positions a rig can be at, far enough apart that a restored one
## cannot be mistaken for a freshly built mission's own opening view.
const SAVED_EYE: Vector3i = Vector3i(11200, 22400, 9600)
const SAVED_TARGET: Vector3i = Vector3i(12800, 12800, 0)


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
	_check_family(h)
	_check_family_lever(h)
	_check_clone_cells(h)
	_check_pose_record(h)
	_check_ground_hole(h)
	_check_resume_after_load(h)
	_check_rider_fall(h)
	_check_rider_fall_in_place(h)
	_check_move_script_seam(h)
	_check_ai_move_script_seam(h)
	_check_warp_script_seam(h)
	_check_platform_ride(h)
	_check_triggers(h)
	_check_setpieces(h)
	_check_queue(h)
	_check_open_ended_steps(h)
	_check_arrived_flag(h)
	_check_shot_stages(h)
	_check_unit_stands(h)
	_check_demo_missions(h)
	_check_arrival(h)
	_check_ride(h)
	_check_steps(h)
	_check_models(h)
	_check_unit_animations(h)
	_check_setpiece_camera(h)
	_check_arm_spawns(h)
	_check_ground_fire(h)
	_check_routine_sounds(h)
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
	var before: int = pool.in_use()
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
	h.equal("bgb.registration_lights_at_once", lit.in_use(), 1,
		"the object is the command's, not the sweep's")
	# `0x0041E41A`..`0x0041E425`: the sweep counts classes 0 and 2 into
	# `0x004FE640`, so a warning light -- class 1, life 255 -- keeps a slot
	# for the whole mission and is never what a play-out waits for. Counting
	# it was what held every shot on `_C_102` for the safety bound.
	h.equal("bgb.warning_light_is_not_counted_live", lit.live(), 0,
		"class 1 is outside the sweep's counter")
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
	h.equal("bgb.registration_made_all_five", lit.in_use(), 5)


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


## The ignited glow's own effect -- docs/42 section 9.1.
##
## `aPlayGroundFireAnimation` `0x004157B0` hides each victim and drops a
## `BloodFlood` and a `FlyingDebris` on it, and then -- **outside** that loop
## -- one `aBlob_CreateTubeSmoke` `0x00423C20` on the burning cell. So a glow
## that catches with nobody standing on it still flashes, which is the half
## `_C_116`'s red patches needed and the whole of what the remake drew there
## until 2026-09-09: nothing, because `ground` was not a shown kind.
func _check_ground_fire(h: TestHarness) -> void:
	h.check("ground_fire.the_round_sweep_is_shown",
		EventPlayback.SHOWN_KINDS.has("ground"),
		"the hand-over's `ground` event reaches a presenter")
	h.check("ground_fire.the_driver_animates_it",
		SetpieceDriver.is_animated("ground_fire")
		and SetpieceDriver.frames_for({"name": "ground_fire", "values": []})
			== SetpieceDriver.POOL_ONLY_FRAMES,
		"it holds until the pool drains, as `0x0042B4A0` does")
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.tiles[Vector2i(3, 4)] = {"object": Vector3i(1000, 2000, 300),
		"unit": {}}
	inputs.models["A_EXPL03.3DI"] = 3
	inputs.models["A_EXPL04.3DI"] = 4
	var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(1.0)
	var ran: bool = BlobPrograms.run(BlobPrograms.TUBE_SMOKE, pool, draws,
		PackedInt32Array([3, 4]), inputs)
	h.equal("ground_fire.smoke_count",
		[ran, pool.records.size(), draws.count],
		[true, BlobPrograms.TUBE_SMOKE_COUNT,
		BlobPrograms.TUBE_SMOKE_COUNT * 3],
		"`cmp ebx, 0x32` -- fifty records, three draws each")
	var wrong: Array[String] = []
	for index: int in range(pool.records.size()):
		var record: Dictionary = pool.records[index]
		var want: String = BlobPrograms.TUBE_SMOKE_MODELS[index & 1]
		if DictRead.as_string(record["model_name"]) != want \
				or DictRead.as_int(record["kind"]) != 0x1F \
				or DictRead.as_int(record["life"]) != 5 \
				or DictRead.as_int(record["delay"]) \
					!= index / BlobPrograms.TUBE_SMOKE_DELAY_DIVISOR \
				or DictRead.as_int(record["z"]) != 300:
			wrong.append("%d: %s" % [index, str(record)])
	h.equal("ground_fire.smoke_records", wrong.size(), 0,
		"kind 31, life 5, the two sprites alternating, delay = index / 6, "
		+ "all at the cell's marker")



## **A set piece's sound lives as long as its routine, not as long as the
## stage that started it** -- docs/28 section 1.4.
##
## Every `aPlay*` routine creates its buffer in straight-line code and kills it
## when it returns, and the remake stages one routine over several steps: the
## crush wall's one debris frame and then the pool it spins on, the statue's
## turn and then its beam, the ground unit's rise and then its carry. A queue
## that stopped its tag at every step boundary cut each of those where the
## picture changed stage -- and for the two whose cue stage is a **single
## frame**, the crush wall and the ground fire, that was the sound being
## stopped on the frame it started: silence, and the defect this table was
## written for. `crushwall.wav` is 1.79 s and it was getting 0.05.
##
## Each row is driven to the end and asked two questions: nothing had stopped
## the queue's tag while the routine was still running, and something had by
## the time it had left -- the second so a held sound cannot leak instead.
func _check_routine_sounds(h: TestHarness) -> void:
	## A silent step standing for whatever the queue holds next.
	const NEXT_ROUTINE: String = "next_routine"
	var paint: Callable = func(_frame: int, _total: int) -> void: pass
	# `kind`, the frames the driver gives it, and the arm's own `extra`.
	var rows: Array[Dictionary] = [
		{"kind": "crush_wall", "frames": SetpieceDriver.POOL_ONLY_FRAMES,
			"extra": {"cells": [[7, 2]]}, "wave": "crushwall.wav"},
		{"kind": "ground_fire", "frames": SetpieceDriver.POOL_ONLY_FRAMES,
			"extra": {"killed": []}, "wave": "gfire.wav"},
		{"kind": "statue", "frames": SetpieceDriver.STATUE_TURN_FRAMES,
			"extra": {"killed": [], "beams": []}, "wave": "stone.wav"},
		{"kind": "barrier_on", "frames": SetpieceDriver.BARRIER_FRAMES,
			"extra": {"direction": 0, "cells": 3, "killed": []},
			"wave": "lbarrier.wav"},
		{"kind": "fire_circle", "frames": SetpieceDriver.FIRE_CIRCLE_FRAMES,
			"extra": {}, "wave": "firecircle.wav"},
		{"kind": "teleporter", "frames": SetpieceDriver.TELEPORTER_FRAMES,
			"extra": {"tx": 5, "ty": 6}, "wave": "teleport.wav"},
		{"kind": "roof_unit", "frames": 8, "extra": {},
			"wave": "crush.wav"},
		{"kind": "ground_unit", "frames": SetpieceDriver.GROUND_UNIT_FRAMES,
			"extra": {"own": Vector2i(4, 4)}, "wave": "alien_scream.wav"},
	]
	var cut: Array[String] = []
	var leaked: Array[String] = []
	for row: Dictionary in rows:
		var kind: String = DictRead.as_string(row["kind"])
		var audio: RecordingAudio = RecordingAudio.new()
		var host: RecordingHost = RecordingHost.new()
		# The pool never drains, so its stage runs its whole bound and the
		# routine is still going when the question is asked.
		host.live = 2
		var queue: SequenceQueue = SequenceQueue.create(audio)
		var cues: Array[Dictionary] = [{"wave": DictRead.as_string(row["wave"]),
			"volume_id": 84, "loop": false}]
		var _staged: int = SetpieceCamera.enqueue(queue, host, kind,
			DictRead.as_int(row["frames"]), Vector2i(3, 4), 0, 0, -1,
			DictRead.as_dict(row["extra"]), paint, cues)
		# A second routine behind it, silent: `_present_ground_fire` queues
		# one sequence per burnt cell back to back, so "the sound was handed
		# on" and "the sound bleeds into the next routine" are the same
		# picture until something asks where it stopped.
		queue.enqueue(NEXT_ROUTINE, 2, paint)
		# The stops counted on the frame after the cue was played: the
		# routine has changed stage by then in every row, and none of them
		# has finished.
		var during: int = -1
		var at_next: int = -1
		var spun: int = 0
		while queue.is_running() and spun < 400:
			var _still: bool = queue.advance(
				1.0 / SequenceQueue.FRAMES_PER_SECOND)
			spun += 1
			var stage: String = queue.current()
			if during < 0 and not audio.plays.is_empty() \
					and stage != kind and stage != NEXT_ROUTINE:
				during = audio.stops
			if at_next < 0 and stage == NEXT_ROUTINE:
				at_next = audio.stops
		if audio.plays.size() != 1 or during != 0:
			cut.append("%s: %s after %d stops" % [kind, str(audio.plays),
				during])
		# Exactly one: none is the sound running on into the next routine,
		# two is a stage boundary killing it again after the routine already
		# had.
		if at_next != 1:
			leaked.append("%s: %d stops when the next routine began"
				% [kind, at_next])
		audio.free()
	h.equal("routine_sound.plays_to_the_end_of_its_routine", cut, [],
		"a stage boundary used to stop the tag, which on a one-frame stage "
		+ "is silence")
	h.equal("routine_sound.and_dies_when_the_routine_returns", leaked, [],
		"docs/28 section 1.4 -- the buffer is killed when the routine ends, "
		+ "which is before the next routine's first frame")

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
	h.equal("arm_spawn.runs", [full, hooks.executed, hooks.made, pool.in_use()],
		[true, 1, 1, 1], "one `0x00423720` request, one record in the pool")
	# One value short: refused and counted, not indexed past the end. Since
	# docs/97 section 48 no request in [BlobKinds] is short, so this is what
	# one **would** do -- the guard outlived the defect that earned it.
	var short: bool = hooks.spawn(BlobKinds.CREATE_ZOOM_BOB,
		[0, 0, 3200, 1, 5], source)
	h.equal("arm_spawn.short_call_refused",
		[short, hooks.short_call.get(BlobKinds.CREATE_ZOOM_BOB, 0),
		hooks.executed, pool.in_use()], [true, 1, 1, 1],
		"the creator takes six; the request carried five")
	# An address with no program: the whole layer's old answer, now counted.
	# `0x00424250` is a **weapon** creator (docs/97 section 22 transcribes it
	# in Python, for the oracle), so nothing in [BlobKinds] asks for it and
	# this is the counter working rather than a case that runs.
	var none: bool = hooks.spawn(0x00424250, [0, 0, 3200], source)
	h.equal("arm_spawn.unhandled_counted",
		[none, hooks.unhandled.get(0x00424250, 0), pool.in_use()], [true, 1, 1],
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

	# Every clone, special object and lattice marker is built -- which the
	# render suite checks on `_C_115`, a mission with no all-part prototype.
	# `_C_140`'s two doors are all-part, and were the two this count missed.
	var expected: int = DictRead.as_array(document["scene_clones"]).size() \
		+ DictRead.as_array(document["special_objects"]).size() \
		+ DictRead.as_array(DictRead.as_dict(document["land"])["x"]).size()
	h.equal("door.mission_instances", scenery.built_count(), expected,
		"the doors are built along with everything else")

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
	h.check("door.ships_closed",
		(world.state.action_point_at(door) & 1) == 1,
		"action point %d -- the closed one, so the first toggle opens it"
			% world.state.action_point_at(door))
	var objects: Array = scenery.objects_on(door)
	h.check("door.has_object", not objects.is_empty(),
		"%d object(s) beside the marker on the door's cell" % objects.size())
	if objects.is_empty():
		scenery.free()
		return
	var panel: Node3D = objects[0]
	h.check("door.is_the_panel", panel.name.begins_with("L100EX00"),
		"the object is %s" % panel.name)
	h.check("door.has_geometry", _surfaces_under(panel) > 0,
		"%d surface(s) drawn under the panel" % _surfaces_under(panel))
	var first: Node3D = scenery.pivot_of(panel, Scenery.LEAF_FIRST)
	var second: Node3D = scenery.pivot_of(panel, Scenery.LEAF_SECOND)
	h.check("door.two_leaves", first != null and second != null,
		"parts 6 and 12 each have a pivot")
	if first == null or second == null:
		scenery.free()
		return
	h.check("door.leaves_hinged_at_the_frame",
		is_equal_approx(absf(first.position.x), 1440.0
			/ WorldSpace.WORLD_UNITS_PER_METRE)
		and is_equal_approx(absf(second.position.x), 1440.0
			/ WorldSpace.WORLD_UNITS_PER_METRE)
		and first.position.x * second.position.x < 0.0,
		"the pivots sit 1440 units either side of the panel's centre")
	h.check("door.closed_leaves_shut",
		first.basis.is_equal_approx(Basis.IDENTITY)
		and second.basis.is_equal_approx(Basis.IDENTITY),
		"a closed door's joints are 0")
	var standing: Array = scenery.instances_on(door)
	var marker: Node3D = null
	for node: Variant in standing:
		var instance: Node3D = node
		if instance != panel and not objects.has(instance):
			marker = instance
	h.check("door.marker_present", marker != null,
		"the lattice marker stands on the cell too")
	var was: Vector3 = panel.transform.origin
	var marker_was: Vector3 = Vector3.ZERO if marker == null \
		else marker.transform.origin

	# Open it the way the world does -- the toggle, so the parity flips with
	# the height -- then redraw only what changed.
	Interact.toggle_door(world.state, door)
	var after: Dictionary = world.terrain_snapshot()
	var moved: PackedInt32Array = TerrainDiff.moved_cells(before, after)
	h.equal("door.diff", moved, PackedInt32Array([door]),
		"exactly the door's cell is reported as moved")
	var count: int = scenery.apply_state(after, moved)
	h.check("door.applied", count == standing.size(),
		"%d of %d instance(s) took the state" % [count, standing.size()])
	h.check("door.panel_stays", panel.transform.origin.is_equal_approx(was),
		"the panel did not move: `[ebp+0x18]` is the land marker's z")
	var open_first: Basis = WorldSpace.joint_basis(0, 0,
		-Scenery.DOOR_LEAF_SWING)
	var open_second: Basis = WorldSpace.joint_basis(0, 0,
		Scenery.DOOR_LEAF_SWING)
	h.check("door.leaves_swing",
		first.basis.is_equal_approx(open_first)
		and second.basis.is_equal_approx(open_second),
		"part 6 at -%d, part 12 at +%d of 4096"
			% [Scenery.DOOR_LEAF_SWING, Scenery.DOOR_LEAF_SWING])
	h.check("door.leaves_turn_about_z",
		is_equal_approx(first.basis.y.y, 1.0)
		and is_equal_approx(second.basis.y.y, 1.0),
		"the hinges are vertical")
	if marker != null:
		var drop: float = float(Interact.DOOR_HEIGHT_STEP) \
			/ WorldSpace.WORLD_UNITS_PER_METRE
		h.check("door.marker_tracks_height",
			absf((marker_was.y - marker.transform.origin.y) - drop) < 0.001,
			"the marker dropped %f m, wanted %f m"
				% [marker_was.y - marker.transform.origin.y, drop])

	# Applying the same state twice is applying it once: the pose is taken
	# from the state every time, never accumulated.
	var _again: int = scenery.apply_state(after, moved)
	h.check("door.idempotent",
		panel.transform.origin.is_equal_approx(was)
		and first.basis.is_equal_approx(open_first)
		and second.basis.is_equal_approx(open_second),
		"a second apply lands in the same pose")

	# The ten frames: a swing of `frame * step`, and the last frame is the
	# open pose exactly.
	h.equal("door.step_times_frames",
		Scenery.DOOR_LEAF_STEP * SetpieceDriver.DOOR_FRAMES,
		Scenery.DOOR_LEAF_SWING,
		"ten frames of +-100 reach +-1000")
	var half: int = scenery.paint_door(door,
		Scenery.DOOR_LEAF_STEP * (SetpieceDriver.DOOR_FRAMES / 2))
	h.equal("door.paint_turns_two", half, 2, "both leaves turn")
	h.check("door.paint_halfway",
		first.basis.is_equal_approx(WorldSpace.joint_basis(0, 0,
			-Scenery.DOOR_LEAF_STEP * (SetpieceDriver.DOOR_FRAMES / 2))),
		"the fifth frame is half open")
	var _full: int = scenery.apply_state(after, moved)

	# And closing it puts everything back exactly where it started, which is
	# what "the picture is a function of the state" has to mean.
	Interact.toggle_door(world.state, door)
	var _closed: int = scenery.apply_state(world.terrain_snapshot(), moved)
	h.check("door.reversible",
		panel.transform.origin.is_equal_approx(was)
		and first.basis.is_equal_approx(Basis.IDENTITY)
		and second.basis.is_equal_approx(Basis.IDENTITY)
		and (marker == null
			or marker.transform.origin.is_equal_approx(marker_was)),
		"closing it returns the leaves and the marker to their authored pose")
	scenery.free()


## docs/42 section 8.3 -- the door's family on the scenery: the lever's
## handle, a supply box's lid and a tube's hatch through
## [method Scenery.paint_joint] on `_C_140`, and a crush wall's own fall and
## deletion through [method Scenery.paint_pose] and
## [method Scenery.remove_objects] on `_C_129`, the one dev fixture with a
## `CrushWall`.
func _check_family(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(DOOR_MISSION)
	if loaded.is_empty():
		h.check("family.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	if geometry.is_empty():
		h.check("family.geometry", false, "geometry/%s.json"
			% DictRead.as_string(header["world_set"]))
		return
	var scenery: Scenery = Scenery.new()
	scenery.build(document, geometry, {})
	var _placed: int = scenery.apply_all(world.terrain_snapshot())

	# `paint_pose` composes the authored yaw through `joint_basis`, and the
	# placement used `yaw_basis`: the two helpers are written separately and
	# have to agree on a plain yaw.
	h.check("family.yaw_is_joint_z",
		WorldSpace.yaw_basis(700).is_equal_approx(WorldSpace.joint_basis(0, 0, 700))
		and WorldSpace.yaw_basis(-1234).is_equal_approx(
			WorldSpace.joint_basis(0, 0, -1234)),
		"a yaw is the z angle of the joint builder")

	# `_C_140`'s one lever stands on `L042EA00`, which has no part: nothing
	# turns, and nothing breaks. The handle itself is checked on `_C_115`.
	var odd: int = _find_action_point(world, Interact.LEVER_UP)
	h.check("family.lever.partless_present", odd >= 0,
		"a cell with action point %d on %s" % [Interact.LEVER_UP, DOOR_MISSION])
	if odd >= 0:
		h.check("family.lever.partless_has_no_handle",
			not scenery.has_joint(odd, Scenery.LEVER_PART),
			"L042EA00 carries no part %d" % Scenery.LEVER_PART)
		h.equal("family.lever.partless_paints_nothing",
			scenery.paint_joint(odd, Scenery.LEVER_PART,
				Vector3i(-Scenery.LEVER_THROW, 0, 0)), 0)
		h.equal("family.no_such_part",
			scenery.paint_joint(odd, 99, Vector3i.ZERO), 0,
			"a part nothing on the cell carries turns nothing")

	# A supply box: L101EX00 / L115EX00, one part, the lid.
	var box: int = -1
	for ap: int in [12, 13, 17, 18, 14, 15, 16, 38, 39, 40, 42]:
		box = _find_action_point(world, ap)
		if box >= 0:
			break
	h.check("family.box.present", box >= 0, "a pickup cell on %s" % DOOR_MISSION)
	if box >= 0:
		h.check("family.box.has_lid",
			scenery.has_joint(box, SetpieceDriver.PART_FIRST),
			"the box on the cell carries part %d" % SetpieceDriver.PART_FIRST)
		var open: Vector3i = Vector3i(SetpieceDriver.PICKUP_LID_STEP
			* SetpieceDriver.PICKUP_LID_FRAMES, 0, 0)
		var lid: int = scenery.paint_joint(box, SetpieceDriver.PART_FIRST, open)
		h.check("family.box.lid_opens",
			lid >= 1 and scenery.joint_of(box, SetpieceDriver.PART_FIRST) == open,
			"twenty frames of 20 stand the lid at 400 about x")

	# A tube: an entry point whose object has a hatch, opened by the script
	# and remembered here alone -- the cell's state says nothing about it.
	var tubes: PackedInt32Array = scenery.cells_with_prototype(TUBE_PROTOTYPE)
	var tube: int = -1
	for index: int in tubes:
		if scenery.has_joint(index, SetpieceDriver.PART_FIRST):
			tube = index
			break
	h.check("family.tube.present", tube >= 0,
		"%d %s tube(s) on %s, one with a hatch" % [tubes.size(), TUBE_PROTOTYPE,
			DOOR_MISSION])
	if tube >= 0:
		var opened: Vector3i = Vector3i(SetpieceDriver.TUBE_STEP
			* SetpieceDriver.TUBE_FRAMES, 0, 0)
		var hatch: int = scenery.paint_joint(tube, SetpieceDriver.PART_FIRST, opened)
		h.check("family.tube.hatch_opens",
			hatch >= 1 and scenery.joint_of(tube, SetpieceDriver.PART_FIRST) == opened,
			"nineteen frames of 51 stand the hatch at 969")
		var _kept: int = scenery.apply_state(world.terrain_snapshot(),
			PackedInt32Array([tube]))
		h.equal("family.tube.pose_survives_state",
			scenery.joint_of(tube, SetpieceDriver.PART_FIRST), opened,
			"applying the state repaints doors and levers, not hatches")
		# The driver's own arm, frame by frame, from the authored pose.
		var _shut: int = scenery.paint_joint(tube, SetpieceDriver.PART_FIRST,
			Vector3i.ZERO)
		var none: PackedInt32Array = PackedInt32Array()
		var picture: Dictionary = {"starts": {}}
		var host: RecordingHost = RecordingHost.new()
		h.equal("family.tube.arm_paints_one", SetpieceDriver.paint_family(
			scenery, tube, "open_tube", none, 10, 19, picture, host), 1)
		h.equal("family.tube.arm_tenth_frame",
			scenery.joint_of(tube, SetpieceDriver.PART_FIRST),
			Vector3i(SetpieceDriver.TUBE_STEP * 10, 0, 0))
		var _last: int = SetpieceDriver.paint_family(scenery, tube, "open_tube",
			none, 19, 19, picture, host)
		h.equal("family.tube.arm_ends_open",
			scenery.joint_of(tube, SetpieceDriver.PART_FIRST), opened)
		var again: Dictionary = {"starts": {}}
		var _twice: int = SetpieceDriver.paint_family(scenery, tube, "open_tube",
			none, 19, 19, again, host)
		h.equal("family.tube.second_opening_starts_open",
			scenery.joint_of(tube, SetpieceDriver.PART_FIRST),
			opened + opened, "the start is read off the object, not authored")
		# The bridge's toggle, on the same part: turned lowers, zero rises.
		var _zero: int = scenery.paint_joint(tube, SetpieceDriver.PART_FIRST,
			Vector3i.ZERO)
		var raise: Dictionary = {"starts": {}}
		var _up: int = SetpieceDriver.paint_family(scenery, tube, "bridge", none,
			SetpieceDriver.BRIDGE_FRAMES, SetpieceDriver.BRIDGE_FRAMES, raise, host)
		h.equal("family.bridge.arm_raises_from_zero",
			scenery.joint_of(tube, SetpieceDriver.PART_FIRST),
			Vector3i(SetpieceDriver.BRIDGE_STEP * SetpieceDriver.BRIDGE_FRAMES, 0, 0))
		var lower: Dictionary = {"starts": {}}
		var _down: int = SetpieceDriver.paint_family(scenery, tube, "bridge", none,
			SetpieceDriver.BRIDGE_FRAMES, SetpieceDriver.BRIDGE_FRAMES, lower, host)
		h.equal("family.bridge.arm_lowers_when_raised",
			scenery.joint_of(tube, SetpieceDriver.PART_FIRST), Vector3i.ZERO,
			"`mov di, [esi+0x26]` / `neg` / `sbb`: the sign is the pose's")
		h.equal("family.unknown_kind_paints_nothing", SetpieceDriver.paint_family(
			scenery, tube, "nothing", none, 1, 1, {"starts": {}}, host), 0)
		# The rotating statue's turn, on the same part 6: thirteen frames of
		# +0x50 on the z word, then the start plus 0x400 -- which is sixteen
		# units *back* from the thirteenth frame. `_C_178`'s three `Statue2`
		# cells carry `L014EH00`, whose one part is exactly this (docs/42
		# section 8.3), and two of them ship turned to -1000.
		var _statue_start: int = scenery.paint_joint(tube, SetpieceDriver.PART_FIRST,
			Vector3i(0, 0, -1000))
		var statue_picture: Dictionary = {"starts": {}}
		var statue_frames: int = SetpieceDriver.STATUE_TURN_FRAMES
		h.equal("family.statue.arm_turns_the_joint", SetpieceDriver.paint_family(
			scenery, tube, "statue", none, statue_frames - 1, statue_frames,
			statue_picture, host), 1)
		h.equal("family.statue.thirteenth_frame",
			scenery.joint_of(tube, SetpieceDriver.PART_FIRST),
			Vector3i(0, 0, -1000 + SetpieceDriver.STATUE_TURN_STEP * (statue_frames - 1)),
			"`add word [esi+0x2A], bp` thirteen times from the start read off the object")
		var _settled: int = SetpieceDriver.paint_family(
			scenery, tube, "statue", none, statue_frames, statue_frames,
			statue_picture, host)
		h.equal("family.statue.settles_on_the_quarter_turn",
			scenery.joint_of(tube, SetpieceDriver.PART_FIRST),
			Vector3i(0, 0, -1000 + SetpieceDriver.STATUE_SETTLE),
			"`0x00413C26` writes the start plus 0x400, sixteen short of frame thirteen")
	if box >= 0:
		var lid_shut: int = scenery.paint_joint(box, SetpieceDriver.PART_FIRST,
			Vector3i.ZERO)
		var lid_picture: Dictionary = {"starts": {}}
		var _hold: int = SetpieceDriver.paint_family(scenery, box, "pickup",
			PackedInt32Array(), 35, 35, lid_picture, RecordingHost.new())
		h.check("family.box.arm_holds_the_lid_open", lid_shut == 1
			and scenery.joint_of(box, SetpieceDriver.PART_FIRST)
				== Vector3i(SetpieceDriver.PICKUP_LID_STEP
					* SetpieceDriver.PICKUP_LID_FRAMES, 0, 0),
			"the hold frames past twenty do not lift it further")
	scenery.free()

	# The crush wall: its own rotation and its own drop, then its deletion.
	var wall_loaded: Dictionary = CacheFixture.load_world(WALL_MISSION)
	if wall_loaded.is_empty():
		h.check("family.wall.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var wall_world: World = wall_loaded["world"]
	var wall_document: Dictionary = DictRead.as_dict(wall_loaded["document"])
	var wall_header: Dictionary = DictRead.as_dict(wall_document["header"])
	var wall_geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(wall_header["world_set"]))
	if wall_geometry.is_empty():
		h.check("family.wall.geometry", false, "geometry/%s.json"
			% DictRead.as_string(wall_header["world_set"]))
		return
	var walls: Scenery = Scenery.new()
	walls.build(wall_document, wall_geometry, {})
	var _all: int = walls.apply_all(wall_world.terrain_snapshot())
	var built: int = walls.built_count()
	var cells: PackedInt32Array = walls.cells_with_prototype(WALL_PROTOTYPE)
	h.check("family.wall.present", not cells.is_empty(),
		"%d %s wall(s) on %s" % [cells.size(), WALL_PROTOTYPE, WALL_MISSION])
	if cells.is_empty():
		walls.free()
		return
	var cell: int = cells[0]
	var wall: Node3D = walls.objects_on(cell)[0]
	var was: Transform3D = wall.transform
	var turn: Vector3i = Vector3i(SetpieceDriver.CRUSH_TURN_STEP * 3, 0, 0)
	var drop: int = SetpieceDriver.CRUSH_DROP_STEP * 3
	h.equal("family.wall.paint_poses_one", walls.paint_pose(cell, turn, drop), 1)
	h.check("family.wall.sinks_by_its_own_step",
		is_equal_approx(was.origin.y - wall.transform.origin.y,
			float(drop) / WorldSpace.WORLD_UNITS_PER_METRE),
		"three frames of 480 down from the authored origin, not the cell's delta")
	h.check("family.wall.turns_about_its_own_x",
		wall.basis.is_equal_approx(was.basis * WorldSpace.joint_basis(turn.x, 0, 0)),
		"three frames of 0x66 about x on top of the authored yaw")
	var _again: int = walls.paint_pose(cell, turn, drop)
	h.check("family.wall.idempotent",
		wall.transform.is_equal_approx(Transform3D(
			was.basis * WorldSpace.joint_basis(turn.x, 0, 0),
			was.origin + WorldSpace.to_godot(0, 0, -drop))),
		"the pose is absolute: painting a frame twice paints it once")
	var wall_picture: Dictionary = {"starts": {}}
	h.equal("family.wall.arm_poses_one", SetpieceDriver.paint_family(walls, cell,
		"crush_wall", PackedInt32Array(), 3, 40, wall_picture, RecordingHost.new()), 1)
	h.check("family.wall.arm_is_the_pose",
		wall.transform.is_equal_approx(Transform3D(
			was.basis * WorldSpace.joint_basis(turn.x, 0, 0),
			was.origin + WorldSpace.to_godot(0, 0, -drop))),
		"the third frame through the driver is the third frame painted by hand")
	h.equal("family.wall.removed", walls.remove_objects(cell), 1,
		"aDeleteLand frees the one object")
	h.check("family.wall.gone_from_the_cell", walls.objects_on(cell).is_empty())
	h.equal("family.wall.marker_stays", walls.instances_on(cell).size(), 1,
		"the lattice marker is not the wall")
	h.equal("family.wall.removed_count", walls.removed_count(), 1)
	h.equal("family.wall.built_count_unchanged", walls.built_count(), built,
		"what was built stays counted; what went is counted apart")
	h.equal("family.wall.paint_after_removal",
		walls.paint_pose(cell, Vector3i.ZERO, 0), 0)
	var _safe: int = walls.apply_state(wall_world.terrain_snapshot(),
		PackedInt32Array([cell]))
	h.check("family.wall.state_after_removal", walls.objects_on(cell).is_empty(),
		"applying the state to an emptied cell is harmless")
	walls.free()


## What the save carries for the picture (docs/42 section 8.3): a hatch
## opened and a wall crushed on `_C_129` come back on a fresh scenery from
## [method Scenery.pose_record] alone -- through the JSON narrowing the save
## header puts them through -- and restoring twice is restoring once.
func _check_pose_record(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(WALL_MISSION)
	if loaded.is_empty():
		h.check("poses.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	if geometry.is_empty():
		h.check("poses.geometry", false, "geometry/%s.json"
			% DictRead.as_string(header["world_set"]))
		return
	var played: Scenery = Scenery.new()
	played.build(document, geometry, {})
	var _all: int = played.apply_all(world.terrain_snapshot())
	h.equal("poses.authored_record_is_empty", played.pose_record(),
		{"joints": [], "removed": [], "moves": []},
		"nothing has moved, so there is nothing to carry")
	var walls: PackedInt32Array = played.cells_with_prototype(WALL_PROTOTYPE)
	var tubes: PackedInt32Array = played.cells_with_prototype(TUBE_PROTOTYPE)
	h.check("poses.fixture_has_a_wall_and_a_tube",
		not walls.is_empty() and not tubes.is_empty(),
		"%d wall(s), %d tube(s) on %s" % [walls.size(), tubes.size(), WALL_MISSION])
	if walls.is_empty() or tubes.is_empty():
		played.free()
		return
	var wall: int = walls[0]
	var tube: int = tubes[0]
	var open: Vector3i = Vector3i(SetpieceDriver.TUBE_STEP * SetpieceDriver.TUBE_FRAMES, 0, 0)
	var _hatch: int = played.paint_joint(tube, SetpieceDriver.PART_FIRST, open)
	var _gone: int = played.remove_objects(wall)
	var record: Dictionary = played.pose_record()
	h.equal("poses.record_lists_the_moved_part", record["joints"],
		[[tube, SetpieceDriver.PART_FIRST, open.x, 0, 0]],
		"one row: the cell, the part and the triple that differs from the .lev")
	h.equal("poses.record_lists_the_freed_cell", record["removed"], [wall])
	# Through the save header's JSON, which turns every number into a float.
	var parsed: Variant = JSON.parse_string(JSON.stringify(record))
	var carried: Dictionary = parsed
	var resumed: Scenery = Scenery.new()
	resumed.build(document, geometry, {})
	var _placed: int = resumed.apply_all(world.terrain_snapshot())
	h.equal("poses.restore_counts", resumed.restore_poses(carried), 2,
		"one part turned, one cell emptied")
	h.equal("poses.hatch_is_open_again",
		resumed.joint_of(tube, SetpieceDriver.PART_FIRST), open)
	h.check("poses.wall_is_gone_again", resumed.objects_on(wall).is_empty()
		and resumed.removed_count() == 1)
	h.equal("poses.restored_record_matches", resumed.pose_record(), record,
		"what was restored records back as what was saved")
	h.equal("poses.restore_twice_is_once", resumed.restore_poses(carried), 1,
		"the part is painted again (absolute), the cell has nothing left to free")
	h.equal("poses.record_after_twice", resumed.pose_record(), record)
	h.equal("poses.empty_record_restores_nothing", resumed.restore_poses({}), 0)
	played.free()
	resumed.free()


## `GroundUnit` leaves the flat level object the original inserts at
## `0x00411FB0`, and that runtime-only object survives a picture save.
func _check_ground_hole(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(GROUND_MISSION)
	if loaded.is_empty():
		h.check("ground_hole.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	var prototype: String = SetpieceCamera.GROUND_HOLE_MODEL
	if not DictRead.as_dict(geometry.get("prototypes", {})).has(prototype):
		h.check("ground_hole.prototype", false, prototype)
		return
	var cell_xy: Vector2i = Vector2i(19, 16)
	var cell: int = world.state.index_of(cell_xy.x, cell_xy.y)
	var at: Vector3i = CameraRig.cell_object(cell_xy.x, cell_xy.y,
		world.state.height_at(cell))
	var played: Scenery = Scenery.new()
	played.build(document, geometry, {})
	var before: int = played.objects_on(cell).size()
	h.check("ground_hole.inserted", played.insert_object(prototype, at))
	h.equal("ground_hole.object_is_drawn", played.objects_on(cell).size(),
		before + 1)
	var record: Dictionary = played.pose_record()
	h.equal("ground_hole.saved", record.get("inserted", []),
		[[cell, prototype, at.x, at.y, at.z, 0]])
	var carried: Dictionary = JSON.parse_string(JSON.stringify(record))
	var resumed: Scenery = Scenery.new()
	resumed.build(document, geometry, {})
	var resumed_before: int = resumed.objects_on(cell).size()
	h.equal("ground_hole.restore_counts", resumed.restore_poses(carried), 1)
	h.equal("ground_hole.restored", resumed.objects_on(cell).size(),
		resumed_before + 1)
	h.equal("ground_hole.restore_is_idempotent",
		resumed.restore_poses(carried), 0)
	played.free()
	resumed.free()


## The riders a falling footbridge carries (docs/42 section 8.3): one map
## field less `0xA0` down a frame, and a tumble of their **own** rotation
## words -- `+0x24` by 25 and `+0x22` by 12, negative for an odd rider, so
## two on one bridge turn opposite ways.
##
## `interaction_tables.py` (`family.footbridges.drop_the_riders`,
## `.turn_the_riders`) pins both against the two loops; this is the port
## reading the same numbers, and the body's half turn beside them: it is a
## half turn about the **model's** vertical, which only a tilted object can
## tell from a half turn about the world's.
func _check_rider_fall(h: TestHarness) -> void:
	h.equal("rider.drop_is_the_field_less_the_step_back",
		SetpieceDriver.FOOTBRIDGE_RIDER_DROP, 0xC80 - 0xA0,
		"`sub eax, 0xC80` and `add eax, 0xA0` on the way to the setter")
	h.equal("rider.turn_grows_with_the_frame",
		[SetpieceDriver.rider_turn(0, 1), SetpieceDriver.rider_turn(0, 3)],
		[Vector3i(0, 12, 25), Vector3i(0, 36, 75)])
	h.equal("rider.odd_rider_turns_the_other_way",
		SetpieceDriver.rider_turn(1, 3), Vector3i(0, -36, -75),
		"`test bl, 1` on the loop counter is the sign")
	h.equal("rider.turn_is_zero_before_the_first_frame",
		SetpieceDriver.rider_turn(1, 0), Vector3i.ZERO)

	var facing: int = 3
	var angle: int = UnitsView.FACING_ANGLES[facing]
	h.check("rider.body_offset_is_the_charisma_half_turn",
		(WorldSpace.yaw_basis(angle).inverse()
			* WorldSpace.charisma_yaw_basis(angle)).is_equal_approx(
			WorldSpace.charisma_offset()),
		"the two agree on a level body, which is where they must")

	var units: UnitsView = UnitsView.new()
	var node: Node3D = Node3D.new()
	node.name = "unit_0"
	units.add_child(node)
	h.check("rider.tumble_needs_a_node", not units.tumble(1, facing, Vector3i.ZERO))
	h.check("rider.tumble_of_nothing_is_the_facing",
		units.tumble(0, facing, Vector3i.ZERO)
		and node.basis.is_equal_approx(WorldSpace.yaw_basis(angle)),
		"a zero triple leaves the unit pointing where it stood")
	var _first: bool = units.tumble(0, facing, SetpieceDriver.rider_turn(0, 8))
	var even: Basis = node.basis
	var _second: bool = units.tumble(0, facing, SetpieceDriver.rider_turn(1, 8))
	var odd: Basis = node.basis
	h.check("rider.tumble_tilts_it", even.y.angle_to(Vector3.UP) > 0.01,
		"a rider on its way down is not standing up: %.3f rad"
			% even.y.angle_to(Vector3.UP))
	h.check("rider.tumble_turns_the_two_riders_apart",
		not even.is_equal_approx(odd),
		"the second rider of the same bridge turns the other way")
	units.free()


## The same fall through the seam that actually runs it: an event `core`
## has already finished, queued with [method SliceMain._queue_setpiece] and
## advanced frame by frame.
##
## What the isolated checks above cannot reach is the **record lookup**. By
## the time a footbridge is drawn its riders are dead -- `core` killed them
## resolving the command -- so the heading the tumble is measured from comes
## out of a record for a unit that is off the map. `UnitState.remove` keeps
## the record and clears the cell, which is why this works at all, and a
## `hp == 0` record that answered nothing would leave the bodies falling
## flat rather than crash.
func _check_rider_fall_in_place(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(WALL_MISSION)
	if loaded.is_empty():
		h.check("queued_rider.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var slots: PackedInt32Array = world.unit_slots()
	if slots.size() < 2:
		h.check("queued_rider.two_units", false,
			"%s carries %d unit(s)" % [WALL_MISSION, slots.size()])
		return
	var riders: PackedInt32Array = PackedInt32Array([slots[0], slots[1]])
	var facings: Array[int] = []
	for slot: int in riders:
		facings.append(DictRead.as_int(world.unit_view(slot)["facing"]))

	var main: SliceMain = SliceMain.new()
	main.world = world
	# **The picture reads the mirror**, and the mirror is taken before the
	# riders are killed: that is what keeps them on screen for the fall
	# without a hold of the presentation's own (docs/100 section 2).
	main._shown = world.clone()
	var units: UnitsView = UnitsView.new()
	units.shown_ref = main._shown
	main._units = units
	for slot: int in riders:
		var node: Node3D = Node3D.new()
		node.name = "unit_%d" % slot
		units.add_child(node)
	main._sequences = SequenceQueue.create(null)
	main._rig = CameraRig.new()
	main._rig.set_now(SAVED_EYE, SAVED_TARGET)

	# `core` first: the interpreter kills every rider before the event is
	# ever played (docs/42 section 8.1), which is the order this must run in.
	for slot: int in riders:
		var doomed: UnitState = world.units_for_ai()[slot]
		var _lost: bool = UnitState.remove(world.state, world.unit_types(),
			world.turn, doomed)
	h.check("queued_rider.core_killed_them",
		world.unit_view(riders[0]).is_empty()
		or DictRead.as_int(world.unit_view(riders[0])["hp"]) == 0,
		"the riders are dead before the picture starts")
	h.equal("queued_rider.the_record_survives_the_kill",
		DictRead.as_int(main._unit_record(riders[0])["facing"]), facings[0],
		"`UnitState.remove` keeps the record, so the tumble has a heading "
		+ "to measure from")

	var cell: Vector2i = Vector2i(1, 1)
	var event: Dictionary = {"name": "foot_bridge",
		"values": [cell.x, cell.y, QUEUED_FALL_FRAMES, riders.size(),
			riders[0], riders[1]]}
	var cues: Array[Dictionary] = []
	main._queue_setpiece(event, QUEUED_FALL_FRAMES, cues)
	h.check("queued_rider.is_queued", main._sequences.is_running(),
		"the flight, the fall and the flight back")
	h.check("queued_rider.the_mirror_keeps_both_during_the_fall",
		DictRead.as_int(main._shown.unit_view(riders[0])["hp"]) > 0
		and DictRead.as_int(main._shown.unit_view(riders[1])["hp"]) > 0,
		"the truth lost them when the hook ran; the picture has not "
		+ "been told yet")

	# The flight settles at once -- nothing advances the rig here -- and then
	# the fall's own frames run.
	var step: float = 1.0 / SequenceQueue.FRAMES_PER_SECOND
	var guard: int = 0
	while main._sequences.current() != "foot_bridge" and guard < QUEUED_GUARD:
		var _went: bool = main._sequences.advance(step)
		main._rig.settle()
		guard += 1
	h.check("queued_rider.reaches_the_fall",
		main._sequences.current() == "foot_bridge",
		"stage %s after %d frame(s)" % [main._sequences.current(), guard])
	var _third: bool = main._sequences.advance(step)
	var _fourth: bool = main._sequences.advance(step)
	var lifts: Dictionary[int, int] = units.lifts()
	var dropped: int = lifts[riders[0]] if lifts.has(riders[0]) else 0
	h.equal("queued_rider.drops_by_the_step",
		dropped, -SetpieceDriver.FOOTBRIDGE_RIDER_DROP * 2,
		"two frames of the fall, each one step")
	var first_node: Node3D = units.get_node_or_null(
		NodePath("unit_%d" % riders[0]))
	var second_node: Node3D = units.get_node_or_null(
		NodePath("unit_%d" % riders[1]))
	if first_node == null or second_node == null:
		h.check("queued_rider.bodies_are_still_drawn", false,
			"the fall takes them out only at the end")
		units.free()
		main._rig.free()
		main.free()
		return
	var first: Basis = first_node.basis
	var second: Basis = second_node.basis
	h.check("queued_rider.tumbles_from_its_own_heading",
		first.is_equal_approx(WorldSpace.joint_basis(0,
			SetpieceDriver.rider_turn(0, 2).y,
			UnitsView.FACING_ANGLES[facings[0] % UnitsView.FACING_ANGLES.size()]
			+ SetpieceDriver.rider_turn(0, 2).z)),
		"the dead rider's own facing plus two frames of turn")
	h.check("queued_rider.the_two_turn_apart", not first.is_equal_approx(second)
		or facings[0] != facings[1],
		"opposite signs by the order the event lists them")

	# The loop's end: `aRemoveUnitElement` takes them off the picture too.
	while main._sequences.is_running() and guard < QUEUED_GUARD:
		var _more: bool = main._sequences.advance(step)
		main._rig.settle()
		guard += 1
	h.check("queued_rider.leave_at_the_end",
		units.get_node_or_null(NodePath("unit_%d" % riders[0])) == null
		and units.get_node_or_null(NodePath("unit_%d" % riders[1])) == null,
		"both bodies are gone when the sequence ends")
	# And the picture catches up: the mirror is handed the kill, and a
	# rebuild then draws neither.
	for slot: int in riders:
		var gone: UnitState = main._shown.units_for_ai()[slot]
		var _dropped: bool = UnitState.remove(main._shown.state,
			main._shown.unit_types(), main._shown.turn, gone)
	units.build(main._shown, {"prototypes": {}}, {})
	h.check("queued_rider.the_mirror_catches_up",
		units.get_node_or_null(NodePath("unit_%d" % riders[0])) == null,
		"a dead record is not drawn once the delta has landed")
	units.free()
	main._rig.free()
	main.free()


## A cell carrying both a `.3DW` clone and a special object: what the
## engine's search can find there, and what it cannot.
##
## `0x00406F20` walks the special-object table alone, and the converter
## places the level's clones **first** -- so "the first object on the cell"
## was the clone wherever the two share a field. On `_C_142` that was the
## door's flight aiming at `LEVEL01D.004`; on `_C_163` the second
## footbridge's camera aimed 13 760 units below its block, the fall tilted
## the level's own geometry, and `aDeleteLand` deleted it into the save's
## `removed` list, where every load would delete it again. `_C_129` (24, 11)
## is the fixture's own case: a crush wall's `L041EA00` sharing a field with
## `LEVEL01D.016`.
func _check_clone_cells(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(WALL_MISSION)
	if loaded.is_empty():
		h.check("clones.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	if geometry.is_empty():
		h.check("clones.geometry", false, "geometry/%s.json"
			% DictRead.as_string(header["world_set"]))
		return
	var scenery: Scenery = Scenery.new()
	scenery.build(document, geometry, {})
	var _all: int = scenery.apply_all(world.terrain_snapshot())
	# The cell is found by what stands on it: a special object sharing a
	# field with a clone, which is what the shared-field case is.
	#
	# **The precondition is read off the scene and not off the search.**
	# [method Scenery.clones_on] answers from the index [method Scenery.build]
	# fills as it places them, and [method Scenery.instances_on] from the whole
	# cell, so neither is the function these checks are about. It used to ask
	# whether `instances_on` held more than `objects_on` plus the marker, which
	# is the same question as the first check below: reverting the exclusion in
	# `objects_on` made the *guard* fail first and took the five checks after
	# it out of the run with an early return, so the mutation that proves the
	# mechanism reported a missing fixture instead. Now a revert leaves this
	# passing and fails the seven checks below it by name --
	# `only_the_special_is_found`, `the_first_object_is_the_special`,
	# `origins_name_the_special`, `the_live_count_is_the_search_s_answer`,
	# `removal_takes_the_special_only`, `the_live_count_falls_with_the_removal`
	# and `the_removed_count_rises_with_it`.
	var shared: int = -1
	for cell: int in range(world.state.width * world.state.height):
		if scenery.clones_on(cell).is_empty():
			continue
		for node: Variant in scenery.instances_on(cell):
			var instance: Node3D = node
			if instance.name.begins_with(CLONE_SHARED_PROTOTYPE):
				shared = cell
				break
		if shared >= 0:
			break
	h.check("clones.fixture_has_a_shared_cell", shared >= 0,
		"a %s on the same field as a clone" % CLONE_SHARED_PROTOTYPE)
	if shared < 0:
		scenery.free()
		return
	var objects: Array = scenery.objects_on(shared)
	h.equal("clones.only_the_special_is_found", objects.size(), 1,
		"the search's table holds the wall and neither the marker nor the "
		+ "clone")
	var found: Node3D = objects[0]
	h.check("clones.the_first_object_is_the_special",
		found.name.begins_with(CLONE_SHARED_PROTOTYPE),
		"a set piece flies to %s" % found.name)
	var origins: Array[Vector3i] = scenery.object_origins(shared)
	h.equal("clones.origins_name_the_special", origins.size(), 1,
		"and the flight has one candidate, not the clone placed before it")
	var drawn: int = scenery.instances_on(shared).size()
	# The number a driven session reads (docs/92 section 7.16). It is the
	# search's own answer summed over the map, which is what makes it move
	# when a set piece frees a cell -- `built_count` counts the marker and the
	# clone too and is a constant for the life of a mission.
	var live: int = 0
	for cell: int in range(world.state.width * world.state.height):
		live += scenery.objects_on(cell).size()
	h.equal("clones.the_live_count_is_the_search_s_answer",
		scenery.object_count(), live,
		"and it is fewer than the %d built" % scenery.built_count())
	h.check("clones.the_live_count_is_under_the_built",
		scenery.object_count() < scenery.built_count(),
		"the lattice's markers and the scene's clones are built and are not "
		+ "objects")
	var _gone: int = scenery.remove_objects(shared)
	h.equal("clones.removal_takes_the_special_only",
		scenery.instances_on(shared).size(), drawn - 1,
		"`aDeleteLand` frees the object the search found; the clone and the "
		+ "marker are still drawn")
	h.equal("clones.the_live_count_falls_with_the_removal",
		scenery.object_count(), live - 1,
		"which is the one number outside the game that says so")
	h.equal("clones.the_removed_count_rises_with_it",
		scenery.removed_count(), 1, "and the cell is counted freed once")
	h.equal("clones.removal_is_the_whole_record",
		scenery.pose_record()["removed"], [shared],
		"and what the save carries is that cell, not the level's geometry")
	scenery.free()


## The load's own seam, end to end: what a mission save carries out of the
## picture and what [method SliceMain._resume_loaded_mission] puts back.
##
## Three things that lived only in the picture until 2026-09-06 and had no
## suite between them: the scenery's poses (an opened hatch, a freed cell),
## the camera -- the header has carried a `camera` field since the first
## save and every writer passed it empty, so nothing had ever come back
## through it -- and the **refusal** that makes the record whole. A set
## piece is frames of picture over a world `core` has already finished, so a
## save taken while one is on the queue would hold the fall's start and none
## of its end; the original cannot reach that state at all, its sequences
## running inside the command. The turn's own autosave is deferred rather
## than dropped, because *Undo last turn* is a promise about every turn.
func _check_resume_after_load(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(WALL_MISSION)
	if loaded.is_empty():
		h.check("resume.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	if geometry.is_empty():
		h.check("resume.geometry", false, "geometry/%s.json"
			% DictRead.as_string(header["world_set"]))
		return
	var played: Scenery = Scenery.new()
	played.build(document, geometry, {})
	var _all: int = played.apply_all(world.terrain_snapshot())
	var walls: PackedInt32Array = played.cells_with_prototype(WALL_PROTOTYPE)
	var tubes: PackedInt32Array = played.cells_with_prototype(TUBE_PROTOTYPE)
	if walls.is_empty() or tubes.is_empty():
		h.check("resume.fixture_has_a_wall_and_a_tube", false,
			"%d wall(s), %d tube(s) on %s"
				% [walls.size(), tubes.size(), WALL_MISSION])
		played.free()
		return
	var wall: int = walls[0]
	var tube: int = tubes[0]
	var open: Vector3i = Vector3i(
		SetpieceDriver.TUBE_STEP * SetpieceDriver.TUBE_FRAMES, 0, 0)
	var _hatch: int = played.paint_joint(tube, SetpieceDriver.PART_FIRST, open)
	var _gone: int = played.remove_objects(wall)

	var rig: CameraRig = CameraRig.new()
	rig.set_now(SAVED_EYE, SAVED_TARGET)
	var host: CampaignHost = CampaignHost.create(CacheFixture.cache_dir(),
		CacheFixture.balance(), Localization.new())
	host.save_dir = RESUME_SCRATCH
	# **The corner is emptied first.** The refusal below is checked by the
	# slot file *not* being there, and nothing wipes `user://` between runs
	# -- so a second run would read the first run's file and call the
	# deferral broken.
	for slot: int in [RESUME_SLOT, HudTables.SLOT_UNDO_TURN]:
		var stale: String = ProjectSettings.globalize_path(host.slot_path(slot))
		if FileAccess.file_exists(stale):
			var _removed: Error = DirAccess.remove_absolute(stale)
	var _started: CampaignState = host.start_new(1, 1)
	var main: SliceMain = SliceMain.new()
	main.world = world
	main.campaign = host
	main._scenery = played
	main._rig = rig
	main._sequences = SequenceQueue.create(null)

	# --- what a save carries ---------------------------------------------
	# **The writer records what it wrote.** The ownership cache is read once
	# per slot and remembered, so a slot written without recording keeps
	# whatever header was on disk when the interface first asked -- which
	# left *Recall position* dark right after `F1` had written it, in a real
	# build (docs/92 section 7.16). The cache is **poisoned first**, because
	# a miss would read the header this save is about to write and pass
	# either way.
	main._slot_owner[RESUME_SLOT] = "_C_XXX"
	h.check("resume.saved", main._save_mission_to(RESUME_SLOT, world),
		"the mission blob, its poses and its camera into slot 0")
	h.check("resume.the_slot_knows_its_mission",
		main._slot_holds_this_mission(RESUME_SLOT),
		"the interface offers the slot it has just written, without "
		+ "re-reading the header it cached before the write")

	# --- and what it refuses ---------------------------------------------
	main._sequences.enqueue("crush_wall", 8, Callable())
	h.check("resume.mid_sequence", main._mid_sequence(),
		"a set piece on the queue")
	h.check("resume.save_is_refused_mid_sequence",
		not main._save_mission_to(RESUME_SLOT + 1, world),
		"`core` has finished, the picture has not -- and the record would "
		+ "hold the fall's start with none of its end")
	main._autosave(HudTables.SLOT_UNDO_TURN)
	h.check("resume.autosave_waits_rather_than_writing",
		not host.has_save(HudTables.SLOT_UNDO_TURN),
		"the turn's own save is deferred, not taken half way")
	main._sequences.skip()
	h.check("resume.queue_drains", not main._mid_sequence())
	main._flush_autosaves()
	h.check("resume.autosave_lands_when_the_queue_drains",
		host.has_save(HudTables.SLOT_UNDO_TURN),
		"*Undo last turn* is a promise about every turn")

	# --- and what a load puts back ---------------------------------------
	var decoded: Dictionary = host.load_save(RESUME_SLOT)
	h.equal("resume.slot_reads_back",
		CampaignCodec.result_name(DictRead.as_int(decoded["result"])), "OK")
	var blob: PackedByteArray = DictRead.to_bytes(decoded["mission"])
	var again: Dictionary = CacheFixture.load_world(WALL_MISSION)
	var fresh: World = again["world"]
	h.equal("resume.mission_reads_back",
		SaveCodec.result_name(fresh.load_save(blob)), "OK")
	var resumed: Scenery = Scenery.new()
	resumed.build(document, geometry, {})
	var _placed: int = resumed.apply_all(fresh.terrain_snapshot())
	var back_rig: CameraRig = CameraRig.new()
	var loader: SliceMain = SliceMain.new()
	loader.world = fresh
	loader._scenery = resumed
	loader._rig = back_rig

	# **The mirror `_build` took is thrown away before the terrain is
	# redrawn.** The picture reads [method SliceMain.shown] and not the
	# truth (docs/100), and the clone `_build` takes describes the mission
	# as the `.lev` authored it -- [method World.load_save] then moves the
	# truth with no delta anybody can replay. Redrawing against that clone
	# compares the authored terrain with itself, finds nothing changed and
	# moves nothing: `_C_115` came back from a slot with its lift 44 steps
	# up in the state, the deck drawn at the bottom and its rider standing
	# on air. The lift is **staged** here rather than ridden -- what the
	# defect needs is a save whose height the authored map does not have.
	var deck: Node3D = null
	for node: Variant in resumed.objects_on(tube):
		deck = node
		break
	var was_at: Vector3 = deck.transform.origin if deck != null else Vector3.ZERO
	var overlay: TerrainOverlay = TerrainOverlay.new()
	loader._overlay = overlay
	loader._shown = fresh.clone()
	loader._drawn_terrain = loader._shown.terrain_snapshot()
	overlay.build(loader._drawn_terrain)
	fresh.state.set_height(tube, fresh.state.height_at(tube) + LIFT_RISE)

	loader._resume_loaded_mission()
	h.check("resume.mirror_is_not_the_one_the_build_took",
		loader.shown().canonical_hash_hex() == fresh.canonical_hash_hex(),
		"the picture reads the loaded world and not `_build`'s clone")
	h.check("resume.a_lifted_cell_carries_its_objects_up",
		deck != null and (deck.transform.origin - was_at).is_equal_approx(
			WorldSpace.to_godot(0, 0, LIFT_RISE)),
		"the deck under the save's rider, moved by the height the save "
		+ "carries rather than left where the `.lev` authored it")
	h.equal("resume.hatch_is_open_again",
		resumed.joint_of(tube, SetpieceDriver.PART_FIRST), open,
		"the poses come back through the save rather than being authored")
	h.check("resume.wall_is_gone_again",
		resumed.objects_on(wall).is_empty() and resumed.removed_count() == 1)
	h.equal("resume.camera_is_where_it_was",
		[back_rig.eye_goal(), back_rig.target_goal()],
		[SAVED_EYE, SAVED_TARGET],
		"the header's camera field, read at last")
	# A save written before the field was filled -- and every save the
	# campaign container holds without a mission -- leaves the built
	# mission's own view rather than snapping to the origin.
	var untouched: CameraRig = CameraRig.new()
	untouched.set_now(SAVED_EYE, SAVED_TARGET)
	untouched.apply_state({})
	h.equal("resume.empty_camera_moves_nothing",
		[untouched.eye_goal(), untouched.target_goal()],
		[SAVED_EYE, SAVED_TARGET])

	played.free()
	resumed.free()
	overlay.free()
	rig.free()
	back_rig.free()
	untouched.free()
	main.free()
	loader.free()


## The lever's handle on `_C_115`: L109EX00's one part, up at zero, thrown
## at -800 -- and the thrown pose is a function of the cell's action point,
## as the door's leaves are of its parity.
func _check_family_lever(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(LEVER_MISSION)
	if loaded.is_empty():
		h.check("family.lever.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	if geometry.is_empty():
		h.check("family.lever.geometry", false, "geometry/%s.json"
			% DictRead.as_string(header["world_set"]))
		return
	var scenery: Scenery = Scenery.new()
	scenery.build(document, geometry, {})
	var _placed: int = scenery.apply_all(world.terrain_snapshot())
	var lever: int = _find_action_point(world, Interact.LEVER_UP)
	h.check("family.lever.present", lever >= 0,
		"a cell with action point %d on %s" % [Interact.LEVER_UP, LEVER_MISSION])
	if lever >= 0:
		h.check("family.lever.has_handle",
			scenery.has_joint(lever, Scenery.LEVER_PART),
			"the object on the cell carries part %d" % Scenery.LEVER_PART)
		h.equal("family.lever.ships_up",
			scenery.joint_of(lever, Scenery.LEVER_PART), Vector3i.ZERO,
			"action point 36 and a zero handle")
		var half: Vector3i = Vector3i(-SetpieceDriver.LEVER_STEP
			* (SetpieceDriver.LEVER_FRAMES / 2), 0, 0)
		h.equal("family.lever.paint_turns_one",
			scenery.paint_joint(lever, Scenery.LEVER_PART, half), 1)
		var objects: Array = scenery.objects_on(lever)
		var handle: Node3D = null
		if not objects.is_empty():
			var first_object: Node3D = objects[0]
			handle = scenery.pivot_of(first_object, Scenery.LEVER_PART)
		h.check("family.lever.halfway", handle != null
			and handle.basis.is_equal_approx(
				WorldSpace.joint_basis(half.x, 0, 0)),
			"the fifth frame is -400 about x")
		h.equal("family.lever.reads_back",
			scenery.joint_of(lever, Scenery.LEVER_PART), half,
			"what was painted is what `joint_of` answers")
		var snapshot: Dictionary = world.terrain_snapshot()
		var only: PackedInt32Array = PackedInt32Array([lever])
		var points: PackedByteArray = snapshot["action_point"]
		points[lever] = Interact.LEVER_DOWN
		snapshot["action_point"] = points
		var _thrown: int = scenery.apply_state(snapshot, only)
		h.equal("family.lever.thrown_from_state",
			scenery.joint_of(lever, Scenery.LEVER_PART),
			Vector3i(-Scenery.LEVER_THROW, 0, 0),
			"action point 37 is the thrown handle")
		points[lever] = Interact.LEVER_UP
		snapshot["action_point"] = points
		var _up: int = scenery.apply_state(snapshot, only)
		h.equal("family.lever.up_from_state",
			scenery.joint_of(lever, Scenery.LEVER_PART), Vector3i.ZERO)
		# The driver's arm from a thrown state: the state paints the end of
		# the throw first, the arm still starts at the rest pose.
		points[lever] = Interact.LEVER_DOWN
		snapshot["action_point"] = points
		var _end: int = scenery.apply_state(snapshot, only)
		var throw: Dictionary = {"starts": {}}
		var _first: int = SetpieceDriver.paint_family(scenery, lever, "lever",
			PackedInt32Array([0, 0, 0]), 1, SetpieceDriver.LEVER_FRAMES, throw,
			RecordingHost.new())
		h.equal("family.lever.arm_starts_at_rest",
			scenery.joint_of(lever, Scenery.LEVER_PART),
			Vector3i(-SetpieceDriver.LEVER_STEP, 0, 0),
			"frame 1 of an up-to-down throw is -80, not -880")
		var _tenth: int = SetpieceDriver.paint_family(scenery, lever, "lever",
			PackedInt32Array([0, 0, 0]), SetpieceDriver.LEVER_FRAMES,
			SetpieceDriver.LEVER_FRAMES, throw, RecordingHost.new())
		h.equal("family.lever.arm_ends_thrown",
			scenery.joint_of(lever, Scenery.LEVER_PART),
			Vector3i(-Scenery.LEVER_THROW, 0, 0))
		h.equal("family.lever.throw_is_step_times_frames",
			Scenery.LEVER_THROW,
			SetpieceDriver.LEVER_STEP * SetpieceDriver.LEVER_FRAMES,
			"ten frames of 80")

	scenery.free()


func _find_action_point(world: World, ap: int) -> int:
	for index: int in range(world.state.cell_count()):
		if world.state.action_point_at(index) == ap:
			return index
	return -1


## How many mesh surfaces draw under a node -- its own and its parts'.
func _surfaces_under(node: Node) -> int:
	var total: int = 0
	var instance: MeshInstance3D = node as MeshInstance3D
	if instance != null and instance.mesh != null:
		total += instance.mesh.get_surface_count()
	for child: Node in node.get_children():
		total += _surfaces_under(child)
	return total


## The three weapon switches reach real effects with real kinds.
## The weapon whose impact reaches `aBlob_CreateShockWave`, and a tile for it.
const SHOCK_WAVE_WEAPON: int = 36
const SHOCK_WAVE_TILE: Vector2i = Vector2i(6, 2)


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
	# **The transcribed creator's own two shapes** (`inclib/blob_creators.py`
	# `_c004247C0`): the streak lives one frame per 2240 units of the wider
	# horizontal span, and the casing is thrown a **third of the round's delta
	# behind** the muzzle at the muzzle's own height -- backwards out of the
	# breech, where it used to start at the muzzle point itself.
	var streak: Blob = null
	var case: Blob = null
	for blob: Blob in pool.blobs():
		if blob.kind == 15:
			streak = blob
		elif blob.kind == BlobTriggers.CASING_KIND:
			case = blob
	h.check("triggers.tracer_and_casing", streak != null and case != null,
		"weapon 2's round is a streak and a case")
	if streak != null and case != null:
		h.equal("triggers.tracer_life", streak.life,
			(to.x - from.x) / BlobTriggers.TRACER_UNIT - 1,
			"max(|dx|, |dy|) / 2240 - 1, the reciprocal multiply's own answer")
		h.equal("triggers.tracer_carries_the_delta",
			Vector3i(streak.vx, streak.vy, streak.vz),
			Vector3i(streak.x, streak.y, streak.z) - from,
			"the round's offset from the muzzle is also its velocity")
		h.equal("triggers.casing_is_thrown_backwards",
			Vector3i(case.x, case.y, case.z),
			Vector3i(from.x - IncInt.div_trunc(streak.vx, 3),
				from.y - IncInt.div_trunc(streak.vy, 3), from.z),
			"a third of the delta behind, and at the muzzle's own height")
		h.check("triggers.casing_rises",
			case.vz >= BlobTriggers.CASING_RISE_BASE
				and case.vz <= BlobTriggers.CASING_RISE_BASE
					+ BlobTriggers.CASING_RISE_SPAN,
			"vz %d is 0x140 + aRandom2(0, 0xA0)" % case.vz)
	# **A shot is a burst.** `aBlob_CreateTracerBullet` takes a round count
	# and a stagger step as its fifth and sixth arguments and loops them, so
	# weapon 2's site pushing 10 is ten tracers and ten cases leaving one
	# frame apart -- not the one round this class made until the count was
	# read off the call site (`blob_tables.py` `MUZZLE_BURSTS`).
	var rounds: Vector2i = BlobTriggers.burst_at(
		triggers.bursts("weapon_muzzle", 2), 0)
	h.equal("triggers.burst_rounds", rounds, Vector2i(10, 1),
		"weapon 2's call site pushes ten rounds one frame apart")
	var streaks: Array[int] = []
	var cases: Array[int] = []
	for blob: Blob in pool.blobs():
		if blob.kind == 15:
			streaks.append(blob.delay)
		elif blob.kind == BlobTriggers.CASING_KIND:
			cases.append(blob.delay)
	streaks.sort()
	cases.sort()
	var want_delays: Array[int] = []
	for i: int in range(rounds.x):
		want_delays.append(i * rounds.y)
	h.equal("triggers.burst_streaks", streaks, want_delays,
		"one streak per round, delayed by its own index")
	h.equal("triggers.burst_cases", cases, want_delays,
		"and one case beside it")
	# **Weapon 12 has two barrels.** Its arm calls the tracer creator twice,
	# and the second call names the part `"MM"` where every other site names
	# `"M"` -- so a shooter whose model carries both fires the two bursts
	# from two places, and one whose model carries neither fires both from
	# the body's axis.
	var twelve: Array = triggers.joints("weapon_muzzle", 12)
	h.equal("triggers.joint_names", twelve, ["M", "MM"],
		"weapon 12's two call sites name two different parts")
	h.equal("triggers.joint_default",
		triggers.joints("weapon_muzzle", 60), ["M"],
		"and the default arm names the muzzle like the rest")
	h.equal("triggers.joint_none", triggers.joints("weapon_muzzle", 17),
		["", "", "", ""],
		"a creator of any other arity pushes no part name at all")
	pool.clear()
	# A field apart, and each case is scored against the **nearer** barrel:
	# the round's own scatter is hundreds of units wide, so a fixed radius
	# around one of them would catch the other's rounds too.
	var barrel_one: Vector3i = from + Vector3i(
		MapResource.WORLD_UNITS_PER_FIELD, 0, 0)
	var barrel_two: Vector3i = from - Vector3i(
		MapResource.WORLD_UNITS_PER_FIELD, 0, 0)
	var placed: Dictionary[String, Vector3i] = {
		"M": barrel_one, "MM": barrel_two}
	var _both: int = triggers.muzzle(12, from, to, placed)
	var first: int = 0
	var second: int = 0
	for blob: Blob in pool.blobs():
		if blob.kind != BlobTriggers.CASING_KIND:
			continue
		if absi(blob.x - barrel_one.x) <= absi(blob.x - barrel_two.x):
			first += 1
		else:
			second += 1
	h.equal("triggers.two_barrels", [first, second], [9, 9],
		"nine cases from each of weapon 12's two bursts")
	pool.clear()
	var _again: int = triggers.muzzle(2, from, to)
	# **The other two burst creators.** Weapon 16's needles are nine sprites a
	# round down the round's own delta, and its constructor call computes its
	# kind -- so before `aBlob_CreateNeedles` was transcribed the table said
	# `null` and the weapon made **no muzzle effect at all**. Weapon 29's
	# flash is one sprite a round.
	pool.clear()
	var _needles: int = triggers.muzzle(16, from, to)
	var last: int = 0
	var body: int = 0
	var seen: Dictionary[Vector3i, bool] = {}
	for blob: Blob in pool.blobs():
		if blob.kind == BlobTriggers.NEEDLE_KIND_LAST:
			last += 1
		elif blob.kind == BlobTriggers.NEEDLE_KIND:
			body += 1
		seen[Vector3i(blob.x, blob.y, blob.z)] = true
	h.equal("triggers.needles", [last, body], [3, 24],
		"three rounds of nine, one of each nine ending the streak")
	h.equal("triggers.needles_are_apart", seen.size(), 27,
		"and no two of the twenty-seven share a position")
	pool.clear()
	var _flashes: int = triggers.muzzle(29, from, to)
	var flashes: int = 0
	for blob: Blob in pool.blobs():
		if blob.kind == 69:
			flashes += 1
	h.equal("triggers.flashes", flashes, 10,
		"weapon 29's ten rounds are ten sprites")
	pool.clear()
	var _restore: int = triggers.muzzle(2, from, to)
	# **The nested creators a burst asks for.** The tracer makes a zoom bob a
	# fifth of every round's delta along, and point-blank the other two make
	# theirs at the *target* instead of the records the round loop builds --
	# which the constructor table cannot carry either way, so they come back
	# as requests for [BlobPrograms].
	pool.clear()
	var _ten: int = triggers.muzzle(2, from, to)
	var asked: Array[Dictionary] = triggers.take_programs()
	h.equal("triggers.tracer_asks_for_a_bob", asked.size(), 10,
		"one zoom bob a round, and only through the program seam")
	h.equal("triggers.and_the_list_is_taken_once",
		triggers.take_programs().size(), 0)
	pool.clear()
	var close: Vector3i = BlobTriggers.muzzle_point(2, 2, 0)
	var _point_blank: int = triggers.muzzle(29, from, close)
	var flash_asks: Array[Dictionary] = triggers.take_programs()
	h.equal("triggers.flash_point_blank", flash_asks.size(), 10,
		"ten rounds inside one spacing are ten bobs at the target")
	var close_flashes: int = 0
	for blob: Blob in pool.blobs():
		if blob.kind == 69:
			close_flashes += 1
	h.equal("triggers.flash_point_blank_drops_its_sprites", close_flashes, 0,
		"and every sprite the round loop built is dropped for a zero life")
	pool.clear()
	var _needles_close: int = triggers.muzzle(16, from, close)
	var needle_asks: Array[Dictionary] = triggers.take_programs()
	var wanted: Array[String] = []
	for request: Dictionary in needle_asks:
		wanted.append(DictRead.as_string(request["creator"]))
	h.equal("triggers.needles_point_blank", wanted,
		[BlobPrograms.ZOOMBOB, BlobPrograms.PLASMA_SPARKS_BURST],
		"a bob and the plasma burst, once for the whole call")
	# **The flag a burst creator writes, which is not "did it make anything".**
	# `cmp steps, 0 / jle` opens all three burst creators: a flight writes 0
	# and the point-blank arm writes **1** before it fills the pool at the
	# target (`0x00424AC3`, `0x0042420D`, `0x0042456A` -- docs/42 section 4.6).
	# A shot that waited on an empty pool instead sat out the whole hundred
	# frames of `ShotSequence.WAIT_FRAMES` on every adjacent target.
	h.equal("triggers.arrived_write_point_blank", triggers.arrived_write(), 1,
		"nothing is in flight, even though the burst made %d record(s)"
			% pool.in_use())
	h.check("triggers.point_blank_still_fills_the_pool",
		not needle_asks.is_empty(),
		"which is why `made == 0` could never be the test")
	pool.clear()
	var _far: int = triggers.muzzle(16, from, to)
	var _far_drain: Array[Dictionary] = triggers.take_programs()
	h.equal("triggers.arrived_write_in_flight", triggers.arrived_write(), 0,
		"a round that has to cross four fields is waited for")
	pool.clear()
	var _no_burst: int = triggers.muzzle(8, from, to)
	var _no_burst_drain: Array[Dictionary] = triggers.take_programs()
	h.equal("triggers.arrived_unwritten_without_a_burst",
		triggers.arrived_write(), BlobTriggers.ARRIVED_UNWRITTEN,
		"the mine thrower's grenade is not one of the three burst creators")

	# **The Cy'Coo's spore round** -- `aBlob_CreateSporeCannon` `0x004268B0`,
	# the fourth creator transcribed in [BlobTriggers] rather than replayed
	# out of the constructor table. Its one call carries `life: null`, so the
	# round used to take [constant BlobTriggers.DEFAULT_LIFE] and a velocity
	# paced to it -- a flat line that then sagged under kind 22's own `0x50` a
	# tick, where the original lobs it.
	pool.clear()
	h.equal("spore.weapon_25_creator", triggers.creators("weapon_muzzle", 25),
		[BlobTriggers.SPORE_CREATOR],
		"the muzzle switch names one creator for weapon 25")
	var lobbed: int = triggers.muzzle(25, from, to)
	h.equal("spore.one_round", lobbed, 1, "one record for the whole call")
	var round_life: int = IncInt.div_trunc(to.x - from.x,
		BlobTriggers.SPORE_UNIT) - BlobTriggers.SPORE_LIFE_BIAS
	var spore: Blob = pool.blobs()[0]
	h.equal("spore.kind", spore.kind, 0x16,
		"kind 22, the one arm that spawns spore sparks as it flies")
	h.equal("spore.life", spore.life, round_life,
		"`max(|dx|, |dy|) / 800 - 2`, the reciprocal multiply at 0x00426A73")
	h.equal("spore.one_step_a_tick", Vector2i(spore.vx, spore.vy),
		Vector2i(BlobTriggers.SPORE_SPEED, 0),
		"the direction service's ratios times the double at 0x004B12C8")
	h.equal("spore.starts_one_step_along",
		Vector3i(spore.x, spore.y, spore.z),
		from + Vector3i(BlobTriggers.SPORE_SPEED, 0, 0),
		"the record sits at the source plus the step, not at the source")
	h.equal("spore.loft", spore.vz,
		BlobTriggers.SPORE_LOFT * IncInt.div_trunc(round_life, 2),
		"`0x50 * (life / 2)` up at launch against `0x50` a tick down")
	h.equal("spore.arrived_write_in_flight", triggers.arrived_write(), 0,
		"the creator's own write over 0x004FE63C at 0x00426A97")
	h.check("spore.in_flight", triggers.in_flight(),
		"and the round is what the shot's flight stage waits for")
	# The arc itself, stepped: it rises for half its life and comes back.
	var peak: int = spore.z
	var flown: int = 0
	while triggers.in_flight() and flown < 200:
		var _stepped: Array[BlobKinds.TickResult] = pool.tick_all()
		flown += 1
		peak = maxi(peak, spore.z)
	h.equal("spore.flies_its_whole_life", flown, round_life + 1,
		"%d moves, and the tick after them finds `life` at zero" % round_life)
	h.check("spore.arcs_over_the_line", peak > from.z + BlobTriggers.SPORE_UNIT,
		"%d against the muzzle's %d: a lob, not a flat line" % [peak, from.z])
	h.check("spore.and_comes_back_down", spore.z < peak,
		"%d at the end of its life" % spore.z)
	h.check("spore.gone_is_not_in_flight", not triggers.in_flight(),
		"which is what ends the flight stage for a round nothing signals for")
	# **And it is not the pool being empty.** Kind 22 spawns sparks every tick
	# and they outlive the round, so `pool_live() == 0` could never be the
	# test -- which is why the records are held by reference here.
	var _later: int = pool.create_blob({"kind": 0x17, "class_id": 2,
		"life": 16, "x": to.x, "y": to.y, "z": to.z})
	h.check("spore.a_later_record_is_not_the_round",
		not triggers.in_flight() and pool.live() > 0,
		"%d record(s) in the pool, none of them the muzzle's" % pool.live())
	# Point-blank is the **same tile** here and not an adjacent one: the spore
	# step is a quarter of a map field, so even a neighbour is four steps off
	# and the round is made. `close` is the muzzle's own cell.
	pool.clear()
	var _same_cell: int = triggers.muzzle(25, from, close)
	h.equal("spore.point_blank_makes_nothing", pool.in_use(), 0,
		"a life of -2 aborts the constructor before it allocates")
	h.equal("spore.point_blank_arrived_write", triggers.arrived_write(), 1,
		"`(life <= 0) ? 1 : 0`, so there is nothing to wait for")
	h.check("spore.point_blank_is_not_in_flight", not triggers.in_flight())
	# And the decision the muzzle stage makes out of it, which is the four
	# lines that used to sit inside `SliceMain.ShotHost` where nothing could
	# reach them.
	h.check("arrived.point_blank_does_not_wait",
		ShotSequence.arrived_after_muzzle(true, 1, 12, false),
		"the creator said there is nothing in flight, whatever it then made")
	h.check("arrived.a_round_in_flight_is_waited_for",
		not ShotSequence.arrived_after_muzzle(true, 0, 12, false),
		"and this is the case the hundred frames exist for")
	h.check("arrived.a_creators_zero_beats_an_empty_pool",
		not ShotSequence.arrived_after_muzzle(true, 0, 0, false),
		"a creator that wrote is not second-guessed by the record count")
	h.check("arrived.nothing_made_is_not_waited_for",
		ShotSequence.arrived_after_muzzle(true,
			BlobTriggers.ARRIVED_UNWRITTEN, 0, false),
		"a refusal of the remake's own is not a round in flight")
	h.check("arrived.a_full_pool_still_waits",
		not ShotSequence.arrived_after_muzzle(true,
			BlobTriggers.ARRIVED_UNWRITTEN, 0, true),
		"the engine leaves the flag down there too")
	h.check("arrived.a_weapon_that_skips_the_wait_never_looks",
		ShotSequence.arrived_after_muzzle(false, 0, 12, false),
		"its muzzle arm writes 0 over the wait flag instead")
	pool.clear()
	var _back: int = triggers.muzzle(2, from, to)
	var _drain: Array[Dictionary] = triggers.take_programs()
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
	h.check("triggers.pooled", pool.in_use() > 0,
		"%d blob(s) in the pool" % pool.in_use())
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
	# Two records a round, and the default arm's site pushes five rounds.
	h.equal("triggers.out_of_range", triggers.muzzle(60, from, to), 10,
		"the switch's default arm, the same creator weapon 2 uses")
	h.equal("triggers.starting_guns", triggers.muzzle(0, from, to), 10,
		"the Light Combat Gun is not a gun with no muzzle flash")
	# The impact switch's default makes no blob, and that **is** the engine:
	# `0x0040DA07` goes straight on to the unit sweep.
	h.equal("triggers.impact_default", triggers.impact(0, to), 0,
		"weapons below the impact table's first id have no impact effect")

	# **Every weapon in both switches, fired.** Weapon 36's impact and weapon
	# 17's muzzle reach `aBlob_CreateShockWave` `0x00422B80`, whose class
	# argument is a `push ebp` the function has just zeroed rather than an
	# immediate (docs/28 section 7.2). The document carried `null` there, and
	# narrowing it raised `Trying to return a value of type "Nil" from a
	# function whose return type is "int"` on every shot from those two --
	# a *runtime* error, which fails no check on its own. Both ends are swept
	# so a call the constructor table cannot read is caught by the run
	# (`run_tests.sh` makes the error text a failure) rather than by a player.
	var calls: Dictionary = DictRead.as_dict(document.get("calls", {}))
	var unread: int = 0
	for call: Variant in calls.values():
		if DictRead.as_dict(call)["class"] == null:
			unread += 1
	h.equal("triggers.call_classes_read", unread, 0,
		"all %d constructor calls carry a class the document could read"
			% calls.size())
	# **Weapon 36's impact is a request, not a record.** Its creator
	# `0x00422B80` places sixty blobs in a ring where its one pinned
	# constructor call describes a single static one, so it is a transcribed
	# creator asked for **by tile** (docs/28 section 7.2). Both halves are
	# checked: the request carries the tile and the type its call sites push,
	# and the constructor-table path made nothing beside it -- a record here
	# would be a sixty-first blob the engine never places.
	pool.clear()
	var before: int = pool.in_use()
	var shock_made: int = triggers.impact(SHOCK_WAVE_WEAPON, to,
		SHOCK_WAVE_TILE)
	var wave_asked: Array[Dictionary] = triggers.take_programs()
	var wave_requests: Array[Dictionary] = []
	for request: Dictionary in wave_asked:
		if DictRead.as_string(request["creator"]) \
				== BlobTriggers.SHOCK_WAVE_CREATOR:
			wave_requests.append(request)
	h.equal("triggers.shock_wave_is_asked_for", wave_requests.size(), 1)
	h.equal("triggers.shock_wave_asks_by_tile",
		DictRead.as_vector2i(wave_requests[0]["tile"]), SHOCK_WAVE_TILE)
	h.equal("triggers.shock_wave_type",
		DictRead.as_int32_array(wave_requests[0]["extra"]),
		PackedInt32Array([BlobTriggers.SHOCK_WAVE_TYPE]),
		"`0x0040CD3C` and `0x0040D7AC` both push it")
	# The switch's **other** creator still fires from the constructor table --
	# weapon 36's impact is the shock wave plus `aBlob_CreateFireExplosion` --
	# and what must not be there is a record of the shock wave's own kind: its
	# one pinned call is skipped, not made beside the ring.
	h.check("triggers.shock_wave_leaves_the_switch_alone",
		shock_made > 0 and pool.in_use() > before,
		"%d record(s) from the rest of weapon %d's impact"
			% [shock_made, SHOCK_WAVE_WEAPON])
	var wave_records: int = 0
	for blob: Blob in pool.blobs():
		if blob != null and blob.alive \
				and blob.kind == BlobPrograms.SHOCKWAVE_KIND:
			wave_records += 1
	h.equal("triggers.shock_wave_makes_no_record", wave_records, 0,
		"the ring goes in through the program seam, not beside it")
	# With no tile there is nothing to place the ring on, and the effect is
	# skipped rather than guessed at.
	pool.clear()
	var _tileless: int = triggers.impact(SHOCK_WAVE_WEAPON, to)
	h.equal("triggers.shock_wave_needs_a_tile",
		triggers.take_programs().size(), 0)

	var swept: int = 0
	for weapon_key: Variant in DictRead.as_dict(
			document.get("weapon_muzzle", {})):
		pool.clear()
		var _muzzled: int = triggers.muzzle(
			DictRead.as_string(weapon_key).to_int(), from, to)
		var _asked: Array[Dictionary] = triggers.take_programs()
		swept += 1
	for weapon_key: Variant in DictRead.as_dict(
			document.get("weapon_impact", {})):
		pool.clear()
		var _hit: int = triggers.impact(
			DictRead.as_string(weapon_key).to_int(), to)
		swept += 1
	h.check("triggers.every_weapon_fires", swept > 0,
		"%d weapon arms fired, none of them a runtime error" % swept)
	pool.clear()

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
	# What the footbridge events carry past their arguments: the riders'
	# slots, and for `FootBridge2` the group's cells first (docs/42 section
	# 8.3). The block stands on one of those cells, never at `(112, 30)`.
	var bridge2: Dictionary = {"name": "foot_bridge2",
		"values": [112, 30, 2, 16, 10, 16, 11, 7]}
	h.equal("setpiece.foot_bridge2_cell", SetpieceDriver.cell_of(bridge2),
		Vector2i(16, 10), "the first group cell, not the group and the frames")
	var want_group: Array[Vector2i] = [Vector2i(16, 10), Vector2i(16, 11)]
	h.equal("setpiece.foot_bridge2_group", SetpieceDriver.group_cells(bridge2),
		want_group)
	h.equal("setpiece.foot_bridge2_riders", SetpieceDriver.riders_of(bridge2),
		PackedInt32Array([7]))
	h.equal("setpiece.foot_bridge2_bare_cell", SetpieceDriver.cell_of(
		{"name": "foot_bridge2", "values": [112, 30, 0]}), Vector2i(-1, -1),
		"a group nothing matched names no cell")
	var bridge: Dictionary = {"name": "foot_bridge", "values": [4, 4, 30, 2, 0, 1]}
	h.equal("setpiece.foot_bridge_cell", SetpieceDriver.cell_of(bridge),
		Vector2i(4, 4))
	h.equal("setpiece.foot_bridge_riders", SetpieceDriver.riders_of(bridge),
		PackedInt32Array([0, 1]))
	h.equal("setpiece.no_riders_elsewhere", SetpieceDriver.riders_of(
		{"name": "open_tube", "values": [20, 22]}), PackedInt32Array())

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
	# The player's own two (docs/42 section 8.3): the lever's ten frames and
	# the supply box's twenty of lid plus fifteen of hold.
	h.equal("setpiece.lever", SetpieceDriver.frames_for(
		{"name": "lever", "values": [3, 3, 0]}), 10,
		"`mov dword [esp+0x34], 0xA` in 0x00416AD0")
	h.equal("setpiece.pickup", SetpieceDriver.frames_for(
		{"name": "pickup", "values": [3, 3]}), 20 + 15,
		"`mov ebx, 0x14` then `mov esi, 0xF` in 0x00410780")
	# The handle's pose is a function of the direction and the frame, never
	# of what the object shows: `core` has flipped the action point before
	# the first frame, so a start read off the scenery is the end of the
	# throw and the handle would run a whole throw past it.
	h.equal("setpiece.lever_pose",
		[SetpieceDriver.lever_pose(0, 0), SetpieceDriver.lever_pose(0, 5),
			SetpieceDriver.lever_pose(0, 10), SetpieceDriver.lever_pose(1, 0),
			SetpieceDriver.lever_pose(1, 10), SetpieceDriver.lever_pose(0, 99)],
		[0, -400, -800, -800, 0, -800],
		"up goes 0 to -800, down goes -800 back to 0, and the frame is clamped")
	h.equal("setpiece.lever_throw", SetpieceDriver.LEVER_THROW,
		Scenery.LEVER_THROW, "the driver and the scenery agree on the throw")
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
## A shot whose round raises nothing -- the Cy'Coo's spore cannon.
##
## `pool_arrived` never comes up, because kind 22 is not one of the fourteen
## update arms that write `0x004FE63C`, and the pool is not empty either: the
## round spawns sparks every tick that outlive it. What ends the flight is the
## muzzle's own record being gone, and this counts the frames it takes.
class SilentRoundHost extends RecordingHost:
	## Frames the round is in the air for; any number the bound is well above.
	const ROUND_FRAMES: int = 12
	var left: int = ROUND_FRAMES

	func pool_arrived() -> bool:
		return false

	func muzzle_in_flight() -> bool:
		if left > 0:
			left -= 1
			return true
		return false


## Its own class rather than fields on [RecordingHost]: the shot suites drive
## `pool_arrived` as a countdown and would answer a raised flag on every frame
## of the bomb run, which is one crump a frame.
class BombRunHost extends RecordingHost:
	var flag: bool = false
	var records: int = 0
	## Where the pool's first live record stands. High enough that the bomb
	## run's own ceiling (`cmp eax, 0x1F40`) is a clamp and not a no-op, and
	## movable so a frozen camera can be told from a tracking one.
	var first: Vector3i = Vector3i(1600, 3200, 48000)
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

	func pool_first() -> Vector3i:
		return first

	## The buffers `play_cues_slots` has handed out, and which still sound.
	## A test clears an entry to let the run play into that buffer again.
	var busy: Dictionary[int, bool] = {}
	var _next_slot: int = 0

	func play_cues_slots(cues: Array[Dictionary]) -> PackedInt32Array:
		play_cues(cues)
		var slot: int = _next_slot
		_next_slot += 1
		busy[slot] = true
		return PackedInt32Array([slot])

	func sound_playing(slot: int) -> bool:
		return busy.get(slot, false)

	## One bomb reaching the ground.
	func land() -> void:
		if records > 0:
			records -= 1
		flag = true


## docs/21 section 6 -- the three `special` 1 guns, the bayonet one of them
## swaps to, and the clip its key names. Written out rather than read off the
## cache: what is being checked is that the seam reaches the selector at all.
const BAYONET_GUNS: Array[int] = [1, 2, 16]
const BAYONET_WEAPON: int = 30
const BAYONET_CLIP: String = "P0_F1_001"


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
	var inserted: Array[String] = []
	var texts: Array[String] = []
	var captions: Array[String] = []

	## The presented weapon of every shot the double was asked to play, so a
	## suite can check that a stab is drawn as a stab (docs/21 section 6).
	var fired_weapons: Array[int] = []

	func body_frames(_slot: int, _weapon: int = -1) -> Dictionary:
		return frames

	func fire_body(_slot: int, _tx: int, _ty: int,
			weapon: int = -1) -> Dictionary:
		calls.append("fire")
		fired_weapons.append(weapon)
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

	func muzzle(_weapon: int, _sx: int, _sy: int, _tx: int, _ty: int,
			_shooter: int = -1) -> void:
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

	func insert_object(model: String, at: Vector3i, yaw: int = 0) -> bool:
		inserted.append("%s:%d,%d,%d,%d" % [model, at.x, at.y, at.z, yaw])
		return true

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
	# **A bayonet kill's death effect.** `docs/42` section 4.8: weapons 30, 31
	# and 32 leave death style 3, so a small non-machine victim gets
	# `death_blood_burst` and not the species burst a rifle leaves. It is a
	# quieter effect on purpose -- thirty `A_BLUT4` pieces and no body parts --
	# but it is not nothing, which is what this pins.
	var gore: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var gore_draws: BlobPrograms.Draws = BlobPrograms.Draws.create(1.0)
	inputs.models["A_BLUT4.3DI"] = 4
	# The victim is the **computer's**, which is what the level-2 gore rule
	# turns on: at that level a unit of the player's own is substituted by the
	# puff and only the computer's bleed (docs/42 section 4.8).
	inputs.tiles[Vector2i(2, 2)] = {"object": Vector3i(6400, 6400, 0),
		"unit": {"type": 0, "player": BlobPrograms.PLAYER_COMPUTER,
			"height": 2880}}
	var _burst: bool = BlobPrograms.run(BlobPrograms.BLOOD_BURST, gore,
		gore_draws, PackedInt32Array([2, 2]), inputs)
	h.equal("stab.the_death_leaves_thirty_records", gore.records.size(), 30,
		"fifteen pairs of A_BLUT4, docs/42 section 4.8.1")
	var gore_kinds: Dictionary[int, int] = {}
	for record: Dictionary in gore.records:
		var k: int = DictRead.as_int(record["kind"])
		gore_kinds[k] = DictRead.as_int(gore_kinds.get(k, 0)) + 1
	h.equal("stab.the_death_is_kinds_17_and_43", gore_kinds, {17: 15, 43: 15})
	# And the level-2 substitution, which is the one way this arm answers with
	# nothing much: the player's own casualty gets the single-record puff.
	inputs.tiles[Vector2i(2, 2)] = {"object": Vector3i(6400, 6400, 0),
		"unit": {"type": 0, "player": 0, "height": 2880}}
	var own_death: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var _puff: bool = BlobPrograms.run(BlobPrograms.BLOOD_BURST, own_death,
		BlobPrograms.Draws.create(1.0), PackedInt32Array([2, 2]), inputs)
	h.equal("stab.the_players_own_casualty_is_a_puff",
		own_death.records.size(), 1,
		"gore level 2 substitutes it, and 2 is the shipped default")
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
	# The shot's own weapon reaches the body, not only the muzzle: the clip
	# stage sizes itself from it and starts it with it, which is how a stab
	# is drawn as a stab (docs/21 section 6).
	h.equal("stages.the_body_is_fired_with_the_shots_weapon",
		host.fired_weapons, [2])
	h.check("stages.waited_for_the_round", frames > 6 + 3 + 2 + 1,
		"%d frame(s): the flight stage waited for the flag" % frames)

	# **A shooter with no fight clip.** A type whose Charisma model or clip
	# the cache does not carry answers zero for all three counts, and the
	# whole shot then collapsed into about three frames -- the target vanished
	# with no attack visible. The floor is [constant
	# ShotSequence.NO_CLIP_FRAMES].
	var clipless: RecordingHost = RecordingHost.new()
	clipless.frames = {"to_break": 0, "spin": 0, "after_break": 0}
	var slow: SequenceQueue = SequenceQueue.create(null)
	var floored: int = ShotSequence.enqueue(slow, clipless, shot)
	h.equal("stages.no_clip_floor", floored,
		ShotSequence.NO_CLIP_FRAMES + 1 + 1,
		"the clip stage takes the floor, the muzzle and the impact one each")
	while slow.is_running() and slow.current() != ShotSequence.STAGE_MUZZLE:
		var _running: bool = slow.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("stages.no_clip_clip_first", clipless.hidden,
		PackedInt32Array(), "nothing is hidden before the muzzle")

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

	# **A round nothing signals for.** Fourteen update arms raise
	# `0x004FE63C` and the spore cannon's kind 22 is not among them, so the
	# flag alone left weapon 25's shot sitting out the whole of
	# [constant ShotSequence.WAIT_FRAMES] -- five seconds of dead screen after
	# a round that had already landed. The stage ends on the round being gone
	# instead; the hundred stays as the bound it is.
	var silent_round: SilentRoundHost = SilentRoundHost.new()
	var lobbed: SequenceQueue = SequenceQueue.create(null)
	shot["weapon"] = 25
	var _lob_bound: int = ShotSequence.enqueue(lobbed, silent_round, shot)
	var flight_frames: int = 0
	frames = 0
	while lobbed.is_running() and frames < 1000:
		if lobbed.current() == ShotSequence.STAGE_FLIGHT:
			flight_frames += 1
		var _still: bool = lobbed.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.equal("stages.flight_ends_when_the_round_is_gone", flight_frames,
		SilentRoundHost.ROUND_FRAMES + 1,
		"the round's own frames and the one that finds it gone, against the "
		+ "%d the flag alone would have taken" % ShotSequence.WAIT_FRAMES)
	h.check("stages.flight_is_still_bounded",
		ShotSequence.WAIT_FRAMES == 100,
		"`cmp ecx, 0x64` at 0x0040D4C1 is untouched")

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

	# **The stab's clip, through the library.** `docs/21` section 6: the swap is
	# live while `aPlayFightAnimation` runs, so the shot's own weapon selects
	# the `F` clip and the record's does not. This is the seam between the note
	# and the body -- the selector's three arguments in their own order -- and
	# nothing else in the suites walks it.
	units.shown_ref = world
	var armed: int = -1
	for candidate: int in units.states:
		var record: Dictionary = world.unit_view(candidate)
		if not record.is_empty() and BAYONET_GUNS.has(
				DictRead.as_int(record["weapon"])):
			armed = candidate
			break
	h.check("stab.a_special_1_gun_is_on_the_map", armed >= 0,
		"one of %s" % str(BAYONET_GUNS))
	if armed >= 0:
		var own: CharismaClip = units.states[armed].fire_clip()
		var _sized: Dictionary = units.body_frames(armed, BAYONET_WEAPON)
		var stab: CharismaClip = units.states[armed].fire_clip()
		h.check("stab.the_clip_is_the_bayonets",
			stab != null and stab != own and stab.name == BAYONET_CLIP,
			"%s, not %s" % ["null" if stab == null else stab.name,
				"null" if own == null else own.name])
		var _back: Dictionary = units.body_frames(armed,
			DictRead.as_int(world.unit_view(armed)["weapon"]))
		h.equal("stab.the_gun_comes_back", units.states[armed].fire_clip(), own,
			"the unit's own weapon is not an override")

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

	# The blood pieces are single flat faces with a fixed authored direction.
	# A bayonet death emits thirty A_BLUT4 cards; if they keep the ordinary
	# model cull mode, all thirty disappear together from the back two camera
	# quadrants even though the pool and renderer counts are non-zero.
	var blood_placed: bool = models.place(2, "A_BLUT4.3DI",
		Vector3i.ZERO, [Vector3i.ZERO, Vector3i.ZERO, Vector3i.ZERO])
	var blood_node: Node3D = models._nodes[2] if models._nodes.has(2) else null
	var blood_body: MeshInstance3D = null
	if blood_node != null:
		blood_body = blood_node.get_node_or_null(MeshBuilder.BODY_NODE) \
			as MeshInstance3D
	var blood_material: StandardMaterial3D = null
	if blood_body != null and blood_body.mesh != null \
			and blood_body.mesh.get_surface_count() > 0:
		blood_material = blood_body.mesh.surface_get_material(0) \
			as StandardMaterial3D
	h.check("models.blood_card_is_built", blood_placed
		and blood_material != null, "A_BLUT4 must reach an actual mesh surface")
	h.equal("models.blood_card_visible_from_both_camera_sides",
		blood_material.cull_mode if blood_material != null else -1,
		BaseMaterial3D.CULL_DISABLED,
		"the thirty-record stab effect must not render as an empty death")
	pool.clear()
	h.equal("models.cleared", models.rebuild(pool), 0)
	models.free()
	_check_special_objects(h, prototypes)
	_check_victory_markers(h, prototypes)


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


## docs/42 section 9.3 -- the marker `0x00431E30` stands on a victory-point
## cell: in `core` a slot of the 80-entry array taken after the cells' own
## objects, in the picture a static `A_MK_*` object at the cell's origin whose
## letter changes colour when a walk claims the cell. Until 2026-09-07 the
## remake drew none of them, and `_C_102`'s two target cells -- the red `A`
## the mission asks the squad to reach -- were bare floor.
func _check_victory_markers(h: TestHarness, prototypes: Dictionary) -> void:
	# The jump table's ten arms, by `action point - 0x50`.
	h.equal("vp.model_80_is_nobodys_A", MapState.victory_marker_model(80),
		"A_MK_0A.3DI")
	h.equal("vp.model_81_is_player_0s_A", MapState.victory_marker_model(81),
		"A_MK_1A.3DI")
	h.equal("vp.model_89_is_player_4s_B", MapState.victory_marker_model(89),
		"A_MK_4B.3DI")
	h.equal("vp.model_outside_the_band", MapState.victory_marker_model(70), "")
	h.equal("vp.ten_models", MapState.VICTORY_MARKER_MODELS.size(), 10)

	var world: World = TestFixtures.tiny_world()
	var state: MapState = world.state
	var a: int = state.index_of(1, 1)
	var b: int = state.index_of(2, 3)
	h.equal("vp.no_marker_without_a_victory_point",
		[state.marker_slot_at(a), state.object_state(0)],
		[MapState.NO_OBJECT, MapState.NO_OBJECT])
	state.set_action_point(a, 81)
	state.set_action_point(b, 85)
	state.rebuild_objects()
	h.equal("vp.markers_take_the_first_free_slots_in_cell_order",
		[state.marker_slot_at(a), state.marker_slot_at(b),
		state.object_state(0), state.object_state(1), state.object_state(2)],
		[0, 1, MapState.OBJECT_STATIC, MapState.OBJECT_STATIC, MapState.NO_OBJECT],
		"`push 5` at 0x00431F45, the slot written to +0x14 at 0x00431F74")
	var mine: int = CellObjects.place_mine(state, 4, 4)
	h.equal("vp.a_later_object_takes_the_slot_after_them", mine, 2)
	# A capture: `aExecuteMove` rewrites the action point and runs the placer
	# again, which frees the marker and takes the first free slot -- its own.
	state.set_action_point(a, 0x51 + 2)
	state.rebuild_markers()
	h.equal("vp.a_capture_keeps_the_slot",
		[state.marker_slot_at(a), state.marker_slot_at(b), state.object_state(2)],
		[0, 1, MapState.OBSTACLE_MINE],
		"aDeleteSpecialObject at 0x00431E8D, then the first free slot again")
	# A cell that stops being a victory point gets 0xFF at +0x14
	# (0x00431F79) and **nothing is freed** -- the engine's arm, not a choice.
	state.set_action_point(b, 0)
	state.rebuild_markers()
	h.equal("vp.a_cleared_cell_forgets_its_marker_and_frees_nothing",
		[state.marker_slot_at(b), state.object_state(1)],
		[MapState.NO_OBJECT, MapState.OBJECT_STATIC])
	# The clone the picture reads carries the slots too.
	var copy: MapState = state.clone()
	h.equal("vp.clone_carries_the_slots",
		[copy.marker_slot_at(a), copy.marker_slot_at(b)], [0, MapState.NO_OBJECT])

	# The picture: one static object per victory-point cell, at the cell's
	# origin, keyed by the cell and not by the slot -- the mirror gets the
	# claim as an action-point delta and nothing else.
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in prototypes:
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	var carried: int = 0
	for name: String in MapState.VICTORY_MARKER_MODELS:
		if prototypes.has(name):
			carried += 1
	h.equal("vp.fixture_carries_the_ten_models", carried, 10,
		"the converter asks for all ten in every world set (0.25.0)")
	var view: SpecialObjects = SpecialObjects.new()
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	view.setup(prototypes, {}, index, rng)
	state.set_action_point(b, 85)
	state.rebuild_markers()
	var touched: PackedInt32Array = view.sync(world.terrain_snapshot())
	h.check("vp.sync_sees_the_victory_points",
		touched.has(a) and touched.has(b), str(touched))
	h.equal("vp.two_markers_and_the_mine", view.live_count(), 3)
	h.equal("vp.all_of_them_draw", view.advance(), 3)
	var key: int = SpecialObjects.MARKER_KEY_BASE + a
	h.equal("vp.the_marker_is_static_at_the_origin",
		[DictRead.as_string(view._live[key]["model"]),
		DictRead.as_int(view._live[key]["state"]),
		DictRead.as_vector3i(view._live[key]["at"])],
		["A_MK_3A.3DI", MapState.OBJECT_STATIC,
		view.origin_of(world.terrain_snapshot(), a)])
	h.equal("vp.idle_sync_is_free", view.sync(world.terrain_snapshot()).size(), 0)
	# The claim repaints the one cell, through the action-point plane alone.
	state.set_action_point(a, 0x51)
	var repainted: PackedInt32Array = view.sync(world.terrain_snapshot())
	h.equal("vp.a_claim_repaints_its_cell", repainted, PackedInt32Array([a]))
	h.equal("vp.the_letter_changes_colour",
		DictRead.as_string(view._live[key]["model"]), "A_MK_1A.3DI")
	view.free()


## What stands for a unit with no Charisma body (docs/40 section 7.2.1: the
## selector writes nothing for player 0xFC): the type's own model column --
## `_C_140`'s barrels -- and not the fallback capsule, which stood on every
## barrel as a white dome until 2026-09-07. And nothing at all under a body:
## the grey `B` of `A_MK_0B`, the living types' model column, is a
## victory-point marker cell and the original draws none of it under a marine.
func _check_unit_stands(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(DOOR_MISSION)
	if loaded.is_empty():
		h.check("stands.fixture", false, "no cache")
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
	var barrels: int = 0
	var barrels_as_models: int = 0
	var capsules: int = 0
	var bodies: int = 0
	var bodies_with_a_marker: int = 0
	for slot: int in world.unit_slots():
		var node: Node3D = _node_of(units, slot)
		if node == null:
			continue
		var view: Dictionary = world.unit_view(slot)
		var has_model: bool = node.get_node_or_null("model") != null
		var has_capsule: bool = node.get_node_or_null("fallback_capsule") != null
		var has_marker: bool = node.get_node_or_null("marker") != null
		if DictRead.as_int(view["player"]) == Combat.PLAYER_NEUTRAL:
			barrels += 1
			if has_model:
				barrels_as_models += 1
			if has_capsule:
				capsules += 1
		elif units.bodies.has(slot):
			bodies += 1
			if has_marker or has_model:
				bodies_with_a_marker += 1
	h.check("stands.fixture_has_barrels_and_bodies", barrels > 0 and bodies > 0,
		"%d neutral, %d with a body" % [barrels, bodies])
	h.equal("stands.a_barrel_is_its_model_column", barrels_as_models, barrels,
		"A_BARAL*.3DI, drawn as the engine draws it")
	h.equal("stands.no_capsule_on_a_barrel", capsules, 0)
	h.equal("stands.nothing_under_a_body", bodies_with_a_marker, 0,
		"A_MK_0B is a marker atlas cell, not a footprint")
	h.check("stands.a_marker_model_is_recognised",
		UnitsView.is_marker_model("A_MK_0B.3DI")
			and not UnitsView.is_marker_model("A_BARAL1.3DI"), "the prefix")
	units.free()


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
	# A closed door's cell stands at 0xC80; the flight aims at the **panel**,
	# whose object is on the floor, and both ends take the panel's z
	# (`0x00410C1E`, `0x00410C35`: `[esi+0x18]` twice). Aiming at the cell's
	# height is what tipped the camera up at the lintel.
	var closed: RecordingHost = RecordingHost.new()
	closed.objects[3] = Vector3i(3200, 3200, 160)
	closed.heights[3] = 2880
	var closed_queue: SequenceQueue = SequenceQueue.create(null)
	var _closed: int = SetpieceCamera.enqueue(closed_queue, closed, "open_door",
		SetpieceDriver.DOOR_FRAMES, Vector2i(2, 1), 0xC80, 0, 3,
		{"object": Vector3i(6400, 3200, 0)}, paint, no_cues)
	var _closed_ran: Dictionary = _run_queue(closed_queue)
	h.equal("camera.door.eye_at_the_panel_z", closed.flights[0][0],
		Vector3i(3200, 3200, 2880),
		"the opener's x and y, the panel's z plus the unit's height")
	h.equal("camera.door.target_is_the_object", closed.flights[0][1],
		Vector3i(6400, 3200, 2880),
		"not the cell at its height, which would be 0xC80 higher")
	# The LCL wrapper names no unit: no flight at all.
	var lcl: RecordingHost = RecordingHost.new()
	var lcl_queue: SequenceQueue = SequenceQueue.create(null)
	var _lcl: int = SetpieceCamera.enqueue(lcl_queue, lcl, "open_door",
		SetpieceDriver.DOOR_FRAMES, Vector2i(2, 1), 0, 0xC80, -1, {}, paint,
		no_cues)
	var _lcl_ran: Dictionary = _run_queue(lcl_queue)
	h.equal("camera.door.no_unit_no_flight", lcl.flights.size(), 0,
		"the wrapper passes -1 and the routine skips its camera")

	# The lever (docs/42 section 8.3): the door's shape with both ends of
	# the flight `0xC80` above the **object's** own z, ten frames, the
	# flight back. `0x00416BC2` reads `[esi+0x10/0x14/0x18]` -- the object
	# `0x00406F20` found beside the marker -- and `0x00416BCB` adds the
	# constant to that z for the eye and the target alike. The cell's own
	# height is not in the flight at all: on `_C_115` the lever's
	# `L109EX00` stands at 12 800 with its cell at 15 999, and taking the
	# cell put the camera a field above the handle, looking over it.
	var lever: RecordingHost = RecordingHost.new()
	lever.objects[3] = Vector3i(3200, 3200, 160)
	var lever_queue: SequenceQueue = SequenceQueue.create(null)
	var lever_frames: int = SetpieceCamera.enqueue(lever_queue, lever, "lever",
		SetpieceDriver.LEVER_FRAMES, Vector2i(2, 1), 640, 640, 3,
		{"object": Vector3i(6400, 3200, 96)}, paint, no_cues)
	h.equal("camera.lever.frames", lever_frames, SetpieceDriver.LEVER_FRAMES)
	var lever_ran: Dictionary = _run_queue(lever_queue)
	h.equal("camera.lever.stages", DictRead.as_array(lever_ran["order"]),
		[SetpieceCamera.STAGE_FLIGHT, "lever", SetpieceCamera.STAGE_BACK])
	h.equal("camera.lever.flies_there_and_back", lever.flights.size(), 2)
	h.equal("camera.lever.eye_above_the_user", lever.flights[0][0],
		Vector3i(3200, 3200, 96 + 0xC80),
		"the user's x and y, the handle's own z plus `add eax, 0xC80` -- "
		+ "not the cell's 640, which would be a field too high")
	h.equal("camera.lever.target_above_the_object", lever.flights[0][1],
		Vector3i(6400, 3200, 96 + 0xC80))
	h.equal("camera.lever.back_where_it_was", lever.flights[1],
		[Vector3i(100, 200, 300), Vector3i(10, 20, 30)])
	# A cell whose object the search misses keeps the marker as its aim.
	var bare: RecordingHost = RecordingHost.new()
	bare.objects[3] = Vector3i(3200, 3200, 160)
	var bare_queue: SequenceQueue = SequenceQueue.create(null)
	var _bare: int = SetpieceCamera.enqueue(bare_queue, bare, "lever",
		SetpieceDriver.LEVER_FRAMES, Vector2i(2, 1), 640, 640, 3, {}, paint,
		no_cues)
	var _bare_ran: Dictionary = _run_queue(bare_queue)
	h.equal("camera.lever.no_object_falls_back_to_the_cell", bare.flights[0][1],
		Vector3i(6400, 3200, 640 + 0xC80),
		"the cell centre at its height, for a lever with no special object")

	# The supply box: from `0xFA0` above the user to `0x320` above the box
	# **object**, thirty-five frames, back.
	var box: RecordingHost = RecordingHost.new()
	box.objects[3] = Vector3i(3200, 3200, 160)
	var box_queue: SequenceQueue = SequenceQueue.create(null)
	var box_frames: int = SetpieceCamera.enqueue(box_queue, box, "pickup",
		SetpieceDriver.PICKUP_LID_FRAMES + SetpieceDriver.PICKUP_HOLD_FRAMES,
		Vector2i(2, 1), 640, 640, 3, {"object": Vector3i(6400, 3200, 96)},
		paint, no_cues)
	h.equal("camera.pickup.frames", box_frames, 35)
	var box_ran: Dictionary = _run_queue(box_queue)
	h.equal("camera.pickup.stages", DictRead.as_array(box_ran["order"]),
		[SetpieceCamera.STAGE_FLIGHT, "pickup", SetpieceCamera.STAGE_BACK])
	h.equal("camera.pickup.eye_above_the_user", box.flights[0][0],
		Vector3i(3200, 3200, 160 + 0xFA0), "`add ecx, 0xFA0`")
	h.equal("camera.pickup.target_above_the_box", box.flights[0][1],
		Vector3i(6400, 3200, 96 + 0x320),
		"`add edx, 0x320` over `[esi+0x18]`, the box's own z")

	# The footbridge (docs/42 section 8.1): a flight to the block, the camera
	# lowered every frame -- the eye by 0x960, the target by 0xD20 -- and
	# the flight back.
	var fall: RecordingHost = RecordingHost.new()
	var fall_queue: SequenceQueue = SequenceQueue.create(null)
	# The flight back restores the camera, so what each frame set is read
	# through the paint, which the arm calls after its `set_camera`.
	var fall_seen: Array[Array] = []
	var fall_frames: int = SetpieceCamera.enqueue(fall_queue, fall, "foot_bridge",
		5, Vector2i(2, 1), 0, 0, -1, {"object": Vector3i(6400, 3200, 0)},
		func(_frame: int, _total: int) -> void:
			fall_seen.append([fall.eye, fall.target]),
		no_cues)
	h.equal("camera.foot_bridge.frames", fall_frames, 5)
	var fall_ran: Dictionary = _run_queue(fall_queue)
	h.equal("camera.foot_bridge.stages", DictRead.as_array(fall_ran["order"]),
		[SetpieceCamera.STAGE_FLIGHT, "foot_bridge", SetpieceCamera.STAGE_BACK])
	h.equal("camera.foot_bridge.flies_to_the_block", fall.flights[0][1],
		Vector3i(6400, 3200, 0))
	h.equal("camera.foot_bridge.camera_per_frame", fall.camera_sets, 5)
	h.equal("camera.foot_bridge.follows_the_block_down",
		fall_seen[4][1] if fall_seen.size() == 5 else Vector3i.ZERO,
		Vector3i(6400, 3200, -5 * 0xD20), "the target drops 0xD20 a frame")
	h.equal("camera.foot_bridge.eye_drops_slower",
		fall_seen[4][0] if fall_seen.size() == 5 else Vector3i.ZERO,
		Vector3i(100, 200, 300 - 5 * 0x960), "the eye drops 0x960 a frame")
	h.equal("camera.foot_bridge.back_where_it_was", fall.flights[1],
		[Vector3i(100, 200, 300), Vector3i(10, 20, 30)])
	# `FootBridge2` is the same fall on the block its search finds.
	var fall2: RecordingHost = RecordingHost.new()
	var fall2_queue: SequenceQueue = SequenceQueue.create(null)
	var fall2_frames: int = SetpieceCamera.enqueue(fall2_queue, fall2,
		"foot_bridge2", 30, Vector2i(16, 10), 0, 0, -1,
		{"object": Vector3i(51200, 32000, 0)},
		func(_frame: int, _total: int) -> void: pass, no_cues)
	h.equal("camera.foot_bridge2.frames", fall2_frames, 30)
	var fall2_ran: Dictionary = _run_queue(fall2_queue)
	h.equal("camera.foot_bridge2.stages", DictRead.as_array(fall2_ran["order"]),
		[SetpieceCamera.STAGE_FLIGHT, "foot_bridge2", SetpieceCamera.STAGE_BACK])
	h.equal("camera.foot_bridge2.flies_to_the_block", fall2.flights[0][1],
		Vector3i(51200, 32000, 0))

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
	h.equal("camera.ground_unit.hidden_while_queued", ground.suppressed,
		PackedInt32Array([8]),
		"the world insertion precedes the sequence, so the destination body must "
		+ "stay hidden until its own rise begins")
	h.equal("camera.ground_unit.not_shown_before_playback", ground.shown,
		PackedInt32Array())
	var _ground_ran: Dictionary = _run_queue(ground_queue)
	h.equal("camera.ground_unit.shows_the_body_before_the_rise", ground.shown,
		PackedInt32Array([8]),
		"the script inserted the unit before aPlayGroundUnitSequence; the first "
		+ "frame must materialise it before moving it out of the floor")
	h.equal("camera.ground_unit.debris_then_dust", ground.programs,
		["%s:3,3,%d" % [BlobPrograms.GROUND_DEBRIS, SetpieceCamera.GROUND_DEBRIS_UP],
		"%s:5,3" % BlobPrograms.LANDING_DUST])
	h.equal("camera.ground_unit.inserts_the_hole", ground.inserted,
		["%s:9600,9600,0,0" % SetpieceCamera.GROUND_HOLE_MODEL])
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
	# The camera as each half of the strike leaves it: the fly-past's last
	# frame, one run frame before the first bomb lands, and one well after
	# it with the pool's first record moved out from under the view.
	var lead_view: Array[Vector3i] = []
	var run_view: Array[Vector3i] = []
	var held_view: Array[Vector3i] = []
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
			if run_frames == 5:
				bombs.first = Vector3i(99000, 99000, 99000)
		var _still: bool = bombs_queue.advance(
			1.0 / SequenceQueue.FRAMES_PER_SECOND)
		if stage == SetpieceCamera.STAGE_LEAD:
			lead_view = [bombs.eye, bombs.target]
		elif stage == "para_bombs" and run_frames == 2:
			run_view = [bombs.eye, bombs.target]
		elif stage == "para_bombs" and run_frames == 7:
			held_view = [bombs.eye, bombs.target]
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
	# **The fly-past follows the plane.** `0x00415FE6`..`0x00416014` runs
	# `0x0042B4B0` and then `0x00403560` **every frame**: the eye holds the
	# flight path and the target is the pool's first live record. The eye's z
	# is the bomber's own -- `0x4E200` on both -- so the plane is watched
	# level rather than from above. `0x00415FB4`'s one set with the camera's
	# own target, which this check used to pin as the whole of it, is never
	# drawn: no frame tick stands between it and the loop.
	h.equal("camera.para_bombs.the_fly_past_follows_the_plane", lead_view,
		[Vector3i(SetpieceCamera.BOMBER_START_X, 0,
			SetpieceCamera.BOMBER_START_Z), Vector3i(1600, 3200, 48000)],
		"a target left on the ground was a view straight down at the map")
	# **And the run is watched from the ground.** `0x00416319` pushes
	# `(0, 0, 0xC80)` for the eye and `0x004162F6` clamps the target's z to
	# `0x1F40`, so the camera stands at the world's corner one field up and
	# looks at where the bomb is going rather than at the sky it came from.
	h.equal("camera.para_bombs.the_run_watches_from_the_ground", run_view,
		[SetpieceCamera.BOMB_RUN_EYE,
		Vector3i(1600, 3200, SetpieceCamera.BOMB_RUN_CEILING)],
		"the strike used to be shown from the fly-past's 320 000 up")
	# The camera lives in `0x004162D6`'s loop, which ends at the **first**
	# landing; `0x00416364`'s, which plays the rest of the crumps, sets none.
	h.equal("camera.para_bombs.the_view_holds_after_the_first_crump",
		held_view, run_view,
		"the pool's first record moved to (99000, 99000, 99000) on frame 5")
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

	# **Three buffers, and a busy one swallows the crump whole.**
	# `0x00416271` creates three `crush.wav` buffers before the bomb run's
	# loop and `0x004163A1` advances the index on every landing whether or
	# not the buffer it lands on is free; `aDirectSoundPlayBuffer`
	# `0x00436EF0` is `IDirectSoundBuffer::Play` with no `Stop` in front of
	# it, so a play into a buffer that is still sounding does nothing at all.
	# One fresh voice per bomb is what made a stick of sixty a wall of noise.
	var ring: BombRunHost = BombRunHost.new()
	var ring_st: Dictionary = {"crump": 0,
		"buffers": PackedInt32Array([-1, -1, -1])}
	for _landing: int in range(6):
		SetpieceCamera.crump(ring, bomb_cue, ring_st)
	h.equal("camera.para_bombs.three_buffers_cap_the_crumps",
		[ring.played.size(), DictRead.as_int(ring_st["crump"])],
		[SetpieceCamera.BOMB_BUFFERS, 0],
		"six landings, three buffers, and the index home again")
	# The fourth buffer-load is the first one back: a crump sounds again as
	# soon as the buffer its turn lands on has finished.
	ring.busy[0] = false
	SetpieceCamera.crump(ring, bomb_cue, ring_st)
	h.equal("camera.para_bombs.a_finished_buffer_sounds_again",
		ring.played.size(), SetpieceCamera.BOMB_BUFFERS + 1,
		"buffer 0 was free when its turn came round")
	SetpieceCamera.crump(ring, bomb_cue, ring_st)
	h.equal("camera.para_bombs.and_the_others_are_still_busy",
		ring.played.size(), SetpieceCamera.BOMB_BUFFERS + 1,
		"buffer 1 has not finished, so its crump is dropped")

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
		"L069EE00.3DI": 4, "A_PARAB1.3DI": 5, "A_EXPL05.3DI": 6}
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
		# `aBlob_CreateShockWave` on the type its two call sites push.
		[BlobPrograms.SHOCK_WAVE, PackedInt32Array([2, 2,
			BlobTriggers.SHOCK_WAVE_TYPE]), 60, 0],
	]
	# **The shock wave, field by field.** Its arm is chosen by a *type*, and
	# the transcription's arithmetic waits on a native capture -- Wine does
	# not reach the anchor on this host (`blob_gold.PROGRAM_ARGS_STALE`) -- so
	# what is pinned here is the shape the disassembly gives: sixty records at
	# the object itself, the ring in the **velocity** rather than the
	# placement, and a type outside the three arms making nothing at all.
	var wave: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var wave_draws: BlobPrograms.Draws = BlobPrograms.Draws.create(1.0)
	var wave_ran: bool = BlobPrograms.run(BlobPrograms.SHOCK_WAVE, wave,
		wave_draws, PackedInt32Array([2, 2, BlobTriggers.SHOCK_WAVE_TYPE]),
		inputs)
	h.check("shockwave.runs", wave_ran)
	var wave_object: Vector3i = inputs.object(2, 2)
	var wave_wrong: Array[String] = []
	var wave_still: int = 0
	for record: Dictionary in wave.records:
		if DictRead.as_int(record["kind"]) != BlobPrograms.SHOCKWAVE_KIND \
				or DictRead.as_int(record["life"]) != 20 \
				or DictRead.as_int(record["class_id"]) != 0 \
				or DictRead.as_int(record["rot_y"]) != 0 \
				or DictRead.as_int(record["vz"]) != 0 \
				or DictRead.as_int(record["x"]) != wave_object.x \
				or DictRead.as_int(record["y"]) != wave_object.y \
				or DictRead.as_int(record["z"]) != wave_object.z:
			wave_wrong.append(str(record))
		if DictRead.as_int(record["vx"]) == 0 \
				and DictRead.as_int(record["vy"]) == 0:
			wave_still += 1
	h.equal("shockwave.records_agree", wave_wrong, [] as Array[String],
		"sixty kind-13 records of life 20 at the object, `rot_y` 0, `vz` 0")
	h.equal("shockwave.every_record_moves", wave_still, 0,
		"the ring is the velocity, so no record stands still")
	h.check("shockwave.orientation_turns",
		DictRead.as_int(wave.records[0]["rot_z"])
			!= DictRead.as_int(wave.records[1]["rot_z"]),
		"each record is aimed along its own point on the circle")
	# The fall-through arm: `ecx` stays zero and the loop is skipped entire.
	var quiet: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var quiet_draws: BlobPrograms.Draws = BlobPrograms.Draws.create(1.0)
	var _quiet_ran: bool = BlobPrograms.run(BlobPrograms.SHOCK_WAVE, quiet,
		quiet_draws, PackedInt32Array([2, 2, 18]), inputs)
	h.equal("shockwave.a_type_with_no_arm_makes_nothing",
		[quiet.records.size(), quiet.refused, quiet_draws.count], [0, 0, 0],
		"a faithful zero -- which is what the capture in hand recorded")

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


## One `MoveUnit` hook, from `core`'s answer to the picture's queue.
##
## `aRunLCL` `0x0046EEFD` is the last thing `aExecuteMove` does, and the
## two footbridge maps drop theirs out of it -- `_C_106` six times and
## `_C_107` once, which is every `FootBridge` call the corpus ships, and both
## unconditionally, so on those maps *any* walk asks the question.
## `core` has run the hook and handed the outcome back on
## [member MoveResult.script_result] since the second slice, and **`game` read
## that field nowhere until 2026-09-07**: the interpreter killed the riders and
## turned the nine cells into deep holes, and the picture showed none of it --
## no fall, no tumble, no `aDeleteLand`, and a save afterwards carrying an
## empty `removed` row over cells that had already gone. Found by playing
## `_C_107` through the agent server, which is the only way it could have been:
## `_C_129`'s own `MoveUnit` section is empty, so no fixture asked.
##
## The program is built here rather than read out of the cache because the
## claim is about the **seam**, not about one mission's script: one command,
## `FootBridge (x, y, frames, 0)`, whose zero threshold makes the mover its
## own rider.
func _check_move_script_seam(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var attached: bool = world.attach_script(_foot_bridge_program(
		MOVE_HOOK_CELL, MOVE_HOOK_FRAMES))
	h.check("move_script.the_program_attaches", attached,
		"one FootBridge command, the shape `script.json` carries")
	var before_walk: Dictionary = world.unit_view(0)
	var moved: MoveResult = world.submit_move(
		MoveCommand.create(0, MOVE_HOOK_CELL.x, MOVE_HOOK_CELL.y))
	if not h.check("move_script.the_walk_ran", moved.ok, moved.reason):
		return
	h.check("move_script.core_ran_the_hook",
		DictRead.as_bool(moved.script_result.get("ran", false)),
		"`0x0046EDDC`'s alive gate let the mover reach `aRunLCL`")
	# [method LclOutcome.to_dict] serialises an event as a `[name, values]`
	# pair, which is the shape the cache document carries and the shape
	# [method AudioEvents.as_event] exists to take apart -- so this reads it
	# the way [method SliceMain._present_script] does and not by hand.
	var events: Array = DictRead.as_array(moved.script_result.get("events", []))
	var names: Array[String] = []
	var first: Dictionary = {}
	for entry: Variant in events:
		var event: Dictionary = AudioEvents.as_event(entry)
		names.append(AudioEvents.name_of(event))
		if first.is_empty():
			first = event
	h.equal("move_script.the_hook_dropped_the_bridge", names, ["foot_bridge"]
		as Array[String], "the walk's own script event, and only it")
	if first.is_empty():
		return
	var values: PackedInt32Array = SetpieceDriver._numbers(first)
	h.equal("move_script.the_mover_is_its_own_rider",
		[values[3], values[4]], [1, 0],
		"one rider, and it is the unit that walked in")
	h.equal("move_script.core_killed_the_rider",
		DictRead.as_int(world.unit_view(0).get("hp", -1)), 0,
		"`aRemoveUnitElement` -- the interpreter kills before the picture "
		+ "starts, which is why the record has to outlive it")
	h.check("move_script.the_walk_has_an_epilogue",
		SliceMain._script_seconds(moved.script_result) > 0.0,
		"the `script` event holds for the fall, behind the walk's own event")
	h.check("move_script.an_empty_outcome_holds_nothing",
		is_zero_approx(SliceMain._script_seconds({})),
		"a walk whose script did nothing holds the playback for nothing")

	# The picture's half: the same dictionary, on the same seam
	# [method SliceMain.move_selected] now hands it to.
	var main: SliceMain = SliceMain.new()
	main.world = world
	# The mirror as it stood before the hook: the rider is alive in it, and
	# stays so until the `script` event's delta lands at the end of the fall.
	main._shown = world.clone()
	main._shown.units_for_ai()[0] = UnitState.from_view(before_walk)
	var units: UnitsView = UnitsView.new()
	units.shown_ref = main._shown
	main._units = units
	var body: Node3D = Node3D.new()
	body.name = "unit_0"
	units.add_child(body)
	main._sequences = SequenceQueue.create(null)
	main._rig = CameraRig.new()
	main._rig.set_now(SAVED_EYE, SAVED_TARGET)
	# The sound layer is wired here -- the recording one, which opens no
	# stream -- so that the cue count the presenter answers can be checked
	# against the table's own; [method _check_warp_script_seam] is the run
	# with no sound layer at all, where the queue alone has to answer.
	var tables: AudioTables = AudioTables.open(CacheFixture.cache_dir())
	if not tables.is_loaded():
		h.check("move_script.audio", false, "tables/sound.json")
		units.free()
		main._rig.free()
		main.free()
		return
	main._events = AudioEvents.open(tables, {})
	var audio: RecordingAudio = RecordingAudio.new()
	main._audio = audio
	# **The mirror keeps the rider until the `script` event lands**, and the
	# picture keeps it for the length of the fall: in play the landing comes
	# when the set piece is queued ([method SliceMain._queue_setpiece]) and
	# [method SliceMain._flush_picture] waits for the queue, so the body is
	# drawn falling and dropped at the drain. No playback runs here, so the
	# mirror is what carries the rule in this check. A script kill carries
	# no attack, no outcome and no marker, so nothing that reads outcomes
	# could ever have found it; the delta needs no shape.
	h.check("move_script.the_mirror_keeps_the_rider",
		DictRead.as_int(main._shown.unit_view(0)["hp"]) > 0,
		"the truth lost it inside `submit_move`; the picture draws the "
		+ "record it had when the walk began")
	var shown: int = main._present_script(moved.script_result)
	h.equal("move_script.the_events_reach_the_picture", shown,
		main._events.for_event(first).size(),
		"every cue the table names for the fall is counted, and no other")
	h.check("move_script.the_fall_is_on_the_queue",
		main._sequences.is_running(),
		"which is what `move_selected` had never asked for")
	# `build` reads `geometry["prototypes"]`, so an empty dictionary is a
	# missing key and not "no models".
	units.build(main._shown, {"prototypes": {}}, {})
	h.check("move_script.the_rider_is_drawn_for_the_fall",
		units.get_node_or_null(NodePath("unit_0")) != null,
		"the body outlives its death for the length of the fall")
	# The rule the hold exists for, on the fixture's own world and geometry:
	# a rebuild drops a dead body and keeps a held one. This is what makes the
	# order above load-bearing rather than tidy.
	_check_rebuild_drops_the_dead(h)
	# The rig is a [Node3D] and is nobody's child, so freeing `main` does not
	# reach it -- and a script left held at shutdown is
	# `N resources still in use at exit`, which `run_tests.sh` gates on.
	units.free()
	audio.free()
	main._rig.free()
	main.free()


## One `FootBridge (x, y, frames, 0)`, as `LclProgram.from_document` reads it.
## The computer's walk fires the same hook.
##
## `aRunLCL` `0x0046EEFD` closes `aExecuteMove` for every caller -- the
## alive gate `0x0046EDDC` is the only test between the walk and the six
## environment writes -- and `0x0040A750`'s tail calls that routine for the
## computer's mover. `AISystem.run` never went through `World.submit_move`,
## so until 2026-09-07 `core` ran no `MoveUnit` for a computer walk at all
## and `_C_106`'s six bridges could not fall under its aliens. This drives
## the plan's own commit step rather than a whole `AISystem.run`, because
## the planner may never choose the bridge cell; the fixture replay of
## `cases_ai.json` builds its context with no script and is unchanged.
func _check_ai_move_script_seam(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var _attached: bool = world.attach_script(_foot_bridge_program(
		MOVE_HOOK_CELL, MOVE_HOOK_FRAMES))
	# The hook is run by [World], so the `script` boundary is the world's own.
	world.enable_journal()
	var ctx: AIContext = AIContext.create(world.state, world.units_for_ai(),
		world.unit_types(), world.weapons(), world.ctrlmap(), world.turn,
		world.rng)
	ctx.mission_script = world._script_callable()
	var unit: UnitState = world.units_for_ai()[0]
	var _filled: bool = AIPlan.build_move_map(ctx, unit, 0)
	var target: int = world.state.index_of(MOVE_HOOK_CELL.x, MOVE_HOOK_CELL.y)
	h.check("ai_script.the_computer_walks_onto_the_bridge",
		AIPlan.commit(ctx, unit, target) and unit.x == MOVE_HOOK_CELL.x
			and unit.y == MOVE_HOOK_CELL.y,
		"`0x0040A750`'s tail, to (%d, %d)" % [unit.x, unit.y])
	var payload: Dictionary = _last_event_payload(ctx, "move")
	var outcome: Dictionary = DictRead.as_dict(payload.get("script", {}))
	h.check("ai_script.the_walk_fired_the_hook",
		DictRead.as_bool(outcome.get("ran", false)),
		"`aRunLCL` `0x0046EEFD`, behind no test of the player")
	h.equal("ai_script.the_bridge_fell_under_it", _event_names(outcome),
		["foot_bridge"] as Array[String], "the walk's own script event")
	h.equal("ai_script.core_killed_the_rider",
		DictRead.as_int(world.unit_view(0).get("hp", -1)), 0,
		"`aRemoveUnitElement`, inside the computer's own turn")
	# **The kill rides in the event's delta**, which is what the picture
	# lands when the fall it is drawing reaches its end. A script kill
	# carries no attack, no outcome and no marker, so a reader that walked
	# outcomes could not see it at all -- the delta needs no such shape.
	h.check("ai_script.the_riders_ride_the_delta",
		_script_delta_kills(world, 0),
		"the `script` event's delta names the rider with no hit points")
	# The computer's jump closes with the same call (`0x0046F1D6`).
	var jumper: World = _jet_pack_world()
	var _hooked: bool = jumper.attach_script(_foot_bridge_program(
		WARP_HOOK_CELL, MOVE_HOOK_FRAMES))
	jumper.enable_journal()
	var jump_ctx: AIContext = AIContext.create(jumper.state,
		jumper.units_for_ai(), jumper.unit_types(), jumper.weapons(),
		jumper.ctrlmap(), jumper.turn, jumper.rng)
	jump_ctx.mission_script = jumper._script_callable()
	var mover: UnitState = jumper.units_for_ai()[0]
	h.check("ai_script.the_computer_jumps_onto_the_bridge",
		AIPlan.execute_warp(jump_ctx, mover, WARP_HOOK_CELL.x, WARP_HOOK_CELL.y),
		"`aExecuteWarp` for the computer")
	var jumped: Dictionary = _last_event_payload(jump_ctx, "warp")
	h.equal("ai_script.the_jump_fired_the_hook",
		_event_names(DictRead.as_dict(jumped.get("script", {}))),
		["foot_bridge"] as Array[String], "`aRunLCL` `0x0046F1D6`")
	h.check("ai_script.the_jump_s_rider_rides_the_delta",
		_script_delta_kills(jumper, 0),
		"the same delta, on a jump")
	# And with no script attached the payload has no such key: the shape
	# the fixture replay compares against `inclib/ai.py`, which never fires
	# the hook, is exactly what it was.
	var bare: World = TestFixtures.tiny_world()
	var bare_ctx: AIContext = AIContext.create(bare.state, bare.units_for_ai(),
		bare.unit_types(), bare.weapons(), bare.ctrlmap(), bare.turn, bare.rng)
	var walker: UnitState = bare.units_for_ai()[0]
	var _bare_fill: bool = AIPlan.build_move_map(bare_ctx, walker, 0)
	var _walked: bool = AIPlan.commit(bare_ctx, walker, target)
	h.check("ai_script.no_script_no_key",
		not _last_event_payload(bare_ctx, "move").has("script"),
		"the fixture replay's payload shape is unchanged")


## The player's jump reaches the picture's half of the seam, and the picture
## needs no sound layer to queue it.
##
## `warp_selected` holds the riders and presents the outcome the way
## `move_selected` does, and nothing shipped can show it: the jet pack is a
## tech-4 item in a campaign whose tech level is 1 from beginning to end
## (docs/27 section 5.2), the two footbridge maps place no warping unit, and
## the one shipped pairing of a jet pack with a live `MoveUnit` is `_C_131`,
## whose hook only reorders the aliens. So the seam is pinned here, on a
## fixture, end to end.
func _check_warp_script_seam(h: TestHarness) -> void:
	var world: World = _jet_pack_world()
	var _attached: bool = world.attach_script(_foot_bridge_program(
		WARP_HOOK_CELL, MOVE_HOOK_FRAMES))
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(0))
	h.check("warp_script.the_bridge_is_a_warp_target",
		fill.is_warp_target(WARP_HOOK_CELL.x, WARP_HOOK_CELL.y),
		"past the walk's one field, inside the pack's five")
	var before_jump: Dictionary = world.unit_view(0)
	var jumped: WarpResult = world.submit_warp(
		WarpCommand.create(0, WARP_HOOK_CELL.x, WARP_HOOK_CELL.y))
	if not h.check("warp_script.the_jump_ran", jumped.ok, jumped.reason):
		return
	h.equal("warp_script.core_ran_the_hook",
		_event_names(jumped.script_result), ["foot_bridge"] as Array[String],
		"`0x0046F133`'s alive gate let the mover reach `aRunLCL`")
	h.equal("warp_script.core_killed_the_rider",
		DictRead.as_int(world.unit_view(0).get("hp", -1)), 0,
		"the mover is its own rider")
	var main: SliceMain = SliceMain.new()
	main.world = world
	# The mirror is taken from a world where the rider is still alive: this
	# is a clone of the record before the hook, which is what the picture
	# draws until the `script` delta lands.
	main._shown = world.clone()
	var alive: UnitState = UnitState.from_view(before_jump)
	main._shown.units_for_ai()[0] = alive
	var units: UnitsView = UnitsView.new()
	units.shown_ref = main._shown
	main._units = units
	var body: Node3D = Node3D.new()
	body.name = "unit_0"
	units.add_child(body)
	main._sequences = SequenceQueue.create(null)
	main._rig = CameraRig.new()
	main._rig.set_now(SAVED_EYE, SAVED_TARGET)
	# **No sound layer.** `_audio` and `_events` are both null here, and
	# the fall still has to reach the queue: the presenter used to answer
	# nothing at all without them, a coupling the picture never needed.
	h.equal("warp_script.no_sound_layer_counts_no_cue",
		main._present_script(jumped.script_result), 0,
		"nothing to play, and nothing pretended")
	h.check("warp_script.the_fall_is_on_the_queue_without_sound",
		main._sequences.is_running(),
		"the set piece queues whether or not there is a table to name its cues")
	h.check("warp_script.the_rider_stands_in_the_mirror_until_the_fall_ends",
		DictRead.as_int(main._shown.unit_view(0)["hp"]) > 0,
		"the truth killed it inside `submit_warp`; the picture has not "
		+ "been told")
	h.equal("warp_script.the_snapshot_names_the_hook",
		str(main.last_script()),
		str({"ran": true, "events": ["foot_bridge"] as Array[String],
			"count": 1}),
		"`picture.script`, the driven session's view of a hook")
	units.free()
	main._rig.free()
	main.free()


## The platform ride moves what it carries.
##
## `aPlayPlatformSequence` adds `0x140` a frame to every object it found on
## the block, to every rider and to the camera target (docs/20 section 7.4
## step 2). The remake ran the sequence -- frames, dust, sound, camera -- and
## moved nothing: the deck stayed where the `.lev` authored it and the
## riders, which `core` relocates the instant the command runs, stood in
## mid-air over the destination. Found on `_C_106`'s first turn, 2026-09-07,
## by the player watching. `_C_106` is not in the dev fixtures, so the
## arithmetic is pinned on its own call and the object and body moves on
## `_C_129`'s geometry.
func _check_platform_ride(h: TestHarness) -> void:
	# `_C_106`'s own `Platform (19,2,2,11)`: south, eleven fields.
	var south: PackedInt32Array = PackedInt32Array([19, 2, 2, 11])
	h.equal("platform.one_frame_is_the_step",
		SetpieceDriver.platform_offset(south, 1),
		Vector3i(0, SetpieceDriver.PLATFORM_STEP, 0), "`0x140` along +y")
	h.equal("platform.the_frames_add_up_to_the_fields",
		SetpieceDriver.platform_offset(south,
			11 * SetpieceDriver.PLATFORM_FRAMES_PER_FIELD),
		Vector3i(0, 11 * WorldSpace.WORLD_UNITS_PER_FIELD, 0),
		"ten steps are one field, so `dist * 10` frames are `dist` fields")
	h.equal("platform.the_travel_is_in_fields",
		SetpieceDriver.platform_travel(south), Vector2i(0, 11), "")
	h.equal("platform.west_is_minus_x",
		SetpieceDriver.platform_offset(PackedInt32Array([5, 5, 1, 3]), 10),
		Vector3i(-WorldSpace.WORLD_UNITS_PER_FIELD, 0, 0),
		"docs/20 section 7.4: 0=N 1=W 2=S 3=E")
	h.equal("platform.a_bad_direction_moves_nothing",
		SetpieceDriver.platform_offset(PackedInt32Array([5, 5, 4, 3]), 10),
		Vector3i.ZERO, "")
	var block: Array[Vector2i] = SetpieceDriver.platform_block(south)
	h.equal("platform.the_block_is_nine", block.size(), 9, "")
	h.check("platform.the_block_is_x_outer",
		block.size() >= 2 and block[0] == Vector2i(18, 1)
			and block[1] == Vector2i(18, 2),
		"`0x00412AAA`: `ebx` runs x, `edi` runs y inside it")

	var loaded: Dictionary = CacheFixture.load_world(WALL_MISSION)
	if loaded.is_empty():
		h.check("platform.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	if geometry.is_empty():
		h.check("platform.fixture", false, "geometry")
		return
	var scenery: Scenery = Scenery.new()
	scenery.build(document, geometry, {})
	var width: int = world.state.width
	var cell: int = -1
	for i: int in range(world.state.cell_count()):
		if not scenery.objects_on(i).is_empty() and i + width < world.state.cell_count() \
				and scenery.objects_on(i + width).is_empty():
			cell = i
			break
	if not h.check("platform.fixture_has_an_object_to_carry", cell >= 0,
			"a cell with a special object and an empty cell south of it"):
		scenery.free()
		return
	var carried: Node3D = scenery.objects_on(cell)[0]
	var authored: Vector3 = carried.transform.origin
	var origin: Vector3i = scenery.object_origins(cell)[0]
	var _shifted: int = scenery.shift_objects(PackedInt32Array([cell]),
		Vector3i(0, SetpieceDriver.PLATFORM_STEP, 0))
	h.equal("platform.a_shift_draws_the_object_a_step_on",
		carried.transform.origin,
		authored + WorldSpace.to_godot(0, SetpieceDriver.PLATFORM_STEP, 0),
		"one frame south, in Godot's -z")
	h.check("platform.a_shift_keeps_the_key",
		scenery.objects_on(cell).has(carried),
		"the object still belongs to its source cell mid-ride")
	var snapshot: Dictionary = world.terrain_snapshot()
	var _landed: int = scenery.move_objects(snapshot, PackedInt32Array([cell]),
		0, 1)
	var target: int = cell + width
	h.check("platform.the_move_rekeys_the_object",
		not scenery.objects_on(cell).has(carried)
			and scenery.objects_on(target).has(carried),
		"the search finds it on the destination cell now, and not on the source")
	var origins: Array[Vector3i] = scenery.object_origins(target)
	h.equal("platform.the_origin_moves_a_field",
		origins[origins.size() - 1] if not origins.is_empty() else Vector3i.ZERO,
		origin + Vector3i(0, WorldSpace.WORLD_UNITS_PER_FIELD, 0),
		"what a later set piece flies to")
	var landed: Vector3 = authored + WorldSpace.to_godot(0,
		WorldSpace.WORLD_UNITS_PER_FIELD, 0)
	h.equal("platform.the_object_lands_a_field_on", carried.transform.origin,
		landed, "")
	var _applied: int = scenery.apply_state(snapshot, PackedInt32Array([target]))
	h.equal("platform.the_terrain_diff_leaves_it_there",
		carried.transform.origin, landed,
		"the authored transform was set so the destination's own height "
		+ "delta lands the object where the ride left it")
	# The save carries the move: a fresh scenery built from the map document
	# has the deck at its authored place, and the record puts it back where
	# the ride left it -- through the header's JSON, and twice is once.
	var record: Dictionary = scenery.pose_record()
	h.equal("platform.the_record_carries_the_move", record["moves"],
		[[cell, 0, 1]], "one row: the home cell and the ride in fields")
	var parsed: Variant = JSON.parse_string(JSON.stringify(record))
	var carried_record: Dictionary = parsed
	var resumed: Scenery = Scenery.new()
	resumed.build(document, geometry, {})
	var _fresh: int = resumed.apply_all(snapshot)
	h.check("platform.a_fresh_build_has_the_deck_at_home",
		not resumed.objects_on(cell).is_empty()
			and resumed.objects_on(target).is_empty(), "")
	h.equal("platform.the_restore_moves_it", resumed.restore_poses(carried_record,
		snapshot), 2, "the deck and the cell's marker, as the ride carries both")
	h.check("platform.the_restored_deck_is_on_the_destination",
		resumed.objects_on(cell).is_empty()
			and not resumed.objects_on(target).is_empty(), "")
	h.equal("platform.the_restored_record_matches", resumed.pose_record(),
		record, "what was restored records back as what was saved")
	h.equal("platform.restore_twice_is_once",
		resumed.restore_poses(carried_record, snapshot), 0,
		"the home cell has nothing left to carry")
	var back: Node3D = resumed.objects_on(target)[0]
	h.equal("platform.the_restored_deck_stands_where_the_ride_left_it",
		back.transform.origin, landed, "")
	var _again: int = resumed.apply_all(snapshot)
	h.equal("platform.the_restored_deck_survives_the_terrain_diff",
		back.transform.origin, landed, "")
	resumed.free()

	# The rider's carry, and that it outlives a rebuild the way a lift does.
	var slots: PackedInt32Array = world.unit_slots()
	if slots.is_empty():
		h.check("platform.fixture", false, "one unit")
		scenery.free()
		return
	var slot: int = slots[0]
	var units: UnitsView = UnitsView.new()
	units.shown_ref = world
	units.build(world, geometry, {})
	var node: Node3D = units.get_node_or_null(NodePath("unit_%d" % slot))
	if not h.check("platform.the_rider_is_drawn", node != null, ""):
		units.free()
		scenery.free()
		return
	var stood: Vector3 = node.position
	units.shift(slot, Vector3i(WorldSpace.WORLD_UNITS_PER_FIELD, 0, 0))
	h.equal("platform.the_rider_is_carried_a_field",
		node.position - stood, Vector3(WorldSpace.FIELD_METRES, 0.0, 0.0),
		"+x, and the height untouched")
	units.build(world, geometry, {})
	var rebuilt: Node3D = units.get_node_or_null(NodePath("unit_%d" % slot))
	h.check("platform.the_carry_survives_a_rebuild",
		rebuilt != null and is_equal_approx(rebuilt.position.x,
			stood.x + WorldSpace.FIELD_METRES),
		"a rebuild recreates every node, so the carry is re-applied like a lift")
	var _down: int = units.drop_shifts()
	rebuilt = units.get_node_or_null(NodePath("unit_%d" % slot))
	h.check("platform.the_rider_is_put_down",
		rebuilt != null and rebuilt.position.is_equal_approx(stood),
		"back on its cell")
	# Two rides on one queue: the first's landing puts down its own riders
	# and leaves the second's carry alone. `_C_105`'s consoles each run two
	# `Platform` commands, and the second's riders used to drop onto their
	# destination cells the moment the first deck landed.
	if slots.size() >= 2:
		var other: int = slots[1]
		var other_node: Node3D = units.get_node_or_null(
			NodePath("unit_%d" % other))
		var other_stood: Vector3 = other_node.position if other_node != null \
			else Vector3.ZERO
		var carry: Vector3i = Vector3i(0, -WorldSpace.WORLD_UNITS_PER_FIELD, 0)
		units.shift(slot, carry)
		units.shift(other, carry)
		h.equal("platform.the_first_landing_puts_down_its_own_riders",
			units.put_down(PackedInt32Array([slot])), 1, "")
		var kept: Dictionary[int, Vector3i] = units.shifts()
		h.equal("platform.the_second_rides_riders_keep_their_carry",
			[kept.has(slot), kept.get(other, Vector3i.ZERO)], [false, carry],
			"only the named slot was put down")
		other_node = units.get_node_or_null(NodePath("unit_%d" % other))
		h.check("platform.the_second_rides_rider_is_still_drawn_carried",
			other_node != null and not other_node.position.is_equal_approx(
				other_stood), "it stays where its deck is, not on its cell")
		var _rest: int = units.drop_shifts()
	else:
		h.check("platform.fixture_has_two_units", false,
			"the second-ride check wants a second unit")
	units.free()
	scenery.free()


## A 7x7 free map with one marine carrying the jet pack (`Info.lcl`'s
## equipment 7, docs/23 section 7.5) and a single movement point, so the
## warp overlay reaches cells its walk cannot.
static func _jet_pack_world() -> World:
	var units: Array = [TestFixtures.unit(0, 2, 2, 0, 0, 1, 0,
		[UnitState.JET_PACK_EQUIP_ID])]
	return World.create(TestFixtures.map_document(7, 7, units),
		TestFixtures.balance(), 1.0)


static func _last_event_payload(ctx: AIContext, kind: String) -> Dictionary:
	for i: int in range(ctx.result.events.size() - 1, -1, -1):
		var event: AIEvent = ctx.result.events[i]
		if event.kind == kind:
			return event.payload
	return {}


static func _event_names(outcome: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for entry: Variant in DictRead.as_array(outcome.get("events", [])):
		names.append(AudioEvents.name_of(AudioEvents.as_event(entry)))
	return names


static func _foot_bridge_program(cell: Vector2i, frames: int) -> Dictionary:
	var args: Array = []
	for value: int in [cell.x, cell.y, frames, 0]:
		args.append({"kind": "number", "value": value})
	return {
		"schema": LclProgram.SCHEMA,
		"header_line": 1,
		"instructions": [
			{"kind": "command", "name": "FootBridge", "line": 1, "op": ">",
				"args": args},
			{"kind": "end", "name": "", "line": 2, "op": ">", "args": []},
		],
		"labels": {},
	}


## `UnitsView.build` on a world with a dead unit in it: dropped when nothing
## holds it, drawn when something does.
func _check_rebuild_drops_the_dead(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(WALL_MISSION)
	if loaded.is_empty():
		h.check("move_script.rebuild_fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	var slots: PackedInt32Array = world.unit_slots()
	if geometry.is_empty() or slots.is_empty():
		h.check("move_script.rebuild_fixture", false, "geometry and one unit")
		return
	var slot: int = slots[0]
	var units: UnitsView = UnitsView.new()
	units.shown_ref = world
	# The node, not [member UnitsView.bodies]: a body is Charisma's and needs
	# the model tables this fixture does not open, while the node is what the
	# rebuild frees and what [method SliceMain._drop_riders] moves.
	var path: NodePath = NodePath("unit_%d" % slot)
	units.build(world, geometry, {})
	h.check("move_script.the_living_are_drawn",
		units.get_node_or_null(path) != null,
		"slot %d is in the picture before it dies" % slot)
	var doomed: UnitState = world.units_for_ai()[slot]
	var _lost: bool = UnitState.remove(world.state, world.unit_types(),
		world.turn, doomed)
	units.build(world, geometry, {})
	h.check("move_script.the_dead_are_dropped",
		units.get_node_or_null(path) == null,
		"`aKillUnit` deletes the object, so a rebuild does not draw it")
	# ...and the mirror is what decides when that happens: a world that has
	# not been told about the death still draws the body, which is how a set
	# piece keeps its rider for the length of the fall.
	var mirror: World = loaded["world"]
	units.shown_ref = mirror
	h.check("move_script.the_mirror_draws_what_it_still_has",
		units.get_node_or_null(path) == null,
		"the same view, one world behind: the record here is the world's own")
	units.free()


## Whether the `script` event a context's journal recorded takes `slot` off
## the map -- the delta's own answer, with no outcome to read.
static func _script_delta_kills(source: World, slot: int) -> bool:
	if not source.journal_enabled():
		return false
	for event: Dictionary in source.take_events():
		if DictRead.as_string(event["kind"]) != "script":
			continue
		var units: Dictionary = DictRead.as_dict(
			DictRead.as_dict(event["delta"])["units"])
		if not units.has(slot):
			continue
		var view: Dictionary = DictRead.as_dict(units[slot])
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			return true
	return false
