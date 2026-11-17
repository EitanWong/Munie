#!/usr/bin/env python3
"""Kill the real Swift/SQLite host fixture at explicit barriers; no model or network."""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

SPEC = importlib.util.spec_from_file_location('report_helper', Path(__file__).with_name('probe-codex.py'))
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
# This runner imports its own helper module instance; these diagnostic caps do not change Codex probes.
helper.MAX_LINE_BYTES = 4096
helper.MAX_STREAM_BYTES = 16 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def decode(value):
    require(type(value) is dict and value.get('provider') == 'synthetic-local-effect' and
            value.get('integrity') == 'ok',
            'Unexpected synthetic fixture output')
    return value


class FixturePeer(helper.JsonLinePeer):
    def accept_notification(self, frame):
        raise ValueError('Unexpected trailing fixture frame')


def execute_fixture(executable, mode, root, kill, attempts=None):
    peer = FixturePeer([str(executable), mode, str(root)], root,
                       {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8'},
                       total_seconds=15)
    primary = None
    observation = {'mode': mode, 'forcedKill': kill}
    try:
        frame = decode(peer.read_frame(time.monotonic() + 10))
        require(frame.get('mode') == mode, 'Wrong fixture barrier')
        if kill:
            # Confirm the actual Swift store remains alive at the barrier, including optimized ARC.
            with (root / 'state/.owner').open('rb') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise ValueError('Fixture released its owner lock before the kill barrier')
            os.killpg(peer.process.pid, signal.SIGKILL)
        peer.close()
        require(peer.cleanup['exitStatus'] == (-signal.SIGKILL if kill else 0) and
                peer.cleanup['processGroupGone'] and peer.cleanup['streamsReachedEOF'] and
                peer.totals['stderr'] == 0, 'Fixture exit/stream/cleanup mismatch')
        result = {'mode': mode, 'exitStatus': peer.cleanup['exitStatus'], 'cleanup': peer.cleanup,
                  'streams': {name: {'bytes': peer.totals[name], 'sha256': digest.hexdigest()}
                              for name, digest in peer.digests.items()}}
        result['barrier' if kill else 'result'] = frame
        if kill:
            result['ownerLockHeldAtBarrier'] = True
        return result
    except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        primary = error
        raise
    finally:
        try:
            peer.close()
        except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as cleanup_error:
            observation['cleanupFailureType'] = type(cleanup_error).__name__
            if primary is None:
                raise
        finally:
            observation['cleanup'] = peer.cleanup
            observation['streams'] = {
                name: {'bytes': peer.totals[name], 'sha256': digest.hexdigest()}
                for name, digest in peer.digests.items()}
            if primary is not None:
                observation['failureType'] = type(primary).__name__
            if attempts is not None:
                attempts.append(observation)


def kill_at_barrier(executable, mode, root, attempts=None):
    return execute_fixture(executable, mode, root, kill=True, attempts=attempts)


def run_fixture(executable, mode, root, attempts=None):
    return execute_fixture(executable, mode, root, kill=False, attempts=attempts)


def effect_count(root):
    file = root / 'effects.txt'
    if not file.exists():
        return 0
    data = file.read_bytes()
    lines = data.splitlines(keepends=True)
    require(all(line == b'synthetic-upstream-effect\n' for line in lines), 'Corrupt fixture effects')
    return len(lines)


def experiment(executable, report):
    require(sys.platform == 'darwin', 'This Swift host fixture requires macOS')
    require(executable.is_absolute() and executable.is_file() and os.access(executable, os.X_OK),
            'Select an explicit compiled submission fixture executable')
    report['executableSHA256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
    report['runnerSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    root = Path(__file__).resolve().parent.parent
    report['sourceRevision'] = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    report['workingTreeDirty'] = bool(subprocess.check_output(
        ['git', 'status', '--porcelain'], cwd=root, text=True).strip())
    source_hash = hashlib.sha256()
    sources = [root / 'Package.swift'] + sorted((root / 'apps/MunieHost').rglob('*.swift'))
    for source in sources:
        source_hash.update(str(source.relative_to(root)).encode() + b'\0' + source.read_bytes() + b'\0')
    report['hostSourceSHA256'] = source_hash.hexdigest()
    report['scope'] = 'Actual Swift/SQLite process recovery with synthetic side effects; no Codex/model/network.'
    report['cases'] = []
    report['attempts'] = []
    for stage in ('uncommitted', 'accepted', 'claimed', 'effect', 'receipt', 'terminal'):
        with tempfile.TemporaryDirectory(prefix='munie-submission-fixture-') as temporary:
            root = Path(temporary).resolve()
            record = {'stage': stage}
            report['cases'].append(record)
            if stage == 'terminal':
                record['initial'] = run_fixture(executable, stage, root, report['attempts'])
            else:
                record['initial'] = kill_at_barrier(executable, stage, root, report['attempts'])
            initial = record['initial'].get('barrier', record['initial'].get('result'))
            expected_initial = {'uncommitted': 'uncommitted-dispatching', 'accepted': 'accepted',
                                'claimed': 'dispatching', 'effect': 'dispatching',
                                'receipt': 'running', 'terminal': 'completed'}[stage]
            require(initial.get('phase') == expected_initial and initial.get('hasUpstream') ==
                    ('true' if stage in ('receipt', 'terminal') else 'false'),
                    'Initial durable checkpoint/identity differs from expected stage')
            expected_count = 1 if stage in ('effect', 'receipt', 'terminal') else 0
            require(effect_count(root) == expected_count, 'Wrong side effect count before retry')
            expected_phase = 'completed' if stage in ('uncommitted', 'accepted', 'terminal') else 'reconciling'
            record['firstRetry'] = run_fixture(executable, 'retry', root, report['attempts'])
            require(record['firstRetry']['result'].get('phase') == expected_phase,
                    'Recovery phase differs from crash-window expectation')
            if stage in ('uncommitted', 'accepted'):
                expected_count = 1
            require(effect_count(root) == expected_count, 'Retry duplicated or lost a fixture effect')
            record['secondRetry'] = run_fixture(executable, 'retry', root, report['attempts'])
            require(record['secondRetry']['result'].get('phase') == expected_phase and
                    effect_count(root) == expected_count, 'Second retry changed an uncertain/terminal request')
            if stage in ('effect', 'receipt'):
                record['reconciliation'] = run_fixture(executable, 'reconcile', root, report['attempts'])
                require(record['reconciliation']['result'].get('phase') == 'completed' and
                        effect_count(root) == 1, 'Positive synthetic reconciliation caused another effect')
            record['effectCount'] = effect_count(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=Path('build/submission-ledger-probe.json'))
    args = parser.parse_args()
    report = {'reportVersion': 1, 'status': 'failed', 'phase': 'starting',
              'capturedAtUTC': datetime.now(timezone.utc).isoformat()}
    helper.write_report(args.output, report)
    status = 1
    try:
        report['phase'] = 'crash-windows'
        experiment(args.executable, report)
        report['status'], report['phase'], status = 'passed', 'complete', 0
    except (ValueError, OSError, subprocess.SubprocessError, UnicodeError) as error:
        report['failureType'] = type(error).__name__
        print('Submission ledger experiment failed: ' + type(error).__name__, file=sys.stderr)
    finally:
        helper.write_report(args.output, report)
    if status == 0:
        print('PASS Swift submission ledger: 6 crash/terminal windows; no duplicate synthetic effects.')
    return status


if __name__ == '__main__':
    sys.exit(main())
