"""ROM gate: find out which Conker ROM the player has, and normalise it to big-endian .z64.

Conker Maker never ships game data. Everything it builds starts from the player's own
cartridge dump, so every command begins here.

Accepted: the US ROM (v1.0) and ROM hacks of it that only change assets (such as the
uncensored hack), the same rule CBFD-Recompiled applies. Other regions and the
betas are refused, because the recomp can't run them.
"""
from __future__ import annotations

import array
import hashlib
from dataclasses import dataclass
from pathlib import Path

ROM_SIZE = 64 * 1024 * 1024
INTERNAL_NAME = b"CONKER BFD"

# Known dumps, by the SHA-1 of the normalised (.z64, big-endian) image.
KNOWN = {
    "4cbadd3c4e0729dec46af64ad018050eada4f47a": ("us", "US v1.0 (original)"),
    "4df27756ef604e82c6874aade21075b5bc8d405a": ("us-uncensored", "US Uncensored (asset hack)"),
}

# The same dumps as raw files in each byte order, so a file can be identified without
# converting it first (the Godot app's ROM gate uses these).
KNOWN_RAW = {
    "4cbadd3c4e0729dec46af64ad018050eada4f47a": ("us", "z64"),
    "27d3123dd4a3d84cb1a7ecf2ced3bc44389f4607": ("us", "v64"),
    "772698b1e87cf1e1912920a4d99a6076c80d2e20": ("us", "n64"),
    "4df27756ef604e82c6874aade21075b5bc8d405a": ("us-uncensored", "z64"),
    "c27c387653a780c06e8fa082f33acab52991d13e": ("us-uncensored", "v64"),
    "69faaf4e7f4167b2df45979e48e42e168f25a6f4": ("us-uncensored", "n64"),
}

# The region the game's code covers (CBFD-Recompiled host/src/rom_versions.cpp). A ROM hack
# must leave this alone, so Conker Maker never writes inside it.
CODE_START = 0x40
CODE_END = 0x1A37E0

# Unused space at the end of the US ROM (and the uncensored hack): 0xFF from 0x3F8B800
# to the end, about 466 KB. Conker Maker keeps its game package here.
FREE_START = 0x3F8C000
FREE_END = ROM_SIZE

MAGIC_ORDER = {
    bytes.fromhex("80371240"): "z64",
    bytes.fromhex("37804012"): "v64",
    bytes.fromhex("40123780"): "n64",
}


class RomError(Exception):
    """The file isn't a ROM Conker Maker can use; the message says why, for the player."""


@dataclass
class Rom:
    data: bytes          # normalised big-endian image
    byte_order: str      # what the file was: z64, v64 or n64
    kind: str            # us, us-uncensored, us-asset-hack
    description: str
    sha1: str

    @property
    def verified(self) -> bool:
        return self.sha1 in KNOWN


def to_z64(raw: bytes) -> tuple[bytes, str]:
    order = MAGIC_ORDER.get(raw[:4])
    if order is None:
        raise RomError("This doesn't look like an N64 ROM (unknown header).")
    if order == "z64":
        return raw, order
    words = array.array("H" if order == "v64" else "I", raw)
    words.byteswap()
    return words.tobytes(), order


def country(data: bytes) -> str:
    return chr(data[0x3E]) if len(data) > 0x3E else "?"


def identify(raw: bytes) -> Rom:
    data, order = to_z64(raw)
    if data[0x20:0x20 + len(INTERNAL_NAME)] != INTERNAL_NAME:
        name = data[0x20:0x34].decode("ascii", "replace").strip()
        raise RomError(f"This ROM is '{name}', not Conker's Bad Fur Day.")
    region = country(data)
    if region != "E":
        names = {"P": "European (PAL)", "J": "Japanese", "D": "German"}
        raise RomError(f"This is the {names.get(region, region)} ROM. Conker Maker (like the recomp) "
                       "needs the US ROM, or a hack of it that only changes assets.")
    if len(data) != ROM_SIZE:
        raise RomError(f"The ROM is {len(data)} bytes; a Conker ROM is exactly 64 MB.")
    sha1 = hashlib.sha1(data).hexdigest()
    if sha1 in KNOWN:
        kind, description = KNOWN[sha1]
    else:
        kind, description = "us-asset-hack", "US ROM hack (unverified: asset changes assumed)"
    return Rom(data, order, kind, description, sha1)


def load(path: str | Path) -> Rom:
    path = Path(path)
    if not path.is_file():
        raise RomError(f"No file at {path}.")
    return identify(path.read_bytes())
