class_name PaletteCurve
extends RefCounted
## What the Compatibility renderer does to a colour on its way to the frame,
## and the value to feed it so the palette byte comes out unchanged.
##
## The original writes its palette straight into the framebuffer: a texel of
## 11 is 11 on screen, and the additive and translucent kinds of
## [`docs/31` §4.4] add and lerp those bytes as they are.  Godot's
## `gl_compatibility` path runs an unshaded fragment's colour through two
## approximations that are not inverses of one another at the dark end: the
## GLES3 scene shader's polynomial `srgb_to_linear`
## (`c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878)`) and the
## simplified `linear_to_srgb` the documentation quotes
## (`max(1.055 * pow(c, 1 / 2.4) - 0.055, 0)`).  Measured on 2026-09-22 with
## Godot 4.7.2 (`docs/92` §7.25): a texel of 8 draws as 1, 11 as 5, 16 as
## 11, 21 as 17, 31 as 29, exact from 62 up, through `albedo_texture`,
## `albedo_color`, a raw `ALBEDO`, a `Sprite3D` and a `SubViewport` alike,
## while the 2D canvas and the clear colour are untouched.  Mobile and
## Forward+ decode in hardware and encode exactly, so they take the byte as
## it is.
##
## The correction is a 256-entry table applied where the 3D picture's colours
## enter: the byte whose round trip lands nearest the wanted value.  Every
## RGB565 expansion the converter writes (`0, 8, 16, 24, 33, ...` and the
## six-bit greens) is reached exactly except where the round trip skips a
## value, where the error is one level — below the RGB565 quantisation the
## original's own framebuffer imposed.  A texture is remapped once when its
## bank is loaded; a vertex colour is remapped as it is set, since the mesh
## stores it in eight bits anyway.
##
## **Coupled to the engine's shader source.**  The constants are Godot
## 4.7.2's; `docs/92` §7.25 names the windowed probe that re-measures the
## whole table, and an engine upgrade re-runs it before trusting this file.

## The GLES3 polynomial `srgb_to_linear`.
const POLY_A: float = 0.305306011
const POLY_B: float = 0.682171111
const POLY_C: float = 0.012522878
## The simplified `linear_to_srgb`.
const ENCODE_SCALE: float = 1.055
const ENCODE_OFFSET: float = 0.055
const ENCODE_POWER: float = 1.0 / 2.4

const RENDERING_METHOD: String = "gl_compatibility"
const LEVELS: int = 256


## Whether the running renderer needs the correction at all.
static func is_active() -> bool:
	return RenderingServer.get_current_rendering_method() == RENDERING_METHOD


## The value the Compatibility renderer puts on screen for an unshaded colour
## of `x`, both in `0..1`.
static func forward(x: float) -> float:
	var linear: float = x * (x * (x * POLY_A + POLY_B) + POLY_C)
	return maxf(ENCODE_SCALE * pow(linear, ENCODE_POWER) - ENCODE_OFFSET, 0.0)


## `table()[v]` is the byte to draw so that `v` reaches the screen.
##
## Built by walking the bytes once: `forward` is monotonic, so the first byte
## whose round trip reaches `v` and the one before it are the two candidates,
## and the nearer is taken.  A tie goes to the lower byte.  Against the
## measured table the round trip is exact on 234 of the 256 values on this
## host and one level off on the rest, all below 62; the exact count sits on
## a few near-ties of `pow`, so the invariant is the one-level bound.
static func table() -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	out.resize(LEVELS)
	var round_trip: PackedFloat32Array = PackedFloat32Array()
	round_trip.resize(LEVELS)
	for b: int in range(LEVELS):
		round_trip[b] = forward(float(b) / float(LEVELS - 1)) * float(LEVELS - 1)
	var b: int = 0
	for v: int in range(LEVELS):
		while b + 1 < LEVELS and round_trip[b] < float(v):
			b += 1
		var best: int = b
		if b > 0 and absf(round_trip[b - 1] - float(v)) \
				<= absf(round_trip[b] - float(v)):
			best = b - 1
		out[v] = best
	return out


## A copy of `image` with every colour byte put through `curve`; alpha is
## left alone.  An image in any other format is converted to RGBA8 first.
static func remap(image: Image, curve: PackedByteArray) -> Image:
	return remap_channels(image, [curve, curve, curve])


## [method remap] with a table of its own for each of red, green and blue --
## the shape [method MeshBuilder.channel_tables] needs, where the green field
## of RGB565 is six bits and the other two are five.
static func remap_channels(image: Image, tables: Array[PackedByteArray]) -> Image:
	var source: Image = image
	var format: int = image.get_format()
	if format != Image.FORMAT_RGB8 and format != Image.FORMAT_RGBA8:
		source = image.duplicate()
		source.convert(Image.FORMAT_RGBA8)
		format = Image.FORMAT_RGBA8
	var stride: int = 4 if format == Image.FORMAT_RGBA8 else 3
	var red: PackedByteArray = tables[0]
	var green: PackedByteArray = tables[1]
	var blue: PackedByteArray = tables[2]
	var data: PackedByteArray = source.get_data()
	var count: int = data.size()
	var i: int = 0
	while i < count:
		data[i] = red[data[i]]
		data[i + 1] = green[data[i + 1]]
		data[i + 2] = blue[data[i + 2]]
		i += stride
	return Image.create_from_data(source.get_width(), source.get_height(),
		false, format, data)


## `colour` with its three channels put through `curve`, alpha kept.
static func colour(colour: Color, curve: PackedByteArray) -> Color:
	return Color8(curve[colour.r8], curve[colour.g8], curve[colour.b8],
		colour.a8)
