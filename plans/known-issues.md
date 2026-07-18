* n64 mupen gles3 core seems to play fast and the audio crackles a lot
    * needs an on-device session: check retro_get_system_av_info fps vs the
      emulation-thread pacing, and whether GL HW-render frame delivery bypasses
      the frame-duration accumulator on Android
* if start a scene and there are video ports plugged in to the tv when i start, i noticed this will have segments to just go up and up and sometimes the video port will just go down and down
* can't seem to use mouse wheel in desktop or the vr controller stick to scroll up and down a menu for systems

# Core-Info Known Issues

As this is a submodule, we need to somehow upstream the issues we found

* Playstation Portable is just named "playstation_portable", this isn't visually appearling with the underscore and lack of captailizations
* There is an insconsistency with the `systemname` "C64" where the corrisponding `systemid` is called either "commodore_c64" or "commodore_64"
