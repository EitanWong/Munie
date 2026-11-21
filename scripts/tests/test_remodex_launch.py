"""Imported runtime launcher fixtures. Only synthetic Codex peers and temporary projects are used."""
import json
import ast
import errno
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / 'scripts/run-remodex-local.sh'
SETUP = ROOT / 'scripts/setup-remodex.sh'


class RemodexLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='munie remodex fixture ')
        self.directory = Path(self.temporary.name).resolve()
        self.project = self.directory / 'project'
        self.project.mkdir()
        self.state = self.directory / 'private-state'
        self.state.mkdir(mode=0o700)
        self.codex = self.directory / 'synthetic-codex'
        node = shutil.which('node')
        if not node:
            self.skipTest('Node.js is unavailable; run scripts/setup-remodex.sh.')
        self.codex.write_text('#!' + node + '\n' + '''const fs = require('fs');
const path = require('path');
fs.writeFileSync(path.join(process.cwd(), 'fixture-launch.json'), JSON.stringify({
  args: process.argv.slice(2), cwd: process.cwd(), codexHome: process.env.CODEX_HOME,
  binary: process.env.REMODEX_CODEX_BINARY, pid: process.pid,
  inheritedSecret: process.env.OPENAI_API_KEY || null }));
const readline = require('readline').createInterface({ input: process.stdin });
readline.on('line', line => {
  fs.appendFileSync(path.join(process.cwd(), 'fixture-requests.jsonl'), line + '\\n');
  const request = JSON.parse(line);
  if (request.id != null) process.stdout.write(JSON.stringify({id: request.id, result: {}}) + '\\n');
});
process.on('SIGTERM', () => process.exit(0));
''')
        self.codex.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, **overrides):
        values = {'--codex': self.codex, '--project': self.project, '--state-dir': self.state}
        values.update(overrides)
        return [str(RUN), *[str(value) for item in values.items() for value in item]]

    def test_requires_explicit_codex_and_project_without_starting_a_service(self):
        result = subprocess.run([str(RUN)], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--codex', result.stderr)
        self.assertFalse((self.state / 'run.json').exists())

    def test_refuses_missing_binary_existing_service_port_and_unscoped_home(self):
        cases = [self.command(**{'--codex': self.directory / 'absent'}),
                 self.command(**{'--relay-port': 9274}), self.command(**{'--project': Path.home()})]
        for command in cases:
            result = subprocess.run(command, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse((self.state / 'run.json').exists())

    def test_setup_uses_locked_install_without_any_lifecycle_scripts_or_runtime_start(self):
        tools = self.directory / 'tools'
        tools.mkdir()
        calls = self.directory / 'setup-calls.txt'
        for name in ('node', 'npm', 'xcrun'):
            executable = tools / name
            executable.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIXTURE_SETUP_CALLS"\nexit 0\n')
            executable.chmod(0o755)
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], FIXTURE_SETUP_CALLS=str(calls))
        result = subprocess.run([str(SETUP)], env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        install = [line for line in calls.read_text().splitlines() if ' ci ' in line]
        self.assertEqual(len(install), 2)
        self.assertTrue(all('--ignore-scripts' in line for line in install))
        self.assertIn('No bridge, relay, or model was started', result.stdout)

    def test_actual_fork_starts_with_synthetic_peer_advertises_wss_and_cleans_owned_groups(self):
        if not (ROOT / 'apps/MunieRemodexBridge/node_modules/ws/package.json').exists():
            self.skipTest('Run scripts/setup-remodex.sh before the synthetic runtime fixture.')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        output = (self.directory / 'launcher.log').open('w')
        child = subprocess.Popen(self.command(**{'--relay-port': port, '--advertise-relay': 'wss://fixture.invalid:8443'}),
                                 stdout=output, stderr=subprocess.STDOUT,
                                 env=dict(os.environ, OPENAI_API_KEY='synthetic-never-inherited'), start_new_session=True)
        try:
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    self.fail((self.directory / 'launcher.log').read_text())
                pairing = self.state / 'device/pairing-session.json'
                launched = self.project / 'fixture-launch.json'
                if pairing.exists() and launched.exists():
                    break
                time.sleep(0.05)
            else:
                self.fail('Synthetic bridge did not reach pairing: ' + (self.directory / 'launcher.log').read_text())
            value = json.loads(pairing.read_text())
            self.assertEqual(value['pairingPayload']['relay'], 'wss://fixture.invalid:8443/relay')
            launch = json.loads(launched.read_text())
            self.assertEqual(launch['cwd'], str(self.project))
            self.assertEqual(launch['binary'], str(self.codex))
            self.assertEqual(launch['codexHome'], str(self.state / 'codex-home'))
            self.assertIsNone(launch['inheritedSecret'])
            self.assertEqual(launch['args'][0], 'app-server')
            self.assertFalse((self.project / 'fixture-requests.jsonl').exists(), 'The launcher must not submit a turn.')
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=15), 0)
            report = json.loads((self.state / 'run.json').read_text())
            self.assertEqual(report['status'], 'stopped')
            self.assertEqual(report['connectRelay'], 'ws://127.0.0.1:' + str(port) + '/relay')
            self.assertTrue(all(item['processGroupGone'] for item in report['processes']))
            self.assertEqual(len(report['processes']), 2)
        finally:
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
            output.close()

    def test_permission_race_keeps_polling_until_observed_disappearance(self):
        source = RUN.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        tree = ast.parse(source)
        helpers = ast.Module(body=[item for item in tree.body if isinstance(item, ast.FunctionDef)
                                   and item.name in ('group_gone', 'stop_owned_group')], type_ignores=[])
        namespace = {'os': os, 'signal': signal, 'time': time}
        exec(compile(helpers, str(RUN), 'exec'), namespace)
        probes = iter([PermissionError(errno.EPERM, 'fixture exiting group'),
                       PermissionError(errno.EPERM, 'fixture exiting group'),
                       ProcessLookupError(errno.ESRCH, 'fixture gone'),
                       ProcessLookupError(errno.ESRCH, 'fixture gone')])
        signals = []

        def killpg(pid, requested):
            if requested == 0:
                raise next(probes)
            signals.append(requested)
            raise PermissionError(errno.EPERM, 'fixture signal race')

        record = {'primaryFailure': 'original fixture failure'}
        namespace['stop_owned_group'](SimpleNamespace(pid=111, poll=lambda: 7), record,
                                     killpg=killpg, pause=lambda duration: None)
        self.assertTrue(record['processGroupGone'])
        self.assertEqual(record['exitStatus'], 7)
        self.assertEqual(record['primaryFailure'], 'original fixture failure')
        self.assertEqual(signals, [signal.SIGTERM])
        self.assertEqual({entry['operation'] for entry in record['cleanupErrors']}, {'probe', 'signal'})

    def test_native_peer_start_failure_is_retained_and_owned_services_are_cleaned(self):
        if not (ROOT / 'apps/MunieRemodexBridge/node_modules/ws/package.json').exists():
            self.skipTest('Run scripts/setup-remodex.sh before the synthetic runtime fixture.')
        self.codex.write_text('#!/bin/sh\nprintf "fixture native failure\\n" >&2\nexit 7\n')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        result = subprocess.run(self.command(**{'--relay-port': port}), capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        report = json.loads((self.state / 'run.json').read_text())
        self.assertEqual(report['status'], 'failed')
        self.assertIn('exited', report['failure'])
        self.assertTrue(all(item['processGroupGone'] for item in report['processes']))
        self.assertTrue(any(item['exitStatus'] != 0 for item in report['processes']))
        self.assertIn('fixture native failure', (Path(report['evidenceDirectory']) / 'bridge.log').read_text())

    def exercise_owner_exit(self, requested):
        if not (ROOT / 'build/remodex-tools/MunieCodexGuardian').is_file():
            self.skipTest('Run scripts/setup-remodex.sh to build the existing native guardian.')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        output = (self.directory / 'owner-exit.log').open('w')
        child = subprocess.Popen(self.command(**{'--relay-port': port}), stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        groups = []
        try:
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    self.fail((self.directory / 'owner-exit.log').read_text())
                try:
                    report = json.loads((self.state / 'run.json').read_text())
                    if report['status'] == 'running' and (self.project / 'fixture-launch.json').is_file():
                        groups = [record['pid'] for record in report['processes']]
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(0.05)
            else:
                self.fail('Synthetic owner did not reach readiness.')
            launch = json.loads((self.project / 'fixture-launch.json').read_text())
            child.send_signal(requested)
            child.wait(timeout=15)
            if requested == signal.SIGHUP:
                self.assertEqual(child.returncode, 0)
                self.assertEqual(json.loads((self.state / 'run.json').read_text())['status'], 'stopped')
            else:
                self.assertEqual(child.returncode, -signal.SIGKILL)
            deadline = time.monotonic() + 8
            remaining = list(groups)
            while remaining and time.monotonic() < deadline:
                for group in list(remaining):
                    try:
                        os.killpg(group, 0)
                    except ProcessLookupError:
                        remaining.remove(group)
                    except PermissionError:
                        pass
                time.sleep(0.05)
            self.assertEqual(remaining, [], 'An owned service group survived launcher exit.')
            with self.assertRaises(ProcessLookupError):
                os.kill(launch['pid'], 0)
            with socket.socket() as connection:
                self.assertNotEqual(connection.connect_ex(('127.0.0.1', port)), 0)
        finally:
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
                child.wait(timeout=15)
            for group in groups:
                try:
                    os.killpg(group, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            output.close()

    def test_hangup_stops_services_and_records_cleanup(self):
        self.exercise_owner_exit(signal.SIGHUP)

    def test_killed_owner_is_observed_by_existing_native_guardian(self):
        self.exercise_owner_exit(signal.SIGKILL)

    def test_persistent_permission_denial_is_bounded_and_never_claimed_gone(self):
        source = RUN.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        tree = ast.parse(source)
        helpers = ast.Module(body=[item for item in tree.body if isinstance(item, ast.FunctionDef)
                                   and item.name in ('group_gone', 'stop_owned_group')], type_ignores=[])
        namespace = {'os': os, 'signal': signal, 'time': time}
        exec(compile(helpers, str(RUN), 'exec'), namespace)
        clock = iter(range(100))

        def denied(pid, requested):
            raise PermissionError(errno.EPERM, 'fixture persistent denial')

        record = {}
        namespace['stop_owned_group'](SimpleNamespace(pid=111, poll=lambda: None), record,
            killpg=denied, monotonic=lambda: next(clock), pause=lambda duration: None)
        self.assertFalse(record['processGroupGone'])
        self.assertEqual([entry['signal'] for entry in record['cleanupErrors'] if entry['operation'] == 'signal'],
                         [signal.SIGTERM, signal.SIGKILL])


if __name__ == '__main__':
    unittest.main()
