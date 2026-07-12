# Wish-List

This is collection of random ideas that get commited into this file over time

* Use spatial data from Oculus Quest 3 (2 not supported) for collision of objects in passthrough scene
    * this would allow TVs, consoles, objects, etc. to be placed on real-world objects
    * maybe allow for room recall if possible?

* Add bloom/glow to the CRT tube (dropped from the Flowerwall port — the spatial tube shader is single-pass and can't blur on its own)
    * Path 1 (cheap, recommended): the MainScene WorldEnvironment already has glow_enabled; the CRT just clamps ALBEDO to 1.0 so nothing crosses the glow threshold. Stop clamping, push highlights above 1.0 with a `crt_glow` uniform (soft knee on luminance), tune glow_hdr_threshold, and add a slider to the TV CRT options tab. Reuses the existing glow pass — Quest-cheap
    * caveat: engine glow is scene-global (blooms every bright thing, not per-tube, bleeds into the room — usually fine in a dark arcade)
    * Path 2 (heavy): confined/per-TV bloom via a SubViewport post-process chain running Flowerwall's blur + bloom canvas_item shaders near-verbatim → final texture on the tube. Full control but N extra render targets per TV per frame
