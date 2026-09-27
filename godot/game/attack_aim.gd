class_name AttackAim
extends RefCounted

## `aAttackUnit`'s body aim, `0x0046B753`..`0x0046B962` -- docs/22 section 7.1
## step 5. Presentation only: it reads no rule byte and writes none, and
## `unit[+0x46]` stays the octant throughout.
##
## The routine switches on the attacker's **type** into four classes and then,
## when the target stands more than a field above or below, on the **weapon**:
##
##     class  types                        near (<= 3200)   far
##     1      0-3, 21-23, 26, 56, 57       level look-at    per weapon, below
##     2      every type not listed        level look-at    look-at tz + h/2
##     3      20, 55, 58, 59, 60, 66       level look-at    level look-at
##     4      61, 62, 63                   nothing          nothing
##
## Class 1 far: weapons 3, 5, 10, 14, 45, 47 look at `tz + h/2`; weapon 46
## does nothing; 8, 42 and 13 aim the part `Unterkoerper` at `tz + 9600`
## (`add edx, 0x2580` at `0x0046B906`) and every other weapon aims it at
## `tz + h/2` (`0x0042CD80`). `h` is the **attacker's** full height
## (`0x0047AD70`, [method HitChance.full_height]), a look-at is `0x00405250`
## -> `0x0042CAC0` along the exact line from the attacker's object to the
## target cell's marker, and *level* replaces the target's z by the
## attacker's own.

const MODE_NONE: String = "none"
const MODE_LOOK: String = "look"
## `0x0042CD80` on the part [constant PART]: the body keeps its octant and
## the part's **parent** -- the spine -- is turned (docs/22 section 7.1 step 5).
const MODE_PART: String = "part"
const PART: String = "Unterkoerper"
## `0x0042CD80`'s two corrections after the look-at, `M * Rx` then `M * Ry`,
## in degrees (`[0x004B1370]`, `[0x004B1378]`).
const SPINE_TILT_X: float = -15.5
const SPINE_TURN_Y: float = -90.0
## `[0x004B1334]`: engine units to Charisma units.
const CHARISMA_PER_ENGINE: float = 1.0 / 16.0

const CLASS_1_TYPES: Array[int] = [0, 1, 2, 3, 21, 22, 23, 26, 56, 57]
const CLASS_3_TYPES: Array[int] = [20, 55, 58, 59, 60, 66]
const CLASS_4_TYPES: Array[int] = [61, 62, 63]
## `cmp eax, 0xC80` / `jle` at `0x0046B812`: within this, the look-at is level.
const NEAR_HEIGHT: int = 3200
const CLASS_1_HALF_HEIGHT_LOOK: Array[int] = [3, 5, 10, 14, 45, 47]
const CLASS_1_FIXED_PART_AIM: Array[int] = [8, 42, 13]
const CLASS_1_NO_AIM_WEAPON: int = 46
## `add edx, 0x2580` at `0x0046B906`.
const FIXED_PART_AIM_RISE: int = 9600


## What the routine does for one shot. `from` is the attacker's object
## position and `to` the target cell's marker, both in engine units; `height`
## the attacker's full height. Answers `{"mode": String, "target": Vector3i}`,
## the target being where the look-at or the part aim points.
static func plan(type_id: int, weapon: int, from: Vector3i, to: Vector3i,
		height: int) -> Dictionary:
	var level: Vector3i = Vector3i(to.x, to.y, from.z)
	var raised: Vector3i = Vector3i(to.x, to.y, to.z + height / 2)
	var near: bool = absi(from.z - to.z) <= NEAR_HEIGHT
	if CLASS_4_TYPES.has(type_id):
		return _answer(MODE_NONE, from)
	if CLASS_3_TYPES.has(type_id) or near:
		return _answer(MODE_LOOK, level)
	if not CLASS_1_TYPES.has(type_id):
		return _answer(MODE_LOOK, raised)
	if CLASS_1_HALF_HEIGHT_LOOK.has(weapon):
		return _answer(MODE_LOOK, raised)
	if weapon == CLASS_1_NO_AIM_WEAPON:
		return _answer(MODE_NONE, from)
	if CLASS_1_FIXED_PART_AIM.has(weapon):
		return _answer(MODE_PART, Vector3i(to.x, to.y, to.z + FIXED_PART_AIM_RISE))
	return _answer(MODE_PART, raised)


## `0x0042CAC0`'s placement as the unit node's basis: the model's forward laid
## along the exact line `from` -> `to`, pitch included, with `up` completing a
## right-handed frame (`side = d x z`, `up = side x d`). The body's own half
## turn stays on the body ([method WorldSpace.charisma_offset]), which is the
## `Rz(pi)` `0x0042CAC0` multiplies on afterwards.
##
## A level target is exactly [method WorldSpace.yaw_basis] at the unquantised
## bearing; a raised one is that frame turned about its own side axis, which
## is what `up = side x d` makes of it. `null`-free: a target on the
## attacker's own column answers `fallback`.
static func look_basis(from: Vector3i, to: Vector3i, fallback: Basis) -> Basis:
	var d: Vector3 = Vector3(to - from)
	if is_zero_approx(d.x) and is_zero_approx(d.y):
		return fallback
	# The bearing from engine +Y toward +X, unquantised: `0x0042CBA0` builds
	# its frame from the float vector, not from an angle.
	var bearing: float = atan2(d.x, d.y)
	var level: Basis = Basis(Vector3.UP, -bearing)
	var flat: Vector3 = WorldSpace.to_godot_v(Vector3(d.x, d.y, 0.0)).normalized()
	var line: Vector3 = WorldSpace.to_godot_v(d).normalized()
	var axis: Vector3 = flat.cross(line)
	if axis.is_zero_approx():
		return level
	return Basis(axis.normalized(), flat.angle_to(line)) * level


static func _answer(mode: String, target: Vector3i) -> Dictionary:
	return {"mode": mode, "target": target}


## `0x0042CD80`'s matrix, as it writes it into the spine's external rotation
## movement: every argument and the answer are engine float matrices, 16
## floats row-major, `M * v`, Charisma units -- the arithmetic reproduced
## 18/18 against the running original (`presentation_gold.py`'s `body_aim`
## phases, replayed by `test_charisma.gd` from `cases_aim.json`).
##
## *placement* is the model's (`V100Model+0x34`), *parent_world* the spine's
## parent's world matrix without the placement, *local* the spine's current
## local matrix, *target* in engine units. The look-at from the spine's joint
## writes **columns** `side = d x z`, `d`, `up = side x d`; `Rx(-15.5)` and
## `Ry(-90)` follow; the frame is then taken back through the placement and
## the parent (`0x00482B36`, a true inverse -- both carry a hair of scale).
## The part keeps its animated translation; only this rotation replaces its
## own for as long as the movement is attached.
static func spine_local(placement: PackedFloat64Array,
		parent_world: PackedFloat64Array, local: PackedFloat64Array,
		target: Vector3i) -> PackedFloat64Array:
	var pivot: Vector3 = CharismaTrack.mat_translation(CharismaTrack.mat_mul(
		CharismaTrack.mat_mul(placement, parent_world),
		CharismaTrack.mat_with_translation(CharismaTrack.identity(),
			CharismaTrack.mat_translation(local))))
	var d: Vector3 = _normalised(Vector3(target) * CHARISMA_PER_ENGINE - pivot)
	var side: Vector3 = _normalised(d.cross(Vector3(0.0, 0.0, 1.0)))
	var up: Vector3 = _normalised(side.cross(d))
	var frame: PackedFloat64Array = CharismaTrack.identity()
	var columns: Array[Vector3] = [side, d, up]
	for column: int in range(3):
		frame[column] = columns[column].x
		frame[4 + column] = columns[column].y
		frame[8 + column] = columns[column].z
	var world: PackedFloat64Array = CharismaTrack.mat_mul(CharismaTrack.mat_mul(
		frame, _axis_rotation(0, SPINE_TILT_X)), _axis_rotation(1, SPINE_TURN_Y))
	return CharismaTrack.mat_mul(_inverse_rotation(parent_world),
		CharismaTrack.mat_mul(_inverse_rotation(placement), world))


## The placement `0x0042C900` gives a body at engine yaw *angle*, standing at
## *at* (engine units): the rotation [method WorldSpace.charisma_yaw_basis]
## draws -- `Rz` by the same angle, since engine `Rz(a)` maps to Godot's
## `Basis(UP, a)` -- and the position in Charisma units.
static func placement_for(angle: int, at: Vector3i) -> PackedFloat64Array:
	var turn: float = -float(posmod(angle + WorldSpace.ANGLE_FULL_TURN / 2,
		WorldSpace.ANGLE_FULL_TURN)) / float(WorldSpace.ANGLE_FULL_TURN) * TAU
	var c: float = cos(turn)
	var s: float = sin(turn)
	var out: PackedFloat64Array = CharismaTrack.identity()
	out[0] = c
	out[1] = -s
	out[4] = s
	out[5] = c
	return CharismaTrack.mat_with_translation(out,
		Vector3(at) * CHARISMA_PER_ENGINE)


## `0x0048262C`: a zero vector becomes `(1, 0, 0)`.
static func _normalised(v: Vector3) -> Vector3:
	return Vector3(1.0, 0.0, 0.0) if v.is_zero_approx() else v.normalized()


## `Rx` (`0x00482920`) for *axis* 0, `Ry` (`0x00482991`) for 1, as the
## right-hand factor of a post-multiplication.
static func _axis_rotation(axis: int, degrees: float) -> PackedFloat64Array:
	var c: float = cos(deg_to_rad(degrees))
	var s: float = sin(deg_to_rad(degrees))
	var out: PackedFloat64Array = CharismaTrack.identity()
	if axis == 0:
		out[5] = c
		out[6] = -s
		out[9] = s
		out[10] = c
	else:
		out[0] = c
		out[2] = s
		out[8] = -s
		out[10] = c
	return out


## `0x00482B36` -- the inverse of *m*'s 3x3, by cofactors, translation clear.
static func _inverse_rotation(m: PackedFloat64Array) -> PackedFloat64Array:
	var a: float = m[0]
	var b: float = m[1]
	var c: float = m[2]
	var d: float = m[4]
	var e: float = m[5]
	var f: float = m[6]
	var g: float = m[8]
	var h: float = m[9]
	var i: float = m[10]
	var det: float = a * (e * i - f * h) - b * (d * i - f * g) \
		+ c * (d * h - e * g)
	var out: PackedFloat64Array = CharismaTrack.identity()
	out[0] = (e * i - f * h) / det
	out[1] = (c * h - b * i) / det
	out[2] = (b * f - c * e) / det
	out[4] = (f * g - d * i) / det
	out[5] = (a * i - c * g) / det
	out[6] = (c * d - a * f) / det
	out[8] = (d * h - e * g) / det
	out[9] = (b * g - a * h) / det
	out[10] = (a * e - b * d) / det
	return out
