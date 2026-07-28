# GBA

* the power light doesn't come on when it is turned on
* the power switch doesn't slide to on when it is slide
* the buttons don't seem to animate

# Core-Info Known Issues

As this is a submodule, we need to somehow upstream the issues we found

* There is an insconsistency with the `systemname` "C64" where the corrisponding `systemid` is called either "commodore_c64" or "commodore_64"
* Same inconsistency for the Amiga — `systemid` is either "commodore_amiga" or "amiga" depending on the core
* Cost of both: `SystemInfo.for_system()` resolves `res://SystemInfo/<systemid>.tres`, so each of these machines needs TWO identical `.tres` files or half the cores get the fallback descriptor (2 ports, cartridge) instead of the authored one. `RetroVR/SystemInfo/` is 60 files for 58 real systems because of it. Anything that counts or lists systems from that directory double-counts the C64 and the Amiga.
* Some systemids carry no usable `systemname` at all ("playstation_portable" comes back as the raw id). `CoreInfoDatabase._NAME_OVERRIDES` patches that one locally rather than editing the submodule
