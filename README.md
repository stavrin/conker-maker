# Conker Maker

Make your own Conker game: levels, characters, pickups, dialogue and events, built
visually and played in **Conker's Bad Fur Day: Recompiled**. The first game it's for is
*Conker's Other Bad Day*.

Conker Maker needs **your own** US ROM of Conker's Bad Fur Day (the uncensored hack works
too). It never ships or shares game data: games are shared as `.bps` patches that
players apply to their own ROM.

See **[docs/DESIGN.md](docs/DESIGN.md)** for how it works and the roadmap.

## What's here

| Folder | What |
| --- | --- |
| `app/` | The Conker Maker app (Godot 4.3+, tested on 4.7.2) |
| `cmtools/` | The build tools (Python): ROM check, asset import, validate, build, BPS patches |
| `catalog/` | The object types, events and scenes the editor offers |
| `templates/new_game/` | What a new project starts as: a two-level sample game |
| `runtime_mod/` | `obd_core`, the recomp mod that plays Conker Maker games |
| `tests/` | cmtools tests |
| `docs/` | Design and roadmap |

## Running the app (for now, from source)

1. Install [Godot 4.3 or newer](https://godotengine.org/download/) (tested on 4.3 and 4.7.2) (the
   standard version, not .NET) and Python 3.12 or later.
2. In Godot, **Import** `app/project.godot` (in the `conker-maker` folder), then press Play (F5).
3. Choose your ROM, create a game (pick an empty folder), and you're in the editor.
4. In the hub's **Settings**, point it at `ConkerRecomp.exe` to use **Playtest in recomp**.

### Using Bad Fur Day's own models and levels

In the project hub, **Assets from your ROM → Import assets from my ROM** reads every model,
texture, animation and level scene out of your ROM into a private library on your computer
(about 300 MB in `%LOCALAPPDATA%\ConkerMaker\library`, once per ROM; it takes 5 to 15 minutes).
It needs Python 3.12+ and, the first time, Git or internet access to fetch the extractors
(DevOldSchool's conkers-bfd-decomp, pinned to a tested commit, into `third_party/`).

After that:

- Conker, cash, chocolate, squirrel tails, B pads and checkpoints show their real models.
- **Browse models...** in the palette places any of ~1,500 models (crates, barrels, signs,
  fences, Tediz, Haybot...) as props, with a spinning preview and search.
- Any object's **Model → Choose from ROM...** in the inspector swaps its look.
- A level's **Stands on** can be any of 55 Bad Fur Day levels (**Browse Bad Fur Day levels...**
  shows them), which you can walk around in **Play here** as the real, animated Conker.
- Levels and events can play the game's music, listed by name (rendered with the game's own
  instruments; this needs NumPy, which the import installs if it can).
- **Export models, levels and sounds to a folder...** makes named, sorted copies for other
  programs: `.glb` models and levels, music as `.wav` + `.mid`, voices and streams as `.mp3`,
  sound effects and instrument samples as `.wav`. That folder isn't part of Conker Maker.
- Level names live in `catalog/level_names.json`: rename or correct them there, then click
  **Refresh level names** in the hub.

Editor controls:

| Do | How |
| --- | --- |
| Place something | Click it in the palette, then click in the level (right-click or Esc to stop) |
| Select / move | Click / drag (Shift-drag: up and down, hold Alt: no snapping) |
| Camera | Right-drag orbit, middle-drag pan, wheel zoom, F focus on the selection |
| Turn / tilt / duplicate / delete | Q and E (Shift: tilt forward/back, Alt: tilt left/right) / Ctrl+D / Delete |
| Undo / redo / save | Ctrl+Z / Ctrl+Y / Ctrl+S |
| Play here | WASD run (Shift: walk), Space jump (hold in the air to hover; jump at a high ledge to grab it, then Space/W climbs, S lets go), F or left click: frying pan (on the ground or in the air), E talk/press; in water: WASD swim, Space jumps out (underwater: swims up), C dives, swim into a low bank to climb out; mouse or arrows: camera (the pointer hides while you play; click to hide it again), wheel: zoom, walk into a Carried Item to pick it up, Tab skips a cutscene, Esc back |

## Using cmtools directly

From the `conker-maker` folder:

```
python -m cmtools check-rom "path\to\Conker's Bad Fur Day (USA).n64"
python -m cmtools import-assets --rom "path\to\rom.z64"
python -m cmtools build my_game --rom "path\to\rom.z64"
python -m cmtools apply "path\to\rom.z64" my_game\build\Conkers_Other_Bad_Day.bps out.z64
python -m unittest discover tests         (set CONKER_ROM=path to also test with your ROM)
```

## Building the runtime mod

On Linux, macOS or WSL, with a CBFD-Recompiled checkout whose `RecompModTool` is built:

```
sh runtime_mod/build.sh /path/to/CBFD-Recompiled
```

Copy `runtime_mod/build/conker_maker_runtime.nrm` into the recomp's `mods` folder and
enable it in the Mods menu. A prebuilt copy is in `runtime_mod/prebuilt/`.

### What the runtime plays so far (v0.3)

A level built on a game scene (its ground is a ROM scene) plays in that scene in the real
game: when the scene comes into play, Conker is put at the level's Conker Start and its
"Level starts" events run. Give/Take cash change his real wallet, story flags and waits
work, and lines are printed to the console (run ConkerRecomp from a terminal to see them).
Anything else (cameras, moving characters, showing and hiding objects) is named in the
console as skipped.

**Game Actor** objects (Characters group) are the game's own characters and things, by actor
number: the mod adds them to the scene's actor table and the game spawns them. What each
number is isn't named yet: [docs/ACTORS.md](docs/ACTORS.md) lists where each is used and how
the game spawns them. Other placed objects don't appear in the real game yet.

The game code shows `scene-12` is the game's scene 0x0C (the same number everywhere). If a
scene ever needs overriding, set `"game_scene"` in the level's `base`. Facing still needs a
check: turn on "Log Conker's Position", stand Conker facing along an axis and compare with the
editor. Positions are editor metres × 100.

## Credits

Built on [CBFD-Recompiled](https://github.com/sciaschi/CBFD-Recompiled) (MIT; GPL-3.0 as
a whole), the [Conker decompilation](https://github.com/mkst/conker),
[DevOldSchool's conkers-bfd-decomp](https://github.com/DevOldSchool/conkers-bfd-decomp)
(MIT), [N64Recomp](https://github.com/N64Recomp/N64Recomp),
[N64ModernRuntime](https://github.com/N64Recomp/N64ModernRuntime),
[RT64](https://github.com/rt64/rt64) and [Godot](https://godotengine.org).

Conker's Bad Fur Day is © Rare Ltd. Conker Maker is an unofficial fan project, not
affiliated with or endorsed by Rare, Microsoft or Nintendo.
