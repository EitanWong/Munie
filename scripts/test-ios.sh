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
RUN_PATH="$(mktemp -d "$ROOT/build/ios-tests.XXXXXX")"
RESULT_PATH="$RUN_PATH/Results.xcresult"
xcodebuild -project Munie.xcodeproj -scheme Munie -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$RUN_PATH/DerivedData" \
  -resultBundlePath "$RUN_PATH/Build.xcresult" -parallel-testing-enabled NO \
  -destination-timeout 90 \
  CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tee build/ios-tests.log
TEST_RUN="$(python3 scripts/test-available-ios.py \
  --prepare-config "$RUN_PATH/DerivedData/Build/Products" --test-scope default \
  --report "$RUN_PATH/test-configuration.json" 2> >(tee -a build/ios-tests.log >&2))"
python3 - "$ROOT/scripts/test-available-ios.py" -xctestrun "$TEST_RUN" -destination "$DESTINATION" \
  -resultBundlePath "$RESULT_PATH" -parallel-testing-enabled NO \
  -destination-timeout 90 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 \
  test-without-building <<'PY' 2>&1 | tee -a build/ios-tests.log
import os, runpy, sys
# A previous opt-in run may leave TEST_RUNNER_MUNIE_* in the shell environment.
# Reuse the device runner's policy before Xcode can forward it into the app.
policy = runpy.run_path(sys.argv[1])
os.execvpe("xcodebuild", ["xcodebuild", *sys.argv[2:]], policy["safe_environment"](dict(os.environ)))
PY
printf 'iOS tests passed: %s\n' "$RESULT_PATH"
