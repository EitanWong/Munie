#!/usr/bin/env python3
"""Observe public SecIdentityCreate declarations and compile/link availability.

Only compiler/toolchain processes run. The emitted dylibs are never loaded or
executed, and the Swift function is never called. This is not runtime, Keychain,
simulator, device, signing, or minimum-OS acceptance evidence.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time


TOTAL_SECONDS = 300
COMMAND_SECONDS = 45
METADATA_SECONDS = 15
MAX_STREAM_BYTES = 262_144
MAX_SOURCE_BYTES = 8_388_608
TARGETS = (
    ('macosx', 'macOS', 'arm64-apple-macosx', ''),
    ('iphoneos', 'iOS', 'arm64-apple-ios', ''),
    ('iphonesimulator', 'iOS', 'arm64-apple-ios', '-simulator'),
    ('watchos', 'watchOS', 'arm64_32-apple-watchos', ''),
    ('appletvos', 'tvOS', 'arm64-apple-tvos', ''),
    ('xros', 'visionOS', 'arm64-apple-xros', ''),
)
SWIFT_SOURCE = '''import Security

public func makeIdentity(certificate: SecCertificate, privateKey: SecKey) -> SecIdentity? {
  SecIdentityCreate(nil, certificate, privateKey)
}
'''


class ProbeFailure(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(value, code):
    if not value:
        raise ProbeFailure(code)


def sha(value):
    return hashlib.sha256(value).hexdigest()


def save_bytes(path, value):
    with path.open('xb') as stream:
        stream.write(value)
    require(path.read_bytes() == value, 'artifact-reopen-mismatch')
    return {'path': str(path), 'bytes': len(value), 'sha256': sha(value)}


def read_minimums(project):
    text = project.read_text(encoding='utf-8')
    section = re.search(r'^  deploymentTarget:\n((?:    .+\n)+)', text, re.MULTILINE)
    require(section is not None, 'project-deployment-targets-missing')
    values = {}
    for platform in {item[1] for item in TARGETS}:
        matches = re.findall(r'^    ' + platform + r": ['\"]?(\d+\.\d+(?:\.\d+)?)[ '\"]*$",
                             section[1], re.MULTILINE)
        require(len(matches) == 1, 'project-deployment-target-invalid-' + platform)
        values[platform] = matches[0]
    return values


def group_gone(pid):
    try:
        os.killpg(pid, 0)
        return False
    except ProcessLookupError:
        return True


def run_command(argv, output, label, report, deadline, seconds=METADATA_SECONDS):
    """Keep literal bounded streams, enforce a deadline, reap the process group."""
    record = {'label': label, 'argv': [str(value) for value in argv], 'exitStatus': None}
    report['commands'].append(record)
    process = None
    selector = selectors.DefaultSelector()
    buffers = {'stdout': bytearray(), 'stderr': bytearray()}
    eof = {'stdout': False, 'stderr': False}
    failure = None
    interruption = None
    started = time.monotonic()
    try:
        require(started < deadline, 'probe-total-deadline')
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        for stream, label_name in ((process.stdout, 'stdout'), (process.stderr, 'stderr')):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, label_name)
        command_deadline = min(deadline, started + seconds)
        while process.poll() is None or not all(eof.values()):
            require(time.monotonic() < command_deadline, 'command-deadline')
            for key, _ in selector.select(.1):
                data = os.read(key.fileobj.fileno(), 8192)
                name = key.data
                if not data:
                    selector.unregister(key.fileobj)
                    eof[name] = True
                    continue
                remaining = MAX_STREAM_BYTES - len(buffers[name])
                buffers[name].extend(data[:remaining])
                require(len(data) <= remaining, 'command-output-limit')
        require(process.returncode >= 0, 'command-signal')
    except BaseException as error:
        failure = error.code if isinstance(error, ProbeFailure) else 'command-execution-error'
        record['failure'] = failure
        if isinstance(error, OSError):
            record['errno'] = error.errno
        if not isinstance(error, (ProbeFailure, OSError)):
            interruption = error
    finally:
        if process is not None:
            # Reap even an exited leader's still-running compiler descendants.
            if not group_gone(process.pid):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                failure = failure or 'command-reap-deadline'
            record['exitStatus'] = process.returncode
            record['processGroupGone'] = group_gone(process.pid)
            if not record['processGroupGone']:
                failure = failure or 'command-process-group-remains'
            for stream in (process.stdout, process.stderr):
                stream.close()
        selector.close()
        record['elapsedSeconds'] = round(time.monotonic() - started, 6)
        record['streamsReachedEOF'] = all(eof.values())
        for name in buffers:
            record[name] = save_bytes(output / (label + '.' + name + '.txt'), bytes(buffers[name]))
        if failure:
            record['failure'] = failure
    if interruption is not None:
        raise interruption
    if failure:
        raise ProbeFailure(failure)
    return record, bytes(buffers['stdout'])


def tool_value(argv, output, label, report, deadline):
    record, value = run_command(argv, output, label, report, deadline)
    require(record['exitStatus'] == 0, 'tool-nonzero-' + label)
    try:
        decoded = value.decode('utf-8').strip()
    except UnicodeError as error:
        raise ProbeFailure('tool-invalid-text-' + label) from error
    require(decoded and '\x00' not in decoded, 'tool-empty-or-invalid-' + label)
    return decoded


def public_evidence(sdk, output):
    framework = sdk / 'System/Library/Frameworks/Security.framework'
    evidence = {'headers': [], 'publicDeclaration': False, 'exportedSymbol': False}
    for name in ('SecIdentity.h', 'Security.h'):
        path = framework / 'Headers' / name
        if not path.is_file():
            continue
        require(path.stat().st_size <= MAX_SOURCE_BYTES, 'header-size-limit')
        value = path.read_bytes()
        saved = save_bytes(output / name, value)
        saved['sourcePath'] = str(path)
        # Comments mentioning the API alone do not constitute a declaration.
        text = re.sub(r'/\*.*?\*/|//[^\n]*', '', value.decode('utf-8'), flags=re.DOTALL)
        saved['declaresSymbol'] = bool(re.search(
            r'\bSecIdentityRef\s+SecIdentityCreate\s*\(\s*CFAllocatorRef\b', text))
        evidence['publicDeclaration'] |= saved['declaresSymbol']
        evidence['headers'].append(saved)
    tbd = framework / 'Security.tbd'
    if tbd.is_file():
        require(tbd.stat().st_size <= MAX_SOURCE_BYTES, 'tbd-size-limit')
        value = tbd.read_bytes()
        evidence['tbd'] = save_bytes(output / 'Security.tbd', value)
        evidence['tbd']['sourcePath'] = str(tbd)
        evidence['exportedSymbol'] = bool(re.search(
            rb'(?<![A-Za-z0-9_])_SecIdentityCreate(?![A-Za-z0-9_])', value))
    return evidence


def probe(output, report, project):
    deadline = time.monotonic() + TOTAL_SECONDS
    minimums = read_minimums(project)
    report['project'] = save_bytes(output / 'project.yml', project.read_bytes())
    report['project']['sourcePath'] = str(project)
    report['minimumOS'] = minimums
    report['swiftSource'] = save_bytes(output / 'IdentitySDKProbe.swift', SWIFT_SOURCE.encode('utf-8'))
    report['xcodeVersion'] = tool_value(['/usr/bin/xcodebuild', '-version'], output,
                                        'xcode-version', report, deadline)
    report['swiftVersion'] = tool_value(['/usr/bin/xcrun', 'swift', '--version'], output,
                                        'swift-version', report, deadline)
    compiler = tool_value(['/usr/bin/xcrun', '--find', 'swiftc'], output,
                          'swiftc-path', report, deadline)
    require(Path(compiler).is_absolute() and Path(compiler).is_file(), 'swiftc-path-invalid')
    for sdk_name, platform, prefix, suffix in TARGETS:
        item_output = output / sdk_name
        item_output.mkdir()
        sdk_path = tool_value(['/usr/bin/xcrun', '--sdk', sdk_name, '--show-sdk-path'],
                              item_output, 'sdk-path', report, deadline)
        sdk_version = tool_value(['/usr/bin/xcrun', '--sdk', sdk_name, '--show-sdk-version'],
                                 item_output, 'sdk-version', report, deadline)
        require(Path(sdk_path).is_absolute() and Path(sdk_path).is_dir(), 'sdk-path-invalid')
        item = {'sdk': sdk_name, 'sdkPath': sdk_path, 'sdkVersion': sdk_version,
                'target': prefix + minimums[platform] + suffix, 'available': False,
                'runtimeExecuted': False}
        report['sdks'].append(item)
        item.update(public_evidence(Path(sdk_path), item_output))
        library = item_output / 'libIdentitySDKProbe.dylib'
        command = [compiler, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
                   '-emit-library', '-module-name', 'IdentitySDKProbe', '-target', item['target'],
                   '-sdk', sdk_path, '-module-cache-path', str(output / 'module-cache'),
                   '-framework', 'Security', str(output / 'IdentitySDKProbe.swift'),
                   '-o', str(library)]
        result, _ = run_command(command, item_output, 'compile-link', report, deadline,
                                seconds=COMMAND_SECONDS)
        item['compileLinkExitStatus'] = result['exitStatus']
        item['compileLinkSucceeded'] = result['exitStatus'] == 0
        if item['compileLinkSucceeded']:
            require(library.is_file() and library.stat().st_size > 0, 'linked-library-missing')
            value = library.read_bytes()
            item['library'] = {'path': str(library), 'bytes': len(value), 'sha256': sha(value)}
        item['available'] = (item['publicDeclaration'] and item['exportedSymbol'] and
                             item['compileLinkSucceeded'])
        item['unavailableReasons'] = [name for name, valid in (
            ('public-declaration-missing', item['publicDeclaration']),
            ('tbd-symbol-missing', item['exportedSymbol']),
            ('compile-or-link-failed', item['compileLinkSucceeded'])) if not valid]
    report['probeCompleted'] = True
    report['allAvailable'] = all(item['available'] for item in report['sdks'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True,
                        help='Fresh directory; existing evidence is never overwritten.')
    args = parser.parse_args()
    output = args.output_dir.expanduser().absolute()
    try:
        output.mkdir(mode=0o700, parents=False, exist_ok=False)
    except OSError:
        print(json.dumps({'probeCompleted': False, 'failure': 'output-directory-not-fresh-or-usable'}))
        return 2
    report = {'schemaVersion': 1, 'probeCompleted': False, 'allAvailable': False,
              'purpose': 'public-SecIdentityCreate-compile-link-only', 'runtimeExecuted': False,
              'utcStarted': datetime.now(timezone.utc).isoformat(), 'commands': [], 'sdks': [],
              'developerDirectory': os.environ.get('DEVELOPER_DIR'),
              'limits': {'totalSeconds': TOTAL_SECONDS, 'commandSeconds': COMMAND_SECONDS,
                         'metadataSeconds': METADATA_SECONDS, 'streamBytes': MAX_STREAM_BYTES},
              'scopeLimits': ['no-runtime-Security-calls', 'no-Keychain-access',
                              'no-generated-library-execution', 'no-device-or-simulator-acceptance',
                              'availability-is-current-SDK-declaration-export-and-link-only']}
    status = 0
    def terminated(_signum, _frame):
        raise ProbeFailure('runner-terminated')
    prior_sigterm = signal.signal(signal.SIGTERM, terminated)
    try:
        report['runner'] = save_bytes(output / 'probe-identity-sdk.py', Path(__file__).read_bytes())
        probe(output, report, Path(__file__).resolve().parents[1] / 'project.yml')
    except BaseException as error:
        status = 1
        report['failure'] = error.code if isinstance(error, ProbeFailure) else type(error).__name__
        if isinstance(error, OSError):
            report['failureErrno'] = error.errno
    finally:
        signal.signal(signal.SIGTERM, prior_sigterm)
    report['utcFinished'] = datetime.now(timezone.utc).isoformat()
    try:
        artifact = save_bytes(output / 'report.json',
                              (json.dumps(report, indent=2, sort_keys=True) + '\n').encode('utf-8'))
    except (ProbeFailure, OSError):
        print(json.dumps({'probeCompleted': False, 'failure': 'report-write-failed'}))
        return 2
    print(json.dumps({'probeCompleted': report['probeCompleted'],
                      'allAvailable': report['allAvailable'], 'report': artifact,
                      'available': {item['sdk']: item['available'] for item in report['sdks']},
                      **({'failure': report['failure']} if 'failure' in report else {})}, sort_keys=True))
    return status


if __name__ == '__main__':
    sys.exit(main())
