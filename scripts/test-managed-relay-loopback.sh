#!/bin/bash
# Explicit simulator-only interoperability test. Never discovers or signs into a physical device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "$#" -ne 1 ]; then
  printf 'Usage: %s IOS_SIMULATOR_UDID\n' "$0" >&2
  exit 64
fi
SIMULATOR_ID="$1"
if ! [[ "$SIMULATOR_ID" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
  printf 'An explicit iOS simulator UUID is required.\n' >&2
  exit 64
fi
NODE_BIN="${MUNIE_MANAGED_NODE:-node}"
BACKEND_ROOT="${MUNIE_MANAGED_BACKEND_ROOT:-$ROOT}"
DERIVED_DATA="${MUNIE_MANAGED_DERIVED_DATA:-$ROOT/build/DerivedData-managed-relay}"

mkdir -p build
RUN="$(mktemp -d "$ROOT/build/managed-swift-node.XXXXXX")"
printf 'Managed relay evidence: %s\n' "$RUN"
READY="$RUN/ready.json"
xcodegen generate > "$RUN/xcodegen.log" 2>&1
"$NODE_BIN" "$ROOT/scripts/fixtures/managed-relay/loopback-peer.cjs" "$BACKEND_ROOT" "$READY" > "$RUN/peer.log" 2>&1 &
FIXTURE_PID=$!
cleanup() {
  kill -TERM "$FIXTURE_PID" 2>/dev/null || true
  wait "$FIXTURE_PID" 2>/dev/null || true
  rm -f "$READY" "$READY.new"
}
trap cleanup EXIT

for ((attempt=0; attempt<100; attempt++)); do
  if [ -s "$READY" ] || ! kill -0 "$FIXTURE_PID" 2>/dev/null; then break; fi
  sleep 0.05
done
if [ ! -s "$READY" ]; then
  printf 'The loopback peer did not register; see %s/peer.log.\n' "$RUN" >&2
  exit 1
fi

export TEST_RUNNER_MUNIE_MANAGED_LOOPBACK_FIXTURE="$(jq -c . "$READY")"
export TEST_RUNNER_REMODEX_ACCEPTANCE_RUN_ID="$(uuidgen)"
xcodebuild -project Munie.xcodeproj -scheme MunieRemodex -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
  -resultBundlePath "$RUN/Results.xcresult" \
  -only-testing:MunieRemodexTests/ManagedRelayLoopbackProbeTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test > "$RUN/tests.log" 2>&1
xcrun xcresulttool get test-results summary --path "$RUN/Results.xcresult" > "$RUN/summary.json"
jq -e '.passedTests == 1 and .failedTests == 0 and .skippedTests == 0' "$RUN/summary.json" >/dev/null
