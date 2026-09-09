class_name CreditsScreen
extends CampaignScreen

## `Menu_a.lcl`'s `:Credits;` block on `Graphics/Credits.bmp`: two buttons,
## `Txtmod_a` 7 *Exit Game* at (450, 410) and 8 *Back* at (250, 410), both
## six tiles wide, and CD program `"8"` (`0x0044C050`). Reached after both
## endings -- the animated extro's 4000 ms hold and the static extro's
## *Continue* both raise the flag `0x0044BC60` writes -- and *Back* is the
## main menu (docs/92 section 7.19).

const PLATE_CREDITS: String = "credits"
const ID_EXIT_GAME: int = 7
const ID_BACK_TO_MENU: int = 8
const EXIT_AT: Vector2 = Vector2(450.0, 410.0)
const BACK_AT: Vector2 = Vector2(250.0, 410.0)
## What the host hears.
const QUIT: String = "quit"
const BACK: String = "back"


func plate_name() -> String:
	return PLATE_CREDITS


func build() -> void:
	var _exit: Button = gui_button(QUIT, BANK_MENU, ID_EXIT_GAME, EXIT_AT)
	var _back: Button = gui_button(BACK, BANK_MENU, ID_BACK_TO_MENU, BACK_AT)
