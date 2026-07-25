## RetroSystemModelPS2 — PlayStation 2 Slim (top-loading disc console).
##
## Loads an author's imported PS2 Slim GLB. The Slim is TOP-LOADING (a hinged disc
## cover, PS2SlimOpen/Close), so `playstation2` is reclassified LOADER_TRAY in
## media_dimensions.gd (it was slot-load, which suits the fat PS2 front slot but
## not this Slim) — RetroSystem then drives play_open()/play_close() on the lid.
##
## Dev-only: the GLB lives in export-excluded imported-assets/ (licence pending);
## _ready() self-guards and re-shows the placeholder box if the GLB is absent.
class_name RetroSystemModelPS2
extends RetroSystemModel

## The GLB PS2SlimOpen clip rotates about the model origin (converter bakes node
## transforms to identity) → wrong direction. Drive a real back-edge hinge instead.
const LID_OPEN_DEG := 80.0

var _glb: Node3D = null
var _anim: AnimationPlayer = null
var _lid: MeshInstance3D = null
var _lid_hinge: VRSpringLatchedHinge = null
var _led: MeshInstance3D = null


## Overridable so the Silver recolour can reuse all this wiring — the black and
## silver PS2 Slim GLBs share node names and animations, only the shell differs.
func _model_path() -> String:
	return "res://imported-assets/ps2_slim.glb"


func _ready() -> void:
	# The authored ps2.tscn / ps2_silver.tscn instances the shell as a "Shell" child
	# plus an editor-authorable "DiscSeat" marker (cylinder "SeatPreview") riding it.
	# Reuse the instance when present.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		# Store-safe guard — ResourceLoader.exists (NOT FileAccess; false in pck).
		var path := _model_path()
		if not ResourceLoader.exists(path):
			push_warning("PS2Model: %s missing — using placeholder box" % path)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var ps := load(path) as PackedScene
		if ps == null:
			push_warning("PS2Model: failed to load %s" % path)
			return
		_glb = ps.instantiate() as Node3D
		add_child(_glb)
	var preview := find_child("SeatPreview", true, false)
	if preview is Node3D:
		(preview as Node3D).visible = false
	# Disable the auto-played anim so the lid keeps its REST pose (= closed).
	_anim = _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		_anim.autoplay = ""
	_hide_clutter(_glb)
	# Recentre on the console body in X/Z (base already rests near y=0).
	var xz := _visible_xz_center(_glb)
	_glb.position = Vector3(-xz.x, 0.0, -xz.y)
	# Cache the closed (rest) lid transform to snap fully shut after closing.
	# Mount the disc cover on a real back-edge hinge (spring-loaded, button-opened).
	_lid = _glb.find_child("ps2s_disc_cover*", true, false) as MeshInstance3D
	if _lid != null:
		_lid_hinge = VRSpringLatchedHinge.mount(self, _lid, LID_OPEN_DEG)
		if _lid_hinge != null:
			_lid_hinge.rotation_changed.connect(_on_lid_swung)
	_led = _glb.find_child("Power Light", true, false) as MeshInstance3D
	_set_led(false)


# Hide the bundled clutter the console GLB ships with:
#   * the coiled controller lead posed out of port 1 (…plug/cable…),
#   * a loose memory card (ps2s_memcard) — keep the ps2s_memcard_SLOT face meshes,
#   * the vent_masking_* strips: flat quads the author tucked behind the rear vents
#     that float free of the body and read as stray black rods from most angles.
# RetroVR spawns its own controllers and cards; the disc-bay spindle/laser covers
# are kept so the bay looks real when the lid opens.
# (Manual recursion — find_children's type filter skips MeshInstance3D here.)
func _hide_clutter(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			var nm := String(mi.name).to_lower()
			var is_lead := nm.contains("plug") or nm.contains("cable")
			# All memcard meshes: the loose card AND the two slot meshes, which are
			# authored as long bars jutting off the console's right side (they read as
			# a stray rod). RetroVR spawns its own card and mounts it on the front face.
			var is_card := nm.contains("memcard")
			# The disc-bay internals (laser_cover_*, dvd_slot, spindle hub), the
			# vent_masking_* strips and the *_vent_* grilles are authored to sit ABOVE /
			# BEHIND the closed cover, so they poke through as stray rods/coils. Closed
			# is the default resting state in VR, so hide all that bay/vent junk for a
			# clean top; the body itself keeps its moulded vent detail.
			var is_bay_junk := nm.contains("masking") or nm.contains("laser") \
				or nm.contains("dvd") or nm.contains("vent")
			if is_lead or is_card or is_bay_junk:
				mi.visible = false
		for c in n.get_children():
			stack.append(c)


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
	return 2


func uses_memory_cards() -> bool:
	return true


# --- disc lid: RetroSystem drives these for LOADER_TRAY consoles ---
# Spring-loaded VRSpringLatchedHinge (replaces the origin-pivoting PS2SlimOpen clip
# that opened the wrong way): OPEN button springs it fully up; the hand pulls it
# down to close (release near-shut latches, release mid springs back open).
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


# --- buttons: POWER + EJECT (the Slim has no discrete RESET) ---
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "Power", _mesh_center("Power"))
	_wire_button(eject_btn, "Eject", _anchor("OpenClose"))
	if reset_btn != null:
		reset_btn.visible = false   # no reset button on the PS2 Slim


func _wire_button(btn: VRButton, mesh_name: String, anchor: Vector3) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mesh != null:
		btn.set_button_mesh(mesh)
	btn.global_position = anchor
	btn.depress_depth = 0.0022
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# --- disc seat / ports / cable / memory card ---
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.global_position = _anchor("socket_media")   # RetroDisc seats on the spindle
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false
	# An authored "DiscSeat" marker (baked into ps2.tscn / ps2_silver.tscn, riding
	# the Shell) wins over socket_media. Absent → keep the socket_media pose.
	var seat := find_child("DiscSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform


func configure_controller_ports(port_zones: Array) -> void:
	var p := _anchor("Playstation Controller Plug")
	if port_zones.size() >= 1:
		port_zones[0].global_position = p
	if port_zones.size() >= 2:
		port_zones[1].global_position = p + Vector3(0.03, 0.0, 0.0)


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("socket_av")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_memory_card_slot(slot: Node3D) -> void:
	# The GLB's slot meshes are hidden (bars jutting off the right); mount the card on
	# the front face beside the controller ports (PS2 cards slot in under the pads).
	slot.global_position = _anchor("Playstation Controller Plug") + Vector3(0.045, -0.008, 0.0)


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.34, 0.06, 0.2)
	var pos := Vector3(0.0, 0.03, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos


func on_power_on() -> void:
	_set_led(true)

func on_power_off() -> void:
	_set_led(false)


func _set_led(on: bool) -> void:
	if _led == null:
		return
	var mat := _led.get_surface_override_material(0) as StandardMaterial3D
	if mat == null or not mat.resource_local_to_scene:
		mat = StandardMaterial3D.new()
		mat.resource_local_to_scene = true
		_led.set_surface_override_material(0, mat)
	mat.albedo_color = Color(0.15, 0.35, 0.9) if on else Color(0.06, 0.1, 0.2)
	mat.emission_enabled = on
	mat.emission = Color(0.2, 0.45, 1.0)
	mat.emission_energy_multiplier = 1.1 if on else 0.0
