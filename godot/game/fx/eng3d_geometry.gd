class_name Eng3dGeometry
extends RefCounted

## The engine's fixed-point geometry, measured rather than invented.
##
## `docs/28` section 12 item 1 said the five services an update arm calls
## outside its own record had never been measured, and [BlobHooks] therefore
## carried a *documented substitute* for the orientation one: an `atan2` over a
## 0..0xFFFF turn, chosen because nothing better was available. It was wrong in
## the unit and wrong in the pitch.
##
## `tools/blob_gold.py`'s `hooks` phase now calls `0x00403AA0` inside a running
## `Incubation.exe` over twenty deltas and reads what it writes. The routine:
##
## 1. takes the **yaw** straight out of the horizontal delta with the engine's
##    two-argument angle helper -- a **4096-unit circle**, `docs/70`'s binary
##    degrees, 0 along `+y` and 1024 along `+x`;
## 2. builds a Q14 rotation matrix for that yaw and turns the whole delta flat
##    with it;
## 3. takes a second angle from the two components that survive and subtracts
##    a quarter turn, which is the `sub eax, 0x400` at `0x00403B21`.
##
## So level is 0, straight up is -1024, and a delta of length 1 rounds away
## entirely. This class reproduces all twenty captured pairs exactly, and
## `tools/inclib/eng3d.py` is its twin on the Python side -- the two read the
## same shipped tables, so the diff in `tests/test_blob.gd` compares two
## transcriptions of one measurement rather than two guesses.
##
## **The tables come from the cache, not from a formula.** `docs/70`'s first
## open question is that the rounding Blue Byte generated them with is unknown;
## `tools/img_tables.py` can only show the formula agrees to within one unit,
## and one unit of a 4096-unit circle is one unit of every angle built on it.
##
## Eng3d's own three-angle matrix builder behind `0x004039A0` is here too, and
## it was the last of the five to fall. `Incubation.exe` only marshals for it;
## the arithmetic is `_E3D_init_matrix_RzRxRy`, ordinal 13 of `Eng3d.dll`, and
## three things about it are not guessable from the caller: it **negates** each
## angle before indexing the table, its products are 64-bit and floored where
## the two-angle builder's are 32-bit and truncated toward zero, and the
## transform reads the matrix **by column**. All eight captured cases, exactly.

## A full turn. Binary degrees; **not** 65536ths.
const ANGLE_UNITS: int = 4096
## `ATN.IMG` is indexed by `(min / max) * 1024`.
const ATAN_INPUT_SCALE: int = 1024
## The Q14 denominator every product is divided by.
const Q14_SHIFT: int = 14
## Where the cosine window starts inside `TRIG.IMG`.
const COSINE_OFFSET: int = 1024
const TRIG_ENTRIES: int = 5120
const ATAN_ENTRIES: int = 1025
const TRIG_MASK: int = 4095

var _trig: PackedInt32Array = PackedInt32Array()
var _atn: PackedInt32Array = PackedInt32Array()


## Read `tables/trig.json` out of a published cache.
static func from_cache(cache_dir: String) -> Eng3dGeometry:
	var raw: Dictionary = CacheLoader.read_json(cache_dir + "/tables/trig.json")
	return from_document(raw)


## Narrow a parsed document into typed arrays.
##
## `JSON.parse_string` produces a `float` for every number, so the narrowing
## happens once, here, at the loading boundary -- the same rule `core/` follows
## for the cache it reads.
static func from_document(raw: Dictionary) -> Eng3dGeometry:
	var made: Eng3dGeometry = Eng3dGeometry.new()
	made._trig = _narrow(raw.get("trig", []))
	made._atn = _narrow(raw.get("atn", []))
	return made


static func _narrow(values: Variant) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if not (values is Array):
		return out
	var raw: Array = values
	for value: Variant in raw:
		out.append(DictRead.as_int(value))
	return out


## Whether both tables arrived at their shipped lengths.
##
## Empty is not an error state to paper over: a caller with no tables must use
## the substitute and **say so**. `tools/blob_runtime.py --emit-cases` writes
## `"orient": "substitute"` into the fixture when it had no game root, and
## `tests/test_blob.gd` fails on that field rather than quietly comparing two
## different orientation helpers.
func is_loaded() -> bool:
	return _trig.size() == TRIG_ENTRIES and _atn.size() == ATAN_ENTRIES


func sine(turn: int) -> int:
	return _trig[turn & TRIG_MASK]


func cosine(turn: int) -> int:
	return _trig[(turn & TRIG_MASK) + COSINE_OFFSET]


## `[0x004FA4E0]` -- the angle of `(a, b)`, measured from `+b` toward `+a`.
##
## `angle(0, 0)` is 0 and `angle(a, 0)` for a non-zero `a` is 1024; both are
## captured answers rather than conventions chosen here.
func angle(a: int, b: int) -> int:
	var quadrant: int = _first_quadrant(absi(a), absi(b))
	if a >= 0:
		return quadrant if b >= 0 else ANGLE_UNITS / 2 - quadrant
	return ANGLE_UNITS / 2 + quadrant if b < 0 else ANGLE_UNITS - quadrant


func _first_quadrant(a: int, b: int) -> int:
	if b == 0:
		return ANGLE_UNITS / 4 if a != 0 else 0
	if a <= b:
		return _atn[(a * ATAN_INPUT_SCALE) / b]
	return ANGLE_UNITS / 4 - _atn[(b * ATAN_INPUT_SCALE) / a]


## `cdq / and edx, 0x3FFF / add / sar 14` -- divide toward zero.
##
## What the **matrix builder** does. It is not what the transform does, and
## both appear inside one call to `0x00403AA0`.
static func trunc_shift(value: int) -> int:
	return -((-value) >> Q14_SHIFT) if value < 0 else value >> Q14_SHIFT


## `sar 14` -- divide toward negative infinity. What Eng3d's transform does.
static func floor_shift(value: int) -> int:
	return value >> Q14_SHIFT


## `0x004039F0` -- the two-angle Q14 matrix, row major.
##
## With both angles zero the diagonal is 16383, 16382, 16383: the engine's
## identity is not one, which is where a coordinate of 1000 becomes 999.
func matrix(a: int, b: int) -> PackedInt32Array:
	var sa: int = sine(a)
	var ca: int = cosine(a)
	var sb: int = sine(b)
	var cb: int = cosine(b)
	var out: PackedInt32Array = PackedInt32Array()
	out.append(cb)
	out.append(-trunc_shift(sb * ca))
	out.append(trunc_shift(sb * sa))
	out.append(sb)
	out.append(trunc_shift(cb * ca))
	out.append(-trunc_shift(cb * sa))
	out.append(0)
	out.append(sa)
	out.append(ca)
	return out


## `_E3D_init_matrix_RzRxRy`, ordinal 13 -- the three-angle Q14 matrix.
##
## Every angle is negated before it indexes the table, every product is floored
## rather than truncated, and the chained triples shift **at each step**: the
## engine's `sh(sh(s * s) * s)` is not `sh(s * s * s)`.
func matrix3(a: int, b: int, c: int) -> PackedInt32Array:
	var sa: int = sine(-a)
	var ca: int = cosine(-a)
	var sb: int = sine(-b)
	var cb: int = cosine(-b)
	var sc: int = sine(-c)
	var cc: int = cosine(-c)
	var out: PackedInt32Array = PackedInt32Array()
	out.append(floor_shift(cb * cc) - floor_shift(floor_shift(sa * sb) * sc))
	out.append(floor_shift(ca * sc))
	out.append(floor_shift(sb * cc) + floor_shift(floor_shift(sa * cb) * sc))
	out.append(-(floor_shift(cb * sc) + floor_shift(floor_shift(sa * sb) * cc)))
	out.append(floor_shift(ca * cc))
	out.append(floor_shift(floor_shift(sa * cb) * cc) - floor_shift(sb * sc))
	out.append(-floor_shift(ca * sb))
	out.append(-sa)
	out.append(floor_shift(ca * cb))
	return out


## `_E3D_c_rotate_coordinate`, ordinal 15 -- `v` through `m`, read by column.
##
## The three entries one output component needs are **three apart** in memory,
## not adjacent. A transposed read paired with a transposed build cancels, which
## is how `orient` passed twenty captured cases while both halves were wrong.
static func transform(m: PackedInt32Array, v: Vector3i) -> Vector3i:
	return Vector3i(
		floor_shift(m[0] * v.x + m[3] * v.y + m[6] * v.z),
		floor_shift(m[1] * v.x + m[4] * v.y + m[7] * v.z),
		floor_shift(m[2] * v.x + m[5] * v.y + m[8] * v.z))


## `0x004039A0` -- a vector through the three-angle matrix of `angles`.
func rotate(v: Vector3i, angles: Vector3i) -> Vector3i:
	return transform(matrix3(angles.x, angles.y, angles.z), v)


## `0x0044AE10` -- the 2D distance, **truncated** to an integer.
##
## A delta of (5, 3) comes back 5 where rounding would give 6, and the third
## component of [method direction] divides by this rather than by the exact
## length. `sqrt` is exact enough for the map's magnitudes, and the two loops
## make it exact for all of them.
static func distance_2d(dx: int, dy: int) -> int:
	var square: int = dx * dx + dy * dy
	var root: int = int(sqrt(float(square)))
	while root > 0 and root * root > square:
		root -= 1
	while (root + 1) * (root + 1) <= square:
		root += 1
	return root


## `0x0046D400` -- the three doubles the seeking arms steer on.
##
## It is **not** a normalised vector, which is the whole point: the first two
## components are divided by whichever of `|dx|` and `|dy|` is larger, so one
## of them is always exactly ±1, and the third is divided by the truncated 2D
## distance. A model that divided by the true length has the right shape and
## the wrong numbers, and that is what kept the two seekers disagreeing with
## the engine until `tools/blob_gold.py` stepped them.
##
## `shift` reaches **only** the vertical -- it is applied inside the branch
## that computes it -- and the three arms all pass 1.
##
## Doubles, not a `Vector3`: `Vector3` is 32-bit and these ratios are
## multiplied by -240 and truncated, where a lost bit changes an integer.
static func direction(source: Vector3i, target: Vector3i,
		shift: int) -> PackedFloat64Array:
	var dx: int = target.x - source.x
	var dy: int = target.y - source.y
	var wide: int = maxi(absi(dx), absi(dy))
	var first: float = NAN
	var second: float = NAN
	if wide != 0:
		first = float(dx) / float(wide)
		second = float(dy) / float(wide)
	if target.z == source.z:
		return PackedFloat64Array([first, second, 0.0])
	var lo: Vector3i = source
	var hi: Vector3i = target
	if shift != 0:
		lo = Vector3i(source.x >> 3, source.y >> 3, source.z >> 3)
		hi = Vector3i(target.x >> 3, target.y >> 3, target.z >> 3)
	var height: int = hi.z - lo.z
	var span: int = distance_2d(hi.x - lo.x, hi.y - lo.y)
	if span == 0:
		if height == 0:
			return PackedFloat64Array([first, second, NAN])
		return PackedFloat64Array([first, second, INF if height > 0 else -INF])
	return PackedFloat64Array([first, second, float(height) / float(span)])


## `0x004AE7B6` -- MSVC's `_ftol`, which is an `fistp qword` and truncates.
##
## It stores **64 bits** and returns the pair in `edx:eax`, and every caller
## here keeps `eax`: the answer is the *low dword*. An invalid conversion
## stores x87's 64-bit integer indefinite, `0x8000000000000000`, whose low
## dword is **zero** -- so a NaN steers a seeker by nothing rather than by
## `INT_MIN`. Measured: the poked kind-27 record of docs/97 section 20 sits on
## its target's column, the direction service answers NaN, and the engine's
## record comes back with no steering term at all.
static func ftol(value: float) -> int:
	if is_nan(value) or is_inf(value) \
			or value < -9223372036854775808.0 or value >= 9223372036854775808.0:
		return 0
	return IncInt.i32(int(value) & IncInt.U32_MASK)


## `0x00403AA0` -- `(pitch, yaw)` in 4096ths, as the arms receive them.
##
## The delta is turned by **minus** the yaw -- the `neg eax` at `0x00403ACF`.
func orient(from: Vector3i, at: Vector3i) -> Vector2i:
	var delta: Vector3i = at - from
	var yaw: int = angle(delta.x, delta.y)
	var flat: Vector3i = transform(matrix(0, -yaw), delta)
	return Vector2i(angle(flat.y, flat.z) - ANGLE_UNITS / 4, yaw)
