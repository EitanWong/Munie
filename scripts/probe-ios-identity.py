#!/usr/bin/env python3
"""Opt-in iOS Simulator identity lifecycle; never touches an existing simulator.

The app alone handles its run-scoped Keychain items. This runner reads only its
fixed, bounded report file, never its private ownership manifest or references.
Optional --fault-case runs a separate expected creation failure and cleanup probe;
it never treats an ordinary lifecycle failure as successful recovery evidence.
No simulator, account, Keychain or network operation occurs on import.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid


BUNDLE = 'app.munie.research.identity'
MINIMUM = '18.0'
PHASES = ('create', 'reopen', 'delete', 'confirm-deleted')
FAULT_CASES = ('after-key-add', 'after-certificate-add')
REPORT_PARTS = ('Library', 'Application Support', 'MunieIdentityResearch', 'report.json')
TOTAL_SECONDS = 600
CLEANUP_RESERVE = 90
BOOT_SECONDS = 240
PHASE_SECONDS = 30
COMMAND_SECONDS = 15
INSTALL_SECONDS = 120
INVENTORY_SECONDS = 30
MAX_STREAM = 262_144
MAX_DIAGNOSTIC = 8192
MAX_PHASE_REPORT = 16_384
CHECKS = {
    'create': {'keyPublicMatched': True, 'identityLeafMatched': True,
               'identityPossessionVerified': True, 'privateKeyPermanent': True,
               'certificatePresent': True, 'controlStillUsable': True,
               'mismatchedIdentityRejected': True},
    'reopen': {'keyPublicMatched': True, 'identityLeafMatched': True,
               'identityPossessionVerified': True, 'privateKeyPermanent': True,
               'certificatePresent': True, 'controlStillUsable': True},
    'delete': {'keyDeleteStatus': 0, 'certificateDeleteStatus': 0,
               'keyLookupStatus': -25300, 'certificateLookupStatus': -25300,
               'controlStillUsable': True},
    'confirm-deleted': {'keyLookupStatus': -25300, 'certificateLookupStatus': -25300,
                        'controlStillUsable': True},
    'cleanup': {'cleanupOwnItems': True},
}


class ProbeFailure(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise ProbeFailure(code)


def failure_code(error):
    return error.code if isinstance(error, ProbeFailure) else type(error).__name__


def sha(value):
    return hashlib.sha256(value).hexdigest()


def new_uuid():
    return str(uuid.uuid4()).upper()


def fault_expectation(fault_case):
    return {'faultCase': fault_case, 'requiredFailure': 'injected-' + fault_case, 'confirmed': False}


def canonical_uuid(value):
    require(type(value) is str and re.fullmatch(
        r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', value), 'invalid-uuid')
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError as error:
        raise ProbeFailure('invalid-uuid') from error


def strict_json(value):
    def unique(pairs):
        result = {}
        for key, item in pairs:
            require(key not in result, 'duplicate-json-member')
            result[key] = item
        return result
    try:
        result = json.loads(value.decode('utf-8'), object_pairs_hook=unique,
                            parse_constant=lambda _: (_ for _ in ()).throw(
                                ProbeFailure('nonfinite-json')))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ProbeFailure('invalid-json') from error
    require(type(result) is dict, 'json-object-required')
    return result


def version(value):
    require(type(value) is str and re.fullmatch(r'\d+(?:\.\d+){0,2}', value), 'invalid-version')
    parts = tuple(int(part) for part in value.split('.'))
    require(all(0 <= part <= 255 for part in parts), 'version-outside-range')
    return parts + (0,) * (3 - len(parts))


def compatible_device(device, runtime):
    if not (type(device) is dict and type(device.get('identifier')) is str and
            device['identifier'].startswith('com.apple.CoreSimulator.SimDeviceType.iPhone-') and
            type(device.get('name')) is str and device['name'].startswith('iPhone')):
        return False
    supported = runtime.get('supportedDeviceTypes')
    listed = False
    if type(supported) is list:
        identifiers = [item.get('identifier') if type(item) is dict else item for item in supported]
        if identifiers:
            if device['identifier'] not in identifiers:
                return False
            listed = True
    packed = sum(part << shift for part, shift in zip(version(runtime['version']), (16, 8, 0)))
    lower, upper = device.get('minRuntimeVersion'), device.get('maxRuntimeVersion')
    if type(lower) is int and type(upper) is int:
        return lower <= packed <= upper
    lower, upper = device.get('minRuntimeVersionString'), device.get('maxRuntimeVersionString')
    if type(lower) is str and type(upper) is str:
        return version(lower) <= version(runtime['version']) <= version(upper)
    return listed  # A supported type list is evidence when bounds are absent.


def select_runtime(runtimes, device_types, sdk, minimum=MINIMUM):
    require(type(runtimes) is dict and type(runtimes.get('runtimes')) is list and
            type(device_types) is dict and type(device_types.get('devicetypes')) is list,
            'simulator-inventory-schema')
    candidates = []
    for runtime in runtimes['runtimes']:
        if not (type(runtime) is dict and runtime.get('isAvailable') is True and
                type(runtime.get('identifier')) is str and
                runtime['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')):
            continue
        runtime_version = version(runtime.get('version'))
        if not version(minimum) <= runtime_version <= version(sdk):
            continue
        for index, device in enumerate(device_types['devicetypes']):
            if compatible_device(device, runtime):
                device_minimum = device.get('minRuntimeVersion')
                generation = device_minimum if type(device_minimum) is int and device_minimum >= 0 else 0
                # Device names sort SE ahead of current numbered iPhones. Prefer
                # the newest supported profile metadata, then the SDK's order.
                candidates.append((runtime_version, generation, -index, runtime, device))
    require(candidates, 'no-compatible-available-iphone-runtime')
    _, _, _, runtime, device = max(candidates, key=lambda item: item[:3])
    bounds = {key: device[key] for key in ('minRuntimeVersion', 'maxRuntimeVersion',
              'minRuntimeVersionString', 'maxRuntimeVersionString') if key in device}
    return {'runtimeID': runtime['identifier'], 'runtimeVersion': runtime['version'],
            'deviceTypeID': device['identifier'], 'deviceTypeName': device['name'],
            'compatibilityBounds': bounds}


def group_gone(process_id):
    try:
        os.killpg(process_id, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        return False


class CommandRunner:
    """Drain both bounded streams, reap and clean a private group on every path."""

    def __init__(self, records, environment=None):
        self.records = records
        self.environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'LC_ALL': 'C'}
        for name in ('DEVELOPER_DIR', 'HOME', 'TMPDIR'):
            if name in os.environ:
                self.environment[name] = os.environ[name]
        if environment is not None:
            self.environment = environment

    def run(self, stage, command, deadline, seconds=COMMAND_SECONDS, *, allowed=(0,), private=False):
        remaining = min(seconds, deadline - time.monotonic())
        require(remaining > 0, 'command-budget-exhausted')
        started = time.monotonic()
        end = time.monotonic() + remaining
        record = {'stage': stage, 'argv': [str(item) for item in command],
                  'effectiveLimitSeconds': remaining}
        self.records.append(record)
        process = selector = None
        output = {'stdout': bytearray(), 'stderr': bytearray()}
        totals = {'stdout': 0, 'stderr': 0}
        hashes = {'stdout': hashlib.sha256(), 'stderr': hashlib.sha256()}
        eof = {'stdout': False, 'stderr': False}
        failure = None
        escalated = False
        cleanup_errors = []

        def pump(wait):
            for key, _ in selector.select(max(0, min(.1, wait))):
                data = os.read(key.fileobj.fileno(), 8192)
                name = key.data
                if not data:
                    selector.unregister(key.fileobj)
                    eof[name] = True
                    continue
                totals[name] += len(data)
                hashes[name].update(data)
                output[name].extend(data[:max(0, MAX_STREAM - len(output[name]))])

        try:
            process = subprocess.Popen([str(item) for item in command], env=self.environment,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True, bufsize=0)
            selector = selectors.DefaultSelector()
            for stream, name in ((process.stdout, 'stdout'), (process.stderr, 'stderr')):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            while process.poll() is None or not all(eof.values()):
                require(time.monotonic() < end, 'command-timeout')
                pump(end - time.monotonic())
                require(all(count <= MAX_STREAM for count in totals.values()), 'command-output-limit')
            require(process.returncode in allowed, 'command-exit-' + stage)
        except BaseException as error:
            failure = error
        finally:
            if process is not None:
                for candidate in (None, signal.SIGTERM, signal.SIGKILL):
                    process.poll()
                    if process.returncode is not None and all(eof.values()) and group_gone(process.pid):
                        break
                    if candidate is not None:
                        try:
                            os.killpg(process.pid, candidate)
                            escalated = True
                        except ProcessLookupError:
                            pass
                        except OSError as error:
                            cleanup_errors.append(error.errno)
                    cleanup_end = time.monotonic() + (.1 if candidate is None else 1)
                    while time.monotonic() < cleanup_end:
                        if selector is not None:
                            try:
                                pump(cleanup_end - time.monotonic())
                            except OSError as error:
                                cleanup_errors.append(error.errno)
                                break
                        process.poll()
                        if process.returncode is not None and all(eof.values()) and group_gone(process.pid):
                            break
                try:
                    process.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    cleanup_errors.append('reap-timeout')
                record.update(exitStatus=process.returncode, streamsReachedEOF=all(eof.values()),
                              processGroupGone=group_gone(process.pid), escalated=escalated,
                              cleanupErrors=cleanup_errors)
                for stream in (process.stdout, process.stderr):
                    stream.close()
                if selector is not None:
                    selector.close()
                if not (record['streamsReachedEOF'] and record['processGroupGone'] and not cleanup_errors):
                    failure = failure or ProbeFailure('command-cleanup-failed')
            else:
                record['spawned'] = False
            for name in ('stdout', 'stderr'):
                record[name + 'Bytes'] = totals[name]
                record[name + 'SHA256'] = hashes[name].hexdigest()
                if not private:
                    record[name] = bytes(output[name][:MAX_DIAGNOSTIC]).decode('utf-8', errors='replace')
                    record[name + 'Truncated'] = totals[name] > MAX_DIAGNOSTIC
            if failure is not None:
                record['failure'] = failure_code(failure)
            record['elapsedSeconds'] = round(time.monotonic() - started, 6)
        if failure is not None:
            raise failure
        return bytes(output['stdout']), bytes(output['stderr']), process.returncode


def validate_phase(frame, run_id, phase, nonce, previous, expected_pid):
    required = {'schemaVersion', 'runID', 'phase', 'nonce', 'launchID', 'processID', 'passed', 'checks'}
    require(type(frame) is dict and required <= frame.keys() <= required | {'failure', 'osStatus'},
            'phase-report-schema')
    require(type(frame['schemaVersion']) is int and frame['schemaVersion'] == 1 and
            type(frame['passed']) is bool and frame['phase'] == phase, 'phase-report-version-or-phase')
    require(canonical_uuid(frame['runID']) == run_id and canonical_uuid(frame['nonce']) == nonce,
            'phase-report-owner-or-nonce')
    launch_id = canonical_uuid(frame['launchID'])
    require(type(frame['processID']) is int and frame['processID'] > 1 and
            frame['processID'] == expected_pid, 'phase-report-process')
    require(all(launch_id != item['launchID'] and frame['processID'] != item['processID']
                for item in previous), 'phase-did-not-cold-relaunch')
    if 'failure' in frame:
        require(type(frame['failure']) is str and re.fullmatch(r'[a-z][a-z0-9-]{0,95}', frame['failure']),
                'phase-failure-code')
    if 'osStatus' in frame:
        require(type(frame['osStatus']) is int and -(2**31) <= frame['osStatus'] < 2**31,
                'phase-osstatus-type')
    require(type(frame['checks']) is dict and frame['checks'].keys() <= CHECKS[phase].keys(),
            'phase-checks-schema')
    for name, value in frame['checks'].items():
        require(type(value) is type(CHECKS[phase][name]), 'phase-check-type')
    result = {key: frame[key] for key in required}
    result.update(runID=run_id, nonce=nonce, launchID=launch_id)
    for name in ('failure', 'osStatus'):
        if name in frame:
            result[name] = frame[name]
    if frame['passed']:
        require('failure' not in frame and 'osStatus' not in frame and frame['checks'] == CHECKS[phase],
                'phase-success-missing-evidence')
    else:
        require('failure' in frame, 'phase-failed-without-code')
    return result


def phase_report_path(container):
    root = Path(container).resolve(strict=True)
    require(root.is_dir(), 'app-container-not-directory')
    candidate = root
    for name in REPORT_PARTS:
        candidate = candidate / name
        require(not candidate.is_symlink(), 'phase-report-symlink')
    return candidate


def read_phase_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(descriptor, 'rb') as stream:
        details = os.fstat(stream.fileno())
        require(stat.S_ISREG(details.st_mode) and 0 < details.st_size <= MAX_PHASE_REPORT,
                'phase-report-file-limit')
        value = stream.read(MAX_PHASE_REPORT + 1)
    require(len(value) <= MAX_PHASE_REPORT, 'phase-report-file-limit')
    return strict_json(value)


def hash_app(path):
    require(path.is_dir() and path.suffix == '.app' and not path.is_symlink(), 'app-bundle-required')
    info_path = path / 'Info.plist'
    require(info_path.is_file() and not info_path.is_symlink(), 'app-info-required')
    try:
        with info_path.open('rb') as stream:
            info = plistlib.load(stream)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ProbeFailure('app-info-invalid') from error
    require(info.get('CFBundleIdentifier') == BUNDLE, 'app-wrong-bundle')
    require(type(info.get('CFBundleSupportedPlatforms')) is list and
            'iPhoneSimulator' in info['CFBundleSupportedPlatforms'] and
            version(info.get('MinimumOSVersion')) == version(MINIMUM), 'app-not-research-ios-simulator')
    executable = info.get('CFBundleExecutable')
    require(type(executable) is str and re.fullmatch(r'[A-Za-z0-9_.-]{1,100}', executable) and
            (path / executable).is_file(), 'app-executable-missing')
    digest = hashlib.sha256()
    total, count = 0, 0
    for item in sorted(path.rglob('*')):
        require(not item.is_symlink(), 'app-symlink-refused')
        if item.is_dir():
            continue
        require(item.is_file(), 'app-special-file')
        count += 1
        total += item.stat().st_size
        require(count <= 10_000 and total <= 512 * 1024 * 1024, 'app-hash-size-limit')
        digest.update(item.relative_to(path).as_posix().encode('utf-8') + b'\0')
        with item.open('rb') as stream:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        digest.update(b'\0')
    return {'bundleID': BUNDLE, 'minimumOS': info['MinimumOSVersion'],
            'sha256': digest.hexdigest(), 'files': count, 'bytes': total}


def source_snapshot(repo):
    fixture = repo / 'scripts/fixtures/device-identity-ios'
    paths = [Path(__file__).resolve(), repo / 'scripts/build-ios-identity-probe.sh',
             fixture / 'Tests/OwnershipChecks.swift', fixture / 'project.yml', fixture / 'Package.resolved',
             repo / 'scripts/fixtures/device-identity/Sources/MunieDeviceIdentityProbe/CSR.swift']
    paths.extend(sorted((fixture / 'App').glob('*.swift')))
    require(len(paths) >= 9, 'research-source-missing')
    sources = []
    for path in paths:
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 1024 * 1024,
                'research-source-invalid')
        raw = path.read_bytes()
        sources.append({'path': str(path), 'bytes': len(raw), 'sha256': sha(raw)})
    project = (fixture / 'project.yml').read_text(encoding='utf-8')
    require(re.search(r"deploymentTarget:\s*\n\s+iOS:\s*['\"]?18\.0['\"]?\s*\n", project),
            'research-project-minimum-changed')
    lock = strict_json((fixture / 'Package.resolved').read_bytes())
    archive = strict_json((repo / 'references/licenses/device-identity/manifest.json').read_bytes())
    expected = {item['identity']: (item['repository'], item['revision']) for item in archive['packages']}
    actual = {item['identity']: (item['location'], item['state']['revision']) for item in lock['pins']}
    require(len(expected) == len(archive['packages']) == len(actual) == len(lock['pins']) == 3 and
            expected == actual, 'research-lock-not-reviewed')
    return {'files': sources, 'lockSHA256': sha((fixture / 'Package.resolved').read_bytes()),
            'minimumOS': MINIMUM,
            'limitation': 'Source snapshot at run time; app hash alone is not build-provenance proof.'}


class Experiment:
    def __init__(self, app, report, runner, run_id=None, *, fault_case=None):
        require(fault_case is None or fault_case in FAULT_CASES, 'unknown-fault-case')
        self.app, self.report, self.runner = app, report, runner
        self.fault_case = fault_case
        self.run_id = new_uuid() if run_id is None else canonical_uuid(run_id)
        self.name = 'MunieIdentityResearch-' + self.run_id
        self.simulator = None
        self.ownership_verified = False
        self.creation_attempted = False
        self.install_attempted = False
        self.container = None
        self.selection = None
        self.end = time.monotonic() + TOTAL_SECONDS
        self.work_end = self.end - CLEANUP_RESERVE
        self.history = []
        self.report.update(runID=self.run_id, phases=[], cleanup={'errors': []})
        if fault_case is not None:
            self.report.update(experiment='expected-creation-failure-recovery',
                               expectedCreationFailure=fault_expectation(fault_case))

    def command(self, stage, *arguments, deadline=None, seconds=COMMAND_SECONDS, allowed=(0,), private=False):
        return self.runner.run(stage, list(arguments), self.work_end if deadline is None else deadline,
                               seconds, allowed=allowed, private=private)

    def inventory(self, deadline):
        raw, _, _ = self.command('own-simulator-inventory', 'xcrun', 'simctl', 'list', 'devices', '--json',
                                  deadline=deadline, seconds=INVENTORY_SECONDS, private=True)
        value = strict_json(raw)
        require(type(value.get('devices')) is dict and
                all(type(items) is list for items in value['devices'].values()), 'device-inventory-schema')
        return value['devices']

    def find_owned(self, devices):
        candidates = []
        for runtime, entries in devices.items():
            for item in entries:
                require(type(item) is dict, 'device-entry-schema')
                item_id = canonical_uuid(item.get('udid'))
                if self.simulator is not None and item_id == self.simulator:
                    require(item.get('name') == self.name and runtime == self.selection['runtimeID'],
                            'created-simulator-owner-mismatch')
                    candidates.append(item)
                elif self.simulator is None and item.get('name') == self.name:
                    require(runtime == self.selection['runtimeID'], 'created-simulator-runtime-mismatch')
                    candidates.append(item)
        require(len(candidates) <= 1, 'ambiguous-created-simulator')
        if candidates:
            self.simulator = canonical_uuid(candidates[0]['udid'])
            self.ownership_verified = True
            return candidates[0]
        return None

    def owned_absent(self, devices):
        return all(canonical_uuid(item.get('udid')) != self.simulator
                   for items in devices.values() for item in items
                   if type(item) is dict) and all(type(item) is dict
                   for items in devices.values() for item in items)

    def terminate(self, deadline):
        _, errors, status = self.command('app-terminate', 'xcrun', 'simctl', 'terminate', self.simulator,
                                          BUNDLE, deadline=deadline, seconds=10, allowed=(0, 3))
        if status != 0:
            require(b'found nothing to terminate' in errors.lower() or b'not running' in errors.lower(),
                    'app-termination-unconfirmed')

    def phase(self, name, cleanup=False):
        deadline = min(self.end if cleanup else self.work_end, time.monotonic() + PHASE_SECONDS)
        if name != 'create':
            self.terminate(deadline)
        if self.container is None:
            raw, _, _ = self.command('app-container', 'xcrun', 'simctl', 'get_app_container',
                                      self.simulator, BUNDLE, 'data', deadline=deadline, private=True)
            try:
                container = raw.decode('utf-8').strip()
            except UnicodeError as error:
                raise ProbeFailure('app-container-encoding') from error
            require('\n' not in container and Path(container).is_absolute(), 'app-container-path')
            self.container = Path(container)
        path = phase_report_path(self.container)
        if path.exists():
            require(path.is_file(), 'phase-report-not-file')
            path.unlink()
        nonce = new_uuid()
        arguments = ['xcrun', 'simctl', 'launch', self.simulator, BUNDLE,
                     '--run-id', self.run_id, '--phase', name, '--nonce', nonce]
        if name == 'create' and self.fault_case is not None:
            arguments.extend(['--fault', self.fault_case])
        raw, _, _ = self.command('app-launch-' + name, *arguments,
                                  deadline=deadline, seconds=10)
        match = re.fullmatch(re.escape(BUNDLE) + r': ([1-9][0-9]*)\s*', raw.decode('ascii'))
        require(match is not None, 'app-launch-pid-missing')
        process_id = int(match[1])
        while True:
            require(time.monotonic() < deadline, 'phase-report-timeout-' + name)
            # Recheck intermediate directory symlinks every time; never read the manifest.
            path = phase_report_path(self.container)
            try:
                frame = read_phase_file(path)
            except FileNotFoundError:
                time.sleep(min(.05, max(0, deadline - time.monotonic())))
                continue
            result = validate_phase(frame, self.run_id, name, nonce, self.history, process_id)
            self.history.append(result)
            self.report['phases'].append(result)
            if name == 'create' and self.fault_case is not None:
                expected = self.report['expectedCreationFailure']
                expected['observed'] = result
                expected['confirmed'] = (result['passed'] is False and result['checks'] == {} and
                                         result.get('failure') == expected['requiredFailure'] and
                                         'osStatus' not in result)
                require(expected['confirmed'], 'expected-creation-failure-not-observed')
            else:
                require(result['passed'], 'app-phase-failed-' + name)
            return result

    def execute(self):
        failure = None
        try:
            xcode, _, _ = self.command('xcode-version', 'xcodebuild', '-version')
            sdk, _, _ = self.command('simulator-sdk', 'xcodebuild', '-version', '-sdk',
                                      'iphonesimulator', 'SDKVersion')
            sdk = sdk.decode('ascii').strip()
            version(sdk)
            raw_runtimes, _, _ = self.command('available-runtimes', 'xcrun', 'simctl', 'list',
                                               'runtimes', '--json')
            raw_types, _, _ = self.command('device-types', 'xcrun', 'simctl', 'list', 'devicetypes', '--json')
            self.selection = select_runtime(strict_json(raw_runtimes), strict_json(raw_types), sdk)
            self.report['tools'] = {'xcode': xcode.decode('utf-8').strip(), 'simulatorSDK': sdk,
                                    'python': sys.version, 'pythonExecutable': sys.executable}
            self.report['simulatorSelection'] = dict(self.selection, name=self.name)
            self.creation_attempted = True
            raw, _, _ = self.command('simulator-create', 'xcrun', 'simctl', 'create', self.name,
                                      self.selection['deviceTypeID'], self.selection['runtimeID'])
            self.simulator = canonical_uuid(raw.decode('ascii').strip())
            self.report['createdSimulatorID'] = self.simulator
            require(self.find_owned(self.inventory(self.work_end)) is not None,
                    'created-simulator-not-in-inventory')
            self.command('simulator-boot', 'xcrun', 'simctl', 'boot', self.simulator)
            self.command('simulator-boot-ready', 'xcrun', 'simctl', 'bootstatus', self.simulator, '-b',
                           seconds=BOOT_SECONDS)
            booted = self.find_owned(self.inventory(self.work_end))
            require(booted is not None and booted.get('state') == 'Booted',
                    'booted-simulator-not-ready')
            self.install_attempted = True
            self.command('app-install-once', 'xcrun', 'simctl', 'install', self.simulator, str(self.app),
                         seconds=INSTALL_SECONDS)
            for name in (('create',) if self.fault_case is not None else PHASES):
                self.phase(name)
        except BaseException as error:
            failure = error
        finally:
            errors = self.report['cleanup']['errors']

            def attempt(stage, action):
                try:
                    return action()
                except BaseException as error:
                    errors.append({'stage': stage, 'failure': failure_code(error)})
                    return None

            if self.creation_attempted and self.simulator is None:
                attempt('recover-created-simulator', lambda: self.find_owned(self.inventory(self.end)))
            if self.simulator is not None:
                current = attempt('inspect-own-simulator', lambda: self.find_owned(self.inventory(self.end)))
                owned = current is not None and self.ownership_verified
                if self.install_attempted and owned:
                    result = attempt('app-keychain-cleanup', lambda: self.phase('cleanup', cleanup=True))
                    self.report['cleanup']['keychainCleanupConfirmed'] = result is not None
                    attempt('app-final-terminate', lambda: self.terminate(self.end))
                elif self.install_attempted:
                    errors.append({'stage': 'app-keychain-cleanup',
                                   'failure': 'created-simulator-ownership-unconfirmed'})
                else:
                    self.report['cleanup']['keychainCleanupNotAttemptedBeforeInstall'] = True
                if owned and current.get('state') != 'Shutdown':
                    attempt('own-simulator-shutdown', lambda: self.command(
                        'simulator-shutdown', 'xcrun', 'simctl', 'shutdown', self.simulator,
                        deadline=self.end, seconds=15))
                if owned:
                    attempt('own-simulator-delete', lambda: self.command(
                        'simulator-delete', 'xcrun', 'simctl', 'delete', self.simulator,
                        deadline=self.end, seconds=15))
                devices = attempt('confirm-own-simulator-absent', lambda: self.inventory(self.end))
                if devices is not None:
                    absent = attempt('validate-final-inventory', lambda: self.owned_absent(devices))
                    self.report['cleanup']['createdSimulatorAbsent'] = absent
                    if not absent:
                        errors.append({'stage': 'confirm-own-simulator-absent', 'failure': 'created-simulator-remains'})
            elif self.creation_attempted:
                errors.append({'stage': 'identify-created-simulator', 'failure': 'created-simulator-not-identified'})
            else:
                self.report['cleanup']['noSimulatorCreated'] = True
        if failure is not None:
            raise failure
        require(not self.report['cleanup']['errors'] and
                self.report['cleanup'].get('keychainCleanupConfirmed') is True and
                self.report['cleanup'].get('createdSimulatorAbsent') is True,
                'experiment-cleanup-failed')
        phases = ['create', 'cleanup'] if self.fault_case is not None else list(PHASES) + ['cleanup']
        require([item['phase'] for item in self.history] == phases,
                'phase-sequence-incomplete')
        if self.fault_case is not None:
            require(self.report['expectedCreationFailure']['confirmed'] is True,
                    'expected-creation-failure-not-observed')


def save_report(path, report):
    encoded = (json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n').encode('utf-8')
    require(len(encoded) <= 1024 * 1024, 'report-size-limit')
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(encoded)
    require(path.read_bytes() == encoded, 'report-reopen-mismatch')
    return {'path': str(path), 'sha256': sha(encoded), 'bytes': len(encoded), 'passed': report['passed']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--fault-case', choices=FAULT_CASES,
                        help='Run a separate expected creation failure and cleanup experiment.')
    args = parser.parse_args()
    destination = args.report.expanduser().absolute()
    if destination.exists() or destination.is_symlink() or not destination.parent.is_dir():
        print(json.dumps({'passed': False, 'failure': 'report-path-not-fresh'}))
        return 2
    experiment_name = ('expected-creation-failure-recovery' if args.fault_case is not None
                       else 'isolated-ios-simulator-identity-lifecycle')
    report = {'schemaVersion': 1, 'experiment': experiment_name,
              'passed': False, 'utcStarted': datetime.now(timezone.utc).isoformat(), 'commands': [],
              'limits': {'totalSeconds': TOTAL_SECONDS, 'cleanupReserveSeconds': CLEANUP_RESERVE,
                         'bootSeconds': BOOT_SECONDS, 'phaseSeconds': PHASE_SECONDS,
                         'commandSeconds': COMMAND_SECONDS, 'commandStreamBytes': MAX_STREAM,
                         'installSeconds': INSTALL_SECONDS, 'inventorySeconds': INVENTORY_SECONDS,
                         'phaseReportBytes': MAX_PHASE_REPORT},
              'scopeLimits': ['ios-simulator-only', 'no-device-lock-screen-or-Secure-Enclave-evidence',
                              'no-WAN-model-account-or-mobile-mTLS', 'no-private-state-or-reference-export',
                              'app-item-deletion-and-simulator-deletion-are-separate-gates']}
    if args.fault_case is not None:
        report['expectedCreationFailure'] = fault_expectation(args.fault_case)
    old_mask = os.umask(0o077)
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def terminated(_signal, _frame):
        raise ProbeFailure('runner-terminated')

    signal.signal(signal.SIGTERM, terminated)
    try:
        app = args.app.expanduser().absolute()
        report['app'] = dict(hash_app(app), path=str(app))
        report['sourceSnapshot'] = source_snapshot(Path(__file__).resolve().parents[1])
        runner = CommandRunner(report['commands'])
        Experiment(app, report, runner, fault_case=args.fault_case).execute()
        report['passed'] = True
    except BaseException as error:
        report['failure'] = failure_code(error)
        if isinstance(error, OSError):
            report['failureErrno'] = error.errno
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        os.umask(old_mask)
        report['utcFinished'] = datetime.now(timezone.utc).isoformat()
    try:
        print(json.dumps(save_report(destination, report), sort_keys=True))
    except (OSError, ProbeFailure):
        print(json.dumps({'passed': False, 'failure': 'report-write-failed'}))
        return 2
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
