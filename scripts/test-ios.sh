#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/bootstrap.sh
mkdir -p build
DESTINATION="${IOS_TEST_DESTINATION:-}"
if [ -z "$DESTINATION" ]; then
  SDK_VERSION="$(xcodebuild -version -sdk iphonesimulator SDKVersion)"
  DESTINATION="$(xcrun simctl list devices available --json | python3 scripts/select-simulator.py "$SDK_VERSION")"
fi
SIMULATOR_ID="$(printf '%s' "$DESTINATION" | sed -n 's/.*id=\([^,]*\).*/\1/p')"
if [ -n "$SIMULATOR_ID" ]; then
  printf 'Booting iPhone simulator %s\n' "$SIMULATOR_ID"
  python3 - "$SIMULATOR_ID" <<'PY'
import subprocess, sys
try:
    subprocess.run(["xcrun", "simctl", "bootstatus", sys.argv[1], "-b"], check=True, timeout=240)
except subprocess.TimeoutExpired:
    sys.exit("Simulator boot exceeded 240 seconds; inspect the runtime/runner before retrying.")
PY
fi
RESULT_PATH="$(mktemp -d "$ROOT/build/ios-tests.XXXXXX")/Results.xcresult"
xcodebuild -project Munie.xcodeproj -scheme Munie -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath build/DerivedData \
  -resultBundlePath "$RESULT_PATH" -parallel-testing-enabled NO \
  -destination-timeout 90 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee build/ios-tests.log
printf 'iOS tests passed: %s\n' "$RESULT_PATH"
