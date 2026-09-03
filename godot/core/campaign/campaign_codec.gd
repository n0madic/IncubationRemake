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
const SCHEMA_VERSION: int = 1
## Magic, schema, campaign-document length, mission-blob length, digest.
const HEADER_SIZE: int = 4 + 4 + 4 + 4 + 32
const DIGEST_SIZE: int = 32

enum Result {
	OK,
	BAD_MAGIC,
	BAD_SCHEMA,
	TRUNCATED,
	BAD_DIGEST,
	BAD_DOCUMENT,
}


static func result_name(code: int) -> String:
	match code:
		Result.OK: return "OK"
		Result.BAD_MAGIC: return "BAD_MAGIC"
		Result.BAD_SCHEMA: return "BAD_SCHEMA"
		Result.TRUNCATED: return "TRUNCATED"
		Result.BAD_DIGEST: return "BAD_DIGEST"
		Result.BAD_DOCUMENT: return "BAD_DOCUMENT"
	return "UNKNOWN"


## *mission_blob* is a [SaveCodec] blob, or empty when the save was taken
## between missions -- on the map screen, in the roster, at a briefing.
static func encode(state: CampaignState,
		mission_blob: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	var document: PackedByteArray = JSON.stringify(
		state.view(), "", true, true).to_utf8_buffer()
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
	# The cache holds no float and neither does this: `JSON.parse_string`
	# produces a `float` for every number, so the narrowing to typed arrays
	# happens once, here, at the loading boundary -- `CampaignState.from_view`
	# reads every number through `DictRead`.
	var document: Dictionary = parsed
	var state: CampaignState = CampaignState.from_view(document)
	var mission: PackedByteArray = body.slice(
		12 + document_size, 12 + document_size + mission_size)
	return {"result": Result.OK, "state": state, "mission": mission}


static func _digest(body: PackedByteArray) -> PackedByteArray:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(body)
	return ctx.finish()
