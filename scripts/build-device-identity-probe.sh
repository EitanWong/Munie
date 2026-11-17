#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/scripts/fixtures/device-identity"
SCRATCH="$ROOT/references/checkouts/device-identity-build"
if [ -L "$ROOT/references/checkouts" ] || [ -L "$SCRATCH" ]; then
  printf 'Identity research refuses a symlinked checkout directory.\n' >&2
  exit 2
fi
mkdir -p "$SCRATCH"
OPTIONS=(--package-path "$FIXTURE" --scratch-path "$SCRATCH/build"
  --cache-path "$SCRATCH/cache" --config-path "$SCRATCH/config"
  --security-path "$SCRATCH/security" --disable-keychain --disable-netrc
  --force-resolved-versions)
swift test "${OPTIONS[@]}" -c release
swift build "${OPTIONS[@]}" -c release --product MunieDeviceIdentityProbe
BIN_DIRECTORY="$(swift build "${OPTIONS[@]}" -c release --show-bin-path)"
mkdir -p "$ROOT/build"
install -m 700 "$BIN_DIRECTORY/MunieDeviceIdentityProbe" "$ROOT/build/MunieDeviceIdentityProbe"
printf 'Identity research executable: %s/build/MunieDeviceIdentityProbe\n' "$ROOT"
