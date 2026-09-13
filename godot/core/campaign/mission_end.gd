class_name MissionEnd
extends RefCounted

## The end of a mission -- docs/27 section 6.
##
## Two things happen here and their order is the debriefing screen's: the
## survivors go back into the roster (`aTransferAllUnitsFromMapToPool(0)`,
## **game mode 1 only**) and then the scorer runs (`0x0043BA10`).
##
## Both of the survival gate's refusals are **silent** in the engine -- it
## returns TRUE and the unit is simply gone. docs/92 section 7.4 decides the
## remake keeps the rule and drops the silence, so they come back as a report
## the screen names.

## `0x0043BBB8`, indexed by `missionResult - 1` -- docs/27 section 6.2.
const RESULT_BASE_SCORE: Array[int] = [0, 100, 200, 300, -100]
## `0x0043BAC8` -- `0x00460450`'s three settings.
const DIFFICULTY_MULTIPLIER: Array[int] = [1, 2, 3]
## docs/20 section 7 -- the two payout slots.
const SLOT_EQUIPMENT_POINTS: int = GameControl.SLOT_EQUIPMENT_POINTS
const SLOT_COMMENDATIONS: int = GameControl.SLOT_COMMENDATIONS

## Why a unit that finished the mission alive did not reach the roster.
const DROP_NOT_CANDIDATE: String = "not_a_pool_candidate"
const DROP_POOL_FULL: String = "pool_full"


## `0x0043BA10` -- the scorer and the two payouts.
##
## Returns one report per scored player. A slot whose `player_kind` is 0 is not
## in the game and is skipped entirely, which is why a campaign produces one
## report and not four.
static func score(state: CampaignState) -> Array[Dictionary]:
	var reports: Array[Dictionary] = []
	for player: int in range(CampaignState.PLAYER_SLOTS):
		if state.player_kind[player] == 0:
			continue
		var board: ScoreRecord = state.scoreboard[player]
		var result: int = board.result
		if result < 1 or result > RESULT_BASE_SCORE.size():
			# `error("unknown missionresult")` in the engine. There is no error
			# path here and the mission still ended, so it scores as a defeat
			# rather than as a win -- the same choice GameControl.mission_result
			# makes for a slot set to something unaccounted for.
			result = ScoreRecord.RESULT_DEFEAT
		var base: int = RESULT_BASE_SCORE[result - 1]
		var multiplier: int = 1
		if state.mode == TurnState.MODE_CAMPAIGN:
			multiplier = DIFFICULTY_MULTIPLIER[
				clampi(state.difficulty, 0, DIFFICULTY_MULTIPLIER.size() - 1)]
		var value: int = board.kills * multiplier - 2 * board.losses + base
		board.score = value
		board.total += value
		var paid_points: int = 0
		var paid_medals: int = 0
		if state.mode == TurnState.MODE_CAMPAIGN \
				and result != ScoreRecord.RESULT_DEFEAT:
			var bonus: int = _slot(state, SLOT_EQUIPMENT_POINTS)
			if bonus != 0:
				# What **landed**, not what the slot said: `add_points` caps
				# the purse, and the replay's rollback subtracts this.
				var purse_before: int = state.equipment_points[player]
				var _paid: bool = state.add_points(player, bonus)
				paid_points = state.equipment_points[player] - purse_before
			var medals: int = _slot(state, SLOT_COMMENDATIONS)
			if medals != 0:
				state.commendations[player] = \
					(state.commendations[player] + medals) & 0xFF
				paid_medals = medals
		reports.append({
			"player": player,
			"result": result,
			"base": base,
			"multiplier": multiplier,
			"kills": board.kills,
			"losses": board.losses,
			"score": value,
			"total": board.total,
			"equipment_points": paid_points,
			"commendations": paid_medals,
		})
	return reports


static func _slot(state: CampaignState, index: int) -> int:
	if index < 0 or index >= state.game_control.size():
		return 0
	return state.game_control[index]


## `aTransferAllUnitsFromMapToPool` `0x00478E50` and the gate at `0x00478F20`.
##
## Returns `{"recovered": Array[Dictionary], "lost": Array[Dictionary]}` --
## a name and a slot for each survivor, and a name and a reason for each unit
## that did not make it back.
static func recover(state: CampaignState, survivors: Array[UnitState],
		player: int) -> Dictionary:
	var recovered: Array[Dictionary] = []
	var lost: Array[Dictionary] = []
	for unit: UnitState in survivors:
		if unit.player != player:
			continue
		if unit.pool_flag == 0:
			lost.append({"name": unit.name, "reason": DROP_NOT_CANDIDATE})
			continue
		var slot: int = state.roster.add(unit)
		if slot == Roster.NO_SLOT:
			lost.append({"name": unit.name, "reason": DROP_POOL_FULL})
			continue
		recovered.append({"name": unit.name, "slot": slot})
	return {"recovered": recovered, "lost": lost}
