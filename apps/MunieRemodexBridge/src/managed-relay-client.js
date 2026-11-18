const { createPrivateKey, sign } = require("node:crypto");
const WebSocket = require("ws");

const MANAGED_RELAY_FRAME_LIMIT = 1024 * 1024;

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

// Only the developer pilot can supply an origin. The packaged app does not set it.
function createManagedRelayClient({ origin, audience, encodeChallenge, attachPhone, sessionId }) {
  const base = loopbackManagedRelayOrigin(origin);
  if (!base || typeof audience !== "string") throw new TypeError("Invalid managed relay pilot configuration");
  let current = null;
  let stopped = false;

  function detachPhone(attempt) {
    const phone = attempt.route;
    attempt.route = null;
    phone?.binding?.detach();
  }

  function dispose(attempt) {
    attempt.controller.abort();
    clearTimeout(attempt.retry);
    detachPhone(attempt);
    attempt.socket?.terminate();
  }

  function replaceTrust(state) {
    if (stopped) return;
    const identity = readIdentity(state);
    if (current?.identity.macKey === identity?.macKey && current?.identity.phoneKey === identity?.phoneKey) return;
    if (current) dispose(current);
    current = identity && { identity, controller: new AbortController(), socket: null, route: null, retry: null };
    if (current) void connect(current);
  }

  function retry(attempt) {
    if (current !== attempt || attempt.retry) return;
    attempt.retry = setTimeout(() => {
      attempt.retry = null;
      void connect(attempt);
    }, 1000);
    attempt.retry.unref();
  }

  async function connect(attempt) {
    if (current !== attempt) return;
    try {
      const { macKey, phoneKey, privateKey } = attempt.identity;
      const response = await fetch(`${base}/v1/managed/challenge`, {
        method: "POST",
        body: JSON.stringify({ role: "mac", macKey, phoneKey }),
        redirect: "error",
        signal: AbortSignal.any([attempt.controller.signal, AbortSignal.timeout(3000)]),
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new Error("Challenge request denied");
      }
      const challenge = await readChallenge(response);
      if (current !== attempt) return;
      if (challenge?.audience !== audience || challenge.role !== "mac" || challenge.macKey !== macKey
          || challenge.phoneKey !== phoneKey || !isNonce(challenge.id)
          || (challenge.generation !== "" && !isNonce(challenge.generation))
          || !Number.isSafeInteger(challenge.expiresAt) || challenge.expiresAt <= Date.now()
          || challenge.expiresAt > Date.now() + 20_000) throw new Error("Invalid admission challenge");
      const url = new URL("/v1/managed/connect", base);
      url.protocol = "ws:";
      const socket = new WebSocket(url, {
        headers: {
          "x-munie-role": "mac", "x-munie-challenge": challenge.id,
          "x-munie-proof": sign(null, encodeChallenge(challenge), privateKey).toString("base64url"),
        },
        handshakeTimeout: 3000, maxPayload: MANAGED_RELAY_FRAME_LIMIT, perMessageDeflate: false,
      });
      attempt.socket = socket;
      const isCurrent = () => current === attempt && attempt.socket === socket;
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
      socket.on("error", () => socket.terminate());
      socket.on("ping", (data) => {
        if (!isCurrent()) return;
        const signal = data.toString();
        if (signal === "munie:phone-detached") {
          detachPhone(attempt);
        } else if (signal.startsWith("munie:phone-attached:")) {
          const routeId = signal.slice("munie:phone-attached:".length);
          if (!/^[0-9a-f-]{36}$/.test(routeId)) return socket.terminate();
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
      socket.once("close", () => {
        if (!isCurrent()) return;
        attempt.socket = null;
        detachPhone(attempt);
        retry(attempt);
      });
    } catch {
      retry(attempt);
    }
  }

  return {
    replaceTrust,
    stop() {
      stopped = true;
      const attempt = current;
      current = null;
      if (attempt) dispose(attempt);
    },
  };
}

async function readChallenge(response) {
  const chunks = [];
  let length = 0;
  for await (const part of response.body) {
    length += part.length;
    if (length > 1024) throw new Error("Challenge too large");
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

module.exports = { createManagedRelayClient, loopbackManagedRelayOrigin, MANAGED_RELAY_FRAME_LIMIT };
