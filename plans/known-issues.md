* Mouse doesn't input to a game for mouse direction
    * Tested in VR with a mouse in a SNES on Mario Paint
* Stoping a system (core) causes a stuttur (game freezes for less than a second)
* can't seem to drop a nintendo DS when picked up with hand in VR
    * drop is grip+trigger+stick-click on the holding hand (same as cabinet
      controllers); confirm whether that combo drops a cabinet controller to tell
      if this is DS-specific or just the combo being hard to find
* Virtual Boy on a TV shows the raw side-by-side frame, not a single/stereo image
    * currently by design — the video-out treats the TV like a capture card
    * revisit if a single-eye (or anaglyph) TV view is wanted
* Virtual Boy has no easy-to-find start/stop (power) control while a game is running
* DVD remote has no "Return" (go-up-one-menu-level) button — libVLC 3's navigate API
  only exposes up/down/left/right/activate/popup (no dvdnav go_up), so a true Return
  isn't implementable on the current stack. "Menu" already escapes any submenu to the
  root menu; revisit a dedicated Return if/when we move to libVLC 4.
