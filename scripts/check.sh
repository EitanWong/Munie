#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/bootstrap.sh
mkdir -p build
python3 scripts/check-repository.py
.tools/actionlint -shellcheck= -pyflakes=
./scripts/lint-swift.sh
xcrun swift-format lint --strict --recursive packages/MunieCore/Sources \
  packages/MunieCore/Tests packages/MunieRemote/Sources packages/MunieRemote/Tests \
  Package.swift packages/MunieCore/Package.swift packages/MunieRemote/Package.swift \
  scripts/fixtures/device-identity
swift test --package-path packages/MunieCore --enable-code-coverage
swift test --package-path packages/MunieRemote --enable-code-coverage
swift test --enable-code-coverage
./scripts/check-submissions.sh
swift build --product MunieCodexGuardian
HOST_BIN="$(swift build --show-bin-path)"
python3 scripts/probe-product-guardian.py --guardian "$HOST_BIN/MunieCodexGuardian" \
  --output "$ROOT/build/product-guardian.json"
swift run --package-path packages/MunieCore MunieCoreSmoke
./scripts/benchmark-core.sh
./scripts/build-apple-platforms.sh
./scripts/setup-remodex.sh
npm --prefix apps/MunieRemodexBridge test
npm --prefix apps/MunieRemodexRelay test
printf 'Quality checks passed; core performance budgets, Apple Debug builds and iOS Release build passed.\n'
