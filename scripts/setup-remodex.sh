#!/bin/bash
# Install the pinned fork's JavaScript dependencies. Never runs lifecycle/Codex bootstrap scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v node >/dev/null
command -v npm >/dev/null
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Node.js 22 or newer is required."); process.exit(1); }'
mkdir -p "$ROOT/build/remodex-tools"
xcrun clang -Wall -Wextra -Werror -O2 "$ROOT/apps/MunieHost/Guardian/main.c" \
  -o "$ROOT/build/remodex-tools/MunieCodexGuardian"
for PACKAGE in MunieRemodexBridge MunieRemodexRelay; do
  npm --prefix "$ROOT/apps/$PACKAGE" ci --ignore-scripts --no-audit --no-fund
done
printf 'Remodex dependencies installed without lifecycle scripts. No bridge, relay, or model was started.\n'
