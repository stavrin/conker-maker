"""Import Bad Fur Day's models, textures and level scenes from the player's own ROM.

Conker Maker never ships Rare's assets. Instead, this turns the player's ROM into a
local *asset library* that the app shows in its palette, inspector and preview:

    <library>/
      catalog.json            every model and scene, with names and categories
      status.json             progress while importing (the app polls it)
      models/us-bank-NN-preview/geometry/*.gltf   (+ .bin, ../textures/*.png)
      scenes/geometry/scene-NN.gltf               composed level scenes

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
LIBRARY_VERSION = 1
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
    steps = 1 + len(TEXTURE_FAMILIES) + len(MODEL_BANKS) + (1 if scenes else 0) + 1
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
                progress("Composing level scenes (the slowest step)")
                shutil.rmtree(library / "scenes", ignore_errors=True)
                # The composer only accepts model folders inside its own checkout: lend it ours.
                lent = decomp_dir / "build" / "conker-maker-models"
                shutil.rmtree(lent, ignore_errors=True)
                lent.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(models), str(lent))
                try:
                    if not attempt("level scenes", ["scripts/model_assets.py", "scene-assemblies", "--rom", str(rom_file),
                                                    "--model-root", str(lent), "--output", str(library / "scenes")], log):
                        shutil.rmtree(library / "scenes", ignore_errors=True)
                finally:
                    shutil.move(str(lent), str(models))
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
            category = label.get("category") or ("characters" if b == 1 else "scene-items")
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
    scene_names = _scene_names(decomp)
    scenes = []
    scenes_manifest = library / "scenes" / "manifest.json"
    if scenes_manifest.is_file():
        for record in json.loads(scenes_manifest.read_text(encoding="utf-8")).get("models", []):
            index = record["scene_index"]
            path = library / "scenes" / "geometry" / f"scene-{index:02d}.gltf"
            if path.is_file():
                scenes.append({"id": f"scene-{index:02d}", "index": index,
                               "name": scene_names.get(index, f"Scene {index}"),
                               "path": f"scenes/geometry/scene-{index:02d}.gltf"})
    scenes.sort(key=lambda s: s["index"])
    catalog = {
        "format": CATALOG_FORMAT, "library_version": LIBRARY_VERSION,
        "rom_sha1": rom.sha1, "rom_kind": rom.kind,
        "decomp": {"repo": DECOMP_REPO, "commit": DECOMP_COMMIT},
        "world_scale": WORLD_SCALE,
        "categories": CATEGORY_LABELS,
        "models": models, "scenes": scenes,
    }
    (library / "catalog.json").write_text(json.dumps(catalog, indent=1), encoding="utf-8")
    return catalog
