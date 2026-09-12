class_name MissionHud
extends CanvasLayer

## The battle interface -- the plate, the button columns, the unit panel, the
## command pad, the radar, the turn counter, the hint line, the direction
## ring and the debriefing panel. docs/43.
##
## **It reads the world and never writes it.** Every widget is rebuilt from
## `World.unit_view`, `World.turn` and the availability callables [SliceMain]
## hands over on each [method refresh]; a button raises a signal and the host
## decides what it means. Nothing on screen is the source of a selection, a
## position or a turn number.
##
## The layout is the plate's own 640x480 with the extra canvas given to the 3D
## window ([PlateLayout], [method HudTables.window_for]); every widget is
## anchored to the piece of the plate it stands on, so a wider or taller
## window moves the pieces apart and leaves each one the size it was drawn.

## A column button raised one of the sixteen interface events.
signal event(number: int)
## A pad socket raised one of the six commands.
signal command(number: int)
## The pointer moved onto a lit column slot / pad socket (the two hover
## ticks of docs/28 section 2.5).
signal column_hovered
signal pad_hovered
## The radar's scale changed.
signal radar_rescaled(fields: int)

## Below [constant CampaignScreen.SCREEN_LAYER], so a campaign screen or the
## shell covers the interface as it covers the mission.
const HUD_LAYER: int = 7
## docs/10 section 5.7 -- the alien side, whose name is not a number.
const PLAYER_COMPUTER: int = 255
## The player the report is written for. One squad, one seat.
const PLAYER_HUMAN: int = 0
## What the map is dimmed to behind the report.
const DIM_COLOUR: Color = Color(0.0, 0.0, 0.0, 0.72)
## The readable face's report size, in the plate's units.
const READABLE_REPORT_SIZE: int = 16
## The face the interface is written in. **One, and it is `font_0`** (docs/43
## D7, closed 2026-09-12): the turn text and the hint caption are written
## with `aGetFont(0)` (`0x0041B212`, `0x0041B5A4`), and the unit panel's
## numbers with the handle `aInitUI` is passed -- `aGetFont(ebx)` with `ebx`
## zero throughout `aInitBattleGround`, stored at `[0x00516328]` and pushed
## twice into `0x004756D0`. The panel used to be set in `font_3`, "the only
## shipped face that fits its rows", on a reading that had not traced the
## handle; the rows were laid out for `font_0`'s 10 px digits and fit them.
## Two names stay because the readable fallback sizes differ (see
## [UnitPanel]).
const TEXT_FONT: String = "font_0"
const SMALL_FONT: String = "font_0"
## The turn counter's colours (`0x0041B1D1`).
const COLOUR_TURN: int = 0xFFFF
const COLOUR_TURN_LATE: int = 0xF800
## The info box's own frame: a dark ground with a thin border, so the text is
## legible over whatever the 3D window is showing under it. The original draws
## the block straight onto the rendered frame with `aPrintGUITextBox`'s own
## ramps and no ground at all; a deliberate divergence, for the same reason
## [method BriefingText.to_bbcode] wraps by Godot's rules and not by 1997's.
const INFO_GROUND: Color = Color(0.04, 0.05, 0.04, 0.88)
const INFO_BORDER: Color = Color(0.36, 0.44, 0.36, 1.0)
const INFO_BORDER_WIDTH: int = 1
const INFO_PADDING: float = 6.0
## The readable face's size for the info box when the shipped faces are not in
## use -- the same decision [method use_font] makes for the report.
##
## **Between the briefing's and the report's.** The box is 180 plate units
## wide (docs/24 section 7.2) and stands over the mission, so a size that
## suits the shell's full-width paragraphs leaves four words on a line here;
## the original's own face is an 8 px bitmap. [constant
## BriefingText.READABLE_SIZE] is 10 and the report's is 16.
const INFO_READABLE_SIZE: int = 11
## How close to the bottom edge the box may run before its height is trimmed.
const INFO_BOTTOM_MARGIN: float = 8.0
## What a heading does to the box, read off the mode-2 arm at `0x0043ED87`:
## the frame is drawn at `(x - 6, y - 24)`, `w + 6` wide and the measured text
## height plus 20 (`[0x0050B4B8] + 0x14`) tall, and the name goes at
## `(x, y - 8)` -- so it is **one** box with room made above the text rather
## than a bar of its own. `0x0043ED4C` compares the stored title with the empty
## string at `0x004FA524` and draws none of it when they match, which is every
## box but the magnifier's.
const INFO_TITLE_OFFSET: Vector2 = Vector2(-6.0, -24.0)
const INFO_TITLE_EXTRA_WIDTH: float = 6.0
## How long the message stands before it takes itself down. A deliberate
## divergence, like [constant INFO_GROUND] beside it: the original holds the
## whole mission until the right button is pressed (docs/24 section 7.2) and a
## crate opened by mistake therefore stops the game until it is noticed. The
## dismissal stays, and this is the floor under it.
const INFO_AUTO_HIDE_SECONDS: float = 5.0
## The readable face's size for the band texts when the cache has no fonts,
## or when the player chose the readable interface font. The hint has one of
## its own: it is a caption for the button under the pointer, not a number
## the game is played by, and at the turn counter's size it read as loudly as
## the turn did.
const FALLBACK_TEXT_SIZE: int = 13
const HINT_FALLBACK_SIZE: int = 9

var plate: PlateLayout = null
var columns: ButtonColumns = null
var pad: CommandPad = null
var panel: UnitPanel = null
var radar: Radar = null
var ring: DirectionRing = null
var progress: TurnProgress = null
## Whether the last [method refresh] moved the bar. The interface makes no
## sound of its own -- it says what happened and the caller decides -- so this
## is read back rather than played here.
var _progress_stepped: bool = false

var _root: Control = null
var _turn: Label = null
var _hint: Label = null
var _result: Control = null
var _report: Label = null
## The pickup message of docs/24 section 7.2 -- see [method show_info].
var _info: PanelContainer = null
var _info_text: BriefingText = null
## The heading over the box: the subject's own name, which only the magnifier's
## page has ([method show_info]). It stands inside the same frame, above the
## text, which is where `0x0043ED87` makes room for it.
var _info_title_text: BriefingText = null
## What holds the mission while the message is up: a full-rect [Control] with
## [constant Control.MOUSE_FILTER_STOP], added last so it picks in front of
## every widget on the plate. See [method show_info].
var _info_shield: Control = null
## The spans the box is showing, so [method view] can report it and
## [method use_font] can put it back after a face change.
var _info_spans: Array = []
## The heading's, the same way.
var _info_title_spans: Array = []
## How long the message has been up, counted by [method tick_info]. It is
## reset by [method show_info] and never runs while the box is down, so one
## message cannot inherit the seconds another was read for.
var _info_clock: float = 0.0
## The height bound the open box was raised with: the pickup's 400 or the
## magnifier's 300 (`0x00432B3D`), both of which the canvas may cut short.
var _info_height: float = InfoText.BOX_SIZE.y
## Whether the open box takes itself down on its own. A page the player asked
## for does not -- see [method show_info].
var _info_auto_hide: bool = true
var _cache_dir: String = ""
## The caption shown for the button under the pointer.
var _hint_button: String = ""
var _strings: Localization = null
var _art: Art = null
var _font: FontFile = null
var _text_font: FontFile = null
var _small_font: FontFile = null


## Build the interface. *font* is the interface font setting (the 17 px face
## or null for the readable one); *text_font* and *small_font* the two plate
## faces, which a cache without fonts leaves null.
func setup(art: Art, strings: Localization, font: FontFile,
		text_font: FontFile, small_font: FontFile,
		cache_dir: String = "") -> void:
	_art = art
	_cache_dir = cache_dir
	_strings = strings
	_font = font
	_text_font = text_font
	_small_font = small_font
	layer = HUD_LAYER
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	plate = PlateLayout.new()
	plate.name = "Plate"
	_root.add_child(plate)
	plate.build(art)

	_turn = Label.new()
	_turn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_turn.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_turn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_root.add_child(_turn)
	_hint = Label.new()
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_hint)

	columns = ButtonColumns.new()
	columns.name = "Columns"
	_root.add_child(columns)
	columns.setup(art, strings)
	columns.event.connect(func(number: int) -> void: event.emit(number))
	columns.hint.connect(set_hint)
	columns.hovered.connect(func() -> void: column_hovered.emit())

	pad = CommandPad.new()
	pad.name = "Pad"
	_root.add_child(pad)
	pad.setup(art, strings)
	pad.command.connect(func(number: int) -> void: command.emit(number))
	pad.hint.connect(set_hint)
	pad.hovered.connect(func() -> void: pad_hovered.emit())

	panel = UnitPanel.new()
	panel.name = "Panel"
	_root.add_child(panel)
	panel.setup(art, strings, _band_font(), _panel_font())
	# The remake names the shipped inventory pictures with local tooltips; the
	# catalogue supplies the original game's own equipment names.
	var catalogue: Array = []
	if _cache_dir != "":
		catalogue = DictRead.as_array(CacheLoader.read_json(
			_cache_dir + "/tables/balance.json").get("equipment", []))
	panel.use_equipment_names(catalogue)

	radar = Radar.new()
	radar.name = "Radar"
	_root.add_child(radar)
	radar.setup(art)
	radar.rescaled.connect(func(fields: int) -> void: radar_rescaled.emit(fields))

	ring = DirectionRing.new()
	ring.name = "Ring"
	_root.add_child(ring)

	progress = TurnProgress.new()
	progress.name = "Progress"
	_root.add_child(progress)
	progress.setup(art)

	_result = Control.new()
	_result.set_anchors_preset(Control.PRESET_FULL_RECT)
	_result.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dim: ColorRect = ColorRect.new()
	dim.color = DIM_COLOUR
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result.add_child(dim)
	_report = Label.new()
	_report.set_anchors_preset(Control.PRESET_CENTER)
	_report.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_report.grow_vertical = Control.GROW_DIRECTION_BOTH
	_report.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result.add_child(_report)
	_result.visible = false
	_root.add_child(_result)

	# The pickup message. It is built here, with the rest of the interface,
	# rather than on first use: `aActivateInfo` writes into a text box the
	# module already owns (box 2, `0x0043ECE0`), and a widget made mid-command
	# would be one more thing that can fail while a crate is being opened.
	_info_shield = Control.new()
	_info_shield.name = "InfoShield"
	_info_shield.set_anchors_preset(Control.PRESET_FULL_RECT)
	# **The whole screen, not the box.** `0x0041BB44` returns from the
	# mission's input handler while a text box is up, and the interface's own
	# mouse hit test `0x00450F10` sits *past* that return (`0x0041BB5F`) --
	# so a click on a button of the plate does nothing either. In Godot a
	# `Control` answers before `_unhandled_input` does, so the plate's widgets
	# would have gone on working behind the message; this is what stops them,
	# and it is also what takes the message down.
	_info_shield.mouse_filter = Control.MOUSE_FILTER_STOP
	_info_shield.visible = false
	_info_shield.gui_input.connect(_on_info_input)
	_info = PanelContainer.new()
	_info.name = "Info"
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_theme_stylebox_override("panel", _info_style())
	_info_text = BriefingText.create(cache_dir, font != null)
	_info_text.fit_content = true
	_info_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_text.scroll_active = false
	_info_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_title_text = BriefingText.create(cache_dir, font != null)
	_info_title_text.fit_content = true
	_info_title_text.scroll_active = false
	_info_title_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_title_text.visible = false
	var stack: VBoxContainer = VBoxContainer.new()
	stack.name = "InfoStack"
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_info_title_text)
	stack.add_child(_info_text)
	_info.add_child(stack)
	_info_shield.add_child(_info)
	_root.add_child(_info_shield)
	use_font(font)
	_root.resized.connect(_layout)
	_layout()


## The interface font setting changed -- and it changes **this screen too**.
##
## The plate's own two faces used to stay whatever the setting said, on the
## reading that the readable option was about the wrapped paragraphs of the
## shell and the report and that the interface's rows are the size the shipped
## faces are. The consequence was that the one screen the game is played on
## was the one screen the setting did not reach: the hint line, the turn and
## the whole unit panel stayed in `font_0` while every plate around
## them was antialiased. The setting is the interface's, so it is the
## interface's here as well; a null *font* means the readable face and
## [method _band_font] and [method _panel_font] answer null with it, which is
## what makes a [Label] fall back to Godot's own at the row's own height.
func use_font(font: FontFile) -> void:
	_font = font
	_apply_font(_turn, _band_font())
	_apply_font(_hint, _band_font(), HINT_FALLBACK_SIZE)
	if font == null:
		_report.remove_theme_font_override("font")
		_report.add_theme_font_size_override("font_size", READABLE_REPORT_SIZE)
	else:
		_apply_font(_report, font)
	if _info_text != null:
		# The box follows the same setting the rest of the interface does: a
		# readable interface with an 8 px bitmap message in the middle of it
		# is the mismatch docs/24's own note about the briefing describes.
		_info_text.use_game_font(_cache_dir, font != null, INFO_READABLE_SIZE)
	if _info_title_text != null:
		_info_title_text.use_game_font(_cache_dir, font != null,
			INFO_READABLE_SIZE)
	if panel != null:
		panel.use_font(_band_font(), _panel_font())
	_layout()


func _band_font() -> FontFile:
	if _font == null:
		return null
	return _text_font if _text_font != null else _font


func _panel_font() -> FontFile:
	if _font == null:
		return null
	return _small_font if _small_font != null else _band_font()


static func _apply_font(label: Label, font: FontFile,
		fallback_size: int = FALLBACK_TEXT_SIZE) -> void:
	if label == null:
		return
	if font == null:
		label.remove_theme_font_override("font")
		# **The size is kept, not dropped.** Godot's default is 16 px and the
		# rows this line sits in are 13; letting it fall all the way back put
		# the hint through the groove above it.
		label.add_theme_font_size_override("font_size", fallback_size)
		return
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font.fixed_size)


## The canvas, in the plate's units: 640x480 on 4:3 and more elsewhere.
func canvas_size() -> Vector2:
	if _root != null and _root.size.x > 0.0 and _root.size.y > 0.0:
		return _root.size
	if is_inside_tree():
		return get_viewport().get_visible_rect().size
	return Vector2(HudTables.PLATE_SIZE)


## The 3D window on this canvas.
func window() -> Rect2:
	return HudTables.window_for(canvas_size())


## Where the developer status line may start without covering the top band.
func bottom() -> float:
	return float(HudTables.WINDOW.position.y)


func _layout() -> void:
	var canvas: Vector2 = canvas_size()
	# `aPrintLibText`'s y is the glyphs' bottom (docs/43 section 5.3), so the
	# turn at (560, 22) and the hint at (60, 22) both end on the groove's
	# row 22 and start one font height above it.
	var band_font: FontFile = _band_font()
	var height: float = float(band_font.fixed_size) if band_font != null \
		else float(FALLBACK_TEXT_SIZE)
	var turn_at: Vector2 = PlateLayout.anchored(Vector2(HudTables.TURN_TEXT_AT),
		canvas, "top_right")
	_turn.position = Vector2(turn_at.x - _turn.size.x, turn_at.y - height)
	# The hint sits on the same row 22 and is the smaller of the two, so its
	# own height is what its baseline is measured from.
	var hint_height: float = float(band_font.fixed_size) if band_font != null \
		else float(HINT_FALLBACK_SIZE)
	_hint.position = Vector2(float(HudTables.CAPTION_AT.x),
		float(HudTables.CAPTION_AT.y) - hint_height)
	_layout_info()


## Redraw everything from the world.
##
## *event_available* answers `(event) -> bool` and *command_available*
## `(command) -> bool`; *north* and *east* are the radar's camera directions;
## *bands* the selection's target overlay; *magnifier* whether event 13's
## mode is on.
##
## *watching* is empty while the seat is the player's own, and otherwise carries
## the watched side's `acted` and `live` counts. It is the whole of docs/43
## section 8: the original swaps this screen for the bare plate and one bar, so
## the four widgets that carry the player's own state go with it.
func refresh(world: World, selected: int, event_available: Callable,
		command_available: Callable, north: Vector2, east: Vector2,
		bands: Dictionary[Vector2i, int], magnifier: bool,
		watching: Dictionary = {}, held: bool = false) -> void:
	var watched: bool = not watching.is_empty()
	columns.refresh(event_available, magnifier)
	pad.refresh(command_available)
	panel.refresh(world, -1 if watched else selected)
	var player: int = world.turn.current_player if world != null else -1
	radar.refresh(world, selected, north, east, bands, player)
	columns.visible = not watched
	pad.visible = not watched
	radar.visible = not watched
	# The turn goes with them: it is printed into the top strip by the
	# interface's own redraw, and the watcher paints that strip back from the
	# bare plate before anything else (docs/43 section 7).
	_turn.visible = not watched
	if watched:
		_progress_stepped = progress.refresh(
			DictRead.as_int(watching.get("acted", 0)),
			DictRead.as_int(watching.get("live", 0)))
	else:
		_progress_stepped = progress.refresh(0, 0)
	_show_turn(world)
	_show_result(world, held)
	_layout()


## The hint line at (60, 22): a button's caption while the pointer is on it.
##
func set_hint(text: String) -> void:
	_hint_button = text
	_show_hint()


func _show_hint() -> void:
	_hint.text = _hint_button
	_hint.visible = _hint_button != ""


func hint_text() -> String:
	return _hint.text if _hint.visible else ""


## `0x0041B13F`..`0x0041B33C`: the turn, right-aligned at (560, 22), as
## `"%d"` or `"%d/%s"` when the mission set a par with `SetTurnControl`, and
## red from three turns before the par.
func _show_turn(world: World) -> void:
	if world == null:
		_turn.text = ""
		return
	var turn: int = world.turn.turn
	var par: int = world.turn.turn_control
	var colour: int = COLOUR_TURN
	if par > 0:
		_turn.text = "%d/%d" % [turn, par]
		if turn >= par - HudTables.TURN_RED_WITHIN:
			colour = COLOUR_TURN_LATE
	else:
		_turn.text = str(turn)
	_turn.add_theme_color_override("font_color", UnitPanel.rgb565(colour))
	_turn.size = _turn.get_minimum_size()


## Whether the last refresh moved the progress bar -- one tick of
## `progress.wav`, docs/43 section 7.1.
func progress_stepped() -> bool:
	return _progress_stepped


## The turn as it is on screen -- empty while the watcher's bare plate is up.
func turn_text() -> String:
	return _turn.text if _turn.visible else ""


## The debriefing, in the game's own words -- docs/20 section 7 says whether
## the mission is over, docs/27 section 6 says what the outcome was worth.
##
## *held* keeps it down while the picture is still showing what ended the
## mission. `core` decides a whole computer turn in one call, so
## `mission_ended()` is true from the first frame of the replay: the shot that
## killed the last marine had not been drawn yet and the plate was already
## over it, on a dimmed map with the defeat playing on underneath. It is the
## same gate [method SliceMain._check_mission_end] makes for the debriefing
## screen, which is the screen this panel stands in front of.
##
## Every line comes out of `Txtmod_d`, the module `aMissionEnd.cpp` builds its
## own screen from, except the headline, which is `Txtmod_g`'s two-word verdict
## the map already used. The two payout slots are shown because the mission
## script writes them and they are in the world already.
func _show_result(world: World, held: bool = false) -> void:
	if world == null or held or not world.game_control.mission_ended():
		_result.visible = false
		return
	var control: GameControl = world.game_control
	var outcome: int = control.mission_result(PLAYER_HUMAN)
	var out: PackedStringArray = PackedStringArray()
	out.append(_strings.shipped(Localization.MODULE_REPORT,
		Localization.ID_REPORT_TITLE))
	out.append("")
	out.append(_strings.shipped(Localization.MODULE_MISSION,
		Localization.ID_COMPLETED if outcome != GameControl.RESULT_DEFEAT
		else Localization.ID_FAILED))
	out.append(_strings.shipped(Localization.MODULE_REPORT,
		_grade_text_id(outcome)))
	out.append("")
	out.append("%s %d" % [_strings.shipped(Localization.MODULE_REPORT,
		Localization.ID_REPORT_TURNS), world.turn.turn])
	# docs/27 section 6.2 pays these out only when the result is not 5, and
	# only when the slot carries something -- both of the engine's own tests.
	if control.pays_out(PLAYER_HUMAN):
		var points: int = control.get_slot(GameControl.SLOT_EQUIPMENT_POINTS)
		if points != 0:
			out.append("%s %d" % [_strings.shipped(
				Localization.MODULE_REPORT,
				Localization.ID_REPORT_EQUIPMENT), points])
		var awards: int = control.get_slot(GameControl.SLOT_COMMENDATIONS)
		if awards != 0:
			out.append("%s %d" % [_strings.shipped(
				Localization.MODULE_REPORT,
				Localization.ID_REPORT_COMMENDATIONS), awards])
	_report.text = "\n".join(out)
	_result.visible = true


## docs/27 section 6.3's mission result, as the line the module has for it.
static func _grade_text_id(outcome: int) -> int:
	match outcome:
		GameControl.RESULT_WON:
			return Localization.ID_REPORT_SUCCESS
		GameControl.RESULT_WON_OUTSTANDING:
			return Localization.ID_REPORT_OUTSTANDING
		GameControl.RESULT_WON_GLORIOUS:
			return Localization.ID_REPORT_GLORIOUS
		GameControl.RESULT_DEFEAT:
			return Localization.ID_REPORT_DEFEATED
	return Localization.ID_REPORT_RUNNING


## The pickup message of docs/24 section 7.2, over the 3D window.
##
## `aActivateInfo` `0x0043E740` puts one block of `Events.txt` in box 2 at
## `230, 200, 180, 400` and raises `0x0050B2B0`; while that flag is up
## `0x0041BB44` returns from the mission's input handler at once, so nothing
## else in the mission answers, and cases `0x204`/`0x206` of the same
## dispatch -- the **right** mouse button -- call `0x0043F130`, which kills
## the box and clears the flag. Both halves are the host's; this draws it.
##
## The original's box is also revealed a word at a time (`aActivateInfo`'s
## eighth argument is 0, docs/24 section 5) and this shows it whole -- the
## typewriter is a sound-driven effect this layer has no cue for.
##
## It also takes itself down after [constant INFO_AUTO_HIDE_SECONDS]
## ([method tick_info]), which the original never does -- but only where the
## box arrived by itself. *auto_hide* is false for the magnifier's page
## (docs/43 section 5.2), which the player opened on purpose and is reading:
## the timeout exists so that a crate opened by mistake cannot hold the
## mission, and a page asked for is neither.
##
## *height* is the box's own height bound: `0x004107A2`'s 400 for a pickup and
## `0x00432B3D`'s 300 for the magnifier ([constant InfoText.DATA_BOX_SIZE]).
## *title* is the heading `0x0043E850`'s eighth argument carries. Only the
## magnifier passes one: `0x00432B20` hands over the **unit record**, whose
## `+0x00` is its `char[20]` name (docs/10 section 5.2), and the painter draws
## it in a frame of its own above the box whenever it is not the empty string.
func show_info(spans: Array, height: float = InfoText.BOX_SIZE.y,
		auto_hide: bool = true, title: String = "") -> void:
	if _info_shield == null or _info_text == null:
		return
	_info_spans = spans
	_info_height = height
	_info_auto_hide = auto_hide
	_info_title_spans = [] if title == "" else [{
		"text": title,
		# The heavier of the two shipped faces, which is what a heading is
		# written in ([method BriefingText.to_bbcode]).
		"font": 1,
		"colour": BriefingText.RAMP_DEFAULT_INDEX,
		"breaks": 0,
	}]
	_info_text.show_block(spans)
	if _info_title_text != null:
		_info_title_text.show_block(_info_title_spans)
		_info_title_text.visible = not _info_title_spans.is_empty()
	_info_shield.visible = not spans.is_empty()
	_info_clock = 0.0
	_layout_info()


func hide_info() -> void:
	if _info_shield == null:
		return
	_info_spans = []
	_info_title_spans = []
	_info_shield.visible = false
	if _info_title_text != null:
		_info_title_text.visible = false


## The message's own clock, stepped by the host's frame
## ([code]SliceMain._tick_interface[/code]) -- not a [Timer] and not
## `_process`, because the suites build the interface with `MissionHud.new()`
## and never add it to a tree, so neither would run under a check.
##
## Nothing accumulates while the box is down: a message dismissed after half a
## second would otherwise hand the next one four and a half.
func tick_info(delta: float) -> void:
	if not info_visible():
		_info_clock = 0.0
		return
	if not _info_auto_hide:
		return
	_info_clock += delta
	if _info_clock >= INFO_AUTO_HIDE_SECONDS:
		hide_info()


func info_visible() -> bool:
	return _info_shield != null and _info_shield.visible


## Any mouse button takes the message down, wherever on the plate it lands.
##
## The original's own dismissal is the **right** button alone -- cases `0x204`
## and `0x206` of `0x0041B6E0`'s mouse dispatch call `0x0043F130` -- and its
## left click, while a box is up, does nothing whatever. Answering that one as
## well therefore takes no behaviour away, and a trackpad's right button is a
## chord. [method tick_info] answers the case where nothing is pressed at all.
func _on_info_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.is_pressed():
		hide_info()
		_info_shield.accept_event()


## The modal [Control] the message sits on, so a suite can ask what it stops
## and drive its dismissal without a window.
func info_shield() -> Control:
	return _info_shield


## What the box is saying, as plain text -- for the driver and the suites.
func info_text() -> String:
	if _info_text == null or not info_visible():
		return ""
	return _info_text.get_parsed_text()


## The heading over it, "" where there is none.
func info_title() -> String:
	if _info_title_text == null or not _info_title_text.visible \
			or not info_visible():
		return ""
	return _info_title_text.get_parsed_text()


## Where the box stands on this canvas.
##
## The plate is 640x480 and every pixel of a larger canvas goes to the 3D
## window ([method HudTables.window_for]), so a box drawn over the window
## keeps its offset from the **window's** centre rather than from the plate's
## origin. At 640x480 the two are the same thing, and the shipped box happens
## to be centred on the window's own column: `230 + 180/2` is 320, and so is
## `60 + 520/2`.
static func info_box_rect(canvas: Vector2,
		bound: float = InfoText.BOX_SIZE.y) -> Rect2:
	var win: Rect2 = HudTables.window_for(canvas)
	var plate: Rect2 = Rect2(Vector2(HudTables.WINDOW.position),
		Vector2(HudTables.WINDOW.size))
	var at: Vector2 = InfoText.BOX_AT + win.get_center() - plate.get_center()
	# The height is a layout bound and not a drawn rectangle -- docs/24
	# section 7.1's `B0` box is 500 tall on a 480 screen -- so what is left
	# under the box's top edge is the bound that matters here.
	var height: float = maxf(0.0, minf(bound,
		canvas.y - at.y - INFO_BOTTOM_MARGIN))
	return Rect2(at, Vector2(InfoText.BOX_SIZE.x, height))


func _layout_info() -> void:
	if _info == null or _info_text == null:
		return
	var box: Rect2 = info_box_rect(canvas_size(), _info_height)
	# A heading moves the frame up and out by what `0x0043ED87` subtracts and
	# adds, so the **text** still starts where the box was asked for.
	var titled: bool = _info_title_text != null and _info_title_text.visible
	var at: Vector2 = box.position
	var width: float = box.size.x
	if titled:
		at += INFO_TITLE_OFFSET
		width += INFO_TITLE_EXTRA_WIDTH
	var inner: float = maxf(0.0, width - 2.0 * INFO_PADDING)
	_info_text.custom_minimum_size = Vector2(inner, 0.0)
	if _info_title_text != null:
		_info_title_text.custom_minimum_size = Vector2(inner, 0.0)
	# The box's own position is inside the shield, which is the whole canvas,
	# so the two coordinate spaces are the same one.
	_info.position = at
	_info.size = Vector2(width, 0.0)
	# `fit_content` grows the label and the container with it, so the box is as
	# tall as what is in it and [member _info_height] bounds **nothing here**.
	#
	# **Measured, not assumed** (docs/24 section 7.1). The height
	# `aActivateBriefingInfo` stores at `0x0050b2c8` has exactly one reader in
	# the whole image, `0x0043f032`, which pushes it into the frame draw
	# `0x0043f430` -- so in the original it is the height of the drawn
	# *rectangle* and nothing clips the text to it. A block longer than its
	# box therefore runs past the frame's bottom edge in the original, which
	# is why `B0` can be given a box 500 tall on a 480 screen at all. Here the
	# frame grows to hold its text instead: the same words, inside a border
	# rather than through it. It is the one place this box diverges, and
	# nothing shipped reaches it: the two boxes drawn here are the pickup's
	# 400-tall one and the magnifier's 300, and no shipped block overflows
	# either. The mission-start `A0` popup, whose 199 was the one height a
	# briefing did overflow, is not drawn at all -- `0x0043B1F0` gates it
	# on multiplayer (docs/92 section 7.19 I10).
	# The numbers are kept because [method info_box_rect] is the rectangle the
	# specs quote and the agent and the suites read it.
	_info.custom_minimum_size = Vector2(width, 0.0)


static func _info_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = INFO_GROUND
	style.border_color = INFO_BORDER
	style.set_border_width_all(INFO_BORDER_WIDTH)
	style.set_content_margin_all(INFO_PADDING)
	return style


func report_visible() -> bool:
	return _result.visible


func report_text() -> String:
	return _report.text if _result.visible else ""


## Everything a driver wants to know about the interface, as scalars.
func view() -> Dictionary:
	var canvas: Vector2 = canvas_size()
	var win: Rect2 = window()
	return {
		"canvas": [canvas.x, canvas.y],
		"window": [win.position.x, win.position.y, win.size.x, win.size.y],
		"visible": visible,
		"turn_text": turn_text(),
		"hint": hint_text(),
		"report": report_text(),
		"info": info_text(),
		"info_title": info_title(),
		# Whether the magnifier is lit (docs/43 section 5.2): a drive that
		# reads the box alone cannot tell a page that was opened from a
		# button that was pressed and answered nothing.
		"magnifier": columns.magnifier(),
		"radar_fields": radar.fields,
		# Zero while another player moves: the marks are still built, and
		# the radar they are on is not on screen (docs/43 section 7).
		"radar_marks": radar.mark_count() if radar.visible else 0,
		"panel_texts": panel.texts(),
		"panel_icons": panel.icon_count(),
		"ring": ring.report(),
		"ring_mode": ring.mode,
		"progress": progress.lit_count(),
		"progress_stepped": progress_stepped(),
	}
