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

var _lines: Label = null
var _banner: Label = null
var _strings: Localization = null


func _init(strings: Localization) -> void:
	_strings = strings
	_lines = Label.new()
	_lines.position = Vector2(12.0, 8.0)
	add_child(_lines)
	_banner = Label.new()
	_banner.position = Vector2(12.0, 8.0)
	_banner.visible = false
	add_child(_banner)


## Where the banner sits once there is something to say.
const BANNER_OFFSET: Vector2 = Vector2(12.0, 200.0)


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
	out.append("%s | %s | %s | %s | %s" % [
		_strings.text("hud.move"), _strings.text("hud.attack"),
		_strings.text("hud.use"), _strings.text("hud.defend"),
		_strings.text("hud.end_turn")])
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


## docs/20 section 7 -- slots 0..4 are what says the mission is over, and slot 0
## is this player's. `Txtmod_g` 25 and 26 are the words the game itself uses.
func _show_result(world: World) -> void:
	if not world.game_control.mission_ended():
		_banner.visible = false
		return
	var won: bool = world.game_control.get_slot(0) != 0
	_banner.text = _strings.shipped(Localization.MODULE_MISSION,
		Localization.ID_COMPLETED if won else Localization.ID_FAILED)
	_banner.position = BANNER_OFFSET
	_banner.visible = true
