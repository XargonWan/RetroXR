# RetroVR What’s Left

## ROM Scraper

This shall scraper the ROM data by reading a checksum of the ROM. With this checksum it shall talk to screenscraper.fr which will return all the data back in a json. Examine how skyscraper does it with screen scraper fr and port that to godot. Examine how it is read within this repo here https://github.com/XenuIsWatching/skyscraper/blob/emulationstation2/src/screenscraper.cpp or locally in here `C:\Users\user\skyscraper`.
An example of what the json can return is found in the file `banjo-kazooie-screenscraper-fr.json`.

The only relevant data [metadata] we are interested are these (some may be in french from the API documents (why they don’t write in English… idk … french people >:( ):

These shall be contained a gamelist.json contained in a rom directory, each system shall have it’s own json. ex. ( roms/nintendo_64/gamelists.json ; roms/super_nintendo/gamelists.json ; etc.)

[Game Level Info]
Game Name
Description
Developer
Publisher
Genre

[Rom Level info]
Rom Release Date
Rom Region

The media we are interested in scraper are these:

These shall be stored in a media/ directory at the rom system level. ex. ( roms/nintendo_64/media/ ; roms/super_nintendo/media ; etc.)
Each of the images shall be in a subfolder within media ex ( media/wheel/ ; media/box/ ; etc. )


wheel (image)
Box Texture (TODO: this box texture only contains 1 spine (the bottom), A BOX HAS 3 OTHER SPINES FIGURE OUT WHERE THEY COME FROM (2 sides and top)
Manual (pdf)
Support Texture (Label) (not the support 2d texture)

if the scraper server doesn’t return a image, then well… there is none. There can sometimes be region specific data for labels such as usa labels or japan labels, it shall store that data with the ROM json level.

Can be seen here in a webpage format: https://www.screenscraper.fr/gameinfos.php?gameid=5405&action=onglet&zone=gameinfosmedias

The game name, release data, rom region, shall be stored in a json (no xml like Emulation Station). An example of how this looks is in the found in the file `gamelists-example.json`. Note that there may extra fields in this example which are not to be in the output json!
It is important to also keep the path to the rom in there.

When scraping a ROM individually, and i gets back a USA rom, and there isn’t an entry for that game, then it shall create it. when scraping a Japan rom, and there is already an entry for that GAME with an existing USA ROM, thenit shall add the ROM metadata to the GAME entry json.

### UI

In the game lists, there shall be a button to the right (use a scissor emoji icon), this shall start the scraping of the rom file. When it is done scraping it shall open up a 'pop'up menu to the right, which shall list the metadata and media it found and give the user the option to 'accept' or 'close' it. Accepting, writes the metadata to the json and downloads the images. For listing metadata and iamges, it shall write all the text metadata (Game name, publisher, rom region, etc.), and for media images, it shall just show a 'checkbox' emoji if it has it and a 'X' emoji if it does not. ex:   wheel [checkbox emoji]  ... or ... whell [X emoji].
It shall also display a rom region as well of which matches the checksum

## Game Metadata Viewer

In the Rom Spawn Menu, it currently just lists the text file name of each ROM in a system. If there is no gamelist json for it (which means it hasn’t been scraped before), then it shall just display the text for the game as it did before.
If there is, then it shall display the wheel in the list which it is in from the game list of the preferred ROM which shall take place of the text.
Currently there is a ‘book’ icon which opens the manual. To the right of that shall be a cartridge icon, which will open up a side menu to the right which will display the metadata of the game [Description, Publisher, developer, genre], this side menu shall also have another button if the number of roms is greater than 1 which will then over up another side menu to the right of the already side menu which will give another list of the roms. This rom list shall be similar to the game list where it display the wheel of the rom in a list format along with the manual spawn button to the right, there shall also be an ‘star’ icon to the left of the game name (wheel) which shall set the preferred (default) rom. The preferred (default) rom is the rom selected by default in the game list.

## Cartriges

If the game has already been scraped then when can spawn a bit extra, otherwise it just spawns the cartridge model for that system with 'text' of the file name in front of it (as it already has)

### Box

Some system games came in boxes along with a cartridge. This box shall use the Box texture rendered over the box. This box shall be 'pick-upable' with a controller, while it is being held, the user can 'open', the box, where the cartridge and manual come out of the box (which are already inside of the box). The cartridge shall have the 'label' image rendered over it

Which systems uses a Box and cartridge (this is not exhuastive and may more need to added later)
nes
super_nes
nintendo64

Each system will have a unique box and cartidge model for it. There may be best to use polymorphism in the design.. for easier code reuse
We currenntly do not have a unique model yet. placeholders for now

### CD and JewelCase

Some systems games came in a jewel case along with the CD. The jewel case shall have the box texture rendered over the jewel case.This jewel case shall be 'pick-upable' with a controller, while it is being held, the user can 'open', the jewel case, where the cartridge and manual come out of the jewel case (which are already inside of the box). The disc shall have the 'label' image rendered over it

Which systems uses a Jewelcase and CD (this is not exhuastive and may more need to added later)
Playstation
Gamecube

Each system will have a unique jewel case and disc model for it. There may be best to use polymorphism in the design.. for easier code reuse
We currenntly do not have a unique model yet. placeholders for now
