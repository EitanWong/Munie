const assert = require("node:assert/strict");
const { generateKeyPairSync, sign } = require("node:crypto");
const { once } = require("node:events");
const { request } = require("node:http");
const { setTimeout: delay } = require("node:timers/promises");
const test = require("node:test");
const { WebSocket } = require("ws");
const { managedAdmissionTranscript } = require("./managed-admission");
const { startManagedRelayPilot } = require("./managed-relay-pilot");

function identity() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return { key: publicKey.export({ format: "jwk" }).x, privateKey };
}

async function fixture(t) {
  const mac = identity();
  const phone = identity();
  const relay = await startManagedRelayPilot({ audience: "fixture.invalid", allowedMacKeys: [mac.key] });
  t.after(() => relay.close());
  const challenge = (role, device = phone) => fetch(`${relay.origin}/v1/managed/challenge`, {
    method: "POST",
    body: JSON.stringify({ role, macKey: mac.key, phoneKey: device.key }),
  });
  const proof = async (role, device = phone, signer = role === "mac" ? mac : device) => {
    const response = await challenge(role, device);
    assert.equal(response.status, 200);
    const value = await response.json();
    return {
      "x-munie-role": role,
      "x-munie-challenge": value.id,
      "x-munie-proof": sign(null, managedAdmissionTranscript(value), signer.privateKey).toString("base64url"),
    };
  };
  const connect = async (headers, observe = null) => {
    const socket = new WebSocket(`${relay.origin.replace(/^http/, "ws")}/v1/managed/connect`, {
      headers, handshakeTimeout: 1000,
    });
    await Promise.all([once(socket, "open"), observe?.(socket)]);
    return socket;
  };
  return { relay, mac, phone, challenge, proof, connect };
}

test("loopback pilot forwards between admitted peers; denied upgrades cannot replace a live route", { timeout: 5000 }, async (t) => {
  const { relay, challenge, proof, connect, phone } = await fixture(t);
  assert.equal((await challenge("phone")).status, 403);
  const macSocket = await connect(await proof("mac"));
  const controls = [];
  macSocket.on("ping", (payload) => controls.push(payload.toString()));
  const phoneProof = await proof("phone");
  const phoneSocket = await connect(phoneProof);
  await assert.rejects(connect(phoneProof), /403/);
  await assert.rejects(connect(await proof("mac", phone, phone)), /403/);
  await assert.rejects(connect({ ...await proof("phone"), "x-munie-role": "mac" }), /403/);

  const validMacProof = await proof("mac");
  const failedUpgrade = await new Promise((resolve, reject) => {
    const req = request(`${relay.origin}/v1/managed/connect`, {
      headers: { ...validMacProof, Connection: "Upgrade", Upgrade: "websocket" },
    }, (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    req.on("upgrade", (_, socket) => {
      socket.destroy();
      reject(new Error("An incomplete WebSocket handshake was unexpectedly accepted"));
    });
    req.on("error", reject);
    req.end();
  });
  assert.equal(failedUpgrade, 400);

  const toMac = once(macSocket, "message");
  phoneSocket.send("synthetic opaque frame");
  const [text, binary] = await toMac;
  assert.equal(text.toString(), "synthetic opaque frame");
  assert.equal(binary, false);
  assert.equal(controls.length, 1);
  assert.match(controls[0], /^munie:phone-attached:[a-f0-9-]{36}$/);
  const toPhone = once(phoneSocket, "message");
  macSocket.send(JSON.stringify({ routeId: controls[0].split(":").at(-1), message: "response" }));
  assert.deepEqual(await toPhone, [Buffer.from("response"), false]);
});

test("replacement removes only the old generation; Mac departure closes the paired phone route", { timeout: 5000 }, async (t) => {
  const { challenge, proof, connect } = await fixture(t);
  const macSocket = await connect(await proof("mac"));
  const phoneSocket = await connect(await proof("phone"));
  const staleProof = await proof("phone");
  const replacedMac = once(macSocket, "close");
  const replacedPhone = once(phoneSocket, "close");
  const newPhone = identity();
  const replacement = await connect(await proof("mac", newPhone));
  await Promise.all([replacedMac, replacedPhone]);
  assert.equal((await challenge("phone")).status, 403);
  await assert.rejects(connect(staleProof), /403/);

  const newSocket = await connect(await proof("phone", newPhone));
  const lost = once(newSocket, "close");
  replacement.close();
  await lost;
  assert.equal((await challenge("phone", newPhone)).status, 403);
});

test("an incumbent survives a competing phone and stale Mac frames do not reach its successor", { timeout: 5000 }, async (t) => {
  const { proof, connect } = await fixture(t);
  const mac = await connect(await proof("mac"));
  const events = [];
  mac.on("ping", (payload) => events.push(["ping", payload.toString()]));
  mac.on("message", (data) => events.push(["message", data.toString()]));

  const original = await connect(await proof("phone"));
  const originalFrame = once(mac, "message");
  original.send("original frame");
  await originalFrame;

  const competitor = await connect(await proof("phone"));
  if (competitor.readyState !== WebSocket.CLOSED) await once(competitor, "close");
  assert.equal(original.readyState, WebSocket.OPEN);
  assert.deepEqual(events.map(([kind]) => kind), ["ping", "message"]);
  const detached = once(mac, "ping");
  original.close();
  assert.equal((await detached)[0].toString(), "munie:phone-detached");
  const replacement = await connect(await proof("phone"));
  const replacementFrame = once(mac, "message");
  replacement.send("replacement frame");
  await replacementFrame;

  assert.deepEqual(events.map(([kind]) => kind), ["ping", "message", "ping", "ping", "message"]);
  const oldId = events[0][1].split(":").at(-1), newId = events[3][1].split(":").at(-1);
  assert.notEqual(oldId, newId);
  const first = once(replacement, "message");
  mac.send(JSON.stringify({ routeId: oldId, message: "stale" }));
  mac.send(JSON.stringify({ routeId: newId, message: "current" }));
  assert.equal((await first)[0].toString(), "current");
});

test("current phone detach is signaled; missing phone frames are dropped without losing Mac registration", { timeout: 5000 }, async (t) => {
  const { proof, connect } = await fixture(t);
  const mac = await connect(await proof("mac"));
  const unavailable = once(mac, "ping");
  mac.send("discard before phone attaches");
  assert.equal((await unavailable)[0].toString(), "munie:phone-unavailable");
  const attached = once(mac, "ping");
  const phone = await connect(await proof("phone"));
  const attachedSignal = (await attached)[0].toString();
  assert.match(attachedSignal, /^munie:phone-attached:[a-f0-9-]{36}$/);
  const received = once(phone, "message");
  mac.send(JSON.stringify({ routeId: attachedSignal.split(":").at(-1), message: "fresh frame" }));
  assert.equal((await received)[0].toString(), "fresh frame");

  const detached = once(mac, "ping");
  phone.close();
  assert.equal((await detached)[0].toString(), "munie:phone-detached");
  const unavailableAfterDetach = once(mac, "ping");
  mac.send("discard after phone detaches");
  assert.equal((await unavailableAfterDetach)[0].toString(), "munie:phone-unavailable");
  const reattached = once(mac, "ping");
  await connect(await proof("phone"));
  assert.match((await reattached)[0].toString(), /^munie:phone-attached:[a-f0-9-]{36}$/);
});

test("only the authenticated Mac can close the exact current phone route", { timeout: 5000 }, async (t) => {
  const { proof, connect } = await fixture(t);
  const mac = await connect(await proof("mac"));
  const nextPing = () => once(mac, "ping").then(([data]) => data.toString());
  async function attach(headers) {
    const attached = nextPing();
    const phone = await connect(headers);
    const signal = await attached;
    assert.match(signal, /^munie:phone-attached:[a-f0-9-]{36}$/);
    return { phone, id: signal.split(":").at(-1) };
  }
  async function closePhone(phone, signal, code, reason) {
    const closed = once(phone, "close", { signal: AbortSignal.timeout(1000) });
    const detached = nextPing();
    mac.ping(signal);
    const [[receivedCode, receivedReason], detachedSignal] = await Promise.all([closed, detached]);
    assert.equal(receivedCode, code);
    assert.equal(receivedReason.toString(), reason);
    assert.equal(detachedSignal, "munie:phone-detached");
    assert.equal(mac.readyState, WebSocket.OPEN);
  }

  const first = await attach(await proof("phone"));
  const firstClose = `munie:phone-close:${first.id}:1009`;
  const toMac = once(mac, "message");
  first.phone.ping(firstClose);
  first.phone.send("phone cannot signal a pilot close");
  assert.equal((await toMac)[0].toString(), "phone cannot signal a pilot close");
  const toFirst = once(first.phone, "message");
  mac.ping(`munie:phone-close:${first.id}:1000`);
  mac.ping(`${firstClose}:untrusted reason`);
  mac.send(JSON.stringify({ routeId: first.id, message: "still current" }));
  assert.equal((await toFirst)[0].toString(), "still current");

  const successorProof = await proof("phone");
  await closePhone(first.phone, firstClose, 1009, "Mobile route frame too large");
  const successor = await attach(successorProof);
  assert.notEqual(successor.id, first.id);
  const toSuccessor = once(successor.phone, "message");
  mac.ping(firstClose);
  mac.send(JSON.stringify({ routeId: successor.id, message: "successor stays open" }));
  assert.equal((await toSuccessor)[0].toString(), "successor stays open");
  await closePhone(successor.phone, `munie:phone-close:${successor.id}:4004`, 4004, "Mobile route unavailable");
});

test("adapter preserves the local close code when receive returns false and fences an old binding", { timeout: 5000 }, async (t) => {
  const { createManagedRelayClient } = require("../MunieRemodexBridge/src/managed-relay-client");
  const { relay, mac, phone, challenge, proof, connect } = await fixture(t);
  const bindings = [];
  const client = createManagedRelayClient({
    origin: relay.origin, audience: "fixture.invalid", encodeChallenge: managedAdmissionTranscript, sessionId: "fixture-session",
    attachPhone(_, binding) {
      bindings.push(binding);
      return {
        receive(text) {
          if (text === "too big") binding.close(1009, "not a wire reason");
          return false;
        },
        detach() {},
      };
    },
  });
  t.after(() => client.stop());
  client.replaceTrust({
    macIdentityPublicKey: mac.key,
    macIdentityPrivateKey: mac.privateKey.export({ format: "jwk" }).d,
    trustedPhones: { phone: phone.key },
  });
  const deadline = AbortSignal.timeout(1000);
  for (;;) {
    const response = await challenge("phone");
    await response.body.cancel();
    if (response.ok) break;
    await delay(10, undefined, { signal: deadline });
  }
  const first = await connect(await proof("phone"));
  const successorProof = await proof("phone");
  const firstClosed = once(first, "close", { signal: AbortSignal.timeout(1000) });
  first.send("too big");
  assert.deepEqual(await firstClosed, [1009, Buffer.from("Mobile route frame too large")]);

  // The adapter can send readiness before the caller resumes from awaiting open.
  const successor = await connect(successorProof, async (socket) => {
    const [ready] = await once(socket, "message", { signal: AbortSignal.timeout(1000) });
    assert.deepEqual(JSON.parse(ready.toString()), { kind: "managedRouteReady", sessionId: "fixture-session" });
  });
  bindings[0].close(1009);
  assert.equal(bindings[0].send("stale opaque frame"), false);
  const afterStaleClose = once(successor, "message", { signal: AbortSignal.timeout(1000) });
  assert.equal(bindings[1].send("current opaque frame"), true);
  assert.equal((await afterStaleClose)[0].toString(), "current opaque frame");
  const unavailable = once(successor, "close", { signal: AbortSignal.timeout(1000) });
  successor.send("unavailable without close code");
  assert.deepEqual(await unavailable, [4004, Buffer.from("Mobile route unavailable")]);
  assert.equal((await challenge("phone")).status, 200);
});

test("legacy routes and oversized challenge bodies are not served on the pilot", { timeout: 5000 }, async (t) => {
  const { relay } = await fixture(t);
  assert.equal(new URL(relay.origin).hostname, "127.0.0.1");
  for (const path of ["/v1/trusted/session/resolve", "/v1/pairing/code/resolve", "/v1/push/session/register-device"]) {
    assert.equal((await fetch(`${relay.origin}${path}`, { method: "POST" })).status, 404);
  }
  const response = await fetch(`${relay.origin}/v1/managed/challenge`, { method: "POST", body: "a".repeat(1025) });
  assert.equal(response.status, 413);
});
