const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { PassThrough } = require("node:stream");
const http = require("node:http");
const net = require("node:net");
const { createCipheriv, createDecipheriv, createHash, createPublicKey, diffieHellman,
  generateKeyPairSync, hkdfSync, randomUUID, sign, verify } = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");
const { setTimeout: delay } = require("node:timers/promises");
const WebSocket = require("ws");
const { nonceForDirection } = require("../src/secure-transport");
const { createDesktopHost, readFrames, selectLanAddress, advertisedHost, safeLogin, publicError, groupExists, verifyCleanup, MAX_REQUEST_BYTES } = require("../src/desktop-host");
const entry = path.resolve(__dirname, "../src/desktop-host.js");
const repository = path.resolve(__dirname, "../../..");

test("network choice uses an actual private IPv4 and prefers physical Apple interfaces", () => {
  const address = (value, extra = {}) => ({ address: value, family: "IPv4", internal: false, ...extra });
  assert.equal(selectLanAddress({ utun1: [address("10.5.0.4")], en1: [address("192.168.1.2")],
    en0: [address("203.0.113.1"), address("172.17.0.2")] }), "172.17.0.2");
  assert.equal(selectLanAddress({ en10: [address("192.168.1.10")], en2: [address("192.168.1.2")] }), "192.168.1.2");
  for (const name of ["utun1", "bridge0", "awdl0"]) {
    assert.throws(() => selectLanAddress({ en0: [address("203.0.113.1")], [name]: [address("10.5.0.4")] }),
      { code: "network_unavailable" });
  }
  assert.throws(() => selectLanAddress({ lo0: [address("127.0.0.1", { internal: true })], en0: [address("203.0.113.1")] }), /private local network/);
  assert.throws(() => selectLanAddress({ en0: [address("192.168.not-an-address")] }), /private local network/);
  assert.equal(advertisedHost("192.168.1.2", "My-Mac.local"), "My-Mac.local");
  assert.equal(advertisedHost("192.168.1.2", "https://invalid.local"), "192.168.1.2");
});

test("browser login only returns native HTTPS OpenAI URLs and never unrelated response fields", () => {
  const safe = safeLogin({ loginId: "id", authUrl: "https://auth.openai.com/authorize?state=flow", authToken: "SECRET" });
  assert.deepEqual(Object.keys(safe), ["loginId", "authUrl"]);
  for (const authUrl of ["file:///tmp/private", "http://auth.openai.com", "https://evil.test/", "https://auth.openai.com:8443/authorize", "https://auth.openai.com.evil.test", "https://user:password@auth.openai.com"]) {
    assert.throws(() => safeLogin({ loginId: "id", authUrl }), /sign-in flow/);
  }
  assert.deepEqual(publicError({ code: "ENOTFOUND", message: "SECRET private path" }), {
    code: "runtime_failed", message: "The local runtime stopped unexpectedly. Retry the connection.",
  });
});

test("JSONL handles fragmented UTF-8, malformed input and a bounded unterminated frame", () => {
  const stream = new PassThrough(), frames = [], failures = [];
  readFrames(stream, 64, (frame) => frames.push(frame), (error) => failures.push(error.code));
  const frame = Buffer.from('{"text":"中文"}\n');
  stream.write(frame.subarray(0, 11)); stream.write(frame.subarray(11));
  stream.write("no json\n"); stream.write(Buffer.from([0xff, 10]));
  stream.write(Buffer.alloc(65, 65)); stream.write("{}\n"); stream.end();
  assert.deepEqual(frames, [{ text: "中文" }]);
  assert.deepEqual(failures, ["invalid_request", "invalid_request", "request_too_large"]);
});

test("EPERM requires an observed empty process group, and failed inspection stays unconfirmed", () => {
  const denied = () => { throw Object.assign(new Error("denied"), { code: "EPERM" }); };
  assert.equal(groupExists(2147483647, { killImpl: denied }), false);
  const current = spawnSync("/bin/ps", ["-p", String(process.pid), "-o", "pgid="], { encoding: "utf8" });
  assert.equal(current.status, 0);
  assert.equal(groupExists(Number(current.stdout.trim()), { killImpl: denied }), true);
  for (const result of [{ status: 1, stdout: "" }, { status: 0, stdout: "invalid table" }, { status: 0, stdout: "" }]) {
    assert.throws(() => groupExists(2147483647, { killImpl: denied, listImpl: () => result }), { code: "EPERM" });
  }
});

test("read-only recovery refuses live owners and invalid process identity", async () => {
  assert.equal(await verifyCleanup(process.pid, 2147483647, { timeoutMs: 30 }), false);
  await assert.rejects(verifyCleanup(0, -1), { code: "invalid_request" });
  const result = spawnSync(process.execPath, [entry, "--verify-cleanup", "not-a-pid", "2"], { encoding: "utf8" });
  assert.equal(result.status, 1);
  assert.equal(JSON.parse(result.stdout).cleanupConfirmed, false);
  assert.equal(result.stderr, "");
});

test("private state and real project authorization reject symlinks and persist a canonical grant", async (t) => {
  const temp = temporary(t), root = path.join(temp, "state"), project = path.join(temp, "project");
  fs.mkdirSync(project);
  fs.symlinkSync(project, path.join(temp, "alias"));
  const host = createDesktopHost({ env: { MUNIE_HOST_STATE_DIR: root } });
  assert.equal((fs.statSync(root).mode & 0o777), 0o700);
  await assert.rejects(host.run("start"), /Choose a project/);
  await assert.rejects(host.run("project/set", { path: "." }), /project folder/);
  await assert.rejects(host.run("project/set", { path: entry }), /project folder/);
  const selected = await host.run("project/set", { path: path.join(temp, "alias") });
  assert.equal(selected.project.path, fs.realpathSync(project));
  assert.equal(fs.statSync(path.join(root, "host.json")).mode & 0o777, 0o600);
  assert.equal(createDesktopHost({ env: { MUNIE_HOST_STATE_DIR: root } }).status().project.path, fs.realpathSync(project));
  fs.rmdirSync(project);
  const reopened = createDesktopHost({ env: { MUNIE_HOST_STATE_DIR: root } });
  assert.equal(reopened.status().project, null);
  assert.equal(reopened.status().lastError.code, "invalid_project");
  const symlink = path.join(temp, "unsafe"); fs.symlinkSync(root, symlink);
  assert.throws(() => createDesktopHost({ env: { MUNIE_HOST_STATE_DIR: symlink } }), /private host state/);
});

test("protocol rejects malformed, duplicate, arbitrary-RPC and oversized requests without echoing data", async (t) => {
  const temp = temporary(t);
  const client = launchProtocol(t, { MUNIE_HOST_STATE_DIR: path.join(temp, "state") });
  const ready = await client.wait((frame) => frame.event === "ready");
  assert.equal(ready.data.lanAvailable, false);
  assert.equal(ready.data.lanRevision, 0);
  client.child.stdin.write('not JSON SECRET\n');
  assert.equal((await client.wait((frame) => frame.id === null)).error.code, "invalid_request");
  assert.equal((await client.call("turn/start", { input: "SECRET" })).error.code, "method_not_found");
  assert.equal((await client.call("account/read")).error.code, "not_running");
  client.child.stdin.write(JSON.stringify({ v: 1, id: "duplicate", method: "status" }) + "\n" + JSON.stringify({ v: 1, id: "duplicate", method: "status" }) + "\n");
  await client.wait((frame) => frame.id === "duplicate" && frame.error?.code === "invalid_request");
  client.child.stdin.write(Array.from({ length: 34 }, (_, index) => JSON.stringify({ v: 1, id: `batch${index}`, method: "status" }) + "\n").join(""));
  await client.wait((frame) => frame.error?.code === "busy");
  client.child.stdin.write("S".repeat(MAX_REQUEST_BYTES + 1));
  await client.wait((frame) => frame.error?.code === "request_too_large");
  client.child.stdin.end();
  await client.closed;
  assert.equal(client.stderr(), "");
  assert.equal(client.raw().includes("SECRET"), false);
});

test("unavailable private state remains inspectable through the protocol", async (t) => {
  const client = launchProtocol(t, { MUNIE_HOST_STATE_DIR: "relative" });
  const ready = await client.wait((frame) => frame.event === "ready");
  assert.equal(ready.data.state, "error");
  assert.equal(ready.data.lastError.code, "state_unavailable");
  for (const snapshot of [ready.data, (await client.call("status")).result]) {
    assert.equal(snapshot.cleanupConfirmed, true);
    assert.equal(snapshot.lanAvailable, false);
    assert.equal(snapshot.lanRevision, 0);
  }
  assert.equal((await client.call("start")).error.code, "state_unavailable");
  const stopped = await client.call("stop");
  assert.equal(stopped.result.state, "stopped");
  assert.equal(stopped.result.cleanupConfirmed, true);
  assert.equal(stopped.result.lanRevision, 0);
  assert.equal((await client.call("status")).result.lastError.code, "state_unavailable");
  client.child.stdin.end();
  assert.equal((await client.closed).code, 0);
});

test("corrupt saved state can confirm stop and quit without claiming startup success", async (t) => {
  const root = path.join(temporary(t), "state"); fs.mkdirSync(root);
  fs.writeFileSync(path.join(root, "host.json"), "invalid config");
  const client = launchProtocol(t, { MUNIE_HOST_STATE_DIR: root });
  const ready = await client.wait((frame) => frame.event === "ready");
  assert.equal(ready.data.lastError.code, "state_unavailable");
  const stopped = (await client.call("stop")).result;
  assert.equal(stopped.state, "stopped");
  assert.equal(stopped.cleanupConfirmed, true);
  assert.equal(stopped.lastError.code, "state_unavailable");
  client.child.stdin.end();
  assert.equal((await client.closed).code, 0);
});

test("bundled relay/native lifecycle, login redaction, trust reset, revoke and E2EE gate", { timeout: 30000, skip: process.platform !== "darwin" }, async (t) => {
  const fixture = setupRuntime(t), events = [];
  const host = createDesktopHost({ env: { ...fixture.env, NODE_OPTIONS: "--invalid-untrusted-option" }, emit: (event, data) => {
    events.push({ event, data });
    if (process.env.MUNIE_HOST_TEST_TRACE) console.error(event, data);
  } });
  t.after(() => host.stop());
  await host.run("project/set", { path: fixture.project });
  const started = await host.run("start");
  assert.equal(started.state, "running");
  assert.equal(started.cleanupConfirmed, false);
  assert.equal(started.ownership.ownerPid, process.pid);
  assert.ok(started.ownership.groupId > 1);
  assert.equal(started.bridge.connectionStatus, "connected");
  const runtimeEnvironment = JSON.parse(fs.readFileSync(fixture.runtimeRecord));
  assert.equal(runtimeEnvironment.cwd, fixture.project);
  assert.equal(runtimeEnvironment.codexHome, path.join(fixture.env.MUNIE_HOST_STATE_DIR, "codex"));
  assert.equal(runtimeEnvironment.endpoint, undefined);
  assert.equal(runtimeEnvironment.nodeOptions, undefined);
  const first = await host.run("pairing/get");
  assert.equal(first.payload.v, 2);
  assert.match(first.payload.relay, /^ws:\/\/[a-z0-9.-]+:\d+\/relay$/i);
  assert.equal(new URL(first.payload.relay).pathname, "/relay");
  assert.ok(first.payload.expiresAt > Date.now());
  assert.equal(first.code.length, 10);
  const initialPids = fixture.pids();
  await delay(5);
  const refreshed = await host.run("pairing/get");
  assert.ok(refreshed.payload.expiresAt > first.payload.expiresAt);
  assert.equal(refreshed.payload.sessionId, first.payload.sessionId);
  assert.equal(refreshed.payload.macDeviceId, first.payload.macDeviceId);
  assert.deepEqual(fixture.pids(), initialPids, "refresh must preserve the native runtime and active work");
  const account = await host.run("account/read");
  assert.equal(account.status, "not_logged_in");
  const login = await host.run("account/login/start");
  assert.equal(login.authUrl, "https://auth.openai.com/authorize?state=synthetic");
  await until(() => events.some((event) => event.event === "account" && event.data.status === "authenticated"));
  assert.equal(JSON.stringify(events).includes("SECRET_TOKEN"), false);
  assert.equal(JSON.stringify(login).includes("SECRET_TOKEN"), false);
  // The LAN socket cannot bypass the pre-existing authenticated encrypted channel.
  // Synthetic peers use the loopback listener; this does not claim physical LAN acceptance.
  const localRelay = new URL(first.payload.relay); localRelay.hostname = "127.0.0.1";
  const socket = new WebSocket(`${localRelay.href}/${first.payload.sessionId}`, { headers: { "x-role": "iphone" } });
  t.after(() => socket.terminate());
  const received = [];
  socket.on("message", (data) => received.push(JSON.parse(data.toString())));
  await new Promise((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); });
  socket.send(JSON.stringify({ id: "plaintext", method: "account/read", params: {} }));
  await until(() => received.some((message) => message.kind === "secureError"));
  assert.equal(received.some((message) => message.id === "plaintext" && message.result), false);
  socket.terminate();
  const reset = await host.run("pairing/reset");
  assert.equal(reset.state, "running");
  const second = await host.run("pairing/get");
  assert.notEqual(second.payload.sessionId, first.payload.sessionId);
  assert.equal(second.payload.macDeviceId, first.payload.macDeviceId);
  const stateFile = path.join(fixture.env.MUNIE_HOST_STATE_DIR, "bridge", "device-state.json");
  const trust = JSON.parse(fs.readFileSync(stateFile));
  trust.trustedPhones = { "fixture-phone": "synthetic-public-key" };
  fs.writeFileSync(stateFile, JSON.stringify(trust), { mode: 0o600 });
  assert.equal(host.status().devices[0].id, "fixture-phone");
  await assert.rejects(host.run("devices/revoke", { deviceId: "other" }), /no longer available/);
  await host.run("devices/revoke", { deviceId: "fixture-phone" });
  assert.deepEqual(host.status().devices, []);
  assert.equal((await host.run("pairing/get")).payload.macDeviceId, first.payload.macDeviceId);
  const stopped = await host.run("stop");
  assert.equal(stopped.state, "stopped");
  assert.equal(stopped.cleanupConfirmed, true);
  for (const pid of fixture.pids()) assert.equal(alive(pid), false, `owned process ${pid} survived`);
  assert.equal((await host.run("retry")).state, "running");
  assert.equal((await host.run("stop")).cleanupConfirmed, true);
});

test("EOF cleans the guarded native group and a killed GUI controller cannot orphan it", { timeout: 30000, skip: process.platform !== "darwin" }, async (t) => {
  const fixture = setupRuntime(t);
  const sentinel = spawn(process.execPath, ["-e", "setInterval(()=>{},1000)"], { stdio: "ignore" });
  t.after(() => sentinel.kill("SIGKILL"));
  const client = launchProtocol(t, fixture.env);
  await client.wait((frame) => frame.event === "ready");
  await client.call("project/set", { path: fixture.project });
  assert.equal((await client.call("start")).result.state, "running");
  await until(() => fixture.pids().length >= 2);
  client.child.stdin.end();
  assert.equal((await client.closed).code, 0);
  await until(() => fixture.pids().every((pid) => !alive(pid)));
  const other = launchProtocol(t, fixture.env);
  await other.wait((frame) => frame.event === "ready");
  const otherRunning = (await other.call("start")).result;
  assert.equal(otherRunning.state, "running");
  assert.equal(otherRunning.ownership.ownerPid, other.child.pid);
  await until(() => fixture.pids().length >= 4);
  other.child.kill("SIGKILL");
  await other.closed;
  const recovery = spawnSync(process.execPath, [entry, "--verify-cleanup", String(other.child.pid), String(otherRunning.ownership.groupId)], { encoding: "utf8", timeout: 11000 });
  assert.equal(recovery.status, 0, recovery.stderr || recovery.stdout);
  const recovered = JSON.parse(recovery.stdout);
  assert.equal(recovered.cleanupConfirmed, true);
  assert.deepEqual(recovered.ownership, otherRunning.ownership);
  await until(() => fixture.pids().every((pid) => !alive(pid)), 8000);
  assert.equal(other.stderr(), "");
  assert.equal(alive(sentinel.pid), true, "unrelated process must survive owned cleanup");
});

test("unexpected native failure or exit zero is observable, cleaned and retryable without leaking stderr", { timeout: 30000, skip: process.platform !== "darwin" }, async (t) => {
  const fixture = setupRuntime(t), events = [];
  const host = createDesktopHost({ env: fixture.env, emit: (event, data) => events.push({ event, data }) });
  t.after(() => host.stop());
  await host.run("project/set", { path: fixture.project });
  await host.run("start");
  await until(() => host.status().lanAvailable);
  assert.equal(host.status().lanRevision, 1);
  await until(() => fixture.pids().length >= 2);
  process.kill(fixture.pids()[0], "SIGKILL");
  await until(() => host.status().state === "error" && host.status().cleanupConfirmed);
  assert.equal(host.status().lastError.code, "runtime_failed");
  assert.equal(host.status().lanAvailable, false);
  assert.equal(host.status().lanRevision, 2);
  assert.equal(JSON.stringify(events).includes("SECRET_STDERR"), false);
  assert.equal((await host.run("retry")).state, "running");
  await until(() => host.status().lanAvailable);
  assert.equal(host.status().lanRevision, 3);
  await until(() => fixture.pids().length >= 4);
  process.kill(fixture.pids()[2], "SIGUSR1");
  await until(() => host.status().state === "error" && host.status().cleanupConfirmed);
  assert.equal(host.status().lastError.code, "runtime_failed");
  assert.equal(host.status().lanAvailable, false);
  assert.equal((await host.run("stop")).lanRevision, 4);
  for (const pid of fixture.pids()) assert.equal(alive(pid), false);
});

test("saved phone relay URL resolves a new signed trusted session after restart and project changes", { timeout: 30000, skip: process.platform !== "darwin" }, async (t) => {
  const fixture = setupRuntime(t);
  fs.mkdirSync(fixture.env.MUNIE_HOST_STATE_DIR, { mode: 0o700 });
  const configFile = path.join(fixture.env.MUNIE_HOST_STATE_DIR, "host.json");
  // Legacy files did not contain a relayPort.
  fs.writeFileSync(configFile, JSON.stringify({ projectPath: fixture.project }));
  const host = createDesktopHost({ env: fixture.env }); t.after(() => host.stop());
  const identity = generateKeyPairSync("ed25519");
  const publicKey = Buffer.from(identity.publicKey.export({ format: "jwk" }).x, "base64url").toString("base64");
  const phoneId = "restart-test-phone";
  const trust = require("../src/secure-device-state");
  const macState = trust.rememberTrustedPhone(trust.loadOrCreateBridgeDeviceState(), phoneId, publicKey);
  await host.run("start");
  const saved = (await host.run("pairing/get")).payload;
  const makeBody = () => {
    const body = { macDeviceId: macState.macDeviceId, phoneDeviceId: phoneId, phoneIdentityPublicKey: publicKey, nonce: randomUUID(), timestamp: Date.now() };
    const fields = ["remodex-trusted-session-resolve-v1", body.macDeviceId, phoneId, Buffer.from(publicKey, "base64"), body.nonce, String(body.timestamp)];
    const transcript = Buffer.concat(fields.map((value) => {
      const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value); const length = Buffer.alloc(4); length.writeUInt32BE(bytes.length); return Buffer.concat([length, bytes]);
    }));
    return { ...body, signature: sign(null, transcript, identity.privateKey).toString("base64") };
  };
  const first = await resolveSavedRelay(saved.relay, makeBody());
  assert.equal(first.status, 200); assert.equal(first.body.sessionId, saved.sessionId);
  const port = JSON.parse(fs.readFileSync(configFile)).relayPort;
  assert.equal(String(port), new URL(saved.relay).port);
  await host.run("stop"); await host.run("start");
  const restarted = (await host.run("pairing/get")).payload;
  assert.equal(restarted.relay, saved.relay); assert.notEqual(restarted.sessionId, saved.sessionId);
  const resolved = await resolveSavedRelay(saved.relay, makeBody());
  assert.equal(resolved.status, 200); assert.equal(resolved.body.sessionId, restarted.sessionId);
  assert.equal(resolved.body.macIdentityPublicKey, saved.macIdentityPublicKey);
  const invalid = makeBody(); invalid.signature = Buffer.alloc(64).toString("base64");
  assert.equal((await resolveSavedRelay(saved.relay, invalid)).status, 403);
  const secondProject = path.join(path.dirname(fixture.project), "second-project"); fs.mkdirSync(secondProject);
  await host.run("project/set", { path: secondProject });
  assert.equal(JSON.parse(fs.readFileSync(configFile)).relayPort, port);
  assert.equal((await host.run("pairing/get")).payload.relay, saved.relay);
  await host.run("stop");
});

test("saved relay port conflict fails explicitly and retry keeps the same port", { timeout: 30000, skip: process.platform !== "darwin" }, async (t) => {
  const fixture = setupRuntime(t), host = createDesktopHost({ env: fixture.env }); t.after(() => host.stop());
  await host.run("project/set", { path: fixture.project }); await host.run("start");
  const saved = (await host.run("pairing/get")).payload.relay, port = Number(new URL(saved).port);
  await host.run("stop");
  const blocker = net.createServer(); t.after(() => blocker.close());
  await new Promise((resolve) => blocker.listen(port, "127.0.0.1", resolve));
  await assert.rejects(host.run("start"), { code: "relay_port_unavailable" });
  assert.equal(host.status().cleanupConfirmed, true);
  await new Promise((resolve) => blocker.close(resolve));
  await host.run("retry");
  assert.equal((await host.run("pairing/get")).payload.relay, saved);
  await host.run("stop");
});

test("LAN loss and fixed-port rebind preserve the guarded runtime and relay session", { timeout: 35000, skip: process.platform !== "darwin" }, async (t) => {
  const fixture = setupRuntime(t);
  const folder = path.dirname(fixture.project), address = selectLanAddress();
  const networkFile = path.join(folder, "network.json"), polls = path.join(folder, "polls.jsonl");
  const preload = path.join(folder, "network-fixture.cjs");
  const setLan = (value) => {
    const next = `${networkFile}.next`;
    fs.writeFileSync(next, JSON.stringify(value));
    fs.renameSync(next, networkFile);
  };
  setLan(address);
  // Give only the worker a synthetic interface view. TCP/HTTP/WS bindings and
  // the native guardian are real; no interfaces or OS settings are changed.
  fs.writeFileSync(preload, `const fs = require('node:fs');
    require('node:os').networkInterfaces = () => {
      const address = JSON.parse(fs.readFileSync(${JSON.stringify(networkFile)}, 'utf8'));
      fs.appendFileSync(${JSON.stringify(polls)}, JSON.stringify(address) + '\\n');
      const tunnel = { address: ${JSON.stringify(address)}, family: 'IPv4', internal: false };
      return { utun0: [tunnel], en0: address ? [{ ...tunnel, address }] : [] };
    };`);
  const statuses = [];
  const host = createDesktopHost({ env: fixture.env, emit: (event, data) => {
    if (event === "status") statuses.push(data);
  }, spawnImpl: (executable, args, options) =>
    spawn(executable, [...args.slice(0, 2), "--require", preload, ...args.slice(2)], options) });
  t.after(() => host.stop());
  await host.run("project/set", { path: fixture.project });
  const started = await host.run("start");
  const first = (await host.run("pairing/get")).payload;
  assert.equal(host.status().lanRevision, 1);
  const port = Number(new URL(first.relay).port);
  const originalPids = fixture.pids();
  assert.equal(originalPids.length, 2);
  const sockets = [];
  t.after(() => { for (const socket of sockets) socket.destroy(); });
  async function connectTCP(hostname) {
    const socket = net.createConnection({ host: hostname, port });
    sockets.push(socket);
    const closed = new Promise((resolve) => socket.once("close", resolve));
    await new Promise((resolve, reject) => { socket.once("connect", resolve); socket.on("error", reject); });
    return { socket, closed };
  }
  async function connectWS(hostname, sessionId, role) {
    const socket = new WebSocket(`ws://${hostname}:${port}/relay/${sessionId}`, { headers: { "x-role": role } });
    t.after(() => socket.terminate());
    const closed = new Promise((resolve) => socket.once("close", resolve));
    await new Promise((resolve, reject) => { socket.once("open", resolve); socket.on("error", reject); });
    await ping(socket);
    return { socket, closed };
  }
  async function ping(socket) {
    assert.equal(socket.readyState, WebSocket.OPEN);
    await new Promise((resolve, reject) => {
      const closedEarly = () => reject(new Error("Relay closed before pong"));
      socket.once("close", closedEarly);
      socket.once("pong", () => { socket.off("close", closedEarly); resolve(); });
      socket.ping();
    });
  }
  // Use a separate room so this loopback WS cannot replace the phone fixture.
  const local = await connectWS("127.0.0.1", randomUUID(), "mac");
  const oldHttp = await connectTCP(address);
  oldHttp.socket.write("GET /health HTTP/1.1\r\n");
  const oldPhone = await connectWS(address, first.sessionId, "iphone");
  setLan(null);
  await Promise.all([oldHttp.closed, oldPhone.closed]);
  await until(() => host.status().state !== "running" || host.status().lanAvailable === false, 7000);
  assert.equal(host.status().state, "running", "LAN loss must not exit the worker");
  assert.equal(host.status().lastError, null);
  assert.equal(host.status().pairingAvailable, false);
  assert.equal(host.status().lanRevision, 2);
  await assert.rejects(host.run("pairing/get"), { code: "pairing_unavailable" });
  assert.equal((await host.run("account/read")).status, "not_logged_in");
  await ping(local.socket);
  await assert.rejects(connectTCP(address), { code: "ECONNREFUSED" });

  // Keep the original port occupied on LAN across two polls, without touching loopback.
  const blocker = net.createServer((socket) => socket.destroy());
  t.after(() => blocker.close());
  await new Promise((resolve, reject) => { blocker.on("error", reject); blocker.listen(port, address, resolve); });
  const pollLines = () => fs.readFileSync(polls, "utf8").trim().split("\n");
  const beforeReturn = pollLines().length;
  setLan(address);
  await until(() => pollLines().slice(beforeReturn).filter((line) => line === JSON.stringify(address)).length >= 2, 12000);
  assert.equal(host.status().state, "running");
  assert.equal(host.status().lanAvailable, false);
  assert.equal(host.status().lanRevision, 2);
  assert.deepEqual(fixture.pids(), originalPids);
  await new Promise((resolve) => blocker.close(resolve));
  await until(() => host.status().lanAvailable === true, 7000);

  const rebound = (await host.run("pairing/get")).payload;
  assert.equal(host.status().pairingAvailable, true);
  assert.equal(host.status().lanRevision, 3);
  assert.deepEqual(host.status().ownership, started.ownership);
  assert.equal(rebound.relay, first.relay);
  assert.equal(rebound.sessionId, first.sessionId);
  assert.equal(rebound.macDeviceId, first.macDeviceId);
  assert.equal(rebound.macIdentityPublicKey, first.macIdentityPublicKey);
  assert.deepEqual(fixture.pids(), originalPids);
  await ping(local.socket);
  const phone = await connectWS(address, first.sessionId, "iphone");
  const stopped = await host.run("stop");
  await Promise.all([phone.closed, local.closed]);
  assert.equal(stopped.cleanupConfirmed, true);
  assert.equal(stopped.lanAvailable, false);
  assert.equal(stopped.lanRevision, 4);
  assert.equal(stopped.state, "stopped");
  await assert.rejects(connectTCP(address), { code: "ECONNREFUSED" });
  await assert.rejects(connectTCP("127.0.0.1"), { code: "ECONNREFUSED" });
  for (const pid of originalPids) assert.equal(alive(pid), false);

  // A cold start with no LAN still provides local account control on the saved port.
  setLan(null);
  const offlineStart = await host.run("start");
  assert.equal(offlineStart.state, "running");
  assert.equal(offlineStart.lanAvailable, false);
  assert.equal(offlineStart.lanRevision, 4);
  assert.equal(offlineStart.pairingAvailable, false);
  assert.equal((await host.run("account/read")).status, "not_logged_in");
  assert.equal(JSON.parse(fs.readFileSync(path.join(fixture.env.MUNIE_HOST_STATE_DIR, "host.json"))).relayPort, port);
  assert.equal((await host.run("stop")).cleanupConfirmed, true);
  let previous = { lanAvailable: false, lanRevision: 0 };
  for (const snapshot of statuses) {
    assert.equal(typeof snapshot.lanAvailable, "boolean");
    assert.ok(Number.isSafeInteger(snapshot.lanRevision));
    assert.equal(snapshot.lanRevision, previous.lanRevision + Number(snapshot.lanAvailable !== previous.lanAvailable));
    assert.equal(snapshot.pairingAvailable, snapshot.state === "running" && snapshot.lanAvailable);
    previous = snapshot;
  }
});

test("managed loopback route preserves the incumbent and uses the existing guarded bridge", { timeout: 30000, skip: process.platform !== "darwin" }, async (t) => {
  const { startManagedRelayPilot } = require("../../MunieRemodexRelay/managed-relay-pilot");
  const { managedAdmissionTranscript } = require("../../MunieRemodexRelay/managed-admission");
  const fixture = setupRuntime(t);
  const mac = generateKeyPairSync("ed25519"), phone = generateKeyPairSync("ed25519");
  const macKey = mac.publicKey.export({ format: "jwk" }).x, phoneKey = phone.publicKey.export({ format: "jwk" }).x;
  const macDeviceId = randomUUID(), phoneDeviceId = randomUUID();
  const relay = await startManagedRelayPilot({ audience: "munie-loopback.invalid", allowedMacKeys: [macKey] });
  const host = createDesktopHost({ env: { ...fixture.env, MUNIE_DEVELOPER_MANAGED_RELAY: relay.origin } });
  t.after(async () => { try { await host.stop(); } finally { await relay.close(); } });
  const stateFile = path.join(fixture.env.MUNIE_HOST_STATE_DIR, "bridge", "device-state.json");
  fs.writeFileSync(stateFile, JSON.stringify({
    version: 1, macDeviceId,
    macIdentityPublicKey: Buffer.from(macKey, "base64url").toString("base64"),
    macIdentityPrivateKey: Buffer.from(mac.privateKey.export({ format: "jwk" }).d, "base64url").toString("base64"),
    trustedPhones: { [phoneDeviceId]: Buffer.from(phoneKey, "base64url").toString("base64") },
  }), { mode: 0o600 });

  const challenge = () => fetch(`${relay.origin}/v1/managed/challenge`, {
    method: "POST", body: JSON.stringify({ role: "phone", macKey, phoneKey }),
    signal: AbortSignal.timeout(1500),
  });
  async function connect(url, headers) {
    const socket = new WebSocket(url, { headers, handshakeTimeout: 3000 });
    const closed = new Promise((resolve) => socket.once("close", resolve));
    const messages = [];
    socket.on("message", (data) => messages.push(JSON.parse(data.toString())));
    t.after(() => socket.terminate());
    await new Promise((resolve, reject) => { socket.once("open", resolve); socket.on("error", reject); });
    return { socket, closed, messages };
  }
  async function connectAway() {
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      const response = await challenge();
      const value = await response.json();
      if (response.ok) {
        return connect(`${relay.origin.replace(/^http/, "ws")}/v1/managed/connect`, {
          "x-munie-role": "phone", "x-munie-challenge": value.id,
          "x-munie-proof": sign(null, managedAdmissionTranscript(value), phone.privateKey).toString("base64url"),
        });
      }
      assert.equal(response.status, 403);
      await delay(50);
    }
    assert.fail("Managed route did not register");
  }
  async function requiresV2(peer) {
    const before = peer.messages.filter((message) => message.kind === "secureError").length;
    peer.socket.send(JSON.stringify({ id: "fixture-read", method: "account/read", params: {} }));
    await until(() => peer.messages.filter((message) => message.kind === "secureError").length > before);
    assert.equal(peer.messages.some((message) => message.id === "fixture-read"), false);
  }

  await host.run("project/set", { path: fixture.project });
  const initial = await host.run("start");
  const nativePids = fixture.pids();
  const first = await connectAway();
  await until(() => first.messages.some((message) => message.kind === "managedRouteReady"));
  const { sessionId } = first.messages.find((message) => message.kind === "managedRouteReady");
  assert.equal(typeof sessionId, "string");
  await requiresV2(first);
  const identity = { sessionId, mac, phone, macDeviceId, phoneDeviceId };
  const firstChannel = await openFixtureSecureChannel(first, identity);
  firstChannel.send({ id: "same-id", method: "model/list", params: { limit: 17 } });
  await until(() => firstChannel.read().some((message) => message.method === "fixture/model-list-pending"));

  const port = JSON.parse(fs.readFileSync(path.join(fixture.env.MUNIE_HOST_STATE_DIR, "host.json"))).relayPort;
  const lanURL = `ws://127.0.0.1:${port}/relay/${sessionId}`;
  const deniedLAN = await connect(lanURL, { "x-role": "iphone" });
  await deniedLAN.closed;
  assert.deepEqual(deniedLAN.messages, []);
  await requiresV2(first);
  first.socket.terminate();
  await first.closed;
  let lan;
  for (let attempt = 0; attempt < 50; attempt++) {
    lan = await connect(lanURL, { "x-role": "iphone" });
    const outcome = await Promise.race([lan.closed.then(() => "closed"), delay(30, "open")]);
    if (outcome === "open") break;
  }
  assert.equal(lan.socket.readyState, WebSocket.OPEN);
  const lanChannel = await openFixtureSecureChannel(lan, identity);
  const blocked = await connectAway();
  await blocked.closed;
  assert.deepEqual(blocked.messages, []);
  await requiresV2(lan);
  lanChannel.send({ id: "same-id", method: "model/list", params: { limit: 19 } });
  await until(() => lanChannel.read().some((message) => message.id === "same-id"));
  assert.deepEqual(lanChannel.read().filter((message) => message.id === "same-id"), [
    { id: "same-id", result: { current: true } },
  ]);
  lanChannel.send({ id: "oversized", method: "model/list", params: { limit: 18 } });
  await until(() => lanChannel.read().some((message) => message.id === "oversized"));
  assert.equal(lanChannel.read().find((message) => message.id === "oversized").error.data.errorCode,
    "relay_response_too_large");
  lan.socket.terminate();
  await lan.closed;
  const resumed = await connectAway();
  await until(() => resumed.messages.some((message) => message.kind === "managedRouteReady"));
  assert.ok(resumed.messages.some((message) => message.kind === "managedRouteReady" && message.sessionId === sessionId));
  assert.deepEqual(fixture.pids(), nativePids);
  assert.deepEqual(host.status().ownership, initial.ownership);
  assert.equal((await host.run("account/read")).status, "not_logged_in");
  await host.run("devices/revoke", { deviceId: phoneDeviceId });
  await resumed.closed;
  assert.equal((await challenge()).status, 403);
  assert.deepEqual(host.status().devices, []);
});

async function openFixtureSecureChannel(peer, { sessionId, mac, phone, macDeviceId, phoneDeviceId }) {
  const macKey = mac.publicKey.export({ format: "jwk" }).x;
  const phoneKey = phone.publicKey.export({ format: "jwk" }).x;
  const ephemeral = generateKeyPairSync("x25519");
  const ephemeralKey = ephemeral.publicKey.export({ format: "jwk" }).x;
  const clientNonce = Buffer.alloc(32, 7);
  const handshakeMode = "trusted_reconnect";
  const send = (frame) => peer.socket.send(JSON.stringify(frame));
  const find = (kind) => peer.messages.find((frame) => frame.kind === kind);
  const base64 = (value) => Buffer.from(value, "base64url").toString("base64");
  send({ kind: "clientHello", sessionId, protocolVersion: 2, handshakeMode, phoneDeviceId,
    phoneIdentityPublicKey: base64(phoneKey), phoneEphemeralPublicKey: base64(ephemeralKey),
    clientNonce: clientNonce.toString("base64") });
  await until(() => find("serverHello"));
  const hello = find("serverHello");
  assert.equal(hello.macDeviceId, macDeviceId);
  assert.equal(hello.macIdentityPublicKey, base64(macKey));
  const prefixed = (value) => {
    const bytes = Buffer.from(value), length = Buffer.alloc(4);
    length.writeUInt32BE(bytes.length);
    return Buffer.concat([length, bytes]);
  };
  const tag = "remodex-e2ee-v1";
  const { keyEpoch } = hello;
  const transcript = Buffer.concat([
    tag, sessionId, "2", handshakeMode, String(keyEpoch), macDeviceId, phoneDeviceId,
    ...[macKey, phoneKey, hello.macEphemeralPublicKey, ephemeralKey].map((key) => Buffer.from(key, "base64")),
    clientNonce, Buffer.from(hello.serverNonce, "base64"), String(hello.expiresAtForTranscript),
  ].map(prefixed));
  assert.ok(verify(null, transcript, mac.publicKey, Buffer.from(hello.macSignature, "base64")));
  const phoneSignature = sign(null, Buffer.concat([transcript, prefixed("client-auth")]), phone.privateKey);
  send({ kind: "clientAuth", sessionId, keyEpoch, phoneDeviceId, phoneSignature: phoneSignature.toString("base64") });
  await until(() => find("secureReady"));
  const shared = diffieHellman({ privateKey: ephemeral.privateKey, publicKey: createPublicKey({
    format: "jwk", key: { kty: "OKP", crv: "X25519", x: Buffer.from(hello.macEphemeralPublicKey, "base64").toString("base64url") },
  }) });
  const salt = createHash("sha256").update(transcript).digest();
  const derive = (label) => Buffer.from(hkdfSync("sha256", shared, salt,
    Buffer.from([tag, sessionId, macDeviceId, phoneDeviceId, keyEpoch, label].join("|")), 32));
  const toMac = derive("phoneToMac"), fromMac = derive("macToPhone");
  let counter = 0;
  send({ kind: "resumeState", sessionId, keyEpoch, lastAppliedBridgeOutboundSeq: 0, bridgeReplayEpoch: hello.bridgeReplayEpoch });
  return {
    send(message) {
      const cipher = createCipheriv("aes-256-gcm", toMac, nonceForDirection("iphone", counter));
      const ciphertext = Buffer.concat([cipher.update(JSON.stringify({ payloadText: JSON.stringify(message) })), cipher.final()]);
      send({ kind: "encryptedEnvelope", v: 2, sessionId, keyEpoch, sender: "iphone", counter,
        ciphertext: ciphertext.toString("base64"), tag: cipher.getAuthTag().toString("base64") });
      counter += 1;
    },
    read() {
      return peer.messages.filter((frame) => frame.kind === "encryptedEnvelope").map((frame) => {
        const decipher = createDecipheriv("aes-256-gcm", fromMac, nonceForDirection("mac", frame.counter));
        decipher.setAuthTag(Buffer.from(frame.tag, "base64"));
        const payload = JSON.parse(Buffer.concat([decipher.update(Buffer.from(frame.ciphertext, "base64")), decipher.final()]));
        return JSON.parse(payload.payloadText);
      });
    },
  };
}

function resolveSavedRelay(savedURL, body) {
  const url = new URL(savedURL); url.protocol = "http:"; url.pathname += "/v1/trusted/session/resolve";
  // Exercise the saved hostname and port through the actual resolver while mapping DNS
  // to the synthetic loopback peer. Physical mDNS/DHCP acceptance remains separate.
  return new Promise((resolve, reject) => {
    const request = http.request(url, { method: "POST", family: 4, lookup: (_host, _options, done) => done(null, "127.0.0.1", 4),
      headers: { "content-type": "application/json" } }, (response) => {
      let data = ""; response.on("data", (chunk) => { data += chunk; });
      response.on("end", () => { try { resolve({ status: response.statusCode, body: JSON.parse(data) }); } catch (error) { reject(error); } });
    });
    request.on("error", reject); request.setTimeout(3000, () => request.destroy(new Error("Synthetic resolver timed out")));
    request.end(JSON.stringify(body));
  });
}

function temporary(t) {
  const folder = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "munie-desktop-host-")));
  t.after(() => fs.rmSync(folder, { recursive: true, force: true }));
  return folder;
}

let guardian;
function setupRuntime(t) {
  assert.equal(process.platform, "darwin", "native guardian acceptance requires macOS");
  const temp = temporary(t), project = path.join(temp, "project");
  fs.mkdirSync(project);
  if (!guardian) {
    const guardianDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "munie-desktop-guardian-"));
    guardian = path.join(guardianDirectory, "MunieCodexGuardian");
    const compilation = spawnSync("clang", ["-Wall", "-Wextra", "-Werror", path.join(repository, "apps/MunieHost/Guardian/main.c"), "-o", guardian], { encoding: "utf8" });
    assert.equal(compilation.status, 0, compilation.stderr);
    process.on("exit", () => fs.rmSync(guardianDirectory, { recursive: true, force: true }));
  }
  const pidsFile = path.join(temp, "owned-pids.jsonl"), codex = path.join(temp, "codex"), runtimeRecord = path.join(temp, "runtime.json");
  const source = `#!${process.execPath}
const fs=require('node:fs'),{spawn}=require('node:child_process');
const file=${JSON.stringify(pidsFile)};
fs.writeFileSync(${JSON.stringify(runtimeRecord)},JSON.stringify({cwd:process.cwd(),codexHome:process.env.CODEX_HOME,endpoint:process.env.REMODEX_CODEX_ENDPOINT,nodeOptions:process.env.NODE_OPTIONS}));
process.on('SIGUSR1',()=>process.exit(0));
fs.appendFileSync(file,process.pid+'\\n');
const descendant=spawn(process.execPath,['-e','process.on("SIGTERM",()=>{});setInterval(()=>{},1000)'],{stdio:'ignore'});
fs.appendFileSync(file,descendant.pid+'\\n');
console.error('SECRET_STDERR');
let authenticated=false,buffer='',pendingModelList=null;
process.stdin.on('data',chunk=>{buffer+=chunk;let end;while((end=buffer.indexOf('\\n'))>=0){const line=buffer.slice(0,end);buffer=buffer.slice(end+1);if(!line)continue;const r=JSON.parse(line);let result={};
switch(r.method){
case 'account/read': result={account:authenticated?{type:'chatgpt',email:'fixture@example.test',planType:'plus'}:null,requiresOpenaiAuth:true};break;
case 'getAuthStatus':result=authenticated?{authMethod:'chatgpt',authToken:'SECRET_TOKEN'}:{};break;
case 'model/list':
 if(r.params?.limit===17){pendingModelList=r.id;console.log(JSON.stringify({method:'fixture/model-list-pending',params:{}}));continue;}
 if(r.params?.limit===18)result={data:'x'.repeat(900*1024)};
 if(r.params?.limit===19){if(pendingModelList)console.log(JSON.stringify({id:pendingModelList,result:{old:true}}));result={current:true};}
 break;
case 'account/login/start':result={type:'chatgpt',loginId:'synthetic-login',authUrl:'https://auth.openai.com/authorize?state=synthetic',authToken:'SECRET_TOKEN'};setTimeout(()=>{authenticated=true;console.log(JSON.stringify({method:'account/login/completed',params:{loginId:'synthetic-login',success:true}}))},100);break;
}
if(r.id!==undefined)console.log(JSON.stringify({id:r.id,result}));
}});
`;
  fs.writeFileSync(codex, source, { mode: 0o700 });
  return { project, runtimeRecord, env: { MUNIE_HOST_STATE_DIR: path.join(temp, "state"), MUNIE_CODEX_BINARY: codex, MUNIE_GUARDIAN_BINARY: guardian,
    REMODEX_CODEX_ENDPOINT: "ws://untrusted.invalid" },
    pids: () => fs.existsSync(pidsFile) ? fs.readFileSync(pidsFile, "utf8").trim().split("\n").filter(Boolean).map(Number) : [] };
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { if (error.code === "ESRCH") return false; throw error; }
}

async function until(predicate, timeout = 5000) {
  const start = Date.now();
  while (!predicate()) { if (Date.now() - start > timeout) throw new Error("Condition timed out"); await delay(20); }
}

function launchProtocol(t, env) {
  const child = spawn(process.execPath, [entry], { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL"); });
  const frames = [], consumed = new Set(); let raw = "", stderr = "", next = 0;
  child.stdout.on("data", (chunk) => { raw += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  readFrames(child.stdout, 1024 * 1024, (frame) => frames.push(frame), (error) => { throw error; });
  const closed = new Promise((resolve) => child.once("close", (code, signal) => resolve({ code, signal })));
  async function wait(predicate) {
    let index;
    await until(() => { index = frames.findIndex((frame, i) => !consumed.has(i) && predicate(frame)); return index >= 0; }, 15000);
    consumed.add(index); return frames[index];
  }
  return { child, closed, wait, raw: () => raw, stderr: () => stderr,
    async call(method, params = {}) { const id = String(++next); child.stdin.write(JSON.stringify({ v: 1, id, method, params }) + "\n"); return wait((frame) => frame.id === id); } };
}
