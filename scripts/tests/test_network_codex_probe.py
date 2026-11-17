"""Offline HTTP/protocol boundaries and real bridge-process cleanup; no Codex/model runs."""

from contextlib import contextmanager, redirect_stderr, redirect_stdout
from email.message import Message
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / 'probe-network-codex.py'
SPEC = importlib.util.spec_from_file_location('network_codex_under_test', SCRIPT)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
FINGERPRINT = hashlib.sha256(b'synthetic verified socket peer DER').hexdigest()
TOKEN = '80000000-0000-0000-0000-000000000001'
TEXT = 'Execute the Munie native host fixture: text'


def reply(**changes):
    return {'event': 'result', 'state': 'codex-snapshot', 'requestID': probe.ledger.REQUEST_A,
            'phase': 'running', 'hasUpstream': True, 'cancellationRequested': False,
            'pendingApproval': False, **changes}


def native_reply(**changes):
    return {'bodyBytes': 200, 'overflow': False, 'redirectRejected': False,
            'cancelledOnResponse': False, 'serverChallenges': 1, 'clientChallenges': 1,
            'trustRejected': 0, 'httpStatus': 200, 'tlsProtocol': 772, 'proxy': False,
            **reply(), **changes}


def body(route='submit', **changes):
    value = {'requestID': probe.ledger.REQUEST_A}
    if route == 'submit':
        value.update(projectID=probe.ledger.PROJECT, payload=TEXT)
    if route == 'approval':
        value.update(approvalToken=TOKEN, decision='accept')
    return json.dumps({**value, **changes}).encode('utf-8')


def native_cleanup(**changes):
    return {'leaderExitStatus': 0, 'stdoutEOF': True, 'stderrEOF': True, 'groupGone': True,
            'escalated': False, 'stdinBytes': 100, 'stdoutBytes': 200, 'stderrBytes': 0, **changes}


def handler(policy, operation='submit', data=None, headers=None):
    request = probe.CodexHTTPHandler.__new__(probe.CodexHTTPHandler)
    request.path = '/fixture/' + operation
    request.connection = Mock()
    request.connection.getpeercert.return_value = b'synthetic verified socket peer DER'
    request.server = SimpleNamespace(policy=policy)
    data = body(operation) if data is None else data
    request.rfile = io.BytesIO(data)
    request.send_result = Mock()
    request.headers = Message()
    for name, value in (headers if headers is not None else [
            ('Content-Type', 'application/json'), ('Content-Length', str(len(data)))]):
        request.headers.add_header(name, value)
    return request


class HTTPBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.bridge = Mock()
        self.bridge.call.return_value = reply()
        self.policy = probe.CodexPolicy(self.bridge)

    def test_socket_identity_wins_over_forged_headers_for_submit_and_approval(self):
        for operation in ('submit', 'approval'):
            with self.subTest(operation=operation):
                self.bridge.reset_mock()
                data = body(operation)
                request = handler(self.policy, operation, data, [
                    ('Content-Type', 'application/json'), ('Content-Length', str(len(data))),
                    ('X-Munie-Device', probe.ledger.DEVICE_B),
                    ('X-Munie-Fingerprint', 'f' * 64), ('Authorization', 'Bearer forged')])
                request.do_POST()
                request.connection.getpeercert.assert_called_once_with(binary_form=True)
                command = self.bridge.call.call_args.args[0]
                self.assertEqual(command['peerFingerprint'], FINGERPRINT)
                self.assertNotIn('deviceID', command)
                self.assertNotIn('Authorization', command)
                self.assertEqual(self.policy.results[-1]['peerFingerprint'], FINGERPRINT)

    def test_only_public_routes_reach_their_fixed_local_operation(self):
        operations = {'submit': 'submit', 'snapshot': 'snapshot', 'events': 'nextEvent',
                      'approval': 'approval', 'interrupt': 'interrupt', 'reconcile': 'reconcile'}
        for operation, local in operations.items():
            with self.subTest(operation=operation):
                self.bridge.reset_mock()
                handler(self.policy, operation).do_POST()
                self.assertEqual(self.bridge.call.call_args.args[0]['operation'], local)
        for operation in ('revoke', 'claim', 'rpc', 'nextEvent', 'authorizeDevice',
                          '../submit', 'submit/', 'submit?operation=revoke', '%73ubmit'):
            with self.subTest(operation=operation):
                self.bridge.reset_mock()
                request = handler(self.policy, operation)
                request.do_POST()
                request.send_result.assert_called_once_with(404, {'error': 'fixture-route'}, close=True)
                self.bridge.call.assert_not_called()

    def test_no_body_can_choose_identity_host_path_or_administrative_action(self):
        for operation in probe.OPERATIONS:
            for field in ('deviceID', 'peerFingerprint', 'hostID', 'cwd', 'config', 'operation'):
                with self.subTest(operation=operation, field=field):
                    self.assertEqual(self.policy.request(operation, FINGERPRINT,
                        body(operation, **{field: 'synthetic-injection'})),
                        (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()
        self.assertEqual(self.policy.results, [])

    def test_control_routes_cannot_smuggle_submit_or_approval_parameters(self):
        for operation in ('snapshot', 'events', 'interrupt', 'reconcile'):
            for extra in ({'projectID': probe.ledger.PROJECT}, {'payload': TEXT},
                          {'approvalToken': TOKEN}, {'decision': 'accept'}):
                with self.subTest(operation=operation, extra=extra):
                    self.assertEqual(self.policy.request(operation, FINGERPRINT,
                        body(operation, **extra)), (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()

    def test_approval_requires_canonical_token_and_one_time_decision(self):
        for change in ({'approvalToken': True}, {'approvalToken': 'bad-token'},
                       {'approvalToken': TOKEN.replace('80000000', 'aaaaaaaa')},
                       {'decision': True}, {'decision': 'acceptForSession'},
                       {'decision': 'accept '}, {'decision': 'decline'}, {'decision': None}):
            with self.subTest(change=change):
                self.assertEqual(self.policy.request('approval', FINGERPRINT,
                    body('approval', **change)), (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()
        for decision in ('accept', 'cancel'):
            self.policy.request('approval', FINGERPRINT, body('approval', decision=decision))
            self.assertEqual(self.bridge.call.call_args.args[0], {
                'operation': 'approval', 'peerFingerprint': FINGERPRINT,
                'requestID': probe.ledger.REQUEST_A, 'approvalToken': TOKEN, 'decision': decision})

    def test_otherwise_valid_duplicate_escaped_keys_and_invalid_values_never_forward(self):
        valid = body('approval').decode()
        duplicate = valid.replace('"decision": "accept"',
                                  '"decision":"cancel","\\u0064ecision":"accept"').encode()
        invalid = [duplicate, b'\xff', b'null', b'[]', body(requestID=True),
                   body(requestID='bad-id'), body(projectID=False), body(payload=True),
                   body(payload=' \n\t'), body(payload='界' * 683)]
        for data in invalid:
            with self.subTest(data=data[:60]):
                operation = 'approval' if data is duplicate else 'submit'
                self.assertEqual(self.policy.request(operation, FINGERPRINT, data),
                                 (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()

    def test_ambiguous_http_framing_rejects_before_identity_or_stdio(self):
        content = ('Content-Type', 'application/json')
        for headers in ([content], [content, ('Content-Length', '2'), ('Content-Length', '2')],
                        [content, ('Content-Length', '2'), ('Transfer-Encoding', 'chunked')],
                        [content, ('Content-Length', '٢')], [content, ('Content-Length', '2049')]):
            with self.subTest(headers=headers):
                request = handler(self.policy, data=b'{}', headers=headers)
                request.do_POST()
                self.assertIn(request.send_result.call_args.args[0], (400, 413))
                request.connection.getpeercert.assert_not_called()
        self.bridge.call.assert_not_called()

    def test_wrong_request_or_private_native_fields_cannot_be_forwarded_or_retained(self):
        for frame in (reply(requestID=probe.ledger.REQUEST_B), reply(nativePayload=TEXT),
                      reply(command='/bin/private'), reply(cwd='/private/home'),
                      reply(installationID='private-installation'),
                      {'event': 'result', 'error': 'private-error-details'}):
            with self.subTest(frame=frame):
                self.bridge.call.return_value = frame
                request = handler(self.policy)
                with self.assertRaises(ValueError) as raised:
                    request.do_POST()
                self.assertEqual(self.policy.failure, type(raised.exception).__name__)
                self.assertEqual(self.policy.results, [])
                request.send_result.assert_not_called()

    def test_domain_denial_is_distinct_from_success_and_does_not_include_state(self):
        for error, status in (('unauthorized', 200), ('unknown-request', 404),
                              ('invalid-approval', 409), ('invalid-state', 409)):
            with self.subTest(error=error):
                self.bridge.call.return_value = {'event': 'result', 'error': error}
                self.assertEqual(self.policy.request('snapshot', FINGERPRINT, body('snapshot')),
                                 (status, {'error': error}))
                self.assertNotIn('state', self.policy.results[-1]['result'])


class ReplyEvidenceTests(unittest.TestCase):
    def test_failure_frame_is_sanitized_before_retention_and_cannot_escape_validation(self):
        bridge = probe.CodexBridge(Path('/bridge'), Path('/codex'), Path('/synthetic'), 'text', {})
        bridge.peer = Mock()
        valid = {'event': 'failure', 'code': 'transport-failure', 'cleanup': native_cleanup(),
                 'cleanupError': None}
        bridge.peer.read_frame.return_value = valid
        with self.assertRaises(ValueError):
            bridge.call({'operation': 'snapshot'})
        self.assertEqual(bridge.report['bridgeFailure'], valid)
        for frame in (dict(valid, code=[]), dict(valid, cleanupError={}),
                      dict(valid, code='private-native-error'), dict(valid, rawStderr=TEXT)):
            with self.subTest(frame=frame):
                bridge.report.clear()
                bridge.peer.read_frame.return_value = frame
                with self.assertRaises(ValueError):
                    bridge.call({'operation': 'snapshot'})
                self.assertNotIn('bridgeFailure', bridge.report)

    def test_booleans_uuid_phase_and_approval_correlation_fail_closed(self):
        invalid = [reply(phase='invented'), reply(requestID=True), reply(requestID='bad-id'),
                   reply(approvalToken=TOKEN), reply(pendingApproval=True, approvalToken=True),
                   reply(pendingApproval=True, approvalToken='bad-token'),
                   reply(agentMessageMatched=True), reply(eventKind='approval', agentMessageMatched=1),
                   reply(eventKind='native-private-event'), reply(phase=True)]
        for key in ('hasUpstream', 'cancellationRequested', 'pendingApproval'):
            invalid.extend((reply(**{key: 0}), reply(**{key: 'false'})))
            incomplete = reply();del incomplete[key];invalid.append(incomplete)
        for frame in invalid:
            with self.subTest(frame=frame), self.assertRaises(ValueError):
                probe.validate_reply(frame)
        pending = reply(pendingApproval=True, approvalToken=TOKEN,
                        eventKind='approval', agentMessageMatched=False)
        self.assertEqual(probe.validate_reply(pending), pending)

    def test_native_domain_schema_cannot_weaken_transport_or_hide_sensitive_fields(self):
        invalid = [native_reply(proxy=True), native_reply(tlsProtocol=771),
                   native_reply(errorCode=-999), native_reply(bodyBytes=True),
                   native_reply(ordinal=1), native_reply(rawBody=TEXT),
                   native_reply(fixtureError='unauthorized'), native_reply(httpStatus=409)]
        for key in ('state', 'requestID', 'phase', 'pendingApproval'):
            incomplete = native_reply();del incomplete[key];invalid.append(incomplete)
        for frame in invalid:
            with self.subTest(frame=frame), self.assertRaises(ValueError):
                probe.validate_native_reply(frame)
        self.assertEqual(probe.validate_native_reply(native_reply()), native_reply())

    def test_native_cleanup_requires_real_boolean_eof_group_exit_and_protocol_traffic(self):
        invalid = [native_cleanup(leaderExitStatus=True), native_cleanup(leaderExitStatus=-9),
                   native_cleanup(stdoutEOF=1), native_cleanup(stderrEOF=False),
                   native_cleanup(groupGone=False), native_cleanup(stdinBytes=True),
                   native_cleanup(stdinBytes=0), native_cleanup(stdoutBytes=0),
                   native_cleanup(stderrBytes=-1), native_cleanup(stdoutBytes=33_554_433),
                   native_cleanup(rawStderr='private')]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                probe.validate_cleanup(value)
        probe.validate_cleanup(native_cleanup())

    def test_pump_requires_bound_approval_and_matching_terminal_output(self):
        report, context = {}, (Path('/synthetic'), Mock(), Mock(), 'text')
        for frame in (reply(eventKind='approval'), reply(phase='completed', eventKind='terminal'),
                      reply(phase='failed', eventKind='terminal', agentMessageMatched=True)):
            with self.subTest(frame=frame), patch.object(probe, 'observe', return_value=frame):
                with self.assertRaises(ValueError):
                    probe.pump(report, *context, stop_at_approval=True)

    def test_old_success_is_invalidated_and_failure_messages_stay_private(self):
        for failure in (ValueError('synthetic-private-token-path'),
                        probe.helper.ProbeError('synthetic-private-token-path')):
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'report.json'
                output.write_text('{"status":"passed","obsolete":"old"}')

                def fail(_arguments, _report):
                    value = json.loads(output.read_bytes())
                    self.assertEqual((value['status'], value['phase']), ('failed', 'starting'))
                    self.assertNotIn('obsolete', value)
                    self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                    _report['scenarios'] = [{'checks': [{'result': {
                        'pendingApproval': True, 'approvalToken': TOKEN}}]}]
                    raise failure

                arguments = ['probe']
                for name in ('native-executable', 'ledger-executable', 'codex', 'schema-dir',
                             'default-schema-dir', 'openssl'):
                    arguments.extend(('--' + name, '/synthetic-' + name))
                arguments.extend(('--output', str(output)))
                stdout, stderr = io.StringIO(), io.StringIO()
                with patch.object(probe.sys, 'argv', arguments), \
                        patch.object(probe, 'experiment', side_effect=fail), \
                        redirect_stdout(stdout), redirect_stderr(stderr):
                    self.assertEqual(probe.main(), 1)
                self.assertNotIn('synthetic-private', output.read_text() + stdout.getvalue() + stderr.getvalue())
                self.assertNotIn('PASS', stdout.getvalue())
                persisted = json.loads(output.read_bytes())
                self.assertEqual(persisted['scenarios'][0]['checks'][0]['result'], {
                    'pendingApproval': True, 'approvalTokenPresent': True})
                self.assertNotIn(TOKEN, output.read_text())

    def test_success_report_omits_tokens_without_mutating_live_correlations(self):
        report = {'status': 'passed', 'checks': [{'result': reply(
            pendingApproval=True, approvalToken=TOKEN)}],
            'serverPolicyResponses': [{'result': {'approvalToken': TOKEN}}]}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'report.json'
            probe.write_report(output, report)
            persisted = json.loads(output.read_bytes())
            self.assertNotIn(TOKEN, output.read_text())
            self.assertTrue(persisted['checks'][0]['result']['approvalTokenPresent'])
            self.assertEqual(persisted['serverPolicyResponses'], [
                {'result': {'approvalTokenPresent': True}}])
            self.assertEqual(report['checks'][0]['result']['approvalToken'], TOKEN)


class OwnershipCleanupTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Requires the actual macOS sandbox')
    def test_native_sandbox_denies_control_and_identity_reads_and_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workspace = root / 'projects' / probe.ledger.PROJECT
            workspace.mkdir(parents=True)
            (root / 'projects' / probe.ledger.OTHER_PROJECT).mkdir()
            for name in ('codex-data', 'tmp', 'state'):
                (root / name).mkdir()
            for name in ('device-b.key', 'device-b.p12', 'p12-password', 'codex-config-1.json',
                         'state/submissions.sqlite3', 'native-codex.json'):
                (root / name).write_bytes(b'synthetic control, no real credential')
            (root / 'sandbox.sb').write_text(probe.native_sandbox_profile(
                root, workspace, root / 'protected', 9))
            report = {}
            probe.verify_native_control_isolation(root, workspace, report)
            self.assertEqual(len(report['nativeControlIsolation']['denials']), 16)
            self.assertEqual(report['nativeControlIsolation']['nativeDirectoryRoundtrips'], 3)

    def bridge(self, root=Path('/synthetic')):
        report = {'bridgeProcesses': [{}]}
        bridge = probe.CodexBridge(Path('/bridge'), Path('/codex'), root, 'text', report)
        peer = Mock(cleanup={'exitStatus': 0, 'streamsReachedEOF': True, 'processGroupGone': True},
                    totals={'stdout': 100, 'stderr': 0},
                    digests={'stdout': hashlib.sha256(), 'stderr': hashlib.sha256()})
        peer.process.pid = 123456789
        peer.read_frame.return_value = {'event': 'closed', 'cleanup': native_cleanup()}
        bridge.peer, bridge.native_group = peer, 234567890
        return bridge, peer, report

    def test_bad_close_ack_still_reaps_bridge_and_checks_native_group(self):
        bridge, peer, report = self.bridge()
        peer.read_frame.return_value = {'event': 'closed', 'cleanup': native_cleanup(stdoutEOF=False)}
        with patch.object(probe.host.probe, 'group_members', return_value=[]) as members:
            with self.assertRaises(ValueError) as raised:
                bridge.stop()
        peer.close.assert_called_once_with()
        members.assert_called_with(234567890)
        self.assertTrue(report['bridgeProcesses'][0]['guardianGroupGone'])
        self.assertEqual(report['bridgeProcesses'][0]['cleanupFailureType'], type(raised.exception).__name__)
        self.assertIsNone(bridge.peer)

    def test_signal_failure_is_preserved_after_bridge_and_native_cleanup_attempts(self):
        bridge, peer, report = self.bridge()
        primary = PermissionError('synthetic-private-signal')
        peer.close.side_effect = ValueError('synthetic-private-drain')
        with patch.object(probe.os, 'killpg', side_effect=primary), \
                patch.object(probe.host.probe, 'group_members', return_value=[]):
            with self.assertRaises(PermissionError) as raised:
                bridge.stop(killed=True)
        self.assertIs(raised.exception, primary)
        peer.close.assert_called_once_with()
        self.assertEqual(report['bridgeProcesses'][0]['cleanupFailureType'], 'PermissionError')
        self.assertNotIn('synthetic-private', json.dumps(report))

    def test_native_inspection_failure_still_attempts_native_termination(self):
        bridge, peer, _report = self.bridge()
        with patch.object(probe.host.probe, 'group_members', side_effect=OSError('synthetic-ps')), \
                patch.object(probe.host, 'stop_native_group', return_value=True) as terminate:
            with self.assertRaises(OSError):
                bridge.stop()
        peer.close.assert_called_once_with()
        terminate.assert_called_once_with(234567890)

    def test_restart_startup_failure_recovers_the_new_guardian_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bridge, peer, report = self.bridge(root)
            bridge.peer = None
            registry = root / 'native-codex.json';registry.write_text('previous synthetic registry')

            def launch(*_arguments, **_keywords):
                registry.write_text('new synthetic registry')
                return peer

            peer.read_frame.side_effect = [ValueError('synthetic-ready-failure'),
                                          {'event': 'closed', 'cleanup': native_cleanup()}]
            with patch.object(probe.network, 'fingerprint', return_value=FINGERPRINT), \
                    patch.object(probe, 'CodexPeer', side_effect=launch), \
                    patch.object(probe.host.probe, 'group_members', return_value=[]), \
                    patch.object(probe.host, 'registered_group', return_value=345678901) as registered:
                with self.assertRaises(ValueError):
                    bridge.start(False)
                bridge.stop()
            registered.assert_called_once_with(registry, peer.process.pid)
            self.assertEqual(bridge.native_group, 345678901)

    def test_scenario_failure_always_closes_provider_even_when_bridge_cleanup_fails(self):
        for primary in (ValueError('synthetic-private-run'), None):
            with self.subTest(primary=primary):
                provider, bridge = Mock(), Mock()
                provider.thread.is_alive.return_value = False
                provider.socket.fileno.return_value = -1
                bridge.stop.side_effect = OSError('synthetic-private-cleanup')
                failure = primary or OSError('synthetic-private-sandbox')
                args = SimpleNamespace(ledger_executable=Path('/bridge'), codex=Path('/codex'))
                report = {}
                with patch.object(probe.host, 'HostFixtureServer', return_value=provider), \
                        patch.object(probe, 'CodexBridge', return_value=bridge), \
                        patch.object(probe, 'prepare_sandbox', side_effect=failure):
                    with self.assertRaises(type(failure)) as raised:
                        probe.run_scenario(args, Path('/synthetic'), 'password', report, 'text')
                self.assertIs(raised.exception, failure)
                bridge.stop.assert_called_once_with()
                provider.close.assert_called_once_with()
                self.assertTrue(report['providerStopped'])
                self.assertNotIn('synthetic-private', json.dumps(report))

    def test_provider_close_failure_after_successful_flow_cannot_return_success(self):
        provider, bridge = Mock(), Mock()
        provider.total = 1
        failure = OSError('synthetic-private-provider-close')
        provider.close.side_effect = failure
        args = SimpleNamespace(ledger_executable=Path('/bridge'), codex=Path('/codex'),
                               native_executable=Path('/native'))
        report = {'checks': []}

        @contextmanager
        def server(_context, _policy, record, **_options):
            record['serverStopped'] = True
            yield 60443

        @contextmanager
        def client(*_arguments):
            yield Mock(transfer=Mock(return_value={'fixtureError': 'request-conflict'}))

        final_rows = {'requests': [{'requestID': probe.ledger.REQUEST_A}],
                      'upstream': [{'threadID': probe.ledger.REQUEST_B,
                                    'turnID': probe.ledger.REQUEST_C}]}
        with patch.object(probe.host, 'HostFixtureServer', return_value=provider), \
                patch.object(probe, 'CodexBridge', return_value=bridge), \
                patch.object(probe, 'prepare_sandbox'), \
                patch.object(probe, 'verify_native_control_isolation'), \
                patch.object(probe.native, 'observed_server_context'), \
                patch.object(probe.network, 'running_server', side_effect=server), \
                patch.object(probe, 'client', side_effect=client), \
                patch.object(probe, 'observe', return_value=reply(phase='completed')), \
                patch.object(probe, 'pump'), patch.object(probe, 'raw_denials'), \
                patch.object(probe.host, 'effect_count', return_value=0), \
                patch.object(probe, 'rows', return_value=final_rows):
            with self.assertRaises(OSError) as raised:
                probe.run_scenario(args, Path('/synthetic'), 'password', report, 'text')
        self.assertIs(raised.exception, failure)
        self.assertEqual(bridge.stop.call_count, 2)
        provider.close.assert_called_once_with()
        self.assertEqual(report['providerCleanupFailureType'], 'OSError')
        self.assertNotIn('synthetic-private', json.dumps(report))

    def test_actual_bridge_process_normal_close_and_sigkill_are_reaped(self):
        for killed in (False, True):
            with self.subTest(killed=killed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                script = root / 'offline-peer.py'
                script.write_text('import json,sys\n'
                    'print(json.dumps({"event":"offline-ready"}),flush=True)\n'
                    'for line in sys.stdin: pass\n'
                    'print(json.dumps(' + repr({'event': 'closed', 'cleanup': native_cleanup()}) +
                    '),flush=True)\n', encoding='utf-8')
                peer = probe.CodexPeer([sys.executable, '-I', str(script)], root,
                                      {'PATH': '/usr/bin:/bin'}, total_seconds=10)
                self.addCleanup(lambda value=peer: probe.helper.JsonLinePeer.close(value))
                self.assertEqual(peer.read_frame(probe.time.monotonic() + 2), {'event': 'offline-ready'})
                bridge, _fake, report = self.bridge(root)
                bridge.peer = peer
                with patch.object(probe.host.probe, 'group_members', return_value=[]):
                    bridge.stop(killed=killed)
                self.assertEqual(peer.cleanup, {'exitStatus': -signal.SIGKILL if killed else 0,
                                               'streamsReachedEOF': True, 'processGroupGone': True})
                self.assertTrue(report['bridgeProcesses'][0]['guardianGroupGone'])


if __name__ == '__main__':
    unittest.main()
