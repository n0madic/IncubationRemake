class_name MeshBuilder
extends RefCounted

## Portable geometry into an [ArrayMesh].
##
## One surface per `(draw_kind, texture)` pair.  Polygons arrive as polygons --
## triangulation is a rendering decision and the cache does not make it -- and
## are triangulated here.
##
## **Faces are ear-clipped, not fanned.**  A fan is only a correct
## triangulation of a convex polygon, and the shipped geometry is not all
## convex: `tools/prototyp_parse.py --check` counts **1572 reflex faces** among
## the 236 861, 81 of them in `World_A00`, which two of the slice's three
## missions use.  A bad fan is silent -- it emits a triangle outside the
## polygon and misses one inside, and looks like a modelling error -- so the
## check that counts them is what retired the manual `--obj` cross-check.
## Faces carry three to **twenty-four** indices, not the three to eight docs/31
## used to say.
##
## Exact planarity is *not* required and is not claimed: only 144 877 of the
## faces are exactly planar in integer world units, because the corpus is
## authored on an integer grid. Triangulating in the plane of the Newell normal
## is what a scanline fill of the same polygon approximates.
##
## Materials follow docs/31 section 4.4's "consequences for a remake" table.
## The original bakes its light into the textures and into the per-face colour,
## so **any** Godot lighting would be an infidelity: every material is
## unshaded.

## docs/31 section 4.3 -- the byte offset into the active draw-routine table,
## which is what the face record carries.
const KIND_FLAT: int = 0x00
const KIND_GOURAUD: int = 0x04
const KIND_TEXTURE: int = 0x08
const KIND_FLAT_BLEND: int = 0x0C
const KIND_TEXTURE_PERSP: int = 0x10
const KIND_TEXTURE_MASKED: int = 0x14
const KIND_TEXTURE_SWITCHED: int = 0x18
const KIND_TEXTURE_ADD: int = 0x1C
const KIND_TEXTURE_SUB: int = 0x20
const KIND_TEXTURE_ENV: int = 0x24
const KIND_NONE: int = 0x28

## Kinds the engine queues and draws after all opaque geometry.
const DEFERRED_KINDS: Array[int] = [KIND_FLAT_BLEND, KIND_TEXTURE_MASKED,
	KIND_TEXTURE_ADD, KIND_TEXTURE_SUB]
## Kinds that ignore their texture and paint the face colour: the two flat
## fills, the ramp-shaded one whose ramp is not modelled, and the
## distance-switched one whose textured branch calls a pointer the DLL never
## sets (docs/31 section 4.4), so only its flat fallback ever paints.
const FLAT_KINDS: Array[int] = [KIND_FLAT, KIND_GOURAUD, KIND_FLAT_BLEND,
	KIND_TEXTURE_SWITCHED]

## `0x410B12` is a bare `ret`.
const DRAWS_NOTHING: Array[int] = [KIND_NONE]

## `0x004089BB` -- an exact half-and-half RGB565 blend.
const BLEND_ALPHA: float = 0.5
## SurfaceTool's smooth group for faceted normals.
const FLAT_SMOOTH_GROUP: int = -1

const NO_TEXTURE: int = -1

## The face key the converter sets on a face the engine draws **under** other
## coplanar faces of the same prototype (`tools/inclib/overdraw.py`): how many
## layers of earlier-drawn overlapping faces lie over it.
const OVERDRAW: String = "overdraw"
## How far one overdraw layer recedes, in world units.  The software renderer
## has no depth buffer: its span buffer (`Eng3d.dll` `0x40DAF0`) skips the
## depth test between spans of one `draw_faces` program and lets the span
## already stored hide the new one, so of two exactly coplanar faces the one
## the front-to-back tree walk reaches first wins.  A depth buffer has no such
## rule and z-fights instead -- the iris on `_C_154`'s landing platform
## (`LEVEL09A.005`, faces 12..19) showed a different set of blades every
## frame.  Pushing each losing layer back sixteen units (1 cm) along its face
## normal reproduces the engine's answer: the winner stays where it was and
## the losers sit behind it.  The step is sized for the depth buffer this
## project renders with -- `gl_compatibility`, 24 bits, not reversed, near
## plane 0.05 m -- whose resolution is about z^2 / (near * 2^24): 0.5 mm at
## 20 m, 3 mm at 50 m, 5 mm at 64 m, the far corner of a 40 x 40 map.  Four
## units (2.5 mm) held the iris at the deployment camera and would have let
## it fight again from across the map.
const OVERDRAW_STEP: float = 16.0 / WorldSpace.WORLD_UNITS_PER_METRE

## [method build_scope]'s "everything the parts do not own".
const ROOT_SCOPE: int = -1

## `textures` is `{"plain": {id: Texture2D}, "keyed": {id: Texture2D}}`.  The
## keyed copies carry alpha 0 wherever the texel is exactly black, which is
## what draw kind `0x14` treats as a hole; [method keyed_texture] makes each
## the first time a face asks for it.
const PLAIN: String = "plain"
const KEYED: String = "keyed"
## `{id: path}` of each texture's PNG, which [method keyed_texture] decodes
## again rather than reading a texture back from the renderer.
const SOURCES: String = "sources"
## `{name: id}` for the world set in use, added by [method load_textures] so a
## face can name its texture instead of numbering it.
const BY_NAME: String = "by_name"
## [PaletteCurve]'s table for the running renderer, or an empty array where
## the renderer draws a byte as it is.  The bank's textures already carry it;
## a flat face's colour goes through it in [method _surface].
const CURVE: String = "curve"
## The bank's [GraphicsMode] sampling, which [method material_for] reads.
## Absent means nearest.
const SAMPLING: String = "sampling"
## Whether the cache's pages are the exact 24-bit decode (`"precision":
## "rgb888"` in the texture index, docs/92 section 7.29) ...
const EXACT: String = "exact"
## ... and whether this bank draws them quantised to the engine's RGB565.
const QUANTISED: String = "quantised"
const PRECISION_EXACT: String = "rgb888"
## The largest byte that quantises to field value 0: `(8 * 31) // 255` and
## `(4 * 63) // 255` are 0, `(9 * 31) // 255` and `(5 * 63) // 255` are 1.
const KEY_LIMIT_5: int = 8
const KEY_LIMIT_6: int = 4
## The meta every material [method material_for] gives a texture carries, so
## [method set_smooth] can find them among everything else a tree holds.
const SMOOTHABLE_META: StringName = &"mesh_builder_texture"
## Where the scene material's variants live, one file per draw-kind class.
const SHADER_DIR: String = "res://game/shaders/scene_"
## The CUSTOM channel that carries [method face_rect].
const FACE_RECT_CHANNEL: int = 0
const SHADER_SUFFIX: String = ".gdshader"
const VARIANT_OPAQUE: String = "opaque"
const VARIANT_MASKED: String = "masked"
const VARIANT_MASKED_DOUBLE: String = "masked_double"
const VARIANT_ADD: String = "add"
const VARIANT_SUB: String = "sub"
const VARIANT_FLAT: String = "flat"
const VARIANT_FLAT_BLEND: String = "flat_blend"
## The variants that take the effects' light and the sun's shadow
## (`#define LIT`), whose vertex alpha is free.
const LIT_VARIANTS: Array[String] = [VARIANT_OPAQUE, VARIANT_MASKED,
	VARIANT_MASKED_DOUBLE, VARIANT_FLAT]
## A lit face's vertex alpha when it takes the sun's shadow on every face (a
## body's); 1 when only on faces turned to the sun (the scene's).
const SUN_ALL_FACES: float = 0.0

## The key a face of the **shared unit geometry** carries instead of `texture`.
##
## A unit body is the same mesh in every world set, but a texture *id* is not:
## `caan0000` is 7 in `A00` and 8 in `E00`, and only 9 of the 29 shared names
## keep their id.  So `geometry/units.json` names its textures and the id is
## resolved here, against whichever set the mission uses.  The per-set
## `geometry/<ws>.json` documents are unaffected and still carry `texture`.
const TEXTURE_NAME: String = "texture_name"


## The node names of an assembled prototype: the root scope's mesh, a part's
## pivot by index, and the mesh under a pivot.
const BODY_NODE: String = "body"
const PART_NODE: String = "part_%d"
const PART_MESH_NODE: String = "mesh"


## `body` marks the lit faces to take the sun's shadow on every face
## ([constant SUN_ALL_FACES]) -- a Charisma body's parts, whose shadow map
## holds no body ([SunShadow]).
static func build(prototype: Dictionary,
		textures: Dictionary, body: bool = false) -> ArrayMesh:
	return build_scope(prototype, textures, ROOT_SCOPE, body)


## One prototype as a node tree: a [constant BODY_NODE] [MeshInstance3D] for
## the root scope and, per `part_push`, a [constant PART_NODE] pivot at the
## part's translation holding a [constant PART_MESH_NODE] child.
##
## This is the shape [BlobModels] draws an articulated effect model in, and
## since 2026-09-06 the shape [Scenery] draws **every** placed object in --
## because a door *is* an articulated model. `L100EX00.3DI` has no root
## geometry at all: all sixteen of its vertices belong to its two leaves,
## parts 6 and 12, and `aDoorOpenSequence` turns their joints (docs/26
## section 3.4). A scenery that built the root scope alone got an empty mesh
## for it and drew nothing, which is what every empty doorway was.
##
## `meshes` caches one [ArrayMesh] per `"<name>/<scope>"` across calls.
## Answers `null` when nothing draws, which a caller counts as "not built".
static func assemble(name: String, prototype: Dictionary, textures: Dictionary,
		meshes: Dictionary[String, ArrayMesh]) -> Node3D:
	var root: Node3D = Node3D.new()
	var body: ArrayMesh = cached_scope(name, ROOT_SCOPE, prototype, textures,
		meshes)
	if body != null and body.get_surface_count() > 0:
		var instance: MeshInstance3D = MeshInstance3D.new()
		instance.name = BODY_NODE
		instance.mesh = body
		root.add_child(instance)
	var parts: Array = DictRead.as_array(prototype.get("parts", []))
	for index: int in range(parts.size()):
		var pivot: Node3D = Node3D.new()
		pivot.name = PART_NODE % index
		pivot.position = part_translation(DictRead.as_dict(parts[index]))
		var mesh: ArrayMesh = cached_scope(name, index, prototype, textures,
			meshes)
		if mesh != null and mesh.get_surface_count() > 0:
			var child: MeshInstance3D = MeshInstance3D.new()
			child.name = PART_MESH_NODE
			child.mesh = mesh
			pivot.add_child(child)
		root.add_child(pivot)
	if root.get_child_count() == 0:
		root.free()
		return null
	return root


## [method build_scope] through a per-`(name, scope)` cache.
static func cached_scope(name: String, scope: int, prototype: Dictionary,
		textures: Dictionary, meshes: Dictionary[String, ArrayMesh]) -> ArrayMesh:
	var key: String = "%s/%d" % [name, scope]
	if meshes.has(key):
		return meshes[key]
	var mesh: ArrayMesh = build_scope(prototype, textures, scope)
	meshes[key] = mesh
	return mesh


## A part's `part_push` translation, in Godot units -- where its pivot sits
## under the object and what its own vertices were localised against.
static func part_translation(part: Dictionary) -> Vector3:
	var t: Array = DictRead.as_array(part.get("translation", []))
	if t.size() < 3:
		return Vector3.ZERO
	return WorldSpace.to_godot(DictRead.as_int(t[0]), DictRead.as_int(t[1]),
		DictRead.as_int(t[2]))


## The `joint_place` offset each part is authored under, by part index --
## `null` for a part the shipped data never rotates -- so a caller can find
## the pivot a joint triple belongs to.
static func part_anims(prototype: Dictionary) -> Array:
	var out: Array = []
	for entry: Variant in DictRead.as_array(prototype.get("parts", [])):
		out.append(DictRead.as_dict(entry).get("anim", null))
	return out


## The whole prototype (`scope == ROOT_SCOPE`), or one articulated sub-object.
##
## docs/28 section 7.8: a prototype with `parts` draws each of them under its
## own joint rotation, so a single mesh cannot show it moving. Splitting is by
## **vertex ownership** -- the converter emits each part's vertex slots -- and a
## face belongs to the part its first corner does, which is exactly how the
## engine's `part_push` index base works: a face never straddles a scope.
##
## A part's vertices come back in **part-local space**, with the `part_push`
## translation subtracted, so the caller can put the translation on the node
## and rotate about the joint rather than about the model origin.
static func build_scope(prototype: Dictionary, textures: Dictionary,
		scope: int, body: bool = false) -> ArrayMesh:
	var vertices: Array = DictRead.as_array(prototype["vertices"])
	var faces: Array = DictRead.as_array(prototype["faces"])
	var parts: Array = DictRead.as_array(prototype.get("parts", []))
	if not parts.is_empty():
		var owner: PackedInt32Array = _ownership(vertices.size(), parts)
		faces = _faces_in(faces, owner, scope)
		if scope != ROOT_SCOPE and scope < parts.size():
			vertices = _localised(vertices,
				DictRead.as_array(DictRead.as_dict(parts[scope])["translation"]))
	elif scope != ROOT_SCOPE:
		return ArrayMesh.new()
	var buckets: Dictionary = {}
	for entry: Variant in faces:
		var face: Dictionary = DictRead.as_dict(entry)
		var kind: int = DictRead.as_int(face.get("draw_kind", KIND_TEXTURE))
		if DRAWS_NOTHING.has(kind):
			continue
		var texture: int = NO_TEXTURE if FLAT_KINDS.has(kind) \
			else _texture_of(face, textures)
		var key: String = "%03d.%04d" % [kind, texture + 1]
		if not buckets.has(key):
			buckets[key] = []
		var bucket: Array = buckets[key]
		bucket.append(face)

	var mesh: ArrayMesh = ArrayMesh.new()
	var keys: Array = buckets.keys()
	keys.sort()
	for key: Variant in keys:
		var fields: PackedStringArray = DictRead.as_string(key).split(".")
		var bucket: Array = buckets[key]
		_surface(vertices, bucket, fields[0].to_int(),
			fields[1].to_int() - 1, textures, mesh, body)
	return mesh


## The texture id of one face: its own, or the id its **name** has in this
## world set.  An unknown name paints flat rather than painting the wrong
## texture -- the converter already warns about one, and a silently mismatched
## texture is the harder bug to see.
static func _texture_of(face: Dictionary, textures: Dictionary) -> int:
	if face.has(TEXTURE_NAME):
		var by_name: Dictionary = DictRead.as_dict(
			textures.get(BY_NAME, {}))
		var wanted: String = DictRead.as_string(face[TEXTURE_NAME])
		if wanted == "" or not by_name.has(wanted):
			return NO_TEXTURE
		return DictRead.as_int(by_name[wanted])
	return DictRead.as_int(face["texture"])


## Vertex slot -> the part that owns it, or [constant ROOT_SCOPE].
static func _ownership(count: int, parts: Array) -> PackedInt32Array:
	var owner: PackedInt32Array = PackedInt32Array()
	owner.resize(count)
	owner.fill(ROOT_SCOPE)
	for index: int in range(parts.size()):
		for entry: Variant in DictRead.as_array(
				DictRead.as_dict(parts[index])["vertices"]):
			var slot: int = DictRead.as_int(entry)
			if slot >= 0 and slot < count:
				owner[slot] = index
	return owner


static func _faces_in(faces: Array, owner: PackedInt32Array,
		scope: int) -> Array:
	var out: Array = []
	for entry: Variant in faces:
		var face: Dictionary = DictRead.as_dict(entry)
		var indices: Array = DictRead.as_array(face["indices"])
		if indices.is_empty():
			continue
		var first: int = DictRead.as_int(indices[0])
		if first < 0 or first >= owner.size():
			continue
		if owner[first] == scope:
			out.append(entry)
	return out


## The same vertex array with a part's translation taken back off, so the part
## is authored about its own joint.
static func _localised(vertices: Array, translation: Array) -> Array:
	if translation.size() < 3:
		return vertices
	var dx: int = DictRead.as_int(translation[0])
	var dy: int = DictRead.as_int(translation[1])
	var dz: int = DictRead.as_int(translation[2])
	var out: Array = []
	for entry: Variant in vertices:
		var v: Array = DictRead.as_array(entry)
		if v.size() < 3:
			out.append(entry)
			continue
		out.append([DictRead.as_int(v[0]) - dx, DictRead.as_int(v[1]) - dy,
			DictRead.as_int(v[2]) - dz])
	return out


static func _surface(vertices: Array, faces: Array, kind: int, texture: int,
		textures: Dictionary, into: ArrayMesh, body: bool = false) -> void:
	var tool: SurfaceTool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	# **Flat normals.** The engine shades nothing, so the normals are read only
	# by the sun's shadow (docs/92 section 7.29), and there smoothed ones were
	# wrong twice: a wall's front bent towards its top, so the top of the front
	# counted as turned to the sun, and the map's normal offset pushed along
	# the bent normal, which hatched sun-facing walls with acne (`_C_166`).
	tool.set_smooth_group(FLAT_SMOOTH_GROUP)
	# Each vertex carries its face's rectangle on the page, which the
	# mipmapped read stays inside (`scene.gdshaderinc`).
	tool.set_custom_format(FACE_RECT_CHANNEL, SurfaceTool.CUSTOM_RGBA_FLOAT)
	var emitted: int = 0
	var curve: PackedByteArray = DictRead.as_byte_array(
		textures.get(CURVE, PackedByteArray()))
	for entry: Variant in faces:
		var face: Dictionary = DictRead.as_dict(entry)
		var indices: Array = DictRead.as_array(face["indices"])
		if indices.size() < 3:
			continue
		var uvs: Array = DictRead.as_array(face["uvs"])
		var rgb: Array = DictRead.as_array(face["rgb"])
		# A textured face's own colour is not shading: white leaves the sampled
		# texel alone, which is what the engine's decal kinds do.
		var colour: Color = Color.WHITE
		if FLAT_KINDS.has(kind):
			colour = Color8(DictRead.as_int(rgb[0]),
				DictRead.as_int(rgb[1]), DictRead.as_int(rgb[2]))
		if kind == KIND_FLAT_BLEND:
			colour.a = BLEND_ALPHA
		if FLAT_KINDS.has(kind) and not curve.is_empty():
			colour = PaletteCurve.colour(colour, curve)
		# The lit variants read no alpha from COLOR, so it carries the sun
		# switch there; the blended ones keep theirs.
		if body and LIT_VARIANTS.has(_variant(kind)):
			colour.a = SUN_ALL_FACES
		var points: PackedVector3Array = _points_of(vertices, indices)
		if points.size() != indices.size():
			continue
		var overdraw: int = DictRead.as_int(face.get(OVERDRAW, 0))
		if overdraw > 0:
			points = receded(points, overdraw)
		var corners: PackedVector2Array = PackedVector2Array()
		for pair_entry: Variant in uvs:
			var pair: Array = DictRead.as_array(pair_entry)
			corners.append(WorldSpace.uv(DictRead.as_int(pair[0]),
				DictRead.as_int(pair[1])))
		var rect: Color = face_rect(corners)
		for corner: int in triangulate(points):
			tool.set_color(colour)
			tool.set_custom(FACE_RECT_CHANNEL, rect)
			if corner < corners.size():
				tool.set_uv(corners[corner])
			tool.add_vertex(points[corner])
			emitted += 1
	if emitted == 0:
		return
	tool.generate_normals()
	tool.set_material(material_for(kind, texture, textures))
	var _mesh: ArrayMesh = tool.commit(into)


## The face's world-space corners, in the order the index array names them.
## Returns fewer points than indices when an index is out of range, which the
## caller treats as "skip this face" rather than drawing a hole.
static func _points_of(vertices: Array, indices: Array) -> PackedVector3Array:
	var points: PackedVector3Array = PackedVector3Array()
	for entry: Variant in indices:
		var slot: int = DictRead.as_int(entry)
		if slot < 0 or slot >= vertices.size():
			return PackedVector3Array()
		var position: Array = DictRead.as_array(vertices[slot])
		points.append(WorldSpace.to_godot(
			DictRead.as_int(position[0]),
			DictRead.as_int(position[1]),
			DictRead.as_int(position[2])))
	return points


## The same polygon moved `layers` overdraw steps away from the side it is
## seen from.  The stored winding's Newell normal points **away** from the
## visible side (see [method material_for]), so the move is along it.  A face
## with no area has no normal and stays where it is.
static func receded(points: PackedVector3Array, layers: int) -> PackedVector3Array:
	var normal: Vector3 = newell(points)
	if normal.is_zero_approx():
		return points
	var offset: Vector3 = normal.normalized() * (OVERDRAW_STEP * float(layers))
	var out: PackedVector3Array = PackedVector3Array()
	for point: Vector3 in points:
		out.append(point + offset)
	return out


## Corner indices, three per triangle, covering the polygon.
##
## The polygon is flattened by dropping the largest component of its Newell
## normal -- the one projection that cannot collapse it to a line -- and given
## to [method Geometry2D.triangulate_polygon], which ear-clips and therefore
## handles a reflex corner.  A fan is the fallback for the cases it refuses
## (a self-intersecting outline, or one whose normal is zero), where no
## triangulation is right and the fan is at least the old behaviour.
##
## Every triangle comes back wound as the polygon is ([method oriented]),
## because the material culls the back face.
static func triangulate(points: PackedVector3Array) -> PackedInt32Array:
	if points.size() == 3:
		return PackedInt32Array([0, 1, 2])
	var normal: Vector3 = newell(points)
	if not normal.is_zero_approx():
		var flat: PackedVector2Array = project(points, normal)
		var ears: PackedInt32Array = Geometry2D.triangulate_polygon(flat)
		if not ears.is_empty():
			return oriented(ears, points, normal)
	return fan(points.size())


## The same triangles, each wound the way the polygon is.
##
## [method Geometry2D.triangulate_polygon] normalises the orientation of what
## it returns rather than following its input, and [method project] mirrors
## the outline for half of the possible normals -- so an ear can come back
## wound against the face. That was invisible while every material was
## double-sided; with the back face culled it is a hole. A triangle whose
## cross product runs against the Newell normal has two corners swapped.
static func oriented(triangles: PackedInt32Array, points: PackedVector3Array,
		normal: Vector3) -> PackedInt32Array:
	var out: PackedInt32Array = triangles.duplicate()
	for t: int in range(0, out.size() - 2, 3):
		var a: Vector3 = points[out[t]]
		var b: Vector3 = points[out[t + 1]]
		var c: Vector3 = points[out[t + 2]]
		if (b - a).cross(c - a).dot(normal) < 0.0:
			var swap: int = out[t + 1]
			out[t + 1] = out[t + 2]
			out[t + 2] = swap
	return out


## Newell's normal: correct for a polygon that is only approximately planar,
## which most of this corpus is.
static func newell(points: PackedVector3Array) -> Vector3:
	var normal: Vector3 = Vector3.ZERO
	for i: int in range(points.size()):
		var a: Vector3 = points[i]
		var b: Vector3 = points[(i + 1) % points.size()]
		normal += Vector3(
			(a.y - b.y) * (a.z + b.z),
			(a.z - b.z) * (a.x + b.x),
			(a.x - b.x) * (a.y + b.y))
	return normal


## Drops the axis the normal points along most strongly.
static func project(points: PackedVector3Array,
		normal: Vector3) -> PackedVector2Array:
	var axis: int = 0
	var best: float = absf(normal.x)
	if absf(normal.y) > best:
		axis = 1
		best = absf(normal.y)
	if absf(normal.z) > best:
		axis = 2
	var flat: PackedVector2Array = PackedVector2Array()
	for point: Vector3 in points:
		if axis == 0:
			flat.append(Vector2(point.y, point.z))
		elif axis == 1:
			flat.append(Vector2(point.x, point.z))
		else:
			flat.append(Vector2(point.x, point.y))
	return flat


static func fan(count: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in range(1, count - 1):
		out.append_array(PackedInt32Array([0, i, i + 1]))
	return out


## docs/31 section 4.4, transcribed into the remake's own material: one of the
## `game/shaders/scene_*.gdshader` variants, whose `render_mode` line carries
## what Godot fixes at compile time -- blending, culling, depth writing -- and
## whose uniforms carry the page and how it is read ([method set_sampling]).
##
## **Unshaded**: the original bakes its light into the pages and the face
## colours, so no Godot light is read.
##
## **One-sided, the way the engine draws them.** docs/31 section 4.2: every
## face names a plane, and the leaf walker (`Eng3d.dll` `0x405203`..
## `0x405230`) draws it only when `plane_value - plane_d < 0`. `plane_value`
## is the plane normal dotted with the object's position **minus the
## camera's** (`0x404BF4` subtracts the camera, `0x4050C4` hands the rotated
## vector to the prototype) and `plane_d` is `-n.v/16384` on the corpus, so
## the test is `n . (vertex - camera) < 0`: the face is drawn when the camera
## is on the side its normal points to. The stored winding's Newell normal is
## **against** the plane normal on 236 160 of 236 861 shipped faces (700 have
## no area, one is a near-degenerate sliver), which under Godot's clockwise
## front face puts the visible side in front -- so the indices are used as
## they come and the back face is culled. `prototyp_parse.py --check` pins
## every number in this paragraph.
##
## **Only the flat kinds read the face colour.** docs/31 section 4.4 lists the
## textured kinds' shading as "none (decal)": the engine samples the texture
## and never looks at `colour`, which is `0x0000` on most textured faces and a
## real grey on the rest. Multiplying it in darkened every textured surface --
## 0.48x in `World_A00`, 0.29x in `World_D00` -- or blacked it out where the
## field is zero.
##
## The deferred kinds are drawn after everything opaque and without writing
## depth (`grDepthMask(0)` in the Glide build): the 50 % flat fill is `dst/2 +
## colour/2` exactly, an alpha of one half riding on the vertex colour; the
## colour key is `if (texel == 0) skip pixel`, a scissor and not a blend; the
## additive and subtractive kinds saturate per channel, and a black texel is
## self-neutral under either, so they need no key.
##
## One deliberate deviation: Godot depth-sorts transparent surfaces. The
## original software path first made a camera-dependent BSP walk and then
## flushed one global deferred queue backwards; its Glide path grouped the
## whole frame by material class. The cache has flattened the BSPs, so simply
## reversing each mesh would reproduce neither renderer and would also lose
## ordering between objects. Exact overlap parity needs per-frame global
## ordering (or a custom renderer), not a fixed import-time face order.
static func material_for(kind: int, texture: int,
		textures: Dictionary) -> ShaderMaterial:
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = load(SHADER_DIR + _variant(kind) + SHADER_SUFFIX)
	material.set_shader_parameter(&"sampling", DictRead.as_int(
		textures.get(SAMPLING, GraphicsMode.SAMPLING_NEAREST)))
	var image: Texture2D = null
	if texture != NO_TEXTURE and not FLAT_KINDS.has(kind):
		image = keyed_texture(textures, texture) \
			if kind == KIND_TEXTURE_MASKED else plain_texture(textures, texture)
	if image != null:
		material.set_shader_parameter(&"page", image)
		material.set_meta(SMOOTHABLE_META, true)
	return material


## Which `scene_*.gdshader` draws `kind`.
static func _variant(kind: int) -> String:
	match kind:
		KIND_FLAT_BLEND:
			return VARIANT_FLAT_BLEND
		KIND_TEXTURE_MASKED:
			return VARIANT_MASKED
		KIND_TEXTURE_ADD:
			return VARIANT_ADD
		KIND_TEXTURE_SUB:
			return VARIANT_SUB
	return VARIANT_FLAT if FLAT_KINDS.has(kind) else VARIANT_OPAQUE


## A face's `(u0, v0, u1, v1)` on its page, as the colour channels of CUSTOM0;
## a face with no coordinates gets the whole page.
static func face_rect(corners: PackedVector2Array) -> Color:
	if corners.is_empty():
		return Color(0.0, 0.0, 1.0, 1.0)
	var low: Vector2 = corners[0]
	var high: Vector2 = corners[0]
	for at: Vector2 in corners:
		low = low.min(at)
		high = high.max(at)
	return Color(low.x, low.y, high.x, high.y)


## The variant name of a material [method material_for] made -- `"opaque"`,
## `"masked"`, ... -- or empty for any other.
static func variant_of(material: Material) -> String:
	var shader_material: ShaderMaterial = material as ShaderMaterial
	if shader_material == null or shader_material.shader == null:
		return ""
	var path: String = shader_material.shader.resource_path
	if not path.begins_with(SHADER_DIR):
		return ""
	return path.trim_prefix(SHADER_DIR).trim_suffix(SHADER_SUFFIX)


## `material` drawn from both sides -- what [BlobModels] asks for the A_BLUT
## splats. Only the colour-keyed kind has a two-sided variant, because it is
## the only kind those models use (27 faces, all `0x14`). Returns whether the
## material was switched.
static func double_sided(material: Material) -> bool:
	var shader_material: ShaderMaterial = material as ShaderMaterial
	if variant_of(shader_material) != VARIANT_MASKED:
		return false
	shader_material.shader = load(SHADER_DIR + VARIANT_MASKED_DOUBLE
		+ SHADER_SUFFIX)
	return true


## Switch every bank-textured material under `root` to `sampling` --
## [constant GraphicsMode.SAMPLING_NEAREST] and the rest, docs/92 section 7.29.
##
## **Nearest** is what both shipped renderers do by default, wrapping mod 256.
## **Linear** is bilinear with the coordinates clamped and no mipmaps, the
## texture state `ENG3DFX.DLL` hands Glide (docs/31 section 4.8) -- the
## remake's own option, not the accelerated build's picture, which has never
## been observed. **Mipmapped** is anisotropic and held inside each face's own
## rectangle of the atlas (`scene.gdshaderinc`).
##
## The materials are built once per scene, so a change made on the options
## screen has to reach the ones already on screen; the banks' own [constant
## SAMPLING] decides the ones built afterwards. Only materials [method
## material_for] gave a texture are touched -- the overlay, the markers and
## the effect sprites keep their own sampling. Returns how many changed.
static func set_sampling(root: Node, sampling: int) -> int:
	var changed: int = 0
	if root == null:
		return changed
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		pending.append_array(node.get_children())
		var instance: MeshInstance3D = node as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		for surface: int in range(instance.mesh.get_surface_count()):
			var material: ShaderMaterial = \
				instance.mesh.surface_get_material(surface) as ShaderMaterial
			if material == null or not material.has_meta(SMOOTHABLE_META):
				continue
			material.set_shader_parameter(&"sampling", sampling)
			changed += 1
	return changed


## Loads every PNG the cache's texture index names, keyed by its id; the
## colour-keyed copy draw kind `0x14` reads is made on first use ([method
## keyed_texture]).
##
## *preset* is a [GraphicsMode] preset: it decides the bank's [constant
## SAMPLING], which [method material_for] reads, and whether the exact 24-bit
## pages are drawn as they are or quantised to the engine's RGB565 ([method
## channel_tables]).
static func load_textures(cache_dir: String, world_set: String,
		index: Dictionary, preset: int = GraphicsMode.DEFAULT) -> Dictionary:
	var plain: Dictionary = {}
	var sources: Dictionary = {}
	var by_name: Dictionary = {}
	# The renderer's curve is applied here, once per bank, so every consumer
	# of the bank -- scenery, bodies, the effect atlas, the cutscenes -- draws
	# the palette byte the texel holds (docs/92 section 7.25).
	var curve: PackedByteArray = PaletteCurve.table() \
		if PaletteCurve.is_active() else PackedByteArray()
	var exact: bool = DictRead.as_string(index.get("precision", "")) \
		== PRECISION_EXACT
	var quantise: bool = exact and not GraphicsMode.exact_colour(preset)
	var tables: Array[PackedByteArray] = channel_tables(curve, quantise)
	var entries: Array = DictRead.as_array(index.get("textures", []))
	for entry: Variant in entries:
		var record: Dictionary = DictRead.as_dict(entry)
		var path: String = "%s/textures/%s/%s" % [cache_dir, world_set,
			DictRead.as_string(record["file"])]
		# `Image.load` warns that it will not work on export whenever the path
		# is under `res://`, which the development fixtures are.  Reading the
		# bytes and decoding them works the same way for `res://` and for the
		# `user://` cache production actually uses.
		var raw: Image = _read_png(path)
		if raw == null:
			continue
		var id: int = DictRead.as_int(record["id"])
		plain[id] = ImageTexture.create_from_image(_drawn(raw, tables))
		sources[id] = path
		by_name[DictRead.as_string(record["name"])] = id
	return {PLAIN: plain, KEYED: {}, SOURCES: sources, BY_NAME: by_name,
		CURVE: curve, SAMPLING: GraphicsMode.sampling(preset), EXACT: exact,
		QUANTISED: quantise}


## Move a loaded bank to `preset`: its [constant SAMPLING] for what is built
## next, and -- when the colour depth changes -- every page it has made,
## rewritten in place so the materials already holding them follow. Returns
## how many pages were rewritten.
static func set_graphics(textures: Dictionary, preset: int) -> int:
	textures[SAMPLING] = GraphicsMode.sampling(preset)
	var quantise: bool = DictRead.as_bool(textures.get(EXACT, false)) \
		and not GraphicsMode.exact_colour(preset)
	if quantise == DictRead.as_bool(textures.get(QUANTISED, false)):
		return 0
	textures[QUANTISED] = quantise
	var curve: PackedByteArray = textures.get(CURVE, PackedByteArray())
	var tables: Array[PackedByteArray] = channel_tables(curve, quantise)
	var sources: Dictionary = DictRead.as_dict(textures.get(SOURCES, {}))
	var rewritten: int = 0
	for kind: String in [PLAIN, KEYED]:
		var made: Dictionary = DictRead.as_dict(textures.get(kind, {}))
		for id: Variant in made.keys():
			var page: ImageTexture = made[id]
			var raw: Image = _read_png(DictRead.as_string(sources.get(id, "")))
			if page == null or raw == null:
				continue
			page.update(colour_key(raw, tables) if kind == KEYED
				else _drawn(raw, tables))
			rewritten += 1
	return rewritten


## The bank's page `id` as the cache holds it -- the exact 24-bit decode --
## read from its PNG rather than back from the renderer; null when the bank has
## no such page.
static func source_image(textures: Dictionary, id: int) -> Image:
	var sources: Dictionary = DictRead.as_dict(textures.get(SOURCES, {}))
	return _read_png(DictRead.as_string(sources.get(id, "")))


## The bank's texture `id`, or null.
static func plain_texture(textures: Dictionary, id: int) -> Texture2D:
	var bank: Dictionary = DictRead.as_dict(textures.get(PLAIN, {}))
	var found: Texture2D = bank.get(id, null)
	return found


## The colour-keyed copy of the bank's texture `id`, made on first use and
## kept in the bank, or null.
##
## **Lazily, because [method colour_key] is the expensive half of a bank** and
## only the draw kind `0x14` reads it -- 2 673 faces of 236 861, one to eight
## pages per world set. Building it for every page cost a quarter of a second
## per world set before the hole fill, and four times that after it.
static func keyed_texture(textures: Dictionary, id: int) -> Texture2D:
	if not textures.has(KEYED):
		textures[KEYED] = {}
	var bank: Dictionary = textures[KEYED]
	if bank.has(id):
		var kept: Texture2D = bank[id]
		return kept
	var sources: Dictionary = DictRead.as_dict(textures.get(SOURCES, {}))
	if not sources.has(id):
		return null
	var raw: Image = _read_png(DictRead.as_string(sources[id]))
	if raw == null:
		return null
	var curve: PackedByteArray = textures.get(CURVE, PackedByteArray())
	var made: ImageTexture = ImageTexture.create_from_image(colour_key(raw,
		channel_tables(curve, DictRead.as_bool(textures.get(QUANTISED, false)))))
	bank[id] = made
	return made


## One byte table per channel, red, green and blue, from the PNG's byte to the
## byte to draw.
##
## *quantise* puts each channel through the engine's own field scaling first,
## `(v * 31) // 255` or `(v * 63) // 255`, and expands it back by bit
## replication -- which reproduces the RGB565 picture **bit for bit** from the
## exact 24-bit one (`visn_decode.py --check` pins the derivation on all 723
## records, docs/50 section 9.1). Then [PaletteCurve]'s table, when the
## renderer needs one. Both are folded into one lookup, so the original look
## costs no pass the exact one does not.
static func channel_tables(curve: PackedByteArray,
		quantise: bool) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	for bits: int in [5, 6, 5]:
		var table: PackedByteArray = PackedByteArray()
		table.resize(PaletteCurve.LEVELS)
		var top: int = (1 << bits) - 1
		for v: int in range(PaletteCurve.LEVELS):
			var drawn: int = v
			if quantise:
				var field: int = (v * top) / 255
				drawn = ((field << (8 - bits)) & 0xFF) | (field >> (2 * bits - 8))
			table[v] = curve[drawn] if not curve.is_empty() else drawn
		out.append(table)
	return out


## Whether every table is the identity, so a page can be drawn as read.
static func _identity(tables: Array[PackedByteArray]) -> bool:
	for table: PackedByteArray in tables:
		for v: int in range(table.size()):
			if table[v] != v:
				return false
	return true


## The page as the renderer draws it: through `tables`, with its mip chain.
##
## **The chain is always built**, whatever the sampling: it costs a third more
## texture memory and lets [method set_graphics] rewrite a page in place --
## `ImageTexture.update` refuses an image whose mipmap flag differs.
static func _drawn(raw: Image, tables: Array[PackedByteArray]) -> Image:
	var out: Image = raw if _identity(tables) \
		else PaletteCurve.remap_channels(raw, tables)
	var _chain: Error = out.generate_mipmaps()
	return out


static func _read_png(path: String) -> Image:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var image: Image = Image.new()
	if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	if image.get_format() != Image.FORMAT_RGB8:
		image.convert(Image.FORMAT_RGB8)
	return image


## `raw` -- the cache's exact 24-bit page -- with alpha 0 where the engine's
## RGB565 texel is `0x0000`, drawn through `tables`, with its mip chain.
##
## **The key is decided on the quantised value, whatever is drawn.** The
## engine skips a texel whose RGB565 is zero, and a 24-bit texel quantises to
## zero when red and blue are at most 8 and green at most 4 (`(v * 31) // 255`
## and `(v * 63) // 255`). Testing the exact bytes for black would make those
## near-black texels solid in the 24-bit picture and holes in the original.
##
## **A hole keeps the mean drawn colour of its opaque 8-neighbours**, at alpha
## 0. Sampled texel by texel the colour of a hole is never seen -- the scissor
## discards it -- but a filtered sample at a hole's edge mixes it in, and
## black there drew a dark fringe round every grille.
static func colour_key(raw: Image, tables: Array[PackedByteArray] = []) -> Image:
	var source: Image = raw
	if source.get_format() != Image.FORMAT_RGB8:
		source = raw.duplicate()
		source.convert(Image.FORMAT_RGB8)
	if tables.is_empty():
		tables = channel_tables(PackedByteArray(), false)
	var red_of: PackedByteArray = tables[0]
	var green_of: PackedByteArray = tables[1]
	var blue_of: PackedByteArray = tables[2]
	var width: int = source.get_width()
	var height: int = source.get_height()
	var rgb: PackedByteArray = source.get_data()
	# One pass for the key, so a hole's neighbours are tested by index rather
	# than by reading pixels back.
	var hole: PackedByteArray = PackedByteArray()
	hole.resize(width * height)
	for at: int in range(width * height):
		var byte: int = at * 3
		hole[at] = 1 if rgb[byte] <= KEY_LIMIT_5 \
			and rgb[byte + 1] <= KEY_LIMIT_6 \
			and rgb[byte + 2] <= KEY_LIMIT_5 else 0
	var rgba: PackedByteArray = PackedByteArray()
	rgba.resize(width * height * 4)
	for y: int in range(height):
		for x: int in range(width):
			var at: int = y * width + x
			var to: int = at * 4
			if hole[at] == 0:
				var from: int = at * 3
				rgba[to] = red_of[rgb[from]]
				rgba[to + 1] = green_of[rgb[from + 1]]
				rgba[to + 2] = blue_of[rgb[from + 2]]
				rgba[to + 3] = 255
				continue
			var red: int = 0
			var green: int = 0
			var blue: int = 0
			var count: int = 0
			for ny: int in range(maxi(y - 1, 0), mini(y + 2, height)):
				for nx: int in range(maxi(x - 1, 0), mini(x + 2, width)):
					var near: int = ny * width + nx
					if hole[near] != 0:
						continue
					red += red_of[rgb[near * 3]]
					green += green_of[rgb[near * 3 + 1]]
					blue += blue_of[rgb[near * 3 + 2]]
					count += 1
			if count > 0:
				rgba[to] = roundi(float(red) / float(count))
				rgba[to + 1] = roundi(float(green) / float(count))
				rgba[to + 2] = roundi(float(blue) / float(count))
			# The alpha stays 0 and a hole with no opaque neighbour stays
			# black: `resize` zero-fills.
	var out: Image = Image.create_from_data(width, height, false,
		Image.FORMAT_RGBA8, rgba)
	var _chain: Error = out.generate_mipmaps()
	return out
