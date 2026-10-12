class_name EffectLights
extends MeshInstance3D

## Light from the effects, and the halo round it -- docs/92 section 7.29. The
## remake's own, for the *enhanced* graphics preset; the original lights
## nothing at run time.
##
## **The sources are the sprite cloud's own blobs.** Every sprite the pool
## draws is additive (`alpha_plus`, docs/28 section 7.3), so each is a little
## emitter already: its colour is the mean of its atlas tile's lit texels, its
## size the blob's half-extent. Each frame the brightest [constant LIMIT] of
## them -- that colour's luminance times the share of the tile it covers times
## the half-extent -- go into a 16 x 2 float table the scene
## shader reads as the global `fx_lights` (`scene.gdshaderinc`), and a halo is
## drawn round each.
##
## **Presentation only**, and read from the picture's pool, never from the
## world: nothing here enters a save or the canonical hash. The table is global
## because every material reads it, so whichever instance is drawing -- the
## mission's or the campaign map's -- owns it, and leaving the tree hands back
## a table with no lights.

## The scene shader's loop bound, `FX_LIGHT_LIMIT`.
const LIMIT: int = 16
const GLOBAL_TABLE: StringName = &"fx_lights"
const GLOBAL_COUNT: StringName = &"fx_light_count"
## A light reaches this many half-extents, and never past [constant
## MAX_RADIUS]: a point light without shadows shines through walls, so the
## reach is kept to a field or two.
const RADIUS_SCALE: float = 5.0
const MAX_RADIUS: float = 8.0
## Colour gain at the source: 1 doubles a white texel under the light's centre.
const LIGHT_GAIN: float = 2.0
## A halo's half-size in half-extents, and its colour gain.
const HALO_SCALE: float = 2.5
const HALO_GAIN: float = 0.8
## Sources darker than this are not worth a slot.
const MIN_LUMINANCE: float = 0.04
## A texel brighter than this in any channel is part of a sprite's flame
## rather than the black around it.
const LIT_TEXEL: int = 24
const FALLOFF_SIZE: int = 64
const HALO_SHADER: String = "res://game/shaders/halo.gdshader"

var lights_enabled: bool = false
var halos_enabled: bool = false

var _tile: int = BlobSprites.TILE
var _grid: int = BlobSprites.GRID
var _half_extent_scale: float = BlobSprites.HALF_EXTENT_SCALE
## Each atlas tile's lit colour, row-major, `grid * grid` entries; its alpha
## is the share of the tile those texels cover.
var _tile_colours: PackedColorArray = PackedColorArray()
var _table: Image = null
var _table_texture: ImageTexture = null
var _immediate: ImmediateMesh = null
## What the global count was last set to; -1 before the first publish.
var _count: int = -1


## `atlas` is the decoded `anim` page (the bank's PNG, not a texture read back
## from the renderer); `document` is `tables/blobs.json`, as for [BlobSprites].
func setup(atlas: Image, document: Dictionary = {}) -> void:
	var geometry: Dictionary = DictRead.as_dict(document.get("atlas", {}))
	if not geometry.is_empty():
		_tile = DictRead.as_int(geometry["tile"])
		_grid = DictRead.as_int(geometry["grid"])
		_half_extent_scale = float(
			DictRead.as_int(geometry["half_extent_scale"]))
	_tile_colours = tile_colours(atlas, _tile, _grid)
	_table = Image.create_empty(LIMIT, 2, false, Image.FORMAT_RGBAF)
	_table_texture = ImageTexture.create_from_image(_table)
	_immediate = ImmediateMesh.new()
	mesh = _immediate
	var material: ShaderMaterial = ShaderMaterial.new()
	material.shader = load(HALO_SHADER)
	material.set_shader_parameter(&"falloff", falloff_texture())
	material_override = material
	transform = Transform3D.IDENTITY
	custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	RenderingServer.global_shader_parameter_set(GLOBAL_TABLE, _table_texture)
	_publish(0)


## The lit colour of each `tile`-square of `atlas`, row by row: the mean of the
## texels brighter than [constant LIT_TEXEL], with the share of the tile they
## cover as alpha. A sprite is a flame on black, so the plain mean would be
## the flame diluted by its own background. An empty cell is transparent black.
static func tile_colours(atlas: Image, tile: int, grid: int) -> PackedColorArray:
	var out: PackedColorArray = PackedColorArray()
	out.resize(grid * grid)
	# `resize` fills opaque black; an empty tile covers nothing.
	out.fill(Color(0.0, 0.0, 0.0, 0.0))
	if atlas == null:
		return out
	var source: Image = atlas
	if source.get_format() != Image.FORMAT_RGB8:
		source = atlas.duplicate()
		source.convert(Image.FORMAT_RGB8)
	var width: int = source.get_width()
	var data: PackedByteArray = source.get_data()
	for row: int in range(grid):
		for column: int in range(grid):
			var red: int = 0
			var green: int = 0
			var blue: int = 0
			var lit: int = 0
			var count: int = 0
			for y: int in range(row * tile, mini((row + 1) * tile, source.get_height())):
				for x: int in range(column * tile, mini((column + 1) * tile, width)):
					var at: int = (y * width + x) * 3
					count += 1
					if maxi(data[at], maxi(data[at + 1], data[at + 2])) <= LIT_TEXEL:
						continue
					red += data[at]
					green += data[at + 1]
					blue += data[at + 2]
					lit += 1
			if lit > 0:
				out[row * grid + column] = Color(float(red) / (255.0 * lit),
					float(green) / (255.0 * lit), float(blue) / (255.0 * lit),
					float(lit) / float(count))
	return out


## A white-to-black radial disc, quadratic, for the halos.
static func falloff_texture() -> ImageTexture:
	var image: Image = Image.create_empty(FALLOFF_SIZE, FALLOFF_SIZE, false,
		Image.FORMAT_L8)
	var half: float = float(FALLOFF_SIZE) / 2.0
	for y: int in range(FALLOFF_SIZE):
		for x: int in range(FALLOFF_SIZE):
			var r: float = Vector2(float(x) + 0.5 - half,
				float(y) + 0.5 - half).length() / half
			var v: float = maxf(1.0 - r, 0.0)
			image.set_pixel(x, y, Color(v * v, v * v, v * v))
	return ImageTexture.create_from_image(image)


## One light: where, how far it reaches, what colour, and how it ranks.
class Source:
	var position: Vector3 = Vector3.ZERO
	var radius: float = 0.0
	var half: float = 0.0
	var colour: Color = Color.BLACK
	var weight: float = 0.0


## The light sources among `blobs`, brightest first, at most [constant LIMIT],
## with positions in Godot metres.
func sources(blobs: Array[Blob]) -> Array[Source]:
	var found: Array[Source] = []
	if _tile_colours.is_empty():
		return found
	for blob: Blob in blobs:
		if not blob.is_sprite() or blob.delay != 0:
			continue
		var colour: Color = _tile_colours[posmod(blob.rot_x, _grid) * _grid
			+ posmod(blob.rot_y, _grid)]
		var luminance: float = colour.get_luminance()
		if luminance < MIN_LUMINANCE:
			continue
		var source: Source = Source.new()
		source.half = float(blob.aux) * _half_extent_scale \
			/ WorldSpace.WORLD_UNITS_PER_METRE
		source.position = WorldSpace.to_godot(blob.x, blob.y, blob.z)
		source.radius = minf(source.half * RADIUS_SCALE, MAX_RADIUS)
		source.colour = colour
		source.weight = luminance * colour.a * source.half
		found.append(source)
	found.sort_custom(func(a: Source, b: Source) -> bool:
		return a.weight > b.weight)
	return found.slice(0, LIMIT)


## One frame: the table from this frame's sources, and their halos.
func rebuild(blobs: Array[Blob], basis: Basis) -> int:
	if _immediate == null:
		return 0
	_immediate.clear_surfaces()
	if not lights_enabled and not halos_enabled:
		_publish(0)
		return 0
	var chosen: Array[Source] = sources(blobs)
	if lights_enabled:
		for i: int in range(chosen.size()):
			var source: Source = chosen[i]
			_table.set_pixel(i, 0, Color(source.position.x, source.position.y,
				source.position.z, source.radius))
			_table.set_pixel(i, 1, Color(source.colour.r * LIGHT_GAIN,
				source.colour.g * LIGHT_GAIN, source.colour.b * LIGHT_GAIN, 1.0))
		_table_texture.update(_table)
	_publish(chosen.size() if lights_enabled else 0)
	if halos_enabled and not chosen.is_empty():
		_immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for source: Source in chosen:
			_halo(source.position, minf(source.half * HALO_SCALE, MAX_RADIUS),
				Color(source.colour.r * HALO_GAIN, source.colour.g * HALO_GAIN,
				source.colour.b * HALO_GAIN), basis)
		_immediate.surface_end()
	return chosen.size()


func _halo(centre: Vector3, half: float, colour: Color, basis: Basis) -> void:
	var dx: Vector3 = basis.x * half
	var dy: Vector3 = basis.y * half
	var corners: Array[Vector3] = [centre - dx + dy, centre + dx + dy,
		centre + dx - dy, centre - dx - dy]
	var uvs: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
		Vector2(0, 1)]
	for corner: int in [0, 1, 2, 0, 2, 3]:
		_immediate.surface_set_color(colour)
		_immediate.surface_set_uv(uvs[corner])
		_immediate.surface_add_vertex(corners[corner])


func _publish(count: int) -> void:
	if count == _count:
		return
	_count = count
	RenderingServer.global_shader_parameter_set(GLOBAL_COUNT, count)


func _exit_tree() -> void:
	_publish(0)


## The table's first `count` lights as `[x, y, z, radius, r, g, b]`, for the
## agent's snapshot.
func describe(count: int = 3) -> Array:
	var out: Array = []
	if _table == null:
		return out
	for i: int in range(mini(count, lit())):
		var where: Color = _table.get_pixel(i, 0)
		var colour: Color = _table.get_pixel(i, 1)
		out.append([snappedf(where.r, 0.01), snappedf(where.g, 0.01),
			snappedf(where.b, 0.01), snappedf(where.a, 0.01),
			snappedf(colour.r, 0.01), snappedf(colour.g, 0.01),
			snappedf(colour.b, 0.01)])
	return out


## How many lights the table holds now.
func lit() -> int:
	return maxi(_count, 0)
