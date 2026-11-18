const assert = require("node:assert/strict");
const { generateKeyPairSync, sign } = require("node:crypto");
const { once } = require("node:events");
const { request } = require("node:http");
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
  const connect = async (headers) => {
    const socket = new WebSocket(`${relay.origin.replace(/^http/, "ws")}/v1/managed/connect`, {
      headers, handshakeTimeout: 1000,
    });
    await once(socket, "open");
    return socket;
  };
  return { relay, mac, phone, challenge, proof, connect };
}

test("loopback pilot forwards between admitted peers; denied upgrades cannot replace a live route", { timeout: 5000 }, async (t) => {
  const { relay, challenge, proof, connect, phone } = await fixture(t);
  assert.equal((await challenge("phone")).status, 403);
  const macSocket = await connect(await proof("mac"));
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
  const toPhone = once(phoneSocket, "message");
  macSocket.send(Buffer.from([1, 2, 3]));
  assert.deepEqual(await toPhone, [Buffer.from([1, 2, 3]), true]);
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

test("a missing phone drops the frame with a control signal and preserves Mac registration", { timeout: 5000 }, async (t) => {
  const { proof, connect } = await fixture(t);
  const mac = await connect(await proof("mac"));
  const unavailable = once(mac, "ping");
  mac.send("discard before phone attaches");
  assert.equal((await unavailable)[0].toString(), "munie:phone-unavailable");
  const phone = await connect(await proof("phone"));
  const received = once(phone, "message");
  mac.send("fresh frame");
  assert.equal((await received)[0].toString(), "fresh frame");
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
