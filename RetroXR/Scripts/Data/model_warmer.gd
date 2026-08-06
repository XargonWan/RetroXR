## ModelWarmer — pays a model's first-spawn cost up front, where nobody is looking.
##
## Spawning a model the first time in a session is expensive on Quest and cheap
## every time after. Measured on a Quest 3, the 3DS stand-in: 3949 ms the first
## time, 85 ms the second. The cost is three one-off things — parsing the scene,
## the model's own _ready, and compiling its pipelines on first draw — and all
## three are paid by simply instantiating the model and letting it be drawn once.
##
## Drawing it in a 256x256 offscreen SubViewport is enough: the pipelines it
## compiles are the ones the main STEREO pass wants, which was not obvious and had
## to be measured (176 ms afterwards against 184 ms for warming in the real world,
## versus 2621 ms cold). So nothing is ever placed where a player could see it.
##
## The stand-ins are warmed by instantiating and drawing them, above. The imported
## shells are warmed differently — a threaded load of the GLB alone, no instance,
## no draw — because their cost is the load and it is enormous: 6.9 s of blocked
## main thread for the NES on a Quest 3. See warm_shells().
##
## They were once left out entirely, as "1.1 GiB of texture memory between them,
## which a Quest cannot spare". Measured on-device that is ~6 MiB for the NES; the
## gigabyte was the reflection atlas, unrelated to any model.
##
## The instances are thrown away. What persists is SystemModelRegistry's hold on
## the PackedScene — without that the scene is dropped and re-parsed on the next
## spawn — plus the compiled pipelines in the renderer's own cache.
class_name ModelWarmer
extends RefCounted

## Set when warming BEGINS, so a second caller does not start a parallel pass.
static var _started := false
## Set when it ENDS. These have to be separate: a caller that wants to know the
## models are ready (a probe timing a spawn, or anything gating on it) is asking
## about the second, and reading the reentry guard instead races the warm and
## measures a half-warmed process.
static var _finished := false

## Same pair for the shells, which warm separately — see warm_shells().
static var _shells_started := false
static var _shells_finished := false

## Every warmed shell's PackedScene, held for the life of the process. This IS the
## warm: a model instantiates its GLB and keeps only the nodes, so the moment that
## model is freed the scene would leave the cache and the next spawn would pay the
## whole load again.
static var _held_shells: Array[Resource] = []


## True once every stand-in has been warmed and thrown away.
static func is_warmed() -> bool:
	return _finished


## Coroutine. `host` only needs to be in the tree — the warming viewport is
## parented to it and removed again.
static func warm_stand_ins(host: Node) -> void:
	if _started or host == null or not host.is_inside_tree():
		return
	_started = true
	var tree := host.get_tree()

	var sv := SubViewport.new()
	sv.name = "ModelWarmViewport"
	sv.size = Vector2i(256, 256)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(sv)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 0.1, 0.35)
	sv.add_child(cam)
	cam.current = true
	sv.add_child(DirectionalLight3D.new())

	var t := Time.get_ticks_usec()
	var mem0: float = Performance.get_monitor(Performance.MEMORY_STATIC)
	var tex0: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	var n := 0
	for id: String in SystemModelRegistry.stand_in_ids():
		if not SystemModelRegistry.is_available(id):
			continue
		var model: RetroSystemModel = SystemModelRegistry.instantiate(
			SystemModelRegistry.row_for(id))
		if model == null:
			continue
		sv.add_child(model)
		await tree.process_frame
		await RenderingServer.frame_post_draw
		model.queue_free()
		await tree.process_frame
		n += 1

	sv.queue_free()
	await tree.process_frame
	_finished = true
	# Reported, not assumed: what this costs to KEEP is the reason it is limited to
	# the stand-ins, so the figure belongs in the log next to the time.
	print("[ModelWarmer] %d stand-ins warmed in %.2f s  (+%.1f MiB static, +%.1f MiB texture)"
		% [n, float(Time.get_ticks_usec() - t) / 1000000.0,
			(Performance.get_monitor(Performance.MEMORY_STATIC) - mem0) / 1048576.0,
			(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) - tex0) / 1048576.0])


## Pull each bespoke shell's GLB into the resource cache, off the main thread.
##
## A shell's model loads its GLB with a plain load() inside _ready(), so that cost
## lands on whichever frame the player spawns one. Measured on a Quest 3 with
## Tools/quest_spawn_probe.tscn: the NES shell took **6861 ms with not one frame
## drawn**, against 63-78 ms per spawn once cached. That is the freeze.
##
## Two things make this work:
##
##   * The reference is KEPT. A model keeps only the instantiated nodes, not the
##     PackedScene, so without _held_shells the scene is dropped when that model is
##     freed and the next spawn pays the full load again.
##   * The load is THREADED. Warming these the way the stand-ins are warmed would
##     just move the same seven seconds into startup; requesting them and polling a
##     frame at a time leaves the room drawing throughout.
##
## The shells were originally left out of warming as "1.1 GiB of texture memory
## between them, which a Quest cannot spare". That figure does not survive
## measurement — the NES shell costs ~6 MiB of texture on-device. The gigabyte was
## the reflection atlas, which is sized by project settings and had nothing to do
## with the shells (see rendering/reflections/reflection_atlas/reflection_count).
static func warm_shells(host: Node) -> void:
	if _shells_started or host == null or not host.is_inside_tree():
		return
	_shells_started = true
	var tree := host.get_tree()
	var t := Time.get_ticks_usec()
	var tex0: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)

	var pending: Array[String] = []
	for path: String in SystemModelRegistry.shell_assets():
		if ResourceLoader.load_threaded_request(path) == OK:
			pending.append(path)
	if pending.is_empty():
		return

	while not pending.is_empty():
		await tree.process_frame
		if not is_instance_valid(host) or not host.is_inside_tree():
			return
		var still: Array[String] = []
		for path: String in pending:
			match ResourceLoader.load_threaded_get_status(path):
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					still.append(path)
				ResourceLoader.THREAD_LOAD_LOADED:
					var res := ResourceLoader.load_threaded_get(path)
					if res != null:
						_held_shells.append(res)
				_:
					push_warning("[ModelWarmer] shell asset failed to load: " + path)
		pending = still

	_shells_finished = true
	print("[ModelWarmer] %d shells warmed in %.2f s  (+%.1f MiB texture)"
		% [_held_shells.size(), float(Time.get_ticks_usec() - t) / 1000000.0,
			(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) - tex0) / 1048576.0])
