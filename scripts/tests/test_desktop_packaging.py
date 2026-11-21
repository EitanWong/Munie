"""Real resource mutation/boundary regressions without running model binaries."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PACKAGE = load("desktop_package", "package-desktop-runtime.py")
EMBED = load("desktop_embed", "embed-desktop-runtime.py")
PREPARE = load("desktop_prepare", "prepare-desktop-runtime.py")


class DesktopPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def fixture(self):
        files = []
        for name in ("Runtime/bin/node", "Runtime/bin/codex", "Runtime/bin/MunieCodexGuardian", "Host/MunieRemodexBridge/src/desktop-host.js", "Host/MunieRemodexRelay/server.js"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture\n")
            files.append({"path": name, "bytes": 8, "sha256": hashlib.sha256(b"fixture\n").hexdigest()})
        manifest = self.root / "Runtime/manifest.json"
        manifest.write_text(json.dumps({"schemaVersion": 1, "distributionReady": False, "distributionBlockers": ["local fixture"], "files": files}))
        return manifest

    def test_complete_locked_resources_accept_for_local_build(self):
        self.fixture()
        self.assertEqual(EMBED.verify_bundle(self.root, False)["schemaVersion"], 1)

    def test_changed_binary_rejected(self):
        self.fixture()
        (self.root / "Runtime/bin/node").write_bytes(b"changed\n")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            EMBED.verify_bundle(self.root, False)

    def test_extra_account_file_rejected(self):
        self.fixture()
        (self.root / "Runtime/auth.json").write_text("not packaged")
        with self.assertRaisesRegex(ValueError, "unrecorded"):
            EMBED.verify_bundle(self.root, False)

    def test_missing_product_component_rejected(self):
        self.fixture()
        (self.root / "Host/MunieRemodexRelay/server.js").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            EMBED.verify_bundle(self.root, False)

    def test_escape_and_duplicate_paths_rejected(self):
        path = self.fixture()
        original = json.loads(path.read_text())
        for entry in ({"path": "../escape"}, original["files"][0]):
            with self.subTest(entry=entry):
                changed = dict(original, files=original["files"] + [entry])
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    EMBED.verify_bundle(self.root, False)

    def test_symlink_rejected_even_when_bytes_match(self):
        self.fixture()
        source = self.root / "Runtime/bin/node"
        source.unlink()
        source.symlink_to(self.root / "Runtime/bin/codex")
        with self.assertRaises(ValueError):
            EMBED.verify_bundle(self.root, False)

    def test_local_runtime_cannot_be_archived(self):
        self.fixture()
        with self.assertRaisesRegex(ValueError, "distribution"):
            EMBED.verify_bundle(self.root, True)

    def test_input_binary_hash_is_mandatory(self):
        path = self.root / "binary"
        path.write_bytes(b"binary")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            PACKAGE.locked_file({"path": str(path), "sha256": "0" * 64})

    def test_policy_preview_requires_both_pins_and_exact_version(self):
        patch = self.root / "references/codex-munie-stdio-policy.patch"
        patch.parent.mkdir()
        patch.write_bytes(b"patch")
        binary = self.root / "binary"
        binary.write_bytes(b"binary")
        lock = {"protocolVersion": 1, "patchSHA256": PACKAGE.sha256(patch),
                "binarySHA256": PACKAGE.sha256(binary)}
        self.assertEqual(PREPARE.verify_policy_preview(self.root, binary, lock), binary)
        with self.assertRaisesRegex(ValueError, "policy version"):
            PREPARE.verify_policy_preview(self.root, binary, dict(lock, protocolVersion=2))
        for field in ("patchSHA256", "binarySHA256"):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "SHA-256"):
                PREPARE.verify_policy_preview(self.root, binary, dict(lock, **{field: "0" * 64}))

    def test_committed_policy_patch_matches_runtime_lock(self):
        references = ROOT / "references"
        lock = json.loads((references / "desktop-runtime-lock.json").read_text())
        self.assertEqual(
            PACKAGE.sha256(references / "codex-munie-stdio-policy.patch"),
            lock["codexPolicyPreview"]["patchSHA256"],
        )

    def test_embed_binds_policy_marker_to_pinned_binary(self):
        manifest_path = self.fixture()
        manifest = json.loads(manifest_path.read_text())
        binary = next(entry for entry in manifest["files"] if entry["path"] == EMBED.CODEX_BINARY)
        marker_path = self.root / EMBED.POLICY_MARKER
        marker_path.parent.mkdir()
        lock_dir = tempfile.TemporaryDirectory()
        self.addCleanup(lock_dir.cleanup)
        lock = Path(lock_dir.name) / "runtime-lock.json"
        lock.write_text(json.dumps({"codexPolicyPreview": {"binarySHA256": binary["sha256"]}}))
        with patch.object(EMBED, "RUNTIME_LOCK", lock):
            with self.assertRaisesRegex(ValueError, "bundled together"):
                EMBED.verify_bundle(self.root, False)
            marker_path.write_bytes(b"1\n")
            manifest["files"].append({"path": EMBED.POLICY_MARKER, "bytes": 2,
                                      "sha256": PACKAGE.sha256(marker_path)})
            manifest_path.write_text(json.dumps(manifest))
            self.assertEqual(EMBED.verify_bundle(self.root, False), manifest)
            lock.write_text(json.dumps({"codexPolicyPreview": {"binarySHA256": "0" * 64}}))
            with self.assertRaisesRegex(ValueError, "bundled together"):
                EMBED.verify_bundle(self.root, False)

    def test_no_existing_output_is_replaced(self):
        manifest = self.root / "input.json"
        manifest.write_text('{"schemaVersion": 1}')
        output = self.root / "existing"
        output.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            PACKAGE.assemble(self.root, manifest, output)

    def test_reembedding_removes_old_resources_and_preserves_other_app_content(self):
        self.fixture()
        with tempfile.TemporaryDirectory() as output:
            destination = Path(output) / "Munie.app/Contents/Resources"
            for name in ("Runtime/removed-library", "Host/removed-module", "AppIcon.icns"):
                path = destination / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"old resource")
            with patch.dict(os.environ, {
                "SRCROOT": str(ROOT), "MUNIE_DESKTOP_BUNDLE": str(self.root),
                "TARGET_BUILD_DIR": output,
                "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Munie.app/Contents/Resources",
                "MUNIE_DESKTOP_COMPILE_ONLY": "NO", "ACTION": "build",
                "CODE_SIGNING_ALLOWED": "NO",
            }):
                EMBED.main()
            self.assertFalse((destination / "Runtime/removed-library").exists())
            self.assertFalse((destination / "Host/removed-module").exists())
            self.assertEqual((destination / "Runtime/bin/node").read_bytes(), b"fixture\n")
            self.assertEqual((destination / "AppIcon.icns").read_bytes(), b"old resource")

    def test_owned_resource_symlink_cleanup_never_follows_external_content(self):
        with tempfile.TemporaryDirectory() as output:
            destination = Path(output) / "resources"
            external = Path(output) / "external"
            destination.mkdir()
            external.mkdir()
            sentinel = external / "sentinel"
            sentinel.write_bytes(b"keep")
            (destination / "Host").symlink_to(external, target_is_directory=True)
            (destination / "Runtime").symlink_to(external / "missing", target_is_directory=True)
            EMBED.remove_owned_resources(destination)
            self.assertFalse((destination / "Host").is_symlink())
            self.assertFalse((destination / "Runtime").is_symlink())
            self.assertEqual(sentinel.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
