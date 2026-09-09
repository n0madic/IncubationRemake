class_name MessageScreen
extends CampaignScreen

## `aPrintMessageScreen` `0x0045F290`: `Graphics/MsgScr.bmp` whole, one line
## in `Font_2.lib` centred at (320, 65), colours `0xF79E` / `0x632C`. Both
## callers -- mission control's entry `0x00454007` and the debriefing's exit
## `0x0045D436` -- pass text id 0 of the loaded bank, *Please Wait...*
## (docs/92 section 7.19).
##
## It is shown for at least one drawn frame before the thing it announces is
## built, so a mission's build is a picture rather than a frozen frame. The
## original's own caption is a text id and so is this one; nothing here names
## the mission.

const PLATE_MESSAGE: String = "msgscr"
const ID_PLEASE_WAIT: int = 0
const TEXT_AT: Vector2 = Vector2(320.0, 65.0)
## `0xF79E` in RGB565: nearly white, a touch warm.
const INK_MESSAGE: Color = Color(30.0 / 31.0, 60.0 / 63.0, 30.0 / 31.0)


func plate_name() -> String:
	return PLATE_MESSAGE


func build() -> void:
	var _line: Label = gui_text(label_for(BANK_MISSION, ID_PLEASE_WAIT),
		TEXT_AT, ALIGN_CENTRE, INK_MESSAGE, null, FNT_TITLE)
