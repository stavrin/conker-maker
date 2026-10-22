# Conker Maker: design

Conker Maker is a "Mario Maker for a whole game" built on Conker's Bad Fur Day. You
build levels by placing things and wiring up events in an editor, then get a ROM you
play in **Conker's Bad Fur Day: Recompiled** and a small patch you share. The first
game it's for is the sequel that never happened, *Conker's Other Bad Day*.

This document says how it fits together, what exists today, and the order the rest
gets built in.

## Ground rules

1. **No game data ever ships.** Conker Maker refuses to do anything until the player
   gives it their own ROM. Shared games are BPS patches. They carry your work and the
   differences from the ROM, and nothing from Rare. This is the rule the recomp and
   both decompilations follow, and the reason a fan project like this can exist.
2. **The real game is the engine.** Finished games run in CBFD-Recompiled, with
   Conker's real moves, camera, models, voices and rendering. The editor's built-in
   preview is a fast sketchpad, not a second engine.
3. **Visual first, code optional.** Everything a level needs can be done with the
   palette, the inspector and events. People who code can drop into JSON, Python
   (cmtools) or C (the runtime mod), but nobody has to.
4. **Never touch the game's code bytes.** The recomp only runs ROMs whose code matches
   the US ROM (it accepts asset hacks such as the uncensored ROM, and refuses code
   hacks). Conker Maker writes only to assets and free space. New behaviour comes from
   a recomp mod (`.nrm`), which is the supported way to change code.

## The pieces

```
           your ROM (US or US Uncensored, .z64/.v64/.n64)
                         │
                         ▼
 ┌───────────────── Conker Maker app (Godot 4, ships as one .exe) ─────────────────┐
 │ ROM gate → project hub → level editor (palette · 3D view · inspector · events)  │
 │                         quick "Play here" preview                               │
 └───────────────┬─────────────────────────────────────────────────────────────────┘
                 │ reads/writes                      │ runs
                 ▼                                   ▼
        project folder (JSON)              cmtools (Python, later cmtools.exe)
        game.json, levels/*.json,          check-rom · validate · build · apply
        assets/                            · inspect · playtest
                                                     │
                                ┌────────────────────┴───────────────────┐
                                ▼                                        ▼
                     MyGame.z64 (play)                          MyGame.bps (share)
                                │
                                ▼
           CBFD-Recompiled  +  obd_core runtime mod (.nrm)
           (the real game)     reads the game package from the ROM and
                               turns levels/objects/events into the game's own
```

| Piece | Where | Status |
| --- | --- | --- |
| Conker Maker app | `app/` (Godot 4.3+, tested on 4.7.2) | **Working skeleton**: ROM gate, hub, editor, events, preview, build and playtest buttons |
| cmtools | `cmtools/` (Python 3.10+) | **Working**: ROM identification, project validation, packing, BPS create/apply, playtest launch |
| Object catalog | `catalog/objects.json` | 13 object types, 6 triggers, 8 actions; shared by app and cmtools |
| Scene catalog | `catalog/scenes.json` | 35 known BFD scenes (chapter-table indices and names) |
| Runtime mod | `runtime_mod/obd_core/` | **Skeleton, builds**: finds the game package in the ROM, logs scene changes |
| ROM asset importer | `cmtools/rom_assets.py`, `app/scripts/rom_library.gd`, `model_browser.gd` | **Working**: 1,485 models (with 764 Conker animations), 44 level scenes, browser, real models in editor and preview |
| Level loader in the real game | — | Planned (milestone 3+) |

### The app (`app/`)

A Godot 4 project, exported as a single Windows exe so players never see or install
Godot (the same approach as Summer Engine and other Godot-based tools). Screens:

- **ROM gate.** Pick your ROM. It's identified by SHA-1 in any byte order (US v1.0 and
  US Uncensored are known), or passed to cmtools, which accepts other US asset hacks by
  their header and refuses PAL, Japanese and beta ROMs with a reason. It's remembered,
  and nothing else in the app opens without it.
- **Project hub.** New game (from `templates/new_game`), open a game, recent games,
  and settings (where ConkerRecomp.exe is, which Python runs cmtools).
- **Level editor.** A palette of object types, a 3D view (orbit, pan, zoom, click to
  place, drag to move, Shift-drag to raise, 0.5 m snapping), an inspector generated
  from the catalog, an Events tab, undo/redo, save, a level picker and new levels.
- **Play here.** Walk the level as a stand-in Conker (run, jump, tail-hover), collect
  cash, chocolate and tails, talk to characters, press B pads, ride platforms, stomp
  enemies, walk through exits to other levels, and run your events. It's for checking
  layout and logic in seconds.
- **Build / Playtest in recomp.** Runs `cmtools build`, then starts ConkerRecomp.exe
  with the built ROM.

### Projects (`templates/new_game/` shows one)

```
MyGame/
  game.json              title, author, start level, chapters, story flags
  levels/<id>.json       a level: base (ground today, a BFD scene later), music, objects, events
  assets/                your own models (.glb), textures (.png), sounds (.wav/.ogg), later
  build/                 what Build makes (MyGame.z64, MyGame.bps, build.json)
```

An object is `{uid, type, position, rotation_y, scale, props}`, where `props` follows
the type's entry in `catalog/objects.json`. An event is
`{id, name, when: {type, object?}, do: [{type, ...fields}]}`. It's plain JSON, so it
diffs well in git, and adding an object type is a catalog entry: the inspector, the
validator and the packer pick it up without new code. (The runtime mod and the preview
need code for its behaviour.)

### cmtools (`cmtools/`)

The command-line half, which the app calls with `--json`:

```
python -m cmtools check-rom  <rom>
python -m cmtools new        <folder> --title "..."
python -m cmtools validate   <project>
python -m cmtools build      <project> --rom <rom> [--out <folder>]
python -m cmtools apply      <rom> <patch.bps> <out.z64>
python -m cmtools inspect    <built.z64>
python -m cmtools playtest   <built.z64> --recomp <ConkerRecomp.exe>
```

- `rom.py` normalises .v64/.n64 to .z64 and identifies the ROM. It also records the
  two regions that matter: the code region (0x40 to 0x1A37E0), which must never change,
  and the free space (0xFF from 0x3F8B800 to the end, about 466 KB in both the US and
  uncensored ROMs).
- `package.py` packs the whole project (minified JSON, zlib) behind a 64-byte `CMKR`
  header at 0x3F8C000. That's room for hundreds of levels of placements and events.
- `bps.py` writes and applies BPS patches (the format Floating IPS, Rom Patcher JS and
  most ROM-hack sites use), with CRC checks on the source, target and patch.
- `build.py` validates, packs, writes the ROM and the patch, and asserts that the code
  region is byte-for-byte the player's.

It ships as `cmtools.exe` (PyInstaller) beside the app later, and the app prefers that
when it's there, so players won't need Python.

### The runtime mod (`runtime_mod/obd_core/`)

An N64ModernRuntime `.nrm` mod, built with the recomp's own mod toolchain (clang for
MIPS, ld.lld, RecompModTool) against `mods/syms` (unchanged between V0.1.6 and the
current master). Today it:

- reads the package header from the ROM with the game's own loader
  (`func_10004514(rom, dram, size, 1)`) and prints the game's title, or says there's
  no Conker Maker game; and
- prints every scene change, which is how we map the scene IDs in `catalog/scenes.json`
  to what's on screen.

It grows into the level loader (milestones 3 to 5).

## The ROM asset library

`cmtools import-assets` runs DevOldSchool's byte-verified extractors (pinned to commit
`4288820`, fetched with Git or as a zip into `third_party/`) on a temporary copy of the
player's ROM: six texture families, the four model banks (01 characters with rigs and
animations, 03 objects, 04 level pieces, 09 objects and effects), and the 44 composed scene
assemblies. The output is glTF with PNG textures, in a per-ROM library under the user's
app-data folder (`%LOCALAPPDATA%\ConkerMaker\library\<sha1>`), never in a project. It's
about 300 MB and takes a few minutes, with stdlib-only Python 3.12+. `catalog.json` names
1,485 models (881 named from the decomp's reviewed gallery) and the scenes.

Levels store a model as `{"id": "b01-0075-00", "bank": 1, "entry": 75, "segment": 0}`: the
app finds it in the library, and the runtime mod will find it in the ROM. One N64 unit is
1 cm in the editor (`world_scale` 0.01), which makes Conker about 1.6 m tall. Conker's
idle, run, jump and hover animations are chosen by logical animation pair in
`catalog/objects.json`, found by looking at them, so they're easy to correct.

## How a level becomes real in Bad Fur Day

This is the hard part, and the reason for the milestones below. Bad Fur Day's levels
are scenes: geometry and collision (asset bank 04), placed objects (bank 03 models,
plus `0x44`-byte placement records), spawn points, cameras, and per-scene scripts and
events. The DevOldSchool decompilation has **reversible codecs** for much of this
(`scene_field_codec.py`: model transforms, spawn fields, group references, view poses;
`script_codec.py`, `event_codec.py`, `route_codec.py` and the model and texture
extractors, which cover 1,487 models byte-for-byte). It's MIT licensed, so Conker
Maker can build on it with credit.

Conker Maker levels reach the real game in three steps, each useful on its own:

1. **Remix existing scenes (data only).** A level picks a BFD scene as its `base`, and
   its objects become edits to that scene's placement records: moving, adding,
   removing and retyping props, pickups and spawns. These are asset changes, written
   into the ROM, so the recomp accepts them and the BPS carries them.
2. **Runtime spawning (obd_core).** The mod reads the package, hooks the scene loader
   (scene request `func_1501C730`, scene loaded `func_15007A70`, as Skip Intro does),
   and spawns objects, triggers and events the base scene doesn't have, using the
   game's own object system (`gObjects`). Dialogue uses the game's text box. Cash,
   chocolate and tails use the counters the Cheats mod writes (0x800D2148, 0x800CC49A,
   0x800D2144).
3. **New geometry.** Custom level meshes made in the app (or Blender) are converted to
   F3DEX2 display lists with collision, and loaded either into a scene's bank-04 slot
   (data) or from the package by obd_core. That's where whole new areas come from.

Chapters map onto the game's chapter table (`D_80087430`, 204 entries), and story
flags onto the save's scene bits, so new chapters can appear in the Chapters menu and
saves keep working.

## Milestones

| # | Milestone | What you can do after it |
| --- | --- | --- |
| 1 | **Skeleton** (this commit) | Make a multi-level game in the editor, play it in the preview, build a ROM and BPS the recomp accepts, and confirm obd_core finds the game |
| 2 | **ROM importer** (done, except audio) | The palette and inspector show real BFD models and textures from your ROM (glTF via the decomp's extractors), levels can stand on real BFD scenes, and the preview plays as the animated Conker. ROM music and voice lines are still to come |
| 3 | **Remix a scene** | Build a level on a real BFD scene: move, add and remove placed objects and spawn points, and play it in the recomp |
| 4 | **obd_core events** | Your events run in the real game: dialogue, pickups, B pads, triggers, exits between your levels |
| 5 | **Custom geometry** | Build new areas (in-editor blocks, or Blender .glb imports) that the real game draws and collides with |
| 6 | **Characters and cutscenes** | NPCs and enemies with BFD rigs and animations, a cutscene timeline with camera shots and voice lines |
| 7 | **Release tooling** | One Conker Maker.exe (Godot export plus cmtools.exe), a "Share" button for the BPS, and a "Play a game" screen that applies a patch for players |

## Risks and open questions

- **Scene formats aren't fully known yet.** The decomp's codecs keep unexplained bytes
  raw, so edits stay byte-safe, but some fields' meanings (surface types, triggers,
  script hooks) need research. obd_core's scene logging is the first tool for that.
- **Free space.** About 466 KB is plenty for game data, but not for much new geometry
  or audio. Big assets will load from the package through obd_core instead, with the
  package possibly growing past 64 MB (the recomp isn't limited by cartridge size; to
  be confirmed) or living next to the mod.
- **Mod reading the ROM.** obd_core borrows the game's loader (`func_10004514`). It
  builds, but it still needs testing in the running recomp.
- **Recomp updates.** Mods link against the recomp's syms. They're unchanged from
  V0.1.6 to master, and `runtime_mod/build.sh` always builds against the checkout you
  give it.
- **Legal.** Conker and Bad Fur Day belong to Rare and Microsoft. Conker Maker is an
  unofficial fan tool. Share patches and the app, never ROMs or extracted assets. Credit
  CBFD-Recompiled (MIT/GPL-3.0), the decompilations (MIT) and N64Recomp, RT64 and
  N64ModernRuntime.

## Code-free, with doors for coders

| You want to... | No code | With code |
| --- | --- | --- |
| Lay out a level | Palette, drag, inspector | Edit `levels/*.json` |
| Script a moment | Events tab: When / Then | (planned) custom actions in obd_core C |
| Add a new kind of object | — | A catalog entry, plus behaviour in the preview and obd_core |
| Automate builds | Build button | `python -m cmtools build ...` in CI |
