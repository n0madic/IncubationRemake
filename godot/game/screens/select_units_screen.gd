class_name SelectUnitsScreen
extends CampaignScreen

## `SelectUnits` -- the deploy screen, docs/27 section 3.4's
## `aTransferUnitFromPoolToMap` and docs/29 section 1.2's cells.
##
## It is a list of roster records and a list of free deployment cells; picking
## one of each places a unit. The header's deployment ring holds **ten**
## records, so ten is the upper bound on a sortie whatever the map offers --
## and no shipped mission offers more.

const ID_TITLE: int = 13
const ID_POSITIONS: int = 87
const ID_IN_SQUAD: int = 89
const ID_CONTINUE_BUTTON: int = 4
const ID_MAIN_MAP: int = 140

var host: CampaignHost = null
## The roster slot the player picked, or [constant Roster.NO_SLOT].
var selected: int = Roster.NO_SLOT

var _squad: VBoxContainer = null
var _cells: VBoxContainer = null


func build() -> void:
	var title: Label = make_label(label_for(BANK_MISSION, ID_TITLE))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	_squad = VBoxContainer.new()
	_squad.position = Vector2(8.0, 36.0)
	body().add_child(_squad)

	_cells = VBoxContainer.new()
	_cells.position = Vector2(300.0, 36.0)
	body().add_child(_cells)

	add_button("start", BANK_MISSION, ID_CONTINUE_BUTTON, 0)
	add_button("map", BANK_MISSION, ID_MAIN_MAP, 1)
	refresh()


func refresh() -> void:
	if host == null or host.state == null or _squad == null:
		return
	for child: Node in _squad.get_children():
		_squad.remove_child(child)
		child.free()
	for child: Node in _cells.get_children():
		_cells.remove_child(child)
		child.free()

	_squad.add_child(make_label("%s %d" % [
		label_for(BANK_MISSION, ID_IN_SQUAD),
		host.state.roster.used_slots()]))
	for slot: int in host.state.roster.occupied_slots():
		var unit: UnitState = host.state.roster.record(slot)
		if unit == null:
			continue
		var row: Button = Button.new()
		row.text = "%-14s %3d" % [unit.name, unit.ep]
		if font != null:
			row.add_theme_font_override("font", font)
		row.toggle_mode = true
		row.button_pressed = slot == selected
		row.pressed.connect(_pick.bind(slot))
		_squad.add_child(row)

	var cells: Array[Vector2i] = host.deployment_cells()
	_cells.add_child(make_label("%s %d" % [
		label_for(BANK_MISSION, ID_POSITIONS), cells.size()]))
	for cell: Vector2i in cells:
		var row: Button = Button.new()
		row.text = "%d, %d" % [cell.x, cell.y]
		if font != null:
			row.add_theme_font_override("font", font)
		row.pressed.connect(_place.bind(cell))
		_cells.add_child(row)


func _pick(slot: int) -> void:
	selected = slot
	refresh()


func _place(cell: Vector2i) -> void:
	if host == null or selected == Roster.NO_SLOT:
		return
	var placed: Dictionary = host.deploy(selected, cell.x, cell.y)
	if DictRead.as_string(placed["result"]) == World.DEPLOY_OK:
		selected = Roster.NO_SLOT
		chose.emit("deployed")
	refresh()
