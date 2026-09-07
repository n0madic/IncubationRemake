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
	_campaign_container(h)
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

	# The scenery's pose record rides beside the camera on the same terms
	# (docs/42 section 8.3): stored, narrowed on the way back, and outside
	# the hash. `core` never reads it; `game` restores the picture from it.
	h.equal("scenery.absent_by_default", camera_world.restored_scenery(), {},
		"a save written without a record loads one back empty")
	var poses: Dictionary = {"joints": [[3, 6, 969, 0, 0], [5, 12, 0, 0, -1000]],
		"removed": [2], "moves": [[7, 0, 11]]}
	var blob_c: PackedByteArray = world.save(camera, poses)
	var scenery_world: World = TestFixtures.tiny_world()
	h.equal("scenery.decode_ok",
		SaveCodec.result_name(scenery_world.load_save(blob_c)), "OK")
	var poses_back: Dictionary = scenery_world.restored_scenery()
	var rows: Array = DictRead.as_array(poses_back.get("joints", []))
	h.equal("scenery.restored.rows", rows.size(), 2)
	h.equal("scenery.restored.first_row",
		str(DictRead.to_int32(rows[0])) if rows.size() > 0 else "",
		str(PackedInt32Array([3, 6, 969, 0, 0])),
		"the record comes back through the JSON header as floats and narrows")
	h.equal("scenery.restored.removed",
		str(DictRead.to_int32(poses_back.get("removed", []))),
		str(PackedInt32Array([2])))
	var moves: Array = DictRead.as_array(poses_back.get("moves", []))
	h.equal("scenery.restored.moves",
		str(DictRead.to_int32(moves[0])) if moves.size() == 1 else "",
		str(PackedInt32Array([7, 0, 11])),
		"a platform ride's row comes back the same way")
	h.equal("scenery.excluded_from_hash", scenery_world.canonical_hash_hex(),
		before)
	h.check("scenery.differs", blob_c != blob,
		"the two saves differ, so the record really is stored")

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


## The campaign container -- a save **over** [SaveCodec] (D10).
##
## [SaveCodec] refuses a blob whose map name is not the world's, which is
## exactly right for a mission save and exactly wrong for a campaign: the whole
## point is that the campaign outlives the mission. So a mission save rides
## inside as an opaque blob, and the container's own four refusals are
## [SaveCodec]'s shape -- four different answers, not one `null`.
func _campaign_container(h: TestHarness) -> void:
	var state: CampaignState = CampaignState.begin(1, 10, 5, 7,
		PackedStringArray(["Bratt", "West", "Maxon"]))
	state.mission = "_C_105"
	state.difficulty = 2
	state.set_points(0, 4321)
	state.scoreboard[0].total = 119
	state.scoreboard[0].campaign_kills = 25
	state.roster.snapshot()
	state.roster.clear(1)
	var digest: String = state.digest_hex()

	# A mission in progress rides inside, and comes back byte for byte.
	var world: World = TestFixtures.tiny_world()
	var blob: PackedByteArray = world.save({})
	var container: PackedByteArray = CampaignCodec.encode(state, blob)
	var decoded: Dictionary = CampaignCodec.decode(container)
	h.equal("campaign_save.round_trip", DictRead.as_int(decoded["result"]),
		CampaignCodec.Result.OK)
	var back: CampaignState = decoded["state"]
	h.equal("campaign_save.digest", back.digest_hex(), digest,
		"campaign, mission, purse, roster, snapshot and scoreboard")
	h.equal("campaign_save.mission_blob", DictRead.to_bytes(decoded["mission"]),
		blob, "opaque to the container, and unchanged by it")
	h.equal("campaign_save.rows",
		[back.roster.used_slots(Roster.ROW_LIVE),
		back.roster.used_slots(Roster.ROW_SNAPSHOT)], [2, 3],
		"the live row lost a slot; the entry snapshot did not")

	# The nested blob still goes through `SaveCodec`, which is what checks the
	# map: a campaign that changed mission carries a blob for the old one.
	var reloaded: World = TestFixtures.tiny_world()
	h.equal("campaign_save.mission_still_checked",
		reloaded.load_save(DictRead.to_bytes(decoded["mission"])),
		SaveCodec.Result.OK)
	var wrong_map: World = TestFixtures.other_world()
	h.equal("campaign_save.other_map_refused",
		wrong_map.load_save(DictRead.to_bytes(decoded["mission"])),
		SaveCodec.Result.MAP_MISMATCH,
		"the container carries the blob; SaveCodec still owns the map check")

	# A campaign between missions carries no blob at all.
	var between: Dictionary = CampaignCodec.decode(CampaignCodec.encode(state))
	h.equal("campaign_save.no_mission",
		DictRead.to_bytes(between["mission"]).size(), 0)

	# The four refusals.
	h.equal("campaign_save.truncated",
		DictRead.as_int(CampaignCodec.decode(
			PackedByteArray([1, 2, 3]))["result"]),
		CampaignCodec.Result.TRUNCATED)
	var magic: PackedByteArray = container.duplicate()
	magic[1] = 0x58
	h.equal("campaign_save.bad_magic",
		DictRead.as_int(CampaignCodec.decode(magic)["result"]),
		CampaignCodec.Result.BAD_MAGIC)
	var torn: PackedByteArray = container.duplicate()
	torn[container.size() - 2] ^= 0xFF
	h.equal("campaign_save.bad_digest",
		DictRead.as_int(CampaignCodec.decode(torn)["result"]),
		CampaignCodec.Result.BAD_DIGEST)
	# `BAD_SCHEMA` is reachable only from a **newer** writer, so it needs one:
	# the schema dword is inside the digest, and flipping it alone reports
	# corruption instead. This builds the save a future version would write.
	var ahead: PackedByteArray = _reschemad(state, CampaignCodec.SCHEMA_VERSION + 1)
	h.equal("campaign_save.bad_schema",
		DictRead.as_int(CampaignCodec.decode(ahead)["result"]),
		CampaignCodec.Result.BAD_SCHEMA,
		"a save from a build this one does not speak")


## What a writer one schema ahead would produce: the same layout, a different
## version dword, and a digest that matches it.
func _reschemad(state: CampaignState, version: int) -> PackedByteArray:
	var document: PackedByteArray = JSON.stringify(
		state.view(), "", true, true).to_utf8_buffer()
	var body: PackedByteArray = PackedByteArray()
	body.append_array(PackedInt32Array([version, document.size(),
		0]).to_byte_array())
	body.append_array(document)
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(body)
	var out: PackedByteArray = CampaignCodec.MAGIC.to_utf8_buffer()
	out.append_array(body)
	out.append_array(ctx.finish())
	return out
