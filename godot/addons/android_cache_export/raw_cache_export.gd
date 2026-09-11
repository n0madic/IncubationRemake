@tool
extends EditorExportPlugin

## `android_payload/cache` deliberately has `.gdignore`: its PNG/WAV files are
## cache records, not Godot resources, and CacheLoader verifies their original
## bytes. The normal exporter would otherwise replace them with imported ctex
## and sample files. EditorExportPlugin.add_file writes this exact byte stream
## to the Android PCK without importing it.

const CACHE_DIR: String = "res://android_payload/cache"
const MANIFEST_NAME: String = "manifest.json"


func _get_name() -> String:
	return "IncubationAndroidRawCache"


func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String,
		_flags: int) -> void:
	if not features.has("android"):
		return
	var manifest_path: String = CACHE_DIR + "/" + MANIFEST_NAME
	if not FileAccess.file_exists(manifest_path):
		push_error("Android export needs %s; run make android-cache first." % manifest_path)
		return
	var manifest_text: String = FileAccess.get_file_as_string(manifest_path)
	var parsed: Variant = JSON.parse_string(manifest_text)
	if not (parsed is Dictionary):
		push_error("Android export cache manifest is invalid: %s" % manifest_path)
		return
	var inventory: Variant = parsed.get("inventory", null)
	if not (inventory is Array) or inventory.is_empty():
		push_error("Android export cache manifest has no inventory: %s" % manifest_path)
		return
	# The manifest itself is deliberately outside its inventory, so add it first.
	add_file(manifest_path, manifest_text.to_utf8_buffer(), false)
	for entry: Variant in inventory:
		if not (entry is Dictionary):
			push_error("Android export cache manifest has an invalid inventory entry")
			return
		var relative_path: Variant = entry.get("path", null)
		if not (relative_path is String):
			push_error("Android export cache manifest has an invalid inventory entry")
			return
		var file_path: String = CACHE_DIR + "/" + relative_path
		if not FileAccess.file_exists(file_path):
			push_error("Android export cache is missing %s" % file_path)
			return
		add_file(file_path, FileAccess.get_file_as_bytes(file_path), false)
