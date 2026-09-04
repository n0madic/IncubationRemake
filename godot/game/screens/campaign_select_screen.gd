class_name CampaignSelectScreen
extends CampaignScreen

## Which of the two chains a new campaign runs -- docs/27 section 8.
##
## `tables/campaign.json` carries both as records: campaign 1 opens at `_C_100`
## on `_C_XXX` and seeds Bratt, West and Maxon; campaign 2 opens at `_C_140` on
## `_C_YYY` and seeds **nothing**, because `aCreateUnitPoolForCampaign(2)` is a
## bare `return TRUE` -- its opening squad is the four units the mission places
## itself.
##
## Neither chain has a shipped name. What each row is captioned with instead is
## the **location** its first mission sits at, out of `Campaign.lcl` -- a
## shipped string that says what the chain opens on rather than a number.

## The remake's own: neither chain is named in any shipped bank.
const OWN_CAMPAIGN: String = "shell.campaign"

var host: CampaignHost = null


func build() -> void:
	var title: Label = make_label(label_for(BANK_MENU,
		MainMenuScreen.ID_START_CAMPAIGN))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	var list: VBoxContainer = VBoxContainer.new()
	list.position = Vector2(8.0, 40.0)
	body().add_child(list)
	for number: int in CampaignState.FIRST_MISSION:
		list.add_child(make_button("start:%d" % number, _caption(number)))

	add_button("back", BANK_MISSION, ID_BACK, 0)


## `Campaign N -- <where it opens>`, both halves from the catalogue.
##
## The location comes from the tables rather than from a second list here: the
## chain's first mission is in `CampaignState.FIRST_MISSION` and the location
## graph knows which location that mission is at, so the caption cannot drift
## away from the map the chain actually opens on.
func _caption(number: int) -> String:
	# The pattern carries the number, so a language that puts it elsewhere can
	# say so. A catalogue that has no line for the key gives back the marker,
	# which has no `%d` in it -- formatting that would be a crash, so it is
	# tested for rather than assumed.
	var pattern: String = strings_own(OWN_CAMPAIGN)
	var name: String = pattern % number if pattern.contains("%d") else pattern
	var mission: String = DictRead.as_string(
		CampaignState.FIRST_MISSION.get(number, ""))
	if host == null or host.tables == null or mission == "":
		return name
	if not host.tables.has_mission(mission):
		return name
	var location: int = host.tables.location_of(
		host.tables.mission_id(mission))
	return "%s  --  %s" % [name, label_for(BANK_LOCATIONS, location)]
