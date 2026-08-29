extends TestSuite

## Oracle boundary: specification-only.  docs/92 section 10.3 items 3 and 4.
##
## The save is the remake's own format and never a superset of the original's
## (docs/92 section 7.3).  Four things are required of it here: a round trip
## preserves the canonical simulation hash, the camera travels with the save but
## does not affect that hash, and the three negative cases fail cleanly with a
## named reason rather than by loading something wrong.

func run(h: TestHarness) -> void:
	h.begin("save", TestHarness.ORACLE_SPEC)
	var world: World = TestFixtures.tiny_world()

	# Move the simulation off its initial state, so a round trip that silently
	# rebuilt from the authored map would be caught.
	world.state.set_height(0, 12345)
	world.state.set_field_type(1, 5)
	world.state.set_obstacle(2, MapState.OBSTACLE_MINE)
	world.state.set_effect(0, 3, 7)
	world.rng.randomize_seed(1.0)
	var _drawn: int = world.rng.draw(0, 100)
	world.compat_flags = PackedStringArray(["technical_box_bug"])

	# `cell[+0x10]` is effect slot 2 and nothing else.  It used to be modelled
	# twice -- a synthesised `_obstacle` array and `_effect[2]` -- so writing a
	# mine left the two disagreeing about one documented field and the hash
	# committed both.
	h.equal("obstacle.is_effect_slot_2",
		world.state.effect_at(MapState.OBSTACLE_SLOT, 2),
		MapState.OBSTACLE_MINE,
		"set_obstacle and set_effect(2, ...) are the same storage")
	world.state.set_effect(MapState.OBSTACLE_SLOT, 4, MapState.OBSTACLE_FIRE)
	h.equal("obstacle.reads_back", world.state.obstacle_at(4),
		MapState.OBSTACLE_FIRE)
	var snap: Dictionary = world.terrain_snapshot()
	var effects: Array = snap["effect"]
	h.equal("obstacle.snapshot_agrees",
		str(DictRead.to_bytes(effects[MapState.OBSTACLE_SLOT])),
		str(DictRead.to_bytes(snap["obstacle"])),
		"the snapshot's two names for the byte carry the same bytes")

	var before: String = world.canonical_hash_hex()
	var camera: Dictionary = {"yaw": 90, "zoom": 17.5, "pivot": [3, 4]}
	var blob: PackedByteArray = world.save(camera)
	h.check("encode.size", blob.size() > 0, "%d bytes" % blob.size())

	var reloaded: World = TestFixtures.tiny_world()
	h.equal("decode.ok", SaveCodec.result_name(reloaded.load_save(blob)), "OK")
	h.equal("round_trip.hash", reloaded.canonical_hash_hex(), before)

	# The camera is stored beside the simulation and excluded from its hash.
	var other_camera: Dictionary = {"yaw": 270, "zoom": 4.0, "pivot": [0, 0]}
	var blob_b: PackedByteArray = world.save(other_camera)
	var camera_world: World = TestFixtures.tiny_world()
	h.equal("camera.decode_ok",
		SaveCodec.result_name(camera_world.load_save(blob_b)), "OK")
	# The camera rides in the JSON header, so every number comes back a
	# `float` -- the same narrowing rule the cache loader follows.  Comparing
	# the dictionaries as strings would be comparing that, not the values.
	var back: Dictionary = camera_world.restored_camera()
	h.equal("camera.restored.yaw", DictRead.as_int(back["yaw"]), 270,
		"the stored camera comes back rather than being dropped on the floor")
	h.equal("camera.restored.zoom", DictRead.as_float(back["zoom"]), 4.0)
	h.equal("camera.restored.pivot",
		str(DictRead.to_int32(back["pivot"])), str(PackedInt32Array([0, 0])))
	h.equal("camera.excluded_from_hash", camera_world.canonical_hash_hex(),
		before)
	h.check("camera.differs", blob != blob_b,
		"the two saves differ, so the camera really is stored")

	# Negative cases.
	var truncated: PackedByteArray = blob.slice(0, blob.size() / 2)
	h.equal("negative.truncated",
		SaveCodec.result_name(TestFixtures.tiny_world().load_save(truncated)),
		"TRUNCATED")

	var wrong_schema: PackedByteArray = blob.duplicate()
	wrong_schema[4] = 99
	h.equal("negative.bad_schema",
		SaveCodec.result_name(
			TestFixtures.tiny_world().load_save(wrong_schema)),
		"BAD_SCHEMA")

	var corrupted: PackedByteArray = blob.duplicate()
	corrupted[corrupted.size() - 1] = corrupted[corrupted.size() - 1] ^ 0xFF
	h.equal("negative.bad_digest",
		SaveCodec.result_name(TestFixtures.tiny_world().load_save(corrupted)),
		"BAD_DIGEST")

	# A save paired with a different authored map is refused by name.
	var other: World = TestFixtures.other_world()
	h.equal("negative.map_mismatch",
		SaveCodec.result_name(other.load_save(blob)), "MAP_MISMATCH")
	h.check("negative.map_mismatch_left_alone",
		other.canonical_hash_hex() != before,
		"a refused save changes nothing")
