class_name MissionSelectScreen
extends CampaignScreen

## *Instant Action*'s `Leveloptions` page.
##
## A row selects a map; it does not launch it.  In the retail flow `ArenaMode`
## accepts the player setup first, then switches Menu_a's window selector to
## `:Leveloptions;`; gadget 21 validates the selected row before a battle is
## built.  The old remake made every manifest entry a launch button, including
## campaign backdrops and upgrade maps which cannot be played as a skirmish.
##
## The owner gives this page only maps supported by the local single-player
## session.  A missing converted `_S_*` map is therefore an empty catalogue,
## not a button that starts an empty or nonsensical battle.

## `Txtmod_a` 110 -- the title of the original's window 10.
const ID_LEVEL_OPTIONS: int = 110
## `Mission.lcl` -- the original turns `_S_004` into text id 4 before it
## paints the row.  The mission stem remains the selection key; this bank is
## presentation only.
const BANK_LEVEL_NAMES: String = "Mission"
## The shipped list reserves ten rows. The supported single-player catalogue
## currently has exactly ten `_S_*` maps, but keep the paging rule at its
## source shape if a later corpus supplies more.

var missions: PackedStringArray = PackedStringArray()

var _rows: Control = null


## `GUI_SetListbox (0..9, ..., 060_x, 120+22i_y, 8_Width)`.
const LIST_AT: Vector2 = Vector2(60.0, 120.0)
const LIST_WIDTH: int = 12
const LIST_ROWS: int = 10
## `GUI_SetIcon (10, 30_Library, 320, 120)` and `(11, 32_Library, 320, 155)`
## -- the list's own two arrows, which is how a shipped listbox is paged.
## They are moved to the list's right edge here, where the rows are wider.
const UP_AT: Vector2 = Vector2(480.0, 120.0)
const DOWN_AT: Vector2 = Vector2(480.0, 155.0)
const UP_INDEX: int = 30
const DOWN_INDEX: int = 32

## The first row on show.
var first_row: int = 0
## The selected map survives paging.  It is a name rather than a row number:
## paging changes indices but must not silently select another map.
var selected: String = ""


func build() -> void:
	var title: Label = make_label(label_for(BANK_MENU, ID_LEVEL_OPTIONS))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	_rows = gui_layer()
	if missions.size() > LIST_ROWS:
		var _up: Button = gui_icon("scroll_up", UP_INDEX, UP_AT, body())
		var _down: Button = gui_icon("scroll_down", DOWN_INDEX, DOWN_AT,
			body())
	add_button("back", BANK_MISSION, ID_BACK, 0)
	# Do not offer an inert Continue button when the cache was produced without
	# `--instant-action-maps`.
	if not missions.is_empty():
		add_button("instant_start", BANK_MISSION, ID_CONTINUE, 1)
	if selected == "" and not missions.is_empty():
		selected = missions[0]
	refresh()


## Ten rows a page, which is what `Menu_a.lcl`'s *Leveloptions* reserves; a
## cache with more missions than that is **paged** rather than scrolled,
## because a shipped listbox has no scroll bar -- it has two arrows.
func refresh() -> void:
	if _rows == null:
		return
	clear_children(_rows)
	first_row = clampi(first_row, 0, maxi(0, missions.size() - LIST_ROWS))
	var shown: int = mini(missions.size() - first_row, LIST_ROWS)
	for index: int in range(shown):
		var name: String = missions[first_row + index]
		var _row: Button = gui_list_row("select_mission:" + name,
			mission_label(name),
			LIST_AT + Vector2(0.0, LIST_ROW_HEIGHT * float(index)),
			LIST_WIDTH, index, shown, _rows)
		_row.toggle_mode = true
		_row.button_pressed = name == selected


## `aBuildMissionTxtSys` (`Incubation.exe` `0x00419BA0`) reads characters
## 3..5 of an underscore-prefixed stem as the id in `Mission.lcl`.  Missing
## ids keep the stem, which is the original's fallback and also keeps custom
## maps identifiable.
func mission_label(name: String) -> String:
	if not name.begins_with("_") or name.length() < 6:
		return name
	var digits: String = name.substr(3, 3)
	if not digits.is_valid_int():
		return name
	var title: String = label_for(BANK_LEVEL_NAMES, digits.to_int())
	if title.begins_with(Localization.MISSING_PREFIX):
		return name
	return title


func select_mission(name: String) -> bool:
	if not missions.has(name):
		return false
	selected = name
	refresh()
	return true


## One arrow, a page at a time.
func scroll(by: int) -> void:
	first_row += by * LIST_ROWS
	refresh()


func scrolls() -> bool:
	return missions.size() > LIST_ROWS


## The wheel, one row at a time -- the arrows turn a page and the wheel does
## not, which is the difference between the two controls.
func step_rows(rows: int) -> void:
	first_row += rows
	refresh()
