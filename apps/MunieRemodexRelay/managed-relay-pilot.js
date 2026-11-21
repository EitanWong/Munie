const { createServer } = require("node:http");
const { randomUUID } = require("node:crypto");
const { constants } = require("node:fs");
const { open } = require("node:fs/promises");
const { WebSocket, WebSocketServer } = require("ws");
const { createManagedRelayAdmission, ISSUANCE_LIMIT_REACHED } = require("./managed-admission");

const CHALLENGE_PATH = "/v1/managed/challenge";
const UPGRADE_PATH = "/v1/managed/connect";
const MAX_BODY = 1024;
const MAX_FRAME = 1024 * 1024;
const PHONE_ATTACHED = "munie:phone-attached";
const PHONE_DETACHED = "munie:phone-detached";
const PHONE_CLOSE = "munie:phone-close";
const PHONE_UNAVAILABLE = "munie:phone-unavailable";
const PHONE_TOO_BIG_REASON = "Mobile route frame too large";
const PHONE_UNAVAILABLE_REASON = "Mobile route unavailable";
const MAC_REGISTERED = "munie:mac-registered";
const HEARTBEAT = "munie:heartbeat";
const HOSTED_HEARTBEAT_MS = 10_000;
const MAX_CONFIG_BYTES = 8192;
const MAX_HOSTED_MACS = 32;

function startManagedRelayPilot({ audience, allowedMacKeys, now }) {
  return startManagedRelay({ audience, allowedMacKeys, now, port: 0 });
}

// The operator's TLS edge must preserve the original Host and forward only the two managed routes.
async function startHostedManagedRelay(config) {
  if (!config || Object.keys(config).length !== 3) throw new TypeError("Invalid hosted relay configuration");
  const { hostname, port, allowedMacKeys } = config;
  if (!isCanonicalHostname(hostname)
      || !Number.isSafeInteger(port) || port < 0 || port > 65535
      || !Array.isArray(allowedMacKeys) || allowedMacKeys.length < 1 || allowedMacKeys.length > MAX_HOSTED_MACS
      || new Set(allowedMacKeys).size !== allowedMacKeys.length) {
    throw new TypeError("Invalid hosted relay configuration");
  }
  return startManagedRelay({ audience: hostname, allowedMacKeys, port, hostedAuthority: hostname });
}

function isCanonicalHostname(hostname) {
  return typeof hostname === "string" && hostname.length <= 253
    && hostname.includes(".") && hostname.split(".").every(
      (label) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label),
    )
    && URL.parse(`https://${hostname}`)?.hostname === hostname
    && !/^[0-9.]+$/.test(hostname);
}

async function startManagedRelay({ audience, allowedMacKeys, now, port, hostedAuthority }) {
  const admission = createManagedRelayAdmission({ audience, allowedMacKeys, now });
  const routes = new Map();
  function acceptsAuthority(req) {
    const hosts = req.headersDistinct.host;
    return !hostedAuthority || (hosts?.length === 1 && hosts[0] === hostedAuthority);
  }
  const server = createServer({
    maxHeaderSize: 4096, headersTimeout: 5000, requestTimeout: 5000,
    ...(hostedAuthority ? { connectionsCheckingInterval: 1000 } : {}),
  }, (req, res) => {
    if (!acceptsAuthority(req)) return respond(res, 421, { ok: false });
    if (req.method !== "POST" || req.url !== CHALLENGE_PATH) {
      return respond(res, 404, { ok: false });
    }
    const chunks = [];
    let size = 0;
    req.setTimeout(3000, () => req.destroy());
    req.on("error", () => res.destroy());
    req.on("data", (chunk) => {
      if (res.writableEnded) return;
      size += chunk.length;
      if (size > MAX_BODY) {
        respond(res, 413, { ok: false });
      } else {
        chunks.push(chunk);
      }
    });
    req.on("end", () => {
      if (res.writableEnded) return;
      let parameters;
      try {
        parameters = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      } catch {
        return respond(res, 400, { ok: false });
      }
      if (!parameters || typeof parameters !== "object" || Array.isArray(parameters)) {
        return respond(res, 400, { ok: false });
      }
      const challenge = admission.issue(parameters);
      if (challenge === ISSUANCE_LIMIT_REACHED) return respond(res, 429, { ok: false });
      return respond(res, challenge ? 200 : 403, challenge ?? { ok: false });
    });
  });
  server.maxConnections = 64;
  const sockets = new Set();
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: MAX_FRAME });
  const awaitingHeartbeat = new Set();
  server.on("upgrade", (req, socket, head) => {
    if (!acceptsAuthority(req)) return rejectUpgrade(socket, "421 Misdirected Request");
    const role = req.headers["x-munie-role"];
    const commit = req.url === UPGRADE_PATH && (role === "mac" || role === "phone")
      ? admission.prepare(req.headers["x-munie-challenge"], req.headers["x-munie-proof"], role)
      : null;
    if (!commit) {
      return rejectUpgrade(socket, "403 Forbidden");
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.on("error", () => ws.terminate());
      const registration = commit();
      if (!registration) return ws.terminate();

      const previous = routes.get(registration.macKey);
      let route;
      if (role === "mac") {
        route = { registration, mac: ws, phone: null, phoneRouteId: null };
        routes.set(registration.macKey, route);
        previous?.phone?.terminate();
        previous?.mac.terminate();
        if (hostedAuthority) sendPhoneControl(ws, MAC_REGISTERED);
      } else {
        if (previous?.registration !== registration || previous.mac.readyState !== WebSocket.OPEN) {
          return ws.terminate();
        }
        route = previous;
        if (route.phone) return ws.terminate();
        route.phone = ws;
        route.phoneRouteId = randomUUID();
        sendPhoneControl(route.mac, `${PHONE_ATTACHED}:${route.phoneRouteId}`);
      }

      if (hostedAuthority) {
        ws.on("pong", (data) => {
          if (data.toString() === HEARTBEAT) awaitingHeartbeat.delete(ws);
        });
      }
      if (role === "mac") {
        ws.on("ping", (data) => {
          if (!admission.isCurrent(registration) || route.mac !== ws || ws.readyState !== WebSocket.OPEN) return;
          const phone = route.phone;
          if (phone?.readyState !== WebSocket.OPEN) return;
          const signal = data.toString();
          const prefix = `${PHONE_CLOSE}:${route.phoneRouteId}:`;
          if (signal === `${prefix}1009`) phone.close(1009, PHONE_TOO_BIG_REASON);
          if (signal === `${prefix}4004`) phone.close(4004, PHONE_UNAVAILABLE_REASON);
        });
      }
      ws.on("message", (data, isBinary) => {
        if (!admission.isCurrent(registration) || route[role] !== ws || ws.readyState !== WebSocket.OPEN) return;
        const peer = role === "phone" ? route.mac : route.phone;
        if (role === "mac" && (!peer || peer.readyState !== WebSocket.OPEN)) {
          return sendPhoneControl(ws, PHONE_UNAVAILABLE);
        }
        if (isBinary) return ws.terminate();
        let payload = data;
        if (role === "mac") {
          let frame;
          try { frame = JSON.parse(data.toString()); } catch { return; }
          if (frame?.routeId !== route.phoneRouteId || typeof frame.message !== "string") return;
          payload = Buffer.from(frame.message);
        }
        if (!peer || peer.readyState !== WebSocket.OPEN || peer.bufferedAmount + payload.length > MAX_FRAME) {
          const phone = role === "mac" ? peer : ws;
          phone?.close(4004, PHONE_UNAVAILABLE_REASON);
          return;
        }
        peer.send(payload, { binary: false }, (error) => {
          if (error) peer.terminate();
        });
      });
      ws.once("close", () => {
        awaitingHeartbeat.delete(ws);
        if (routes.get(registration.macKey) !== route || route[role] !== ws) return;
        if (role === "phone") {
          route.phone = null;
          route.phoneRouteId = null;
          sendPhoneControl(route.mac, PHONE_DETACHED);
        } else {
          admission.deactivate(registration);
          routes.delete(registration.macKey);
          route.phone?.terminate();
        }
      });
    });
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
  const heartbeat = hostedAuthority ? setInterval(() => {
    for (const route of routes.values()) {
      for (const ws of [route.mac, route.phone]) {
        if (ws?.readyState !== WebSocket.OPEN) continue;
        if (awaitingHeartbeat.has(ws)) {
          ws.terminate();
        } else {
          awaitingHeartbeat.add(ws);
          sendPhoneControl(ws, HEARTBEAT);
        }
      }
    }
  }, HOSTED_HEARTBEAT_MS).unref() : null;
  let closing;
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    snapshot: () => {
      let activeMacRoutes = 0;
      let activePhoneRoutes = 0;
      for (const route of routes.values()) {
        if (route.mac.readyState !== WebSocket.OPEN) continue;
        activeMacRoutes += 1;
        if (route.phone?.readyState === WebSocket.OPEN) activePhoneRoutes += 1;
      }
      return { activeMacRoutes, activePhoneRoutes };
    },
    close: () => closing ??= new Promise((resolve, reject) => {
      clearInterval(heartbeat);
      for (const route of routes.values()) admission.deactivate(route.registration);
      routes.clear();
      awaitingHeartbeat.clear();
      for (const socket of sockets) socket.destroy();
      wss.close();
      server.close((error) => error ? reject(error) : resolve());
    }),
  };
}

function rejectUpgrade(socket, status) {
  socket.on("error", () => socket.destroy());
  socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`, () => socket.destroy());
}

function sendPhoneControl(mac, payload) {
  if (mac.readyState !== WebSocket.OPEN) return;
  if (mac.bufferedAmount >= MAX_FRAME) return mac.terminate();
  mac.ping(payload, false, (error) => { if (error) mac.terminate(); });
}

function respond(res, status, body) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    Connection: "close",
  });
  res.end(JSON.stringify(body));
}

async function readOperatorConfiguration(path) {
  const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
  try {
    if (!(await file.stat()).isFile()) throw new TypeError("Invalid hosted relay configuration");
    const buffer = Buffer.alloc(MAX_CONFIG_BYTES + 1);
    let size = 0;
    while (size < buffer.length) {
      const { bytesRead } = await file.read(buffer, size, buffer.length - size, null);
      if (bytesRead === 0) break;
      size += bytesRead;
    }
    if (size > MAX_CONFIG_BYTES) throw new TypeError("Invalid hosted relay configuration");
    return JSON.parse(buffer.toString("utf8", 0, size));
  } finally {
    await file.close();
  }
}

async function runHostedRelay(args) {
  if (args.length !== 1) throw new TypeError("A single configuration file is required");
  const config = await readOperatorConfiguration(args[0]);
  if (config?.port === 0) throw new TypeError("A fixed listener port is required");
  const relay = await startHostedManagedRelay(config);
  const snapshot = () => console.log(JSON.stringify({
    event: "managed-relay-snapshot", time: new Date().toISOString(), ...relay.snapshot(),
  }));
  const stop = () => {
    relay.close().catch(() => {
      console.error("Managed relay shutdown failed");
      process.exitCode = 1;
    });
  };
  process.on("SIGUSR2", snapshot);
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  snapshot();
}

if (require.main === module) {
  runHostedRelay(process.argv.slice(2)).catch(() => {
    console.error("Managed relay startup failed; check the operator configuration and loopback listener port");
    process.exitCode = 1;
  });
}

module.exports = { startManagedRelayPilot, startHostedManagedRelay };
