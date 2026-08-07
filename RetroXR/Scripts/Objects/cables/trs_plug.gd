## One end of a 3.5 mm TRS lead — an RcaPlug wearing a stereo jack plug.
##
## Everything that makes a lead work already lives in RcaPlug and CompositeCable:
## what a cord carries is decided by the two sockets its ends sit in, not by the
## plug. The only thing that differs is which sockets will take it, and that is one
## string — a TRS plug does not go into a phono jack.
class_name TrsPlug
extends RcaPlug


func plug_group() -> String:
	return "trs_plug"
