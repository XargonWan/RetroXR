# Core Downloader

## Core info

info about each core can be found at the path libretro-core-info. this is a git submodule

You'll need to gather all the information for each each in there in to some data structure.

## Download URL

The files can be downloaded here, you'll need to some how read over http and get all the dll.zip files that can be downloaded. It should match a name of what is found in core info. There could be some that don't exist in the core info but could still be in the url.

Windows can be found here: https://buildbot.libretro.com/nightly/windows/x86_64/latest/

## User interface

There shall be a GUI which is also under the spawn menu. but there shall but another ribbon on top called "Cores" which the user can click on (and "Spawn" shall be added as well which will contain what was already implemented). This shall be under the "Cores" in another ribbon called "Download" There shall be a field at the top of this submenu which gives the libretro/core path of where cores are downloaded. By default this shall be the user directory and in a folder call %USERPROFILE%/retrovr/libretro/cores on Windows (it should create this path if it does not exist).

This "Cores" menu shall contain a scrollable list of all the cores found at the url. This scrollable list shall display the "display_name" of each downloadable core and below which wil display the "systemname" and "license" and the "description. If there is no matching core-info, the file name it saw on the url with "CORE UNKNOWN" under it. It also should have a Download button displayed at the to the right of "displayname" which the user clicks and it will download the zip file, and then unzip it in place, and then delete the zip file. While it is download this button shall transform and say "BUSY" along with a progress bar under it. If the expected file already exist. Then it shall say "Re-Download". If the file at the URL is newer than the file it already has downloaded then it shall say "UPDATE".

It shall appear like this in the scrollabe list

"display name" [clickable download button] (in larger font) 
"license" (in smaller font than displayname)
"description" (in smaller font than "license")

It might be useful to create a json in the core paths that can be loaded to know which cores are already download and when they were downloaded so there is persitences.

# Core Manager

With downloaded cores, it should be possible to select default cores for each 'systemid' (ex. nintendo_64, super_nes, nes, game_boy, etc.) As each of these systemids shall correspond with a spawnable 'system', There shall be another ribbon called "Manager".

This shall contain a dropdown of which core to select as the default for a system. For example, super_nes could have bsnes or higan if the user has those cores downloaded. It shall use the systemname field for display here as that is more human readable than the systemid.

It shouldn't be expected to have 'hard-coded' expectiations for systemid. The code shall load from what is already downloaded for what to display. For example, if the user has only downloaded super_nes systemid cores, then it shouldn't display options for nes, game_boy or others. It should dynamically read what's possible from the *.info files.

The may have to be some data strcuture created so the cores can be known.

# Spawnable Systems

It shall use the systemname field to determine which systems can be spawned, if the user super_nes cores download... then the user can spawn that system which will come loaded with the default core as it's system. If the user changes the default core, while a system has already be spawnned, then those systems should rather be looking at that "option" of which core they are to load when they are started.