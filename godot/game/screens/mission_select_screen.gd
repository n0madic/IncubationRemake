class_name MissionSelectScreen
extends CampaignScreen

## *Instant Action* -- one mission, past the campaign.
##
## The list is the cache manifest's own `missions`, in the order the converter
## emitted them, which is exactly what `--mission=` can already reach. The
## point of the screen is that it is the same set without a command line: a
## cache published with `--campaign-maps` offers all 92, one published with the
## default six offers six, and the screen says which it is rather than pretending
## the rest exist.
##
## A mission entered here has **no campaign state**: no roster to deploy, no
## scoreboard to write, and no next mission -- which is why [method
## SliceMain._check_mission_end] correctly does nothing when one ends.

## `Txtmod_a` 111 -- *Found Maps:*, the caption the original's own map list
## carries.
const ID_FOUND: int = 111
## How many rows fit before the list is worth scrolling. The catalogue is 92
## long when the cache carries the campaign.
const LIST_HEIGHT: float = 300.0

var missions: PackedStringArray = PackedStringArray()


func build() -> void:
	var title: Label = make_label("%s  %s" % [
		label_for(BANK_MENU, MainMenuScreen.ID_INSTANT_ACTION),
		label_for(BANK_MENU, ID_FOUND)])
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.position = Vector2(8.0, 32.0)
	scroll.custom_minimum_size = Vector2(400.0, LIST_HEIGHT)
	body().add_child(scroll)
	var list: VBoxContainer = VBoxContainer.new()
	scroll.add_child(list)
	for name: String in missions:
		list.add_child(make_button("mission:" + name, name))

	add_button("back", BANK_MISSION, ID_BACK, 0)
