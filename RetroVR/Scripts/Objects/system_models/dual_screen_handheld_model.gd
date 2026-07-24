## RetroSystemModelDualScreen — clamshell dual-screen handhelds (DS / 3DS).
##
## Dual-screen cores render BOTH screens into one composite framebuffer
## (melonDS top/bottom stacked 256×384; patched azahar side-by-side stereo
## 400×480). The C++ VideoHandler drives ONE mesh — a hidden proxy quad
## (the Virtual Boy pattern) — and this model feeds the proxy's emission
## texture into a screen_window ShaderMaterial per visible screen quad:
##   * each quad's `source_rect` selects its region of the composite, and
##   * a stereo top screen (3DS) adds `eye_shift` so the RIGHT eye samples the
##     right-eye half (VIEW_INDEX) — real depth in the headset.
##
## The visible shell — base, hinged lid, both screens + bezels, the touch area,
## the hidden proxy quad, the grabbable lid hinge, cosmetics, and the volume
## slider — is authored in the per-device scene (nds.tscn / n3ds.tscn). This
## script caches those nodes, builds the two window ShaderMaterials at runtime
## (source_tex is live core output — it can only be bound per-frame), feeds the
## screens, and handles touch input.
##
## Video-out: TWO cables (get_video_channels), TOP and BOTTOM, each with its
## own labelled port on the back edge. RetroSystem mirrors the same proxy
## texture onto each connected TV through the same shader, and taps on the
## BOTTOM TV feed the touch screen.
##
## Subclasses set the composite UV rects + stereo eye_shift in _init.
class_name RetroSystemModelDualScreen
extends RetroSystemModelHandheld

const SCREEN_WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

# Base local frame is the handheld convention: flat, top face +Y, hinge/back
# edge -Z. The lid pivots at the back-top edge (LidPivot, authored in the scene).

## Physical bottom-screen size in metres — read back from the authored
## BottomScreen quad; drives the touch-area UV mapping.
var bottom_screen_size := Vector2(0.061, 0.0457)
## Each screen's region of the composite core framebuffer (set in subclass _init).
var top_uv_rect := Rect2(0.0, 0.0, 1.0, 0.5)
var bottom_uv_rect := Rect2(0.0, 0.5, 1.0, 0.5)
## Right-eye UV-x shift for a stereo side-by-side composite (3DS azahar).
## 0 = mono core output (DS).
var top_eye_shift := 0.0

var _bottom_screen: MeshInstance3D = null
# Screen-cast light for the bottom screen (the base handles the top via _screen).
var _bottom_screen_light: OmniLight3D = null
var _lid_pivot: Node3D = null
# Grabbable lid hinge. The lid's rotation about X lives on _lid_pivot (0 = flat /
# 180° interior open, 180 = folded shut); the public angle (get/set_lid_angle_deg)
# is the interior open angle, 180 minus that rotation.
var _hinge: VRHinge = null
var _touch: Area3D = null
# Hidden proxy quad the C++ VideoHandler renders the composite into.
var _proxy: MeshInstance3D = null
# screen_window materials feeding each quad from the proxy's texture.
var _top_mat: ShaderMaterial = null
var _bottom_mat: ShaderMaterial = null
# Unlit-LCD materials shown while no core picture exists (authored on the quads).
var _top_off_mat: StandardMaterial3D = null
var _bottom_off_mat: StandardMaterial3D = null
# VR fingertip touch state (per engaged controller).
var _touch_ctrl: XRController3D = null
var _touch_pointer_down := false
var _touch_controllers: Array[XRController3D] = []


## Measure only the base (bottom clamshell half) when placing the system name
## label, so it lands on the base's front — the same +Z face the START button
## sits on — rather than over the raised lid / top screen. (Used by
## RetroSystem._body_aabb / _place_name_label.)
func name_label_body() -> Node3D:
	# The stand-in body only exists on the fallback path; with the detailed shell
	# in, the base half IS the Shell subtree (its lid rides LidPivot).
	var body := find_child("HandheldBody", true, false) as Node3D
	return body if body != null else get_node_or_null("Shell")


## Upright on the base's vertical front (+Z) face (where the START button is),
## centred and filling most of the thin base height — not flat on the top.
func name_label_placement() -> Dictionary:
	return {"upright": true, "v_center": 0.5, "h_frac": 0.72}


## Force the stand-in shell even when the detailed GLB is present. The fallback
## path is otherwise never exercised in development (imported-assets/ is always
## there), so this is what a probe flips to keep it honest.
@export var force_primitive_shell: bool = false


func _ready() -> void:
	var gp := _glb_path()
	var detailed := not force_primitive_shell and not gp.is_empty() and ResourceLoader.exists(gp)
	# The stand-in is a SEPARATE scene, added only when there's no detailed shell,
	# instead of living in the device scene permanently and being hidden. Nothing
	# invisible is left behind to be measured by mistake — which is exactly how
	# body_size used to come from a 133x11x74 box the player never sees.
	if not detailed:
		_spawn_primitive_shell()
	_cache_dual_nodes()
	if detailed:
		_upgrade_dual_to_glb(gp)
	# Screen-cast lights: both screens glow into the room (base _ready — which sets
	# up the single-screen light — is not called here, so create both explicitly).
	_screen_light = _make_screen_light(_screen)
	_bottom_screen_light = _make_screen_light(_bottom_screen)
	# Editor-only cart-seat preview box — hide at runtime (base _ready, which does
	# this for single-screen handhelds, is not called here).
	var seat_preview := find_child("SeatPreview", true, false)
	if seat_preview is Node3D:
		(seat_preview as Node3D).visible = false
	# Window materials, ready before the first frame of core output.
	_top_mat = ShaderMaterial.new()
	_top_mat.shader = SCREEN_WINDOW_SHADER
	_bottom_mat = ShaderMaterial.new()
	_bottom_mat.shader = SCREEN_WINDOW_SHADER
	_apply_window_params()
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_touch_controllers.append(node as XRController3D)


## Override to return a detailed clamshell GLB (imported); "" keeps the primitive
## shell (store builds — imported-assets/* is export-excluded).
func _glb_path() -> String:
	return ""


## Both screens cast light (base drives only the top via _screen).
func _update_screen_light() -> void:
	_drive_screen_light(_screen, _screen_light)
	_drive_screen_light(_bottom_screen, _bottom_screen_light)


## Exact mesh names in the GLB that belong to the LID (fold with the hinge).
## Everything else is the base half. Override per device.
func _lid_mesh_names() -> PackedStringArray:
	return PackedStringArray()


## Forward (toward +Z, away from the very back edge) correction added to the
## computed hinge Z position. 0 by default — the base's back bounding-box edge
## is a fine hinge estimate on most shells. Override when a shell's real hinge
## sits measurably forward of that edge (see n3ds_model.gd for how this was
## derived: solve for the Z that makes the CLOSED lid's footprint match the
## base's footprint, since the naive back-edge estimate is invisible at the
## open angle the GLB ships in and only shows up once you swing the lid shut).
func _hinge_z_offset() -> float:
	return 0.0


## Downward correction added to the computed hinge Y position (base_top_y —
## the base shell's own top face). 0 by default. Override when the real hinge
## barrel sits measurably below the base's top face, which the naive estimate
## can't see any more than the Z case above can — see n3ds_model.gd.
func _hinge_y_offset() -> float:
	return 0.0


## Override to return the store-safe stand-in shell scene; "" = no fallback
## geometry (the device scene carries its own, the old arrangement).
func _primitive_path() -> String:
	return ""


## Add the stand-in shell. Its root holds the base-half meshes directly and its
## lid parts under a "LidParts" child, which is reparented onto LidPivot so the
## stand-in folds with the hinge exactly like the detailed shell's lid does.
func _spawn_primitive_shell() -> void:
	var pp := _primitive_path()
	if pp.is_empty() or has_node("Primitive") or not ResourceLoader.exists(pp):
		return
	var scene := load(pp) as PackedScene
	if scene == null:
		return
	var prim := scene.instantiate() as Node3D
	prim.name = "Primitive"
	add_child(prim)
	var lid_parts := prim.get_node_or_null("LidParts") as Node3D
	var pivot := get_node_or_null("LidPivot") as Node3D
	if lid_parts != null and pivot != null:
		lid_parts.reparent(pivot, false)


## Swap the primitive clamshell for the detailed GLB. The base script's runtime
## nodes stay authoritative — the live TopScreen/BottomScreen picture quads, the
## ProxyScreen, the TouchScreen pad, the grabbable LidHinge — but they get moved
## onto the GLB's real geometry: centre the base half at the origin, split the
## lid meshes onto LidPivot so they fold with the hinge (LidPivot's rest rotation
## derived from the top lens's normal, its pivot from where the lid plane meets
## the base's top face), drop the picture quads onto the GLB screen lenses, resize
## the base collision + touch pad, and hide the primitive stand-ins, the GLB's own
## opaque screen lenses, and its bundled AV lead. Idempotent (skips if the base
## is already GLB-scaled from a prior run / baked scene).
## Baked-scene cleanup: the editable "Shell" instance re-creates the GLB's own
## lid meshes on load, even though the bake reparented UNROTATED copies onto
## LidPivot — so the Shell-side originals reappear at their authored open-pose
## rotation and float free of the console. Hide those duplicates, plus the GLB's
## own opaque screen lenses + LCD backing (the live TopScreen/BottomScreen quads
## replace them). Runtime-only fix — the baked .tscn is untouched.
func _hide_baked_shell_dupes() -> void:
	var shell := get_node_or_null("Shell") as Node3D
	if shell == null:
		return
	if _lid_pivot != null:
		for lp in _lid_pivot.find_children("*", "MeshInstance3D", true, false):
			var dup := shell.find_child(lp.name, true, false) as MeshInstance3D
			if dup != null:
				dup.visible = false
	for n in shell.find_children("*", "MeshInstance3D", true, false):
		var nm := String(n.name)
		if nm == "screen_mesh Top" or nm == "screen_mesh Bottom" or nm.to_lower().contains("backface"):
			(n as MeshInstance3D).visible = false


func _upgrade_dual_to_glb(path: String) -> void:
	if _lid_pivot == null or _screen == null or _bottom_screen == null:
		return
	# Fully baked into the .tscn already (Shell + reparented lid + placed screens
	# + hidden primitives authored in the scene) — no placement to redo. body_size
	# still has to be adopted from the real shell: _cache_dual_nodes seeds it from
	# the primitive HandheldBody box, and on this path nothing ever overwrote it,
	# so collision, the pointer area, the cart slot depth, the cable attach point
	# and the power button were all sized to a stand-in the player can't even see.
	if has_meta("dual_glb_baked"):
		_hide_baked_shell_dupes()
		var baked := _base_half_size()
		if baked.length() > 0.0:
			body_size = baked
		_setup_lid_grab()
		return
	var shell := get_node_or_null("Shell") as Node3D
	if shell == null:
		var scene := load(path) as PackedScene
		if scene == null:
			return
		shell = scene.instantiate() as Node3D
		shell.name = "Shell"
		var ap := shell.find_child("AnimationPlayer", true, false) as AnimationPlayer
		if ap != null:
			ap.autoplay = ""
		add_child(shell)
	_hide_glb_clutter(shell)

	# Split GLB meshes into lid vs base, and grab the two GLB screen lenses.
	var lidnames := _lid_mesh_names()
	var lid_meshes: Array[MeshInstance3D] = []
	var glb_top: MeshInstance3D = null
	var glb_bottom: MeshInstance3D = null
	var base_aabb := AABB()
	var base_first := true
	var stack: Array[Node] = [shell]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			var nm := String(mi.name)
			if nm == "screen_mesh Top":
				glb_top = mi
			elif nm == "screen_mesh Bottom":
				glb_bottom = mi
			elif nm.to_lower().contains("backface"):
				mi.visible = false   # dark LCD backing — the live picture quad replaces it
			elif mi.visible:
				if lidnames.has(nm):
					# Drop any rotation the lid mesh carries in its own right. The
					# New 3DS XL's `top` (and its two slider knobs) ship a -65.7
					# degree quaternion about X — an authored open pose whose PIVOT
					# the .bundle conversion lost, so it swings about the model origin
					# instead of the hinge and throws the lid below and behind the
					# console. The giveaway is that `screen_mesh Top`, the lid's own
					# lens, carries no rotation: unrotate the lid and the two land in
					# the same place. The fold belongs to LidPivot, not to the mesh.
					mi.transform.basis = Basis()
					lid_meshes.append(mi)
				else:
					var ab := _local_aabb(mi)
					base_aabb = ab if base_first else base_aabb.merge(ab)
					base_first = false
		for c in n.get_children():
			stack.append(c)
	if glb_top == null or glb_bottom == null or base_first:
		return

	# Centre the base half on the model origin (base mid-thickness → y=0) — unless
	# it's already centred (a baked scene where the Shell was authored pre-centred).
	var base_ctr := base_aabb.position + base_aabb.size * 0.5
	if base_ctr.length() > 0.001:
		shell.position -= base_ctr
	body_size = base_aabb.size
	var base_top_y := base_aabb.size.y * 0.5

	var top_ab := _local_aabb(glb_top)
	var top_ctr := top_ab.position + top_ab.size * 0.5
	var bot_ab := _local_aabb(glb_bottom)
	var bot_ctr := bot_ab.position + bot_ab.size * 0.5

	# Hinge at the base's back-top edge (the clamshell pivot). The lid's open angle
	# is the direction hinge → top-lens centre; the top screen's outward normal is
	# perpendicular to that, facing up-and-forward. Derive orientation from the
	# FOLD, not the GLB lens-mesh normals — on some devices `screen_mesh Top` is a
	# small angled trim strip whose normal doesn't match the lid's screen plane.
	# _hinge_y_offset / _hinge_z_offset let a device nudge the pivot off the
	# base's raw bounding-box top-back corner — see n3ds_model.gd, where the
	# real hinge barrel sits measurably forward AND below that corner (interactively
	# calibrated in Tools/n3ds_hinge_calibrator.tscn) and the naive corner
	# overshot the lid's swept closed position (overhanging the back, short of
	# the front, and rotating around the wrong height).
	var hinge := Vector3(0.0, base_top_y + _hinge_y_offset(), -base_aabb.size.z * 0.5 + _hinge_z_offset())
	var lid_dir := top_ctr - hinge
	lid_dir.x = 0.0
	lid_dir = lid_dir.normalized()
	var top_n := Vector3(0.0, -lid_dir.z, lid_dir.y).normalized()
	# ...but prefer the lens's OWN normal when the mesh really is one flat plane.
	# The fold is only an estimate of the lid angle: it assumes the lens centre
	# sits on the line the lid folds along, and on the DS Phat it does not — the
	# fold says the lid is open 123 degrees while its glass is a clean 45 degree
	# plane, so the picture sat 12 degrees off the panel it is meant to be lying
	# on. The planarity test is what keeps this safe on shells where the lens is a
	# little angled trim strip rather than the screen surface.
	var flat := _planar_normal(glb_top)
	if flat != Vector3.ZERO:
		flat.x = 0.0
		if flat.length() > 0.001:
			top_n = flat.normalized()
	if top_n.y < 0.0:
		top_n = -top_n
	var rest_rot := top_n.angle_to(Vector3.UP)
	_lid_pivot.transform = Transform3D(Basis(Vector3.RIGHT, rest_rot), hinge)

	# Split the lid meshes onto LidPivot so they fold with the hinge; the live
	# TopScreen quad already rides there (authored under LidPivot).
	for mi in lid_meshes:
		mi.reparent(_lid_pivot, true)

	# Live picture quads onto the GLB lenses (a hair proud of the opaque lens so
	# the picture wins the depth test), sized to the lens, facing its normal.
	var top_size := Vector2(maxf(top_ab.size.x, 0.001),
		maxf(sqrt(top_ab.size.y * top_ab.size.y + top_ab.size.z * top_ab.size.z), 0.001))
	# Raise each live quad clear of the lid/base outer glass (part of the shell
	# meshes, which render opaque here) so the picture wins the depth test — the
	# offset scales with how deep the lid's own screen surface sits over the lens.
	var top_clear := _lens_clearance(top_ctr, top_n, top_size)
	_place_screen(_screen, top_ctr + top_n * top_clear, top_n, top_size)
	var bot_size := Vector2(maxf(bot_ab.size.x, 0.001), maxf(bot_ab.size.z, 0.001))
	var bot_clear := _lens_clearance(bot_ctr, Vector3.UP, bot_size)
	_place_screen(_bottom_screen, bot_ctr + Vector3.UP * bot_clear, Vector3.UP, bot_size)
	bottom_screen_size = bot_size
	if _screen.mesh is QuadMesh:
		var qt := (_screen.mesh as QuadMesh).duplicate() as QuadMesh
		qt.size = top_size
		_screen.mesh = qt
	if _bottom_screen.mesh is QuadMesh:
		var qb := (_bottom_screen.mesh as QuadMesh).duplicate() as QuadMesh
		qb.size = bot_size
		_bottom_screen.mesh = qb

	# ProxyScreen + TouchScreen ride the bottom lens.
	if _proxy != null:
		_proxy.position = to_local(_bottom_screen.global_position)
	if _touch != null:
		_touch.global_position = _bottom_screen.global_position
		var tcol := _touch.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if tcol != null and tcol.shape is BoxShape3D:
			tcol.shape = tcol.shape.duplicate()
			(tcol.shape as BoxShape3D).size = Vector3(bot_size.x, 0.012, bot_size.y)

	# Hide the GLB's opaque lenses (the live quads replace them) and every
	# authored primitive stand-in (body, lid, bezels, buttons, knobs — anywhere in
	# the tree, incl. under LidPivot) — the GLB shell carries the real ones. Keep
	# the live picture quads and the reparented GLB lid meshes.
	glb_top.visible = false
	glb_bottom.visible = false
	var keep: Array = [_screen, _bottom_screen, _proxy]
	for lm in lid_meshes:
		keep.append(lm)
	var hstack: Array[Node] = [self]
	while not hstack.is_empty():
		var hn: Node = hstack.pop_back()
		var hmi := hn as MeshInstance3D
		if hmi != null and not keep.has(hmi) and not shell.is_ancestor_of(hmi):
			hmi.visible = false
		for hc in hn.get_children():
			hstack.append(hc)

	# This pass is NOT re-runnable, so claim the same flag the authored-baked
	# scenes use. It measures the base half from the visible meshes and then hides
	# the lid's lens — so a second call measures a DIFFERENT base, moves the hinge,
	# and drags the already-reparented lid with it. That is what threw the 3DS lid
	# off the back of the console: `top` ended up 13.6 cm out on Z carrying a 91
	# degree roll it never should have had.
	set_meta("dual_glb_baked", true)
	_setup_lid_grab()


## Size the lid's grab hinge to the TOP (free) HALF of the lid face — the part
## farther from the hinge, which ends up on top when the lid is raised. The grab
## box, the VR proximity sphere and the floating hint icon are all placed off the
## live TopScreen quad (both it and LidHinge are LidPivot children, so this is one
## local frame), so it tracks whatever pose the lid was calibrated into.
func _setup_lid_grab() -> void:
	if _hinge == null or _screen == null or _lid_pivot == null:
		return
	if not (_screen.mesh is QuadMesh):
		return
	var qsize: Vector2 = (_screen.mesh as QuadMesh).size
	var w: float = maxf(qsize.x, 0.01)
	var h: float = maxf(qsize.y, 0.01)
	var st: Transform3D = _screen.transform          # quad-local → LidPivot-local
	# Which ±Y edge of the quad is the FREE edge (farther from the hinge at the
	# LidPivot origin)? The grab half centres on that edge's side.
	var e_pos: Vector3 = st * Vector3(0.0, h * 0.5, 0.0)
	var e_neg: Vector3 = st * Vector3(0.0, -h * 0.5, 0.0)
	var free_sign: float = 1.0 if e_pos.length() >= e_neg.length() else -1.0
	var center_local: Vector3 = st * Vector3(0.0, free_sign * h * 0.25, 0.0)
	var basis: Basis = st.basis.orthonormalized()
	_hinge.transform = Transform3D(basis, center_local)
	var col := _hinge.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = Vector3(w, h * 0.5, 0.02)
	# VR proximity sphere covers the free half; icon floats off the face normal
	# (quad local +Z) a touch toward the free edge.
	_hinge.engage_radius = clampf(maxf(w, h * 0.5) * 0.55, 0.03, 0.07)
	_hinge.icon_offset = Vector3(0.0, free_sign * 0.008, 0.045)


## How far the shell's own (opaque) glass/surface sits over a lens along its
## normal, so the live picture quad can be raised just clear of it. Samples the
## shell body meshes within the screen footprint; falls back to a small default.
## Dimensions of the BASE half of whatever shell is actually present, in model
## space. On the runtime path the lid meshes are reparented onto LidPivot, but a
## BAKED scene can leave them under Shell (nds_lite.tscn does), so the lid names
## are excluded explicitly rather than assumed to have moved — otherwise this
## measures the whole OPEN clamshell and the body comes out twice as tall.
func _base_half_size() -> Vector3:
	var shell := get_node_or_null("Shell") as Node3D
	if shell == null:
		return Vector3.ZERO
	var lidnames := _lid_mesh_names()
	var acc := AABB()
	var first := true
	for n in shell.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.visible or lidnames.has(String(mi.name)):
			continue
		var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
		acc = ab if first else acc.merge(ab)
		first = false
	return Vector3.ZERO if first else acc.size


## How far to hold the picture off the shell surface once that surface has been
## measured. This only has to beat depth-buffer precision — the geometry is
## already accounted for — so it wants to be as small as will not z-fight. It was
## 0.8 mm, which is most of a millimetre of visible gap on something you hold in
## your hands: the DS Phat's bottom picture read as floating a hair off the
## console, because `best` under that screen is 0.2 mm and the margin was the
## rest of it.
const _DEPTH_MARGIN := 0.0002


func _lens_clearance(center: Vector3, normal: Vector3, size: Vector2) -> float:
	var shell := get_node_or_null("Shell") as Node3D
	if shell == null:
		return _DEPTH_MARGIN * 2.0
	var n := normal.normalized()
	# Test the lens's own RECTANGULAR footprint, built on the same basis
	# _place_screen uses so it matches the quad exactly. This used to be a circle
	# of half the LARGER dimension, which on a 63x49 mm screen reaches 32 mm out
	# — past the bezel into the surrounding shell. On the DS Phat, whose lower
	# half is one big mesh with a raised surround, that picked up shell 11.4 mm
	# above the lens and floated the live picture that far off the console.
	var up_hint := Vector3.FORWARD if absf(n.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var ax := up_hint.cross(n)
	if ax.length() < 1e-5:
		ax = Vector3.RIGHT
	ax = ax.normalized()
	var ay := n.cross(ax).normalized()
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var best := 0.0
	var stack: Array[Node] = [shell]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var mi := node as MeshInstance3D
		if mi != null and mi.visible and mi.mesh != null:
			var nm := String(mi.name)
			if not nm.begins_with("screen_mesh") and not nm.to_lower().contains("rca"):
				var xf := global_transform.affine_inverse() * mi.global_transform
				var arr := mi.mesh.surface_get_arrays(0)
				var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				for v in verts:
					var p := xf * v - center
					var along := p.dot(n)
					if along <= 0.0 or along >= 0.02:
						continue
					var inplane := p - n * along
					if absf(inplane.dot(ax)) <= hx and absf(inplane.dot(ay)) <= hy:
						best = maxf(best, along)
		for c in node.get_children():
			stack.append(c)
	return best + _DEPTH_MARGIN


## Position + orient a screen quad (QuadMesh normal is +Z) to face `normal` at
## `where`, both given in this model node's LOCAL space. Set via global_transform
## so it's correct regardless of the quad's parent (TopScreen rides LidPivot).
func _place_screen(quad: MeshInstance3D, where: Vector3, normal: Vector3, _size: Vector2) -> void:
	var z := normal.normalized()
	var up_hint := Vector3.FORWARD if absf(z.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var x := up_hint.cross(z)
	if x.length() < 1e-5:
		x = Vector3.RIGHT
	x = x.normalized()
	var y := z.cross(x).normalized()
	quad.global_transform = global_transform * Transform3D(Basis(x, y, z), where)


## Bundled AV lead / plug (RetroVR spawns its own video-out cables).
func _hide_glb_clutter(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			var nm := String(mi.name).to_lower()
			if nm.contains("rca") or nm.contains("cable") or nm.contains("plug"):
				mi.visible = false
		for c in n.get_children():
			stack.append(c)


## AABB of a mesh in this model node's local space.
func _local_aabb(mi: MeshInstance3D) -> AABB:
	return (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()


## Cache the authored shell nodes and read the dimensions the runtime logic needs.
func _cache_dual_nodes() -> void:
	_lid_pivot = get_node_or_null("LidPivot")
	_screen = get_node_or_null("LidPivot/TopScreen") as MeshInstance3D
	_bottom_screen = get_node_or_null("BottomScreen") as MeshInstance3D
	_proxy = get_node_or_null("ProxyScreen") as MeshInstance3D
	_touch = get_node_or_null("TouchScreen") as Area3D
	_hinge = get_node_or_null("LidPivot/LidHinge") as VRHinge
	_volume_slider = get_node_or_null("VolumeSlider") as VRSlider
	# find_child, not get_node: the stand-in shell is a "Primitive" subtree now.
	var body := find_child("HandheldBody", true, false) as MeshInstance3D
	if body and body.mesh is BoxMesh:
		body_size = (body.mesh as BoxMesh).size
	if _bottom_screen and _bottom_screen.mesh is QuadMesh:
		bottom_screen_size = (_bottom_screen.mesh as QuadMesh).size
	if _screen:
		_top_off_mat = _screen.get_surface_override_material(0) as StandardMaterial3D
	if _bottom_screen:
		_bottom_off_mat = _bottom_screen.get_surface_override_material(0) as StandardMaterial3D


## Interior open angle in degrees: 0 = folded shut, 180 = flat open.
func get_lid_angle_deg() -> float:
	return 180.0 - rad_to_deg(_lid_pivot.rotation.x) if _lid_pivot else 180.0


## Set the interior open angle (0 shut … 180 flat).
func set_lid_angle_deg(open_deg: float) -> void:
	var rot := clampf(180.0 - open_deg, 0.0, 180.0)
	if _hinge:
		_hinge.set_rotation_deg_no_signal(rot)
	elif _lid_pivot:
		_lid_pivot.rotation.x = deg_to_rad(rot)


## Push the UV windows onto the window materials (rects are set by subclass
## _init, so once at build time is enough).
func _apply_window_params() -> void:
	_top_mat.set_shader_parameter("source_rect",
		Vector4(top_uv_rect.position.x, top_uv_rect.position.y,
			top_uv_rect.size.x, top_uv_rect.size.y))
	_top_mat.set_shader_parameter("eye_shift", top_eye_shift)
	_bottom_mat.set_shader_parameter("source_rect",
		Vector4(bottom_uv_rect.position.x, bottom_uv_rect.position.y,
			bottom_uv_rect.size.x, bottom_uv_rect.size.y))
	_bottom_mat.set_shader_parameter("eye_shift", 0.0)


func get_builtin_screen() -> MeshInstance3D:
	return _proxy   # hidden — VideoHandler renders here, the screen quads sample it


## TWO video-out cables: TOP (plain) and BOTTOM (carries touch back to the
## core — tapping the TV showing the bottom screen is tapping the touch screen).
func get_video_channels() -> Array:
	return [
		{"label": "TOP", "rect": top_uv_rect, "touch": false, "eye_shift": top_eye_shift},
		{"label": "BOTTOM", "rect": bottom_uv_rect, "touch": true, "eye_shift": 0.0},
	]


## Clamshells keep the labelled START/STOP cabinet button (see configure_buttons).
func has_start_stop_button() -> bool:
	return true


## The composite picture texture currently on the proxy, or null when off.
func _proxy_texture() -> Texture2D:
	if _proxy == null:
		return null
	var mat := _proxy.get_surface_override_material(0)
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).emission_texture
	return null


func _process(_delta: float) -> void:
	# Feed both screen quads from whatever emission texture the VideoHandler
	# put on the proxy (copy-on-change identity checks, VB-eyepiece style).
	var tex := _proxy_texture()
	if tex != null:
		if _top_mat.get_shader_parameter("source_tex") != tex:
			_top_mat.set_shader_parameter("source_tex", tex)
			_bottom_mat.set_shader_parameter("source_tex", tex)
		if _screen.get_surface_override_material(0) != _top_mat:
			_screen.set_surface_override_material(0, _top_mat)
			_bottom_screen.set_surface_override_material(0, _bottom_mat)
	else:
		if _screen.get_surface_override_material(0) != _top_off_mat:
			_screen.set_surface_override_material(0, _top_off_mat)
			_bottom_screen.set_surface_override_material(0, _bottom_off_mat)

	_process_fingertip_touch()


## Shrink the cabinet power button to handheld scale and mount it on the front
## edge of the base, facing the player, with its START/STOP label under it.
## (RetroSystem keeps this button visible because has_start_stop_button().)
func configure_buttons(power_btn: VRButton, _reset_btn: VRButton, _eject_btn: VRButton) -> void:
	power_btn.position = Vector3(body_size.x * 0.36, 0, body_size.z / 2.0 + 0.002)
	power_btn.trigger_radius = 0.015
	power_btn.depress_depth = 0.002
	power_btn.depress_axis = Vector3(0, 0, -1)

	var col := power_btn.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = Vector3(0.016, 0.016, 0.008)

	var small := MeshInstance3D.new()
	small.name = "HandheldPowerMesh"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.005
	cyl.bottom_radius = 0.006
	cyl.height = 0.005
	small.mesh = cyl
	small.rotation_degrees = Vector3(90, 0, 0)   # cylinder axis out of the front face
	power_btn.add_child(small)
	# Re-caches the depress origin and hides the console-scale ButtonMesh.
	power_btn.set_button_mesh(small)

	var lbl := power_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.transform = Transform3D.IDENTITY
		lbl.position = Vector3(0, -0.0105, 0.002)
		lbl.pixel_size = 0.0004
		lbl.font_size = 12


## Two labelled video-out ports on the back edge, beside the cartridge slot:
## TOP on the right, BOTTOM on the left.
func configure_cable_attach_for(attach_point: Node3D, channel: int) -> void:
	var x := body_size.x * (0.30 if channel == 0 else -0.30)
	attach_point.position = Vector3(x, 0, -body_size.z / 2.0 - 0.002)
	# Channel 0 is the scene's CableAttachPoint, which carries the console's
	# grey barrel PortVisual — out of scale on a handheld (the extra channels'
	# points are bare Node3Ds), so hide it and let the labels mark the ports.
	var vis := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if vis:
		vis.visible = false
	_add_port_label("TOP" if channel == 0 else "BOTTOM", x)


func _add_port_label(text: String, x: float) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.pixel_size = 0.00018
	lbl.font_size = 16
	lbl.modulate = Color(0.92, 0.92, 0.94)
	lbl.outline_size = 4
	# On the back face, reading correctly from behind the device.
	lbl.rotation_degrees = Vector3(0, 180, 0)
	lbl.position = Vector3(x, body_size.y * 0.16, -body_size.z / 2.0 - 0.0015)
	add_child(lbl)


# ── Touch screen ──────────────────────────────────────────────────────────────

## Desktop reticle / VR laser events forwarded from the TouchScreen Area3D.
func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			_touch_pointer_down = true
			_send_touch(event.position, true)
		XRToolsPointerEvent.Type.MOVED:
			if _touch_pointer_down:
				_send_touch(event.position, true)
		XRToolsPointerEvent.Type.RELEASED, XRToolsPointerEvent.Type.EXITED:
			if _touch_pointer_down:
				_touch_pointer_down = false
				_send_touch(event.position, false)


## VR fingertip: a controller tip hovering just above the bottom screen is a
## stylus. Engage within the pad's bounds + a small height window; release
## when it leaves (with hysteresis, VRSlider-style). Hands HOLDING the device
## never count — a gripping hand's tip hovers near the pad permanently and
## would otherwise lock the touch (streaming a stuck press and blocking the
## free hand from poking).
func _process_fingertip_touch() -> void:
	if _touch == null or _touch_pointer_down:
		return
	if _touch_ctrl != null:
		if not is_instance_valid(_touch_ctrl) or not _touch_ctrl.get_is_active() \
				or _is_holding_hand(_touch_ctrl) \
				or not _tip_on_screen(PokeTip.tip_of(_touch_ctrl), 1.6):
			var last := _touch_ctrl
			_touch_ctrl = null
			if is_instance_valid(last):
				_send_touch(PokeTip.tip_of(last), false)
		else:
			_send_touch(PokeTip.tip_of(_touch_ctrl), true)
			return
	for ctrl in _touch_controllers:
		if ctrl and ctrl.get_is_active() and not _is_holding_hand(ctrl) \
				and _tip_on_screen(PokeTip.tip_of(ctrl), 1.0):
			_touch_ctrl = ctrl
			_send_touch(PokeTip.tip_of(ctrl), true)
			return


## True when this controller's hand is currently gripping the device.
func _is_holding_hand(ctrl: XRController3D) -> bool:
	if _host == null:
		return false
	var driver: Variant = _host.get("_grab_driver")
	if driver == null:
		return false
	if driver.primary and driver.primary.controller == ctrl:
		return true
	if driver.secondary and driver.secondary.controller == ctrl:
		return true
	return false


func _tip_on_screen(world_pos: Vector3, slack: float) -> bool:
	var local := _touch.to_local(world_pos)
	return absf(local.y) <= 0.01 * slack \
		and absf(local.x) <= bottom_screen_size.x / 2.0 + 0.005 * slack \
		and absf(local.z) <= bottom_screen_size.y / 2.0 + 0.005 * slack


## World point on/over the bottom screen → composite-framebuffer UV → host.
func _send_touch(world_pos: Vector3, pressed: bool) -> void:
	if _host == null or not _host.has_method("feed_touch"):
		return
	var local := _touch.to_local(world_pos)
	var fx := clampf(local.x / bottom_screen_size.x + 0.5, 0.0, 1.0)
	var fy := clampf(local.z / bottom_screen_size.y + 0.5, 0.0, 1.0)
	_host.feed_touch(bottom_uv_rect.position + Vector2(fx, fy) * bottom_uv_rect.size, pressed)


## Mean normal of a mesh IF every face agrees on one — i.e. the mesh is a single
## flat plane. Returns ZERO when the normals disagree, so callers can fall back
## rather than trusting the normal of something that is not a screen surface.
func _planar_normal(mi: MeshInstance3D) -> Vector3:
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return Vector3.ZERO
	var arr: Array = mi.mesh.surface_get_arrays(0)
	if arr.is_empty() or arr[Mesh.ARRAY_NORMAL] == null:
		return Vector3.ZERO
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	if norms.is_empty():
		return Vector3.ZERO
	var basis_n: Vector3 = mi.global_transform.basis * norms[0]
	basis_n = basis_n.normalized()
	var acc := Vector3.ZERO
	for n in norms:
		var w: Vector3 = (mi.global_transform.basis * n).normalized()
		# Two-sided quads list both facings; fold the back half onto the front.
		if w.dot(basis_n) < 0.0:
			w = -w
		if w.dot(basis_n) < 0.99:
			return Vector3.ZERO
		acc += w
	return acc.normalized()
