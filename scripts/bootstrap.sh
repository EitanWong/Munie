#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
command -v xcodebuild >/dev/null
command -v python3 >/dev/null
TOOLS="$ROOT/.tools"
VERSION=2.46.0
CHECKSUM=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
BINARY="$TOOLS/xcodegen/bin/xcodegen"
if [ ! -x "$BINARY" ]; then
  mkdir -p "$TOOLS"
  STAGING="$(mktemp -d "$TOOLS/install.XXXXXX")"
  trap 'rm -rf "$STAGING"' EXIT
  curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip" \
    --output "$STAGING/xcodegen.zip"
  printf '%s  %s\n' "$CHECKSUM" "$STAGING/xcodegen.zip" | shasum -a 256 -c -
  unzip -q "$STAGING/xcodegen.zip" -d "$STAGING"
  mv "$STAGING/xcodegen" "$TOOLS/xcodegen"
fi
"$BINARY" --version | grep -F "Version: $VERSION"
ACTIONLINT_VERSION=1.7.12
case "$(uname -m)" in
  arm64)
    ARCH=arm64
    ACTIONLINT_SHA=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    ;;
  x86_64)
    ARCH=amd64
    ACTIONLINT_SHA=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
    ;;
  *) printf 'Unsupported macOS architecture.\n' >&2; exit 1 ;;
esac
if [ ! -x "$TOOLS/actionlint" ]; then
  ACTION_STAGING="$(mktemp -d "$TOOLS/actionlint.XXXXXX")"
  trap 'rm -rf "${STAGING:-}" "$ACTION_STAGING"' EXIT
  curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_darwin_$ARCH.tar.gz" \
    --output "$ACTION_STAGING/actionlint.tar.gz"
  printf '%s  %s\n' "$ACTIONLINT_SHA" "$ACTION_STAGING/actionlint.tar.gz" | shasum -a 256 -c -
  tar -xzf "$ACTION_STAGING/actionlint.tar.gz" -C "$ACTION_STAGING" actionlint
  mv "$ACTION_STAGING/actionlint" "$TOOLS/actionlint"
fi
"$TOOLS/actionlint" -version | head -1 | grep -Fx "$ACTIONLINT_VERSION"
if [ ! -f config/Signing.xcconfig ]; then
  cp config/Signing.xcconfig.example config/Signing.xcconfig
fi
"$BINARY" generate --spec project.yml
printf 'Open %s/Munie.xcodeproj\n' "$ROOT"
