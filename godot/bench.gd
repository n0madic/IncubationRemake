extends SceneTree

## The measurements docs/92 section 10.4 asks for, taken in a real load.
##
##     godot --headless --path godot --script res://bench.gd

const RUNS: int = 20


func _initialize() -> void:
	var t0: int = Time.get_ticks_usec()
	var loaded: Dictionary = CacheFixture.load_slice_world()
	var t1: int = Time.get_ticks_usec()
	if loaded.is_empty():
		print("no cache")
		quit(1)
		return
	var world: World = loaded["world"]
	var document: Dictionary = loaded["document"]
	print("cache_dir=", CacheFixture.cache_dir())
	print("load_and_world_us=", t1 - t0)

	var manifest: Dictionary = CacheFixture.manifest()
	var t2: int = Time.get_ticks_usec()
	var problems: PackedStringArray = CacheLoader.verify(
		CacheFixture.cache_dir(), manifest)
	print("verify_us=", Time.get_ticks_usec() - t2,
		" problems=", problems.size())

	var header: Dictionary = DictRead.as_dict(document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	var geometry: Dictionary = CacheFixture.geometry(world_set)
	var index: Dictionary = CacheFixture.texture_index(world_set)
	var t3: int = Time.get_ticks_usec()
	var textures: Dictionary = MeshBuilder.load_textures(
		CacheFixture.cache_dir(), world_set, index)
	print("textures_us=", Time.get_ticks_usec() - t3, " n=", textures.size())

	var scenery: Scenery = Scenery.new()
	var t4: int = Time.get_ticks_usec()
	scenery.build(document, geometry, textures)
	print("scenery_us=", Time.get_ticks_usec() - t4,
		" instances=", scenery.built_count())

	var overlay: TerrainOverlay = TerrainOverlay.new()
	var t5: int = Time.get_ticks_usec()
	overlay.build(world.terrain_snapshot())
	print("overlay_us=", Time.get_ticks_usec() - t5,
		" cells=", world.resource.cell_count())

	var slot: int = world.unit_slots()[0]
	var command: MoveQueryCommand = MoveQueryCommand.create(slot, false)
	var _warm: MoveMapResult = world.submit_move_query(command)
	var t6: int = Time.get_ticks_usec()
	for _i: int in range(RUNS):
		var _r: MoveMapResult = world.submit_move_query(command)
	print("move_map_us_each=", float(Time.get_ticks_usec() - t6) / float(RUNS))

	var t7: int = Time.get_ticks_usec()
	for _i: int in range(RUNS):
		var _h: String = world.canonical_hash_hex()
	print("canonical_hash_us_each=",
		float(Time.get_ticks_usec() - t7) / float(RUNS))

	var t8: int = Time.get_ticks_usec()
	var blob: PackedByteArray = world.save({"yaw_step": 0, "zoom": 20.0})
	print("save_us=", Time.get_ticks_usec() - t8, " bytes=", blob.size())
	var again: Dictionary = CacheFixture.load_slice_world()
	var reloaded: World = again["world"]
	var t9: int = Time.get_ticks_usec()
	var code: int = reloaded.load_save(blob)
	print("load_save_us=", Time.get_ticks_usec() - t9,
		" result=", SaveCodec.result_name(code))
	_turn_measurements()
	_body_measurements("_C_140")
	_body_measurements("_C_132")
	scenery.free()
	overlay.free()
	quit(0)


## The second slice's own measurements, on `_C_140` -- the mission it plays.
##
## Taken on the mission with its program attached, because a hand-over *runs*
## the program twice and the cost of the script is part of the cost of a turn.
func _turn_measurements() -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		print("no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	print("mission=_C_140 cells=", world.resource.cell_count(),
		" units=", world.unit_slots().size())

	var utab: UnitTypeTable = world.unit_types()
	var wtab: WeaponTable = world.weapons()
	# The fog pass, on a roster of its own: it writes `+0x4F`, so running it
	# against the world's own units would time something slightly different
	# every round.
	Visibility.build(world.state, _roster(world), utab, 0, 1, 1)
	var t0: int = Time.get_ticks_usec()
	for _i: int in range(RUNS):
		Visibility.build(world.state, _roster(world), utab, 0, 1, 1)
	print("visibility_us_each=", float(Time.get_ticks_usec() - t0)
		/ float(RUNS))

	# One line of sight and one hit probability, over every ordered enemy pair.
	var roster: Dictionary = _roster(world)
	var pairs: int = 0
	var t1: int = Time.get_ticks_usec()
	for a: int in world.unit_slots():
		for b: int in world.unit_slots():
			if a == b:
				continue
			var attacker: UnitState = roster[a]
			var defender: UnitState = roster[b]
			var _chance_of: HitChance = HitChance.compute(world.state, roster,
				utab, wtab, attacker, defender, attacker.weapon, true, 1, 1)
			pairs += 1
	print("hit_probability_us_each=",
		float(Time.get_ticks_usec() - t1) / float(maxi(pairs, 1)),
		" pairs=", pairs)

	# One `NEXT PLAYER` of the mission's own program.
	var env: Dictionary = MissionScript.env(MissionScript.CALL_NEXT_PLAYER, 5,
		0)
	var _warm_script: Dictionary = world.run_script(
		MissionScript.CALL_NEXT_PLAYER, env)
	var t2: int = Time.get_ticks_usec()
	for _i: int in range(RUNS):
		var _out: Dictionary = world.run_script(
			MissionScript.CALL_NEXT_PLAYER, env)
	print("next_player_script_us_each=",
		float(Time.get_ticks_usec() - t2) / float(RUNS))

	# A whole hand-over: the rotation, the refresh of every unit, the two
	# script runs and the fog pass.
	var handovers: int = 0
	var t3: int = Time.get_ticks_usec()
	for _i: int in range(RUNS):
		var result: TurnResult = world.submit_end_turn(
			EndTurnCommand.create())
		if result.code == TurnResult.OK:
			handovers += 1
	print("hand_over_us_each=", float(Time.get_ticks_usec() - t3)
		/ float(RUNS), " ok=", handovers)

	# A shot, resolved end to end. Destructive, so it runs on a fresh world.
	var arena: World = CacheFixture.load_mission("_C_140")["world"]
	var shooter: int = -1
	var target: int = -1
	for slot: int in arena.unit_slots():
		var view: Dictionary = arena.unit_view(slot)
		if DictRead.as_int(view["player"]) == 0 and shooter < 0:
			shooter = slot
		elif DictRead.as_int(view["player"]) == UnitState.PLAYER_ALIEN \
				and target < 0:
			target = slot
	if shooter < 0 or target < 0:
		print("no shooter/target pair")
		return
	var aim: Dictionary = arena.unit_view(target)
	var t4: int = Time.get_ticks_usec()
	for _i: int in range(RUNS):
		var _shot: AttackResult = arena.submit_attack(AttackCommand.create(
			shooter, DictRead.as_int(aim["x"]), DictRead.as_int(aim["y"])))
	print("attack_us_each=", float(Time.get_ticks_usec() - t4) / float(RUNS))
	_ai_measurements("_C_140")
	_ai_measurements("_C_132")


## A fresh roster of [UnitState]s from the world's own views.
##
## The fog pass writes `+0x4F`, so measuring it against the world's own units
## would leave the world in a different state after each run and time something
## slightly different every time.
func _roster(world: World) -> Dictionary:
	var out: Dictionary = {}
	for slot: int in world.unit_slots():
		out[slot] = UnitState.from_view(world.unit_view(slot))
	return out


## The measurement docs/92 section 2 has been waiting for since the first day:
## **a complete computer turn.**
##
## Two missions -- `_C_140`, which the slice demonstrates (20x20), and
## `_C_132`, the corpus worst case by live aliens times cells (40x40, 39
## aliens). Driven through [method AISystem.run] rather than through
## [method World.submit_end_turn]: the planner is what is being measured, not
## the rotation, the two script runs and the fog pass, which
## [method _turn_measurements] already timed separately.
##
## The turn is **destructive** -- it moves and kills units and draws from the
## generator -- so every repetition runs against a freshly loaded mission, and
## the load happens **outside** the timed region rather than being subtracted
## from it.
func _ai_measurements(mission: String) -> void:
	var probe: Dictionary = CacheFixture.load_mission(mission)
	if probe.is_empty():
		print("no ", mission, " in the cache")
		return
	var probe_world: World = probe["world"]
	var aliens: int = 0
	for slot: int in probe_world.unit_slots():
		var view: Dictionary = probe_world.unit_view(slot)
		if DictRead.as_int(view["player"]) == UnitState.PLAYER_ALIEN \
				and DictRead.as_int(view["hp"]) > 0:
			aliens += 1
	print("ai_mission=", mission, " cells=", probe_world.resource.cell_count(),
		" live_aliens=", aliens)

	var work: Dictionary = {}
	var sweeps: int = 0
	var events: int = 0
	var dispatches: int = 0
	var spent: int = 0
	for _i: int in range(AI_RUNS):
		var ctx: AIContext = _fresh_context(mission)
		var t: int = Time.get_ticks_usec()
		var result: AITurnResult = AISystem.run(ctx, UnitState.PLAYER_ALIEN)
		spent += Time.get_ticks_usec() - t
		work = result.work
		sweeps = result.sweeps
		events = result.events.size()
		dispatches = 0
		for order: Variant in result.orders_seen:
			dispatches += DictRead.as_int(result.orders_seen[order])
	print("ai_turn_us_each=", float(spent) / float(AI_RUNS))
	print("ai_turn_sweeps=", sweeps, " events=", events, " work=", work,
		" order_dispatches=", dispatches)

	# One of each of the three things a turn is made of, so the shares above
	# can be read as time and not only as counts. The plan and the fire are
	# **destructive** -- one commits a move, the other spends ammunition -- so
	# they get a fresh mission each, like the turn.
	var fill_ctx: AIContext = _fresh_context(mission)
	var first: UnitState = _first_alien(fill_ctx)
	if first == null:
		print("no live alien in ", mission)
		return
	var t_fill: int = Time.get_ticks_usec()
	for _i: int in range(RUNS):
		fill_ctx.reset_overlay()
		var _built: bool = AIPlan.build_move_map(fill_ctx, first, 0)
	print("ai_fill_us_each=", float(Time.get_ticks_usec() - t_fill)
		/ float(RUNS))

	var overlay_ctx: AIContext = _fresh_context(mission)
	var aimer: UnitState = _first_alien(overlay_ctx)
	var t_overlay: int = Time.get_ticks_usec()
	for _i: int in range(RUNS):
		overlay_ctx.reset_overlay()
		var _stamped: bool = AIOverlay.build(overlay_ctx, aimer,
			overlay_ctx.turn.human_count(), overlay_ctx.turn.mode)
	print("ai_target_overlay_us_each=",
		float(Time.get_ticks_usec() - t_overlay) / float(RUNS))

	var plan_us: int = 0
	var fire_us: int = 0
	for _i: int in range(AI_RUNS):
		var pctx: AIContext = _fresh_context(mission)
		var mover: UnitState = _first_alien(pctx)
		var t0: int = Time.get_ticks_usec()
		var _planned: bool = AIPlan.run(pctx, mover, AIPlan.KIND_ENEMY, 0, 0)
		plan_us += Time.get_ticks_usec() - t0
		var fctx: AIContext = _fresh_context(mission)
		var shooter: UnitState = _first_alien(fctx)
		var t1: int = Time.get_ticks_usec()
		var _fired: bool = AIFire.run(fctx, shooter)
		fire_us += Time.get_ticks_usec() - t1
	print("ai_plan_us_each=", float(plan_us) / float(AI_RUNS),
		" ai_fire_us_each=", float(fire_us) / float(AI_RUNS))


## A context on a freshly loaded mission, built the way [World] builds one.
func _fresh_context(mission: String) -> AIContext:
	var loaded: Dictionary = CacheFixture.load_mission(mission)
	var world: World = loaded["world"]
	world.turn.current_player = UnitState.PLAYER_ALIEN
	return AIContext.create(world.state, world.units_for_ai(),
		world.unit_types(), world.weapons(), world.ctrlmap(), world.turn,
		world.rng)


## The lowest-numbered live alien slot -- the one the sweep would reach first.
func _first_alien(ctx: AIContext) -> UnitState:
	var slots: Array = ctx.units.keys()
	slots.sort()
	for slot: Variant in slots:
		var unit: UnitState = ctx.units[slot]
		if unit.player == UnitState.PLAYER_ALIEN and unit.hp > 0:
			return unit
	return null


## Fewer than [constant RUNS]: a turn on `_C_132` is three orders of magnitude
## more expensive than a move map, and each repetition reloads the mission.
const AI_RUNS: int = 10


## The fourth slice's own: what a body costs to build and to pose.
##
## Taken **before** the state machine exists, so that "what gets cut first" is
## still a live option if the numbers say so (the plan's risk 5). A body is up
## to 130 meshed parts on the large models and about 26 on a marine, and a map
## holds up to 200 unit slots.
func _body_measurements(mission: String) -> void:
	var loaded: Dictionary = CacheFixture.load_mission(mission)
	if loaded.is_empty():
		print("bodies mission=", mission, " not in the cache")
		return
	var world: World = loaded["world"]
	var document: Dictionary = loaded["document"]
	var world_set: String = DictRead.as_string(
		DictRead.as_dict(document["header"])["world_set"])
	var textures: Dictionary = MeshBuilder.load_textures(
		CacheFixture.cache_dir(), world_set,
		CacheFixture.texture_index(world_set))

	var t0: int = Time.get_ticks_usec()
	var library: CharismaLibrary = CharismaLibrary.open(
		CacheFixture.cache_dir(), textures)
	print("bodies mission=", mission, " library_open_us=",
		Time.get_ticks_usec() - t0, " ready=", library.is_ready())
	if not library.is_ready():
		return

	# Every body the mission's own units select, built once each -- which is
	# what the game does, because `CharismaLibrary` shares a mesh between the
	# units that draw it.
	var built: Array[CharismaBody] = []
	var clips: Array[CharismaClip] = []
	var parts: int = 0
	var t1: int = Time.get_ticks_usec()
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty():
			continue
		var type_id: int = DictRead.as_int(view["type_id"])
		var weapon: int = DictRead.as_int(view["weapon"])
		var player: int = DictRead.as_int(view["player"])
		var model: CharismaModel = library.model(library.name_for(
			CharismaLibrary.SELECTOR_MODEL, type_id, weapon, player))
		if model == null:
			continue
		var body: CharismaBody = CharismaBody.create(model, library)
		if body == null:
			continue
		built.append(body)
		parts += body.part_count()
		clips.append(library.clip(library.name_for(
			CharismaLibrary.SELECTOR_IDLE, type_id, weapon, player)))
	var build_us: int = Time.get_ticks_usec() - t1
	print("bodies mission=", mission, " n=", built.size(), " parts=", parts,
		" build_total_us=", build_us, " build_each_us=",
		0.0 if built.is_empty() else float(build_us) / float(built.size()))

	# One frame: pose and place every body, which is what `_process` would do.
	var frames: int = 30
	var t2: int = Time.get_ticks_usec()
	for f: int in range(frames):
		for i: int in range(built.size()):
			built[i].pose(clips[i], float(f))
	var frame_us: float = float(Time.get_ticks_usec() - t2) / float(frames)
	print("bodies mission=", mission, " frame_us=", frame_us,
		" per_body_us=",
		0.0 if built.is_empty() else frame_us / float(built.size()),
		" budget_16667us_headroom=", 16667.0 / maxf(frame_us, 0.001), "x")
	for body: CharismaBody in built:
		body.free()
