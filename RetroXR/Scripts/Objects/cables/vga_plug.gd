## One end of a VGA lead — an RcaPlug wearing a DE-15 hood instead of a phono barrel.
##
## Everything that makes a lead work is already in RcaPlug and CompositeCable: what
## a cord carries is decided by the two sockets its ends sit in, not by the plug, so
## a VGA lead needs no routing of its own. The only thing that differs is which
## sockets will take it, and that is one string.
##
## Kept as a class rather than an exported group on RcaPlug because the pairing is
## what has to be hard to get wrong: VgaPort declares the same string, and the two
## are meant to be read together.
class_name VgaPlug
extends RcaPlug


func plug_group() -> String:
	return "vga_plug"
