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


## The inverse of [method to_godot]: a Godot position back into engine units.
##
## Truncated, not rounded, because every consumer is an engine routine that
## works on integers -- the camera flight of docs/42 section 2.2 is one -- and
## a rounding here would put a half unit into arithmetic the engine does in
## whole ones.
static func from_godot(v: Vector3) -> Vector3i:
	return Vector3i(int(v.x * WORLD_UNITS_PER_METRE),
		int(-v.z * WORLD_UNITS_PER_METRE), int(v.y * WORLD_UNITS_PER_METRE))


## The centre of map field `(x, y)` at engine height `h`.
static func cell_centre(x: int, y: int, h: int) -> Vector3:
	return Vector3(float(x) * FIELD_METRES, float(h) / WORLD_UNITS_PER_METRE,
		-float(y) * FIELD_METRES)


## An engine yaw as a Godot basis.  Taken modulo a full turn because the corpus
## carries accumulated values well past 4096.
##
## **The angle is negated**, and that is measured rather than argued.  A placed
## object's heading is the third component of the rotation triple at `+0x20`
## (docs/10 section 6), and the engine turns it with exactly the machinery a
## joint angle goes through -- so this *is* [method joint_basis] with only its
## third component, and `test_effects.gd` pins the two together rather than
## letting them be two rules.  Every link of the chain:
##
## * **6332 of the 6333** yawed special objects in the 155 shipped `.lev` are
##   drawn by a prototype whose render program carries `joint_rotate_3` at anim
##   offset **0**, which is the object record's own triple.  The one that is
##   not is a single `L096EF00.3DI`, which the engine therefore draws unturned.
##   At offset 0 the whole 26 072-prototype corpus uses only that opcode and
##   its `_alt`; no placed heading reaches `_E3D_init_matrix_RyRxRz`, which is
##   the one builder that does **not** negate.
## * `+0x20` and `+0x22` are zero in all 194 105 records (`lev_parse.py
##   --check`, 155/155), so that opcode takes its own pure-yaw fast path --
##   `or ax, cx / je` at `Eng3d.dll+0x40601E` -- into the single-angle builder
##   `+0x411A59` rather than into a three-angle one.
## * `+0x411A59` and `E3D_init_matrix_RzRxRy` (`+0x411BF6`) answer the same
##   rotation for a pure yaw, and the second is reproduced 8/8 against a live
##   `Incubation.exe` (docs/97 section 18.1).
## * the result lands docs/10 section 5.10's eight headings on the eight steps
##   `aExecuteUse` takes -- **8 of 8**, where the un-negated angle agrees only
##   on the two a sign cannot move.
##
## Until 2026-09-04 this was `+turns`, which is right on yaw 0 and 2048 and
## half a turn out on 1024 and 3072.  The shipped world is built on quarter
## turns and most of its geometry is symmetric end for end, which is why it
## survived being looked at (docs/97 section 47).
static func yaw_basis(yaw: int) -> Basis:
	return Basis(Vector3.UP, -_turns(yaw))


## A joint-angle triple as a Godot basis: the three-axis rotation the engine's
## own matrix builder makes of it.
##
## docs/28 section 7.8 -- the render opcodes read three consecutive `i16` out of
## the object's joint buffer and hand them to a matrix builder. docs/30 section
## 2.5 left **which** builder open ("the composition order is prototype data,
## not a format constant"); it is readable, and the fifth slice read it: the two
## opcodes that place a jointed part, `joint_rotate_3` (`Eng3d.dll+0x405FFC`)
## and `joint_place` (`Eng3d.dll+0x4060F0`), both call
## `E3D_init_matrix_RzRxRy` at `Eng3d.dll+0x411BF6`. So the order here is not a
## guess.
##
## Nor is the **completeness** of that, measured on 2026-09-04: over all 26 072
## prototypes the *render* stream -- the only one that draws -- carries exactly
## three of the seven rotation opcodes, `joint_rotate_3` at anim offset 0
## (1959), `joint_rotate_3_alt` at 0 (367) and `joint_place` at 6 and 12 (213).
## The third opcode that reaches the non-negating `_E3D_init_matrix_RyRxRz`,
## `matrix_from_angles`, appears in no render stream at all, and
## `joint_rotate_3_alt` branches into the single-angle builder `+0x411A59` for
## the pure-yaw triples the shipped data holds -- which agrees with `+0x411BF6`.
## So **every rotation the renderer applies negates its angle**, and the three
## offsets [method BlobModels._triple_basis] honours are the three that exist.
##
## The components are in **engine axis order and are not reordered** (docs/30
## section 2.5): the first is about engine X, the second about engine Y, the
## third about engine Z -- the yaw, which is the one docs/30 had already closed.
## Both blob arms that write these agree: kind 54 spins its flame billboards by
## putting a random value in the **third** component, which is a spin about
## vertical, and kind 42 flips its panel plate with the **second**.
##
## **What stays a choice** is the handedness of the composition once it is
## carried across into Godot's column-vector convention: the engine transforms
## row vectors (`out[j] = sum_i M[3i+j] * v[i]`, docs/30 section 2.5). This
## composes the three rotations in the builder's own name order under Godot's
## convention, which reproduces every single-axis case exactly -- and every
## shipped joint animation is single-axis per part.
static func joint_basis(ax: int, ay: int, az: int) -> Basis:
	# Each engine axis, in Godot's frame, under the `(x, z, -y)` mapping at the
	# top of this file: engine X is Godot X, engine Y is Godot -Z, engine Z is
	# Godot Y. `BACK` is the *negated* image of engine Y, which is why that one
	# term carries an extra minus beyond the negation below.
	#
	# **The angles are negated**, which is the builder's own first three
	# instructions (`neg ebx / neg ecx / neg edx`, `97` section 18.1) and was
	# missing here until 2026-09-03. Two independent things say so besides the
	# listing: an Eng3d model is authored along engine **+Y** (`A_LINE5.3DI` is
	# 1600 units long in Y and 242 wide in X) and `0x00403AA0` measures its
	# bearing from **+Y** toward +X, so a model turned by its own bearing must
	# rotate the short way round -- and [method charisma_yaw_basis], measured
	# against `10` section 5.10's facing table long before this, is the same
	# negation plus the half turn a body's -Y forward needs. With the sign the
	# wrong way a shot's tracer flew across its own path (`97` section 46.5).
	var rx: Basis = Basis(Vector3.RIGHT, -_turns(ax))
	var ry: Basis = Basis(Vector3.BACK, _turns(ay))
	var rz: Basis = Basis(Vector3.UP, -_turns(az))
	return rz * rx * ry


static func _turns(angle: int) -> float:
	return float(posmod(angle, ANGLE_FULL_TURN)) / float(ANGLE_FULL_TURN) * TAU


## The same engine yaw, for a Charisma **body** rather than for Eng3d geometry.
##
## It is not [method yaw_basis], and the difference is now a single geometric
## fact rather than a fitted correction.  Eng3d geometry is authored along
## engine **+Y**; a Charisma model is authored facing engine **-Y**
## ([constant CharismaBody.AUTHORED_FORWARD]).  So a body needs its object's
## heading plus **half a turn**, and nothing else:
##
##     facing  0    1    2    3     4     5     6     7     (docs/10 5.10)
##     angle   0    3072 2048 1024  1536  3584  512   2560
##     step   +y   -x   -y   +x    +x-y  -x+y  +x+y  -x-y   (`FACING_OF_STEP`)
##
## `test_charisma.gd` walks that table and checks both halves of it: the body's
## forward against the step, and the Eng3d forward the node carries against the
## same step.
##
## This used to read `2048 - yaw`, fitted against the table while
## [method yaw_basis] still turned the wrong way.  `-(yaw + 2048)` and
## `2048 - yaw` are the same angle modulo a full turn, so no body moved when
## the sign was corrected on 2026-09-04 -- only the reason did, and it is a
## better one: the earlier note had to weigh a **mirror** that would fit the
## table equally well, and a half turn for a backwards-authored model leaves
## nothing for a mirror to explain.
##
## **Where the engine does it**: `0x0042C900` builds the placement through
## `_E3D_init_matrix_RzRxRy` with `az + 0x800` (`0x0042C943`), a half turn
## about the model's own up axis -- a rotation, determinant +1 on all eight
## facings, not a mirror (docs/40 section 5.4).
static func charisma_yaw_basis(yaw: int) -> Basis:
	return yaw_basis(yaw + ANGLE_FULL_TURN / 2)


## The same half turn on its own, for a body whose object is not level.
##
## [method charisma_yaw_basis] is [method yaw_basis] with half a turn added
## to the angle, and about one axis that is the same as multiplying by half
## a turn afterwards -- so this is that factor, and `node.basis * this` is
## the body's frame for **any** object rotation, not only a yaw. A falling
## footbridge's rider is the one that needs it: its own `+0x22` is turned as
## well as its `+0x24` (docs/42 section 8.3), so its object is tilted and a
## half turn about the world's vertical would no longer be a half turn about
## the model's. `test_effects.gd` pins the two against each other on a level
## body, which is where they must agree.
static func charisma_offset() -> Basis:
	return Basis(Vector3.UP, -PI)


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
## the body on its side, a wrong handedness mirrors it. What pins it is
## `test_charisma.gd`'s bone sweep -- every bone's **full local matrix** at one
## frame against `tools/cha_parse.py`'s, for every (model, clip) pairing -- so
## a permutation or a handedness error shows up as a numeric difference rather
## than as something to notice in a screenshot.
static func engine_matrix(m: PackedFloat64Array) -> Transform3D:
	var basis: Basis = Basis(
		Vector3(m[0], m[8], -m[4]),
		Vector3(m[2], m[10], -m[6]),
		Vector3(-m[1], -m[9], m[5]))
	return Transform3D(basis, to_godot_v(Vector3(m[3], m[7], m[11])))


static func uv(u: int, v: int) -> Vector2:
	return Vector2(float(u), float(v)) / UV_SCALE
