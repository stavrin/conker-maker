"""Import Bad Fur Day's models, textures and level scenes from the player's own ROM.

Conker Maker never ships Rare's assets. Instead, this turns the player's ROM into a
local *asset library* that the app shows in its palette, inspector and preview:

    <library>/
      catalog.json            every model and scene, with names and categories
      status.json             progress while importing (the app polls it)
      models/us-bank-NN-preview/geometry/*.gltf   (+ .bin, ../textures/*.png)
      levels/geometry/scene-NN.gltf               complete level scenes (models placed as in the game)
      audio/source, audio/mp3, audio/cues          sound bank, music sequences, MP3 streams, lip cues
      audio/preview/music/NNNN.wav                 music rendered with the game's own samples

The library lives in the user's app-data folder (not in a project), one per ROM, so it's
never committed or shared by accident.

The extraction itself is DevOldSchool's conkers-bfd-decomp (MIT licensed), pinned to a
known commit and fetched on first use. Its extractors are byte-verified against the ROM
and need only Python 3.12+ with no extra packages.
"""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

from . import rom as romlib

DECOMP_REPO = "DevOldSchool/conkers-bfd-decomp"
DECOMP_COMMIT = "4288820283c66edb65f41e20dc13c89cd8c46e05"
CATALOG_FORMAT = "conker-maker-rom-library-v1"
CATALOG_REVISION = 2   # 2: animation donors (anim_from) for characters without their own clips
LIBRARY_VERSION = 2   # 2: complete levels (levels/), level names
# One N64 unit is about a centimetre: Conker comes out about 1.6 m tall at this scale.
WORLD_SCALE = 0.01

TEXTURE_FAMILIES = [  # (family, output folder the model exporter looks for)
    ("64x64", "us"),
    ("1056-proven", "us-1056-proven"),
    ("ci8-proven", "us-ci8-proven"),
    ("rgba16-proven", "us-rgba16-proven"),
    ("native-proven", "us-native-proven"),
    ("tiled-views", "us-tiled-views"),
]
MODEL_BANKS = ["01", "03", "04", "09"]
BANK_LABELS = {1: "Characters & animated", 3: "Objects", 4: "Level pieces", 9: "Objects & effects"}
CATEGORY_LABELS = {
    "characters": "Characters", "collectables": "Pickups", "scene-items": "Scenery",
    "weapons": "Weapons", "parts-effects": "Parts & effects",
    "level-pieces": "Level pieces (unnamed)", "other-objects": "Other objects (unnamed)",
}


class AssetError(Exception):
    pass


ROOT = Path(__file__).resolve().parent.parent


def app_data_dir() -> Path:
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return base / "ConkerMaker"


def default_library(rom: romlib.Rom) -> Path:
    return app_data_dir() / "library" / rom.sha1[:12]


def default_decomp_dir() -> Path:
    return ROOT / "third_party" / "conkers-bfd-decomp"


def library_info(library: Path) -> dict:
    catalog = library / "catalog.json"
    if not catalog.is_file():
        return {"imported": False, "library": str(library)}
    data = json.loads(catalog.read_text(encoding="utf-8"))
    return {"imported": data.get("library_version") == LIBRARY_VERSION, "library": str(library),
            "models": len(data.get("models", [])), "scenes": len(data.get("scenes", [])),
            "rom_sha1": data.get("rom_sha1"), "out_of_date": data.get("library_version") != LIBRARY_VERSION}


# --- the decomp's extractors -------------------------------------------------------------------

def ensure_decomp(decomp: Path, say=print) -> Path:
    """The pinned decomp checkout: an existing clone, or the commit's zip from GitHub."""
    if (decomp / "scripts" / "model_assets.py").is_file():
        return decomp
    say(f"Downloading the asset extractors ({DECOMP_REPO} @ {DECOMP_COMMIT[:10]})...")
    staging = decomp.with_name(decomp.name + ".partial")
    shutil.rmtree(staging, ignore_errors=True)
    if shutil.which("git"):   # a shallow fetch of exactly the pinned commit
        staging.mkdir(parents=True)
        steps = [["git", "init", "-q"], ["git", "remote", "add", "origin", f"https://github.com/{DECOMP_REPO}.git"],
                 ["git", "fetch", "-q", "--depth", "1", "origin", DECOMP_COMMIT], ["git", "checkout", "-q", "FETCH_HEAD"]]
        if all(subprocess.run(step, cwd=staging, capture_output=True).returncode == 0 for step in steps):
            shutil.rmtree(decomp, ignore_errors=True)
            staging.rename(decomp)
            return decomp
        shutil.rmtree(staging, ignore_errors=True)
    url = f"https://codeload.github.com/{DECOMP_REPO}/zip/{DECOMP_COMMIT}"
    try:
        with urllib.request.urlopen(url, timeout=120) as response:
            blob = response.read()
    except OSError as error:
        raise AssetError(f"Couldn't download the asset extractors from GitHub: {error}. "
                         f"You can also clone https://github.com/{DECOMP_REPO} into {decomp}.") from error
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        prefix = archive.namelist()[0].split("/")[0] + "/"
        for member in archive.infolist():
            name = member.filename[len(prefix):]
            # Only the Python extractors, their configs and the docs that name things.
            if not name or not name.startswith(("scripts/", "config/", "docs/evidence/assets/", "LICENSE")):
                continue
            target = staging / name
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(member))
    (staging / "COMMIT").write_text(DECOMP_COMMIT + "\n", encoding="utf-8")
    shutil.rmtree(decomp, ignore_errors=True)
    staging.rename(decomp)
    return decomp


SHIM = Path(__file__).resolve().parent / "decomp_shim.py"
PATCH_LEVEL = "1"
_RELATIVE_STR = re.compile(r"str\(([A-Za-z_][\w.]*)\.relative_to\(([^()]*(?:\([^()]*\))?[^()]*)\)\)")


def prepare_decomp(decomp: Path) -> None:
    """Small portability fixes to our pinned copy (the decomp is developed on Linux and macOS).

    Its manifests store paths with '/', but `str(path.relative_to(root))` gives '\\' on
    Windows, so lookups like the scene composer's fail there ("inspection source lacks a
    unique ROM model record"). `.as_posix()` gives '/' everywhere.
    """
    marker = decomp / ".conker-maker-patched"
    if marker.is_file() and marker.read_text(encoding="utf-8").strip() == PATCH_LEVEL:
        return
    for script in (decomp / "scripts").rglob("*.py"):
        text = script.read_text(encoding="utf-8")
        fixed = _RELATIVE_STR.sub(r"\1.relative_to(\2).as_posix()", text)
        if fixed != text:
            script.write_text(fixed, encoding="utf-8")
    marker.write_text(PATCH_LEVEL + "\n", encoding="utf-8")


def ensure_numpy(log) -> bool:
    """The music renderer needs NumPy: use it if it's there, otherwise try installing it."""
    check = [sys.executable, "-c", "import numpy"]
    if subprocess.run(check, capture_output=True).returncode == 0:
        return True
    install = subprocess.run([sys.executable, "-m", "pip", "install", "--user", "--quiet", "numpy"],
                             capture_output=True, text=True)
    log.write(f"$ pip install numpy\n{install.stdout}{install.stderr}\n")
    return subprocess.run(check, capture_output=True).returncode == 0


def _run(decomp: Path, args: list[str], log, alias: str = "") -> None:
    command = [sys.executable, str(SHIM), *args]
    # UTF-8 mode: on Windows, files opened without an encoding would otherwise be read as cp1252.
    env = {**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1", "CM_ROM_ALIAS": alias}
    process = subprocess.run(command, cwd=decomp, capture_output=True, text=True, env=env)
    log.write(f"$ {' '.join(command)}\n{process.stdout}{process.stderr}\n")
    log.flush()
    if process.returncode != 0:
        lines = (process.stderr or process.stdout).strip().splitlines()
        raise AssetError(lines[-1] if lines else f"exit code {process.returncode}")


# --- import ----------------------------------------------------------------------------------

def import_assets(rom_path: str | Path, library: str | Path | None = None, decomp: str | Path | None = None,
                  scenes: bool = True, say=print) -> dict:
    """Extract everything the ROM can give. A step that fails (for example on assets a ROM hack
    changed) is skipped with a warning; the import only fails if no models came out at all."""
    if sys.version_info < (3, 12):
        raise AssetError(f"Importing ROM assets needs Python 3.12 or newer (this is {sys.version.split()[0]}).")
    rom = romlib.load(rom_path)
    library = (Path(library) if library else default_library(rom)).resolve()
    library.mkdir(parents=True, exist_ok=True)
    status_path = library / "status.json"
    steps = 1 + len(TEXTURE_FAMILIES) + len(MODEL_BANKS) + (1 if scenes else 0) + 2 + 1
    state = {"state": "running", "step": 0, "steps": steps, "message": "", "started": time.time(), "warnings": []}
    us_sha1 = next(sha for sha, (kind, _) in romlib.KNOWN.items() if kind == "us")
    alias = "" if rom.sha1 == us_sha1 else f"{rom.sha1}:{us_sha1}"

    def progress(message: str) -> None:
        state["step"] += 1
        state["message"] = message
        status_path.write_text(json.dumps(state), encoding="utf-8")
        say(f"[{state['step']}/{steps}] {message}")

    def attempt(what: str, args: list[str], log) -> bool:
        try:
            _run(decomp_dir, args, log, alias)
            return True
        except AssetError as error:
            state["warnings"].append(f"{what}: {error}")
            say(f"    skipped {what}: {error}")
            return False

    work = library / "_work"
    work.mkdir(exist_ok=True)
    rom_file = work / "baserom.us.z64"
    try:
        progress("Getting the asset extractors")
        decomp_dir = ensure_decomp((Path(decomp) if decomp else default_decomp_dir()).resolve(), say)
        prepare_decomp(decomp_dir)
        rom_file.write_bytes(rom.data)   # the extractors want a big-endian .z64
        textures = library / "textures"
        with open(library / "import.log", "w", encoding="utf-8") as log:
            log.write(f"ROM: {rom.description} ({rom.sha1}){' - read as an asset hack of US' if alias else ''}\n")
            for family, folder in TEXTURE_FAMILIES:
                progress(f"Extracting textures ({family})")
                shutil.rmtree(textures / folder, ignore_errors=True)
                attempt(f"textures ({family})", ["scripts/texture_assets.py", "extract", "--family", family,
                                                 "--rom", str(rom_file), "--output", str(textures / folder)], log)
            models = library / "models"
            for bank in MODEL_BANKS:
                progress(f"Extracting models (bank {bank}{', with animations' if bank == '01' else ''})")
                out = models / f"us-bank-{bank}-preview"
                shutil.rmtree(out, ignore_errors=True)
                args = ["scripts/model_assets.py", "preview", "--bank", bank, "--rom", str(rom_file),
                        "--textures", str(textures), "--output", str(out), "--skip-blender", "--skip-renders"]
                if bank == "01":
                    args.append("--rom-defaults")
                if not attempt(f"models (bank {bank})", args, log):
                    shutil.rmtree(out, ignore_errors=True)
            if scenes:
                progress("Building the levels (the slowest step)")
                shutil.rmtree(library / "levels", ignore_errors=True)
                shutil.rmtree(library / "scenes", ignore_errors=True)   # the older, partial set
                # The composer only accepts model folders inside its own checkout: lend it ours.
                lent = decomp_dir / "build" / "conker-maker-models"
                shutil.rmtree(lent, ignore_errors=True)
                lent.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(models), str(lent))
                try:
                    if not attempt("levels", [str(Path(__file__).resolve().parent / "decomp_levels.py"), str(rom_file),
                                              str(lent), str(library / "levels")], log):
                        shutil.rmtree(library / "levels", ignore_errors=True)
                finally:
                    shutil.move(str(lent), str(models))
            progress("Extracting music, voices and sounds")
            audio = library / "audio"
            shutil.rmtree(audio, ignore_errors=True)
            rom_arg = ["--rom", str(rom_file)]
            attempt("sound bank and music", ["scripts/audio_assets.py", "extract", *rom_arg, "--output", str(audio / "source")], log)
            attempt("MP3 streams", ["scripts/mp3_assets.py", "extract", *rom_arg, "--output", str(audio / "mp3")], log)
            attempt("voice cues", ["scripts/mp3_assets.py", "cue-extract", *rom_arg, "--output", str(audio / "cues")], log)
            progress("Playing the music through the game's instruments")
            if (audio / "source" / "manifest.json").is_file():
                if ensure_numpy(log):
                    attempt("music renders", ["scripts/audio_assets.py", "soundtrack-preview", "--input", str(audio / "source"),
                                              "--mp3-input", str(audio / "mp3"), "--output", str(audio / "preview")], log)
                else:
                    state["warnings"].append("music renders: needs NumPy (python -m pip install numpy), so music is MIDI only")
        progress("Building the catalog")
        catalog = build_catalog(library, decomp_dir, rom)
        if not catalog["models"]:
            raise AssetError("No models could be read from this ROM.\n" + "\n".join(state["warnings"]))
    except Exception as error:
        state.update(state="failed", message=str(error))
        status_path.write_text(json.dumps(state), encoding="utf-8")
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)   # don't leave a copy of the ROM around
    state.update(state="done", message=f"{len(catalog['models'])} models and {len(catalog['scenes'])} scenes",
                 finished=time.time())
    status_path.write_text(json.dumps(state), encoding="utf-8")
    return {"library": str(library), "models": len(catalog["models"]), "scenes": len(catalog["scenes"]),
            "warnings": state["warnings"], "seconds": round(state["finished"] - state["started"])}


# --- catalog ---------------------------------------------------------------------------------

def model_id(bank: int, entry: int, segment: int) -> str:
    return f"b{bank:02d}-{entry:04d}-{segment:02d}"


def _labels(decomp: Path) -> dict:
    """Names and categories from the decomp's reviewed gallery, keyed by model id."""
    labels: dict[str, dict] = {}
    path = decomp / "config" / "model-inspection.json"
    if not path.is_file():
        return labels
    special = {"conker-rom-defaults": (1, 0, 0), "haybot-rom-defaults": (1, 75, 0)}
    for record in json.loads(path.read_text(encoding="utf-8")).get("models", []):
        case = record.get("render_case", "")
        found = special.get(case)
        match = re.search(r"bank(\d\d)-(\d{4})(?:-(\d\d))?-rom$", case)
        if match:
            found = (int(match[1]), int(match[2]), int(match[3] or 0))
        if not found:
            continue
        name = re.split(r" — (?:ROM|ROM bank) \d\d", record.get("label", ""))[0].strip()
        name = name.replace(" — ROM defaults and animations", "")
        labels[model_id(*found)] = {"name": name or None, "category": record.get("category")}
    return labels


def _scene_names(decomp: Path) -> dict[int, str]:
    names: dict[int, str] = {}
    path = decomp / "docs" / "evidence" / "assets" / "models" / "us_static_scene_assemblies.md"
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.match(r"\| (\d+) \| ([^|;]+)", line)
            if match:
                names[int(match[1])] = match[2].strip()
    return names


def audio_catalog(library: Path) -> dict:
    """Music (named sequences), streamed music, voices and other streams, sound samples."""
    audio = library / "audio"
    result = {"music": [], "music_streams": [], "streams": [], "samples": []}
    preview = audio / "preview" / "manifest.json"
    source = audio / "source" / "manifest.json"
    if preview.is_file():
        data = json.loads(preview.read_text(encoding="utf-8"))
        for seq in data.get("sequences", []):
            result["music"].append({"index": seq["index"], "name": seq.get("name") or f"Unidentified {seq['index']:04d}",
                                    "category": seq.get("category") or ("Unidentified" if not seq.get("name") else "Other"),
                                    "confidence": seq.get("confidence"), "note": seq.get("note", ""),
                                    "wav": f"audio/preview/{seq['file']}" if seq.get("file") else None,
                                    "midi": f"audio/preview/{seq['midi_file']}" if seq.get("midi_file") else None})
        for stream in data.get("music_streams", []):
            result["music_streams"].append({"index": stream["index"], "name": stream.get("name"),
                                            "confidence": stream.get("confidence")})
    elif source.is_file():   # no renders (no NumPy): MIDI files and the names from the decomp's labels
        labels = {}
        label_path = default_decomp_dir() / "config" / "audio-sequences.json"
        if label_path.is_file():
            labels = {s["index"]: s for s in json.loads(label_path.read_text(encoding="utf-8")).get("sequences", [])}
        for cseq in sorted((audio / "source" / "sequences").glob("*.cseq")):
            index = int(cseq.stem)
            label = labels.get(index, {})
            result["music"].append({"index": index, "name": label.get("name") or f"Unidentified {index:04d}",
                                    "category": label.get("category") or "Other", "confidence": label.get("confidence"),
                                    "note": label.get("note", ""), "wav": None, "midi": None,
                                    "cseq": f"audio/source/sequences/{cseq.name}"})
    cues = audio / "cues" / "manifest.json"
    if cues.is_file():
        named = {s["index"] for s in result["music_streams"]}
        for stream in json.loads(cues.read_text(encoding="utf-8")).get("streams", []):
            index = stream["entry_index"]
            kind = "music" if index in named else ("voice" if stream.get("cue_count") else "other")
            result["streams"].append({"index": index, "kind": kind, "seconds": round(stream.get("duration_seconds", 0), 1),
                                      "file": f"audio/mp3/streams/{index:04d}.mp3"})
    graph = audio / "source" / "sound-bank-graph.json"
    if graph.is_file():
        data = json.loads(graph.read_text(encoding="utf-8"))
        instrument_of = {s["index"]: s["instrument_index"] for s in data.get("sounds", [])}
        for sample in data.get("samples", []):
            instruments = sorted({instrument_of.get(w, -1) for w in sample.get("wavetable_indices", [])})
            result["samples"].append({"index": sample["index"], "instruments": instruments,
                                      "wav": f"audio/preview/samples/{sample['index']:04d}.wav"})
    return result


def level_names() -> dict:
    """Your names for levels (catalog/level_names.json), by scene index: edit it to rename them."""
    path = ROOT / "catalog" / "level_names.json"
    if not path.is_file():
        return {}
    return {k: v for k, v in json.loads(path.read_text(encoding="utf-8")).get("names", {}).items() if v}


def level_descriptions() -> dict:
    path = ROOT / "catalog" / "level_names.json"
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8")).get("descriptions", {})


def _skeleton_signature(gltf: Path) -> tuple | None:
    """The joint hierarchy of a skinned model (each joint's parent), or None if it has no skin."""
    try:
        doc = json.loads(gltf.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    skins = doc.get("skins") or []
    if not skins:
        return None
    joints = skins[0]["joints"]
    parent = {}
    for index, node in enumerate(doc.get("nodes", [])):
        for child in node.get("children", []):
            parent[child] = index
    position = {node: i for i, node in enumerate(joints)}
    return tuple(position.get(parent.get(j), -1) for j in joints)


def animation_donors(library: Path, models: list[dict]) -> dict[str, str]:
    """Characters stored without animations (the Tedi soldiers, the General...) share a skeleton
    with one that has them: borrow those. Prefers a donor with a similar name."""
    signatures, animated = {}, {}
    for m in models:
        if m["bank"] != 1 or m.get("category") != "characters":
            continue
        sig = _skeleton_signature(library / m["path"])
        if sig is None or len(sig) < 4:
            continue
        signatures[m["id"]] = sig
        if m["animations"] > 0:
            animated.setdefault(sig, []).append(m)
    donors = {}
    for m in models:
        sig = signatures.get(m["id"])
        if sig is None or m["animations"] > 0 or sig not in animated:
            continue
        stem = re.sub(r"[^a-z]", "", m["name"].lower())[:4]
        best = max(animated[sig], key=lambda d: (bool(stem) and re.sub(r"[^a-z]", "", d["name"].lower())[:4] == stem,
                                                 d.get("named", False), d["animations"]))
        donors[m["id"]] = best["id"]
    return donors


def build_catalog(library: Path, decomp: Path, rom: romlib.Rom) -> dict:
    labels = _labels(decomp)
    models = []
    for bank in MODEL_BANKS:
        folder = library / "models" / f"us-bank-{bank}-preview"
        manifest_path = folder / "manifest.json"
        if not manifest_path.is_file():
            continue
        for record in json.loads(manifest_path.read_text(encoding="utf-8")).get("models", []):
            if not record.get("gltf_file") or not record.get("face_count"):
                continue
            b, entry, segment = int(bank), record["bank_entry"], record["segment"]
            mid = model_id(b, entry, segment)
            label = labels.get(mid, {})
            # Unnamed pieces get their own groups so the named ones are easy to find.
            category = label.get("category") or ("characters" if b == 1 else "level-pieces" if b == 4 else "other-objects")
            models.append({
                "id": mid, "bank": b, "entry": entry, "segment": segment,
                "name": label.get("name") or f"{BANK_LABELS[b]} {entry:04d}/{segment:02d}",
                "named": bool(label.get("name")),
                "category": category,
                "path": f"models/us-bank-{bank}-preview/{record['gltf_file']}",
                "faces": record["face_count"],
                "animations": record.get("animation_clip_count", 0) or 0,
            })
    models.sort(key=lambda m: (not m["named"], m["name"].lower()))
    for mid, donor in animation_donors(library, models).items():
        for m in models:
            if m["id"] == mid:
                m["anim_from"] = donor
    scene_names = _scene_names(decomp)
    scenes = []
    nicknames = level_names()
    extra_descriptions = level_descriptions()
    levels_index = library / "levels" / "levels.json"
    if levels_index.is_file():
        for record in json.loads(levels_index.read_text(encoding="utf-8")).get("levels", []):
            index = record["index"]
            if not (library / "levels" / record["path"]).is_file():
                continue
            description = (scene_names.get(index) or extra_descriptions.get(str(index))
                           or "Complete scene (no description yet)")
            nickname = nicknames.get(str(index), "")
            scenes.append({"id": f"scene-{index:02d}", "index": index,
                           "name": f"{nickname} — {description}" if nickname else description,
                           "nickname": nickname, "description": description,
                           "reviewed": record.get("reviewed", False), "faces": record.get("faces", 0),
                           "path": f"levels/{record['path']}"})
    scenes.sort(key=lambda s: s["index"])
    catalog_audio = audio_catalog(library)
    catalog = {
        "format": CATALOG_FORMAT, "library_version": LIBRARY_VERSION, "catalog_revision": CATALOG_REVISION,
        "rom_sha1": rom.sha1, "rom_kind": rom.kind,
        "decomp": {"repo": DECOMP_REPO, "commit": DECOMP_COMMIT},
        "world_scale": WORLD_SCALE,
        "categories": CATEGORY_LABELS,
        "models": models, "scenes": scenes, "audio": catalog_audio,
    }
    (library / "catalog.json").write_text(json.dumps(catalog, indent=1), encoding="utf-8")
    return catalog
