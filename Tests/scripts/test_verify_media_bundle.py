#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-media-bundle.py"
spec = importlib.util.spec_from_file_location("verify_media_bundle", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MediaBundleLayoutTests(unittest.TestCase):
    def make_app(self, root: Path) -> Path:
        app = root / "FileFlip.app"
        media = app / "Contents" / "Resources" / "MediaTools"
        licenses = media / "LICENSES"
        licenses.mkdir(parents=True)
        artifacts = []
        for tool in ("ffmpeg", "ffprobe"):
            path = media / tool
            path.write_bytes(b"binary")
            path.chmod(0o755)
            artifacts.append({
                "name": tool,
                "path": tool,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "signature": {"mode": "adhoc"},
            })
        (media / "manifest.json").write_text(
            json.dumps({"artifacts": artifacts}) + "\n", encoding="utf-8"
        )
        for name in module.REQUIRED_LICENSES:
            (licenses / name).write_text("license\n", encoding="utf-8")
        return app

    def test_accepts_exact_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary))
            self.assertEqual(module.verify_app(app), [])

    def test_rejects_flattened_missing_extra_nonexecutable_symlink_and_hash_mismatch(self) -> None:
        mutations = {
            "flattened": lambda app: (app / "Contents/Resources/ffmpeg").write_bytes(b"bad"),
            "missing": lambda app: (app / "Contents/Resources/MediaTools/ffprobe").unlink(),
            "extra": lambda app: (app / "Contents/Resources/MediaTools/extra").write_bytes(b"bad"),
            "nonexecutable": lambda app: (app / "Contents/Resources/MediaTools/ffmpeg").chmod(0o644),
            "symlink": lambda app: self.replace_with_symlink(app / "Contents/Resources/MediaTools/ffprobe"),
            "hash-mismatch": lambda app: (app / "Contents/Resources/MediaTools/ffmpeg").write_bytes(b"signed binary"),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                app = self.make_app(Path(temporary))
                mutate(app)
                self.assertTrue(module.verify_app(app))

    def test_identity_signature_replaces_unstable_executable_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary))
            media = app / "Contents/Resources/MediaTools"
            manifest_path = media / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            for artifact in manifest["artifacts"]:
                artifact.pop("sha256")
                artifact["signature"] = {
                    "mode": "identity",
                    "teamIdentifier": module.EXPECTED_TEAM_IDENTIFIER,
                }
                (media / artifact["name"]).write_bytes(b"export-resigned binary")
            manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")

            self.assertEqual(module.verify_app(app, identity_validator=lambda _: None), [])
            failures = module.verify_app(
                app, identity_validator=lambda _: "explicit requirement failed"
            )
            self.assertTrue(any("signature is invalid" in failure for failure in failures))

    @staticmethod
    def replace_with_symlink(path: Path) -> None:
        path.unlink()
        path.symlink_to("ffmpeg")


if __name__ == "__main__":
    unittest.main()
