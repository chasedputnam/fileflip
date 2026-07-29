#!/usr/bin/env python3
"""Compare or explicitly regenerate FileFlip's deterministic certified media fixtures."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "Tests" / "Fixtures" / "Media"
FORMATS = (
    ("audio", "mp3", "mp3", ["-c:a", "libmp3lame", "-b:a", "128k", "-f", "mp3"]),
    ("audio", "m4a", "m4a", ["-c:a", "aac", "-b:a", "128k", "-f", "ipod"]),
    ("audio", "aac", "aac", ["-c:a", "aac", "-b:a", "128k", "-f", "adts"]),
    ("audio", "wav", "wav", ["-c:a", "pcm_s16le", "-f", "wav"]),
    ("audio", "aiff", "aiff", ["-c:a", "pcm_s16be", "-f", "aiff"]),
    ("audio", "flac", "flac", ["-c:a", "flac", "-f", "flac"]),
    ("audio", "ogg", "ogg", ["-c:a", "libvorbis", "-q:a", "4", "-f", "ogg"]),
    ("audio", "opus", "opus", ["-c:a", "libopus", "-b:a", "96k", "-f", "opus"]),
    ("video", "mp4", "mp4", ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-b:a", "96k", "-f", "mp4"]),
    ("video", "m4v", "m4v", ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-b:a", "96k", "-f", "mp4"]),
    ("video", "mov", "mov", ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-b:a", "96k", "-f", "mov"]),
    ("video", "mkv", "mkv", ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", "-b:a", "96k", "-f", "matroska"]),
    ("video", "webm", "webm", ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus", "-b:a", "96k", "-f", "webm"]),
)


class FixtureError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(arguments: list[str]) -> bytes:
    result = subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != 0:
        raise FixtureError(f"command failed ({result.returncode}): {' '.join(arguments)}\n{result.stderr.decode('utf-8', 'replace')}")
    return result.stdout


def tool_version(ffmpeg: Path) -> str:
    first = run([str(ffmpeg), "-version"]).decode("utf-8").splitlines()[0].split()
    if len(first) < 3 or first[:2] != ["ffmpeg", "version"]:
        raise FixtureError("ffmpeg returned an unrecognized version")
    return first[2]


def verified_tools(directory: Path) -> tuple[Path, Path, dict]:
    if not directory.is_absolute():
        raise FixtureError("--media-tools must be an absolute directory")
    ffmpeg, ffprobe, manifest_path = directory / "ffmpeg", directory / "ffprobe", directory / "manifest.json"
    for path in (ffmpeg, ffprobe, manifest_path):
        if not path.is_file() or path.is_symlink():
            raise FixtureError(f"missing regular packaged media tool artifact: {path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureError(f"cannot read packaged media manifest: {error}") from error
    artifacts = {entry.get("name"): entry for entry in manifest.get("artifacts", []) if isinstance(entry, dict)}
    for name, path in (("ffmpeg", ffmpeg), ("ffprobe", ffprobe)):
        if artifacts.get(name, {}).get("sha256") != sha256(path):
            raise FixtureError(f"packaged {name} hash does not match its manifest")
    if manifest.get("ffmpegVersion") != tool_version(ffmpeg):
        raise FixtureError("packaged ffmpeg version does not match its manifest")
    return ffmpeg, ffprobe, manifest


def generate_file(ffmpeg: Path, family: str, output: Path, codec_args: list[str]) -> None:
    common = [str(ffmpeg), "-hide_banner", "-nostdin", "-v", "error"]
    if family == "audio":
        inputs = ["-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000:duration=1"]
        mapping = ["-map", "0:a:0", "-ac", "1", "-map_metadata", "-1"]
        bitexact = ["-fflags", "+bitexact", "-flags:a", "+bitexact"]
    else:
        inputs = [
            "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000:duration=1",
        ]
        mapping = ["-map", "0:v:0", "-map", "1:a:0", "-ac", "1", "-shortest", "-map_metadata", "-1"]
        bitexact = ["-fflags", "+bitexact", "-flags:a", "+bitexact", "-flags:v", "+bitexact"]
    run(common + inputs + mapping + codec_args + bitexact + ["-y", str(output)])


def positive_int(value: object, label: str) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as error:
        raise FixtureError(f"ffprobe returned invalid {label}: {value!r}") from error
    if parsed <= 0:
        raise FixtureError(f"ffprobe returned non-positive {label}: {parsed}")
    return parsed


def probe_facts(ffprobe: Path, path: Path) -> dict:
    output = run([
        str(ffprobe), "-v", "error", "-err_detect", "explode", "-protocol_whitelist", "file,pipe",
        "-count_frames", "-show_entries",
        "format=format_name,duration:format_tags=major_brand:stream=codec_type,codec_name,nb_read_frames,duration,sample_rate,channels,width,height",
        "-of", "json", "--", str(path),
    ])
    try:
        payload = json.loads(output)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FixtureError(f"ffprobe returned malformed facts for {path}") from error
    format_value = payload.get("format")
    streams_value = payload.get("streams")
    if not isinstance(format_value, dict) or not isinstance(streams_value, list) or not streams_value:
        raise FixtureError(f"ffprobe returned incomplete facts for {path}")
    try:
        duration = float(format_value.get("duration"))
    except (TypeError, ValueError) as error:
        raise FixtureError(f"ffprobe returned invalid duration for {path}") from error
    if not duration > 0:
        raise FixtureError(f"ffprobe returned invalid duration for {path}")
    streams: list[dict] = []
    for observed in streams_value:
        if not isinstance(observed, dict) or observed.get("codec_type") not in {"audio", "video"}:
            raise FixtureError(f"ffprobe returned unsupported stream facts for {path}")
        kind = observed["codec_type"]
        codec = observed.get("codec_name")
        if not isinstance(codec, str) or not codec:
            raise FixtureError(f"ffprobe returned missing codec for {path}")
        stream = {"kind": kind, "codec": codec, "frameCount": positive_int(observed.get("nb_read_frames"), "frame count")}
        if kind == "audio":
            stream.update(sampleRate=positive_int(observed.get("sample_rate"), "sample rate"), channels=positive_int(observed.get("channels"), "channel count"))
        else:
            stream.update(width=positive_int(observed.get("width"), "width"), height=positive_int(observed.get("height"), "height"))
        streams.append(stream)
    return {
        "formatNames": sorted(str(format_value.get("format_name", "")).split(",")),
        "majorBrand": (format_value.get("tags") or {}).get("major_brand"),
        "durationMilliseconds": int(duration * 1000 + 0.5),
        "streams": streams,
    }


def build_manifest(staging: Path, ffprobe: Path, version: str, media_manifest_hash: str) -> dict:
    fixtures = []
    for family, logical_format, extension, _ in FORMATS:
        relative = Path(family) / f"source.{extension}"
        path = staging / relative
        fixtures.append({
            "id": f"{family}-{logical_format}",
            "family": family,
            "format": logical_format,
            "canonicalExtension": extension,
            "path": relative.as_posix(),
            "sha256": sha256(path),
            "byteLength": path.stat().st_size,
            "license": "CC0-1.0",
            "provenance": "FileFlip deterministic synthetic media recipe v1",
            "facts": probe_facts(ffprobe, path),
        })
    return {
        "schemaVersion": 1,
        "recipeVersion": 1,
        "generator": {"ffmpegVersion": version, "manifestSHA256": media_manifest_hash},
        "fixtures": fixtures,
    }


def regenerate(media_tools: Path, output: Path) -> None:
    ffmpeg, ffprobe, _ = verified_tools(media_tools)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fileflip-media-fixtures-", dir=output.parent) as temporary:
        staging = Path(temporary)
        if any(staging.iterdir()):
            raise FixtureError("fixture staging directory must be empty")
        for family, _, extension, codec_args in FORMATS:
            directory = staging / family
            directory.mkdir(exist_ok=True)
            generate_file(ffmpeg, family, directory / f"source.{extension}", codec_args)
        manifest = build_manifest(staging, ffprobe, tool_version(ffmpeg), sha256(media_tools / "manifest.json"))
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        replacement = output.with_name(output.name + ".new")
        if replacement.exists():
            shutil.rmtree(replacement)
        shutil.copytree(staging, replacement)
        if output.exists():
            shutil.rmtree(output)
        replacement.replace(output)
    print(f"regenerated 13 certified media fixtures in {output}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media-tools", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()
    try:
        if not args.update:
            checker = ROOT / "scripts" / "check-media-fixtures.py"
            return subprocess.run([sys.executable, str(checker), "--media-tools", str(args.media_tools), str(args.output / "manifest.json")], check=False).returncode
        if os.environ.get("FILECONVERT_UPDATE_FIXTURES") != "1":
            parser.error("--update requires FILECONVERT_UPDATE_FIXTURES=1; default mode never writes fixtures")
        regenerate(args.media_tools.resolve(), args.output.resolve())
        return 0
    except FixtureError as error:
        print(f"fixture generation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
