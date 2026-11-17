#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/scripts/fixtures/device-identity-ios"
OUTPUT="$ROOT/build/identity-ios"
CHECKOUTS="$ROOT/references/checkouts/identity-ios"
PROJECT="$OUTPUT/MunieIdentityResearch.xcodeproj"
LOCK="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
verify_lock() {
  python3 - "$ROOT" "$1" <<'PY'
import json
from pathlib import Path
import sys
root, lock = Path(sys.argv[1]), Path(sys.argv[2])
manifest = json.loads((root / 'references/licenses/device-identity/manifest.json').read_bytes())
expected = {p['identity']: (p['repository'], p['revision']) for p in manifest['packages']}
pins = json.loads(lock.read_bytes())['pins']
actual = {p['identity']: (p['location'], p['state']['revision']) for p in pins}
if len(pins) != 3 or len(actual) != 3 or actual != expected:
    sys.exit('iOS identity lock differs from reviewed dependency revisions')
print('iOS identity lock matches reviewed dependency revisions')
PY
}
if [ -L "$ROOT/references/checkouts" ] || [ -L "$CHECKOUTS" ] || [ -L "$OUTPUT" ]; then
  printf 'Identity research refuses a symlinked build or checkout directory.\n' >&2
  exit 2
fi
verify_lock "$FIXTURE/Package.resolved"
"$ROOT/scripts/bootstrap.sh"
mkdir -p "$OUTPUT" "$CHECKOUTS"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$FIXTURE/App/ResearchProtocol.swift" "$FIXTURE/Tests/OwnershipChecks.swift" \
  -o "$OUTPUT/ownership-checks" > "$OUTPUT/ownership-checks.log" 2>&1 || {
  check_status=$?
  cat "$OUTPUT/ownership-checks.log"
  exit "$check_status"
}
"$OUTPUT/ownership-checks" >> "$OUTPUT/ownership-checks.log" 2>&1 || {
  check_status=$?
  cat "$OUTPUT/ownership-checks.log"
  exit "$check_status"
}
"$ROOT/.tools/xcodegen/bin/xcodegen" generate --spec "$FIXTURE/project.yml" --project "$OUTPUT"
mkdir -p "$(dirname "$LOCK")"
cp "$FIXTURE/Package.resolved" "$LOCK"
OPTIONS=(-project "$PROJECT" -scheme MunieIdentityResearch -configuration Release
  -destination 'generic/platform=iOS Simulator'
  -derivedDataPath "$OUTPUT/DerivedData"
  -clonedSourcePackagesDirPath "$CHECKOUTS/SourcePackages"
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile)
xcodebuild "${OPTIONS[@]}" CODE_SIGNING_ALLOWED=NO build > "$OUTPUT/build.log" 2>&1 || {
  build_status=$?
  tail -80 "$OUTPUT/build.log"
  exit "$build_status"
}
# Also check the lock that Xcode actually used, after compilation.
verify_lock "$LOCK"
APP="$OUTPUT/DerivedData/Build/Products/Release-iphonesimulator/MunieIdentityResearch.app"
test -d "$APP"
# A linker-only signature has no application identifier; actual simulator
# Security queries reject it with -34018. Seal only this research simulator app
# with its exact private group. No signing account, team or profile is involved.
python3 - "$APP/Info.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'app.munie.research.identity'
assert info['CFBundleSupportedPlatforms'] == ['iPhoneSimulator']
PY
codesign --force --sign - --entitlements "$FIXTURE/Simulator.entitlements" \
  "$APP" > "$OUTPUT/simulator-signing.log" 2>&1
codesign --verify --strict "$APP" >> "$OUTPUT/simulator-signing.log" 2>&1
codesign --display --entitlements - --xml "$APP" > "$OUTPUT/effective-entitlements.plist" \
  2>> "$OUTPUT/simulator-signing.log"
python3 - "$FIXTURE/Simulator.entitlements" "$OUTPUT/effective-entitlements.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as stream:
    expected = plistlib.load(stream)
with open(sys.argv[2], 'rb') as stream:
    actual = plistlib.load(stream)
assert actual == expected, 'Effective research simulator entitlements differ'
print('Research simulator signature and exact private Keychain group verified')
PY
printf 'iOS identity research app: %s\n' "$APP"
