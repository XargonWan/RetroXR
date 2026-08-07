## One cabinet of a SpeakerPair — a plain pickable box.
##
## It carries no behaviour of its own on purpose. The pair owns the wire, the socket,
## the knob and the sink contract; a cabinet is only the thing you pick up and put
## down, and both of them being independently grabbable is the whole point of it
## being its own body rather than a mesh on the pair's root.
##
## Exists as a class rather than the addon's pickable.gd attached raw so that
## ScenePersistence and the pair can name what they are looking at.
class_name SpeakerBox
extends XRToolsPickable
