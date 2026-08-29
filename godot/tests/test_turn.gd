extends TestSuite

## Oracle boundary: **executable Python**, which is itself pinned to the native
## runtime.  `tools/turn_gold.py --check` diffs `tools/inclib/turn.py` against
## `0x0043B320` and `0x004781C0` inside a live `Incubation.exe`; this suite
## diffs `core/` against the same rules.
##
## The rotation cases come straight from that capture's shape: a campaign save
## has one human slot and the computer, so the cycle is `0, 255, 0, ...` and
## `any_player_left_this_turn` alternates with it because the computer moves
## last.

const PLAYER_COMPUTER: int = TurnState.PLAYER_COMPUTER


func _campaign_state() -> TurnState:
	var state: TurnState = TurnState.create()
	state.turn = 1
	state.current_player = 0
	state.player_count = 1
	state.player_kind = PackedInt32Array([1, 0, 0, 0])
	state.end_state = PackedInt32Array([1, 0, 0, 0])
	state.solo_flag = true
	state.ai_level = 0
	return state


func run(h: TestHarness) -> void:
	h.begin("turn", TestHarness.ORACLE_PYTHON)
	_rotation(h)
	_turn_counter(h)
	_refresh(h)


func _rotation(h: TestHarness) -> void:
	var state: TurnState = _campaign_state()
	var live: Callable = func(_slot: int) -> int: return 1
	var seen_current: Array[int] = []
	var seen_left: Array[bool] = []
	for _step: int in range(12):
		seen_current.append(state.current_player)
		seen_left.append(Rotation.any_player_left_this_turn(state, live))
		h.check("rotation.advance_returns_true",
			Rotation.advance_player(state, live), "step accepted")
	h.check("rotation.cycles_player_and_computer",
		seen_current == [0, PLAYER_COMPUTER, 0, PLAYER_COMPUTER, 0,
			PLAYER_COMPUTER, 0, PLAYER_COMPUTER, 0, PLAYER_COMPUTER, 0,
			PLAYER_COMPUTER],
		str(seen_current))
	# The computer moves last, so with it current there is never anybody left.
	h.check("rotation.any_left_alternates",
		seen_left == [true, false, true, false, true, false, true, false,
			true, false, true, false],
		str(seen_left))
	h.check("rotation.previous_is_the_one_before",
		state.previous_player == PLAYER_COMPUTER,
		"previous %d" % state.previous_player)
	# docs/25 section 7: 252 is never stored in the current-player byte.
	h.check("rotation.never_yields_the_prop_owner",
		not seen_current.has(TurnState.PLAYER_PROPS), "no 252")


func _turn_counter(h: TestHarness) -> void:
	var state: TurnState = TurnState.create()
	state.turn = TurnState.TURN_WRAP - 1
	h.check("turn.wraps_at_200", state.advance_turn() == 0,
		"turn %d" % state.turn)
	h.check("turn.counts_up", state.advance_turn() == 1, "turn %d" % state.turn)
	# At zero the whole skip rule is disabled, which is why the first hand-over
	# of a mission reaches every slot even before the script has placed anybody.
	var zero: TurnState = _campaign_state()
	zero.turn = 0
	zero.end_state = PackedInt32Array([0, 0, 0, 0])
	var none: Callable = func(_slot: int) -> int: return 0
	h.check("turn.zero_disables_the_skip_rule",
		Rotation.slot_qualifies(zero, 0, none), "slot 0 still qualifies")
	zero.turn = 1
	h.check("turn.past_zero_the_skip_rule_bites",
		not Rotation.slot_qualifies(zero, 0, none), "slot 0 skipped")


func _refresh(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var units: Dictionary = {}
	var unit: UnitState = UnitState.new()
	unit.slot = 0
	unit.player = 0
	unit.type_id = 0
	unit.hp = 10
	unit.x = 1
	unit.y = 1
	unit.fp = 1
	unit.mp = 0
	unit.action_state = Refresh.ACTION_STOOD_DOWN
	unit.walked = 40
	unit.stimulant = Refresh.STIMULANT_SPENT
	unit.ticket = 7
	unit.acted = 1
	unit.malfunction = 2
	units[0] = unit

	var state: TurnState = _campaign_state()
	state.reaction_counter = PackedInt32Array([3, 3, 3, 3])
	var no_banner: Callable = func(_slot: int) -> bool: return false
	var touched: PackedInt32Array = Refresh.player(state, 0, units,
		world.unit_types(), WeaponTable.from_rows([]), no_banner)

	h.check("refresh.touches_the_incoming_player", touched == PackedInt32Array([0]),
		str(touched))
	h.check("refresh.zeroes_the_reaction_counters",
		state.reaction_counter == PackedInt32Array([0, 0, 0, 0]),
		str(state.reaction_counter))
	h.check("refresh.clears_a_spent_stimulant", unit.stimulant == 0,
		"stimulant %d" % unit.stimulant)
	h.check("refresh.records_where_the_turn_began",
		unit.turn_start_x == 1 and unit.turn_start_y == 1,
		"(%d,%d)" % [unit.turn_start_x, unit.turn_start_y])
	h.check("refresh.resets_the_walked_distance", unit.walked == 0,
		"walked %d" % unit.walked)
	# `rested` is set from the state *before* it is cleared, which is the only
	# way the "did not act last turn" bonus can ever be earned.
	h.check("refresh.stood_down_becomes_rested", unit.rested == 1,
		"rested %d" % unit.rested)
	h.check("refresh.clears_the_action_state", unit.action_state == 0,
		"action_state %d" % unit.action_state)
	h.check("refresh.clears_the_acted_flag", unit.acted == 0,
		"acted %d" % unit.acted)
	h.check("refresh.clears_the_reaction_ticket", unit.ticket == 0,
		"ticket %d" % unit.ticket)
	h.check("refresh.steps_the_malfunction_ladder", unit.malfunction == 1,
		"malfunction %d" % unit.malfunction)
	# The movement points are **restored**, which is the correction this slice
	# made to docs/25 section 5: `0x004759B0` stores `aGetMovePoints`'s answer.
	h.check("refresh.restores_the_movement_points", unit.mp > 0,
		"mp %d" % unit.mp)
	# The ordering inside the refresh is what earns the rested bonus, and it is
	# the part a reimplementation is most likely to get wrong: `rested` is set
	# from the *incoming* action state, and only then is the allowance asked
	# for.  Clearing the state first would silently drop the point.  Compared
	# against a unit identical but for having acted.
	var busy: UnitState = UnitState.new()
	busy.slot = 1
	busy.player = 0
	busy.type_id = unit.type_id
	busy.hp = 10
	busy.x = 2
	busy.y = 2
	busy.fp = 1
	busy.action_state = 0
	var busy_units: Dictionary = {1: busy}
	var busy_state: TurnState = _campaign_state()
	Refresh.player(busy_state, 0, busy_units, world.unit_types(),
		WeaponTable.from_rows([]), no_banner)
	h.check("refresh.standing_down_is_worth_one_movement_point",
		unit.mp == busy.mp + 1,
		"stood down %d, acted %d" % [unit.mp, busy.mp])
	h.check("refresh.the_busy_unit_is_not_rested", busy.rested == 0,
		"rested %d" % busy.rested)

	# The ordering the refresh comments on is only observable through action
	# states 5 and 6, the two `Allowance` zeroes: `0x004759B0` asks
	# `aGetMovePoints`, which reads `+0x41`, and the state is cleared only
	# afterwards.  Clearing it first would hand such a unit a full allowance.
	# A unit in state 7 cannot show this -- 7 is not a suppressing state -- so
	# an ordering test written on the stood-down unit above passes either way.
	var suppressed: UnitState = UnitState.new()
	suppressed.slot = 2
	suppressed.player = 0
	suppressed.type_id = unit.type_id
	suppressed.hp = 10
	suppressed.x = 3
	suppressed.y = 3
	suppressed.fp = 1
	suppressed.mp = 9
	suppressed.action_state = Allowance.ACTION_STATE_SUPPRESSED[0]
	var suppressed_units: Dictionary = {2: suppressed}
	Refresh.player(_campaign_state(), 0, suppressed_units,
		world.unit_types(), WeaponTable.from_rows([]), no_banner)
	h.check("refresh.recomputes_before_clearing_the_action_state",
		suppressed.mp == 0,
		"a unit in state %d keeps a zero allowance, got %d"
			% [Allowance.ACTION_STATE_SUPPRESSED[0], suppressed.mp])
	h.check("refresh.still_clears_that_action_state",
		suppressed.action_state == 0,
		"action_state %d" % suppressed.action_state)

	# The ladder, every rung, because the fixture above only walks one.
	var ladder: Array[int] = []
	for rung: int in [0, 1, 2, 3, 4, 5, 6]:
		ladder.append(Refresh.malfunction_step(rung))
	h.check("refresh.malfunction_ladder_is_the_documented_one",
		ladder == [0, 0, 1, 0, 3, 4, 6], str(ladder))
