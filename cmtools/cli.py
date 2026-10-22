"""cmtools: the command-line half of Conker Maker. The app calls these same commands.

    python -m cmtools check-rom  <rom>
    python -m cmtools new        <folder> --title "Conker's Other Bad Day"
    python -m cmtools validate   <project>
    python -m cmtools build      <project> --rom <rom> [--out <folder>]
    python -m cmtools apply      <rom> <patch.bps> <out.z64>
    python -m cmtools inspect    <built.z64>
    python -m cmtools playtest   <built.z64> --recomp <ConkerRecomp.exe>
    python -m cmtools import-assets --rom <rom> [--library <folder>]   (models, textures, scenes)
    python -m cmtools library    --rom <rom>       (where the asset library is, and what's in it)

Add --json to get machine-readable output (the app uses it).
"""
from __future__ import annotations

import argparse
import json
import sys

from . import build, package, project, rom as romlib, rom_assets


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cmtools", description="Conker Maker tools")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check-rom", help="is this ROM one Conker Maker can use?")
    p.add_argument("rom")
    p = sub.add_parser("new", help="start a new game project")
    p.add_argument("folder")
    p.add_argument("--title", default="Conker's Other Bad Day")
    p = sub.add_parser("validate", help="check a project for problems")
    p.add_argument("project")
    p = sub.add_parser("build", help="build a project into a ROM and a .bps patch")
    p.add_argument("project")
    p.add_argument("--rom", required=True)
    p.add_argument("--out")
    p = sub.add_parser("apply", help="apply a Conker Maker .bps patch to your ROM")
    p.add_argument("rom")
    p.add_argument("patch")
    p.add_argument("out")
    p = sub.add_parser("inspect", help="show the game packed in a built ROM")
    p.add_argument("rom")
    p = sub.add_parser("playtest", help="start the recomp with a built ROM")
    p.add_argument("rom")
    p.add_argument("--recomp", required=True)
    p = sub.add_parser("import-assets", help="extract models, textures and scenes from your ROM")
    p.add_argument("--rom", required=True)
    p.add_argument("--library", help="where to put them (default: your app-data folder)")
    p.add_argument("--decomp", help="an existing conkers-bfd-decomp checkout to use")
    p.add_argument("--no-scenes", action="store_true", help="skip composing level scenes (faster)")
    p = sub.add_parser("library", help="where your ROM's asset library is")
    p.add_argument("--rom", required=True)
    args = parser.parse_args(argv)

    def say(result: dict, text: str) -> None:
        print(json.dumps(result) if args.json else text)

    try:
        if args.command == "check-rom":
            r = romlib.load(args.rom)
            say({"ok": True, "kind": r.kind, "description": r.description, "sha1": r.sha1,
                 "byte_order": r.byte_order, "verified": r.verified},
                f"OK: {r.description} ({r.byte_order}, SHA-1 {r.sha1})")
        elif args.command == "new":
            path = project.new_project(args.folder, args.title)
            say({"ok": True, "project": str(path)}, f"Created '{args.title}' in {path}")
        elif args.command == "validate":
            problems = project.validate(project.load(args.project))
            say({"ok": not problems, "problems": problems},
                "No problems found." if not problems else "Problems:\n  - " + "\n  - ".join(problems))
            return 0 if not problems else 1
        elif args.command == "build":
            report = build.build(args.project, args.rom, args.out)
            say({"ok": True, **report},
                f"Built '{report['title']}' ({report['levels']} levels, {report['objects']} objects)\n"
                f"  play:  {report['rom']}\n  share: {report['patch']} ({report['patch_bytes']:,} bytes)\n"
                f"  space: {report['package_bytes']:,} of {report['package_capacity']:,} bytes used")
        elif args.command == "apply":
            out = build.apply_patch(args.rom, args.patch, args.out)
            say({"ok": True, "rom": str(out)}, f"Patched ROM written to {out}")
        elif args.command == "inspect":
            r = romlib.load(args.rom)
            game = package.read_from(r.data)
            if game is None:
                say({"ok": False, "error": "no game"}, "No Conker Maker game in this ROM.")
                return 1
            say({"ok": True, "game": game},
                f"'{game['title']}': {len(game['levels'])} levels, starts at '{game['start_level']}'")
        elif args.command == "playtest":
            proc = build.playtest(args.recomp, args.rom)
            say({"ok": True, "pid": proc.pid}, f"Started the recomp (pid {proc.pid}).")
        elif args.command == "import-assets":
            result = rom_assets.import_assets(args.rom, args.library, args.decomp, not args.no_scenes,
                                              say=(lambda m: print(m, file=sys.stderr)) if args.json else print)
            say({"ok": True, **result}, f"Imported {result['models']} models and {result['scenes']} scenes "
                f"in {result['seconds']} s into {result['library']}")
        elif args.command == "library":
            r = romlib.load(args.rom)
            info = rom_assets.library_info(rom_assets.default_library(r))
            say({"ok": True, **info}, json.dumps(info, indent=2))
    except (romlib.RomError, project.ProjectError, package.PackageError, build.BuildError, Exception) as error:
        say({"ok": False, "error": str(error)}, f"Error: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
