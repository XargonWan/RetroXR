## The male F connector on the end of an aerial lead.
##
## An RcaPlug with a different mouth, for the reason VgaPlug is: what a plug DOES
## is answer to a snap group and carry a cord index, and neither of those cares
## what the connector looks like. The group is the whole of the keying — it is what
## stops a phono plug being pushed into an aerial socket and an F connector into a
## phono jack.
class_name CoaxPlug
extends RcaPlug


func plug_group() -> String:
	return "coax_plug"
