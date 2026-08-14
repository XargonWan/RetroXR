## CartridgeSaveTarget — a ROM standing in for a cartridge, so its saves can be
## read somewhere no cartridge exists.
##
## CartridgeOptionsPanel answers questions about a game: which saves are on this
## device, which of them RomM holds, what the achievement set says. Every one of
## those is a fact about the ROM, not about the plastic — but the panel could only
## be pointed at a RetroCartridge, so the spawn menu's library had no way to ask.
##
## This carries the four things the panel reads. It is deliberately NOT a
## cartridge: nothing here can be bound to a save, because a save is bound to the
## object you put in the machine, and the panel checks which kind of target it has
## before offering that.
class_name CartridgeSaveTarget
extends RefCounted

var systemid := ""
var rom_path := ""
var game_label := ""
## Written by the panel when a server save is pulled down. Nothing reads it back —
## it exists so the panel does not have to special-case the write.
var save_id := ""


static func create(sysid: String, path: String, label: String) -> CartridgeSaveTarget:
	var t := CartridgeSaveTarget.new()
	t.systemid = sysid
	t.rom_path = path
	t.game_label = label
	return t
