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
	scenery.free()
	overlay.free()
	quit(0)
