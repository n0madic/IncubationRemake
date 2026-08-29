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
	print("ai_turn_us=does_not_exist_yet")


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
