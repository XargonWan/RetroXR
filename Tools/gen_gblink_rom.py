#!/usr/bin/env python3
"""Build the two Game Boy ROMs the link-cable probe drives.

A commercial game is a bad oracle for a cable. Getting Pokemon as far as a trade
means a scripted walk through a Pokemon Centre, and when it fails you learn that
something went wrong somewhere between the menu and the wire. These two do one
thing: swap a known byte, for ever, and paint the screen white while the byte
that came back is the right one. A photo of the two screens IS the assertion.

  master.gb  writes 0xA5 to SB, sets SC to 0x81 (start, internal clock), waits
             for the hardware to clear the start bit, and expects 0x5A back.
  slave.gb   writes 0x5A to SB, sets SC to 0x80 (start, external clock), and
             waits to be clocked by the other end; expects 0xA5.

Both then set BGP: 0x00 (every shade white) when the byte matched, 0xAA (dark
grey) when it did not. The screen is one blank tile everywhere, so the palette IS
the picture. Black means the exchange has not completed even once -- which is
also what a machine with no cable in it shows, since a Game Boy waiting on an
external clock that never comes waits for ever, exactly as this does.

Roles are split across two ROMs rather than chosen at run time because nothing a
Game Boy can see says which end of a cable it is on. A real game asks the player.

    python Tools/gen_gblink_rom.py

Writes RetroXR/Tools/gblink/link_master.gb and link_slave.gb.

The Nintendo logo at 0x104 is deliberately left as zeros: only a real boot ROM
checks it, and the probe turns gambatte's bootloader option off so none runs.
"""
import os
import sys

# Hardware registers, as offsets from 0xFF00.
R_SB = 0x01
R_SC = 0x02
R_LY = 0x44
R_BGP = 0x47
R_LCDC = 0x40


class Asm(object):
    """Enough of a Game Boy assembler for two dozen instructions."""

    def __init__(self, org):
        self.org = org
        self.code = bytearray()
        self.labels = {}
        self.holes = []      # (offset, label, kind) kind in {"jr", "jp"}

    # -- position ---------------------------------------------------------
    def pc(self):
        return self.org + len(self.code)

    def label(self, name):
        self.labels[name] = self.pc()

    def db(self, *b):
        self.code += bytes(b)

    # -- instructions -----------------------------------------------------
    def di(self):                 self.db(0xF3)
    def nop(self):                self.db(0x00)
    def xor_a(self):              self.db(0xAF)
    def ld_a(self, n):            self.db(0x3E, n & 0xFF)
    def ld_b(self, n):            self.db(0x06, n & 0xFF)
    def ld_sp(self, nn):          self.db(0x31, nn & 0xFF, nn >> 8)
    def ld_bc(self, nn):          self.db(0x01, nn & 0xFF, nn >> 8)
    def ld_hl(self, nn):          self.db(0x21, nn & 0xFF, nn >> 8)
    def ld_hli_a(self):           self.db(0x22)
    def dec_bc(self):             self.db(0x0B)
    def dec_b(self):              self.db(0x05)
    def ld_a_b(self):             self.db(0x78)
    def or_c(self):               self.db(0xB1)
    def ldh_to(self, off):        self.db(0xE0, off & 0xFF)
    def ldh_from(self, off):      self.db(0xF0, off & 0xFF)
    def cp(self, n):              self.db(0xFE, n & 0xFF)
    def and_(self, n):            self.db(0xE6, n & 0xFF)

    def _rel(self, opcode, label):
        self.db(opcode)
        self.holes.append((len(self.code), label, "jr"))
        self.db(0x00)

    def jr(self, label):          self._rel(0x18, label)
    def jr_nz(self, label):       self._rel(0x20, label)
    def jr_z(self, label):        self._rel(0x28, label)

    def jp(self, label):
        self.db(0xC3)
        self.holes.append((len(self.code), label, "jp"))
        self.db(0x00, 0x00)

    # -- link -------------------------------------------------------------
    def resolve(self):
        for off, name, kind in self.holes:
            if name not in self.labels:
                raise KeyError("undefined label " + name)
            target = self.labels[name]
            if kind == "jr":
                delta = target - (self.org + off + 1)
                if not -128 <= delta <= 127:
                    raise ValueError("jr out of range to " + name)
                self.code[off] = delta & 0xFF
            else:
                self.code[off] = target & 0xFF
                self.code[off + 1] = target >> 8
        return bytes(self.code)


def build(master):
    a = Asm(0x150)

    a.di()
    a.ld_sp(0xFFFE)

    # The LCD has to be off before VRAM can be written from code that is not
    # timing its accesses, and it can only be turned off during vblank.
    a.label("waitvbl")
    a.ldh_from(R_LY)
    a.cp(0x90)
    a.jr_nz("waitvbl")
    a.xor_a()
    a.ldh_to(R_LCDC)

    # One blank tile, and a map that is nothing but that tile: every pixel on
    # screen is colour 0, so BGP's bottom two bits paint the whole picture.
    a.ld_hl(0x8000)
    a.ld_b(16)
    a.label("clrtile")
    a.xor_a()
    a.ld_hli_a()
    a.dec_b()
    a.jr_nz("clrtile")

    a.ld_hl(0x9800)
    a.ld_bc(0x0400)
    a.label("clrmap")
    a.xor_a()
    a.ld_hli_a()
    a.dec_bc()
    a.ld_a_b()
    a.or_c()
    a.jr_nz("clrmap")

    a.ld_a(0xFF)              # black: nothing has crossed yet
    a.ldh_to(R_BGP)
    a.ld_a(0x91)              # LCD on, BG on, tiles at 0x8000, map at 0x9800
    a.ldh_to(R_LCDC)

    mine = 0xA5 if master else 0x5A
    theirs = 0x5A if master else 0xA5

    a.label("loop")
    if master:
        # About 27 ms between bytes, which is a slow Game Boy game and a hundred
        # times the frontend's rendezvous horizon. Fast enough that a three
        # second probe sees dozens of exchanges.
        a.ld_bc(0x1000)
        a.label("delay")
        a.dec_bc()
        a.ld_a_b()
        a.or_c()
        a.jr_nz("delay")

    a.ld_a(mine)
    a.ldh_to(R_SB)
    a.ld_a(0x81 if master else 0x80)
    a.ldh_to(R_SC)

    # Poll the start bit rather than taking the interrupt: interrupts are off,
    # and a machine that is waiting to be clocked has nothing else to do anyway.
    a.label("wait")
    a.ldh_from(R_SC)
    a.and_(0x80)
    a.jr_nz("wait")

    a.ldh_from(R_SB)
    a.cp(theirs)
    a.jr_nz("bad")
    a.ld_a(0x00)              # white
    a.ldh_to(R_BGP)
    a.jr("loop")

    a.label("bad")
    a.ld_a(0xAA)              # dark grey
    a.ldh_to(R_BGP)
    a.jr("loop")

    code = a.resolve()

    rom = bytearray(0x8000)
    rom[0x100:0x104] = bytes([0x00, 0xC3, 0x50, 0x01])   # nop; jp 0x150
    title = ("GBLINK " + ("MASTER" if master else "SLAVE")).ljust(16, "\0")[:16]
    rom[0x134:0x144] = title.encode("ascii")
    rom[0x147] = 0x00        # ROM only
    rom[0x148] = 0x00        # 32 KiB
    rom[0x149] = 0x00        # no cartridge RAM
    rom[0x14B] = 0x33        # new licensee scheme

    checksum = 0
    for i in range(0x134, 0x14D):
        checksum = (checksum - rom[i] - 1) & 0xFF
    rom[0x14D] = checksum

    rom[0x150:0x150 + len(code)] = code
    return bytes(rom)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(os.path.dirname(here), "RetroXR", "Tools", "gblink")
    os.makedirs(out, exist_ok=True)
    for master in (True, False):
        rom = build(master)
        name = "link_master.gb" if master else "link_slave.gb"
        path = os.path.join(out, name)
        with open(path, "wb") as fh:
            fh.write(rom)
        print("wrote %s (%d bytes)" % (path, len(rom)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
