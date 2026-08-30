class_name AIScore
extends RefCounted

## The three unit predicates and the cover score -- docs/23 section 5.2.
##
## `0x0040B000`, `0x0040B040` and `0x0040B080` are what the twelve scoring
## arms of `0x0040A750` filter candidates with, and `0x0040B0D0` is the only
## place in the whole AI that weighs terrain.

## docs/21 section 5 -- the species an inanimate object carries, and the one
## the regrouping kinds look for.
const SPECIES_OBJECT: int = 2
const SPECIES_ALIEN: int = 1
## `unit[+0x41]` -- a reaction is pending.
const ACTION_STATE_WAITING: int = 1

## `0x0040B080`'s three movement-point caps, in the order kinds 1 and 3 try
## them: an ally that has spent everything, then one nearly spent, then any.
const ALLY_CAPS_FULL: Array[int] = [0, 2, 255]
const ALLY_CAPS_SHORT: Array[int] = [0, 255]

## `0x0040B0D0` -- the wall field type each neighbour adds a point for, and the
## multiplier on the distance to the furthest enemy.
const WALL_FIELD_TYPE: int = 2
const DISTANCE_NUMERATOR: int = 3
const DISTANCE_DENOMINATOR: int = 2

## What the three out-of-bounds reads add.
##
## docs/23 section 5.2 proves the two bytes are 66 past the end of an
## 18200-byte `malloc` block -- heap history, not game state. What the term
## computes is +10 for every cell except one map row and one map column, so on
## a map no larger than 40x40 it **is** this constant whenever either byte is
## at least 40, which `tools/ai_gold.py` reads and checks.
##
## Reproducing it as a constant is not the same as dropping it: the
## maximiser's incumbent starts at zero, so a candidate scoring 0 is selected
## with the term and refused without it.
const ALIGNMENT_BONUS: int = 10

## `0x004308C0`'s eight directions, diagonals allowed.
const DIR_DX: Array[int] = [0, -1, 0, 1, 1, -1, 1, -1]
const DIR_DY: Array[int] = [1, 0, -1, 0, -1, 1, 1, -1]


## `0x0040B000` -- another player's, and not an inanimate object.
static func is_enemy(utab: UnitTypeTable, unit: UnitState,
		other: UnitState) -> bool:
	if other.player == unit.player:
		return false
	return utab.species(other.type_id) != SPECIES_OBJECT


## `0x0040B040` -- [method is_enemy] plus "no reaction pending".
static func is_enemy_ready(utab: UnitTypeTable, unit: UnitState,
		other: UnitState) -> bool:
	if not is_enemy(utab, unit, other):
		return false
	return other.action_state != ACTION_STATE_WAITING


## `0x0040B080` -- a live alien of ours with at most `cap` points left.
static func is_ally(utab: UnitTypeTable, unit: UnitState, other: UnitState,
		cap: int) -> bool:
	if other.hp == 0:
		return false
	if other.slot == unit.slot:
		return false
	if other.mp > cap:
		return false
	if other.player != unit.player:
		return false
	return utab.species(other.type_id) == SPECIES_ALIEN


## `0x0040B0D0(cell, u, *best)` -- the only place the AI weighs terrain.
##
## Returns `{"cell": int, "best": int}`, with `cell` -1 when the candidate did
## not beat the incumbent. The distance to the furthest enemy is **Euclidean
## and truncated**: the engine computes it in x87 and converts with `_ftol`,
## and so does the `* 1.5`.
static func cover(ctx: AIContext, index: int, unit: UnitState,
		best: int) -> Dictionary:
	var cx: int = ctx.cell_x(index)
	var cy: int = ctx.cell_y(index)
	var far: int = 0
	for slot: int in range(AISystem.UNIT_SLOTS):
		var other: UnitState = ctx.unit_or_null(slot)
		if other == null or other.hp == 0:
			continue
		if other.player == unit.player:
			continue
		var dx: int = other.x - cx
		var dy: int = other.y - cy
		var d: int = IncInt.isqrt_trunc(dx * dx + dy * dy)
		if d > far:
			far = d
	var score: int = IncInt.div_trunc(far * DISTANCE_NUMERATOR,
		DISTANCE_DENOMINATOR)

	for dir: int in range(DIR_DX.size()):
		var nx: int = cx + DIR_DX[dir]
		var ny: int = cy + DIR_DY[dir]
		if not ctx.map.in_bounds(nx, ny):
			continue
		if ctx.map.field_type_at(ctx.map.index_of(nx, ny)) == WALL_FIELD_TYPE:
			score += 1

	score += ALIGNMENT_BONUS
	if score > best:
		return {"cell": index, "best": score}
	return {"cell": -1, "best": best}
