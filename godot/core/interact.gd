class_name Interact
extends RefCounted

## `aExecuteUse` (`0x0046DC60`) and its gate, from docs/26.
##
## **A unit uses what it is facing.**  There is no reach and no selection; the
## whole input is the facing byte `+0x46`, which is what makes docs/26's native
## sweep over all eight facings a complete test of the convention.
##
## Two arms are deliberately faithful to bugs in the original, and each has a
## named check behind it:
##
## * **class 12 assigns the magazine, it does not add to it** (docs/26 section
##   3.2), so a unit that has not fired sees `+0x3D` unchanged while the point
##   is still consumed.  A test written as "ammunition increased" fails on
##   correct behaviour.
## * **class 16 raises Technical Skills while guarding on Battle Fitness**
##   (docs/26 section 3.3) -- a copy-paste slip in the original.  It therefore
##   stops working at `CON == 6` and can push `TS` past its own cap.  docs/92
##   section 7.1: reproduce by default, expose the correction as a setting.

## docs/10 section 5.10 -- unit `+0x46` to the cell step in front of it.
const FACING_DX: Array[int] = [0, -1, 0, 1, 1, -1, 1, -1]
const FACING_DY: Array[int] = [1, 0, -1, 0, -1, 1, 1, -1]

## `0x0047A530` -- the band the Use button lights for, inclusive.
const BAND_LOW: int = 10
const BAND_HIGH: int = 49

## docs/26 section 3 -- the random supply box.  `aRandom(11, 3)` is base 11 span
## 3, so 11, 12 or 13, written into the cell **before** the switch runs.
const RANDOM_BOX: int = 10
const RANDOM_BOX_BASE: int = 11
const RANDOM_BOX_SPAN: int = 3

## The four door ids.  The toggle keys on the low bit: even is open, odd is
## closed, and nothing in it distinguishes the jammed pair from the standard
## one -- that lives entirely in the gate.
const DOOR_IDS: Array[int] = [30, 31, 32, 33]
const DOOR_JAMMED_CLOSED: int = 33
const DOOR_JAMMED_OPEN: int = 32
## docs/10 section 4 -- one tile of cell height, the amount a closing door rises.
const DOOR_HEIGHT_STEP: int = 0xC80
## docs/10 section 4.1 -- the two field types the toggle writes.
const FIELD_TYPE_WALL: int = 2
const FIELD_TYPE_FREE: int = 1
## docs/10 section 4.1 -- a pushed object that reaches one of these falls out of
## the world.
const FIELD_TYPE_HOLE: int = 3
const FIELD_TYPE_DEEP_HOLE: int = 4

const LEVER_UP: int = 36
const LEVER_DOWN: int = 37

## The entry point and what it becomes.  `0x0042F840(x, y, 6, height - 0xA0)`
## sets the cell on fire before the sequence plays.
const ENTRY_POINT: int = 70
const ENTRY_POINT_DESTROYED: int = 71
const ENTRY_POINT_EFFECT: int = 6
const ENTRY_POINT_Z_DROP: int = 0xA0

## docs/26 section 3.1 -- the equipment ids the pickups grant, and the one that
## doubles a magazine.
const EQUIP_DOUBLE_MUNITION: int = 6
const EQUIP_EXPLOSION_PACK: int = 9
const EQUIP_CROWBAR: int = 17
const EQUIP_DAMAGE_ABSORBER: int = 18
const EQUIP_COOLER: int = 19
const ABSORBER_CHARGES: int = 4

## docs/20 section 5.3 -- the mission's equipment-point bonus.
## The same slot [constant GameControl.SLOT_EQUIPMENT_POINTS] names; written
## out here because docs/20 section 5.3 is where the number comes from.
const GAME_CONTROL_EQUIPMENT_POINTS: int = GameControl.SLOT_EQUIPMENT_POINTS

const SKILL_CAP: int = 6

## `0x0047B250` -- the unit types a Use may push.  `31`, `Parabomb`, sits in the
## middle of the run and is **not** one of them.
const PUSHABLE_TYPES: Array[int] = [30, 32, 33, 34, 35]
## `0x0046D530` -- how far one push slides an object, re-testing each step.
const PUSH_MAX_STEPS: int = 4
## docs/10 section 5.10 -- facings 4..7 are the diagonals, and a diagonal push
## tests the two flanking neighbours as well.
const DIAGONAL_FACINGS: Array[int] = [4, 5, 6, 7]

## `+0x10` -- the runtime effect object that makes a cell a mine.
const EFFECT_MINE: int = 2
const EFFECT_NONE: int = 255


## `0x004308C0(facing, x, y)` -- the neighbour a unit is looking at.
##
## Empty off the map, which is the dispatch's first early return.
static func cell_in_front(state: MapState, unit: UnitState) -> PackedInt32Array:
	if unit.facing < 0 or unit.facing >= FACING_DX.size():
		return PackedInt32Array()
	var x: int = unit.x + FACING_DX[unit.facing]
	var y: int = unit.y + FACING_DY[unit.facing]
	if not state.in_bounds(x, y):
		return PackedInt32Array()
	return PackedInt32Array([x, y])


## `0x0047A530` -- predicate 1, returning the action point or `-1`.
##
## Four comparisons and nothing else: an empty cell, the band, the crowbar for a
## *jammed, closed* door, and an outright refusal of *jammed, open* -- which is
## why a jammed door can be pried open exactly once.
static func use_target(state: MapState, unit: UnitState) -> int:
	var at: PackedInt32Array = cell_in_front(state, unit)
	if at.is_empty():
		return -1
	var index: int = state.index_of(at[0], at[1])
	if state.unit_at(index) >= 0:
		return -1
	var ap: int = state.action_point_at(index)
	if ap < BAND_LOW or ap > BAND_HIGH:
		return -1
	if ap == DOOR_JAMMED_CLOSED and not unit.has_equipment(EQUIP_CROWBAR):
		return -1
	if ap == DOOR_JAMMED_OPEN:
		return -1
	return ap


## `0x0047B250` -- predicate 2, taking the **object's** cell.
##
## The executor re-tests it before every one of its four steps, and it does so
## with the object's coordinates rather than the pusher's: the pusher does not
## move.  A model written as a predicate on the unit would slide the unit along
## behind the object, which is a different game.
static func can_push(state: MapState, units: Dictionary, utab: UnitTypeTable,
		x: int, y: int, facing: int) -> bool:
	if not state.in_bounds(x, y):
		return false
	if facing < 0 or facing >= FACING_DX.size():
		return false
	var source: int = state.index_of(x, y)
	var slot: int = state.unit_at(source)
	if slot < 0 or not units.has(slot):
		return false
	var occupant: UnitState = units[slot]
	if not PUSHABLE_TYPES.has(occupant.type_id):
		return false
	var dx: int = FACING_DX[facing]
	var dy: int = FACING_DY[facing]
	if not state.in_bounds(x + dx, y + dy):
		return false
	var into: int = state.index_of(x + dx, y + dy)
	if state.unit_at(into) >= 0:
		return false
	if state.field_type_at(into) == FIELD_TYPE_WALL:
		return false
	if state.height_at(into) > state.height_at(source):
		return false
	if DIAGONAL_FACINGS.has(facing):
		for flank: PackedInt32Array in [PackedInt32Array([x + dx, y]),
				PackedInt32Array([x, y + dy])]:
			if not state.in_bounds(flank[0], flank[1]):
				return false
			var side: int = state.index_of(flank[0], flank[1])
			if state.unit_at(side) >= 0:
				return false
			if state.field_type_at(side) == FIELD_TYPE_WALL:
				return false
	# `utab` is unused by the engine's own predicate -- the type test above is
	# on the unit record, not the type table -- and is taken so that every
	# entry point in this file has the same shape.
	return utab != null


## docs/26 section 2 -- the Use button lights when **any** predicate accepts.
static func may_use(state: MapState, units: Dictionary, utab: UnitTypeTable,
		unit: UnitState) -> bool:
	if use_target(state, unit) >= 0:
		return true
	var at: PackedInt32Array = cell_in_front(state, unit)
	if at.is_empty():
		return false
	if can_push(state, units, utab, at[0], at[1], unit.facing):
		return true
	var index: int = state.index_of(at[0], at[1])
	if (state.action_point_at(index) == ENTRY_POINT and unit.fp != 0
			and unit.has_equipment(EQUIP_EXPLOSION_PACK)):
		return true
	return state.obstacle_at(index) == EFFECT_MINE


## `0x00410A20` -- one toggle for all four door ids, on the low bit.
##
## A door is a wall panel that rises out of the floor: closing it raises the
## cell by exactly one tile and makes it a `Wall`, opening it drops the cell to
## height 0 and makes it a `Free Place`.
static func toggle_door(state: MapState, index: int) -> void:
	var ap: int = state.action_point_at(index)
	if ap % 2 == 0:                      # even: 30, 32 -- it is open
		state.set_height(index, state.height_at(index) + DOOR_HEIGHT_STEP)
		state.set_action_point(index, ap + 1)
		state.set_field_type(index, FIELD_TYPE_WALL)
	else:                                # odd: 31, 33 -- it is closed
		state.set_field_type(index, FIELD_TYPE_FREE)
		state.set_action_point(index, ap - 1)
		state.set_height(index, 0)


## `0x0046DB80` -- the effect object is freed and nothing explodes.
static func defuse_mine(state: MapState, index: int) -> UseResult:
	state.set_obstacle(index, EFFECT_NONE)
	var out: UseResult = UseResult.new()
	out.ok = true
	out.kind = "defuse_mine"
	out.cell = PackedInt32Array([index % state.width, index / state.width])
	return out


## `0x0046D530` -- slide the object up to four cells, re-testing each.
##
## Two ways the slide ends other than running out of steps, and both can kill
## the pusher: the object reaches a mine and detonates it as a weapon-36 shot
## centred on the cell, or it reaches a `Hole` and falls out of the world.
static func push_object(state: MapState, units: Dictionary,
		utab: UnitTypeTable, wtab: WeaponTable, unit: UnitState,
		ai_level: int, human_players: int, game_mode: int, turn: TurnState,
		rng: IncRandom) -> UseResult:
	var at: PackedInt32Array = cell_in_front(state, unit)
	if at.is_empty():
		return UseResult.refused("the cell in front is off the map")
	var out: UseResult = UseResult.new()
	out.ok = true
	out.kind = "push"
	out.cell = at.duplicate()
	var dx: int = FACING_DX[unit.facing]
	var dy: int = FACING_DY[unit.facing]
	for _i: int in range(PUSH_MAX_STEPS):
		if not can_push(state, units, utab, at[0], at[1], unit.facing):
			break
		var source: int = state.index_of(at[0], at[1])
		var slot: int = state.unit_at(source)
		var obj: UnitState = units[slot]
		at = PackedInt32Array([at[0] + dx, at[1] + dy])
		var into: int = state.index_of(at[0], at[1])
		state.set_unit(source, MapState.NO_UNIT)
		state.set_unit(into, slot)
		obj.x = at[0]
		obj.y = at[1]
		out.pushed.append(at.duplicate())
		if state.obstacle_at(into) == EFFECT_MINE:
			state.set_obstacle(into, EFFECT_NONE)
			execute_bomb(state, units, utab, wtab, at[0], at[1], ai_level,
				human_players, game_mode, turn, rng)
			out.kind = "push_onto_mine"
			break
		var ft: int = state.field_type_at(into)
		if ft == FIELD_TYPE_HOLE or ft == FIELD_TYPE_DEEP_HOLE:
			UnitState.remove(state, turn, obj)
			obj.hp = 0
			out.kind = "push_into_hole"
			break
	return out


## `aExecuteBomb` `0x004702C0` -- a weapon-36 shot with no shooter.
##
## **Correct as written -- docs/26 section 10 item 7 is closed.**  The worry was
## that the sibling path -- a mine *stepped* on during a walk -- was probed
## natively and did not detonate, so the push might be as inert.  It is not:
## `0x0046D8DD` carries the identical guard the walk path does, and what the
## probe hit was that guard (docs/26 section 6.2).  Neither arm is inert.
static func execute_bomb(state: MapState, units: Dictionary,
		utab: UnitTypeTable, wtab: WeaponTable, x: int, y: int, ai_level: int,
		human_players: int, game_mode: int, turn: TurnState,
		rng: IncRandom) -> AttackResult:
	var result: AttackResult = AttackResult.new()
	result.fired = true
	var unsupported: Array[String] = []
	result.marked = Combat.mark_cells(state, units, Combat.BOMB_WEAPON, x, y,
		unsupported)
	if not unsupported.is_empty():
		result.fired = false
		result.reason = unsupported[0]
		return result
	for cell: PackedInt32Array in result.marked:
		var index: int = state.index_of(cell[0], cell[1])
		var slot: int = state.unit_at(index)
		if slot < 0 or not units.has(slot):
			continue
		var target: UnitState = units[slot]
		if not target.is_alive():
			continue
		# `0x004703A9` -- the reveal `aAttackUnit` makes: a unit on a marked
		# cell is visible before its roll.
		Visibility.set_state(target, Visibility.FULL)
		if state.obstacle_at(index) == Combat.EFFECT_SHIELDED:
			continue
		var chance: int = wtab.hit(Combat.BOMB_WEAPON)
		var damage: int = Combat.marker_damage(wtab, cell[2],
			Combat.BOMB_WEAPON)
		var roll: int = rng.draw(0, Combat.HIT_SPAN)
		if chance + Combat.HIT_BONUS < roll:
			result.outcomes.append({"slot": slot, "x": cell[0], "y": cell[1],
				"marker": Combat.MARKER_MISS, "dealt": 0, "chance": chance,
				"roll": roll})
			continue
		var dealt: int = 0
		if target.absorber != 0:
			target.absorber -= 1
		else:
			# A bomb has no shooter, so the rear-arc test takes the heading from
			# the centre.  Nothing in the disassembly names the value the engine
			# passes; a target standing *on* the centre gets heading 0 either
			# way, which is the only case the shipped data reaches.
			dealt = Combat.apply_damage(target, damage,
				Combat.direction(x, y, cell[0], cell[1]), ai_level,
				human_players, game_mode, rng)
		var killed: bool = not target.is_alive()
		if killed:
			UnitState.remove(state, turn, target)
		result.outcomes.append({"slot": slot, "x": cell[0], "y": cell[1],
			"marker": Combat.MARKER_KILLED if killed else Combat.MARKER_HIT,
			"dealt": dealt, "chance": chance, "roll": roll})
	return result


## `aExecuteUse` `0x0046DC60` -- docs/26 section 3, in the order it runs.
##
## The two early returns come first and **never reach the script**; only the
## action-point classes do.  Every pickup arm clears the cell, and every id the
## switch does not handle falls through to the default arm, which *is* the LCL
## event and nothing else.
static func execute(state: MapState, units: Dictionary, utab: UnitTypeTable,
		wtab: WeaponTable, control: GameControl, unit: UnitState,
		ai_level: int, human_players: int, game_mode: int, turn: TurnState,
		rng: IncRandom) -> UseResult:
	var at: PackedInt32Array = cell_in_front(state, unit)
	if at.is_empty():
		return UseResult.refused("the cell in front is off the map")
	var index: int = state.index_of(at[0], at[1])
	if state.unit_at(index) >= 0:
		return push_object(state, units, utab, wtab, unit, ai_level,
			human_players, game_mode, turn, rng)
	if state.obstacle_at(index) == EFFECT_MINE:
		return defuse_mine(state, index)

	if state.action_point_at(index) == RANDOM_BOX:
		state.set_action_point(index,
			rng.draw(RANDOM_BOX_BASE, RANDOM_BOX_SPAN))
	var ap: int = state.action_point_at(index)
	var out: UseResult = UseResult.new()
	out.ok = true
	out.kind = "class"
	out.cell = at.duplicate()
	out.action_point = ap
	out.fires_script_event = true

	if ap == 11 or ap == 41:
		state.set_action_point(index, 0)
		out.kind = "message_only"
	elif ap == 12:
		var magazine: int = wtab.magazine(unit.weapon)
		if unit.has_equipment(EQUIP_DOUBLE_MUNITION):
			magazine *= 2
		unit.ammo = magazine
		state.set_action_point(index, 0)
		out.kind = "full_munition"
	elif ap == 13 or ap == 17 or ap == 18:
		var worth: int = 50
		if ap == 17:
			worth = 20
		elif ap == 18:
			worth = 10
		control.increment(GAME_CONTROL_EQUIPMENT_POINTS, worth)
		state.set_action_point(index, 0)
		out.kind = "equipment_points"
	elif ap == 14:
		_raise_skill(unit, UnitState.SKILL_LW, UnitState.SKILL_LW)
		_raise_skill(unit, UnitState.SKILL_HW, UnitState.SKILL_HW)
		state.set_action_point(index, 0)
		out.kind = "weapon_skills"
	elif ap == 15:
		_raise_skill(unit, UnitState.SKILL_CON, UnitState.SKILL_CON)
		state.set_action_point(index, 0)
		out.kind = "condition"
	elif ap == 16:
		# The guard reads CON and the increment writes TS -- docs/26 section 3.3.
		_raise_skill(unit, UnitState.SKILL_TS, UnitState.SKILL_CON)
		state.set_action_point(index, 0)
		out.kind = "technical"
	elif DOOR_IDS.has(ap):
		toggle_door(state, index)
		out.kind = "door"
	elif ap == LEVER_UP or ap == LEVER_DOWN:
		state.set_action_point(index,
			LEVER_DOWN if ap == LEVER_UP else LEVER_UP)
		out.kind = "lever"
	elif ap == 38 or ap == 39 or ap == 40 or ap == 42:
		var granted: int = EQUIP_DAMAGE_ABSORBER
		if ap == 39:
			granted = EQUIP_CROWBAR
		elif ap == 40:
			granted = EQUIP_COOLER
		elif ap == 42:
			granted = EQUIP_EXPLOSION_PACK
		if not unit.equipment.has(granted):
			unit.equipment.append(granted)
			unit.equipment.sort()
		if ap == 38:
			unit.absorber = ABSORBER_CHARGES
		state.set_action_point(index, 0)
		out.kind = "equipment"
	elif ap == ENTRY_POINT:
		state.set_obstacle(index, ENTRY_POINT_EFFECT)
		state.set_height(index, state.height_at(index) - ENTRY_POINT_Z_DROP)
		state.set_action_point(index, ENTRY_POINT_DESTROYED)
		out.kind = "entry_point"
	else:
		# The default arm: 19..29, 34, 35, 43..49 and everything outside the
		# switch's own 11..70 band.  It is the LCL event and nothing else.
		out.kind = "script_only"
	return out


## One implant box.  `guard` is the skill index the arm actually compares
## against, which is the whole of docs/26 section 3.3.
static func _raise_skill(unit: UnitState, which: int, guard: int) -> void:
	if unit.skills[guard] < SKILL_CAP:
		unit.skills[which] += 1
