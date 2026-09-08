class_name ItemListScreen
extends CampaignScreen

## *Item List* -- `Menu_b.lcl`'s `:ItemList;`, window 5, the catalogue the
## Upgrade screen's *Select Weapon* and *Select Equipment* buttons open.
##
## It is a **chooser, not a till**: picking a row here names the item the
## Upgrade screen then shows in its right-hand window, and *Buy Item* over
## there is what spends anything. That is the original's shape -- window 5 has
## no purchase button at all, only *Toggle List* and *Back*.
##
## Two numbers per row, and neither is a plain column of the balance table:
##
## * `Cost` is `+0x20` of the equipment record or `+0x3E` of the weapon's;
## * `Skills` is what the item costs **this soldier** -- the shortfall
##   `0x0047A6E0` / `0x0047A600` computes against their own six skills
##   ([Upgrade]) -- so the same rifle reads 3 for a recruit and 0 for the
##   veteran who already trained on it.
##
## A row the soldier cannot be given now is drawn dim rather than hidden: the
## engine greys the purchase (`0x0045A170` refuses when
## `rec[+0x18] < cost * 12`) and leaves the row where it is, and a catalogue
## that hid what is out of reach would make a tech level that never rises
## indistinguishable from a working one (docs/27 section 5.2).

const ID_TITLE: int = 150
const ID_TOGGLE: int = 3
const ID_POINTS: int = 153
const ID_SKILL_POINTS: int = 154
const ID_COST: int = 92
const ID_SKILLS: int = 91

## `GUI_SetButton (1, ..., 003_WinText, 410_x, 384_y)` and
## `(0, ..., 002_WinText, 410_x, 416_y)`.
const TOGGLE_AT: Vector2 = Vector2(410.0, 384.0)
const BACK_AT: Vector2 = Vector2(410.0, 416.0)

## The two counters. The **`Format`** column is the alignment (`0x00439777`),
## not `cX`: `GUI_SetText (1/2_txtID, ..., 070_x, ..., 0_Format)` are
## left-aligned captions and `(3/4_txtID, ..., 210_x, ..., 2_Format)` are
## right-aligned values. All four carry `1_cX`, which is a different column
## and is what this once read.
const COUNTER_LABEL_X: float = 70.0
const COUNTER_VALUE_X: float = 210.0
const COUNTER_Y: Array[float] = [410.0, 425.0]

## The grid. `Menu_b.lcl` reserves no boxes for it -- the engine paints the
## rows itself -- so the two column origins and the row pitch are measured off
## the shipped screen and are the Unit Menu's own metrics, which is what they
## measure to.
const GRID_AT: Vector2 = Vector2(130.0, 70.0)
const GRID_COLUMN_STEP: float = 260.0
const GRID_ROW_HEIGHT: float = 30.0
## **Enough rows for the whole half, because the engine's painter has no
## bound.** `0x00459D10` steps the catalogue until the stepper runs out and
## lays each row down two columns -- `x` 80 then 330, wrapping at 500 with
## `y += 35` -- so nothing caps it and nothing scrolls; window 5 carries only
## *Toggle List* and *Back*. The widest half is equipment, whose ids run
## 0..20 (docs/27 section 5.2), so eleven rows of two hold every tech band
## there is. Eight fitted the shipped screen's tech-1 catalogue and silently
## dropped the rest of a fuller one.
const GRID_ROWS: int = 11
const GRID_COLUMNS: int = 2
## The two columns are **not** the same width on the shipped screen: the left
## rule runs 130..340 and the right 390..570, because the right column's
## picture stands between them.
const GRID_WIDTH: Array[float] = [210.0, 185.0]
## The item picture, left of its name -- as on the roster row.
const ICON_OFFSET: Vector2 = Vector2(-40.0, 2.0)
const ICON_SIZE: Vector2 = Vector2(36.0, 22.0)
const ROW_SECOND_LINE: float = 12.0
const ROW_SKILLS_X: float = 95.0

## The small inventory pictures, one per `icon` column.
const WEAPON_ICONS: String = "uweapons"
const EQUIPMENT_ICONS: String = "uequip"

## The remake's own line: the original never has an empty catalogue, because
## its tech level always admits something.
const OWN_EMPTY: String = "catalogue.empty"

var host: CampaignHost = null
## Which half of the catalogue is up -- [constant CampaignHost.KIND_WEAPONS] or
## [constant CampaignHost.KIND_EQUIPMENT].
var kind: String = CampaignHost.KIND_WEAPONS
## The roster slot the numbers are measured against.
var slot: int = Roster.NO_SLOT
var _grid: Control = null
var _counters: Control = null


func plate_name() -> String:
	return PLATE_MISSION_CONTROL


func plate_window() -> Rect2:
	return PLATE_WINDOW


func build() -> void:
	var _title: Label = place_title(label_for(BANK_MISSION, ID_TITLE))
	_grid = gui_layer()
	_counters = gui_layer()
	var _toggle: Button = gui_button("toggle", BANK_MISSION, ID_TOGGLE,
		TOGGLE_AT)
	var _back: Button = gui_button("back", BANK_MISSION, ID_BACK, BACK_AT)
	refresh()


func refresh() -> void:
	if host == null or host.state == null or _grid == null:
		return
	clear_children(_grid)
	clear_children(_counters)
	var unit: UnitState = host.state.roster.record(slot)
	_draw_counters(unit)
	var rows: Array[Dictionary] = host.catalogue_rows(kind, unit)
	if rows.is_empty():
		var _empty: Label = gui_text(strings_own(OWN_EMPTY),
			GRID_AT, ALIGN_LEFT, INK_LABEL, _grid)
		return
	for index: int in range(mini(rows.size(), GRID_ROWS * GRID_COLUMNS)):
		_draw_row(index, rows[index])


func _draw_counters(unit: UnitState) -> void:
	var points: int = host.state.points(0)
	var skills: int = Upgrade.skill_points(unit) if unit != null else 0
	var lines: Array[PackedStringArray] = [
		PackedStringArray([label_for(BANK_MISSION, ID_POINTS), str(points)]),
		PackedStringArray([label_for(BANK_MISSION, ID_SKILL_POINTS),
			str(skills)]),
	]
	for index: int in range(lines.size()):
		var y: float = COUNTER_Y[index]
		var pair: PackedStringArray = lines[index]
		var _caption: Label = gui_text(pair[0],
			Vector2(COUNTER_LABEL_X, y), ALIGN_LEFT, INK_LABEL, _counters)
		var _value: Label = gui_text(pair[1],
			Vector2(COUNTER_VALUE_X, y), ALIGN_RIGHT, INK_VALUE, _counters,
			FNT_VALUE)


func _draw_row(index: int, row: Dictionary) -> void:
	var column: int = index / GRID_ROWS
	var line: int = index % GRID_ROWS
	var at: Vector2 = GRID_AT + Vector2(float(column) * GRID_COLUMN_STEP,
		float(line) * GRID_ROW_HEIGHT)
	var id: int = DictRead.as_int(row["id"])
	var carried: bool = DictRead.as_bool(row["carried"])
	var affordable: bool = DictRead.as_bool(row["affordable"])

	var span: float = GRID_WIDTH[column]
	var hit: Button = make_button("item:%d" % id, "")
	hit.flat = true
	place_on_plate(hit, at + Vector2(ICON_OFFSET.x, 0.0),
		Vector2(span - ICON_OFFSET.x, GRID_ROW_HEIGHT))
	_grid.add_child(hit)

	var library: String = WEAPON_ICONS if kind == CampaignHost.KIND_WEAPONS \
		else EQUIPMENT_ICONS
	var _icon: TextureRect = gui_sprite(library, DictRead.as_int(row["icon"]),
		at + ICON_OFFSET, ICON_SIZE, _grid)
	# The original brackets what the soldier already has -- `* Light Armor *`
	# on the shipped screen -- and paints the rest in the catalogue's red.
	var shown: String = DictRead.as_string(row["name"])
	if carried:
		shown = "* %s *" % shown
	var _name: Label = gui_text(shown, at, ALIGN_LEFT,
		INK_ITEM if affordable or carried else INK_DISABLED, _grid)
	var _cost: Label = gui_text("%s %d" % [label_for(BANK_MISSION, ID_COST),
		DictRead.as_int(row["cost"])],
		at + Vector2(0.0, ROW_SECOND_LINE), ALIGN_LEFT, INK_LABEL, _grid)
	var _skills: Label = gui_text("%s %d" % [
		label_for(BANK_MISSION, ID_SKILLS), DictRead.as_int(row["skills"])],
		at + Vector2(ROW_SKILLS_X, ROW_SECOND_LINE), ALIGN_LEFT, INK_LABEL,
		_grid)
	var rule: ColorRect = ColorRect.new()
	rule.color = INK_DISABLED
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(rule, at + Vector2(0.0, GRID_ROW_HEIGHT - 1.0),
		Vector2(span, 1.0))
	_grid.add_child(rule)


## *Toggle List* -- the one button that changes what the window is a list of.
func toggle() -> void:
	kind = CampaignHost.KIND_EQUIPMENT \
		if kind == CampaignHost.KIND_WEAPONS else CampaignHost.KIND_WEAPONS
	refresh()
