#!/usr/bin/env python3
"""Build-tool entry: fetch/verify fixed archives and assemble Mac app resources.

This runs on a developer or CI host, never on an end user's first launch.
Archive arguments allow fully offline reproduction with the same fixed hashes.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("desktop_packaging", ROOT / "scripts/package-desktop-runtime.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


def archive(entry: dict, supplied: Path | None, cache: Path) -> Path:
    path = supplied if supplied is not None else cache / entry["url"].rsplit("/", 1)[1]
    if not path.exists():
        if supplied is not None:
            raise ValueError(f"missing supplied archive: {path}")
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as download:
            temporary = Path(download.name)
            try:
                with urllib.request.urlopen(entry["url"], timeout=60) as response:
                    if not response.url.startswith("https://"):
                        raise ValueError("runtime download must retain HTTPS")
                    while block := response.read(1024 * 1024):
                        download.write(block)
                download.close()
                if PACKAGE.sha256(temporary) != entry["sha256"]:
                    raise ValueError("download archive SHA-256 mismatch")
                temporary.rename(path)
            finally:
                temporary.unlink(missing_ok=True)
    if path.is_symlink() or PACKAGE.sha256(path) != entry["sha256"]:
        raise ValueError(f"archive SHA-256 mismatch: {path}")
    return path


def extract_file(archive_path: Path, member: str, destination: Path, executable: bool = False) -> None:
    with tarfile.open(archive_path) as source:
        item = source.getmember(member)
        if not item.isfile() or item.size > 512 * 1024 * 1024:
            raise ValueError(f"invalid native archive member: {member}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open("wb") as target, source.extractfile(item) as stream:
            while block := stream.read(1024 * 1024):
                target.write(block)
    destination.chmod(0o755 if executable else 0o644)


def verify_policy_preview(root: Path, binary: Path, lock: dict) -> Path:
    if lock["protocolVersion"] != 1:
        raise ValueError("unknown Codex preview policy version")
    PACKAGE.locked_file({
        "path": str(root / "references/codex-munie-stdio-policy.patch"),
        "sha256": lock["patchSHA256"],
    })
    return PACKAGE.locked_file({"path": str(binary.absolute()), "sha256": lock["binarySHA256"]})


def prepare(root: Path, output: Path, node_archive: Path | None, codex_archive: Path | None,
            policy_codex: Path | None = None) -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("the reviewed desktop runtime currently targets Apple silicon Macs")
    lock = json.loads((root / "references/desktop-runtime-lock.json").read_text())
    if policy_codex is not None:
        policy_codex = verify_policy_preview(root, policy_codex, lock["codexPolicyPreview"])
    cache = root / ".tools/desktop-runtime/archives"
    cache.mkdir(parents=True, exist_ok=True)
    node = archive(lock["node"], node_archive, cache)
    codex = archive(lock["codex"], codex_archive, cache)
    with tempfile.TemporaryDirectory(prefix="desktop-input-", dir=cache.parent) as temporary:
        inputs = Path(temporary)
        prefix = "package/vendor/aarch64-apple-darwin/"
        extract_file(node, f"node-v{lock['node']['version']}-darwin-arm64/bin/node", inputs / "node", True)
        extract_file(node, f"node-v{lock['node']['version']}-darwin-arm64/LICENSE", inputs / "node-LICENSE")
        if policy_codex is None:
            extract_file(codex, prefix + "bin/codex", inputs / "codex", True)
        extract_file(codex, prefix + "codex-package.json", inputs / "codex-package.json")
        assets = []
        for relative in ("bin/codex-code-mode-host", "codex-path/rg", "codex-resources/zsh/bin/zsh"):
            destination = inputs / relative
            extract_file(codex, prefix + relative, destination, True)
            assets.append({"path": str(destination), "destination": relative, "sha256": PACKAGE.sha256(destination), "executable": True})
        guardian = inputs / "MunieCodexGuardian"
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-O2", str(root / "apps/MunieHost/Guardian/main.c"), "-o", str(guardian)], check=True)
        assets.append({"path": str(guardian), "destination": "bin/MunieCodexGuardian", "sha256": PACKAGE.sha256(guardian), "executable": True})
        manifest = {"schemaVersion": 1, "distributionReady": False, "distributionBlockers": lock["distributionBlockers"], "assets": assets}
        for name in ("node", "codex"):
            license_path = inputs / "node-LICENSE" if name == "node" else root / "references/licenses/codex-runtime.txt"
            manifest[name] = {
                "path": str(inputs / name),
                "version": lock[name]["version"], "licensePath": str(license_path),
                "licenseSHA256": PACKAGE.sha256(license_path),
                "provenance": lock[name]["url"],
            }
            if name == "codex" and policy_codex is not None:
                policy_lock = lock["codexPolicyPreview"]
                commit = lock["codex"]["sourceCommit"]
                manifest[name].update(
                    path=str(policy_codex), sha256=policy_lock["binarySHA256"],
                    provenance=f"https://github.com/openai/codex/tree/{commit} + codex-munie-stdio-policy.patch"
                )
                marker = inputs / "munie-stdio-policy"
                marker.write_bytes(b"1\n")
                assets.append({"path": str(marker), "destination": "codex-resources/munie-stdio-policy",
                               "sha256": PACKAGE.sha256(marker)})
                manifest["distributionBlockers"].append("Developer-only Codex stdio policy preview")
            else:
                manifest[name]["sha256"] = PACKAGE.sha256(inputs / name)
        if manifest["codex"]["licenseSHA256"] != lock["codex"]["licenseSHA256"]:
            raise ValueError("Codex source license SHA-256 mismatch")
        manifest["codexPackage"] = {"path": str(inputs / "codex-package.json"), "sha256": PACKAGE.sha256(inputs / "codex-package.json")}
        manifest_path = inputs / "input.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        PACKAGE.assemble(root, manifest_path, output)
    print(f"Assembled verified local Mac app resources: {output}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/DesktopBundle")
    parser.add_argument("--node-archive", type=Path)
    parser.add_argument("--codex-archive", type=Path)
    parser.add_argument("--policy-codex", type=Path, help="Use the pinned local policy preview; never for distribution")
    args = parser.parse_args()
    try:
        prepare(ROOT, args.output.absolute(), args.node_archive, args.codex_archive, args.policy_codex)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Desktop runtime preparation failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
