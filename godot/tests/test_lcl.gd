extends TestSuite

## Oracle boundary: **executable Python**, which is itself checked against all
## 153 shipped scripts and pinned natively for one `NextPlayer` on `_C_141`.
##
## `tools/lcl_runtime.py --emit-cases` replays four missions through
## `inclib/lcl_runtime.py` -- every entry point at five `(turn, player)`
## settings -- and writes what each run produced. This suite runs the *same*
## programs on the *same* worlds through [LclInterpreter] and diffs the two
## documents.
##
## **Four missions, not 153.** The converter ships four maps and the corpus-wide
## `N/N` stays in Python, where the other 149 `.lev` files are. What this side
## proves is that the transcription agrees, not that the corpus parses.
##
## The turn settings matter as much as the call types: `_C_140`'s `NEXT TURN`
## opens two tubes on turn 4 and its `NEXT PLAYER` inserts reinforcements from
## turn 5. A replay at turn 1 alone would compare an empty delta with an empty
## delta on every case.

const DEV_CASES: String = "res://generated/lcl/lcl.json"
const USER_CASES: String = "user://lcl/lcl.json"
const SCHEMA: String = "incubation.lcl-cases/2"
## The native pin lives in the turn capture, because that is the session it was
## taken in; the *program* comes from the replay file, which is the only place
## a parsed script is.
const TURN_DEV_CASES: String = "res://generated/turn/turn.json"
const TURN_USER_CASES: String = "user://turn/turn.json"
const NATIVE_MISSION: String = "_C_141"
const REPORT_LIMIT: int = 6


static func _path() -> String:
	if FileAccess.file_exists(DEV_CASES):
		return DEV_CASES
	return USER_CASES


func run(h: TestHarness) -> void:
	h.begin("lcl", TestHarness.ORACLE_PYTHON)
	var path: String = _path()
	if not FileAccess.file_exists(path):
		h.check("fixture", false,
			"run tools/lcl_runtime.py --emit-cases tests/fixtures/lcl/cases_lcl.json")
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		h.check("fixture.parses", false, "not a JSON object")
		return
	var doc: Dictionary = parsed
	if DictRead.as_string(doc["schema"]) != SCHEMA:
		h.check("fixture.schema", false, DictRead.as_string(doc["schema"]))
		return
	_script_cameras(h)

	var arrays: PackedStringArray = PackedStringArray()
	for name: Variant in DictRead.as_array(doc["cell_arrays"]):
		arrays.append(DictRead.as_string(name))
	var ai_level: int = DictRead.as_int(doc["ai_level"])
	var missions: Array = DictRead.as_array(doc["missions"])
	h.check("missions.present", not missions.is_empty(),
		"%d mission(s)" % missions.size())

	var total: int = 0
	var reached: Dictionary = {}
	for entry: Variant in missions:
		total += _mission(h, DictRead.as_dict(entry), arrays, ai_level,
			reached)
	h.check("cases.replayed", total > 0, "%d case(s)" % total)
	# A replay in which nothing ever happened would agree with an interpreter
	# that did nothing. These three say the corpus reached the arms that write.
	h.check("cases.reached_a_cell_write",
		DictRead.as_bool(reached.get("cells", false)),
		"at least one case changed the map")
	h.check("cases.reached_a_spawn",
		DictRead.as_bool(reached.get("spawn", false)),
		"at least one case inserted a unit")
	h.check("cases.reached_a_generator",
		DictRead.as_bool(reached.get("rng", false)),
		"at least one case drew from aRandom or from the C runtime")

	_native(h, missions, ai_level)
	_synthetic(h)


## The one native pin the interpreter has -- `tools/turn_gold.py` phase 6.
##
## `0x0043F6E0` ran `_C_141`'s program with `_A = 1` inside the live engine, and
## the generator's seed was read either side: **1.0 before and 847344462.0
## after**, which is exactly two draws of `aRandom`, one per `SetVarRandom` in
## the body. That pins the arithmetic *and* says the interpreter reached both.
##
## The world is the capture's own unit array and not the shipped `.lev`:
## `_C_141` ships with ten crates and nothing else, so `GetUnits(0)` answers 0
## there and 4 in the save, and the script's "squad wiped out" arm would fire in
## the model and not in the engine.
func _native(h: TestHarness, missions: Array, ai_level: int) -> void:
	var turn_path: String = TURN_DEV_CASES
	if not FileAccess.file_exists(turn_path):
		turn_path = TURN_USER_CASES
	if not FileAccess.file_exists(turn_path):
		h.check("native.fixture", false,
			"run tools/turn_gold.py --emit-cases")
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(turn_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		h.check("native.fixture.parses", false, "not a JSON object")
		return
	var turn_doc: Dictionary = parsed
	var combat: Dictionary = DictRead.as_dict(turn_doc["combat"])
	var case: Dictionary = DictRead.as_dict(combat.get("lcl", {}))
	if case.is_empty():
		h.check("native.captured", false,
			"the capture holds no LCL phase; re-run --game-copy")
		return

	var entry: Dictionary = {}
	for record: Variant in missions:
		var candidate: Dictionary = DictRead.as_dict(record)
		if DictRead.as_string(candidate["mission"]) == NATIVE_MISSION:
			entry = candidate
	if entry.is_empty():
		h.check("native.program", false,
			"%s is not in the replay case file" % NATIVE_MISSION)
		return
	var program: LclProgram = LclProgram.from_document(
		DictRead.as_dict(entry["script"]))

	var built: Dictionary = MoveMapCaseRunner.build_combat_world(combat,
		DictRead.as_dict(turn_doc["types"]), DictRead.as_array(combat["units"]))
	var state: MapState = built["state"]
	var units: Dictionary = built["units"]
	var types: UnitTypeTable = built["unit_types"]
	var before: PackedByteArray = state.to_bytes()

	var turn: TurnState = TurnState.create()
	turn.turn = DictRead.as_int(case["turn"])
	turn.current_player = DictRead.as_int(case["player"])
	turn.ai_level = ai_level
	var control: GameControl = GameControl.from_array(
		DictRead.to_int32(case["slots_before"]))
	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(DictRead.as_float(case["seed_before"]))
	var context: LclContext = LclContext.create(state, units, types, turn,
		control, rng, CRandom.create(),
		DictRead.as_int(case["player"]), NATIVE_MISSION)
	var outcome: LclOutcome = LclInterpreter.run(program, context,
		LclEnv.of(DictRead.as_int(case["entry"]), turn.turn, turn.current_player))

	h.check("native.ran_to_the_end", outcome.ok(),
		"%s: %s" % [outcome.kind, outcome.reason])
	# The seed is the whole of it: two draws, and both the count and the value.
	h.equal("native.seed_matches_the_engine", rng.seed,
		DictRead.as_float(case["seed_after"]),
		"1.0 -> 847344462.0 is exactly two aRandom draws, one per SetVarRandom")
	h.equal("native.drew_twice", rng.calls, 2)
	h.equal_ints("native.game_control_matches_the_engine", control.values(),
		DictRead.to_int32(case["slots_after"]))
	h.equal_bytes("native.the_world_is_unchanged", state.to_bytes(), before,
		6)
	var unchanged: Array = DictRead.as_array(case["world_unchanged"])
	h.equal("native.the_engine_also_changed_nothing",
		[DictRead.as_bool(unchanged[0]), DictRead.as_bool(unchanged[1])],
		[true, true],
		"NEXT PLAYER on this save places nothing and moves nothing, so "
		+ "InsertUnit never fires")


func _mission(h: TestHarness, entry: Dictionary, arrays: PackedStringArray,
		ai_level: int, reached: Dictionary) -> int:
	var name: String = DictRead.as_string(entry["mission"])
	var program: LclProgram = LclProgram.from_document(
		DictRead.as_dict(entry["script"]))
	h.check("%s.program" % name, not program.is_empty(),
		"%d instruction(s), %d label(s)"
			% [program.instructions.size(), program.labels.size()])
	if program.is_empty():
		return 0

	var cases: Array = DictRead.as_array(entry["cases"])
	var outcome_bad: Array[String] = []
	var control_bad: Array[String] = []
	var cells_bad: Array[String] = []
	var units_bad: Array[String] = []
	var rng_bad: Array[String] = []
	var events_bad: Array[String] = []
	for record: Variant in cases:
		var case: Dictionary = DictRead.as_dict(record)
		var tag: String = "call %d turn %d player %d" % [
			DictRead.as_int(case["call"]), DictRead.as_int(case["turn"]),
			DictRead.as_int(case["player"])]
		var built: Dictionary = MoveMapCaseRunner.build_lcl_world(entry)
		var state: MapState = built["state"]
		var units: Dictionary = built["units"]
		var types: UnitTypeTable = built["unit_types"]
		var turn: TurnState = TurnState.create()
		turn.turn = DictRead.as_int(case["turn"])
		turn.current_player = DictRead.as_int(case["player"])
		turn.ai_level = ai_level
		var control: GameControl = GameControl.create()
		var rng: IncRandom = IncRandom.new()
		rng.randomize_seed(1.0)
		var crand: CRandom = CRandom.create()
		var context: LclContext = LclContext.create(state, units, types, turn,
			control, rng, crand, DictRead.as_int(case["player"]),
			DictRead.as_string(entry["next_map"]))
		context.weapons = built["weapons"]
		context.ctrlmap = built["ctrlmap"]

		var env: PackedInt32Array = PackedInt32Array()
		env.resize(LclEnv.ENV_SLOTS)
		var env_doc: Dictionary = DictRead.as_dict(case["env"])
		for key: Variant in env_doc:
			env[DictRead.as_string(key).to_int()] = DictRead.as_int(
				env_doc[key])
		var got: LclOutcome = LclInterpreter.run(program, context, env)

		var want: Dictionary = DictRead.as_dict(case["outcome"])
		var mine: Array[int] = [
			1 if got.kind == DictRead.as_string(want["kind"]) else 0,
			got.line, got.steps, got.dispatched]
		var theirs: Array[int] = [1, DictRead.as_int(want["line"]),
			DictRead.as_int(want["steps"]),
			DictRead.as_int(want["dispatched"])]
		if mine != theirs:
			outcome_bad.append("%s: %s %s != %s"
				% [tag, got.kind, mine, theirs])
		# The **whole** event, name and arguments. Comparing only the names
		# left `platform`'s cell count, `set_ground_fire`'s hit count and
		# `para_bombs`' tile count unchecked on both sides.
		var mine_events: Array = DictRead.as_array(got.to_dict()["events"])
		var want_events: Array = DictRead.as_array(want["events"])
		if mine_events.size() != want_events.size():
			events_bad.append("%s: %d event(s) != %d" % [tag,
				mine_events.size(), want_events.size()])
		else:
			for i: int in range(mine_events.size()):
				var got_pair: Array = DictRead.as_array(mine_events[i])
				var want_pair: Array = DictRead.as_array(want_events[i])
				if DictRead.as_string(got_pair[0]) \
						!= DictRead.as_string(want_pair[0]):
					events_bad.append("%s: event %d is '%s' != '%s'" % [tag, i,
						got_pair[0], want_pair[0]])
				elif not _same_values(DictRead.as_array(got_pair[1]),
						DictRead.as_array(want_pair[1])):
					events_bad.append("%s: event %d '%s' %s != %s" % [tag, i,
						got_pair[0], got_pair[1], want_pair[1]])

		var control_want: PackedInt32Array = DictRead.to_int32(
			case["game_control"])
		if control.values() != control_want:
			control_bad.append("%s: %s != %s"
				% [tag, control.values(), control_want])
		if context.next_map != DictRead.as_string(case["next_map"]):
			control_bad.append("%s: next map '%s' != '%s'"
				% [tag, context.next_map, case["next_map"]])
		if turn.turn_control != DictRead.as_int(case["turn_control"]):
			control_bad.append("%s: turn control %d != %d"
				% [tag, turn.turn_control, case["turn_control"]])

		var delta: Array = DictRead.as_array(case["cell_delta"])
		if not delta.is_empty():
			reached["cells"] = true
		for write: Variant in delta:
			var triple: Array = DictRead.as_array(write)
			var index: int = DictRead.as_int(triple[1])
			var wanted: int = DictRead.as_int(triple[2])
			var mine_value: int = _cell(state,
				arrays[DictRead.as_int(triple[0])], index)
			if mine_value != wanted:
				cells_bad.append("%s: %s[%d] %d != %d" % [tag,
					arrays[DictRead.as_int(triple[0])], index, mine_value,
					wanted])

		var after: Array = DictRead.as_array(case["units_after"])
		if after.size() > DictRead.as_array(entry["units"]).size():
			reached["spawn"] = true
		if units.size() != after.size():
			units_bad.append("%s: %d unit(s) != %d"
				% [tag, units.size(), after.size()])
		else:
			for record2: Variant in after:
				var view: Dictionary = DictRead.as_dict(record2)
				var slot: int = DictRead.as_int(view["slot"])
				if not units.has(slot):
					units_bad.append("%s: slot %d missing" % [tag, slot])
					continue
				var unit: UnitState = units[slot]
				var difference: String = _unit_diff(unit, view)
				if difference != "":
					units_bad.append("%s: slot %d %s" % [tag, slot, difference])

		var rng_want: Dictionary = DictRead.as_dict(case["rng"])
		var crand_want: Dictionary = DictRead.as_dict(case["crand"])
		if rng.calls != 0 or crand.calls != 0:
			reached["rng"] = true
		if rng.calls != DictRead.as_int(rng_want["calls"]) \
				or absf(rng.seed - DictRead.as_float(rng_want["seed"])) > 0.5:
			rng_bad.append("%s: aRandom %d draw(s) seed %f != %d seed %f"
				% [tag, rng.calls, rng.seed, rng_want["calls"],
					rng_want["seed"]])
		if crand.calls != DictRead.as_int(crand_want["calls"]) \
				or crand.seed != DictRead.as_int(crand_want["seed"]):
			rng_bad.append("%s: rand() %d draw(s) seed %d != %d seed %d"
				% [tag, crand.calls, crand.seed, crand_want["calls"],
					crand_want["seed"]])

	h.check("%s.outcome" % name, outcome_bad.is_empty(),
		", ".join(outcome_bad.slice(0, REPORT_LIMIT)))
	h.check("%s.events" % name, events_bad.is_empty(),
		", ".join(events_bad.slice(0, REPORT_LIMIT)))
	h.check("%s.game_control" % name, control_bad.is_empty(),
		", ".join(control_bad.slice(0, REPORT_LIMIT)))
	h.check("%s.cells" % name, cells_bad.is_empty(),
		", ".join(cells_bad.slice(0, REPORT_LIMIT)))
	h.check("%s.units" % name, units_bad.is_empty(),
		", ".join(units_bad.slice(0, REPORT_LIMIT)))
	h.check("%s.generators" % name, rng_bad.is_empty(),
		", ".join(rng_bad.slice(0, REPORT_LIMIT)))
	return cases.size()


## Two event argument lists, compared through JSON's own numeric type.
##
## Every number the fixture holds arrived through `JSON.parse_string` and is a
## `float`; the interpreter's are `int`. Comparing the arrays directly would
## make `4` and `4.0` differ, which is the narrowing boundary [DictRead]
## describes, here at the one place a check crosses it.
static func _same_values(mine: Array, theirs: Array) -> bool:
	if mine.size() != theirs.size():
		return false
	for i: int in range(mine.size()):
		if typeof(theirs[i]) == TYPE_STRING or typeof(mine[i]) == TYPE_STRING:
			if DictRead.as_string(mine[i]) != DictRead.as_string(theirs[i]):
				return false
		elif DictRead.as_int(mine[i]) != DictRead.as_int(theirs[i]):
			return false
	return true


static func _cell(state: MapState, array: String, index: int) -> int:
	match array:
		"height": return state.height_at(index)
		"field_type": return state.field_type_at(index)
		"action_point": return state.action_point_at(index)
		"unit": return state.unit_at(index)
		_: return -1


## The columns a spawn writes, compared one by one so a failure names the field.
static func _unit_diff(unit: UnitState, want: Dictionary) -> String:
	if unit.player != DictRead.as_int(want["player"]):
		return "player %d != %d" % [unit.player, want["player"]]
	if unit.type_id != DictRead.as_int(want["type_id"]):
		return "type %d != %d" % [unit.type_id, want["type_id"]]
	if unit.x != DictRead.as_int(want["x"]) \
			or unit.y != DictRead.as_int(want["y"]):
		return "at (%d,%d) != (%d,%d)" % [unit.x, unit.y, want["x"],
			want["y"]]
	if unit.hp != DictRead.as_int(want["hit_points"]):
		return "hp %d != %d" % [unit.hp, want["hit_points"]]
	if unit.group != DictRead.as_int(want["group"]):
		return "group %d != %d" % [unit.group, want["group"]]
	if unit.ammo != DictRead.as_int(want["ammo"]):
		return "ammo %d != %d" % [unit.ammo, want["ammo"]]
	if unit.ep != DictRead.as_int(want["ep"]) \
			or unit.tp != DictRead.as_int(want["tp"]):
		return "ep/tp %d/%d != %d/%d" % [unit.ep, unit.tp, want["ep"],
			want["tp"]]
	if unit.pool_flag != DictRead.as_int(want["pool_flag"]):
		return "pool flag %d != %d" % [unit.pool_flag, want["pool_flag"]]
	if unit.speech != DictRead.as_int(want["speech"]):
		return "speech %d != %d" % [unit.speech, want["speech"]]
	if unit.name != DictRead.as_string(want["name"]):
		return "name '%s' != '%s'" % [unit.name, want["name"]]
	return ""



# --- hand-built programs -----------------------------------------------------
#
# The corpus cannot exercise what it happens not to contain, and the four
# missions in the cache contain less of it than the 153 do. Every check below
# was added because a mutation of [LclInterpreter] survived the replay: the
# locals' initial value, `SetVarVar`'s bug, `SetActPt`'s byte mask and
# `GetUnitsInArea`'s rectangle are each reached by exactly one shipped call
# site, and none of the four is in the four missions.

const SYNTHETIC_SLOT: int = 0
const SYNTHETIC_MARK: int = 7


static func _num(value: int) -> Dictionary:
	return {"kind": "number", "value": value}


static func _var(slot: int) -> Dictionary:
	return {"kind": "var", "slot_index": slot}


static func _name(value: String) -> Dictionary:
	return {"kind": "name", "value": value}


static func _instr(kind: String, name: String, args: Array,
		op: String = ">") -> Dictionary:
	return {"kind": kind, "name": name, "line": 1, "op": op, "args": args}


## A program that marks game-control slot 0 when its condition holds.
static func _program(body: Array, labels: Dictionary = {}) -> LclProgram:
	var instructions: Array = body.duplicate()
	instructions.append(_instr("end", "", []))
	return LclProgram.from_document({
		"schema": LclProgram.SCHEMA,
		"source": {"mission": "synthetic"},
		"header_line": 1,
		"instructions": instructions,
		"labels": labels,
	})


## Runs one hand-built program on a `w x h` world with the given units.
static func _run_synthetic(program: LclProgram, units: Array,
		width: int = 4, height: int = 4,
		cells: Dictionary = {}, ai_level: int = -1,
		objects: Array = [], seed: float = 0.0) -> Dictionary:
	var zeros: Array = []
	var links: Array = []
	# The idle value of the three object slots and the obstacle byte.
	var idle: Array = []
	for _i: int in range(width * height):
		zeros.append(0)
		links.append(-1)
		idle.append(255)
	# `cells` overrides single arrays -- a set piece that reads the field type
	# or the action point needs a map that carries one.
	var grid: Dictionary = {"height": zeros, "field_type": zeros,
		"action_point": zeros, "unit": links, "effect0": zeros,
		"effect1": idle, "effect2": idle, "effect3": idle,
		"effect4": zeros, "effect5": idle,
		"land": zeros, "start_index": links}
	for key: Variant in cells:
		grid[key] = cells[key]
	var res: MapResource = MapResource.from_document({
		"width": width, "height": height,
		"header": {"name": "synthetic", "next_map": "", "map_type": 0,
			"mission_id": 0, "world_set": "", "world_scene": "",
			"camera_height": 0, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0},
		"cells": grid,
		"special_objects": objects,
	})
	var state: MapState = MapState.from_resource(res)
	var roster: Dictionary = {}
	for entry: Variant in units:
		var record: Dictionary = DictRead.as_dict(entry)
		var unit: UnitState = UnitState.new()
		unit.slot = DictRead.as_int(record["slot"])
		unit.player = DictRead.as_int(record["player"])
		unit.type_id = DictRead.as_int(record.get("type_id", 0))
		unit.x = DictRead.as_int(record["x"])
		unit.y = DictRead.as_int(record["y"])
		unit.hp = 10
		unit.visibility = DictRead.as_int(record.get("visibility", 0))
		roster[unit.slot] = unit
		state.set_unit(state.index_of(unit.x, unit.y), unit.slot)
	var types: UnitTypeTable = UnitTypeTable.from_rows([
		{"id": 0, "mp_max": 4, "fp_max": 0, "hp_max": 10, "special": 0,
			"size": 0, "species": 0, "height": 18, "model": "",
			"armour_front": 255, "armour_rear": 255,
			"description": "soldier"},
		{"id": 1, "mp_max": 0, "fp_max": 255, "hp_max": 10, "special": 0,
			"size": 0, "species": 2, "height": 18, "model": "",
			"armour_front": 255, "armour_rear": 255,
			"description": "crate"},
	])
	var turn: TurnState = TurnState.create()
	turn.turn = 3
	if ai_level >= 0:
		turn.ai_level = ai_level
	var control: GameControl = GameControl.create()
	# An unseeded generator answers `base` every time -- the retail globals'
	# own zero -- so a rule that draws needs a seed to be seen drawing.
	var random: IncRandom = IncRandom.new()
	random.randomize_seed(seed)
	var context: LclContext = LclContext.create(state, roster, types, turn,
		control, random, CRandom.create(), 0, "")
	# The one thing `World` hands a context that `create` does not take:
	# the converter's footprints (docs/42 section 8.2).
	context.object_cells = res.object_cells()
	var outcome: LclOutcome = LclInterpreter.run(program, context,
		LclEnv.of(LclEnv.CALL_NEXT_TURN, turn.turn), 500)
	return {"outcome": outcome, "control": control, "state": state,
		"units": roster, "context": context}


## `SetGameControl (0, 7)`, the marker every synthetic program ends with.
static func _mark() -> Dictionary:
	return _instr("command", "SetGameControl",
		[_num(SYNTHETIC_SLOT), _num(SYNTHETIC_MARK)])


static func _marked(run: Dictionary) -> bool:
	var control: GameControl = run["control"]
	return control.get_slot(SYNTHETIC_SLOT) == SYNTHETIC_MARK


func _synthetic(h: TestHarness) -> void:
	# docs/20 section 4.2 -- the 28 locals are filled with **-1**, so a read
	# before the first write yields -1 and not 0.
	var unread: Dictionary = _run_synthetic(_program([
		_instr("cond", "VarCmpNum", [_var(0), _num(LclEnv.LOCAL_INITIAL)]),
		_mark(),
		_instr("close", "", []),
	]), [])
	h.check("synthetic.locals_start_at_minus_one", _marked(unread),
		"a local read before any write is -1")

	# docs/20 section 8.2 -- `SetVarVar` indexes the local array with the
	# second **numeric** argument, which is missing, so it reads `local[-1]`.
	var broken: Dictionary = _run_synthetic(_program([
		_instr("command", "SetVarNum", [_var(1), _num(9)]),
		_instr("command", "SetVarVar", [_var(0), _var(1)]),
		_instr("cond", "VarCmpNum", [_var(0), _num(LclEnv.LOCAL_INITIAL)]),
		_mark(),
		_instr("close", "", []),
	]), [])
	h.check("synthetic.setvarvar_is_broken_as_shipped", _marked(broken),
		"a corrected SetVarVar would leave 9 here, and this is not a "
		+ "correction")

	# docs/20 section 7.4 -- `SetActPt` writes a **byte**, so the two-argument
	# form stores `(byte)(-1)` = 255.
	var masked: Dictionary = _run_synthetic(_program([
		_instr("command", "SetActPt", [_num(1), _num(1)]),
		_instr("command", "GetActPt", [_var(0), _num(1), _num(1)]),
		_instr("cond", "VarCmpNum", [_var(0), _num(255)]),
		_mark(),
		_instr("close", "", []),
	]), [])
	h.check("synthetic.setactpt_short_form_writes_255", _marked(masked),
		"_C_120.lcl:66 is the one shipped site")

	# `0x00478000` -- an **inclusive** rectangle, and a player of -1 matches
	# any. Two units, one in the box and one out of it.
	var boxed: Dictionary = _run_synthetic(_program([
		_instr("command", "GetUnitsInArea",
			[_var(0), _num(0), _num(0), _num(0), _num(1), _num(1)]),
		_instr("cond", "VarCmpNum", [_var(0), _num(1)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 1, "y": 1},
		{"slot": 1, "player": 0, "x": 3, "y": 3}])
	h.check("synthetic.getunitsinarea_respects_the_rectangle", _marked(boxed),
		"one of the two units is outside (0,0)-(1,1)")

	# The flag mechanics of docs/20 section 2: `&` and `|` combine with the
	# flag the previous condition left, `close` resets it and `else` inverts.
	var conjunction: Dictionary = _run_synthetic(_program([
		_instr("cond", "VarCmpNum", [_var(0), _num(LclEnv.LOCAL_INITIAL)]),
		_instr("cond", "VarCmpNum", [_var(1), _num(99)], "&"),
		_mark(),
		_instr("close", "", []),
	]), [])
	h.check("synthetic.and_combines", not _marked(conjunction),
		"the second condition is false, so the command must not run")

	# docs/22 section 9.3 -- `Platform` relocates its riders through
	# `0x0047AD90`, and each looks around from its new cell before the cells
	# are copied: a rider carried into sight of a hidden alien reveals it, and
	# the vacated centre is left a deep hole. Measured by `turn_gold.py`'s
	# `platform` phase; here on an 8x8 map, east by three.
	var ride: Dictionary = _run_synthetic(_program([
		_instr("command", "Platform", [_num(1), _num(1), _num(3), _num(3)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 1, "y": 1},
		{"slot": 1, "player": UnitState.PLAYER_ALIEN, "x": 6, "y": 1,
			"visibility": Visibility.HIDDEN}], 8, 8)
	var riders: Dictionary = ride["units"]
	var rider: UnitState = riders[0]
	var spotted: UnitState = riders[1]
	var ridden: MapState = ride["state"]
	h.check("synthetic.platform_carries_the_rider", _marked(ride)
		and rider.x == 4 and rider.y == 1
		and ridden.unit_at(ridden.index_of(4, 1)) == 0
		and ridden.unit_at(ridden.index_of(1, 1)) == MapState.NO_UNIT,
		"(1,1) east by three is (4,1), in the map's unit index as well")
	h.equal("synthetic.platform_rider_looks_around", spotted.visibility,
		Visibility.FULL, "0x0047AF53, from the cell it arrived on")
	h.equal("synthetic.platform_leaves_a_deep_hole",
		ridden.field_type_at(ridden.index_of(1, 1)), Platform.CTRL_TYPE_DEEP_HOLE)

	# docs/20 section 7.4 steps 2 and 4, measured on `_C_105`: the record the
	# search finds beside the centre marker is carried `dist * 3200` in the
	# table (a far one is not); the cells' object, obstacle and countdown go
	# with the type and the source is cleared to 0 / 0xFF / 0; the height
	# stays on both cells.
	var cells_w: int = 8
	var raised: Array = []
	var slot1: Array = []
	var slot2: Array = []
	var slot0: Array = []
	for i: int in range(cells_w * cells_w):
		var in_block: bool = i % cells_w <= 2 and i / cells_w <= 2
		raised.append(1600 if in_block else 0)
		slot1.append(3 if i == cells_w + 1 else 255)
		slot2.append(MapState.OBSTACLE_FIRE if i == cells_w + 1 else 255)
		slot0.append(4 if i == cells_w + 1 else 0)
	var carried: Dictionary = _run_synthetic(_program([
		_instr("command", "Platform", [_num(1), _num(1), _num(3), _num(3)]),
		_mark(),
		_instr("close", "", []),
	]), [], cells_w, cells_w,
		{"height": raised, "effect1": slot1, "effect2": slot2,
			"effect0": slot0}, -1,
		[{"prototype": "L024EB00", "x": 3200, "y": 3200, "z": 1600},
			{"prototype": "L024EB00", "x": 6 * 3200, "y": 6 * 3200, "z": 0}])
	var carried_state: MapState = carried["state"]
	var table: Array[Dictionary] = carried_state.land_objects()
	h.equal("synthetic.platform_moves_the_found_record",
		[DictRead.as_int(table[0]["x"]), DictRead.as_int(table[0]["y"]),
			DictRead.as_int(table[0]["z"]), DictRead.as_int(table[1]["x"])],
		[4 * 3200, 3200, 1600, 6 * 3200], "`0x00412D00`: +0x10/+0x14 only")
	var src: int = carried_state.index_of(1, 1)
	var dst: int = carried_state.index_of(4, 1)
	h.equal("synthetic.platform_carries_the_cell_objects",
		[carried_state.effect_at(MapState.OBJECT_SLOT, dst),
			carried_state.obstacle_at(dst),
			carried_state.effect_at(MapState.TIMER_SLOT, dst),
			carried_state.effect_at(MapState.OBJECT_SLOT, src),
			carried_state.obstacle_at(src),
			carried_state.effect_at(MapState.TIMER_SLOT, src)],
		[3, MapState.OBSTACLE_FIRE, 4, 0, MapState.OBSTACLE_NONE, 0],
		"`0x00413049`..`0x00413070`")
	h.equal("synthetic.platform_leaves_the_heights",
		[carried_state.height_at(src), carried_state.height_at(dst)],
		[1600, 0], "`+0x01` is not in the copy loop")

	# A destination cell already occupied: the relocation is refused and the
	# rider's source cell keeps its link -- a cleared one would leave a unit
	# the map no longer knows about.
	var blocked: Dictionary = _run_synthetic(_program([
		_instr("command", "Platform", [_num(1), _num(1), _num(3), _num(3)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 1, "y": 1},
		{"slot": 1, "player": 0, "x": 4, "y": 1}], 8, 8)
	var stuck_units: Dictionary = blocked["units"]
	var stuck: UnitState = stuck_units[0]
	var stuck_state: MapState = blocked["state"]
	h.check("synthetic.platform_refused_rider_keeps_its_link",
		stuck.x == 1 and stuck.y == 1
		and stuck_state.unit_at(stuck_state.index_of(1, 1)) == 0
		and stuck_state.unit_at(stuck_state.index_of(4, 1)) == 1,
		"rider at (%d,%d), link %d" % [stuck.x, stuck.y,
			stuck_state.unit_at(stuck_state.index_of(1, 1))])
	var disjunction: Dictionary = _run_synthetic(_program([
		_instr("cond", "VarCmpNum", [_var(0), _num(99)]),
		_instr("cond", "VarCmpNum", [_var(1), _num(LclEnv.LOCAL_INITIAL)],
			"|"),
		_mark(),
		_instr("close", "", []),
	]), [])
	h.check("synthetic.or_combines", _marked(disjunction),
		"the second condition is true")
	var inverted: Dictionary = _run_synthetic(_program([
		_instr("cond", "VarCmpNum", [_var(0), _num(99)]),
		_instr("else", "", []),
		_mark(),
		_instr("close", "", []),
	]), [])
	h.check("synthetic.else_inverts", _marked(inverted),
		"a false condition followed by an else runs the command")
	var closed: Dictionary = _run_synthetic(_program([
		_instr("cond", "VarCmpNum", [_var(0), _num(99)]),
		_instr("close", "", []),
		_mark(),
	]), [])
	h.check("synthetic.close_resets_the_flag", _marked(closed),
		"a command after a close runs whatever the condition said")

	# `CheckCurrentTurn` is a **range on the turn number**, and the world above
	# is at turn 3.
	var in_range: Dictionary = _run_synthetic(_program([
		_instr("cond", "CheckCurrentTurn", [_num(2), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [])
	h.check("synthetic.check_current_turn_is_a_range", _marked(in_range),
		"2 <= 3 <= 4")
	var out_of_range: Dictionary = _run_synthetic(_program([
		_instr("cond", "CheckCurrentTurn", [_num(5), _num(9)]),
		_mark(),
		_instr("close", "", []),
	]), [])
	h.check("synthetic.check_current_turn_excludes", not _marked(out_of_range),
		"3 is not in 5..9")

	# `NoUnitOnField` takes a **cell**, and a crate on it makes it false --
	# it looks at no species, unlike `UnitOnField`.
	var empty_cell: Dictionary = _run_synthetic(_program([
		_instr("cond", "NoUnitOnField", [_num(3), _num(3)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 1, "y": 1}])
	h.check("synthetic.no_unit_on_field_is_a_cell_test",
		_marked(empty_cell), "(3,3) is empty and (1,1) is not")
	var crate_cell: Dictionary = _run_synthetic(_program([
		_instr("cond", "NoUnitOnField", [_num(1), _num(1)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "type_id": 1, "x": 1, "y": 1}])
	h.check("synthetic.a_crate_still_occupies_a_cell",
		not _marked(crate_cell),
		"species 2 is excluded by UnitOnField and not by this one")

	# docs/20 section 7.1 -- an unknown name and a missing label both abort,
	# and neither is silent.
	var unknown: LclOutcome = _run_synthetic(_program([
		_instr("command", "NoSuchCommand", []),
	]), [])["outcome"]
	h.equal("synthetic.an_unknown_command_aborts", unknown.kind,
		LclOutcome.ABORT, unknown.reason)
	var lost: LclOutcome = _run_synthetic(_program([
		_instr("command", "Goto", [_name("Nowhere")]),
	]), [])["outcome"]
	h.equal("synthetic.a_missing_label_aborts", lost.kind, LclOutcome.ABORT,
		lost.reason)
	var unknown_pred: LclOutcome = _run_synthetic(_program([
		_instr("cond", "NoSuchPredicate", [_var(0), _num(1)]),
	]), [])["outcome"]
	h.equal("synthetic.an_unknown_predicate_aborts", unknown_pred.kind,
		LclOutcome.ABORT, unknown_pred.reason)

	# A `Goto` loop is expressible, and the step cap is what stops it.
	var looping: LclOutcome = _run_synthetic(_program([
		_instr("label", "Top", []),
		_instr("command", "Goto", [_name("Top")]),
	], {"Top": 0}), [])["outcome"]
	h.equal("synthetic.a_goto_loop_hits_the_step_cap", looping.kind,
		LclOutcome.ABORT, looping.reason)
	h.check("synthetic.the_cap_is_reported_not_hidden",
		looping.reason.contains("Goto loop"), looping.reason)

	# The environment's own bounds. docs/20 section 4: `letter - 'A'` against
	# 0..26, so 65 -- what `ord("A")` asks for -- is not a slot. A version of
	# `MissionScript.to_slots` that dropped it silently would leave `_A` at 0,
	# match no `EnvVarCmpNum` arm, and let the hand-over proceed with the
	# mission never advancing.
	h.equal("synthetic.the_environment_bounds_are_zero_to_26",
		[LclEnv.is_slot(0), LclEnv.is_slot(LclEnv.ENV_SLOTS - 1),
			LclEnv.is_slot(LclEnv.ENV_SLOTS), LclEnv.is_slot(-1),
			LclEnv.is_slot("A".unicode_at(0))],
		[true, true, false, false, false])
	# And the seam's two halves are inverses on a real call type.
	var packed: PackedInt32Array = MissionScript.to_slots(
		MissionScript.env(LclEnv.CALL_MOVE_UNIT, 4, 0, 7, 9, 3, 17, 2))
	h.equal_ints("synthetic.the_seam_round_trips", packed,
		LclEnv.of(LclEnv.CALL_MOVE_UNIT, 4, 0, 7, 9, 3, 17, 2))

	# `GetUnits` with the player left off counts **nobody**. `_n` answers -1
	# for a missing operand, and routing that through the "any player"
	# sentinel counted the aliens and the props too.
	var counted: Dictionary = _run_synthetic(_program([
		_instr("command", "GetUnits", [_var(0)]),
		_instr("cond", "VarCmpNum", [_var(0), _num(0)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 1, "y": 1},
		{"slot": 1, "player": 255, "x": 2, "y": 2}])
	h.check("synthetic.getunits_without_a_player_counts_nobody",
		_marked(counted),
		"there is a player-0 unit and an alien on the map")
	var mine_only: Dictionary = _run_synthetic(_program([
		_instr("command", "GetUnits", [_var(0), _num(0)]),
		_instr("cond", "VarCmpNum", [_var(0), _num(1)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 1, "y": 1},
		{"slot": 1, "player": 255, "x": 2, "y": 2}])
	h.check("synthetic.getunits_with_a_player_counts_that_player",
		_marked(mine_only), "one of the two is player 0")

	# A spawn of a type `Info.lcl` never defines is **nameless**, not
	# `"type 99"`: the executable model answers "" and the two rosters would
	# otherwise differ on a field the replay compares.
	var nameless: Dictionary = _run_synthetic(_program([
		_instr("command", "InsertUnit", [_num(255), _num(99), _num(0),
			_num(0), _num(2), _num(2), _num(0)]),
	]), [])
	var spawned: Dictionary = nameless["units"]
	var found: String = "<none>"
	for key: Variant in spawned:
		var one: UnitState = spawned[key]
		if one.type_id == 99:
			found = one.name
	h.equal("synthetic.an_unknown_type_spawns_nameless", found, "",
		"UnitTypeTable.description answers 'type 99' and must not be used here")

	# docs/20 section 7.4 -- **the `rand()` call is unconditional whenever
	# `maxCount` is not zero.** All three difficulty arms at `0x0044194E`
	# reach `call [0x5255FC]` with no guard, so the arms whose only possible
	# answer is 0 -- `maxCount == 1`, and the short form's -1 -- still consume
	# one draw. The corpus cannot show this: `_C_116` holds all six short
	# sites and is not in the replayed fixture, and the desync it causes is
	# visible only from turn 9. So it is checked here, the same shape as
	# `lcl_runtime.py --check`'s `insert.draws_even_when_barren`.
	var barren: Array[String] = []
	for level: int in [0, 1, 2]:
		# Six numbers: the short form, whose missing `maxCount` reads as -1.
		var short_form: Dictionary = _run_synthetic(_program([
			_instr("command", "InsertUnit", [_num(255), _num(0), _num(0),
				_num(0), _num(2), _num(2)]),
		]), [], 4, 4, {}, level)
		var one_max: Dictionary = _run_synthetic(_program([
			_instr("command", "InsertUnit", [_num(255), _num(0), _num(0),
				_num(0), _num(2), _num(2), _num(1)]),
		]), [], 4, 4, {}, level)
		for probe: Dictionary in [short_form, one_max]:
			var ctx: LclContext = probe["context"]
			if ctx.crand.calls != 1:
				barren.append("level %d: %d draws" % [level, ctx.crand.calls])
	h.equal("synthetic.insert_draws_even_when_barren",
		", ".join(barren), "",
		"maxCount 1 and the short form's -1 each consume one rand()")
	var no_draw: Dictionary = _run_synthetic(_program([
		_instr("command", "InsertUnit", [_num(255), _num(0), _num(0),
			_num(0), _num(2), _num(2), _num(0)]),
	]), [], 4, 4, {}, 1)
	var no_draw_ctx: LclContext = no_draw["context"]
	h.equal("synthetic.insert_zero_max_count_draws_nothing",
		no_draw_ctx.crand.calls, 0,
		"maxCount 0 returns 1 before the divide is reached")

	_generate(h)
	_statues(h)
	_fixed_statues(h)
	_land_table(h)
	_growing_land(h)
	_falling_spores(h)
	_spores(h)
	_barrier(h)
	_foot_bridges(h)
	_free_slots(h)
	_crush_wall(h)
	_open_door(h)

	# A program with no `[END]` falls off the end, which is an outcome and not
	# an error (docs/20 section 2).
	var fell: LclOutcome = _fell_off()
	h.equal("synthetic.no_end_falls_off", fell.kind, LclOutcome.FELL_OFF,
		"the loop runs out of buffer; docs/20 section 2")



## Whether the unit in a [method _run_synthetic] roster is still alive.
static func _alive(run: Dictionary, slot: int) -> bool:
	var roster: Dictionary = run["units"]
	var unit: UnitState = roster[slot]
	return unit.is_alive()


## A special object for a synthetic map document: `model` at a world point.
static func _special(model: String, x: int, y: int, z: int) -> Dictionary:
	return {"prototype": model, "x": x, "y": y, "z": z}


## A synthetic map with nothing on it, `side` by `side`, and `extra` arrays.
static func _blank(side: int, extra: Dictionary = {}) -> Dictionary:
	var cells: Dictionary = {}
	for key: String in ["field_type", "action_point", "height"]:
		var zeros: Array = []
		for _i: int in range(side * side):
			zeros.append(0)
		cells[key] = zeros
	for key: Variant in extra:
		cells[key] = extra[key]
	return cells


## One command, then the marker, on a synthetic map.
static func _one(command: String, args: Array, units: Array, side: int,
		cells: Dictionary, objects: Array = [], seed: float = 0.0) -> Dictionary:
	return _run_synthetic(_program([
		_instr("command", command, args), _mark(),
		_instr("close", "", [])]), units, side, side, cells, -1, objects, seed)


## The seed the rules that draw are run with, and a generator in the same
## state to predict them.
const DRAW_SEED: float = 1.0


static func _seeded() -> IncRandom:
	var random: IncRandom = IncRandom.new()
	random.randomize_seed(DRAW_SEED)
	return random


## The special-object table `[0x004FA80C]` (docs/42 section 8.2): it starts
## as the `.lev`'s records, and `0x00406F20` answers the nearest strictly
## inside the box.
func _land_table(h: TestHarness) -> void:
	var run: Dictionary = _one("SetGameControl", [_num(1), _num(1)], [], 4,
		_blank(4), [_special("A.3DI", 6400, 6400, 0),
		_special("B.3DI", 6400 + 4999, 6400, 0),
		_special("C.3DI", 6400 - 10, 6400, 0),
		_special("D.3DI", 6400 + 10, 6400, 0)])
	var state: MapState = run["state"]
	h.equal("land_table.starts_as_the_lev", state.land_object_count(), 4)
	var box: Vector3i = Vector3i(5000, 5000, 9600)
	h.equal("land_table.finds_the_nearest",
		state.land_object(state.find_land_object(Vector3i(6400, 6400, 0), box))
			.get("model"), "A.3DI")
	h.equal("land_table.the_box_is_strict",
		state.land_object(state.find_land_object(
			Vector3i(6400 + 5000, 6400, 0), box)).get("model"), "B.3DI",
		"A stands exactly 5000 off and `|d| < half` refuses it")
	var gone: int = state.find_land_object(Vector3i(6400, 6400, 0), box)
	var deleted: bool = state.delete_land_object(gone)
	var tied: String = DictRead.as_string(state.land_object(
		state.find_land_object(Vector3i(6400, 6400, 0), box)).get("model", ""))
	h.equal("land_table.delete_keeps_the_order", [deleted, tied],
		[true, "C.3DI"], "C and D tie at 10; C is first in the table")


## `GrowingLand` `0x0046FF20`: one of four neighbours per try, drawn
## `ARandom(0, 4)`; a grown cell never grows in the same call; the object
## goes in at the old marker and the cell rises to 1600 as a tagged wall.
func _growing_land(h: TestHarness) -> void:
	var side: int = 5
	var cells: Dictionary = _blank(side)
	cells["action_point"][2 * side + 2] = 100
	cells["field_type"][2 * side + 2] = 2
	var run: Dictionary = _one("GrowingLand", [_num(100), _name("S.3DI")], [],
		side, cells, [], DRAW_SEED)
	var step: Vector2i = LclInterpreter.GROWTH_STEPS[_seeded().draw(0, 4)]
	var at: Vector2i = Vector2i(2, 2) + step
	var state: MapState = run["state"]
	var cell: int = state.index_of(at.x, at.y)
	h.equal("growing_land.the_first_draw_picks_the_neighbour",
		[state.field_type_at(cell), state.action_point_at(cell),
		state.height_at(cell)], [2, 100, LclInterpreter.GROWTH_HEIGHT],
		"a tagged wall at 1600, in the direction `ARandom(0, 4)` chose")
	h.equal("growing_land.one_growth_per_call", state.land_object_count(), 1,
		"the new cell carries the tag but the 0xFF mark keeps it from growing")
	h.equal("growing_land.the_event_carries_the_growth",
		_events_named(run, "growing_land"),
		[[100, "S.3DI", 1, at.x, at.y, 0, 0]])
	# A fire on the neighbour is freed, not grown around.
	var burning: Dictionary = _blank(side)
	burning["action_point"][2 * side + 2] = 100
	var obstacle: Array = []
	for _i: int in range(side * side):
		obstacle.append(MapState.OBSTACLE_FIRE)
	burning["effect2"] = obstacle
	var fired: Dictionary = _one("GrowingLand", [_num(100), _name("S.3DI")], [],
		side, burning, [], DRAW_SEED)
	var hot: MapState = fired["state"]
	h.equal("growing_land.a_fire_is_freed",
		hot.obstacle_at(hot.index_of(at.x, at.y)), MapState.OBSTACLE_NONE,
		"`+0x10 = 0xFF` at `0x00470023`")
	# The cap: more than 140 records refuses the whole call.
	var crowd: Array = []
	for i: int in range(MapState.LAND_OBJECTS_GROWTH_MAX + 1):
		crowd.append(_special("X.3DI", 0, 0, -100000 - i))
	var full: Dictionary = _one("GrowingLand", [_num(100), _name("S.3DI")], [],
		side, cells, crowd)
	var capped: MapState = full["state"]
	h.equal("growing_land.refused_above_140", capped.land_object_count(),
		MapState.LAND_OBJECTS_GROWTH_MAX + 1, "`cmp eax, 0x8C` / `jg`")
	crowd.pop_back()
	var room: Dictionary = _one("GrowingLand", [_num(100), _name("S.3DI")], [],
		side, cells, crowd)
	var roomy: MapState = room["state"]
	h.equal("growing_land.140_still_grows", roomy.land_object_count(),
		MapState.LAND_OBJECTS_GROWTH_MAX + 1)


## `FallingSpores` `0x00441F60`: the row is drawn **before** the column, the
## drop lands on the marker's old height and the cell becomes a tagged wall
## at `height << 4`; an occupied cell takes no drop.
func _falling_spores(h: TestHarness) -> void:
	var side: int = 6
	var run: Dictionary = _one("FallingSpores", [_num(1), _num(1), _num(4),
		_num(4), _num(1), _num(120), _name("L016EH00.3DI"), _num(40)], [], side,
		_blank(side), [], DRAW_SEED)
	var rng: IncRandom = _seeded()
	var ty: int = rng.draw(1, 4)
	var tx: int = rng.draw(1, 4)
	var state: MapState = run["state"]
	var cell: int = state.index_of(tx, ty)
	h.equal("falling_spores.y_before_x",
		[state.field_type_at(cell), state.action_point_at(cell),
		state.height_at(cell)], [2, 120, 40 << 4],
		"`0x00441F98` draws y, `0x00441FB9` x")
	h.equal("falling_spores.the_event_carries_the_drop",
		_events_named(run, "falling_spores"),
		[[1, 1, 4, 4, 1, 120, "L016EH00.3DI", 1, tx, ty, 0, 0]])
	var held: Dictionary = _one("FallingSpores", [_num(2), _num(2), _num(1),
		_num(1), _num(1), _num(120), _name("L016EH00.3DI"), _num(40)],
		[{"slot": 0, "player": 0, "x": 2, "y": 2}], side, _blank(side))
	var busy: MapState = held["state"]
	h.equal("falling_spores.an_occupied_cell_takes_none",
		[busy.land_object_count(), busy.field_type_at(busy.index_of(2, 2))],
		[0, 0], "`0x00479C60` wants `+0x07 == 0xFFFF`")


## `Spores` `0x0046FC30` -> `0x004147D0`: every tagged cell draws
## `ARandom(0, 15)` and only 0..2 hatch; a hatch needs a spore object in the
## box, frees it, clears the cell and puts the unit there.
func _spores(h: TestHarness) -> void:
	# Spores four fields apart, and a tagged cell with none of its own halfway
	# between -- 6400 from either, past the box's 5000 -- where the search
	# finds nothing.
	var side: int = 12
	var cells: Dictionary = _blank(side)
	var objects: Array = []
	var tagged: Array[Vector2i] = []
	var spored: Dictionary[Vector2i, bool] = {}
	for y: int in range(0, side, 4):
		for x: int in range(side):
			var cell: int = y * side + x
			var own: bool = x % 4 == 0
			if not own and x % 4 != 2:
				continue
			cells["action_point"][cell] = 120
			cells["field_type"][cell] = 2
			cells["height"][cell] = 3200
			tagged.append(Vector2i(x, y))
			if own:
				spored[Vector2i(x, y)] = true
				objects.append(_special("L016EH00.3DI", x * 3200, y * 3200, 3200))
	var run: Dictionary = _one("Spores", [_num(120), _num(120), _num(0)], [],
		side, cells, objects, DRAW_SEED)
	var rng: IncRandom = _seeded()
	var want: Array = []
	var bare: int = 0
	for at: Vector2i in tagged:
		if rng.draw(0, LclInterpreter.SPORE_ODDS) > LclInterpreter.SPORE_HATCH_MAX:
			continue
		if spored.has(at):
			want.append(at)
		else:
			bare += 1
	var state: MapState = run["state"]
	var got: Array = []
	for event: Array in _events_named(run, "spores"):
		got.append(Vector2i(DictRead.as_int(event[0]), DictRead.as_int(event[1])))
	h.equal("spores.three_in_fifteen_with_a_spore_hatch", got, want,
		"`cmp eax, 2` / `jg` after `ARandom(0, 15)`, and `0x00406F20` must find one")
	h.check("spores.some_hatched_some_did_not", not want.is_empty()
		and want.size() < objects.size(), "%d of %d" % [want.size(), objects.size()])
	h.check("spores.a_low_draw_with_no_spore_hatches_nothing", bare > 0,
		"%d bare cells drew 0..2 and are not in the hatch list" % bare)
	var cleared: bool = true
	for at: Vector2i in want:
		var cell: int = state.index_of(at.x, at.y)
		if state.action_point_at(cell) != 0 or state.height_at(cell) != 0 \
				or state.field_type_at(cell) != 1 \
				or state.unit_at(cell) == MapState.NO_UNIT:
			cleared = false
	h.check("spores.a_hatched_cell_is_free_floor_with_the_unit", cleared,
		"actpt 0, height 0, field type 1 and the new unit on it")
	h.equal("spores.each_hatch_frees_its_spore", state.land_object_count(),
		objects.size() - want.size())


## `FixedStatue` -- `aPlayStatueSequence` `0x00414000`: one arm of ten, and an
## event that carries the walk for the picture, found victim or not.
func _fixed_statues(h: TestHarness) -> void:
	var wide: int = 12
	var free: Array = []
	for _i: int in range(wide * wide):
		free.append(0)
	# Direction 0 is south (+y). The statue on (2, 0) reaches (2, 10); the
	# tenth cell is in reach.
	var tenth: Dictionary = _run_synthetic(_program([
		_instr("command", "FixedStatue", [_num(2), _num(0), _num(0)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 2, "y": 10}], wide, wide,
		{"field_type": free})
	h.equal("fixed_statue.the_tenth_cell_is_in_reach",
		_alive(tenth, 0), false, "`cmp eax, 0xa` at `0x00414164`")
	h.equal("fixed_statue.the_event_carries_the_walk_and_the_victim",
		_events_named(tenth, "fixed_statue"),
		[[2, 0, 0, 2, 10, 10, 0, 2, 10]],
		"x, y, dir, the endpoint, ten steps, the victim's slot and cell")
	h.equal("fixed_statue.the_kill_follows",
		_events_named(tenth, "fixed_statue_kill"), [[2, 10]])
	var eleventh: Dictionary = _run_synthetic(_program([
		_instr("command", "FixedStatue", [_num(2), _num(0), _num(0)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 2, "y": 11}], wide, wide,
		{"field_type": free})
	h.equal("fixed_statue.the_eleventh_is_not",
		_alive(eleventh, 0), true)
	# **The beam is drawn with nobody on it** (`0x00414266`): the event
	# is emitted, and no kill follows.
	h.equal("fixed_statue.an_empty_walk_still_shows",
		[_events_named(eleventh, "fixed_statue"),
		_events_named(eleventh, "fixed_statue_kill")],
		[[[2, 0, 0, 2, 10, 10, -1, -1, -1]], []])
	# A wall stops the walk on its own cell, uncounted, before the unit.
	var walled: Array = free.duplicate()
	walled[4 * wide + 2] = 2
	var blocked: Dictionary = _run_synthetic(_program([
		_instr("command", "FixedStatue", [_num(2), _num(0), _num(0)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 2, "y": 6}], wide, wide,
		{"field_type": walled})
	h.equal("fixed_statue.a_wall_stops_the_beam",
		[_alive(blocked, 0), _events_named(blocked, "fixed_statue")],
		[true, [[2, 0, 0, 2, 4, 3, -1, -1, -1]]],
		"`cmp byte [esi+0xd], 2` at `0x00414196`")


## `aGenerateUnitElement` (`0x00479CF0`) -- docs/20 section 7.4. The corpus
## replay compares the magazine and the cell; this pins the columns it does not
## carry, which are exactly the ones whose absence made `_C_168`'s aliens
## crawl one field a turn and never strike.
func _generate(h: TestHarness) -> void:
	var types: UnitTypeTable = UnitTypeTable.from_rows([
		{"id": 0, "mp_max": 3, "fp_max": 0, "hp_max": 5, "special": 0,
			"size": 0, "species": 0, "height": 18, "model": "",
			"description": "soldier"},
		{"id": UnitState.SPIDER_TYPE, "mp_max": 10, "fp_max": 255,
			"hp_max": 1, "special": 0, "size": 0, "species": 0, "height": 4,
			"model": "", "weapon": 17, "description": "Spider"},
		{"id": 62, "mp_max": 0, "fp_max": 255, "hp_max": 4, "special": 0,
			"size": 0, "species": 1, "height": 10, "model": "",
			"weapon": 7, "description": "unturnable"},
		{"id": 66, "mp_max": 4, "fp_max": 255, "hp_max": 12, "special": 16,
			"size": 0, "species": 1, "height": 10, "model": "",
			"armour_front": 2, "armour_rear": 2, "weapon": 7,
			"description": "Bea'Coo"},
	])
	var weapons: WeaponTable = WeaponTable.from_rows([
		{"id": 7, "mun": 5}, {"id": 17, "mun": 3}])
	var ctrlmap: CtrlMapTable = CtrlMapTable.from_rows([
		{"index": 0, "delay": 1, "name": "free"},
		{"index": 2, "delay": 255, "name": "wall"}])

	# A free cell, a soldier two fields south: the whole derived record.
	var world: Dictionary = _run_synthetic(_program([]),
		[{"slot": 0, "player": 0, "x": 2, "y": 4}], 5, 6)
	var state: MapState = world["state"]
	var units: Dictionary = world["units"]
	var speech: IncRandom = IncRandom.new()
	speech.randomize_seed(1.0)
	var made: UnitState = UnitState.generate(state, units, types, weapons,
		ctrlmap, UnitState.PLAYER_ALIEN, 66, "", 0, 0, 2, 2, false, 2, speech)
	h.equal("generate.the_types_default_weapon", made.weapon, 7,
		"unitinfo[+0x06] into +0x3F at 0x00479EC4")
	h.equal("generate.recomputes_the_whole_record",
		[made.hp, made.mp, made.fp, made.ammo, made.armour_front,
			made.armour_rear],
		[12, 4, Refresh.FP_NONE, 5, 2, 2],
		"0x004759E0 at 0x00479F20: an alien has no fitness, not an empty one")
	h.equal("generate.no_voice_for_player_255", [made.speech, speech.calls],
		[0, 0])
	h.equal("generate.faces_the_nearest_enemy", made.facing,
		Combat.direction(2, 2, 2, 4), "0x0047A8E0 mode 1, then 0x004792A0")

	# Mode 1 first: a hidden enemy one field away loses to a visible one three.
	world = _run_synthetic(_program([]),
		[{"slot": 0, "player": 0, "x": 3, "y": 2,
			"visibility": UnitState.VISIBILITY_HIDDEN},
		{"slot": 1, "player": 0, "x": 2, "y": 5}], 5, 6)
	made = _generate_on(world, types, weapons, ctrlmap, UnitState.PLAYER_ALIEN, 66,
		"", 0, 2, 2, speech)
	h.equal("generate.a_visible_enemy_before_a_nearer_hidden_one",
		made.facing, Combat.direction(2, 2, 2, 5))
	# Mode 2 when nobody is visible: the hidden one is still an enemy.
	world = _run_synthetic(_program([]),
		[{"slot": 0, "player": 0, "x": 3, "y": 2,
			"visibility": UnitState.VISIBILITY_HIDDEN}], 5, 6)
	made = _generate_on(world, types, weapons, ctrlmap, UnitState.PLAYER_ALIEN, 66,
		"", 0, 2, 2, speech)
	h.equal("generate.any_enemy_when_none_is_visible", made.facing,
		Combat.direction(2, 2, 3, 2))
	world = _run_synthetic(_program([]),
		[{"slot": 0, "player": 0, "x": 2, "y": 4}], 5, 6)
	made = _generate_on(world, types, weapons, ctrlmap, UnitState.PLAYER_ALIEN, 62,
		"", 0, 2, 2, speech)
	h.equal("generate.types_61_to_63_keep_facing_0", made.facing, 0,
		"0x00479330 refuses the turn")

	# Occupied: `0x004308C0`'s direction order, then its test `0x00479C60`.
	world = _run_synthetic(_program([]),
		[{"slot": 0, "player": 255, "x": 2, "y": 2}], 5, 5)
	made = _generate_on(world, types, weapons, ctrlmap, UnitState.PLAYER_ALIEN, 66,
		"", 0, 2, 2, speech)
	h.equal("generate.first_neighbour_is_direction_0", [made.x, made.y],
		[2, 3], "(0,+1) -- not the row-major (1,1)")
	var walled: Array = []
	for i: int in range(25):
		walled.append(2 if i == 3 * 5 + 2 else 0)
	world = _run_synthetic(_program([]),
		[{"slot": 0, "player": 255, "x": 2, "y": 2}], 5, 5,
		{"field_type": walled})
	made = _generate_on(world, types, weapons, ctrlmap, UnitState.PLAYER_ALIEN, 66,
		"", 0, 2, 2, speech)
	h.equal("generate.a_wall_is_not_a_landing", [made.x, made.y], [1, 2])
	world = _run_synthetic(_program([]),
		[{"slot": 0, "player": 255, "x": 2, "y": 2}], 5, 5)
	var fired: MapState = world["state"]
	fired.set_obstacle(fired.index_of(2, 3), MapState.OBSTACLE_FIRE)
	fired.set_obstacle(fired.index_of(1, 2), MapState.OBSTACLE_MINE)
	made = _generate_on(world, types, weapons, ctrlmap, UnitState.PLAYER_ALIEN, 66,
		"", 0, 2, 2, speech)
	h.equal("generate.fire_and_mines_are_not_landings", [made.x, made.y],
		[2, 1])

	# The voice: drawn for a human, fixed for the Spider.
	world = _run_synthetic(_program([]), [], 5, 5)
	made = _generate_on(world, types, weapons, ctrlmap, 0, 0,
		"", 2, 1, 1, speech)
	h.check("generate.a_human_draws_a_voice",
		made.speech >= 1 and made.speech <= 6 and speech.calls == 1,
		"speech %d, %d draw(s)" % [made.speech, speech.calls])
	h.equal("generate.a_humans_ceiling_counts_the_rank", made.hp, 7,
		"min(15, 5 + 24 / 12)")
	made = _generate_on(world, types, weapons, ctrlmap, 0, UnitState.SPIDER_TYPE,
		"Spidy", 0, 3, 3, speech)
	h.equal("generate.the_spider_speaks_spidy_without_a_draw",
		[made.speech, speech.calls], [UnitState.SPEECH_SPIDY, 1])


## `Statue` / `Statue2` -- `aPlayRotateStatueSequence` `0x00413A40`, the beam
## that kills. docs/42 section 8.1 as corrected by docs/97 section 41.


## [method UnitState.generate] on a [method _run_synthetic] world, typed.
static func _generate_on(world: Dictionary, types: UnitTypeTable,
		weapons: WeaponTable, ctrlmap: CtrlMapTable, player: int, type_id: int,
		name: String, rank: int, x: int, y: int,
		speech: IncRandom) -> UnitState:
	var map: MapState = world["state"]
	var units: Dictionary = world["units"]
	return UnitState.generate(map, units, types, weapons, ctrlmap, player,
		type_id, name, rank, 0, x, y, false, 2, speech)

func _statues(h: TestHarness) -> void:
	# A 9x9 world so the six-cell reach fits either side of the middle.
	var wide: int = 9
	var walls: Array = []
	for _i: int in range(wide * wide):
		walls.append(0)
	# The statue on (4, 4) with action point 0: the toggle makes it 1, so the
	# beam runs along **x**.
	var points: Array = walls.duplicate()
	points[4 * wide + 4] = 0
	var run: Dictionary = _run_synthetic(_program([
		_instr("command", "Statue", [_num(4), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 6, "y": 4},
		{"slot": 1, "player": 0, "x": 1, "y": 4},
		{"slot": 2, "player": 0, "x": 4, "y": 7},
	], wide, wide, {"field_type": walls, "action_point": points})
	var state: MapState = run["state"]
	h.equal("statue.toggles_the_action_point",
		state.action_point_at(state.index_of(4, 4)), 1,
		"`0x00413C31` flips bit 0 of the statue's own `+0x0B`")
	h.equal("statue.the_beam_kills_one_each_way",
		[_alive(run, 0), _alive(run, 1), _alive(run, 2)],
		[false, false, true],
		"the new bit picks x, so the unit off the axis is spared")
	h.equal("statue.the_victims_leave_the_map",
		[state.unit_at(state.index_of(6, 4)),
		state.unit_at(state.index_of(1, 4))],
		[MapState.NO_UNIT, MapState.NO_UNIT],
		"`aRemoveUnitElement` takes them off their cells")

	# The nearer of two on one arm is the only one taken: `0x00413D67`
	# re-enters the loop only on the no-unit branch.
	var near: Dictionary = _run_synthetic(_program([
		_instr("command", "Statue", [_num(4), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 5, "y": 4},
		{"slot": 1, "player": 0, "x": 7, "y": 4},
	], wide, wide, {"field_type": walls, "action_point": points})
	h.equal("statue.only_the_first_unit_on_an_arm_dies",
		[_alive(near, 0), _alive(near, 1)], [false, true],
		"one kill site per direction, not one per cell")

	# Field type 2 stops the walk before the unit behind it.
	var blocked: Array = walls.duplicate()
	blocked[4 * wide + 6] = 2
	var stopped: Dictionary = _run_synthetic(_program([
		_instr("command", "Statue", [_num(4), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 7, "y": 4},
	], wide, wide, {"field_type": blocked, "action_point": points})
	h.equal("statue.a_wall_stops_the_beam",
		_alive(stopped, 0), true,
		"`cmp byte [esi+0x0D], 2` at `0x00413CCA`")

	# The reach is six cells, so the sixth dies and the seventh does not.
	var sixth: Dictionary = _run_synthetic(_program([
		_instr("command", "Statue", [_num(7), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 1, "y": 4},
	], wide, wide, {"field_type": walls, "action_point": points})
	h.equal("statue.the_sixth_cell_is_in_reach",
		_alive(sixth, 0), false,
		"`cmp dword [esp+0x3c], 6` at `0x00413C97`")
	var seventh: Dictionary = _run_synthetic(_program([
		_instr("command", "Statue", [_num(8), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 1, "y": 4},
	], wide, wide, {"field_type": walls, "action_point": points})
	h.equal("statue.the_seventh_is_not",
		_alive(seventh, 0), true,
		"the counter exits at six before the step is taken")

	# An odd action point toggles **down**, which picks the other axis.
	var odd: Array = walls.duplicate()
	odd[4 * wide + 4] = 5
	var turned: Dictionary = _run_synthetic(_program([
		_instr("command", "Statue", [_num(4), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 6, "y": 4},
		{"slot": 1, "player": 0, "x": 4, "y": 6},
	], wide, wide, {"field_type": walls, "action_point": odd})
	var turned_state: MapState = turned["state"]
	h.equal("statue.an_odd_point_toggles_down",
		turned_state.action_point_at(turned_state.index_of(4, 4)), 4,
		"`0x00413C38` is `dec al`, so 5 becomes 4 and the axis is y")
	h.equal("statue.the_axis_follows_the_new_bit",
		[_alive(turned, 0), _alive(turned, 1)], [true, false],
		"an even byte after the toggle walks +y")

	# `Statue2` runs the same sequence on every cell in the ActPt range.
	var batch: Array = walls.duplicate()
	batch[1 * wide + 1] = 40
	batch[6 * wide + 6] = 41
	var swept: Dictionary = _run_synthetic(_program([
		_instr("command", "Statue2", [_num(40), _num(41)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 3, "y": 1},
		{"slot": 1, "player": 0, "x": 6, "y": 4},
	], wide, wide, {"field_type": walls, "action_point": batch})
	h.equal("statue2.runs_every_matched_cell",
		[_alive(swept, 0), _alive(swept, 1)], [false, false],
		"40 toggles to 41 and walks x; 41 toggles to 40 and walks y")


## `Barrier` -- `0x004423D0`'s toggle, and `aPlayLaserBarrier`'s victim
## list (docs/42 section 8): the beam walks from the emitter along `dir` to
## the first wall, kills everyone on it, and the event carries each victim as
## `slot, x, y` in beam order, because the routine flies to the middle one
## (`0x00413926`) and the picture cannot re-derive that from a map they have
## already left. The off arm carries nothing and runs no beam.
func _barrier(h: TestHarness) -> void:
	var wide: int = 9
	var walls: Array = []
	for _i: int in range(wide * wide):
		walls.append(0)
	# The wall at (7, 4) ends the beam of an emitter at (2, 4) firing +x
	# (direction 3); the unit behind it is out of reach.
	walls[4 * wide + 7] = 2
	var points: Array = walls.duplicate()
	var roster: Array = [
		{"slot": 0, "player": 0, "x": 3, "y": 4},
		{"slot": 1, "player": 0, "x": 5, "y": 4},
		{"slot": 2, "player": 0, "x": 6, "y": 4},
		{"slot": 3, "player": 0, "x": 8, "y": 4},
		{"slot": 4, "player": 0, "x": 4, "y": 5},
	]
	# Seeded with the on value: the first call switches it off.
	var off: Dictionary = _run_synthetic(_program([
		_instr("command", "Barrier", [_num(2), _num(4), _num(3), _num(90),
			_num(91), _num(90)]),
		_mark(),
		_instr("close", "", []),
	]), roster, wide, wide, {"field_type": walls, "action_point": points})
	var off_state: MapState = off["state"]
	h.equal("barrier.seeded_on_goes_off",
		[off_state.action_point_at(off_state.index_of(2, 4)),
		_events_named(off, "barrier_off"), _events_named(off, "barrier_on"),
		_alive(off, 0)],
		[91, [[2, 4]], [], true],
		"the seed equals `on`, so the toggle answers off and nobody dies")
	# Seeded with the off value: the first call fires the beam.
	var on: Dictionary = _run_synthetic(_program([
		_instr("command", "Barrier", [_num(2), _num(4), _num(3), _num(90),
			_num(91), _num(91)]),
		_mark(),
		_instr("close", "", []),
	]), roster, wide, wide, {"field_type": walls, "action_point": points})
	var on_state: MapState = on["state"]
	h.equal("barrier.the_beam_kills_to_the_wall",
		[_alive(on, 0), _alive(on, 1), _alive(on, 2), _alive(on, 3),
		_alive(on, 4)],
		[false, false, false, true, true],
		"three on the line die; behind the wall and off the line live")
	h.equal("barrier.the_event_carries_the_victims_in_beam_order",
		_events_named(on, "barrier_on"),
		[[2, 4, 3, 3, 0, 3, 4, 1, 5, 4, 2, 6, 4]],
		"x, y, dir, count, then slot, x, y each as the walk found them")
	h.equal("barrier.the_victims_leave_the_map",
		[on_state.unit_at(on_state.index_of(3, 4)),
		on_state.unit_at(on_state.index_of(5, 4)),
		on_state.action_point_at(on_state.index_of(2, 4))],
		[MapState.NO_UNIT, MapState.NO_UNIT, 90])
	# Nobody on the line: the count is zero and the list is empty.
	var clear: Dictionary = _run_synthetic(_program([
		_instr("command", "Barrier", [_num(2), _num(4), _num(3), _num(90),
			_num(91), _num(91)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 4, "y": 5}], wide, wide,
		{"field_type": walls, "action_point": points})
	h.equal("barrier.an_empty_beam_carries_a_zero",
		_events_named(clear, "barrier_on"), [[2, 4, 3, 0]])


## Every `name` event's values, in the order the run recorded them.
static func _events_named(run: Dictionary, name: String) -> Array:
	var outcome: LclOutcome = run["outcome"]
	var out: Array = []
	for entry: Variant in outcome.events:
		var event: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_string(event["name"]) == name:
			out.append(DictRead.as_array(event["values"]))
	return out


## The field types of `cells` on the run's map.
static func _types_at(run: Dictionary, cells: Array) -> Array:
	var state: MapState = run["state"]
	var out: Array = []
	for entry: Variant in cells:
		var cell: Vector2i = entry
		out.append(state.field_type_at(state.index_of(cell.x, cell.y)))
	return out


## `FootBridge` / `FootBridge2` -- `0x00414A70`, `0x00415110`.
##
## The twin of `lcl_runtime.py`'s `foot_bridge.*`: the `minUnits` gate, the
## nine cells becoming deep holes, the riders taken off the map **dead** and
## carried on the event; and for `FootBridge2` the exact-turn gate, the group
## byte cleared, the matched cells on the event before the riders (docs/42
## section 8.3).
func _foot_bridges(h: TestHarness) -> void:
	var wide: int = 9
	var zeros: Array = []
	for _i: int in range(wide * wide):
		zeros.append(0)
	var block: Array = []
	for y: int in [3, 4, 5]:
		for x: int in [3, 4, 5]:
			block.append(Vector2i(x, y))
	var nine_holes: Array = []
	var nine_floors: Array = []
	for _i: int in range(9):
		nine_holes.append(LclInterpreter.CTRL_TYPE_DEEP_HOLE)
		nine_floors.append(0)

	# One unit on the block and `minUnits` 1: the count is not **more than**
	# the argument, and nothing happens.
	var held: Dictionary = _run_synthetic(_program([
		_instr("command", "FootBridge", [_num(4), _num(4), _num(30), _num(1)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 4, "y": 4}], wide, wide,
		{"field_type": zeros})
	h.equal("foot_bridge.needs_more_than_min_units",
		[_types_at(held, block), _alive(held, 0),
			_events_named(held, "foot_bridge")],
		[nine_floors, true, []],
		"`0x00442650` compares the count with `jle`")

	# Two units: the nine cells become deep holes, both riders die and leave
	# their cells, and the event names them after the count.
	var fell: Dictionary = _run_synthetic(_program([
		_instr("command", "FootBridge", [_num(4), _num(4), _num(30), _num(1)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 4, "y": 4},
		{"slot": 1, "player": 0, "x": 5, "y": 5},
		{"slot": 2, "player": 0, "x": 7, "y": 7},
	], wide, wide, {"field_type": zeros})
	var fell_state: MapState = fell["state"]
	h.equal("foot_bridge.the_block_becomes_a_deep_hole",
		_types_at(fell, block), nine_holes,
		"`mov byte [esi+0x0D], 4` on all nine")
	h.equal("foot_bridge.the_riders_die",
		[_alive(fell, 0), _alive(fell, 1), _alive(fell, 2)],
		[false, false, true],
		"`0x00414F9C` is `aRemoveUnitElement`, and removal kills")
	h.equal("foot_bridge.the_riders_leave_the_map",
		[fell_state.unit_at(fell_state.index_of(4, 4)),
			fell_state.unit_at(fell_state.index_of(5, 5))],
		[MapState.NO_UNIT, MapState.NO_UNIT])
	# A fire on the block is freed before the cell becomes a hole
	# (`0x00414B96`..`0x00414BBF`): the object slot goes back to the pool and
	# the three bytes are cleared.
	var burning: Array = []
	var fire_obj: Array = []
	var countdown: Array = []
	for i: int in range(wide * wide):
		var on_fire: bool = i == 3 * wide + 3
		burning.append(MapState.OBSTACLE_FIRE if on_fire else 255)
		fire_obj.append(7 if on_fire else 255)
		countdown.append(2 if on_fire else 0)
	var doused: Dictionary = _run_synthetic(_program([
		_instr("command", "FootBridge", [_num(4), _num(4), _num(30), _num(1)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 4, "y": 4},
		{"slot": 1, "player": 0, "x": 5, "y": 5},
	], wide, wide, {"field_type": zeros, "effect2": burning,
		"effect1": fire_obj, "effect0": countdown})
	var doused_state: MapState = doused["state"]
	var fire_cell: int = doused_state.index_of(3, 3)
	h.equal("foot_bridge.frees_a_fire_on_the_block",
		[doused_state.object_state(7), doused_state.obstacle_at(fire_cell),
			doused_state.effect_at(MapState.OBJECT_SLOT, fire_cell),
			doused_state.effect_at(MapState.TIMER_SLOT, fire_cell),
			doused_state.field_type_at(fire_cell)],
		[MapState.NO_OBJECT, MapState.OBSTACLE_NONE, 0, 0,
			LclInterpreter.CTRL_TYPE_DEEP_HOLE],
		"`aDeleteSpecialObject`, then +0x0F = 0, +0x10 = 0xFF, +0x0E = 0")
	h.equal("foot_bridge.the_event_carries_the_riders",
		_events_named(fell, "foot_bridge"), [[4, 4, 30, 2, 0, 1]],
		"x, y, frames, standing, then the slots in block order")

	# `FootBridge2` on the wrong turn does nothing at all; the synthetic
	# runner plays turn 3.
	var group: Array = zeros.duplicate()
	group[2 * wide + 2] = 112
	group[2 * wide + 6] = 112
	group[6 * wide + 4] = 113
	var early: Dictionary = _run_synthetic(_program([
		_instr("command", "FootBridge2", [_num(112), _num(30), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 2, "y": 2}], wide, wide,
		{"field_type": zeros, "action_point": group})
	var early_state: MapState = early["state"]
	h.equal("foot_bridge2.needs_the_exact_turn",
		[early_state.action_point_at(early_state.index_of(2, 2)),
			_alive(early, 0), _events_named(early, "foot_bridge2")],
		[112, true, []],
		"`0x004426D0` compares `GetTurn`'s answer with `jne`")

	# On its turn: both matched cells become deep holes with the byte
	# cleared, the other group is untouched, the rider dies, and the event
	# carries the cells before the rider.
	var gone: Dictionary = _run_synthetic(_program([
		_instr("command", "FootBridge2", [_num(112), _num(30), _num(3)]),
		_mark(),
		_instr("close", "", []),
	]), [
		{"slot": 0, "player": 0, "x": 2, "y": 2},
		{"slot": 1, "player": 0, "x": 4, "y": 6},
	], wide, wide, {"field_type": zeros, "action_point": group})
	var gone_state: MapState = gone["state"]
	h.equal("foot_bridge2.clears_the_group",
		[_types_at(gone, [Vector2i(2, 2), Vector2i(6, 2), Vector2i(4, 6)]),
			[gone_state.action_point_at(gone_state.index_of(2, 2)),
				gone_state.action_point_at(gone_state.index_of(6, 2)),
				gone_state.action_point_at(gone_state.index_of(4, 6))]],
		[[LclInterpreter.CTRL_TYPE_DEEP_HOLE,
			LclInterpreter.CTRL_TYPE_DEEP_HOLE, 0], [0, 0, 113]],
		"`mov byte [esi+0x0B], 0` and `[esi+0x0D], 4` on the matches only")
	h.equal("foot_bridge2.the_riders_die", [_alive(gone, 0), _alive(gone, 1)],
		[false, true], "`0x00415663` is `aRemoveUnitElement` on every rider")
	h.equal("foot_bridge2.the_event_carries_the_cells",
		_events_named(gone, "foot_bridge2"), [[112, 30, 2, 2, 2, 6, 2, 0]],
		"actpt, frames, hit, the cells row-major, then the riders")


## `CrushWall` -- `0x00415C70` through `0x0042F410`, docs/42 section 8.2.
##
## The twin of `lcl_runtime.py`'s `crush_wall.*`: a wall cell becomes floor at
## ground level, and the event carries the cells that changed -- **all** of
## them, since the converter projects the wall piece's own geometry onto the
## control map (docs/42 section 8.2, docs/97 section 50). A map document with no
## special objects, which is every synthetic one, falls back to the command's
## own cell; the second half of this case gives it one and gets the run.
func _crush_wall(h: TestHarness) -> void:
	var walls: Array = []
	var heights: Array = []
	for _i: int in range(8 * 8):
		walls.append(0)
		heights.append(0)
	walls[4 * 8 + 3] = 2
	heights[4 * 8 + 3] = 3280
	var run: Dictionary = _run_synthetic(_program([
		_instr("command", "CrushWall", [_num(3), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [], 8, 8, {"field_type": walls, "height": heights})
	var state: MapState = run["state"]
	var at: int = state.index_of(3, 4)
	h.equal("crush_wall.becomes_free_place_at_ground",
		[state.field_type_at(at), state.height_at(at)], [1, 0],
		"`0x0042F410` writes the field type argument and a zero height")
	var outcome: LclOutcome = run["outcome"]
	var carried: Array = []
	for entry: Variant in outcome.events:
		var event: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_string(event["name"]) == "crush_wall":
			carried = DictRead.as_array(event["values"])
	h.equal("crush_wall.the_event_carries_the_cells", carried, [3, 4, 3, 4],
		"the command's cell, then every cell it changed")

	# The same command with an object standing on it: a three-cell run, the
	# shape `L041EA00` gives on the shipped maps. The command names the middle
	# cell to show that the run is found by the cell rather than by the
	# record's own position -- `0x00406F20` searches a box around the cell.
	var footprint: Array = [{"prototype": "L041EA00.3DI",
		"x": 3 * 3200, "y": 3 * 3200, "z": 3280,
		"cells": [3 * 8 + 2, 3 * 8 + 3, 3 * 8 + 4]}]
	var wide_walls: Array = []
	var wide_heights: Array = []
	for _i: int in range(8 * 8):
		wide_walls.append(0)
		wide_heights.append(0)
	for x: int in [2, 3, 4]:
		wide_walls[3 * 8 + x] = 2
		wide_heights[3 * 8 + x] = 3280
	var wide: Dictionary = _run_synthetic(_program([
		_instr("command", "CrushWall", [_num(3), _num(3)]),
		_mark(),
		_instr("close", "", []),
	]), [], 8, 8, {"field_type": wide_walls, "height": wide_heights}, -1,
		footprint)
	var wide_state: MapState = wide["state"]
	var crushed: Array = []
	for x: int in [1, 2, 3, 4, 5]:
		var cell: int = wide_state.index_of(x, 3)
		crushed.append([wide_state.field_type_at(cell),
			wide_state.height_at(cell)])
	h.equal("crush_wall.the_whole_footprint_becomes_floor", crushed,
		[[0, 0], [1, 0], [1, 0], [1, 0], [0, 0]],
		"the three cells of the run, and neither neighbour")
	h.equal("crush_wall.frees_the_object_it_found",
		wide_state.land_object_count(), 0,
		"`aDeleteLand` `0x00415E07` takes it out of the special-object table")
	var wide_outcome: LclOutcome = wide["outcome"]
	var wide_carried: Array = []
	for entry: Variant in wide_outcome.events:
		var event: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_string(event["name"]) == "crush_wall":
			wide_carried = DictRead.as_array(event["values"])
	h.equal("crush_wall.the_event_carries_the_footprint", wide_carried,
		[3, 3, 2, 3, 3, 3, 4, 3],
		"the command's cell, then the three the picture throws debris on")


## `OpenDoor` -- `0x004420C0` through `aDoorOpenSequence` `0x00410A20`.
##
## The twin of `lcl_runtime.py`'s `_c_open_door`: the command is a **toggle**
## on the low bit of the action point (docs/26 section 3.4), so a closed door
## at 31 opens -- `Free Place`, height 0, action point 30 -- and a second call
## shuts it again. A unit standing on the tile makes it do nothing at all.
##
## It recorded the animation event and wrote **no state** until 2026-09-09,
## which is what made `_C_116`'s three lever-worked doors impossible to open:
## the leaves swung and [method Scenery.apply_state], which paints them from
## the cell's parity, put them straight back.
func _open_door(h: TestHarness) -> void:
	var points: Array = []
	var heights: Array = []
	var types: Array = []
	for _i: int in range(8 * 8):
		points.append(0)
		heights.append(0)
		types.append(1)
	var at_index: int = 4 * 8 + 3
	points[at_index] = 31
	heights[at_index] = 3193
	types[at_index] = 2
	var cells: Dictionary = {"action_point": points, "height": heights,
		"field_type": types}
	var run: Dictionary = _run_synthetic(_program([
		_instr("command", "OpenDoor", [_num(3), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [], 8, 8, cells)
	var state: MapState = run["state"]
	var at: int = state.index_of(3, 4)
	h.equal("open_door.opens_a_closed_door",
		[state.action_point_at(at), state.field_type_at(at),
		state.height_at(at)], [30, 1, 0],
		"31 is closed: the toggle drops the cell to a `Free Place` at ground")
	var fired: bool = false
	var outcome: LclOutcome = run["outcome"]
	for entry: Variant in outcome.events:
		if DictRead.as_string(DictRead.as_dict(entry)["name"]) == "open_door":
			fired = true
	h.check("open_door.records_the_animation", fired,
		"the picture still gets its event")
	# The same command again, on the world it left: the door shuts.
	points[at_index] = 30
	heights[at_index] = 0
	types[at_index] = 1
	var again: Dictionary = _run_synthetic(_program([
		_instr("command", "OpenDoor", [_num(3), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [], 8, 8, {"action_point": points, "height": heights,
		"field_type": types})
	var shut: MapState = again["state"]
	h.equal("open_door.closes_an_open_one",
		[shut.action_point_at(at), shut.field_type_at(at),
		shut.height_at(at)], [31, 2, Interact.DOOR_HEIGHT_STEP],
		"30 is open: it rises one tile and becomes a `Wall`")
	# And a unit on the tile refuses the whole thing.
	points[at_index] = 31
	heights[at_index] = 3193
	types[at_index] = 2
	var blocked: Dictionary = _run_synthetic(_program([
		_instr("command", "OpenDoor", [_num(3), _num(4)]),
		_mark(),
		_instr("close", "", []),
	]), [{"slot": 0, "player": 0, "x": 3, "y": 4}], 8, 8,
		{"action_point": points, "height": heights, "field_type": types})
	var held: MapState = blocked["state"]
	h.equal("open_door.a_unit_on_the_tile_refuses",
		[held.action_point_at(at), held.field_type_at(at),
		held.height_at(at)], [31, 2, 3193],
		"`0x004420C0` returns before the sequence")


## A program with no `[END]`, run on the smallest world there is.
static func _fell_off() -> LclOutcome:
	var program: LclProgram = LclProgram.from_document({
		"schema": LclProgram.SCHEMA, "source": {}, "header_line": 1,
		"instructions": [_instr("command", "SetGameControl",
			[_num(0), _num(1)])],
		"labels": {},
	})
	return _run_synthetic(program, [])["outcome"]

## docs/42 section 2.4 -- the script's own camera commands, as flights on
## the queue (docs/97 section 34).
func _script_cameras(h: TestHarness) -> void:
	var host: RecordingCameraHost = RecordingCameraHost.new()
	var queue: SequenceQueue = SequenceQueue.create(null)
	var saved: Array[Array] = []
	h.check("script_camera.handles",
		ScriptCamera.handles("move_camera")
			and ScriptCamera.handles("rotating_camera")
			and not ScriptCamera.handles("open_door"),
		"six commands, and nothing else")
	# `MoveCamera (5, 21, 2, 21, 8)` -- the eye on the first tile at
	# `h * 1600`, the target on the second at z 0.
	var _c: int = ScriptCamera.enqueue(queue, host, "move_camera",
		PackedInt32Array([5, 21, 2, 21, 8]), saved)
	var frames: int = 0
	while queue.is_running() and frames < 400:
		var _still: bool = queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
		frames += 1
	h.equal("script_camera.move_camera", host.flights[0],
		[Vector3i(5 * WorldSpace.WORLD_UNITS_PER_FIELD,
			21 * WorldSpace.WORLD_UNITS_PER_FIELD,
			8 * ScriptCamera.MOVE_CAMERA_SCALE),
		Vector3i(2 * WorldSpace.WORLD_UNITS_PER_FIELD,
			21 * WorldSpace.WORLD_UNITS_PER_FIELD, 0)],
		"the object on (5, 21) at h * 1600, looking at (2, 21) at z 0")
	# `MoveTarget` keeps the eye; `MovePosition` keeps the target.
	host.eye = Vector3i(11, 22, 33)
	host.target = Vector3i(44, 55, 66)
	var target_queue: SequenceQueue = SequenceQueue.create(null)
	var _t: int = ScriptCamera.enqueue(target_queue, host, "move_target",
		PackedInt32Array([3, 4]), saved)
	while target_queue.is_running():
		var _s: bool = target_queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("script_camera.move_target_keeps_the_eye",
		host.flights[1][0], Vector3i(11, 22, 33))
	h.equal("script_camera.move_target_cell", host.flights[1][1],
		Vector3i(3 * WorldSpace.WORLD_UNITS_PER_FIELD,
			4 * WorldSpace.WORLD_UNITS_PER_FIELD, 0))
	host.eye = Vector3i(11, 22, 33)
	host.target = Vector3i(44, 55, 66)
	var position_queue: SequenceQueue = SequenceQueue.create(null)
	var _p: int = ScriptCamera.enqueue(position_queue, host, "move_position",
		PackedInt32Array([6, 7, 2]), saved)
	while position_queue.is_running():
		var _s: bool = position_queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("script_camera.move_position_keeps_the_target",
		host.flights[2][1], Vector3i(44, 55, 66))
	h.equal("script_camera.move_position_height",
		host.flights[2][0].z, 2 * ScriptCamera.MOVE_POSITION_SCALE,
		"`h * 3200`, not the MoveCamera scale")
	# Save and load round-trip through the caller's stack.
	host.eye = Vector3i(1, 2, 3)
	host.target = Vector3i(4, 5, 6)
	var save_queue: SequenceQueue = SequenceQueue.create(null)
	var _sv: int = ScriptCamera.enqueue(save_queue, host, "save_camera",
		PackedInt32Array(), saved)
	while save_queue.is_running():
		var _s: bool = save_queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("script_camera.save_pushes_six", saved.size(), 1)
	host.eye = Vector3i(9, 9, 9)
	var load_queue: SequenceQueue = SequenceQueue.create(null)
	var _ld: int = ScriptCamera.enqueue(load_queue, host, "load_camera",
		PackedInt32Array(), saved)
	while load_queue.is_running():
		var _s: bool = load_queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("script_camera.load_pops_them_back",
		host.flights[host.flights.size() - 1],
		[Vector3i(1, 2, 3), Vector3i(4, 5, 6)])
	h.equal("script_camera.stack_is_empty_again", saved.size(), 0)
	# **A skipped pair must not leak an entry.** `skip()` paints each remaining
	# step once at its last frame, so a `frame == 1` guard never fired for the
	# load: the push happened (a one-frame step) and the pop did not, and every
	# later `LoadCamera` in the mission restored an older view.
	host.eye = Vector3i(7, 7, 7)
	host.target = Vector3i(8, 8, 8)
	var skip_save: SequenceQueue = SequenceQueue.create(null)
	var _ss: int = ScriptCamera.enqueue(skip_save, host, "save_camera",
		PackedInt32Array(), saved)
	skip_save.skip()
	var skip_load: SequenceQueue = SequenceQueue.create(null)
	var _sl: int = ScriptCamera.enqueue(skip_load, host, "load_camera",
		PackedInt32Array(), saved)
	skip_load.skip()
	h.equal("script_camera.a_skipped_pair_leaks_nothing",
		[saved.size(), host.flights[host.flights.size() - 1]],
		[0, [Vector3i(7, 7, 7), Vector3i(8, 8, 8)]],
		"the pop is guarded by a once-flag, not by the frame number")
	# `RotatingCamera` is the orbit of docs/42 section 7.5 with `h * 160`.
	var orbit_queue: SequenceQueue = SequenceQueue.create(null)
	var orbit_frames: int = ScriptCamera.enqueue(orbit_queue, host,
		"rotating_camera", PackedInt32Array([16, 37, 80]), saved)
	h.equal("script_camera.rotating_is_the_orbit", orbit_frames,
		1 + OrbitSequence.FRAMES)


## A [ShotHost] that records flights and answers cells, for the commands
## above; no scene, no rig.
class RecordingCameraHost extends ShotHost:
	var eye: Vector3i = Vector3i.ZERO
	var target: Vector3i = Vector3i.ZERO
	var flights: Array[Array] = []

	func camera_eye() -> Vector3i:
		return eye

	func camera_target() -> Vector3i:
		return target

	func cell_object(x: int, y: int) -> Vector3i:
		return Vector3i(x * WorldSpace.WORLD_UNITS_PER_FIELD,
			y * WorldSpace.WORLD_UNITS_PER_FIELD, 0)

	func fly(to_eye: Vector3i, to_target: Vector3i) -> int:
		flights.append([to_eye, to_target])
		eye = to_eye
		target = to_target
		return 0


## `aInsertUnit` `0x00477830` with slot -1, as `turn_gold.py`'s `spawn` phase
## measured it on `_C_141` (docs/94 section 4): the lowest slot with zero hit
## points, a named record included; a refusal when that is slot 199; and a
## refusal (where the engine overruns) when every slot is taken.
func _free_slots(h: TestHarness) -> void:
	var cases: Array = [
		["empty", [], 0],
		["named_dead_record_is_free", [[0, 0], [1, 10]], 0],
		["lowest_gap", [[0, 10], [1, 10], [3, 10]], 2],
		["slot_198_is_taken", _live_below(198), 198],
		["slot_199_is_refused", _live_below(199), UnitState.NO_FREE_SLOT],
		["full_is_refused", _live_below(UnitState.UNIT_SLOTS),
			UnitState.NO_FREE_SLOT],
	]
	for entry: Variant in cases:
		var case: Array = entry
		var units: Dictionary = {}
		for pair: Variant in case[1]:
			var slot_hp: Array = pair
			var unit: UnitState = UnitState.new()
			unit.slot = slot_hp[0]
			unit.hp = slot_hp[1]
			units[unit.slot] = unit
		h.equal("free_slot.%s" % case[0], UnitState.free_slot(units), case[2])


static func _live_below(count: int) -> Array:
	var out: Array = []
	for slot: int in range(count):
		out.append([slot, 10])
	return out
