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
## The theme slots the four shaded faces go into, in the order
## [method use_game_font] builds them: `font_0` and `font_1` at the default
## shade, then the same two at the body ramp's.
const FONT_SLOTS: Array[String] = ["normal_font", "bold_font",
	"italics_font", "bold_italics_font"]
## The ramp whose second entry is not the other two's -- the one `[i]` marks.
const RAMP_BODY_INDEX: int = 1
## The box's own colours, which `{§0}` selects and a heading is drawn in.
const RAMP_DEFAULT_INDEX: int = 0
## The body's size when it is not drawn in the shipped faces, in the plate's
## own units: small enough that a long `A0` still fits the box, large enough
## to read beside a heading.
##
## **Ten, not twelve, because the box is not the whole plate.** The briefing
## programme puts its pictures at their own `x, y` inside the same 640x480
## (docs/24 section 8), and on `_C_106`'s `C0` two of them start at `y` 240 --
## inside a text box that runs from 77 to 353. At 12 the readable face ran a
## line and a half further down than the 8 px `font_0` does, so this is
## [constant CampaignScreen.READABLE_SIZE]'s own `font_0` entry, the
## cap-height match for the face the body is actually written in. The size
## is not what keeps the two apart, though -- `_C_151`'s pictures sit under
## its block in the shipped face too -- [method BriefingScreen.settle_pictures]
## is.
const READABLE_SIZE: int = 10

## `COLOUR_RAMPS` at `0x0043E445`, as RGB565 converted to sRGB: ramp 0 is the
## box's own colours, 1 the green-grey body text and 2 the red one. The first
## entry of each is the ink; the **second** is what a glyph's index-2 pixels
## are drawn in, and that is carried by the face rather than by the span --
## see [method use_game_font].
##
## Ramp 0 is `0xFFFF`, plain white. It used to be guessed at here as a warm
## off-white because it "restores the box's own colours" and those were taken
## to be unknowable; they are not. `0x0043D891` copies them out of the
## descriptor `aCreateGUITextBox` is handed, the briefing's is the one global
## `0x0050B2B4`, and its four writers all put `0xFFFF, 0x632C, 0, 0` in it.
const RAMP_DEFAULT: Color = Color(1.0, 1.0, 1.0)
## `0x94B2` -- r 18, g 37, b 18 in RGB565.
const RAMP_BODY: Color = Color(18.0 / 31.0, 37.0 / 63.0, 18.0 / 31.0)
## `0xF800` -- r 31, g 0, b 0.
const RAMP_ALERT: Color = Color(1.0, 0.0, 0.0)

## Six of the 116 shipped `A0` blocks do not fit the box, so the label scrolls.
const SCROLL_STEP: float = 24.0

## The typewriter -- docs/24 section 5. `aActivateBriefingInfo`'s sixth
## argument at 0 installs `1` in the four print limits and `fcn.0043ECF0`
## adds one to each on every printed frame (`0x0043F0AB`, caps 5000 and
## 50000), so one more glyph shows per frame; a space drawn while the word
## count is under its limit plays `textbeep.wav` (`0x0043E3C1`). The frame is
## the front end's, `0x0044BDB0`'s 20 a second (docs/92 section 7.19).
const TYPEWRITER_FPS: float = 20.0
const TYPEWRITER_PER_FRAME: int = 1
## The blip's wave, as `aInitGUI` loads it beside the two clicks.
const BLIP_WAVE: String = "textbeep.wav"


## The cue every typing screen plays on a finished word.
##
## **One seam, because there are three screens.** The briefing page, the
## deployment screen and the location map's `B0` all blip, and the volume was
## written out three times: two passed [constant AudioTables.NO_SCALING] --
## the GUI's own volume, as `0x0043E3C1` plays it beside the two clicks -- and
## the third passed `0`, a real table id. The shipped table's entry 0 is 100,
## so it sounded the same and nothing said otherwise; a cache without that id
## would have answered `REFUSED` and silenced that one screen.
##
## `site` is the block the text came from, for the agent's pool view; the two
## screens that have only one block leave it empty.
static func blip_cue(site: String = "") -> Dictionary:
	var cue: Dictionary = {"wave": BLIP_WAVE,
		"volume_id": AudioTables.NO_SCALING, "loop": false}
	if site != "":
		cue["site"] = site
	return cue

## One word finished under the typewriter: the caller plays the blip.
signal blip

var _typing: bool = false
var _carry: float = 0.0
var _shown: int = 0
var _plain: String = ""

var _fonts: Array[FontFile] = []
## Whether all four shaded faces are up, which is what makes `[i]` mean the
## body ramp's shade rather than an italic.
var _shaded: bool = false


## *game_font* asks for the shipped faces `font_0` and `font_1`, which is what
## `{§n}` selects and what the original draws a briefing in.
##
## They are **8 px bitmaps**, the smallest of the four (docs/60), so on the
## 640x480 layout space they are a third the height of the headings around
## them and cannot be antialiased -- which is exactly how a briefing came out:
## legible headings over body text nobody could read. With the readable face
## the override is left off entirely and a size is set instead, and the span
## colours are unaffected either way.
## *faces* is [method game_faces]' answer kept by the caller: a screen that
## rebuilds its whole tree on every click would otherwise walk the atlas four
## times a redraw.
static func create(paths: CachePaths, game_font: bool = true,
		size: int = READABLE_SIZE,
		faces: Array[FontFile] = []) -> BriefingText:
	var label: BriefingText = BriefingText.new()
	label.bbcode_enabled = true
	label.scroll_active = true
	label.fit_content = false
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.use_game_font(paths, game_font, size, faces)
	return label


## The four faces [method use_game_font] binds, built once.
##
## `font_0` and `font_1`, each at the default shade and at the body ramp's --
## see [method use_game_font] for why a face carries its own.
static func game_faces(paths: CachePaths) -> Array[FontFile]:
	var out: Array[FontFile] = []
	if paths == null:
		return out
	for name: String in FONT_NAMES:
		out.append(GameFont.load_from(paths, name, GameFont.SHADE_COVERAGE))
	for name: String in FONT_NAMES:
		out.append(GameFont.load_from(paths, name, GameFont.SHADE_BODY))
	return out


## Swap between the shipped faces and the readable one **in place**, so a
## label already on screen follows the interface setting without being rebuilt.
##
## *size* overrides [constant READABLE_SIZE] for the readable face; the box the
## pickup message is drawn in is narrower than a briefing's and reads better a
## point larger.
func use_game_font(paths: CachePaths, game_font: bool,
		size: int = READABLE_SIZE, faces: Array[FontFile] = []) -> void:
	_fonts.clear()
	_shaded = false
	for slot: String in FONT_SLOTS:
		remove_theme_font_override(slot)
		remove_theme_font_size_override(slot + "_size")
	if not game_font:
		for slot: String in FONT_SLOTS:
			add_theme_font_size_override(slot + "_size", size)
		return
	# **Four faces for two, because a face carries its own shade.** A glyph's
	# index-2 pixels are drawn in the *second* entry of the ramp in force
	# (`0x00447ADD`), and the three ramps do not agree on what fraction of the
	# first that is: 12/31 for ramps 0 and 2, 10/18 for the body ramp 1. The
	# atlas is one texture tinted by a colour, so the fraction has to be baked
	# in -- and the theme has four slots for the two faces. `{§1}` is written
	# `[b]` and a body-ramp span `[i]`, so the four combinations are exactly
	# (font_0, font_1) x (default shade, body shade) and every span is drawn
	# in the pair the original would have used.
	if faces.size() == FONT_SLOTS.size():
		_fonts.assign(faces)
	else:
		_fonts.assign(game_faces(paths))
	for index: int in range(FONT_SLOTS.size()):
		if index < _fonts.size() and _fonts[index] != null:
			add_theme_font_override(FONT_SLOTS[index], _fonts[index])
	_shaded = _fonts.size() == FONT_SLOTS.size() and not _fonts.has(null)


static func ramp_colour(index: int) -> Color:
	match index:
		1: return RAMP_BODY
		2: return RAMP_ALERT
	return RAMP_DEFAULT


## Turn one block's spans into the BBCode this label draws.
##
## `breaks` is **how many lines** the hard `@`s in front of the span start, and
## it is a count rather than a flag because a run of `@` does not start one
## line per character: `aCreateGUITextBox`'s measuring loop takes the character
## after a break unconditionally, so every second `@` in a run is an ordinary
## character the printer then skips (`0x0043E300`). Every shipped heading is
## written `heading@` with the body's own `@` on the next source line, which is
## two lines and therefore the blank line under it -- collapsing the pair into
## one break is what made the remake's briefings read as a solid slab.
##
## The soft wrap is Godot's, which is a deliberate divergence --
## `inclib/brieftext.layout` reproduces the same measuring loop and this does
## not, because the remake's box is a different width and a wrap position
## copied from a 1997 layout would be wrong here rather than faithful.
##
## *shaded* says the four game faces are up ([method use_game_font]), and then
## a body-ramp span is marked `[i]` so it takes the pair carrying that ramp's
## own second ink level. With the readable face there is no such level and
## `[i]` would be a real italic, so it is not emitted.
static func to_bbcode(spans: Array, shaded: bool = false) -> String:
	var out: PackedStringArray = PackedStringArray()
	for entry: Variant in spans:
		var span: Dictionary = entry
		var breaks: int = DictRead.as_int(span.get("breaks", 0))
		for _line: int in range(breaks):
			out.append("\n")
		var body: String = DictRead.as_string(span["text"])
		if body == "":
			continue
		var ramp: int = DictRead.as_int(span["colour"])
		var colour: Color = ramp_colour(ramp)
		# Font 1 is the heavier of the two and is what the shipped blocks use
		# for their headings, so it is written as bold -- and
		# [method use_game_font] binds `bold_font` to `font_1` itself, which
		# is the swap. The two faces are not one weight of one design: an `M`
		# is 9 units wide in `font_1` against `font_0`'s 7 and the ascent is
		# 8 against 7, so *Mission Description:* measures 119 units to the
		# other's 94.
		var heavy: bool = DictRead.as_int(span["font"]) == 1
		var body_ramp: bool = shaded and ramp == RAMP_BODY_INDEX
		var opened: String = "[color=#%s]" % colour.to_html(false)
		var closed: String = "[/color]"
		if heavy:
			opened += "[b]"
			closed = "[/b]" + closed
		if body_ramp:
			opened += "[i]"
			closed = "[/i]" + closed
		out.append(opened + body.replace("[", "[lb]") + closed)
	return "".join(out)


func show_block(spans: Array) -> void:
	text = ""
	append_text(to_bbcode(spans, _shaded))
	if _typing:
		start_typewriter()


## Reveal the block one glyph per frame from the start. Idempotent on an
## empty block.
func start_typewriter() -> void:
	_typing = true
	_carry = 0.0
	_shown = 0
	_plain = get_parsed_text()
	visible_characters = 0


## Everything at once -- `animate != 0`, or a block already fully shown.
func finish_typewriter() -> void:
	_typing = false
	visible_characters = -1


func typing() -> bool:
	return _typing


## One frame of the host's clock. Answers how many blips the words that
## finished this frame owe -- a space is a word's end.
func tick_typewriter(delta: float) -> int:
	if not _typing:
		return 0
	var blips: int = 0
	_carry += delta * TYPEWRITER_FPS
	while _carry >= 1.0 and _typing:
		_carry -= 1.0
		for _glyph: int in range(TYPEWRITER_PER_FRAME):
			if _shown >= _plain.length():
				finish_typewriter()
				break
			if _plain[_shown] == " ":
				blips += 1
				blip.emit()
			_shown += 1
			visible_characters = _shown
	return blips


## What the six overlong `A0` blocks need.
func scroll_by(lines: float) -> void:
	var bar: VScrollBar = get_v_scroll_bar()
	if bar == null:
		return
	bar.value = clampf(bar.value + lines * SCROLL_STEP, bar.min_value,
		bar.max_value)
