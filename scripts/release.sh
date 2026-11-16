#!/bin/bash
# Intended for the protected GitHub Actions testflight environment.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${GITHUB_REF:-}" != refs/heads/main ]; then
  printf 'Release runs only in GitHub Actions on main.\n' >&2
  exit 1
fi
for NAME in APPLE_TEAM_ID APP_BUNDLE_ID DISTRIBUTION_CERTIFICATE_BASE64 \
  DISTRIBUTION_CERTIFICATE_PASSWORD PROVISIONING_PROFILE_BASE64 \
  APP_STORE_CONNECT_KEY_BASE64 APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID; do
  if [ -z "${!NAME:-}" ]; then
    printf 'Missing release secret: %s\n' "$NAME" >&2
    exit 1
  fi
done
XCODE_MAJOR="$(xcodebuild -version | awk '/Xcode/ {split($2, v, "."); print v[1]}')"
if [ "$XCODE_MAJOR" -lt 26 ]; then
  printf 'App Store distribution requires Xcode 26 or later.\n' >&2
  exit 1
fi
./scripts/bootstrap.sh
mkdir -p build
RELEASE_DIR="$(mktemp -d "$ROOT/build/release.XXXXXX")"
export RELEASE_DIR
KEYCHAIN="$RELEASE_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
PROFILE_PATH=""
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  if [ -n "$PROFILE_PATH" ]; then rm -f "$PROFILE_PATH"; fi
  rm -rf "$RELEASE_DIR"
}
trap cleanup EXIT
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['RELEASE_DIR'])
for name, filename in [('DISTRIBUTION_CERTIFICATE_BASE64', 'certificate.p12'),
                       ('PROVISIONING_PROFILE_BASE64', 'profile.mobileprovision'),
                       ('APP_STORE_CONNECT_KEY_BASE64', 'AuthKey.p8')]:
    (root / filename).write_bytes(base64.b64decode(os.environ[name], validate=True))
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$RELEASE_DIR/certificate.p12" -P "$DISTRIBUTION_CERTIFICATE_PASSWORD" \
  -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security cms -D -i "$RELEASE_DIR/profile.mobileprovision" > "$RELEASE_DIR/profile.plist"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print UUID' "$RELEASE_DIR/profile.plist")"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print Name' "$RELEASE_DIR/profile.plist")"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
PROFILE_PATH="$PROFILE_DIR/$PROFILE_UUID.mobileprovision"
if [ -e "$PROFILE_PATH" ]; then
  printf 'Refusing to replace an existing provisioning profile.\n' >&2
  PROFILE_PATH=""
  exit 1
fi
cp "$RELEASE_DIR/profile.mobileprovision" "$PROFILE_PATH"
export PROFILE_NAME
python3 - <<'PY'
import os, plistlib
from pathlib import Path
root = Path(os.environ['RELEASE_DIR'])
profile = plistlib.loads((root / 'profile.plist').read_bytes())
expected = os.environ['APPLE_TEAM_ID'] + '.' + os.environ['APP_BUNDLE_ID']
if profile['Entitlements']['application-identifier'] != expected:
    raise SystemExit('Provisioning profile does not match the team and bundle ID.')
options = {'method': 'app-store-connect', 'destination': 'upload',
           'teamID': os.environ['APPLE_TEAM_ID'], 'signingStyle': 'manual',
           'provisioningProfiles': {os.environ['APP_BUNDLE_ID']: os.environ['PROFILE_NAME']},
           'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True}
(root / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
xcodebuild -project Munie.xcodeproj -scheme Munie -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$RELEASE_DIR/Munie.xcarchive" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT}" archive
xcodebuild -exportArchive -archivePath "$RELEASE_DIR/Munie.xcarchive" \
  -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist" \
  -exportPath "$RELEASE_DIR/export" -allowProvisioningUpdates \
  -authenticationKeyPath "$RELEASE_DIR/AuthKey.p8" \
  -authenticationKeyID "$APP_STORE_CONNECT_KEY_ID" \
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
printf 'Archive uploaded to App Store Connect; processing status must be checked there.\n'
