class_name HqScreen
extends CampaignScreen

## The roster, and the Recruit screen's two buttons -- docs/27 sections 3.2,
## 3.3 and 5.4.
##
## A row **addresses a record, not a table position** (docs/29 section 1.4):
## `0x00478630`'s sort moves records between slots, so a screen that
## remembered "row 3" would sell a different soldier after a sort. Each row
## carries the slot it came from.

const ID_TITLE: int = 70
const ID_RECRUIT: int = 81
const ID_POINTS: int = 83
const ID_IN_SQUAD: int = 89
const ID_SKILLS: int = 91
const ID_COST: int = 92
const ID_EXP: int = 93
const ID_UNDO: int = 112
const ID_MAIN_MAP: int = 140

var host: CampaignHost = null
## The slot the player has picked, or [constant Roster.NO_SLOT].
var selected: int = Roster.NO_SLOT

var _rows: VBoxContainer = null
var _purse: Label = null


func build() -> void:
	var title: Label = make_label(label_for(BANK_MISSION, ID_TITLE))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	_purse = make_label("")
	_purse.position = Vector2(8.0, 30.0)
	body().add_child(_purse)

	var header: Label = make_label("%s   %s   %s" % [
		label_for(BANK_MISSION, ID_EXP),
		label_for(BANK_MISSION, ID_SKILLS),
		label_for(BANK_MISSION, ID_COST)])
	header.position = Vector2(8.0, 58.0)
	body().add_child(header)

	_rows = VBoxContainer.new()
	_rows.position = Vector2(8.0, 82.0)
	body().add_child(_rows)

	add_button("recruit", BANK_MISSION, ID_RECRUIT, 0)
	add_button("dismiss", BANK_MISSION, ID_UNDO, 1)
	add_button("map", BANK_MISSION, ID_MAIN_MAP, 2)
	refresh()


## Redraw the roster. Called after every hire and every sale, because both
## renumber the rows.
func refresh() -> void:
	if host == null or host.state == null or _rows == null:
		return
	for child: Node in _rows.get_children():
		_rows.remove_child(child)
		child.free()
	_purse.text = "%s %d" % [label_for(BANK_MISSION, ID_POINTS),
		host.state.points(0)]
	var costs: Dictionary = host.weapon_costs()
	for slot: int in host.state.roster.occupied_slots():
		var unit: UnitState = host.state.roster.record(slot)
		if unit == null:
			continue
		var resale: int = Roster.refund_for(
			DictRead.as_int(costs.get(unit.weapon, 0)))
		var row: Button = Button.new()
		row.text = "%-14s  %3d  %d  %4d" % [unit.name, unit.ep,
			unit.ep / Roster.EP_PER_RANK, resale]
		if font != null:
			row.add_theme_font_override("font", font)
		row.toggle_mode = true
		row.button_pressed = slot == selected
		row.pressed.connect(_pick.bind(slot))
		_rows.add_child(row)
	var count: Label = make_label("%s %d" % [
		label_for(BANK_MISSION, ID_IN_SQUAD),
		host.state.roster.used_slots()])
	_rows.add_child(count)


## The slot, not the row: a sort moves records and this must follow the record.
func _pick(slot: int) -> void:
	selected = slot
	refresh()
