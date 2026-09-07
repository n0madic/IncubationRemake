extends TestSuite

## Oracle boundary: **native runtime** -- the four cell placers and the round
## tick of docs/42 section 9.1, replayed against the cells and the object array
## `Incubation.exe` itself left.
##
## `tools/presentation_gold.py` loads the fixture save inside the running
## engine, reads the whole control map and the whole 80-slot special-object
## array, calls one placer with controlled tiles and reads both back;
## `--emit-special-cases` writes the before state, the arguments and the after
## state of every call. This suite runs [CellObjects] from the same before
## state and requires every cell away from idle, and every taken slot, to
## agree.
##
## **What that settles.** The mine a Plasma-armed shot leaves, the nine fires
## weapon 40 lays, the shield's two-round countdown and the way all of them
## clear themselves at the round boundary are the engine's own writes, not the
## remake's reading of a listing. One case is the *refusal* that matters most:
## the capture runs on `World_A00`, which carries no `GLOW1/2.3DI`, so
## `SetGroundFire`'s glow placer writes nothing at all -- the model name is a
## gate and the suite holds the twin to it.

const CASES: String = "res://generated/presentation/special.json"
const SCHEMA: String = "incubation.special-cases/1"
## The eight phases the kept capture holds; a thinner fixture fails.
const LEAST_CASES: int = 10
## How many calls they make between them.
const LEAST_STEPS: int = 18
const REPORT_LIMIT: int = 4


func run(h: TestHarness) -> void:
	h.begin("ctrl_map", TestHarness.ORACLE_NATIVE)
	if not FileAccess.file_exists(CASES):
		h.check("fixture", false,
			"run python3 tools/presentation_gold.py --emit-special-cases "
			+ "tests/fixtures/presentation/cases_special.json "
			+ "--root gog_incubation")
		return
	var document: Dictionary = CacheLoader.read_json(CASES)
	if not h.equal("schema", document.get("schema"), SCHEMA):
		return
	var models: PackedStringArray = DictRead.to_strings(document["models"])
	h.check("world_set.has_no_glow",
		not models.has(CellObjects.GLOW_MODEL_FRESH),
		"%s carries %s" % [DictRead.as_string(document["world_set"]), models])
	var cases: Array = DictRead.as_array(document["cases"])
	h.check("cases", cases.size() >= LEAST_CASES,
		"%d case(s), at least %d expected" % [cases.size(), LEAST_CASES])
	var steps: int = 0
	var glowed: bool = false
	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		# Each case names the models **its own** world set carries: two of
		# them run on `_C_116`, a `World_D00` mission, which is the one set
		# that has `GLOW1/2.3DI`.
		var own: PackedStringArray = DictRead.to_strings(
			kase.get("models", models))
		if own.has(CellObjects.GLOW_MODEL_FRESH):
			glowed = true
		steps += _replay(h, kase, own)
	h.check("cases.reach_the_glow", glowed,
		"a D00 case is what measures the glow's own lifecycle")
	h.check("steps", steps >= LEAST_STEPS,
		"%d call(s), at least %d expected" % [steps, LEAST_STEPS])


## One phase: the before state, then every call in order.
func _replay(h: TestHarness, kase: Dictionary, models: PackedStringArray) -> int:
	var name: String = DictRead.as_string(kase["name"])
	var state: MapState = _state_of(kase, models)
	var steps: Array = DictRead.as_array(kase["steps"])
	var ran: int = 0
	for entry: Variant in steps:
		var step: Dictionary = DictRead.as_dict(entry)
		var routine: String = DictRead.as_string(step["routine"])
		var args: PackedInt32Array = DictRead.to_int32(step["args"])
		var made: int = _call(state, routine, args)
		ran += 1
		var label: String = "%s.%d.%s" % [name, ran - 1, routine]
		_positions(h, label, state, kase, step, made)
		h.equal(label + ".cells", _sparse(state),
			_rows(DictRead.as_array(step["cells"])),
			"every cell away from idle, as the engine left it")
		h.equal(label + ".objects", _objects(state),
			_rows(DictRead.as_array(step["objects"])),
			"every taken slot of the 80")
	return ran


## Answers the object id the call made, or -1.
func _call(state: MapState, routine: String, args: PackedInt32Array) -> int:
	match routine:
		"aMakeFire":
			return CellObjects.place_fire(state, args[0], args[1], args[2],
				args[3])
		"aMakeMine":
			return CellObjects.place_mine(state, args[0], args[1])
		"aMakeShield":
			return CellObjects.place_shield(state, args[0], args[1])
		"aMakeGlow":
			return CellObjects.place_glow(state, args[0], args[1], args[2])
		"aGroundEffectsTick":
			var _changed: PackedInt32Array = CellObjects.round_tick(state)
	return -1


## The object's **position**: the cell's own object plus the scatter the fire
## and the glow draw, against the record the engine left.
func _positions(h: TestHarness, label: String, state: MapState,
		kase: Dictionary, step: Dictionary, made: int) -> void:
	if made < 0:
		return
	var origins: Dictionary = DictRead.as_dict(kase["origins"])
	var kind: int = state.object_state(made)
	# The emitter writes which origin the call places against -- "m" and "a"
	# for the two tiles of the capture's own scene, "g" for the two `World_D00`
	# phases, which carry that one alone. Deriving it here from the phase name
	# once made both D00 cases abort on a missing key and skip this check
	# while the suite still reported its full count.
	if not step.has("origin"):
		h.equal(label + ".origin_key_present", false, true,
			"the case file predates the per-step origin; re-emit it with "
			+ "presentation_gold.py --emit-special-cases")
		return
	var key: String = DictRead.as_string(step["origin"])
	var origin: Vector3i = DictRead.as_vector3i(origins[key])
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(DictRead.as_float(kase["seed"]))
	var got: Vector3i = CellObjects.object_position(origin, kind, rng)
	var want: Vector3i = Vector3i.ZERO
	for entry: Variant in DictRead.as_array(step["positions"]):
		var row: PackedInt32Array = DictRead.to_int32(entry)
		if row[0] == made:
			want = Vector3i(row[1], row[2], row[3])
	h.equal(label + ".position", got, want,
		"the cell's own object plus the two aRandom2 draws the fire and the "
		+ "glow spend")


## The capture's before state as a [MapState]: the map's own heights, field
## types and action points, with the sparse effect rows applied.
func _state_of(kase: Dictionary, models: PackedStringArray) -> MapState:
	var width: int = DictRead.as_int(kase["width"])
	var height: int = DictRead.as_int(kase["height"])
	var n: int = width * height
	var zeros: Array = []
	var links: Array = []
	var idle: Array = []
	for _i: int in range(n):
		zeros.append(0)
		links.append(-1)
		idle.append(255)
	var document: Dictionary = {
		"width": width, "height": height,
		"header": {"name": DictRead.as_string(kase["name"]), "next_map": "",
			"map_type": 0, "mission_id": 0, "world_set": "",
			"world_scene": "", "camera_height": 0,
			"equip_points": [0, 0, 0, 0], "skill_level": 0, "tech_level": 0},
		"cells": {
			"height": DictRead.as_array(kase["heights"]),
			"field_type": DictRead.as_array(kase["field_types"]),
			"action_point": DictRead.as_array(kase["action_points"]),
			"unit": links,
			"effect0": zeros, "effect1": idle, "effect2": idle,
			"effect3": idle, "effect4": zeros, "effect5": idle,
			"land": zeros, "start_index": links},
	}
	var state: MapState = MapState.from_resource(
		MapResource.from_document(document))
	state.set_special_models(models)
	for entry: Variant in DictRead.as_array(kase["before"]):
		var row: PackedInt32Array = DictRead.to_int32(entry)
		for slot: int in range(MapState.EFFECT_SLOTS):
			state.set_effect(slot, row[0], row[slot + 1])
	# **Rebuilt, then cross-checked against the capture.** `_C_116` loads
	# with slot 0 holding a static object no effect byte names: the
	# victory-point marker `0x00431E30` stands on its one cell with action
	# point 81 (docs/42 section 9.3). `rebuild_objects` places it since
	# 2026-09-07; the capture's `objects_before` writes the same 5 over it,
	# so a rebuild that put the marker anywhere else would be caught by the
	# phases' object diffs rather than hidden by the seeding.
	state.rebuild_objects()
	for entry: Variant in DictRead.as_array(kase.get("objects_before", [])):
		var row: PackedInt32Array = DictRead.to_int32(entry)
		state.set_object_state(row[0], row[1])
	return state


## Every cell away from idle, as `[index, +0x0E .. +0x13]`.
func _sparse(state: MapState) -> Array:
	var idle: PackedInt32Array = PackedInt32Array([0, 255, 255, 255, 0, 255])
	var out: Array = []
	for i: int in range(state.cell_count()):
		var row: Array = [i]
		var away: bool = false
		for slot: int in range(MapState.EFFECT_SLOTS):
			var value: int = state.effect_at(slot, i)
			row.append(value)
			if value != idle[slot]:
				away = true
		if away:
			out.append(row)
	return out


func _objects(state: MapState) -> Array:
	var out: Array = []
	for oid: int in range(MapState.SPECIAL_OBJECT_SLOTS):
		if state.object_state(oid) != MapState.NO_OBJECT:
			out.append([oid, state.object_state(oid)])
	return out


## The case file's rows as plain `Array`s of `int`, so the compare is a value
## compare and not a float-versus-int one: `JSON.parse_string` makes every
## number a `float`.
func _rows(values: Array) -> Array:
	var out: Array = []
	for entry: Variant in values:
		out.append(Array(DictRead.to_int32(entry)))
	return out
