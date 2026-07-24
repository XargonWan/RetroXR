## RetroSystemModelHandheld — shared base for handheld consoles (Game Boy family).
##
## A handheld is a RetroSystem whose model provides a BUILT-IN screen: the core
## renders to the on-device LCD when no TV is connected, and the video-out
## cable moves the picture to a TV (Super Game Boy style).
##
## The visible shell — body, screen, bezel, cosmetic d-pad/buttons, cartridge
## slot mouth, and the on-device volume slider + power switch — is authored in
## the per-device scene under Scenes/Objects/system_models/ (e.g. game_boy.tscn).
## This script no longer BUILDS geometry: it caches the authored nodes, reads the
## body/screen dimensions back from them, wires the control signals to the owning
## RetroSystem, keeps the live LCD picture filtered, and repositions the shared
## cabinet nodes (collision, cartridge slot, cable port) to fit the device.
##
## Subclasses set only NON-geometry data in _init (cartridge dimensions, the DMG
## LCD shader) — the shape and layout live in the scene.
class_name RetroSystemModelHandheld
extends RetroSystemModel

# Device local frame: lying flat, screen on the +Y (top) face, top edge of the
# screen toward -Z, cartridge slot on the back edge (-Z), video-out on the left.

## Body size in metres (x = width, y = thickness, z = length). Read back from the
## authored HandheldBody mesh at _ready; the scene is the source of truth.
var body_size := Vector3(0.09, 0.032, 0.148)
## Screen quad size (x = width, z = height on the device face). Read back from the
## authored HandheldScreen mesh at _ready.
var screen_size := Vector2(0.047, 0.043)
## Cartridge size (width, length-into-slot, thickness) — should match the
## system's MediaDimensions.CART_SIZES entry. Drives the slot-mouth visual
## and how deep the cart seats. Default = Game Boy cart. Set per-device in _init.
var cart_size := Vector3(0.057, 0.065, 0.008)

var _screen: MeshInstance3D = null
var _power_switch: VRSlider = null
var _volume_slider: VRSlider = null
var _host: Node3D = null

# Optional per-device LCD display filter (e.g. the DMG dot-matrix look). A
# subclass sets _lcd_shader; the base then wraps the built-in screen's material
# with it — the same watch-and-rewrap the TV uses for its CRT, since the C++
# video handler re-asserts its own StandardMaterial3D (emission = picture) each
# frame. Left null → no filter (GBA colour LCD, etc.).
var _lcd_shader: Shader = null
var _lcd_material: ShaderMaterial = null

## When a subclass returns a GLB path from _glb_path(), the handheld swaps its
## primitive stand-in shell for that detailed imported model (dev-only — the GLB lives
## in export-excluded imported-assets/). Store builds (GLB absent) keep the authored
## primitive shell, so on-device controls + screen still work everywhere.
var _glb: Node3D = null


func is_handheld() -> bool:
	return true


## Override to return a detailed shell GLB (else "" = keep the primitive shell).
func _glb_path() -> String:
	return ""


## Name of the GLB's screen-lens mesh. Most imported handhelds call it "screen_mesh";
## some (the PSP-1000) suffix it "screen_mesh_0". Override to match.
func _glb_screen_name() -> String:
	return "screen_mesh"


## Called at the end of _upgrade_to_glb once the shell is in place, laid back and
## recentred. Subclasses cache their control meshes here for animate_controls().
func _on_glb_ready() -> void:
	pass

## imported handheld GLBs are modelled upright (screen on +Z); RetroVR's frame is
## lying flat with the screen on +Y, so the default lays it back. Override if a
## particular GLB is authored differently.
func _glb_rotation_degrees() -> Vector3:
	return Vector3(-90, 0, 0)


func _ready() -> void:
	_cache_shell_nodes()
	var gp := _glb_path()
	if not gp.is_empty() and ResourceLoader.exists(gp):
		_upgrade_to_glb(gp)
	# An authored "CartSeat" marker (see configure_cartridge_slot) may carry a
	# visible "SeatPreview" box so the seated-cart pose can be dialled in inside
	# the Godot 3D editor. It's an editor aid only — hide it at runtime.
	var preview := find_child("SeatPreview", true, false)
	if preview is Node3D:
		(preview as Node3D).visible = false


## Cache the authored shell nodes and read the device dimensions back from their
## meshes, so runtime placement (collision/slot/cable) tracks the scene geometry.
func _cache_shell_nodes() -> void:
	_screen = get_node_or_null("HandheldScreen") as MeshInstance3D
	_volume_slider = get_node_or_null("VolumeSlider") as VRSlider
	_power_switch = get_node_or_null("PowerSwitch") as VRSlider
	# find_child, not get_node: the stand-in shell is a "Primitive" subtree now.
	var body := find_child("HandheldBody", true, false) as MeshInstance3D
	if body and body.mesh is BoxMesh:
		body_size = (body.mesh as BoxMesh).size
	if _screen and _screen.mesh is QuadMesh:
		screen_size = (_screen.mesh as QuadMesh).size


## Swap the primitive stand-in shell for the detailed GLB: lay it flat, recentre,
## hide the GLB's bundled AV lead, adopt its flat screen quad as the live-picture
## surface, hide the primitive shell meshes + control knobs (the GLB shows the real
## ones), and move the power switch onto the GLB's switch marker. body_size is
## re-read from the GLB so collision / cart slot / cable placement track it.
func _upgrade_to_glb(path: String) -> void:
	# Already baked into the scene (authored "Shell" GLB instance + repositioned
	# screen/controls)? Then the .tscn is self-contained — just keep the reference.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
		_fix_shell_materials()
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	_glb = scene.instantiate() as Node3D
	_glb.name = "Shell"
	var ap := _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		ap.autoplay = ""
	_glb.rotation_degrees = _glb_rotation_degrees()
	add_child(_glb)
	_hide_glb_clutter(_glb)
	# Centre the GLB on the model origin (handheld frame is centred; y=0 = mid-thickness).
	var b := _glb_local_aabb(_glb)
	_glb.position -= b.position + b.size * 0.5
	b = _glb_local_aabb(_glb)
	body_size = b.size
	# The live picture keeps rendering on the KNOWN-GOOD primitive screen quad (proven
	# UVs, the C++ video handler already targets it) — repositioned + resized onto the
	# GLB's screen, raised a hair so it sits IN FRONT of the plastic lens. The GLB's
	# own screen_mesh sits behind that opaque lens, so it's hidden.
	_fix_shell_materials()
	var glb_screen := _glb.find_child(_glb_screen_name(), true, false) as MeshInstance3D
	if glb_screen != null and _screen != null:
		var sab: AABB = glb_screen.global_transform * glb_screen.get_aabb()
		var sctr := sab.position + sab.size * 0.5
		_screen.global_position = sctr + Vector3(0.0, 0.0016, 0.0)
		if _screen.mesh is QuadMesh:
			var q := (_screen.mesh as QuadMesh).duplicate() as QuadMesh
			# Small inset so the picture sits inside the bezel lip, not over it.
			q.size = Vector2(sab.size.x, sab.size.z) * 0.92
			_screen.mesh = q
			screen_size = q.size
		glb_screen.visible = false
	# Hide the primitive stand-in shell meshes (keep the repositioned screen) + slider
	# knobs — the GLB carries the real body, buttons and switch caps.
	for child in get_children():
		if child is MeshInstance3D and child != _screen:
			(child as MeshInstance3D).visible = false
	_hide_knob(_volume_slider)
	_hide_knob(_power_switch)
	# Move the power switch's interaction zone onto the GLB's real switch.
	var pm := _glb.find_child("Power", true, false) as Node3D
	if _power_switch != null and pm != null:
		_power_switch.position = to_local(pm.global_position)
	_on_glb_ready()


func _hide_knob(slider: VRSlider) -> void:
	if slider == null:
		return
	var k := slider.get_node_or_null("KnobMesh") as MeshInstance3D
	if k != null:
		k.visible = false


## Hide the GLB's bundled AV lead / plug (RetroVR spawns its own video-out cable).
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


## Combined AABB of the GLB's visible meshes, in this model node's local space.
func _glb_local_aabb(inst: Node3D) -> AABB:
	var acc := AABB(); var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	return acc


## Keep the LCD filter wrapped over the live core picture. Cheap identity checks
## in the steady state; only re-installs when the source material changes.
func _process(_delta: float) -> void:
	if _lcd_shader == null or _screen == null:
		return
	var override := _screen.get_surface_override_material(0)
	if override == null or override == _lcd_material:
		return
	var tex := _screen_emission_texture(override)
	if tex == null:
		return   # off / no picture — leave the unlit LCD material alone
	if _lcd_material == null:
		_lcd_material = ShaderMaterial.new()
		_lcd_material.shader = _lcd_shader
	_lcd_material.set_shader_parameter("source_tex", tex)
	_screen.set_surface_override_material(0, _lcd_material)


## The live picture texture out of whichever material the core installed (it uses
## an emissive StandardMaterial3D; our own wrapper carries source_tex).
func _screen_emission_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).emission_texture
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	return null


func get_controller_port_count() -> int:
	return 0


func get_builtin_screen() -> MeshInstance3D:
	return _screen


## How much of the seated cartridge pokes out of the back for grabbing.
func _cart_protrude() -> float:
	return clampf(cart_size.y * 0.28, 0.008, 0.02)


## Seated cart: only the protruding stub is grabbable — the cart's padded
## grab box otherwise pokes through the thin shell and steals desktop clicks
## / VR grabs aimed at the device.
func play_cartridge_insert(cartridge: Node3D, _slot: Node3D) -> void:
	if cartridge.has_method("set_seated_grab_stub"):
		cartridge.set_seated_grab_stub(_cart_protrude() + 0.004)


func play_cartridge_eject(cartridge: Node3D, _slot: Node3D) -> void:
	if cartridge.has_method("reset_grab_shapes"):
		cartridge.reset_grab_shapes()


## Seat the cartridge INSIDE the body, through the slot mouth on the back
## face: lying flat (label up), most of its length inside, _cart_protrude()
## sticking out for grabbing.
func configure_cartridge_slot(slot: Node3D) -> void:
	# Cartridge local frame: x = width, y = length (insert axis), z = thickness
	# with the label on +Z. This pose lays it flat with the length running into
	# the body (-Z) and the LABEL FACING DOWN toward the device's back shell —
	# like real handheld carts (the label is hidden while inserted).
	slot.rotation_degrees = Vector3(90, 180, 0)
	slot.position = Vector3(0, 0,
		-body_size.z / 2.0 + cart_size.y / 2.0 - _cart_protrude())
	# The console-scale 7 cm grab sphere (also the desktop click target for the
	# seated cart) envelopes most of a handheld — clicking anywhere near the
	# device grabbed the cart. Shrink it to just around the slot/stub.
	slot.grab_distance = 0.03
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false
	# The snap ghost is a generic console-cartridge box — reshape it to this
	# system's cart so the blue "goes here" shadow matches what fits.
	var ghost := slot.get_node_or_null("SnapHighlight/HighlightMesh") as MeshInstance3D
	if ghost:
		var ghost_mesh := BoxMesh.new()
		ghost_mesh.size = cart_size
		ghost.mesh = ghost_mesh
	# An authored "CartSeat" marker in the device .tscn wins over the computed pose
	# above, so the exact seated-cart transform can be placed visually in the Godot
	# 3D editor (drag/rotate CartSeat; its SeatPreview box shows the cart footprint).
	# Devices without the marker keep the generic pose — nothing else changes.
	var seat := find_child("CartSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform


## Cartridges slide in from behind the device.
func get_cartridge_insert_direction() -> Vector3:
	return Vector3(0, 0, -1)


## Video-out port on the rear edge (the Super Game Boy fantasy), clear of the
## centred cartridge slot mouth. On narrow bodies whose back edge is mostly
## slot (Game Boy, WonderSwan, Supervision, Pokémon Mini) the port moves to
## the right side edge instead.
func configure_cable_attach(attach_point: Node3D) -> void:
	var back_x := maxf(body_size.x * 0.30, (cart_size.x + 0.005) / 2.0 + 0.010)
	if back_x <= body_size.x / 2.0 - 0.008:
		attach_point.position = Vector3(back_x, 0, -body_size.z / 2.0 - 0.002)
	else:
		attach_point.position = Vector3(body_size.x / 2.0 + 0.002, 0, -body_size.z * 0.30)
	# The scene's console-scale grey port barrel dwarfs a handheld shell —
	# hide it (the cable itself marks the port).
	var vis := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if vis:
		vis.visible = false


## Shrink the root collision box to the device and hide the console body.
## Called by RetroSystem after the model loads.
func configure_handheld_body(host: Node3D) -> void:
	var col := host.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		# The .tscn sub-resource is shared across instances — duplicate first.
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = body_size + Vector3(0.01, 0.01, 0.01)
		col.position = Vector3.ZERO
	var body := host.get_node_or_null("SystemBody") as MeshInstance3D
	if body:
		body.visible = false
	# The selection PointerArea keeps its console-sized box otherwise — a huge
	# invisible pointable slab that the desktop reticle / VR laser hits FIRST,
	# shadowing every on-device control (power switch, volume slider, START
	# button, touch screen). Shrink it to the body so controls, which all poke
	# out of the shell, win the raycast.
	var pcol := host.get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol and pcol.shape is BoxShape3D:
		pcol.shape = pcol.shape.duplicate()
		(pcol.shape as BoxShape3D).size = body_size
		pcol.position = Vector3.ZERO


## On-device controls: wire the authored volume slider + power switch to the
## owning RetroSystem. The knobs/travel/positions are authored in the scene;
## this only connects their signals.
func configure_handheld_controls(host: Node3D) -> void:
	_host = host
	if _volume_slider:
		_volume_slider.value_changed.connect(func(v: float) -> void:
			if _host and _host.has_method("set_audio_volume"):
				_host.set_audio_volume(v))
	if _power_switch:
		_power_switch.value_changed.connect(func(v: float) -> void:
			if _host == null or not _host.has_method("toggle_power"):
				return
			var want_on := v > 0.5
			if want_on != bool(_host.get("is_powered_on")):
				_host.toggle_power())


## Reflect externally-driven power changes (e.g. cart removal powers off, or a
## multiplayer event) back onto the switch position, and apply the volume
## slider's current position to the freshly-created audio player.
func on_power_on() -> void:
	if _power_switch:
		_power_switch.set_value_no_signal(1.0)
	if _volume_slider and _host and _host.has_method("set_audio_volume"):
		_host.set_audio_volume(_volume_slider.value)


func on_power_off() -> void:
	if _power_switch:
		_power_switch.set_value_no_signal(0.0)
	# Unlit LCD look returns automatically when the core releases the material.


## Some converted shells ship emissiveFactor 1,1,1 with no emissive texture,
## which Godot takes literally — the Arctic White GBA glowed like a lightbulb.
## The live picture is drawn on our own quad, so nothing on the shell itself
## should be self-illuminated. Runs on the baked path too: several handhelds
## have their GLB saved into the .tscn and return before the load below.
func _fix_shell_materials() -> void:
	if _glb != null:
		ModelMaterialFix.strip_emission(_glb)
