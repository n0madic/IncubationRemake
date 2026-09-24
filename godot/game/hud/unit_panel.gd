class_name UnitPanel
extends Control

## The selected unit's panel -- `aUnitInfos.cpp`'s `0x004756D0` and the five
## renderers it calls, docs/29 section 1.1 and docs/43 section 5.
##
## The original restores the plate under it and draws at (60, 415): the name
## and a status word at y 397, the hit-point block, the experience block, the
## weapon block, the action-point disc and the inventory, each at a fixed
## offset from the origin. The offsets, the `uicons.LIB` elements and the
## colours are [HudTables]'; what is drawn is read from `World.unit_view` and
## the two balance tables on every refresh, so nothing here is a copy of a
## rule that lives in `core`.
##
## Two font slots, one shipped face: the numbers and the name line are both
## `font_0` -- the handle `aInitUI` is passed is `aGetFont(0)` and
## `0x00473960` pushes it twice into the panel (docs/43 D7). The slots stay
## apart because the readable fallback sizes below differ.

## The band's two halves were clicked -- the place interface's *previous*
## ([constant Deployment.PREV]) or *next* ([constant Deployment.NEXT]) pool
## soldier, `fcn.004637c0` (docs/43 section 5.5).
signal cycled(step: int)

## RGB565 colours the panel writes with.
const COLOUR_TEXT: int = 0xFFFF
const COLOUR_SHADOW: int = 0x632C
const COLOUR_NAME_SHADOW: int = 0x18E3
const COLOUR_RED: int = 0xF800
const COLOUR_HEAT: int = 0xFCA0
const COLOUR_HEAT_SHADOW: int = 0x6180
const COLOUR_DISC_SHADOW: int = 0x7BEF
## Rungs: three pixels apart, at most ten, every second one past ten.
const RUNG_STEP: int = 3
const RUNG_MAX: int = 10
## Experience: one rung per twelve points, four pixels apart; a tier disc
## every seven; the wedge's thirty columns.
const XP_RUNG_STEP: int = 4
const TIER_STEP: int = 7
const TIER_LIMITS: Array[int] = [40, 60, 100]
const WEDGE_COLUMNS: int = 30
const WEDGE_HEIGHT_MAX: int = 16
## The alien weapons the block refuses to draw (`0x0047432D`: ids 17..37).
const WEAPON_ALIEN_LOW: int = 17
const WEAPON_ALIEN_HIGH: int = 37
## `weapon < 40` shows lamp A, an alternate mode lamp B.
const WEAPON_ALTERNATE_FIRST: int = 40
## Equipment id -> `inv.LIB` element (`0x00475BA1`..`0x004761D4`: the flag
## byte at `+0x21 + id` selects the element).
const INVENTORY_ELEMENTS: Dictionary = {0: 0, 1: 1, 5: 2, 6: 3, 14: 4, 17: 5,
	3: 6, 4: 7, 15: 8, 16: 9, 7: 10, 9: 11}
## No inventory picture under the pointer.
const NO_ITEM: int = -1
const INVENTORY_COLUMNS: int = 4
const INVENTORY_STEP: Vector2i = Vector2i(18, 19)
## The weapon, movement disc and inventory move together into the unused gap
## after experience. At the original offsets the last inventory picture sits
## on the bottom plate's bevel at the 640-wide layout; eight units clear it
## while leaving the weapon mode lamp clear of the experience block.
## Deliberately the remake's presentation correction: [HudTables] keeps the
## executable's measured coordinates unchanged.
const TRAILING_BLOCK_SHIFT: Vector2 = Vector2(-8.0, 0.0)
## docs/21 section 5's species column.
const SPECIES_HUMAN: int = 0
const SPECIES_ALIEN: int = 1
const SPECIES_MACHINE: int = 3
## The readable face's sizes, used both when the cache has no bitmap fonts and
## when the player chose the readable interface font ([method
## MissionHud._panel_font] answers null for it). **Two of them**: the panel's
## numbers sit in rows cut for `font_0`'s 10 px digits and the name line is
## its 13 px line, and one size for both drew the unit's name at the size of
## the digits under it.
##
## The digits are **8 and not the bitmap's 10**: the rows are the original's
## measured coordinates -- the ammunition at `uicons[7].width - 7` and the
## movement disc at `+235` (`0x0047454F`) -- and they are laid out for a face
## whose glyphs are five pixels wide. The disc is drawn after the weapon block
## in the engine's own order, so a proportional face wide enough to reach it
## goes *under* it: at 10 and at 9 `10/10` loses its last digit, at 8 the row
## ends clear of the disc. The anchors themselves are untouched.
const FALLBACK_TEXT_SIZE: int = 8
const FALLBACK_NAME_SIZE: int = 13
## How far short of the movement disc the ammunition row has to stop.
const AMMO_DISC_GAP: float = 3.0
## How far short of the inventory the weapon's name has to stop. The name
## starts at the frame's right edge and the inventory's first column is at
## `+275`, which leaves the shipped bitmap face room for every weapon name but
## not a readable one: `Mine Thrower Enhanced` ran across the first picture
## while the whole width over the frame stood empty. So the name moves **left**
## by its overrun, over the frame, the same correction the ammunition row gets.
## The bound is the pictures **as drawn**, not the column: each is placed by
## its own sprite offset, which puts some of them left of `+275`.
const NAME_INVENTORY_GAP: float = 3.0

var _art: Art = null
var _strings: Localization = null
var _font: FontFile = null
var _small: FontFile = null
var _items: Array[Control] = []
var _origin: Vector2 = Vector2.ZERO
var _hp_max: int = 0
## The weapon's name as the last refresh drew it, until the inventory is
## down and [method _clear_weapon_name] can see what it has to stop short of.
var _weapon_name: Label = null
## The inventory's tooltip targets: one rectangle and one equipment id per
## drawn picture, in the panel's own coordinates.
var _hover_rects: Array[Rect2] = []
var _hover_ids: PackedInt32Array = PackedInt32Array()
## One persistent carrier per fixed inventory position. The pictures are
## rebuilt on every refresh, but these are not: replacing a hovered [Control]
## would restart Godot's tooltip timer on every redraw and it would never open.
var _item_hints: Array[HintControl] = []
## `Info.lcl`'s equipment names, keyed by id -- the same rows the Item List
## screen reads. Empty where no cache was handed over, and an empty name is
## no hint rather than a caption of the remake's own.
var _equipment_names: Dictionary = {}
## The place interface's two click halves of the panel band, up only while a
## pool record is on the panel. They stop the mouse and sit above the
## inventory's tooltip carriers, so on turn 0 the pictures under them have
## no tooltip -- the original's band knows nothing of the pictures either.
var _cycle_zones: Array[Control] = []


func setup(art: Art, strings: Localization, font: FontFile, small: FontFile) -> void:
	_art = art
	_strings = strings
	_font = font
	_small = small
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_ensure_inventory_hints()
	_ensure_cycle_zones()
	resized.connect(_layout_cycle_zones)


func use_font(font: FontFile, small: FontFile) -> void:
	_font = font
	_small = small
	for area: HintControl in _item_hints:
		area.face = _font


## Redraw for *slot*, or clear for a slot the world does not have.
func refresh(world: World, slot: int) -> void:
	_clear()
	if world == null or slot < 0 or not world.has_unit(slot):
		_sync_inventory_hints({})
		return
	var view: Dictionary = world.unit_view(slot)
	if view.is_empty():
		_sync_inventory_hints({})
		return
	_paint(view, world.unit_types(), world.weapons(),
		world.max_hit_points(slot))


## Redraw for a record that is not on the map -- the place interface feeds
## the pool's selected record to the same painter (`fcn.00463730` ->
## `0x004756D0`, docs/43 section 5.5). The hit-point cap is the record's own,
## from the same rule [method World.max_hit_points] applies to a placed one.
## The record is read and let go: the roster hands out clones.
func refresh_record(world: World, record: UnitState) -> void:
	_clear()
	if world == null or record == null or not record.is_placed():
		_sync_inventory_hints({})
		return
	var utab: UnitTypeTable = world.unit_types()
	_paint(record.view(), utab, world.weapons(),
		Interact.max_hit_points(utab, record))


## Whether the band's halves take clicks -- on while a pool record is shown.
func set_cycling(on: bool) -> void:
	for zone: Control in _cycle_zones:
		zone.visible = on


func cycling() -> bool:
	return not _cycle_zones.is_empty() and _cycle_zones[0].visible


func _clear() -> void:
	for item: Control in _items:
		remove_child(item)
		item.queue_free()
	_items.clear()
	_hover_rects.clear()
	_hover_ids.clear()


func _paint(view: Dictionary, utab: UnitTypeTable, wtab: WeaponTable,
		hp_max: int) -> void:
	_hp_max = hp_max
	_origin = PlateLayout.anchored(Vector2(HudTables.PANEL_ORIGIN), size,
		"bottom_left")
	var type_id: int = DictRead.as_int(view["type_id"])
	var species: int = utab.species(type_id)
	_name_line(view, wtab, species)
	_hp_block(view, utab, species)
	_experience_block(view)
	if species != SPECIES_ALIEN:
		_weapon_block(view, wtab)
	_movement_block(view)
	_inventory(view)
	_clear_weapon_name()


## The name at the engine's (60, 397) -- which is **over the class icon's
## helmet**: the icon is anchored 37 rows up from (+28, +13) and its top is
## 391, six above the name's baseline. In `font_0` that is a thin 8 px
## line across the top of a small picture and reads as the original does.
## The readable face is half again as tall and wide, and a Cyrillic name
## with descenders covered the figure -- so with that face the line starts
## **to the right of the icon** instead ([constant NAME_CLEAR]), where
## nothing else is drawn until the weapon block fifteen rows lower. The
## shipped face keeps the shipped coordinate.
func _name_line(view: Dictionary, wtab: WeaponTable, species: int) -> void:
	var text: String = DictRead.as_string(view["name"])
	var status: int = _status_text(view, wtab)
	if status > 0 and _strings != null:
		text += " " + _strings.shipped(HudTables.BANK_INTERFACE, status)
	var at: Vector2 = Vector2(_origin.x, _origin.y
		- float(HudTables.PANEL_ORIGIN.y - HudTables.PANEL_NAME_Y))
	if _font == null:
		at.x = maxf(at.x, _class_icon_right(species) + NAME_CLEAR)
	_text(text, at, _font, COLOUR_TEXT, COLOUR_SHADOW, false,
		FALLBACK_NAME_SIZE)


## The gap between the class icon's right edge and a readable-face name.
const NAME_CLEAR: float = 4.0


## The panel-space x the class icon ends at: `(+28, +13)` less its anchor
## plus its width, out of the art's own index -- the same numbers
## [method _hp_block] places it by.
func _class_icon_right(species: int) -> float:
	var class_icon: int = HudTables.ICON_CLASS_MARINE
	if species == SPECIES_ALIEN:
		class_icon = HudTables.ICON_CLASS_ALIEN
	elif species == SPECIES_MACHINE:
		class_icon = HudTables.ICON_CLASS_ROBOT
	if _art == null:
		return _origin.x
	var texture: Texture2D = _art.sprite(HudTables.LIB_ICONS, class_icon)
	if texture == null:
		return _origin.x
	var left: float = _origin.x + float(HudTables.PANEL_BLOCK_HP.x) + 28.0 \
		- float(_art.sprite_offset(HudTables.LIB_ICONS, class_icon).x)
	return left + texture.get_width()


## `0x00474C40` -- the word after the name: panic at no fitness, light panic
## at one, "weapon is hot" with no heat left and rounds to fire, "out of
## ammo" with none.
func _status_text(view: Dictionary, wtab: WeaponTable) -> int:
	var fp: int = DictRead.as_int(view["fp"])
	var ammo: int = DictRead.as_int(view["ammo"])
	var weapon: int = DictRead.as_int(view["weapon"])
	if fp == 0:
		return HudTables.TEXT_PANIC
	if fp == 1:
		return HudTables.TEXT_LIGHT_PANIC
	var limit: int = _heat_limit(view, wtab)
	if limit != Refresh.HEAT_NONE and DictRead.as_int(view["heat"]) >= limit \
			and ammo != 0 and wtab.heat(weapon) != Refresh.HEAT_NONE:
		return HudTables.TEXT_HOT
	if ammo == 0:
		return HudTables.TEXT_NO_AMMO
	return 0


## `0x00475340` -- the weapon's heat cap, doubled by a Cooler (`+0x34`).
static func _heat_limit(view: Dictionary, wtab: WeaponTable) -> int:
	var limit: int = wtab.heat(DictRead.as_int(view["weapon"]))
	if limit == Refresh.HEAT_NONE:
		return limit
	if DictRead.to_int32(view["equipment"]).has(Interact.EQUIP_COOLER):
		limit *= 2
	return limit


## `0x004752A0` -- the magazine, doubled by Double Munition (`+0x27`).
##
## The 255 arm is the panel's, not the routine's: a weapon that never consumes
## ammunition is drawn as `-/-`, so the doubling the engine would still do is
## not asked for.
static func _ammo_max(view: Dictionary, wtab: WeaponTable) -> int:
	var weapon: int = DictRead.as_int(view["weapon"])
	if wtab.magazine(weapon) == Refresh.HEAT_NONE:
		return Refresh.HEAT_NONE
	return wtab.magazine_for(weapon, DictRead.to_int32(
		view["equipment"]).has(Interact.EQUIP_DOUBLE_MUNITION))


## `0x00474DD0(x, y + 10)`: the frame, the class icon, the two armour
## ladders, the rank, `hp/max` and the absorber's charges.
func _hp_block(view: Dictionary, _utab: UnitTypeTable, species: int) -> void:
	var base: Vector2 = _origin + Vector2(HudTables.PANEL_BLOCK_HP)
	_icon(HudTables.LIB_ICONS, HudTables.ICON_HP_FRAME, base)
	var class_icon: int = HudTables.ICON_CLASS_MARINE
	if species == SPECIES_ALIEN:
		class_icon = HudTables.ICON_CLASS_ALIEN
	elif species == SPECIES_MACHINE:
		class_icon = HudTables.ICON_CLASS_ROBOT
	_icon(HudTables.LIB_ICONS, class_icon, base + Vector2(28, 3), true)
	_rungs(DictRead.as_int(view["armour_rear"]), base + Vector2(14, 2))
	_rungs(DictRead.as_int(view["armour_front"]), base + Vector2(42, 23))
	var rank: int = DictRead.as_int(view["ep"]) / Refresh.EP_PER_RANK
	var rank_text: String = "-" if species == SPECIES_ALIEN else str(rank)
	_text(rank_text, base + Vector2(53, -7), _small,
		COLOUR_RED if rank <= 1 else COLOUR_TEXT, COLOUR_SHADOW)
	var hp: int = DictRead.as_int(view["hp"])
	var hp_max: int = _hp_max
	_text("%d/%d" % [hp, hp_max], base + Vector2(0, 32), _small,
		COLOUR_RED if hp <= hp_max / 2 else COLOUR_TEXT, COLOUR_SHADOW)
	var charges: int = DictRead.as_int(view.get("absorber", 0))
	for k: int in range(mini(charges, RUNG_MAX)):
		_icon(HudTables.LIB_ICONS, HudTables.ICON_WOUND_DOT,
			base + Vector2(48 - 4 * k, 28))


## An armour ladder: one rung per point, every second one past ten.
func _rungs(points: int, foot: Vector2) -> void:
	var count: int = points if points <= RUNG_MAX else RUNG_MAX + (points - RUNG_MAX) / 2
	if points == 255:
		count = 0
	for k: int in range(count):
		_icon(HudTables.LIB_ICONS, HudTables.ICON_ARMOUR_RUNG,
			foot - Vector2(0, RUNG_STEP * k))


## `0x00474850(x + 75, y - 10)`: the frame, one rung per twelve experience
## points, a pair of dots per twelve training points, the tier's discs.
func _experience_block(view: Dictionary) -> void:
	var base: Vector2 = _origin + Vector2(HudTables.PANEL_BLOCK_EXPERIENCE)
	var frame: Texture2D = _icon(HudTables.LIB_ICONS,
		HudTables.ICON_EXPERIENCE_FRAME, base)
	var frame_height: float = frame.get_height() if frame != null else 0.0
	var ep: int = DictRead.as_int(view["ep"])
	var tp: int = DictRead.as_int(view["tp"])
	for k: int in range(mini(ep / Refresh.EP_PER_RANK, RUNG_MAX)):
		_icon(HudTables.LIB_ICONS, HudTables.ICON_ARMOUR_RUNG,
			base + Vector2(7, frame_height - XP_RUNG_STEP * k))
	for k: int in range(mini(tp / Refresh.EP_PER_RANK, RUNG_MAX)):
		var row: float = frame_height - XP_RUNG_STEP * k
		_icon(HudTables.LIB_ICONS, HudTables.ICON_WOUND_DOT, base + Vector2(2, row))
		_icon(HudTables.LIB_ICONS, HudTables.ICON_WOUND_DOT, base + Vector2(14, row))
	for k: int in range(tier_of(ep)):
		_icon(HudTables.LIB_ICONS, HudTables.ICON_TIER_DISC,
			base + Vector2(23, -24 - TIER_STEP * k))


## `0x00475550` -- the experience tier: below 40, 60, 100, or beyond.
static func tier_of(ep: int) -> int:
	for i: int in range(TIER_LIMITS.size()):
		if ep < TIER_LIMITS[i]:
			return i
	return TIER_LIMITS.size()


## `0x00474220(x + 145, y)`: the frame, the name, the weapon and munition
## icons, `ammo/max`, the heat, the malfunction, the heat wedge, the mode
## lamp and the state icon. Alien weapons (ids 17..37) draw nothing.
func _weapon_block(view: Dictionary, wtab: WeaponTable) -> void:
	var weapon: int = DictRead.as_int(view["weapon"])
	if weapon >= WEAPON_ALIEN_LOW and weapon <= WEAPON_ALIEN_HIGH:
		return
	var base: Vector2 = _origin + Vector2(HudTables.PANEL_BLOCK_WEAPON) \
		+ TRAILING_BLOCK_SHIFT
	var frame: Texture2D = _icon(HudTables.LIB_ICONS, HudTables.ICON_WEAPON_FRAME, base)
	var frame_width: float = frame.get_width() if frame != null else 0.0
	_weapon_name = _text(wtab.name_of(weapon), base + Vector2(frame_width, -3),
		_small, COLOUR_TEXT, COLOUR_NAME_SHADOW)
	_icon(HudTables.LIB_WEAPONS, wtab.icon(weapon), base + Vector2(33, 7), true)
	_icon(HudTables.LIB_MUNITION, wtab.type_of(weapon), base + Vector2(23, 27), true)
	var ammo: int = DictRead.as_int(view["ammo"])
	var ammo_max: int = _ammo_max(view, wtab)
	var ammo_text: String = "-/-" if wtab.magazine(weapon) == Refresh.HEAT_NONE \
		else "%d/%d" % [ammo, ammo_max]
	# The movement disc is drawn after this block and sits at `+235`, so the
	# ammunition row is what a wide face loses a digit of.
	_text(ammo_text, base + Vector2(frame_width - 7, 36), _small,
		COLOUR_RED if ammo == 0 else COLOUR_TEXT, COLOUR_SHADOW, false,
		FALLBACK_TEXT_SIZE,
		_origin.x + float(HudTables.PANEL_BLOCK_MOVEMENT.x) \
			+ TRAILING_BLOCK_SHIFT.x - AMMO_DISC_GAP)
	var heat: int = DictRead.as_int(view["heat"])
	var limit: int = _heat_limit(view, wtab)
	if limit != Refresh.HEAT_NONE:
		_text(str(heat), base + Vector2(14, 36), _small, COLOUR_HEAT,
			COLOUR_HEAT_SHADOW)
		_wedge(heat, limit, base + Vector2(43, 19),
			DictRead.to_int32(view["equipment"]).has(Interact.EQUIP_COOLER))
	var malfunction: int = DictRead.as_int(view["malfunction"])
	var mode_text: String = "2*" if weapon >= WEAPON_ALTERNATE_FIRST else str(malfunction)
	_text(mode_text, base + Vector2(37, 36), _small, COLOUR_TEXT, COLOUR_SHADOW)
	if wtab.toggle(weapon) != weapon:
		_icon(HudTables.LIB_ICONS, HudTables.ICON_LAMP_A
			if weapon < WEAPON_ALTERNATE_FIRST else HudTables.ICON_LAMP_B,
			base + Vector2(-22, 31))
	if malfunction >= 1:
		var state: int = mini(malfunction, 3) - 1
		_icon(HudTables.LIB_ICONS, HudTables.ICON_MALFUNCTION_FIRST + state,
			base + Vector2(26, 24))


## Move the weapon's name and its shadow left until the pair ends
## [constant NAME_INVENTORY_GAP] short of every inventory picture on its row,
## or of the inventory's first column when the unit carries nothing. Only the
## readable face: the shipped bitmap already fits (see [method _text]).
func _clear_weapon_name() -> void:
	var over: Label = _weapon_name
	_weapon_name = null
	if over == null or _small != null:
		return
	var width: float = over.get_minimum_size().x
	var row: Rect2 = Rect2(over.position, Vector2(width, over.get_minimum_size().y))
	var limit: float = _origin.x + float(HudTables.PANEL_BLOCK_SKILLS.x) \
		+ TRAILING_BLOCK_SHIFT.x
	for rect: Rect2 in _hover_rects:
		if rect.position.y < row.end.y and rect.end.y > row.position.y:
			limit = minf(limit, rect.position.x)
	var overrun: float = over.position.x + width - (limit - NAME_INVENTORY_GAP)
	if overrun <= 0.0:
		return
	var index: int = _items.find(over)
	over.position.x -= overrun
	# [method _text] adds the shadow immediately before the text.
	if index > 0:
		_items[index - 1].position.x -= overrun


## The heat wedge: `heat * 30 / limit` columns growing from one pixel to
## sixteen, red with the green rising by eight a column; blue when a Cooler
## doubled the cap.
func _wedge(heat: int, limit: int, foot: Vector2, cooled: bool) -> void:
	if limit <= 0:
		return
	var columns: int = mini(heat * WEDGE_COLUMNS / limit, WEDGE_COLUMNS)
	for column: int in range(columns):
		var height: int = 1 + column * (WEDGE_HEIGHT_MAX - 1) / (WEDGE_COLUMNS - 1)
		var bar: ColorRect = ColorRect.new()
		bar.color = Color8(255, mini(column * 8, 255), 255 if cooled else 0)
		bar.position = foot + Vector2(column, -height)
		bar.size = Vector2(1, height)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bar)
		_items.append(bar)


## `0x00474AF0(x + 235, y + 15, mp)`: the disc and the number centred on it.
func _movement_block(view: Dictionary) -> void:
	var base: Vector2 = _origin + Vector2(HudTables.PANEL_BLOCK_MOVEMENT) \
		+ TRAILING_BLOCK_SHIFT
	_icon(HudTables.LIB_ICONS, HudTables.ICON_MOVEMENT_DISC, base)
	var _points: Label = _text(str(DictRead.as_int(view["mp"])),
		base + Vector2(11, 14), _small, COLOUR_TEXT, COLOUR_DISC_SHADOW, true)


## `0x00475A60(x + 275, y - 10)`: one `inv.LIB` element per piece of
## equipment the unit carries, on an 18 by 19 grid.
func _inventory(view: Dictionary) -> void:
	var base: Vector2 = _origin + Vector2(HudTables.PANEL_BLOCK_SKILLS) \
		+ TRAILING_BLOCK_SHIFT
	var hints: Dictionary = {}
	for id: int in DictRead.to_int32(view["equipment"]):
		if not INVENTORY_ELEMENTS.has(id):
			continue
		var element: int = DictRead.as_int(INVENTORY_ELEMENTS[id])
		var at: Vector2 = base + Vector2(
			float((element % INVENTORY_COLUMNS) * INVENTORY_STEP.x),
			float((element / INVENTORY_COLUMNS) * INVENTORY_STEP.y))
		var drawn: int = _items.size()
		var _face: Texture2D = _icon(HudTables.LIB_INVENTORY, element, at, true)
		if _items.size() == drawn:
			continue
		var picture: TextureRect = _items[drawn] as TextureRect
		if picture == null:
			continue
		var rect: Rect2 = Rect2(picture.position, picture.size)
		_hover_rects.append(rect)
		_hover_ids.append(id)
		hints[element] = {"rect": rect, "text": equipment_name(id)}
	_sync_inventory_hints(hints)


func _ensure_inventory_hints() -> void:
	if not _item_hints.is_empty():
		return
	for element: int in range(INVENTORY_ELEMENTS.size()):
		var area: HintControl = HintControl.new()
		area.name = "ItemHint%d" % element
		area.face = _font
		area.readable_size = CampaignScreen.readable_size(
			CampaignScreen.FNT_LABEL)
		area.ink = CampaignScreen.INK_LABEL
		area.mouse_filter = Control.MOUSE_FILTER_PASS
		area.z_index = 1
		area.visible = false
		add_child(area)
		_item_hints.append(area)


## The two halves of the band, `fcn.004637c0`'s rectangles, built once.
## Above the tooltip carriers (`z_index` 2 to their 1) and down until
## [method set_cycling] raises them.
func _ensure_cycle_zones() -> void:
	if not _cycle_zones.is_empty():
		return
	for step: int in [Deployment.PREV, Deployment.NEXT]:
		var zone: Control = Control.new()
		zone.name = "CyclePrev" if step == Deployment.PREV else "CycleNext"
		zone.mouse_filter = Control.MOUSE_FILTER_STOP
		zone.z_index = 2
		zone.visible = false
		zone.gui_input.connect(_on_zone_input.bind(step))
		add_child(zone)
		_cycle_zones.append(zone)
	_layout_cycle_zones()


func _layout_cycle_zones() -> void:
	if _cycle_zones.is_empty():
		return
	var rects: Array[Rect2] = Deployment.band_rects(size)
	for index: int in range(_cycle_zones.size()):
		_cycle_zones[index].position = rects[index].position
		_cycle_zones[index].size = rects[index].size


func _on_zone_input(event: InputEvent, step: int) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click == null or not click.pressed \
			or click.button_index != MOUSE_BUTTON_LEFT:
		return
	cycled.emit(step)


func _sync_inventory_hints(wanted: Dictionary) -> void:
	_ensure_inventory_hints()
	for element: int in range(_item_hints.size()):
		var area: HintControl = _item_hints[element]
		if not wanted.has(element):
			if area.visible:
				area.visible = false
			area.tooltip_text = ""
			continue
		var entry: Dictionary = DictRead.as_dict(wanted[element])
		var rect: Rect2 = entry["rect"]
		var text: String = DictRead.as_string(entry["text"])
		if area.position != rect.position:
			area.position = rect.position
		if area.size != rect.size:
			area.size = rect.size
		if area.tooltip_text != text:
			area.tooltip_text = text
		var shown: bool = text != ""
		if area.visible != shown:
			area.visible = shown


## One sprite at *at*, less its own anchor when the original subtracted it.
func _icon(library: String, element: int, at: Vector2,
		anchored: bool = false) -> Texture2D:
	if _art == null:
		return null
	var texture: Texture2D = _art.sprite(library, element)
	if texture == null:
		return null
	var view: TextureRect = TextureRect.new()
	view.texture = texture
	view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	view.stretch_mode = TextureRect.STRETCH_KEEP
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	view.position = at
	if anchored:
		view.position -= Vector2(_art.sprite_offset(library, element))
	view.size = texture.get_size()
	add_child(view)
	_items.append(view)
	return texture


## A line of text with the one-pixel shadow the engine's `aPrintLibText`
## draws under everything on the panel. *at* is the engine's own text
## position, whose y is the **bottom** of the glyphs: the turn is printed at
## y 22 inside a groove that ends at 24, and the name at y 397 above the class
## icon whose top is 401 -- neither fits with y as the top.
## Two labels, the shadow one pixel down and right of the text
## (`aPrintLibText` is called twice, `0x00474A70` and `0x00474A8F`).
##
## *centred* moves **both** by half the text's width: the shadow is a second
## label and not a property of the first, so centring the returned one alone
## leaves the dark copy standing where the number used to start.
## *right_limit*, where it is given, is the panel-space x the text must not
## run past. It moves the pair **left**, and only for the readable face: the
## shipped bitmap is narrow enough that every row already clears its
## neighbour, and the anchors are the original's measured ones (docs/43
## section 5). A proportional face is not, and the plate's own draw order --
## the weapon block, then the movement disc over it -- turns the overrun into
## a digit hidden under the disc rather than into a wider row.
func _text(text: String, at: Vector2, font: FontFile, colour: int,
		shadow: int, centred: bool = false,
		fallback_size: int = FALLBACK_TEXT_SIZE,
		right_limit: float = 0.0) -> Label:
	var under: Label = _label(text, at + Vector2(1, 1), font, shadow,
		fallback_size)
	add_child(under)
	_items.append(under)
	var over: Label = _label(text, at, font, colour, fallback_size)
	add_child(over)
	_items.append(over)
	if centred:
		var half: float = over.get_minimum_size().x * 0.5
		over.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		under.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		over.position.x -= half
		under.position.x -= half
	if font == null and right_limit > 0.0:
		var overrun: float = over.position.x \
			+ over.get_minimum_size().x - right_limit
		if overrun > 0.0:
			over.position.x -= overrun
			under.position.x -= overrun
	return over


func _label(text: String, at: Vector2, font: FontFile, colour: int,
		fallback_size: int = FALLBACK_TEXT_SIZE) -> Label:
	var label: Label = Label.new()
	label.text = text
	var height: int = font.fixed_size if font != null else fallback_size
	# **The anchor is a baseline, not a top edge.** The engine's own
	# `aPrintLibText` draws from the row's bottom, and a shipped bitmap face
	# is all ascent -- its `fixed_size` *is* the distance the text rises above
	# the anchor. A readable face is not: about a fifth of its size is descent,
	# so lifting by the nominal size dropped every line that fifth too low and
	# is what pushed the name onto the portrait and `10/10` onto the disc.
	var lift: float = float(height)
	if font == null and ThemeDB.fallback_font != null:
		lift = ThemeDB.fallback_font.get_ascent(fallback_size)
	label.position = at - Vector2(0.0, lift)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		label.add_theme_font_override("font", font)
		label.add_theme_font_size_override("font_size", font.fixed_size)
	else:
		label.add_theme_font_size_override("font_size", fallback_size)
	label.add_theme_color_override("font_color", rgb565(colour))
	return label


## A 16-bit `RRRRRGGGGGGBBBBB` colour as the engine writes them.
static func rgb565(value: int) -> Color:
	return Color8(((value >> 11) & 0x1F) << 3, ((value >> 5) & 0x3F) << 2,
		(value & 0x1F) << 3)


## The texts the last refresh drew, for a driver or a suite.
func texts() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for item: Control in _items:
		var label: Label = item as Label
		if label != null and not out.has(label.text):
			out.append(label.text)
	return out


## Where the last refresh drew the inventory pictures, in panel coordinates.
func inventory_rects() -> Array[Rect2]:
	return _hover_rects.duplicate()


## How many sprites the last refresh drew.
func icon_count() -> int:
	var n: int = 0
	for item: Control in _items:
		if item is TextureRect:
			n += 1
	return n


## The equipment catalogue's own names, from `tables/balance.json`'s
## `equipment` rows -- the same list the Item List screen reads. Rows with no
## name are skipped, so an id the cache does not carry simply has no hint.
func use_equipment_names(rows: Array) -> void:
	_equipment_names.clear()
	for entry: Variant in rows:
		var row: Dictionary = entry
		var text: String = DictRead.as_string(row.get("name", ""))
		if text == "":
			continue
		_equipment_names[DictRead.as_int(row["id"])] = text


## The name the hint line shows for *id*, or `""`.
func equipment_name(id: int) -> String:
	if not _equipment_names.has(id):
		return ""
	return DictRead.as_string(_equipment_names[id])


## The inventory pictures the last refresh drew, in the panel's own
## coordinates -- a copy, for a suite or a driver.
func item_rects() -> Array[Rect2]:
	return _hover_rects.duplicate()


## The equipment ids behind [method item_rects], in the same order.
func item_ids() -> PackedInt32Array:
	return _hover_ids.duplicate()


## The equipment id whose picture covers *at*, in the panel's own
## coordinates, or [constant NO_ITEM].
func item_at(at: Vector2) -> int:
	for index: int in range(_hover_rects.size()):
		if _hover_rects[index].has_point(at):
			return _hover_ids[index]
	return NO_ITEM


## The tooltip carrier whose picture covers *at*, for a suite or driver.
func item_hint_at(at: Vector2) -> HintControl:
	for area: HintControl in _item_hints:
		if area.visible and Rect2(area.position, area.size).has_point(at):
			return area
	return null
