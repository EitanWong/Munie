#!/usr/bin/env python3
"""Exercise a non-escalating approval policy with a local Responses fixture."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile


SCRIPTS = Path(__file__).resolve().parents[1]
BRIDGE = SCRIPTS.parent / "apps/MunieRemodexBridge/src"


def load_turns():
    spec = importlib.util.spec_from_file_location("fixture_turns", SCRIPTS / "probe-codex-turns.py")
    turns = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(turns)
    return turns


def launch_plan(node, env):
    script = """
const {createCodexLaunchPlans} = require(process.argv[1]);
const {SHARED_CODEX_PERMISSIONS, SHARED_CODEX_APPROVAL} = require(process.argv[2]);
const [plan] = createCodexLaunchPlans({env: process.env});
console.log(JSON.stringify({command: plan.command, args: plan.args,
  permissions: SHARED_CODEX_PERMISSIONS, approvalPolicy: SHARED_CODEX_APPROVAL}));
"""
    return json.loads(subprocess.check_output(
        [node, "-e", script, BRIDGE / "codex-transport.js", BRIDGE / "munie-project-policy.js"],
        env=env, timeout=8, text=True,
    ))


def bound_approval_reply(node, frame, root, thread_id, turn_id):
    script = """
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {createSharedCodexApprovalGate} = require(process.argv[1]);
const {root, threadId, turnId, frame} = JSON.parse(fs.readFileSync(0, "utf8"));
const route = Symbol("fixture route");
const gate = createSharedCodexApprovalGate({root, route, threadId, turnId});
const prompt = gate.offer(frame);
const reply = {id: prompt.id, result: {decision: "accept"}};
assert.equal(prompt.params.command, frame.params.command);
assert.equal(prompt.params.cwd, root);
assert.throws(() => gate.reply(reply, Symbol("reconnected route")));
assert.throws(() => gate.reply({...reply, result: {decision: "acceptForSession"}}, route));
const accepted = gate.reply(reply, route);
assert.throws(() => gate.reply(reply, route));
console.log(JSON.stringify(accepted));
"""
    return json.loads(subprocess.check_output(
        [node, "-e", script, BRIDGE / "munie-project-policy.js"],
        input=json.dumps({"root": str(root), "threadId": thread_id, "turnId": turn_id, "frame": frame}),
        timeout=8, text=True,
    ))


def probe(codex, node, mode):
    request_escalation = mode == "escalation"
    turns = load_turns()
    original_sse = turns.sse
    decode_payload = turns.probe.strict_json
    command = "/usr/bin/touch approval-marker"
    policy_denial_seen = False

    def response(item, response_id):
        if not request_escalation and item["type"] == "function_call":
            args = json.loads(item["arguments"])
            del args["sandbox_permissions"], args["justification"]
            item = {**item, "arguments": json.dumps(args)}
        return original_sse(item, response_id)

    turns.sse = response

    def observe_fixture_body(data):
        nonlocal policy_denial_seen
        result = decode_payload(data)
        if request_escalation and type(result) is dict:
            for item in result.get("input", []):
                if (item.get("type") == "function_call_output"
                        and item.get("call_id") == "call_approval-accept"
                        and "you cannot ask for escalated permissions" in str(item.get("output"))):
                    policy_denial_seen = True
        return result

    turns.probe.strict_json = observe_fixture_body

    with tempfile.TemporaryDirectory(prefix="munie-bounded-approval-") as scratch:
        root = Path(scratch).resolve()
        home, project, state = (root / name for name in ("codex", "project", "state"))
        for directory in (home, project, state):
            directory.mkdir(mode=0o700)
        provider = turns.FixtureServer(project)
        peer = None
        try:
            endpoint = f"http://127.0.0.1:{provider.server_port}" + provider.path.removesuffix("/responses")
            (home / "config.toml").write_text(
                'cli_auth_credentials_store="file"\nanalytics.enabled=false\nfeedback.enabled=false\n'
                f'model={json.dumps(turns.MODEL)}\nmodel_provider="munie_fixture"\n'
                '[model_providers.munie_fixture]\nname="Local synthetic fixture"\n'
                f'base_url={json.dumps(endpoint)}\nwire_api="responses"\n'
                'request_max_retries=0\nstream_max_retries=0\n',
                encoding="utf-8",
            )
            rules = home / "rules"
            rules.mkdir()
            (rules / "default.rules").write_text(
                'prefix_rule(pattern=["/usr/bin/touch", "approval-marker"], decision="prompt")\n',
                encoding="utf-8",
            )
            env = {"HOME": str(root), "CODEX_HOME": str(home), "PATH": "/usr/bin:/bin",
                   "TMPDIR": str(root), "REMODEX_CODEX_BINARY": codex,
                   "REMODEX_PROJECT_ROOT": str(project), "MUNIE_HOST_STATE_DIR": str(state),
                   "MUNIE_FOLLOW_CODEX_ACCOUNT": "1", "MUNIE_CODEX_DISABLE_EXTERNAL_EXTENSIONS": "1"}
            plan = launch_plan(node, env)

            class Peer(turns.LifecyclePeer):
                def rpc(self, method, params):
                    if method == "initialize":
                        params = {**params, "capabilities": {"experimentalApi": True}}
                    if method == "thread/start":
                        params = {**params, "approvalPolicy": plan["approvalPolicy"],
                                  "approvalsReviewer": "user", "permissions": plan["permissions"]}
                        del params["sandbox"]
                    self.request_id += 1
                    reply = self.request({"id": self.request_id, "method": method, "params": params})
                    assert type(reply.get("result")) is dict, (method, reply.get("error"))
                    result = reply["result"]
                    if method == "initialize":
                        version = result.get("munieStdioPolicyVersion")
                        assert type(version) is int and version == 1, result
                    if method == "thread/start":
                        assert result["activePermissionProfile"]["id"] == plan["permissions"], result
                        assert result["approvalPolicy"] == plan["approvalPolicy"], result
                    return result

                def accept_notification(self, frame):
                    method, params = frame.get("method"), frame.get("params", {})
                    if "id" not in frame and method in {"configWarning", "deprecationNotice", "warning"}:
                        return
                    if "id" not in frame:
                        return super().accept_notification(frame)
                    assert not request_escalation and self.approval is None, "Unexpected approval request"
                    assert method == "item/commandExecution/requestApproval", method
                    assert params.get("threadId") == self.thread_id, params
                    assert params.get("turnId") == self.turn_id and params.get("itemId") == "call_approval-accept", params
                    assert params.get("command") == f"/bin/sh -c '{command}'", params
                    assert params.get("cwd") == str(self.workspace), params
                    assert "accept" in params.get("availableDecisions", []), params
                    self.approval = frame["id"]
                    self.approval_frame = frame

            peer = Peer([plan["command"], *plan["args"]], project, env)
            peer.initialize(home)
            provider.select("approval-accept")
            peer.start("approval-accept")
            marker = project / "approval-marker"
            if not request_escalation:
                peer.wait_for(lambda: peer.approval is not None or peer.terminal is not None)
                assert not marker.exists() and peer.approval is not None and peer.terminal is None
                if mode == "unavailable":
                    peer.send({
                        "id": peer.approval,
                        "error": {
                            "code": -32000,
                            "message": "Phone callbacks are unavailable in the Codex settings preview.",
                            "data": {"errorCode": "shared_codex_actions_unavailable"},
                        },
                    })
                else:
                    reply = bound_approval_reply(node, peer.approval_frame, project, peer.thread_id, peer.turn_id)
                    assert reply == {"id": peer.approval, "result": {"decision": "accept"}}, reply
                    peer.send(reply)
                    peer.approval_replied = True
            peer.wait_for(lambda: peer.terminal is not None)
            if mode == "unavailable":
                assert peer.resolved and not marker.exists()
                assert peer.command_result != ("completed", 0)
                assert peer.terminal in {"interrupted", "completed"}, peer.terminal
                provider.check(1 if peer.terminal == "interrupted" else 2)
            else:
                provider.check(2)
                assert peer.terminal == "completed" and peer.message is True
            if request_escalation:
                assert policy_denial_seen, "Missing native sandbox escalation rejection"
                assert peer.approval is None and not marker.exists(), "Escalation changed state"
            elif mode == "accept":
                assert peer.resolved and marker.is_file() and peer.command_result == ("completed", 0)
            print(json.dumps({"mode": mode, "turn": peer.terminal,
                              "approvalRequested": peer.approval is not None,
                              "approvalResolved": peer.resolved, "approvedOnce": peer.approval_replied,
                              "projectMarkerWritten": marker.is_file(),
                              "nativePolicyDenialObserved": policy_denial_seen}), flush=True)
        finally:
            try:
                if peer is not None:
                    peer.close()
                    assert peer.cleanup["processGroupGone"] and peer.cleanup["exitStatus"] == 0
            finally:
                provider.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("codex", type=Path)
    parser.add_argument("node", type=Path)
    args = parser.parse_args()
    if not __debug__:
        parser.error("run without Python optimization")
    for mode in ("escalation", "accept", "unavailable"):
        probe(str(args.codex.resolve(strict=True)), str(args.node.resolve(strict=True)), mode)


if __name__ == "__main__":
    main()
