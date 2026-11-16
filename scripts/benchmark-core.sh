#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
# Prevent an interrupted or failed run from presenting an older report as current.
rm -f build/core-performance.raw.json build/core-performance.json build/core-performance-run.log
swift build -c release --package-path packages/MunieCore --product MunieCoreBenchmark \
  > build/core-performance-build.log 2>&1 || {
    cat build/core-performance-build.log >&2
    exit 1
  }
BENCHMARK_BIN_DIR="$(swift build -c release --package-path packages/MunieCore --show-bin-path)"
python3 - "$BENCHMARK_BIN_DIR/MunieCoreBenchmark" <<'PYTHON'
from pathlib import Path
import subprocess
import sys

try:
    with open('build/core-performance.raw.json', 'w') as output, \
            open('build/core-performance-run.log', 'w') as errors:
        subprocess.run([sys.argv[1]], stdout=output, stderr=errors, check=True, timeout=180)
except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
    print(Path('build/core-performance-run.log').read_text(), file=sys.stderr, end='')
    sys.exit(f'Core benchmark execution failed: {error}')
PYTHON
python3 scripts/check-performance.py build/core-performance.raw.json config/performance-budgets.json \
  --capture --executable "$BENCHMARK_BIN_DIR/MunieCoreBenchmark" --output build/core-performance.json
