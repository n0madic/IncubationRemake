extends TestSuite

## Oracle boundary: specification-only, against docs/31 section 4.4 and against
## the geometry the converter emitted.
##
## Two things the slice left open and this closes.
##
## **Triangulation.**  A triangle fan is only correct for a convex polygon, and
## `tools/prototyp_parse.py --check` counts 1572 reflex faces in the corpus, 81
## of them in `World_A00`.  The checks below build one deliberately reflex quad
## and require that the triangulation covers its area exactly -- a fan of the
## same quad covers a different region of the plane, which is why the naive
## version was silent rather than obviously wrong.
##
## **Coplanar overdraw.**  Two coplanar faces of one prototype z-fight in a
## depth buffer; the original shows one of them (`tools/inclib/overdraw.py`
## says which, from the tree and from what the retail game was seen to draw).
## The checks below require that a face the converter marks with `overdraw`
## is built one step behind its winner, along the direction the face is *not*
## seen from, and pin the marks the cached `World_A00` carries.
##
## **`draw_kind`.**  The eleven rasteriser kinds are recovered in docs/31 but
## the slice drew everything opaque.  The checks state the "consequences for a
## remake" table as properties of the material each kind produces, and pin
## which kinds the cached world sets actually contain, so a kind appearing for
## the first time is noticed rather than silently drawn as something else.

## A five-sided outline with one reflex corner, in Godot metres and in the XZ
## plane: (0,0) (4,0) (4,4) (2,1) (0,4).  The fourth vertex points **inwards**
## from the top edge, and it is not adjacent to vertex 0 -- which is what makes
## a fan from vertex 0 emit a triangle outside the outline.
const REFLEX: Array = [
	Vector3(0.0, 0.0, 0.0), Vector3(4.0, 0.0, 0.0), Vector3(4.0, 0.0, 4.0),
	Vector3(2.0, 0.0, 1.0), Vector3(0.0, 0.0, 4.0),
]

## Its area by the shoelace formula.  A fan of the same outline covers 14.
const REFLEX_AREA: float = 10.0
const AREA_EPSILON: float = 0.0001


func run(h: TestHarness) -> void:
	h.begin("mesh", TestHarness.ORACLE_SPEC)
	_check_triangulation(h)
	_check_winding(h)
	_check_draw_kinds(h)
	_check_colour_key(h)
	_check_corpus_kinds(h)
	_check_overdraw(h)


func _check_triangulation(h: TestHarness) -> void:
	var square: PackedVector3Array = PackedVector3Array([
		Vector3(0.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 2.0), Vector3(0.0, 0.0, 2.0)])
	h.equal("fan.triangle", str(MeshBuilder.triangulate(
		PackedVector3Array(REFLEX.slice(0, 3)))), str(PackedInt32Array([0, 1, 2])),
		"a triangle needs no work")
	var convex: PackedInt32Array = MeshBuilder.triangulate(square)
	h.equal("convex.corner_count", convex.size(), 6, "two triangles")
	h.check("convex.area",
		absf(_area(square, convex) - 4.0) < AREA_EPSILON,
		"a convex quad is covered exactly")

	var reflex: PackedVector3Array = PackedVector3Array(REFLEX)
	var ears: PackedInt32Array = MeshBuilder.triangulate(reflex)
	h.equal("reflex.corner_count", ears.size(), 9, "three triangles")
	h.check("reflex.is_reflex", not _is_convex(reflex),
		"the fixture really does have a reflex corner")
	h.check("reflex.area",
		absf(_area(reflex, ears) - REFLEX_AREA) < AREA_EPSILON,
		"the reflex corner is respected: area %f, want %f"
			% [_area(reflex, ears), REFLEX_AREA])
	# The check that makes the one above mean something: the old behaviour
	# fails it, so this is a test of the triangulation and not of the area sum.
	var fanned: PackedInt32Array = MeshBuilder.fan(reflex.size())
	h.check("reflex.fan_is_wrong",
		absf(_area(reflex, fanned) - REFLEX_AREA) > AREA_EPSILON,
		"a fan of the same polygon covers %f, not %f"
			% [_area(reflex, fanned), REFLEX_AREA])

	# A degenerate outline has no triangulation; the fan is the fallback and
	# must still produce a well-formed index array rather than nothing.
	var collinear: PackedVector3Array = PackedVector3Array([
		Vector3.ZERO, Vector3(1.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 0.0)])
	h.equal("degenerate.falls_back",
		MeshBuilder.triangulate(collinear).size(), 6,
		"a zero-area outline still yields a fan rather than nothing")
	h.check("newell.zero_on_degenerate",
		MeshBuilder.newell(collinear).is_zero_approx())


## docs/31 section 4.2: a face is drawn from one side, the one its plane
## normal points to, and the stored winding puts that side in front under
## Godot's convention -- so the material culls the back face and every
## triangle the builder emits has to be wound as its polygon is.
## `Geometry2D.triangulate_polygon` normalises its output's orientation, and
## dropping an axis mirrors the outline for half the normals, so without
## [method MeshBuilder.oriented] an ear-clipped face can vanish. The reflex
## outline is laid in all three planes, facing both ways, wound both ways.
func _check_winding(h: TestHarness) -> void:
	var textures: Dictionary = {MeshBuilder.PLAIN: {}, MeshBuilder.KEYED: {}}
	h.equal("side.back_face_culled", MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_PERSP, 0, textures).cull_mode,
		BaseMaterial3D.CULL_BACK,
		"Eng3d.dll 0x405203..0x405230 draws a face from one side only")
	var flips: int = 0
	for axis: int in range(3):
		for way: int in [1, -1]:
			for backwards: bool in [false, true]:
				var poly: PackedVector3Array = _outline_in(axis, way, backwards)
				var normal: Vector3 = MeshBuilder.newell(poly)
				var ears: PackedInt32Array = MeshBuilder.triangulate(poly)
				var label: String = "%d%s%s" % [axis, "+" if way > 0 else "-",
					"r" if backwards else "f"]
				h.check("side.ears_follow_the_face." + label,
					ears.size() == 9 and _all_with(poly, ears, normal),
					"%d corners; a triangle runs against the Newell normal"
						% ears.size())
				var raw: PackedInt32Array = Geometry2D.triangulate_polygon(
					MeshBuilder.project(poly, normal))
				if not _all_with(poly, raw, normal):
					flips += 1
	# The check above has to bite: the un-oriented ears really do run against
	# the face for some of the twelve, or the orientation pass tests nothing.
	h.check("side.raw_ears_do_flip", flips > 0,
		"%d of 12 raw triangulations run against the face" % flips)
	# The fan on a **convex** outline: a fan is only a triangulation of one,
	# and on the reflex fixture its third triangle is wound the other way,
	# which is the defect `reflex.fan_is_wrong` already pins.
	var plain: PackedVector3Array = PackedVector3Array([
		Vector3(0.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0),
		Vector3(2.0, 0.0, 2.0), Vector3(0.0, 0.0, 2.0)])
	h.check("side.fan_follows_the_face", _all_with(plain,
		MeshBuilder.fan(plain.size()), MeshBuilder.newell(plain)),
		"the fallback fan keeps a convex polygon's winding")
	var triangle: PackedVector3Array = PackedVector3Array(plain.slice(0, 3))
	h.check("side.triangle_untouched", _all_with(triangle,
		MeshBuilder.triangulate(triangle), MeshBuilder.newell(triangle)))


## The reflex outline in the plane normal to `axis`, mirrored when `way` is
## negative and wound the other way when `backwards`.
static func _outline_in(axis: int, way: int, backwards: bool) -> PackedVector3Array:
	var out: PackedVector3Array = PackedVector3Array()
	for entry: Variant in REFLEX:
		var flat: Vector3 = entry
		var u: float = flat.x
		var v: float = flat.z * float(way)
		if axis == 0:
			out.append(Vector3(0.0, u, v))
		elif axis == 1:
			out.append(Vector3(u, 0.0, v))
		else:
			out.append(Vector3(u, v, 0.0))
	if backwards:
		out.reverse()
	return out


## Whether every triangle's cross product runs with `normal`.
static func _all_with(points: PackedVector3Array, triangles: PackedInt32Array,
		normal: Vector3) -> bool:
	if triangles.size() < 3:
		return false
	for t: int in range(0, triangles.size() - 2, 3):
		var a: Vector3 = points[triangles[t]]
		var b: Vector3 = points[triangles[t + 1]]
		var c: Vector3 = points[triangles[t + 2]]
		if (b - a).cross(c - a).dot(normal) <= 0.0:
			return false
	return true


func _check_draw_kinds(h: TestHarness) -> void:
	var textures: Dictionary = {MeshBuilder.PLAIN: {}, MeshBuilder.KEYED: {}}
	var opaque: StandardMaterial3D = MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_PERSP, 0, textures)
	h.equal("kind.10.transparency", opaque.transparency,
		BaseMaterial3D.TRANSPARENCY_DISABLED, "the dominant kind is opaque")
	h.equal("kind.10.depth", opaque.depth_draw_mode,
		BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY)
	h.equal("kind.all.unshaded", opaque.shading_mode,
		BaseMaterial3D.SHADING_MODE_UNSHADED,
		"the original bakes its light in, so any Godot light is infidelity")
	# docs/31 section 4.4 lists the textured kinds' shading as "none (decal)":
	# the face colour is not read for them.  Multiplying it in darkened every
	# textured surface -- `World_A00` carries (123,125,123) on its textured
	# faces, which is 0.48x -- and blacked out the ones whose colour is 0.
	h.equal("kind.textured.ignores_face_colour",
		opaque.vertex_color_use_as_albedo, false)
	h.equal("kind.flat.uses_face_colour", MeshBuilder.material_for(
		MeshBuilder.KIND_FLAT, MeshBuilder.NO_TEXTURE,
		textures).vertex_color_use_as_albedo, true,
		"the flat kinds are the only ones that paint it")

	var blend: StandardMaterial3D = MeshBuilder.material_for(
		MeshBuilder.KIND_FLAT_BLEND, -1, textures)
	h.equal("kind.0c.blend", blend.blend_mode, BaseMaterial3D.BLEND_MODE_MIX)
	h.equal("kind.0c.transparency", blend.transparency,
		BaseMaterial3D.TRANSPARENCY_ALPHA, "dst/2 + colour/2 is alpha one half")
	h.equal("kind.0c.depth", blend.depth_draw_mode,
		BaseMaterial3D.DEPTH_DRAW_DISABLED, "deferred, and grDepthMask(0)")

	var masked: StandardMaterial3D = MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_MASKED, 0, textures)
	h.equal("kind.14.transparency", masked.transparency,
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR,
		"a colour key is a scissor, not a blend")

	h.equal("kind.1c.blend", MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_ADD, 0, textures).blend_mode,
		BaseMaterial3D.BLEND_MODE_ADD)
	h.equal("kind.20.blend", MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_SUB, 0, textures).blend_mode,
		BaseMaterial3D.BLEND_MODE_SUB)

	# The half-dead kind: its textured branch calls a filler pointer the DLL
	# never sets, so only the flat fallback paints -- which means it must not
	# receive a texture here either.
	h.check("kind.18.is_flat",
		MeshBuilder.FLAT_KINDS.has(MeshBuilder.KIND_TEXTURE_SWITCHED),
		"0x18's textured branch is a bare ret in the shipped DLL")
	h.check("kind.28.draws_nothing",
		MeshBuilder.DRAWS_NOTHING.has(MeshBuilder.KIND_NONE))

	# And a prototype made only of kind 0x28 produces an empty mesh, which is
	# what "bare ret" has to mean once it reaches a mesh builder.
	var nothing: Dictionary = {
		"vertices": [[0, 0, 0], [1600, 0, 0], [0, 1600, 0]],
		"faces": [{"draw_kind": MeshBuilder.KIND_NONE, "texture": -1,
			"rgb": [255, 255, 255], "indices": [0, 1, 2], "uvs": []}],
	}
	h.equal("kind.28.no_surface",
		MeshBuilder.build(nothing, textures).get_surface_count(), 0)


func _check_colour_key(h: TestHarness) -> void:
	var image: Image = Image.create_empty(2, 1, false, Image.FORMAT_RGB8)
	image.set_pixel(0, 0, Color8(0, 0, 0))
	image.set_pixel(1, 0, Color8(0, 0, 8))
	var keyed: Image = MeshBuilder.colour_key(image)
	h.equal("key.black_is_a_hole", keyed.get_pixel(0, 0).a, 0.0)
	h.equal("key.near_black_is_opaque", keyed.get_pixel(1, 0).a, 1.0,
		"the key is RGB565 0x0000 exactly, not a darkness threshold")


## Which kinds the slice's own geometry contains.  Pinned so that a kind
## turning up for the first time is a visible change rather than a surface
## quietly drawn as something else.
func _check_corpus_kinds(h: TestHarness) -> void:
	var found: Dictionary = {}
	var faces: int = 0
	var polygons: Dictionary = {}
	for world_set: String in ["A00", "D00"]:
		var geometry: Dictionary = CacheFixture.geometry(world_set)
		if geometry.is_empty():
			continue
		var prototypes: Dictionary = DictRead.as_dict(geometry["prototypes"])
		for name: Variant in prototypes:
			var proto: Dictionary = DictRead.as_dict(prototypes[name])
			for entry: Variant in DictRead.as_array(proto["faces"]):
				var face: Dictionary = DictRead.as_dict(entry)
				var kind: int = DictRead.as_int(face["draw_kind"])
				found[kind] = DictRead.as_int(found.get(kind, 0)) + 1
				var corners: int = DictRead.as_array(face["indices"]).size()
				polygons[corners] = DictRead.as_int(
					polygons.get(corners, 0)) + 1
				faces += 1
	h.check("corpus.faces", faces > 0, "%d faces in the cached world sets"
		% faces)
	var kinds: Array = found.keys()
	kinds.sort()
	h.equal("corpus.kinds", str(kinds), str([0, 8, 12, 16, 20, 28]),
		"flat, affine texture, half-blended flat (the heal flash's three "
		+ "crosses, carried since 2026-09-03), perspective texture, masked "
		+ "and additive")
	var sizes: Array = polygons.keys()
	sizes.sort()
	h.check("corpus.polygon_sizes", DictRead.as_int(sizes[sizes.size() - 1]) > 4,
		"faces with more than four corners exist here: %s" % str(sizes))


## Whether every turn around the outline has the same sign, in the XZ plane.
func _is_convex(points: PackedVector3Array) -> bool:
	var sign_seen: int = 0
	var n: int = points.size()
	for i: int in range(n):
		var a: Vector3 = points[i]
		var b: Vector3 = points[(i + 1) % n]
		var c: Vector3 = points[(i + 2) % n]
		var cross: float = (b.x - a.x) * (c.z - a.z) \
			- (b.z - a.z) * (c.x - a.x)
		if is_zero_approx(cross):
			continue
		var here: int = 1 if cross > 0.0 else -1
		if sign_seen != 0 and here != sign_seen:
			return false
		sign_seen = here
	return true


## Twice the area of a triangulation, halved -- in the XZ plane, which is where
## the fixtures above lie.
func _area(points: PackedVector3Array, indices: PackedInt32Array) -> float:
	var total: float = 0.0
	var i: int = 0
	while i + 2 < indices.size():
		var a: Vector3 = points[indices[i]]
		var b: Vector3 = points[indices[i + 1]]
		var c: Vector3 = points[indices[i + 2]]
		total += absf((b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x))
		i += 3
	return total * 0.5


## The A00 cache's overdraw marks: `prototyp_parse.py --check`'s corpus line
## gives the whole world set 41 faces over 15 prototypes, none deeper than two
## layers.  A published cache carries the prototypes its missions name, so
## the face count differs between the campaign cache and the development one
## and only the depth is pinned.
const A00_OVERDRAW_DEEPEST: int = 2
## `LEVEL01A.004`: two faces one layer down and one two layers down.
const LEVEL01A_004_OVERDRAW: Array = [1, 1, 2]


func _check_overdraw(h: TestHarness) -> void:
	# A square wall in the engine's XZ plane.  Which side it is seen from is
	# not the point; that the recession runs along its Newell normal -- the
	# direction the material's back-face cull hides -- is.
	var square: Array = [[0, 0, 0], [1600, 0, 0], [1600, 0, 1600], [0, 0, 1600]]
	var points: PackedVector3Array = PackedVector3Array()
	for corner: Variant in square:
		var c: Array = DictRead.as_array(corner)
		points.append(WorldSpace.to_godot(DictRead.as_int(c[0]),
			DictRead.as_int(c[1]), DictRead.as_int(c[2])))
	var normal: Vector3 = MeshBuilder.newell(points)
	var one: PackedVector3Array = MeshBuilder.receded(points, 1)
	var two: PackedVector3Array = MeshBuilder.receded(points, 2)
	h.equal("overdraw.count_kept", one.size(), points.size())
	h.check("overdraw.step_is_sixteen_units",
		is_equal_approx(MeshBuilder.OVERDRAW_STEP, 16.0 / 1600.0),
		"1 cm per layer: over the 24-bit depth resolution at 64 m")
	var moved: Vector3 = one[0] - points[0]
	h.check("overdraw.along_the_newell_normal",
		moved.normalized().is_equal_approx(normal.normalized())
			and is_equal_approx(moved.length(), MeshBuilder.OVERDRAW_STEP),
		"moved %s, Newell %s" % [str(moved), str(normal.normalized())])
	h.check("overdraw.linear_in_layers",
		(two[2] - points[2]).is_equal_approx(moved * 2.0))
	h.equal("overdraw.zero_area_untouched", str(MeshBuilder.receded(
		PackedVector3Array([Vector3.ZERO, Vector3.ONE, Vector3.ONE * 2.0]), 1)),
		str(PackedVector3Array([Vector3.ZERO, Vector3.ONE, Vector3.ONE * 2.0])),
		"a face with no normal has no side to recede from")

	# Through the builder: the same square twice, the second marked, comes
	# out as two quads whose vertices differ by exactly one step.
	var textures: Dictionary = {MeshBuilder.PLAIN: {}, MeshBuilder.KEYED: {}}
	var proto: Dictionary = {
		"vertices": square,
		"faces": [
			{"draw_kind": MeshBuilder.KIND_FLAT, "texture": -1,
				"rgb": [255, 255, 255], "indices": [0, 1, 2, 3], "uvs": []},
			{"draw_kind": MeshBuilder.KIND_FLAT, "texture": -1,
				"rgb": [255, 255, 255], "indices": [0, 1, 2, 3], "uvs": [],
				MeshBuilder.OVERDRAW: 1},
		],
	}
	var mesh: ArrayMesh = MeshBuilder.build(proto, textures)
	h.equal("overdraw.one_surface", mesh.get_surface_count(), 1)
	var arrays: Array = mesh.surface_get_arrays(0)
	var built: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	h.equal("overdraw.corner_count", built.size(), 12, "two quads, six corners each")
	var receded: int = 0
	var in_place: int = 0
	for corner: Vector3 in built:
		var d: float = (corner - points[0]).dot(normal.normalized())
		if is_zero_approx(d):
			in_place += 1
		elif is_equal_approx(d, MeshBuilder.OVERDRAW_STEP):
			receded += 1
	h.equal("overdraw.first_in_place", in_place, 6, "the winner stays put")
	h.equal("overdraw.second_one_step_back", receded, 6)

	# The fixture: the marks the converter wrote for World_A00.
	var geometry: Dictionary = CacheFixture.geometry("A00")
	if geometry.is_empty():
		return
	var prototypes: Dictionary = DictRead.as_dict(geometry["prototypes"])
	var marked: int = 0
	var deepest: int = 0
	var sample: Array = []
	for name: Variant in prototypes:
		var faces: Array = DictRead.as_array(
			DictRead.as_dict(prototypes[name])["faces"])
		for entry: Variant in faces:
			var face: Dictionary = DictRead.as_dict(entry)
			var layers: int = DictRead.as_int(face.get(MeshBuilder.OVERDRAW, 0))
			if layers <= 0:
				continue
			marked += 1
			deepest = maxi(deepest, layers)
			if DictRead.as_string(name) == "LEVEL01A.004":
				sample.append(layers)
	h.check("overdraw.a00.marked_faces", marked > 0,
		"%d faces marked in the cached World_A00" % marked)
	h.equal("overdraw.a00.deepest", deepest, A00_OVERDRAW_DEEPEST)
	sample.sort()
	h.equal("overdraw.a00.level01a_004", str(sample), str(LEVEL01A_004_OVERDRAW))
