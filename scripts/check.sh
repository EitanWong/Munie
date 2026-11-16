#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/bootstrap.sh
mkdir -p build
python3 scripts/check-repository.py
.tools/actionlint -shellcheck= -pyflakes=
xcrun swift-format lint --strict --recursive apps packages/MunieCore/Sources \
  packages/MunieCore/Tests Package.swift packages/MunieCore/Package.swift
swift test --package-path packages/MunieCore --enable-code-coverage
swift test --enable-code-coverage
swift run --package-path packages/MunieCore MunieCoreSmoke
./scripts/build-apple-platforms.sh
printf 'Quality checks passed; all Apple platform apps and iOS test bundles compiled.\n'
