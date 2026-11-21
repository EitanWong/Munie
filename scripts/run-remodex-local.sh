#!/bin/bash
# Explicit foreground start only. Does not configure Tailscale, install launchd, or submit a model turn.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

root = Path(sys.argv[1])
parser = argparse.ArgumentParser(description='Run the imported Remodex relay and bridge explicitly in the foreground.')
parser.add_argument('--codex', type=Path, required=True, help='Absolute path of the approved Codex executable; no PATH fallback.')
parser.add_argument('--project', type=Path, required=True, help='Explicit existing project directory authorized for this launch.')
parser.add_argument('--relay-port', type=int, default=9275)
parser.add_argument('--advertise-relay', help='Phone-reachable ws(s) relay URL; a bare host URL receives /relay.')
parser.add_argument('--state-dir', type=Path, help='Private persistent state directory; defaults to a fresh ignored build directory.')
parser.add_argument('--codex-home', type=Path, help='Explicit Codex home; otherwise a fresh private home without imported credentials.')
args = parser.parse_args(sys.argv[2:])
if not 1024 <= args.relay_port <= 65535 or args.relay_port == 9274:
    parser.error('--relay-port must be 1024..65535 and must preserve the existing service on 9274.')
if not args.codex.is_absolute() or not args.project.is_absolute():
    parser.error('--codex and --project must be absolute paths.')
try:
    codex = args.codex.resolve(strict=True)
    project = args.project.resolve(strict=True)
except OSError as error:
    parser.error(str(error))
if not codex.is_file() or not os.access(codex, os.X_OK) or not project.is_dir():
    parser.error('--codex must be executable and --project must be a directory.')
if project == Path(project.anchor) or project == Path.home():
    parser.error('Authorize a project directory rather than the filesystem root or entire home.')
from urllib.parse import urlsplit, urlunsplit
advertised = args.advertise_relay or 'ws://127.0.0.1:' + str(args.relay_port)
parts = urlsplit(advertised)
if parts.scheme not in ('ws', 'wss') or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
    parser.error('--advertise-relay must be a ws(s) URL without credentials, query, or fragment.')
path = parts.path.rstrip('/') or '/relay'
if not path.endswith('/relay'):
    parser.error('--advertise-relay path must end with /relay.')
advertised = urlunsplit((parts.scheme, parts.netloc, path, '', ''))
node = shutil.which('node')
if not node:
    parser.error('Node.js is required; run scripts/setup-remodex.sh first.')
guardian = root / 'build/remodex-tools/MunieCodexGuardian'
if not guardian.is_file() or not os.access(guardian, os.X_OK):
    parser.error('The existing native owner guardian is required; run scripts/setup-remodex.sh first.')
for package in ('MunieRemodexBridge', 'MunieRemodexRelay'):
    if not (root / 'apps' / package / 'node_modules/ws/package.json').is_file():
        parser.error('Missing locked dependencies; run scripts/setup-remodex.sh first.')
probe = socket.socket()
try:
    probe.bind(('127.0.0.1', args.relay_port))
except OSError:
    parser.error('The chosen loopback relay port is already in use; existing services are preserved.')
finally:
    probe.close()
os.umask(0o077)
if args.state_dir:
    state = args.state_dir.expanduser().resolve()
    state.mkdir(parents=True, mode=0o700, exist_ok=True)
else:
    build = root / 'build'
    build.mkdir(exist_ok=True)
    state = Path(tempfile.mkdtemp(prefix='remodex-local-', dir=build)).resolve()
if state.stat().st_uid != os.getuid() or state.stat().st_mode & 0o077:
    parser.error('--state-dir must be owned by the current user with mode 0700.')
codex_home = args.codex_home.expanduser().resolve() if args.codex_home else state / 'codex-home'
codex_home.mkdir(parents=True, mode=0o700, exist_ok=True)
if codex_home.stat().st_uid != os.getuid() or codex_home.stat().st_mode & 0o077:
    parser.error('--codex-home must be private and owned by the current user.')
environment = {key: value for key, value in os.environ.items()
               if not key.startswith(('REMODEX_', 'PHODEX_', 'MUNIE_'))
               and key not in ('NODE_OPTIONS', 'NODE_PATH', 'OPENAI_API_KEY', 'CODEX_HOME')}
environment.update({'REMODEX_RELAY': 'ws://127.0.0.1:' + str(args.relay_port) + '/relay',
    'REMODEX_PUBLIC_RELAY': advertised, 'REMODEX_CODEX_BINARY': str(codex),
    'REMODEX_PROJECT_ROOT': str(project), 'REMODEX_DEVICE_STATE_DIR': str(state / 'device'),
    'REMODEX_DISABLE_KEYCHAIN': '1', 'REMODEX_SKIP_CODEX_BOOTSTRAP': '1',
    'REMODEX_DESKTOP_IPC_LIVE_SYNC': 'false', 'REMODEX_REFRESH_ENABLED': 'false',
    'REMODEX_DESKTOP_AUTO_FOLLOW': 'false', 'REMODEX_KEEP_MAC_AWAKE': 'false',
    'REMODEX_PUSH_SERVICE_URL': '', 'REMODEX_ENABLE_PUSH_SERVICE': 'false',
    'RELAY_BIND_HOST': '127.0.0.1', 'PORT': str(args.relay_port), 'CODEX_HOME': str(codex_home)})
report = {'schemaVersion': 1, 'status': 'starting', 'project': str(project), 'codex': str(codex),
    'codexSHA256': hashlib.sha256(codex.read_bytes()).hexdigest(), 'codexHome': str(codex_home),
    'connectRelay': environment['REMODEX_RELAY'], 'advertiseRelay': advertised, 'processes': [],
    'guardian': str(guardian), 'guardianSHA256': hashlib.sha256(guardian.read_bytes()).hexdigest(),
    'ownerPID': os.getpid(),
    'scope': 'Imported Remodex foreground runtime; no task is submitted. Guardian covers its owned groups, not escaped descendants.'}
evidence = state / 'runs' / uuid.uuid4().hex
evidence.mkdir(parents=True, mode=0o700)
report['evidenceDirectory'] = str(evidence)
report_path = state / 'run.json'

def save():
    temporary = state / '.run.json.tmp'
    temporary.write_text(json.dumps(report, indent=2) + '\n')
    os.replace(temporary, report_path)
    (evidence / 'run.json').write_text(json.dumps(report, indent=2) + '\n')

processes = []
outputs = []
interrupted = False

def stopping(signum, frame):
    global interrupted
    interrupted = True

for requested in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(requested, stopping)

def group_gone(pid, errors, killpg=os.killpg):
    try:
        killpg(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError as error:
        # Darwin can return EPERM while an owned group is exiting but not yet reaped.
        # Preserve this evidence and keep polling; only ESRCH proves disappearance.
        if not any(item.get('operation') == 'probe' and item.get('errno') == error.errno for item in errors):
            errors.append({'operation': 'probe', 'errno': error.errno})
        return False


def stop_owned_group(child, record, *, killpg=os.killpg, monotonic=time.monotonic, pause=time.sleep):
    errors = record.setdefault('cleanupErrors', [])
    for requested in (signal.SIGTERM, signal.SIGKILL):
        child.poll()
        if group_gone(child.pid, errors, killpg):
            break
        try:
            killpg(child.pid, requested)
        except ProcessLookupError:
            break
        except PermissionError as error:
            errors.append({'operation': 'signal', 'signal': int(requested), 'errno': error.errno})
        deadline = monotonic() + 5
        while monotonic() < deadline:
            child.poll()
            if group_gone(child.pid, errors, killpg):
                break
            pause(0.02)
        else:
            continue
        break
    record['exitStatus'] = child.poll()
    record['processGroupGone'] = group_gone(child.pid, errors, killpg)


try:
    for name, entry in (('relay', root / 'apps/MunieRemodexRelay/server.js'),
                        ('bridge', root / 'apps/MunieRemodexBridge/bin/munie-local.js')):
        if interrupted:
            break
        output = (evidence / (name + '.log')).open('xb')
        outputs.append(output)
        command = [str(guardian), str(os.getpid()), node, str(entry)]
        child = subprocess.Popen(command, cwd=project, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        processes.append(child)
        report['processes'].append({'name': name, 'pid': child.pid, 'command': command, 'log': str(output.name)})
        save()
        if name == 'relay':
            deadline = time.monotonic() + 10
            while not interrupted and time.monotonic() < deadline:
                if child.poll() is not None:
                    raise RuntimeError('Relay exited before readiness.')
                try:
                    with urllib.request.urlopen('http://127.0.0.1:' + str(args.relay_port) + '/health', timeout=1) as response:
                        if json.load(response) == {'ok': True}:
                            break
                except (OSError, ValueError):
                    pass
                time.sleep(0.1)
            else:
                if not interrupted:
                    raise RuntimeError('Relay readiness exceeded 10 seconds.')
    if not interrupted:
        deadline = time.monotonic() + 10
        while not interrupted and time.monotonic() < deadline:
            if any(child.poll() is not None for child in processes):
                raise RuntimeError('Bridge or relay exited before pairing readiness.')
            try:
                bridge_status = json.loads((state / 'device/bridge-status.json').read_text())
                if (bridge_status.get('connectionStatus') == 'connected'
                        and bridge_status.get('codexLaunchState') == 'connected'
                        and (state / 'device/pairing-session.json').is_file()):
                    break
            except (OSError, ValueError):
                pass
            time.sleep(0.1)
        else:
            if not interrupted:
                raise RuntimeError('Bridge pairing readiness exceeded 10 seconds.')
    if not interrupted:
        report['status'] = 'running'
        save()
        print('Remodex started; no model task submitted. Report: ' + str(report_path), flush=True)
        print('Phone relay: ' + advertised, flush=True)
        print('Pairing QR: ' + str(evidence / 'bridge.log'), flush=True)
    while not interrupted:
        for child in processes:
            if child.poll() is not None:
                raise RuntimeError('A foreground service exited; inspect retained logs.')
        time.sleep(0.2)
except (OSError, RuntimeError) as error:
    report['status'] = 'failed'
    report['failure'] = str(error)
    print(str(error), file=sys.stderr)
finally:
    for child, record in reversed(list(zip(processes, report['processes']))):
        try:
            stop_owned_group(child, record)
        except OSError as error:
            record.setdefault('cleanupErrors', []).append({'operation': 'cleanup', 'errno': error.errno})
            record['processGroupGone'] = False
            record['exitStatus'] = child.poll()
        if not record['processGroupGone']:
            report['status'] = 'failed'
            report['cleanupFailure'] = 'Owned process group cleanup failed.'
    for output in outputs:
        output.close()
    if report['status'] != 'failed':
        report['status'] = 'stopped'
    save()
sys.exit(1 if report['status'] == 'failed' else 0)
PY
