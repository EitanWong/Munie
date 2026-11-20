#!/bin/bash
# Explicit simulator-only interoperability test. Never discovers or signs into a physical device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != '--approval' ]; }; then
  printf 'Usage: %s IOS_SIMULATOR_UDID [--approval]\n' "$0" >&2
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
if [ "$#" -eq 2 ] && [ -z "${MUNIE_MANAGED_PACKAGED_APP:-}" ]; then
  printf '%s\n' 'The approval fixture requires an explicit signed Mac app.' >&2
  exit 64
fi

mkdir -p build
RUN="$(mktemp -d "$ROOT/build/managed-swift-node.XXXXXX")"
printf 'Managed relay evidence: %s\n' "$RUN"
READY="$RUN/ready.json"
TEST_CASE="testUnreachableLANFallsBackToManagedEncryptedInitializeAndPreservesLANHint"
xcodegen generate > "$RUN/xcodegen.log" 2>&1
if [ -n "${MUNIE_MANAGED_PACKAGED_APP:-}" ]; then
  TEST_CASE="testSignedPreviewReadsAuthorizedProjectAndRefusesTaskCreation"
  if [ "$#" -eq 2 ]; then
    TEST_CASE="testSignedFixtureApprovesStopsAndRecoversExactlyOneSubmission"
  fi
  codesign --verify --deep --strict "$MUNIE_MANAGED_PACKAGED_APP" > "$RUN/signature.log" 2>&1
  RESOURCES="$MUNIE_MANAGED_PACKAGED_APP/Contents/Resources"
  "$RESOURCES/Runtime/bin/node" "$ROOT/scripts/fixtures/managed-relay/packaged-preview-peer.cjs" \
    "$RESOURCES" "$READY" "${@:2}" > "$RUN/peer.log" 2>&1 &
else
  "$NODE_BIN" "$ROOT/scripts/fixtures/managed-relay/loopback-peer.cjs" "$BACKEND_ROOT" "$READY" > "$RUN/peer.log" 2>&1 &
fi
FIXTURE_PID=$!
cleanup() {
  status=$?
  trap - EXIT
  kill -TERM "$FIXTURE_PID" 2>/dev/null || true
  peer_status=0
  wait "$FIXTURE_PID" 2>/dev/null || peer_status=$?
  for file in "$READY" "$READY.new"; do
    if [ -f "$file" ]; then unlink "$file"; fi
  done
  if [ "$status" -eq 0 ] && [ -n "${MUNIE_MANAGED_PACKAGED_APP:-}" ]; then
    if [ "$peer_status" -ne 0 ] || ! grep -Fxq 'Signed preview stopped and disposable state removed.' "$RUN/peer.log"; then
      printf 'Signed preview cleanup was not confirmed; see %s/peer.log.\n' "$RUN" >&2
      status=1
    fi
  fi
  exit "$status"
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
export TEST_RUNNER_MUNIE_DEV_MANAGED_RELAY_ORIGIN="$(jq -er .origin "$READY")"
export TEST_RUNNER_REMODEX_ACCEPTANCE_RUN_ID="$(uuidgen)"
xcodebuild -project Munie.xcodeproj -scheme MunieRemodex -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -derivedDataPath "$DERIVED_DATA" \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
  -resultBundlePath "$RUN/Results.xcresult" \
  "-only-testing:MunieRemodexTests/ManagedRelayLoopbackProbeTests/$TEST_CASE" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test > "$RUN/tests.log" 2>&1
xcrun xcresulttool get test-results summary --path "$RUN/Results.xcresult" > "$RUN/summary.json"
jq -e '.passedTests == 1 and .failedTests == 0 and .skippedTests == 0' "$RUN/summary.json" >/dev/null
