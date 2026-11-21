#!/usr/bin/env python3
"""Actual loopback mTLS identity to SQLite ledger; no Codex, model or product gateway."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid

SPEC = importlib.util.spec_from_file_location(
    'ledger_native_fixture', Path(__file__).with_name('probe-native-network.py'))
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)
network, helper, require = native.network, native.helper, native.require
HOST = '70000000-0000-0000-0000-000000000001'
PROJECT = '70000000-0000-0000-0000-000000000002'
OTHER_PROJECT = '70000000-0000-0000-0000-000000000003'
DEVICE_A = '70000000-0000-0000-0000-000000000004'
DEVICE_B = '70000000-0000-0000-0000-000000000005'
REQUEST_A = '70000000-0000-0000-0000-000000000006'
REQUEST_B = '70000000-0000-0000-0000-000000000007'
MISSING = '70000000-0000-0000-0000-000000000008'
REQUEST_C = '70000000-0000-0000-0000-000000000009'
TEXT = 'Munie synthetic authenticated ledger input. No Agent ran.'
PHASES = {'accepted', 'dispatching', 'running', 'reconciling', 'completed', 'failed', 'cancelled'}
ERRORS = {'unauthorized', 'invalid-request', 'request-conflict', 'unknown-request'}
EXPECTED_CASES = (
    'unregistered-certificate', 'cross-project-denial', 'durable-acceptance',
    'duplicate-acceptance', 'conflicting-payload', 'authorized-snapshot', 'unknown-snapshot',
    'claimed-state-visible', 'claimed-retry-no-redispatch', 'existing-connection-revoked-read',
    'existing-connection-revoked-retry', 'existing-connection-revoked-new-request',
    'revoked-new-connection', 'cross-device-replay', 'cross-device-read',
    'second-device-acceptance', 'accepted-request-before-restart', 'forged-body-device',
    'forged-body-fingerprint', 'forged-header-device', 'duplicate-json-identity',
    'no-remote-revoke', 'no-remote-claim', 'restart-revocation-persists',
    'restart-cross-device-read', 'restart-uncertain-retry', 'restart-uncertain-snapshot',
    'restart-accepted-retry',
)


def canonical_uuid(value):
    require(type(value) is str and len(value) == 36, 'Invalid identifier type')
    require(str(uuid.UUID(value)).upper() == value, 'Noncanonical identifier')
    return value


def validate_ledger_reply(frame):
    require(type(frame) is dict and frame.get('event') == 'result', 'Invalid ledger event')
    if set(frame) == {'event', 'error'}:
        require(type(frame['error']) is str and frame['error'] in ERRORS, 'Invalid ledger error')
    else:
        require(set(frame) == {'event', 'state', 'requestID', 'phase'} and
                frame['state'] == 'ledger-snapshot', 'Invalid ledger snapshot schema')
        canonical_uuid(frame['requestID'])
        require(type(frame['phase']) is str and frame['phase'] in PHASES, 'Invalid ledger phase')
    return dict(frame)


def validate_native_reply(frame):
    keys = (native.RESULT_KEYS - {'ordinal'}) | {'requestID', 'phase'}
    require(type(frame) is dict and native.REQUIRED_KEYS <= frame.keys() <= keys,
            'Invalid native ledger result schema')
    # Validate the transport independently of the domain outcome.
    transport = {k: v for k, v in frame.items()
                 if k not in {'state', 'requestID', 'phase', 'fixtureError'}}
    native.validate_result(transport)
    require(frame.get('httpStatus') in {200, 400, 404, 409} and 'errorCode' not in frame and
            frame.get('tlsProtocol') == 772 and frame.get('proxy') is False and
            frame['trustRejected'] == 0 and frame['bodyBytes'] > 0 and
            not frame['overflow'] and not frame['redirectRejected'] and
            not frame['cancelledOnResponse'], 'Missing direct authenticated HTTP evidence')
    if 'fixtureError' in frame:
        require(type(frame['fixtureError']) is str and frame['fixtureError'] in ERRORS and
                not {'state', 'requestID', 'phase'} & frame.keys(), 'Ambiguous ledger denial')
    else:
        require({'state', 'requestID', 'phase'} <= frame.keys(), 'Missing ledger result fields')
        validate_ledger_reply({k: frame[k] for k in ('event', 'state', 'requestID', 'phase')})
        require(frame['httpStatus'] == 200, 'Ledger snapshot used a failure status')
    return dict(frame)


class LedgerNativePeer(native.NativePeer):
    def transfer(self, command):
        self.send(command)
        return validate_native_reply(self.read_frame(time.monotonic() + self.request_seconds))


class LedgerPeer(helper.JsonLinePeer):
    def ready(self):
        frame = self.read_frame(time.monotonic() + 5)
        require(set(frame) == {'event', 'sqliteVersion'} and frame['event'] == 'ready' and
                type(frame['sqliteVersion']) is str and 0 < len(frame['sqliteVersion']) <= 32,
                'Ledger startup failed')
        return frame['sqliteVersion']

    def accept_notification(self, _frame):
        raise helper.ProbeError('Unexpected ledger trailing frame')

    def finish(self, killed=False):
        failure = None
        try:
            if not killed:
                self.process.stdin.close()
                require(self.read_frame(time.monotonic() + 3) == {'event': 'closed'},
                        'Missing ledger close acknowledgement')
        except (ValueError, OSError, UnicodeError) as error:
            failure = error
        try:
            cleanup = super().close()
            require(cleanup['exitStatus'] == (-signal.SIGKILL if killed else 0) and
                    cleanup['streamsReachedEOF'] and cleanup['processGroupGone'] and
                    self.totals['stderr'] == 0, 'Ledger process cleanup failed')
        except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
            failure = failure or error
        if failure is not None:
            raise failure
        return cleanup


class LedgerBridge:
    """Trusted local fixture control, never an HTTP payload or production IPC protocol."""

    def __init__(self, executable, root, report):
        self.executable, self.root, self.report = executable, root, report
        self.lock, self.peer, self.round = threading.Lock(), None, 0

    def start(self, initialize):
        require(self.peer is None, 'Ledger process already owned')
        self.round += 1
        config = {'rootDirectory': str(self.root), 'initialize': initialize, 'hostID': HOST,
                  'projects': [PROJECT, OTHER_PROJECT], 'devices': [
                      {'fingerprint': network.fingerprint(self.root, name), 'deviceID': device,
                       'projectIDs': [PROJECT]}
                      for name, device in [('device-a', DEVICE_A), ('device-b', DEVICE_B)]]}
        path = self.root / ('ledger-config-' + str(self.round) + '.json')
        native.private_file(path, json.dumps(config).encode('utf-8'))
        record = {'round': self.round, 'initialized': initialize}
        self.report.setdefault('ledgerProcesses', []).append(record)
        self.peer = LedgerPeer([str(self.executable), str(path)], self.root,
                               {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'TMPDIR': str(self.root)},
                               request_seconds=5, total_seconds=120)
        record['sqliteVersion'] = self.peer.ready()

    def call(self, command):
        with self.lock:
            require(self.peer is not None, 'Ledger process unavailable')
            self.peer.send(command)
            return self.peer.read_frame(time.monotonic() + 5)

    def stop(self, killed=False):
        with self.lock:
            if self.peer is None:
                return
            peer, self.peer = self.peer, None
            failure = None
            try:
                if killed:
                    os.killpg(peer.process.pid, signal.SIGKILL)
                    peer.process.wait(timeout=3)
            except (OSError, subprocess.SubprocessError) as error:
                failure = error
            finally:
                try:
                    peer.finish(killed=killed)
                except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
                    failure = failure or error
                    self.report['ledgerProcesses'][-1]['cleanupFailureType'] = type(error).__name__
                finally:
                    record = self.report['ledgerProcesses'][-1]
                    record['killed'] = killed
                    record['cleanup'] = peer.cleanup
                    record['streams'] = {k: {'bytes': peer.totals[k], 'sha256': v.hexdigest()}
                                         for k, v in peer.digests.items()}
            if failure is not None:
                raise failure


class LedgerPolicy:
    def __init__(self, bridge):
        self.bridge, self.connections, self.results = bridge, 0, []
        self.failure = None

    def submit(self, fingerprint, body):
        return self.request('accept', fingerprint, body)

    def request(self, operation, fingerprint, body):
        # Fingerprint is supplied solely by FixtureHandler after CERT_REQUIRED TLS.
        try:
            require(operation in {'accept', 'snapshot'}, 'Unsupported HTTP operation')
            value = helper.strict_json(body)
            expected = {'requestID', 'projectID', 'payload'} if operation == 'accept' else {'requestID'}
            require(type(value) is dict and set(value) == expected, 'Invalid HTTP schema')
            canonical_uuid(value['requestID'])
            command = {'operation': operation, 'peerFingerprint': fingerprint,
                       'requestID': value['requestID']}
            if operation == 'accept':
                canonical_uuid(value['projectID'])
                require(type(value['payload']) is str and value['payload'].strip() and
                        len(value['payload'].encode('utf-8')) <= network.MAX_BODY,
                        'Invalid HTTP text')
                command.update(projectID=value['projectID'], text=value['payload'])
        except (ValueError, UnicodeError):
            return 400, {'error': 'invalid-request'}
        frame = validate_ledger_reply(self.bridge.call(command))
        require('error' in frame or frame['requestID'] == command['requestID'],
                'Uncorrelated ledger response')
        result = {k: v for k, v in frame.items() if k != 'event'}
        status = {'request-conflict': 409, 'invalid-request': 400,
                  'unknown-request': 404}.get(result.get('error'), 200)
        # Domain denial over200 is the versioned research candidate, never acceptance.
        self.results.append({'operation': operation, 'peerFingerprint': fingerprint,
                             'result': result, 'wireHTTPStatus': status})
        return status, result


class LedgerHTTPHandler(network.FixtureHandler):
    allowed_paths = ('/fixture/submit', '/fixture/snapshot')

    def handle_submission(self, fingerprint, body):
        try:
            return self.server.policy.request(
                'accept' if self.path == '/fixture/submit' else 'snapshot', fingerprint, body)
        except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
            # Keep a server-side failure even when BaseHTTPRequestHandler closes the socket.
            self.server.policy.failure = type(error).__name__
            raise


def ledger_rows(root):
    database = root / 'state/submissions.sqlite3'
    with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=2) as connection:
        require(connection.execute('PRAGMA quick_check(1)').fetchall() == [('ok',)],
                'Ledger integrity failed')
        rows = connection.execute('SELECT id,identity,phase FROM requests ORDER BY id').fetchall()
        devices = connection.execute('SELECT id,enabled FROM devices ORDER BY id').fetchall()
    require(database.stat().st_mode & 0o777 == 0o600, 'Ledger privacy mode changed')
    result = []
    for request_id, identity, phase in rows:
        value = json.loads(identity)
        require(value['requestID'] == request_id and value['hostID'] == HOST and
                value['projectID'] == PROJECT, 'Unexpected durable request identity')
        result.append({'requestID': request_id, 'deviceID': value['deviceID'], 'phase': phase,
                       'payloadDigest': value['payloadDigest']})
    require(TEXT.encode('utf-8') not in database.read_bytes(), 'Ledger persisted plaintext')
    return {'requests': result, 'devices': dict(devices)}


def check_native(report, root, policy, name, peer, *, request=REQUEST_A, path='submit',
                 project=PROJECT, text=TEXT, phase='accepted', error=None, count=1):
    record = {'name': name, 'source': 'native-https', 'connectionsBefore': policy.connections,
              'before': ledger_rows(root)}
    report['cases'].append(record)
    started = time.monotonic()
    frame = peer.transfer(native.command(path=path, requestID=request, projectID=project, payload=text))
    record.update(result=frame, connectionsAfter=policy.connections, after=ledger_rows(root),
                  roundTripSeconds=round(time.monotonic() - started, 6))
    require(policy.results[-1]['peerFingerprint'] == peer.fixture_fingerprint,
            'Server identity did not match the actual fixture client')
    if record['connectionsAfter'] != record['connectionsBefore']:
        require(frame['serverChallenges'] > 0 and frame['clientChallenges'] > 0,
                'New native connection lacks both authentication challenges')
    require(len(record['after']['requests']) == count, 'Unexpected durable request count')
    if error is not None:
        require(frame.get('fixtureError') == error and 'state' not in frame,
                'Expected ledger denial was not observed')
        require(record['before'] == record['after'], 'Denied request mutated durable authorization')
    else:
        require(frame.get('state') == 'ledger-snapshot' and frame.get('requestID') == request and
                frame.get('phase') == phase and 'fixtureError' not in frame,
                'Native result does not match expected ledger state')
        row = next(r for r in record['after']['requests'] if r['requestID'] == request)
        require(row['deviceID'] == peer.fixture_device and row['phase'] == phase and
                row['payloadDigest'] == hashlib.sha256(text.encode()).hexdigest(),
                'Native result differs from independent SQLite evidence')
    require(policy.failure is None, 'Server bridge failed')
    record['passed'] = True
    return record


@contextmanager
def client(executable, root, port, password, report, name, identity='device-a'):
    with native.native_peer(executable, root, port, password, report, name,
                            identity=identity, peer_class=LedgerNativePeer) as peer:
        peer.fixture_fingerprint = network.fingerprint(root, identity)
        peer.fixture_device = {'device-a': DEVICE_A, 'device-b': DEVICE_B}.get(identity)
        yield peer


def check_raw(report, root, policy, port, name, *, value=None, body=None, headers=None,
              identity='device-a', expected=(400, {'error': 'invalid-request'}), route=None):
    before = ledger_rows(root)
    with network.LoopbackClient(port, network.tls_context(root, identity=identity),
                                hostname='127.0.0.1') as peer:
        if route:
            peer.request('POST', route, body=b'{}', headers={'Content-Type': 'application/json'})
            reply = peer.getresponse()
            actual = reply.status, helper.strict_json(reply.read(network.MAX_RESPONSE + 1))
        else:
            actual = peer.submit(value, body, headers)
    after = ledger_rows(root)
    record = {'name': name, 'source': 'raw-https', 'httpStatus': actual[0], 'result': actual[1],
              'before': before, 'after': after}
    report['cases'].append(record)
    require(actual == expected and before == after and policy.failure is None,
            'Raw request crossed the identity/admin boundary')
    record['passed'] = True


def check_claim(report, bridge, root, request, *, phase, send):
    frame = bridge.call({'operation': 'claim', 'peerFingerprint': network.fingerprint(root, 'device-b'),
                         'requestID': request, 'projectID': PROJECT, 'text': TEXT})
    require(frame == {'event': 'result', 'state': 'ledger-claim', 'requestID': request,
                      'phase': phase, 'send': send} and type(frame['send']) is bool,
            'Local claim did not preserve dispatch uncertainty')
    rows = ledger_rows(root)
    require(next(row['phase'] for row in rows['requests'] if row['requestID'] == request) == phase,
            'Local claim differs from SQLite phase')
    report.setdefault('localClaims', []).append({'result': frame, 'ledger': rows})


def run_cases(native_executable, bridge, root, password, report):
    bridge.start(initialize=True)
    policy = LedgerPolicy(bridge)
    state = native.NativeFixtureState()
    server_record = {}
    report['servers'] = [server_record]
    context = native.observed_server_context(root, state)
    with network.running_server(context, policy, server_record, handler=LedgerHTTPHandler) as port:
        with client(native_executable, root, port, password, report, 'unknown', 'unknown') as peer:
            check_native(report, root, policy, 'unregistered-certificate', peer, error='unauthorized', count=0)
        with client(native_executable, root, port, password, report, 'persistent-a') as peer:
            check_native(report, root, policy, 'cross-project-denial', peer, project=OTHER_PROJECT,
                         error='unauthorized', count=0)
            check_native(report, root, policy, 'durable-acceptance', peer)
            check_native(report, root, policy, 'duplicate-acceptance', peer)
            check_native(report, root, policy, 'conflicting-payload', peer,
                         text='Changed synthetic input', error='request-conflict')
            check_native(report, root, policy, 'authorized-snapshot', peer, path='snapshot')
            check_native(report, root, policy, 'unknown-snapshot', peer, path='snapshot',
                         request=MISSING, error='unknown-request')
            claim = bridge.call({'operation': 'claim', 'peerFingerprint': network.fingerprint(root, 'device-a'),
                                 'requestID': REQUEST_A, 'projectID': PROJECT, 'text': TEXT})
            require(claim == {'event': 'result', 'state': 'ledger-claim', 'requestID': REQUEST_A,
                              'phase': 'dispatching', 'send': True}, 'Local claim failed')
            check_native(report, root, policy, 'claimed-state-visible', peer, path='snapshot', phase='dispatching')
            check_native(report, root, policy, 'claimed-retry-no-redispatch', peer, phase='dispatching')
            connection = policy.connections
            require(bridge.call({'operation': 'revoke', 'deviceID': DEVICE_A}) == {'event': 'revoked'},
                    'Local revocation failed')
            check_native(report, root, policy, 'existing-connection-revoked-read', peer,
                         path='snapshot', error='unauthorized')
            check_native(report, root, policy, 'existing-connection-revoked-retry', peer, error='unauthorized')
            check_native(report, root, policy, 'existing-connection-revoked-new-request', peer,
                         request=MISSING, error='unauthorized')
            require(policy.connections == connection, 'Revocation was not tested on the existing connection')
        with client(native_executable, root, port, password, report, 'revoked-new-connection') as peer:
            check_native(report, root, policy, 'revoked-new-connection', peer, error='unauthorized')
        with client(native_executable, root, port, password, report, 'device-b', 'device-b') as peer:
            check_native(report, root, policy, 'cross-device-replay', peer, error='unauthorized')
            check_native(report, root, policy, 'cross-device-read', peer, path='snapshot', error='unauthorized')
            check_native(report, root, policy, 'second-device-acceptance', peer, request=REQUEST_B, count=2)
            check_native(report, root, policy, 'accepted-request-before-restart', peer,
                         request=REQUEST_C, count=3)
        check_claim(report, bridge, root, REQUEST_B, phase='dispatching', send=True)
        check_claim(report, bridge, root, REQUEST_B, phase='dispatching', send=False)
        value = {'requestID': MISSING, 'projectID': PROJECT, 'payload': TEXT}
        check_raw(report, root, policy, port, 'forged-body-device', value=dict(value, deviceID=DEVICE_B))
        check_raw(report, root, policy, port, 'forged-body-fingerprint',
                  value=dict(value, peerFingerprint=network.fingerprint(root, 'device-b')))
        check_raw(report, root, policy, port, 'forged-header-device', identity='unknown', value=value,
                  headers={'Content-Type': 'application/json', 'X-Munie-Device': DEVICE_B},
                  expected=(200, {'error': 'unauthorized'}))
        check_raw(report, root, policy, port, 'duplicate-json-identity',
                  body=(f'{{"requestID":"{MISSING}","requestID":"{MISSING}",'
                        f'"projectID":"{PROJECT}","payload":"{TEXT}"}}').encode('utf-8'))
        for operation in ('revoke', 'claim'):
            check_raw(report, root, policy, port, 'no-remote-' + operation,
                      route='/fixture/' + operation, expected=(404, {'error': 'fixture-route'}))
        # Kill with two dispatching records and one accepted record. No model/tool is run.
        bridge.stop(killed=True)
        bridge.start(initialize=False)
        rows = ledger_rows(root)
        require([r['phase'] for r in rows['requests']] == ['reconciling', 'reconciling', 'accepted'] and
                rows['devices'][DEVICE_A] == 0, 'Restart lost uncertainty or revived a revoked device')
        check_claim(report, bridge, root, REQUEST_B, phase='reconciling', send=False)
        with client(native_executable, root, port, password, report, 'revoked-after-restart') as peer:
            check_native(report, root, policy, 'restart-revocation-persists', peer, error='unauthorized', count=3)
        with client(native_executable, root, port, password, report, 'b-after-restart', 'device-b') as peer:
            check_native(report, root, policy, 'restart-cross-device-read', peer,
                         path='snapshot', error='unauthorized', count=3)
            check_native(report, root, policy, 'restart-uncertain-retry', peer,
                         request=REQUEST_B, phase='reconciling', count=3)
            check_native(report, root, policy, 'restart-uncertain-snapshot', peer,
                         request=REQUEST_B, path='snapshot', phase='reconciling', count=3)
            check_native(report, root, policy, 'restart-accepted-retry', peer, request=REQUEST_C, count=3)
    report['connections'] = policy.connections
    report['serverPolicyResponses'] = policy.results
    report['finalLedger'] = ledger_rows(root)
    require(policy.failure is None, 'Server bridge had a recorded failure')


def experiment(native_executable, ledger_executable, openssl, report):
    report['failureCode'] = 'preflight'
    require(native.platform.system() == 'Darwin' and native.ssl.HAS_TLSv1_3, 'Unsupported runtime')
    for path in (native_executable, ledger_executable, openssl):
        require(path.is_absolute() and path.is_file() and os.access(path, os.X_OK),
                'Select explicit executable paths')
    native.record_metadata(native_executable, openssl, report)
    repository = Path(__file__).resolve().parent.parent
    for key, path in [('ledgerExecutableSHA256', ledger_executable), ('ledgerRunnerSHA256', Path(__file__)),
                      ('ledgerSourceSHA256', repository / 'apps/MunieHost/LedgerNetworkProbe/MunieLedgerNetworkProbe.swift')]:
        report[key] = hashlib.sha256(path.read_bytes()).hexdigest()
    report['ledgerSources'] = {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest()
                               for path in sorted((repository / 'apps/MunieHost/LedgerNetworkProbe').glob('*.swift'))}
    report['scope'] = ('Actual macOS URLSession/Security to loopback CERT_REQUIRED TLS peer certificate '
                       'mapping and real SQLite HostSubmissionLedger. The local Python/stdio bridge '
                       'is trusted fixture control, not production IPC or pairing. Temporary identities '
                       'and synthetic inputs only; no Codex, model, tool, mobile app, service or WAN.')
    report['cases'], report['peers'] = [], []
    temporary_path = None
    try:
        with tempfile.TemporaryDirectory(prefix='munie-ledger-mtls-') as temporary:
            root = Path(temporary).resolve()
            temporary_path = root
            password = native.prepare_native_certificates(openssl, root)
            report['fixtureIdentityFingerprints'] = {name: network.fingerprint(root, name)
                                                    for name in ('device-a', 'device-b', 'unknown')}
            (root / 'projects').mkdir(mode=0o700)
            for project in (PROJECT, OTHER_PROJECT):
                (root / 'projects' / project).mkdir(mode=0o700)
            bridge = LedgerBridge(ledger_executable, root, report)
            primary_error = None
            try:
                report['failureCode'] = 'ledger-network-cases'
                run_cases(native_executable, bridge, root, password, report)
            except BaseException as error:
                primary_error = error
                raise
            finally:
                try:
                    bridge.stop()
                except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
                    report['ledgerCleanupFailureType'] = type(error).__name__
                    if primary_error is None:
                        raise
    finally:
        report['temporaryCredentialsAndLedgerRemoved'] = temporary_path is not None and not temporary_path.exists()
    require(report['temporaryCredentialsAndLedgerRemoved'] and
            tuple(case['name'] for case in report['cases']) == EXPECTED_CASES and
            all(case.get('passed') for case in report['cases']), 'Incomplete ledger network evidence')
    report.pop('failureCode', None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-executable', type=Path, required=True)
    parser.add_argument('--ledger-executable', type=Path, required=True)
    parser.add_argument('--openssl', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = {'reportVersion': 1, 'status': 'failed', 'phase': 'starting',
              'capturedAtUTC': datetime.now(timezone.utc).isoformat()}
    helper.write_report(args.output, report)
    status = 1
    try:
        report['phase'] = 'authenticated-ledger-loopback'
        experiment(args.native_executable, args.ledger_executable, args.openssl, report)
        report['status'], report['phase'], status = 'passed', 'complete', 0
    except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
        report['failureType'] = type(error).__name__
        print('Ledger network experiment failed: ' + type(error).__name__, file=sys.stderr)
    finally:
        helper.write_report(args.output, report)
    if status == 0:
        print('PASS authenticated SQLite ledger loopback: ' + str(len(report['cases'])) +
              ' cases; no Agent, model or WAN.')
    return status


if __name__ == '__main__':
    sys.exit(main())
