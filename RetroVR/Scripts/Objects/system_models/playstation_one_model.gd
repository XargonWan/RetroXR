## RetroSystemModelPlaystationOne — PS1 (PSone) disc-tray console model.
##
## Loads an author's imported PSone GLB and wires the power/open buttons, the CD lid
## (driven by the GLB's own PSOneOpen/PSOneClose animations), the disc seat,
## memory-card slot, controller ports and cable. LOADER_TRAY: RetroSystem calls
## play_open()/play_close() to animate the lid (system.gd:1560-1563).
##
## Dev-only: the GLB lives in export-excluded imported-assets/ (licence pending);
## _ready() self-guards and re-shows the placeholder box if the GLB is absent.
class_name RetroSystemModelPlaystationOne
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/playstation_one.glb"

var _glb: Node3D = null
var _anim: AnimationPlayer = null
var _lid: Node3D = null
var _lid_closed: Transform3D


func _ready() -> void:
	# Store-safe guard — ResourceLoader.exists (NOT FileAccess; false in pck).
	if not ResourceLoader.exists(_MODEL_PATH):
		push_warning("PlaystationOneModel: %s missing — using placeholder box" % _MODEL_PATH)
		var host := get_parent()
		if host:
			var body := host.get_node_or_null("SystemBody") as MeshInstance3D
			if body:
				body.show()
		return
	var ps := load(_MODEL_PATH) as PackedScene
	if ps == null:
		push_warning("PlaystationOneModel: failed to load %s" % _MODEL_PATH)
		return
	_glb = ps.instantiate() as Node3D
	# Disable the GLB's auto-played animation so the lid keeps its REST pose, which
	# is the closed lid (verified by diagnostic). PSOneClose is broken — don't use.
	_anim = _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		_anim.autoplay = ""
	add_child(_glb)
	# Hide bundled cables/plugs — RetroVR spawns its own controllers + AV cable.
	for extra in ["controller_plug_002", "RCA_Silver"]:
		var e := _glb.find_child(extra, true, false) as Node3D
		if e != null:
			e.visible = false
	# Recentre on the console body in X/Z (base already rests near y=0).
	var xz := _visible_xz_center(_glb)
	_glb.position = Vector3(-xz.x, 0.0, -xz.y)
	# Cache the closed (rest) lid transform to snap fully shut after closing.
	_lid = _glb.find_child("psone_cd_lid", true, false) as Node3D
	if _lid != null:
		_lid_closed = _lid.transform


func _visible_xz_center(root: Node3D) -> Vector2:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	var ctr := acc.position + acc.size * 0.5
	return Vector2(ctr.x, ctr.z)


# World position of a GLB marker empty (accounts for the recentre offset).
func _anchor(marker: String) -> Vector3:
	if _glb == null:
		return global_position
	var n := _glb.find_child(marker, true, false) as Node3D
	return n.global_position if n != null else global_position


func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return true


# --- disc lid: RetroSystem drives these for LOADER_TRAY consoles ---
func play_open() -> void:
	if _anim != null and _anim.has_animation("PSOneOpen"):
		_anim.play("PSOneOpen")

func play_close() -> void:
	# PSOneClose is broken in the GLB — reverse the open anim, then snap the last
	# sliver shut (its frame 0 is slightly ajar vs the rest/closed pose).
	if _anim != null and _anim.has_animation("PSOneOpen"):
		_anim.play_backwards("PSOneOpen")
		if not _anim.animation_finished.is_connected(_on_close_finished):
			_anim.animation_finished.connect(_on_close_finished, CONNECT_ONE_SHOT)

func _on_close_finished(_anim_name: StringName) -> void:
	if _lid != null:
		_lid.transform = _lid_closed
	if _anim != null:
		_anim.stop()


# --- buttons ---
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "psone_button_power_reset", "Power")
	_wire_button(eject_btn, "psone_button_open", "OpenClose")
	# No distinct reset mesh on the PSone — place the reset button at the left top.
	if reset_btn != null:
		reset_btn.global_position = _anchor("Eject")
		reset_btn.depress_depth = 0.0025
		reset_btn.set_depress_axis_world(Vector3.DOWN)


func _wire_button(btn: VRButton, mesh_name: String, anchor: String) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mesh != null:
		btn.set_button_mesh(mesh)
	btn.global_position = _anchor(anchor)
	btn.depress_depth = 0.0025
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# --- disc seat / ports / cable / memory card ---
func configure_cartridge_slot(slot: Node3D) -> void:
	# Seat the disc on socket_media, NOT the spindle: the spindle marker sits at
	# the rotor's own height (y≈0.0245), which is *inside* the laser assembly
	# (y 0.0212–0.0290) — the disc sank into the mechanism instead of resting on
	# it. socket_media is the same point raised clear of the laser cover.
	slot.global_position = _anchor("socket_media")
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_controller_ports(port_zones: Array) -> void:
	var p := _anchor("Playstation Controller Plug 1")
	if port_zones.size() >= 1:
		port_zones[0].global_position = p
	if port_zones.size() >= 2:
		port_zones[1].global_position = p + Vector3(-0.045, 0.0, 0.0)


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("Cable Plug (S)")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_memory_card_slot(slot: Node3D) -> void:
	# No card-slot marker; place it just above the front-right controller port.
	slot.global_position = _anchor("Playstation Controller Plug 1") + Vector3(0.03, 0.02, 0.0)


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.2, 0.045, 0.18)
	var pos := Vector3(0.0, 0.022, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
