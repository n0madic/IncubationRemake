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
var _roll: Control = null
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
	if _roll != null:
		_roll.get_parent().queue_free()
		_roll = null
	var lines: PackedStringArray = roll_lines()
	_roll_height = roll_height(lines)
	set_process(false)
	if _roll_height <= 0.0:
		return
	# The clip is the original's own `fcn.00447B20` rectangle, so the roll
	# passes **behind** the buttons' row at 410 rather than over it.
	var clip: Control = Control.new()
	_clip = clip
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.clip_contents = true
	place_on_plate(clip, ROLL_CLIP.position, ROLL_CLIP.size)
	root().add_child(clip)
	_roll = Control.new()
	_roll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# **The roll is positioned, not anchored.** An anchor is a fraction of the
	# parent, so the roll's own *y* went through a divide and a multiply in
	# 32-bit float on the way to a pixel -- and the rounding error of that
	# round trip changes with the value. Every line inherits it, so a line
	# whose position happened to sit near the half-pixel rounded up on one
	# step and down on the next while its neighbours did not: **some** names
	# twitched and the rest were still. Written straight, the roll's *y* is
	# exact, each line's offset inside it is constant, and every line rounds
	# the same way on every frame.
	_roll.set_anchors_preset(Control.PRESET_TOP_LEFT)
	clip.add_child(_roll)
	for entry: Dictionary in roll_layout(lines):
		_draw_line(entry)
	_place_roll()
	set_process(true)


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
	var line: Label = make_label(text, 0, fnt)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# `aPrintLibText`'s *y* is the glyphs' bottom (docs/43 section 5.3), which
	# is what puts a rule at *y*+1 **under** the line rather than through it.
	line.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	line.add_theme_color_override("font_color", UnitPanel.rgb565(ink_565))
	_smooth(line, fnt)
	# **The box is dropped by the face's descent.** Bottom alignment puts the
	# text *block*'s bottom on the box's, and a block is ascent **plus
	# descent** -- so a box ending at *y* leaves the ink ending a descent
	# above it, and every rule hung off the box lands that much too low. It
	# measured 3.8 units of air above the rule and 0.6 below, where the engine
	# leaves 1 and 3: the readable face's descent is nearly three units and it
	# was pushing each rule down onto the first name of the group. A shipped
	# bitmap face is all ascent and drops by nothing, which is why this never
	# showed up in the faces the rest of the plate uses.
	#
	# The drop is the face's **declared descent**. Taking the block's own
	# height less its ascent instead looks more principled and is wrong: a
	# [Label]'s block is padded by the theme's line spacing, so that reading
	# came out five units too large and put the rule through the heading.
	var drop: float = _descent(fnt)
	_anchor(line, Vector2(0.0, y - ADVANCE_LINE + drop),
		Vector2(TEXT_RIGHT, ADVANCE_LINE), Vector2(PLATE_SIZE.x, _roll_height))
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


## One row of pixels running left from [constant RULE_RIGHT], *below* by
## `below` -- `fcn.00463D80`'s case 0, whose loop steps *x* down from its
## argument for the measured length.
##
## **Drawn through a filtered ramp rather than as a hard rectangle.** The
## original's bar is one pixel of a 640x480 frame buffer; here a plate unit is
## not a whole pixel -- at 1280x800 it is five thirds of one -- so a hard
## rectangle covers two pixel rows at one sub-pixel offset and one at the
## next, and the two rules under every heading blink their way up the screen
## as the roll moves. A four-row alpha ramp under [constant
## Control.TEXTURE_FILTER_LINEAR] has **continuous** coverage instead: the
## solid middle half is the engine's own one-unit bar and the half unit either
## side of it fades, so a fraction of a pixel of movement changes the picture
## by a fraction of its brightness rather than by a whole row.
func _rule(line: Label, width: float, ink: Color, below: float) -> void:
	var rule: TextureRect = TextureRect.new()
	rule.texture = _rule_ramp()
	rule.stretch_mode = TextureRect.STRETCH_SCALE
	rule.texture_filter = Control.TEXTURE_FILTER_LINEAR
	rule.modulate = ink
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	rule.offset_right = RULE_RIGHT - TEXT_RIGHT
	rule.offset_left = rule.offset_right - width
	# Centred on the row the engine fills, which is `below`..`below + 1`.
	rule.offset_top = below - RULE_FADE
	rule.offset_bottom = below + RULE_HEIGHT + RULE_FADE
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


## Draw *line* in a face that does not change shape as it moves.
##
## **Hinting is what makes scrolling text shimmer.** A hinted face snaps its
## stems to the pixel grid, so a glyph is re-rasterised into a slightly
## different shape at every sub-pixel offset and a moving line appears to
## boil. The readable face is Godot's own fallback, whose hinting cannot be
## turned off in place, so the roll takes a copy of it with hinting off and
## quarter-pixel positioning on. The shipped bitmap faces are images and have
## neither, so they are left alone.
func _smooth(line: Label, fnt: int) -> void:
	if face(fnt) != null:
		return
	var smooth: FontFile = _smooth_face(fnt)
	if smooth == null:
		return
	line.add_theme_font_override("font", smooth)
	line.add_theme_font_size_override("font_size", readable_size(fnt))


func _smooth_face(fnt: int) -> FontFile:
	if _faces_smooth.has(fnt):
		return _faces_smooth[fnt]
	var made: FontFile = null
	var fallback: Font = ThemeDB.fallback_font
	if fallback is FontFile:
		var source: FontFile = fallback
		made = source.duplicate()
		made.hinting = TextServer.HINTING_NONE
		# **Sub-pixel positioning is off, and that is the point.** With it on
		# a glyph is placed on a quarter-pixel grid while the rule beside it
		# is drawn wherever it is asked, so the two move by different amounts
		# and the names tremble against the line above them. Off, a glyph
		# lands on a whole canvas pixel -- which is exactly where
		# [method roll_top] puts the roll, so the placement is a no-op and
		# text and rule move as one picture.
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


## Anchors in the plate's own units, against a box of *space* units -- the
## sibling of [method place_on_plate], which measures against the plate
## itself. The roll is neither 640x480 nor a fixed pixel count: it is as tall
## as its own lines and it moves, so its children carry fractions of it.
static func _anchor(control: Control, at: Vector2, size: Vector2,
		space: Vector2) -> void:
	control.anchor_left = at.x / space.x
	control.anchor_top = at.y / space.y
	control.anchor_right = (at.x + size.x) / space.x
	control.anchor_bottom = (at.y + size.y) / space.y
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0


## Where the roll stands now, in the clip's own units.
func _place_roll() -> void:
	if _roll == null:
		return
	# The clip is the plate's own rectangle, so its height *is* the roll's
	# unit; before the first layout pass there is none and the plate's own
	# figures stand in.
	var across: float = PLATE_SIZE.x
	var down: float = 1.0
	if _clip != null and _clip.size.y > 0.0:
		across = _clip.size.x
		down = _clip.size.y / ROLL_CLIP.size.y
	_roll.size = Vector2(across, _roll_height * down)
	_roll.position = Vector2(0.0, roll_top() * down)


## The plate-space *y* of the roll's first line, for a suite or the agent.
##
## **Stepped by one canvas pixel**, which is the original's own step
## (`dec dword [0x0050FE1C]` into a 640x480 frame buffer) and, at a viewport
## 480 units tall, one plate unit -- so the roll advances twenty times a
## second exactly as it does there.
##
## Left continuous, the roll shimmers, and not evenly: a glyph is placed on
## the grid its face allows while the rule under a heading is a rectangle
## drawn wherever it is asked, so the two move by different amounts and the
## first name of every group trembles against the line above it. The step and
## [method _smooth_face]'s disabled sub-pixel positioning are one answer, not
## two: on this grid the text server's own rounding is a no-op, so what moves
## is one picture rather than a picture and a rule.
func roll_top() -> float:
	var step: float = _pixel_step()
	if step <= 0.0:
		return ROLL_START - _travelled
	return ROLL_START - floorf(_travelled / step) * step


## One **canvas** pixel, in plate units -- the grid a face with no sub-pixel
## positioning lands its glyphs on.
##
## Measured rather than assumed to be 1: the plate is stretched over the whole
## viewport, and a viewport is 480 units tall only while the window is at
## least four units wide to three. Zero when there is no viewport to measure,
## which is the case in a suite: the layout is then exact and unquantised,
## which is what a suite compares against.
##
## **Not the rendered pixel.** The render target is larger again on a display
## with a backing store -- 2134x1334 for this 768x480 viewport -- and stepping
## by one of *those* moves the roll a fraction of the grid the glyphs are on,
## which is the shimmer this is here to remove. Both were tried.
func _pixel_step() -> float:
	var view: Viewport = get_viewport()
	if view == null:
		return 0.0
	var units: float = view.get_visible_rect().size.y
	if units <= 0.0:
		return 0.0
	return PLATE_SIZE.y / units


func _process(delta: float) -> void:
	_travelled += ROLL_SPEED * delta
	# Nothing brings it back: the original decrements forever and the last
	# line leaves the top of the clip for good.
	if roll_top() + _roll_height < ROLL_CLIP.position.y:
		set_process(false)
		return
	_place_roll()
