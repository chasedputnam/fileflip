#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "generate-media-manifest.py"
FIXTURES = ROOT / "Tests" / "FileConvertProvidersTests" / "Fixtures" / "configuration-token-cases.json"

spec = importlib.util.spec_from_file_location("generate_media_manifest", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MediaConfigurationTests(unittest.TestCase):
    def test_shared_configuration_cases(self) -> None:
        fixture = json.loads(FIXTURES.read_text(encoding="utf-8"))
        self.assertEqual(fixture["schemaVersion"], 1)
        for case in fixture["cases"]:
            with self.subTest(case=case["name"]):
                if case.get("error"):
                    with self.assertRaises(module.ManifestError):
                        module.canonical_configuration(case["input"])
                else:
                    self.assertEqual(module.canonical_configuration(case["input"]), case["arguments"])

    def test_semantically_different_values_hash_differ(self) -> None:
        first = module.configuration_sha256(["--enable-decoder=aac,flac"])
        second = module.configuration_sha256(["--enable-decoder=aac,opus"])
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
