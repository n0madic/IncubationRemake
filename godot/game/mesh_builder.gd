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
## The colour key of the masked kind is RGB565 `0x0000`, which is pure black
## after the 5-6-5 expansion the converter does.
const KEY_CUTOFF: float = 0.5

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
## what draw kind `0x14` treats as a hole.
const PLAIN: String = "plain"
const KEYED: String = "keyed"
## `{name: id}` for the world set in use, added by [method load_textures] so a
## face can name its texture instead of numbering it.
const BY_NAME: String = "by_name"
## [PaletteCurve]'s table for the running renderer, or an empty array where
## the renderer draws a byte as it is.  The bank's textures already carry it;
## a flat face's colour goes through it in [method _surface].
const CURVE: String = "curve"

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


static func build(prototype: Dictionary,
		textures: Dictionary) -> ArrayMesh:
	return build_scope(prototype, textures, ROOT_SCOPE)


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
		scope: int) -> ArrayMesh:
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
			fields[1].to_int() - 1, textures, mesh)
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
		textures: Dictionary, into: ArrayMesh) -> void:
	var tool: SurfaceTool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
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
		var points: PackedVector3Array = _points_of(vertices, indices)
		if points.size() != indices.size():
			continue
		var overdraw: int = DictRead.as_int(face.get(OVERDRAW, 0))
		if overdraw > 0:
			points = receded(points, overdraw)
		for corner: int in triangulate(points):
			tool.set_color(colour)
			if corner < uvs.size():
				var pair: Array = DictRead.as_array(uvs[corner])
				tool.set_uv(WorldSpace.uv(DictRead.as_int(pair[0]),
					DictRead.as_int(pair[1])))
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


## docs/31 section 4.4, transcribed into Godot's material.
##
## One deliberate deviation: Godot depth-sorts transparent surfaces. The
## original software path first made a camera-dependent BSP walk and then
## flushed one global deferred queue backwards; its Glide path grouped the
## whole frame by material class. The cache has flattened the BSPs, so simply
## reversing each mesh would reproduce neither renderer and would also lose
## ordering between objects. Exact overlap parity needs per-frame global
## ordering (or a custom renderer), not a fixed import-time face order.
static func material_for(kind: int, texture: int,
		textures: Dictionary) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# **One-sided, the way the engine draws them.** docs/31 section 4.2: every
	# face names a plane, and the leaf walker (`Eng3d.dll` `0x405203`..
	# `0x405230`) draws it only when `plane_value - plane_d < 0`. `plane_value`
	# is the plane normal dotted with the object's position **minus the
	# camera's** (`0x404BF4` subtracts the camera, `0x4050C4` hands the rotated
	# vector to the prototype) and `plane_d` is `-n.v/16384` on the corpus, so
	# the test is `n . (vertex - camera) < 0`: the face is drawn when the camera
	# is on the side its normal points to. The stored winding's Newell normal is
	# **against** the plane normal on 236 160 of 236 861 shipped faces (700 have
	# no area, one is a near-degenerate sliver), which under Godot's clockwise
	# front face puts the visible side in front -- so the indices are used as
	# they come and the back face is culled. `prototyp_parse.py --check` pins
	# every number in this paragraph.
	material.cull_mode = BaseMaterial3D.CULL_BACK
	# **Only the flat kinds read the face colour.**  docs/31 section 4.4 lists
	# the textured kinds' shading as "none (decal)": the engine samples the
	# texture and never looks at `colour`, which is `0x0000` on most textured
	# faces and a real grey on the rest.  Letting Godot multiply it in darkens
	# every textured surface -- 0.48x in `World_A00`, 0.29x in `World_D00` --
	# or blacks it out entirely where the field is zero.
	material.vertex_color_use_as_albedo = texture == NO_TEXTURE
	# The palette entry is an sRGB value.  Forward+ and Mobile read a vertex
	# colour as linear unless told otherwise; the flag is inert under
	# gl_compatibility, which the project renders with, and is set so the
	# face colour means the same thing under any renderer (docs/92 section
	# 7.25 -- the terrain overlay, which takes the same path, washed out
	# under Mobile before it was set).
	material.vertex_color_is_srgb = true

	var keyed: bool = kind == KIND_TEXTURE_MASKED
	var bank: Dictionary = DictRead.as_dict(
		textures.get(KEYED if keyed else PLAIN, {}))
	if texture != NO_TEXTURE and bank.has(texture):
		var image: Texture2D = bank[texture]
		material.albedo_texture = image

	match kind:
		KIND_FLAT_BLEND:
			# 50 % translucent flat fill: `dst/2 + colour/2` exactly, which is
			# an alpha of one half over MIX.  The alpha itself rides on the
			# vertex colour, set in `_surface`.
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
		KIND_TEXTURE_MASKED:
			# Colour-keyed: `if (texel == 0) skip pixel`.  A scissor, not a
			# blend -- the kept pixels are fully opaque.
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			material.alpha_scissor_threshold = KEY_CUTOFF
		KIND_TEXTURE_ADD:
			# Saturating per-channel add.  A black texel is self-neutral under
			# addition, so the key needs no alpha channel here.
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		KIND_TEXTURE_SUB:
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.blend_mode = BaseMaterial3D.BLEND_MODE_SUB
		_:
			material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	if DEFERRED_KINDS.has(kind):
		# The engine draws these after everything opaque and with the depth
		# buffer write disabled (`grDepthMask(0)` in the Glide build).
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return material


## Loads every PNG the cache's texture index names, keyed by its id, plus a
## colour-keyed copy of each for draw kind `0x14`.
##
## The keyed copies are built for every texture rather than only for the ids a
## masked face actually names: the whole set is ten images on the slice's lead
## mission, and deciding needs the geometry, which this does not have.
static func load_textures(cache_dir: String, world_set: String,
		index: Dictionary) -> Dictionary:
	var plain: Dictionary = {}
	var keyed: Dictionary = {}
	var by_name: Dictionary = {}
	# The renderer's curve is applied here, once per bank, so every consumer
	# of the bank -- scenery, bodies, the effect atlas, the cutscenes -- draws
	# the palette byte the texel holds (docs/92 section 7.25).
	var curve: PackedByteArray = PaletteCurve.table() \
		if PaletteCurve.is_active() else PackedByteArray()
	var entries: Array = DictRead.as_array(index.get("textures", []))
	for entry: Variant in entries:
		var record: Dictionary = DictRead.as_dict(entry)
		var path: String = "%s/textures/%s/%s" % [cache_dir, world_set,
			DictRead.as_string(record["file"])]
		# `Image.load` warns that it will not work on export whenever the path
		# is under `res://`, which the development fixtures are.  Reading the
		# bytes and decoding them works the same way for `res://` and for the
		# `user://` cache production actually uses.
		if not FileAccess.file_exists(path):
			continue
		var image: Image = Image.new()
		var loaded: Error = image.load_png_from_buffer(
			FileAccess.get_file_as_bytes(path))
		if loaded != OK:
			continue
		var id: int = DictRead.as_int(record["id"])
		if not curve.is_empty():
			# Before the key: the table maps black to black, so the hole a
			# masked face reads is the same texel it was.
			image = PaletteCurve.remap(image, curve)
		plain[id] = ImageTexture.create_from_image(image)
		keyed[id] = ImageTexture.create_from_image(colour_key(image))
		by_name[DictRead.as_string(record["name"])] = id
	return {PLAIN: plain, KEYED: keyed, BY_NAME: by_name, CURVE: curve}


## A copy of `image` with alpha 0 wherever the texel is exactly black.
##
## RGB565 `0x0000` is the engine's key and expands to `(0, 0, 0)`, so the test
## is exact rather than a threshold: a dark-but-not-black texel is opaque in
## the original and stays opaque here.
static func colour_key(image: Image) -> Image:
	var out: Image = Image.create_empty(image.get_width(), image.get_height(),
		false, Image.FORMAT_RGBA8)
	for y: int in range(image.get_height()):
		for x: int in range(image.get_width()):
			var pixel: Color = image.get_pixel(x, y)
			if pixel.r8 == 0 and pixel.g8 == 0 and pixel.b8 == 0:
				out.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
			else:
				pixel.a = 1.0
				out.set_pixel(x, y, pixel)
	return out
