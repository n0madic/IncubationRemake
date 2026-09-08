class_name UnitMenuScreen
extends CampaignScreen

## *Unit Menu* -- window 4, the screen `Txtmod_b` 70 names.
##
## **This window has no layout program.** `Menu_b.lcl`'s selector carries
## `EnvVarCmpNum(_A_WindowSelector, 04_SelectUnits); Goto(SelectUnits);` and
## the file defines no such label -- nor one for `WaitForPlayers` -- so two of
## the twelve windows the selector names are not in the shipped data at all.
## Every coordinate below is therefore **measured off the shipped screen**, not
## read out of the LCL, and is marked UNVERIFIED as a group: the captions are
## the original's and the geometry is this remake's reading of a screenshot.
##
## **This is the roster, not the deployment map.** The two are easy to conflate
## because the window is called `SelectUnits`: the original's placing of
## soldiers on the map is `aPI.cpp`, a different module entirely
## (docs/29 section 1.3), and [SelectUnitsScreen] is the remake's screen for
## *that*. What this one does is what docs/27 section 3.2 and 3.3 describe --
## hire, dismiss, and pick whose equipment the Upgrade screen will change.
##
## The list is nine rows of 30 at `(130, 70)`, the scroll arrows are
## `buttons.LIB` 30 and 32 at `(425, 65)` and `(425, 98)`, and the three
## counters are right-aligned at 540 with their values at 550 -- the same
## pairing the *Recruit* window does write down.
##
## The plate is `plate_3` with the frame's window left clear, because that is
## what the original shows: Mission Control loads that plate once at
## `aInitGUI` and this window loads none of its own, so the 3D scene behind it
## is visible through the inset.

## `Txtmod_b`, the bank docs/27 section 1.2 names for these screens.
const ID_TITLE: int = 70
const ID_RECRUIT: int = 81
const ID_POINTS: int = 83
const ID_PLACEFIELDS: int = 87
const ID_IN_SQUAD: int = 89
const ID_SKILLS: int = 91
const ID_EXP: int = 93
const ID_UNDO: int = 134
const ID_BUILD_SQUAD: int = 12

## The rows, measured: nine of 30 from `(130, 70)`, 240 wide.
const LIST_AT: Vector2 = Vector2(130.0, 70.0)
const ROSTER_ROW_HEIGHT: float = 30.0
const LIST_WIDTH: float = 240.0
const LIST_ROWS: int = 9
## The weapon icon sits left of the box; the original draws it inside the row's
## own paint rather than through the layout table, so its x is measured off the
## shipped screen rather than read out of `Menu_b.lcl`.
const ICON_AT: Vector2 = Vector2(84.0, 2.0)
const ICON_SIZE: Vector2 = Vector2(42.0, 20.0)
## Where the second line of a row starts, and where `Exp` sits on it.
const ROW_SECOND_LINE: float = 12.0
const ROW_EXP_X: float = 60.0
## One per row at `x = 395`, and `buttons.LIB` 52 is a **red cross**: the
## button that takes that soldier off
## the squad. The screen therefore dismisses per row rather than through the
## selection, and the *Undo* button below puts the whole row back.
const DROP_X: float = 395.0
const DROP_Y: float = 79.0
const DROP_INDEX: int = 52

## The two scroll arrows, `buttons.LIB` 30 over 32.
const UP_AT: Vector2 = Vector2(425.0, 65.0)
const DOWN_AT: Vector2 = Vector2(425.0, 98.0)
const UP_INDEX: int = 30
const DOWN_INDEX: int = 32

## The three counters: caption right-aligned at 540, value left at 550.
const COUNTER_LABEL_X: float = 540.0
const COUNTER_VALUE_X: float = 550.0
const COUNTER_Y: Array[float] = [307.0, 326.0, 345.0]

const RECRUIT_AT: Vector2 = Vector2(410.0, 385.0)
const DISMISS_AT: Vector2 = Vector2(55.0, 385.0)
const BACK_AT: Vector2 = Vector2(410.0, 418.0)
## **The remake's own placement of a shipped button.** `Build squad`
## (`Txtmod_b` 12) belongs to the HQ window, which this shell does not raise:
## the campaign map opens the Unit Menu directly. The caption is the original's
## and the corner is the one `Menu_b.lcl` leaves empty on this window.
const UPGRADE_AT: Vector2 = Vector2(55.0, 418.0)

## The library the roster row's weapon picture comes from -- the small
## inventory icons, not the 30-frame turntables the Upgrade screen uses.
const WEAPON_ICON_LIBRARY: String = "uweapons"

## The remake's own line, for the one thing the original never has to say.
const OWN_EMPTY: String = "roster.empty"

var host: CampaignHost = null
## The roster **slot** the player picked, or [constant Roster.NO_SLOT]. A slot
## and not a row: `0x00478630`'s sort moves records between slots, so a screen
## that remembered a row would sell a different soldier after a sort
## (docs/29 section 1.4).
var selected: int = Roster.NO_SLOT
## The first roster slot the list shows, stepped by the two arrows.
var first_row: int = 0

## What *Undo* puts back: the live row and the purse as they stood before the
## last hire or dismissal. A hire or a dismissal moves every slot after it
## (`aRemoveUnitFromUnitPool` compacts), so there is nothing narrower to undo.
var _saved: Array[UnitState] = []
var _saved_points: int = 0

var _rows: Control = null
var _counters: Control = null


func plate_name() -> String:
	return PLATE_MISSION_CONTROL


func plate_window() -> Rect2:
	return PLATE_WINDOW


func build() -> void:
	var _title: Label = place_title(label_for(BANK_MISSION, ID_TITLE))
	# Under everything else: the roster and the three counters are both
	# written across the base's 3D scene.
	var _backing: ColorRect = shade(plate_window())
	_rows = gui_layer()
	_counters = gui_layer()
	var _up: Button = gui_icon("scroll_up", UP_INDEX, UP_AT)
	var _down: Button = gui_icon("scroll_down", DOWN_INDEX, DOWN_AT)
	var _hire: Button = gui_button("recruit", BANK_MISSION, ID_RECRUIT,
		RECRUIT_AT)
	var _fire: Button = gui_button("roster_undo", BANK_MISSION, ID_UNDO,
		DISMISS_AT)
	var _up_screen: Button = gui_button("upgrade", BANK_MISSION,
		ID_BUILD_SQUAD, UPGRADE_AT)
	var _back: Button = gui_button("map", BANK_MISSION, ID_BACK, BACK_AT)
	refresh()


## Redraw the list and the three counters. Called after every hire and every
## dismissal, because both renumber the slots.
func refresh() -> void:
	if host == null or host.state == null or _rows == null:
		return
	clear_children(_rows)
	clear_children(_counters)
	var slots: PackedInt32Array = host.state.roster.occupied_slots()
	# A dismissal can leave the window past the end of a shortened roster.
	first_row = clampi(first_row, 0, maxi(0, slots.size() - LIST_ROWS))
	if not slots.has(selected):
		selected = slots[0] if not slots.is_empty() else Roster.NO_SLOT
	_draw_counters(slots.size())
	if slots.is_empty():
		var empty: Label = gui_text(strings_own(OWN_EMPTY),
			LIST_AT + Vector2(0.0, 4.0), ALIGN_LEFT, INK_LABEL, _rows)
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return
	for index: int in range(LIST_ROWS):
		var at: int = first_row + index
		if at >= slots.size():
			break
		_draw_row(index, slots[at])


func _draw_counters(in_squad: int) -> void:
	var state: CampaignState = host.state
	# `Grid positions on map:` is the deployment ring's size, which only a
	# built mission knows. On the roster screen there is none, and the
	# original prints its own placeholder rather than a zero -- the shipped
	# screen reads `?` there.
	var lines: Array[PackedStringArray] = [
		PackedStringArray([label_for(BANK_MISSION, ID_POINTS),
			str(state.points(0))]),
		PackedStringArray([label_for(BANK_MISSION, ID_PLACEFIELDS),
			_placefields()]),
		PackedStringArray([label_for(BANK_MISSION, ID_IN_SQUAD),
			str(in_squad)]),
	]
	for index: int in range(lines.size()):
		var y: float = COUNTER_Y[index]
		var pair: PackedStringArray = lines[index]
		var _caption: Label = gui_text(pair[0],
			Vector2(COUNTER_LABEL_X, y), ALIGN_RIGHT, INK_LABEL, _counters)
		var _value: Label = gui_text(pair[1],
			Vector2(COUNTER_VALUE_X, y), ALIGN_LEFT, INK_VALUE, _counters, FNT_VALUE)


## `Txtmod_b` 21 is the placeholder the shipped screen prints when there is no
## map to count landing cells on -- and the roster screen never has one.
func _placefields() -> String:
	var cells: Array[Vector2i] = host.deployment_cells()
	return str(cells.size()) if not cells.is_empty() else "?"


func _draw_row(index: int, slot: int) -> void:
	var unit: UnitState = host.state.roster.record(slot)
	if unit == null:
		return
	var top: float = LIST_AT.y + float(index) * ROSTER_ROW_HEIGHT
	# The whole row is the click target, drawn flat so the plate shows through
	# and the row reads as text rather than as a widget -- but it lights under
	# the pointer, and the chosen one stays lit.
	var _hit: Button = row_hit("pick:%d" % slot,
		Rect2(Vector2(ICON_AT.x, top),
			Vector2(LIST_WIDTH + LIST_AT.x - ICON_AT.x, ROSTER_ROW_HEIGHT)),
		_rows, slot == selected)

	var weapon: Dictionary = host.row_for(CampaignHost.KIND_WEAPONS,
		unit.weapon)
	if not weapon.is_empty():
		var _icon: TextureRect = gui_sprite(WEAPON_ICON_LIBRARY,
			DictRead.as_int(weapon["icon"]),
			Vector2(ICON_AT.x, top + ICON_AT.y), ICON_SIZE, _rows)
	# **The hero's mark, and it is the remake's own.** No format string in
	# `Incubation.exe` appends a star to a unit's name: the only `"* %s *"` is
	# `0x004CAAD0`, which `0x0045A476` and `0x0045A645` use for an item the
	# soldier already **carries**, and that is the Item List's marker rather
	# than a roster one. So this is not the original's star -- it is kept
	# because `pool_flag == 2` is real (docs/27 section 3.1 seeds it on Bratt)
	# and this window has nothing else that says so. Which row is *chosen* is
	# the lit backing under it now, not the star.
	var star: String = " *" if unit.pool_flag == UnitState.HERO_POOL_FLAG else ""
	var _name: Label = gui_text(unit.name + star, Vector2(LIST_AT.x, top),
		ALIGN_LEFT, INK_VALUE if slot == selected else INK_ROSTER, _rows)
	var _skills: Label = gui_text("%s %d" % [
		label_for(BANK_MISSION, ID_SKILLS), Upgrade.skill_points(unit)],
		Vector2(LIST_AT.x, top + ROW_SECOND_LINE), ALIGN_LEFT, INK_LABEL,
		_rows)
	var _exp: Label = gui_text("%s %d" % [
		label_for(BANK_MISSION, ID_EXP), unit.ep],
		Vector2(LIST_AT.x + ROW_EXP_X, top + ROW_SECOND_LINE), ALIGN_LEFT,
		INK_LABEL, _rows)
	var rule: ColorRect = ColorRect.new()
	rule.color = INK_DISABLED
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(rule, Vector2(LIST_AT.x, top + ROSTER_ROW_HEIGHT - 1.0),
		Vector2(LIST_WIDTH, 1.0))
	_rows.add_child(rule)
	# `GUI_SetIcon` again, so it lights under the pointer like every other one:
	# `buttons.LIB` 52 is the cross and 53 is the same cross lit.
	var _drop: Button = gui_icon("drop:%d" % slot, DROP_INDEX,
		Vector2(DROP_X, DROP_Y + float(index) * ROSTER_ROW_HEIGHT), _rows)


## Which soldier the Upgrade screen will open on.
func pick(slot: int) -> void:
	selected = slot
	refresh()


## The two arrows, `0x00478630`'s list stepped by one row.
func scroll(by: int) -> void:
	first_row += by
	refresh()


## Remember the roster before a hire or a dismissal, so *Undo* has something
## to put back.
func remember() -> void:
	if host == null or host.state == null:
		return
	_saved = host.state.roster.records()
	_saved_points = host.state.points(0)


## *Undo* -- `Txtmod_b` 134, the same caption the Upgrade screen gives its own
## snapshot restore.
func undo() -> void:
	if host == null or host.state == null or _saved.is_empty():
		return
	host.state.restore_roster(0, _saved, _saved_points)
	_saved = []
	refresh()
