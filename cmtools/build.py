"""Build a project into something playable and something shareable.

    out/<Title>.z64   your ROM with the game packed in: open it in the recomp to play
    out/<Title>.bps   the same as a patch against your ROM: this is what you share
    out/build.json    what was built, from which ROM

The ROM's code region is never touched, so the recomp accepts the result as an asset
hack, just like the uncensored ROM.
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import time
from pathlib import Path

from . import bps, package, project, rom as romlib


class BuildError(Exception):
    pass


def build(project_dir: str | Path, rom_path: str | Path, out_dir: str | Path | None = None) -> dict:
    project_dir = Path(project_dir)
    game = project.load(project_dir)
    problems = project.validate(game)
    if problems:
        raise BuildError("The game isn't ready to build:\n  - " + "\n  - ".join(problems))
    base = romlib.load(rom_path)
    if package.read_from(base.data) is not None:
        raise BuildError("That ROM already has a Conker Maker game in it. Build from your original ROM.")

    blob = package.pack(game)
    built = package.write_into(base.data, blob)
    assert built[romlib.CODE_START:romlib.CODE_END] == base.data[romlib.CODE_START:romlib.CODE_END]

    out_dir = Path(out_dir) if out_dir else project_dir / "build"
    out_dir.mkdir(parents=True, exist_ok=True)
    name = project.slug(game["title"])
    rom_out, patch_out = out_dir / f"{name}.z64", out_dir / f"{name}.bps"
    rom_out.write_bytes(built)
    meta = json.dumps({"tool": "Conker Maker", "title": game["title"], "base": base.kind,
                       "base_sha1": base.sha1})
    patch_out.write_bytes(bps.create(base.data, built, meta))

    report = {
        "title": game["title"],
        "built_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "base_rom": {"kind": base.kind, "description": base.description, "sha1": base.sha1,
                     "byte_order": base.byte_order},
        "rom": str(rom_out), "rom_sha1": hashlib.sha1(built).hexdigest(),
        "patch": str(patch_out), "patch_bytes": patch_out.stat().st_size,
        "package_bytes": len(blob), "package_capacity": package.CAPACITY,
        "levels": len(game["levels"]),
        "objects": sum(len(l.get("objects", [])) for l in game["levels"].values()),
    }
    (out_dir / "build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def apply_patch(rom_path: str | Path, patch_path: str | Path, out_path: str | Path) -> Path:
    """What a player does: their ROM + your .bps -> the game's ROM."""
    base = romlib.load(rom_path)
    built = bps.apply(base.data, Path(patch_path).read_bytes())
    out_path = Path(out_path)
    out_path.write_bytes(built)
    return out_path


def playtest(recomp_exe: str | Path, rom_path: str | Path) -> subprocess.Popen:
    """Start CBFD-Recompiled with the built ROM (it takes a ROM path on its command line)."""
    exe = Path(recomp_exe)
    if not exe.is_file():
        raise BuildError(f"Can't find the recomp at {exe}.")
    return subprocess.Popen([str(exe), str(Path(rom_path).resolve())], cwd=str(exe.parent))
