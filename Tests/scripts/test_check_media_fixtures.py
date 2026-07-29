#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-media-fixtures.py"
FIXTURES = ROOT / "Tests" / "Fixtures" / "Media"
MEDIA_TOOLS = ROOT / "Sources" / "FileConvertApp" / "Resources" / "MediaTools"
spec = importlib.util.spec_from_file_location("check_media_fixtures", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MediaFixtureCertificationTests(unittest.TestCase):
    def test_certifies_reviewed_fixture_set(self) -> None:
        module.certify(FIXTURES / "manifest.json", MEDIA_TOOLS)

    def copied_fixtures(self, temporary: str) -> tuple[Path, dict]:
        destination = Path(temporary) / "Media"
        shutil.copytree(FIXTURES, destination)
        manifest_path = destination / "manifest.json"
        return manifest_path, json.loads(manifest_path.read_text(encoding="utf-8"))

    @staticmethod
    def write_manifest(path: Path, manifest: dict) -> None:
        path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def assert_rejected(self, mutate) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path, manifest = self.copied_fixtures(temporary)
            mutate(path.parent, manifest)
            self.write_manifest(path, manifest)
            with self.assertRaises((module.CertificationError, module.GENERATOR.FixtureError)):
                module.certify(path, MEDIA_TOOLS)

    def test_rejects_unknown_fields_at_every_manifest_level(self) -> None:
        mutations = [
            lambda _root, value: value.__setitem__("unknown", True),
            lambda _root, value: value["generator"].__setitem__("unknown", True),
            lambda _root, value: value["fixtures"][0].__setitem__("unknown", True),
            lambda _root, value: value["fixtures"][0]["facts"].__setitem__("unknown", True),
            lambda _root, value: value["fixtures"][0]["facts"]["streams"][0].__setitem__("unknown", True),
        ]
        for index, mutation in enumerate(mutations):
            with self.subTest(level=index):
                self.assert_rejected(mutation)

    def test_rejects_missing_mislabeled_hash_mismatch_empty_and_unsafe_fixtures(self) -> None:
        def missing(root: Path, manifest: dict) -> None:
            (root / manifest["fixtures"][0]["path"]).unlink()

        def mislabeled(_root: Path, manifest: dict) -> None:
            manifest["fixtures"][0]["format"] = "wav"

        def hash_mismatch(_root: Path, manifest: dict) -> None:
            manifest["fixtures"][0]["sha256"] = "0" * 64

        def empty(root: Path, manifest: dict) -> None:
            (root / manifest["fixtures"][0]["path"]).write_bytes(b"")

        def unsafe(_root: Path, manifest: dict) -> None:
            manifest["fixtures"][0]["path"] = "../source.mp3"

        for name, mutation in {
            "missing": missing,
            "mislabeled": mislabeled,
            "hash mismatch": hash_mismatch,
            "empty": empty,
            "unsafe": unsafe,
        }.items():
            with self.subTest(case=name):
                self.assert_rejected(mutation)

    def test_rejects_invalid_bounds_duplicates_and_inconsistent_facts(self) -> None:
        def duration(_root: Path, manifest: dict) -> None:
            manifest["fixtures"][0]["facts"]["durationMilliseconds"] = 2_001

        def channels(_root: Path, manifest: dict) -> None:
            manifest["fixtures"][0]["facts"]["streams"][0]["channels"] = 0

        def duplicate(_root: Path, manifest: dict) -> None:
            manifest["fixtures"][-1] = copy.deepcopy(manifest["fixtures"][0])

        def inconsistent(_root: Path, manifest: dict) -> None:
            manifest["fixtures"][0]["facts"]["streams"][0]["codec"] = "aac"

        for name, mutation in {
            "duration": duration,
            "channels": channels,
            "duplicate": duplicate,
            "inconsistent": inconsistent,
        }.items():
            with self.subTest(case=name):
                self.assert_rejected(mutation)

    def test_rejects_undecodable_bytes_even_when_hash_and_length_are_updated(self) -> None:
        def undecodable(root: Path, manifest: dict) -> None:
            fixture = manifest["fixtures"][0]
            path = root / fixture["path"]
            path.write_bytes(b"not media")
            fixture["byteLength"] = path.stat().st_size
            fixture["sha256"] = module.digest(path)

        self.assert_rejected(undecodable)

    def test_regeneration_is_byte_for_byte_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            regenerated = Path(temporary) / "Media"
            module.GENERATOR.regenerate(MEDIA_TOOLS, regenerated)
            expected_paths = sorted(path.relative_to(FIXTURES) for path in FIXTURES.rglob("*") if path.is_file())
            observed_paths = sorted(path.relative_to(regenerated) for path in regenerated.rglob("*") if path.is_file())
            self.assertEqual(observed_paths, expected_paths)
            for relative in expected_paths:
                with self.subTest(path=relative):
                    self.assertEqual((regenerated / relative).read_bytes(), (FIXTURES / relative).read_bytes())


if __name__ == "__main__":
    unittest.main()
