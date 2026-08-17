## RomM self-tests — the pure-logic half of the RomM stack, run headless with no
## server, no headset and no network.
##
## This project has no test framework and does not want one; what it has is
## probe scenes. This is a probe that asserts instead of printing, and it is the
## one probe worth keeping in the tree: every case below is a bug that actually
## shipped, so the file doubles as the regression record.
##
##     "$godot" --headless --path RetroXR res://Tests/romm_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## What is NOT covered, and why: anything that needs a live RomM server
## (sync paging, the delta watermark, download resume) and anything welded to
## the menu's Control tree (_rebuild_romm_rows, which is the merge this most
## wants to test — it reads a dozen view members and cannot be called without a
## built view). Extracting that merge into a pure function is the next step.
extends Node

const TEST_SYSTEM := "__romm_selftest"

var _pass := 0
var _fail := 0


func _ready() -> void:
	# A probe must never hang a headless run. The HTTP cases each cap their own
	# wait as well, because this timer is a SceneTree timer: it only fires while
	# the main loop is running, and a blocking call made ON the main thread would
	# stop the very clock meant to catch it.
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))

	_test_pair_url()
	_test_systemid_for()
	_test_partition()
	_test_collapse_by_systemid()
	_test_firmware_index()
	_test_stats_unchanged()
	_test_verify_transfer()
	_test_cache_paths()
	_test_scan_roms()
	_test_gamelist_removal()
	_test_media_and_cleanup()
	_test_cleanup_gate()
	_test_cleanup_core_dirs()
	_test_cleanup_folder_as_file()
	_test_gamelist_bad_paths()
	_test_core_uninstall()
	_test_backup_switch()
	await _test_http_stalls()

	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


## Indexing an array that came out shorter than expected is a hard error, which
## aborts the rest of the case function — so one broken assumption takes its
## neighbours' results with it and the run reports fewer cases, not failures.
func _at(arr: Array, i: int) -> Dictionary:
	return arr[i] as Dictionary if i >= 0 and i < arr.size() else {}


# ---------------------------------------------------------------------------
# RommPairUrl — the QR payload parser.
# ---------------------------------------------------------------------------

func _test_pair_url() -> void:
	var scheme := RommPairUrl.parse("http://192.168.0.106:8080/pair?code=MXWT-SDZE")
	_eq("pair/scheme url", scheme["url"], "http://192.168.0.106:8080")
	_eq("pair/scheme code", scheme["code"], "MXWT-SDZE")

	# The QR frequently omits the scheme; both forms must land identically.
	var bare := RommPairUrl.parse("192.168.0.106:8080/pair?code=MXWT-SDZE")
	_eq("pair/schemeless url", bare["url"], "http://192.168.0.106:8080")
	_eq("pair/schemeless code", bare["code"], "MXWT-SDZE")

	# A bare code pairs against the configured server.
	var only := RommPairUrl.parse("MXWT-SDZE")
	_eq("pair/bare code url", only["url"], "")
	_eq("pair/bare code code", only["code"], "MXWT-SDZE")

	# Shaped like a URL but carrying no host: treating this as a bare code would
	# pair against whatever server happened to be configured and hide the
	# malformed QR behind an unrelated failure.
	var hostless := RommPairUrl.parse("/pair?code=MXWT-SDZE")
	_eq("pair/hostless rejected", hostless["code"], "")

	_eq("pair/not a romm qr", RommPairUrl.parse("https://example.com/hello")["code"], "")
	_eq("pair/empty", RommPairUrl.parse("")["code"], "")
	_eq("pair/whitespace only", RommPairUrl.parse("   ")["code"], "")

	# Percent-encoding must decode, and decoding must not smuggle in a code the
	# pattern would have rejected.
	_eq("pair/uri decoded", RommPairUrl.parse("http://h:8080/pair?code=AB%2DCD")["code"], "AB-CD")
	_eq("pair/decode cannot widen",
		RommPairUrl.parse("http://h:8080/pair?code=AB%2FCD")["code"], "")

	# Fragments and extra query params.
	_eq("pair/extra query", RommPairUrl.parse("http://h:8080/pair?x=1&code=ABCD")["code"], "ABCD")

	var over := "A".repeat(RommPairUrl.MAX_CODE_LEN + 1)
	_eq("pair/over-long code", RommPairUrl.parse("http://h:8080/pair?code=" + over)["code"], "")


# ---------------------------------------------------------------------------
# RommPlatforms — slug mapping.
# ---------------------------------------------------------------------------

func _test_systemid_for() -> void:
	_eq("slug/plain n64",
		RommPlatforms.systemid_for({"slug": "n64", "fs_slug": "n64"}), "nintendo_64")

	# The one that shipped wrong: 64DD is its own system, not N64.
	_eq("slug/64dd is not n64",
		RommPlatforms.systemid_for({"slug": "64dd", "fs_slug": "n64dd"}), "nintendo_64dd")

	# fs_slug beats slug — it is the folder the user named themselves.
	_eq("slug/fs_slug wins",
		RommPlatforms.systemid_for({"slug": "unknown-thing", "fs_slug": "snes"}), "super_nes")

	# An explicit override beats both, by either key.
	_eq("slug/override by slug",
		RommPlatforms.systemid_for({"slug": "weird", "fs_slug": "alsoweird"}, {"weird": "nes"}),
		"nes")

	_eq("slug/unmappable", RommPlatforms.systemid_for({"slug": "nonesuch", "fs_slug": "nope"}), "")

	# JSON nulls arrive from RomM for absent fields; str(null) must not map.
	_eq("slug/null fields", RommPlatforms.systemid_for({"slug": null, "fs_slug": null}), "")


func _test_partition() -> void:
	var part := RommPlatforms.partition([
		{"slug": "nes", "fs_slug": "nes", "rom_count": 12},
		{"slug": "nonesuch", "fs_slug": "nope", "rom_count": 5},
		{"slug": "snes", "fs_slug": "snes", "rom_count": 0},      # empty, dropped
		{"slug": "gb", "fs_slug": "gb", "rom_count": null},        # null, dropped
	])
	_eq("partition/mapped", part["mapped"].size(), 1)
	_eq("partition/unmapped", part["unmapped"].size(), 1)
	_eq("partition/systemid stamped", str((part["mapped"][0] as Dictionary)["systemid"]), "nes")


func _test_collapse_by_systemid() -> void:
	# snes/sfc/sgb all map to super_nes. Before the fix the dict build kept
	# whichever came last, so the winner depended on the server's array order.
	var a := {"slug": "snes", "systemid": "super_nes", "rom_count": 3512}
	var b := {"slug": "sgb", "systemid": "super_nes", "rom_count": 42}

	var forward := RommPlatforms.collapse_by_systemid([a, b])
	var reverse := RommPlatforms.collapse_by_systemid([b, a])

	_eq("collapse/one tile per systemid", (forward["platforms"] as Dictionary).size(), 1)
	_eq("collapse/biggest wins",
		str(((forward["platforms"] as Dictionary)["super_nes"] as Dictionary)["slug"]), "snes")
	_eq("collapse/order independent",
		str(((reverse["platforms"] as Dictionary)["super_nes"] as Dictionary)["slug"]), "snes")

	# The loser is reported, not dropped on the floor.
	_eq("collapse/loser reported", (forward["shadowed"] as Array).size(), 1)
	_eq("collapse/loser identity",
		str(((forward["shadowed"] as Array)[0] as Dictionary)["slug"]), "sgb")
	_eq("collapse/loser reported either order", (reverse["shadowed"] as Array).size(), 1)

	# Distinct systemids never contend.
	var many := RommPlatforms.collapse_by_systemid([
		{"slug": "nes", "systemid": "nes", "rom_count": 1},
		{"slug": "gb", "systemid": "game_boy", "rom_count": 1},
	])
	_eq("collapse/distinct kept", (many["platforms"] as Dictionary).size(), 2)
	_eq("collapse/no false shadow", (many["shadowed"] as Array).size(), 0)


# ---------------------------------------------------------------------------
# RommFirmware — the two indexes over the server's firmware list.
#
# The PS2 BIOS shipped invisible: both PS2 cores declare a FOLDER ("pcsx2/bios")
# rather than a filename, so the by-name join had nothing to match and 68 files
# sitting on the server were never offered. The platform index is the fix, and
# `file_path` — which the indexer used to discard — is the only key it has.
# ---------------------------------------------------------------------------

func _test_firmware_index() -> void:
	_eq("fw/slug from path", RommFirmware.platform_slug_from_path("bios/ps2"), "ps2")
	_eq("fw/slug trailing slash", RommFirmware.platform_slug_from_path("bios/ps2/"), "ps2")
	_eq("fw/slug backslashes", RommFirmware.platform_slug_from_path("bios\\ps2"), "ps2")
	_eq("fw/slug cased", RommFirmware.platform_slug_from_path("bios/PS2"), "ps2")
	# A bare name is not a folder. Reading one as a slug would file every loose
	# firmware under whatever platform its filename happened to resemble.
	_eq("fw/slug needs a folder", RommFirmware.platform_slug_from_path("ps2"), "")
	_eq("fw/slug empty", RommFirmware.platform_slug_from_path(""), "")

	var fw := RommFirmware.new()
	fw.config = RommConfig.new()
	# _index and _loaded are reached into directly: the only public route to them
	# is refresh(), which needs a server.
	fw._index([
		{"id": 7, "file_name": "ps2-0120a-20000902.bin", "file_path": "bios/ps2",
			"file_size_bytes": 4194304, "md5_hash": "8DB2FBBAC7413BF3E7154C1E0715E565"},
		{"id": 3, "file_name": "ps2-0100j-20000117.bin", "file_path": "bios/ps2",
			"file_size_bytes": 4194304, "md5_hash": "acf4730ceb38ac9d8c7d8e21f2614600"},
		{"id": 9, "file_name": "scph5500.bin", "file_path": "bios/psx",
			"file_size_bytes": 524288, "md5_hash": ""},
		# On the server's books but not on its disk — offering it would 404.
		{"id": 11, "file_name": "ps2-0101j-20000217.bin", "file_path": "bios/ps2",
			"file_size_bytes": 4194304, "missing_from_fs": true},
		# An unmappable folder must not become its own bucket keyed on "".
		{"id": 12, "file_name": "mystery.rom", "file_path": "bios/nonesuch",
			"file_size_bytes": 1024},
	])
	fw._loaded = true

	var ps2: Array = fw.find_for_system("playstation2")
	_eq("fw/platform index size", ps2.size(), 2)
	_eq("fw/name sorted", str(_at(ps2, 0).get("file_name", "")), "ps2-0100j-20000117.bin")
	_eq("fw/other platform", fw.find_for_system("playstation").size(), 1)
	_eq("fw/unmapped is not a bucket", fw.find_for_system("").size(), 0)
	_eq("fw/no such system", fw.find_for_system("gamecube").size(), 0)

	# The by-name index still works, and now carries the system with it.
	var hit := fw.find("scph5500.bin")
	_eq("fw/by name id", int(hit.get("id", 0)), 9)
	_eq("fw/by name stamps systemid", str(hit.get("systemid", "")), "playstation")
	# Declared nested and stored flat, cased differently — the shipped case.
	_eq("fw/by name is basename+caseless",
		int(fw.find("Machines/PS2-0120A-20000902.BIN").get("id", 0)), 7)

	# md5 is compared against FileAccess.get_md5, which is lowercase.
	_eq("fw/md5 lowercased", str(_at(ps2, 1).get("md5", "")),
		"8db2fbbac7413bf3e7154c1e0715e565")

	# A missing file is absent from BOTH indexes, not just the one it was
	# filtered out of.
	_eq("fw/missing from fs excluded by name",
		fw.find("ps2-0101j-20000217.bin").is_empty(), true)

	# Re-listing replaces; a server that lost a file must not keep serving it out
	# of a stale platform bucket.
	fw._index([
		{"id": 3, "file_name": "ps2-0100j-20000117.bin", "file_path": "bios/ps2",
			"file_size_bytes": 4194304},
	])
	_eq("fw/reindex replaces", fw.find_for_system("playstation2").size(), 1)
	_eq("fw/reindex clears other platforms", fw.find_for_system("playstation").size(), 0)

	fw.free()


# ---------------------------------------------------------------------------
# RommConfig — the "did the library move?" fingerprint.
# ---------------------------------------------------------------------------

func _test_stats_unchanged() -> void:
	var cfg := RommConfig.new()
	var stats := {"ROMS": 171148, "PLATFORMS": 54, "TOTAL_FILESIZE_BYTES": 13522092343348}

	# No baseline means "assume it moved" — never skip the first sync.
	cfg.last_stats = {}
	_ok("stats/no baseline is changed", not cfg.stats_unchanged(stats))

	cfg.last_stats = stats.duplicate()
	_ok("stats/identical is unchanged", cfg.stats_unchanged(stats))

	# An empty reading is not evidence of sameness.
	_ok("stats/empty reading is changed", not cfg.stats_unchanged({}))

	for key: String in ["ROMS", "PLATFORMS", "TOTAL_FILESIZE_BYTES"]:
		var moved := stats.duplicate()
		moved[key] = int(moved[key]) + 1
		_ok("stats/%s move is seen" % key, not cfg.stats_unchanged(moved))


# ---------------------------------------------------------------------------
# RommDownloader.verify_transfer — is what landed on disk the whole body?
#
# The shipped bug: this compared the .part against the catalog's fs_size_bytes.
# For a "folder as file" ROM the server has no such file to send and streams a
# zip it builds around the members, which is larger than their sum by its own
# headers — so the check could never pass, and a download that genuinely
# finished was deleted and retried three times before going terminal. Reported
# as "downloads to 100%, then fails, for all the retries".
# ---------------------------------------------------------------------------

func _test_verify_transfer() -> void:
	var V: Callable = RommDownloader.verify_transfer

	# A plain, complete file: the response's own length is what it is judged on.
	_eq("verify/exact length ok", V.call(0, 200, 1000, 1000, 1000, false), "")
	# Truncated. HTTPClient cannot distinguish this from a clean finish, so this
	# check is the only thing that catches it.
	_ok("verify/short body caught",
		not V.call(0, 200, 1000, 940, 1000, false).is_empty())

	# THE BUG: a generated zip is bigger than the ROM the catalog describes, and
	# the server sent no length to check it against. It must still pass.
	_eq("verify/streamed zip larger than fs_size_bytes",
		V.call(0, 200, 0, 214223188, 214222438, true), "")
	# And a raw streamed file with no length still falls back to fs_size_bytes.
	_ok("verify/streamed raw file still checked",
		not V.call(0, 200, 0, 940, 1000, false).is_empty())
	_eq("verify/streamed raw file complete", V.call(0, 200, 0, 1000, 1000, false), "")

	# A served length always wins over fs_size_bytes — a zip whose body length IS
	# known must be judged on it, not on the members' sum.
	_eq("verify/served length beats fs_size_bytes",
		V.call(0, 200, 214223188, 214223188, 214222438, true), "")

	# Resume honoured: 206, and have + served is the whole file.
	_eq("verify/206 resume ok", V.call(400, 206, 600, 1000, 1000, false), "")
	_ok("verify/206 resume short caught",
		not V.call(400, 206, 600, 900, 1000, false).is_empty())

	# Resume IGNORED: 200 with a partial already on disk means the whole body was
	# appended onto it. have + served then equals the corrupt length, so nothing
	# downstream can catch it — this rule is the only guard.
	_ok("verify/range ignored caught", not V.call(400, 200, 1000, 1400, 1000, false).is_empty())
	_eq("verify/range ignored names itself",
		V.call(400, 200, 1000, 1400, 1000, false), "The server did not resume the download")
	# Not a resume, so a 200 is simply the normal case.
	_eq("verify/200 with no partial is fine", V.call(0, 200, 1000, 1000, 1000, false), "")

	# Nothing to check against at all: no served length, no catalog size. Passing
	# is the only option — failing here would block every unsized transfer.
	_eq("verify/no oracle passes", V.call(0, 200, 0, 1234, 0, false), "")

	# A mismatch that rounds to the same words must print exact bytes, or it
	# reports "204 MB of 204 MB" and reads as a broken message rather than a real
	# difference — which is exactly the scale a zip's headers add.
	var near: String = V.call(0, 200, 214222438, 214223188, 0, false)
	_ok("verify/near-miss reports exact bytes", near.contains("214223188")
		and near.contains("214222438"), near)
	# A difference big enough to render differently keeps the readable form.
	var far: String = V.call(0, 200, 3300000000, 1100000000, 0, false)
	_ok("verify/wide miss stays human", far.contains("GB"), far)


# ---------------------------------------------------------------------------
# RommCacheManifest — path handling. A key derived from a server-supplied name
# is the classic traversal hole.
# ---------------------------------------------------------------------------

func _test_cache_paths() -> void:
	var root := RomLibrary.default_roms_root()
	_eq("cache/relative strips the system dir",
		RommCacheManifest.relative_path("nes", root.path_join("nes").path_join("Game.nes")),
		"Game.nes")

	var key := RommCacheManifest.make_key("nes", "Game.nes")
	_ok("cache/key carries the system", key.contains("nes"), key)
	_ok("cache/key is stable", key == RommCacheManifest.make_key("nes", "Game.nes"))
	_ok("cache/key separates systems",
		RommCacheManifest.make_key("nes", "Game.nes")
			!= RommCacheManifest.make_key("snes", "Game.nes"))

	# A traversing name must not resolve outside the system's own folder.
	var escaped := RommCacheManifest.local_path("nes", "../../etc/passwd")
	_ok("cache/no traversal out of the system dir",
		escaped.is_empty() or escaped.begins_with(root.path_join("nes")), escaped)


# ---------------------------------------------------------------------------
# RomLibrary.scan_roms — the disk walk. Uses a scratch system folder under the
# real roms root, because the path is derived from the systemid and cannot be
# pointed elsewhere. Removed at both ends, so a crashed run leaves nothing.
# ---------------------------------------------------------------------------

func _test_scan_roms() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)

	for f: String in [
		"Game.z64",            # plain
		"UPPER.Z64",           # extension case must not matter
		".hidden.z64",         # dotfile, skipped
		"Disc.bin", "Disc.cue",  # .bin hidden by its .cue descriptor
		"Loose.bin",           # .bin with no .cue survives
		"notes.txt",           # filtered out when an extension list is given
	]:
		var h := FileAccess.open(dir_path.path_join(f), FileAccess.WRITE)
		if h:
			h.store_string("x")
			h.close()
	# A ROM one level down must NOT be found: the scan is flat for every system
	# except the folder_content ones.
	DirAccess.make_dir_recursive_absolute(dir_path.path_join("Sub"))
	var sh := FileAccess.open(dir_path.path_join("Sub").path_join("Nested.z64"), FileAccess.WRITE)
	if sh:
		sh.store_string("x")
		sh.close()

	var exts: Array[String] = ["z64", "cue", "bin"]
	var names: Array[String] = []
	for r: Dictionary in RomLibrary.scan_roms(TEST_SYSTEM, exts):
		names.append(str(r["path"]).get_file())

	_ok("scan/finds a plain rom", "Game.z64" in names, str(names))
	_ok("scan/extension case insensitive", "UPPER.Z64" in names, str(names))
	_ok("scan/skips dotfiles", not (".hidden.z64" in names), str(names))
	_ok("scan/cue hides its bin", not ("Disc.bin" in names), str(names))
	_ok("scan/keeps the cue", "Disc.cue" in names, str(names))
	_ok("scan/keeps an unpaired bin", "Loose.bin" in names, str(names))
	_ok("scan/is not recursive", not ("Nested.z64" in names), str(names))

	# Empty list means "no filter" — this is the call the menu actually makes,
	# and it is why gamelist.json once listed itself as a ROM.
	var unfiltered: Array[String] = []
	for r: Dictionary in RomLibrary.scan_roms(TEST_SYSTEM, [] as Array[String]):
		unfiltered.append(str(r["path"]).get_file())
	_ok("scan/empty filter keeps everything", "notes.txt" in unfiltered, str(unfiltered))

	_rm_rf(dir_path)
	_ok("scan/cleaned up", not DirAccess.dir_exists_absolute(dir_path))


# ---------------------------------------------------------------------------
# Deleting a game — what goes with it, and what must not.
#
# Deleting a ROM used to remove the bytes and nothing else: its library row, its
# box art, its manual and its cached cover all stayed forever, because
# GamelistManager had no removal API at all. These cover the removal rules and
# the one boundary that matters — saves are NEVER swept with a game, since a ROM
# can be downloaded again and a save cannot.
#
# Uses the same scratch system folder as the scan cases, removed at both ends.
# ---------------------------------------------------------------------------

func _test_gamelist_removal() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	_touch(dir_path.path_join("Kept.z64"))

	var gl := GamelistManager.new()
	gl.invalidate(TEST_SYSTEM)
	for entry: Array in [["Kept.z64", "keep"], ["Gone.z64", "drop"], ["Also.z64", "drop"]]:
		gl.add_or_merge_rom(TEST_SYSTEM,
			{"game_id": str(entry[1]), "name": str(entry[1])},
			{"path": "./" + str(entry[0]), "romname": str(entry[0])})

	# Absolute or relative, both must resolve to the same row.
	_ok("del/remove by absolute path",
		gl.remove_rom(TEST_SYSTEM, dir_path.path_join("Also.z64")))
	_ok("del/removed row is gone", not gl.known_rom_paths(TEST_SYSTEM).has("./Also.z64"))
	_ok("del/other rows untouched", gl.known_rom_paths(TEST_SYSTEM).has("./Kept.z64"))
	_ok("del/removing twice is not an error", not gl.remove_rom(TEST_SYSTEM, "Also.z64"))
	_ok("del/unknown rom refuses", not gl.remove_rom(TEST_SYSTEM, "Nonesuch.z64"))

	# The "drop" game held two ROMs and one is left, so the game must survive.
	var by_id := {}
	for g: Dictionary in gl.load_gamelist(TEST_SYSTEM).get("games", []):
		by_id[str(g.get("game_id", ""))] = g
	_ok("del/game survives while a rom remains", by_id.has("drop"))
	_eq("del/last rom standing", (by_id["drop"] as Dictionary).get("roms", []).size(), 1)

	# Removing the last one takes the game with it: an entry the library claims
	# and cannot produce is exactly the stale row this exists to stop.
	_ok("del/remove the last rom", gl.remove_rom(TEST_SYSTEM, "Gone.z64"))
	var ids := {}
	for g: Dictionary in gl.load_gamelist(TEST_SYSTEM).get("games", []):
		ids[str(g.get("game_id", ""))] = true
	_ok("del/empty game entry removed", not ids.has("drop"), str(ids.keys()))

	# prune_missing judges by the file, not by the row.
	gl.add_or_merge_rom(TEST_SYSTEM, {"game_id": "ghost", "name": "ghost"},
		{"path": "./Ghost.z64", "romname": "Ghost.z64"})
	var pruned := gl.prune_missing(TEST_SYSTEM)
	_ok("del/prune drops the missing", "./Ghost.z64" in pruned, str(pruned))
	_ok("del/prune keeps what is on disk",
		gl.known_rom_paths(TEST_SYSTEM).has("./Kept.z64"))

	# The preferred flag must not be left on a row that is gone — get_preferred_rom
	# falls back to roms[0], but set_preferred_rom reads the flags, so with none
	# set the answer depends on which reader asks.
	gl.invalidate(TEST_SYSTEM)
	for n: String in ["A.z64", "B.z64"]:
		_touch(dir_path.path_join(n))
		gl.add_or_merge_rom(TEST_SYSTEM, {"game_id": "pref", "name": "pref"},
			{"path": "./" + n, "romname": n})
	_ok("del/remove the preferred copy", gl.remove_rom(TEST_SYSTEM, "A.z64"))
	for g: Dictionary in gl.load_gamelist(TEST_SYSTEM).get("games", []):
		if str(g.get("game_id", "")) == "pref":
			_ok("del/preferred moves to a surviving rom",
				bool(GamelistManager.get_preferred_rom(g).get("preferred", false)))

	_rm_rf(dir_path)


func _test_media_and_cleanup() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	_touch(dir_path.path_join("Live.z64"))

	var media := RomMedia.media_root(TEST_SYSTEM)
	for rel: String in ["box/Live.png", "wheel/Live.jpg", "manual/Live.pdf",
						"box/Dead.png", "label/Dead.png", "romm/4242_s.webp"]:
		DirAccess.make_dir_recursive_absolute(media.path_join(rel).get_base_dir())
		_touch(media.path_join(rel))

	# Art is keyed on the ROM's basename and the extension is whatever the
	# scraper was handed, so a composed path would miss the .jpg every time.
	var live := RomMedia.scraped_for_rom(TEST_SYSTEM, "Live.z64")
	_eq("media/finds every extension for one rom", live.size(), 3)
	_ok("media/matches a rom-relative path",
		RomMedia.scraped_for_rom(TEST_SYSTEM, "./sub/Live.cue").size() == 3)
	_eq("media/unknown rom has none",
		RomMedia.scraped_for_rom(TEST_SYSTEM, "Nothing.z64").size(), 0)

	# The RomM cover is keyed on the server id instead, and the index has to say
	# so or the sweep cannot tell the two schemes apart.
	var index := RomMedia.index(TEST_SYSTEM)
	_eq("media/index keys scraped art by basename",
		str(index.get(media.path_join("box/Live.png"), "")), "Live")
	_eq("media/index keys romm art by id",
		str(index.get(media.path_join("romm/4242_s.webp"), "")), "romm:4242")
	_eq("media/romm art found by id", RomMedia.romm_art_for_id(TEST_SYSTEM, 4242).size(), 1)
	_eq("media/wrong id finds nothing", RomMedia.romm_art_for_id(TEST_SYSTEM, 1).size(), 0)

	# A sweep must spare art whose ROM is still here and take the rest.
	var found := StorageCleanup.scan()
	var orphans := {}
	for p: String in (found.get(StorageCleanup.MEDIA, {}) as Dictionary).get("paths", []):
		orphans[p] = true
	var sample := _sample(orphans)
	_ok("cleanup/keeps art for a rom on disk",
		not orphans.has(media.path_join("box/Live.png")), sample)
	_ok("cleanup/finds art with no rom",
		orphans.has(media.path_join("box/Dead.png")), sample)
	# A cover with no download IS found, but under COVERS — asserted just below.
	# What matters here is that it does not ALSO land in the artwork category.
	_ok("cleanup/a cover is not counted as scraped artwork",
		not orphans.has(media.path_join("romm/4242_s.webp")), sample)

	# A cached RomM cover is not an orphan, it is a cache — its own category, or
	# it dominates the total and a sweep looks like it reclaimed far more than it
	# did. 3,184 of them against 163 scraped files on a real disk.
	var covers := {}
	for p: String in (found.get(StorageCleanup.COVERS, {}) as Dictionary).get("paths", []):
		covers[p] = true
	_ok("cleanup/romm cover is its own category",
		covers.has(media.path_join("romm/4242_s.webp")), _sample(covers))
	_ok("cleanup/scraped art is not filed as a cover",
		not covers.has(media.path_join("box/Dead.png")), _sample(covers))

	# THE boundary: the two that cannot be got back by pressing a button are
	# reported but never pre-selected. Saves are progress; a BIOS folder is
	# firmware no server here hands out, and removing a core is routine.
	_ok("cleanup/saves are never swept by default",
		not (StorageCleanup.SAVES in StorageCleanup.DEFAULT_SELECTED))
	_ok("cleanup/bios folders are never swept by default",
		not (StorageCleanup.CORE_SYSTEM in StorageCleanup.DEFAULT_SELECTED))
	_ok("cleanup/media is sweepable", StorageCleanup.MEDIA in StorageCleanup.DEFAULT_SELECTED)

	# purge_rom_metadata takes one ROM's art and leaves its neighbours'.
	var freed := StorageCleanup.purge_rom_metadata(TEST_SYSTEM, "Live.z64", 0)
	_ok("cleanup/purge reports bytes", freed >= 0)
	_ok("cleanup/purge took the box art",
		not FileAccess.file_exists(media.path_join("box/Live.png")))
	_ok("cleanup/purge took the manual",
		not FileAccess.file_exists(media.path_join("manual/Live.pdf")))
	_ok("cleanup/purge left another rom's art alone",
		FileAccess.file_exists(media.path_join("box/Dead.png")))
	# It is metadata only — the ROM itself is the caller's to remove, and a purge
	# that took the file would delete the game twice over.
	_ok("cleanup/purge does not touch the rom",
		FileAccess.file_exists(dir_path.path_join("Live.z64")))

	_rm_rf(dir_path)
	_ok("cleanup/cleaned up", not DirAccess.dir_exists_absolute(dir_path))


## The category gate — the one rule in this feature that must never regress.
##
## Driven against a HAND-BUILT findings dict, never a real scan: calling
## remove() with SAVES on whatever scan() found would delete the developer's own
## orphaned saves the first time this suite ran. The gate is what is under test,
## not the scanner, so the input is synthetic on purpose.
func _test_cleanup_gate() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	var art := RomMedia.media_root(TEST_SYSTEM).path_join("box/Sweepable.png")
	var save_dir := dir_path.path_join("__fake_save")
	_touch(art)
	_touch(save_dir.path_join("game.srm"))

	var found := {
		StorageCleanup.MEDIA: {"label": "m", "count": 1, "bytes": 1, "paths": [art]},
		StorageCleanup.SAVES: {"label": "s", "count": 1, "bytes": 1, "paths": [save_dir]},
	}

	var res := StorageCleanup.remove(found, StorageCleanup.DEFAULT_SELECTED)
	_ok("gate/sweeps the safe category", not FileAccess.file_exists(art))
	_ok("gate/SAVES SURVIVES A DEFAULT SWEEP",
		FileAccess.file_exists(save_dir.path_join("game.srm")))
	_eq("gate/counts only what it removed", int(res["removed"]), 1)

	# Named explicitly, it goes — and a directory goes with its contents.
	StorageCleanup.remove(found, [StorageCleanup.SAVES])
	_ok("gate/saves removed when asked for by name",
		not DirAccess.dir_exists_absolute(save_dir))

	# A category present in the findings but absent from `kinds` is untouched,
	# which is what makes the checkboxes mean anything.
	_touch(art)
	StorageCleanup.remove(found, [StorageCleanup.SAVES])
	_ok("gate/unnamed category untouched", FileAccess.file_exists(art))

	_rm_rf(dir_path)


## Which directories under system/ may be offered for deletion.
##
## Both shapes below were live on a real disk and both were pre-ticked before the
## gate went in: `cheats/` is shared infrastructure holding dolphin-emu/*.cht,
## and `melonDS DS/` belongs to a core that IS installed but names its directory
## after its display name rather than its core_name. "Not installed" was the
## wrong test; "is a core this app knows about, and is not installed" is right,
## because it leaves anything unidentifiable alone.
func _test_cleanup_core_dirs() -> void:
	var system_root := CoreDownloadManager.default_core_root().path_join("system")
	var db := CoreInfoDatabase.shared()

	# The gate itself, asserted directly — the scan cannot be pointed at a
	# scratch libretro root, so planting directories under the real one to prove
	# it would risk the developer's own firmware.
	_ok("coredir/cheats is not a core name", db.get_by_core_name("cheats").is_empty())
	_ok("coredir/a display name is not a core name",
		db.get_by_core_name("melonDS DS").is_empty())
	_ok("coredir/the core behind that display name IS known",
		not db.get_by_core_name("melondsds").is_empty())
	_ok("coredir/a real core name is known", not db.get_by_core_name("snes9x").is_empty())

	# And the live scan: nothing it offers may be a directory the database
	# cannot name, whatever is actually on this machine.
	var offered := (StorageCleanup.scan().get(StorageCleanup.CORE_SYSTEM, {}) as Dictionary)
	var bad := {}
	for p: String in offered.get("paths", []):
		var leaf := str(p).trim_suffix("/").get_file()
		if db.get_by_core_name(leaf).is_empty():
			bad[p] = true
	_eq("coredir/offers no unidentifiable directory", bad.size(), 0)
	# Belt and braces: name the two that actually shipped wrong.
	for leaf: String in ["cheats", "melonDS DS"]:
		_ok("coredir/never offers %s" % leaf,
			not (system_root.path_join(leaf) in offered.get("paths", [])))


## A "folder as file" game — a directory named Game.cue holding the cue and its
## tracks, the layout ES-DE and RetroDECK use. The folder IS the ROM, so its art
## must not be swept.
func _test_cleanup_folder_as_file() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	# The common shape: the folder and its launch file share a name.
	_touch(dir_path.path_join("Disc Game.cue/Disc Game.cue"))
	_touch(dir_path.path_join("Disc Game.cue/Disc Game.bin"))
	# And the shape that actually tests the rule: a folder whose contents are
	# named nothing like it, so ONLY the folder's own name can vouch for the art.
	# Without it, the two cases above pass whether or not folders are recorded.
	_touch(dir_path.path_join("Compilation.m3u/track01.bin"))
	_touch(dir_path.path_join("Compilation.m3u/track02.bin"))

	var media := RomMedia.media_root(TEST_SYSTEM)
	_touch(media.path_join("box/Disc Game.png"))
	_touch(media.path_join("box/Compilation.png"))
	_touch(media.path_join("box/Vanished.png"))
	# Art keyed on a file INSIDE the folder must survive too — the walk records
	# the folder's own name and its contents.
	_touch(media.path_join("label/Disc Game.png"))

	var orphans := {}
	for p: String in (StorageCleanup.scan().get(StorageCleanup.MEDIA, {}) as Dictionary
			).get("paths", []):
		orphans[p] = true
	# The sweep sees the whole real library, so a failure would otherwise print
	# every orphan on the disk — hundreds of lines nobody reads.
	var sample := _sample(orphans)

	_ok("folder/keeps art for a folder-as-file game",
		not orphans.has(media.path_join("box/Disc Game.png")), sample)
	_ok("folder/keeps art when only the folder name matches",
		not orphans.has(media.path_join("box/Compilation.png")), sample)
	_ok("folder/keeps art keyed on a member",
		not orphans.has(media.path_join("label/Disc Game.png")), sample)
	_ok("folder/still finds a real orphan beside it",
		orphans.has(media.path_join("box/Vanished.png")), sample)

	_rm_rf(dir_path)


## A gamelist row whose path escapes the ROM root resolves to nothing. It must
## read as missing and be pruned, not silently kept forever because the check
## could not answer.
func _test_gamelist_bad_paths() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	_touch(dir_path.path_join("Real.z64"))

	var gl := GamelistManager.new()
	gl.invalidate(TEST_SYSTEM)
	for bad: String in ["./../../etc/passwd", "./", "C:/Windows/system.ini"]:
		gl.add_or_merge_rom(TEST_SYSTEM, {"game_id": bad, "name": bad},
			{"path": bad, "romname": bad})
	gl.add_or_merge_rom(TEST_SYSTEM, {"game_id": "ok", "name": "ok"},
		{"path": "./Real.z64", "romname": "Real.z64"})

	var pruned := gl.prune_missing(TEST_SYSTEM)
	_ok("badpath/traversal pruned", "./../../etc/passwd" in pruned, str(pruned))
	_ok("badpath/absolute pruned", "C:/Windows/system.ini" in pruned, str(pruned))
	_ok("badpath/real rom kept", gl.known_rom_paths(TEST_SYSTEM).has("./Real.z64"))

	_rm_rf(dir_path)


## Uninstalling a core. Runs against the real cores directory because the path is
## derived, not injectable — under a name nothing could ever ship as, and the
## cores manifest is byte-restored afterwards: rewriting it round-trips through
## JSON, and the user's real install is not this suite's to reformat.
func _test_core_uninstall() -> void:
	const FAKE := "__cleanup_selftest"
	var cores_dir := CoreDownloadManager.default_cores_dir()
	var manifest_path := CoreDownloadManager.default_manifest_dir().path_join(
		"cores_manifest.json")

	var backup := ""
	var had_manifest := FileAccess.file_exists(manifest_path)
	if had_manifest:
		backup = FileAccess.get_file_as_string(manifest_path)

	# The naming rules, driven with an explicit suffix list rather than this
	# platform's. Desktop has ONE suffix, so a test that leaned on the live list
	# could not tell "removes every variant" from "removes the only one" — it
	# passed with the loop cut down to a single name.
	var android := PackedStringArray(["_libretro_android", "_libretro"])
	var both := CoreDownloadManager.core_lib_filenames(FAKE, android, ".so")
	_eq("uninstall/android has two naming variants", both.size(), 2)
	_eq("uninstall/canonical variant first", both[0], FAKE + "_libretro_android.so")
	_eq("uninstall/round-trips the android name",
		CoreDownloadManager.core_name_from_lib_filename(
			FAKE + "_libretro_android.so", android, ".so"), FAKE)
	_eq("uninstall/round-trips the bare name",
		CoreDownloadManager.core_name_from_lib_filename(
			FAKE + "_libretro.so", android, ".so"), FAKE)
	_eq("uninstall/a non-core filename yields nothing",
		CoreDownloadManager.core_name_from_lib_filename("readme.txt", android, ".so"), "")

	var names := CoreDownloadManager.core_lib_filenames(FAKE)
	_ok("uninstall/has a filename for this platform", names.size() > 0)
	for n: String in names:
		_touch(cores_dir.path_join(n))
	# A stray file under a name uninstall must NOT touch, to prove the sweep is
	# scoped to this core rather than to anything sharing its prefix.
	var bystander := cores_dir.path_join(FAKE + "2" + names[0].trim_prefix(FAKE))
	_touch(bystander)

	var res := CoreDownloadManager.uninstall(FAKE)
	_ok("uninstall/reports ok", bool(res["ok"]), str(res))
	var left := 0
	for n: String in names:
		if FileAccess.file_exists(cores_dir.path_join(n)):
			left += 1
	_eq("uninstall/removes this platform's library", left, 0)
	_ok("uninstall/leaves a similarly named core alone", FileAccess.file_exists(bystander))
	DirAccess.remove_absolute(bystander)

	# Uninstalling what is not there must fail rather than report success — the
	# UI turns ok into "Removed X, N freed".
	var again := CoreDownloadManager.uninstall(FAKE)
	_ok("uninstall/absent core refuses", not bool(again["ok"]), str(again))
	_ok("uninstall/absent core says why", not str(again["error"]).is_empty())
	_ok("uninstall/empty name refuses", not bool(CoreDownloadManager.uninstall("")["ok"]))

	# Nothing in the scene, so nothing can be using it.
	_eq("uninstall/nothing is using a fake core",
		CoreDownloadManager.systems_using(FAKE).size(), 0)
	_eq("uninstall/an unnamed core is used by nothing",
		CoreDownloadManager.systems_using("").size(), 0)

	if had_manifest:
		var f := FileAccess.open(manifest_path, FileAccess.WRITE)
		if f:
			f.store_string(backup)
			f.close()
	elif FileAccess.file_exists(manifest_path):
		DirAccess.remove_absolute(manifest_path)
	_ok("uninstall/manifest restored",
		not had_manifest or FileAccess.get_file_as_string(manifest_path) == backup)


## A readable slice of a set that may legitimately hold thousands of entries.
func _sample(found: Dictionary, limit: int = 6) -> String:
	var keys := found.keys()
	var head: Array = keys.slice(0, mini(limit, keys.size()))
	return "%d found, e.g. %s" % [keys.size(), str(head)]


func _touch(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("x")
		f.close()


# ---------------------------------------------------------------------------
# RommHttp — what a stalled server does to the thread waiting on it.
#
# A RomM box that accepts the connection and then goes quiet froze the whole app:
# the body loop had no deadline, so the worker sat on the socket indefinitely and
# whoever joined that thread sat there with it. These drive a real socket that
# behaves exactly that way, on loopback, with no RomM anywhere.
# ---------------------------------------------------------------------------

const _HEAD := "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n"
const _BODY := '{"ok":true}'


## A TCP server that accepts one connection and then does as it is told: a list
## of [delay_ms, bytes] steps, followed by silence with the socket HELD OPEN.
##
## Holding it open is the whole point. A server that closes instead ends the
## client's body loop by itself, and every case below would pass green without
## the code under test contributing anything.
class FakeServer extends RefCounted:

	var port := 0
	var _server := TCPServer.new()
	var _thread := Thread.new()
	var _stop := false

	func start(steps: Array) -> bool:
		for p in range(49500, 49560):
			if _server.listen(p, "127.0.0.1") == OK:
				port = p
				break
		if port == 0:
			return false
		_thread.start(_serve.bind(steps))
		return true

	func stop() -> void:
		_stop = true
		if _thread.is_started():
			_thread.wait_to_finish()
		_server.stop()

	func _serve(steps: Array) -> void:
		var peer: StreamPeerTCP = null
		var give_up := Time.get_ticks_msec() + 5000
		while peer == null and Time.get_ticks_msec() < give_up and not _stop:
			if _server.is_connection_available():
				peer = _server.take_connection()
			else:
				OS.delay_msec(5)
		if peer == null:
			return
		peer.poll()
		while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and not _stop:
			OS.delay_msec(5)
			peer.poll()

		for step: Array in steps:
			OS.delay_msec(int(step[0]))
			var chunk: PackedByteArray = step[1]
			if chunk.size() > 0:
				peer.put_data(chunk)

		while not _stop:
			OS.delay_msec(10)
		peer.disconnect_from_host()


## One exchange against a scripted server, run on ITS OWN thread.
##
## The blocking call cannot go on the main thread: a body loop with no deadline
## would pin _ready() itself, and a probe that hangs is worse than no probe —
## nothing left running would ever report the failure. Off-thread, `cap_sec`
## turns that same regression into a red line.
##
## Sentinel results, so a setup failure can never read as a pass:
##   -1 could not listen   -2 could not connect   -3 still blocked at the cap
func _probe(steps: Array, abort: Callable, timeout_sec: float,
			cap_sec: float = 10.0) -> Dictionary:
	var srv := FakeServer.new()
	if not srv.start(steps):
		return {"result": -1}

	var box := {"out": {"result": -2}}
	var url := "http://127.0.0.1:%d" % srv.port
	var t := Thread.new()
	t.start(func() -> void:
		var http := RommHttp.new()
		if http.open(url) == RommHttp.Result.OK:
			box["out"] = http.get_json("/x", PackedStringArray(), abort, timeout_sec)
		http.close())

	var deadline := Time.get_ticks_msec() + int(cap_sec * 1000.0)
	while t.is_alive() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	var stuck := t.is_alive()
	# Dropping the server closes the socket, which is what lets a stuck call
	# unwind far enough to be joined.
	srv.stop()
	t.wait_to_finish()
	return {"result": -3} if stuck else box["out"]


func _test_http_stalls() -> void:
	# Positive control. The header wait always had a deadline, so this one passing
	# says the fake server and the harness work; if it ever goes red, suspect them
	# before suspecting RommHttp.
	var silent: Dictionary = await _probe([], Callable(), 1.0)
	_eq("http/a server that never answers times out",
		int(silent["result"]), RommHttp.Result.TIMED_OUT)

	# The freeze itself: headers arrive, three bytes of an eleven-byte body
	# arrive, and then nothing ever does.
	var half: Array = [[0, (_HEAD + "abc").to_utf8_buffer()]]
	var stalled: Dictionary = await _probe(half, Callable(), 1.0)
	_eq("http/a body that stops mid-stream times out",
		int(stalled["result"]), RommHttp.Result.TIMED_OUT)

	# Same stall, but the caller changes its mind first. A generous timeout so
	# that reaching ABORTED proves the abort ended it and not the clock — this is
	# what lets a teardown join the worker instead of waiting out the server.
	var give_up := Time.get_ticks_msec() + 300
	var aborted: Dictionary = await _probe(half,
		func() -> bool: return Time.get_ticks_msec() > give_up, 30.0)
	_eq("http/a stalled body answers the abort",
		int(aborted["result"]), RommHttp.Result.ABORTED)

	# The deadline bounds SILENCE, not total transfer. Six chunks 200 ms apart run
	# 1.2 s against a 0.5 s budget and must all get through: a 4 GB ROM outruns
	# any single timeout, so a total-duration cap would abandon healthy downloads.
	var drip: Array = [[0, _HEAD.to_utf8_buffer()]]
	for i in range(6):
		drip.append([200, _BODY.substr(i * 2, 2).to_utf8_buffer()])
	var slow: Dictionary = await _probe(drip, Callable(), 0.5)
	_eq("http/a slow but moving body is not cut off",
		int(slow["result"]), RommHttp.Result.OK)


func _rm_rf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var child := path.path_join(n)
		if d.current_is_dir():
			_rm_rf(child)
		else:
			DirAccess.remove_absolute(child)
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


# ---------------------------------------------------------------------------
# The global backup switch. This changed SHIPPED behaviour — battery saves used
# to be opt-in per save, defaulting to off — so the exact fallback order is
# worth pinning: an explicit record always wins, and only a save nobody has
# said anything about follows the switch.
# ---------------------------------------------------------------------------

func _test_backup_switch() -> void:
	var cfg := RommConfig.new()
	var sync := RommSaveSync.new()
	sync.config = cfg
	var path := CoreDownloadManager.default_core_root().path_join("save") 		.path_join("fceumm").path_join("Game").path_join("abc123.srm")

	cfg.backup_enabled = true
	_ok("backup/a save nobody has ruled on follows the switch", sync.is_enabled(path))
	cfg.backup_enabled = false
	_ok("backup/and follows it the other way", not sync.is_enabled(path))

	# An explicit answer outranks the switch in BOTH directions. The first is
	# what lets a player keep one save off a shared server; the second is what
	# stops turning the switch off silently un-syncing a save they turned on.
	sync.set_enabled(path, true)
	_ok("backup/an opted-in save ignores the switch being off", sync.is_enabled(path))
	cfg.backup_enabled = true
	sync.set_enabled(path, false)
	_ok("backup/an opted-out save ignores the switch being on", not sync.is_enabled(path))

	# A save INSIDE a memory card is keyed separately and has to follow the same
	# ladder — a card's saves were opt-in per slot too.
	var card := CoreDownloadManager.default_core_root().path_join("save") 		.path_join("memcards").path_join("playstation").path_join("MEMORY CARD.mcr")
	var key := RommSaveSync.card_save_key(card, "BASLUS-00594")
	cfg.backup_enabled = true
	_ok("backup/a card save follows the switch too", sync.is_key_enabled(key))
	cfg.backup_enabled = false
	_ok("backup/and follows it off", not sync.is_key_enabled(key))

	# Nothing was persisted by this case beyond the two records it wrote; drop
	# them so a rerun starts where it did.
	sync._state.erase(RommSaveSync.key_for(path))
	sync.save_state()

	# The switch survives a round trip through the file, and an OLD config that
	# has never heard of it comes back ON — that is what makes the default
	# apply to everyone who upgrades rather than only to new installs.
	var fresh := RommConfig.new()
	_ok("backup/a config with no such key defaults on", fresh.backup_enabled)
	sync.free()
