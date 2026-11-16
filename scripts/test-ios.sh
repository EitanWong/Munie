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
phones = [d for runtime, ds in devices.items() if ".iOS-" in runtime for d in ds
          if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not phones:
    sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode Settings > Components, or set IOS_TEST_DESTINATION.")
print("platform=iOS Simulator,id=" + phones[0]["udid"])
')"
fi
RESULT_PATH="$(mktemp -d "$ROOT/build/ios-tests.XXXXXX")/Results.xcresult"
xcodebuild -project Munie.xcodeproj -scheme Munie -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath build/DerivedData \
  -resultBundlePath "$RESULT_PATH" -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
printf 'iOS tests passed: %s\n' "$RESULT_PATH"
