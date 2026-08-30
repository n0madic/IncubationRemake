class_name WorldSpace
extends RefCounted

## The one place the engine's coordinate convention meets Godot's.
##
## docs/30 section 2.5: engine world space is **X right, Y into the screen,
## Z up**, and one map field is 3200 world units, one metre 1600.  Godot is
## Y-up, -Z forward.  The mapping is
##
##     godot = Vector3(ex, ez, -ey) / 1600
##
## which preserves handedness -- `ex x ey = ez` still holds after it -- so a
## mesh does not come out mirrored.  Nothing else in `game/` is allowed to
## write this conversion out by hand.

const WORLD_UNITS_PER_METRE: float = 1600.0
const WORLD_UNITS_PER_FIELD: int = 3200
const FIELD_METRES: float = 2.0
## docs/10 -- a full turn in the engine's angle units.
const ANGLE_FULL_TURN: int = 4096
## docs/31 section 4.3 -- texture coordinates are 8.7 fixed point.
const UV_SCALE: float = 32768.0


static func to_godot(ex: int, ey: int, ez: int) -> Vector3:
	return Vector3(float(ex), float(ez), -float(ey)) / WORLD_UNITS_PER_METRE


static func to_godot_v(v: Vector3) -> Vector3:
	return Vector3(v.x, v.z, -v.y) / WORLD_UNITS_PER_METRE


## The centre of map field `(x, y)` at engine height `h`.
static func cell_centre(x: int, y: int, h: int) -> Vector3:
	return Vector3(float(x) * FIELD_METRES, float(h) / WORLD_UNITS_PER_METRE,
		-float(y) * FIELD_METRES)


## An engine yaw as a Godot basis.  Taken modulo a full turn because the corpus
## carries accumulated values well past 4096.
static func yaw_basis(yaw: int) -> Basis:
	var turns: float = float(posmod(yaw, ANGLE_FULL_TURN)) / float(ANGLE_FULL_TURN)
	return Basis(Vector3.UP, turns * TAU)


## The same engine yaw, for a Charisma **body** rather than for Eng3d geometry.
##
## It is not [method yaw_basis] and the difference is measured, not a nudge to
## make a screenshot look right.  A Charisma model is authored facing engine
## **-Y** ([constant CharismaBody.AUTHORED_FORWARD]), and with that forward
## there is **no** angle convention under which `docs/10` section 5.10's own
## facing table sends all eight facings the right way: taken as a plain
## rotation it agrees on the two facings along X and is mirrored in Y on the
## other six.  Half a turn minus the angle agrees on all eight, and it is the
## only such correction:
##
##     facing  0    1    2    3     4     5     6     7     (docs/10 5.10)
##     angle   0    3072 2048 1024  1536  3584  512   2560
##     step   +y   -x   -y   +x    +x-y  -x+y  +x+y  -x-y   (`FACING_OF_STEP`)
##     needed  180  270  0    90    45    225   135   315   = 2048 - angle
##
## **Where the engine does this is UNVERIFIED**, exactly as `docs/40` section
## 5.3's scale is: the Charisma-to-Eng3d bridge is not decompiled.  A rotation
## is chosen over the mirror that would also fit because a mirror flips the
## body left for right, and the marine carries its weapon in `Hand_R`.  One
## screenshot of the original showing the weapon in the *left* hand closes that
## question the other way.
static func charisma_yaw_basis(yaw: int) -> Basis:
	return yaw_basis(ANGLE_FULL_TURN / 2 - yaw)


## A whole engine matrix -- 16 floats, row-major, applied as `M * v`
## (docs/40 section 5.1) -- as a Godot [Transform3D].
##
## This is [method to_godot] generalised from a point to a frame, and it is
## derived rather than guessed. A point maps as `g = S * P * e` with
## `P = [[1,0,0],[0,0,1],[0,-1,0]]` the axis permutation and `S` the metre
## scale, so a transform maps as
##
##     basis  = P * R * P^T          (the scale cancels: it is uniform)
##     origin = to_godot(translation)
##
## Written out, the columns below are that product. Godot's [Basis] takes
## **columns**, and the engine's matrix is stored by **rows**, which is the
## transposition that has to happen exactly once and here.
##
## The failure modes are unmistakable if looked at: a wrong permutation lays
## the body on its side, a wrong handedness mirrors it. `test_charisma.gd`
## checks the three properties that pin it -- identity, composition, and an
## engine yaw against [method yaw_basis].
static func engine_matrix(m: PackedFloat64Array) -> Transform3D:
	var basis: Basis = Basis(
		Vector3(m[0], m[8], -m[4]),
		Vector3(m[2], m[10], -m[6]),
		Vector3(-m[1], -m[9], m[5]))
	return Transform3D(basis, to_godot_v(Vector3(m[3], m[7], m[11])))


static func uv(u: int, v: int) -> Vector2:
	return Vector2(float(u), float(v)) / UV_SCALE
