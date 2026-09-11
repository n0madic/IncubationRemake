@tool
extends EditorPlugin


var _cache_export: EditorExportPlugin = preload("res://addons/android_cache_export/raw_cache_export.gd").new()


func _enter_tree() -> void:
	add_export_plugin(_cache_export)


func _exit_tree() -> void:
	remove_export_plugin(_cache_export)
