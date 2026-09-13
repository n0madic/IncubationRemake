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
## The resolver accepts the whole `0x50..0x59` input band, although target
## pattern handlers only write the six named values above.
const MARKER_INPUT_LAST: int = 0x59
## docs/22 section 7.3 -- the markers the resolver writes back.
const MARKER_MISS: int = 0x5A
const MARKER_RESOLVED: int = 0x5B
const MARKER_HIT: int = 0x5C
const MARKER_KILLED: int = 0x5D
## `aSetCellState` protects the whole scratch band from a second write.
const MARKER_SCRATCH_LAST: int = 0x5E
## `aSetCellState` accepts a neighbour only below this absolute height delta;
## equality is refused. Secondary blasts supply their centre cell's height;
## geometric weapon-pattern handlers bypass the check with -1.
const MARKER_HEIGHT_WINDOW: int = 0x640

## docs/22 section 7.3 -- the roll is `aRandom(0, 100)` and the comparison is
## `chance + 10 < roll`, so a weapon at 0 % still connects 11 % of the time.
const HIT_BONUS: int = 10
const HIT_SPAN: int = 100

## docs/21 section 6 -- the weapon `special` column's value 1: *the weapon
## changes in close combat into the weapon named by `param`*.  Three shipped
## guns carry it -- `Advanced Combat Gun`, `Standard Assault Rifle` and
## `Light Plasma Gun` -- and each names one of the three `Light Bayonet` rows,
## which name it back.
const SPECIAL_CLOSE_COMBAT: int = 1
## `cmp cl, 0x1E` / `0x1F` / `0x20` at `0x0046F8E8` -- the three ids the revert
## arm accepts.  The test is on the weapon the unit is **holding**, which is
## what keeps the swap from undoing itself on the way in: a gun with
## `special` 1 that is not one of these three is on its way to a bayonet, and
## one that is, is on its way back.
const CLOSE_COMBAT_WEAPONS: Array[int] = [30, 31, 32]
## The distance the swap wants, after the large-unit subtraction of
## docs/22 section 5.1 -- `cmp eax, 1` at `0x0046FA1B`.
const CLOSE_COMBAT_DISTANCE: int = 1
## `cmp edx, 0x10` at `0x0046FAAC`, over `abs(dh) / 160` -- the two cells may
## stand sixteen height levels apart and no more.  The reciprocal multiply is
## `0x66666667` with `sar 6`, which is a truncating divide by
## [constant UnitTypeTable.HEIGHT_UNIT].
const CLOSE_COMBAT_HEIGHT_LEVELS: int = 16

## docs/22 section 7 -- target `special` values that force the hit and the
## damage. 12 is `Barrel`/`Parabomb`, 13 is `Case`. A 12 also stamps its eight
## neighbours for the secondary pass inside [method attack].
const SPECIAL_EXPLODES_ON_HIT: int = 12
const SPECIAL_EXPLODES_ON_DEATH: int = 16
const GUARANTEED_HIT_SPECIALS: Array[int] = [SPECIAL_EXPLODES_ON_HIT, 13]
const GUARANTEED_HIT_DAMAGE: int = 255

## docs/21 section 5 -- `special` 9, the one arm of the effect dispatcher
## `0x0046F210` that rewrites the roster rather than a number.
##
## The whole rule is read off `0x0046F279`, the dispatcher's `case 4`:
## `Squee'Coo` (type 57, the only shipped carrier) that is **hit but not
## killed**, has five hit points or fewer left, and was hit by a weapon whose
## `type` column is 1, 2 or 4, is removed and replaced **in place** by a
## neutral `Squee'Ther` inheriting its AI group -- and the fog is then rebuilt
## for the player holding the turn, permanently (docs/22 section 9.4).
const SPECIAL_HATCH: int = 9
## `push 0x36` at `0x0046F338`; `push 0xff` at `0x0046F33A`.
const HATCH_TYPE: int = 0x36
const HATCH_PLAYER: int = UnitState.PLAYER_ALIEN
## `cmp byte [esi + 0x16], 5` then `ja` -- six or more and nothing happens.
const HATCH_HP_LIMIT: int = 5
## The attacker's weapon `type` (`SetWeaponInfo + 0x37`), compared to 1, 2 and
## 4 at `0x0046F2A3`.
const HATCH_WEAPON_TYPES: Array[int] = [1, 2, 4]

## docs/22 section 7.4 -- the sentinel damage value and the one immune type.
const DAMAGE_SENTINEL: int = 0xFE
const SENTINEL_DAMAGE_DEALT: int = 2
const IMMUNE_UNIT_TYPE: int = 0x23
## docs/22 sections 7.3 and 7.5 -- Bea'Coo is also the one type exempt from
## spending ammunition. A type-2 weapon writes literal 1000 into applyDamage's
## u8 argument, so the damage that arrives is 232.
const BEACOO_TYPE: int = 0x42
const BEACOO_WEAPON_TYPE: int = 2
const BEACOO_DAMAGE: int = 1000 & 0xFF
const NO_AMMO_UNIT_TYPE: int = BEACOO_TYPE
## docs/22 section 7.3 -- a cell whose effect state is 3 takes no damage.
const EFFECT_SHIELDED: int = 3
## docs/22 section 7.3 -- a `Banner` carrier within four fields doubles the
## chance; equipment 8, and `0x0046FAD0` does not skip the unit it was asked
## about, so a carrier counts itself.
const EQUIP_BANNER: int = 8
const BANNER_RANGE: int = 4
## docs/22 section 7.5 -- equipment 18, whose slot `+0x33` is what
## `0x00475590` reads before it reads the charges at `+0x3A`.
const EQUIP_DAMAGE_ABSORBER: int = 18
## docs/22 section 7.3 -- the one weapon whose hit **converts** its target,
## `cmp byte [esi+0x3F], 0x2F` at `0x0046BDAD`. `Laser Enhanced` in the shipped
## table, carried by no shipped unit; `tools/turn_gold.py` writes the byte.
const CONVERTER_WEAPON: int = 0x2F
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
## `0x0046B0D8` -- weapon 11 `Multi-target Destroyer`; cells whose **state
## byte** is in the target overlay's band 30..34 (`mov al, [edi] / cmp al,
## 0x1E / jb / cmp al, 0x22 / ja` at `0x0046B0F4`, `edi` stepping the control
## map by 0x17) -- the enemies the shooter's own overlay stamped by hit
## chance, docs/23 section 6. Until 2026-09-12 this said the action point,
## the same mislabel docs/23 section 3.6's pseudocode had put on
## `aGetDirectionTo`; `blob_gold.SHOT_BAND_POKES` has the captures that found
## the byte.
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
## their last four entries; `aSetCellState` keeps the first write on overlaps.
const FLAME_B_NEIGHBOUR_ORDER: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(0, 1), Vector2i(0, -1)]
## docs/10 section 5.7 -- the neutral-prop owner the spores pattern skips.
const PLAYER_NEUTRAL: int = 0xFC
## `0x004308C0`'s direction table (docs/23 section 8), in the order the spores
## handler sweeps it with `allowDiagonal` set.  It is neither the facing
## encoding nor the `dy`-then-`dx` order [constant AIM_AND_NEIGHBOURS] writes
## its ring in.
const STEP_DIRECTIONS: Array[Vector2i] = [
	Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, 0),
	Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1), Vector2i(-1, -1)]
## docs/22 section 7.2 -- the ids whose dispatch entry reports an error.  28 is
## the `-` placeholder and 37 is `Mine`; the other seven `Info.lcl` never
## defines.  They mark nothing, and that is correct rather than unsupported.
const NO_PATTERN: Array[int] = [18, 19, 28, 33, 34, 35, 37, 38, 39]

## docs/21 section 4 -- `ParaBomb`.  A mine resolves as a shot from this.
const BOMB_WEAPON: int = 36
## `aExecuteBomb` does not read weapon 36's damage column: `0x004703CF`
## installs 30 for an ordinary target, while `0x00470419` installs literal
## 1000 for `special` 12 and applyDamage narrows that argument to u8.
const BOMB_DAMAGE: int = 30
const BOMB_EXPLOSIVE_DAMAGE: int = 1000 & 0xFF
## The heading `aExecuteBomb` hands `applyDamage` -- `push 0xFF` at
## `0x004704BF`. No octant's arc holds it, so a mine always meets the **front**
## armour. The model used to derive a heading from the centre.
const BOMB_FACING: int = 0xFF


## `0x0047A8E0`'s three modes. Only mode 2 is reached from `endUnitTurn`; mode
## 0 looks for a cell whose **state** byte carries a target band -- the
## interface's own mode, corrected 2026-09-05 (docs/43 section 4.4) -- and
## mode 1 is mode 2 **plus a visibility test**.
const FACING_MODE_TARGET_BAND: int = 0
const FACING_MODE_VISIBLE_ENEMY: int = 1
const FACING_MODE_ANY_ENEMY: int = 2
## What it answers when it finds nobody: the caller skips the write.
const FACING_NONE: int = 0xFF
## The cell state bytes mode 0 accepts -- the target overlay's hit bands
## (docs/23 section 6). The **state** byte `cell[+0x00]`, not the action point.
const FACING_STATE_LOW: int = 30
const FACING_STATE_HIGH: int = 34
## `cell[+0x00]` after `0x0042EE90`'s reset -- what every cell reads as when
## the caller hands over no overlay.
const FACING_STATE_PLAIN: int = 1
## docs/21 section 5 -- species 2 is an inanimate object.
const SPECIES_OBJECT: int = 2
## docs/21 section 2 -- species 0 is human; only a human's pool raise plays the
## skill orbit (`0x0046C269`).
const SPECIES_HUMAN: int = 0

# --- docs/22 section 7.5: the kill award -------------------------------------
# `0x0047AFD0` / `0x0047B090` / `0x0047B100` / `0x0047AF90`, transcribed from
# their instructions (`combat_tables.py` pins every one) and measured in the
# campaign arm by `turn_gold.py`'s `experience` phase. Same names as
# `inclib.combat`.

## `0x0043B740` returns the game mode; 1 is the campaign (docs/11), and the
## gain routine returns the type's `exp` byte unchanged for it (`0x0047AFD7`).
const GAME_MODE_CAMPAIGN: int = 1
## `0x0047AFF5`..`0x0047B013` -- `aiLevel()` 0, 1 and 2 select 4, 3 and **1**;
## anything else keeps the 2 the routine starts with. That 2 -> 1 and 3 -> 2 is
## what the `dec / je` chain does, and it is kept as it is. Reached only by
## the session modes the remake does not play.
const DIFFICULTY_MULTIPLIER: Dictionary = {0: 4, 1: 3, 2: 1}
const DIFFICULTY_MULTIPLIER_DEFAULT: int = 2
## `cmp eax, 0x48` and `cmp eax, 0x6C` -- the bands of the session ladder.
const EXPERIENCE_LOW: int = 72
const EXPERIENCE_HIGH: int = 108
## `fcomp [0x4B1640]` -- 144.0, the cap on both bytes; `fmul [0x4B163C]` --
## 0.5, the halved gain above 108.
const EXPERIENCE_CAP: int = 144
const EXPERIENCE_HALF: float = 0.5
## `imul 0x38E38E39 / sar edx, 4` -- a signed divide by 72.
const EXPERIENCE_DIVISOR: int = 72
## `0x0047AFB5` -- the kill counter saturates at 255.
const KILL_COUNT_CAP: int = 0xFF
## docs/10 section 5 -- a skill level is twelve points of the pool.
const POINTS_PER_SKILL_LEVEL: int = 12
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
## * mode 0 accepts a cell whose **state byte** is a target band 30..34;
##   `states` is that byte per cell ([member AIContext.state]), and a caller
##   without an overlay reads every cell as 1. Until 2026-09-05 this read the
##   action point here and in the ratchet, on a mislabelled line of docs/23
##   section 3.6's pseudocode; the decompile tests `*cell` in both places;
## * the winner is chosen by a **ratchet**: a candidate needs a state byte
##   `>=` the best so far **and** a distance strictly less than the best so
##   far. Neither half is a plain minimum, and a later candidate at the same
##   distance loses to the earlier one; with every cell at 1 the ratchet is
##   the nearest candidate.
##
## The net-session gate (`0x0043B1F0`) suppresses the whole thing between two
## human players; it is false in a campaign, so it defaults to false the way it
## does everywhere else in `core`.
static func end_turn_facing(state: MapState, units: Dictionary,
		utab: UnitTypeTable, x: int, y: int,
		mode: int = FACING_MODE_ANY_ENEMY, net_gate: bool = false,
		states: PackedByteArray = PackedByteArray()) -> int:
	if not state.in_bounds(x, y):
		return FACING_NONE
	var slot: int = state.unit_at(state.index_of(x, y))
	if slot == MapState.NO_UNIT or not units.has(slot):
		return FACING_NONE
	var me: UnitState = units[slot]
	var has_states: bool = states.size() == state.cell_count()
	if not states.is_empty() and not has_states:
		# The Python twin raises here (`inclib/combat.py`), and a silent
		# "no overlay" would be a different answer rather than a refusal:
		# every cell would read as plain and the turn would go to the
		# nearest candidate instead of the best band.
		push_error("end_turn_facing: %d state bytes for %d cells"
			% [states.size(), state.cell_count()])
	var best_index: int = -1
	var best_state: int = 0
	var best_distance: int = 0x7FFFFFFF
	for index: int in range(state.cell_count()):
		var occupant_slot: int = state.unit_at(index)
		var other: UnitState = null
		if occupant_slot != MapState.NO_UNIT and units.has(occupant_slot):
			other = units[occupant_slot]
		var cell_state: int = states[index] if has_states else FACING_STATE_PLAIN
		var matched: bool = false
		if mode == FACING_MODE_TARGET_BAND:
			matched = cell_state >= FACING_STATE_LOW \
				and cell_state <= FACING_STATE_HIGH
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
		if cell_state >= best_state and gap < best_distance:
			best_state = cell_state
			best_distance = gap
			best_index = index
	if best_index < 0:
		return FACING_NONE
	return direction(me.x, me.y, best_index % state.width,
		best_index / state.width)


## `0x0046A760` -- the octant from the shooter to the target.
##
## The thresholds are `|dy/dx|` at 0.5 and 1.5, which is what makes the eight
## sectors unequal -- and unequal in **three** sizes, because the two
## thresholds are not each other's reciprocals. Measured by sweeping a full
## turn: facings 0 and 2, the two along y, span 67.38 degrees each; facings 1
## and 3, along x, span 53.13; the four diagonals span 29.75. So a unit can
## stand up to **33.69 degrees** off the line to what it is looking at, which
## is what [method UnitsView.aim_twist] measures and the picture turns a
## shooter's waist by.
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
## `0x00475590` -- the charges a Damage Absorber has left, or none at all.
##
## `+0x3A` is read **only behind `+0x33`**, equipment slot 18: a record whose
## equipment does not carry the absorber has no charges whatever the byte
## holds. Six placed aliens on `_C_119.lev` hold a stale 123 or 126 there and
## are refreshed only at their first hand-over -- after the human's first
## turn -- and the engine lets that turn's shots through.
static func absorber_charges(unit: UnitState) -> int:
	if not unit.has_equipment(EQUIP_DAMAGE_ABSORBER):
		return 0
	return unit.absorber


## `0x004755B0` -- spend one charge behind the same gate; `true` if spent.
static func spend_absorber(unit: UnitState) -> bool:
	if absorber_charges(unit) == 0:
		return false
	unit.absorber -= 1
	return true


## `0x0046BDC7`..`0x0046BDEB` -- weapon 47's arm, in its order: the target's
## player becomes the shooter's, its movement points are refilled by
## `aGetMovePoints` (whose Banner scan reads the **new** player, which is why
## the player is written first), its action state is cleared, and it looks
## around from its own cell for its new side -- the writing pass of docs/22
## section 9.3. Returns that pass's answer.
static func convert_unit(state: MapState, units: Dictionary,
		utab: UnitTypeTable, target: UnitState, player: int, ai_level: int,
		human_players: int, game_mode: int) -> bool:
	target.player = player
	target.mp = Allowance.for_unit(target, utab, units, ai_level)
	target.action_state = 0
	return Visibility.look_from(state, units, utab, target, target.x,
		target.y, human_players, game_mode)


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
##
## The roll of exactly 30 is `0x0046D2D8`: the loss counter `0x0043B8D0`,
## `aRemoveUnitElement` `0x004779C0` -- the cell, the hero counter and the
## hit-point byte, so the carrier is **off the map** and not merely at zero
## hit points -- and, when the carrier's own cell holds a shield (`+0x10 ==
## 3`), `aDeleteSpecialObject` `0x00406960` on it with the two bytes cleared
## behind. Writing `hp = 0` alone left the cell naming a dead unit, no loss
## on the scoreboard and `HeroKilled` never raised.
##
## *shielded* is the cheat's answer, decided **before** the removal: a
## shielded marine may not be killed by its own gun, and a removal cannot be
## undone by restoring the hit points afterwards. The arm is downgraded to
## the damaged-weapon one it shares an instruction with rather than skipped,
## so the draw is where it would have been either way.
static func check_weapon_damage(wtab: WeaponTable, unit: UnitState,
		rng: IncRandom, state: MapState = null, utab: UnitTypeTable = null,
		turn: TurnState = null, shielded: bool = false) -> String:
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
		if shielded:
			unit.malfunction = MALFUNCTION_DAMAGED
			return OVERHEAT_DAMAGE
		var here: int = -1
		if state != null and state.in_bounds(unit.x, unit.y):
			here = state.index_of(unit.x, unit.y)
		if state != null and utab != null and turn != null:
			var _hero: bool = UnitState.remove(state, utab, turn, unit)
		else:
			unit.hp = 0
		# `0x0046D374`: the shield the carrier stood in goes with it -- the
		# object first, the two cell bytes only on the far side of a delete
		# that succeeded, as `interact.gd`'s mine arm has it.
		if here >= 0 and state.obstacle_at(here) == MapState.OBSTACLE_SHIELD:
			if CellObjects.delete_object(
					state, state.effect_at(MapState.OBJECT_SLOT, here)):
				state.set_obstacle(here, MapState.OBSTACLE_NONE)
				state.set_effect(MapState.TIMER_SLOT, here, 0)
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
## Returns `[x, y, marker]` triples in the order the handler writes them. The
## order decides the final marker on overlaps; resolution later walks CtrlMap
## row-major. All sixteen handlers are here since the third slice;
## `unsupported` is kept for the caller's sake and is now only ever filled by
## a weapon id above 47.
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
		if SPECIAL_OBJECTS.has(weapon_id) \
				and context.states.size() != state.cell_count():
			# The engine has no caller that reaches this handler without an
			# overlay on the map: the player's select and the computer's
			# fire both build one first. A caller here without one is
			# refused rather than handed the reset value, which would mark
			# nothing in silence.
			unsupported.append(
				"weapon %d reads the control map's state bytes -- the "
				% weapon_id + "target overlay of docs/23 section 6 -- and "
				+ "this shot was made without one")
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


## The eight neighbours of a cell, in a handler's own write order. These
## pattern handlers pass height `-1` to `aSetCellState`, so terrain does not
## clip the geometric weapon pattern.
static func _ring(state: MapState, x: int, y: int,
		order: Array[Vector2i],
		marker: int = MARKER_70) -> Array[PackedInt32Array]:
	var out: Array[PackedInt32Array] = []
	for step: Vector2i in order:
		var nx: int = x + step.x
		var ny: int = y + step.y
		if not state.in_bounds(nx, ny):
			continue
		out.append(PackedInt32Array([nx, ny, marker]))
	return out


## Secondary explosions pass the centre cell's actual height to
## `aSetCellState`; neighbours at a delta of 0x640 or more are refused.
static func _blast_ring(state: MapState, x: int, y: int,
		order: Array[Vector2i],
		marker: int = MARKER_70) -> Array[PackedInt32Array]:
	if not state.in_bounds(x, y):
		return []
	var source_height: int = state.height_at(state.index_of(x, y))
	var out: Array[PackedInt32Array] = []
	for cell: PackedInt32Array in _ring(state, x, y, order, marker):
		if absi(state.height_at(state.index_of(cell[0], cell[1])) \
				- source_height) < MARKER_HEIGHT_WINDOW:
			out.append(cell)
	return out


## Put marker writes into the same cell-indexed shape as CtrlMap. The original
## writer refuses a cell already in `0x50..0x5E`, so the first write wins; this
## is the crucial distinction from a queue when secondary rings overlap.
static func _write_markers(state: MapState, markers: PackedByteArray,
		cells: Array[PackedInt32Array]) -> void:
	for cell: PackedInt32Array in cells:
		if cell.size() < 3 or not state.in_bounds(cell[0], cell[1]):
			continue
		var index: int = state.index_of(cell[0], cell[1])
		if markers[index] >= MARKER_FULL \
				and markers[index] <= MARKER_SCRATCH_LAST:
			continue
		markers[index] = cell[2]


static func _marker_map(state: MapState,
		cells: Array[PackedInt32Array]) -> PackedByteArray:
	var markers: PackedByteArray = PackedByteArray()
	markers.resize(state.cell_count())
	markers.fill(0)
	_write_markers(state, markers, cells)
	return markers


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
## unit the shooter can **see**, weapon 11 a cell whose **state byte** is in
## the target overlay's band 30..34 ([member PatternContext.states]) and does
## not care what stands on it. Both then require the octant from the shooter
## to the cell to lie in the three-octant arc around the shooter's facing,
## and the cell to be within four fields of the aim point.
##
## Measured both ways in `blob_gold`: `shot_11` fires straight after a load
## and marks nothing, `shot_11_band` finds exactly the two cells whose state
## byte was written to 32, and `shot_11_overlay` finds exactly the two aliens
## `aBuildTargetOverlay` stamped itself.
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
		elif context.states[index] < SPECIAL_OBJECT_LOW \
				or context.states[index] > SPECIAL_OBJECT_HIGH:
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


## `0x0046F7E0` phase 0's `special` 1 arm -- **the bayonet**, docs/21 section 6.
##
## `aAttackUnit` calls the weapon-special dispatcher three times, and the
## phase is the argument: **0** before the shot (`0x0046B5C7`), **2** on each
## unit it hit (`0x0046BE1C`) and **1** at the very end (`0x0046C325`).  Phase
## 0 owns two arms, `special` 1 and `special` 2; this is the first.
##
## The swap is a write over the attacker's own weapon byte, so **everything
## downstream reads the bayonet row**: heat 255 disables the overheat roll,
## `hit` 100 and `range max` 1 make the chance flat, the damage is the
## bayonet's, and -- the reason a player notices at all -- `mun` 255 means the
## subtraction after the shot is skipped entirely.  Stabbing costs no
## ammunition because the weapon that fired had none to spend.
##
## Returns whether it swapped.  Four conditions, in the engine's own order:
## a unit is standing on the aim point at all (`test edi, edi` at
## `0x0046F9C5`), the weapon's `special` is 1, the distance is
## [constant CLOSE_COMBAT_DISTANCE] after a field is taken off for each large
## participant, and the two cells are within
## [constant CLOSE_COMBAT_HEIGHT_LEVELS] of each other.
static func close_combat_swap(state: MapState, utab: UnitTypeTable,
		wtab: WeaponTable, attacker: UnitState, target: UnitState) -> bool:
	if not close_combat_applies(state, utab, wtab, attacker, target):
		return false
	attacker.weapon = wtab.param(attacker.weapon)
	return true


## The swap's four conditions, without the write -- so a caller that only
## wants to know **which weapon a shot would be resolved with** can ask
## without moving anything ([method presented_weapon_for]).
static func close_combat_applies(state: MapState, utab: UnitTypeTable,
		wtab: WeaponTable, attacker: UnitState, target: UnitState) -> bool:
	if target == null:
		return false
	if wtab.special(attacker.weapon) != SPECIAL_CLOSE_COMBAT:
		return false
	if not state.in_bounds(attacker.x, attacker.y) \
			or not state.in_bounds(target.x, target.y):
		return false
	var fields: int = MoveMap.distance(attacker.x, attacker.y,
		target.x, target.y)
	if utab.unit_size(attacker.type_id) == UnitTypeTable.SIZE_LARGE:
		fields -= 1
	if utab.unit_size(target.type_id) == UnitTypeTable.SIZE_LARGE:
		fields -= 1
	if fields != CLOSE_COMBAT_DISTANCE:
		return false
	var drop: int = absi(state.height_at(state.index_of(attacker.x, attacker.y))
		- state.height_at(state.index_of(target.x, target.y)))
	return IncInt.div_trunc(drop, UnitTypeTable.HEIGHT_UNIT) \
		< CLOSE_COMBAT_HEIGHT_LEVELS


## The weapon `attacker` would resolve a shot at `(tx, ty)` with -- the bayonet
## when the swap of [method close_combat_swap] would fire, the held weapon
## otherwise -- **without changing anything**.
##
## It exists because the spend is the swapped weapon's: a rifle with an empty
## magazine still stabs, and its `param`'s `mun` of 255 means the subtraction
## never runs. A caller that gates a shot on ammunition has to ask about this
## weapon and not about the one on the record, or it refuses the one shot the
## unit could still make ([method World.submit_attack]).
static func presented_weapon_for(state: MapState, units: Dictionary,
		utab: UnitTypeTable, wtab: WeaponTable, attacker: UnitState,
		tx: int, ty: int, reaction: bool = false) -> int:
	if reaction:
		return attacker.weapon
	var standing: UnitState = _unit_on(state, units, tx, ty)
	if not close_combat_applies(state, utab, wtab, attacker, standing):
		return attacker.weapon
	return wtab.param(attacker.weapon)


## `0x0046F7E0` phase 1's `special` 1 arm -- back to the gun.
##
## It runs at `0x0046C325`, **after** the ammunition subtraction of
## docs/22 section 7.5 and before the hatch sweep, so the round the bayonet
## did not spend is already not spent by the time the rifle comes back.  Both
## halves are gated on the same thing the swap is: a shot marked a reaction
## reaches neither (`0x0046B592` and `0x0046C319` read `aAttackUnit`'s fifth
## argument and jump past the call).
static func close_combat_revert(wtab: WeaponTable,
		attacker: UnitState) -> bool:
	if wtab.special(attacker.weapon) != SPECIAL_CLOSE_COMBAT:
		return false
	if not CLOSE_COMBAT_WEAPONS.has(attacker.weapon):
		return false
	attacker.weapon = wtab.param(attacker.weapon)
	return true


## `aAttackUnit` `0x0046B450` -- docs/22 section 7, in the order it runs.
## `reaction` is `aAttackUnit`'s fifth argument, the one
## [method Reaction.drain] passes as 1: it gates the two close-combat arms and
## nothing else here.
static func attack(state: MapState, units: Dictionary, utab: UnitTypeTable,
		wtab: WeaponTable, x: int, y: int, tx: int, ty: int, ai_level: int,
		human_players: int, game_mode: int, turn: TurnState,
		rng: IncRandom, reaction: bool = false,
		cheats: Cheats = null,
		states: PackedByteArray = PackedByteArray()) -> AttackResult:
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
	# `0x0046B5C7` -- the weapon-special dispatcher's **phase 0**, before the
	# weapon is even checked for damage: a `special` 1 gun standing next to
	# what it is aiming at becomes its bayonet for the length of the shot
	# ([method close_combat_swap]).  A reaction skips it -- `0x0046B592` reads
	# the fifth argument and jumps straight to the heat cap.
	if not reaction:
		var _bayonet: bool = close_combat_swap(state, utab, wtab, attacker,
			standing)
	# `0x0046B588` -- the pool at entry, for the skill-orbit compare.
	var tp_before: int = attacker.tp
	# `0x0046B5DF` -- weapon 47 is set **to its heat cap** before the overheat
	# check, inside the same `maxHeat != 255` gate: every shot of it rolls
	# `aRandom(0, 40)`, and 15 of the 40 outcomes damage the weapon before it
	# fires. Measured in `turn_gold.py`'s `weapon47` probe.
	if attacker.weapon == CONVERTER_WEAPON:
		var cap: int = max_heat(wtab, attacker)
		if cap != 0xFF:
			attacker.heat = cap
	# **The armed cheat is read once, here**, and the same answer is used for
	# the spend below: a bayonet swap changes the weapon between the two, never
	# the shooter, so asking twice could not disagree -- but reading it once
	# says so.
	var free_shot: bool = Cheats.armed(cheats, attacker, turn)
	if free_shot:
		# `aCheckWeaponDamage` is what jams the gun, destroys it and, on a roll
		# of exactly 30, kills the shooter. Infinite ammunition that still let
		# the gun blow up in the tester's hand would be the wrong switch.
		attacker.malfunction = 0
	else:
		# The roll of exactly 30 takes the shooter off the map, and a
		# shielded marine may not be killed by its own gun: the cheat is
		# decided inside the routine, before the removal it would otherwise
		# have to undo.
		result.overheat = check_weapon_damage(wtab, attacker, rng, state,
			utab, turn, Cheats.shielded(cheats, attacker, turn))
	if attacker.malfunction != 0 or attacker.hp == 0:
		result.fired = false
		result.reason = ("the weapon jammed or was destroyed"
			if attacker.malfunction != 0 else "the attacker is dead")
		return result
	# `0x0046B643` -- the shooter is marked visible the moment its weapon is
	# cleared to fire, before it turns to face the target.
	Visibility.set_state(attacker, Visibility.FULL)

	attacker.facing = direction(x, y, tx, ty)
	result.facing = attacker.facing
	var unsupported: Array[String] = []
	# `states` is the control map's state bytes as the caller's own overlay
	# left them -- what weapon 11's handler reads ([constant
	# SPECIAL_OBJECTS]); every other family ignores it.
	result.marked = mark_cells(state, units, attacker.weapon, tx, ty,
		unsupported, PatternContext.create(attacker, utab, wtab, rng,
			human_players, game_mode, states))
	if not unsupported.is_empty():
		result.fired = false
		result.reason = unsupported[0]
		return result

	var banner: bool = banner_nearby(attacker, units)
	# `result.marked` remains the weapon's raw target array for inspection.
	# Resolution is over CtrlMap: first writes win, the map is swept row-major,
	# and a secondary explosion requests another complete pass. Presentation
	# reconstructs the final CtrlMap order from `outcomes`.
	var markers: PackedByteArray = _marker_map(state, result.marked)
	var repeat_sweep: bool = false
	var marker_index: int = 0
	while marker_index < markers.size() or repeat_sweep:
		if marker_index >= markers.size():
			marker_index = 0
			repeat_sweep = false
		var index: int = marker_index
		marker_index += 1
		var marker: int = markers[index]
		if marker < MARKER_FULL or marker > MARKER_INPUT_LAST:
			continue
		var cx: int = index % state.width
		var cy: int = index / state.width
		var target: UnitState = _unit_on(state, units, cx, cy)
		if target == null:
			continue
		# `0x0046BA22` -- every unit on a marked cell is marked visible before
		# its roll, whether the shot then hits or misses.
		Visibility.set_state(target, Visibility.FULL)
		if state.obstacle_at(state.index_of(cx, cy)) == EFFECT_SHIELDED:
			markers[index] = MARKER_RESOLVED
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
		if target.type_id == BEACOO_TYPE \
				and wtab.type_of(attacker.weapon) == BEACOO_WEAPON_TYPE:
			damage = BEACOO_DAMAGE
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
		var target_special: int = utab.special(target.type_id)
		if damage > 0 and GUARANTEED_HIT_SPECIALS.has(target_special):
			chance = 0
			roll = 1
			damage = GUARANTEED_HIT_DAMAGE
			if target_special == SPECIAL_EXPLODES_ON_HIT:
				# `0x0046BC59`..`0x0046BCF6`: the same unrolled order as
				# `aim_and_neighbours`, but marker `0x53` -- flat damage 100.
				_write_markers(state, markers, _blast_ring(state, cx, cy,
					AIM_NEIGHBOUR_ORDER, MARKER_FLAT_100))
				repeat_sweep = true
		# The same override, for the same reason: the comparison is replaced
		# and the generator is not, so the roll above has already been drawn.
		# **A unit the other switch shields is never the one killed**, so the
		# two switches held together do not make friendly fire lethal.
		var one_shot: bool = Cheats.lethal(cheats, attacker, turn) \
			and not Cheats.controlled(target, turn)
		if one_shot:
			chance = 0
			roll = 1

		if chance + HIT_BONUS < roll:
			markers[index] = MARKER_MISS
			result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
				"marker": MARKER_MISS, "dealt": 0, "chance": chance,
				"roll": roll})
			continue

		if marker == MARKER_STUN:
			# No damage is rolled; unless a Damage Absorber charge is spent the
			# target loses the rest of its turn.
			# A shielded target is not stunned either -- a marine that cannot
			# be hurt but can still be frozen for a turn is not what the
			# switch says -- and it does not pay a Damage Absorber charge for
			# the immunity it already has, which is why the shield is tested
			# first and `and` short-circuits the spend away.
			var shielded: bool = Cheats.shielded(cheats, target, turn)
			var stunned: bool = not shielded \
				and absorber_charges(target) == 0
			if not shielded and not spend_absorber(target):
				target.action_state = STUNNED_ACTION_STATE
				target.mp = 0
			markers[index] = MARKER_RESOLVED
			result.outcomes.append({"slot": target.slot, "x": cx, "y": cy,
				"marker": MARKER_RESOLVED, "dealt": 0, "chance": chance,
				"roll": roll, "stunned": stunned})
			continue

		if spend_absorber(target):
			# docs/22 section 7.5: a charge nullifies the damage -- behind
			# `0x00475590`'s equipment gate, like the charge count -- by
			# **zeroing the argument**, not by skipping the call: `xor ebp, ebp`
			# at `0x0046BD83` and `applyDamage` still runs at `0x0046BD9D`,
			# rolling its dice over a span of nothing. The seed says so
			# (`turn_gold.py`, `absorber_flagged`: two draws, not one).
			damage = 0
		# **The shield is the absorber's own mechanism, borrowed.** Zeroing the
		# argument rather than skipping the call keeps the draw order -- and
		# therefore the generator -- exactly where it would have been, so a
		# world played with the switch on is still a world whose picture and
		# truth agree. `applyDamage` over a span of nothing deals nothing:
		# every roll it makes is `draw(0, 0)` or `draw(0, 1)`, and
		# [method IncRandom.draw] truncates both to zero.
		if Cheats.shielded(cheats, target, turn):
			damage = 0
		var dealt: int = apply_damage(target, damage, attacker.facing, ai_level,
			human_players, game_mode, rng)
		# The other half of the pair: what the armour roll left standing is
		# taken off after it, so `dealt` is the whole of the target's health
		# and the picture's damage number is the truth. It is written here
		# rather than as `damage = 255` because `applyDamage` subtracts armour
		# from any damage at all and refuses [constant IMMUNE_UNIT_TYPE]
		# outright -- neither of which a one-shot kill may be stopped by.
		if one_shot and target.is_alive():
			dealt += target.hp
			target.hp = 0
		# `0x0046BDAD` -- weapon 47 converts what it hits and does not kill.
		# The charge test is asked **again** after the spend, so a target whose
		# last charge just went is converted on the same shot.
		var converted: bool = (attacker.weapon == CONVERTER_WEAPON
			and absorber_charges(target) == 0 and target.is_alive())
		if converted:
			var _saw: bool = convert_unit(state, units, utab, target,
				attacker.player, ai_level, human_players, game_mode)
		var killed: bool = not target.is_alive()
		if killed and target_special == SPECIAL_EXPLODES_ON_DEATH:
			# `0x0046BE4F`..`0x0046BF2F`: unlike a barrel this ring is
			# written only after `applyDamage` left the carrier at zero HP.
			_write_markers(state, markers, _blast_ring(state, cx, cy,
				AIM_NEIGHBOUR_ORDER, MARKER_FLAT_100))
			repeat_sweep = true
		if killed:
			# `0x0046BF84`..`0x0046BF93`: the shooter's kill and the victim's
			# "lost to an enemy", both **only** when the two players differ.
			# The engine calls them before `aKillUnit`; the order does not
			# matter here because neither reads the other's counter.
			turn.count_kill_and_loss(attacker.player, target.type_id,
				target.player)
			# `aKillUnit` (`0x00472920`) is two calls: the death sequence and
			# `aRemoveUnitElement`, which is where the hero counter lives.
			UnitState.remove(state, utab, turn, target)
			# `0x0046BF47` -- `test ebp, ebp / jle`: the award is gated on the
			# damage **argument** (what `applyDamage` was handed, zero after
			# an absorber charge), not on what was dealt.
			if damage > 0:
				result.xp += award_kill(utab, attacker, target, game_mode,
					ai_level)
		var outcome: Dictionary = {"slot": target.slot, "x": cx, "y": cy,
			"marker": MARKER_KILLED if killed else MARKER_HIT, "dealt": dealt,
			"chance": chance, "roll": roll}
		markers[index] = DictRead.as_int(outcome["marker"])
		if converted:
			outcome["converted"] = true
		result.outcomes.append(outcome)

	# `0x0046C186` -- **the fight animation runs here, inside `aAttackUnit`**,
	# between the swap and the revert below, so the byte it selects the clip,
	# the wave and the muzzle from is the one the unit holds *now*: the
	# bayonet after a swap, the gun otherwise.  Recorded rather than played:
	# `core` decides and `game` draws (docs/92 section 5.1), and the picture
	# reads this off the result.  It is taken here and not next to the swap
	# because this is where the engine takes it.
	result.presented_weapon = attacker.weapon

	# After the shot: ammunition and heat.  docs/22 section 7.5 gates on
	# **both** halves -- a weapon whose `mun` column is 255 spends nothing, and
	# neither does unit type 0x42.  Dropping the second would disarm that type.
	if wtab.has(attacker.weapon) and not free_shot:
		if (wtab.magazine(attacker.weapon) != MUN_NONE
				and attacker.type_id != NO_AMMO_UNIT_TYPE):
			# `0x0046C308` is an 8-bit `sub` with no clamp, so the engine
			# wraps rather than refusing; the check is every caller's. This
			# keeps the signed value for the same reason
			# `inclib.combat.attack_unit` does -- past zero is visible as a
			# negative rather than as 250-something -- and no caller reaches
			# it: `AIOverlay.effective_weapon` gates the computer and
			# [method World.submit_attack] the player.
			attacker.ammo -= wtab.mun_per_fight(attacker.weapon)
		var cap: int = max_heat(wtab, attacker)
		if cap != HEAT_NONE and attacker.heat < cap:
			attacker.heat += 1

	# `0x0046C325` -- the dispatcher's **phase 1**, and the other half of the
	# bayonet: the gun comes back the moment the shot is paid for.  What is
	# below this line -- the impact placer and the hatch sweep -- therefore
	# sees the **gun** on the record, which is why the placer above is handed
	# [member AttackResult.presented_weapon] and not `attacker.weapon`.
	# `aPlayFightAnimation` is **not** below it: it ran at `0x0046C186`, three
	# instructions' worth of stages earlier, and every switch it dispatches on
	# a weapon id took the **bayonet's** arm.  *(Corrected 2026-09-09: this
	# said the animation runs after the routine returns.  It does not -- the
	# call is inside, and `W_BAYO_0` and `P0_F1_001` are what the original
	# plays for a stab.)*
	if not reaction:
		var _gun: bool = close_combat_revert(wtab, attacker)

	# `0x0046C216` -- after the animation: the skill orbit's argument.
	# **The impact arm lays a transient object for three weapons** (docs/42
	# section 9.1): 40 burns nine cells, 42 lays a mine, 43 a shield.
	# `aPlayFightAnimation`'s impact switch dispatches on the shooter's weapon
	# **whether the shot hit or missed**, and on the target cell after the
	# standing-unit adjustment above -- so this is a consequence of firing
	# rather than of connecting.  It runs before the hatch sweep below, which
	# is the order the animation has them in.
	# The cells it changed are not on the result: `AttackResult.to_dict()`'s
	# shape is pinned to the Python twin's, and the picture reads the terrain
	# diff for this (docs/42 section 9.1) rather than a second channel.
	#
	# **The weapon is the presented one.**  This stage and the hatch sweep
	# below are the animation's, and the animation ran at `0x0046C186` with
	# the record still holding the bayonet -- so they read the byte from
	# there, not off the reverted record.  They are left standing after the
	# revert because nothing between the two positions changes what they read:
	# neither reads ammunition or heat, and no shipped weapon makes the two
	# readings disagree -- 40, 42 and 43 are the placer's ids and none of them
	# is a `special` 1 gun, and the hatch gate takes weapon `type` 1 and 4
	# alike, which is the gun's and the bayonet's.
	var _placed: PackedInt32Array = CellObjects.place_impact(
		state, result.presented_weapon, tx, ty)
	result.skill_raised = skill_levels_raised(utab, attacker, tp_before)

	# **`aPlayFightAnimation` is not only an animation.**  `0x0040BD70` -- which
	# `aAttackUnit` calls at `0x0046C186`, before the subtraction above and not
	# after the routine returns -- sweeps the whole cell array and calls the
	# effect dispatcher `0x0046F210` with phase 4 for every cell whose marker
	# byte is `0x5C` -- hit, and not `0x5D`, killed.  Only `special` 9 has a
	# `case 4`, so that sweep is [method hatch] and nothing else; the sweep
	# order is the cell array's, which is the order the outcomes were appended
	# in.
	for outcome: Dictionary in result.outcomes:
		if DictRead.as_int(outcome["marker"]) != MARKER_HIT:
			continue
		var slot: int = DictRead.as_int(outcome["slot"])
		if not units.has(slot):
			continue
		var carrier: UnitState = units[slot]
		if not carrier.is_alive():
			# The engine reads the cell's **current** occupant, so a second
			# marked cell naming a carrier that already hatched finds the
			# replacement -- `special` 0 -- and does nothing.
			continue
		var made: int = hatch(state, units, utab, wtab, carrier, attacker,
			human_players, game_mode, turn, result.presented_weapon)
		if made >= 0:
			outcome["hatched"] = made
	return result


## `0x0047AFD0(unit, exp)` -- the gain one kill is worth, as the float the
## routine leaves in `st(0)`.
##
## In the campaign it is the victim type's `exp` byte. In a session the
## difficulty picks a multiplier `m` and the attacker's own experience `e`
## bends it: below 72 the gain is `(m - m*e/72) * exp`, from 72 to 108 it is
## `exp`, and above 108 it is half -- or **nothing** when the byte is exactly
## 1 (`cmp cl, 1` at `0x0047B06C` reads the argument's low byte, not the unit).
static func experience_gain(attacker: UnitState, exp: int, game_mode: int,
		ai_level: int) -> float:
	exp = exp & 0xFF
	if game_mode == GAME_MODE_CAMPAIGN:
		return float(exp)
	var m: int = DictRead.as_int(DIFFICULTY_MULTIPLIER.get(ai_level,
		DIFFICULTY_MULTIPLIER_DEFAULT))
	var e: int = attacker.ep
	if e < EXPERIENCE_LOW:
		# `imul ecx, eax` then the reciprocal divide; `m * e` is small and
		# non-negative, so truncation and floor agree.
		return float(m - (m * e) / EXPERIENCE_DIVISOR) * float(exp)
	if e > EXPERIENCE_HIGH:
		return 0.0 if exp == 1 else float(exp) * EXPERIENCE_HALF
	return float(exp)


## `0x0047B090(unit, exp)` -- the skill-point pool, `+0x18`.
##
## Skipped entirely when `ep + gain` would reach 144 (`0x0047B0B2`);
## otherwise the pool takes the gain and is capped at 144. It is called
## **before** `+0x17` moves, so the gate reads the pre-award experience.
static func award_training(attacker: UnitState, exp: int, game_mode: int,
		ai_level: int) -> void:
	var gain: float = experience_gain(attacker, exp, game_mode, ai_level)
	if float(attacker.ep) + gain >= float(EXPERIENCE_CAP):
		return
	var total: float = gain + float(attacker.tp)
	# `_ftol` truncates toward zero, which is what `int()` does.
	attacker.tp = EXPERIENCE_CAP if total >= float(EXPERIENCE_CAP) \
		else int(total)


## `0x0047B100(unit, exp)` -- experience, `+0x17`, capped at 144.
static func award_experience(attacker: UnitState, exp: int, game_mode: int,
		ai_level: int) -> void:
	var total: float = experience_gain(attacker, exp, game_mode, ai_level) \
		+ float(attacker.ep)
	attacker.ep = EXPERIENCE_CAP if total >= float(EXPERIENCE_CAP) \
		else int(total)


## `0x0047AF90(unit, n)` -- `+0x53` plus `n`, saturating at 255.
static func count_kill(attacker: UnitState, count: int = 1) -> void:
	var total: int = (attacker.kills & 0xFF) + (count & 0xFF)
	attacker.kills = KILL_COUNT_CAP if total > KILL_COUNT_CAP else total


## The kill block of `aAttackUnit` at `0x0046BF53`..`0x0046C004`.
##
## Nothing for a species-2 victim, nothing for one of the attacker's own
## player; otherwise the gain is truncated into the shot's total, both bytes
## are awarded and the kill is counted. Returns what the total grew by.
##
## The three player-record counters the block also moves (`0x0043B8D0`,
## `0x0043B860`, `0x0043B810`) are the debriefing's statistics, so they are
## [TurnState]'s rather than this function's: the sixth slice wired the kill
## pair at the call site that resolves the shot and `0x0043B8D0` into
## [method UnitState.remove], which is the one death path every killer reaches.
static func award_kill(utab: UnitTypeTable, attacker: UnitState,
		victim: UnitState, game_mode: int, ai_level: int) -> int:
	if utab.species(victim.type_id) == SPECIES_OBJECT:
		return 0
	if victim.player == attacker.player:
		return 0
	var exp: int = utab.exp(victim.type_id)
	var gained: int = int(experience_gain(attacker, exp, game_mode, ai_level))
	award_training(attacker, exp, game_mode, ai_level)
	award_experience(attacker, exp, game_mode, ai_level)
	count_kill(attacker)
	return gained


## `0x0046C216`..`0x0046C283` -- whether the skill orbit plays.
##
## The attacker must still be alive, its pool's level (`+0x18 / 12`) must
## have risen over the value saved at entry, and its species must be 0 --
## then `0x00410190` is called with the difference. Zero otherwise.
static func skill_levels_raised(utab: UnitTypeTable, attacker: UnitState,
		tp_before: int) -> int:
	if not attacker.is_alive():
		return 0
	var before: int = tp_before / POINTS_PER_SKILL_LEVEL
	var after: int = attacker.tp / POINTS_PER_SKILL_LEVEL
	if after <= before:
		return 0
	if utab.species(attacker.type_id) != SPECIES_HUMAN:
		return 0
	return after - before


## `0x0046F210` `case 4` with `special == 9` -- see [constant SPECIAL_HATCH].
##
## Returns the slot of the unit that hatched, or -1 when the arm did not fire.
##
## Three things are the engine's own and each would be easy to "fix":
##
## * the carrier is **removed**, not killed -- `aRemoveUnitElement`
##   (`0x004779C0`) frees its record and clears the cell -- so its slot is free
##   again and the replacement usually takes it;
## * `aGenerateUnitElement` is called with its `exact` flag **set**
##   (`push 1` at `0x0046F32B`), so the replacement never searches a
##   neighbouring cell the way an `InsertUnit` would;
## * the fog rebuild is `aBuildVisibleMap(g_currentPlayer)` and is **not**
##   bracketed by the save/restore pair, so unlike the per-command probe of
##   docs/22 section 9.4 it changes what the rules see, not only the picture.
##
## The carrier goes through [method UnitState.remove], so the hero counter
## `aRemoveUnitElement` keeps at `+0x24` moves here too -- a `Squee'Coo` marked
## as a hero would be counted, which is what the engine does and not a rule
## invented for this arm.
## `weapon` is the byte the animation dispatches on, which after a close-combat
## swap is the bayonet and not what the record holds by the time this runs
## ([member AttackResult.presented_weapon]).  Left optional because the
## attacker's own weapon is the answer for every caller that has not swapped.
static func hatch(state: MapState, units: Dictionary, utab: UnitTypeTable,
		wtab: WeaponTable, target: UnitState, attacker: UnitState,
		human_players: int, game_mode: int, turn: TurnState,
		weapon: int = -1) -> int:
	if weapon < 0:
		weapon = attacker.weapon
	if utab.special(target.type_id) != SPECIAL_HATCH:
		return -1
	if target.hp > HATCH_HP_LIMIT:
		return -1
	if not HATCH_WEAPON_TYPES.has(wtab.type_of(weapon)):
		return -1
	var x: int = target.x
	var y: int = target.y
	var group: int = target.group
	# `remove` is what zeroes the hit points -- `0x00477ABD`.
	UnitState.remove(state, utab, turn, target)
	var made: UnitState = UnitState.generate(state, units, utab, HATCH_PLAYER,
		HATCH_TYPE, "", 0, 0, x, y, true)
	if made == null:
		return -1
	made.group = group
	Visibility.build(state, units, utab, turn.current_player, human_players,
		game_mode)
	return made.slot


static func _unit_on(state: MapState, units: Dictionary, x: int,
		y: int) -> UnitState:
	if not state.in_bounds(x, y):
		return null
	var slot: int = state.unit_at(state.index_of(x, y))
	if slot < 0 or not units.has(slot):
		return null
	var unit: UnitState = units[slot]
	return unit if unit.is_alive() else null
