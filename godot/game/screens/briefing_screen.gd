class_name BriefingScreen
extends CampaignScreen

## docs/24's blocks and the mission's picture programme, in the original's own
## layout.
##
## `A0` is the full briefing and `C0` the tips, and the screen is one screen
## for both: the title stays *Briefing* (`Txtmod_b` 30) and the middle button
## swaps between *Tips* (31) and *Briefing* (32), which is exactly what the
## shipped bank carries two words for. `B0` -- the short conditions -- is not
## here: docs/24 section 7.1's call sites put it on the unit-selection and map
## screens, and this screen never asks for it.
##
## **The coordinates are the game's own.** docs/24 section 7.1 records the text
## box as `84, 77, 280, 276` for `A0` and `84, 77, 230, 276` for `C0`, and the
## briefing programme (section 8) gives every picture its own `x, y` inside
## 640x480 with its description lines printed underneath. So the layout is read
## out of the shipped data rather than invented -- the pictures used to be
## placed at a fixed column that was 30 units off the right edge of the plate,
## where nothing could see them.

## `Txtmod_b` -- 'Briefing' is both the screen's name and the button back to it.
const ID_BRIEFING: int = 30
const ID_TIPS: int = 31
const ID_BACK_TO_BRIEFING: int = 32

## docs/24 section 7.1 -- `0x00456DE0` and `0x00456D96`.
const BOX_AT: Vector2 = Vector2(84.0, 77.0)
const BOX_SIZE_BRIEFING: Vector2 = Vector2(280.0, 276.0)
const BOX_SIZE_TIPS: Vector2 = Vector2(230.0, 276.0)
## How much room a picture's description lines are given under it, and how
## wide the line is allowed to run either side of the picture's centre.
##
## The tips screen puts **three** pictures across the bottom of the plate, so
## a caption may not be much wider than its own share: at 220 units and the
## default size the three ran into one another and read as one sentence.
const CAPTION_GAP: float = 3.0
const CAPTION_HEIGHT: float = 36.0
const CAPTION_SPREAD: float = 168.0
## The caption's size when the readable face is in use. The original draws
## these in `font_0`, the 8 px bitmap, under a picture 50 to 180 units wide.
const CAPTION_FONT_SIZE: int = 10

var mission: String = ""
var document: Dictionary = {}
var cache_dir: String = ""
## Which block is up -- `A0` or `C0`.
var block: String = "A0"
## Whether this screen was raised **over a running mission** -- interface
## event 11, the `B` key -- rather than as the campaign's own briefing step.
## It decides which buttons the screen has; see [method build].
var over_mission: bool = false

## Whether the block is revealed one glyph a frame (docs/24 section 5).
##
## In the original the campaign's briefing screen (`0x00456DCB`) and the tips
## (`0x00456D81`) both pass `animate = 0` and both type. **Here only the
## briefing does** -- docs/92 section 7.19's I20. The tips are a reference
## page the player opens to look something up and closes again, and typing
## them out is a wait for text that was already read once; the briefing is the
## one the reveal is *for*. The briefing's own reveal is interruptible with
## [method skip_typing], which is I21.
##
## The same page raised over a mission by `B` is `0x004577DB`'s recall, and
## its argument is not read here -- the recall shows what the player has
## already seen, so it does not type.
var animate: bool = true
## The cache-relative path of the mission's voice-over, `audio/briefing/
## <mission>.wav`, or `""` for a mission without one. The host plays and
## stops it; the screen only names it.
var voice: String = ""

var _text: BriefingText = null
var _pictures: Control = null
var _toggle: Button = null


func build() -> void:
	var _title: Label = place_title(label_for(BANK_MISSION, ID_BRIEFING))

	# `font` is the interface's, and `null` there means the readable face was
	# chosen -- so the body follows the same decision the headings did instead
	# of always being the shipped 8 px bitmap.
	_text = BriefingText.create(cache_dir, font != null)
	place_on_plate(_text, BOX_AT, BOX_SIZE_BRIEFING)
	root().add_child(_text)
	_text.blip.connect(_on_blip)
	if animate and not over_mission:
		_text.start_typewriter()

	_pictures = Control.new()
	_pictures.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pictures.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root().add_child(_pictures)

	# **Back to where it was opened from.** `B` raises this screen over a
	# running mission (docs/43 section 5.2's event 11, `0x0043B150`), and the
	# original's own button returns to the mission -- so the map's *Back* and
	# *Continue* are not this screen's buttons in that case. They were, and
	# both were wrong: *Back* went to the location map, which frees the
	# mission and, through `abandon_mission`, used to lose the squad standing
	# on it; *Continue* rebuilt the mission from scratch under the player.
	if over_mission:
		add_button("resume", BANK_MISSION, ID_BACK, 0)
	else:
		add_button("map", BANK_MISSION, ID_BACK, 0)
	# **Only where there is one.** 25 of the 116 shipped briefings carry no
	# `C0` at all (docs/24 section 7.1), and a button that opened an empty
	# screen would be the inert control section 7.1 calls a defect.
	if _has_block("C0"):
		_toggle = add_button("tips", BANK_MISSION, ID_TIPS, 1)
	if not over_mission:
		add_button("enter", BANK_MISSION, ID_CONTINUE, 2)
	_lay_out_buttons()
	show_block(block)


## One of `A0` or `C0`. A block the file does not carry shows empty rather
## than erroring: docs/24 records that not every briefing has all three.
func show_block(key: String) -> void:
	block = key
	if _text == null:
		return
	var blocks: Dictionary = DictRead.as_dict(document.get("blocks", {}))
	_text.show_block(DictRead.as_array(blocks.get(key, [])))
	# The tips are shown whole, and coming back to the briefing after them
	# does not start the reveal again: [method BriefingText.show_block] only
	# restarts a typewriter that is already running, so one visit to `C0`
	# settles the page for as long as it is up.
	if key == "C0":
		_text.finish_typewriter()
	place_on_plate(_text, BOX_AT,
		BOX_SIZE_TIPS if key == "C0" else BOX_SIZE_BRIEFING)
	if _toggle != null:
		_toggle.text = label_for(BANK_MISSION,
			ID_BACK_TO_BRIEFING if key == "C0" else ID_TIPS)
	_show_pictures("tips" if key == "C0" else "pictures")


## The briefing programme's own rows: the picture at its `x, y` with its
## description lines centred underneath (docs/24 section 8).
##
## The rows come from two lists because the programme has two base rows -- 0
## for the objectives screen and 5 for the tips one -- and the converter keeps
## them apart under those names.
func _show_pictures(key: String) -> void:
	if _pictures == null:
		return
	clear_children(_pictures)
	for entry: Variant in DictRead.as_array(document.get(key, [])):
		var row: Dictionary = entry
		var name: String = DictRead.as_string(row["picture"])
		if name == "" or art == null:
			continue
		var texture: Texture2D = art.briefing_picture(name)
		if texture == null:
			# `_C_132`'s tip picture is named `No` and no such bitmap ships,
			# so the original draws nothing there either (docs/24 section 8).
			continue
		var at: Vector2 = Vector2(float(DictRead.as_int(row["x"])),
			float(DictRead.as_int(row["y"])))
		var size: Vector2 = Vector2(float(texture.get_width()),
			float(texture.get_height()))
		var view: TextureRect = TextureRect.new()
		view.texture = texture
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_SCALE
		view.mouse_filter = Control.MOUSE_FILTER_IGNORE
		place_on_plate(view, at, size)
		_pictures.add_child(view)

		var lines: PackedStringArray = DictRead.to_strings(
			row.get("descriptions", []))
		if lines.is_empty():
			continue
		# Centred on the picture and allowed to run wider than it: the shipped
		# lines are sentences and the pictures are 50 to 180 units across, so
		# a caption bounded by its picture would wrap to four words a line.
		# The original centres them the same way and lets them overhang.
		var caption: Label = make_label("\n".join(lines))
		if font == null:
			caption.add_theme_font_size_override("font_size",
				CAPTION_FONT_SIZE)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		place_on_plate(caption,
			Vector2(at.x + size.x * 0.5 - CAPTION_SPREAD * 0.5,
				at.y + size.y + CAPTION_GAP),
			Vector2(CAPTION_SPREAD, CAPTION_HEIGHT))
		_pictures.add_child(caption)


func _has_block(key: String) -> bool:
	var blocks: Dictionary = DictRead.as_dict(document.get("blocks", {}))
	return not DictRead.as_array(blocks.get(key, [])).is_empty()


func scroll(lines: float) -> void:
	if _text != null:
		_text.scroll_by(lines)


## The typewriter's clock -- `_process` rather than the host's tick, because
## this screen is a [CanvasLayer] on the tree and the pickup box's reason for
## a hosted clock (a suite building it off-tree) applies to the checks here
## only through [method tick].
func _process(delta: float) -> void:
	tick(delta)


func tick(delta: float) -> void:
	if _text != null:
		var _blips: int = _text.tick_typewriter(delta)


func typing() -> bool:
	return _text != null and _text.typing()


## Put the rest of the block up at once -- the reveal, not the page.
##
## The briefing is up to `A0`'s full length at
## [constant BriefingText.TYPEWRITER_PER_FRAME] glyphs a frame, which is long
## enough that a player who has read it once is waiting rather than reading.
## A click or a key finishes it, and **the voice-over is untouched**: the host
## owns it under [constant SliceMain.VOICE_TAG] and stops it when the page is
## left, so the reading goes on over the finished text exactly as it would
## have over the typing one.
##
## Public rather than done inside [method _unhandled_input] because a suite
## builds this screen off the tree, where the engine routes no input at all.
func skip_typing() -> bool:
	if _text == null or not _text.typing():
		return false
	_text.finish_typewriter()
	return true


## A click or a key anywhere the buttons did not take.
##
## The buttons are `Control`s with `MOUSE_FILTER_STOP`, so a click on
## *Continue* while the text is still typing is that button's and reaches
## nothing here -- which is what should happen.
func _unhandled_input(event: InputEvent) -> void:
	var pressed: bool = false
	if event is InputEventKey:
		var key: InputEventKey = event
		pressed = key.is_pressed() and not key.is_echo()
	elif event is InputEventMouseButton:
		var button: InputEventMouseButton = event
		pressed = button.is_pressed()
	if pressed and skip_typing():
		get_viewport().set_input_as_handled()


## `0x0043E3C1 -> 0x00436EF0`: one `textbeep.wav` per word, at the GUI's own
## volume like the two clicks.
func _on_blip() -> void:
	if audio == null:
		return
	var _slot: int = audio.play_cue(BriefingText.blip_cue())


## **The one scrolling thing here that is not a list of rows**, and the reason
## it is wired at all: `scroll` had no caller in the whole project, so the six
## overlong `A0` blocks it exists for could not be read past the box.
func scrolls() -> bool:
	return _text != null


func step_rows(rows: int) -> void:
	scroll(float(rows))
