"""The game package: your whole project, packed into the ROM's free space.

Layout at rom.FREE_START (all big-endian, as the N64 reads it):

    0x00  'CMKR'          magic
    0x04  u16 version     PACKAGE_VERSION
    0x06  u16 flags       0
    0x08  u32 size        bytes of compressed payload
    0x0C  u32 crc32       of the compressed payload
    0x10  u32 raw size    bytes of the JSON before compression
    0x14  char[44] title  NUL-padded, for tools that only want the name
    0x40  payload         zlib-compressed, minified project JSON

The obd_core runtime mod finds the game by reading this header from the ROM. JSON is a
starting point; once the runtime's needs settle, the payload becomes a compact binary.
"""
from __future__ import annotations

import json
import struct
import zlib

from . import rom as romlib

MAGIC = b"CMKR"
PACKAGE_VERSION = 1
HEADER = struct.Struct(">4sHHIII44s")
CAPACITY = romlib.FREE_END - romlib.FREE_START


class PackageError(Exception):
    pass


def pack(game: dict) -> bytes:
    raw = json.dumps(game, separators=(",", ":"), sort_keys=True).encode("utf-8")
    payload = zlib.compress(raw, 9)
    title = str(game.get("title", "")).encode("utf-8")[:43]
    blob = HEADER.pack(MAGIC, PACKAGE_VERSION, 0, len(payload), zlib.crc32(payload), len(raw), title)
    blob += bytes(0x40 - HEADER.size) + payload
    if len(blob) > CAPACITY:
        raise PackageError(f"The game is {len(blob):,} bytes packed, but the ROM has room for {CAPACITY:,}. "
                           "(Bigger games will load from the mod's own files in a later version.)")
    return blob


def unpack(blob: bytes) -> dict:
    magic, version, _flags, size, crc, raw_size, _title = HEADER.unpack_from(blob)
    if magic != MAGIC:
        raise PackageError("no Conker Maker game here")
    if version > PACKAGE_VERSION:
        raise PackageError(f"this game needs a newer Conker Maker (package v{version})")
    payload = blob[0x40:0x40 + size]
    if zlib.crc32(payload) != crc:
        raise PackageError("the game package is damaged")
    raw = zlib.decompress(payload)
    if len(raw) != raw_size:
        raise PackageError("the game package is damaged")
    return json.loads(raw)


def write_into(rom_data: bytes, blob: bytes) -> bytes:
    """A copy of the ROM with the package in its free space (the rest of it filled with 0xFF)."""
    region = rom_data[romlib.FREE_START:romlib.FREE_END]
    if region.strip(b"\xff") and not region.startswith(MAGIC):
        raise PackageError("The ROM's free space is already used by something else (another hack?).")
    filled = blob + b"\xff" * (CAPACITY - len(blob))
    return rom_data[:romlib.FREE_START] + filled + rom_data[romlib.FREE_END:]


def read_from(rom_data: bytes) -> dict | None:
    blob = rom_data[romlib.FREE_START:romlib.FREE_END]
    return unpack(blob) if blob.startswith(MAGIC) else None
