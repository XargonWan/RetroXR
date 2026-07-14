* Mouse direction works with snes9x/bsnes but NOT bsnes2014 (resolved by switching
  the SNES default core to bsnes)
    * Root cause (frontend-side): InputHandler::ProcessMouseDevice returns the
      accumulated delta and zeroes it on the FIRST read. bsnes2014 queries mouse
      X/Y more than once per frame, so the read the game actually uses gets 0.
      The libretro contract is: repeated queries within a frame return the same
      value; the delta window resets at retro_input_poll. Fix if ever needed:
      latch the accumulator once per frame (input_poll or frame-counter guard)
      instead of zero-on-read — also affects other multi-poll cores (DOSBox etc.)
* Stoping a system (core) causes a stuttur (game freezes for less than a second)
    * A non-blocking StopContent (deferred join/teardown via _process) exists in the
      libretro-godot working tree (restored 2026-07-13 from a git stash that the
      deployed Windows template_debug DLL was already built from) — needs validation
      and an Android rebuild before this can be marked fixed
* can't seem to drop a nintendo DS when picked up with hand in VR
    * drop is grip+trigger+stick-click on the holding hand (same as cabinet
      controllers); confirm whether that combo drops a cabinet controller to tell
      if this is DS-specific or just the combo being hard to find
        * i confirmed that this does not work
* Virtual Boy collision doesn't match the model
* Virtual Boy, start button doesn't toggle to stop after pressing start
* Virtual boy controller port should be under the red 'headset' in the front, pointing down
* Virtual boy ray interesect doesn't seem to intersect with the model when selecting to be grabed by the ray
* try to stop the n64 mupen gles3 core seems to freeze the game and the oculus quest says too much memory being used and it was killed
* n64 mupen gles3 core seems to plays fast and the audio seems to crakle a lot
* tv remote doesn't point stright when held, It just points in the orientation that it was picked up, it should point stright just like the ray gun when it is picked
