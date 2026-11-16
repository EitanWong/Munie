"""Offline safety tests for the pinned reference checkout tool."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("reference_sync", ROOT / "scripts/sync-references.py")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class ReferenceSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.checkouts = self.root / "references/checkouts"
        self.path = self.checkouts / "example"
        self.path.mkdir(parents=True)
        SYNC.git(self.path, "init", "--quiet")
        SYNC.git(self.path, "remote", "add", "origin", "https://github.com/example/example.git")
        (self.path / "README.md").write_text("Pristine reference\n")
        SYNC.git(self.path, "add", "README.md")
        SYNC.git(self.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "fixture")
        self.reference = {
            "name": "example", "url": "https://github.com/example/example.git",
            "commit": SYNC.git(self.path, "rev-parse", "HEAD"),
        }
        self.marker = self.path / ".git/munie-reference.json"
        self.marker.write_text(json.dumps(self.reference))

    def test_clean_checkout_is_verified_idempotently(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            SYNC.sync(self.reference, self.checkouts)
            SYNC.sync(self.reference, self.checkouts)
        self.assertEqual(output.getvalue().count("VERIFIED example "), 2)
        self.assertEqual((self.path / "README.md").read_text(), "Pristine reference\n")
        self.assertEqual(SYNC.git(self.path, "status", "--porcelain"), "")

    def test_dirty_checkout_is_preserved(self):
        (self.path / "README.md").write_text("Local edits\n")
        with self.assertRaisesRegex(ValueError, "dirty checkout"):
            SYNC.sync(self.reference, self.checkouts)
        self.assertEqual((self.path / "README.md").read_text(), "Local edits\n")

    def test_untracked_file_prevents_sync(self):
        (self.path / "notes.txt").write_text("Keep this")
        with self.assertRaisesRegex(ValueError, "dirty checkout"):
            SYNC.sync(self.reference, self.checkouts)
        self.assertTrue((self.path / "notes.txt").exists())

    def test_unmanaged_checkout_is_preserved(self):
        self.marker.unlink()
        with self.assertRaisesRegex(ValueError, "unmanaged checkout"):
            SYNC.sync(self.reference, self.checkouts)
        self.assertTrue((self.path / "README.md").is_file())

    def test_changed_origin_is_rejected(self):
        SYNC.git(self.path, "remote", "set-url", "origin", "https://github.com/other/repo.git")
        with self.assertRaisesRegex(ValueError, "Unexpected origin"):
            SYNC.sync(self.reference, self.checkouts)

    def test_changed_manifest_pin_is_rejected(self):
        changed = dict(self.reference, commit="0" * 40)
        with self.assertRaisesRegex(ValueError, "pin/identity differs"):
            SYNC.sync(changed, self.checkouts)
        self.assertEqual(SYNC.git(self.path, "rev-parse", "HEAD"), self.reference["commit"])

    def test_changed_head_is_rejected(self):
        SYNC.git(self.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "--quiet", "-m", "local")
        with self.assertRaisesRegex(ValueError, "Unexpected HEAD"):
            SYNC.sync(self.reference, self.checkouts)

    def test_symlink_checkout_is_rejected(self):
        link = self.checkouts / "linked"
        link.symlink_to(self.path, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink checkout"):
            SYNC.sync(dict(self.reference, name="linked"), self.checkouts)

    def test_manifest_license_tampering_is_rejected(self):
        shutil.copy(ROOT / "references/manifest.json", self.root / "references/manifest.json")
        shutil.copytree(ROOT / "references/licenses", self.root / "references/licenses")
        self.assertGreater(len(SYNC.load_manifest(self.root)), 0)
        (self.root / "references/licenses/omi.txt").write_text("Changed license")
        with self.assertRaisesRegex(ValueError, "License snapshot hash mismatch"):
            SYNC.load_manifest(self.root)

    def test_cli_requires_explicit_selection(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/sync-references.py")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("required", result.stderr)


if __name__ == "__main__":
    unittest.main()
