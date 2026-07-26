extends Node

## Exercises the real PageGrab input path with a fake VR controller: proximity,
## the trigger latch, the drag, and the release. Nothing here calls the fold
## solver directly.

const BOOK := preload("res://Scenes/Objects/pdf_book.tscn")
const PDF := "nintendo_power_issue1.pdf"

var _book: Node3D
var _ctrl: XRController3D
var _tracker: XRControllerTracker
var _origin: XROrigin3D
var _fails: int = 0
var _checks: int = 0


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void: get_tree().quit(1))
	_build()
	await _wait(150)
	await _run()
	print("[probe] %d/%d checks passed" % [_checks - _fails, _checks])
	get_tree().quit(1 if _fails > 0 else 0)


func _check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("[probe] %s %s" % ["PASS" if ok else "FAIL", label])


func _build() -> void:
	_book = BOOK.instantiate()
	_book.set("pdf_path", OS.get_environment("USERPROFILE").replace("\\", "/") + "/retrovr/books/" + PDF)
	add_child(_book)
	(_book as RigidBody3D).freeze = true
	_book.global_position = Vector3.ZERO

	_origin = XROrigin3D.new()
	add_child(_origin)
	_ctrl = XRController3D.new()
	_ctrl.tracker = &"right_hand"
	_origin.add_child(_ctrl)
	# PokeTip.tip_of() just wants a child node of this name; keeping it at the
	# controller origin makes the maths below one-to-one.
	var tip := Node3D.new()
	tip.name = "PokeTip"
	_ctrl.add_child(tip)

	_tracker = XRControllerTracker.new()
	_tracker.name = &"right_hand"
	_tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(_tracker)
	_set_hand(Vector3(0.0, 0.0, 1.0), 0.0)


func _set_hand(world_pos: Vector3, trigger: float) -> void:
	var rel := Transform3D(Basis(), _origin.global_transform.affine_inverse() * world_pos)
	_tracker.set_pose(&"default", rel, Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_tracker.set_input(&"trigger", trigger)


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame


func _run() -> void:
	_book.call("set_page", 1, 8)
	await _wait(40)

	var w: float = _book.get("_book_width")
	var plane_z: float = _book.call("_page_plane_z", 1)
	var spine_half := 0.005 * 0.5
	# Middle of the right-hand grab band, a bit below centre.
	var grip := _book.to_global(Vector3(spine_half + w * 0.80, -0.03, plane_z))

	_check("controller active", _ctrl.get_is_active())

	# Hover with the trigger released — must NOT latch.
	_set_hand(grip, 0.0)
	await _wait(4)
	_check("hover alone does not grab", int(_book.get("_grab_dir")) == 0)
	_check("hover shows the page hint", bool(_book.get("_grab_right").call("is_hovering")))

	# Pull the trigger — must latch and anchor on the gripped spot.
	_set_hand(grip, 0.85)
	await _wait(4)
	var latched := int(_book.get("_grab_dir")) == 1
	_check("trigger latches the page", latched)
	if not latched:
		return
	var anchor: Vector2 = _book.get("_grab_anchor")
	var leaf: Node3D = _book.get("_active_leaf")
	var expect: Vector3 = leaf.to_local(grip)
	_check("anchor lands where the hand was (%.4f vs %.4f)" % [anchor.x, expect.x],
		absf(anchor.x - expect.x) < 0.002 and absf(anchor.y - expect.y) < 0.002)

	# Drag toward the spine — the fold must advance.
	var mid := _book.to_global(Vector3(spine_half + w * 0.15, -0.02, plane_z + 0.05))
	_set_hand(mid, 0.85)
	await _wait(4)
	var mid_progress: float = _book.call("_turn_progress")
	_check("drag advances the fold (%.3f)" % mid_progress, mid_progress > 0.25)

	# Still latched with the hand well off the page — latch-then-roam.
	var far := _book.to_global(Vector3(-w * 1.6, 0.10, plane_z + 0.20))
	_set_hand(far, 0.85)
	await _wait(4)
	_check("latch survives the hand leaving the page", int(_book.get("_grab_dir")) == 1)

	# Release past the commit threshold.
	var final_progress: float = _book.call("_turn_progress")
	_set_hand(far, 0.1)
	await _wait(4)
	_check("release past %.0f%% commits (was %.3f)" % [50.0, final_progress],
		final_progress >= 0.5)
	await _wait(45)
	_check("turn completed to leaf 9 (got %s)" % _book.get("_current_leaf"),
		int(_book.get("_current_leaf")) == 9)
	_check("leaf cleaned up", _book.get("_active_leaf") == null)
	_check("grab released", int(_book.get("_grab_dir")) == 0)

	# Deliberately pulling again turns another page.
	_set_hand(grip, 0.0)
	await _wait(4)
	_set_hand(grip, 0.85)
	await _wait(4)
	_check("a fresh pull grabs again", int(_book.get("_grab_dir")) == 1)

	# The zone being switched off underneath a held trigger (the book changes
	# state, or the PDF reloads) drops the page — and must NOT re-latch while
	# that same pull is still held, which is what the re-arm map is for.
	var zone: PageGrab = _book.get("_grab_right")
	zone.set_enabled(false)
	await _wait(2)
	zone.set_enabled(true)
	await _wait(6)
	_check("held trigger does not re-latch after a forced release",
		not zone.is_held())
	_set_hand(grip, 0.0)
	await _wait(50)
