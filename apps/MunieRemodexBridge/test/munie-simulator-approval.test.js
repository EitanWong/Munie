const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const { createSimulatorApprovalBoundary } = require(process.env.MUNIE_TEST_SIMULATOR_APPROVAL || "../src/munie-simulator-approval");
const { SHARED_CODEX_PERMISSIONS } = require("../src/munie-project-policy");

function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "munie-approval-routing-")));
  t.after(() => fs.rmdirSync(root));
  let route = Symbol(), time = 0, cancellationPending = false;
  const phone = [], native = [];
  const boundary = createSimulatorApprovalBoundary({
    root, currentRoute: () => route, now: () => time,
    cancellationPending: (threadId, turnId) => cancellationPending && threadId === "thread" && turnId === "turn",
    sendNative: (frame) => native.push(frame),
    sendPhone: (frame) => (phone.push(frame), true),
  });
  const open = { id: "open", method: "thread/start", params: {} };
  const opened = { id: "open", result: {
    thread: { id: "thread", cwd: root }, activePermissionProfile: { id: SHARED_CODEX_PERMISSIONS },
  } };
  const submit = { id: "submit", method: "turn/start", params: {
    threadId: "thread", input: [{ type: "text", text: "Munie signed simulator stop probe" }],
  } };
  const started = { id: "submit", result: { turn: { id: "turn", status: "inProgress" } } };
  const offer = { id: 19, method: "item/commandExecution/requestApproval", params: {
    kind: "command", threadId: "thread", turnId: "turn", itemId: "item", cwd: root,
    command: "/bin/sh -c '/bin/sh managed-stop.sh'", availableDecisions: ["accept", "cancel", "acceptForSession"],
  } };
  const setup = () => {
    boundary.attest(); boundary.reserve(open); boundary.observe(opened);
    boundary.reserve(submit); boundary.observe(started);
  };
  return { boundary, open, opened, submit, offer, phone, native, setup,
    setCancellationPending: (value) => { cancellationPending = value; },
    replaceRoute: () => { route = Symbol(); boundary.closeApprovals(); },
    expire: () => { time += 120_000; boundary.expire(); } };
}

test("native acknowledgment and exact named profile precede the one fixture submission", (t) => {
  const { boundary, open, opened, submit, offer } = fixture(t);
  assert.throws(() => boundary.reserve(open));
  boundary.attest();
  boundary.reserve(open);
  assert.throws(() => boundary.reserve(submit));
  assert.ok(boundary.observe({ id: opened.id, result: { thread: opened.result.thread } }).error);
  assert.throws(() => boundary.reserve(submit));
  boundary.reserve(open);
  boundary.observe(opened);
  assert.throws(() => boundary.reserve({ ...submit, params: { ...submit.params, input: [{ text: "Other work" }] } }));
  boundary.reserve(submit);
  assert.equal(boundary.offer(offer), false);
  assert.throws(() => boundary.reserve({ ...submit, id: "second" }));
});

test("only the matching approval projects a command and native resolution dismisses the translated ID", (t) => {
  const { boundary, offer, phone, native, setup } = fixture(t);
  setup();
  assert.equal(boundary.offer({ ...offer, params: { ...offer.params, command: "other-command" } }), false);
  assert.equal(boundary.offer({ ...offer, params: { ...offer.params, turnId: "other-turn" } }), false);
  assert.equal(boundary.offer(offer), true);
  const { id } = phone[0];
  assert.deepEqual(phone[0].params.availableDecisions, ["accept", "cancel"]);
  boundary.reply({ id, result: { decision: "acceptForSession" } });
  assert.deepEqual(native, []);
  boundary.reply({ id, result: { decision: "accept" } });
  boundary.reply({ id, result: { decision: "accept" } });
  assert.deepEqual(native, [{ id: 19, result: { decision: "accept" } }]);
  const resolved = { method: "serverRequest/resolved", params: { threadId: "thread", requestId: 19 } };
  assert.equal(boundary.observe(resolved), null);
  assert.equal(boundary.observe(resolved), null);
  assert.deepEqual(phone[1], { ...resolved, params: { ...resolved.params, requestId: id } });
  assert.equal(phone.length, 2);
});

test("route replacement drains pending native callbacks without replaying mobile prompts", (t) => {
  const { boundary, offer, phone, native, setup, replaceRoute } = fixture(t);
  setup();
  assert.equal(boundary.offer(offer), true);
  replaceRoute();
  boundary.reply({ id: phone[0].id, result: { decision: "accept" } });
  assert.equal(boundary.offer({ ...offer, id: 20 }), false);
  assert.deepEqual(native, [{ id: 19, result: { decision: "cancel" } }]);
  assert.equal(phone.length, 1);
});

test("expiry settles exactly once and the caller can dismiss the same prompt", (t) => {
  const { boundary, offer, phone, native, setup, expire } = fixture(t);
  setup();
  assert.equal(boundary.offer(offer), true);
  expire(); expire();
  boundary.reply({ id: phone[0].id, result: { decision: "accept" } });
  assert.deepEqual(native, [{ id: 19, result: { decision: "cancel" } }]);
  assert.deepEqual(phone[1], { method: "serverRequest/resolved", params: { threadId: "thread", requestId: phone[0].id } });
  assert.equal(phone.length, 2);
});

test("only the exact terminal turn can retry an unfinished cancellation", (t) => {
  const { boundary, setup, setCancellationPending } = fixture(t);
  setup();
  const stop = { method: "turn/interrupt", id: "stop", params: { threadId: "thread", turnId: "turn" } };
  boundary.reserve(stop);
  boundary.observe({ method: "turn/completed", params: { threadId: "thread", turn: { id: "turn" } } });
  assert.throws(() => boundary.reserve(stop));
  setCancellationPending(true);
  assert.throws(() => boundary.reserve({ ...stop, params: { ...stop.params, turnId: "another-turn" } }));
  boundary.reserve(stop);
  setCancellationPending(false);
  assert.throws(() => boundary.reserve(stop));
});
