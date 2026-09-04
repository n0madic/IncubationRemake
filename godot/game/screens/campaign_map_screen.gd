class_name CampaignMapScreen
extends CampaignScreen

## The location map -- docs/27 section 2.
##
## `_C_XXX` and `_C_YYY` are ordinary `.lev` files of map type 4 and the
## existing renderer draws them (D3); their `.lcl` is **not** run, because a
## campaign map's script is the original front end's and this remake's flow is
## its own. So this screen is the list of open locations laid over that view,
## and clicking one is `aLocationHandling`.
##
## `Campaign.lcl` names all 110 locations, which is why not one caption here is
## a literal.

const ID_TITLE: int = 140
const ID_ENTER: int = 141
const ID_DIALOGUE: int = 145
const ID_HQ: int = 70
const ID_SAVE: int = 19

var host: CampaignHost = null

var _list: VBoxContainer = null


func build() -> void:
	var title: Label = make_label(label_for(BANK_MISSION, ID_TITLE))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	_list = VBoxContainer.new()
	_list.position = Vector2(8.0, 32.0)
	body().add_child(_list)

	add_button("hq", BANK_MISSION, ID_HQ, 0)
	add_button("save", BANK_MISSION, ID_SAVE, 1)
	# **The map is where the difficulty is editable**, and `Txtmod_h` 58 says
	# so aloud -- *Set Difficulty Level (only in main map during campaign)*.
	# Without a way in from here that was the one place the shipped string
	# promises the control works and the one place the player could not reach:
	# `ESC` refuses while a campaign plate is up, deliberately, because the
	# shell shares `_screen` with it.
	var _options: Button = make_action_button("options",
		strings_own(OWN_OPTIONS))
	_buttons_row().add_child(_options)
	_lay_out_buttons()
	refresh()


func refresh() -> void:
	if host == null or host.state == null or _list == null:
		return
	clear_children(_list)
	_list.add_child(make_label("%s  %s  %d" % [
		host.state.mission, host.map_mission(), host.state.points(0)]))
	for id: int in host.open_locations():
		var kind: String = host.tables.kind_of(id)
		var row: Button = Button.new()
		# `Campaign.lcl` is text bank 1 and names every location; a dialogue
		# location is named and opens and plays nothing (D5).
		row.text = "%3d  %-28s  %s" % [id,
			label_for(BANK_LOCATIONS, id), kind]
		if font != null:
			row.add_theme_font_override("font", font)
		row.pressed.connect(_click.bind(id))
		_list.add_child(row)


func _click(id: int) -> void:
	if host == null:
		return
	var clicked: Dictionary = host.click_location(id)
	chose.emit("location:%d:%s" % [id, DictRead.as_string(clicked["kind"])])
