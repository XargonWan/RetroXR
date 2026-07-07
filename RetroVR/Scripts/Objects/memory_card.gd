## MemoryCard — pickable memory card for CD-based consoles (PlayStation).
## Must be in the "memory_card" group to snap into a RetroSystem's
## MemoryCardSlot (only visible on consoles whose model uses_memory_cards()).
##
## A card is a persistent folder of battery saves: each game played with this
## card seated stores its SRAM at save/<core>/memcards/<card_id>/<game>.srm.
## No card in the slot at power-on = authentic no-persistence.
class_name MemoryCard
extends XRToolsPickable


## Persistent identity — the on-disk folder name for this card's saves.
@export var card_id: String = ""

## Display label shown on the card face.
@export var card_label: String = "MEMORY CARD":
	set(v):
		card_label = v
		_update_label()


func _ready() -> void:
	if card_id.is_empty():
		card_id = "%08x%08x" % [randi(), randi()]
	_update_label()


func _update_label() -> void:
	var lbl := get_node_or_null("CardLabel") as Label3D
	if lbl:
		lbl.text = card_label
