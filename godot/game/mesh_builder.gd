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

## `textures` is `{"plain": {id: Texture2D}, "keyed": {id: Texture2D}}`.  The
## keyed copies carry alpha 0 wherever the texel is exactly black, which is
## what draw kind `0x14` treats as a hole.
const PLAIN: String = "plain"
const KEYED: String = "keyed"


static func build(prototype: Dictionary,
		textures: Dictionary) -> ArrayMesh:
	var vertices: Array = DictRead.as_array(prototype["vertices"])
	var faces: Array = DictRead.as_array(prototype["faces"])
	var buckets: Dictionary = {}
	for entry: Variant in faces:
		var face: Dictionary = DictRead.as_dict(entry)
		var kind: int = DictRead.as_int(face.get("draw_kind", KIND_TEXTURE))
		if DRAWS_NOTHING.has(kind):
			continue
		var texture: int = NO_TEXTURE if FLAT_KINDS.has(kind) \
			else DictRead.as_int(face["texture"])
		var key: String = "%03d.%04d" % [kind, texture + 1]
		if not buckets.has(key):
			buckets[key] = []
		var bucket: Array = buckets[key]
		bucket.append(face)

	var mesh: ArrayMesh = ArrayMesh.new()
	var keys: Array = buckets.keys()
	keys.sort()
	for key: Variant in keys:
		var parts: PackedStringArray = DictRead.as_string(key).split(".")
		var bucket: Array = buckets[key]
		_surface(vertices, bucket, parts[0].to_int(),
			parts[1].to_int() - 1, textures, mesh)
	return mesh


static func _surface(vertices: Array, faces: Array, kind: int, texture: int,
		textures: Dictionary, into: ArrayMesh) -> void:
	var tool: SurfaceTool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var emitted: int = 0
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
		var points: PackedVector3Array = _points_of(vertices, indices)
		if points.size() != indices.size():
			continue
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


## Corner indices, three per triangle, covering the polygon.
##
## The polygon is flattened by dropping the largest component of its Newell
## normal -- the one projection that cannot collapse it to a line -- and given
## to [method Geometry2D.triangulate_polygon], which ear-clips and therefore
## handles a reflex corner.  A fan is the fallback for the cases it refuses
## (a self-intersecting outline, or one whose normal is zero), where no
## triangulation is right and the fan is at least the old behaviour.
static func triangulate(points: PackedVector3Array) -> PackedInt32Array:
	if points.size() == 3:
		return PackedInt32Array([0, 1, 2])
	var normal: Vector3 = newell(points)
	if not normal.is_zero_approx():
		var flat: PackedVector2Array = project(points, normal)
		var ears: PackedInt32Array = Geometry2D.triangulate_polygon(flat)
		if not ears.is_empty():
			return ears
	return fan(points.size())


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
## One deliberate deviation: the original flushes its deferred polygons in
## **reverse submission order** and Godot sorts transparent surfaces by depth.
## Reproducing the submission order would mean reproducing the BSP walk that
## produced it, which the cache deliberately flattened away, and depth sorting
## is right more often than a fixed order is.  Recorded, not tuned by eye.
static func material_for(kind: int, texture: int,
		textures: Dictionary) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# **Only the flat kinds read the face colour.**  docs/31 section 4.4 lists
	# the textured kinds' shading as "none (decal)": the engine samples the
	# texture and never looks at `colour`, which is `0x0000` on most textured
	# faces and a real grey on the rest.  Letting Godot multiply it in darkens
	# every textured surface -- 0.48x in `World_A00`, 0.29x in `World_D00` --
	# or blacks it out entirely where the field is zero.
	material.vertex_color_use_as_albedo = texture == NO_TEXTURE

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
		plain[id] = ImageTexture.create_from_image(image)
		keyed[id] = ImageTexture.create_from_image(colour_key(image))
	return {PLAIN: plain, KEYED: keyed}


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
