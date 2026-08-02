#!/usr/bin/env python3
"""Fail-closed consistency checks for FileFlip's Sparkle updater configuration."""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_URL = "https://github.com/sparkle-project/Sparkle"


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def check_hardened_runtime_build_settings(
    failures: list[str],
    build_settings_outputs: dict[str, str] | None = None,
) -> None:
    for configuration in ("Debug", "Release"):
        if build_settings_outputs is None:
            result = subprocess.run(
                [
                    "xcodebuild",
                    "-project",
                    "FileFlip.xcodeproj",
                    "-target",
                    "FileConvertApp",
                    "-configuration",
                    configuration,
                    "-showBuildSettings",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                detail = result.stderr.strip() or result.stdout.strip()
                failures.append(
                    f"{configuration} build settings could not be resolved: {detail}"
                )
                continue
            output = result.stdout
        else:
            output = build_settings_outputs.get(configuration, "")

        values = re.findall(
            r"^\s*ENABLE_HARDENED_RUNTIME\s*=\s*(\S+)\s*$",
            output,
            re.MULTILINE,
        )
        if values != ["YES"]:
            rendered = ", ".join(values) if values else "missing"
            failures.append(
                f"FileConvertApp {configuration} must resolve "
                f"ENABLE_HARDENED_RUNTIME=YES; found {rendered}"
            )


def project_sparkle_version(failures: list[str], project_path: Path | None = None) -> str | None:
    project_path = project_path or ROOT / "FileFlip.xcodeproj/project.pbxproj"
    project_text = project_path.read_text(encoding="utf-8")
    sections = re.findall(
        r"(?ms)^/\* Begin XCRemoteSwiftPackageReference section \*/\n"
        r"(.*?)"
        r"^/\* End XCRemoteSwiftPackageReference section \*/$",
        project_text,
    )
    if len(sections) != 1:
        failures.append(
            f"{project_path}: must contain exactly one XCRemoteSwiftPackageReference section"
        )
        return None

    sparkle_repository_count = len(
        re.findall(
            rf'^\t\t\trepositoryURL = "{re.escape(SPARKLE_URL)}";$',
            sections[0],
            re.MULTILINE,
        )
    )

    reference_pattern = re.compile(
        r'^\t\t[0-9A-F]+ /\* XCRemoteSwiftPackageReference "[^"\n]+" \*/ = \{\n'
        r"(?P<body>(?:^\t{3,}[^\n]*\n)*)"
        r"^\t\t\};$",
        re.MULTILINE,
    )
    sparkle_references: list[str] = []
    for reference in reference_pattern.finditer(sections[0]):
        repositories = re.findall(
            r'^\t\t\trepositoryURL = "([^"\n]+)";$',
            reference.group("body"),
            re.MULTILINE,
        )
        if repositories == [SPARKLE_URL]:
            sparkle_references.append(reference.group("body"))

    if sparkle_repository_count != 1 or len(sparkle_references) != 1:
        failures.append(
            f"{project_path}: must contain exactly one Sparkle XCRemoteSwiftPackageReference"
        )
        return None

    exact_versions = re.findall(
        r"^\t\t\trequirement = \{\n"
        r"^\t\t\t\tkind = exactVersion;\n"
        r"^\t\t\t\tversion = ([0-9][0-9A-Za-z.-]*);\n"
        r"^\t\t\t\};$",
        sparkle_references[0],
        re.MULTILINE,
    )
    if len(exact_versions) != 1:
        failures.append(
            f"{project_path}: Sparkle package requirement must contain exactly one exactVersion pin"
        )
        return None
    return exact_versions[0]


def declared_versions(failures: list[str]) -> dict[str, str]:
    versions: dict[str, str] = {}
    project_version = project_sparkle_version(failures)
    if project_version is not None:
        versions["FileFlip.xcodeproj/project.pbxproj"] = project_version

    package_text = (ROOT / "Package.swift").read_text(encoding="utf-8")
    match = re.search(
        r'\.package\(url:\s*"https://github\.com/sparkle-project/Sparkle(?:\.git)?",\s*exact:\s*"([^"]+)"\)',
        package_text,
    )
    if match is None:
        failures.append("Package.swift must pin Sparkle with an exact version")
    else:
        versions["Package.swift"] = match.group(1)

    generator_text = (ROOT / "scripts/generate-project.rb").read_text(encoding="utf-8")
    match = re.search(r'SPARKLE_VERSION\s*=\s*"([^"]+)"', generator_text)
    if match is None:
        failures.append("scripts/generate-project.rb must declare SPARKLE_VERSION")
    else:
        versions["scripts/generate-project.rb"] = match.group(1)

    contract = load_json(ROOT / "release/release-contract.json")
    updater = contract.get("updater")
    if not isinstance(updater, dict) or not isinstance(updater.get("sparkleVersion"), str):
        failures.append("release/release-contract.json must declare updater.sparkleVersion")
    else:
        versions["release/release-contract.json"] = updater["sparkleVersion"]

    resolved_paths = [
        ROOT / "Package.resolved",
        ROOT / "FileFlip.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ]
    for resolved_path in resolved_paths:
        label = str(resolved_path.relative_to(ROOT))
        if not resolved_path.is_file():
            failures.append(f"{label} is missing; resolve the package graph")
            continue
        resolved = load_json(resolved_path)
        pins = resolved.get("pins")
        sparkle = next(
            (
                pin
                for pin in pins if isinstance(pin, dict)
                and str(pin.get("identity", "")).lower() == "sparkle"
            ),
            None,
        ) if isinstance(pins, list) else None
        state = sparkle.get("state") if isinstance(sparkle, dict) else None
        version = state.get("version") if isinstance(state, dict) else None
        if not isinstance(version, str):
            failures.append(f"{label} must contain a versioned Sparkle pin")
        else:
            versions[label] = version

    return versions


def check_pins(failures: list[str]) -> None:
    versions = declared_versions(failures)
    if versions and len(set(versions.values())) != 1:
        rendered = ", ".join(f"{source}={version}" for source, version in sorted(versions.items()))
        failures.append(f"Sparkle pin mismatch: {rendered}")


def check_bundle_configuration(
    failures: list[str],
    plist_path: Path | None = None,
    updater_contract: dict[str, Any] | None = None,
) -> None:
    plist_path = plist_path or ROOT / "Config/FileConvertApp-Info.plist"
    if updater_contract is None:
        contract = load_json(ROOT / "release/release-contract.json")
        candidate = contract.get("updater")
        if not isinstance(candidate, dict):
            failures.append("release/release-contract.json must declare updater configuration")
            return
        updater_contract = candidate
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    required = {
        "SUFeedURL": f"https://github.com/{updater_contract.get('repository')}/releases/latest/download/{updater_contract.get('feedAssetName')}",
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": True,
        "SUScheduledCheckInterval": 86400,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "SUSignedFeedFailureExpirationInterval": 0,
        "SUEnableSystemProfiling": False,
        "SUEnableJavaScript": False,
        "SUAllowedURLSchemes": ["https"],
    }
    for key, expected in required.items():
        if plist.get(key) != expected:
            failures.append(f"{plist_path}: {key} must equal {expected!r}")
    public_key = plist.get("SUPublicEDKey")
    expected_key = updater_contract.get("publicEdKey")
    if (
        not isinstance(public_key, str)
        or not re.fullmatch(r"[A-Za-z0-9+/]{43}=", public_key)
        or public_key != expected_key
    ):
        failures.append(f"{plist_path}: SUPublicEDKey must match the release contract Ed25519 public key")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pins-only", action="store_true")
    parser.add_argument(
        "--built-app",
        type=Path,
        help="also validate the updater configuration in this built .app",
    )
    args = parser.parse_args()
    failures: list[str] = []
    try:
        check_pins(failures)
        if not args.pins_only:
            check_hardened_runtime_build_settings(failures)
            check_bundle_configuration(failures)
            if args.built_app is not None:
                check_bundle_configuration(failures, args.built_app / "Contents/Info.plist")
    except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        failures.append(str(error))
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("Updater configuration is consistent and fail-closed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
