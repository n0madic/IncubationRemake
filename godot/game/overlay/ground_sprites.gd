class_name GroundSprites
extends Node3D

## The ground overlay of a mission -- `fcn.00417E70` in `aBattleMap.cpp`,
## docs/43 section 3: the movement points left on every reachable cell, the
## warp targets, the hit bands on the enemies in range, the frame on the cell
## under the pointer and the marks over the player's own units.
##
## **It is a pass of 2D sprites after the frame, not terrain.** The engine
## projects each cell's ground object and blits a `mp1.LIB`/`mp.LIB` element
## at the projected point less the element's anchor, through `fcn.004475D0`,
## with no depth test at all -- a marked field is never hidden by what stands
## in front of it. docs/97 section 45.2 read the opposite and the green quads
## of `highlight.gd` were built on that; this replaces them.
##
## Like [MapMarkers], every mark is a [Sprite3D] with `fixed_size` and
## `no_depth_test`: one texel is one unit of the 640x480 layout through the
## mission window's own focal length, so the shipped 9x9 digits come out the
## size the original draws them whatever the window is.
##
## **It reads the world and never writes it.** The cell states are translated
## from [MoveMapResult] and [method World.target_bands] to the engine's own
## values before [HudTables] is consulted, so the table is the engine's.

## Clear of the floor, in Godot units, for the same reason [MapMarkers.LIFT]
## exists: a mark on a cell with something standing on it stays on top.
const LIFT: float = 0.1
## No mark this pass: the engine's own "nothing chosen yet" for the element
## slots the unit pass writes (`-1` at `0x00418749`).
const NO_ELEMENT: int = -1

## One texel of a mark, in Godot units, at the mission window's focal length
## (400 for the original's 520-wide window). Not [MapMarkers.pixel_size],
## which is the campaign map's 518-wide window and 398.
static func pixel_size() -> float:
	return 1.0 / CameraRig.focal_length(float(HudTables.WINDOW.size.x))

## What the last [method refresh] drew, cell by cell, for a driver or a suite
## to read back: `cell -> [[library, element], ...]`, in drawing order.
var _drawn: Dictionary[Vector2i, Array] = {}
## The marks that blink: hidden on the odd tick.
var _blink_off: Array[Sprite3D] = []
var _art: Art = null


## Redraw the whole overlay from the world.
##
## *query* is the selection's fill (or null), *hover* the cell under the
## pointer, *bands* [method World.target_bands] for the selection,
## *current_player* the side whose units get the near-view marks, and *far*
## whether the camera is above [constant HudTables.ZOOM_GATE].
##
## **Nothing marks a walk.** State 100 -- `aWalkMoveMap`'s reconstructed path
## -- is written by every move in the game, the player's and the computer's
## alike, and is drawn by none of them: docs/43 section 3.1.
func refresh(art: Art, world: World, selected: int, query: MoveMapResult,
		hover: Vector2i, bands: Dictionary[Vector2i, int],
		current_player: int, far: bool) -> void:
	_art = art
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_drawn.clear()
	_blink_off.clear()
	if art == null or world == null:
		return
	var width: int = world.resource.width
	var states: Dictionary[Vector2i, int] = cell_states(world, selected, query,
		bands)
	var hover_state: int = DictRead.as_int(states.get(hover, HudTables.STATE_PLAIN))
	var hover_legal: bool = HudTables.HOVER_GATED_STATES.has(hover_state)
	# The cells. The gated states draw only while the pointer is over a
	# legal one (`var_34h`); the hovered cell's own digit blinks and takes
	# the frame.
	for cell: Vector2i in states:
		var state: int = states[cell]
		var mp_left: int = query.mp_left_at(cell.x, cell.y) if query != null else 0
		var sprite: Array = HudTables.sprite_for_state(state, mp_left)
		if sprite.is_empty():
			continue
		if HudTables.HOVER_GATED_STATES.has(state) and not hover_legal:
			continue
		var mark: Sprite3D = _place(world, cell, DictRead.as_string(sprite[0]),
			DictRead.as_int(sprite[1]))
		if mark == null:
			continue
		_note(cell, sprite)
		if cell == hover and (state == HudTables.STATE_REACHABLE
				or (state >= HudTables.STATE_BAND_FIRST
				and state <= HudTables.STATE_DEPLOY_LAST)):
			_blink_off.append(mark)
	# The frame under the pointer: a legal cell, or a visible unit's cell.
	if hover.x >= 0 and (states.has(hover) or _unit_shown_at(world, hover)):
		var frame: Sprite3D = _place(world, hover, HudTables.LIB_MARKERS,
			HudTables.HOVER_FRAME)
		if frame != null:
			_note(hover, [HudTables.LIB_MARKERS, HudTables.HOVER_FRAME])
	# The units.
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			continue
		if not Fog.is_drawn(view):
			continue
		var cell: Vector2i = Vector2i(DictRead.as_int(view["x"]),
			DictRead.as_int(view["y"]))
		if far:
			_place_far(world, cell, view)
			continue
		if DictRead.as_int(view["player"]) != current_player:
			continue
		if states.get(cell, 0) == HudTables.STATE_SPECIAL_OBJECT:
			continue
		_place_near(world, cell, view)
	# The victory-point letters, far view only.
	if far:
		for y: int in range(world.resource.height):
			for x: int in range(width):
				var letter: int = HudTables.vp_letter(
					world.state.action_point_at(y * width + x))
				if letter >= 0:
					var vp: Sprite3D = _place(world, Vector2i(x, y),
						HudTables.LIB_MARKERS, letter)
					if vp != null:
						_note(Vector2i(x, y), [HudTables.LIB_MARKERS, letter])


## The engine's cell states this overlay draws from, `cell -> state`:
## the fill's 10 and 60, the selection's own cell 50 and the bands 30..34.
## Static so a suite can check the translation alone.
##
## **100 is not among them**, and that is the point of the check on it: the
## state exists and the table has an element for it, but no walk in the
## original ever shows one (docs/43 section 3.1).
static func cell_states(world: World, selected: int, query: MoveMapResult,
		bands: Dictionary[Vector2i, int]) -> Dictionary[Vector2i, int]:
	var states: Dictionary[Vector2i, int] = {}
	if world == null:
		return states
	if query != null:
		for y: int in range(query.height):
			for x: int in range(query.width):
				var state: int = query.state_at(query.index_of(x, y))
				if state == MoveMapResult.STATE_REACHABLE:
					states[Vector2i(x, y)] = HudTables.STATE_REACHABLE
				elif state == MoveMapResult.STATE_WARP:
					states[Vector2i(x, y)] = HudTables.STATE_WARP
	if selected >= 0 and world.has_unit(selected):
		var view: Dictionary = world.unit_view(selected)
		states[Vector2i(DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))] \
			= HudTables.STATE_OWN_CELL
	# **A band on an empty cell is not drawn.** The bands are computed on the
	# truth when the unit is selected and the mirror lags it by a command, so
	# a victim the shot has killed is still under a band until its delta
	# lands -- and lands it does, at the death stage, from which frame the
	# cell has no body and the aim goes with it. The original's overlay is
	# drawn from the unit array of the moment, which is the same test.
	for cell: Vector2i in bands:
		if _unit_shown_at(world, cell):
			states[cell] = bands[cell]
	return states


## Advance the blink: *odd* is bit 0 of the 100 ms counter.
func tick(odd: bool) -> void:
	for mark: Sprite3D in _blink_off:
		mark.visible = not odd


## What the last refresh drew on *cell*: `[library, element]` pairs in
## drawing order, or an empty array.
func drawn_at(cell: Vector2i) -> Array:
	return _drawn.get(cell, [])


func _note(cell: Vector2i, sprite: Array) -> void:
	if not _drawn.has(cell):
		_drawn[cell] = []
	var list: Array = _drawn[cell]
	list.append(sprite)


## Every cell the last refresh drew on.
func drawn_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell: Vector2i in _drawn:
		out.append(cell)
	return out


static func _unit_shown_at(world: World, cell: Vector2i) -> bool:
	if not world.state.in_bounds(cell.x, cell.y):
		return false
	var slot: int = world.state.unit_at(world.state.index_of(cell.x, cell.y))
	if slot == MapState.NO_UNIT:
		return false
	var view: Dictionary = world.unit_view(slot)
	return not view.is_empty() and DictRead.as_int(view["hp"]) > 0 \
		and Fog.is_drawn(view) and not Fog.is_contact(view)


## The far view's flag over a unit: the owner's colour for a visible one,
## `map[6]` for a detected one -- at `map[4]`'s anchors, the quirk the engine
## has (`0x00418580` reads element 4's deltas for element 6).
func _place_far(world: World, cell: Vector2i, view: Dictionary) -> void:
	if Fog.is_contact(view):
		var mark: Sprite3D = _place(world, cell, HudTables.LIB_FAR,
			HudTables.FAR_FLAG_HIDDEN, HudTables.FAR_FLAG_NEUTRAL)
		if mark != null:
			_note(cell, [HudTables.LIB_FAR, HudTables.FAR_FLAG_HIDDEN])
		return
	var flag: int = HudTables.far_flag(DictRead.as_int(view["player"]))
	var own: Sprite3D = _place(world, cell, HudTables.LIB_FAR, flag)
	if own != null:
		_note(cell, [HudTables.LIB_FAR, flag])


## The near view's mark over one of the current player's units: the hit
## points as a digit, or 49 on overwatch, or 50 with a jammed weapon; a
## panicking unit takes 54 as its frame.
##
## The engine has a fourth arm here -- a unit with points left standing on a
## state-100 cell alternates `mp[51]`/`mp[52]` on the tick
## (`0x004186BA`..`0x00418735`) -- and it is not reproduced, for the reason
## the path itself is not: nothing in play ever leaves a cell in state 100
## while the overlay is blitted (docs/43 section 3.1).
##
## **The digit needs movement points.** `0x004186AF` reads `+0x15` and jumps
## the whole digit block when it is zero, so the numbers over the squad are
## "these have not finished their turn" and go out one by one as the units
## spend their points. The overwatch and jam marks are written *after* that
## jump lands (`0x00418710`), so a unit with nothing left still shows them.
func _place_near(world: World, cell: Vector2i, view: Dictionary) -> void:
	var points: int = DictRead.as_int(view["mp"])
	var element: int = NO_ELEMENT
	if points != 0:
		element = mini(DictRead.as_int(view["hp"]), HudTables.HP_DIGIT_MAX)
	var action: int = DictRead.as_int(view["action_state"])
	if action == HudTables.ACTION_DEFENDING:
		element = HudTables.MARKER_DEFENDING
	elif DictRead.as_int(view["malfunction"]) != 0:
		element = HudTables.MARKER_MALFUNCTION
	if element != NO_ELEMENT:
		var mark: Sprite3D = _place(world, cell, HudTables.LIB_MARKERS, element)
		if mark != null:
			_note(cell, [HudTables.LIB_MARKERS, element])
	if action == HudTables.ACTION_PANIC:
		var panic: Sprite3D = _place(world, cell, HudTables.LIB_MARKERS,
			HudTables.MARKER_PANIC)
		if panic != null:
			_note(cell, [HudTables.LIB_MARKERS, HudTables.MARKER_PANIC])


## One element of *library* over *cell*, anchored the way the blitter's
## callers anchor it: the projected point less the element's `+0x1C/+0x20`.
## *anchor_from* names another element whose anchors are used instead.
func _place(world: World, cell: Vector2i, library: String, element: int,
		anchor_from: int = -1) -> Sprite3D:
	if not world.state.in_bounds(cell.x, cell.y):
		return null
	var texture: Texture2D = _art.sprite(library, element)
	if texture == null:
		return null
	var anchor: Vector2i = _art.sprite_offset(library,
		anchor_from if anchor_from >= 0 else element)
	var mark: Sprite3D = make_sprite(texture, anchor)
	var height: int = world.state.height_at(world.state.index_of(cell.x, cell.y))
	mark.position = WorldSpace.cell_centre(cell.x, cell.y, height) \
		+ Vector3(0.0, LIFT, 0.0)
	add_child(mark)
	return mark


## A mark: billboard, `fixed_size`, `no_depth_test`, nearest filtering, and
## the texel at *anchor* (from the image's top-left) on the sprite's origin.
##
## [Sprite3D] lays a non-centred texture with its bottom-left on the origin
## and grows it right and **up**, and `offset` moves that corner -- measured
## with the generated mesh's bounds, and pinned by `test_hud.gd` because the
## sign is exactly the kind of thing that reads right both ways.
static func make_sprite(texture: Texture2D, anchor: Vector2i) -> Sprite3D:
	var mark: Sprite3D = Sprite3D.new()
	mark.texture = texture
	mark.centered = false
	mark.offset = anchor_offset(anchor, texture.get_height())
	mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mark.fixed_size = true
	mark.no_depth_test = true
	mark.shaded = false
	mark.double_sided = true
	mark.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mark.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	mark.pixel_size = pixel_size()
	return mark


## The [member Sprite3D.offset] that puts texel *anchor* on the origin for a
## texture *height* texels tall: the top-left goes to `(-x, +y)` in a space
## whose y points up, and the rect's corner is one height below the top.
static func anchor_offset(anchor: Vector2i, height: int) -> Vector2:
	return Vector2(-float(anchor.x), float(anchor.y) - float(height))
