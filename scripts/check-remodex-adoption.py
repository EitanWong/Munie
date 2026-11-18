#!/usr/bin/env python3
"""Check the fixed Remodex copy, dependency locks and archived notice evidence.

Offline checks do not require the ignored reference checkout. Supplying the
checkout additionally authenticates every source byte and emits reviewable diffs.
This validates recorded evidence; it does not infer licenses for embedded works.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def checked_path(root: Path, relative: str) -> Path:
    path = root / relative
    if Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise ValueError(f"unsafe recorded path: {relative}")
    if path.is_symlink() or path.resolve().is_relative_to(root.resolve()) is False:
        raise ValueError(f"symlink or escaping recorded path: {relative}")
    return path


def git(checkout: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(checkout), *args], stderr=subprocess.PIPE)


def verify_archive(root: Path, archive: dict) -> list[str]:
    errors = []
    base = root / "references/licenses/remodex-dependencies"
    for entry in archive["files"]:
        path = checked_path(base, entry["path"])
        if not path.is_file():
            errors.append(f"missing notice: {entry['path']}")
            continue
        data = path.read_bytes()
        if len(data) != entry["bytes"] or digest(data) != entry["sha256"]:
            errors.append(f"notice hash mismatch: {entry['path']}")
    combined = archive.get("combinedNotices")
    if combined:
        path = root / "references/licenses/remodex-third-party-notices.txt"
        if not path.is_file() or len(path.read_bytes()) != combined["bytes"] or digest(path.read_bytes()) != combined["sha256"]:
            errors.append("combined readable third-party notices missing or changed")
    return errors


def verify_locks(root: Path, archive: dict) -> list[str]:
    errors = []
    lock = read_json(root / "config/Remodex.Package.resolved")
    expected = {item["identity"]: (item["repository"], item["state"]) for item in archive["swiftPackages"]}
    actual = {item["identity"]: (item["location"], item["state"]) for item in lock["pins"]}
    if len(actual) != len(lock["pins"]) or actual != expected:
        errors.append("Swift dependency identities, locations or fixed revisions differ from reviewed lock")
    reviewed = {item["name"]: item for item in archive["npmPackages"]}
    for name, names in [("MunieRemodexBridge", {"ws", "qrcode-terminal"}), ("MunieRemodexRelay", {"ws"})]:
        path = root / "apps" / name / "package-lock.json"
        packages = read_json(path)["packages"]
        expected_paths = {""} | {"node_modules/" + item for item in names}
        if set(packages) != expected_paths:
            errors.append(f"{name}: unreviewed npm lock entries")
        for dependency in names:
            entry = packages.get("node_modules/" + dependency, {})
            for key in ("version", "integrity"):
                if entry.get(key) != reviewed[dependency][key]:
                    errors.append(f"{name}: {dependency} {key} differs from reviewed package")
    return errors


def inspect_copy(root: Path, inventory: dict, checkout: Path | None) -> tuple[list[str], list[dict], str]:
    errors, changes, diffs = [], [], []
    if checkout:
        if git(checkout, "rev-parse", "HEAD").decode().strip() != inventory["revision"]:
            raise ValueError("reference checkout is not the recorded revision")
        if git(checkout, "remote", "get-url", "origin").decode().strip() != inventory["repository"]:
            raise ValueError("reference checkout origin differs from recorded repository")
        if git(checkout, "status", "--porcelain").strip():
            raise ValueError("reference checkout is dirty; preserve changes before verification")
    destinations = set()
    for entry in inventory["files"]:
        relative = entry["destination"]
        if relative in destinations:
            errors.append(f"duplicate adopted destination: {relative}")
        destinations.add(relative)
        path = checked_path(root, relative)
        if not path.is_file():
            errors.append(f"missing adopted file: {relative}")
            continue
        before = git(checkout, "show", f"{inventory['revision']}:{entry['source']}") if checkout else None
        if before is not None and (digest(before) != entry["sha256"] or len(before) != entry["bytes"]):
            errors.append(f"source inventory hash mismatch: {entry['source']}")
        data = path.read_bytes()
        if digest(data) != entry["sha256"]:
            changes.append({**entry, "modifiedSHA256": digest(data), "modifiedBytes": len(data)})
            if entry["source"] == "LICENSE":
                errors.append(f"upstream license must remain verbatim: {relative}")
            if path.suffix in {".swift", ".js", ".mjs", ".c", ".h", ".applescript"} and b"Munie modification" not in data[:4096]:
                errors.append(f"modified source lacks prominent Munie modification notice: {relative}")
            if before is not None:
                diffs.extend(difflib.unified_diff(before.decode("utf-8").splitlines(keepends=True), data.decode("utf-8").splitlines(keepends=True), fromfile="upstream/" + entry["source"], tofile=relative))
    app = root / "apps/MunieRemodex"
    for path in app.rglob("*"):
        if path.is_symlink():
            errors.append(f"unexpected adopted symlink: {path.relative_to(root)}")
        if path.is_file() and (path.suffix.lower() in {".ttf", ".otf", ".a", ".dylib", ".svg", ".js"} or ".xcframework" in str(path)):
            errors.append(f"excluded upstream asset/binary reintroduced: {path.relative_to(root)}")
    for name in ["MunieRemodex", "MunieRemodexBridge", "MunieRemodexRelay"]:
        directory = root / "apps" / name
        if not any((directory / filename).is_file() for filename in ("NOTICE", "NOTICE.md")):
            errors.append(f"missing source adoption notice: {name}")
    return errors, changes, "".join(diffs)


def verify(root: Path, checkout: Path | None = None, distribution: bool = False) -> tuple[dict, str]:
    inventory = read_json(root / "references/licenses/remodex-source-manifest.json")
    archive = read_json(root / "references/licenses/remodex-dependencies/manifest.json")
    registry = read_json(root / "references/manifest.json")
    reference = next(item for item in registry["repositories"] if item["name"] == "remodex")
    errors = []
    if reference["commit"] != inventory["revision"] or reference["url"] != inventory["repository"]:
        errors.append("source inventory and main reference pin differ")
    errors.extend(verify_archive(root, archive))
    errors.extend(verify_locks(root, archive))
    copy_errors, changes, diff = inspect_copy(root, inventory, checkout)
    errors.extend(copy_errors)
    blockers = archive.get("distributionBlockers", [])
    if distribution and blockers:
        errors.append(f"distribution gate has {len(blockers)} unresolved embedded-layer/notice items")
    report = {
        "schemaVersion": 1,
        "revision": inventory["revision"],
        "sourceCheckoutVerified": checkout is not None,
        "adoptedFileCount": len(inventory["files"]),
        "modifiedFiles": changes,
        "archivedNoticeCount": len(archive["files"]),
        "distributionBlockers": blockers,
        "errors": errors,
        "passed": not errors,
    }
    return report, diff


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-checkout", type=Path)
    parser.add_argument("--report-directory", type=Path)
    parser.add_argument("--require-distribution-ready", action="store_true")
    args = parser.parse_args()
    try:
        report, diff = verify(args.root.resolve(), args.source_checkout, args.require_distribution_ready)
        if args.report_directory:
            args.report_directory.mkdir(parents=True, exist_ok=True)
            (args.report_directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            if args.source_checkout:
                (args.report_directory / "modified-source.patch").write_text(diff)
        print(f"Remodex {report['revision']}: {report['adoptedFileCount']} source copies, {len(report['modifiedFiles'])} modified, {report['archivedNoticeCount']} notice records")
        print(f"Distribution gate: {len(report['distributionBlockers'])} unresolved items; see references/remodex-adoption.md")
        for error in report["errors"]:
            print(error, file=sys.stderr)
        return 0 if report["passed"] else 1
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        print(f"Remodex adoption check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
