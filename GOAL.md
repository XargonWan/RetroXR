# RetroVR

This is a libretro core manager/downloader, rom datamanager, rom scraper, in VR

There shall be "tvs" which have a display which displays the libretro output. Each of these displays shall have a port on it which is used to hook up a "system" object. This shall resemble a composite video port (yellow, red, white cables). The other end of this cable shall connect to a system.

## Objects

Each of these objects shall be spawnable by a menu. This menu is opened by the user. this menu has 3 ribbons in it where a user can use a 'ray' from the touch controllers and use the grip button while point at these objects to spawn them in their hand. These objects shall be in a grid menu where it shows a 3d mockup of the object.

### Systems

These shall resemble a retro console (playstation 1, nintendo entertainment sytem, super nintendo, nintendo 64 etc). From a programming perspective, they shall contain the "libretro" frontent.
They shall have a libretro core that is always attached to it (firm-coded) in to the object. (there can be other libretro cores but shall be limited to those only usueable by the system). Use can select the 'defaullt' libretro core for that system in an options menu.

The systems will run this libretro script. The 'rendered' output shall be based on a "user grabbable" video cable that is on the back of the system. The user will physicall drag it from the system to the tv. This shall be done with touch controls where the user uses the "grip" button and holds it, letting go of the end of the cable at the tv esentially plugging it in.

The systems shall also have a CD/Cartrige slot. This is where it loads the path of the game to load it in to. The user can phyically grab that object which will attach to this System object

The system shall have physicall buttons on it where the user acts with VR by touching (pressing), these buttons. One of these buttons are turn on (start libretro) and turn off (stop libretro) where it toggles. Another button is 'reset' libretro, just like reseting a game.

### CD/Cartriges

These are 3d objects which contain a rom path as a configuration object for it. These objects are dragged by the player and attached to a system. Once they are attached, the system's libretro instance uses the rom path from this object. When this object is removed, detached, from the system, it clears that path in the libretro system.

### TVs

Theses TVs shall contain a 3d instance where the System can attach to for it to render the video output. This is also where the audio from the system is to be spatially. There also shall be a position where the user can drop the System rope cable for a system to attach to it.