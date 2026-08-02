# Hardware coverage

Which real hardware retroXR models, and which it doesn't yet. Split by kind so
each file stays readable.

Real hardware only. retroXR's own props — the generic pad, cartridge, disc,
memory card, multitap, keyboard/mouse, ray gun and controller cable — are not
listed: nothing here corresponds to them, and counting them as implemented only
inflated the totals.

| File | Rows | Implemented |
|---|---|---|
| `retroxr_systems.csv` | 59 | 0 |
| `retroxr_controllers.csv` | 29 | 0 |
| `retroxr_carts.csv` | 16 | 0 |
| `retroxr_peripherals.csv` | 12 | 0 |

## Columns

- **System** — the platform the hardware belongs to.
- **Model** — the specific piece of hardware.
- **Implemented** — **the real model is in the room.** A procedural stand-in does
  **not** count, even when it is playable. The Pokémon Mini, Lynx, WonderSwan, Neo
  Geo Pocket and Supervision all boot and run games, but what you pick up is a
  primitive box, so they read `[ ]`. Otherwise the column would say "done" about
  five consoles nobody has modelled.

Everything currently reads `[ ]`. What ships today is the procedural stand-ins in
`RetroXR/Scenes/Objects/system_models/` — clean geometry rather than replicas.

## Adding a model

`SystemModelRegistry` (`RetroXR/Scripts/Data/systems/model_registry.gd`) is the
one place a model is declared: a row with an id, the platform it sits under, a
label for the spawn menu, and either a scene or a script. The spawn menu follows
from that, so landing a new model is a row plus its files — and tick the box here.

Anything modelled for retroXR must be work you have the right to ship.
