#!/usr/bin/env python3
"""Opt-in actual iPhone HTTPS/text/restart acceptance; never UI, voice or cellular evidence."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import urlsplit

PAIR = re.compile(r"MUNIE_DEVICE_PAIR ([0-9A-Fa-f-]{36}) ([0-9a-f]{16})")
RESULT = re.compile(r"MUNIE_DEVICE_RESULT ([0-9A-Fa-f-]{36}) ([0-9]+) completed")
RECOVERED = re.compile(r"MUNIE_DEVICE_RECOVERED ([0-9A-Fa-f-]{36}) ([0-9]+) completed")
MARKER = "MUNIE_PHONE_REAL_OK"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1_048_576), b""):
            value.update(chunk)
    return value.hexdigest()


def write_private(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def save_report(path: Path, value: dict) -> None:
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        write_private(temporary, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare_test_run(original: dict, variables: dict[str, str], selector: str) -> dict:
    """Only the app-hosted unit bundle remains; no separate runner app is installed."""
    if original.get("__xctestrun_metadata__", {}).get("FormatVersion") != 1:
        raise ValueError("Only the reviewed format-1 xctestrun is supported.")
    if "MunieTests" not in original or not original["MunieTests"].get("IsAppHostedTestBundle"):
        raise ValueError("The signed app-hosted MunieTests bundle is required.")
    result = {"MunieTests": copy.deepcopy(original["MunieTests"]),
              "__xctestrun_metadata__": copy.deepcopy(original["__xctestrun_metadata__"])}
    test = result["MunieTests"]
    test["DependentProductPaths"] = [value for value in test.get("DependentProductPaths", [])
                                     if "MunieUITests" not in value]
    test["ProcessNamesForCrashReportCollection"] = ["Munie"]
    test["BundleIdentifiersForCrashReportEmphasis"] = ["app.munie.ios", "app.munie.tests"]
    test.setdefault("EnvironmentVariables", {}).update(variables)
    test["OnlyTestIdentifiers"] = [selector]
    test.pop("SkipTestIdentifiers", None)
    test["TestTimeoutsEnabled"] = True
    test["DefaultTestExecutionTimeAllowance"] = 330
    test["MaximumTestExecutionTimeAllowance"] = 330
    test["SystemAttachmentLifetime"] = "keepNever"
    test["UserAttachmentLifetime"] = "keepNever"
    test.pop("DiagnosticCollectionPolicy", None)
    metadata = result["__xctestrun_metadata__"]
    metadata["CodeCoverageBuildableInfos"] = [value for value in metadata.get("CodeCoverageBuildableInfos", [])
                                               if "MunieUITests" not in value.get("Name", "")]
    return result


def group_gone(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        return False


def stop_process(process: subprocess.Popen, grace: float = 5) -> bool:
    for requested_signal, timeout in ((signal.SIGTERM, grace), (signal.SIGKILL, 5)):
        if process.poll() is not None:
            break
        try:
            os.killpg(process.pid, requested_signal)
        except (ProcessLookupError, PermissionError):
            # Darwin may deny signalling a leader that is concurrently exiting.
            # Reap it and then independently verify disappearance of its group.
            pass
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if requested_signal == signal.SIGKILL:
                return False
    # Reap descendants still in this operation's own process group, never unrelated processes.
    if not group_gone(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            return False
        deadline = time.monotonic() + 5
        while not group_gone(process.pid) and time.monotonic() < deadline:
            time.sleep(0.02)
    return group_gone(process.pid)


class LocalHost:
    def __init__(self, executable: Path, configuration: Path, stderr_path: Path):
        self.stderr = stderr_path.open("xb")
        self.selector = None
        self.process = None
        try:
            os.chmod(stderr_path, 0o600)
            self.selector = selectors.DefaultSelector()
            self.process = subprocess.Popen([str(executable), "--configuration", str(configuration)],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=self.stderr, start_new_session=True)
            self.selector.register(self.process.stdout, selectors.EVENT_READ)
        except BaseException:
            try:
                if self.process is not None:
                    stop_process(self.process)
            finally:
                if self.process is not None:
                    self.process.stdin.close()
                    self.process.stdout.close()
                if self.selector is not None:
                    self.selector.close()
                self.stderr.close()
            raise
        self.buffer = b""
        self.closed = False

    def read(self, timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Local service response deadline exceeded.")
            if not self.selector.select(min(remaining, 1)):
                continue
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Local service exited before its response.")
            self.buffer += chunk
            if len(self.buffer) > 2_097_152:
                raise RuntimeError("Local service response exceeded its bound.")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def command(self, op: str, **fields) -> dict:
        body = json.dumps({"op": op, **fields}, separators=(",", ":")).encode() + b"\n"
        self.process.stdin.write(body)
        self.process.stdin.flush()
        reply = self.read(20 if op == "quit" else 10)
        if reply.get("event") == "operationFailed":
            raise RuntimeError("Local service rejected an administrative fixture operation.")
        return reply

    def finish(self) -> dict:
        result = {"graceful": False, "processGroupGone": False}
        try:
            if self.process.poll() is None:
                reply = self.command("quit")
                result["graceful"] = reply.get("event") == "closed"
                self.process.wait(timeout=10)
        except Exception:
            pass
        finally:
            try:
                result["processGroupGone"] = stop_process(self.process)
            except Exception as error:
                result["cleanupFailureType"] = type(error).__name__
            finally:
                result["exitStatus"] = self.process.poll()
                self.selector.close()
                self.process.stdin.close()
                self.process.stdout.close()
                self.stderr.close()
                self.closed = True
        return result


def run_device_phase(*, xctestrun: Path, device: str, selector: str, result_path: Path,
                     log_path: Path, timeout: int, host: LocalHost, project_id: str,
                     invitation_json: str, approve: bool, record: dict) -> dict:
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
               "-destination", f"platform=iOS,id={device}", "-only-testing:MunieTests/" + selector,
               "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result_path),
               "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "330"]
    # Establish local evidence first, so an unwritable log cannot orphan xcodebuild.
    with log_path.open("xb") as log:
        os.chmod(log_path, 0o600)
        monitor = selectors.DefaultSelector()
        process = None
        approved = False
        outcome = None
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            record["xcodebuildPID"] = process.pid
            monitor.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + timeout
            pending = None
            recent = ""
            captured = 0
            last_candidate_check = 0.0
            while True:
                if time.monotonic() > deadline:
                    raise TimeoutError("The physical-device test invocation exceeded its bound.")
                if monitor.select(0.25):
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    captured += len(chunk)
                    if captured > 16_777_216:
                        raise RuntimeError("The physical-device log exceeded its bound.")
                    text = chunk.decode("utf-8", errors="replace")
                    # Private inputs are never intentionally printed; mask the exact env value defensively.
                    text = text.replace(invitation_json, "[PRIVATE_INVITATION]")
                    log.write(text.encode())
                    log.flush()
                    recent = (recent + text)[-131072:]
                    if approve:
                        for candidate in PAIR.finditer(recent):
                            observed = (str(uuid.UUID(candidate.group(1))), candidate.group(2))
                            if pending is not None and pending != observed:
                                raise RuntimeError("The phone changed its pairing identity during acceptance.")
                            pending = observed
                    for match in (RESULT if approve else RECOVERED).finditer(recent):
                        observed = {"taskID": str(uuid.UUID(match.group(1))),
                                    "appPID": int(match.group(2)), "phase": "completed"}
                        if outcome is not None and outcome != observed:
                            raise RuntimeError("The phone emitted inconsistent task result evidence.")
                        outcome = observed
                elif process.poll() is not None:
                    break
                if approve and pending and not approved and time.monotonic() - last_candidate_check >= 0.5:
                    last_candidate_check = time.monotonic()
                    candidate = host.command("candidate").get("candidate")
                    if candidate is not None:
                        exact = (str(uuid.UUID(candidate["id"])), candidate["fingerprint"])
                        if exact != pending:
                            raise RuntimeError("Mac and iPhone pairing identifiers/fingerprints do not match.")
                        if host.command("approvePairing", projectIDs=[project_id]).get("event") != "paired":
                            raise RuntimeError("Mac did not confirm the exact phone fixture.")
                        approved = True
            exit_status = process.wait(timeout=10)
            if exit_status != 0 or outcome is None or (approve and not approved):
                raise RuntimeError("Physical-device unit test failed or omitted its required evidence.")
            outcome.update({"xcodebuildExitStatus": exit_status, "pairingMatched": approved if approve else None})
            return outcome
        finally:
            cleanup = True
            if process is not None:
                try:
                    cleanup = stop_process(process)
                except Exception as error:
                    cleanup = False
                    record["cleanupFailureType"] = type(error).__name__
                finally:
                    record["xcodebuildExitStatus"] = process.returncode
                    record["processGroupGone"] = cleanup
                    process.stdout.close()
            record["pairingMatched"] = approved if approve else None
            if outcome is not None:
                record.update(outcome)
            monitor.close()
            if not cleanup and sys.exc_info()[0] is None:
                raise RuntimeError("The xcodebuild process group did not disappear.")


def ledger_count(directory: Path) -> int:
    database = directory / "ledger" / "submissions.sqlite3"
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2) as connection:
        return connection.execute("SELECT count(*) FROM requests").fetchone()[0]


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allow-real-model", action="store_true", help="Required owner authorization gate.")
    for name in ("service", "codex", "guardian", "xctestrun", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--device", required=True, help="Explicit connected physical iPhone identifier.")
    parser.add_argument("--endpoint", required=True, help="Explicit HTTPS origin served by this Mac.")
    parser.add_argument("--keep-fixture-pairing", action="store_true")
    parser.add_argument("--first-timeout", type=int, default=420)
    parser.add_argument("--recovery-timeout", type=int, default=180)
    result = parser.parse_args()
    if not result.allow_real_model:
        parser.error("--allow-real-model is required; this runner consumes the authorized Codex account.")
    if not all(60 <= value <= 900 for value in (result.first_timeout, result.recovery_timeout)):
        parser.error("Device invocation limits must be between 60 and 900 seconds.")
    endpoint = urlsplit(result.endpoint)
    if (endpoint.scheme != "https" or not endpoint.hostname or endpoint.username or endpoint.password
            or endpoint.query or endpoint.fragment or endpoint.path not in ("", "/")):
        parser.error("--endpoint must be the explicit HTTPS origin served by this Mac.")
    if not re.fullmatch(r"[A-Za-z0-9-]{4,80}", result.device):
        parser.error("--device must be an explicit connected device identifier.")
    return result


def main() -> int:
    args = arguments()
    args.output = args.output.expanduser().resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "status": "failed", "stage": "starting",
              "startedAt": datetime.now(timezone.utc).isoformat(), "deviceID": args.device,
              "scope": "physical iPhone native HTTPS/text/Keychain/relaunch; not UI gestures, voice, cellular or push"}
    save_report(args.output, report)
    root = Path(__file__).resolve().parents[1]
    evidence = args.output.parent / (args.output.stem + "-private-" + uuid.uuid4().hex)
    evidence.mkdir(mode=0o700)
    host = None
    private_runs = []
    temporary = None
    original_hash = None
    try:
        for name in ("service", "codex", "guardian", "xctestrun"):
            path = getattr(args, name).expanduser().resolve(strict=True)
            if not path.is_file() or (name != "xctestrun" and not os.access(path, os.X_OK)):
                raise ValueError("An explicit built executable or signed test-run file is unavailable.")
            setattr(args, name, path)
        original_hash = digest(args.xctestrun)
        original = plistlib.loads(args.xctestrun.read_bytes())
        prepare_test_run(original, {}, "RemoteDeviceAcceptanceTests/testPairSubmitRealTask")
        report["hashes"] = {name: digest(getattr(args, name)) for name in ("service", "codex", "guardian", "xctestrun")}
        report["hashes"].update({"runner": digest(Path(__file__)),
            "phoneTestSource": digest(root / "apps/MunieTests/RemoteDeviceAcceptanceTests.swift")})
        temporary = tempfile.TemporaryDirectory(prefix="munie-iphone-product-")
        work = Path(temporary.name).resolve(strict=True)
        project = work / "project"
        project.mkdir(mode=0o700)
        subprocess.run(["git", "init", "--quiet", str(project)], check=True, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        host_id, project_id = str(uuid.uuid4()), str(uuid.uuid4())
        state = work / "state"
        configuration = work / "host.json"
        config = {"hostID": host_id, "stateDirectory": state.as_uri(),
            "codexHome": (work / "native-account").as_uri(), "executable": args.codex.as_uri(),
            "guardian": args.guardian.as_uri(), "projects": [{"id": project_id,
            "name": "Disposable iPhone acceptance", "directory": project.as_uri()}],
            "endpoint": args.endpoint, "port": 9274}
        write_private(configuration, json.dumps(config).encode())
        report["stage"] = "host-start"
        save_report(args.output, report)
        host = LocalHost(args.service, configuration, evidence / "host.stderr.log")
        if host.read(60).get("event") != "ready":
            raise RuntimeError("The disposable Mac service did not become ready.")
        invitation = host.command("invite").get("invitation")
        if not isinstance(invitation, dict):
            raise RuntimeError("The disposable host did not issue a pairing invitation.")
        invitation_json = json.dumps(invitation, separators=(",", ":"))
        submit_selector = "RemoteDeviceAcceptanceTests/testPairSubmitRealTask"
        first_path = args.xctestrun.parent / ("MunieDeviceAcceptance-" + uuid.uuid4().hex + ".xctestrun")
        first = prepare_test_run(original, {"MUNIE_DEVICE_ACCEPTANCE_MODE": "submit",
            "MUNIE_DEVICE_INVITATION": invitation_json}, submit_selector)
        write_private(first_path, plistlib.dumps(first, fmt=plistlib.FMT_BINARY))
        private_runs.append(first_path)
        report["stage"] = "phone-pair-submit"
        save_report(args.output, report)
        first_result = run_device_phase(xctestrun=first_path, device=args.device, selector=submit_selector,
            result_path=evidence / "submit.xcresult", log_path=evidence / "submit.log",
            timeout=args.first_timeout, host=host, project_id=project_id,
            invitation_json=invitation_json, approve=True, record=report.setdefault("submit", {}))
        if ledger_count(state) != 1:
            raise RuntimeError("The actual native ledger must contain exactly one accepted request.")
        recovery_selector = "RemoteDeviceAcceptanceTests/testRecoverSameTaskAfterProcessRestart"
        second_path = args.xctestrun.parent / ("MunieDeviceAcceptance-" + uuid.uuid4().hex + ".xctestrun")
        variables = {"MUNIE_DEVICE_ACCEPTANCE_MODE": "recover", "MUNIE_DEVICE_EXPECTED_TASK_UUID": first_result["taskID"],
            "MUNIE_DEVICE_EXPECTED_HOST_UUID": host_id,
            "MUNIE_DEVICE_CLEAR_FIXTURE_CREDENTIAL": "0" if args.keep_fixture_pairing else "1"}
        second = prepare_test_run(original, variables, recovery_selector)
        write_private(second_path, plistlib.dumps(second, fmt=plistlib.FMT_BINARY))
        private_runs.append(second_path)
        report["stage"] = "phone-new-process-recovery"
        save_report(args.output, report)
        recovery = run_device_phase(xctestrun=second_path, device=args.device, selector=recovery_selector,
            result_path=evidence / "recovery.xcresult", log_path=evidence / "recovery.log",
            timeout=args.recovery_timeout, host=host, project_id=project_id,
            invitation_json=invitation_json, approve=False, record=report.setdefault("recovery", {}))
        if recovery["taskID"] != first_result["taskID"] or recovery["appPID"] == first_result["appPID"]:
            raise RuntimeError("Recovery must observe the same task in a different native app process.")
        status = host.command("status").get("status", {})
        tasks = status.get("tasks", [])
        if len(tasks) != 1 or str(uuid.UUID(tasks[0]["id"])) != first_result["taskID"]:
            raise RuntimeError("Recovery changed the authoritative host task count or identity.")
        if not any(item.get("role") == "assistant" and item.get("text", "").strip() == MARKER
                   for item in tasks[0].get("messages", [])):
            raise RuntimeError("The Mac did not retain the exact real assistant result.")
        count = ledger_count(state)
        if count != 1:
            raise RuntimeError("A new request was accepted during restart recovery.")
        report["ledgerRequestCountAfterRecovery"] = count
        diagnostics = host.command("diagnostics").get("diagnostics", {})
        report["nativeCleanup"] = {key: diagnostics.get(key) for key in
            ("groupGone", "stdoutEOF", "stderrEOF", "leaderExitStatus", "escalated")}
        if not all(diagnostics.get(key) is True for key in ("groupGone", "stdoutEOF", "stderrEOF")):
            raise RuntimeError("Native process/stream cleanup was not confirmed.")
        report["status"] = "passed"
        report["stage"] = "completed"
    except Exception as error:
        report["failureType"] = type(error).__name__
        report["status"] = "failed"
    finally:
        cleanup = {"privateTestRunsRemoved": True, "temporaryAccountAndProjectRemoved": False}
        if host is not None:
            try:
                cleanup["host"] = host.finish()
            except Exception as error:
                cleanup["host"] = {"graceful": False, "processGroupGone": False,
                                   "cleanupFailureType": type(error).__name__}
            if not cleanup["host"].get("graceful") or not cleanup["host"].get("processGroupGone"):
                report["status"] = "failed"
        for path in private_runs:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                cleanup["privateTestRunsRemoved"] = False
                report["status"] = "failed"
        if temporary is not None:
            location = Path(temporary.name)
            try:
                temporary.cleanup()
                cleanup["temporaryAccountAndProjectRemoved"] = not location.exists()
            except OSError:
                report["status"] = "failed"
        if original_hash is not None:
            cleanup["originalTestRunUnchanged"] = args.xctestrun.exists() and digest(args.xctestrun) == original_hash
            if not cleanup["originalTestRunUnchanged"]:
                report["status"] = "failed"
        report["cleanup"] = cleanup
        report["privateEvidenceDirectory"] = str(evidence)
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        save_report(args.output, report)
    print(f"{report['status'].upper()}: native iPhone product acceptance report {args.output}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
