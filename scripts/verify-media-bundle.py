#!/usr/bin/env python3
"""Verify the fail-closed FileFlip packaged media resource layout."""
from __future__ import annotations

from collections.abc import Callable
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

REQUIRED_LICENSES = frozenset({
    "ffmpeg.txt",
    "lame.txt",
    "libogg.txt",
    "libvorbis.txt",
    "libvpx.txt",
    "opus.txt",
})
REQUIRED_MEDIA_ENTRIES = frozenset({"ffmpeg", "ffprobe", "manifest.json", "LICENSES"})
FLATTENED_MEDIA_NAMES = REQUIRED_LICENSES | frozenset({"ffmpeg", "ffprobe", "manifest.json"})
EXPECTED_TEAM_IDENTIFIER = "C5C4W9B7FS"


def verify_identity_signature(path: Path) -> str | None:
    requirement = (
        "anchor apple generic and "
        f'certificate leaf[subject.OU] = "{EXPECTED_TEAM_IDENTIFIER}"'
    )
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", f"-R={requirement}", str(path)],
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode == 0:
        return None
    return result.stderr.strip() or "codesign rejected the executable"




def safe_entries(directory: Path, label: str, failures: list[str]) -> set[str]:
    try:
        if directory.is_symlink() or not directory.is_dir():
            failures.append(f"{label} is missing or is not a real directory: {directory}")
            return set()
        return {entry.name for entry in directory.iterdir()}
    except OSError as error:
        failures.append(f"cannot inspect {label} {directory}: {error}")
        return set()


def require_regular(path: Path, label: str, failures: list[str], executable: bool = False) -> None:
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        failures.append(f"missing {label}: {path} ({error})")
        return
    if not stat.S_ISREG(mode):
        failures.append(f"{label} is not a regular file: {path}")
    elif executable and mode & 0o111 == 0:
        failures.append(f"{label} is not executable: {path}")


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_manifest(
    media: Path,
    failures: list[str],
    identity_validator: Callable[[Path], str | None],
) -> None:
    manifest_path = media / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        artifacts = manifest["artifacts"]
        by_name = {artifact["name"]: artifact for artifact in artifacts}
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError):
        failures.append(f"media manifest is invalid: {manifest_path}")
        return
    if len(artifacts) != 2 or set(by_name) != {"ffmpeg", "ffprobe"}:
        failures.append("media manifest does not declare exactly ffmpeg and ffprobe")
        return
    for name in ("ffmpeg", "ffprobe"):
        artifact = by_name[name]
        signature = artifact.get("signature")
        if artifact.get("path") != name or not isinstance(signature, dict):
            failures.append(f"media manifest artifact is invalid: {name}")
            continue
        mode = signature.get("mode")
        expected = artifact.get("sha256")
        if mode == "adhoc":
            if not isinstance(expected, str) or signature.get("teamIdentifier") is not None:
                failures.append(f"ad-hoc media manifest artifact is invalid: {name}")
                continue
            try:
                actual = file_sha256(media / name)
            except OSError as error:
                failures.append(f"cannot hash packaged {name}: {error}")
                continue
            if actual != expected.lower():
                failures.append(f"packaged {name} hash does not match the media manifest")
        elif mode == "identity":
            if expected is not None or signature.get("teamIdentifier") != EXPECTED_TEAM_IDENTIFIER:
                failures.append(f"identity-signed media manifest artifact is invalid: {name}")
                continue
            if error := identity_validator(media / name):
                failures.append(f"packaged {name} signature is invalid: {error}")
        else:
            failures.append(f"media manifest signature mode is invalid: {name}")


def verify_app(
    app: Path,
    identity_validator: Callable[[Path], str | None] = verify_identity_signature,
) -> list[str]:
    failures: list[str] = []
    resources = app / "Contents" / "Resources"
    media = resources / "MediaTools"
    licenses = media / "LICENSES"

    resource_entries = safe_entries(resources, "application resources", failures)
    flattened = sorted(resource_entries & FLATTENED_MEDIA_NAMES)
    if flattened:
        failures.append(f"media artifacts are flattened into application resources: {', '.join(flattened)}")

    media_entries = safe_entries(media, "MediaTools", failures)
    if media_entries and media_entries != REQUIRED_MEDIA_ENTRIES:
        missing = sorted(REQUIRED_MEDIA_ENTRIES - media_entries)
        unexpected = sorted(media_entries - REQUIRED_MEDIA_ENTRIES)
        if missing:
            failures.append(f"MediaTools entries missing: {', '.join(missing)}")
        if unexpected:
            failures.append(f"MediaTools entries unexpected: {', '.join(unexpected)}")

    require_regular(media / "ffmpeg", "ffmpeg", failures, executable=True)
    require_regular(media / "ffprobe", "ffprobe", failures, executable=True)
    require_regular(media / "manifest.json", "media manifest", failures)

    license_entries = safe_entries(licenses, "media licenses", failures)
    if license_entries and license_entries != REQUIRED_LICENSES:
        missing = sorted(REQUIRED_LICENSES - license_entries)
        unexpected = sorted(license_entries - REQUIRED_LICENSES)
        if missing:
            failures.append(f"license notices missing: {', '.join(missing)}")
        if unexpected:
            failures.append(f"license notices unexpected: {', '.join(unexpected)}")
    for name in REQUIRED_LICENSES:
        require_regular(licenses / name, f"license notice {name}", failures)
    verify_manifest(media, failures, identity_validator)
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    failures = verify_app(args.app)
    if failures:
        for failure in failures:
            print(f"media bundle check failed: {failure}", file=sys.stderr)
        return 1
    print(f"Media bundle layout verified: {args.app}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
