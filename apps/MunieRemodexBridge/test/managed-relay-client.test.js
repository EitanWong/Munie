const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const { generateKeyPairSync, randomBytes, verify } = require("node:crypto");
const { once } = require("node:events");
const { mkdtemp, readFile, rm, writeFile } = require("node:fs/promises");
const { Agent, createServer } = require("node:https");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const test = require("node:test");
const { WebSocketServer } = require("ws");
const { createHostedManagedRelayClient, createManagedRelayClient } = require("../src/managed-relay-client");

const hostname = "relay.munie.test";
const hostedOrigin = `https://${hostname}`;
const mac = generateKeyPairSync("ed25519");
const phone = generateKeyPairSync("ed25519");
const macKey = mac.privateKey.export({ format: "jwk" });
const phoneKey = phone.publicKey.export({ format: "jwk" }).x;
const trust = {
  macIdentityPublicKey: macKey.x,
  macIdentityPrivateKey: macKey.d,
  trustedPhones: { fixture: phoneKey },
};
const encodeChallenge = (challenge) => Buffer.from(JSON.stringify(challenge));

test("hosted transport requires explicit opt-in and a canonical HTTPS DNS origin", () => {
  assert.throws(() => createManagedRelayClient({ origin: hostedOrigin, audience: hostname }), TypeError);
  for (const invalid of [
    undefined, "https://localhost", "https://127.0.0.1", "https://[::1]", "https://1.2.3.4",
    "https://relay.munie.test:443", "https://relay.munie.test:8000", "https://relay.munie.test.",
    "https://relay.munie.test/path", "https://relay.munie.test?", "https://relay.munie.test/#",
    "https://user@relay.munie.test", "https://@relay.munie.test", "https://RELAY.munie.test",
    "https://relay.munie.test ", "https://relay.munie.test\n", "http://relay.munie.test", "https://relay.munie.test\\",
    "https://other..munie.test", "https://-relay.munie.test",
    "https://relay.local", "https://relay.localhost", `${hostedOrigin}/`, new URL(hostedOrigin),
  ]) {
    assert.throws(() => createHostedManagedRelayClient({ hostedOrigin: invalid }), TypeError);
  }
  createHostedManagedRelayClient({ hostedOrigin }).stop();
});

test("hosted waiting state belongs to the owner's first trust update, not construction", (t) => {
  const { client, states } = createClient(t, hostedOrigin, false);
  assert.deepEqual(states, []);
  client.replaceTrust({ trustedPhones: {} });
  client.replaceTrust(null);
  assert.deepEqual(states, ["waitingForPair"]);
  client.stop();
  assert.deepEqual(states, ["waitingForPair", "stopped"]);
});

test("hosted TLS registration binds the exact pair and trust removal closes it", { timeout: 7000 }, async (t) => {
  const fixture = await createTLSFixture(t);
  const { client, states, nextState } = createClient(t);
  assert.deepEqual(states, ["waitingForPair"]);
  client.replaceTrust(trust);
  await nextState("registered");
  assert.deepEqual(fixture.requests, [["POST", "/v1/managed/challenge", hostname]]);
  assert.equal(fixture.upgrades.length, 1);
  const [request] = fixture.upgrades;
  assert.equal(request.url, "/v1/managed/connect");
  assert.equal(request.headers.host, hostname);
  assert.equal(request.headers["x-munie-role"], "mac");
  assert.equal(request.headers["x-munie-challenge"], fixture.challenge.id);
  assert.deepEqual(fixture.challenge, {
    audience: hostname, role: "mac", macKey: macKey.x, phoneKey,
    id: fixture.challenge.id, generation: "", expiresAt: fixture.challenge.expiresAt,
  });
  assert.equal(verify(null, encodeChallenge(fixture.challenge), mac.publicKey,
    Buffer.from(request.headers["x-munie-proof"], "base64url")), true);
  const closed = once(fixture.socket, "close");
  client.replaceTrust(null);
  await nextState("waitingForPair");
  await closed;
  assert.deepEqual(states, ["waitingForPair", "connecting", "registered", "waitingForPair"]);
});

test("hosted certificate and hostname failures close registration", { timeout: 7000 }, async (t) => {
  await t.test("untrusted chain, even with the process-level TLS override", { timeout: 5000 }, async (t) => {
    const fixture = await createTLSFixture(t, { trustCertificate: false });
    const oldOverride = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
    t.after(() => {
      if (oldOverride === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
      else process.env.NODE_TLS_REJECT_UNAUTHORIZED = oldOverride;
    });
    const { client, states, nextState } = createClient(t);
    client.replaceTrust(trust);
    await nextState("denied");
    assert.deepEqual(states, ["waitingForPair", "connecting", "denied"]);
    assert.equal(fixture.requests.length, 0);
    assert.equal(fixture.upgrades.length, 0);
  });
  await t.test("trusted chain but wrong hostname", { timeout: 5000 }, async (t) => {
    const fixture = await createTLSFixture(t, { expectedHostname: "other.munie.test" });
    const { client, nextState } = createClient(t, "https://other.munie.test");
    client.replaceTrust(trust);
    await nextState("denied");
    assert.equal(fixture.requests.length, 0);
    assert.equal(fixture.upgrades.length, 0);
  });
  await t.test("untrusted WebSocket after trusted challenge", { timeout: 5000 }, async (t) => {
    const fixture = await createTLSFixture(t, { trustCertificate: (index) => index === 0 });
    const { client, nextState } = createClient(t);
    client.replaceTrust(trust);
    await nextState("denied");
    assert.equal(fixture.requests.length, 1);
    assert.equal(fixture.upgrades.length, 0);
  });
});

test("a WebSocket upgrade is not registration or permission to attach a phone", { timeout: 7000 }, async (t) => {
  const fixture = await createTLSFixture(t, { deferRegistration: true });
  const { client, states, nextState } = createClient(t);
  client.replaceTrust(trust);
  const socket = await fixture.upgraded;
  const pong = once(socket, "pong");
  socket.ping("munie:phone-attached:6cc2b857-1aba-406f-88c0-18b87b751358");
  await pong;
  assert.deepEqual(states, ["waitingForPair", "connecting"]);
  socket.ping("munie:mac-registered");
  await nextState("registered");
});

test("hosted HTTP and upgrade rejection do not follow redirects or retry admission", { timeout: 8000 }, async (t) => {
  for (const [phase, status] of [["challenge", 307], ["challenge", 403], ["upgrade", 307], ["upgrade", 401]]) {
    await t.test(`${phase} ${status}`, { timeout: 3000 }, async (t) => {
      const fixture = await createTLSFixture(t, {
        challengeStatus: phase === "challenge" ? [status] : [],
        upgradeStatus: phase === "upgrade" ? status : null,
      });
      const { client, states, nextState } = createClient(t);
      client.replaceTrust(trust);
      await nextState("denied");
      client.replaceTrust(trust);
      // A same-pair refresh is not an override for a terminal admission decision.
      assert.deepEqual(states, ["waitingForPair", "connecting", "denied"]);
      assert.deepEqual(fixture.requests, [["POST", "/v1/managed/challenge", hostname]]);
      assert.deepEqual(fixture.upgrades.map((request) => request.url),
        phase === "upgrade" ? ["/v1/managed/connect"] : []);
    });
  }
});

test("a hosted 503 is retryable and recovers without changing the trusted pair", { timeout: 7000 }, async (t) => {
  const fixture = await createTLSFixture(t, { challengeStatus: [503] });
  const { client, states, nextState } = createClient(t);
  client.replaceTrust(trust);
  await nextState("registered");
  assert.deepEqual(states, ["waitingForPair", "connecting", "unavailable", "connecting", "registered"]);
  assert.equal(fixture.requests.length, 2);
  assert.equal(fixture.upgrades.length, 1);
});

function createClient(t, origin = hostedOrigin, initializeTrust = true) {
  const states = [];
  const waiters = new Map();
  const client = createHostedManagedRelayClient({
    hostedOrigin: origin,
    encodeChallenge,
    attachPhone: () => assert.fail("relay registration is not a phone connection"),
    sessionId: "fixture",
    onState(state) {
      states.push(state);
      waiters.get(state)?.();
      waiters.delete(state);
    },
  });
  t.after(() => client.stop());
  if (initializeTrust) client.replaceTrust(null);
  function nextState(state) {
    if (states.at(-1) === state) return Promise.resolve();
    return new Promise((resolve) => waiters.set(state, resolve));
  }
  return { client, states, nextState };
}

async function createTLSFixture(t, {
  expectedHostname = hostname, trustCertificate = true, challengeStatus = [], upgradeStatus = null,
  deferRegistration = false,
} = {}) {
  const directory = await mkdtemp(join(tmpdir(), "munie-hosted-relay-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(join(directory, "req.cnf"), [
    "[req]", "distinguished_name=dn", "x509_extensions=ext", "prompt=no",
    "[dn]", `CN=${hostname}`, "[ext]", `subjectAltName=DNS:${hostname}`, "",
  ].join("\n"));
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
    "-config", "req.cnf", "-keyout", "key.pem", "-out", "cert.pem"], { cwd: directory, stdio: "pipe" });
  const [key, cert] = await Promise.all(["key.pem", "cert.pem"].map((name) => readFile(join(directory, name))));
  const { promise: upgraded, resolve: socketUpgraded } = Promise.withResolvers();
  const fixture = { requests: [], upgrades: [], challenge: null, socket: null, upgraded };
  const server = createServer({ key, cert }, async (request, response) => {
    fixture.requests.push([request.method, request.url, request.headers.host]);
    const status = challengeStatus.shift() ?? 200;
    if (status !== 200) {
      response.writeHead(status, { Location: `https://${expectedHostname}/not-managed` });
      return response.end();
    }
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const requested = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    fixture.challenge = {
      audience: hostname, ...requested, id: randomBytes(32).toString("base64url"),
      generation: "", expiresAt: Date.now() + 15_000,
    };
    response.writeHead(200, { "Content-Type": "application/json" });
    response.end(JSON.stringify(fixture.challenge));
  });
  const sockets = new Set();
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (request, socket, head) => {
    fixture.upgrades.push(request);
    if (upgradeStatus !== null) {
      return socket.end(`HTTP/1.1 ${upgradeStatus} Fixture\r\nConnection: close\r\n`
        + `Location: https://${expectedHostname}/not-managed\r\nContent-Length: 0\r\n\r\n`);
    }
    wss.handleUpgrade(request, socket, head, (webSocket) => {
      fixture.socket = webSocket;
      socketUpgraded(webSocket);
      if (!deferRegistration) webSocket.ping("munie:mac-registered");
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
  });
  let connections = 0;
  const createConnection = Agent.prototype.createConnection;
  t.mock.method(Agent.prototype, "createConnection", function (options, callback) {
    assert.equal(options.servername, expectedHostname);
    assert.equal(options.rejectUnauthorized, true);
    // Reroute TCP for the fixture only; the original TLS hostname and full validation stay in effect.
    const trust = typeof trustCertificate === "function" ? trustCertificate(connections++) : trustCertificate;
    return createConnection.call(this, {
      ...options, host: "127.0.0.1", port: server.address().port, ca: trust ? cert : undefined,
    }, callback);
  });
  return fixture;
}
