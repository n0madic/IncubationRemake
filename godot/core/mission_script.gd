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
## [LclInterpreter] is the real runner and [method World.attach_script] is what
## installs it. Nothing here interprets anything: this file is the *contract*,
## and the constants below are aliases of [LclEnv]'s so that the two cannot
## drift apart.

## docs/20 section 5 -- `_A` selects the entry point.
const CALL_NEXT_PLAYER: int = LclEnv.CALL_NEXT_PLAYER
const CALL_MOVE_UNIT: int = LclEnv.CALL_MOVE_UNIT
const CALL_ATTACK: int = LclEnv.CALL_ATTACK
const CALL_USE: int = LclEnv.CALL_USE
const CALL_NEXT_TURN: int = LclEnv.CALL_NEXT_TURN
const CALL_INIT_MAP: int = LclEnv.CALL_INIT_MAP

## The environment is indexed `letter - 'A'` (`0x0050BF70`), so `_A` is 0.
const SLOT_A: int = LclEnv.SLOT_A
const SLOT_B: int = LclEnv.SLOT_B
const SLOT_C: int = LclEnv.SLOT_C
const SLOT_D: int = LclEnv.SLOT_D
const SLOT_E: int = LclEnv.SLOT_E
const SLOT_F: int = LclEnv.SLOT_F

## docs/20 section 7.4 -- `GetHeight`/`SetHeight` speak in units of 160 world
## units, and `_D` carries a height **level**, not the raw `cell[+0x01]`.
const HEIGHT_LEVEL_UNITS: int = LclEnv.HEIGHT_LEVEL_UNITS


## What the host writes into the environment for one call type.
##
## A `Dictionary` keyed by slot, because that is what the seam's [Callable]
## carries; [method to_slots] turns it back into the array [LclInterpreter]
## reads. The contract itself is [method LclEnv.of]'s, once.
static func env(call_type: int, turn: int = 1, player: int = 0, x: int = 0,
		y: int = 0, height_level: int = 0, actpt: int = 0,
		unit_index: int = -1) -> Dictionary:
	var packed: PackedInt32Array = LclEnv.of(call_type, turn, player, x, y,
		height_level, actpt, unit_index)
	var out: Dictionary = {}
	# Only the slots this call type sets, **including the ones it sets to
	# zero**: `LclEnv.of` zeroes all 27, and a dictionary carrying every one
	# would make a trace unreadable while one carrying only the non-zero ones
	# would lose a `MoveUnit` to cell (0,0).
	for slot: int in LclEnv.slots_for(call_type):
		out[slot] = packed[slot]
	return out


## The inverse: the seam's dictionary as the array the interpreter reads.
##
## An out-of-range slot is **reported**, not dropped. The engine indexes the
## environment by `letter - 'A'` (`0x004402A0`), so a caller passing `ord("A")`
## rather than 0 is asking for slot 65 -- and dropping it silently leaves `_A`
## at zero, matches no `EnvVarCmpNum` arm, runs the program to `fell_off` with
## `ok` true, and lets the hand-over proceed with the mission never advancing.
## `inclib/lcl_runtime.py` raises for the same reason, and records that it
## learned it the hard way.
static func to_slots(environment: Dictionary) -> PackedInt32Array:
	var packed: PackedInt32Array = PackedInt32Array()
	packed.resize(LclEnv.ENV_SLOTS)
	for key: Variant in environment:
		var slot: int = DictRead.as_int(key)
		if not LclEnv.is_slot(slot):
			push_error(("environment slot %d is outside 0..%d; the engine "
				+ "indexes by letter - 'A', so pass 0 for _A")
				% [slot, LclEnv.ENV_SLOTS - 1])
			continue
		packed[slot] = DictRead.as_int(environment[key])
	return packed


## The default runner: no program is attached, so nothing refuses anything.
##
## `ran` is what tells a caller the difference between this and a real
## invocation, and it is why the flag exists rather than being inferred from an
## empty result.
static func no_op(call_type: int, environment: Dictionary) -> Dictionary:
	return {"ok": true, "ran": false, "call_type": call_type,
		"env": environment.duplicate()}
