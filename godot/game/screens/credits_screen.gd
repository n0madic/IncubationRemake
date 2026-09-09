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
## **Namespaced, and it has to be.** The host routes every screen through one
## `match` on the action string, and this arm stands ahead of the `"back"` the
## Item List, the Recruit window and the Unit Menu share. Spelled `back` it
## shadowed all three: leaving the catalogue ran the credits' own arm, which
## is `_end_campaign()` -- the campaign dropped and the boot menu up, with the
## progress since the last save gone. The sibling screens' own verbs
## (`splash_done`, `sequence_done`, `fly_in_done`) are prefixed for the same
## reason; do not "simplify" this one back.
const BACK: String = "credits_back"


func plate_name() -> String:
	return PLATE_CREDITS


func build() -> void:
	var _exit: Button = gui_button(QUIT, BANK_MENU, ID_EXIT_GAME, EXIT_AT)
	var _back: Button = gui_button(BACK, BANK_MENU, ID_BACK_TO_MENU, BACK_AT)
