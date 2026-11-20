// Munie Mac GUI process boundary. stdout is a bounded v1 JSONL protocol, never a log stream.
// The native guardian owns one detached group containing this worker, relay and Codex.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { isIPv4 } = require("node:net");
const { spawn, spawnSync } = require("node:child_process");
const { createHash, randomBytes } = require("node:crypto");
const { setTimeout: delay } = require("node:timers/promises");

const MAX_REQUEST_BYTES = 32 * 1024;
const MAX_FRAME_BYTES = 1024 * 1024;
const MESSAGES = {
  invalid_request: "The host request is invalid.",
  request_too_large: "The host request exceeds its size limit.",
  busy: "The host has too many pending requests.",
  method_not_found: "The host operation is unavailable.",
  state_unavailable: "The private host state could not be opened.",
  project_required: "Choose a project before starting the host.",
  invalid_project: "The selected project folder is unavailable.",
  runtime_unavailable: "The bundled runtime is unavailable.",
  network_unavailable: "Connect the Mac to a private local network.",
  relay_port_unavailable: "The saved local connection is in use. Close the other host and retry.",
  not_running: "Start the host before performing this operation.",
  runtime_failed: "The local runtime stopped unexpectedly. Retry the connection.",
  runtime_timeout: "The local runtime did not respond in time.",
  account_unavailable: "The account status could not be read. Retry sign-in.",
  api_key_unavailable: "The local runtime could not configure the OpenAI API key.",
  custom_provider_unavailable: "The local runtime could not configure the custom provider.",
  login_unavailable: "The runtime could not begin a supported sign-in flow.",
  pairing_unavailable: "A fresh pairing invitation is unavailable. Retry pairing.",
  device_not_found: "The paired device is no longer available.",
  cleanup_pending: "The host is still stopping. Retry before quitting.",
};

function hostError(code) {
  return Object.assign(new Error(MESSAGES[code] || MESSAGES.runtime_failed), { code });
}

function publicError(error) {
  const code = Object.hasOwn(MESSAGES, error?.code) ? error.code : "runtime_failed";
  return { code, message: MESSAGES[code] };
}

function readOpenAiApiKey(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 512
    || /[^\x21-\x7e]/u.test(value)) throw hostError("api_key_unavailable");
  return value;
}

function readCustomProvider(value) {
  try {
    if (!value || typeof value !== "object" || Array.isArray(value)
      || Object.keys(value).length !== 3 || typeof value.model !== "string"
      || !/^[A-Za-z0-9._:/-]{1,128}$/u.test(value.model)) throw new Error();
    const { providerEndpoint } = require("./custom-provider-broker");
    const endpoint = providerEndpoint(value.baseURL);
    const namespace = createHash("sha256").update(JSON.stringify([endpoint.href, value.model])).digest("hex");
    return { baseURL: value.baseURL, model: value.model, apiKey: readOpenAiApiKey(value.apiKey), namespace };
  } catch { throw hostError("custom_provider_unavailable"); }
}

// Retains at most one frame, including when a peer never sends a newline.
function readFrames(stream, maxBytes, receive, fail) {
  let buffer = Buffer.alloc(0), failed = false;
  function onData(chunk) {
    if (failed) return;
    let offset = 0;
    while (offset < chunk.length) {
      const end = chunk.indexOf(10, offset);
      const part = chunk.subarray(offset, end < 0 ? chunk.length : end);
      if (buffer.length + part.length > maxBytes) {
        failed = true;
        fail(hostError("request_too_large"));
        return;
      }
      buffer = Buffer.concat([buffer, part]);
      if (end < 0) return;
      const frame = buffer;
      buffer = Buffer.alloc(0);
      offset = end + 1;
      if (!frame.length) continue;
      try {
        const text = new TextDecoder("utf-8", { fatal: true }).decode(frame);
        receive(JSON.parse(text));
      } catch {
        fail(hostError("invalid_request"));
      }
    }
  }
  function onEnd() { if (buffer.length && !failed) fail(hostError("invalid_request")); }
  stream.on("data", onData);
  stream.on("end", onEnd);
  return () => {
    stream.off("data", onData);
    stream.off("end", onEnd);
  };
}

function writeFrame(stream, frame) {
  const text = JSON.stringify(frame) + "\n";
  if (Buffer.byteLength(text) > MAX_FRAME_BYTES || stream.writableLength > MAX_FRAME_BYTES * 2) {
    throw hostError("busy");
  }
  stream.write(text);
}

function privateDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw hostError("state_unavailable");
  fs.chmodSync(directory, 0o700);
  return fs.realpathSync(directory);
}

function writePrivateJSON(file, value) {
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value) + "\n", { mode: 0o600, flag: "wx" });
  fs.renameSync(temporary, file);
}

function executable(file) {
  if (!path.isAbsolute(file)) throw hostError("runtime_unavailable");
  try {
    fs.accessSync(file, fs.constants.X_OK);
    if (!fs.statSync(file).isFile()) throw new Error();
    return fs.realpathSync(file);
  } catch { throw hostError("runtime_unavailable"); }
}

function projectFolder(folder) {
  try {
    if (typeof folder !== "string" || !path.isAbsolute(folder) || folder.length > 4096) throw new Error();
    const canonical = fs.realpathSync(folder);
    if (!fs.statSync(canonical).isDirectory()) throw new Error();
    fs.accessSync(canonical, fs.constants.R_OK | fs.constants.W_OK | fs.constants.X_OK);
    return { path: canonical, name: path.basename(canonical) || canonical };
  } catch { throw hostError("invalid_project"); }
}

function selectLanAddress(interfaces = os.networkInterfaces()) {
  // Do not fall back to VPN tunnels or bridges when Wi-Fi/Ethernet disappears.
  const entries = Object.entries(interfaces)
    .filter(([name]) => /^en\d+$/.test(name))
    .sort(([a], [b]) => Number(a.slice(2)) - Number(b.slice(2)) || a.localeCompare(b));
  for (const [, addresses] of entries) {
    for (const entry of addresses || []) {
      if (entry.internal || entry.family !== "IPv4") continue;
      const address = entry.address;
      if (isIPv4(address) && (/^10\./.test(address) || /^192\.168\./.test(address)
        || /^172\.(1[6-9]|2\d|3[01])\./.test(address))) return address;
    }
  }
  throw hostError("network_unavailable");
}

function advertisedHost(address, hostname = os.hostname()) {
  return /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.local$/i.test(hostname) ? hostname : address;
}

function safeLogin(result) {
  try {
    const url = new URL(result?.authUrl);
    if (url.protocol !== "https:" || (url.port && url.port !== "443") || url.username || url.password
      || !["auth.openai.com", "auth0.openai.com", "chatgpt.com"].includes(url.hostname)
      || typeof result.loginId !== "string" || !result.loginId || result.loginId.length > 512
      || url.href.length > 16384) throw new Error();
    return { loginId: result.loginId, authUrl: url.href };
  } catch { throw hostError("login_unavailable"); }
}

function groupExists(pid, { killImpl = process.kill, listImpl = spawnSync } = {}) {
  try { killImpl(-pid, 0); return true; }
  catch (error) {
    if (error.code === "ESRCH") return false;
    if (error.code !== "EPERM") throw error;
    // macOS may return EPERM while the final group member is disappearing.
    // Confirm the actual process table; permission denial alone never means cleanup.
    const result = listImpl("/bin/ps", ["-axo", "pid=,pgid=,stat="], {
      encoding: "utf8", timeout: 1000, maxBuffer: MAX_FRAME_BYTES,
    });
    if (result.error || result.status !== 0) throw error;
    const rows = result.stdout.trim().split("\n").filter(Boolean);
    if (!rows.length || rows.some((row) => !/^\s*\d+\s+\d+\s+\S+\s*$/.test(row))) throw error;
    return rows.some((row) => Number(row.trim().split(/\s+/)[1]) === pid);
  }
}

async function verifyCleanup(ownerPid, groupId, { timeoutMs = 9000 } = {}) {
  const valid = (value) => Number.isSafeInteger(value) && value > 1 && value <= 2147483647;
  if (!valid(ownerPid) || !valid(groupId)) throw hostError("invalid_request");
  const deadline = Date.now() + timeoutMs;
  do {
    let ownerExists = true;
    try { process.kill(ownerPid, 0); }
    catch (error) { if (error.code === "ESRCH") ownerExists = false; else if (error.code !== "EPERM") throw error; }
    // A recycled owner PID or group remains conservative. Recovery never terminates a process.
    if (!ownerExists && !groupExists(groupId)) return true;
    await delay(Math.min(100, Math.max(0, deadline - Date.now())));
  } while (Date.now() < deadline);
  return false;
}

async function runCleanupVerification(arguments_) {
  let ownership = null;
  try {
    if (arguments_.length !== 2 || arguments_.some((value) => !/^\d+$/.test(value))) throw hostError("invalid_request");
    ownership = { ownerPid: Number(arguments_[0]), groupId: Number(arguments_[1]) };
    const cleanupConfirmed = await verifyCleanup(ownership.ownerPid, ownership.groupId);
    writeFrame(process.stdout, { v: 1, method: "verify-cleanup", ownership, cleanupConfirmed,
      error: cleanupConfirmed ? null : publicError(hostError("cleanup_pending")) });
    process.exitCode = cleanupConfirmed ? 0 : 1;
  } catch (error) {
    writeFrame(process.stdout, { v: 1, method: "verify-cleanup", ownership, cleanupConfirmed: false, error: publicError(error) });
    process.exitCode = 1;
  }
}

function bridgeSnapshot(value) {
  const connectionStatus = ["starting", "connecting", "connected", "disconnected", "error"].includes(value?.connectionStatus)
    ? value.connectionStatus : "disconnected";
  const codexLaunchState = ["starting", "connected", "error", "stopped"].includes(value?.codexLaunchState)
    ? value.codexLaunchState : "starting";
  // Phone summaries are constructed by the secure bridge, but expose only UI identity fields.
  const summary = (record) => record && typeof record === "object" ? {
    connected: record.connected === true,
    deviceId: typeof record.deviceId === "string" ? record.deviceId.slice(0, 512) : null,
    deviceKind: typeof record.deviceKind === "string" ? record.deviceKind.slice(0, 64) : null,
    fingerprint: typeof (record.phoneFingerprint || record.fingerprint) === "string"
      ? (record.phoneFingerprint || record.fingerprint).slice(0, 128) : null,
  } : null;
  return { connectionStatus, codexLaunchState, activeDevice: summary(value?.activeDevice), activePhone: summary(value?.activePhone) };
}

function createDesktopHost({ env = process.env, emit = () => {}, spawnImpl = spawn } = {}) {
  let root;
  try {
    if (!env.MUNIE_HOST_STATE_DIR || !path.isAbsolute(env.MUNIE_HOST_STATE_DIR)) throw new Error();
    root = privateDirectory(env.MUNIE_HOST_STATE_DIR);
    privateDirectory(path.join(root, "bridge"));
    privateDirectory(path.join(root, "codex"));
  } catch { throw hostError("state_unavailable"); }
  const configFile = path.join(root, "host.json");
  let project = null, initialProjectError = null, relayPort = null;
  try {
    if (fs.existsSync(configFile)) {
      if (fs.lstatSync(configFile).isSymbolicLink() || fs.statSync(configFile).size > MAX_REQUEST_BYTES) throw new Error();
      const saved = JSON.parse(fs.readFileSync(configFile, "utf8"));
      if (saved.relayPort !== undefined && saved.relayPort !== null) {
        if (!Number.isInteger(saved.relayPort) || saved.relayPort < 1024 || saved.relayPort > 65535) throw new Error();
        relayPort = saved.relayPort;
      }
      try { project = projectFolder(saved.projectPath); }
      catch (error) {
        if (error.code !== "invalid_project") throw error;
        initialProjectError = publicError(error);
      }
    }
  } catch { throw hostError("state_unavailable"); }
  // Scope existing canonical trust helpers to this app's state; never import legacy Keychain credentials.
  process.env.REMODEX_DEVICE_STATE_DIR = path.join(root, "bridge");
  process.env.REMODEX_DEVICE_STATE_FILE = path.join(root, "bridge", "device-state.json");
  process.env.REMODEX_DISABLE_KEYCHAIN = "1";
  const trust = require("./secure-device-state");
  let state = "stopped", worker = null, ownedGroup = null, stopping = false, cleanupTask = null;
  let bridge = null, account = null, lastError = initialProjectError;
  let apiKey = null, customProvider = null, workerAccountReady = true, workerKeySent = false;
  // The host owns the revision, not any of its replaceable workers.
  let lanAvailable = false, lanRevision = 0;
  let requestCounter = 0, readyResolve = null, readyReject = null;
  const pending = new Map();

  function devices() {
    const record = trust.readBridgeDeviceState();
    return Object.entries(record?.trustedPhones || {}).map(([id, key]) => ({
      id, fingerprint: createHash("sha256").update(key).digest("hex"),
    }));
  }
  function status() {
    return { state, project, bridge, account, devices: devices(), lanAvailable, lanRevision,
      pairingAvailable: state === "running" && lanAvailable,
      lastError, cleanupConfirmed: ownedGroup === null,
      ownership: ownedGroup === null ? null : { ownerPid: process.pid, groupId: ownedGroup } };
  }
  function publish() { emit("status", status()); }
  function updateLanAvailability(available) {
    if (lanAvailable === available) return false;
    lanAvailable = available;
    lanRevision = Math.min(lanRevision + 1, Number.MAX_SAFE_INTEGER);
    return true;
  }
  function rejectPending() {
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(hostError("runtime_failed")); }
    pending.clear();
  }
  function finishStartup() {
    if (!readyResolve || bridge?.codexLaunchState !== "connected"
      || bridge.connectionStatus !== "connected") return;
    if (workerAccountReady) readyResolve();
    else if (!workerKeySent) {
      workerKeySent = true;
      writeFrame(worker.stdin, { method: "account/api-key/configure", apiKey });
    }
  }
  function receive(frame) {
    if (frame?.event === "relay") {
      const port = frame.data?.port;
      if (!Number.isInteger(port) || port < 1024 || port > 65535 || (relayPort !== null && relayPort !== port)) throw hostError("runtime_failed");
      relayPort = port;
      writePrivateJSON(configFile, { projectPath: project.path, relayPort });
    } else if (frame?.event === "fatal") {
      readyReject?.(hostError(frame.data?.code));
    } else if (frame?.event === "bridge") {
      bridge = bridgeSnapshot(frame.data);
      finishStartup();
      publish();
    } else if (frame?.event === "api-key-ready") {
      if (!workerKeySent || workerAccountReady) throw hostError("runtime_failed");
      workerAccountReady = true;
      finishStartup();
    } else if (frame?.event === "lan") {
      if (typeof frame.data !== "boolean") throw hostError("runtime_failed");
      if (!stopping && updateLanAvailability(frame.data)) publish();
    } else if (frame?.event === "account") {
      account = frame.data;
      emit("account", account);
      publish();
    } else if (typeof frame?.id === "string") {
      const entry = pending.get(frame.id);
      if (!entry) return;
      clearTimeout(entry.timer);
      pending.delete(frame.id);
      if (frame.error) entry.reject(hostError(frame.error.code)); else entry.resolve(frame.result);
    }
  }
  function request(method) {
    if (state !== "running" || !worker?.stdin.writable) throw hostError("not_running");
    const id = String(++requestCounter);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(hostError("runtime_timeout")); }, 12_000);
      pending.set(id, { resolve, reject, timer });
      try { writeFrame(worker.stdin, { id, method }); }
      catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
    });
  }
  async function performStop() {
    stopping = true;
    state = "stopping";
    updateLanAvailability(false);
    publish();
    rejectPending();
    try {
      worker?.stdin.end();
      const group = ownedGroup;
      if (group !== null) {
        const started = Date.now();
        while (groupExists(group) && Date.now() - started < 5500) {
          const elapsed = Date.now() - started;
          if (elapsed > 4000) { try { process.kill(-group, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; } }
          else if (elapsed > 2500) { try { process.kill(-group, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; } }
          await delay(25);
        }
        if (groupExists(group)) throw hostError("cleanup_pending");
      }
      worker = null;
      ownedGroup = null;
      bridge = null;
      account = null;
      state = "stopped";
      lastError = null;
    } catch (error) {
      state = "error";
      lastError = publicError(hostError("cleanup_pending"));
      const failure = hostError("cleanup_pending");
      failure.cause = { code: error?.code || "unknown", name: error?.name || "Error" };
      throw failure;
    } finally { stopping = false; publish(); }
    return status();
  }
  function stop() {
    if (!cleanupTask) cleanupTask = performStop().finally(() => { cleanupTask = null; });
    return cleanupTask;
  }
  async function start() {
    if (cleanupTask) await cleanupTask;
    if (state === "running") return status();
    if (ownedGroup !== null) await stop();
    if (!project) throw hostError("project_required");
    project = projectFolder(project.path);
    const codex = executable(env.MUNIE_CODEX_BINARY || path.resolve(__dirname, "../../../Runtime/bin/codex"));
    const guardian = executable(env.MUNIE_GUARDIAN_BINARY || path.resolve(__dirname, "../../../Runtime/bin/MunieCodexGuardian"));
    const profileDirectory = customProvider ? `codex-custom-${customProvider.namespace}`
      : apiKey === null ? "codex" : "codex-openai-api";
    const codexHome = privateDirectory(path.join(root, profileDirectory));
    state = "starting"; lastError = null; bridge = null; account = null;
    workerAccountReady = apiKey === null;
    workerKeySent = false;
    updateLanAvailability(false);
    publish();
    const childEnv = {
      HOME: os.homedir(), PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR: os.tmpdir(), LANG: "en_US.UTF-8",
      MUNIE_HOST_STATE_DIR: root, MUNIE_HOST_PROJECT_ROOT: project.path,
      MUNIE_HOST_RELAY_PORT: String(relayPort || 0),
      REMODEX_CODEX_BINARY: codex, REMODEX_PROJECT_ROOT: project.path,
      REMODEX_DEVICE_STATE_DIR: path.join(root, "bridge"), REMODEX_DEVICE_STATE_FILE: path.join(root, "bridge", "device-state.json"),
      REMODEX_DISABLE_KEYCHAIN: "1", CODEX_HOME: codexHome,
    };
    if (apiKey !== null) childEnv.MUNIE_DESKTOP_OPENAI_API = "1";
    if (customProvider !== null) childEnv.MUNIE_DESKTOP_CUSTOM_PROVIDER = "1";
    const { loopbackManagedRelayOrigin } = require("./managed-relay-client");
    const pilotOrigin = loopbackManagedRelayOrigin(env.MUNIE_DEVELOPER_MANAGED_RELAY);
    if (pilotOrigin && apiKey === null && customProvider === null) childEnv.MUNIE_DEVELOPER_MANAGED_RELAY = pilotOrigin;
    const child = spawnImpl(guardian, [String(process.pid), process.execPath, __filename, "--worker"], {
      env: childEnv, cwd: project.path, detached: true, stdio: ["pipe", "pipe", "ignore"],
    });
    worker = child; ownedGroup = child.pid || null;
    child.stdin.on("error", () => {});
    let startupTimer;
    const ready = new Promise((resolve, reject) => {
      readyResolve = resolve; readyReject = reject;
      startupTimer = setTimeout(() => reject(hostError("runtime_timeout")), 12_000);
    });
    function failChild(code = "runtime_failed") {
      if (worker !== child) return;
      rejectPending();
      readyReject?.(hostError(code));
      if (!stopping) {
        state = "error"; account = null;
        updateLanAvailability(false);
        lastError = publicError(hostError("runtime_failed")); publish();
        // Guardian has already cleaned on exit; confirm absence before releasing ownership.
        stop().then(() => { state = "error"; lastError = publicError(hostError("runtime_failed")); publish(); }).catch(() => {});
      }
    }
    child.on("error", () => { failChild("runtime_unavailable"); });
    child.on("close", () => { failChild(); });
    readFrames(child.stdout, MAX_FRAME_BYTES, (frame) => { if (worker === child) receive(frame); }, () => failChild());
    publish();
    try {
      if (customProvider) {
        const { baseURL, model, apiKey: providerKey } = customProvider;
        writeFrame(child.stdin, { method: "provider/configure", provider: { baseURL, model, apiKey: providerKey } });
      }
      await ready;
      state = "running"; publish();
      return status();
    } catch (error) {
      try { await stop(); } catch { throw hostError("cleanup_pending"); }
      state = "error"; lastError = publicError(error); publish(); throw error;
    } finally { clearTimeout(startupTimer); readyResolve = null; readyReject = null; }
  }
  async function run(method, params = {}) {
    switch (method) {
      case "status": return status();
      case "start": {
        const selectedKey = Object.hasOwn(params, "apiKey") ? readOpenAiApiKey(params.apiKey) : null;
        const selectedProvider = Object.hasOwn(params, "customProvider") ? readCustomProvider(params.customProvider) : null;
        if (selectedKey !== null && selectedProvider !== null) throw hostError("invalid_request");
        if (state === "running" && (apiKey !== selectedKey
          || customProvider?.namespace !== selectedProvider?.namespace
          || customProvider?.apiKey !== selectedProvider?.apiKey)) {
          throw hostError(customProvider || selectedProvider ? "custom_provider_unavailable" : "api_key_unavailable");
        }
        apiKey = selectedKey;
        customProvider = selectedProvider;
        return start();
      }
      case "stop": {
        try { return await stop(); }
        finally { apiKey = null; customProvider = null; }
      }
      case "retry": await stop(); return start();
      case "project/set": {
        const selected = projectFolder(params.path);
        const wasRunning = state === "running";
        await stop();
        writePrivateJSON(configFile, { projectPath: selected.path, relayPort });
        project = selected; publish();
        return wasRunning ? start() : status();
      }
      case "account/read": {
        account = await request(method); emit("account", account); publish(); return account;
      }
      case "account/login/start": {
        if (apiKey !== null || customProvider !== null) throw hostError("login_unavailable");
        return safeLogin(await request(method));
      }
      case "account/login/cancel": return request(method);
      case "pairing/get": {
        // An explicit Mac approval requests a fresh invitation without restarting active work.
        if (state !== "running" || !lanAvailable) throw hostError("pairing_unavailable");
        const pairing = await request(method);
        if (!lanAvailable || !pairing || pairing.pairingPayload.expiresAt <= Date.now()) throw hostError("pairing_unavailable");
        return { payload: pairing.pairingPayload, code: pairing.pairingCode };
      }
      case "devices/revoke":
        if (typeof params.deviceId !== "string" || !devices().some((device) => device.id === params.deviceId)) throw hostError("device_not_found");
        // The existing protocol permits exactly one trusted phone; resetting revokes its live session too.
        // falls through
      case "pairing/reset": {
        const wasRunning = state === "running";
        await stop(); trust.resetBridgeTrustState(); publish();
        return wasRunning ? start() : status();
      }
      default: throw hostError("method_not_found");
    }
  }
  return { run, status, stop };
}

function monitorLanRelay(loopbackServer, port, onAvailability) {
  let binding = null, boundAddress = null, stopped = false;

  function retire(current, rebind = false) {
    if (current.closing) return;
    current.closing = true;
    const wasAvailable = boundAddress !== null;
    boundAddress = null;
    current.server.close(() => {
      binding = null;
      if (rebind && !stopped) reconcile();
    });
    // Raw TCP tracking includes incomplete HTTP requests and upgraded WebSockets.
    // The loopback server's sockets are never in this set.
    for (const socket of current.sockets) socket.destroy();
    if (wasAvailable && !stopped) onAvailability(false);
  }

  function reconcile() {
    let address = null;
    try { address = selectLanAddress(); }
    catch { /* No usable interface. Keep loopback available and try the next poll. */ }
    if (binding) {
      if (binding.address !== address) retire(binding, address !== null);
      return;
    }
    if (address === null) return;

    const server = http.createServer();
    const current = binding = { server, address, sockets: new Set(), closing: false };
    // Reuse the exact relay HTTP and upgrade handlers, including their session state.
    for (const event of ["request", "upgrade"]) {
      for (const listener of loopbackServer.listeners(event)) server.on(event, listener);
    }
    server.on("connection", (socket) => {
      if (current.closing) { socket.destroy(); return; }
      current.sockets.add(socket);
      socket.once("close", () => current.sockets.delete(socket));
    });
    // A fixed-port bind failure retires this attempt; the next poll retries the same port.
    server.on("error", () => retire(current));
    try {
      server.listen(port, address, () => {
        if (current.closing) return;
        boundAddress = address;
        onAvailability(true);
      });
    } catch {
      retire(current);
    }
  }

  reconcile();
  const timer = setInterval(reconcile, 5000);
  timer.unref();
  return {
    get address() { return boundAddress; },
    stop() {
      stopped = true;
      clearInterval(timer);
      if (binding) retire(binding);
    },
  };
}

function readProviderStartup(input) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => finish(null), 5000);
    function finish(profile) {
      clearTimeout(timeout);
      input.off("end", onEnd);
      input.pause();
      detach();
      if (profile) resolve(profile); else reject(hostError("custom_provider_unavailable"));
    }
    const onEnd = () => finish(null);
    const detach = readFrames(input, MAX_REQUEST_BYTES, (frame) => {
      if (frame?.method !== "provider/configure") return finish(null);
      let profile;
      try { profile = readCustomProvider(frame.provider); }
      catch { return finish(null); }
      finish(profile);
    }, onEnd);
    input.once("end", onEnd);
    input.resume();
  });
}

async function runWorker() {
  // Imported bridge/relay log text may contain paths or upstream details: discard, never forward it.
  for (const key of ["log", "info", "warn", "error", "debug"]) console[key] = () => {};
  const send = (frame) => writeFrame(process.stdout, frame);
  const { createRelayServer } = require("../../MunieRemodexRelay/server");
  const { managedAdmissionTranscript } = require("../../MunieRemodexRelay/managed-admission");
  const { MOBILE_ROUTE_FRAME } = require("../../MunieRemodexRelay/relay");
  const { loopbackManagedRelayOrigin } = require("./managed-relay-client");
  const { startBridge, readBridgeConfig } = require("./index");
  const apiKeyMode = process.env.MUNIE_DESKTOP_OPENAI_API === "1";
  const customMode = process.env.MUNIE_DESKTOP_CUSTOM_PROVIDER === "1";
  const pilotOrigin = loopbackManagedRelayOrigin(process.env.MUNIE_DEVELOPER_MANAGED_RELAY);
  const relay = createRelayServer({ enablePushService: false, maxPayload: MAX_FRAME_BYTES,
    relayOptions: { enableManagedRoutes: Boolean(pilotOrigin) } });
  await new Promise((resolve, reject) => {
    relay.server.once("error", reject);
    relay.server.listen(Number(process.env.MUNIE_HOST_RELAY_PORT), "127.0.0.1", resolve);
  });
  const port = relay.server.address().port;
  send({ event: "relay", data: { port } });
  let broker = null, customLaunch = null;
  if (customMode) {
    try {
      const { startCustomProviderBroker } = require("./custom-provider-broker");
      const provider = await readProviderStartup(process.stdin);
      broker = await startCustomProviderBroker(provider);
      customLaunch = { model: provider.model, origin: broker.baseURL, capability: broker.capability,
        environmentKey: "MUNIE_LOCAL_PROVIDER_" + randomBytes(16).toString("hex").toUpperCase() };
    } catch { throw hostError("custom_provider_unavailable"); }
  }
  const startLan = () => monitorLanRelay(relay.server, port, (available) => send({ event: "lan", data: available }));
  let lan = apiKeyMode ? null : startLan(), configuringApiKey = false;
  const config = { ...readBridgeConfig(), relayUrl: `ws://127.0.0.1:${port}/relay`, publicRelayUrl: "",
    codexEndpoint: "", pushServiceUrl: "", refreshEnabled: false, desktopAutoFollowEnabled: false,
    keepMacAwakeEnabled: false, desktopIpcLiveSyncEnabled: false, localAccountControlEnabled: true,
    localOpenAiApiKeyMode: apiKeyMode,
  };
  const bridge = startBridge({ config, printPairingQr: false,
    desktopCustomProvider: customLaunch,
    desktopManagedRelay: pilotOrigin ? {
      origin: pilotOrigin, audience: "munie-loopback.invalid", encodeChallenge: managedAdmissionTranscript,
      attachPhone: relay.attachManagedPhone, routeFrame: MOBILE_ROUTE_FRAME,
    } : null,
    onBridgeStatus: (data) => {
      send({ event: "bridge", data: bridgeSnapshot(data) });
      // Native app-server can also close with exit 0 unexpectedly; it is still a host failure.
      if (data.state === "error") queueMicrotask(() => process.exit(1));
    },
  });
  let stopping = false, pending = 0, loginPoll = null, loginPollBusy = false;
  function pollLogin() {
    clearInterval(loginPoll);
    const expires = Date.now() + 10 * 60_000;
    loginPoll = setInterval(async () => {
      if (loginPollBusy || stopping) return;
      if (Date.now() >= expires) { clearInterval(loginPoll); return; }
      loginPollBusy = true;
      try {
        const data = await bridge.localAccount.read();
        send({ event: "account", data });
        if (!data.loginInFlight) clearInterval(loginPoll);
      } catch { /* Explicit account/read still reports failures to the GUI. */ }
      finally { loginPollBusy = false; }
    }, 1000);
    loginPoll.unref();
  }
  async function shutdown() {
    if (stopping) return;
    stopping = true;
    clearInterval(loginPoll);
    lan?.stop();
    bridge.stop();
    await broker?.stop();
    for (const client of relay.wss.clients) client.terminate();
    relay.wss.close();
    relay.server.close();
    // Guardian confirms native and descendant cleanup after this worker exits.
    process.exit(0);
  }
  readFrames(process.stdin, MAX_REQUEST_BYTES, (frame) => {
    if (frame?.method === "account/api-key/configure") {
      if (!apiKeyMode || configuringApiKey || stopping) return;
      configuringApiKey = true;
      Promise.resolve().then(async () => {
        await bridge.localAccount.setOpenAiApiKey(readOpenAiApiKey(frame.apiKey));
        if (stopping) return;
        lan = startLan();
        send({ event: "api-key-ready" });
      }).catch(() => {
        send({ event: "fatal", data: publicError(hostError("api_key_unavailable")) });
        void shutdown();
      });
      return;
    }
    if (pending >= 32) { send({ id: frame?.id, error: publicError(hostError("busy")) }); return; }
    pending++;
    Promise.resolve().then(async () => {
      switch (frame.method) {
        case "pairing/get": {
          if (!lan?.address) throw hostError("pairing_unavailable");
          const session = bridge.localPairing.refresh();
          // Only the local handoff URL changes. The bridge's session, key and relay
          // registration stay owned by the original loopback transport.
          const relay = `ws://${advertisedHost(lan.address)}:${port}/relay`;
          return { ...session, pairingPayload: { ...session.pairingPayload, relay } };
        }
        case "account/read": return bridge.localAccount.read();
        case "account/login/start": {
          if (apiKeyMode || customMode) throw hostError("login_unavailable");
          const result = safeLogin(await bridge.localAccount.startLogin());
          pollLogin();
          return result;
        }
        case "account/login/cancel":
          clearInterval(loginPoll);
          return bridge.localAccount.cancelLogin();
        default: throw hostError("method_not_found");
      }
    }).then((result) => send({ id: frame.id, result }), () => send({ id: frame.id,
      error: publicError(hostError(frame.method === "pairing/get" ? "pairing_unavailable" : "account_unavailable")) }))
      .finally(() => pending--);
  }, () => { void shutdown(); });
  process.stdin.on("end", shutdown);
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  process.stdin.resume();
}

function runProtocol({ input = process.stdin, output = process.stdout, env = process.env } = {}) {
  const send = (value) => writeFrame(output, { v: 1, ...value });
  let host;
  try { host = createDesktopHost({ env, emit: (event, data) => send({ event, data }) }); }
  catch (error) {
    const failure = publicError(error);
    const failedStatus = { state: "error", project: null, bridge: null, account: null, devices: [], lanAvailable: false, lanRevision: 0,
      pairingAvailable: false, lastError: failure, cleanupConfirmed: true, ownership: null };
    send({ event: "ready", data: failedStatus });
    readFrames(input, MAX_REQUEST_BYTES, (frame) => {
      const id = typeof frame?.id === "string" ? frame.id : null;
      if (frame?.v === 1 && id && frame.method === "status") send({ id, result: failedStatus });
      else if (frame?.v === 1 && id && frame.method === "stop") {
        // No worker can exist when construction fails. Confirm that fact so the native
        // owner can close this helper while retaining the startup error for inspection.
        failedStatus.state = "stopped";
        send({ id, result: failedStatus });
      }
      else send({ id, error: failure });
    }, (failure) => send({ id: null, error: publicError(failure) }));
    input.resume();
    return null;
  }
  send({ event: "ready", data: host.status() });
  let queue = Promise.resolve(), queued = 0, ending = false;
  const ids = new Set();
  function finish() {
    if (ending) return;
    ending = true;
    queue.finally(async () => {
      try { await host.stop(); process.exitCode = 0; }
      catch { process.exitCode = 1; }
      input.pause();
    });
  }
  readFrames(input, MAX_REQUEST_BYTES, (frame) => {
    const valid = frame?.v === 1 && typeof frame.id === "string" && frame.id.length > 0 && frame.id.length <= 128
      && typeof frame.method === "string" && frame.method.length <= 128
      && (frame.params === undefined || (frame.params && typeof frame.params === "object" && !Array.isArray(frame.params)));
    const id = valid ? frame.id : null;
    if (!valid || ids.has(id)) { send({ id, error: publicError(hostError("invalid_request")) }); return; }
    if (ending || queued >= 32) { send({ id, error: publicError(hostError("busy")) }); return; }
    queued++; ids.add(id);
    queue = queue.then(async () => {
      try { send({ id, result: await host.run(frame.method, frame.params) }); }
      catch (error) { send({ id, error: publicError(error) }); }
      finally { queued--; ids.delete(id); }
    }).catch(finish);
  }, (error) => {
    send({ id: null, error: publicError(error) });
    if (error.code === "request_too_large") finish();
  });
  input.on("end", finish);
  process.on("SIGTERM", finish);
  process.on("SIGINT", finish);
  return host;
}

if (require.main === module) {
  if (process.argv[2] === "--verify-cleanup") void runCleanupVerification(process.argv.slice(3));
  else if (process.argv.includes("--worker")) runWorker().catch((error) => {
    const code = error?.code === "EADDRINUSE" ? "relay_port_unavailable" : error?.code;
    writeFrame(process.stdout, { event: "fatal", data: publicError(hostError(code)) });
    process.exit(1);
  });
  else runProtocol();
}

module.exports = { createDesktopHost, readFrames, runProtocol, selectLanAddress, advertisedHost, safeLogin, publicError, groupExists, verifyCleanup, MAX_REQUEST_BYTES, MAX_FRAME_BYTES };
