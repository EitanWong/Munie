#!/usr/bin/env python3
"""Fixture-only owner for Codex children when the Swift experiment host dies.

Launch in a fresh process group with an explicitly supplied environment. Standard output
and error belong only to the native protocol/diagnostics; no command or path is logged.
The registry is a private, unique launch identity, not a general process-discovery API.
"""

import argparse
import json
import os
from pathlib import Path
import secrets
import select
import signal
import stat
import subprocess
import sys
import time

FORWARD_BYTES = 65_536
READ_BYTES = 16_384
EOF_FORWARD_SECONDS = .75
CLOSE_SECONDS = .75
TERM_SECONDS = .75
SESSION_SECONDS = 120
QUERY_SECONDS = .5
QUERY_BYTES = 65_536
FAILURE = b'Native host guardian failed\n'


class GuardianError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise GuardianError()


def arguments(argv):
    parser = Parser(add_help=False)
    parser.add_argument('--parent-pid', type=int, required=True)
    parser.add_argument('--registry', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    result = parser.parse_args(argv)
    if result.command[:1] == ['--']:
        result.command = result.command[1:]
    if (result.parent_pid <= 1 or result.parent_pid == os.getpid() or
            not result.registry.is_absolute() or not result.registry.name or
            not result.command or not Path(result.command[0]).is_absolute() or
            len(result.command) > 256 or
            any('\0' in value or len(value.encode()) > 65_536 for value in result.command)):
        raise GuardianError()
    return result


def register(path, parent_pid):
    """Publish complete UTF-8 bytes through an exclusive link; never replace any existing leaf."""
    parent = path.parent
    if Path(os.path.realpath(parent)) != parent:
        raise GuardianError()
    directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    temporary = '.guardian-' + secrets.token_hex(16)
    descriptor = None
    created = False
    try:
        info = os.fstat(directory)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise GuardianError()
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=directory)
        created = True
        os.fchmod(descriptor, 0o600)
        data = (json.dumps({'registryVersion': 1, 'processGroupID': os.getpgrp(),
                            'guardianPID': os.getpid(), 'parentPID': parent_pid},
                           sort_keys=True) + '\n').encode('utf-8')
        offset = 0
        while offset < len(data):
            count = os.write(descriptor, data[offset:])
            if count <= 0:
                raise GuardianError()
            offset += count
        os.fsync(descriptor)
        os.link(temporary, path.name, src_dir_fd=directory, dst_dir_fd=directory,
                follow_symlinks=False)
        os.unlink(temporary, dir_fd=directory)
        created = False
        os.fsync(directory)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if created:
            os.unlink(temporary, dir_fd=directory)
        os.close(directory)


def owned_members(group):
    """Bounded query restricted to this one owned group, excluding the query process itself."""
    query = subprocess.Popen(['/bin/ps', '-g', str(group), '-o', 'pid=,pgid='],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, close_fds=True)
    data = bytearray()
    deadline = time.monotonic() + QUERY_SECONDS
    os.set_blocking(query.stdout.fileno(), False)
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([query.stdout], [], [], .01)
            if ready:
                chunk = os.read(query.stdout.fileno(), READ_BYTES)
                if not chunk:
                    query.wait(timeout=max(.001, deadline - time.monotonic()))
                    if query.returncode != 0:
                        raise GuardianError()
                    members = []
                    for line in bytes(data).splitlines():
                        fields = line.split()
                        if len(fields) != 2:
                            raise GuardianError()
                        pid, pgid = (int(field) for field in fields)
                        if pgid != group:
                            raise GuardianError()
                        if pid not in (os.getpid(), query.pid):
                            members.append(pid)
                    return members
                data.extend(chunk)
                if len(data) > QUERY_BYTES:
                    raise GuardianError()
        raise GuardianError()
    finally:
        if query.poll() is None:
            query.kill()
            try:
                query.wait(timeout=QUERY_SECONDS)
            except subprocess.TimeoutExpired:
                # It remains in our owned group; final escalation also terminates it.
                pass
        query.stdout.close()


def group_signal(group, value):
    if group != os.getpid() or os.getpgrp() != group:
        raise GuardianError()
    os.killpg(group, value)


def clean(child, group):
    """EOF first, then TERM; KILL includes this guardian so no ignored child survives it."""
    if child is None:
        return 0
    try:
        child.stdin.close()
    except OSError:
        pass
    for value, seconds in ((None, CLOSE_SECONDS), (signal.SIGTERM, TERM_SECONDS)):
        if value is not None:
            group_signal(group, value)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            child.poll()
            try:
                empty = not owned_members(group)
            except (OSError, ValueError, subprocess.SubprocessError, GuardianError):
                empty = False
            if child.returncode is not None and empty:
                return child.returncode if child.returncode >= 0 else 128 - child.returncode
            time.sleep(.01)
    group_signal(group, signal.SIGKILL)
    # SIGKILL cannot be caught. This is only a defensive guard against an impossible return.
    raise GuardianError()


def forward(child, parent_pid, stopping, initial):
    os.set_blocking(child.stdin.fileno(), False)
    poller = select.poll()
    poller.register(0, select.POLLIN | select.POLLHUP | select.POLLERR)
    pending = bytearray(initial)
    input_eof = False
    eof_deadline = None
    deadline = time.monotonic() + SESSION_SECONDS
    while time.monotonic() < deadline:
        if stopping[0] or os.getppid() != parent_pid:
            return
        if child.poll() is not None:
            return
        events = dict(poller.poll(0))
        flags = events.get(0, 0)
        if flags & (select.POLLHUP | select.POLLERR):
            if eof_deadline is None:
                eof_deadline = time.monotonic() + EOF_FORWARD_SECONDS
        if not input_eof and len(pending) < FORWARD_BYTES:
            try:
                data = os.read(0, min(READ_BYTES, FORWARD_BYTES - len(pending)))
                if data:
                    pending.extend(data)
                else:
                    input_eof = True
            except BlockingIOError:
                pass
            except InterruptedError:
                continue
        if pending:
            try:
                count = os.write(child.stdin.fileno(), pending)
                if count <= 0:
                    raise GuardianError()
                del pending[:count]
            except BlockingIOError:
                pass
            except InterruptedError:
                continue
            except BrokenPipeError:
                return
        if input_eof and not pending:
            return
        if eof_deadline is not None and time.monotonic() >= eof_deadline:
            return
        # Forward promptly under load, without busy-spinning when a peer has backpressure.
        readers = [] if input_eof or len(pending) >= FORWARD_BYTES else [0]
        writers = [child.stdin] if pending else []
        select.select(readers, writers, [], .01)


def run(args):
    group = os.getpgrp()
    if group != os.getpid():
        raise GuardianError()
    stopping = [False]
    # A caught no-op protects this owner, while exec restores the child's default TERM handling.
    # SIG_IGN would instead survive exec and accidentally make every native child ignore TERM.
    signal.signal(signal.SIGTERM, lambda *_: None)
    for value in (signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(value, lambda *_: stopping.__setitem__(0, True))
    os.set_blocking(0, False)
    # Observe death/EOF before registration, but still publish our owned identity for the driver.
    parent_gone = os.getppid() != args.parent_pid
    poller = select.poll()
    poller.register(0, select.POLLIN | select.POLLHUP | select.POLLERR)
    input_closed = any(flags & (select.POLLHUP | select.POLLERR)
                       for _, flags in poller.poll(0))
    initial = b''
    if not input_closed:
        try:
            initial = os.read(0, READ_BYTES)
            input_closed = not initial
        except BlockingIOError:
            pass
    register(args.registry, args.parent_pid)
    if parent_gone or input_closed or stopping[0] or os.getppid() != args.parent_pid:
        return 0
    child = None
    failed = False
    try:
        # No shell, environment discovery, credential/config loading, setsid or new process group.
        # The trusted caller supplied this guardian's complete environment; the child inherits it.
        child = subprocess.Popen(args.command, stdin=subprocess.PIPE, close_fds=True)
        if os.getpgid(child.pid) != group:
            raise GuardianError()
        forward(child, args.parent_pid, stopping, initial)
    except BaseException:
        # Preserve the fixed diagnostic boundary even for unexpected fixture/runtime failures.
        failed = True
    finally:
        status = clean(child, group)
    if failed:
        raise GuardianError()
    return status


def main(argv=None):
    try:
        return run(arguments(sys.argv[1:] if argv is None else argv))
    except BaseException:
        try:
            os.set_blocking(2, False)
            os.write(2, FAILURE)
        except OSError:
            pass
        return 1


if __name__ == '__main__':
    sys.exit(main())
