// Munie addition: binds explicit local launches to one canonical project root.
// This is an application routing boundary; the Codex sandbox remains authoritative for tools.
const fs = require("fs");
const path = require("path");

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

function bindNativeRequest(request, root = configuredRoot()) {
  if (!root || !request?.method) return request;
  if (request.method.startsWith('desktop/') && request.method !== 'desktop/preferences/read') {
    throw new Error('This foreground launch does not authorize Desktop handoff, power changes or package updates.');
  }
  const params = { ...(request.params || {}) };
  for (const field of ['config', 'permissionProfile', 'permission_profile']) {
    if (Object.prototype.hasOwnProperty.call(params, field)) {
      throw new Error('Client configuration overrides are not authorized: ' + field);
    }
  }
  if (params.runtimeProvider && params.runtimeProvider !== "codex") {
    throw new Error("This explicit launch authorizes the selected Codex runtime only.");
  }
  validatePathParameters(params, root);
  if (request.method === 'fuzzyFileSearch') params.roots = [root];
  if (request.method === 'skills/list') params.cwds = [root];
  if (["thread/start", "thread/resume", "thread/fork", "turn/start", "thread/settings/update"].includes(request.method)) {
    params.cwd = scopedPath(params.cwd || root, { root });
    params.approvalPolicy = "on-request";
    params.approvalsReviewer = "user";
    delete params.permissions;
    delete params.sandbox_policy;
    if (["thread/start", "thread/resume", "thread/fork"].includes(request.method)) {
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
  assertNativeMethod, createPendingResponseGate };
