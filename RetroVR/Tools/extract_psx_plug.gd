## Extracts the PS1 controller connector out of the PSone console GLB and saves
## it as a standalone mesh for the PlayStation controllers' cable ends.
##
## an author's PSone GLB ships a fully modelled controller plug (`controller_plug_002`,
## 1657 verts, textured) sitting in port 1. The console model hides it — RetroVR
## spawns its own controllers — but it's the right connector for those controllers
## to be wearing, so it's lifted out here instead of going to waste.
##
## Run headless to (re)generate the asset:
##   godot --headless --path RetroVR res://Tools/extract_psx_plug.tscn
##
## The mesh is baked into the ControllerPlug's own frame: origin at the seated
## plug position, connector pointing +Z and cable trailing -Z (the convention
## controller_cable.tscn's generic PlugTip uses). That bake reproduces the exact
## insertion depth the model's author posed it at, so the plug sits in the port
## the way it does in the source scene.
extends Node

const SRC := "res://imported-assets/playstation_one.glb"
const DST := "res://imported-assets/psx_controller_plug.res"
const MESH_NAME := "controller_plug_002"
## Matches RetroSystemModelPlaystationOne._PORT_INSET — the port zone sits half a
## recess-depth inside the console's front face.
const PORT_INSET := 0.0025


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func(): get_tree().quit(1))
	var ps := load(SRC) as PackedScene
	if ps == null:
		print("[extract] cannot load %s" % SRC)
		get_tree().quit(1)
		return
	var root: Node3D = ps.instantiate()
	add_child(root)
	await get_tree().process_frame

	var mi := root.find_child(MESH_NAME, true, false) as MeshInstance3D
	var shell := root.find_child("psone_console", true, false) as MeshInstance3D
	var port := root.find_child("Playstation Controller Plug 1", true, false) as Node3D
	if mi == null or shell == null or port == null:
		print("[extract] missing source nodes")
		get_tree().quit(1)
		return

	# Where this plug is seated: the port column (its own x), the port row height
	# (the marker's y) and the console's front face less the recess inset.
	var plug_ab: AABB = mi.global_transform * mi.get_aabb()
	var shell_ab: AABB = shell.global_transform * shell.get_aabb()
	var seat := Vector3(plug_ab.get_center().x, port.global_position.y, shell_ab.end.z - PORT_INSET)
	# Yaw 180 so the connector ends up on +Z, matching the generic plug.
	var xf := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * Transform3D(Basis(), -seat)
	print("[extract] seat=%s" % seat)

	var src_mesh := mi.mesh
	var out := ArrayMesh.new()
	for si in src_mesh.get_surface_count():
		var arrays: Array = src_mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			verts[i] = xf * verts[i]
		arrays[Mesh.ARRAY_VERTEX] = verts
		if arrays[Mesh.ARRAY_NORMAL] != null:
			var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			for i in norms.size():
				norms[i] = xf.basis * norms[i]
			arrays[Mesh.ARRAY_NORMAL] = norms
		if arrays[Mesh.ARRAY_TANGENT] != null:
			var tans: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
			var i := 0
			while i + 3 < tans.size():
				var t: Vector3 = xf.basis * Vector3(tans[i], tans[i + 1], tans[i + 2])
				tans[i] = t.x; tans[i + 1] = t.y; tans[i + 2] = t.z
				i += 4
			arrays[Mesh.ARRAY_TANGENT] = tans
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		# Duplicate the material so the saved resource stands on its own (it then
		# references the extracted albedo PNG directly, not the GLB's sub-resource).
		var src_mat: Material = mi.get_surface_override_material(si)
		if src_mat == null:
			src_mat = src_mesh.surface_get_material(si)
		if src_mat != null:
			out.surface_set_material(si, src_mat.duplicate())

	var ab: AABB = out.get_aabb()
	print("[extract] baked aabb pos=%s end=%s size=%s" % [ab.position, ab.end, ab.size])
	var err := ResourceSaver.save(out, DST)
	print("[extract] save %s -> %s" % [DST, "OK" if err == OK else str(err)])
	get_tree().quit(0 if err == OK else 1)
