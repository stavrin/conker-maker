"""Tests that need no ROM. Run from conker_maker/:  python -m unittest discover tests

With CONKER_ROM set to your ROM's path, test_real_rom.py also checks the full build.
"""
import array
import copy
import json
import os
import random
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from cmtools import bps, build, package, project, rom as romlib, rom_assets  # noqa: E402


def fake_rom(region=b"E") -> bytes:
    """A 64 MB stand-in with a Conker header (not the game, just its shape)."""
    rng = random.Random(1)
    data = bytearray(rng.randbytes(romlib.FREE_START))
    data[0:4] = bytes.fromhex("80371240")
    data[0x20:0x34] = b"CONKER BFD          "
    data[0x3B:0x3F] = b"NFU" + region
    data += b"\xff" * (romlib.ROM_SIZE - len(data))
    return bytes(data)


class RomTests(unittest.TestCase):
    def test_byte_orders(self):
        z64 = fake_rom()
        v64 = array.array("H", z64); v64.byteswap()
        n64 = array.array("I", z64); n64.byteswap()
        for raw, order in ((z64, "z64"), (v64.tobytes(), "v64"), (n64.tobytes(), "n64")):
            r = romlib.identify(raw)
            self.assertEqual(r.byte_order, order)
            self.assertEqual(r.data, z64)
            self.assertEqual(r.kind, "us-asset-hack")  # not the real dump

    def test_refuses_pal_and_other_games(self):
        with self.assertRaisesRegex(romlib.RomError, "European"):
            romlib.identify(fake_rom(b"P"))
        other = bytearray(fake_rom()); other[0x20:0x34] = b"SUPER MARIO 64      "
        with self.assertRaisesRegex(romlib.RomError, "not Conker"):
            romlib.identify(bytes(other))
        with self.assertRaises(romlib.RomError):
            romlib.identify(b"hello world")


class BpsTests(unittest.TestCase):
    def test_round_trip(self):
        rng = random.Random(2)
        source = rng.randbytes(200_000)
        target = bytearray(source)
        for _ in range(50):
            at, size = rng.randrange(len(target) - 100), rng.randrange(1, 100)
            target[at:at + size] = rng.randbytes(size)  # in place, as Conker Maker edits
        target[-5000:] = b"\xaa" * 5000
        target += b"grown"
        patch = bps.create(source, bytes(target), "hello")
        self.assertEqual(bps.apply(source, patch), bytes(target))
        self.assertEqual(bps.metadata(patch), "hello")
        self.assertLess(len(patch), 10_000)

    def test_wrong_source(self):
        patch = bps.create(b"a" * 1000, b"b" * 1000)
        with self.assertRaisesRegex(bps.BpsError, "different ROM"):
            bps.apply(b"c" * 1000, patch)


class ProjectTests(unittest.TestCase):
    def setUp(self):
        self.game = project.load(ROOT / "templates" / "new_game")

    def test_template_is_valid(self):
        self.assertEqual(project.validate(self.game), [])

    def test_catches_mistakes(self):
        game = copy.deepcopy(self.game)
        level = game["levels"]["test_level"]
        level["objects"] = [o for o in level["objects"] if o["type"] != "player_start"]
        level["objects"][0]["uid"] = level["objects"][1]["uid"]
        level["events"][1]["when"]["object"] = "nobody"
        problems = "\n".join(project.validate(game))
        self.assertIn("exactly one Conker Start", problems)
        self.assertIn("more than one object", problems)
        self.assertIn("needs a Character", problems)

    def test_new_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = project.new_project(Path(tmp) / "g", "My Game")
            game = project.load(path)
            self.assertEqual(game["title"], "My Game")
            self.assertEqual(project.validate(game), [])


class RomAssetTests(unittest.TestCase):
    def test_labels_from_decomp_gallery(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config"
            config.mkdir()
            (config / "model-inspection.json").write_text(json.dumps({"models": [
                {"render_case": "conker-rom-defaults", "label": "Conker — ROM defaults and animations", "category": "characters"},
                {"render_case": "object-bank03-0039-rom", "label": "Wooden barrel — ROM bank 03 / 0039", "category": "scene-items"},
                {"render_case": "object-bank04-0028-13-rom", "label": "Tree stump — ROM 04 / 0028 / 13", "category": "scene-items"},
            ]}), encoding="utf-8")
            labels = rom_assets._labels(Path(tmp))
        self.assertEqual(labels["b01-0000-00"]["name"], "Conker")
        self.assertEqual(labels["b03-0039-00"]["name"], "Wooden barrel")
        self.assertEqual(labels["b04-0028-13"]["name"], "Tree stump")

    def test_shim_aliases_only_the_whole_hack_rom(self):
        import hashlib, subprocess
        with tempfile.TemporaryDirectory() as tmp:
            rom_path = Path(tmp) / "hack.bin"
            rom_path.write_bytes(b"\x01" * romlib.ROM_SIZE)
            script = Path(tmp) / "check.py"
            script.write_text("import hashlib, sys\n"
                              "data = open(sys.argv[1], 'rb').read()\n"
                              "print(hashlib.sha1(data).hexdigest(), hashlib.sha1(data[:10]).hexdigest())\n")
            hack = hashlib.sha1(rom_path.read_bytes()).hexdigest()
            us = "4cbadd3c4e0729dec46af64ad018050eada4f47a"
            out = subprocess.run([sys.executable, str(rom_assets.SHIM), str(script), str(rom_path)],
                                 capture_output=True, text=True, env={**os.environ, "CM_ROM_ALIAS": f"{hack}:{us}"})
            whole, part = out.stdout.split()
            self.assertEqual(whole, us)
            self.assertEqual(part, hashlib.sha1(b"\x01" * 10).hexdigest())

    def test_windows_paths_patch(self):
        text = "relative = str(source.relative_to(root))\nx = str(a.b.relative_to(ROOT / 'c'))"
        fixed = rom_assets._RELATIVE_STR.sub(r"\1.relative_to(\2).as_posix()", text)
        self.assertEqual(fixed, "relative = source.relative_to(root).as_posix()\nx = a.b.relative_to(ROOT / 'c').as_posix()")

    def test_model_references_are_validated(self):
        game = project.load(ROOT / "templates" / "new_game")
        level = game["levels"]["test_level"]
        level["objects"][1]["props"]["model"] = {"id": "b01-0075-00", "bank": 1, "entry": 75, "segment": 0}
        level["base"] = {"kind": "rom_scene", "scene": "scene-06"}
        self.assertEqual(project.validate(game), [])
        level["objects"][1]["props"]["model"] = "haybot"
        level["base"] = {"kind": "rom_scene"}
        problems = "\n".join(project.validate(game))
        self.assertIn("isn't a ROM model reference", problems)
        self.assertIn("doesn't say which", problems)


class PackageTests(unittest.TestCase):
    def test_round_trip_and_build(self):
        game = project.load(ROOT / "templates" / "new_game")
        blob = package.pack(game)
        self.assertEqual(package.unpack(blob), game)
        base = fake_rom()
        built = package.write_into(base, blob)
        self.assertEqual(len(built), len(base))
        self.assertEqual(built[:romlib.FREE_START], base[:romlib.FREE_START])
        self.assertEqual(package.read_from(built)["title"], game["title"])

    def test_full_build_with_fake_rom(self):
        with tempfile.TemporaryDirectory() as tmp:
            rom_path = Path(tmp) / "fake.z64"
            rom_path.write_bytes(fake_rom())
            report = build.build(ROOT / "templates" / "new_game", rom_path, Path(tmp) / "out")
            out = build.apply_patch(rom_path, report["patch"], Path(tmp) / "patched.z64")
            self.assertEqual(out.read_bytes(), Path(report["rom"]).read_bytes())
            with self.assertRaisesRegex(build.BuildError, "already has"):
                build.build(ROOT / "templates" / "new_game", report["rom"], Path(tmp) / "out2")


@unittest.skipUnless(os.environ.get("CONKER_ROM"), "set CONKER_ROM to your ROM to run")
class RealRomTests(unittest.TestCase):
    def test_real_rom(self):
        r = romlib.load(os.environ["CONKER_ROM"])
        self.assertTrue(r.verified, r.description)
        # The free space Conker Maker uses really is free.
        self.assertEqual(r.data[romlib.FREE_START:], b"\xff" * (romlib.ROM_SIZE - romlib.FREE_START))
        with tempfile.TemporaryDirectory() as tmp:
            report = build.build(ROOT / "templates" / "new_game", os.environ["CONKER_ROM"], tmp)
            built = Path(report["rom"]).read_bytes()
            self.assertEqual(built[:romlib.FREE_START], r.data[:romlib.FREE_START])
            print("\n", report)


if __name__ == "__main__":
    unittest.main()
