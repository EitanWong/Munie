#!/usr/bin/env python3
"""Opt-in Swift ledger + pinned native Codex experiments with a synthetic provider."""

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

SPEC = importlib.util.spec_from_file_location(
    'host_lifecycle', Path(__file__).with_name('probe-codex-turns.py'))
lifecycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifecycle)
probe = lifecycle.probe
require = probe.require
CASES = ('text', 'approval-cancel', 'approval-accept', 'running-interrupt',
         'pending-crash', 'mapped-crash', 'mapping-loss', 'startup-loss')
EFFECT_COMMAND = '/bin/echo effect >> approval-effects'
RUNNING_COMMAND = ('echo $$ > running-shell.pid; /bin/sleep 30 & child=$!; '
                   'echo $child > running-child.pid; wait $child; /usr/bin/touch after-interrupt')


def validate_user_input(body, scenario):
    users = [item for item in body['input']
             if type(item) is dict and item.get('role') == 'user']
    require(bool(users), 'Missing native user input')
    content = users[-1].get('content')
    expected = 'Execute the Munie native host fixture: ' + scenario
    require(type(content) is list and len(content) == 1 and type(content[0]) is dict and
            content[0].get('type') == 'input_text' and
            content[0].get('text') == expected, 'Native user input did not match submission')


class HostFixtureServer(lifecycle.FixtureServer):
    def __init__(self, workspace):
        super().__init__(workspace)
        self.RequestHandlerClass = HostFixtureHandler
        self.response_sent = threading.Event()

    def select(self, case):
        require(case in CASES, 'Unknown native host scenario')
        with self.lock:
            self.case, self.count = case, 0
            self.started.clear()
            self.response_sent.clear()


class HostFixtureHandler(lifecycle.FixtureHandler):
    def do_POST(self):
        server = self.server
        try:
            require(self.path == server.path and self.client_address[0] == '127.0.0.1',
                    'Invalid fixture endpoint')
            require(self.headers.get_all('Authorization') is None and
                    self.headers.get_all('Cookie') is None, 'Fixture forbids credentials')
            require(self.headers.get_all('Transfer-Encoding') is None and
                    len(self.headers.get_all('Content-Length', [])) == 1,
                    'Invalid fixture framing')
            length = int(self.headers.get('Content-Length', '0'))
            require(0 < length <= lifecycle.MAX_REQUEST, 'Fixture request size exceeded')
            data = self.rfile.read(length)
            require(len(data) == length, 'Truncated fixture request')
            body = probe.strict_json(data)
            require(type(body) is dict and body.get('model') == lifecycle.MODEL and
                    body.get('stream') is True and type(body.get('input')) is list,
                    'Unexpected fixture request')
            with server.lock:
                case = server.case
                server.count += 1
                server.total += 1
                count = server.count
                validate_user_input(body, case)
                maximum = 2 if case == 'approval-accept' else 1
                require(case in CASES and count <= maximum and server.total <= maximum,
                        'Unexpected native provider retry')
            tool_case = case in ('approval-cancel', 'approval-accept', 'running-interrupt',
                                 'pending-crash')
            if tool_case and count == 1:
                require(any(t.get('name') == 'exec_command' for t in body.get('tools', [])),
                        'Native command tool unavailable')
                command = RUNNING_COMMAND if case == 'running-interrupt' else EFFECT_COMMAND
                item = {'type': 'function_call', 'id': 'fc_host', 'call_id': 'call_host',
                        'name': 'exec_command', 'arguments': json.dumps({
                            'cmd': command, 'shell': '/bin/sh', 'login': False,
                            'workdir': str(server.workspace), 'yield_time_ms': 10000,
                            'max_output_tokens': 1000, 'sandbox_permissions': 'require_escalated',
                            'justification': 'Munie native host fixture approval'})}
            else:
                if case == 'approval-accept':
                    require(any(i.get('type') == 'function_call_output' and
                                i.get('call_id') == 'call_host' and
                                type(i.get('output')) is str and bool(i['output'])
                                for i in body['input']), 'Missing actual tool response')
                item = {'type': 'message', 'id': 'msg_host', 'role': 'assistant',
                        'status': 'completed', 'content': [{'type': 'output_text',
                            'text': lifecycle.MARKER, 'annotations': []}]}
            data = lifecycle.sse(item, 'resp_host_' + str(count))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
            server.response_sent.set()
        except (ValueError, OSError, UnicodeError, TypeError, KeyError):
            server.failure = 'host-request-rejected'
            self.close_connection = True


class HostPeer(probe.JsonLinePeer):
    def accept_notification(self, frame):
        raise ValueError('Unexpected trailing host diagnostic frame')


def stop_native_group(group_id):
    """Only the numeric group emitted immediately after this fixture's trusted spawn."""
    require(type(group_id) is int and group_id > 1 and group_id != os.getpgrp(),
            'Invalid spawned native group')
    try:
        os.killpg(group_id, signal.SIGKILL)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 5
    while probe.group_members(group_id) and time.monotonic() < deadline:
        time.sleep(.02)
    require(not probe.group_members(group_id), 'Native fixture group remains')
    return {'processGroupGone': True, 'forcedKill': True}


def registered_group(path, parent_id):
    deadline = time.monotonic() + 5
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(.01)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and
                stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == os.geteuid() and
                info.st_size <= 1024, 'Unsafe native launch registry')
        value = probe.strict_json(os.read(descriptor, 1025))
    finally:
        os.close(descriptor)
    require(type(value) is dict and set(value) == {
        'registryVersion', 'processGroupID', 'guardianPID', 'parentPID'} and
        all(type(v) is int for v in value.values()) and value['registryVersion'] == 1 and
        value['parentPID'] == parent_id and value['processGroupID'] == value['guardianPID'] and
        value['processGroupID'] > 1, 'Invalid native launch registry')
    return value['processGroupID']


def validate_result(frame, scenario, mode):
    require(set(frame) == {'milestone', 'mode', 'scenario', 'phase', 'hasUpstream',
        'pendingApproval', 'eventCount', 'commandCompleted', 'commandExit', 'cleanup',
        'toolProcessesGoneBeforeClose', 'agentMessageMatched'}, 'Unexpected result fields')
    for key in ('hasUpstream', 'pendingApproval', 'commandCompleted',
                'toolProcessesGoneBeforeClose', 'agentMessageMatched'):
        require(type(frame[key]) is bool, 'Invalid result boolean')
    require(type(frame['eventCount']) is int and 0 <= frame['eventCount'] <= 256 and
            (frame['commandExit'] is None or type(frame['commandExit']) is int) and
            frame['pendingApproval'] is False, 'Invalid result state')
    expected = ('reconciling' if scenario in ('pending-crash', 'mapped-crash', 'mapping-loss')
                else 'cancelled' if scenario in ('approval-cancel', 'running-interrupt')
                else 'completed')
    if mode == 'recover':
        expected = 'completed' if scenario == 'mapped-crash' else (
            'cancelled' if scenario == 'pending-crash' else 'reconciling')
    require(frame['phase'] == expected and frame['hasUpstream'] is (scenario != 'mapping-loss'),
            'Unexpected recovered native task state')
    if mode == 'start' and scenario in ('text', 'approval-accept'):
        require(frame['agentMessageMatched'] is True, 'Native assistant marker was not verified')
    if mode == 'start' and scenario == 'approval-accept':
        require(frame['commandCompleted'] is True and frame['commandExit'] == 0,
                'Approved native tool did not complete successfully')
    if mode == 'start' and scenario == 'running-interrupt':
        require(frame['toolProcessesGoneBeforeClose'] is True,
                'Tool termination was not verified before transport shutdown')
    if mode == 'start':
        require(frame['eventCount'] > 0, 'Native result had no observed events')
    cleanup = frame['cleanup']
    require(type(cleanup) is dict and set(cleanup) == {'leaderExitStatus', 'stdoutEOF',
        'stderrEOF', 'groupGone', 'escalated', 'stdinBytes', 'stdoutBytes', 'stderrBytes'},
        'Invalid native cleanup fields')
    require(all(type(cleanup[key]) is bool for key in ('stdoutEOF', 'stderrEOF', 'groupGone',
        'escalated')) and cleanup['stdoutEOF'] and cleanup['stderrEOF'] and cleanup['groupGone'] and
        all(type(cleanup[key]) is int and 0 <= cleanup[key] <= 33_554_432
            for key in ('stdinBytes', 'stdoutBytes', 'stderrBytes')) and
        cleanup['stderrBytes'] <= 1_048_576, 'Native cleanup/stream bounds failed')
    require(cleanup['stdinBytes'] > 0 and cleanup['stdoutBytes'] > 0,
            'Native result had no protocol traffic')
    expected_status = 9 if mode == 'start' and scenario in ('pending-crash', 'mapped-crash') else 0
    require(type(cleanup['leaderExitStatus']) is int and cleanup['leaderExitStatus'] == expected_status,
            'Unexpected native process terminal status')


def validate_milestone(frame, previous, scenario, mode):
    require(type(frame) is dict and frame.get('scenario') == scenario and
            frame.get('mode') == mode, 'Unexpected host fixture frame')
    milestone = frame.get('milestone')
    require(type(milestone) is str, 'Invalid host fixture milestone')
    expected_barrier = {'pending-crash': 'awaitingApproval', 'mapped-crash': 'running',
                        'mapping-loss': 'dispatching'}
    if milestone == 'arming':
        require(scenario == 'startup-loss' and mode == 'start' and not previous and
                set(frame) == {'milestone', 'mode', 'scenario'}, 'Unexpected startup-loss barrier')
    elif milestone == 'spawned':
        require(not previous and scenario != 'startup-loss' and
                set(frame) == {'milestone', 'mode', 'scenario', 'nativeGroup'} and
                type(frame['nativeGroup']) is int, 'Invalid native launch ordering')
    elif milestone == 'barrier':
        require(mode == 'start' and scenario in expected_barrier and previous == ['spawned'] and
                set(frame) == {'milestone', 'mode', 'scenario', 'phase'} and
                frame['phase'] == expected_barrier[scenario], 'Invalid native fault barrier')
    elif milestone == 'result':
        expected = ['spawned', 'barrier'] if mode == 'start' and scenario in expected_barrier else [
            'spawned']
        require(scenario not in ('startup-loss',) and
                not (mode == 'start' and scenario == 'mapping-loss') and previous == expected,
                'Native result bypassed required fault barrier')
    else:
        raise ValueError('Unknown host fixture milestone')


def execute_host(executable, codex, root, scenario, mode, provider, attempts):
    peer = HostPeer([str(executable), mode, scenario, str(root), str(codex)], root,
                    {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8'},
                    total_seconds=60)
    native_group = None
    killed_host = False
    native_finished = False
    result = {'mode': mode, 'scenario': scenario, 'milestones': []}
    primary = None
    registry = root / ('native-' + mode + '.json')
    try:
        while True:
            try:
                frame = peer.read_frame(time.monotonic() + 25)
            except (ValueError, OSError):
                if scenario != 'startup-loss' or result['milestones'] != [
                        {'milestone': 'arming', 'mode': mode, 'scenario': scenario}]:
                    raise
                native_group = registered_group(registry, peer.process.pid)
                killed_host = True
                result['startupLossRegistry'] = True
                result['faultInjected'] = True
                break
            validate_milestone(frame, [f['milestone'] for f in result['milestones']], scenario, mode)
            milestone = frame['milestone']
            require(type(milestone) is str and len(result['milestones']) < 16,
                    'Host fixture milestone limit')
            result['milestones'].append(frame)
            if milestone == 'spawned':
                require(native_group is None and type(frame.get('nativeGroup')) is int,
                        'Invalid native launch identity')
                native_group = frame['nativeGroup']
                require(native_group > 1 and native_group != peer.process.pid,
                        'Native group was not isolated')
                require(registered_group(registry, peer.process.pid) == native_group,
                        'Native group did not match independent launch registry')
            elif milestone == 'arming':
                require(scenario == 'startup-loss' and mode == 'start' and
                        len(result['milestones']) == 1, 'Unexpected startup-loss barrier')
            elif milestone == 'barrier':
                require(mode == 'start' and native_group is not None and
                        scenario in ('pending-crash', 'mapped-crash', 'mapping-loss'),
                        'Unexpected host barrier')
                result['faultInjected'] = True
                if scenario in ('mapped-crash', 'mapping-loss'):
                    require(provider.response_sent.wait(5), 'Native provider was not consumed')
                if scenario == 'mapping-loss':
                    # The durable claim exists; the trusted adapter has the upstream IDs but has
                    # not returned them to the coordinator. Killing the owner loses that mapping.
                    os.killpg(peer.process.pid, signal.SIGKILL)
                    killed_host = True
                    result['nativeForcedCleanup'] = stop_native_group(native_group)
                    break
                os.killpg(native_group, signal.SIGKILL)
                os.write(peer.process.stdin.fileno(), b'\n')
            elif milestone == 'result':
                validate_result(frame, scenario, mode)
                result['result'] = frame
                break
            else:
                raise ValueError('Unknown host fixture milestone')
        peer.close()
        require(peer.cleanup['exitStatus'] == (-signal.SIGKILL if killed_host else 0) and
                peer.cleanup['processGroupGone'] and peer.cleanup['streamsReachedEOF'] and
                peer.totals['stderr'] == 0, 'Host fixture exit/cleanup failed')
        if killed_host:
            deadline = time.monotonic() + 5
            while probe.group_members(native_group) and time.monotonic() < deadline:
                time.sleep(.02)
        require(native_group is not None and not probe.group_members(native_group),
                'Native group leaked after host completion')
        native_finished = True
        result['cleanup'] = peer.cleanup
        result['streams'] = {name: {'bytes': peer.totals[name], 'sha256': d.hexdigest()}
                             for name, d in peer.digests.items()}
        return result
    except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        primary = error
        raise
    finally:
        cleanup_failure = None
        try:
            peer.close()
        except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
            cleanup_failure = error
        finally:
            observation = dict(result, hostCleanup=peer.cleanup)
            try:
                if native_group is None and registry.exists():
                    native_group = registered_group(registry, peer.process.pid)
                # A failed ps observation must never skip the initial cleanup signal.
                if native_group is not None and not native_finished:
                    observation['finalNativeCleanup'] = stop_native_group(native_group)
                elif native_finished:
                    observation['finalNativeCleanup'] = {'processGroupGone': True, 'forcedKill': False}
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                observation['nativeCleanupFailure'] = type(error).__name__
                cleanup_failure = cleanup_failure or error
            finally:
                if primary is not None:
                    observation['failureType'] = type(primary).__name__
                if cleanup_failure is not None:
                    observation['cleanupFailureType'] = type(cleanup_failure).__name__
                attempts.append(observation)
            if primary is None and cleanup_failure is not None:
                raise cleanup_failure


def effect_count(workspace):
    path = workspace / 'approval-effects'
    if not path.exists():
        return 0
    data = path.read_bytes()
    require(data in (b'', b'effect\n'), 'Repeated or malformed native effect')
    return int(bool(data))


def experiment(args, report):
    probe.validate_inputs(args.codex, args.schema_dir, args.default_schema_dir, args.catalog, report)
    require(args.executable.is_absolute() and args.executable.is_file() and
            os.access(args.executable, os.X_OK), 'Select the compiled host experiment')
    report['hostExecutableSHA256'] = hashlib.sha256(args.executable.read_bytes()).hexdigest()
    report['runnerSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report['providerRunnerSHA256'] = hashlib.sha256(Path(lifecycle.__file__).read_bytes()).hexdigest()
    guardian = Path(__file__).with_name('codex-host-guardian.py').resolve()
    report['guardianSHA256'] = hashlib.sha256(guardian.read_bytes()).hexdigest()
    repo = Path(__file__).resolve().parent.parent
    source = hashlib.sha256()
    for path in [repo / 'Package.swift'] + sorted((repo / 'apps/MunieHost').rglob('*.swift')):
        source.update(str(path.relative_to(repo)).encode() + b'\0' + path.read_bytes() + b'\0')
    report['hostSourceSHA256'] = source.hexdigest()
    report['scope'] = ('Real Swift submission coordinator and native Codex processes; synthetic '
                       'loopback model, seeded trusted identity; no credentials/external network/mobile.')
    report['phase'] = 'native-host'
    report['attempts'], report['cases'] = [], []
    for case in CASES:
        with tempfile.TemporaryDirectory(prefix='munie-native-host-') as temporary:
            base = Path(temporary).resolve()
            fixture, protected = base / 'fixture', base / 'protected'
            fixture.mkdir(mode=0o700)
            protected.mkdir(mode=0o700)
            sentinel = protected / 'sentinel'
            sentinel.write_text('pristine')
            for name in ('workspace', 'codex-data', 'tmp'):
                (fixture / name).mkdir(mode=0o700)
            workspace, home = fixture / 'workspace', fixture / 'codex-data'
            (fixture / 'launch.json').write_text(json.dumps({
                'python': sys.executable, 'guardian': str(guardian)}))
            provider = HostFixtureServer(workspace)
            try:
                provider.select(case)
                port = provider.server_port
                (home / 'config.toml').write_text(
                    f'model = "{lifecycle.MODEL}"\nmodel_provider = "munie_fixture"\n'
                    'cli_auth_credentials_store = "file"\n[shell_environment_policy]\ninherit = "none"\n'
                    '[model_providers.munie_fixture]\nname = "Munie deterministic fixture"\n'
                    f'base_url = "http://127.0.0.1:{port}{provider.path.removesuffix("/responses")}"\n'
                    'wire_api = "responses"\nrequires_openai_auth = false\n'
                    'request_max_retries = 0\nstream_max_retries = 0\n'
                    '[analytics]\nenabled = false\n[feedback]\nenabled = false\n')
                profile = probe.sandbox_profile(fixture, protected, Path.home()) + (
                    f'\n(allow network-outbound (remote ip "localhost:{port}"))')
                profile_path = fixture / 'sandbox.sb'
                profile_path.write_text(profile)
                environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()),
                               'CODEX_HOME': str(home), 'TMPDIR': str(fixture / 'tmp'),
                               'LANG': 'en_US.UTF-8'}
                sandbox = ['/usr/bin/sandbox-exec', '-f', str(profile_path)]
                guard = subprocess.run(sandbox + [sys.executable, '-I', '-c', probe.GUARD_CODE,
                    str(sentinel), str(Path.home())], cwd=workspace, env=environment,
                    capture_output=True, timeout=10, check=True)
                guards = probe.strict_json(guard.stdout)
                require(sentinel.read_text() == 'pristine', 'Protected bytes changed')
                version = subprocess.run(sandbox + [str(args.codex), '--version'], cwd=workspace,
                    env=environment, capture_output=True, timeout=5, check=True)
                require(version.stdout.decode().strip() == probe.VERSION, 'Native version changed')
                record = {'scenario': case, 'sandboxGuards': guards}
                report['cases'].append(record)
                record['initial'] = execute_host(args.executable, args.codex, fixture, case,
                    'start', provider, report['attempts'])
                if case in ('pending-crash', 'mapped-crash', 'mapping-loss'):
                    record['recovery'] = execute_host(args.executable, args.codex, fixture, case,
                        'recover', provider, report['attempts'])
                expected_requests = 0 if case == 'startup-loss' else (
                    2 if case == 'approval-accept' else 1)
                provider.check(expected_requests)
                record['providerRequests'] = provider.total
                record['effectCount'] = effect_count(workspace)
                require(record['effectCount'] == int(case == 'approval-accept'),
                        'Native effect count mismatch')
                require(not (workspace / 'after-interrupt').exists(),
                        'Cancelled tool continued to its final effect')
                if case == 'running-interrupt':
                    require(record['initial']['result'].get('toolProcessesGoneBeforeClose') is True,
                            'Tool exit was not verified before native transport cleanup')
                    for name in ('running-shell.pid', 'running-child.pid'):
                        pid = int((workspace / name).read_text().strip())
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            continue
                        raise ValueError('Interrupted tool process remains')
                    record['toolProcessesGone'] = True
            finally:
                provider.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True, type=Path)
    parser.add_argument('--codex', required=True, type=Path)
    parser.add_argument('--schema-dir', required=True, type=Path)
    parser.add_argument('--default-schema-dir', required=True, type=Path)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parent.parent /
                        'references/codex-capabilities.json')
    parser.add_argument('--output', type=Path, default=Path('build/codex-host-probe.json'))
    args = parser.parse_args()
    report = {'reportVersion': 1, 'status': 'failed', 'phase': 'starting',
              'capturedAtUTC': datetime.now(timezone.utc).isoformat()}
    probe.write_report(args.output, report)
    status = 1
    try:
        report['phase'] = 'native-host'
        experiment(args, report)
        report['status'], report['phase'], status = 'passed', 'complete', 0
    except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
        report['failureType'] = type(error).__name__
        if isinstance(error, probe.ProbeError):
            report['failure'] = str(error)
        print('Codex host experiment failed: ' + type(error).__name__, file=sys.stderr)
    finally:
        probe.write_report(args.output, report)
    if status == 0:
        print('PASS Swift host + native Codex: 8 cases; synthetic provider, no real model.')
    return status


if __name__ == '__main__':
    sys.exit(main())
