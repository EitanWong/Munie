"""Offline availability, signing and command-bound tests; no Xcode or device is invoked."""
import copy
import errno
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

SOURCE = Path(__file__).resolve().parents[1] / "test-available-ios.py"
SPEC = importlib.util.spec_from_file_location("available_ios", SOURCE)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
PHONE = "c9b6ca8a-deb2-4bce-a538-3be3146cf3dc"
OTHER_PHONE = "d9b6ca8a-deb2-4bce-a538-3be3146cf3dc"
UDID = "00000000-0011223344556677"
TEAM = "SYNTH12345"


def phone(identifier=PHONE, **overrides):
    device = {"identifier": identifier, "hardwareProperties": {
        "reality": "physical", "deviceType": "iPhone", "platform": "iOS", "udid": UDID},
        "connectionProperties": {"tunnelState": "connected", "transportType": "wired"},
        "deviceProperties": {"ddiServicesAvailable": True}}
    for section, fields in overrides.items():
        device[section].update(fields)
    return device


def envelope(result):
    return {"info": {"outcome": "success"}, "result": result}


def lock(identifier=PHONE, **overrides):
    result = {"deviceIdentifier": identifier, "passcodeRequired": False, "unlockedSinceBoot": True}
    result.update(overrides)
    return envelope(result)


def generated_test_run(products, ui_path="__TESTROOT__/Debug-iphoneos/Munie", product="legacy"):
    products.mkdir(parents=True, exist_ok=True)
    (products / "Debug-iphoneos/Munie.app").mkdir(parents=True, exist_ok=True)
    source = products / "Munie_fixture-iphoneos.xctestrun"
    value = {"__xctestrun_metadata__": {"FormatVersion": 1, "ContainerInfo": {"SchemeName": "Munie"}},
             "MunieTests": {"IsAppHostedTestBundle": True, "TestHostPath": "__TESTROOT__/Debug-iphoneos/Munie.app",
                            "EnvironmentVariables": {"MUNIE_ACCEPTANCE_INVITATION": "fixture", "SAFE": "yes"}},
             "MunieUITests": {"IsUITestBundle": True, "UITargetAppPath": ui_path},
             "OtherTests": {"TestHostPath": "fixture"}}
    if product == 'remodex':
        value = {key.replace('Munie', 'MunieRemodex'): target for key, target in value.items()}
        value['__xctestrun_metadata__']['ContainerInfo']['SchemeName'] = 'MunieRemodex'
        value['MunieRemodexTests']['EnvironmentVariables'].update({
            'TEST_RUNNER_REMODEX_ACCEPTANCE_PAIRING': 'private', 'PHODEX_FIXTURE': 'private'})
        value['MunieRemodexTests']['OnlyTestIdentifiers'] = ['StaleSelection']
        value['MunieRemodexTests']['SkipTestIdentifiers'] = ['ExistingSkip']
        value['MunieRemodexUITests']['UITargetAppPath'] = '__TESTROOT__/Debug-iphoneos/MunieRemodex'
        (products / 'Debug-iphoneos/MunieRemodex.app').mkdir(exist_ok=True)
        source = products / 'MunieRemodex_fixture-iphoneos.xctestrun'
    source.write_bytes(plistlib.dumps(value))
    return source


class FixtureRunner:
    def __init__(self, inventory=None, locks=None, fail=None, invalid_inventory=False):
        self.inventory = envelope({"devices": [phone()]}) if inventory is None else inventory
        self.locks = locks or {PHONE: lock()}
        self.fail = fail or {}
        self.invalid_inventory = invalid_inventory
        self.calls = []

    def run(self, command, *, timeout, log, environment):
        self.calls.append((command, timeout, copy.deepcopy(environment)))
        name = log.stem
        record = {"command": command, "timeoutSeconds": timeout, "exitStatus": self.fail.get(name, 0),
                  "processGroupGone": True, "log": str(log)}
        if "devicectl" in command and record["exitStatus"] == 0:
            destination = Path(command[command.index("--json-output") + 1])
            if "lockState" in command:
                value = self.locks[command[command.index("--device") + 1]]
            else:
                value = self.inventory
            destination.write_text("invalid" if self.invalid_inventory else json.dumps(value))
        if name == "physical-build" and record["exitStatus"] == 0:
            derived = Path(command[command.index("-derivedDataPath") + 1])
            scheme = command[command.index('-scheme') + 1]
            generated_test_run(derived / "Build/Products", product='remodex' if scheme == 'MunieRemodex' else 'legacy')
        return record


class AvailableDeviceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="munie-device-tooling-fixture-")
        self.root = Path(self.temporary.name)
        (self.root / "config").mkdir()
        self.evidence = self.root / "build"
        self.evidence.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def run_fixture(self, runner=None, environment=None, dry_run=False, product='legacy'):
        runner = runner or FixtureRunner()
        environment = {"MUNIE_DEVELOPMENT_TEAM": TEAM} if environment is None else environment
        return M.execute(self.root, self.evidence, dry_run=dry_run, environment=environment, runner=runner, product=product)

    def test_remodex_profile_runs_all_offline_unit_tests_but_excludes_real_account_tests(self):
        runner = FixtureRunner()
        report = self.run_fixture(runner, product='remodex')
        self.assertEqual((report['status'], report['product']), ('passed', 'remodex'))
        build, test = [c[0] for c in runner.calls[-2:]]
        self.assertIn('MunieRemodex', build)
        self.assertIn('-onlyUsePackageVersionsFromResolvedFile', build)
        self.assertEqual([v for v in test if v.startswith('-only-testing:')],
                         ['-only-testing:' + s for s in M.REMODEX_SAFE_TESTS])
        self.assertIn('-skip-testing:MunieRemodexTests/MunieRemodexDeviceAcceptanceTests', test)
        clone = plistlib.loads(Path(report['testConfiguration']['clone']).read_bytes())
        unit = clone['MunieRemodexTests']
        self.assertNotIn('OnlyTestIdentifiers', unit)
        self.assertEqual(unit['SkipTestIdentifiers'], ['ExistingSkip', 'MunieRemodexDeviceAcceptanceTests'])
        self.assertEqual(unit['EnvironmentVariables'], {'SAFE': 'yes'})
        self.assertEqual(clone['MunieRemodexUITests']['OnlyTestIdentifiers'],
                         ['MunieRemodexSmokeTests', 'MunieOnboardingUITests'])
        self.assertEqual(clone['__xctestrun_metadata__']['ContainerInfo']['SchemeName'], 'MunieRemodex')
        self.assertTrue(report['testConfiguration']['originalUnchanged'])

    def test_remodex_absent_phone_and_failed_physical_run_keep_selected_product(self):
        absent = FixtureRunner(inventory=envelope({'devices': []}))
        result = self.run_fixture(absent, product='remodex')
        self.assertEqual((result['mode'], result['status']), ('simulator', 'passed'))
        self.assertEqual(absent.calls[-1][0], [str(self.root / 'scripts/test-remodex-ios.sh')])
        failed = FixtureRunner(fail={'physical-tests': 65})
        result = self.run_fixture(failed, product='remodex')
        self.assertEqual((result['mode'], result['status']), ('physical', 'failed'))
        self.assertFalse(any('test-remodex-ios.sh' in s for c, _, _ in failed.calls for s in c))

    def test_remodex_profile_does_not_clone_legacy_products_or_inherit_real_model_inputs(self):
        products = self.root / 'products'
        generated_test_run(products)
        with self.assertRaises(ValueError):
            M.prepare_test_run(products, product='remodex')
        source = generated_test_run(products, product='remodex')
        original = source.read_bytes()
        clone, _ = M.prepare_test_run(products, safe_only=False, product='remodex')
        value = plistlib.loads(clone.read_bytes())
        self.assertEqual(value['MunieRemodexTests']['OnlyTestIdentifiers'], ['StaleSelection'])
        self.assertEqual(value['MunieRemodexTests']['SkipTestIdentifiers'], ['ExistingSkip'])
        self.assertEqual(value['MunieRemodexTests']['EnvironmentVariables'], {'SAFE': 'yes'})
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(M.safe_environment({'TEST_RUNNER_REMODEX_MODE': 'submit',
                         'REMODEX_QR': 'private', 'PHODEX_MODE': 'private', 'PATH': 'preserved'}),
                         {'PATH': 'preserved'})

    def test_ready_unlocked_physical_iphone_builds_signed_then_runs_only_safe_tests(self):
        runner = FixtureRunner()
        report = self.run_fixture(runner)
        self.assertEqual(report["mode"], "physical")
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["device"]["udid"], UDID)
        commands = [call[0] for call in runner.calls]
        self.assertEqual(len(commands), 5)
        build, test = commands[-2:]
        self.assertEqual(build[-1], "build-for-testing")
        self.assertIn("CODE_SIGNING_ALLOWED=YES", build)
        self.assertIn("DEVELOPMENT_TEAM=" + TEAM, build)
        self.assertIn("platform=iOS,id=" + UDID, build)
        self.assertEqual(test[-1], "test-without-building")
        self.assertIn("-xctestrun", test)
        self.assertNotIn("-project", test)
        self.assertTrue(report["testConfiguration"]["originalUnchanged"])
        self.assertEqual(report["testConfiguration"]["pathRepairs"][0]["new"],
                         "__TESTROOT__/Debug-iphoneos/Munie.app")
        self.assertEqual([value for value in test if value.startswith("-only-testing:")],
                         ["-only-testing:" + value for value in M.SAFE_TESTS])
        self.assertIn("-skip-testing:MunieTests/RemoteDeviceAcceptanceTests", test)
        self.assertIn("-skip-testing:MunieUITests/RemoteFlowTests/testPairedRealTaskAndRestartRecovery", test)
        self.assertFalse(any("test-ios.sh" in value for command in commands for value in command))
        self.assertTrue(all(timeout > 0 for _, timeout, _ in runner.calls))

    def test_absent_locked_or_disconnected_phone_uses_existing_simulator_script(self):
        scenarios = [
            FixtureRunner(inventory=envelope({"devices": []})),
            FixtureRunner(locks={PHONE: lock(passcodeRequired=True)}),
            FixtureRunner(inventory=envelope({"devices": [phone(connectionProperties={"tunnelState": "disconnected"})]})),
            FixtureRunner(inventory=envelope({"devices": [phone(deviceProperties={"ddiServicesAvailable": False})]})),
        ]
        for index, runner in enumerate(scenarios):
            with self.subTest(index=index):
                report = self.run_fixture(runner)
                self.assertEqual((report["mode"], report["status"]), ("simulator", "passed"))
                self.assertEqual(runner.calls[-1][0], [str(self.root / "scripts/test-ios.sh")])
                self.assertFalse(any(call[0][0] == "xcodebuild" for call in runner.calls))

    def test_watch_ipad_and_simulated_iphone_are_not_physical_candidates(self):
        devices = [phone(hardwareProperties={"deviceType": "appleWatch", "platform": "watchOS"}),
                   phone(hardwareProperties={"deviceType": "iPad"}),
                   phone(hardwareProperties={"reality": "simulated"}),
                   phone(deviceProperties={"ddiServicesAvailable": 1})]
        runner = FixtureRunner(inventory=envelope({"devices": devices}))
        report = self.run_fixture(runner)
        self.assertEqual(report["mode"], "simulator")
        self.assertFalse(any("lockState" in call[0] for call in runner.calls))

    def test_missing_or_mismatched_lock_evidence_never_permits_physical_tests(self):
        values = [envelope({}), envelope([]), lock(identifier=OTHER_PHONE), lock(unlockedSinceBoot=False),
                  lock(passcodeRequired=0), lock(unlockedSinceBoot=1)]
        for value in values:
            with self.subTest(value=value):
                report = self.run_fixture(FixtureRunner(locks={PHONE: value}))
                self.assertEqual(report["mode"], "simulator")

    def test_locked_first_phone_does_not_hide_another_unlocked_phone(self):
        runner = FixtureRunner(inventory=envelope({"devices": [phone(), phone(OTHER_PHONE)]}),
                               locks={PHONE: lock(passcodeRequired=True), OTHER_PHONE: lock(OTHER_PHONE)})
        report = self.run_fixture(runner)
        self.assertEqual(report["device"]["identifier"], OTHER_PHONE)
        self.assertEqual(report["mode"], "physical")

    def test_lock_probe_count_is_bounded(self):
        devices = [phone(str(uuid.UUID(int=index))) for index in range(1, 8)]
        locks = {item["identifier"]: lock(item["identifier"], passcodeRequired=True) for item in devices}
        runner = FixtureRunner(inventory=envelope({"devices": devices}), locks=locks)
        report = self.run_fixture(runner)
        self.assertEqual(report["mode"], "simulator")
        self.assertEqual(sum("lockState" in call[0] for call in runner.calls), M.LIMITS["maximumLockProbes"])

    def test_probe_failure_or_malformed_json_uses_simulator_and_preserves_failed_command(self):
        for runner in [FixtureRunner(fail={"device-inventory": 2}), FixtureRunner(invalid_inventory=True),
                       FixtureRunner(fail={"device-lock-0": 1}), FixtureRunner(inventory=envelope({"devices": [{}] * 129})),
                       FixtureRunner(inventory=envelope([])), FixtureRunner(inventory={"info": [], "result": {}}),
                       FixtureRunner(inventory={"info": {"outcome": "failed"}, "result": {}})]:
            with self.subTest(runner=runner):
                report = self.run_fixture(runner)
                self.assertEqual(report["mode"], "simulator")
                self.assertEqual(report["status"], "passed")
                self.assertGreaterEqual(len(report["commands"]), 2)

    def test_configuration_clone_preserves_original_and_selects_only_safe_targets(self):
        products = self.root / "products"
        source = generated_test_run(products)
        original = source.read_bytes()
        clone, record = M.prepare_test_run(products)
        value = plistlib.loads(clone.read_bytes())
        self.assertEqual(source.read_bytes(), original)
        self.assertTrue(record["originalUnchanged"])
        self.assertEqual(clone.parent, source.parent)
        self.assertEqual(set(value), {"__xctestrun_metadata__", "MunieTests", "MunieUITests"})
        self.assertEqual(value["__xctestrun_metadata__"]["ContainerInfo"], {"SchemeName": "Munie"})
        self.assertEqual(value["MunieTests"]["EnvironmentVariables"], {"SAFE": "yes"})
        self.assertEqual(value["MunieUITests"]["OnlyTestIdentifiers"],
                         [item.split("/", 1)[1] for item in M.SAFE_TESTS if item.startswith("MunieUITests/")])
        self.assertEqual(record["pathRepairs"], [{"target": "MunieUITests", "field": "UITargetAppPath",
                         "old": "__TESTROOT__/Debug-iphoneos/Munie", "new": "__TESTROOT__/Debug-iphoneos/Munie.app"}])

    def test_app_suffix_is_only_added_if_the_app_directory_actually_exists(self):
        for index, path in enumerate(("__TESTROOT__/Debug-iphoneos/Munie.app", "__TESTROOT__/Debug-iphoneos/Missing")):
            products = self.root / str(index)
            generated_test_run(products, ui_path=path)
            clone, record = M.prepare_test_run(products)
            self.assertEqual(plistlib.loads(clone.read_bytes())["MunieUITests"]["UITargetAppPath"], path)
            self.assertEqual(record["pathRepairs"], [])

    def test_default_scope_preserves_generated_test_selection(self):
        products = self.root / "products"
        source = generated_test_run(products)
        value = plistlib.loads(source.read_bytes())
        value["MunieTests"]["OnlyTestIdentifiers"] = ["FixtureTests"]
        value["MunieUITests"]["SkipTestIdentifiers"] = ["FixtureSkippedTests"]
        source.write_bytes(plistlib.dumps(value))
        clone, record = M.prepare_test_run(products, safe_only=False)
        copied = plistlib.loads(clone.read_bytes())
        self.assertEqual(copied["MunieTests"]["OnlyTestIdentifiers"], ["FixtureTests"])
        self.assertEqual(copied["MunieUITests"]["SkipTestIdentifiers"], ["FixtureSkippedTests"])
        self.assertNotIn("OnlyTestIdentifiers", copied["MunieUITests"])
        self.assertEqual(record["testScope"], "default")

    def test_missing_ambiguous_or_unreviewed_test_configuration_is_rejected(self):
        products = self.root / "products"
        products.mkdir()
        with self.assertRaises(ValueError):
            M.prepare_test_run(products)
        source = generated_test_run(products)
        source.write_bytes(plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 2}}))
        with self.assertRaises(ValueError):
            M.prepare_test_run(products)
        (products / "Munie_second.xctestrun").write_bytes(source.read_bytes())
        with self.assertRaises(ValueError):
            M.prepare_test_run(products)

    def test_configuration_failure_cannot_fall_back_after_a_physical_build(self):
        runner = FixtureRunner()
        with patch.object(M, "prepare_test_run", side_effect=ValueError("fixture bad configuration")):
            report = self.run_fixture(runner)
        self.assertEqual((report["mode"], report["status"]), ("physical", "failed"))
        self.assertEqual(report["failure"], "test-configuration: fixture bad configuration")
        self.assertEqual(runner.calls[-1][0][-1], "build-for-testing")

    def test_team_is_only_read_from_explicit_environment_or_ignored_config(self):
        config = self.root / "config/Signing.xcconfig"
        config.write_text('// DEVELOPMENT_TEAM = WRONG12345\nDEVELOPMENT_TEAM = "CONFIG1234" // owner\n')
        self.assertEqual(M.development_team(self.root, {}), ("CONFIG1234", "ignored-signing-config"))
        self.assertEqual(M.development_team(self.root, {"MUNIE_DEVELOPMENT_TEAM": TEAM}), (TEAM, "environment"))
        self.assertEqual(self.run_fixture(environment={})["mode"], "physical")
        config.unlink()
        report = self.run_fixture(environment={"DEVELOPMENT_TEAM": TEAM})
        self.assertEqual(report["mode"], "simulator")
        self.assertEqual(report["reason"], "physical-iphone-signing-unconfigured")

    def test_invalid_explicit_team_fails_without_build_or_simulator(self):
        runner = FixtureRunner()
        report = self.run_fixture(runner, environment={"MUNIE_DEVELOPMENT_TEAM": "$(untrusted)"})
        self.assertEqual(report["status"], "failed")
        self.assertEqual(len(runner.calls), 2)

    def test_dry_run_only_probes_and_reports_selection(self):
        for runner in [FixtureRunner(), FixtureRunner(inventory=envelope({"devices": []}))]:
            with self.subTest(runner=runner):
                report = self.run_fixture(runner, dry_run=True)
                self.assertEqual(report["status"], "selected")
                self.assertTrue(all("devicectl" in call[0] for call in runner.calls))

    def test_physical_signing_install_or_test_failure_cannot_be_hidden_by_simulator_success(self):
        for stage in ("bootstrap", "physical-build", "physical-tests"):
            runner = FixtureRunner(fail={stage: 65})
            with self.subTest(stage=stage):
                report = self.run_fixture(runner)
                self.assertEqual((report["mode"], report["status"]), ("physical", "failed"))
                self.assertEqual(report["commands"][-1]["exitStatus"], 65)
                self.assertFalse(any("test-ios.sh" in value for call in runner.calls for value in call[0]))

    def test_simulator_failure_is_a_failure(self):
        runner = FixtureRunner(inventory=envelope({"devices": []}), fail={"simulator-tests": 1})
        report = self.run_fixture(runner)
        self.assertEqual((report["mode"], report["status"]), ("simulator", "failed"))

    def test_real_model_inputs_and_destination_override_are_not_inherited(self):
        runner = FixtureRunner(inventory=envelope({"devices": []}))
        environment = {"MUNIE_ACCEPTANCE_INVITATION": "private", "MUNIE_DEVICE_ACCEPTANCE_MODE": "submit",
                       "TEST_RUNNER_MUNIE_DEVICE_INVITATION": "private", "IOS_TEST_DESTINATION": "platform=iOS,id=wrong",
                       "XCODE_XCCONFIG_FILE": "/unexpected", "PATH": "/fixture", "DEVELOPER_DIR": "/fixture/Xcode"}
        self.run_fixture(runner, environment=environment)
        for _, _, observed in runner.calls:
            self.assertEqual(observed, {"PATH": "/fixture", "DEVELOPER_DIR": "/fixture/Xcode"})

    def test_json_size_type_and_symlink_limits(self):
        path = self.root / "probe.json"
        path.write_bytes(b"x" * (M.LIMITS["jsonBytes"] + 1))
        with self.assertRaises(ValueError):
            M.read_json(path)
        path.unlink()
        path.symlink_to(self.root / "absent")
        with self.assertRaises(OSError):
            M.read_json(path)

    def test_runner_records_literal_exit_and_reaps_bounded_fixture_timeout(self):
        runner = M.CommandRunner(self.root)
        result = runner.run([sys.executable, "-c", 'print("fixture stdout"); raise SystemExit(7)'],
                            timeout=5, log=self.root / "exit.log", environment=dict(os.environ))
        self.assertEqual(result["exitStatus"], 7)
        self.assertEqual((self.root / "exit.log").read_text().strip(), "fixture stdout")
        self.assertTrue(result["processGroupGone"])
        timed = runner.run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=1,
                           log=self.root / "timeout.log", environment=dict(os.environ))
        self.assertEqual(timed["failure"], "timeout")
        self.assertTrue(timed["processGroupGone"])
        self.assertIsNotNone(timed["exitStatus"])

    def test_exiting_owned_group_permission_race_is_retried_and_reaped(self):
        runner = M.CommandRunner(self.root)
        native_killpg = os.killpg
        terminated = set()
        denied = []

        def transient_permission_error(pid, requested):
            if requested == 0 and pid in terminated and not denied:
                denied.append(pid)
                raise PermissionError(errno.EPERM, "Synthetic exiting-group probe race")
            result = native_killpg(pid, requested)
            if requested == signal.SIGTERM:
                terminated.add(pid)
            return result

        with patch.object(M.os, "killpg", side_effect=transient_permission_error):
            result = runner.run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.1,
                                log=self.root / "transient-permission.log", environment=dict(os.environ))
        self.assertEqual(len(denied), 1)
        self.assertEqual(result["failure"], "timeout")
        self.assertTrue(result["processGroupGone"])
        self.assertIsNotNone(result["exitStatus"])
        self.assertNotIn("cleanupFailure", result)

    def test_permission_denial_alone_never_establishes_group_cleanup(self):
        with patch.object(M.os, "killpg", side_effect=PermissionError(errno.EPERM, "denied")):
            self.assertFalse(M.group_gone(123))

    def test_cleanup_failure_preserves_original_timeout_and_prevents_success(self):
        native_stop = M.stop_group

        def cleaned_but_report_unconfirmed(process):
            # Reap the actual owned fixture, then test an unconfirmed cleanup report safely.
            self.assertTrue(native_stop(process))
            return False

        with patch.object(M, "stop_group", side_effect=cleaned_but_report_unconfirmed):
            result = M.CommandRunner(self.root).run(
                [sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.1,
                log=self.root / "unconfirmed-cleanup.log", environment=dict(os.environ))
        self.assertEqual(result["failure"], "timeout")
        self.assertEqual(result["cleanupFailure"], "process-cleanup")
        self.assertFalse(result["processGroupGone"])
        self.assertFalse(M.succeeded(result))


if __name__ == "__main__":
    unittest.main()
