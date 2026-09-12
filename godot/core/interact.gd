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
## The placer's third argument -- the fire's intensity, which is also its
## countdown: a subtype-6 fire burns for five more rounds.
const ENTRY_POINT_FIRE_SUBTYPE: int = CellObjects.ENTRY_POINT_FIRE_SUBTYPE
const ENTRY_POINT_Z_DROP: int = CellObjects.ENTRY_POINT_FIRE_Z_DROP

## docs/26 section 3.1 -- the equipment ids the pickups grant, and the one that
## doubles a magazine.
const EQUIP_DOUBLE_MUNITION: int = 6
const EQUIP_EXPLOSION_PACK: int = 9
const EQUIP_CROWBAR: int = 17
const EQUIP_DAMAGE_ABSORBER: int = Combat.EQUIP_DAMAGE_ABSORBER
const EQUIP_COOLER: int = 19
const ABSORBER_CHARGES: int = 4

## docs/92 section 7.1 -- the stable correction behind the user-facing
## `Faithful` preset. Absence preserves the original omission, which also
## keeps saves made before this flag existed faithful.
const COMPAT_BEACOO_MINE_DEATH_BLAST: String = "beacoo_mine_death_blast"

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
## What the **cell** does: closing it raises the cell by exactly one tile and
## makes it a `Wall`, opening it drops the cell to height 0 and makes it a
## `Free Place`. This once read "a door is a wall panel that rises out of the
## floor", which is what the picture was drawn from and is wrong: the panel
## never moves. `aDoorOpenSequence` turns the panel's two **leaves** about z
## and writes the cell's height into the land marker alone (docs/26 section 3.4,
## docs/97 section 7 as corrected on 2026-09-06).
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
	var _freed: bool = CellObjects.delete_object(
		state, state.effect_at(MapState.OBJECT_SLOT, index))
	state.set_effect(MapState.OBJECT_SLOT, index, MapState.NO_OBJECT)
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
		rng: IncRandom, cheats: Cheats = null,
		compat_flags: PackedStringArray = PackedStringArray()) -> UseResult:
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
		UnitState.vacate(state, utab, obj, obj.x, obj.y)
		UnitState.occupy(state, utab, obj, at[0], at[1])
		obj.x = at[0]
		obj.y = at[1]
		out.pushed.append(at.duplicate())
		if state.obstacle_at(into) == EFFECT_MINE:
			# `0x0046D8DD` carries the same guard the walk's arm does (docs/26
			# section 6.2): the object is deleted first and the two cell bytes
			# are cleared only on the far side of it.
			if CellObjects.delete_object(
					state, state.effect_at(MapState.OBJECT_SLOT, into)):
				state.set_effect(MapState.OBJECT_SLOT, into, MapState.NO_OBJECT)
				state.set_obstacle(into, EFFECT_NONE)
				state.set_effect(MapState.TIMER_SLOT, into, 0)
				# **The third way a mine reaches a unit**, and the one the
				# header above warns can kill the pusher -- so the shield
				# rides with it, exactly as it does on the walk's arm and the
				# warp's.
				out.blast = execute_bomb(state, units, utab, wtab, at[0], at[1],
					ai_level, human_players, game_mode, turn, rng, cheats,
					compat_flags).to_dict()
				out.kind = "push_onto_mine"
				break
		var ft: int = state.field_type_at(into)
		if ft == FIELD_TYPE_HOLE or ft == FIELD_TYPE_DEEP_HOLE:
			UnitState.remove(state, utab, turn, obj)
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
		rng: IncRandom, cheats: Cheats = null,
		compat_flags: PackedStringArray = PackedStringArray()) -> AttackResult:
	var result: AttackResult = AttackResult.new()
	result.fired = true
	var unsupported: Array[String] = []
	result.marked = Combat.mark_cells(state, units, Combat.BOMB_WEAPON, x, y,
		unsupported)
	if not unsupported.is_empty():
		result.fired = false
		result.reason = unsupported[0]
		return result
	# This is a separate resolver from `Combat.attack`. `0x004703CF` starts
	# every reached unit with a 30-point damage argument, and there is no hit
	# roll. A `special` 12 target writes its ring and makes the sweep repeat.
	var markers: PackedByteArray = Combat._marker_map(state, result.marked)
	var repeat_sweep: bool = false
	var marker_index: int = 0
	while marker_index < markers.size() or repeat_sweep:
		if marker_index >= markers.size():
			marker_index = 0
			repeat_sweep = false
		var index: int = marker_index
		marker_index += 1
		var marker: int = markers[index]
		if marker < Combat.MARKER_FULL or marker > Combat.MARKER_INPUT_LAST:
			continue
		var x_at: int = index % state.width
		var y_at: int = index / state.width
		var slot: int = state.unit_at(index)
		if slot < 0 or not units.has(slot):
			continue
		var target: UnitState = units[slot]
		if not target.is_alive():
			continue
		# `0x004703A9` -- the reveal `aAttackUnit` makes: a unit on a marked
		# cell is visible before its damage resolution.
		Visibility.set_state(target, Visibility.FULL)
		var damage: int = 0 if state.obstacle_at(index) \
			== Combat.EFFECT_SHIELDED else Combat.BOMB_DAMAGE
		if utab.special(target.type_id) == Combat.SPECIAL_EXPLODES_ON_HIT:
			Combat._write_markers(state, markers, Combat._blast_ring(state, x_at, y_at,
				Combat.AIM_NEIGHBOUR_ORDER, Combat.MARKER_FLAT_100))
			repeat_sweep = true
			damage = Combat.BOMB_EXPLOSIVE_DAMAGE
		# The shield, by the absorber's mechanism -- the same zeroed argument
		# [method Combat.attack] uses, so the generator lands where it would
		# have. This is the second and last way a weapon reaches a unit.
		if Cheats.shielded(cheats, target, turn):
			damage = 0
		# No absorber here: `aExecuteBomb` never calls `0x00475590` or
		# `0x004755B0` -- the per-cell resolver calls `applyDamage` directly at
		# `0x004704C9`, with the heading `0xFF` no arc holds. The model once
		# spent a charge the engine does not and derived a heading from the
		# centre.
		var dealt: int = Combat.apply_damage(target, damage, Combat.BOMB_FACING,
			ai_level, human_players, game_mode, rng)
		var killed: bool = not target.is_alive()
		if killed \
				and utab.special(target.type_id) \
					== Combat.SPECIAL_EXPLODES_ON_DEATH \
				and compat_flags.has(COMPAT_BEACOO_MINE_DEATH_BLAST):
			# Corrected mode makes special 16 source-independent. The named flag
			# is absent from Faithful sessions and old saves.
			Combat._write_markers(state, markers, Combat._blast_ring(state, x_at, y_at,
				Combat.AIM_NEIGHBOUR_ORDER, Combat.MARKER_FLAT_100))
			repeat_sweep = true
		if killed:
			UnitState.remove(state, utab, turn, target)
		markers[index] = Combat.MARKER_KILLED if killed else Combat.MARKER_HIT
		result.outcomes.append({"slot": slot, "x": x_at, "y": y_at,
			"marker": Combat.MARKER_KILLED if killed else Combat.MARKER_HIT,
			"dealt": dealt, "chance": 100, "roll": 0})
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
		rng: IncRandom, cheats: Cheats = null,
		compat_flags: PackedStringArray = PackedStringArray()) -> UseResult:
	var at: PackedInt32Array = cell_in_front(state, unit)
	if at.is_empty():
		return UseResult.refused("the cell in front is off the map")
	var index: int = state.index_of(at[0], at[1])
	if state.unit_at(index) >= 0:
		return push_object(state, units, utab, wtab, unit, ai_level,
			human_players, game_mode, turn, rng, cheats, compat_flags)
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
		# `0x0046E0BF`: the action point becomes 71 **first**, then the cell is
		# set alight.  The 71 is what lets the fire placer accept a cell whose
		# field type is not one of its four (docs/23 section 7.1), and the
		# `- 0xA0` is the placer's z argument, which reaches only its
		# half-a-field height window -- nothing writes the cell's height.
		state.set_action_point(index, ENTRY_POINT_DESTROYED)
		var _lit: int = CellObjects.place_fire(state, index % state.width,
			index / state.width, ENTRY_POINT_FIRE_SUBTYPE,
			state.height_at(index) - ENTRY_POINT_Z_DROP)
		out.kind = "entry_point"
	else:
		# The default arm: 19..29, 34, 35, 43..49 and everything outside the
		# switch's own 11..70 band.  It is the LCL event and nothing else.
		out.kind = "script_only"
	return out


# --- the heal command: docs/29 section 1.1 button 2, `0x00470890` ----------

## `unit + 0x30` / `+0x31` -- the two medic kits, by equipment id.
const EQUIP_SMALL_MEDIC_KIT: int = 15
const EQUIP_LARGE_MEDIC_KIT: int = 16
## `0x004753C0` -- what one press restores.
const HEAL_POWER_LARGE: int = 3
const HEAL_POWER_SMALL: int = 1
## `0x00475240` -- a human unit's ceiling: the type's hit points plus
## `ep / 12`, never above 15; a computer unit's is the type's alone.
const MAX_HIT_POINTS_CAP: int = 15
const EXPERIENCE_PER_HIT_POINT: int = 12
## `+0x39` after the heal pad arm, written whether or not anything was
## healed (the join at `0x004733F3`).
const ACTED_HEALED: int = 3


## `0x004753C0` -- 3 with a Large Medic Kit, else 1 with a Small one, else 0.
static func heal_power(unit: UnitState) -> int:
	if unit.has_equipment(EQUIP_LARGE_MEDIC_KIT):
		return HEAL_POWER_LARGE
	return HEAL_POWER_SMALL if unit.has_equipment(EQUIP_SMALL_MEDIC_KIT) else 0


## `0x00475240` -- the ceiling a heal fills to.
static func max_hit_points(utab: UnitTypeTable, unit: UnitState) -> int:
	var base: int = utab.hp_max(unit.type_id)
	if unit.player == UnitState.PLAYER_ALIEN:
		return base
	return mini(MAX_HIT_POINTS_CAP, base + unit.ep / EXPERIENCE_PER_HIT_POINT)


## `0x0047B180` -- `hp += power` while that stays under the ceiling, else
## the ceiling itself.
static func apply_heal(utab: UnitTypeTable, unit: UnitState, power: int) -> void:
	var cap: int = max_hit_points(utab, unit)
	unit.hp = unit.hp + power if unit.hp + power < cap else cap


## `0x00470890` -- the heal command, in the order it runs. The twin of
## `inclib/interact.py`'s `heal`, checked by `interact_runtime.py`.
##
## Refused with no movement points. The unit in front is healed when it is
## below its ceiling and belongs to the healer's player; otherwise -- off the
## map, an empty cell, at full health, or somebody else's -- the healer heals
## itself, and that arm alone answers `ok: false` when the healer is at its
## own ceiling. A network game relaxes the owner test to players 0..3; the
## remake has no network and keeps the local arm.
##
## Answers `{ok, reason, target, delta, self_heal}`; `delta` is the orbit's
## third argument (docs/42 section 7.5).
static func heal(state: MapState, units: Dictionary, utab: UnitTypeTable,
		unit: UnitState) -> Dictionary:
	if unit.mp == 0:
		return {"ok": false, "reason": "no movement points", "target": -1,
			"delta": 0, "self_heal": false}
	var power: int = heal_power(unit)
	var at: PackedInt32Array = cell_in_front(state, unit)
	var target: UnitState = null
	if not at.is_empty():
		var slot: int = state.unit_at(state.index_of(at[0], at[1]))
		if slot >= 0 and units.has(slot):
			var candidate: UnitState = units[slot]
			if candidate.hp != max_hit_points(utab, candidate) \
					and candidate.player == unit.player:
				target = candidate
	if target != null:
		var before: int = target.hp
		apply_heal(utab, target, power)
		return {"ok": true, "reason": "", "target": target.slot,
			"delta": absi(target.hp - before), "self_heal": false}
	if unit.hp == max_hit_points(utab, unit):
		return {"ok": false, "reason": "already at full health",
			"target": unit.slot, "delta": 0, "self_heal": true}
	var was: int = unit.hp
	apply_heal(utab, unit, power)
	return {"ok": true, "reason": "", "target": unit.slot,
		"delta": absi(unit.hp - was), "self_heal": true}


## `0x0047B4C0` -- whether the pad offers button 2 at all: a kit, and
## either a patient in front under its ceiling and of the same player, or
## the healer itself under its own. The pad's arm at `0x0047262D` adds
## `mp >= 1` on top, which [method heal] refuses again on its own.
static func may_heal(state: MapState, units: Dictionary, utab: UnitTypeTable,
		unit: UnitState) -> bool:
	if heal_power(unit) == 0:
		return false
	var at: PackedInt32Array = cell_in_front(state, unit)
	if not at.is_empty():
		var slot: int = state.unit_at(state.index_of(at[0], at[1]))
		if slot >= 0 and units.has(slot):
			var patient: UnitState = units[slot]
			if patient.player == unit.player \
					and patient.hp != max_hit_points(utab, patient):
				return true
	return unit.hp != max_hit_points(utab, unit)


## The pad's arm around [method heal] (`0x004733BB`): one movement point off
## when the command answered 1 and there was one to take, and `+0x39`
## written to 3 **either way** -- the join at `0x004733F3` is after both
## branches, so a press that healed nothing still marks the unit as acted.
static func heal_command(state: MapState, units: Dictionary,
		utab: UnitTypeTable, unit: UnitState) -> Dictionary:
	var result: Dictionary = heal(state, units, utab, unit)
	if DictRead.as_bool(result["ok"]) and unit.mp > 0:
		unit.mp -= 1
	unit.acted = ACTED_HEALED
	return result


## One implant box.  `guard` is the skill index the arm actually compares
## against, which is the whole of docs/26 section 3.3.
static func _raise_skill(unit: UnitState, which: int, guard: int) -> void:
	if unit.skills[guard] < SKILL_CAP:
		unit.skills[which] += 1
