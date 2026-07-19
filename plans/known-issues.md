* n64 mupen gles3 core seems to play fast and the audio crackles a lot
    * needs an on-device session: check retro_get_system_av_info fps vs the
      emulation-thread pacing, and whether GL HW-render frame delivery bypasses
      the frame-duration accumulator on Android
* fov options shows in vr, it should only show up in desktop mode
* controls menu in the spawn menu, shows the keyboard controls in vr
* if the title of a game is too long, it will cut of the buttons on the right side in the cartridges game list
  * it should stop it from expanding too long, and should scroll horizontally through the rest of the name

# Core-Info Known Issues

As this is a submodule, we need to somehow upstream the issues we found

* Playstation Portable is just named "playstation_portable", this isn't visually appearling with the underscore and lack of captailizations
* There is an insconsistency with the `systemname` "C64" where the corrisponding `systemid` is called either "commodore_c64" or "commodore_64"
