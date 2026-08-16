## AvSource — what a source device's own sockets currently reach.
##
## Every machine that puts a picture or a sound onto a lead asks the same question
## when a plug moves: walking MY sockets, which sinks do I reach, which of their
## speakers does each channel land on, and did any cord land somewhere its other
## end did not mean? A console, a VCR and a DVD player each answered it for
## themselves, and the three answers drifted — only the console read a multi-way
## socket through `channel_for()`, collected more than one screen, recognised a
## sink with no screen, or understood a stereo lead.
##
## Resolving lives here. What to DO with the answer stays with each device, which
## is where they genuinely differ: a console tells every screen it reaches, a deck
## drives the one it is showing on.
class_name AvSource


## One source's current wiring.
class Feed:
	## Every television the picture reaches, in link order. More than one is
	## ordinary — a PC tower wears a DE-15 and a phono jack.
	var video_sinks: Array[RetroTV] = []
	## The sink carrying the sound: a set, a pair of powered speakers, or anything
	## else that can say where its speakers are. The first one found wins, and
	## cords into a second are ignored rather than splitting the sound.
	var audio_sink: Node3D = null
	## Which of that sink's speakers each channel lands on — 0 left, 1 right, -1
	## nowhere. Crossed cords are honest here: left really does come out of the
	## right-hand speaker if that is where the cord went.
	var left := -1
	var right := -1
	## One entry per cord, "OUT->IN", marked "(!)" when the two ends sit on
	## different channels. A phono plug fits any phono socket — that is the
	## hardware, not an oversight — so this is the commonest wiring mistake in the
	## room and the only thing that makes it visible.
	var cords: Array[String] = []

	## The sink a device that models a single connection should treat as "the"
	## one: the screen if there is one, else whatever is carrying the sound.
	func primary_sink() -> Node3D:
		return video_sinks[0] if not video_sinks.is_empty() else audio_sink

	## Human-readable summary of every cord, for the log.
	func summary() -> String:
		return ", ".join(cords) if not cords.is_empty() else "none"


## Resolve `dev`'s wiring from ITS OWN sockets, not from the lead that reported.
##
## A cable reports only its own cords, and every caller then overwrites its
## picture and both speaker routings wholesale — so with two leads on one machine
## whichever moved last cancelled the other. Walked over RcaPort.GROUP via
## AvGraph, so a socket authored into a model scene counts the same as one built
## at runtime. Runs on a plug or unplug, never per frame.
##
## `stereo` says whether the device has separate left and right outputs. Mono
## hardware has one audio socket and no other, so its cord carries the whole of
## the sound: both channels go wherever it lands, and two coincident sources sum.
static func resolve(dev: Node3D, stereo: bool) -> Feed:
	var feed := Feed.new()
	for link in AvGraph.links_for(dev):
		var out_port: RcaPort = link["out"]
		if out_port.get_device() != dev:
			continue
		var in_port: RcaPort = link["in"]
		# Asked of the socket WITH THE CORD, never read off `channel` directly. A
		# phono jack answers the same either way, but the Wii's AV Multi Out is one
		# socket carrying all three signals and only the cord tells them apart —
		# see RcaPort.channel_for.
		var cord: int = int(link.get("cord", 0))
		var out_ch: RcaPort.Channel = out_port.channel_for(cord)
		var in_ch: RcaPort.Channel = in_port.channel_for(cord)
		feed.cords.append("%s->%s%s" % [out_port.channel_name_for(cord),
			in_port.channel_name_for(cord), "" if out_ch == in_ch else "(!)"])
		# Duck-typed, not `as RetroTV`. A television is not the only thing a source
		# can be wired into — a pair of powered speakers is a sink with no screen at
		# all — and the cast silently dropped every one of them.
		# get_speaker_positions is the whole of what a sink has to offer: the source
		# owns its voices and moves them onto whatever comes back.
		var target := in_port.get_device()
		if target == null or not target.has_method("get_speaker_positions"):
			continue
		# Which of the sink's speakers this cord lands on. Channel order is VIDEO,
		# L, R, so an audio input gives 0 or 1; the video input carries nothing an
		# amplifier can use.
		var dest := -1 if in_ch == RcaPort.Channel.VIDEO else int(in_ch) - 1
		match out_ch:
			RcaPort.Channel.VIDEO:
				# A picture needs a screen, so this sink has to be a television —
				# and only a VIDEO input carries one.
				if in_ch == RcaPort.Channel.VIDEO:
					var set_ := target as RetroTV
					if set_ != null and not feed.video_sinks.has(set_):
						feed.video_sinks.append(set_)
			RcaPort.Channel.AUDIO_L:
				if feed.audio_sink != null and feed.audio_sink != target:
					continue
				feed.audio_sink = target
				feed.left = dest
				if not stereo:
					feed.right = dest
			RcaPort.Channel.AUDIO_R:
				if feed.audio_sink != null and feed.audio_sink != target:
					continue
				feed.audio_sink = target
				feed.right = dest
			RcaPort.Channel.AUDIO_STEREO:
				# One cord, both channels — which is what a 3.5 mm TRS lead is. Left
				# goes to the sink's left speaker and right to its right, and there
				# is no crossed case to model: unlike a pair of phono cords, a
				# stereo plug cannot be put in half way round.
				if in_ch == RcaPort.Channel.AUDIO_STEREO:
					if feed.audio_sink != null and feed.audio_sink != target:
						continue
					feed.audio_sink = target
					feed.left = 0
					feed.right = 1
	return feed
