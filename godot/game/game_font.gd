class_name GameFont
extends RefCounted

## The game's own bitmap fonts, as a Godot [FontFile].
##
## docs/60 section 5: `Libs/font_0.LIB` … `font_3.LIB` are proportional bitmap
## fonts of 224 glyphs each, one per **byte** from 32 to 255 of the release's
## code page, so a glyph's element index is `byte - 32`. The cache writes the
## byte and the Unicode code point it stands for; this registers by the code
## point, which is what a [String] indexes glyphs by.
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


const INDEX_PATH: String = "fonts/index.json"


## Build one font from the cache, or null when the cache has no fonts.
##
## A language pack's fonts are the same four `.LIB`s with the release's own
## glyphs in the 224 byte slots, registered under the code points the
## release's code page gives them (`inclib.language`): *paths* picks the
## pack's index when the chosen language carries one.
static func load_from(paths: CachePaths, font_name: String,
		shade: float = SHADE_COVERAGE) -> FontFile:
	var index: Dictionary = CacheLoader.read_json(paths.path(INDEX_PATH))
	if index.is_empty():
		return null
	for entry: Variant in DictRead.as_array(index.get("fonts", [])):
		var document: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_string(document["name"]) != font_name:
			continue
		return _build(paths, document, shade)
	return null


static func _build(paths: CachePaths, document: Dictionary,
		shade: float = SHADE_COVERAGE) -> FontFile:
	var path: String = paths.path("fonts/%s"
		% DictRead.as_string(document["file"]))
	if not FileAccess.file_exists(path):
		return null
	var image: Image = Image.new()
	# Read the bytes and decode rather than `Image.load`: the development
	# fixtures live under `res://` and `load` warns it will not work on export,
	# while this works the same way for `res://` and for the `user://` cache
	# production actually uses.
	if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	image = _as_alpha(image, shade)

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


## What the second ink index is worth beside the first, for a ramp that is not
## the body one -- 12/31, out of `0x632C` over `0xFFFF` and `0x6000` over
## `0xF800`. See [constant SHADE_COVERAGE].
##
## **Index 2 is the glyph's antialiasing, and it is half-covered, not solid.**
## The four shipped faces use exactly the values 0, 1 and 2 -- `font_3` only 0
## and 1 -- and the blitter `0x00447900` maps them straight onto the caller's
## four colours: at `0x00447ADD` (the 16-bit path the game runs in) a 1 takes
## `colour[0]` and **everything else** takes `colour[1]`, with 0, 3 and 4
## skipped; the 8-bit path at `0x00447A2A` is the same ladder written out to
## `colour[3]`. So a glyph is drawn in two tones, and the second is the one
## `aPrintGUITextBox` sets beside the first: `0x0043E47A` writes the body ramp
## `0x94B2` / `0x528A` and `0x0043E458` the alert ramp `0xF800` / `0x6000`.
##
## **All three ramps are known**, and two of them agree. `0x0043D891` copies a
## box's four colours out of the descriptor handed to `aCreateGUITextBox`, and
## the briefing's and the info page's is the one global `0x0050B2B4`, written
## with the same immediates by all four of its writers: `0xFFFF, 0x632C, 0, 0`.
## So the fractions are 12/31 for the default ramp, 10/18 for the body one and
## 12/31 again for the alert one -- [constant SHADE_COVERAGE] and
## [constant SHADE_BODY], and *shade* picks between them.
##
## The shade is written **opaque** rather than as an alpha. The original writes
## `colour[1]` into the frame buffer; it never blends. Over a light patch of a
## plate an alpha would take the background instead, which is a visible error
## and the one this used to make.
##
## Painting index 2 solid ink instead -- which is what this did until
## 2026-09-08 -- fattens every stem by a pixel, fills the counters of `a`, `o`
## and `e`, and is why the remake's text read as a different, blobbier face
## than the original's.
const SHADE_COVERAGE: float = 12.0 / 31.0
## `0x528A` over `0x94B2`, the body ramp `{#1}` selects.
const SHADE_BODY: float = 10.0 / 18.0

## The atlas as white pixels: index 0 transparent, index 1 solid, index 2 at
## *shade* of the ink and **opaque**.
##
## The cache stores the raw palette index in all three channels, because that
## is what the file holds and the cache decides nothing. Turning it into
## coverage is a decision, and the obvious version of it is wrong: a glyph's
## pixels are *indices*, not intensities. `font_2` uses only the values 0, 1
## and 2, so `alpha = value / 255` renders the whole font at 1 % opacity --
## invisible, which is exactly how it first came out.
##
## Ink is white so that a [Label]'s own `font_color` tints it, which is the
## freedom the original had when it handed the font a palette.
static func _as_alpha(source: Image,
		shade: float = SHADE_COVERAGE) -> Image:
	var out: Image = Image.create_empty(source.get_width(),
		source.get_height(), false, Image.FORMAT_RGBA8)
	var dim: Color = Color(shade, shade, shade, 1.0)
	for y: int in range(source.get_height()):
		for x: int in range(source.get_width()):
			var index: int = roundi(source.get_pixel(x, y).r * 255.0)
			if index == 0:
				out.set_pixel(x, y, Color(1.0, 1.0, 1.0, 0.0))
			elif index == 1:
				out.set_pixel(x, y, Color(1.0, 1.0, 1.0, 1.0))
			else:
				out.set_pixel(x, y, dim)
	return out
