#!/usr/bin/env node
// Munie addition: foreground fork entry; retains private pairing/status for the owner and tests.
const { startBridge, readBridgeConfig } = require("../src");
const { writePairingSession, writeBridgeStatus } = require("../src/daemon-state");
if (!process.env.REMODEX_CODEX_BINARY || !process.env.REMODEX_PROJECT_ROOT) {
  console.error("Use scripts/run-remodex-local.sh with explicit --codex and --project inputs.");
  process.exit(1);
}
startBridge({ config: readBridgeConfig(), onPairingSession: writePairingSession, onBridgeStatus: writeBridgeStatus });
