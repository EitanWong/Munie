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
xcodebuild -project Munie.xcodeproj -scheme Munie -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build-for-testing > build/ios-build.log 2>&1 || {
  tail -80 build/ios-build.log
  exit 1
}
printf 'Quality checks passed; iOS app and test bundles compiled. Log: build/ios-build.log\n'
