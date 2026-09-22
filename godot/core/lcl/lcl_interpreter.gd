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
## `0x00415D66` -- `CrushWall` marks its footprint with this field type.
const CTRL_TYPE_FREE_PLACE: int = 1
const CTRL_TYPE_DEEP_HOLE: int = 4
## `Elevator` moves five height levels per step.
const ELEVATOR_STEP: int = 800
## `ParaBombs` makes exactly this many attempts to lay a mine.
const PARA_BOMB_TRIES: int = 60
## `FixedStatue` reaches at most this far -- `0x00414164`, `cmp eax, 0xa`.
const STATUE_REACH: int = 10
## `Statue` reaches at most this far, each way -- `0x00413C97`,
## `cmp dword [esp+0x3c], 6`.
const STATUE_BEAM_REACH: int = 6

## docs/20 sections 2.3 and 7.4 -- the two directions a set piece can be given,
## which do **not** agree on the north/south axis. Keeping both spellings is the
## point: folding them into one is the trap the doc calls out. `Platform`'s is
## [constant Platform.DIR_DX] / [constant Platform.DIR_DY].
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
			#
			# The `& 0xFF` is **redundant in this implementation and stays**:
			# `MapState` keeps action points in a `PackedByteArray`, which
			# wraps on assignment, so removing it is an equivalent mutation and
			# no check looks for one. It is written because the *rule* is the
			# engine's byte store and not Godot's container -- a `MapState`
			# that ever widened that array would otherwise change what a script
			# means.
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
			# **A bare equality**, and not [method _count_units]'s `-1` "any
			# player" sentinel: `_n` answers -1 for a missing operand, so
			# routing this through the sentinel made `GetUnits (_A);` count the
			# aliens and the props. `inclib/lcl_runtime.py` compares directly.
			var counted: int = 0
			for key: Variant in _context.units:
				var one: UnitState = _context.units[key]
				if one.is_alive() and one.player == _n(instr, 0):
					counted += 1
			_set_local(_v(instr, 0), counted)
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
##
## **The draw is unconditional whenever `max_count` is not zero**, including the
## arms whose result can only be 0: all three of `0x00441942`, `0x0044195C` and
## `0x0044194E` reach `call [0x5255FC]` before the `idiv` with no guard in
## front of it. Short-circuiting them desynchronises the stream against the
## engine -- `_C_116` fires its six short sites on turn 8 and another
## `InsertUnit` on every turn after.
func _insert_count(max_count: int) -> int:
	if max_count == 0:
		return 1
	var level: int = _context.turn.ai_level
	if level < 0 or level > 2:
		# `incorrect ai level!` -- the engine's own path, which spawns nothing
		# and, having branched before the call, draws nothing either.
		return 0
	# `cmp esi, 2 / jle` at `0x0044194e`: easy takes the normal arm outright
	# below 3 and otherwise divides by one less.
	var divisor: int = max_count - 1 if level == 0 and max_count > 2 else max_count
	# The dividend is `rand()` and never negative, so the remainder is the
	# plain modulus against the divisor's magnitude -- a divisor of -1, which
	# is what the six short call sites' missing argument reads as, can only
	# yield 0.
	var count: int = _context.crand.draw() % absi(divisor)
	return count + 1 if level == 2 else count


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
			_statue(_n(instr, 0), _n(instr, 1))
		"Statue2":
			_statue2(_n(instr, 0), _n(instr, 1))
		"GrowingLand":
			_growing_land(instr)
		"FallingSpores":
			_falling_spores(instr)
		"SetGroundFire":
			_set_ground_fire(instr)
		"ParaBombs":
			_para_bombs(instr)
		"OpenDoor":
			_open_door(_n(instr, 0), _n(instr, 1))
		"OpenTube":
			_event("open_tube", [_n(instr, 0), _n(instr, 1)])
		"OpenPlantTube":
			_event("open_plant_tube", [_n(instr, 0), _n(instr, 1)])
		"OpenFrontDoor":
			_event("open_front_door", [_n(instr, 0), _n(instr, 1)])
		"CrushWall":
			_crush_wall(_n(instr, 0), _n(instr, 1))
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
## `0x00412A00` -- the ride is [method Platform.ride]: each rider is
## relocated through `0x0047AD90` and looks around from its new cell
## **before** the cells are copied, which is why this one command performs a
## fog pass the interpreter otherwise only records (docs/22 section 9.3).
func _platform(instr: Dictionary) -> void:
	var direction: int = _n(instr, 2)
	if direction < 0 or direction >= Platform.DIR_DX.size():
		return
	var x: int = _n(instr, 0)
	var y: int = _n(instr, 1)
	var dist: int = _n(instr, 3)
	var moved: int = Platform.ride(_context.state, _context.units,
		_context.types, x, y, direction, dist, _context.turn.human_count(),
		_context.turn.mode)
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
	# The victims ride on the event as `slot, x, y` each, in beam order:
	# `aPlayLaserBarrier` collects them into a forty-slot array as it walks
	# (`0x0041371B`) and flies to the middle one, `victims[n / 2]`
	# (`0x00413926`), and the picture cannot re-derive that from a map the
	# victims have already left (docs/42 section 8).
	var victims: Array = []
	if direction >= 0 and direction < DIR_BARRIER_DX.size():
		var bx: int = x + DIR_BARRIER_DX[direction]
		var by: int = y + DIR_BARRIER_DY[direction]
		while _context.in_bounds(bx, by) and _context.state.field_type_at(
				_context.index(bx, by)) != CTRL_TYPE_WALL:
			var victim: UnitState = _context.unit_on(bx, by)
			if victim != null:
				victims.append_array([victim.slot, victim.x, victim.y])
				_context.kill(victim)
			bx += DIR_BARRIER_DX[direction]
			by += DIR_BARRIER_DY[direction]
	var values: Array = [x, y, direction, victims.size() / 3]
	values.append_array(victims)
	_event("barrier_on", values)


## `0x00413A40`, `aPlayRotateStatueSequence` -- the rule half of the statue.
##
## The statue's own action-point byte toggles bit 0 (`0x00413C31`: an odd byte
## goes down by one, an even one up by one) and the **new** bit picks the axis
## -- 0 walks `+y`, 1 walks `+x` (`0x00413C5A`). The beam then runs both ways
## from the statue's cell, at most [constant STATUE_BEAM_REACH] cells each
## (`0x00413C97`, `cmp dword [esp+0x3c], 6`), and stops at the map edge, at a
## cell of field type 2, or at the **first** unit it meets: `0x00413D67`
## re-enters the loop only on the no-unit branch, which is why the routine has
## exactly two kill sites (`0x00413F4E`, `0x00413F94`). Each victim is booked
## as a loss (`0x0043B8D0`) and taken off the map by `aRemoveUnitElement`
## `0x004779C0`.
##
## The endpoint the beam is drawn to is the cell that stopped the walk. Running
## off the map leaves the engine with a null cell pointer there, so the remake
## draws to the last cell it did reach instead -- the remake's, and the only
## place this differs from the instructions.
func _statue(x: int, y: int) -> void:
	if not _context.in_bounds(x, y):
		return
	var cell: int = _context.index(x, y)
	var flipped: int = _context.state.action_point_at(cell)
	flipped = (flipped - 1) if (flipped & 1) != 0 else (flipped + 1)
	flipped &= 0xFF
	_context.state.set_action_point(cell, flipped)
	var axis: int = flipped & 1
	var dx: int = 1 if axis == 1 else 0
	var dy: int = 0 if axis == 1 else 1
	var victims: Array[UnitState] = [null, null]
	var forward: Vector3i = _statue_walk(x, y, dx, dy, victims, 0)
	var backward: Vector3i = _statue_walk(x, y, -dx, -dy, victims, 1)
	# Fifteen numbers, fixed width: the statue's cell, the axis the toggle
	# chose, each arm's endpoint and step count, and each arm's victim as
	# `slot, x, y` with `-1, -1, -1` for an arm that found nobody. The picture
	# cannot re-derive any of it -- the byte it would read has already been
	# toggled and the victims are already off the map by the time it runs.
	var values: Array[int] = [x, y, axis,
		forward.x, forward.y, forward.z,
		backward.x, backward.y, backward.z]
	for victim: UnitState in victims:
		if victim == null:
			values.append_array([-1, -1, -1])
		else:
			values.append_array([victim.slot, victim.x, victim.y])
	_event("statue", values)
	for victim: UnitState in victims:
		if victim == null:
			continue
		var vx: int = victim.x
		var vy: int = victim.y
		_context.kill(victim)
		_event("statue_kill", [vx, vy])


## One arm of [method _statue]. Returns the cell that stopped the walk and the
## number of cells stepped, and writes the one unit it found -- if it found
## one -- into `victims[arm]`.
func _statue_walk(x: int, y: int, dx: int, dy: int,
		victims: Array[UnitState], arm: int) -> Vector3i:
	var cx: int = x
	var cy: int = y
	var stepped: int = 0
	while stepped < STATUE_BEAM_REACH:
		var nx: int = cx + dx
		var ny: int = cy + dy
		if not _context.in_bounds(nx, ny):
			break
		if _context.state.field_type_at(_context.index(nx, ny)) \
				== CTRL_TYPE_WALL:
			return Vector3i(nx, ny, stepped)
		cx = nx
		cy = ny
		stepped += 1
		var victim: UnitState = _context.unit_on(cx, cy)
		if victim != null:
			victims[arm] = victim
			return Vector3i(cx, cy, stepped)
	return Vector3i(cx, cy, stepped)


## `0x004424B0` -> `0x00413500` -- the batch form: every cell whose action
## point falls in the inclusive range runs [method _statue]. The engine reads
## the byte fresh at each cell of a row-major sweep, and the toggle only ever
## touches the cell being processed, so the matched set is the one taken up
## front.
func _statue2(low: int, high: int) -> void:
	var cells: PackedInt32Array = _context.cells_with_actpt(low, high)
	_event("statue2", [low, high, cells.size()])
	for cell: int in cells:
		_statue(cell % _context.state.width, cell / _context.state.width)



## `aPlayCrushWallAnimation` `0x00415C70` -- the rule half, docs/42 section 8.2.
##
## Before it throws any debris the routine calls `0x0042F410(wall, 1, 0, 1)`,
## which sweeps the whole control map, casts four probes per cell from that
## cell's **own** symbol object -- `x` and `y` each 200 either way, from
## `z = 100000` -- against the wall's standard object, and for every cell a
## probe hits writes the height 0, the field type 1 (`Free Place`) and the
## state byte 2. The state byte goes back to 1 in the debris sweep
## (`0x00415DA4`), so what lasts is **the height and the field type**: a
## crushed wall becomes walkable floor at ground level.
##
## **The footprint is a query against the scene, and the converter runs it**
## (`inclib.footprint`, docs/97 section 50). The probe is vertical, so "the ray
## meets the object" is "the probe lies inside the `xy` projection of one of its
## faces", and the wall piece is a `.lev` special object naming a prototype
## whose mesh is in `prototyp.bin` -- so the sweep is arithmetic and it is done
## once, at conversion, rather than by either runtime. All nine shipped call
## sites come out cell for cell (docs/42 section 8.2).
##
## `core` reads the answer through [method LclContext.cells_of_object_at] and
## falls back to the command's own cell where nothing stands there -- which is
## what a hand-built context and an off-map command both give. The event carries
## what was changed so the picture throws its debris on exactly those cells.
## `0x004420C0` -- **does nothing** when a unit stands on the tile, and
## otherwise runs `aDoorOpenSequence` `0x00410A20`, which is a **toggle**
## (docs/26 section 3.4): an odd action point is a closed door and the call
## opens it -- field type `Free Place`, height 0, action point one lower --
## and an even one closes it again.
##
## The state write used to be missing here: only the animation event was
## recorded, so a lever wired to `OpenDoor` swung the panel's leaves and
## [method Scenery.apply_state] painted them shut again on the next frame,
## because the pose is a function of the cell's parity. `_C_116`'s three
## doors could not be opened at all.
##
## The rebuild of the visible map the routine ends with is **not** here:
## [LclInterpreter] owns no fog, so the event is acted on by
## [method World._run_mission_script], the way `InsertUnit`'s and
## `Elevator`'s are.
func _open_door(x: int, y: int) -> void:
	if _context.unit_on(x, y) != null:
		return
	if _context.in_bounds(x, y):
		Interact.toggle_door(_context.state, _context.index(x, y))
	_event("open_door", [x, y])


func _crush_wall(x: int, y: int) -> void:
	var values: Array[int] = [x, y]
	if _context.in_bounds(x, y):
		for at: int in _context.cells_of_object_at(_context.index(x, y)):
			_context.state.set_height(at, 0)
			_context.state.set_field_type(at, CTRL_TYPE_FREE_PLACE)
			values.append_array([at % _context.state.width,
				at / _context.state.width])
	_event("crush_wall", values)

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
##
## The event is `x, y, frames, standing` and then the riders' slots in the
## block's row-major order. `aPlayFootBridgeSequence` `0x00414A70` lists
## every unit on the nine cells before its loop and, after it, takes each
## one off the map through `aRemoveUnitElement` (`0x00414F8C`, `0x0043B8D0`
## then `0x004779C0`) -- and removal kills (docs/42 section 12, the closed
## item on `0x00477ABD`). The slots are carried because the map no longer
## knows who stood there once they are gone.
func _foot_bridge(instr: Dictionary) -> void:
	var x: int = _n(instr, 0)
	var y: int = _n(instr, 1)
	var riders: Array[UnitState] = []
	var block: PackedInt32Array = PackedInt32Array()
	for oy: int in [-1, 0, 1]:
		for ox: int in [-1, 0, 1]:
			if not _context.in_bounds(x + ox, y + oy):
				continue
			block.append(_context.index(x + ox, y + oy))
			var rider: UnitState = _context.unit_on(x + ox, y + oy)
			if rider != null:
				riders.append(rider)
	if riders.size() <= _n(instr, 3):
		return
	for cell: int in block:
		_context.state.set_field_type(cell, CTRL_TYPE_DEEP_HOLE)
	var values: Array = [x, y, _n(instr, 2), riders.size()]
	for rider: UnitState in riders:
		values.append(rider.slot)
	_event("foot_bridge", values)
	for rider: UnitState in riders:
		_context.kill(rider)


## `0x004426D0` -- nothing happens unless the turn number matches exactly.
##
## The event is `actpt, frames, hit`, then the `hit` matched cells as `x, y`
## pairs in the engine's own row-major scan order, then the riders' slots.
## `0x00415110` clears the group byte on each cell as it scans
## (`0x004151EB`), so the cells travel on the event for the picture to find
## the block -- `L069EI00` stands on one of the two -- and it removes every
## rider the way `FootBridge` does (`0x00415653`, `0x00415663`).
func _foot_bridge2(instr: Dictionary) -> void:
	if _context.turn.turn != _n(instr, 2):
		return
	var cells: PackedInt32Array = _context.cells_with_actpt(_n(instr, 0),
		_n(instr, 0))
	var riders: Array[UnitState] = []
	var values: Array = [_n(instr, 0), _n(instr, 1), cells.size()]
	for cell: int in cells:
		_context.state.set_field_type(cell, CTRL_TYPE_DEEP_HOLE)
		_context.state.set_action_point(cell, 0)
		var rider: UnitState = _context.unit_on(cell % _context.state.width,
			cell / _context.state.width)
		if rider != null:
			riders.append(rider)
	for cell: int in cells:
		values.append(cell % _context.state.width)
		values.append(cell / _context.state.width)
	for rider: UnitState in riders:
		values.append(rider.slot)
	_event("foot_bridge2", values)
	for rider: UnitState in riders:
		_context.kill(rider)


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
##
## What it lays is a **glow**, not a flame: `0x0042FCB0(x, y, 2)` writes
## `+0x11`, `+0x12` and `+0x13` and nothing else, so a fresh `SetGroundFire`
## blocks nobody.  The fuse is two hand-overs long -- the round tick decays the
## glow to phase 1 and the next round's sweep burns it, removing every unit the
## flames reach (docs/42 section 9.1).  The cell must carry no glow already,
## control-map type 0 or 1, and a height of exactly `level * 160`.
func _set_ground_fire(instr: Dictionary) -> void:
	var level: int = _n(instr, 2)
	var lit: Array[int] = []
	for _i: int in range(maxi(_n(instr, 5), 0)):
		var tx: int = _context.rng.draw(_n(instr, 0), _n(instr, 3))
		var ty: int = _context.rng.draw(_n(instr, 1), _n(instr, 4))
		if not _context.in_bounds(tx, ty):
			continue
		var cell: int = _context.index(tx, ty)
		var kind: int = _context.state.field_type_at(cell)
		if _context.state.effect_at(MapState.DECAL_STATE_SLOT, cell) \
				!= MapState.DECAL_NONE:
			continue
		if (kind == 0 or kind == 1) and _context.state.height_at(cell) \
				== level * LclEnv.HEIGHT_LEVEL_UNITS \
				and CellObjects.place_glow(_context.state, tx, ty,
					CellObjects.GLOW_PHASE_FRESH) >= 0:
			lit.append(tx)
			lit.append(ty)
	# The tiles ride on the event after the count, as `ParaBombs`' do: the
	# picture puts a glow on each and must not re-draw them.
	var values: Array[int] = [_n(instr, 0), _n(instr, 1), level, _n(instr, 3),
		_n(instr, 4), _n(instr, 5), lit.size() / 2]
	values.append_array(lit)
	_event("set_ground_fire", values)


## `0x00442270` -- the fly-past, then **60** attempts to lay a mine.
##
## `0x00470845` takes a cell with no unit on it and `+0x10 == 255` and calls the
## mine placer, which writes `+0x10 = 2` -- a rule the move map reads, so this
## one *is* the script layer's business (docs/23 section 7.3).
func _para_bombs(instr: Dictionary) -> void:
	var tiles: Array[int] = []
	for _i: int in range(PARA_BOMB_TRIES):
		var tx: int = _context.rng.draw(_n(instr, 0), _n(instr, 2))
		var ty: int = _context.rng.draw(_n(instr, 1), _n(instr, 3))
		if not _context.in_bounds(tx, ty):
			continue
		# `cmp word [eax + 7], 0xFFFF` -- the cell's unit **link**, so a slot
		# whose unit is dead still keeps the bomber off the tile.
		var cell: int = _context.index(tx, ty)
		if _context.state.unit_at(cell) >= 0:
			continue
		if _context.state.obstacle_at(cell) != MapState.OBSTACLE_NONE:
			continue
		if CellObjects.place_mine(_context.state, tx, ty) >= 0:
			tiles.append(tx)
			tiles.append(ty)
	# The tiles themselves ride on the event after the count: the picture
	# (docs/42 section 8) drops one bomb on each, and re-drawing them there
	# would move the generator a second time.
	var values: Array[int] = [_n(instr, 0), _n(instr, 1), _n(instr, 2),
		_n(instr, 3), tiles.size() / 2]
	values.append_array(tiles)
	_event("para_bombs", values)
