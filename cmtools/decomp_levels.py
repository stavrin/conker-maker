"""Compose every Bad Fur Day level scene the ROM has, using the decomp's scene composer.

Run from the decomp's folder (cmtools does, through decomp_shim.py):

    python decomp_levels.py <rom.z64> <model root inside the decomp> <output folder>

The decomp ships 44 hand-reviewed scene selections, which leave out alternative states
(a damaged wall beside the intact one) and pieces whose look isn't solved yet. For those
scenes we use its selection. For the rest of the ROM's 69 scene indices, we take every
piece, leaving out only the pieces whose materials can't be decoded yet, so you get a
complete level instead of nothing. Each result says what was left out and why.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path.cwd().resolve()
sys.path[:0] = [str(ROOT), str(ROOT / "scripts")]

from scripts.model_scene_assemblies import compose, rom_scenes  # noqa: E402

UNRESOLVED = re.compile(r"unresolved materials: \((\d+), (\d+), (\d+)\)")


def main() -> int:
    rom, model_root, output = Path(sys.argv[1]), Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve()
    sha1, scenes = rom_scenes("us", rom)
    reviewed = {s["scene_index"]: s for s in
                json.loads((ROOT / "config" / "model-scene-assemblies.json").read_text(encoding="utf-8"))["scenes"]}
    (output / "geometry").mkdir(parents=True, exist_ok=True)
    levels, skipped = [], []
    for index in sorted(scenes):
        selection = reviewed.get(index, {"scene_index": index, "exclude_models": []})
        selection = {"scene_index": index, "exclude_models": list(selection.get("exclude_models", []))}
        for _ in range(40):   # leave out undecodable pieces one at a time
            try:
                gltf, binary, record = compose(scenes[index], selection, model_root, sha1)
                break
            except ValueError as error:
                match = UNRESOLVED.search(str(error))
                if not match:
                    skipped.append({"index": index, "reason": str(error)})
                    record = None
                    break
                selection["exclude_models"].append({"model": [int(g) for g in match.groups()],
                                                    "reason": "materials not decodable yet"})
        else:
            record = None
        if record is None:
            continue
        name = f"scene-{index:02d}"
        (output / "geometry" / f"{name}.gltf").write_bytes(gltf)
        (output / "geometry" / f"{name}.bin").write_bytes(binary)
        levels.append({"index": index, "reviewed": index in reviewed, "path": f"geometry/{name}.gltf",
                       "instances": record["instance_count"], "faces": record["face_count"],
                       "left_out": [o["model"] for o in record["omissions"]]})
        print(f"scene {index}: {record['instance_count']} pieces, {record['face_count']} faces", flush=True)
    (output / "levels.json").write_text(json.dumps({"rom_sha1": sha1, "levels": levels, "skipped": skipped},
                                                   indent=1), encoding="utf-8")
    print(f"{len(levels)} levels, {len(skipped)} scene indices without a usable level")
    return 0


if __name__ == "__main__":
    sys.exit(main())
