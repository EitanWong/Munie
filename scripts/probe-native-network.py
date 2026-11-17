#!/usr/bin/env python3
"""Opt-in macOS URLSession + loopback mTLS experiment with temporary identities only."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time

SPEC = importlib.util.spec_from_file_location(
    'native_network_fixture', Path(__file__).with_name('probe-authenticated-network.py'))
network = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(network)
helper = network.helper
require = helper.require
REQUEST_SECONDS = 8
RESULT_KEYS = {
    'event', 'bodyBytes', 'overflow', 'redirectRejected', 'serverChallenges', 'clientChallenges',
    'trustRejected', 'httpStatus', 'errorCode', 'tlsProtocol', 'proxy', 'state', 'ordinal', 'fixtureError',
    'cancelledOnResponse',
}
REQUIRED_KEYS = {
    'event', 'bodyBytes', 'overflow', 'redirectRejected', 'serverChallenges', 'clientChallenges',
    'trustRejected', 'cancelledOnResponse',
}
FIXTURE_ERRORS = {'device-denied', 'project-denied', 'request-conflict', 'fixture-capacity'}


def validate_result(frame):
    """Validate before retaining a peer field; raw frames never enter the report."""
    require(type(frame) is dict and REQUIRED_KEYS <= frame.keys() <= RESULT_KEYS,
            'Unexpected native result schema')
    require(frame['event'] == 'result', 'Unexpected native event')
    require(type(frame['bodyBytes']) is int and 0 <= frame['bodyBytes'] <= network.MAX_RESPONSE,
            'Invalid native response byte count')
    for key in ('overflow', 'redirectRejected', 'proxy', 'cancelledOnResponse'):
        if key in frame:
            require(type(frame[key]) is bool, 'Invalid native Boolean')
    for key in ('serverChallenges', 'clientChallenges', 'trustRejected'):
        require(type(frame[key]) is int and 0 <= frame[key] <= 4, 'Invalid challenge count')
    require(frame['trustRejected'] <= frame['serverChallenges'], 'Inconsistent trust rejection')
    for key in ('httpStatus', 'errorCode', 'tlsProtocol', 'ordinal'):
        if key in frame:
            require(type(frame[key]) is int, 'Invalid native integer')
    if 'httpStatus' in frame:
        require(100 <= frame['httpStatus'] <= 599, 'Invalid HTTP status')
    if 'tlsProtocol' in frame:
        require(frame['tlsProtocol'] == 772, 'Native transport did not use TLS 1.3')
    require(frame.get('proxy') is not True, 'Native transport used a proxy')
    require(('state' in frame) == ('ordinal' in frame), 'Incomplete acceptance evidence')
    if 'state' in frame:
        require(frame['state'] == 'fixture-accepted' and
                1 <= frame['ordinal'] <= network.MAX_ACCEPTED, 'Invalid fixture acceptance')
        require('fixtureError' not in frame and 'errorCode' not in frame and
                not frame['overflow'] and not frame['redirectRejected'] and
                not frame['cancelledOnResponse'], 'Ambiguous acceptance')
    if 'fixtureError' in frame:
        require(type(frame['fixtureError']) is str and frame['fixtureError'] in FIXTURE_ERRORS and
                'errorCode' not in frame and
                not frame['overflow'] and not frame['redirectRejected'], 'Invalid fixture error')
    return dict(frame)


def expect_http(frame, status, *, ordinal=None, error=None):
    require(frame.get('httpStatus') == status and 'errorCode' not in frame and
            frame.get('tlsProtocol') == 772 and frame.get('proxy') is False and
            frame['bodyBytes'] > 0 and not frame['overflow'] and not frame['redirectRejected'] and
            not frame['cancelledOnResponse'] and frame['trustRejected'] == 0,
            'Unexpected native HTTP outcome')
    if ordinal is not None:
        require(frame.get('state') == 'fixture-accepted' and frame.get('ordinal') == ordinal and
                'fixtureError' not in frame, 'Unexpected native acceptance')
    else:
        require(frame.get('fixtureError') == error and 'state' not in frame,
                'Unexpected native policy denial')


def expect_tls_rejection(frame, *, trust=False, missing=False, server_rejected=False):
    require('httpStatus' not in frame and 'state' not in frame and 'fixtureError' not in frame and
            frame['bodyBytes'] == 0 and not frame['overflow'] and not frame['redirectRejected'] and
            not frame['cancelledOnResponse'],
            'Rejected TLS peer reached HTTP')
    if trust:
        require(frame.get('errorCode') in {-999, -1202} and frame['serverChallenges'] > 0 and
                frame['trustRejected'] > 0, 'Missing server-trust rejection evidence')
    else:
        codes = {-999, -1200, -1205, -1206} | ({-1005} if server_rejected else set())
        require(frame.get('errorCode') in codes and
                frame['clientChallenges'] > 0 and frame['trustRejected'] == 0,
                'Missing client-certificate rejection evidence')
        if not missing:
            require(frame['serverChallenges'] > 0, 'Missing server-trust challenge')


class NativePeer(helper.JsonLinePeer):
    """One native process owns one URLSession until a verified EOF/invalidation handshake."""

    def __init__(self, command, cwd, environment):
        self.closed_frame = False
        self.close_failure = None
        super().__init__(command, cwd, environment, request_seconds=REQUEST_SECONDS, total_seconds=60)

    def ready(self, identity):
        frame = self.read_frame(time.monotonic() + self.request_seconds)
        require(frame == {'event': 'ready', 'memoryOnlyIdentity': identity} and
                type(frame.get('memoryOnlyIdentity')) is bool, 'Native startup/identity failed')

    def transfer(self, command):
        self.send(command)
        return validate_result(self.read_frame(time.monotonic() + self.request_seconds))

    def accept_notification(self, _frame):
        raise helper.ProbeError('Unexpected native trailing frame')

    def close(self):
        if self.cleanup is not None:
            if self.close_failure is not None:
                raise self.close_failure
            return self.cleanup
        failure = None
        try:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
            frame = self.read_frame(time.monotonic() + 3)
            require(frame == {'event': 'closed', 'sessionInvalidated': True} and
                    type(frame.get('sessionInvalidated')) is bool, 'Missing session invalidation')
            self.closed_frame = True
        except (ValueError, OSError, UnicodeError) as error:
            failure = error
        # Drain/reap/group checks must run even when startup, a result or invalidation failed.
        try:
            cleanup = super().close()
            require(cleanup['exitStatus'] == 0 and cleanup['streamsReachedEOF'] and
                    cleanup['processGroupGone'], 'Native process did not close cleanly')
        except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
            failure = failure or error
        self.close_failure = failure
        if failure is not None:
            raise failure
        return self.cleanup


def private_file(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(data)


def prepare_native_certificates(openssl, root):
    old_umask = os.umask(0o077)
    try:
        network.make_certificates(openssl, root)
        # Preserve the DNS-only server leaf as the literal wrong-IP-name control.
        for suffix in ('pem', 'key'):
            shutil.copyfile(root / ('server.' + suffix), root / ('wrong-server.' + suffix))
        config = root / 'server.cnf'
        config.write_text(config.read_text(encoding='utf-8').replace(
            'subjectAltName=DNS:localhost', 'subjectAltName=IP:127.0.0.1'), encoding='utf-8')
        network.openssl_run(openssl, root, 'x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem',
                            '-CAkey', 'ca.key', '-set_serial', '11', '-days', '1', '-sha256',
                            '-extfile', 'server.cnf', '-extensions', 'leaf', '-out', 'server.pem')
        for name in ('ca', 'untrusted-ca'):
            network.openssl_run(openssl, root, 'x509', '-in', name + '.pem',
                                '-outform', 'DER', '-out', name + '.der')
        password = secrets.token_urlsafe(24)
        private_file(root / 'p12-password', password.encode('ascii'))
        for name in ('device-a', 'device-b', 'unknown', 'untrusted'):
            ca = 'untrusted-ca' if name == 'untrusted' else 'ca'
            # Use the selected OpenSSL defaults first; never silently relax identity encryption.
            network.openssl_run(openssl, root, 'pkcs12', '-export', '-in', name + '.pem',
                                '-inkey', name + '.key', '-certfile', ca + '.pem',
                                '-name', 'synthetic-' + name, '-passout',
                                'file:' + str(root / 'p12-password'), '-out', name + '.p12')
        for path in root.iterdir():
            path.chmod(0o600)
        return password
    finally:
        os.umask(old_umask)


@contextmanager
def native_peer(executable, root, port, password, report, name, identity='device-a', ca='ca'):
    configuration = {'port': port, 'caDERPath': str(root / (ca + '.der'))}
    if identity is not None:
        configuration.update(identityPKCS12Path=str(root / (identity + '.p12')), passphrase=password)
    config_path = root / ('native-' + name + '.json')
    private_file(config_path, json.dumps(configuration).encode('utf-8'))
    fixture_tmp = root / ('fixturetmp-' + name)
    fixture_tmp.mkdir(mode=0o700)
    environment = {'PATH': '/usr/bin:/bin', 'LANG': 'C', 'TMPDIR': str(fixture_tmp)}
    record = {'name': name, 'sessionInvalidated': False}
    report.setdefault('peers', []).append(record)
    peer, primary_error = None, None
    try:
        report['failureCode'] = 'native-startup'
        peer = NativePeer([str(executable), str(config_path)], root, environment)
        peer.ready(identity is not None)
        record['memoryOnlyIdentity'] = identity is not None
        yield peer
    except BaseException as error:
        primary_error = error
        record['failureType'] = type(error).__name__
        raise
    finally:
        if peer is not None:
            try:
                peer.close()
            except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
                record['cleanupFailureType'] = type(error).__name__
                if primary_error is None:
                    raise
            finally:
                record['sessionInvalidated'] = peer.closed_frame
                record['cleanup'] = peer.cleanup
                record['streams'] = {
                    key: {'bytes': peer.totals[key], 'sha256': digest.hexdigest()}
                    for key, digest in peer.digests.items()
                }


class NativeFixtureState:
    def __init__(self):
        self.hits = {}
        self.certificate_rejections = []
        self.policy_responses = []
        self.lock = threading.Lock()
        self.slow_started = threading.Event()
        self.release_slow = threading.Event()
        self.cancel_started = threading.Event()
        self.cancel_prefix_sent = threading.Event()
        self.release_cancel = threading.Event()

    def hit(self, route):
        with self.lock:
            self.hits[route] = self.hits.get(route, 0) + 1

    def snapshot(self):
        with self.lock:
            return dict(self.hits)

    def rejection_codes(self):
        with self.lock:
            return list(self.certificate_rejections)

    def policy_results(self):
        with self.lock:
            return list(self.policy_responses)


def observed_server_context(root, state):
    class ObservedSocket(ssl.SSLSocket):
        def do_handshake(self, *args, **kwargs):
            try:
                return super().do_handshake(*args, **kwargs)
            except ssl.SSLCertVerificationError as error:
                with state.lock:
                    state.certificate_rejections.append(error.verify_code)
                raise

    context = network.tls_context(root, server=True)
    context.sslsocket_class = ObservedSocket
    return context


def native_handler(state, policy_envelope=True):
    class Handler(network.FixtureHandler):
        def send_result(self, status, value, close=False):
            wire_status = status
            if self.path == '/fixture/submit':
                if status == 403 and policy_envelope:
                    require(value in ({'error': 'device-denied'}, {'error': 'project-denied'}),
                            'Unexpected policy denial')
                    # Research candidate informed by the local403/-1206 observation below.
                    # HTTP200 does not imply acceptance; only the fixed state+ordinal can do that.
                    wire_status, close = 200, False
                with state.lock:
                    state.policy_responses.append({'policyStatus': status, 'wireHTTPStatus': wire_status,
                                                   'result': dict(value)})
            return super().send_result(wire_status, value, close)

        def do_GET(self):
            state.hit('redirect-target' if self.path == '/fixture/redirect-target' else 'unexpected')
            self.send_result(403, {'error': 'device-denied'}, close=True)

        def do_POST(self):
            if self.path == '/fixture/submit':
                state.hit('submit')
                return super().do_POST()
            if self.path == '/fixture/redirect-target':
                state.hit('redirect-target')
                self.send_result(403, {'error': 'device-denied'}, close=True)
                return
            route = self.path.removeprefix('/fixture/')
            require(route in {'redirect', 'oversized', 'slow'}, 'Unexpected fixture route')
            lengths = self.headers.get_all('Content-Length', [])
            require(len(lengths) == 1 and lengths[0].isascii() and lengths[0].isdigit() and
                    len(lengths[0]) <= 6 and self.headers.get('Transfer-Encoding') is None and
                    self.headers.get('Content-Type') == 'application/json', 'Invalid fixture framing')
            length = int(lengths[0])
            require(0 < length <= network.MAX_BODY, 'Fixture request too large')
            deadline, body = time.monotonic() + network.IO_SECONDS, bytearray()
            while len(body) < length:
                remaining = deadline - time.monotonic()
                require(remaining > 0, 'Fixture body deadline')
                self.connection.settimeout(remaining)
                part = self.rfile.read1(length - len(body))
                require(bool(part), 'Incomplete fixture body')
                body.extend(part)
            value = helper.strict_json(bytes(body))
            require(type(value) is dict and set(value) == {'requestID', 'projectID', 'payload'} and
                    all(type(item) is str and 0 < len(item.encode('utf-8')) <= 256
                        for item in value.values()) and value['projectID'] == network.PROJECT,
                    'Invalid special fixture request')
            fingerprint = hashlib.sha256(self.connection.getpeercert(binary_form=True)).hexdigest()
            require(fingerprint in self.server.policy.devices and
                    fingerprint not in self.server.policy.revoked, 'Unauthorized special route')
            cancelling = route == 'slow' and self.headers.get('X-Munie-Fixture-Cancel') == 'after-response'
            state.hit('cancel-on-response' if cancelling else route)
            if route == 'slow':
                if cancelling:
                    state.cancel_started.set()
                    self.send_response_only(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', '2')
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    # Headers-only control timed out without a response callback on this runtime;
                    # send a prefix while withholding body completion.
                    self.wfile.write(b'{')
                    self.wfile.flush()
                    state.cancel_prefix_sent.set()
                    self.close_connection = True
                    state.release_cancel.wait(REQUEST_SECONDS)
                    self.wfile.write(b'}')
                    self.wfile.flush()
                else:
                    state.slow_started.set()
                    state.release_slow.wait(REQUEST_SECONDS)
                    self.send_result(200, {'state': 'fixture-accepted', 'ordinal': 1}, close=True)
            elif route == 'oversized':
                self.send_response_only(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(network.MAX_RESPONSE * 2))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.close_connection = True
                self.wfile.write(b'x' * (network.MAX_RESPONSE * 2))
                self.wfile.flush()
            else:
                self.send_response_only(307)
                self.send_header('Location', 'https://127.0.0.1:' + str(self.server.server_port) +
                                 '/fixture/redirect-target')
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', '2')
                self.end_headers()
                self.wfile.write(b'{}')
                self.wfile.flush()

    return Handler


def command(**changes):
    return {'path': 'submit', 'requestID': 'synthetic-1', 'projectID': network.PROJECT,
            'payload': 'synthetic-task', 'cancel': False, **changes}


def check(report, policy, name, peer, validate, *, acceptance_delta=0, **changes):
    report['failureCode'] = 'native-case-validation'
    case = {'name': name, 'acceptedBefore': len(policy.accepted),
            'connectionsBefore': policy.connections}
    report['cases'].append(case)
    frame = peer.transfer(command(**changes))
    case.update(result=frame, acceptedAfter=len(policy.accepted), connectionsAfter=policy.connections)
    validate(frame)
    require(case['acceptedAfter'] == case['acceptedBefore'] + acceptance_delta,
            'Unexpected acceptance count transition')
    case['passed'] = True
    return frame


def expect_transport_control(frame, kind):
    require('state' not in frame and 'fixtureError' not in frame and frame['trustRejected'] == 0 and
            frame.get('tlsProtocol') == 772 and frame.get('proxy') is False,
            'Transport control produced policy acceptance')
    if kind == 'redirect':
        require(frame.get('httpStatus') == 307 and frame['redirectRejected'] and
                not frame['overflow'] and 'errorCode' not in frame and
                frame.get('tlsProtocol') == 772 and frame.get('proxy') is False,
                'Redirect was not explicitly rejected')
    elif kind == 'oversized':
        require(frame.get('httpStatus') == 200 and frame['overflow'] and
                frame.get('errorCode') == -999 and frame['bodyBytes'] == 0 and
                not frame['redirectRejected'], 'Oversized response was not bounded at headers')
    elif kind == 'slow':
        require(frame.get('errorCode') == -1001 and
                'httpStatus' not in frame and frame['bodyBytes'] == 0 and
                not frame['overflow'] and not frame['redirectRejected'] and
                not frame['cancelledOnResponse'], 'Missing exact timeout evidence')
    else:
        require(kind == 'inflight-response-cancel' and frame.get('errorCode') == -999 and
                frame.get('httpStatus') == 200 and frame['bodyBytes'] == 0 and
                frame['cancelledOnResponse'] and not frame['overflow'] and
                not frame['redirectRejected'] and frame.get('tlsProtocol') == 772 and
                frame.get('proxy') is False, 'Missing in-flight cancellation evidence')


def expect_legacy_denial(frame):
    require(frame.get('errorCode') == -1206 and 'httpStatus' not in frame and
            'state' not in frame and 'fixtureError' not in frame and frame['bodyBytes'] == 0 and
            not frame['overflow'] and not frame['redirectRejected'] and not frame['cancelledOnResponse'] and
            frame['trustRejected'] == 0 and frame['serverChallenges'] > 0 and
            frame['clientChallenges'] > 0 and frame.get('tlsProtocol') == 772 and
            frame.get('proxy') is False, 'Legacy403 did not reproduce the observed native mapping')


def run_cases(executable, root, password, policy, report):
    state = NativeFixtureState()
    report['servers'] = []
    wrong_context = network.tls_context(root, server=True)
    wrong_context.load_cert_chain(str(root / 'wrong-server.pem'), str(root / 'wrong-server.key'))
    wrong_server = {'name': 'wrong-hostname'}
    report['servers'].append(wrong_server)
    with network.running_server(wrong_context, policy, wrong_server) as port:
        with native_peer(executable, root, port, password, report, 'wrong-hostname') as peer:
            check(report, policy, 'wrong-hostname', peer,
                  lambda frame: expect_tls_rejection(frame, trust=True))
    require(not policy.accepted, 'Wrong-hostname control accepted a request')
    legacy = {'name': 'legacy-http403-control'}
    report['servers'].append(legacy)
    with network.running_server(observed_server_context(root, state), policy, legacy,
                                handler=native_handler(state, policy_envelope=False)) as port:
        with native_peer(executable, root, port, password, report,
                         'legacy-http403-control', identity='unknown') as peer:
            check(report, policy, 'http403-native-mapping-control', peer, expect_legacy_denial)
            require(state.policy_results() == [{'policyStatus': 403, 'wireHTTPStatus': 403,
                                                'result': {'error': 'device-denied'}}] and
                    not policy.accepted, 'Legacy403 policy evidence differs')
    report['policyEncoding'] = {
        'candidateOnly': True, 'productionSelected': False,
        'nativeLimitation': 'On the recorded local runtime, HTTP403 after mutual TLS returned '
                            'URLError -1206 without HTTP/body; cause and other runtimes are unverified.',
        'candidate': 'Policy403 device/project denials use HTTP200 plus a fixed error envelope; '
                     'acceptance requires state and ordinal. Conflicts retain HTTP409.',
    }
    server = {'name': 'valid-ip-hostname'}
    report['servers'].append(server)
    try:
        with network.running_server(observed_server_context(root, state), policy, server,
                                    handler=native_handler(state)) as port:
            for name, identity, ca in (
                    ('untrusted-server', 'device-a', 'untrusted-ca'),
                    ('missing-client', None, 'ca'), ('untrusted-client', 'untrusted', 'ca'),
                    ('unenrolled-client', 'unknown', 'ca')):
                with native_peer(executable, root, port, password, report, name, identity, ca) as peer:
                    rejections_before = len(state.rejection_codes())
                    if name == 'unenrolled-client':
                        validate = lambda frame: expect_http(frame, 200, error='device-denied')
                    else:
                        validate = lambda frame: expect_tls_rejection(
                            frame, trust=name == 'untrusted-server', missing=name == 'missing-client',
                            server_rejected=len(state.rejection_codes()) > rejections_before)
                    check(report, policy, name, peer, validate)
                    if name == 'untrusted-client':
                        codes = state.rejection_codes()
                        require(len(codes) == rejections_before + 1 and codes[-1] in {18, 19, 20, 21},
                                'Missing server rejection of untrusted client CA')
                        report['cases'][-1]['serverCertificateVerifyCode'] = codes[-1]
                require(not policy.accepted, 'Negative control accepted a request')
            with native_peer(executable, root, port, password, report, 'persistent-session') as peer:
                first = check(report, policy, 'first-acceptance', peer,
                              lambda frame: expect_http(frame, 202, ordinal=1), acceptance_delta=1)
                require(first['serverChallenges'] > 0 and first['clientChallenges'] > 0,
                        'Missing native mutual-authentication challenges')
                established_connections = policy.connections
                check(report, policy, 'same-request-retry', peer,
                      lambda frame: expect_http(frame, 200, ordinal=1))
                check(report, policy, 'conflicting-payload', peer,
                      lambda frame: expect_http(frame, 409, error='request-conflict'), payload='changed')
                check(report, policy, 'unauthorized-project', peer,
                      lambda frame: expect_http(frame, 200, error='project-denied'), projectID='other-project')
                require(policy.connections == established_connections,
                        'Positive session did not reuse its authenticated connection')
                policy.revoked.add(network.fingerprint(root, 'device-a'))
                check(report, policy, 'existing-connection-revocation', peer,
                      lambda frame: expect_http(frame, 200, error='device-denied'),
                      requestID='fresh-after-revocation')
                require(policy.connections == established_connections,
                        'Revocation was not checked on the established connection')
                check(report, policy, 'revoked-request-retry', peer,
                      lambda frame: expect_http(frame, 200, error='device-denied'))
                require(policy.connections == established_connections,
                        'Revoked retry did not reuse its authenticated connection')
            with native_peer(executable, root, port, password, report,
                             'cross-device-replay', identity='device-b') as peer:
                check(report, policy, 'cross-device-replay', peer,
                      lambda frame: expect_http(frame, 409, error='request-conflict'))
            # Transport controls use the still-enrolled second identity, without policy submissions.
            for route in ('redirect', 'oversized', 'slow', 'inflight-response-cancel'):
                with native_peer(executable, root, port, password, report, route,
                                 identity='device-b') as peer:
                    started = time.monotonic()
                    try:
                        frame = check(report, policy, route, peer,
                              lambda frame: expect_transport_control(frame, route),
                              path='slow' if route == 'inflight-response-cancel' else route,
                              requestID='transport-control', cancel=route == 'inflight-response-cancel')
                        if route == 'slow':
                            elapsed = time.monotonic() - started
                            report['timeout'] = {'serverReceivedRequest': state.slow_started.is_set(),
                                                 'elapsedSeconds': round(elapsed, 3)}
                            require(state.slow_started.is_set() and 2 <= elapsed < REQUEST_SECONDS,
                                    'Timeout occurred without an active transfer')
                        elif route == 'inflight-response-cancel':
                            report['cancellation'] = {
                                'serverReceivedRequest': state.cancel_started.is_set(),
                                'cancelledAtResponseHeaders': True,
                                'wirePrefixBytes': 1 if state.cancel_prefix_sent.is_set() else 0,
                                'advertisedBodyBytes': 2,
                                'nativeBodyBytes': frame['bodyBytes'],
                                'acceptedCount': len(policy.accepted),
                            }
                            require(state.cancel_started.is_set() and state.cancel_prefix_sent.is_set(),
                                    'Cancellation occurred without an active transfer')
                    finally:
                        if route == 'slow':
                            state.release_slow.set()
                        elif route == 'inflight-response-cancel':
                            state.release_cancel.set()
                require(len(policy.accepted) == 1, 'Transport control changed acceptance policy')
            report['routeHits'] = state.snapshot()
            require(report['routeHits'].get('redirect-target', 0) == 0,
                    'Native client followed a forbidden redirect')
            require(all(report['routeHits'].get(route) == 1
                        for route in ('redirect', 'oversized', 'slow', 'cancel-on-response')),
                    'Transport fixture did not observe the intended requests')
    finally:
        state.release_slow.set()
        state.release_cancel.set()
        report['connections'] = policy.connections
        report['acceptedCount'] = len(policy.accepted)
        report['routeHits'] = state.snapshot()
        report['serverCertificateRejectionCodes'] = state.rejection_codes()
        report['serverPolicyResponses'] = state.policy_results()


def record_metadata(executable, openssl, report):
    repository = Path(__file__).resolve().parent.parent
    report['runtime'] = {
        'python': sys.version, 'executable': sys.executable, 'ssl': ssl.OPENSSL_VERSION,
        'macOS': platform.mac_ver()[0], 'darwin': platform.release(),
        'openssl': subprocess.check_output(
            [str(openssl), 'version'], text=True, stderr=subprocess.PIPE, timeout=5,
            env={'PATH': '/usr/bin:/bin', 'LANG': 'C', 'OPENSSL_CONF': os.devnull}).strip(),
    }
    for label, path in (
            ('runnerSHA256', Path(__file__)), ('nativeExecutableSHA256', executable),
            ('nativeSourceSHA256', repository / 'apps/MunieHost/NetworkProbe/MunieNativeNetworkProbe.swift'),
            ('networkFixtureSHA256', Path(network.__file__)), ('helperSHA256', Path(helper.__file__))):
        report[label] = hashlib.sha256(path.read_bytes()).hexdigest()
    report['sourceRevision'] = subprocess.check_output(
        ['/usr/bin/git', 'rev-parse', 'HEAD'], cwd=repository, text=True, timeout=5).strip()
    report['workingTreeDirty'] = bool(subprocess.check_output(
        ['/usr/bin/git', 'status', '--porcelain'], cwd=repository, text=True, timeout=5).strip())


def experiment(executable, openssl, report):
    report['failureCode'] = 'unsupported-runtime'
    require(platform.system() == 'Darwin', 'Native experiment requires macOS')
    require(ssl.HAS_TLSv1_3, 'Select a Python runtime with TLS 1.3')
    for path in (executable, openssl):
        require(path.is_absolute() and path.is_file() and os.access(path, os.X_OK),
                'Select explicit executable paths')
    report['failureCode'] = 'runtime-metadata'
    record_metadata(executable, openssl, report)
    report['scope'] = ('Actual macOS URLSession, Security memory-only identities and loopback TLS 1.3; '
                       'temporary credentials and synthetic in-memory authorization. No personal '
                       'Keychain import, pairing, ledger, Codex, model, relay or WAN. In-flight '
                       'cancellation occurs after authenticated response headers while the response '
                       'body is incomplete; no body bytes are delivered to the native delegate.')
    report['cases'], report['peers'] = [], []
    temporary_path = None
    try:
        with tempfile.TemporaryDirectory(prefix='munie-native-mtls-') as temporary:
            root = Path(temporary).resolve()
            temporary_path = root
            report['failureCode'] = 'certificate-generation'
            password = prepare_native_certificates(openssl, root)
            policy = network.FixtureAuthorization({network.fingerprint(root, name): name
                                                    for name in ('device-a', 'device-b')})
            run_cases(executable, root, password, policy, report)
    finally:
        report['temporaryCredentialsRemoved'] = temporary_path is not None and not temporary_path.exists()
    require(report['temporaryCredentialsRemoved'], 'Temporary identities remain after experiment')
    require(all(case.get('passed') for case in report['cases']) and len(report['cases']) == 17,
            'Native experiment cases incomplete')
    report.pop('failureCode', None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', type=Path, required=True, help='Absolute compiled Swift probe')
    parser.add_argument('--openssl', type=Path, required=True, help='Absolute OpenSSL executable')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = {'reportVersion': 1, 'status': 'failed', 'phase': 'starting',
              'capturedAtUTC': datetime.now(timezone.utc).isoformat()}
    helper.write_report(args.output, report)  # Invalidate old success before any child or listener.
    status = 1
    try:
        report['phase'] = 'native-loopback-mtls'
        experiment(args.executable, args.openssl, report)
        report['status'], report['phase'], status = 'passed', 'complete', 0
    except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
        report['failureType'] = type(error).__name__
        print('Native network probe failed: ' + type(error).__name__, file=sys.stderr)
    finally:
        helper.write_report(args.output, report)
    if status == 0:
        print('PASS native URLSession loopback mTLS: ' + str(len(report['cases'])) +
              ' synthetic cases; no Codex, model or WAN.')
    return status


if __name__ == '__main__':
    sys.exit(main())
