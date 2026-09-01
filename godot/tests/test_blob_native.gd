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
