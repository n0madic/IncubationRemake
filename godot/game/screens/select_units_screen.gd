class_name SelectUnitsScreen
extends CampaignScreen

## `SelectUnits` -- the deploy screen, docs/27 section 3.4's
## `aTransferUnitFromPoolToMap` and docs/29 section 1.2's cells.
##
## **The squad is put on the map, not into a list.** It used to be two columns
## of buttons -- names on the left, `x, y` pairs on the right -- and a player
## was expected to read a coordinate rather than look at the place. Now the
## plate is a frame around the mission's own view, every free deployment cell
## carries one of the shipped `map.LIB` dots, and a click on the map places the
## soldier the squad row has selected. That is what the original does and it is
## why the original never needed a word of explanation.
##
## What survives from the list version is the **spoken refusal** (docs/92
## section 7.4): a click on a cell with nobody picked, and *Continue* with an
## empty map, both say why. The original does not need the words because its
## screen is a picture of the map with the squad standing on it -- this one is
## too, now, but a refusal that says nothing is still a defect.

## The remake's own, because this screen's silences are the remake's own too.
const OWN_HINT: String = "deploy.hint"
const OWN_PICK_FIRST: String = "deploy.pick_a_soldier"
const OWN_NEED_ONE: String = "deploy.need_one"
## `deploy.<result>` for each of [World]'s refusal names.
const OWN_REFUSAL: String = "deploy.%s"

const ID_TITLE: int = 13
const ID_IN_SQUAD: int = 89

## **The mission's own 3D window**, `(60, 34)` by 520 x 340, which
## `0x00419D90` sets with `0x0040B670` and keeps in `0x004FE330…0x004FE33C`.
## Deployment is the mission's view with a caption over it, so it is that
## rectangle and not the campaign screens' smaller one; the squad row and the
## message line live between it and the action row.
const DEPLOY_WINDOW: Rect2 = Rect2(60.0, 34.0, 520.0, 340.0)
## The line under the window: the count on the left, what the last click meant
## across the rest of it. They shared the whole width once and the hint was
## written through the middle of the count.
const MESSAGE_TOP: float = 378.0
const MESSAGE_HEIGHT: float = 18.0
const COUNT_WIDTH: float = 150.0
## The line's size when the readable face is in use.
const MESSAGE_FONT_SIZE: int = 12
const SQUAD_TOP: float = 398.0
const SQUAD_HEIGHT: float = 22.0
const SQUAD_MARGIN: float = 46.0
const SQUAD_GAP: float = 4.0
## The squad row's caption size when the readable face is in use: ten names
## across 548 units is 55 units each.
const SQUAD_FONT_SIZE: int = 11

var host: CampaignHost = null
## The mission's briefing document and where the fonts are, for the short
## briefing `B0` the unit-selection screen types out at (220, 120) --
## `0x0044EEDA`, `animate = 0` (docs/24 section 7.1). Empty for a mission the
## cache has no briefing for, and then no box is drawn.
var document: Dictionary = {}
var cache_dir: String = ""
## The roster slot the player picked, or [constant Roster.NO_SLOT].
var selected: int = Roster.NO_SLOT
## Instant Action has no location map. Its second action returns to the level
## catalogue; a campaign deployment keeps the shipped Main Map action.
var back_to_levels: bool = false

## The squad row and the line under it.
var _squad: Control = null
var _message: Label = null


func plate_window() -> Rect2:
	return DEPLOY_WINDOW


func build() -> void:
	var _title: Label = place_title(label_for(BANK_MISSION, ID_TITLE))

	_message = make_label(strings_own(OWN_HINT))
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font == null:
		_message.add_theme_font_size_override("font_size", MESSAGE_FONT_SIZE)
	place_on_plate(_message,
		Vector2(SQUAD_MARGIN + COUNT_WIDTH, MESSAGE_TOP),
		Vector2(PLATE_SIZE.x - 2.0 * SQUAD_MARGIN - COUNT_WIDTH,
			MESSAGE_HEIGHT))
	root().add_child(_message)

	# A plain [Control] for the same reason the action row is one: the squad
	# is up to ten names and a container would size them from their own
	# minimum and walk off the plate.
	_squad = Control.new()
	_squad.set_anchors_preset(Control.PRESET_FULL_RECT)
	_squad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root().add_child(_squad)

	# **No briefing box here.** The slice put `B0` over this view on the
	# strength of one row of docs/24 section 7.1's table, which named the
	# screen without reading the arm. `0x0044EEDA` is inside `aMenuSystem`'s
	# dispatcher `0x0044DCD0`, whose outer switch is on `Menu_a`'s window
	# selector `[0x50FDF8]` -- window **10** is `:Leveloptions;` and the
	# action that reaches it is gadget **22**, the button `Menu_a.lcl`
	# comments `* infos`. That is the multiplayer level-options screen, which
	# this remake does not have; `SelectUnits` is a `Menu_b` window and no
	# `aActivateBriefingInfo` site lies in its arm at all. The conditions are
	# on the briefing page, one screen back.

	add_button("start", BANK_MISSION, ID_CONTINUE, 0)
	add_button("instant_levels" if back_to_levels else "map", BANK_MISSION,
		ID_BACK if back_to_levels else ID_MAIN_MAP, 1)
	_lay_out_buttons()
	refresh()


func refresh() -> void:
	if host == null or host.state == null or _squad == null:
		return
	clear_children(_squad)
	var slots: PackedInt32Array = host.state.roster.occupied_slots()
	# **Somebody is always picked.** The one refusal a player could not
	# diagnose was clicking a cell with nobody selected, so the screen selects
	# the next soldier itself and the refusal is left for the case it means:
	# the squad is empty.
	if not slots.has(selected) and not slots.is_empty():
		selected = slots[0]
	if slots.is_empty():
		selected = Roster.NO_SLOT

	var count: Label = make_label("%s %d" % [
		label_for(BANK_MISSION, ID_IN_SQUAD), slots.size()])
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font == null:
		count.add_theme_font_size_override("font_size", MESSAGE_FONT_SIZE)
	place_on_plate(count, Vector2(SQUAD_MARGIN, MESSAGE_TOP),
		Vector2(COUNT_WIDTH, MESSAGE_HEIGHT))
	_squad.add_child(count)
	if slots.is_empty():
		return

	var span: float = PLATE_SIZE.x - 2.0 * SQUAD_MARGIN
	var width: float = (span - SQUAD_GAP * float(slots.size() - 1)) \
		/ float(slots.size())
	for index: int in range(slots.size()):
		var slot: int = slots[index]
		var unit: UnitState = host.state.roster.record(slot)
		if unit == null:
			continue
		var row: Button = make_button("pick:%d" % slot, unit.name)
		row.clip_text = true
		row.toggle_mode = true
		row.button_pressed = slot == selected
		if font == null:
			row.add_theme_font_size_override("font_size", SQUAD_FONT_SIZE)
		place_on_plate(row,
			Vector2(SQUAD_MARGIN + float(index) * (width + SQUAD_GAP),
				SQUAD_TOP),
			Vector2(width, SQUAD_HEIGHT))
		_squad.add_child(row)


## The free deployment cells, each carrying the original's own red dot.
static func marks_for(cells: Array[Vector2i]) -> Dictionary[Vector2i, int]:
	var out: Dictionary[Vector2i, int] = {}
	for cell: Vector2i in cells:
		out[cell] = MapMarkers.DOT_BATTLE
	return out


func takes_world_clicks() -> bool:
	return true


func world_click(cell: Vector2i) -> void:
	if host == null or cell.x < 0:
		return
	if selected == Roster.NO_SLOT:
		say(strings_own(OWN_PICK_FIRST))
		return
	var placed: Dictionary = host.deploy(selected, cell.x, cell.y)
	var outcome: String = DictRead.as_string(placed["result"])
	if outcome == World.DEPLOY_OK:
		selected = Roster.NO_SLOT
		say(strings_own(OWN_HINT))
		chose.emit("deployed")
	else:
		# [World]'s own refusal name, turned into a sentence. A name the
		# catalogue has no line for comes back as the marker rather than as a
		# blank, so a new refusal is visible instead of silent.
		say(strings_own(OWN_REFUSAL % outcome))
	refresh()


## Which soldier the next click places.
func pick(slot: int) -> void:
	selected = slot
	refresh()


## Put one line under the map. The host calls it too, for the refusal only
## it can see -- that a mission may not start with an empty map.
func say(line: String) -> void:
	if _message != null:
		_message.text = line
