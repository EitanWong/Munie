#!/usr/bin/env python3
"""Opt-in one real disposable task through the adopted client/bridge, then process recovery."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('device_policy', ROOT / 'scripts/test-available-ios.py')
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)
MARKER = 'MUNIE_REMODEX_REAL_OK'
PROMPT = 'Reply exactly ' + MARKER + '. Do not use tools.'
CONTINUATION_MARKER = 'MUNIE_REMODEX_CONTINUED_OK'
CONTROL_MARKERS = {'munie-approved.txt': b'MUNIE_REMODEX_APPROVED\n',
                   'munie-running.txt': b'MUNIE_REMODEX_RUNNING\n'}
CONTROL_LATE_MARKER = 'munie-after-wait.txt'
SELECTOR = 'MunieRemodexDeviceAcceptanceTests/testExplicitDisposableTaskAndSeparateProcessRecovery'
MAX_ROLLOUT_BYTES = 16 * 1024 * 1024
MAX_LINE_BYTES = 1024 * 1024
MAX_ROLLOUT_FILES = 16


def canonical_uuid(value):
    return str(uuid.UUID(value))


def save_report(path, report):
    """Atomically retain the latest stage, including an interrupted/failed invocation."""
    temporary = path.with_suffix('.json.tmp')
    try:
        with temporary.open('x', encoding='utf-8') as output:
            json.dump(report, output, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def disposable_scope(work, project, account):
    """Only the runner-created private canonical temporary directory is a grant."""
    if (work != work.resolve(strict=True) or work.parent != Path(tempfile.gettempdir()).resolve()
            or not work.name.startswith('munie-remodex-account-')
            or project != work / 'project' or account != work / 'account'):
        raise ValueError('Disposable directory scope did not match this invocation.')
    for path in (work, project):
        info = path.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) & 0o077):
            raise ValueError('Disposable directory is not private and owner-controlled.')


def rollout_evidence(account, project, run_id):
    """Project only fixed marker flags and native metadata; never copy rollout text/auth."""
    result = {'schemaVersion': 1, 'runID': canonical_uuid(run_id),
              'scope': 'Fresh invocation account; exact disposable project cwd only.',
              'rollouts': [], 'rejectedRollouts': 0, 'status': 'absent'}
    sessions = account / 'sessions'
    if not sessions.exists() and not sessions.is_symlink():
        return result
    if account.is_symlink() or account.resolve() != account or sessions.is_symlink():
        raise ValueError('Rollout directory scope is unsafe.')
    files = []
    for directory, directories, names in os.walk(sessions, followlinks=False):
        directories[:] = sorted(name for name in directories
                                if not (Path(directory) / name).is_symlink())
        files.extend(Path(directory) / name for name in sorted(names) if name.endswith('.jsonl'))
        if len(files) > MAX_ROLLOUT_FILES:
            raise ValueError('Invocation rollout file limit exceeded.')
    total_bytes = 0
    for path in files:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(descriptor)
            total_bytes += info.st_size
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or total_bytes > MAX_ROLLOUT_BYTES):
                raise ValueError('Invocation rollout is not a bounded owned regular file.')
            with os.fdopen(descriptor, 'rb', closefd=False) as source:
                first = source.readline(MAX_LINE_BYTES + 1)
                try:
                    meta = json.loads(first)
                    payload = meta['payload']
                    thread_id = canonical_uuid(payload['id'])
                    matching = (len(first) <= MAX_LINE_BYTES and meta['type'] == 'session_meta'
                                and payload.get('cwd') == str(project))
                except (ValueError, KeyError, TypeError, AttributeError):
                    matching = False
                if not matching:
                    result['rejectedRollouts'] += 1
                    continue
                item = {'threadID': thread_id, 'readStatus': 'parsed', 'recordsRead': 1,
                        'userPromptObserved': False, 'assistantMarkerObserved': False,
                        'continuationMarkerObserved': False, 'turns': [],
                        'terminalStatus': 'not-observed'}
                turns = {}
                current_turn = None
                bytes_read = len(first)
                while True:
                    line = source.readline(MAX_LINE_BYTES + 1)
                    if not line:
                        break
                    bytes_read += len(line)
                    if len(line) > MAX_LINE_BYTES or bytes_read > MAX_ROLLOUT_BYTES:
                        item['readStatus'] = 'exceeded-limit'
                        break
                    try:
                        value = json.loads(line)
                        body = value.get('payload', {})
                        if not isinstance(body, dict):
                            continue
                    except (ValueError, AttributeError):
                        item['readStatus'] = 'invalid-json'
                        break
                    item['recordsRead'] += 1
                    kind = body.get('type')
                    if value.get('type') == 'event_msg':
                        try:
                            event_turn = canonical_uuid(body.get('turn_id', body.get('turnId')))
                        except (ValueError, TypeError, AttributeError):
                            event_turn = None
                        if kind == 'task_started':
                            current_turn = event_turn
                        event_turn = event_turn or current_turn
                        if kind == 'task_started':
                            item['terminalStatus'] = 'running'
                        elif kind in ('task_complete', 'task_failed', 'turn_aborted'):
                            item['terminalStatus'] = {'task_complete': 'completed',
                                'task_failed': 'failed', 'turn_aborted': 'cancelled'}[kind]
                        if event_turn and kind in ('task_started', 'task_complete', 'task_failed', 'turn_aborted'):
                            turns[event_turn] = item['terminalStatus']
                        if kind == 'user_message' and body.get('message') == PROMPT:
                            item['userPromptObserved'] = True
                        if kind in ('agent_message', 'task_complete'):
                            text = body.get('message', body.get('last_agent_message'))
                            item['assistantMarkerObserved'] |= isinstance(text, str) and text.strip() == MARKER
                            item['continuationMarkerObserved'] |= isinstance(text, str) and text.strip() == CONTINUATION_MARKER
                    if value.get('type') == 'response_item' and kind == 'message':
                        content = body.get('content', [])
                        if isinstance(content, list):
                            texts = [part.get('text') for part in content if isinstance(part, dict)]
                            if body.get('role') == 'user':
                                item['userPromptObserved'] |= PROMPT in texts
                            elif body.get('role') == 'assistant':
                                item['assistantMarkerObserved'] |= any(
                                    isinstance(text, str) and text.strip() == MARKER for text in texts)
                                item['continuationMarkerObserved'] |= any(
                                    isinstance(text, str) and text.strip() == CONTINUATION_MARKER for text in texts)
                item['turns'] = [{'turnID': key, 'terminalStatus': status} for key, status in turns.items()]
                result['rollouts'].append(item)
        finally:
            os.close(descriptor)
    result['status'] = 'retained' if result['rollouts'] else 'no-matching-rollouts'
    return result


def device_result(log, mode, run_id):
    """Ignore diagnostic bodies; accept only a typed same-run fixed-result record."""
    found = []
    for line in log.read_text(errors='replace').splitlines():
        if mode == 'cleanup':
            if line.strip() == 'MUNIE_REMODEX_CLEANUP ' + run_id:
                found.append({'runID': run_id, 'fixtureRemoved': True})
            continue
        prefix = 'MUNIE_REMODEX_ACCEPTANCE '
        if prefix not in line:
            continue
        try:
            value = json.loads(line.split(prefix, 1)[1])
            result = {'mode': mode, 'runID': canonical_uuid(value['runID']),
                      'threadID': canonical_uuid(value['threadID']), 'pid': value['pid'],
                      'previousPID': value['previousPID'], 'encrypted': value['encrypted'],
                      'matchingUserMessages': value['matchingUserMessages'],
                      'markerObserved': value['markerObserved']}
            if (value['mode'] != mode or result['runID'] != run_id
                    or type(result['pid']) is not int or result['pid'] <= 0
                    or type(result['previousPID']) is not int
                    or result['encrypted'] is not True or result['markerObserved'] is not True
                    or type(result['matchingUserMessages']) is not int
                    or result['matchingUserMessages'] != 1):
                raise ValueError()
        except (ValueError, KeyError, TypeError, AttributeError):
            raise RuntimeError(mode + ' returned an invalid acceptance record.') from None
        if mode == 'controls':
            try:
                for field in ('approvalCommandMatched', 'approvalCwdMatched', 'runningMarkerObserved',
                              'interruptionAcknowledged', 'cancelledTerminalObserved', 'continuationMarkerObserved'):
                    if value[field] is not True:
                        raise ValueError()
                    result[field] = True
                if type(value['approvalCount']) is not int or value['approvalCount'] != 2:
                    raise ValueError()
                result['approvalCount'] = 2
                for field in ('approvedTurnID', 'cancelledTurnID', 'continuedTurnID'):
                    result[field] = canonical_uuid(value[field])
                if len({result[field] for field in ('approvedTurnID', 'cancelledTurnID', 'continuedTurnID')}) != 3:
                    raise ValueError()
            except (ValueError, KeyError, TypeError, AttributeError):
                raise RuntimeError('controls returned an invalid control record.') from None
        found.append(result)
    if len(found) != 1:
        raise RuntimeError(mode + ' did not return exactly one matching acceptance record.')
    return found[0]


def control_marker_evidence(project):
    result = {}
    for name, expected in CONTROL_MARKERS.items():
        descriptor = os.open(project / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                    or info.st_size != len(expected) or os.read(descriptor, len(expected) + 1) != expected):
                raise RuntimeError('Control marker did not match the fixed invocation effect.')
            result[name] = True
        finally:
            os.close(descriptor)
    late = project / CONTROL_LATE_MARKER
    result['lateMarkerAbsent'] = not late.exists() and not late.is_symlink()
    if not result['lateMarkerAbsent']:
        raise RuntimeError('Cancelled command produced the forbidden late marker.')
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-real-model', action='store_true')
    parser.add_argument('--codex', type=Path)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--relay')
    parser.add_argument('--relay-port', type=int, default=9275)
    parser.add_argument('--with-controls', action='store_true',
                        help='Opt in to fixed marker approvals, a sleep-30 cancellation and same-thread continuation.')
    parser.add_argument('--cleanup-run-id', type=canonical_uuid,
                        help='Delete only this prior UUID fixture on the device; no model or host startup.')
    args = parser.parse_args(argv)
    if args.cleanup_run_id and args.with_controls:
        parser.error('--with-controls cannot be used for cleanup-only.')
    if not args.cleanup_run_id and not (args.allow_real_model and args.codex and args.relay):
        parser.error('--allow-real-model, --codex and --relay are required for actual acceptance.')
    products = args.products.resolve(strict=True)
    if not products.is_relative_to((ROOT / 'build').resolve()):
        parser.error('Use generated test products inside this checkout build directory.')
    os.umask(0o077)
    evidence = Path(tempfile.mkdtemp(prefix='remodex-real-', dir=ROOT / 'build')).resolve()
    work = None if args.cleanup_run_id else Path(tempfile.mkdtemp(prefix='munie-remodex-account-')).resolve()
    project, state, account = ((work / 'project', work / 'state', work / 'account')
                               if work else (None, None, None))
    if work:
        project.mkdir(mode=0o700)
        state.mkdir(mode=0o700)
        disposable_scope(work, project, account)
    run_id = args.cleanup_run_id or str(uuid.uuid4())
    report = {'schemaVersion': 2, 'status': 'running', 'stage': 'starting', 'runID': run_id,
              'destination': args.destination, 'relay': args.relay, 'commands': [],
              'scope': 'One explicit disposable text task and read-only recovery in separate app processes.',
              'evidenceDirectory': str(evidence), 'workDirectory': str(work) if work else None,
              'mode': 'cleanup-only' if args.cleanup_run_id else 'acceptance', 'stages': []}
    report['withControls'] = args.with_controls
    if args.with_controls:
        report['scope'] = ('Disposable submit, two exact one-time command approvals, a sleep-30 '
                           'cancellation, same-thread continuation and separate-process recovery.')
    launcher = None
    launcher_log = None
    submit_attempted = False
    acceptance_finished = False
    clones = []
    output = evidence / 'report.json'

    def save():
        save_report(output, report)

    def stage(name):
        report['stage'] = name
        report['stages'].append({'name': name, 'status': 'running'})
        save()

    def finish_stage(status='passed'):
        report['stages'][-1]['status'] = status
        save()

    def cleanup_failure(name, error):
        report['cleanupFailures'] = report.get('cleanupFailures', []) + [
            {'stage': name, 'failure': str(error)}]
        report['status'] = 'failed'
        if report['stages'] and report['stages'][-1]['status'] == 'running':
            finish_stage('failed')
        save()

    def run(command, name, timeout=300):
        record = POLICY.CommandRunner(ROOT).run(command, timeout=timeout, log=evidence / (name + '.log'),
                                               environment=POLICY.safe_environment(dict(os.environ)))
        report['commands'].append(record)
        save()
        if record['exitStatus'] != 0 or record.get('failure') or record.get('cleanupFailure'):
            raise RuntimeError(name + ' failed; original log retained.')
        return record

    def device_phase(mode, pairing=None):
        nonlocal submit_attempted
        stage('device-' + mode)
        clone, configuration = POLICY.prepare_test_run(products, product='remodex', safe_only=False)
        clones.append(clone)
        value = plistlib.loads(clone.read_bytes())
        value.pop('MunieRemodexUITests', None)
        unit = value['MunieRemodexTests']
        unit['OnlyTestIdentifiers'] = [SELECTOR]
        unit['SkipTestIdentifiers'] = []
        variables = {'REMODEX_ACCEPTANCE_RUN_ID': run_id, 'REMODEX_ACCEPTANCE_MODE': mode,
                     'REMODEX_ACCEPTANCE_AUTHORIZED': 'disposable-project-only'}
        if mode != 'cleanup':
            variables.update({'REMODEX_ACCEPTANCE_PAIRING': json.dumps(pairing, separators=(',', ':')),
                              'REMODEX_ACCEPTANCE_PROJECT': str(project)})
            if args.with_controls:
                variables['REMODEX_ACCEPTANCE_WITH_CONTROLS'] = 'fixed-marker-controls'
        unit.setdefault('EnvironmentVariables', {}).update(variables)
        clone.write_bytes(plistlib.dumps(value))
        configuration['cloneSHA256'] = hashlib.sha256(clone.read_bytes()).hexdigest()
        report[mode + 'Configuration'] = configuration
        save()
        if mode == 'submit':
            submit_attempted = True
        allowance = '480' if mode == 'controls' else '150'
        maximum = '540' if mode == 'controls' else '180'
        run(['xcodebuild', '-xctestrun', str(clone), '-destination', args.destination,
             '-parallel-testing-enabled', 'NO', '-destination-timeout', '45',
             '-resultBundlePath', str(evidence / (mode + '.xcresult')),
             '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', allowance,
             '-maximum-test-execution-time-allowance', maximum, 'test-without-building'], mode,
            600 if mode == 'controls' else 300)
        result = device_result(evidence / (mode + '.log'), mode, run_id)
        if mode in ('controls', 'recover'):
            first = report['submitResult']
            if (result['threadID'] != first['threadID'] or result['pid'] == first['pid']
                    or result['previousPID'] != first['pid']):
                raise RuntimeError('Recovery did not match the original thread in a separate app process.')
        report[mode + 'Result'] = result
        finish_stage()

    save()
    try:
        if args.cleanup_run_id:
            device_phase('cleanup')
        else:
            stage('prepare-account')
            # Reuse the already reviewed descriptor-based native credential preparation verbatim.
            # The extracted helper has no transport/model startup or credential output.
            original = (ROOT / 'apps/MunieHost/Transport/NativeCodexRuntime.swift').read_text()
            implementation = original[original.index('private enum NativeCredentialStorage'):]
            helper = evidence / 'prepare-account.swift'
            helper.write_text('import Darwin\nimport Foundation\n'
                              'enum NativeRuntimeError: Error { case insecureCredentials, loginRequired }\n'
                              + implementation + '\n'
                              'do { try NativeCredentialStorage.prepare(home: URL(fileURLWithPath: CommandLine.arguments[1]), '
                              'source: URL(fileURLWithPath: CommandLine.arguments[2])); '
                              'print("Prepared private disposable account; no model called.") } '
                              'catch { fputs("Private account preparation refused.\\n", stderr); exit(1) }\n')
            report['credentialPreparationSourceSHA256'] = hashlib.sha256(original.encode()).hexdigest()
            run(['xcrun', 'swift', str(helper), str(account), str(Path.home() / '.codex/auth.json')], 'prepare-account', 90)
            if (account / 'sessions').exists():
                raise RuntimeError('Fresh disposable account unexpectedly contains native history.')
            finish_stage()
            stage('launcher-start')
            launcher_log = (evidence / 'launcher.log').open('xb')
            launcher = subprocess.Popen([str(ROOT / 'scripts/run-remodex-local.sh'), '--codex', str(args.codex),
                '--project', str(project), '--state-dir', str(state), '--codex-home', str(account),
                '--advertise-relay', args.relay, '--relay-port', str(args.relay_port)],
                cwd=ROOT, env=POLICY.safe_environment(dict(os.environ)), stdin=subprocess.DEVNULL,
                stdout=launcher_log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if launcher.poll() is not None:
                    raise RuntimeError('Launcher exited before readiness.')
                try:
                    status = json.loads((state / 'run.json').read_text())
                    pairing = json.loads((state / 'device/pairing-session.json').read_text())['pairingPayload']
                    if status['status'] == 'running':
                        break
                except (OSError, ValueError, KeyError):
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError('Launcher readiness exceeded 30 seconds.')
            report['nativeSHA256'] = status['codexSHA256']
            finish_stage()
            for mode in (('submit', 'controls', 'recover') if args.with_controls else ('submit', 'recover')):
                device_phase(mode, pairing)
                if mode == 'controls':
                    stage('observe-no-late-marker')
                    # The approved command sleeps 30s. Observe beyond that window after confirmed cancellation.
                    report['lateMarkerObservationSeconds'] = 31
                    save()
                    time.sleep(31)
                    report['controlMarkers'] = control_marker_evidence(project)
                    finish_stage()
        acceptance_finished = True
    except Exception as error:
        report['status'] = 'failed'
        report['failureStage'] = report['stage']
        report['failure'] = str(error)
        finish_stage('failed')
    finally:
        if submit_attempted:
            try:
                device_phase('cleanup')
            except Exception as error:
                cleanup_failure('device-cleanup', error)
        if launcher is not None:
            stage('launcher-stop')
            try:
                launcher.send_signal(signal.SIGTERM)
                launcher.wait(timeout=20)
                report['launcherExitStatus'] = launcher.returncode
                finish_stage()
            except (OSError, subprocess.TimeoutExpired) as error:
                cleanup_failure('launcher-stop', error)
        if launcher_log is not None:
            launcher_log.close()
        if state and (state / 'run.json').is_file():
            try:
                runtime = json.loads((state / 'run.json').read_text())
                report['runtimeCleanup'] = runtime
                if runtime['status'] != 'stopped' or not all(p.get('processGroupGone') for p in runtime['processes']):
                    raise RuntimeError('Owned runtime cleanup not verified.')
            except (OSError, ValueError, KeyError, RuntimeError) as error:
                cleanup_failure('runtime-cleanup', error)
        for clone in clones:
            try:
                clone.unlink(missing_ok=True)
            except OSError as error:
                cleanup_failure('configuration-cleanup', error)
        if account:
            stage('retain-sanitized-rollout')
            try:
                disposable_scope(work, project, account)
                report['nativeEvidence'] = rollout_evidence(account, project, run_id)
                # The metadata is saved durably before removing the copied native account.
                save_report(evidence / 'native-metadata.json', report['nativeEvidence'])
                report['nativeEvidenceVerified'] = any(
                    item['threadID'] == report.get('submitResult', {}).get('threadID')
                    and item['readStatus'] == 'parsed' and item['userPromptObserved']
                    and item['assistantMarkerObserved'] and item['terminalStatus'] == 'completed'
                    for item in report['nativeEvidence']['rollouts'])
                if args.with_controls and report.get('controlsResult'):
                    controls = report['controlsResult']
                    matched = next((item for item in report['nativeEvidence']['rollouts']
                                    if item['threadID'] == controls['threadID']), None)
                    observed = {turn['turnID']: turn['terminalStatus'] for turn in matched['turns']} if matched else {}
                    report['nativeControlsVerified'] = bool(matched and matched['continuationMarkerObserved']
                        and observed.get(controls['approvedTurnID']) == 'completed'
                        and observed.get(controls['cancelledTurnID']) == 'cancelled'
                        and observed.get(controls['continuedTurnID']) == 'completed')
                    if acceptance_finished and not report['nativeControlsVerified']:
                        raise RuntimeError('Matching native approval/cancellation/continuation terminals were not observed.')
                if acceptance_finished and not report['nativeEvidenceVerified']:
                    raise RuntimeError('Matching native marker and terminal metadata were not observed.')
                finish_stage()
            except (OSError, ValueError, RuntimeError) as error:
                cleanup_failure('retain-sanitized-rollout', error)
            stage('temporary-account-cleanup')
            try:
                disposable_scope(work, project, account)
                if account.is_symlink():
                    account.unlink()
                elif account.is_dir():
                    shutil.rmtree(account)
                report['temporaryAccountRemoved'] = not account.exists()
                finish_stage()
            except (OSError, ValueError) as error:
                cleanup_failure('temporary-account-cleanup', error)
        report['stage'] = 'complete'
        if acceptance_finished and report['status'] != 'failed':
            report['status'] = 'passed'
        save()
    print(json.dumps({'status': report['status'], 'report': str(output)}))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
