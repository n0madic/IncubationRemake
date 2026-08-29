class_name World
extends RefCounted

## The only simulation object `game` holds.
##
## `core` has no scene tree, no rendering, no audio, no filesystem and no engine
## singleton (docs/92 section 10.4).  It also never hands out a live reference:
## every view is a freshly built `Dictionary` of scalars, and every packed array
## that leaves is a `duplicate()`.  `godot/tests/test_isolation.gd` enforces
## both -- the first by mutating a snapshot and re-hashing, the second by
## reading every file under `core/` as text and failing on a forbidden symbol.

var resource: MapResource = null
var state: MapState = null
var rng: IncRandom = null
## The second generator. docs/20 section 7.4: `InsertUnit` draws from the C
## runtime's `rand()`, not from `aRandom`, so the two streams are separate and
## both are simulation state.
var crand: CRandom = CRandom.create()
var compat_flags: PackedStringArray = PackedStringArray()

var _units: Dictionary = {}
var _ctrlmap: CtrlMapTable = null
## Camera state carried by the last loaded save.  Deliberately outside the
## canonical hash -- where the player was looking is not simulation state.
var _camera: Dictionary = {}
var _unit_types: UnitTypeTable = null
var _weapons: WeaponTable = null
## docs/25 section 3 -- whose turn it is, and the counter. Outside [MapState]
## because it is not cell state; inside the canonical hash because it is
## simulation state, which docs/92 section 7.3 foresaw when it recorded that
## "campaign and turn phase have no representation yet".
var turn: TurnState = null
## docs/20 section 7 -- the twelve int32s the mission script writes and the
## hand-over reads to decide the mission is over.
var game_control: GameControl = null

## docs/23 section 5.3 -- what the move's caller writes into `unit[+0x39]`.
const ACTED_MOVED: int = 3

## The [MissionScript] seam. Assign a real runner and the hand-over and the
## walk start driving the mission program; leave it and they run
## [method MissionScript.no_op], which reports success and does nothing. The
## default is not "no script" as an error state -- a world with no program
## attached must let the turn proceed.
##
## **A runner that captures this world leaks it.** `World` holds the
## [Callable] and the lambda holds the `World`, which is a `RefCounted` cycle;
## Godot reports it only as "resources still in use at exit". Prefer a static
## function or a method on a separate object, and where a closure is genuinely
## wanted, put the default back when done.
var script_runner: Callable = Callable(MissionScript, "no_op")

## The mission program, or `null` when none is attached.
##
## **Data, with no reference back to this world.** The interpreter needs the
## world, and storing a runner that holds one would be a `RefCounted` cycle --
## the one Godot reports only as "resources still in use at exit". So the
## *program* is stored and the [Callable] that runs it is built per call, in
## [method _script_callable], and never kept.
var script_program: LclProgram = null

## `EnterNameOfNextMap` writes it and the campaign layer reads it. It starts as
## the authored header's value ([member MapResource.next_map]) -- a mission that
## never calls the command still names a successor.
var next_map: String = ""


static func create(map_document: Dictionary, balance: Dictionary,
		rng_seed: float = 0.0) -> World:
	var world: World = World.new()
	world.resource = MapResource.from_document(map_document)
	world.state = MapState.from_resource(world.resource)
	world._ctrlmap = CtrlMapTable.from_rows(DictRead.as_array(balance["ctrlmap"]))
	world._unit_types = UnitTypeTable.from_rows(DictRead.as_array(balance["units"]))
	# Required, not optional: an empty weapon table would silently disable the
	# refresh's cooling and its weapon-mode revert, which is the "a fallback
	# where an error belongs" shape this project keeps finding.
	world._weapons = WeaponTable.from_rows(DictRead.as_array(balance["weapons"]))
	world.turn = TurnState.create()
	world.game_control = GameControl.create()
	world.next_map = world.resource.next_map
	world.rng = IncRandom.new()
	# docs/92 section 10.3 item 2: seed explicitly even though the slice
	# consumes no draws, so the state shape later traces compare is established.
	world.rng.randomize_seed(rng_seed)

	var records: Array = DictRead.as_array(map_document["units"])
	for record: Variant in records:
		var view: Dictionary = record
		var unit: UnitState = UnitState.from_document(view)
		if not unit.is_placed():
			continue
		world._units[unit.slot] = unit
	return world


func ctrlmap() -> CtrlMapTable:
	return _ctrlmap


func unit_types() -> UnitTypeTable:
	return _unit_types


func weapons() -> WeaponTable:
	return _weapons


func unit_slots() -> PackedInt32Array:
	var slots: Array[int] = []
	for slot: Variant in _units:
		slots.append(DictRead.as_int(slot))
	slots.sort()
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(slots.size())
	for i: int in range(slots.size()):
		out[i] = slots[i]
	return out


func has_unit(slot: int) -> bool:
	return _units.has(slot)


## A fresh dictionary of scalars, never the [UnitState] itself.
func unit_view(slot: int) -> Dictionary:
	if not _units.has(slot):
		return {}
	var unit: UnitState = _units[slot]
	return unit.view()


func cell_view(x: int, y: int) -> Dictionary:
	if not state.in_bounds(x, y):
		return {}
	var index: int = state.index_of(x, y)
	return {
		"index": index,
		"x": x,
		"y": y,
		"height": state.height_at(index),
		"field_type": state.field_type_at(index),
		"field_type_name": _ctrlmap.type_name(state.field_type_at(index)),
		"action_point": state.action_point_at(index),
		"unit": state.unit_at(index),
		"obstacle": state.obstacle_at(index),
		"delay": _ctrlmap.delay(state.field_type_at(index)),
		"enterable": _ctrlmap.is_enterable(state.field_type_at(index)),
	}


## Copies of every mutable array, for rendering.  Mutating what comes back
## cannot reach the simulation.
func terrain_snapshot() -> Dictionary:
	return state.snapshot()


func submit_move_query(command: MoveQueryCommand) -> MoveMapResult:
	if not _units.has(command.unit_slot):
		# Sized, not empty: the result declares the map's dimensions, and a
		# caller that trusts them -- `game/highlight.gd` walks width x height --
		# would index past the end of a zero-length array for every cell.
		var overlay: PackedByteArray = PackedByteArray()
		overlay.resize(state.cell_count())
		var mp_left: PackedInt32Array = PackedInt32Array()
		mp_left.resize(state.cell_count())
		return MoveMapResult.create(state.width, state.height, 0,
			overlay, mp_left, false, 0)
	var unit: UnitState = _units[command.unit_slot]
	# docs/23:652 -- the fill spends the unit's current `+0x15`, and asks
	# `0x00475160` for the allowance the ladder step charges.  That allowance is
	# **computed** here rather than approximated by `mp_max`: the formula is in
	# [Allowance] and is pinned by 37 native calls into the live engine.
	return MoveMap.build(state, _units, _unit_types, _ctrlmap,
		command.unit_slot, command.pass_friendlies, unit.mp,
		movement_allowance(command.unit_slot))


## `aGetMovePoints` (`0x00475160`) for one slot -- docs/10 section 5.5.
func movement_allowance(slot: int,
		ai_level: int = Allowance.DEFAULT_AI_LEVEL) -> int:
	if not _units.has(slot):
		return 0
	var unit: UnitState = _units[slot]
	return Allowance.for_unit(unit, _unit_types, _units, ai_level)


## Walks a unit to `command`'s cell, and is the only thing that spends
## movement points.
##
## The three steps are the engine's, in its order (docs/23 section 5.3): fill,
## reconstruct, walk. A path that runs through another unit is **abandoned**
## rather than walked -- `blocked != 0` zeroes the step count in the original,
## and the caller moves nothing.
##
## The charge happens **here**, not in [ExecuteMove], because that is where the
## engine does it: `aExecuteMove` reports the cost through its fifth argument
## and leaves `u->mp` alone (docs/93 section 11, measured). The mine arm is the
## exception the engine itself makes -- it zeroes the movement points inside
## the routine and reports a cost of 0.
func submit_move(command: MoveCommand) -> MoveResult:
	if not _units.has(command.unit_slot):
		return MoveResult.failed(0, 0, "no such unit")
	var unit: UnitState = _units[command.unit_slot]
	var fill: MoveMapResult = submit_move_query(
		MoveQueryCommand.create(command.unit_slot))
	var walked: Dictionary = walk_path(fill, command.unit_slot, command.x,
		command.y)
	if not DictRead.as_bool(walked["ok"]):
		return MoveResult.failed(unit.x, unit.y,
			DictRead.as_string(walked["reason"]))
	if DictRead.as_int(walked["blocked"]) != 0:
		return MoveResult.failed(unit.x, unit.y, "the path runs through a unit")

	var moved: MoveResult = ExecuteMove.run(state, _ctrlmap, unit, walked)
	if moved.steps == 0:
		return moved
	state.set_unit(state.index_of(unit.x, unit.y), MapState.NO_UNIT)
	state.set_unit(state.index_of(moved.x, moved.y), unit.slot)
	unit.x = moved.x
	unit.y = moved.y
	unit.facing = moved.facing
	# `+0x50` is one byte and the engine adds into it, so it wraps rather than
	# saturating. Unreachable in practice -- the refresh zeroes it every turn
	# and 255 tenths is 25 fields of walking -- but masking is what the field
	# is, and picking a cap instead would be inventing a rule.
	unit.walked = (unit.walked + moved.walked) & 0xFF
	for write: Vector2i in moved.action_point_writes:
		# `x` is the cell index and `y` the action point it becomes; the pair
		# comes from [ExecuteMove] in that order.
		state.set_action_point(write.x, write.y)
	# docs/23 section 5.3's tail, in the caller: the native probe shows
	# `aExecuteMove` leaving `+0x39` alone, so this is the AI call site's own
	# assignment and the player's path is assumed to match it.
	# docs/20 section 5 -- the `MoveUnit` event, and it fires **before** the
	# charge because the engine fires it inside `aExecuteMove` itself
	# (`0x0046E220` is the call site the section lists) while the subtraction
	# is the caller's. A script that read the mover's movement points would see
	# them uncharged, and putting the seam after the charge would quietly
	# change that. Wired with the no-op runner now, so attaching the
	# interpreter later changes one assignment and not this function.
	#
	# `_D` is the cell's height field divided by 160, and the division is C's:
	# GDScript truncates toward zero on integers exactly as the original does,
	# so a cell below datum gives the same level in both.
	var arrived: int = state.index_of(moved.x, moved.y)
	moved.script_result = DictRead.as_dict(_script_callable().call(
		MissionScript.CALL_MOVE_UNIT,
		MissionScript.env(MissionScript.CALL_MOVE_UNIT, turn.turn,
			unit.player, moved.x, moved.y,
			state.height_at(arrived) / MissionScript.HEIGHT_LEVEL_UNITS,
			state.action_point_at(arrived), unit.slot)))

	unit.acted = ACTED_MOVED
	if moved.movement_zeroed:
		unit.mp = 0
	elif moved.cost > 0:
		unit.mp = 0 if moved.cost > unit.mp else unit.mp - moved.cost

	# docs/23 section 5.3's tail: `aExecuteFight` is called **after**
	# `aExecuteMove`, by the caller and never by the routine -- twice from the
	# AI and three times from `aUI.cpp`. So the drain lives here, where the
	# charge above already is, and not inside [TurnSequence] or [ExecuteMove].
	moved.reactions = Reaction.drain(state, _units, _unit_types, _weapons,
		unit, turn.ai_level, turn.human_count(), turn.mode, rng)
	return moved


## `aAttackUnit` (`0x0046B450`) -- docs/22 section 7.
##
## The command's cell is the aim point. Nothing here re-checks line of sight:
## the resolver does not, and adding a check would make a shot the engine
## allows impossible.
func submit_attack(command: AttackCommand) -> AttackResult:
	if not _units.has(command.unit_slot):
		var refused: AttackResult = AttackResult.new()
		refused.reason = "no such unit"
		return refused
	var unit: UnitState = _units[command.unit_slot]
	return Combat.attack(state, _units, _unit_types, _weapons, unit.x, unit.y,
		command.x, command.y, turn.ai_level, turn.human_count(), turn.mode,
		rng)


## `aExecuteUse` (`0x0046DC60`) -- docs/26.
##
## The one movement point the command pad charges is `0x004734C0`'s, not
## `aExecuteUse`'s, so it is spent here: the routine itself takes nothing.
## docs/26 section 1.1 also has the pad deselect a unit the use killed, which is
## presentation and stays in `game/`.
func submit_use(command: UseCommand) -> UseResult:
	if not _units.has(command.unit_slot):
		return UseResult.refused("no such unit")
	var unit: UnitState = _units[command.unit_slot]
	var result: UseResult = Interact.execute(state, _units, _unit_types,
		_weapons, game_control, unit, turn.ai_level, turn.human_count(),
		turn.mode, rng)
	if unit.hp != 0 and unit.mp != 0:
		unit.mp -= 1
	return result


## `0x00478500` behind `0x004753E0`'s gate -- the **Def** button.
##
## Returns the ticket, or 0 when the gate refused. The gate is the UI one and
## not the AI's automatic pass: this is a player pressing a button, and the two
## disagree on `def_mode` 4 (docs/21 section 4).
func submit_defend(command: DefendCommand) -> int:
	if not _units.has(command.unit_slot):
		return 0
	var unit: UnitState = _units[command.unit_slot]
	if not Reaction.may_enter_defence(_weapons, unit):
		return 0
	return Reaction.enter_defence(turn, unit)


## Attach a mission program, from `missions/<name>/script.json`.
##
## Passing an empty document detaches: [member script_runner] takes over again,
## and its default lets every hand-over proceed. "No program" and "a program
## that refused" are different answers, and only the second stops anything.
func attach_script(document: Dictionary) -> bool:
	script_program = LclProgram.from_document(document)
	if script_program.is_empty():
		script_program = null
		return false
	return true


## The runner for this world, built fresh and never stored.
func _script_callable() -> Callable:
	if script_program == null:
		return script_runner
	return Callable(self, "_run_mission_script")


## One invocation of the attached program -- the seam's own shape.
##
## `player` is the host's argument for this call and not always
## [member TurnState.current_player]: `NEXT PLAYER` names the player whose turn
## is *starting*, which the hand-over has already advanced to.
func _run_mission_script(call_type: int,
		environment: Dictionary) -> Dictionary:
	var context: LclContext = LclContext.create(state, _units, _unit_types,
		turn, game_control, rng, crand, turn.current_player, next_map)
	var outcome: LclOutcome = LclInterpreter.run(script_program, context,
		MissionScript.to_slots(environment))
	next_map = context.next_map
	var result: Dictionary = outcome.to_dict()
	result["ok"] = outcome.ok()
	result["ran"] = true
	result["call_type"] = call_type
	result["env"] = environment.duplicate()
	return result


## `0x00477BF0` -- how many live units a player owns.
func live_unit_count(player: int) -> int:
	var n: int = 0
	for slot: Variant in _units:
		var unit: UnitState = _units[slot]
		if unit.player == player and unit.hp > 0:
			n += 1
	return n


## `0x0046FAD0` -- whether this unit is in range of a Banner.
func banner_in_range(slot: int) -> bool:
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	return Allowance.banner_in_range(unit, _units)


## `0x0047D600` -- end the current player's turn and hand over.
##
## The mission script runs from inside this, twice, and a refusal from either
## stops the hand-over: that is the engine's own `if (!runProgram()) return 0;`
## and it is why [member script_runner] defaults to something that says yes.
##
## **The computer's turn is a turn.** When the rotation yields 255 the result
## says so and the refresh has already run for it; a caller that treated it as
## nothing to do and handed over again immediately would run `NEXT PLAYER`
## twice per round, and on `_C_140` that is the script's reinforcement roll
## firing twice as often as the mission intends.
func submit_end_turn(command: EndTurnCommand) -> TurnResult:
	var result: TurnResult = TurnSequence.hand_over(turn, _units, game_control,
		_unit_types, _weapons, _script_callable(), banner_in_range,
		live_unit_count, command.arg)
	if result.refreshed:
		# `aBuildVisibleMap` for whoever now holds the turn. It runs here and
		# not in [Refresh] for the reason that file states: visibility is a map
		# walk and the refresh is a unit walk. It runs only when the refresh
		# did, so a hand-over the script stopped leaves the fog alone -- the
		# same player is still looking at the same world.
		Visibility.build(state, _units, _unit_types, turn.current_player,
			turn.human_count(), turn.mode)
		result.fog_rebuilt = true
	return result


## `aWalkMoveMap` (`0x004305E0`) over a move map this world produced.
##
## The result is a value, not a change: `core` owns no overlay, and the
## engine's own path marks live in the cells it sweeps afterwards.
func walk_path(result: MoveMapResult, slot: int, tx: int,
		ty: int) -> Dictionary:
	if not _units.has(slot):
		return {"ok": false, "steps": 0, "blocked": 0,
			"path": PackedInt32Array(), "state": PackedByteArray(),
			"reason": "no such unit"}
	var unit: UnitState = _units[slot]
	return WalkMap.path(state, _units, _ctrlmap, result, unit.x, unit.y,
		tx, ty)


func canonical_hash() -> PackedByteArray:
	return CanonicalHash.compute(state, _units, turn, game_control, rng,
		crand, compat_flags)


func canonical_hash_hex() -> String:
	return CanonicalHash.to_hex(canonical_hash())


func save(camera: Dictionary) -> PackedByteArray:
	return SaveCodec.encode(resource, state, _units, turn, game_control, rng,
		crand,
		compat_flags, camera)


## Returns the [enum SaveCodec.Result] code; the world is only changed on `OK`.
##
## The camera is stored beside the simulation and **excluded** from the
## canonical hash, so it comes back through [method restored_camera] rather
## than being applied here: `core` owns no camera, and `game` is what puts it
## back.  Discarding it entirely, which this used to do, made the field a
## write-only decoration.
func load_save(data: PackedByteArray) -> int:
	var decoded: Dictionary = SaveCodec.decode(data, resource)
	var code: int = DictRead.as_int(decoded["result"])
	if code != SaveCodec.Result.OK:
		return code
	state = decoded["state"]
	_units = decoded["units"]
	turn = decoded["turn"]
	game_control = decoded["game_control"]
	rng = decoded["rng"]
	crand = decoded["crand"]
	compat_flags = decoded["compat_flags"]
	_camera = DictRead.as_dict(decoded["camera"])
	return code


## The camera state the last successful [method load_save] read, or an empty
## dictionary when nothing has been loaded.
func restored_camera() -> Dictionary:
	return _camera.duplicate(true)
