class_name ExtroScreen
extends CampaignScreen

## The static extro -- mission id 180, `0x00457430`: `Graphics/Ship.bmp` whole,
## `Briefing/extro.wav` playing, and `Menu_b.lcl`'s window 11 (`:SlideShow;`)
## with its one live button, `Txtmod_b` 4 *Continue* at (450, 430), six tiles
## wide. *Continue* (`0x0045BD7F`) raises the credits flag and the wave stops
## with the screen (docs/41 section 4, docs/92 section 7.19).
##
## The wave is the host's to play: this layer has no audio of its own beyond
## the buttons' clicks, and what starts a sound must be what stops it.

const PLATE_SHIP: String = "ship"
const ID_CONTINUE_BUTTON: int = 4
const CONTINUE_AT: Vector2 = Vector2(450.0, 430.0)
## The cache-relative path of the soundtrack the host plays.
const WAVE: String = "audio/briefing/extro.wav"
## What the host hears.
const CONTINUE: String = "continue"


func plate_name() -> String:
	return PLATE_SHIP


func build() -> void:
	var _go: Button = gui_button(CONTINUE, BANK_MISSION, ID_CONTINUE_BUTTON,
		CONTINUE_AT)
