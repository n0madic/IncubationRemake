class_name CreditsScreen
extends CampaignScreen

## `Menu_a.lcl`'s `:Credits;` block on `Graphics/Credits.bmp`: two buttons,
## `Txtmod_a` 7 *Exit Game* at (450, 410) and 8 *Back* at (250, 410), both
## six tiles wide, and CD program `"8"` (`0x0044C050`). Reached after both
## endings -- the animated extro's 4000 ms hold and the static extro's
## *Continue* both raise the flag `0x0044BC60` writes -- and *Back* is the
## main menu (docs/92 section 7.19).
##
## **The plate is not the whole screen: the credits roll up its dark half.**
## `Menu_a.lcl` carries the two buttons and nothing else, so the roll used to
## be read as absent -- but `0x0044C050` also writes the scroll position
## `[0x0050FE1C] = 410` and the menu's draw loop `fcn.0044B5E0` calls
## `fcn.0044BD90` on every frame the window selector `[0x0050FDF8]` is 15
## (`0x0044B691`). That function walks `Txtmod_a` from string 161 until one
## reads *END* (339 in the shipped bank), prints each right-aligned at
## *x* 600, and decrements the position by one at the end of every frame.
## Its own first call is `fcn.0047F2E0(20, 20)` -- aLIB's frame-rate
## controller, which busy-waits on `GetTickCount` until `1000/20` ms have
## passed (`0x0047F359`) -- so the roll is **20 lines a second measured**, not
## a decision.
##
## Every line's first character is a code, read as a five-arm `switch` on
## `byte - '0'` (the jump table at `0x0044C03C`); the rest of the line is what
## is printed:
##
## | Code | Font | `cX`/`cA` | Rules | Advance |
## |---|---|---|---|---|
## | `0` title | 1 | `0xFFFF`/`0x632C` | two, at *y*+1 and *y*+3, `0x94B2` | 15 |
## | `1` heading | 1 | `0x94B2`/`0x3186` | one, at *y*+1, `0x632C` | 15 |
## | `2` name, last of its group | 0 | `0xFFFF`/`0x632C` | none | 30 |
## | `3` | -- | -- | none | 15 |
## | `4` name | 0 | `0xFFFF`/`0x632C` | none | 15 |
##
## The advance is the **printed line's** own code, so a `2` is what opens the
## gap before the next heading. A rule is `fcn.00463D80` case 0 -- a row of
## pixels running *left* from *x* 599 for exactly the width
## `aGetLibTextLength` measured, i.e. an underline under the line above it.
## The clip is `fcn.00447B20(0, 0, 640, 400)`, which is why the roll passes
## behind the buttons' row rather than over it, and nothing resets the
## position: the original's credits scroll away and do not come back.
##
## **These calls pass literal RGB565**, not the `cX`/`cA` ramp indices of
## `GUI_SetText` (docs/20 section 7.4) -- `0x632C` and `0x3186` are entries 3
## and 8 of the table `0x0043E680` resolves, written out. It is the one place
## the ramp's own values reach `aPrintLibText` directly; the UNVERIFIED note
## on [constant CampaignScreen.INK_TITLE] stands for the other screens, whose
## columns are indices. **Only `cX` is drawn**: the converted faces are one
## colour a glyph and `font_color` carries it, so the ramp's second entry --
## the `cA` column, which the engine writes for pixel value 2 -- is read,
## written down and not rendered. It is a divergence, not an omission.
##
## **The roll has a group the original does not**: [method own_lines] adds a
## heading and a name saying who made the remake, written in the roll's own
## grammar and taken from [method strings_own]. It is the only invented text
## on the screen. It sits **after the title and before the shipped bank** --
## the polite place is the end, and three minutes is longer than anyone
## watches.

const PLATE_CREDITS: String = "credits"
const ID_EXIT_GAME: int = 7
const ID_BACK_TO_MENU: int = 8
const EXIT_AT: Vector2 = Vector2(450.0, 410.0)
const BACK_AT: Vector2 = Vector2(250.0, 410.0)
## What the host hears.
const QUIT: String = "quit"
## **Namespaced, and it has to be.** The host routes every screen through one
## `match` on the action string, and this arm stands ahead of the `"back"` the
## Item List, the Recruit window and the Unit Menu share. Spelled `back` it
## shadowed all three: leaving the catalogue ran the credits' own arm, which
## is `_end_campaign()` -- the campaign dropped and the boot menu up, with the
## progress since the last save gone. The sibling screens' own verbs
## (`splash_done`, `sequence_done`, `fly_in_done`) are prefixed for the same
## reason; do not "simplify" this one back.
const BACK: String = "credits_back"

## The first string of the roll, `Txtmod_a` 161 -- *"0Credits"*.
const FIRST_LINE: int = 161
## The original's own terminator, and not a caption: `fcn.0044BD90` compares
## each line against `"END"` (`0x004C4868`) and stops the walk on a match. The
## shipped bank has it at 339.
const END_MARK: String = "END"
## How far past [constant FIRST_LINE] the walk may go before it gives up. The
## original has no bound -- it trusts the terminator -- and a bank without one
## would walk the whole catalogue here.
const LAST_LINE: int = 512

## The remake's own two strings, the tail of the roll.
const OWN_REMAKE: String = "credits.remake"
const OWN_REMAKE_BY: String = "credits.remake_by"

## `[0x0050FE1C]`, written at `0x0044C092`: where the first line starts.
const ROLL_START: float = 410.0
## `fcn.0047F2E0(20, 20)`'s frame rate, and the one-pixel step
## `dec dword [0x0050FE1C]` takes at `0x0044C026`.
const ROLL_FPS: float = 20.0
const ROLL_STEP: float = 1.0
## What the two above come to: plate units a second.
const ROLL_SPEED: float = ROLL_FPS * ROLL_STEP
## `fcn.00447B20(0, 0, 640, 400)` at `0x0044BDC4`.
const ROLL_CLIP: Rect2 = Rect2(0.0, 0.0, 640.0, 400.0)
## Where a printed line ends (`push 0x258` with `Format` 2) and where a rule
## starts before it runs left (`push 0x257`).
const TEXT_RIGHT: float = 600.0
const RULE_RIGHT: float = 599.0
## The two advances, `0x0044BFFD` and `0x0044C002`.
const ADVANCE_GROUP: float = 30.0
const ADVANCE_LINE: float = 15.0
## The rules' own rows, `lea esi, [edi + 1]` and `lea esi, [edi + 3]`.
const RULE_FIRST: float = 1.0
const RULE_SECOND: float = 3.0
const RULE_HEIGHT: float = 1.0
## How far the ramp fades either side of the engine's own row.
##
## **A quarter of a unit, not a half.** The engine leaves a whole unit of air
## between a rule and the cap height of the name under it -- a heading's box
## bottom is *y*, the rule is *y*+1..*y*+2 and the next line's capitals start
## at about *y*+3 -- and a half-unit fade eats half of that at both ends,
## which reads as the rule touching the first name of the group. A quarter
## still spreads the edge over a pixel at any window size, which is all the
## ramp is for.
const RULE_FADE: float = 0.25

## The five arms of the jump table at `0x0044C03C`, by the digit that reaches
## them.
const CODE_TITLE: int = 0
const CODE_HEADING: int = 1
const CODE_GROUP_END: int = 2
const CODE_SILENT: int = 3
const CODE_NAME: int = 4

## RGB565 as the three arms push it.
const INK_ROLL_TITLE: int = 0xFFFF
const RAMP_ROLL_TITLE: int = 0x632C
const INK_ROLL_HEADING: int = 0x94B2
const RAMP_ROLL_HEADING: int = 0x3186
const RULE_TITLE: int = 0x94B2
const RULE_HEADING: int = 0x632C

## How far the roll has travelled, in plate units. **It survives a rebuild**:
## [method build] runs again whenever the screen is redressed, and a roll that
## started over on each one would never reach its end.
var _travelled: float = 0.0

var _clip: Control = null
var _view: SubViewport = null
var _screen: TextureRect = null
var _roll: Control = null
## The lines the roll was built from, kept so a resize can lay them out again.
var _lines: PackedStringArray = PackedStringArray()
## The clip size the current layout was made for.
var _laid_out: Vector2 = Vector2.ZERO
## A plate unit in the viewport's own pixels, across and down.
var _across: float = 1.0
var _down: float = 1.0
var _ramp: ImageTexture = null
var _faces_smooth: Dictionary[int, FontFile] = {}
var _roll_height: float = 0.0


func plate_name() -> String:
	return PLATE_CREDITS


func build() -> void:
	_build_roll()
	var _exit: Button = gui_button(QUIT, BANK_MENU, ID_EXIT_GAME, EXIT_AT)
	var _back: Button = gui_button(BACK, BANK_MENU, ID_BACK_TO_MENU, BACK_AT)


## The shipped roll: `Txtmod_a` from [constant FIRST_LINE] until the bank's own
## [constant END_MARK], verbatim, codes and all.
##
## Kept apart from the drawing so a suite can pin the walk without a clock or
## a scene tree, the way [method SliceMain.boot_choice] is.
func shipped_lines() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for id: int in range(FIRST_LINE, LAST_LINE):
		var raw: String = label_for(BANK_MENU, id)
		if raw == END_MARK:
			break
		out.append(raw)
	return out


## The remake's own group, in the roll's own grammar -- a heading and a name,
## the name coded as a group end so the gap after it is the 30 the original
## opens in front of every heading.
##
## **The only invented text on this screen.** Everything else is the shipped
## bank; this says who made the remake, and it goes through
## [method strings_own] like every other string `game/` writes that the
## original never had to say (docs/92 section 7.6).
func own_lines() -> PackedStringArray:
	return PackedStringArray([
		"%d%s" % [CODE_HEADING, strings_own(OWN_REMAKE)],
		"%d%s" % [CODE_GROUP_END, strings_own(OWN_REMAKE_BY)],
	])


## The whole roll: the shipped bank with the remake's own group spliced in
## **after the title**.
##
## It used to be the tail, which is where a remake's own name politely
## belongs. The roll is three minutes long and nobody waits for the end of
## it, so it is the first group instead -- after `Txtmod_a` 161's *Credits*
## and the empty group end that follows it, both of which stay first because
## they are the screen's own heading.
func roll_lines() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var placed: bool = false
	for line: String in shipped_lines():
		out.append(line)
		if not placed and line.begins_with("%d" % CODE_GROUP_END):
			out.append_array(own_lines())
			placed = true
	if not placed:
		out.append_array(own_lines())
	return out


## One line of the roll as the engine's `switch` reads it: the code, what is
## printed, where the glyphs' **bottom** sits and what is drawn under it.
##
## Pure and static: *lines* are the bank's strings in order, and the answer is
## the whole layout, so what a suite checks is what the screen draws.
static func roll_layout(lines: PackedStringArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var y: float = 0.0
	for raw: String in lines:
		var code: int = -1
		if raw.length() > 0:
			code = raw.unicode_at(0) - "0".unicode_at(0)
		if code < CODE_TITLE or code > CODE_NAME:
			# The engine's `ja case.default` arm: nothing is printed and the
			# line still takes a step. A caption the catalogue could not
			# answer takes the name arm instead, so the suites' one gate over
			# [constant Localization.MISSING_PREFIX] can see it.
			if raw.begins_with(Localization.MISSING_PREFIX):
				out.append(_roll_entry(CODE_NAME, raw, y))
			y += ADVANCE_LINE
			continue
		if code != CODE_SILENT:
			out.append(_roll_entry(code, raw.substr(1), y))
		y += ADVANCE_GROUP if code == CODE_GROUP_END else ADVANCE_LINE
	return out


## How tall the whole roll is -- the last line's step included, which is what
## decides when the screen has nothing left to move.
static func roll_height(lines: PackedStringArray) -> float:
	var y: float = 0.0
	for raw: String in lines:
		var code: int = -1
		if raw.length() > 0:
			code = raw.unicode_at(0) - "0".unicode_at(0)
		y += ADVANCE_GROUP if code == CODE_GROUP_END else ADVANCE_LINE
	return y


static func _roll_entry(code: int, text: String, y: float) -> Dictionary:
	var entry: Dictionary = {"code": code, "text": text, "y": y}
	match code:
		CODE_TITLE:
			entry["font"] = FNT_VALUE
			entry["ink"] = INK_ROLL_TITLE
			entry["ramp"] = RAMP_ROLL_TITLE
			entry["rules"] = 2
			entry["rule_ink"] = RULE_TITLE
		CODE_HEADING:
			entry["font"] = FNT_VALUE
			entry["ink"] = INK_ROLL_HEADING
			entry["ramp"] = RAMP_ROLL_HEADING
			entry["rules"] = 1
			entry["rule_ink"] = RULE_HEADING
		_:
			entry["font"] = FNT_LABEL
			entry["ink"] = INK_ROLL_TITLE
			entry["ramp"] = RAMP_ROLL_TITLE
			entry["rules"] = 0
			entry["rule_ink"] = 0
	return entry


func _build_roll() -> void:
	if _clip != null:
		_clip.queue_free()
		_clip = null
		_view = null
		_roll = null
		_screen = null
	_lines = roll_lines()
	_roll_height = roll_height(_lines)
	set_process(false)
	if _roll_height <= 0.0:
		return
	# The clip is the original's own `fcn.00447B20` rectangle, so the roll
	# passes **behind** the buttons' row at 410 rather than over it.
	_clip = Control.new()
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.clip_contents = true
	place_on_plate(_clip, ROLL_CLIP.position, ROLL_CLIP.size)
	root().add_child(_clip)
	# **The roll is drawn into a viewport of its own and shown as a picture.**
	# Four passes of moving [Control]s about the canvas each traded one kind
	# of tremble for another, and the reason none of them could win is that
	# the canvas is not a pixel grid: the plate is stretched over whatever
	# window the player opened, so a plate unit is a fraction of a pixel and
	# every glyph, rule and box lands on its own sub-pixel offset, which then
	# *changes* as the roll moves. Rendered into a [SubViewport] the size of
	# the clip **in real pixels**, the roll has a grid: the lines are laid out
	# on whole pixels of it, the roll steps a whole pixel of it, and what
	# reaches the screen is one picture drawn in the same place every frame
	# with different contents. Nothing can shimmer against anything else,
	# because there is only one thing (docs/101 section 14).
	_view = SubViewport.new()
	_view.transparent_bg = true
	_view.disable_3d = true
	_view.gui_disable_input = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_view.size = Vector2i(1, 1)
	_clip.add_child(_view)
	_roll = Control.new()
	_roll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_roll.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_view.add_child(_roll)

	_screen = TextureRect.new()
	_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screen.stretch_mode = TextureRect.STRETCH_SCALE
	# **Without this the stretch does nothing.** A [TextureRect] keeps the
	# texture's own size by default and takes it as its minimum, so the
	# viewport's picture was drawn at 2134x1112 in the top-left corner of a
	# 768x400 clip: the roll was rendering perfectly and every right-aligned
	# line sat off the edge of it.
	_screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# The picture is drawn at the size it was rendered, so this is a copy
	# rather than a resampling; linear rather than nearest because a viewport
	# whose size did not divide evenly would alias hard under nearest and only
	# softens under this.
	_screen.texture_filter = Control.TEXTURE_FILTER_LINEAR
	_clip.add_child(_screen)
	set_process(true)


## How many real pixels one canvas pixel is drawn as.
##
## The window's own pixel is not it: a display with a backing store renders a
## 768x480 viewport into a 2134x1334 target, and the roll's grid has to be the
## target's. One when there is nothing to measure.
func _render_scale() -> float:
	var view: Viewport = get_viewport()
	if view == null:
		return 1.0
	var units: float = view.get_visible_rect().size.y
	var target: ViewportTexture = view.get_texture()
	if target == null or units <= 0.0:
		return 1.0
	var pixels: float = float(target.get_size().y)
	if pixels <= 0.0:
		return 1.0
	return pixels / units


## Size the viewport to the clip and lay every line out on its pixels.
##
## Run again whenever the clip's size changes -- a window resize moves the
## grid, and a layout kept from the old one would be soft.
func _relayout() -> void:
	if _clip == null or _view == null or _roll == null:
		return
	var box: Vector2 = _clip.size
	if box.x <= 0.0 or box.y <= 0.0:
		return
	var render: float = _render_scale()
	_view.size = Vector2i(int(roundf(box.x * render)),
		int(roundf(box.y * render)))
	# A plate unit in the viewport's own pixels, across and down. The plate is
	# stretched horizontally and not vertically, so the two differ.
	_across = float(_view.size.x) / PLATE_SIZE.x
	_down = float(_view.size.y) / ROLL_CLIP.size.y
	_roll.size = Vector2(float(_view.size.x), _roll_height * _down)
	clear_children(_roll)
	for entry: Dictionary in roll_layout(_lines):
		_draw_line(entry)
	_screen.texture = _view.get_texture()
	_laid_out = box
	_place_roll()


## One printed line, right-aligned on [constant TEXT_RIGHT] with its rules
## hung off its own box so they keep the width the face actually drew.
func _draw_line(entry: Dictionary) -> void:
	# **Read back with assignments, not casts.** A `Dictionary` value is a
	# `Variant`, and this project compiles with warnings as errors: `int(...)`
	# over one is `UNSAFE_CALL_ARGUMENT` and does not load. An assignment into
	# a typed local is checked at run time and is the pattern the rest of the
	# tree uses.
	var text: String = entry["text"]
	var fnt: int = entry["font"]
	var ink_565: int = entry["ink"]
	var y: float = entry["y"]
	var rules: int = entry["rules"]
	var rule_565: int = entry["rule_ink"]
	var line: Label = Label.new()
	line.text = text
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# `aPrintLibText`'s *y* is the glyphs' bottom (docs/43 section 5.3), which
	# is what puts a rule at *y*+1 **under** the line rather than through it.
	line.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	line.add_theme_color_override("font_color", UnitPanel.rgb565(ink_565))
	_dress(line, fnt)
	# **The box is dropped by the face's descent.** Bottom alignment puts the
	# text *block*'s bottom on the box's, and a block is ascent **plus
	# descent** -- so a box ending at *y* leaves the ink ending a descent
	# above it, and every rule hung off the box lands that much too low. It
	# measured 3.8 units of air above the rule and 0.6 below, where the engine
	# leaves 1 and 3. Taking the block's own height less its ascent instead
	# looks more principled and is wrong: a [Label]'s block is padded by the
	# theme's line spacing, so that reading came out five units too large and
	# put the rule through the heading.
	var drop: float = _descent(fnt)
	line.position = Vector2(0.0, roundf((y - ADVANCE_LINE + drop) * _down))
	line.size = Vector2(TEXT_RIGHT * _across, roundf(ADVANCE_LINE * _down))
	_roll.add_child(line)
	if rules <= 0:
		return
	# The width is the one the face draws, measured after the override the way
	# `aGetLibTextLength` measures the string it is about to print.
	var width: float = line.get_minimum_size().x
	var ink: Color = UnitPanel.rgb565(rule_565)
	_rule(line, width, ink, RULE_FIRST - drop)
	if rules > 1:
		_rule(line, width, ink, RULE_SECOND - drop)


## Give *line* the face it prints in, at the size the viewport's grid asks for.
##
## The shipped bitmap faces and the readable one are both scaled by the render
## factor, because the viewport is that much bigger than the plate: a face
## left at its own size would come out a third of the height it should be.
## Hinting is off on the readable one -- a hinted face snaps its stems to the
## pixel grid and re-rasterises into a slightly different shape at every size
## and offset, which reads as boiling on text that moves.
func _dress(line: Label, fnt: int) -> void:
	var chosen: FontFile = face(fnt)
	var base: float = float(readable_size(fnt))
	if chosen != null:
		base = float(chosen.fixed_size)
		line.add_theme_font_override("font", chosen)
	else:
		var smooth: FontFile = _smooth_face(fnt)
		if smooth != null:
			line.add_theme_font_override("font", smooth)
	line.add_theme_font_size_override("font_size",
		maxi(int(roundf(base * _down)), 1))


## One row of pixels running left from [constant RULE_RIGHT], *below* by
## `below` -- `fcn.00463D80`'s case 0, whose loop steps *x* down from its
## argument for the measured length.
##
## **Drawn through a filtered ramp rather than as a hard rectangle.** The
## original's bar is one pixel of a 640x480 frame buffer; in the roll's own
## viewport it is the render factor's worth of them, which is not a whole
## number. A four-row alpha ramp under [constant
## Control.TEXTURE_FILTER_LINEAR] has continuous coverage, so the bar's edge
## fades instead of gaining and losing a row.
func _rule(line: Label, width: float, ink: Color, below: float) -> void:
	var rule: TextureRect = TextureRect.new()
	rule.texture = _rule_ramp()
	rule.stretch_mode = TextureRect.STRETCH_SCALE
	rule.texture_filter = Control.TEXTURE_FILTER_LINEAR
	rule.modulate = ink
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	rule.offset_right = (RULE_RIGHT - TEXT_RIGHT) * _across
	rule.offset_left = rule.offset_right - width
	# Centred on the row the engine fills, which is `below`..`below + 1`.
	rule.offset_top = (below - RULE_FADE) * _down
	rule.offset_bottom = (below + RULE_HEIGHT + RULE_FADE) * _down
	line.add_child(rule)


## How far the face hangs below its own baseline, in plate units.
##
## Zero for the shipped bitmap faces: `fixed_size` *is* the distance the
## glyphs rise above the anchor and nothing is drawn under it (docs/60), which
## is the convention `aPrintLibText` prints in.
func _descent(fnt: int) -> float:
	var chosen: FontFile = face(fnt)
	if chosen != null:
		return chosen.get_descent(chosen.fixed_size)
	var fallback: Font = ThemeDB.fallback_font
	if fallback == null:
		return 0.0
	return fallback.get_descent(readable_size(fnt))


func _smooth_face(fnt: int) -> FontFile:
	if _faces_smooth.has(fnt):
		return _faces_smooth[fnt]
	var made: FontFile = null
	var fallback: Font = ThemeDB.fallback_font
	if fallback is FontFile:
		var source: FontFile = fallback
		made = source.duplicate()
		made.hinting = TextServer.HINTING_NONE
		made.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	_faces_smooth[fnt] = made
	return made


## The ramp itself -- four rows, `0`, `1`, `1`, `0` in alpha, built once per
## screen. **Not a `static var`**: one of those keeps its whole dependency
## tree loaded for the life of the process, which the exported build reports
## as leaked resources (docs/92 section 7.19).
func _rule_ramp() -> ImageTexture:
	if _ramp != null:
		return _ramp
	var image: Image = Image.create_empty(1, 4, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(1.0, 1.0, 1.0, 0.0))
	image.set_pixel(0, 1, Color(1.0, 1.0, 1.0, 1.0))
	image.set_pixel(0, 2, Color(1.0, 1.0, 1.0, 1.0))
	image.set_pixel(0, 3, Color(1.0, 1.0, 1.0, 0.0))
	_ramp = ImageTexture.create_from_image(image)
	return _ramp


## Where the roll stands now, on the viewport's own pixel grid.
func _place_roll() -> void:
	if _roll == null:
		return
	_roll.position = Vector2(0.0, roundf(roll_top() * _down))


## The plate-space *y* of the roll's first line, for a suite or the agent.
##
## Continuous here and rounded where it is used: what has to land on a whole
## pixel is the roll's position **in its own viewport**, and that is the one
## rounding in the screen. Four earlier passes rounded this instead -- to a
## window pixel, to a canvas pixel, to the quarter a text server places glyphs
## on -- and each of them traded the underlines' flicker for a shudder under
## the names, because the canvas has no grid to round to.
func roll_top() -> float:
	return ROLL_START - _travelled


func _process(delta: float) -> void:
	if _clip != null and _clip.size != _laid_out:
		_relayout()
	_travelled += ROLL_SPEED * delta
	# Nothing brings it back: the original decrements forever and the last
	# line leaves the top of the clip for good.
	if roll_top() + _roll_height < ROLL_CLIP.position.y:
		set_process(false)
		return
	_place_roll()
