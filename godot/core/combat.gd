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

## docs/22 section 7.2 -- the weapon families this file simulates.  The other
## seven -- the radius that widens with the shot, the line-of-sight sweep, the
## whole-map sweep, the 18-cell scatter, the re-centred explosion and the two
## special-object sweeps -- are **not** here.  [method mark_cells] returns an
## empty array and sets `unsupported`, so a shot this model cannot resolve says
## so instead of quietly marking nothing.
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


## `0x0046AA10` -- the covered cells and their markers, for the simple families.
##
## Returns `[x, y, marker]` triples.  A family this file does not simulate
## returns empty **and** appends its name to `unsupported`, so the caller can
## refuse instead of reporting a clean miss.
static func mark_cells(state: MapState, units: Dictionary, weapon_id: int,
		tx: int, ty: int,
		unsupported: Array[String]) -> Array[PackedInt32Array]:
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
	var neighbours: Array[PackedInt32Array] = []
	for dy: int in [-1, 0, 1]:
		for dx: int in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			if state.in_bounds(tx + dx, ty + dy):
				neighbours.append(
					PackedInt32Array([tx + dx, ty + dy, MARKER_70]))
	if AIM_AND_NEIGHBOURS.has(weapon_id):
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_FULL]))
		out.append_array(neighbours)
		return out
	if NEIGHBOURS_THEN_AIM_70.has(weapon_id):
		# The order is the handler's own: the ring first, then the aim point.
		out.append_array(neighbours)
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_70]))
		return out
	if SPORES_FILTERED.has(weapon_id):
		# Two things "the same, filtered" loses: an **empty** neighbour is
		# skipped too -- the `cell->unit == 0xFFFF` test comes before the owner
		# test -- and the sweep runs the stepper's direction order rather than
		# the unrolled ring above.
		if aim_in:
			out.append(PackedInt32Array([tx, ty, MARKER_FULL]))
		for step: Vector2i in STEP_DIRECTIONS:
			var nx: int = tx + step.x
			var ny: int = ty + step.y
			if not state.in_bounds(nx, ny):
				continue
			var slot: int = state.unit_at(state.index_of(nx, ny))
			if slot == MapState.NO_UNIT:
				continue
			if not units.has(slot):
				continue
			var occupant: UnitState = units[slot]
			if occupant.player == PLAYER_NEUTRAL:
				continue
			out.append(PackedInt32Array([nx, ny, MARKER_70]))
		return out
	unsupported.append(
		"weapon %d uses a target pattern this model does not simulate; "
		% weapon_id + "docs/22 section 7.2 describes it")
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
		unsupported)
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
