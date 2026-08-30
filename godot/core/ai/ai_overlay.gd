class_name AIOverlay
extends RefCounted

## `0x0042FF30`, `0x0042FE90` and `0x0042EE90` -- how the computer decides
## *what* to shoot, and it is a single number per cell (docs/23 section 6).
##
## For every enemy the acting unit could engage, the full `aGetHitProbability`
## chain runs and the target's cell is stamped with a **band** of the
## resulting percentage. Because the fire routine then picks the numerically
## largest marker, **the AI always shoots at its highest hit chance**, with no
## weighting for the target's health, threat or value.

## docs/23 section 10 -- the overlay values this file writes and reads.
const STATE_RESET: int = 1
const MARKER_MIN: int = 30
const MARKER_MAX: int = 34
const MARKER_TOP: int = 34
## The thresholds, written out the way the engine writes its comparisons.
const BAND_LIMITS: Array[int] = [20, 50, 70, 90]
const BAND_MARKERS: Array[int] = [30, 31, 32, 33]

## The three markers `0x0042FF30`'s other arms write. The fire routine's
## `30 <= s <= 34` window never selects them, so a unit whose weapon reaches
## one of those arms can never find an AI target. Named so that fact reads as
## a property of this table rather than as an omission.
const MARKER_SPECIAL_OBJECT: int = 35
const MARKER_EMPTY_GROUND: int = 36
const MARKER_ANY_UNIT: int = 37

## `0x004303A8` -- which arm each weapon id reaches, indexed by weapon id.
const FAMILY: Array[int] = [
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	10, 10, 1, 1, 1, 1, 1, 1, 1, 1, 10, 2, 2, 2, 2,
	10, 10, 10, 10, 10, 10, 10, 3, 4, 5, 6, 7, 7, 8, 9,
]
## `0x0040437C` -- what each family does. `units` is the hit-probability sweep;
## the other three stamp markers outside the AI's window, and `error` is the
## "unknown weapon" arm, which also returns TRUE.
const ARMS: Array[String] = ["units", "units", "units", "special_objects",
	"units", "empty_ground", "any_unit", "units", "empty_ground", "units",
	"error"]

## The first gate: a unit this tired stamps nothing at all.
const MIN_FITNESS: int = 1
## The id the routine returns TRUE on before it dispatches -- "No Weapon".
const WEAPON_NONE: int = 28
## docs/21 section 5 -- the species the prune pass clears markers for.
const SPECIES_OBJECT: int = 2
## docs/22 section 9.1 -- only a fully visible target is ever stamped.
const VISIBILITY_VISIBLE: int = 0
## The two unit types the sweep refuses to aim at outright.
const TYPE_NEVER_TARGET: int = 0x3D
const TYPE_IMMUNE: int = 0x23
## `weapon[+0x39]` -- a magazine of this size never consumes ammunition.
const MUN_NONE: int = 0xFF
## `weapon[+0x3B]` -- 1 means "fall back to `param` when jammed or empty",
## 6 means "aim at where the target stood when the turn began".
const SPECIAL_FALLBACK: int = 1
const SPECIAL_LAST_TURN_CELL: int = 6
## The two weapon ids whose own arm overrides the chance with 255, which the
## `>= 254` refusal below then drops.
const WEAPON_LASER_ENHANCED: int = 47
const WEAPON_SHOCK: int = 45
const CHANCE_REFUSED: int = 254


## Which arm of `0x0042FF30` a weapon id reaches.
static func arm_of(weapon_id: int) -> String:
	if weapon_id < 0 or weapon_id >= FAMILY.size():
		return "error"
	return ARMS[FAMILY[weapon_id]]


## The weapon the sweep aims with, or -1 when it refuses outright.
##
## A jammed or empty weapon whose `special` column is 1 falls back to its
## `param` id; one without does not aim at all. The **dispatch** still uses
## the unit's original weapon -- `edx` is loaded before the substitution and
## never reloaded -- so this returns the aiming weapon and the caller keeps the
## original for [method arm_of].
static func effective_weapon(wtab: WeaponTable, unit: UnitState) -> int:
	if not wtab.has(unit.weapon):
		return -1
	var weapon_id: int = unit.weapon
	if unit.malfunction != 0 or unit.ammo == 0:
		if wtab.special(unit.weapon) != SPECIAL_FALLBACK:
			return -1
		weapon_id = wtab.param(unit.weapon)
	if not wtab.has(weapon_id):
		return -1
	if unit.mp < wtab.ap(weapon_id):
		return -1
	if wtab.magazine(weapon_id) != MUN_NONE \
			and unit.ammo < wtab.mun_per_fight(weapon_id):
		return -1
	return weapon_id


## `0x0042FF30` -- stamp every reachable enemy with its hit-chance band.
##
## Returns the routine's own answer. FALSE means "this unit cannot aim at
## all"; TRUE with nothing stamped means "it can aim and found nobody", and to
## the caller the two differ only through the overlay.
static func build(ctx: AIContext, unit: UnitState, human_players: int,
		game_mode: int) -> bool:
	if unit.fp <= MIN_FITNESS:
		return false
	if unit.weapon == WEAPON_NONE:
		# The routine returns TRUE here without dispatching, so "No Weapon"
		# stamps nothing and is not an error.
		return true
	var weapon_id: int = effective_weapon(ctx.wtab, unit)
	if weapon_id < 0:
		return false
	var arm: String = arm_of(unit.weapon)
	if arm != "units":
		ctx.refuse("overlay arm '%s' stamps no AI target band" % arm)
		return true

	for slot: int in range(AISystem.UNIT_SLOTS):
		var other: UnitState = ctx.unit_or_null(slot)
		if other == null or other.hp == 0:
			continue
		if slot == unit.slot:
			continue
		if other.player == unit.player:
			continue
		# `0x0043B1F0` gates the "both players are human" skip that follows it
		# in the engine. It is the network-game test (docs/25 section 3.1),
		# false in the campaign, so that skip never fires here.
		if not _special_hook_allows(ctx, unit):
			continue
		if other.visibility != VISIBILITY_VISIBLE:
			continue
		if other.type_id == TYPE_NEVER_TARGET or other.type_id == TYPE_IMMUNE:
			continue
		var chance: HitChance = HitChance.compute(ctx.map, ctx.units, ctx.utab,
			ctx.wtab, unit, other, weapon_id, true, human_players, game_mode)
		if not chance.in_range:
			continue
		var percent: int = _overrides(ctx, unit, other, chance.percent)
		if percent <= 0 or percent >= CHANCE_REFUSED:
			continue
		var tx: int = other.x
		var ty: int = other.y
		# The **original** weapon's `special`, not the substituted one's:
		# `0x004302A8` indexes the table with the byte reloaded from
		# `u->+0x3F` and never from the fallback.
		if ctx.wtab.special(unit.weapon) == SPECIAL_LAST_TURN_CELL:
			tx = other.turn_start_x
			ty = other.turn_start_y
		ctx.write_marker(tx, ty, band_of(percent))
	return true


static func band_of(percent: int) -> int:
	for i: int in range(BAND_LIMITS.size()):
		if percent <= BAND_LIMITS[i]:
			return BAND_MARKERS[i]
	return MARKER_TOP


## `0x0046F210(u, o, 2)` -- docs/21 section 5's `special` dispatcher.
##
## The switch keys on the **aiming** unit's type, and phase 2's arm handles
## exactly one value: `special` 4, "may attack only while its per-turn counter
## is 2 or less". Every other value -- 0 included, which returns before the
## switch -- lands on the default, and the default returns TRUE.
##
## No shipped `SetUnitInfo` line carries 4. The gate exists so the omission has
## a name rather than being invisible.
static func _special_hook_allows(ctx: AIContext, unit: UnitState) -> bool:
	if ctx.utab.special(unit.type_id) != 4:
		return true
	ctx.refuse("special 4 gates the target overlay; unshipped")
	return true


## `0x0043021B` and `0x00430257` -- the two weapon ids with an override.
##
## 255 is above the `>= 254` refusal, so the effect is that those weapons find
## a target only where the override does *not* fire.
static func _overrides(ctx: AIContext, unit: UnitState, other: UnitState,
		percent: int) -> int:
	if unit.weapon == WEAPON_LASER_ENHANCED:
		if other.hp >= 4:
			return 255
		if ctx.utab.unit_size(other.type_id) == UnitTypeTable.SIZE_LARGE:
			return 255
		if ctx.utab.species(other.type_id) == SPECIES_OBJECT:
			return 255
	if unit.weapon == WEAPON_SHOCK \
			and ctx.utab.species(other.type_id) == 3:
		return 255
	return percent


## `0x0042FE90(keep)` -- drop the markers standing on inanimate objects.
##
## The AI always passes 0, so a barrel never becomes a target. The argument is
## kept because the routine has one, and because "the AI passes 0" is a fact
## about the call site rather than about the routine.
static func prune(ctx: AIContext, keep: bool = false) -> void:
	if keep:
		return
	for i: int in range(ctx.state.size()):
		var marker: int = ctx.state[i]
		if marker < MARKER_MIN or marker > MARKER_MAX:
			continue
		var target: UnitState = ctx.unit_on_index(i)
		if target == null:
			continue
		if ctx.utab.species(target.type_id) == SPECIES_OBJECT:
			ctx.state[i] = STATE_RESET
