class_name MissionSelectScreen
extends CampaignScreen

## *Instant Action* -- one mission, past the campaign.
##
## The list is the cache manifest's own `missions`, in the order the converter
## emitted them, which is exactly what `--mission=` can already reach. The
## point of the screen is that it is the same set without a command line: a
## cache published with `--campaign-maps` offers all 92, one published with the
## default six offers six, and the screen says which it is rather than pretending
## the rest exist.
##
## A mission entered here has **no campaign state**: no roster to deploy, no
## scoreboard to write, and no next mission -- which is why [method
## SliceMain._check_mission_end] correctly does nothing when one ends.

## `Txtmod_a` 111 -- *Found Maps:*, the caption the original's own map list
## carries.
const ID_FOUND: int = 111
## How many rows fit before the list is worth scrolling. The catalogue is 92
## long when the cache carries the campaign.

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


func build() -> void:
	var title: Label = make_label("%s  %s" % [
		label_for(BANK_MENU, MainMenuScreen.ID_INSTANT_ACTION),
		label_for(BANK_MENU, ID_FOUND)])
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	_rows = gui_layer()
	if missions.size() > LIST_ROWS:
		var _up: Button = gui_icon("scroll_up", UP_INDEX, UP_AT, body())
		var _down: Button = gui_icon("scroll_down", DOWN_INDEX, DOWN_AT,
			body())
	refresh()

	add_button("back", BANK_MISSION, ID_BACK, 0)


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
		var _row: Button = gui_list_row("mission:" + name, name,
			LIST_AT + Vector2(0.0, LIST_ROW_HEIGHT * float(index)),
			LIST_WIDTH, index, shown, _rows)


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
