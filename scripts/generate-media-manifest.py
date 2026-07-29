#!/usr/bin/env python3
"""Generate a fail-closed manifest for pinned FFmpeg media tools.

The generator executes only direct argument vectors. It rejects a binary unless
its observed FFmpeg configuration and component inventory meet this file's
approved LGPL/BSD profile.

Usage:
  generate-media-manifest.py --ffmpeg PATH --ffprobe PATH --source-lock PATH --output PATH
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

SCHEMA_VERSION = 1
ARCHITECTURES = ("arm64",)
MAX_OUTPUT = 1024 * 1024
FORBIDDEN_CONFIGURATION = frozenset({"--enable-gpl", "--enable-nonfree", "--enable-version3"})
APPROVED_ENABLED_CONFIGURATION = frozenset({
    "--enable-ffmpeg", "--enable-ffprobe", "--enable-libmp3lame", "--enable-libopus",
    "--enable-libvorbis", "--enable-libvpx", "--enable-static", "--disable-shared",
    "--enable-protocol=file", "--enable-avcodec", "--enable-avfilter", "--enable-avformat",
    "--enable-avutil", "--enable-swresample", "--enable-swscale",
    "--disable-network", "--disable-autodetect", "--disable-doc", "--disable-debug",
    "--disable-ffplay", "--disable-programs", "--disable-everything",
})
APPROVED_FLAG_PREFIXES = (
    "--prefix=", "--arch=", "--target-os=", "--cc=", "--cxx=", "--ar=", "--ranlib=", "--nm=",
    "--pkg-config-flags=", "--enable-decoder=", "--enable-encoder=", "--enable-demuxer=", "--enable-muxer=", "--enable-indev=",
    "--enable-parser=", "--enable-filter=", "--extra-cflags=", "--extra-ldflags=", "--extra-libs=",
)
EXPECTED_INVENTORY = {
    "encoders": frozenset({"aac", "flac", "libmp3lame", "libopus", "libvorbis", "libvpx", "libvpx-vp9", "mpeg4", "pcm_s16be", "pcm_s16le"}),
    "muxers": frozenset({"adts", "aiff", "flac", "ipod", "matroska", "mov", "mp3", "mp4", "null", "ogg", "opus", "wav", "webm"}),
    "demuxers": frozenset({"aac", "aiff", "flac", "matroska", "mov", "mp3", "mpegts", "ogg", "wav"}),
}

class ManifestError(RuntimeError):
    pass

def run(argv: list[str]) -> str:
    try:
        result = subprocess.run(argv, check=False, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ManifestError(f"cannot execute {argv[0]}: {error}") from error
    if len(result.stdout) > MAX_OUTPUT or len(result.stderr) > MAX_OUTPUT:
        raise ManifestError(f"command output exceeded {MAX_OUTPUT} bytes: {argv[0]}")
    if result.returncode != 0:
        raise ManifestError(f"command failed ({result.returncode}): {argv[0]}")
    return result.stdout.decode("utf-8", "strict")

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def architectures(path: Path) -> list[str]:
    output = run(["/usr/bin/lipo", "-archs", str(path)])
    observed = output.strip().split()
    if sorted(observed) != sorted(ARCHITECTURES):
        raise ManifestError(f"{path} must be arm64-only, observed: {output.strip()}")
    return list(ARCHITECTURES)

def dynamic_dependencies(path: Path) -> None:
    output = run(["/usr/bin/otool", "-L", str(path)])
    dependencies = [line.strip().split(" ", 1)[0] for line in output.splitlines() if line[:1].isspace()]
    non_system = [dependency for dependency in dependencies if not dependency.startswith("/usr/lib/") and not dependency.startswith("/System/Library/")]
    if non_system:
        raise ManifestError(f"{path} has non-system dynamic dependencies: {', '.join(non_system)}")

ALLOWED_ESCAPES = frozenset({" ", "\t", "'", '"', "\\"})


def tokenize_configuration_line(text: str) -> list[str]:
    tokens: list[str] = []
    token: list[str] = []
    quote: str | None = None
    started = False
    index = 0
    while index < len(text):
        character = text[index]
        if quote is None and character.isspace():
            if started:
                tokens.append("".join(token))
                token = []
                started = False
            index += 1
            continue
        if character in {"'", '"'}:
            if quote is None:
                quote = character
                started = True
            elif quote == character:
                quote = None
            else:
                token.append(character)
            index += 1
            continue
        if character == "\\" and quote != "'":
            index += 1
            if index >= len(text) or text[index] not in ALLOWED_ESCAPES:
                raise ManifestError("unsupported escape in FFmpeg configuration")
            token.append(text[index])
            started = True
            index += 1
            continue
        token.append(character)
        started = True
        index += 1
    if quote is not None:
        raise ManifestError("unterminated quote in FFmpeg configuration")
    if started:
        tokens.append("".join(token))
    return tokens


def canonical_configuration(text: str) -> list[str]:
    lines = text.splitlines()
    configuration: list[str] = []
    found = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped.startswith("configuration:"):
            continue
        found = True
        inline = stripped.partition(":")[2].strip()
        if inline:
            configuration.extend(tokenize_configuration_line(inline))
        for continuation in lines[index + 1:]:
            stripped = continuation.strip()
            if stripped.startswith("--"):
                configuration.extend(tokenize_configuration_line(stripped))
            elif stripped:
                break
        break
    if not found or not configuration:
        raise ManifestError("ffmpeg -buildconf did not emit configuration")
    if any(not argument.startswith("--") for argument in configuration):
        raise ManifestError("FFmpeg configuration contains a non-option token")
    keys = [argument.partition("=")[0] for argument in configuration]
    if len(keys) != len(set(keys)):
        raise ManifestError("FFmpeg configuration contains a duplicate option")
    return configuration


def configuration_sha256(configuration: list[str]) -> str:
    return hashlib.sha256("\n".join(configuration).encode()).hexdigest()


def build_configuration(ffmpeg: Path) -> tuple[list[str], str]:
    configuration = canonical_configuration(run([str(ffmpeg), "-hide_banner", "-buildconf"]))
    flags = frozenset(configuration)
    forbidden = sorted(flags & FORBIDDEN_CONFIGURATION)
    if forbidden:
        raise ManifestError(f"forbidden FFmpeg configure flags: {', '.join(forbidden)}")
    missing = sorted(APPROVED_ENABLED_CONFIGURATION - flags)
    if missing:
        raise ManifestError(f"FFmpeg configuration differs from approved profile; missing: {', '.join(missing)}")
    unapproved = sorted(flag for flag in flags if flag not in APPROVED_ENABLED_CONFIGURATION and not any(flag.startswith(prefix) for prefix in APPROVED_FLAG_PREFIXES))
    if unapproved:
        raise ManifestError(f"FFmpeg configuration has unapproved flags: {', '.join(unapproved)}")
    return configuration, configuration_sha256(configuration)

def inventory(path: Path, option: str) -> set[str]:
    text = run([str(path), "-hide_banner", option])
    observed: set[str] = set()
    for line in text.splitlines():
        if match := re.match(r"^\s*[A-Z\.]+\s+([A-Za-z0-9_][A-Za-z0-9_.,-]+)", line):
            observed.update(match.group(1).split(","))
    return observed

def version(path: Path) -> str:
    text = run([str(path), "-hide_banner", "-version"])
    match = re.search(r"^(?:ffmpeg|ffprobe) version ([^\s]+)", text, re.MULTILINE)
    if not match:
        raise ManifestError(f"{path} -version did not identify an FFmpeg tool version")
    return match.group(1)

def read_source_lock(path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"invalid source lock: {error}") from error
    sources, licenses = value.get("sources"), value.get("licenses")
    if not isinstance(sources, list) or not isinstance(licenses, list) or not sources:
        raise ManifestError("source lock requires nonempty sources and licenses arrays")
    for source in sources:
        if not isinstance(source, dict) or not all(isinstance(source.get(key), str) and source[key] for key in ("name", "version", "url", "sha256", "license")):
            raise ManifestError("source lock contains an incomplete source record")
        if not re.fullmatch(r"[0-9a-f]{64}", source["sha256"]):
            raise ManifestError(f"source lock has invalid SHA-256 for {source['name']}")
    return sources, licenses

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--ffprobe", required=True, type=Path)
    parser.add_argument("--source-lock", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        for binary in (args.ffmpeg, args.ffprobe):
            if not binary.is_file() or not os.access(binary, os.X_OK):
                raise ManifestError(f"missing executable: {binary}")
            dynamic_dependencies(binary)
        binary_architectures = architectures(args.ffmpeg)
        if architectures(args.ffprobe) != binary_architectures:
            raise ManifestError("ffmpeg and ffprobe architectures differ")
        configuration, configuration_sha256 = build_configuration(args.ffmpeg)
        probe_configuration, _ = build_configuration(args.ffprobe)
        if probe_configuration != configuration or version(args.ffprobe) != version(args.ffmpeg):
            raise ManifestError("ffprobe version or build configuration differs from ffmpeg")
        observed = {key: inventory(args.ffmpeg, f"-{key}") for key in EXPECTED_INVENTORY}
        for key, expected in EXPECTED_INVENTORY.items():
            missing = sorted(expected - observed[key])
            if missing:
                raise ManifestError(f"FFmpeg {key} inventory is missing approved entries: {', '.join(missing)}")
        sources, licenses = read_source_lock(args.source_lock)
        signing_identity = os.environ.get("MEDIA_TOOLS_SIGNING_IDENTITY")
        signature = {"mode": "identity", "identity": signing_identity} if signing_identity and signing_identity != "-" else {"mode": "adhoc"}
        manifest = {
            "schemaVersion": SCHEMA_VERSION, "status": "available", "ffmpegVersion": version(args.ffmpeg),
            "sources": sources, "licenses": licenses,
            "build": {"configuration": configuration, "configurationSHA256": configuration_sha256, "architectures": binary_architectures},
            "artifacts": [{"name": name, "path": name, "sha256": sha256(path), "architectures": binary_architectures,
                "signature": signature}
                for name, path in (("ffmpeg", args.ffmpeg), ("ffprobe", args.ffprobe))],
            "inventory": {key: sorted(observed[key]) for key in EXPECTED_INVENTORY},
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_suffix(args.output.suffix + ".tmp")
        temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(args.output)
    except ManifestError as error:
        print(f"generate-media-manifest.py: {error}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
