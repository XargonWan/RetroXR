## One end of a link cable.
##
## Everything that makes a lead work already lives in RcaPlug and its cable:
## what a cord carries is decided by the two sockets its ends sit in, not by the
## plug. The only thing that differs is which sockets will take it, and that is
## one string.
##
## Kept as its own group rather than reusing an existing one because a link lead
## really does not fit anything else, and the whole point of plug_group() is that
## the room refuses connections that could not be made with the real hardware.
## It is also what will let an asymmetric cable work later: a GameCube-to-GBA
## lead is one cable whose two ends belong to different groups, so neither end
## can be pushed into the wrong socket.
class_name LinkPlug
extends RcaPlug


func plug_group() -> String:
	return "link_plug"
