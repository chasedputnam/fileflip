#!/usr/bin/env python3
"""Verify the fail-closed FileFlip packaged media resource layout."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
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


def verify_app(app: Path) -> list[str]:
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
