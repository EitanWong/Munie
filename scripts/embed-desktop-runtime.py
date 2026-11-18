#!/usr/bin/env python3
"""Xcode build phase: verify and embed already assembled resources, never download."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_bundle(source: Path, distribution: bool) -> dict:
    manifest = json.loads((source / "Runtime/manifest.json").read_text())
    if manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported desktop resource manifest")
    if distribution and (manifest.get("distributionReady") is not True or manifest.get("distributionBlockers")):
        raise ValueError("desktop runtime distribution provenance/notice gate is unresolved")
    expected = {"Runtime/manifest.json"}
    for entry in manifest["files"]:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts or relative.parts[0] not in {"Runtime", "Host"}:
            raise ValueError("unsafe resource manifest path")
        if str(relative) in expected:
            raise ValueError("duplicate resource manifest path")
        expected.add(str(relative))
        path = source / relative
        if path.is_symlink() or not path.is_file() or path.stat().st_size != entry["bytes"]:
            raise ValueError(f"missing or invalid bundled resource: {relative}")
        if sha256(path) != entry["sha256"]:
            raise ValueError(f"bundled resource SHA-256 mismatch: {relative}")
    actual = set()
    for path in source.rglob("*"):
        if path.is_symlink():
            raise ValueError("resource symlinks are not allowed")
        if path.is_file():
            actual.add(str(path.relative_to(source)))
    if actual != expected:
        raise ValueError("unrecorded resources in desktop bundle")
    for required in ("Runtime/bin/node", "Runtime/bin/codex", "Runtime/bin/MunieCodexGuardian", "Host/MunieRemodexBridge/src/desktop-host.js", "Host/MunieRemodexRelay/server.js"):
        if required not in expected:
            raise ValueError(f"missing required product resource: {required}")
    return manifest


def remove_owned_resources(destination: Path) -> None:
    for name in ("Runtime", "Host"):
        target = destination / name
        if target.is_symlink():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)


def main() -> None:
    root = Path(os.environ["SRCROOT"])
    source = Path(os.environ.get("MUNIE_DESKTOP_BUNDLE", str(root / "build/DesktopBundle")))
    distribution = os.environ.get("ACTION") == "install"
    destination = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
    if os.environ.get("MUNIE_DESKTOP_COMPILE_ONLY") == "YES":
        if distribution:
            raise ValueError("compile-only builds cannot be archived")
        # Explicit CI/unit build. Product refuses readiness without resources.
        # Remove stale resources if a previously packaged build used this folder.
        remove_owned_resources(destination)
        print("Compile-only Mac build: no execution resources embedded; not an installable product.")
        return
    verify_bundle(source, distribution)
    destination.mkdir(parents=True, exist_ok=True)
    remove_owned_resources(destination)
    for name in ("Runtime", "Host"):
        target = destination / name
        shutil.copytree(source / name, target)
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY")
    if os.environ.get("CODE_SIGNING_ALLOWED") == "YES" and identity:
        executables = [path for path in (destination / "Runtime").rglob("*") if path.is_file() and os.access(path, os.X_OK)]
        for path in executables:
            command = ["/usr/bin/codesign", "--force", "--sign", identity]
            if path.name == "node":
                command.extend(["--entitlements", str(root / "config/DesktopRuntime.entitlements")])
            if identity != "-":
                command.extend(["--options", "runtime", "--timestamp"])
            subprocess.run(command + [str(path)], check=True)
    print("Verified and embedded the Mac runtime, bridge, relay and notices.")


if __name__ == "__main__":
    main()
