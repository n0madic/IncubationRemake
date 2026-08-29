extends TestSuite

## Oracle boundary: **specification** -- and the stage's gate.
##
## docs/20's win conditions, played rather than asserted: `_C_140` is loaded
## from the cache with its own program attached, its squad is walked to the
## evacuation zone through [method World.submit_move], the turn is handed over
## through [method World.submit_end_turn], and the mission is expected to end
## because the script decided it did.
##
## What makes this a gate rather than a demonstration: **nothing here writes
## `game_control`**. Slot 0 is set by `SetGameControl (0,1)` inside `_C_140`'s
## own `NEXT PLAYER` body, which runs only if the interpreter reached it, which
## needs the two `GetUnits` counts to agree and a unit to be standing on
## `(3,18)` -- so the assertion at the end is a statement about the whole stack
## from the move map up.
##
## The mission's own text, decoded:
## [codeblock]
## >UnitOnField (0,3,18);          SetVarNum (_F,1);           <
## >VarCmpNum (_F,1); &VarCmpVar (_A,_G);  SetGameControl (0,1); <
## [/codeblock]
## `_A` is `GetUnits (0)` and `_G` is `GetUnitsInArea (0, 0,13, 8,19)`, so the
## whole squad must be inside the zone **and** one of them on the marker.

const MISSION: String = "_C_140"
## The evacuation zone `GetUnitsInArea (_G,0,0,13,8,19)` names, and the marker
## `UnitOnField (0,3,18)` names.
const MARKER: Vector2i = Vector2i(3, 18)
const ZONE_TOP_LEFT: Vector2i = Vector2i(0, 13)
const ZONE_BOTTOM_RIGHT: Vector2i = Vector2i(8, 19)
## Where the four squad members are sent. The first is the marker; the other
## three are free cells beside it, inside the zone.
const TARGETS: Array[Vector2i] = [Vector2i(3, 18), Vector2i(4, 18),
	Vector2i(3, 17), Vector2i(4, 17)]

## A bound, not a prediction. The potential-field walk below takes 17 player
## turns; anything past this is a regression that would otherwise hang the run.
const TURN_LIMIT: int = 40
## The movement points the potential fill is given -- enough to flood the whole
## reachable component of a 20x20 map many times over.
const FLOOD_MP: int = 2000
## The turn `_C_140`'s script first inserts reinforcements (`EnvVarGreaterNum
## (_B,4)`), which is what makes the mid-mission save carry a spawned unit.
const FIRST_INSERT_TURN: int = 5


func run(h: TestHarness) -> void:
	h.begin("mission", TestHarness.ORACLE_SPEC)
	var loaded: Dictionary = CacheFixture.load_mission(MISSION)
	if loaded.is_empty():
		h.check("cache", false,
			"no %s in the cache; run tools/remake_convert.py" % MISSION)
		return
	var world: World = loaded["world"]
	h.check("script.attached", DictRead.as_bool(loaded["script_attached"]),
		"missions/%s/script.json" % MISSION)
	h.check("script.is_the_real_one", world.script_program != null
			and world.script_program.labels.has("NextPlayer"),
		"the entry points the dispatcher jumps to")

	var squad: PackedInt32Array = _squad(world)
	h.equal("squad.size", squad.size(), TARGETS.size(),
		"_C_140 places four units of player 0")
	h.check("squad.starts_outside_the_zone", not _all_in_zone(world, squad),
		"a mission that began won would prove nothing")
	h.equal("control.starts_unset", world.game_control.mission_ended(), false)

	_play(h, world, squad, DictRead.as_dict(loaded["document"]))


## The squad, in slot order.
static func _squad(world: World) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["player"]) == 0 \
				and DictRead.as_int(view["hp"]) > 0:
			out.append(slot)
	return out


static func _all_in_zone(world: World, squad: PackedInt32Array) -> bool:
	for slot: int in squad:
		var view: Dictionary = world.unit_view(slot)
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		if x < ZONE_TOP_LEFT.x or x > ZONE_BOTTOM_RIGHT.x \
				or y < ZONE_TOP_LEFT.y or y > ZONE_BOTTOM_RIGHT.y:
			return false
	return true


## Walk the squad in, handing the turn over between rounds, until the script
## ends the mission.
func _play(h: TestHarness, world: World, squad: PackedInt32Array,
		document: Dictionary) -> void:
	# One fill per target, from the target outwards, on the map as authored.
	# `mp_left` is then a proximity field: higher is closer. A greedy walk on
	# the Chebyshev distance instead walks into the wall across row 12 and
	# stops -- measured, on this map, before this was written.
	var potential: Array[PackedInt32Array] = []
	for i: int in range(squad.size()):
		var view: Dictionary = world.unit_view(squad[i])
		potential.append(_potential(document, world.unit_types(),
			world.ctrlmap(), DictRead.as_int(view["type_id"]), TARGETS[i]))

	# The first hand-over: `arg != 0` searches from slot 0 instead of advancing,
	# which is how a mission starts (docs/25 section 3.1).
	var first: TurnResult = world.submit_end_turn(EndTurnCommand.create(1))
	h.equal("start.first_hand_over", first.code, TurnResult.OK,
		"arg 1 searches from slot 0")

	var saved: PackedByteArray = PackedByteArray()
	var saved_hash: String = ""
	var saved_units: int = 0
	var rounds: int = 0
	var moves: int = 0
	while rounds < TURN_LIMIT and not world.game_control.mission_ended():
		rounds += 1
		if world.turn.current_player == 0:
			for i: int in range(squad.size()):
				if _step(world, squad[i], potential[i]):
					moves += 1
		# The mid-mission save is taken once the script has inserted at least
		# one unit, so the hash it preserves covers a roster the `.lev` does
		# not describe.
		if saved.is_empty() and world.turn.turn >= FIRST_INSERT_TURN \
				and world.unit_slots().size() > squad.size() + 2:
			saved = world.save({})
			saved_hash = world.canonical_hash_hex()
			saved_units = world.unit_slots().size()
		var handed: TurnResult = world.submit_end_turn(EndTurnCommand.create())
		if handed.code != TurnResult.OK and not handed.mission_ended:
			h.check("play.hand_over_%d" % rounds, false,
				"code %d at turn %d" % [handed.code, world.turn.turn])
			return

	h.check("play.moved", moves > 0, "%d move command(s)" % moves)
	h.check("play.within_the_bound", rounds < TURN_LIMIT,
		"%d hand-over(s)" % rounds)
	h.check("play.squad_reached_the_zone", _all_in_zone(world, squad),
		"the whole squad inside (0,13)-(8,19)")
	h.check("play.a_unit_stands_on_the_marker", _on_marker(world, squad),
		"UnitOnField (0,3,18)")
	h.equal("play.the_script_ended_the_mission",
		world.game_control.mission_ended(), true,
		"SetGameControl (0,1) from _C_140's own NEXT PLAYER body")
	h.equal("play.slot_zero_is_the_win", world.game_control.get_slot(0), 1)
	h.equal("play.the_computer_did_not_win",
		world.game_control.get_slot(4), 0,
		"slot 4 is set when the squad is wiped out or the hero dies")
	h.equal("play.the_next_map_is_named", world.next_map, "_C_141",
		"EnterNameOfNextMap from the InitMap entry -- or the header, which "
		+ "agrees")

	# The mid-mission save, with the script's own reinforcements in it.
	h.check("save.taken_mid_mission", not saved.is_empty(),
		"%d unit(s) at the time, against the %d the .lev places"
			% [saved_units, squad.size() + 2])
	if saved.is_empty():
		return
	h.check("save.carries_inserted_units", saved_units > squad.size() + 2,
		"the roster grew before the save was taken")
	var restored: World = CacheFixture.load_mission(MISSION)["world"]
	h.equal("save.loads", restored.load_save(saved), SaveCodec.Result.OK)
	h.equal("save.round_trip_preserves_the_hash",
		restored.canonical_hash_hex(), saved_hash,
		"including both generators, the turn and the game-control slots")
	h.equal("save.round_trip_preserves_the_roster",
		restored.unit_slots().size(), saved_units)


static func _on_marker(world: World, squad: PackedInt32Array) -> bool:
	for slot: int in squad:
		var view: Dictionary = world.unit_view(slot)
		if Vector2i(DictRead.as_int(view["x"]),
				DictRead.as_int(view["y"])) == MARKER:
			return true
	return false


## A fill run **from** a target with more movement points than any map needs.
##
## The result's `mp_left` is a monotone proximity field over the component the
## target sits in, which is what turns "walk toward it" into something that
## survives a wall. A greedy walk on the Chebyshev distance instead stops
## against the wall across row 12 -- measured, on this map, before this was
## written.
##
## Built on **its own** [MapState] with an empty roster, not on the world's:
## `core` hands out no live [UnitState], and a test that reached in to move one
## would put a hole in exactly the isolation `test_isolation.gd` guards.
static func _potential(document: Dictionary, utab: UnitTypeTable,
		ctab: CtrlMapTable, type_id: int,
		target: Vector2i) -> PackedInt32Array:
	var state: MapState = MapState.from_resource(
		MapResource.from_document(document))
	for i: int in range(state.cell_count()):
		state.set_unit(i, MapState.NO_UNIT)
	var probe: UnitState = UnitState.new()
	probe.slot = 0
	probe.type_id = type_id
	probe.player = 0
	probe.x = target.x
	probe.y = target.y
	probe.hp = 1
	probe.fp = 255
	probe.mp = FLOOD_MP
	state.set_unit(state.index_of(target.x, target.y), 0)
	return MoveMap.build(state, {0: probe}, utab, ctab, 0, false, FLOOD_MP,
		FLOOD_MP).mp_left()


## One unit's move for one turn: the reachable cell with the highest potential.
static func _step(world: World, slot: int,
		potential: PackedInt32Array) -> bool:
	var view: Dictionary = world.unit_view(slot)
	if DictRead.as_int(view["hp"]) <= 0:
		return false
	var here: int = world.state.index_of(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(slot))
	var reach: PackedInt32Array = fill.mp_left()
	var best: int = here
	var best_potential: int = potential[here]
	for i: int in range(reach.size()):
		if reach[i] > 0 and potential[i] > best_potential \
				and world.state.unit_at(i) == MapState.NO_UNIT:
			best_potential = potential[i]
			best = i
	if best == here:
		return false
	var moved: MoveResult = world.submit_move(MoveCommand.create(slot,
		best % world.state.width, best / world.state.width))
	return moved.ok
