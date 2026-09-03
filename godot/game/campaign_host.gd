class_name CampaignHost
extends RefCounted

## The campaign's state machine -- docs/27 section 1.1's `Menu_b.lcl`, narrowed
## to the transitions this remake implements.
##
## [codeblock]
## MainMap -> Briefing -> SelectUnits -> (the mission) -> MissionEnd -> MainMap
## [/codeblock]
##
## plus `MainMenu` (the HQ roster), `Recruit` and `UpGrade`. It owns the
## [CampaignState], asks the caller to build a mission or the campaign map, and
## writes the save file -- which is why it lives in `game/` and not in `core/`:
## `core` never touches the filesystem (D10).

## Where the campaign save goes. One slot; a save-slot **screen** is out of
## this slice (docs/92 section 7.9).
const SAVE_PATH: String = "user://campaign.sav"

## The screens, in the order the flow reaches them.
const SCREEN_MAP: String = "map"
const SCREEN_BRIEFING: String = "briefing"
const SCREEN_SELECT: String = "select_units"
const SCREEN_MISSION: String = "mission"
const SCREEN_DEBRIEFING: String = "debriefing"
const SCREEN_HQ: String = "hq"
const SCREEN_RECRUIT: String = "recruit"
const SCREEN_UPGRADE: String = "upgrade"

## `aRandom(1, 6)` -- the recruit's voice. The engine draws it from the
## `GetTickCount`-seeded stream at `0x004638E0` (docs/28 section 3.2), which
## never repeats. A campaign save has to reproduce, so this draws from a
## deterministic stream of its own and the divergence is declared (D8).
const SPEECH_BASE: int = 1
const SPEECH_SPAN: int = 6

var state: CampaignState = null
var screen: String = SCREEN_MAP
## The location the player last clicked, or 0.
var location: int = 0
var tables: CampaignMap = null

## Filled by [method finish_mission]: what the debriefing has to say.
var last_report: Dictionary = {}

## The deterministic stream the recruit's voice comes from.
var _rng: IncRandom = null
## Set while a mission is loaded, so the host knows what to score.
var _mission_world: World = null
var _cache_dir: String = ""
var _balance: Dictionary = {}
## The shipped text banks. `Txtmod_h` 60..62 carry the seeded squad's names,
## so a campaign started without it falls back to the transcribed constants.
var _text: Localization = null


static func create(cache_dir: String, balance: Dictionary,
		text: Localization = null) -> CampaignHost:
	var host: CampaignHost = CampaignHost.new()
	host._cache_dir = cache_dir
	host._balance = balance
	host._text = text
	host._rng = IncRandom.new()
	host._rng.randomize_seed(1.0)
	host.tables = CampaignMap.from_document(
		CacheLoader.read_json(cache_dir + "/tables/campaign.json"))
	return host


# -- starting ------------------------------------------------------------------

## A new campaign in either chain (D1).
##
## Campaign 1 begins at `_C_100` with Bratt, West and Maxon; campaign 2 begins
## at `_C_140` with an **empty** pool, because
## `aCreateUnitPoolForCampaign(2)` is a bare `return TRUE`. Campaign 2's
## opening squad is the four units `_C_140.lev` places itself, which reach the
## roster at its debriefing.
func start_new(number: int) -> CampaignState:
	var names: PackedStringArray = _seed_names()
	var speech: PackedInt32Array = PackedInt32Array()
	for _index: int in range(CampaignState.SEED_NAMES.size()):
		speech.append(_draw_speech())
	state = CampaignState.begin(number, _weapon_zero_cost(),
		_recruit_hit_points(), names, speech)
	screen = SCREEN_MAP
	location = tables.location_of(tables.mission_id(state.mission))
	last_report = {}
	return state


## `Txtmod_h.lcl` 60..62 -- the three names really live in the text bank, and
## `campaign_tables` names 0x3C..0x3E as the ids.
func _seed_names() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for index: int in range(CampaignState.SEED_TEXT_IDS.size()):
		var id: int = CampaignState.SEED_TEXT_IDS[index]
		var name: String = ""
		if _text != null:
			name = _text.shipped(CampaignState.SEED_TEXT_BANK, id)
		out.append(name if name != "" else CampaignState.SEED_NAMES[index])
	return out


## `aRandom(1, 6)` -- base and **span**, so the result is 1..6.
func _draw_speech() -> int:
	return _rng.draw(SPEECH_BASE, SPEECH_SPAN)


func _weapon_zero_cost() -> int:
	var weapons: Array = DictRead.as_array(_balance.get("weapons", []))
	for entry: Variant in weapons:
		var row: Dictionary = entry
		if DictRead.as_int(row["id"]) == 0:
			return DictRead.as_int(row["cost"])
	return 10


func _recruit_hit_points(player: int = 0) -> int:
	var units: Array = DictRead.as_array(_balance.get("units", []))
	for entry: Variant in units:
		var row: Dictionary = entry
		if DictRead.as_int(row["id"]) == player:
			return DictRead.as_int(row["hp_max"])
	return 1


# -- the map -------------------------------------------------------------------

## The `.lev` the campaign map is drawn on -- `_C_XXX` or `_C_YYY` (D3).
func map_mission() -> String:
	return state.map_name() if state != null else ""


## `aCreateLocationMap` -- the locations open with the current mission next.
func open_locations() -> PackedInt32Array:
	if state == null:
		return PackedInt32Array()
	return tables.open_locations(tables.mission_id(state.mission))


## What clicking a location does -- `aLocationHandling` `0x0045C7D0`'s three
## kinds of arm. Returns `{"kind": String, "target": String, "sequence": int}`.
##
## A dialogue location opens, is named and **plays nothing**: the sequence
## player is a later slice (D5).
func click_location(id: int) -> Dictionary:
	if state == null:
		return {"kind": CampaignMap.KIND_NONE, "target": "", "sequence": 0}
	if not open_locations().has(id):
		return {"kind": CampaignMap.KIND_NONE, "target": "", "sequence": 0}
	location = id
	var kind: String = tables.kind_of(id)
	match kind:
		CampaignMap.KIND_BATTLE:
			screen = SCREEN_BRIEFING
			return {"kind": kind, "target": tables.mission_of(id),
				"sequence": 0}
		CampaignMap.KIND_UPGRADE:
			screen = SCREEN_UPGRADE
			return {"kind": kind, "target": tables.upgrade_map(id),
				"sequence": 0}
		CampaignMap.KIND_DIALOGUE:
			return {"kind": kind, "target": "",
				"sequence": tables.dialogue_number(id)}
	return {"kind": CampaignMap.KIND_NONE, "target": "", "sequence": 0}


# -- entering a mission --------------------------------------------------------

## `aCopyUnitPool(0, 1)` at `0x0045A914` -- the mission-entry snapshot.
##
## Taken **before** deployment, which is what makes the debriefing's *replay*
## button restore the squad as it was, rather than as it ended.
func begin_mission(mission_world: World) -> void:
	if state == null:
		return
	state.roster.snapshot()
	_mission_world = mission_world
	screen = SCREEN_SELECT


## Put one roster slot on the map. Returns [World]'s own result dictionary,
## with the slot removed from the live row on success.
func deploy(slot: int, x: int, y: int) -> Dictionary:
	if state == null or _mission_world == null:
		return {"result": World.DEPLOY_EMPTY_RECORD, "slot": MapState.NO_UNIT}
	var record: UnitState = state.roster.record(slot)
	if record == null:
		return {"result": World.DEPLOY_EMPTY_RECORD, "slot": MapState.NO_UNIT}
	var placed: Dictionary = _mission_world.deploy_from_pool(0, record, x, y)
	if DictRead.as_string(placed["result"]) == World.DEPLOY_OK:
		# `aTransferUnitFromPoolToMap` takes the slot out of the pool only
		# after the placement succeeds.
		state.roster.clear(slot)
	return placed


## The cells a squad may deploy onto, and how many of them there are -- the
## upper bound on a sortie, because the header's ring holds ten records.
func deployment_cells() -> Array[Vector2i]:
	if _mission_world == null:
		return []
	return _mission_world.deployment_cells(0)


## Whether the mission may start: the engine's own screen refuses an empty map.
func may_start() -> bool:
	if _mission_world == null:
		return false
	for slot: int in _mission_world.unit_slots():
		var view: Dictionary = _mission_world.unit_view(slot)
		if DictRead.as_int(view["player"]) == 0:
			return true
	return false


func enter_mission() -> void:
	screen = SCREEN_MISSION


# -- the end of a mission ------------------------------------------------------

## The debriefing, in `aMissionEnd.cpp`'s order (docs/27 section 6.1).
##
## 1. **in game mode 1 only**, `aTransferAllUnitsFromMapToPool(0)`;
## 2. `0x0043BA10`, the scorer and the payout.
##
## The kills and losses come from the world rather than being invented: the
## scoreboard's `+0x00` and `+0x08` are what the mission left there.
func finish_mission(mission_world: World) -> Dictionary:
	if state == null:
		return {}
	_mission_world = mission_world
	var board: ScoreRecord = state.scoreboard[0]
	board.result = mission_world.game_control.mission_result(0)
	# The mission's own halves of the scoreboard, counted where the engine
	# counts them rather than summed here: `+0x00` at `0x0043B810`, `+0x08` at
	# `0x0043B8D0` and `+0x10` at `0x0043B860`. A sum over the survivors would
	# lose every kill made by a unit that later died.
	var turn: TurnState = mission_world.turn
	board.kills = turn.mission_kills[0]
	board.losses = turn.mission_lost[0]
	board.lost_to_enemy = turn.mission_lost_to_enemy[0]
	# The campaign halves accumulate, which is what the pairing means.
	board.campaign_kills += board.kills
	board.campaign_losses += board.losses
	board.campaign_lost_to_enemy += board.lost_to_enemy
	board.heroes_lost = mission_world.turn.hero_killed[0]
	# The mission script's payout slots, carried over so the scorer can read
	# what the mission that just ended wrote.
	state.game_control = mission_world.game_control.values()

	var recovery: Dictionary = {"recovered": [], "lost": []}
	if state.mode == TurnState.MODE_CAMPAIGN:
		recovery = MissionEnd.recover(state,
			mission_world.survivors_of(0), 0)
	var scores: Array[Dictionary] = MissionEnd.score(state)
	last_report = {
		"result": board.result,
		"score": scores[0]["score"] if not scores.is_empty() else 0,
		"total": board.total,
		"kills": board.kills,
		"losses": board.losses,
		"equipment_points": scores[0]["equipment_points"] \
			if not scores.is_empty() else 0,
		"commendations": scores[0]["commendations"] \
			if not scores.is_empty() else 0,
		"recovered": recovery["recovered"],
		# **Named, not silent** (docs/92 section 7.4). The engine drops a unit
		# that is not a pool candidate and one that finds no free slot without
		# saying so; both come back here so the screen can.
		"lost": recovery["lost"],
		"next_map": _next_map(mission_world),
	}
	screen = SCREEN_DEBRIEFING
	return last_report


## docs/27 section 6.6 -- the header's next-map field, overridable by
## `EnterNameOfNextMap`, which is what [member World.next_map] already carries.
func _next_map(mission_world: World) -> String:
	if mission_world.next_map != "":
		return mission_world.next_map
	return tables.next_map(state.mission)


## The debriefing's *go on* button, `0x0045E986`.
func advance() -> String:
	if state == null:
		return ""
	var target: String = DictRead.as_string(last_report.get("next_map", ""))
	if target == "":
		target = tables.next_map(state.mission)
	if target != "":
		state.mission = target
	# The snapshot does not outlive the debriefing: `_5_.sav` is on the map
	# screen with row 1 empty. What clears it is not traced, but that it is
	# gone by then is what makes *replay* a debriefing button and not a map one.
	state.roster.clear_snapshot()
	state.scoreboard[0].kills = 0
	state.scoreboard[0].losses = 0
	screen = SCREEN_MAP
	if tables.has_mission(state.mission):
		location = tables.location_of(tables.mission_id(state.mission))
	_mission_world = null
	return state.mission


## The debriefing's *back to the map* button, `0x0045E9CB` --
## `aCopyUnitPool(1, 0)`, which puts the **pre-mission** roster back. So it is
## a replay of the same mission, not a step forward.
func replay() -> String:
	if state == null:
		return ""
	state.roster.restore()
	state.roster.clear_snapshot()
	state.scoreboard[0].reset()
	screen = SCREEN_MAP
	_mission_world = null
	return state.mission


# -- the HQ --------------------------------------------------------------------

func recruit() -> int:
	if state == null:
		return Roster.NO_SLOT
	return state.recruit(0, _draw_speech())


func dismiss(slot: int) -> int:
	if state == null:
		return 0
	return state.dismiss(0, slot, weapon_costs())


## `id -> cost`, from the balance tables. Built once per call rather than
## cached, because the tables are small and a stale copy would misprice a sale.
func weapon_costs() -> Dictionary:
	var out: Dictionary = {}
	for entry: Variant in DictRead.as_array(_balance.get("weapons", [])):
		var row: Dictionary = entry
		out[DictRead.as_int(row["id"])] = DictRead.as_int(row["cost"])
	return out


## docs/27 section 5.2 -- the catalogue the tech level gates, and what is
## locked. Returns `{"available": Array, "locked": Array}` so a screen can show
## both: a filter that silently hid the rest would make a frozen tech level
## indistinguishable from a working one.
func catalogue(kind: String) -> Dictionary:
	var available: Array[Dictionary] = []
	var locked: Array[Dictionary] = []
	for entry: Variant in DictRead.as_array(_balance.get(kind, [])):
		var row: Dictionary = entry
		var needs: int = DictRead.as_int(row.get("tech", 0))
		if needs <= state.tech_level:
			available.append(row)
		else:
			locked.append(row)
	return {"available": available, "locked": locked}


# -- the save file -------------------------------------------------------------

## Write the campaign, and optionally the mission in progress.
##
## The mission blob is [SaveCodec]'s and stays opaque here: that codec refuses
## a blob whose map name is not the world's, which is right for a mission save
## and wrong for a campaign container (D10).
func save(mission_world: World = null) -> bool:
	if state == null:
		return false
	var blob: PackedByteArray = PackedByteArray()
	if mission_world != null:
		blob = mission_world.save({})
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(CampaignCodec.encode(state, blob))
	file.close()
	return true


## Returns `{"result": int, "mission": PackedByteArray}`; `result` is one of
## [enum CampaignCodec.Result].
func load_save() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {"result": CampaignCodec.Result.TRUNCATED,
			"mission": PackedByteArray()}
	var data: PackedByteArray = FileAccess.get_file_as_bytes(SAVE_PATH)
	var decoded: Dictionary = CampaignCodec.decode(data)
	if DictRead.as_int(decoded["result"]) != CampaignCodec.Result.OK:
		return decoded
	state = decoded["state"]
	screen = SCREEN_MAP
	if tables.has_mission(state.mission):
		location = tables.location_of(tables.mission_id(state.mission))
	return decoded


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


# -- reporting -----------------------------------------------------------------

## Everything a screen or `tour.gd` needs, as scalars.
func view() -> Dictionary:
	if state == null:
		return {"screen": screen, "campaign": 0, "mission": ""}
	var roster: Array[Dictionary] = []
	for slot: int in state.roster.occupied_slots():
		var unit: UnitState = state.roster.record(slot)
		roster.append({
			"slot": slot,
			"name": unit.name,
			"ep": unit.ep,
			"rank": unit.ep / Roster.EP_PER_RANK,
			"hp": unit.hp,
			"weapon": unit.weapon,
			"pool_flag": unit.pool_flag,
		})
	return {
		"screen": screen,
		"campaign": state.campaign,
		"mission": state.mission,
		"map": state.map_name(),
		"location": location,
		"open_locations": open_locations(),
		"equipment_points": state.points(0),
		"commendations": state.commendations[0],
		"tech_level": state.tech_level,
		"skill_level": state.skill_level,
		"difficulty": state.difficulty,
		"roster": roster,
		"snapshot": state.roster.used_slots(Roster.ROW_SNAPSHOT),
		"score_total": state.scoreboard[0].total,
		"report": last_report,
		"digest": state.digest_hex(),
	}
