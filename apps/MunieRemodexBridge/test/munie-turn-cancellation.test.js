const test = require("node:test");
const assert = require("node:assert/strict");
const { setTimeout: wait } = require("node:timers/promises");
const { createTurnCancellationController } = require("../src/munie-turn-cancellation");

function fixture(overrides = {}, { seedOwners = true } = {}) {
  const calls = [], replies = [], events = [];
  let controller;
  let live = [{ itemId: "command-1", processId: "native-session-1" },
    { itemId: "older-command", processId: "keep-old-session" }];
  const terminal = { method: "turn/completed", params: {
    threadId: "thread-1", turn: { id: "turn-1", status: "interrupted", items: [] },
  } };
  const handlers = {
    "turn/interrupt": () => { controller.observe(terminal); return {}; },
    "thread/items/list": () => { throw Object.assign(new Error("thread/items/list is not supported yet"), { code: -32601 }); },
    "thread/backgroundTerminals/list": () => ({ data: live }),
    "thread/backgroundTerminals/terminate": ({ processId }) => {
      live = live.filter((entry) => entry.processId !== processId);
      return { terminated: true };
    },
    ...overrides,
  };
  controller = createTurnCancellationController({
    request: async (method, params) => { calls.push({ method, params }); return handlers[method](params); },
    respond: (raw) => replies.push(JSON.parse(raw)), publish: (event) => events.push(event), timeoutMs: 30,
  });
  if (seedOwners) {
    controller.observe({ method: "item/started", params: { threadId: "thread-1", turnId: "turn-1",
      item: { id: "command-1", type: "commandExecution" } } });
    controller.observe({ method: "item/completed", params: { threadId: "thread-1", turnId: "older-turn",
      item: { id: "older-command", type: "commandExecution" } } });
  }
  const cancel = (id = "cancel-1", turnId = "turn-1") => controller.handle({
    id, method: "turn/interrupt", params: { threadId: "thread-1", turnId },
  });
  return { controller, calls, replies, events, cancel, terminal, handlers };
}

async function settled(f) {
  for (let n = 0; n < 100 && f.replies.length === 0; n++) await wait(2);
  assert.ok(f.replies.length > 0, "cancellation must resolve within fixture bound");
}

test("interrupt terminates only this native turn's yielded sessions before publishing completion", async () => {
  let finishTermination;
  const f = fixture({ "thread/backgroundTerminals/terminate": () => new Promise((resolve) => {
    finishTermination = resolve;
  }) });
  f.cancel();
  await wait(1);
  assert.equal(f.replies.length, 0);
  assert.equal(f.events.length, 0);
  assert.equal(f.controller.handle({ id: "new", method: "turn/start", params: { threadId: "thread-1" } }), true);
  assert.equal(f.replies.pop().error.data.errorCode, "cancellation_cleanup_pending");
  assert.equal(f.controller.handle({ id: "other", method: "turn/start", params: { threadId: "other-thread" } }), false);
  f.handlers["thread/backgroundTerminals/list"] = () => ({ data: [{ itemId: "older-command", processId: "keep-old-session" }] });
  finishTermination({ terminated: true });
  await settled(f);
  assert.deepEqual(f.replies[0], { id: "cancel-1", result: {} });
  assert.deepEqual(f.events, [f.terminal]);
  assert.deepEqual(f.calls.filter((call) => call.method.endsWith("/terminate")), [{
    method: "thread/backgroundTerminals/terminate", params: { threadId: "thread-1", processId: "native-session-1" },
  }]);
  assert.equal(f.controller.handle({ id: "next", method: "turn/start", params: { threadId: "thread-1" } }), false);
  assert.equal(f.calls.some((call) => call.method === "thread/items/list" || call.method === "thread/read"), false);
});

test("a surviving process keeps cancellation pending; retry cleans without interrupting another turn", async () => {
  const f = fixture({ "thread/backgroundTerminals/terminate": () => ({ terminated: true }) });
  f.cancel(); await settled(f);
  assert.equal(f.replies[0].error.data.errorCode, "cancellation_cleanup_pending");
  assert.deepEqual(f.events, []);
  for (const method of ["turn/start", "turn/steer", "thread/read", "thread/turns/list", "thread/resume"]) {
    assert.equal(f.controller.handle({ id: method, method, params: { threadId: "thread-1" } }), true);
    assert.ok(f.replies.at(-1).error);
  }
  f.cancel("wrong", "new-turn");
  assert.ok(f.replies.at(-1).error);
  f.handlers["thread/backgroundTerminals/list"] = () => ({ data: [] });
  f.replies.length = 0;
  f.cancel("retry"); await settled(f);
  assert.deepEqual(f.replies, [{ id: "retry", result: {} }]);
  assert.equal(f.calls.filter((call) => call.method === "turn/interrupt").length, 1);
  assert.deepEqual(f.events, [f.terminal]);
});

test("a false terminate response succeeds only if the process is absent in a fresh list", async () => {
  const f = fixture({ "thread/backgroundTerminals/terminate": () => {
    f.handlers["thread/backgroundTerminals/list"] = () => ({ data: [] });
    return { terminated: false };
  } });
  f.cancel(); await settled(f);
  assert.ok(f.replies[0].result);
  assert.equal(f.calls.filter((call) => call.method.endsWith("/list") && call.method.includes("backgroundTerminals")).length, 2);
});

test("native failure, missing terminal event, and malformed turn association never confirm cancellation", async (t) => {
  for (const overrides of [
    { "turn/interrupt": () => { throw new Error("native reject"); } },
    { "turn/interrupt": () => ({}) },
    { "thread/backgroundTerminals/list": () => ({ data: [{ processId: "unbound" }] }) },
    { "thread/backgroundTerminals/terminate": () => ({}) },
  ]) await t.test(Object.keys(overrides)[0] + JSON.stringify(overrides), async () => {
    const f = fixture(overrides); f.cancel(); await settled(f);
    assert.ok(f.replies[0].error);
    assert.deepEqual(f.events, []);
  });
});

test("pagination binds exact turn items and terminates all of their sessions", async () => {
  const f = fixture({
    "thread/backgroundTerminals/list": ({ cursor, threadId }) => {
      assert.equal(threadId, "thread-1");
      const terminated = f.calls.some((call) => call.method.endsWith("/terminate"));
      if (terminated) return { data: [] };
      return cursor ? { data: [{ itemId: "command-1", processId: "native-session-1" }] }
        : { data: [{ itemId: "older-command", processId: "keep-old-session" }], nextCursor: "terminals-next" };
    },
  });
  f.cancel(); await settled(f); assert.ok(f.replies[0].result);
  assert.equal(f.calls.filter((call) => call.method.endsWith("/terminate")).length, 1);
});

test("repeated cursors and duplicate cancel requests cannot bypass the pending gate", async () => {
  const f = fixture({ "thread/backgroundTerminals/list": () => ({ data: [], nextCursor: "cycle" }) });
  f.cancel("first"); f.cancel("duplicate");
  await settled(f); await wait(2);
  assert.equal(f.calls.filter((call) => call.method === "turn/interrupt").length, 1);
  assert.equal(f.replies.length, 2);
  assert.ok(f.replies.every((reply) => reply.error));
  assert.deepEqual(f.events, []);
});

test("unrelated terminal events pass through; exact terminal and status are held until cleanup", async () => {
  let resolveInterrupt;
  const f = fixture({ "turn/interrupt": () => new Promise((resolve) => { resolveInterrupt = resolve; }) });
  f.cancel();
  assert.equal(f.controller.holdOutbound({ method: "turn/completed", params: { threadId: "thread-1", turnId: "turn-1" } }), true);
  assert.equal(f.controller.holdOutbound({ method: "turn/completed", params: { threadId: "thread-1", turnId: "other-turn" } }), false);
  assert.equal(f.controller.holdOutbound({ method: "turn/completed", params: { threadId: "other-thread", turnId: "turn-1" } }), false);
  assert.equal(f.controller.observe({ ...f.terminal, params: { ...f.terminal.params, threadId: "other-thread" } }), false);
  assert.equal(f.controller.observe({ ...f.terminal, params: { ...f.terminal.params, turn: { id: "other-turn" } } }), false);
  const status = { method: "thread/status/changed", params: { threadId: "thread-1", status: { type: "idle" } } };
  assert.equal(f.controller.observe(f.terminal), true);
  assert.equal(f.controller.observe(status), true);
  resolveInterrupt({}); await settled(f);
  assert.deepEqual(f.events, [f.terminal, status]);
  assert.equal(f.controller.holdOutbound(f.terminal), false);
});

test("a pre-terminal active status cannot revive the cancelled turn during delayed cleanup", async () => {
  let resolveInterrupt;
  const f = fixture({ "turn/interrupt": () => new Promise((resolve) => { resolveInterrupt = resolve; }) });
  f.cancel();
  const active = { method: "thread/status/changed", params: { threadId: "thread-1", status: { type: "active", activeFlags: [] } } };
  assert.equal(f.controller.observe(active), true);
  f.controller.observe(f.terminal);
  resolveInterrupt({}); await settled(f);
  assert.deepEqual(f.events, [f.terminal]);
});

test("late native terminal after a timeout lets retry clean up without another interrupt", async () => {
  const f = fixture({ "turn/interrupt": () => ({}) });
  f.cancel(); await settled(f);
  assert.ok(f.replies[0].error);
  f.controller.observe(f.terminal);
  f.replies.length = 0;
  f.cancel("retry"); await settled(f);
  assert.ok(f.replies[0].result);
  assert.equal(f.calls.filter((call) => call.method === "turn/interrupt").length, 1);
});

test("exact non-retry error and failed events cannot publish a terminal state before session cleanup", async () => {
  for (const method of ["error", "turn/failed"]) {
    let resolveInterrupt;
    const f = fixture({ "turn/interrupt": () => new Promise((resolve) => { resolveInterrupt = resolve; }) });
    f.cancel();
    const error = { method, params: { threadId: "thread-1", turnId: "turn-1", willRetry: false,
      error: { message: "synthetic execution failure" } } };
    assert.equal(f.controller.observe(error), true);
    assert.equal(f.controller.holdOutbound(error), true);
    assert.equal(f.controller.observe({ ...error, params: { ...error.params, threadId: "other-thread" } }), false);
    assert.equal(f.controller.observe({ ...error, params: { ...error.params, turnId: "other-turn" } }), false);
    assert.deepEqual(f.events, []);
    // Failure events cannot stand in for the exact native turn/completed confirmation.
    resolveInterrupt({});
    await wait(1);
    assert.equal(f.calls.some((call) => call.method.includes("backgroundTerminals")), false);
    assert.deepEqual(f.events, []);
    f.controller.observe(f.terminal); await settled(f);
    assert.deepEqual(f.events, [error, f.terminal]);
  }
  const f = fixture({ "turn/interrupt": () => ({}) });
  f.cancel();
  const retry = { method: "error", params: { threadId: "thread-1", turnId: "turn-1", willRetry: true } };
  assert.equal(f.controller.observe(retry), false);
  assert.equal(f.controller.holdOutbound(retry), false);
  f.controller.close();
});

test("a definite native stale-turn rejection releases the gate and preserves refresh-and-cancel", async () => {
  const f = fixture({ "turn/interrupt": () => {
    throw Object.assign(new Error("expected active turn id turn-2 but found turn-1"), {
      code: -32602, data: { reason: "stale_turn" },
    });
  } });
  f.cancel(); await settled(f);
  assert.deepEqual(f.replies[0].error, { code: -32602,
    message: "expected active turn id turn-2 but found turn-1", data: { reason: "stale_turn" } });
  assert.equal(f.controller.handle({ id: "refresh", method: "thread/read", params: { threadId: "thread-1" } }), false);
  assert.equal(f.calls.some((call) => call.method.includes("backgroundTerminals")), false);
  f.handlers["turn/interrupt"] = () => {
    f.controller.observe({ method: "turn/completed", params: { threadId: "thread-1",
      turn: { id: "turn-2", status: "interrupted", items: [] } } });
    return {};
  };
  f.handlers["thread/backgroundTerminals/list"] = () => ({ data: [] });
  f.replies.length = 0;
  f.cancel("fresh", "turn-2"); await settled(f);
  assert.deepEqual(f.replies, [{ id: "fresh", result: {} }]);
  assert.deepEqual(f.calls.filter((call) => call.method === "turn/interrupt").map((call) => call.params.turnId), ["turn-1", "turn-2"]);
  assert.equal(f.calls.some((call) => call.method.endsWith("/terminate")), false);
});

test("an uncertain interrupt failure retains the exact old-turn gate", async () => {
  const f = fixture({ "turn/interrupt": () => { throw new Error("Codex request timed out: turn/interrupt"); } });
  f.cancel(); await settled(f);
  assert.equal(f.replies[0].error.data.errorCode, "cancellation_cleanup_pending");
  assert.equal(f.controller.handle({ id: "refresh", method: "thread/read", params: { threadId: "thread-1" } }), true);
  f.cancel("other-turn", "turn-2");
  assert.equal(f.calls.filter((call) => call.method === "turn/interrupt").length, 1);
  f.handlers["turn/interrupt"] = () => {
    throw Object.assign(new Error("expected active turn id turn-2 but found turn-1"), { code: -32602 });
  };
  f.replies.length = 0;
  f.cancel("retry"); await settled(f);
  assert.equal(f.replies[0].error.data.errorCode, "cancellation_cleanup_pending");
  assert.equal(f.controller.handle({ id: "refresh-again", method: "thread/read", params: { threadId: "thread-1" } }), true);
  f.controller.close();
});

test("an unbound background command cannot be silently treated as another turn's process", async () => {
  const f = fixture({}, { seedOwners: false });
  f.cancel(); await settled(f);
  assert.equal(f.replies[0].error.data.errorCode, "cancellation_cleanup_pending");
  assert.deepEqual(f.events, []);
  assert.equal(f.calls.some((call) => call.method.endsWith("/terminate")), false);
});

test("conflicting native item ownership keeps all processes untouched and cancellation pending", async () => {
  const f = fixture();
  f.controller.observe({ method: "item/completed", params: { threadId: "thread-1", turnId: "other-turn",
    item: { id: "command-1", type: "commandExecution" } } });
  f.cancel(); await settled(f);
  assert.equal(f.replies[0].error.data.errorCode, "cancellation_cleanup_pending");
  assert.deepEqual(f.events, []);
  assert.equal(f.calls.some((call) => call.method.endsWith("/terminate")), false);
});

test("native completed-turn items bind a session even if no item delta reached the controller", async () => {
  const f = fixture({ "thread/backgroundTerminals/list": () => ({ data: f.calls.some((call) => call.method.endsWith("/terminate"))
    ? [] : [{ itemId: "command-1", processId: "native-session-1" }] }) }, { seedOwners: false });
  f.terminal.params.turn.items = [{ id: "command-1", type: "commandExecution" }];
  f.cancel(); await settled(f);
  assert.ok(f.replies[0].result);
  assert.equal(f.calls.some((call) => call.method.endsWith("/terminate")), true);
  assert.equal(f.calls.some((call) => call.method === "thread/items/list" || call.method === "thread/read"), false);
});

test("the live ownership ledger survives relay-style repeated controls and stays bounded", async () => {
  const f = fixture();
  for (let index = 0; index < 1_025; index++) f.controller.observe({ method: "item/started", params: {
    threadId: "thread-1", turnId: "later-turn", item: { id: `later-${index}`, type: "commandExecution" },
  } });
  f.cancel(); await settled(f);
  assert.equal(f.replies[0].error.data.errorCode, "cancellation_cleanup_pending");
  assert.equal(f.calls.some((call) => call.method.endsWith("/terminate")), false);
  assert.deepEqual(f.events, []);
});

test("a native owner conflict arriving during background-list await cannot terminate either owner", async () => {
  let resolveList;
  const f = fixture({ "thread/backgroundTerminals/list": () => new Promise((resolve) => { resolveList = resolve; }) });
  f.cancel();
  for (let n = 0; n < 30 && !resolveList; n++) await wait(1);
  assert.ok(resolveList);
  f.controller.observe({ method: "item/completed", params: { threadId: "thread-1", turnId: "other-turn",
    item: { id: "command-1", type: "commandExecution" } } });
  resolveList({ data: [{ itemId: "command-1", processId: "native-session-1" }] });
  await settled(f);
  assert.equal(f.replies[0].error.data.errorCode, "cancellation_cleanup_pending");
  assert.equal(f.calls.some((call) => call.method.endsWith("/terminate")), false);
});

test("relay-style completion mirrors never create a native command owner", async () => {
  const f = fixture({}, { seedOwners: false });
  assert.equal(f.controller.holdOutbound({ method: "item/started", params: {
    threadId: "thread-1", turnId: "turn-1", item: { id: "command-1", type: "commandExecution" },
  } }), false);
  f.cancel(); await settled(f);
  assert.equal(f.replies[0].error.data.errorCode, "cancellation_cleanup_pending");
  assert.equal(f.calls.some((call) => call.method.endsWith("/terminate")), false);
});
