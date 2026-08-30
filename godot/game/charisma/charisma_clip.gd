class_name CharismaClip
extends RefCounted

## One `.cha` out of the cache: its tracks, its notes and how long it runs.
##
## Tracks are indexed by `(target, channel)`, which is the pair
## `V100Part::Update` matches on (`0x004A6598`).
##
## **A track whose target is no part of the model is kept and ignored.**
## docs/40 section 7 measures 17 of them across the gameplay set -- `Banner`,
## `Line00`, spare Biped fingers -- authoring helpers the exporter left in the
## clip and never emitted as parts. The converter deliberately does not strip
## them, so that this path is exercised by shipped data rather than only by a
## synthetic case: [method track] simply never finds them, because nothing ever
## asks for a bone the model does not have.

## docs/40 section 9 -- the only note verb gameplay uses. A combat animation
## registers a `StopAnimationAtNoteEventCallback` on it (`0x0042C5D0`) and
## therefore halts itself the moment playback passes the marker.
const NOTE_BREAK: String = "BREAK"

var name: String = ""
## Length in key-time units.
var duration: float = 0.0
var _tracks: Dictionary[String, CharismaTrack] = {}
## `[{"time": float, "text": String}]`, in file order.
var notes: Array[Dictionary] = []


static func from_document(document: Dictionary) -> CharismaClip:
	var clip: CharismaClip = CharismaClip.new()
	clip.name = DictRead.as_string(document["name"])
	clip.duration = _from_bits(DictRead.as_int(document["duration_bits"]))
	for entry: Variant in DictRead.as_array(document["notes"]):
		var note: Dictionary = DictRead.as_dict(entry)
		clip.notes.append({
			"time": _from_bits(DictRead.as_int(note["time_bits"])),
			"text": DictRead.as_string(note["text"]),
		})
	for entry: Variant in DictRead.as_array(document["tracks"]):
		var track_document: Dictionary = DictRead.as_dict(entry)
		var loaded: CharismaTrack = CharismaTrack.from_document(track_document)
		clip._tracks[_key(loaded.target, loaded.channel)] = loaded
	return clip


## The `f32` a cached `*_bits` integer is.
##
## The cache stores a single float as its own IEEE-754 bit pattern so that no
## float is ever formatted (`inclib/charisma_cache.py`); this is where one
## becomes a number again. Arrays take the base64 route instead -- an integer
## per key would be neither smaller nor greppable.
static func _from_bits(bits: int) -> float:
	var raw: PackedByteArray = PackedByteArray()
	raw.resize(4)
	raw.encode_u32(0, bits)
	return raw.decode_float(0)


static func _key(target: String, channel: String) -> String:
	return target + " " + channel


## The track driving `channel` of `target`, or null when there is none.
func track(target: String, channel: String) -> CharismaTrack:
	return _tracks.get(_key(target, channel), null)


func track_count() -> int:
	return _tracks.size()


## Every target this clip drives, for a check to count.
func targets() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for track_key: String in _tracks:
		out.append(_tracks[track_key].target)
	return out


## The time of the first `BREAK` note, or -1 when the clip has none.
##
## docs/40 section 9: a combat animation stops itself here. `BREAK` is the only
## verb gameplay uses -- `Focus` and `Switch` drive the cutscene camera and
## belong to docs/41 -- and a note's text is free-form hand-written script,
## CRLF-separated, with one shipped note being the empty string. So it is split
## on both line endings, trimmed and matched, and anything else is ignored
## rather than parsed.
func break_time() -> float:
	for note: Dictionary in notes:
		var text: String = DictRead.as_string(note["text"])
		for line: String in text.replace("\r", "\n").split("\n"):
			if line.strip_edges() == NOTE_BREAK:
				return DictRead.as_float(note["time"])
	return -1.0
