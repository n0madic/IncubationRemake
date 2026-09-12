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
## 2026-09-12: `0x00426070` joined them. Its phase was re-taken with weapon
## 44's own 0xFF -- the **proximity** round, which draws three offsets and
## scatters the aim point off the line before the direction is taken. A fixed
## arc, 0 to 5, would have stayed on it.
const SCATTER_PLACEMENT: Array[String] = ["0x00424D20", "0x00425810",
	"0x00426070", "0x00427410", "0x00429F40", "0x0042A9D0"]
## How many of the thirty advance the uncounted stream on the captured tile.
## 17 since 2026-09-12: `0x00426070` and `0x00427C80` reach a generator only on
## the arm their real tail selects, and both tails landed that day.
const CREATORS_THAT_DRAW: int = 17
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
	_check_weapon_creators(h, phases)
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


## The **weapon switches'** own creators, replayed against the engine.
##
## The thirty a weapon selects were the ones nothing in the remake ever ran:
## [method BlobTriggers._fire] built one record per constructor call site and
## gave it a straight line of its own, so a creator whose loop lays sixty
## records came out as one sprite (docs/97 §14.5). They are being transcribed
## one at a time into [BlobPrograms], and this is the check that a
## transcription is the engine's rather than a plausible shape.
##
## Two halves. `weapon_programs` runs each program **directly**, with the
## capture's own argument vector and the same inputs `blob_gold.py` hands the
## Python twin -- the two symbol objects, the two unit heights, the target
## cell's unit id, the engine's model handles and its trig tables -- so what
## is compared is the creator alone. `weapon_creators` then drives one of them
## the whole way through [method BlobTriggers.muzzle], from the switch down,
## which is the check on the **seam** rather than on the arithmetic.
##
## The capture's window is twelve records, so a wider creator is compared over
## the prefix it holds **plus the generator's seed afterwards**, which
## accounts for every draw the rest of the loop took.
const WEAPON_PROGRAMS: Array[String] = ["0x00420A50", "0x00424D20",
	"0x004227C0",
	"0x004264A0", "0x00425810", "0x00426F90", "0x00427410", "0x00427810",
	"0x00429180", "0x004294E0", "0x004295D0", "0x00429A80", "0x00429F40",
	"0x0042A9D0", "0x0042ACF0", "0x0042AF10",
	# 2026-09-12: the fire wheel and the mine plume, which came off
	# `blob_gold.PROGRAM_ARGS_STALE` on a *reading* rather than on a capture.
	# Both load `[esp+4]` and `[esp+8]` in their prologue and read no third
	# slot anywhere, so the tail `argument_vector` filled is dead and the phase
	# already in hand is the engine's answer to the call their arm makes.
	"0x004228F0", "0x00429C30", "0x00428200", "0x00428570",
	# 2026-09-12, the afternoon: the other five, and all five by *capture*.
	# Wine had answered 0 of 80 that morning and reached the anchor for every
	# plan a few hours later on the same host, so the eight corrected phases
	# and the `models` re-take all landed. `0x00425400` and `0x00427C80` came
	# off `PROGRAM_ARGS_STALE`; `0x00425CA0`, `0x00426070` and `0x00426B70`
	# off `PROGRAM_MODELS_UNCAPTURED`, because the constructor stopped refusing
	# their rounds for want of a model handle.
	#
	# **Only one of the five needed a correction, and the diff is what found
	# it**: `0x00427C80`'s sprite half-size is biased by a *per-record byte
	# counter* that opens at two, not by the ring index over three. Eleven of
	# the engine's twelve records disagreed, every one of them on `aux` alone.
	"0x00425400", "0x00425CA0", "0x00426070", "0x00426B70", "0x00427C80",
	# 2026-09-12, the evening: **the last five of the thirty**, and no new
	# capture for any of them -- every phase was already in hand. The three
	# bursts are replayed against their `burst_*` phase, the one taken with
	# the round count and stagger the muzzle switch's own arm pushes
	# (`blob_gold.BURST_ARGS`); the bare phase of each holds an empty loop.
	# The shock wave's phase holds the capture's twelve-record window onto
	# its sixty, so the prefix is what is compared. The spore cannon's
	# holds its one round. Until this day the bursts went down a
	# constructor-table arm in `BlobTriggers` and the other two were built
	# by hand and checked structurally in `test_effects` -- a weaker claim
	# than this one, and one nothing stated as such (docs/102 item 2.1).
	"0x004247C0", "0x00424250", "0x00423D80", "0x00422B80", "0x004268B0"]
## The burst creators' own phase carries this prefix (`blob_gold.BURST_PREFIX`).
const BURST_PREFIX: String = "burst_"
## **Empty, and that is the measurement.** These three lists held five
## creators between them on the morning of 2026-09-12 -- one whose phase no
## capture had ever verified, three blocked on a model handle, one transcribed
## with a deliberate divergence -- and the afternoon's capture emptied all
## three. Every creator the switch routes is now replayed against the engine's
## own records. The lists stay because a thinner capture has to put a name back
## rather than quietly compare less, which is what
## [method _check_routed_are_measured] enforces.
##
## `blob_gold.PROGRAM_MODELS_UNCAPTURED`, `PROGRAM_ARGS_STALE` and
## `PROGRAM_DIVERGENT` are the same three pins on the Python side.
##
## What is *not* closed by any of this is named where it lives and not here:
## [constant BlobPrograms.FLAME_RING0_DIVERGENCE] -- the flame stream's first
## ring reads the caller's stack, the capture measured the anchor's, and a shot
## calls it from somewhere else.
const WEAPON_PROGRAMS_UNCAPTURED: Array[String] = []
const WEAPON_PROGRAMS_STATIC: Array[String] = []
const WEAPON_PROGRAMS_DIVERGENT: Array[String] = []
## The one driven end to end, and the weapon whose muzzle switch names it.
const SEAM_CREATOR: String = "0x00425810"
const SEAM_WEAPON: int = 26
## The tile-shaped half: `aBlob_CreateLandingDust` `0x004227C0` is weapon 42's
## whole impact switch, and it reads the **cell** rather than the points.
const IMPACT_CREATOR: String = "0x004227C0"
const IMPACT_WEAPON: int = 42
## Enough slots for the widest transcribed creator's whole loop.
const REPLAY_SLOTS: int = 256
## Every field the constructor stores that the capture reads back.
const REPLAY_FIELDS: Array[String] = ["x", "y", "z", "vx", "vy", "vz",
	"rot_x", "rot_y", "rot_z", "kind", "life", "aux", "delay", "class_id"]
## No symbol object stands on the tile asked for.
const NO_SYMBOL: Vector3i = Vector3i(-1, -1, -1)
## docs/30 section 2.5 again, as the capture's cell index is laid out.
const CAPTURE_WIDTH: int = 20
## How many records the phases above hold between them: the window is twelve
## and **nine** of the twenty-five creators lay fewer than that, so the sum is
## written out rather than rounded. Two for `0x004264A0`, four for `0x00427810`,
## three for `0x0042AF10`, three for `0x00429C30`, whose whole effect is three
## puffs, eight for `0x00428570`, whose chain is six dots, a tail and the bob it
## opens with, two for `0x00425400`'s one round of spray, six for
## `0x00426070`'s one arc, and -- the two the model re-take unblocked -- **one**
## for `0x00425CA0` and **two** for `0x00426B70`.
##
## Those last two are the shape of the capture, not of the creator: both lay a
## round the constructor accepts and a second record on a branch this tile does
## not take, so a single phase is the whole of what either makes here.
##
## Then the last five: **thirty** for the tracer's ten rounds of three,
## **twenty-seven** for the needles' three rounds of nine, **ten** for the
## flash's ten rounds of one, **twelve** for the shock wave -- the capture's
## window onto sixty, so a prefix -- and **one** for the spore cannon.
const CAPTURED_RECORDS: int = 12 * 16 + 2 + 4 + 3 + 3 + 8 + 2 + 6 + 1 + 2 \
	+ 30 + 27 + 10 + 12 + 1


func _check_weapon_creators(h: TestHarness, phases: Dictionary) -> void:
	var inputs: BlobPrograms.Inputs = _weapon_inputs(phases)
	if inputs == null:
		h.check("weapon_programs.inputs", false,
			"the capture carries no symbol objects, unit heights or cells; "
			+ "re-take it")
		return
	var bad: PackedStringArray = PackedStringArray()
	var seeds: PackedStringArray = PackedStringArray()
	var compared: int = 0
	var ran: int = 0
	for creator: String in WEAPON_PROGRAMS:
		# A burst creator's own phase where it has one: the bare phase was
		# taken with a round count of zero and holds an empty loop.
		var phase: Dictionary = DictRead.as_dict(phases.get(
			BURST_PREFIX + creator, phases.get(creator, {})))
		var records: Array = DictRead.as_array(phase.get("records", []))
		if records.is_empty() or not phase.has("seed2_before"):
			# A creator the capture called with arguments that make nothing
			# is a faithful zero and judges nothing -- see
			# `blob_gold.PROGRAM_ARGS_STALE`. It is still a hole here, and
			# named as one.
			bad.append("%s: not captured" % creator)
			continue
		var args: PackedInt32Array = PackedInt32Array()
		for value: Variant in DictRead.as_array(phase["args"]):
			args.append(DictRead.as_int(value))
		var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
		var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(
			DictRead.as_float(phase["seed2_before"]))
		if not BlobPrograms.run(creator, pool, draws, args, inputs):
			bad.append("%s: no program" % creator)
			continue
		ran += 1
		if not is_equal_approx(draws.rng.seed,
				DictRead.as_float(phase["seed2_after"])):
			seeds.append(creator)
		for index: int in range(records.size()):
			compared += 1
			if index >= pool.records.size():
				bad.append("%s.%d: missing" % [creator, index])
				continue
			var want: Dictionary = DictRead.as_dict(records[index])
			var got: Dictionary = pool.records[index]
			for field: String in REPLAY_FIELDS:
				if DictRead.as_int(got[field]) != DictRead.as_int(want[field]):
					bad.append("%s.%d.%s: %d is not %d" % [creator, index,
						field, DictRead.as_int(got[field]),
						DictRead.as_int(want[field])])
	# **A comparison that examined nothing is not a comparison that passed.**
	# Every entry must have run and the record count must be the capture's,
	# or a thinner capture would report agreement it never tested.
	h.equal("weapon_programs.ran", ran, WEAPON_PROGRAMS.size())
	h.equal("weapon_programs.compared", compared, CAPTURED_RECORDS)
	_check_routed_are_measured(h)
	h.check("weapon_programs.fields", bad.is_empty(),
		"%d record(s) across %d creator(s) field for field%s"
			% [compared, ran, "" if bad.is_empty() else "; first: " + bad[0]])
	var none: PackedStringArray = PackedStringArray()
	h.equal("weapon_programs.draws", seeds, none)
	_check_weapon_seam(h, phases)
	_check_impact_seam(h, phases)
	_check_arc_shots(h, phases)


## **Every creator the switch routes is either replayed above or named as
## not being.** `BlobTriggers.WEAPON_PROGRAMS` is the routing table, and the
## rule this file exists to keep is that an entry joins it only once the
## capture judges it -- so the one list has to equal the other two.
##
## Without this the exception list is a comment: `0x00426B70` was routed on
## 2026-09-12 with nothing replaying it, and nothing would have said so.
func _check_routed_are_measured(h: TestHarness) -> void:
	var routed: Array[String] = []
	for key: Variant in BlobTriggers.WEAPON_PROGRAMS:
		routed.append(DictRead.as_string(key))
	routed.append(BlobTriggers.SPORE_EXPLOSION_TYPED)
	routed.append(BlobTriggers.GRENADE_ARC_TYPED)
	routed.append(BlobTriggers.FLAME_STREAM_TYPED)
	routed.append_array(BlobTriggers.BURST_TYPED)
	# Asked for by tile rather than run from the switch, and routed all the
	# same.
	routed.append(BlobTriggers.SHOCK_WAVE_CREATOR)
	routed.sort()
	var judged: Array[String] = WEAPON_PROGRAMS.duplicate()
	judged.append_array(WEAPON_PROGRAMS_UNCAPTURED)
	judged.append_array(WEAPON_PROGRAMS_STATIC)
	judged.append_array(WEAPON_PROGRAMS_DIVERGENT)
	judged.sort()
	# The seam drives these two from the switch rather than from a program of
	# their own, so they are routed without being rows of the table.
	var extra: Array[String] = []
	for creator: String in judged:
		if not routed.has(creator):
			extra.append(creator)
	var missing: Array[String] = []
	for creator: String in routed:
		if not judged.has(creator):
			missing.append(creator)
	h.check("weapon_programs.routed_are_measured",
		missing.is_empty() and extra.is_empty(),
		"%d routed creator(s), every one replayed or named%s" % [routed.size(),
			"" if missing.is_empty() and extra.is_empty()
			else "; routed but unjudged: %s; judged but unrouted: %s"
				% [missing, extra]])


## The **seam**: the whole muzzle made through the switch, against the pool
## the engine left. What this adds over the check above is everything
## [BlobTriggers] does around a program -- the switch's own creator list, the
## joint the creator resolves for itself, the argument vector, the generator
## handed over and handed back, and the records reaching the live pool.
func _check_weapon_seam(h: TestHarness, phases: Dictionary) -> void:
	var document: Dictionary = CacheFixture.read_json(
		CacheFixture.cache_dir() + "/tables/blobs.json")
	if document.is_empty():
		h.check("weapon_creators.document", false, "tables/blobs.json")
		return
	var phase: Dictionary = DictRead.as_dict(phases.get(SEAM_CREATOR, {}))
	var records: Array = DictRead.as_array(phase.get("records", []))
	var inputs: BlobPrograms.Inputs = _weapon_inputs(phases)
	if records.is_empty() or inputs == null:
		h.check("weapon_creators.captured", false,
			"the capture holds no records for %s" % SEAM_CREATOR)
		return
	var args: Array = DictRead.as_array(phase["args"])
	var source_tile: Vector2i = Vector2i(DictRead.as_int(args[0]),
		DictRead.as_int(args[1]))
	var target_tile: Vector2i = Vector2i(DictRead.as_int(args[2]),
		DictRead.as_int(args[3]))
	var pool: BlobPool = BlobPool.create(1.0, REPLAY_SLOTS)
	pool.hooks().rng.randomize_seed(
		DictRead.as_float(phase["seed2_before"]))
	pool.hooks().geometry = inputs.geometry
	for name: Variant in inputs.models:
		pool.hooks().model_index[DictRead.as_string(name)] = DictRead.as_int(
			inputs.models[name])
	var triggers: BlobTriggers = BlobTriggers.open(pool, document)
	var _made: int = triggers.muzzle(SEAM_WEAPON, inputs.source_point(),
		inputs.target_point(), {}, source_tile, target_tile,
		inputs.source, inputs.target)
	var ours: Array[Blob] = pool.blobs()
	h.check("weapon_creators.count", ours.size() >= records.size(),
		"%d record(s) against the capture's %d-record window"
			% [ours.size(), records.size()])
	h.equal("weapon_creators.seed", pool.hooks().rng.seed,
		DictRead.as_float(phase["seed2_after"]))
	h.equal("weapon_creators.arrived", triggers.arrived_write(), 1,
		"`mov dword [0x004FE63C], 1` at `0x00425AD6`")
	var bad: PackedStringArray = PackedStringArray()
	for index: int in range(mini(ours.size(), records.size())):
		var want: Dictionary = DictRead.as_dict(records[index])
		var got: Dictionary = ours[index].to_dict()
		for field: String in REPLAY_FIELDS:
			if DictRead.as_int(got[field]) != DictRead.as_int(want[field]):
				bad.append("%d.%s: %d is not %d" % [index, field,
					DictRead.as_int(got[field]),
					DictRead.as_int(want[field])])
	h.check("weapon_creators.fields", bad.is_empty(),
		"%d record(s) field for field%s" % [records.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])


## The **tile** half of the same seam: an impact creator that reads a cell
## rather than the two points it was handed, driven through
## [method BlobTriggers.impact].
##
## It exists because the line-shaped seam above cannot see the one thing a
## tile-shaped creator needs -- `BlobPrograms.Inputs.tiles` filled with the
## object the cell carries. A runner that leaves it empty answers
## `Vector3i.ZERO` and lays the whole effect at the world origin, which every
## other check in this file is blind to.
func _check_impact_seam(h: TestHarness, phases: Dictionary) -> void:
	var document: Dictionary = CacheFixture.read_json(
		CacheFixture.cache_dir() + "/tables/blobs.json")
	var phase: Dictionary = DictRead.as_dict(phases.get(IMPACT_CREATOR, {}))
	var records: Array = DictRead.as_array(phase.get("records", []))
	var inputs: BlobPrograms.Inputs = _weapon_inputs(phases)
	if document.is_empty() or records.is_empty() or inputs == null:
		h.check("impact_creators.captured", false,
			"the capture holds no records for %s" % IMPACT_CREATOR)
		return
	var args: Array = DictRead.as_array(phase["args"])
	var tile: Vector2i = Vector2i(DictRead.as_int(args[0]),
		DictRead.as_int(args[1]))
	var pool: BlobPool = BlobPool.create(1.0, REPLAY_SLOTS)
	pool.hooks().rng.randomize_seed(DictRead.as_float(phase["seed2_before"]))
	pool.hooks().geometry = inputs.geometry
	for name: Variant in inputs.models:
		pool.hooks().model_index[DictRead.as_string(name)] = DictRead.as_int(
			inputs.models[name])
	var triggers: BlobTriggers = BlobTriggers.open(pool, document)
	# The capture called this creator on the **source** cell, which is where
	# its own `args` say it stood.
	var _made: int = triggers.impact(IMPACT_WEAPON, inputs.source_point(),
		tile, inputs.source)
	var ours: Array[Blob] = pool.blobs()
	# The capture reads back a twelve-record window; the seed afterwards is
	# what accounts for the rest.
	h.check("impact_creators.count", ours.size() >= records.size(),
		"%d record(s) against the capture's %d-record window"
			% [ours.size(), records.size()])
	h.equal("impact_creators.seed", pool.hooks().rng.seed,
		DictRead.as_float(phase["seed2_after"]))
	var bad: PackedStringArray = PackedStringArray()
	for index: int in range(mini(ours.size(), records.size())):
		var want: Dictionary = DictRead.as_dict(records[index])
		var got: Dictionary = ours[index].to_dict()
		for field: String in REPLAY_FIELDS:
			if DictRead.as_int(got[field]) != DictRead.as_int(want[field]):
				bad.append("%d.%s: %d is not %d" % [index, field,
					DictRead.as_int(got[field]),
					DictRead.as_int(want[field])])
	h.check("impact_creators.fields", bad.is_empty(),
		"%d record(s) field for field%s" % [records.size(),
			"" if bad.is_empty() else "; first: " + bad[0]])


## What a weapon creator reads before it draws, out of the capture's own
## read-only phases -- `blob_gold._creator_inputs`' other copy.
func _weapon_inputs(phases: Dictionary) -> BlobPrograms.Inputs:
	var origins: Dictionary = DictRead.as_dict(phases.get("origins", {}))
	var symbols: Dictionary = DictRead.as_dict(phases.get("symbols", {}))
	var cells: Array = DictRead.as_array(origins.get("cells", []))
	var heights: Array = DictRead.as_array(origins.get("heights", []))
	var units: Array = DictRead.as_array(
		DictRead.as_dict(phases.get("state", {})).get("units", []))
	if cells.is_empty() or symbols.is_empty() or heights.size() < 2 \
			or units.size() < 2:
		return null
	var found: Array[Dictionary] = []
	for index: int in range(2):
		var unit: Dictionary = DictRead.as_dict(units[index])
		var at: int = DictRead.as_int(unit["y"]) * CAPTURE_WIDTH \
			+ DictRead.as_int(unit["x"])
		if at >= cells.size():
			return null
		found.append(DictRead.as_dict(cells[at]))
	var source: Vector3i = _symbol(symbols, DictRead.as_int(found[0]["object"]))
	var target: Vector3i = _symbol(symbols, DictRead.as_int(found[1]["object"]))
	if source == NO_SYMBOL or target == NO_SYMBOL:
		return null
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.source = source
	inputs.source_height = DictRead.as_int(heights[0])
	inputs.target = target
	inputs.target_height = DictRead.as_int(heights[1])
	inputs.target_unit = DictRead.as_int(found[1]["unit"]) & 0xFF
	for name: String in DictRead.as_dict(phases.get("models", {})):
		inputs.models[name] = DictRead.as_int(
			DictRead.as_dict(phases["models"])[name])
	if FileAccess.file_exists(BLOB_CASES):
		var document: Dictionary = CacheLoader.read_json(BLOB_CASES)
		var raw: Variant = document.get("eng3d")
		if raw is Dictionary:
			inputs.geometry = Eng3dGeometry.from_document(DictRead.as_dict(raw))
	# Every creator here reads the tile through `object()` as well, and the
	# two the capture used are the two it measured.
	inputs.tiles[Vector2i(DictRead.as_int(DictRead.as_dict(units[0])["x"]),
		DictRead.as_int(DictRead.as_dict(units[0])["y"]))] = {
			"object": source, "unit": {}}
	inputs.tiles[Vector2i(DictRead.as_int(DictRead.as_dict(units[1])["x"]),
		DictRead.as_int(DictRead.as_dict(units[1])["y"]))] = {
			"object": target, "unit": {}}
	return inputs


## **The walking arm at arc 1**, against the engine. The two weapon-11 shots
## of docs/97 section 51.2 -- `shot_11_band`, whose two cells this tool
## stamped by hand, and `shot_11_overlay`, whose two `aBuildTargetOverlay`
## stamped itself -- each walked two cells and called `aBlob_CreateGrenade`
## once per cell with the running count as its sixth argument. The Python
## twin is judged on them by `blob_gold`; this is the same replay for
## [method BlobPrograms.grenade_arc], cell by cell, with each cell's own
## placed object, occupant height and occupant slot out of the `origins` and
## `symbols` phases -- the substitutions `blob_gold._cell_inputs` makes. The
## bare `0x00426070` phase reaches arc 0xFF alone, so without this the arc-1
## arm of the GDScript twin was judged by nothing.
const ARC_SHOTS: Array[String] = ["shot_11_band", "shot_11_overlay"]
## Two cells of six records, twice.
const ARC_SHOT_RECORDS: int = 2 * 2 * 6
## Weapon 11's arm pushes 0xA as the fifth argument, which the body never
## reads (`BlobTriggers.GRENADE_ARC_TYPED`'s row).
const ARC_TAIL_UNREAD: int = 0xA


func _check_arc_shots(h: TestHarness, phases: Dictionary) -> void:
	var base: BlobPrograms.Inputs = _weapon_inputs(phases)
	if base == null:
		return
	var bad: PackedStringArray = PackedStringArray()
	var compared: int = 0
	var walked: int = 0
	for name: String in ARC_SHOTS:
		var phase: Dictionary = DictRead.as_dict(phases.get(name, {}))
		var records: Array = DictRead.as_array(phase.get("records", []))
		var marked: Array = DictRead.as_array(phase.get("marked", []))
		if records.is_empty() or marked.is_empty() \
				or not phase.has("seed2_before"):
			bad.append("%s: not captured" % name)
			continue
		var attacker: Array = DictRead.as_array(phase["attacker"])
		var here: Vector2i = Vector2i(DictRead.as_int(attacker[0]),
			DictRead.as_int(attacker[1]))
		var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(
			DictRead.as_float(phase["seed2_before"]))
		var built: Array[Dictionary] = []
		for index: int in range(marked.size()):
			var cell: Dictionary = DictRead.as_dict(marked[index])
			var there: Vector2i = Vector2i(DictRead.as_int(cell["x"]),
				DictRead.as_int(cell["y"]))
			var inputs: BlobPrograms.Inputs = _cell_inputs(base, phases, here,
				there)
			if inputs == null:
				bad.append("%s: (%d, %d) has no measured object"
					% [name, there.x, there.y])
				continue
			walked += 1
			var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
			var ran: bool = BlobPrograms.run(BlobPrograms.GRENADE_ARC, pool,
				draws, PackedInt32Array([here.x, here.y, there.x, there.y,
					ARC_TAIL_UNREAD, index]), inputs)
			if not ran:
				bad.append("%s: the grenade program refused" % name)
			built.append_array(pool.records)
		for index: int in range(mini(built.size(), records.size())):
			compared += 1
			var want: Dictionary = DictRead.as_dict(records[index])
			var got: Dictionary = built[index]
			for field: String in REPLAY_FIELDS:
				if DictRead.as_int(got[field]) != DictRead.as_int(want[field]):
					bad.append("%s.%d.%s: %d is not %d" % [name, index, field,
						DictRead.as_int(got[field]),
						DictRead.as_int(want[field])])
	h.equal("arc_shots.walked", walked, 2 * ARC_SHOTS.size(),
		"two cells in the band of each shot, each replayed with its own arc")
	h.equal("arc_shots.compared", compared, ARC_SHOT_RECORDS)
	h.check("arc_shots.records", bad.is_empty(),
		"%d record(s) over %d walked cell(s) field for field, the second "
		% [compared, walked] + "cell of each shot at arc 1"
		+ ("" if bad.is_empty() else "; first: " + bad[0]))


## [BlobPrograms.Inputs] aimed at one walked cell from the attacker's own,
## the way `blob_gold._shot_source` and `_cell_inputs` build it: the placed
## object of each cell out of `origins.cells[].object` resolved through
## `symbols`, the occupant's height out of `origins.heights` by slot, and
## the occupant itself for the seeker's `aux`. `null` for a cell the capture
## never measured, which is a gap to name and not a rule to fall back on.
static func _cell_inputs(base: BlobPrograms.Inputs, phases: Dictionary,
		here: Vector2i, there: Vector2i) -> BlobPrograms.Inputs:
	var origins: Dictionary = DictRead.as_dict(phases.get("origins", {}))
	var cells: Array = DictRead.as_array(origins.get("cells", []))
	var heights: Array = DictRead.as_array(origins.get("heights", []))
	var slots: Array = DictRead.as_array(origins.get("height_slots", []))
	var symbols: Dictionary = DictRead.as_dict(phases.get("symbols", {}))
	var source_at: int = here.y * CAPTURE_WIDTH + here.x
	var target_at: int = there.y * CAPTURE_WIDTH + there.x
	if source_at >= cells.size() or target_at >= cells.size():
		return null
	var source_cell: Dictionary = DictRead.as_dict(cells[source_at])
	var target_cell: Dictionary = DictRead.as_dict(cells[target_at])
	var source: Vector3i = _symbol(symbols,
		DictRead.as_int(source_cell["object"]))
	var target: Vector3i = _symbol(symbols,
		DictRead.as_int(target_cell["object"]))
	if source == NO_SYMBOL or target == NO_SYMBOL:
		return null
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.geometry = base.geometry
	inputs.models = base.models
	inputs.source = source
	inputs.source_height = _height_of(heights, slots,
		DictRead.as_int(source_cell["unit"]), base.source_height)
	inputs.target = target
	var occupant: int = DictRead.as_int(target_cell["unit"])
	inputs.target_height = _height_of(heights, slots, occupant,
		base.target_height)
	inputs.target_unit = occupant & 0xFF
	inputs.tiles[here] = {"object": source, "unit": {}}
	inputs.tiles[there] = {"object": target, "unit": {}}
	return inputs


## The height `0x0047AD30` answered for a slot in the `origins` phase, or the
## fallback for a cell nobody stands on.
static func _height_of(heights: Array, slots: Array, slot: int,
		fallback: int) -> int:
	for index: int in range(mini(heights.size(), slots.size())):
		if DictRead.as_int(slots[index]) == slot:
			return DictRead.as_int(heights[index])
	return fallback


## One entry of the `symbols` phase, or [constant NO_SYMBOL].
static func _symbol(symbols: Dictionary, id: int) -> Vector3i:
	var at: Variant = symbols.get(str(id))
	if not (at is Dictionary):
		return NO_SYMBOL
	var record: Dictionary = DictRead.as_dict(at)
	return Vector3i(DictRead.as_int(record["x"]), DictRead.as_int(record["y"]),
		DictRead.as_int(record["z"]))


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
