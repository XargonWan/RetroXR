## MemoryCard — pickable memory card for CD-based consoles (PlayStation).
## Must be in the "memory_card" group to snap into a RetroSystem's
## MemoryCardSlot (only visible on consoles whose model uses_memory_cards()).
##
## A card IS one 128 KB image, at save/memcards/<systemid>/<card_id>.mcr — the
## same file every game played with this card seated writes into, which is what
## lets a game read the saves other games left behind. No card in the slot means
## nothing persists at all.
class_name MemoryCard
extends XRToolsPickable

const OPTIONS_PANEL_SCENE := preload("res://Scenes/UI/memory_card_panel.tscn")

var _options_panel: MemoryCardPanel = null


## Persistent identity, and literally the file name this card's saves live in
## (`<card_id>.mcr`). Derived from card_label, so renaming a card moves its
## image — see MemoryCardPanel, which is the only thing that should change it.
@export var card_id: String = ""

## Display label shown on the card face. Also the card's filename on disk — see
## card_id — so the folder reads as a shelf of named cards.
@export var card_label: String = "MEMORY CARD":
	set(v):
		card_label = v
		_update_label()


func _ready() -> void:
	# Cards are otherwise identical grey bricks, yet each holds a different set
	# of saves. Number them in the order they appear so two can be told apart on
	# sight. A restored card arrives with its name already set and keeps it.
	if card_label == "MEMORY CARD":
		card_label = "MEMORY CARD %d" % get_tree().get_nodes_in_group("memory_card").size()
	# Name before id: the id is the name, made unique against what is on disk so
	# two cards can never end up sharing one image.
	if card_id.is_empty():
		card_id = SramPaths.unique_card_id(card_label)
		card_label = card_id
	_update_label()


func _update_label() -> void:
	var lbl := get_node_or_null("CardLabel") as Label3D
	if lbl:
		lbl.text = card_label


## Open/close the card's save list. Reached by pointing at the card and pressing
## the options button, like every other object that has a panel.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		_options_panel = OPTIONS_PANEL_SCENE.instantiate()
		add_child(_options_panel)
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)
