## Editor half of the QR scanner: registers the export plugin that puts the
## RetroXRQr AAR, its ZXing dependency and the camera permissions into an
## Android build. There is nothing to do at runtime — see QrScanner.
@tool
extends EditorPlugin

const ExportPluginScript := preload("res://addons/retroxr_qr/export_plugin.gd")

var _export_plugin: EditorExportPlugin = null


func _enter_tree() -> void:
	_export_plugin = ExportPluginScript.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
