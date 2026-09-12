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
## How many seeds [method _the_dead_mover_fires_nothing] tries before it gives
## up. The remake's, and only a bound on the search.
## `tests/fixtures.gd`'s one large type -- `size` 1, docs/21 section 5.
const LARGE_TYPE: int = 99
const SEED_SEARCH: int = 40


func run(h: TestHarness) -> void:
	h.begin("execute_move", TestHarness.ORACLE_PYTHON)
	_arithmetic(h)
	_delay_experiment(h)
	_victory_points(h)
	_mine(h)
	_the_caller_spends(h)
	_the_move_unit_event(h)
	_the_passes(h)
	_teleporters(h)
	_the_footprint(h)


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
	h.check("execute_move.the_stop_is_reported_for_the_caller",
		moved.stopped_on_mine and moved.detonate.is_empty(),
		"0x0046EC0F gates the block and 0x0046EC25 picks its arm by the "
		+ "type's size, which `run` has no table for")
	_the_large_unit_ring(h)


## docs/26 section 6.2 item 8 -- the ring a `size`-1 mover triggers.
##
## `0x0046EC25` picks the arm at the **arrival**, so the `size` byte is
## written after the walk and before the block: the fill would refuse a large
## mover its 3x3 clearance, and the branch does not read it. That is the same
## move docs/93 section 11 made to reach the clearance itself. No shipped map
## places a large unit next to a mine, so this is the only thing that runs it.
func _the_large_unit_ring(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var found: Dictionary = _mixed_path(world, 0)
	if not h.check("execute_move.ring_path_exists", not found.is_empty()):
		return
	var route: PackedInt32Array = DictRead.as_int32_array(found["route"])
	var stop: int = route[1]
	var width: int = world.state.width
	var sx: int = stop % width
	var sy: int = stop / width
	h.check("execute_move.ring_stop_mine",
		CellObjects.place_mine(world.state, sx, sy) >= 0, "the stop cell")
	# One neighbour, and not one the walk crosses.
	var walked: Dictionary = {}
	var neighbour: int = -1
	for step: Vector2i in CellObjects.STEP_DELTA:
		var nx: int = sx + step.x
		var ny: int = sy + step.y
		if not world.state.in_bounds(nx, ny):
			continue
		if route.has(world.state.index_of(nx, ny)):
			continue
		if CellObjects.place_mine(world.state, nx, ny) >= 0:
			neighbour = world.state.index_of(nx, ny)
			break
	if not h.check("execute_move.ring_neighbour_mine", neighbour >= 0):
		return
	var _w: Dictionary = walked
	var unit: UnitState = world.units_for_ai()[0]
	unit.x = 2
	unit.y = 2
	# The type's size, written for this call only.
	var types: UnitTypeTable = world.unit_types()
	var was: int = types.unit_size(unit.type_id)
	types.set_unit_size(unit.type_id, ExecuteMove.LARGE_UNIT_SIZE)
	var moved: MoveResult = ExecuteMove.execute(world.state,
		world.units_for_ai(), types, world.ctrlmap(), world.weapons(), unit,
		DictRead.as_dict(found["walk"]), sx, sy, 0, 1, 1,
		world.turn.ai_level, world.turn, world.rng)
	types.set_unit_size(unit.type_id, was)
	var fired: PackedInt32Array = moved.detonate
	h.check("execute_move.ring_fired", fired.size() >= 2, "%s" % [fired])
	h.equal("execute_move.ring_left_the_stop_cell",
		world.state.obstacle_at(stop), MapState.OBSTACLE_MINE,
		"0x0046ECA4 sweeps the eight neighbours and not the cell the walk "
		+ "stopped on")
	h.equal("execute_move.ring_cleared_the_neighbour",
		world.state.obstacle_at(neighbour), MapState.OBSTACLE_NONE)
	_the_mine_leaves_before_the_blast(h)


## docs/26 section 6.2 read as an **order**, which is what the picture needs.
##
## Every cell-based detonation is `aDeleteSpecialObject(cell[+0x0F])` and the
## cell bytes cleared, and only then `aExecuteBomb` `0x004702C0` -- whose own
## `aPlayFightAnimation` draws frames. So the mine is off the map before the
## first frame of the blast, and by docs/100's rule an event boundary belongs
## between the two: `mine_cleared` carries the cell, `mine` the casualties.
## With one boundary for both, the picture drew the blast over a mine that
## was still standing and dropped it when the queue drained -- reported from
## `_C_110`'s minefield as *the bomb goes off and then, separately, the
## object disappears*.
func _the_mine_leaves_before_the_blast(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var found: Dictionary = _mixed_path(world, 0)
	if not h.check("execute_move.blast_path_exists", not found.is_empty()):
		return
	var route: PackedInt32Array = DictRead.as_int32_array(found["route"])
	var stop: int = route[1]
	var sx: int = stop % world.state.width
	var sy: int = stop / world.state.width
	if not h.check("execute_move.blast_stop_mine",
			CellObjects.place_mine(world.state, sx, sy) >= 0):
		return
	world.enable_journal()
	var _residue: Array[Dictionary] = world.take_events()
	# The mirror stands where the walk begins, as the picture's does.
	var mirror: World = world.clone()
	var unit: UnitState = world.units_for_ai()[0]
	unit.x = 2
	unit.y = 2
	var _moved: MoveResult = ExecuteMove.execute(world.state,
		world.units_for_ai(), world.unit_types(), world.ctrlmap(),
		world.weapons(), unit, DictRead.as_dict(found["walk"]), sx, sy, 0, 1,
		1, world.turn.ai_level, world.turn, world.rng, -1, true,
		world.journal())
	var kinds: Array[String] = []
	var events: Array[Dictionary] = world.take_events()
	var cleared_at: int = -1
	for i: int in range(events.size()):
		var kind: String = DictRead.as_string(events[i]["kind"])
		kinds.append(kind)
		if kind == "mine_cleared" and cleared_at < 0:
			cleared_at = i
	h.check("execute_move.the_clear_is_its_own_event",
		cleared_at >= 0 and kinds.find("mine") > cleared_at,
		"kinds: %s" % [kinds])
	if cleared_at < 0:
		return
	# Replay up to and including the clear: the cell must already be empty
	# while the blast's own event is still ahead of the mirror.
	for i: int in range(cleared_at + 1):
		mirror.apply_delta(DictRead.as_dict(events[i].get("delta", {})))
	h.equal("execute_move.the_cell_is_clear_before_the_blast",
		mirror.state.obstacle_at(stop), MapState.OBSTACLE_NONE,
		"`aDeleteSpecialObject` runs in front of `aExecuteBomb`")
	h.equal("execute_move.and_its_object_slot_with_it",
		mirror.state.effect_at(MapState.OBJECT_SLOT, stop),
		MapState.NO_OBJECT,
		"the model is drawn from the slot, so both bytes have to land here")


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
	_the_dead_mover_fires_nothing(h)


## [method TestFixtures.tiny_world] with a deliberately useless weapon-36 row.
##
## `aExecuteBomb` uses 36 only to select the aim pattern; its private resolver
## must ignore both zero columns and still pass 30 to the damage routine.
static func _bombable_world(rng_seed: float) -> World:
	var bal: Dictionary = TestFixtures.balance()
	var weapons: Array = DictRead.as_array(bal["weapons"]).duplicate()
	weapons.append({"id": Combat.BOMB_WEAPON, "heat": 255, "toggle": 0,
		"mun": 0, "hit": 0, "damage": 0, "range_min": 1, "range_max": 1,
		"type": 1, "special": 0, "def_mode": 0, "mun_per_fight": 0})
	bal["weapons"] = weapons
	var units: Array = [TestFixtures.unit(0, 2, 2),
		TestFixtures.unit(1, 4, 2, 0, 1)]
	return World.create(TestFixtures.map_document(7, 7, units), bal, rng_seed)


## `0x0046EDDC` -- the walk's own alive gate, and `0x0046F133` the jump's.
##
## Both are `mov al, [record+0x16] / test al, al / je <epilogue>`, placed
## immediately after the mine's `aExecuteBomb` and immediately before the
## fog rebuild, the six `aSetLCLVariable` writes and `aRunLCL`. A mover the
## mine has just killed therefore fires **no** `MoveUnit`, which is what the
## caller has to honour, because the caller is where the remake makes the call.
func _the_dead_mover_fires_nothing(h: TestHarness) -> void:
	# There is no hit roll, but applyDamage still rolls the amount. Search for a
	# killing seed rather than asserting the generator's arithmetic by accident;
	# the walk consumes the mine either way.
	var calls: Array[int] = []
	var killed: bool = false
	var moved: MoveResult = null
	var world: World = null
	for attempt: int in range(SEED_SEARCH):
		world = _bombable_world(float(attempt + 1))
		# **An alien mover**, because [MoveMap] refuses a mined cell to
		# everybody else: the fill this command rebuilds would otherwise route
		# around the mine and the walk would never reach it.
		var mover: UnitState = world.units_for_ai()[0]
		mover.player = UnitState.PLAYER_ALIEN
		var found: Dictionary = _mixed_path(world, 0)
		if found.is_empty():
			continue
		var route: PackedInt32Array = DictRead.as_int32_array(found["route"])
		var stop: int = route[1]
		if CellObjects.place_mine(world.state, stop % world.state.width,
				stop / world.state.width) < 0:
			continue
		mover.hp = 1
		calls = []
		world.script_runner = func(call_type: int, _e: Dictionary) -> Dictionary:
			calls.append(call_type)
			return {"ok": true, "ran": true}
		moved = world.submit_move(MoveCommand.create(0,
			DictRead.as_int(found["x"]), DictRead.as_int(found["y"])))
		killed = moved.stopped_on_mine and not mover.is_alive()
		# The same `RefCounted` cycle the event test breaks, for the same
		# reason, on every attempt and not only the last.
		world.script_runner = Callable(MissionScript, "no_op")
		if killed:
			break
	if not h.check("execute_move.the_mine_killed_the_mover", killed,
			"no seed below %d let the blast kill the mover" % SEED_SEARCH):
		return
	h.equal("execute_move.a_dead_mover_fires_no_move_unit",
		[calls.size(), moved.script_result], [0, {}],
		"0x0046EDDC jumps past aRunLCL at 0x0046EEFD")


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


## A 7x7 floor with one wall cell at (3, 1): a unit on (1, 1) and one on
## (5, 1) cannot see each other along the row, and a step down to (1, 3)
## opens the line past the wall's corner.
static func _walled_world(mover_player: int, mover_x: int, mover_y: int,
		other_player: int) -> World:
	var mover: Dictionary = TestFixtures.unit(0, mover_x, mover_y, 0,
		mover_player, 4, Visibility.HIDDEN)
	var other: Dictionary = TestFixtures.unit(1, 5, 1, 0, other_player, 4,
		Visibility.HIDDEN)
	# Orders 5, 6 and 8 wake the group (docs/22 section 9.3): the secondary
	# order is what the promotion copies over the primary.
	other["order"] = 5
	other["order2"] = 7
	other["group"] = 9
	var heights: Array = []
	for _i: int in range(7 * 7):
		heights.append(0)
	heights[1 * 7 + 3] = 20000
	return World.create(TestFixtures.map_document(7, 7, [mover, other], [],
		heights), TestFixtures.balance(), 1.0)


## `aExecuteMove`'s three visibility passes (docs/22 section 9.3) are writing
## ones, run inside [method ExecuteMove.execute]: from the destination before
## the first step, from the source for a computer mover, and from the arrival
## cell. What they write is `+0x4F` and, through `0x0047A810`, the promoted
## orders of the groups they alert.
func _the_passes(h: TestHarness) -> void:
	# The player's mover: the destination pass reveals the alien it will see
	# from (1, 3) -- and wakes its group -- before a step is taken.
	var world: World = _walled_world(0, 1, 1, UnitState.PLAYER_ALIEN)
	h.equal("passes.the_alien_starts_hidden",
		DictRead.as_int(world.unit_view(1)["visibility"]), Visibility.HIDDEN)
	var moved: MoveResult = world.submit_move(MoveCommand.create(0, 1, 3))
	h.check("passes.the_walk_happened", moved.ok and moved.steps > 0,
		moved.reason)
	h.check("passes.the_destination_answer_is_yes", moved.seen_destination,
		"an enemy is in sight from (1, 3)")
	h.check("passes.the_source_is_not_asked_for_a_human",
		not moved.seen_source, "0x0046E367: only a computer mover asks it")
	h.equal("passes.the_destination_pass_reveals",
		DictRead.as_int(world.unit_view(1)["visibility"]), Visibility.FULL)
	h.equal("passes.the_destination_pass_wakes_the_group",
		DictRead.as_int(world.unit_view(1)["order"]), 7,
		"0x0047A810 copies +0x49 over +0x47 for the whole group")

	# The same walk called directly, with the destination's `+0x0C` over the
	# limit: the flag is discarded (0x0046E357) and the writes are not.
	var direct: World = _walled_world(0, 1, 1, UnitState.PLAYER_ALIEN)
	var units: Dictionary = {
		0: UnitState.from_document(TestFixtures.unit(0, 1, 1, 0, 0, 4,
			Visibility.HIDDEN)),
		1: UnitState.from_document(_walled_alien()),
	}
	var walked: Dictionary = _walk(direct, units, 0, 1, 3)
	var walker: UnitState = units[0]
	var watched: UnitState = units[1]
	var discarded: MoveResult = ExecuteMove.execute(direct.state, units,
		direct.unit_types(), direct.ctrlmap(), direct.weapons(), walker,
		walked, 1, 3, ExecuteMove.ARRIVAL_POINTS_LIMIT + 1, 1, 1,
		direct.turn.ai_level, direct.turn, direct.rng)
	h.check("passes.over_the_limit_discards_the_flag",
		discarded.ok and not discarded.seen_destination,
		"cmp byte [dest + 0x0C], 6; jbe")
	h.equal("passes.over_the_limit_still_writes", watched.visibility,
		Visibility.FULL,
		"the discard is of the answer, never of the pass")
	var kept: Dictionary = {
		0: UnitState.from_document(TestFixtures.unit(0, 1, 1, 0, 0, 4,
			Visibility.HIDDEN)),
		1: UnitState.from_document(_walled_alien()),
	}
	var at_limit: World = _walled_world(0, 1, 1, UnitState.PLAYER_ALIEN)
	var limit_walk: Dictionary = _walk(at_limit, kept, 0, 1, 3)
	var kept_walker: UnitState = kept[0]
	var held: MoveResult = ExecuteMove.execute(at_limit.state, kept,
		at_limit.unit_types(), at_limit.ctrlmap(), at_limit.weapons(),
		kept_walker, limit_walk, 1, 3, ExecuteMove.ARRIVAL_POINTS_LIMIT, 1, 1,
		at_limit.turn.ai_level, at_limit.turn, at_limit.rng)
	h.check("passes.at_the_limit_the_flag_stands",
		held.ok and held.seen_destination, "six is not over six")

	# A computer mover seen where it starts: the source pass is asked, it
	# answers yes, and mode 3 marks the walker itself visible (0x0046E4BB).
	var alien_world: World = _walled_world(UnitState.PLAYER_ALIEN, 1, 3, 0)
	var alien_units: Dictionary = {
		0: UnitState.from_document(TestFixtures.unit(0, 1, 3, 0,
			UnitState.PLAYER_ALIEN, 4, Visibility.HIDDEN)),
		1: UnitState.from_document(TestFixtures.unit(1, 5, 1, 0, 0, 4,
			Visibility.HIDDEN)),
	}
	var alien_walk: Dictionary = _walk(alien_world, alien_units, 0, 1, 1)
	var alien: UnitState = alien_units[0]
	var human: UnitState = alien_units[1]
	var alien_moved: MoveResult = ExecuteMove.execute(alien_world.state,
		alien_units, alien_world.unit_types(), alien_world.ctrlmap(),
		alien_world.weapons(), alien, alien_walk, 1, 1, 0, 1, 1,
		alien_world.turn.ai_level, alien_world.turn, alien_world.rng)
	h.check("passes.a_computer_mover_asks_the_source",
		alien_moved.ok and alien_moved.seen_source, alien_moved.reason)
	h.check("passes.the_wall_hides_the_destination",
		not alien_moved.seen_destination, "(1, 1) to (5, 1) runs through (3, 1)")
	h.equal("passes.mode_3_reveals_the_walker", alien.visibility,
		Visibility.FULL, "aSetVisibleStateForUnit(unit, 0) at 0x0046E4BB")
	h.equal("passes.the_source_pass_reveals_the_human", human.visibility,
		Visibility.FULL)

	# The same walk with the *Enemy Move* option off is mode 0: no self-reveal,
	# but the walker's own arrival pass promotes it to a contact -- the
	# cluster rule is inside `aBuildVisibleMapForUnit`, and the engine left
	# exactly this (`turn_gold.py`, `mode3_off`).
	var quiet_world: World = _walled_world(UnitState.PLAYER_ALIEN, 1, 3, 0)
	var quiet_units: Dictionary = {
		0: UnitState.from_document(TestFixtures.unit(0, 1, 3, 0,
			UnitState.PLAYER_ALIEN, 4, Visibility.HIDDEN)),
		1: UnitState.from_document(TestFixtures.unit(1, 5, 1, 0, 0, 4,
			Visibility.HIDDEN)),
	}
	var quiet_walk: Dictionary = _walk(quiet_world, quiet_units, 0, 1, 1)
	var quiet_alien: UnitState = quiet_units[0]
	var quiet_human: UnitState = quiet_units[1]
	var quiet_moved: MoveResult = ExecuteMove.execute(quiet_world.state,
		quiet_units, quiet_world.unit_types(), quiet_world.ctrlmap(),
		quiet_world.weapons(), quiet_alien, quiet_walk, 1, 1, 0, 1, 1,
		quiet_world.turn.ai_level, quiet_world.turn, quiet_world.rng, -1,
		false)
	h.check("passes.the_option_off_still_asks_the_source",
		quiet_moved.ok and quiet_moved.seen_source, quiet_moved.reason)
	h.equal("passes.the_option_off_leaves_the_walker_a_contact",
		quiet_alien.visibility, Visibility.CONTACT,
		"no mode-3 write; its own arrival pass promotes it (0x00479786)")
	h.equal("passes.the_option_off_still_reveals_the_human",
		quiet_human.visibility, Visibility.FULL)
	h.equal("passes.the_walker_arrived", Vector2i(alien.x, alien.y),
		Vector2i(1, 1))


static func _walled_alien() -> Dictionary:
	var other: Dictionary = TestFixtures.unit(1, 5, 1, 0,
		UnitState.PLAYER_ALIEN, 4, Visibility.HIDDEN)
	other["order"] = 5
	other["order2"] = 7
	other["group"] = 9
	return other


static func _walk(world: World, units: Dictionary, slot: int, tx: int,
		ty: int) -> Dictionary:
	var mover: UnitState = units[slot]
	var fill: MoveMapResult = MoveMap.build(world.state, units,
		world.unit_types(), world.ctrlmap(), slot, false, mover.mp,
		Allowance.for_unit(mover, world.unit_types(), units, 1))
	return WalkMap.path(world.state, units, world.ctrlmap(), fill, mover.x,
		mover.y, tx, ty)


## `aExecuteTeleporter` `0x00470150` -- docs/26 section 5, reached from
## `aExecuteMove`'s own epilogue at `0x0046EE03`.
##
## A corridor on row 1 with an entry on (2, 1) and an exit on (5, 1), both
## keyed 100.
static func _teleporter_world(exit_key: int, blocker: bool) -> World:
	var width: int = 7
	var height: int = 3
	var field_types: Array = []
	var points: Array = []
	for y: int in range(height):
		for x: int in range(width):
			field_types.append(1 if y == 1 else 2)
			points.append(0)
	field_types[1 * width + 2] = 9
	field_types[1 * width + 5] = 10
	points[1 * width + 2] = 100
	points[1 * width + 5] = exit_key
	var units: Array = [TestFixtures.unit(0, 0, 1, 0, 0, 8)]
	if blocker:
		units.append(TestFixtures.unit(1, 5, 1, 0, 0, 0))
	return World.create(TestFixtures.map_document(width, height, units,
		field_types, [], points), TestFixtures.balance(), 1.0)


static func _kinds(moved: MoveResult) -> Array:
	var out: Array = []
	for event: Dictionary in moved.events:
		out.append(DictRead.as_string(event["kind"]))
	return out


func _teleporters(h: TestHarness) -> void:
	var world: World = _teleporter_world(100, false)
	var moved: MoveResult = world.submit_move(MoveCommand.create(0, 4, 1))
	h.equal("teleporter.the_walk_ends_on_the_entry_and_the_unit_leaves_it",
		[moved.steps, Vector2i(moved.x, moved.y)], [2, Vector2i(5, 1)],
		"two steps to (2, 1), then `0x0046EE03` puts it on the exit")
	h.equal("teleporter.the_events_are_in_order", _kinds(moved),
		["teleporter", "teleported"],
		"the walk records the entry, the epilogue records the arrival")
	h.equal("teleporter.the_map_follows",
		[world.state.unit_at(world.state.index_of(2, 1)),
		world.state.unit_at(world.state.index_of(5, 1))],
		[MapState.NO_UNIT, 0],
		"the cell link moves with the record")
	h.equal("teleporter.the_move_unit_event_sees_the_exit",
		Vector2i(DictRead.as_int(world.unit_view(0)["x"]),
		DictRead.as_int(world.unit_view(0)["y"])), Vector2i(5, 1))

	# `0x004701CA` -- no exit carries the key, so nothing happens at all.
	# This is `_C_156`'s key-104 entry, docs/26 section 5.1's authoring bug.
	var orphan: World = _teleporter_world(0, false)
	var stuck: MoveResult = orphan.submit_move(MoveCommand.create(0, 4, 1))
	h.equal("teleporter.an_unpaired_entry_is_inert",
		[Vector2i(stuck.x, stuck.y), _kinds(stuck)],
		[Vector2i(2, 1), ["teleporter"]],
		"the walk still ends on the entry; the traveller stays there")

	# `0x004701DD` -- an occupied exit kills the traveller on the entry cell.
	var blocked: World = _teleporter_world(100, true)
	var died: MoveResult = blocked.submit_move(MoveCommand.create(0, 4, 1))
	var alive: bool = DictRead.as_int(blocked.unit_view(0)["hp"]) > 0
	h.equal("teleporter.an_occupied_exit_kills_the_traveller",
		[alive, _kinds(died)],
		[false, ["teleporter", "teleporter_blocked"]],
		"`aRemoveUnitElement` takes it off the entry cell")
	h.equal("teleporter.the_dead_traveller_leaves_the_entry",
		blocked.state.unit_at(blocked.state.index_of(2, 1)),
		MapState.NO_UNIT)


## `aWriteUnitIdIntoCtrlMap` (`0x0047A240`) -- every cell a large unit's link
## covers, and the four things that write it.
##
## docs/10 section 4.4: the authored `.lev` already names all nine cells of
## every large unit, which is why the 128 cells whose link disagrees with the
## unit's own coordinates are not a parse error. The remake used to clear and
## write the **centre** alone, so a `ComBot` that took one step left eight
## cells naming a unit that had walked away: eight cells no unit could enter
## and no fill could cross for the rest of the mission. Reported from
## `_C_113`, where the authored ring at (17..19, 12..14) still blocked a
## marine on turn 6.
func _the_footprint(h: TestHarness) -> void:
	var units: Array = [TestFixtures.unit(0, 4, 4, LARGE_TYPE),
		TestFixtures.unit(1, 2, 2)]
	var world: World = World.create(
		TestFixtures.map_document(9, 9, units), TestFixtures.balance(), 1.0)
	var big: UnitState = world.units_for_ai()[0]
	var types: UnitTypeTable = world.unit_types()
	h.equal("footprint.the_type_is_large",
		types.unit_size(big.type_id), UnitTypeTable.SIZE_LARGE)
	h.equal("footprint.nine_cells",
		UnitState.footprint(world.state, types, big, 4, 4).size(), 9,
		"0x0047A319's eight writes plus the centre at 0x0047A3EC")
	var small_unit: UnitState = world.units_for_ai()[1]
	h.equal("footprint.one_cell_for_a_small_unit",
		UnitState.footprint(world.state, types, small_unit, 2, 2).size(), 1,
		"0x0047A3FB -- the other arm")
	h.equal("footprint.the_map_edge_clips_it",
		UnitState.footprint(world.state, types, big, 0, 0).size(), 4,
		"aGetCtrlMapElementPtr 0x0042F730 answers NULL off the map and the "
		+ "write is skipped")

	# The authored map names the centre only; the engine's own loader stamps
	# the block, so stamp it here the way a `.lev` carries it.
	UnitState.occupy(world.state, types, big, 4, 4)
	h.equal("footprint.the_block_is_named", _named(world, 0), 9)
	var _fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(0))
	var moved: MoveResult = world.submit_move(MoveCommand.create(0, 5, 4))
	if not h.check("footprint.the_large_unit_walked", moved.ok, moved.reason):
		return
	h.equal("footprint.the_walk_moved_the_whole_block",
		[_named(world, 0), world.state.unit_at(world.state.index_of(3, 3)),
			world.state.unit_at(world.state.index_of(6, 5))],
		[9, MapState.NO_UNIT, 0],
		"clear then write, and the overlapping cells survive the pair")

	# The symptom: the cells the block left are cells a marine can walk into.
	var small: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(1))
	h.check("footprint.the_vacated_cells_are_reachable",
		small.is_reachable(3, 3) and small.is_reachable(3, 4)
		and small.is_reachable(3, 5),
		"the column the block left is a column to walk into")

	var _hero: bool = UnitState.remove(world.state, types, world.turn, big)
	h.equal("footprint.death_clears_the_block", _named(world, 0), 0,
		"aRemoveUnitElement 0x004779C0 calls the same routine with 0xFFFF")


## How many cells name *slot*.
func _named(world: World, slot: int) -> int:
	var n: int = 0
	for i: int in range(world.state.cell_count()):
		if world.state.unit_at(i) == slot:
			n += 1
	return n
