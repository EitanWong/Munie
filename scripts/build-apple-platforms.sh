#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Regenerate here too so direct use never builds an out-of-date project.
./scripts/bootstrap.sh
mkdir -p build

build_platform() {
  local platform="$1" scheme="$2" destination="$3" action="$4" derived_data="$5"
  local configuration="${6:-Debug}"
  local log="build/$platform-build.log"
  printf 'Building %s %s (%s)\n' "$platform" "$configuration" "$destination"
  xcodebuild -project Munie.xcodeproj -scheme "$scheme" -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$derived_data" \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO "$action" > "$log" 2>&1 || {
    tail -80 "$log"
    return 1
  }
  printf 'PASS %s: %s\n' "$platform" "$log"
}

# iPadOS shares the iOS target and device family; iOS also compiles both test bundles.
build_platform ios Munie 'generic/platform=iOS Simulator' build-for-testing build/DerivedData
build_platform macos Munie 'generic/platform=macOS' build build/DerivedData-macos
build_platform macos-host MunieHost 'generic/platform=macOS' build build/DerivedData-host
build_platform tvos Munie 'generic/platform=tvOS Simulator' build build/DerivedData-tvos
build_platform visionos Munie 'generic/platform=visionOS Simulator' build build/DerivedData-visionos
build_platform watchos MunieWatch 'generic/platform=watchOS Simulator' build build/DerivedData-watchos
# Exercise optimized shipping code before signing or distribution is configured.
build_platform ios-release Munie 'generic/platform=iOS' build build/DerivedData-ios-release Release
build_platform remodex-ios MunieRemodex 'generic/platform=iOS Simulator' build-for-testing build/DerivedData-remodex
build_platform remodex-ios-release MunieRemodex 'generic/platform=iOS' build build/DerivedData-remodex-release Release
printf 'All Apple platform builds passed. Hardware and signed distribution remain separate acceptance.\n'
