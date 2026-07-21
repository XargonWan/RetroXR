## RetroSystemModelDesktopTower — a beige PC tower, used as the MS-DOS "console".
##
## Loads an author's imported Desktop Tower GLB and wires the POWER button + power LED
## and the front optical-drive bay. DOS is a home-computer system (media_type
## CARTRIDGE / no lidded tray in RetroVR), so the CD tray stays closed at rest and
## the model reads as a static tower; games load from the menu.
##
## Registered as the "dos" model (dev-only). GLB export-excluded (licence pending);
## _ready() self-guards to the placeholder box if the GLB is absent.
class_name RetroSystemModelDesktopTower
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/desktop_tower.glb"

var _glb: Node3D = null
var _led: MeshInstance3D = null


func _ready() -> void:
	if not ResourceLoader.exists(_MODEL_PATH):
		push_warning("DesktopTowerModel: %s missing — using placeholder box" % _MODEL_PATH)
		var host := get_parent()
		if host:
			var body := host.get_node_or_null("SystemBody") as MeshInstance3D
			if body:
				body.show()
		return
	var scene := load(_MODEL_PATH) as PackedScene
	if scene == null:
		push_warning("DesktopTowerModel: failed to load %s" % _MODEL_PATH)
		return
	_glb = scene.instantiate() as Node3D
	# Keep the optical tray shut (rest pose); DOS has no lidded-tray mechanic here.
	var ap := _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		ap.autoplay = ""
	add_child(_glb)
	# Hide the bundled power lead.
	var plug := _glb.find_child("plug", true, false) as Node3D
	if plug != null:
		plug.visible = false
	# Recentre in X/Z, rest the base on the ground (the tower is ~50 cm tall).
	var b := _model_aabb(_glb)
	var c := b.position + b.size * 0.5
	_glb.position = Vector3(-c.x, -b.position.y, -c.z)
	_led = _glb.find_child("Power Light", true, false) as MeshInstance3D
	_set_led(false)


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


func _anchor(marker: String) -> Vector3:
	if _glb == null:
		return global_position
	var n := _glb.find_child(marker, true, false) as Node3D
	return n.global_position if n != null else global_position


func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return false


# POWER only; the front CD eject maps to the eject button, no reset on the tower.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	if power_btn != null:
		power_btn.global_position = _anchor("Power Button")
		power_btn.depress_depth = 0.003
		power_btn.set_depress_axis_world(Vector3.FORWARD)
		var pl := power_btn.get_node_or_null("ButtonLabel") as Label3D
		if pl != null:
			pl.hide()
	if eject_btn != null:
		eject_btn.global_position = _anchor("Eject")
		eject_btn.depress_depth = 0.003
		eject_btn.set_depress_axis_world(Vector3.FORWARD)
		var el := eject_btn.get_node_or_null("ButtonLabel") as Label3D
		if el != null:
			el.hide()
	if reset_btn != null:
		reset_btn.visible = false


# The optical bay stands in for the media seat (games load from the menu, so the
# snap zone is mostly cosmetic). Hide its placeholder visual.
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.global_position = _anchor("socket_media")
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("socket_av")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.24, 0.52, 0.58)
	var pos := Vector3(0.0, 0.26, 0.0)
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
	mat.albedo_color = Color(0.2, 0.8, 0.3) if on else Color(0.06, 0.15, 0.08)
	mat.emission_enabled = on
	mat.emission = Color(0.3, 1.0, 0.4)
	mat.emission_energy_multiplier = 1.0 if on else 0.0
