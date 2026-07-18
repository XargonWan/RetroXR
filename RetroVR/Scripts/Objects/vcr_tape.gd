## VCRTape — pickable VHS-style cassette carrying a video file path.
## Must be in the "vcr_tape" group to snap into a VCRPlayer's TapeSlot.
class_name VCRTape
extends XRToolsPickable


## The full path to the video file this tape represents
@export_global_file("*.mp4", "*.mkv", "*.avi", "*.webm", "*.mov") var video_path: String = ""

## Display label (video name, shown on the tape face and in spawn menu)
@export var video_label: String = "":
	set(v):
		video_label = v
		_update_label()


func _ready() -> void:
	super()   # XRToolsPickable._ready collects grab points (SnapGrabPoint)
	_update_label()


func _update_label() -> void:
	var lbl := get_node_or_null("VideoLabel") as Label3D
	if lbl:
		lbl.text = video_label


## Returns the video path — called by VCRPlayer when the tape snaps in
func get_video_path() -> String:
	return video_path
