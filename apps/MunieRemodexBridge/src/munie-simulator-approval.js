// Munie signed simulator fixture. No installed-account or arbitrary command path.
const { createSharedCodexApprovalGate, SHARED_CODEX_PERMISSIONS } = require("./munie-project-policy");

const FIXTURE_PROMPT = "Munie signed simulator stop probe";
const FIXTURE_COMMAND = "/bin/sh managed-stop.sh";
const FIXTURE_ACTIONS = new Set(["thread/start", "thread/resume", "turn/start", "turn/interrupt"]);

function createSimulatorApprovalBoundary({ root, sendNative, sendPhone, currentRoute, cancellationPending, now }) {
  let attested = false;
  let opening = null;
  let threadId = null;
  let turn = null;
  let submitted = false;

  function reserve({ method, id, params }) {
    const route = currentRoute();
    const unavailable = () => new Error("The signed simulator action is not available.");
    if (!attested || !route || typeof id !== "string") throw unavailable();
    if (method === "thread/start" || method === "thread/resume") {
      if (opening || (method === "thread/start" && threadId)
          || (method === "thread/resume" && (!threadId || params.threadId !== threadId || (turn && !turn.terminal)))) {
        throw unavailable();
      }
      opening = { method, id };
    } else if (method === "turn/start") {
      if (submitted || opening || !threadId || params.threadId !== threadId
          || params.input?.length !== 1 || params.input[0].text !== FIXTURE_PROMPT) throw unavailable();
      submitted = true;
      turn = { id, route, threadId, turnId: null, terminal: false, gate: null };
    } else if (method === "turn/interrupt") {
      if (!turn || !turn.turnId || params.threadId !== turn.threadId || params.turnId !== turn.turnId
          || (turn.terminal && !cancellationPending(turn.threadId, turn.turnId))) throw unavailable();
    }
  }

  function dismiss(phoneId) {
    if (phoneId && currentRoute() === turn?.route) {
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
  }

  function observe(message) {
    const { id, method, params, result, error } = message ?? {};
    if (!method && opening && id === opening.id) {
      const opened = opening;
      opening = null;
      const valid = !error && result?.thread?.cwd === root
        && typeof result.thread.id === "string" && result.thread.id.length > 0
        && result.activePermissionProfile?.id === SHARED_CODEX_PERMISSIONS
        && (opened.method === "thread/start" || result.thread.id === threadId);
      if (valid) threadId = result.thread.id;
      else if (!error) {
        threadId = null;
        return { id, error: { code: -32000, message: "Native simulator profile was not confirmed." } };
      }
    }
    if (!method && turn && id === turn.id && !turn.turnId && !turn.terminal) {
      turn.turnId = typeof result?.turn?.id === "string" ? result.turn.id : null;
      turn.terminal = !turn.turnId || result.turn.status !== "inProgress";
      if (!turn.terminal && currentRoute() === turn.route) {
        turn.gate = createSharedCodexApprovalGate({ root, route: turn.route, threadId, turnId: turn.turnId, now });
      }
    }
    if (method === "turn/completed" && turn && params?.threadId === turn.threadId && params.turn?.id === turn.turnId) {
      turn.terminal = true;
      closeApprovals({ notify: true });
    }
    if (method === "serverRequest/resolved") {
      if (turn && params?.threadId === turn.threadId) dismiss(turn.gate?.resolve(params.requestId));
      return null; // Never publish native callback IDs into the phone replay buffer.
    }
    return message;
  }

  function offer(message) {
    if (!turn?.gate || turn.terminal || currentRoute() !== turn.route
        || message.params?.command !== `/bin/sh -c '${FIXTURE_COMMAND}'`) return false;
    let prompt;
    try { prompt = turn.gate.offer(message); }
    catch { return false; }
    if (sendPhone(prompt)) return true;
    turn.gate.resolve(message.id);
    return false;
  }

  function reply(message) {
    if (!turn?.gate || turn.terminal) return;
    let response;
    try { response = turn.gate.reply(message, currentRoute()); }
    catch { return; }
    sendNative(response);
  }

  return {
    attest() { attested = true; },
    reserve, observe, offer, reply, closeApprovals,
    expire() { if (turn?.gate) drain(turn.gate.expire(), true); },
    settlePendingBeforeStop() { closeApprovals({ notify: true }); },
  };
}

module.exports = { createSimulatorApprovalBoundary, FIXTURE_ACTIONS, FIXTURE_COMMAND };
