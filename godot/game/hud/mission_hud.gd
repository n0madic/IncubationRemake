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
## The two faces the interface is written in: the 13 px `font_0` for the
## turn and the hints, the 10 px `font_3` for the panel's numbers.
const TEXT_FONT: String = "font_0"
const SMALL_FONT: String = "font_3"
## The turn counter's colours (`0x0041B1D1`).
const COLOUR_TURN: int = 0xFFFF
const COLOUR_TURN_LATE: int = 0xF800
## The readable face's size for the band texts when the cache has no fonts.
const FALLBACK_TEXT_SIZE: int = 13

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
var _strings: Localization = null
var _art: Art = null
var _font: FontFile = null
var _text_font: FontFile = null
var _small_font: FontFile = null


## Build the interface. *font* is the interface font setting (the 17 px face
## or null for the readable one); *text_font* and *small_font* the two plate
## faces, which a cache without fonts leaves null.
func setup(art: Art, strings: Localization, font: FontFile,
		text_font: FontFile, small_font: FontFile) -> void:
	_art = art
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

	pad = CommandPad.new()
	pad.name = "Pad"
	_root.add_child(pad)
	pad.setup(art, strings)
	pad.command.connect(func(number: int) -> void: command.emit(number))
	pad.hint.connect(set_hint)

	panel = UnitPanel.new()
	panel.name = "Panel"
	_root.add_child(panel)
	panel.setup(art, strings, _band_font(), _panel_font())

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
	use_font(font)
	_root.resized.connect(_layout)
	_layout()


## The interface font setting changed. The plate's own two faces stay: they
## are the size their rows are, and the readable option is about the wrapped
## paragraphs of the shell and the report.
func use_font(font: FontFile) -> void:
	_font = font
	for label: Label in [_turn, _hint]:
		_apply_font(label, _band_font())
	if font == null:
		_report.remove_theme_font_override("font")
		_report.add_theme_font_size_override("font_size", READABLE_REPORT_SIZE)
	else:
		_apply_font(_report, font)
	if panel != null:
		panel.use_font(_band_font(), _panel_font())
	_layout()


func _band_font() -> FontFile:
	return _text_font if _text_font != null else _font


func _panel_font() -> FontFile:
	return _small_font if _small_font != null else _band_font()


static func _apply_font(label: Label, font: FontFile) -> void:
	if label == null:
		return
	if font == null:
		label.remove_theme_font_override("font")
		label.remove_theme_font_size_override("font_size")
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
	_hint.position = Vector2(float(HudTables.CAPTION_AT.x),
		float(HudTables.CAPTION_AT.y) - height)


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
		watching: Dictionary = {}) -> void:
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
	_show_result(world)
	_layout()


## The hint line at (60, 22): a button's caption while the pointer is on it.
func set_hint(text: String) -> void:
	_hint.text = text
	_hint.visible = text != ""


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
## Every line comes out of `Txtmod_d`, the module `aMissionEnd.cpp` builds its
## own screen from, except the headline, which is `Txtmod_g`'s two-word verdict
## the map already used. The two payout slots are shown because the mission
## script writes them and they are in the world already.
func _show_result(world: World) -> void:
	if world == null or not world.game_control.mission_ended():
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
