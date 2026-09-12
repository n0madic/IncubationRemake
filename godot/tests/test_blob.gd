extends TestSuite

## Oracle boundary: **executable Python**, and deliberately not stronger.
##
## `tools/blob_runtime.py` is `aBlob_Update`'s wrapper and all 74 of its
## jump-table arms transcribed from `Incubation.exe`, with the original's field
## widths and x86 wraparound. This suite replays the per-tick trace it emits and
## requires [Blob], [BlobKinds] and [BlobHooks] to agree **field for field, tick
## for tick**, over all 78 kinds and ten scenarios each.
##
## **What this does not claim.** All five services of docs/28 section 12 item 1
## -- `0x004039A0`, `0x00403AA0`, `0x0046D400`, `0x00405100`, `0x00477AE0` --
## have been swept inside a running `Incubation.exe` now, and the orientation
## one is the engine's own arithmetic on both sides of this diff. The other
## services stay a *deterministic adapter* that both sides implement, on
## purpose: making them read a running game would replace a reproducible diff
## with a replay of recorded returns.
##
## So this is still a check that the **arms** were transcribed correctly, not a
## check that a particle follows the trajectory the original's particle
## followed. One service being measured does not make the arms measured. The
## fixture says so in its own `oracle` field, and this suite prints
## `executable-Python` rather than `native-runtime` for exactly that reason.
##
## The one service that **is** natively pinned is the generator: `aRandom` is
## docs/91's routine and [IncRandom] reproduces its seed exactly, so the draw
## counts and seeds compared here are anchored even though the hooks are not.
##
## **No tolerance.** Every value is an integer stored at a known width, so a
## mismatch is a mismatch. That is the difference between this diff and the
## Charisma one, and it is why the failure message names the field.

const CASES: String = "res://generated/blob/blob.json"
const SCHEMA: String = "incubation.blob-cases/1"
## How many mismatching fields to name before the message becomes noise.
const REPORTED: int = 6
## The vectors the native sweep put through `0x004039A0`.
const ROTATE_CASES: int = 8
## Arms stepped inside a running `Incubation.exe`, and those that disagreed.
##
## **Arm 13 moved from the second count to the first on 2026-09-11.** It had
## been poked -- a donor record with its kind byte rewritten -- because the
## shock wave's capture phase held nothing: `blob_gold.argument_vector` had
## handed `aBlob_CreateShockWave` a tile number where its two call sites push
## a type, so the creator took its fall-through arm. With the argument
## corrected the creator lays sixty records and the arm is stepped with a
## creator's own, which is the stronger claim of the two.
const NATIVE_ARMS: int = 27
const POKED_ARMS: int = 47
const UNRESOLVED_ARMS: int = 0
## Transcribed arm lines the native comparison actually executed, and how many
## there are. The eight that are missing are named in `blob_gold.py`'s
## `COVERAGE_UNCOVERED`; two of them are a deliberate divergence.
const ARM_LINES_COVERED: int = 383
const ARM_LINES_TOTAL: int = 385


func run(h: TestHarness) -> void:
	h.begin("blob", TestHarness.ORACLE_PYTHON)
	if not FileAccess.file_exists(CASES):
		h.check("fixture", false,
			"run python3 tools/blob_runtime.py --emit-cases "
			+ "tests/fixtures/blob/cases_blob.json")
		return
	var document: Dictionary = CacheLoader.read_json(CASES)
	if document.is_empty():
		h.check("fixture", false, "%s did not parse" % CASES)
		return
	if not h.equal("schema", document.get("schema"), SCHEMA):
		return

	h.equal("kinds", BlobKinds.KIND_COUNT,
		DictRead.as_int(document["kinds"]))
	h.equal("gravity",
		[BlobKinds.GRAVITY_SPLIT, BlobKinds.GRAVITY_HIGH,
			BlobKinds.GRAVITY_LOW],
		[DictRead.as_int(DictRead.as_dict(document["gravity"])["split"]),
			DictRead.as_int(DictRead.as_dict(document["gravity"])["high"]),
			DictRead.as_int(DictRead.as_dict(document["gravity"])["low"])])
	h.equal("immortal", BlobKinds.IMMORTAL,
		DictRead.as_int(document["immortal_life"]))
	h.equal("unreachable", BlobKinds.UNREACHABLE,
		_as_ints(DictRead.as_array(document["unreachable"])))
	# **The orientation service is measured now**, and the suite must fail if
	# it silently falls back. docs/28 section 12 item 1 recorded the retail
	# routine as never called; `tools/blob_gold.py`'s `hooks` phase called it,
	# and a fixture emitted with a game root carries the shipped tables so
	# both twins run the same arithmetic instead of the same guess.
	h.equal("orient_is_measured", DictRead.as_string(document.get("orient", "")),
		"native",
		"the fixture was emitted with a game root, so orient() is 0x00403AA0")
	var measured: Eng3dGeometry = _geometry(document)
	h.check("orient_tables_loaded", measured != null and measured.is_loaded(),
		"TRIG.IMG and ATN.IMG rode along in the fixture")
	# Two answers out of the twenty the native sweep took, restated here so a
	# GDScript-side regression in the table narrowing fails this suite and not
	# only the Python one: a full field along +x is a quarter turn of the
	# 4096 circle with the pitch at level, and straight up is -1024.
	h.equal("orient_quarter_turn",
		measured.orient(Vector3i.ZERO, Vector3i(1000, 0, 0)),
		Vector2i(0, 1024), "+x is yaw 1024, pitch 0")
	h.equal("orient_straight_up",
		measured.orient(Vector3i.ZERO, Vector3i(0, 0, 1000)),
		Vector2i(-1024, 0), "straight up is pitch -1024")
	_check_rotate(h, document, measured)
	_check_native_arms(h, document)
	h.equal("adapter_models", BlobHooks.MODELS,
		_as_strings(DictRead.as_array(document["models"])))
	h.equal("adapter_target", BlobHooks.DEFAULT_TARGET,
		_as_vector(DictRead.to_int32(document["target"])))

	_check_aliases(h, document)
	_check_ticks(h, document)
	_check_pool(h)
	_check_rounding(h)


## The four aliased pairs, checked as aliases rather than as equal behaviour.
##
## Two arms that happen to write the same fields on the fixture's inputs would
## pass every tick comparison and still be a different program. So each pair is
## run on an input that reaches a branch, and the whole 78-onto-74 mapping is
## compared against the jump table the emitter read out of the binary.
func _check_aliases(h: TestHarness, document: Dictionary) -> void:
	var arm_of: Dictionary = DictRead.as_dict(document["arm_of_kind"])
	var mismatched: PackedStringArray = PackedStringArray()
	for pair: Vector2i in BlobKinds.ALIASES:
		if DictRead.as_int(arm_of[str(pair.x)]) \
				!= DictRead.as_int(arm_of[str(pair.y)]):
			mismatched.append("%d/%d" % [pair.x, pair.y])
	h.check("aliases_in_table", mismatched.is_empty(),
		"%d pairs share an arm in the jump table: %s"
			% [BlobKinds.ALIASES.size(), ", ".join(mismatched)])
	var arms: Dictionary[int, bool] = {}
	for key: Variant in arm_of:
		arms[DictRead.as_int(arm_of[key])] = true
	h.equal("distinct_arms", arms.size(), DictRead.as_int(document["arms"]))

	var differing: PackedStringArray = PackedStringArray()
	for pair: Vector2i in BlobKinds.ALIASES:
		var left: Blob = _seeded_blob(pair.x, document)
		var right: Blob = _seeded_blob(pair.y, document)
		var hooks_left: BlobHooks = _hooks(document, {})
		var hooks_right: BlobHooks = _hooks(document, {})
		BlobKinds.tick(left, hooks_left)
		BlobKinds.tick(right, hooks_right)
		var a: Dictionary = left.to_dict()
		var b: Dictionary = right.to_dict()
		a.erase("kind")
		b.erase("kind")
		if a != b:
			differing.append("%d/%d" % [pair.x, pair.y])
	h.check("aliases_behave", differing.is_empty(),
		"and produce the same record: %s" % ", ".join(differing))


func _check_ticks(h: TestHarness, document: Dictionary) -> void:
	var cases: Array = DictRead.as_array(document["cases"])
	var fields: Array = DictRead.as_array(document["fields"])
	var bad: PackedStringArray = PackedStringArray()
	var ticks: int = 0
	var compared: int = 0
	var kinds_seen: Dictionary[int, bool] = {}
	var scenarios_seen: Dictionary[String, bool] = {}
	var spawns: int = 0

	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var kind: int = DictRead.as_int(kase["kind"])
		var scenario: String = DictRead.as_string(kase["scenario"])
		kinds_seen[kind] = true
		scenarios_seen[scenario] = true
		var blob: Blob = Blob.make(DictRead.as_dict(kase["blob"]))
		var hooks: BlobHooks = _hooks(document, kase)
		var trace: Array = DictRead.as_array(kase["ticks"])
		for index: int in range(trace.size()):
			var want: Dictionary = DictRead.as_dict(trace[index])
			var result: BlobKinds.TickResult = BlobKinds.tick(blob, hooks)
			ticks += 1
			var got: Dictionary = blob.to_dict()
			var expect: Dictionary = DictRead.as_dict(want["blob"])
			for name: Variant in fields:
				var field: String = DictRead.as_string(name)
				compared += 1
				if DictRead.as_int(got[field]) \
						!= DictRead.as_int(expect[field]):
					bad.append("kind %d %s tick %d: %s %d != %d"
						% [kind, scenario, index, field,
							DictRead.as_int(got[field]),
							DictRead.as_int(expect[field])])
			var flags: Dictionary = result.to_dict()
			for flag: String in ["ran", "delayed", "dispatched", "deleted",
					"delete_requested", "global_signal", "global_signal_clear",
					"target_missing",
					"model_missing"]:
				compared += 1
				if DictRead.as_int(flags[flag]) \
						!= DictRead.as_int(want[flag]):
					bad.append("kind %d %s tick %d: %s %d != %d"
						% [kind, scenario, index, flag,
							DictRead.as_int(flags[flag]),
							DictRead.as_int(want[flag])])
			spawns += result.spawns.size()
			var spawn_problem: String = _compare_spawns(result.spawns,
				DictRead.as_array(want["spawns"]))
			if not spawn_problem.is_empty():
				bad.append("kind %d %s tick %d: %s"
					% [kind, scenario, index, spawn_problem])
			# The generator is the one natively pinned service in the whole
			# adapter, so its call count and seed are compared every tick
			# rather than at the end: a draw taken in the wrong order inside
			# an arm is invisible in a total and obvious here.
			compared += 2
			if hooks.rng.calls != DictRead.as_int(want["rng_calls"]):
				bad.append("kind %d %s tick %d: %d draws != %d"
					% [kind, scenario, index, hooks.rng.calls,
						DictRead.as_int(want["rng_calls"])])
			if hooks.rng.seed != DictRead.as_float(want["rng_seed"]):
				bad.append("kind %d %s tick %d: seed %f != %f"
					% [kind, scenario, index, hooks.rng.seed,
						DictRead.as_float(want["rng_seed"])])

	h.check("ticks", bad.is_empty() and ticks > 0,
		"%d cases, %d ticks, %d field and flag comparisons, %d spawns%s"
			% [cases.size(), ticks, compared, spawns,
				"" if bad.is_empty() else "; " + _first(bad)])
	h.equal("kinds_covered", kinds_seen.size(), BlobKinds.KIND_COUNT)
	h.equal("scenarios_covered", scenarios_seen.size(),
		DictRead.as_array(document["scenarios"]).size())
	# A fixture that shrank would otherwise pass everything above it.
	h.check("trace_depth", ticks >= 3900,
		"%d ticks -- the fixture is 78 kinds by twelve scenarios" % ticks)


func _compare_spawns(got: Array[Dictionary], want: Array) -> String:
	if got.size() != want.size():
		return "%d spawns != %d" % [got.size(), want.size()]
	for index: int in range(want.size()):
		var expect: Dictionary = DictRead.as_dict(want[index])
		if DictRead.as_int(got[index]["creator"]) \
				!= DictRead.as_int(expect["creator"]):
			return "spawn %d creator 0x%X != 0x%X" % [index,
				DictRead.as_int(got[index]["creator"]),
				DictRead.as_int(expect["creator"])]
		if DictRead.as_int(got[index]["ok"]) != DictRead.as_int(expect["ok"]):
			return "spawn %d ok %d != %d" % [index,
				DictRead.as_int(got[index]["ok"]),
				DictRead.as_int(expect["ok"])]
		var mine: Array = DictRead.as_array(got[index]["args"])
		var theirs: Array = DictRead.as_array(expect["args"])
		if mine.size() != theirs.size():
			return "spawn %d has %d args, not %d" % [index, mine.size(),
				theirs.size()]
		for a: int in range(mine.size()):
			if DictRead.as_int(mine[a]) != DictRead.as_int(theirs[a]):
				return "spawn %d arg %d: %d != %d" % [index, a,
					DictRead.as_int(mine[a]), DictRead.as_int(theirs[a])]
	return ""


## The pool's own rules, which the per-tick trace cannot reach: the 450-slot
## cap, the two arguments that refuse a create outright, and the determinism
## the canonical hash deliberately does not provide here.
func _check_pool(h: TestHarness) -> void:
	var pool: BlobPool = BlobPool.create(1.0, 4)
	h.equal("pool_capacity", pool.capacity(), 4)
	var made: PackedInt32Array = PackedInt32Array()
	for step: int in range(6):
		made.append(pool.create_blob({"kind": 7, "life": 12, "class_id": 2,
			"z": 1000}))
	h.equal("pool_full", made, PackedInt32Array([0, 1, 2, 3, -1, -1]),
		"a create that finds no slot is dropped, not raised")
	h.equal("pool_drops", pool.drops(), 2)
	# `life` of zero aborts the constructor before anything is allocated.
	var empty: BlobPool = BlobPool.create(1.0, 4)
	h.equal("pool_life_zero",
		empty.create_blob({"kind": 7, "life": 0, "class_id": 2}), -1)
	# A model class 0/1 whose name this world set does not carry is cancelled,
	# which is how docs/28 7.5's four rare models behave outside their sets.
	h.equal("pool_model_missing",
		empty.create_blob({"kind": 7, "life": 9, "class_id": 0,
			"model_name": "A_PARAB1.3DI"}), -1,
		"an effect whose model is absent is cancelled, not drawn")
	h.check("pool_model_present",
		empty.create_blob({"kind": 7, "life": 9, "class_id": 0,
			"model_name": BlobHooks.MODELS[0]}) >= 0,
		"and one whose model is present is created")

	# Determinism, bought explicitly because the canonical hash does not cover
	# this pool: same seed, same events, same digest.
	var first: BlobPool = _ticked_pool()
	var second: BlobPool = _ticked_pool()
	h.equal("pool_deterministic", first.trace_digest(), second.trace_digest(),
		"the same seed and the same events give the same records")
	var other: BlobPool = _ticked_pool(2.0)
	h.check("pool_seed_matters",
		other.trace_digest() != first.trace_digest(),
		"and a different seed does not")


func _ticked_pool(seed_value: float = 1.0) -> BlobPool:
	var pool: BlobPool = BlobPool.create(seed_value, 32)
	for kind: int in [0, 7, 8, 22, 43, 59, 62, 77]:
		pool.create_blob({"kind": kind, "life": 20, "class_id": 2,
			"x": 100, "y": -200, "z": 5000, "vx": 300, "vy": -400, "vz": 500,
			"aux": 4})
	for _frame: int in range(6):
		pool.tick_all()
	return pool


## The one place the port could disagree with the reference for a reason that
## is not a transcription error: Python's `round` is half-to-even and
## GDScript's `roundi` is half-away-from-zero. The seek step reaches the
## half-integers whenever a distance divides evenly, so the helper is checked
## on its own rather than left to be discovered as drift.
func _check_rounding(h: TestHarness) -> void:
	var cases: Array[Vector2] = [
		Vector2(0.5, 0.0), Vector2(1.5, 2.0), Vector2(2.5, 2.0),
		Vector2(3.5, 4.0), Vector2(-0.5, 0.0), Vector2(-1.5, -2.0),
		Vector2(-2.5, -2.0), Vector2(0.4, 0.0), Vector2(0.6, 1.0),
		Vector2(-0.6, -1.0), Vector2(7.0, 7.0)]
	var bad: PackedStringArray = PackedStringArray()
	for kase: Vector2 in cases:
		var got: int = BlobHooks.round_half_even(kase.x)
		if got != int(kase.y):
			bad.append("%f -> %d, wanted %d" % [kase.x, got, int(kase.y)])
	h.check("round_half_even", bad.is_empty(),
		"%d cases, including every half-integer either side of zero%s"
			% [cases.size(), "" if bad.is_empty() else "; " + bad[0]])
	h.check("differs_from_roundi", BlobHooks.round_half_even(2.5) != roundi(2.5),
		"and it is not what GDScript's roundi does")


func _hooks(document: Dictionary, kase: Dictionary) -> BlobHooks:
	var hooks: BlobHooks = BlobHooks.deterministic(
		DictRead.as_float(document["seed"]))
	hooks.geometry = _geometry(document)
	hooks.target = _as_vector(DictRead.to_int32(document["target"]))
	if kase.has("target"):
		hooks.has_target = kase["target"] != null
		if hooks.has_target:
			hooks.target = _as_vector(DictRead.to_int32(kase["target"]))
	if kase.has("models"):
		hooks.models_present = DictRead.as_int(kase["models"]) != 0
	if kase.has("spawns_ok"):
		hooks.spawns_succeed = DictRead.as_int(kase["spawns_ok"]) != 0
	if kase.has("emitter_mode"):
		hooks.emitter_mode = DictRead.as_int(kase["emitter_mode"])
	return hooks


## The shipped trig tables the fixture carries, or null.
##
## `tools/blob_runtime.py --emit-cases --root <game>` puts them in and marks
## the document `"orient": "native"`; without a root the field says
## `"substitute"` and both twins keep the older stand-in. Reading the field
## rather than assuming either is what keeps a root-free emit from quietly
## comparing two different orientation helpers.
## The arms the engine itself has stepped, carried in from the capture.
##
## This suite's own boundary does **not** move: it compares GDScript against
## Python, and the fixture's `oracle` field says so. What it can do is name the
## arms for which the Python side has additionally been diffed against a
## running `Incubation.exe` field for field, so a reader knows which of the 74
## are transitively native and which are two readings of one listing.
func _check_native_arms(h: TestHarness, document: Dictionary) -> void:
	var native: Array = DictRead.as_array(document.get("native_arms", []))
	var unresolved: Array = DictRead.as_array(document.get("unresolved_arms", []))
	h.equal("native_arms_counted", native.size(), NATIVE_ARMS,
		"%d of 74 arms were stepped inside the retail process and agreed"
		% NATIVE_ARMS)
	h.equal("unresolved_arms_counted", unresolved.size(), UNRESOLVED_ARMS,
		"%d stepped arm(s) disagree; the two seekers left this list when "
		% UNRESOLVED_ARMS
		+ "`_seek` started asking `0x0046D400` instead of normalising")
	var poked: Array = DictRead.as_array(document.get("poked_arms", []))
	h.equal("poked_arms_counted", poked.size(), POKED_ARMS,
		"%d arm(s) no creator fills were stepped with a donor record whose "
		% POKED_ARMS + "kind byte was rewritten")
	var overlap: bool = false
	for arm: Variant in unresolved:
		if native.has(arm):
			overlap = true
	for arm: Variant in poked:
		if native.has(arm):
			overlap = true
	h.check("native_arms_disjoint", not overlap,
		"an arm is stepped one way or the other, never both")
	h.check("native_arms_cover_the_table",
		native.size() + poked.size() == DictRead.as_int(document["arms"]),
		"the two capture families between them reach all %d arms"
		% DictRead.as_int(document["arms"]))
	# **How much of each arm the native comparison reached.** A per-arm claim
	# that never says which lines were run is a claim about the arm's name
	# rather than its body, and one uncovered branch is exactly the defect
	# `docs/97` section 20 went looking for. The fixture carries the figure
	# the capture earned; a re-emit that lost a vector would lower it.
	h.equal("arm_lines_covered",
		DictRead.as_int(document.get("arm_lines_covered", 0)),
		ARM_LINES_COVERED,
		"%d of the transcribed arm lines are executed by the comparison "
		% ARM_LINES_COVERED + "against the engine, not merely transcribed")
	h.equal("arm_lines_total",
		DictRead.as_int(document.get("arm_lines_total", 0)), ARM_LINES_TOTAL,
		"out of %d" % ARM_LINES_TOTAL)
	# And the boundary this suite prints is still the weaker one, on purpose.
	h.check("oracle_is_still_executable_python",
		DictRead.as_string(document.get("oracle", "")).begins_with(
			"executable-Python"),
		"the fixture says transcription-against-transcription in its own words")


## `0x004039A0` -- the last of the five services, on the eight vectors the
## native sweep put through it.
##
## The fixture carries the **Python** twin's answers to those eight, and
## `tools/blob_gold.py` compares the same eight against the engine's own. So
## this half is twin against twin and that half is twin against the process,
## and neither is asked to stand in for the other.
func _check_rotate(h: TestHarness, document: Dictionary,
		measured: Eng3dGeometry) -> void:
	var raw: Variant = document.get("eng3d")
	var block: Dictionary = DictRead.as_dict(raw)
	var rotations: Array = DictRead.as_array(block.get("rotations", []))
	h.check("rotate_cases_present", rotations.size() == ROTATE_CASES,
		"the fixture carries %d rotation(s)" % ROTATE_CASES)
	var bad: int = 0
	for row: Variant in rotations:
		var triple: Array = DictRead.as_array(row)
		if triple.size() != 3:
			bad += 1
			continue
		var vector: Vector3i = _as_vector3i(DictRead.as_array(triple[0]))
		var angles: Vector3i = _as_vector3i(DictRead.as_array(triple[1]))
		var want: Vector3i = _as_vector3i(DictRead.as_array(triple[2]))
		if measured.rotate(vector, angles) != want:
			bad += 1
	h.equal("rotate_matches_python", bad, 0,
		"every captured vector goes through _E3D_init_matrix_RzRxRy the same way")
	# The three properties that separate this builder from its neighbour, each
	# stated so a GDScript-side regression fails here and not only in Python.
	h.equal("rotate_identity_loses_a_unit",
		measured.rotate(Vector3i(1000, 0, 0), Vector3i.ZERO), Vector3i(999, 0, 0),
		"the engine's identity rotation is 16383/16384, not 1")
	h.equal("rotate_negates_its_angles",
		measured.matrix3(0, 0, 1024)[1], -measured.sine(1024),
		"the builder indexes the table with the opposite turn")
	h.equal("rotate_reads_by_column",
		Eng3dGeometry.transform(_column_probe(), Vector3i(0, 1, 0)),
		Vector3i(1, 0, 0),
		"output i reads m[i], m[i+3], m[i+6]")


## A matrix whose only non-zero entry is m[3], one in Q14.
static func _column_probe() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for index: int in range(9):
		out.append(1 << Eng3dGeometry.Q14_SHIFT if index == 3 else 0)
	return out


static func _as_vector3i(values: Array) -> Vector3i:
	if values.size() != 3:
		return Vector3i.ZERO
	return Vector3i(DictRead.as_int(values[0]), DictRead.as_int(values[1]),
		DictRead.as_int(values[2]))


func _geometry(document: Dictionary) -> Eng3dGeometry:
	if _cached_geometry != null:
		return _cached_geometry
	var raw: Variant = document.get("eng3d")
	if not (raw is Dictionary):
		return null
	_cached_geometry = Eng3dGeometry.from_document(DictRead.as_dict(raw))
	return _cached_geometry


var _cached_geometry: Eng3dGeometry = null


func _seeded_blob(kind: int, document: Dictionary) -> Blob:
	for entry: Variant in DictRead.as_array(document["cases"]):
		var kase: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_int(kase["kind"]) == kind \
				and DictRead.as_string(kase["scenario"]) == "profile":
			return Blob.make(DictRead.as_dict(kase["blob"]))
	return Blob.new()


func _as_vector(values: PackedInt32Array) -> Vector3i:
	if values.size() < 3:
		return Vector3i.ZERO
	return Vector3i(values[0], values[1], values[2])


func _as_strings(values: Array) -> Array[String]:
	var out: Array[String] = []
	for value: Variant in values:
		out.append(DictRead.as_string(value))
	return out


func _as_ints(values: Array) -> Array[int]:
	var out: Array[int] = []
	for value: Variant in values:
		out.append(DictRead.as_int(value))
	return out


func _first(lines: PackedStringArray) -> String:
	var shown: PackedStringArray = PackedStringArray()
	for index: int in range(mini(REPORTED, lines.size())):
		shown.append(lines[index])
	var text: String = "; ".join(shown)
	if lines.size() > REPORTED:
		text += " (and %d more)" % (lines.size() - REPORTED)
	return text
