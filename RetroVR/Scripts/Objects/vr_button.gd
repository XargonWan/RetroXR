## VRButton — Area3D that emits button_pressed when a VR controller interacts with it.
## Attach to any Area3D that has a child MeshInstance3D named "ButtonMesh".
## Uses direct XRController3D proximity checks each frame instead of physics
## bodies, so it reliably fires exactly where the controller/hand visually is.
## Also supports desktop reticle pointer hover/press.
##
## Two interaction modes:
##   • TOUCH (default) — the fingertip crossing trigger_radius fires the button
##     immediately. No confirmation, so a drifting hand presses things by accident.
##   • TRIGGER (require_trigger = true) — the fingertip entering the interaction
##     box only ARMS the button, outlining it green; pulling the controller's
##     TRIGGER then fires it and the outline turns amber. Same shape as VRHinge's
##     proximity-then-button latch, and the same amber for "engaged".
class_name VRButton
extends Area3D


signal button_pressed

const POINTABLE_LAYER := 1 << 20

## Analog trigger action, read as a float like the rest of the project
## (grip_click/trigger_click bools are only read by godot-xr-tools itself).
const TRIGGER_ACTION := "trigger"
## Float that arms→engages, and the lower value that releases (hysteresis).
## Mirrors VRHinge.GRIP_ON / GRIP_OFF.
const TRIGGER_ON := 0.6
const TRIGGER_OFF := 0.4


## How close (metres) the controller tip must be to trigger the button.
## The button face is at the top of the mesh, so ~half the mesh height is a
## good starting threshold.  TOUCH mode only — TRIGGER mode uses interact_margin.
@export var trigger_radius: float = 0.01

## Require a TRIGGER pull while the fingertip is inside the interaction box,
## instead of firing on touch alone. Off by default so authored buttons keep
## their existing behaviour until switched over scene by scene.
@export var require_trigger: bool = false

## How far (metres) the interaction box extends past the button mesh's own AABB,
## on every side. TRIGGER mode only.
@export var interact_margin: float = 0.02

## How much the mesh travels when pressed (metres)
@export var depress_depth: float = 0.008

## Direction the mesh moves when pressed, in the mesh PARENT's local space.
## Default (0,-1,0) pushes down on Y.  For front-face buttons derive it from
## the model's Finger Button empty's -Z axis via set_depress_axis_from_node().
@export var depress_axis: Vector3 = Vector3(0, -1, 0)

# Cached original local position of the active mesh (in its parent's space)
var _mesh_local_origin: Vector3
# Parent node of the active mesh — used for direction-space conversion
var _mesh_depress_parent: Node3D = null

# Visual state
var _touch_pressed: bool = false
var _pointer_pressed: bool = false
var _pointer_hovered: bool = false
var _latched_pressed: bool = false

# TRIGGER mode state
var _armed: bool = false                       # a fingertip is inside the box
var _trigger_pressed: bool = false             # trigger held after arming
var _engaged_ctrl: XRController3D = null       # controller holding the trigger
# Controller instance ids whose trigger has dropped below TRIGGER_OFF since they
# last fired this button — see _process_trigger_mode.
var _rearmed: Dictionary = {}
var _last_activate_frame: int = -1

@onready var _mesh: MeshInstance3D = $ButtonMesh

# Controller nodes — resolved once in _ready
var _controllers: Array[XRController3D] = []
var _outline: WidgetOutline = null
var _outline_amber: bool = false


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	_mesh_local_origin = _mesh.position
	_mesh_depress_parent = _mesh.get_parent() as Node3D
	_outline = WidgetOutline.attach(self)
	_outline.set_source(_mesh)
	# Controllers aren't added until the first frame, so wait one frame
	await get_tree().process_frame
	# Find all XRController3D nodes in the scene by type
	var all := get_tree().root.find_children("*", "XRController3D", true, false)
	for node in all:
		_controllers.append(node as XRController3D)


func _process(_delta: float) -> void:
	if not _controllers.is_empty():
		if require_trigger:
			_process_trigger_mode()
		else:
			_process_touch_mode()
	_sync_outline()


## TOUCH mode — the original behaviour: crossing trigger_radius fires immediately.
func _process_touch_mode() -> void:
	# Check whether any controller tip is inside our trigger radius
	var touching := false
	for controller in _controllers:
		# Skip a hand that's holding something — otherwise the poke tip of the
		# hand gripping a handheld fires this button by drifting near it.
		if not controller.get_is_active() or not PokeTip.is_poking(controller):
			continue
		var dist: float = global_position.distance_to(PokeTip.tip_of(controller))
		if dist <= trigger_radius:
			touching = true
			break

	if touching and not _touch_pressed:
		_touch_pressed = true
		_update_visual_state()
		_activate()
	elif not touching and _touch_pressed:
		_touch_pressed = false
		_update_visual_state()


## TRIGGER mode — arm on proximity, fire on the trigger's rising edge.
func _process_trigger_mode() -> void:
	# Re-arm bookkeeping. A controller may only fire this button once per trigger
	# pull: without it, sweeping a HELD trigger across a row of buttons (a DVD
	# player's transport strip) fires every one of them in turn.
	for ctrl in _controllers:
		if ctrl != null and ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_rearmed[ctrl.get_instance_id()] = true

	if _trigger_pressed:
		# Held. The hand is free to roam off the button — only releasing the
		# trigger lets go.
		if not is_instance_valid(_engaged_ctrl) or not _engaged_ctrl.get_is_active() \
				or _engaged_ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_engaged_ctrl = null
			_trigger_pressed = false
			_update_visual_state()
		_armed = _hovering_ctrl() != null
		return

	var ctrl := _hovering_ctrl()
	_armed = ctrl != null
	if ctrl == null or ctrl.get_float(TRIGGER_ACTION) <= TRIGGER_ON:
		return
	if not _rearmed.get(ctrl.get_instance_id(), false):
		return
	_rearmed[ctrl.get_instance_id()] = false
	_engaged_ctrl = ctrl
	_trigger_pressed = true
	_update_visual_state()
	_activate()


## First active, non-holding controller whose poke tip is inside the box.
func _hovering_ctrl() -> XRController3D:
	if not is_instance_valid(_mesh) or _mesh.mesh == null:
		return null
	for ctrl in _controllers:
		# Skip a hand that's holding something, same as TOUCH mode.
		if ctrl == null or not ctrl.get_is_active() or not PokeTip.is_poking(ctrl):
			continue
		if _tip_in_box(PokeTip.tip_of(ctrl)):
			return ctrl
	return null


## Interaction volume: the button mesh's own AABB grown by interact_margin on
## every side, tested in the mesh's local space. Beats a sphere centred on the
## Area3D origin for the wide, rectangular caps most console buttons have.
func _tip_in_box(tip: Vector3) -> bool:
	var box := _mesh.mesh.get_aabb().grow(interact_margin)
	return box.has_point(_mesh.global_transform.affine_inverse() * tip)


## Single funnel for every activation path, deduped to one emit per frame.
##
## XRToolsFunctionPointer.active_button_action is "trigger_click" — the same
## physical pull the near-field path watches. Without this, a hand inside the box
## while the laser is also on the button emits button_pressed TWICE in one frame.
## Same idiom as VRDropdown._accept_activation.
func _activate() -> void:
	var frame := Engine.get_process_frames()
	if frame == _last_activate_frame:
		return
	_last_activate_frame = frame
	button_pressed.emit()


func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_hovered = true
			_update_visual_state()
		XRToolsPointerEvent.Type.EXITED:
			_pointer_hovered = false
			_pointer_pressed = false
			_update_visual_state()
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_hovered = true
			_pointer_pressed = true
			_update_visual_state()
			_activate()
		XRToolsPointerEvent.Type.RELEASED:
			_pointer_pressed = false
			_update_visual_state()


## Swap the mesh used for the depress animation and hide the original ButtonMesh child.
## Call this from a system model after the GLB has loaded to drive the real geometry.
## True until a real GLB button mesh is adopted. The power button's green/red
## START/STOP tint (RetroSystem._update_power_button_visual) is only meant for the
## generic placeholder cap — painting it onto a modelled button (the 3DS's real
## power key) turns that button pure green while the console is off. Cleared by
## set_button_mesh so state colouring skips real meshes.
var state_tint := true


func set_button_mesh(mesh: MeshInstance3D) -> void:
	var old := get_node_or_null("ButtonMesh") as MeshInstance3D
	if old:
		old.hide()
	state_tint = false
	_mesh = mesh
	_mesh_local_origin = mesh.position
	_mesh_depress_parent = mesh.get_parent() as Node3D
	# The outline traces the real geometry, and so does the TRIGGER-mode AABB.
	if _outline:
		_outline.set_source(_mesh)
	_update_visual_state()


## Derive the depress axis from a GLB "Finger Button" empty node.
## GLTF finger-button empties are oriented so their local -Z points in the direction
## of travel.  This converts that to the button mesh's local space.
func set_depress_axis_from_node(finger_node: Node3D) -> void:
	# Global -Z of the finger empty = travel direction in world space.
	# Convert to mesh parent's local space so that _mesh.position offsets work correctly.
	var world_dir := -finger_node.global_transform.basis.z.normalized()
	var parent := _mesh_depress_parent if _mesh_depress_parent else _mesh.get_parent() as Node3D
	if parent:
		depress_axis = parent.global_transform.basis.inverse() * world_dir
	else:
		depress_axis = world_dir


## Set the depress travel direction from a WORLD-space direction (converted to the
## button mesh's parent local space). Use when a GLB's finger-button empties don't
## encode the travel axis reliably — e.g. after the model itself has been rotated.
func set_depress_axis_world(world_dir: Vector3) -> void:
	var parent := _mesh_depress_parent if _mesh_depress_parent else _mesh.get_parent() as Node3D
	if parent:
		depress_axis = parent.global_transform.basis.inverse() * world_dir.normalized()
	else:
		depress_axis = world_dir.normalized()


## Keep drawing the hover outline even though the source mesh is hidden — for a
## control the shell PAINTS into its texture rather than modelling, so there is
## no geometry to adopt and the source is a hidden box the size of the print.
## Same escape hatch VRSlider uses for its hidden KnobMesh placeholder; see
## WidgetOutline.outline_hidden_source for why it is off by default.
func set_outline_hidden_source(hidden_ok: bool) -> void:
	if _outline:
		_outline.outline_hidden_source = hidden_ok


## Set the button's visual color by changing its material albedo
func set_color(color: Color) -> void:
	if not _mesh:
		return
	_apply_mesh_color(color)


func set_latched_pressed(pressed: bool) -> void:
	_latched_pressed = pressed
	_update_visual_state()


func _update_visual_state() -> void:
	if not _mesh:
		return

	if _touch_pressed or _pointer_pressed or _latched_pressed or _trigger_pressed:
		# depress_axis may already encode inverse parent scale from
		# set_depress_axis_from_node(), so do not renormalize it here.
		_mesh.position = _mesh_local_origin + depress_axis * depress_depth
	else:
		_mesh.position = _mesh_local_origin

func _apply_mesh_color(color: Color) -> void:
	# Get or create a per-instance material override.
	# Scene sub-resources are shared across instances, so duplicate on first use.
	var mat := _mesh.get_surface_override_material(0)
	if not mat or not mat is StandardMaterial3D:
		mat = StandardMaterial3D.new()
		_mesh.set_surface_override_material(0, mat)
	elif not mat.resource_local_to_scene:
		mat = mat.duplicate() as StandardMaterial3D
		_mesh.set_surface_override_material(0, mat)
	(mat as StandardMaterial3D).albedo_color = color


## Green while armed (the trigger will act here), amber while the trigger is down.
## The pointer-hover outline is unchanged by require_trigger — the laser has always
## highlighted what it is over.
func _sync_outline() -> void:
	if _outline == null:
		return
	if _trigger_pressed != _outline_amber:
		_outline_amber = _trigger_pressed
		_outline.set_color(WidgetOutline.ACTIVE_COLOR if _outline_amber else WidgetOutline.HOVER_COLOR)
	_outline.sync(_armed or _trigger_pressed or _pointer_hovered)
