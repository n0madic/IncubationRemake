class_name GameFont
extends RefCounted

## The game's own bitmap fonts, as a Godot [FontFile].
##
## docs/60 section 5: `Libs/font_0.LIB` … `font_3.LIB` are proportional bitmap
## fonts of 224 glyphs each, one per cp1252 code point from 32 to 255, so a
## glyph's element index is `codepoint - 32`.
##
## Two properties of the format decide how this is built:
##
## * a glyph's `delta_y` is its **ascent** -- its top row sits at
##   `baseline - delta_y` -- and `height - delta_y` is a constant per font, the
##   descent. So the per-glyph vertical offset is `-ascent` and the font's own
##   ascent is the largest of them;
## * the glyphs are palette **indices** and the fonts ship without a companion
##   `.pal`: the caller supplies the ramp. The cache writes the atlas as the
##   index value in all three channels, and the index is used here as
##   **alpha** with the colour left white, so a [Label]'s own `font_color`
##   tints it. That is what the original did by handing the font a palette.
##
## The cache carries JSON and PNG, not a `.fnt`: `FontFile.load_bitmap_font`
## would be less code and would put another engine's format inside the
## converted data, which docs/92 section 3.2 is exactly against.

## The nominal size the [FontFile] cache is keyed by. A bitmap font has one
## real size; this is only the key, and it is the atlas height so that two
## fonts of different heights cannot collide in one cache.
const VARIATION: int = 0
## docs/60 section 5 -- one blank column between glyphs when laying out text.
const TRACKING: int = 1


## Build one font from the cache, or null when the cache has no fonts.
static func load_from(cache_dir: String, font_name: String) -> FontFile:
	var index: Dictionary = CacheLoader.read_json(
		cache_dir + "/fonts/index.json")
	if index.is_empty():
		return null
	for entry: Variant in DictRead.as_array(index.get("fonts", [])):
		var document: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_string(document["name"]) != font_name:
			continue
		return _build(cache_dir, document)
	return null


static func _build(cache_dir: String, document: Dictionary) -> FontFile:
	var path: String = "%s/fonts/%s" % [cache_dir,
		DictRead.as_string(document["file"])]
	if not FileAccess.file_exists(path):
		return null
	var image: Image = Image.new()
	# Read the bytes and decode rather than `Image.load`: the development
	# fixtures live under `res://` and `load` warns it will not work on export,
	# while this works the same way for `res://` and for the `user://` cache
	# production actually uses.
	if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	image = _as_alpha(image)

	var glyphs: Array = DictRead.as_array(document["glyphs"])
	var height: int = DictRead.as_int(document["atlas_height"])
	var size: Vector2i = Vector2i(height, 0)
	var font: FontFile = FontFile.new()
	font.fixed_size = height
	font.set_texture_image(VARIATION, size, 0, image)

	var ascent: int = 0
	var descent: int = 0
	for entry: Variant in glyphs:
		var glyph: Dictionary = DictRead.as_dict(entry)
		ascent = maxi(ascent, DictRead.as_int(glyph["ascent"]))
		descent = maxi(descent, DictRead.as_int(glyph["height"])
			- DictRead.as_int(glyph["ascent"]))
	font.set_cache_ascent(VARIATION, height, float(ascent))
	font.set_cache_descent(VARIATION, height, float(descent))

	for entry: Variant in glyphs:
		var glyph: Dictionary = DictRead.as_dict(entry)
		var code: int = DictRead.as_int(glyph["codepoint"])
		var width: int = DictRead.as_int(glyph["width"])
		var glyph_height: int = DictRead.as_int(glyph["height"])
		font.set_glyph_texture_idx(VARIATION, size, code, 0)
		font.set_glyph_uv_rect(VARIATION, size, code,
			Rect2(float(DictRead.as_int(glyph["x"])), 0.0,
				float(width), float(glyph_height)))
		font.set_glyph_size(VARIATION, size, code,
			Vector2(float(width), float(glyph_height)))
		# The glyph's top row is `ascent` above the baseline, and its left side
		# bearing is 0 for everything except the two blank glyphs.
		font.set_glyph_offset(VARIATION, size, code,
			Vector2(float(DictRead.as_int(glyph["bearing"])),
				-float(DictRead.as_int(glyph["ascent"]))))
		font.set_glyph_advance(VARIATION, height, code,
			Vector2(float(width + TRACKING), 0.0))
	return font


## The atlas as white pixels: index 0 transparent, **any non-zero opaque**.
##
## The cache stores the raw palette index in all three channels, because that
## is what the file holds and the cache decides nothing. Turning it into
## coverage is a decision, and the obvious version of it is wrong: a glyph's
## pixels are *indices*, not intensities. `font_2` uses only the values 0, 1
## and 2, so `alpha = value / 255` renders the whole font at 1 % opacity --
## invisible, which is exactly how it first came out.
##
## `tools/font_render.py` documents the same trap and makes the same choice:
## "using the raw index as a grey level would render most glyphs near-black".
## Ink is white so that a [Label]'s own `font_color` tints it, which is the
## freedom the original had when it handed the font a palette.
##
## The two non-zero indices are kept in the cache, so a later slice that finds
## out what index 2 means -- an outline, most likely -- can use it without a
## reconversion.
static func _as_alpha(source: Image) -> Image:
	var out: Image = Image.create_empty(source.get_width(),
		source.get_height(), false, Image.FORMAT_RGBA8)
	for y: int in range(source.get_height()):
		for x: int in range(source.get_width()):
			var ink: bool = source.get_pixel(x, y).r > 0.0
			out.set_pixel(x, y, Color(1.0, 1.0, 1.0, 1.0 if ink else 0.0))
	return out
