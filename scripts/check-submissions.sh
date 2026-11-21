#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
# A failed/interrupted compile must not leave the previous successful experiment as current.
rm -f build/submission-ledger-probe.json
swift build -c release --product MunieSubmissionProbe > build/submission-ledger-build.log 2>&1 || {
  cat build/submission-ledger-build.log >&2
  exit 1
}
SUBMISSION_BIN_DIRECTORY="$(swift build -c release --show-bin-path)"
python3 scripts/probe-submission-ledger.py \
  --executable "$SUBMISSION_BIN_DIRECTORY/MunieSubmissionProbe"
