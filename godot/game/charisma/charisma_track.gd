class_name CharismaTrack
extends RefCounted

## One animated channel of one bone, and the maths that samples it.
##
## The twin of `tools/inclib/pose.py` and the interpolation half of
## `tools/inclib/charisma.py`. `tests/fixtures/charisma/cases_pose.json` diffs
## the two bone by bone, and `godot/tests/test_charisma.gd` replays it.
##
## **Godot makes the wrong answer the easy one here, three times over.** Each
## trap is a shipped-data error, not a theoretical one:
##
## 1. [method quat_to_matrix] is **not** `Basis(Quaternion(x, y, z, w))`. The
##    engine's `0x004827B0` produces the *transpose* of the textbook `R(q)`
##    under its own row-major `M * v` reading -- equivalently `R(q*)` -- so a
##    stock conversion rotates every bone the wrong way (docs/40 section 6.1).
##    It also divides by the **squared norm** rather than assuming unit length,
##    which matters: 1 169 shipped keys are more than 1 % off unit.
## 2. [method log_q] and [method exp_q] are **not** the textbook quaternion
##    logarithm and exponential. The disassembly of `0x004AEFD1` and
##    `0x004AF04B` contains no `fsqrt`: both use `s = x^2 + y^2 + z^2` where
##    the textbook uses `|v|`. For small rotations the two agree to first
##    order, which is why "fixing" them still looks plausible and still does
##    not match the engine (docs/40 section 4.4).
## 3. The **hold rule** is not an optimisation to skip. A segment of
##    [constant HOLD_DT] frames or less returns one key outright, and 5.2 % of
##    the corpus' 896 443 segments are exactly 0.25 frames long.
##
## Sampling is `static` and stateless. The only per-track state is the squad
## control quaternions, which the engine derives once at **load** time
## (`0x004AD53E`) and which are therefore derived once here too, in
## [method _ensure_controls] -- not per frame, and not per unit.
##
## **Everything here stays in the engine's own representation**: a matrix is 16
## floats, row-major, applied as `M * v`, with the translation in the column at
## indices 3, 7 and 11 (docs/40 section 5.1). Nothing becomes a [Basis] or a
## [Transform3D] until [CharismaBody] places a mesh, which is the single point
## where Godot's column-major `B * v` convention and the engine's axis
## permutation are applied. Posing in Godot types instead would put a
## convention change inside every bone product, and the pose fixture -- which
## stores the engine's own 16 floats -- could not diff it element for element.

## `0x004B38E0` and `0x004B38F4`, shared by all five `GetValue`
## implementations: a segment this short or shorter is a hold, and `u` at or
## below the pick threshold returns the first of the two keys.
const HOLD_DT: float = 0.25
const HOLD_PICK: float = 0.5

## `0x004B3C58` -- below this, [method exp_q]'s scale factor is 1 rather than
## `sin(s) / s`.
const EXP_EPSILON: float = 1e-05
## `0x004B3C84` -- the weight in Shoemake's inner control point.
const CONTROL_WEIGHT: float = -0.25
## The threshold both of `SlerpQuat`'s degenerate branches test against.
const SLERP_EPSILON: float = 1e-06

## The three channel names `V100Part` matches against (`0x004A6598`).
const CHANNEL_POSITION: String = "Position"
const CHANNEL_ROTATION: String = "Rotation matrix"
const CHANNEL_VISIBILITY: String = "Visibility"

var target: String = ""
var channel: String = ""
var key_class: String = ""
## Floats per key **excluding** the time stamp.
var arity: int = 0
var count: int = 0
## `count * (1 + arity)` values: each key's time followed by its values.
##
## The file stores `f32` and the cache carries those exact bits; they are
## widened to `double` **once, here**, and every intermediate below is a
## double. That is not gold-plating -- it is what the reference does. The
## original ran on an x87 FPU whose intermediates are 80-bit, and
## `inclib/pose.py` computes in Python `float`, which is a double. Rounding
## each intermediate quaternion back to `f32` -- which an earlier draft did,
## simply by returning `PackedFloat32Array` from the helpers -- made squad's
## three nested slerps disagree with the reference by 1.8e-4 relative, a
## thousand times worse than the widening costs.
var _keys: PackedFloat64Array = PackedFloat64Array()
## Derived once for a `BezierRotationKey` track; empty otherwise.
var _controls: PackedFloat64Array = PackedFloat64Array()
var _controls_ready: bool = false


## Read one track out of a cached `animations/<name>.json` document.
static func from_document(document: Dictionary) -> CharismaTrack:
	var track: CharismaTrack = CharismaTrack.new()
	track.target = DictRead.as_string(document["target"])
	track.channel = DictRead.as_string(document["channel"])
	track.key_class = DictRead.as_string(document["key_class"])
	track.arity = DictRead.as_int(document["arity"])
	track.count = DictRead.as_int(document["count"])
	# The cache carries the file's own `f32` bit patterns, so this is the only
	# place a number becomes a float and it does so without ever having been
	# formatted (see `inclib/charisma_cache.py`).
	var raw: PackedByteArray = Marshalls.base64_to_raw(
		DictRead.as_string(document["keys"]))
	var floats: PackedFloat64Array = PackedFloat64Array()
	floats.resize(raw.size() / 4)
	for i: int in range(floats.size()):
		# `decode_float` reads the four bytes as `f32`; widening an `f32` to a
		# double is exact, so this is the file's own value and not a rounding.
		floats[i] = raw.decode_float(i * 4)
	track._keys = floats
	return track


## The stride of one key record: its time plus its values.
func stride() -> int:
	return 1 + arity


func time_of(index: int) -> float:
	return _keys[index * stride()]


## One key's values, without its time stamp.
func values_of(index: int) -> PackedFloat64Array:
	return _keys.slice(index * stride() + 1, (index + 1) * stride())


func duration() -> float:
	return 0.0 if count == 0 else time_of(count - 1)


## The key pair bracketing `t`, as `[index, u]`.
##
## `u` is meaningless when the pair is a hold or an endpoint; the samplers
## test for that themselves, exactly as the engine does.
func _segment(t: float) -> Array:
	if count == 0:
		return [0, 0.0]
	# Linear rather than bisected: tracks are short (a median of 12 keys) and
	# a scan has no index to keep in step with the caller's own time.
	var i: int = -1
	for k: int in range(count):
		if time_of(k) <= t:
			i = k
		else:
			break
	if i < 0:
		return [0, 0.0]
	if i >= count - 1:
		return [count - 1, 1.0]
	var dt: float = time_of(i + 1) - time_of(i)
	return [i, 0.0 if dt == 0.0 else (t - time_of(i)) / dt]


## True when the segment at `index` is a hold -- one key returned outright.
func _is_hold(index: int) -> bool:
	if count <= 1 or index >= count - 1:
		return true
	return time_of(index + 1) - time_of(index) <= HOLD_DT


# --------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------

## Rotation channel -> a 16-float engine matrix (`0x004A9A9A`, `0x004ACA7A`).
func sample_rotation(t: float) -> PackedFloat64Array:
	if count == 0:
		return identity()
	var found: Array = _segment(t)
	var i: int = found[0]
	var u: float = found[1]
	if _is_hold(i):
		var pick: int = i if u <= HOLD_PICK else mini(i + 1, count - 1)
		return quat_to_matrix(values_of(pick))
	if key_class == "BezierRotationKey":
		_ensure_controls()
		return quat_to_matrix(squad(values_of(i), _control(i), _control(i + 1),
			values_of(i + 1), u))
	return quat_to_matrix(slerp_q(values_of(i), values_of(i + 1), u))


## Position channel -> a vec3 in **engine** units (`0x004A8B72`, `0x004AB918`).
func sample_vector(t: float) -> Vector3:
	if count == 0:
		return Vector3.ZERO
	var found: Array = _segment(t)
	var i: int = found[0]
	var u: float = found[1]
	if _is_hold(i):
		var pick: int = i if u <= HOLD_PICK else mini(i + 1, count - 1)
		var held: PackedFloat64Array = values_of(pick)
		return Vector3(held[0], held[1], held[2])
	var a: PackedFloat64Array = values_of(i)
	var b: PackedFloat64Array = values_of(i + 1)
	if key_class == "LinearVectorKey":
		return Vector3(a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u,
			a[2] + (b[2] - a[2]) * u)
	# BezierVectorKey: [0:3] value, [3:6] in-tangent, [6:9] out-tangent.
	var dt: float = time_of(i + 1) - time_of(i)
	return Vector3(
		bezier_scalar(a[0], a[6], b[0], b[3], dt, u),
		bezier_scalar(a[1], a[7], b[1], b[4], dt, u),
		bezier_scalar(a[2], a[8], b[2], b[5], dt, u))


## Visibility channel -> a scalar (`0x004AA9DF`). The part is drawn when > 0.
func sample_float(t: float) -> float:
	if count == 0:
		return 1.0
	var found: Array = _segment(t)
	var i: int = found[0]
	var u: float = found[1]
	if _is_hold(i):
		var pick: int = i if u <= HOLD_PICK else mini(i + 1, count - 1)
		return values_of(pick)[0]
	var a: PackedFloat64Array = values_of(i)
	var b: PackedFloat64Array = values_of(i + 1)
	if key_class == "LinearFloatKey":
		return a[0] + (b[0] - a[0]) * u
	# BezierFloatKey: [0] value, [1] in-tangent, [2] out-tangent.
	return bezier_scalar(a[0], a[2], b[0], b[1], time_of(i + 1) - time_of(i), u)


# --------------------------------------------------------------------------
# The engine's quaternion algebra
# --------------------------------------------------------------------------

## A 4x4 identity in the engine's row-major layout.
static func identity() -> PackedFloat64Array:
	return PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0])


## `a * b` in the engine's row-major `M * v` convention (`0x00482AB3`).
static func mat_mul(a: PackedFloat64Array,
		b: PackedFloat64Array) -> PackedFloat64Array:
	var out: PackedFloat64Array = PackedFloat64Array()
	out.resize(16)
	for row: int in range(4):
		for column: int in range(4):
			var total: float = 0.0
			for k: int in range(4):
				total += a[row * 4 + k] * b[k * 4 + column]
			out[row * 4 + column] = total
	return out


## The translation column of a row-major `M * v` matrix (`0x004828CD`).
static func mat_translation(m: PackedFloat64Array) -> Vector3:
	return Vector3(m[3], m[7], m[11])


## A copy of `m` whose translation column is replaced (`0x004828E7`).
static func mat_with_translation(m: PackedFloat64Array,
		t: Vector3) -> PackedFloat64Array:
	var out: PackedFloat64Array = m.duplicate()
	out[3] = t.x
	out[7] = t.y
	out[11] = t.z
	return out


## Four stored floats -> a rotation matrix, 16 floats row-major (`0x004827B0`).
##
## **Do not replace this with `Basis(Quaternion(q[0], q[1], q[2], q[3]))`.**
## The engine's matrix is the transpose of the textbook `R(q)` under its own
## row-major `M * v` convention, and it divides by the squared norm instead of
## assuming unit length. Both differences are visible on shipped data: the
## first mirrors every rotation, the second mis-scales the 1 169 keys that are
## more than 1 % off unit, by up to 40 %.
##
## `q[3]` is the scalar `w`: it is the only component absent from all three
## diagonal terms, and `(w, x, y, z)` would put `w` on the diagonal, which no
## rotation matrix does (docs/40 section 6.1).
static func quat_to_matrix(q: PackedFloat64Array) -> PackedFloat64Array:
	var a: float = q[0]
	var b: float = q[1]
	var c: float = q[2]
	var d: float = q[3]
	var n: float = a * a + b * b + c * c + d * d
	var s: float = 0.0 if n == 0.0 else 2.0 / n
	var m: PackedFloat64Array = identity()
	m[0] = 1.0 - (s * c * c + s * b * b)
	m[1] = s * b * a + d * s * c
	m[2] = s * c * a - d * s * b
	m[4] = s * b * a - d * s * c
	m[5] = 1.0 - (s * c * c + s * a * a)
	m[6] = s * a * d + s * c * b
	m[8] = d * s * b + s * c * a
	m[9] = s * c * b - s * a * d
	m[10] = 1.0 - (s * b * b + s * a * a)
	return m


## Shoemake's `SlerpQuat` (`0x004AEDC7`), including its perpendicular branch.
static func slerp_q(p: PackedFloat64Array, q: PackedFloat64Array,
		t: float) -> PackedFloat64Array:
	var cosom: float = p[0] * q[0] + p[1] * q[1] + p[2] * q[2] + p[3] * q[3]
	var s0: float = 0.0
	var s1: float = 0.0
	if 1.0 + cosom <= SLERP_EPSILON:
		# Nearly opposite: rotate through an arbitrary perpendicular. The
		# index pattern `(-p.y, p.x, -p.w, p.z)` is the second independent
		# witness for the `(x, y, z, w)` order (docs/40 section 6.1).
		var half_pi: float = PI / 2.0
		s0 = sin((1.0 - t) * half_pi)
		s1 = sin(t * half_pi)
		return PackedFloat64Array([s0 * p[0] - s1 * p[1],
			s0 * p[1] + s1 * p[0], s0 * p[2] - s1 * p[3],
			s0 * p[3] + s1 * p[2]])
	if 1.0 - cosom <= SLERP_EPSILON:
		s0 = 1.0 - t
		s1 = t
	else:
		var omega: float = acos(clampf(cosom, -1.0, 1.0))
		var sinom: float = sin(omega)
		s0 = sin((1.0 - t) * omega) / sinom
		s1 = sin(t * omega) / sinom
	return PackedFloat64Array([s0 * p[0] + s1 * q[0], s0 * p[1] + s1 * q[1],
		s0 * p[2] + s1 * q[2], s0 * p[3] + s1 * q[3]])


## Hamilton product on `(x, y, z, w)` quaternions (`0x004AECB0`).
static func mul_q(a: PackedFloat64Array,
		b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([
		a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
		a[3] * b[1] + a[1] * b[3] + a[2] * b[0] - a[0] * b[2],
		a[3] * b[2] + a[2] * b[3] + a[0] * b[1] - a[1] * b[0],
		a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]])


## `q* / |q|^2` (`0x004AED3F`) -- the squared norm again, not a unit assumption.
static func inverse_q(q: PackedFloat64Array) -> PackedFloat64Array:
	var n: float = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]
	if n == 0.0:
		return PackedFloat64Array([-q[0], -q[1], -q[2], q[3]])
	return PackedFloat64Array([-q[0] / n, -q[1] / n, -q[2] / n, q[3] / n])


## The engine's quaternion logarithm (`0x004AEFD1`) -- **not** the textbook one.
##
## It scales the vector part by `atan2(s, w) / s` with `s = x^2 + y^2 + z^2`,
## where the textbook uses `|v|`. There is no `fsqrt` in the disassembly.
static func log_q(q: PackedFloat64Array) -> PackedFloat64Array:
	var s: float = q[0] * q[0] + q[1] * q[1] + q[2] * q[2]
	var t: float = atan2(s, q[3])
	if s > 0.0:
		s = t / s
	return PackedFloat64Array([q[0] * s, q[1] * s, q[2] * s, 0.0])


## The engine's quaternion exponential (`0x004AF04B`), mirroring [method log_q].
static func exp_q(v: PackedFloat64Array) -> PackedFloat64Array:
	var s: float = v[0] * v[0] + v[1] * v[1] + v[2] * v[2]
	var k: float = sin(s) / s if s > EXP_EPSILON else 1.0
	return PackedFloat64Array([v[0] * k, v[1] * k, v[2] * k, cos(s)])


## Shoemake's inner spline control quaternion (`0x004AF0D1`).
static func spline_control(prev: PackedFloat64Array, q: PackedFloat64Array,
		nxt: PackedFloat64Array) -> PackedFloat64Array:
	var qinv: PackedFloat64Array = inverse_q(q)
	var l_prev: PackedFloat64Array = log_q(mul_q(qinv, prev))
	var l_next: PackedFloat64Array = log_q(mul_q(qinv, nxt))
	var inner: PackedFloat64Array = PackedFloat64Array()
	inner.resize(4)
	for i: int in range(4):
		inner[i] = CONTROL_WEIGHT * (l_prev[i] + l_next[i])
	return mul_q(q, exp_q(inner))


## `slerp(slerp(p, q, u), slerp(a, b, u), 2u(1 - u))` (`0x004AEF75`).
static func squad(p: PackedFloat64Array, a: PackedFloat64Array,
		b: PackedFloat64Array, q: PackedFloat64Array,
		u: float) -> PackedFloat64Array:
	return slerp_q(slerp_q(p, q, u), slerp_q(a, b, u), (1.0 - u) * u * 2.0)


## One cubic Bezier segment (`0x004AA9DF`, `0x004AB918`).
##
## The tangents are slopes in value units per time unit, so the control points
## are `v0 + out0 * dt/3` and `v1 + in1 * dt/3` -- they are not pre-scaled
## offsets, and treating them as such collapses every curve toward its chord.
static func bezier_scalar(v0: float, out0: float, v1: float, in1: float,
		dt: float, u: float) -> float:
	var third: float = dt / 3.0
	var w: float = 1.0 - u
	var c1: float = v0 + out0 * third
	var c2: float = v1 + in1 * third
	return v1 * u * u * u + 3.0 * c2 * u * u * w + 3.0 * c1 * u * w * w \
		+ v0 * w * w * w


# --------------------------------------------------------------------------
# The per-track control quaternions
# --------------------------------------------------------------------------

## Derive the squad controls once, as `0x004AD53E` does at load time.
##
## Its two boundary rules are the engine's: the first key uses its successor as
## its predecessor, and the last uses its predecessor as its successor. A
## single-key track sees the loop's zero-initialised locals on both sides,
## which [method log_q] and [method exp_q] turn into the identity.
func _ensure_controls() -> void:
	if _controls_ready:
		return
	_controls_ready = true
	if key_class != "BezierRotationKey" or count == 0:
		return
	_controls.resize(count * 4)
	var prev: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for i: int in range(count):
		if i != 0:
			prev = values_of(i - 1)
		var nxt: PackedFloat64Array = prev if i == count - 1 else values_of(i + 1)
		if i == 0:
			prev = nxt
		var control: PackedFloat64Array = spline_control(prev, values_of(i), nxt)
		for c: int in range(4):
			_controls[i * 4 + c] = control[c]


func _control(index: int) -> PackedFloat64Array:
	return _controls.slice(index * 4, index * 4 + 4)
