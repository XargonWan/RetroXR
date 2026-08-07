# Hardware coverage

Which real hardware RetroXR models, and which it doesn't yet. Split by kind so
each file stays readable.

Real hardware only. RetroXR's own props — the generic pad, cartridge, disc,
memory card, multitap, keyboard/mouse, ray gun and controller cable — are not
listed: nothing here corresponds to them, and counting them as implemented only
inflated the totals.

| File | Rows | Implemented |
|---|---|---|
| `retroxr_systems.csv` | 59 | 1 |
| `retroxr_controllers.csv` | 29 | 1 |
| `retroxr_carts.csv` | 16 | 1 |
| `retroxr_peripherals.csv` | 13 | 1 |

## Columns

- **System** — the platform the hardware belongs to.
- **Model** — the specific piece of hardware.
- **Implemented** — **the real model is in the room.** A procedural stand-in does
  **not** count, even when it is playable. The Pokémon Mini, Lynx, WonderSwan, Neo
  Geo Pocket and Supervision all boot and run games, but what you pick up is a
  primitive box, so they read `[ ]`. Otherwise the column would say "done" about
  five consoles nobody has modelled.

The NES is the first platform with real hardware in the room: the front-loading
NES-001, its pad, its cart and the connector on the pad's lead. Everything else
still reads `[ ]` — what ships for those is the procedural stand-ins in
`RetroXR/Scenes/Objects/system_models/`, clean geometry rather than replicas.

The NES rows are ticked only for what is actually modelled. The Famicom, the
NTSC top loader, the Zapper, the Famicom cart and the FDS disk are all still `[ ]`
even though the platform they sit under now has real hardware.

## Adding a model

`SystemModelRegistry` (`RetroXR/Scripts/Data/systems/model_registry.gd`) is the
one place a model is declared: a row with an id, the platform it sits under, a
label for the spawn menu, and either a scene or a script. The spawn menu follows
from that, so landing a new model is a row plus its files — and tick the box here.

Anything modelled for RetroXR must be work you have the right to ship.
