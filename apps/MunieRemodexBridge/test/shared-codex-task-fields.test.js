const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const {
  bindNativeRequest, SHARED_CODEX_PERMISSIONS, SHARED_CODEX_APPROVAL,
} = require(process.env.MUNIE_TEST_TASK_POLICY || "../src/munie-project-policy");

const follow = { followCodexAccount: true };
const root = fs.realpathSync(os.tmpdir());
const fixed = {
  cwd: root, approvalPolicy: SHARED_CODEX_APPROVAL,
  permissions: SHARED_CODEX_PERMISSIONS,
};
const unsafe = {
  model: "stale-phone-model", effort: "high", serviceTier: "fast",
  runtimeWorkspaceRoots: ["/"], environments: [{ environmentId: "elsewhere" }],
  dynamicTools: [{ name: "not-from-mac" }], developerInstructions: "client-controlled",
  approvalsReviewer: "auto_review", approvalPolicy: "never", permissions: ":danger-full-access",
  sandbox: "danger-full-access", sandboxPolicy: { type: "dangerFullAccess" },
};

test("shared account projects thread start and resume onto Mac-owned settings", () => {
  assert.deepEqual(bindNativeRequest({ id: 1, method: "thread/start", params: unsafe }, root, follow),
    { id: 1, method: "thread/start", params: fixed });
  assert.deepEqual(bindNativeRequest({
    method: "thread/resume", params: {
      ...unsafe, threadId: "existing-thread", excludeTurns: true,
      history: [{ type: "message" }], path: "local-rollout",
    },
  }, root, follow).params, { ...fixed, threadId: "existing-thread", excludeTurns: true });
});

test("shared account accepts plain task text but does not forward runtime or tool overrides", () => {
  const input = [{ type: "text", text: "Run the disposable project check.", text_elements: [] }];
  const params = {
    ...unsafe, threadId: "existing-thread",
    collaborationMode: { mode: "default", settings: { model: "other" } },
    additionalContext: { unchecked: {} }, toolOutput: { itemId: "other" },
    input: input.map((entry) => ({ ...entry, text_elements: [{ extra: "fixture" }], clientExtension: true })),
    remodexRuntimeSettingsVersion: 2,
  };
  const result = bindNativeRequest({ method: "turn/start", params }, root, follow);
  assert.deepEqual(result.params, {
    ...fixed, threadId: "existing-thread", input, remodexRuntimeSettingsVersion: 2,
  });
  assert.equal(params.model, "stale-phone-model");
  delete params.remodexRuntimeSettingsVersion;
  const withoutVersion = bindNativeRequest({ method: "turn/start", params }, root, follow);
  assert.deepEqual(withoutVersion, result);
  assert.throws(() => bindNativeRequest({
    method: "turn/start", params: { ...params, input: [{ type: "localImage", path: "/unknown" }] },
  }, root, follow), /plain text/);
  assert.throws(() => bindNativeRequest({
    method: "turn/start", params: { ...params, input: [{ type: "text", text: "🙂".repeat(32769) }] },
  }, root, follow), /exceeds its limit/);
});

test("shared account interrupts the exact turn and rejects an unbound task ID", () => {
  const params = { threadId: "thread", turnId: "turn" };
  assert.deepEqual(bindNativeRequest({
    method: "turn/interrupt", params: { ...params, ...unsafe },
  }, root, follow).params, params);
  assert.deepEqual(bindNativeRequest({
    method: "turn/interrupt", params: { thread_id: "thread", turn_id: "turn" },
  }, root, follow).params, params);
  assert.throws(() => bindNativeRequest({
    method: "turn/interrupt", params: { ...params, turn_id: "different" },
  }, root, follow), /Conflicting turnId/);
  assert.throws(() => bindNativeRequest({ method: "thread/resume", params: { threadId: " " } },
    root, follow), /threadId/);
  const legacy = bindNativeRequest({
    method: "thread/start", params: { model: "legacy-choice", cwd: root },
  }, root);
  assert.equal(legacy.params.model, "legacy-choice");
});

test("shared account rejects a requested cwd that does not match the Mac project", (t) => {
  const child = fs.mkdtempSync(path.join(root, "munie-task-child-"));
  t.after(() => fs.rmdirSync(child));
  for (const method of ["thread/start", "thread/resume"]) {
    assert.throws(() => bindNativeRequest({ method, params: { cwd: child, threadId: "thread" } },
      root, follow), /Select the requested project on the Mac/);
  }
});
