#!/bin/bash
# Owner-invoked macOS user service for Tailscale Serve, without changing system DNS or routes.
set -euo pipefail
MUNIE_NETWORK_DIRECTORY="$HOME/Library/Application Support/MunieNetwork"
MUNIE_NETWORK_PLIST="$HOME/Library/LaunchAgents/app.munie.private-network.plist"
MUNIE_DAEMON="$(command -v tailscaled)"
if launchctl print "gui/$(id -u)/app.munie.private-network" >/dev/null 2>&1; then
  printf 'Munie private network service is already loaded.\n'
  exit 0
fi
mkdir -p "$MUNIE_NETWORK_DIRECTORY" "$HOME/Library/LaunchAgents"
chmod 700 "$MUNIE_NETWORK_DIRECTORY"
python3 - "$MUNIE_NETWORK_PLIST" "$MUNIE_DAEMON" "$MUNIE_NETWORK_DIRECTORY" <<'PY'
import pathlib,plistlib,sys
file,daemon,directory=map(pathlib.Path,sys.argv[1:])
content={'Label':'app.munie.private-network','ProgramArguments':[str(daemon),
 '--tun=userspace-networking','--no-logs-no-support','--statedir='+str(directory),
 '--socket='+str(directory/'tailscaled.sock')],'RunAtLoad':True,'KeepAlive':True,
 'StandardOutPath':str(directory/'service.log'),'StandardErrorPath':str(directory/'service.log')}
encoded=plistlib.dumps(content)
if file.exists() and file.read_bytes()!=encoded:
 raise SystemExit('Existing network LaunchAgent differs; preserve it and review before changing.')
file.write_bytes(encoded);file.chmod(0o600)
PY
launchctl bootstrap "gui/$(id -u)" "$MUNIE_NETWORK_PLIST"
printf 'Started user service. Login and HTTPS enablement are separate owner actions.\n'
printf 'To stop: launchctl bootout gui/%s/app.munie.private-network\n' "$(id -u)"
