## Bakes the git description of this checkout into an exported build.
##
## A build on a headset cannot run git, and the DEBUG tab's build plate is only
## worth having if it is right there — a version number typed into
## project.godot months ago tells you nothing about which APK is installed. So
## the stamp is taken here, at export, and added to the pack as a file that
## exists in no checkout, which is exactly what lets an editor run tell itself
## apart and ask git live instead.
##
## The file is added, not written to res://: the export file list is already
## decided by the time this runs, so a file on disk would not be packed.
@tool
extends EditorExportPlugin


func _get_name() -> String:
	return "RetroXRBuildStamp"


func _export_begin(_features: PackedStringArray, _is_debug: bool,
				   _path: String, _flags: int) -> void:
	var stamp := BuildInfo.collect_from_git()
	# The one field git cannot answer. UTC, because a build gets quoted in a
	# report by someone who is not in the timezone that made it.
	stamp["built"] = Time.get_datetime_string_from_system(true).replace("T", " ")
	add_file(BuildInfo.STAMP_PATH, JSON.stringify(stamp, "\t").to_utf8_buffer(), false)
	print("[build-stamp] %s built %s" % [stamp.get("describe", BuildInfo.UNKNOWN), stamp["built"]])
