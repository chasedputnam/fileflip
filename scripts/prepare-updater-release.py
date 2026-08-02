#!/usr/bin/env python3
"""Generate and validate candidate-bound Sparkle release metadata."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import plistlib
import re
import stat
import tempfile
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
STABLE_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){1,3}")
BASE64_ED25519_KEY = re.compile(r"[A-Za-z0-9+/]{43}=")
BASE64_ED25519_SIGNATURE = re.compile(r"[A-Za-z0-9+/]{86}==")
FEED_SIGNATURE = re.compile(
    rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n?\Z"
)


class ReleaseMetadataError(ValueError):
    pass


@dataclass(frozen=True)
class UpdaterContract:
    bundle_identifier: str
    minimum_macos_major: int
    required_architectures: tuple[str, ...]
    sparkle_version: str
    keychain_account: str
    public_key: str
    repository: str
    feed_asset_name: str
    disk_image_asset_name: str
    checksum_asset_name: str

    @property
    def tools_directory(self) -> Path:
        return ROOT / ".build" / "artifacts" / "sparkle" / "Sparkle" / "bin"

    def release_page(self, tag: str) -> str:
        return f"https://github.com/{self.repository}/releases/tag/{tag}"

    def release_download_prefix(self, tag: str) -> str:
        return f"https://github.com/{self.repository}/releases/download/{tag}/"

    @property
    def feed_url(self) -> str:
        return f"https://github.com/{self.repository}/releases/latest/download/{self.feed_asset_name}"


def load_contract(path: Path = ROOT / "release" / "release-contract.json") -> UpdaterContract:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    application = require_mapping(value, "application")
    updater = require_mapping(value, "updater")
    architectures = application.get("requiredArchitectures")
    if not isinstance(architectures, list) or not architectures or not all(
        isinstance(item, str) and item for item in architectures
    ):
        raise ReleaseMetadataError("application.requiredArchitectures must be a non-empty string array")
    return UpdaterContract(
        bundle_identifier=require_string(application, "bundleIdentifier"),
        minimum_macos_major=require_int(application, "minimumMacOSMajor"),
        required_architectures=tuple(architectures),
        sparkle_version=require_string(updater, "sparkleVersion"),
        keychain_account=require_string(updater, "keychainAccount"),
        public_key=require_string(updater, "publicEdKey"),
        repository=require_string(updater, "repository"),
        feed_asset_name=require_string(updater, "feedAssetName"),
        disk_image_asset_name=require_string(updater, "diskImageAssetName"),
        checksum_asset_name=require_string(updater, "checksumAssetName"),
    )


def require_mapping(value: dict[str, Any], key: str) -> dict[str, Any]:
    result = value.get(key)
    if not isinstance(result, dict):
        raise ReleaseMetadataError(f"{key} must be an object")
    return result


def require_string(value: dict[str, Any], key: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result:
        raise ReleaseMetadataError(f"{key} must be a non-empty string")
    return result


def require_int(value: dict[str, Any], key: str) -> int:
    result = value.get(key)
    if not isinstance(result, int) or isinstance(result, bool):
        raise ReleaseMetadataError(f"{key} must be an integer")
    return result


def load_app_info(app: Path) -> dict[str, Any]:
    plist_path = app / "Contents" / "Info.plist"
    if not app.is_dir() or not plist_path.is_file():
        raise ReleaseMetadataError("--app must name a macOS application bundle with Contents/Info.plist")
    with plist_path.open("rb") as handle:
        value = plistlib.load(handle)
    if not isinstance(value, dict):
        raise ReleaseMetadataError("application Info.plist must contain a dictionary")
    return value


def validate_candidate_configuration(
    info: dict[str, Any], contract: UpdaterContract, tag: str
) -> tuple[str, str, str]:
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    minimum_system = info.get("LSMinimumSystemVersion")
    if not isinstance(version, str) or STABLE_VERSION.fullmatch(version) is None:
        raise ReleaseMetadataError("candidate version must be a stable numeric dotted version")
    if not isinstance(build, str) or not build.isdigit() or int(build) <= 0:
        raise ReleaseMetadataError("candidate build must be a positive decimal integer")
    if tag != f"v{version}":
        raise ReleaseMetadataError(f"release tag must be v{version}")
    if info.get("CFBundleIdentifier") != contract.bundle_identifier:
        raise ReleaseMetadataError("candidate bundle identifier does not match the release contract")
    if not isinstance(minimum_system, str) or minimum_system.split(".", 1)[0] != str(contract.minimum_macos_major):
        raise ReleaseMetadataError("candidate minimum macOS version does not match the release contract")
    required = {
        "SUFeedURL": contract.feed_url,
        "SUPublicEDKey": contract.public_key,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
    }
    for key, expected in required.items():
        if info.get(key) != expected:
            raise ReleaseMetadataError(f"candidate {key} does not match the fail-closed updater contract")
    if BASE64_ED25519_KEY.fullmatch(contract.public_key) is None:
        raise ReleaseMetadataError("release contract publicEdKey is not a base64 Ed25519 public key")
    return version, build, minimum_system


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def application_payload_digest(app: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*"), key=lambda candidate: candidate.relative_to(app).as_posix()):
        relative = path.relative_to(app).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            digest.update(b"L")
            target = path.readlink().as_posix().encode("utf-8")
            digest.update(len(target).to_bytes(4, "big"))
            digest.update(target)
        elif stat.S_ISREG(mode):
            digest.update(b"F")
            digest.update(bytes([mode & 0o111 != 0]))
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        elif stat.S_ISDIR(mode):
            digest.update(b"D")
        else:
            raise ReleaseMetadataError(f"candidate app contains unsupported file type: {relative.decode()}")
    return digest.hexdigest()


def validate_disk_image_application(dmg: Path, app: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="fileflip-dmg-") as temporary:
        mount_point = Path(temporary) / "mounted"
        mount_point.mkdir()
        try:
            run_tool([
                "hdiutil", "attach", "-readonly", "-nobrowse",
                "-mountpoint", str(mount_point), str(dmg),
            ])
            embedded_app = mount_point / app.name
            if not embedded_app.is_dir():
                raise ReleaseMetadataError(f"candidate disk image does not contain {app.name}")
            if application_payload_digest(embedded_app) != application_payload_digest(app):
                raise ReleaseMetadataError("candidate disk image app does not match the validated --app bundle")
        finally:
            if mount_point.is_mount():
                run_tool(["hdiutil", "detach", str(mount_point)])


def validate_application_notarization(app: Path) -> None:
    run_tool(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    run_tool(["xcrun", "stapler", "validate", str(app)])
    run_tool([
        "spctl", "--assess", "--type", "execute", "--verbose=4", str(app),
    ])



def run_tool(arguments: list[str], *, input_text: str | None = None) -> str:
    try:
        result = subprocess.run(
            arguments,
            input=input_text,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise ReleaseMetadataError(f"required tool {Path(arguments[0]).name} is unavailable") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        suffix = f": {detail[-1]}" if detail else ""
        raise ReleaseMetadataError(f"{Path(arguments[0]).name} failed{suffix}")
    return result.stdout.strip()


def verify_signing_key(contract: UpdaterContract, generate_keys: Path) -> None:
    public_key = run_tool(
        [str(generate_keys), "--account", contract.keychain_account, "-p"]
    )
    if public_key != contract.public_key:
        raise ReleaseMetadataError("Keychain signing key does not match the release contract public key")


def parse_signed_feed(appcast: Path) -> tuple[ET.Element, str]:
    data = appcast.read_bytes()
    signature_match = FEED_SIGNATURE.search(data)
    if signature_match is None:
        raise ReleaseMetadataError("appcast is missing its signed-feed envelope")
    signed_length = int(signature_match.group(2))
    if signed_length != signature_match.start():
        raise ReleaseMetadataError("appcast signed-feed length does not match its signed content")
    try:
        root = ET.fromstring(data[:signed_length])
    except ET.ParseError as error:
        raise ReleaseMetadataError("appcast XML is malformed") from error
    return root, signature_match.group(1).decode("ascii")


def child_text(item: ET.Element, name: str) -> str:
    child = item.find(f"{{{SPARKLE_NAMESPACE}}}{name}")
    if child is None or child.text is None or not child.text.strip():
        raise ReleaseMetadataError(f"appcast item is missing sparkle:{name}")
    return child.text.strip()

def version_key(version: str) -> tuple[int, int, int, int]:
    if STABLE_VERSION.fullmatch(version) is None:
        raise ReleaseMetadataError("previous appcast contains a non-stable version")
    components = [int(component) for component in version.split(".")]
    return tuple((components + [0, 0, 0, 0])[:4])


def validate_candidate_increases(
    version: str,
    build: str,
    previous_appcast: Path | None,
    initial_release: bool,
    sign_update: Path,
    signing_arguments: list[str],
) -> None:
    if initial_release == (previous_appcast is not None):
        raise ReleaseMetadataError("select exactly one of --previous-appcast or --initial-release")
    if initial_release:
        return
    assert previous_appcast is not None
    if not previous_appcast.is_file():
        raise ReleaseMetadataError("previous appcast is missing")
    run_tool([str(sign_update), *signing_arguments, "--verify", str(previous_appcast)])
    root, _ = parse_signed_feed(previous_appcast)
    previous_items = root.findall("./channel/item")
    if not previous_items:
        raise ReleaseMetadataError("previous appcast contains no release items")
    previous_versions: list[tuple[tuple[int, int, int, int], int]] = []
    for item in previous_items:
        previous_version = child_text(item, "shortVersionString")
        previous_build = child_text(item, "version")
        if not previous_build.isdigit():
            raise ReleaseMetadataError("previous appcast contains an invalid build")
        previous_versions.append((version_key(previous_version), int(previous_build)))
    highest_version, highest_build = max(previous_versions)
    if version_key(version) <= highest_version:
        raise ReleaseMetadataError("candidate version does not increase over the stable appcast")
    if int(build) <= highest_build:
        raise ReleaseMetadataError("candidate build does not increase over the stable appcast")




def validate_metadata(
    *,
    app: Path,
    dmg: Path,
    appcast: Path,
    checksum: Path,
    tag: str,
    contract: UpdaterContract,
    sign_update: Path,
    generate_keys: Path,
    signing_arguments: list[str] | None = None,
    previous_appcast: Path | None = None,
    initial_release: bool = False,
    notarization_validator: Callable[[Path], None] = validate_application_notarization,
) -> None:
    verify_signing_key(contract, generate_keys)
    info = load_app_info(app)
    version, build, minimum_system = validate_candidate_configuration(info, contract, tag)
    key_arguments = signing_arguments or ["--account", contract.keychain_account]
    validate_candidate_increases(
        version,
        build,
        previous_appcast,
        initial_release,
        sign_update,
        key_arguments,
    )
    if not dmg.is_file():
        raise ReleaseMetadataError("candidate disk image is missing")
    if dmg.name != contract.disk_image_asset_name:
        raise ReleaseMetadataError(f"candidate disk image must be named {contract.disk_image_asset_name}")
    notarization_validator(app)
    validate_disk_image_application(dmg, app)
    if appcast.name != contract.feed_asset_name or not appcast.is_file():
        raise ReleaseMetadataError(f"signed feed must be named {contract.feed_asset_name}")
    if checksum.name != contract.checksum_asset_name or not checksum.is_file():
        raise ReleaseMetadataError(f"checksum must be named {contract.checksum_asset_name}")

    root, _ = parse_signed_feed(appcast)
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ReleaseMetadataError("stable appcast must contain exactly one candidate item")
    item = items[0]
    if item.find(f"{{{SPARKLE_NAMESPACE}}}channel") is not None:
        raise ReleaseMetadataError("stable appcast item must not select a prerelease channel")
    expected_page = contract.release_page(tag)
    link = item.findtext("link")
    if link != expected_page or child_text(item, "fullReleaseNotesLink") != expected_page:
        raise ReleaseMetadataError("appcast release links do not match the candidate tag")
    if child_text(item, "shortVersionString") != version:
        raise ReleaseMetadataError("appcast version does not match the candidate")
    if child_text(item, "version") != build:
        raise ReleaseMetadataError("appcast build does not match the candidate")
    if child_text(item, "minimumSystemVersion") != minimum_system:
        raise ReleaseMetadataError("appcast minimum system version does not match the candidate")
    hardware = set(child_text(item, "hardwareRequirements").split(","))
    if hardware != set(contract.required_architectures):
        raise ReleaseMetadataError("appcast hardware requirements do not match the release contract")

    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ReleaseMetadataError("appcast item is missing its enclosure")
    expected_url = contract.release_download_prefix(tag) + contract.disk_image_asset_name
    if enclosure.get("url") != expected_url or "/latest/" in (enclosure.get("url") or ""):
        raise ReleaseMetadataError("appcast enclosure URL is not candidate-versioned and immutable")
    if enclosure.get("type") != "application/octet-stream":
        raise ReleaseMetadataError("appcast enclosure has an unexpected content type")
    if enclosure.get("length") != str(dmg.stat().st_size):
        raise ReleaseMetadataError("appcast enclosure length does not match the candidate disk image")
    enclosure_signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    if enclosure_signature is None or BASE64_ED25519_SIGNATURE.fullmatch(enclosure_signature) is None:
        raise ReleaseMetadataError("appcast enclosure is missing its Ed25519 signature")

    expected_digest = sha256(dmg)
    checksum_parts = checksum.read_text(encoding="utf-8").strip().split()
    if checksum_parts != [expected_digest, contract.disk_image_asset_name]:
        raise ReleaseMetadataError("candidate checksum does not match the exact disk image")

    key_arguments = signing_arguments or ["--account", contract.keychain_account]
    run_tool([str(sign_update), *key_arguments, "--verify", str(appcast)])
    run_tool([str(sign_update), *key_arguments, "--verify", str(dmg), enclosure_signature])


def prepare_release(
    *,
    app: Path,
    source_dmg: Path,
    release_notes: Path,
    output_directory: Path,
    tag: str,
    contract: UpdaterContract,
    previous_appcast: Path | None,
    initial_release: bool,
) -> None:
    info = load_app_info(app)
    version, build, _ = validate_candidate_configuration(info, contract, tag)
    if source_dmg.name != contract.disk_image_asset_name or not source_dmg.is_file():
        raise ReleaseMetadataError(f"--dmg must name an existing {contract.disk_image_asset_name}")
    validate_application_notarization(app)
    if not release_notes.is_file():
        raise ReleaseMetadataError("--release-notes must name an existing Markdown, HTML, or text file")
    if release_notes.suffix.lower() not in {".md", ".html", ".txt"}:
        raise ReleaseMetadataError("release notes must use .md, .html, or .txt")
    if output_directory.exists() or output_directory.is_symlink():
        raise ReleaseMetadataError("refusing to overwrite an existing output directory")
    output_parent = output_directory.parent
    output_parent.mkdir(parents=True, exist_ok=True)
    temporary_output = Path(
        tempfile.mkdtemp(prefix=f".{output_directory.name}.", dir=output_parent)
    )
    try:
        destinations = [
            temporary_output / contract.disk_image_asset_name,
            temporary_output / contract.feed_asset_name,
            temporary_output / contract.checksum_asset_name,
            temporary_output / f"{Path(contract.disk_image_asset_name).stem}{release_notes.suffix.lower()}",
        ]

        generate_appcast = contract.tools_directory / "generate_appcast"
        generate_keys = contract.tools_directory / "generate_keys"
        sign_update = contract.tools_directory / "sign_update"
        verify_signing_key(contract, generate_keys)
        validate_candidate_increases(
            version,
            build,
            previous_appcast,
            initial_release,
            sign_update,
            ["--account", contract.keychain_account],
        )

        staged_dmg = destinations[0]
        staged_notes = destinations[3]
        source_digest = sha256(source_dmg)
        shutil.copy2(source_dmg, staged_dmg)
        shutil.copy2(release_notes, staged_notes)
        if sha256(staged_dmg) != source_digest:
            raise ReleaseMetadataError("staged disk image differs from the verified candidate")

        release_page = contract.release_page(tag)
        run_tool(
            [
                str(generate_appcast),
                "--account", contract.keychain_account,
                "--download-url-prefix", contract.release_download_prefix(tag),
                "--full-release-notes-url", release_page,
                "--link", release_page,
                "--versions", require_string(info, "CFBundleVersion"),
                "--maximum-versions", "1",
                "--maximum-deltas", "0",
                "-o", str(destinations[1]),
                str(temporary_output),
            ]
        )
        destinations[2].write_text(
            f"{source_digest}  {contract.disk_image_asset_name}\n", encoding="utf-8"
        )
        validate_metadata(
            app=app,
            dmg=staged_dmg,
            appcast=destinations[1],
            checksum=destinations[2],
            tag=f"v{version}",
            contract=contract,
            sign_update=sign_update,
            generate_keys=generate_keys,
            initial_release=True,
        )
        temporary_output.replace(output_directory)
    finally:
        if temporary_output.exists():
            shutil.rmtree(temporary_output)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate and validate signed Sparkle metadata for an exact FileFlip candidate."
    )
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--release-notes", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--appcast", type=Path)
    parser.add_argument("--checksum", type=Path)
    parser.add_argument("--validate-only", action="store_true")
    release_history = parser.add_mutually_exclusive_group(required=True)
    release_history.add_argument("--previous-appcast", type=Path)
    release_history.add_argument("--initial-release", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    try:
        contract = load_contract()
        if args.validate_only:
            if args.appcast is None or args.checksum is None:
                raise ReleaseMetadataError("--validate-only requires --appcast and --checksum")
            validate_metadata(
                app=args.app,
                dmg=args.dmg,
                appcast=args.appcast,
                checksum=args.checksum,
                tag=args.tag,
                contract=contract,
                sign_update=contract.tools_directory / "sign_update",
                generate_keys=contract.tools_directory / "generate_keys",
                previous_appcast=args.previous_appcast,
                initial_release=args.initial_release,
            )
        else:
            if args.release_notes is None or args.output_dir is None:
                raise ReleaseMetadataError("generation requires --release-notes and --output-dir")
            prepare_release(
                app=args.app,
                source_dmg=args.dmg,
                release_notes=args.release_notes,
                output_directory=args.output_dir,
                tag=args.tag,
                contract=contract,
                previous_appcast=args.previous_appcast,
                initial_release=args.initial_release,
            )
    except (OSError, json.JSONDecodeError, plistlib.InvalidFileException, ReleaseMetadataError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("Updater release metadata is candidate-bound and valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
