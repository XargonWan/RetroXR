## Editor half of the build stamp: registers the export plugin that writes
## res://build_info.json into a build. There is nothing to do at runtime — see
## BuildInfo, which reads the file back.
@tool
extends EditorPlugin

const ExportPluginScript := preload("res://addons/retroxr_build_stamp/export_plugin.gd")

var _export_plugin: EditorExportPlugin = null


func _enter_tree() -> void:
	_export_plugin = ExportPluginScript.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
