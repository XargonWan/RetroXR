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

# Per-device LCD display filter (e.g. the DMG dot-matrix look). A subclass may
# replace _lcd_shader; the base wraps the built-in screen's material with it — the
# same watch-and-rewrap the TV uses for its CRT, since the C++ video handler
# re-asserts its own StandardMaterial3D (emission = picture) each frame.
#
# The DEFAULT is screen_pixel_aa: no device look, purely to get the core frame
# sampled properly. A handheld's screen sits near 1:1 with the headset's pixels
# (a 54 mm GBA panel at arm's length is ~0.94x — see Scripts/XR/xr_init.gd), and at
# non-integer ratios neither hardware filter works: linear is uniformly soft, and
# nearest drops source rows and crawls as the head moves. pixel_aa.gdshaderinc
# explains the fix; gameboy_lcd samples the same way, so a device look does not
# cost sharpness.
const PIXEL_AA_SHADER: Shader = preload("res://Shaders/screen_pixel_aa.gdshader")

var _lcd_shader: Shader = PIXEL_AA_SHADER
var _lcd_material: ShaderMaterial = null

## When a subclass returns a GLB path from _glb_path(), the handheld swaps its
## primitive stand-in shell for that detailed imported model (dev-only — the GLB lives
## in export-excluded imported-assets/). Store builds (GLB absent) keep the authored
## primitive shell, so on-device controls + screen still work everywhere.
var _glb: Node3D = null

## Screen-cast light: the built-in LCD tints a SpotLight3D aimed OUT of the glass,
## so a powered handheld throws a glow on whatever it's pointed at — the
## personal-scale sibling of the TV's ambilight, and the same recipe (see tv.tscn's
## Ambilight: a spot sitting just off the screen, energy 0.6, 50° cone, tinted to
## the average frame colour). This started as an OmniLight, which sat INSIDE the
## shell and lit the whole device from within instead of casting anywhere.
## Off when the screen shows no picture; colour is the throttled frame average.
const SCREEN_LIGHT_ENERGY := 0.6
## Cone width, matching the TV ambilight's.
const SCREEN_LIGHT_ANGLE := 50.0
## Reach, as a multiple of the screen's long edge, clamped. A 47 mm Game Boy LCD
## has no business throwing the TV's 2.5 m cone, and a 25 mm Pokémon-mini screen
## still wants to glow a little way out.
const SCREEN_LIGHT_RANGE_FACTOR := 12.0
const SCREEN_LIGHT_RANGE_MIN := 0.35
const SCREEN_LIGHT_RANGE_MAX := 0.9
## Clearance from the glass — the cone must start outside it (see the TV's
## ambilight, which sits just proud of its screen).
const SCREEN_LIGHT_OFFSET := 0.006
var _screen_light: SpotLight3D = null


func is_handheld() -> bool:
	return true


## Override to return a detailed shell GLB (else "" = keep the primitive shell).
func _glb_path() -> String:
	return ""


## Name of the GLB's screen-lens mesh. Most imported handhelds call it "screen_mesh";
## some (the PSP-1000) suffix it "screen_mesh_0". Override to match.
func _glb_screen_name() -> String:
	return "screen_mesh"


## Called once the shell is in place — EITHER shell. Subclasses cache their
## control meshes here for animate_controls() and mount their sliders/buttons on
## them. A stand-in scene authors its controls under the same names the detailed
## shell uses, so the same pass wires both and neither needs a special case.
func _on_shell_ready() -> void:
	pass

## imported handheld GLBs are modelled upright (screen on +Z); RetroVR's frame is
## lying flat with the screen on +Y, so the default lays it back. Override if a
## particular GLB is authored differently.
func _glb_rotation_degrees() -> Vector3:
	return Vector3(-90, 0, 0)


func _ready() -> void:
	_cache_shell_nodes()
	# A stand-in scene IS its shell — plain geometry authored alongside these
	# functional nodes — so there is nothing to upgrade to and nothing to probe
	# for. The licensed scenes take the other branch, unconditionally.
	if primitive_shell:
		_on_shell_ready()          # the stand-in's own controls, already in place
	else:
		_upgrade_to_glb(_glb_path())
	# An authored "CartSeat" marker (see configure_cartridge_slot) may carry a
	# visible "SeatPreview" box so the seated-cart pose can be dialled in inside
	# the Godot 3D editor. It's an editor aid only — hide it at runtime.
	_hide_seat_previews()
	_setup_screen_light()


func _setup_screen_light() -> void:
	_screen_light = _make_screen_light(_screen)


## Create + configure a screen-cast spot just off `screen`'s glass, aimed out along
## the screen's own normal. Parented to the screen so it tracks a GLB-repositioned
## (or lid-mounted) screen automatically. Reusable for devices with more than one
## screen (see RetroSystemModelDualScreen).
func _make_screen_light(screen: MeshInstance3D) -> SpotLight3D:
	if screen == null:
		return null
	var light := SpotLight3D.new()
	light.name = "ScreenCastLight"
	# A QuadMesh screen faces its local +Z, but a SpotLight3D emits along its local
	# -Z — so flip it, or the cone points back through the device.
	light.rotation_degrees = Vector3(180.0, 0.0, 0.0)
	light.spot_angle = SCREEN_LIGHT_ANGLE
	light.spot_range = _screen_light_range(screen)
	light.shadow_enabled = false
	light.light_energy = 0.0
	light.position = Vector3(0.0, 0.0, SCREEN_LIGHT_OFFSET)
	screen.add_child(light)
	return light


## Reach for one screen's cast light, proportional to that screen's long edge.
func _screen_light_range(screen: MeshInstance3D) -> float:
	var s := screen_size
	if screen.mesh is QuadMesh:
		s = (screen.mesh as QuadMesh).size
	return clampf(maxf(s.x, s.y) * SCREEN_LIGHT_RANGE_FACTOR,
		SCREEN_LIGHT_RANGE_MIN, SCREEN_LIGHT_RANGE_MAX)


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
		# body_size used to come from the primitive HandheldBody; on baked scenes
		# that box is split out to a *_primitive.tscn, so measure the real shell
		# instead (collision / cart slot / cable placement track it).
		var bb := _glb_local_aabb(_glb)
		if bb.size.length() > 0.0:
			body_size = bb.size
		_fix_shell_materials()
		_on_shell_ready()
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
	# Move the power switch's interaction zone onto the GLB's real switch FIRST —
	# _adopt_knob derives the travel axis from the slider's global transform, so
	# it has to run after the move.
	var pm := _glb.find_child("Power", true, false) as Node3D
	if _power_switch != null and pm != null:
		_power_switch.position = to_local(pm.global_position)
	_adopt_knob(_volume_slider, "Volume")
	_adopt_knob(_power_switch, "Power")
	_on_shell_ready()


## Point a slider at the GLB's real switch cap so its interaction box and green
## highlight trace the geometry you can actually see. Without this a handheld
## whose GLB has loaded would size both to the hidden primitive knob.
##
## Only a node that IS a MeshInstance3D is adopted — the slider moves whatever it
## is handed, and grabbing a parent group would drag half the shell along with it.
## Otherwise fall back to the old behaviour of just hiding the primitive.
func _adopt_knob(slider: VRSlider, glb_node_name: String) -> void:
	if slider == null:
		return
	var cap: MeshInstance3D = null
	if _glb != null:
		cap = _glb.find_child(glb_node_name, true, false) as MeshInstance3D
	if cap != null:
		slider.set_knob_mesh(cap)   # hides the placeholder itself
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
			# "kabel" catches a few imported shells (e.g. the PSP-1000's an author
			# model) authored with German node names ("AVKabel", "PowerKabel1/2").
			if nm.contains("rca") or nm.contains("cable") or nm.contains("kabel") or nm.contains("plug"):
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
	_update_screen_light()
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


func _update_screen_light() -> void:
	_drive_screen_light(_screen, _screen_light)


## Drive one screen-cast light from its screen's live picture: on when the screen
## shows a frame, tinted to the throttled average frame colour. get_image() is a
## GPU→CPU readback, so it's rate-limited by QualityManager like the TV ambilight.
## The per-light throttle counter rides on the light (meta) so several screens can
## share this without a member counter each.
func _drive_screen_light(screen: MeshInstance3D, light: SpotLight3D) -> void:
	if light == null or screen == null:
		return
	var tex := _screen_emission_texture(screen.get_surface_override_material(0))
	if tex == null:
		light.light_energy = 0.0
		return
	light.light_energy = SCREEN_LIGHT_ENERGY
	var f: int = int(light.get_meta("sl_frame", 0)) + 1
	var interval: int = QualityManager.ambilight_interval if QualityManager else 10
	if f < interval:
		light.set_meta("sl_frame", f)
		return
	light.set_meta("sl_frame", 0)
	var img := tex.get_image()
	if img == null:
		return
	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var avg := img.get_pixel(0, 0)
	light.light_color = Color(avg.r, avg.g, avg.b)


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
	var seat := _seat_marker("CartSeat")
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


## How far down the body the hands grip, as a fraction of its length from centre.
const GRIP_Z_FRACTION := 0.25


## Where a hand grips the device, in the system's local frame — the side edges,
## at mid-thickness, down toward the near edge where the hands actually sit (the
## far edge is the cartridge slot). RetroSystem hands this to GripAnchor so a
## held handheld sits in one hand or between two, rather than keeping whatever
## offset it was touched at.
func get_grip_anchor(is_left: bool) -> Transform3D:
	var x := body_size.x * 0.5
	return Transform3D(Basis(), Vector3(
		-x if is_left else x,
		0.0,
		body_size.z * GRIP_Z_FRACTION))


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
	if _power_switch is VRSpringReturnSlider:
		# A MOMENTARY switch reports an intent, not a position: it springs back on
		# release, so its value crosses the midpoint twice per push and means
		# nothing either time. Wire the completed hold instead.
		var momentary := _power_switch as VRSpringReturnSlider
		momentary.system_on = bool(_host.get("is_powered_on"))
		momentary.toggle_requested.connect(func() -> void:
			if _host != null and _host.has_method("toggle_power"):
				_host.toggle_power())
	elif _power_switch:
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
	if _power_switch is VRSpringReturnSlider:
		# Nothing to park — the cap lives at rest and springs back after each
		# push. It only needs to know which dwell applies from here on.
		(_power_switch as VRSpringReturnSlider).system_on = true
	elif _power_switch:
		_power_switch.set_value_no_signal(1.0)
	if _volume_slider and _host and _host.has_method("set_audio_volume"):
		_host.set_audio_volume(_volume_slider.value)


func on_power_off() -> void:
	if _power_switch is VRSpringReturnSlider:
		(_power_switch as VRSpringReturnSlider).system_on = false
	elif _power_switch:
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
