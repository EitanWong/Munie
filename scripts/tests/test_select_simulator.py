import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "select-simulator.py"
SPEC = importlib.util.spec_from_file_location("select_simulator", SCRIPT)
SELECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SELECTOR)


def runtime(value):
    return "com.apple.CoreSimulator.SimRuntime.iOS-" + value


def phone(identifier, available=True, state="Shutdown", name="iPhone 17"):
    return {"udid": identifier, "name": name, "isAvailable": available, "state": state}


class SimulatorSelectionTests(unittest.TestCase):
    def test_newest_supported_runtime_wins_over_old_or_future_runtime(self):
        devices = {
            runtime("18-5"): [phone("old")],
            runtime("26-2"): [phone("matching")],
            runtime("27-0"): [phone("future")],
        }
        self.assertEqual(SELECTOR.select_device(devices, "26.2"), "matching")

    def test_unavailable_and_non_phone_devices_are_excluded(self):
        devices = {
            runtime("26-2"): [phone("missing", False), phone("ipad", name="iPad Pro")],
            runtime("26-1"): [phone("valid")],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-2": [phone("watch")],
        }
        self.assertEqual(SELECTOR.select_device(devices, "26.2"), "valid")

    def test_booted_device_is_preferred_within_the_same_runtime(self):
        devices = {runtime("26-2"): [phone("z-shutdown"), phone("a-booted", state="Booted")]}
        self.assertEqual(SELECTOR.select_device(devices, "26.2.0"), "a-booted")

    def test_missing_compatible_device_is_a_failure(self):
        with self.assertRaisesRegex(ValueError, "No available iPhone simulator"):
            SELECTOR.select_device({runtime("27-0"): [phone("future")]}, "26.2")


class SimulatorPipelineTests(unittest.TestCase):
    """Run the actual shell/helper with disposable command fixtures, never Xcode or a device."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="munie simulator fixture ")
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("test-ios.sh", "test-available-ios.py", "select-simulator.py"):
            shutil.copy2(SCRIPT.parent / name, scripts / name)
        (scripts / "bootstrap.sh").write_text("#!/bin/bash\nexit 0\n")
        (scripts / "bootstrap.sh").chmod(0o755)
        tools = self.root / "fixture-bin"
        tools.mkdir()
        fixture = '''import json, os, plistlib, sys
from pathlib import Path
name = Path(sys.argv[0]).name
arguments = sys.argv[1:]
with open(os.environ["FIXTURE_CALLS"], "a") as output:
    output.write(json.dumps([name, *arguments]) + "\\n")
failure = os.environ.get("FIXTURE_FAILURE", "")
if name == "xcrun":
    if arguments[:3] == ["simctl", "list", "devices"]:
        print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
            {"udid": "fixture-simulator", "name": "iPhone 17", "isAvailable": True, "state": "Booted"}]}}))
    elif arguments[:2] == ["simctl", "bootstatus"]:
        print("fixture boot output")
        if failure == "boot": sys.exit(69)
    else: sys.exit(99)
elif arguments[:1] == ["-version"]:
    print("27.2")
elif "build-for-testing" in arguments:
    print("fixture build output")
    if failure == "build": sys.exit(65)
    derived = Path(arguments[arguments.index("-derivedDataPath") + 1])
    products = derived / "Build/Products"
    (products / "Debug-iphonesimulator/Munie.app").mkdir(parents=True)
    value = {"__xctestrun_metadata__": {"FormatVersion": 2 if failure == "configuration" else 1},
             "MunieTests": {"IsAppHostedTestBundle": True},
             "MunieUITests": {"IsUITestBundle": True,
                 "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/Munie"}}
    (products / "Munie_fixture-iphonesimulator.xctestrun").write_bytes(plistlib.dumps(value))
    Path(arguments[arguments.index("-resultBundlePath") + 1]).mkdir()
elif "test-without-building" in arguments:
    assert not any("MUNIE_" in key for key in os.environ), "real-model environment reached Xcode"
    value = plistlib.loads(Path(arguments[arguments.index("-xctestrun") + 1]).read_bytes())
    assert value["MunieUITests"]["UITargetAppPath"] == "__TESTROOT__/Debug-iphonesimulator/Munie.app"
    assert "OnlyTestIdentifiers" not in value["MunieTests"]
    assert "OnlyTestIdentifiers" not in value["MunieUITests"]
    print("fixture test output")
    Path(arguments[arguments.index("-resultBundlePath") + 1]).mkdir()
    if failure == "test": sys.exit(65)
else:
    sys.exit(99)
'''
        for name in ("xcodebuild", "xcrun"):
            path = tools / name
            path.write_text("#!" + sys.executable + "\n" + fixture)
            path.chmod(0o755)
        self.environment = dict(os.environ)
        self.environment.update({"PATH": str(tools) + os.pathsep + os.environ["PATH"],
                                 "FIXTURE_CALLS": str(self.root / "commands.jsonl")})
        self.environment.pop("IOS_TEST_DESTINATION", None)

    def tearDown(self):
        self.temporary.cleanup()

    def run_fixture(self, failure=""):
        self.environment["FIXTURE_FAILURE"] = failure
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/test-ios.sh")], cwd=self.root,
                                env=self.environment, capture_output=True, text=True, timeout=15)
        calls = [json.loads(line) for line in (self.root / "commands.jsonl").read_text().splitlines()]
        return result, calls

    def test_build_clone_and_test_keep_default_scope_limits_logs_and_results(self):
        result, calls = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build = next(command for command in calls if "build-for-testing" in command)
        test = next(command for command in calls if "test-without-building" in command)
        self.assertLess(calls.index(build), calls.index(test))
        self.assertIn("CODE_SIGNING_ALLOWED=NO", build)
        self.assertIn("-xctestrun", test)
        self.assertNotIn("-project", test)
        self.assertEqual(test[test.index("-destination") + 1], "platform=iOS Simulator,id=fixture-simulator")
        self.assertEqual(test[test.index("-default-test-execution-time-allowance") + 1], "120")
        self.assertEqual(test[test.index("-maximum-test-execution-time-allowance") + 1], "180")
        self.assertEqual(test[test.index("-destination-timeout") + 1], "90")
        self.assertEqual(test[test.index("-parallel-testing-enabled") + 1], "NO")
        self.assertFalse(any(value.startswith(("-only-testing:", "-skip-testing:")) for value in test))
        log = (self.root / "build/ios-tests.log").read_text()
        self.assertIn("fixture build output", log)
        self.assertIn("fixture test output", log)
        reports = list((self.root / "build").glob("ios-tests.*/test-configuration.json"))
        self.assertEqual(len(reports), 1)
        report = json.loads(reports[0].read_text())
        self.assertEqual((report["status"], report["testScope"]), ("prepared", "default"))
        self.assertTrue(report["originalUnchanged"])
        self.assertTrue((reports[0].parent / "Build.xcresult").is_dir())
        self.assertTrue((reports[0].parent / "Results.xcresult").is_dir())
        self.assertEqual(plistlib.loads(Path(report["original"]).read_bytes())["MunieUITests"]["UITargetAppPath"],
                         "__TESTROOT__/Debug-iphonesimulator/Munie")

    def test_build_failure_stops_before_configuration_or_tests(self):
        result, calls = self.run_fixture("build")
        self.assertEqual(result.returncode, 65)
        self.assertFalse(any("test-without-building" in command for command in calls))
        self.assertNotIn("iOS tests passed", result.stdout)

    def test_opt_in_real_model_environment_cannot_reach_default_test_execution(self):
        self.environment.update({"MUNIE_ACCEPTANCE_INVITATION": "private-fixture",
                                 "TEST_RUNNER_MUNIE_ACCEPTANCE_MODE": "submit",
                                 "TEST_RUNNER_MUNIE_ACCEPTANCE_INVITATION": "private-fixture"})
        result, calls = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any("test-without-building" in command for command in calls))

    def test_configuration_failure_is_recorded_and_stops_before_tests(self):
        result, calls = self.run_fixture("configuration")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any("test-without-building" in command for command in calls))
        reports = list((self.root / "build").glob("ios-tests.*/test-configuration.json"))
        self.assertEqual(json.loads(reports[0].read_text())["status"], "failed")
        self.assertIn("Test configuration failed", (self.root / "build/ios-tests.log").read_text())
        self.assertNotIn("iOS tests passed", result.stdout)

    def test_test_failure_propagates_through_tee_and_retains_logs(self):
        result, _ = self.run_fixture("test")
        self.assertEqual(result.returncode, 65)
        self.assertIn("fixture test output", (self.root / "build/ios-tests.log").read_text())
        self.assertNotIn("iOS tests passed", result.stdout)

    def test_boot_failure_stops_before_build(self):
        result, calls = self.run_fixture("boot")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("build-for-testing" in command for command in calls))


if __name__ == "__main__":
    unittest.main()
