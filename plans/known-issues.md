* Drop combo (grip+trigger+stick-click) reported not working on cabinet controllers
    * the code path reads correct, so the report is unexplained — [drop-combo]
      diagnostics log the three inputs on state change; grab a console/logcat
      trace next VR session to see whether primary_click ever registers
* try to stop the n64 mupen gles3 core seems to freeze the game and the oculus
  quest says too much memory being used and it was killed
    * likely the old blocking stop (main thread joined a hung GL teardown) —
      retest with the non-blocking StopContent + rebuilt Android .so
* n64 mupen gles3 core seems to play fast and the audio crackles a lot
    * needs an on-device session: check retro_get_system_av_info fps vs the
      emulation-thread pacing, and whether GL HW-render frame delivery bypasses
      the frame-duration accumulator on Android
