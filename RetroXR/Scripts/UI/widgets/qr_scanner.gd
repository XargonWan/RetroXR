## QrScanner — GDScript side of the RetroXRQr Android plugin.
##
## The plugin drives a Meta passthrough camera through Camera2 and decodes QR
## codes with ZXing on its own thread, so this is only a binding: it forwards
## the three signals and owns the connect/disconnect pair.
##
## Availability is Quest 3 / 3S on Horizon OS v74 or newer. Everywhere else
## (Quest 2, Quest Pro, Windows, Linux) is_available() is false and callers are
## expected to hide the entry point rather than fail on use.
class_name QrScanner
extends RefCounted

const SINGLETON := "RetroXRQr"

## CAMERA gates Camera2 at all, HEADSET_CAMERA gates the passthrough cameras.
## Both are runtime permissions, and openCamera throws without either.
const PERMISSIONS: PackedStringArray = [
	"android.permission.CAMERA",
	"horizonos.permission.HEADSET_CAMERA",
]

## Preview frames arrive as 8-bit luma at this size. Must match the plugin.
const PREVIEW_WIDTH := 320
const PREVIEW_HEIGHT := 240

## A preview frame, PREVIEW_WIDTH * PREVIEW_HEIGHT bytes of luma.
signal frame_ready(luma: PackedByteArray)
## A QR was decoded. The payload is raw — see RommPairUrl for reading it.
signal detected(payload: String)
signal failed(message: String)

## -1 until asked, then 0 or 1. The plugin enumerates cameras to answer, so the
## result is cached: this is called while building menu rows.
static var _available: int = -1

var _plugin: Object = null
var _running: bool = false


static func singleton() -> Object:
	if not Engine.has_singleton(SINGLETON):
		return null
	return Engine.get_singleton(SINGLETON)


static func is_available() -> bool:
	if _available < 0:
		var plugin := singleton()
		var ok: bool = plugin != null and bool(plugin.isAvailable())
		_available = 1 if ok else 0
	return _available == 1


static func has_permission() -> bool:
	var granted := OS.get_granted_permissions()
	for p in PERMISSIONS:
		if not (p in granted):
			return false
	return true


## Raises the Horizon OS consent dialogs. They are answered outside the app, so
## the result here only says a request was made — re-check has_permission()
## after the player comes back.
static func request_permission() -> bool:
	var granted := OS.get_granted_permissions()
	var asked := false
	for p in PERMISSIONS:
		if not (p in granted):
			asked = OS.request_permission(p) or asked
	return asked


func is_running() -> bool:
	return _running


func start() -> bool:
	if _running:
		return true

	var plugin := singleton()
	if plugin == null:
		failed.emit("QR scanning is not available on this device")
		return false

	_plugin = plugin
	plugin.connect("qr_frame", _on_frame)
	plugin.connect("qr_detected", _on_detected)
	plugin.connect("qr_error", _on_error)

	if not bool(plugin.startScan()):
		stop()
		failed.emit("Could not open the headset camera")
		return false

	_running = true
	return true


## Safe to call repeatedly, and from any teardown path.
func stop() -> void:
	if _plugin == null:
		return

	if _plugin.is_connected("qr_frame", _on_frame):
		_plugin.disconnect("qr_frame", _on_frame)
	if _plugin.is_connected("qr_detected", _on_detected):
		_plugin.disconnect("qr_detected", _on_detected)
	if _plugin.is_connected("qr_error", _on_error):
		_plugin.disconnect("qr_error", _on_error)

	if _running:
		_plugin.stopScan()

	_running = false
	_plugin = null


## No NOTIFICATION_PREDELETE hook here on purpose. On a RefCounted the refcount
## has already reached zero by then, so calling stop() on self fails with
## "call function 'stop' in base 'null instance'". The owner stops the scanner
## explicitly instead — see QrScanOverlay.close(), which every teardown path
## goes through.
func _on_frame(luma: PackedByteArray) -> void:
	frame_ready.emit(luma)


func _on_detected(payload: String) -> void:
	detected.emit(payload)


func _on_error(message: String) -> void:
	failed.emit(message)
