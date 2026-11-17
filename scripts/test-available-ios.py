#!/usr/bin/env python3
"""Prefer an available unlocked iPhone; otherwise reuse the existing simulator tests.

This does not run model/recording acceptance, change device settings, remove apps,
or install an SDK. --dry-run probes availability without building or running tests.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

LIMITS = {"probeSeconds": 15, "devicectlSeconds": 10, "maximumDevices": 128,
          "maximumLockProbes": 4, "jsonBytes": 2_097_152, "logBytes": 16_777_216,
          "bootstrapSeconds": 180, "buildSeconds": 1_200, "testSeconds": 900,
          "simulatorSeconds": 1_800, "processCleanupSeconds": 10,
          "destinationSeconds": 45, "defaultTestSeconds": 120, "maximumTestSeconds": 180}
SAFE_TESTS = ("MunieTests/CaptureModelTests", "MunieTests/ShortVoiceInputTests",
              "MunieTests/RemoteNotificationTests",
              "MunieUITests/RemoteFlowTests/testNativeRemoteEntryHasPairingOrKnownConnection",
              "MunieUITests/CaptureFlowTests/testCapturePersistsAcrossLaunchAndCanBeDeleted")


def group_gone(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        # On macOS an exiting, not-yet-reaped group can transiently reject signal 0.
        # This is unknown/live evidence; keep polling, never report it as gone.
        return False


def stop_group(process: subprocess.Popen) -> bool:
    """Only signal this invocation's newly created process group, including surviving children."""
    for requested, seconds in ((signal.SIGTERM, 5), (signal.SIGKILL, 5)):
        if group_gone(process.pid):
            process.wait(timeout=seconds)
            return True
        try:
            os.killpg(process.pid, requested)
        except (ProcessLookupError, PermissionError):
            # A group already exiting can also reject the signal during this window.
            # Reap the child and require an actual ESRCH before accepting cleanup.
            pass
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            process.poll()
            if group_gone(process.pid):
                process.wait(timeout=seconds)
                return True
            time.sleep(0.02)
    return group_gone(process.pid)


class CommandRunner:
    def __init__(self, root: Path):
        self.root = root

    def run(self, command: list[str], *, timeout: int, log: Path, environment: dict) -> dict:
        record = {"command": command, "timeoutSeconds": timeout, "log": str(log),
                  "maximumLogBytes": LIMITS["logBytes"], "exitStatus": None}
        process = None
        started = time.monotonic()
        try:
            with log.open("xb") as output:
                os.chmod(log, 0o600)
                process = subprocess.Popen(command, cwd=self.root, env=environment,
                                           stdin=subprocess.DEVNULL, stdout=output,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                deadline = started + timeout
                while True:
                    if os.fstat(output.fileno()).st_size > LIMITS["logBytes"]:
                        record["failure"] = "output-limit"
                        break
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        record["failure"] = "timeout"
                        break
                    try:
                        process.wait(timeout=min(remaining, 0.2))
                        if os.fstat(output.fileno()).st_size > LIMITS["logBytes"]:
                            record["failure"] = "output-limit"
                        break
                    except subprocess.TimeoutExpired:
                        continue
        except OSError as error:
            record["failure"] = type(error).__name__
        finally:
            if process is not None:
                try:
                    record["processGroupGone"] = stop_group(process)
                except (OSError, subprocess.TimeoutExpired) as error:
                    record["processGroupGone"] = False
                    record["cleanupError"] = {"type": type(error).__name__,
                                              "errno": getattr(error, "errno", None)}
                record["exitStatus"] = process.poll()
                if not record["processGroupGone"]:
                    record["cleanupFailure"] = "process-cleanup"
                    record.setdefault("failure", "process-cleanup")
            record["elapsedSeconds"] = round(time.monotonic() - started, 3)
        return record


def succeeded(record: dict) -> bool:
    return record.get("exitStatus") == 0 and not record.get("failure")


def read_json(path: Path) -> dict:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > LIMITS["jsonBytes"]:
            raise ValueError("Device JSON is not a bounded regular file.")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            data = source.read(LIMITS["jsonBytes"] + 1)
        if len(data) > LIMITS["jsonBytes"]:
            raise ValueError("Device JSON exceeded its bound.")
        value = json.loads(data)
        if (not isinstance(value, dict) or not isinstance(value.get("info"), dict)
                or value["info"].get("outcome") != "success"):
            raise ValueError("Device command did not report success.")
        os.fchmod(descriptor, 0o600)
        return value
    finally:
        os.close(descriptor)


def candidates(value: dict) -> list[dict]:
    result = value.get("result")
    devices = result.get("devices") if isinstance(result, dict) else None
    if not isinstance(devices, list) or len(devices) > LIMITS["maximumDevices"]:
        raise ValueError("Invalid or oversized device inventory.")
    ready = []
    for device in devices:
        if not isinstance(device, dict):
            continue
        hardware = device.get("hardwareProperties", {})
        connection = device.get("connectionProperties", {})
        properties = device.get("deviceProperties", {})
        if not all(isinstance(part, dict) for part in (hardware, connection, properties)):
            continue
        if (hardware.get("reality") != "physical" or hardware.get("deviceType") != "iPhone"
                or hardware.get("platform") != "iOS" or connection.get("tunnelState") != "connected"
                or properties.get("ddiServicesAvailable") is not True):
            continue
        try:
            identifier = str(uuid.UUID(device["identifier"]))
            udid = hardware["udid"]
            if not isinstance(udid, str) or not re.fullmatch(r"[A-Za-z0-9-]{4,80}", udid):
                continue
        except (KeyError, ValueError, TypeError, AttributeError):
            continue
        ready.append({"identifier": identifier, "udid": udid,
                      "wired": connection.get("transportType") == "wired"})
    return sorted(ready, key=lambda item: (not item["wired"], item["identifier"]))


def unlocked(value: dict, identifier: str) -> bool:
    result = value.get("result", {})
    if not isinstance(result, dict):
        return False
    try:
        matches = str(uuid.UUID(result.get("deviceIdentifier", ""))) == identifier
    except (ValueError, TypeError, AttributeError):
        return False
    # This is the observed devicectl lockState schema. Missing/unknown state never permits a test.
    return matches and result.get("passcodeRequired") is False and result.get("unlockedSinceBoot") is True


def development_team(root: Path, environment: dict) -> tuple[str | None, str]:
    value = environment.get("MUNIE_DEVELOPMENT_TEAM", "").strip()
    source = "environment" if value else "unconfigured"
    if not value:
        config = root / "config/Signing.xcconfig"
        if config.is_file():
            for line in config.read_text().splitlines():
                match = re.fullmatch(r"\s*DEVELOPMENT_TEAM\s*=\s*(.*?)\s*", line.split("//", 1)[0])
                if match:
                    value = match.group(1).strip().strip('"')
            if value:
                source = "ignored-signing-config"
    if value and not re.fullmatch(r"[A-Z0-9]{10}", value):
        raise ValueError("The explicit development team must be a ten-character Apple team ID.")
    return value or None, source


def safe_environment(environment: dict) -> dict:
    return {key: value for key, value in environment.items()
            if "MUNIE_" not in key and key not in ("IOS_TEST_DESTINATION", "XCODE_XCCONFIG_FILE")}


def prepare_test_run(products: Path, *, safe_only: bool = True) -> tuple[Path, dict]:
    """Keep generated relative paths valid and preserve the signed build's original plist."""
    sources = sorted(products.glob("Munie_*.xctestrun"))
    if len(sources) != 1:
        raise ValueError("Expected one generated Munie xctestrun in the fresh build products.")
    source = sources[0]
    original = source.read_bytes()
    value = plistlib.loads(original)
    metadata = value.get("__xctestrun_metadata__") if isinstance(value, dict) else None
    if not isinstance(metadata, dict) or metadata.get("FormatVersion") != 1:
        raise ValueError("Only the reviewed format-1 xctestrun is supported.")
    clone = {"__xctestrun_metadata__": copy.deepcopy(metadata)}
    repairs = []
    for name in ("MunieTests", "MunieUITests"):
        target = value.get(name)
        if not isinstance(target, dict):
            raise ValueError("Missing generated test target: " + name)
        target = copy.deepcopy(target)
        if safe_only:
            target["OnlyTestIdentifiers"] = [item.split("/", 1)[1] for item in SAFE_TESTS
                                              if item.startswith(name + "/")]
            target.pop("SkipTestIdentifiers", None)
        for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            if field in target:
                if not isinstance(target[field], dict):
                    raise ValueError("Invalid test environment: " + name)
                target[field] = safe_environment(target[field])
        path = target.get("UITargetAppPath")
        if isinstance(path, str) and path.startswith("__TESTROOT__/"):
            actual = products / path.removeprefix("__TESTROOT__/")
            appended = Path(str(actual) + ".app")
            if (not actual.is_dir() and not path.endswith(".app") and appended.is_dir()
                    and appended.resolve().is_relative_to(products.resolve())):
                target["UITargetAppPath"] = path + ".app"
                repairs.append({"target": name, "field": "UITargetAppPath",
                                "old": path, "new": target["UITargetAppPath"]})
        clone[name] = target
    destination = products / ("Munie_available-" + uuid.uuid4().hex + ".xctestrun")
    with destination.open("xb") as output:
        os.chmod(destination, 0o600)
        plistlib.dump(clone, output)
    original_hash = hashlib.sha256(original).hexdigest()
    unchanged = hashlib.sha256(source.read_bytes()).hexdigest() == original_hash
    if not unchanged or plistlib.loads(destination.read_bytes()) != clone:
        raise ValueError("Test configuration verification failed.")
    return destination, {"original": str(source), "originalSHA256": original_hash,
                         "originalUnchanged": unchanged, "clone": str(destination),
                         "cloneSHA256": hashlib.sha256(destination.read_bytes()).hexdigest(),
                         "pathRepairs": repairs, "testScope": "safe" if safe_only else "default"}


def save_report(output: Path, report: dict) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".ios-available-", dir=output.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)


def execute(root: Path, evidence: Path, *, dry_run: bool, environment: dict, runner=None) -> dict:
    runner = runner or CommandRunner(root)
    report = {"schemaVersion": 1, "status": "failed", "mode": "undetermined", "device": None,
              "dryRun": dry_run, "limits": dict(LIMITS), "commands": [],
              "scope": "Non-model app tests and native entry/capture UI; no microphone/cellular acceptance."}
    clean_environment = safe_environment(environment)

    def command(arguments, timeout, name):
        result = runner.run(arguments, timeout=timeout, log=evidence / (name + ".log"),
                            environment=clean_environment)
        report["commands"].append(result)
        return result

    def probe(arguments, name):
        destination = evidence / (name + ".json")
        result = command(["xcrun", "devicectl", *arguments, "--timeout",
                          str(LIMITS["devicectlSeconds"]), "--json-output", str(destination)],
                         LIMITS["probeSeconds"], name)
        if not succeeded(result):
            return None
        try:
            return read_json(destination)
        except (OSError, ValueError, TypeError, AttributeError):
            result["jsonFailure"] = "unavailable-or-invalid"
            return None

    inventory = probe(["list", "devices"], "device-inventory")
    report["reason"] = "inventory-unavailable" if inventory is None else "no-ready-physical-iphone"
    try:
        available = candidates(inventory) if inventory is not None else []
    except (ValueError, AttributeError):
        available = []
        report["reason"] = "invalid-device-inventory"
    for index, device in enumerate(available[:LIMITS["maximumLockProbes"]]):
        lock = probe(["device", "info", "lockState", "--device", device["identifier"]],
                     "device-lock-" + str(index))
        if lock is not None and unlocked(lock, device["identifier"]):
            report["device"] = device
            break
        report["reason"] = "physical-iphone-locked-or-lock-state-unavailable"
    try:
        team, source = development_team(root, environment)
    except (OSError, ValueError) as error:
        report["failure"] = str(error)
        return report
    report["signingSource"] = source
    if report["device"] is not None and team:
        report["mode"] = "physical"
        report["reason"] = "connected-ddi-ready-unlocked-iphone-with-explicit-signing"
    else:
        report["mode"] = "simulator"
        if report["device"] is not None:
            report["reason"] = "physical-iphone-signing-unconfigured"
    if dry_run:
        report["status"] = "selected"
        return report
    if report["mode"] == "simulator":
        result = command([str(root / "scripts/test-ios.sh")], LIMITS["simulatorSeconds"], "simulator-tests")
        report["status"] = "passed" if succeeded(result) else "failed"
        return report

    # A ready physical device is now bound. Signing/build/install/test failure never falls back.
    if not succeeded(command([str(root / "scripts/bootstrap.sh")], LIMITS["bootstrapSeconds"], "bootstrap")):
        return report
    derived = evidence / "DerivedData"
    destination = "platform=iOS,id=" + report["device"]["udid"]
    common = ["xcodebuild", "-project", str(root / "Munie.xcodeproj"), "-scheme", "Munie",
              "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(derived),
              "-destination-timeout", str(LIMITS["destinationSeconds"]), "-parallel-testing-enabled", "NO"]
    build = common + ["DEVELOPMENT_TEAM=" + team, "CODE_SIGN_STYLE=Automatic", "CODE_SIGNING_ALLOWED=YES",
                      "-resultBundlePath", str(evidence / "Build.xcresult"), "build-for-testing"]
    if not succeeded(command(build, LIMITS["buildSeconds"], "physical-build")):
        return report
    try:
        test_run, report["testConfiguration"] = prepare_test_run(derived / "Build/Products")
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        report["failure"] = "test-configuration: " + str(error)
        return report
    test = ["xcodebuild", "-xctestrun", str(test_run), "-destination", destination,
            "-destination-timeout", str(LIMITS["destinationSeconds"]), "-parallel-testing-enabled", "NO",
            "-resultBundlePath", str(evidence / "Tests.xcresult"), "-test-timeouts-enabled", "YES",
                     "-default-test-execution-time-allowance", str(LIMITS["defaultTestSeconds"]),
                     "-maximum-test-execution-time-allowance", str(LIMITS["maximumTestSeconds"])]
    test += ["-only-testing:" + selector for selector in SAFE_TESTS]
    test += ["-skip-testing:MunieTests/RemoteDeviceAcceptanceTests",
             "-skip-testing:MunieUITests/RemoteFlowTests/testPairedRealTaskAndRestartRecovery",
             "test-without-building"]
    report["status"] = "passed" if succeeded(command(test, LIMITS["testSeconds"], "physical-tests")) else "failed"
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--dry-run", action="store_true", help="Probe and report selection; do not build/run tests.")
    action.add_argument("--prepare-config", type=Path,
                        help="Only clone generated build products' xctestrun; print the clone path, with no device probe.")
    parser.add_argument("--test-scope", choices=("safe", "default"), default="safe",
                        help="For --prepare-config: safe selectors, or preserve the generated default test selection.")
    parser.add_argument("--report", type=Path, help="Report path inside this checkout's ignored build directory.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    build = (root / "build").resolve()
    build.mkdir(parents=True, exist_ok=True)
    output = args.report.expanduser().resolve() if args.report else build / "ios-available-tests.json"
    if not output.is_relative_to(build):
        parser.error("--report must remain inside this checkout's ignored build directory.")
    output.parent.mkdir(parents=True, exist_ok=True)
    if args.prepare_config is not None:
        products = args.prepare_config.expanduser().resolve()
        if not products.is_relative_to(build):
            parser.error("--prepare-config must remain inside this checkout's ignored build directory.")
        try:
            clone, record = prepare_test_run(products, safe_only=args.test_scope == "safe")
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
            save_report(output, {"status": "failed", "mode": "prepare-test-configuration", "failure": str(error)})
            print("Test configuration failed: " + str(error), file=sys.stderr)
            return 1
        save_report(output, {"status": "prepared", "mode": "prepare-test-configuration", **record})
        print(clone)
        return 0
    if args.test_scope != "safe":
        parser.error("--test-scope applies only with --prepare-config.")
    evidence = Path(tempfile.mkdtemp(prefix="ios-available-", dir=build))
    started = datetime.now(timezone.utc).isoformat()
    report = execute(root, evidence, dry_run=args.dry_run, environment=dict(os.environ))
    report.update({"startedAt": started, "finishedAt": datetime.now(timezone.utc).isoformat(),
                   "evidenceDirectory": str(evidence)})
    save_report(output, report)
    print(json.dumps({"status": report["status"], "mode": report["mode"], "reason": report.get("reason"),
                      "device": report["device"]["udid"] if report.get("device") else None, "report": str(output)}))
    return 0 if report["status"] in ("passed", "selected") else 1


if __name__ == "__main__":
    raise SystemExit(main())
