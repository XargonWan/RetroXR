## Headless probe for dual-screen handheld models (NDS / 3DS): UV windows on
## the two screen quads, top→bottom material mirroring, and touch-poke →
## composite-framebuffer UV conversion (including the 3DS's inset bottom rect).
##
## Run: godot --headless --path RetroVR res://Tools/dual_screen_probe.tscn
extends Node3D

var _fail := false


class StubHost extends Node3D:
	var touches: Array = []
	func feed_touch(uv: Vector2, pressed: bool) -> void:
		touches.append([uv, pressed])
	func set_audio_volume(_v: float) -> void:
		pass


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[probe] FAIL: %s" % msg)


func _uv_bounds(mesh: MeshInstance3D) -> Rect2:
	var arrays := (mesh.mesh as ArrayMesh).surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var lo := uvs[0]
	var hi := uvs[0]
	for uv in uvs:
		lo = Vector2(minf(lo.x, uv.x), minf(lo.y, uv.y))
		hi = Vector2(maxf(hi.x, uv.x), maxf(hi.y, uv.y))
	return Rect2(lo, hi - lo)


func _check_model(path: String, want_top: Rect2, want_bottom: Rect2) -> void:
	var nm := path.get_file()
	var script := load(path) as GDScript
	var model: RetroSystemModelDualScreen = script.new() as RetroSystemModelDualScreen
	add_child(model)

	_fail_if(not model.is_handheld(), "%s not handheld" % nm)
	var top := model.get_builtin_screen()
	var bottom: MeshInstance3D = model._bottom_screen
	_fail_if(top == null or bottom == null, "%s missing screens" % nm)
	if top == null or bottom == null:
		return

	# UV windows into the composite framebuffer.
	var top_uv := _uv_bounds(top)
	var bot_uv := _uv_bounds(bottom)
	print("[probe] %s top_uv=%s bottom_uv=%s" % [nm, top_uv, bot_uv])
	_fail_if(not top_uv.position.is_equal_approx(want_top.position)
		or not top_uv.size.is_equal_approx(want_top.size), "%s top UV window" % nm)
	_fail_if(not bot_uv.position.is_equal_approx(want_bottom.position)
		or not bot_uv.size.is_equal_approx(want_bottom.size), "%s bottom UV window" % nm)

	# Material mirroring: whatever lands on the top screen's surface 0 (the
	# C++ VideoHandler's seat) must appear on the bottom quad next _process.
	var core_mat := StandardMaterial3D.new()
	top.set_surface_override_material(0, core_mat)
	model._process(0.016)
	_fail_if(bottom.get_surface_override_material(0) != core_mat,
		"%s bottom did not mirror core material" % nm)

	# Touch conversion: pokes at the bottom screen's centre and corners map
	# through the bottom UV window.
	var host := StubHost.new()
	add_child(host)
	model._host = host
	var touch: Area3D = model._touch
	model._send_touch(touch.global_position, true)   # centre
	model._send_touch(touch.to_global(Vector3(
		model.bottom_screen_size.x / 2.0, 0, model.bottom_screen_size.y / 2.0)), false)
	var want_centre := want_bottom.position + want_bottom.size * 0.5
	var want_corner := want_bottom.position + want_bottom.size
	_fail_if(host.touches.size() != 2, "%s touch count %d" % [nm, host.touches.size()])
	if host.touches.size() == 2:
		var t0: Array = host.touches[0]
		var t1: Array = host.touches[1]
		print("[probe] %s touch centre=%s corner=%s" % [nm, t0[0], t1[0]])
		_fail_if(not (t0[0] as Vector2).is_equal_approx(want_centre) or t0[1] != true,
			"%s centre touch %s (want %s)" % [nm, t0[0], want_centre])
		_fail_if(not (t1[0] as Vector2).is_equal_approx(want_corner) or t1[1] != false,
			"%s corner touch %s (want %s)" % [nm, t1[0], want_corner])

	# Lid: top screen sits on the lid pivot, angled open (not coplanar with base).
	var lid_x: float = model._lid_pivot.rotation_degrees.x
	_fail_if(absf(lid_x - (180.0 - model.lid_open_deg)) > 0.01,
		"%s lid angle %f" % [nm, lid_x])


func _ready() -> void:
	_check_model("res://Scripts/Objects/system_models/nds_model.gd",
		Rect2(0, 0, 1, 0.5), Rect2(0, 0.5, 1, 0.5))
	_check_model("res://Scripts/Objects/system_models/n3ds_model.gd",
		Rect2(0, 0, 1, 0.5), Rect2(0.1, 0.5, 0.8, 0.5))
	print("[probe] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)
