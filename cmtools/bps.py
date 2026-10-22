"""BPS patches: how a finished Conker Maker game is shared.

A BPS patch holds only the differences from the player's ROM, so it carries no game
data. Players apply it to their own US ROM (with Conker Maker, Floating IPS, Rom
Patcher JS, ...) to get the sequel's ROM, the same way fan hacks are shared.

The encoder is tuned for in-place edits (Conker Maker writes into existing assets and
the ROM's free space, never shifting data around): it emits SourceRead for unchanged
runs and TargetRead for changed ones. The decoder handles every BPS action.
"""
from __future__ import annotations

import zlib

SOURCE_READ, TARGET_READ, SOURCE_COPY, TARGET_COPY = range(4)
CHUNK = 4096


class BpsError(Exception):
    pass


def _varint(value: int) -> bytes:
    out = bytearray()
    while True:
        x = value & 0x7F
        value >>= 7
        if value == 0:
            out.append(0x80 | x)
            return bytes(out)
        out.append(x)
        value -= 1


def _read_varint(data: bytes, pos: int) -> tuple[int, int]:
    value, shift = 0, 1
    while True:
        if pos >= len(data):
            raise BpsError("truncated patch")
        x = data[pos]
        pos += 1
        value += (x & 0x7F) * shift
        if x & 0x80:
            return value, pos
        shift <<= 7
        value += shift


def _diff_runs(source: bytes, target: bytes):
    """Yield (equal, start, end) runs over target, comparing with source at the same offset."""
    n, shared = len(target), min(len(source), len(target))
    pos, run_start, run_equal = 0, 0, None

    def flip(at: int, equal: bool):
        nonlocal run_start, run_equal
        if run_equal is None:
            run_equal = equal
        elif equal != run_equal:
            runs.append((run_equal, run_start, at))
            run_start, run_equal = at, equal

    runs: list[tuple[bool, int, int]] = []
    while pos < shared:
        end = min(pos + CHUNK, shared)
        if source[pos:end] == target[pos:end]:
            flip(pos, True)
        else:
            for i in range(pos, end):
                flip(i, source[i] == target[i])
        pos = end
    if shared < n:
        flip(shared, False)
    if run_equal is not None:
        runs.append((run_equal, run_start, n))
    return runs


def create(source: bytes, target: bytes, metadata: str = "") -> bytes:
    meta = metadata.encode("utf-8")
    out = bytearray(b"BPS1")
    out += _varint(len(source)) + _varint(len(target)) + _varint(len(meta)) + meta
    for equal, start, end in _diff_runs(source, target):
        # Tiny equal gaps cost more as a separate action than as literal bytes; that's fine either way.
        length = end - start
        if equal:
            out += _varint(((length - 1) << 2) | SOURCE_READ)
        else:
            out += _varint(((length - 1) << 2) | TARGET_READ)
            out += target[start:end]
    out += zlib.crc32(source).to_bytes(4, "little")
    out += zlib.crc32(target).to_bytes(4, "little")
    out += zlib.crc32(bytes(out)).to_bytes(4, "little")
    return bytes(out)


def metadata(patch: bytes) -> str:
    if patch[:4] != b"BPS1":
        raise BpsError("not a BPS patch")
    pos = 4
    _, pos = _read_varint(patch, pos)
    _, pos = _read_varint(patch, pos)
    size, pos = _read_varint(patch, pos)
    return patch[pos:pos + size].decode("utf-8", "replace")


def apply(source: bytes, patch: bytes) -> bytes:
    if patch[:4] != b"BPS1" or len(patch) < 16:
        raise BpsError("not a BPS patch")
    if zlib.crc32(patch[:-4]) != int.from_bytes(patch[-4:], "little"):
        raise BpsError("the patch file is damaged (checksum mismatch)")
    if zlib.crc32(source) != int.from_bytes(patch[-12:-8], "little"):
        raise BpsError("this patch is for a different ROM (source checksum mismatch)")
    pos = 4
    source_size, pos = _read_varint(patch, pos)
    target_size, pos = _read_varint(patch, pos)
    meta_size, pos = _read_varint(patch, pos)
    pos += meta_size
    if source_size != len(source):
        raise BpsError("this patch is for a ROM of a different size")
    target = bytearray(target_size)
    out = source_rel = target_rel = 0
    end = len(patch) - 12
    while pos < end:
        word, pos = _read_varint(patch, pos)
        action, length = word & 3, (word >> 2) + 1
        if out + length > target_size:
            raise BpsError("patch writes past the end of the target")
        if action == SOURCE_READ:
            target[out:out + length] = source[out:out + length]
        elif action == TARGET_READ:
            target[out:out + length] = patch[pos:pos + length]
            pos += length
        else:
            raw, pos = _read_varint(patch, pos)
            delta = -(raw >> 1) if raw & 1 else raw >> 1
            if action == SOURCE_COPY:
                source_rel += delta
                target[out:out + length] = source[source_rel:source_rel + length]
                source_rel += length
            else:
                target_rel += delta
                for i in range(length):  # may overlap the bytes it writes
                    target[out + i] = target[target_rel + i]
                target_rel += length
        out += length
    result = bytes(target)
    if zlib.crc32(result) != int.from_bytes(patch[-8:-4], "little"):
        raise BpsError("patched ROM failed its checksum")
    return result
