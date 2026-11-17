#!/usr/bin/env python3
"""Explicit, synthetic macOS process acceptance for the product Codex guardian.

No model, account, network, installed service, or personal project is used. Signals are
restricted to recorded PID/start-time identities and their freshly created process groups.
"""

import argparse
import ctypes
import dataclasses
import errno
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

WAIT_SECONDS = 6.0
POLL_SECONDS = .02
MAXIMUM_FILE_BYTES = 16_384
ENVIRONMENT = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C'}


class ProbeError(Exception):
    """A structural diagnostic, never raw subprocess content."""


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid',
        'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in (
        'nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_seconds', ctypes.c_uint64),
                ('start_microseconds', ctypes.c_uint64)]


@dataclasses.dataclass(frozen=True)
class Identity:
    pid: int
    parent: int
    group: int
    start_seconds: int
    start_microseconds: int

    def same_process(self, other):
        return other is not None and (self.pid, self.start_seconds, self.start_microseconds) == (
            other.pid, other.start_seconds, other.start_microseconds)


class ProcessTable:
    def __init__(self):
        if sys.platform != 'darwin':
            raise ProbeError('macOS-required')
        self.library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                             ctypes.c_void_p, ctypes.c_int]
        self.library.proc_pidinfo.restype = ctypes.c_int
        self.library.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32,
                                              ctypes.c_void_p, ctypes.c_int]
        self.library.proc_listpids.restype = ctypes.c_int

    def identity(self, pid):
        if not isinstance(pid, int) or pid <= 1:
            raise ProbeError('invalid-process-id')
        info = BSDInfo()
        ctypes.set_errno(0)
        count = self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        if count == 0 and ctypes.get_errno() in (0, errno.ESRCH, errno.ENOENT):
            return None
        if count != ctypes.sizeof(info) or info.pid != pid or info.uid != os.geteuid():
            raise ProbeError('process-identity-query-failed')
        return Identity(info.pid, info.ppid, info.pgid, info.start_seconds, info.start_microseconds)

    def members(self, group):
        if group <= 1 or group == os.getpgrp():
            raise ProbeError('unowned-process-group')
        values = (ctypes.c_int * 8192)()
        ctypes.set_errno(0)
        count = self.library.proc_listpids(2, group, values, ctypes.sizeof(values))
        if count == 0 and ctypes.get_errno() not in (0, errno.ESRCH, errno.ENOENT):
            raise ProbeError('process-group-query-failed')
        if count < 0 or count >= ctypes.sizeof(values) or count % ctypes.sizeof(ctypes.c_int):
            raise ProbeError('process-group-query-failed')
        return [identity for pid in values[:count // ctypes.sizeof(ctypes.c_int)] if pid > 1
                if (identity := self.identity(pid)) is not None and identity.group == group]

    def signal_identity(self, identity, value):
        if not identity.same_process(self.identity(identity.pid)):
            raise ProbeError('process-identity-changed-before-signal')
        os.kill(identity.pid, value)

    def clean_group(self, group, anchors):
        members = self.members(group)
        if not members:
            return
        if not any(anchor.same_process(member) for anchor in anchors for member in members):
            raise ProbeError('no-live-owned-group-anchor')
        os.killpg(group, signal.SIGKILL)


def wait_until(predicate, code, seconds=WAIT_SECONDS):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(POLL_SECONDS)
    raise ProbeError(code)


def read_small(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAXIMUM_FILE_BYTES:
        raise ProbeError('invalid-fixture-record')
    with path.open('rb') as stream:
        result = stream.read(MAXIMUM_FILE_BYTES + 1)
    if len(result) > MAXIMUM_FILE_BYTES:
        raise ProbeError('oversized-fixture-record')
    return result


def read_record(path):
    return json.loads(read_small(path))


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(report, stream, sort_keys=True, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_guardian(path):
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        raise ProbeError('absolute-executable-guardian-required')
    return path.resolve()


def validate_output(path, guardian):
    if not path.is_absolute() or path == guardian or path.resolve() == guardian.resolve():
        raise ProbeError('separate-absolute-report-required')
    if path.exists() and not path.is_file():
        raise ProbeError('regular-report-required')
    return path


OWNER = r'''
import json,os,resource,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]); guardian=sys.argv[2]; script=sys.argv[3]
def record(name,value):
    temporary=root/(name+'.pending')
    temporary.write_text(json.dumps(value))
    os.replace(temporary,root/name)
def limits():
    resource.setrlimit(resource.RLIMIT_FSIZE,(1048576,1048576))
    resource.setrlimit(resource.RLIMIT_CPU,(10,10))
with open(root/'native.stdout','wb') as out, open(root/'native.stderr','wb') as err:
    child=subprocess.Popen([guardian,str(os.getpid()),'/bin/sh','-c',script,'fixture',str(root)],
        cwd=root,env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'C'},
        stdin=subprocess.DEVNULL,stdout=out,stderr=err,start_new_session=True,preexec_fn=limits)
    record('launch.json',{'ownerPID':os.getpid(),'guardianPID':child.pid})
    result=child.wait(timeout=10)
record('result.json',{'exitStatus':result})
'''

SCRIPTS = {
    'normal-exit': 'printf "%s\\n" "$$" > "$1/leader.pid"; IFS= read -r release < "$1/release.fifo"; exit 23',
    'owner-death': 'trap "" TERM; /bin/sh -c \'trap "" TERM; exec /bin/sleep 60\' & child=$!; '
                   'printf "%s\\n" "$$" > "$1/leader.pid"; printf "%s\\n" "$child" > "$1/child.pid"; wait "$child"',
    'leader-exit-with-descendant': '/bin/sleep 60 & child=$!; printf "%s\\n" "$$" > "$1/leader.pid"; '
                   'printf "%s\\n" "$child" > "$1/child.pid"; IFS= read -r release < "$1/release.fifo"; exit 17',
}


class Runner:
    def __init__(self, guardian, root, table=None):
        self.guardian = guardian
        self.root = root
        self.table = table or ProcessTable()
        self.processes = []
        self.groups = {}

    def register(self, process):
        identity = wait_until(lambda: self.table.identity(process.pid), 'spawn-identity-missing')
        if identity.group != identity.pid:
            raise ProbeError('fixture-not-group-leader')
        self.processes.append((process, identity))
        self.groups.setdefault(identity.group, []).append(identity)
        return identity

    def sentinel(self):
        process = subprocess.Popen(['/bin/sleep', '60'], env=ENVIRONMENT,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        return process, self.register(process)

    def assert_sentinel(self, sentinel):
        process, identity = sentinel
        if process.poll() is not None or not identity.same_process(self.table.identity(identity.pid)):
            raise ProbeError('unrelated-sentinel-was-stopped')

    def release(self, root):
        def opened():
            try:
                return os.open(root / 'release.fifo', os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno == errno.ENXIO:
                    return None
                raise
        descriptor = wait_until(opened, 'release-fifo-not-ready')
        try:
            os.write(descriptor, b'release\n')
        finally:
            os.close(descriptor)

    def scenario(self, name, sentinel):
        root = self.root / name
        root.mkdir(mode=0o700)
        os.mkfifo(root / 'release.fifo', 0o600)
        owner_log = open(root / 'owner.stderr', 'wb')
        try:
            owner = subprocess.Popen([sys.executable, '-I', '-c', OWNER, str(root), str(self.guardian), SCRIPTS[name]],
                                     cwd=root, env=ENVIRONMENT, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=owner_log, start_new_session=True)
        finally:
            owner_log.close()
        owner_id = self.register(owner)
        wait_until(lambda: (root / 'launch.json').exists(), 'guardian-launch-record-missing')
        launch = read_record(root / 'launch.json')
        guardian_id = wait_until(lambda: self.table.identity(launch['guardianPID']), 'guardian-identity-missing')
        if guardian_id.parent != owner.pid or guardian_id.group != guardian_id.pid:
            raise ProbeError('guardian-parent-group-mismatch')
        self.groups.setdefault(guardian_id.group, []).append(guardian_id)
        wait_until(lambda: (root / 'leader.pid').exists() and read_small(root / 'leader.pid').strip(), 'native-leader-record-missing')
        leader_pid = int(read_small(root / 'leader.pid'))
        leader_id = wait_until(lambda: self.table.identity(leader_pid), 'native-leader-identity-missing')
        if leader_id.group != guardian_id.group or leader_id.parent != guardian_id.pid:
            raise ProbeError('native-leader-parent-group-mismatch')
        self.groups[guardian_id.group].append(leader_id)
        child_id = None
        if name != 'normal-exit':
            wait_until(lambda: (root / 'child.pid').exists() and read_small(root / 'child.pid').strip(), 'native-child-record-missing')
            child_pid = int(read_small(root / 'child.pid'))
            child_id = wait_until(lambda: self.table.identity(child_pid), 'native-child-identity-missing')
            if child_id.group != guardian_id.group or child_id.parent != leader_pid:
                raise ProbeError('native-child-parent-group-mismatch')
            self.groups[guardian_id.group].append(child_id)
        started = time.monotonic()
        if name == 'owner-death':
            self.table.signal_identity(owner_id, signal.SIGKILL)
            owner.wait(timeout=WAIT_SECONDS)
            if owner.returncode != -signal.SIGKILL:
                raise ProbeError('owner-kill-not-observed')
            expected = None
        else:
            self.release(root)
            owner.wait(timeout=WAIT_SECONDS)
            if owner.returncode != 0:
                raise ProbeError('fixture-owner-failed')
            expected = 23 if name == 'normal-exit' else 17
            if read_record(root / 'result.json')['exitStatus'] != expected:
                raise ProbeError('native-exit-code-not-preserved')
        wait_until(lambda: not self.table.members(guardian_id.group), 'guardian-group-remained')
        wait_until(lambda: not guardian_id.same_process(self.table.identity(guardian_id.pid)), 'guardian-remained')
        if leader_id.same_process(self.table.identity(leader_pid)) or (child_id is not None and child_id.same_process(self.table.identity(child_id.pid))):
            raise ProbeError('native-process-remained')
        if read_small(root / 'native.stdout') or read_small(root / 'native.stderr'):
            raise ProbeError('unexpected-native-output')
        self.assert_sentinel(sentinel)
        return {'name': name, 'status': 'passed', 'ownerExitStatus': owner.returncode,
                'guardianExitStatus': expected, 'groupGone': True, 'leaderGone': True,
                'childGone': True if child_id is not None else None,
                'unrelatedSentinelAlive': True, 'elapsedSeconds': time.monotonic() - started,
                'identities': {'owner': dataclasses.asdict(owner_id), 'guardian': dataclasses.asdict(guardian_id),
                               'leader': dataclasses.asdict(leader_id),
                               'child': dataclasses.asdict(child_id) if child_id else None}}

    def wrong_owner(self, sentinel):
        root = self.root / 'wrong-owner'
        root.mkdir(mode=0o700)
        marker = root / 'must-not-run'
        with open(root / 'stdout', 'wb') as out, open(root / 'stderr', 'wb') as err:
            process = subprocess.Popen([str(self.guardian), str(sentinel[1].pid), '/bin/sh', '-c',
                                        'printf ran > "$1"', 'fixture', str(marker)],
                                       env=ENVIRONMENT, stdin=subprocess.DEVNULL, stdout=out,
                                       stderr=err, start_new_session=True)
            # It is our direct child; a fast rejection may finish before a libproc identity query.
            self.processes.append((process, None))
            process.wait(timeout=WAIT_SECONDS)
        if process.returncode != 64 or marker.exists():
            raise ProbeError('wrong-owner-launched-native')
        if read_small(root / 'stdout') or read_small(root / 'stderr'):
            raise ProbeError('unexpected-rejection-output')
        if self.table.members(process.pid):
            raise ProbeError('rejected-guardian-left-group')
        self.assert_sentinel(sentinel)
        return {'name': 'wrong-owner', 'status': 'passed', 'guardianExitStatus': 64,
                'sideEffectAbsent': True, 'groupGone': True, 'unrelatedSentinelAlive': True}

    def cleanup(self):
        results = []
        # Direct children are known kernel-owned handles; poll reaps before PID/start checks.
        for process, identity in self.processes:
            try:
                if process.poll() is None:
                    if identity is None:
                        raise ProbeError('missing-live-child-identity')
                    self.table.signal_identity(identity, signal.SIGKILL)
                process.wait(timeout=WAIT_SECONDS)
                results.append({'pid': process.pid, 'directChildReaped': True})
            except (OSError, subprocess.SubprocessError, ProbeError):
                results.append({'pid': process.pid, 'directChildReaped': False})
        for group, anchors in self.groups.items():
            try:
                self.table.clean_group(group, anchors)
                wait_until(lambda: not self.table.members(group), 'cleanup-group-remained')
                results.append({'group': group, 'groupGone': True})
            except (OSError, ProbeError):
                results.append({'group': group, 'groupGone': False})
        return results


def execute(guardian, output):
    report = {'schemaVersion': 1, 'status': 'failed', 'phase': 'starting', 'cases': [], 'cleanup': []}
    write_report(output, report)
    root = Path(tempfile.mkdtemp(prefix='munie-product-guardian-')).resolve()
    os.chmod(root, 0o700)
    runner = None
    failed = False
    try:
        report['guardianSHA256'] = hashlib.sha256(guardian.read_bytes()).hexdigest()
        report['runnerSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        runner = Runner(guardian, root)
        sentinel = runner.sentinel()
        report['sentinelIdentity'] = dataclasses.asdict(sentinel[1])
        for name in SCRIPTS:
            report['phase'] = name
            write_report(output, report)
            try:
                report['cases'].append(runner.scenario(name, sentinel))
            except BaseException as error:
                report['cases'].append({'name': name, 'status': 'failed', 'error': str(error) if isinstance(error, ProbeError) else type(error).__name__})
                raise
        report['phase'] = 'wrong-owner'
        report['cases'].append(runner.wrong_owner(sentinel))
        report['phase'] = 'cleanup'
    except BaseException as error:
        failed = True
        report['failedPhase'] = report['phase']
        report['error'] = str(error) if isinstance(error, ProbeError) else type(error).__name__
    finally:
        if runner is not None:
            report['cleanup'] = runner.cleanup()
            if not all(item.get('directChildReaped', item.get('groupGone', False)) for item in report['cleanup']):
                failed = True
        if not failed:
            shutil.rmtree(root)
            report['temporaryStateRemoved'] = True
        else:
            report['retainedFixture'] = str(root)
            report['temporaryStateRemoved'] = False
        report['status'] = 'failed' if failed else 'passed'
        report['phase'] = 'finished'
        write_report(output, report)
    return 1 if failed else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--guardian', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        guardian = validate_guardian(args.guardian)
        output = validate_output(args.output, guardian)
        return execute(guardian, output)
    except (ProbeError, OSError) as error:
        print(str(error) if isinstance(error, ProbeError) else 'filesystem-validation-failed', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
