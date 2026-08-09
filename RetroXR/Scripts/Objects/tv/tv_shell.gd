## RetroTVShell — the visual cabinet for a RetroTV.
##
## A shell supplies geometry and anchors ONLY. Every functional node — the screen,
## the composite port, the ambilight, the bezel buttons, the colliders — stays on
## the RetroTV itself, because tv.gd reaches them by fixed `$Name` paths and the
## whole point of the variant system is that a new cabinet costs no script changes.
##
## A shell says where those nodes belong on THIS cabinet by carrying `Marker3D`
## children with known names. Anything it does not name is left exactly as authored
## in tv.tscn, so a shell only has to describe what actually differs. This is the
## same "authored marker wins over the computed default" idiom the console models
## use for CartSeat/DiscSeat/UMDSeat (see system_models/atari_2600_model.gd).
##
## Marker names, all optional:
##   ScreenSeat     — pose for ScreenMesh. Its SCALE sizes the tube; the OSD labels
##                    are children of ScreenMesh and ride that scale for free.
##   PortSeat       — pose for CompositePort (carries PortVisual + SnapHighlight).
##   AmbilightSeat  — pose for the Ambilight SpotLight3D.
##   ButtonRow      — pose of the FIRST bezel button (volume-down). The rest step
##                    along the marker's local +X by `button_pitch`.
##   VolumeLabelSeat— pose for the VolumeLabel Label3D.
##   SpeakerLSeat   — pose for the SpeakerL marker, the point the left channel
##   SpeakerRSeat     radiates from, and the same for the right. Name BOTH or
##                    neither: a shell that names one gets the computed pair for
##                    its tube instead, since half an authored stereo image is
##                    worse than none. Left is the listener's left, i.e. -X on a
##                    set facing +Z.
class_name RetroTVShell
extends Node3D


## Outer dimensions of the cabinet, driving the pickup collider and the pointer
## box. Defaults to tv.tscn's original 0.5 x 0.4 x 0.3 body.
@export var body_size: Vector3 = Vector3(0.5, 0.4, 0.3)

## Spacing between bezel buttons along the ButtonRow marker's local +X.
@export var button_pitch: float = 0.07

## Caps per row before wrapping to the next one, and how far down the marker's
## local -Y that next row sits.
##
## The row used to run until it ran out, which was fine at six caps and stopped
## being fine at eleven — the last of them walked off the end of the cabinet.
## Wrapping keeps every control on the bezel whatever a shell's width.
@export var buttons_per_row: int = 7
@export var button_row_drop: float = 0.055

## Small cabinets (a computer monitor) have no room for the 25 mm button caps on
## a 70 mm pitch. Turn the row off and TVOptionsPanel — already pointer-driven —
## becomes the only control surface for this shell.
@export var show_button_row: bool = true

## Mesh nodes inside the shell GLB to hide. Chiefly the cabinet's own glass: the
## live picture has to land on RetroTV's ScreenMesh, and a modelled pane sitting
## in front of it would either z-fight or hide it outright.
@export var hide_meshes: PackedStringArray = []

## Whether the AV IN legend gets its printed backing plate. OFF by default because a
## moulded CRT back is curved — both cabinets here taper 16 mm and 46 mm across the
## plate's own footprint, so a flat rectangle floats off the curve or cuts into it,
## and the legend falls back to outlined words. The stock body, being a flat box,
## keeps its plate. A shell with a genuinely flat back panel turns this on.
@export var av_legend_plate: bool = false


func _ready() -> void:
	if hide_meshes.is_empty():
		return
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if hide_meshes.has(mi.name):
			mi.visible = false


func screen_seat() -> Variant:      return _seat("ScreenSeat")
func port_seat() -> Variant:        return _seat("PortSeat")
## Absent on every shell but the computer monitor, and that absence is the switch:
## RetroTV leaves its VgaPort disabled and hidden unless a shell asks for one.
func vga_port_seat() -> Variant:    return _seat("VgaPortSeat")
func ambilight_seat() -> Variant:   return _seat("AmbilightSeat")
func button_row_seat() -> Variant:  return _seat("ButtonRow")
func volume_label_seat() -> Variant: return _seat("VolumeLabelSeat")
func speaker_l_seat() -> Variant:   return _seat("SpeakerLSeat")
func speaker_r_seat() -> Variant:   return _seat("SpeakerRSeat")


## Transform of a named marker relative to this shell's root, or null if absent.
##
## Walks the parent chain rather than reading `marker.transform` directly, so a
## marker may be nested under the imported GLB hierarchy (which is where it will
## naturally end up if it is parented to a cabinet part in the editor).
func _seat(marker_name: String) -> Variant:
	var marker := find_child(marker_name, true, false) as Node3D
	if marker == null:
		return null
	var xf: Transform3D = marker.transform
	var p: Node = marker.get_parent()
	while p != null and p != self:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf
