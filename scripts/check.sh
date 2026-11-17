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
./scripts/check-submissions.sh
swift run --package-path packages/MunieCore MunieCoreSmoke
./scripts/benchmark-core.sh
./scripts/build-apple-platforms.sh
printf 'Quality checks passed; core performance budgets, Apple Debug builds and iOS Release build passed.\n'
