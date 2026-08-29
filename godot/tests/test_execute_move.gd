extends TestSuite

## Oracle boundary: **executable Python**, itself pinned to the native runtime.
##
## `tools/turn_gold.py` phase 10 walks one two-step path six times inside a live
## `Incubation.exe`, writing one byte between the walk and the call each time.
## This suite runs the same six experiments against `core/`, in the same order
## and with the same sequencing -- the fill and the walk happen on the clean
## map, every mutation lands afterwards -- so the two are asking the engine and
## the remake the same question rather than two similar ones.

## docs/21 section 2 -- Debris, the only shipped field type with a delay that
## is neither 0 nor impassable.  The delay experiment needs exactly that.
const DEBRIS: int = 5
const FREE_PLACE: int = 1
## docs/26 section 6.1 -- VictoryPoint A, unclaimed.
const VICTORY_UNCLAIMED: int = 0x50


func run(h: TestHarness) -> void:
	h.begin("execute_move", TestHarness.ORACLE_PYTHON)
	_arithmetic(h)
	_delay_experiment(h)
	_victory_points(h)
	_mine(h)
	_the_caller_spends(h)
	_the_move_unit_event(h)


## A world whose mover has room to take a two-step path with one orthogonal
## step and one diagonal one, and that path.
##
## The target is **found**, not written down: the walk's tie-breaking is
## docs/23 section 8's and a hard-coded cell would be asserting the tie rule by
## accident.  What is asserted is that such a path exists and that it mixes the
## two step kinds, which is what makes one walk pin both bases at once.
func _mixed_path(world: World, slot: int) -> Dictionary:
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(slot))
	for y: int in range(world.state.height):
		for x: int in range(world.state.width):
			if not fill.is_reachable(x, y):
				continue
			var walked: Dictionary = world.walk_path(fill, slot, x, y)
			if not DictRead.as_bool(walked["ok"]):
				continue
			if DictRead.as_int(walked["steps"]) != 2:
				continue
			var route: PackedInt32Array = DictRead.as_int32_array(
				walked["path"]).duplicate()
			route.reverse()
			if _diagonal_steps(world, route) != 1:
				continue
			return {"walk": walked, "route": route, "x": x, "y": y}
	return {}


func _diagonal_steps(world: World, route: PackedInt32Array) -> int:
	var n: int = 0
	for i: int in range(1, route.size()):
		var a: int = route[i - 1]
		var b: int = route[i]
		if a % world.state.width != b % world.state.width \
				and a / world.state.width != b / world.state.width:
			n += 1
	return n


## The numbers are written out here, not imported from [ExecuteMove]: a check
## that multiplies by the constant it is checking passes whatever the constant
## is.  These four are docs/10 section 5.10 and docs/26 section 5, and the
## native oracle for them is one path that cost 3 and walked 25.
func _arithmetic(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var found: Dictionary = _mixed_path(world, 0)
	if not h.check("execute_move.a_mixed_path_exists", not found.is_empty(),
			"a two-step path with one orthogonal step and one diagonal"):
		return
	var unit: UnitState = UnitState.new()
	unit.slot = 0
	unit.x = 2
	unit.y = 2
	unit.player = 0
	var moved: MoveResult = ExecuteMove.run(world.state, world.ctrlmap(), unit,
		DictRead.as_dict(found["walk"]))
	h.check("execute_move.returns_true", moved.ok, moved.reason)
	h.equal("execute_move.steps", moved.steps, 2)
	h.equal("execute_move.cost", moved.cost, 1 + 2)
	h.equal("execute_move.walked_in_tenths", moved.walked, 10 + 15)
	h.equal("execute_move.ends_on_the_target", moved.x,
		DictRead.as_int(found["x"]))
	h.equal("execute_move.ends_on_the_target_y", moved.y,
		DictRead.as_int(found["y"]))

	# The facing is the **last** step's, which is the half the native capture's
	# mine probe proved: it stopped on the orthogonal step and came back
	# holding that facing while the five that finished held the diagonal's.
	var route: PackedInt32Array = DictRead.as_int32_array(found["route"])
	var last: int = route[route.size() - 2]
	var end: int = route[route.size() - 1]
	var step: Vector2i = Vector2i(
		end % world.state.width - last % world.state.width,
		end / world.state.width - last / world.state.width)
	h.equal("execute_move.facing_is_the_last_step",
		moved.facing, DictRead.as_int(ExecuteMove.FACING_OF_STEP[step]))


## The experiment phase 10 ran, reproduced: one path, four walks, a delay-1
## field type on a different cell of it each time.
##
## Written **after** the walk, exactly as the capture does it, so all four
## follow the identical route and the cost difference has one cause.
func _delay_experiment(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var found: Dictionary = _mixed_path(world, 0)
	if not h.check("execute_move.delay_path_exists", not found.is_empty()):
		return
	var route: PackedInt32Array = DictRead.as_int32_array(found["route"])
	var costs: Dictionary = {}
	var cells: Dictionary = {
		"control": -1,
		"source": route[0],
		"middle": route[1],
		"dest": route[route.size() - 1],
	}
	for tag: String in ["control", "source", "middle", "dest"]:
		var index: int = DictRead.as_int(cells[tag])
		if index >= 0:
			world.state.set_field_type(index, DEBRIS)
		var unit: UnitState = UnitState.new()
		unit.slot = 0
		unit.x = 2
		unit.y = 2
		unit.player = 0
		var moved: MoveResult = ExecuteMove.run(world.state, world.ctrlmap(),
			unit, DictRead.as_dict(found["walk"]))
		costs[tag] = moved.cost
		if index >= 0:
			world.state.set_field_type(index, FREE_PLACE)

	var control: int = DictRead.as_int(costs["control"])
	h.equal("execute_move.delay_on_the_source_is_free",
		DictRead.as_int(costs["source"]) - control, 0)
	h.equal("execute_move.delay_on_a_crossed_cell_costs_one",
		DictRead.as_int(costs["middle"]) - control, 1)
	h.equal("execute_move.delay_on_the_destination_costs_one",
		DictRead.as_int(costs["dest"]) - control, 1)


## docs/26 section 6.1, and the arm the shipped corpus never reaches: over all
## 4587 reconstructed paths not one walks onto a VictoryPoint.
func _victory_points(h: TestHarness) -> void:
	for player: int in [0, 3, ExecuteMove.PLAYER_ALIEN]:
		var world: World = TestFixtures.tiny_world()
		var found: Dictionary = _mixed_path(world, 0)
		if not h.check("execute_move.victory_path_exists_%d" % player,
				not found.is_empty()):
			return
		var route: PackedInt32Array = DictRead.as_int32_array(found["route"])
		var target: int = route[route.size() - 1]
		world.state.set_action_point(target, VICTORY_UNCLAIMED)
		var unit: UnitState = UnitState.new()
		unit.slot = 0
		unit.x = 2
		unit.y = 2
		unit.player = player
		var moved: MoveResult = ExecuteMove.run(world.state, world.ctrlmap(),
			unit, DictRead.as_dict(found["walk"]))
		if player == ExecuteMove.PLAYER_ALIEN:
			h.equal("execute_move.the_pseudo_player_claims_nothing",
				moved.action_point_writes.size(), 0)
			continue
		h.equal("execute_move.one_claim_per_victory_point",
			moved.action_point_writes.size(), 1)
		h.equal("execute_move.claimed_as_0x51_plus_player_%d" % player,
			moved.action_point_writes[0].y, 0x51 + player)
		h.equal("execute_move.claiming_is_free_%d" % player, moved.cost,
			1 + 2)


## The arm docs/26 section 6.1 got wrong, and the reason this suite carries it:
## a mine ends the walk, zeroes the movement points and returns **FALSE** with
## a cost of 0 -- and fires nothing.  Measured natively; the seed, the mover's
## hit points and the cell's own byte were all unchanged.
func _mine(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var found: Dictionary = _mixed_path(world, 0)
	if not h.check("execute_move.mine_path_exists", not found.is_empty()):
		return
	var route: PackedInt32Array = DictRead.as_int32_array(found["route"])
	world.state.set_obstacle(route[1], MapState.OBSTACLE_MINE)
	var unit: UnitState = UnitState.new()
	unit.slot = 0
	unit.x = 2
	unit.y = 2
	unit.player = 0
	var moved: MoveResult = ExecuteMove.run(world.state, world.ctrlmap(), unit,
		DictRead.as_dict(found["walk"]))
	h.check("execute_move.a_mine_answers_false", not moved.ok, moved.reason)
	h.equal("execute_move.a_mine_stops_the_walk", moved.steps, 1)
	h.equal("execute_move.a_mine_reports_no_cost", moved.cost, 0)
	h.equal("execute_move.a_mine_still_accumulates_distance",
		moved.walked, 10)
	h.check("execute_move.a_mine_zeroes_the_movement",
		moved.movement_zeroed, "the routine does it, not the caller")
	h.equal("execute_move.the_mine_is_the_only_event", moved.events.size(),
		1)
	h.equal("execute_move.and_it_is_a_mine",
		DictRead.as_string(moved.events[0]["kind"]), "mine")


## The seam docs/23 section 5.3 draws and docs/93 section 11 measured: the
## routine reports and the **caller** spends.  Both halves are asserted, since
## a remake that got this wrong would double-charge one path and leave the
## other free.
func _the_caller_spends(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var found: Dictionary = _mixed_path(world, 0)
	if not h.check("execute_move.spend_path_exists", not found.is_empty()):
		return
	var before: Dictionary = world.unit_view(0)
	var unit: UnitState = UnitState.new()
	unit.slot = 0
	unit.x = 2
	unit.y = 2
	unit.player = 0
	unit.mp = DictRead.as_int(before["mp"])
	ExecuteMove.run(world.state, world.ctrlmap(), unit,
		DictRead.as_dict(found["walk"]))
	h.equal("execute_move.the_routine_spends_nothing", unit.mp,
		DictRead.as_int(before["mp"]))
	h.equal("execute_move.and_moves_nothing", unit.x, 2)

	var target_x: int = DictRead.as_int(found["x"])
	var target_y: int = DictRead.as_int(found["y"])
	var moved: MoveResult = world.submit_move(
		MoveCommand.create(0, target_x, target_y))
	h.check("execute_move.submit_move_walks", moved.ok, moved.reason)
	var after: Dictionary = world.unit_view(0)
	h.equal("execute_move.the_caller_charges_the_cost",
		DictRead.as_int(after["mp"]),
		DictRead.as_int(before["mp"]) - moved.cost)
	h.equal("execute_move.the_unit_is_where_it_walked_to",
		DictRead.as_int(after["x"]), target_x)
	h.equal("execute_move.the_map_link_followed_it",
		world.state.unit_at(world.state.index_of(target_x, target_y)), 0)
	h.equal("execute_move.the_cell_it_left_is_empty",
		world.state.unit_at(world.state.index_of(2, 2)), MapState.NO_UNIT)
	h.equal("execute_move.distance_accumulates_on_the_unit",
		DictRead.as_int(after["walked"]),
		DictRead.as_int(before["walked"]) + moved.walked)
	h.equal("execute_move.the_caller_marks_it_as_acted",
		DictRead.as_int(after["acted"]), World.ACTED_MOVED)

	_blocked_path(h)


## docs/20 section 5 -- the `MoveUnit` event a completed walk fires.
##
## Wired but unchecked is the same as not wired: removing the call left every
## other check in this file green, which is why this one exists. What it pins
## is the call type, the whole environment, and that the event fires **before**
## the caller charges -- the engine fires it inside `aExecuteMove` while the
## subtraction is the caller's, so a script reading the mover's movement points
## sees them uncharged.
func _the_move_unit_event(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var found: Dictionary = _mixed_path(world, 0)
	if not h.check("execute_move.event_path_exists", not found.is_empty()):
		return
	var target_x: int = DictRead.as_int(found["x"])
	var target_y: int = DictRead.as_int(found["y"])
	# The action point the arrival cell carries, so `_E` is not zero by
	# accident and a runner that filled the wrong slot would still pass.
	var arrived: int = world.state.index_of(target_x, target_y)
	world.state.set_action_point(arrived, 37)

	var seen: Array[Dictionary] = []
	var mp_at_call: Array[int] = []
	world.script_runner = func(call_type: int, e: Dictionary) -> Dictionary:
		seen.append({"call_type": call_type, "env": e.duplicate()})
		mp_at_call.append(DictRead.as_int(world.unit_view(0)["mp"]))
		return {"ok": true, "ran": true}

	var before: int = DictRead.as_int(world.unit_view(0)["mp"])
	var moved: MoveResult = world.submit_move(
		MoveCommand.create(0, target_x, target_y))
	h.check("execute_move.the_walk_fires_one_event", seen.size() == 1,
		"%d event(s)" % seen.size())
	if seen.is_empty():
		return
	h.equal("execute_move.the_event_is_move_unit",
		DictRead.as_int(seen[0]["call_type"]), MissionScript.CALL_MOVE_UNIT)
	h.equal("execute_move.the_environment_is_the_arrival_cell",
		DictRead.as_dict(seen[0]["env"]),
		{
			MissionScript.SLOT_A: MissionScript.CALL_MOVE_UNIT,
			MissionScript.SLOT_B: target_x,
			MissionScript.SLOT_C: target_y,
			MissionScript.SLOT_D: world.state.height_at(arrived)
				/ MissionScript.HEIGHT_LEVEL_UNITS,
			MissionScript.SLOT_E: 37,
			MissionScript.SLOT_F: 0,
		})
	h.equal("execute_move.the_event_sees_uncharged_movement", mp_at_call[0],
		before)
	h.equal("execute_move.and_the_charge_follows_it",
		DictRead.as_int(world.unit_view(0)["mp"]), before - moved.cost)
	# **Put the default back, or this leaks.** The lambda above captures
	# `world`, and `world` holds the lambda -- a `RefCounted` cycle that Godot
	# reports as "resources still in use at exit" and nothing else notices.
	# `run_tests.sh` treats that line as a failure, which is how it was found.
	world.script_runner = Callable(MissionScript, "no_op")


## `blocked != 0` -- a path that runs over another unit is **abandoned**
## (docs/23 section 5.3), and the caller moves nothing.
##
## Reaching that arm at all takes a corridor and a **hidden** unit standing in
## it. The fill treats a hidden unit as an empty cell (docs/22 section 9.1) so
## the target stays reachable, while the walk counts any occupant at all --
## which is the only combination that produces a non-zero blocked count without
## `pass_friendlies`. An open map is no use here: the walk simply goes round.
func _blocked_path(h: TestHarness) -> void:
	var width: int = 7
	var height: int = 3
	var field_types: Array = []
	for y: int in range(height):
		for x: int in range(width):
			field_types.append(FREE_PLACE if y == 1 else 2)
	var units: Array = [
		TestFixtures.unit(0, 0, 1, 0, 0, 8),
		TestFixtures.unit(1, 2, 1, 0, 0, 0, UnitState.VISIBILITY_HIDDEN),
	]
	var world: World = World.create(
		TestFixtures.map_document(width, height, units, field_types),
		TestFixtures.balance(), 1.0)

	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(0))
	if not h.check("execute_move.the_corridor_reaches_past_the_hidden_unit",
			fill.is_reachable(4, 1),
			"the fill must treat the hidden unit as an empty cell"):
		return
	var walked: Dictionary = world.walk_path(fill, 0, 4, 1)
	h.equal("execute_move.the_walk_counts_the_hidden_unit",
		DictRead.as_int(walked["blocked"]), 1)
	var far: MoveResult = world.submit_move(MoveCommand.create(0, 4, 1))
	h.check("execute_move.a_blocked_path_is_refused", not far.ok, far.reason)
	h.equal("execute_move.a_blocked_path_moves_nothing",
		DictRead.as_int(world.unit_view(0)["x"]), 0)
	h.equal("execute_move.a_blocked_path_spends_nothing",
		DictRead.as_int(world.unit_view(0)["mp"]), 8)
