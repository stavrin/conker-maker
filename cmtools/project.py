"""Conker Maker projects: a folder of JSON files describing a whole game.

    MyGame/
      game.json            title, chapters (which levels, in what order), start level
      levels/<id>.json     one per level: objects placed in it, and its events
      assets/              (later) your own models, textures, sounds

Everything is plain JSON so it diffs nicely in git and can be edited by hand if you
ever want to. The app reads and writes the same files.
"""
from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

GAME_FORMAT = "conker-maker-project-v1"
LEVEL_FORMAT = "conker-maker-level-v1"
ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / "catalog" / "objects.json"
TEMPLATE = ROOT / "templates" / "new_game"
ID_RE = re.compile(r"^[a-z0-9_]{1,32}$")


class ProjectError(Exception):
    pass


def catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def load(project_dir: str | Path) -> dict:
    """The whole project as one dict: game.json plus a 'levels' map of id -> level."""
    project_dir = Path(project_dir)
    game_path = project_dir / "game.json"
    if not game_path.is_file():
        raise ProjectError(f"{project_dir} has no game.json; is it a Conker Maker project?")
    game = json.loads(game_path.read_text(encoding="utf-8"))
    game["levels"] = {}
    for path in sorted((project_dir / "levels").glob("*.json")):
        level = json.loads(path.read_text(encoding="utf-8"))
        game["levels"][level.get("id", path.stem)] = level
    return game


def validate(game: dict) -> list[str]:
    """Problems a player would hit, in plain words. Empty means good to build."""
    cat = catalog()
    types, triggers, actions = cat["objects"], cat["events"]["triggers"], cat["events"]["actions"]
    problems: list[str] = []
    if game.get("format") != GAME_FORMAT:
        problems.append(f"game.json: format should be '{GAME_FORMAT}'.")
    if not str(game.get("title", "")).strip():
        problems.append("game.json: the game needs a title.")
    levels = game.get("levels", {})
    if not levels:
        problems.append("The game has no levels yet.")
    if game.get("start_level") not in levels:
        problems.append(f"game.json: start_level '{game.get('start_level')}' isn't one of your levels.")
    for chapter in game.get("chapters", []):
        for level_id in chapter.get("levels", []):
            if level_id not in levels:
                problems.append(f"Chapter '{chapter.get('title')}' lists a level '{level_id}' that doesn't exist.")

    for level_id, level in levels.items():
        where = f"Level '{level.get('title', level_id)}'"
        if level.get("format") != LEVEL_FORMAT:
            problems.append(f"{where}: format should be '{LEVEL_FORMAT}'.")
        if not ID_RE.match(level_id):
            problems.append(f"{where}: id '{level_id}' should be lower-case letters, digits and _ only.")
        base = level.get("base", {})
        if base.get("kind", "blank") not in ("blank", "rom_scene"):
            problems.append(f"{where}: unknown base '{base.get('kind')}'.")
        elif base.get("kind") == "rom_scene" and not re.match(r"^scene-\d\d$", str(base.get("scene", ""))):
            problems.append(f"{where}: stands on a Bad Fur Day scene but doesn't say which.")
        objects = level.get("objects", [])
        uids = [o.get("uid") for o in objects]
        dupes = {u for u in uids if uids.count(u) > 1}
        if dupes:
            problems.append(f"{where}: more than one object is called {', '.join(sorted(map(str, dupes)))}.")
        by_uid = {o.get("uid"): o for o in objects}
        for obj in objects:
            kind = obj.get("type")
            if kind not in types:
                problems.append(f"{where}: '{obj.get('uid')}' has an unknown type '{kind}'.")
                continue
            pos = obj.get("position")
            if not (isinstance(pos, list) and len(pos) == 3 and all(isinstance(v, (int, float)) for v in pos)):
                problems.append(f"{where}: '{obj.get('uid')}' needs a position [x, y, z].")
            model = obj.get("props", {}).get("model")
            if model is not None and not (isinstance(model, dict) and re.match(r"^b\d\d-\d{4}-\d\d$", str(model.get("id", "")))):
                problems.append(f"{where}: '{obj.get('uid')}' has a model that isn't a ROM model reference.")
            if kind == "level_exit":
                target = obj.get("props", {}).get("target_level")
                if target not in levels:
                    problems.append(f"{where}: exit '{obj.get('uid')}' goes to '{target}', which isn't a level.")
        starts = sum(1 for o in objects if o.get("type") == "player_start")
        if starts != 1:
            problems.append(f"{where}: needs exactly one Conker Start (has {starts}).")
        for event in level.get("events", []):
            label = f"{where}, event '{event.get('name', event.get('id'))}'"
            when = event.get("when", {})
            trig = triggers.get(when.get("type"))
            if trig is None:
                problems.append(f"{label}: unknown trigger '{when.get('type')}'.")
            elif trig["object"]:
                target = by_uid.get(when.get("object"))
                if target is None or target.get("type") != trig["object"]:
                    problems.append(f"{label}: '{trig['label']}' needs a {types[trig['object']]['label']}.")
            for action in event.get("do", []):
                spec = actions.get(action.get("type"))
                if spec is None:
                    problems.append(f"{label}: unknown action '{action.get('type')}'.")
                    continue
                for field, kind in spec["fields"].items():
                    value = action.get(field)
                    if kind == "object" and value not in by_uid:
                        problems.append(f"{label}: '{spec['label']}' points at a missing object '{value}'.")
                    if kind == "level" and value not in levels:
                        problems.append(f"{label}: '{spec['label']}' points at a missing level '{value}'.")
    return problems


def new_project(project_dir: str | Path, title: str) -> Path:
    project_dir = Path(project_dir)
    if project_dir.exists() and any(project_dir.iterdir()):
        raise ProjectError(f"{project_dir} already exists and isn't empty.")
    shutil.copytree(TEMPLATE, project_dir, dirs_exist_ok=True)
    game_path = project_dir / "game.json"
    game = json.loads(game_path.read_text(encoding="utf-8"))
    game["title"] = title
    game_path.write_text(json.dumps(game, indent=2) + "\n", encoding="utf-8")
    return project_dir


def slug(title: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "_", title).strip("_") or "game"
