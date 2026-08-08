## PS1Card — the PlayStation memory card image format (raw 128 KB .mcr).
##
## A card is 16 blocks of 8192 bytes. Block 0 is the directory; blocks 1-15 hold
## one save file each, chained through the directory's next-block links. Every
## PS1 core reads this same raw layout, which is why a card belongs to the
## console rather than to whichever core is currently running it.
##
## The blank produced here is byte-exact with the card pcsx_rearmed formats for
## itself (md5 d8f29ffd55cb1e4f77987a1e07472d66), verified by having the core
## create one and diffing. It deliberately does NOT match the layout most
## references describe — there is no 0xFF filler in frames 56-62 and no
## write-test frame at 63. Trust the measurement, not the reference.
##
## A new card must arrive formatted: RetroXR never boots the PS1 BIOS, so the
## player has no way to format one themselves.
class_name PS1Card
extends RefCounted

const FRAME_SIZE  := 128
const BLOCK_SIZE  := 8192
const BLOCK_COUNT := 16
const CARD_SIZE   := BLOCK_SIZE * BLOCK_COUNT   # 131072

## Directory entry states (byte 0 of frames 1-15).
const STATE_FIRST   := 0x51   ## in use, first block of a file
const STATE_MIDDLE  := 0x52   ## in use, middle of a chain
const STATE_LAST    := 0x53   ## in use, last block of a chain
const STATE_FREE    := 0xA0   ## free (formatted)

const LINK_NONE := 0xFFFF     ## next-block value meaning "end of chain"


## A freshly formatted, empty card.
static func blank_image() -> PackedByteArray:
	var img := PackedByteArray()
	img.resize(CARD_SIZE)
	img.fill(0)

	# Frame 0 — header: "MC" plus the XOR checksum of bytes 0..126 (0x4D ^ 0x43).
	img[0] = 0x4D
	img[1] = 0x43
	img[FRAME_SIZE - 1] = 0x0E

	# Frames 1-15 — directory, every entry free and terminating its own chain.
	for f in range(1, 16):
		var base := f * FRAME_SIZE
		img[base] = STATE_FREE
		img[base + 8] = 0xFF
		img[base + 9] = 0xFF
		img[base + FRAME_SIZE - 1] = STATE_FREE

	# Frames 16-35 — broken-sector list, all entries marked unused.
	for f in range(16, 36):
		var base := f * FRAME_SIZE
		for i in range(4):
			img[base + i] = 0xFF
		img[base + 8] = 0xFF
		img[base + 9] = 0xFF

	# Frames 36-63 and blocks 1-15 stay zero.
	return img


## True when `data` looks like a PS1 card image (right size, "MC" magic).
static func is_card_image(data: PackedByteArray) -> bool:
	return data.size() == CARD_SIZE and data[0] == 0x4D and data[1] == 0x43


## XOR checksum of a frame's bytes 0..126, which is what byte 127 must equal.
static func frame_checksum(data: PackedByteArray, frame_offset: int) -> int:
	var sum := 0
	for i in range(FRAME_SIZE - 1):
		sum ^= data[frame_offset + i]
	return sum


# --- Reading the saves on a card ---------------------------------------------

## Every save file on the card, newest-block-order, one entry per save:
##   name    String   PS1 filename, e.g. "BASLUS-00972AC3NA"
##   serial  String   the game's product code pulled out of it, "SLUS-00972"
##   title   String   the save's own title, decoded from Shift-JIS
##   blocks  int      how many of the 15 blocks it occupies
##   block   int      its first block index (1-15)
##   icons   Array    Image, one per animation frame (1-3)
##
## Link blocks (0x52/0x53) are skipped: they belong to the file that starts at
## the 0x51 entry, and listing them would show one save several times.
static func list_saves(data: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not is_card_image(data):
		return out
	for i in range(1, BLOCK_COUNT):
		var e := i * FRAME_SIZE
		if data[e] != STATE_FIRST:
			continue
		var raw := data.slice(e + 10, e + 31)
		var name := _ascii_until_nul(raw)
		var size := data.decode_u32(e + 4)
		var blk := i * BLOCK_SIZE
		out.append({
			"name": name,
			"serial": _serial_of(name),
			"title": _decode_title(data.slice(blk + 4, blk + 68)),
			"blocks": maxi(1, size / BLOCK_SIZE),
			"block": i,
			"icons": _icons(data, blk),
		})
	return out


## How many of the 15 save blocks are still free.
static func free_blocks(data: PackedByteArray) -> int:
	if not is_card_image(data):
		return 0
	var n := 0
	for i in range(1, BLOCK_COUNT):
		if data[i * FRAME_SIZE] >= STATE_FREE:
			n += 1
	return n


static func _ascii_until_nul(raw: PackedByteArray) -> String:
	var s := ""
	for b in raw:
		if b == 0:
			break
		s += char(b)
	return s


## "BASLUS-00972AC3NA" -> "SLUS-00972". The leading letter is the card region
## marker and the next is the game's region; the product code follows.
static func _serial_of(name: String) -> String:
	if name.length() < 12:
		return ""
	return name.substr(2, 10)


## Decode a save's title frame. PS1 titles are Shift-JIS and almost always use
## the FULL-WIDTH forms, so reading the bytes as ASCII yields mojibake — the
## full-width blocks are contiguous, which covers every Western title. Anything
## outside them (real kana or kanji) has no ASCII equivalent and is dropped
## rather than guessed; the filename is always there as a fallback.
static func _decode_title(raw: PackedByteArray) -> String:
	const PUNCT := {
		0x8140: " ", 0x8141: ",", 0x8142: ".", 0x8143: ",", 0x8144: ".",
		0x8146: ":", 0x8147: ";", 0x8148: "?", 0x8149: "!", 0x814F: "^",
		0x8151: "_", 0x815B: "-", 0x815C: "-", 0x815D: "-", 0x815E: "/",
		0x815F: "\\", 0x8160: "~", 0x8162: "|", 0x8165: "'", 0x8166: "'",
		0x8167: "\"", 0x8168: "\"", 0x8169: "(", 0x816A: ")", 0x816D: "[",
		0x816E: "]", 0x816F: "{", 0x8170: "}", 0x817B: "+", 0x817C: "-",
		0x8181: "=", 0x8183: "<", 0x8184: ">", 0x8190: "$", 0x8193: "%",
		0x8194: "#", 0x8195: "&", 0x8196: "*", 0x8197: "@",
	}
	var s := ""
	var i := 0
	while i < raw.size():
		var b := raw[i]
		if b == 0:
			break
		# Some games just write plain ASCII.
		if b < 0x80:
			s += char(b)
			i += 1
			continue
		if i + 1 >= raw.size():
			break
		var w := (b << 8) | raw[i + 1]
		i += 2
		if w >= 0x824F and w <= 0x8258:
			s += char(0x30 + (w - 0x824F))        # full-width 0-9
		elif w >= 0x8260 and w <= 0x8279:
			s += char(0x41 + (w - 0x8260))        # full-width A-Z
		elif w >= 0x8281 and w <= 0x829A:
			s += char(0x61 + (w - 0x8281))        # full-width a-z
		elif PUNCT.has(w):
			s += str(PUNCT[w])
	return s.strip_edges()


## The save's animation frames as 16x16 RGBA images (1-3 of them).
##
## 4 bpp indices into a 16-colour CLUT of little-endian BGR555. Two pixels per
## byte, LOW nibble first — get that backwards and the icon comes out mirrored
## in pairs. Colour 0x0000 with the semi-transparency bit clear is transparent,
## which is how icons get their cut-out background.
static func _icons(data: PackedByteArray, blk: int) -> Array:
	var frames: int = clampi(data[blk + 2] & 0x0F, 1, 3)
	var pal := PackedColorArray()
	for c in range(16):
		var v := data.decode_u16(blk + 96 + c * 2)
		var a := 0.0 if (v & 0x7FFF) == 0 and (v & 0x8000) == 0 else 1.0
		pal.append(Color(
			float((v & 0x1F) << 3) / 255.0,
			float(((v >> 5) & 0x1F) << 3) / 255.0,
			float(((v >> 10) & 0x1F) << 3) / 255.0,
			a))
	var out: Array = []
	for f in range(frames):
		var src := blk + FRAME_SIZE + f * FRAME_SIZE
		var px := PackedByteArray()
		px.resize(16 * 16 * 4)
		for i in range(16 * 16):
			var byte := data[src + i / 2]
			var idx := (byte & 0x0F) if i % 2 == 0 else (byte >> 4)
			var col: Color = pal[idx]
			px[i * 4]     = int(col.r * 255.0)
			px[i * 4 + 1] = int(col.g * 255.0)
			px[i * 4 + 2] = int(col.b * 255.0)
			px[i * 4 + 3] = int(col.a * 255.0)
		out.append(Image.create_from_data(16, 16, false, Image.FORMAT_RGBA8, px))
	return out
