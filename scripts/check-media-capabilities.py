#!/usr/bin/env python3
"""Compare public packaged-media declarations with InstalledMediaContract."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = ROOT / "release" / "release-contract.json"
README_PATH = ROOT / "README.md"
SITE_PATH = ROOT / "site" / "src" / "pages" / "index.astro"


class ConsistencyError(RuntimeError):
    pass


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ConsistencyError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=strict_object)
    except (OSError, json.JSONDecodeError) as error:
        raise ConsistencyError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ConsistencyError(f"{path} must contain a JSON object")
    return value


def exported_contract() -> dict[str, Any]:
    result = subprocess.run(
        ["swift", "run", "packaged-media-contract"],
        cwd=ROOT,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise ConsistencyError(f"contract exporter failed: {result.stderr.strip()}")
    try:
        value = json.loads(result.stdout, object_pairs_hook=strict_object)
    except json.JSONDecodeError as error:
        raise ConsistencyError(f"contract exporter returned invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ConsistencyError("contract exporter did not return an object")
    return value


def expected_export(release_contract: dict[str, Any]) -> dict[str, Any]:
    media = release_contract.get("packagedMedia")
    if not isinstance(media, dict) or not isinstance(media.get("expected"), dict):
        raise ConsistencyError("release contract lacks packagedMedia.expected")
    expected = media["expected"]
    return {
        "schemaVersion": 1,
        "contractVersion": media.get("contractVersion"),
        "providerID": media.get("providerID"),
        "routeSetSHA256": expected.get("routeSetSHA256"),
        "totalFormats": expected.get("formatCount"),
        "totalRoutes": expected.get("routeCount"),
        "audio": {
            "formats": expected.get("audioFormats"),
            "directedNonIdentityRoutes": expected.get("audioRouteCount"),
        },
        "video": {
            "formats": expected.get("videoFormats"),
            "directedNonIdentityRoutes": expected.get("videoRouteCount"),
        },
    }


def display_names(formats: list[dict[str, Any]]) -> str:
    names: list[str] = []
    for item in formats:
        canonical = item["canonicalExtension"].upper()
        aliases = [alias.upper() for alias in item["aliases"]]
        names.append("/".join([canonical, *aliases]))
    return ", ".join(names)


def verify_declarations(release_contract: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    expected = expected_export(release_contract)
    observed = exported_contract()
    if observed != expected:
        failures.append("release packaged-media declaration differs from InstalledMediaContract export")

    audio = display_names(expected["audio"]["formats"])
    video = display_names(expected["video"]["formats"])
    readme_declaration = f"| Bundled FFmpeg/ffprobe | {audio}; {video} |"
    site_audio = f"['Audio', '{audio}'],"
    site_video = f"['Video', '{video}'],"
    try:
        readme = README_PATH.read_text(encoding="utf-8")
        site = SITE_PATH.read_text(encoding="utf-8")
    except OSError as error:
        return [*failures, f"cannot read public capability declaration: {error}"]
    if readme_declaration not in readme:
        failures.append("README bundled-media capability row differs from InstalledMediaContract")
    if site_audio not in site or site_video not in site:
        failures.append("website audio/video capability lists differ from InstalledMediaContract")
    return failures


def main() -> int:
    try:
        failures = verify_declarations(load_json(CONTRACT_PATH))
    except ConsistencyError as error:
        failures = [str(error)]
    if failures:
        print("MEDIA CAPABILITY DECLARATIONS INVALID", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("Media capability declarations match InstalledMediaContract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
