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
## Every mark the last refresh placed, by cell, and where each was placed --
## what a platform ride moves (see [method shift_cells]).
var _marks: Dictionary[Vector2i, Array] = {}
var _bases: Dictionary[Sprite3D, Vector3] = {}
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
## *hover_gated* is the original's rule: the movement dots and the target bands
## draw only while the pointer is over a legal cell. A touch screen has no
## pointer to stand there -- the finger is either pressing or gone -- so the
## caller turns the gate off in that mode and the selection's own cells are
## shown for as long as it is selected (docs/43 section 3, a divergence).
## *deploying* is the caller's word that the place interface is up: the
## turn counter alone says so for a bare world, but a campaign host also
## asks for the mission to be the screen ([method SliceMain._deploying]).
func refresh(art: Art, world: World, selected: int, query: MoveMapResult,
		hover: Vector2i, bands: Dictionary[Vector2i, int],
		current_player: int, far: bool, hover_gated: bool = true,
		deploying: bool = false) -> void:
	_art = art
	for child: Node in get_children():
		remove_child(child)
		child.queue_free()
	_drawn.clear()
	_blink_off.clear()
	_marks.clear()
	_bases.clear()
	if art == null or world == null:
		return
	var width: int = world.resource.width
	# The place interface's dots: `markDeploymentCells` runs for the incoming
	# player while the counter is 0 (docs/29 section 1.2), and every cell of
	# that player's is in state 70..73 -- the occupied ones too, which is the
	# affordance for taking a soldier back.
	var deploying_player: int = current_player \
		if deploying and current_player >= 0 \
		and current_player <= HudTables.FAR_PLAYER_MAX else -1
	var states: Dictionary[Vector2i, int] = cell_states(world, selected, query,
		bands, deploying_player)
	var hover_state: int = DictRead.as_int(states.get(hover, HudTables.STATE_PLAIN))
	var hover_legal: bool = not hover_gated \
		or HudTables.HOVER_GATED_STATES.has(hover_state)
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
## *deploying_player* >= 0 marks that player's deployment cells with the
## place interface's state, `0x46 + player` (`0x00431118`).
static func cell_states(world: World, selected: int, query: MoveMapResult,
		bands: Dictionary[Vector2i, int],
		deploying_player: int = -1) -> Dictionary[Vector2i, int]:
	var states: Dictionary[Vector2i, int] = {}
	if world == null:
		return states
	if deploying_player >= 0:
		for cell: Vector2i in world.deployment_cells(deploying_player):
			states[cell] = HudTables.STATE_DEPLOY_FIRST + deploying_player
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
## The engine has a fourth arm here -- a cell whose `mp` slot already holds
## 51 alternates `mp[51]`/`mp[52]` on the tick (`0x004186BA`..`0x00418735`),
## and **that is the selection's own state-50 cell** (docs/43 section 3.2,
## measured natively on 2026-09-12 by `tools/hud_probe.py`): the corner frame
## with the digit on the odd tick, the 16x16 cross alone on the even one. The
## remake draws the frame steady and does not alternate it -- a divergence
## recorded there, not played, because what the original's frames show over
## a unit is itself the open question below.
##
## **No hit-point digit** (docs/43 D12, 2026-09-07; narrowed 2026-09-12).
## The listing's `0x004186AF`..`0x00418708` puts `mp[min(hp, 15)]` on a
## current player's unit while `+0x15` is non-zero, and the remake drew it;
## the original, on the player's own turn with a fresh squad, shows nothing
## over a unit that is not selected. The overlay routine itself, stepped
## inside the live game, **does** blit the digit over such a unit, so the
## gate is not in it -- what the frames show is a compositing question
## (docs/43 open question 1), and until a frame settles it the picture
## follows the frames rather than the routine. The overwatch, jam and panic
## marks are written past that block (`0x00418710`, `0x0041872F`) and stay.
func _place_near(world: World, cell: Vector2i, view: Dictionary) -> void:
	var element: int = NO_ELEMENT
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
	if not _marks.has(cell):
		_marks[cell] = []
	var on_cell: Array = _marks[cell]
	on_cell.append(mark)
	_bases[mark] = mark.position
	return mark


## Draw every mark on *cells* `offset` engine units from where it was placed.
##
## The engine blits each mark at the **projected point of the cell's ground
## object** (docs/43 section 3), and a platform ride translates those objects
## by `0x140` a frame (docs/20 section 7.4 step 2) -- so the bands and digits
## on a riding block travel with the deck, and the bodies on it. The
## picture's copy of that: [Scenery.shift_objects] moves the objects and this
## moves the marks over them by the same offset. Zero puts them back. The
## next [method refresh] places everything afresh from the world, which is
## where the marks land once the ride's drain redraws. Answers how many moved.
func shift_cells(cells: Array[Vector2i], offset: Vector3i) -> int:
	var by: Vector3 = WorldSpace.to_godot(offset.x, offset.y, offset.z)
	var moved: int = 0
	for cell: Vector2i in cells:
		if not _marks.has(cell):
			continue
		for entry: Variant in _marks[cell]:
			var mark: Sprite3D = entry
			if not is_instance_valid(mark) or not _bases.has(mark):
				continue
			mark.position = _bases[mark] + by
			moved += 1
	return moved


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
