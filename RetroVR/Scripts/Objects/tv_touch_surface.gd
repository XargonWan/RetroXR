## TVTouchSurface — makes a TV screen behave like a DS/3DS touch screen.
##
## Created by RetroSystem when a dual-screen handheld's BOTTOM video-out cable
## connects to a TV, and freed on disconnect. Sits as an Area3D child of the
## TV's ScreenMesh (a +Z-facing QuadMesh), so it follows the TV wherever it
## goes and inherits its display scale.
##
## Taps arrive two ways — the desktop reticle / VR laser (pointer_event) and a
## direct VR fingertip press against the glass — and both map the hit through
## `uv_rect` (the channel's window of the composite framebuffer, i.e. what the
## TV is showing) into host.feed_touch() → RETRO_DEVICE_POINTER, exactly like
## poking the handheld's own bottom screen.
class_name TVTouchSurface
extends Area3D

## The RetroSystem receiving the touches.
var host: Node3D = null
## The channel's UV window of the composite framebuffer (what this TV shows).
var uv_rect := Rect2(0, 0, 1, 1)

var _size := Vector2(0.35, 0.25)
var _pointer_down := false
var _touch_ctrl: XRController3D = null
var _controllers: Array[XRController3D] = []


## Build collision to match the screen quad it is attached to.
func setup(system: Node3D, rect: Rect2, screen_mesh: MeshInstance3D) -> void:
	host = system
	uv_rect = rect
	if screen_mesh and screen_mesh.mesh is QuadMesh:
		_size = (screen_mesh.mesh as QuadMesh).size
	name = "TVTouchSurface"
	collision_layer |= VRSlider.POINTABLE_LAYER
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(_size.x, _size.y, 0.008)
	col.shape = shape
	add_child(col)


func _ready() -> void:
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## Desktop reticle / VR laser taps on the glass.
func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_down = true
			_send_touch(event.position, true)
		XRToolsPointerEvent.Type.MOVED:
			if _pointer_down:
				_send_touch(event.position, true)
		XRToolsPointerEvent.Type.RELEASED, XRToolsPointerEvent.Type.EXITED:
			if _pointer_down:
				_pointer_down = false
				_send_touch(event.position, false)


## VR fingertip pressed against the glass (hysteresis like the handheld pad).
func _process(_delta: float) -> void:
	if _pointer_down:
		return
	if _touch_ctrl != null:
		if not is_instance_valid(_touch_ctrl) or not _touch_ctrl.get_is_active() \
				or not _tip_on_screen(PokeTip.tip_of(_touch_ctrl), 1.6):
			var last := _touch_ctrl
			_touch_ctrl = null
			if is_instance_valid(last):
				_send_touch(PokeTip.tip_of(last), false)
		else:
			_send_touch(PokeTip.tip_of(_touch_ctrl), true)
			return
	for ctrl in _controllers:
		if ctrl and ctrl.get_is_active() and _tip_on_screen(PokeTip.tip_of(ctrl), 1.0):
			_touch_ctrl = ctrl
			_send_touch(PokeTip.tip_of(ctrl), true)
			return


func _tip_on_screen(world_pos: Vector3, slack: float) -> bool:
	var local := to_local(world_pos)
	return absf(local.z) <= 0.03 * slack \
		and absf(local.x) <= _size.x / 2.0 + 0.005 * slack \
		and absf(local.y) <= _size.y / 2.0 + 0.005 * slack


## World point on the glass → screen fraction → composite-framebuffer UV.
## The quad faces +Z: local x right, y up; UV y runs top-down.
func _send_touch(world_pos: Vector3, pressed: bool) -> void:
	if host == null or not host.has_method("feed_touch"):
		return
	var local := to_local(world_pos)
	var fx := clampf(local.x / _size.x + 0.5, 0.0, 1.0)
	var fy := clampf(0.5 - local.y / _size.y, 0.0, 1.0)
	host.feed_touch(uv_rect.position + Vector2(fx, fy) * uv_rect.size, pressed)
