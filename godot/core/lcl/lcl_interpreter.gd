class_name LclInterpreter
extends RefCounted

## `0x0043F6E0` -- one invocation of one mission program, from docs/20.
##
## Transcribed from `tools/inclib/lcl_runtime.py`, which is itself checked
## against all 153 shipped scripts and pinned natively for one `NextPlayer` on
## `_C_141` (two `SetVarRandom` draws, `aRandom`'s seed read either side).
##
## Four properties are deliberate, and each is what the engine does:
##
## 1. **One linear pass with a condition flag**, not a tree. A `cond` sets or
##    combines the flag, a `close` resets it to true, an `else` inverts it, and
##    a command runs only when it is true. `Goto` rescans from the top, so a
##    loop is expressible and [constant MAX_STEPS] is what stops one.
## 2. **The predicate always runs.** `&` and `|` do not short-circuit: the
##    engine evaluates the predicate and *then* combines, so a predicate with a
##    side effect -- none of the twelve has one -- would still fire.
## 3. **An unknown name aborts.** docs/20 section 7.1: the dispatcher returns
##    "not found" and the invocation ends with a report. A silent no-op would
##    look like a working script, so this reports the name.
## 4. **`SetVarVar` is broken as shipped** and stays broken -- see the handler.
##
## Dispatch is a `match` on the name and not a table of [Callable]s: a
## dictionary lookup yields a `Variant`, which `unsafe_call_argument` refuses,
## and the engine's own dispatch is a linear name comparison anyway.

## A hard stop. `Goto` makes an unbounded loop expressible, and a check that
## hangs on one script is worse than one that names it.
const MAX_STEPS: int = 100000

## docs/20 section 7.4 -- 255 is the computer in every player argument;
## `UnitOnField`/`MechOnField` also accept 254 for "any".
const PLAYER_COMPUTER: int = 255
const PLAYER_ANY: int = 254
## Species 2 is an object and 3 a machine; `UnitOnField` excludes both and
## `MechOnField` requires the second.
const SPECIES_OBJECT: int = 2
const SPECIES_MACHINE: int = 3
## `InsertUnit` refuses to spawn on a cell whose ActPt is 71 (`'G'`).
const ACTPT_NO_SPAWN: int = 71
## The control-map types the set pieces write.
const CTRL_TYPE_WALL: int = 2
const CTRL_TYPE_DEEP_HOLE: int = 4
## `Elevator` moves five height levels per step.
const ELEVATOR_STEP: int = 800
## `ParaBombs` makes exactly this many attempts to lay a mine.
const PARA_BOMB_TRIES: int = 60
## `FixedStatue` reaches at most this far.
const STATUE_REACH: int = 10

## docs/20 sections 2.3 and 7.4 -- the two directions a set piece can be given,
## which do **not** agree on the north/south axis. Keeping both spellings is the
## point: folding them into one is the trap the doc calls out.
const DIR_PLATFORM_DX: Array[int] = [0, -1, 0, 1]
const DIR_PLATFORM_DY: Array[int] = [-1, 0, 1, 0]
const DIR_BARRIER_DX: Array[int] = [0, -1, 0, 1]
const DIR_BARRIER_DY: Array[int] = [1, 0, -1, 0]

var _program: LclProgram
var _context: LclContext
var _local: PackedInt32Array = PackedInt32Array()
var _env: PackedInt32Array = PackedInt32Array()
var _flag: bool = true
var _pos: int = 0
var _max_steps: int = MAX_STEPS
var _events: Array[Dictionary] = []
var _dispatched: int = 0
var _abort: String = ""


static func create(program: LclProgram, context: LclContext,
		env: PackedInt32Array, max_steps: int = MAX_STEPS) -> LclInterpreter:
	var it: LclInterpreter = LclInterpreter.new()
	it._program = program
	it._context = context
	it._local.resize(LclEnv.LOCAL_SLOTS)
	it._local.fill(LclEnv.LOCAL_INITIAL)
	it._env.resize(LclEnv.ENV_SLOTS)
	for i: int in range(mini(env.size(), LclEnv.ENV_SLOTS)):
		it._env[i] = env[i]
	it._max_steps = max_steps
	return it


## Run one invocation. Construct, call this, read the outcome.
static func run(program: LclProgram, context: LclContext,
		env: PackedInt32Array, max_steps: int = MAX_STEPS) -> LclOutcome:
	return create(program, context, env, max_steps).execute()


func execute() -> LclOutcome:
	var steps: int = 0
	while true:
		if _pos >= _program.instructions.size():
			return _outcome(LclOutcome.FELL_OFF, "", _last_line(), steps)
		steps += 1
		if steps > _max_steps:
			return _outcome(LclOutcome.ABORT,
				"more than %d steps; a Goto loop that never reaches [END]"
					% _max_steps, _line(_pos), steps)
		var instr: Dictionary = _program.instructions[_pos]
		var kind: String = DictRead.as_string(instr["kind"])
		var line: int = DictRead.as_int(instr["line"])
		_pos += 1

		match kind:
			"cond":
				var value: bool = _predicate(instr)
				if _abort != "":
					return _outcome(LclOutcome.ABORT, _abort, line, steps)
				# No short-circuit: the predicate above already ran.
				match DictRead.as_string(instr["op"]):
					">": _flag = value
					"&": _flag = _flag and value
					_: _flag = _flag or value
			"close":
				_flag = true
			"else":
				_flag = not _flag
			"label", "text":
				# A label is an address and a text line is a store the mission
				# layer never reads.
				pass
			"end":
				return _outcome(LclOutcome.END, "", line, steps)
			"abort":
				return _outcome(LclOutcome.ABORT,
					DictRead.as_string(instr["name"]), line, steps)
			"command":
				if not _flag:
					continue
				_dispatched += 1
				var jumped: String = _command(instr)
				if jumped != "":
					return _outcome(LclOutcome.ABORT, jumped, line, steps)
			_:
				return _outcome(LclOutcome.ABORT,
					"unknown instruction kind '%s'" % kind, line, steps)
	# Unreachable: every arm above returns or continues.
	return _outcome(LclOutcome.ABORT, "the loop fell through", 0, steps)


func _outcome(kind: String, reason: String, line: int,
		steps: int) -> LclOutcome:
	var out: LclOutcome = LclOutcome.new()
	out.kind = kind
	out.reason = reason
	out.line = line
	out.steps = steps
	out.dispatched = _dispatched
	out.events = _events
	return out


func _line(pos: int) -> int:
	if pos >= 0 and pos < _program.instructions.size():
		var instr: Dictionary = _program.instructions[pos]
		return DictRead.as_int(instr["line"])
	return _last_line()


func _last_line() -> int:
	if _program.instructions.is_empty():
		return 0
	var instr: Dictionary = _program.instructions[-1]
	return DictRead.as_int(instr["line"])


func _event(name: String, values: Array) -> void:
	_events.append({"name": name, "values": values.duplicate()})


# --- parameter access -------------------------------------------------------
# docs/20 section 3.2: three separate arrays, pre-filled with -1 and "". That is
# why calling a command with fewer arguments than its handler reads is well
# defined rather than undefined.

static func _n(instr: Dictionary, i: int) -> int:
	var numbers: PackedInt32Array = instr["num"]
	return numbers[i] if i < numbers.size() else LclEnv.LOCAL_INITIAL


static func _s(instr: Dictionary, i: int) -> String:
	var strings: PackedStringArray = instr["str"]
	return strings[i] if i < strings.size() else ""


static func _v(instr: Dictionary, i: int) -> int:
	var variables: PackedInt32Array = instr["var"]
	return variables[i] if i < variables.size() else LclEnv.LOCAL_INITIAL


func _get_local(slot: int) -> int:
	if slot < 0 or slot >= LclEnv.LOCAL_SLOTS:
		return LclEnv.LOCAL_INITIAL
	return _local[slot]


func _set_local(slot: int, value: int) -> void:
	if slot >= 0 and slot < LclEnv.LOCAL_SLOTS:
		_local[slot] = value


func _get_env(slot: int) -> int:
	if slot < 0 or slot >= LclEnv.ENV_SLOTS:
		return 0
	return _env[slot]


# --- predicates -- docs/20 section 7.4 --------------------------------------

func _predicate(instr: Dictionary) -> bool:
	var name: String = DictRead.as_string(instr["name"])
	match name:
		"EnvVarCmpNum":
			return _get_env(_v(instr, 0)) == _n(instr, 0)
		"EnvVarLowerNum":
			return _get_env(_v(instr, 0)) < _n(instr, 0)
		"EnvVarGreaterNum":
			return _get_env(_v(instr, 0)) > _n(instr, 0)
		"VarCmpNum":
			return _get_local(_v(instr, 0)) == _n(instr, 0)
		"VarLowerNum":
			return _get_local(_v(instr, 0)) < _n(instr, 0)
		"VarGreaterNum":
			return _get_local(_v(instr, 0)) > _n(instr, 0)
		"VarCmpVar":
			return _get_local(_v(instr, 0)) == _get_local(_v(instr, 1))
		"CheckCurrentTurn":
			# **A range on the turn number, not a test on the player.** The
			# name reads like the latter and the arguments are `(low, high)`.
			return _n(instr, 0) <= _context.turn.turn \
				and _context.turn.turn <= _n(instr, 1)
		"HeroKilled":
			var slot: int = _n(instr, 0)
			if slot < 0 or slot >= _context.turn.hero_killed.size():
				return false
			return _context.turn.hero_killed[slot] != 0
		"GroupOnField":
			var standing: UnitState = _context.unit_on(_n(instr, 1),
				_n(instr, 2))
			return standing != null and standing.group == _n(instr, 0)
		"UnitOnField":
			return _on_field(instr, false)
		"MechOnField":
			return _on_field(instr, true)
		"NoUnitOnField":
			# **Two arguments, and they are the cell.** Not the negation of
			# `UnitOnField`: this one takes no player and does not look at the
			# species, so a crate on the tile makes it false.
			return _context.unit_on(_n(instr, 0), _n(instr, 1)) == null
		"GameControlCmpNum":
			var slot: int = _n(instr, 0)
			return slot >= 0 and slot < GameControl.SLOTS \
				and _context.control.get_slot(slot) == _n(instr, 1)
		_:
			# docs/20 section 7.1: an unmatched name makes the dispatcher
			# return "not found", which aborts. Reported, never silently false:
			# a silent false looks like a working script.
			_abort = "unknown predicate '%s'" % name
			return false


## `UnitOnField (player, x, y)` and `MechOnField (player, x, y)` -- one test on
## **one cell**, with two species rules.
##
## docs/20 section 7.4: the first **excludes** objects and machines, the second
## **requires** a machine. A player of 254 matches any. Neither scans the map:
## they ask what is standing on the tile the arguments name, which is why the
## coordinates are arguments 2 and 3 and the player is argument 1.
func _on_field(instr: Dictionary, want_machine: bool) -> bool:
	var unit: UnitState = _context.unit_on(_n(instr, 1), _n(instr, 2))
	if unit == null:
		return false
	var species: int = _context.types.species(unit.type_id)
	if want_machine:
		if species != SPECIES_MACHINE:
			return false
	elif species == SPECIES_OBJECT or species == SPECIES_MACHINE:
		return false
	var player: int = _n(instr, 0)
	return player == PLAYER_ANY or unit.player == player


# --- commands -- docs/20 section 7.4 ----------------------------------------
#
# A handler returns "" normally, or an abort reason. Three groups:
#
#   * **state** -- the effect is in what [LclContext] holds, and is applied;
#   * **set piece** -- the documented *state change* is applied and the
#     animation is recorded as an event, which is this stage's declared
#     deviation: the effect is instant and the movement is not drawn;
#   * **presentation** -- camera, sound and GUI: recorded, never simulated.

func _command(instr: Dictionary) -> String:
	var name: String = DictRead.as_string(instr["name"])
	match name:
		# --- flow ---------------------------------------------------------
		"Goto":
			# `0x00440E00` -- rescan from byte 0, first match wins, missing
			# aborts. The label instruction is a no-op, so landing on it is the
			# same as landing after it.
			var target: String = _s(instr, 0)
			if not _program.labels.has(target):
				return "Goto to a missing label '%s'" % target
			_pos = DictRead.as_int(_program.labels[target])
		# --- variables ----------------------------------------------------
		"SetVarNum":
			_set_local(_v(instr, 0), _n(instr, 0))
		"SetVarVar":
			# **Broken as shipped** -- docs/20 section 8.2. `0x00440750`
			# indexes the local array with the second *numeric* argument
			# instead of the second *variable* argument, so `SetVarVar (_A,_B)`
			# reads `local[-1]` -- the missing number -- rather than `local[1]`.
			# Reproduced: a remake that "fixes" it changes the one shipped
			# call's result.
			_set_local(_v(instr, 0), _get_local(_n(instr, 1)))
		"SetVarRandom":
			# `0x004407D0` -- `aRandom(0, n)`, i.e. uniform in `0 .. n-1`.
			_set_local(_v(instr, 0), _context.rng.draw(0, _n(instr, 0)))
		"VarAddNum":
			_set_local(_v(instr, 0), _get_local(_v(instr, 0)) + _n(instr, 0))
		"VarSubNum":
			_set_local(_v(instr, 0), _get_local(_v(instr, 0)) - _n(instr, 0))
		"VarAddVar":
			_set_local(_v(instr, 0),
				_get_local(_v(instr, 0)) + _get_local(_v(instr, 1)))
		"VarSubVar":
			_set_local(_v(instr, 0),
				_get_local(_v(instr, 0)) - _get_local(_v(instr, 1)))
		# --- map cells ----------------------------------------------------
		"GetActPt":
			if _context.in_bounds(_n(instr, 0), _n(instr, 1)):
				_set_local(_v(instr, 0), _context.state.action_point_at(
					_context.index(_n(instr, 0), _n(instr, 1))))
		"SetActPt":
			# `0x00442A40` writes a **byte**, so the two-argument form stores
			# 255: `_C_120.lcl:66`'s `SetActPt (14,16);` leaves the third
			# argument at -1, and `(byte)(-1)` is 255. Masking here rather than
			# at the reader is what makes that come out right.
			if _context.in_bounds(_n(instr, 0), _n(instr, 1)):
				_context.state.set_action_point(
					_context.index(_n(instr, 0), _n(instr, 1)),
					_n(instr, 2) & 0xFF)
		"GetCtrlMapType":
			if _context.in_bounds(_n(instr, 0), _n(instr, 1)):
				_set_local(_v(instr, 0), _context.state.field_type_at(
					_context.index(_n(instr, 0), _n(instr, 1))))
		"SetCtrlMapType":
			if _context.in_bounds(_n(instr, 0), _n(instr, 1)):
				_context.state.set_field_type(
					_context.index(_n(instr, 0), _n(instr, 1)),
					_n(instr, 2) & 0xFF)
		"GetHeight":
			# C's integer division, truncated **toward zero**: 1844 shipped
			# cells carry a negative height, and a floor would give a different
			# level for every one of them.
			if _context.in_bounds(_n(instr, 0), _n(instr, 1)):
				_set_local(_v(instr, 0), IncInt.div_trunc(
					_context.state.height_at(
						_context.index(_n(instr, 0), _n(instr, 1))),
					LclEnv.HEIGHT_LEVEL_UNITS))
		"SetHeight":
			if _context.in_bounds(_n(instr, 0), _n(instr, 1)):
				_context.state.set_height(
					_context.index(_n(instr, 0), _n(instr, 1)),
					_n(instr, 2) * LclEnv.HEIGHT_LEVEL_UNITS)
				_event("land_object_height",
					[_n(instr, 0), _n(instr, 1), _n(instr, 2)])
		# --- queries ------------------------------------------------------
		"GetTurn":
			_set_local(_v(instr, 0), _context.turn.turn)
		"GetPlayer":
			_set_local(_v(instr, 0), _context.player)
		"GetUnits":
			_set_local(_v(instr, 0), _count_units(_n(instr, 0), -1, 0, 0, 0, 0,
				false))
		"GetUnitsInArea":
			# `0x00478000` -- inclusive rectangle; a player of -1 matches any.
			_set_local(_v(instr, 0), _count_units(_n(instr, 0), -1,
				_n(instr, 1), _n(instr, 2), _n(instr, 3), _n(instr, 4), true))
		"GetGroupsInArea":
			# `0x004780A0` -- the same loop on the group id, despite the name.
			_set_local(_v(instr, 0), _count_units(-2, _n(instr, 0),
				_n(instr, 1), _n(instr, 2), _n(instr, 3), _n(instr, 4), true))
		"GetUnitsInGroup":
			_set_local(_v(instr, 0), _count_units(-2, _n(instr, 0), 0, 0, 0, 0,
				false))
		# --- units --------------------------------------------------------
		"InsertUnit":
			return _insert_unit(instr)
		"InsertUnitWithGroup":
			# `0x004419D0` -- exactly one unit, then its group id.
			if _spawn_refused(_n(instr, 4), _n(instr, 5)):
				return ""
			var made: UnitState = _context.spawn(_n(instr, 0), _n(instr, 1),
				_s(instr, 0), _n(instr, 2), _n(instr, 3), _n(instr, 4),
				_n(instr, 5))
			if made != null:
				made.group = _n(instr, 6)
		"SetAmmoForUnit":
			# `0x00441710` -- takes a **tile**, and sets that unit's ammo to 0.
			var on_tile: UnitState = _context.unit_on(_n(instr, 0),
				_n(instr, 1))
			if on_tile != null:
				on_tile.ammo = 0
		"LinkChrWithGroup":
			for key: Variant in _context.units:
				var unit: UnitState = _context.units[key]
				if unit.is_alive() and unit.group == _n(instr, 0):
					unit.speech = _n(instr, 1)
		"RoofUnit":
			# `0x00442030` -- drop one computer unit onto a free tile.
			if _context.free_cell(_n(instr, 0), _n(instr, 1)):
				_context.spawn(PLAYER_COMPUTER, _n(instr, 3), "", 0, 0,
					_n(instr, 0), _n(instr, 1))
				_event("roof_unit", [_n(instr, 0), _n(instr, 1), _n(instr, 2),
					_n(instr, 3)])
		"GroundUnit":
			return _ground_unit(instr)
		"Spores":
			# `0x00441FF0` -- hatch one computer unit on every tile in range.
			for cell: int in _context.cells_with_actpt(_n(instr, 0),
					_n(instr, 1)):
				_context.state.set_action_point(cell, 0)
				_context.spawn(PLAYER_COMPUTER, _n(instr, 2), "", 0, 0,
					cell % _context.state.width, cell / _context.state.width)
		# --- game control and mission flow --------------------------------
		"SetGameControl":
			_context.control.set_slot(_n(instr, 0), _n(instr, 1))
		"IncGameControl":
			_context.control.increment(_n(instr, 0), _n(instr, 1))
		"EnterNameOfNextMap":
			_context.next_map = _s(instr, 0)
		"SetTurnControl":
			# `0x004418B0` -- one argument into `0x0043BE00`; role
			# **UNVERIFIED**. Stored rather than dropped so a later capture has
			# something to compare.
			_context.turn.turn_control = _n(instr, 0)
		"BuildVisibleMap":
			_event("build_visible_map",
				[_context.player if _n(instr, 0) == -1 else _n(instr, 0)])
		_:
			return _set_piece(instr, name)
	return ""


func _count_units(player: int, group: int, x1: int, y1: int, x2: int, y2: int,
		in_area: bool) -> int:
	var n: int = 0
	for key: Variant in _context.units:
		var unit: UnitState = _context.units[key]
		if not unit.is_alive():
			continue
		# `player == -2` means "match on the group instead"; `-1` means any
		# player. The two sentinels are the engine's own: `GetUnitsInArea`
		# tests `player != -1` and the group forms never look at the player.
		if player == -2:
			if unit.group != group:
				continue
		elif player != -1 and unit.player != player:
			continue
		if in_area and not (x1 <= unit.x and unit.x <= x2
				and y1 <= unit.y and unit.y <= y2):
			continue
		n += 1
	return n


## `InsertUnit (player, type, "name", rank, poolFlag, x, y, maxCount)`.
func _insert_unit(instr: Dictionary) -> String:
	if _spawn_refused(_n(instr, 4), _n(instr, 5)):
		return ""
	for _i: int in range(_insert_count(_n(instr, 6))):
		_context.spawn(_n(instr, 0), _n(instr, 1), _s(instr, 0),
			_n(instr, 2), _n(instr, 3), _n(instr, 4), _n(instr, 5))
	_event("build_visible_map", [_context.player])
	return ""


## Step 1 of `0x004418C0` -- an ActPt of 71 refuses the spawn outright.
func _spawn_refused(x: int, y: int) -> bool:
	return _context.in_bounds(x, y) \
		and _context.state.action_point_at(_context.index(x, y)) \
			== ACTPT_NO_SPAWN


## `0x004418C0` step 2 -- how many units one `InsertUnit` spawns.
##
## `max_count == 0` means exactly one. Otherwise the draw is the **C runtime's**
## `rand()`, not `aRandom`, and the bound is exclusive on easy and normal and
## inclusive on hard -- so `InsertUnit (..., 1)` spawns nothing except on hard,
## and the six short call sites, whose `maxCount` reads as -1, spawn nothing
## except on hard.
func _insert_count(max_count: int) -> int:
	if max_count == 0:
		return 1
	match _context.turn.ai_level:
		0:
			var span: int = max_count - 1 if max_count >= 3 else max_count
			return 0 if span <= 0 else _context.crand.draw() % span
		1:
			return 0 if max_count <= 0 else _context.crand.draw() % max_count
		2:
			return (0 if max_count <= 0
				else _context.crand.draw() % max_count) + 1
		_:
			# `incorrect ai level!` -- the engine's own path, which spawns
			# nothing.
			return 0


## `0x00442150` -- burst out at `(x2,y2)`, leaving a hole at `(x1,y1)`.
func _ground_unit(instr: Dictionary) -> String:
	var x1: int = _n(instr, 0)
	var y1: int = _n(instr, 1)
	var x2: int = _n(instr, 2)
	var y2: int = _n(instr, 3)
	if not (_context.free_cell(x1, y1) and _context.free_cell(x2, y2)):
		return ""
	_context.spawn(PLAYER_COMPUTER, _n(instr, 4), "", 0, 0, x2, y2)
	_context.state.set_field_type(_context.index(x1, y1), CTRL_TYPE_DEEP_HOLE)
	_event("ground_unit", [x1, y1, x2, y2, _n(instr, 4)])
	return ""


# --- set pieces and presentation ---------------------------------------------

## The rest of the table. Split from [method _command] because GDScript's
## `match` is a linear ladder either way and one 60-arm function is unreadable;
## the split is alphabetically arbitrary and carries no meaning.
func _set_piece(instr: Dictionary, name: String) -> String:
	match name:
		"Platform":
			_platform(instr)
		"Elevator":
			# `0x00442590` -- `steps * 5` height levels up (dir 0) or down (1).
			var direction: int = _n(instr, 2)
			if _context.in_bounds(_n(instr, 0), _n(instr, 1)) \
					and (direction == 0 or direction == 1):
				var at: int = _context.index(_n(instr, 0), _n(instr, 1))
				var delta: int = _n(instr, 3) * ELEVATOR_STEP \
					* (1 if direction == 0 else -1)
				_context.state.set_height(at,
					_context.state.height_at(at) + delta)
				_event("elevator", [_n(instr, 0), _n(instr, 1), direction,
					_n(instr, 3)])
		"Barrier":
			_barrier(instr)
		"FixedStatue":
			_fixed_statue(instr)
		"FootBridge":
			_foot_bridge(instr)
		"FootBridge2":
			_foot_bridge2(instr)
		"Statue":
			_event("statue", [_n(instr, 0), _n(instr, 1)])
		"Statue2":
			_event("statue2", [_n(instr, 0), _n(instr, 1),
				_context.cells_with_actpt(_n(instr, 0), _n(instr, 1)).size()])
		"GrowingLand":
			_growing_land(instr)
		"FallingSpores":
			_falling_spores(instr)
		"SetGroundFire":
			_set_ground_fire(instr)
		"ParaBombs":
			_para_bombs(instr)
		"OpenDoor":
			# `0x004420C0` -- **does nothing** when a unit stands on the tile.
			if _context.unit_on(_n(instr, 0), _n(instr, 1)) == null:
				_event("open_door", [_n(instr, 0), _n(instr, 1)])
		"OpenTube":
			_event("open_tube", [_n(instr, 0), _n(instr, 1)])
		"OpenPlantTube":
			_event("open_plant_tube", [_n(instr, 0), _n(instr, 1)])
		"OpenFrontDoor":
			_event("open_front_door", [_n(instr, 0), _n(instr, 1)])
		"CrushWall":
			_event("crush_wall", [_n(instr, 0), _n(instr, 1)])
		"Bridge":
			_event("bridge", [_n(instr, 0), _n(instr, 1)])
		"FireCircle":
			_event("fire_circle", [_n(instr, 0), _n(instr, 1)])
		"MoveObjects":
			_actpt_range(instr, "move_objects")
		"MoveFireCircles":
			_actpt_range(instr, "move_fire_circles")
		"MoveSpores":
			_actpt_range(instr, "move_spores")
		# --- presentation: camera, sound, effects, dialogs -----------------
		"MoveCamera":
			_record(instr, "move_camera", 5)
		"MoveTarget":
			_record(instr, "move_target", 2)
		"MovePosition":
			_record(instr, "move_position", 3)
		"MoveWorld":
			_record(instr, "move_world", 10)
		"RotatingCamera":
			_record(instr, "rotating_camera", 3)
		"CreateCameraPath":
			_record(instr, "create_camera_path", 5)
		"SaveCamera":
			_record(instr, "save_camera", 0)
		"LoadCamera":
			_record(instr, "load_camera", 0)
		"CreateBGB":
			_record(instr, "create_bgb", 8)
		"NewCommands":
			_record(instr, "new_commands", 5)
		"SelectNextUnit":
			_record(instr, "select_next_unit", 0)
		"SetVolumeCtrl":
			_record(instr, "set_volume_ctrl", 2)
		"CDTrackProgram":
			_record_str(instr, "cd_track_program")
		"ActivateInfo":
			_record_str(instr, "activate_info")
		"ActivateInfoSuccessor":
			_record_str(instr, "activate_info_successor")
		"Dialog":
			_record_str(instr, "dialog")
		"EndDialog":
			_record(instr, "end_dialog", 0)
		"Message", "PrintAllVars":
			# A bare call to the reporter, which is an empty stub in the
			# release build.
			pass
		"?_":
			_record(instr, "unit_draw_path", 1)
		"OBJ":
			_record_str(instr, "obj")
		# The balance-table loaders. docs/21 owns them and the cache is what
		# applies them; a mission script never calls one, and `Info.lcl` is not
		# run by this interpreter at all.
		"SetUnitInfo":
			_record_str(instr, "set_unit_info")
		"SetWeaponInfo":
			_record_str(instr, "set_weapon_info")
		"SetWeaponInfo2":
			_record_str(instr, "set_weapon_info2")
		"SetEquipInfo":
			_record_str(instr, "set_equip_info")
		"SetCtrlMapInfo":
			_record_str(instr, "set_ctrl_map_info")
		"SetCharismaInfo":
			_record_str(instr, "set_charisma_info")
		# The GUI layout family: pure pass-throughs into `aGUI`'s builders,
		# which no mission script calls.
		"GUI_SetWindow":
			_record(instr, "gui_set_window", 4)
		"GUI_SetText":
			_record(instr, "gui_set_text", 11)
		"GUI_SetButton":
			_record(instr, "gui_set_button", 8)
		"GUI_SetTextButton":
			_record(instr, "gui_set_text_button", 7)
		"GUI_SetIcon":
			_record(instr, "gui_set_icon", 4)
		"GUI_SetListbox":
			_record(instr, "gui_set_listbox", 7)
		"GUI_SetTextOnly":
			_record(instr, "gui_set_text_only", 7)
		"GUI_SetTextOnly2":
			_record(instr, "gui_set_text_only2", 7)
		"GUI_SetTextbox":
			_record(instr, "gui_set_textbox", 1)
		"GUI_LoadBackground":
			_record_str(instr, "gui_load_background")
		"GUI_PrintBackground":
			_record(instr, "gui_print_background", 0)
		"GUI_Render":
			_record(instr, "gui_render", 0)
		_:
			# docs/20 section 7.1 again: a command with no entry aborts the
			# invocation, and naming it is the difference between a check that
			# says which command is missing and one that says nothing.
			return "unknown command '%s'" % name
	return ""


func _record(instr: Dictionary, name: String, count: int) -> void:
	var values: Array = []
	for i: int in range(count):
		values.append(_n(instr, i))
	_event(name, values)


func _record_str(instr: Dictionary, name: String) -> void:
	_event(name, [_s(instr, 0)])


func _actpt_range(instr: Dictionary, name: String) -> void:
	_event(name, [_n(instr, 0), _n(instr, 1),
		_context.cells_with_actpt(_n(instr, 0), _n(instr, 1)).size()])


## `0x004422B0` -- move the 3x3 block `dist` tiles, leaving deep holes.
##
## docs/20 section 7.4 pins the arguments arithmetically off `_C_105.lcl`'s
## there-and-back pairs: `(x,y)` is the platform's centre **before** the move
## and `dist` is a distance in tiles, not an identifier.
##
## The copy reads each source after possibly writing an earlier one, which would
## be wrong if the two 3x3 blocks overlapped. They cannot: the smallest shipped
## `dist` is **3** (the corpus spans 3..16), and 3 already separates them. A
## mission with `dist` 1 or 2 would need the nine cells buffered first, and
## would need the engine's own copy order -- a native probe, not a guess.
func _platform(instr: Dictionary) -> void:
	var direction: int = _n(instr, 2)
	if direction < 0 or direction >= DIR_PLATFORM_DX.size():
		return
	var x: int = _n(instr, 0)
	var y: int = _n(instr, 1)
	var dist: int = _n(instr, 3)
	var dx: int = DIR_PLATFORM_DX[direction] * dist
	var dy: int = DIR_PLATFORM_DY[direction] * dist
	var moved: int = 0
	for oy: int in [-1, 0, 1]:
		for ox: int in [-1, 0, 1]:
			var sx: int = x + ox
			var sy: int = y + oy
			if not (_context.in_bounds(sx, sy)
					and _context.in_bounds(sx + dx, sy + dy)):
				continue
			var src: int = _context.index(sx, sy)
			var dst: int = _context.index(sx + dx, sy + dy)
			_context.state.set_height(dst, _context.state.height_at(src))
			_context.state.set_field_type(dst,
				_context.state.field_type_at(src))
			var rider: UnitState = _context.unit_on(sx, sy)
			_context.state.set_unit(dst, _context.state.unit_at(src))
			if rider != null:
				rider.x = sx + dx
				rider.y = sy + dy
			_context.state.set_unit(src, MapState.NO_UNIT)
			_context.state.set_field_type(src, CTRL_TYPE_DEEP_HOLE)
			moved += 1
	_event("platform", [x, y, direction, dist, moved])


## `0x004423D0` -- a toggle keyed on the emitter tile's own ActPt.
##
## Seeded only when the ActPt is 0, so a barrier seeded with the "on" value is
## switched **off** by its first call. All 164 shipped sites use 90/91.
func _barrier(instr: Dictionary) -> void:
	var x: int = _n(instr, 0)
	var y: int = _n(instr, 1)
	if not _context.in_bounds(x, y):
		return
	var cell: int = _context.index(x, y)
	var on: int = _n(instr, 3)
	if _context.state.action_point_at(cell) == 0:
		_context.state.set_action_point(cell, _n(instr, 5) & 0xFF)
	if _context.state.action_point_at(cell) == on:
		_context.state.set_action_point(cell, _n(instr, 4) & 0xFF)
		_event("barrier_off", [x, y])
		return
	_context.state.set_action_point(cell, on & 0xFF)
	var direction: int = _n(instr, 2)
	var killed: int = 0
	if direction >= 0 and direction < DIR_BARRIER_DX.size():
		var bx: int = x + DIR_BARRIER_DX[direction]
		var by: int = y + DIR_BARRIER_DY[direction]
		while _context.in_bounds(bx, by) and _context.state.field_type_at(
				_context.index(bx, by)) != CTRL_TYPE_WALL:
			var victim: UnitState = _context.unit_on(bx, by)
			if victim != null:
				_context.kill(victim)
				killed += 1
			bx += DIR_BARRIER_DX[direction]
			by += DIR_BARRIER_DY[direction]
	_event("barrier_on", [x, y, direction, killed])


## `0x00442370` -- up to ten cells along `dir`; the first unit dies.
func _fixed_statue(instr: Dictionary) -> void:
	var direction: int = _n(instr, 2)
	if direction < 0 or direction >= DIR_BARRIER_DX.size():
		return
	var cx: int = _n(instr, 0)
	var cy: int = _n(instr, 1)
	for _i: int in range(STATUE_REACH):
		cx += DIR_BARRIER_DX[direction]
		cy += DIR_BARRIER_DY[direction]
		if not _context.in_bounds(cx, cy):
			return
		if _context.state.field_type_at(_context.index(cx, cy)) \
				== CTRL_TYPE_WALL:
			return
		var victim: UnitState = _context.unit_on(cx, cy)
		if victim != null:
			_context.kill(victim)
			_event("fixed_statue_kill", [cx, cy])
			return


## `0x00442650` -- collapses only when **more than** `minUnits` stand on it.
func _foot_bridge(instr: Dictionary) -> void:
	var x: int = _n(instr, 0)
	var y: int = _n(instr, 1)
	var standing: int = 0
	var block: PackedInt32Array = PackedInt32Array()
	for oy: int in [-1, 0, 1]:
		for ox: int in [-1, 0, 1]:
			if not _context.in_bounds(x + ox, y + oy):
				continue
			block.append(_context.index(x + ox, y + oy))
			if _context.unit_on(x + ox, y + oy) != null:
				standing += 1
	if standing <= _n(instr, 3):
		return
	for cell: int in block:
		_context.state.set_field_type(cell, CTRL_TYPE_DEEP_HOLE)
	_event("foot_bridge", [x, y, _n(instr, 2), standing])


## `0x004426D0` -- nothing happens unless the turn number matches exactly.
func _foot_bridge2(instr: Dictionary) -> void:
	if _context.turn.turn != _n(instr, 2):
		return
	var hit: int = 0
	for cell: int in _context.cells_with_actpt(_n(instr, 0), _n(instr, 0)):
		_context.state.set_field_type(cell, CTRL_TYPE_DEEP_HOLE)
		_context.state.set_action_point(cell, 0)
		hit += 1
	_event("foot_bridge2", [_n(instr, 0), _n(instr, 1), hit])


## `0x00442010` -- grow into a random free neighbour of each tagged tile.
##
## The new tile inherits the ActPt and becomes a wall. `0x00407410` refuses once
## the scene holds 141 objects; the scene object count is outside this model, so
## the refusal is a recorded deviation rather than a guess.
func _growing_land(instr: Dictionary) -> void:
	var actpt: int = _n(instr, 0)
	var grown: int = 0
	for cell: int in _context.cells_with_actpt(actpt, actpt):
		var cx: int = cell % _context.state.width
		var cy: int = cell / _context.state.width
		var free: PackedInt32Array = PackedInt32Array()
		for dy: int in [-1, 0, 1]:
			for dx: int in [-1, 0, 1]:
				if dx == 0 and dy == 0:
					continue
				if _context.free_cell(cx + dx, cy + dy):
					free.append(_context.index(cx + dx, cy + dy))
		if free.is_empty():
			continue
		var target: int = free[_context.rng.draw(0, free.size())]
		_context.state.set_action_point(target, actpt & 0xFF)
		_context.state.set_field_type(target, CTRL_TYPE_WALL)
		grown += 1
	_event("growing_land", [actpt, _s(instr, 0), grown])


## `0x00441F60` -- `count` drops on random tiles of the `w x h` block.
func _falling_spores(instr: Dictionary) -> void:
	var actpt: int = _n(instr, 5)
	for _i: int in range(maxi(_n(instr, 4), 0)):
		var tx: int = _context.rng.draw(_n(instr, 0), _n(instr, 2))
		var ty: int = _context.rng.draw(_n(instr, 1), _n(instr, 3))
		if not _context.in_bounds(tx, ty):
			continue
		var cell: int = _context.index(tx, ty)
		_context.state.set_field_type(cell, CTRL_TYPE_WALL)
		_context.state.set_action_point(cell, actpt & 0xFF)
	_event("falling_spores", [_n(instr, 0), _n(instr, 1), _n(instr, 2),
		_n(instr, 3), _n(instr, 4), actpt, _s(instr, 0)])


## `0x00442730` -- `tries` attempts at a tile of the right type and height.
func _set_ground_fire(instr: Dictionary) -> void:
	var level: int = _n(instr, 2)
	var lit: int = 0
	for _i: int in range(maxi(_n(instr, 5), 0)):
		var tx: int = _context.rng.draw(_n(instr, 0), _n(instr, 3))
		var ty: int = _context.rng.draw(_n(instr, 1), _n(instr, 4))
		if not _context.in_bounds(tx, ty):
			continue
		var cell: int = _context.index(tx, ty)
		var kind: int = _context.state.field_type_at(cell)
		if (kind == 0 or kind == 1) and _context.state.height_at(cell) \
				== level * LclEnv.HEIGHT_LEVEL_UNITS:
			lit += 1
	_event("set_ground_fire", [_n(instr, 0), _n(instr, 1), level, _n(instr, 3),
		_n(instr, 4), _n(instr, 5), lit])


## `0x00442270` -- the fly-past, then **60** attempts to lay a mine.
##
## A mine is cell `+0x10 = 2`, which this command does not write: laying one is
## the effect object's, and the attempts are drawn here because they advance the
## generator and a later capture will compare the stream.
func _para_bombs(instr: Dictionary) -> void:
	var tiles: int = 0
	for _i: int in range(PARA_BOMB_TRIES):
		var tx: int = _context.rng.draw(_n(instr, 0), _n(instr, 2))
		var ty: int = _context.rng.draw(_n(instr, 1), _n(instr, 3))
		if _context.in_bounds(tx, ty) and _context.unit_on(tx, ty) == null:
			tiles += 1
	_event("para_bombs", [_n(instr, 0), _n(instr, 1), _n(instr, 2),
		_n(instr, 3), tiles])
