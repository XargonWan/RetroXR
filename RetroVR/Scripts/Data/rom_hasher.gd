## RomHasher — computes CRC32, MD5, SHA1 checksums for ROM files.
class_name RomHasher
extends RefCounted


## CRC32 lookup table (standard polynomial 0xEDB88320), built once.
static var _crc_table: PackedInt32Array = _build_crc_table()


static func _build_crc_table() -> PackedInt32Array:
	var table := PackedInt32Array()
	table.resize(256)
	for i in 256:
		var crc: int = i
		for _j in 8:
			if crc & 1:
				crc = (crc >> 1) ^ 0xEDB88320
			else:
				crc = crc >> 1
		table[i] = crc
	return table


## Compute all three checksums for a ROM file.
## Returns {crc: String, md5: String, sha1: String, size: int} with uppercase hex strings.
## Returns empty dict on failure.
static func compute_checksums(rom_path: String) -> Dictionary:
	var file := FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		push_error("[RomHasher] Failed to open: %s" % rom_path)
		return {}

	var file_size := file.get_length()

	var md5_ctx := HashingContext.new()
	var sha1_ctx := HashingContext.new()
	md5_ctx.start(HashingContext.HASH_MD5)
	sha1_ctx.start(HashingContext.HASH_SHA1)

	var crc: int = 0xFFFFFFFF
	const CHUNK_SIZE := 1048576  # 1 MB

	while file.get_position() < file_size:
		var remaining := file_size - file.get_position()
		var read_size: int = mini(remaining, CHUNK_SIZE)
		var chunk := file.get_buffer(read_size)
		if chunk.is_empty():
			break
		md5_ctx.update(chunk)
		sha1_ctx.update(chunk)
		for byte_val in chunk:
			crc = _crc_table[(crc ^ byte_val) & 0xFF] ^ (crc >> 8)

	crc = crc ^ 0xFFFFFFFF
	# Mask to 32-bit unsigned
	crc = crc & 0xFFFFFFFF

	var md5_bytes := md5_ctx.finish()
	var sha1_bytes := sha1_ctx.finish()

	return {
		"crc": "%08X" % crc,
		"md5": md5_bytes.hex_encode().to_upper(),
		"sha1": sha1_bytes.hex_encode().to_upper(),
		"size": file_size,
	}
