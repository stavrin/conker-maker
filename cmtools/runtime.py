"""The runtime block: the part of a game the obd_core mod reads inside the real game.

The full project travels as compressed JSON (package.py), which is handy for tools but too much
for a small N64 mod to unpack. So the build also writes this flat, uncompressed table of just what
the mod can act on today. Everything is big-endian, as the N64 reads it.

    header (0x28 bytes)
        0x00 'CMRT'
        0x04 u16 version (RUNTIME_VERSION)
        0x06 u16 level count
        0x08 u16 event count
        0x0A u16 condition count
        0x0C u16 action count
        0x0E u16 start level (index, 0xFFFF none)
        0x10 u32 offset of levels      (from the start of the block)
        0x14 u32 offset of events
        0x18 u32 offset of conditions / actions follow the conditions directly
        0x1C u32 offset of strings
        0x20 u32 offset of game actors (v2)
        0x24 u16 game actor count, u16 0
    level (0x18 bytes)
        s16 game scene (the scene_in_play value; -1 for a level not built on a game scene)
        u16 flags (1 = has a start position)
        f32 x, y, z of Conker's start, in game units
        u16 angle (0x10000 = a full turn)
        u16 first event, u16 event count
        u16 name (string)
        u16 first game actor, u16 game actor count (v2)
    game actor (0x0C bytes): u8 actor number, u8 angle (0x100 a full turn), s16 x, y, z, u16 0, u16 0
        The mod turns each into one of the game's 48-byte actor placement records and appends it
        to the scene's actor table as the scene loads (see docs/ACTORS.md).
    event (0x0C bytes)
        u8 trigger (TRIGGERS), u8 flags (1 = cutscene)
        u16 subject (string: the object the trigger is about, or NONE)
        u16 first condition, u16 condition count
        u16 first action, u16 action count
    condition (0x08 bytes): u8 type (CONDITIONS), u8 0, u16 string, s32 value
    action (0x0C bytes):    u8 type (ACTIONS), u8 0, u16 a, u16 b, u16 0, s32 value
        say: a = speaker, b = text. give/take_cash: value = amount. set_flag: a = flag.
        wait: value = milliseconds. goto_level: value = level index. Any other action is
        written as OTHER with a = its type name, so the mod can say what it skipped.
    strings: NUL-terminated UTF-8; a string is its offset into this table (NONE = 0xFFFF).
"""
from __future__ import annotations

import struct

MAGIC = b"CMRT"
RUNTIME_VERSION = 2
NONE = 0xFFFF

TRIGGERS = {"level_start": 1, "enter_zone": 2, "press_pad": 3, "talk_to": 4, "defeat": 5,
            "all_cash": 6, "pick_up": 7, "deliver": 8}
CONDITIONS = {"flag_set": 1, "flag_not_set": 2, "cash_at_least": 3}
ACTIONS = {"other": 0, "say": 1, "give_cash": 2, "take_cash": 3, "set_flag": 4, "wait": 5,
           "goto_level": 6}

HEADER = struct.Struct(">4sHHHHHHIIIIIHH")
LEVEL = struct.Struct(">hHfffHHHHHH")
ACTOR = struct.Struct(">BBhhhHH")
EVENT = struct.Struct(">BBHHHHH")
CONDITION = struct.Struct(">BBHi")
ACTION = struct.Struct(">BBHHHi")

GAME_UNITS_PER_METRE = 100.0   # the editor shows the game's world at 0.01 (Rom.world_scale)


class RuntimeError_(Exception):
    pass


def game_angle(rotation_y: float) -> int:
    """An editor turn (degrees, positive turns to face -X) as the game's u16 angle.

    The game's 0 looks down -Z like the editor's, but its angle grows toward +X, the other way.
    Unconfirmed until it's checked in the real game (the mod's position log is for that)."""
    return int(round(-float(rotation_y) / 360.0 * 65536.0)) & 0xFFFF


def game_scene(level: dict) -> int:
    base = level.get("base", {})
    if "game_scene" in base:   # set by hand once the mapping for a scene is known
        return int(base["game_scene"])
    if base.get("kind") == "rom_scene":
        return int(str(base.get("scene", "scene--1")).split("-")[1])
    return -1


class _Strings:
    def __init__(self) -> None:
        self.data = bytearray()
        self.seen: dict[str, int] = {}

    def __call__(self, text) -> int:
        if text is None or text == "":
            return NONE
        text = str(text)
        if text not in self.seen:
            if len(self.data) >= NONE:
                raise RuntimeError_("The game has too much text for the runtime (64 KB).")
            self.seen[text] = len(self.data)
            self.data += text.encode("utf-8") + b"\0"
        return self.seen[text]


def build(game: dict) -> bytes:
    strings = _Strings()
    level_ids = list(game.get("levels", {}))
    levels, events, conditions, actions, actors = [], [], [], [], []
    for level_id in level_ids:
        level = game["levels"][level_id]
        start = next((o for o in level.get("objects", []) if o.get("type") == "player_start"), None)
        first_event = len(events)
        for event in level.get("events", []):
            when = event.get("when", {})
            first_condition = len(conditions)
            for c in event.get("only_if", []):
                kind = CONDITIONS.get(c.get("type"))
                if kind is None:
                    continue
                conditions.append(CONDITION.pack(kind, 0, strings(c.get("flag")), int(c.get("amount", 0))))
            first_action = len(actions)
            for a in event.get("do", []):
                actions.append(_action(a, strings, level_ids))
            events.append(EVENT.pack(TRIGGERS.get(when.get("type"), 0), 1 if event.get("cutscene") else 0,
                                     strings(when.get("object")),
                                     first_condition, len(conditions) - first_condition,
                                     first_action, len(actions) - first_action))
        first_actor = len(actors)
        for o in level.get("objects", []):
            if o.get("type") != "game_actor":
                continue
            x, y, z = (_s16(float(v) * GAME_UNITS_PER_METRE) for v in o.get("position", [0, 0, 0]))
            actors.append(ACTOR.pack(int(o.get("props", {}).get("actor", 0)) & 0xFF,
                                     game_angle(o.get("rotation_y", 0)) >> 8, x, y, z, 0, 0))
        pos = [float(v) * GAME_UNITS_PER_METRE for v in (start or {}).get("position", [0, 0, 0])]
        levels.append(LEVEL.pack(game_scene(level), 1 if start else 0, *pos,
                                 game_angle((start or {}).get("rotation_y", 0)),
                                 first_event, len(events) - first_event,
                                 strings(level.get("title", level_id)),
                                 first_actor, len(actors) - first_actor))
    for name, count in (("levels", len(levels)), ("events", len(events)), ("actions", len(actions))):
        if count >= NONE:
            raise RuntimeError_(f"The game has too many {name} for the runtime.")

    off_levels = HEADER.size
    off_events = off_levels + LEVEL.size * len(levels)
    off_conditions = off_events + EVENT.size * len(events)
    off_actors = off_conditions + CONDITION.size * len(conditions) + ACTION.size * len(actions)
    off_strings = off_actors + ACTOR.size * len(actors)
    start = level_ids.index(game["start_level"]) if game.get("start_level") in level_ids else NONE
    blob = HEADER.pack(MAGIC, RUNTIME_VERSION, len(levels), len(events), len(conditions), len(actions),
                       start, off_levels, off_events, off_conditions, off_strings, off_actors, len(actors), 0)
    blob += b"".join(levels) + b"".join(events) + b"".join(conditions) + b"".join(actions) + b"".join(actors)
    blob += bytes(strings.data)
    return blob + bytes(-len(blob) % 16)


def _s16(v: float) -> int:
    v = int(round(v))
    if not -32768 <= v <= 32767:
        raise RuntimeError_("A game actor is too far from the middle of the level for the game (327 m).")
    return v


def _action(a: dict, strings: _Strings, level_ids: list[str]) -> bytes:
    kind = a.get("type")
    if kind == "say":
        return ACTION.pack(ACTIONS["say"], 0, strings(a.get("speaker")), strings(a.get("text")), 0, 0)
    if kind in ("give_cash", "take_cash"):
        return ACTION.pack(ACTIONS[kind], 0, NONE, NONE, 0, int(a.get("amount", 0)))
    if kind == "set_flag":
        return ACTION.pack(ACTIONS["set_flag"], 0, strings(a.get("flag")), NONE, 0, 0)
    if kind == "wait":
        return ACTION.pack(ACTIONS["wait"], 0, NONE, NONE, 0, int(round(float(a.get("seconds", 0)) * 1000)))
    if kind == "goto_level" and a.get("level") in level_ids:
        return ACTION.pack(ACTIONS["goto_level"], 0, strings(a.get("level")), NONE, 0, level_ids.index(a["level"]))
    return ACTION.pack(ACTIONS["other"], 0, strings(kind), NONE, 0, 0)


def read(blob: bytes) -> dict:
    """The block back as plain data (for tests and for checking a built ROM)."""
    (magic, version, n_levels, n_events, n_conditions, n_actions, start,
     off_levels, off_events, off_conditions, off_strings, off_actors, n_actors, _) = HEADER.unpack_from(blob)
    if magic != MAGIC:
        raise RuntimeError_("no runtime block here")

    def text(offset: int):
        if offset == NONE:
            return None
        end = blob.index(b"\0", off_strings + offset)
        return blob[off_strings + offset:end].decode("utf-8")

    names = {v: k for k, v in ACTIONS.items()}
    off_actions = off_conditions + CONDITION.size * n_conditions
    result = {"version": version, "start_level": None if start == NONE else start,
              "levels": [], "events": [], "conditions": [], "actions": [], "actors": []}
    for i in range(n_levels):
        scene, flags, x, y, z, angle, fe, ne, name, fa, na = LEVEL.unpack_from(blob, off_levels + i * LEVEL.size)
        result["levels"].append({"scene": scene, "has_start": bool(flags & 1), "position": [x, y, z],
                                 "angle": angle, "events": [fe, ne], "name": text(name), "actors": [fa, na]})
    for i in range(n_actors):
        actor, angle, x, y, z, _, _ = ACTOR.unpack_from(blob, off_actors + i * ACTOR.size)
        result["actors"].append({"actor": actor, "angle": angle, "position": [x, y, z]})
    for i in range(n_events):
        trig, flags, subject, fc, nc, fa, na = EVENT.unpack_from(blob, off_events + i * EVENT.size)
        result["events"].append({"trigger": trig, "cutscene": bool(flags & 1), "subject": text(subject),
                                 "conditions": [fc, nc], "actions": [fa, na]})
    for i in range(n_conditions):
        kind, _, s, value = CONDITION.unpack_from(blob, off_conditions + i * CONDITION.size)
        result["conditions"].append({"type": kind, "text": text(s), "value": value})
    for i in range(n_actions):
        kind, _, a, b, _, value = ACTION.unpack_from(blob, off_actions + i * ACTION.size)
        result["actions"].append({"type": names.get(kind, kind), "a": text(a), "b": text(b), "value": value})
    return result
