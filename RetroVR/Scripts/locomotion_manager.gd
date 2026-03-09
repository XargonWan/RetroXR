class_name LocomotionManager
extends Node

const CHANNEL_LEFT := &"left"
const CHANNEL_RIGHT := &"right"
const CHANNEL_ALL := &"all"

var _move_turn: Node = null
var _func_teleport: Node = null
var _move_direct: Node = null

var _left_blocks := {}
var _right_blocks := {}


func _ready() -> void:
	call_deferred("_deferred_setup")


func _deferred_setup() -> void:
	_move_turn = get_tree().root.find_child("MovementTurn", true, false)
	_func_teleport = get_tree().root.find_child("FunctionTeleport", true, false)
	_move_direct = get_tree().root.find_child("MovementDirect", true, false)
	_apply()


func set_block(owner: StringName, channel: StringName, active: bool) -> void:
	match channel:
		CHANNEL_LEFT:
			_set_channel_block(_left_blocks, owner, active)
		CHANNEL_RIGHT:
			_set_channel_block(_right_blocks, owner, active)
		CHANNEL_ALL:
			_set_channel_block(_left_blocks, owner, active)
			_set_channel_block(_right_blocks, owner, active)
		_:
			push_warning("LocomotionManager: unknown channel '%s'" % [channel])
			return

	_apply()


func clear_owner(owner: StringName) -> void:
	_left_blocks.erase(owner)
	_right_blocks.erase(owner)
	_apply()


func is_blocked(channel: StringName) -> bool:
	match channel:
		CHANNEL_LEFT:
			return not _left_blocks.is_empty()
		CHANNEL_RIGHT:
			return not _right_blocks.is_empty()
		CHANNEL_ALL:
			return not _left_blocks.is_empty() or not _right_blocks.is_empty()
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


func _set_node_enabled(node: Node, value: bool) -> void:
	if node and "enabled" in node:
		node.set("enabled", value)
