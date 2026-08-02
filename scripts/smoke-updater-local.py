#!/usr/bin/env python3
"""Exercise a signed Sparkle replacement using isolated local FileFlip copies."""
from __future__ import annotations

import argparse
import functools
import http.server
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent
GENERATE_APPCAST = ROOT / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
TEST_VECTOR = ROOT / "Tests/Fixtures/Updater/ed25519-rfc8032-vector1.txt"
MANIFEST = ROOT / "Tests/Fixtures/Updater/manifest.json"
OLD_VERSION = ("0.1.0", "1")
NEW_VERSION = ("0.2.0", "2")
TIMEOUT = 90.0


class SmokeFailure(RuntimeError):
    pass


class RecordingHandler(http.server.SimpleHTTPRequestHandler):
    requests: list[str] = []

    def do_GET(self) -> None:
        type(self).requests.append(self.path)
        super().do_GET()

    def log_message(self, format: str, *args: object) -> None:
        print(f"feed: {format % args}")


def run(arguments: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=True,
        text=True,
        capture_output=capture,
        cwd=ROOT,
    )


def wait_until(description: str, predicate: Callable[[], bool], timeout: float = TIMEOUT) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.25)
    raise SmokeFailure(f"timed out waiting for {description}")


def load_info(app: Path) -> dict[str, object]:
    with (app / "Contents/Info.plist").open("rb") as handle:
        return plistlib.load(handle)


def configure_app(
    source: Path,
    destination: Path,
    *,
    bundle_identifier: str,
    version: tuple[str, str],
    feed_url: str,
    public_key: str,
) -> None:
    shutil.copytree(source, destination, symlinks=True)
    info_path = destination / "Contents/Info.plist"
    info = load_info(destination)
    info.update({
        "CFBundleIdentifier": bundle_identifier,
        "CFBundleShortVersionString": version[0],
        "CFBundleVersion": version[1],
        "SUFeedURL": feed_url,
        "SUPublicEDKey": public_key,
        "SUAllowedURLSchemes": ["http"],
        "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
    })
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle)
    run(["codesign", "--force", "--deep", "--sign", "-", str(destination)])



def set_up_preferences(bundle_identifier: str, sentinel: str) -> None:
    run(["defaults", "write", bundle_identifier, "SUEnableAutomaticChecks", "-bool", "true"])
    run(["defaults", "write", bundle_identifier, "SUAutomaticallyUpdate", "-bool", "true"])
    run([
        "defaults", "write", bundle_identifier, "SULastCheckTime", "-date",
        "2000-01-01 00:00:00 +0000",
    ])
    run(["defaults", "write", bundle_identifier, "FileFlipUpdateSmokeState", sentinel])


def terminate(bundle_identifier: str) -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application id "{bundle_identifier}" to quit'],
        check=False,
        text=True,
        capture_output=True,
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Smoke-test FileFlip's signed Sparkle download, staging, replacement, and state preservation"
    )
    parser.add_argument("--app", type=Path, required=True, help="built FileFlip.app used as the isolated source")
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    source = args.app.resolve()
    if sys.platform != "darwin":
        raise SmokeFailure("the updater smoke test requires macOS")
    if not (source / "Contents/MacOS/FileFlip").is_file():
        raise SmokeFailure(f"not a FileFlip application bundle: {source}")
    for tool in (GENERATE_APPCAST, TEST_VECTOR, MANIFEST):
        if not tool.is_file():
            raise SmokeFailure(f"required updater smoke input is missing: {tool}")

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    public_key = manifest["syntheticKey"]["publicKey"]
    unique = uuid.uuid4().hex
    bundle_identifier = f"app.fileconvert.FileConvert.UpdateSmoke.{unique}"
    sentinel = f"preserved-{unique}"
    old_process: subprocess.Popen[bytes] | None = None
    new_process: subprocess.Popen[bytes] | None = None
    server: http.server.ThreadingHTTPServer | None = None

    try:
        with tempfile.TemporaryDirectory(prefix="fileflip-updater-smoke.") as temporary:
            work = Path(temporary)
            server_root = work / "server"
            server_root.mkdir()
            RecordingHandler.requests = []
            handler = functools.partial(RecordingHandler, directory=str(server_root))
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            port = server.server_address[1]
            threading.Thread(target=server.serve_forever, daemon=True).start()
            feed_url = f"http://127.0.0.1:{port}/appcast.xml"

            old_app = work / "installed/FileFlip.app"
            new_app = work / "candidate/FileFlip.app"
            old_app.parent.mkdir()
            new_app.parent.mkdir()
            configure_app(
                source, old_app,
                bundle_identifier=bundle_identifier,
                version=OLD_VERSION,
                feed_url=feed_url,
                public_key=public_key,
            )
            configure_app(
                source, new_app,
                bundle_identifier=bundle_identifier,
                version=NEW_VERSION,
                feed_url=feed_url,
                public_key=public_key,
            )

            dmg = server_root / "FileFlip.dmg"
            run([
                "hdiutil", "create", "-volname", "FileFlip", "-srcfolder", str(new_app),
                "-ov", "-format", "UDZO", str(dmg),
            ])
            run([
                str(GENERATE_APPCAST), "--ed-key-file", str(TEST_VECTOR),
                "--download-url-prefix", f"http://127.0.0.1:{port}/",
                "--maximum-versions", "0", str(server_root),
            ])

            state_root = work / "persistent-state"
            state_root.mkdir()
            state_file = state_root / "sentinel.json"
            state_contents = json.dumps({"value": sentinel}) + "\n"
            state_file.write_text(state_contents, encoding="utf-8")
            set_up_preferences(bundle_identifier, sentinel)

            environment = os.environ.copy()
            environment["FILECONVERT_UI_TEST_STORAGE"] = str(state_root)
            old_process = subprocess.Popen([str(old_app / "Contents/MacOS/FileFlip")], env=environment)
            wait_until("signed appcast request", lambda: "/appcast.xml" in RecordingHandler.requests)
            wait_until("signed archive request", lambda: "/FileFlip.dmg" in RecordingHandler.requests)
            wait_until(
                "verified staged updater",
                lambda: subprocess.run(
                    ["pgrep", "-f", f"Autoupdate {bundle_identifier}"],
                    check=False,
                    capture_output=True,
                ).returncode == 0,
            )
            # The helper starts before extraction and verification fully settle. Quitting
            # in that narrow interval invalidates Sparkle's installer connection.
            time.sleep(5)

            terminate(bundle_identifier)
            old_process.wait(timeout=30)
            old_process = None
            wait_until(
                "application replacement",
                lambda: load_info(old_app).get("CFBundleVersion") == NEW_VERSION[1],
            )

            run(["codesign", "--verify", "--deep", "--strict", str(old_app)])
            installed = load_info(old_app)
            if installed.get("CFBundleShortVersionString") != NEW_VERSION[0]:
                raise SmokeFailure("replacement did not install the expected short version")
            if state_file.read_text(encoding="utf-8") != state_contents:
                raise SmokeFailure("application-support state changed during replacement")
            persisted = run(
                ["defaults", "read", bundle_identifier, "FileFlipUpdateSmokeState"],
                capture=True,
            ).stdout.strip()
            if persisted != sentinel:
                raise SmokeFailure("user preference state did not survive replacement")

            new_process = subprocess.Popen([str(old_app / "Contents/MacOS/FileFlip")], env=environment)
            time.sleep(2)
            if new_process.poll() is not None:
                raise SmokeFailure("updated application exited during relaunch")
            print(
                "PASS: signed appcast and archive downloaded; "
                f"FileFlip {OLD_VERSION[0]} ({OLD_VERSION[1]}) was replaced by "
                f"{NEW_VERSION[0]} ({NEW_VERSION[1]}); external state persisted; updated app relaunched"
            )
            return 0
    finally:
        terminate(bundle_identifier)
        for process in (old_process, new_process):
            if process is not None and process.poll() is None:
                process.terminate()
        if server is not None:
            server.shutdown()
            server.server_close()
        subprocess.run(["defaults", "delete", bundle_identifier], check=False, capture_output=True)
        shutil.rmtree(Path.home() / "Library/Caches" / bundle_identifier, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, json.JSONDecodeError, plistlib.InvalidFileException, subprocess.SubprocessError, SmokeFailure) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
