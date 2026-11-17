"""Check submission-runner failure boundaries with local fake peers, never Swift or Codex."""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'probe-submission-ledger.py'
SPEC = importlib.util.spec_from_file_location('submission_probe', SCRIPT)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)

FRAME = {'provider': 'synthetic-local-effect', 'mode': 'retry', 'phase': 'completed',
         'hasUpstream': 'true', 'sqliteVersion': 'synthetic-test', 'integrity': 'ok'}


class SubmissionPeerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='munie-submission-peer-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.peers = []
        self.addCleanup(self.check_cleanup)
        native = probe.FixturePeer
        peers = self.peers

        class RecordingPeer(native):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                peers.append(self)

        self.recording_peer = RecordingPeer
        self.peer_patch = patch.object(probe, 'FixturePeer', RecordingPeer)
        self.peer_patch.start()
        self.addCleanup(self.peer_patch.stop)

    def check_cleanup(self):
        for peer in self.peers:
            # All runner paths must already have closed the peer. Keep the regression safe
            # if the implementation fails: attempt cleanup before reporting the invariant.
            closed_by_runner = peer.cleanup is not None
            try:
                peer.close()
            except (ValueError, OSError, subprocess.SubprocessError):
                pass
            self.assertTrue(closed_by_runner, 'Runner skipped its cleanup path')
            self.assertIsNotNone(peer.process.poll(), 'Fake peer leader was not reaped')
            self.assertIsNotNone(peer.cleanup, 'Cleanup evidence was lost on failure')
            self.assertTrue(peer.cleanup['processGroupGone'], 'Fake peer process group remains')
            self.assertEqual(probe.helper.group_members(peer.process.pid), [])

    def executable(self, code):
        executable = self.root / ('fake-' + str(len(list(self.root.glob('fake-*')))) + '.py')
        executable.write_text('#!' + sys.executable + '\n' + code, encoding='utf-8')
        executable.chmod(0o700)
        return executable

    def emits(self, frames, after=''):
        wire = b''.join(json.dumps(frame).encode() + b'\n' for frame in frames)
        return self.executable('import os,sys\n' +
                               f'os.write(sys.stdout.fileno(), {wire!r})\n' + after)

    def test_one_valid_frame_and_clean_exit_produce_complete_cleanup_evidence(self):
        attempts = []
        result = probe.run_fixture(self.emits([FRAME]), 'retry', self.root, attempts=attempts)
        self.assertEqual(result['result'], FRAME)
        self.assertEqual(result['exitStatus'], 0)
        self.assertEqual(result['cleanup'], {'exitStatus': 0, 'processGroupGone': True,
                                             'streamsReachedEOF': True})
        self.assertEqual(result['streams']['stderr']['bytes'], 0)
        self.assertEqual(result['streams']['stdout']['bytes'], len(json.dumps(FRAME).encode()) + 1)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]['cleanup'], result['cleanup'])
        self.assertEqual(attempts[0]['streams'], result['streams'])
        self.assertFalse(attempts[0]['forcedKill'])
        self.assertNotIn('failureType', attempts[0])

    def test_sigkill_requires_the_owner_lock_and_records_actual_signal_exit(self):
        frame = dict(FRAME, mode='accepted', phase='accepted', hasUpstream='false')
        executable = self.executable(
            'import fcntl,json,os,sys\nfrom pathlib import Path\n'
            'state=Path(sys.argv[2])/"state"\nstate.mkdir(mode=0o700)\n'
            'owner=os.open(state/".owner",os.O_RDWR|os.O_CREAT,0o600)\n'
            'fcntl.flock(owner,fcntl.LOCK_EX|fcntl.LOCK_NB)\n'
            f'print({json.dumps(frame)!r},flush=True)\n'
            'sys.stdin.buffer.read(1)\n')
        result = probe.kill_at_barrier(executable, 'accepted', self.root)
        self.assertEqual(result['exitStatus'], -signal.SIGKILL)
        self.assertTrue(result['ownerLockHeldAtBarrier'])
        self.assertTrue(result['cleanup']['streamsReachedEOF'])
        with (self.root / 'state/.owner').open('rb') as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_unlocked_barrier_is_rejected_instead_of_claiming_a_real_kill_window(self):
        state = self.root / 'state'
        state.mkdir()
        (state / '.owner').write_bytes(b'')
        frame = dict(FRAME, mode='accepted')
        with self.assertRaisesRegex(ValueError, 'released its owner lock'):
            probe.kill_at_barrier(self.emits([frame]), 'accepted', self.root)

    def test_unknown_provider_integrity_and_nonobject_frames_fail_closed(self):
        missing_integrity = {key: value for key, value in FRAME.items() if key != 'integrity'}
        for frame in (dict(FRAME, provider='unexpected'), dict(FRAME, integrity='failed'),
                      missing_integrity, ['unexpected']):
            with self.subTest(frame=frame):
                with self.assertRaisesRegex(ValueError, '(Unexpected synthetic|frame must be an object)'):
                    probe.run_fixture(self.emits([frame]), 'retry', self.root)

    def test_trailing_notification_or_second_response_is_not_silently_discarded(self):
        for frame in ({'method': 'unexpected/trailing', 'params': {}}, FRAME):
            with self.subTest(frame=frame):
                with self.assertRaisesRegex(ValueError, 'Unexpected trailing'):
                    probe.run_fixture(self.emits([FRAME, frame]), 'retry', self.root)

    def test_stdout_flood_is_rejected_with_bounded_memory_and_reaped_group(self):
        executable = self.executable(
            'import os,sys\nos.write(sys.stdout.fileno(),b"x"*1048576)\n')
        with self.assertRaisesRegex(ValueError, '(JSONL line|stdout byte) limit exceeded'):
            probe.run_fixture(executable, 'retry', self.root)
        peer = self.peers[-1]
        self.assertLessEqual(len(peer.buffer), probe.helper.MAX_LINE_BYTES + 8192)
        self.assertLessEqual(peer.totals['stdout'], probe.helper.MAX_STREAM_BYTES + 16384)

    def test_stderr_flood_is_rejected_without_retaining_raw_diagnostics(self):
        executable = self.executable(
            'import os,sys\nos.write(sys.stderr.fileno(),b"PRIVATE_FAKE_DIAGNOSTIC"*65536)\n')
        with self.assertRaisesRegex(ValueError, 'stderr byte limit exceeded'):
            probe.run_fixture(executable, 'retry', self.root)
        peer = self.peers[-1]
        self.assertGreater(peer.totals['stderr'], probe.helper.MAX_STREAM_BYTES)
        self.assertLessEqual(peer.totals['stderr'], probe.helper.MAX_STREAM_BYTES + 16384)
        self.assertNotIn('PRIVATE_FAKE_DIAGNOSTIC', repr(peer.__dict__))

    def test_stderr_after_the_response_is_rejected_during_cleanup(self):
        executable = self.emits([FRAME],
                                'sys.stdin.read()\n'
                                'os.write(sys.stderr.fileno(),b"x"*1048576)\n')
        with self.assertRaisesRegex(ValueError, 'stderr byte limit exceeded'):
            probe.run_fixture(executable, 'retry', self.root)

    def test_exited_leader_and_closed_stdio_do_not_hide_a_live_descendant(self):
        child_code = 'import time;time.sleep(30)'
        child_file = self.root / 'child.pid'
        executable = self.executable(
            'import json,subprocess,sys\nfrom pathlib import Path\n'
            f'child=subprocess.Popen([sys.executable,"-I","-c",{child_code!r}],'
            'stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n'
            f'Path({str(child_file)!r}).write_text(str(child.pid))\n'
            f'print({json.dumps(FRAME)!r},flush=True)\n')
        try:
            result = probe.run_fixture(executable, 'retry', self.root)
            self.assertTrue(result['cleanup']['processGroupGone'])
            self.assertTrue(result['cleanup']['streamsReachedEOF'])
            child_pid = int(child_file.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if child_file.exists():
                try:
                    os.kill(int(child_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_bad_mode_error_survives_a_trailing_frame_cleanup_error(self):
        wrong = dict(FRAME, mode='wrong-mode')
        trailing = {'method': 'unexpected/trailing', 'params': {}}
        attempts = []
        with self.assertRaisesRegex(ValueError, '^Wrong fixture barrier$'):
            probe.run_fixture(self.emits([wrong, trailing]), 'retry', self.root, attempts=attempts)
        self.assertIsNotNone(self.peers[-1].cleanup)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]['failureType'], 'ValueError')
        self.assertTrue(attempts[0]['cleanup']['processGroupGone'])
        self.assertIn('streams', attempts[0])

    def test_nonzero_exit_cannot_be_reported_as_a_successful_retry(self):
        with self.assertRaisesRegex(ValueError, 'Fixture exit/stream/cleanup mismatch'):
            probe.run_fixture(self.emits([FRAME], 'sys.exit(7)\n'), 'retry', self.root)
        self.assertEqual(self.peers[-1].cleanup['exitStatus'], 7)

    def test_silent_peer_is_bounded_by_total_deadline_and_then_reaped(self):
        native = self.recording_peer

        class ShortDeadlinePeer(native):
            def __init__(self, *args, **kwargs):
                kwargs['total_seconds'] = .1
                super().__init__(*args, **kwargs)

        executable = self.executable('import time;time.sleep(30)\n')
        started = time.monotonic()
        with patch.object(probe, 'FixturePeer', ShortDeadlinePeer):
            with self.assertRaisesRegex(ValueError, 'deadline exceeded'):
                probe.run_fixture(executable, 'retry', self.root)
        self.assertLess(time.monotonic() - started, 5)


class SubmissionReportTests(unittest.TestCase):
    def test_sigkill_after_experiment_start_invalidates_the_previous_success(self):
        with tempfile.TemporaryDirectory(prefix='munie-submission-report-') as temporary:
            root = Path(temporary)
            report = root / 'report.json'
            marker = root / 'entered-experiment'
            report.write_text(json.dumps({'status': 'passed', 'stale': True}))
            code = (
                'import importlib.util,signal,sys\nfrom pathlib import Path\n'
                f'spec=importlib.util.spec_from_file_location("probe",{str(SCRIPT)!r})\n'
                'probe=importlib.util.module_from_spec(spec)\nspec.loader.exec_module(probe)\n'
                'def blocked(*_):\n'
                f'    Path({str(marker)!r}).write_text("entered")\n'
                '    signal.pause()\n'
                'probe.experiment=blocked\n'
                f'sys.argv=["probe","--executable","/synthetic-unused","--output",{str(report)!r}]\n'
                'sys.exit(probe.main())\n')
            child = subprocess.Popen([sys.executable, '-I', '-c', code],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline and child.poll() is None:
                    time.sleep(.005)
                self.assertTrue(marker.exists(), 'Child never reached the substituted experiment')
                os.killpg(child.pid, signal.SIGKILL)
                stdout, stderr = child.communicate(timeout=3)
                self.assertEqual(child.returncode, -signal.SIGKILL)
                self.assertEqual((stdout, stderr), (b'', b''))
                retained = json.loads(report.read_text())
                self.assertEqual(retained['status'], 'failed')
                self.assertEqual(retained['phase'], 'starting')
                self.assertNotIn('stale', retained)
                self.assertEqual(report.stat().st_mode & 0o777, 0o600)
                self.assertEqual(probe.helper.group_members(child.pid), [])
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                child.communicate(timeout=3)


if __name__ == '__main__':
    unittest.main()
