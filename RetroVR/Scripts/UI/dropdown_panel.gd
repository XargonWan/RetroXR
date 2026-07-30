## DropdownPanel — a VRDropdown's option list as its own quad, floating a few
## centimetres in front of the panel that opened it.
##
## A 2D list inside a Viewport2Din3D has nowhere to go: expanding it grows its
## row, and overlaying it fights the sibling draw order. Its own quad has
## neither problem, and it matches the cartridge/core/tv options panels.
##
## Parented to the host Viewport2Din3D, so all placement is in that panel's
## local space and the popout follows the menu when it is grabbed or moved.
class_name DropdownPanel
extends Node3D

signal option_chosen(id: Variant)
signal dismissed

const VIEWPORT_2D_IN_3D := preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
const OPTIONS_2D := preload("res://Scenes/UI/dropdown_options_2d.tscn")

## Metres in front of the host panel. Far enough to clear it without landing in
## a different focal plane from the menu behind it.
const Z_OFFSET := 0.035
const MAX_PANEL_PX_H := 620.0
const MIN_PANEL_PX_W := 320.0

var _viewport: XRToolsViewport2DIn3D = null
var _ui: DropdownOptions2D = null
var _host: XRToolsViewport2DIn3D = null
## Metres per host viewport pixel, so the popout matches the menu's scale.
var _m_per_px := 0.0005


func _ready() -> void:
	visible = false


## host        : the Viewport2Din3D the dropdown lives in
## toggle_rect : the toggle's rect in host viewport pixels
## options     : [[label, id, (Texture2D)], ...]
func show_for(host: XRToolsViewport2DIn3D, toggle_rect: Rect2, options: Array,
			  current_id: Variant, font: Font = null, columns: int = 1) -> void:
	_host = host
	if host.screen_size.x > 0.0 and host.viewport_size.x > 0.0:
		_m_per_px = host.screen_size.x / host.viewport_size.x

	var ui := _ensure_ui()
	if ui == null:
		return
	var want := DropdownOptions2D.wanted_size(options.size(), columns)
	var px_w := maxf(maxf(toggle_rect.size.x, MIN_PANEL_PX_W), want.x)
	var px_h := minf(want.y, MAX_PANEL_PX_H)

	_viewport.viewport_size = Vector2(px_w, px_h)
	_viewport.screen_size = Vector2(px_w * _m_per_px, px_h * _m_per_px)

	ui.set_options(options, current_id, font, 22, columns)

	# On a curved host the screen bows toward the viewer — up to ~11 cm at the
	# edges, far more than Z_OFFSET — so a flat offset leaves the card buried in
	# the menu it is meant to float over. Ride the arc instead, and face along it.
	var flat := _local_for(host, toggle_rect, px_w, px_h)
	var curved := host.get_node_or_null("CurvedPanel")
	if curved != null and curved.has_method("surface_pose"):
		transform = curved.surface_pose(flat.x, flat.y, Z_OFFSET)
	else:
		position = flat
	visible = true


func hide_panel() -> void:
	visible = false


## Place the popout just under the toggle, clamped so it cannot hang off the
## host panel, and flipped above the toggle when there is no room below.
func _local_for(host: XRToolsViewport2DIn3D, toggle_rect: Rect2,
				px_w: float, px_h: float) -> Vector3:
	var vp := host.viewport_size
	var gap := 6.0

	var x_px := toggle_rect.position.x + toggle_rect.size.x * 0.5
	var top_px := toggle_rect.position.y + toggle_rect.size.y + gap
	if top_px + px_h > vp.y:
		top_px = toggle_rect.position.y - gap - px_h
	top_px = clampf(top_px, 0.0, maxf(0.0, vp.y - px_h))
	x_px = clampf(x_px, px_w * 0.5, maxf(px_w * 0.5, vp.x - px_w * 0.5))

	var y_px := top_px + px_h * 0.5
	# Viewport pixels are +Y down from the top-left; the quad is centred, +Y up.
	return Vector3(
		(x_px / vp.x - 0.5) * host.screen_size.x,
		-(y_px / vp.y - 0.5) * host.screen_size.y,
		Z_OFFSET)


func _ensure_ui() -> DropdownOptions2D:
	if _ui != null and is_instance_valid(_ui):
		return _ui

	if _viewport == null:
		# Must be instanced from the addon scene: the SubViewport, mesh and
		# collision body are scene children, so .new() yields a bare Node3D.
		_viewport = VIEWPORT_2D_IN_3D.instantiate() as XRToolsViewport2DIn3D
		_viewport.name = "DropdownViewport"
		_viewport.update_mode = XRToolsViewport2DIn3D.UpdateMode.UPDATE_ALWAYS
		# Opaque and unshaded: the card fills its own quad, so alpha blending
		# only lets the list behind bleed through, and scene lighting would make
		# it read dimmer than the panel it sits on.
		_viewport.transparent = XRToolsViewport2DIn3D.TransparancyMode.OPAQUE
		_viewport.unshaded = true
		if _host != null:
			_viewport.collision_layer = _host.collision_layer
		add_child(_viewport)

	# Must go through the `scene` property: that is what instantiates the UI
	# into the SubViewport and binds its texture to the quad's material.
	# Adding a Control to the SubViewport directly renders nothing.
	_viewport.scene = OPTIONS_2D
	_ui = _viewport.get_scene_instance() as DropdownOptions2D
	if _ui == null:
		return null
	_ui.option_chosen.connect(func(id: Variant) -> void:
		hide_panel()
		option_chosen.emit(id)
	)
	return _ui
