## SpawnMenuAboutView — the menu's ABOUT tab: author, donate, and the credits.
##
## Several of these are licence obligations rather than courtesies — the CC BY
## models and the Meta XR Audio SDK both require the notice be reproduced
## wherever the work ships — so treat the tables below as something to add to,
## never to prune.
##
## The five credit sections were five copies of "header, rows, note, spacer".
## They are one table and one loop now, so a new section is a row of data.
class_name SpawnMenuAboutView
extends ScrollContainer

## [header, [[title, author, licence], ...], note] — note "" for no note.
const SECTIONS: Array = [
	["OPEN SOURCE LIBRARIES", [
		# Ours now — the 2026-03-07 import has been rewritten and outgrown many
		# times over. The upstream it started from is credited in the note below,
		# which is where the MIT obligation is discharged.
		["libretro-godot",    "XenuIsWatching", "MIT"],
		["pdfium",            "The Chromium Authors", "BSD 3-Clause"],
		["godot-xr-tools",   "Bastiaan Olij",   "MIT"],
		["godot-cpp",        "Godot Engine contributors", "MIT"],
		["SDL3",             "Sam Lantinga / SDL contributors", "zlib"],
		["libretro-common",  "libretro team",   "MIT"],
		["ReaderWriterQueue","Cameron Desrochers","BSD"],
		["libVLC",           "VideoLAN",        "LGPL v2.1"],
		["Nerd Fonts",       "Ryan L McIntyre", "MIT"],
		["RomM",             "RomM contributors", "AGPL v3"],
	], "libretro-godot began as a fork of SK.Libretro.Godot by SKurdt (MIT)."],

	# Deliberately not folded into the list above: the Meta XR Audio SDK is not
	# open source, and its licence requires the copyright notice be reproduced
	# wherever the library ships.
	["THIRD-PARTY SDKS", [
		["Meta XR Audio SDK", "Meta Platforms, Inc.", "Oculus SDK License"],
	], "Spatial audio on Quest is HRTF-rendered by the Meta XR Audio SDK, "
		+ "which places each sound in three dimensions rather than simply panning it "
		+ "left and right. Where the SDK is unavailable the room falls back to Godot's "
		+ "built-in 3D audio."],

	["ARTWORK", [
		["Systematic icon set", "BAXY Square — github.com/baxysquare", "MIT"],
		["Input Prompts", "Kenney — kenney.nl", "CC0 1.0"],
		["Touch controller model", "immersive-web/webxr-input-profiles", "MIT"],
		["Lamp chain switch (audio)", "ftpalad — freesound.org", "CC0 1.0"],
	], "Console art from the Systematic theme for RetroArch / Lakka. "
		+ "Controller line art is rendered from the WebXR input profile model; "
		+ "button glyphs are Kenney's Input Prompts."],

	["GAME DATA", [
		["ScreenScraper", "screenscraper.fr contributors", "CC BY-NC-SA 4.0"],
	], "Box art, screenshots and game details are scraped from screenscraper.fr."],

	# The CC BY entries are the reason this section exists: attribution is a
	# licence condition for them. The CC0 ones are credited anyway.
	["3D MODELS", [
		["Bedroom furniture", "General of Thailand — @Melonpolygons", "CC BY 4.0"],
		["Bookcases with books", "Matthew Collings — @mtcollings", "CC BY 4.0"],
		["Ceiling fan", "lucaboechat", "CC BY 4.0"],
		["Corner TV stand", "Manix3D — @manix3d", "CC BY 4.0"],
		["CRT computer monitor", "fizyman", "CC BY 4.0"],
		["Desk chair", "Slava Izvekov — @guantanamera", "CC BY 4.0"],
		["Interior door and trim", "Roman — @janwama", "CC BY 4.0"],
		["Light switch", "BillieBones", "CC BY 4.0"],
		["Nightstand", "ilyafom1", "CC BY 4.0"],
		["Trash can", "Yury Misiyuk — @Tim0", "CC BY 4.0"],
		["Table lamp", "plaggy", "CC0 1.0"],
		["Television 02", "Benny Weimer — Poly Haven", "CC0 1.0"],
		["Throw pillows", "Serhii Khromov — Poly Haven", "CC0 1.0"],
		["Potted plant", "James Ray Cock — Poly Haven", "CC0 1.0"],
		["Suburban houses", "Kenney — kenney.nl", "CC0 1.0"],
		["Trees", "Quaternius", "CC0 1.0"],
		["Furniture Kit", "Kenney — kenney.nl", "CC0 1.0"],
		["Surfaces", "ambientCG", "CC0 1.0"],
	], "Room and prop models. CC BY entries require attribution; "
		+ "wall and floor surfaces are ambientCG photogrammetry."],
]

## The GitHub Pages redirect, not the payment processor itself. This string ships
## inside the APK, so pointing it straight at Ko-fi would cost a release every
## time the processor changed.
const DONATE_URL := "https://xenuiswatching.github.io/retroXR/donate/"


static func create() -> SpawnMenuAboutView:
	var v := SpawnMenuAboutView.new()
	v._build()
	return v


func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := MenuStyle.vbox(14)
	add_child(vbox)
	vbox.add_child(MenuStyle.spacer(16))

	# Author credit
	var author_lbl := MenuStyle.label("Ryan McClelland", 32, MenuStyle.COLOR_TITLE)
	author_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(author_lbl)

	var role_lbl := MenuStyle.label("Author", 18, MenuStyle.COLOR_LICENSE)
	role_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(role_lbl)

	vbox.add_child(MenuStyle.spacer(8))

	var donate_btn := Button.new()
	donate_btn.text = "  ❤  DONATE  "
	donate_btn.custom_minimum_size = Vector2(0, 64)
	donate_btn.add_theme_font_size_override("font_size", 24)
	var donate_style := MenuStyle.rounded(MenuStyle.COLOR_BTN_DL, 8)
	for state in ["normal", "hover", "pressed"]:
		donate_btn.add_theme_stylebox_override(state, donate_style)
	donate_btn.pressed.connect(func(): OS.shell_open(DONATE_URL))
	vbox.add_child(donate_btn)

	vbox.add_child(HSeparator.new())

	for i in SECTIONS.size():
		var section: Array = SECTIONS[i]
		vbox.add_child(MenuStyle.header(section[0] as String, 20))
		for entry: Array in section[1] as Array:
			_add_credit_row(vbox, entry[0] as String, entry[1] as String, entry[2] as String)
		var note: String = section[2]
		if not note.is_empty():
			var note_lbl := MenuStyle.label(note, 14, MenuStyle.COLOR_LICENSE)
			note_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			vbox.add_child(note_lbl)
		vbox.add_child(MenuStyle.spacer(12 if i == SECTIONS.size() - 1 else 6))


## One credit line: title over author on the left, licence on the right.
func _add_credit_row(vbox: VBoxContainer, title: String, author: String, license: String) -> void:
	var row := MenuStyle.hbox(8)
	row.custom_minimum_size = Vector2(0, 52)
	vbox.add_child(row)

	var left := MenuStyle.vbox(2)
	row.add_child(left)
	left.add_child(MenuStyle.label(title, 18, MenuStyle.COLOR_TITLE))
	left.add_child(MenuStyle.label(author, 14, MenuStyle.COLOR_LICENSE))

	var lic_lbl := MenuStyle.label(license, 16, MenuStyle.COLOR_DESC)
	lic_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lic_lbl)

	# The scroll bar is drawn over the content, so the licence needs a gutter or
	# a long one ("CC BY-NC-SA 4.0") loses its last character behind it.
	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(18, 0)
	row.add_child(gutter)

	vbox.add_child(HSeparator.new())
