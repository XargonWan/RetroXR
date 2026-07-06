# Wish-List

This is collection of random ideas that get commited into this file over time

* Use spatial data from Oculus Quest 3 (2 not supported) for collision of objects in passthrough scene
    * this would allow TVs, consoles, objects, etc. to be placed on real-world objects
    * maybe allow for room recall if possible?
* Multiplayer
    * Another player could join in be 'player 2' (or 3, 4, etc) in the scene that the player 'hosts'
    * Would require a lot of understanding how to implement this. Isn't quite clear on the technical details, and this could be too much effort (or tokens)
    * would need some way to send roms on-demand or verify the same rom exists on the player by hash and sync libretro state... somehow?
        * similar thing needed for books and videos
* Rollback netcode for netplay (future upgrade over the initial delay-based lockstep)
    * current netplay is strict delay-based lockstep: the emu thread blocks until the agreed
      inputs for frame N arrive, so every peer feels the full network latency (hidden only by a
      tunable input-delay buffer) and a late/lost packet stalls everyone
    * RetroArch's netplay is rollback: run ahead on predicted remote input, and when the real
      input arrives for an already-run frame that mispredicted, invisibly load the savestate at
      that frame and replay forward — so local input always feels zero-latency
    * the CRC-desync + savestate handshake plumbing is already shared with lockstep, so the
      upgrade is mostly: predict remote input, keep a ring of recent savestates, detect
      misprediction, rewind+replay. needs cheap/frequent core serialization
    * would feel much better for twitchy games (fighters) over Quest Wi-Fi jitter
