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
		if got.events.size() != DictRead.as_array(want["events"]).size():
			events_bad.append("%s: %d event(s) != %d" % [tag,
				got.events.size(),
				DictRead.as_array(want["events"]).size()])
		else:
			for i: int in range(got.events.size()):
				var pair: Array = DictRead.as_array(
					DictRead.as_array(want["events"])[i])
				if DictRead.as_string(got.events[i]["name"]) \
						!= DictRead.as_string(pair[0]):
					events_bad.append("%s: event %d is '%s' != '%s'" % [tag, i,
						got.events[i]["name"], pair[0]])

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
