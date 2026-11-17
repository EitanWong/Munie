"""Offline regressions for source provenance, notice and dependency boundaries."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-remodex-adoption.py"
SPEC = importlib.util.spec_from_file_location("remodex_adoption", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AdoptionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "munie"
        self.root.mkdir()
        self.before = b"print(\"original\")\n"
        self.entry = {
            "source": "Client.swift",
            "destination": "apps/MunieRemodex/App/Client.swift",
            "bytes": len(self.before),
            "sha256": MODULE.digest(self.before),
        }
        self.pin = "a" * 40
        self.repository = "https://example.invalid/remodex.git"
        self.write(self.entry["destination"], self.before)
        for name in ("MunieRemodex", "MunieRemodexBridge", "MunieRemodexRelay"):
            self.write(f"apps/{name}/NOTICE", b"Fixture source attribution\n")
        self.write("references/licenses/remodex-dependencies/LICENSE", b"Fixture permission\n")
        self.archive = {
            "swiftPackages": [{"identity": "fixture", "repository": "https://example.invalid/fixture", "state": {"revision": "b" * 40, "version": "1.0.0"}}],
            "npmPackages": [{"name": "ws", "version": "8.21.0", "integrity": "fixture-ws"}, {"name": "qrcode-terminal", "version": "0.12.0", "integrity": "fixture-qr"}],
            "files": [{"path": "LICENSE", "bytes": 19, "sha256": MODULE.digest(b"Fixture permission\n")}],
            "distributionBlockers": [{"component": "unresolved-grammar"}],
        }
        self.json("config/Remodex.Package.resolved", {"pins": [{"identity": "fixture", "location": self.archive["swiftPackages"][0]["repository"], "state": self.archive["swiftPackages"][0]["state"]}]})
        for name, dependencies in [("MunieRemodexBridge", ["ws", "qrcode-terminal"]), ("MunieRemodexRelay", ["ws"])]:
            packages = {"": {}}
            for dependency in dependencies:
                entry = next(item for item in self.archive["npmPackages"] if item["name"] == dependency)
                packages["node_modules/" + dependency] = {key: entry[key] for key in ("version", "integrity")}
            self.json(f"apps/{name}/package-lock.json", {"packages": packages})
        self.save_records()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def json(self, name, value):
        self.write(name, (json.dumps(value) + "\n").encode())

    def save_records(self):
        self.json("references/licenses/remodex-source-manifest.json", {"revision": self.pin, "repository": self.repository, "files": [self.entry]})
        self.json("references/licenses/remodex-dependencies/manifest.json", self.archive)
        self.json("references/manifest.json", {"repositories": [{"name": "remodex", "commit": self.pin, "url": self.repository}]})

    def verify(self, **kwargs):
        return MODULE.verify(self.root, **kwargs)[0]

    def test_offline_checks_preserve_explicit_distribution_gate(self):
        self.assertTrue(self.verify()["passed"])
        self.assertFalse(self.verify(distribution=True)["passed"])
        self.assertEqual(len(self.verify()["distributionBlockers"]), 1)

    def test_missing_source_and_changed_notice_are_rejected(self):
        (self.root / self.entry["destination"]).unlink()
        self.write("references/licenses/remodex-dependencies/LICENSE", b"replaced\n")
        errors = self.verify()["errors"]
        self.assertTrue(any("missing adopted" in item for item in errors))
        self.assertTrue(any("notice hash mismatch" in item for item in errors))

    def test_changed_source_requires_prominent_notice(self):
        self.write(self.entry["destination"], b"print(\"changed\")\n")
        self.assertFalse(self.verify()["passed"])
        self.write(self.entry["destination"], b"// Munie modification: fixture change\nprint(\"changed\")\n")
        report = self.verify()
        self.assertTrue(report["passed"])
        self.assertEqual(len(report["modifiedFiles"]), 1)

    def test_unreviewed_swift_revision_is_rejected(self):
        path = self.root / "config/Remodex.Package.resolved"
        data = json.loads(path.read_text())
        data["pins"][0]["state"]["revision"] = "c" * 40
        path.write_text(json.dumps(data))
        self.assertFalse(self.verify()["passed"])

    def test_unreviewed_npm_dependency_is_rejected(self):
        path = self.root / "apps/MunieRemodexBridge/package-lock.json"
        data = json.loads(path.read_text())
        data["packages"]["node_modules/native-peer"] = {"version": "1.0"}
        path.write_text(json.dumps(data))
        self.assertFalse(self.verify()["passed"])

    def test_excluded_binary_and_font_are_rejected(self):
        self.write("apps/MunieRemodex/App/GhosttyKit.xcframework/Info.plist", b"fixture")
        self.write("apps/MunieRemodex/Resources/unknown.otf", b"fixture")
        errors = self.verify()["errors"]
        self.assertEqual(sum("excluded upstream asset/binary" in item for item in errors), 2)

    def test_escaping_symlink_is_rejected(self):
        path = self.root / self.entry["destination"]
        path.unlink()
        outside = Path(self.temporary.name) / "outside.swift"
        outside.write_bytes(self.before)
        path.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.verify()

    def test_upstream_license_cannot_be_silently_modified(self):
        self.entry["source"] = "LICENSE"
        self.entry["destination"] = "apps/MunieRemodex/LICENSE"
        self.write(self.entry["destination"], b"replaced terms\n")
        self.save_records()
        self.assertTrue(any("license must remain verbatim" in item for item in self.verify()["errors"]))

    def test_exact_checkout_authenticates_source_and_emits_real_diff(self):
        checkout = Path(self.temporary.name) / "upstream"
        checkout.mkdir()
        subprocess.run(["git", "init", "-q", str(checkout)], check=True)
        (checkout / "Client.swift").write_bytes(self.before)
        subprocess.run(["git", "-C", str(checkout), "add", "."], check=True)
        subprocess.run(["git", "-C", str(checkout), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        subprocess.run(["git", "-C", str(checkout), "remote", "add", "origin", self.repository], check=True)
        self.pin = MODULE.git(checkout, "rev-parse", "HEAD").decode().strip()
        self.save_records()
        self.write(self.entry["destination"], b"// Munie modification: fixture\nprint(\"changed\")\n")
        report, diff = MODULE.verify(self.root, checkout)
        self.assertTrue(report["passed"])
        self.assertTrue(report["sourceCheckoutVerified"])
        self.assertIn('-print("original")', diff)
        self.assertIn('+print("changed")', diff)
        self.entry["sha256"] = "0" * 64
        self.save_records()
        self.assertFalse(MODULE.verify(self.root, checkout)[0]["passed"])
        (checkout / "Client.swift").write_text("dirty\n")
        with self.assertRaisesRegex(ValueError, "dirty"):
            MODULE.verify(self.root, checkout)


if __name__ == "__main__":
    unittest.main()
