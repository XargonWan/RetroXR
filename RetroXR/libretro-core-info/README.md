# libretro core info

Vendored copy of the libretro core `.info` files — one per core, giving its
display name, the systemid it serves, its supported extensions and its licence.
`CoreInfoDatabase.load_from_project()` parses every `*.info` here.

  Source repo : https://github.com/XenuIsWatching/libretro-super
  Path        : `dist/info/`
  Licence     : MIT — `COPYING`, copied from the same repo.

These files used to be the `libretro/libretro-core-info` submodule, which is a
mirror of the above and lags it. They are vendored rather than submoduled
because the fork carries fixes not yet upstream.

To resync: `cp <libretro-super>/dist/info/*.info RetroXR/libretro-core-info/`.
That is a mirror, not a merge — a file only the old submodule had is not
restored by it. Two such files were dropped at the switch: `boom3_xp` (deleted
upstream) and `radio` (`internet_radio`, which SystemFilter hides anyway).
