## The console end of a Wii A/V lead — an RcaPlug wearing a Multi Out shell instead of
## a phono barrel.
##
## The same four lines VgaPlug is, and for the same reason: what a cord carries is
## decided by the two sockets its ends sit in, not by the plug, so a lead with this on
## one end needs no routing of its own. The only thing that differs is which sockets
## will take it, and that is one string. WiiAvPort declares the matching side.
##
## Unlike every other plug in the room this one is the end of THREE cords rather than
## one, which is a fact about the LEAD and not about the connector — see
## CompositeCable's shared-end note. Nothing here has to know.
class_name WiiAvPlug
extends RcaPlug


func plug_group() -> String:
	return "wii_av_plug"
