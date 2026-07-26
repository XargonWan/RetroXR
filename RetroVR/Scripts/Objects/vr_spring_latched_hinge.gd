## VRSpringLatchedHinge — a spring-loaded, button-opened console CD/GD-ROM lid.
##
## Behaviour (on top of VRHinge's grab plumbing):
##   • Boots CLOSED and LATCHED. The console's OPEN button (model.play_open) calls
##     open() → the lid springs FULLY OPEN.
##   • While open, the hand (VR grip) / desktop pointer can grab the lid and pull it
##     DOWN toward closed. On release: near the closed limit → LATCH shut (and report
##     it, via rotation_changed, so the host closes the tray); anywhere else → the
##     lid SPRINGS back fully open.
##   • The hand can NOT start an open from closed — engagement is gated while latched
##     (_can_engage), so only the button opens it.
##
## closed = min_deg (0), open = max_deg (>0). The spring eases toward max_deg; the
## latch snaps to min_deg. Direction is set by the lid rig (see mount()), which
## rotates the lid UP about its real back-edge hinge — replacing the broken GLB
## Open animation that made these lids swing the wrong way.
class_name VRSpringLatchedHinge
extends VRHinge

## Degrees/sec the lid eases back toward fully open when released mid-swing.
@export var spring_speed_deg: float = 260.0
## Release within this many degrees of the closed limit (min_deg) → latch shut.
@export var close_latch_deg: float = 12.0
## Consoles boot with the tray shut, so the lid starts latched closed.
@export var start_closed: bool = true

var _latched_closed := false


func _ready() -> void:
	super._ready()
	_latched_closed = start_closed
	_apply(min_deg if _latched_closed else max_deg, false)
	_set_interactive(not _latched_closed)


## Button-driven open (model.play_open): unlatch so the spring pulls it fully open.
func open() -> void:
	_latched_closed = false
	_set_interactive(true)


## Latch fully shut (model.play_close, or the hand pushed it home). Emits so the
## host can mark the tray closed.
func latch_closed() -> void:
	_latched_closed = true
	_grip_ctrl = null
	_pointer_held = false
	_set_interactive(false)
	_apply(min_deg, true)


## A latched-shut lid genuinely can't be interacted with — only the OPEN
## button unlatches it (_can_engage() already blocks a grab from starting)
## — so hide the hover/held hint icon and disable the grab-box collision
## entirely rather than leaving a dead hitbox a hand can bump into.
func _set_interactive(active: bool) -> void:
	for c in get_children():
		if c is CollisionShape3D:
			(c as CollisionShape3D).disabled = not active
	if not active and _icon != null:
		_icon.visible = false


func _update_icon() -> void:
	if _latched_closed:
		return
	super._update_icon()


func is_latched_closed() -> bool:
	return _latched_closed


# The hand can only grab an OPEN (unlatched) lid — button-only opening.
func _can_engage() -> bool:
	return not _latched_closed


# closed = min_deg, open = max_deg: wheel UP opens, wheel DOWN closes.
func _open_toward_max() -> bool:
	return true


# On release: close if the hand left it near shut, else let the spring take over.
func _on_released() -> void:
	if target == null:
		return
	var cur := rad_to_deg(target.rotation.x)
	if absf(cur - min_deg) <= close_latch_deg:
		latch_closed()


# Ease back toward fully open whenever it's neither held nor latched shut. Silent
# (no signal) — only latch_closed reports state; the spring return isn't "an event".
func _on_idle(delta: float) -> void:
	if _latched_closed or target == null:
		return
	var cur := rad_to_deg(target.rotation.x)
	if is_equal_approx(cur, max_deg):
		return
	_apply(move_toward(cur, max_deg, spring_speed_deg * delta), false)


## Build a spring lid rig on `host` from an already-placed lid mesh: a DiscLidPivot
## at the lid's real back-edge hinge, the lid reparented onto it, and a
## VRSpringLatchedHinge with a grab box over the lid. `open_deg` is how far up it
## swings. Mirrors playstation_one_model._mount_lid (the recipe that opens the right
## way): pivot at the lid's back-bottom edge, 180° yaw so +rotation lifts the front.
## Returns the hinge (connect rotation_changed for tray-state reporting).
static func mount(host: Node3D, lid: MeshInstance3D, open_deg: float) -> VRSpringLatchedHinge:
	if host == null or lid == null:
		return null
	var ab: AABB = lid.global_transform * lid.get_aabb()   # world-space lid box
	var pivot := Node3D.new()
	pivot.name = "DiscLidPivot"
	host.add_child(pivot)
	pivot.global_transform = Transform3D(
		host.global_transform.basis * Basis(Vector3.UP, PI),
		Vector3(ab.get_center().x, ab.position.y, ab.position.z))
	var world := lid.global_transform
	lid.reparent(pivot, false)
	lid.global_transform = world
	var hinge := VRSpringLatchedHinge.new()
	hinge.name = "DiscLidHinge"
	hinge.target = pivot
	hinge.min_deg = 0.0
	hinge.max_deg = open_deg
	hinge.engage_radius = clampf(maxf(ab.size.x, ab.size.z) * 0.4, 0.03, 0.09)
	pivot.add_child(hinge)
	# Grab box over the lid (in pivot-local), thin along the lid's normal.
	hinge.position = pivot.to_local(ab.get_center())
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(ab.size.x, 0.02), maxf(ab.size.z, 0.02), maxf(ab.size.y, 0.01) + 0.02)
	col.shape = box
	hinge.add_child(col)
	# Hint in the lid's OWN plane, just past the grab box — the authored lids
	# carry this as their HingeHint node position; a code-built rig sets its own.
	# The line is pivot -> hinge, which for this rig is simply hinge.position.
	var away := hinge.position.normalized() if hinge.position.length() > 0.0001 else Vector3.UP
	var reach: float = (absf(away.x) * box.size.x + absf(away.y) * box.size.y 		+ absf(away.z) * box.size.z) * 0.5
	hinge.place_hint(away * (reach + 0.014))
	return hinge
