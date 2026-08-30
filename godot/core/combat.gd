class_name Combat
extends RefCounted

## `aAttackUnit` (`0x0046B450`) and what it calls, from docs/22 sections 7 and 8.
##
## Three things the code gives that the data files cannot, and all three change
## what a remake does:
##
## * **line of sight is not re-checked in the resolver.**  `applyLOS` is false
##   there, so a target the marking pass accepted is hit without a second cover
##   test;
## * **a target outside the weapon's range still resolves**, using the raw
##   `Hit (%)` column as its chance, which is how splash reaches past `range
##   max`;
## * **the `+10` bonus is unconditional**, so a weapon at 0 % connects on a roll
##   of 0..9.
##
## The draw order is the part a native capture pins and prose cannot: the hit
## roll is drawn **per marked cell that holds a unit**, even when the marker
## forces the outcome, and then the damage roll, the fatigue extras and the
## armour roll follow in that order.  Every draw goes through the one [IncRandom]
## the caller passes, or the canonical hash lies.

## docs/22 section 7.4 -- the eight direction codes, from the shooter to the
## target.  Indexed by code; the layout is docs/22's own diagram.
const DIRECTION_DX: Array[int] = [0, -1, 0, 1, 1, -1, 1, -1]
const DIRECTION_DY: Array[int] = [1, 0, -1, 0, -1, 1, 1, -1]
## `0x0046A930` / `0x0046A9A0` -- a facing and its two neighbouring octants.
## Three of eight, i.e. an arc 135 degrees wide.
##
## Flat, three entries per octant, because a `PackedInt32Array` is not a
## constant expression in GDScript and an `Array` of untyped `Array`s hands
## back a `Variant` that `unsafe_method_access` refuses.  [method in_arc] is
## the only reader.
const ARC: Array[int] = [
	0, 5, 6,   1, 5, 7,   2, 4, 7,   3, 4, 6,
	4, 2, 3,   5, 0, 1,   6, 0, 3,   7, 1, 2,
]
const ARC_WIDTH: int = 3
const FACINGS: int = 8

## docs/22 section 7.2 -- what each cell marker is worth.
const MARKER_FULL: int = 0x50
const MARKER_70: int = 0x51
const MARKER_50: int = 0x52
const MARKER_FLAT_100: int = 0x53
const MARKER_FORCED_HIT: int = 0x54
const MARKER_STUN: int = 0x55
## docs/22 section 7.3 -- the markers the resolver writes back.
const MARKER_MISS: int = 0x5A
const MARKER_RESOLVED: int = 0x5B
const MARKER_HIT: int = 0x5C
const MARKER_KILLED: int = 0x5D

## docs/22 section 7.3 -- the roll is `aRandom(0, 100)` and the comparison is
## `chance + 10 < roll`, so a weapon at 0 % still connects 11 % of the time.
const HIT_BONUS: int = 10
const HIT_SPAN: int = 100

## docs/22 section 7 -- target `special` values that force the hit and the
## damage.  12 is `Barrel`/`Parabomb`, 13 is `Case`.
const GUARANTEED_HIT_SPECIALS: Array[int] = [12, 13]
const GUARANTEED_HIT_DAMAGE: int = 255

## docs/22 section 7.4 -- the sentinel damage value and the one immune type.
const DAMAGE_SENTINEL: int = 0xFE
const SENTINEL_DAMAGE_DEALT: int = 2
const IMMUNE_UNIT_TYPE: int = 0x23
## docs/22 sections 7.3 and 7.5 -- the one type exempt from spending ammunition.
const NO_AMMO_UNIT_TYPE: int = 0x42
## docs/22 section 7.3 -- a cell whose effect state is 3 takes no damage.
const EFFECT_SHIELDED: int = 3
## docs/22 section 7.3 -- a `Banner` carrier within four fields doubles the
## chance; equipment 8, and `0x0046FAD0` does not skip the unit it was asked
## about, so a carrier counts itself.
const EQUIP_BANNER: int = 8
const BANNER_RANGE: int = 4
## The charge stun spends, and the state it leaves behind.
const STUNNED_ACTION_STATE: int = 5

## docs/22 section 8 -- `0x0046D1B0`'s outcomes, as names.
const OVERHEAT_NONE: String = "none"
const OVERHEAT_JAM: String = "jam"
const OVERHEAT_DAMAGE: String = "damage"
const OVERHEAT_DESTROYED: String = "destroyed"
const OVERHEAT_CLEARED: String = "cleared"
## Weapon types whose overheat damages rather than jams.
const DAMAGING_WEAPON_TYPES: Array[int] = [0, 2, 3, 4]
## `0x0046D1D6` -- the span of the overheat roll, a **constant** and not the
## weapon's heat cap.  docs/22 section 8 said the cap for most of this project's
## life; the native capture is what settled it.
const OVERHEAT_SPAN: int = 40
const MALFUNCTION_JAM: int = 2
const MALFUNCTION_DAMAGED: int = 5
## `0x00475340` -- the `Cooler` doubles the heat cap.  It is not purely
## protective: doubling the cap widens `aRandom(0, cap)` and so the range of
## bad outcomes.
const EQUIP_COOLER: int = 19
const HEAT_NONE: int = 0xFF
## docs/22 section 7.5 -- a weapon whose `mun` column is this spends nothing.
## The same number as [constant HEAT_NONE] and a different meaning; naming them
## apart is why the ammunition gate cannot be read as a heat test.
const MUN_NONE: int = 0xFF

## docs/22 section 7.2 -- the sixteen weapon families, **all** of them since
## the third slice. [method mark_cells] still takes an `unsupported` array,
## because a weapon id above 47 reaches the dispatcher's own error arm.
## 46 and 42 belong to their own handlers -- `aim_cell_full_null_object` and
## `aim_cell_70_null_object` -- which differ from these two only in a null
## object pointer the marking pass does not use.  They are folded in here
## because the *marks* are identical; the two names are kept in docs/22
## section 7.2 and in `inclib.combat.PATTERN_FAMILIES`.
const AIM_FULL: Array[int] = [0, 1, 2, 3, 4, 6, 10, 14, 15, 16, 20, 21, 23, 24,
	25, 27, 29, 30, 31, 32, 46, 47]
const AIM_70: Array[int] = [7, 42]
const AIM_AND_NEIGHBOURS: Array[int] = [8, 12, 26, 36]
const NEIGHBOURS_THEN_AIM_70: Array[int] = [40]
const AIM_FORCED_HIT: Array[int] = [43]
const AIM_STUN: Array[int] = [45]
## `0x0046ACCD` -- weapon 22 `Spores`.  The aim cell, then the eight
## neighbours, each only when it holds a unit whose owner is not
## [constant PLAYER_NEUTRAL].
const SPORES_FILTERED: Array[int] = [22]
## `0x0046ABD5` -- weapon 17 `Explosives`. The shooter's own cell, then the
## eight neighbours; a **large** occupant is stamped on its own centre.
const EXPLOSIVES: Array[int] = [17]
## `0x0046B1C7` -- weapons 5 and 41; the blast grows with the range of the shot.
const RADIUS_BY_RANGE: Array[int] = [5, 41]
const RADIUS_NEAR_LIMIT: int = 2
const RADIUS_MID_LIMIT: int = 25
const RADIUS_BEYOND: int = 3
## `0x0046AF38` -- weapon 9 `Plasma Gun`; every unit the shooter can see.
const LINE_OF_SIGHT_FROM_AIM: Array[int] = [9]
## `0x0046B0D8` -- weapon 11 `Multi-target Destroyer`; cells in the action-point
## band, which docs/10 section 4.6 calls the multiplayer victory points.
const SPECIAL_OBJECTS: Array[int] = [11]
const SPECIAL_OBJECT_LOW: int = 30
const SPECIAL_OBJECT_HIGH: int = 34
## `0x0046AED2` -- weapon 44; every unit within `< 4` of the aim point, which is
## **not** "every unit on the map".
const EVERY_UNIT: Array[int] = [44]
const EVERY_UNIT_MAX_DISTANCE: int = 4
## `0x0046AF38` and `0x0046B0D8` use `<= 4`, which is not the same test.
const ARC_SWEEP_MAX_DISTANCE: int = 4
## `0x0046AD9F` -- weapon 13; eighteen cells at `aRandom(-2, 5)` offsets, and
## then the aim cell, because the handler falls through into weapon 42's.
const SCATTER_18: Array[int] = [13]
const SCATTER_COUNT: int = 18
const SCATTER_BASE: int = -2
const SCATTER_SPAN: int = 5
## `0x0042FF30`'s refusal: a chance at or above this is "never".
const PATTERN_CHANCE_REFUSED: int = 254
## `0x0046AE0B` (weapons 8, 12, 26, 36) -- the eight neighbours in the order the
## **unrolled** handler writes them.
const AIM_NEIGHBOUR_ORDER: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(0, -1),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, 1)]
## `0x0046AA66` (weapon 40) -- a *different* unrolled eight. The two differ in
## their last four entries, and the order is the order the rolls come out in.
const FLAME_B_NEIGHBOUR_ORDER: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(0, 1), Vector2i(0, -1)]
## docs/10 section 5.7 -- the neutral-prop owner the spores pattern skips.
const PLAYER_NEUTRAL: int = 0xFC
## `0x004308C0`'s direction table (docs/23 section 8), in the order the spores
## handler sweeps it with `allowDiagonal` set.  It is neither the facing
## encoding nor the `dy`-then-`dx` order [constant AIM_AND_NEIGHBOURS] writes
## its ring in, and the order is what the damage rolls come out in.
const STEP_DIRECTIONS: Array[Vector2i] = [
	Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, 0),
	Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1), Vector2i(-1, -1)]
## docs/22 section 7.2 -- the ids whose dispatch entry reports an error.  28 is
## the `-` placeholder and 37 is `Mine`; the other seven `Info.lcl` never
## defines.  They mark nothing, and that is correct rather than unsupported.
const NO_PATTERN: Array[int] = [18, 19, 28, 33, 34, 35, 37, 38, 39]

## docs/21 section 4 -- `ParaBomb`.  A mine resolves as a shot from this.
const BOMB_WEAPON: int = 36


## `0x0047A8E0`'s three modes. Only mode 2 is reached from `endUnitTurn`; mode
## 0 looks for an action point in the multiplayer band and mode 1 is mode 2
## **plus a visibility test**.
const FACING_MODE_ACTION_POINT: int = 0
const FACING_MODE_VISIBLE_ENEMY: int = 1
const FACING_MODE_ANY_ENEMY: int = 2
## What it answers when it finds nobody: the caller skips the write.
const FACING_NONE: int = 0xFF
## docs/10 section 4.6 -- the multiplayer victory points, which mode 0 looks
## for.
const FACING_ACTION_POINT_LOW: int = 30
const FACING_ACTION_POINT_HIGH: int = 34
## docs/21 section 5 -- species 2 is an inanimate object.
const SPECIES_OBJECT: int = 2
## The player numbers the net-session gate calls human.
const LAST_HUMAN_PLAYER: int = 4


## `0x0047A8E0(x, y, mode)` -- which way the unit on a cell turns.
##
## `endUnitTurn` (`0x0040B380`) calls this with mode 2 and writes the answer
## into `unit[+0x46]` unless it is [constant FACING_NONE]. What it does:
##
## * take the unit standing on `(x, y)`; no cell or no unit is `0xFF`;
## * sweep the **whole control map in index order** for a candidate;
## * mode 2 accepts any cell holding a unit of another player, mode 1 the same
##   **plus** `other[+0x4F] == 0` -- so **the end-of-turn facing does not care
##   whether the enemy can be seen.** A unit turns towards something it has no
##   line of sight to, which is the sort of thing a remake invents a fog test
##   for and gets wrong;
## * either way the candidate's species must not be 2: the table read at
##   `0x51C099 + type * 0x7E` is `SetUnitInfo`'s `+0x79` column, and the three
##   accepted values 0, 1 and 3 are human, alien and machine. Props do not
##   attract a turn;
## * the winner is chosen by a **ratchet**: a candidate needs an action point
##   byte `>=` the best so far **and** a distance strictly less than the best
##   so far. Neither half is a plain minimum, and a later candidate at the same
##   distance loses to the earlier one.
##
## The net-session gate (`0x0043B1F0`) suppresses the whole thing between two
## human players; it is false in a campaign, so it defaults to false the way it
## does everywhere else in `core`.
static func end_turn_facing(state: MapState, units: Dictionary,
		utab: UnitTypeTable, x: int, y: int,
		mode: int = FACING_MODE_ANY_ENEMY, net_gate: bool = false) -> int:
	if not state.in_bounds(x, y):
		return FACING_NONE
	var slot: int = state.unit_at(state.index_of(x, y))
	if slot == MapState.NO_UNIT or not units.has(slot):
		return FACING_NONE
	var me: UnitState = units[slot]
	var best_index: int = -1
	var best_action_point: int = 0
	var best_distance: int = 0x7FFFFFFF
	for index: int in range(state.cell_count()):
		var occupant_slot: int = state.unit_at(index)
		var other: UnitState = null
		if occupant_slot != MapState.NO_UNIT and units.has(occupant_slot):
			other = units[occupant_slot]
		var matched: bool = false
		if mode == FACING_MODE_ACTION_POINT:
			var point: int = state.action_point_at(index)
			matched = point >= FACING_ACTION_POINT_LOW \
				and point <= FACING_ACTION_POINT_HIGH
		elif other != null and other.player != me.player:
			var both_human: bool = net_gate \
				and other.player <= LAST_HUMAN_PLAYER \
				and me.player <= LAST_HUMAN_PLAYER
			if not both_human:
				matched = mode == FACING_MODE_ANY_ENEMY \
					or other.visibility == AIOverlay.VISIBILITY_VISIBLE
		if not matched:
			continue
		# The routine reads the cell's unit again here **outside** the mode
		# arms, and an empty cell ends the whole scan rather than skipping it.
		# Mode 0 is the only arm that can reach this with an empty cell.
		if other == null:
			return FACING_NONE
		if utab.species(other.type_id) == SPECIES_OBJECT:
			continue
		var cell_x: int = index % state.width
		var cell_y: int = index / state.width
		var gap: int = MoveMap.distance(cell_x, cell_y, x, y)
		if state.action_point_at(index) >= best_action_point \
				and gap < best_distance:
			best_action_point = state.action_point_at(index)
			best_distance = gap
			best_index = index
	if best_index < 0:
		return FACING_NONE
	return direction(me.x, me.y, best_index % state.width,
		best_index / state.width)


## `0x0046A760` -- the octant from the shooter to the target.
##
## The thresholds are `|dy/dx|` at 0.5 and 1.5, which is what makes the eight
## sectors unequal: the four axis-aligned ones span 53 degrees and the
## diagonals 37.
static func direction(x0: int, y0: int, x1: int, y1: int) -> int:
	var dx: int = x1 - x0
	var dy: int = y1 - y0
	if dx == 0 and dy == 0:
		return 0
	if dx == 0:
		return 0 if dy > 0 else 2
	var ratio: float = absf(float(dy) / float(dx))
	if ratio < 0.5:
		return 3 if dx > 0 else 1
	if ratio > 1.5:
		return 0 if dy > 0 else 2
	if dx > 0:
		return 6 if dy > 0 else 4
	return 5 if dy > 0 else 7


## docs/22 section 7.4 -- the defender is shot in the back.
##
## True when the attacker is firing **in the same direction the defender is
## looking**, or in either neighbouring octant.
static func is_rear_shot(attacker_facing: int, defender_facing: int) -> bool:
	return in_arc(defender_facing, attacker_facing)


## Is `facing` one of the three octants centred on `centre`?
static func in_arc(centre: int, facing: int) -> bool:
	if centre < 0 or centre >= FACINGS:
		return false
	for i: int in range(ARC_WIDTH):
		if ARC[centre * ARC_WIDTH + i] == facing:
			return true
	return false


## `0x0046FAD0` in its single-player form -- docs/22 section 7.3.
static func banner_nearby(unit: UnitState, units: Dictionary) -> bool:
	for slot: Variant in units:
		var other: UnitState = units[slot]
		if not other.is_alive() or other.player != unit.player:
			continue
		if not other.has_equipment(EQUIP_BANNER):
			continue
		if MoveMap.distance(unit.x, unit.y, other.x, other.y) < BANNER_RANGE:
			return true
	return false


## `0x00475340` -- `weapon[+0x3A]`, doubled by the `Cooler`.
static func max_heat(wtab: WeaponTable, unit: UnitState) -> int:
	var cap: int = wtab.heat(unit.weapon)
	if cap == HEAT_NONE:
		return HEAT_NONE
	return cap * 2 if unit.has_equipment(EQUIP_COOLER) else cap


## `aCheckWeaponDamage` `0x0046D1B0` -- called once per attack.
##
## Does nothing unless the weapon is **exactly** at its cap.  The roll's span is
## the constant [constant OVERHEAT_SPAN], **not** the cap: `0x0046D1D6` pushes
## `0x28`.  So every weapon that can overheat at all can also be destroyed by
## it, and the `Cooler` only makes the gate harder to reach.
##
## A roll above 30 lands on the *same* instruction as the 11-20 / 25-29 arm,
## which clears `+0x40` -- so it is a clear, not a no-op.  Pinned natively over
## eight probes at the cap.
static func check_weapon_damage(wtab: WeaponTable, unit: UnitState,
		rng: IncRandom) -> String:
	var cap: int = max_heat(wtab, unit)
	if cap == HEAT_NONE or unit.heat != cap:
		return OVERHEAT_NONE
	var roll: int = rng.draw(0, OVERHEAT_SPAN)
	if roll >= 0 and roll <= 10:
		if DAMAGING_WEAPON_TYPES.has(wtab.type_of(unit.weapon)):
			unit.malfunction = MALFUNCTION_DAMAGED
			return OVERHEAT_DAMAGE
		unit.malfunction = MALFUNCTION_JAM
		return OVERHEAT_JAM
	if roll >= 21 and roll <= 24:
		unit.malfunction = MALFUNCTION_DAMAGED
		return OVERHEAT_DAMAGE
	if roll == 30:
		unit.hp = 0
		return OVERHEAT_DESTROYED
	unit.malfunction = 0
	return OVERHEAT_CLEARED


## `0x0046C960` -- returns the damage actually dealt.
##
## docs/22 section 7.4: the difficulty level **widens the roll upward** rather
## than scaling it -- the floor `(D+1)/2` is the same at every level and only
## the span grows -- and fatigue is a multiplier on the receiving end.
static func apply_damage(defender: UnitState, damage: int,
		attacker_facing: int, ai_level: int, human_players: int,
		game_mode: int, rng: IncRandom) -> int:
	if defender.type_id == IMMUNE_UNIT_TYPE:
		return 0
	if damage == DAMAGE_SENTINEL:
		# Weapon 14, `Enhanced Laser Gun`: exactly 2 HP, ignoring the roll,
		# fatigue, armour and the difficulty level.
		defender.hp = maxi(defender.hp - SENTINEL_DAMAGE_DEALT, 0)
		return SENTINEL_DAMAGE_DEALT

	# `aRandom` is `(base, span)`, not `(min, max)`, so the roll spans `damage`
	# values from the floor upward and the level adds one to the **span**.
	var base: int = IncInt.div_trunc(damage + 1, 2)
	# Written as three arms, the way the original is, rather than as
	# `damage + ai_level`: the engine has a fourth arm that reports "incorrect
	# ai level!", and folding the three into arithmetic would silently accept a
	# level it refuses.
	var dealt: int = 0
	if ai_level == 0:
		dealt = rng.draw(base, damage)
	elif ai_level == 1:
		dealt = rng.draw(base, damage + 1)
	elif ai_level == 2:
		dealt = rng.draw(base, damage + 2)
	else:
		push_error("incorrect ai level: %d" % ai_level)
		return 0

	if defender.fp == 0:
		dealt += rng.draw(0, damage + 1)
		dealt += rng.draw(0, damage + 1)
	elif defender.fp == 1:
		dealt += rng.draw(0, damage + 1)

	var armour: int = defender.armour_front
	if is_rear_shot(attacker_facing, defender.facing):
		armour = defender.armour_rear
	# `aRandom(armour/2, armour)` -- a subtraction, not a percentage.  The
	# engine's second, guarded roll is dead code: the first cannot return less
	# than its own base.
	var absorbed: int = 0
	if armour != 0:
		absorbed = rng.draw(IncInt.div_trunc(armour, 2), armour)
	dealt = dealt - absorbed if dealt > absorbed else 0

	if human_players > 1 or game_mode == 2:
		dealt = IncInt.div_trunc(dealt * 3, 4)

	defender.hp = defender.hp - dealt if dealt < defender.hp else 0
	return dealt


## `0x0046AA10(weapon, aimX, aimY, shooterX, shooterY, shooterFacing)`.
##
## Returns `[x, y, marker]` triples in the order the handler writes them --
## which is the order the damage rolls come out in, so it is not a set. All
## sixteen handlers are here since the third slice; `unsupported` is kept for
## the caller's sake and is now only ever filled by a weapon id above 47.
##
## The dispatcher takes **six** arguments and not three. Its two call sites
## settle what they are: the shot resolver at `0x0046B6AC` pushes the shooter's
## `+0x42`, `+0x43` and `+0x46`, and `aExecuteBomb` (`0x00470318`) passes one
## value for all three because weapon 36 reads none of them. `shooter` carries
## the last three; a family that needs it and does not get it marks nothing and
## says so.
##
## Four things a reading of docs/22 section 7.2's table alone gets wrong, all
## cross-checked between the raw listing and Ghidra:
##
## * **weapons 17 and 22 blast the shooter's own cell**, not the aim cell;
## * **weapon 44 is not "every unit on the map"** -- it is every unit within
##   `aGetDistance < 4` of the aim point;
## * **weapon 13 falls through** into weapon 42's arm, so the eighteen
##   scattered cells are followed by the aim cell at `0x51`;
## * the two unrolled eight-neighbour handlers write in **two different
##   orders**, and neither is `dy`-then-`dx`.
static func mark_cells(state: MapState, units: Dictionary, weapon_id: int,
		tx: int, ty: int, unsupported: Array[String],
		context: PatternContext = null) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	if NO_PATTERN.has(weapon_id):
		return out
	var aim_in: bool = state.in_bounds(tx, ty)
	if AIM_FULL.has(weapon_id):
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_FULL]))
		return out
	if AIM_70.has(weapon_id):
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_70]))
		return out
	if AIM_FORCED_HIT.has(weapon_id):
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_FORCED_HIT]))
		return out
	if AIM_STUN.has(weapon_id):
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_STUN]))
		return out
	if AIM_AND_NEIGHBOURS.has(weapon_id):
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_FULL]))
		out.append_array(_ring(state, tx, ty, AIM_NEIGHBOUR_ORDER))
		return out
	if NEIGHBOURS_THEN_AIM_70.has(weapon_id):
		out.append_array(_ring(state, tx, ty, FLAME_B_NEIGHBOUR_ORDER))
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_70]))
		return out
	if EVERY_UNIT.has(weapon_id):
		return _every_unit(state, tx, ty)
	if SCATTER_18.has(weapon_id):
		if context == null or context.rng == null:
			unsupported.append(
				"weapon %d draws from aRandom; no generator was given"
				% weapon_id)
			return out
		return _scatter(state, tx, ty, context.rng)
	if SPORES_FILTERED.has(weapon_id) or EXPLOSIVES.has(weapon_id):
		if not _has_shooter(context, weapon_id, unsupported):
			return out
		return _self_centred_ring(state, units, context,
			SPORES_FILTERED.has(weapon_id))
	if RADIUS_BY_RANGE.has(weapon_id):
		if not _has_shooter(context, weapon_id, unsupported):
			return out
		return _radius_by_range(state, units, weapon_id, tx, ty, context)
	if LINE_OF_SIGHT_FROM_AIM.has(weapon_id) \
			or SPECIAL_OBJECTS.has(weapon_id):
		if not _has_shooter(context, weapon_id, unsupported):
			return out
		return _arc_sweep(state, units, tx, ty, context,
			LINE_OF_SIGHT_FROM_AIM.has(weapon_id))
	unsupported.append(
		"weapon %d uses a target pattern this model does not simulate; "
		% weapon_id + "docs/22 section 7.2 describes it")
	return out


static func _has_shooter(context: PatternContext, weapon_id: int,
		unsupported: Array[String]) -> bool:
	if context != null and context.shooter != null:
		return true
	unsupported.append(
		"weapon %d reads the shooter's position and facing " % weapon_id
		+ "(0x0046AA10's arguments 4, 5 and 6); none was given")
	return false


## The eight neighbours of a cell, in a handler's own write order.
static func _ring(state: MapState, x: int, y: int,
		order: Array[Vector2i]) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	for step: Vector2i in order:
		if state.in_bounds(x + step.x, y + step.y):
			out.append(PackedInt32Array([x + step.x, y + step.y, MARKER_70]))
	return out


## `0x0046AD9F` -- eighteen scattered cells, then the aim cell.
##
## **The y offset is drawn before the x offset**: the two `aRandom` calls carry
## source lines 978 and 977 in that order, so the compiler evaluated the
## arguments right to left. A model that draws x first agrees on the cells and
## disagrees on every roll that follows in the same turn. The draws happen for
## all eighteen iterations whether or not the cell is on the map -- the write
## is bounds-checked and the draw is not.
static func _scatter(state: MapState, tx: int, ty: int,
		rng: IncRandom) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	for _i: int in range(SCATTER_COUNT):
		var dy: int = rng.draw(SCATTER_BASE, SCATTER_SPAN)
		var dx: int = rng.draw(SCATTER_BASE, SCATTER_SPAN)
		if state.in_bounds(tx + dx, ty + dy):
			out.append(PackedInt32Array([tx + dx, ty + dy, MARKER_FULL]))
	# The fall-through into weapon 42's arm.
	if state.in_bounds(tx, ty):
		out.append(PackedInt32Array([tx, ty, MARKER_70]))
	return out


## `0x0046AED2` -- every occupied cell within `< 4` of the aim.
static func _every_unit(state: MapState, tx: int,
		ty: int) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	for index: int in range(state.cell_count()):
		if state.unit_at(index) == MapState.NO_UNIT:
			continue
		var cx: int = index % state.width
		var cy: int = index / state.width
		if MoveMap.distance(tx, ty, cx, cy) < EVERY_UNIT_MAX_DISTANCE:
			out.append(PackedInt32Array([cx, cy, MARKER_FULL]))
	return out


## `0x0046ACCD` (spores) and `0x0046ABD5` (explosives).
##
## Both stamp the **shooter's own cell** at `0x50` and then walk the stepper's
## eight directions from it. A neighbour is stamped only when it holds a unit,
## and then spores skip an occupant owned by `0xFC` while explosives stamp a
## **large** occupant's own `+0x42`/`+0x43` instead of the stepped cell.
static func _self_centred_ring(state: MapState, units: Dictionary,
		context: PatternContext, spores: bool) -> Array[PackedInt32Array]:
	var shooter: UnitState = context.shooter
	var out: Array[PackedInt32Array] = []
	if state.in_bounds(shooter.x, shooter.y):
		out.append(PackedInt32Array([shooter.x, shooter.y, MARKER_FULL]))
	for step: Vector2i in STEP_DIRECTIONS:
		var nx: int = shooter.x + step.x
		var ny: int = shooter.y + step.y
		if not state.in_bounds(nx, ny):
			continue
		var slot: int = state.unit_at(state.index_of(nx, ny))
		if slot == MapState.NO_UNIT or not units.has(slot):
			continue
		var occupant: UnitState = units[slot]
		if spores:
			if occupant.player == PLAYER_NEUTRAL:
				continue
			out.append(PackedInt32Array([nx, ny, MARKER_70]))
			continue
		if context.utab.unit_size(occupant.type_id) == 1:
			out.append(PackedInt32Array(
				[occupant.x, occupant.y, MARKER_70]))
		else:
			out.append(PackedInt32Array([nx, ny, MARKER_70]))
	return out


## `0x0046B1C7` (weapons 5 and 41) -- a blast that grows with the range.
##
## The radius comes from how far the shot went, not from the weapon: 1 up to
## two fields, 2 up to twenty-five, 3 beyond. Inside it a cell is stamped only
## when it holds a unit, the octant from the shooter to that cell is **exactly**
## the shooter's facing, and `aGetHitProbability` answers with a chance in
## 1..253.
static func _radius_by_range(state: MapState, units: Dictionary,
		weapon_id: int, tx: int, ty: int,
		context: PatternContext) -> Array[PackedInt32Array]:
	var shooter: UnitState = context.shooter
	var reach: int = MoveMap.distance(shooter.x, shooter.y, tx, ty)
	var radius: int = RADIUS_BEYOND
	if reach <= RADIUS_NEAR_LIMIT:
		radius = 1
	elif reach <= RADIUS_MID_LIMIT:
		radius = 2
	var out: Array[PackedInt32Array] = []
	for index: int in range(state.cell_count()):
		var cx: int = index % state.width
		var cy: int = index / state.width
		if MoveMap.distance(cx, cy, tx, ty) > radius:
			continue
		var slot: int = state.unit_at(index)
		if slot == MapState.NO_UNIT or not units.has(slot):
			continue
		if direction(shooter.x, shooter.y, cx, cy) != shooter.facing:
			continue
		var target: UnitState = units[slot]
		var chance: HitChance = HitChance.compute(state, units, context.utab,
			context.wtab, shooter, target, weapon_id, true,
			context.human_players, context.game_mode)
		if chance.percent > 0 and chance.percent < PATTERN_CHANCE_REFUSED:
			out.append(PackedInt32Array([cx, cy, MARKER_FULL]))
	return out


## `0x0046AF38` (weapon 9) and `0x0046B0D8` (weapon 11).
##
## The two share a shape and differ in what they look for: weapon 9 wants a
## unit the shooter can **see**, weapon 11 a cell whose action point is in the
## multiplayer band 30..34 and does not care what stands on it. Both then
## require the octant from the shooter to the cell to lie in the three-octant
## arc around the shooter's facing, and the cell to be within four fields of
## the aim point.
static func _arc_sweep(state: MapState, units: Dictionary, tx: int, ty: int,
		context: PatternContext,
		by_line_of_sight: bool) -> Array[PackedInt32Array]:
	var shooter: UnitState = context.shooter
	var out: Array[PackedInt32Array] = []
	var eye: int = state.height_at(state.index_of(shooter.x, shooter.y)) \
		+ HitChance.eye_height(context.utab, shooter.type_id)
	for index: int in range(state.cell_count()):
		var cx: int = index % state.width
		var cy: int = index / state.width
		if by_line_of_sight:
			var slot: int = state.unit_at(index)
			if slot == MapState.NO_UNIT or not units.has(slot):
				continue
			var target: UnitState = units[slot]
			var blocked: int = LineOfSight.check(state, units, context.utab,
				cx, cy,
				state.height_at(index)
				+ HitChance.eye_height(context.utab, target.type_id),
				shooter.x, shooter.y, eye, 1, context.human_players,
				context.game_mode)
			if blocked >= LineOfSight.TERRAIN:
				continue
		elif state.action_point_at(index) < SPECIAL_OBJECT_LOW \
				or state.action_point_at(index) > SPECIAL_OBJECT_HIGH:
			continue
		if not in_arc(direction(shooter.x, shooter.y, cx, cy),
				shooter.facing):
			continue
		if MoveMap.distance(cx, cy, tx, ty) > ARC_SWEEP_MAX_DISTANCE:
			continue
		out.append(PackedInt32Array([cx, cy, MARKER_FULL]))
	return out


## docs/22 section 7.2 -- what the marker is worth at that cell.
static func marker_damage(wtab: WeaponTable, marker: int,
		weapon_id: int) -> int:
	var full: int = wtab.damage(weapon_id)
	if marker == MARKER_FULL:
		return full
	if marker == MARKER_70:
		return IncInt.div_trunc(full * 70 + 1, 100)
	if marker == MARKER_50:
		return IncInt.div_trunc(full * 50 + 1, 100)
	if marker == MARKER_FLAT_100:
		return 100
	return 0                     # 0x54 and 0x55 roll no damage at all


## `aAttackUnit` `0x0046B450` -- docs/22 section 7, in the order it runs.
static func attack(state: MapState, units: Dictionary, utab: UnitTypeTable,
		wtab: WeaponTable, x: int, y: int, tx: int, ty: int, ai_level: int,
		human_players: int, game_mode: int, rng: IncRandom) -> AttackResult:
	var result: AttackResult = AttackResult.new()
	var attacker: UnitState = _unit_on(state, units, x, y)
	if attacker == null:
		result.reason = "no attacker on that cell"
		return result

	# If a unit stands on the aim point, the aim point becomes **that unit's
	# own** cell -- which matters for units occupying more than one field.
	var standing: UnitState = _unit_on(state, units, tx, ty)
	if standing != null:
		tx = standing.x
		ty = standing.y

	result.fired = true
	result.overheat = check_weapon_damage(wtab, attacker, rng)
	if attacker.malfunction != 0 or attacker.hp == 0:
		result.fired = false
		result.reason = ("the weapon jammed or was destroyed"
			if attacker.malfunction != 0 else "the attacker is dead")
		return result

	attacker.facing = direction(x, y, tx, ty)
	result.facing = attacker.facing
	var unsupported: Array[String] = []
	result.marked = mark_cells(state, units, attacker.weapon, tx, ty,
		unsupported, PatternContext.create(attacker, utab, wtab, rng,
			human_players, game_mode))
	if not unsupported.is_empty():
		result.fired = false
		result.reason = unsupported[0]
		return result

	var banner: bool = banner_nearby(attacker, units)
	for cell: PackedInt32Array in result.marked:
		var cx: int = cell[0]
		var cy: int = cell[1]
		var marker: int = cell[2]
		var target: UnitState = _unit_on(state, units, cx, cy)
		if target == null:
			continue
		if state.obstacle_at(state.index_of(cx, cy)) == EFFECT_SHIELDED:
			result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
				"marker": MARKER_RESOLVED, "dealt": 0, "chance": 0, "roll": 0})
			continue

		var reach: HitChance = HitChance.compute(state, units, utab, wtab,
			attacker, target, attacker.weapon, false, human_players, game_mode)
		var chance: int = reach.percent if reach.in_range \
			else wtab.hit(attacker.weapon)
		if banner:
			chance *= 2
		var damage: int = marker_damage(wtab, marker, attacker.weapon)
		# **The roll is drawn before the overrides, not after.**  The native
		# capture shows two draws against a `Case` whether or not the roll
		# would have connected, against one for a miss on an ordinary target:
		# the overrides replace the comparison, never the generator.
		var roll: int = rng.draw(0, HIT_SPAN)
		if marker == MARKER_FORCED_HIT:
			chance = 0
			roll = 1
		elif marker == MARKER_STUN:
			chance = 1
			roll = 0
		if GUARANTEED_HIT_SPECIALS.has(utab.special(target.type_id)):
			chance = 0
			roll = 1
			damage = GUARANTEED_HIT_DAMAGE

		if chance + HIT_BONUS < roll:
			result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
				"marker": MARKER_MISS, "dealt": 0, "chance": chance,
				"roll": roll})
			continue

		if marker == MARKER_STUN:
			# No damage is rolled; unless a Damage Absorber charge is spent the
			# target loses the rest of its turn.
			var stunned: bool = target.absorber == 0
			if target.absorber != 0:
				target.absorber -= 1
			else:
				target.action_state = STUNNED_ACTION_STATE
				target.mp = 0
			result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
				"marker": MARKER_RESOLVED, "dealt": 0, "chance": chance,
				"roll": roll, "stunned": stunned})
			continue

		var dealt: int = 0
		if target.absorber != 0:
			# docs/22 section 7.5: a charge nullifies the damage entirely.
			target.absorber -= 1
		else:
			dealt = apply_damage(target, damage, attacker.facing, ai_level,
				human_players, game_mode, rng)
		var killed: bool = not target.is_alive()
		if killed:
			state.set_unit(state.index_of(target.x, target.y), MapState.NO_UNIT)
		result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
			"marker": MARKER_KILLED if killed else MARKER_HIT, "dealt": dealt,
			"chance": chance, "roll": roll})

	# After the shot: ammunition and heat.  docs/22 section 7.5 gates on
	# **both** halves -- a weapon whose `mun` column is 255 spends nothing, and
	# neither does unit type 0x42.  Dropping the second would disarm that type.
	if wtab.has(attacker.weapon):
		if (wtab.magazine(attacker.weapon) != MUN_NONE
				and attacker.type_id != NO_AMMO_UNIT_TYPE):
			attacker.ammo -= wtab.mun_per_fight(attacker.weapon)
		var cap: int = max_heat(wtab, attacker)
		if cap != HEAT_NONE and attacker.heat < cap:
			attacker.heat += 1
	return result


static func _unit_on(state: MapState, units: Dictionary, x: int,
		y: int) -> UnitState:
	if not state.in_bounds(x, y):
		return null
	var slot: int = state.unit_at(state.index_of(x, y))
	if slot < 0 or not units.has(slot):
		return null
	var unit: UnitState = units[slot]
	return unit if unit.is_alive() else null
