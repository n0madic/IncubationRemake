class_name ExecuteWarp
extends RefCounted

## `aExecuteWarp(sx, sy, tx, ty, animate)` `0x0046EF50`, reduced to its
## state -- the same reduction [AIPlan.execute_warp] makes for the computer,
## here for the player's own jump (docs/97 section 31).
##
## The routine clears the source cell's unit id, writes the mover's into the
## target's, moves the record, **detonates a mine under the landing**
## (`0x0046F088`..`0x0046F109`) and then rebuilds the fog for the mover's
## **own** player (`0x0046F144`, docs/22 section 9.4) -- gated, like everything
## after it, on the mover still being alive (`0x0046F133` reads `+0x16`).
##
## The mine arm used to be named here and not simulated, because no shipped
## cell carries one. That stopped being the whole story when the placers of
## docs/42 section 9.1 went in: a mine is made during play, and this carries
## the same `aDeleteSpecialObject` guard the walk and the push do.
##
## The jump animation and the `MoveUnit` script call are the caller's: `game`
## draws the first, [World] fires the second.


## Answers `{ok, reason}`. Nothing is changed on a refusal.
static func execute(state: MapState, units: Dictionary, utab: UnitTypeTable,
		wtab: WeaponTable, unit: UnitState, tx: int, ty: int,
		human_players: int, game_mode: int, ai_level: int, turn: TurnState,
		rng: IncRandom, journal: EventJournal = null) -> Dictionary:
	var source: int = state.index_of(unit.x, unit.y)
	if state.unit_at(source) != unit.slot:
		# "no unit on start path field" -- the routine's own refusal.
		return {"ok": false, "reason": "no unit on start path field"}
	if not state.in_bounds(tx, ty):
		return {"ok": false, "reason": "the target is off the map"}
	var target: int = state.index_of(tx, ty)
	state.set_unit(source, MapState.NO_UNIT)
	state.set_unit(target, unit.slot)
	var from_x: int = unit.x
	var from_y: int = unit.y
	unit.x = tx
	unit.y = ty
	# **The landing is a boundary.** The engine's jump sequence puts the body
	# down before the mine under it goes off (`0x0046F088` follows the
	# relink), so the picture must be able to show the same two moments.
	if journal != null:
		var _landed: Dictionary = journal.mark("warp", unit.slot, from_x,
			from_y, tx, ty, 0, "", {})
	var blast: Dictionary = {}
	if state.obstacle_at(target) == MapState.OBSTACLE_MINE \
			and CellObjects.delete_object(
				state, state.effect_at(MapState.OBJECT_SLOT, target)):
		state.set_effect(MapState.OBJECT_SLOT, target, MapState.NO_OBJECT)
		state.set_obstacle(target, MapState.OBSTACLE_NONE)
		state.set_effect(MapState.TIMER_SLOT, target, 0)
		blast = Interact.execute_bomb(state, units, utab, wtab, tx, ty,
			ai_level, human_players, game_mode, turn, rng).to_dict()
		if journal != null:
			var _blown: Dictionary = journal.mark("mine", unit.slot, tx, ty,
				tx, ty, 0, "", {"blast": blast})
	# The fog rebuild is behind the same `+0x16` gate the rest of the arm is:
	# a mover the mine just killed rebuilds nothing.
	if unit.hp > 0:
		Visibility.build(state, units, utab, unit.player, human_players,
			game_mode)
	return {"ok": true, "reason": "", "blast": blast}
