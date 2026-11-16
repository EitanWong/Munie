#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/bootstrap.sh
mkdir -p build
DESTINATION="${IOS_TEST_DESTINATION:-}"
if [ -z "$DESTINATION" ]; then
  DESTINATION="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
# Prefer the newest runtime rather than an old image left on the hosted runner.
runtimes = sorted(devices, key=lambda value: tuple(int(part) for part in value.rsplit("iOS-", 1)[-1].split("-") if part.isdigit()), reverse=True)
phones = [d for runtime in runtimes if ".iOS-" in runtime for d in devices[runtime]
          if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not phones:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode Settings > Components, or set IOS_TEST_DESTINATION.")
print("platform=iOS Simulator,id=" + phones[0]["udid"])
')"
fi
SIMULATOR_ID="$(printf '%s' "$DESTINATION" | sed -n 's/.*id=\([^,]*\).*/\1/p')"
if [ -n "$SIMULATOR_ID" ]; then
  printf 'Booting iPhone simulator %s\n' "$SIMULATOR_ID"
  xcrun simctl bootstatus "$SIMULATOR_ID" -b
fi
RESULT_PATH="$(mktemp -d "$ROOT/build/ios-tests.XXXXXX")/Results.xcresult"
xcodebuild -project Munie.xcodeproj -scheme Munie -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath build/DerivedData \
  -resultBundlePath "$RESULT_PATH" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 \
  CODE_SIGNING_ALLOWED=NO test
printf 'iOS tests passed: %s\n' "$RESULT_PATH"
