#!/usr/bin/env python3
from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "packaged_media_release.py"
spec = importlib.util.spec_from_file_location("packaged_media_release", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

NOW = datetime(2026, 7, 29, 12, 0, tzinfo=timezone.utc)
STAMP = "2026-07-29T11:00:00Z"
REVISION = "0123456789abcdef"


def sha(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class PackagedMediaReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.contract = json.loads((ROOT / "release/release-contract.json").read_text(encoding="utf-8"))
        self.contract["packagedMedia"]["fixtureManifest"] = "fixtures.json"
        self.app = self.root / "FileFlip.app"
        media = self.app / "Contents/Resources/MediaTools"
        media.mkdir(parents=True)
        (media / "manifest.json").write_text('{"schemaVersion":1}\n', encoding="utf-8")
        (media / "ffmpeg").write_bytes(b"ffmpeg")
        (media / "ffprobe").write_bytes(b"ffprobe")
        info = {
            "CFBundleIdentifier": "app.fileconvert.FileConvert",
            "CFBundleShortVersionString": "1.0",
        }
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        expected = self.contract["packagedMedia"]["expected"]
        formats = [
            item["canonicalExtension"]
            for family in ("audioFormats", "videoFormats")
            for item in expected[family]
        ]
        self.fixture_hashes = {extension: sha(f"fixture:{extension}") for extension in formats}
        fixtures = {
            "fixtures": [
                {"canonicalExtension": extension, "sha256": digest}
                for extension, digest in self.fixture_hashes.items()
            ]
        }
        (self.root / "fixtures.json").write_text(json.dumps(fixtures), encoding="utf-8")
        (self.root / "smoke.txt").write_text("passed\n", encoding="utf-8")
        self.report = self.make_report()
        self.write_report()
        self.evidence = {
            "revision": REVISION,
            "recordedAt": STAMP,
            "packagedMedia": {
                "matrixReport": {
                    "status": "passed",
                    "command": [
                        item.replace("{root}", str(self.root.resolve())).replace("{app}", str(self.app.resolve())).replace("{report}", str((self.root / "matrix.json").resolve()))
                        for item in self.contract["packagedMedia"]["matrixCommand"]
                    ],
                    "observedAt": STAMP,
                    "revision": REVISION,
                    "artifact": "matrix.json",
                },
                "installationSmoke": {
                    "status": "passed",
                    "command": [
                        item.replace("{root}", str(self.root.resolve())).replace("{app}", str(self.app.resolve()))
                        for item in self.contract["packagedMedia"]["installationSmokeCommand"]
                    ],
                    "observedAt": STAMP,
                    "revision": REVISION,
                    "artifact": "smoke.txt",
                },
            },
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_report(self) -> dict[str, object]:
        media = self.contract["packagedMedia"]
        routes = []
        for identity in sorted(module.expected_routes(media), key=lambda value: value.encode("utf-8")):
            family_source, target = identity.split("->")
            family, source = family_source.split(":")
            streams = [{"kind": "audio", "codec": "aac", "frameCount": 10, "sampleRate": 48000, "channels": 1, "width": None, "height": None}]
            if family == "video":
                streams.append({"kind": "video", "codec": "h264", "frameCount": 10, "sampleRate": None, "channels": None, "width": 96, "height": 96})
            fixture = self.fixture_hashes[source]
            routes.append({
                "family": family,
                "source": source,
                "target": target,
                "fixtureSHA256": fixture,
                "sourceBeforeSHA256": fixture,
                "sourceAfterSHA256": fixture,
                "outputSHA256": sha(f"output:{identity}"),
                "outputByteLength": 100,
                "observedFacts": {"logicalFormat": target, "durationMilliseconds": 1000, "streams": streams},
                "status": "passed",
            })
        expected = media["expected"]
        manifest_sha = module._regular_file_sha256(self.app / "Contents/Resources/MediaTools/manifest.json")
        return {
            "schemaVersion": media["reportSchemaVersion"],
            "generatedAt": STAMP,
            "revision": REVISION,
            "platform": {"os": "macOS", "architecture": "arm64"},
            "application": {
                "bundleIdentifier": "app.fileconvert.FileConvert",
                "version": "1.0",
                "candidateSHA256": module.candidate_sha256(self.app),
            },
            "provider": {
                "ffmpegVersion": "8.1.2",
                "manifestSHA256": manifest_sha,
                "contractVersion": media["contractVersion"],
                "routeSetSHA256": expected["routeSetSHA256"],
            },
            "summary": {
                "expectedRoutes": 76,
                "executedRoutes": 76,
                "passedRoutes": 76,
                "failedRoutes": 0,
                "skippedRoutes": 0,
                "audioRoutes": 56,
                "videoRoutes": 20,
            },
            "routes": routes,
        }

    def write_report(self) -> None:
        (self.root / "matrix.json").write_text(json.dumps(self.report), encoding="utf-8")

    @staticmethod
    def passing_command(_: list[str]) -> tuple[int, str]:
        return 0, "passed"

    def check(self, command=None, app=True) -> list[str]:
        failures: list[str] = []
        module.check_packaged_media(
            self.contract,
            self.evidence,
            self.app if app else None,
            self.root,
            command or self.passing_command,
            failures,
            now=NOW,
        )
        return failures

    def test_complete_candidate_bound_matrix_passes(self) -> None:
        self.assertEqual(self.check(), [])

    def test_source_tree_only_evidence_is_rejected(self) -> None:
        self.assertTrue(any("requires the built application candidate" in item for item in self.check(app=False)))

    def test_flattened_or_missing_candidate_layout_is_rejected(self) -> None:
        def command(argv: list[str]) -> tuple[int, str]:
            return (1, "missing MediaTools directory") if argv[0] == "scripts/verify-media-bundle.py" else (0, "passed")
        self.assertTrue(any("candidate layout" in item for item in self.check(command=command)))

    def test_capability_declaration_drift_is_rejected(self) -> None:
        def command(argv: list[str]) -> tuple[int, str]:
            return (1, "formats differ") if argv == self.contract["packagedMedia"]["consistencyCommand"] else (0, "passed")
        self.assertTrue(any("capability declarations differ" in item for item in self.check(command=command)))

    def test_incomplete_summary_is_rejected(self) -> None:
        self.report["summary"]["passedRoutes"] = 75
        self.write_report()
        self.assertTrue(any("matrix summary" in item for item in self.check()))

    def test_stale_matrix_is_rejected(self) -> None:
        self.report["generatedAt"] = "2026-01-01T00:00:00Z"
        self.write_report()
        self.assertTrue(any("stale" in item for item in self.check()))

    def test_duplicate_or_substituted_route_is_rejected(self) -> None:
        self.report["routes"][1] = deepcopy(self.report["routes"][0])
        self.write_report()
        self.assertTrue(any("missing, duplicated, or substituted" in item for item in self.check()))
    def test_noncanonical_release_command_is_rejected(self) -> None:
        self.evidence["packagedMedia"]["matrixReport"]["command"] = ["swift", "run", "some-other-matrix"]
        self.assertTrue(any("exact release command" in item for item in self.check()))


    def test_source_mutation_is_rejected(self) -> None:
        self.report["routes"][0]["sourceAfterSHA256"] = sha("mutated")
        self.write_report()
        self.assertTrue(any("source is changed" in item for item in self.check()))

    def test_candidate_or_manifest_mismatch_is_rejected(self) -> None:
        self.report["application"]["candidateSHA256"] = sha("other candidate")
        self.write_report()
        self.assertTrue(any("different application candidate" in item for item in self.check()))
        self.report = self.make_report()
        self.report["provider"]["manifestSHA256"] = sha("other manifest")
        self.write_report()
        self.assertTrue(any("different packaged manifest" in item for item in self.check()))

    def test_unknown_report_fields_are_rejected(self) -> None:
        self.report["unexpected"] = True
        self.write_report()
        self.assertTrue(any("matrix report keys differ" in item for item in self.check()))

    def test_duplicate_json_keys_are_rejected(self) -> None:
        path = self.root / "duplicate.json"
        path.write_text('{"schemaVersion":1,"schemaVersion":1}', encoding="utf-8")
        with self.assertRaisesRegex(module.PackagedMediaEvidenceError, "duplicate JSON key"):
            module.load_json(path, "duplicate report")


if __name__ == "__main__":
    unittest.main()
