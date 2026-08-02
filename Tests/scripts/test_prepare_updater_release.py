#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Tests" / "Fixtures" / "Updater"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


release = load_module("prepare_updater_release_tests", ROOT / "scripts" / "prepare-updater-release.py")
fixtures = load_module("check_updater_fixtures_tests", ROOT / "scripts" / "check-updater-fixtures.py")


class PrepareUpdaterReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "Updater"
        shutil.copytree(FIXTURES, self.root)
        manifest = json.loads((self.root / "manifest.json").read_text(encoding="utf-8"))
        production = release.load_contract()
        self.contract = release.UpdaterContract(
            bundle_identifier="app.fileconvert.FileConvert",
            minimum_macos_major=production.minimum_macos_major,
            required_architectures=production.required_architectures,
            sparkle_version=production.sparkle_version,
            keychain_account="synthetic-fixture",
            public_key=manifest["syntheticKey"]["publicKey"],
            repository=production.repository,
            feed_asset_name=production.feed_asset_name,
            disk_image_asset_name=production.disk_image_asset_name,
            checksum_asset_name=production.checksum_asset_name,
        )
        self.sign_update = production.tools_directory / "sign_update"
        self.generate_keys = self.root / "generate_keys"
        self.write_generate_keys(self.contract.public_key)
        self.signing_arguments = ["--ed-key-file", str(self.root / "ed25519-rfc8032-vector1.txt")]

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def synthetic_notarization(
        self,
        *,
        rejected_tool: str | None = None,
        observed: list[list[str]] | None = None,
    ):
        original_run_tool = release.run_tool

        def run_tool(arguments: list[str], *, input_text: str | None = None) -> str:
            executable = Path(arguments[0]).name
            if executable in {"codesign", "xcrun", "spctl"}:
                if observed is not None:
                    observed.append(arguments)
                if executable == rejected_tool:
                    raise release.ReleaseMetadataError(f"{executable} failed: rejected fixture")
                return ""
            return original_run_tool(arguments, input_text=input_text)

        return mock.patch.object(release, "run_tool", side_effect=run_tool)


    def validate(
        self,
        *,
        previous_appcast: Path | None = None,
        initial_release: bool = True,
        rejected_tool: str | None = None,
        observed: list[list[str]] | None = None,
    ) -> None:
        with self.synthetic_notarization(rejected_tool=rejected_tool, observed=observed):
            release.validate_metadata(
                app=self.root / "FileFlip.app",
                dmg=self.root / "FileFlip.dmg",
                appcast=self.root / "appcast.xml",
                checksum=self.root / "FileFlip.dmg.sha256",
                tag="v1.2.3",
                contract=self.contract,
                sign_update=self.sign_update,
                generate_keys=self.generate_keys,
                signing_arguments=self.signing_arguments,
                previous_appcast=previous_appcast,
                initial_release=initial_release,
            )

    def assert_rejected(self, message: str, **arguments) -> None:
        with self.assertRaisesRegex(release.ReleaseMetadataError, message):
            self.validate(**arguments)

    def mutate_info(self, mutation) -> None:
        path = self.root / "FileFlip.app" / "Contents" / "Info.plist"
        with path.open("rb") as handle:
            value = plistlib.load(handle)
        mutation(value)
        with path.open("wb") as handle:
            plistlib.dump(value, handle, sort_keys=True)

    def write_generate_keys(self, public_key: str) -> None:
        self.generate_keys.write_text(
            f"#!/bin/sh\nprintf '%s\\n' '{public_key}'\n", encoding="utf-8"
        )
        self.generate_keys.chmod(0o755)

    def mutate_and_resign_feed(self, mutation, *, destination: Path | None = None) -> Path:
        source = self.root / "appcast.xml"
        target = destination or source
        data = source.read_bytes()
        match = release.FEED_SIGNATURE.search(data)
        self.assertIsNotNone(match)
        root = ET.fromstring(data[: match.start()])
        mutation(root.find("./channel/item"))
        ET.register_namespace("sparkle", SPARKLE_NAMESPACE)
        target.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True))
        release.run_tool([str(self.sign_update), *self.signing_arguments, str(target)])
        return target

    def test_valid_fixture_passes_real_signature_verification(self) -> None:
        observed: list[list[str]] = []
        self.validate(observed=observed)
        app = str(self.root / "FileFlip.app")
        self.assertEqual(
            observed,
            [
                ["codesign", "--verify", "--deep", "--strict", "--verbose=2", app],
                ["xcrun", "stapler", "validate", app],
                [
                    "spctl", "--assess", "--type", "execute", "--verbose=4", app,
                ],
            ],
        )

    def test_unstapled_candidate_is_rejected(self) -> None:
        self.assert_rejected("xcrun failed", rejected_tool="xcrun")

    def test_gatekeeper_rejected_candidate_is_rejected(self) -> None:
        self.assert_rejected("spctl failed", rejected_tool="spctl")

    def test_valid_keychain_key_is_required_for_validation(self) -> None:
        self.write_generate_keys("PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw=")
        self.assert_rejected("Keychain signing key does not match")

    def test_generation_rejects_an_unstapled_source_app_before_metadata_generation(self) -> None:
        release_notes = self.root / "release-notes.md"
        release_notes.write_text("Release notes", encoding="utf-8")
        output_directory = self.root / "release-output"
        observed: list[list[str]] = []

        with (
            mock.patch.object(release, "verify_signing_key"),
            mock.patch.object(release, "validate_candidate_increases"),
            self.synthetic_notarization(rejected_tool="xcrun", observed=observed),
        ):
            with self.assertRaisesRegex(release.ReleaseMetadataError, "xcrun failed"):
                release.prepare_release(
                    app=self.root / "FileFlip.app",
                    source_dmg=self.root / "FileFlip.dmg",
                    release_notes=release_notes,
                    output_directory=output_directory,
                    tag="v1.2.3",
                    contract=self.contract,
                    previous_appcast=None,
                    initial_release=True,
                )

        self.assertEqual(
            observed,
            [
                ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(self.root / "FileFlip.app")],
                ["xcrun", "stapler", "validate", str(self.root / "FileFlip.app")],
            ],
        )
        self.assertFalse(output_directory.exists())

    def test_generation_failure_is_atomic_and_retry_publishes_complete_output(self) -> None:
        release_notes = self.root / "release-notes.md"
        release_notes.write_text("Release notes", encoding="utf-8")
        output_directory = self.root / "release-output"

        def fake_run_tool(arguments: list[str], *, input_text: str | None = None) -> str:
            executable = Path(arguments[0]).name
            if executable == "generate_keys":
                return self.contract.public_key
            if executable == "generate_appcast":
                Path(arguments[arguments.index("-o") + 1]).write_text(
                    "<rss/>", encoding="utf-8"
                )
            return ""

        arguments = {
            "app": self.root / "FileFlip.app",
            "source_dmg": self.root / "FileFlip.dmg",
            "release_notes": release_notes,
            "output_directory": output_directory,
            "tag": "v1.2.3",
            "contract": self.contract,
            "previous_appcast": None,
            "initial_release": True,
        }
        with (
            mock.patch.object(release, "run_tool", side_effect=fake_run_tool),
            mock.patch.object(
                release,
                "validate_metadata",
                side_effect=release.ReleaseMetadataError("generated appcast validation failed"),
            ),
        ):
            with self.assertRaisesRegex(release.ReleaseMetadataError, "generated appcast validation failed"):
                release.prepare_release(**arguments)
        self.assertFalse(output_directory.exists())
        self.assertEqual(list(output_directory.parent.glob(f".{output_directory.name}.*")), [])

        with (
            mock.patch.object(release, "run_tool", side_effect=fake_run_tool),
            mock.patch.object(release, "validate_metadata"),
        ):
            release.prepare_release(**arguments)
        self.assertEqual(
            {path.name for path in output_directory.iterdir()},
            {
                self.contract.disk_image_asset_name,
                self.contract.feed_asset_name,
                self.contract.checksum_asset_name,
                f"{Path(self.contract.disk_image_asset_name).stem}.md",
            },
        )

    def test_disk_image_must_embed_the_validated_application(self) -> None:
        (self.root / "FileFlip.app" / "Contents" / "candidate-only.txt").write_text(
            "not embedded in the disk image",
            encoding="utf-8",
        )
        self.assert_rejected("does not match the validated --app bundle")

    def test_tampered_candidate_is_rejected(self) -> None:
        with (self.root / "FileFlip.dmg").open("ab") as handle:
            handle.write(b"tampered")
        self.assert_rejected("hdiutil failed|enclosure length|checksum|sign_update failed")

    def test_tampered_feed_signature_is_rejected(self) -> None:
        path = self.root / "appcast.xml"
        path.write_bytes(path.read_bytes().replace(b"<title>FileFlip</title>", b"<title>FileFlop</title>", 1))
        self.assert_rejected("sign_update failed")

    def test_unsigned_feed_is_rejected(self) -> None:
        path = self.root / "appcast.xml"
        match = release.FEED_SIGNATURE.search(path.read_bytes())
        self.assertIsNotNone(match)
        path.write_bytes(path.read_bytes()[: match.start()])
        self.assert_rejected("signed-feed envelope")

    def test_non_increasing_candidate_is_rejected(self) -> None:
        previous = self.root / "previous.xml"
        self.mutate_and_resign_feed(
            lambda item: (
                item.find(f"{{{SPARKLE_NAMESPACE}}}shortVersionString").__setattr__("text", "2.0.0"),
                item.find(f"{{{SPARKLE_NAMESPACE}}}version").__setattr__("text", "200"),
            ),
            destination=previous,
        )
        self.assert_rejected("candidate version does not increase", previous_appcast=previous, initial_release=False)

    def test_tampered_previous_appcast_is_rejected(self) -> None:
        previous = self.root / "previous.xml"
        shutil.copy2(self.root / "appcast.xml", previous)
        previous.write_bytes(
            previous.read_bytes().replace(
                b"<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>",
                b"<sparkle:shortVersionString>0.2.3</sparkle:shortVersionString>",
                1,
            )
        )
        self.assert_rejected("sign_update failed", previous_appcast=previous, initial_release=False)


    def test_prerelease_candidate_version_is_rejected(self) -> None:
        self.mutate_info(lambda info: info.__setitem__("CFBundleShortVersionString", "1.2.3-beta.1"))
        self.assert_rejected("stable numeric dotted version")

    def test_prerelease_channel_is_rejected(self) -> None:
        self.mutate_and_resign_feed(
            lambda item: ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}channel").__setattr__("text", "beta")
        )
        self.assert_rejected("must not select a prerelease channel")

    def test_unsupported_macos_requirement_is_rejected(self) -> None:
        self.mutate_info(lambda info: info.__setitem__("LSMinimumSystemVersion", "15.0"))
        self.assert_rejected("minimum macOS version")

    def test_unsupported_architecture_is_rejected(self) -> None:
        self.mutate_and_resign_feed(
            lambda item: item.find(f"{{{SPARKLE_NAMESPACE}}}hardwareRequirements").__setattr__("text", "x86_64")
        )
        self.assert_rejected("hardware requirements")

    def test_incomplete_feed_is_rejected(self) -> None:
        self.mutate_and_resign_feed(lambda item: item.remove(item.find("enclosure")))
        self.assert_rejected("missing its enclosure")

    def test_identity_mismatch_is_rejected(self) -> None:
        self.mutate_info(lambda info: info.__setitem__("CFBundleIdentifier", "example.invalid.FileFlip"))
        self.assert_rejected("bundle identifier")

    def test_mutable_enclosure_url_is_rejected(self) -> None:
        self.mutate_and_resign_feed(
            lambda item: item.find("enclosure").set(
                "url", "https://github.com/chasedputnam/file-flip/releases/latest/download/FileFlip.dmg"
            )
        )
        self.assert_rejected("candidate-versioned and immutable")

    def test_malformed_signed_xml_is_rejected(self) -> None:
        path = self.root / "appcast.xml"
        data = path.read_bytes()
        path.write_bytes(b"!" + data[1:])
        self.assert_rejected("XML is malformed")

    def test_release_history_selection_is_fail_closed(self) -> None:
        with self.assertRaisesRegex(release.ReleaseMetadataError, "select exactly one"):
            self.validate(initial_release=False)


class UpdaterFixtureTests(unittest.TestCase):
    def test_manifest_is_compare_only_and_fixture_is_valid(self) -> None:
        fixtures.validate(fixtures.load_helper(), fixtures.load_manifest())

    def test_synthetic_notarization_validator_rejects_an_unexpected_app(self) -> None:
        with self.assertRaisesRegex(ValueError, "unexpected application"):
            fixtures.validate_synthetic_notarization(FIXTURES / "unexpected.app")

    def test_regeneration_requires_explicit_environment_gate(self) -> None:
        manifest = fixtures.load_manifest()
        helper = fixtures.load_helper()
        with self.assertRaisesRegex(ValueError, "regeneration requires"):
            fixtures.regenerate(helper, manifest)


if __name__ == "__main__":
    unittest.main()
