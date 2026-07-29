#!/usr/bin/env python3
"""Strictly certify FileFlip media fixtures against bytes and packaged ffprobe facts."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GENERATOR_PATH = Path(__file__).with_name("generate-media-fixtures.py")
SPEC = importlib.util.spec_from_file_location("fileflip_media_fixture_generator", GENERATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load media fixture generator")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)

ROOT_KEYS = {"schemaVersion", "recipeVersion", "generator", "fixtures"}
GENERATOR_KEYS = {"ffmpegVersion", "manifestSHA256"}
FIXTURE_KEYS = {"id", "family", "format", "canonicalExtension", "path", "sha256", "byteLength", "license", "provenance", "facts"}
FACT_KEYS = {"formatNames", "majorBrand", "durationMilliseconds", "streams"}
AUDIO_STREAM_KEYS = {"kind", "codec", "frameCount", "sampleRate", "channels"}
VIDEO_STREAM_KEYS = {"kind", "codec", "frameCount", "width", "height"}
HEX = frozenset("0123456789abcdef")


class CertificationError(RuntimeError):
    pass


def exact_keys(value: object, expected: set[str], label: str) -> dict:
    if not isinstance(value, dict) or set(value) != expected:
        observed = set(value) if isinstance(value, dict) else type(value).__name__
        raise CertificationError(f"{label}: expected fields {sorted(expected)}, observed {observed}")
    return value


def bounded_integer(value: object, minimum: int, maximum: int, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise CertificationError(f"{label}: expected integer in {minimum}...{maximum}")
    return value


def nonempty_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value.strip() != value:
        raise CertificationError(f"{label}: expected a non-empty trimmed string")
    return value


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def safe_fixture_path(root: Path, relative_value: object, fixture_id: str) -> Path:
    relative = Path(nonempty_string(relative_value, f"{fixture_id}.path"))
    if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != str(relative_value):
        raise CertificationError(f"{fixture_id}.path: expected a normalized safe relative path")
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise CertificationError(f"{fixture_id}.path: missing regular non-symlink fixture")
    return path


def validate_stream(stream: object, fixture_id: str, index: int) -> None:
    label = f"{fixture_id}.facts.streams[{index}]"
    if not isinstance(stream, dict):
        raise CertificationError(f"{label}: expected an object")
    kind = stream.get("kind")
    expected_keys = AUDIO_STREAM_KEYS if kind == "audio" else VIDEO_STREAM_KEYS if kind == "video" else set()
    if not expected_keys:
        raise CertificationError(f"{label}.kind: expected audio or video")
    exact_keys(stream, expected_keys, label)
    nonempty_string(stream["codec"], f"{label}.codec")
    bounded_integer(stream["frameCount"], 1, 1_000_000, f"{label}.frameCount")
    if kind == "audio":
        bounded_integer(stream["sampleRate"], 8_000, 384_000, f"{label}.sampleRate")
        bounded_integer(stream["channels"], 1, 32, f"{label}.channels")
    else:
        bounded_integer(stream["width"], 1, 8_192, f"{label}.width")
        bounded_integer(stream["height"], 1, 8_192, f"{label}.height")


def certify(manifest_path: Path, media_tools: Path) -> None:
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise CertificationError("fixture manifest must be a regular non-symlink file")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CertificationError(f"cannot decode fixture manifest: {error}") from error
    exact_keys(manifest, ROOT_KEYS, "manifest")
    if manifest["schemaVersion"] != 1 or manifest["recipeVersion"] != 1:
        raise CertificationError("manifest schemaVersion and recipeVersion must both equal 1")
    generator = exact_keys(manifest["generator"], GENERATOR_KEYS, "generator")
    ffmpeg, ffprobe, media_manifest = GENERATOR.verified_tools(media_tools.resolve())
    if generator["ffmpegVersion"] != GENERATOR.tool_version(ffmpeg):
        raise CertificationError("generator.ffmpegVersion differs from the packaged tool")
    if generator["manifestSHA256"] != digest(media_tools / "manifest.json"):
        raise CertificationError("generator.manifestSHA256 differs from the packaged manifest")
    if media_manifest.get("ffmpegVersion") != generator["ffmpegVersion"]:
        raise CertificationError("fixture and packaged manifest versions differ")

    fixtures = manifest["fixtures"]
    if not isinstance(fixtures, list) or len(fixtures) != len(GENERATOR.FORMATS):
        raise CertificationError(f"fixtures: expected exactly {len(GENERATOR.FORMATS)} entries")
    expected = {
        f"{family}-{logical_format}": (family, logical_format, extension, f"{family}/source.{extension}")
        for family, logical_format, extension, _ in GENERATOR.FORMATS
    }
    seen_ids: set[str] = set()
    seen_formats: set[tuple[str, str]] = set()
    seen_paths: set[str] = set()
    root = manifest_path.parent
    for index, fixture_value in enumerate(fixtures):
        fixture = exact_keys(fixture_value, FIXTURE_KEYS, f"fixtures[{index}]")
        fixture_id = nonempty_string(fixture["id"], f"fixtures[{index}].id")
        if fixture_id in seen_ids or fixture_id not in expected:
            raise CertificationError(f"{fixture_id}: duplicate or unexpected fixture id")
        seen_ids.add(fixture_id)
        family, logical_format, extension, relative = expected[fixture_id]
        if (fixture["family"], fixture["format"], fixture["canonicalExtension"], fixture["path"]) != (family, logical_format, extension, relative):
            raise CertificationError(f"{fixture_id}: family, format, extension, or path differs from the installed contract")
        format_key = (family, logical_format)
        if format_key in seen_formats or relative in seen_paths:
            raise CertificationError(f"{fixture_id}: duplicate logical format or path")
        seen_formats.add(format_key)
        seen_paths.add(relative)
        nonempty_string(fixture["license"], f"{fixture_id}.license")
        nonempty_string(fixture["provenance"], f"{fixture_id}.provenance")
        byte_length = bounded_integer(fixture["byteLength"], 1, 16 * 1024 * 1024, f"{fixture_id}.byteLength")
        sha = fixture["sha256"]
        if not isinstance(sha, str) or len(sha) != 64 or not set(sha).issubset(HEX):
            raise CertificationError(f"{fixture_id}.sha256: expected lowercase SHA-256")
        path = safe_fixture_path(root, fixture["path"], fixture_id)
        if path.stat().st_size != byte_length or digest(path) != sha:
            raise CertificationError(f"{fixture_id}: byte length or SHA-256 mismatch")

        facts = exact_keys(fixture["facts"], FACT_KEYS, f"{fixture_id}.facts")
        names = facts["formatNames"]
        if not isinstance(names, list) or not names or names != sorted(set(names)) or not all(isinstance(name, str) and name for name in names):
            raise CertificationError(f"{fixture_id}.facts.formatNames: expected a sorted unique non-empty string array")
        if facts["majorBrand"] is not None and not isinstance(facts["majorBrand"], str):
            raise CertificationError(f"{fixture_id}.facts.majorBrand: expected string or null")
        bounded_integer(facts["durationMilliseconds"], 500, 2_000, f"{fixture_id}.facts.durationMilliseconds")
        streams = facts["streams"]
        expected_stream_kinds = ["audio"] if family == "audio" else ["video", "audio"]
        if not isinstance(streams, list) or [stream.get("kind") if isinstance(stream, dict) else None for stream in streams] != expected_stream_kinds:
            raise CertificationError(f"{fixture_id}.facts.streams: expected exact {expected_stream_kinds} stream order")
        for stream_index, stream in enumerate(streams):
            validate_stream(stream, fixture_id, stream_index)
        observed_facts = GENERATOR.probe_facts(ffprobe, path)
        if observed_facts != facts:
            raise CertificationError(f"{fixture_id}: packaged ffprobe facts differ from the reviewed manifest")

    actual_entries = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    expected_entries = {"manifest.json", *seen_paths}
    if actual_entries != expected_entries:
        raise CertificationError(f"fixture directory entries differ: expected {sorted(expected_entries)}, observed {sorted(actual_entries)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media-tools", type=Path, required=True)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    try:
        certify(args.manifest.resolve(), args.media_tools.resolve())
    except (CertificationError, GENERATOR.FixtureError) as error:
        print(f"media fixture certification failed: {error}", file=sys.stderr)
        return 1
    print(f"certified {len(GENERATOR.FORMATS)} media fixtures: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
