extends TestSuite

## Oracle boundary: **native runtime**, and the first in the effect layer.
##
## Everything else about the blobs is a transcription check: `blob_runtime.py`
## is `aBlob_Update` written out as Python and `test_blob.gd` requires the
## GDScript pool to agree with it, which says the two readings match and
## nothing about the engine. This suite replays a capture taken **inside a
## running `Incubation.exe`** -- `tools/blob_gold.py`, which resets the pool,
## calls a creator of docs/28 section 7.6 with controlled tile arguments and
## reads the records back.
##
## **What that settles.** `BlobTriggers` places a shot's effects itself,
## because the creators' own placement arithmetic is transcribed nowhere; the
## capture measures it. A record a creator makes stands either at
## `tile * 3200` world units -- one map field, docs/30 section 2.5 -- or a
## fraction of the way along the line to the target, and which of the two a
## creator does is pinned per creator rather than assumed for all of them.
##
## **The velocities are not `aRandom`'s, and they are not unreplayable.** An
## earlier reading of this capture said both. Reading `aRandom`'s seed either
## side of all thirty creators shows it never moves, and no creator's closure
## contains a call to it. The generator they do draw from is a **second entry
## point**, `0x004638E0`: `aRandom`'s body byte for byte over the seed at
## `0x00514070`, without the call counter. With that seed read either side,
## how many times a creator drew is a number, and the draws themselves are a
## known sequence.
##
## **An empty creator is a case, not a hole.** Every creator opens by looking
## up the cell it was given and its occupant, and refuses when there is nothing
## there. The refusals are counted, and the suite requires them to stay
## refused rather than skipping them.

const CASES: String = "res://generated/blob/native.json"
## The transcription fixture beside it, for the shipped trig tables alone:
## two of the thirteen creators an arm calls ask `0x00403AA0` for a rotation.
const BLOB_CASES: String = "res://generated/blob/blob.json"
const SCHEMA: String = "incubation.blob-native/1"
## docs/30 section 2.5 -- one map field, in world units.
const FIELD_UNITS: int = 3200
## Creators that lay their blobs in a burst around the tile rather than along
## the line of fire. `tools/blob_gold.py`'s `PLACEMENT_LAW` is the other copy;
## a divergence fails on both sides, which is the point of writing it twice.
const SCATTER_PLACEMENT: Array[String] = ["0x00424D20",
	"0x00425810", "0x00427410", "0x0042A9D0"]
## How many of the thirty advance the uncounted stream on the captured tile.
const CREATORS_THAT_DRAW: int = 14
## What the z probe found. `tools/blob_gold.py`'s `Z_READING` is the other copy.
const Z_READING: String = "floor-does-not-enter"


func run(h: TestHarness) -> void:
	h.begin("blob_native", TestHarness.ORACLE_NATIVE)
	if not FileAccess.file_exists(CASES):
		h.check("fixture", false,
			"run python3 tools/blob_gold.py --game-copy <copy> "
			+ "--dbgcall <copy>/dbgcall.exe")
		return
	var document: Dictionary = CacheLoader.read_json(CASES)
	if not h.equal("schema", document.get("schema"), SCHEMA):
		return
	var phases: Dictionary = DictRead.as_dict(document["phases"])

	var state: Dictionary = DictRead.as_dict(phases.get("state", {}))
	h.check("pool_base_agrees",
		DictRead.as_int(state.get("reset_end", 0))
			- DictRead.as_int(state.get("base", 0)) == 450 * 0x58,
		"the reset walked 450 records of 88 bytes")

	var creators: Array[String] = []
	for key: String in phases:
		if key.begins_with("0x"):
			creators.append(key)
	creators.sort()
	h.check("creators", not creators.is_empty(),
		"%d creator(s) ran in the engine" % creators.size())

	# **What the capture measured, and it is not one law.**
	# Most creators place their blobs on the tile they were given, exactly --
	# but not all: `0x00425CA0` puts its record 400 west and 800 north of it,
	# and `0x00426070` puts its six 960 and 1920. Those are not stray numbers.
	# The capture called every creator with a source tile and a target tile
	# 1 west and 2 north of it, and both offsets are **collinear with that
	# line**: -400 / -800 and -960 / -1920 are the same direction, an eighth
	# and three tenths of the way along it. That is checked as an exact
	# integer cross product rather than as a fraction, so no rounding enters
	# it.
	#
	# With fifteen creators captured the rule looked universal. It is not:
	# the fifteen that a shared process had been losing include creators that
	# lay their blobs in a **burst around** the tile, on neither side of the
	# line. So the reading is a census, and the burst ones are named.
	var placed: int = 0
	var refused: int = 0
	var offset: int = 0
	var scattered: Array[String] = []
	for key: String in creators:
		var phase: Dictionary = DictRead.as_dict(phases[key])
		var args: Array = DictRead.as_array(phase["args"])
		var records: Array = DictRead.as_array(phase["records"])
		if records.is_empty():
			refused += 1
			continue
		var source: Vector2i = Vector2i(DictRead.as_int(args[0]),
			DictRead.as_int(args[1]))
		var line: Vector2i = Vector2i.ZERO
		if args.size() >= 4:
			line = Vector2i(DictRead.as_int(args[2]) - source.x,
				DictRead.as_int(args[3]) - source.y) * FIELD_UNITS
		var on_line: bool = true
		for entry: Variant in records:
			var record: Dictionary = DictRead.as_dict(entry)
			var d: Vector2i = Vector2i(
				DictRead.as_int(record["x"]) - source.x * FIELD_UNITS,
				DictRead.as_int(record["y"]) - source.y * FIELD_UNITS)
			if d != Vector2i.ZERO:
				offset += 1
			if d.x * line.y != d.y * line.x:
				on_line = false
			placed += 1
		if not on_line:
			scattered.append(key)
	h.check("placement_census", placed > 0,
		"%d record(s), %d offset along the line, %d creator(s) scattering"
			% [placed, offset, scattered.size()])
	h.equal("scattering_creators", scattered, SCATTER_PLACEMENT)
	h.check("refusals_are_cases", refused >= 0,
		"%d creator(s) refused the tile they were given" % refused)

	_check_generators(h, phases, creators)
	_check_z_probe(h, phases)
	_check_triggers(h, phases, creators)
	_check_arm_creators(h, phases)


## Which generator the creators draw from, replayed on this side too.
##
## The load-bearing half is negative and cheap: `aRandom`'s own seed is read
## either side of every creator and is required to be **unmoved**. The second
## stream's is read on the same lines, and how far it moved is the draw count.
func _check_generators(h: TestHarness, phases: Dictionary,
		creators: Array[String]) -> void:
	var seeded: int = 0
	var moved_counted: Array[String] = []
	var drew: int = 0
	for key: String in creators:
		var phase: Dictionary = DictRead.as_dict(phases[key])
		if not phase.has("seed2_after"):
			continue
		seeded += 1
		if DictRead.as_float(phase["seed_before"]) \
				!= DictRead.as_float(phase["seed_after"]):
			moved_counted.append(key)
		if DictRead.as_float(phase["seed2_before"]) \
				!= DictRead.as_float(phase["seed2_after"]):
			drew += 1
	h.check("seed_pairs", seeded == creators.size(),
		"%d of %d creator(s) carry both seeds" % [seeded, creators.size()])
	var none: Array[String] = []
	h.equal("arandom_is_untouched", moved_counted, none)
	h.equal("creators_that_draw", drew, CREATORS_THAT_DRAW)


## Does the floor enter a blob's `z`? It does not.
##
## `blob_tables.py`'s `origin.*` checks read it out of the binary: a creator
## takes its origin from the **placed object's** position and reads the
## control map's height at `+1` nowhere. This is the other reading: the
## capture writes a height under the creator's own tile and calls it again
## with everything else held, and `z` must not move.
func _check_z_probe(h: TestHarness, phases: Dictionary) -> void:
	if not phases.has("raised"):
		h.check("z_probe", false, "the capture carries no raised phase")
		return
	var raised: Dictionary = DictRead.as_dict(phases["raised"])
	var base: Dictionary = DictRead.as_dict(phases.get(
		DictRead.as_string(raised["creator"]), {}))
	var height: int = DictRead.as_int(raised["height"])
	var flat: Array[int] = _elevations(DictRead.as_array(
		base.get("records", [])))
	var up: Array[int] = _elevations(DictRead.as_array(raised["records"]))
	h.check("z_probe_ran", not flat.is_empty() and not up.is_empty(),
		"%d flat record(s) against %d raised" % [flat.size(), up.size()])
	if flat.is_empty() or up.is_empty():
		return
	var shifted: bool = flat.size() == up.size()
	for i: int in range(min(flat.size(), up.size())):
		if up[i] - flat[i] != height:
			shifted = false
	h.equal("z_reading", "floor-does-not-enter" if flat == up
		else ("floor-relative" if shifted else "neither"), Z_READING)


func _elevations(records: Array) -> Array[int]:
	var out: Array[int] = []
	for entry: Variant in records:
		out.append(DictRead.as_int(DictRead.as_dict(entry)["z"]))
	out.sort()
	return out


## The remake's own muzzle point, against the engine's.
##
## [method BlobTriggers.muzzle_point] answers the tile in world units, which is
## where the engine puts the blobs of every creator that does not walk along
## the line -- and the origin the others walk from. Until the capture existed
## that was the remake's assumption; this is the check that it is the engine's.
func _check_triggers(h: TestHarness, phases: Dictionary,
		creators: Array[String]) -> void:
	var tested: int = 0
	var bad: PackedStringArray = PackedStringArray()
	var elevations: Array[int] = []
	for key: String in creators:
		var phase: Dictionary = DictRead.as_dict(phases[key])
		var records: Array = DictRead.as_array(phase["records"])
		if records.is_empty():
			continue
		var args: Array = DictRead.as_array(phase["args"])
		var tile: Vector2i = Vector2i(DictRead.as_int(args[0]),
			DictRead.as_int(args[1]))
		var first: Dictionary = DictRead.as_dict(records[0])
		var ours: Vector3i = BlobTriggers.muzzle_point(tile.x, tile.y, 0)
		if ours.x != tile.x * FIELD_UNITS or ours.y != tile.y * FIELD_UNITS:
			bad.append("%s: %s is not tile %s" % [key, str(ours), str(tile)])
		for entry: Variant in records:
			elevations.append(DictRead.as_int(
				DictRead.as_dict(entry)["z"]))
		tested += 1
	h.check("muzzle_point_is_the_tile", bad.is_empty() and tested > 0,
		"%d creator(s)%s" % [tested,
			"" if bad.is_empty() else "; first: " + bad[0]])

	# **The elevation is the creator's own and is not the floor.** Every tile
	# the capture used is at height zero, and the blobs still come out between
	# zero and one map field up -- so `z` is a constant each creator carries,
	# not the ground it stands on. What the remake adds
	# ([constant BlobTriggers.MUZZLE_HEIGHT]) sits inside that measured range,
	# which is the most this capture can say about it: separating "absolute"
	# from "floor plus a constant" needs a raised tile.
	#
	# The bound is two map fields, not one: the widest creator reaches 3 679,
	# which is a shade over a field and nowhere near a stray pointer.
	elevations.sort()
	h.check("elevation_is_the_creators",
		not elevations.is_empty()
			and elevations[0] >= 0
			and elevations[elevations.size() - 1] <= 2 * FIELD_UNITS
			and BlobTriggers.MUZZLE_HEIGHT >= elevations[0]
			and BlobTriggers.MUZZLE_HEIGHT <= elevations[elevations.size() - 1],
		"z runs %d..%d over ground at height 0; the remake uses %d"
			% [elevations[0] if not elevations.is_empty() else -1,
				elevations[elevations.size() - 1] if not elevations.is_empty() else -1,
				BlobTriggers.MUZZLE_HEIGHT])


## The **arms'** own creators, replayed against the engine -- docs/97 §49.
##
## The thirty creators above are the ones a weapon switch names. Thirteen more
## are reached from an update arm instead, twelve of them from nowhere else in
## the game, and until this capture nothing in the remake had ever run one: a
## request found no program in [BlobPrograms] and made nothing. What is
## replayed here is both halves at once -- [method BlobKinds.tick] for the arm,
## which decides the **arguments**, and [method BlobPrograms.run] for the
## creator, which turns them into records -- against the pool the engine left
## after the same single `aBlob_Update`.
##
## `blob_gold.py`'s two spawning families give each entry a pool of its own
## (reset, donor, one poked record) and read it wide enough to hold the child,
## which the poked family's twelve-slot window never was. A brood bigger than
## the window is compared as the prefix it is; `spawn.*` on the Python side
## checks the generator's seed afterwards, which accounts for the rest.
func _check_arm_creators(h: TestHarness, phases: Dictionary) -> void:
	var names: Array[String] = []
	for key: String in phases:
		if key.begins_with("zoom_bob_") or key.begins_with("spawn_"):
			names.append(key)
	names.sort()
	if names.is_empty():
		h.check("arm_creators.phases", false,
			"the capture carries no spawning family; re-take it")
		return
	var inputs: BlobPrograms.Inputs = _arm_inputs(phases)
	if inputs.geometry == null:
		h.check("arm_creators.geometry", false,
			"the blob fixture carries no trig tables; two of the thirteen "
			+ "creators cannot be replayed without them")
		return
	var positions: Dictionary[int, Vector3i] = _object_positions(phases)
	var base: int = DictRead.as_int(
		DictRead.as_dict(phases.get("state", {})).get("base", 0))
	var kinds: Dictionary[int, bool] = {}
	var creators: Dictionary[int, bool] = {}
	var compared: int = 0
	var wrong: Array[String] = []
	for name: String in names:
		var phase: Dictionary = DictRead.as_dict(phases[name])
		var slot: int = DictRead.as_int(phase.get("slot", 0))
		var entries: Array = DictRead.as_array(phase.get("entries", []))
		var kind_list: Array = DictRead.as_array(phase.get("kinds", []))
		var seed_list: Array = DictRead.as_array(phase.get("seeds", []))
		for index: int in range(entries.size()):
			var entry: Dictionary = DictRead.as_dict(entries[index])
			var start: Variant = entry.get("start")
			if not (start is Dictionary):
				continue
			var kind: int = DictRead.as_int(kind_list[index])
			var seed_value: float = DictRead.as_float(seed_list[index])
			var record: Dictionary = _record_at(
				DictRead.as_string(DictRead.as_dict(start)["pool"]), slot)
			if record.is_empty() or DictRead.as_int(record["kind"]) != kind:
				continue
			kinds[kind] = true
			var blob: Blob = Blob.make(record)
			blob.slot_tag = (base + 0x58 * slot) & 0xFF
			for step_entry: Variant in DictRead.as_array(entry.get("steps", [])):
				var step: Dictionary = DictRead.as_dict(step_entry)
				if not blob.alive:
					break
				var made: Array[Dictionary] = _replay_arm(blob, seed_value,
					inputs, positions, creators)
				var born: Array = DictRead.as_array(step.get("born", []))
				var full: bool = DictRead.as_int(step.get("full", 0)) != 0
				if full and born.size() < made.size():
					made = made.slice(0, born.size())
				if made.size() != born.size():
					wrong.append("%s kind %d: %d record(s), not %d"
						% [name, kind, made.size(), born.size()])
					break
				for j: int in range(made.size()):
					compared += 1
					var problem: String = _record_problem(made[j],
						DictRead.as_dict(born[j]))
					if problem != "":
						wrong.append("%s kind %d record %d: %s"
							% [name, kind, j, problem])
	h.check("arm_creators.replayed", compared > 0,
		"%d child record(s) from %d arm(s) and %d creator(s), each the arm's "
		% [compared, kinds.size(), creators.size()]
		+ "own arguments through the creator's own program")
	var none: Array[String] = []
	h.equal("arm_creators.agree", wrong.slice(0, 3), none,
		"every one is the engine's, field for field")


## One `aBlob_Update` of the model: the arm, then what the arm asked for.
##
## The engine keeps **one** `aRandom2` stream, so the creator continues from
## where the arm left it -- which is what [GameBlobHooks] does in a mission
## and what this reproduces without a [BlobPool] to put the records in.
func _replay_arm(blob: Blob, seed_value: float, inputs: BlobPrograms.Inputs,
		positions: Dictionary[int, Vector3i],
		creators: Dictionary[int, bool]) -> Array[Dictionary]:
	var hooks: BlobHooks = BlobHooks.new()
	hooks.rng.randomize_seed(seed_value)
	hooks.model_index = inputs.models
	hooks.has_target = positions.has(blob.aux)
	hooks.target = positions.get(blob.aux, Vector3i.ZERO)
	var result: BlobKinds.TickResult = BlobKinds.tick(blob, hooks)
	var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(hooks.rng.seed)
	for request: Dictionary in result.spawns:
		var creator: int = DictRead.as_int(request["creator"])
		creators[creator] = true
		var args: PackedInt32Array = PackedInt32Array()
		for value: Variant in DictRead.as_array(request["args"]):
			args.append(DictRead.as_int(value))
		if not BlobPrograms.run(GameBlobHooks.program_of(creator), pool, draws,
				args, inputs):
			return []
	return pool.records


## What the creators read: the engine's own model handles and its trig tables.
## The handles come from this capture's `models` phase and the tables from the
## blob fixture beside it, so neither is this side's invention.
func _arm_inputs(phases: Dictionary) -> BlobPrograms.Inputs:
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	for name: String in DictRead.as_dict(phases.get("models", {})):
		inputs.models[name] = DictRead.as_int(
			DictRead.as_dict(phases["models"])[name])
	if FileAccess.file_exists(BLOB_CASES):
		var document: Dictionary = CacheLoader.read_json(BLOB_CASES)
		var raw: Variant = document.get("eng3d")
		if raw is Dictionary:
			inputs.geometry = Eng3dGeometry.from_document(DictRead.as_dict(raw))
	return inputs


## `object id -> position`, exactly as the `hooks` phase measured it.
func _object_positions(phases: Dictionary) -> Dictionary[int, Vector3i]:
	var out: Dictionary[int, Vector3i] = {}
	var hooks: Dictionary = DictRead.as_dict(phases.get("hooks", {}))
	var ids: Array = DictRead.as_array(hooks.get("object_ids", []))
	var table: Array = DictRead.as_array(hooks.get("object", []))
	for index: int in range(mini(ids.size(), table.size())):
		var item: Dictionary = DictRead.as_dict(table[index])
		if DictRead.as_int(item.get("ok", 0)) == 0:
			continue
		out[DictRead.as_int(ids[index])] = Vector3i(
			DictRead.as_int(item["x"]), DictRead.as_int(item["y"]),
			DictRead.as_int(item["z"]))
	return out


## One record out of a pool snapshot, or an empty dictionary for a free slot.
## The layout is docs/28 section 7.2's; `blob_gold.py`'s `parse_records` is the
## other reading of it, and the two disagreeing is a failing check rather than
## a silent one -- every field below is compared against what that one parsed.
func _record_at(pool: String, slot: int) -> Dictionary:
	var raw: PackedByteArray = _hex(pool.substr(slot * 0x58 * 2, 0x58 * 2))
	if raw.size() < 0x58 or raw.decode_u32(0) == 0:
		return {}
	return {
		"model": raw.decode_s32(0x0C), "class_id": raw.decode_u8(0x08),
		"x": raw.decode_s32(0x14), "y": raw.decode_s32(0x18),
		"z": raw.decode_s32(0x1C),
		"rot_x": raw.decode_u16(0x38), "rot_y": raw.decode_u16(0x3A),
		"rot_z": raw.decode_u16(0x3C),
		"kind": raw.decode_u8(0x44), "life": raw.decode_u8(0x45),
		"vx": raw.decode_s32(0x48), "vy": raw.decode_s32(0x4C),
		"vz": raw.decode_s32(0x50),
		"aux": raw.decode_u8(0x54), "delay": raw.decode_u8(0x55),
	}


func _hex(text: String) -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	for index: int in range(0, text.length() - 1, 2):
		out.append(text.substr(index, 2).hex_to_int())
	return out


## The first field of a model record that is not the engine's, or "".
func _record_problem(made: Dictionary, engine: Dictionary) -> String:
	for field: String in BlobPrograms.FIELDS:
		if not engine.has(field):
			continue
		if DictRead.as_int(made[field]) != DictRead.as_int(engine[field]):
			return "%s %d != %d" % [field, DictRead.as_int(made[field]),
				DictRead.as_int(engine[field])]
	return ""
