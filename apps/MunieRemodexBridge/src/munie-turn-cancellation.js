// Munie addition: a turn interrupt does not terminate yielded unified-exec sessions.
// Keep cancellation pending until native background terminals from this exact turn are gone.
// All process identifiers come from native thread/item APIs; none are accepted from the phone.
function createTurnCancellationController({ request, respond, publish, diagnose = () => {}, timeoutMs = 12_000 }) {
  const pending = new Map();
  // The pinned runtime exports item-history schemas but rejects those RPCs.
  // Native live events are the source of command ownership across relay reconnects.
  const ownersByThread = new Map();
  let closed = false;
  const guardedMethods = new Set([
    "turn/start", "turn/steer", "review/start", "thread/compact/start", "thread/resume",
    "thread/read", "thread/turns/list", "thread/items/list", "thread/archive", "thread/unsubscribe",
  ]);

  function failure(message = "Codex cancellation is pending. Retry cancel before continuing this chat.") {
    return Object.assign(new Error(message), { errorCode: "cancellation_cleanup_pending" });
  }

  function replyError(id, error) {
    respond(JSON.stringify({ id, error: { code: -32000, message: error.message,
      data: { errorCode: error.errorCode || "cancellation_cleanup_pending" } } }));
  }

  function handle(message) {
    const threadId = message?.params?.threadId;
    if (message?.method !== "turn/interrupt") {
      if (!pending.has(threadId) || !guardedMethods.has(message?.method)) return false;
      if (message.id != null) replyError(message.id, failure());
      return true;
    }
    if (closed) { if (message.id != null) replyError(message.id, failure()); return true; }
    const turnId = message.params?.turnId;
    if (message.id == null || !validId(threadId) || !validId(turnId)) {
      if (message.id != null) replyError(message.id, failure("Cancellation requires exact native thread and turn IDs."));
      return true;
    }
    let state = pending.get(threadId);
    if (state && state.turnId !== turnId) {
      replyError(message.id, failure());
      return true;
    }
    if (!state) {
      if (pending.size >= 64) { replyError(message.id, failure()); return true; }
      state = { threadId, turnId, interrupted: false, terminal: null, status: null, failureMessage: null, operation: null };
      pending.set(threadId, state);
    }
    state.operation ||= cancel(state).finally(() => { state.operation = null; });
    state.operation.then((result) => {
      respond(JSON.stringify({ id: message.id, result }));
      if (pending.get(threadId) !== state) return;
      pending.delete(threadId);
      // Re-enter the ordinary native pipeline only after cleanup is confirmed.
      if (state.failureMessage) publish(state.failureMessage);
      if (state.terminal) publish(state.terminal);
      if (state.status) publish(state.status);
    }).catch((error) => {
      diagnose({ stage: state.stage || "interrupt", outcome: "pending",
        ...(Number.isInteger(error?.code) ? { nativeCode: error.code } : {}) });
      // A native JSON-RPC rejection proves the interrupt was not accepted. Let the
      // existing client refresh a stale turn id; timeouts and cleanup failures stay gated.
      if (state.nativeRejection === error && !state.uncertainInterrupt && !state.interrupted && !state.terminal) {
        if (pending.get(threadId) === state) pending.delete(threadId);
        respond(JSON.stringify({ id: message.id, error: { code: error.code, message: error.message,
          ...(error.data !== undefined ? { data: error.data } : {}) } }));
      } else replyError(message.id, failure());
    });
    return true;
  }

  function observe(message) {
    const params = message?.params;
    if (message?.method === "item/started" || message?.method === "item/completed") {
      rememberOwner(params?.threadId, params?.turnId, params?.item);
    } else if (message?.method === "turn/completed" && Array.isArray(params?.turn?.items)) {
      for (const item of params.turn.items) rememberOwner(params.threadId, params.turn.id, item);
    }
    const state = pending.get(params?.threadId);
    if (!state) return false;
    if (message.method === "turn/completed" && params.turn?.id === state.turnId) {
      state.terminal = message;
      // A thread-scoped status observed earlier cannot be replayed after this turn's terminal.
      state.status = null;
      state.onTerminal?.();
      return true;
    }
    if (message.method === "thread/status/changed") {
      state.status = message;
      return true;
    }
    if (isTerminalFailure(message, state.turnId)) {
      state.failureMessage = message;
      return true;
    }
    return false;
  }

  function rememberOwner(threadId, turnId, item) {
    if (!validId(threadId) || !validId(turnId) || !validId(item?.id) || !validId(item.type)) return;
    let owners = ownersByThread.get(threadId);
    if (!owners) {
      if (ownersByThread.size >= 128) {
        const oldest = [...ownersByThread.keys()].find((id) => !pending.has(id));
        if (oldest) ownersByThread.delete(oldest);
        else return;
      }
      owners = new Map(); ownersByThread.set(threadId, owners);
    }
    const previous = owners.get(item.id);
    const conflict = previous?.conflict || (previous && (previous.turnId !== turnId || previous.type !== item.type));
    owners.delete(item.id);
    owners.set(item.id, { turnId, type: item.type, conflict: Boolean(conflict) });
    if (owners.size > 1_024) owners.delete(owners.keys().next().value);
  }

  function holdOutbound(message) {
    const state = pending.get(message?.params?.threadId);
    if (!state) return false;
    if (message.method === "thread/status/changed") return true;
    // Rollout/Desktop catch-up notifications use flat ids and cannot prove native completion.
    return isTerminalFailure(message, state.turnId) || (message.method === "turn/completed"
      && (message.params.turn?.id || message.params.turnId || message.params.id) === state.turnId);
  }

  async function cancel(state) {
    const deadline = Date.now() + timeoutMs;
    const call = (method, params) => {
      const remaining = deadline - Date.now();
      if (closed || remaining <= 0) throw failure();
      return request(method, params, { timeoutMs: Math.min(remaining, 4_000) });
    };
    if (!state.interrupted && !state.terminal) {
      state.stage = "interrupt";
      try {
        state.result = await call("turn/interrupt", { threadId: state.threadId, turnId: state.turnId });
      } catch (error) {
        if (Number.isInteger(error?.code)) state.nativeRejection = error;
        else state.uncertainInterrupt = true;
        throw error;
      }
      state.interrupted = true;
    }
    if (!state.terminal) {
      state.stage = "terminal";
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { state.onTerminal = null; reject(failure()); },
          Math.max(1, Math.min(4_000, deadline - Date.now())));
        state.onTerminal = () => { clearTimeout(timer); state.onTerminal = null; resolve(); };
      });
    }
    // Once the native terminal event arrives, this turn cannot create more command items.
    const ownerFor = (terminal) => {
      if (!validId(terminal?.itemId) || !validId(terminal.processId)) throw failure();
      const owner = ownersByThread.get(state.threadId)?.get(terminal.itemId);
      if (!owner || owner.conflict || owner.type !== "commandExecution") throw failure();
      return owner;
    };
    const list = () => pages("thread/backgroundTerminals/list", { threadId: state.threadId }, call);
    state.stage = "background-list";
    const terminals = await list();
    state.stage = "ownership";
    // Validate the full page set before terminating any process.
    for (const terminal of terminals) ownerFor(terminal);
    for (const terminal of terminals) {
      if (ownerFor(terminal).turnId !== state.turnId) continue;
      state.stage = "terminate";
      const result = await call("thread/backgroundTerminals/terminate", {
        threadId: state.threadId, processId: terminal.processId,
      });
      if (typeof result?.terminated !== "boolean") throw failure();
    }
    // A false terminate result can mean it exited concurrently. The fresh native list decides.
    state.stage = "background-verify";
    const remaining = await list();
    for (const terminal of remaining) {
      if (ownerFor(terminal).turnId === state.turnId) throw failure();
    }
    if (closed) throw failure();
    diagnose({ stage: "confirmed", outcome: "completed" });
    return state.result ?? {};
  }

  function close() {
    closed = true;
    for (const state of pending.values()) state.onTerminal?.();
    pending.clear();
    ownersByThread.clear();
  }

  return { handle, observe, holdOutbound, close,
    isPending(threadId, turnId) { return pending.get(threadId)?.turnId === turnId && validId(turnId); },
  };
}

function validId(value) { return typeof value === "string" && value.length > 0 && value.trim() === value; }

function isTerminalFailure(message, turnId) {
  return (message.params?.turn?.id || message.params?.turnId || message.params?.id) === turnId
    && (message.method === "turn/failed" || (message.method === "error" && message.params.willRetry !== true));
}

async function pages(method, params, call) {
  const result = [];
  const cursors = new Set();
  let cursor;
  for (let page = 0; page < 16; page++) {
    const response = await call(method, { ...params, limit: 100, ...(cursor ? { cursor } : {}) });
    if (!Array.isArray(response?.data) || response.data.length > 100) throw new Error("Invalid native page.");
    result.push(...response.data);
    cursor = response.nextCursor;
    if (cursor == null) return result;
    if (!validId(cursor) || cursors.has(cursor)) throw new Error("Invalid native cursor.");
    cursors.add(cursor);
  }
  throw new Error("Native cancellation page limit exceeded.");
}

module.exports = { createTurnCancellationController };
