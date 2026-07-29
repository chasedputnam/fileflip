#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
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
        for tool in ("ffmpeg", "ffprobe"):
            path = media / tool
            path.write_bytes(b"binary")
            path.chmod(0o755)
        (media / "manifest.json").write_text("{}\n", encoding="utf-8")
        for name in module.REQUIRED_LICENSES:
            (licenses / name).write_text("license\n", encoding="utf-8")
        return app

    def test_accepts_exact_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = self.make_app(Path(temporary))
            self.assertEqual(module.verify_app(app), [])

    def test_rejects_flattened_missing_extra_nonexecutable_and_symlink_layouts(self) -> None:
        mutations = {
            "flattened": lambda app: (app / "Contents/Resources/ffmpeg").write_bytes(b"bad"),
            "missing": lambda app: (app / "Contents/Resources/MediaTools/ffprobe").unlink(),
            "extra": lambda app: (app / "Contents/Resources/MediaTools/extra").write_bytes(b"bad"),
            "nonexecutable": lambda app: (app / "Contents/Resources/MediaTools/ffmpeg").chmod(0o644),
            "symlink": lambda app: self.replace_with_symlink(app / "Contents/Resources/MediaTools/ffprobe"),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                app = self.make_app(Path(temporary))
                mutate(app)
                self.assertTrue(module.verify_app(app))

    @staticmethod
    def replace_with_symlink(path: Path) -> None:
        path.unlink()
        path.symlink_to("ffmpeg")


if __name__ == "__main__":
    unittest.main()
