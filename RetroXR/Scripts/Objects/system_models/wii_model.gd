## RetroSystemModelWii — the Wii, wearing the procedural box until it has a shell
## of its own. It exists for the core options below, which are not cosmetic: the
## Wii Remote does not work at all without them.
##
## Everything else Wii-shaped — pairing, slot arbitration, the GameCube-vs-Wii
## device ids — lives in WiiLink, the component system.gd attaches to this
## console. This file is only the hardware description.
class_name RetroSystemModelWii
extends RetroSystemModelDefault


## Both of these are load-bearing for the Wii Remote, in different ways.
##
## `dolphin_ir_mode = "2"` is what points the emulated remote's IR at the
## libretro POINTER device. Left at its default the core binds IR to the right
## analog stick instead, and the remote's raycast reaches nothing at all —
## buttons work, aiming does not.
##
## `dolphin_save_load_settings = "disabled"` is already the core's default, and
## is pinned here because of what switching it on does: the core then loads
## WiimoteNew.ini and returns EARLY from its port setup, skipping every built-in
## mapping — including the pointer binding above. A stale profile in the Dolphin
## system folder would silently cost the player their aim, with nothing in the
## logs to say why.
func get_forced_core_options() -> Dictionary:
	return {
		"dolphin_ir_mode": "2",
		"dolphin_save_load_settings": "disabled",
	}
