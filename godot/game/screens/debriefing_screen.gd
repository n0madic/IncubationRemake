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
## full roster had no slot for, are both listed rather than simply gone.

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

var report: Dictionary = {}
var board: ScoreRecord = null


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
	for entry: Variant in DictRead.as_array(report.get("lost", [])):
		var row: Dictionary = entry
		var line: Label = make_label("%s -- %s" % [
			DictRead.as_string(row["name"]),
			DictRead.as_string(row["reason"])])
		line.add_theme_color_override("font_color", BriefingText.RAMP_ALERT)
		squad.add_child(line)

	add_button("advance", BANK_REPORT, ID_CONTINUE_BUTTON, 0)
	add_button("replay", BANK_REPORT, ID_TRY_AGAIN, 1)


func _pair(grid: GridContainer, id: int, mission_half: int,
		campaign_half: int) -> void:
	grid.add_child(make_label(label_for(BANK_REPORT, id)))
	grid.add_child(make_label(str(mission_half)))
	grid.add_child(make_label(str(campaign_half)))
