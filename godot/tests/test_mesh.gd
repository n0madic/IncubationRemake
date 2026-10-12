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
	_check_sampling(h)
	_check_corpus_kinds(h)
	_check_overdraw(h)
	_check_palette_curve(h)


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
	h.check("side.back_face_culled", _render_mode(MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_PERSP, 0, textures)).has("cull_back"),
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
	# docs/92 section 7.29: each kind is a `scene_*.gdshader` variant, and
	# what Godot fixes at compile time is on its `render_mode` line.
	var opaque: ShaderMaterial = MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_PERSP, 0, textures)
	h.equal("kind.10.variant", MeshBuilder.variant_of(opaque),
		MeshBuilder.VARIANT_OPAQUE, "the dominant kind is opaque")
	h.check("kind.10.depth", _render_mode(opaque).has("depth_draw_opaque")
		and not _defines(opaque).has("TRANSLUCENT"))
	var unlit: Array[String] = []
	for variant: String in [MeshBuilder.VARIANT_OPAQUE,
			MeshBuilder.VARIANT_MASKED, MeshBuilder.VARIANT_MASKED_DOUBLE,
			MeshBuilder.VARIANT_ADD, MeshBuilder.VARIANT_SUB,
			MeshBuilder.VARIANT_FLAT, MeshBuilder.VARIANT_FLAT_BLEND]:
		var shader: Shader = load(MeshBuilder.SHADER_DIR + variant
			+ MeshBuilder.SHADER_SUFFIX)
		if shader != null and _mode_of(shader.code).has("unshaded"):
			unlit.append(variant)
	h.equal("kind.all.unshaded", unlit.size(), 7,
		"the original bakes its light in, so any Godot light is infidelity")
	# docs/31 section 4.4 lists the textured kinds' shading as "none (decal)":
	# the face colour is not read for them.  Multiplying it in darkened every
	# textured surface -- `World_A00` carries (123,125,123) on its textured
	# faces, which is 0.48x -- and blacked out the ones whose colour is 0.
	h.check("kind.textured.ignores_face_colour",
		_defines(opaque).has("TEXTURED"), "TEXTURED paints the page alone")
	var flat: ShaderMaterial = MeshBuilder.material_for(
		MeshBuilder.KIND_FLAT, MeshBuilder.NO_TEXTURE, textures)
	h.check("kind.flat.uses_face_colour",
		MeshBuilder.variant_of(flat) == MeshBuilder.VARIANT_FLAT
		and not _defines(flat).has("TEXTURED"),
		"the flat kinds are the only ones that paint it")

	var blend: ShaderMaterial = MeshBuilder.material_for(
		MeshBuilder.KIND_FLAT_BLEND, -1, textures)
	h.check("kind.0c.blend", _render_mode(blend).has("blend_mix")
		and _defines(blend).has("TRANSLUCENT"),
		"dst/2 + colour/2 is alpha one half")
	h.check("kind.0c.depth", _render_mode(blend).has("depth_draw_never"),
		"deferred, and grDepthMask(0)")

	var masked: ShaderMaterial = MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_MASKED, 0, textures)
	h.check("kind.14.scissor", _defines(masked).has("MASKED")
		and not _defines(masked).has("TRANSLUCENT"),
		"a colour key is a scissor, not a blend")

	h.check("kind.1c.blend", _render_mode(MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_ADD, 0, textures)).has("blend_add"))
	h.check("kind.20.blend", _render_mode(MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_SUB, 0, textures)).has("blend_sub"))
	h.check("kind.14.two_sided_on_request",
		MeshBuilder.double_sided(masked)
		and _render_mode(masked).has("cull_disabled")
		and not MeshBuilder.double_sided(opaque),
		"only the colour-keyed kind has the splats' two-sided variant")

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
	image.set_pixel(1, 0, Color8(0, 0, 9))
	var keyed: Image = MeshBuilder.colour_key(image)
	h.equal("key.black_is_a_hole", keyed.get_pixel(0, 0).a, 0.0)
	h.equal("key.near_black_is_opaque", keyed.get_pixel(1, 0).a, 1.0,
		"the key is RGB565 0x0000 exactly, not a darkness threshold")
	# The cache holds the exact 24-bit page, and the engine keys on the
	# quantised texel: (8, 4, 8) is RGB565 0x0000, so it is a hole in either
	# colour depth -- solid in one and a hole in the other was the bug.
	var quantised_zero: Image = Image.create_empty(2, 1, false,
		Image.FORMAT_RGB8)
	quantised_zero.set_pixel(0, 0, Color8(8, 4, 8))
	quantised_zero.set_pixel(1, 0, Color8(8, 5, 8))
	var keyed_zero: Image = MeshBuilder.colour_key(quantised_zero)
	h.equal("key.decided_on_the_quantised_texel",
		[keyed_zero.get_pixel(0, 0).a8, keyed_zero.get_pixel(1, 0).a8], [0, 255],
		"(4 * 63) // 255 is 0 and (5 * 63) // 255 is 1")
	# A hole takes the mean of its opaque neighbours, so a smoothed sample at
	# its edge does not pull black in; a hole with none stays black.
	var grille: Image = Image.create_empty(3, 1, false, Image.FORMAT_RGB8)
	grille.set_pixel(0, 0, Color8(200, 100, 0))
	grille.set_pixel(1, 0, Color8(0, 0, 0))
	grille.set_pixel(2, 0, Color8(100, 0, 200))
	var filled: Color = MeshBuilder.colour_key(grille).get_pixel(1, 0)
	h.equal("key.hole_takes_its_neighbours_colour",
		[filled.r8, filled.g8, filled.b8, filled.a8], [150, 50, 100, 0],
		"still a hole, coloured like its edge")
	var lone: Image = Image.create_empty(1, 1, false, Image.FORMAT_RGB8)
	lone.set_pixel(0, 0, Color8(0, 0, 0))
	h.equal("key.lone_hole_stays_black",
		MeshBuilder.colour_key(lone).get_pixel(0, 0), Color(0.0, 0.0, 0.0, 0.0))

	# The keyed copy is made from the page's PNG the first time a masked face
	# asks, and kept: the bank does not build one per page up front.
	var path: String = "user://test_mesh_keyed.png"
	h.equal("key.lazy.fixture_written", grille.save_png(path), OK)
	var bank: Dictionary = {MeshBuilder.PLAIN: {}, MeshBuilder.KEYED: {},
		MeshBuilder.SOURCES: {7: path}}
	var first: Texture2D = MeshBuilder.keyed_texture(bank, 7)
	var hole: Color = first.get_image().get_pixel(1, 0) if first != null \
		else Color(1.0, 1.0, 1.0, 1.0)
	h.equal("key.lazy.built_from_the_source", [hole.a8, hole.r8], [0, 150])
	h.check("key.lazy.kept_in_the_bank",
		first != null and MeshBuilder.keyed_texture(bank, 7) == first)
	h.check("key.lazy.unknown_page_is_null",
		MeshBuilder.keyed_texture(bank, 8) == null)
	var _gone: Error = DirAccess.remove_absolute(
		ProjectSettings.globalize_path(path))


## docs/92 sections 7.28 and 7.29: texel by texel unless the bank's preset says
## otherwise, and the switch reaches a material already in a tree without
## touching any other.
func _check_sampling(h: TestHarness) -> void:
	var page: ImageTexture = ImageTexture.create_from_image(
		Image.create_empty(2, 2, false, Image.FORMAT_RGB8))
	var sharp_bank: Dictionary = {MeshBuilder.PLAIN: {0: page},
		MeshBuilder.KEYED: {0: page}}
	var sharp: ShaderMaterial = MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_PERSP, 0, sharp_bank)
	h.equal("sampling.nearest_by_default",
		[sharp.get_shader_parameter(&"sampling"),
		sharp.get_shader_parameter(&"page") == page],
		[GraphicsMode.SAMPLING_NEAREST, true],
		"the software renderer's nearest texel")
	var smooth_bank: Dictionary = sharp_bank.duplicate()
	smooth_bank[MeshBuilder.SAMPLING] = GraphicsMode.SAMPLING_LINEAR
	var smooth: ShaderMaterial = MeshBuilder.material_for(
		MeshBuilder.KIND_TEXTURE_MASKED, 0, smooth_bank)
	h.equal("sampling.bank_decides_new_materials",
		smooth.get_shader_parameter(&"sampling"), GraphicsMode.SAMPLING_LINEAR)
	# **One sampler.** The Compatibility renderer keeps the filter on the
	# texture object, so a page bound to two differently filtered uniforms is
	# filtered in both; the texel-by-texel read is `texelFetch` instead.
	var include: String = FileAccess.get_file_as_string(
		"res://game/shaders/scene.gdshaderinc")
	h.check("sampling.one_sampler_state",
		include.contains("uniform sampler2D page : hint_default_white, "
			+ "filter_linear_mipmap_anisotropic, repeat_disable;")
		and include.count("\nuniform sampler2D") == 1
		and include.contains("texelFetch(page"))

	var root: Node3D = Node3D.new()
	var built: MeshInstance3D = MeshInstance3D.new()
	var mesh: ArrayMesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO,
		Vector3.RIGHT, Vector3.UP])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, sharp)
	var foreign: ShaderMaterial = MeshBuilder.material_for(
		MeshBuilder.KIND_FLAT, MeshBuilder.NO_TEXTURE, sharp_bank)
	mesh.surface_set_material(1, foreign)
	built.mesh = mesh
	root.add_child(built)
	h.equal("sampling.switch_reaches_only_bank_materials",
		[MeshBuilder.set_sampling(root, GraphicsMode.SAMPLING_MIPMAPPED),
		sharp.get_shader_parameter(&"sampling"),
		foreign.get_shader_parameter(&"sampling")],
		[1, GraphicsMode.SAMPLING_MIPMAPPED, GraphicsMode.SAMPLING_NEAREST],
		"an untextured face has nothing to sample")
	var _back: int = MeshBuilder.set_sampling(root,
		GraphicsMode.SAMPLING_NEAREST)
	h.equal("sampling.switch_back", sharp.get_shader_parameter(&"sampling"),
		GraphicsMode.SAMPLING_NEAREST)
	root.free()

	# Each face carries its own rectangle of the atlas, which the mipmapped
	# read stays inside.
	h.equal("rect.of_a_face", MeshBuilder.face_rect(PackedVector2Array([
		Vector2(0.25, 0.5), Vector2(0.75, 0.125), Vector2(0.5, 0.625)])),
		Color(0.25, 0.125, 0.75, 0.625))
	h.equal("rect.of_no_coordinates", MeshBuilder.face_rect(
		PackedVector2Array()), Color(0.0, 0.0, 1.0, 1.0))
	var quad: Dictionary = {
		"vertices": [[0, 0, 0], [1600, 0, 0], [1600, 1600, 0], [0, 1600, 0]],
		"faces": [{"draw_kind": MeshBuilder.KIND_TEXTURE_PERSP, "texture": 0,
			"rgb": [0, 0, 0], "indices": [0, 1, 2, 3],
			"uvs": [[0, 0], [4096, 0], [4096, 8192], [0, 8192]]}],
	}
	var quad_mesh: ArrayMesh = MeshBuilder.build(quad, sharp_bank)
	var custom: PackedFloat32Array = PackedFloat32Array()
	if quad_mesh.get_surface_count() > 0:
		custom = quad_mesh.surface_get_arrays(0)[Mesh.ARRAY_CUSTOM0]
	h.equal("rect.reaches_the_vertices",
		Array(custom.slice(0, 4)) if custom.size() >= 4 else [],
		[0.0, 0.0, 0.125, 0.25], "u up to 4096 of 32768, v up to 8192")

	# The presets, as the named questions every consumer asks.
	h.equal("graphics.presets",
		[GraphicsMode.sampling(GraphicsMode.ORIGINAL),
		GraphicsMode.exact_colour(GraphicsMode.ORIGINAL),
		GraphicsMode.sampling(GraphicsMode.SMOOTH),
		GraphicsMode.exact_colour(GraphicsMode.SMOOTH),
		GraphicsMode.effect_lights(GraphicsMode.SMOOTH),
		GraphicsMode.sampling(GraphicsMode.ENHANCED),
		GraphicsMode.effect_lights(GraphicsMode.ENHANCED)],
		[GraphicsMode.SAMPLING_NEAREST, false, GraphicsMode.SAMPLING_LINEAR,
		true, false, GraphicsMode.SAMPLING_MIPMAPPED, true])
	_check_colour_depth(h)


## The `render_mode` line of a scene material's variant.
func _render_mode(material: ShaderMaterial) -> PackedStringArray:
	return _mode_of(material.shader.code) if material != null \
		and material.shader != null else PackedStringArray()


func _mode_of(code: String) -> PackedStringArray:
	for line: String in code.split("\n"):
		if line.begins_with("render_mode "):
			var out: PackedStringArray = PackedStringArray()
			for word: String in line.trim_prefix("render_mode ") \
					.trim_suffix(";").split(","):
				out.append(word.strip_edges())
			return out
	return PackedStringArray()


## The `#define`s in front of a variant's include.
func _defines(material: ShaderMaterial) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if material == null or material.shader == null:
		return out
	for line: String in material.shader.code.split("\n"):
		if line.begins_with("#define "):
			out.append(line.trim_prefix("#define ").strip_edges())
	return out


## docs/92 section 7.29: the cache's page is the exact 24-bit decode, and the
## original's RGB565 picture is one table away.
func _check_colour_depth(h: TestHarness) -> void:
	var quantised: Array[PackedByteArray] = MeshBuilder.channel_tables(
		PackedByteArray(), true)
	# Red/blue: (128 * 31) // 255 = 15, replicated (15 << 3) | (15 >> 2) = 123;
	# green: (128 * 63) // 255 = 31, (31 << 2) | (31 >> 4) = 125. The ends stay.
	h.equal("depth.quantised_tables",
		[quantised[0][128], quantised[1][128], quantised[2][128],
		quantised[0][0], quantised[1][255], quantised[0][8], quantised[0][9]],
		[123, 125, 123, 0, 255, 0, 8],
		"the engine's field scaling, then bit replication as the old cache had")
	var exact: Array[PackedByteArray] = MeshBuilder.channel_tables(
		PackedByteArray(), false)
	h.equal("depth.exact_is_identity", [exact[0][37], exact[1][200]], [37, 200])

	# A bank switched between the two rewrites its pages in place, so a
	# material that already holds one follows.
	var path: String = "user://test_mesh_depth.png"
	var page: Image = Image.create_empty(2, 1, false, Image.FORMAT_RGB8)
	page.set_pixel(0, 0, Color8(128, 128, 128))
	page.set_pixel(1, 0, Color8(3, 2, 3))
	h.equal("depth.fixture_written", page.save_png(path), OK)
	var index: Dictionary = {"precision": MeshBuilder.PRECISION_EXACT,
		"textures": [{"id": 0, "name": "probe", "file": "depth.png"}]}
	var dir: String = "user://test_mesh_depth_cache"
	var _made: Error = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(dir + "/textures/T00"))
	var _copied: Error = DirAccess.copy_absolute(
		ProjectSettings.globalize_path(path),
		ProjectSettings.globalize_path(dir + "/textures/T00/depth.png"))
	var bank: Dictionary = MeshBuilder.load_textures(dir, "T00", index,
		GraphicsMode.ORIGINAL)
	var held: Texture2D = MeshBuilder.plain_texture(bank, 0)
	var before: int = held.get_image().get_pixel(0, 0).r8 if held != null else -1
	var rewritten: int = MeshBuilder.set_graphics(bank, GraphicsMode.SMOOTH)
	var after: int = held.get_image().get_pixel(0, 0).r8 if held != null else -1
	var curve: PackedByteArray = DictRead.as_dict(bank).get(MeshBuilder.CURVE,
		PackedByteArray())
	var expect_exact: int = curve[128] if not curve.is_empty() else 128
	var expect_quantised: int = curve[123] if not curve.is_empty() else 123
	h.equal("depth.bank_switches_in_place",
		[before, rewritten, MeshBuilder.plain_texture(bank, 0) == held],
		[expect_quantised, 1, true],
		"the same texture object, rewritten from the exact page")
	# The headless run's renderer keeps a texture's first image whatever
	# `update` hands it, so the rewritten pixels are only observable where a
	# real one draws -- the windowed and exported runs.
	if DisplayServer.get_name() != "headless":
		h.equal("depth.bank_rewrites_the_pixels", after, expect_exact)
	h.equal("depth.same_preset_rewrites_nothing",
		MeshBuilder.set_graphics(bank, GraphicsMode.ENHANCED), 0,
		"smooth and enhanced share the colour depth")
	for gone: String in [path, dir + "/textures/T00/depth.png"]:
		var _removed: Error = DirAccess.remove_absolute(
			ProjectSettings.globalize_path(gone))


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


## What Godot 4.7.2's Compatibility renderer drew for an unshaded texel of
## 0..63 on 2026-09-22 (identity from 62 up), measured through the windowed
## probe docs/92 section 7.25 names.  The model in [PaletteCurve] has to
## reproduce it to within a level, and its table has to undo it.
const GL_OUTPUT_HEAD: PackedInt32Array = [
	0, 0, 0, 0, 0, 0, 0, 0, 1, 3, 4, 5, 6, 8, 9, 10,
	11, 12, 14, 15, 16, 17, 18, 19, 21, 22, 23, 24, 25, 26, 27, 29,
	30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 42, 43, 44, 45, 46,
	47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 62, 63,
]
const GL_OUTPUT_IDENTITY_FROM: int = 62
## The RGB565 expansions the converter writes for red and blue.
const RGB565_FIVE_BIT: PackedInt32Array = [0, 8, 16, 24, 33, 41, 49, 57, 66,
	74, 82, 90, 99, 107, 115, 123, 132, 140, 148, 156, 165, 173, 181, 189, 198,
	206, 214, 222, 231, 239, 247, 255]


func _measured(v: int) -> int:
	return GL_OUTPUT_HEAD[v] if v < GL_OUTPUT_HEAD.size() else v


func _check_palette_curve(h: TestHarness) -> void:
	var worst_model: int = 0
	for v: int in range(256):
		var drawn: int = roundi(PaletteCurve.forward(float(v) / 255.0) * 255.0)
		worst_model = maxi(worst_model, absi(drawn - _measured(v)))
	h.check("curve.model_matches_measured_within_one", worst_model <= 1,
		"worst |model - measured| = %d" % worst_model)
	var identity_from: int = 0
	for v: int in range(GL_OUTPUT_HEAD.size()):
		if GL_OUTPUT_HEAD[v] != v:
			identity_from = v + 1
	h.equal("curve.measured_identity_from", identity_from, GL_OUTPUT_IDENTITY_FROM)
	var curve: PackedByteArray = PaletteCurve.table()
	h.equal("curve.table_size", curve.size(), 256)
	h.equal("curve.black_stays_black", curve[0], 0,
		"the colour key reads exactly zero")
	h.equal("curve.white_stays_white", curve[255], 255)
	var worst_round_trip: int = 0
	var exact: int = 0
	var monotonic: bool = true
	for v: int in range(256):
		var err: int = absi(_measured(curve[v]) - v)
		worst_round_trip = maxi(worst_round_trip, err)
		if err == 0:
			exact += 1
		if v > 0 and curve[v] < curve[v - 1]:
			monotonic = false
	h.equal("curve.round_trip_worst", worst_round_trip, 1,
		"one level, below the original's RGB565 quantisation")
	# 234 on the measuring host; the last few sit on near-ties of `pow`, which
	# another libm may round the other way.
	h.check("curve.round_trip_mostly_exact", exact >= 230,
		"%d of 256 exact" % exact)
	h.check("curve.monotonic", monotonic)
	var off: int = 0
	for v: int in RGB565_FIVE_BIT:
		if _measured(curve[v]) != v:
			off += 1
	h.check("curve.rgb565_red_blue_nearly_all_exact", off <= 3,
		"%d of %d expansions one level off (41 and 57 on the measuring host)"
		% [off, RGB565_FIVE_BIT.size()])
	h.check("curve.dark_texel_lifted", curve[11] >= 15 and curve[11] <= 16,
		"11 drew as 5 and 16 drew as 11; the model's boundary may pick 15 (got %d)"
		% curve[11])
	var image: Image = Image.create_empty(2, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color8(0, 0, 0, 0))
	image.set_pixel(1, 0, Color8(11, 21, 200, 255))
	var remapped: Image = PaletteCurve.remap(image, curve)
	h.equal("curve.remap_keeps_hole", remapped.get_pixel(0, 0).a8, 0)
	h.equal("curve.remap_keeps_black", remapped.get_pixel(0, 0).r8, 0)
	h.equal("curve.remap_channels", str([remapped.get_pixel(1, 0).r8,
		remapped.get_pixel(1, 0).g8, remapped.get_pixel(1, 0).b8,
		remapped.get_pixel(1, 0).a8]),
		str([curve[11], curve[21], curve[200], 255]))
	var rgb: Image = Image.create_empty(1, 1, false, Image.FORMAT_RGB8)
	rgb.set_pixel(0, 0, Color8(16, 16, 16))
	h.equal("curve.remap_rgb8_format",
		PaletteCurve.remap(rgb, curve).get_format(), Image.FORMAT_RGB8,
		"a three-byte image stays three bytes")
	h.equal("curve.colour", PaletteCurve.colour(Color8(11, 0, 255, 128), curve),
		Color8(curve[11], 0, 255, 128))
	h.equal("curve.active_follows_the_rendering_method", PaletteCurve.is_active(),
		RenderingServer.get_current_rendering_method() == "gl_compatibility")
