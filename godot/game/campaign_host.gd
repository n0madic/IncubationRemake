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
## The numbered slots the shell shows.
##
## **Twenty-four, paged twelve at a time.** It was eight, which is what
## `aLoad.cpp`'s own screen holds; the shipped screen is a picture of eight
## rows and this one is a listbox, so the count is the remake's to choose and
## a campaign is long enough to want more than one save per chapter. A row
## costs a `slot-N.sav` that is only written when the player writes it, and
## only the twelve rows on show decode a header ([method
## SaveSlotsScreen.refresh]), so the count is not paid for until it is used.
##
## **The ceiling is the interface's three reserved slots**, not a round
## number: `HudTables.SLOT_UNDO_MISSION`, `SLOT_REMIND` and `SLOT_UNDO_TURN`
## are 31, 32 and 33, and they are files in this same directory written by
## *Remember position* and by the turn's own autosave. A count that reached
## them would put an autosave on the list as a row the player could load by
## surprise and overwrite by accident. `test_shell.gd` pins the gap.
const SLOT_COUNT: int = 24
## The quick save is **not** one of them: `F5` must not cost the player a slot
## they meant to keep, so it has a file of its own beside the numbered ones.
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
## `Menu_b.lcl`'s `:ItemList;`, window 5 -- the catalogue the Upgrade screen's
## *Select Weapon* and *Select Equipment* buttons open.
const SCREEN_ITEMS: String = "items"

## The two halves of the catalogue, as the Item List's *Toggle List* names them.
const KIND_WEAPONS: String = "weapons"
const KIND_EQUIPMENT: String = "equipment"

## `mov byte [0x00510A34], 0` at `0x0045BF44` -- the low end of the range both
## catalogue builders filter on; the high end is the tech level. See
## [method catalogue].
const CATALOGUE_LOW: int = 0
## The first id **past** the catalogue, per half.
##
## **This is the exclusion that keeps the aliens out of the shop**, and it is
## the forward stepper's alone: `0x0047A18B` compares the record pointer
## against `0x0051B834` -- `0x0051B2F8 + 20 * 67`, so `id < 20` -- *after* the
## name and the range, and its backward twin has no such test because the
## caller starts it at 18 (`0x0045AF71`, `push 0x12`) and it only walks down.
## The equipment pair is bounded by where the forward walk stops instead,
## `0x0047A023` against `0x00517F43` = `0x00517BD1 + 21 * 42`.
##
## Weapons 20..29 are the aliens, 30..37 the bayonets and the bombs, 40..47 the
## `B`-variant duplicates and 28 is `Info.lcl`'s `"-"` placeholder
## (`* (x) No Weapon`); none of them is reachable. Ids 18 and 19 have no
## `SetWeaponInfo` line at all, so the catalogue is 0..17 -- the sixteen human
## weapons plus the Combot's gun and `Explosives`, both tech 99 and so refused
## by any shipped level.
const CATALOGUE_ID_MAX: Dictionary = {KIND_WEAPONS: 20, KIND_EQUIPMENT: 21}

## `aRandom(1, 6)` -- the recruit's voice. The engine draws it from the
## `GetTickCount`-seeded stream at `0x004638E0` (docs/28 section 3.2), which
## never repeats. A campaign save has to reproduce, so this draws from a
## deterministic stream of its own and the divergence is declared (D8).
const SPEECH_BASE: int = 1
const SPEECH_SPAN: int = 6

## The gate `0x00456FC0(-1)` reads the mission id and picks a sequence
## (docs/27 section 2.3, docs/41 section 5): id 1 with the intro flag plays
## logical id 0 full screen, id 180 the static extro, id 255 logical id 1
## full screen, anything else nothing.
const INTRO_CAMPAIGN: int = 1
const INTRO_MISSION_ID: int = 1
const INTRO_SEQUENCE: int = 0
const STATIC_EXTRO_MISSION_ID: int = 180
const ANIMATED_EXTRO_MISSION_ID: int = 255
const ANIMATED_EXTRO_SEQUENCE: int = 1
## What [method opening_sequence] answers in `kind`.
const OPENING_NONE: String = ""
const OPENING_INTRO: String = "intro"
const OPENING_EXTRO: String = "extro"
const OPENING_STATIC_EXTRO: String = "extro_static"

var state: CampaignState = null
var screen: String = SCREEN_MAP
## The location the player last clicked, or 0.
var location: int = 0
## What the Unit Menu, the Upgrade Menu and the Item List are looking at.
##
## They are three windows onto one choice -- the soldier being equipped and the
## item being considered -- and the original keeps that choice in globals of
## its own (`0x00510A48` the roster slot, `0x00510A44` the list half,
## `0x00510A40` the item). Keeping it here rather than in the screens is what
## lets *Select Weapon* leave the Upgrade Menu and come back to the same
## soldier.
var upgrade_slot: int = Roster.NO_SLOT
var item_kind: String = KIND_WEAPONS
var item_id: int = -1
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
		_recruit_hit_points(), _recruit_ammo(), names, speech)
	state.difficulty = clampi(difficulty, GameSettings.DIFFICULTY_MIN,
		GameSettings.DIFFICULTY_MAX)
	# `0x00450997`: the new-campaign start arms the intro on its campaign-1
	# arm and clears it on the other (`0x00450A11`). The gate then plays
	# logical id 0 once, when mission id 1 first reaches mission control.
	state.intro_pending = number == INTRO_CAMPAIGN
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


## Weapon 0's `mun` -- what `aEnlargeUnitPool`'s closing recompute puts in a
## recruit's magazine, `aEnlargeUnitPool` having just given them weapon 0.
func _recruit_ammo() -> int:
	var weapons: Array = DictRead.as_array(_balance.get("weapons", []))
	for entry: Variant in weapons:
		var row: Dictionary = entry
		if DictRead.as_int(row["id"]) == 0:
			return DictRead.as_int(row["mun"])
	return 0


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


## The mission the chain stands on, or `""` when no campaign is running.
##
## Guarded for the same reason [method map_mission] is: the agent's `ui NAME`
## raises a campaign screen from the shell without one ([`92` §7.16]), and
## three of those screens want the mission's own briefing document. Reading
## `state.mission` at the call site is what made that a crash.
func current_mission() -> String:
	return state.mission if state != null else ""


## Player 0's scoreboard row, or an empty one where no campaign is running.
##
## The same guard as [method current_mission], for the same reason and found
## the same way: the debriefing is one of the screens the agent's `ui NAME`
## raises from the shell, and `state.scoreboard[0]` at the call site made that
## a crash. A fresh [ScoreRecord] reads as a mission that scored nothing,
## which is what an unplayed debriefing should show.
func mission_board() -> ScoreRecord:
	return state.scoreboard[0] if state != null else ScoreRecord.new()


## `aCreateLocationMap` -- the locations open with the current mission next.
func open_locations() -> PackedInt32Array:
	if state == null:
		return PackedInt32Array()
	return tables.open_locations(tables.mission_id(state.mission))


## What clicking a location does -- `aLocationHandling` `0x0045C7D0`'s three
## kinds of arm. Returns `{"kind": String, "target": String, "sequence": int}`.
##
## A dialogue location answers the logical sequence id its arm passes; the
## caller raises the framed sequence screen on it (docs/41 section 5; D5 is
## closed since the ninth slice).
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


## What mission control shows on the way in, before the map -- the gate at
## `0x00456FC0` run with -1 (docs/41 section 5, docs/92 section 7.19).
##
## Returns `{"kind": String, "sequence": int, "full_screen": bool}`. The intro
## arm **consumes** the flag, as `0x004570B6` clears it after the sequence, so
## asking twice plays it once; the two endings are decided by the mission id
## alone and are asked as often as the map is raised, which is once.
func opening_sequence() -> Dictionary:
	var none: Dictionary = {"kind": OPENING_NONE, "sequence": -1,
		"full_screen": false}
	if state == null or tables == null:
		return none
	var id: int = tables.mission_id(state.mission)
	if id == INTRO_MISSION_ID:
		if not state.intro_pending:
			return none
		state.intro_pending = false
		return {"kind": OPENING_INTRO, "sequence": INTRO_SEQUENCE,
			"full_screen": true}
	if id == STATIC_EXTRO_MISSION_ID:
		return {"kind": OPENING_STATIC_EXTRO, "sequence": -1,
			"full_screen": true}
	if id == ANIMATED_EXTRO_MISSION_ID:
		return {"kind": OPENING_EXTRO, "sequence": ANIMATED_EXTRO_SEQUENCE,
			"full_screen": true}
	return none


## Whether the mission the campaign stands on is one of the two endings --
## the map is never drawn for those; the credits follow.
func at_an_ending() -> bool:
	if state == null or tables == null:
		return false
	var id: int = tables.mission_id(state.mission)
	return id == STATIC_EXTRO_MISSION_ID or id == ANIMATED_EXTRO_MISSION_ID


# -- entering a mission --------------------------------------------------------

## `aCopyUnitPool(0, 1)` at `0x0045A914` -- the mission-entry snapshot.
##
## Taken **before** deployment, which is what makes the debriefing's *replay*
## button restore the squad as it was, rather than as it ended.
func begin_mission(mission_world: World) -> void:
	if state == null:
		return
	# **Re-entering a mission that was already begun.** The briefing raised
	# over the deployment screen carries its own *Continue*, and that rebuilds
	# the mission's scene -- so whoever was already standing on the old map
	# goes with it, and they had been taken out of the live row to get there.
	# Without putting them back first the snapshot below would freeze the
	# depleted row, and the squad was then lost for good: the map's own
	# `aCopyUnitPool(1, 0)` had nothing left to restore.
	if state.roster.used_slots(Roster.ROW_SNAPSHOT) > 0:
		state.roster.restore()
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


## Whether the pool holds nobody at all to put on the map.
##
## **A chain can start this way by design.** `aCreateUnitPoolForCampaign(2)`
## is a bare return, so campaign 2 begins with an empty pool and `_C_140`
## places its own squad; the debriefing then recovers that squad into the pool
## and every mission after it deploys normally. Of the 75 campaign missions
## only 31 ship a player-0 squad (docs/98), and those 31 are exactly where
## this can be true.
##
## [SliceMain] uses it to skip the deployment screen rather than to refuse
## anything: a screen offering a roster of nobody, a map of dots nobody can
## stand on and one button was read as the campaign being broken.
func nobody_to_deploy() -> bool:
	if state == null:
		return true
	return state.roster.occupied_slots().is_empty()


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


## Leaving the deployment screen for the map without starting the sortie.
##
## `aCopyUnitPool(1, 0)` again -- the same call the debriefing's *replay*
## makes, for the same reason: whoever has already been put on the map has
## been **taken out of the pool** (docs/27 section 3.4), and the map screen
## then takes the mission's whole scene down. Without this, backing out of a
## deployment cost the campaign every soldier already standing on it.
##
## Only from [constant SCREEN_SELECT]: it is the one screen where the squad
## can be on a map that has not been played.
func abandon_mission() -> void:
	if state == null:
		return
	# **Whenever a mission is left without finishing it**, not only from the
	# deployment screen. The map frees the mission's scene either way, and
	# everyone standing in it had been taken out of the live row to get there
	# -- so a mission abandoned from any other screen left the squad nowhere:
	# the roster came back empty and the next location had nobody to deploy.
	if screen == SCREEN_SELECT or screen == SCREEN_MISSION:
		state.roster.restore()
		state.roster.clear_snapshot()
		_mission_world = null
	screen = SCREEN_MAP


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
##
## Only a win may move the campaign's current mission. The next-map name is
## present on a defeated world's header too, so checking that it exists would
## turn a loss into progress and open the next location.
func advance() -> String:
	if state == null:
		return ""
	var result: int = DictRead.as_int(last_report.get("result",
		ScoreRecord.RESULT_NOTHING))
	if result < ScoreRecord.RESULT_WON \
			or result > ScoreRecord.RESULT_WON_GLORIOUS:
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

## The Unit Menu's *Recruit unit*. *unit_type* is the Recruit window's choice
## and -1 the campaign's own, which is `aEnlargeUnitPool`'s `type = player`.
func recruit(unit_type: int = -1) -> int:
	if state == null:
		return Roster.NO_SLOT
	var health: int = 0
	if unit_type >= 0:
		health = DictRead.as_int(row_for("units", unit_type).get("hp_max", 0))
	return state.recruit(0, _draw_speech(), unit_type, health)


## Whether the Unit Menu's *Recruit unit* opens the Recruit window or hires on
## the spot -- `0x0045B7F8`'s game-mode gate. A campaign hires on the spot.
func recruits_through_a_screen() -> bool:
	return state != null and state.mode != TurnState.MODE_CAMPAIGN


func dismiss(slot: int) -> int:
	if state == null:
		return 0
	return state.dismiss(0, slot, weapon_costs())


## The Upgrade screen's *Buy Item*, for either half of the catalogue.
func buy(kind: String, slot: int, id: int) -> Dictionary:
	if state == null:
		return {"result": Upgrade.NO_UNIT, "cost": 0, "skill_points": 0}
	var row: Dictionary = row_for(kind, id)
	if row.is_empty():
		return {"result": Upgrade.BAD_ID, "cost": 0, "skill_points": 0}
	if kind == KIND_WEAPONS:
		return state.buy_weapon(0, slot, id, weapon_costs(), row)
	return state.buy_equipment(0, slot, id, row)


## `id -> cost`, from the balance tables. Built once per call rather than
## cached, because the tables are small and a stale copy would misprice a sale.
func weapon_costs() -> Dictionary:
	var out: Dictionary = {}
	for entry: Variant in DictRead.as_array(_balance.get("weapons", [])):
		var row: Dictionary = entry
		out[DictRead.as_int(row["id"])] = DictRead.as_int(row["cost"])
	return out


## The balance table one half of the catalogue comes from.
func table(kind: String) -> Array:
	return DictRead.as_array(_balance.get(kind, []))


## One row of it, by id -- **by id and not by position**: `equipment` has no
## id 2, so the two differ from there on (D12).
func row_for(kind: String, id: int) -> Dictionary:
	for entry: Variant in table(kind):
		var row: Dictionary = entry
		if DictRead.as_int(row["id"]) == id:
			return row
	return {}


## The catalogue as the Item List draws it: every row the tech level allows,
## each carrying what it would cost **this soldier** and whether they can have
## it.
##
## `skills` is [method Upgrade.weapon_skill_cost] or its equipment twin -- the
## shortfall against this record, which is the number the original prints in
## the row and the number the purchase charges. With no soldier selected the
## row still lists, with the shortfall measured against an untrained one, so
## the screen is never empty for want of a selection.
func catalogue_rows(kind: String, unit: UnitState) -> Array[Dictionary]:
	var probe: UnitState = unit if unit != null else UnitState.new()
	var purse: int = state.points(0) if state != null else 0
	var out: Array[Dictionary] = []
	for entry: Variant in DictRead.as_array(catalogue(kind)["available"]):
		var row: Dictionary = entry
		var id: int = DictRead.as_int(row["id"])
		var cost: int = DictRead.as_int(row["cost"])
		var skills: int = Upgrade.weapon_skill_cost(row, probe) \
			if kind == KIND_WEAPONS \
			else Upgrade.equipment_skill_cost(row, probe)
		var carried: bool = probe.weapon == id if kind == KIND_WEAPONS \
			else probe.has_equipment(id)
		out.append({
			"id": id,
			"kind": kind,
			"name": DictRead.as_string(row["name"]),
			"cost": cost,
			"icon": DictRead.as_int(row["icon"]),
			"skills": skills,
			"carried": carried,
			# Red in the original: what the soldier cannot be given now.
			"affordable": cost <= purse
				and skills * Upgrade.TP_PER_SKILL_POINT <= probe.tp,
		})
	return out


## docs/27 section 5.2 -- the catalogue the tech level gates, and what is
## locked. Returns `{"available": Array, "locked": Array}` so a screen can show
## both: a filter that silently hid the rest would make a frozen tech level
## indistinguishable from a working one.
##
## **The range is a range, and in a campaign it is the base's own.**
## `0x0045AF21` reads `0x00510A34`/`0x00510A35` as a word for the two list
## builders -- `0x0047A090` (equipment) and `0x0047A1B0` (weapons), the
## routines the Upgrade Menu's arrows step with -- and each accepts a record
## whose requirement byte satisfies `low <= b <= high`. Where that word comes
## from is `0x0045BF2A`, and it has **two arms**: outside a campaign it is
## `0` and the tech level (`0x0045BF44`, `0x0045BF4B`), and inside one it is
## `0x00510C5C`/`0x00510C5D`, which the entered location's own arm wrote --
## see [method CampaignMap.tech_band]. So the shop is per base, and the
## campaign tech level gates nothing at all.
##
## **And a record with no name is in neither half.** Before either builder
## looks at the range it compares the record's name against the empty string
## at `0x004FA524` and steps past a match (`0x0047A1DD` weapons,
## `0x0047A0BD` equipment).
##
## **Nor is a record past [constant CATALOGUE_ID_MAX].** That third test is the
## one this read wrongly twice: it is in the *forward* stepper only, three
## instructions past the range, and the backward twin does without it because
## its caller starts it at 18. Missing it put the ten alien weapons and the
## `"-"` placeholder in the shop -- with `Item_w0.lib` for a picture, since
## they all carry icon 0 -- which the original never shows.
## The tech band the catalogue is gated on -- the entered base's, or the
## campaign tech level where there is no base (an *Instant Action* squad, or a
## location that names no arm).
func catalogue_band() -> Vector2i:
	if tables != null:
		var band: Vector2i = tables.tech_band(location)
		if band.x >= 0:
			return band
	return Vector2i(CATALOGUE_LOW, state.tech_level if state != null else 0)


func catalogue(kind: String) -> Dictionary:
	var available: Array[Dictionary] = []
	var locked: Array[Dictionary] = []
	var band: Vector2i = catalogue_band()
	for entry: Variant in DictRead.as_array(_balance.get(kind, [])):
		var row: Dictionary = entry
		if DictRead.as_string(row.get("name", "")) == "":
			continue
		if DictRead.as_int(row["id"]) >= DictRead.as_int(
				CATALOGUE_ID_MAX.get(kind, 0)):
			continue
		var needs: int = DictRead.as_int(row.get("tech", 0))
		if needs >= band.x and needs <= band.y:
			available.append(row)
		else:
			locked.append(row)
	return {"available": available, "locked": locked}


# -- the save file -------------------------------------------------------------

## The file one slot lives in. [constant QUICK_SLOT] is the quick save;
## `0..SLOT_COUNT - 1` are the numbered ones.
func slot_path(slot: int = QUICK_SLOT) -> String:
	if slot == QUICK_SLOT:
		return "%s/%s" % [save_dir, QUICK_NAME]
	return "%s/%s" % [save_dir, SLOT_NAME % slot]


## A save is assembled beside its slot and moved over it only after the bytes
## read back exactly.  A full disk or a short write must leave the previous
## slot untouched, rather than truncate it and still report success.
const SAVE_TEMP_SUFFIX: String = ".writing"


## Write the campaign, and optionally the mission in progress.
##
## The mission blob is [SaveCodec]'s and stays opaque here: that codec refuses
## a blob whose map name is not the world's, which is right for a mission save
## and wrong for a campaign container (D10).
##
## *when* and *when_text* are the stamp the slot row shows. They come from the
## caller because `core` may not call `Time` and the codec is `core`'s
## (`godot/tests/test_isolation.gd`); [method stamp_now] is the one place in
## `game/` that reads the clock. *scenery* is [method Scenery.pose_record]
## and *camera* [method CameraRig.state] -- the picture's own state the
## mission blob carries beside the simulation, both outside the canonical
## hash because `core` owns neither.
## *name* is what the player typed on the slot screen, or `""` for a save that
## was never named -- the quick save, and a numbered slot written with the
## field left empty. It rides in the container's document and not in
## [CampaignState], which is hashed.
func save(mission_world: World = null, slot: int = QUICK_SLOT,
		when: int = 0, when_text: String = "",
		scenery: Dictionary = {}, camera: Dictionary = {},
		name: String = "") -> bool:
	if state == null:
		return false
	var blob: PackedByteArray = PackedByteArray()
	if mission_world != null:
		blob = mission_world.save(camera, scenery)
	var made: Error = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(save_dir))
	if made != OK and made != ERR_ALREADY_EXISTS:
		return false
	var target: String = slot_path(slot)
	var temporary: String = target + SAVE_TEMP_SUFFIX
	var bytes: PackedByteArray = CampaignCodec.encode(
		state, blob, when, when_text, name)
	if FileAccess.file_exists(temporary):
		var removed: Error = DirAccess.remove_absolute(
			ProjectSettings.globalize_path(temporary))
		if removed != OK:
			return false
	var file: FileAccess = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK or FileAccess.get_file_as_bytes(temporary) != bytes:
		var _discarded: Error = DirAccess.remove_absolute(
			ProjectSettings.globalize_path(temporary))
		return false
	var moved: Error = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temporary),
		ProjectSettings.globalize_path(target))
	if moved != OK:
		var _discarded: Error = DirAccess.remove_absolute(
			ProjectSettings.globalize_path(temporary))
		return false
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
## "score": int, "saved_at": int, "saved_at_text": String, "name": String,
## "has_mission": bool}`.
##
## A row for a file this build cannot read is **shown**, carrying its refusal
## code, rather than being hidden -- a slot that vanished because the schema
## moved would look like a slot the player never used.
func slot_header(slot: int) -> Dictionary:
	if not has_save(slot):
		return {"result": CampaignCodec.Result.NO_FILE, "used": false,
			"campaign": 0, "mission": "", "score": 0, "saved_at": 0,
			"saved_at_text": "", CampaignCodec.KEY_NAME: "",
			"has_mission": false}
	var header: Dictionary = CampaignCodec.decode_header(
		FileAccess.get_file_as_bytes(slot_path(slot)))
	header["used"] = true
	return header


# -- reporting -----------------------------------------------------------------

## Everything a screen or the agent server needs, as scalars.
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
