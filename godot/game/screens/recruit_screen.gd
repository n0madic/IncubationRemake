class_name RecruitScreen
extends CampaignScreen

## *Select Soldier* -- `Menu_b.lcl`'s `:Recruit;`, window 9, `Txtmod_b` 180.
##
## **The campaign never reaches it, and that is the engine's own gate.**
## `0x0045B7F8` reads the game mode and, at mode 1, falls straight through to
## the direct hire at `0x0045B81F` -- `weapon[0].cost + 50`, then
## `aEnlargeUnitPool`. Only outside campaign mode, and only with `0x00509F10`
## set (*soft mode*, on by default at `0x0043AE38`), does it call this
## window's builder at `0x00456640`. So the Unit Menu's *Recruit unit* hires
## on the spot in a campaign, and this screen is what the other mode gets.
##
## **The rows are presets, not unit types** *(corrected 2026-09-13)*. The
## five buttons each write a list of numbers into `0x00510A14` (see
## [constant CATEGORY_TYPES]), and a click on a row hands its number to
## `0x00476260`, which builds a ready-made **type 0** soldier from it: a
## `Txtmod_h` name (140..163), a weapon and a bag of equipment bought through
## `aBuyWeapon`/`aBuyEquipment`, EP and FP by literal, HP from the ceiling,
## and a price that is the items' costs plus a per-preset markup. Reading the
## numbers as `Info.lcl` unit types offered *Human Soldier (2)* and three
## aliens here, and hired a type-1 soldier for player 0 -- a unit the model
## selector has no body for. The presets come out of the cache's
## `campaign.json` (`campaign_tables.py`'s `preset.*` checks read them back
## out of the executable); [method CampaignHost.recruit_preset] hires one.
##
## The purse gate is the row painter's, not the category arm's: `0x00455C00`
## compares the preset's cost against the purse (`0x00455EDF`) and paints an
## unaffordable row red with its gadget disabled. The same here, with the
## hire's own refusal spoken as well.

const ID_TITLE: int = 180
const ID_FIRST_CATEGORY: int = 181
const ID_POINTS: int = 83
const ID_PLACEFIELDS: int = 87
const ID_IN_SQUAD: int = 89
const ID_PLACEFIELDS_VALUE: int = 87
## The remake's own line for the row's price and load-out.
const OWN_PRICE: String = "recruit.price"
## `recruit.<result>` for a hire the engine would refuse silently.
const OWN_REFUSAL: String = "recruit.%s"
## Where the refusal is written: under the rows, left of the counters.
const MESSAGE_AT: Vector2 = Vector2(80.0, 380.0)

## `GUI_SetButton (20..24, ..., 181..185_WinText, 410_x, 070+40i_y)`.
const CATEGORY_AT: Vector2 = Vector2(410.0, 70.0)
const CATEGORY_STEP: float = 40.0
## **Five explicit lists of preset ids, not five bases.** `0x0045615F` clears
## all five slots of `0x00510A14` to -1 and disables the five row gadgets,
## then `0x004561C9`'s jump table fills the slots for the chosen category,
## one `mov dword [0x510A14 + 4k], imm32` per row. Reading them off gives
## twenty-three writes, not twenty-five: **categories 0 and 2 fill four
## slots and leave the fifth at -1**, and category 3's fifth is **35, not
## 34** (34, *Heavy Energy Unit*, has a name in `Txtmod_h` and no arm in the
## builder).
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
var _message: Label = null


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
	_message = gui_text("", MESSAGE_AT, ALIGN_LEFT, INK_LABEL)
	refresh()


## The refusal line under the rows; cleared by the next redraw.
func say(line: String) -> void:
	if _message != null:
		_message.text = line


func refresh() -> void:
	if host == null or host.state == null or _rows == null:
		return
	clear_children(_rows)
	clear_children(_counters)
	if _message != null:
		_message.text = ""
	_draw_counters()
	var candidates: PackedInt32Array = presets_in(category)
	if candidates.is_empty():
		var _empty: Label = gui_text(strings_own(OWN_EMPTY),
			Vector2(ROW_TEXT_X, ROW_MARK_AT.y), ALIGN_LEFT, INK_LABEL, _rows)
		return
	for index: int in range(candidates.size()):
		_draw_row(index, candidates[index])


## The preset ids one category offers, skipping any the cache does not carry.
func presets_in(which: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if host == null:
		return out
	for id: int in category_types(which):
		if not host.preset(id).is_empty():
			out.append(id)
	return out


## `Txtmod_b` 83/87/89 -- the three counters the shipped window prints; the
## placefield count is the map's, `?` off the roster with no map behind it.
func _draw_counters() -> void:
	var cells: Array[Vector2i] = host.deployment_cells()
	var lines: Array[PackedStringArray] = [
		PackedStringArray([label_for(BANK_MISSION, ID_POINTS),
			str(host.state.points(0))]),
		PackedStringArray([label_for(BANK_MISSION, ID_PLACEFIELDS),
			str(cells.size()) if not cells.is_empty() else "?"]),
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


## One preset: its name, and under it what it carries and what it costs.
func _draw_row(index: int, id: int) -> void:
	var top: float = ROW_MARK_AT.y + float(index) * ROW_STEP
	# `0x00455EDF`: a row the purse cannot cover is painted in the alert ink
	# and its gadget stays disabled.
	var offered: bool = host.preset_affordable(id)
	var hit: Button = row_hit("hire:%d" % id,
		Rect2(Vector2(ROW_TEXT_X, top - 8.0),
			Vector2(ROW_MARK_AT.x - ROW_TEXT_X, ROW_STEP - 8.0)), _rows)
	hit.disabled = not offered
	var _name: Label = gui_text(host.preset_name(id),
		Vector2(ROW_TEXT_X, top), ALIGN_LEFT,
		INK_ROSTER if offered else INK_ITEM, _rows)
	var _stats: Label = gui_text(load_out_line(id),
		Vector2(ROW_TEXT_X, top + ROW_SECOND_LINE), ALIGN_LEFT,
		INK_LABEL if offered else INK_ITEM, _rows)
	var _mark: TextureRect = gui_sprite(Art.BUTTON_LIBRARY, ROW_MARK_INDEX,
		Vector2(ROW_MARK_AT.x, top), Vector2.ZERO, _rows)


## `price -- weapon, item, item`, the row's second line.
func load_out_line(id: int) -> String:
	var preset: Dictionary = host.preset(id)
	var names: PackedStringArray = PackedStringArray()
	names.append(DictRead.as_string(host.row_for(CampaignHost.KIND_WEAPONS,
		DictRead.as_int(preset.get("weapon", 0))).get("name", "")))
	for item: int in DictRead.to_int32(
			preset.get("equipment", PackedInt32Array())):
		names.append(DictRead.as_string(host.row_for(
			CampaignHost.KIND_EQUIPMENT, item).get("name", "")))
	return strings_own(OWN_PRICE) % [host.preset_price(id),
		", ".join(names)]


## One of the five buttons.
func choose(which: int) -> void:
	category = clampi(which, 0, CATEGORY_TYPES.size() - 1)
	refresh()
