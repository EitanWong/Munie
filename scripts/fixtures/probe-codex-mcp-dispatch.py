"""Disposable app-server control for Munie's process-level extension policy."""
import argparse
import importlib.util
import json
import tempfile
from pathlib import Path


def run(binary, loader, restricted):
    with tempfile.TemporaryDirectory(prefix="munie-native-policy-") as scratch:
        root = Path(scratch).resolve()
        home, project = root / "codex-home", root / "project"
        home.mkdir(mode=0o700)
        project.mkdir(mode=0o700)
        config = home / "config.toml"

        def set_config(model, server):
            marker = root / ("spawn-" + server)
            config.write_text(
                'analytics.enabled=false\nfeedback.enabled=false\n'
                f'model={json.dumps(model)}\nmodel_provider="fixture"\n'
                '[model_providers.fixture]\nname="Local fixture"\n'
                'base_url="http://127.0.0.1:9/v1"\n'
                f'[mcp_servers.{server}]\ncommand="/usr/bin/touch"\nargs=[{json.dumps(str(marker))}]\n',
                encoding="utf-8",
            )
            return marker

        policy = (
            'permissions={munie_probe={filesystem={":minimal"="read",'
            f'{json.dumps(str(home))}="deny",{json.dumps(str(project))}="write"'
            '},network={enabled=false}}}'
        )
        command = [str(binary), "app-server", "--stdio", "-c", 'default_permissions="munie_probe"',
                   "-c", policy]
        env = {"HOME": str(root), "CODEX_HOME": str(home), "PATH": "/usr/bin:/bin"}
        if restricted:
            env["MUNIE_CODEX_DISABLE_EXTERNAL_EXTENSIONS"] = "1"
        first = set_config("fixture-a", "first")

        class Peer(loader.JsonLinePeer):
            def accept_notification(self, frame):
                # This fixture never accepts a server request or sends a turn.
                assert "id" not in frame and isinstance(frame.get("method"), str)

        peer = Peer(command, project, env)
        try:
            def rpc(request_id, method, params):
                response = peer.request({"id": request_id, "method": method, "params": params})
                assert "result" in response, f"Native RPC failed: {method}"
                return response["result"]

            initialized = rpc(1, "initialize", {
                "clientInfo": loader.CLIENT, "capabilities": {"experimentalApi": True}
            })
            assert Path(initialized["codexHome"]).resolve() == home
            peer.send({"method": "initialized"})
            for index, model, marker in ((2, "fixture-a", first), (4, "fixture-b", None)):
                if marker is None:
                    marker = set_config(model, "second")
                    rpc(3, "config/mcpServer/reload", None)
                result = rpc(index, "thread/start", {
                    "cwd": str(project), "ephemeral": True, "permissions": "munie_probe",
                    "approvalPolicy": {"granular": {
                        "sandbox_approval": False, "rules": True, "mcp_elicitations": False,
                        "request_permissions": False, "skill_approval": False,
                    }},
                })
                assert result["activePermissionProfile"]["id"] == "munie_probe"
                assert result["model"] == model
                spawned = marker.is_file()
                print(json.dumps({"restricted": restricted, "model": model, "mcpStarted": spawned}))
                assert spawned != restricted, "MCP observation differs from the control"
        finally:
            peer.close()
            assert peer.cleanup["processGroupGone"] and peer.cleanup["exitStatus"] == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--restricted", action="store_true")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("native_probe", "scripts/probe-codex.py")
    loader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loader)
    run(args.binary.resolve(strict=True), loader, args.restricted)


if __name__ == "__main__":
    main()
