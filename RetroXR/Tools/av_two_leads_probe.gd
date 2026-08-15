## A deck wired to one television with TWO leads: picture on one, sound on the
## other. Each cable reports only its own cords, so whichever resolved last used
## to overwrite the deck's whole routing and silently drop the other half.
##
##   godot --headless --path RetroXR res://Tools/av_two_leads_probe.tscn
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const VCR_SCENE := preload("res://Scenes/Objects/appliances/vcr_player.tscn")
const CABLE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")

var _fail := false


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[two] FAIL: %s" % msg)


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[two] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.position = Vector3(0, 1, 0)
	tv.freeze = true
	add_child(tv)
	tv.add_to_group("spawned")
	var deck := VCR_SCENE.instantiate() as VCRPlayer
	deck.position = Vector3(1.2, 1, 0)
	deck.freeze = true
	add_child(deck)
	deck.add_to_group("spawned")
	await _wait(40)

	var tv_ports: Array[RcaPort] = []
	for n in ["CompositePort4", "AudioLIn4", "AudioRIn4"]:
		tv_ports.append(tv.get_node_or_null(n) as RcaPort)
	var deck_ports: Array[RcaPort] = []
	for n in ["VideoOut", "AudioLOut", "AudioROut"]:
		deck_ports.append(deck.get_node_or_null(n) as RcaPort)

	# Lead A carries the picture, lead B carries the pair. Both land on Composite 4.
	var lead_a := CABLE_SCENE.instantiate() as Node3D
	lead_a.position = Vector3(0.5, 1, -0.4)
	add_child(lead_a)
	var lead_b := CABLE_SCENE.instantiate() as Node3D
	lead_b.position = Vector3(0.7, 1, -0.6)
	add_child(lead_b)
	await _wait(30)

	deck_ports[0].pick_up_object(lead_a.get_node("PlugA0") as RcaPlug)
	tv_ports[0].pick_up_object(lead_a.get_node("PlugB0") as RcaPlug)
	await _wait(10)
	# Seated SECOND, so lead B is the one that resolves last.
	for c in [1, 2]:
		deck_ports[c].pick_up_object(lead_b.get_node("PlugA%d" % c) as RcaPlug)
		tv_ports[c].pick_up_object(lead_b.get_node("PlugB%d" % c) as RcaPlug)
		await _wait(10)
	await _wait(40)

	print("[two] after both leads: tv=%s video=%s left=%d right=%d" % [
		deck.connected_tv != null, deck._feed_video, deck._feed_left, deck._feed_right])
	_fail_if(deck.connected_tv == null, "the deck does not know which set it feeds")
	_fail_if(not deck._feed_video, "the picture cord was forgotten (lead B resolved last)")
	_fail_if(deck._feed_left != 0 or deck._feed_right != 1,
		"the sound pair was forgotten (left=%d right=%d)" % [deck._feed_left, deck._feed_right])

	var input := -1
	for i in (tv._connected_systems as Array).size():
		if tv._connected_systems[i] == deck:
			input = i
	print("[two] the set files the deck on input %d (want %d)" % [input, RetroTV.Source.COMPOSITE_4])
	_fail_if(input != RetroTV.Source.COMPOSITE_4, "wrong input")

	# Now make lead A resolve last, which is the other order of the same wiring.
	# Which lead resolves last must not matter. Each cable reports only its own
	# cords, so hand the deck each report in turn and check the other half of its
	# routing survives — this is the defect itself, without the snap-zone physics
	# a real re-plug would drag in (a released plug is left standing in front of a
	# row of sockets 18 mm apart whose grab zones reach 60 mm, and a neighbour
	# catches it first).
	deck.on_av_topology_changed(lead_b.links())
	await _wait(5)
	print("[two] after the SOUND lead reports: video=%s left=%d right=%d" % [
		deck._feed_video, deck._feed_left, deck._feed_right])
	_fail_if(not deck._feed_video, "a report from the sound lead dropped the picture")

	deck.on_av_topology_changed(lead_a.links())
	await _wait(5)
	print("[two] after the PICTURE lead reports: video=%s left=%d right=%d" % [
		deck._feed_video, deck._feed_left, deck._feed_right])
	_fail_if(deck._feed_left != 0 or deck._feed_right != 1,
		"a report from the picture lead dropped the sound")

	print("[two] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame
