## RetroSystemModelPSP — Sony PlayStation Portable (480×272 widescreen LCD).
## Single wide 16:9 screen; the ROM ("disc") loads from the back edge. The core
## (ppsspp) is the heavyweight part — the shell itself is trivial.
##
## Shell geometry (including the UMD drive slit) lives in psp.tscn. This keeps
## the runtime hooks that decorate the SHARED cabinet nodes: the UMD eject latch
## on the host EjectButton, and the slot-load disc placement.
class_name RetroSystemModelPSP
extends RetroSystemModelHandheld


## The UMD EJECT button otherwise floats at its console-scale scene position.
## Real PSP: the eject latch sits on the top edge of the console — mount it on
## the top face at the back-right corner, shrunk to a small slide-latch.
func configure_buttons(_power_btn: VRButton, _reset_btn: VRButton, eject_btn: VRButton) -> void:
	eject_btn.position = Vector3(body_size.x * 0.40, body_size.y / 2.0 + 0.002,
		-body_size.z * 0.32)
	eject_btn.trigger_radius = 0.015
	eject_btn.depress_depth = 0.002
	eject_btn.depress_axis = Vector3(0, -1, 0)

	var col := eject_btn.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = Vector3(0.018, 0.008, 0.014)

	var latch := MeshInstance3D.new()
	latch.name = "UMDEjectMesh"
	var latch_mesh := BoxMesh.new()
	latch_mesh.size = Vector3(0.012, 0.004, 0.008)
	latch.mesh = latch_mesh
	eject_btn.add_child(latch)
	# Re-caches the depress origin and hides the console-scale ButtonMesh.
	eject_btn.set_button_mesh(latch)
	eject_btn.set_color(Color(0.35, 0.35, 0.40))

	var lbl := eject_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.transform = Transform3D.IDENTITY
		lbl.rotation_degrees = Vector3(-90, 0, 0)   # flat on the face, read from above
		lbl.position = Vector3(0, 0.0025, 0.010)
		lbl.pixel_size = 0.0003
		lbl.font_size = 12


## UMD slot keeps the flat placement at the back edge — the slot-load disc ride
## (MediaSlot, wired in system._load_system_model) travels along the zone's -Z, so
## the cartridge-style -90° zone rotation must not apply to the disc.
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.position = Vector3(0, 0, -body_size.z / 2.0 - 0.01)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false
