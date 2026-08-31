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

## How many times one [method submit_end_turn] will hand the computer the turn
## before it stops. The rotation can hand player 255 the turn twice running when
## no human slot qualifies, and a mission whose script never ends would
## otherwise loop for ever; four is well past anything the corpus produces
## (every mission hands over to a human on the first pass) and short enough
## that the stop is a result rather than a hang.
##
## It counts **hand-overs to the computer**, not planner runs: at turn zero the
## computer is handed the turn and does not act (see [method submit_end_turn]).
const AI_TURNS_PER_HAND_OVER: int = 4

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
## [member UseResult.kind] for the one interaction whose animation rebuilds
## the fog -- see [method submit_use].
const DOOR_USE_KIND: String = "door"
## The event [LclInterpreter] emits where the engine calls `aBuildVisibleMap`.
const SCRIPT_FOG_EVENT: String = "build_visible_map"
## The `Elevator` command's event. `aPlayElevatorSequence` ends with a
## permanent rebuild for the **rider's** own player -- see [method run_script].
const ELEVATOR_EVENT: String = "elevator"

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

## `0x004FAE40`, through its setter `0x0040B360` and getter `0x0040B370` --
## "the computer may fire". An engine **debug** global: `aMain` reaches the
## whole AI module exactly once and that call is this setter, and no product
## option is wired to it (docs/23 section 1). It is 1 in every shipped run.
##
## It is exposed here because it is the one switch that separates "the
## opponent moves" from "the opponent kills", which is what a test needs to
## show the mission is still completable through the whole stack while a
## second run shows what the live opponent does to a squad.
var ai_may_fire: bool = true

## `EnterNameOfNextMap` writes it and the campaign layer reads it. It starts as
## the authored header's value ([member MapResource.next_map]) -- a mission that
## never calls the command still names a successor.
var next_map: String = ""

## `0x005229D0` -- the latch `aNextPlayerHandling` sets on its first run.
##
## **The engine saves it.** `aSaveViewPlayer` (`0x0047DBE0`) and
## `aLoadViewPlayer` (`0x0047DC20`) transfer `0x44C` bytes starting at this
## address, so a save taken after the first hand-over comes back with the
## one-shot already spent -- which matters, because otherwise the reset inside
## it would clear the loaded hero counters. This remake's save block is its
## own and does not carry the byte; [method load_save] derives it instead,
## from the one thing that says the same: a loaded turn counter above zero can
## only have come from a hand-over that has already run.
var _hand_over_initialised: bool = false


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


## `aNextPlayerHandling`'s one-shot -- `0x0047DCA7`..`0x0047DCD4`.
##
## The first time the rotation runs, and only then:
##
## [codeblock]
## if (g_5229D0 == 0) {                       /* 0x0047DCAC */
##     g_5229D0 = 1;
##     resetPlayerRecords();                  /* 0x0043B770 */
##     if (gameMode() == 1)                   /* 0x0043B740, campaign */
##         aBuildVisibleMap(0);               /* 0x0047DCCF */
## }
## [/codeblock]
##
## `0x0043B770` walks the four player records with its pointer at `record + 8`
## -- it starts at `0x00509F50` and its first store is `[eax-8]` -- so its six
## stores land on `+0x00`, `+0x08`, `+0x10`, `+0x18` (zero), `+0x20` (1) and
## `+0x24` (a byte, zero). The last of those is the hero counter, so this
## clears [member TurnState.hero_killed]; the other five are fields this
## remake does not carry. It also zeroes the turn counter and game-control
## slots 10 and 11, which [method create] already leaves that way.
##
## The rebuild is **not** the hand-over's own: that one runs later, for
## whoever the rotation picked and only when the refresh ran. This one is
## unconditional, for player 0, and it is the reason a campaign's first turn
## starts on a fog pass rather than on the `+0x4F` bytes the `.lev` authored.
func _first_hand_over() -> void:
	if _hand_over_initialised:
		return
	_hand_over_initialised = true
	turn.hero_killed = PackedInt32Array([0, 0, 0, 0])
	if turn.mode != TurnState.MODE_CAMPAIGN:
		return
	Visibility.build(state, _units, _unit_types, 0, turn.human_count(),
		turn.mode)


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


## The unit dictionary, for the one consumer that needs the objects rather
## than views: [AIContext], which is `core` and mutates them by design.
##
## Not a leak of the isolation rule -- `core/ai/` is inside `core` and
## `tests/test_isolation.gd` sweeps it with everything else. It is named
## `_for_ai` so a `game` file reaching for it reads as obviously wrong.
func units_for_ai() -> Dictionary:
	return _units


## Write a case record over one unit, field by field.
##
## The one writer of unit state that is not a command, and it exists for the
## case suites: `test_ai.gd` applies a roster the Python model produced so the
## two implementations start from bit-identical state rather than from two
## loaders that happen to agree. Absent keys are left alone, so a case can name
## only what it is about.
func apply_unit_record(slot: int, record: Dictionary) -> bool:
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	var was: int = state.index_of(unit.x, unit.y)
	unit.apply_record(record)
	if state.unit_at(was) == slot and was != state.index_of(unit.x, unit.y):
		state.set_unit(was, MapState.NO_UNIT)
	if unit.hp > 0:
		state.set_unit(state.index_of(unit.x, unit.y), slot)
	return true


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
		unit, turn.ai_level, turn.human_count(), turn.mode, turn, rng)
	return moved


## `aAttackUnit` (`0x0046B450`) -- docs/22 section 7.
##
## The command's cell is the aim point. Nothing here re-checks line of sight:
## the resolver does not, and adding a check would make a shot the engine
## allows impossible.
##
## **The charge, the *acted* flag and the reaction drain are the call site's,
## and they were missing.** `aUI.cpp:3516` (`0x004731E4`) does, after the
## resolver returns and only while the shooter is still alive: subtract the
## weapon's AP with a clamp at zero, write 3 into `+0x39`, and call
## `aExecuteFight`. `0x0040A440` -- the computer's fire routine -- does the
## same three things, which is what makes them the call site's rather than the
## resolver's. Slice 2 left all three out and nothing noticed, because a
## player who could fire for free was still playing against an opponent that
## never moved.
func submit_attack(command: AttackCommand) -> AttackResult:
	if not _units.has(command.unit_slot):
		var refused: AttackResult = AttackResult.new()
		refused.reason = "no such unit"
		return refused
	var unit: UnitState = _units[command.unit_slot]
	var shot: AttackResult = Combat.attack(state, _units, _unit_types,
		_weapons, unit.x, unit.y, command.x, command.y, turn.ai_level,
		turn.human_count(), turn.mode, turn, rng)
	if unit.hp == 0:
		return shot
	var ap: int = _weapons.ap(unit.weapon)
	unit.mp = unit.mp - ap if unit.mp > ap else 0
	unit.acted = ACTED_MOVED
	shot.reactions = Reaction.drain(state, _units, _unit_types, _weapons,
		unit, turn.ai_level, turn.human_count(), turn.mode, turn, rng)
	return shot


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
	# **The gate comes first, and the charge is unconditional after it.**
	# docs/26 section 1.1 quotes the pad's arm: it calls `aExecuteUse` and then
	# spends the point whatever came back -- but `0x00472570` never offers
	# command 8 unless `may_use` accepted, so the two together mean "a use that
	# was not offered costs nothing". Charging on the result instead let a unit
	# at the map edge, facing outward, lose a point per press.
	if not Interact.may_use(state, _units, _unit_types, unit):
		return UseResult.refused("there is nothing to use in front of it")
	var result: UseResult = Interact.execute(state, _units, _unit_types,
		_weapons, game_control, unit, turn.ai_level, turn.human_count(),
		turn.mode, turn, rng)
	# **A door that opens changes what the rules see, and the rebuild is not
	# `aExecuteUse`'s.** It belongs to `aDoorOpenSequence` (`0x00410A20`), the
	# animation the use path drives, which calls `aBuildVisibleMap` twice --
	# `0x00410C6A` on the arm that opens the panel and `0x00410D60` on the one
	# that closes it -- for `aGetCurrentPlayer`, and **not** inside the
	# save/restore bracket that makes docs/22 section 9.4's per-command pass a
	# probe. So this is permanent, and it is here rather than in [Interact]
	# because `interact_runtime`'s native capture replays `aExecuteUse` alone
	# and would disagree with a model that folded the animation into it.
	#
	# Both sites are guarded by `aGetCurrentPlayer() != 0xFF`: a door the
	# computer opens leaves the fog alone until the hand-over.
	if result.kind == DOOR_USE_KIND \
			and turn.current_player != UnitState.PLAYER_ALIEN:
		Visibility.build(state, _units, _unit_types, turn.current_player,
			turn.human_count(), turn.mode)
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
	# **The script's own fog rebuilds, which the interpreter records and does
	# not perform.** `InsertUnit` (`0x004419B6`) and the `BuildVisibleMap`
	# command both call `aBuildVisibleMap` for good, so the events they emit
	# are acted on here -- outside [LclInterpreter], which owns no fog, and
	# outside [LclContext], whose whole point is that the language reaches four
	# cell fields and not the map's derived state. The events themselves are
	# unchanged, so `lcl_runtime.py`'s comparison still sees the same list.
	#
	# **The elevator is a third, and it rebuilds for somebody else.**
	# `aPlayElevatorSequence` (`0x004125D0`) reads the unit index out of the
	# elevator's own ctrl-map cell, takes that unit's `+0x45`, and calls
	# `aBuildVisibleMap` with it at `0x00412905` -- the **rider's** player, not
	# the current one, and skipped entirely when the tile is empty
	# (`cell[+0x07] == 0xFFFF`). The rider is read back off the cell here
	# rather than carried in the event, because the command changes the cell's
	# height and never moves the unit, so the occupant after is the occupant
	# before -- and the event payload stays byte-identical to the one
	# `lcl_runtime.py` emits.
	for event: Dictionary in outcome.events:
		var name: String = DictRead.as_string(event["name"])
		var values: PackedInt32Array = DictRead.as_int32_array(event["values"])
		if name == SCRIPT_FOG_EVENT:
			if values.is_empty():
				continue
			Visibility.build(state, _units, _unit_types, values[0],
				turn.human_count(), turn.mode)
		elif name == ELEVATOR_EVENT:
			if values.size() < 2 or not state.in_bounds(values[0], values[1]):
				continue
			var rider: int = state.unit_at(state.index_of(values[0], values[1]))
			if rider < 0 or not _units.has(rider):
				continue
			var on_it: UnitState = _units[rider]
			Visibility.build(state, _units, _unit_types, on_it.player,
				turn.human_count(), turn.mode)
	var result: Dictionary = outcome.to_dict()
	result["ok"] = outcome.ok()
	result["ran"] = true
	result["call_type"] = call_type
	result["env"] = environment.duplicate()
	return result


## The `INIT MAP` entry point -- docs/20 section 5.
##
## The loader runs it once, before any turn, and it is what names the successor
## map and starts the music. Separate from the hand-over because it is not part
## of one: no turn has begun when it runs.
func run_init_map() -> Dictionary:
	return run_script(MissionScript.CALL_INIT_MAP,
		MissionScript.env(MissionScript.CALL_INIT_MAP))


## One invocation of the attached program, through the seam.
##
## The hand-over and the walk call this for themselves; it is public because
## `INIT MAP` has no other caller and because a measurement of what a script
## costs should not have to reach past the seam to take it.
func run_script(call_type: int, environment: Dictionary) -> Dictionary:
	return DictRead.as_dict(_script_callable().call(call_type, environment))


## `0x00478570` -- spend the rest of this unit's turn, deliberately.
##
## Returns whether anything happened. docs/25 section 8: the state is 7 and the
## movement points go to zero, and the *reward* arrives at the next hand-over --
## [Refresh] turns state 7 into `rested = 1`, which docs/10 section 5.5's
## allowance formula reads as one extra point while fitness is above 1.
func submit_stand_down(command: StandDownCommand) -> bool:
	if not _units.has(command.unit_slot):
		return false
	var unit: UnitState = _units[command.unit_slot]
	if not unit.is_alive():
		return false
	unit.action_state = Refresh.ACTION_STOOD_DOWN
	unit.mp = 0
	return true


## `0x004785B0` -- spend a stimulant, once a turn.
##
## Returns whether it was spent. The movement points go up by the **old** value,
## which is what makes a *Heavy Stimulant* worth two, and `+0x58` becomes 255 --
## "spent this turn", which the refresh turns back into the charge. Nothing is
## consumed; a unit that decremented the field would have one per mission.
func submit_stimulant(command: SpendStimulantCommand) -> bool:
	if not _units.has(command.unit_slot):
		return false
	var unit: UnitState = _units[command.unit_slot]
	if not unit.is_alive():
		return false
	if unit.stimulant == 0 or unit.stimulant == Refresh.STIMULANT_SPENT:
		return false
	unit.mp += unit.stimulant
	unit.stimulant = Refresh.STIMULANT_SPENT
	return true


## `0x00477BF0` -- how many live units a player owns.
func live_unit_count(player: int) -> int:
	var n: int = 0
	for slot: Variant in _units:
		var unit: UnitState = _units[slot]
		if unit.player == player and unit.hp > 0:
			n += 1
	return n


## `0x00477DF0`'s three tests -- whether the player holding the turn may give
## this slot an order.
##
## Alive, `+0x45` equal to `aGetCurrentPlayer`, and `+0x4F` not hidden. That
## routine is what `0x00453CF0` -- the game's own "cycle the selected friendly
## unit", docs/29's command 14 -- walks the 200 slots with, so it is the
## engine's own notion of a unit you can command.
##
## In `core` rather than in `game` because it is a rule about the simulation
## and not about the mouse: a demo run, a click and a test all have to agree
## on it. `game` used to select whatever was under the cursor and consult the
## owner only to choose between attacking and selecting -- which was invisible
## while the aliens never acted, and let a player take the computer's turn for
## it once they did.
## The fourth test is not one of `0x00477DF0`'s and is added here on purpose:
## **a finished mission is not playable**. The engine has no state in which the
## map is still up after the game-control slots have ended it -- the hand-over
## stops and `aMissionEnd.cpp`'s debriefing screen replaces the map (docs/27
## section 6.1) -- so there is nothing for it to test. The remake leaves the map
## on screen behind the result panel, which would otherwise let a player keep
## giving orders after they had lost.
func may_command(slot: int) -> bool:
	if game_control.mission_ended():
		return false
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	if unit.hp == 0:
		return false
	if unit.player != turn.current_player:
		return false
	return unit.visibility != UnitState.VISIBILITY_HIDDEN


## `aGetHitProbability` (`0x0046A270`) for one shooter and one target.
##
## A scalar, not a [HitChance]: `core` hands out values and this is the one the
## interface needs -- docs/29 section 1.1's target cursor and the AI's own
## band both read exactly this number. Zero means "out of range, blocked, or
## no such unit", which are the three the caller treats alike.
func hit_chance(shooter_slot: int, target_slot: int) -> int:
	if not _units.has(shooter_slot) or not _units.has(target_slot):
		return 0
	var shooter: UnitState = _units[shooter_slot]
	var target: UnitState = _units[target_slot]
	var weapon: int = AIOverlay.effective_weapon(_weapons, shooter)
	if weapon < 0:
		return 0
	var chance: HitChance = HitChance.compute(state, _units, _unit_types,
		_weapons, shooter, target, weapon, true, turn.human_count(),
		turn.mode)
	return chance.percent if chance.in_range else 0


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
	_first_hand_over()
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

	# **The computer's turn is played here, and handed back through the same
	# seam it arrived by.** docs/25 section 4 puts `aAISystemControl` at the end
	# of the hand-over, after the refresh and the fog, and docs/23 section 2 is
	# what it runs. When it is done the hand-over runs *again*, which is the
	# engine's own and not a second one: the rotation moves on to whoever is
	# next, exactly as it would after a human player pressed the button.
	#
	# **It is a loop and not recursion, and the two AI turns are merged.**
	# `0x0043B320` re-selects player 255 when no human slot qualifies
	# (`Rotation.advance_player`, the arm that leaves `current_player` alone
	# and answers true), so the computer can be handed the turn twice running
	# -- every human out, and a mission script that has not ended the mission.
	# The old shape recursed into itself there and overwrote the first turn's
	# [member TurnResult.ai_result] with the second's, so the events of the
	# earlier turn were never played back; and nothing bounded the depth, so
	# a mission that never ends would exhaust the stack rather than stop.
	#
	# **The condition is the engine's own, and it is not
	# [member TurnResult.ai_turn].** docs/25 section 4.1 gives
	# `aNextPlayerHandling`'s body as
	# `do { ... } while (g_currentPlayer == 255 && result == 1)` -- the
	# *player*, and the code equal to `1` rather than merely not zero. Looping
	# on `ai_turn` instead let one case out: at turn zero `ai_turn` is false
	# while the computer holds the turn (`0x0047D600` runs the planner only
	# `if (g_turn != 0)`), so the first press of "end turn" returned to the
	# interface with player 255 holding it. The engine cannot do that -- its
	# loop is what "lets the computer take its turn without returning to the
	# interface" -- and in this remake it meant the player could select and
	# command the aliens, with nothing on screen to say whose turn it was.
	var played: AITurnResult = null
	var turns: int = 0
	while turn.current_player == TurnState.PLAYER_COMPUTER \
			and result.code == TurnResult.OK:
		_first_hand_over()
		turns += 1
		if turns > AI_TURNS_PER_HAND_OVER:
			result.code = TurnResult.STOPPED
			if played != null:
				played.ok = false
				played.reason = ("the rotation handed the computer "
					+ str(turns) + " turns without reaching a human player")
			break
		# **The AI runs only when the hand-over said so; the loop turns
		# either way.** `0x0047D600` sets the view state and calls
		# `aAISystemControl` under `if (g_turn != 0)`, so at turn zero the
		# computer is handed the turn and does nothing with it -- and it is
		# `aNextPlayerHandling`'s loop, not the planner, that carries the
		# rotation past it.
		if result.ai_turn:
			var ctx: AIContext = AIContext.create(state, _units, _unit_types,
				_weapons, _ctrlmap, turn, rng)
			ctx.may_fire = ai_may_fire
			var one: AITurnResult = AISystem.run(ctx, turn.current_player)
			played = one if played == null else played.followed_by(one)
		result = TurnSequence.hand_over(turn, _units, game_control,
			_unit_types, _weapons, _script_callable(), banner_in_range,
			live_unit_count, EndTurnCommand.create().arg)
		if result.refreshed:
			Visibility.build(state, _units, _unit_types, turn.current_player,
				turn.human_count(), turn.mode)
			result.fog_rebuilt = true
	result.ai_result = played
	return result


## What the player would see if the fog were rebuilt now -- slot to `+0x4F`.
##
## A **query**: it leaves every `+0x4F` exactly as it found it, so nothing here
## reaches the canonical hash, the AI or the rules. It is the engine's own
## split: `0x00481F00` rebuilds the fog before every player command and then
## restores it, and the restore covers the unit byte but not the 3D object's
## draw flag, so what is *drawn* follows the command and what is *decided*
## follows the last hand-over. [method Visibility.states_for] carries the
## addresses.
func display_visibility() -> Dictionary[int, int]:
	return Visibility.states_for(state, _units, _unit_types,
		turn.current_player, turn.human_count(), turn.mode)


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
	# See [member _hand_over_initialised]: the engine restores the latch from
	# the save, and a non-zero turn counter is what a spent one implies.
	_hand_over_initialised = turn.turn != 0
	# `aLoad.cpp:1649` (`0x004490A9`) -- the load ends with a permanent
	# `aBuildVisibleMap(aGetCurrentPlayer())`, after the mission objectives are
	# read back. The stored `+0x4F` bytes are therefore not what the loaded
	# mission plays with: the pass is re-run over the restored roster. docs/22
	# section 9.4.
	Visibility.build(state, _units, _unit_types, turn.current_player,
		turn.human_count(), turn.mode)
	return code


## The camera state the last successful [method load_save] read, or an empty
## dictionary when nothing has been loaded.
func restored_camera() -> Dictionary:
	return _camera.duplicate(true)
