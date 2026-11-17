"""Offline policy/report/cleanup regressions; these do not establish TLS interoperability."""

from contextlib import redirect_stderr, redirect_stdout
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / 'probe-authenticated-network.py'
SPEC = importlib.util.spec_from_file_location('authenticated_network_under_test', SCRIPT)
network = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(network)
FINGERPRINT_A = hashlib.sha256(b'synthetic certificate A DER').hexdigest()
FINGERPRINT_B = hashlib.sha256(b'synthetic certificate B DER').hexdigest()


def request(**changes):
    return json.dumps({'requestID': 'synthetic-1', 'projectID': network.PROJECT,
                       'payload': 'synthetic-task', **changes}, ensure_ascii=False).encode('utf-8')


class FixtureAuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.policy = network.FixtureAuthorization({FINGERPRINT_A: 'device-a',
                                                    FINGERPRINT_B: 'device-b'})

    def test_certificate_fingerprint_maps_verified_der_to_device(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'device-a.pem').write_text('synthetic PEM', encoding='ascii')
            with patch.object(network.ssl, 'PEM_cert_to_DER_cert',
                              return_value=b'synthetic certificate A DER') as decode:
                fingerprint = network.fingerprint(root, 'device-a')
        decode.assert_called_once_with('synthetic PEM')
        self.assertEqual(fingerprint, FINGERPRINT_A)
        self.assertEqual(self.policy.submit(fingerprint, request()),
                         (202, {'state': 'fixture-accepted', 'ordinal': 1}))
        self.assertEqual(self.policy.accepted['synthetic-1'][0][0], 'device-a')

    def test_unknown_and_revoked_certificates_cannot_accept_or_replay(self):
        self.assertEqual(self.policy.submit('unknown-certificate', request()),
                         (403, {'error': 'device-denied'}))
        self.assertFalse(self.policy.accepted)
        self.policy.submit(FINGERPRINT_A, request())
        previous = copy.deepcopy(self.policy.accepted)
        self.policy.revoked.add(FINGERPRINT_A)
        for body in (request(), request(requestID='fresh-after-revocation'), b'\xff'):
            with self.subTest(body=body):
                self.assertEqual(self.policy.submit(FINGERPRINT_A, body),
                                 (403, {'error': 'device-denied'}))
        self.assertEqual(self.policy.accepted, previous)
        # One device's revocation cannot silently grant or revoke another identity.
        self.assertEqual(self.policy.submit(FINGERPRINT_B, request(requestID='device-b-request')),
                         (202, {'state': 'fixture-accepted', 'ordinal': 2}))

    def test_self_reported_device_fields_never_override_certificate_identity(self):
        for field in ('deviceID', 'fingerprint', 'certificate', 'hostID'):
            with self.subTest(field=field):
                self.assertEqual(self.policy.submit(FINGERPRINT_A, request(**{field: 'device-b'})),
                                 (400, {'error': 'invalid-request'}))
        self.assertFalse(self.policy.accepted)

    def test_project_denial_has_no_acceptance_and_cannot_reuse_existing_id(self):
        self.assertEqual(self.policy.submit(FINGERPRINT_A, request(projectID='other-project')),
                         (403, {'error': 'project-denied'}))
        self.assertFalse(self.policy.accepted)
        self.policy.submit(FINGERPRINT_A, request())
        previous = copy.deepcopy(self.policy.accepted)
        self.assertEqual(self.policy.submit(FINGERPRINT_A, request(projectID='other-project')),
                         (403, {'error': 'project-denied'}))
        self.assertEqual(self.policy.accepted, previous)

    def test_immutable_request_identity_binds_device_project_and_payload(self):
        body = request(payload='你好\0synthetic')
        self.assertEqual(self.policy.submit(FINGERPRINT_A, body),
                         (202, {'state': 'fixture-accepted', 'ordinal': 1}))
        previous = copy.deepcopy(self.policy.accepted)
        self.assertEqual(self.policy.submit(FINGERPRINT_A, body),
                         (200, {'state': 'fixture-accepted', 'ordinal': 1}))
        for fingerprint, changed in ((FINGERPRINT_B, body),
                                     (FINGERPRINT_A, request(payload='changed'))):
            with self.subTest(fingerprint=fingerprint):
                self.assertEqual(self.policy.submit(fingerprint, changed),
                                 (409, {'error': 'request-conflict'}))
        self.assertEqual(self.policy.accepted, previous)

    def test_invalid_utf8_duplicate_members_types_and_sizes_fail_without_mutation(self):
        self.policy.submit(FINGERPRINT_A, request())
        previous = copy.deepcopy(self.policy.accepted)
        invalid = [b'\xff', b'{}', b'null', b'[]', b'"synthetic"',
                   b'{"requestID":"first","requestID":"second","projectID":"synthetic-project",'
                   b'"payload":"synthetic-task"}',
                   b'{"requestID":"first","\\u0072equestID":"second",'
                   b'"projectID":"synthetic-project","payload":"synthetic-task"}',
                   request(requestID=True), request(payload=None), request(payload=[]),
                   request(payload=''), request(payload='\u754c' * 86),
                   request(requestID='x' * 257)]
        for body in invalid:
            with self.subTest(body=body):
                self.assertEqual(self.policy.submit(FINGERPRINT_A, body),
                                 (400, {'error': 'invalid-request'}))
                self.assertEqual(self.policy.accepted, previous)

    def test_capacity_refuses_new_identity_and_preserves_old_replay_and_conflict(self):
        for ordinal in range(1, network.MAX_ACCEPTED + 1):
            self.assertEqual(self.policy.submit(FINGERPRINT_A, request(requestID=str(ordinal))),
                             (202, {'state': 'fixture-accepted', 'ordinal': ordinal}))
        previous = copy.deepcopy(self.policy.accepted)
        self.assertEqual(self.policy.submit(FINGERPRINT_A, request(requestID='overflow')),
                         (429, {'error': 'fixture-capacity'}))
        for ordinal in range(1, network.MAX_ACCEPTED + 1):
            self.assertEqual(self.policy.submit(FINGERPRINT_A, request(requestID=str(ordinal))),
                             (200, {'state': 'fixture-accepted', 'ordinal': ordinal}))
        self.assertEqual(self.policy.submit(FINGERPRINT_B, request(requestID='1')),
                         (409, {'error': 'request-conflict'}))
        self.assertEqual(self.policy.accepted, previous)


class ProbeReportTests(unittest.TestCase):
    def test_old_pass_is_invalidated_before_work_and_errors_stay_private(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'report.json'
            output.write_text(json.dumps({'status': 'passed', 'oldEvidence': 'obsolete'}))
            output.chmod(0o644)
            secret = 'synthetic-private-token-and-certificate-path'

            def fail(_executable, _report):
                starting = json.loads(output.read_bytes())
                self.assertEqual((starting['status'], starting['phase']), ('failed', 'starting'))
                self.assertNotIn('oldEvidence', starting)
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                raise ValueError(secret)

            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(network.sys, 'argv', ['probe', '--output', str(output)]), \
                    patch.object(network, 'experiment', side_effect=fail), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(network.main(), 1)
            report = json.loads(output.read_bytes())
            self.assertEqual(report['status'], 'failed')
            self.assertEqual(report['failureType'], 'ValueError')
            self.assertNotIn('oldEvidence', report)
            self.assertNotIn(secret, output.read_text() + stdout.getvalue() + stderr.getvalue())
            self.assertNotIn('PASS', stdout.getvalue())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_tls13_absence_explicitly_fails_without_launch_or_downgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'report.json'
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(network.ssl, 'HAS_TLSv1_3', False), \
                    patch.object(network.subprocess, 'check_output') as command, \
                    patch.object(network, 'make_certificates') as certificates, \
                    patch.object(network, 'FixtureServer') as server, \
                    patch.object(network.sys, 'argv', ['probe', '--output', str(output)]), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(network.main(), 1)
            report = json.loads(output.read_bytes())
            self.assertEqual(report['status'], 'failed')
            self.assertEqual(report['failureCode'], 'tls13-unavailable')
            self.assertNotIn('PASS', stdout.getvalue())
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            command.assert_not_called()
            certificates.assert_not_called()
            server.assert_not_called()

    def test_context_requires_tls13_peer_verification_and_no_keylog(self):
        context = Mock(keylog_filename=None, verify_flags=0)
        with patch.object(network.ssl, 'SSLContext', return_value=context):
            self.assertIs(network.tls_context(Path('/synthetic-private-root'), server=True), context)
        self.assertEqual(context.minimum_version, ssl.TLSVersion.TLSv1_3)
        self.assertEqual(context.maximum_version, ssl.TLSVersion.TLSv1_3)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertEqual(context.num_tickets, 0)
        context.set_alpn_protocols.assert_called_once_with(['http/1.1'])
        context.load_cert_chain.assert_called_once_with('/synthetic-private-root/server.pem',
                                                        '/synthetic-private-root/server.key')
        context.keylog_filename = '/synthetic-forbidden-keylog'
        with patch.object(network.ssl, 'SSLContext', return_value=context):
            with self.assertRaisesRegex(ValueError, 'must not log TLS secrets'):
                network.tls_context(Path('/synthetic-private-root'), server=True)


class OfflineServer:
    """Thread lifecycle boundary only; it never opens a socket or speaks TLS."""
    server_port = 12345

    def __init__(self):
        self.closed = threading.Event()
        self.stopped = threading.Event()
        self.operations = []
        self.socket = Mock()
        self.socket.fileno.return_value = 123

    def serve_forever(self, **_):
        self.stopped.wait(2)

    def stop_connections(self):
        self.operations.append('stop-connections')

    def shutdown(self):
        self.operations.append('shutdown')
        self.stopped.set()

    def server_close(self):
        self.operations.append('server-close')
        self.socket.fileno.return_value = -1
        self.closed.set()


class FailureCleanupTests(unittest.TestCase):
    def test_open_listener_cannot_be_reported_as_stopped(self):
        server = OfflineServer()
        report = {}
        server.server_close = Mock()  # Simulate a cleanup regression retaining its listener.
        with patch.object(network, 'FixtureServer', return_value=server):
            with self.assertRaisesRegex(ValueError, 'server did not stop'):
                with network.running_server(object(), object(), report):
                    pass
        self.assertIs(report['serverStopped'], False)
        self.assertTrue(server.stopped.is_set())

    def test_experiment_failure_closes_worker_and_removes_temporary_credentials(self):
        server = OfflineServer()
        report, roots = {}, []

        def certificates(_executable, root):
            roots.append(root)
            (root / 'synthetic.key').write_bytes(b'synthetic ephemeral key')

        def context(_root, server=False, **_):
            if server:
                return object()
            raise ValueError('synthetic-private-context-failure')

        with patch.object(network.ssl, 'HAS_TLSv1_3', True), \
                patch.object(network.subprocess, 'check_output',
                             side_effect=['synthetic OpenSSL', 'synthetic revision', '']), \
                patch.object(network, 'make_certificates', side_effect=certificates), \
                patch.object(network, 'fingerprint', side_effect=[FINGERPRINT_A, FINGERPRINT_B]), \
                patch.object(network, 'tls_context', side_effect=context), \
                patch.object(network, 'FixtureServer', return_value=server):
            with self.assertRaisesRegex(ValueError, 'synthetic-private-context-failure'):
                network.experiment(SCRIPT.resolve(), report)
        self.assertTrue(server.closed.is_set())
        self.assertTrue(server.stopped.is_set())
        self.assertEqual(server.operations, ['stop-connections', 'shutdown', 'server-close'])
        self.assertIs(report['serverStopped'], True)
        self.assertIs(report['temporaryCredentialsRemoved'], True)
        self.assertEqual(len(roots), 1)
        self.assertFalse(roots[0].exists())

    def test_failed_server_tls_handshake_closes_raw_socket_before_rethrow(self):
        server = object.__new__(network.FixtureServer)
        server.active, server.active_lock, server.stopping = set(), threading.Lock(), False
        server.context = Mock()
        server.policy = network.FixtureAuthorization({})
        raw = Mock()
        failure = ssl.SSLError('synthetic private handshake failure')
        server.context.wrap_socket.side_effect = failure
        with patch.object(network.HTTPServer, 'get_request', return_value=(raw, ('127.0.0.1', 1))):
            with self.assertRaises(ssl.SSLError) as raised:
                server.get_request()
        self.assertIs(raised.exception, failure)
        raw.settimeout.assert_called_once_with(network.IO_SECONDS)
        raw.close.assert_called_once_with()
        self.assertEqual(server.policy.connections, 0)
        self.assertFalse(server.active)

    def test_ssl_socket_is_registered_before_handshake_and_discarded_on_failure(self):
        server = object.__new__(network.FixtureServer)
        server.active, server.active_lock, server.stopping = set(), threading.Lock(), False
        server.context = Mock()
        server.policy = network.FixtureAuthorization({})
        raw, secured = Mock(), Mock()
        failure = ssl.SSLError('synthetic private explicit-handshake failure')

        def wrap(*args, **kwargs):
            self.assertIn(raw, server.active)
            self.assertEqual(kwargs, {'server_side': True, 'do_handshake_on_connect': False})
            return secured

        def handshake():
            self.assertIn(secured, server.active)
            self.assertNotIn(raw, server.active)
            raise failure

        server.context.wrap_socket.side_effect = wrap
        secured.do_handshake.side_effect = handshake
        with patch.object(network.HTTPServer, 'get_request', return_value=(raw, ('127.0.0.1', 1))):
            with self.assertRaises(ssl.SSLError) as raised:
                server.get_request()
        self.assertIs(raised.exception, failure)
        secured.close.assert_called_once_with()
        self.assertFalse(server.active)
        self.assertEqual(server.policy.connections, 0)

    def test_stop_connections_closes_every_active_peer_despite_shutdown_error(self):
        server = object.__new__(network.FixtureServer)
        first, second = Mock(), Mock()
        first.shutdown.side_effect = OSError('synthetic peer already closed')
        server.active = {first, second}
        server.active_lock, server.stopping = threading.Lock(), False
        server.stop_connections()
        self.assertTrue(server.stopping)
        self.assertFalse(server.active)
        for peer in (first, second):
            peer.shutdown.assert_called_once_with(network.socket.SHUT_RDWR)
            peer.close.assert_called_once_with()

    def test_accept_during_stop_closes_new_socket_without_starting_tls(self):
        server = object.__new__(network.FixtureServer)
        server.active, server.active_lock, server.stopping = set(), threading.Lock(), True
        server.context = Mock()
        raw = Mock()
        with patch.object(network.HTTPServer, 'get_request', return_value=(raw, ('127.0.0.1', 1))):
            with self.assertRaises(OSError):
                server.get_request()
        raw.close.assert_called_once_with()
        server.context.wrap_socket.assert_not_called()
        self.assertFalse(server.active)

    def test_failed_client_tls_handshake_closes_raw_socket_before_rethrow(self):
        client = object.__new__(network.LoopbackClient)
        client.port, client.hostname = 12345, 'localhost'
        client._context = Mock()
        failure = ssl.SSLError('synthetic private hostname failure')
        client._context.wrap_socket.side_effect = failure
        raw = Mock()
        with patch.object(network.socket, 'create_connection', return_value=raw):
            with self.assertRaises(ssl.SSLError) as raised:
                client.connect()
        self.assertIs(raised.exception, failure)
        raw.close.assert_called_once_with()


if __name__ == '__main__':
    unittest.main()
