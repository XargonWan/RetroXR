extends Node

## The bedroom's time-of-day lever and the lighting it drives.
##
##   godot --headless --path RetroXR res://Tests/time_of_day_tests.tscn
##   godot --headless --path RetroXR res://Tests/time_of_day_tests.tscn -- --only=authored
##
## Exits non-zero on failure, so it can gate a commit. No ROM, core, headset or
## GPU — the whole feature is property writes over a scene that loads headless.
##
## `authored` is the group that matters most and the reason this suite exists. The
## room shipped as ONE hard-authored dusk, and t = 0.75 has to reproduce it exactly
## — every colour, every energy, and both sun BASES. It has already caught the case
## it was written for: slaving the indoor fill to the exterior sun's raw azimuth
## swung it 9.3 degrees and silently relit the shipped room, because the two are
## authored at different azimuths on purpose.
##
## `sharing` is the other one worth keeping. Resource.duplicate() is shallow, so an
## Environment copy still points at the .tscn's one Sky and its one sky material;
## without hand-copying both levels, changing the time in one bedroom repaints the
## sky in every other instance in the session.
##
## What this canNOT check is how any of it LOOKS. That is
## `Tools/bedroom_probe.tscn --mode=timesweep`, windowed.

const GROUPS := ["authored", "sharing", "sweep", "night", "blinds", "lever", "desktop", "persist"]
const SCENE := preload("res://Scenes/BedroomScene.tscn")

## The authored dusk, transcribed from BedroomScene.tscn before TimeOfDay existed.
const AUTHORED_DUSK := 0.75

var _fail := 0
var _ran := 0
var _only := ""

var _root: Node = null
var _tod: TimeOfDay = null
var _lever: VRLever = null
var _blinds: WindowBlinds = null
var _we: WorldEnvironment = null
var _dusk: DirectionalLight3D = null
var _ext_sun: DirectionalLight3D = null
var _ext_fill: DirectionalLight3D = null
var _win_sun: SpotLight3D = null
var _lamp: OmniLight3D = null
var _lamp_head: MeshInstance3D = null
var _pref_backup := 0.0


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	# The persist cases write the player's real prefs, so put them back after.
	_pref_backup = AppPrefs.bedroom_time_of_day

	_root = SCENE.instantiate()
	add_child(_root)
	for i in 6:
		await get_tree().process_frame

	_tod = _root.get_node("TimeOfDay")
	_lever = _root.get_node("Furniture/TimeLever/LeverPivot/Lever")
	_blinds = _root.get_node("Furniture/Blinds")
	_we = _root.get_node("WorldEnvironment")
	_dusk = _root.get_node("Dusk")
	_ext_sun = _root.get_node("ExteriorSun")
	_ext_fill = _root.get_node("ExteriorFill")
	_win_sun = _root.get_node("WindowSun")
	_lamp = _root.get_node("Exterior/StreetLamp/Light")
	_lamp_head = _root.get_node("Exterior/StreetLamp/Head")

	if _want("authored"):
		await _test_authored()
	if _want("sharing"):
		await _test_sharing()
	if _want("sweep"):
		await _test_sweep()
	if _want("night"):
		await _test_night()
	if _want("blinds"):
		await _test_blinds()
	if _want("lever"):
		await _test_lever()
	if _want("desktop"):
		await _test_desktop()
	if _want("persist"):
		await _test_persist()

	AppPrefs.bedroom_time_of_day = _pref_backup
	AppPrefs.save_prefs()
	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ── t = 0.75 IS the room as authored ──────────────────────────────────────────

func _test_authored() -> void:
	_tod.apply_now(AUTHORED_DUSK)
	await get_tree().process_frame

	# The three contested energies are the blinds' to write, scaled by how far they
	# are open, so the expected values carry that factor. The scene ships drop 0.25.
	var open: float = _blinds.openness()

	_col(_dusk.light_color, Color(1, 0.72, 0.5), "authored/Dusk colour")
	_num(_dusk.light_energy, lerpf(0.035, 0.15, open), "authored/Dusk energy")
	_basis(_dusk.global_transform.basis,
		Basis(Vector3(0.94, 0, -0.34), Vector3(-0.24, 0.7, -0.67), Vector3(0.24, 0.71, 0.66)),
		"authored/Dusk basis (azimuth 19.9, elevation 45.2)")

	_col(_win_sun.light_color, Color(1, 0.83, 0.62), "authored/WindowSun colour")
	_num(_win_sun.light_energy, 3.6 * open, "authored/WindowSun energy")

	_col(_ext_sun.light_color, Color(1, 0.74, 0.48), "authored/ExteriorSun colour")
	_num(_ext_sun.light_energy, 1.5, "authored/ExteriorSun energy")
	_basis(_ext_sun.global_transform.basis,
		Basis(Vector3(0.87, 0, -0.49), Vector3(-0.32, 0.76, -0.57), Vector3(0.37, 0.65, 0.66)),
		"authored/ExteriorSun basis (azimuth 29.2, elevation 40.5)")

	_col(_ext_fill.light_color, Color(0.45, 0.55, 0.85), "authored/ExteriorFill colour")
	_num(_ext_fill.light_energy, 0.5, "authored/ExteriorFill energy")

	var env: Environment = _we.environment
	_col(env.ambient_light_color, Color(1, 0.84, 0.7), "authored/ambient colour")
	_num(env.ambient_light_energy, lerpf(0.10, 0.25, open), "authored/ambient energy")

	var sm: ProceduralSkyMaterial = env.sky.sky_material
	_col(sm.sky_top_color, Color(0.06, 0.11, 0.3), "authored/sky top")
	_col(sm.sky_horizon_color, Color(0.78, 0.45, 0.28), "authored/sky horizon")
	_col(sm.ground_horizon_color, Color(0.55, 0.35, 0.24), "authored/ground horizon")
	_col(sm.ground_bottom_color, Color(0.05, 0.05, 0.06), "authored/ground bottom")

	_num(_lamp.light_energy, 3.0, "authored/street lamp energy")
	var lm: StandardMaterial3D = _lamp_head.get_surface_override_material(0)
	_num(lm.emission_energy_multiplier, 6.0, "authored/street lamp emission")

	# The lamp's reach is what keeps it OUTSIDE. Widening it at night would light
	# the bedroom through a wall, because shadows are off.
	_num(_lamp.omni_range, 14.0, "authored/street lamp range is not widened")


# ── Instance-local resources ──────────────────────────────────────────────────

func _test_sharing() -> void:
	_tod.apply_now(0.0)
	await get_tree().process_frame
	var env: Environment = _we.environment
	var mine: ProceduralSkyMaterial = env.sky.sky_material

	# A second, untouched instance of the same scene is the oracle: whatever it
	# holds is what the .tscn's shared sub-resources still say.
	var other: Node = SCENE.instantiate()
	var shared: Environment = other.get_node("WorldEnvironment").environment

	_ok(env.sky != shared.sky, "sharing/the Sky is a copy, not the shared one")
	_ok(mine != shared.sky.sky_material,
		"sharing/the sky material is a copy, not the shared one")
	_col(shared.sky.sky_material.sky_top_color, Color(0.06, 0.11, 0.3),
		"sharing/a morning room left the shared sky at its authored dusk")
	other.free()


# ── The sweep actually sweeps ─────────────────────────────────────────────────

func _test_sweep() -> void:
	var amb: Array[float] = []
	var sun: Array[float] = []
	var tops: Array[Color] = []
	for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
		_tod.apply_now(t)
		await get_tree().process_frame
		amb.append(_we.environment.ambient_light_energy)
		sun.append(_ext_sun.light_energy)
		tops.append(_we.environment.sky.sky_material.sky_top_color)

	_ok(amb[1] > amb[0], "sweep/midday is brighter than morning")
	_ok(amb[1] > amb[3], "sweep/midday is brighter than dusk")
	_ok(amb[4] < amb[3], "sweep/night is darker than dusk")
	_ok(sun[4] < sun[1], "sweep/the exterior sun dims into the night")
	var distinct := {}
	for c in tops:
		distinct[c] = true
	_eq(distinct.size(), 5, "sweep/all five keys give a distinct sky")

	# Between keys, not at them: the interpolation has to actually run.
	_tod.apply_now(0.125)
	await get_tree().process_frame
	var mid: float = _we.environment.ambient_light_energy
	_ok(mid > amb[0] and mid < amb[1], "sweep/a value between keys interpolates")

	# The street lamp is GATED, not lerped — a photocell does not sit half-lit
	# through the afternoon.
	_tod.apply_now(0.0)
	await get_tree().process_frame
	_num(_lamp.light_energy, 0.0, "sweep/street lamp is off in the morning")
	_tod.apply_now(0.5)
	await get_tree().process_frame
	_num(_lamp.light_energy, 0.0, "sweep/street lamp is still off at 2pm")
	_tod.apply_now(1.0)
	await get_tree().process_frame
	_ok(_lamp.light_energy > 3.0, "sweep/street lamp is on at night")


# ── The room stays usable at night ────────────────────────────────────────────

func _test_night() -> void:
	_tod.apply_now(1.0)
	await get_tree().process_frame
	_ok(_we.environment.ambient_light_energy >= _tod.night_ambient_floor - 0.0001,
		"night/ambient stays at or above the floor")
	# Zeroing it turns the window into a black rectangle; it is the moon patch.
	_ok(_win_sun.light_energy > 0.05, "night/the window still carries a moon patch")

	# The lamps are the player's, on their pull cords, and the ceiling globe is the
	# light switch's. TimeOfDay writing any of them would fight its owner.
	var bedside: OmniLight3D = _root.get_node("BedsideLampLight")
	var desk: OmniLight3D = _root.get_node("DeskLampLight")
	var globe: OmniLight3D = _root.get_node("FanGlobeLight")
	_num(bedside.light_energy, 1.0, "night/the bedside lamp is left alone")
	_num(desk.light_energy, 1.0, "night/the desk lamp is left alone")
	_num(globe.light_energy, 1.2, "night/the ceiling globe's energy is left alone")
	_ok(globe.visible, "night/the ceiling globe's visibility is the switch's")

	# Blinds shut at night is the darkest the room gets by daylight alone.
	_blinds.drop = 1.0
	await get_tree().process_frame
	_ok(_we.environment.ambient_light_energy >= _tod.night_ambient_floor - 0.0001,
		"night/shut blinds at night still clear the floor")
	_blinds.drop = 0.25


# ── The blinds keep owning the three energies ─────────────────────────────────

func _test_blinds() -> void:
	_tod.apply_now(0.25)
	await get_tree().process_frame
	var open_sun: float = _win_sun.light_energy
	var open_amb: float = _we.environment.ambient_light_energy
	var open_day: float = _dusk.light_energy

	_blinds.drop = 1.0
	await get_tree().process_frame
	_ok(_win_sun.light_energy < open_sun * 0.05, "blinds/shut kills the sun patch")
	_ok(_we.environment.ambient_light_energy < open_amb, "blinds/shut dims the ambient")
	_ok(_dusk.light_energy < open_day, "blinds/shut dims the indoor fill")

	# Shut must never be BRIGHTER than open, at any time of day, or closing the
	# blinds would light the room.
	for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
		_tod.apply_now(t)
		_blinds.drop = 0.0
		await get_tree().process_frame
		var o: float = _we.environment.ambient_light_energy
		_blinds.drop = 1.0
		await get_tree().process_frame
		_ok(_we.environment.ambient_light_energy <= o + 0.0001,
			"blinds/shut <= open ambient at t = %.2f" % t)

	# And a blind moved AFTER the time changed must still scale the new base.
	_tod.apply_now(0.25)
	_blinds.drop = 0.0
	await get_tree().process_frame
	var bright: float = _win_sun.light_energy
	_tod.apply_now(1.0)
	await get_tree().process_frame
	_ok(_win_sun.light_energy < bright,
		"blinds/a time change reaches the lights through the blinds")
	_blinds.drop = 0.25


# ── The lever ─────────────────────────────────────────────────────────────────

func _test_lever() -> void:
	var pivot: Node3D = _root.get_node("Furniture/TimeLever/LeverPivot")
	var ball: Node3D = _root.get_node("Furniture/TimeLever/LeverPivot/Ball")

	for pair in [[0.0, 65.0], [0.5, 0.0], [1.0, -65.0], [0.25, 32.5]]:
		_lever.set_value_no_signal(pair[0])
		_num(rad_to_deg(pivot.rotation.x), pair[1],
			"lever/value %.2f is %+.1f deg" % [pair[0], pair[1]], 0.05)
		_num(_lever.get_value(), pair[0], "lever/value %.2f reads back" % pair[0], 0.001)

	# The whole point of the mount/pivot split: the arm turns about the WALL NORMAL,
	# so the ball tracks along the wall and never swings into the room or through
	# the plaster. If x moves, the mount's basis has been transposed or overwritten.
	var pts: Array[Vector3] = []
	for v in [0.0, 0.25, 0.5, 0.75, 1.0]:
		_lever.set_value_no_signal(v)
		await get_tree().process_frame
		pts.append(ball.global_position)
	var xs: Array[float] = []
	for p in pts:
		xs.append(p.x)
	_ok(float(xs.max()) - float(xs.min()) < 0.001,
		"lever/the ball turns about the wall normal (x is constant)")
	_ok(pts[0].x > -2.525, "lever/the ball stays proud of the wall face")
	_ok(pts[0].z > pts[4].z, "lever/morning is the door side, night the far side")
	# The light switch is at z 0.55 and the door opening starts at z 0.70.
	_ok(pts[0].z < 0.45, "lever/the sweep clears the light switch")
	_ok(pts[0].z < 0.70, "lever/the sweep clears the door opening")

	# Moving the lever moves the room.
	_lever.set_value(0.25)
	await get_tree().create_timer(0.2).timeout
	var day: float = _we.environment.ambient_light_energy
	_lever.set_value(1.0)
	await get_tree().create_timer(0.2).timeout
	_ok(_we.environment.ambient_light_energy < day, "lever/drives the room's ambient")
	_num(_tod.time, 1.0, "lever/drives TimeOfDay.time", 0.001)

	# The throttle coalesces a drag, but the value the player let go on must land.
	for i in 20:
		_lever.set_value(float(i) / 19.0)
	await get_tree().create_timer(0.3).timeout
	_num(_tod.time, 1.0, "lever/the final value of a fast sweep still lands", 0.001)


# ── Desktop press-drag ────────────────────────────────────────────────────────

func _test_desktop() -> void:
	# VRHinge gates its pointer tracking on use_xr and rolls the angle from the
	# mouse WHEEL on desktop, which is right for a lid and wrong for a lever.
	# VRLever overrides that, and this is the case that proves it.
	_ok(not get_viewport().use_xr, "desktop/this run is the non-XR path")

	var mount: Node3D = _root.get_node("Furniture/TimeLever")
	var mid: Vector3 = mount.global_transform * Vector3(0.018, 0.0, -0.11)
	var morning: Vector3 = mount.global_transform * Vector3(0.018, 0.0997, -0.0465)

	_lever.set_value_no_signal(0.5)
	_point(XRToolsPointerEvent.Type.ENTERED, mid, mid)
	_point(XRToolsPointerEvent.Type.PRESSED, mid, mid)
	_num(_lever.get_value(), 0.5, "desktop/a press alone does not jump the lever", 0.01)

	_point(XRToolsPointerEvent.Type.MOVED, morning, mid)
	var dragged: float = _lever.get_value()
	_ok(absf(dragged - 0.5) > 0.1, "desktop/dragging while held moves it")
	_ok(dragged < 0.5, "desktop/it moves toward the end the pointer went to")

	_point(XRToolsPointerEvent.Type.RELEASED, morning, morning)
	var after: float = _lever.get_value()
	_point(XRToolsPointerEvent.Type.MOVED, mid, morning)
	_num(_lever.get_value(), after, "desktop/after release, movement is ignored", 0.001)

	# EXITED must NOT drop the drag — a sweep leaves the grab box almost at once,
	# because the box rides the arm and the pointer is chasing it.
	_lever.set_value_no_signal(0.5)
	_point(XRToolsPointerEvent.Type.PRESSED, mid, mid)
	_point(XRToolsPointerEvent.Type.EXITED, mid, mid)
	_point(XRToolsPointerEvent.Type.MOVED, morning, mid)
	_ok(absf(_lever.get_value() - 0.5) > 0.1,
		"desktop/a drag survives leaving the grab box")
	_point(XRToolsPointerEvent.Type.RELEASED, morning, morning)


# ── Persistence ───────────────────────────────────────────────────────────────

func _test_persist() -> void:
	var before: float = AppPrefs.bedroom_time_of_day

	_lever.set_value(0.4)
	await get_tree().process_frame
	_num(AppPrefs.bedroom_time_of_day, before,
		"persist/a drag does not write prefs every frame", 0.0001)

	_lever.released.emit(_lever.get_value())
	await get_tree().process_frame
	_num(AppPrefs.bedroom_time_of_day, 0.4, "persist/release writes the pref", 0.001)

	# And a fresh room reads it back.
	AppPrefs.bedroom_time_of_day = 0.2
	var fresh: Node = SCENE.instantiate()
	add_child(fresh)
	for i in 4:
		await get_tree().process_frame
	var tod2: TimeOfDay = fresh.get_node("TimeOfDay")
	var lever2: VRLever = fresh.get_node("Furniture/TimeLever/LeverPivot/Lever")
	_num(tod2.time, 0.2, "persist/a fresh room restores the saved time", 0.001)
	_num(lever2.get_value(), 0.2, "persist/and puts the lever's arm back", 0.001)
	fresh.queue_free()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _want(name: String) -> bool:
	return _only.is_empty() or _only == name


func _point(type: XRToolsPointerEvent.Type, at: Vector3, last: Vector3) -> void:
	_lever.pointer_event(XRToolsPointerEvent.new(type, null, _lever, at, last))


func _ok(cond: bool, what: String) -> void:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what if got == want else "%s (got %s, want %s)" % [what, got, want])


func _num(got: float, want: float, what: String, tol: float = 0.002) -> void:
	_ok(absf(got - want) <= tol,
		what if absf(got - want) <= tol
		else "%s (got %.4f, want %.4f)" % [what, got, want])


func _col(got: Color, want: Color, what: String) -> void:
	var ok := absf(got.r - want.r) <= 0.002 and absf(got.g - want.g) <= 0.002 \
		and absf(got.b - want.b) <= 0.002
	_ok(ok, what if ok else "%s (got %s, want %s)" % [what, str(got), str(want)])


func _basis(got: Basis, want: Basis, what: String) -> void:
	var ok := (got.x - want.x).length() <= 0.01 and (got.y - want.y).length() <= 0.01 \
		and (got.z - want.z).length() <= 0.01
	_ok(ok, what if ok else "%s (got x=%v y=%v z=%v)" % [what, got.x, got.y, got.z])
