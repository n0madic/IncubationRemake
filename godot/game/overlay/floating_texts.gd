class_name FloatingTexts
extends CanvasLayer

## The animation overlay of type 0 (docs/42 section 1.1): the fight caption
## at (80, 54) and the floating texts of section 4.4, each rising two pixels
## a frame and fading over fifteen.
##
## The original draws these into a 640x480 frame with the game's own font;
## the remake draws them with the same font in a viewport of whatever size,
## scaled by [method scale] -- **that factor is the remake's**, there is no
## engine number behind it, and it is the one thing here that is not a
## transcription. Everything else is: the caption's corner, the rise, the
## fade and the countdown `0x004FC0A0` the tick decrements.
##
## Nothing here knows what a shot is. [ShotSequence] asks for a caption, adds
## the texts once the round has landed, starts the fade, and reads
## [method is_fading] to know when the routine may end.

## The frame the original draws into.
const ORIGINAL_WIDTH: float = 640.0
const ORIGINAL_HEIGHT: float = 480.0
## `push 0x36 / push 0x50` in the tick -- the caption's corner.
const CAPTION_AT: Vector2 = Vector2(80.0, 54.0)
## `add edx, -2` -- the rise per frame, in the original's pixels.
const RISE_PER_FRAME: float = 2.0
## `mov [0x004FC0A0], 0xF` -- the fade countdown, in frames.
const FADE_FRAMES: int = 15
## `mov word [esi], 0x5ACB` -- the texts' colour word. **UNVERIFIED as a
## colour**: RGB565 is the pixel plot's format (docs/97 section 23.4), and
## whether the text drawer takes the same word or a palette index is not
## read; as 565 it is a mid grey.
const TEXT_COLOUR: Color = Color8(88, 88, 88)
## The entry types of docs/42 section 4.4, by marker.
const TYPE_MISSED: int = 0
const TYPE_NO_DAMAGE: int = 1
const TYPE_DAMAGE: int = 2
const TYPE_KILLED: int = 3
const TYPE_DAMAGE_OBJECT: int = 4
const TYPE_KILLED_OBJECT: int = 5
## `0x004FBFF4` bounds the entries at sixteen.
const MAX_ENTRIES: int = 16

var _font: FontFile = null
var _caption: Label = null
## Whether the caption is overlay 3's centred one rather than overlay 0's.
var _centred: bool = false
var _entries: Array[Label] = []
## `0x004FC0A0` -- frames of fade left; zero when nothing is fading.
var countdown: int = 0
## How many frames [method tick] has run since the fade began, for a suite.
var ticked: int = 0


func _init() -> void:
	layer = 2
	_caption = Label.new()
	_caption.visible = false
	_caption.add_theme_color_override("font_color", TEXT_COLOUR)
	add_child(_caption)


## The game's own bitmap font, when the cache carries it.
func use_font(font: FontFile) -> void:
	_font = font
	_apply_font(_caption)


func _apply_font(label: Label) -> void:
	if _font == null:
		return
	label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", _font.fixed_size)


## Viewport pixels per original pixel -- **the remake's factor**, named.
func scale() -> float:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return 1.0
	var height: float = viewport.get_visible_rect().size.y
	return 1.0 if height <= 0.0 else height / ORIGINAL_HEIGHT


## The fight caption -- *"<name> received N experience points"* -- or
## nothing for the empty string, which is what a computer's or a reaction's
## shot formats (docs/42 section 4.2).
func set_caption(text: String) -> void:
	_caption.text = text
	_caption.visible = text != ""
	_centred = false
	_layout_caption()


## Overlay type 3 (docs/42 section 7.5): the orbits' caption, centred on
## the original's 640-wide frame at the caption row. The original centres
## it by the text's own pixel width; the remake centres it with the label's
## alignment over the viewport's width -- **the remake's layout**, named.
func set_centred_caption(text: String) -> void:
	_caption.text = text
	_caption.visible = text != ""
	_centred = text != ""
	_layout_caption()


## Whether the caption on screen is the centred one, for a suite.
func is_caption_centred() -> bool:
	return _centred and _caption.visible


func _layout_caption() -> void:
	var factor: float = scale()
	if _centred:
		var viewport: Viewport = get_viewport()
		var width: float = ORIGINAL_WIDTH * factor
		if viewport != null:
			width = viewport.get_visible_rect().size.x
		_caption.position = Vector2(0.0, CAPTION_AT.y * factor)
		_caption.size = Vector2(width, 0.0)
		_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	else:
		_caption.position = CAPTION_AT * factor
		_caption.size = Vector2.ZERO
		_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT


func caption() -> String:
	return _caption.text if _caption.visible else ""


func clear_caption() -> void:
	set_caption("")


## One floating text at a screen position (viewport pixels). Refused past the
## sixteenth, as `0x004FBFF4` refuses it.
func add_text(text: String, at: Vector2) -> bool:
	if _entries.size() >= MAX_ENTRIES:
		return false
	var label: Label = Label.new()
	label.text = text
	label.position = at
	label.add_theme_color_override("font_color", TEXT_COLOUR)
	_apply_font(label)
	add_child(label)
	_entries.append(label)
	return true


func entries() -> int:
	return _entries.size()


## Overlay type 0 is selected: the countdown starts at fifteen.
func begin_fade() -> void:
	countdown = FADE_FRAMES
	ticked = 0


func is_fading() -> bool:
	return countdown > 0


## One displayed frame of overlay 0 (`0x0040B6F0`): every text rises two
## pixels, the alpha follows the countdown, and the countdown drops by one.
func tick() -> void:
	if countdown <= 0:
		return
	var factor: float = scale()
	var alpha: float = float(countdown) / float(FADE_FRAMES)
	for label: Label in _entries:
		label.position.y -= RISE_PER_FRAME * factor
		label.modulate.a = alpha
	countdown -= 1
	ticked += 1
	if countdown == 0:
		_drop_entries()


func _drop_entries() -> void:
	for label: Label in _entries:
		remove_child(label)
		label.free()
	_entries.clear()


## Everything off the screen: the texts, the caption and the countdown.
func clear() -> void:
	_drop_entries()
	countdown = 0
	clear_caption()
