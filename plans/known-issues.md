* n64 mupen gles3 core seems to play fast and the audio crackles a lot
    * needs an on-device session: check retro_get_system_av_info fps vs the
      emulation-thread pacing, and whether GL HW-render frame delivery bypasses
      the frame-duration accumulator on Android
* the checkbox in the system tab where 'ignore gravity' is and sometimes 'enable video out', isn't using the same button slider as the options menu
  * we need to make this toggle more visually appeallying as well
* in desktop allow the mouse well to bring in objects a bit closer lowering the 'min'
* when rotating objects in VR and Desktop with the stick when held by the ray, it's not intentive, where the rotation happens from the persetive of the player
  * this needs to be tought about and dicussed a better way of where pressing right,left,up,down on the stack rotates the object right from the orientation of the player

# Core-Info Known Issues

As this is a submodule, we need to somehow upstream the issues we found

* Playstation Portable is just named "playstation_portable", this isn't visually appearling with the underscore and lack of captailizations
* There is an insconsistency with the `systemname` "C64" where the corrisponding `systemid` is called either "commodore_c64" or "commodore_64"
