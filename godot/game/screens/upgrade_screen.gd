class_name UpgradeScreen
extends CampaignScreen

## *Upgrade Menu* -- `Menu_b.lcl`'s `:UpGrade;`, window 2, the one campaign
## window that loads a plate of its own (`plate_6` at `0x0045BFBB`, immediately
## before `[0x510A38] = 2`).
##
## The plate is not a frame but a set of painted panels, and the screen's whole
## layout is those panels: the model window at `(63, 134)` 249x128, the item
## window at `(399, 136)` 186x127 and the column of **six** skill boxes between
## them -- all three measured off `plate_6` itself, whose interior is pure
## black where the game draws. Six, not five: the shipped screen fills five and
## the hover hints `Txtmod_b` 160..165 name six, one per skill of
## `+0x1A..+0x1F`.
##
## What the buttons do is `0x0045A770`'s jump table, decoded from the byte map
## at `0x0045BE50` rather than from the disassembler's switch labels:
##
## | gadget | case | what |
## |---|---|---|
## | 0 | `0x0045A970` | *Buy Item* |
## | 3 | `0x0045ABFB` | the name field |
## | 4 | `0x0045AD2D` | *Select Unit* |
## | 5 | `0x0045ADB9` | *Commend Unit* |
## | 6 / 7 | `0x0045AF03` / `0x0045B07B` | the item arrows |
## | 10 / 11 | `0x0045B2D6` / `0x0045B3C9` | *Select Weapon* / *Select Equipment* |
## | 16 | `0x0045B4BC` | the *i* |
## | 18 | `0x0045B507` | *Undo* |
## | 19 | `0x0045B583` | *Exit* |
## | 20 / 21 | `0x0045B1C0` / `0x0045B23E` | the soldier arrows |
##
## **`Undo` is a snapshot, not a step back.** `0x0045B507` copies 91 bytes from
## `0x00510E00` over the soldier's record and calls `0x0043BD40`, which puts
## the whole economy block back; the snapshot is taken where the window is
## built (`0x0045C054`, with `0x0043BD20` beside it), so it undoes **the whole
## visit to this soldier** and not the last purchase. That is why *Buy Item*
## and *Undo* share a position: gadget 0 and gadget 18 are both written at
## `(405, 384)`. Which of the two that position shows is decided **per
## catalogue row**, not per visit -- see [method buy_offered].
##
## Two things on this screen turn. The item is thirty pre-rendered frames --
## `Libs/Items/item_w{icon}.LIB` and `item_e{icon}.LIB`, which is what
## `aPrintOnlyWeapon` `0x00474150` and `aPrintOnlyEquip` `0x00474080` walk with
## the element count as the wrap. The soldier is a **live model**:
## `aBuildRotatingUnit` `0x00458170` copies the record and starts an animation
## on it, and the engine's camera for it is named `RotatingCamera`.

const ID_TITLE: int = 100
const ID_SELECT_UNIT: int = 101
const ID_SELECT_WEAPON: int = 102
const ID_SELECT_EQUIPMENT: int = 103
const ID_BUY: int = 105
const ID_POINTS: int = 106
const ID_COMMENDATIONS: int = 108
const ID_COMMEND: int = 111
const ID_UNDO: int = 112
const ID_ITEM_COST: int = 121
const ID_RANGE: int = 123
const ID_ACCURACY: int = 125
const ID_DAMAGE: int = 127
const ID_ACTION_POINTS: int = 129
const ID_SKILL_COST: int = 136
const ID_SKILL_LEFT: int = 137
const ID_EXIT: int = 5
## `Txtmod_b` 160..165, one per skill box, in `+0x1A..+0x1F` order but starting
## at *Battle Fitness* -- 160 names the fitness the tall first box shows and
## 161..165 the five proficiencies.
const ID_HINT_FITNESS: int = 160
## `Txtmod_b` 166..173 name **regions of this window** rather than gadgets:
## *Squad information*, *Item to purchase*, *Soldier profile*, *Soldier's
## weapon information*, *Inventory*, *Action points*, *Total skill points,
## skill points available and commendations*, *Unit to upgrade*. Which
## rectangle each one covers is **UNVERIFIED** -- the strings name no
## coordinates and the help mode's own painter has not been read -- so the
## pairing below is this remake's reading of the eight names.
const ID_HINT_SQUAD: int = 166
const ID_HINT_ITEM: int = 167
const ID_HINT_PROFILE: int = 168
const ID_HINT_WEAPON: int = 169
const ID_HINT_INVENTORY: int = 170
const ID_HINT_ACTION_POINTS: int = 171
const ID_HINT_SKILL_POINTS: int = 172
const ID_HINT_UNIT: int = 173
## The seven regions, in step with [constant HINT_IDS]. *Unit to upgrade* is
## not here: it goes on the name field itself, which is a gadget.
const HINT_IDS: Array[int] = [ID_HINT_SQUAD, ID_HINT_PROFILE, ID_HINT_ITEM,
	ID_HINT_WEAPON, ID_HINT_INVENTORY, ID_HINT_ACTION_POINTS,
	ID_HINT_SKILL_POINTS]
const HINT_REGIONS: Array[Rect2] = [
	Rect2(0.0, 66.0, 640.0, 22.0),
	MODEL_WINDOW,
	ITEM_WINDOW,
	Rect2(455.0, 282.0, 175.0, 70.0),
	Rect2(60.0, 270.0, 210.0, 56.0),
	Rect2(125.0, 294.0, 60.0, 20.0),
	Rect2(274.0, 272.0, 40.0, 90.0),
]

## The header pair, both right-aligned captions with their values beside them.
const POINTS_LABEL_AT: Vector2 = Vector2(220.0, 75.0)
const POINTS_VALUE_AT: Vector2 = Vector2(225.0, 75.0)
const MEDALS_LABEL_AT: Vector2 = Vector2(430.0, 75.0)
const MEDALS_VALUE_AT: Vector2 = Vector2(435.0, 75.0)

## `GUI_SetTextButton (3_gdtID, 0_fntID, 110_WinText, 6_Library, 145_x, 95_y,
## 5_Width)` and the centred name over it,
## `GUI_SetText (20_txtID, 1_fntID, 110_WinText, 220_x, 117_y, ..., 1_cX, ...)`.
##
## It is gadget **type 3**, exactly like the action buttons (`0x0043cff0`
## writes the same type byte `0x0043cd10` does), so the field is composed the
## same way -- `6 + (8 x 3) + 7`, three 32x32 pieces between two -- and comes
## to 160 by 32 rather than the 173 this once measured off a screenshot.
const NAME_AT: Vector2 = Vector2(220.0, 117.0)
const NAME_FIELD_WIDTH: int = 5
const NAME_BOX_AT: Vector2 = Vector2(145.0, 95.0)
## The typing box sits inside the plate piece rather than over its border.
const NAME_FIELD_INSET: Vector2 = Vector2(6.0, 4.0)
## `+0x00` is a 16-byte name field with room for a terminator (docs/10 section 5).
const NAME_LIMIT: int = 15

## Measured off `plate_6`: the black interior the model is drawn into, and the
## black interior of the item window.
const MODEL_WINDOW: Rect2 = Rect2(63.0, 134.0, 249.0, 128.0)
const ITEM_WINDOW: Rect2 = Rect2(399.0, 136.0, 186.0, 127.0)
## The six skill boxes, from the bright separators at y 88/144/187/231/272/
## 313/354 across x 315..399.
const SKILL_COLUMN_X: float = 316.0
const SKILL_COLUMN_WIDTH: float = 82.0
const SKILL_BOX_EDGES: Array[float] = [89.0, 145.0, 188.0, 232.0, 273.0,
	314.0, 354.0]

## `GUI_SetIcon` -- the soldier arrows at the model window's left edge and the
## item arrows at the item window's right edge, both `50` over `48`.
const UNIT_PREV_AT: Vector2 = Vector2(68.0, 227.0)
const UNIT_NEXT_AT: Vector2 = Vector2(68.0, 240.0)
const ITEM_PREV_AT: Vector2 = Vector2(570.0, 227.0)
const ITEM_NEXT_AT: Vector2 = Vector2(570.0, 240.0)
const INFO_AT: Vector2 = Vector2(570.0, 350.0)
const ICON_PREV: int = 50
const ICON_NEXT: int = 48
const ICON_INFO: int = 44

const BUY_AT: Vector2 = Vector2(405.0, 384.0)
const SELECT_UNIT_AT: Vector2 = Vector2(60.0, 384.0)
const COMMEND_AT: Vector2 = Vector2(60.0, 416.0)
const SELECT_WEAPON_AT: Vector2 = Vector2(232.0, 384.0)
const SELECT_EQUIPMENT_AT: Vector2 = Vector2(232.0, 416.0)
const EXIT_AT: Vector2 = Vector2(405.0, 416.0)

## The item's own readouts. **The alignment is the `Format` column, not `cX`:**
## `0x00439777` subtracts half the measured width at `Format == 1` and the
## whole of it at `2`, and `cX` is a separate word the printer takes as its own
## argument. The two columns agree in 72 of `Menu_*.lcl`'s 121 `GUI_SetText`
## calls, which is why reading the wrong one showed up in exactly one place --
## `GUI_SetText (8_txtID, 1_fntID, 120_WinText, 500_x, 116_y, 0_Style, 0_cX,
## ..., 1_Format)`, the item's name, which is **centred** on 500 and ran off
## the plate drawn from its left edge.
const ITEM_NAME_AT: Vector2 = Vector2(500.0, 116.0)
const ITEM_RANGE_AT: Vector2 = Vector2(464.0, 325.0)
const ITEM_RANGE_VALUE_X: float = 469.0
const ITEM_ACCURACY_AT: Vector2 = Vector2(464.0, 340.0)
const ITEM_ACCURACY_VALUE_X: float = 469.0
const ITEM_DAMAGE_AT: Vector2 = Vector2(557.0, 325.0)
const ITEM_DAMAGE_VALUE_X: float = 561.0
const ITEM_ACTION_AT: Vector2 = Vector2(557.0, 340.0)
const ITEM_ACTION_VALUE_X: float = 561.0
## `GUI_SetText (9_txtID, ..., 517_x, 290_y, ..., 2_Format)` with its value at
## `15_txtID ... 521_x ... 0_Format`. `21_txtID`'s *Skill points* caption at
## `(517, 305)` has **no** value slot in the layout table, so that one keeps
## the remake's own gap.
const ITEM_COST_AT: Vector2 = Vector2(517.0, 290.0)
const ITEM_COST_VALUE_X: float = 521.0
const ITEM_SKILL_AT: Vector2 = Vector2(517.0, 305.0)
const VALUE_GAP: float = 5.0
## The description box the *i* opens, from the call that opens it:
## `0x00458B2D` and `0x004587A6` both hand `0x00432B70`/`0x00432BD0` the
## rectangle `(405, 140)` by `170 x 110`, which is the item window's interior.
const DESCRIPTION_BOX: Rect2 = Rect2(405.0, 140.0, 170.0, 110.0)

## The inventory strip under the model window, and the skill-point readout
## `GUI_SetText (22, ..., 137_WinText, 304_x, 349_y, 2_cX)` beside it.
const WEAPON_NAME_AT: Vector2 = Vector2(66.0, 278.0)
const WEAPON_ICON_AT: Vector2 = Vector2(66.0, 296.0)
const WEAPON_ICON_SIZE: Vector2 = Vector2(56.0, 24.0)
const AMMO_AT: Vector2 = Vector2(130.0, 300.0)
const CARRIED_AT: Vector2 = Vector2(190.0, 292.0)
const CARRIED_STEP: float = 30.0
const CARRIED_SIZE: Vector2 = Vector2(26.0, 30.0)
const SKILL_LEFT_AT: Vector2 = Vector2(304.0, 349.0)
const SKILL_BAR: Rect2 = Rect2(278.0, 276.0, 12.0, 50.0)
## Ten skill points is `0x00458416`'s cap, so the bar has ten segments.
const SKILL_BAR_SEGMENTS: int = 10

## The portrait corner: the rank where the shipped screen shows it, and the
## hit points under it. The original draws a second, smaller render of the
## soldier here; **which** view that is is UNVERIFIED, so this draws only the
## two numbers -- and where it puts the hit points is UNVERIFIED too, which is
## why they are tucked under the rank rather than out on the plate's frame.
const PORTRAIT_HP_AT: Vector2 = Vector2(105.0, 120.0)
const PORTRAIT_RANK_AT: Vector2 = Vector2(118.0, 105.0)

## The turntables and the small inventory icons.
const WEAPON_TURNTABLE: String = "item_w%d"
const EQUIPMENT_TURNTABLE: String = "item_e%d"
const WEAPON_ICONS: String = "uweapons"
const EQUIPMENT_ICONS: String = "uequip"
const SKILL_ICONS: String = "uicons"

## How fast the two things on this screen turn.
##
## **UNVERIFIED.** The engine advances the item's frame from the GUI's own
## paint loop and wraps it on the library's element count; what that loop's
## rate is has not been measured, and the model's spin comes from a camera this
## remake does not reproduce. Both are named here so a measurement replaces a
## constant rather than a scattering of magic numbers.
const ITEM_SPIN_FPS: float = 15.0
const MODEL_SPIN_DEGREES: float = 45.0
## The turntable's camera: a narrow field from far back, so the body's own
## proportions survive the turn (see [method _build_model_window]).
const MODEL_CAMERA_FOV: float = 30.0
const MODEL_CAMERA_DISTANCE: float = 6.0
const MODEL_CAMERA_PITCH: float = -8.0
## The old 2.1 m camera's 0.95 m eye, carried back along its own pitch so the
## framing is unchanged: `0.95 + (6.0 - 2.1) * tan(8 deg)`.
const MODEL_CAMERA_HEIGHT: float = 1.5

## The remake's own lines: what the original says with a greyed button.
const OWN_REFUSED: String = "upgrade.%s"
const OWN_NOBODY: String = "upgrade.nobody"

var host: CampaignHost = null
## The roster slot on show, or [constant Roster.NO_SLOT].
var selected: int = Roster.NO_SLOT
## Which half of the catalogue the item window is showing, and which id.
var item_kind: String = CampaignHost.KIND_WEAPONS
var item_id: int = -1
## Whether the *i* is down, which is what puts the hover hints on the boxes.
var hints: bool = false
## Whether the name box is open for typing. Gadget 3 is a `GUI_SetTextButton`
## and not a label: clicking it renames the soldier, and `0x00458449` greys it
## when the record is the hero's (docs/10 section 5.11).
var _renaming: bool = false

## What [method select] saved and *Undo* puts back -- the record, the purse and
## the medals, which is exactly what `0x0045B507` and `0x0043BD40` restore.
var _saved: UnitState = null
var _saved_points: int = 0
var _saved_medals: int = 0

## Gadget 18's own enable flag -- see [method undo_offered].
var _undo_armed: bool = false

## The four shaded faces the *i*'s description page binds, built once.
##
## [method refresh] rebuilds the whole panel on every click, and building them
## per redraw re-reads `fonts/index.json` and walks the atlas pixel by pixel
## four times over.
var _description_faces: Array[FontFile] = []

## `Data.txt`'s blocks -- the descriptions the *i* shows. Set by [SliceMain];
## a cache made before the converter grew the document leaves it empty and the
## *i* then shows nothing rather than failing.
var descriptions: InfoText = null

## Where the shipped faces are read from, for the description page. Set by
## [SliceMain]; `null` leaves the page in the readable face, which is what a
## screen built with no cache in a suite gets.
var paths: CachePaths = null

## The bodies, when the cache carries them. Set by [SliceMain] before
## [method setup]; without it the model window stays empty and the rest of the
## screen works.
var library: CharismaLibrary = null

var _panel: Control = null
var _message: Label = null
var _item_view: TextureRect = null
var _item_frame: float = 0.0
var _viewport: SubViewport = null
var _pivot: Node3D = null
var _figure: CharismaBody = null
## The weapon the window's body was last built for -- `-1` before the first
## build. A purchase that changes the record's weapon changes which body the
## model selector names, so *Buy Item* compares against this and rebuilds
## only then; an equipment purchase or a refusal keeps the body it has.
var _figure_weapon: int = -1
var _spin: float = 0.0


func plate_name() -> String:
	return PLATE_UPGRADE


func build() -> void:
	var _title: Label = place_title(label_for(BANK_MISSION, ID_TITLE))
	_build_model_window()
	_build_item_window()
	_panel = gui_layer()
	_message = gui_text("", Vector2(320.0, 366.0), ALIGN_CENTRE, INK_LABEL)

	var _prev: Button = gui_icon("prev_unit", ICON_PREV, UNIT_PREV_AT)
	var _next: Button = gui_icon("next_unit", ICON_NEXT, UNIT_NEXT_AT)
	var _item_prev: Button = gui_icon("prev_item", ICON_PREV, ITEM_PREV_AT)
	var _item_next: Button = gui_icon("next_item", ICON_NEXT, ITEM_NEXT_AT)
	var _info: Button = gui_icon("info", ICON_INFO, INFO_AT)

	var _unit: Button = gui_button("select_unit", BANK_MISSION, ID_SELECT_UNIT,
		SELECT_UNIT_AT)
	var _commend: Button = gui_button("commend", BANK_MISSION, ID_COMMEND,
		COMMEND_AT)
	var _weapons: Button = gui_button("select_weapon", BANK_MISSION,
		ID_SELECT_WEAPON, SELECT_WEAPON_AT)
	var _equipment: Button = gui_button("select_equipment", BANK_MISSION,
		ID_SELECT_EQUIPMENT, SELECT_EQUIPMENT_AT)
	var _exit: Button = gui_button("map", BANK_MISSION, ID_EXIT, EXIT_AT)
	refresh()


## The window the soldier turns in: a [SubViewport] with a camera of its own,
## because the body is a `Node3D` and this screen is a [CanvasLayer].
func _build_model_window() -> void:
	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	# **A world of its own.** A [SubViewport] shares its parent's [World3D] by
	# default, and the parent here is the root -- so the camera below rendered
	# the campaign map with a marine standing in the middle of the city.
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(int(MODEL_WINDOW.size.x * 2.0),
		int(MODEL_WINDOW.size.y * 2.0))
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_pivot = Node3D.new()
	_pivot.name = "RotatingUnit"
	_viewport.add_child(_pivot)
	var camera: Camera3D = Camera3D.new()
	camera.name = "RotatingCamera"
	camera.current = true
	# A standing marine is about 1.8 m in Godot space
	# ([constant WorldSpace.WORLD_UNITS_PER_METRE]), and the window is 249x128
	# of the plate's units -- so it is nearly twice as wide as it is tall and
	# the figure is framed on its height. The engine's own camera is not
	# reproduced -- see [constant MODEL_SPIN_DEGREES].
	#
	# **A long lens, from far back.** The first camera stood 2.1 m from the
	# figure at Godot's default 75-degree field, and a rifle swinging towards
	# the viewer as the body turned was drawn as a blade twice its length --
	# the near end of a 0.6 m barrel was a third closer than the far end. At
	# 30 degrees from 6 m the same frame holds the same height
	# (`tan(15) * 6.0 == tan(37.5) * 2.1`) and the weapon keeps its shape at
	# every yaw (2026-09-12, checked against P0_001 at eight yaws).
	camera.fov = MODEL_CAMERA_FOV
	camera.position = Vector3(0.0, MODEL_CAMERA_HEIGHT, MODEL_CAMERA_DISTANCE)
	camera.rotation_degrees = Vector3(MODEL_CAMERA_PITCH, 0.0, 0.0)
	_viewport.add_child(camera)
	var view: TextureRect = TextureRect.new()
	view.texture = _viewport.get_texture()
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.stretch_mode = TextureRect.STRETCH_SCALE
	place_on_plate(view, MODEL_WINDOW.position, MODEL_WINDOW.size)
	root().add_child(_viewport)
	root().add_child(view)


func _build_item_window() -> void:
	_item_view = TextureRect.new()
	_item_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_item_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_item_view.stretch_mode = TextureRect.STRETCH_SCALE
	# Placed at the **turntable's own size**, not stretched to the window: the
	# frames are 80x60 in the plate's own units and the window is 186x127, so a
	# gun that filled the frame was drawing itself two and a half times life
	# size. Where inside the window the original blits it is **UNVERIFIED**;
	# centred is this remake's choice.
	place_on_plate(_item_view, ITEM_WINDOW.position, ITEM_WINDOW.size)
	root().add_child(_item_view)


## Put *texture* in the item window at its own size, centred.
func _fit_item(texture: Texture2D) -> void:
	_item_view.texture = texture
	if texture == null:
		return
	var size: Vector2 = texture.get_size()
	place_on_plate(_item_view,
		ITEM_WINDOW.position + (ITEM_WINDOW.size - size) * 0.5, size)


# -- what is on show -----------------------------------------------------------

## Open on one soldier, and take the snapshot *Undo* restores.
##
## `0x0045C054` copies the record and `0x0043BD20` the economy block, both at
## the point the window is built -- so a soldier changed and then left is
## changed, and *Undo* only ever reaches back to the moment this was called.
func select(slot: int) -> void:
	selected = slot
	_renaming = false
	# `0x0045C075` -- the build disables gadget 18, so a fresh visit offers
	# nothing to undo.
	_undo_armed = false
	var unit: UnitState = _unit()
	_saved = unit
	_saved_points = host.state.points(0) if host != null and host.state != null \
		else 0
	_saved_medals = host.state.commendations[0] \
		if host != null and host.state != null else 0
	if unit != null and item_id < 0:
		item_kind = CampaignHost.KIND_WEAPONS
		item_id = unit.weapon
	_rebuild_body()
	refresh()


func _unit() -> UnitState:
	if host == null or host.state == null:
		return null
	return host.state.roster.record(selected)


## Step to the next or previous occupied slot -- gadgets 20 and 21, which
## rebuild the whole window and so take a fresh snapshot.
func step_unit(by: int) -> void:
	if host == null or host.state == null:
		return
	var slots: PackedInt32Array = host.state.roster.occupied_slots()
	if slots.is_empty():
		return
	var at: int = slots.find(selected)
	if at < 0:
		at = 0
	else:
		at = posmod(at + by, slots.size())
	select(slots[at])


## Step through the catalogue half the item window is showing -- gadgets 6
## and 7.
func step_item(by: int) -> void:
	var rows: Array[Dictionary] = host.catalogue_rows(item_kind, _unit())
	if rows.is_empty():
		return
	var at: int = -1
	for index: int in range(rows.size()):
		if DictRead.as_int(rows[index]["id"]) == item_id:
			at = index
			break
	at = posmod(at + by, rows.size()) if at >= 0 else 0
	show_item(item_kind, DictRead.as_int(rows[at]["id"]))


## What the Item List chose.
func show_item(kind: String, id: int) -> void:
	item_kind = kind
	item_id = id
	_item_frame = 0.0
	refresh()


# -- the buttons ---------------------------------------------------------------

## *Buy Item* -- the purse, then the skill points, then the record.
func buy() -> void:
	# `0x0045A970` enables gadget 18 **before** the switch reaches the
	# purchase, so a refused one arms *Undo* too.
	_undo_armed = true
	var outcome: Dictionary = host.buy(item_kind, selected, item_id)
	var result: String = DictRead.as_string(outcome["result"])
	if result != Upgrade.OK:
		say(strings_own(OWN_REFUSED % result))
	else:
		say("")
		var unit: UnitState = _unit()
		if unit != null and unit.weapon != _figure_weapon:
			_rebuild_body()
	refresh()


## *Undo* -- `0x0045B507`.
func undo() -> void:
	if _saved == null or host == null or host.state == null:
		return
	host.state.restore_unit(0, selected, _saved, _saved_points, _saved_medals)
	say("")
	_rebuild_body()
	refresh()


## *Commend Unit* -- case 3 of `0x0045A770`.
func commend() -> void:
	if host == null or host.state == null:
		return
	if not host.state.commend(0, selected):
		say(strings_own(OWN_REFUSED % "commend"))
	else:
		# `0x0045AEC3`, past the decrement `aDecDecorations` guards. The
		# engine cannot reach the arm with nothing to award -- `0x00458270`
		# greys gadget 5 -- so a refusal arms nothing here either.
		_undo_armed = true
		say("")
	refresh()


## Whether the visit has changed anything -- which is what *Undo* puts back.
##
## **Not** the gate that shows the button. That is [method undo_offered], and
## the two differ: the engine's *Undo* is a gadget flag, not a diff.
func is_dirty() -> bool:
	var unit: UnitState = _unit()
	if unit == null or _saved == null:
		return false
	return unit.weapon != _saved.weapon or unit.tp != _saved.tp \
		or unit.decorations != _saved.decorations \
		or unit.equipment != _saved.equipment or unit.name != _saved.name


## Whether the shared button position shows *Buy Item* -- gadget 0's own gate
## in the item window's refresh, `0x00457B00` (equipment) and `0x00457DA0`
## (weapons).
##
## Both are called from every catalogue arrow, from the *Buy Item* arm, from
## *Undo* and from the window's build, and both gate gadget 0 on the **row
## that is up** rather than on the visit. Three tests, all of them the row's:
##
## * the soldier does not carry it already -- `0x00458037` against the unit
##   record's `+0x3F` weapon id, `0x00457C51` against the equipment flag at
##   `+0x21 + row`;
## * the price fits the purse -- `0x00458061` reads the weapon's `+0x3E` and
##   `0x00457C85` the item's `+0x20`, each against the player's equipment
##   points. It is the **full** price even for a weapon swap, which
##   [method CampaignState.buy_weapon] charges only the difference of
##   (`0x0045A970` refunds the old one first). That asymmetry is the engine's
##   own: the greying is what keeps the cheaper arithmetic out of reach, so
##   the two are consistent only when read together;
## * and the skills are within reach -- `0x0047A600` / `0x0047A6E0`'s
##   shortfall times twelve against the record's `+0x18`.
##
## [method CampaignHost.catalogue_rows] already measures all three per row,
## which is also what colours the Item List, so the button asks it rather than
## repeating the arithmetic.
func buy_offered() -> bool:
	if host == null or item_id < 0:
		return false
	for row: Dictionary in host.catalogue_rows(item_kind, _unit()):
		if DictRead.as_int(row["id"]) != item_id:
			continue
		return DictRead.as_bool(row["affordable"]) \
			and not DictRead.as_bool(row["carried"])
	return false


## Whether that position shows *Undo* instead.
##
## Gadget 18 is a flag of its own and not a diff: *Buy Item* and *Commend
## Unit* enable it (`0x0045A970`, `0x0045AEC3`), the window's build disables
## it (`0x0045C075`), and the refresh above disables it again the moment a
## row the soldier **can** buy comes up (`0x00457D07`, `0x004580E3`). So
## stepping off a purchase onto something still affordable puts *Buy Item*
## back, and *Undo* is what the position shows when there is nothing to buy
## here and something has been bought since the window opened.
##
## *Undo* itself does not clear the flag -- `0x0045B507` writes neither
## gadget, and a second *Undo* restores the same snapshot.
func undo_offered() -> bool:
	return _undo_armed and not buy_offered()


func say(line: String) -> void:
	if _message != null:
		_message.text = line


# -- drawing -------------------------------------------------------------------

func refresh() -> void:
	if host == null or host.state == null or _panel == null:
		return
	clear_children(_panel)
	var unit: UnitState = _unit()
	var _points: Label = gui_text(label_for(BANK_MISSION, ID_POINTS),
		POINTS_LABEL_AT, ALIGN_RIGHT, INK_LABEL, _panel)
	var _points_value: Label = gui_text(str(host.state.points(0)),
		POINTS_VALUE_AT, ALIGN_LEFT, INK_VALUE, _panel, FNT_VALUE)
	var _medals: Label = gui_text(label_for(BANK_MISSION, ID_COMMENDATIONS),
		MEDALS_LABEL_AT, ALIGN_RIGHT, INK_LABEL, _panel)
	var _medals_value: Label = gui_text(str(host.state.commendations[0]),
		MEDALS_VALUE_AT, ALIGN_LEFT, INK_VALUE, _panel, FNT_VALUE)
	_draw_action_button()
	if unit == null:
		var _nobody: Label = gui_text(strings_own(OWN_NOBODY), NAME_AT,
			ALIGN_CENTRE, INK_LABEL, _panel)
		_fit_item(null)
		return
	_draw_hints()
	_draw_name(unit)
	_draw_portrait(unit)
	_draw_skills(unit)
	_draw_inventory(unit)
	_draw_item(unit)


## `Txtmod_b` 166..173 over the regions they name. Added before everything
## else so a widget drawn afterwards sits on top of its own region.
func _draw_hints() -> void:
	for index: int in range(HINT_IDS.size()):
		var line: String = label_for(BANK_MISSION, HINT_IDS[index])
		var _area: Control = hint_region(HINT_REGIONS[index], line, _panel)


## *Buy Item* and *Undo* share `(405, 384)`; the item window's refresh shows
## one. See [method buy_offered] and [method undo_offered] for whose flag is
## whose.
func _draw_action_button() -> void:
	var offered: bool = buy_offered()
	if offered:
		# The refresh's own write, `0x00457D07` / `0x004580E3`: a row the
		# soldier can buy disables gadget 18.
		_undo_armed = false
	elif _undo_armed:
		var _undo: Button = gui_text_button("undo",
			label_for(BANK_MISSION, ID_UNDO), BUY_AT, GUI_BUTTON_WIDTH,
			_panel)
		return
	# Greyed rather than gone when neither is offered, which is what the
	# engine leaves behind: both gadgets are still drawn, both disabled.
	var buy_button: Button = gui_text_button("buy",
		label_for(BANK_MISSION, ID_BUY), BUY_AT, GUI_BUTTON_WIDTH, _panel)
	buy_button.disabled = not offered


func _draw_name(unit: UnitState) -> void:
	# The field is the gadget, so it is built as one even when it cannot be
	# typed in: a hero's name sits on the same composed panel, greyed only in
	# that clicking it does nothing (`0x00458449`).
	var box: Button = gui_text_button("rename", "", NAME_BOX_AT,
		NAME_FIELD_WIDTH, _panel, Art.BUTTON_BASE_FIELD)
	box.disabled = not Upgrade.may_rename(unit)
	box.tooltip_text = label_for(BANK_MISSION, ID_HINT_UNIT)
	if _renaming and Upgrade.may_rename(unit):
		_draw_name_field(unit, box)
		return
	# **Centred in the field, not hung off `GUI_SetText`'s y.** That column is
	# the printer's *baseline* -- `aPrintGadget` hands `0x00439610` the
	# gadget's y plus 20 for a 31-tall face, which is a baseline and not a top
	# -- and `gui_text` addresses a box's top edge, so 117 dropped the name
	# onto the field's bottom rail. The field is 32 units tall and the name
	# belongs in the middle of it either way.
	var name_line: Label = make_label(unit.name, 0, FNT_VALUE)
	name_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_line.add_theme_color_override("font_color", INK_ROSTER)
	name_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	place_on_plate(name_line, NAME_BOX_AT, _face_size(box))
	_panel.add_child(name_line)


## The name box with the caret in it. `text_submitted` is what the original's
## `GUI_GetTextButton` returns on `Enter`; leaving the field keeps whatever is
## typed, because the box is the only place the name lives while it is open.
func _draw_name_field(unit: UnitState, box: Button) -> void:
	var field: LineEdit = LineEdit.new()
	field.text = unit.name
	field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	field.max_length = NAME_LIMIT
	field.flat = true
	var chosen: FontFile = face(FNT_VALUE)
	if chosen != null:
		field.add_theme_font_override("font", chosen)
	field.add_theme_color_override("font_color", INK_ROSTER)
	field.text_submitted.connect(commit_rename)
	# **A lambda, not `bind`.** `Callable.bind` freezes its argument where the
	# connection is made -- one line under `field.text = unit.name` -- so a
	# bound `field.text` hands `commit_rename` the *old* name and everything
	# typed is dropped the moment the focus leaves. Read the box when it
	# fires.
	field.focus_exited.connect(func() -> void:
		if is_instance_valid(field):
			commit_rename(field.text))
	var span: Vector2 = _face_size(box)
	place_on_plate(field, NAME_BOX_AT + NAME_FIELD_INSET,
		span - NAME_FIELD_INSET * 2.0)
	_panel.add_child(field)
	_focus_field.call_deferred(field)


## Put the caret in the box on the next frame.
##
## **Deferred and guarded.** The caret can only be taken once the field is in
## the tree, and by the next frame it may not be: the suites build this screen
## with no tree at all and free it in the same frame, where `grab_focus` is an
## engine error -- and `run_tests.sh` fails a run on an error line whatever the
## checks say.
static func _focus_field(field: LineEdit) -> void:
	if not is_instance_valid(field) or not field.is_inside_tree():
		return
	field.grab_focus()
	field.select_all()


## How big a composed face came out, back in the plate's own units.
static func _face_size(box: Control) -> Vector2:
	return Vector2(box.anchor_right - box.anchor_left,
		box.anchor_bottom - box.anchor_top) * PLATE_SIZE


## Open the box. Called for the `rename` action the box emits.
func begin_rename() -> void:
	var unit: UnitState = _unit()
	if unit == null or not Upgrade.may_rename(unit):
		say(strings_own(OWN_REFUSED % "rename"))
		return
	_renaming = true
	refresh()


## Close the box and keep what was typed. A name the rules refuse -- a hero's,
## or an empty one -- leaves the record alone and the box shut.
func commit_rename(typed: String) -> void:
	if not _renaming:
		return
	_renaming = false
	if host != null and host.state != null:
		var _done: bool = host.state.rename_unit(selected, typed)
	refresh()


## Whether the name box is open for typing. For the suites and the agent.
func is_renaming() -> bool:
	return _renaming


func _draw_portrait(unit: UnitState) -> void:
	var _hp: Label = gui_text("%d/%d" % [unit.hp, _hit_point_ceiling(unit)],
		PORTRAIT_HP_AT, ALIGN_CENTRE, INK_VALUE, _panel)
	var _rank: Label = gui_text(str(unit.ep / Roster.EP_PER_RANK),
		PORTRAIT_RANK_AT, ALIGN_LEFT, INK_ROSTER, _panel)


## `0x00475240` -- the type's `hp_max` plus `EP / 12`, never above 15, which
## is what the recompute restores to. It read the type's column alone, so a
## rank-10 soldier showed `15/5`.
func _hit_point_ceiling(unit: UnitState) -> int:
	var row: Dictionary = host.row_for("units", unit.type_id)
	var base: int = DictRead.as_int(row.get("hp_max", 0))
	if base <= 0:
		return unit.hp
	if unit.player == UnitState.PLAYER_ALIEN:
		return base
	return mini(Interact.MAX_HIT_POINTS_CAP,
		base + unit.ep / Interact.EXPERIENCE_PER_HIT_POINT)


## The six boxes: an icon, the value, and the hint `Txtmod_b` 160..165 names,
## which is on the box rather than beside it -- a caption drawn next to a
## 82-unit column ran across half the plate.
func _draw_skills(unit: UnitState) -> void:
	for index: int in range(SKILL_BOX_EDGES.size() - 1):
		var top: float = SKILL_BOX_EDGES[index]
		var height: float = SKILL_BOX_EDGES[index + 1] - top
		var icon: TextureRect = gui_sprite(SKILL_ICONS, index,
			Vector2(SKILL_COLUMN_X, top + 2.0),
			Vector2(SKILL_COLUMN_WIDTH, height - 16.0), _panel)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var value: int = _skill_shown(unit, index)
		var _number: Label = gui_text(str(value),
			Vector2(SKILL_COLUMN_X + SKILL_COLUMN_WIDTH * 0.5,
				top + height - 14.0), ALIGN_CENTRE, INK_ROSTER, _panel)
		var _hint: Control = hint_region(
			Rect2(SKILL_COLUMN_X, top, SKILL_COLUMN_WIDTH, height),
			label_for(BANK_MISSION, ID_HINT_FITNESS + index), _panel)


## Box 0 is *Battle Fitness*, `+0x19`; the five below it are the skills of
## `+0x1B`, `+0x1C`, `+0x1D`, `+0x1E`, `+0x1F` -- the proficiencies, in the
## order the hints name them and **not** in the record's, whose first byte is
## CON.
func _skill_shown(unit: UnitState, box: int) -> int:
	if box == 0:
		return unit.fp
	var order: Array[int] = [UnitState.SKILL_LW, UnitState.SKILL_HW,
		UnitState.SKILL_TS, UnitState.SKILL_MS, UnitState.SKILL_LS]
	var skill: int = order[box - 1]
	return unit.skills[skill] if skill < unit.skills.size() else 0


func _draw_inventory(unit: UnitState) -> void:
	var weapon: Dictionary = host.row_for(CampaignHost.KIND_WEAPONS,
		unit.weapon)
	if not weapon.is_empty():
		var _name: Label = gui_text(DictRead.as_string(weapon["name"]),
			WEAPON_NAME_AT, ALIGN_LEFT, INK_VALUE, _panel)
		var _icon: TextureRect = gui_sprite(WEAPON_ICONS,
			DictRead.as_int(weapon["icon"]), WEAPON_ICON_AT,
			WEAPON_ICON_SIZE, _panel)
		var _ammo: Label = gui_text("%d/%d" % [unit.ammo,
			DictRead.as_int(weapon["mun"])], AMMO_AT, ALIGN_LEFT, INK_LABEL,
			_panel)
	var at: int = 0
	for held: int in unit.equipment:
		var item: Dictionary = host.row_for(CampaignHost.KIND_EQUIPMENT, held)
		if item.is_empty():
			continue
		var _picture: TextureRect = gui_sprite(EQUIPMENT_ICONS,
			DictRead.as_int(item["icon"]),
			CARRIED_AT + Vector2(float(at) * CARRIED_STEP, 0.0), CARRIED_SIZE,
			_panel)
		at += 1
	var left: int = Upgrade.skill_points(unit)
	var _caption: Label = gui_text(label_for(BANK_MISSION, ID_SKILL_LEFT),
		SKILL_LEFT_AT, ALIGN_RIGHT, INK_LABEL, _panel)
	var _value: Label = gui_text(str(left),
		SKILL_LEFT_AT + Vector2(VALUE_GAP, 0.0), ALIGN_LEFT, INK_VALUE,
		_panel, FNT_VALUE)
	_draw_skill_bar(left)


## The segmented bar beside the inventory: ten cells, one per attainable skill
## point (`0x00458416` stops *Commend Unit* at 120, which is ten).
func _draw_skill_bar(points: int) -> void:
	var step: float = SKILL_BAR.size.y / float(SKILL_BAR_SEGMENTS)
	for index: int in range(SKILL_BAR_SEGMENTS):
		var cell: ColorRect = ColorRect.new()
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.color = INK_ROSTER if index < points else INK_DISABLED
		place_on_plate(cell,
			Vector2(SKILL_BAR.position.x,
				SKILL_BAR.position.y + SKILL_BAR.size.y - step * float(index + 1)),
			Vector2(SKILL_BAR.size.x, step - 1.0))
		_panel.add_child(cell)


func _draw_item(unit: UnitState) -> void:
	var row: Dictionary = host.row_for(item_kind, item_id)
	if row.is_empty():
		_fit_item(null)
		return
	if hints:
		_draw_description(row)
		return
	var _name: Label = gui_text(DictRead.as_string(row["name"]), ITEM_NAME_AT,
		ALIGN_CENTRE, INK_VALUE, _panel, FNT_VALUE)
	var skills: int = host.skill_cost(item_kind, row, unit)
	_pair(ID_ITEM_COST, str(DictRead.as_int(row["cost"])), ITEM_COST_AT,
		ITEM_COST_VALUE_X)
	_pair(ID_SKILL_COST, str(skills), ITEM_SKILL_AT)
	if item_kind == CampaignHost.KIND_WEAPONS:
		_pair(ID_RANGE, "%d-%d" % [DictRead.as_int(row["range_min"]),
			DictRead.as_int(row["range_max"])], ITEM_RANGE_AT,
			ITEM_RANGE_VALUE_X)
		_pair(ID_ACCURACY, "%d%%" % DictRead.as_int(row["hit"]),
			ITEM_ACCURACY_AT, ITEM_ACCURACY_VALUE_X)
		_pair(ID_DAMAGE, str(DictRead.as_int(row["damage"])), ITEM_DAMAGE_AT,
			ITEM_DAMAGE_VALUE_X)
		_pair(ID_ACTION_POINTS, str(DictRead.as_int(row["ap"])),
			ITEM_ACTION_AT, ITEM_ACTION_VALUE_X)
	_item_frame = 0.0


## One right-aligned caption with its value beside it, which is how every
## readout on this plate is written.
func _pair(id: int, value: String, at: Vector2, value_x: float = -1.0) -> void:
	var _caption: Label = gui_text(label_for(BANK_MISSION, id), at,
		ALIGN_RIGHT, INK_LABEL, _panel)
	var x: float = value_x if value_x >= 0.0 else at.x + VALUE_GAP
	var _value: Label = gui_text(value, Vector2(x, at.y),
		ALIGN_LEFT, INK_VALUE, _panel, FNT_VALUE)


## The *i* down: the item's own description, where its picture was.
##
## `0x0045B4BC` toggles `0x00510A54`; at 1 the item window stops loading its
## shape library (`0x00458BFE`) and `0x00432B70` (equipment) or `0x00432BD0`
## (a weapon) opens an info page instead. Both read a **letter out of the
## record** -- `+0x29` of the 42-byte equipment record, `+0x40` of the 65-byte
## weapon one, which `Info.lcl` writes as `SetEquipInfo`'s and
## `SetWeaponInfo2`'s last string and the cache carries as `key` -- refuse when
## it is `#`, and ask `DATA/TXT/<language>/Info/Data.txt` for the block that
## letter names plus a digit for the family: `0` a unit, `1` equipment, `2` a
## weapon. So `Scan Module`'s `A` is block `A1`.
func _draw_description(row: Dictionary) -> void:
	var name_text: String = DictRead.as_string(row.get("name", ""))
	# The name goes red in the info mode, which is what the shipped screen
	# shows -- the alert step of the same ramp the block's own spans use.
	var _title: Label = gui_text(name_text, ITEM_NAME_AT, ALIGN_CENTRE,
		INK_ITEM, _panel, FNT_VALUE)
	var spans: Array = _description_spans(row)
	if spans.is_empty():
		return
	# **The same renderer the briefing uses.** `Data.txt` is docs/24's markup
	# like any other block, so the face pairing, the ramps and the shade all
	# belong in one place rather than being set up a second time here.
	if _description_faces.is_empty() and font != null:
		_description_faces = BriefingText.game_faces(paths)
	var page: BriefingText = BriefingText.create(paths, font != null,
		readable_size(FNT_LABEL), _description_faces)
	page.scroll_active = false
	page.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(page, DESCRIPTION_BOX.position, DESCRIPTION_BOX.size)
	_panel.add_child(page)
	page.show_block(spans)


## The block `Data.txt` holds for this row, or nothing.
func _description_spans(row: Dictionary) -> Array:
	if descriptions == null or row.is_empty():
		return []
	var letter: String = DictRead.as_string(row.get("key", ""))
	if letter == "" or letter == descriptions.no_page():
		return []
	var digit: String = descriptions.family_digit(
		"weapons" if item_kind == CampaignHost.KIND_WEAPONS else "equipment")
	if digit == "":
		return []
	return descriptions.spans(letter + digit)


# -- the two things that turn --------------------------------------------------

func _process(delta: float) -> void:
	_spin_item(delta)
	_spin_model(delta)


func _spin_item(delta: float) -> void:
	if _item_view == null or art == null:
		return
	# `0x00458bfe` loads the item's shape library only while the info mode is
	# 0, so the help mode has no picture in this window at all.
	var library_name: String = "" if hints else _turntable_name()
	if library_name == "":
		_fit_item(null)
		return
	var frames: int = art.sprite_count(library_name)
	if frames <= 0:
		_fit_item(null)
		return
	_item_frame = fmod(_item_frame + delta * ITEM_SPIN_FPS, float(frames))
	_fit_item(art.sprite(library_name, int(_item_frame)))


## `item_w{icon}` or `item_e{icon}` -- the **icon** column and not the id, so
## the four weapons that share a picture share a turntable.
func _turntable_name() -> String:
	if host == null or item_id < 0:
		return ""
	var row: Dictionary = host.row_for(item_kind, item_id)
	if row.is_empty():
		return ""
	var icon: int = DictRead.as_int(row["icon"])
	return (WEAPON_TURNTABLE if item_kind == CampaignHost.KIND_WEAPONS
		else EQUIPMENT_TURNTABLE) % icon


func _spin_model(delta: float) -> void:
	if _pivot == null:
		return
	_spin = fmod(_spin + delta * MODEL_SPIN_DEGREES, 360.0)
	_pivot.rotation_degrees = Vector3(0.0, _spin, 0.0)


## Put the selected soldier's body in the window.
##
## Null is an ordinary answer: a cache converted without the Charisma tables
## carries no bodies, and the window is then empty rather than the screen
## failing to open.
func _rebuild_body() -> void:
	if _pivot == null:
		return
	if _figure != null:
		_pivot.remove_child(_figure)
		_figure.queue_free()
		_figure = null
	var unit: UnitState = _unit()
	_figure_weapon = unit.weapon if unit != null else -1
	if unit == null or library == null or not library.is_ready():
		return
	var model_name: String = library.name_for(CharismaLibrary.SELECTOR_MODEL,
		unit.type_id, unit.weapon, unit.player)
	var model: CharismaModel = library.model(model_name)
	if model == null:
		return
	_figure = CharismaBody.create(model, library)
	if _figure == null:
		return
	_pivot.add_child(_figure)
	# The idle clip's first frame. The engine starts a real animation on the
	# copied record (`0x00458170` calls `0x00406500` on it); this stands the
	# body in the pose that animation opens with, which is the one thing about
	# it that is not a guess.
	var clip: CharismaClip = library.clips_for(unit.type_id, unit.weapon,
		unit.player)[0]
	if clip != null:
		_figure.pose(clip, 0.0)
