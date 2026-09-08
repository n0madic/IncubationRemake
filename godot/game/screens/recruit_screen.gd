class_name RecruitScreen
extends CampaignScreen

## *Select Soldier* -- `Menu_b.lcl`'s `:Recruit;`, window 9, `Txtmod_b` 180.
##
## **The campaign never reaches it, and that is the engine's own gate.**
## `0x0045B7F8` reads the game mode and, at mode 1, falls straight through to
## the direct hire at `0x0045B81F` -- `weapon[0].cost + 50`, then
## `aEnlargeUnitPool`. Only outside campaign mode, and only with `0x00509F10`
## set, does it call this window's builder at `0x00456640`. So the Unit Menu's
## *Recruit unit* hires on the spot in a campaign, exactly as it did before
## this screen existed, and this screen is what the other mode gets.
##
## What the five buttons choose is a **base unit type**: `0x004561EB`,
## `0x00456292`, `0x00456362` and `0x004564DD` write 0, 10, 20 and 40 into
## `0x00510A14`, and the four slots after it take `base+1 .. base+4`, each
## filled only when the purse can afford it (`0x00456500` onward). The fifth
## category's base is written through a computed address rather than an
## immediate and is **UNVERIFIED**; 30 is what the spacing implies and is what
## is used, with the row simply empty when the table has nothing there.
##
## And the shipped table mostly has nothing there. `Info.lcl` declares unit
## types 0..3, 20..26, 30..35 and 50..68, so *Light Units* offers the four
## `Human Soldier` variants, *Heavy Units* the five records at 20..24, and
## *Commanders* nothing at all. That is what the data says; the screen shows
## the empty categories rather than hiding them, for the same reason the
## Upgrade screen shows what the tech level locks.

const ID_TITLE: int = 180
const ID_FIRST_CATEGORY: int = 181
const ID_POINTS: int = 83
const ID_PLACEFIELDS: int = 87
const ID_IN_SQUAD: int = 89
const ID_COST: int = 92

## `GUI_SetButton (20..24, ..., 181..185_WinText, 410_x, 070+40i_y)`.
const CATEGORY_AT: Vector2 = Vector2(410.0, 70.0)
const CATEGORY_STEP: float = 40.0
## `0x004561EB`, `0x00456292`, `0x00456362`, the unverified fourth, and
## `0x004564DD`.
const CATEGORY_BASES: Array[int] = [0, 10, 20, 30, 40]
## `0x00456500`..`0x00456571` fill four slots after the base.
const CATEGORY_SPAN: int = 5

## `GUI_SetIcon (00..04, 54_Library, 348_x, 080+60i_y)` -- the row markers.
const ROW_MARK_AT: Vector2 = Vector2(348.0, 80.0)
const ROW_STEP: float = 60.0
const ROW_MARK_INDEX: int = 54
## Where a candidate's two lines go, left of the marker.
const ROW_TEXT_X: float = 80.0
const ROW_SECOND_LINE: float = 16.0

const COUNTER_LABEL_X: float = 540.0
const COUNTER_VALUE_X: float = 550.0
const COUNTER_Y: Array[float] = [307.0, 326.0, 345.0]

const BACK_AT: Vector2 = Vector2(410.0, 399.0)

## The remake's own line for an empty category.
const OWN_EMPTY: String = "recruit.empty"

var host: CampaignHost = null
## Which of the five buttons is down, 0..4.
var category: int = 0

var _rows: Control = null
var _counters: Control = null


func plate_name() -> String:
	return PLATE_MISSION_CONTROL


func plate_window() -> Rect2:
	return PLATE_WINDOW


func build() -> void:
	var _title: Label = place_title(label_for(BANK_MISSION, ID_TITLE))
	_rows = gui_layer()
	_counters = gui_layer()
	for index: int in range(CATEGORY_BASES.size()):
		var _pick: Button = gui_button("category:%d" % index, BANK_MISSION,
			ID_FIRST_CATEGORY + index,
			CATEGORY_AT + Vector2(0.0, float(index) * CATEGORY_STEP))
	var _back: Button = gui_button("back", BANK_MISSION, ID_BACK, BACK_AT)
	refresh()


func refresh() -> void:
	if host == null or host.state == null or _rows == null:
		return
	clear_children(_rows)
	clear_children(_counters)
	_draw_counters()
	var candidates: Array[Dictionary] = types_in(category)
	if candidates.is_empty():
		var _empty: Label = gui_text(strings_own(OWN_EMPTY),
			Vector2(ROW_TEXT_X, ROW_MARK_AT.y), ALIGN_LEFT, INK_LABEL, _rows)
		return
	for index: int in range(candidates.size()):
		_draw_row(index, candidates[index])


## The unit types one category offers -- `base .. base + 4`, skipping the ids
## the shipped table has no record for.
func types_in(which: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if host == null:
		return out
	var base: int = CATEGORY_BASES[clampi(which, 0,
		CATEGORY_BASES.size() - 1)]
	for offset: int in range(CATEGORY_SPAN):
		var row: Dictionary = host.row_for("units", base + offset)
		if row.is_empty():
			continue
		if DictRead.as_string(row["description"]) == "":
			continue
		out.append(row)
	return out


func _draw_counters() -> void:
	var lines: Array[PackedStringArray] = [
		PackedStringArray([label_for(BANK_MISSION, ID_POINTS),
			str(host.state.points(0))]),
		PackedStringArray([label_for(BANK_MISSION, ID_COST),
			str(host.state.recruit_cost())]),
		PackedStringArray([label_for(BANK_MISSION, ID_IN_SQUAD),
			str(host.state.roster.used_slots())]),
	]
	for index: int in range(lines.size()):
		var y: float = COUNTER_Y[index]
		var pair: PackedStringArray = lines[index]
		var _caption: Label = gui_text(pair[0],
			Vector2(COUNTER_LABEL_X, y), ALIGN_RIGHT, INK_LABEL, _counters)
		var _value: Label = gui_text(pair[1],
			Vector2(COUNTER_VALUE_X, y), ALIGN_LEFT, INK_VALUE, _counters, FNT_VALUE)


func _draw_row(index: int, row: Dictionary) -> void:
	var top: float = ROW_MARK_AT.y + float(index) * ROW_STEP
	var id: int = DictRead.as_int(row["id"])
	var hit: Button = make_button("hire:%d" % id, "")
	hit.flat = true
	place_on_plate(hit, Vector2(ROW_TEXT_X, top - 8.0),
		Vector2(ROW_MARK_AT.x - ROW_TEXT_X, ROW_STEP - 8.0))
	_rows.add_child(hit)
	var _name: Label = gui_text(DictRead.as_string(row["description"]),
		Vector2(ROW_TEXT_X, top), ALIGN_LEFT, INK_ROSTER, _rows)
	var _stats: Label = gui_text("HP %d   MP %d" % [
		DictRead.as_int(row["hp_max"]), DictRead.as_int(row["mp_max"])],
		Vector2(ROW_TEXT_X, top + ROW_SECOND_LINE), ALIGN_LEFT, INK_LABEL,
		_rows)
	var _mark: TextureRect = gui_sprite(Art.BUTTON_LIBRARY, ROW_MARK_INDEX,
		Vector2(ROW_MARK_AT.x, top), Vector2.ZERO, _rows)


## One of the five buttons.
func choose(which: int) -> void:
	category = clampi(which, 0, CATEGORY_BASES.size() - 1)
	refresh()
