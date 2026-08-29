class_name MissionScript
extends RefCounted

## The seam the LCL interpreter plugs into -- docs/20 section 5.
##
## The hand-over runs the mission program twice and the walk runs it once more,
## and **all three check the return**: `0x0047D600` is `if (!runProgram())
## return 0;`, so a script that reports and returns zero stops the sequence
## where it stands. That contract is stated here rather than at each call site,
## because a seam whose failure semantics live in three places is a seam that
## will acquire a fourth.
##
## The runner is a [Callable] taking `(call_type: int, env: Dictionary)` and
## returning a `Dictionary` carrying at least `"ok": bool`. [method no_op] is
## the default and returns **`ok = true`**: a world with no script attached
## must let the turn proceed, since "no program" and "a program that refused"
## are different answers and only the second stops anything.
##
## `core/lcl/` will supply the real runner in a later stage. Nothing here
## interprets anything.

## docs/20 section 5 -- `_A` selects the entry point.
const CALL_NEXT_PLAYER: int = 1
const CALL_MOVE_UNIT: int = 2
const CALL_ATTACK: int = 3
const CALL_USE: int = 4
const CALL_NEXT_TURN: int = 5
const CALL_INIT_MAP: int = 6

## The environment is indexed `letter - 'A'` (`0x0050BF70`), so `_A` is 0.
const SLOT_A: int = 0
const SLOT_B: int = 1
const SLOT_C: int = 2
const SLOT_D: int = 3
const SLOT_E: int = 4
const SLOT_F: int = 5

## docs/20 section 7.4 -- `GetHeight`/`SetHeight` speak in units of 160 world
## units, and `_D` carries a height **level**, not the raw `cell[+0x01]`.
const HEIGHT_LEVEL_UNITS: int = 160


## What the host writes into the environment for one call type.
##
## docs/20 section 5 tabulates the whole contract, including the one place the
## engine contradicts itself: the walk (`0x0046E220`) puts the cell's **height**
## in `_D` while the warp (`0x0046EF50`) puts its action point there. This
## builds the walk's form, which is the ordinary move.
static func env(call_type: int, turn: int = 1, player: int = 0, x: int = 0,
		y: int = 0, height_level: int = 0, actpt: int = 0,
		unit_index: int = -1) -> Dictionary:
	var out: Dictionary = {SLOT_A: call_type}
	match call_type:
		CALL_NEXT_PLAYER:
			out[SLOT_B] = turn
			out[SLOT_C] = player
		CALL_MOVE_UNIT:
			out[SLOT_B] = x
			out[SLOT_C] = y
			out[SLOT_D] = height_level
			out[SLOT_E] = actpt
			out[SLOT_F] = unit_index
		CALL_ATTACK:
			out[SLOT_B] = x
			out[SLOT_C] = y
		CALL_USE:
			out[SLOT_B] = x
			out[SLOT_C] = y
			out[SLOT_D] = actpt
		CALL_NEXT_TURN:
			out[SLOT_B] = turn
		# InitMap sets none.
	return out


## The default runner: no program is attached, so nothing refuses anything.
##
## `ran` is what tells a caller the difference between this and a real
## invocation, and it is why the flag exists rather than being inferred from an
## empty result.
static func no_op(call_type: int, environment: Dictionary) -> Dictionary:
	return {"ok": true, "ran": false, "call_type": call_type,
		"env": environment.duplicate()}
