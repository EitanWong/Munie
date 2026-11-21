#!/bin/bash
# Offline app-hosted lifecycle tests. Never logs into an account or starts a model.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
RUN_PATH="$(mktemp -d "$ROOT/build/desktop-tests.XXXXXX")"
xcodebuild -project Munie.xcodeproj -scheme MunieDesktop -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData-desktop \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 \
  -resultBundlePath "$RUN_PATH/Results.xcresult" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test \
  2>&1 | tee "$RUN_PATH/tests.log"
printf 'Native desktop lifecycle tests passed: %s\n' "$RUN_PATH/Results.xcresult"
