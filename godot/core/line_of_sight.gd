class_name LineOfSight
extends RefCounted

## `aCheckLineOfSight` (`0x0046C720`) and `aCheckLineOfSightEx` (`0x0046C460`),
## transcribed from docs/22 section 6.
##
## Three properties are deliberate, and each of them is what the engine does:
##
## 1. **The outcomes are codes, not costs.**  0 is clear, 254 is a body and 255
##    is terrain.  Terrain wins: once 255 is set the unit test cannot lower it,
##    and [method ray] runs to the target cell rather than stopping at the
##    first block.  A remake that returned "blocked / not blocked" loses the
##    distinction docs/22 section 9.3 depends on -- a unit standing in the way
##    blocks a shot but **not** the sight of it.
##    [br][br]
##    Returning 255 the moment terrain is met gives the *same* answer -- nothing
##    can raise the code above terrain -- so that mutation is equivalent and no
##    check looks for it.  What is **not** equivalent is returning early on a
##    **body**: a ray that meets a crate and then a wall must report the wall,
##    or a target behind a wall comes back merely shielded.
## 2. **The walk is a `float` DDA and stays one.**  A rounding bias is added
##    before truncation, and that bias is what lets a shot slip past a corner.
##    An integer Bresenham would produce a different, plausible answer.
## 3. **`dz` is divided by the Euclidean distance while the walk advances along
##    the dominant axis**, so on a perfect diagonal the ray climbs about 1.41x
##    more slowly than its endpoints imply and arrives low.  That is the
##    engine's arithmetic, not a rounding artefact.  Do not "fix" it.

## docs/22 section 6.2 -- the three outcome codes.
const CLEAR: int = 0
const UNIT: int = 0xFE
const TERRAIN: int = 0xFF

## docs/22 section 6.2 -- `dz` is per field stepped, so this is a slope limit of
## `4000 / 3200`, about 51 degrees.
const SLOPE_LIMIT: float = 4000.0
## `0x0046C720`'s own loop bound.
const MAX_STEPS: int = 1000

## docs/22 section 6.1 -- the biases each ray form uses.  0.4 and 0.6 walk the
## *same* geometric line and break ties on opposite sides of it.
const BIAS_CENTRE: float = 0.5
const BIAS_LOW: float = 0.4
const BIAS_HIGH: float = 0.6


## `0x0046D400` -- a plain DDA, one whole field on the dominant axis.
##
## Returns `[dx, dy, dz]`.
static func setup_step(x0: int, y0: int, z0: int, x1: int, y1: int,
		z1: int) -> PackedFloat64Array:
	var slope: float = 1.0
	if x1 != x0:
		slope = absf(float(y1 - y0) / float(x1 - x0))
	var sy: float = 0.0
	if y1 > y0:
		sy = slope
	elif y1 < y0:
		sy = -slope
	var sx: float = 0.0
	if x1 > x0:
		sx = 1.0
	elif x1 < x0:
		sx = -1.0
	var m: float = maxf(absf(sy), absf(sx))
	var dz: float = 0.0
	if z1 != z0:
		# `aGetDistance`, the Euclidean one -- the same helper the hit
		# curve measures with, not the dominant-axis count this walk steps.
		var d: int = MoveMap.distance(x0, y0, x1, y1)
		if d != 0:
			dz = float(z1 - z0) / float(d)
	return PackedFloat64Array([sx / m, sy / m, dz])


## `0x0046C720` -- one ray, returning 0, 254 or 255.
static func ray(state: MapState, units: Dictionary, utab: UnitTypeTable,
		x0: int, y0: int, z0: int, x1: int, y1: int, z1: int,
		bias: float) -> int:
	if x0 == x1 and y0 == y1:
		return CLEAR                       # same cell: always clear
	var step: PackedFloat64Array = setup_step(x0, y0, z0, x1, y1, z1)
	var dz: float = step[2]
	if dz > SLOPE_LIMIT or dz < -SLOPE_LIMIT:
		return TERRAIN                     # too steep
	var out: int = CLEAR
	var x: float = float(x0)
	var y: float = float(y0)
	var z: float = float(z0)
	for _i: int in range(MAX_STEPS + 1):
		x += step[0]
		y += step[1]
		z += dz
		var cx: int = int(x + bias)
		var cy: int = int(y + bias)
		if cx == x1 and cy == y1:
			return out
		if not state.in_bounds(cx, cy):
			# A ray that left the grid has nothing to be blocked by.  The
			# shipped data never reaches this -- the endpoints are always
			# cells -- but `aGetCtrlMapElementPtr` answers null off the map
			# and the caller keeps walking.
			continue
		var index: int = state.index_of(cx, cy)
		var cell_h: int = state.height_at(index)
		if z < float(cell_h):
			out = TERRAIN
		if out < TERRAIN:
			var slot: int = state.unit_at(index)
			if slot >= 0 and units.has(slot):
				var blocker: UnitState = units[slot]
				if blocker.is_alive() and blocker.x == cx and blocker.y == cy:
					var top: float = float(
						utab.body_height_world(blocker.type_id) + cell_h)
					if z <= top:
						out = UNIT
	return out


## `0x0046C460` -- up to four rays, **keeping the smallest** result.
##
## docs/22 section 6.1: a target is visible if any sampled walk is clear, which
## is how the engine lets a shot past a corner without tracing a cone.  Mode 0
## is the single reversed ray a neutral unit on an order other than 9 gets.
static func check(state: MapState, units: Dictionary, utab: UnitTypeTable,
		x0: int, y0: int, z0: int, x1: int, y1: int, z1: int, mode: int,
		human_players: int, game_mode: int) -> int:
	var rays: Array[PackedFloat64Array] = []
	if mode == 0:
		rays.append(PackedFloat64Array([x1, y1, z1, x0, y0, z0, BIAS_CENTRE]))
	else:
		rays.append(PackedFloat64Array([x0, y0, z0, x1, y1, z1, BIAS_LOW]))
		rays.append(PackedFloat64Array([x0, y0, z0, x1, y1, z1, BIAS_HIGH]))
		if not (human_players == 1 and game_mode != 2):
			rays.append(PackedFloat64Array(
				[x1, y1, z1, x0, y0, z0, BIAS_LOW]))
			rays.append(PackedFloat64Array(
				[x1, y1, z1, x0, y0, z0, BIAS_HIGH]))
	var best: int = TERRAIN
	for r: PackedFloat64Array in rays:
		best = mini(best, ray(state, units, utab, int(r[0]), int(r[1]),
			int(r[2]), int(r[3]), int(r[4]), int(r[5]), r[6]))
	return best
