class_name CellObjects
extends RefCounted

## The transient objects a control-map cell owns -- docs/23 section 7.1 and
## docs/42 section 9.1.  The twin of `tools/inclib/ctrlmap.py`.
##
## Four placers write the cell bytes `+0x0E`..`+0x13` and take a slot in the
## **80-entry** special-object array `[0x004FA828]`:
##
## [codeblock]
## +0x0E  timer         fire, mine, shield   the countdown / intensity
## +0x0F  object        fire, mine, shield   the array slot, 255 = none
## +0x10  state         fire, mine, shield   1 fire, 2 mine, 3 shield
## +0x11  decal object  glow                 the array slot, 255 = none
## +0x12  decal phase   glow                 1 or 2, the ground fire's phase
## +0x13  decal state   glow                 4 while a glow stands there
## [/codeblock]
##
## `+0x10` is the one the rules read: the move map refuses a fire outright, a
## mine to anyone but the aliens, and a shield to everyone including the unit
## standing in it.  `+0x13` carries no movement rule, but the glow it marks
## becomes a fire that **removes every unit around it** two rounds later.
##
## The placers here write cell bytes and nothing else: the rules need the slot,
## not the position. Where the object **goes** is [method object_position],
## the same instructions transcribed -- the fire and the glow scatter inside
## the cell with two `aRandom2` draws each and the mine and the shield take the
## cell's own object position exactly. That generator is the presentation's
## (docs/22 section 3.2), so it is handed in rather than kept here.
##
## Both are measured: `presentation_gold`'s eight `special_*` phases read the
## whole 66-byte record back and compare all three position fields and the
## draw count (docs/97 section 37).
##
## **The model name is a gate.**  `aCreateSpecialObject` resolves the name and
## answers -1 for one the loaded world set does not carry.  All nine sets carry
## `A_FIRE1/2/3`, `A_MINE` and `A_SHILD`; only `World_D00` carries `GLOW1/2`,
## and the two missions that use `SetGroundFire` are both in it.  Measured in
## the live engine (docs/97 section 37).

const OBSTACLE_NONE: int = MapState.OBSTACLE_NONE
const OBSTACLE_FIRE: int = MapState.OBSTACLE_FIRE
const OBSTACLE_MINE: int = MapState.OBSTACLE_MINE
const OBSTACLE_SHIELD: int = MapState.OBSTACLE_SHIELD
const DECAL_NONE: int = MapState.DECAL_NONE
const DECAL_GLOW: int = MapState.DECAL_GLOW
const NO_OBJECT: int = MapState.NO_OBJECT

## `0x0042FCB0`'s two phases and the models they name.  Phase 2 is what
## `SetGroundFire` lays; the round tick decays it to 1 and the next round's
## sweep ignites it.
const GLOW_PHASE_LIT: int = 1
const GLOW_PHASE_FRESH: int = 2
const GLOW_MODEL_LIT: String = "GLOW2.3DI"
const GLOW_MODEL_FRESH: String = "GLOW1.3DI"

const FIRE_MODEL_SMALL: String = "A_FIRE3.3DI"
const FIRE_MODEL_MEDIUM: String = "A_FIRE2.3DI"
const FIRE_MODEL_LARGE: String = "A_FIRE1.3DI"
const MINE_MODEL: String = "A_MINE.3DI"
const SHIELD_MODEL: String = "A_SHILD.3DI"

## The field types the fire, mine and shield placers accept.
const PLACER_FIELD_TYPES: Array[int] = [0, 1, 6, 8]
## The fire placer's **first** gate is the cell's action point, not its field
## type: `cmp al, 0x47` at `0x0042F894` is 71, a destroyed entry point, which
## burns whatever its field type says.
const FIRE_ACTION_POINT: int = 71
## `cmp eax, 0x640` -- the fire refuses a cell more than half a field away in
## height from the z its caller passes.
const FIRE_HEIGHT_WINDOW: int = 0x640
## `mov byte [ebp + 0x0E], 2` at `0x0042FBF9`, written **before** the
## already-a-shield return, so a second Plasma hit refreshes the countdown
## without making a second object.
const SHIELD_TIMER: int = 2

## `0x0040D962`..`0x0040D9FF` -- weapon 40 lays **nine** fires around the target
## cell, the centre at subtype 4 and the eight neighbours at 3, all at the
## centre cell's own height.  In call order: `(dx, dy, subtype)`.
const NINE_FIRES: Array[Vector3i] = [
	Vector3i(-1, 0, 3), Vector3i(-1, -1, 3), Vector3i(-1, 1, 3),
	Vector3i(1, 0, 3), Vector3i(1, -1, 3), Vector3i(1, 1, 3),
	Vector3i(0, 0, 4), Vector3i(0, -1, 3), Vector3i(0, 1, 3),
]

## The impact arms of `aPlayFightAnimation` that change the map.
const WEAPON_GROUND_FIRE: int = 40
const WEAPON_MINE: int = 42
const WEAPON_SHIELD: int = 43

## `0x0046E0BF` -- the destroyed entry point writes its action point first,
## then burns with subtype 6 at `cell height - 0xA0`.  Nothing writes the
## height: the drop is the placer's z argument and reaches only its window.
const ENTRY_POINT_FIRE_SUBTYPE: int = 6
const ENTRY_POINT_FIRE_Z_DROP: int = 0xA0

## `0x004308C0`'s eight directions, in the order it numbers them.  The ground
## fire is the one caller that passes the diagonal flag **set** (`push 1` at
## `0x00415963`), so all eight reach a cell.
const STEP_DELTA: Array[Vector2i] = [
	Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, 0),
	Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1), Vector2i(-1, -1),
]


## `push 0x258 / push 0xFFFFFED4` -- the fire's and the glow's scatter,
## `aRandom2(-300, 600)`, drawn twice: the **first** draw is added to the
## object's y and the second to its x (`0x0042F9F2`..`0x0042FA1A`).
const SCATTER_BASE: int = -300
const SCATTER_SPAN: int = 600


## Where a placer puts its object, given the cell's own object as `origin`.
##
## The mine and the shield take it unchanged; the fire and the glow scatter
## around it with two draws from `rng`. A null `rng` scatters by zero, which is
## a picture with no generator rather than a wrong one.
static func object_position(origin: Vector3i, state: int,
		rng: IncRandom) -> Vector3i:
	if (state != MapState.OBSTACLE_FIRE and state != MapState.DECAL_GLOW) \
			or rng == null:
		return origin
	# The order is the engine's: the first draw lands on **y**.
	var y: int = origin.y + rng.draw(SCATTER_BASE, SCATTER_SPAN)
	var x: int = origin.x + rng.draw(SCATTER_BASE, SCATTER_SPAN)
	return Vector3i(x, y, origin.z)


## `aCreateSpecialObject` `0x004069C0` -- the first free slot, or -1.
##
## Two failures, both the engine's: a full array, and a model the loaded world
## set does not carry (*"unknown object!"*, `0x004069F4`).
static func create_object(state: MapState, kind: int, model: String) -> int:
	var models: PackedStringArray = state.special_models()
	if not models.is_empty() and not models.has(model):
		return -1
	for oid: int in range(MapState.SPECIAL_OBJECT_SLOTS):
		if state.object_state(oid) == NO_OBJECT:
			state.set_object_state(oid, kind)
			return oid
	return -1


## `aDeleteSpecialObject` `0x00406960` -- the guard every cell-based detonation
## is behind (docs/26 section 6.2).
##
## True for an id in 0..80, having marked the slot free; false for anything
## else, which is the `CHECK` failure the walk's mine arm returns on.
static func delete_object(state: MapState, object_id: int) -> bool:
	if object_id < 0 or object_id > MapState.SPECIAL_OBJECT_SLOTS:
		return false
	if object_id < MapState.SPECIAL_OBJECT_SLOTS:
		state.set_object_state(object_id, NO_OBJECT)
	return true


## The model the fire placer's switch picks for a subtype.
static func fire_model(subtype: int) -> String:
	if subtype == 0 or subtype == 1:
		return FIRE_MODEL_SMALL
	if subtype == 2 or subtype == 3:
		return FIRE_MODEL_MEDIUM
	return FIRE_MODEL_LARGE


## `0x0042F840` -- burning ground, `+0x10 = 1`.  The object id, or -1.
##
## The one placer that clears what is already on the cell: a mine's object is
## deleted **without** detonating it, and a shield refuses the whole call.
static func place_fire(state: MapState, x: int, y: int, subtype: int,
		z: int) -> int:
	if not state.in_bounds(x, y):
		return -1
	var i: int = state.index_of(x, y)
	if state.action_point_at(i) != FIRE_ACTION_POINT \
			and not PLACER_FIELD_TYPES.has(state.field_type_at(i)):
		return -1
	if absi(state.height_at(i) - z) >= FIRE_HEIGHT_WINDOW:
		return -1
	if state.obstacle_at(i) != OBSTACLE_NONE:
		if state.obstacle_at(i) == OBSTACLE_SHIELD:
			return -1
		if state.effect_at(MapState.OBJECT_SLOT, i) != NO_OBJECT:
			var _freed: bool = delete_object(
				state, state.effect_at(MapState.OBJECT_SLOT, i))
	var oid: int = create_object(state, OBSTACLE_FIRE, fire_model(subtype))
	if oid < 0:
		state.set_effect(MapState.TIMER_SLOT, i, 0)
		state.set_obstacle(i, OBSTACLE_NONE)
		return -1
	state.set_effect(MapState.OBJECT_SLOT, i, oid)
	state.set_effect(MapState.TIMER_SLOT, i, subtype)
	state.set_obstacle(i, OBSTACLE_FIRE)
	return oid


## `0x0042FA70` -- a mine, `+0x10 = 2`.
##
## It neither deletes what stood there nor refuses a shield: the two bytes are
## overwritten and whatever object the cell named is orphaned.  As it is.
static func place_mine(state: MapState, x: int, y: int) -> int:
	if not state.in_bounds(x, y):
		return -1
	var i: int = state.index_of(x, y)
	if not PLACER_FIELD_TYPES.has(state.field_type_at(i)):
		return -1
	state.set_effect(MapState.TIMER_SLOT, i, 0)
	var oid: int = create_object(state, OBSTACLE_MINE, MINE_MODEL)
	if oid < 0:
		state.set_effect(MapState.TIMER_SLOT, i, 0)
		state.set_obstacle(i, OBSTACLE_NONE)
		return -1
	state.set_effect(MapState.OBJECT_SLOT, i, oid)
	state.set_obstacle(i, OBSTACLE_MINE)
	return oid


## `0x0042FB90` -- the Plasma Gun's shield, `+0x10 = 3`.
static func place_shield(state: MapState, x: int, y: int) -> int:
	if not state.in_bounds(x, y):
		return -1
	var i: int = state.index_of(x, y)
	if not PLACER_FIELD_TYPES.has(state.field_type_at(i)):
		return -1
	state.set_effect(MapState.TIMER_SLOT, i, SHIELD_TIMER)
	if state.obstacle_at(i) == OBSTACLE_SHIELD:
		return -1
	var oid: int = create_object(state, OBSTACLE_SHIELD, SHIELD_MODEL)
	if oid < 0:
		state.set_effect(MapState.TIMER_SLOT, i, 0)
		state.set_obstacle(i, OBSTACLE_NONE)
		return -1
	state.set_effect(MapState.OBJECT_SLOT, i, oid)
	state.set_obstacle(i, OBSTACLE_SHIELD)
	return oid


## `0x0042FCB0` -- `SetGroundFire`'s glow, `+0x13 = 4`.
##
## The one placer with no gate on the cell, its own three cell bytes, and no
## write on failure -- which is what happens on every world set but `D00`.
static func place_glow(state: MapState, x: int, y: int, phase: int) -> int:
	if not state.in_bounds(x, y):
		return -1
	if phase != GLOW_PHASE_LIT and phase != GLOW_PHASE_FRESH:
		return -1
	var model: String = GLOW_MODEL_LIT if phase == GLOW_PHASE_LIT \
		else GLOW_MODEL_FRESH
	var oid: int = create_object(state, DECAL_GLOW, model)
	if oid < 0:
		return -1
	var i: int = state.index_of(x, y)
	state.set_effect(MapState.DECAL_OBJECT_SLOT, i, oid)
	state.set_effect(MapState.DECAL_PHASE_SLOT, i, phase)
	state.set_effect(MapState.DECAL_STATE_SLOT, i, DECAL_GLOW)
	return oid


## The three impact arms of docs/42 section 9.1 that change the map.
##
## `0x0040D93D` (weapon 40) calls the fire placer nine times around the target
## -- the centre at subtype 4 and the eight neighbours at 3, every one at the
## **centre** cell's height, so a neighbour more than half a field above or
## below it does not catch.  `0x0040D76A` (42) lays one mine and `0x0040D5F8`
## (43) one shield, both on the target cell.  All three run whether the shot
## hit or missed: the impact switch reads no outcome.
##
## Answers the cell indices that changed, in call order.
static func place_impact(state: MapState, weapon_id: int, tx: int,
		ty: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if weapon_id == WEAPON_GROUND_FIRE:
		if not state.in_bounds(tx, ty):
			return out
		var z: int = state.height_at(state.index_of(tx, ty))
		for step: Vector3i in NINE_FIRES:
			if place_fire(state, tx + step.x, ty + step.y, step.z, z) >= 0:
				out.append(state.index_of(tx + step.x, ty + step.y))
	elif weapon_id == WEAPON_MINE:
		if place_mine(state, tx, ty) >= 0:
			out.append(state.index_of(tx, ty))
	elif weapon_id == WEAPON_SHIELD:
		if place_shield(state, tx, ty) >= 0:
			out.append(state.index_of(tx, ty))
	return out


## `0x0042ED60` -- one sweep of the whole grid, once per **round**.
##
## The hand-over `0x0047D600` runs it after the turn counter goes up and before
## the `NEXT TURN` event (docs/25 section 4), so it is a round tick and not a
## per-player one.  Three decays, in the order the sweep applies them: a glow
## at phase 2 becomes one at phase 1; a fire loses one intensity and goes out
## below 2; a shield loses one from its countdown and expires at 1.  A mine is
## not touched by any of it.
##
## Answers the cell indices that changed.
static func round_tick(state: MapState) -> PackedInt32Array:
	var changed: PackedInt32Array = PackedInt32Array()
	for i: int in range(state.cell_count()):
		var x: int = i % state.width
		var y: int = i / state.width
		if state.effect_at(MapState.DECAL_STATE_SLOT, i) == DECAL_GLOW \
				and state.effect_at(MapState.DECAL_PHASE_SLOT, i) \
					== GLOW_PHASE_FRESH:
			var _freed: bool = delete_object(
				state, state.effect_at(MapState.DECAL_OBJECT_SLOT, i))
			var _lit: int = place_glow(state, x, y, GLOW_PHASE_LIT)
			changed.append(i)
		var kind: int = state.obstacle_at(i)
		if kind == OBSTACLE_FIRE:
			var _freed: bool = delete_object(
				state, state.effect_at(MapState.OBJECT_SLOT, i))
			if state.effect_at(MapState.TIMER_SLOT, i) <= 1:
				state.set_obstacle(i, OBSTACLE_NONE)
				state.set_effect(MapState.TIMER_SLOT, i, 0)
			else:
				var _made: int = place_fire(
					state, x, y, state.effect_at(MapState.TIMER_SLOT, i) - 1,
					state.height_at(i))
			changed.append(i)
		elif kind == OBSTACLE_SHIELD:
			if state.effect_at(MapState.TIMER_SLOT, i) == 1:
				var _freed: bool = delete_object(
					state, state.effect_at(MapState.OBJECT_SLOT, i))
				state.set_obstacle(i, OBSTACLE_NONE)
				state.set_effect(MapState.TIMER_SLOT, i, 0)
			else:
				state.set_effect(MapState.TIMER_SLOT, i,
					state.effect_at(MapState.TIMER_SLOT, i) - 1)
			changed.append(i)
	return changed


## `0x00470AB0` -- the cells whose glow has reached phase 1.
##
## Called from the hand-over immediately **before** [method round_tick], so a
## glow laid this round is decayed by the tick and ignited by the sweep a round
## later.  Clears `+0x13` and frees the object as it goes.
static func glows_to_ignite(state: MapState) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in range(state.cell_count()):
		if state.effect_at(MapState.DECAL_STATE_SLOT, i) != DECAL_GLOW \
				or state.effect_at(MapState.DECAL_PHASE_SLOT, i) \
					!= GLOW_PHASE_LIT:
			continue
		var _freed: bool = delete_object(
			state, state.effect_at(MapState.DECAL_OBJECT_SLOT, i))
		state.set_effect(MapState.DECAL_STATE_SLOT, i, DECAL_NONE)
		out.append(i)
	return out


## `aPlayGroundFireAnimation` `0x004157B0` -- the cells an ignited glow reaches.
##
## The eight neighbours through `0x004308C0` with the diagonal flag set, then
## the centre.  A cell whose `+0x10` is a **shield** is skipped, which is the
## only thing that survives standing in one.
static func ground_fire_cells(state: MapState, x: int,
		y: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for step: Vector2i in STEP_DELTA:
		if state.in_bounds(x + step.x, y + step.y):
			out.append(state.index_of(x + step.x, y + step.y))
	if state.in_bounds(x, y):
		out.append(state.index_of(x, y))
	var kept: PackedInt32Array = PackedInt32Array()
	for i: int in out:
		if state.obstacle_at(i) != OBSTACLE_SHIELD:
			kept.append(i)
	return kept
