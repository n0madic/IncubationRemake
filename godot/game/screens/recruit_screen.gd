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
## What the five buttons choose is a **list of unit types**, and the list is
## written out slot by slot: `0x0045615F` clears the five slots of
## `0x00510A14` to -1 and disables the five row gadgets, and `0x004561C9`'s
## jump table then fills the chosen category's, one
## `mov dword [0x510A14 + 4k], imm32` per row and each behind its own
## affordability test (an unaffordable type is left at -1 and its gadget
## stays disabled). See [constant CATEGORY_TYPES].
##
## And the shipped table mostly has nothing there. `Info.lcl` declares unit
## types 0..3, 20..26, 30..35 and 50..68, so *Light Units* offers the four
## `Human Soldier` variants, *Heavy Units* the four records at 20..23, and
## *Commanders* nothing at all -- the engine lists 40..44 there and `Info.lcl`
## declares none of them. That is what the data says; the screen shows the
## empty categories rather than hiding them, for the same reason the Upgrade
## screen shows what the tech level locks.

const ID_TITLE: int = 180
const ID_FIRST_CATEGORY: int = 181
const ID_POINTS: int = 83
const ID_PLACEFIELDS: int = 87
const ID_IN_SQUAD: int = 89
const ID_COST: int = 92

## `GUI_SetButton (20..24, ..., 181..185_WinText, 410_x, 070+40i_y)`.
const CATEGORY_AT: Vector2 = Vector2(410.0, 70.0)
const CATEGORY_STEP: float = 40.0
## **Five explicit lists, not five bases.** `0x0045615F` clears all five slots
## of `0x00510A14` to -1 and disables the five row gadgets, then
## `0x004561C9`'s jump table fills the slots for the chosen category, one
## `mov dword [0x510A14 + 4k], imm32` per row and each behind its own
## affordability test. Reading them off gives twenty-three writes, not
## twenty-five: **categories 0 and 2 fill four slots and leave the fifth at
## -1**, and category 3's fifth is **35, not 34**. A `base + 0..4` reading --
## which is what this was, with 30 guessed and marked UNVERIFIED -- offered
## type 24 that the engine never lists and hid type 35 that it does.
const CATEGORY_TYPES: Array[Array] = [
	[0, 1, 2, 3],
	[10, 11, 12, 13, 14],
	[20, 21, 22, 23],
	[30, 31, 32, 33, 35],
	[40, 41, 42, 43, 44],
]


## One category's list, narrowed. A `PackedInt32Array` cannot be a constant
## expression, so the table above is plain arrays and this is the boundary.
static func category_types(which: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for value: Variant in CATEGORY_TYPES[clampi(which, 0,
			CATEGORY_TYPES.size() - 1)]:
		out.append(DictRead.as_int(value))
	return out

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
	# The same backing the other two lists take: this one is written across
	# the base's 3D scene as well.
	var _backing: ColorRect = shade(plate_window())
	_rows = gui_layer()
	_counters = gui_layer()
	for index: int in range(CATEGORY_TYPES.size()):
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
	for type_id: int in category_types(which):
		var row: Dictionary = host.row_for("units", type_id)
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
	var _hit: Button = row_hit("hire:%d" % id,
		Rect2(Vector2(ROW_TEXT_X, top - 8.0),
			Vector2(ROW_MARK_AT.x - ROW_TEXT_X, ROW_STEP - 8.0)), _rows)
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
	category = clampi(which, 0, CATEGORY_TYPES.size() - 1)
	refresh()
