class_name Allowance
extends RefCounted

## `aGetMovePoints` (`0x00475160`), transcribed from docs/10 section 5.5.
##
## The single source of a unit's movement points.  Nothing stores them between
## turns, so the turn refresh and the ladder step both ask this again.
##
## Three properties are transcription and not design:
##
## 1. **The accumulator is a byte.**  `bl` carries the running total through
##    the whole routine, so subtracting one from zero wraps to 255, and the
##    `> 200` guard at `0x0047521F` is what catches it.  An unbounded integer
##    would make that guard dead code.
## 2. **The Banner scan does not skip the carrier.**  `0x0046FAD0` walks all
##    200 slots without excluding the unit it was asked about, so a unit
##    carrying its own Banner gets the bonus from itself.  Measured: the native
##    capture's `banner=self` call returns one more than the base.
## 3. **The Banner reach is floor-Euclidean and strictly below four.**  The
##    scan calls `aGetDistance` and accepts `< 4`, so three fields.  docs/10
##    section 5.5 said "within 4 fields", which was ambiguous between that and
##    Chebyshev; the native capture settles it -- a carrier at `(3,3)` does
##    **not** count, where Chebyshev would make it 3 and in range.

## docs/10 section 5 -- the equipment ids, as offsets into `unit[+0x21]`.
const EQUIP_BANNER: int = 8
const EQUIP_HEAVY_ARMOR: int = 13
const EQUIP_SERVO_SYSTEM: int = 14

## `0x0046FB31` -- `cmp eax, 4; jl`, so 0, 1, 2 or 3 fields count.
const BANNER_RANGE: int = 4

## `0x0047521F` -- `cmp bl, 200; ja` zeroes the byte accumulator.
const GUARD: int = 200

## `0x00475226` -- action states that suppress movement entirely.
const ACTION_STATE_SUPPRESSED: Array[int] = [5, 6]
## `0x0047520F` -- `unit[+0x57]`, "did not act last turn".
const RESTED: int = 1

## `0x0047516B` -- the one unit type whose base allowance depends on the AI
## level `0x00460450` returns.  Level 0 takes one off the table value; 1 and 2
## leave it; anything else raises "incorrect ai level!" and returns zero.
const DIFFICULTY_TWEAK_TYPE: int = 0x32
const AI_LEVELS: Array[int] = [0, 1, 2]
## What `0x00460450` answered in the captured session.  It is a difficulty
## setting, not a constant of the engine, so it is a parameter everywhere below
## and this is only the default.
const DEFAULT_AI_LEVEL: int = 1


## The movement points `unit_slot` has this turn.
##
## `units` is the whole live roster, needed only for the Banner scan.
static func for_unit(unit: UnitState, utab: UnitTypeTable, units: Dictionary,
		ai_level: int = DEFAULT_AI_LEVEL) -> int:
	var total: int = utab.mp_max(unit.type_id) & 0xFF
	if unit.type_id == DIFFICULTY_TWEAK_TYPE:
		if not AI_LEVELS.has(ai_level):
			return 0
		if ai_level == 0:
			total = (total - 1) & 0xFF

	if unit.has_equipment(EQUIP_SERVO_SYSTEM):
		total = (total + 1) & 0xFF
	if banner_in_range(unit, units):
		total = (total + 1) & 0xFF
	if unit.has_equipment(EQUIP_HEAVY_ARMOR):
		total = (total - 1) & 0xFF

	if unit.fp == 0:
		# Exhaustion overrides everything above it, equipment included.
		total = 1
	elif unit.fp == 1:
		total = 2
	elif unit.rested == RESTED:
		total = (total + 1) & 0xFF

	if total > GUARD:
		total = 0
	if ACTION_STATE_SUPPRESSED.has(unit.action_state):
		total = 0
	return total


## `0x0046FAD0` in its single-player form: a live unit of the **same** player
## carrying the Banner, within [constant BANNER_RANGE].
##
## The routine has a second arm for network game types 2, 3 and 4, which
## relaxes the owner test; nothing here runs a network game, so it is not
## modelled rather than guessed at.
static func banner_in_range(unit: UnitState, units: Dictionary) -> bool:
	for slot: Variant in units:
		var other: UnitState = units[slot]
		if not other.is_alive():
			continue
		if other.player != unit.player:
			continue
		if not other.has_equipment(EQUIP_BANNER):
			continue
		if MoveMap.distance(unit.x, unit.y, other.x, other.y) < BANNER_RANGE:
			return true
	return false
