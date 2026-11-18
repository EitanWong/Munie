#!/bin/bash
# Run the adopted client's full offline unit suite and deterministic native UI smoke.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/bootstrap.sh
RUN_PATH="$(mktemp -d "$ROOT/build/remodex-ios-tests.XXXXXX")"
SDK_VERSION="$(xcodebuild -version -sdk iphonesimulator SDKVersion)"
DESTINATION="$(xcrun simctl list devices available --json | python3 scripts/select-simulator.py "$SDK_VERSION")"
SIMULATOR_ID="${DESTINATION##*id=}"
python3 - "$SIMULATOR_ID" <<'PY'
import subprocess, sys
subprocess.run(["xcrun", "simctl", "bootstatus", sys.argv[1], "-b"], check=True, timeout=240)
PY
xcodebuild -project Munie.xcodeproj -scheme MunieRemodex -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$RUN_PATH/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
  -destination-timeout 90 CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build-for-testing \
  2>&1 | tee "$RUN_PATH/build.log"
TEST_RUN="$(python3 scripts/test-available-ios.py --product remodex \
  --prepare-config "$RUN_PATH/DerivedData/Build/Products" --test-scope safe \
  --report "$RUN_PATH/test-configuration.json")"
python3 - "$ROOT/scripts/test-available-ios.py" -xctestrun "$TEST_RUN" \
  -destination "$DESTINATION" -parallel-testing-enabled NO -destination-timeout 90 \
  -resultBundlePath "$RUN_PATH/Results.xcresult" -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180 \
  test-without-building <<'PY' 2>&1 | tee "$RUN_PATH/tests.log"
import os, runpy, sys
policy = runpy.run_path(sys.argv[1])
os.execvpe("xcodebuild", ["xcodebuild", *sys.argv[2:]], policy["safe_environment"](dict(os.environ)))
PY
printf 'Munie Remodex tests passed: %s\n' "$RUN_PATH/Results.xcresult"
