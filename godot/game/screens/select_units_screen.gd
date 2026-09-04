class_name SelectUnitsScreen
extends CampaignScreen

## `SelectUnits` -- the deploy screen, docs/27 section 3.4's
## `aTransferUnitFromPoolToMap` and docs/29 section 1.2's cells.
##
## It is a list of roster records and a list of free deployment cells; picking
## one of each places a unit. The header's deployment ring holds **ten**
## records, so ten is the upper bound on a sortie whatever the map offers --
## and no shipped mission offers more.
##
## **Every refusal here is said out loud** (docs/92 section 7.4). It used to
## say nothing at all: a cell clicked with no soldier picked did nothing, and
## *Continue* with an empty map did nothing, so a player who did not already
## know that a name has to be clicked before a position could not start the
## campaign and had no way to find out. The original does not need the words
## because its screen is a picture of the map with the squad standing on it;
## a pair of lists does.

## The remake's own, because this screen's silences are the remake's own too.
const OWN_HINT: String = "deploy.hint"
const OWN_PICK_FIRST: String = "deploy.pick_a_soldier"
const OWN_NEED_ONE: String = "deploy.need_one"
## `deploy.<result>` for each of [World]'s refusal names.
const OWN_REFUSAL: String = "deploy.%s"

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
## What the last click meant, shown under the two lists.
var _message: Label = null


func build() -> void:
	var title: Label = make_label(label_for(BANK_MISSION, ID_TITLE))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	# The hint sits under the title and the lists under the hint. The three
	# offsets were 0 / 16 / 36 and the title is about 20 units tall at the
	# readable size, so the hint was written across the bottom of it.
	_message = make_label(strings_own(OWN_HINT))
	_message.position = Vector2(8.0, 22.0)
	body().add_child(_message)

	_squad = VBoxContainer.new()
	_squad.position = Vector2(8.0, 44.0)
	body().add_child(_squad)

	_cells = VBoxContainer.new()
	_cells.position = Vector2(300.0, 44.0)
	body().add_child(_cells)

	add_button("start", BANK_MISSION, ID_CONTINUE_BUTTON, 0)
	add_button("map", BANK_MISSION, ID_MAIN_MAP, 1)
	refresh()


func refresh() -> void:
	if host == null or host.state == null or _squad == null:
		return
	clear_children(_squad)
	clear_children(_cells)

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
	if host == null:
		return
	if selected == Roster.NO_SLOT:
		say(strings_own(OWN_PICK_FIRST))
		return
	var placed: Dictionary = host.deploy(selected, cell.x, cell.y)
	var outcome: String = DictRead.as_string(placed["result"])
	if outcome == World.DEPLOY_OK:
		selected = Roster.NO_SLOT
		say(strings_own(OWN_HINT))
		chose.emit("deployed")
	else:
		# [World]'s own refusal name, turned into a sentence. A name the
		# catalogue has no line for comes back as the marker rather than as a
		# blank, so a new refusal is visible instead of silent.
		say(strings_own(OWN_REFUSAL % outcome))
	refresh()


## Put one line under the title. The host calls it too, for the refusal only
## it can see -- that a mission may not start with an empty map.
func say(line: String) -> void:
	if _message != null:
		_message.text = line
