"""Offline validation, privacy and real-process cleanup tests; no TLS success is simulated."""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / 'probe-native-network.py'
SPEC = importlib.util.spec_from_file_location('native_network_under_test', SCRIPT)
native = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(native)


def result(**changes):
    return {'event': 'result', 'bodyBytes': 40, 'overflow': False, 'redirectRejected': False,
            'cancelledOnResponse': False, 'serverChallenges': 1, 'clientChallenges': 1,
            'trustRejected': 0, 'httpStatus': 202, 'tlsProtocol': 772, 'proxy': False,
            'state': 'fixture-accepted', 'ordinal': 1, **changes}


def rejected(**changes):
    return {'event': 'result', 'bodyBytes': 0, 'overflow': False, 'redirectRejected': False,
            'cancelledOnResponse': False, 'serverChallenges': 1, 'clientChallenges': 1,
            'trustRejected': 0, 'tlsProtocol': 772, 'proxy': False, 'errorCode': -999, **changes}


class NativeValidationTests(unittest.TestCase):
    def test_http_success_requires_tls13_direct_transport_and_exact_acceptance(self):
        frame = native.validate_result(result())
        native.expect_http(frame, 202, ordinal=1)
        for changes in ({'httpStatus': 200}, {'ordinal': 2}, {'bodyBytes': 0},
                        {'cancelledOnResponse': True}, {'errorCode': -999}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                native.expect_http(result(**changes), 202, ordinal=1)

    def test_schema_rejects_secret_fields_missing_fields_and_non_integer_types(self):
        cases = [result(rawBody='synthetic-private-body'), result(bodyBytes=True),
                 result(ordinal=True), result(clientChallenges=-1), result(serverChallenges=5),
                 result(overflow=0), result(proxy=0), result(httpStatus=999),
                 result(tlsProtocol=771), result(proxy=True), result(trustRejected=2)]
        missing = result()
        del missing['cancelledOnResponse']
        cases.append(missing)
        for frame in cases:
            with self.subTest(keys=list(frame)), self.assertRaises(ValueError):
                native.validate_result(frame)

    def test_error_envelope_cannot_be_confused_with_acceptance_or_arbitrary_content(self):
        frame = rejected(httpStatus=200, bodyBytes=25, fixtureError='device-denied')
        del frame['errorCode']
        native.expect_http(native.validate_result(frame), 200, error='device-denied')
        for changes in ({'fixtureError': ['synthetic-private-body']},
                        {'fixtureError': 'synthetic-private-body'}, {'state': 'fixture-accepted'},
                        {'errorCode': -999}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                native.validate_result({**frame, **changes})

    def test_any_network_error_is_insufficient_for_certificate_rejection(self):
        with self.assertRaises(ValueError):
            native.expect_tls_rejection(rejected(errorCode=-1005))
        native.expect_tls_rejection(rejected(errorCode=-1005), server_rejected=True)
        for frame in (rejected(errorCode=-1001), rejected(clientChallenges=0),
                      rejected(httpStatus=200), rejected(bodyBytes=1)):
            with self.subTest(frame=frame), self.assertRaises(ValueError):
                native.expect_tls_rejection(frame, server_rejected=True)

    def test_wrong_server_requires_trust_challenge_and_actual_rejection(self):
        native.expect_tls_rejection(rejected(trustRejected=1), trust=True)
        for changes in ({'trustRejected': 0}, {'serverChallenges': 0}, {'errorCode': -1005}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                native.expect_tls_rejection(rejected(**{'trustRejected': 1, **changes}), trust=True)

    def test_timeout_cancellation_overflow_and_redirect_have_distinct_evidence(self):
        native.expect_transport_control(rejected(errorCode=-1001), 'slow')
        native.expect_transport_control(rejected(httpStatus=200, cancelledOnResponse=True),
                                        'inflight-response-cancel')
        native.expect_transport_control(rejected(httpStatus=200, overflow=True), 'oversized')
        redirect = rejected(httpStatus=307, redirectRejected=True, bodyBytes=2)
        del redirect['errorCode']
        native.expect_transport_control(redirect, 'redirect')
        for frame, kind in ((rejected(), 'slow'), (rejected(), 'inflight-response-cancel'),
                            (rejected(httpStatus=200, bodyBytes=1, overflow=True), 'oversized'),
                            (rejected(httpStatus=307), 'redirect')):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                native.expect_transport_control(frame, kind)

    def test_legacy403_mapping_does_not_pass_the_readable_policy_gate(self):
        frame = rejected(errorCode=-1206)
        native.expect_legacy_denial(frame)
        with self.assertRaises(ValueError):
            native.expect_http(frame, 403, error='device-denied')

    def test_candidate_denial_envelope_is_separate_from_legacy403_and_never_accepts(self):
        for candidate, expected_status, expected_close in ((True, 200, False), (False, 403, True)):
            state = native.NativeFixtureState()
            handler_type = native.native_handler(state, policy_envelope=candidate)
            handler = handler_type.__new__(handler_type)
            handler.path = '/fixture/submit'
            with patch.object(native.network.FixtureHandler, 'send_result') as send:
                handler.send_result(403, {'error': 'device-denied'}, close=True)
            send.assert_called_once_with(expected_status, {'error': 'device-denied'}, expected_close)
            self.assertEqual(state.policy_results(), [{'policyStatus': 403,
                                                       'wireHTTPStatus': expected_status,
                                                       'result': {'error': 'device-denied'}}])

    def test_invalid_peer_frame_is_not_retained_in_case_report(self):
        peer = native.NativePeer.__new__(native.NativePeer)
        peer.request_seconds = 8
        peer.send = Mock()
        peer.read_frame = Mock(return_value=result(rawBody='synthetic-private-body'))
        report = {'cases': []}
        policy = Mock(accepted={}, connections=0)
        with self.assertRaises(ValueError):
            native.check(report, policy, 'offline-malformed-frame', peer, lambda _: None)
        self.assertNotIn('synthetic-private-body', json.dumps(report))
        self.assertNotIn('result', report['cases'][0])
        self.assertNotIn('passed', report['cases'][0])


class ReportPrivacyTests(unittest.TestCase):
    def test_metadata_binds_observed_runtime_revision_and_all_executed_sources(self):
        report = {}
        with patch.object(native.platform, 'mac_ver', return_value=('synthetic-macOS', (), '')), \
                patch.object(native.platform, 'release', return_value='synthetic-kernel'), \
                patch.object(native.subprocess, 'check_output', side_effect=[
                    'OpenSSL synthetic\n', 'a' * 40 + '\n', ' M synthetic-file\n']):
            native.record_metadata(SCRIPT, Path('/synthetic-openssl'), report)
        self.assertEqual(report['runtime']['macOS'], 'synthetic-macOS')
        self.assertEqual(report['runtime']['darwin'], 'synthetic-kernel')
        self.assertEqual(report['runtime']['python'], sys.version)
        self.assertEqual(report['runtime']['executable'], sys.executable)
        self.assertEqual(report['runtime']['openssl'], 'OpenSSL synthetic')
        self.assertEqual(report['sourceRevision'], 'a' * 40)
        self.assertTrue(report['workingTreeDirty'])
        for key in ('runnerSHA256', 'nativeExecutableSHA256', 'nativeSourceSHA256',
                    'networkFixtureSHA256', 'helperSHA256'):
            self.assertRegex(report[key], r'^[a-f0-9]{64}$')

    def test_old_pass_invalidated_before_any_experiment_and_failure_message_redacted(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'report.json'
            output.write_text('{"status":"passed","oldEvidence":"obsolete"}')
            output.chmod(0o644)
            secret = 'synthetic-private-password-and-certificate-path'

            def fail(_executable, _openssl, _report):
                self.assertEqual(json.loads(output.read_bytes())['phase'], 'starting')
                self.assertEqual(json.loads(output.read_bytes())['status'], 'failed')
                self.assertNotIn('oldEvidence', output.read_text())
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                raise ValueError(secret)

            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(native.sys, 'argv', ['probe', '--executable', '/synthetic-native',
                                                  '--openssl', '/synthetic-openssl',
                                                  '--output', str(output)]), \
                    patch.object(native, 'experiment', side_effect=fail), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(native.main(), 1)
            report = json.loads(output.read_bytes())
            self.assertEqual((report['status'], report['failureType']), ('failed', 'ValueError'))
            self.assertNotIn(secret, output.read_text() + stdout.getvalue() + stderr.getvalue())
            self.assertNotIn('PASS', stdout.getvalue())

    def test_no_tls13_fails_before_certificates_processes_or_servers(self):
        report = {}
        with patch.object(native.platform, 'system', return_value='Darwin'), \
                patch.object(native.ssl, 'HAS_TLSv1_3', False), \
                patch.object(native, 'prepare_native_certificates') as certificates, \
                patch.object(native, 'NativePeer') as peer, \
                patch.object(native.network, 'running_server') as server:
            with self.assertRaises(ValueError):
                native.experiment(SCRIPT, SCRIPT, report)
        self.assertEqual(report['failureCode'], 'unsupported-runtime')
        certificates.assert_not_called()
        peer.assert_not_called()
        server.assert_not_called()

    def test_failure_removes_ephemeral_certificates_and_records_removal(self):
        roots, report = [], {}

        def certificates(_openssl, root):
            roots.append(root)
            native.private_file(root / 'synthetic-private.key', b'synthetic ephemeral identity')
            raise ValueError('synthetic-private-certificate-error')

        with patch.object(native.platform, 'system', return_value='Darwin'), \
                patch.object(native.ssl, 'HAS_TLSv1_3', True), \
                patch.object(native, 'record_metadata'), \
                patch.object(native, 'prepare_native_certificates', side_effect=certificates):
            with self.assertRaises(ValueError):
                native.experiment(Path(sys.executable).resolve(), Path(sys.executable).resolve(), report)
        self.assertTrue(report['temporaryCredentialsRemoved'])
        self.assertEqual(len(roots), 1)
        self.assertFalse(roots[0].exists())

    def test_private_write_excludes_existing_files_and_uses_0600(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'identity.json'
            native.private_file(path, b'synthetic private fixture')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                native.private_file(path, b'replacement')
            self.assertEqual(path.read_bytes(), b'synthetic private fixture')

    def test_pkcs12_password_is_a_file_argument_and_generation_restores_umask(self):
        commands = []

        def base_certificates(_openssl, root):
            for name in ('server.pem', 'server.key', 'server.cnf'):
                (root / name).write_text('subjectAltName=DNS:localhost\n')

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(native.network, 'make_certificates', side_effect=base_certificates), \
                    patch.object(native.network, 'openssl_run', side_effect=lambda *args: commands.append(args)), \
                    patch.object(native.secrets, 'token_urlsafe', return_value='synthetic-password'), \
                    patch.object(native.os, 'umask', side_effect=[0o022, 0o077]) as umask:
                password = native.prepare_native_certificates(Path('/synthetic-openssl'), root)
            self.assertEqual(password, 'synthetic-password')
            self.assertEqual(umask.call_args_list[-1].args, (0o022,))
            exports = [item[2:] for item in commands if item[2] == 'pkcs12']
            self.assertEqual(len(exports), 4)
            for arguments in exports:
                self.assertEqual(arguments[arguments.index('-passout') + 1], 'file:' + str(root / 'p12-password'))
                self.assertNotIn(password, arguments)
                self.assertNotIn('-legacy', arguments)
            self.assertIn('IP:127.0.0.1', (root / 'server.cnf').read_text())
            for path in root.iterdir():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)


class PeerCleanupTests(unittest.TestCase):
    def fake_peer(self, root, *, close_frame=True, trailing=False, startup=True):
        """The fake process exercises JSONL/EOF only; it never claims network validation."""
        source = root / 'offline_peer.py'
        source.write_text(
            'import json,sys\n'
            + ('print(json.dumps({"event":"ready","memoryOnlyIdentity":True}),flush=True)\n'
               if startup else 'sys.exit(1)\n')
            + 'for line in sys.stdin: pass\n'
            + ('print(json.dumps({"event":"closed","sessionInvalidated":True}),flush=True)\n'
               if close_frame else '')
            + ('print(json.dumps({"method":"unexpected"}),flush=True)\n' if trailing else ''),
            encoding='utf-8')
        return native.NativePeer([sys.executable, str(source)], root, {'PATH': '/usr/bin:/bin'})

    def test_native_close_consumes_closed_before_generic_drain_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            peer = self.fake_peer(Path(directory))
            peer.ready(True)
            cleanup = peer.close()
            self.assertEqual(cleanup, {'exitStatus': 0, 'streamsReachedEOF': True, 'processGroupGone': True})
            self.assertTrue(peer.closed_frame)
            self.assertEqual(peer.close(), cleanup)

    def test_missing_closed_frame_still_reaps_and_records_eof(self):
        with tempfile.TemporaryDirectory() as directory:
            peer = self.fake_peer(Path(directory), close_frame=False)
            peer.ready(True)
            with self.assertRaises(ValueError):
                peer.close()
            self.assertFalse(peer.closed_frame)
            self.assertTrue(peer.cleanup['streamsReachedEOF'])
            self.assertTrue(peer.cleanup['processGroupGone'])
            with self.assertRaises(ValueError):
                peer.close()

    def test_trailing_frame_fails_even_after_session_invalidation(self):
        with tempfile.TemporaryDirectory() as directory:
            peer = self.fake_peer(Path(directory), trailing=True)
            peer.ready(True)
            with self.assertRaises(ValueError):
                peer.close()
            self.assertTrue(peer.closed_frame)
            self.assertTrue(peer.cleanup['processGroupGone'])
            self.assertEqual(peer.cleanup['exitStatus'], 0)

    def test_startup_failure_still_closes_process_and_streams(self):
        with tempfile.TemporaryDirectory() as directory:
            peer = self.fake_peer(Path(directory), startup=False)
            with self.assertRaises(ValueError):
                peer.ready(True)
            with self.assertRaises(ValueError):
                peer.close()
            self.assertEqual(peer.cleanup['exitStatus'], 1)
            self.assertTrue(peer.cleanup['processGroupGone'])
            self.assertTrue(peer.cleanup['streamsReachedEOF'])

    def test_primary_error_survives_cleanup_error_and_report_has_only_stream_hashes(self):
        peer = Mock(closed_frame=False,
                    cleanup={'exitStatus': 1, 'streamsReachedEOF': True, 'processGroupGone': True},
                    totals={'stdout': 0, 'stderr': 19},
                    digests={'stdout': hashlib.sha256(), 'stderr': hashlib.sha256(b'synthetic-private')})
        peer.ready.side_effect = ValueError('primary-secret')
        peer.close.side_effect = OSError('cleanup-secret')
        report = {}
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(native, 'NativePeer', return_value=peer) as constructor:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'primary-secret'):
                with native.native_peer(Path('/synthetic-native'), root, 12345,
                                        'synthetic-password', report, 'failure'):
                    self.fail('startup must fail')
            configuration = root / 'native-failure.json'
            self.assertEqual(configuration.stat().st_mode & 0o777, 0o600)
            environment = constructor.call_args.args[2]
            self.assertNotIn('HOME', environment)
            self.assertNotIn('TOKEN', environment)
            self.assertTrue(Path(environment['TMPDIR']).name.startswith('fixturetmp-'))
        record = report['peers'][0]
        self.assertEqual(record['failureType'], 'ValueError')
        self.assertEqual(record['cleanupFailureType'], 'OSError')
        self.assertEqual(record['cleanup']['exitStatus'], 1)
        wire = json.dumps(report)
        for secret in ('primary-secret', 'cleanup-secret', 'synthetic-password', 'synthetic-private'):
            self.assertNotIn(secret, wire)


if __name__ == '__main__':
    unittest.main()
