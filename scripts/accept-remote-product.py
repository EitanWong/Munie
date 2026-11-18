#!/usr/bin/env python3
"""Opt-in actual-account acceptance in a disposable project; never run from default CI."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import shlex
import sqlite3
import subprocess
import time
import urllib.request
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('redirect rejected by local acceptance')


def exact_marker_command(observed, expected):
    if observed == expected:
        return True
    # Codex renders the actual shell launcher. Parse that fixed wrapper; do not normalize its body.
    try:
        values = shlex.split(observed)
    except ValueError:
        return False
    return len(values) == 3 and values[0] in ('/bin/zsh', '/bin/bash', '/bin/sh') and values[1] in ('-c', '-lc') and values[2] == expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--service', type=Path, required=True)
    parser.add_argument('--guardian', type=Path, required=True)
    parser.add_argument('--codex', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--allow-real-model', action='store_true')
    args = parser.parse_args()
    if not args.allow_real_model:
        parser.error('explicit --allow-real-model and owner authorization required')
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    root = args.output.parent / ('remote-acceptance-' + uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    project = root / 'project'
    project.mkdir(mode=0o700)
    # Only this synthetic project is registered; no repository or personal directory is a task cwd.
    host_id, project_id = str(uuid.uuid4()), str(uuid.uuid4())
    config = {'hostID': host_id, 'stateDirectory': (root / 'state').as_uri(),
              'codexHome': (root / 'codex').as_uri(), 'executable': args.codex.resolve().as_uri(),
              'guardian': args.guardian.resolve().as_uri(), 'projects': [
                  {'id': project_id, 'name': 'Disposable acceptance', 'directory': project.as_uri()}],
              'endpoint': 'https://munie-acceptance.invalid', 'port': 0}
    configuration = root / 'configuration.json'
    configuration.write_text(json.dumps(config))
    configuration.chmod(0o600)
    report = {'schema': 1, 'passed': False, 'realModel': True, 'network': 'Mac loopback HTTP only',
              'physicalDevice': False, 'cellular': False, 'remotePush': False,
              'sourceRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'binaryHashes': {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in [args.service, args.guardian, args.codex]}, 'checks': []}
    credential = None
    process = None
    stderr = (root / 'service.stderr').open('wb')
    try:
        process = subprocess.Popen([str(args.service.resolve()), '--configuration', str(configuration)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                   text=True, bufsize=1, start_new_session=True)
        def read_reply(timeout=30):
            ready, _, _ = select.select([process.stdout], [], [], timeout)
            if not ready:
                raise RuntimeError('bounded admin reply timeout')
            line = process.stdout.readline()
            if not line:
                raise RuntimeError('host closed administrative pipe')
            return json.loads(line)
        def admin(op, **kwargs):
            process.stdin.write(json.dumps({'op': op, **kwargs}) + '\n')
            process.stdin.flush()
            return read_reply()
        start = read_reply()
        assert start['event'] == 'ready', start
        port = start['port']
        def call(op, **kwargs):
            request = urllib.request.Request(f'http://127.0.0.1:{port}/v1',
                json.dumps({'protocolVersion': 1, 'op': op, **kwargs}).encode(),
                headers={'Content-Type': 'application/json', **(
                    {'Authorization': 'Bearer ' + credential} if credential else {})})
            # urllib proxy environment cannot redirect this local acceptance into an external server.
            with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=25) as response:
                value = json.load(response)
            if value.get('error'):
                report['lastDiagnostics'] = admin('diagnostics').get('diagnostics')
                raise RuntimeError('host denial: ' + value['error'])
            return value
        invitation = admin('invite')['invitation']
        pair_id, pair_secret = str(uuid.uuid4()), base64.b64encode(os.urandom(32)).decode()
        paired = call('pair', invitation=invitation['secret'], pairingID=pair_id,
                      pairingSecret=pair_secret, deviceName='Acceptance client')
        assert paired['pairingState'] == 'pending'
        candidate = admin('candidate')['candidate']
        assert candidate['id'].lower() == pair_id.lower()
        assert candidate['fingerprint'] == hashlib.sha256(pair_secret.encode()).hexdigest()[:16]
        assert admin('approvePairing', projectIDs=[project_id])['event'] == 'paired'
        credential = call('pairStatus', invitation=invitation['secret'], pairingID=pair_id,
                          pairingSecret=pair_secret)['credential']
        report['checks'].append({'name': 'explicit-pairing-project-grant', 'passed': True})
        status = call('status')['status']
        assert len(status['projects']) == 1 and status['projects'][0]['id'].lower() == project_id
        def task_state(task_id):
            return next(t for t in call('status', taskID=task_id)['status']['tasks']
                        if t['id'].lower() == task_id.lower())
        def wait(task_id, predicate, timeout=150):
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                task = task_state(task_id)
                if predicate(task):
                    return task
                if task['phase'] in ['failed', 'cancelled', 'reconciling']:
                    raise RuntimeError('unexpected task state: ' + task['phase'])
                time.sleep(0.35)
            raise RuntimeError('bounded actual-model task timeout')
        def submit(text, task_id=None):
            request_id = str(uuid.uuid4())
            request = {'requestID': request_id, 'projectID': project_id, 'text': text}
            if task_id:
                request['taskID'] = task_id
            deadline = time.monotonic() + 8
            while True:
                try:
                    result = call('submit', **request)['task']
                    return result['id'], request
                except RuntimeError as error:
                    if str(error) != 'host denial: busy' or time.monotonic() >= deadline:
                        raise
                    # A terminal may be visible while its native process is closing. Check the
                    # authoritative request first; never treat a timeout or uncertainty as denial.
                    snapshots = call('status')['status']['tasks']
                    existing = next((t for t in snapshots if t['requestID'].lower() == request_id), None)
                    if existing:
                        return existing['id'], request
                    time.sleep(0.25)
        text_id, text_request = submit('Reply exactly MUNIE_REAL_TEXT_OK. Do not use any tools.')
        text_result = wait(text_id, lambda t: t['phase'] == 'completed')
        assert any(m['role'] == 'assistant' and 'MUNIE_REAL_TEXT_OK' in m['text'] for m in text_result['messages'])
        retry = call('submit', **text_request)['task']
        assert retry['requestID'] == text_result['requestID'] and retry['phase'] == 'completed'
        report['checks'].append({'name': 'actual-text-terminal-exact-retry', 'passed': True,
                                 'phase': text_result['phase'], 'requestID': text_result['requestID']})
        # New HTTP connections plus no observer for a moment must not stop the host event owner.
        time.sleep(0.5)
        assert task_state(text_id)['phase'] == 'completed'
        continued_id, continued_request = submit('Reply exactly MUNIE_REAL_CONTINUED_OK. Do not use any tools.', text_id)
        assert continued_id == text_id
        continued = wait(text_id, lambda t: t['phase'] == 'completed')
        assert any(m['role'] == 'assistant' and 'MUNIE_REAL_CONTINUED_OK' in m['text'] for m in continued['messages'])
        connection = sqlite3.connect(root / 'state/ledger/submissions.sqlite3')
        native = connection.execute('SELECT thread,turn FROM requests ORDER BY rowid').fetchall()
        connection.close()
        assert len(native) == 2 and native[0][0] == native[1][0] and native[0][1] != native[1][1]
        report['checks'].append({'name': 'authoritative-reconnect-native-continuation', 'passed': True,
                                 'sameNativeThread': True, 'distinctNativeTurns': True})
        # A command can run only after this operator verifies the exact bounded marker operation.
        command = "printf 'MUNIE_APPROVED\\n' > approved.txt"
        approval_id, _ = submit('Use the shell tool to run exactly this command in the current project:\n```sh\n'
            + command + '\n```\nThe sandbox is read-only: explicitly request require_escalated with justification '
            'so the user receives a command approval. Do not modify anything before approval. '
            'Afterward reply MUNIE_APPROVAL_COMPLETE. No other commands or files.')
        pending = wait(approval_id, lambda t: t.get('approval') is not None)
        approval = pending['approval']
        approved_command = approval['command'].strip()
        report['observedMarkerApproval'] = {'command': approved_command, 'cwdMatchesProject': Path(approval['cwd']).resolve() == project}
        assert exact_marker_command(approved_command, command), 'model requested a different command; no approval issued'
        assert Path(approval['cwd']).resolve() == project
        assert not (project / 'approved.txt').exists()
        ack = call('approve', taskID=approval_id, requestID=pending['requestID'],
                   approvalID=approval['id'], accept=True)
        completed = wait(approval_id, lambda t: t['phase'] == 'completed')
        assert (project / 'approved.txt').read_text() == 'MUNIE_APPROVED\n'
        report['checks'].append({'name': 'informed-one-time-approval-real-effect', 'passed': True,
                                 'command': approved_command, 'phase': completed['phase']})
        cancel_command = "printf 'MUNIE_RUNNING\\n' > running.txt; sleep 30; printf 'MUNIE_AFTER_WAIT\\n' > after-wait.txt"
        cancel_id, _ = submit('Use the shell tool to run exactly this command in the current project:\n```sh\n'
            + cancel_command + '\n```\nRequest require_escalated so this read-only sandbox produces a command approval. '
            'No other commands or files. The user will test cancelling while the command waits.')
        pending = wait(cancel_id, lambda t: t.get('approval') is not None)
        approval = pending['approval']
        report['observedCancellationApproval'] = {'command': approval['command'], 'cwdMatchesProject': Path(approval['cwd']).resolve() == project}
        assert exact_marker_command(approval['command'].strip(), cancel_command), 'unexpected command; not approved'
        assert Path(approval['cwd']).resolve() == project
        call('approve', taskID=cancel_id, requestID=pending['requestID'], approvalID=approval['id'], accept=True)
        started = time.monotonic() + 15
        while not (project / 'running.txt').exists() and time.monotonic() < started:
            time.sleep(0.1)
        assert (project / 'running.txt').read_text() == 'MUNIE_RUNNING\n'
        ack = call('cancel', taskID=cancel_id, requestID=pending['requestID'])['task']
        assert ack['cancellationRequested'] or ack['phase'] == 'cancelled'
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            cancelled = task_state(cancel_id)
            if cancelled['phase'] == 'cancelled':
                break
            time.sleep(0.2)
        assert cancelled['phase'] == 'cancelled'
        assert not (project / 'after-wait.txt').exists()
        report['checks'].append({'name': 'running-command-cancellation-confirmed-terminal', 'passed': True,
                                 'ackPhase': ack['phase'], 'terminalPhase': cancelled['phase'], 'lateEffect': False})
        # First stop proves native group/pipe cleanup. Restart then queries the same private state.
        diagnostics = admin('diagnostics')['diagnostics']
        assert diagnostics.get('groupGone') and diagnostics.get('stdoutEOF') and diagnostics.get('stderrEOF')
        assert admin('quit')['event'] == 'closed'
        process.wait(timeout=10)
        assert process.returncode == 0
        report['checks'].append({'name': 'native-service-clean-close', 'passed': True, 'exit': process.returncode})
        process = subprocess.Popen([str(args.service.resolve()), '--configuration', str(configuration)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                   text=True, bufsize=1, start_new_session=True)
        restarted = read_reply()
        assert restarted['event'] == 'ready'
        port = restarted['port']
        assert task_state(text_id)['phase'] == 'completed'
        assert task_state(cancel_id)['phase'] == 'cancelled'
        connection = sqlite3.connect(root / 'state/ledger/submissions.sqlite3')
        assert connection.execute('SELECT count(*) FROM requests').fetchone()[0] == 4
        connection.close()
        assert admin('quit')['event'] == 'closed'
        process.wait(timeout=10)
        assert process.returncode == 0
        report['checks'].append({'name': 'service-restart-authoritative-history-no-resubmit', 'passed': True})
        report['passed'] = True
    except Exception as error:
        report['failure'] = str(error)
        if process is not None and process.poll() is None:
            try:
                report['lastDiagnostics'] = admin('diagnostics').get('diagnostics')
            except (OSError, RuntimeError):
                pass
        raise
    finally:
        if process is not None and process.poll() is None:
            try:
                process.stdin.write('{"op":"quit"}\n'); process.stdin.flush()
                process.wait(timeout=12)
            except (OSError, subprocess.TimeoutExpired):
                process.kill(); process.wait(timeout=5)
        stderr.close()
        # Credential material is never retained with test reports, including a failed run.
        try:
            if (root / 'codex').exists():
                shutil.rmtree(root / 'codex')
        except OSError:
            report['passed'] = False
            report['cleanupFailure'] = 'could not remove temporary native account directory'
        report['serviceExit'] = process.returncode if process else None
        report['evidenceDirectory'] = str(root)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        args.output.chmod(0o600)
        print(json.dumps({'passed': report['passed'], 'checks': len(report['checks']),
                          'report': str(args.output), 'failure': report.get('failure')}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
