#!/usr/bin/env python3
"""Opt-in macOS, no-model stdio experiment against an explicitly selected native Codex."""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import selectors
import signal
import subprocess
import sys
import tempfile
import time

VERSION = 'codex-cli 0.162.1'
ZERO_ID = '00000000-0000-0000-0000-000000000000'
MAX_LINE_BYTES = 64 * 1024
MAX_STREAM_BYTES = 512 * 1024
REQUEST_SECONDS = 10
TOTAL_SECONDS = 60
CLIENT = {'name': 'munie_protocol_probe', 'version': '0.1.0'}


class ProbeError(ValueError):
    """A diagnostic written by this runner, containing no raw peer or host values."""


def require(condition, message):
    if not condition:
        raise ProbeError(message)


def strict_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result

    def invalid(value):
        raise ProbeError('Non-finite JSON number')

    def finite(value):
        number = float(value)
        require(math.isfinite(number), 'Non-finite JSON number')
        return number

    return json.loads(data.decode('utf-8'), object_pairs_hook=unique, parse_constant=invalid,
                      parse_float=finite)


def group_members(group_id):
    # On macOS, probing a just-reaped process group can return EPERM rather than ESRCH.
    # Confirm numeric membership instead of treating either permission failure or EOF as cleanup.
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,pgid='], capture_output=True,
                            text=True, check=True, timeout=2)
    return [int(parts[0]) for line in result.stdout.splitlines()
            if len(parts := line.split()) == 2 and int(parts[1]) == group_id]


class JsonLinePeer:
    """Bounded JSONL transport; never answers server requests or accepts unknown frames."""

    def __init__(self, command, cwd, environment, request_seconds=REQUEST_SECONDS,
                 total_seconds=TOTAL_SECONDS):
        self.process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        start_new_session=True)
        self.selector = selectors.DefaultSelector()
        for stream, label in ((self.process.stdout, 'stdout'), (self.process.stderr, 'stderr')):
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, label)
        self.buffer = b''
        self.totals = {'stdout': 0, 'stderr': 0}
        self.digests = {'stdout': hashlib.sha256(), 'stderr': hashlib.sha256()}
        self.deadline = time.monotonic() + total_seconds
        self.request_seconds = request_seconds
        self.notifications = []
        self.cleanup = None

    def send(self, message):
        require(time.monotonic() < self.deadline, 'Total probe deadline exceeded')
        encoded = json.dumps(message, allow_nan=False).encode('utf-8') + b'\n'
        require(len(encoded) <= 4096, 'Probe request exceeds fixed size')
        # All requests are fixed and tiny; the peer never receives user-controlled payloads.
        self.process.stdin.write(encoded)
        self.process.stdin.flush()

    def read_frame(self, deadline):
        while True:
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                require(len(line) <= MAX_LINE_BYTES, 'JSONL line limit exceeded')
                frame = strict_json(line)
                require(type(frame) is dict, 'Protocol frame must be an object')
                return frame
            require(len(self.buffer) <= MAX_LINE_BYTES, 'JSONL line limit exceeded')
            remaining = min(deadline, self.deadline) - time.monotonic()
            require(remaining > 0, 'Protocol response deadline exceeded')
            for key, _ in self.selector.select(remaining):
                data = os.read(key.fileobj.fileno(), 8192)
                if not data:
                    self.selector.unregister(key.fileobj)
                    require(key.data != 'stdout', 'Protocol stdout closed before response')
                    continue
                label = key.data
                self.totals[label] += len(data)
                self.digests[label].update(data)
                require(self.totals[label] <= MAX_STREAM_BYTES, label + ' byte limit exceeded')
                if label == 'stdout':
                    self.buffer += data

    def accept_notification(self, frame):
        require('id' not in frame, 'Unexpected server request; no approval was sent')
        require(frame.get('method') == 'remoteControl/status/changed' and
                type(frame.get('params')) is dict and
                frame['params'].get('status') == 'disabled', 'Unexpected server notification')
        self.notifications.append({'method': frame['method'], 'params': {'status': 'disabled'}})
        require(len(self.notifications) <= 4, 'Unexpected notification volume')

    def request(self, message):
        require(type(message.get('id')) is int, 'Probe request ID must be an integer')
        self.send(message)
        deadline = time.monotonic() + self.request_seconds
        while True:
            frame = self.read_frame(deadline)
            if 'method' in frame:
                # Startup includes host/installation identifiers even with an empty data directory.
                # Retain only the one needed, non-identifying value.
                self.accept_notification(frame)
                continue
            require(type(frame.get('id')) is int and frame['id'] == message['id'],
                    'Mismatched response ID')
            require(('result' in frame) != ('error' in frame), 'Ambiguous result/error response')
            if 'error' in frame:
                error = frame['error']
                require(type(error) is dict and type(error.get('code')) is int and
                        type(error.get('message')) is str, 'Invalid protocol error')
            return frame

    def drain(self, deadline):
        """After the last response, only the same bounded startup notifications may remain."""
        while True:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                require(len(line) <= MAX_LINE_BYTES, 'JSONL line limit exceeded')
                frame = strict_json(line)
                require(type(frame) is dict and 'method' in frame, 'Unexpected trailing response')
                self.accept_notification(frame)
            require(len(self.buffer) <= MAX_LINE_BYTES, 'JSONL line limit exceeded')
            if not self.selector.get_map():
                require(not self.buffer, 'Incomplete trailing JSONL frame')
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            for key, _ in self.selector.select(remaining):
                data = os.read(key.fileobj.fileno(), 8192)
                if not data:
                    self.selector.unregister(key.fileobj)
                    continue
                label = key.data
                self.totals[label] += len(data)
                self.digests[label].update(data)
                require(self.totals[label] <= MAX_STREAM_BYTES, label + ' byte limit exceeded')
                if label == 'stdout':
                    self.buffer += data

    def close(self):
        if self.cleanup is not None:
            return self.cleanup
        process = self.process
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
        failure = None
        # Drain EOF first, then terminate with bounded escalation; validation failure never skips it.
        for sig in (None, signal.SIGTERM, signal.SIGKILL):
            process.poll()
            if sig is not None:
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    if group_members(process.pid):
                        failure = failure or ProbeError('Cannot terminate probe process group')
            if failure is None:
                try:
                    self.drain(time.monotonic() + 1)
                except (ValueError, OSError, UnicodeError) as error:
                    failure = error
            try:
                process.wait(timeout=.2)
            except subprocess.TimeoutExpired:
                continue
            if not self.selector.get_map():
                if not group_members(process.pid):
                    break
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            failure = failure or ProbeError('Cannot reap probe process')
        group_gone = False
        reap_deadline = time.monotonic() + .5
        while time.monotonic() < reap_deadline:
            if not group_members(process.pid):
                group_gone = True
                break
            time.sleep(.01)
        streams_eof = not self.selector.get_map() and not self.buffer
        if not streams_eof:
            failure = failure or ProbeError('Probe streams did not reach EOF')
        for stream in (process.stdout, process.stderr):
            stream.close()
        self.selector.close()
        self.cleanup = {'exitStatus': process.returncode, 'processGroupGone': group_gone,
                        'streamsReachedEOF': streams_eof}
        require(group_gone, 'Probe process group remains after cleanup')
        if failure is not None:
            raise failure
        return self.cleanup


def sandbox_profile(fixture, protected, real_home):
    def path(value):
        return json.dumps(str(value))

    return '\n'.join([
        '(version 1)', '(allow default)', '(deny network*)', '(deny file-write*)',
        f'(allow file-write* (subpath {path(fixture)}))',
        f'(deny file-read* (subpath {path(real_home)}) (subpath {path(protected)}) '
        '(subpath "/Library/Keychains") (subpath "/etc/codex"))',
        '(deny mach-lookup)',
        '(allow mach-lookup (global-name "com.apple.cfprefsd.agent") '
        '(global-name "com.apple.cfprefsd.daemon"))',
    ])


GUARD_CODE = r'''
import ctypes, errno, json, socket, sys
from pathlib import Path
passed = []
def denied(label, action):
    try:
        action()
    except OSError as error:
        if error.errno not in (errno.EPERM, errno.EACCES):
            raise
        passed.append(label)
    else:
        raise RuntimeError('Sandbox did not deny ' + label)
denied('protected-read', lambda: Path(sys.argv[1]).read_bytes())
denied('real-home-read', lambda: list(Path(sys.argv[2]).iterdir()))
denied('outside-write', lambda: Path(sys.argv[1]).write_text('changed'))
with socket.socket() as connection:
    connection.settimeout(1)
    denied('network-connect', lambda: connection.connect(('127.0.0.1', 9)))
with socket.socket() as listener:
    denied('network-bind', lambda: listener.bind(('127.0.0.1', 0)))
lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
lookup = lib.bootstrap_look_up
lookup.argtypes = [ctypes.c_uint, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint)]
lookup.restype = ctypes.c_int
bootstrap = ctypes.c_uint.in_dll(lib, 'bootstrap_port').value
for endpoint in (b'com.apple.SecurityServer', b'com.apple.securityd.xpc', b'com.apple.securityd.general'):
    port = ctypes.c_uint()
    if lookup(bootstrap, endpoint, ctypes.byref(port)) != 1100:
        raise RuntimeError('Sandbox did not deny Keychain service lookup')
passed.append('keychain-service-lookup')
print(json.dumps(passed))
'''


def expect_error(frame, prefix):
    error = frame.get('error', {})
    require(error.get('code') == -32600 and error.get('message', '').startswith(prefix),
            'Observed error differs from fixed-version expectation')
    return {'code': error['code'], 'messagePrefix': prefix}


def experiment(binary, schema_dir, default_dir, catalog_path, report):
    report['phase'] = 'preflight'
    require(sys.platform == 'darwin', 'This opt-in experiment requires macOS sandbox-exec')
    require(binary.is_absolute() and binary.is_file() and os.access(binary, os.X_OK),
            '--codex must select an absolute executable native binary')
    require(binary.read_bytes()[:4] in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe'),
            '--codex must be native Mach-O; npm/shell wrappers are not accepted')
    spec = importlib.util.spec_from_file_location('catalog_codex', Path(__file__).with_name('catalog-codex.py'))
    catalog = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(catalog)
    snapshot = catalog.read_json(catalog_path)
    catalog.validate_snapshot(snapshot)
    generated = catalog.build_catalog(schema_dir, default_dir, VERSION)
    catalog.check_catalog(generated, snapshot)
    report['schemaBundles'] = generated['schemaBundles']
    report['binarySHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
    report['sourceRevision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'],
                                                       cwd=Path(__file__).resolve().parent.parent,
                                                       text=True).strip()
    report['workingTreeDirty'] = bool(subprocess.check_output(
        ['git', 'status', '--porcelain', '--untracked-files=normal'],
        cwd=Path(__file__).resolve().parent.parent, text=True).strip())
    report['runnerSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report['host'] = {'system': platform.system(), 'architecture': platform.machine()}
    with tempfile.TemporaryDirectory(prefix='munie-codex-probe-') as temporary:
        root = Path(temporary).resolve()
        fixture, protected = root / 'fixture', root / 'protected'
        fixture.mkdir()
        protected.mkdir()
        sentinel = protected / 'sentinel'
        sentinel.write_text('pristine')
        for name in ('codex-data', 'workspace', 'tmp'):
            (fixture / name).mkdir()
        (fixture / 'codex-data/config.toml').write_text(
            'cli_auth_credentials_store = "file"\n[analytics]\nenabled = false\n'
            '[feedback]\nenabled = false\n', encoding='utf-8')
        environment = {'PATH': '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
                       'HOME': str(Path.home()), 'CODEX_HOME': str(fixture / 'codex-data'),
                       'TMPDIR': str(fixture / 'tmp'), 'LANG': 'en_US.UTF-8'}
        profile = sandbox_profile(fixture, protected, Path.home())
        sandbox = ['/usr/bin/sandbox-exec', '-p', profile]
        report['phase'] = 'sandbox-guards'
        guard = subprocess.run(sandbox + [sys.executable, '-I', '-c', GUARD_CODE,
                                         str(sentinel), str(Path.home())],
                               cwd=fixture / 'workspace', env=environment,
                               capture_output=True, timeout=10, check=True)
        report['sandboxGuards'] = strict_json(guard.stdout)
        require(sentinel.read_text() == 'pristine', 'Sandbox guard altered protected bytes')
        report['phase'] = 'binary-version'
        version = subprocess.run(sandbox + [str(binary), '--version'], cwd=fixture / 'workspace',
                                 env=environment, capture_output=True, timeout=5, check=True)
        require(version.stdout.decode().strip() == VERSION, 'Selected Codex version does not match catalog')
        report['cliVersion'] = VERSION
        report['phase'] = 'stdio-protocol'
        peer = JsonLinePeer(sandbox + [str(binary), 'app-server', '--stdio'],
                            fixture / 'workspace', environment)
        report['checks'] = []
        nonexistent = {'threadId': ZERO_ID, 'turnId': ZERO_ID}

        def error_check(label, request_id, method, params, prefix):
            frame = peer.request({'id': request_id, 'method': method, 'params': params})
            report['checks'].append({'name': label, 'requestID': request_id, 'method': method,
                                     'error': expect_error(frame, prefix)})

        primary_error = None
        try:
            error_check('before-initialize', 1, 'turn/interrupt', nonexistent, 'Not initialized')
            frame = peer.request({'id': 2, 'method': 'initialize', 'params': {
                'clientInfo': CLIENT, 'capabilities': {'experimentalApi': False}}})
            result = frame.get('result')
            require(type(result) is dict and type(result.get('userAgent')) is str and
                    '/0.162.1 ' in result['userAgent'] and
                    result.get('codexHome') == str(fixture / 'codex-data'),
                    'Initialization did not confirm isolated data directory and version')
            report['checks'].append({'name': 'initialize', 'requestID': 2, 'method': 'initialize',
                                     'resultFields': sorted(result), 'isolatedCodexHome': True})
            peer.send({'method': 'initialized', 'params': {}})
            error_check('duplicate-initialize', 3, 'initialize', {'clientInfo': CLIENT}, 'Already initialized')
            error_check('invalid-params', 4, 'turn/interrupt', {}, 'Invalid request: missing field `threadId`')
            error_check('unknown-method', 5, 'munie/nonexistent', {}, 'Invalid request: unknown variant `munie/nonexistent`')
            error_check('nonexistent-turn', 6, 'turn/interrupt', nonexistent, 'thread not found: ' + ZERO_ID)
        except (ValueError, OSError, UnicodeError) as error:
            primary_error = error
            raise
        finally:
            try:
                peer.close()
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                if primary_error is None:
                    raise
                report['cleanupFailureType'] = type(error).__name__
            finally:
                report['cleanup'] = peer.cleanup
                report['notifications'] = peer.notifications
                report['streams'] = {name: {'bytes': peer.totals[name], 'sha256': digest.hexdigest()}
                                     for name, digest in peer.digests.items()}
        require(peer.cleanup['exitStatus'] == 0, 'Codex server exited unsuccessfully')
        report['scope'] = 'No model turn, thread creation, approval, network listener or remote adapter.'
        report['phase'] = 'complete'


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix='.codex-probe-', delete=False) as output:
            temporary = Path(output.name)
            json.dump(report, output, ensure_ascii=False, indent=2, sort_keys=True)
            output.write('\n')
        # The temporary file starts private (0600); replace also avoids following output symlinks.
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', type=Path, required=True, help='Absolute native Mach-O path; no wrapper')
    parser.add_argument('--schema-dir', type=Path, required=True)
    parser.add_argument('--default-schema-dir', type=Path, required=True)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parent.parent /
                        'references/codex-capabilities.json')
    parser.add_argument('--output', type=Path, default=Path('build/codex-protocol-probe.json'))
    args = parser.parse_args()
    report = {'reportVersion': 1, 'status': 'failed',
              'phase': 'starting', 'capturedAtUTC': datetime.now(timezone.utc).isoformat()}
    # Invalidate an older success before any child can start, including on forced termination.
    write_report(args.output, report)
    status = 1
    try:
        experiment(args.codex, args.schema_dir, args.default_schema_dir, args.catalog, report)
        report['status'] = 'passed'
        status = 0
    except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
        # Never persist raw subprocess stderr, initialization fields, hostnames or installation IDs.
        report['failureType'] = type(error).__name__
        if isinstance(error, ProbeError):
            report['failure'] = str(error)
        print('Codex stdio probe failed: ' + type(error).__name__, file=sys.stderr)
    finally:
        write_report(args.output, report)
    if status == 0:
        print('PASS isolated Codex 0.162.1 stdio: 6 protocol checks; no model task executed.')
    return status


if __name__ == '__main__':
    sys.exit(main())
