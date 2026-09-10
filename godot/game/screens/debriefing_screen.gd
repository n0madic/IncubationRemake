class_name DebriefingScreen
extends CampaignScreen

## docs/27 section 6.1's screen, and what its four buttons carry.
##
## The scoreboard is shown as the engine shows it: **four pairs**, each "In
## Mission" beside "In Campaign" (`Txtmod_d` 30 and 31), which is what named
## the record's four unknown fields.
##
## The two silent refusals of docs/27 section 3.4 are **named here**
## (docs/92 section 7.4): a survivor that was not a pool candidate, and one the
## full roster had no slot for, are both listed rather than simply gone -- in
## words, and only the second in the alert ramp.

const ID_TITLE: int = 10
const ID_KILLS: int = 20
const ID_LOSSES: int = 21
const ID_COMMENDATIONS: int = 22
const ID_RESULT: int = 23
const ID_IN_MISSION: int = 30
const ID_IN_CAMPAIGN: int = 31
const ID_EQUIPMENT_POINTS: int = 45
const ID_CONTINUE_BUTTON: int = 2
const ID_TRY_AGAIN: int = 3
## `Txtmod_d` 14..19, by mission result.
const ID_RESULT_TEXT: Array[int] = [19, 15, 16, 17, 14]
## What the two refusals say. The original says neither, so both are the
## remake's own strings ([Localization]).
const KEY_GUEST: String = "debriefing.guest"
const KEY_SQUAD_FULL: String = "debriefing.squad_full"

var report: Dictionary = {}
var board: ScoreRecord = null
## Instant Action has no campaign map or next mission. Its report returns to
## the level catalogue while keeping the ordinary retry.
var instant_action: bool = false


func build() -> void:
	var title: Label = make_label(label_for(BANK_REPORT, ID_TITLE))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	var outcome: int = DictRead.as_int(report.get("result", 1))
	var verdict: Label = make_label(label_for(BANK_REPORT,
		ID_RESULT_TEXT[clampi(outcome - 1, 0, ID_RESULT_TEXT.size() - 1)]))
	verdict.position = Vector2(8.0, 30.0)
	body().add_child(verdict)

	var grid: GridContainer = GridContainer.new()
	grid.columns = 3
	grid.position = Vector2(8.0, 64.0)
	grid.add_theme_constant_override("h_separation", 28)
	body().add_child(grid)
	grid.add_child(make_label(""))
	grid.add_child(make_label(label_for(BANK_REPORT, ID_IN_MISSION)))
	grid.add_child(make_label(label_for(BANK_REPORT, ID_IN_CAMPAIGN)))
	_pair(grid, ID_KILLS, board.kills, board.campaign_kills)
	_pair(grid, ID_LOSSES, board.losses, board.campaign_losses)
	_pair(grid, ID_RESULT, board.score, board.total)

	var paid: VBoxContainer = VBoxContainer.new()
	paid.position = Vector2(8.0, 176.0)
	body().add_child(paid)
	paid.add_child(make_label("%s %d" % [
		label_for(BANK_REPORT, ID_EQUIPMENT_POINTS),
		DictRead.as_int(report.get("equipment_points", 0))]))
	paid.add_child(make_label("%s %d" % [
		label_for(BANK_REPORT, ID_COMMENDATIONS),
		DictRead.as_int(report.get("commendations", 0))]))

	var squad: VBoxContainer = VBoxContainer.new()
	squad.position = Vector2(320.0, 64.0)
	body().add_child(squad)
	for entry: Variant in DictRead.as_array(report.get("recovered", [])):
		var row: Dictionary = entry
		squad.add_child(make_label(DictRead.as_string(row["name"])))
	# **Named, not silent.** The engine drops both of these without a word.
	#
	# The two are not the same news, though, and saying them the same way read
	# as a fault: a **guest** who does not join the squad is the ordinary end
	# of an escort -- all 26 of the shipped `pool_flag == 0` records a
	# campaign mission places for player 0 are named story characters -- while
	# a survivor left behind by a full squad is a soldier lost. So the guest
	# is written in the ordinary ink and only the loss takes the alert ramp,
	# and neither prints the reason's own identifier.
	for entry: Variant in DictRead.as_array(report.get("lost", [])):
		var row: Dictionary = entry
		var reason: String = DictRead.as_string(row["reason"])
		# An unknown reason keeps its id rather than borrowing a sentence
		# that would be wrong: a new refusal has to be given words here.
		var said: String = reason
		var key: String = reason_key(reason)
		if key != "":
			said = strings_own(key)
		var line: Label = make_label("%s -- %s" % [
			DictRead.as_string(row["name"]), said])
		if reason != MissionEnd.DROP_NOT_CANDIDATE:
			line.add_theme_color_override("font_color", BriefingText.RAMP_ALERT)
		squad.add_child(line)

	var button_index: int = 0
	if instant_action:
		add_button("instant_levels", BANK_MISSION, ID_BACK, button_index)
		button_index += 1
		add_button("instant_replay", BANK_REPORT, ID_TRY_AGAIN, button_index)
		return
	if outcome >= ScoreRecord.RESULT_WON \
			and outcome <= ScoreRecord.RESULT_WON_GLORIOUS:
		add_button("advance", BANK_REPORT, ID_CONTINUE_BUTTON, button_index)
		button_index += 1
	add_button("replay", BANK_REPORT, ID_TRY_AGAIN, button_index)


## The words a refusal is written in, or "" for one that has none yet.
static func reason_key(reason: String) -> String:
	if reason == MissionEnd.DROP_NOT_CANDIDATE:
		return KEY_GUEST
	if reason == MissionEnd.DROP_POOL_FULL:
		return KEY_SQUAD_FULL
	return ""


func _pair(grid: GridContainer, id: int, mission_half: int,
		campaign_half: int) -> void:
	grid.add_child(make_label(label_for(BANK_REPORT, id)))
	grid.add_child(make_label(str(mission_half)))
	grid.add_child(make_label(str(campaign_half)))
