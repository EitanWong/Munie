#!/usr/bin/env python3
"""Developer-only assembly of a self-contained Mac app resource bundle.

Inputs are explicit, hash-locked native binaries and notice files. This never
installs software, executes lifecycle hooks, reads accounts or starts a model.
The finished app launches its own resources without a shell or system npm.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def locked_file(entry: dict, field: str = "path", hash_field: str = "sha256") -> Path:
    path = Path(entry[field]).expanduser()
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        raise ValueError(f"expected absolute regular file: {path}")
    if len(entry[hash_field]) != 64 or sha256(path) != entry[hash_field]:
        raise ValueError(f"SHA-256 mismatch: {path}")
    return path


def system_linked(path: Path) -> None:
    result = subprocess.run(["/usr/bin/otool", "-L", str(path)], capture_output=True, text=True, check=True)
    for line in result.stdout.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise ValueError(f"external runtime dependency in {path.name}: {dependency}")


def copy_regular_tree(source: Path, destination: Path, suffixes: set[str] | None = None) -> None:
    if not source.is_dir() or source.is_symlink():
        raise ValueError(f"missing regular source directory: {source}")
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"symlinks are not packaged: {path}")
        if not path.is_file() or (suffixes is not None and path.suffix not in suffixes):
            continue
        target = destination / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        target.chmod(0o644)


def install_locked_dependencies(destination: Path) -> None:
    # Build tooling only. npm verifies package-lock SRI before extracting. No
    # postinstall bootstrap, global installation or network fallback is allowed.
    subprocess.run([
        "npm", "ci", "--offline", "--ignore-scripts", "--no-audit", "--no-fund",
        "--bin-links=false",
        "--prefix", str(destination),
    ], check=True, capture_output=True, text=True)
    for path in destination.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"unexpected npm symlink: {path}")


def assemble(root: Path, manifest_path: Path, output: Path, distribution: bool = False) -> dict:
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported runtime manifest")
    if distribution and (manifest.get("distributionReady") is not True or manifest.get("distributionBlockers")):
        raise ValueError("runtime provenance/notice distribution gate is unresolved")
    if output.exists() or output.is_symlink():
        raise ValueError("output already exists; choose a fresh bundle directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".desktop-package-", dir=output.parent) as temporary:
        bundle = Path(temporary) / "bundle"
        executable_dir = bundle / "Runtime/bin"
        notices = bundle / "Runtime/Notices"
        executable_dir.mkdir(parents=True)
        notices.mkdir(parents=True)
        runtimes = {}
        for name in ("node", "codex"):
            entry = manifest[name]
            source = locked_file(entry)
            system_linked(source)
            license_path = locked_file(entry, "licensePath", "licenseSHA256")
            target = executable_dir / name
            shutil.copyfile(source, target)
            target.chmod(0o755)
            if sha256(target) != entry["sha256"]:
                raise ValueError(f"copy hash mismatch: {name}")
            shutil.copyfile(license_path, notices / f"{name}-LICENSE.txt")
            runtimes[name] = {key: entry[key] for key in ("version", "sha256", "licenseSHA256", "provenance")}
        bridge = root / "apps/MunieRemodexBridge"
        relay = root / "apps/MunieRemodexRelay"
        host = bundle / "Host"
        for name, source in (("MunieRemodexBridge", bridge), ("MunieRemodexRelay", relay)):
            target = host / name
            target.mkdir(parents=True)
            for filename in ("package.json", "package-lock.json", "LICENSE", "NOTICE.md"):
                source_path = source / filename
                if source_path.is_file():
                    shutil.copyfile(source_path, target / filename)
            if source == bridge:
                copy_regular_tree(source / "src", target / "src", {".js", ".json"})
            else:
                for path in source.glob("*.js"):
                    if not path.name.endswith(".test.js"):
                        shutil.copyfile(path, target / path.name)
            install_locked_dependencies(target)
        for entry in manifest.get("assets", []):
            relative = Path(entry["destination"])
            if relative.is_absolute() or ".." in relative.parts or not relative.parts or relative.parts[0] not in {"bin", "codex-path", "codex-resources"}:
                raise ValueError("unsafe native runtime asset destination")
            target = bundle / "Runtime" / relative
            if target.exists():
                raise ValueError(f"duplicate runtime asset: {relative}")
            source = locked_file(entry)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            target.chmod(0o755 if entry.get("executable") else 0o644)
            if entry.get("executable"):
                system_linked(target)
        package_metadata = manifest.get("codexPackage")
        if package_metadata:
            shutil.copyfile(locked_file(package_metadata), bundle / "Runtime/codex-package.json")
        shutil.copyfile(root / "references/licenses/remodex-third-party-notices.txt", notices / "Remodex-THIRD-PARTY.txt")
        report = {
            "schemaVersion": 1,
            "distributionReady": manifest.get("distributionReady") is True,
            "distributionBlockers": manifest.get("distributionBlockers", []),
            "runtimes": runtimes,
            "files": [
                {"path": str(path.relative_to(bundle)), "bytes": path.stat().st_size, "sha256": sha256(path)}
                for path in sorted(bundle.rglob("*")) if path.is_file()
            ],
        }
        (bundle / "Runtime/manifest.json").write_text(json.dumps(report, indent=2) + "\n")
        bundle.rename(output)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--input-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--distribution", action="store_true")
    args = parser.parse_args()
    try:
        report = assemble(args.root.resolve(), args.input_manifest, args.output.absolute(), args.distribution)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Desktop packaging failed: {error}\n")
    print(json.dumps({"path": str(args.output.absolute()), "files": len(report["files"]), "distributionReady": report["distributionReady"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
