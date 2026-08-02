#!/usr/bin/env python3
"""Fail-closed release-readiness gate for FileConvert release candidates.

Default mode compares tracked fixture inventories and checks supplied release evidence.
--run-suites executes the contract's exact commands but never creates evidence; a release
still needs independently recorded, reviewable observations.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Any
sys.path.insert(0, str(Path(__file__).resolve().parent))
from packaged_media_release import check_packaged_media

ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = ROOT / "release/release-contract.json"


class StrictJSONError(ValueError):
    pass


def strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise StrictJSONError(f"duplicate key: {key}")
        value[key] = item
    return value


def load_json(path: Path, label: str, failures: list[str]) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=strict_object)
    except FileNotFoundError:
        failures.append(f"missing {label}: {path}")
        return None
    except (OSError, json.JSONDecodeError, StrictJSONError) as error:
        failures.append(f"invalid {label} {path}: {error}")
        return None
    if not isinstance(value, dict):
        failures.append(f"invalid {label} {path}: top level must be an object")
        return None
    return value


def command(argv: list[str], stdout_only: bool = False) -> tuple[int, str]:
    try:
        result = subprocess.run(
            argv,
            check=False,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL if stdout_only else subprocess.STDOUT,
            text=True,
        )
    except OSError as error:
        return 127, str(error)
    return result.returncode, result.stdout


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rendered_command(suite: dict[str, Any], platform: dict[str, Any]) -> list[str]:
    return [item.replace("{architecture}", platform["architecture"]) for item in suite["commandTemplate"]]


def check_fixture_inventories(contract: dict[str, Any], failures: list[str]) -> None:
    policy = contract["fixturePolicy"]
    if policy.get("defaultMode") != "compare-only" or policy.get("updateEnvironment") != "FILECONVERT_UPDATE_FIXTURES=1":
        failures.append("fixture policy is not explicit compare-only with guarded update mode")
    if policy.get("updateRequiresReviewableDiff") is not True:
        failures.append("fixture policy does not require reviewable semantic/golden diffs")
    for inventory in contract["fixtureInventories"]:
        kind = inventory["kind"]
        if kind == "hashed-static":
            code, output = command(inventory["compareCommand"])
            if code != 0:
                failures.append(f"fixture inventory {inventory['id']} did not compare cleanly: {output.strip()}")
        elif kind in {"unhashed-static-inputs", "negative-only"}:
            for relative in inventory["paths"]:
                if not (ROOT / relative).is_file():
                    failures.append(f"fixture inventory {inventory['id']} is missing input: {relative}")
        elif kind == "certified-media":
            code, output = command(inventory["compareCommand"])
            if code != 0:
                failures.append(f"fixture inventory {inventory['id']} did not certify cleanly: {output.strip()}")
        elif kind == "runtime-generated":
            if not (ROOT / inventory["testSource"]).is_file():
                failures.append(f"runtime fixture source is missing: {inventory['testSource']}")
        else:
            failures.append(f"fixture inventory {inventory['id']} has unsupported kind: {kind}")


def check_media_manifest(failures: list[str]) -> None:
    manifest_path = ROOT / "Sources/FileConvertApp/Resources/MediaTools/manifest.json"
    manifest = load_json(manifest_path, "media provider manifest", failures)
    if manifest is None:
        return
    if manifest.get("schemaVersion") != 1:
        failures.append("media provider manifest has an unsupported schemaVersion")
    if manifest.get("status") != "available":
        failures.append(f"media provider manifest is not release-ready: {manifest.get('reason', 'no reason recorded')}")
        return
    if not isinstance(manifest.get("sources"), list) or not manifest["sources"]:
        failures.append("media provider manifest lacks exact source evidence")
    if not isinstance(manifest.get("licenses"), list) or not manifest["licenses"]:
        failures.append("media provider manifest lacks license evidence")
    build = manifest.get("build")
    if not isinstance(build, dict) or set(build.get("architectures", [])) != {"arm64"} or not build.get("configurationSHA256"):
        failures.append("media provider manifest lacks approved Apple Silicon build configuration evidence")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or {item.get("name") for item in artifacts if isinstance(item, dict)} != {"ffmpeg", "ffprobe"}:
        failures.append("media provider manifest lacks exactly ffmpeg and ffprobe artifacts")
        return
    for artifact in artifacts:
        path = ROOT / "Sources/FileConvertApp/Resources/MediaTools" / artifact["path"]
        if not path.is_file() or not os.access(path, os.X_OK):
            failures.append(f"media artifact is missing or non-executable: {artifact['path']}")
            continue
        if artifact.get("sha256") != sha256(path):
            failures.append(f"media artifact hash differs from manifest: {artifact['path']}")
        if set(artifact.get("architectures", [])) != {"arm64"}:
            failures.append(f"media artifact lacks Apple Silicon architecture evidence: {artifact['path']}")


def missing_evidence(contract: dict[str, Any], failures: list[str]) -> None:
    for suite in contract["requiredSuites"]:
        for platform in suite["platforms"]:
            failures.append(f"missing passing {suite['id']} suite evidence for {platform}")
    for name in contract["thresholds"]:
        failures.append(f"missing threshold evidence: {name}")
    for key in contract["externalEvidence"]:
        failures.append(f"missing external evidence: {key}")
    failures.append("missing Finder smoke-matrix evidence")


def passed_external(value: object, evidence: dict[str, Any], schema: dict[str, Any], name: str, failures: list[str]) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        failures.append(f"external evidence {name} must be an object, not a boolean assertion")
        return None
    missing = [key for key in schema["externalEvidenceRequiredKeys"] if not value.get(key)]
    if missing or value.get("status") != "passed" or value.get("revision") != evidence.get("revision"):
        failures.append(f"external evidence {name} is incomplete, non-passing, or for a different revision")
        return None
    return value


def check_evidence(contract: dict[str, Any], evidence: dict[str, Any] | None, failures: list[str]) -> None:
    if evidence is None:
        missing_evidence(contract, failures)
        return
    schema = contract["evidenceSchema"]
    for key in schema["requiredTopLevelKeys"]:
        if not evidence.get(key):
            failures.append(f"release evidence lacks required key: {key}")
    if evidence.get("schemaVersion") != 2 or not isinstance(evidence.get("revision"), str) or not evidence["revision"]:
        failures.append("release evidence has unsupported schemaVersion or no revision")
    suite_runs = evidence.get("suiteRuns") if isinstance(evidence.get("suiteRuns"), list) else []
    for suite in contract["requiredSuites"]:
        for platform_id in suite["platforms"]:
            platform = contract["platforms"][platform_id]
            expected = rendered_command(suite, platform)
            matches = [run for run in suite_runs if isinstance(run, dict) and run.get("suite") == suite["id"] and run.get("platform") == platform_id]
            if not matches:
                failures.append(f"missing passing {suite['id']} suite evidence for {platform_id}")
                continue
            valid = False
            for run in matches:
                required = schema["suiteRunRequiredKeys"]
                if any(not run.get(key) and run.get(key) != 0 for key in required):
                    continue
                if run.get("command") != expected or run.get("architecture") != platform["architecture"] or run.get("revision") != evidence.get("revision") or run.get("exitCode") != 0:
                    continue
                version = run.get("macOSVersion")
                required_major = platform["macOSMajor"]
                if not isinstance(version, str) or (isinstance(required_major, int) and not version.startswith(f"{required_major}.")):
                    continue
                valid = True
            if not valid:
                failures.append(f"no valid passing {suite['id']} evidence for {platform_id}")
    observed_thresholds = evidence.get("thresholds") if isinstance(evidence.get("thresholds"), dict) else {}
    for name, requirement in contract["thresholds"].items():
        observed = observed_thresholds.get(name)
        if not isinstance(observed, dict) or observed.get("revision") != evidence.get("revision") or not observed.get("artifact"):
            failures.append(f"missing threshold evidence: {name}")
            continue
        if name == "mediaDurationTolerance":
            if observed.get("passed") is not True:
                failures.append("media duration tolerance lacks a passing observation")
            continue
        value = observed.get("value")
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            failures.append(f"threshold {name} lacks a numeric observed value")
        elif requirement["operator"] == "<=" and value > requirement["value"]:
            failures.append(f"threshold {name} missed: observed {value} > {requirement['value']} {requirement['unit']}")
        elif requirement["operator"] == "==" and value != requirement["value"]:
            failures.append(f"threshold {name} missed: observed {value} != {requirement['value']} {requirement['unit']}")
    release = evidence.get("release") if isinstance(evidence.get("release"), dict) else {}
    external = {name: passed_external(release.get(name), evidence, schema, name, failures) for name in contract["externalEvidence"]}
    fixture_coverage = external.get("fixtureCoverage")
    if fixture_coverage is not None:
        pairs = fixture_coverage.get("advertisedPairs")
        if not isinstance(pairs, list) or not pairs or any(not isinstance(pair, dict) or not all(pair.get(key) for key in ("source", "target", "provider", "validator", "fixture")) for pair in pairs):
            failures.append("fixture coverage lacks an independently validated certified fixture for every advertised pair")
    fault = external.get("faultInjection")
    if fault is not None:
        boundaries = fault.get("boundaries")
        if not isinstance(boundaries, dict) or any(boundaries.get(boundary) != 0 for boundary in schema["faultBoundaries"]):
            failures.append("fault-injection evidence does not prove zero source-byte loss at every boundary")
    privacy = external.get("privacy")
    if privacy is not None:
        flows = privacy.get("flows")
        if not isinstance(flows, dict) or any(flows.get(flow) != 0 for flow in schema["privacyFlows"]):
            failures.append("privacy evidence does not prove zero outbound connections for every required flow")
    smoke = evidence.get("smokeMatrix")
    enabled = fixture_coverage.get("enabledFamilies") if fixture_coverage is not None else None
    if not isinstance(smoke, list) or not isinstance(enabled, list) or not enabled:
        failures.append("missing Finder smoke-matrix evidence for enabled format families")
    else:
        observed_families: set[str] = set()
        for entry in smoke:
            if not isinstance(entry, dict):
                continue
            missing = [key for key in schema["smokeRequiredKeys"] if not entry.get(key)]
            if missing or entry.get("revision") != evidence.get("revision"):
                failures.append(f"incomplete Finder smoke entry for {entry.get('family', '<unknown>')}: {', '.join(missing)}")
            else:
                observed_families.add(entry["family"])
        if set(enabled) != observed_families:
            failures.append(f"Finder smoke matrix families differ from enabled capabilities: expected {sorted(enabled)}, observed {sorted(observed_families)}")


def is_macho(path: Path) -> bool:
    code, output = command(["/usr/bin/file", "-b", str(path)])
    return code == 0 and "Mach-O" in output


DEVELOPER_ID_TEAM_IDENTIFIER = re.compile(r"^[A-Z0-9]{10}$")


def approved_developer_id_team(contract: dict[str, Any], failures: list[str]) -> str | None:
    application = contract.get("application")
    signing = application.get("signing") if isinstance(application, dict) else None
    team_identifier = signing.get("approvedDeveloperIDTeamIdentifier") if isinstance(signing, dict) else None
    if not isinstance(team_identifier, str) or not DEVELOPER_ID_TEAM_IDENTIFIER.fullmatch(team_identifier):
        failures.append(
            "release contract approved Developer ID TeamIdentifier is unconfigured; "
            "set application.signing.approvedDeveloperIDTeamIdentifier to the production 10-character Team ID"
        )
        return None
    return team_identifier


def developer_id_requirement(team_identifier: str) -> str:
    return (
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] "
        "and certificate leaf[field.1.2.840.113635.100.6.1.13] "
        f'and certificate leaf[subject.OU] = "{team_identifier}"'
    )


def code_label(path: Path, app: Path) -> str:
    return "app bundle" if path == app else str(path.relative_to(app))


def check_developer_id_identity(path: Path, app: Path, approved_team: str, failures: list[str]) -> None:
    label = code_label(path, app)
    code, output = command(["/usr/bin/codesign", "-d", "--verbose=4", str(path)])
    match = re.search(r"^TeamIdentifier=(\S+)$", output, re.MULTILINE)
    if code != 0 or match is None:
        failures.append(f"Developer ID identity metadata could not be read for {label}: {output.strip()}")
    elif match.group(1) != approved_team:
        failures.append(
            f"Developer ID TeamIdentifier mismatch for {label}: expected {approved_team}, observed {match.group(1)}"
        )
    code, output = command(
        ["/usr/bin/codesign", "--verify", "--strict", "--requirements", developer_id_requirement(approved_team), str(path)]
    )
    if code != 0:
        failures.append(f"Developer ID designated requirement failed for {label}: {output.strip()}")


def check_architecture_and_signature(
    path: Path, app: Path, required: set[str], approved_team: str, failures: list[str]
) -> None:
    code, output = command(["/usr/bin/lipo", "-archs", str(path)])
    observed = set(output.split()) if code == 0 else set()
    if observed != required:
        failures.append(f"architecture check failed for {path.relative_to(app)}: expected {sorted(required)}, observed {sorted(observed)}")
    code, output = command(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(path)])
    if code != 0:
        failures.append(f"nested executable signature failed for {path.relative_to(app)}: {output.strip()}")
    code, output = command(["/usr/bin/codesign", "-d", "--verbose=4", str(path)])
    if code != 0 or "runtime" not in output:
        failures.append(
            f"hardened runtime is absent for {path.relative_to(app)}"
        )
    check_developer_id_identity(path, app, approved_team, failures)


def check_data_permissions(data_root: Path | None, failures: list[str]) -> None:
    if data_root is None:
        failures.append("missing owner-only data-permission inspection: pass --data-root ApplicationSupport/FileConvert")
        return
    if not data_root.is_dir():
        failures.append(f"data root is not an accessible directory: {data_root}")
        return
    for path in [data_root, *data_root.rglob("*")]:
        mode = path.stat().st_mode & 0o777
        if mode & 0o077:
            failures.append(f"data path is accessible by group or other users: {path} mode {mode:04o}")


def check_bundle(
    contract: dict[str, Any],
    app: Path | None,
    data_root: Path | None,
    approved_team: str | None,
    failures: list[str],
) -> None:
    if app is None:
        failures.append("missing release candidate: pass --app /path/to/FileFlip.app")
        return
    if not app.is_dir():
        failures.append(f"release candidate is not an app bundle: {app}")
        return
    application = contract["application"]
    executable = app / application["executable"]
    info = app / application["infoPlist"]
    if not executable.is_file() or not info.is_file():
        failures.append("release candidate lacks its main executable or Info.plist")
        return
    try:
        metadata = plistlib.loads(info.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        failures.append(f"release candidate Info.plist cannot be read: {error}")
        return
    if metadata.get("CFBundleIdentifier") != application["bundleIdentifier"]:
        failures.append("release candidate bundle identifier differs from release contract")
    minimum = str(metadata.get("LSMinimumSystemVersion", ""))
    if not re.match(rf"^{application['minimumMacOSMajor']}(?:\.|$)", minimum):
        failures.append("release candidate minimum macOS version differs from release contract")
    required = set(application["requiredArchitectures"])
    if approved_team is None:
        failures.append("release candidate signing identity cannot be checked until the approved Developer ID TeamIdentifier is configured")
        return
    check_architecture_and_signature(executable, app, required, approved_team, failures)
    code, output = command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", str(app)])
    if code != 0:
        failures.append(f"app signature verification failed: {output.strip()}")
    check_developer_id_identity(app, app, approved_team, failures)
    code, output = command(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], stdout_only=True)
    try:
        entitlements = plistlib.loads(output.encode("utf-8")) if output.strip() else {}
    except (ValueError, plistlib.InvalidFileException):
        entitlements = {}
        failures.append("app entitlements could not be parsed")
    for entitlement in application["forbiddenEntitlements"]:
        if entitlements.get(entitlement):
            failures.append(f"forbidden network entitlement present: {entitlement}")
    frameworks = app / "Contents/Frameworks"
    embedded = sorted(item.name for item in frameworks.iterdir()) if frameworks.is_dir() else []
    unexpected = [item for item in embedded if item not in set(application["permittedEmbeddedFrameworks"])]
    if unexpected:
        failures.append(f"unauthorized embedded frameworks: {', '.join(unexpected)}")
    signed_bundle_suffixes = {".framework", ".app", ".appex", ".xpc"}
    for candidate in app.rglob("*"):
        if candidate.is_dir() and candidate.suffix in signed_bundle_suffixes:
            check_developer_id_identity(candidate, app, approved_team, failures)
        elif candidate.is_file() and candidate != executable and is_macho(candidate):
            check_architecture_and_signature(candidate, app, required, approved_team, failures)
    code, output = command(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", str(app)])
    if code != 0 or "Notarized Developer ID" not in output:
        failures.append("notarization assessment did not report a Notarized Developer ID release candidate")
    check_data_permissions(data_root, failures)


def check_updater_metadata(
    app: Path | None,
    dmg: Path | None,
    appcast: Path | None,
    checksum: Path | None,
    tag: str | None,
    previous_appcast: Path | None,
    initial_release: bool,
    failures: list[str],
) -> None:
    supplied = [dmg, appcast, checksum, tag, previous_appcast]
    if app is None:
        if any(value is not None for value in supplied) or initial_release:
            failures.append("updater metadata was supplied without a release application")
        return
    if dmg is None or appcast is None or checksum is None or tag is None:
        failures.append("release application requires --dmg, --appcast, --checksum, and --release-tag")
        return
    if initial_release == (previous_appcast is not None):
        failures.append("release application requires exactly one of --previous-appcast or --initial-release")
        return
    helper_path = ROOT / "scripts" / "prepare-updater-release.py"
    spec = importlib.util.spec_from_file_location("fileflip_prepare_updater_release", helper_path)
    if spec is None or spec.loader is None:
        failures.append("updater release validator could not be loaded")
        return
    helper = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = helper
    try:
        spec.loader.exec_module(helper)
        updater_contract = helper.load_contract(CONTRACT_PATH)
        helper.validate_metadata(
            app=app,
            dmg=dmg,
            appcast=appcast,
            checksum=checksum,
            tag=tag,
            contract=updater_contract,
            sign_update=updater_contract.tools_directory / "sign_update",
            generate_keys=updater_contract.tools_directory / "generate_keys",
            previous_appcast=previous_appcast,
            initial_release=initial_release,
        )
    except (OSError, ValueError, json.JSONDecodeError, plistlib.InvalidFileException) as error:
        failures.append(f"updater release metadata failed validation: {error}")


def run_suites(contract: dict[str, Any], failures: list[str]) -> None:
    for suite in contract["requiredSuites"]:
        for platform_id in suite["platforms"]:
            argv = rendered_command(suite, contract["platforms"][platform_id])
            print("running", suite["id"], "for", platform_id, ":", " ".join(argv))
            code, output = command(argv)
            if code != 0:
                failures.append(f"release suite {suite['id']} failed on {platform_id} with exit code {code}: {output.strip()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="signed FileFlip.app release candidate")
    parser.add_argument("--data-root", type=Path, help="owner-only Application Support root produced by this candidate")
    parser.add_argument("--evidence", type=Path, default=ROOT / "release/evidence.json", help="machine-recorded release evidence")
    parser.add_argument("--run-suites", action="store_true", help="run exact suite commands before inspecting evidence")
    parser.add_argument("--dmg", type=Path, help="exact notarized FileFlip.dmg release candidate")
    parser.add_argument("--appcast", type=Path, help="candidate-bound signed appcast.xml")
    parser.add_argument("--checksum", type=Path, help="candidate-bound FileFlip.dmg.sha256")
    parser.add_argument("--release-tag", help="stable GitHub release tag, for example v1.2.3")
    updater_history = parser.add_mutually_exclusive_group()
    updater_history.add_argument("--previous-appcast", type=Path, help="downloaded currently published stable appcast")
    updater_history.add_argument("--initial-release", action="store_true", help="assert that no stable appcast exists yet")
    args = parser.parse_args()
    failures: list[str] = []
    contract = load_json(CONTRACT_PATH, "release contract", failures)
    if contract is None or contract.get("schemaVersion") != 2:
        failures.append("release contract has an unsupported schemaVersion")
        return report(failures)
    approved_team = approved_developer_id_team(contract, failures)
    if args.run_suites:
        run_suites(contract, failures)
    check_fixture_inventories(contract, failures)
    check_media_manifest(failures)
    evidence = load_json(args.evidence, "release evidence", failures)
    check_evidence(contract, evidence, failures)
    check_packaged_media(contract, evidence, args.app, ROOT, command, failures)
    check_bundle(contract, args.app, args.data_root, approved_team, failures)
    check_updater_metadata(
        args.app,
        args.dmg,
        args.appcast,
        args.checksum,
        args.release_tag,
        args.previous_appcast,
        args.initial_release,
        failures,
    )
    return report(failures)


def report(failures: list[str]) -> int:
    if failures:
        print("RELEASE NOT READY", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("RELEASE READY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
