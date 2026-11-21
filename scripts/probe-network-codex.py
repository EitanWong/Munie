#!/usr/bin/env python3
"""Opt-in native HTTPS -> authenticated ledger -> native Codex, synthetic provider only."""

import argparse
from contextlib import contextmanager, ExitStack
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import time


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ledger = load('network_codex_ledger', 'probe-ledger-network.py')
host = load('network_codex_host', 'probe-codex-host.py')
native, network, helper, require = ledger.native, ledger.network, ledger.helper, ledger.require
SCENARIOS = ('text', 'approval-cancel', 'approval-accept', 'running-interrupt', 'pending-crash',
             'revoked-pending')
OPERATIONS = {'submit', 'snapshot', 'events', 'approval', 'interrupt', 'reconcile'}
ERRORS = ledger.ERRORS | {'invalid-approval', 'invalid-state'}
CORE = {'event', 'state', 'requestID', 'phase', 'hasUpstream', 'cancellationRequested', 'pendingApproval'}
OPTIONAL = {'eventKind', 'approvalToken', 'agentMessageMatched'}


def validate_reply(frame):
    require(type(frame) is dict and frame.get('event') == 'result', 'Invalid Codex bridge event')
    if set(frame) == {'event', 'error'}:
        require(type(frame['error']) is str and frame['error'] in ERRORS, 'Invalid bridge error')
        return dict(frame)
    require(CORE <= frame.keys() <= CORE | OPTIONAL and frame['state'] == 'codex-snapshot',
            'Invalid Codex snapshot schema')
    ledger.canonical_uuid(frame['requestID'])
    require(type(frame['phase']) is str and frame['phase'] in ledger.PHASES, 'Invalid task phase')
    for key in ('hasUpstream', 'cancellationRequested', 'pendingApproval'):
        require(type(frame[key]) is bool, 'Invalid snapshot Boolean')
    if 'eventKind' in frame:
        require(type(frame['eventKind']) is str and frame['eventKind'] in
                {'progress', 'approval', 'approval-resolved', 'terminal', 'none'}, 'Invalid event kind')
    if 'approvalToken' in frame:
        ledger.canonical_uuid(frame['approvalToken'])
        require(frame['pendingApproval'], 'Token outside a pending approval')
    if 'agentMessageMatched' in frame:
        require(type(frame['agentMessageMatched']) is bool and 'eventKind' in frame,
                'Uncorrelated native message observation')
    return dict(frame)


def validate_native_reply(frame):
    extra = (CORE - {'event'}) | OPTIONAL
    require(type(frame) is dict and native.REQUIRED_KEYS <= frame.keys() <=
            (native.RESULT_KEYS - {'ordinal'}) | extra, 'Invalid native Codex result schema')
    transport = {k: v for k, v in frame.items() if k not in extra | {'fixtureError'}}
    native.validate_result(transport)
    require(frame.get('httpStatus') in {200, 400, 404, 409} and 'errorCode' not in frame and
            frame.get('tlsProtocol') == 772 and frame.get('proxy') is False and
            frame['trustRejected'] == 0 and frame['bodyBytes'] > 0 and
            not frame['overflow'] and not frame['redirectRejected'] and
            not frame['cancelledOnResponse'], 'Missing authenticated native HTTP evidence')
    if 'fixtureError' in frame:
        require(type(frame['fixtureError']) is str and frame['fixtureError'] in ERRORS and
                not extra & frame.keys(), 'Ambiguous native domain denial')
    else:
        validate_reply({k: v for k, v in frame.items() if k in CORE | OPTIONAL})
        require(frame['httpStatus'] == 200, 'Task state used an error HTTP status')
    return dict(frame)


class CodexNativePeer(native.NativePeer):
    def transfer(self, command):
        self.send(command)
        return validate_native_reply(self.read_frame(time.monotonic() + self.request_seconds))


class CodexPeer(helper.JsonLinePeer):
    def accept_notification(self, _frame):
        raise helper.ProbeError('Unexpected trailing Codex bridge frame')


class CodexBridge(ledger.LedgerBridge):
    def __init__(self, executable, codex, root, scenario, report):
        super().__init__(executable, root, report)
        self.codex, self.scenario, self.native_group = codex, scenario, None
        self.guardian = Path(__file__).with_name('codex-host-guardian.py').resolve()

    def start(self, initialize):
        require(self.peer is None, 'Bridge process already owned')
        self.round += 1
        config = {'rootDirectory': str(self.root), 'initialize': initialize, 'hostID': ledger.HOST,
                  'projects': [ledger.PROJECT, ledger.OTHER_PROJECT], 'devices': [
                      {'fingerprint': network.fingerprint(self.root, name), 'deviceID': device,
                       'projectIDs': [ledger.PROJECT]}
                      for name, device in [('device-a', ledger.DEVICE_A), ('device-b', ledger.DEVICE_B)]]}
        path = self.root / ('codex-config-' + str(self.round) + '.json')
        native.private_file(path, json.dumps(config).encode())
        record = {'round': self.round, 'initialized': initialize}
        self.report.setdefault('bridgeProcesses', []).append(record)
        # Guardian creates this atomically. Only remove a prior, already verified dead fixture group.
        registry = self.root / 'native-codex.json'
        if registry.exists():
            require(self.native_group is not None and not host.probe.group_members(self.native_group),
                    'Cannot replace a live native launch registry')
            registry.unlink()
        self.native_group = None
        self.peer = CodexPeer([str(self.executable), str(path), str(self.codex), sys.executable,
                               str(self.guardian), self.scenario], self.root,
                              {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
                              request_seconds=12, total_seconds=90)
        frame = self.peer.read_frame(time.monotonic() + 12)
        require(type(frame) is dict and set(frame) == {'event', 'sqliteVersion', 'nativeGroup'} and
                frame['event'] == 'ready' and type(frame['sqliteVersion']) is str and
                type(frame['nativeGroup']) is int and frame['nativeGroup'] > 1 and
                frame['nativeGroup'] != self.peer.process.pid, 'Invalid native bridge startup')
        self.native_group = frame['nativeGroup']
        require(host.registered_group(registry, self.peer.process.pid) == self.native_group,
                'Native identity differs from independent guardian registry')
        record.update(sqliteVersion=frame['sqliteVersion'], nativeGroup=self.native_group)

    def call(self, command):
        with self.lock:
            require(self.peer is not None, 'Codex bridge unavailable')
            self.peer.send(command)
            frame = self.peer.read_frame(time.monotonic() + 12)
            if type(frame) is dict and frame.get('event') == 'failure':
                self.report['bridgeFailure'] = validate_failure(frame)
                raise ValueError('Native bridge reported a structural failure')
            return frame

    def stop(self, killed=False):
        with self.lock:
            if self.peer is None:
                return
            peer, self.peer = self.peer, None
            record = self.report['bridgeProcesses'][-1]
            failure = None
            try:
                if killed:
                    os.killpg(peer.process.pid, signal.SIGKILL)
                else:
                    peer.process.stdin.close()
                    closed = peer.read_frame(time.monotonic() + 8)
                    require(type(closed) is dict and set(closed) == {'event', 'cleanup'} and
                            closed['event'] == 'closed', 'Missing native cleanup acknowledgement')
                    validate_cleanup(closed['cleanup'])
                    record['nativeCleanup'] = closed['cleanup']
            except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
                failure = error
            finally:
                try:
                    peer.close()
                    require(peer.cleanup['exitStatus'] == (-signal.SIGKILL if killed else 0) and
                            peer.cleanup['streamsReachedEOF'] and peer.cleanup['processGroupGone'] and
                            peer.totals['stderr'] == 0, 'Bridge process cleanup failed')
                except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
                    failure = failure or error
                finally:
                    try:
                        if self.native_group is None:
                            registry = self.root / 'native-codex.json'
                            if registry.exists():
                                self.native_group = host.registered_group(registry, peer.process.pid)
                        if self.native_group is not None:
                            try:
                                deadline = time.monotonic() + 5
                                while host.probe.group_members(self.native_group) and time.monotonic() < deadline:
                                    time.sleep(.02)
                                gone = not host.probe.group_members(self.native_group)
                            except (ValueError, OSError, subprocess.SubprocessError):
                                # A broken process observation must not skip the initial kill/reap.
                                record['forcedNativeCleanup'] = host.stop_native_group(self.native_group)
                                raise
                            record['guardianGroupGone'] = gone
                            if not gone:
                                record['forcedNativeCleanup'] = host.stop_native_group(self.native_group)
                                raise ValueError('Guardian failed to reap native group')
                        else:
                            raise ValueError('Native launch identity unavailable')
                    except (ValueError, OSError, subprocess.SubprocessError) as error:
                        failure = failure or error
                    record.update(killed=killed, cleanup=peer.cleanup,
                                  streams={k: {'bytes': peer.totals[k], 'sha256': v.hexdigest()}
                                           for k, v in peer.digests.items()})
                    if failure is not None:
                        record['cleanupFailureType'] = type(failure).__name__
            if failure is not None:
                raise failure


def validate_cleanup(value):
    require(type(value) is dict and set(value) == {'leaderExitStatus', 'stdoutEOF', 'stderrEOF',
        'groupGone', 'escalated', 'stdinBytes', 'stdoutBytes', 'stderrBytes'}, 'Invalid native cleanup')
    require(type(value['leaderExitStatus']) is int and value['leaderExitStatus'] == 0,
            'Native process did not exit cleanly')
    for key in ('stdoutEOF', 'stderrEOF', 'groupGone', 'escalated'):
        require(type(value[key]) is bool, 'Invalid cleanup Boolean')
    require(value['stdoutEOF'] and value['stderrEOF'] and value['groupGone'], 'Native cleanup incomplete')
    for key in ('stdinBytes', 'stdoutBytes', 'stderrBytes'):
        require(type(value[key]) is int and 0 <= value[key] <= 33_554_432, 'Invalid stream size')
    require(value['stdinBytes'] > 0 and value['stdoutBytes'] > 0, 'No native protocol traffic')


def validate_failure(value):
    codes = {'fixture-failure', 'input-failure', 'client-failure', 'transport-failure',
             'ledger-failure', 'session-failure', 'close-failure', 'recovery-failure',
             'cancelled', 'unexpected-failure', 'client-permission-mismatch',
             'client-identity-mismatch', 'client-response-mismatch', 'client-invalid-transition',
             'client-transport-failure', 'client-malformed-frame', 'client-closed',
             'client-not-initialized', 'client-busy', 'client-event-limit', 'client-transport',
             'client-unsupported-version', 'client-unsupported-method', 'client-already-initialized',
             'client-invalid-configuration', 'client-stale-approval', 'client-unavailable-decision',
             'client-pagination-limit'}
    def safe_code(code):
        return type(code) is str and (code in codes or
            re.fullmatch(r'client-rpc--?[0-9]{1,19}', code) is not None)
    require(set(value) == {'event', 'code', 'cleanup', 'cleanupError'} and
            value['event'] == 'failure' and safe_code(value['code']) and
            (value['cleanupError'] is None or safe_code(value['cleanupError'])), 'Invalid failure schema')
    if value['cleanup'] is not None:
        validate_cleanup(value['cleanup'])
    return dict(value)


class CodexPolicy(ledger.LedgerPolicy):
    def request(self, operation, fingerprint, body):
        try:
            require(operation in OPERATIONS, 'Unsupported operation')
            value = helper.strict_json(body)
            expected = ({'requestID', 'projectID', 'payload'} if operation == 'submit' else
                        {'requestID', 'approvalToken', 'decision'} if operation == 'approval' else
                        {'requestID'})
            require(type(value) is dict and set(value) == expected, 'Invalid HTTP schema')
            ledger.canonical_uuid(value['requestID'])
            command = {'operation': 'nextEvent' if operation == 'events' else operation,
                       'peerFingerprint': fingerprint, 'requestID': value['requestID']}
            if operation == 'submit':
                ledger.canonical_uuid(value['projectID'])
                require(type(value['payload']) is str and value['payload'].strip() and
                        len(value['payload'].encode()) <= network.MAX_BODY, 'Invalid text')
                command.update(projectID=value['projectID'], text=value['payload'])
            if operation == 'approval':
                ledger.canonical_uuid(value['approvalToken'])
                require(type(value['decision']) is str and value['decision'] in {'accept', 'cancel'},
                        'Invalid approval decision')
                command.update(approvalToken=value['approvalToken'], decision=value['decision'])
        except (ValueError, UnicodeError):
            return 400, {'error': 'invalid-request'}
        frame = validate_reply(self.bridge.call(command))
        require('error' in frame or frame['requestID'] == command['requestID'], 'Uncorrelated reply')
        result = {k: v for k, v in frame.items() if k != 'event'}
        status = {'request-conflict': 409, 'invalid-request': 400,
                  'unknown-request': 404, 'invalid-approval': 409, 'invalid-state': 409}.get(
                      result.get('error'), 200)
        self.results.append({'operation': operation, 'peerFingerprint': fingerprint,
                             'result': result, 'wireHTTPStatus': status})
        return status, result


class CodexHTTPHandler(ledger.LedgerHTTPHandler):
    allowed_paths = tuple('/fixture/' + path for path in sorted(OPERATIONS))

    def handle_submission(self, fingerprint, body):
        try:
            return self.server.policy.request(self.path.removeprefix('/fixture/'), fingerprint, body)
        except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
            self.server.policy.failure = type(error).__name__
            raise


def rows(root, text):
    result = ledger.ledger_rows(root)
    with sqlite3.connect((root / 'state/submissions.sqlite3').as_uri() + '?mode=ro', uri=True) as db:
        upstream = db.execute('SELECT id,thread,turn FROM requests ORDER BY id').fetchall()
    result['upstream'] = [{'requestID': r, 'threadID': t, 'turnID': u} for r, t, u in upstream]
    for row in result['requests']:
        require(row['payloadDigest'] == hashlib.sha256(text.encode()).hexdigest(),
                'SQLite digest differs from transmitted input')
    require(text.encode() not in (root / 'state/submissions.sqlite3').read_bytes(),
            'Ledger persisted request plaintext')
    return result


def request_command(operation, scenario, *, request=ledger.REQUEST_A, project=ledger.PROJECT,
                    token=None, decision=None):
    value = native.command(path=operation, requestID=request, projectID=project,
                           payload='Execute the Munie native host fixture: ' + scenario)
    if token is not None:
        value['approvalToken'] = token
    if decision is not None:
        value['decision'] = decision
    return value


@contextmanager
def client(executable, root, port, password, report, name, identity='device-a'):
    with native.native_peer(executable, root, port, password, report, name, identity=identity,
                            peer_class=CodexNativePeer) as peer:
        peer.fixture_fingerprint = network.fingerprint(root, identity)
        yield peer


def observe(report, root, policy, peer, scenario, name, operation='snapshot', *,
            phase=None, error=None, request=ledger.REQUEST_A, project=ledger.PROJECT,
            token=None, decision=None):
    text = 'Execute the Munie native host fixture: ' + scenario
    before = rows(root, text)
    connections = policy.connections
    frame = peer.transfer(request_command(operation, scenario, request=request, project=project,
                                           token=token, decision=decision))
    after = rows(root, text)
    record = {'name': name, 'operation': operation, 'before': before, 'result': frame, 'after': after,
              'connectionsBefore': connections, 'connectionsAfter': policy.connections}
    report['checks'].append(record)
    require(policy.results[-1]['peerFingerprint'] == peer.fixture_fingerprint,
            'Connection identity does not match native client')
    if error:
        require(frame.get('fixtureError') == error and before == after,
                'Denial changed ledger or returned task data')
    else:
        require(frame.get('requestID') == request and frame.get('state') == 'codex-snapshot' and
                'fixtureError' not in frame, 'Unexpected task response')
        if phase is not None:
            require(frame['phase'] == phase, 'Unexpected task phase')
        row = next(r for r in after['requests'] if r['requestID'] == request)
        require(row['phase'] == frame['phase'] and row['deviceID'] == ledger.DEVICE_A,
                'Native result differs from independent SQLite state')
    require(policy.failure is None, 'HTTP bridge recorded failure')
    record['passed'] = True
    return frame


def pump(report, root, policy, peer, scenario, *, stop_at_approval=False, expected='completed'):
    messages = False
    for index in range(128):
        result = observe(report, root, policy, peer, scenario, 'event-' + str(index), 'events')
        messages |= result.get('agentMessageMatched') is True
        if stop_at_approval and result.get('eventKind') == 'approval':
            require(result['pendingApproval'] and 'approvalToken' in result, 'Missing approval token')
            return result
        if result['phase'] in {'completed', 'failed', 'cancelled'}:
            require(result['phase'] == expected and result.get('eventKind') == 'terminal',
                    'Unexpected native terminal')
            require(messages is (expected == 'completed'), 'Native output marker mismatch')
            return result
    raise ValueError('Native event budget exceeded')


def raw_denials(report, root, policy, port, scenario):
    text = 'Execute the Munie native host fixture: ' + scenario
    value = {'requestID': ledger.REQUEST_A, 'projectID': ledger.PROJECT, 'payload': text}
    controls = [('forged-device', '/fixture/submit', dict(value, deviceID=ledger.DEVICE_B)),
                ('forged-fingerprint', '/fixture/submit', dict(value, peerFingerprint='0' * 64)),
                ('no-remote-revoke', '/fixture/revoke', {}),
                ('no-remote-claim', '/fixture/claim', {}),
                ('no-remote-rpc', '/fixture/rpc', {})]
    for name, route, body in controls:
        before = rows(root, text)
        with network.LoopbackClient(port, network.tls_context(root, identity='device-a'),
                                    hostname='127.0.0.1') as peer:
            peer.request('POST', route, body=json.dumps(body).encode(),
                         headers={'Content-Type': 'application/json'})
            response = peer.getresponse(); actual = response.status, helper.strict_json(response.read(2049))
        expected = (400, {'error': 'invalid-request'}) if name.startswith('forged') else (
                    404, {'error': 'fixture-route'})
        require(actual == expected and before == rows(root, text) and policy.failure is None,
                'Raw input crossed trusted boundary')
        report['checks'].append({'name': name, 'source': 'raw-https', 'httpStatus': actual[0],
                                 'result': actual[1], 'passed': True})


def verify_tool_exit(workspace):
    for name in ('running-shell.pid', 'running-child.pid'):
        pid = int((workspace / name).read_text().strip())
        deadline = time.monotonic() + 3
        while True:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            require(time.monotonic() < deadline, 'Interrupted tool remains before native shutdown')
            time.sleep(.02)
    require(not (workspace / 'after-interrupt').exists(), 'Cancelled tool continued')


def run_scenario(args, root, password, report, scenario):
    provider_scenario = 'pending-crash' if scenario == 'revoked-pending' else scenario
    workspace = root / 'projects' / ledger.PROJECT
    provider = host.HostFixtureServer(workspace)
    bridge = CodexBridge(args.ledger_executable, args.codex, root, provider_scenario, report)
    primary = None
    try:
        provider.select(provider_scenario)
        prepare_sandbox(root, workspace, provider, args.codex, report)
        bridge.start(True)
        verify_native_control_isolation(root, workspace, report)
        policy = CodexPolicy(bridge)
        state = native.NativeFixtureState()
        server_record = {};report['server'] = server_record
        with network.running_server(native.observed_server_context(root, state), policy,
                                    server_record, handler=CodexHTTPHandler) as port:
            with client(args.native_executable, root, port, password, report, 'unknown', 'unknown') as peer:
                observe(report, root, policy, peer, provider_scenario, 'unknown-device', 'submit',
                        error='unauthorized')
            with client(args.native_executable, root, port, password, report, 'a') as peer:
                with ExitStack() as reconnects:
                    observe(report, root, policy, peer, provider_scenario, 'cross-project', 'submit',
                            project=ledger.OTHER_PROJECT, error='unauthorized')
                    observe(report, root, policy, peer, provider_scenario, 'start', 'submit', phase='running')
                    observe(report, root, policy, peer, provider_scenario, 'exact-retry', 'submit', phase='running')
                    before_conflict = rows(root, 'Execute the Munie native host fixture: ' + provider_scenario)
                    conflict = request_command('submit', provider_scenario)
                    conflict['payload'] = 'Different synthetic content for same immutable request'
                    denied = peer.transfer(conflict)
                    require(denied.get('fixtureError') == 'request-conflict' and
                            rows(root, 'Execute the Munie native host fixture: ' + provider_scenario) == before_conflict,
                            'Conflicting retry changed durable input')
                    report['checks'].append({'name': 'conflicting-payload', 'result': denied,
                                             'before': before_conflict, 'after': before_conflict, 'passed': True})
                    if scenario == 'text':
                        pump(report, root, policy, peer, provider_scenario)
                    else:
                        approval = pump(report, root, policy, peer, provider_scenario, stop_at_approval=True)
                        token = approval['approvalToken']
                        peer.close()
                        with client(args.native_executable, root, port, password, report,
                                    'b-pending', 'device-b') as other:
                            observe(report, root, policy, other, provider_scenario,
                                    'cross-device-pending-read', error='unauthorized')
                            observe(report, root, policy, other, provider_scenario,
                                    'cross-device-pending-approval', 'approval', token=token,
                                    decision='accept', error='unauthorized')
                        peer = reconnects.enter_context(client(args.native_executable, root, port,
                            password, report, 'a-reconnected'))
                        resumed = observe(report, root, policy, peer, provider_scenario,
                                          'same-owner-reconnected', phase='running')
                        require(resumed.get('approvalToken') == token and resumed['pendingApproval'],
                                'Reconnect lost original pending approval token')
                        observe(report, root, policy, peer, provider_scenario, 'wrong-approval-token', 'approval',
                                token=ledger.MISSING, decision='accept', error='invalid-approval')
                        if scenario == 'revoked-pending':
                            connections = policy.connections
                            require(bridge.call({'operation': 'revoke', 'deviceID': ledger.DEVICE_A}) ==
                                    {'event': 'revoked'}, 'Local revoke failed')
                            for operation in ('snapshot', 'approval', 'events', 'interrupt'):
                                observe(report, root, policy, peer, provider_scenario, 'revoked-' + operation,
                                        operation, token=token if operation == 'approval' else None,
                                        decision='accept' if operation == 'approval' else None,
                                        error='unauthorized')
                            require(policy.connections == connections, 'Revocation used a new TLS connection')
                        elif scenario == 'pending-crash':
                            bridge.stop(killed=True)
                            bridge.start(False)
                            observe(report, root, policy, peer, provider_scenario, 'restart-exact-retry',
                                    'submit', phase='reconciling')
                            observe(report, root, policy, peer, provider_scenario, 'restart-stale-token',
                                    'approval', token=token, decision='accept', error='invalid-approval')
                            recovered = observe(report, root, policy, peer, provider_scenario,
                                                'positive-known-id-recovery', 'reconcile')
                            require(recovered['phase'] == 'cancelled', 'Unexpected recovery terminal')
                        else:
                            decision = 'cancel' if scenario == 'approval-cancel' else 'accept'
                            observe(report, root, policy, peer, provider_scenario, 'answer-bound-approval',
                                    'approval', token=token, decision=decision)
                            observe(report, root, policy, peer, provider_scenario, 'duplicate-approval',
                                    'approval', token=token, decision=decision, error='invalid-approval')
                            if scenario == 'running-interrupt':
                                deadline = time.monotonic() + 5
                                while not all((workspace / n).exists() for n in
                                              ('running-shell.pid', 'running-child.pid')):
                                    require(time.monotonic() < deadline, 'Native tool did not start')
                                    time.sleep(.01)
                                ack = observe(report, root, policy, peer, provider_scenario,
                                              'request-interrupt', 'interrupt', phase='running')
                                require(ack['cancellationRequested'], 'Missing cancellation intent')
                            pump(report, root, policy, peer, provider_scenario,
                                 expected='completed' if scenario == 'approval-accept' else 'cancelled')
                            if scenario == 'running-interrupt':
                                verify_tool_exit(workspace);report['toolProcessesGoneBeforeClose'] = True
                    if scenario != 'revoked-pending':
                        final = observe(report, root, policy, peer, provider_scenario, 'final-state')
                        observe(report, root, policy, peer, provider_scenario, 'terminal-retry', 'submit',
                                phase=final['phase'])
            with client(args.native_executable, root, port, password, report, 'b', 'device-b') as peer:
                observe(report, root, policy, peer, provider_scenario, 'cross-device-read', error='unauthorized')
                observe(report, root, policy, peer, provider_scenario, 'cross-device-replay', 'submit',
                        error='unauthorized')
            raw_denials(report, root, policy, port, provider_scenario)
        bridge.stop()
        expected_requests = 2 if scenario == 'approval-accept' else 1
        provider.check(expected_requests)
        report['providerRequests'] = provider.total
        require(provider.total == expected_requests, 'Unexpected native model retry')
        report['effectCount'] = host.effect_count(workspace)
        require(report['effectCount'] == int(scenario == 'approval-accept'), 'Repeated native tool effect')
        report['finalLedger'] = rows(root, 'Execute the Munie native host fixture: ' + provider_scenario)
        require(len(report['finalLedger']['requests']) == 1 and
                report['finalLedger']['upstream'][0]['threadID'] is not None and
                report['finalLedger']['upstream'][0]['turnID'] is not None, 'Lost durable native mapping')
        report['connections'] = policy.connections
        report['serverPolicyResponses'] = policy.results
        report['passed'] = True
    except BaseException as error:
        primary = error
        raise
    finally:
        failure = None
        try:
            bridge.stop()
        except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
            report['bridgeCleanupFailureType'] = type(error).__name__;failure = error
        finally:
            try:
                provider.close()
                report['providerStopped'] = not provider.thread.is_alive() and provider.socket.fileno() == -1
            except (ValueError, OSError) as error:
                report['providerCleanupFailureType'] = type(error).__name__;failure = failure or error
        if primary is None and failure is not None:
            raise failure


def native_sandbox_profile(root, workspace, protected, port):
    # Native execution may touch only its own workspace, Codex data and scratch within the
    # fixture. Host ledger/registry, TLS identities and future native-client configs stay private.
    exclusions = ' '.join('(require-not (subpath ' + json.dumps(str(path)) + '))'
                          for path in (workspace, root / 'codex-data', root / 'tmp'))
    return host.probe.sandbox_profile(root, protected, Path.home()) + (
        '\n(deny file-read-data file-write* (require-all (subpath ' + json.dumps(str(root)) + ') '
        + exclusions + '))' + f'\n(allow network-outbound (remote ip "localhost:{port}"))')


CONTROL_GUARD_CODE = r'''
import errno, json, os, sys
from pathlib import Path
root, workspace, other = map(Path, sys.argv[1:])
targets = [('tls-key', root / 'device-b.key'), ('tls-identity', root / 'device-b.p12'),
           ('tls-passphrase', root / 'p12-password'), ('driver-config', root / 'codex-config-1.json'),
           ('native-config', root / 'native-isolation-guard.json'),
           ('ledger', root / 'state/submissions.sqlite3'), ('registry', root / 'native-codex.json'),
           ('other-project', other)]
passed = []
for label, path in targets:
    for operation in ('read', 'write'):
        try:
            if operation == 'read':
                path.read_bytes()
            else:
                with path.open('r+b') as output:
                    output.write(b'forbidden')
        except OSError as error:
            if error.errno not in (errno.EPERM, errno.EACCES):
                raise
            passed.append(label + '-' + operation + '-denied')
        else:
            raise RuntimeError('Native control isolation failed')
for directory in (workspace, root / 'codex-data', root / 'tmp'):
    path = directory / 'native-isolation-roundtrip'
    path.write_bytes(b'synthetic')
    if path.read_bytes() != b'synthetic':
        raise RuntimeError('Native data access failed')
    path.unlink()
print(json.dumps({'denials': passed, 'nativeDirectoryRoundtrips': 3}))
'''


def verify_native_control_isolation(root, workspace, report):
    other = root / 'projects' / ledger.OTHER_PROJECT / 'isolation-sentinel'
    native.private_file(other, b'other project must remain inaccessible')
    native.private_file(root / 'native-isolation-guard.json', b'synthetic native configuration')
    targets = [root / name for name in ('device-b.key', 'device-b.p12', 'p12-password',
        'codex-config-1.json', 'native-isolation-guard.json', 'state/submissions.sqlite3',
        'native-codex.json')] + [other]
    before = [hashlib.sha256(path.read_bytes()).hexdigest() for path in targets]
    result = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(root / 'sandbox.sb'),
        sys.executable, '-I', '-c', CONTROL_GUARD_CODE, str(root), str(workspace), str(other)],
        cwd=workspace, env={'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8'},
        capture_output=True, timeout=10, check=True)
    observed = helper.strict_json(result.stdout)
    expected = [label + '-' + operation + '-denied' for label in ('tls-key', 'tls-identity',
        'tls-passphrase', 'driver-config', 'native-config', 'ledger', 'registry', 'other-project')
        for operation in ('read', 'write')]
    require(observed == {'denials': expected, 'nativeDirectoryRoundtrips': 3} and not result.stderr,
            'Incomplete native control isolation evidence')
    require(before == [hashlib.sha256(path.read_bytes()).hexdigest() for path in targets],
            'Native guard changed control bytes')
    report['nativeControlIsolation'] = observed


def prepare_sandbox(root, workspace, provider, codex, report):
    protected = root.parent / 'protected';protected.mkdir(mode=0o700)
    sentinel = protected / 'sentinel';sentinel.write_text('pristine')
    home = root / 'codex-data';home.mkdir(mode=0o700)
    (root / 'tmp').mkdir(mode=0o700)
    port = provider.server_port
    native.private_file(home / 'config.toml', (
        f'model = "{host.lifecycle.MODEL}"\nmodel_provider = "munie_fixture"\n'
        'cli_auth_credentials_store = "file"\n[shell_environment_policy]\ninherit = "none"\n'
        '[model_providers.munie_fixture]\nname = "Munie deterministic fixture"\n'
        f'base_url = "http://127.0.0.1:{port}{provider.path.removesuffix("/responses")}"\n'
        'wire_api = "responses"\nrequires_openai_auth = false\n'
        'request_max_retries = 0\nstream_max_retries = 0\n'
        '[analytics]\nenabled = false\n[feedback]\nenabled = false\n').encode())
    profile = native_sandbox_profile(root, workspace, protected, port)
    native.private_file(root / 'sandbox.sb', profile.encode())
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()),
                   'CODEX_HOME': str(home), 'TMPDIR': str(root / 'tmp'), 'LANG': 'en_US.UTF-8'}
    sandbox = ['/usr/bin/sandbox-exec', '-f', str(root / 'sandbox.sb')]
    guard = subprocess.run(sandbox + [sys.executable, '-I', '-c', host.probe.GUARD_CODE,
                           str(sentinel), str(Path.home())], cwd=workspace, env=environment,
                           capture_output=True, timeout=10, check=True)
    report['sandboxGuards'] = helper.strict_json(guard.stdout)
    require(sentinel.read_text() == 'pristine', 'Protected bytes changed')
    version = subprocess.run(sandbox + [str(codex), '--version'], cwd=workspace, env=environment,
                             capture_output=True, timeout=5, check=True)
    require(version.stdout.decode().strip() == host.probe.VERSION, 'Native version drift')


def experiment(args, report):
    host.probe.validate_inputs(args.codex, args.schema_dir, args.default_schema_dir, args.catalog, report)
    report['phase'] = 'authenticated-network-native-codex'
    require(native.platform.system() == 'Darwin' and native.ssl.HAS_TLSv1_3, 'Unsupported runtime')
    for path in (args.native_executable, args.ledger_executable, args.openssl):
        require(path.is_absolute() and path.is_file() and os.access(path, os.X_OK),
                'Select explicit executable paths')
    native.record_metadata(args.native_executable, args.openssl, report)
    report['bridgeExecutableSHA256'] = hashlib.sha256(args.ledger_executable.read_bytes()).hexdigest()
    report['runnerSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    repository = Path(__file__).resolve().parent.parent
    sources = [repository / 'Package.swift', Path(__file__), Path(ledger.__file__),
               Path(native.__file__), Path(host.__file__), Path(host.lifecycle.__file__),
               repository / 'scripts/codex-host-guardian.py']
    sources += sorted((repository / 'apps/MunieHost').rglob('*.swift'))
    report['sourceSHA256'] = {str(p.relative_to(repository)): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sources}
    report['scope'] = ('Actual macOS URLSession/Security -> loopback TLS peer identity -> SQLite -> '
        'fixed-version native Codex. Deterministic provider and temporary projects/identities only. '
        'Approval controls are trusted research actions over prevalidated fixed commands; no '
        'production approval UI, pairing/service, real model/account, mobile app, WAN or hardware.')
    report['scenarios'] = []
    for scenario in SCENARIOS:
        record = {'scenario': scenario, 'checks': []};report['scenarios'].append(record)
        temporary = None
        try:
            import tempfile
            with tempfile.TemporaryDirectory(prefix='munie-network-codex-') as directory:
                base = Path(directory).resolve();root = base / 'fixture';temporary = base
                root.mkdir(mode=0o700)
                password = native.prepare_native_certificates(args.openssl, root)
                (root / 'projects').mkdir(mode=0o700)
                for project in (ledger.PROJECT, ledger.OTHER_PROJECT):
                    (root / 'projects' / project).mkdir(mode=0o700)
                record['fixtureIdentityFingerprints'] = {
                    n: network.fingerprint(root, n) for n in ('device-a', 'device-b', 'unknown')}
                run_scenario(args, root, password, record, scenario)
        finally:
            record['temporaryCredentialsProjectsLedgerRemoved'] = temporary is not None and not temporary.exists()
        require(record['passed'] and record['temporaryCredentialsProjectsLedgerRemoved'] and
                record['providerStopped'] and record['server']['serverStopped'] and
                all(x.get('passed') for x in record['checks']), 'Incomplete scenario evidence')
    require(tuple(x['scenario'] for x in report['scenarios']) == SCENARIOS, 'Incomplete scenario matrix')


def write_report(path, report):
    # Tokens are needed in memory for replay/reconnect assertions, never in persisted diagnostics.
    def project(value):
        if type(value) is dict:
            result = {key: project(item) for key, item in value.items() if key != 'approvalToken'}
            if 'approvalToken' in value:
                result['approvalTokenPresent'] = True
            return result
        if type(value) is list:
            return [project(item) for item in value]
        return value
    helper.write_report(path, project(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('native-executable', 'ledger-executable', 'codex', 'schema-dir',
                 'default-schema-dir', 'openssl', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parent.parent /
                        'references/codex-capabilities.json')
    args = parser.parse_args()
    report = {'reportVersion': 1, 'status': 'failed', 'phase': 'starting',
              'capturedAtUTC': datetime.now(timezone.utc).isoformat()}
    write_report(args.output, report)
    status = 1
    try:
        report['phase'] = 'authenticated-network-native-codex'
        experiment(args, report)
        report['status'], report['phase'], status = 'passed', 'complete', 0
    except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
        report['failureType'] = type(error).__name__
        report['failure'] = type(error).__name__
        print('Network Codex experiment failed: ' + type(error).__name__, file=sys.stderr)
    finally:
        write_report(args.output, report)
    if status == 0:
        print('PASS authenticated network + native Codex: 6 scenarios; synthetic provider, no real model or WAN.')
    return status


if __name__ == '__main__':
    sys.exit(main())
