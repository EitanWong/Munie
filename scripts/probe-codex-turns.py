#!/usr/bin/env python3
"""Opt-in native Codex lifecycle research with a deterministic loopback model fixture.

Runs actual app-server threads/turns/tools; the Responses API provider is synthetic.
No personal credentials, real model, external network, mobile gateway or product adapter.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

SPEC = importlib.util.spec_from_file_location('munie_codex_probe',
                                            Path(__file__).with_name('probe-codex.py'))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
require = probe.require
MODEL = 'munie-fixture'
MARKER = 'MUNIE_FIXTURE_COMPLETE'
PROVIDER_KEY_ENV = 'MUNIE_FIXTURE_PROVIDER_TOKEN'
APPROVAL_COMMAND = '/usr/bin/touch approval-marker'
MAX_REQUEST = 256 * 1024
KEY_GUARD_SCRIPT = 'provider-key-guard.sh'
CASES = ('text', 'approval-cancel', 'approval-accept', 'interrupt')
EVENTS = frozenset((
    'thread/started', 'thread/status/changed', 'warning', 'turn/started', 'turn/completed',
    'item/started', 'item/completed', 'thread/tokenUsage/updated', 'account/rateLimits/updated',
    'item/commandExecution/outputDelta', 'item/agentMessage/delta', 'serverRequest/resolved',
    'thread/goal/cleared',
))


def native_id(value):
    require(type(value) is str and len(value) == 36, 'Invalid native fixture identity')
    require(str(uuid.UUID(value)) == value, 'Invalid native fixture identity')
    return value


def sse(item, response_id):
    """Responses API test data, not generated model output."""
    events = [
        {'type': 'response.created', 'response': {'id': response_id}},
        {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
        {'type': 'response.completed', 'response': {
            'id': response_id, 'status': 'completed', 'output': [item],
            'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}},
    ]
    return ''.join('data: ' + json.dumps(event) + '\n\n' for event in events).encode()


class FixtureServer(http.server.HTTPServer):
    """One bounded, loopback-only HTTP/1.0 fixture, never a public/model service."""

    def __init__(self, workspace, synthetic_key=None):
        self.workspace = workspace
        self.synthetic_key = synthetic_key
        self.command = fixture_command(synthetic_key is not None)
        self.path = '/fixture-' + secrets.token_hex(24) + '/responses'
        self.case = None
        self.count = 0
        self.total = 0
        self.connections = 0
        self.active_socket = None
        self.failure = None
        self.started = threading.Event()
        self.release = threading.Event()
        self.stopping = threading.Event()
        self.lock = threading.Lock()
        super().__init__(('127.0.0.1', 0), FixtureHandler)
        self.thread = threading.Thread(target=self.serve_forever, kwargs={'poll_interval': .05},
                                       daemon=True)
        self.thread.start()

    def select(self, case):
        require(case in CASES, 'Unknown fixture scenario')
        with self.lock:
            self.case, self.count = case, 0
            self.started.clear()
            self.release.clear()

    def check(self, expected):
        require(self.failure is None, 'Loopback provider rejected a request')
        require(self.count == expected, 'Unexpected provider request count')

    def close(self):
        self.stopping.set()
        self.release.set()
        # socket timeouts alone permit a client to drip bytes forever. Force the active read
        # to end before shutdown waits for this single handler; reject races in get_request.
        with self.lock:
            if self.active_socket is not None:
                try:
                    self.active_socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                self.active_socket.close()
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=3)
        require(not self.thread.is_alive(), 'Loopback fixture thread remains')

    def get_request(self):
        connection, address = super().get_request()
        with self.lock:
            if self.stopping.is_set():
                connection.close()
                raise OSError('Fixture is stopping')
            self.connections += 1
            self.active_socket = connection
        return connection, address

    def handle_error(self, request, address):
        # BaseServer otherwise prints a raw request traceback and paths to stderr.
        self.failure = 'handler-failure'


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(2)

    def do_POST(self):
        server = self.server
        try:
            require(self.path == server.path and self.client_address[0] == '127.0.0.1',
                    'Invalid fixture endpoint')
            expected = None if server.synthetic_key is None else ['Bearer ' + server.synthetic_key]
            require(self.headers.get_all('Authorization') == expected and
                    self.headers.get_all('Cookie') is None,
                    'Unexpected fixture authentication')
            require(self.headers.get_all('Transfer-Encoding') is None,
                    'Chunked requests are forbidden')
            require(len(self.headers.get_all('Content-Length', [])) == 1,
                    'Exactly one content length is required')
            length = int(self.headers.get('Content-Length', '0'))
            require(0 < length <= MAX_REQUEST, 'Provider request size limit exceeded')
            data = self.rfile.read(length)
            require(len(data) == length, 'Truncated provider request')
            if server.synthetic_key is not None:
                require(server.synthetic_key.encode('ascii') not in data,
                        'Provider key reached the request body')
            body = probe.strict_json(data)
            require(type(body) is dict and body.get('model') == MODEL and
                    body.get('stream') is True and type(body.get('input')) is list,
                    'Unexpected provider request shape')
            with server.lock:
                case = server.case
                server.count += 1
                server.total += 1
                count = server.count
                require(case in CASES and count <= (2 if case == 'approval-accept' else 1)
                        and server.total <= 6, 'Unexpected provider retry or scenario')
            if case in ('approval-cancel', 'approval-accept') and count == 1:
                require(any(tool.get('name') == 'exec_command' for tool in body.get('tools', [])),
                        'Native command tool is unavailable')
                item = {'type': 'function_call', 'id': 'fc_' + case, 'call_id': 'call_' + case,
                        'name': 'exec_command', 'arguments': json.dumps({
                            'cmd': server.command, 'shell': '/bin/sh',
                            'login': False, 'workdir': str(server.workspace),
                            'yield_time_ms': 1000, 'max_output_tokens': 1000,
                            'sandbox_permissions': 'require_escalated',
                            'justification': 'Munie synthetic fixture approval'})}
            else:
                if case == 'approval-accept':
                    require(any(item.get('type') == 'function_call_output' and
                                item.get('call_id') == 'call_approval-accept' and
                                type(item.get('output')) is str and bool(item['output'])
                                for item in body['input']), 'Missing actual command result')
                item = {'type': 'message', 'id': 'msg_' + case, 'role': 'assistant',
                        'status': 'completed', 'content': [
                            {'type': 'output_text', 'text': MARKER, 'annotations': []}]}
            data = sse(item, 'resp_' + case + '_' + str(count))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            if case == 'interrupt':
                # Prove cancellation while an actual provider response is pending, without sleeps.
                self.wfile.write(b': fixture waiting\n\n')
                self.wfile.flush()
                server.started.set()
                require(server.release.wait(10), 'Provider interrupt scenario timed out')
                return
            self.wfile.write(data)
            self.wfile.flush()
        except (ValueError, OSError, UnicodeError, TypeError, KeyError):
            server.failure = 'request-rejected'
            self.close_connection = True


def fixture_command(check_key_environment):
    return '/bin/sh ' + KEY_GUARD_SCRIPT if check_key_environment else APPROVAL_COMMAND


def key_guard_source():
    # Test presence, not value. A rejected launch must not log the synthetic key.
    return f'[ -z "${{{PROVIDER_KEY_ENV}+set}}" ] || exit 87\n{APPROVAL_COMMAND}\n'


class LifecyclePeer(probe.JsonLinePeer):
    """Validate native identities and state before replying to a single fixed approval."""

    def __init__(self, command, cwd, environment, check_key_environment=False):
        super().__init__(command, cwd, environment, total_seconds=60)
        self.workspace = cwd
        self.approval_command = fixture_command(check_key_environment)
        self.synthetic_key = environment.get(PROVIDER_KEY_ENV) if check_key_environment else None
        self.thread_id = None
        self.turn_id = None
        self.case = None
        self.approval = None
        self.approval_replied = False
        self.resolved = False
        self.terminal = None
        self.command_result = None
        self.message = None
        self.events = []
        self.request_id = 0

    def rpc(self, method, params):
        self.request_id += 1
        frame = self.request({'id': self.request_id, 'method': method, 'params': params})
        require('result' in frame and type(frame['result']) is dict,
                'Native lifecycle RPC failed')
        return frame['result']

    def read_frame(self, deadline):
        frame = super().read_frame(deadline)
        self.reject_key_in_frame(frame)
        return frame

    def reject_key_in_frame(self, frame):
        if self.synthetic_key is not None:
            require(self.synthetic_key not in json.dumps(frame),
                    'Provider key reached native protocol output')

    def accept_notification(self, frame):
        # The final drain dispatches notifications without going through read_frame.
        self.reject_key_in_frame(frame)
        method, params = frame.get('method'), frame.get('params')
        require(type(params) is dict, 'Invalid native event parameters')
        if method == 'remoteControl/status/changed':
            return super().accept_notification(frame)
        require(len(self.events) < 300, 'Native lifecycle event limit exceeded')
        if 'id' in frame:
            require(method == 'item/commandExecution/requestApproval' and
                    self.case in ('approval-cancel', 'approval-accept') and
                    self.approval is None and type(frame['id']) in (int, str),
                    'Unexpected server request; no response was sent')
            require(params.get('threadId') == self.thread_id and
                    params.get('turnId') == self.turn_id and
                    params.get('itemId') == 'call_' + self.case and
                    params.get('command') == "/bin/sh -c '" + self.approval_command + "'" and
                    params.get('cwd') == str(self.workspace) and
                    params.get('kind') == 'command' and
                    params.get('reason') == 'Munie synthetic fixture approval' and
                    params.get('availableDecisions') == [
                        'accept', {'acceptWithExecpolicyAmendment': {
                            'execpolicy_amendment': self.approval_command.split(' ')}}, 'cancel'],
                    'Approval differs from the bound fixture action')
            self.approval = frame['id']
        else:
            require(method in EVENTS, 'Unexpected native lifecycle notification')
            if method == 'thread/started':
                thread = params.get('thread', {})
                require(thread.get('id') == self.thread_id and
                        thread.get('cwd') == str(self.workspace), 'Thread event target mismatch')
            elif method != 'account/rateLimits/updated':
                require(params.get('threadId') == self.thread_id, 'Event thread mismatch')
            if method in ('turn/started', 'turn/completed'):
                turn = params.get('turn', {})
                require(turn.get('id') == self.turn_id, 'Event turn mismatch')
                if method == 'turn/completed':
                    require(self.terminal is None and turn.get('status') in
                            ('completed', 'interrupted', 'failed'), 'Invalid/duplicate terminal event')
                    self.terminal = turn['status']
            elif method.startswith('item/'):
                require(params.get('turnId') == self.turn_id, 'Item turn mismatch')
                item = params.get('item', {})
                if method == 'item/completed' and item.get('type') == 'commandExecution':
                    require(item.get('id') == 'call_' + self.case, 'Command item mismatch')
                    self.command_result = (item.get('status'), item.get('exitCode'))
                if method == 'item/completed' and item.get('type') == 'agentMessage':
                    require(item.get('text') == MARKER, 'Synthetic final marker mismatch')
                    self.message = True
            elif method == 'serverRequest/resolved':
                require(self.approval is not None and
                        type(params.get('requestId')) is type(self.approval) and
                        params.get('requestId') == self.approval,
                        'Resolved approval identity mismatch')
                self.resolved = True
            elif method == 'warning':
                require(params.get('message') == 'Model metadata for `munie-fixture` not found. '
                        'Defaulting to fallback metadata; this can degrade performance and cause issues.',
                        'Unexpected warning')
        # Preserve order, types and binding checks, never raw paths, text, host or account metadata.
        self.events.append({'method': method, 'case': self.case})

    def respond_approval(self, decision):
        expected = {'approval-cancel': 'cancel', 'approval-accept': 'accept'}.get(self.case)
        require(self.approval is not None and not self.approval_replied and self.terminal is None and
                decision == expected, 'Invalid, stale or duplicate fixture approval response')
        self.send({'id': self.approval, 'result': {'decision': decision}})
        self.approval_replied = True

    def wait_for(self, predicate):
        deadline = time.monotonic() + 10
        while not predicate():
            self.accept_notification(self.read_frame(deadline))

    def initialize(self, home):
        result = self.rpc('initialize', {'clientInfo': probe.CLIENT,
                                       'capabilities': {'experimentalApi': False}})
        require(result.get('codexHome') == str(home), 'Unexpected Codex data directory')
        self.send({'method': 'initialized', 'params': {}})

    def start(self, case):
        self.case = case
        self.turn_id = self.approval = self.terminal = self.command_result = self.message = None
        self.resolved = False
        # The thread/start response precedes its thread/started event in this pinned protocol.
        result = self.rpc('thread/start', {
            'model': MODEL, 'modelProvider': 'munie_fixture', 'cwd': str(self.workspace),
            'approvalPolicy': 'on-request', 'sandbox': 'read-only', 'ephemeral': False})
        thread = result.get('thread', {})
        require(type(thread.get('id')) is str and thread.get('cwd') == str(self.workspace),
                'Native thread did not bind the synthetic workspace')
        self.thread_id = native_id(thread['id'])
        self.start_turn(case)

    def start_turn(self, case):
        self.case = case
        self.turn_id = self.approval = self.terminal = self.command_result = self.message = None
        self.resolved = False
        self.approval_replied = False
        result = self.rpc('turn/start', {'threadId': self.thread_id, 'input': [
            {'type': 'text', 'text': 'Execute the Munie synthetic protocol fixture: ' + case}]})
        turn = result.get('turn', {})
        require(type(turn.get('id')) is str and turn.get('status') == 'inProgress',
                'Turn acknowledgment is not inProgress')
        self.turn_id = native_id(turn['id'])


def experiment(args, report):
    probe.validate_inputs(args.codex, args.schema_dir, args.default_schema_dir, args.catalog, report)
    report['runnerSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report['transportRunnerSHA256'] = hashlib.sha256(Path(probe.__file__).read_bytes()).hexdigest()
    report['scope'] = ('Actual native Codex lifecycle with synthetic local Responses API output; '
                       'no real model, user credentials, external network, mobile gateway or adapter.')
    with tempfile.TemporaryDirectory(prefix='munie-codex-turns-') as temporary:
        root = Path(temporary).resolve()
        fixture, protected = root / 'fixture', root / 'protected'
        fixture.mkdir()
        protected.mkdir()
        sentinel = protected / 'sentinel'
        sentinel.write_text('pristine')
        for name in ('codex-data', 'workspace', 'tmp'):
            (fixture / name).mkdir()
        workspace, home = fixture / 'workspace', fixture / 'codex-data'
        synthetic_key = secrets.token_hex(32) if args.synthetic_provider_key else None
        if synthetic_key is not None:
            (workspace / KEY_GUARD_SCRIPT).write_text(key_guard_source(), encoding='utf-8')
        provider = FixtureServer(workspace, synthetic_key=synthetic_key)
        peers = []
        report['checks'] = []
        try:
            port = provider.server_port
            (home / 'config.toml').write_text(
                f'model = "{MODEL}"\nmodel_provider = "munie_fixture"\n'
                'cli_auth_credentials_store = "file"\n[shell_environment_policy]\ninherit = "none"\n'
                '[model_providers.munie_fixture]\nname = "Munie deterministic fixture"\n'
                f'base_url = "http://127.0.0.1:{port}{provider.path.removesuffix("/responses")}"\n'
                'wire_api = "responses"\nrequires_openai_auth = false\n'
                + (f'env_key = "{PROVIDER_KEY_ENV}"\n' if synthetic_key is not None else '') +
                'request_max_retries = 0\nstream_max_retries = 0\n'
                '[analytics]\nenabled = false\n[feedback]\nenabled = false\n')
            environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()),
                           'CODEX_HOME': str(home), 'TMPDIR': str(fixture / 'tmp'),
                           'LANG': 'en_US.UTF-8'}
            # Seatbelt accepts localhost here; numeric host:port is rejected by its parser.
            profile = probe.sandbox_profile(fixture, protected, Path.home()) + (
                f'\n(allow network-outbound (remote ip "localhost:{port}"))')
            sandbox = ['/usr/bin/sandbox-exec', '-p', profile]
            report['phase'] = 'sandbox-guards'
            guard = subprocess.run(sandbox + [sys.executable, '-I', '-c', probe.GUARD_CODE,
                                             str(sentinel), str(Path.home())],
                                   cwd=workspace, env=environment, capture_output=True,
                                   timeout=10, check=True)
            report['sandboxGuards'] = probe.strict_json(guard.stdout)
            require(sentinel.read_text() == 'pristine', 'Sandbox guard changed protected bytes')
            version = subprocess.run(sandbox + [str(args.codex), '--version'], cwd=workspace,
                                     env=environment, capture_output=True, timeout=5, check=True)
            require(version.stdout.decode().strip() == probe.VERSION, 'Native version mismatch')
            report['cliVersion'] = probe.VERSION
            if synthetic_key is not None:
                environment[PROVIDER_KEY_ENV] = synthetic_key
            command = sandbox + [str(args.codex), 'app-server', '--stdio']
            report['phase'] = 'native-lifecycle'
            peer = LifecyclePeer(command, workspace, environment, synthetic_key is not None)
            peers.append(peer)
            peer.initialize(home)
            marker = workspace / 'approval-marker'
            history = []
            for case in CASES:
                require(not marker.exists(), 'Unexpected fixture side effect before submission')
                provider.select(case)
                peer.start(case)
                if case in ('approval-cancel', 'approval-accept'):
                    peer.wait_for(lambda: peer.approval is not None)
                    require(not marker.exists(), 'Command ran before approval')
                    decision = 'cancel' if case == 'approval-cancel' else 'accept'
                    peer.respond_approval(decision)
                elif case == 'interrupt':
                    require(provider.started.wait(5), 'Provider did not receive the interrupt turn')
                    # Empty RPC result is just acknowledgement; wait for a matching terminal below.
                    peer.rpc('turn/interrupt', {'threadId': peer.thread_id, 'turnId': peer.turn_id})
                peer.wait_for(lambda: peer.terminal is not None)
                provider.release.set()
                expected = 'interrupted' if case in ('approval-cancel', 'interrupt') else 'completed'
                require(peer.terminal == expected, 'Unexpected native terminal state')
                require(marker.exists() == (case == 'approval-accept'), 'Approval side effect mismatch')
                if case in ('approval-cancel', 'approval-accept'):
                    require(peer.resolved, 'Native approval was not resolved')
                if case == 'approval-accept':
                    require(peer.command_result == ('completed', 0) and
                            type(peer.command_result[1]) is int, 'Actual tool did not succeed')
                    marker.unlink()
                if expected == 'completed':
                    require(peer.message is True, 'Missing completed synthetic assistant item')
                provider.check(2 if case == 'approval-accept' else 1)
                history.append((peer.thread_id, peer.turn_id, expected))
                report['checks'].append({'name': case, 'acknowledged': 'inProgress',
                                         'terminal': peer.terminal, 'targetBindingsChecked': True,
                                         'threadID': peer.thread_id, 'turnID': peer.turn_id,
                                         'approvalResolved': peer.resolved,
                                         'markerCreated': case == 'approval-accept',
                                         'providerRequests': provider.count})
            # Reopen persisted threads on a fresh process/transport, not the live in-memory session.
            peer.close()
            require(peer.cleanup['exitStatus'] == 0, 'Native lifecycle server exited unsuccessfully')
            report['phase'] = 'persisted-history'
            resumed = LifecyclePeer(command, workspace, environment, synthetic_key is not None)
            peers.append(resumed)
            resumed.initialize(home)
            for thread_id, turn_id, status in history:
                resumed.thread_id = thread_id
                result = resumed.rpc('thread/read', {'threadId': thread_id, 'includeTurns': False})
                thread = result.get('thread', {})
                page = resumed.rpc('thread/turns/list', {
                    'threadId': thread_id, 'limit': 10, 'sortDirection': 'asc', 'itemsView': 'full'})
                turns = page.get('data', [])
                require(thread.get('id') == thread_id and thread.get('cwd') == str(workspace) and
                        any(t.get('id') == turn_id and t.get('status') == status for t in turns),
                        'Persisted terminal history mismatch')
            report['checks'].append({'name': 'fresh-process-history', 'threads': len(history),
                                     'matchingTurnIDsAndTerminals': True})
            resumed.thread_id = history[0][0]
            result = resumed.rpc('thread/resume', {
                'threadId': resumed.thread_id, 'excludeTurns': True,
                'cwd': str(workspace), 'approvalPolicy': 'on-request', 'sandbox': 'read-only'})
            require(result.get('thread', {}).get('id') == resumed.thread_id and
                    result.get('approvalPolicy') == 'on-request' and
                    result.get('sandbox', {}).get('type') == 'readOnly',
                    'Resumed thread target or effective permissions changed')
            provider.select('text')
            resumed.start_turn('text')
            require(resumed.turn_id not in {turn_id for _, turn_id, _ in history},
                    'Resumed turn reused a prior turn identity')
            resumed.wait_for(lambda: resumed.terminal is not None)
            require(resumed.terminal == 'completed' and resumed.message is True,
                    'Resumed native thread did not complete a new synthetic turn')
            provider.check(1)
            report['checks'].append({'name': 'resumed-turn', 'sameThread': True,
                                     'threadID': resumed.thread_id, 'turnID': resumed.turn_id,
                                     'terminal': resumed.terminal, 'permissionsReasserted': True})
            resumed.close()
            require(resumed.cleanup['exitStatus'] == 0, 'History server exited unsuccessfully')
            report['phase'] = 'complete'
        finally:
            primary_error = sys.exc_info()[0]
            failures = []
            for peer in peers:
                try:
                    peer.close()
                except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
                    failures.append(type(error).__name__)
            try:
                provider.close()
            except (ValueError, OSError, RuntimeError) as error:
                failures.append(type(error).__name__)
                report['providerCleanupFailureType'] = type(error).__name__
            report['provider'] = {'kind': 'deterministic-loopback-fixture',
                                  'requests': provider.total, 'stopped': not provider.thread.is_alive(),
                                  'connections': provider.connections,
                                  'failed': provider.failure is not None}
            report['sessions'] = [
                {'cleanup': peer.cleanup, 'events': peer.events,
                 'streams': {name: {'bytes': peer.totals[name], 'sha256': digest.hexdigest()}
                             for name, digest in peer.digests.items()}}
                for peer in peers]
            if failures:
                report['cleanupFailures'] = failures
                if primary_error is None:
                    raise probe.ProbeError('Native lifecycle cleanup failed')
            if primary_error is None:
                require(provider.failure is None, 'Loopback provider failed during cleanup')
                require(provider.total == provider.connections == 6,
                        'Unexpected final provider connection/request count')
                if synthetic_key is not None:
                    report['syntheticProviderAuth'] = {
                        'exactBearerRequests': provider.total,
                        'keyAbsentFromBodies': True,
                        'keyAbsentFromObservedNativeFrames': True,
                        'keyAbsentFromApprovedShellEnvironment': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', type=Path, required=True)
    parser.add_argument('--schema-dir', type=Path, required=True)
    parser.add_argument('--default-schema-dir', type=Path, required=True)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parent.parent /
                        'references/codex-capabilities.json')
    parser.add_argument('--output', type=Path, default=Path('build/codex-turn-probe.json'))
    parser.add_argument('--synthetic-provider-key', action='store_true',
                        help='Generate a fixture-only key and check native authorization and shell isolation.')
    args = parser.parse_args()
    report = {'reportVersion': 1, 'status': 'failed', 'phase': 'starting',
              'capturedAtUTC': datetime.now(timezone.utc).isoformat()}
    probe.write_report(args.output, report)
    status = 1
    try:
        experiment(args, report)
        report['status'], status = 'passed', 0
    except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
        report['failureType'] = type(error).__name__
        if isinstance(error, probe.ProbeError):
            report['failure'] = str(error)
        print('Codex lifecycle fixture failed: ' + type(error).__name__, file=sys.stderr)
    finally:
        probe.write_report(args.output, report)
    if status == 0:
        print('PASS native Codex lifecycle: 5 synthetic-provider turns + fresh-process history; no real model.')
    return status


if __name__ == '__main__':
    sys.exit(main())
