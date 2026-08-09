## FloatLock — "ignore gravity" for a pickable: park it in mid-air where it is and
## keep it there through every drop, until it is switched off again.
##
## A child component rather than a base class. The devices that want this
## (RetroTV, VCRPlayer, DVDPlayer, RetroAudioPlayer) all extend XRToolsPickable
## directly and GDScript has one inheritance slot, so a shared ancestor would mean
## restructuring four class hierarchies to add a boolean. Same shape as MediaSlot.
##
## RetroSystem keeps its own copy of this behaviour rather than using this: its
## toggle also replicates over netplay (EV_SYS_GRAVITY) and is read back by
## object_sync, so folding it in here would mean moving that too. This is the same
## rule written once for everything else, and RetroSystem can adopt it whenever
## that replication is worth moving.
class_name FloatLock
extends Node

## Emitted whenever the lock changes state, so a panel showing it can follow.
signal changed(enabled: bool)

var enabled: bool = false

var _body: RigidBody3D = null


## Attach a lock to `body`. `initial` comes from a save, so a restored device
## floats at the pose it was saved at instead of falling to the floor first.
static func attach(body: RigidBody3D, initial: bool = false) -> FloatLock:
	var lock := FloatLock.new()
	lock.name = "FloatLock"
	body.add_child(lock)
	lock._bind(body, initial)
	return lock


func _bind(body: RigidBody3D, initial: bool) -> void:
	_body = body
	if body.has_signal("dropped"):
		body.dropped.connect(_on_dropped)
	if initial:
		enabled = true
		# Deferred: at _ready the body may not have reached its restored pose yet,
		# and parking it before it does pins it to the wrong place.
		_park.call_deferred()


## Turn floating on (freeze right here, and wherever it is next dropped) or off
## (hand it back to physics, unless it is currently in someone's hand).
func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	if on:
		_park()
	elif is_instance_valid(_body) and not _held():
		_body.freeze = false
		_body.sleeping = false
	changed.emit(enabled)


func _on_dropped(_pickable: Node3D) -> void:
	if enabled:
		# Deferred: let the release finish — XRToolsPickable restores its own
		# freeze snapshot and applies throw velocities as part of the drop, and
		# both would land after us.
		_park.call_deferred()


func _park() -> void:
	if not enabled or not is_instance_valid(_body) or _held():
		return
	_body.linear_velocity = Vector3.ZERO
	_body.angular_velocity = Vector3.ZERO
	_body.freeze = true


func _held() -> bool:
	return _body.has_method("is_picked_up") and _body.is_picked_up()
