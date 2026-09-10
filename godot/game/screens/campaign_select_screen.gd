class_name CampaignSelectScreen
extends CampaignScreen

## Which of the two campaigns a new game runs -- docs/27 section 8.
##
## `tables/campaign.json` carries both as records: campaign 1 opens at `_C_100`
## on `_C_XXX` and seeds Bratt, West and Maxon; campaign 2 opens at `_C_140` on
## `_C_YYY` and seeds **nothing**, because `aCreateUnitPoolForCampaign(2)` is a
## bare `return TRUE` -- its opening squad is the four units the mission places
## itself.
##
## The original front end never offered both at once, so no LCL bank contains
## names for this selector. The GOG distribution does: `Graphics/Title.bmp`
## names the base game and `Install/Title.bmp` names the expansion. The
## converter bakes those two pictures as the cards below, while the readable
## captions use the same product names through the remake's localisation seam.

## Kept for unnamed save-slot metadata; the selector itself uses product names.
const OWN_CAMPAIGN: String = "shell.campaign"
const CAMPAIGN_TITLE: Dictionary = {
	1: "shell.campaign.base",
	2: "shell.campaign.wilderness",
}
const CAMPAIGN_COVER: Dictionary = {
	1: "title",
	2: "wilderness_title",
}

## A remake-owned layout, because the original had no two-product chooser.
## Both cards fit inside `plate_1`'s frame and keep the bottom action row clear.
const CARD_AT: Vector2 = Vector2(60.0, 78.0)
const CARD_SIZE: Vector2 = Vector2(248.0, 282.0)
const CARD_GAP: float = 24.0
const CARD_INSET: float = 6.0
const COVER_ASPECT: float = 4.0 / 3.0
# Keep the base cover where `KEEP_ASPECT_CENTERED` used to draw it inside the
# old 202-unit area. Wilderness is 632x455 rather than 4:3, so `STRETCH_SCALE`
# changes it by only about four percent and makes both campaign covers occupy
# exactly the same rectangle without cropping either picture.
const COVER_TOP: float = 18.5
const COVER_HEIGHT: float = (CARD_SIZE.x - CARD_INSET * 2.0) / COVER_ASPECT
const CAPTION_TOP: float = 218.0

var host: CampaignHost = null


func build() -> void:
	place_title(label_for(BANK_MENU, MainMenuScreen.ID_START_CAMPAIGN))

	var cards: Control = gui_layer()
	var numbers: Array = CampaignState.FIRST_MISSION.keys()
	numbers.sort()
	var buttons: Array[Button] = []
	for index: int in range(numbers.size()):
		var number: int = numbers[index]
		buttons.append(_campaign_card(number, index, cards))
	if buttons.size() == 2:
		buttons[0].focus_neighbor_left = buttons[0].get_path_to(buttons[1])
		buttons[0].focus_neighbor_right = buttons[0].get_path_to(buttons[1])
		buttons[1].focus_neighbor_left = buttons[1].get_path_to(buttons[0])
		buttons[1].focus_neighbor_right = buttons[1].get_path_to(buttons[0])

	add_button("back", BANK_MISSION, ID_BACK, 0)


func _campaign_card(number: int, index: int, into: Control) -> Button:
	# The slot follows the plate layout, but the card inside it does not inherit
	# a non-4:3 window's independent x/y stretch. That keeps the cover, caption
	# and border one proportional object instead of preserving only the cover.
	var slot: AspectRatioContainer = AspectRatioContainer.new()
	slot.name = "CampaignCardSlot%d" % number
	slot.ratio = CARD_SIZE.x / CARD_SIZE.y
	slot.stretch_mode = AspectRatioContainer.STRETCH_FIT
	slot.alignment_horizontal = AspectRatioContainer.ALIGNMENT_CENTER
	slot.alignment_vertical = AspectRatioContainer.ALIGNMENT_CENTER
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place_on_plate(slot,
		CARD_AT + Vector2((CARD_SIZE.x + CARD_GAP) * float(index), 0.0),
		CARD_SIZE)
	into.add_child(slot)

	var card: Button = Button.new()
	card.name = "CampaignCard%d" % number
	card.focus_mode = Control.FOCUS_ALL
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.clip_contents = true
	card.tooltip_text = _campaign_title(number)
	card.pressed.connect(_on_pressed.bind("start:%d" % number))
	arm_sounds(card)
	card.add_theme_stylebox_override("normal",
		_card_style(Color(0.0, 0.0, 0.02, 0.70), INK_DISABLED, 1))
	card.add_theme_stylebox_override("hover",
		_card_style(Color(0.03, 0.08, 0.03, 0.82), INK_ROSTER, 2))
	card.add_theme_stylebox_override("pressed",
		_card_style(Color(0.05, 0.12, 0.05, 0.90), INK_VALUE, 2))
	card.add_theme_stylebox_override("focus",
		_card_style(Color(0.0, 0.0, 0.0, 0.0), INK_ROSTER, 3))
	slot.add_child(card)

	var cover: TextureRect = TextureRect.new()
	cover.name = "CampaignCover%d" % number
	cover.texture = art.plate(DictRead.as_string(
		CAMPAIGN_COVER.get(number, ""))) if art != null else null
	cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover.stretch_mode = TextureRect.STRETCH_SCALE
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.anchor_right = 1.0
	cover.offset_left = CARD_INSET
	cover.offset_top = COVER_TOP
	cover.offset_right = -CARD_INSET
	cover.offset_bottom = COVER_TOP + COVER_HEIGHT
	card.add_child(cover)

	var caption: Label = make_label(_campaign_title(number), 0, FNT_LABEL)
	caption.name = "CampaignTitle%d" % number
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.add_theme_color_override("font_color", INK_TITLE)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.anchor_right = 1.0
	caption.anchor_bottom = 1.0
	caption.offset_left = CARD_INSET
	caption.offset_top = CAPTION_TOP
	caption.offset_right = -CARD_INSET
	caption.offset_bottom = -CARD_INSET
	card.add_child(caption)
	return card


func _campaign_title(number: int) -> String:
	var key: String = DictRead.as_string(CAMPAIGN_TITLE.get(number, ""))
	if key != "":
		return strings_own(key)
	var pattern: String = strings_own(OWN_CAMPAIGN)
	return pattern % number if pattern.contains("%d") else pattern


static func _card_style(background: Color, border: Color,
		width: int) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(width)
	return style
