## Vinyl mini blinds that raise and lower on a pull cord.
##
## Slats are one MultiMesh — 48 of them in a single draw call, with no per-frame
## mesh rebuild; only instance transforms move. Draw calls are the binding
## constraint on Quest, so a slat-per-MeshInstance would have been 48 of them for
## a window dressing.
##
## `drop` is 0 (fully raised) to 1 (fully lowered) and everything derives from it.
## Real blinds do not slide as a rigid unit: the slats STACK at the headrail as
## they rise, so the pitch between them collapses rather than the whole assembly
## translating. That is why raising bunches them at the top instead of sliding
## them out of view.
##
## Pulling is BeadPullCord's, not a second interaction. The cord signals `pulled`
## and this steps `drop`; leaving the cord's light_path empty stops it toggling a
## lamp as well.
class_name WindowBlinds
extends Node3D


signal drop_changed(drop: float)


## Window opening the blinds cover, in this node's local space.
@export var width: float = 1.44
@export var height: float = 1.18

@export var slat_count: int = 48
@export var slat_thickness: float = 0.0022
@export var slat_height: float = 0.019

## Pitch when fully raised. Not zero — stacked vinyl slats still occupy their own
## thickness, and collapsing them to a plane makes the headrail look empty.
@export var stack_pitch: float = 0.0055

@export var slat_color: Color = Color(0.87, 0.85, 0.79)

## 0 = raised (stacked at the headrail), 1 = lowered (covering the window).
@export_range(0.0, 1.0) var drop: float = 1.0:
	set(v):
		drop = clampf(v, 0.0, 1.0)
		_apply()
		drop_changed.emit(drop)

## How much a single pull changes `drop`. Pulls step DOWN through the range and
## wrap back to fully lowered, which matches the one-cord blinds this models —
## a two-cord blind would need a second cord to reverse, and one cord that only
## ever goes one way is easier to understand in VR than a hidden direction toggle.
@export var step: float = 0.25

@export var animate_time: float = 0.45

## The sun spot coming through this window, dimmed as the blinds close. Owning
## its energy here is safe: QualityManager writes shadow_enabled on every light
## but only touches energy for the "ceiling_light" group, which this is not in.
@export var sun_path: NodePath
@export var sun_energy: float = 3.0

var _sun: Light3D = null

var _slats: MultiMeshInstance3D = null
var _bottom: MeshInstance3D = null
var _tween: Tween = null


func _ready() -> void:
	if not sun_path.is_empty():
		_sun = get_node_or_null(sun_path) as Light3D
	_build()
	_apply()


func _build() -> void:
	var slat := BoxMesh.new()
	slat.size = Vector3(width, slat_height, slat_thickness)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = slat
	mm.instance_count = slat_count

	var mat := StandardMaterial3D.new()
	mat.albedo_color = slat_color
	# Vinyl, not paper: a little sheen so the slats separate under the sun rather
	# than reading as one flat sheet.
	mat.roughness = 0.42
	mat.metallic = 0.0

	_slats = MultiMeshInstance3D.new()
	_slats.name = "Slats"
	_slats.multimesh = mm
	_slats.material_override = mat
	add_child(_slats)

	# Headrail, fixed at the top.
	var head := MeshInstance3D.new()
	head.name = "HeadRail"
	var hb := BoxMesh.new()
	hb.size = Vector3(width + 0.03, 0.042, 0.032)
	head.mesh = hb
	head.position = Vector3(0.0, 0.021, 0.0)
	var hm := StandardMaterial3D.new()
	hm.albedo_color = slat_color.darkened(0.08)
	hm.roughness = 0.45
	head.material_override = hm
	add_child(head)

	# Bottom rail rides the lowest slat, so it is placed in _apply().
	_bottom = MeshInstance3D.new()
	_bottom.name = "BottomRail"
	var bb := BoxMesh.new()
	bb.size = Vector3(width + 0.006, 0.026, 0.007)
	_bottom.mesh = bb
	_bottom.material_override = hm
	add_child(_bottom)


func _apply() -> void:
	if _slats == null:
		return
	# A blind does NOT compress every slat evenly as it rises. The slats still
	# HANGING stay at their full pitch with daylight between them, and only the
	# raised ones bunch up against the headrail. Interpolating one pitch across the
	# whole run was the first attempt and it read as a solid sheet, because at any
	# partial height the pitch fell below slat_height and every slat overlapped its
	# neighbour.
	var full_pitch := height / float(slat_count)
	var hanging := int(round(float(slat_count) * drop))
	var stacked := slat_count - hanging
	var mm := _slats.multimesh
	var y := 0.0
	for i in slat_count:
		y -= stack_pitch if i < stacked else full_pitch
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0.0, y, 0.0)))
	if _bottom != null:
		_bottom.position = Vector3(0.0, y - 0.012, 0.0)
	if _sun != null:
		_sun.light_energy = sun_energy * openness()


## Signal target for BeadPullCord.pulled, which carries a bool that means nothing
## here — a blind has no on/off, only a height. Needed as its own method because
## GDScript will not connect a 1-argument signal to a 0-argument callable.
func _on_cord_pulled(_on: bool) -> void:
	pull_step()


## One pull: step down through the range, wrapping back to fully lowered.
func pull_step() -> void:
	var target: float = drop - step
	if target < -0.001:
		target = 1.0
	_animate_to(clampf(target, 0.0, 1.0))


func _animate_to(target: float) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_method(_set_drop, drop, target, animate_time) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _set_drop(v: float) -> void:
	drop = v


## Fraction of the window still open, for anything that wants to dim with the
## blinds — the sun spot does.
func openness() -> float:
	return 1.0 - drop
