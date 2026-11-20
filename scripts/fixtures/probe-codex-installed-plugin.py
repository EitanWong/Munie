#!/usr/bin/env python3
"""Compare installed PreToolUse dispatch with an isolated native Codex peer."""

import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import tempfile


def load_fixture():
    source = Path(__file__).resolve().parents[1] / "probe-codex-turns.py"
    spec = importlib.util.spec_from_file_location("fixture_turns", source)
    turns = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(turns)
    original_sse = turns.sse

    def command_without_escalation(item, response_id):
        if item["type"] == "function_call":
            args = json.loads(item["arguments"])
            del args["sandbox_permissions"], args["justification"]
            item = {**item, "arguments": json.dumps(args)}
        return original_sse(item, response_id)

    turns.sse = command_without_escalation
    return turns


def install_fixture(home, marker):
    plugin = home / "plugins/cache/test/sample/local"
    manifest = plugin / ".codex-plugin"
    hooks = plugin / "hooks"
    manifest.mkdir(parents=True)
    hooks.mkdir()
    (manifest / "plugin.json").write_text('{"name":"sample"}\n', encoding="utf-8")
    handler = {"type": "command", "command": f"/usr/bin/touch {shlex.quote(str(marker))}"}
    (hooks / "hooks.json").write_text(json.dumps({"hooks": {
        "PreToolUse": [{"matcher": "^Bash$", "hooks": [handler]}],
    }}), encoding="utf-8")


def probe(binary, turns, restricted):
    class Peer(turns.LifecyclePeer):
        def rpc(self, method, params):
            if method == "initialize":
                params = {**params, "capabilities": {"experimentalApi": True}}
            if method == "thread/start":
                params = {**params, "approvalPolicy": "never", "sandbox": "workspace-write",
                          "config": {"bypass_hook_trust": True}}
            result = super().rpc(method, params)
            if method == "initialize":
                if restricted:
                    version = result.get("munieStdioPolicyVersion")
                    assert type(version) is int and version == 1, result
                else:
                    assert "munieStdioPolicyVersion" not in result, result
            return result

        def accept_notification(self, frame):
            method = frame.get("method", "")
            if "id" not in frame and (method.startswith("hook/") or method in {
                "configWarning", "deprecationNotice", "warning"
            }):
                return
            super().accept_notification(frame)

    with tempfile.TemporaryDirectory(prefix="munie-plugin-fixture-") as scratch:
        root = Path(scratch).resolve()
        home, project = root / "codex", root / "project"
        project.mkdir(mode=0o700)
        marker = root / "plugin-pre-tool-use"
        install_fixture(home, marker)
        provider = turns.FixtureServer(project)
        peer = None
        try:
            endpoint = f"http://127.0.0.1:{provider.server_port}" + provider.path.removesuffix("/responses")
            (home / "config.toml").write_text(
                'cli_auth_credentials_store="file"\nanalytics.enabled=false\nfeedback.enabled=false\n'
                'features.codex_hooks=true\nfeatures.plugins=true\n'
                f'model={json.dumps(turns.MODEL)}\nmodel_provider="munie_fixture"\n'
                '[plugins."sample@test"]\nenabled=true\n'
                '[model_providers.munie_fixture]\nname="Local synthetic fixture"\n'
                f'base_url={json.dumps(endpoint)}\nwire_api="responses"\n'
                'request_max_retries=0\nstream_max_retries=0\n',
                encoding="utf-8",
            )
            env = {"HOME": str(root), "CODEX_HOME": str(home), "PATH": "/usr/bin:/bin",
                   "TMPDIR": str(root)}
            if restricted:
                env["MUNIE_CODEX_DISABLE_EXTERNAL_EXTENSIONS"] = "1"
            peer = Peer([binary, "app-server", "--stdio"], project, env)
            peer.initialize(home)
            provider.select("approval-accept")
            peer.start("approval-accept")
            peer.wait_for(lambda: peer.terminal is not None)
            provider.check(2)
            assert peer.terminal == "completed" and peer.message is True
            assert peer.command_result == ("completed", 0), peer.command_result
            assert (project / "approval-marker").is_file()
            assert marker.is_file() != restricted, "Plugin hook result differs from the control"
            print(json.dumps({"restricted": restricted, "turn": peer.terminal,
                              "commandExit": peer.command_result[1],
                              "pluginPreToolUseRan": marker.is_file()}), flush=True)
        finally:
            try:
                if peer is not None:
                    peer.close()
                    assert peer.cleanup["processGroupGone"] and peer.cleanup["exitStatus"] == 0
            finally:
                provider.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="pinned Codex CLI with the Munie patch")
    args = parser.parse_args()
    if not __debug__:
        parser.error("run without Python optimization")
    binary = str(args.binary.resolve(strict=True))
    turns = load_fixture()
    for restricted in (False, True):
        probe(binary, turns, restricted)


if __name__ == "__main__":
    main()
