## PokeTip — a small visible cone on the front of a VR controller whose POINT
## is the canonical near-interaction ("poke") position: touch screens, console
## buttons, keyboard keys, sliders, book corners all test against this tip
## instead of the controller's tracked origin (which sits inside the
## controller body, ~6 cm behind where your finger visually is).
##
## Add as a child named "PokeTip" of each XRController3D (player_rig.tscn).
## Consumers call the static PokeTip.tip_of(ctrl); when the node is missing
## (e.g. desktop hands) it falls back to a computed forward offset, so callers
## never need to care.
class_name PokeTip
extends Node3D

## How far ahead of the controller origin the tip sits (metres, along -Z aim).
const TIP_FORWARD := 0.06

const CONE_HEIGHT := 0.022
const CONE_RADIUS := 0.007

var _pickup: Node = null   # sibling XRToolsFunctionPickup (hide cone while holding)


## The poke position for a controller: its PokeTip child's origin, or a
## computed forward offset when no PokeTip node exists.
static func tip_of(ctrl: Node3D) -> Vector3:
	var tip := ctrl.get_node_or_null("PokeTip") as Node3D
	if tip:
		return tip.global_position
	return ctrl.global_position - ctrl.global_transform.basis.z * TIP_FORWARD


func _ready() -> void:
	position = Vector3(0, 0, -TIP_FORWARD)
	_pickup = get_parent().get_node_or_null("FunctionPickup")

	# Visible cone: apex exactly at this node's origin, base back toward the
	# controller body — reads as a stylus nib.
	var mesh := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = CONE_RADIUS
	cone.height = CONE_HEIGHT
	mesh.mesh = cone
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.8, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.3, 0.4)
	mat.emission_energy_multiplier = 0.4
	mesh.set_surface_override_material(0, mat)
	# Cylinder axis is +Y (apex at +Y when top_radius = 0). Rotate -90° about X
	# so the apex points -Z (forward), then push the mesh back so the apex
	# lands on the node origin.
	mesh.rotation_degrees = Vector3(-90, 0, 0)
	mesh.position = Vector3(0, 0, CONE_HEIGHT / 2.0)
	add_child(mesh)


func _process(_delta: float) -> void:
	# Hide the nib while this hand holds something — poking doesn't apply and
	# the cone would clip through the held object.
	if _pickup:
		visible = not is_instance_valid(_pickup.get("picked_up_object"))
