extends TestSuite

## Oracle boundary: **native runtime**. `0x004781C0` and `0x0043B320` called
## inside a running `Incubation.exe` on `_C_141`, re-expressed by
## `tools/turn_gold.py --emit-cases`.
##
## This is the third side of the diff. `test_turn.gd` checks `core/` against the
## rules; `tools/turn_gold.py --check` checks `inclib/turn.py` against the
## engine; this checks `core/` against the same engine bytes, so the two
## implementations are compared on identical inputs rather than on both having
## read the same prose.
##
## Every case carries its own balance rows. Reaching for `tables/balance.json`
## would mean the unit records came from the capture and the columns that
## interpret them came from somewhere else, and a converter change could move
## one without the other.

const DEV_CASES: String = "res://generated/turn/turn.json"
const USER_CASES: String = "user://turn/turn.json"
const SCHEMA: String = "incubation.turn-cases/1"


static func _path() -> String:
	if FileAccess.file_exists(DEV_CASES):
		return DEV_CASES
	return USER_CASES


func run(h: TestHarness) -> void:
	h.begin("turn_native", TestHarness.ORACLE_NATIVE)
	var path: String = _path()
	if not FileAccess.file_exists(path):
		h.check("fixture", false,
			"run tools/turn_gold.py --emit-cases tests/fixtures/turn/cases_turn.json")
		return
	var text: String = FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		h.check("fixture.parses", false, "not a JSON object")
		return
	var doc: Dictionary = parsed
	if DictRead.as_string(doc["schema"]) != SCHEMA:
		h.check("fixture.schema", false, DictRead.as_string(doc["schema"]))
		return

	var types: UnitTypeTable = UnitTypeTable.from_rows(
		DictRead.as_array(DictRead.as_dict(doc["types"])["units"]))
	var weapons: WeaponTable = WeaponTable.from_rows(
		DictRead.as_array(DictRead.as_dict(doc["types"])["weapons"]))
	var ai_level: int = DictRead.as_int(doc["ai_level"])

	_refresh_cases(h, doc, types, weapons, ai_level)
	_rotation_case(h, doc)
	_move_cases(h, doc)


## `aExecuteMove` inside the live engine, six probes over one path.
##
## The world is built once and reloaded per probe, the same way the capture
## reloads the save: a walk moves a unit and rewrites the cells it crossed, and
## writing the mutated bytes back does not undo that.
##
## The fill and the walk run on the **clean** map and the probe's bytes are
## written afterwards, which is the plan's own sequencing -- so all six follow
## the identical route and a disagreement names the arm that caused it.
func _move_cases(h: TestHarness, doc: Dictionary) -> void:
	var moves: Dictionary = DictRead.as_dict(doc["moves"])
	if moves.is_empty():
		h.check("move.captured", false,
			"the capture holds no aExecuteMove phase")
		return
	var probes: Array = DictRead.as_array(moves["probes"])
	h.check("move.probes", not probes.is_empty(),
		"%d probe(s) over one path" % probes.size())
	var slot: int = DictRead.as_int(moves["slot"])
	for entry: Variant in probes:
		var probe: Dictionary = DictRead.as_dict(entry)
		var tag: String = DictRead.as_string(probe["tag"])
		var built: Dictionary = MoveMapCaseRunner.build_world(moves)
		var state: MapState = built["state"]
		var ctrlmap: CtrlMapTable = built["ctrlmap"]
		var unit_types: UnitTypeTable = built["unit_types"]
		var units: Dictionary = built["units"]
		var mover: UnitState = units[slot]

		var fill: MoveMapResult = MoveMap.build(state, units, unit_types,
			ctrlmap, slot, false, mover.mp,
			Allowance.for_unit(mover, unit_types, units,
				DictRead.as_int(doc["ai_level"])))
		var walked: Dictionary = WalkMap.path(state, units, ctrlmap, fill,
			mover.x, mover.y, DictRead.as_int(moves["tx"]),
			DictRead.as_int(moves["ty"]))
		if not h.check("move.%s.walk" % tag,
				DictRead.as_bool(walked["ok"])
				and DictRead.as_int(walked["steps"])
					== DictRead.as_int(moves["steps"]),
				DictRead.as_string(walked["reason"])):
			continue
		for write: Variant in DictRead.as_array(probe["writes"]):
			_apply_write(state, DictRead.as_dict(write))

		var expected: Dictionary = DictRead.as_dict(probe["expected"])
		var tx: int = DictRead.as_int(moves["tx"])
		var ty: int = DictRead.as_int(moves["ty"])
		# The four the mine arm needs; no probe carries one, so the bomb
		# never fires and they only have to be well-formed.
		var probe_turn: TurnState = TurnState.create()
		var probe_rng: IncRandom = IncRandom.new()
		probe_rng.randomize_seed(1.0)
		var probe_weapons: WeaponTable = WeaponTable.from_rows(
			DictRead.as_array(DictRead.as_dict(doc["types"])["weapons"]))
		var moved: MoveResult = ExecuteMove.execute(state, units, unit_types,
			ctrlmap, probe_weapons, mover, walked, tx, ty,
			fill.mp_left_at(tx, ty),
			DictRead.as_int(doc["human_count"]),
			DictRead.as_int(DictRead.as_dict(doc["combat"])["game_mode"]),
			DictRead.as_int(doc["ai_level"]), probe_turn, probe_rng)
		h.equal("move.%s.returns" % tag, 1 if moved.ok else 0,
			DictRead.as_int(expected["returns"]))
		h.equal("move.%s.cost" % tag, moved.cost,
			DictRead.as_int(expected["cost"]))
		h.equal("move.%s.position" % tag, Vector2i(moved.x, moved.y),
			Vector2i(DictRead.as_int(expected["x"]),
				DictRead.as_int(expected["y"])))
		h.equal("move.%s.walked" % tag, moved.walked,
			DictRead.as_int(expected["walked"]))
		h.equal("move.%s.facing" % tag, moved.facing,
			DictRead.as_int(expected["facing"]))
		# The three visibility passes of `aExecuteMove` (docs/22 section 9.3)
		# are writing ones, and `+0x4F`, `+0x47` and `+0x48` of every live
		# record after the call are what they left. The probe's mover is the
		# player's, so the source pass and the mode-3 self-reveal are the two
		# arms this capture cannot reach.
		var fog_bad: PackedStringArray = PackedStringArray()
		for entry3: Variant in DictRead.as_array(expected["records_after"]):
			var record: Dictionary = DictRead.as_dict(entry3)
			var other_slot: int = DictRead.as_int(record["slot"])
			if not units.has(other_slot):
				fog_bad.append("slot %d missing" % other_slot)
				continue
			var other: UnitState = units[other_slot]
			for pair: Array in [["visibility", other.visibility],
					["order", other.order], ["order_param", other.order_param]]:
				var name: String = DictRead.as_string(pair[0])
				if DictRead.as_int(record[name]) != DictRead.as_int(pair[1]):
					fog_bad.append("slot %d %s %d != %d" % [other_slot, name,
						DictRead.as_int(pair[1]), DictRead.as_int(record[name])])
		h.check("move.%s.passes_write_what_the_engine_wrote" % tag,
			fog_bad.is_empty(), ", ".join(fog_bad))

		# **The probe calls the routine, not the engine's caller**, so what
		# `+0x15` holds afterwards is a statement about `aExecuteMove` alone:
		# unchanged everywhere except the mine, which zeroes it itself. The
		# caller's own `mp -= cost` is checked in `test_execute_move.gd`,
		# where there is a caller to check.
		h.equal("move.%s.the_routine_spends_nothing" % tag,
			DictRead.as_int(expected["mp_after"]),
			0 if moved.movement_zeroed
				else DictRead.as_int(expected["mp_before"]))

		# `JSON.parse_string` gives a float for every number, so the expected
		# pairs are narrowed here rather than compared as parsed -- the same
		# boundary rule the cache loader follows.
		var claimed: PackedInt32Array = PackedInt32Array()
		for write: Vector2i in moved.action_point_writes:
			claimed.append(write.x)
			claimed.append(write.y)
		var wanted: PackedInt32Array = PackedInt32Array()
		for entry2: Variant in DictRead.as_array(expected["action_points"]):
			var pair: Array = DictRead.as_array(entry2)
			wanted.append(DictRead.as_int(pair[0]))
			wanted.append(DictRead.as_int(pair[1]))
		h.equal_ints("move.%s.action_points" % tag, claimed, wanted)


func _apply_write(state: MapState, write: Dictionary) -> void:
	var index: int = state.index_of(DictRead.as_int(write["x"]),
		DictRead.as_int(write["y"]))
	var value: int = DictRead.as_int(write["value"])
	match DictRead.as_string(write["kind"]):
		"cell_field_type": state.set_field_type(index, value)
		"cell_action_point": state.set_action_point(index, value)
		"cell_obstacle": state.set_obstacle(index, value)


func _unit_from(view: Dictionary) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.slot = DictRead.as_int(view["slot"])
	unit.player = DictRead.as_int(view["player"])
	unit.type_id = DictRead.as_int(view["type_id"])
	unit.x = DictRead.as_int(view["x"])
	unit.y = DictRead.as_int(view["y"])
	unit.hp = DictRead.as_int(view["hp"])
	unit.mp = DictRead.as_int(view["mp"])
	unit.fp = DictRead.as_int(view["fp"])
	unit.ep = DictRead.as_int(view["ep"])
	unit.rested = DictRead.as_int(view["rested"])
	unit.action_state = DictRead.as_int(view["action_state"])
	unit.acted = DictRead.as_int(view["acted"])
	unit.ammo = DictRead.as_int(view["ammo"])
	unit.heat = DictRead.as_int(view["heat"])
	unit.weapon = DictRead.as_int(view["weapon"])
	unit.malfunction = DictRead.as_int(view["malfunction"])
	unit.walked = DictRead.as_int(view["walked"])
	unit.turn_start_x = DictRead.as_int(view["turn_start_x"])
	unit.turn_start_y = DictRead.as_int(view["turn_start_y"])
	unit.stimulant = DictRead.as_int(view["stimulant"])
	unit.ticket = DictRead.as_int(view["ticket"])
	unit.facing = DictRead.as_int(view["facing"])
	unit.visibility = DictRead.as_int(view["visibility"])
	return unit


## The fields the refresh writes. Compared one by one and named individually,
## so a failure says which rule broke rather than "the record differs".
const COMPARED: Array[String] = ["mp", "fp", "acted", "action_state", "rested",
	"walked", "turn_start_x", "turn_start_y", "stimulant", "ticket", "heat",
	"malfunction", "weapon"]


func _refresh_cases(h: TestHarness, doc: Dictionary, types: UnitTypeTable,
		weapons: WeaponTable, ai_level: int) -> void:
	var cases: Array = DictRead.as_array(doc["refreshes"])
	h.check("refresh.cases_present", not cases.is_empty(),
		"%d player refresh(es)" % cases.size())
	for entry: Variant in cases:
		var case: Dictionary = DictRead.as_dict(entry)
		var player: int = DictRead.as_int(case["player"])
		var units: Dictionary = {}
		for record: Variant in DictRead.as_array(case["before"]):
			var unit: UnitState = _unit_from(DictRead.as_dict(record))
			units[unit.slot] = unit
		var state: TurnState = TurnState.create()
		state.turn = DictRead.as_int(doc["turn"])
		state.current_player = player
		state.player_count = DictRead.as_int(doc["player_count"])
		state.ai_level = ai_level
		# The Banner test belongs to docs/22 and is not modelled in core/ yet;
		# no unit on this save carries one, so the capture cannot tell the two
		# apart and the constant is honest rather than convenient.
		var no_banner: Callable = func(_slot: int) -> bool: return false
		Refresh.player(state, player, units, types, weapons, no_banner)

		var mismatches: Array[String] = []
		var compared: int = 0
		for record: Variant in DictRead.as_array(case["after"]):
			var want: Dictionary = DictRead.as_dict(record)
			var slot: int = DictRead.as_int(want["slot"])
			var got: UnitState = units[slot]
			for field: String in COMPARED:
				compared += 1
				var mine: int = DictRead.as_int(got.get(field))
				var theirs: int = DictRead.as_int(want[field])
				if mine != theirs:
					mismatches.append("slot %d %s: %d != %d"
						% [slot, field, mine, theirs])
		h.check("refresh.p%d.compared" % player, compared > 0,
			"%d field comparison(s)" % compared)
		h.check("refresh.p%d.matches_native" % player, mismatches.is_empty(),
			", ".join(mismatches.slice(0, 6)))


func _rotation_case(h: TestHarness, doc: Dictionary) -> void:
	var rot: Dictionary = DictRead.as_dict(doc["rotation"])
	var current: Array = DictRead.as_array(rot["current"])
	var previous: Array = DictRead.as_array(rot["previous"])
	var any_left: Array = DictRead.as_array(rot["any_left"])
	var advance: Array = DictRead.as_array(rot["advance"])
	h.check("rotation.steps_present", not advance.is_empty(),
		"%d step(s)" % advance.size())
	if advance.is_empty():
		return

	var state: TurnState = TurnState.create()
	state.turn = DictRead.as_int(doc["turn"])
	state.current_player = DictRead.as_int(current[0])
	state.previous_player = DictRead.as_int(previous[0])
	state.player_count = DictRead.as_int(doc["player_count"])
	state.solo_flag = DictRead.as_int(doc["solo_flag"]) != 0
	state.player_kind = _ints(DictRead.as_array(doc["player_kind"]))
	state.end_state = _ints(DictRead.as_array(doc["end_state"]))
	# Every live slot of the capture belongs to a player that still has units,
	# so the count the skip rule consults is non-zero for all of them.
	var live: Callable = func(_slot: int) -> int: return 1

	var bad: Array[String] = []
	for i: int in range(advance.size()):
		if state.current_player != DictRead.as_int(current[i]):
			bad.append("step %d current: %d != %d"
				% [i, state.current_player, DictRead.as_int(current[i])])
		if state.previous_player != DictRead.as_int(previous[i]):
			bad.append("step %d previous: %d != %d"
				% [i, state.previous_player, DictRead.as_int(previous[i])])
		var left: bool = Rotation.any_player_left_this_turn(state, live)
		if int(left) != DictRead.as_int(any_left[i]):
			bad.append("step %d any_left: %d != %d"
				% [i, int(left), DictRead.as_int(any_left[i])])
		var ok: bool = Rotation.advance_player(state, live)
		if int(ok) != DictRead.as_int(advance[i]):
			bad.append("step %d advance: %d != %d"
				% [i, int(ok), DictRead.as_int(advance[i])])
	h.check("rotation.matches_native", bad.is_empty(),
		", ".join(bad.slice(0, 6)))
	# A rotation that never moved would agree with a model that never moved.
	var visited: Dictionary = {}
	for value: Variant in current:
		visited[DictRead.as_int(value)] = true
	h.check("rotation.is_not_stationary", visited.size() > 1,
		"visits %s" % str(visited.keys()))


func _ints(values: Array) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(values.size())
	for i: int in range(values.size()):
		out[i] = DictRead.as_int(values[i])
	return out
