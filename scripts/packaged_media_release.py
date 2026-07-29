#!/usr/bin/env python3
"""Strict packaged-media release evidence validation."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
from typing import Any, Callable

SHA256 = __import__("re").compile(r"^[0-9a-f]{64}$")
REPORT_KEYS = {"schemaVersion", "generatedAt", "revision", "platform", "application", "provider", "summary", "routes"}
PLATFORM_KEYS = {"os", "architecture"}
APPLICATION_KEYS = {"bundleIdentifier", "version", "candidateSHA256"}
PROVIDER_KEYS = {"ffmpegVersion", "manifestSHA256", "contractVersion", "routeSetSHA256"}
SUMMARY_KEYS = {"expectedRoutes", "executedRoutes", "passedRoutes", "failedRoutes", "skippedRoutes", "audioRoutes", "videoRoutes"}
ROUTE_KEYS = {"family", "source", "target", "fixtureSHA256", "sourceBeforeSHA256", "sourceAfterSHA256", "outputSHA256", "outputByteLength", "observedFacts", "status"}
FACT_KEYS = {"logicalFormat", "durationMilliseconds", "streams"}
STREAM_KEYS = {"kind", "codec", "frameCount", "sampleRate", "channels", "width", "height"}


class PackagedMediaEvidenceError(ValueError):
    pass


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise PackagedMediaEvidenceError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_strict_object)
    except (OSError, json.JSONDecodeError) as error:
        raise PackagedMediaEvidenceError(f"cannot read {label} {path}: {error}") from error
    if not isinstance(value, dict):
        raise PackagedMediaEvidenceError(f"{label} top level must be an object")
    return value


def _exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        observed = sorted(value) if isinstance(value, dict) else type(value).__name__
        raise PackagedMediaEvidenceError(f"{label} keys differ: expected {sorted(expected)}, observed {observed}")
    return value


def _timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise PackagedMediaEvidenceError(f"{label} must be a nonempty ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise PackagedMediaEvidenceError(f"{label} is not ISO-8601") from error
    if parsed.tzinfo is None:
        raise PackagedMediaEvidenceError(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _regular_file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def candidate_sha256(root: Path) -> str:
    if root.is_symlink() or not root.is_dir():
        raise PackagedMediaEvidenceError("candidate root must be a non-symlink directory")
    records: list[tuple[str, str]] = []

    def visit(directory: Path) -> None:
        try:
            children = list(os.scandir(directory))
        except OSError as error:
            raise PackagedMediaEvidenceError(f"candidate cannot be enumerated: {error}") from error
        for child in children:
            path = Path(child.path)
            relative = path.relative_to(root).as_posix()
            try:
                attributes = child.stat(follow_symlinks=False)
            except OSError as error:
                raise PackagedMediaEvidenceError(f"candidate entry cannot be inspected: {relative}: {error}") from error
            if stat.S_ISLNK(attributes.st_mode):
                destination = os.readlink(path)
                resolved = (path.parent / destination).resolve() if not os.path.isabs(destination) else Path(destination).resolve()
                try:
                    resolved.relative_to(root.resolve())
                except ValueError as error:
                    raise PackagedMediaEvidenceError(f"candidate symlink escapes its root: {relative}") from error
                if not resolved.exists():
                    raise PackagedMediaEvidenceError(f"candidate symlink is broken: {relative}")
                records.append((relative, f"L\0{relative}\0{destination}\n"))
            elif stat.S_ISDIR(attributes.st_mode):
                visit(path)
            elif stat.S_ISREG(attributes.st_mode):
                executable_mode = attributes.st_mode & 0o111
                record = f"F\0{relative}\0{executable_mode:o}\0{attributes.st_size}\0{_regular_file_sha256(path)}\n"
                records.append((relative, record))
            else:
                raise PackagedMediaEvidenceError(f"candidate contains a non-regular entry: {relative}")

    visit(root)
    if not any(record.startswith("F\0") for _, record in records):
        raise PackagedMediaEvidenceError("candidate contains no regular files")
    digest = hashlib.sha256()
    for _, record in sorted(records, key=lambda item: item[0].encode("utf-8")):
        digest.update(record.encode("utf-8"))
    return digest.hexdigest()


def expected_routes(media: dict[str, Any]) -> set[str]:
    expected = media["expected"]
    routes: set[str] = set()
    for family in ("audio", "video"):
        formats = [item["canonicalExtension"] for item in expected[f"{family}Formats"]]
        routes.update(f"{family}:{source}->{target}" for source in formats for target in formats if source != target)
    return routes


def fixture_hashes(root: Path, media: dict[str, Any]) -> dict[str, str]:
    manifest = load_json(root / media["fixtureManifest"], "certified media fixture manifest")
    fixtures = manifest.get("fixtures")
    if not isinstance(fixtures, list):
        raise PackagedMediaEvidenceError("certified media fixture manifest lacks fixtures")
    hashes: dict[str, str] = {}
    for fixture in fixtures:
        if not isinstance(fixture, dict) or not isinstance(fixture.get("canonicalExtension"), str) or not SHA256.fullmatch(str(fixture.get("sha256", ""))):
            raise PackagedMediaEvidenceError("certified media fixture manifest contains an invalid fixture identity")
        extension = fixture["canonicalExtension"]
        if extension in hashes:
            raise PackagedMediaEvidenceError(f"duplicate certified fixture format: {extension}")
        hashes[extension] = fixture["sha256"]
    expected_formats = {
        item["canonicalExtension"]
        for family in ("audioFormats", "videoFormats")
        for item in media["expected"][family]
    }
    if set(hashes) != expected_formats:
        raise PackagedMediaEvidenceError("certified fixture formats differ from packaged media contract")
    return hashes


def _validate_stream(stream: Any, route: str) -> None:
    if not isinstance(stream, dict):
        raise PackagedMediaEvidenceError(f"matrix stream must be an object: {route}")
    unknown = set(stream) - STREAM_KEYS
    if unknown or not {"kind", "codec"}.issubset(stream):
        raise PackagedMediaEvidenceError(f"matrix stream fields are unknown or incomplete: {route}")
    if stream["kind"] not in {"audio", "video", "subtitle"} or not isinstance(stream["codec"], str) or not stream["codec"]:
        raise PackagedMediaEvidenceError(f"matrix stream has invalid kind or codec: {route}")
    for key in STREAM_KEYS - {"kind", "codec"}:
        observed = stream.get(key)
        if observed is not None and (not isinstance(observed, int) or isinstance(observed, bool) or observed <= 0):
            raise PackagedMediaEvidenceError(f"matrix stream has invalid {key}: {route}")


def validate_matrix_report(
    report: dict[str, Any],
    media: dict[str, Any],
    app: Path,
    manifest_sha256: str,
    fixtures: dict[str, str],
    revision: str,
    recorded_at: datetime,
    now: datetime,
) -> None:
    _exact_keys(report, REPORT_KEYS, "matrix report")
    expected = media["expected"]
    generated_at = _timestamp(report["generatedAt"], "matrix generatedAt")
    maximum_age = timedelta(days=media["maximumEvidenceAgeDays"])
    if generated_at > recorded_at or generated_at > now or now - generated_at > maximum_age:
        raise PackagedMediaEvidenceError("matrix report date is future, stale, or newer than its release evidence")
    if report["schemaVersion"] != media["reportSchemaVersion"] or report["revision"] != revision:
        raise PackagedMediaEvidenceError("matrix report schema or revision differs from release evidence")

    platform = _exact_keys(report["platform"], PLATFORM_KEYS, "matrix platform")
    if platform != {"os": "macOS", "architecture": "arm64"}:
        raise PackagedMediaEvidenceError("matrix report platform is not supported arm64 macOS")
    application = _exact_keys(report["application"], APPLICATION_KEYS, "matrix application")
    try:
        info = __import__("plistlib").loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, ValueError) as error:
        raise PackagedMediaEvidenceError(f"candidate Info.plist is invalid: {error}") from error
    if application["bundleIdentifier"] != info.get("CFBundleIdentifier") or application["version"] != info.get("CFBundleShortVersionString"):
        raise PackagedMediaEvidenceError("matrix application identity differs from its candidate")
    if application["candidateSHA256"] != candidate_sha256(app):
        raise PackagedMediaEvidenceError("matrix report belongs to a different application candidate")
    provider = _exact_keys(report["provider"], PROVIDER_KEYS, "matrix provider")
    if provider["ffmpegVersion"] != "8.1.2" or provider["contractVersion"] != media["contractVersion"]:
        raise PackagedMediaEvidenceError("matrix provider version or contract version differs")
    if provider["manifestSHA256"] != manifest_sha256:
        raise PackagedMediaEvidenceError("matrix report belongs to a different packaged manifest")
    if provider["routeSetSHA256"] != expected["routeSetSHA256"]:
        raise PackagedMediaEvidenceError("matrix report route-set identity differs from the authoritative contract")

    summary = _exact_keys(report["summary"], SUMMARY_KEYS, "matrix summary")
    required_summary = {
        "expectedRoutes": expected["routeCount"],
        "executedRoutes": expected["routeCount"],
        "passedRoutes": expected["routeCount"],
        "failedRoutes": 0,
        "skippedRoutes": 0,
        "audioRoutes": expected["audioRouteCount"],
        "videoRoutes": expected["videoRouteCount"],
    }
    if summary != required_summary:
        raise PackagedMediaEvidenceError("matrix summary does not prove 56 audio and 20 video routes with zero failures or skips")
    routes = report["routes"]
    if not isinstance(routes, list) or len(routes) != expected["routeCount"]:
        raise PackagedMediaEvidenceError("matrix route records are incomplete")
    identities: list[str] = []
    for route_value in routes:
        route = _exact_keys(route_value, ROUTE_KEYS, "matrix route")
        identity = f"{route['family']}:{route['source']}->{route['target']}"
        identities.append(identity)
        if route["status"] != "passed" or route["source"] == route["target"]:
            raise PackagedMediaEvidenceError(f"matrix route is not passing non-identity evidence: {identity}")
        hashes = (route["fixtureSHA256"], route["sourceBeforeSHA256"], route["sourceAfterSHA256"], route["outputSHA256"])
        if any(not isinstance(value, str) or not SHA256.fullmatch(value) for value in hashes):
            raise PackagedMediaEvidenceError(f"matrix route contains an invalid hash: {identity}")
        if route["fixtureSHA256"] != fixtures.get(route["source"]) or len(set(hashes[:3])) != 1 or route["outputSHA256"] == route["sourceBeforeSHA256"]:
            raise PackagedMediaEvidenceError(f"matrix route source is changed, uncertified, or reused as output: {identity}")
        if not isinstance(route["outputByteLength"], int) or isinstance(route["outputByteLength"], bool) or route["outputByteLength"] <= 0:
            raise PackagedMediaEvidenceError(f"matrix route output is empty or unbounded: {identity}")
        facts = _exact_keys(route["observedFacts"], FACT_KEYS, f"matrix facts {identity}")
        if facts["logicalFormat"] != route["target"] or not isinstance(facts["durationMilliseconds"], int) or isinstance(facts["durationMilliseconds"], bool) or facts["durationMilliseconds"] <= 0:
            raise PackagedMediaEvidenceError(f"matrix route output facts differ from target: {identity}")
        if not isinstance(facts["streams"], list) or not facts["streams"]:
            raise PackagedMediaEvidenceError(f"matrix route lacks independently observed streams: {identity}")
        for stream in facts["streams"]:
            _validate_stream(stream, identity)
        observed_kinds = Counter(stream["kind"] for stream in facts["streams"])
        required_kinds = Counter({"audio": 1}) if route["family"] == "audio" else Counter({"audio": 1, "video": 1})
        if observed_kinds != required_kinds:
            raise PackagedMediaEvidenceError(f"matrix route stream topology differs from the installed contract: {identity}")
    expected_identities = expected_routes(media)
    if set(identities) != expected_identities or len(set(identities)) != len(identities):
        raise PackagedMediaEvidenceError("matrix routes are missing, duplicated, or substituted")
    if identities != sorted(identities, key=lambda value: value.encode("utf-8")):
        raise PackagedMediaEvidenceError("matrix routes are not in canonical bytewise order")


def _artifact_path(root: Path, value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise PackagedMediaEvidenceError(f"{label} artifact path is missing")
    path = Path(value)
    resolved = path if path.is_absolute() else root / path
    if not resolved.is_file():
        raise PackagedMediaEvidenceError(f"{label} artifact does not exist: {resolved}")
    return resolved


def check_packaged_media(
    contract: dict[str, Any],
    evidence: dict[str, Any] | None,
    app: Path | None,
    root: Path,
    command: Callable[[list[str]], tuple[int, str]],
    failures: list[str],
    now: datetime | None = None,
) -> None:
    media = contract.get("packagedMedia")
    if not isinstance(media, dict):
        failures.append("release contract lacks packaged media requirements")
        return
    consistency_code, consistency_output = command(media["consistencyCommand"])
    if consistency_code != 0:
        failures.append(f"packaged media capability declarations differ: {consistency_output.strip()}")
    fixture_code, fixture_output = command(media["fixtureCompareCommand"])
    if fixture_code != 0:
        failures.append(f"certified media fixtures drifted: {fixture_output.strip()}")
    if app is None or not app.is_dir():
        failures.append("packaged media evidence requires the built application candidate")
        return
    layout_code, layout_output = command(["scripts/verify-media-bundle.py", str(app)])
    if layout_code != 0:
        failures.append(f"packaged media candidate layout is invalid: {layout_output.strip()}")
        return
    media_directory = app / media["candidateResourceDirectory"]
    manifest_path = media_directory / "manifest.json"
    try:
        load_json(manifest_path, "candidate media manifest")
        manifest_digest = _regular_file_sha256(manifest_path)
        fixture_digest_by_format = fixture_hashes(root, media)
    except PackagedMediaEvidenceError as error:
        failures.append(str(error))
        return
    packaged_evidence = evidence.get("packagedMedia") if isinstance(evidence, dict) else None
    required_evidence_keys = set(contract["evidenceSchema"]["packagedMediaEvidenceRequiredKeys"])
    if not isinstance(packaged_evidence, dict) or set(packaged_evidence) != required_evidence_keys:
        failures.append("release evidence lacks exact packaged media matrix and installation-smoke records")
        return
    revision = evidence.get("revision")
    try:
        recorded_at = _timestamp(evidence.get("recordedAt"), "release recordedAt")
        current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        run_keys = set(contract["evidenceSchema"]["packagedMediaRunRequiredKeys"])
        matrix_run = _exact_keys(packaged_evidence["matrixReport"], run_keys, "matrix evidence")
        smoke_run = _exact_keys(packaged_evidence["installationSmoke"], run_keys, "installation smoke evidence")
        report_path = _artifact_path(root, matrix_run["artifact"], "matrix")
        _artifact_path(root, smoke_run["artifact"], "installation smoke")
        expected_commands = {
            "matrix": [
                item.replace("{root}", str(root.resolve())).replace("{app}", str(app.resolve())).replace("{report}", str(report_path.resolve()))
                for item in media["matrixCommand"]
            ],
            "installation smoke": [
                item.replace("{root}", str(root.resolve())).replace("{app}", str(app.resolve()))
                for item in media["installationSmokeCommand"]
            ],
        }
        for label, run in (("matrix", matrix_run), ("installation smoke", smoke_run)):
            observed_at = _timestamp(run["observedAt"], f"{label} observedAt")
            if run["status"] != "passed" or run["revision"] != revision:
                raise PackagedMediaEvidenceError(f"{label} evidence is non-passing or for a different revision")
            if run["command"] != expected_commands[label]:
                raise PackagedMediaEvidenceError(f"{label} evidence did not run the exact release command against this candidate")
            if observed_at > recorded_at or observed_at > current or current - observed_at > timedelta(days=media["maximumEvidenceAgeDays"]):
                raise PackagedMediaEvidenceError(f"{label} evidence date is future, stale, or newer than release evidence")
        report = load_json(report_path, "packaged media matrix report")
        validate_matrix_report(report, media, app, manifest_digest, fixture_digest_by_format, revision, recorded_at, current)
    except PackagedMediaEvidenceError as error:
        failures.append(str(error))
