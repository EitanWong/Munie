#!/usr/bin/env python3
"""Materialize explicitly selected, pinned research repositories without overwriting work."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def git(path, *args, check=True):
    environment = dict(os.environ, GIT_LFS_SKIP_SMUDGE="1", GIT_TERMINAL_PROMPT="0")
    result = subprocess.run(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false", "-C", str(path), *args],
        text=True, capture_output=True, env=environment,
    )
    if check and result.returncode:
        raise ValueError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


def load_manifest(root):
    manifest = json.loads((root / "references/manifest.json").read_text())
    if manifest.get("schema_version") != 1:
        raise ValueError("Unsupported reference manifest version")
    references = manifest["repositories"]
    names = set()
    for item in references:
        name = item["name"]
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name) or name in names:
            raise ValueError(f"Invalid or repeated reference name: {name}")
        names.add(name)
        if not re.fullmatch(r"[a-f0-9]{40}", item["commit"]):
            raise ValueError(f"Invalid full commit pin: {name}")
        if not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", item["url"]):
            raise ValueError(f"Unsupported repository URL: {name}")
        snapshot = item["license"]["snapshot"]
        if snapshot:
            if not re.fullmatch(r"licenses/[a-z][a-z0-9-]*\.txt", snapshot):
                raise ValueError(f"Invalid license snapshot path: {name}")
            license_file = root / "references" / snapshot
            expected = next(source for source in item["sources"] if source["path"] == "LICENSE")
            actual = hashlib.sha256(license_file.read_bytes()).hexdigest()
            if actual != expected["sha256"]:
                raise ValueError(f"License snapshot hash mismatch: {name}")
    return references


def identity(reference):
    return {key: reference[key] for key in ("name", "url", "commit")}


def validate_checkout(path, reference, allow_incomplete=False):
    if path.is_symlink() or not path.is_dir() or (path / ".git").is_symlink():
        raise ValueError(f"Refusing non-directory or symlink checkout: {path}")
    marker = path / ".git/munie-reference.json"
    if not (path / ".git").is_dir() or not marker.is_file() or marker.is_symlink():
        raise ValueError(f"Refusing unmanaged checkout: {path}")
    if json.loads(marker.read_text()) != identity(reference):
        raise ValueError(f"Managed checkout pin/identity differs; preserve it and choose a fresh location: {path}")
    if Path(git(path, "rev-parse", "--show-toplevel")).resolve() != path.resolve():
        raise ValueError(f"Unexpected Git root: {path}")
    if git(path, "remote", "get-url", "origin") != reference["url"]:
        raise ValueError(f"Unexpected origin: {path}")
    if git(path, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError(f"Refusing dirty checkout: {path}")
    head = git(path, "rev-parse", "--verify", "HEAD", check=False)
    if not head and allow_incomplete:
        return False
    if head != reference["commit"]:
        raise ValueError(f"Unexpected HEAD {head!r}: {path}")
    return True


def sync(reference, checkouts):
    if checkouts.is_symlink() or checkouts.parent.is_symlink():
        raise ValueError(f"Refusing symlink reference root: {checkouts}")
    checkouts.mkdir(parents=True, exist_ok=True)
    path = checkouts / reference["name"]
    if path.exists() or path.is_symlink():
        if validate_checkout(path, reference, allow_incomplete=True):
            print(f"VERIFIED {reference['name']} {reference['commit']} {path}")
            return
    else:
        path.mkdir()
        git(path, "init", "--quiet")
        git(path, "remote", "add", "origin", reference["url"])
        (path / ".git/munie-reference.json").write_text(json.dumps(identity(reference), sort_keys=True) + "\n")
    git(path, "fetch", "--depth=1", "--no-tags", "origin", reference["commit"])
    git(path, "checkout", "--detach", "--quiet", "FETCH_HEAD")
    validate_checkout(path, reference)
    print(f"SYNCED {reference['name']} {reference['commit']} {path}")


def main():
    references = load_manifest(ROOT)
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--name", action="append", choices=[item["name"] for item in references])
    selection.add_argument("--all", action="store_true", help="Explicitly fetch every reference, including large repositories")
    selection.add_argument("--list", action="store_true", help="Validate manifest and local license hashes; list pins")
    args = parser.parse_args()
    if args.list:
        for item in references:
            print(f"{item['name']} {item['commit']} {item['decision']}")
        return
    for item in references:
        if args.all or item["name"] in args.name:
            sync(item, ROOT / "references/checkouts")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, StopIteration) as error:
        print(f"Reference sync failed: {error}", file=sys.stderr)
        sys.exit(1)
