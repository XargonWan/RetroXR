class_name LocomotionManager
extends Node

const CHANNEL_LEFT := &"left"
const CHANNEL_RIGHT := &"right"
const CHANNEL_ALL := &"all"

## Desktop mode has no hands, so its providers are separate nodes with their own
## names and need their own channel. Covers the keyboard-driven providers only —
## MovementDesktopTurn (mouse-look) is deliberately never gated, because turning
## is how the player drags the virtual mouse.
const CHANNEL_DESKTOP_MOVE := &"desktop_move"

var _move_turn: Node = null
var _func_teleport: Node = null
var _move_direct: Node = null
var _desktop_movers: Array[Node] = []

var _left_blocks := {}
var _right_blocks := {}
var _desktop_blocks := {}


func _ready() -> void:
	call_deferred("_deferred_setup")


func _deferred_setup() -> void:
	_move_turn = _require("MovementTurn")
	_func_teleport = _require("FunctionTeleport")
	_move_direct = _require("MovementDirect")
	# These are what desktop mode actually runs. They were missing for a long
	# time, so nothing was ever blocked outside VR — hence the push_warning: a
	# rename must fail loudly instead of silently disabling arbitration again.
	_desktop_movers.clear()
	for provider_name: String in ["MovementDesktopDirect", "MovementDesktopCrouch",
			"MovementDesktopWalk"]:
		var node := _require(provider_name)
		if node != null:
			_desktop_movers.append(node)
	_apply()


func _require(provider_name: String) -> Node:
	var node := get_tree().root.find_child(provider_name, true, false)
	if node == null:
		push_warning("LocomotionManager: no node named '%s' — it will never be blocked"
			% provider_name)
	return node


func set_block(owner: StringName, channel: StringName, active: bool) -> void:
	match channel:
		CHANNEL_LEFT:
			_set_channel_block(_left_blocks, owner, active)
		CHANNEL_RIGHT:
			_set_channel_block(_right_blocks, owner, active)
		CHANNEL_ALL:
			_set_channel_block(_left_blocks, owner, active)
			_set_channel_block(_right_blocks, owner, active)
		CHANNEL_DESKTOP_MOVE:
			_set_channel_block(_desktop_blocks, owner, active)
		_:
			push_warning("LocomotionManager: unknown channel '%s'" % [channel])
			return

	_apply()


func clear_owner(owner: StringName) -> void:
	_left_blocks.erase(owner)
	_right_blocks.erase(owner)
	_desktop_blocks.erase(owner)
	_apply()


func is_blocked(channel: StringName) -> bool:
	match channel:
		CHANNEL_LEFT:
			return not _left_blocks.is_empty()
		CHANNEL_RIGHT:
			return not _right_blocks.is_empty()
		CHANNEL_ALL:
			return not _left_blocks.is_empty() or not _right_blocks.is_empty()
		CHANNEL_DESKTOP_MOVE:
			return not _desktop_blocks.is_empty()
		_:
			return false


func _set_channel_block(blocks: Dictionary, owner: StringName, active: bool) -> void:
	if active:
		blocks[owner] = true
	else:
		blocks.erase(owner)


func _apply() -> void:
	_set_node_enabled(_move_direct, _left_blocks.is_empty())
	var right_enabled := _right_blocks.is_empty()
	_set_node_enabled(_move_turn, right_enabled)
	_set_node_enabled(_func_teleport, right_enabled)
	var desktop_enabled := _desktop_blocks.is_empty()
	for mover: Node in _desktop_movers:
		_set_node_enabled(mover, desktop_enabled)


func _set_node_enabled(node: Node, value: bool) -> void:
	if node and "enabled" in node:
		node.set("enabled", value)
