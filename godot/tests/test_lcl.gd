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
const SCHEMA: String = "incubation.lcl-cases/1"
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
		width: int = 4, height: int = 4) -> Dictionary:
	var zeros: Array = []
	var links: Array = []
	for _i: int in range(width * height):
		zeros.append(0)
		links.append(-1)
	var res: MapResource = MapResource.from_document({
		"width": width, "height": height,
		"header": {"name": "synthetic", "next_map": "", "map_type": 0,
			"mission_id": 0, "world_set": "", "world_scene": "",
			"camera_height": 0, "equip_points": [0, 0, 0, 0],
			"skill_level": 0, "tech_level": 0},
		"cells": {"height": zeros, "field_type": zeros,
			"action_point": zeros, "unit": links, "effect0": zeros,
			"effect1": zeros, "effect2": zeros, "effect3": zeros,
			"land": zeros, "start_index": links, "decal0": zeros,
			"decal1": zeros},
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
	var control: GameControl = GameControl.create()
	var context: LclContext = LclContext.create(state, roster, types, turn,
		control, IncRandom.new(), CRandom.create(), 0, "")
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

	# A program with no `[END]` falls off the end, which is an outcome and not
	# an error (docs/20 section 2).
	var fell: LclOutcome = _fell_off()
	h.equal("synthetic.no_end_falls_off", fell.kind, LclOutcome.FELL_OFF,
		"the loop runs out of buffer; docs/20 section 2")


## A program with no `[END]`, run on the smallest world there is.
static func _fell_off() -> LclOutcome:
	var program: LclProgram = LclProgram.from_document({
		"schema": LclProgram.SCHEMA, "source": {}, "header_line": 1,
		"instructions": [_instr("command", "SetGameControl",
			[_num(0), _num(1)])],
		"labels": {},
	})
	return _run_synthetic(program, [])["outcome"]
