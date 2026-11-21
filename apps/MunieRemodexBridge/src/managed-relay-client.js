const { createPrivateKey, sign } = require("node:crypto");
const { Agent, request } = require("node:https");
const WebSocket = require("ws");

const MANAGED_RELAY_FRAME_LIMIT = 1024 * 1024;
const MAX_CHALLENGE_BYTES = 1024;
const HOSTED_REACHABILITY_CODES = new Set([
  "EAI_AGAIN", "ECONNREFUSED", "ECONNRESET", "ENETDOWN", "ENETUNREACH",
  "ENOTFOUND", "EHOSTUNREACH", "EPIPE", "ETIMEDOUT",
]);
const HOSTED_RETRY_CLOSE_CODES = new Set([1000, 1001, 1006, 1011, 1012, 1013]);

function loopbackManagedRelayOrigin(value) {
  try {
    const url = new URL(value);
    return url.protocol === "http:" && url.hostname === "127.0.0.1" && url.port
      && !url.username && !url.password && url.pathname === "/" && !url.search && !url.hash
      ? url.origin : null;
  } catch {
    return null;
  }
}

function hostedManagedRelayOrigin(value) {
  if (typeof value !== "string" || !value.startsWith("https://")) return null;
  const host = value.slice(8);
  if (host.length > 253 || /[^a-z0-9.-]/.test(host) || !/\.[a-z][a-z0-9-]*$/.test(host)
      || host.endsWith(".local") || host.endsWith(".localhost")
      || !host.split(".").every((label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) {
    return null;
  }
  return `https://${host}`;
}

function createManagedRelayClient({ origin, audience, encodeChallenge, attachPhone, sessionId }) {
  const base = loopbackManagedRelayOrigin(origin);
  if (!base || typeof audience !== "string") throw new TypeError("Invalid managed relay pilot configuration");
  return createClient({ base, audience, encodeChallenge, attachPhone, sessionId });
}

// Requires an app-owned origin, not an endpoint obtained from a phone or a user preference.
function createHostedManagedRelayClient({ hostedOrigin, encodeChallenge, attachPhone, sessionId, onState }) {
  const base = hostedManagedRelayOrigin(hostedOrigin);
  if (!base) throw new TypeError("Invalid hosted managed relay configuration");
  const agent = new Agent({ keepAlive: false, maxCachedSessions: 0, rejectUnauthorized: true });
  return createClient({
    base, audience: new URL(base).hostname, agent, encodeChallenge, attachPhone, sessionId, onState,
  });
}

function createClient({ base, audience, encodeChallenge, attachPhone, sessionId, agent, onState }) {
  let current = null;
  let stopped = false;
  let status;

  function publish(next) {
    if (!agent || status === next) return;
    status = next;
    onState?.(next);
  }

  function detachPhone(attempt) {
    const phone = attempt.route;
    attempt.route = null;
    phone?.binding?.detach();
  }

  function dispose(attempt) {
    attempt.controller.abort();
    clearTimeout(attempt.retry);
    clearTimeout(attempt.deadline);
    detachPhone(attempt);
    attempt.socket?.terminate();
  }

  function replaceTrust(state) {
    if (stopped) return;
    const identity = readIdentity(state);
    if (identity && current?.identity.macKey === identity.macKey && current.identity.phoneKey === identity.phoneKey) return;
    const previous = current;
    const attempt = identity && {
      identity, controller: new AbortController(), socket: null, route: null,
      retry: null, retryCount: 0, deadline: null,
    };
    current = attempt;
    if (previous) dispose(previous);
    if (current !== attempt || stopped) return;
    if (attempt) void connect(attempt);
    else publish("waitingForPair");
  }

  function fail(attempt, failure) {
    if (current !== attempt || attempt.retry) return;
    if (agent && failure === "denied") return publish("denied");
    const delay = !agent ? 1000 : failure === "quota" ? 15_000
      : Math.min(1000 * 2 ** Math.min(attempt.retryCount++, 5), 30_000);
    attempt.retry = setTimeout(() => {
      attempt.retry = null;
      void connect(attempt);
    }, delay);
    attempt.retry.unref();
    publish("unavailable");
  }

  async function connect(attempt) {
    if (current !== attempt) return;
    try {
      publish("connecting");
      if (current !== attempt) return;
      const { macKey, phoneKey, privateKey } = attempt.identity;
      const body = JSON.stringify({ role: "mac", macKey, phoneKey });
      const signal = AbortSignal.any([attempt.controller.signal, AbortSignal.timeout(3000)]);
      const challenge = agent
        ? await readHostedChallenge(`${base}/v1/managed/challenge`, agent, body, signal)
        : await readLoopbackChallenge(`${base}/v1/managed/challenge`, body, signal);
      if (current !== attempt) return;
      if (challenge?.audience !== audience || challenge.role !== "mac" || challenge.macKey !== macKey
          || challenge.phoneKey !== phoneKey || !isNonce(challenge.id)
          || (challenge.generation !== "" && !isNonce(challenge.generation))
          || !Number.isSafeInteger(challenge.expiresAt) || challenge.expiresAt <= Date.now()
          || challenge.expiresAt > Date.now() + 20_000) throw new Error("Invalid admission challenge");
      const url = new URL("/v1/managed/connect", base);
      url.protocol = agent ? "wss:" : "ws:";
      const socket = new WebSocket(url, {
        headers: {
          "x-munie-role": "mac", "x-munie-challenge": challenge.id,
          "x-munie-proof": sign(null, encodeChallenge(challenge), privateKey).toString("base64url"),
        },
        handshakeTimeout: 3000, maxPayload: MANAGED_RELAY_FRAME_LIMIT, perMessageDeflate: false,
        ...(agent ? { agent, rejectUnauthorized: true, followRedirects: false } : {}),
      });
      attempt.socket = socket;
      let registered = !agent;
      let socketFailure;
      const isCurrent = () => current === attempt && attempt.socket === socket;
      function setDeadline(delay, failure) {
        clearTimeout(attempt.deadline);
        attempt.deadline = setTimeout(() => {
          if (!isCurrent()) return;
          socketFailure = failure;
          socket.terminate();
        }, delay);
        attempt.deadline.unref();
      }
      if (agent) {
        socket.once("open", () => { if (isCurrent()) setDeadline(3000, "denied"); });
        socket.on("unexpected-response", (_, response) => {
          socketFailure = classifyHostedStatus(response.statusCode);
          response.destroy();
          socket.terminate();
        });
      }
      const canUsePhone = (phone) => isCurrent() && attempt.route === phone && !phone.closing
        && socket.readyState === WebSocket.OPEN;
      function closePhone(phone, code) {
        if (!canUsePhone(phone)) return;
        phone.closing = true;
        phone.binding?.detach();
        phone.binding = null;
        // Only an explicit size rejection gets 1009; unavailable routes fail closed with 4004.
        const closeCode = code === 1009 ? 1009 : 4004;
        socket.ping(`munie:phone-close:${phone.id}:${closeCode}`, true, (error) => {
          if (error && isCurrent() && attempt.route === phone) socket.terminate();
        });
      }
      function send(phone, text) {
        if (!canUsePhone(phone)) return false;
        const frame = JSON.stringify({ routeId: phone.id, message: text });
        const size = Buffer.byteLength(frame);
        if (size > MANAGED_RELAY_FRAME_LIMIT) {
          closePhone(phone, 1009);
          return false;
        }
        if (socket.bufferedAmount + size > MANAGED_RELAY_FRAME_LIMIT) {
          closePhone(phone, 4004);
          return false;
        }
        socket.send(frame, (error) => { if (error) socket.terminate(); });
        return true;
      }
      socket.on("error", (error) => {
        // ws reports its own opening deadline as an Error with no errno.
        socketFailure ??= error.message === "Opening handshake has timed out"
          ? "unavailable" : classifyHostedError(error);
        socket.terminate();
      });
      socket.on("ping", (data) => {
        if (!isCurrent()) return;
        const signal = data.toString();
        if (agent && !registered) {
          if (signal !== "munie:mac-registered") return;
          registered = true;
          attempt.retryCount = 0;
          setDeadline(25_000, "unavailable");
          publish("registered"); // Relay admission only; v2 still authenticates the phone.
          return;
        }
        if (agent && signal === "munie:heartbeat") {
          setDeadline(25_000, "unavailable");
        } else if (signal === "munie:phone-detached") {
          detachPhone(attempt);
        } else if (signal.startsWith("munie:phone-attached:")) {
          const routeId = signal.slice("munie:phone-attached:".length);
          if (!/^[0-9a-f-]{36}$/.test(routeId)) {
            socketFailure = "denied";
            return socket.terminate();
          }
          if (attempt.route?.id === routeId) return;
          detachPhone(attempt);
          const phone = { id: routeId, binding: null, closing: false };
          attempt.route = phone;
          const binding = attachPhone(sessionId, {
            send: (text) => send(phone, text),
            close: (code) => closePhone(phone, code),
          });
          if (!canUsePhone(phone)) return binding?.detach();
          if (!binding) return closePhone(phone);
          phone.binding = binding;
          send(phone, JSON.stringify({ kind: "managedRouteReady", sessionId }));
        }
      });
      socket.on("message", (data, isBinary) => {
        const phone = attempt.route;
        if (!phone || !canUsePhone(phone)) return;
        if (isBinary || !phone.binding?.receive(data.toString())) closePhone(phone);
      });
      socket.once("close", (code) => {
        if (!isCurrent()) return;
        attempt.socket = null;
        clearTimeout(attempt.deadline);
        detachPhone(attempt);
        fail(attempt, socketFailure ?? (registered && HOSTED_RETRY_CLOSE_CODES.has(code) ? "unavailable" : "denied"));
      });
    } catch (error) {
      fail(attempt, classifyHostedError(error));
    }
  }

  return {
    replaceTrust,
    stop() {
      stopped = true;
      const attempt = current;
      current = null;
      if (attempt) dispose(attempt);
      agent?.destroy();
      publish("stopped");
    },
  };
}

async function readLoopbackChallenge(url, body, signal) {
  const response = await fetch(url, { method: "POST", body, redirect: "error", signal });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error("Challenge request denied");
  }
  return readChallengeBody(response.body);
}

function readHostedChallenge(url, agent, body, signal) {
  return new Promise((resolve, reject) => {
    const outgoing = request(url, {
      method: "POST", agent, signal, rejectUnauthorized: true,
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) },
    }, (response) => {
      if (response.statusCode !== 200) {
        response.destroy();
        reject(new HostedChallengeFailure(classifyHostedStatus(response.statusCode)));
      } else {
        readChallengeBody(response).then(resolve, reject);
      }
    });
    outgoing.once("error", reject);
    outgoing.end(body);
  });
}

class HostedChallengeFailure extends Error {
  constructor(state) {
    super("Managed relay challenge rejected");
    this.state = state;
  }
}

function classifyHostedStatus(status) {
  if (status === 429) return "quota";
  if (status === 502 || status === 503 || status === 504) return "unavailable";
  return "denied";
}

function classifyHostedError(error) {
  if (error instanceof HostedChallengeFailure) return error.state;
  if (HOSTED_REACHABILITY_CODES.has(error?.code)
      || (error?.code === "ABORT_ERR" && error.cause?.name === "TimeoutError")) {
    return "unavailable";
  }
  return "denied";
}

async function readChallengeBody(body) {
  const chunks = [];
  let length = 0;
  for await (const part of body) {
    length += part.length;
    if (length > MAX_CHALLENGE_BYTES) throw new Error("Challenge too large");
    chunks.push(part);
  }
  return JSON.parse(Buffer.concat(chunks).toString());
}

function isNonce(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value)
    && Buffer.from(value, "base64url").toString("base64url") === value;
}

function readIdentity(state) {
  const trust = Object.values(state?.trustedPhones || {});
  if (trust.length !== 1) return null;
  try {
    const macKey = Buffer.from(state.macIdentityPublicKey, "base64").toString("base64url");
    const phoneKey = Buffer.from(trust[0], "base64").toString("base64url");
    const privateBytes = Buffer.from(state.macIdentityPrivateKey, "base64").toString("base64url");
    if (![macKey, phoneKey, privateBytes].every(isNonce)) return null;
    const privateKey = createPrivateKey({ format: "jwk", key: { kty: "OKP", crv: "Ed25519", x: macKey, d: privateBytes } });
    return { macKey, phoneKey, privateKey };
  } catch {
    return null;
  }
}

module.exports = {
  createHostedManagedRelayClient, createManagedRelayClient, hostedManagedRelayOrigin,
  loopbackManagedRelayOrigin, MANAGED_RELAY_FRAME_LIMIT,
};
