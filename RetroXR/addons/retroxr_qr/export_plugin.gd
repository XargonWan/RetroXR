## Puts the RetroXRQr Android plugin into a Quest build.
##
## The permissions live here rather than in export_presets.cfg (gitignored, so
## machine-local) or inside the AAR (binary, so not greppable). They land in the
## generated manifest under their own attributed block, alongside the ones the
## OpenXR vendors plugin contributes.
@tool
extends EditorExportPlugin

const BIN_DIR := "res://addons/retroxr_qr/bin/"
const ZXING := "com.google.zxing:core:3.5.3"


func _get_name() -> String:
	return "RetroXRQr"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
	if not _supports_platform(platform):
		return PackedStringArray()
	var aar := "retroxr-qr-debug.aar" if debug else "retroxr-qr-release.aar"
	return PackedStringArray([BIN_DIR + aar])


## The AAR compiles against ZXing but does not bundle it, so the app supplies it.
func _get_android_dependencies(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
	if not _supports_platform(platform):
		return PackedStringArray()
	return PackedStringArray([ZXING])


## CAMERA gates Camera2 at all; HEADSET_CAMERA gates the passthrough cameras
## specifically. Both are runtime permissions — QrScanner asks for them on the
## first scan rather than at boot, because an unanswered Horizon OS consent
## dialog blocks the app from launching.
func _get_android_manifest_element_contents(platform: EditorExportPlatform, debug: bool) -> String:
	if not _supports_platform(platform):
		return ""
	return """
	<uses-permission android:name="android.permission.CAMERA" />
	<uses-permission android:name="horizonos.permission.HEADSET_CAMERA" />
	<uses-feature android:name="android.hardware.camera2" android:required="false" />
"""
