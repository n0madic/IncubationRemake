class_name CampaignState
extends RefCounted

## Everything docs/27 section 8 item 1 lists, and nothing derived.
##
## The campaign number is the **first** field for a reason (D1): it selects the
## seed, the first mission, the campaign map and the band of locations, and all
## four are switches on it in the engine.
##
## This object is deliberately **outside** [World]'s canonical hash (D7). A
## campaign is not a simulation state a mission trace has to reproduce, and
## folding it in would move every hash the first five slices pinned. It carries
## its own digest instead, so a campaign save can still be compared with itself.

## `0x0043AF57` and `0x0043AF2A` -- the campaign number picks the first mission.
const FIRST_MISSION: Dictionary = {1: "_C_100", 2: "_C_140"}
## docs/27 section 2.1 -- and the map its locations are drawn on.
const CAMPAIGN_MAP: Dictionary = {1: "_C_XXX", 2: "_C_YYY"}
## Campaign 1 seeds Bratt/West/Maxon; `aCreateUnitPoolForCampaign(2)` is a bare
## `return TRUE`, so campaign 2 runs on whatever the pool holds -- nothing.
const SEEDING_CAMPAIGN: int = 1

const PLAYER_SLOTS: int = 4

## The campaign arm `0x0043AE76` writes these for **player 0 alone**: its loop
## bound is the player count, which it has just set to 1. Slots 1..3 keep
## whatever the front end left in them, which is why a real save reads
## `EP = (100, 2000, 2000, 2000)` -- the 2000s are the multiplayer arm's.
const START_PLAYER_COUNT: int = 1
const START_EQUIPMENT_POINTS: int = 100
## `0x0043AEBB`. **The tech level does not grow.** `0x00509F04` has four
## `.text` references in the whole image -- the two init arms and the
## setter/getter -- and the five `setTechLevel` call sites are the
## single-mission front end, which is what the header's `+0x21E` is for. So
## this is the campaign's tech level from beginning to end.
const START_TECH_LEVEL: int = 1
## `0x0043AF06`.
const START_SKILL_LEVEL: int = 0
const START_COMMENDATIONS: int = 0

## `0x0043B010` clamps the add here.
const EQUIPMENT_POINT_CAP: int = 10000

## docs/27 section 3.1 -- the three seeded records, decoded from
## `0x0047883B`..`0x004788A5`. Skills are indices into `+0x1A`.
const HERO_UNIT_TYPE: int = 0x17
const HERO_POOL_FLAG: int = 2
const MEDIC_EQUIPMENT_ID: int = 15
const SEED_NAMES: Array[String] = ["Bratt", "West", "Maxon"]
## `Txtmod_h.lcl` text ids 60..62, which is where the three names really live.
const SEED_TEXT_BANK: String = "Txtmod_h"
const SEED_TEXT_IDS: Array[int] = [0x3C, 0x3D, 0x3E]

var campaign: int = 2
var mission: String = ""
## `0x00509EEC`, one per player slot.
var equipment_points: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## `0x00509EFC`.
var commendations: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
## `0x00509E20` -- 0 means the slot is not in the game.
var player_kind: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
var scoreboard: Array[ScoreRecord] = []
var roster: Roster = null
var difficulty: int = 0
var tech_level: int = START_TECH_LEVEL
var skill_level: int = START_SKILL_LEVEL
var player_count: int = START_PLAYER_COUNT
var mode: int = TurnState.MODE_CAMPAIGN
## docs/20 section 7 -- the twelve slots a mission script writes, carried here
## so the debriefing can pay out what the mission that just ended left.
var game_control: PackedInt32Array = PackedInt32Array()
## `Info.lcl`'s `hp_max` for the recruit's unit type. `aEnlargeUnitPool` writes
## `unitType = player`, so it is the type of the hiring side.
var recruit_hit_points: int = 1
## `Info.lcl`'s weapon 0 cost, which prices a recruit at `cost + 50`.
var weapon_zero_cost: int = 10


static func create() -> CampaignState:
	var state: CampaignState = CampaignState.new()
	state.roster = Roster.create()
	state.game_control.resize(GameControl.SLOTS)
	for _slot: int in range(PLAYER_SLOTS):
		state.scoreboard.append(ScoreRecord.new())
	return state


## A new campaign -- `0x0043AE76`, then `aCreateUnitPoolForCampaign`.
##
## *speech* supplies the seed's three `aRandom(1, 6)` draws; the campaign draws
## them from its own deterministic stream rather than the `GetTickCount`-seeded
## one the engine uses, because a save has to reproduce (D8).
static func begin(number: int, weapon_zero: int, hit_points: int,
		names: PackedStringArray = PackedStringArray(),
		speech: PackedInt32Array = PackedInt32Array()) -> CampaignState:
	var state: CampaignState = CampaignState.create()
	if not FIRST_MISSION.has(number):
		return state
	state.campaign = number
	state.weapon_zero_cost = weapon_zero
	state.recruit_hit_points = hit_points
	state.player_count = START_PLAYER_COUNT
	for player: int in range(state.player_count):
		state.equipment_points[player] = START_EQUIPMENT_POINTS
		state.commendations[player] = START_COMMENDATIONS
		state.scoreboard[player].reset()
	state.tech_level = START_TECH_LEVEL
	state.skill_level = START_SKILL_LEVEL
	# The front end marks player 0 as human; every shipped save reads
	# `player_kind = [1, 0, 0, 0]`.
	state.player_kind[0] = 1
	state.mission = DictRead.as_string(FIRST_MISSION[number])
	state.seed_pool(names, speech)
	return state


## `aCreateUnitPoolForCampaign` `0x00478710`.
func seed_pool(names: PackedStringArray = PackedStringArray(),
		speech: PackedInt32Array = PackedInt32Array()) -> void:
	if campaign != SEEDING_CAMPAIGN:
		return
	for index: int in range(SEED_NAMES.size()):
		var drawn: int = speech[index] if index < speech.size() else 1
		roster.enlarge(0, mode, skill_level, drawn, recruit_hit_points)
	for index: int in range(SEED_NAMES.size()):
		var unit: UnitState = roster.record(index)
		if unit == null:
			continue
		unit.name = names[index] if index < names.size() else SEED_NAMES[index]
		_apply_seed(unit, index)
		roster.put(index, unit)


## docs/27 section 3.1's table. Record 0 is Sgt. Bratt, the hero.
func _apply_seed(unit: UnitState, index: int) -> void:
	match index:
		0:
			unit.ep = 17
			unit.tp = 0
			unit.skills[UnitState.SKILL_LW] = 1
			unit.skills[UnitState.SKILL_LS] = 2
			unit.type_id = HERO_UNIT_TYPE
			unit.pool_flag = HERO_POOL_FLAG
			unit.speech = 10
		1:
			unit.ep = 12
			unit.tp = 0
			unit.skills[UnitState.SKILL_MS] = 2
			unit.pool_flag = Roster.POOL_CANDIDATE
			unit.speech = 3
			if not unit.equipment.has(MEDIC_EQUIPMENT_ID):
				unit.equipment.append(MEDIC_EQUIPMENT_ID)
		2:
			unit.ep = 12
			unit.tp = 12
			unit.skills[UnitState.SKILL_HW] = 1
			unit.pool_flag = Roster.POOL_CANDIDATE
			unit.speech = 4


# -- the campaign's own position ----------------------------------------------

## docs/27 section 2.1 -- which `.lev` the location map is drawn on.
func map_name() -> String:
	return DictRead.as_string(CAMPAIGN_MAP.get(campaign, ""))


# -- the economy -- docs/27 section 5.1 ---------------------------------------

## `0x0043AFF0`.
func points(player: int) -> int:
	if player < 0 or player >= PLAYER_SLOTS:
		return 0
	return equipment_points[player]


## `0x0043B010` -- clamped at 10000, and refused for a slot not in the game.
func add_points(player: int, amount: int) -> bool:
	if not _in_game(player):
		return false
	equipment_points[player] = mini(EQUIPMENT_POINT_CAP,
		equipment_points[player] + amount)
	return true


## `0x0043B060` -- refuses when the purse is short, so a purchase never goes
## negative.
func spend_points(player: int, amount: int) -> bool:
	if not _in_game(player):
		return false
	if equipment_points[player] < amount:
		return false
	equipment_points[player] -= amount
	return true


## `0x0043B0A0`.
func set_points(player: int, amount: int) -> void:
	if player < 0 or player >= PLAYER_SLOTS:
		return
	equipment_points[player] = amount


func _in_game(player: int) -> bool:
	return player >= 0 and player < PLAYER_SLOTS and player_kind[player] != 0


## docs/27 section 5.4 -- `weapon[0].cost + 50`, which `Info.lcl` prices at 60.
func recruit_cost() -> int:
	return weapon_zero_cost + Roster.RECRUIT_MARKUP


## The Recruit screen's hire button: price, purse, free slot, then
## `aEnlargeUnitPool`. Returns the slot or [constant Roster.NO_SLOT].
func recruit(player: int, speech: int) -> int:
	var cost: int = recruit_cost()
	if points(player) < cost:
		return Roster.NO_SLOT
	if roster.first_free() == Roster.NO_SLOT:
		return Roster.NO_SLOT
	if not spend_points(player, cost):
		return Roster.NO_SLOT
	return roster.enlarge(player, mode, skill_level, speech, recruit_hit_points)


## The Recruit screen's other button. Returns the points refunded.
func dismiss(player: int, slot: int, weapon_costs: Dictionary) -> int:
	var removed: UnitState = roster.dismiss(slot)
	if removed == null:
		return 0
	var refund: int = Roster.refund_for(
		DictRead.as_int(weapon_costs.get(removed.weapon, 0)))
	add_points(player, refund)
	return refund


## docs/27 section 5.3 -- refund the old weapon, spend the new one.
##
## The order is the engine's: the refund at `0x0045AAC7` happens **first**, so
## a swap costs the difference and an upgrade the player could not afford
## outright still goes through.
func buy_weapon(player: int, slot: int, weapon: int,
		weapon_costs: Dictionary) -> bool:
	var unit: UnitState = roster.record(slot)
	if unit == null:
		return false
	var old_cost: int = DictRead.as_int(weapon_costs.get(unit.weapon, 0))
	var new_cost: int = DictRead.as_int(weapon_costs.get(weapon, 0))
	add_points(player, old_cost)
	if not spend_points(player, new_cost):
		# The engine's `add` has already happened and the player keeps it; the
		# weapon simply does not change. Putting the refund back is what keeps
		# a failed purchase from being a way to print money.
		spend_points(player, old_cost)
		return false
	unit.weapon = weapon
	roster.put(slot, unit)
	return true


## `0x0045A9E9` -- guarded on the unit's carried-equipment bitmap.
func buy_equipment(player: int, slot: int, item: int, cost: int) -> bool:
	var unit: UnitState = roster.record(slot)
	if unit == null or unit.has_equipment(item):
		return false
	if not spend_points(player, cost):
		return false
	unit.equipment.append(item)
	roster.put(slot, unit)
	return true


# -- serialisation -------------------------------------------------------------

func view() -> Dictionary:
	var boards: Array = []
	for record: ScoreRecord in scoreboard:
		boards.append(record.view())
	return {
		"campaign": campaign,
		"mission": mission,
		"equipment_points": equipment_points.duplicate(),
		"commendations": commendations.duplicate(),
		"player_kind": player_kind.duplicate(),
		"difficulty": difficulty,
		"tech_level": tech_level,
		"skill_level": skill_level,
		"player_count": player_count,
		"mode": mode,
		"game_control": game_control.duplicate(),
		"recruit_hit_points": recruit_hit_points,
		"weapon_zero_cost": weapon_zero_cost,
		"scoreboard": boards,
		"roster": roster.view(),
	}


static func from_view(record: Dictionary) -> CampaignState:
	var state: CampaignState = CampaignState.create()
	state.campaign = DictRead.as_int(record["campaign"])
	state.mission = DictRead.as_string(record["mission"])
	state.equipment_points = DictRead.to_int32(record["equipment_points"])
	state.commendations = DictRead.to_int32(record["commendations"])
	state.player_kind = DictRead.to_int32(record["player_kind"])
	state.difficulty = DictRead.as_int(record["difficulty"])
	state.tech_level = DictRead.as_int(record["tech_level"])
	state.skill_level = DictRead.as_int(record["skill_level"])
	state.player_count = DictRead.as_int(record["player_count"])
	state.mode = DictRead.as_int(record["mode"])
	state.game_control = DictRead.to_int32(record["game_control"])
	state.recruit_hit_points = DictRead.as_int(record["recruit_hit_points"])
	state.weapon_zero_cost = DictRead.as_int(record["weapon_zero_cost"])
	var boards: Array[ScoreRecord] = []
	for entry: Variant in DictRead.as_array(record["scoreboard"]):
		boards.append(ScoreRecord.from_view(entry))
	state.scoreboard = boards
	state.roster = Roster.from_view(DictRead.as_dict(record["roster"]))
	return state


## The campaign's own digest -- **not** [World]'s canonical hash (D7).
func digest_hex() -> String:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(mission.to_utf8_buffer())
	ctx.update(PackedInt32Array([campaign, difficulty, tech_level, skill_level,
		player_count, mode, recruit_hit_points,
		weapon_zero_cost]).to_byte_array())
	ctx.update(equipment_points.to_byte_array())
	ctx.update(commendations.to_byte_array())
	ctx.update(player_kind.to_byte_array())
	ctx.update(game_control.to_byte_array())
	for record: ScoreRecord in scoreboard:
		record.hash_into(ctx)
	roster.hash_into(ctx)
	return CanonicalHash.to_hex(ctx.finish())
