"""Copy your imported Bad Fur Day assets out to a folder of your choice, named and sorted,
for use in other programs (Blender, other engines, audio editors).

    <out>/Conker's Bad Fur Day - extracted assets/
      Models/<Characters | Pickups | Scenery | Weapons | Parts & effects | Level pieces (unnamed) | Other objects (unnamed)>/<Name>.glb
      Levels/<NN> <Name>.glb
      Music/<Chapter>/<NNNN> <Name>.wav   (+ .mid)
      Music (streamed)/<NNNN> <Name>.mp3
      Voices and dialogue/<NNNN> (<seconds>s).mp3
      Other streams/<NNNN> (<seconds>s).mp3
      Sound effects/<NNNN>.wav
      Instrument samples/Instrument NNN/<NNNN>.wav
      index.csv, README.txt

Models and levels are self-contained .glb files (textures and animations packed in), the
format Blender, Godot, Unity and most 3D tools open directly. This folder is yours and isn't
used by Conker Maker. It's made from your ROM: it's for your own use, not for sharing.
"""
from __future__ import annotations

import base64
import csv
import json
import re
import shutil
import struct
from pathlib import Path
from urllib.parse import unquote

from . import project, rom_assets

ROOT_NAME = "Conker's Bad Fur Day - extracted assets"
CATEGORY_FOLDERS = {"characters": "Characters", "collectables": "Pickups", "scene-items": "Scenery",
                    "weapons": "Weapons", "parts-effects": "Parts & effects"}
MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


def safe_name(text: str, limit: int = 90) -> str:
    """A file name Windows, macOS and Linux all accept."""
    text = re.sub(r"\?(?=\s|$)", " (guess)", text).replace("?", "").replace(": ", " - ")
    text = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "-", text).strip().rstrip(".")
    return (text or "unnamed")[:limit].rstrip()


def _uri_bytes(base: Path, uri: str) -> bytes:
    if uri.startswith("data:"):
        return base64.b64decode(uri.split(",", 1)[1])
    return (base / unquote(uri)).read_bytes()


def gltf_to_glb(path: Path, rename_animations: dict | None = None) -> bytes:
    """Pack a .gltf with its .bin and images into one binary .glb."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    base = path.parent
    blob = bytearray()

    def append(data: bytes) -> tuple[int, int]:
        while len(blob) % 4:
            blob.append(0)
        offset = len(blob)
        blob.extend(data)
        return offset, len(data)

    # Old buffers become one: shift each buffer's views by where it lands.
    shifts = []
    for buffer in doc.get("buffers", []):
        data = _uri_bytes(base, buffer["uri"]) if "uri" in buffer else b""
        shifts.append(append(data)[0])
    for view in doc.get("bufferViews", []):
        view["byteOffset"] = view.get("byteOffset", 0) + shifts[view.get("buffer", 0)]
        view["buffer"] = 0
    for image in doc.get("images", []):
        if "uri" not in image:
            continue
        data = _uri_bytes(base, image["uri"])
        mime = "image/png" if image["uri"].startswith("data:image/png") else MIME.get(Path(unquote(image["uri"])).suffix.lower(), "image/png")
        offset, length = append(data)
        doc.setdefault("bufferViews", []).append({"buffer": 0, "byteOffset": offset, "byteLength": length})
        image.pop("uri")
        image["bufferView"] = len(doc["bufferViews"]) - 1
        image["mimeType"] = mime
    while len(blob) % 4:
        blob.append(0)
    doc["buffers"] = [{"byteLength": len(blob)}]
    for animation in doc.get("animations", []):
        for key, label in (rename_animations or {}).items():
            if key in animation.get("name", ""):
                animation["name"] = f"{label} ({animation['name']})"
    text = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    text += b" " * (-len(text) % 4)
    total = 12 + 8 + len(text) + 8 + len(blob)
    return (struct.pack("<4sII", b"glTF", 2, total) + struct.pack("<I4s", len(text), b"JSON") + text
            + struct.pack("<I4s", len(blob), b"BIN\x00") + bytes(blob))


def _unique(path: Path, used: set) -> Path:
    candidate, n = path, 2
    while str(candidate).lower() in used:
        candidate = path.with_name(f"{path.stem} {n}{path.suffix}")
        n += 1
    used.add(str(candidate).lower())
    return candidate


def export(library: str | Path, out: str | Path, say=print) -> dict:
    library = Path(library)
    catalog = json.loads((library / "catalog.json").read_text(encoding="utf-8"))
    root = Path(out) / ROOT_NAME
    root.mkdir(parents=True, exist_ok=True)
    used: set = set()
    rows = []
    counts = {"models": 0, "levels": 0, "sounds": 0}
    conker_anims = {v: k for k, v in project.catalog().get("player", {}).get("animations", {}).items()}

    say("Packing models...")
    for m in catalog.get("models", []):
        source = library / m["path"]
        if not source.is_file():
            continue
        if m.get("named"):
            folder = CATEGORY_FOLDERS.get(m.get("category"), "Objects")
            name = m["name"]
        else:
            folder = "Level pieces (unnamed)" if m["bank"] == 4 else "Other objects (unnamed)"
            name = f"{m['id']}"
        target = _unique(root / "Models" / folder / f"{safe_name(name)}.glb", used)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(gltf_to_glb(source, conker_anims if m["id"] == "b01-0000-00" else None))
        rows.append(["model", target.relative_to(root).as_posix(), m["id"], m["name"], m.get("category", ""),
                     m.get("faces", 0), m.get("animations", 0)])
        counts["models"] += 1

    say("Packing levels...")
    for lvl in catalog.get("scenes", []):
        source = library / lvl["path"]
        if not source.is_file():
            continue
        target = _unique(root / "Levels" / f"{lvl['index']:02d} {safe_name(lvl['name'])}.glb", used)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(gltf_to_glb(source))
        rows.append(["level", target.relative_to(root).as_posix(), lvl["id"], lvl["name"], "", lvl.get("faces", 0), 0])
        counts["levels"] += 1

    say("Copying music and sounds...")
    audio = catalog.get("audio", {})

    def copy(src_rel, target: Path, kind: str, ident, name: str, category: str = "") -> None:
        if not src_rel or not (library / src_rel).is_file():
            return
        target = _unique(target, used)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(library / src_rel, target)
        rows.append([kind, target.relative_to(root).as_posix(), ident, name, category, "", ""])
        counts["sounds"] += 1

    for music in audio.get("music", []):
        folder = root / "Music" / safe_name(music.get("category") or "Other")
        stem = f"{music['index']:04d} {safe_name(music['name'])}"
        copy(music.get("wav"), folder / f"{stem}.wav", "music", music["index"], music["name"], music.get("category", ""))
        copy(music.get("midi"), folder / f"{stem}.mid", "music-midi", music["index"], music["name"], music.get("category", ""))
    stream_names = {s["index"]: s.get("name") for s in audio.get("music_streams", [])}
    folders = {"music": "Music (streamed)", "voice": "Voices and dialogue", "other": "Other streams"}
    for stream in audio.get("streams", []):
        label = stream_names.get(stream["index"]) or f"{stream['seconds']:g}s"
        name = f"{stream['index']:04d} ({label}).mp3" if stream["kind"] != "music" else f"{stream['index']:04d} {safe_name(label)}.mp3"
        copy(stream["file"], root / folders[stream["kind"]] / name, f"stream-{stream['kind']}", stream["index"], label)
    for sample in audio.get("samples", []):
        instruments = sample.get("instruments") or [-1]
        if instruments == [0]:
            folder = root / "Sound effects"
        else:
            folder = root / "Instrument samples" / f"Instrument {instruments[0]:03d}"
        copy(sample["wav"], folder / f"{sample['index']:04d}.wav", "sample", sample["index"], "",
             ", ".join(str(i) for i in instruments))

    with open(root / "index.csv", "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["kind", "file", "rom id", "name", "category", "faces", "animations"])
        writer.writerows(rows)
    (root / "README.txt").write_text(
        "Conker's Bad Fur Day assets, extracted by Conker Maker from your own ROM\n"
        f"(ROM SHA-1 {catalog.get('rom_sha1')}).\n\n"
        "These are Rare's copyrighted assets, for your personal use only: don't share or publish them.\n\n"
        "Models/ and Levels/ are .glb files (textures and animations included) that Blender, Godot,\n"
        "Unity and most 3D tools open. One unit is one N64 unit (about a centimetre): scale by 0.01 for metres.\n"
        "Names come from the conkers-bfd-decomp project's reviewed gallery; 'Level pieces' and 'Objects'\n"
        "without names are listed by ROM id (bank-entry-segment). Conker's animations that Conker Maker\n"
        "has identified are labelled (idle, walk, run, jump, hover, attack); the rest keep their ROM names.\n\n"
        "Music/ is rendered with the game's own instrument samples (an approximation of the N64's playback),\n"
        "with the MIDI beside each track. Track names are by-ear identifications from the decomp project.\n"
        "Voices and dialogue/ are the MP3 streams with lip-sync cues; Other streams/ are the rest.\n"
        "Sound effects/ and Instrument samples/ are the sound bank's samples, by instrument.\n\n"
        "index.csv lists every file with its ROM identity.\n", encoding="utf-8")
    counts["folder"] = str(root)
    return counts
