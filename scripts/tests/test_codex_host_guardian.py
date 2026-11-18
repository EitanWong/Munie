"""Real subprocess regressions for the fixture guardian; no Codex/model/network process."""

import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

GUARDIAN = Path(__file__).resolve().parents[1] / 'codex-host-guardian.py'
ENVIRONMENT = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'MUNIE_SYNTHETIC': 'explicit'}


def members(group):
    query = subprocess.run(['/bin/ps', '-g', str(group), '-o', 'pid=,pgid='],
                           capture_output=True, text=True, timeout=2, check=False)
    if query.returncode not in (0, 1):
        raise RuntimeError('group query failed')
    return [int(fields[0]) for line in query.stdout.splitlines()
            if len(fields := line.split()) == 2 and int(fields[1]) == group]


class GuardianTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='munie-guardian-tests-')
        self.root = Path(self.temporary.name).resolve()
        self.processes = []
        self.groups = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=2)
        for group in self.groups:
            if members(group):
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.wait_gone(group)
        self.temporary.cleanup()

    def wait_gone(self, group):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if not members(group):
                return
            time.sleep(.02)
        self.fail('owned guardian group remains')

    def wait_file(self, path):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if path.exists():
                return
            time.sleep(.01)
        self.fail('fixture file did not appear')

    def command(self, registry, script, parent=None):
        return [sys.executable, '-I', str(GUARDIAN), '--parent-pid', str(parent or os.getpid()),
                '--registry', str(registry), '--', '/usr/bin/python3', '-I', '-c', script]

    def start(self, script, registry=None, stdin=subprocess.PIPE):
        registry = registry or self.root / 'registry.json'
        process = subprocess.Popen(self.command(registry, script), cwd=self.root,
                                   env=ENVIRONMENT, stdin=stdin, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        self.processes.append(process)
        self.groups.append(process.pid)
        return process

    def registry(self, path, parent, guardian):
        record = json.loads(path.read_bytes())
        self.assertEqual(record, {'registryVersion': 1, 'processGroupID': guardian,
                                  'guardianPID': guardian, 'parentPID': parent})
        info = path.lstat()
        self.assertTrue(stat.S_ISREG(info.st_mode))
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
        self.assertEqual(info.st_nlink, 1)
        self.assertEqual(info.st_uid, os.geteuid())
        self.assertFalse(list(self.root.glob('.guardian-*')))
        return record

    def test_forwards_bytes_and_explicit_environment_then_reaps_normal_eof(self):
        process = self.start(
            'import hashlib,json,os,sys; data=sys.stdin.buffer.read(); '
            'print(json.dumps({"sha":hashlib.sha256(data).hexdigest(),"bytes":len(data),'
            '"group":os.getpgrp(),"explicit":os.environ.get("MUNIE_SYNTHETIC"),'
            '"home":"HOME" in os.environ}))')
        # Keep the host input open until the guardian has registered and launched the child.
        self.wait_file(self.root / 'registry.json')
        data = bytes(range(256)) * 800
        output, error = process.communicate(input=data, timeout=5)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(error, b'')
        result = json.loads(output)
        self.assertEqual(result, {'sha': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
                                  'group': process.pid, 'explicit': 'explicit', 'home': False})
        self.registry(self.root / 'registry.json', os.getpid(), process.pid)
        self.wait_gone(process.pid)

    def test_closed_stdin_before_start_registers_without_launching_native(self):
        marker = self.root / 'must-not-run'
        process = self.start(f'from pathlib import Path; Path({str(marker)!r}).write_text("ran")',
                             stdin=subprocess.DEVNULL)
        output, error = process.communicate(timeout=3)
        self.assertEqual((process.returncode, output, error), (0, b'', b''))
        self.registry(self.root / 'registry.json', os.getpid(), process.pid)
        self.assertFalse(marker.exists())
        self.wait_gone(process.pid)

    def test_registry_never_overwrites_regular_file_or_symlink(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                registry = self.root / ('symlink.json' if symlink else 'existing.json')
                target = self.root / 'pristine'
                target.write_bytes(b'pristine')
                if symlink:
                    registry.symlink_to(target)
                else:
                    registry.write_bytes(b'pristine')
                process = self.start('raise RuntimeError("must not launch")', registry=registry)
                output, error = process.communicate(timeout=3)
                self.assertEqual((process.returncode, output, error),
                                 (1, b'', b'Native host guardian failed\n'))
                self.assertEqual(target.read_bytes(), b'pristine')
                self.assertEqual(registry.read_bytes(), b'pristine')
                self.assertEqual(registry.is_symlink(), symlink)
                self.wait_gone(process.pid)

    def test_spawn_failure_retains_registry_and_has_no_descendants(self):
        process = subprocess.Popen(
            [sys.executable, '-I', str(GUARDIAN), '--parent-pid', str(os.getpid()),
             '--registry', str(self.root / 'registry.json'), '--', '/missing-native-synthetic'],
            cwd=self.root, env=ENVIRONMENT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True)
        self.processes.append(process)
        self.groups.append(process.pid)
        self.wait_file(self.root / 'registry.json')
        # Do not close input before the attempted launch.
        process.wait(timeout=3)
        output, error = process.communicate(timeout=1)
        self.assertEqual((process.returncode, output, error),
                         (1, b'', b'Native host guardian failed\n'))
        self.registry(self.root / 'registry.json', os.getpid(), process.pid)
        self.wait_gone(process.pid)

    def test_backpressure_eof_escalates_with_bounded_pending_memory(self):
        marker = self.root / 'native.pid'
        process = self.start(
            f'import os,signal,time; open({str(marker)!r},"w").write(str(os.getpid())); '
            'signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)')
        self.wait_file(marker)
        # Fits the bounded guardian buffer, while the native peer never reads any input.
        output, error = process.communicate(input=b'x' * 32_768, timeout=5)
        self.assertEqual(process.returncode, -signal.SIGKILL)
        self.assertEqual((output, error), (b'', b''))
        self.wait_gone(process.pid)

    def host(self, child_script, immediately_kill=False):
        registry = self.root / 'registry.json'
        host_code = (
            'import os,signal,subprocess,time\n'
            f'command={self.command(registry, child_script, parent=999999)!r}\n'
            'command[command.index("--parent-pid")+1]=str(os.getpid())\n'
            'guardian=subprocess.Popen(command,stdin=subprocess.PIPE,start_new_session=True)\n'
        )
        if immediately_kill:
            host_code += 'os.kill(os.getpid(),signal.SIGKILL)\n'
        else:
            host_code += 'time.sleep(60)\n'
        host = subprocess.Popen([sys.executable, '-I', '-c', host_code], cwd=self.root,
                                env=ENVIRONMENT, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        self.processes.append(host)
        self.groups.append(host.pid)
        return host

    def test_host_death_before_pgid_message_still_publishes_and_cleans_group(self):
        host = self.host('import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
                         'time.sleep(60)', immediately_kill=True)
        output, error = host.communicate(timeout=5)
        self.assertEqual(host.returncode, -signal.SIGKILL)
        self.assertEqual((output, error), (b'', b''))
        self.wait_file(self.root / 'registry.json')
        record = json.loads((self.root / 'registry.json').read_bytes())
        group = record['processGroupID']
        self.groups.append(group)
        self.registry(self.root / 'registry.json', host.pid, group)
        self.wait_gone(group)

    def test_host_death_after_native_spawn_kills_ignored_term_and_orphan_descendant(self):
        marker = self.root / 'native.json'
        pending_marker = marker.with_suffix('.pending')
        child = (
            'import json,os,signal,time\n'
            'signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
            'child=os.fork()\n'
            'if child==0:\n'
            '    while True: time.sleep(1)\n'
            f'with open({str(pending_marker)!r},"w") as output:\n'
            '    json.dump([os.getpid(),child],output)\n'
            f'os.replace({str(pending_marker)!r},{str(marker)!r})\n'
            'while True: time.sleep(1)\n'
        )
        host = self.host(child)
        self.wait_file(marker)
        record = json.loads((self.root / 'registry.json').read_bytes())
        group = record['processGroupID']
        self.groups.append(group)
        pids = json.loads(marker.read_bytes())
        self.assertTrue(all(os.getpgid(pid) == group for pid in pids))
        host.kill()
        output, error = host.communicate(timeout=5)
        self.assertEqual(host.returncode, -signal.SIGKILL)
        self.assertEqual((output, error), (b'', b''))
        self.wait_gone(group)
        for pid in pids:
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_parent_pid_mismatch_never_launches_and_does_not_signal_other_group(self):
        process = subprocess.Popen(self.command(self.root / 'registry.json',
                                               'raise RuntimeError("must not launch")', parent=2),
                                   cwd=self.root, env=ENVIRONMENT, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        self.processes.append(process)
        self.groups.append(process.pid)
        process.wait(timeout=3)
        output, error = process.communicate(timeout=1)
        self.assertEqual((process.returncode, output, error), (0, b'', b''))
        self.registry(self.root / 'registry.json', 2, process.pid)
        self.wait_gone(process.pid)

    def test_nonzero_native_exit_preserves_status_and_streams(self):
        marker = self.root / 'native-ready'
        process = self.start(
            f'import os,time; open({str(marker)!r},"w").write("ready"); '
            'os.write(1,b"synthetic protocol\\n"); os.write(2,b"native diagnostic\\n"); '
            'time.sleep(.05); os._exit(7)')
        self.wait_file(marker)
        process.wait(timeout=3)
        output, error = process.communicate(timeout=1)
        self.assertEqual(process.returncode, 7)
        self.assertEqual(output, b'synthetic protocol\n')
        self.assertEqual(error, b'native diagnostic\n')
        self.wait_gone(process.pid)

    def test_guardian_term_handler_is_not_inherited_as_native_ignore(self):
        marker = self.root / 'native-ready'
        process = self.start(
            f'import time; open({str(marker)!r},"w").write("ready"); time.sleep(60)')
        self.wait_file(marker)
        output, error = process.communicate(timeout=4)
        # Native default TERM exit propagates as 128 + 15; guardian must not need self-KILL.
        self.assertEqual((process.returncode, output, error), (143, b'', b''))
        self.wait_gone(process.pid)

    def test_exited_leader_does_not_hide_live_descendant(self):
        marker = self.root / 'descendant.pid'
        process = self.start(
            'import os,signal,time\n'
            'child=os.fork()\n'
            'if child==0:\n'
            '    signal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
            '    while True: time.sleep(1)\n'
            f'open({str(marker)!r},"w").write(str(child))\n'
            'os._exit(0)\n')
        self.wait_file(marker)
        process.wait(timeout=4)
        output, error = process.communicate(timeout=1)
        self.assertEqual((process.returncode, output, error), (-signal.SIGKILL, b'', b''))
        self.wait_gone(process.pid)

    def test_refuses_shared_group_without_signalling_it(self):
        process = subprocess.Popen(self.command(self.root / 'registry.json', 'pass'),
                                   cwd=self.root, env=ENVIRONMENT, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        output, error = process.communicate(timeout=3)
        self.assertEqual((process.returncode, output, error),
                         (1, b'', b'Native host guardian failed\n'))
        self.assertFalse((self.root / 'registry.json').exists())


if __name__ == '__main__':
    unittest.main()
