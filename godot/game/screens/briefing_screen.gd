class_name BriefingScreen
extends CampaignScreen

## docs/24's three blocks and the mission's picture programme.
##
## `A0` is the briefing, `B0` the victory conditions and `C0` the tips -- the
## same three `Txtmod_b` 30/31/32 name. Six of the 116 shipped `A0`s do not fit
## the box, which is why [BriefingText] scrolls.

## `Txtmod_b` -- 'Briefing', 'Tips', 'Briefing'.
const ID_BRIEFING: int = 30
const ID_TIPS: int = 31
## `Txtmod_b` 11 -- 'Information'. `B0` is the in-mission objective summary;
## the victory and defeat conditions are inside `A0` itself.
const ID_CONDITIONS: int = 11
const ID_ENTER: int = 141
const ID_MAIN_MAP: int = 140

var mission: String = ""
var document: Dictionary = {}
var cache_dir: String = ""

var _text: BriefingText = null


func build() -> void:
	var title: Label = make_label(
		"%s  %s" % [label_for(BANK_MISSION, ID_BRIEFING), mission])
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	# `font` is the interface's, and `null` there means the readable face was
	# chosen -- so the body follows the same decision the headings did instead
	# of always being the shipped 8 px bitmap.
	_text = BriefingText.create(cache_dir, font != null)
	_text.position = Vector2(8.0, 28.0)
	_text.custom_minimum_size = Vector2(520.0, 300.0)
	_text.size = Vector2(520.0, 300.0)
	body().add_child(_text)
	show_block("A0")

	var pictures: Control = Control.new()
	pictures.position = Vector2(540.0, 28.0)
	body().add_child(pictures)
	var top: float = 0.0
	for entry: Variant in DictRead.as_array(document.get("pictures", [])):
		var row: Dictionary = entry
		var name: String = DictRead.as_string(row["picture"])
		if name == "" or art == null:
			continue
		var texture: Texture2D = art.briefing_picture(name)
		if texture == null:
			continue
		var view: TextureRect = TextureRect.new()
		view.texture = texture
		view.position = Vector2(0.0, top)
		view.stretch_mode = TextureRect.STRETCH_KEEP
		pictures.add_child(view)
		top += float(texture.get_height()) + 8.0

	add_button("briefing", BANK_MISSION, ID_BRIEFING, 0)
	add_button("conditions", BANK_MISSION, ID_CONDITIONS, 1)
	add_button("tips", BANK_MISSION, ID_TIPS, 2)
	add_button("enter", BANK_MISSION, ID_ENTER, 3)
	add_button("map", BANK_MISSION, ID_MAIN_MAP, 4)


## One of `A0`, `B0`, `C0`. A block the file does not carry shows empty rather
## than erroring: docs/24 records that not every briefing has all three.
func show_block(key: String) -> void:
	if _text == null:
		return
	var blocks: Dictionary = DictRead.as_dict(document.get("blocks", {}))
	_text.show_block(DictRead.as_array(blocks.get(key, [])))


func scroll(lines: float) -> void:
	if _text != null:
		_text.scroll_by(lines)
