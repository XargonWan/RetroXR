## Extracts the Sega 9-pin controller connector and saves it as a standalone mesh
## for the Genesis / Mega Drive pad's cable end.
##
## Neither the Genesis console GLB nor either Mega Drive pad models a controller
## plug — the only plug prop on those shells is the silver A/V lead. an author's
## "Sega Mega Drive System (SMS.32X)" bundle DOES ship one, twice: `Port1 Connect`
## and `Port2 Connect`, posed in the two front ports. Its `megadrive_console` mesh
## is byte-for-byte the same dimensions as the plain Genesis shell, so it is the
## same base model with the 32X extras — which makes its plug the right connector
## for our pad, and its port coordinates directly transferable.
##
## The 16.5 MB source GLB is NOT kept — only the three texture sidecars the plug's
## own material references survive (they keep their `mega_drive_32x_` prefix, which
## is the provenance). To re-run this, convert the bundle back first:
##
##   python Tools/bundle_convert.py ##     "~/model-library/Retro bundle Collection/Retro bundle Collection/Custom/bundle/Consoles and Media/Sega/Sega Genesis/Sega_Mega_Drive_System_(SMS_32X)_e8f88480.bundle" ##     RetroVR/imported-assets/mega_drive_32x.glb
##   godot --headless --path RetroVR --editor --quit    # import it
##   godot --headless --path RetroVR res://Tools/extract_genesis_plug.tscn
##
## Baked into the ControllerPlug frame: origin at the seated position (the port
## column's x, the port marker's y, the console's front face z), connector +Z and
## cable trailing -Z.
extends Node

const SRC := "res://imported-assets/mega_drive_32x.glb"
const DST := "res://imported-assets/genesis_controller_plug.res"
const MESH_NAME := "Port1 Connect"
const PORT_MARKER := "Port1"
const SHELL_MESH := "megadrive_console"


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
	var shell := root.find_child(SHELL_MESH, true, false) as MeshInstance3D
	var port := root.find_child(PORT_MARKER, true, false) as Node3D
	if mi == null or shell == null or port == null:
		print("[extract] missing source nodes: mesh=%s shell=%s port=%s" % [mi, shell, port])
		get_tree().quit(1)
		return

	var plug_ab: AABB = mi.global_transform * mi.get_aabb()
	var shell_ab: AABB = shell.global_transform * shell.get_aabb()
	var seat := Vector3(plug_ab.get_center().x, port.global_position.y, shell_ab.end.z)
	# Yaw 180 so the connector ends up on +Z, matching the generic plug.
	var xf := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * Transform3D(Basis(), -seat)
	print("[extract] plug=%s shell_front_z=%.4f seat=%s" % [plug_ab, shell_ab.end.z, seat])

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
		var src_mat: Material = mi.get_surface_override_material(si)
		if src_mat == null:
			src_mat = src_mesh.surface_get_material(si)
		if src_mat != null:
			out.surface_set_material(si, src_mat.duplicate())
			if src_mat is BaseMaterial3D:
				var bm := src_mat as BaseMaterial3D
				for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL,
						BaseMaterial3D.TEXTURE_ORM, BaseMaterial3D.TEXTURE_METALLIC]:
					var t: Texture2D = bm.get_texture(slot)
					if t != null:
						print("[extract] surface %d texture: %s" % [si, t.resource_path])

	var ab: AABB = out.get_aabb()
	print("[extract] baked aabb pos=%s end=%s size=%s" % [ab.position, ab.end, ab.size])
	var err := ResourceSaver.save(out, DST)
	print("[extract] save %s -> %s" % [DST, "OK" if err == OK else str(err)])
	get_tree().quit(0 if err == OK else 1)
