#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check-updater-config.py"
SOURCE_PLIST = ROOT / "Config" / "FileConvertApp-Info.plist"
SOURCE_PROJECT = ROOT / "FileFlip.xcodeproj" / "project.pbxproj"
spec = importlib.util.spec_from_file_location("check_updater_config", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpdaterConfigurationTests(unittest.TestCase):
    def load_plist(self) -> dict:
        with SOURCE_PLIST.open("rb") as handle:
            return plistlib.load(handle)

    def validate(self, value: dict) -> list[str]:
        contract = module.load_json(ROOT / "release" / "release-contract.json")["updater"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "Config"
            config.mkdir()
            with (config / SOURCE_PLIST.name).open("wb") as handle:
                plistlib.dump(value, handle)
            original_root = module.ROOT
            module.ROOT = root
            try:
                failures: list[str] = []
                module.check_bundle_configuration(failures, updater_contract=contract)
                return failures
            finally:
                module.ROOT = original_root

    def validate_pins(self, project_text: str) -> list[str]:
        sources = (
            Path("Package.swift"),
            Path("scripts/generate-project.rb"),
            Path("release/release-contract.json"),
            Path("Package.resolved"),
            Path("FileFlip.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for source in sources:
                destination = root / source
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / source, destination)
            project = root / "FileFlip.xcodeproj/project.pbxproj"
            project.parent.mkdir(parents=True, exist_ok=True)
            project.write_text(project_text, encoding="utf-8")

            original_root = module.ROOT
            module.ROOT = root
            try:
                failures: list[str] = []
                module.check_pins(failures)
                return failures
            finally:
                module.ROOT = original_root

    def validate_hardened_runtime(self, outputs: dict[str, str]) -> list[str]:
        failures: list[str] = []
        module.check_hardened_runtime_build_settings(failures, outputs)
        return failures

    def test_accepts_hardened_runtime_in_all_application_configurations(self) -> None:
        outputs = {
            configuration: "    ENABLE_HARDENED_RUNTIME = YES\n"
            for configuration in ("Debug", "Release")
        }

        self.assertEqual(self.validate_hardened_runtime(outputs), [])

    def test_rejects_disabled_or_missing_hardened_runtime(self) -> None:
        mutations = {
            "disabled Debug": {
                "Debug": "    ENABLE_HARDENED_RUNTIME = NO\n",
                "Release": "    ENABLE_HARDENED_RUNTIME = YES\n",
            },
            "missing Release": {
                "Debug": "    ENABLE_HARDENED_RUNTIME = YES\n",
                "Release": "",
            },
        }
        for name, outputs in mutations.items():
            with self.subTest(case=name):
                failures = self.validate_hardened_runtime(outputs)
                self.assertTrue(
                    any("ENABLE_HARDENED_RUNTIME=YES" in failure for failure in failures)
                )

    def test_accepts_production_fail_closed_configuration(self) -> None:
        self.assertEqual(self.validate(self.load_plist()), [])

    def test_accepts_real_project_sparkle_pin(self) -> None:
        project_text = SOURCE_PROJECT.read_text(encoding="utf-8")
        self.assertEqual(self.validate_pins(project_text), [])

    def test_rejects_drifted_project_sparkle_pin(self) -> None:
        project_text = SOURCE_PROJECT.read_text(encoding="utf-8")
        current_pin = "\t\t\t\tversion = 2.9.4;"
        self.assertEqual(project_text.count(current_pin), 1)
        drifted = project_text.replace(current_pin, "\t\t\t\tversion = 2.9.3;")

        failures = self.validate_pins(drifted)

        self.assertTrue(any("Sparkle pin mismatch" in failure for failure in failures))

    def test_rejects_non_exact_or_missing_project_requirement(self) -> None:
        project_text = SOURCE_PROJECT.read_text(encoding="utf-8")
        exact_requirement = (
            "\t\t\trequirement = {\n"
            "\t\t\t\tkind = exactVersion;\n"
            "\t\t\t\tversion = 2.9.4;\n"
            "\t\t\t};\n"
        )
        self.assertEqual(project_text.count(exact_requirement), 1)
        mutations = {
            "non-exact": project_text.replace(
                "\t\t\t\tkind = exactVersion;",
                "\t\t\t\tkind = upToNextMajorVersion;",
            ),
            "missing": project_text.replace(exact_requirement, ""),
        }
        for name, candidate in mutations.items():
            with self.subTest(case=name):
                failures = self.validate_pins(candidate)
                self.assertTrue(
                    any("must contain exactly one exactVersion pin" in failure for failure in failures)
                )

    def test_rejects_relaxed_or_invalid_security_configuration(self) -> None:
        mutations = {
            "missing public key": lambda value: value.pop("SUPublicEDKey"),
            "invalid public key": lambda value: value.__setitem__("SUPublicEDKey", "not-a-key"),
            "non-HTTPS feed": lambda value: value.__setitem__("SUFeedURL", "http://example.test/appcast.xml"),
            "automatic checks disabled": lambda value: value.__setitem__("SUEnableAutomaticChecks", False),
            "automatic updates disabled by default": lambda value: value.__setitem__("SUAutomaticallyUpdate", False),
            "short schedule": lambda value: value.__setitem__("SUScheduledCheckInterval", 60),
            "post-extraction verification": lambda value: value.__setitem__("SUVerifyUpdateBeforeExtraction", False),
            "unsigned feed": lambda value: value.__setitem__("SURequireSignedFeed", False),
            "signature fallback": lambda value: value.__setitem__("SUSignedFeedFailureExpirationInterval", 3600),
            "profiling": lambda value: value.__setitem__("SUEnableSystemProfiling", True),
            "JavaScript": lambda value: value.__setitem__("SUEnableJavaScript", True),
            "unsafe URL scheme": lambda value: value.__setitem__("SUAllowedURLSchemes", ["https", "file"]),
        }
        baseline = self.load_plist()
        for name, mutation in mutations.items():
            with self.subTest(case=name):
                candidate = copy.deepcopy(baseline)
                mutation(candidate)
                self.assertTrue(self.validate(candidate))


if __name__ == "__main__":
    unittest.main()
