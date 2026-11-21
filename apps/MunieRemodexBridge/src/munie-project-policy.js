// Munie addition: binds explicit local launches to one canonical project root.
// This is an application routing boundary; the Codex sandbox remains authoritative for tools.
const fs = require("fs");
const path = require("path");
const { randomUUID } = require("node:crypto");
const SHARED_CODEX_PERMISSIONS = "munie_remote_shared_codex";
const SHARED_CODEX_APPROVAL = Object.freeze({ granular: Object.freeze({
  sandbox_approval: false, rules: true, mcp_elicitations: false,
  request_permissions: false, skill_approval: false,
}) });
// The pinned runtime can start configured MCP outside the named tool sandbox.
// Keep the shared-account candidate read-only until all execution paths are guarded.
const FOLLOW_CODEX_PREVIEW_METHODS = new Set([
  "initialize", "initialized", "account/read", "account/status/read", "getAuthStatus",
  "model/list", "collaborationMode/list", "project/quickLocations", "project/listDirectory", "project/recentDirectories",
  "thread/list", "thread/read", "thread/turns/list", "thread/goal/get",
]);

function assertFollowCodexPreview(request) {
  if (!FOLLOW_CODEX_PREVIEW_METHODS.has(request?.method)) {
    throw Object.assign(new Error("Remote actions are unavailable while the Mac uses the Codex settings preview."),
      { errorCode: "shared_codex_actions_unavailable" });
  }
}

// The imported client's ordinary native workflow. New native methods need an explicit policy.
const NATIVE_METHODS = new Set([
  'initialize', 'initialized', 'model/list', 'collaborationMode/list',
  'thread/start', 'thread/list', 'thread/read', 'thread/resume', 'thread/fork', 'thread/archive',
  'thread/unarchive', 'thread/name/set', 'thread/compact/start', 'thread/unsubscribe',
  'thread/settings/update', 'thread/turns/list', 'thread/goal/get', 'thread/goal/set', 'thread/goal/clear',
  'thread/approveGuardianDeniedAction', 'turn/start', 'turn/steer', 'turn/interrupt', 'review/start',
  'account/read', 'account/rateLimits/read', 'account/login/start', 'account/login/cancel',
  'account/login/complete', 'account/logout', 'getAuthStatus', 'skills/list', 'plugin/list', 'fuzzyFileSearch',
]);

function assertNativeMethod(request, root = configuredRoot()) {
  if (root && request?.method && !NATIVE_METHODS.has(request.method)) {
    throw new Error('This native method requires an explicit authorization policy: ' + request.method);
  }
}

function createPendingResponseGate() {
  const pending = new Map();
  return {
    remember(id) {
      pending.set(String(id), Date.now());
      while (pending.size > 256) pending.delete(pending.keys().next().value);
    },
    consume(id) {
      const key = String(id), created = pending.get(key);
      pending.delete(key);
      if (created === undefined || Date.now() - created > 5 * 60 * 1000) {
        throw new Error('No live native server request matches this response.');
      }
    },
  };
}

// A gate belongs to one Mac-authorized turn and one authenticated route.
// The caller must drain expiry and close records to settle native callbacks.
function createSharedCodexApprovalGate({ root, route, threadId, turnId, now = () => performance.now() }) {
  if (typeof route !== "symbol" || !path.isAbsolute(root) || fs.realpathSync(root) !== root) {
    throw new Error("Approval requires a canonical project and authenticated route.");
  }
  requireTaskID(threadId, "threadId");
  requireTaskID(turnId, "turnId");
  const pending = new Map();
  const offered = new Map();
  const singleUse = new Set(["accept", "decline", "cancel"]);
  let closed = false;
  const unavailable = () => new Error("No matching one-time command approval is available.");
  return {
    offer(request) {
      const { id, method, params } = request ?? {};
      if (closed || offered.size >= 64 || pending.size >= 8 || offered.has(id)
        || !(Number.isSafeInteger(id) || (typeof id === "string" && id.length > 0 && id.length <= 256))
        || method !== "item/commandExecution/requestApproval"
        || params?.kind !== "command" || params.threadId !== threadId || params.turnId !== turnId
        || params.cwd !== root || fs.realpathSync(root) !== root
        || (params.environmentId != null && params.environmentId !== "local")
        || params.approvalId != null || params.additionalPermissions != null
        || params.networkApprovalContext != null || params.proposedNetworkPolicyAmendments != null
        || typeof params.command !== "string" || !params.command.trim()
        || Buffer.byteLength(params.command, "utf8") > 8192
        || !Array.isArray(params.availableDecisions) || params.availableDecisions.length > 16) {
        throw unavailable();
      }
      const itemId = requireTaskID(params.itemId, "itemId");
      const decisions = new Set(params.availableDecisions.filter((value) => singleUse.has(value)));
      if (!decisions.has("accept")) throw unavailable();
      const token = randomUUID();
      offered.set(id, token);
      pending.set(token, { id, decisions, deadline: now() + 120_000 });
      return { id: token, method, params: {
        kind: "command", threadId, turnId, itemId, command: params.command, cwd: root,
        availableDecisions: [...decisions],
      } };
    },
    reply(response, activeRoute) {
      const record = pending.get(response?.id);
      const result = response?.result;
      if (closed || activeRoute !== route || !record || now() >= record.deadline
        || !Object.hasOwn(response, "id") || !Object.hasOwn(response, "result") || Object.keys(response).length !== 2
        || !result || typeof result !== "object" || Array.isArray(result)
        || !Object.hasOwn(result, "decision") || Object.keys(result).length !== 1
        || !record.decisions.has(result.decision)
        || fs.realpathSync(root) !== root) {
        throw unavailable();
      }
      pending.delete(response.id);
      return { id: record.id, result: { decision: result.decision } };
    },
    resolve(nativeId) {
      const phoneId = offered.get(nativeId);
      if (!phoneId) return null;
      offered.set(nativeId, null);
      pending.delete(phoneId);
      return phoneId;
    },
    expire() {
      const unresolved = [];
      const currentTime = now();
      for (const [phoneId, { id: nativeId, deadline }] of pending) {
        if (currentTime < deadline) continue;
        pending.delete(phoneId);
        offered.set(nativeId, null);
        unresolved.push({ nativeId, phoneId });
      }
      return unresolved;
    },
    close() {
      closed = true;
      const unresolved = [];
      for (const [nativeId, phoneId] of offered) {
        if (phoneId) unresolved.push({ nativeId: pending.has(phoneId) ? nativeId : null, phoneId });
      }
      pending.clear();
      offered.clear();
      return unresolved;
    },
  };
}

function configuredRoot() {
  const root = process.env.REMODEX_PROJECT_ROOT;
  return root ? fs.realpathSync(root) : null;
}

function withinRoot(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(".." + path.sep) && relative !== ".." && !path.isAbsolute(relative));
}

function scopedPath(candidate, { allowMissing = false, root = configuredRoot() } = {}) {
  if (!root) return candidate;
  if (typeof candidate !== "string" || !candidate.trim()) throw new Error("A project path is required.");
  const absolute = path.resolve(root, candidate);
  let canonical;
  try { canonical = fs.realpathSync(absolute); }
  catch (error) {
    if (!allowMissing || error.code !== "ENOENT") throw error;
    const missing = [];
    let parent = absolute;
    while (true) {
      try { fs.lstatSync(parent); break; }
      catch (missingError) { if (missingError.code !== "ENOENT") throw missingError; }
      missing.unshift(path.basename(parent));
      const next = path.dirname(parent);
      if (next === parent) throw error;
      parent = next;
    }
    canonical = path.join(fs.realpathSync(parent), ...missing);
  }
  if (!withinRoot(canonical, root)) throw Object.assign(new Error("The requested path is outside this launch's authorized project."), { errorCode: "project_not_authorized" });
  return canonical;
}

function validatePathParameters(params, root = configuredRoot()) {
  if (!root || !params || typeof params !== "object") return;
  const paths = new Set(["cwd", "currentWorkingDirectory", "path", "filePath", "localPath", "directory",
    "directoryPath", "worktreePath", "worktreeRoot", "targetPath", "destinationPath", "sourcePath", "repoPath"]);
  for (const [key, value] of Object.entries(params)) {
    if (paths.has(key) && typeof value === "string" && value) scopedPath(value, { root, allowMissing: true });
    else if (value && typeof value === "object") validatePathParameters(value, root);
  }
}

const SHARED_CODEX_TASK_METHODS = new Set(["thread/start", "thread/resume", "turn/start", "turn/interrupt"]);

function requireTaskID(value, field) {
  if (typeof value !== "string" || !value || value.length > 256 || value.trim() !== value) {
    throw new Error(`Invalid ${field}.`);
  }
  return value;
}

function bindSharedCodexTask(method, params, root) {
  if (method === "turn/interrupt") {
    const id = (field, alias) => {
      if (Object.hasOwn(params, field) && Object.hasOwn(params, alias)) {
        if (params[field] !== params[alias]) throw new Error(`Conflicting ${field}.`);
      }
      return requireTaskID(params[field] ?? params[alias], field);
    };
    return {
      threadId: id("threadId", "thread_id"),
      turnId: id("turnId", "turn_id"),
    };
  }
  if (params.cwd != null && scopedPath(params.cwd, { root }) !== root) {
    throw new Error("Select the requested project on the Mac before starting or resuming a task.");
  }
  // Project, effective model, and execution policy come from the Mac, not a stale phone selection.
  const bound = {
    cwd: root, approvalPolicy: SHARED_CODEX_APPROVAL,
    approvalsReviewer: "user", permissions: SHARED_CODEX_PERMISSIONS,
  };
  if (method === "thread/start") {
    if (typeof params.ephemeral === "boolean") bound.ephemeral = params.ephemeral;
    return bound;
  }
  bound.threadId = requireTaskID(params.threadId, "threadId");
  if (method === "thread/resume") {
    if (typeof params.excludeTurns === "boolean") bound.excludeTurns = params.excludeTurns;
    return bound;
  }
  if (!Array.isArray(params.input) || params.input.length === 0 || params.input.length > 128) {
    throw new Error("A shared Codex task requires bounded plain text input.");
  }
  let inputBytes = 0;
  bound.input = params.input.map((item) => {
    if (item?.type !== "text" || typeof item.text !== "string") {
      throw new Error("Shared Codex tasks accept plain text only.");
    }
    inputBytes += Buffer.byteLength(item.text, "utf8");
    if (inputBytes > 128 * 1024) throw new Error("Shared Codex task text exceeds its limit.");
    return { type: "text", text: item.text, text_elements: [] };
  });
  if (params.clientUserMessageId != null) {
    bound.clientUserMessageId = requireTaskID(params.clientUserMessageId, "clientUserMessageId");
  }
  // Inherit the native service tier even for older clients; do not inject the legacy default.
  bound.remodexRuntimeSettingsVersion = 2;
  return bound;
}

function bindNativeRequest(request, root = configuredRoot(), { followCodexAccount = false } = {}) {
  if (!root || !request?.method) return request;
  if (request.method.startsWith('desktop/') && request.method !== 'desktop/preferences/read') {
    throw new Error('This foreground launch does not authorize Desktop handoff, power changes or package updates.');
  }
  const params = { ...(request.params || {}) };
  if (followCodexAccount && (request.method.startsWith("account/login/") || request.method === "account/logout")) {
    throw new Error("Manage the account in Codex on this Mac.");
  }
  if (followCodexAccount && (Object.hasOwn(params, "modelProvider") || Object.hasOwn(params, "model_provider"))) {
    throw new Error("Munie follows the model provider configured in Codex on this Mac.");
  }
  if (request.method === 'account/login/start'
      && (params.type !== 'chatgpt' || Object.keys(params).length !== 1)) {
    throw new Error("API keys and authentication tokens can only be set on this Mac.");
  }
  for (const field of ['config', 'permissionProfile', 'permission_profile']) {
    if (Object.prototype.hasOwnProperty.call(params, field)) {
      throw new Error('Client configuration overrides are not authorized: ' + field);
    }
  }
  if (params.runtimeProvider && params.runtimeProvider !== "codex") {
    throw new Error("This explicit launch authorizes the selected Codex runtime only.");
  }
  if (followCodexAccount && SHARED_CODEX_TASK_METHODS.has(request.method)) {
    return { ...request, params: bindSharedCodexTask(request.method, params, root) };
  }
  validatePathParameters(params, root);
  if (request.method === 'fuzzyFileSearch') params.roots = [root];
  if (request.method === 'skills/list') params.cwds = [root];
  if (["thread/start", "thread/resume", "thread/fork", "turn/start", "thread/settings/update"].includes(request.method)) {
    params.cwd = scopedPath(params.cwd || root, { root });
    params.approvalPolicy = followCodexAccount ? SHARED_CODEX_APPROVAL : "on-request";
    params.approvalsReviewer = "user";
    delete params.permissions;
    delete params.sandbox_policy;
    if (followCodexAccount) {
      if (request.method !== "thread/settings/update") params.permissions = SHARED_CODEX_PERMISSIONS;
      delete params.sandbox;
      delete params.sandboxPolicy;
    } else if (["thread/start", "thread/resume", "thread/fork"].includes(request.method)) {
      params.sandbox = "workspace-write";
      delete params.sandboxPolicy;
    } else {
      params.sandboxPolicy = { type: "workspaceWrite", writableRoots: [root], networkAccess: false,
        excludeTmpdirEnvVar: true, excludeSlashTmp: true };
      delete params.sandbox;
    }
  }
  return { ...request, params };
}

module.exports = { configuredRoot, scopedPath, withinRoot, validatePathParameters, bindNativeRequest,
  assertNativeMethod, createPendingResponseGate, createSharedCodexApprovalGate, assertFollowCodexPreview,
  SHARED_CODEX_PERMISSIONS, SHARED_CODEX_APPROVAL };
