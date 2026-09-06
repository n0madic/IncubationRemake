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

var _blocks: Dictionary = {}
## action point -> `{"label": String, "speech": int}`, out of the document.
var _pickups: Dictionary[int, Dictionary] = {}


## The document, or an empty reader when the cache has none -- a cache made
## before the converter grew this document still loads, and the box is then
## the one thing missing rather than the mission.
static func load_from(cache_dir: String) -> InfoText:
	var out: InfoText = InfoText.new()
	out.read(CacheLoader.read_json("%s/%s" % [cache_dir, DOCUMENT]))
	return out


## The same from a document already in hand, so a suite can hand one over.
func read(document: Dictionary) -> void:
	_blocks = {}
	_pickups = {}
	if DictRead.as_string(document.get("schema", "")) != SCHEMA:
		return
	_blocks = DictRead.as_dict(document.get("blocks", {}))
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


func has(label: String) -> bool:
	return _blocks.has(label)


func spans(label: String) -> Array:
	return DictRead.as_array(_blocks.get(label, []))


## What one action point shows, `[]` when it shows nothing.
func spans_for(action_point: int) -> Array:
	return spans(label_for(action_point))
