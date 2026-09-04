class_name CampaignMapScreen
extends CampaignScreen

## The location map -- docs/27 section 2.
##
## `_C_XXX` and `_C_YYY` are ordinary `.lev` files of map type 4 and the
## existing renderer draws them (D3); their `.lcl` is **not** run, because a
## campaign map's script is the original front end's and this remake's flow is
## its own.
##
## **The map is the picture, not a list.** It used to be a column of buttons
## on a full plate, with the 3D map that carries the locations never drawn at
## all. Now the plate is a frame around a hole, [SliceMain] renders the chain's
## own map behind it, and each open location is a dot standing on the cell
## whose action point is its id -- which is what docs/27 section 2.1 says a
## location *is*. Clicking the map is `aLocationHandling`.
##
## `Campaign.lcl` names all 110 locations, which is why not one caption here is
## a literal: the name of whatever the pointer is over is written along the
## bottom of the frame.

const ID_TITLE: int = 140
const ID_ENTER: int = 141
const ID_DIALOGUE: int = 145
const ID_HQ: int = 70
const ID_SAVE: int = 19
## `Txtmod_b` 18 -- *End game*, which the original puts on this bar beside
## *Save game*.
const ID_END_GAME: int = 18
## `Txtmod_b` 83 -- *Equipment points:*, the one number the map is worth
## showing when the pointer is over nothing.
const ID_POINTS: int = 83
## The one button on this plate that cannot be undone.
const END_GAME: String = "end_game"
## What a row of the no-picture list carries. Not an action the host sees:
## [method _on_pressed] turns it into the same call a click on a dot makes.
const GO: String = "go:"

## The no-picture list: one row per open location, down the middle of the
## plate. In the plate's own units.
const LIST_AT: Vector2 = Vector2(160.0, 70.0)
const LIST_SIZE: Vector2 = Vector2(320.0, 24.0)
const LIST_STEP: float = 28.0

## Where the campaign's purse is written, in the plate's own units: on the
## bottom band, above the action row.
const CAPTION_TOP: float = 394.0
const CAPTION_HEIGHT: float = 22.0
## Where the location under the pointer is named: **at the top**, just inside
## the window, over the sky. It shared the bottom band with the purse and the
## button captions once and could not be told from either.
const NAME_TOP: float = 62.0
const NAME_HEIGHT: float = 22.0

## `GUI\plate_3.bmp`, which is the plate `aMissionControl.cpp` puts the
## campaign screens on: `aInitGUI` at `0x00454245` on the way in and
## `0x004576C2` again for the map. It is the one shipped plate with a picture
## frame inset in it, and [constant CampaignScreen.PLATE_WINDOW] is that
## frame's own interior -- so the hole and the art that surrounds it come from
## the same place instead of one being fitted to the other.
const PLATE_MAP: String = "plate_3"

var host: CampaignHost = null

## Whether [SliceMain] has a picture to put behind the frame. False when the
## cache carries no campaign map, and then the plate is drawn whole and the
## screen is the list of open locations it was before the picture existed.
var has_picture: bool = false

## location -> the cell it stands on, filled by [SliceMain] out of the map the
## backdrop was built from. Empty until then, and a screen with none simply
## shows no dots -- which is what a suite building it with no tree gets.
var location_cells: Dictionary[int, Vector2i] = {}

var _caption: Label = null
var _name: Label = null
## The location the pointer is over, or -1. The host reads it to put the ring
## on the map.
var hovered: int = -1


func plate_name() -> String:
	return PLATE_MAP


## A frame around the chain's own map.
##
## Empty when there is no map behind it: a cache published without
## `--campaign-maps` carries no `_C_XXX`/`_C_YYY`, and a hole cut for a
## picture that is not there is a black rectangle where the plate's own frame
## should be. [SliceMain] clears this by leaving [member has_picture] false.
func plate_window() -> Rect2:
	return PLATE_WINDOW if has_picture else Rect2()


func build() -> void:
	var _title: Label = place_title(label_for(BANK_MISSION, ID_TITLE))

	_caption = make_label("")
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(_caption, Vector2(0.0, CAPTION_TOP),
		Vector2(PLATE_SIZE.x, CAPTION_HEIGHT))
	root().add_child(_caption)

	_name = make_label("")
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(_name, Vector2(0.0, NAME_TOP),
		Vector2(PLATE_SIZE.x, NAME_HEIGHT))
	root().add_child(_name)

	if not has_picture:
		_show_location_list()

	_show_actions()
	refresh()


## The way in when there is no map to click.
##
## A cache published without `--campaign-maps` carries no `_C_XXX`/`_C_YYY`,
## so there is nothing to draw and nothing to point at. Leaving the plate whole
## and the screen empty would make every open location unreachable, which
## docs/92 section 7.1 counts as the defect it is; the list is what this screen
## was before the picture existed.
func _show_location_list() -> void:
	if host == null or host.state == null:
		return
	var index: int = 0
	for id: int in host.open_locations():
		var row: Button = make_button(GO + str(id),
			label_for(BANK_LOCATIONS, id))
		root().add_child(row)
		place_on_plate(row, LIST_AT + Vector2(0.0, LIST_STEP * float(index)),
			LIST_SIZE)
		index += 1


## The list's rows are not actions the host knows; they are clicks on a dot
## that is not drawn.
func _on_pressed(action: String) -> void:
	if action.begins_with(GO):
		enter_location(action.substr(GO.length()).to_int())
		return
	super._on_pressed(action)


## The action row, in one of its two states.
func _show_actions() -> void:
	clear_children(_buttons_row())
	if pending == END_GAME:
		add_button(CANCEL, BANK_REPORT, ID_NO, 0)
		add_button(END_GAME, BANK_REPORT, ID_YES, 1)
	else:
		add_button("hq", BANK_MISSION, ID_HQ, 0)
		add_button("save", BANK_MISSION, ID_SAVE, 1)
		# **The map is where the difficulty is editable**, and `Txtmod_h` 58
		# says so aloud -- *Set Difficulty Level (only in main map during
		# campaign)*. Without a way in from here that was the one place the
		# shipped string promises the control works and the one place the
		# player could not reach: `ESC` refuses while a campaign plate is up,
		# deliberately, because the shell shares `_screen` with it.
		var _options: Button = make_action_button("options",
			strings_own(OWN_OPTIONS))
		_buttons_row().add_child(_options)
		add_button(END_GAME, BANK_MISSION, ID_END_GAME, 2)
	_lay_out_buttons()


## *End game* drops a campaign that may never have been saved.
func needs_confirming(action: String) -> bool:
	return action == END_GAME


func refresh() -> void:
	if host == null or host.state == null or _caption == null:
		return
	if pending != "":
		_caption.text = label_for(BANK_REPORT, ID_CONFIRM)
		if _name != null:
			_name.text = ""
		return
	_caption.text = "%s %d" % [label_for(BANK_MISSION, ID_POINTS),
		host.state.points(0)]


## Which sprite each open location is drawn with, for [MapMarkers].
##
## Pure, and it takes the host rather than reading a member, so a suite can ask
## it the question without a screen on a tree.
static func marks_for(campaign: CampaignHost,
		cells: Dictionary[int, Vector2i]) -> Dictionary[Vector2i, int]:
	var out: Dictionary[Vector2i, int] = {}
	if campaign == null or campaign.state == null:
		return out
	for id: int in campaign.open_locations():
		# docs/27 section 2.5: campaign 1 enables two locations `_C_XXX` has
		# no cell for. A location with nowhere to stand is skipped rather
		# than drawn at the origin.
		if not cells.has(id):
			continue
		out[cells[id]] = _dot_for(campaign.tables.kind_of(id))
	return out


static func _dot_for(kind: String) -> int:
	match kind:
		CampaignMap.KIND_UPGRADE:
			return MapMarkers.DOT_UPGRADE
		CampaignMap.KIND_DIALOGUE:
			return MapMarkers.DOT_DIALOGUE
	return MapMarkers.DOT_BATTLE


func takes_world_clicks() -> bool:
	return true


func world_click(cell: Vector2i) -> void:
	enter_location(location_at(cell))


## Open a location -- from a dot on the map, or from a row of the list the
## screen falls back to when the cache carries no map.
func enter_location(id: int) -> void:
	if id < 0 or host == null or pending != "":
		return
	var clicked: Dictionary = host.click_location(id)
	chose.emit("location:%d:%s" % [id, DictRead.as_string(clicked["kind"])])


func world_hover(cell: Vector2i) -> void:
	if _name == null or pending != "":
		return
	var id: int = location_at(cell)
	hovered = id
	if id < 0:
		_name.text = ""
		return
	# `Campaign.lcl` is text bank 1 and names every location; a dialogue
	# location is named and opens and plays nothing (D5).
	_name.text = "%s  --  %s" % [label_for(BANK_LOCATIONS, id),
		label_for(BANK_MISSION, ID_ENTER)]


## The open location standing on *cell*, or -1. Public because it is the
## whole of what a click on the map means, and a suite checks it directly.
func location_at(cell: Vector2i) -> int:
	if host == null or host.state == null:
		return -1
	for id: int in host.open_locations():
		if not location_cells.has(id):
			continue
		var at: Vector2i = location_cells[id]
		if at == cell:
			return id
	return -1
