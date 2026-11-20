"""Compare native hook dispatch using only disposable configuration and loopback Responses."""
import argparse
import importlib.util
import json
import os
import shlex
import tempfile
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--restricted", action="store_true")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("local_turn_fixture", "scripts/probe-codex-turns.py")
    turns = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(turns)

    with tempfile.TemporaryDirectory(prefix="munie-native-hooks-") as scratch:
        root = Path(scratch).resolve()
        home, project = root / "codex-home", root / "project"
        home.mkdir(mode=0o700)
        project.mkdir(mode=0o700)
        provider = turns.FixtureServer(project)
        markers = [root / "configured-hook", root / "legacy-notify"]
        config = home / "config.toml"
        endpoint = f"http://127.0.0.1:{provider.server_port}" + provider.path.removesuffix("/responses")
        config.write_text(
            'analytics.enabled=false\nfeedback.enabled=false\nfeatures.codex_hooks=true\n'
            f'notify=["/usr/bin/touch",{json.dumps(str(markers[1]))}]\n'
            f'model={json.dumps(turns.MODEL)}\nmodel_provider="munie_fixture"\n'
            '[model_providers.munie_fixture]\nname="Local synthetic fixture"\n'
            f'base_url={json.dumps(endpoint)}\nwire_api="responses"\n'
            'request_max_retries=0\nstream_max_retries=0\n'
            '[[hooks.SessionStart]]\n[[hooks.SessionStart.hooks]]\ntype="command"\n'
            f'command={json.dumps("/usr/bin/touch " + shlex.quote(str(markers[0])))}\n',
            encoding="utf-8",
        )
        env = {"HOME": str(root), "CODEX_HOME": str(home), "PATH": "/usr/bin:/bin",
               "TMPDIR": str(root)}
        if args.restricted:
            env["MUNIE_CODEX_DISABLE_EXTERNAL_EXTENSIONS"] = "1"

        class Peer(turns.LifecyclePeer):
            def rpc(self, method, params):
                if method == "thread/start":
                    # This local fixture intentionally trusts its only controlled hook.
                    params = {**params, "config": {"bypass_hook_trust": True}}
                return super().rpc(method, params)

            def accept_notification(self, frame):
                method = frame.get("method")
                if method and (method.startswith("hook/") or method in {"configWarning", "deprecationNotice", "warning"}) and "id" not in frame:
                    return
                if method not in turns.EVENTS and method != "remoteControl/status/changed":
                    print(f"Observed native event method: {method}", flush=True)
                super().accept_notification(frame)

        peer = None
        try:
            peer = Peer([str(args.binary.resolve(strict=True)), "app-server", "--stdio"], project, env)
            peer.initialize(home)
            provider.select("text")
            peer.start("text")
            peer.wait_for(lambda: peer.terminal is not None)
            assert peer.terminal == "completed" and peer.message is True
            provider.check(1)
            limit = time.monotonic() + 2
            while time.monotonic() < limit and (args.restricted or not all(p.exists() for p in markers)):
                time.sleep(0.02)
            result = {"turn": peer.terminal, "restricted": args.restricted,
                      "configuredHookStarted": markers[0].exists(), "legacyNotifyStarted": markers[1].exists()}
            print(json.dumps(result))
            assert all(p.exists() != args.restricted for p in markers), "Hook result differs from the control."
        finally:
            try:
                if peer is not None:
                    peer.close()
                    assert peer.cleanup["processGroupGone"] and peer.cleanup["exitStatus"] == 0
            finally:
                provider.close()


if __name__ == "__main__":
    main()
