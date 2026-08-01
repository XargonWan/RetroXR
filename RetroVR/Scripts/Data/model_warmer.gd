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
## Only the STAND-INS are warmed. The imported shells are 31 s and 1.1 GiB of
## texture memory between them, which a Quest cannot spare; the stand-ins are
## ~1.1 s and near-zero texture, being untextured primitives.
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
