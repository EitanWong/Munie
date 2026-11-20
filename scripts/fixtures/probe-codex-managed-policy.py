#!/usr/bin/env python3
"""Check managed-policy rejection with the patched standalone debug app-server."""

import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time


INIT = {
    "id": 1, "method": "initialize",
    "params": {"clientInfo": {"name": "munie-managed-fixture", "version": "1"},
               "capabilities": {"experimentalApi": True}},
}
CONFLICT = "Munie's restricted stdio mode cannot enforce this managed hook or MCP policy"
CASES = {
    "compatible": 'allow_remote_control = false\n',
    "managed_hook": (
        'allow_remote_control = false\n'
        '[[hooks.SessionStart]]\n[[hooks.SessionStart.hooks]]\n'
        'type = "command"\ncommand = "/usr/bin/true"\n'
    ),
    "managed_mcp": (
        'allow_remote_control = false\n[mcp_servers.fixture.identity]\n'
        'url = "http://127.0.0.1:9/mcp"\n'
    ),
}


def send(child, frame):
    child.stdin.write((json.dumps(frame) + "\n").encode())
    child.stdin.flush()


def responses(child):
    pending = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        while selector.select(timeout=8):
            chunk = os.read(child.stdout.fileno(), 65536)
            if not chunk:
                return
            pending.extend(chunk)
            if len(pending) > 1024 * 1024:
                raise RuntimeError("fixture output exceeded limit")
            while (boundary := pending.find(b"\n")) >= 0:
                frame = json.loads(pending[:boundary])
                del pending[:boundary + 1]
                yield frame
    raise TimeoutError("debug app-server did not reply")


def read_reply(frames, request_id):
    deadline = time.monotonic() + 8
    for frame in frames:
        if frame.get("id") == request_id:
            return frame
        if time.monotonic() >= deadline:
            raise TimeoutError(f"app-server did not answer request {request_id}")
    return None


def probe(binary, case, restricted):
    incompatible = restricted and case != "compatible"
    with tempfile.TemporaryDirectory(prefix="munie-managed-policy-") as temporary:
        folder = Path(temporary).resolve()
        home = folder / "codex"
        home.mkdir(mode=0o700)
        requirements = folder / "requirements.toml"
        requirements.write_text(CASES[case], encoding="utf-8")
        (home / "config.toml").write_text(
            'cli_auth_credentials_store="file"\nanalytics.enabled=false\nfeedback.enabled=false\n'
            'model_provider="fixture"\n[model_providers.fixture]\n'
            'name="Local fixture"\nbase_url="http://127.0.0.1:9/v1"\nwire_api="responses"\n',
            encoding="utf-8",
        )
        env = {"PATH": "/usr/bin:/bin", "HOME": str(folder), "TMPDIR": str(folder),
               "CODEX_HOME": str(home),
               "CODEX_APP_SERVER_MANAGED_CONFIG_PATH": str(folder / "managed_config.toml")}
        if restricted:
            env["MUNIE_CODEX_DISABLE_EXTERNAL_EXTENSIONS"] = "1"
        with tempfile.TemporaryFile() as diagnostics, subprocess.Popen(
            [binary, "--listen", "stdio://"], cwd=folder, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=diagnostics,
        ) as child:
            frames = responses(child)
            try:
                try:
                    send(child, INIT)
                except BrokenPipeError:
                    if not incompatible:
                        raise
                reply = read_reply(frames, 1)
                initialize = (reply or {}).get("result", {})
                ack = initialize.get("munieStdioPolicyVersion")
                if incompatible:
                    assert reply is None, reply
                else:
                    assert "result" in (reply or {}), reply
                    if restricted:
                        assert type(ack) is int and ack == 1, reply
                    else:
                        assert "munieStdioPolicyVersion" not in initialize, reply
                    send(child, {"method": "initialized"})
                    send(child, {"id": 2, "method": "configRequirements/read", "params": None})
                    result = read_reply(frames, 2)["result"]["requirements"]
                    assert result["allowRemoteControl"] is False, result
                    if case == "managed_hook":
                        assert result["hooks"], result
                    if restricted:
                        for request_id, updated in enumerate(("managed_hook", "managed_mcp"), 3):
                            requirements.write_text(CASES[updated], encoding="utf-8")
                            send(child, {"id": request_id, "method": "thread/start",
                                         "params": {"cwd": str(folder), "ephemeral": True}})
                            failed = read_reply(frames, request_id)
                            assert CONFLICT in failed.get("error", {}).get("message", ""), failed
                            print(json.dumps({"reload": updated, "restricted": True,
                                              "newThreadRejected": True}), flush=True)
                        requirements.write_text(CASES["compatible"], encoding="utf-8")
                        send(child, {"id": 5, "method": "thread/start",
                                     "params": {"cwd": str(folder), "ephemeral": True}})
                        recovered = read_reply(frames, 5)
                        assert recovered and recovered.get("result", {}).get("thread", {}).get("id"), recovered
                        print(json.dumps({"reload": "compatible", "restricted": True,
                                          "newThreadAccepted": True}), flush=True)
                try:
                    child.stdin.close()
                except BrokenPipeError:
                    if not incompatible:
                        raise
                status = child.wait(timeout=8)
                diagnostics.seek(0)
                stderr = diagnostics.read().decode(errors="replace")
                assert status == (1 if incompatible else 0), stderr
                assert (CONFLICT in stderr) == incompatible, stderr
                print(json.dumps({"case": case, "restricted": restricted, "initialized": reply is not None,
                                  "policyVersion": ack, "managedPolicyConflict": incompatible,
                                  "exit": status}), flush=True)
            finally:
                frames.close()
                if child.poll() is None:
                    child.kill()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="patched debug codex-app-server (not codex)")
    args = parser.parse_args()
    if not __debug__:
        parser.error("run without Python optimization so fixture assertions are enabled")
    binary = str(args.binary.resolve(strict=True))
    for case in CASES:
        for restricted in (False, True):
            probe(binary, case, restricted)


if __name__ == "__main__":
    main()
