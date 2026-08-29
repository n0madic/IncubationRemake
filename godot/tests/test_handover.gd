extends TestSuite

## Oracle boundary: **executable Python**.  `tools/turn_runtime.py
## --emit-handover-cases` traces `inclib/turn.py`'s `hand_over` on `_C_140`
## with the real LCL interpreter driving the mission script, and this replays
## the trace against `core/`.
##
## The composition of `0x0047D600` is **code-read, not natively run**: it ends
## by invoking `aAISystemControl`, the computer's whole turn, which is not
## something to start inside a debugger probe.  So there is no native oracle
## for the sequence, and the strongest check available is the two
## implementations agreeing on identical documents.
##
## `core/` has no interpreter yet, so the two cannot be given the same
## *program*.  They are given the same **transcript**: every step records what
## the script was asked, in order, what it answered and what it left in the
## game-control slots, and the runner installed here replays exactly that.
## What is compared is the hand-over's own behaviour -- when each event fires,
## what environment it carries, whether a refusal stops the sequence, and every
## unit field the refresh touched.

const DEV_CASES: String = "res://generated/turn/handover.json"
const USER_CASES: String = "user://turn/handover.json"
const SCHEMA: String = "incubation.handover-cases/1"

## The fields the trace carries per unit, which are the fields the hand-over
## reads or writes.  Compared as a set rather than one at a time so a refresh
## that stopped writing one of them cannot hide behind the others.
const UNIT_FIELDS: Array[String] = ["x", "y", "hp", "mp", "fp", "acted",
	"action_state", "rested", "walked", "turn_start_x", "turn_start_y",
	"stimulant", "ticket", "heat", "malfunction", "weapon"]

var _script_calls: Array = []
var _script_index: int = 0
var _control: GameControl = null
var _harness: TestHarness = null
var _step: int = 0


static func _path() -> String:
	if FileAccess.file_exists(DEV_CASES):
		return DEV_CASES
	return USER_CASES


func run(h: TestHarness) -> void:
	h.begin("handover", TestHarness.ORACLE_PYTHON)
	_harness = h
	var path: String = _path()
	if not FileAccess.file_exists(path):
		h.check("fixture", false,
			"run tools/turn_runtime.py --check gog_incubation "
			+ "--emit-handover-cases tests/fixtures/turn/cases_handover.json")
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

	var types: UnitTypeTable = UnitTypeTable.from_rows(
		DictRead.as_array(DictRead.as_dict(doc["types"])["units"]))
	var weapons: WeaponTable = WeaponTable.from_rows(
		DictRead.as_array(DictRead.as_dict(doc["types"])["weapons"]))
	var state: TurnState = _state_from(DictRead.as_dict(doc["state"]))
	var units: Dictionary = {}
	for entry: Variant in DictRead.as_array(doc["units"]):
		var unit: UnitState = _unit_from(DictRead.as_dict(entry))
		units[unit.slot] = unit
	_control = GameControl.create()

	var live_units: Callable = func(player: int) -> int:
		var n: int = 0
		for slot: Variant in units:
			var u: UnitState = units[slot]
			if u.player == player and u.hp > 0:
				n += 1
		return n
	var banner_of: Callable = func(slot: int) -> bool:
		var u: UnitState = units[slot]
		return Allowance.banner_in_range(u, units)

	var steps: Array = DictRead.as_array(doc["steps"])
	h.check("handover.steps", not steps.is_empty(),
		"%d step(s) traced on %s" % [steps.size(),
			DictRead.as_string(doc["mission"])])
	for i: int in range(steps.size()):
		var step: Dictionary = DictRead.as_dict(steps[i])
		_step = i
		_force(step, state)
		_place(step, units)
		_script_calls = DictRead.as_array(step["calls"])
		_script_index = 0
		var result: TurnResult = TurnSequence.hand_over(state, units, _control,
			types, weapons, _runner, banner_of, live_units,
			DictRead.as_int(step["arg"]))
		h.equal("handover.%d.script_calls_all_consumed" % i, _script_index,
			_script_calls.size())
		_compare(step, result, state, units)


## The recorded transcript, replayed.  Asserting the call type and the whole
## environment here rather than only counting the calls is the point: the two
## events differ **only** in their environment, and a hand-over that fired
## NEXT TURN where NEXT PLAYER belongs would otherwise pass.
func _runner(call_type: int, environment: Dictionary) -> Dictionary:
	if _script_index >= _script_calls.size():
		_harness.check("handover.%d.script_call_%d_was_expected"
			% [_step, _script_index], false,
			"the sequence ran a script the trace does not have")
		return {"ok": true, "ran": false}
	var expected: Dictionary = DictRead.as_dict(
		_script_calls[_script_index])
	_script_index += 1
	_harness.equal("handover.%d.call_%d.type" % [_step, _script_index - 1],
		call_type, DictRead.as_int(expected["call_type"]))
	var wanted: Dictionary = DictRead.as_dict(expected["env"])
	var got: Dictionary = {}
	for key: Variant in environment:
		got[str(DictRead.as_int(key))] = DictRead.as_int(environment[key])
	var want: Dictionary = {}
	for key: Variant in wanted:
		want[DictRead.as_string(key)] = DictRead.as_int(wanted[key])
	_harness.equal("handover.%d.call_%d.env" % [_step, _script_index - 1],
		got, want)
	# What the script left behind, applied rather than re-derived: the
	# mission-end test reads these, and a runner that dropped them could never
	# reach the win the trace ends on.
	#
	# **Written into the object, not over the handle.** The sequence was handed
	# this [GameControl] before the runner was ever called, so rebinding the
	# member here changes nothing it can see -- which is exactly what happened,
	# and the win step reported no win at all.
	var slots: PackedInt32Array = DictRead.to_int32(expected["game_control"])
	for slot: int in range(slots.size()):
		_control.set_slot(slot, slots[slot])
	return {"ok": DictRead.as_bool(expected["ok"]), "ran": true}


## What the trace forced between steps, applied here rather than assumed.
##
## The emitter reaches a state the sequence would take many turns to produce --
## a refusal at NEXT TURN needs the computer to be the current player -- and
## records the reach. Leaving it out made the replay ask a different question
## than the emitter did, and it surfaced as the wrong script event firing.
func _force(step: Dictionary, state: TurnState) -> void:
	var forced: Dictionary = DictRead.as_dict(step["force"])
	for key: Variant in forced:
		var name: String = DictRead.as_string(key)
		if name == "game_control":
			var slots: PackedInt32Array = DictRead.to_int32(forced[key])
			for slot: int in range(slots.size()):
				_control.set_slot(slot, slots[slot])
		else:
			state.set(name, DictRead.as_int(forced[key]))


func _place(step: Dictionary, units: Dictionary) -> void:
	for entry: Variant in DictRead.as_array(step["place"]):
		var move: Array = DictRead.as_array(entry)
		var unit: UnitState = units[DictRead.as_int(move[0])]
		unit.x = DictRead.as_int(move[1])
		unit.y = DictRead.as_int(move[2])


func _compare(step: Dictionary, result: TurnResult, state: TurnState,
		units: Dictionary) -> void:
	var expected: Dictionary = DictRead.as_dict(step["expected"])
	var i: int = _step
	_harness.equal("handover.%d.code" % i, result.code,
		DictRead.as_int(expected["code"]))
	_harness.equal("handover.%d.turn" % i, result.turn,
		DictRead.as_int(expected["turn"]))
	_harness.equal("handover.%d.player" % i, result.player,
		DictRead.as_int(expected["player"]))
	_harness.equal("handover.%d.previous_player" % i, result.previous_player,
		DictRead.as_int(expected["previous_player"]))
	_harness.equal("handover.%d.mission_ended" % i, result.mission_ended,
		DictRead.as_bool(expected["mission_ended"]))
	_harness.equal("handover.%d.ai_turn" % i, result.ai_turn,
		DictRead.as_bool(expected["ai_turn"]))
	_harness.equal_ints("handover.%d.refreshed" % i, result.refreshed,
		DictRead.to_int32(expected["refreshed"]))

	var after: Dictionary = DictRead.as_dict(step["state_after"])
	_harness.equal("handover.%d.state.turn" % i, state.turn,
		DictRead.as_int(after["turn"]))
	_harness.equal("handover.%d.state.current_player" % i,
		state.current_player, DictRead.as_int(after["current_player"]))
	_harness.equal_ints("handover.%d.state.reaction_counter" % i,
		state.reaction_counter, DictRead.to_int32(after["reaction_counter"]))

	# The premise the replay rests on, checked rather than assumed: the engine
	# has one unit array, and this trace was taken from a harness that has two
	# (`tools/turn_runtime.py`'s `_check_one_unit_array` says why, and stops
	# the emitter where they part company). If a step ever carried a different
	# slot list, the comparison below would be against a set the mission had
	# already changed.
	var slots: PackedInt32Array = PackedInt32Array()
	var keys: Array = units.keys()
	keys.sort()
	for key: Variant in keys:
		slots.append(DictRead.as_int(key))
	_harness.equal_ints("handover.%d.slots" % i, slots,
		DictRead.to_int32(step["slots"]))

	# Every unit field the trace carries, for every unit -- not the refreshed
	# ones alone. A refresh that touched a slot it should have left standing is
	# the failure this shape catches and a per-slot spot check does not.
	var mismatched: PackedStringArray = PackedStringArray()
	for entry: Variant in DictRead.as_array(step["units_after"]):
		var view: Dictionary = DictRead.as_dict(entry)
		var unit: UnitState = units[DictRead.as_int(view["slot"])]
		for name: String in UNIT_FIELDS:
			var got: int = DictRead.as_int(unit.get(name))
			var want: int = DictRead.as_int(view[name])
			if got != want:
				mismatched.append("slot %d %s %d != %d"
					% [unit.slot, name, got, want])
	_harness.check("handover.%d.units" % i, mismatched.is_empty(),
		", ".join(mismatched))


func _state_from(view: Dictionary) -> TurnState:
	var state: TurnState = TurnState.create()
	state.turn = DictRead.as_int(view["turn"])
	state.current_player = DictRead.as_int(view["current_player"])
	state.previous_player = DictRead.as_int(view["previous_player"])
	state.player_count = DictRead.as_int(view["player_count"])
	state.player_kind = DictRead.to_int32(view["player_kind"])
	state.end_state = DictRead.to_int32(view["end_state"])
	state.solo_flag = DictRead.as_bool(view["solo_flag"])
	state.ai_level = DictRead.as_int(view["ai_level"])
	state.mode = DictRead.as_int(view["mode"])
	state.reaction_counter = DictRead.to_int32(view["reaction_counter"])
	return state


func _unit_from(view: Dictionary) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.slot = DictRead.as_int(view["slot"])
	unit.type_id = DictRead.as_int(view["type_id"])
	unit.player = DictRead.as_int(view["player"])
	unit.ep = DictRead.as_int(view["ep"])
	unit.equipment = DictRead.to_int32(view["equipment_ids"])
	for name: String in UNIT_FIELDS:
		unit.set(name, DictRead.as_int(view[name]))
	return unit
