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

## docs/21 section 5's species 2, `Info.lcl`'s *inanimate object* -- the one
## owner test [method load_sweep] forgives.
const SPECIES_INANIMATE: int = 2

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
## The scenery's pose record carried by the last loaded save -- the joint
## words and the freed cells of docs/42 section 8.3. Outside the canonical
## hash for the camera's reason: `core` owns no picture, and `game` is what
## puts it back ([method Scenery.restore_poses]).
var _scenery: Dictionary = {}
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

## `0x00479330` -- the three unit types `aChangeUnitViewDirection` will not
## turn.
const ROTATE_REFUSED_TYPE_LOW: int = 61
const ROTATE_REFUSED_TYPE_HIGH: int = 63
## docs/21 section 5 -- the species column's machines, which the pad offers
## neither *Rest* nor *Use* (`0x00472658`, `0x00472697`).
const SPECIES_MACHINE: int = 3
## docs/23 section 5.3 -- what the move's caller writes into `unit[+0x39]`.
const ACTED_MOVED: int = 3
## `0x0047304A` -- what the pad's warp arm writes there after a jump.
const ACTED_WARPED: int = 5
## docs/92 section 7.5.5, revised 2026-09-03 (docs/97 section 34): the
## engine's per-command fog probe **wakes** the groups it sees, because its
## save and restore cover `+0x4F` and not the orders `alert_group` promotes.
## That is reproduced by default; this flag restores the quiet probe this
## remake used to have.
const COMPAT_FOG_PROBE_QUIET: String = "fog_probe_does_not_wake_groups"
## [member UseResult.kind] for the one interaction whose animation rebuilds
## the fog -- see [method submit_use].
const DOOR_USE_KIND: String = "door"
## The event [LclInterpreter] emits where the engine calls `aBuildVisibleMap`.
const SCRIPT_FOG_EVENT: String = "build_visible_map"
## The `Elevator` command's event. `aPlayElevatorSequence` ends with a
## permanent rebuild for the **rider's** own player -- see [method run_script].
const ELEVATOR_EVENT: String = "elevator"
## The `Platform` command's event. `aPlayPlatformSequence` ends with a
## permanent rebuild for the **selected** unit's player (`0x004130E6`, docs/22
## section 9.4) and skips it when nothing is selected -- see [method run_script].
const PLATFORM_EVENT: String = "platform"
## The LCL `?_` command (docs/20 section 8): dword 10 of `Game.opt`, which
## `0x004604A0` returns and the death creators branch on (docs/42 section
## 4.8.1). Both interpreters record it as `unit_draw_path`.
const GORE_EVENT: String = "unit_draw_path"
## docs/42 section 4.8.1 -- the gore level: 1 every death is the puff, 2 the
## computer's units bleed, 3 everything bleeds. **The default is the
## remake's**: 2 is what the game copy's `Game.opt` holds, and no shipped file
## sets the option -- not one of the 92 campaign missions writes
## [constant GORE_EVENT], which is what makes the shell's own gore control a
## live one rather than a default some mission overrides (docs/92 section
## 7.14). [method GameSettings.apply_world] writes it as the world is built.
const GORE_DEFAULT: int = 2

## The slot the interface has selected, or [constant MapState.NO_UNIT] --
## `0x005162F8`, read by `0x00471F70`. The presentation writes it; `core` reads
## it in exactly one place, the platform's closing rebuild, which is the one
## rule that keys on the selection rather than on the turn.
var selected_slot: int = MapState.NO_UNIT
## `Game.opt` dword 10 -- see [constant GORE_EVENT]. Presentation reads it;
## no rule does, so it is outside the canonical hash and the save.
var gore_level: int = GORE_DEFAULT

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

## The level tester's switches, never `null`. See [Cheats] for why they are
## outside the canonical hash and outside the save, and for what a shield does
## and does not cover. A world nobody set them on behaves exactly as it did
## before they existed: every rule that reads them is behind
## [method Cheats.controlled], and every one of the seams that carries them
## takes `null` by default.
var cheats: Cheats = Cheats.new()

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

## The picture's record of what each command changed, or `null`.
##
## Off by default: a world with no journal costs one boolean test per
## [MapState] setter, so the case suites that replay whole missions through
## [method submit_end_turn] are unaffected. `game` turns it on when the
## mission is built ([method enable_journal]) and reads it with
## [method take_events]. [EventJournal] explains what a delta is and why the
## boundaries sit where they do.
var _journal: EventJournal = null


## `special_models` is the placer model names the mission's **world set**
## carries, out of the geometry cache: leaving it empty skips the gate, which
## is right for a synthetic map and wrong for a real one -- only `World_D00`
## has `GLOW1/2`, so a `SetGroundFire` elsewhere writes nothing (docs/42
## section 9.1).
static func create(map_document: Dictionary, balance: Dictionary,
		rng_seed: float = 0.0,
		special_models: PackedStringArray = PackedStringArray()) -> World:
	var world: World = World.new()
	world.resource = MapResource.from_document(map_document)
	world.state = MapState.from_resource(world.resource)
	world.state.set_special_models(special_models)
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


## `0x004783D0` -- the post-load sweep, run by `aLoadBattleMap`'s own caller at
## `0x00417D18` before anything else touches the map.
##
## **Not part of [method create]**, for the same reason it is not part of
## `aLoadBattleMap`: it is a separate routine the loader's caller runs, and it
## reads *session* state -- who is playing -- rather than the map. `game`'s
## mission entry calls it; a save's restore does not, because `load_save`
## replaces the whole unit array afterwards, and a hand-built world calls it
## only when it means to be a freshly loaded battle map.
##
## It walks all 200 unit slots and does one of two things to every live record:
## takes it off the map, or hands it to the **full** derived-stat recompute
## `0x004759E0` ([method Refresh.recompute_full]). So a `.lev`'s own `+0x3D`,
## `+0x16`, `+0x15`, `+0x19`, `+0x36`/`+0x37`, `+0x3A` and `+0x58` are
## authored values that the engine overwrites before the first turn, and the
## shipped bytes are whatever the editor last saved. Measured over the 155
## shipped missions: of 1826 placed units 45 carry an ammunition byte that is
## not their weapon's magazine and 58 carry hit points below their ceiling.
##
## The branch, in the engine's order:
##
## [codeblock]
## if (rec[+0x16] == 0)            continue;         /* free slot */
## if (playerKind(rec.player) == 0) {                /* 0x0043B6E0 */
##     if (rec.player == 255)      goto alien;
##     if (species(rec.type) == 2) goto keep;        /* a barrel outlives its owner */
##     aUI_KillUnit(rec.x, rec.y); continue;
## }
## keep:
## if (rec.player != 255)          { recompute(rec); continue; }
## alien:
## if (humanCount() <= 1)          { recompute(rec); continue; }   /* 0x0043B700 */
## if (isNetworkSession())         { recompute(rec); continue; }   /* 0x0043B1F0 */
## aUI_KillUnit(rec.x, rec.y);
## [/codeblock]
##
## `playerKind` is the dword array at `0x00509E20`, indexed 0..3 and answering
## 0 for anything else -- which is why players 252 (the scenery owner of 181
## shipped barrels and cases) and 255 both take the out-of-session arm, and why
## the species exception exists at all. The alien arm removes the aliens from a
## local game with more than one human; a campaign has exactly one, so it
## recomputes.
##
## Answers how many records it took off the map.
func load_sweep() -> int:
	var removed: int = 0
	var humans: int = turn.human_count()
	for slot: int in unit_slots():
		var unit: UnitState = _units[slot]
		if not unit.is_placed():
			continue
		var in_session: bool = _player_kind_of(unit.player) != 0
		var alien: bool = unit.player == UnitState.PLAYER_ALIEN
		if not in_session and not alien \
				and _unit_types.species(unit.type_id) != SPECIES_INANIMATE:
			var _hero: bool = UnitState.take_off_map(state, turn, unit)
			removed += 1
			continue
		# `0x0043B1F0` is the network gate, and this remake has no network
		# session (docs/92 section 7.9), so the alien arm turns on the human
		# count alone.
		if alien and humans > 1:
			var _hero: bool = UnitState.take_off_map(state, turn, unit)
			removed += 1
			continue
		Refresh.recompute_full(unit, _unit_types, _weapons, _units,
			turn.ai_level)
	return removed


## `0x0043B6E0` -- `playerKind[player]`, and 0 for an index outside 0..3.
func _player_kind_of(player: int) -> int:
	if player < 0 or player >= turn.player_kind.size():
		return 0
	return turn.player_kind[player]


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


## The hand-over a map load makes before anything is played -- the first call
## of `aNextPlayerHandling`, which takes the `handOver(1)` arm because the
## re-entry latch is still clear (docs/25 section 4.1).
##
## It raises **no** script: it searches the rotation from slot 0, refreshes
## whoever it finds, and through [method _first_hand_over] clears the hero
## counters and rebuilds the fog for player 0. Nothing in the remake called it
## until the turn-0 opening was found -- [member _hand_over_initialised] was
## reached lazily by the player's first *end turn* instead, so a mission
## opened on the `+0x4F` bytes the `.lev` authored.
##
## It leaves the counter where it was, which is what makes the *deployment*
## the thing that starts a mission: see [method skip_deployment_turn] for the
## other opening and [method submit_end_turn] for what leaving the deployment
## screen then does.
func open_mission() -> TurnResult:
	return submit_end_turn(EndTurnCommand.create(true))


## `aInitBattleGround` `0x0041A073` -- a campaign mission with nobody in the
## pool to place opens on turn **1** outright, with no hand-over and no script
## run at all:
##
## [codeblock]
## if (poolCount(currentPlayer) == 0 && turnCounter() == 0 && gameMode() == 1)
##     setTurn(1);                                /* 0x0043B290 */
## [/codeblock]
##
## That is the whole of the asymmetry between the two openings, and it is
## forced by the call graph rather than assumed: `setTurn` has exactly two
## callers in the image -- this one and the `local session` arm of
## `0x0041C010` -- and `advanceTurn` `0x0043B2A0` exactly two -- the hand-over
## and mode 2's own frame handler. So a campaign mission the player deploys
## into can only leave turn 0 through the hand-over, which raises `NEXT TURN`;
## and one that ships its own squad (`_C_140`, and the `--mission=` entry past
## the campaign) leaves it silently, here.
##
## `_C_106` is where the difference shows: its `NEXT TURN` is
## `Platform (19,2,2,11)` under an action-point flag the `.lev` arrives with,
## so through the deployment screen the squad rides the platform down before
## the player's first turn, and through `--mission=` it does not.
func skip_deployment_turn() -> void:
	if turn.mode == TurnState.MODE_CAMPAIGN and turn.turn == 0:
		turn.turn = TurnState.FIRST_TURN


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
		# caller that trusts them -- `game/overlay/ground_sprites.gd` walks width x height --
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

	# The routine's own three visibility passes and the position it leaves
	# are inside [method ExecuteMove.execute]; `mp_left_at` is the destination's
	# `+0x0C`, which only the presentation mode of a computer walk reads.
	var moved: MoveResult = ExecuteMove.execute(state, _units, _unit_types,
		_ctrlmap, _weapons, unit, walked, command.x, command.y,
		fill.mp_left_at(command.x, command.y), turn.human_count(), turn.mode,
		turn.ai_level, turn, rng, -1, true, _journal, cheats)
	if moved.steps == 0:
		return moved
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
	#
	# **And it is behind the mover's own alive gate.** `0x0046EDDC` is
	# `mov al, [edi+0x16] / test al, al / je 0x46EF2A`, placed immediately
	# after the mine's `aExecuteBomb` and immediately before the teleporter,
	# `aBuildVisibleMapForUnit`, the six `aSetLCLVariable` writes and
	# `aRunLCL` `0x0046EEFD`. A mover the mine on its stop cell has just
	# killed therefore runs **none** of them, and the script never sees a
	# `MoveUnit` for a walk that ended in a body.
	var arrived: int = state.index_of(moved.x, moved.y)
	if unit.is_alive():
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
	_refund_mp(unit)
	moved.reactions = Reaction.drain(state, _units, _unit_types, _weapons,
		unit, turn.ai_level, turn.human_count(), turn.mode, turn, rng,
		_journal, cheats)
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
	# **A weapon that spends ammunition and has none does not fire.**
	#
	# `aAttackUnit` itself does not check: its spend is `mov al, [esi+0x3D] /
	# sub al, dl / mov [esi+0x3D], al` at `0x0046C308`, an **8-bit**
	# subtraction that wraps rather than refusing. The check is the caller's,
	# and the engine's own weapon selector `0x0042FF30` -- transcribed as
	# [method AIOverlay.effective_weapon] for docs/23 -- is where it lives: a
	# unit whose weapon is empty gets its `special` 1 fallback or no weapon at
	# all. The computer has been going through that routine since slice 3; the
	# player's call site had no gate, so a marine fired for ever and its count
	# went negative.
	#
	# The condition mirrors [method Combat.attack]'s **spend** exactly, so the
	# count can no longer go past zero by this path whatever the magazine size.
	if (not Cheats.armed(cheats, unit, turn)
			and _weapons.magazine(unit.weapon) != Combat.MUN_NONE
			and unit.type_id != Combat.NO_AMMO_UNIT_TYPE
			and unit.ammo < _weapons.mun_per_fight(unit.weapon)):
		var empty: AttackResult = AttackResult.new()
		empty.reason = "no ammunition"
		return empty
	var weapon_fired: int = unit.weapon
	var shot: AttackResult = Combat.attack(state, _units, _unit_types,
		_weapons, unit.x, unit.y, command.x, command.y, turn.ai_level,
		turn.human_count(), turn.mode, turn, rng, false, cheats)
	if unit.hp == 0:
		# The shooter its own shot killed -- an explosive at contact range.
		# The boundary is still here: the victims are already down.
		_mark("fire", command.unit_slot, command.x, command.y,
			command.x, command.y, weapon_fired, str(weapon_fired),
			shot.to_dict())
		return shot
	var ap: int = _weapons.ap(unit.weapon)
	unit.mp = unit.mp - ap if unit.mp > ap else 0
	unit.acted = ACTED_MOVED
	_refund_mp(unit)
	# **The boundary is after the charge**, so the movement points the pad
	# draws move in the same delta as the damage; the engine draws its pad
	# from the same frame the fight animation runs in.
	#
	# The weapon rides in the note because it is read at the moment the
	# trigger was pulled: a bayonet swap or a jam changes the record before
	# the picture gets to it (docs/97 section 24).
	_mark("fire", command.unit_slot, unit.x, unit.y, command.x, command.y,
		weapon_fired, str(weapon_fired), shot.to_dict())
	shot.reactions = Reaction.drain(state, _units, _unit_types, _weapons,
		unit, turn.ai_level, turn.human_count(), turn.mode, turn, rng,
		_journal, cheats)
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
	var front: PackedInt32Array = Interact.cell_in_front(state, unit)
	var front_x: int = front[0] if front.size() == 2 else unit.x
	var front_y: int = front[1] if front.size() == 2 else unit.y
	var result: UseResult = Interact.execute(state, _units, _unit_types,
		_weapons, game_control, unit, turn.ai_level, turn.human_count(),
		turn.mode, turn, rng, cheats)
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
	# The arm's own writes are one frame: the door's cells, the lever's byte,
	# the box's clearing. The script's run marks a boundary of its own below,
	# and the pad's charge after it folds into whichever event is last -- the
	# original plays the lever's handle inside the arm and the script's
	# elevator after it, and the mirror keeps that order.
	_mark("use", command.unit_slot, unit.x, unit.y, front_x, front_y,
		result.action_point, result.kind, result.to_dict())
	# **The LCL `Use` event** -- docs/26 section 6, `0x0046E126`. Every
	# action-point class ends in it, handled or not; only a push and a defuse
	# return before it. `_D` is loaded at `0x0046E152`, **after** the switch
	# has rewritten the cell, so a lever that read 36 hands the script 37 and
	# a pickup hands it 0 -- which is why the cell is read back here rather
	# than taken from the result. There is no alive gate on this path, unlike
	# the walk's. Until 2026-09-07 nothing ran it, and every terminal a
	# mission drives through its `:Use` section -- `_C_105`'s four platform
	# consoles among them -- was a click and nothing else.
	if result.fires_script_event:
		var written: int = state.action_point_at(
			state.index_of(front_x, front_y))
		result.script_result = DictRead.as_dict(_script_callable().call(
			MissionScript.CALL_USE,
			MissionScript.env(MissionScript.CALL_USE, turn.turn, unit.player,
				front_x, front_y, 0, written, unit.slot)))
	if unit.hp != 0 and unit.mp != 0:
		unit.mp -= 1
	_refund_mp(unit)
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
	var ticket: int = Reaction.enter_defence(turn, unit)
	_mark("defend", command.unit_slot, unit.x, unit.y, 0, 0, ticket)
	return ticket


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
	# are acted on here -- outside [LclInterpreter], which owns no fog (with
	# one exception: `Platform`'s riders look around inside [method Platform.ride],
	# because that pass runs before the cell copy and after it would differ), and
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
		elif name == GORE_EVENT:
			if not values.is_empty():
				gore_level = values[0]
		elif name == ELEVATOR_EVENT:
			if values.size() < 2 or not state.in_bounds(values[0], values[1]):
				continue
			var rider: int = state.unit_at(state.index_of(values[0], values[1]))
			if rider < 0 or not _units.has(rider):
				continue
			var on_it: UnitState = _units[rider]
			Visibility.build(state, _units, _unit_types, on_it.player,
				turn.human_count(), turn.mode)
		elif name == PLATFORM_EVENT:
			# The riders already looked around inside [method Platform.ride];
			# this is the routine's own closing rebuild, for whoever the
			# interface has selected, and for nobody when it has no one.
			if selected_slot == MapState.NO_UNIT or not _units.has(selected_slot):
				continue
			var chosen: UnitState = _units[selected_slot]
			Visibility.build(state, _units, _unit_types, chosen.player,
				turn.human_count(), turn.mode)
	var result: Dictionary = outcome.to_dict()
	result["ok"] = outcome.ok()
	result["ran"] = true
	result["call_type"] = call_type
	result["env"] = environment.duplicate()
	# **Every LCL run is a boundary.** A `MoveUnit` hook that drops a
	# footbridge has killed its riders and dug its nine cells by the time it
	# answers, and the commands the turn's own program runs place units and
	# open tubes; all of it happens on screen where the sequence that changes
	# it is the one drawing (docs/42 section 10).
	_mark("script", -1, 0, 0, 0, 0, call_type, "", result)
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
	_mark("stand_down", command.unit_slot, unit.x, unit.y)
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
	_mark("stimulant", command.unit_slot, unit.x, unit.y, 0, 0, unit.mp)
	return true


## `aChangeUnitViewDirection` (`0x004792A0`) -- the direction ring's own
## command (docs/43 section 4). Writes `+0x46` and nothing else: no point is
## charged and no visibility rebuilt. Unit types 61..63 refuse
## (`0x00479330`), as do a dead unit and a facing outside 0..7.
func submit_rotate(command: RotateCommand) -> bool:
	if not _units.has(command.unit_slot):
		return false
	var unit: UnitState = _units[command.unit_slot]
	if not unit.is_alive():
		return false
	if command.facing < 0 or command.facing >= Interact.FACING_DX.size():
		return false
	if unit.type_id >= ROTATE_REFUSED_TYPE_LOW \
			and unit.type_id <= ROTATE_REFUSED_TYPE_HIGH:
		return false
	unit.facing = command.facing
	_mark("rotate", command.unit_slot, unit.x, unit.y, 0, 0, command.facing)
	return true


## `0x004753E0` -- whether the pad offers button 1, *Def*
## ([method Reaction.may_enter_defence] over a slot).
func may_defend(slot: int) -> bool:
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	return unit.is_alive() and Reaction.may_enter_defence(_weapons, unit)


## `0x00475430` -- whether the pad offers button 5, *Change weapon mode*.
##
## The weapon must have another mode (`toggle != id`), the unit must carry at
## least the **other** mode's rounds per shot (`+0x41` of the toggle) and at
## least its action points (`+0x3C` of the toggle). Read against the toggle
## and not the current weapon, which is what makes a mode with no ammunition
## left unreachable rather than merely useless.
func may_toggle_weapon(slot: int) -> bool:
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	if not unit.is_alive():
		return false
	var other: int = _weapons.toggle(unit.weapon)
	if other == unit.weapon:
		return false
	if unit.ammo < _weapons.mun_per_fight(other):
		return false
	return unit.mp >= _weapons.ap(other)


## `aToggleWeaponModes` (`0x0047A8C0`) -- `unit[+0x3F] = weapon[+0x3D]`,
## behind the pad's own gate. Answers whether the mode changed.
func submit_toggle_weapon(command: ToggleWeaponCommand) -> bool:
	if not may_toggle_weapon(command.unit_slot):
		return false
	var unit: UnitState = _units[command.unit_slot]
	unit.weapon = _weapons.toggle(unit.weapon)
	_mark("toggle_weapon", command.unit_slot, unit.x, unit.y, 0, 0,
		unit.weapon)
	return true


## `0x00472641` -- whether the pad offers button 7, *Rest*: the unit has not
## acted this turn (`+0x39 == 0`) and is not a machine (species 3).
func may_stand_down(slot: int) -> bool:
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	if not unit.is_alive():
		return false
	return unit.acted == 0 \
		and _unit_types.species(unit.type_id) != SPECIES_MACHINE


## `0x004725F4` -- whether the pad offers button 3, *Take stimulants*: a
## charge that is neither absent nor already spent this turn, and a point.
func may_take_stimulant(slot: int) -> bool:
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	if not unit.is_alive() or unit.mp < 1:
		return false
	return unit.stimulant != 0 and unit.stimulant != Refresh.STIMULANT_SPENT


## `0x0047268B` -- whether the pad offers button 8, *Use*: not a machine, a
## point left, and something in front to use ([method Interact.may_use]).
func may_use(slot: int) -> bool:
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	if not unit.is_alive() or unit.mp < 1:
		return false
	if _unit_types.species(unit.type_id) == SPECIES_MACHINE:
		return false
	return Interact.may_use(state, _units, _unit_types, unit)


## `aBuildTargetOverlay` (`0x0042FF30`) for the **player's** selection: the
## cells docs/23 section 6's bands are stamped on, keyed by cell. What the
## ground overlay draws as `mp[43..47]` (docs/43 section 3) and what [method
## facing_to_target] turns the shooter towards.
##
## **The routine is [method AIOverlay.build], not a second transcription of
## it.** The player's select (`0x00472990`) and the computer's plan call the
## same `0x0042FF30`, so its exclusions are the same for both: the fitness
## gate, the never-target and immune types, the two weapon overrides and the
## `special` hook. A short reading of it here banded a `Norc'Yn` and a
## Concrete Block -- cells the engine's overlay leaves at state 1 -- and made
## the shooter turn towards them after a shot. The context is a fresh one per
## call: it is one array of map size, and a selection is a click, not a frame.
func target_bands(shooter_slot: int) -> Dictionary[Vector2i, int]:
	var bands: Dictionary[Vector2i, int] = {}
	if not _units.has(shooter_slot):
		return bands
	var overlay: PackedByteArray = target_overlay(shooter_slot)
	for index: int in range(overlay.size()):
		var marker: int = overlay[index]
		if marker < AIOverlay.MARKER_MIN or marker > AIOverlay.MARKER_MAX:
			continue
		bands[Vector2i(index % state.width, index / state.width)] = marker
	return bands


## The overlay bytes themselves -- `cell[+0x00]` as `0x0042FF30` leaves them,
## reset to [constant AIOverlay.STATE_RESET] and stamped with the bands.
##
## Only the `units` arm of the dispatcher is transcribed (docs/43 section 11,
## D10): the other arms stamp 35, 36 and 37 for the weapons that aim at a
## special object, at empty ground or at any unit, and `AIOverlay.build`
## records that refusal rather than inventing it.
func target_overlay(shooter_slot: int) -> PackedByteArray:
	if not _units.has(shooter_slot):
		return PackedByteArray()
	var shooter: UnitState = _units[shooter_slot]
	var ctx: AIContext = AIContext.create(state, _units, _unit_types, _weapons,
		_ctrlmap, turn, rng)
	var _stamped: bool = AIOverlay.build(ctx, shooter, turn.human_count(),
		turn.mode)
	return ctx.state


## `aGetDirectionTo(x, y, 0)` as the click handler calls it after an attack
## (`0x0047181C`): the facing towards the best target band, or
## [constant Combat.FACING_NONE] with nothing to face. The bands are the
## selection's own ([method target_bands]), written into a cell-state array
## the way the engine's overlay leaves them on `cell[+0x00]`.
func facing_to_target(shooter_slot: int) -> int:
	if not _units.has(shooter_slot):
		return Combat.FACING_NONE
	var shooter: UnitState = _units[shooter_slot]
	# The overlay's own bytes, not a dictionary written back into an array:
	# `aGetDirectionTo` reads `cell[+0x00]` and this is that array
	# (docs/43 section 4.4).
	var states: PackedByteArray = target_overlay(shooter_slot)
	return Combat.end_turn_facing(state, _units, _unit_types, shooter.x,
		shooter.y, Combat.FACING_MODE_TARGET_BAND, false, states)


## `0x00475240` -- the hit points a unit can have, for the panel's `hp/max`
## ([method Interact.max_hit_points] over a slot).
func max_hit_points(slot: int) -> int:
	if not _units.has(slot):
		return 0
	var unit: UnitState = _units[slot]
	return Interact.max_hit_points(_unit_types, unit)


## `0x0047B4C0` under the pad's `+0x15 >= 1` -- whether button 2 is offered
## for a slot. The gate is the pad's, so it lives beside the command and not
## inside it, as [method Interact.may_use] does for `Use`.
func may_heal(slot: int) -> bool:
	if not _units.has(slot):
		return false
	var unit: UnitState = _units[slot]
	if not unit.is_alive() or unit.mp < 1:
		return false
	return Interact.may_heal(state, _units, _unit_types, unit)


## docs/29 section 1.1's button 2 -- the medic kit (`0x00470890` under the
## pad arm at `0x004733BB`, docs/97 section 31). Answers [method
## Interact.heal]'s dictionary; a refusal changes nothing but `acted`, which
## the pad writes either way.
func submit_heal(command: HealCommand) -> Dictionary:
	if not _units.has(command.unit_slot):
		return {"ok": false, "reason": "no such unit", "target": -1,
			"delta": 0, "self_heal": false}
	var unit: UnitState = _units[command.unit_slot]
	if not unit.is_alive():
		return {"ok": false, "reason": "the unit is dead", "target": -1,
			"delta": 0, "self_heal": false}
	var healed: Dictionary = Interact.heal_command(state, _units,
		_unit_types, unit)
	_mark("heal", command.unit_slot, unit.x, unit.y, 0, 0,
		DictRead.as_int(healed["delta"]), "", healed)
	return healed


## The Jet Pack's jump -- `aExecuteWarp` under the pad arm at `0x00472F10`
## (docs/97 section 31). The cell must be one the movement query marked as
## a warp target, which is the same gate a walk has: `core` re-fills rather
## than trusting the picture.
##
## After the routine, for a mover still alive: the movement points go to
## zero, `+0x39` is written 5, and the reaction queue is drained at the
## landing cell. The `MoveUnit` script call is the routine's own
## (`0x0046F196`: var 0x41 written 2, x, y and the cell's action point), and
## it fires **before** the pad's charge, as the walk's does.
func submit_warp(command: WarpCommand) -> WarpResult:
	if not _units.has(command.unit_slot):
		return WarpResult.failed(0, 0, "no such unit")
	var unit: UnitState = _units[command.unit_slot]
	var fill: MoveMapResult = submit_move_query(
		MoveQueryCommand.create(command.unit_slot))
	if not fill.is_warp_target(command.x, command.y):
		return WarpResult.failed(unit.x, unit.y,
			"the cell is not a warp target")
	var from_x: int = unit.x
	var from_y: int = unit.y
	var done: Dictionary = ExecuteWarp.execute(state, _units, _unit_types,
		_weapons, unit, command.x, command.y, turn.human_count(), turn.mode,
		turn.ai_level, turn, rng, _journal, cheats)
	if not DictRead.as_bool(done["ok"]):
		return WarpResult.failed(unit.x, unit.y,
			DictRead.as_string(done["reason"]))
	var result: WarpResult = WarpResult.new()
	result.ok = true
	result.from_x = from_x
	result.from_y = from_y
	result.x = unit.x
	result.y = unit.y
	result.blast = DictRead.as_dict(done.get("blast", {}))
	# The `MoveUnit` call is behind the mover's own alive gate, exactly as the
	# walk's is: `0x0046F133` is `mov al, [esi+0x16] / test al, al /
	# je 0x46F200`, and `0x46F200` is the bare `mov eax, 1 / ret`. So a mover
	# the mine under its landing has just killed runs neither the fog rebuild
	# (`0x0046F144`, inside [ExecuteWarp]) nor `aRunLCL` (`0x0046F1D6`).
	var arrived: int = state.index_of(unit.x, unit.y)
	if unit.is_alive():
		result.script_result = DictRead.as_dict(_script_callable().call(
			MissionScript.CALL_MOVE_UNIT,
			MissionScript.env(MissionScript.CALL_MOVE_UNIT, turn.turn,
				unit.player, unit.x, unit.y,
				state.height_at(arrived) / MissionScript.HEIGHT_LEVEL_UNITS,
				state.action_point_at(arrived), unit.slot)))
		unit.mp = 0
		unit.acted = ACTED_WARPED
		_refund_mp(unit)
		result.reactions = Reaction.drain(state, _units, _unit_types,
			_weapons, unit, turn.ai_level, turn.human_count(), turn.mode,
			turn, rng, _journal, cheats)
	return result


## `0x00477BF0` -- how many live units a player owns.
func live_unit_count(player: int) -> int:
	var n: int = 0
	for slot: Variant in _units:
		var unit: UnitState = _units[slot]
		if unit.player == player and unit.hp > 0:
			n += 1
	return n


## Whether the player holding the turn may give this slot an order.
##
## Alive (`+0x16`) and `+0x45` equal to the player it is passed are the first
## two of `0x00477D40`'s three tests -- the walker `0x00471E00`, the game's own
## "select the next friendly unit" (interface event 12), runs over the 200
## slots; its third, `+0x15` not zero, is [method may_select]'s. `+0x4F` not
## hidden is the remake's own guard on top: an own unit is never hidden by
## the fog pass, so it costs nothing and keeps a click and the cycle on the
## same rule. (Until 2026-09-05 this comment named `0x00477DF0`, which is the
## *other* walker: the first live unit **not** of the current player with
## `+0x4F == 0`, the one event 14 -- *Jump to visible enemy* -- puts the
## camera on. docs/43 section 5.2.)
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


## `0x004714B0`'s own selection rule on top of [method may_command]: a unit
## with no movement points left cannot be selected (`0x00471CB6` returns
## before `0x00472990`), and the click handler deselects after any command
## that leaves none. docs/43 section 4.
func may_select(slot: int) -> bool:
	if not may_command(slot):
		return false
	var unit: UnitState = _units[slot]
	return unit.mp > 0


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
## `0x00470AB0` then `0x0042ED60` -- the round's two ground sweeps, in the
## order the hand-over has them.
##
## Every glow that reached phase 1 ignites, and the flames **remove** every
## unit on the eight cells around it plus its own that is not standing in a
## shield; then the glows, fires and shields decay one step (docs/42 section
## 9.1).  It is not damage: `aPlayGroundFireAnimation` hides each object and
## calls `aRemoveUnitElement` for it.
func _ground_tick() -> Dictionary:
	var ignited: PackedInt32Array = CellObjects.glows_to_ignite(state)
	var killed: PackedInt32Array = PackedInt32Array()
	for at: int in ignited:
		var cells: PackedInt32Array = CellObjects.ground_fire_cells(
			state, at % state.width, at / state.width)
		for cell: int in cells:
			var slot: int = state.unit_at(cell)
			if slot < 0 or not _units.has(slot):
				continue
			var victim: UnitState = _units[slot]
			# The flames are what weapon 40 lays (docs/42 section 9.1), so
			# they are a weapon reaching a unit and [member Cheats.god]
			# covers them. It cannot be a zeroed damage argument here: this
			# path rolls nothing and removes outright, so the shield is the
			# removal not happening.
			if Cheats.shielded(cheats, victim, turn):
				continue
			# `aRemoveUnitElement` and **nothing else**: it bumps the hero
			# counter, frees the 3D object, clears the cell link and -- with
			# its last instruction, `0x00477ABD` -- zeroes the hit points.
			# So the flames kill; no damage roll runs, but the victim is dead
			# and not merely unlinked (docs/97 section 40 corrects section 38).
			var _counted: bool = UnitState.remove(state, turn, victim)
			killed.append(slot)
	var changed: PackedInt32Array = CellObjects.round_tick(state)
	var outcome: Dictionary = {"ignited": Array(ignited),
		"killed": Array(killed), "changed": Array(changed)}
	_mark("ground", -1, 0, 0, 0, 0, killed.size(), "", outcome)
	return outcome


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
		live_unit_count, command.arg, _ground_tick)
	if result.refreshed:
		# `aBuildVisibleMap` for whoever now holds the turn. It runs here and
		# not in [Refresh] for the reason that file states: visibility is a map
		# walk and the refresh is a unit walk. It runs only when the refresh
		# did, so a hand-over the script stopped leaves the fog alone -- the
		# same player is still looking at the same world.
		Visibility.build(state, _units, _unit_types, turn.current_player,
			turn.human_count(), turn.mode)
		result.fog_rebuilt = true
	# The rotation, the refresh and the fog are one visible change: the engine
	# draws its between-players screen here (`0x0047C2C0`, docs/97 section
	# 35.1) and nothing of the turn before it is on screen after.
	_mark("hand_over", -1, turn.previous_player, 0, turn.current_player, 0,
		turn.turn, str(result.code), result.to_dict())

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
			ctx.cheats = cheats
			ctx.journal = _journal
			# The mission script reaches the computer's walks and jumps the
			# way it reaches the player's: `aRunLCL` closes `aExecuteMove`
			# and `aExecuteWarp` themselves, with no test of who is moving.
			ctx.mission_script = _script_callable()
			var one: AITurnResult = AISystem.run(ctx, turn.current_player)
			played = one if played == null else played.followed_by(one)
		result = TurnSequence.hand_over(turn, _units, game_control,
			_unit_types, _weapons, _script_callable(), banner_in_range,
			live_unit_count, EndTurnCommand.create().arg, _ground_tick)
		if result.refreshed:
			Visibility.build(state, _units, _unit_types, turn.current_player,
				turn.human_count(), turn.mode)
			result.fog_rebuilt = true
		_mark("hand_over", -1, turn.previous_player, 0, turn.current_player,
			0, turn.turn, str(result.code), result.to_dict())
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
func display_visibility(viewer: int = -1,
		at: Dictionary[int, Vector2i] = {}) -> Dictionary[int, int]:
	var seat: int = turn.current_player if viewer < 0 else viewer
	return Visibility.states_for(state, _units, _unit_types,
		seat, turn.human_count(), turn.mode, at)


## `0x00481F00` once, as `aViewPlayer.cpp`'s dispatcher runs it: **before a
## player command**, not on every rebuild.
##
## The probe restores every `+0x4F`, so what it saw is a query -- that is
## [method display_visibility]. What it does **not** restore is the orders
## `alert_group` promotes, so a group the current player can see switches to
## its second order and stays switched. That is a defect of the engine's,
## and this remake used to decline to reproduce it (docs/92 section 7.5.5);
## it reproduces it now, because the original is the standard and the defect
## costs the player no control (docs/97 section 34). [constant
## COMPAT_FOG_PROBE_QUIET] restores the quiet probe.
##
## Answers how many units the wake promoted, for a caller and a suite.
func probe_fog() -> int:
	if compat_flags.has(COMPAT_FOG_PROBE_QUIET):
		return 0
	var woken: int = Visibility.probe(state, _units, _unit_types,
		turn.current_player, turn.human_count(), turn.mode)
	# The probe restores every `+0x4F` and **not** the orders it promoted, so
	# it changes the rules; the mirror has to follow it or the two worlds
	# drift by exactly that defect.
	_mark("fog_probe", -1, 0, 0, 0, 0, woken, "", {})
	return woken


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


## Start recording what every command changes, for the picture's mirror.
##
## Idempotent, and there is no way back: a journal that could be turned off
## mid-mission would leave the mirror behind the truth with nothing to say so.
## See [EventJournal].
func enable_journal() -> void:
	if _journal != null:
		return
	_journal = EventJournal.new()
	_journal.bind(state, _units, turn, game_control, rng, crand)


func journal_enabled() -> bool:
	return _journal != null


## The journal itself, for a caller that hands it to the computer's turn.
func journal() -> EventJournal:
	return _journal


## The events since the last call, oldest first. Empty without a journal.
func take_events() -> Array[Dictionary]:
	if _journal == null:
		return []
	return _journal.take()


## Close one boundary. A no-op without a journal, and it builds nothing then.
## Put a unit's movement points back, when [member Cheats.moves] says to.
##
## **The allowance, not the value before the charge.** [method
## Allowance.for_unit] is what a hand-over would have given the unit
## ([method Refresh.player]), so a unit that stood down, is out of fitness or
## carries an action state that zeroes the allowance still gets nothing --
## the switch makes an action free, it does not lift the rules that say the
## unit may not act at all.
##
## It runs **before** the command's journal boundary, so the pad draws the
## refunded points in the same delta as the rest of the command.
func _refund_mp(unit: UnitState) -> void:
	if not Cheats.tireless(cheats, unit, turn) or not unit.is_alive():
		return
	unit.mp = Allowance.for_unit(unit, _unit_types, _units, turn.ai_level)


## [constant Cheats.ACTION_NUKE] -- kill every unit no human player controls.
##
## A one-off action and not a switch: it has no state to be in. The counters
## move exactly as they do for a unit shot dead ([method
## Combat.attack]'s kill arm), because a mission whose win condition counts
## kills has to be able to end this way -- which is the whole point of having
## it while a level is being walked.
##
## **The inanimate objects are left standing.** docs/21 section 5's species 2
## is barrels, cases and the scenery that happens to be a unit record; a
## mission whose crates all vanished would not be the mission being tested,
## and [method load_sweep] already treats that species as the one owner test
## to forgive.
##
## Answers how many died. The caller redraws: this writes the world and marks
## nothing, so the picture's mirror is resynchronised rather than advanced.
func cheat_kill_enemies() -> int:
	var killed: int = 0
	for slot: int in unit_slots():
		var unit: UnitState = _units[slot]
		if not unit.is_alive() or Cheats.controlled(unit, turn):
			continue
		if _unit_types.species(unit.type_id) == SPECIES_INANIMATE:
			continue
		turn.count_kill_and_loss(turn.current_player, unit.type_id,
			unit.player)
		var _hero: bool = UnitState.remove(state, turn, unit)
		killed += 1
	return killed


func _mark(kind: String, slot: int = -1, x: int = 0, y: int = 0,
		tx: int = 0, ty: int = 0, detail: int = 0, note: String = "",
		payload: Dictionary = {}) -> void:
	if _journal == null:
		return
	var _event: Dictionary = _journal.mark(kind, slot, x, y, tx, ty, detail,
		note, payload)


## An independent world at this one's state -- the picture's mirror.
##
## **Not [method save] and [method load_save].** That pair needs the same
## [MapResource] and ends in a permanent `aBuildVisibleMap`
## (`0x004490A9`), which would move the fog of the copy the picture reads; and
## it cannot carry `special_models`, `next_map` or the selection. This copies
## the simulation and **shares** the four read-only tables: the map resource,
## the control map, the unit types and the weapons are authored data that no
## rule writes.
##
## The mirror runs no mission program ([member script_program] stays `null`):
## it is advanced by deltas and never resolves anything itself.
func clone() -> World:
	var copy: World = World.new()
	copy.resource = resource
	copy._ctrlmap = _ctrlmap
	copy._unit_types = _unit_types
	copy._weapons = _weapons
	copy.state = state.clone()
	for key: Variant in _units:
		var unit: UnitState = _units[key]
		copy._units[DictRead.as_int(key)] = UnitState.from_view(unit.view())
	copy.turn = turn.clone()
	copy.game_control = game_control.clone()
	copy.rng = rng.clone()
	copy.crand = crand.clone()
	copy.compat_flags = compat_flags.duplicate()
	copy.selected_slot = selected_slot
	copy.gore_level = gore_level
	copy.next_map = next_map
	copy.ai_may_fire = ai_may_fire
	# **Shared, not copied.** The switches are one session-level object
	# ([member SliceMain.cheats]) that [method SliceMain._build] hands to every
	# world it makes; a snapshot taken here would freeze at clone time and
	# diverge from the truth on the next toggle. The mirror resolves nothing,
	# so nothing ever writes through it, and [Cheats] holds no reference back.
	copy.cheats = cheats
	copy._hand_over_initialised = _hand_over_initialised
	copy._camera = _camera.duplicate(true)
	copy._scenery = _scenery.duplicate(true)
	return copy


## Advance this world by one event's delta. The mirror's only mutator.
##
## Cells go through [MapState]'s setters, so a mirror that is itself
## journalled would record them; units are rebuilt from their views, because
## a slot the turn refilled is a different unit and not an edited one.
func apply_delta(delta: Dictionary) -> void:
	if delta.is_empty():
		return
	var cells: Dictionary = DictRead.as_dict(delta["cells"])
	for key: Variant in cells:
		state.apply_cell_record(DictRead.as_int(key),
			DictRead.as_dict(cells[key]))
	if delta.has("objects"):
		state.set_objects(DictRead.to_bytes(delta["objects"]))
	var units: Dictionary = DictRead.as_dict(delta["units"])
	for key: Variant in units:
		var slot: int = DictRead.as_int(key)
		var view: Dictionary = DictRead.as_dict(units[key])
		if view.is_empty():
			var _gone: bool = _units.erase(slot)
		else:
			_units[slot] = UnitState.from_view(view)
	turn.restore(DictRead.as_dict(delta["turn"]))
	game_control.restore(DictRead.as_int32_array(delta["game_control"]))
	rng.restore(DictRead.as_dict(delta["rng"]))
	crand.restore(DictRead.as_dict(delta["crand"]))


## Every event in order. The list [method take_events] answered.
func apply_events(events: Array[Dictionary]) -> void:
	for event: Dictionary in events:
		apply_delta(DictRead.as_dict(event["delta"]))


## Where two worlds differ, named: the turn, the game control, the two
## generators, the compatibility flags, each unit whose view moved (with
## the fields), the cells and the objects. Reads only. For the mirror's
## resynchronisation warning and a driven session's snapshot -- a hash that
## says "different" names nothing, and the field is what closes the defect.
func mirror_diff(other: World) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if other == null:
		return out
	if not EventJournal._same_view(turn.view(), other.turn.view()):
		out.append("turn %s vs %s" % [str(turn.view()), str(other.turn.view())])
	if game_control.values() != other.game_control.values():
		out.append("game_control")
	if not EventJournal._same_view(rng.state(), other.rng.state()):
		out.append("rng %s vs %s" % [str(rng.state()), str(other.rng.state())])
	if not EventJournal._same_view(crand.state(), other.crand.state()):
		out.append("crand %s vs %s" % [str(crand.state()), str(other.crand.state())])
	if compat_flags != other.compat_flags:
		out.append("compat_flags")
	for slot: int in unit_slots():
		if not other.has_unit(slot):
			out.append("unit %d missing" % slot)
			continue
		var mine: Dictionary = unit_view(slot)
		var theirs: Dictionary = other.unit_view(slot)
		if EventJournal._same_view(mine, theirs):
			continue
		var fields: PackedStringArray = PackedStringArray()
		for key: Variant in mine:
			if not theirs.has(key) or mine[key] != theirs[key]:
				fields.append("%s %s/%s" % [str(key), str(mine[key]),
					str(theirs.get(key))])
		out.append("unit %d: %s" % [slot, ", ".join(fields)])
	for slot: int in other.unit_slots():
		if not has_unit(slot):
			out.append("unit %d extra" % slot)
	var cells: int = 0
	var first: String = ""
	for index: int in range(state.width * state.height):
		if not EventJournal._same_view(state.cell_record(index),
				other.state.cell_record(index)):
			cells += 1
			if first.is_empty():
				first = "%d %s vs %s" % [index, str(state.cell_record(index)),
					str(other.state.cell_record(index))]
	if cells > 0:
		out.append("%d cell(s), first %s" % [cells, first])
	if state.objects() != other.state.objects():
		out.append("objects")
	return out


func canonical_hash() -> PackedByteArray:
	return CanonicalHash.compute(state, _units, turn, game_control, rng,
		crand, compat_flags)


func canonical_hash_hex() -> String:
	return CanonicalHash.to_hex(canonical_hash())


func save(camera: Dictionary, scenery: Dictionary = {}) -> PackedByteArray:
	return SaveCodec.encode(resource, state, _units, turn, game_control, rng,
		crand,
		compat_flags, camera, scenery)


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
	# The world set's placer models are the **mission's**, not the save's, and
	# `SaveCodec` neither stores nor could store them -- so they are carried
	# across rather than lost, or a resumed mission would let a
	# `SetGroundFire` work where the engine does nothing (docs/42 section 9.1).
	var models: PackedStringArray = state.special_models()
	state = decoded["state"]
	state.set_special_models(models)
	_units = decoded["units"]
	turn = decoded["turn"]
	game_control = decoded["game_control"]
	rng = decoded["rng"]
	crand = decoded["crand"]
	compat_flags = decoded["compat_flags"]
	_camera = DictRead.as_dict(decoded["camera"])
	_scenery = DictRead.as_dict(decoded["scenery"])
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
	# The load replaced every component the journal was watching, so it is
	# re-bound onto the new ones; whatever it had recorded belonged to the
	# world that is gone.
	if _journal != null:
		_journal.bind(state, _units, turn, game_control, rng, crand)
	return code


## The camera state the last successful [method load_save] read, or an empty
## dictionary when nothing has been loaded.
func restored_camera() -> Dictionary:
	return _camera.duplicate(true)


## The scenery pose record the last successful [method load_save] read, or
## an empty dictionary when nothing has been loaded.
func restored_scenery() -> Dictionary:
	return _scenery.duplicate(true)


# --- deployment -- docs/29 section 1.2, docs/27 section 3.4 -------------------

## `0x00431118` -- a deployment cell is one whose action point is the player's
## slot plus one.
const DEPLOYMENT_ACTION_POINT_BIAS: int = 1

## Why [method deploy_from_pool] refused.
const DEPLOY_OK: String = ""
const DEPLOY_NOT_A_CELL: String = "not_a_deployment_cell"
const DEPLOY_CELL_TAKEN: String = "cell_occupied"
const DEPLOY_NO_SLOT: String = "no_free_unit_slot"
const DEPLOY_EMPTY_RECORD: String = "empty_roster_record"


## The cells *player* may deploy onto, in map order.
##
## **Not `start_index`.** `+0x14` is the slot of the victory-point marker the
## placer `0x00431E30` last stood on the cell (docs/10 section 4.2), a runtime
## residue; deployment is the action-point byte `+0x0B`, and the corpus shows
## no cell is both.
func deployment_cells(player: int) -> Array[Vector2i]:
	var want: int = player + DEPLOYMENT_ACTION_POINT_BIAS
	var out: Array[Vector2i] = []
	for y: int in range(state.height):
		for x: int in range(state.width):
			# From [MapState], not [MapResource] (D4): the action-point byte is
			# cell state a mission can rewrite, and there is no second list of
			# deployment cells to keep in step with it.
			if state.action_point_at(state.index_of(x, y)) == want:
				out.append(Vector2i(x, y))
	return out


## `aTransferUnitFromPoolToMap` `0x00478D10` -- put one roster record on the map.
##
## Returns `{"result": String, "slot": int}`. `result` is [constant DEPLOY_OK]
## on success and one of the four refusals otherwise -- the engine's own
## `aUI_SetUnit` path simply fails, and docs/92 section 7.4's rule that the
## silence does not stay applies to deployment as much as to the mission end.
##
## The record is **not** removed from the roster here: the caller owns the
## roster, `core` does not, and the engine's own routine takes the slot out of
## the pool only after `aUI_SetUnit` succeeds.
func deploy_from_pool(player: int, record: UnitState, x: int,
		y: int) -> Dictionary:
	if record == null or not record.is_placed():
		return {"result": DEPLOY_EMPTY_RECORD, "slot": MapState.NO_UNIT}
	if not state.in_bounds(x, y):
		return {"result": DEPLOY_NOT_A_CELL, "slot": MapState.NO_UNIT}
	if state.action_point_at(state.index_of(x, y)) \
			!= player + DEPLOYMENT_ACTION_POINT_BIAS:
		return {"result": DEPLOY_NOT_A_CELL, "slot": MapState.NO_UNIT}
	if not UnitState.free_cell(state, _units, x, y):
		return {"result": DEPLOY_CELL_TAKEN, "slot": MapState.NO_UNIT}
	var slot: int = UnitState.free_slot(_units)
	# `free_slot` answers with the **last** slot when the array is full rather
	# than with a refusal, so a full array has to be recognised here or a
	# deployment would silently overwrite slot 199.
	if _units.has(slot) and DictRead.as_int(slot) >= 0:
		var sitting: UnitState = _units[slot]
		if sitting.is_alive():
			return {"result": DEPLOY_NO_SLOT, "slot": MapState.NO_UNIT}

	var unit: UnitState = UnitState.from_view(record.view())
	unit.slot = slot
	unit.player = player
	unit.x = x
	unit.y = y
	unit.turn_start_x = x
	unit.turn_start_y = y
	_units[slot] = unit
	state.set_unit(state.index_of(x, y), slot)
	# `0x00478DD1`, between `aUI_SetUnit` and the pool removal: the **full**
	# recompute, not the hand-over's short one. A roster record carries no
	# ammunition byte of its own -- `aEnlargeUnitPool` never writes one -- so
	# without this every deployed squad reaches the map with an empty weapon,
	# which is what made `_C_100` unplayable.
	Refresh.recompute_full(unit, _unit_types, _weapons, _units, turn.ai_level)
	# `aTransferUnitFromPoolToMap` rebuilds visibility before it returns, which
	# is what makes a squad see the map it was just placed on.
	Visibility.build(state, _units, _unit_types, player, turn.human_count(),
		turn.mode)
	return {"result": DEPLOY_OK, "slot": slot}


## `aTransferAllUnitsFromMapToPool` `0x00478E50` -- every live unit of *player*,
## as the records the roster's gate then judges.
##
## The gate itself is [method MissionEnd.recover]: `core` hands back the
## survivors and the campaign decides which of them the pool accepts, because
## the pool is campaign state and this object is a mission.
func survivors_of(player: int) -> Array[UnitState]:
	var out: Array[UnitState] = []
	for slot: int in unit_slots():
		var unit: UnitState = _units[slot]
		if unit.player != player or not unit.is_placed():
			continue
		# `0x00478EA1` -- the same full recompute deployment runs, so what
		# reaches the pool is a refreshed record rather than one still carrying
		# the last turn's movement. It heals the survivor to the ceiling and
		# refills the magazine, which is what the pool row of every save
		# fixture shows: Sgt. Bratt comes back at `hp 11` with `ammo 10`, his
		# maximum and weapon 2's magazine exactly.
		Refresh.recompute_full(unit, _unit_types, _weapons, _units,
			turn.ai_level)
		out.append(UnitState.from_view(unit.view()))
	return out


## `lKillPlayerUnits` `0x0047BC60` -- *Give up!*: every unit of *player* is
## **killed**, one by one, and the mission goes on without them.
##
## The engine's loop walks all 200 records, tests the owner and calls its
## death creator and then the kill routine per unit, so the mission's own
## counters move exactly as they do for a unit shot dead. Erasing the records
## instead -- which this used to do -- left the scoreboard reporting no losses
## at all for a squad that had just been wiped out. Answers how many died.
func kill_units_of(player: int) -> int:
	var killed: int = 0
	for slot: int in unit_slots():
		var unit: UnitState = _units[slot]
		if unit.player != player or not unit.is_alive():
			continue
		var _hero: bool = UnitState.remove(state, turn, unit)
		killed += 1
	return killed


## Take a player's units off the map -- what the debriefing leaves behind.
func clear_units_of(player: int) -> int:
	var removed: int = 0
	for slot: int in unit_slots():
		var unit: UnitState = _units[slot]
		if unit.player != player:
			continue
		state.set_unit(state.index_of(unit.x, unit.y), MapState.NO_UNIT)
		_units.erase(slot)
		removed += 1
	return removed
