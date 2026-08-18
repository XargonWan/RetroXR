extends Node

## Posters: image loading, the sheet's dimensions, sticking to a surface, riding
## the thing it stuck to, and the save/restore round trip.
##
##   godot --headless --path RetroXR res://Tests/poster_tests.tscn
##   godot --headless --path RetroXR res://Tests/poster_tests.tscn -- --only=stick
##
## Exits non-zero on failure, so it can gate a commit.
##
## Physics runs fine headless — the dummy renderer stubs RENDERING, not Jolt — so
## the stick cases are real: a body, a wall, a raycast and a reparent. What cannot
## be checked here is how any of it LOOKS; that needs a windowed probe.
##
## The image cases need a file to read, so the suite writes its own PNG (with a
## transparent corner, to exercise the alpha path) into the real posters folder and
## removes it at both ends.

const GROUPS := ["image", "stick", "conform", "menu", "persist"]
const SLOT := "__poster_selftest"
const TEST_IMAGE := "__poster_selftest.png"

var _fail := 0
var _ran := 0
var _only := ""
var _img_path := ""


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func():
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	_img_path = _write_test_image()
	if _img_path.is_empty():
		print("[test] could not write a test image")
		get_tree().quit(1)
		return

	if _want("image"):
		await _test_image()
	if _want("stick"):
		await _test_stick()
	if _want("conform"):
		await _test_conform()
	if _want("menu"):
		await _test_menu()
	if _want("persist"):
		await _test_persist()

	_cleanup()
	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ── The image, and the sheet it sizes ─────────────────────────────────────────

func _test_image() -> void:
	var listed := RomLibrary.scan_posters()
	var names: Array = []
	for e: Dictionary in listed:
		names.append(str(e["path"]))
	_ok(_img_path in names, "image/scan_posters finds a dropped file")

	var p := _make_poster()
	await get_tree().process_frame

	# 160x120 source, so 4:3, and the long edge is the one that measures 0.5.
	var sz: Vector2 = p.get_sheet_size()
	_ok(absf(sz.x - 0.5) < 0.001, "image/long edge is 0.5 m (%.3f)" % sz.x)
	_ok(absf(sz.y - 0.375) < 0.001, "image/short edge follows the aspect (%.3f)" % sz.y)

	var mesh := p.get_node("Surface/FlatMesh") as MeshInstance3D
	_ok((mesh.mesh as QuadMesh).size.is_equal_approx(sz), "image/quad matches the sheet")

	var mat := mesh.get_surface_override_material(0) as StandardMaterial3D
	_ok(mat != null, "image/a material was built")
	# The trap: ALPHA would put this in the transparent pass with depth writes off,
	# and two posters would then sort per-triangle against each other.
	_ok(mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR,
		"image/an image with alpha uses SCISSOR, not blend")
	_ok(mat.albedo_texture.get_image().has_mipmaps(), "image/mipmaps generated")
	_ok(mat.emission_enabled and absf(mat.emission_energy_multiplier - 0.1) < 0.001,
		"image/emission at 0.1, as the room's own posters carry")

	# One scalar drives both edges, so the aspect cannot drift.
	p.size_scale = 2.0
	await get_tree().process_frame
	var big: Vector2 = p.get_sheet_size()
	_ok(absf(big.x - 1.0) < 0.001, "image/resize scales the long edge (%.3f)" % big.x)
	_ok(absf((big.x / big.y) - (sz.x / sz.y)) < 0.0001, "image/aspect survives a resize")
	var box := (p.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	_ok(absf(box.size.x - big.x) < 0.001, "image/the collider followed the resize")

	# A .tscn sub-resource is shared unless it says otherwise, and these are written
	# per instance — so resizing one poster must not resize the next.
	var q := _make_poster()
	await get_tree().process_frame
	var qbox := (q.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	_ok(not is_equal_approx(qbox.size.x, box.size.x),
		"image/each poster owns its own mesh and shapes")

	# An image that has been deleted must not crash the spawn.
	var gone := _make_poster("user://__no_such_poster.png")
	await get_tree().process_frame
	_ok(is_instance_valid(gone), "image/a missing file still spawns a sheet")

	p.queue_free()
	q.queue_free()
	gone.queue_free()
	await get_tree().process_frame


# ── Sticking, riding, peeling ─────────────────────────────────────────────────

func _test_stick() -> void:
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame

	var p := _make_poster()
	await get_tree().process_frame
	p.global_transform = Transform3D(Basis(), Vector3(0, 1.5, -1.88))

	# A RAY release, which is how a poster reaches a far wall — and the case a
	# dropped-driven stick would miss entirely, because _end_ray_grab restores the
	# body itself and never calls let_go().
	await _release(p)

	_ok(p.is_stuck(), "stick/sticks on a ray-style release, with no dropped signal")
	_ok(p.stick_target() == wall, "stick/the wall is the host")
	_ok(p.get_parent() == wall, "stick/reparented so it rides the host")
	_ok(p.freeze, "stick/parked, so it cannot be knocked off")
	# Wall centre -2.0, half-depth 0.075 -> face at -1.925, plus the 2 mm skin.
	_ok(absf(p.global_position.z - (-1.923)) < 0.01,
		"stick/sits on the wall face (z %.4f)" % p.global_position.z)
	_ok(p.global_transform.basis.z.dot(Vector3(0, 0, 1)) > 0.99, "stick/faces the room")
	_ok(absf(p.global_transform.basis.y.dot(Vector3.UP) - 1.0) < 0.01, "stick/hangs upright")

	# The whole point of reparenting: carrying the host carries the poster.
	var before: Vector3 = p.global_position
	wall.global_position += Vector3(0.5, 0.25, 0.0)
	await get_tree().physics_frame
	_ok(p.global_position.distance_to(before + Vector3(0.5, 0.25, 0.0)) < 0.001,
		"stick/rides the host when it moves")

	# A grab IS the peel — every hold restores freeze on its own.
	p.picked_up.emit(p)
	await get_tree().physics_frame
	_ok(not p.is_stuck(), "stick/a grab peels it")
	_ok(p.get_parent() != wall, "stick/peeling hands it back to the room")

	# Released against nothing, it stays loose rather than sticking to air.
	var loose := _make_poster()
	await get_tree().process_frame
	loose.global_transform = Transform3D(Basis(), Vector3(6, 1.5, 6))
	await _release(loose)
	_ok(not loose.is_stuck(), "stick/nothing in reach means no stick")

	p.queue_free()
	loose.queue_free()
	wall.queue_free()
	await get_tree().process_frame


# ── Save and restore ──────────────────────────────────────────────────────────

func _test_persist() -> void:
	var sp := ScenePersistence.new("arcade")
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame

	var p := _make_poster()
	p.add_to_group("spawned")
	await get_tree().process_frame
	p.size_scale = 1.75
	p.global_transform = Transform3D(Basis(), Vector3(0.4, 1.5, -1.88))
	await _release(p)
	_ok(p.is_stuck(), "persist/stuck before saving")

	_ok(sp.save_slot(self, SLOT), "persist/saved")

	# Read the file, not just the room: this is what separates "recorded wrong"
	# from "restored wrong", and the two need different fixes.
	var file := "user://scenes/arcade/%s.json" % SLOT
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	var entry: Dictionary = {}
	for o: Variant in (raw as Dictionary).get("objects", []):
		if str((o as Dictionary).get("type", "")) == "poster":
			entry = o as Dictionary
	_ok(not entry.is_empty(), "persist/a poster entry reached the file")
	_ok(str(entry.get("image_path", "")) == _img_path, "persist/image_path recorded")
	_ok(absf(float(entry.get("size_scale", 0.0)) - 1.75) < 0.001, "persist/size recorded")
	_ok(bool(entry.get("stuck", false)), "persist/stuck recorded")

	sp.clear_scene(self)
	for i in range(20):
		await get_tree().physics_frame
	_eq(_count_posters(), 0, "persist/cleared")

	await sp.load_slot_async(self, SLOT)
	for i in range(40):
		await get_tree().physics_frame
	_eq(_count_posters(), 1, "persist/restored exactly one")

	var back: Poster = null
	for n in get_tree().get_nodes_in_group("spawned"):
		if n is Poster:
			back = n as Poster
	if back != null:
		_ok(back.image_path == _img_path, "persist/image came back")
		_ok(absf(back.size_scale - 1.75) < 0.001, "persist/size came back")
		_ok(absf(back.get_sheet_size().x - 0.875) < 0.002,
			"persist/dimensions re-derived from the restored size")
		_ok(back.is_stuck(), "persist/came back stuck to the wall")
		# The restore hands gravity back to everything it froze; a stuck poster
		# must not take that as permission to fall.
		var settled: Vector3 = back.global_position
		for i in range(30):
			await get_tree().physics_frame
		_ok(back.global_position.distance_to(settled) < 0.005,
			"persist/did not fall after the restore let go")

	sp.clear_scene(self)
	for i in range(10):
		await get_tree().physics_frame
	wall.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


# ── Harness ───────────────────────────────────────────────────────────────────

func _want(name: String) -> bool:
	return _only.is_empty() or _only == name


func _make_poster(path: String = "") -> Poster:
	var p := preload("res://Scenes/Objects/media/poster.tscn").instantiate() as Poster
	p.image_path = _img_path if path.is_empty() else path
	add_child(p)
	return p


## Mesh AND collider at the same size, the way the rooms author their walls —
## which is what makes the poster_flat opt-out worth testing: without a mesh
## there is nothing to sample and conform would bail for the wrong reason.
func _make_wall(at: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 3, 0.15)
	cs.shape = box
	wall.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	wall.add_child(mi)
	add_child(wall)
	wall.global_position = at
	return wall


## Hold then release the way a ray grab does: freeze on, freeze off, and no signal
## in between.
func _release(p: Poster) -> void:
	p.freeze = true
	for i in range(4):
		await get_tree().physics_frame
	p.freeze = false
	for i in range(14):
		await get_tree().physics_frame


func _count_posters() -> int:
	var n := 0
	for x in get_tree().get_nodes_in_group("spawned"):
		if x is Poster:
			n += 1
	return n


## A 160x120 PNG with one transparent corner, written into the real posters folder
## — scan_posters derives that path and it cannot be pointed anywhere safer.
func _write_test_image() -> String:
	var dir := RomLibrary.default_posters_root()
	DirAccess.make_dir_recursive_absolute(dir)
	var img := Image.create(160, 120, false, Image.FORMAT_RGBA8)
	for y in range(120):
		for x in range(160):
			var a := 0.0 if (x < 40 and y < 30) else 1.0
			img.set_pixel(x, y, Color(float(x) / 160.0, float(y) / 120.0, 0.8, a))
	var path := dir.path_join(TEST_IMAGE)
	if img.save_png(path) != OK:
		return ""
	return path


func _cleanup() -> void:
	if not _img_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_img_path))
	var slot := ProjectSettings.globalize_path("user://scenes/arcade/%s.json" % SLOT)
	if FileAccess.file_exists(slot):
		DirAccess.remove_absolute(slot)


func _ok(cond: bool, what: String) -> void:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what if got == want else "%s (got %s, want %s)" % [what, got, want])


# ── Conforming to a curved surface ────────────────────────────────────────────

func _test_conform() -> void:
	# A cylinder standing on Y, so its circle is in X-Z and the sheet has to wrap
	# around it horizontally. Radius 0.4, roughly a CRT shoulder.
	var host := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.4
	cyl.bottom_radius = 0.4
	cyl.height = 2.0
	mi.mesh = cyl
	host.add_child(mi)
	var cs := CollisionShape3D.new()
	# A deliberately crude collider — a box around the cylinder, the way most of
	# the room's GLB furniture is wrapped. Conform must ignore it and read the mesh.
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 2.0, 0.8)
	cs.shape = box
	host.add_child(cs)
	add_child(host)
	host.global_position = Vector3(0, 1.2, -3.0)
	await get_tree().physics_frame

	var p := _make_poster()
	await get_tree().process_frame
	p.size_scale = 0.6                      # 0.3 x 0.225, well inside the barrel
	p.global_transform = Transform3D(Basis(), Vector3(0, 1.2, -2.55))
	await _release(p)
	_ok(p.is_stuck(), "conform/stuck to the cylinder")

	p.set_fit_mode(Poster.FitMode.CONFORM)
	for i in range(20):
		await get_tree().physics_frame

	var cm := p.get_node_or_null("Surface/ConformMesh") as MeshInstance3D
	_ok(cm != null and cm.mesh != null, "conform/a wrapped mesh was built")
	if cm == null or cm.mesh == null:
		host.queue_free()
		p.queue_free()
		return
	_ok(not (p.get_node("Surface/FlatMesh") as MeshInstance3D).visible,
		"conform/the flat quad gives way to it")

	var arrays := cm.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	_ok(verts.size() > 40, "conform/subdivided (%d verts)" % verts.size())
	_ok(norms.size() == verts.size() and uvs.size() == verts.size(),
		"conform/normals and UVs per vertex")

	# The real check: every vertex should sit on the cylinder, 0.4 from its axis.
	# A flat sheet would leave the corners short by centimetres.
	var worst := 0.0
	var flat_worst := 0.0
	for i in range(verts.size()):
		var world: Vector3 = p.global_transform * verts[i]
		var rel := world - host.global_position
		var r := Vector2(rel.x, rel.z).length()
		worst = maxf(worst, absf(r - 0.4))
		# Same point if the sheet had stayed flat (z of the vertex zeroed).
		var flat_v: Vector3 = Vector3(verts[i].x, verts[i].y, 0.0)
		var fw: Vector3 = p.global_transform * flat_v
		var frel := fw - host.global_position
		flat_worst = maxf(flat_worst, absf(Vector2(frel.x, frel.z).length() - 0.4))
	_ok(worst < 0.006, "conform/every vertex lies on the cylinder (worst %.4f m)" % worst)
	_ok(flat_worst > worst * 2.0,
		"conform/and a flat sheet would not (flat worst %.4f m)" % flat_worst)

	# Normals must be smooth, not the facets a trimesh hit reports. Compared along a
	# ROW: consecutive array indices wrap from one edge of the sheet to the other,
	# where the normals genuinely differ by the whole wrap angle.
	var w := 18   # nx + 1 for this sheet
	var min_dot := 1.0
	for k in range(norms.size()):
		if (k + 1) % w == 0:
			continue
		min_dot = minf(min_dot, norms[k].dot(norms[k + 1]))
	_ok(min_dot > 0.99, "conform/normals vary smoothly along a row (worst %.4f)" % min_dot)

	# UVs still span the sheet exactly, so the art fills it.
	var umin := 2.0
	var umax := -1.0
	for uv in uvs:
		umin = minf(umin, uv.x)
		umax = maxf(umax, uv.x)
	_ok(absf(umin) < 0.001 and absf(umax - 1.0) < 0.001,
		"conform/UVs still span 0..1 (%.3f..%.3f)" % [umin, umax])

	# A wall is tagged as its own surface, so it must NOT be sampled.
	var wall := _make_wall(Vector3(0, 1.5, 4.0))
	wall.add_to_group("poster_flat")
	await get_tree().physics_frame
	var wp := _make_poster()
	await get_tree().process_frame
	# In FRONT of the wall for a sheet whose probe runs along its own -Z.
	wp.global_transform = Transform3D(Basis(), Vector3(0, 1.5, 4.12))
	wp.fit_mode = Poster.FitMode.CONFORM
	await _release(wp)
	for i in range(20):
		await get_tree().physics_frame
	_ok(wp.is_stuck(), "conform/the wall poster stuck at all")
	_ok(wp.get_node_or_null("Surface/ConformMesh") == null,
		"conform/a poster_flat surface is never sampled")
	_ok((wp.get_node("Surface/FlatMesh") as MeshInstance3D).visible,
		"conform/it stays a flat quad")

	p.queue_free()
	wp.queue_free()
	host.queue_free()
	wall.queue_free()
	await get_tree().process_frame


# ── The options menu contract ─────────────────────────────────────────────────

func _test_menu() -> void:
	var p := _make_poster()
	await get_tree().process_frame

	# The controller finds a host by TYPE and then calls this without checking, so
	# a poster registered in those chains must answer it.
	_ok(p.has_method("toggle_options_ui"), "menu/the poster exports toggle_options_ui")

	var src := FileAccess.get_file_as_string(
		"res://Scripts/UI/spawn_menu/spawn_menu_controller.gd")
	# BOTH chains — the VR pointer's and the desktop Tab's. Missing either means the
	# menu silently does nothing on that platform.
	_eq(src.count("node is Poster"), 2, "menu/registered in both host chains")

	var panel := p.get_node_or_null("PosterOptionsPanel")
	_ok(panel != null, "menu/the panel is on the poster")
	_ok(panel != null and not panel.visible, "menu/and starts hidden")
	p.toggle_options_ui(null)
	_ok(panel != null and panel.visible, "menu/opens")
	p.toggle_options_ui(null)
	_ok(panel != null and not panel.visible, "menu/and closes again")

	# Peel is offered as a verb too, for a poster out of arm's reach.
	_ok(p.has_method("peel"), "menu/peel is callable without a grab")
	p.peel()
	_ok(not p.is_stuck(), "menu/peeling an unstuck poster is safe")

	p.queue_free()
	await get_tree().process_frame
