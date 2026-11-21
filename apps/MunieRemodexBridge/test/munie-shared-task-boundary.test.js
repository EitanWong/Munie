const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const { SHARED_CODEX_PERMISSIONS } = require("../src/munie-project-policy");
const { createSharedCodexTaskBoundary } = require("../src/munie-shared-task-boundary");

function harness(t, { crossRouteStop = true } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "munie-shared-task-"));
  const root = path.join(fs.realpathSync(dir), "project");
  fs.mkdirSync(root);
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  let route = Symbol("original"), phone = "trusted-phone", pending = false, time = 0, nextID = 0;
  const toPhone = [], toNative = [];
  const boundary = createSharedCodexTaskBoundary({
    root, currentRoute: () => route,
    ...(crossRouteStop ? { currentPhone: () => phone } : {}),
    sendNative(frame) { toNative.push(frame); },
    sendPhone(frame) { toPhone.push(frame); return true; },
    cancellationPending(threadId, turnId) { return pending && threadId === "thread" && turnId === "turn"; },
    now: () => time,
  });
  const request = (method, params = {}) => ({
    id: `bridge-${nextID++}`, method, params: { cwd: root, permissions: SHARED_CODEX_PERMISSIONS, ...params },
  });
  const opened = (req, threadId = "thread", overrides = {}) => ({
    id: req.id, result: { cwd: root, thread: { id: threadId, cwd: root, status: { type: "idle" } },
      activePermissionProfile: { id: SHARED_CODEX_PERMISSIONS }, ...overrides },
  });
  const submit = (threadId = "thread") => request("turn/start", {
    threadId, input: [{ type: "text", text: "Summarize the project readme." }],
  });
  const accepted = (req, turnId = "turn") => ({
    id: req.id, result: { turn: { id: turnId, status: "inProgress" } },
  });
  const terminal = (threadId = "thread", turnId = "turn", status = "interrupted") => ({
    method: "turn/completed", params: { threadId, turn: { id: turnId, status } },
  });
  const authorization = (overrides = {}) => ({ id: 1, method: "item/commandExecution/requestApproval",
    params: { kind: "command", threadId: "thread", turnId: "turn", itemId: "item",
      cwd: root, command: "printf %s reviewed", availableDecisions: ["accept", "acceptForSession", "decline", "cancel"],
      ...overrides },
  });
  function replace(newPhone = phone) {
    boundary.closeApprovals();
    route = Symbol("replacement");
    phone = newPhone;
  }
  function start() {
    boundary.attest();
    const req = request("thread/start");
    boundary.reserve(req);
    assert.deepEqual(boundary.observe(opened(req)), opened(req));
  }
  return { boundary, dir, root, toNative, toPhone, request, opened, submit, accepted, terminal, authorization,
    replace, start, cleanupPending: (value) => { pending = value; }, advance: (ms) => { time += ms; } };
}

test("write authority requires an attested native runtime, route, idle thread, project and permissions", (t) => {
  const h = harness(t);
  const b = h.boundary;
  assert.throws(() => b.reserve(h.request("thread/start")), /not authorized/);
  b.attest();
  assert.throws(() => b.reserve(h.request("thread/start", { cwd: h.dir })), /not authorized/);
  assert.throws(() => b.reserve(h.request("thread/start", { permissions: "workspace-write" })), /not authorized/);
  assert.throws(() => b.reserve(h.request("thread/start", { ephemeral: true })), /not authorized/);
  assert.throws(() => b.reserve(h.request("thread/fork")), /not authorized/);
  assert.throws(() => b.reserve(h.submit()), /not authorized/);

  for (const override of [
    { cwd: h.dir }, { activePermissionProfile: { id: "different" } },
    { thread: { id: "thread", cwd: h.root, status: { type: "active" } } },
    { thread: { id: "thread", cwd: h.root, ephemeral: true, status: { type: "idle" } } },
    { thread: { id: "thread", cwd: h.dir, status: { type: "idle" } } },
  ]) {
    const req = h.request("thread/start");
    b.reserve(req);
    assert.equal(b.observe(h.opened(req, "thread", override)).error.data.errorCode, "native_method_not_authorized");
    assert.throws(() => b.reserve(h.submit()), /not authorized/);
  }
  const resumed = h.request("thread/resume", { threadId: "expected" });
  b.reserve(resumed);
  assert.ok(b.observe(h.opened(resumed, "other")).error);
  h.start();
  assert.doesNotThrow(() => b.reserve(h.submit()));
  h.replace(null);
  assert.throws(() => b.reserve(h.request("turn/interrupt", { threadId: "thread", turnId: "turn" })), /not authorized/);
});

test("stale openings cannot authorize a replacement route or satisfy its new request", (t) => {
  const h = harness(t);
  const b = h.boundary;
  b.attest();
  const original = h.request("thread/start");
  b.reserve(original);
  h.replace();
  const replacement = h.request("thread/resume", { threadId: "thread" });
  assert.throws(() => b.reserve(replacement), /not authorized/);
  assert.equal(b.observe(h.opened(original)), null);
  assert.throws(() => b.reserve(h.submit()), /not authorized/);
  b.reserve(replacement);
  const unrelated = { ...h.opened(original), id: "unrelated-native-id" };
  assert.deepEqual(b.observe(unrelated), unrelated);
  assert.throws(() => b.reserve(h.submit()), /not authorized/);
  assert.deepEqual(b.observe(h.opened(replacement)), h.opened(replacement));
  assert.doesNotThrow(() => b.reserve(h.submit()));
});

test("late submission acknowledgment stops duplicate delivery and only the exact same-phone Stop can target it", (t) => {
  const h = harness(t);
  const b = h.boundary;
  h.start();
  const original = h.submit();
  b.reserve(original);
  h.replace("other-phone");
  assert.throws(() => b.reserve(h.submit()), /not authorized/);
  assert.equal(b.observe(h.accepted(original)), null);
  const stop = (turnId = "turn") => h.request("turn/interrupt", { threadId: "thread", turnId });
  assert.throws(() => b.reserve(stop()), /not authorized/);
  assert.equal(b.offer(h.authorization()), false);
  h.replace("trusted-phone");
  assert.throws(() => b.reserve(stop("other-turn")), /not authorized/);
  assert.doesNotThrow(() => b.reserve(stop()));
  assert.deepEqual(b.observe(h.terminal("thread", "other-turn")), h.terminal("thread", "other-turn"));
  assert.throws(() => b.reserve(h.request("thread/resume", { threadId: "thread" })), /not authorized/);
  h.cleanupPending(true);
  b.observe(h.terminal());
  assert.doesNotThrow(() => b.reserve(stop()));
  assert.throws(() => b.reserve(h.submit()), /not authorized/);
  h.cleanupPending(false);
  assert.throws(() => b.reserve(stop()), /not authorized/);
  assert.throws(() => b.reserve(h.submit()), /not authorized/);
  const resume = h.request("thread/resume", { threadId: "thread" });
  b.reserve(resume);
  b.observe(h.opened(resume));
  assert.doesNotThrow(() => b.reserve(h.submit()));
});

test("malformed native acknowledgment keeps the task unresolved, without a false rejection or resend", (t) => {
  const h = harness(t);
  h.start();
  const b = h.boundary, send = h.submit();
  b.reserve(send);
  assert.equal(b.observe({ id: send.id, result: { turn: { status: "inProgress" } } }), null);
  b.observe(h.terminal());
  assert.equal(b.observe({ id: send.id, error: { code: -32000, message: "Contradiction" } }), null);
  h.replace();
  assert.throws(() => b.reserve(h.submit()), /not authorized/);
  assert.throws(() => b.reserve(h.request("thread/resume", { threadId: "thread" })), /not authorized/);
  assert.equal(b.offer(h.authorization()), false);
});

test("an authoritative native rejection before submission allows a later explicit request", (t) => {
  const h = harness(t);
  h.start();
  const b = h.boundary, send = h.submit();
  b.reserve(send);
  const rejection = { id: send.id, error: { code: -32602, message: "Rejected before submission" } };
  assert.deepEqual(b.observe(rejection), rejection);
  assert.doesNotThrow(() => b.reserve(h.submit()));
});

test("an exact native terminal racing the response releases the turn, but other terminals do not", (t) => {
  const h = harness(t);
  h.start();
  const b = h.boundary, send = h.submit();
  b.reserve(send);
  b.observe(h.terminal("elsewhere", "turn", "completed"));
  b.observe(h.terminal("thread", "turn", "inProgress"));
  assert.throws(() => b.reserve(h.submit()), /not authorized/);
  b.observe(h.terminal());
  assert.throws(() => b.reserve(h.submit()), /not authorized/);
  b.observe(h.accepted(send));
  assert.equal(b.offer(h.authorization()), false);
  assert.doesNotThrow(() => b.reserve(h.submit()));
});

test("approval is one-time, scoped to the exact active turn and settled before Stop", (t) => {
  const h = harness(t);
  h.start();
  const b = h.boundary, send = h.submit();
  b.reserve(send);
  b.observe(h.accepted(send));
  assert.equal(b.offer(h.authorization({ turnId: "different-turn" })), false);
  assert.equal(b.offer(h.authorization({ threadId: "different-thread" })), false);
  assert.equal(b.offer(h.authorization({ networkApprovalContext: {} })), false);
  assert.equal(b.offer(h.authorization({ cwd: h.dir })), false);
  assert.equal(b.offer(h.authorization()), true);
  const firstPrompt = h.toPhone.at(-1);
  assert.notEqual(firstPrompt.id, 1);
  assert.deepEqual(firstPrompt.params.availableDecisions, ["accept", "decline", "cancel"]);
  b.reply({ id: firstPrompt.id, result: { decision: "acceptForSession" } });
  b.reply({ id: "wrong", result: { decision: "accept" } });
  assert.deepEqual(h.toNative, []);
  b.reply({ id: firstPrompt.id, result: { decision: "accept" } });
  b.reply({ id: firstPrompt.id, result: { decision: "accept" } });
  assert.deepEqual(h.toNative, [{ id: 1, result: { decision: "accept" } }]);
  assert.equal(b.observe({ method: "serverRequest/resolved", params: { threadId: "thread", requestId: 1 } }), null);
  assert.equal(h.toPhone.at(-1).params.requestId, firstPrompt.id);
  assert.equal(b.offer({ ...h.authorization(), id: 2 }), true);
  const secondPrompt = h.toPhone.at(-1);
  b.reserve(h.request("turn/interrupt", { threadId: "thread", turnId: "turn" }));
  b.settlePendingBeforeStop();
  b.reply({ id: secondPrompt.id, result: { decision: "accept" } });
  assert.deepEqual(h.toNative.at(-1), { id: 2, result: { decision: "cancel" } });
  assert.equal(h.toNative.length, 2);
  assert.equal(b.offer({ ...h.authorization(), id: 3 }), false);
});

test("replacement and expiry cannot forward stale approval responses or expose original callback IDs", (t) => {
  const h = harness(t);
  h.start();
  const b = h.boundary, send = h.submit();
  b.reserve(send);
  b.observe(h.accepted(send));
  assert.equal(b.offer(h.authorization()), true);
  const expired = h.toPhone.at(-1);
  h.advance(120_000);
  b.reply({ id: expired.id, result: { decision: "accept" } });
  assert.deepEqual(h.toNative, []);
  b.expire();
  b.expire();
  assert.deepEqual(h.toNative, [{ id: 1, result: { decision: "cancel" } }]);
  assert.equal(b.offer({ ...h.authorization(), id: 2 }), true);
  const replaced = h.toPhone.at(-1);
  const phoneFrames = h.toPhone.length;
  h.replace();
  b.reply({ id: replaced.id, result: { decision: "accept" } });
  assert.equal(b.observe({ method: "serverRequest/resolved", params: { threadId: "thread", requestId: 2 } }), null);
  assert.equal(h.toPhone.length, phoneFrames);
  assert.deepEqual(h.toNative.at(-1), { id: 2, result: { decision: "cancel" } });
});

test("a replacement directory at the same path cannot inherit the Mac project grant", (t) => {
  const h = harness(t);
  h.start();
  fs.renameSync(h.root, `${h.root}-original`);
  fs.mkdirSync(h.root);
  assert.throws(() => h.boundary.reserve(h.submit()), /not authorized/);
});

test("the active route retains at most 64 idle grants; an explicit reconnect can resume a known thread", (t) => {
  const h = harness(t);
  h.boundary.attest();
  for (let index = 0; index < 64; index++) {
    const open = h.request("thread/start");
    h.boundary.reserve(open);
    assert.equal(h.boundary.observe(h.opened(open, `thread-${index}`)).result.thread.id, `thread-${index}`);
  }
  assert.throws(() => h.boundary.reserve(h.request("thread/start")), /not authorized/);
  h.replace();
  assert.throws(() => h.boundary.reserve(h.submit("thread-0")), /not authorized/);
  const resume = h.request("thread/resume", { threadId: "thread-0" });
  h.boundary.reserve(resume);
  h.boundary.observe(h.opened(resume, "thread-0"));
  assert.doesNotThrow(() => h.boundary.reserve(h.submit("thread-0")));
});
