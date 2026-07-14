* Mouse doesn't input to a game for mouse direction
    * Tested in VR with a mouse in a SNES on Mario Paint
* Stoping a system (core) causes a stuttur (game freezes for less than a second)
* can't seem to drop a nintendo DS when picked up with hand in VR
    * drop is grip+trigger+stick-click on the holding hand (same as cabinet
      controllers); confirm whether that combo drops a cabinet controller to tell
      if this is DS-specific or just the combo being hard to find
        * i confirmed that this does not work
* Virtual Boy collision doesn't match the model
* DVD remote has no "Return" (go-up-one-menu-level) button — libVLC 3's navigate API
  only exposes up/down/left/right/activate/popup (no dvdnav go_up), so a true Return
  isn't implementable on the current stack. "Menu" already escapes any submenu to the
  root menu; revisit a dedicated Return if/when we move to libVLC 4.
* Virtual Boy, start button doesn't toggle to stop after pressing start
* Virtual boy controller port should be under the red 'headset' in the front, pointing down
* Virtual boy ray interesect doesn't seem to intersect with the model when selecting to be grabed by the ray
* try to stop the n64 mupen gles3 core seems to freeze the game and the oculus quest says too much memory being used and it was killed
* n64 mupen gles3 core seems to plays fast and the audio seems to crakle a lot
