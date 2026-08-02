#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


readiness = load_module("release_readiness_tests", ROOT / "scripts" / "release-readiness.py")


class DeveloperIDIdentityTests(unittest.TestCase):
    approved_team = "APPROVED01"

    def contract(self) -> dict:
        contract = readiness.load_json(ROOT / "release" / "release-contract.json", "release contract", [])
        self.assertIsNotNone(contract)
        contract = copy.deepcopy(contract)
        contract["application"]["signing"]["approvedDeveloperIDTeamIdentifier"] = self.approved_team
        return contract

    def test_production_identity_is_configured(self) -> None:
        failures: list[str] = []
        contract = readiness.load_json(ROOT / "release" / "release-contract.json", "release contract", failures)
        self.assertIsNotNone(contract)
        self.assertEqual(readiness.approved_developer_id_team(contract, failures), "C5C4W9B7FS")
        self.assertEqual(failures, [])

    def test_valid_but_wrong_team_identifier_is_rejected(self) -> None:
        failures: list[str] = []
        commands: list[list[str]] = []

        def command(argv: list[str], stdout_only: bool = False) -> tuple[int, str]:
            commands.append(argv)
            if argv[:3] == ["/usr/bin/codesign", "-d", "--verbose=4"]:
                return 0, "TeamIdentifier=MISMATCH01\n"
            if argv[:2] == ["/usr/bin/codesign", "--verify"]:
                return 0, ""
            self.fail(f"unexpected command: {argv}")

        with patch.object(readiness, "command", command):
            readiness.check_developer_id_identity(Path("FileFlip.app"), Path("FileFlip.app"), self.approved_team, failures)

        self.assertTrue(any("expected APPROVED01, observed MISMATCH01" in failure for failure in failures))
        self.assertIn(readiness.developer_id_requirement(self.approved_team), [argument for argv in commands for argument in argv])

    def test_nested_signed_helper_identity_and_runtime_are_checked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "FileFlip.app"
            executable = app / "Contents/MacOS/FileFlip"
            helper = app / "Contents/Frameworks/Helper.framework/Versions/A/Helper"
            executable.parent.mkdir(parents=True)
            helper.parent.mkdir(parents=True)
            executable.touch()
            helper.touch()
            (app / "Contents/Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": "app.fileconvert.FileConvert", "LSMinimumSystemVersion": "14.0"})
            )
            checked_metadata_paths: list[Path] = []

            def command(argv: list[str], stdout_only: bool = False) -> tuple[int, str]:
                if argv[:2] == ["/usr/bin/file", "-b"]:
                    return 0, "Mach-O 64-bit executable arm64"
                if argv[:2] == ["/usr/bin/lipo", "-archs"]:
                    return 0, "arm64"
                if argv[:3] == ["/usr/bin/codesign", "-d", "--verbose=4"]:
                    path = Path(argv[-1])
                    checked_metadata_paths.append(path)
                    team = "MISMATCH01" if path == helper else self.approved_team
                    runtime = "" if path == helper else "runtime\n"
                    return 0, f"{runtime}TeamIdentifier={team}\n"
                if argv[:4] == ["/usr/bin/codesign", "-d", "--entitlements", ":-"]:
                    return 0, plistlib.dumps({}).decode("utf-8")
                if argv[:2] == ["/usr/bin/codesign", "--verify"]:
                    return 0, ""
                if argv[:2] == ["/usr/sbin/spctl", "--assess"]:
                    return 0, "Notarized Developer ID"
                self.fail(f"unexpected command: {argv}")

            failures: list[str] = []
            with patch.object(readiness, "command", command):
                readiness.check_bundle(self.contract(), app, app, self.approved_team, failures)

        self.assertIn(helper, checked_metadata_paths)
        self.assertTrue(any("Helper.framework/Versions/A/Helper" in failure and "MISMATCH01" in failure for failure in failures))
        self.assertTrue(
            any(
                "hardened runtime is absent for Contents/Frameworks/Helper.framework/Versions/A/Helper"
                in failure
                for failure in failures
            )
        )


if __name__ == "__main__":
    unittest.main()
