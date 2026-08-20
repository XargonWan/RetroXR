## Binding self-tests — the resolution rules behind per-platform control
## overrides, run headless with no core, no ROM, no headset and no pad.
##
##     "$godot" --headless --path RetroXR res://Tests/binding_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## Both stores merge default → global → per-system, and a platform's stored
## profile IS its override switch — there is no separate flag. That makes three
## rules load-bearing, and each has a case below: a platform with no profile is
## indistinguishable from global; a profile shadows global completely, including
## global edits made afterwards; and clearing a profile puts that platform back
## on global without touching anyone else's.
##
## What is NOT covered here, on purpose: that a binding reaches a running core.
## That needs a real system, a real controller and the CONSUMER_GROUP fan-out,
## and it lives in Tools/binding_live_probe.tscn.
##
## This writes the player's own user://controller_bindings.json and
## user://gamepad_bindings.json — the paths are consts on the two classes and
## cannot be pointed elsewhere — so both are snapshotted up front and restored
## byte-for-byte at the end.
extends Node

## Two platforms, so "clearing one leaves the other standing" is a real
## assertion rather than a tautology. Named so a leaked file is obviously test
## residue and not a console the player owns.
const SYS_A := "__binding_selftest_a"
const SYS_B := "__binding_selftest_b"

var _pass := 0
var _fail := 0

## path -> file contents, or an absent key when there was no file to begin with.
var _saved: Dictionary = {}

## Guards _snapshot() against overwriting the player's data with test data.
var _snapped := false


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		_restore()
		get_tree().quit(1))

	_snapshot()
	_clear()

	_test_no_profile_is_global()
	_test_profile_shadows_global()
	_test_later_global_edit_does_not_leak()
	_test_has_override()
	_test_clear_restores_global()
	_test_empty_systemid_is_global()
	_test_overridden_systems()
	_test_console_pad_art()

	_restore()
	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


# ── The player's own files, taken away and put back ───────────────────────────

## Snapshot the player's real bindings. Idempotent ON PURPOSE, and the guard is
## the whole point: every case below starts from a clean slate, so this used to
## be called again at the top of each one — and because it also DELETED the
## files, the second call snapshotted the FIRST case's test data over the
## player's. _restore() then faithfully put the test data back. It overwrote a
## real settings file with `right_grip -> R2` and `a -> btn:9`, which are
## literally _xr_profile() and _pad_profile()'s arguments.
func _snapshot() -> void:
	if _snapped:
		return
	_snapped = true
	for path: String in [ControllerBindings.SAVE_PATH, GamepadBindings.SAVE_PATH]:
		if FileAccess.file_exists(path):
			_saved[path] = FileAccess.get_file_as_string(path)


## The clean slate each case wants. Deletes only — it never touches the snapshot.
func _clear() -> void:
	for path: String in [ControllerBindings.SAVE_PATH, GamepadBindings.SAVE_PATH]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _restore() -> void:
	for path: String in [ControllerBindings.SAVE_PATH, GamepadBindings.SAVE_PATH]:
		if _saved.has(path):
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_string(_saved[path] as String)
				f.close()
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## A whole XR profile built off the shipped defaults with one button moved, so
## every key is present — a partial profile would leak later global edits, which
## is exactly what _test_later_global_edit_does_not_leak checks against.
func _xr_profile(source: String, bit: int) -> Array:
	var buttons := ControllerBindings.DEFAULT_BUTTON_MAP.duplicate()
	buttons[source] = bit
	return [buttons, ControllerBindings.DEFAULT_STICK_MAP.duplicate(),
		ControllerBindings.DEFAULT_LIGHTGUN_MAP.duplicate()]


func _pad_profile(target: String, binding: String) -> Array:
	var buttons := GamepadBindings.DEFAULT_BUTTON_MAP.duplicate()
	buttons[target] = binding
	return [buttons, GamepadBindings.DEFAULT_STICK_MAP.duplicate()]


# ---------------------------------------------------------------------------
# A platform with no profile of its own is exactly global.
# ---------------------------------------------------------------------------

func _test_no_profile_is_global() -> void:
	_clear()
	var xr_global := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(xr_global[0], xr_global[1], xr_global[2])
	var pad_global := _pad_profile("a", "btn:5")
	GamepadBindings.save_global(pad_global[0], pad_global[1])

	_eq("xr/no profile resolves to global",
		ControllerBindings.get_for_system(SYS_A)["buttons"],
		ControllerBindings.get_global()["buttons"])
	_eq("pad/no profile resolves to global",
		GamepadBindings.get_for_system(SYS_A)["buttons"],
		GamepadBindings.get_global()["buttons"])
	# And the global edit itself took, rather than both sides agreeing on stale
	# defaults — a comparison of two identical wrong answers proves nothing.
	_eq("xr/global edit took",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)
	_eq("pad/global edit took",
		str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")),
		"btn:5")


# ---------------------------------------------------------------------------
# A profile shadows global for its own platform and nobody else's.
# ---------------------------------------------------------------------------

func _test_profile_shadows_global() -> void:
	_clear()
	var g := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(g[0], g[1], g[2])
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])

	_eq("xr/profile wins for its own platform",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_R2)
	_eq("xr/another platform still reads global",
		int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)
	_eq("xr/the global map itself is untouched",
		int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)

	var pg := _pad_profile("a", "btn:5")
	GamepadBindings.save_global(pg[0], pg[1])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])

	_eq("pad/profile wins for its own platform",
		str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")), "btn:9")
	_eq("pad/another platform still reads global",
		str((GamepadBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("a")), "btn:5")
	_eq("pad/the global map itself is untouched",
		str((GamepadBindings.get_global()["buttons"] as Dictionary).get("a")), "btn:5")


# ---------------------------------------------------------------------------
# The reason a profile is written WHOLE: an override must pin a platform against
# global edits made after it, not track them.
# ---------------------------------------------------------------------------

func _test_later_global_edit_does_not_leak() -> void:
	_clear()
	var g := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(g[0], g[1], g[2])
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])

	# Move a DIFFERENT button globally, after the override was written.
	var g2 := _xr_profile("left_grip", ControllerBindings.JOYPAD_R3)
	ControllerBindings.save_global(g2[0], g2[1], g2[2])

	_eq("xr/a later global edit does not reach an overridden platform",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("left_grip")),
		ControllerBindings.DEFAULT_BUTTON_MAP["left_grip"])
	_eq("xr/but it does reach an un-overridden one",
		int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("left_grip")),
		ControllerBindings.JOYPAD_R3)


# ---------------------------------------------------------------------------
# The switch's own state: the profile IS the flag.
# ---------------------------------------------------------------------------

func _test_has_override() -> void:
	_clear()
	_ok("xr/no override before a write", not ControllerBindings.has_system_override(SYS_A))
	_ok("pad/no override before a write", not GamepadBindings.has_system_override(SYS_A))

	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])

	_ok("xr/override after a write", ControllerBindings.has_system_override(SYS_A))
	_ok("pad/override after a write", GamepadBindings.has_system_override(SYS_A))
	_ok("xr/a sibling platform is unaffected", not ControllerBindings.has_system_override(SYS_B))
	_ok("pad/a sibling platform is unaffected", not GamepadBindings.has_system_override(SYS_B))
	# The global map must never report as an override, or the switch would come
	# up ON for every platform the moment the player edits the global page.
	_ok("xr/the global scope is not an override", not ControllerBindings.has_system_override(""))
	_ok("pad/the global scope is not an override", not GamepadBindings.has_system_override(""))


# ---------------------------------------------------------------------------
# Turning the switch off.
# ---------------------------------------------------------------------------

func _test_clear_restores_global() -> void:
	_clear()
	var g := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(g[0], g[1], g[2])
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])
	var b := _xr_profile("right_grip", ControllerBindings.JOYPAD_L2)
	ControllerBindings.save_for_system(SYS_B, b[0], b[1], b[2])

	ControllerBindings.clear_system_override(SYS_A)

	_ok("xr/clear drops the override", not ControllerBindings.has_system_override(SYS_A))
	_eq("xr/cleared platform is back on global",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)
	_ok("xr/the other platform's profile stands",
		ControllerBindings.has_system_override(SYS_B))
	_eq("xr/and still resolves to its own value",
		int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L2)
	_eq("xr/global survives the clear",
		int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)

	var pg := _pad_profile("a", "btn:5")
	GamepadBindings.save_global(pg[0], pg[1])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])
	GamepadBindings.clear_system_override(SYS_A)
	_ok("pad/clear drops the override", not GamepadBindings.has_system_override(SYS_A))
	_eq("pad/cleared platform is back on global",
		str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")), "btn:5")

	# Clearing a platform that never had one is a no-op, not a crash — the switch
	# can be flicked off on a page that was never overridden.
	ControllerBindings.clear_system_override("__never_written")
	GamepadBindings.clear_system_override("__never_written")
	_ok("clearing an absent profile is harmless", true)


# ---------------------------------------------------------------------------
# The fall-through the shared binding editor is built on: one editor class
# serves both pages because an empty systemid means "global".
# ---------------------------------------------------------------------------

func _test_empty_systemid_is_global() -> void:
	_clear()
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system("", a[0], a[1], a[2])
	_eq("xr/save_for_system(\"\") writes global",
		int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_R2)

	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system("", pa[0], pa[1])
	_eq("pad/save_for_system(\"\") writes global",
		str((GamepadBindings.get_global()["buttons"] as Dictionary).get("a")), "btn:9")

	_eq("xr/get_for_system(\"\") is get_global",
		ControllerBindings.get_for_system("")["buttons"],
		ControllerBindings.get_global()["buttons"])
	_eq("pad/get_for_system(\"\") is get_global",
		GamepadBindings.get_for_system("")["buttons"],
		GamepadBindings.get_global()["buttons"])

	# A global write must not invent a per_system entry, or every platform tile
	# would come up badged the first time the global page is touched.
	_ok("xr/a global write creates no per-system entry",
		ControllerBindings.overridden_systems().is_empty())
	_ok("pad/a global write creates no per-system entry",
		GamepadBindings.overridden_systems().is_empty())


# ---------------------------------------------------------------------------
# What the tile badges are painted from.
# ---------------------------------------------------------------------------

func _test_overridden_systems() -> void:
	_clear()
	_ok("xr/nothing overridden on a fresh store",
		ControllerBindings.overridden_systems().is_empty())

	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])
	var b := _xr_profile("right_grip", ControllerBindings.JOYPAD_L2)
	ControllerBindings.save_for_system(SYS_B, b[0], b[1], b[2])

	var listed := ControllerBindings.overridden_systems()
	listed.sort()
	_eq("xr/lists exactly the overridden platforms", listed, [SYS_A, SYS_B])

	ControllerBindings.clear_system_override(SYS_A)
	_eq("xr/a cleared platform leaves the list",
		ControllerBindings.overridden_systems(), [SYS_B])

	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])
	_eq("pad/lists its own overridden platforms",
		GamepadBindings.overridden_systems(), [SYS_A])
	# The two stores are independent: a pad override alone must still badge the
	# tile, which is why the view asks both.
	_ok("the two stores disagree independently",
		GamepadBindings.has_system_override(SYS_A)
			and not ControllerBindings.has_system_override(SYS_A))


# ---------------------------------------------------------------------------
# ConsolePadArt — the table a platform's own controller is drawn from.
# ---------------------------------------------------------------------------

func _test_console_pad_art() -> void:
	_ok("art/nes has a pad", ConsolePadArt.has("nes"))
	_ok("art/a platform without one says so", not ConsolePadArt.has("super_nes"))
	# The global page passes "" as its systemid, and it must never draw a console.
	_ok("art/the global scope has no pad", not ConsolePadArt.has(""))

	var controls := ConsolePadArt.controls("nes")
	var want := ["up", "down", "left", "right", "select", "start", "b", "a"]
	var got := controls.duplicate()
	got.sort()
	want.sort()
	_eq("art/nes carries exactly its eight controls", got, want)

	# The whole two-sections-one-table trick rests on this: a control key is a
	# GamepadBindings target, and that array's index IS the RetroPad bit. If the
	# two ever disagree, the XR half silently binds the wrong button.
	_eq("art/a maps to JOYPAD_A", ConsolePadArt.bit_of("a"), ControllerBindings.JOYPAD_A)
	_eq("art/b maps to JOYPAD_B", ConsolePadArt.bit_of("b"), ControllerBindings.JOYPAD_B)
	_eq("art/select maps to JOYPAD_SELECT",
		ConsolePadArt.bit_of("select"), ControllerBindings.JOYPAD_SELECT)
	_eq("art/start maps to JOYPAD_START",
		ConsolePadArt.bit_of("start"), ControllerBindings.JOYPAD_START)
	_eq("art/up maps to JOYPAD_UP", ConsolePadArt.bit_of("up"), ControllerBindings.JOYPAD_UP)
	_eq("art/down maps to JOYPAD_DOWN",
		ConsolePadArt.bit_of("down"), ControllerBindings.JOYPAD_DOWN)
	_eq("art/left maps to JOYPAD_LEFT",
		ConsolePadArt.bit_of("left"), ControllerBindings.JOYPAD_LEFT)
	_eq("art/right maps to JOYPAD_RIGHT",
		ConsolePadArt.bit_of("right"), ControllerBindings.JOYPAD_RIGHT)

	# Structural check for whoever adds the next console: every control needs an
	# anchor and a row, and every anchor needs to be a control. A row entry with
	# no anchor draws a lead to the origin; an anchor with no row draws nothing
	# and its control silently cannot be bound.
	var row := ConsolePadArt.row("nes")
	var anchors: Dictionary = row["anchors"]
	var listed: Array = (row["top"] as Array) + (row["bottom"] as Array)
	var listed_sorted := listed.duplicate()
	listed_sorted.sort()
	_eq("art/every control appears in exactly one row", listed_sorted, want)
	var anchor_keys: Array = anchors.keys()
	anchor_keys.sort()
	_eq("art/anchors and controls are the same set", anchor_keys, want)

	var in_range := true
	for control: String in anchors:
		var uv: Vector2 = anchors[control]
		if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
			in_range = false
	_ok("art/anchors are normalized to the art", in_range)

	_ok("art/the texture loads", ConsolePadArt.texture("nes") != null)
	_ok("art/an uncovered platform has no texture", ConsolePadArt.texture("super_nes") == null)
