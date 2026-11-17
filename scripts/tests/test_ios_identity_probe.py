"""Offline runner regressions. Apple tools, Keychain and network never execute."""

from contextlib import redirect_stdout
from copy import deepcopy
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'probe-ios-identity.py'
SPEC = importlib.util.spec_from_file_location('ios_identity_probe', SCRIPT)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
RUN = 'D72E4630-B8B9-4864-8304-BB4A416753D4'
NONCE = '5CE1CB2C-E5AD-4F1F-B4EE-36AF801D2CC7'
OWN = 'B3EAF229-925A-48F6-A523-552430AC2D78'
EXISTING = '8C8F72D7-AF88-4FF0-9F45-F33EC797D80D'
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-2'
DEVICE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'


def frame(phase='create', run=RUN, nonce=NONCE, pid=31001):
    return {'schemaVersion': 1, 'runID': run, 'phase': phase, 'nonce': nonce,
            'launchID': probe.new_uuid(), 'processID': pid, 'passed': True,
            'checks': deepcopy(probe.CHECKS[phase])}


def runtime(number='26.2', *, available=True, devices=None):
    return {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-' + number.replace('.', '-'),
            'version': number, 'isAvailable': available,
            'supportedDeviceTypes': [DEVICE] if devices is None else devices}


def device(**changes):
    value = {'identifier': DEVICE, 'name': 'iPhone 17'}
    value.update(changes)
    return value


class PhaseTests(unittest.TestCase):
    def validate(self, value, phase='create', previous=(), pid=31001):
        return probe.validate_phase(value, RUN, phase, NONCE, previous, pid)

    def rejects(self, value, code=None, **kwargs):
        with self.assertRaises(probe.ProbeFailure) as caught:
            self.validate(value, **kwargs)
        if code is not None:
            self.assertEqual(caught.exception.code, code)

    def test_each_success_requires_every_gate_including_control_and_cleanup(self):
        for phase, checks in probe.CHECKS.items():
            with self.subTest(phase=phase):
                self.assertEqual(self.validate(frame(phase), phase=phase)['checks'], checks)
            for missing in checks:
                value = frame(phase)
                del value['checks'][missing]
                with self.subTest(phase=phase, missing=missing):
                    self.rejects(value, 'phase-success-missing-evidence', phase=phase)

    def test_every_gate_must_have_exact_value(self):
        for phase, checks in probe.CHECKS.items():
            for key, expected in checks.items():
                value = frame(phase)
                value['checks'][key] = not expected if type(expected) is bool else expected + 1
                with self.subTest(phase=phase, gate=key):
                    self.rejects(value, 'phase-success-missing-evidence', phase=phase)

    def test_boolean_is_not_integer_and_integer_is_not_boolean(self):
        for phase, key, replacement in [('delete', 'keyDeleteStatus', False),
                                         ('delete', 'keyLookupStatus', True),
                                         ('create', 'controlStillUsable', 1)]:
            value = frame(phase)
            value['checks'][key] = replacement
            self.rejects(value, 'phase-check-type', phase=phase)
        for field, replacement in [('schemaVersion', True), ('passed', 1), ('processID', True)]:
            value = frame()
            value[field] = replacement
            self.rejects(value)

    def test_stale_owner_nonce_phase_pid_and_relaunch_are_rejected(self):
        for field, replacement in [('runID', OWN), ('nonce', OWN), ('phase', 'reopen'),
                                   ('processID', 31002), ('launchID', 'not-a-uuid')]:
            value = frame()
            value[field] = replacement
            self.rejects(value)
        value = frame()
        previous = [dict(value, processID=31000)]
        self.rejects(value, 'phase-did-not-cold-relaunch', previous=previous)
        previous = [dict(value, launchID=OWN)]
        self.rejects(value, 'phase-did-not-cold-relaunch', previous=previous)

    def test_uuid_normalization_is_uppercase(self):
        value = frame(run=RUN.lower(), nonce=NONCE.lower())
        value['launchID'] = OWN.lower()
        observed = self.validate(value)
        self.assertEqual((observed['runID'], observed['nonce'], observed['launchID']), (RUN, NONCE, OWN))
        self.assertRegex(probe.new_uuid(), r'^[0-9A-F-]{36}$')

    def test_failed_frame_retains_fixed_code_but_never_claims_success(self):
        value = frame()
        value.update(passed=False, checks={}, failure='injected-after-key-add', osStatus=-25300)
        observed = self.validate(value)
        self.assertFalse(observed['passed'])
        self.assertEqual(observed['failure'], 'injected-after-key-add')
        for change in ({'failure': 'path /private/reference'}, {'osStatus': True},
                       {'osStatus': 2**31}, {'failure': ''}):
            self.rejects(dict(value, **change))
        del value['failure']
        self.rejects(value, 'phase-failed-without-code')

    def test_unknown_fields_and_private_reference_fields_are_rejected(self):
        for key in ('persistentReference', 'manifest', 'token', 'path'):
            self.rejects(dict(frame(), **{key: 'private'}), 'phase-report-schema')
        value = frame()
        value['checks']['privateReference'] = 'private'
        self.rejects(value, 'phase-checks-schema')

    def test_success_cannot_hide_failure_status(self):
        self.rejects(dict(frame(), failure='hidden-error'), 'phase-success-missing-evidence')
        self.rejects(dict(frame(), osStatus=0), 'phase-success-missing-evidence')

    def test_strict_json_rejects_duplicate_nonfinite_and_invalid_utf8(self):
        for raw in (b'{"passed":true,"passed":false}', b'{"status":NaN}', b'{"a":"\xff"}', b'[]'):
            with self.subTest(raw=raw), self.assertRaises(probe.ProbeFailure):
                probe.strict_json(raw)


class RuntimeTests(unittest.TestCase):
    def select(self, values, types=None, sdk='26.2'):
        return probe.select_runtime({'runtimes': values},
                                    {'devicetypes': [device()] if types is None else types}, sdk)

    def test_highest_available_runtime_is_bounded_by_minimum_and_selected_sdk(self):
        observed = self.select([runtime('17.5'), runtime('18.0'), runtime('26.1'),
                                runtime('26.2', available=False), runtime('27.0')])
        self.assertEqual(observed['runtimeVersion'], '26.1')
        self.assertEqual(self.select([runtime('18.0')])['runtimeVersion'], '18.0')

    def test_no_available_compatible_iphone_fails_closed(self):
        cases = [([runtime('17.5')], [device()]),
                 ([runtime('27.0')], [device()]),
                 ([runtime(available=False)], [device()]),
                 ([runtime(devices=['another-type'])], [device()]),
                 ([runtime()], [device(identifier='com.apple.CoreSimulator.SimDeviceType.iPad-Pro', name='iPad')])]
        for values, types in cases:
            with self.subTest(values=values, types=types), self.assertRaises(probe.ProbeFailure):
                self.select(values, types)

    def test_current_profile_metadata_wins_over_lexically_later_se_name(self):
        old_id = 'com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation'
        values = [runtime(devices=[old_id, DEVICE])]
        types = [device(identifier=old_id, name='iPhone SE (3rd generation)',
                        minRuntimeVersion=(15 << 16) + (4 << 8)),
                 device(minRuntimeVersion=26 << 16)]
        self.assertEqual(self.select(values, types)['deviceTypeID'], DEVICE)

    def test_listed_future_device_cannot_bypass_its_runtime_bounds(self):
        future = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17e'
        values = [runtime(devices=[future, DEVICE])]
        types = [device(identifier=future, name='iPhone 17e',
                        minRuntimeVersion=(26 << 16) + (3 << 8), maxRuntimeVersion=0xFFFFFFFF),
                 device(minRuntimeVersion=26 << 16, maxRuntimeVersion=0xFFFFFFFF)]
        self.assertEqual(self.select(values, types)['deviceTypeID'], DEVICE)

    def test_compatibility_requires_evidence_and_uses_packed_bounds(self):
        value = runtime()
        del value['supportedDeviceTypes']
        self.assertFalse(probe.compatible_device(device(), value))
        minimum = 18 << 16
        maximum = (26 << 16) + (2 << 8)
        self.assertTrue(probe.compatible_device(device(minRuntimeVersion=minimum,
                                                      maxRuntimeVersion=maximum), value))
        self.assertFalse(probe.compatible_device(device(minRuntimeVersion=minimum,
                                                       maxRuntimeVersion=maximum - 1), value))
        self.assertFalse(probe.compatible_device(device(minRuntimeVersion=False,
                                                       maxRuntimeVersion=True), value))

    def test_compatibility_accepts_official_object_list_or_string_bounds(self):
        self.assertTrue(probe.compatible_device(device(), runtime(devices=[{'identifier': DEVICE}])))
        value = runtime()
        del value['supportedDeviceTypes']
        self.assertTrue(probe.compatible_device(device(minRuntimeVersionString='18.0',
                                                      maxRuntimeVersionString='26.2'), value))

    def test_explicit_unsupported_type_never_falls_back_to_loose_bounds(self):
        self.assertFalse(probe.compatible_device(device(minRuntimeVersion=0,
                                                       maxRuntimeVersion=0xFFFFFFFF),
                                                 runtime(devices=['other-type'])))

    def test_invalid_version_or_inventory_is_rejected(self):
        for bad in ('26.2 beta', '26.2.1.3', '999.0', None, True):
            with self.subTest(value=bad), self.assertRaises(probe.ProbeFailure):
                probe.version(bad)
        with self.assertRaises(probe.ProbeFailure):
            probe.select_runtime({'runtimes': {}}, {'devicetypes': []}, '26.2')


class DiagnosticTests(unittest.TestCase):
    def progress(self):
        return {'schemaVersion': 1, 'runID': RUN, 'phase': 'create', 'nonce': NONCE,
                'processID': 31001, 'milestone': 'phase-started'}

    def test_progress_rejects_private_fields_stale_context_and_invalid_state(self):
        value = self.progress()
        self.assertEqual(probe.validate_progress(value, RUN, 'create', NONCE), value)
        for changes in ({'manifest': 'private'}, {'schemaVersion': True}, {'nonce': OWN},
                        {'runID': OWN}, {'phase': 'cleanup'}, {'processID': True},
                        {'processID': 0}, {'milestone': 'key-added'}):
            with self.subTest(changes=changes), self.assertRaises(probe.ProbeFailure):
                probe.validate_progress(dict(value, **changes), RUN, 'create', NONCE)

    def test_log_hints_never_export_messages_paths_or_other_process_lines(self):
        raw = json.dumps([
            {'process': 'SpringBoard', 'eventMessage':
             f'{probe.BUNDLE} signature invalid /private/secret token=private'},
            {'process': 'unrelated-app', 'eventMessage':
             'other-app signature invalid /private/other', 'bundle': probe.BUNDLE},
            {'process': 'MunieIdentityResearch', 'eventMessage': 'startup failed token=private'},
        ]).encode()
        self.assertEqual(probe.log_hints(raw), {'matchingLines': 2,
                         'signatureRejectionHintLines': 1, 'launchFailureHintLines': 1,
                         'frontBoardRejectionHintLines': 0, 'errorDomains': []})

    def test_frontboard_and_nested_error_domains_keep_only_signed_numeric_codes(self):
        raw = json.dumps([
            {'process': 'SpringBoard', 'eventMessage':
             f'{probe.BUNDLE} request denied by SBMainWorkspace '
             '(domain=FBSOpenApplicationServiceErrorDomain, code=1); '
             'Error Domain=RBSRequestErrorDomain Code=-5 "private detail" '
             'NSUnderlyingError=Error Domain=NSPOSIXErrorDomain Code=13 /private/token'},
            {'process': 'MunieIdentityResearch', 'eventMessage':
             'Error Domain=NSOSStatusErrorDomain Code=-2147483648 '
             'Error Domain=NSOSStatusErrorDomain Code=2147483647 '
             'Error Domain=NSOSStatusErrorDomain Code=-2147483649 '
             'Error Domain=NSOSStatusErrorDomain Code=2147483648 '
             'Error Domain=PrivateTokenDomain Code=42'},
            {'process': 'unrelated-app', 'eventMessage':
             'Error Domain=NSPOSIXErrorDomain Code=99', 'privateMetadata': probe.BUNDLE},
        ]).encode()
        result = probe.log_hints(raw)
        domains = {item['domain']: item['codes'] for item in result['errorDomains']}
        self.assertEqual(domains, {'FBSOpenApplicationServiceErrorDomain': [1],
                                  'RBSRequestErrorDomain': [-5], 'NSPOSIXErrorDomain': [13],
                                  'NSOSStatusErrorDomain': [-(2**31), 2**31 - 1]})
        self.assertEqual(result['matchingLines'], 2)
        self.assertEqual(result['frontBoardRejectionHintLines'], 1)
        self.assertEqual(set(result), {'matchingLines', 'signatureRejectionHintLines',
                                     'launchFailureHintLines', 'frontBoardRejectionHintLines',
                                     'errorDomains'})
        encoded = json.dumps(result)
        for private in ('private detail', '/private/', 'PrivateTokenDomain', 'NSUnderlyingError'):
            self.assertNotIn(private, encoded)

    def test_error_domain_allowlist_deduplicates_and_bounds_each_sorted_code_list(self):
        allowed = ('FBSOpenApplicationServiceErrorDomain', 'FBProcessExit',
                   'FBApplicationInfoErrorDomain', 'RBSRequestErrorDomain',
                   'RBSAssertionErrorDomain', 'NSPOSIXErrorDomain', 'NSOSStatusErrorDomain',
                   'NSCocoaErrorDomain', 'LSApplicationWorkspaceErrorDomain',
                   'MIInstallerErrorDomain', 'IXUserPresentableErrorDomain')
        records = [{'process': 'MunieIdentityResearch',
                    'eventMessage': f'Error Domain={domain} Code=-7 Error Domain={domain} Code=-7'}
                   for domain in allowed]
        records.extend({'process': 'MunieIdentityResearch',
                        'eventMessage': f'Error Domain=NSPOSIXErrorDomain Code={code}'}
                       for code in (12, 3, -4, 18, 8, 1, 2, 9, 7, 5, 4))
        result = probe.log_hints(json.dumps(records).encode())
        domains = {item['domain']: item['codes'] for item in result['errorDomains']}
        self.assertEqual(set(domains), set(allowed))
        for domain, codes in domains.items():
            self.assertEqual(codes, sorted(set(codes)))
            self.assertLessEqual(len(codes), 8)
            self.assertTrue(all(type(code) is int for code in codes))
            if domain != 'NSPOSIXErrorDomain':
                self.assertEqual(codes, [-7])
        self.assertEqual(len(domains['NSPOSIXErrorDomain']), 8)
        self.assertTrue(set(domains['NSPOSIXErrorDomain']) <= {-7, 12, 3, -4, 18, 8, 1, 2, 9, 7, 5, 4})

    def test_only_message_and_supported_process_identity_fields_correlate_log_records(self):
        raw = json.dumps([
            {'process': 'other-app', 'eventMessage': 'ordinary text',
             'bundleID': probe.BUNDLE,
             'metadata': 'Error Domain=NSPOSIXErrorDomain Code=77'},
            {'process': 'MunieIdentityResearch', 'eventMessage': 'ordinary text',
             'metadata': 'Error Domain=NSPOSIXErrorDomain Code=88'},
            {'processImagePath': '/private/fixture/MunieIdentityResearch',
             'eventMessage': 'ordinary text'},
            {'processImagePath': '/private/fixture/OtherProcess', 'process': 'MunieIdentityResearch',
             'eventMessage': 'Error Domain=NSPOSIXErrorDomain Code=99'},
        ]).encode()
        result = probe.log_hints(raw)
        self.assertEqual(result['matchingLines'], 2)
        self.assertEqual(result['errorDomains'], [])
        self.assertNotIn('/private/', json.dumps(result))

    def test_malformed_or_oversized_json_logs_fail_without_exposing_raw_text(self):
        invalid = (b'private malformed text', b'\xff', b'{"eventMessage":"private"}',
                   b'[', b'["private record"]', json.dumps([{}] * 2049).encode(),
                   b'[{"process":false}]', b'[{"eventMessage":2}]',
                   b'[{"eventMessage":"first","eventMessage":"private"}]',
                   b'[{"eventMessage":NaN}]')
        for raw in invalid:
            with self.subTest(size=len(raw)), self.assertRaises(probe.ProbeFailure) as caught:
                probe.log_hints(raw)
            self.assertEqual(caught.exception.code, 'diagnostic-log-schema')
            self.assertEqual(str(caught.exception), 'diagnostic-log-schema')

    def test_empty_and_exactly_bounded_log_lists_are_valid(self):
        for records in ([], [{'process': 'other-app', 'eventMessage': 'unrelated'}] * 2048):
            with self.subTest(count=len(records)):
                result = probe.log_hints(json.dumps(records).encode())
                self.assertEqual(result['matchingLines'], 0)
                self.assertEqual(result['errorDomains'], [])

    def test_noninteger_code_tokens_never_become_numeric_error_evidence(self):
        for token in ('1.5', '-2.5', '1e3', '7private', 'true', '9_000'):
            with self.subTest(token=token):
                raw = json.dumps([{'process': 'MunieIdentityResearch',
                                   'eventMessage': f'Error Domain=NSPOSIXErrorDomain Code={token}'}]).encode()
                self.assertEqual(probe.log_hints(raw)['errorDomains'], [])


class CommandTests(unittest.TestCase):
    def test_unclean_timeout_is_not_reported_as_retryable_timeout(self):
        records = []
        runner = probe.CommandRunner(records)
        with patch.object(probe, 'group_gone', return_value=False):
            with self.assertRaisesRegex(probe.ProbeFailure, 'command-cleanup-failed'):
                runner.run('synthetic-unclean', [sys.executable, '-c', 'import time;time.sleep(30)'],
                           time.monotonic() + 4, seconds=.05)
        self.assertEqual(records[0]['priorFailure'], 'command-timeout')
        self.assertEqual(records[0]['failure'], 'command-cleanup-failed')
        self.assertFalse(records[0]['processGroupGone'])

    def run_python(self, code, *, seconds=2, private=False):
        self.records = []
        runner = probe.CommandRunner(self.records)
        return runner.run('offline-python', [sys.executable, '-c', code],
                          time.monotonic() + 10, seconds, private=private)

    def test_literal_streams_status_hash_and_eof_are_recorded(self):
        output, errors, status = self.run_python(
            "import sys; print('observed stdout'); print('observed stderr', file=sys.stderr)")
        record = self.records[0]
        self.assertEqual((output, errors, status), (b'observed stdout\n', b'observed stderr\n', 0))
        self.assertEqual(record['stdout'], output.decode())
        self.assertEqual(record['stderrSHA256'], probe.sha(errors))
        self.assertTrue(record['streamsReachedEOF'])
        self.assertTrue(record['processGroupGone'])

    def test_nonzero_exit_and_silent_timeout_retain_diagnostics(self):
        with self.assertRaises(probe.ProbeFailure) as caught:
            self.run_python("import sys; print('failure stderr', file=sys.stderr); sys.exit(7)")
        self.assertEqual(caught.exception.code, 'command-exit-offline-python')
        self.assertEqual(self.records[0]['exitStatus'], 7)
        self.assertEqual(self.records[0]['stderr'], 'failure stderr\n')
        started = time.monotonic()
        with self.assertRaises(probe.ProbeFailure) as caught:
            self.run_python('import time; time.sleep(20)', seconds=.15)
        self.assertEqual(caught.exception.code, 'command-timeout')
        self.assertLess(time.monotonic() - started, 4)
        self.assertTrue(self.records[0]['processGroupGone'])
        self.assertTrue(self.records[0]['streamsReachedEOF'])

    def test_each_stream_flood_is_bounded_and_group_is_cleaned(self):
        for descriptor in (1, 2):
            with self.subTest(descriptor=descriptor):
                code = f'import os; os.write({descriptor}, b"x" * {probe.MAX_STREAM + 32768})'
                with self.assertRaises(probe.ProbeFailure) as caught:
                    self.run_python(code)
                self.assertEqual(caught.exception.code, 'command-output-limit')
                record = self.records[0]
                name = 'stdout' if descriptor == 1 else 'stderr'
                self.assertLessEqual(len(record[name]), probe.MAX_DIAGNOSTIC)
                self.assertTrue(record[name + 'Truncated'])
                self.assertTrue(record['processGroupGone'])
                self.assertTrue(record['streamsReachedEOF'])

    def test_descendant_holding_pipes_is_bounded_after_leader_exit(self):
        # Only harmless Python subprocesses; no simctl, keychain or network.
        child = 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(20)'
        code = 'import subprocess,sys; subprocess.Popen([sys.executable,"-c",' + repr(child) + '])'
        started = time.monotonic()
        with self.assertRaises(probe.ProbeFailure) as caught:
            self.run_python(code, seconds=.2)
        self.assertEqual(caught.exception.code, 'command-timeout')
        self.assertLess(time.monotonic() - started, 4)
        self.assertTrue(self.records[0]['escalated'])
        self.assertTrue(self.records[0]['streamsReachedEOF'])
        self.assertTrue(self.records[0]['processGroupGone'])

    def test_private_inventory_never_exports_unrelated_device_names(self):
        output, _, _ = self.run_python("print('Personal device; /private/container/reference')", private=True)
        record = self.records[0]
        self.assertIn(b'Personal device', output)
        self.assertNotIn('stdout', record)
        self.assertNotIn('stderr', record)
        self.assertEqual(record['stdoutSHA256'], probe.sha(output))
        self.assertEqual(record['stdoutBytes'], len(output))

    def test_expired_budget_does_not_spawn(self):
        records = []
        with patch.object(probe.subprocess, 'Popen') as spawn, self.assertRaises(probe.ProbeFailure):
            probe.CommandRunner(records).run('expired', ['unused'], time.monotonic() - 1)
        spawn.assert_not_called()


class FileTests(unittest.TestCase):
    def make_app(self, root):
        app = root / 'Research.app'
        app.mkdir()
        info = {'CFBundleIdentifier': probe.BUNDLE, 'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
                'MinimumOSVersion': '18.0', 'CFBundleExecutable': 'Research'}
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Research').write_bytes(b'harmless-offline-app-fixture')
        return app, info

    def test_app_hash_covers_all_files_and_exact_research_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            app, _ = self.make_app(Path(directory))
            original = probe.hash_app(app)
            (app / 'Research').write_bytes(b'changed')
            self.assertNotEqual(probe.hash_app(app)['sha256'], original['sha256'])
            self.assertEqual(original['files'], 2)
            self.assertEqual(original['minimumOS'], '18.0')

    def test_app_preflight_rejects_shipping_bundle_platform_minimum_or_symlink(self):
        cases = [{'CFBundleIdentifier': 'app.munie.shipping'},
                 {'CFBundleSupportedPlatforms': ['iPhoneOS']},
                 {'CFBundleSupportedPlatforms': 'iPhoneSimulator'},
                 {'MinimumOSVersion': '17.0'}, {'CFBundleExecutable': '../outside'}]
        for change in cases:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                app, info = self.make_app(Path(directory))
                (app / 'Info.plist').write_bytes(plistlib.dumps(dict(info, **change)))
                with self.assertRaises(probe.ProbeFailure):
                    probe.hash_app(app)
        with tempfile.TemporaryDirectory() as directory:
            app, _ = self.make_app(Path(directory))
            (app / 'reference').symlink_to(app / 'Research')
            with self.assertRaises(probe.ProbeFailure):
                probe.hash_app(app)

    def test_fixed_report_rejects_symlinks_oversize_and_duplicate_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = probe.phase_report_path(root)
            path.parent.mkdir(parents=True)
            path.write_bytes(json.dumps(frame()).encode())
            self.assertEqual(probe.read_phase_file(path)['phase'], 'create')
            path.write_bytes(b'x' * (probe.MAX_PHASE_REPORT + 1))
            with self.assertRaises(probe.ProbeFailure):
                probe.read_phase_file(path)
            path.unlink()
            path.symlink_to(root / 'private-manifest')
            with self.assertRaises(probe.ProbeFailure):
                probe.phase_report_path(root)

    def test_fifo_report_is_rejected_without_waiting_for_a_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            os.mkfifo(path)
            started = time.monotonic()
            with self.assertRaises(probe.ProbeFailure) as caught:
                probe.read_phase_file(path)
            self.assertEqual(caught.exception.code, 'phase-report-file-limit')
            self.assertLess(time.monotonic() - started, .5)

    def test_source_snapshot_covers_helper_and_ownership_checks_and_enforces_license_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = root / 'scripts/fixtures/device-identity-ios'
            (fixture / 'App').mkdir(parents=True)
            (fixture / 'Tests').mkdir()
            (fixture / 'Tests/OwnershipChecks.swift').write_text('// offline fixture\n')
            (fixture / 'Simulator.entitlements').write_bytes(plistlib.dumps({
                'application-identifier': probe.BUNDLE, 'keychain-access-groups': [probe.BUNDLE]}))
            for name in ('A', 'B', 'C'):
                (fixture / 'App' / (name + '.swift')).write_text('// offline fixture\n')
            (root / 'scripts/build-ios-identity-probe.sh').write_text('#!/bin/sh\nexit 0\n')
            (fixture / 'project.yml').write_text("  deploymentTarget:\n    iOS: '18.0'\n")
            csr = root / 'scripts/fixtures/device-identity/Sources/MunieDeviceIdentityProbe/CSR.swift'
            csr.parent.mkdir(parents=True)
            csr.write_text('// shared source fixture\n')
            pins = [{'identity': name, 'location': 'https://example.invalid/' + name,
                     'state': {'revision': name * 40}} for name in ('a', 'b', 'c')]
            (fixture / 'Package.resolved').write_text(json.dumps({'pins': pins}))
            license_path = root / 'references/licenses/device-identity/manifest.json'
            license_path.parent.mkdir(parents=True)
            packages = [{'identity': item['identity'], 'repository': item['location'],
                         'revision': item['state']['revision']} for item in pins]
            license_path.write_text(json.dumps({'packages': packages}))
            observed = probe.source_snapshot(root)
            paths = [item['path'] for item in observed['files']]
            self.assertIn(str(fixture / 'Tests/OwnershipChecks.swift'), paths)
            self.assertIn(str(root / 'scripts/build-ios-identity-probe.sh'), paths)
            self.assertIn(str(fixture / 'Simulator.entitlements'), paths)
            self.assertEqual(len(paths), 10)
            pins[0]['state']['revision'] = 'unreviewed-revision'
            (fixture / 'Package.resolved').write_text(json.dumps({'pins': pins}))
            with self.assertRaises(probe.ProbeFailure) as caught:
                probe.source_snapshot(root)
            self.assertEqual(caught.exception.code, 'research-lock-not-reviewed')

    def test_report_is_exclusive_reopened_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            result = probe.save_report(path, {'passed': False, 'failure': 'fixture'})
            self.assertEqual(result['sha256'], probe.sha(path.read_bytes()))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                probe.save_report(path, {'passed': True})
            self.assertEqual(path.read_bytes(), original)

    def test_existing_report_or_dangling_symlink_prevents_any_execution(self):
        for link in (False, True):
            with self.subTest(link=link), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                report = root / 'report.json'
                report.symlink_to(root / 'missing') if link else report.write_bytes(b'historical-evidence')
                with patch.object(sys, 'argv', ['probe', '--app', str(root / 'unused.app'),
                                               '--report', str(report)]), \
                        patch.object(probe, 'hash_app') as preflight, \
                        patch.object(probe.Experiment, 'execute') as execute, redirect_stdout(io.StringIO()):
                    self.assertEqual(probe.main(), 2)
                preflight.assert_not_called()
                execute.assert_not_called()
                if not link:
                    self.assertEqual(report.read_bytes(), b'historical-evidence')


class FakeTools:
    """Model only the isolated simulator and fixed app report, never Apple tools."""

    def __init__(self, root, *, fail_stage=None, fail_phase=None, retain_simulator=False,
                 cleanup_bad=False, uncertain_create=False, wrong_owner=False, stale_frame=False,
                 fault_changes=None):
        self.root = root
        self.fail_stage, self.fail_phase = fail_stage, fail_phase
        self.retain_simulator, self.cleanup_bad = retain_simulator, cleanup_bad
        self.uncertain_create, self.wrong_owner = uncertain_create, wrong_owner
        self.stale_frame = stale_frame
        self.fault_changes = fault_changes
        self.calls = []
        self.created = False
        self.state = 'Shutdown'
        self.name = None
        self.pid = 41000
        self.path = root.joinpath(*probe.REPORT_PARTS)
        self.path.parent.mkdir(parents=True)
        self.path.write_text('{"stale":"must-be-removed-before-first-launch"}')
        # Private app state is deliberately unreadable and must never be opened.
        (self.path.parent / 'manifest.json').symlink_to(root / 'must-never-read')

    def run(self, stage, command, deadline, seconds, *, allowed=(0,), private=False):
        self.calls.append({'stage': stage, 'argv': command, 'deadline': deadline,
                           'seconds': seconds, 'allowed': allowed, 'private': private})
        if stage == self.fail_stage:
            raise probe.ProbeFailure('fixture-' + stage)
        if stage == 'xcode-version':
            return b'Xcode 26.2\nBuild version fixture\n', b'', 0
        if stage == 'simulator-sdk':
            return b'26.2\n', b'', 0
        if stage == 'available-runtimes':
            return json.dumps({'runtimes': [runtime()]}).encode(), b'', 0
        if stage == 'device-types':
            return json.dumps({'devicetypes': [device()]}).encode(), b'', 0
        if stage == 'simulator-create':
            self.created, self.name = True, command[3]
            if self.uncertain_create:
                raise probe.ProbeFailure('fixture-create-output-lost')
            return ((EXISTING if self.wrong_owner else OWN) + '\n').encode(), b'', 0
        if stage == 'own-simulator-inventory':
            items = [{'udid': EXISTING, 'name': 'Personal device', 'state': 'Booted'}]
            if self.created:
                items.append({'udid': OWN, 'name': self.name, 'state': self.state})
            return json.dumps({'devices': {RUNTIME: items}}).encode(), b'', 0
        if stage == 'simulator-boot':
            self.state = 'Booted'
        elif stage == 'app-container':
            return (str(self.root) + '\n').encode(), b'', 0
        elif stage == 'app-terminate':
            return b'', b'found nothing to terminate\n', 3
        elif stage.startswith('app-launch-'):
            assert not self.path.exists(), 'runner must remove only the previous fixed report'
            phase = command[command.index('--phase') + 1]
            run = command[command.index('--run-id') + 1]
            nonce = command[command.index('--nonce') + 1]
            self.pid += 1
            value = frame(phase, run, nonce, self.pid)
            if '--fault' in command:
                assert phase == 'create', 'fault must never reach cleanup or normal phases'
                hook = command[command.index('--fault') + 1]
                value.update(passed=False, checks={}, failure='injected-' + hook)
                for key, item in (self.fault_changes or {}).items():
                    if item is None:
                        value.pop(key, None)
                    else:
                        value[key] = deepcopy(item)
            if phase == self.fail_phase:
                value.update(passed=False, checks={}, failure='fixture-phase-failed')
            if phase == 'cleanup' and self.cleanup_bad:
                value['checks']['cleanupOwnItems'] = False
            if self.stale_frame:
                value['nonce'] = NONCE
            self.path.write_text(json.dumps(value))
            return f'{probe.BUNDLE}: {self.pid}\n'.encode(), b'', 0
        elif stage == 'simulator-shutdown':
            self.state = 'Shutdown'
        elif stage == 'simulator-delete' and not self.retain_simulator:
            self.created = False
        elif stage == 'diagnostic-app-logs':
            return b'[]', b'', 0
        return b'', b'', 0


class DiagnosticFixtureTools:
    """Bounded, inspectable responses for direct diagnostics; never Apple tools."""

    def __init__(self, *, inventory=None, inventory_error=None, log_error=None, logs=None):
        self.calls = []
        self.inventory_error, self.log_error = inventory_error, log_error
        self.inventory = {'devices': {RUNTIME: [{'udid': OWN,
                          'name': 'MunieIdentityResearch-' + RUN, 'state': 'Booted'}]}}
        if inventory is not None:
            self.inventory = inventory
        self.logs = [] if logs is None else logs

    def run(self, stage, command, deadline, seconds, **options):
        self.calls.append({'stage': stage, 'argv': command, 'deadline': deadline,
                           'seconds': seconds, **options})
        if stage == 'diagnostic-owned-inventory':
            if self.inventory_error is not None:
                raise probe.ProbeFailure(self.inventory_error)
            return json.dumps(self.inventory).encode(), b'', 0
        if stage == 'diagnostic-app-logs':
            if self.log_error is not None:
                raise probe.ProbeFailure(self.log_error)
            return json.dumps(self.logs).encode(), b'', 0
        if stage == 'diagnostic-launchd':
            return f'41001 0 UIKitApplication:{probe.BUNDLE}\n'.encode(), b'', 0
        raise AssertionError('unexpected offline diagnostic stage: ' + stage)


class ExperimentTests(unittest.TestCase):
    def diagnostic_experiment(self, tools, root=Path('/unused')):
        report = {}
        experiment = probe.Experiment(root, report, tools, RUN)
        experiment.simulator, experiment.ownership_verified = OWN, True
        experiment.selection = {'runtimeID': RUNTIME}
        experiment.owned_identity = (OWN, experiment.name, RUNTIME, RUN)
        return experiment, report

    def test_diagnostic_skips_when_process_cleanup_margin_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = FakeTools(Path(directory))
            experiment, report = self.diagnostic_experiment(tools, Path(directory))
            experiment.work_end = time.monotonic() + 2
            experiment.diagnose_failure()
            self.assertEqual(report['failureDiagnostics']['skipped'], 'insufficient-work-budget')
            self.assertEqual(tools.calls, [])

    def test_timed_out_diagnostic_reaps_real_term_resistant_child_before_cleanup_reserve(self):
        records = []
        command_runner = probe.CommandRunner(records)
        name = 'MunieIdentityResearch-' + RUN

        class DiagnosticTools:
            def run(self, stage, command, deadline, seconds, **kwargs):
                if stage == 'diagnostic-owned-inventory':
                    return json.dumps({'devices': {RUNTIME: [
                        {'udid': OWN, 'name': name, 'state': 'Booted'}]}}).encode(), b'', 0
                return command_runner.run(stage, [sys.executable, '-c',
                    'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'],
                    deadline, seconds, **kwargs)

        report = {}
        experiment = probe.Experiment(Path('/unused'), report, DiagnosticTools(), RUN)
        experiment.simulator, experiment.ownership_verified = OWN, True
        experiment.selection = {'runtimeID': RUNTIME}
        experiment.owned_identity = (OWN, experiment.name, RUNTIME, RUN)
        experiment.work_end = time.monotonic() + 5
        experiment.diagnose_failure()
        self.assertLess(time.monotonic(), experiment.work_end)
        self.assertTrue(records[0]['escalated'])
        self.assertTrue(records[0]['processGroupGone'])
        self.assertTrue(records[0]['streamsReachedEOF'])
        self.assertEqual(records[0]['failure'], 'command-timeout')
        self.assertFalse(report['failureDiagnostics']['acceptedAsLifecycleEvidence'])

    def test_launch_timeout_can_have_unaccepted_report_and_progress_without_passing(self):
        class TimedOutTools(FakeTools):
            def run(self, stage, *args, **kwargs):
                result = super().run(stage, *args, **kwargs)
                if stage == 'app-launch-create':
                    value = json.loads(self.path.read_bytes())
                    progress = {key: value[key] for key in
                                ('schemaVersion', 'runID', 'phase', 'nonce', 'processID')}
                    progress['milestone'] = 'report-saved'
                    self.path.with_name('progress.json').write_text(json.dumps(progress))
                    raise probe.ProbeFailure('command-timeout')
                if stage == 'diagnostic-owned-inventory':
                    return json.dumps({'devices': {RUNTIME: [
                        {'udid': OWN, 'name': self.name, 'state': self.state}]}}).encode(), b'', 0
                if stage == 'diagnostic-launchd':
                    return f'41001 0 UIKitApplication:{probe.BUNDLE}\n'.encode(), b'', 0
                if stage == 'diagnostic-app-logs':
                    return json.dumps([{'process': 'MunieIdentityResearch', 'eventMessage':
                                        f'{probe.BUNDLE} signature invalid private-text'}]).encode(), b'', 0
                return result

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools, report = TimedOutTools(root), {}
            experiment = probe.Experiment(root / 'Research.app', report, tools, RUN)
            with self.assertRaisesRegex(probe.ProbeFailure, 'command-timeout'):
                experiment.execute()
            diagnostic = report['failureDiagnostics']
            self.assertFalse(diagnostic['acceptedAsLifecycleEvidence'])
            self.assertTrue(diagnostic['unacceptedPhaseReport']['passed'])
            self.assertEqual(diagnostic['progress']['milestone'], 'report-saved')
            self.assertTrue(diagnostic['launchd']['researchAppJobPresent'])
            self.assertEqual(diagnostic['appLogHints']['signatureRejectionHintLines'], 1)
            self.assertEqual(diagnostic['phaseContext']['phase'], 'create')
            self.assertEqual(diagnostic['phaseContext']['nonce'], diagnostic['progress']['nonce'])
            self.assertEqual(experiment.phase_context['phase'], 'cleanup')
            self.assertNotEqual(diagnostic['phaseContext']['nonce'], experiment.phase_context['nonce'])
            self.assertEqual([item['phase'] for item in report['phases']], ['cleanup'])
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
            calls = [call for call in tools.calls if call['stage'].startswith('diagnostic-')]
            self.assertEqual([call['stage'] for call in calls],
                             ['diagnostic-owned-inventory', 'diagnostic-app-logs', 'diagnostic-launchd'])
            self.assertEqual(len({call['deadline'] for call in calls}), 1)
            for call in calls:
                self.assertTrue(call['private'])
                self.assertLessEqual(call['deadline'], experiment.work_end)
                self.assertLessEqual(call['seconds'], 10)
                if 'spawn' in call['argv']:
                    self.assertEqual(call['argv'][3], OWN)

    def test_clean_diagnostic_inventory_timeout_continues_logs_first_without_masking_failure(self):
        experiment, report, tools, failure = self.exercise_diagnostic_failure('command-timeout')
        self.assertEqual(failure, 'fixture-app-launch-create')
        self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
        diagnostic = report['failureDiagnostics']
        self.assertEqual(diagnostic['ownedState'], 'unknown')
        self.assertTrue(diagnostic['usingInitiallyVerifiedSimulator'])
        self.assertFalse(diagnostic['acceptedAsLifecycleEvidence'])
        calls = [call for call in tools.calls if call['stage'].startswith('diagnostic-')]
        self.assertEqual([call['stage'] for call in calls],
                         ['diagnostic-owned-inventory', 'diagnostic-app-logs', 'diagnostic-launchd'])
        self.assertEqual(len({call['deadline'] for call in calls}), 1)
        self.assertTrue(all(call['private'] for call in calls))
        for call in calls[1:]:
            self.assertEqual(call['argv'][3], experiment.owned_identity[0])
            self.assertNotIn(EXISTING, call['argv'])

    def exercise_diagnostic_failure(self, code):
        class FailedDiagnostic(FakeTools):
            def run(self, stage, command, deadline, seconds, **kwargs):
                if stage == 'diagnostic-owned-inventory':
                    self.calls.append({'stage': stage, 'argv': command, 'deadline': deadline,
                                       'seconds': seconds, **kwargs})
                    raise probe.ProbeFailure(code)
                return super().run(stage, command, deadline, seconds, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = FailedDiagnostic(root, fail_stage='app-launch-create')
            report = {}
            experiment = probe.Experiment(root / 'Research.app', report, tools, RUN)
            failure = None
            try:
                experiment.execute()
            except probe.ProbeFailure as error:
                failure = error.code
            return experiment, report, tools, failure

    def test_diagnostic_hard_inventory_failures_absence_mismatch_and_nonbooted_stop(self):
        own_entry = {'udid': OWN, 'name': 'MunieIdentityResearch-' + RUN, 'state': 'Booted'}
        cases = [
            ('unclean-timeout', {'inventory_error': 'command-cleanup-failed'}),
            ('output-overflow', {'inventory_error': 'command-output-limit'}),
            ('tool-exit', {'inventory_error': 'command-exit-diagnostic-owned-inventory'}),
            ('invalid-schema', {'inventory': {'devices': []}}),
            ('absent', {'inventory': {'devices': {RUNTIME: []}}}),
            ('wrong-name', {'inventory': {'devices': {RUNTIME: [dict(own_entry, name='other-owner')]}}}),
            ('wrong-runtime', {'inventory': {'devices': {'other-runtime': [own_entry]}}}),
            ('shutdown', {'inventory': {'devices': {RUNTIME: [dict(own_entry, state='Shutdown')]}}}),
            ('unknown-state', {'inventory': {'devices': {RUNTIME: [dict(own_entry, state='unknown')]}}}),
        ]
        for name, options in cases:
            with self.subTest(case=name):
                tools = DiagnosticFixtureTools(**options)
                experiment, report = self.diagnostic_experiment(tools)
                experiment.diagnose_failure()
                self.assertEqual([call['stage'] for call in tools.calls], ['diagnostic-owned-inventory'])
                diagnostic = report['failureDiagnostics']
                self.assertNotIn('usingInitiallyVerifiedSimulator', diagnostic)
                self.assertNotIn('appLogHints', diagnostic)
                self.assertNotIn('launchd', diagnostic)
                self.assertFalse(diagnostic['acceptedAsLifecycleEvidence'])
                self.assertEqual(experiment.history, [])
                if name not in ('shutdown', 'unknown-state'):
                    self.assertEqual(diagnostic['errors'][0]['stage'], 'ownedState')

    def test_unclean_log_command_stops_launchd_but_clean_errors_can_continue(self):
        for code in ('command-cleanup-failed', 'command-timeout', 'diagnostic-log-schema'):
            with self.subTest(code=code):
                tools = DiagnosticFixtureTools(inventory_error='command-timeout', log_error=code)
                experiment, report = self.diagnostic_experiment(tools)
                experiment.diagnose_failure()
                expected = ['diagnostic-owned-inventory', 'diagnostic-app-logs']
                if code != 'command-cleanup-failed':
                    expected.append('diagnostic-launchd')
                self.assertEqual([call['stage'] for call in tools.calls], expected)
                diagnostic = report['failureDiagnostics']
                self.assertIn({'stage': 'appLogHints', 'failure': code}, diagnostic['errors'])
                self.assertEqual(diagnostic['ownedState'], 'unknown')
                self.assertEqual(experiment.history, [])
                self.assertEqual(report['phases'], [])

    def test_invalid_structured_logs_remain_private_and_do_not_hide_launchd_state(self):
        tools = DiagnosticFixtureTools(logs={'private': '/private/account/token'})
        experiment, report = self.diagnostic_experiment(tools)
        experiment.diagnose_failure()
        self.assertEqual([call['stage'] for call in tools.calls],
                         ['diagnostic-owned-inventory', 'diagnostic-app-logs', 'diagnostic-launchd'])
        diagnostic = report['failureDiagnostics']
        self.assertIn({'stage': 'appLogHints', 'failure': 'diagnostic-log-schema'}, diagnostic['errors'])
        self.assertTrue(diagnostic['launchd']['researchAppJobPresent'])
        self.assertNotIn('/private/', json.dumps(diagnostic))
        self.assertTrue(all(call['private'] for call in tools.calls))
        log_call = tools.calls[1]
        self.assertEqual(log_call['argv'][log_call['argv'].index('--style') + 1], 'json')
        self.assertEqual(log_call['argv'][3], OWN)

    def test_owned_identity_is_claimed_once_and_repeated_lookup_preserves_the_lock(self):
        tools = DiagnosticFixtureTools()
        experiment = probe.Experiment(Path('/unused'), {}, tools, RUN)
        self.assertIsNone(experiment.owned_identity)
        experiment.simulator = OWN
        experiment.selection = {'runtimeID': RUNTIME}
        first = experiment.find_owned(tools.inventory['devices'])
        expected = (OWN, experiment.name, RUNTIME, RUN)
        self.assertEqual(experiment.owned_identity, expected)
        self.assertTrue(experiment.ownership_verified)
        self.assertEqual(experiment.find_owned(deepcopy(tools.inventory['devices'])), first)
        self.assertEqual(experiment.owned_identity, expected)

    def test_later_lookup_cannot_replace_any_part_of_the_owned_identity(self):
        for changed in ('simulator', 'name', 'runtime', 'run_id'):
            with self.subTest(changed=changed):
                tools = DiagnosticFixtureTools()
                experiment, _ = self.diagnostic_experiment(tools)
                original = experiment.owned_identity
                if changed == 'simulator':
                    experiment.simulator = EXISTING
                elif changed == 'name':
                    experiment.name += '-replacement'
                elif changed == 'runtime':
                    experiment.selection = {'runtimeID': 'replacement-runtime'}
                else:
                    experiment.run_id = NONCE
                devices = {experiment.selection['runtimeID']: [
                    {'udid': experiment.simulator, 'name': experiment.name, 'state': 'Booted'}]}
                with self.assertRaises(probe.ProbeFailure) as caught:
                    experiment.find_owned(devices)
                self.assertEqual(caught.exception.code, 'created-simulator-identity-changed')
                self.assertEqual(experiment.owned_identity, original)
                self.assertEqual(tools.calls, [])

    def test_diagnostics_require_the_original_identity_lock_before_any_tool_or_file_read(self):
        for changed in ('simulator', 'name', 'runtime', 'run_id', 'missing-lock'):
            with self.subTest(changed=changed):
                tools = DiagnosticFixtureTools()
                experiment, _ = self.diagnostic_experiment(tools)
                if changed == 'simulator':
                    experiment.simulator = EXISTING
                elif changed == 'name':
                    experiment.name += '-replacement'
                elif changed == 'runtime':
                    experiment.selection = {'runtimeID': 'replacement-runtime'}
                elif changed == 'run_id':
                    experiment.run_id = NONCE
                else:
                    experiment.owned_identity = None
                with patch.object(probe, 'read_phase_file') as read, self.assertRaises(probe.ProbeFailure) as caught:
                    experiment.diagnose_failure()
                self.assertEqual(caught.exception.code, 'diagnostic-simulator-identity-changed')
                read.assert_not_called()
                self.assertEqual(tools.calls, [])

    def test_diagnostic_phase_context_is_a_copy_and_never_counts_as_lifecycle_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            tools = DiagnosticFixtureTools()
            root = Path(directory)
            experiment, report = self.diagnostic_experiment(tools, root)
            context = {'phase': 'create', 'nonce': NONCE}
            experiment.phase_context = context
            experiment.container = root
            experiment.diagnose_failure()
            context.update(phase='cleanup', nonce=OWN)
            self.assertEqual(report['failureDiagnostics']['phaseContext'],
                             {'phase': 'create', 'nonce': NONCE})
            self.assertIsNot(report['failureDiagnostics']['phaseContext'], context)
            self.assertFalse(report['failureDiagnostics']['acceptedAsLifecycleEvidence'])
            self.assertEqual(report['phases'], [])
            self.assertEqual(experiment.history, [])

    def test_unknown_state_commands_share_one_original_deadline_and_leave_cleanup_margin(self):
        for remaining, expected_deadline in ((100, 127), (18, 115)):
            with self.subTest(remaining=remaining):
                tools = DiagnosticFixtureTools(inventory_error='command-timeout')
                experiment, report = self.diagnostic_experiment(tools)
                experiment.work_end = 100 + remaining
                now = {'value': 100}
                original = tools.run

                def advancing_tool(*args, **kwargs):
                    try:
                        return original(*args, **kwargs)
                    finally:
                        now['value'] += 4

                with patch.object(probe.time, 'monotonic', side_effect=lambda: now['value']), \
                        patch.object(tools, 'run', side_effect=advancing_tool):
                    experiment.diagnose_failure()
                self.assertEqual([call['stage'] for call in tools.calls],
                                 ['diagnostic-owned-inventory', 'diagnostic-app-logs', 'diagnostic-launchd'])
                self.assertEqual({call['deadline'] for call in tools.calls}, {expected_deadline})
                self.assertTrue(all(call['deadline'] <= experiment.work_end - 3 for call in tools.calls))
                self.assertEqual([call['seconds'] for call in tools.calls], [5, 10, 10])

    def test_diagnostic_interruptions_stop_reads_preserve_original_failure_and_finish_cleanup(self):
        for interrupt in ('KeyboardInterrupt', 'runner-terminated'):
            with self.subTest(interrupt=interrupt), tempfile.TemporaryDirectory() as directory:
                class InterruptedDiagnostic(FakeTools):
                    def run(self, stage, command, deadline, seconds, **kwargs):
                        if stage in ('diagnostic-owned-inventory', 'diagnostic-app-logs'):
                            self.calls.append({'stage': stage, 'argv': command, 'deadline': deadline,
                                               'seconds': seconds, **kwargs})
                            if stage == 'diagnostic-app-logs':
                                if interrupt == 'KeyboardInterrupt':
                                    raise KeyboardInterrupt()
                                raise probe.ProbeFailure('runner-terminated')
                            return json.dumps({'devices': {RUNTIME: [
                                {'udid': OWN, 'name': self.name, 'state': 'Booted'}]}}).encode(), b'', 0
                        return super().run(stage, command, deadline, seconds, **kwargs)

                root = Path(directory)
                tools = InterruptedDiagnostic(root, fail_stage='app-launch-create')
                report = {}
                experiment = probe.Experiment(root / 'Research.app', report, tools, RUN)
                with self.assertRaises(probe.ProbeFailure) as caught:
                    experiment.execute()
                self.assertEqual(caught.exception.code, 'fixture-app-launch-create')
                self.assertEqual(report['diagnosticFailure'], interrupt)
                self.assertEqual([call['stage'] for call in tools.calls
                                  if call['stage'].startswith('diagnostic-')],
                                 ['diagnostic-owned-inventory', 'diagnostic-app-logs'])
                self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])
                self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
                self.assertEqual(report['cleanup']['errors'], [])
                self.assertEqual([item['phase'] for item in report['phases']], ['cleanup'])
                self.assert_only_owned_operations(tools)

    def exercise(self, root, *, fault_case=None, **options):
        report = {'commands': []}
        tools = FakeTools(root, **options)
        experiment = probe.Experiment(root / 'Research.app', report, tools, RUN, fault_case=fault_case)
        failure = None
        try:
            experiment.execute()
        except probe.ProbeFailure as error:
            failure = error.code
        return experiment, report, tools, failure

    def assert_only_owned_operations(self, tools):
        operations = {'boot', 'bootstatus', 'install', 'terminate', 'get_app_container',
                      'launch', 'shutdown', 'delete'}
        for call in tools.calls:
            command = call['argv']
            if len(command) > 3 and command[0:2] == ['xcrun', 'simctl'] and command[2] in operations:
                self.assertEqual(command[3], OWN)
                self.assertNotIn('all', command)
                self.assertNotIn(EXISTING, command)
        self.assertFalse(any('clone' in call['argv'] or 'erase' in call['argv'] for call in tools.calls))

    def test_success_installs_once_cold_launches_each_phase_then_cleans_own_items(self):
        with tempfile.TemporaryDirectory() as directory:
            experiment, report, tools, failure = self.exercise(Path(directory))
            self.assertIsNone(failure)
            stages = [call['stage'] for call in tools.calls]
            self.assertEqual(stages.count('app-install-once'), 1)
            self.assertEqual([item['phase'] for item in report['phases']], list(probe.PHASES) + ['cleanup'])
            self.assertEqual(stages.count('app-terminate'), 5)
            self.assertLess(stages.index('own-simulator-inventory'), stages.index('simulator-boot'))
            boot_ready = stages.index('simulator-boot-ready')
            self.assertEqual(stages[boot_ready + 1], 'own-simulator-inventory')
            self.assertLess(boot_ready + 1, stages.index('app-install-once'))
            install = next(call for call in tools.calls if call['stage'] == 'app-install-once')
            self.assertEqual(install['seconds'], 120)
            self.assertLess(stages.index('app-launch-cleanup'), stages.index('simulator-delete'))
            self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
            self.assertEqual(report['cleanup']['errors'], [])
            self.assertTrue(experiment.ownership_verified)
            self.assert_only_owned_operations(tools)
            self.assertTrue((tools.path.parent / 'manifest.json').is_symlink())
            for call in tools.calls:
                self.assertLessEqual(call['deadline'], experiment.end)
                if call['stage'] in ('own-simulator-inventory', 'app-container'):
                    self.assertTrue(call['private'])
            for index, call in enumerate(tools.calls):
                if call['stage'].startswith('app-launch-') and call['stage'] != 'app-launch-create':
                    self.assertEqual(tools.calls[index - 1]['stage'], 'app-terminate')

    def test_every_main_phase_failure_still_cleans_but_remains_failed(self):
        for phase in probe.PHASES:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                _, report, tools, failure = self.exercise(Path(directory), fail_phase=phase)
                self.assertEqual(failure, 'app-phase-failed-' + phase)
                self.assertFalse(next(item for item in report['phases'] if item['phase'] == phase)['passed'])
                self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])
                self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
                self.assertEqual(report['phases'][-1]['phase'], 'cleanup')
                self.assert_only_owned_operations(tools)

    def test_post_boot_read_timeout_can_recover_before_install_without_repeating_effects(self):
        class DelayedRead(FakeTools):
            failed = False

            def run(self, stage, *args, **kwargs):
                if stage == 'own-simulator-inventory' and self.state == 'Booted' and not self.failed:
                    self.failed = True
                    raise probe.ProbeFailure('command-timeout')
                return super().run(stage, *args, **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            tools = DelayedRead(Path(directory))
            report = {'commands': []}
            experiment = probe.Experiment(Path(directory) / 'Research.app', report, tools, RUN)
            experiment.execute()
            self.assertEqual(len(report['readinessRetries']), 1)
            self.assertEqual(sum(call['stage'] == 'app-install-once' for call in tools.calls), 1)
            self.assertEqual([item['phase'] for item in report['phases']], list(probe.PHASES) + ['cleanup'])

    def test_persistent_post_boot_read_timeout_never_installs_and_has_three_attempt_bound(self):
        class UnresponsiveRead(FakeTools):
            attempts = 0

            def run(self, stage, *args, **kwargs):
                if stage == 'own-simulator-inventory' and self.state == 'Booted' and self.attempts < 3:
                    self.attempts += 1
                    raise probe.ProbeFailure('command-timeout')
                return super().run(stage, *args, **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            tools = UnresponsiveRead(Path(directory))
            report = {'commands': []}
            experiment = probe.Experiment(Path(directory) / 'Research.app', report, tools, RUN)
            with self.assertRaisesRegex(probe.ProbeFailure, 'command-timeout'):
                experiment.execute()
            self.assertEqual(tools.attempts, 3)
            self.assertFalse(any(call['stage'] == 'app-install-once' for call in tools.calls))
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])

    def test_app_cleanup_failure_cannot_be_replaced_by_simulator_deletion(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, tools, failure = self.exercise(Path(directory), cleanup_bad=True)
            self.assertEqual(failure, 'experiment-cleanup-failed')
            self.assertFalse(report['cleanup']['keychainCleanupConfirmed'])
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
            self.assertIn('app-keychain-cleanup', [item['stage'] for item in report['cleanup']['errors']])
            self.assert_only_owned_operations(tools)

    def test_simulator_delete_error_and_remaining_device_are_failure(self):
        for options in ({'fail_stage': 'simulator-delete'}, {'retain_simulator': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                _, report, _, failure = self.exercise(Path(directory), **options)
                self.assertEqual(failure, 'experiment-cleanup-failed')
                self.assertFalse(report['cleanup']['createdSimulatorAbsent'])
                self.assertTrue(report['cleanup']['errors'])

    def test_preinstall_boot_failure_only_deletes_own_simulator(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, tools, failure = self.exercise(Path(directory), fail_stage='simulator-boot-ready')
            self.assertEqual(failure, 'fixture-simulator-boot-ready')
            self.assertTrue(report['cleanup']['keychainCleanupNotAttemptedBeforeInstall'])
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
            self.assertFalse(any(call['stage'].startswith('app-launch') for call in tools.calls))
            self.assert_only_owned_operations(tools)

    def test_install_error_still_attempts_app_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, tools, failure = self.exercise(Path(directory), fail_stage='app-install-once')
            self.assertEqual(failure, 'fixture-app-install-once')
            self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])
            self.assertIn('app-launch-cleanup', [call['stage'] for call in tools.calls])
            self.assert_only_owned_operations(tools)

    def test_uncertain_create_recovers_exact_random_name_and_cleans_only_that_uuid(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, tools, failure = self.exercise(Path(directory), uncertain_create=True)
            self.assertEqual(failure, 'fixture-create-output-lost')
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
            self.assert_only_owned_operations(tools)

    def test_wrong_owner_uuid_never_reaches_mutating_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, tools, failure = self.exercise(Path(directory), wrong_owner=True)
            self.assertEqual(failure, 'created-simulator-owner-mismatch')
            self.assertFalse(any(call['stage'] in ('simulator-boot', 'app-install-once',
                                                   'simulator-delete', 'simulator-shutdown')
                                 for call in tools.calls))
            self.assertTrue(report['cleanup']['errors'])

    def test_stale_frame_never_advances_and_cleanup_is_still_attempted(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, tools, failure = self.exercise(Path(directory), stale_frame=True)
            self.assertEqual(failure, 'phase-report-owner-or-nonce')
            self.assertNotIn('app-launch-reopen', [call['stage'] for call in tools.calls])
            self.assertIn('app-launch-cleanup', [call['stage'] for call in tools.calls])
            self.assertFalse(report['cleanup']['keychainCleanupConfirmed'])
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])

    def test_inventory_failure_before_creation_does_not_operate_any_simulator(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, tools, failure = self.exercise(Path(directory), fail_stage='available-runtimes')
            self.assertEqual(failure, 'fixture-available-runtimes')
            self.assertTrue(report['cleanup']['noSimulatorCreated'])
            self.assertFalse(any(call['stage'] == 'simulator-create' for call in tools.calls))

    def test_both_fault_hooks_require_exact_failed_create_then_fresh_process_cleanup(self):
        for hook in probe.FAULT_CASES:
            with self.subTest(hook=hook), tempfile.TemporaryDirectory() as directory:
                _, report, tools, failure = self.exercise(Path(directory), fault_case=hook)
                self.assertIsNone(failure)
                self.assertEqual(report['experiment'], 'expected-creation-failure-recovery')
                expected = report['expectedCreationFailure']
                self.assertEqual(expected['faultCase'], hook)
                self.assertEqual(expected['requiredFailure'], 'injected-' + hook)
                self.assertTrue(expected['confirmed'])
                self.assertEqual(expected['observed'], report['phases'][0])
                self.assertFalse(expected['observed']['passed'])
                self.assertEqual(expected['observed']['checks'], {})
                self.assertNotIn('osStatus', expected['observed'])
                self.assertEqual([item['phase'] for item in report['phases']], ['create', 'cleanup'])
                create, cleanup = report['phases']
                for key in ('processID', 'launchID', 'nonce'):
                    self.assertNotEqual(create[key], cleanup[key])
                launches = [call for call in tools.calls if call['stage'].startswith('app-launch-')]
                self.assertEqual(launches[0]['argv'][-2:], ['--fault', hook])
                self.assertNotIn('--fault', launches[1]['argv'])
                stages = [call['stage'] for call in tools.calls]
                self.assertEqual(stages.count('app-install-once'), 1)
                self.assertEqual(stages[stages.index('app-launch-cleanup') - 1], 'app-terminate')
                self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])
                self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
                self.assert_only_owned_operations(tools)
                self.assertTrue((tools.path.parent / 'manifest.json').is_symlink())

    def test_wrong_fault_code_or_ordinary_failure_never_becomes_expected_success(self):
        for hook in probe.FAULT_CASES:
            other = next(item for item in probe.FAULT_CASES if item != hook)
            for code in ('injected-' + other, 'ordinary-create-failure'):
                with self.subTest(hook=hook, code=code), tempfile.TemporaryDirectory() as directory:
                    _, report, _, failure = self.exercise(Path(directory), fault_case=hook,
                                                         fault_changes={'failure': code})
                    self.assertEqual(failure, 'expected-creation-failure-not-observed')
                    self.assertFalse(report['expectedCreationFailure']['confirmed'])
                    self.assertEqual(report['expectedCreationFailure']['observed']['failure'], code)
                    self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])
                    self.assertTrue(report['cleanup']['createdSimulatorAbsent'])

    def test_unexpected_passed_create_is_failure_even_with_successful_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, _, failure = self.exercise(
                Path(directory), fault_case='after-key-add',
                fault_changes={'passed': True, 'checks': probe.CHECKS['create'], 'failure': None})
            self.assertEqual(failure, 'expected-creation-failure-not-observed')
            self.assertTrue(report['expectedCreationFailure']['observed']['passed'])
            self.assertFalse(report['expectedCreationFailure']['confirmed'])
            self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])

    def test_expected_failure_with_checks_or_osstatus_is_rejected(self):
        for changes in ({'checks': {'keyPublicMatched': True}}, {'osStatus': 0}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                _, report, _, failure = self.exercise(Path(directory), fault_case='after-key-add',
                                                     fault_changes=changes)
                self.assertEqual(failure, 'expected-creation-failure-not-observed')
                self.assertFalse(report['expectedCreationFailure']['confirmed'])
                self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])

    def test_expected_creation_failure_does_not_excuse_cleanup_or_simulator_delete_failure(self):
        for hook in probe.FAULT_CASES:
            for options in ({'cleanup_bad': True}, {'retain_simulator': True},
                            {'fail_stage': 'app-launch-cleanup'}):
                with self.subTest(hook=hook, options=options), tempfile.TemporaryDirectory() as directory:
                    _, report, _, failure = self.exercise(Path(directory), fault_case=hook, **options)
                    self.assertEqual(failure, 'experiment-cleanup-failed')
                    self.assertTrue(report['expectedCreationFailure']['confirmed'])
                    self.assertTrue(report['cleanup']['errors'])

    def test_fault_mode_still_rejects_stale_nonce_and_does_not_skip_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            _, report, tools, failure = self.exercise(Path(directory), fault_case='after-key-add',
                                                     stale_frame=True)
            self.assertEqual(failure, 'phase-report-owner-or-nonce')
            self.assertFalse(report['expectedCreationFailure']['confirmed'])
            self.assertIn('app-launch-cleanup', [call['stage'] for call in tools.calls])
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])

    def test_default_lifecycle_never_accepts_an_injected_failure(self):
        class InjectedTools(FakeTools):
            def run(self, stage, *args, **kwargs):
                result = super().run(stage, *args, **kwargs)
                if stage == 'app-launch-create':
                    value = json.loads(self.path.read_bytes())
                    value.update(passed=False, checks={}, failure='injected-after-key-add')
                    self.path.write_text(json.dumps(value))
                return result

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = InjectedTools(root)
            report = {}
            experiment = probe.Experiment(root / 'Research.app', report, tools, RUN)
            with self.assertRaises(probe.ProbeFailure) as caught:
                experiment.execute()
            self.assertEqual(caught.exception.code, 'app-phase-failed-create')
            self.assertNotIn('expectedCreationFailure', report)
            self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])
            self.assertFalse(any('--fault' in call['argv'] for call in tools.calls))

    def test_cli_reports_distinct_modes_and_generates_independent_run_ids(self):
        run_ids, simulator_names = [], []
        for hook in (None,) + probe.FAULT_CASES:
            with self.subTest(hook=hook), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app, _ = FileTests().make_app(root)
                tools = FakeTools(root)
                report_path = root / 'result.json'
                arguments = ['probe', '--app', str(app), '--report', str(report_path)]
                if hook is not None:
                    arguments.extend(['--fault-case', hook])
                with patch.object(sys, 'argv', arguments), \
                        patch.object(probe, 'source_snapshot', return_value={'files': []}), \
                        patch.object(probe, 'CommandRunner', return_value=tools), redirect_stdout(io.StringIO()):
                    self.assertEqual(probe.main(), 0)
                report = json.loads(report_path.read_bytes())
                self.assertTrue(report['passed'])
                run_ids.append(report['runID'])
                simulator_names.append(report['simulatorSelection']['name'])
                if hook is None:
                    self.assertEqual(report['experiment'], 'isolated-ios-simulator-identity-lifecycle')
                    self.assertNotIn('expectedCreationFailure', report)
                    self.assertEqual(len(report['phases']), 5)
                else:
                    self.assertEqual(report['experiment'], 'expected-creation-failure-recovery')
                    self.assertTrue(report['expectedCreationFailure']['confirmed'])
                    self.assertEqual(len(report['phases']), 2)
                self.assert_only_owned_operations(tools)
        self.assertEqual(len(set(run_ids)), 3)
        self.assertEqual(len(set(simulator_names)), 3)
        self.assertTrue(all(value == value.upper() for value in run_ids))

    def test_unknown_fault_hook_is_rejected_before_any_tool_execution(self):
        with patch.object(sys, 'argv', ['probe', '--app', '/unused.app', '--report', '/unused.json',
                                       '--fault-case', 'unknown']), \
                patch.object(probe, 'hash_app') as preflight, \
                patch.object(probe, 'CommandRunner') as runner, \
                patch.object(sys, 'stderr', io.StringIO()), self.assertRaises(SystemExit) as caught:
            probe.main()
        self.assertEqual(caught.exception.code, 2)
        preflight.assert_not_called()
        runner.assert_not_called()

    def test_each_fault_mode_preserves_existing_evidence_before_preflight(self):
        for hook in probe.FAULT_CASES:
            with self.subTest(hook=hook), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                path = root / 'existing.json'
                original = b'previous-run-evidence\n'
                path.write_bytes(original)
                with patch.object(sys, 'argv', ['probe', '--app', str(root / 'unused.app'),
                                               '--report', str(path), '--fault-case', hook]), \
                        patch.object(probe, 'hash_app') as preflight, \
                        patch.object(probe, 'CommandRunner') as runner, redirect_stdout(io.StringIO()):
                    self.assertEqual(probe.main(), 2)
                self.assertEqual(path.read_bytes(), original)
                preflight.assert_not_called()
                runner.assert_not_called()

    def test_fault_mode_preflight_failure_remains_failed_and_explicitly_labeled(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'result.json'
            with patch.object(sys, 'argv', ['probe', '--app', str(root / 'missing.app'),
                                           '--report', str(path), '--fault-case', 'after-certificate-add']), \
                    patch.object(probe, 'CommandRunner') as runner, redirect_stdout(io.StringIO()):
                self.assertEqual(probe.main(), 1)
            report = json.loads(path.read_bytes())
            self.assertFalse(report['passed'])
            self.assertEqual(report['experiment'], 'expected-creation-failure-recovery')
            self.assertEqual(report['failure'], 'app-bundle-required')
            self.assertFalse(report['expectedCreationFailure']['confirmed'])
            self.assertEqual(report['expectedCreationFailure']['requiredFailure'],
                             'injected-after-certificate-add')
            runner.assert_not_called()

    def test_sigterm_during_a_phase_runs_finally_cleanup_and_writes_failed_report(self):
        class SignalledTools(FakeTools):
            def run(self, stage, *args, **kwargs):
                if stage == 'app-launch-reopen':
                    os.kill(os.getpid(), signal.SIGTERM)
                return super().run(stage, *args, **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, _ = FileTests().make_app(root)
            tools = SignalledTools(root)
            report_path = root / 'result.json'
            previous_handler = signal.getsignal(signal.SIGTERM)
            with patch.object(sys, 'argv', ['probe', '--app', str(app), '--report', str(report_path)]), \
                    patch.object(probe, 'source_snapshot', return_value={'files': []}), \
                    patch.object(probe, 'CommandRunner', return_value=tools), redirect_stdout(io.StringIO()):
                self.assertEqual(probe.main(), 1)
            report = json.loads(report_path.read_bytes())
            self.assertFalse(report['passed'])
            self.assertEqual(report['failure'], 'runner-terminated')
            self.assertTrue(report['cleanup']['keychainCleanupConfirmed'])
            self.assertTrue(report['cleanup']['createdSimulatorAbsent'])
            self.assertEqual(signal.getsignal(signal.SIGTERM), previous_handler)
            self.assert_only_owned_operations(tools)


if __name__ == '__main__':
    unittest.main()
