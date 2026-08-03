## QrScanOverlay — full-panel viewfinder for scanning a QR code.
##
## Knows nothing about what the code means: it shows the passthrough camera,
## emits `scanned` once per code, and offers a yes/no row the caller can drive.
## Parsing and acting on the payload belong to the caller.
##
## The player is standing in a virtual room, so the preview is the only way to
## see the screen being aimed at — a reticle alone would be aiming blind.
class_name QrScanOverlay
extends PanelContainer

## A code was decoded. Further codes are suppressed until resume() or close().
signal scanned(payload: String)
signal cancelled

## Nothing found in this long: the camera is closed rather than left burning.
const IDLE_TIMEOUT_SEC := 60.0
const PREVIEW_SIZE := Vector2(560, 420)

var _watch: Control = null
var _scanner: QrScanner = null
var _image: Image = null
var _texture: ImageTexture = null
var _preview: TextureRect = null
var _status: Label = null
var _confirm_row: HBoxContainer = null
var _confirm_label: Label = null
var _on_confirm: Callable = Callable()
var _idle: Timer = null
var _closed: bool = false
var _busy: bool = false
var _last_activate_frame: int = -1


## `watch` is the view this overlay belongs to. The overlay is parented to that
## view's container so it draws over the whole panel, which means a nav-tab
## switch would otherwise leave it on screen: SpawnMenu2D._show_view only
## toggles the eight views it knows about.
static func create(watch: Control) -> QrScanOverlay:
	var o := QrScanOverlay.new()
	o._watch = watch
	o._build()
	return o


func _build() -> void:
	add_theme_stylebox_override("panel", MenuStyle.rounded(Color(0.06, 0.06, 0.13, 0.99), 8))
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 14)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	vbox.add_child(head)

	var title := Label.new()
	title.text = "Scan RomM pairing code"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(140, 48)
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.pressed.connect(_on_cancel_pressed)
	head.add_child(cancel)

	var centre := CenterContainer.new()
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(centre)

	# The frame doubles as the reticle: get the code inside the box.
	var frame := PanelContainer.new()
	var border := MenuStyle.rounded(Color(0, 0, 0, 0), 6)
	border.border_color = Color(0.45, 0.70, 1.00, 0.85)
	for side in ["border_width_top", "border_width_bottom",
				 "border_width_left", "border_width_right"]:
		border.set(side, 3)
	frame.add_theme_stylebox_override("panel", border)
	centre.add_child(frame)

	_image = Image.create_empty(QrScanner.PREVIEW_WIDTH, QrScanner.PREVIEW_HEIGHT,
		false, Image.FORMAT_L8)
	_texture = ImageTexture.create_from_image(_image)

	_preview = TextureRect.new()
	_preview.texture = _texture
	_preview.custom_minimum_size = PREVIEW_SIZE
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	frame.add_child(_preview)

	_status = Label.new()
	_status.text = "Point the headset at the QR code on your screen."
	_status.add_theme_font_size_override("font_size", 18)
	_status.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status)

	_confirm_row = HBoxContainer.new()
	_confirm_row.add_theme_constant_override("separation", 10)
	_confirm_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_confirm_row.visible = false
	vbox.add_child(_confirm_row)

	_confirm_label = Label.new()
	_confirm_label.add_theme_font_size_override("font_size", 18)
	_confirm_label.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	_confirm_row.add_child(_confirm_label)

	var yes := Button.new()
	yes.text = "Switch"
	yes.custom_minimum_size = Vector2(140, 48)
	yes.focus_mode = Control.FOCUS_NONE
	yes.pressed.connect(_on_confirm_pressed)
	_confirm_row.add_child(yes)

	var no := Button.new()
	no.text = "Keep current"
	no.custom_minimum_size = Vector2(180, 48)
	no.focus_mode = Control.FOCUS_NONE
	no.pressed.connect(_on_decline_pressed)
	_confirm_row.add_child(no)

	_idle = Timer.new()
	_idle.one_shot = true
	_idle.wait_time = IDLE_TIMEOUT_SEC
	_idle.timeout.connect(_on_idle_timeout)
	add_child(_idle)


func _ready() -> void:
	if _watch != null:
		_watch.visibility_changed.connect(_on_watch_visibility_changed)

	_scanner = QrScanner.new()
	_scanner.frame_ready.connect(_on_frame)
	_scanner.detected.connect(_on_detected)
	_scanner.failed.connect(_on_failed)
	_scanner.start()
	# Started either way: a camera that failed to open should not leave the
	# overlay sitting on an error message until someone notices it.
	_idle.start()


## Backstop: the camera must never outlive the node, however it went away.
func _exit_tree() -> void:
	close()


func _on_watch_visibility_changed() -> void:
	if is_instance_valid(_watch) and not _watch.visible:
		close()


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


## Accept codes again after the caller rejected the last one.
func resume() -> void:
	_busy = false
	_confirm_row.visible = false
	_on_confirm = Callable()
	if not _closed and _idle != null:
		_idle.start()


## Show a yes/no question. `on_confirm` runs only if the player says yes;
## saying no resumes scanning.
func ask(question: String, on_confirm: Callable) -> void:
	_confirm_label.text = question
	_on_confirm = on_confirm
	_confirm_row.visible = true
	if _idle != null:
		_idle.stop()


func close() -> void:
	if _closed:
		return
	_closed = true
	# is_instance_valid, not != null: on a teardown that frees the whole menu the
	# view can already be gone, and is_connected on a freed object errors.
	if is_instance_valid(_watch) and _watch.visibility_changed.is_connected(_on_watch_visibility_changed):
		_watch.visibility_changed.disconnect(_on_watch_visibility_changed)
	if _idle != null:
		_idle.stop()
	if _scanner != null:
		_scanner.stop()
		_scanner = null
	queue_free()


## Every Viewport2Din3D click arrives twice. Buttons stay in the default RELEASE
## action mode, and anything that is not idempotent is guarded here as well.
func _accept_activation() -> bool:
	var frame := Engine.get_process_frames()
	if frame == _last_activate_frame:
		return false
	_last_activate_frame = frame
	return true


func _on_frame(luma: PackedByteArray) -> void:
	if _closed or luma.size() != QrScanner.PREVIEW_WIDTH * QrScanner.PREVIEW_HEIGHT:
		return
	_image.set_data(QrScanner.PREVIEW_WIDTH, QrScanner.PREVIEW_HEIGHT,
		false, Image.FORMAT_L8, luma)
	_texture.update(_image)


func _on_detected(payload: String) -> void:
	if _closed or _busy:
		return
	_busy = true
	if _idle != null:
		_idle.stop()
	scanned.emit(payload)


func _on_failed(message: String) -> void:
	if _closed:
		return
	set_status(message)


func _on_idle_timeout() -> void:
	set_status("No code found. Closing the camera.")
	_emit_cancelled()


func _on_cancel_pressed() -> void:
	_emit_cancelled()


func _on_confirm_pressed() -> void:
	if not _accept_activation():
		return
	var cb := _on_confirm
	_on_confirm = Callable()
	_confirm_row.visible = false
	if cb.is_valid():
		cb.call()


func _on_decline_pressed() -> void:
	if not _accept_activation():
		return
	set_status("Point the headset at the QR code on your screen.")
	resume()


func _emit_cancelled() -> void:
	if _closed:
		return
	cancelled.emit()
	close()
