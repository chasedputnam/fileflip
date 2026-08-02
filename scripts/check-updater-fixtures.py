#!/usr/bin/env python3
"""Validate or explicitly regenerate deterministic synthetic updater fixtures."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import tempfile
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "Fixtures" / "Updater"
MANIFEST = FIXTURES / "manifest.json"
UPDATE_ENVIRONMENT = "FILECONVERT_UPDATE_UPDATER_FIXTURES"


def load_helper():
    path = ROOT / "scripts" / "prepare-updater-release.py"
    spec = importlib.util.spec_from_file_location("prepare_updater_release", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load updater release helper")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture_paths(manifest: dict[str, object]) -> dict[str, Path]:
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("fixture manifest files must be a non-empty object")
    result: dict[str, Path] = {}
    for relative, expected in files.items():
        if not isinstance(relative, str) or not isinstance(expected, str):
            raise ValueError("fixture manifest file entries must map strings to strings")
        path = FIXTURES / relative
        if not path.is_file():
            raise ValueError(f"fixture is missing: {relative}")
        result[relative] = path
    return result


def load_manifest() -> dict[str, object]:
    value = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("mode") != "compare-only":
        raise ValueError("updater fixture manifest must declare compare-only mode")
    if value.get("regenerationEnvironment") != f"{UPDATE_ENVIRONMENT}=1":
        raise ValueError("updater fixture regeneration gate does not match the script")
    return value


def synthetic_contract(helper, manifest: dict[str, object]):
    key = manifest.get("syntheticKey")
    if not isinstance(key, dict) or not isinstance(key.get("publicKey"), str):
        raise ValueError("fixture manifest synthetic public key is missing")
    production = helper.load_contract()
    return helper.UpdaterContract(
        bundle_identifier="app.fileconvert.FileConvert",
        minimum_macos_major=production.minimum_macos_major,
        required_architectures=production.required_architectures,
        sparkle_version=production.sparkle_version,
        keychain_account="synthetic-fixture",
        public_key=key["publicKey"],
        repository=production.repository,
        feed_asset_name=production.feed_asset_name,
        disk_image_asset_name=production.disk_image_asset_name,
        checksum_asset_name=production.checksum_asset_name,
    )


def regenerate(helper, manifest: dict[str, object]) -> None:
    if os.environ.get(UPDATE_ENVIRONMENT) != "1":
        raise ValueError(f"regeneration requires {UPDATE_ENVIRONMENT}=1")
    dmg = FIXTURES / "FileFlip.dmg"
    test_vector = FIXTURES / "ed25519-rfc8032-vector1.txt"
    appcast = FIXTURES / "appcast.xml"
    signature = helper.run_tool(
        [str(helper.load_contract().tools_directory / "sign_update"), "--ed-key-file", str(test_vector), "-p", str(dmg)]
    )
    appcast.write_text(
        '<?xml version="1.0" standalone="yes"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        '  <channel>\n'
        '    <title>FileFlip</title>\n'
        '    <item>\n'
        '      <title>1.2.3</title>\n'
        '      <link>https://github.com/chasedputnam/file-flip/releases/tag/v1.2.3</link>\n'
        '      <sparkle:fullReleaseNotesLink>https://github.com/chasedputnam/file-flip/releases/tag/v1.2.3</sparkle:fullReleaseNotesLink>\n'
        '      <sparkle:version>123</sparkle:version>\n'
        '      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>\n'
        '      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n'
        '      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n'
        f'      <enclosure url="https://github.com/chasedputnam/file-flip/releases/download/v1.2.3/FileFlip.dmg" length="{dmg.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/>\n'
        '    </item>\n'
        '  </channel>\n'
        '</rss>\n',
        encoding="utf-8",
    )
    helper.run_tool(
        [str(helper.load_contract().tools_directory / "sign_update"), "--ed-key-file", str(test_vector), str(appcast)]
    )
    checksum = FIXTURES / "FileFlip.dmg.sha256"
    checksum.write_text(f"{digest(dmg)}  FileFlip.dmg\n", encoding="utf-8")
    files = fixture_paths(manifest)
    manifest["files"] = {relative: digest(path) for relative, path in files.items()}
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def validate_synthetic_notarization(app: Path) -> None:
    if app != FIXTURES / "FileFlip.app":
        raise ValueError("synthetic notarization validator received an unexpected application")




def validate(helper, manifest: dict[str, object]) -> None:
    files = fixture_paths(manifest)
    expected = manifest["files"]
    assert isinstance(expected, dict)
    for relative, path in files.items():
        actual = digest(path)
        if actual != expected[relative]:
            raise ValueError(f"fixture hash mismatch: {relative}")
    contract = synthetic_contract(helper, manifest)
    with tempfile.TemporaryDirectory(prefix="fileflip-synthetic-generate-keys-") as temporary:
        generate_keys = Path(temporary) / "generate_keys"
        generate_keys.write_text(
            f"#!/bin/sh\nprintf '%s\\n' '{contract.public_key}'\n", encoding="utf-8"
        )
        generate_keys.chmod(0o755)
        helper.validate_metadata(
            app=FIXTURES / "FileFlip.app",
            dmg=FIXTURES / "FileFlip.dmg",
            appcast=FIXTURES / "appcast.xml",
            checksum=FIXTURES / "FileFlip.dmg.sha256",
            tag="v1.2.3",
            contract=contract,
            sign_update=contract.tools_directory / "sign_update",
            generate_keys=generate_keys,
            signing_arguments=["--ed-key-file", str(FIXTURES / "ed25519-rfc8032-vector1.txt")],
            initial_release=True,
            notarization_validator=validate_synthetic_notarization,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()
    try:
        helper = load_helper()
        manifest = load_manifest()
        if args.update:
            regenerate(helper, manifest)
        validate(helper, load_manifest())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("Updater fixtures are unchanged and cryptographically valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
