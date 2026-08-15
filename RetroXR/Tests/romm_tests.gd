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
	# A probe must never hang a headless run.
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))

	_test_pair_url()
	_test_systemid_for()
	_test_partition()
	_test_collapse_by_systemid()
	_test_stats_unchanged()
	_test_cache_paths()
	_test_scan_roms()

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
