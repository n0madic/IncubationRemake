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
