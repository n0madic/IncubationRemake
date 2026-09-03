class_name MoveMapCaseRunner
extends RefCounted

## Runs `godot/generated/movemap/*.json` case files through [MoveMap].
##
## One shape, three producers: the synthetic cases and the slice mission come
## from `tools/inclib/movemap.py`, and the native file is `aBuildMoveMap` itself
## re-expressed from a live capture.  Each case carries its **whole** input --
## the grid, the obstacle byte, every unit, the delay column -- so the two
## implementations receive byte-identical inputs by construction rather than by
## agreement, and a suite's only choice is which oracle boundary it declares.

## Production has no case files at all -- they are a test input -- so an
## exported test build reads them from `user://movemap/`, next to the cache it
## also reads from `user://`.
##
## **`res://generated` is looked at first.**  It used to be second, and a
## `user://` copy left behind by an earlier session then shadowed the fresh
## one: the run stayed green and got quietly smaller, which is exactly the
## failure `run_tests.sh`'s sentinel exists to prevent.  `run_tests.sh` writes
## `res://generated` on every run, and an exported build has no such directory,
## so this order makes the newest copy win in both.
const USER_CASES_DIR: String = "user://movemap"
const DEV_CASES_DIR: String = "res://generated/movemap"
const SCHEMA: String = "incubation.movemap-cases/1"


static func path_for(name: String) -> String:
	var in_dev: String = "%s/%s.json" % [DEV_CASES_DIR, name]
	if FileAccess.file_exists(in_dev):
		return in_dev
	return "%s/%s.json" % [USER_CASES_DIR, name]


## Any case file in the shared directory, whatever its schema.  [MoveMap]'s
## own files go through [method load_cases], which additionally pins the
## schema; the allowance suite has its own and reuses only the lookup.
static func load_named(name: String) -> Dictionary:
	var path: String = path_for(name)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return DictRead.as_dict(parsed)


static func load_cases(name: String) -> Dictionary:
	var path: String = path_for(name)
	if not FileAccess.file_exists(path):
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return DictRead.as_dict(parsed)


## Runs every case and reports one check per case.  Returns how many ran.
static func run_all(h: TestHarness, document: Dictionary) -> int:
	if DictRead.as_string(document.get("schema", "")) != SCHEMA:
		h.check("schema", false, "unexpected schema")
		return 0
	var cases: Array = DictRead.as_array(document["cases"])
	for entry: Variant in cases:
		run_one(h, DictRead.as_dict(entry))
	return cases.size()


static func run_one(h: TestHarness, case: Dictionary) -> void:
	var name: String = DictRead.as_string(case["name"])
	var built: Dictionary = build_world(case)
	var query: Dictionary = DictRead.as_dict(case["query"])
	var slot: int = DictRead.as_int(query["slot"])
	var units: Dictionary = DictRead.as_dict(built["units"])
	var mover: UnitState = units[slot]
	var unit_types: UnitTypeTable = built["unit_types"]
	var state: MapState = built["state"]
	var ctrlmap: CtrlMapTable = built["ctrlmap"]
	var result: MoveMapResult = MoveMap.build(
		state, units, unit_types, ctrlmap,
		slot, DictRead.as_bool(query["pass_friendlies"]),
		mover.mp, unit_types.mp_max(mover.type_id))
	var expected: Dictionary = DictRead.as_dict(case["expected"])
	h.equal_bytes("%s.state" % name, result.states(),
		DictRead.to_bytes(expected["state"]))
	h.equal_ints("%s.mp_left" % name, result.mp_left(),
		DictRead.to_int32(expected["mp_left"]))
	h.equal("%s.any_friendly_blocked" % name, result.any_friendly_blocked,
		DictRead.as_bool(expected["any_friendly_blocked"]))
	if expected.has("walks"):
		_run_walks(h, name, state, units, ctrlmap, result,
			mover, DictRead.as_array(expected["walks"]))


## `aWalkMoveMap` over the same fill the case just checked.
##
## The engine's overlay records a path as a **set** of cells marked 100, not as
## an order, so the native cases compare sorted cell indices; the executable
## model additionally carries the order, and where a case has it the order is
## compared too.
static func _run_walks(h: TestHarness, name: String, state: MapState,
		units: Dictionary, ctrlmap: CtrlMapTable, result: MoveMapResult,
		mover: UnitState, walks: Array) -> void:
	for entry: Variant in walks:
		var walk: Dictionary = DictRead.as_dict(entry)
		var tx: int = DictRead.as_int(walk["tx"])
		var ty: int = DictRead.as_int(walk["ty"])
		var tag: String = "%s.walk(%d,%d)" % [name, tx, ty]
		var got: Dictionary = WalkMap.path(state, units, ctrlmap, result,
			mover.x, mover.y, tx, ty)
		var ok: bool = DictRead.as_bool(got["ok"])
		h.equal("%s.ok" % tag, ok, DictRead.as_bool(walk["ok"]))
		if not ok:
			continue
		h.equal("%s.steps" % tag, DictRead.as_int(got["steps"]),
			DictRead.as_int(walk["steps"]))
		h.equal("%s.blocked" % tag, DictRead.as_int(got["blocked"]),
			DictRead.as_int(walk["blocked"]))
		var want: PackedInt32Array = DictRead.to_int32(walk["path"])
		var mine: PackedInt32Array = got["path"]
		var sorted_want: Array = Array(want)
		var sorted_mine: Array = Array(mine)
		sorted_want.sort()
		sorted_mine.sort()
		# The engine marks a cell once however often the walk crosses it, so
		# the comparison is over the marked set.
		var unique: Array = []
		for index: Variant in sorted_mine:
			if unique.is_empty() or unique[unique.size() - 1] != index:
				unique.append(index)
		h.equal("%s.path" % tag, str(unique), str(sorted_want))


## Builds the pieces [MoveMap] needs from one case.
static func build_world(case: Dictionary) -> Dictionary:
	var width: int = DictRead.as_int(case["width"])
	var height: int = DictRead.as_int(case["height"])
	var cells: Dictionary = DictRead.as_dict(case["cells"])

	var ctrl_rows: Array = []
	var delays: Dictionary = DictRead.as_dict(case["delays"])
	for key: Variant in delays:
		ctrl_rows.append({
			"index": DictRead.as_string(key).to_int(),
			"delay": DictRead.as_int(delays[key]),
			"name": "type " + DictRead.as_string(key),
		})

	var type_rows: Array = []
	var seen: Dictionary = {}
	var units: Dictionary = {}
	var records: Array = DictRead.as_array(case["units"])
	for entry: Variant in records:
		var record: Dictionary = DictRead.as_dict(entry)
		var type_id: int = DictRead.as_int(record["type_id"])
		if not seen.has(type_id):
			seen[type_id] = true
			type_rows.append({
				"id": type_id,
				"mp_max": DictRead.as_int(record["mp_allowance"]),
				"fp_max": 255, "hp_max": 0,
				"special": DictRead.as_int(record["special"]),
				"size": DictRead.as_int(record["size"]),
				"species": 0,
				"height": 0,
				"armour_front": 255, "armour_rear": 255,
				"model": "",
				"description": "type %d" % type_id,
			})
		var unit: UnitState = UnitState.new()
		unit.slot = DictRead.as_int(record["slot"])
		unit.type_id = type_id
		unit.player = DictRead.as_int(record["player"])
		unit.x = DictRead.as_int(record["x"])
		unit.y = DictRead.as_int(record["y"])
		unit.mp = DictRead.as_int(record["mp"])
		unit.hp = 1
		unit.visibility = DictRead.as_int(record["visibility"])
		unit.equipment = DictRead.to_int32(record["equipment_ids"])
		# The walk's visibility passes read and write these (docs/22 section
		# 9.3); a fill-only case carries none, and none is what they get.
		unit.order = DictRead.as_int(record.get("order", 0))
		unit.order_param = DictRead.as_int(record.get("order_param", 0))
		unit.order2 = DictRead.as_int(record.get("order2", 0))
		unit.order2_param = DictRead.as_int(record.get("order2_param", 0))
		unit.group = DictRead.as_int(record.get("group", 0))
		units[unit.slot] = unit

	var zeros: Array = []
	var links: Array = []
	# The idle value of the three object slots and the obstacle byte.
	var idle: Array = []
	for _i: int in range(width * height):
		zeros.append(0)
		links.append(-1)
		idle.append(255)

	var document: Dictionary = {
		"width": width,
		"height": height,
		"header": {
			"name": DictRead.as_string(case["name"]), "next_map": "",
			"map_type": 0, "mission_id": 0, "world_set": "", "world_scene": "",
			"camera_height": 0, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0,
		},
		"cells": {
			"height": cells["height"],
			"field_type": cells["field_type"],
			"action_point": cells["action_point"],
			"unit": cells["unit"],
			# The fill reads none of these; they are zeroed rather than
			# invented, so a case file never looks like it asserts them.
			"effect0": zeros, "effect1": idle, "effect2": idle,
			"effect3": idle, "effect4": zeros, "effect5": idle,
			"land": zeros, "start_index": links,
		},
	}
	var res: MapResource = MapResource.from_document(document)
	var state: MapState = MapState.from_resource(res)
	var obstacles: PackedByteArray = DictRead.to_bytes(cells["obstacle"])
	for i: int in range(obstacles.size()):
		state.set_obstacle(i, obstacles[i])
	return {
		"resource": res,
		"state": state,
		"units": units,
		"ctrlmap": CtrlMapTable.from_rows(ctrl_rows),
		"unit_types": UnitTypeTable.from_rows(type_rows),
	}


## The combat case's world: the same cells, plus **full** unit records and the
## real balance rows.
##
## Separate from [method build_world] because the two carry different things.
## The move cases synthesise a unit-type table out of the columns the fill
## reads; a shot reads the shipped rows, and a case that invented them would
## agree with the engine only by luck.
static func build_combat_world(case: Dictionary, types_doc: Dictionary,
		records: Array) -> Dictionary:
	var width: int = DictRead.as_int(case["width"])
	var height: int = DictRead.as_int(case["height"])
	var cells: Dictionary = DictRead.as_dict(case["cells"])

	var zeros: Array = []
	var links: Array = []
	# The idle value of the three object slots and the obstacle byte.
	var idle: Array = []
	for _i: int in range(width * height):
		zeros.append(0)
		links.append(-1)
		idle.append(255)
	var document: Dictionary = {
		"width": width, "height": height,
		"header": {
			"name": DictRead.as_string(case["name"]), "next_map": "",
			"map_type": 0, "mission_id": 0, "world_set": "", "world_scene": "",
			"camera_height": 0, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0,
		},
		"cells": {
			"height": cells["height"], "field_type": cells["field_type"],
			"action_point": cells["action_point"], "unit": cells["unit"],
			"effect0": zeros, "effect1": idle, "effect2": idle,
			"effect3": idle, "effect4": zeros, "effect5": idle,
			"land": zeros, "start_index": links,
		},
	}
	var res: MapResource = MapResource.from_document(document)
	var state: MapState = MapState.from_resource(res)
	var obstacles: PackedByteArray = DictRead.to_bytes(cells["obstacle"])
	for i: int in range(obstacles.size()):
		state.set_obstacle(i, obstacles[i])

	var units: Dictionary = {}
	for entry: Variant in records:
		var unit: UnitState = combat_unit(DictRead.as_dict(entry))
		units[unit.slot] = unit
	return {
		"resource": res,
		"state": state,
		"units": units,
		"unit_types": UnitTypeTable.from_rows(
			DictRead.as_array(types_doc["units"])),
		"weapons": WeaponTable.from_rows(
			DictRead.as_array(types_doc["weapons"])),
	}


## One `COMBAT_UNIT_FIELDS` record as a [UnitState].
static func combat_unit(record: Dictionary) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.slot = DictRead.as_int(record["slot"])
	unit.type_id = DictRead.as_int(record["type_id"])
	unit.player = DictRead.as_int(record["player"])
	unit.x = DictRead.as_int(record["x"])
	unit.y = DictRead.as_int(record["y"])
	unit.hp = DictRead.as_int(record["hp"])
	unit.facing = DictRead.as_int(record["facing"])
	unit.fp = DictRead.as_int(record["fp"])
	unit.mp = DictRead.as_int(record["mp"])
	unit.weapon = DictRead.as_int(record["weapon"])
	unit.ammo = DictRead.as_int(record["ammo"])
	unit.heat = DictRead.as_int(record["heat"])
	unit.malfunction = DictRead.as_int(record["malfunction"])
	unit.absorber = DictRead.as_int(record["absorber"])
	unit.rested = DictRead.as_int(record.get("rested", 0))
	unit.armour_front = DictRead.as_int(record["armour_front"])
	unit.armour_rear = DictRead.as_int(record["armour_rear"])
	unit.action_state = DictRead.as_int(record["action_state"])
	unit.acted = DictRead.as_int(record["acted"])
	unit.ticket = DictRead.as_int(record["ticket"])
	unit.visibility = DictRead.as_int(record["visibility"])
	unit.order = DictRead.as_int(record["order"])
	unit.order_param = DictRead.as_int(record["order_param"])
	unit.order2 = DictRead.as_int(record["order2"])
	unit.order2_param = DictRead.as_int(record["order2_param"])
	unit.group = DictRead.as_int(record["group"])
	unit.turn_start_x = DictRead.as_int(record["turn_start_x"])
	unit.turn_start_y = DictRead.as_int(record["turn_start_y"])
	unit.ep = DictRead.as_int(record["ep"])
	unit.tp = DictRead.as_int(record["tp"])
	unit.kills = DictRead.as_int(record["kills"])
	unit.skills = DictRead.to_int32(record["skills"])
	unit.equipment = DictRead.to_int32(record["equipment_ids"])
	return unit


## The world one LCL replay case runs on.
##
## A third builder, and for the reason the case file states: the `.lev` a
## mission ships and the `map.json` the converter writes are built from the same
## file but not from the same **set** of records -- `active_units` is "has a
## name" and the interpreter's roster is "has hit points", and `_C_140` differs
## by two slots. The case carries its own world so the two implementations
## cannot disagree about what they were given.
static func build_lcl_world(case: Dictionary) -> Dictionary:
	var width: int = DictRead.as_int(case["width"])
	var height: int = DictRead.as_int(case["height"])
	var cells: Dictionary = DictRead.as_dict(case["cells"])
	var zeros: Array = []
	var links: Array = []
	# The idle value of the three object slots and the obstacle byte.
	var idle: Array = []
	for _i: int in range(width * height):
		zeros.append(0)
		links.append(-1)
		idle.append(255)
	var document: Dictionary = {
		"width": width, "height": height,
		"header": {
			"name": DictRead.as_string(case["mission"]), "next_map": "",
			"map_type": 0, "mission_id": 0, "world_set": "", "world_scene": "",
			"camera_height": 0, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0,
		},
		"cells": {
			"height": cells["height"], "field_type": cells["field_type"],
			"action_point": cells["action_point"], "unit": cells["unit"],
			"effect0": zeros, "effect1": idle, "effect2": idle,
			"effect3": idle, "effect4": zeros, "effect5": idle,
			"land": zeros, "start_index": links,
		},
	}
	var res: MapResource = MapResource.from_document(document)
	var units: Dictionary = {}
	for entry: Variant in DictRead.as_array(case["units"]):
		var unit: UnitState = lcl_unit(DictRead.as_dict(entry))
		units[unit.slot] = unit
	return {
		"state": MapState.from_resource(res),
		"units": units,
		"unit_types": UnitTypeTable.from_rows(
			DictRead.as_array(case["types"])),
	}


## One `CASE_UNIT_FIELDS` record as a [UnitState].
static func lcl_unit(record: Dictionary) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.slot = DictRead.as_int(record["slot"])
	unit.player = DictRead.as_int(record["player"])
	unit.type_id = DictRead.as_int(record["type_id"])
	unit.x = DictRead.as_int(record["x"])
	unit.y = DictRead.as_int(record["y"])
	unit.hp = DictRead.as_int(record["hit_points"])
	unit.group = DictRead.as_int(record["group"])
	unit.ammo = DictRead.as_int(record["ammo"])
	unit.ep = DictRead.as_int(record["ep"])
	unit.tp = DictRead.as_int(record["tp"])
	unit.pool_flag = DictRead.as_int(record["pool_flag"])
	unit.speech = DictRead.as_int(record["speech"])
	unit.name = DictRead.as_string(record["name"])
	return unit
