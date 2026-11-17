"""Offline evidence/cleanup regressions; no successful TLS or Keychain work is simulated."""

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / 'probe-device-identity.py'
SPEC = importlib.util.spec_from_file_location('device_identity_under_test', SCRIPT)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
FINGERPRINTS = {'valid': 'a' * 64, 'unknown': 'b' * 64, 'untrusted': 'c' * 64,
                'expired': 'd' * 64, 'wrong-eku': 'e' * 64}


def result(**changes):
    return {'event': 'result', 'name': 'valid', 'bodyBytes': 98,
            'serverChallenges': 1, 'clientChallenges': 1, 'trustRejected': 0,
            'overflow': False, 'redirectRejected': False, 'invalidated': True,
            'httpStatus': 200, 'tlsProtocol': 772, 'proxy': False,
            'state': 'accepted', 'peer': FINGERPRINTS['valid'], **changes}


def rejected(name='wrong-ca', **changes):
    return {'event': 'result', 'name': name, 'bodyBytes': 0,
            'serverChallenges': 1, 'clientChallenges': 1, 'trustRejected': 0,
            'overflow': False, 'redirectRejected': False, 'invalidated': True,
            'errorCode': -1206, **changes}


def ready(**changes):
    return {'event': 'csr-ready', 'keyBits': 256, 'keyPermanent': False,
            'publicKeyEncoding': 'spki-der', 'publicKeySHA256': '1' * 64,
            'csrSHA256': '2' * 64, **changes}


def done(**changes):
    return {'event': 'done', 'sessionsInvalidated': len(probe.CASE_SPECS), 'certificateKeyMatched': True,
            'identityLeafMatched': True, 'identityPossessionVerified': True,
            'mismatchedIdentityRejected': True, 'keychainUsed': False,
            'privateKeyExported': False, **changes}


def server_cleanup():
    def request(peer, state):
        return {'loopback': True, 'handshake': True, 'businessRequest': True,
                'peer': peer, 'state': state, 'tlsProtocol': 'TLSv1.3'}
    return {'listenerClosed': True, 'workerStopped': True, 'activeConnectionClosed': True,
            'fatal': None, 'connections': [request(FINGERPRINTS['valid'], 'accepted'),
                request(FINGERPRINTS['valid'], 'accepted'),
                request(FINGERPRINTS['unknown'], 'denied')]}


class EvidenceBoundaryTests(unittest.TestCase):
    def test_success_requires_exact_actual_leaf_not_same_ca_or_public_key(self):
        probe.validate_result(result(), 'valid', FINGERPRINTS)
        for peer in (FINGERPRINTS['unknown'], FINGERPRINTS['untrusted'], 'A' * 64, None):
            with self.subTest(peer=peer), self.assertRaises(probe.ProbeFailure):
                probe.validate_result(result(peer=peer), 'valid', FINGERPRINTS)

    def test_same_ca_domain_denial_is_readable_and_cannot_be_reported_as_acceptance(self):
        frame = result(name='unknown-same-ca', state='denied', peer=FINGERPRINTS['unknown'])
        probe.validate_result(frame, 'unknown-same-ca', FINGERPRINTS)
        for changes in ({'state': 'accepted'}, {'peer': FINGERPRINTS['valid']},
                        {'httpStatus': 403}, {'errorCode': -1206}, {'bodyBytes': 0}):
            with self.subTest(changes=changes), self.assertRaises(probe.ProbeFailure):
                probe.validate_result({**frame, **changes}, 'unknown-same-ca', FINGERPRINTS)
        with self.assertRaises(probe.ProbeFailure):
            probe.validate_result(frame, 'valid', FINGERPRINTS)

    def test_success_requires_observed_transport_and_completed_session_invalidation(self):
        for changes in ({'httpStatus': 201}, {'tlsProtocol': 771}, {'proxy': True},
                        {'bodyBytes': 0}, {'serverChallenges': 0}, {'clientChallenges': 0},
                        {'trustRejected': 1}, {'invalidated': False}, {'overflow': True},
                        {'redirectRejected': True}, {'errorCode': -999}):
            with self.subTest(changes=changes), self.assertRaises(probe.ProbeFailure):
                probe.validate_result(result(**changes), 'valid', FINGERPRINTS)

    def test_frames_reject_sensitive_extensions_missing_fields_and_boolean_counts(self):
        frames = [result(rawCertificate='synthetic-private-marker'), result(bodyBytes=True),
                  result(clientChallenges=True), result(httpStatus=True), result(tlsProtocol=True),
                  result(proxy=0), result(invalidated=1), result(trustRejected=2),
                  result(serverChallenges=9), result(bodyBytes=2049)]
        missing = result()
        del missing['invalidated']
        frames.append(missing)
        for frame in frames:
            with self.subTest(keys=list(frame)), self.assertRaises(probe.ProbeFailure):
                probe.validate_result(frame, 'valid', FINGERPRINTS)

    def test_tls_rejection_requires_control_evidence_and_no_business_payload(self):
        probe.validate_result(rejected(), 'wrong-ca', FINGERPRINTS)
        for changes in ({'httpStatus': 200}, {'state': 'denied'}, {'peer': FINGERPRINTS['valid']},
                        {'bodyBytes': 1}, {'errorCode': -1001}, {'clientChallenges': 0},
                        {'trustRejected': 1}):
            with self.subTest(changes=changes), self.assertRaises(probe.ProbeFailure):
                probe.validate_result(rejected(**changes), 'wrong-ca', FINGERPRINTS)

    def test_wrong_server_identity_requires_trust_rejection_before_client_credential(self):
        for name in ('wrong-server-anchor', 'wrong-server-hostname'):
            frame = rejected(name, errorCode=-999, trustRejected=1, clientChallenges=0)
            probe.validate_result(frame, name, FINGERPRINTS)
            for changes in ({'trustRejected': 0}, {'serverChallenges': 0},
                            {'errorCode': -1005}, {'clientChallenges': 1}):
                with self.subTest(name=name, changes=changes), self.assertRaises(probe.ProbeFailure):
                    probe.validate_result({**frame, **changes}, name, FINGERPRINTS)

    def test_ready_and_done_bind_key_profile_identity_checks_and_all_sessions(self):
        probe.validate_ready(ready())
        probe.validate_done(done())
        for changes in ({'keyPermanent': True}, {'publicKeyEncoding': 'x963'},
                        {'keyBits': True}, {'csrSHA256': 'not-a-digest'},
                        {'rawCSR': 'synthetic-private-marker'}):
            with self.subTest(changes=changes), self.assertRaises(probe.ProbeFailure):
                probe.validate_ready(ready(**changes))
        for changes in ({'sessionsInvalidated': 7}, {'sessionsInvalidated': True},
                        {'identityPossessionVerified': False}, {'mismatchedIdentityRejected': False},
                        {'keychainUsed': True}, {'privateKeyExported': True},
                        {'rawPrivateKey': 'synthetic-private-marker'}):
            with self.subTest(changes=changes), self.assertRaises(probe.ProbeFailure):
                probe.validate_done(done(**changes))

    def test_server_counts_reject_extra_business_and_claims_from_wrong_actual_peer(self):
        self.assertEqual(probe.validate_server(server_cleanup(), FINGERPRINTS)['businessRequests'], 3)
        wrong_peer = server_cleanup()
        wrong_peer['connections'][0]['peer'] = FINGERPRINTS['unknown']
        extra_business = server_cleanup()
        extra_business['connections'].append(dict(extra_business['connections'][0]))
        rejected_business = server_cleanup()
        rejected_business['connections'][0]['handshake'] = False
        wrong_state = server_cleanup()
        wrong_state['connections'][2]['state'] = 'accepted'
        for cleanup in (wrong_peer, extra_business, rejected_business, wrong_state):
            with self.subTest(cleanup=cleanup), self.assertRaises(probe.ProbeFailure):
                probe.validate_server(cleanup, FINGERPRINTS)

    def test_server_cleanup_failure_cannot_be_hidden_by_correct_business_counts(self):
        for field, value in (('workerStopped', False), ('listenerClosed', False),
                             ('activeConnectionClosed', False), ('fatal', 'RuntimeError')):
            cleanup = server_cleanup()
            cleanup[field] = value
            with self.subTest(field=field), self.assertRaises(probe.ProbeFailure):
                probe.validate_server(cleanup, FINGERPRINTS)

    def test_json_rejects_duplicate_nonfinite_and_nonobject_frames(self):
        for value in (b'{"event":"result","event":"done"}', b'{"x":NaN}', b'[]', b'\xff'):
            with self.subTest(value=value), self.assertRaises(probe.ProbeFailure):
                probe.strict_json(value)


class RealProcessCleanupTests(unittest.TestCase):
    def process(self, root, source, seconds=4):
        return probe.BoundedProcess([sys.executable, '-c', source], root,
                                    {'PATH': '/usr/bin:/bin'}, seconds, time.monotonic() + 10)

    def assert_closed(self, cleanup):
        self.assertTrue(cleanup['stdoutEOF'])
        self.assertTrue(cleanup['stderrEOF'])
        self.assertTrue(cleanup['streamsReachedEOF'])
        self.assertTrue(cleanup['processGroupGone'])
        self.assertEqual(cleanup['errors'], [])
        self.assertIsNotNone(cleanup['exitStatus'])

    def test_premature_stdout_eof_fails_without_leaking_group_or_pipes(self):
        with tempfile.TemporaryDirectory() as root:
            peer = self.process(root, 'pass')
            try:
                with self.assertRaises(probe.ProbeFailure) as failure:
                    peer.frame(seconds=2)
                self.assertEqual(failure.exception.code, 'driver-premature-eof')
            finally:
                cleanup = peer.close()
            self.assert_closed(cleanup)
            self.assertEqual(cleanup['exitStatus'], 0)
            self.assertIs(peer.close(), cleanup)

    def test_silent_process_hits_frame_deadline_then_is_reaped(self):
        with tempfile.TemporaryDirectory() as root:
            peer = self.process(root, 'import time; time.sleep(30)')
            try:
                with self.assertRaises(probe.ProbeFailure) as failure:
                    peer.frame(seconds=.15)
                self.assertEqual(failure.exception.code, 'driver-frame-deadline')
            finally:
                cleanup = peer.close()
            self.assert_closed(cleanup)
            self.assertTrue(cleanup['escalated'])

    def test_stdout_and_stderr_floods_are_bounded_and_still_drained_on_failure(self):
        for descriptor, label in ((1, 'stdout'), (2, 'stderr')):
            with self.subTest(stream=label), tempfile.TemporaryDirectory() as root:
                peer = self.process(root, f'import os; os.write({descriptor}, b"x" * 131072)')
                try:
                    with self.assertRaises(probe.ProbeFailure) as failure:
                        peer.finish()
                    self.assertEqual(failure.exception.code, 'process-output-limit')
                finally:
                    cleanup = peer.close()
                self.assert_closed(cleanup)
                self.assertFalse(cleanup['outputWithinLimits'])
                self.assertGreater(cleanup[label + 'Bytes'], probe.MAX_STREAM)
                self.assertLessEqual(len(peer.output[label]), probe.MAX_STREAM)

    def test_exited_leader_with_inherited_pipes_does_not_hide_live_descendant(self):
        source = ('import json, subprocess, sys\n'
                  'child = subprocess.Popen([sys.executable, "-c", '
                  '"import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"])\n'
                  'print(json.dumps({"event":"child-started"}), flush=True)\n')
        with tempfile.TemporaryDirectory() as root:
            peer = self.process(root, source, seconds=8)
            try:
                self.assertEqual(peer.frame(seconds=3), {'event': 'child-started'})
                peer.process.wait(timeout=3)
                self.assertFalse(probe.group_gone(peer.process.pid))
            finally:
                cleanup = peer.close()
            self.assert_closed(cleanup)
            self.assertEqual(cleanup['exitStatus'], 0)
            self.assertTrue(cleanup['escalated'])


class ServerInitializationFailureTests(unittest.TestCase):
    def check_initialization_failure(self, stage):
        context, listener, worker = Mock(), Mock(), Mock()
        context.verify_flags = 0
        context.keylog_filename = None
        listener.getsockname.return_value = ('127.0.0.1', 43210)
        failure = RuntimeError('synthetic worker start failure') if stage == 'start' else \
            OSError('synthetic listener initialization failure')
        getattr(worker if stage == 'start' else listener, stage).side_effect = failure
        with patch.object(probe.ssl, 'SSLContext', return_value=context), \
                patch.object(probe.socket, 'socket', return_value=listener), \
                patch.object(probe.threading, 'Thread', return_value=worker) as thread, \
                self.assertRaises(type(failure)) as caught:
            probe.FixtureServer(Path('/synthetic-unused-fixture'), FINGERPRINTS['valid'])
        self.assertIs(caught.exception, failure)
        listener.close.assert_called_once_with()
        worker.join.assert_not_called()
        if stage == 'start':
            thread.assert_called_once()
            worker.start.assert_called_once_with()
        else:
            thread.assert_not_called()
            worker.start.assert_not_called()

    def test_bind_failure_closes_created_listener_without_starting_worker(self):
        self.check_initialization_failure('bind')

    def test_listen_failure_closes_bound_listener_without_starting_worker(self):
        self.check_initialization_failure('listen')

    def test_start_failure_closes_listening_socket_without_joining_unstarted_worker(self):
        self.check_initialization_failure('start')


class WorkerFailureTests(unittest.TestCase):
    class RawSocket:
        def __init__(self):
            self.closed = False

        def settimeout(self, _value):
            pass

        def close(self):
            self.closed = True

    class Listener:
        def __init__(self, raw):
            self.raw = raw
            self.closed = False

        def accept(self):
            return self.raw, ('127.0.0.1', 43210)

        def close(self):
            self.closed = True

        def fileno(self):
            return -1 if self.closed else 10

    def server(self, raw, context):
        # Bypass only certificate loading/bind. Exercise the actual serve/close
        # failure paths without making a TLS success claim or opening a socket.
        server = probe.FixtureServer.__new__(probe.FixtureServer)
        server.context = context
        server.valid_fingerprint = FINGERPRINTS['valid']
        server.listener = self.Listener(raw)
        server.lock = threading.Lock()
        server.active = None
        server.stopping = threading.Event()
        server.records = []
        server.fatal = None
        server.thread = threading.Thread(target=server.serve, daemon=True)
        return server

    def test_unexpected_worker_error_closes_raw_socket_and_cannot_pass_gate(self):
        raw = self.RawSocket()
        context = Mock()
        context.wrap_socket.side_effect = RuntimeError('synthetic-private-marker')
        server = self.server(raw, context)
        server.thread.start()
        server.thread.join(timeout=3)
        cleanup = server.close()
        self.assertTrue(raw.closed)
        self.assertTrue(cleanup['listenerClosed'])
        self.assertTrue(cleanup['workerStopped'])
        self.assertTrue(cleanup['activeConnectionClosed'])
        self.assertEqual(cleanup['fatal'], 'RuntimeError')
        self.assertNotIn('synthetic-private-marker', json.dumps(cleanup))
        with self.assertRaises(probe.ProbeFailure):
            probe.validate_server(cleanup, FINGERPRINTS)

    def test_cleanup_interrupts_a_pending_handshake_and_joins_worker(self):
        entered, stopped = threading.Event(), threading.Event()
        raw = self.RawSocket()
        secured = self.RawSocket()

        def handshake():
            entered.set()
            stopped.wait(timeout=10)
            raise OSError('synthetic pending-handshake interruption')

        secured.do_handshake = handshake
        secured.shutdown = lambda _: stopped.set()
        context = Mock()
        context.wrap_socket.return_value = secured
        server = self.server(raw, context)
        server.thread.start()
        try:
            self.assertTrue(entered.wait(timeout=3))
        finally:
            cleanup = server.close()
        self.assertTrue(stopped.is_set())
        self.assertTrue(secured.closed)
        self.assertTrue(cleanup['listenerClosed'])
        self.assertTrue(cleanup['workerStopped'])
        self.assertTrue(cleanup['activeConnectionClosed'])
        self.assertIsNone(cleanup['fatal'])
        self.assertFalse(cleanup['connections'][0]['businessRequest'])


class ExperimentFailureTests(unittest.TestCase):
    def test_invalid_driver_frame_is_not_retained_and_failure_cleans_real_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            driver = root / 'driver'
            driver.write_text(f'#!{sys.executable}\nimport json,time\n'
                              'print(json.dumps({"event":"bad",'
                              '"rawKey":"synthetic-private-marker"}),flush=True)\n'
                              'time.sleep(30)\n')
            driver.chmod(0o700)
            report = {'commands': [], 'cases': []}
            openssl = Mock()
            openssl.run.return_value = (b'OpenSSL synthetic\n', b'')
            with patch.object(probe, 'OpenSSL', return_value=openssl), \
                    self.assertRaises(probe.ProbeFailure) as failure:
                probe.experiment(driver, Path('/unused-openssl'), report)
            self.assertEqual(failure.exception.code, 'driver-ready-schema')
            self.assertNotIn('synthetic-private-marker', json.dumps(report))
            self.assertNotIn('driverReady', report)
            self.assertEqual(report['cases'], [])
            cleanup = report['cleanup']
            self.assertTrue(cleanup['driver']['streamsReachedEOF'])
            self.assertTrue(cleanup['driver']['processGroupGone'])
            self.assertTrue(cleanup['temporaryDirectoryRemoved'])
            self.assertTrue(cleanup['temporaryCredentialFilesRemoved'])

    def test_sigterm_during_silent_driver_runs_main_failure_cleanup_and_saves_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            started = root / 'driver-started'
            report = root / 'report.json'
            driver = root / 'driver'
            driver.write_text(f'#!{sys.executable}\nimport os,time\n'
                              f'open({str(started)!r},"w").write(str(os.getpid()))\n'
                              'time.sleep(30)\n')
            driver.chmod(0o700)
            shim = ('import importlib.util,sys\n'
                    f's=importlib.util.spec_from_file_location("probe",{str(SCRIPT)!r})\n'
                    'm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n'
                    'class OpenSSL:\n'
                    ' def __init__(self,*args):pass\n'
                    ' def run(self,*args,**kwargs):return b"OpenSSL synthetic\\n",b""\n'
                    'm.OpenSSL=OpenSSL\n'
                    'm.ssl.HAS_TLSv1_3=True\n'
                    f'sys.argv=["probe","--driver",{str(driver)!r},"--report",{str(report)!r}]\n'
                    'sys.exit(m.main())\n')
            process = subprocess.Popen([sys.executable, '-c', shim], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not started.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(started.exists(), 'Driver did not reach the silent fixture')
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 1)
                self.assertEqual(stderr, b'')
                evidence = json.loads(report.read_bytes())
                self.assertFalse(evidence['passed'])
                self.assertEqual(evidence['failure'], 'runner-terminated')
                self.assertFalse(json.loads(stdout)['passed'])
                cleanup = evidence['cleanup']
                self.assertTrue(cleanup['driver']['processGroupGone'])
                self.assertTrue(cleanup['driver']['streamsReachedEOF'])
                self.assertTrue(cleanup['temporaryDirectoryRemoved'])
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=3)
                if started.exists():
                    try:
                        os.killpg(int(started.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_existing_report_prevents_execution_and_preserves_old_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            original = b'{"passed":true,"historical":"preserve-me"}\n'
            path.write_bytes(original)
            stdout = io.StringIO()
            with patch.object(probe.sys, 'argv', ['probe', '--driver', '/unused', '--report', str(path)]), \
                    patch.object(probe, 'experiment') as experiment, redirect_stdout(stdout):
                self.assertEqual(probe.main(), 2)
            experiment.assert_not_called()
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(json.loads(stdout.getvalue()),
                             {'passed': False, 'failure': 'report-path-not-fresh'})

    def test_failed_preflight_report_records_failure_without_exception_content(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(probe.sys, 'argv', ['probe', '--driver', '/does-not-exist', '--report', str(path)]), \
                    patch.object(probe, 'experiment') as experiment, \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(probe.main(), 1)
            experiment.assert_not_called()
            evidence = json.loads(path.read_bytes())
            self.assertFalse(evidence['passed'])
            self.assertEqual(evidence['failure'], 'driver-not-executable')
            self.assertFalse(json.loads(stdout.getvalue())['passed'])
            self.assertEqual(stderr.getvalue(), '')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_missing_tls13_fails_before_creating_credentials_or_starting_driver(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            with patch.object(probe.sys, 'argv', ['probe', '--driver', sys.executable,
                                                '--report', str(path)]), \
                    patch.object(probe.ssl, 'HAS_TLSv1_3', False), \
                    patch.object(probe, 'experiment') as experiment, \
                    patch.object(probe.tempfile, 'mkdtemp') as create_temporary, \
                    patch.object(probe, 'BoundedProcess') as process, \
                    redirect_stdout(io.StringIO()):
                self.assertEqual(probe.main(), 1)
            experiment.assert_not_called()
            create_temporary.assert_not_called()
            process.assert_not_called()
            evidence = json.loads(path.read_bytes())
            self.assertEqual(evidence['failure'], 'python-tls13-unavailable')
            self.assertFalse(evidence['pythonTLS13'])
            self.assertEqual(evidence['commands'], [])
            self.assertEqual(evidence['cases'], [])


class PublicKeyDescriptionCompatibilityTests(unittest.TestCase):
    def test_real_parser_accepts_both_openssl_p256_descriptions_without_relaxing_curve(self):
        class AfterProfile(Exception):
            pass

        for description, accepted in (
                (b'Public-Key: (256 bit)\nASN1 OID: prime256v1\n', True),
                (b'Public-Key: (256 bit field, 128 bit security level)\nASN1 OID: prime256v1\n', True),
                (b'Public-Key: (384 bit)\nASN1 OID: secp384r1\n', False),
                (b'Public-Key: (256 bit field, 128 bit security level)\nASN1 OID: secp256k1\n', False)):
            with self.subTest(description=description), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                csr, spki = b'synthetic-not-cryptographic-csr', b'synthetic-public-spki'
                (root / 'device.csr.der').write_bytes(csr)
                startup = ready(csrSHA256=hashlib.sha256(csr).hexdigest(),
                                publicKeySHA256=hashlib.sha256(spki).hexdigest())

                def command(stage, *_args, **_kwargs):
                    if stage == 'csr-public-key':
                        return b'synthetic-public-pem', b''
                    if stage == 'csr-public-spki':
                        return spki, b''
                    if stage == 'csr-key-profile':
                        return description, b''
                    if stage == 'csr-to-pem':
                        raise AfterProfile()
                    return b'', b''

                openssl = Mock()
                openssl.run.side_effect = command
                expected = AfterProfile if accepted else probe.ProbeFailure
                with self.assertRaises(expected) as failure:
                    probe.prepare_certificates(openssl, root, startup, {})
                if not accepted:
                    self.assertEqual(failure.exception.code, 'csr-key-not-p256')


if __name__ == '__main__':
    unittest.main()
