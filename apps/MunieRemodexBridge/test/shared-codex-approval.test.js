const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const { createSharedCodexApprovalGate } = require(process.env.MUNIE_TEST_TASK_POLICY || "../src/munie-project-policy");

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "munie-approval-gate-")));
  t.after(() => fs.rmdirSync(root));
  const route = Symbol("authenticated route");
  let now = 0;
  const gate = createSharedCodexApprovalGate({
    root, route, threadId: "fixture-thread", turnId: "fixture-turn", now: () => now,
  });
  const request = {
    id: 17, method: "item/commandExecution/requestApproval",
    params: {
      kind: "command", command: "/usr/bin/touch fixture-marker", cwd: root,
      threadId: "fixture-thread", turnId: "fixture-turn", itemId: "fixture-item",
      environmentId: "local", availableDecisions: ["accept", "acceptForSession", "decline", "cancel",
        { acceptWithExecpolicyAmendment: { execpolicy_amendment: ["/usr/bin/touch"] } }],
      proposedExecpolicyAmendment: { command: ["/usr/bin/touch"] },
    },
  };
  return { gate, request, route, advance: (amount) => { now += amount; } };
}

test("only the exact host callback is sent to native, once, without a lasting grant", (t) => {
  const { gate, request, route } = fixture(t);
  const prompt = gate.offer(request);
  assert.notEqual(prompt.id, request.id);
  assert.deepEqual(prompt.params, {
    kind: "command", command: request.params.command, cwd: request.params.cwd,
    threadId: request.params.threadId, turnId: request.params.turnId, itemId: request.params.itemId,
    availableDecisions: ["accept", "decline", "cancel"],
  });
  const reply = { id: prompt.id, result: { decision: "accept" } };
  for (const decision of ["acceptForSession", { acceptWithExecpolicyAmendment: {} }]) {
    assert.throws(() => gate.reply({ ...reply, result: { decision } }, route));
  }
  assert.throws(() => gate.reply({ ...reply, result: { decision: "accept", scope: "session" } }, route));
  assert.throws(() => gate.reply(reply, Symbol("different route")));
  assert.throws(() => gate.reply({ ...reply, id: request.id }, route));
  assert.deepEqual(gate.reply(reply, route), { id: 17, result: { decision: "accept" } });
  assert.throws(() => gate.reply(reply, route));
  assert.equal(gate.resolve("17"), null);
  assert.equal(gate.resolve(17), prompt.id);
  assert.equal(gate.resolve(17), null);
  assert.throws(() => gate.offer(request));
});

test("bad native offers cannot create a prompt", (t) => {
  const { gate, request } = fixture(t);
  for (const change of [
    { threadId: "other" }, { turnId: "other" }, { itemId: "" }, { cwd: path.dirname(request.params.cwd) },
    { kind: "stdin" }, { environmentId: "remote" }, { approvalId: "subcommand" },
    { additionalPermissions: {} }, { networkApprovalContext: {} }, { proposedNetworkPolicyAmendments: [] },
    { availableDecisions: ["acceptForSession"] },
  ]) {
    assert.throws(() => gate.offer({ ...request, params: { ...request.params, ...change } }));
  }
  assert.throws(() => gate.offer({ ...request, method: "item/permissions/requestApproval" }));
  assert.ok(gate.offer(request));
});

test("expired, cancelled and revoked requests cannot be accepted", (t) => {
  const { gate, request, route, advance } = fixture(t);
  const first = gate.offer(request);
  advance(120_000);
  assert.throws(() => gate.reply({ id: first.id, result: { decision: "accept" } }, route));
  assert.deepEqual(gate.expire(), [{ nativeId: 17, phoneId: first.id }]);
  assert.deepEqual(gate.expire(), []);
  const next = gate.offer({ ...request, id: "native-2" });
  assert.deepEqual(gate.reply({ id: next.id, result: { decision: "cancel" } }, route),
    { id: "native-2", result: { decision: "cancel" } });
  const last = gate.offer({ ...request, id: "native-3" });
  assert.deepEqual(gate.close(), [
    { nativeId: null, phoneId: next.id },
    { nativeId: "native-3", phoneId: last.id },
  ]);
  assert.deepEqual(gate.close(), []);
  assert.throws(() => gate.reply({ id: last.id, result: { decision: "accept" } }, route));
  assert.throws(() => gate.offer({ ...request, id: "native-4" }));
});
