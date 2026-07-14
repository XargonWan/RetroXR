# Open

* Stopping a system (core) causes a stutter (game freezes for less than a second)
    * Fix committed 2026-07-13 (non-blocking StopContent, libretro-godot b890571) —
      close after an on-device pass confirms power-off no longer hitches
* Drop combo (grip+trigger+stick-click) reported not working on cabinet controllers
    * The powered-off-handheld case (undroppable DS) was a real gate bug, fixed in
      b03c29f. The cabinet-controller code path reads correct, so that report is
      unexplained — [drop-combo] diagnostics now log the three inputs on state
      change; grab a console/logcat trace next VR session to see whether
      primary_click ever registers or the drop handling fails
* try to stop the n64 mupen gles3 core seems to freeze the game and the oculus
  quest says too much memory being used and it was killed
    * Likely the old blocking stop (main thread joined a hung GL teardown). Retest
      with the 2026-07-13 non-blocking StopContent + rebuilt Android .so; if the
      app now survives, remaining leak is the abandoned core thread
* n64 mupen gles3 core seems to play fast and the audio crackles a lot
    * Needs an on-device session: check retro_get_system_av_info fps vs the
      emulation-thread pacing, and whether GL HW-render frame delivery bypasses
      the frame-duration accumulator on Android

# Fixed this pass (2026-07-13) — verify in VR, then delete

* Nintendo DS undroppable when picked up while powered off (b03c29f)
* TV remote now snaps to a straight grip like the ray gun (669f86b)
* Virtual Boy: collision matches the model + selection ray can hit it (4995021)
* Virtual Boy: power button toggles START/STOP while running (9d31c45)
* Virtual Boy: controller port under the visor front, pointing down (29d4696)
* SNES mouse: plug-before-power-on now works (port-device persistence, submodule
  8fbdd03); bsnes2014 still ignores mouse deltas by design of our zero-on-read
  path — SNES default is bsnes now, latch fix documented in project memory if a
  multi-poll core (DOSBox etc.) ever needs it
