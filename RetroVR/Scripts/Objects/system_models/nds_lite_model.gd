## RetroSystemModelNDSLite — Nintendo DS Lite, the "nds:lite" variant.
##
## Behaviourally identical to the original DS (screen layout, forced core
## options, cart size all inherited from RetroSystemModelNDS) — the only
## difference is the shell, so this overrides just the GLB path.
##
## Shell geometry lives in nds_lite.tscn, which is FULLY BAKED (it carries the
## Shell instance, the reparented lid and the placed screens, plus a
## dual_glb_baked meta), so the base skips its runtime upgrade pass entirely.
class_name RetroSystemModelNDSLite
extends RetroSystemModelNDS


## Detailed DS Lite shell (an author imported). Export-excluded — store builds keep
## the primitive clamshell authored in nds_lite.tscn.
func _glb_path() -> String:
	return "res://imported-assets/ds_lite.glb"
