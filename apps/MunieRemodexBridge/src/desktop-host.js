// Munie Mac GUI process boundary. stdout is a bounded v1 JSONL protocol, never a log stream.
// The native guardian owns one detached group containing this worker, relay and Codex.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { isIPv4 } = require("node:net");
const { spawn, spawnSync } = require("node:child_process");
const { createHash, X509Certificate } = require("node:crypto");
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
  account_unavailable: "The account status could not be read. Check Codex on this Mac.",
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

// Retains at most one frame, including when a peer never sends a newline.
function readFrames(stream, maxBytes, receive, fail) {
  let buffer = Buffer.alloc(0), failed = false;
  stream.on("data", (chunk) => {
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
  });
  stream.on("end", () => {
    if (buffer.length && !failed) fail(hostError("invalid_request"));
  });
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

function resolveCodexHome(env, userHome = os.homedir()) {
  if (!env.CODEX_HOME) return path.join(userHome, ".codex");
  // Match the native override: an explicitly configured home must already exist.
  try {
    if (!path.isAbsolute(env.CODEX_HOME)) throw new Error();
    const canonical = fs.realpathSync(env.CODEX_HOME);
    if (!fs.statSync(canonical).isDirectory()) throw new Error();
    return canonical;
  } catch { throw hostError("account_unavailable"); }
}

function requiresPackagedCodexPolicy(codex) {
  const marker = path.resolve(path.dirname(codex), "../codex-resources/munie-stdio-policy");
  const stats = fs.lstatSync(marker, { throwIfNoEntry: false });
  if (!stats) return false;
  if (!stats.isFile() || stats.size !== 2 || fs.readFileSync(marker, "utf8") !== "1\n") {
    throw hostError("runtime_unavailable");
  }
  return true;
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

function prepareSimulatorApprovalFixture(fixture, env, { verify = false } = {}) {
  const { directory, providerPort, certificateHash } = fixture;
  const base = verify ? null : fs.realpathSync(os.tmpdir());
  const assertPrivate = (target) => {
    const info = fs.lstatSync(target);
    if (!info.isDirectory() || info.uid !== process.getuid()
        || (info.mode & 0o777) !== 0o700 || fs.realpathSync(target) !== target) {
      throw hostError("state_unavailable");
    }
  };
  if (typeof directory !== "string" || !path.isAbsolute(directory) || (base && path.dirname(directory) !== base)
      || !/^munie-packed-phone-[a-zA-Z0-9]+$/.test(path.basename(directory))
      || !Number.isInteger(providerPort) || providerPort < 1024 || providerPort > 65535) {
    throw hostError("state_unavailable");
  }
  const home = path.join(directory, "codex"), project = path.join(directory, "project");
  const state = path.join(directory, "state");
  if (env.CODEX_HOME !== home || env.MUNIE_HOST_STATE_DIR !== state
      || !require("./managed-relay-client").loopbackManagedRelayOrigin(env.MUNIE_DEVELOPER_MANAGED_RELAY)
      || (verify ? env.REMODEX_PROJECT_ROOT !== project || env.TMPDIR !== directory : fs.existsSync(state))) {
    throw hostError("state_unavailable");
  }
  for (const dir of [directory, home, project, ...(verify ? [state, path.join(home, "rules")] : [])]) assertPrivate(dir);
  if (!verify && (fs.readdirSync(home).length || fs.readdirSync(project).length)) throw hostError("state_unavailable");
  // Only the CA generated under this private fixture root can enter the worker's environment.
  const ca = path.join(directory, "approval-provider-ca.pem");
  let caHash;
  try {
    const info = fs.lstatSync(ca);
    if (!info.isFile() || info.uid !== process.getuid() || (info.mode & 0o7777) !== 0o600
        || info.nlink !== 1 || info.size > 4096) throw new Error();
    const pem = fs.readFileSync(ca, "utf8");
    if (!/^-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+\n-----END CERTIFICATE-----\n$/.test(pem)) throw new Error();
    const cert = new X509Certificate(pem);
    const from = Date.parse(cert.validFrom), to = Date.parse(cert.validTo), now = Date.now();
    if (!cert.ca || cert.subject !== "CN=Munie Simulator Approval Root" || cert.issuer !== cert.subject
        || cert.publicKey.asymmetricKeyType !== "rsa" || cert.publicKey.asymmetricKeyDetails.modulusLength !== 2048
        || !(from <= now && now < to && to - from <= 86_400_000)) throw new Error();
    caHash = createHash("sha256").update(pem).digest("hex");
    if (verify && (caHash !== certificateHash || env.CODEX_CA_CERTIFICATE !== ca || env.SSL_CERT_FILE !== ca)) throw new Error();
  } catch { throw hostError("state_unavailable"); }
  const put = (file, content) => {
    if (!verify) return fs.writeFileSync(file, content, { flag: "wx", mode: 0o600 });
    const info = fs.lstatSync(file);
    if (!info.isFile() || info.uid !== process.getuid() || (info.mode & 0o777) !== 0o600
        || info.size !== Buffer.byteLength(content) || fs.readFileSync(file, "utf8") !== content) {
      throw hostError("state_unavailable");
    }
  };
  put(path.join(home, "config.toml"), 'cli_auth_credentials_store="file"\nanalytics.enabled=false\nfeedback.enabled=false\n'
    + 'model="munie-fixture"\nmodel_provider="munie_fixture"\n[model_providers.munie_fixture]\n'
    + `name="Munie simulator fixture"\nbase_url="https://127.0.0.1:${providerPort}/v1"\nwire_api="responses"\n`
    + 'requires_openai_auth=false\nsupports_websockets=false\n'
    + 'request_max_retries=0\nstream_max_retries=0\n');
  if (!verify) fs.mkdirSync(path.join(home, "rules"), { mode: 0o700 });
  put(path.join(home, "rules", "default.rules"), 'prefix_rule(pattern=["/bin/sh", "managed-stop.sh"], decision="prompt")\n');
  put(path.join(project, "managed-stop.sh"), "/bin/mkdir managed-shell-started && /bin/sleep 8 && /bin/mkdir managed-shell-late\n");
  return { directory, project, providerPort, ca, caHash };
}

function createDesktopHost({
  env = process.env, emit = () => {}, spawnImpl = spawn, simulatorApprovalFixture = null, lanTaskPreviewProject = null,
  hostedRelayOrigin = null, scopedHostedTaskPreview = false,
} = {}) {
  // Only the local signed test driver constructs this option; no env or protocol method enables it.
  const fixture = simulatorApprovalFixture ? prepareSimulatorApprovalFixture(simulatorApprovalFixture, env) : null;
  const { hostedManagedRelayOrigin } = require("./managed-relay-client");
  const hostedOrigin = !fixture && (!lanTaskPreviewProject || scopedHostedTaskPreview) && hostedRelayOrigin
    ? hostedManagedRelayOrigin(hostedRelayOrigin) : null;
  if (scopedHostedTaskPreview && (!hostedOrigin || typeof lanTaskPreviewProject !== "string"
      || !path.isAbsolute(lanTaskPreviewProject))) throw hostError("invalid_request");
  let root;
  try {
    if (!env.MUNIE_HOST_STATE_DIR || !path.isAbsolute(env.MUNIE_HOST_STATE_DIR)) throw new Error();
    root = privateDirectory(env.MUNIE_HOST_STATE_DIR);
    privateDirectory(path.join(root, "bridge"));
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
  // The host owns the revision, not any of its replaceable workers.
  let lanAvailable = false, lanRevision = 0;
  let awayState = "stopped", awayRevision = 0;
  let requestCounter = 0, readyResolve = null, readyReject = null;
  const pending = new Map();

  function devices() {
    const record = trust.readBridgeDeviceState();
    return Object.entries(record?.trustedPhones || {}).map(([id, key]) => ({
      id, fingerprint: createHash("sha256").update(key).digest("hex"),
    }));
  }
  function status() {
    return { state, project, bridge, account, devices: devices(), lanAvailable, lanRevision, awayState, awayRevision,
      pairingAvailable: state === "running" && lanAvailable,
      lastError, cleanupConfirmed: ownedGroup === null,
      ownership: ownedGroup === null ? null : { ownerPid: process.pid, groupId: ownedGroup } };
  }
  function publish() { emit("status", status()); }
  function updateAwayState(next) {
    if (awayState === next) return;
    awayState = next;
    awayRevision++;
    publish();
  }
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
      if (bridge.codexLaunchState === "connected" && bridge.connectionStatus === "connected") readyResolve?.();
      publish();
    } else if (frame?.event === "lan") {
      if (typeof frame.data !== "boolean") throw hostError("runtime_failed");
      if (!stopping && updateLanAvailability(frame.data)) publish();
    } else if (frame?.event === "away") {
      if (!["waitingForPair", "connecting", "registered", "unavailable", "denied", "stopped"].includes(frame.data)) {
        throw hostError("runtime_failed");
      }
      if (!stopping) updateAwayState(frame.data);
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
  function request(method, params) {
    if (state !== "running" || !worker?.stdin.writable) throw hostError("not_running");
    const id = String(++requestCounter);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(hostError("runtime_timeout")); }, 12_000);
      pending.set(id, { resolve, reject, timer });
      try { writeFrame(worker.stdin, { id, method, params }); }
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
      updateAwayState("stopped");
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
    const enableLanTaskExecution = project.path === lanTaskPreviewProject;
    const codex = executable(env.MUNIE_CODEX_BINARY || path.resolve(__dirname, "../../../Runtime/bin/codex"));
    const guardian = executable(env.MUNIE_GUARDIAN_BINARY || path.resolve(__dirname, "../../../Runtime/bin/MunieCodexGuardian"));
    const requireCodexStdioPolicy = requiresPackagedCodexPolicy(codex);
    if (fixture && (!requireCodexStdioPolicy || project.path !== fixture.project)) throw hostError("runtime_unavailable");
    const { loopbackManagedRelayOrigin } = require("./managed-relay-client");
    const pilotOrigin = loopbackManagedRelayOrigin(env.MUNIE_DEVELOPER_MANAGED_RELAY);
    if (enableLanTaskExecution && (!requireCodexStdioPolicy || fixture || pilotOrigin)) {
      throw hostError("runtime_unavailable");
    }
    state = "starting"; lastError = null; bridge = null; account = null;
    updateLanAvailability(false);
    publish();
    const childEnv = {
      HOME: os.homedir(), PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR: os.tmpdir(), LANG: "en_US.UTF-8",
      MUNIE_HOST_STATE_DIR: root, MUNIE_HOST_PROJECT_ROOT: project.path,
      MUNIE_HOST_RELAY_PORT: String(relayPort || 0),
      MUNIE_FOLLOW_CODEX_ACCOUNT: "1",
      REMODEX_CODEX_BINARY: codex, REMODEX_PROJECT_ROOT: project.path,
      REMODEX_DEVICE_STATE_DIR: path.join(root, "bridge"), REMODEX_DEVICE_STATE_FILE: path.join(root, "bridge", "device-state.json"),
      REMODEX_DISABLE_KEYCHAIN: "1",
    };
    if (requireCodexStdioPolicy) childEnv.MUNIE_REQUIRE_CODEX_STDIO_POLICY = "1";
    // Leave Codex's native default unset, including on a fresh Mac where ~/.codex does not yet exist.
    if (env.CODEX_HOME) childEnv.CODEX_HOME = resolveCodexHome(env);
    if (pilotOrigin) childEnv.MUNIE_DEVELOPER_MANAGED_RELAY = pilotOrigin;
    const workerArgs = [String(process.pid), process.execPath, __filename, "--worker"];
    if (enableLanTaskExecution) workerArgs.push("--lan-task-execution");
    if (hostedOrigin && !pilotOrigin && (!scopedHostedTaskPreview || enableLanTaskExecution)) {
      workerArgs.push("--managed-relay-origin", hostedOrigin);
    }
    if (fixture) {
      childEnv.HOME = fixture.directory;
      childEnv.TMPDIR = fixture.directory;
      childEnv.CODEX_CA_CERTIFICATE = fixture.ca;
      childEnv.SSL_CERT_FILE = fixture.ca;
      workerArgs.push("--simulator-approval-fixture", String(fixture.providerPort), fixture.caHash);
    }
    const child = spawnImpl(guardian, workerArgs, {
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
      case "start": return start();
      case "stop": return stop();
      case "retry": await stop(); return start();
      case "away/set": {
        if (!hostedOrigin || (scopedHostedTaskPreview && project?.path !== lanTaskPreviewProject)
            || typeof params.enabled !== "boolean" || state !== "running") {
          throw hostError("invalid_request");
        }
        await request(method, { enabled: params.enabled });
        return status();
      }
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

async function runWorker({
  simulatorApprovalFixture = false, fixtureProviderPort = null, fixtureCertificateHash = null, lanTaskExecution = false,
  hostedRelayOrigin = null,
} = {}) {
  // Imported bridge/relay log text may contain paths or upstream details: discard, never forward it.
  for (const key of ["log", "info", "warn", "error", "debug"]) console[key] = () => {};
  const send = (frame) => writeFrame(process.stdout, frame);
  const { createRelayServer } = require("../../MunieRemodexRelay/server");
  const { managedAdmissionTranscript } = require("../../MunieRemodexRelay/managed-admission");
  const { MOBILE_ROUTE_FRAME } = require("../../MunieRemodexRelay/relay");
  const { loopbackManagedRelayOrigin, hostedManagedRelayOrigin } = require("./managed-relay-client");
  const { startBridge, readBridgeConfig } = require("./index");
  const pilotOrigin = loopbackManagedRelayOrigin(process.env.MUNIE_DEVELOPER_MANAGED_RELAY);
  const hostedOrigin = !pilotOrigin && !simulatorApprovalFixture && hostedRelayOrigin
    ? hostedManagedRelayOrigin(hostedRelayOrigin) : null;
  if (simulatorApprovalFixture) {
    if (!pilotOrigin || process.env.MUNIE_REQUIRE_CODEX_STDIO_POLICY !== "1") throw hostError("runtime_unavailable");
    prepareSimulatorApprovalFixture({
      directory: process.env.HOME, providerPort: fixtureProviderPort, certificateHash: fixtureCertificateHash,
    }, process.env, { verify: true });
  }
  const relay = createRelayServer({ enablePushService: false, maxPayload: MAX_FRAME_BYTES,
    relayOptions: { enableManagedRoutes: true } });
  await new Promise((resolve, reject) => {
    relay.server.once("error", reject);
    relay.server.listen(Number(process.env.MUNIE_HOST_RELAY_PORT), "127.0.0.1", resolve);
  });
  const port = relay.server.address().port;
  send({ event: "relay", data: { port } });
  const lan = simulatorApprovalFixture ? { address: null, stop() {} }
    : monitorLanRelay(relay.server, port, (available) => send({ event: "lan", data: available }));
  const config = { ...readBridgeConfig(), relayUrl: `ws://127.0.0.1:${port}/relay`, publicRelayUrl: "",
    codexEndpoint: "", pushServiceUrl: "", refreshEnabled: false, desktopAutoFollowEnabled: false,
    keepMacAwakeEnabled: false, desktopIpcLiveSyncEnabled: false, localAccountControlEnabled: true,
    followCodexAccount: true,
    requireCodexStdioPolicy: process.env.MUNIE_REQUIRE_CODEX_STDIO_POLICY === "1",
    simulatorApprovalFixture,
  };
  const bridge = startBridge({ config, printPairingQr: false,
    desktopMobileRouteFrame: MOBILE_ROUTE_FRAME,
    desktopLanTaskExecution: lanTaskExecution,
    desktopManagedRelay: pilotOrigin ? {
      origin: pilotOrigin, audience: "munie-loopback.invalid", encodeChallenge: managedAdmissionTranscript,
      attachPhone: relay.attachManagedPhone,
    } : null,
    desktopHostedRelay: hostedOrigin ? {
      hostedOrigin, encodeChallenge: managedAdmissionTranscript, attachPhone: relay.attachManagedPhone,
      onState: (data) => send({ event: "away", data }),
    } : null,
    onBridgeStatus: (data) => {
      send({ event: "bridge", data: bridgeSnapshot(data) });
      // Native app-server can also close with exit 0 unexpectedly; it is still a host failure.
      if (data.state === "error") queueMicrotask(() => process.exit(1));
    },
  });
  let stopping = false, pending = 0;
  async function shutdown() {
    if (stopping) return;
    stopping = true;
    lan.stop();
    bridge.stop();
    for (const client of relay.wss.clients) client.terminate();
    relay.wss.close();
    relay.server.close();
    // Guardian confirms native and descendant cleanup after this worker exits.
    process.exit(0);
  }
  readFrames(process.stdin, MAX_REQUEST_BYTES, (frame) => {
    if (pending >= 32) { send({ id: frame?.id, error: publicError(hostError("busy")) }); return; }
    pending++;
    Promise.resolve().then(async () => {
      switch (frame.method) {
        case "away/set": {
          if (!bridge.localAway || typeof frame.params?.enabled !== "boolean") throw hostError("invalid_request");
          bridge.localAway.setEnabled(frame.params.enabled);
          return true;
        }
        case "pairing/get": {
          if (!lan.address) throw hostError("pairing_unavailable");
          const session = bridge.localPairing.refresh();
          // Only the local handoff URL changes. The bridge's session, key and relay
          // registration stay owned by the original loopback transport.
          const relay = `ws://${advertisedHost(lan.address)}:${port}/relay`;
          return { ...session, pairingPayload: { ...session.pairingPayload, relay } };
        }
        case "account/read": return bridge.localAccount.read();
        default: throw hostError("method_not_found");
      }
    }).then((result) => send({ id: frame.id, result }), () => send({ id: frame.id,
      error: publicError(hostError(
        frame.method === "pairing/get" ? "pairing_unavailable"
          : frame.method === "away/set" ? "runtime_unavailable" : "account_unavailable"
      )) }))
      .finally(() => pending--);
  }, () => { void shutdown(); });
  process.stdin.on("end", shutdown);
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  process.stdin.resume();
}

function runProtocol({
  input = process.stdin, output = process.stdout, env = process.env, lanTaskPreviewProject = null,
  hostedRelayOrigin = null, scopedHostedTaskPreview = false,
} = {}) {
  const send = (value) => writeFrame(output, { v: 1, ...value });
  let host;
  try { host = createDesktopHost({ env, lanTaskPreviewProject, hostedRelayOrigin, scopedHostedTaskPreview,
    emit: (event, data) => send({ event, data }) }); }
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
  else if (process.argv[2] === "--worker") runWorker({
    simulatorApprovalFixture: process.argv[3] === "--simulator-approval-fixture",
    lanTaskExecution: process.argv[3] === "--lan-task-execution",
    fixtureProviderPort: Number(process.argv[4]),
    fixtureCertificateHash: process.argv[5],
    hostedRelayOrigin: process.argv[3] === "--managed-relay-origin" && process.argv.length === 5 ? process.argv[4]
      : process.argv[3] === "--lan-task-execution" && process.argv[4] === "--managed-relay-origin"
        && process.argv.length === 6 ? process.argv[5] : null,
  }).catch((error) => {
    writeFrame(process.stdout, { event: "fatal", data: publicError(hostError(error?.code === "EADDRINUSE" ? "relay_port_unavailable" : "runtime_failed")) });
    process.exit(1);
  });
  else if (process.argv[2] === "--scoped-task-preview-and-managed-relay" && process.argv.length === 5) runProtocol({
    lanTaskPreviewProject: process.argv[3], hostedRelayOrigin: process.argv[4], scopedHostedTaskPreview: true,
  });
  else runProtocol({
    lanTaskPreviewProject: process.argv[2] === "--lan-task-preview-project" && process.argv.length === 4
      ? process.argv[3] : null,
    hostedRelayOrigin: process.argv[2] === "--managed-relay-origin" && process.argv.length === 4 ? process.argv[3] : null,
  });
}

module.exports = { createDesktopHost, readFrames, runProtocol, selectLanAddress, advertisedHost, resolveCodexHome, publicError, groupExists, verifyCleanup, MAX_REQUEST_BYTES, MAX_FRAME_BYTES };
