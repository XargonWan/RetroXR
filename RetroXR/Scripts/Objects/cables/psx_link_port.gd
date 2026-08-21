## The serial socket on the back of a PlayStation -- SIO1, the one a link cable
## goes in.
##
## Not the controller bus. That is SIO0, it is on the front, and it carries pads
## and memory cards; the two share a register layout and a name and nothing else.
##
## Subclassed off LinkPort rather than off RcaPort directly, because everything
## this socket needs it already has: finding the machine that owns it by walking
## up the tree, and the core running inside that machine. What differs is the one
## string that decides which plugs fit, and a PlayStation has exactly one of
## these sockets so link_port stays at its default 0.
##
## get_cable() is inherited and always answers null here, which is correct rather
## than merely harmless: it exists so a GBA lead's inline junction can be told
## apart from a socket on a machine, and a PlayStation link cable has no
## junction. Two consoles, one wire, nothing in the middle.
class_name PsxLinkPort
extends LinkPort


func plug_group() -> String:
	return "psx_link_plug"
