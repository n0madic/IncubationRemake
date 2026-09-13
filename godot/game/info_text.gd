class_name InfoText
extends RefCounted

## `Events.txt` -- what a pickup says, and which pickup says what.
##
## docs/26 section 3: thirteen of `aExecuteUse`'s arms hand a two-character
## label to the shared pickup sequence `0x00410780`, which opens the info file
## by its literal name `"Events"` (`0x004C1304`), draws it through
## `aActivateInfo` `0x0043E740` and plays `box.wav`. The remake had the sound
## and not the message, so a crate opened with nothing to show for it.
##
## **Everything here is read, nothing is transcribed.** The text is
## `text/info/events.json`, written as spans by
## `inclib.convert.convert_info_events` exactly as a briefing block is, so this
## class renders and never re-parses the markup (docs/92 section 3.2); and the
## action-point-to-label map in the same document is
## `interaction_tables.InteractionTables.cases()`'s own decoding of the switch,
## so there is no second copy of it here to disagree by a swapped pair. The
## twelve arms that also speak are the twelve that call `0x0047B660`, which is
## the same decoding and not a rule about which id is quiet.

## Where the cache keeps it.
const DOCUMENT: String = "text/info/events.json"
const SCHEMA: String = "incubation.info/1"

## docs/24 section 7.2 -- `0x004107A2`..`0x00410793` push `230, 200, 180, 400`
## as the box's `x, y, w, h` in the plate's own 640x480. The height is a
## layout bound and not a drawn rectangle: the shipped `B0` box is
## `220, 120, 200, 500` and overshoots the screen the same way.
const BOX_AT: Vector2 = Vector2(230.0, 200.0)
const BOX_SIZE: Vector2 = Vector2(180.0, 400.0)

## What the decoder writes for an arm that calls no voice routine.
const NO_SPEECH: int = -1
## `text/info/data.json` -- the item, weapon and unit descriptions the Upgrade
## Menu's *i* opens (`0x00432B20/70/D0`).
const DATA_DOCUMENT: String = "text/info/data.json"
## `0x00432B86` -- a record whose letter is this has no page.
const NO_PAGE: String = "#"
## The label `0x0043E850` retries with when the composed one has no block
## (`0x0043E910`: two literal `'*'`s, whatever the family was). `Data.txt`
## carries it, and it reads *No information available.*
const FALLBACK_LABEL: String = "**"
## The box the magnifier's page is drawn in: `0x00432B3D`..`0x00432B4C` push
## `230, 200, 180, 300` -- the pickup's rectangle with a shorter height bound.
const DATA_BOX_SIZE: Vector2 = Vector2(180.0, 300.0)

var _blocks: Dictionary = {}
var _families: Dictionary = {}
var _no_page: String = NO_PAGE
## action point -> `{"label": String, "speech": int}`, out of the document.
var _pickups: Dictionary[int, Dictionary] = {}


## The document, or an empty reader when the cache has none -- a cache made
## before the converter grew this document still loads, and the box is then
## the one thing missing rather than the mission.
static func load_from(paths: CachePaths,
		document: String = DOCUMENT) -> InfoText:
	var out: InfoText = InfoText.new()
	out.read(CacheLoader.read_json(paths.path(document)))
	return out


## The same from a document already in hand, so a suite can hand one over.
func read(document: Dictionary) -> void:
	_blocks = {}
	_pickups = {}
	_families = {}
	_no_page = NO_PAGE
	if DictRead.as_string(document.get("schema", "")) != SCHEMA:
		return
	_blocks = DictRead.as_dict(document.get("blocks", {}))
	_families = DictRead.as_dict(document.get("families", {}))
	_no_page = DictRead.as_string(document.get("no_page", NO_PAGE))
	for entry: Variant in DictRead.as_array(document.get("pickups", [])):
		var record: Dictionary = DictRead.as_dict(entry)
		_pickups[DictRead.as_int(record.get("action_point", -1))] = {
			"label": DictRead.as_string(record.get("label", "")),
			"speech": DictRead.as_int(record.get("speech", NO_SPEECH)),
		}


## Every action point that shows a message, in id order.
func action_points() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array(_pickups.keys())
	out.sort()
	return out


## The label an action point shows, or `""` for an arm that shows nothing --
## the doors, the levers, the entry point and every id outside the switch.
func label_for(action_point: int) -> String:
	if not _pickups.has(action_point):
		return ""
	return DictRead.as_string(_pickups[action_point]["label"])


## Whether that arm also speaks: the twelve `0x0047B660` sites of docs/28
## section 4.3, all of them argument 9. *Found nothing* is the one pickup with
## no voice line, and that is read out of its arm rather than written here.
func speaks(action_point: int) -> bool:
	if not _pickups.has(action_point):
		return false
	return DictRead.as_int(_pickups[action_point]["speech"]) != NO_SPEECH


## The speech argument the arm pushes, or [constant NO_SPEECH].
func speech_argument(action_point: int) -> int:
	if not _pickups.has(action_point):
		return NO_SPEECH
	return DictRead.as_int(_pickups[action_point]["speech"])


## Every pickup whose label is not the one its position in id order asks for.
##
## The thirteen arms take the thirteen labels **in id order** -- `E0`..`E9`,
## then `EA`, `EB`, `EC` -- so this is the whole map stated without a copy of
## it, and a pair swapped anywhere between the switch and this reader shows up
## here. A check on the label *set* cannot see such a swap, which is why this
## exists beside it.
func labels_out_of_order() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var points: PackedInt32Array = action_points()
	for i: int in range(points.size()):
		var want: String = "E%X" % i
		if label_for(points[i]) != want:
			out.append("%d -> %s, wanted %s"
				% [points[i], label_for(points[i]), want])
	return out


## The digit `Data.txt`'s labels append for one family -- `0` a unit, `1`
## equipment, `2` a weapon (`0x00432B20`, `0x00432B70`, `0x00432BD0`). Read out
## of the document rather than written here, so the game side carries no table
## the converter could disagree with.
func family_digit(family: String) -> String:
	return DictRead.as_string(_families.get(family, ""))


## The letter that means "this record has no page" (`0x00432B86`).
func no_page() -> String:
	return _no_page


## Whether this document can answer a unit page at all.
##
## `convert_info_data` writes the families and an **empty** block map when
## `Data.txt` decodes but carries no `{:xy}` label -- a warning, not a failure
## -- and a cache made before the converter grew the document answers nothing.
## Either way there is no page to open, and the caller's business is to keep
## the button dark rather than to light one that does nothing when it is
## pressed ([code]SliceMain._event_available[/code]).
func has_unit_pages() -> bool:
	return family_digit("units") != "" and not _blocks.is_empty()


## What the magnifier shows for a unit type, by the type's own letter.
##
## docs/43 section 5.2: `0x00432B20` composes the label out of the letter at
## `0x0051C09D` and the family digit `0`, and hands it to `0x0043E850`, which
## retries with [constant FALLBACK_LABEL] when there is no such block. **The
## unit path tests nothing else** -- unlike `0x00432B86` and `0x00432BE4`,
## which refuse an item whose letter is [constant NO_PAGE] before they open
## the file at all -- so a `#` and a letter with no page both come back as the
## fallback's *No information available.* rather than as nothing.
func unit_page(key: String) -> Array:
	var digit: String = family_digit("units")
	if digit == "":
		return []
	var page: Array = spans(key + digit)
	if page.is_empty():
		page = spans(FALLBACK_LABEL)
	return page


func has(label: String) -> bool:
	return _blocks.has(label)


func spans(label: String) -> Array:
	return DictRead.as_array(_blocks.get(label, []))


## What one action point shows, `[]` when it shows nothing.
func spans_for(action_point: int) -> Array:
	return spans(label_for(action_point))
