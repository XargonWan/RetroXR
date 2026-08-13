## Which interactive controls are trapped inside their own shell's collision box.
##
## A nearest-hit interaction model can only reach a control that pokes out of
## whatever volume surrounds it. This spawns every model in the registry and, for
## each control it carries, asks whether that control's box sits wholly inside a
## single one of the shell's own boxes on the same query mask. Wholly inside means
## a ray from any direction meets the shell first and the control is unreachable.
##
##   godot --headless --path RetroXR res://Tools/shell_enclosure_audit.tscn
##
## Convexity caveat: "inside a SINGLE shell box" — a control enclosed by two shell
## boxes together but by neither alone reads as reachable. The shells are slabs, so
## that is rare, but it is why this is an audit and not a proof.
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")

## The pointer ray's mask (21:XRPointer, 23) and the pickup ray's (3:Pickable).
const POINTER_BITS := 0b0000_0000_0101_0000_0000_0000_0000_0000
const PICKUP_BITS := 4

var _rows: Array = []


func _ready() -> void:
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		print("[audit] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


## Platforms with no bespoke model, so they wear the procedural console. Not in
## all_ids() — placeholder_row() sits outside the registry — and it is the shell
## the great majority of the room's hardware actually uses, one loader each.
const PLAIN_PLATFORMS := ["genesis", "snes", "n64", "playstation", "ps2"]


func _run() -> void:
	var ids: Array = SystemModelRegistry.all_ids()
	print("[audit] %d models in the registry, plus %d procedural"
		% [ids.size(), PLAIN_PLATFORMS.size()])
	for id in ids:
		await _audit(str(id))
	for platform in PLAIN_PLATFORMS:
		await _audit("", str(platform))
	_report()
	get_tree().quit(0)


func _audit(model_id: String, plain_platform: String = "") -> void:
	var platform := plain_platform
	var label := "procedural/%s" % plain_platform
	if plain_platform.is_empty():
		var row: Dictionary = SystemModelRegistry.row_for(model_id)
		# A row can serve a whole family (the PC tower covers 18 home computers).
		# Any one of them stands the same shell up.
		var served: Variant = row.get("platform", "")
		platform = str(served[0]) if served is Array and not served.is_empty() else str(served)
		label = model_id
	if platform.is_empty():
		return
	model_id = label

	print("[audit] -> %s (%s)" % [label, platform])
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = platform
	sys.model_id = "" if not plain_platform.is_empty() else model_id
	sys.position = Vector3(0, 1, 0)
	sys.ignore_gravity = true
	add_child(sys)
	await _wait(25)

	var inv := sys.global_transform.affine_inverse()
	# The shell's own volumes, split by which ray can see them.
	var shell_pointer: Array[AABB] = []
	var shell_pickup: Array[AABB] = []
	_collect_shell(sys, inv, shell_pointer, shell_pickup)
	var shell_union := AABB()
	for s in shell_pointer + shell_pickup:
		shell_union = s if shell_union.size == Vector3.ZERO else shell_union.merge(s)

	var checked := 0
	for control in _controls(sys):
		var body: CollisionObject3D = control["body"]
		var bits: int = body.collision_layer
		var shell: Array[AABB] = []
		if (bits & POINTER_BITS) != 0:
			shell = shell_pointer
		elif (bits & PICKUP_BITS) != 0:
			shell = shell_pickup
		else:
			continue
		checked += 1
		var box: AABB = control["aabb"]
		var buried := _deepest_burial(box, shell)
		# The question a nearest-hit resolver actually asks: aiming at this control
		# from outside, along the face it sits on, is it the FIRST thing hit? Burial
		# alone misses a control that pokes out of some other face and is still
		# shadowed from the side you would reach for it.
		var shadow := _shadowed_by(sys, body, box, shell_union, bits)
		if buried <= 0.0 and shadow.is_empty():
			continue
		_rows.append({
			"model": model_id,
			"name": str(control["name"]),
			"kind": str(control["kind"]),
			"depth": buried,
			"shadow": shadow,
			"size": box.size,
		})
	print("[audit] %-22s %-14s %2d controls" % [model_id, platform, checked])
	if _verbose_for(model_id):
		for i in range(shell_pointer.size()):
			print("[audit]      shell/pointer[%d] %s" % [i, _fmt(shell_pointer[i])])
		for i in range(shell_pickup.size()):
			print("[audit]      shell/pickup [%d] %s" % [i, _fmt(shell_pickup[i])])
		for control in _controls(sys):
			print("[audit]      control %-18s %-8s %s"
				% [control["name"], control["kind"], _fmt(control["aabb"])])

	sys.queue_free()
	await _wait(5)


## How far inside the nearest shell face this control sits, in metres, or <= 0 when
## some face of it reaches outside every shell box. The margin of the box it is
## most comfortably buried in, so a control poking out of one slab but inside
## another still reads as reachable.
func _deepest_burial(box: AABB, shell: Array[AABB]) -> float:
	var best := -INF
	for s in shell:
		var margin: float = INF
		margin = minf(margin, box.position.x - s.position.x)
		margin = minf(margin, box.position.y - s.position.y)
		margin = minf(margin, box.position.z - s.position.z)
		margin = minf(margin, s.end.x - box.end.x)
		margin = minf(margin, s.end.y - box.end.y)
		margin = minf(margin, s.end.z - box.end.z)
		best = maxf(best, margin)
	return best


## Aim at this control from outside, along the shell face it sits nearest, and
## name whatever the ray meets first if it is not the control. Empty when the
## control wins its own approach.
func _shadowed_by(sys: RetroSystem, body: CollisionObject3D, box: AABB,
		shell: AABB, bits: int) -> String:
	if shell.size == Vector3.ZERO:
		return ""
	# The face this control belongs to: the axis it is furthest off-centre on,
	# measured in half-extents so a long flat shell does not always answer "top".
	var off := box.get_center() - shell.get_center()
	var half := shell.size * 0.5
	var norm := Vector3(
		off.x / maxf(half.x, 0.0001),
		off.y / maxf(half.y, 0.0001),
		off.z / maxf(half.z, 0.0001))
	# Every face, not just the likeliest one. A control low on a tall device has
	# its largest offset downward, and testing only that approach aims up through
	# the floor and calls the base plate a blocker — the control is perfectly
	# reachable from the side. Blocked only when NO approach is clear.
	var dirs: Array[Vector3] = [
		Vector3(signf(norm.x), 0, 0), Vector3(0, signf(norm.y), 0),
		Vector3(0, 0, signf(norm.z)), Vector3(-signf(norm.x), 0, 0),
		Vector3(0, -signf(norm.y), 0), Vector3(0, 0, -signf(norm.z))]
	var centre_w: Vector3 = sys.global_transform * box.get_center()
	var mask := POINTER_BITS if (bits & POINTER_BITS) != 0 else PICKUP_BITS
	var blocker := "nothing"
	for dir in dirs:
		if dir == Vector3.ZERO:
			continue
		var dir_w: Vector3 = (sys.global_transform.basis * dir).normalized()
		var q := PhysicsRayQueryParameters3D.create(centre_w + dir_w * 0.5, centre_w, mask)
		q.collide_with_bodies = true
		q.collide_with_areas = true
		var hit := sys.get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty():
			continue
		var node := hit.collider as Node
		while node != null:
			if node == body:
				return ""
			node = node.get_parent()
		blocker = str((hit.collider as Node).name)
	return blocker


func _collect_shell(sys: RetroSystem, inv: Transform3D,
		into_pointer: Array[AABB], into_pickup: Array[AABB]) -> void:
	for node: Node in [sys, sys.get_node_or_null("PointerArea")]:
		var body := node as CollisionObject3D
		if body == null:
			continue
		var target := into_pointer if (body.collision_layer & POINTER_BITS) != 0 else into_pickup
		for entry in _shapes_of(body, inv):
			target.append(entry["aabb"])


## Every control the resolver could classify as something other than the console.
func _controls(sys: RetroSystem) -> Array:
	var inv := sys.global_transform.affine_inverse()
	var out: Array = []
	var stack: Array[Node] = [sys]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var body := node as CollisionObject3D
		if body == null or body == sys or body.name == "PointerArea":
			continue
		var kind := _kind_of(body)
		if kind.is_empty():
			continue
		for entry in _shapes_of(body, inv):
			out.append({
				"body": body,
				"name": body.name,
				"kind": kind,
				"aabb": entry["aabb"],
			})
	return out


## The resolver's own classification order, for the node itself only — its
## ancestors are the console, which is what it is competing against.
func _kind_of(body: CollisionObject3D) -> String:
	if body is VRButton:
		return "button"
	if body is XRToolsSnapZone:
		return "snap"
	if body.has_method("pointer_event") or body.has_signal("pointer_event"):
		return "pointer"
	return ""


func _shapes_of(body: CollisionObject3D, inv: Transform3D) -> Array:
	var out: Array = []
	for owner_id_raw in body.get_shape_owners():
		var owner_id := int(owner_id_raw)
		if body.is_shape_owner_disabled(owner_id):
			continue
		for i in body.shape_owner_get_shape_count(owner_id):
			var shape := body.shape_owner_get_shape(owner_id, i)
			if shape == null:
				continue
			var local := body.global_transform * body.shape_owner_get_transform(owner_id)
			var extent := _extent_of(shape)
			if extent == Vector3.ZERO:
				continue
			var t := inv * local
			var centre := t.origin
			# Conservative AABB of the (possibly rotated) box in host space.
			var half := (t.basis * extent).abs() \
				+ (t.basis * Vector3(extent.x, -extent.y, extent.z)).abs()
			half *= 0.5
			out.append({"aabb": AABB(centre - half, half * 2.0)})
	return out


func _extent_of(shape: Shape3D) -> Vector3:
	if shape is BoxShape3D:
		return (shape as BoxShape3D).size * 0.5
	if shape is SphereShape3D:
		var r := (shape as SphereShape3D).radius
		return Vector3(r, r, r)
	if shape is CylinderShape3D:
		var c := shape as CylinderShape3D
		return Vector3(c.radius, c.height * 0.5, c.radius)
	if shape is CapsuleShape3D:
		var p := shape as CapsuleShape3D
		return Vector3(p.radius, p.height * 0.5, p.radius)
	return Vector3.ZERO


func _report() -> void:
	print("")
	print("[audit] ==== controls buried inside their own shell ====")
	if _rows.is_empty():
		print("[audit] none")
		return
	_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["depth"]) > float(b["depth"]))
	print("[audit] %-24s %-18s %-8s %8s  %s"
		% ["model", "control", "kind", "buried", "first hit aiming at it"])
	for r in _rows:
		var d: float = float(r["depth"])
		print("[audit] %-24s %-18s %-8s %8s  %s"
			% [r["model"], r["name"], r["kind"],
				("%.1fmm" % (d * 1000.0)) if d > 0.0 else "-",
				str(r["shadow"]) if not str(r["shadow"]).is_empty() else "(reachable)"])
	print("[audit] %d buried of %d models" % [_rows.size(), _rows.size()])


## Models whose boxes are dumped in full, named on the command line:
##   -- --dump=virtual_boy_primitive,atari_2600
func _verbose_for(model_id: String) -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dump="):
			for want in a.split("=")[1].split(","):
				if model_id.contains(want):
					return true
	return false


func _fmt(a: AABB) -> String:
	return "x %7.1f..%7.1f  y %7.1f..%7.1f  z %7.1f..%7.1f  (mm)" % [
		a.position.x * 1000.0, a.end.x * 1000.0,
		a.position.y * 1000.0, a.end.y * 1000.0,
		a.position.z * 1000.0, a.end.z * 1000.0]


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame
