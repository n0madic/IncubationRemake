class_name BriefingText
extends RichTextLabel

## Renders docs/24's markup, out of the cache's **structured** form.
##
## `text/briefing/<mission>.json` carries each block as a list of spans, each
## with its font and colour ramp, because docs/92 section 3.2 asks the cache to
## carry markup as structure: a consumer that re-parsed `{§n}` and `{#n}` out of
## a string would be a second implementation of `inclib/brieftext.py`.
##
## The two fonts `{§n}` selects are `Libs/font_0.LIB` and `font_1.LIB`
## (`aGetFont` `0x00439E20` returns -1 for anything else), and the three colour
## ramps are `aPrintGUITextBox`'s at `0x0043E445`.

## `{§0}` and `{§1}`.
const FONT_NAMES: Array[String] = ["font_0", "font_1"]
## The body's size when it is not drawn in the shipped faces, in the plate's
## own units: small enough that a long `A0` still fits the box, large enough
## to read beside a heading.
const READABLE_SIZE: int = 12

## `COLOUR_RAMPS` at `0x0043E445`, as RGB565 converted to sRGB: ramp 0 restores
## the box's own colours, 1 is the green-grey body text and 2 the red one.
## Only the brightest of each ramp's four entries is used here -- the other
## three shade a glyph's outline, which this renderer does not draw.
const RAMP_DEFAULT: Color = Color(0.82, 0.82, 0.78)
## `0x94B2` -- r 18, g 37, b 18 in RGB565.
const RAMP_BODY: Color = Color(18.0 / 31.0, 37.0 / 63.0, 18.0 / 31.0)
## `0xF800` -- r 31, g 0, b 0.
const RAMP_ALERT: Color = Color(1.0, 0.0, 0.0)

## Six of the 116 shipped `A0` blocks do not fit the box, so the label scrolls.
const SCROLL_STEP: float = 24.0

var _fonts: Array[FontFile] = []


## *game_font* asks for the shipped faces `font_0` and `font_1`, which is what
## `{§n}` selects and what the original draws a briefing in.
##
## They are **8 px bitmaps**, the smallest of the four (docs/60), so on the
## 640x480 layout space they are a third the height of the headings around
## them and cannot be antialiased -- which is exactly how a briefing came out:
## legible headings over body text nobody could read. With the readable face
## the override is left off entirely and a size is set instead, and the span
## colours and the bold of `font_1` are unaffected either way.
static func create(cache_dir: String, game_font: bool = true) -> BriefingText:
	var label: BriefingText = BriefingText.new()
	label.bbcode_enabled = true
	label.scroll_active = true
	label.fit_content = false
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.use_game_font(cache_dir, game_font)
	return label


## Swap between the shipped faces and the readable one **in place**, so a
## label already on screen follows the interface setting without being rebuilt.
##
## *size* overrides [constant READABLE_SIZE] for the readable face; the box the
## pickup message is drawn in is narrower than a briefing's and reads better a
## point larger.
func use_game_font(cache_dir: String, game_font: bool,
		size: int = READABLE_SIZE) -> void:
	_fonts.clear()
	remove_theme_font_override("normal_font")
	remove_theme_font_size_override("normal_font_size")
	remove_theme_font_size_override("bold_font_size")
	if not game_font:
		add_theme_font_size_override("normal_font_size", size)
		add_theme_font_size_override("bold_font_size", size)
		return
	for name: String in FONT_NAMES:
		var font: FontFile = GameFont.load_from(cache_dir, name)
		_fonts.append(font)
	if not _fonts.is_empty() and _fonts[0] != null:
		add_theme_font_override("normal_font", _fonts[0])


static func ramp_colour(index: int) -> Color:
	match index:
		1: return RAMP_BODY
		2: return RAMP_ALERT
	return RAMP_DEFAULT


## Turn one block's spans into the BBCode this label draws.
##
## `break_before` is the hard `@`; the soft wrap is Godot's, which is a
## deliberate divergence -- `inclib/brieftext.layout` reproduces
## `aCreateGUITextBox`'s own measuring loop and this does not, because the
## remake's box is a different width and a wrap position copied from a 1997
## layout would be wrong here rather than faithful.
static func to_bbcode(spans: Array) -> String:
	var out: PackedStringArray = PackedStringArray()
	for entry: Variant in spans:
		var span: Dictionary = entry
		if DictRead.as_bool(span.get("break_before", false)):
			out.append("\n")
		var body: String = DictRead.as_string(span["text"])
		if body == "":
			continue
		var colour: Color = ramp_colour(DictRead.as_int(span["colour"]))
		# Font 1 is the heavier of the two and is what the shipped blocks use
		# for their headings, so it is rendered bold rather than by swapping
		# the face: the two bitmap faces differ in weight, not in metrics.
		var opened: String = "[color=#%s]" % colour.to_html(false)
		if DictRead.as_int(span["font"]) == 1:
			opened += "[b]"
		out.append(opened + body.replace("[", "[lb]")
			+ ("[/b]" if DictRead.as_int(span["font"]) == 1 else "")
			+ "[/color]")
	return "".join(out)


func show_block(spans: Array) -> void:
	text = ""
	append_text(to_bbcode(spans))


## What the six overlong `A0` blocks need.
func scroll_by(lines: float) -> void:
	var bar: VScrollBar = get_v_scroll_bar()
	if bar == null:
		return
	bar.value = clampf(bar.value + lines * SCROLL_STEP, bar.min_value,
		bar.max_value)
