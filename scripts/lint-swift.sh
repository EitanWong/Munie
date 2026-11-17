#!/bin/bash
# Preserve pinned upstream formatting; new Swift files keep Munie's strict formatter gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 - "$ROOT" <<'PY'
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'references/licenses/remodex-source-manifest.json').read_text())
adopted = {item['destination'] for item in manifest['files']}
paths = sorted(str(p.relative_to(root)) for p in (root / 'apps').rglob('*.swift')
               if str(p.relative_to(root)) not in adopted and 'node_modules' not in p.parts)
if not paths:
    raise SystemExit('No first-party Swift app sources found.')
subprocess.run(['xcrun', 'swift-format', 'lint', '--strict', *paths], check=True)
PY
