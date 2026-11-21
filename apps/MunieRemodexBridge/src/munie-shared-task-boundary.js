// Munie: authorize mutations for one pinned local app-server and Mac-selected project.
const fs = require("node:fs");
const path = require("node:path");
const { createSharedCodexApprovalGate, SHARED_CODEX_PERMISSIONS } = require("./munie-project-policy");

const MAX_GRANTED_THREADS = 64;
const TERMINAL_STATUSES = new Set(["completed", "interrupted", "failed"]);

function validId(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 256 && value.trim() === value;
}

function projectIdentity(root) {
  if (!path.isAbsolute(root) || fs.realpathSync(root) !== root) throw new Error("Project must be canonical.");
  const stat = fs.statSync(root, { bigint: true });
  if (!stat.isDirectory()) throw new Error("Project must be a directory.");
  return `${stat.dev}:${stat.ino}`;
}

// Requests have already passed the project binder and contain unique, bridge-owned native RPC IDs.
// The caller supplies the live authenticated route only; a replacement must close approvals.
// No provider or history is interpreted here. Native policy verifies the destination before
// sending history, and the phone must reconcile uncertain delivery from authoritative history.
function createSharedCodexTaskBoundary({ root, sendNative, sendPhone, currentRoute, currentPhone,
  cancellationPending, now }) {
  const identity = projectIdentity(root);
  let attested = false;
  let opening = null;
  let turn = null;
  const granted = new Map();
  const unavailable = () => new Error("This shared Codex task is not authorized on the current connection.");

  function projectIsCurrent() {
    try { return projectIdentity(root) === identity; } catch { return false; }
  }

  function livePeer() {
    const route = currentRoute();
    const phone = currentPhone?.();
    return typeof route === "symbol" && (!currentPhone || validId(phone)) ? { route, phone } : null;
  }

  function samePhone(peer, origin) {
    return peer && (currentPhone ? peer.phone === origin.phone : peer.route === origin.route);
  }

  function cleanupPending() {
    return turn?.turnId != null && cancellationPending(turn.threadId, turn.turnId);
  }

  function reserve({ method, id, params }) {
    const peer = livePeer();
    if (!attested || !peer || !validId(id) || !projectIsCurrent()) throw unavailable();
    const { threadId, turnId } = params ?? {};
    if (method === "turn/interrupt") {
      if (!turn?.turnId || turn.threadId !== threadId || turn.turnId !== turnId
          || !samePhone(peer, turn) || (turn.terminal && !cleanupPending())) throw unavailable();
      return;
    }
    if (opening || (turn && (!turn.terminal || cleanupPending()))
        || params?.cwd !== root || params.permissions !== SHARED_CODEX_PERMISSIONS) throw unavailable();
    if (method === "thread/start" || method === "thread/resume") {
      if (params.ephemeral === true) throw unavailable();
      if (method === "thread/resume" && !validId(threadId)) throw unavailable();
      for (const [grantedId, route] of granted) {
        if (route !== peer.route) granted.delete(grantedId);
      }
      if (granted.size >= MAX_GRANTED_THREADS && !granted.has(threadId)) throw unavailable();
      if (method === "thread/resume") granted.delete(threadId);
      opening = { ...peer, id, method, threadId };
      return;
    }
    if (method !== "turn/start" || !validId(threadId) || granted.get(threadId) !== peer.route) throw unavailable();
    turn = { ...peer, id, threadId, turnId: null, terminal: false, gate: null, earlyTerminal: null };
  }

  function dismiss(phoneId) {
    if (phoneId && livePeer()?.route === turn?.route) {
      sendPhone({ method: "serverRequest/resolved", params: { threadId: turn.threadId, requestId: phoneId } });
    }
  }

  function drain(records, notify) {
    for (const { nativeId, phoneId } of records) {
      if (nativeId != null) sendNative({ id: nativeId, result: { decision: "cancel" } });
      if (notify) dismiss(phoneId);
    }
  }

  function closeApprovals({ nativeAlive = true, notify = false } = {}) {
    const records = turn?.gate?.close() ?? [];
    if (turn) turn.gate = null;
    if (nativeAlive) drain(records, notify);
    else {
      attested = false;
      opening = null;
      turn = null;
      granted.clear();
    }
  }

  function deny(id, message) {
    return { id, error: { code: -32000, message, data: { errorCode: "native_method_not_authorized" } } };
  }

  function observe(message) {
    const { id, method, params, result, error } = message ?? {};
    if (!method && opening && id === opening.id) {
      const request = opening;
      opening = null;
      if (livePeer()?.route !== request.route) return null;
      if (error) return message;
      const thread = result?.thread;
      if (!projectIsCurrent() || !validId(thread?.id) || thread.cwd !== root
          || result.cwd !== root || thread.ephemeral === true || thread.status?.type !== "idle"
          || result.activePermissionProfile?.id !== SHARED_CODEX_PERMISSIONS
          || (request.method === "thread/resume" && thread.id !== request.threadId)) {
        return deny(id, "The native idle thread and project permission profile were not confirmed.");
      }
      granted.set(thread.id, request.route);
    }
    if (!method && turn && id === turn.id && !turn.turnId && !turn.terminal) {
      if (error && turn.earlyTerminal === null && !Object.hasOwn(message, "result") && Number.isSafeInteger(error.code)) {
        // Native turn/start errors precede submission or affirm it was not submitted.
        const origin = turn.route;
        turn = null;
        return livePeer()?.route === origin ? message : null;
      }
      const origin = turn.route;
      if (error || !validId(result?.turn?.id) || result.turn.status !== "inProgress") {
        // Keep the hold and leave the reply unconfirmed. A synthetic RPC error would
        // imply that delivery definitely failed and could make the client resubmit.
        return null;
      }
      turn.turnId = result.turn.id;
      turn.terminal = turn.earlyTerminal === turn.turnId;
      turn.earlyTerminal = null;
      if (!turn.terminal && livePeer()?.route === origin && projectIsCurrent()) {
        try {
          turn.gate = createSharedCodexApprovalGate({ root, route: origin, threadId: turn.threadId,
            turnId: turn.turnId, now });
        } catch {
          // The directory may have changed between checks. Native callbacks stay denied.
        }
      }
      return livePeer()?.route === origin ? message : null;
    }
    if (method === "turn/completed" && turn && params?.threadId === turn.threadId
        && validId(params.turn?.id) && TERMINAL_STATUSES.has(params.turn.status)) {
      if (!turn.turnId && turn.earlyTerminal === null) turn.earlyTerminal = params.turn.id;
      if (params.turn.id === turn.turnId) {
        turn.terminal = true;
        closeApprovals({ notify: true });
      }
    }
    if (method === "serverRequest/resolved") {
      if (turn && params?.threadId === turn.threadId) dismiss(turn.gate?.resolve(params.requestId));
      return null;
    }
    if (method === "turn/started" && (turn?.threadId !== params?.threadId || turn?.terminal
        || (turn?.turnId && turn.turnId !== params.turn?.id))) granted.delete(params?.threadId);
    if (method === "thread/closed" || method === "thread/archived") granted.delete(params?.threadId);
    return message;
  }

  function offer(message) {
    if (!turn?.gate || turn.terminal || livePeer()?.route !== turn.route || !projectIsCurrent()) return false;
    let prompt;
    try { prompt = turn.gate.offer(message); } catch { return false; }
    if (sendPhone(prompt)) return true;
    turn.gate.resolve(message.id);
    return false;
  }

  function reply(message) {
    if (!turn?.gate || turn.terminal || !projectIsCurrent()) return;
    let response;
    try { response = turn.gate.reply(message, livePeer()?.route); } catch { return; }
    sendNative(response);
  }

  return {
    attest() { attested = true; },
    reserve, observe, offer, reply, closeApprovals,
    expire() { if (turn?.gate) drain(turn.gate.expire(), true); },
    settlePendingBeforeStop() { closeApprovals({ notify: true }); },
  };
}

module.exports = { createSharedCodexTaskBoundary };
