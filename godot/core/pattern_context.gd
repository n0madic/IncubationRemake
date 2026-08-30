class_name PatternContext
extends RefCounted

## The last three arguments of `0x0046AA10` plus what they need to be used.
##
## The dispatcher takes six arguments, not three: `(weapon, aimX, aimY,
## shooterX, shooterY, shooterFacing)`. Nine of the sixteen families read none
## of the last three; the other six read the shooter's cell, its facing, or
## both, and two of them go on to call `aGetHitProbability` and
## `aCheckLineOfSightEx`, which need the tables. Rather than growing
## [method Combat.mark_cells] six more parameters, they travel together as one
## value -- and a family that needs it and does not get it marks nothing and
## says why.
##
## `aExecuteBomb` (`0x00470318`) passes one value for all three because weapon
## 36 reads none of them, so a bomb passes no context at all.

var shooter: UnitState = null
var utab: UnitTypeTable = null
var wtab: WeaponTable = null
var rng: IncRandom = null
var human_players: int = 1
var game_mode: int = 1


static func create(unit: UnitState, types: UnitTypeTable,
		weapons: WeaponTable, generator: IncRandom = null,
		humans: int = 1, mode: int = 1) -> PatternContext:
	var out: PatternContext = PatternContext.new()
	out.shooter = unit
	out.utab = types
	out.wtab = weapons
	out.rng = generator
	out.human_players = humans
	out.game_mode = mode
	return out
