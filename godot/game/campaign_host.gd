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

## Where the campaign saves go, and **a field rather than a constant**.
##
## The `macOS Tests` export preset runs the suites inside a real build, against
## the real `user://`. A suite that wrote to the shipped path would overwrite a
## live player's game, so the directory is injectable and the suites point it
## at a scratch one (docs/92 section 7.15).
const DEFAULT_SAVE_DIR: String = "user://saves"
## The eight numbered slots the shell shows.
const SLOT_COUNT: int = 8
## The quick save is **not** one of them: `F5` must not cost the player a slot
## they meant to keep, so it has a file of its own beside the eight.
const QUICK_SLOT: int = -1
const QUICK_NAME: String = "quick.sav"
const SLOT_NAME: String = "slot-%d.sav"

var save_dir: String = DEFAULT_SAVE_DIR

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
## *difficulty* is what the shell's options screen last chose, and it is set
## here rather than left at [CampaignState]'s own default because the two
## defaults are **not** the same number: the class starts at 0 and
## [member TurnState.ai_level] at 1, and they are one engine setting
## (`0x00460450`). Passing it at the one place a campaign begins is what keeps
## a campaign-built world's canonical hash where every other caller's is.
func start_new(number: int,
		difficulty: int = GameSettings.DIFFICULTY_DEFAULT) -> CampaignState:
	var names: PackedStringArray = _seed_names()
	var speech: PackedInt32Array = PackedInt32Array()
	for _index: int in range(CampaignState.SEED_NAMES.size()):
		speech.append(_draw_speech())
	state = CampaignState.begin(number, _weapon_zero_cost(),
		_recruit_hit_points(), names, speech)
	state.difficulty = clampi(difficulty, GameSettings.DIFFICULTY_MIN,
		GameSettings.DIFFICULTY_MAX)
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
	# Only the mission halves: the campaign totals are what the debriefing has
	# just added to, and `reset()` -- which is `resetScoreboard` -- would wipe
	# them.
	state.scoreboard[0].reset_mission()
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
	# The same rule, and here it is the one that mattered: *Try Again* used to
	# call `reset()`, which wiped the campaign score along with the mission's.
	# A replay undoes the mission, not the campaign -- and the score the
	# debriefing added has to come back off the total, because the replayed
	# mission will add its own.
	var board: ScoreRecord = state.scoreboard[0]
	board.campaign_kills -= board.kills
	board.campaign_losses -= board.losses
	board.campaign_lost_to_enemy -= board.lost_to_enemy
	board.total -= board.score
	board.reset_mission()
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

## The file one slot lives in. [constant QUICK_SLOT] is the quick save; 0..7
## are the numbered ones.
func slot_path(slot: int = QUICK_SLOT) -> String:
	if slot == QUICK_SLOT:
		return "%s/%s" % [save_dir, QUICK_NAME]
	return "%s/%s" % [save_dir, SLOT_NAME % slot]


## Write the campaign, and optionally the mission in progress.
##
## The mission blob is [SaveCodec]'s and stays opaque here: that codec refuses
## a blob whose map name is not the world's, which is right for a mission save
## and wrong for a campaign container (D10).
##
## *when* and *when_text* are the stamp the slot row shows. They come from the
## caller because `core` may not call `Time` and the codec is `core`'s
## (`godot/tests/test_isolation.gd`); [method stamp_now] is the one place in
## `game/` that reads the clock.
func save(mission_world: World = null, slot: int = QUICK_SLOT,
		when: int = 0, when_text: String = "") -> bool:
	if state == null:
		return false
	var blob: PackedByteArray = PackedByteArray()
	if mission_world != null:
		blob = mission_world.save({})
	var made: Error = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(save_dir))
	if made != OK and made != ERR_ALREADY_EXISTS:
		return false
	var file: FileAccess = FileAccess.open(slot_path(slot), FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(CampaignCodec.encode(state, blob, when, when_text))
	file.close()
	return true


## The clock, read in the one place `game/` reads it for a save.
static func stamp_now() -> Dictionary:
	return {"when": int(Time.get_unix_time_from_system()),
		"when_text": Time.get_datetime_string_from_system(false, true)}


## Returns `{"result": int, "mission": PackedByteArray}`; `result` is one of
## [enum CampaignCodec.Result].
##
## An **absent** file is reported as [constant CampaignCodec.Result.NO_FILE]
## and not as a truncated one: "you never saved here" and "the bytes are
## damaged" are different answers, and the slot screen shows different rows
## for them.
func load_save(slot: int = QUICK_SLOT) -> Dictionary:
	if not has_save(slot):
		return {"result": CampaignCodec.Result.NO_FILE,
			"mission": PackedByteArray()}
	var data: PackedByteArray = FileAccess.get_file_as_bytes(slot_path(slot))
	var decoded: Dictionary = CampaignCodec.decode(data)
	if DictRead.as_int(decoded["result"]) != CampaignCodec.Result.OK:
		return decoded
	state = decoded["state"]
	screen = SCREEN_MAP
	if tables.has_mission(state.mission):
		location = tables.location_of(tables.mission_id(state.mission))
	return decoded


func has_save(slot: int = QUICK_SLOT) -> bool:
	return FileAccess.file_exists(slot_path(slot))


## What one slot's row says, without building the campaign behind it:
## `{"result": int, "used": bool, "campaign": int, "mission": String,
## "score": int, "saved_at": int, "saved_at_text": String,
## "has_mission": bool}`.
##
## A row for a file this build cannot read is **shown**, carrying its refusal
## code, rather than being hidden -- a slot that vanished because the schema
## moved would look like a slot the player never used.
func slot_header(slot: int) -> Dictionary:
	if not has_save(slot):
		return {"result": CampaignCodec.Result.NO_FILE, "used": false,
			"campaign": 0, "mission": "", "score": 0, "saved_at": 0,
			"saved_at_text": "", "has_mission": false}
	var header: Dictionary = CampaignCodec.decode_header(
		FileAccess.get_file_as_bytes(slot_path(slot)))
	header["used"] = true
	return header


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
