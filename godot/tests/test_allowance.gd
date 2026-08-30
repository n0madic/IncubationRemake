extends TestSuite

## Oracle boundary: **native runtime**.  `aGetMovePoints` (`0x00475160`) called
## inside a running `Incubation.exe` on `_C_141`.
##
## Thirty-seven calls: every live slot as the save holds it, then the Servo
## System, the Heavy Armor, both together, all three fitness arms, the rested
## bonus with and without an override in front of it, both suppressing action
## states, and the Banner at seven placements plus one owned by someone else.
##
## The placements are what decides a question docs/10 section 5.5 left open.
## "Within 4 fields" is ambiguous between Chebyshev and the Euclidean distance
## the rest of the engine uses; a carrier three fields along **and** three
## fields up does not count, so it is `aGetDistance` -- floor-Euclidean -- and
## strictly below four.

const CASES: String = "allowance"
const SCHEMA: String = "incubation.allowance-cases/1"


func run(h: TestHarness) -> void:
	h.begin("allowance", TestHarness.ORACLE_NATIVE)
	var document: Dictionary = MoveMapCaseRunner.load_named(CASES)
	if document.is_empty():
		h.check("fixture", false,
			"run tools/movemap_gold.py --emit-allowance-cases")
		return
	if DictRead.as_string(document.get("schema", "")) != SCHEMA:
		h.check("schema", false, "unexpected schema")
		return
	var ai_level: int = DictRead.as_int(document["ai_level"])
	var cases: Array = DictRead.as_array(document["cases"])
	var tags: Dictionary = {}
	for entry: Variant in cases:
		var case: Dictionary = DictRead.as_dict(entry)
		var name: String = DictRead.as_string(case["name"])
		tags[name] = DictRead.as_int(case["expected"])
		var built: Dictionary = _build(case)
		var units: Dictionary = DictRead.as_dict(built["units"])
		var mover: UnitState = units[DictRead.as_int(case["slot"])]
		var table: UnitTypeTable = built["unit_types"]
		h.equal(name, Allowance.for_unit(mover, table, units, ai_level),
			DictRead.as_int(case["expected"]))
	h.check("count", cases.size() >= 30, "%d native calls" % cases.size())

	# The metric, stated as its own check rather than left implicit in the two
	# case results above: Chebyshev would put (3,3) in range and make these
	# equal.
	var near: String = "_C_141.banner+3,0"
	var diagonal: String = "_C_141.banner+3,3"
	if tags.has(near) and tags.has(diagonal):
		h.check("banner_is_euclidean",
			DictRead.as_int(tags[near]) > DictRead.as_int(tags[diagonal]),
			"a Banner three fields along counts and one three along and " \
			+ "three up does not, so the reach is floor-Euclidean below 4")

	# An unknown AI level is the engine's "incorrect ai level!" arm, which
	# leaves the accumulator at zero.  No capture can show it -- 0x00460450
	# cannot return 3 -- so it is asserted from the code.
	var solo: UnitState = UnitState.new()
	solo.type_id = Allowance.DIFFICULTY_TWEAK_TYPE
	solo.hp = 1
	solo.fp = 255
	var only: Dictionary = {0: solo}
	var table_one: UnitTypeTable = UnitTypeTable.from_rows([{
		"id": Allowance.DIFFICULTY_TWEAK_TYPE, "mp_max": 6, "fp_max": 255, "hp_max": 0,
		"special": 0, "size": 0, "species": 0, "height": 0, "model": "",
		"armour_front": 255, "armour_rear": 255,
		"description": "difficulty-tweaked type",
	}])
	h.equal("ai_level.bad", Allowance.for_unit(solo, table_one, only, 3), 0)
	h.equal("ai_level.0", Allowance.for_unit(solo, table_one, only, 0), 5)
	h.equal("ai_level.1", Allowance.for_unit(solo, table_one, only, 1), 6)
	h.equal("ai_level.2", Allowance.for_unit(solo, table_one, only, 2), 6)

	# The byte accumulator, which no shipped unit reaches: a type with no
	# movement points at all, wearing Heavy Armor, wraps to 255 and the guard
	# at 0x0047521F turns that into 0 rather than into a huge allowance.
	var zero: UnitState = UnitState.new()
	zero.type_id = 1
	zero.hp = 1
	zero.fp = 255
	zero.equipment = PackedInt32Array([Allowance.EQUIP_HEAVY_ARMOR])
	var table_zero: UnitTypeTable = UnitTypeTable.from_rows([{
		"id": 1, "mp_max": 0, "fp_max": 255, "hp_max": 0, "special": 0, "size": 0,
		"species": 0, "height": 0, "model": "",
		"armour_front": 255, "armour_rear": 255, "description": "immobile",
	}])
	h.equal("byte_wrap_guard",
		Allowance.for_unit(zero, table_zero, {0: zero}), 0)


## The roster of one case, as [UnitState] objects and a [UnitTypeTable].
func _build(case: Dictionary) -> Dictionary:
	var units: Dictionary = {}
	var rows: Array = []
	var seen: Dictionary = {}
	var records: Array = DictRead.as_array(case["units"])
	for entry: Variant in records:
		var record: Dictionary = DictRead.as_dict(entry)
		var unit: UnitState = UnitState.new()
		unit.slot = DictRead.as_int(record["slot"])
		unit.type_id = DictRead.as_int(record["type_id"])
		unit.player = DictRead.as_int(record["player"])
		unit.x = DictRead.as_int(record["x"])
		unit.y = DictRead.as_int(record["y"])
		unit.hp = DictRead.as_int(record["hp"])
		unit.fp = DictRead.as_int(record["fp"])
		unit.rested = DictRead.as_int(record["rested"])
		unit.action_state = DictRead.as_int(record["action_state"])
		unit.equipment = DictRead.to_int32(record["equipment_ids"])
		units[unit.slot] = unit
		if not seen.has(unit.type_id):
			seen[unit.type_id] = true
			rows.append({
				"id": unit.type_id,
				"mp_max": DictRead.as_int(record["mp_max"]),
				"fp_max": 255,
				"hp_max": 0, "special": 0, "size": 0, "species": 0,
				"height": 0, "model": "",
				"armour_front": 255, "armour_rear": 255,
				"description": "type %d" % unit.type_id,
			})
	return {"units": units, "unit_types": UnitTypeTable.from_rows(rows)}
