class_name LclEnv
extends RefCounted

## The environment array and the entry-point contract -- docs/20 sections 4
## and 5.
##
## **The environment is indexed by `letter - 'A'`.** `0x004402A0` range-checks
## that against 0..26, so `_A` is slot **0** and not `ord("A")`. Passing the
## character code silently selects slot 65, and an invocation then runs to its
## end having never reached the entry point it was supposed to select --
## measured once, on the Python side, and it looked exactly like a working run.

## docs/20 section 4.1 -- `0x0043FC70` clears 28 dwords before every run.
const LOCAL_SLOTS: int = 28
## docs/20 section 4.2 -- and fills them with -1, so a read before the first
## write yields -1 rather than 0.
const LOCAL_INITIAL: int = -1
## docs/20 section 4 -- the environment array the host writes.
const ENV_SLOTS: int = 27

## docs/20 section 5 -- the call types the host writes into `_A`.
const CALL_NEXT_PLAYER: int = 1
const CALL_MOVE_UNIT: int = 2
const CALL_ATTACK: int = 3
const CALL_USE: int = 4
const CALL_NEXT_TURN: int = 5
const CALL_INIT_MAP: int = 6

const SLOT_A: int = 0
const SLOT_B: int = 1
const SLOT_C: int = 2
const SLOT_D: int = 3
const SLOT_E: int = 4
const SLOT_F: int = 5

## docs/20 section 7.4 -- `GetHeight`/`SetHeight` speak in units of 160 world
## units; one map tile is 3200.
const HEIGHT_LEVEL_UNITS: int = 160


## Which slots one call type writes.
##
## Separate from [method of] because "the slot is set to zero" and "the slot is
## not set" are different, and the seam's dictionary form can only tell them
## apart by being told. A `MoveUnit` to cell (0,0) sets `_B` and `_C` to zero,
## and a runner that dropped them would see a different environment.
static func slots_for(call_type: int) -> PackedInt32Array:
	match call_type:
		CALL_NEXT_PLAYER:
			return PackedInt32Array([SLOT_A, SLOT_B, SLOT_C])
		CALL_MOVE_UNIT:
			return PackedInt32Array([SLOT_A, SLOT_B, SLOT_C, SLOT_D, SLOT_E,
				SLOT_F])
		CALL_ATTACK:
			return PackedInt32Array([SLOT_A, SLOT_B, SLOT_C])
		CALL_USE:
			return PackedInt32Array([SLOT_A, SLOT_B, SLOT_C, SLOT_D])
		CALL_NEXT_TURN:
			return PackedInt32Array([SLOT_A, SLOT_B])
		_:
			# `InitMap` sets none but `_A`, and neither does an unknown type.
			return PackedInt32Array([SLOT_A])


## What the host writes into the environment array for one call type.
##
## docs/20 section 5 tabulates the whole contract, including the one place the
## engine contradicts itself: the walk (`0x0046E220`) puts the cell's **height**
## in `_D` while the warp (`0x0046EF50`) puts its **ActPt** there. This builds
## the walk's form, which is the ordinary move; no shipped mission reads any of
## `_B`..`_F` in `MoveUnit`, so the difference is invisible in the released game
## and a remake reproduces it per path.
static func of(call_type: int, turn: int = 1, player: int = 0, x: int = 0,
		y: int = 0, height_level: int = 0, actpt: int = 0,
		unit_index: int = -1) -> PackedInt32Array:
	var env: PackedInt32Array = PackedInt32Array()
	env.resize(ENV_SLOTS)
	env[SLOT_A] = call_type
	match call_type:
		CALL_NEXT_PLAYER:
			env[SLOT_B] = turn
			env[SLOT_C] = player
		CALL_MOVE_UNIT:
			env[SLOT_B] = x
			env[SLOT_C] = y
			env[SLOT_D] = height_level
			env[SLOT_E] = actpt
			env[SLOT_F] = unit_index
		CALL_ATTACK:
			env[SLOT_B] = x
			env[SLOT_C] = y
		CALL_USE:
			env[SLOT_B] = x
			env[SLOT_C] = y
			env[SLOT_D] = actpt
		CALL_NEXT_TURN:
			env[SLOT_B] = turn
		_:
			# `InitMap` sets none, and neither does an unknown call type.
			pass
	return env
