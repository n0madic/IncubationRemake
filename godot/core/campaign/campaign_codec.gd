class_name CampaignCodec
extends RefCounted

## The campaign save's bytes -- a container **over** [SaveCodec] (D10).
##
## [SaveCodec] refuses a blob whose map name is not the world's
## (`MAP_MISMATCH`), which is exactly right for a mission save and exactly
## wrong for a campaign: the whole point is that the campaign outlives the
## mission. So the campaign state is its own document, and a mission save --
## when there is one, because a quick save can be taken mid-mission -- rides
## inside it as an opaque blob that [SaveCodec] decodes later, against the
## world the campaign has by then loaded.
##
## No file access here. `core` never touches the filesystem
## (`godot/tests/test_isolation.gd`), so this hands bytes to `game/`, which
## writes them.

const MAGIC: String = "INCC"
## Raised to **2** by the seventh slice: the document gained the stamp a slot
## row shows, and with a list of slots to draw the campaign state moved under its
## own key so a header read never has to know what is beside it. An older
## container is refused **by name** (`BAD_SCHEMA`), which is the field's whole
## purpose.
const SCHEMA_VERSION: int = 2
## The document's own keys. The state is nested rather than spread at the top
## level so that a future [CampaignState] field cannot collide with the stamp.
const KEY_STATE: String = "state"
const KEY_SAVED_AT: String = "saved_at"
const KEY_SAVED_AT_TEXT: String = "saved_at_text"
## What the player called this save, or `""` for one that was never named --
## the quick save, and a numbered slot written with the name field left empty.
##
## **Additive, and [constant SCHEMA_VERSION] stays at 2 for it.** The version
## exists to refuse a container this build cannot *read*, and a document
## without this key is read perfectly well: it is a save with no name. Bumping
## it would have thrown away every slot a player already has, to gain nothing.
## Read it through `get`, never through `[]`.
const KEY_NAME: String = "name"
## Magic, schema, campaign-document length, mission-blob length, digest.
const HEADER_SIZE: int = 4 + 4 + 4 + 4 + 32
const DIGEST_SIZE: int = 32

## **These numbers are not [enum SaveCodec.Result]'s.** `TRUNCATED` is 1 there
## and 3 here, so a refusal must always be named through the matching
## [method result_name] -- crossing the two prints a confident wrong reason.
enum Result {
	OK,
	BAD_MAGIC,
	BAD_SCHEMA,
	TRUNCATED,
	BAD_DIGEST,
	BAD_DOCUMENT,
	## Nothing is saved there. Appended rather than inserted, so the five
	## above keep the numbers this build already prints.
	NO_FILE,
}


static func result_name(code: int) -> String:
	match code:
		Result.OK: return "OK"
		Result.BAD_MAGIC: return "BAD_MAGIC"
		Result.BAD_SCHEMA: return "BAD_SCHEMA"
		Result.TRUNCATED: return "TRUNCATED"
		Result.BAD_DIGEST: return "BAD_DIGEST"
		Result.BAD_DOCUMENT: return "BAD_DOCUMENT"
		Result.NO_FILE: return "NO_FILE"
	return "UNKNOWN"


## *mission_blob* is a [SaveCodec] blob, or empty when the save was taken
## between missions -- on the map screen, in the roster, at a briefing.
##
## *saved_at* is Unix seconds and *saved_at_text* is what the writer's own
## clock said in its own time zone. Two fields on purpose: the first orders
## slots, the second is what a row shows, and neither is derivable from the
## other here -- `core` may not call `Time` at all, so the offset that turns
## one into the other is not available on this side.
static func encode(state: CampaignState,
		mission_blob: PackedByteArray = PackedByteArray(),
		saved_at: int = 0, saved_at_text: String = "",
		name: String = "") -> PackedByteArray:
	var document: PackedByteArray = JSON.stringify({
		KEY_SAVED_AT: saved_at,
		KEY_SAVED_AT_TEXT: saved_at_text,
		KEY_NAME: name,
		KEY_STATE: state.view(),
	}, "", true, true).to_utf8_buffer()
	var body: PackedByteArray = PackedByteArray()
	body.append_array(PackedInt32Array([SCHEMA_VERSION, document.size(),
		mission_blob.size()]).to_byte_array())
	body.append_array(document)
	body.append_array(mission_blob)

	var out: PackedByteArray = MAGIC.to_utf8_buffer()
	out.append_array(body)
	out.append_array(_digest(body))
	return out


## Returns `{"result": Result, "state": CampaignState, "mission": PackedByteArray}`.
##
## The failure modes are [SaveCodec]'s, on purpose: a save that is not one of
## ours, one from a schema this build does not speak, a truncated file and a
## corrupted one are four different answers, not one `null`.
static func decode(data: PackedByteArray) -> Dictionary:
	var parsed: Dictionary = _read_document(data)
	var code: int = DictRead.as_int(parsed["result"])
	if code != Result.OK:
		return {"result": code}
	# The cache holds no float and neither does this: `JSON.parse_string`
	# produces a `float` for every number, so the narrowing to typed arrays
	# happens once, here, at the loading boundary -- `CampaignState.from_view`
	# reads every number through `DictRead`.
	var document: Dictionary = DictRead.as_dict(parsed["document"])
	var state: CampaignState = CampaignState.from_view(
		DictRead.as_dict(document[KEY_STATE]))
	var document_size: int = DictRead.as_int(parsed["document_size"])
	var mission_size: int = DictRead.as_int(parsed["mission_size"])
	var body: PackedByteArray = data.slice(4, data.size() - DIGEST_SIZE)
	var mission: PackedByteArray = body.slice(
		12 + document_size, 12 + document_size + mission_size)
	return {"result": Result.OK, "state": state, "mission": mission,
		KEY_SAVED_AT: DictRead.as_int(document[KEY_SAVED_AT]),
		KEY_SAVED_AT_TEXT: DictRead.as_string(document[KEY_SAVED_AT_TEXT]),
		KEY_NAME: DictRead.as_string(document.get(KEY_NAME, ""))}


## What a slot row needs, and nothing else.
##
## Returns `{"result": Result, "campaign": int, "mission": String,
## "score": int, "saved_at": int, "saved_at_text": String, "name": String,
## "has_mission": bool}`. The scoreboard, the roster and the mission blob are
## **not** unrolled: a page of rows is a page of these, and building a campaign
## per row to draw a list would be paying for the world to read its label.
##
## The digest is still checked. It is a SHA-256 over a file of tens of
## kilobytes, and a row that showed a damaged save as sound would be worse
## than the microsecond.
static func decode_header(data: PackedByteArray) -> Dictionary:
	var empty: Dictionary = {"campaign": 0, "mission": "", "score": 0,
		KEY_SAVED_AT: 0, KEY_SAVED_AT_TEXT: "", KEY_NAME: "",
		"has_mission": false}
	var parsed: Dictionary = _read_document(data)
	var code: int = DictRead.as_int(parsed["result"])
	if code != Result.OK:
		empty["result"] = code
		return empty
	var document: Dictionary = DictRead.as_dict(parsed["document"])
	var state: Dictionary = DictRead.as_dict(document[KEY_STATE])
	# The total is the scoreboard's, read at the position player 0 holds --
	# the same record [CampaignHost] scores into.
	var boards: Array = DictRead.as_array(state.get("scoreboard", []))
	var score: int = 0
	if not boards.is_empty():
		score = DictRead.as_int(DictRead.as_dict(boards[0]).get("total", 0))
	return {"result": Result.OK,
		"campaign": DictRead.as_int(state.get("campaign", 0)),
		"mission": DictRead.as_string(state.get("mission", "")),
		"score": score,
		KEY_SAVED_AT: DictRead.as_int(document[KEY_SAVED_AT]),
		KEY_SAVED_AT_TEXT: DictRead.as_string(document[KEY_SAVED_AT_TEXT]),
		KEY_NAME: DictRead.as_string(document.get(KEY_NAME, "")),
		"has_mission": DictRead.as_int(parsed["mission_size"]) > 0}


## The container's checks, up to and including the parsed JSON document.
## Shared by [method decode] and [method decode_header] so the two cannot
## disagree about what a valid file is.
static func _read_document(data: PackedByteArray) -> Dictionary:
	if data.size() < HEADER_SIZE:
		return {"result": Result.TRUNCATED}
	if data.slice(0, 4).get_string_from_utf8() != MAGIC:
		return {"result": Result.BAD_MAGIC}
	var body: PackedByteArray = data.slice(4, data.size() - DIGEST_SIZE)
	var stored: PackedByteArray = data.slice(data.size() - DIGEST_SIZE)
	if _digest(body) != stored:
		return {"result": Result.BAD_DIGEST}
	var head: PackedInt32Array = body.slice(0, 12).to_int32_array()
	if head[0] != SCHEMA_VERSION:
		return {"result": Result.BAD_SCHEMA}
	var document_size: int = head[1]
	var mission_size: int = head[2]
	if body.size() < 12 + document_size + mission_size:
		return {"result": Result.TRUNCATED}
	var text: String = body.slice(12, 12 + document_size).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"result": Result.BAD_DOCUMENT}
	var document: Dictionary = parsed
	if not document.has(KEY_STATE):
		return {"result": Result.BAD_DOCUMENT}
	return {"result": Result.OK, "document": document,
		"document_size": document_size, "mission_size": mission_size}


static func _digest(body: PackedByteArray) -> PackedByteArray:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(body)
	return ctx.finish()
