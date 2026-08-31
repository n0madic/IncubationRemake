class_name Hud
extends CanvasLayer

## The mission's own interface: whose turn it is, what the selected unit has
## left, what the keys do, and how the mission ended.
##
## docs/29 section 1.1's full panel is the next stage. What is here is the
## minimum a mission needs to be *played* -- and every word of it comes through
## [Localization], including the five the shipped `Txtmod_g` already has.
##
## **It reads the world and never writes it.** Every line is rebuilt from
## `World.unit_view` and `World.turn`; nothing on screen is the source of a
## selection, a position or a turn number.

## docs/10 section 5.7 -- the alien side, whose name is not a number.
const PLAYER_COMPUTER: int = 255
## `+0x41 == 1` -- a reaction is pending (docs/25 section 6).
const ACTION_WAITING: int = 1
## The player the report is written for. One squad, one seat: the slice has no
## campaign and no second human, and docs/27 section 6.3's result is per player.
const PLAYER_HUMAN: int = 0
## What the map is dimmed to behind the report. Dimmed rather than covered:
## the last thing that happened is worth seeing under the words.
const DIM_COLOUR: Color = Color(0.0, 0.0, 0.0, 0.72)

var _lines: Label = null
## The report is a panel, not a line: a dimmed screen with the debriefing on
## it. [member _report] is the Label inside [member _result].
var _result: Control = null
var _report: Label = null
var _strings: Localization = null


## The game's own font, when the cache carries it.
##
## docs/60: `font_2` is the largest of the four at 17 px and the only one big
## enough to read at a modern resolution. A cache without fonts -- one built by
## an older converter -- leaves the [Label]s on Godot's default, which is what
## they were on for three slices; the HUD is not the place to fail over it.
var _font: FontFile = null


func use_font(font: FontFile) -> void:
	_font = font
	for label: Label in [_lines, _report]:
		if label == null or font == null:
			continue
		label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", font.fixed_size)


func _init(strings: Localization) -> void:
	_strings = strings
	_lines = Label.new()
	_lines.position = Vector2(12.0, 8.0)
	add_child(_lines)
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
	add_child(_result)


func refresh(world: World, selected: int, note: String) -> void:
	if world == null:
		return
	var out: PackedStringArray = PackedStringArray()
	out.append("%s: %s   %s: %d   %s: %s" % [
		_strings.shipped(Localization.MODULE_MISSION, Localization.ID_MISSION),
		world.resource.mission,
		_strings.shipped(Localization.MODULE_MISSION, Localization.ID_TURN),
		world.turn.turn,
		_strings.shipped(Localization.MODULE_MISSION, Localization.ID_PLAYER),
		_player_name(world.turn.current_player)])
	out.append(_unit_line(world, selected))
	if note != "":
		out.append(note)
	out.append("%s | %s | %s | %s | %s | %s" % [
		_strings.text("hud.move"), _strings.text("hud.attack"),
		_strings.text("hud.use"), _strings.text("hud.defend"),
		_strings.text("hud.cycle"), _strings.text("hud.end_turn")])
	_lines.text = "\n".join(out)
	_show_result(world)


func _player_name(player: int) -> String:
	if player == PLAYER_COMPUTER:
		return _strings.text("hud.computer")
	return str(player)


func _unit_line(world: World, selected: int) -> String:
	if selected < 0 or not world.has_unit(selected):
		return _strings.text("hud.no_selection") + " -- " \
			+ _strings.text("hud.select")
	var view: Dictionary = world.unit_view(selected)
	var line: String = "%s   %s %d   %s %d   %s %d   %s %d" % [
		DictRead.as_string(view["name"]),
		_strings.text("hud.movement_points"), DictRead.as_int(view["mp"]),
		_strings.text("hud.hit_points"), DictRead.as_int(view["hp"]),
		_strings.text("hud.fitness"), DictRead.as_int(view["fp"]),
		_strings.text("hud.ammunition"), DictRead.as_int(view["ammo"])]
	if DictRead.as_int(view["action_state"]) == ACTION_WAITING:
		line += "   " + _strings.text("hud.overwatch")
	return line


## The debriefing, in the game's own words -- docs/20 section 7 says whether
## the mission is over, docs/27 section 6 says what the outcome was worth.
##
## Every line comes out of `Txtmod_d`, the module `aMissionEnd.cpp` builds its
## own screen from, except the headline, which is `Txtmod_g`'s two-word verdict
## the map already used. What is **not** here is the campaign half: the score,
## the kills and the losses need the scoreboard record, and docs/27 is out of
## this slice's scope. The two payout slots are shown because the mission
## script writes them and they are in the world already.
func _show_result(world: World) -> void:
	if not world.game_control.mission_ended():
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
func _grade_text_id(outcome: int) -> int:
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
