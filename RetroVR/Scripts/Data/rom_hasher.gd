## RomHasher — computes MD5 + SHA1 checksums for ROM files (one file pass).
##
## ScreenScraper's jeuInfos.php accepts crc, md5 and sha1 as ALTERNATIVE rom
## identifiers — any single one is enough for a match. We send md5 + sha1:
## both use Godot's native HashingContext (mbedTLS), so hashing is disk-I/O
## bound. CRC32 was dropped deliberately — Godot has no native CRC and the
## per-byte GDScript loop made hashing take orders of magnitude longer than
## the two native hashes combined.
class_name RomHasher
extends RefCounted


## Compute checksums for a ROM file.
## Returns {md5: String, sha1: String, size: int} with uppercase hex strings.
## Returns empty dict on failure.
static func compute_checksums(rom_path: String) -> Dictionary:
	print("[RomHasher] Computing checksums: ", rom_path)
	var file := FileAccess.open(rom_path, FileAccess.READ)
	if not file:
		push_error("[RomHasher] Failed to open: %s" % rom_path)
		return {}

	var file_size := file.get_length()
	print("[RomHasher] File size: %d bytes" % file_size)

	var md5_ctx := HashingContext.new()
	var sha1_ctx := HashingContext.new()
	md5_ctx.start(HashingContext.HASH_MD5)
	sha1_ctx.start(HashingContext.HASH_SHA1)

	const CHUNK_SIZE := 4194304  # 4 MB

	while file.get_position() < file_size:
		var remaining := file_size - file.get_position()
		var read_size: int = mini(remaining, CHUNK_SIZE)
		var chunk := file.get_buffer(read_size)
		if chunk.is_empty():
			break
		md5_ctx.update(chunk)
		sha1_ctx.update(chunk)

	var md5_bytes := md5_ctx.finish()
	var sha1_bytes := sha1_ctx.finish()

	var result := {
		"md5": md5_bytes.hex_encode().to_upper(),
		"sha1": sha1_bytes.hex_encode().to_upper(),
		"size": file_size,
	}
	print("[RomHasher] Done — MD5=%s SHA1=%s" % [result["md5"], result["sha1"]])
	return result
