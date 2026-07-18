* n64 mupen gles3 core seems to play fast and the audio crackles a lot
    * needs an on-device session: check retro_get_system_av_info fps vs the
      emulation-thread pacing, and whether GL HW-render frame delivery bypasses
      the frame-duration accumulator on Android

# Core-Info Known Issues

As this is a submodule, we need to somehow upstream the issues we found

* Playstation Portable is just named "playstation_portable", this isn't visually appearling with the underscore and lack of captailizations
* There is an insconsistency with the `systemname` "C64" where the corrisponding `systemid` is called either "commodore_c64" or "commodore_64"
