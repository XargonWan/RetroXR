## VbController — stand-in Virtual Boy controller.
##
## The real VB pad is unusual: it carries the console's POWER switch and the
## battery pack on its back, because the head unit has neither. A proper model
## exists in the wild but isn't in our library yet, so this is the generic
## RetroVR pad reshaped, with a battery pack and a working power SLIDER — the
## one control you genuinely cannot reach anywhere else on this system.
##
## Sliding it on/off powers the console it is plugged into, so the Virtual Boy
## is operated the way the hardware actually is.
class_name VbController
extends RetroController

## Fraction of travel past which the switch counts as ON.
const _ON_AT := 0.5

var _slider: VRSlider = null
var _was_on := false


func _ready() -> void:
	super._ready()
	_slider = get_node_or_null("PowerSlider") as VRSlider
	if _slider != null:
		_slider.value_changed.connect(_on_power_slider)


## Drive the plugged-in console's power from the slider, latching on the
## crossing so a jittery hand doesn't toggle it repeatedly mid-slide.
func _on_power_slider(v: float) -> void:
	var on := v >= _ON_AT
	if on == _was_on:
		return
	_was_on = on
	var sys := _connected_system
	if sys == null:
		return
	if on and not sys.is_powered_on:
		sys.power_on()
	elif not on and sys.is_powered_on:
		sys.power_off()


## Reflect the console's state if it was powered some other way (the cabinet
## START button, a save restore), so the switch never sits at odds with it.
func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	super.on_plugged_in(system, port_index)
	if _slider == null or system == null:
		return
	_was_on = system.is_powered_on
	_slider.set_value_no_signal(1.0 if _was_on else 0.0)
