extends Node

## Saves and netplay both carry model identity, and both go through
## ScenePersistence. This feeds an OLD-format entry — the shape every arcade saved
## before models had ids — and proves it still restores to the right hardware, then
## proves what gets written back is the new shape.
##
##   godot --headless --path RetroVR res://Tools/save_restore_probe.tscn

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func(): get_tree().quit(1))
	get_tree().current_scene = self

	# Exactly what a pre-model_id save file holds: systemid + model_variant, no
	# model_id key anywhere.
	var legacy := [
		{"id": 0, "type": "system", "systemid": "playstation", "model_variant": "original",
			"position": [0, 0, 0], "rotation": [0, 0, 0]},
		{"id": 1, "type": "system", "systemid": "game_boy", "model_variant": "primitive",
			"position": [1, 0, 0], "rotation": [0, 0, 0]},
		{"id": 2, "type": "system", "systemid": "nes", "model_variant": "",
			"position": [2, 0, 0], "rotation": [0, 0, 0]},
		{"id": 3, "type": "system", "systemid": "snes", "model_variant": "primitive",
			"position": [3, 0, 0], "rotation": [0, 0, 0]},
	]
	var want := {0: "playstation_original", 1: "game_boy_primitive", 2: "nes",
		3: SystemModelRegistry.PLACEHOLDER_ID}

	var sp := ScenePersistence.new()
	sp.instantiate_objects(self, legacy)
	for i in range(40):
		await get_tree().physics_frame

	var systems: Array = []
	for n in get_children():
		if n is RetroSystem:
			systems.append(n)
	if systems.size() != legacy.size():
		_bad("restored %d systems, expected %d" % [systems.size(), legacy.size()])

	for idx in range(systems.size()):
		var sys: RetroSystem = systems[idx]
		var expect: String = want[idx]
		if sys.model_id != expect:
			_bad("entry %d: model_id '%s', expected '%s'" % [idx, sys.model_id, expect])
		if sys.get("_model") == null:
			_bad("entry %d: no model instantiated" % idx)
		else:
			print("[save] %-14s variant '%s' -> model_id '%s'  (%s)" % [
				sys.systemid, legacy[idx]["model_variant"], sys.model_id,
				(sys.get("_model") as Node).get_script().resource_path.get_file()])

	# And what goes back out must be the NEW shape.
	var out: Dictionary = sp._serialize_node(systems[0], 0, {})
	if not out.has("model_id"):
		_bad("re-serialized entry has no model_id")
	if out.has("model_variant"):
		_bad("re-serialized entry still carries model_variant")
	print("[save] re-serialized keys: model_id=%s model_variant_present=%s" % [
		out.get("model_id", "<none>"), str(out.has("model_variant"))])

	print("[save] %s" % ("PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


func _bad(m: String) -> void:
	_fail += 1
	print("[save] FAIL " + m)
