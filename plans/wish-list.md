# Wish-List

This is collection of random ideas that get commited into this file over time

* Use spatial data from Oculus Quest 3 (2 not supported) for collision of objects in passthrough scene
    * this would allow TVs, consoles, objects, etc. to be placed on real-world objects
    * maybe allow for room recall if possible?
* Non-VR build
    * Would require some way of setting controls in game
    * Mouse and WASD main controlls
        * there would need to a 'dot' in the middle of the screen (sort of like a cross hair) to know where can be selected just like someone would do with picking up and object or interacting it with a ray
        * There may be some ineration limitaions.
            * maybe have special key to use for 'activating' (toggeling) buttons
* Video Player
    * Videos (mp4 and maybe other 'easy' to support fomrats) can be put in a folder 'videos', just like how books is.
    * would spawn a VCR shape device which contains a 'path' to the video file just like how cartridges are down
    * There would be a 'vcr player' object which would slot in the VCR objects. The 'vcr player' would have a button on it for 'play', 'pause' (consider other controls?)
        * This would use the same 'plug' as the systems use which would connect to TVs in the same way systems do which would display the 'video' on the screen it is attached to in the same way a 'system' does. (try to reuse code here)
* Multiplayer
    * Another player could join in be 'player 2' (or 3, 4, etc) in the scene that the player 'hosts'
    * Would require a lot of understanding how to implement this. Isn't quite clear on the technical details, and this could be too much effort (or tokens)
* Ray-Gun Support
    * Support Ray-Gun controllers with libretro,
    * A player can spawn in a 'ray-gun' controller used for video games (like duck hunt and others) 
        * A player would point this at a TV where the X,Y coordinates of where the 'gun' is pointed in relation to the tv "screen" is to be passed to the libretro control instance
* VR Controller button remapping for libretro systems
    * Allow for remaping of controls of the Quest Controllers to the libretro instance
    * Would need persistence on this options
    * maybe have per system? or global?
