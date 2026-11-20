"""Exercise the bounded JSONL transport with local subprocesses, never Codex or a network."""

import importlib.util
import json
import os
import signal
import re
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'probe-codex.py'
SPEC = importlib.util.spec_from_file_location('probe_codex', SCRIPT)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)

REQUEST = {'id': 7, 'method': 'synthetic/probe', 'params': {}}


class JsonLinePeerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='munie-peer-test-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.peers = []
        self.addCleanup(self.close_peers)

    def close_peers(self):
        errors = []
        for peer in reversed(self.peers):
            try:
                peer.close()
            except Exception as error:
                expected = getattr(peer, '_test_expected_cleanup_error', None)
                if expected is None:
                    errors.append(error)
                else:
                    self.assertIsInstance(error, ValueError)
                    self.assertRegex(str(error), expected)
            self.assertIsNotNone(peer.process.poll(), 'Test peer leader was not reaped')
            self.assertIsNotNone(peer.cleanup, 'Cleanup result must survive stream rejection')
            self.assertTrue(peer.cleanup['processGroupGone'], 'Test peer process group remains')
        if errors:
            raise errors[0]

    def peer(self, code, **timeouts):
        peer = probe.JsonLinePeer([sys.executable, '-I', '-u', '-c', code], self.directory,
                                  {'PATH': os.defpath}, **timeouts)
        self.peers.append(peer)
        return peer

    def reply(self, wire, **timeouts):
        return self.peer('import sys\nsys.stdin.readline()\n'
                         f'sys.stdout.buffer.write({wire!r})\nsys.stdout.flush()\n', **timeouts)

    def assert_bad_reply(self, wire, error):
        peer = self.reply(wire)
        with self.assertRaisesRegex((ValueError, UnicodeError), error):
            peer.request(REQUEST)
        # The only bytes ever sent upstream were the synthetic request: no approval reply.
        self.assertEqual(peer.notifications, [])

    def test_interleaved_disabled_status_is_accepted_and_identifiers_are_redacted(self):
        frames = [
            {'method': 'remoteControl/status/changed', 'params': {
                'status': 'disabled', 'hostname': 'synthetic-private-host',
                'installID': 'synthetic-private-install', 'installationId': 'private-alias'}},
            {'id': 7, 'result': {'synthetic': True}},
        ]
        peer = self.reply(('\n'.join(json.dumps(frame) for frame in frames) + '\n').encode())
        self.assertEqual(peer.request(REQUEST), frames[1])
        self.assertEqual(peer.notifications, [
            {'method': 'remoteControl/status/changed', 'params': {'status': 'disabled'}}])
        retained = json.dumps(peer.notifications)
        for private in ('hostname', 'installID', 'installationId', 'synthetic-private', 'private-alias'):
            self.assertNotIn(private, retained)

    def test_reverse_approval_rpc_is_rejected_without_answering(self):
        frame = {'id': 123, 'method': 'item/commandExecution/requestApproval',
                 'params': {'command': 'synthetic only'}}
        marker = self.directory / 'received-input.json'
        code = (
            'import json,os,select,sys\nfrom pathlib import Path\n'
            'sys.stdin.readline()\n'
            f'print({json.dumps(frame)!r},flush=True)\n'
            'readable,_,_=select.select([sys.stdin],[],[],.15)\n'
            'received=os.read(sys.stdin.fileno(),4096) if readable else b""\n'
            f'Path({str(marker)!r}).write_text(json.dumps(received.decode()))\n'
            'sys.stdin.read()\n'
        )
        peer = self.peer(code)
        with self.assertRaisesRegex(ValueError, 'Unexpected server request'):
            peer.request(REQUEST)
        deadline = time.monotonic() + 2
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.005)
        self.assertTrue(marker.exists(), 'Synthetic peer did not finish its input observation')
        self.assertEqual(json.loads(marker.read_text()), '', 'Transport answered an approval RPC')

    def test_unknown_or_enabled_notification_is_rejected(self):
        for frame in (
            {'method': 'item/agentMessage/delta', 'params': {'delta': 'unexpected'}},
            {'method': 'remoteControl/status/changed', 'params': {'status': 'enabled'}},
            {'method': 'remoteControl/status/changed', 'params': []},
        ):
            with self.subTest(frame=frame):
                self.assert_bad_reply(json.dumps(frame).encode() + b'\n', 'Unexpected server notification')

    def test_mismatched_missing_boolean_and_string_response_ids_are_rejected(self):
        for frame in ({'id': 8, 'result': {}}, {'result': {}},
                      {'id': True, 'result': {}}, {'id': '7', 'result': {}}):
            with self.subTest(frame=frame):
                self.assert_bad_reply(json.dumps(frame).encode() + b'\n', 'Mismatched response ID')

    def test_boolean_outgoing_id_is_rejected_before_sending(self):
        peer = self.peer('import sys\nsys.stdin.read()')
        with self.assertRaisesRegex(ValueError, 'request ID must be an integer'):
            peer.request(dict(REQUEST, id=True))
        self.assertEqual(peer.totals, {'stdout': 0, 'stderr': 0})

    def test_both_or_neither_result_and_error_are_rejected(self):
        for frame in ({'id': 7, 'result': {}, 'error': {'code': -1, 'message': 'failed'}}, {'id': 7}):
            with self.subTest(frame=frame):
                self.assert_bad_reply(json.dumps(frame).encode() + b'\n', 'Ambiguous result/error')

    def test_valid_error_is_preserved_and_malformed_errors_rejected(self):
        error = {'id': 7, 'error': {'code': -32600, 'message': 'synthetic failure'}}
        self.assertEqual(self.reply(json.dumps(error).encode() + b'\n').request(REQUEST), error)
        for invalid in (None, 'failed', {'code': True, 'message': 'failed'},
                        {'code': -1}, {'code': -1, 'message': 5}):
            with self.subTest(error=invalid):
                self.assert_bad_reply(json.dumps({'id': 7, 'error': invalid}).encode() + b'\n',
                                      'Invalid protocol error')

    def test_invalid_json_utf8_duplicates_and_nonobjects_are_rejected(self):
        for wire, error in (
            (b'not json\n', 'Expecting value'),
            (b'{"id":7,"result":{},"id":7}\n', 'Duplicate JSON key'),
            (b'{"id":7,"result":{"nested":1,"nested":2}}\n', 'Duplicate JSON key'),
            (b'[]\n', 'frame must be an object'),
            (b'\xff\n', 'decode'),
        ):
            with self.subTest(wire=wire):
                self.assert_bad_reply(wire, error)

    def test_request_and_total_deadlines_bound_silent_peer(self):
        for timeouts in ({'request_seconds': .12, 'total_seconds': 5},
                         {'request_seconds': 5, 'total_seconds': .12}):
            with self.subTest(timeouts=timeouts):
                peer = self.peer('import sys,time\nsys.stdin.readline()\ntime.sleep(10)', **timeouts)
                start = time.monotonic()
                with self.assertRaisesRegex(ValueError, 'deadline exceeded'):
                    peer.request(REQUEST)
                self.assertLess(time.monotonic() - start, 2)

    def test_stdout_line_limit_includes_unterminated_output(self):
        for terminator in (b'', b'\n'):
            with self.subTest(terminated=bool(terminator)):
                peer = self.reply(b'x' * (probe.MAX_LINE_BYTES + 1) + terminator)
                peer._test_expected_cleanup_error = 'JSONL line limit exceeded'
                with self.assertRaisesRegex(ValueError, 'JSONL line limit exceeded'):
                    peer.request(REQUEST)

    def test_stdout_total_limit_applies_across_many_valid_lines(self):
        with patch.object(probe, 'MAX_STREAM_BYTES', 1024):
            frame = {'id': 7, 'result': 'x' * 180}
            peer = self.peer('import sys\nfor line in sys.stdin:\n'
                             f'    print({json.dumps(frame)!r},flush=True)\n')
            accepted = 0
            with self.assertRaisesRegex(ValueError, 'stdout byte limit exceeded'):
                for _ in range(12):
                    self.assertEqual(peer.request(REQUEST), frame)
                    accepted += 1
            self.assertGreater(accepted, 1, 'Budget was not tested across multiple response reads')
            self.assertGreater(peer.totals['stdout'], 1024)
            with self.assertRaisesRegex(probe.ProbeError, 'stdout byte limit exceeded'):
                peer.close()
            self.assertTrue(peer.cleanup['streamsReachedEOF'])
            self.assertTrue(peer.cleanup['processGroupGone'])

    def test_split_over_limit_frame_is_terminal_and_cleanup_keeps_original_failure(self):
        frame = {'id': 7, 'result': 'x' * 180}
        wire = (json.dumps(frame) + '\n').encode()
        peer = self.peer('import sys\nfor line in sys.stdin:\n'
                         f'    print({json.dumps(frame)!r},flush=True)\n')
        native_read = os.read

        def split_overflow(descriptor, maximum):
            if descriptor == peer.process.stdout.fileno() and peer.totals['stdout'] >= 5 * len(wire):
                maximum = min(maximum, 8)
            return native_read(descriptor, maximum)

        with patch.object(probe, 'MAX_STREAM_BYTES', 5 * len(wire) + 4), \
                patch.object(probe.os, 'read', side_effect=split_overflow):
            for _ in range(5):
                self.assertEqual(peer.request(REQUEST), frame)
            with self.assertRaisesRegex(probe.ProbeError, 'stdout byte limit exceeded') as rejected:
                peer.request(REQUEST)
        original = rejected.exception
        with patch.object(peer, 'send', wraps=peer.send) as send:
            with self.assertRaises(probe.ProbeError) as retry:
                peer.request(REQUEST)
            self.assertIs(retry.exception, original)
            send.assert_called_once_with(REQUEST)
        with patch.object(peer.process.stdin, 'write') as write, self.assertRaises(probe.ProbeError):
            peer.send(REQUEST)
        write.assert_not_called()
        with patch.object(probe, 'strict_json', side_effect=AssertionError('reparsed rejected stream')):
            with self.assertRaises(probe.ProbeError) as closed:
                peer.close()
        self.assertIs(closed.exception, original)
        self.assertEqual(peer.totals['stdout'], 6 * len(wire))
        self.assertEqual(peer.digests['stdout'].hexdigest(), probe.hashlib.sha256(wire * 6).hexdigest())
        self.assertEqual(peer.buffer, b'')
        self.assertTrue(peer.cleanup['streamsReachedEOF'])
        self.assertTrue(peer.cleanup['processGroupGone'])
        self.assertNotIn('cleanupReadLimitReached', peer.cleanup)
        self.assertLess(peer.discard_bytes, 8192)
        self.assertIsNotNone(peer.process.poll())
        self.assertEqual(peer.close(), peer.cleanup)

    def test_terminal_discard_budget_bounds_real_flood_bytes_and_preserves_failure(self):
        for label, descriptor in (('stdout', 1), ('stderr', 2)):
            with self.subTest(stream=label), patch.object(probe, 'MAX_STREAM_BYTES', 16 * 1024):
                peer = self.peer('import os,sys\nsys.stdin.readline()\n'
                                 f'os.write({descriptor},b"x"*1048576)\n')
                with self.assertRaisesRegex(probe.ProbeError, label + ' byte limit exceeded') as rejected:
                    peer.request(REQUEST)
                rejected_total = peer.totals[label]
                with self.assertRaises(probe.ProbeError) as closed:
                    peer.close()
                self.assertIs(closed.exception, rejected.exception)
                self.assertEqual(peer.discard_bytes, 8192)
                self.assertEqual(peer.totals[label], rejected_total + 8192)
                self.assertLessEqual(peer.totals[label], probe.MAX_STREAM_BYTES + 16384)
                self.assertTrue(peer.cleanup['cleanupReadLimitReached'])
                self.assertFalse(peer.cleanup['streamsReachedEOF'])
                self.assertTrue(peer.cleanup['processGroupGone'])
                self.assertIsNotNone(peer.process.poll())
                self.assertEqual(peer.buffer, b'')
                self.assertEqual(peer.close(), peer.cleanup)

    def test_discard_reads_share_budget_across_streams_without_a_probe_after_exhaustion(self):
        peer = self.peer('import sys\nsys.stdin.readline()')
        with self.assertRaises(probe.ProbeError) as rejected:
            peer.reject_stream('stdout byte limit exceeded')
        native_read = os.read
        descriptors = {peer.process.stdout.fileno(): 'stdout', peer.process.stderr.fileno(): 'stderr'}
        reads = []
        chunks = iter((b'a' * 3000, b'b' * 4000, b'c' * 1192))

        def bounded_read(descriptor, maximum):
            if descriptor not in descriptors:
                return native_read(descriptor, maximum)
            reads.append(maximum)
            data = next(chunks)
            self.assertLessEqual(len(data), maximum)
            return data

        # Alternate both descriptors through a real selector's keys. Once the
        # budget is consumed, the next ready event must not call os.read at all.
        keys = {key.data: key for key in peer.selector.get_map().values()}
        events = iter(([(keys['stdout'], 1)], [(keys['stderr'], 1)],
                       [(keys['stdout'], 1)], [(keys['stderr'], 1)]))
        with patch.object(peer.selector, 'select', side_effect=lambda _timeout: next(events)), \
                patch.object(probe.os, 'read', side_effect=bounded_read):
            with self.assertRaisesRegex(probe.ProbeError, 'Cleanup discard byte limit exceeded'):
                peer.drain(time.monotonic() + 2)
        self.assertEqual(reads, [8192, 5192, 1192])
        self.assertEqual(peer.discard_bytes, 8192)
        self.assertEqual(peer.totals, {'stdout': 4192, 'stderr': 4000})
        self.assertEqual(peer.digests['stdout'].hexdigest(), probe.hashlib.sha256(b'a'*3000+b'c'*1192).hexdigest())
        self.assertEqual(peer.digests['stderr'].hexdigest(), probe.hashlib.sha256(b'b'*4000).hexdigest())
        with self.assertRaises(probe.ProbeError) as closed:
            peer.close()
        self.assertIs(closed.exception, rejected.exception)
        self.assertFalse(peer.cleanup['streamsReachedEOF'])
        self.assertTrue(peer.cleanup['cleanupReadLimitReached'])
        self.assertTrue(peer.cleanup['processGroupGone'])

    def test_stderr_flood_is_bounded_without_persisting_content(self):
        peer = self.peer('import sys\nsys.stdin.readline()\n'
                         f'sys.stderr.buffer.write(b"private-diagnostic" * {probe.MAX_STREAM_BYTES})\n'
                         'sys.stderr.flush()')
        peer._test_expected_cleanup_error = 'stderr byte limit exceeded'
        with self.assertRaisesRegex(ValueError, 'stderr byte limit exceeded'):
            peer.request(REQUEST)
        self.assertGreater(peer.totals['stderr'], probe.MAX_STREAM_BYTES)
        self.assertLessEqual(peer.totals['stderr'], probe.MAX_STREAM_BYTES + 8192)
        self.assertEqual(len(peer.digests['stderr'].hexdigest()), 64)
        self.assertNotIn('private-diagnostic', repr(peer.__dict__))

    def test_cleanup_read_error_preserves_stream_failure_and_records_unproven_eof(self):
        peer = self.reply(b'{"id":7,"result":{}}\n')
        with patch.object(probe, 'MAX_STREAM_BYTES', 1):
            with self.assertRaisesRegex(probe.ProbeError, 'stdout byte limit exceeded') as rejected:
                peer.request(REQUEST)
        native_read = os.read
        peer_descriptors = {peer.process.stdout.fileno(), peer.process.stderr.fileno()}

        def failed_peer_read(descriptor, maximum):
            if descriptor in peer_descriptors:
                raise OSError(5, 'synthetic read failure')
            return native_read(descriptor, maximum)

        with patch.object(probe.os, 'read', side_effect=failed_peer_read):
            with self.assertRaises(probe.ProbeError) as closed:
                peer.close()
        self.assertIs(closed.exception, rejected.exception)
        self.assertTrue(peer.cleanup['processGroupGone'])
        self.assertFalse(peer.cleanup['streamsReachedEOF'])
        self.assertTrue(peer.cleanup['drainErrors'])
        self.assertEqual(set(peer.cleanup['drainErrors']), {'OSError'})
        self.assertNotIn('synthetic read failure', json.dumps(peer.cleanup))
        self.assertIsNotNone(peer.process.poll())
        self.assertEqual(peer.close(), peer.cleanup)

    def test_eof_before_response_fails(self):
        peer = self.peer('import sys\nsys.stdin.readline()')
        with self.assertRaisesRegex(ValueError, 'stdout closed before response'):
            peer.request(REQUEST)

    def test_notification_flood_does_not_extend_request_forever(self):
        frame = {'method': 'remoteControl/status/changed', 'params': {'status': 'disabled'}}
        peer = self.reply((json.dumps(frame) + '\n').encode() * 5)
        with self.assertRaisesRegex(ValueError, 'Unexpected notification volume'):
            peer.request(REQUEST)

    def test_trailing_unknown_frame_is_rejected_during_cleanup(self):
        response = json.dumps({'id': 7, 'result': {}}) + '\n'
        for trailing in (
            {'method': 'unexpected/trailing', 'params': {}},
            {'id': 99, 'method': 'item/commandExecution/requestApproval', 'params': {}},
        ):
            with self.subTest(trailing=trailing):
                code = ('import sys\nsys.stdin.readline()\n'
                        f'sys.stdout.write({response!r})\nsys.stdout.flush()\n'
                        'sys.stdin.read()\n'
                        f'print({json.dumps(trailing)!r},flush=True)\n')
                peer = self.peer(code)
                self.assertEqual(peer.request(REQUEST), {'id': 7, 'result': {}})
                with self.assertRaisesRegex(ValueError, 'Unexpected (server request|server notification)'):
                    peer.close()
                self.assertTrue(peer.cleanup['processGroupGone'])
                self.assertIsNotNone(peer.process.poll())
                self.assertEqual(peer.close(), peer.cleanup)

    def test_trailing_stderr_flood_is_bounded_and_process_reaped(self):
        response = json.dumps({'id': 7, 'result': {}}) + '\n'
        code = ('import sys\nsys.stdin.readline()\n'
                f'sys.stdout.write({response!r})\nsys.stdout.flush()\n'
                'sys.stdin.read()\n'
                f'sys.stderr.buffer.write(b"x" * {probe.MAX_STREAM_BYTES + 8192})\n'
                'sys.stderr.flush()\n')
        peer = self.peer(code)
        self.assertEqual(peer.request(REQUEST), {'id': 7, 'result': {}})
        with self.assertRaisesRegex(ValueError, 'stderr byte limit exceeded'):
            peer.close()
        self.assertTrue(peer.cleanup['processGroupGone'])
        self.assertIsNotNone(peer.process.poll())
        self.assertGreater(peer.totals['stderr'], probe.MAX_STREAM_BYTES)

    def test_cleanup_rejects_open_stream_after_original_group_is_gone(self):
        if os.name != 'posix':
            self.skipTest('Process-group isolation requires POSIX')
        # Both real subprocesses inherit the same OS stdout pipe. The independent holder is
        # our direct child in another session, so this test can always kill AND reap it.
        read_fd, write_fd = os.pipe()
        reader = os.fdopen(read_fd, 'rb')
        native_popen = subprocess.Popen
        holder = None
        peer = None

        def shared_stdout_peer(*args, **kwargs):
            kwargs['stdout'] = write_fd
            process = native_popen(*args, **kwargs)
            process.stdout = reader
            return process

        try:
            holder = native_popen([sys.executable, '-I', '-c', 'import time; time.sleep(30)'],
                                  stdin=subprocess.DEVNULL, stdout=write_fd,
                                  stderr=subprocess.DEVNULL, start_new_session=True)
            with patch.object(probe.subprocess, 'Popen', shared_stdout_peer):
                peer = self.peer('import json,sys\nsys.stdin.readline()\n'
                                 'print(json.dumps({"id":7,"result":{}}),flush=True)')
            os.close(write_fd)
            write_fd = None
            self.assertEqual(peer.request(REQUEST), {'id': 7, 'result': {}})
            peer.process.wait(timeout=2)
            self.assertNotEqual(os.getpgid(holder.pid), peer.process.pid)
            self.assertIsNone(holder.poll(), 'Independent pipe holder must still be alive')
            with self.assertRaisesRegex(ValueError, 'streams did not reach EOF'):
                peer.close()
            self.assertTrue(peer.cleanup['processGroupGone'])
            self.assertFalse(peer.cleanup['streamsReachedEOF'])
            self.assertEqual(peer.close(), peer.cleanup)
        finally:
            if write_fd is not None:
                os.close(write_fd)
            if holder is not None:
                if holder.poll() is None:
                    holder.kill()
                holder.wait(timeout=2)
                self.assertIsNotNone(holder.returncode, 'Independent pipe holder was not reaped')
            if peer is None:
                reader.close()

    def test_cleanup_checks_child_group_even_after_leader_and_pipes_exit(self):
        if os.name != 'posix':
            self.skipTest('Process-group isolation requires POSIX')
        # Child closes inherited pipes, so EOF and leader exit do not prove the group is gone.
        child_code = 'import time\ntime.sleep(30)'
        parent_code = (
            'import json,subprocess,sys\n'
            'sys.stdin.readline()\n'
            f'child=subprocess.Popen([sys.executable,"-I","-c",{child_code!r}],\n'
            '    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n'
            'print(json.dumps({"id":7,"result":{"childPID":child.pid}}),flush=True)\n'
        )
        peer = self.peer(parent_code)
        child_pid = peer.request(REQUEST)['result']['childPID']
        self.assertEqual(os.getpgid(child_pid), peer.process.pid)
        try:
            peer.process.wait(timeout=2)
            cleanup = peer.close()
            self.assertTrue(cleanup['processGroupGone'])
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            # The regression must not leak a real child when tested against a broken implementation.
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_cleanup_terminates_process_group_and_is_idempotent(self):
        if os.name != 'posix':
            self.skipTest('Process-group isolation requires POSIX')
        child_code = 'import signal,time\nsignal.signal(signal.SIGTERM, lambda *_: exit(0))\ntime.sleep(30)'
        # Parent reaps the group child on TERM so no orphan/zombie makes the result timing-dependent.
        parent_code = (
            'import json,signal,subprocess,sys\n'
            f'child = subprocess.Popen([sys.executable,"-I","-u","-c",{child_code!r}])\n'
            'def terminate(*_):\n'
            '    child.wait(timeout=2)\n'
            '    sys.exit(0)\n'
            'signal.signal(signal.SIGTERM, terminate)\n'
            'sys.stdin.readline()\n'
            'print(json.dumps({"id":7,"result":{"childPID":child.pid}}),flush=True)\n'
            'sys.stdin.read()\n'
            'signal.pause()\n'
        )
        peer = self.peer(parent_code)
        child_pid = peer.request(REQUEST)['result']['childPID']
        self.assertEqual(os.getpgid(child_pid), peer.process.pid)
        self.assertEqual(os.getpgid(peer.process.pid), peer.process.pid)
        cleanup = peer.close()
        self.assertTrue(cleanup['processGroupGone'])
        self.assertIsNotNone(peer.process.poll())
        self.assertEqual(peer.close(), cleanup)
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)
        groups = subprocess.check_output(['/bin/ps', '-axo', 'pid=,pgid='], text=True)
        members = [int(pid) for pid, group in (line.split() for line in groups.splitlines())
                   if int(group) == peer.process.pid]
        self.assertEqual(members, [], 'Peer group still contains numeric process members')


class ReportSafetyTests(unittest.TestCase):
    def test_sigkill_during_experiment_cannot_leave_previous_pass_report(self):
        if os.name != 'posix':
            self.skipTest('This regression requires SIGKILL')
        with tempfile.TemporaryDirectory(prefix='munie-report-test-') as directory:
            root = Path(directory)
            output = root / 'report.json'
            ready = root / 'experiment-ready'
            output.write_text(json.dumps({'status': 'passed', 'oldEvidence': True}))
            output.chmod(0o644)
            code = (
                'import importlib.util,sys,time\nfrom pathlib import Path\n'
                'script,ready,output=sys.argv[1:]\n'
                'spec=importlib.util.spec_from_file_location("synthetic_probe",script)\n'
                'module=importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n'
                'def synthetic_experiment(*_):\n'
                '    Path(ready).write_text("ready")\n'
                '    time.sleep(30)\n'
                'module.experiment=synthetic_experiment\n'
                'sys.argv=[script,"--codex","/synthetic/codex",\n'
                '    "--schema-dir","/synthetic/schema",\n'
                '    "--default-schema-dir","/synthetic/default","--output",output]\n'
                'sys.exit(module.main())\n'
            )
            process = subprocess.Popen([sys.executable, '-I', '-u', '-c', code,
                                        str(SCRIPT), str(ready), str(output)],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 3
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists(), 'Synthetic experiment did not reach its ready marker')
                self.assertIsNone(process.poll())
                process.kill()
                self.assertEqual(process.wait(timeout=2), -signal.SIGKILL)
                report = json.loads(output.read_text())
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(report['phase'], 'starting')
                self.assertNotIn('oldEvidence', report)
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=2)
                process.stdout.close()
                process.stderr.close()

    def test_atomic_report_replaces_symlink_and_preserves_linked_file(self):
        if os.name != 'posix':
            self.skipTest('This regression requires POSIX symlinks and permissions')
        with tempfile.TemporaryDirectory(prefix='munie-report-link-test-') as directory:
            root = Path(directory)
            protected = root / 'protected.json'
            original = b'{"synthetic": "pristine bytes"}\n'
            protected.write_bytes(original)
            protected.chmod(0o644)
            output = root / 'report.json'
            output.symlink_to(protected)
            report = {'status': 'failed', 'phase': 'starting'}
            probe.write_report(output, report)
            self.assertFalse(output.is_symlink())
            self.assertEqual(json.loads(output.read_text()), report)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(protected.read_bytes(), original)
            self.assertEqual(protected.stat().st_mode & 0o777, 0o644)
            self.assertEqual(list(root.glob('.codex-probe-*')), [], 'Atomic-write temporary file leaked')


class StrictJSONAndSandboxTests(unittest.TestCase):
    def test_strict_json_rejects_nonfinite_numbers_at_every_depth(self):
        for value in (b'NaN', b'Infinity', b'-Infinity', b'1e999', b'-1e999',
                      b'{"result":{"nested":[1e999]}}'):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, 'Non-finite'):
                    probe.strict_json(value)
        self.assertEqual(probe.strict_json(b'{"values":[0,-1,1.5,1e-9]}'),
                         {'values': [0, -1, 1.5, 1e-9]})

    def test_sandbox_profile_preserves_denials_and_one_write_root(self):
        fixture = Path('/tmp/synthetic fixture"escaped')
        protected = Path('/tmp/synthetic-protected')
        real_home = Path('/synthetic-real-home')
        profile = probe.sandbox_profile(fixture, protected, real_home)
        self.assertIn('(deny network*)', profile)
        self.assertIn('(deny file-write*)', profile)
        self.assertEqual(profile.count('(allow file-write*'), 1)
        self.assertIn('(allow file-write* (subpath ' + json.dumps(str(fixture)) + '))', profile)
        self.assertIn('(deny file-read*', profile)
        for blocked in (real_home, protected, Path('/Library/Keychains'), Path('/etc/codex')):
            self.assertIn('(subpath ' + json.dumps(str(blocked)) + ')', profile)
        self.assertIn('(deny mach-lookup)', profile)
        self.assertNotIn('(allow network', profile)
        allowed_rules = re.findall(
            r'\(allow mach-lookup\s+((?:\(global-name "[^"]+"\)\s*)+)\)', profile)
        self.assertEqual(len(allowed_rules), profile.count('(allow mach-lookup'),
                         'Mach lookup exceptions must use explicit service names only')
        allowed_names = re.findall(r'\(global-name "([^"]+)"\)', ''.join(allowed_rules))
        self.assertCountEqual(allowed_names, ['com.apple.cfprefsd.agent', 'com.apple.cfprefsd.daemon'])


if __name__ == '__main__':
    unittest.main()
