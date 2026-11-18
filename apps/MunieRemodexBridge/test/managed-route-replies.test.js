const test = require("node:test");
const assert = require("node:assert/strict");
const { createManagedRouteReplies } = require("../src/managed-route-replies");

test("a late reply cannot satisfy a successor route's reused request ID", () => {
  const replies = createManagedRouteReplies();
  const original = { id: 42, method: "thread/read", params: { threadId: "fixture" } };
  const departed = replies.wrapRequest(original);
  replies.clear();
  const active = replies.wrapRequest(original);
  assert.notEqual(active.id, departed.id);
  assert.deepEqual(active.params, original.params);
  assert.equal(replies.takeReply({ id: departed.id, result: { old: true } }), null);
  assert.deepEqual(replies.takeReply({ id: active.id, result: { active: true } }), { id: 42, result: { active: true } });
  assert.equal(replies.takeReply({ id: active.id, result: {} }), null);
  assert.equal(replies.takeReply({ id: 42, result: {} }), null);
});

test("reply capacity refuses new work instead of evicting live requests", () => {
  const replies = createManagedRouteReplies();
  const first = replies.wrapRequest({ id: 0 });
  for (let index = 1; index < 500; index += 1) assert.ok(replies.wrapRequest({ id: index }));
  assert.equal(replies.wrapRequest({ id: 500 }), null);
  assert.deepEqual(replies.takeReply({ id: first.id, error: { code: -1 } }), { id: 0, error: { code: -1 } });
  assert.ok(replies.wrapRequest({ id: 500 }));
});
