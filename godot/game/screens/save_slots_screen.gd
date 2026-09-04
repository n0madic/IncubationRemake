class_name SaveSlotsScreen
extends CampaignScreen

## The eight numbered slots -- `aLoad.cpp`'s screen, which is what `Txtmod_f`
## is the bank for.
##
## One screen, two modes: [constant ShellHost.MODE_LOAD] and
## [constant ShellHost.MODE_SAVE]. The rows are the same eight either way and
## only what a click does changes -- a screen that could do both from one row
## would eventually overwrite a save with a click meant to load it.
##
## **A row is built from the container's header alone.** [method
## CampaignCodec.decode_header] reads the campaign, the mission, the score and
## the stamp without unrolling the roster, the scoreboard or the mission blob:
## eight rows must not cost eight campaigns.
##
## A slot this build cannot read is **shown, carrying its refusal**, not
## hidden. A save that vanished from the list because the schema moved would
## look exactly like a slot the player never used, and section 7.4 is about
## precisely that kind of silence.

## `Txtmod_f`, the load/save bank (`aLoad.cpp`).
const BANK_SAVES: String = "Txtmod_f"
const ID_EXIT: int = 0
const ID_EMPTY: int = 1
const ID_LOAD: int = 10
const ID_SAVE: int = 11

## The remake's own: the original numbered its slots in the picture, not in a
## string, and none of the shipped banks carries a row heading.
const OWN_SLOT: String = "shell.slot"
const OWN_NO_MISSION: String = "shell.no_mission"

var host: CampaignHost = null
## [constant ShellHost.MODE_LOAD] or [constant ShellHost.MODE_SAVE].
var mode: String = ShellHost.MODE_LOAD
## True while there is a campaign to write, which is what makes the save mode
## meaningful. A row that offered to save nothing would be inert.
var may_save: bool = false

var _list: VBoxContainer = null


func build() -> void:
	var title: Label = make_label(label_for(BANK_SAVES,
		ID_SAVE if mode == ShellHost.MODE_SAVE else ID_LOAD))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	_list = VBoxContainer.new()
	_list.position = Vector2(8.0, 32.0)
	body().add_child(_list)
	refresh()

	add_button("back", BANK_SAVES, ID_EXIT, 0)


func refresh() -> void:
	if _list == null:
		return
	clear_children(_list)
	for slot: int in range(CampaignHost.SLOT_COUNT):
		var row: Button = make_button("slot:%d" % slot, _caption(slot))
		# Loading an empty slot is the one click in this screen that can have
		# nothing behind it, so it is refused at the row rather than reported
		# afterwards.
		if mode == ShellHost.MODE_LOAD:
			row.disabled = host == null or not host.has_save(slot)
		else:
			row.disabled = not may_save
		_list.add_child(row)


## `Slot N  <what is in it>`.
func _caption(slot: int) -> String:
	var pattern: String = strings_own(OWN_SLOT)
	var name: String = pattern % (slot + 1) if pattern.contains("%d") \
		else pattern
	if host == null:
		return "%s  %s" % [name, label_for(BANK_SAVES, ID_EMPTY)]
	var header: Dictionary = host.slot_header(slot)
	var code: int = DictRead.as_int(header["result"])
	if code == CampaignCodec.Result.NO_FILE:
		return "%s  %s" % [name, label_for(BANK_SAVES, ID_EMPTY)]
	if code != CampaignCodec.Result.OK:
		# **Named through the matching table.** `CampaignCodec.Result` and
		# `SaveCodec.Result` do not agree numerically -- `TRUNCATED` is 3 here
		# and 1 there -- so a slot's refusal must be spelled by the codec that
		# refused it.
		return "%s  %s" % [name, CampaignCodec.result_name(code)]
	var pattern_campaign: String = strings_own(
		CampaignSelectScreen.OWN_CAMPAIGN)
	var chain: int = DictRead.as_int(header["campaign"])
	var chain_text: String = pattern_campaign % chain \
		if pattern_campaign.contains("%d") else pattern_campaign
	var mission: String = DictRead.as_string(header["mission"])
	if not DictRead.as_bool(header["has_mission"]):
		# On the map, in the roster, at a briefing: the container carries the
		# campaign and no world.
		mission = "%s (%s)" % [mission, strings_own(OWN_NO_MISSION)]
	return "%s  %s  %s  %d  %s" % [name, chain_text, mission,
		DictRead.as_int(header["score"]),
		DictRead.as_string(header[CampaignCodec.KEY_SAVED_AT_TEXT])]
