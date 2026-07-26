## RetroSystemModelGameCube — Nintendo GameCube (mini-DVD disc, top-loading lid).
##
## Loads necro's imported GameCube GLB and wires POWER, RESET and the disc-lid
## OPEN button, plus 4 controller ports and 1 memory card slot. The lid is a
## real hinged mesh ("LID") mounted on a VRSpringLatchedHinge (the same rig
## Dreamcast/PS2/Saturn use) rather than the GLB's own Open/Close animation
## clips, which — like those consoles' — don't reliably drive the mesh.
##
## Registered as the "gamecube" model (dev-only). GLB is export-excluded;
## _ready() self-guards to the placeholder box if the GLB is absent.
class_name RetroSystemModelGameCube
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/gamecube.glb"
## The GLB's own Open animation swings the wrong way / doesn't restore on
## Close — same story as every other disc console in this library.
const LID_OPEN_DEG := 50.0

var _glb: Node3D = null
var _anim: AnimationPlayer = null
var _lid: MeshInstance3D = null
var _lid_hinge: VRSpringLatchedHinge = null


func _ready() -> void:
	# The authored gamecube.tscn bakes the recentred shell as a "Shell" instance
	# plus an editor-authorable "DiscSeat" marker (cylinder "SeatPreview") riding
	# it. Reuse that instance instead of loading a second copy of the GLB.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		if not ResourceLoader.exists(_MODEL_PATH):
			push_warning("GameCubeModel: %s missing — using placeholder box" % _MODEL_PATH)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var scene := load(_MODEL_PATH) as PackedScene
		if scene == null:
			push_warning("GameCubeModel: failed to load %s" % _MODEL_PATH)
			return
		_glb = scene.instantiate() as Node3D
		add_child(_glb)
		var b := _model_aabb(_glb)
		var c := b.position + b.size * 0.5
		_glb.position = Vector3(-c.x, -b.position.y, -c.z)
	# Two "SeatPreview" boxes ride this shell (DiscSeat and MemCardSeat) — both
	# are editor aids only, hide all matches, not just the first.
	for preview in find_children("SeatPreview", "", true, false):
		if preview is Node3D:
			(preview as Node3D).visible = false
	_anim = _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		_anim.autoplay = ""   # keep the rest pose (lid closed) on load
	# Mount the disc lid on a real back-edge hinge (spring-loaded, button-opened).
	# Baked into gamecube.tscn as DiscLidPivot/DiscLidHinge/CollisionShape3D
	# (mount()'s own node names) — same idiom as the PSP's UMDDoorPivot — so
	# reuse it when present instead of rebuilding the rig every load.
	var pivot := get_node_or_null("DiscLidPivot") as Node3D
	if pivot != null:
		_lid_hinge = pivot.get_node_or_null("DiscLidHinge") as VRSpringLatchedHinge
	else:
		_lid = _glb.find_child("LID", true, false) as MeshInstance3D
		if _lid != null:
			_lid_hinge = VRSpringLatchedHinge.mount(self, _lid, LID_OPEN_DEG)
	# The lid is two pieces: the LID shell and the "GC GEM" inlay seated in it.
	# Only LID rode the pivot, so opening the lid left the gem hanging in mid-air
	# over the hole.
	if pivot != null:
		var gem := _glb.find_child("GC GEM", true, false) as MeshInstance3D
		if gem != null and gem.get_parent() != pivot:
			gem.reparent(pivot, true)
	# The shell ships a controller plug already seated in port 1 (the other three
	# sockets are empty). RetroVR spawns its own plug on a cable, so that one is
	# just a plug end permanently stuck in the console.
	var seated_plug := _glb.find_child("GCPort", true, false) as MeshInstance3D
	if seated_plug != null:
		seated_plug.visible = false
	if _lid_hinge != null:
		_lid_hinge.rotation_changed.connect(_on_lid_swung)


func _model_aabb(inst: Node3D) -> AABB:
	var acc := AABB(); var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	return acc


## An EMPTY marker's own position is already its true world location
## (bundle_convert places socket/plug/finger anchors there directly) — unlike a
## MeshInstance3D, whose control meshes ship with an IDENTITY node transform
## (the offset lives in the baked vertex data; see the PSP-1000 / Atari 5200
## shells for the same gotcha), so an anchor needs .global_position directly
## while a mesh needs its AABB centre in global space instead.
func _anchor(marker: String) -> Vector3:
	if _glb == null:
		return global_position
	var n := _glb.find_child(marker, true, false) as Node3D
	return n.global_position if n != null else global_position


func _mesh_center(mesh_name: String) -> Vector3:
	if _glb == null:
		return global_position
	var m := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	return (m.global_transform * m.get_aabb().get_center()) if m != null else global_position


func get_controller_port_count() -> int:
	return 4


func uses_memory_cards() -> bool:
	return true


# --- disc lid (spring-loaded VRSpringLatchedHinge) ---
func has_spring_latched_lid() -> bool:
	return _lid_hinge != null


func play_open() -> void:
	if _lid_hinge != null:
		_lid_hinge.open()


func play_close() -> void:
	if _lid_hinge != null:
		_lid_hinge.latch_closed()


func _on_lid_swung(_deg: float) -> void:
	if _lid_hinge != null and _lid_hinge.is_latched_closed():
		var host := get_parent()
		if host != null and host.has_method("request_tray_state"):
			host.request_tray_state(false)


# --- buttons: POWER, RESET, disc-lid OPEN ---
#
# Each has both a real button mesh AND a "FINGER ..." anchor empty sitting
# just proud of it (the trigger point) — use the anchor's position (accurate
# by construction) and the mesh only for the visible depress animation.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "POW BUTTON", "FINGER POWER")
	_wire_button(reset_btn, "RESET BUTTON", "FINGER RESET")
	_wire_button(eject_btn, "gc_console_button_open", "FINGER OPEN")


func _wire_button(btn: VRButton, mesh_name: String, anchor_name: String) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mesh != null:
		btn.set_button_mesh(mesh)
	btn.global_position = _anchor(anchor_name)
	btn.depress_depth = 0.003
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


## No per-port marker meshes beyond the one modelled "GCPort" — the other 3
## are approximated at a real-hardware-typical pitch to its right. Baked as
## authored "PortSeat1".."PortSeat4" markers in gamecube.tscn (dial-able in the 3D
## editor, same "authored wins over computed" idiom as CartSeat/DiscSeat) —
## this fallback only fires for a script-only instance with no baked scene.
const _PORT_PITCH := 0.028


func configure_controller_ports(port_zones: Array) -> void:
	if _glb == null:
		return
	var base := _mesh_center("GCPort")
	for i in range(port_zones.size()):
		var recess := port_zones[i].get_node_or_null("PortRecess") as MeshInstance3D
		if recess != null:
			recess.hide()
		var lbl := port_zones[i].get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()
		var marker := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if marker != null:
			port_zones[i].global_transform = marker.global_transform
		else:
			port_zones[i].global_transform = Transform3D(
				global_transform.basis,
				base + Vector3(_PORT_PITCH * i, 0, 0))


## Only slot 1 is modelled/wired — RetroSystem only has one MemoryCardSlot
## regardless of how many the real hardware has (same as the PSone's two
## slots, only slot 1 wired). An authored "MemCardSeat" marker (baked into
## gamecube.tscn) wins over the computed mesh-centre pose, same idiom as the
## controller ports above.
func configure_memory_card_slot(slot: Node3D) -> void:
	var seat := find_child("MemCardSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform
		return
	slot.global_position = _mesh_center("gc_console_memcard_01")


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("digiav")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_cartridge_slot(slot: Node3D) -> void:
	if _glb == null:
		return
	slot.global_position = _anchor("System Socket (CD)")
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false
	# An authored "DiscSeat" marker (baked into gamecube.tscn, riding the Shell)
	# wins over the socket-derived pose, so the disc rest can be dialled in
	# visually in the editor. Absent → keep the socket pose.
	var seat := find_child("DiscSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.17, 0.12, 0.22)
	var pos := Vector3(0.0, 0.06, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
