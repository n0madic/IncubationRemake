class_name BlobSprites
extends MeshInstance3D

## The cheap half of the effect system: 54 of the 116 constructor calls.
##
## docs/28 section 7.3. A class-2 or class-3 blob has no geometry at all.
## `aDrawZoomBlobs` sends it to `E3D_draw_zoom_bob_alpha_plus` as a
## camera-facing quad, and every parameter of its appearance is two bytes and a
## size: **which flip-book, which frame, how big**. The atlas is one 256×256
## texture named `anim`, an 8 × 8 grid of 32 × 32 sprites, present and
## byte-identical in all nine world sets.
##
## Each row of the atlas is one flip-book -- a fire puff, an expanding ring, a
## red burst, a green cloud, a grey smoke puff, a white spark star, a green
## glow, a red spiky burst -- and **the update arm advances the column**. That
## is why the arms write `+0x26` far more often than `+0x24`, and it is the
## whole animation system for half the effects in the game.
##
## There are no colour parameters anywhere in the blob system and there never
## were: the palette is baked into `anim`.
##
## **One [ImmediateMesh], rebuilt each frame, rather than 450 nodes.** The UVs
## differ per blob, so a shared mesh cannot be instanced without a shader, and
## 450 nodes created and freed as particles come and go would cost more than
## 1 800 vertices written into one surface. `scenery.gd` made the opposite call
## for the same reason -- 84 static instances that never change.

## The grid, from `tables/blobs.json` rather than from a constant here; these
## are the fallbacks for a document that does not carry them.
const TILE: int = 32
const GRID: int = 8
const ATLAS_SIZE: int = 256
## `quad half-extent = size * 160` world units, and 1600 units is a metre, so a
## `size` of 10 is a one-metre half-extent -- the ten shipped values run 3 to
## 40, which is 0.3 m to 4 m.
const HALF_EXTENT_SCALE: float = 160.0

var _tile: int = TILE
var _grid: int = GRID
var _atlas_size: int = ATLAS_SIZE
var _half_extent_scale: float = HALF_EXTENT_SCALE
var _immediate: ImmediateMesh = null
var _material: StandardMaterial3D = null
var _drawn: int = 0


## `atlas` is the `anim` texture of the mission's world set; `document` is
## `tables/blobs.json`, which carries the grid the binary was read for.
func setup(atlas: Texture2D, document: Dictionary = {}) -> void:
	var geometry: Dictionary = DictRead.as_dict(document.get("atlas", {}))
	if not geometry.is_empty():
		_tile = DictRead.as_int(geometry["tile"])
		_grid = DictRead.as_int(geometry["grid"])
		_atlas_size = DictRead.as_int(geometry["size"])
		_half_extent_scale = float(
			DictRead.as_int(geometry["half_extent_scale"]))
	_immediate = ImmediateMesh.new()
	mesh = _immediate
	_material = _make_material(atlas)
	material_override = _material
	# The quads are written in world space, so the node must not add a
	# transform of its own on top of them.
	transform = Transform3D.IDENTITY
	# A particle cloud is never the reason to cull: the mesh is rebuilt every
	# frame and its bounds change with it, so a stale AABB would pop.
	custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))


## **Additive, and recorded as a reading rather than as a measurement.**
##
## `Eng3d` exports three zoom-bob entry points -- `alpha_plus`, `alpha_minus`
## and `masked`, ordinals 63, 64 and 65 -- and `a3DEngine.cpp` resolves all
## three at start-up. Only `alpha_plus` is ever called; the other two import
## slots are written by the resolver and read by nothing. So the entry point's
## **name** is the only evidence there is for what it does, and "plus" is read
## as a saturating add.
##
## Two consequences follow and are worth stating. A black texel is
## self-neutral under addition, so the atlas needs no colour key and no alpha
## channel -- the plain RGB PNG the converter writes is already complete. And
## depth writing is off: an additive sprite that wrote depth would punch a hole
## in everything drawn after it, which is the same rule `mesh_builder.gd`
## applies to the engine's own deferred draw kinds.
func _make_material(atlas: Texture2D) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.vertex_color_use_as_albedo = false
	material.albedo_texture = atlas
	return material


## Nearest texel, or filtered under any other [GraphicsMode] sampling --
## docs/92 section 7.29. The atlas needs no clamp and no mipmaps for it:
## [method _uv_of] runs every quad from the centre of its tile's first texel
## to the centre of its last, so a filtered read never reaches the next tile.
func set_sampling(sampling: int) -> void:
	if _material != null:
		_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST \
			if sampling == GraphicsMode.SAMPLING_NEAREST \
			else BaseMaterial3D.TEXTURE_FILTER_LINEAR


func drawn() -> int:
	return _drawn


## Rebuild the whole cloud from the pool's live records.
##
## `basis` is the camera's, and the quad is built from its right and up
## vectors: that is what "camera-facing" means, and doing it here rather than
## with a billboard flag keeps the quad's own extent in world units where the
## `size * 160` rule can be applied literally.
func rebuild(blobs: Array[Blob], basis: Basis) -> int:
	_drawn = 0
	if _immediate == null:
		return 0
	_immediate.clear_surfaces()
	var right: Vector3 = basis.x
	var up: Vector3 = basis.y
	var sprites: Array[Blob] = []
	for blob: Blob in blobs:
		if blob.is_sprite() and blob.delay == 0:
			sprites.append(blob)
	if sprites.is_empty():
		return 0
	_immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for blob: Blob in sprites:
		_quad(blob, right, up)
		_drawn += 1
	_immediate.surface_end()
	return _drawn


func _quad(blob: Blob, right: Vector3, up: Vector3) -> void:
	var centre: Vector3 = WorldSpace.to_godot(blob.x, blob.y, blob.z)
	var half: float = float(blob.aux) * _half_extent_scale \
		/ WorldSpace.WORLD_UNITS_PER_METRE
	var dx: Vector3 = right * half
	var dy: Vector3 = up * half
	var uv: Rect2 = _uv_of(blob.rot_x, blob.rot_y)

	var a: Vector3 = centre - dx + dy
	var b: Vector3 = centre + dx + dy
	var c: Vector3 = centre + dx - dy
	var d: Vector3 = centre - dx - dy
	_vertex(a, Vector2(uv.position.x, uv.position.y))
	_vertex(b, Vector2(uv.end.x, uv.position.y))
	_vertex(c, Vector2(uv.end.x, uv.end.y))
	_vertex(a, Vector2(uv.position.x, uv.position.y))
	_vertex(c, Vector2(uv.end.x, uv.end.y))
	_vertex(d, Vector2(uv.position.x, uv.end.y))


func _vertex(at: Vector3, uv: Vector2) -> void:
	_immediate.surface_set_uv(uv)
	_immediate.surface_add_vertex(at)


## The tile `(row, column)` occupies, as normalised UVs.
##
## The original computes `u0 = col * 32; u1 = u0 + 31` -- **31, not 32**, so
## the span is the two end texels *inclusive*. Rendered, that means the quad
## runs from the centre of texel 0 to the centre of texel 31, which is where
## the half-texel inset below comes from. Using `u0 .. u0 + 32` instead would
## sample a sliver of the neighbouring sprite along every edge, and with 64
## sprites packed edge to edge that shows.
##
## Row and column are taken modulo the grid: an arm advances the column every
## tick with no bound of its own, and a flip-book that ran off the right of the
## atlas would otherwise wrap into the next row's first frame.
func _uv_of(row: int, column: int) -> Rect2:
	var r: int = posmod(row, _grid)
	var c: int = posmod(column, _grid)
	var size: float = float(_atlas_size)
	var u0: float = (float(c * _tile) + 0.5) / size
	var u1: float = (float(c * _tile + _tile - 1) + 0.5) / size
	var v0: float = (float(r * _tile) + 0.5) / size
	var v1: float = (float(r * _tile + _tile - 1) + 0.5) / size
	return Rect2(Vector2(u0, v0), Vector2(u1 - u0, v1 - v0))
