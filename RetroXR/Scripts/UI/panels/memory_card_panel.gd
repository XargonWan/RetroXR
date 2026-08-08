## MemoryCardPanel — floating 3D panel listing what is saved on a memory card.
##
## Parented to a MemoryCard but uses top_level=true so it inherits no transform.
## Each frame it repositions above the owning card and faces the camera.
## Opened/closed via show_for()/hide_panel(); also has an in-UI ✕.
## Mirrors MouseOptionsPanel / TVOptionsPanel.
##
## The card image is re-read every time the panel opens: a card seated in a
## running console is being written to as the player saves, so anything cached
## from last time would be stale.
class_name MemoryCardPanel
extends Node3D

## Height above the card's origin at which the panel floats.
const FLOAT_HEIGHT := 0.32

var _card: MemoryCard = null
var _camera: Node3D = null
# Guard so we only wire the 2D UI signals once (the SubViewport persists).
var _ui_connected := false

@onready var _viewport_node: XRToolsViewport2DIn3D = $MemoryCardViewport


func _ready() -> void:
	top_level = true
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	if _card and is_instance_valid(_card):
		global_position = _card.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	if _camera and is_instance_valid(_camera):
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


# ── Public API ─────────────────────────────────────────────────────────────────

func show_for(card: MemoryCard, camera: Node3D) -> void:
	_card = card
	_camera = camera
	if _card:
		global_position = _card.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()


func hide_panel() -> void:
	visible = false


# ── Internal helpers ───────────────────────────────────────────────────────────

func _get_ui() -> MemoryCard2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as MemoryCard2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_ensure_ui_connected")
		return
	ui.name_committed.connect(_on_renamed)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true


func _populate() -> void:
	if not _card:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_populate")
		return

	# A card that has never been in a powered console has no image yet. That is
	# not an error — it is a blank card, and saying so beats an empty panel.
	var saves: Array[Dictionary] = []
	var free := 15
	var path := SramPaths.find_card(_card.card_id)
	if not path.is_empty():
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data := f.get_buffer(f.get_length())
			f.close()
			saves = PS1Card.list_saves(data)
			free = PS1Card.free_blocks(data)
	ui.populate(_card.card_label, saves, free)


## A card's name IS its filename, so renaming moves the image on disk. Refused
## when another card already answers to that name — merging them would make two
## cards share one set of saves.
##
## A card seated in a powered console has its path held by the core, so the
## console is told to re-point at the moved file; otherwise the next flush would
## recreate the old name and the rename would appear to have duplicated the card.
func _on_renamed(text: String) -> void:
	if not (_card and is_instance_valid(_card)) or text.strip_edges().is_empty():
		return
	var new_id := SramPaths.rename_card(_card.card_id, text)
	if new_id.is_empty():
		push_warning("[MemoryCardPanel] a card named '%s' already exists" % text)
		_populate()
		return
	_card.card_id = new_id
	_card.card_label = new_id
	_host_system_for(_card)
	_populate()


## Tell whichever console is holding this card that its image moved.
func _host_system_for(card: MemoryCard) -> void:
	for sys: Node in _card.get_tree().get_nodes_in_group("retro_system"):
		if sys.has_method("get_snapped_memcard") and sys.get_snapped_memcard() == card:
			if sys.has_method("refresh_memcard_path"):
				sys.refresh_memcard_path()
			return
