class_name UpgradeScreen
extends CampaignScreen

## The purchase catalogue -- docs/27 sections 5.2 and 5.3.
##
## The catalogue is shown **filtered by the tech level and with what is locked
## still visible**. That matters more here than it looks: the tech level does
## not grow (`0x00509F04` has four `.text` references in the whole image and
## the campaign's writes 1 once), so at tech 1 fourteen of the forty-two
## weapons and seven of the nineteen items are ever buyable. A screen that
## silently hid the rest would make that indistinguishable from a working
## progression.
##
## **The filter is the engine's own, and it is a range.** `0x0045BF44` writes
## `[0x00510A34] = 0` and `[0x00510A35] = getTechLevel()`; `0x0045AF21` reads
## the two as one word, `al` the low limit and `ah` the high, and hands them to
## the list builders `0x0047A090` (equipment) and `0x0047A1B0` (weapons), which
## walk the table backwards, skip a record whose name is empty and accept one
## whose requirement byte is `low <= b <= high`. That closes docs/27 section
## 5.2's **UNVERIFIED** on which of the pair is which.
##
## A consequence worth stating rather than quietly filtering out: the ten alien
## weapons have requirement 0 and a non-empty name, so at any tech level they
## pass, priced at zero. That is what the shipped filter gives.

const ID_TITLE: int = 100
const ID_SELECT_UNIT: int = 101
const ID_WEAPONS: int = 151
const ID_EQUIPMENT: int = 152
const ID_POINTS: int = 153
const ID_BUY: int = 105
const ID_MAIN_MAP: int = 140

var host: CampaignHost = null
var selected: int = Roster.NO_SLOT
## `"weapons"` or `"equipment"`.
var catalogue_kind: String = "weapons"

var _list: VBoxContainer = null
var _purse: Label = null


func build() -> void:
	var title: Label = make_label(label_for(BANK_MISSION, ID_TITLE))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	_purse = make_label("")
	_purse.position = Vector2(8.0, 30.0)
	body().add_child(_purse)

	# The catalogue is longer than the plate: 42 weapons and 19 items, and the
	# whole of both is shown because what is locked has to stay visible.
	var scroller: ScrollContainer = ScrollContainer.new()
	scroller.position = Vector2(8.0, 60.0)
	scroller.custom_minimum_size = Vector2(420.0, 560.0)
	scroller.size = Vector2(420.0, 560.0)
	body().add_child(scroller)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroller.add_child(_list)

	add_button("weapons", BANK_MISSION, ID_WEAPONS, 0)
	add_button("equipment", BANK_MISSION, ID_EQUIPMENT, 1)
	add_button("map", BANK_MISSION, ID_MAIN_MAP, 2)
	refresh()


func refresh() -> void:
	if host == null or host.state == null or _list == null:
		return
	clear_children(_list)
	_purse.text = "%s %d   tech %d" % [
		label_for(BANK_MISSION, ID_POINTS), host.state.points(0),
		host.state.tech_level]
	var split: Dictionary = host.catalogue(catalogue_kind)
	var available: Array = DictRead.as_array(split["available"])
	var locked: Array = DictRead.as_array(split["locked"])
	for entry: Variant in available:
		var row: Dictionary = entry
		var line: Button = Button.new()
		line.text = "%-22s %4d" % [DictRead.as_string(row["name"]),
			DictRead.as_int(row["cost"])]
		if font != null:
			line.add_theme_font_override("font", font)
		line.pressed.connect(_buy.bind(DictRead.as_int(row["id"]),
			DictRead.as_int(row["cost"])))
		_list.add_child(line)
	# What is locked stays on the screen, greyed and with the level it wants.
	for entry: Variant in locked:
		var row: Dictionary = entry
		var line: Label = make_label("%-22s %4d  tech %d" % [
			DictRead.as_string(row["name"]), DictRead.as_int(row["cost"]),
			DictRead.as_int(row["tech"])])
		line.add_theme_color_override("font_color",
			Color(0.45, 0.45, 0.45))
		_list.add_child(line)
	var counted: Label = make_label("%d / %d" % [available.size(),
		available.size() + locked.size()])
	_list.add_child(counted)


func _buy(id: int, cost: int) -> void:
	if selected == Roster.NO_SLOT:
		return
	if catalogue_kind == "weapons":
		var _bought: bool = host.state.buy_weapon(0, selected, id,
			host.weapon_costs())
	else:
		var _taken: bool = host.state.buy_equipment(0, selected, id, cost)
	refresh()
