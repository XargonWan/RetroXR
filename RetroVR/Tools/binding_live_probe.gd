## binding_live_probe — a rebind in the options panel must reach the core with no
## further action from the player.
##
## Run: godot --headless --path RetroVR res://Tools/binding_live_probe.tscn
##
## This exists because it did not. The XR binding editor wrote to a scratch map
## that only reached disk when you pressed "Save as Global" — a button at the very
## bottom of a scrolling panel, below the joypad, analog-stick and lightgun
## sections. Change a dropdown, walk away, and nothing had happened.
extends Node3D

const MAIN := preload("res://Scenes/MainScene.tscn")
const PAD := "res://Scenes/Objects/controllers/retro_controller.tscn"

var _fail := false


func _check(c: bool, m: String) -> void:
	print("[probe] %s: %s" % ["PASS" if c else "FAIL", m])
	if not c:
		_fail = true


func _ready() -> void:
	get_tree().create_timer(200.0).timeout.connect(func() -> void: get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	add_child(MAIN.instantiate())
	for i in 30:
		await get_tree().process_frame
	var menu: Node = get_tree().root.find_child("SpawnMenu", true, false)
	_check(menu != null, "the options menu exists")
	var pad: Node3D = (load(PAD) as PackedScene).instantiate()
	get_tree().current_scene.add_child(pad)
	pad.set("freeze", true)
	for i in 12:
		await get_tree().process_frame

	# Build the XR editor directly. Headless reports no OpenXR, so
	# _build_controls_section would pick the desktop branch; this is the same
	# function the headset path runs.
	var box := VBoxContainer.new()
	add_child(box)
	menu.call("_build_xr_controls", box)
	await get_tree().process_frame
	var edit: Dictionary = menu.get("_edit_button_map")
	_check(edit.size() > 0, "the editor loads the current bindings (%d entries)" % edit.size())
	_check(int((pad.get("_button_map") as Dictionary).get("right_ax_button")) == 8,
		"the pad starts on the default: right A -> RetroPad A")

	# Select RetroPad X on the "Right A" row, exactly as a player would, and then
	# do NOTHING else. No save, no confirm.
	var opts: Dictionary = menu.get("_controls_opts")
	var drop: Node = opts.get("btn:right_ax_button")
	_check(drop != null, "the Right A dropdown exists")
	if drop != null:
		drop.emit_signal("item_selected", 9)
		await get_tree().process_frame
		await get_tree().process_frame
	var now: Variant = (pad.get("_button_map") as Dictionary).get("right_ax_button")
	_check(int(now) == 9, "picking X applies immediately, with no Save (got %s)" % str(now))
	_check(int((ControllerBindings.get_global()["buttons"] as Dictionary)
		.get("right_ax_button")) == 9, "and it reached disk")
	# Reset must be live too — it used to need the same missing button.
	menu.call("_on_controls_reset")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(int((pad.get("_button_map") as Dictionary).get("right_ax_button")) == 8,
		"Reset to Default is live as well")
	print("[probe] RESULT %s" % ("PASS" if not _fail else "FAIL"))
	get_tree().quit(1 if _fail else 0)
