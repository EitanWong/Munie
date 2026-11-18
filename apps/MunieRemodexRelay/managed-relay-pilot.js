const { createServer } = require("node:http");
const { WebSocket, WebSocketServer } = require("ws");
const { createManagedRelayAdmission } = require("./managed-admission");

const CHALLENGE_PATH = "/v1/managed/challenge";
const UPGRADE_PATH = "/v1/managed/connect";
const MAX_BODY = 1024;
const MAX_FRAME = 1024 * 1024;
const PHONE_UNAVAILABLE = "munie:phone-unavailable";

// No CLI or configurable bind address: this is an isolated developer listener.
async function startManagedRelayPilot({ audience, allowedMacKeys }) {
  const admission = createManagedRelayAdmission({ audience, allowedMacKeys });
  const routes = new Map();
  const server = createServer({ maxHeaderSize: 4096, headersTimeout: 5000, requestTimeout: 5000 }, (req, res) => {
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
  server.on("upgrade", (req, socket, head) => {
    const role = req.headers["x-munie-role"];
    const commit = req.url === UPGRADE_PATH && (role === "mac" || role === "phone")
      ? admission.prepare(req.headers["x-munie-challenge"], req.headers["x-munie-proof"], role)
      : null;
    if (!commit) {
      socket.on("error", () => socket.destroy());
      socket.end("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", () => socket.destroy());
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.on("error", () => ws.terminate());
      const registration = commit();
      if (!registration) return ws.terminate();

      const previous = routes.get(registration.macKey);
      let route;
      if (role === "mac") {
        route = { registration, mac: ws, phone: null };
        routes.set(registration.macKey, route);
        previous?.phone?.terminate();
        previous?.mac.terminate();
      } else {
        if (previous?.registration !== registration || previous.mac.readyState !== WebSocket.OPEN) {
          return ws.terminate();
        }
        route = previous;
        const oldPhone = route.phone;
        route.phone = ws;
        oldPhone?.terminate();
      }

      ws.on("message", (data, isBinary) => {
        if (!admission.isCurrent(registration) || route[role] !== ws) return;
        const peer = role === "phone" ? route.mac : route.phone;
        if (role === "mac" && (!peer || peer.readyState !== WebSocket.OPEN) && ws.bufferedAmount < MAX_FRAME) {
          ws.ping(PHONE_UNAVAILABLE, false, (error) => { if (error) ws.terminate(); });
          return;
        }
        if (!peer || peer.readyState !== WebSocket.OPEN || peer.bufferedAmount + data.length > MAX_FRAME) {
          ws.terminate();
          return;
        }
        peer.send(data, { binary: isBinary }, (error) => {
          if (error) peer.terminate();
        });
      });
      ws.once("close", () => {
        if (routes.get(registration.macKey) !== route || route[role] !== ws) return;
        if (role === "phone") {
          route.phone = null;
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
    server.listen(0, "127.0.0.1", () => {
      server.removeListener("error", reject);
      resolve();
    });
  });
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((resolve, reject) => {
      for (const socket of sockets) socket.destroy();
      wss.close();
      server.close((error) => error ? reject(error) : resolve());
    }),
  };
}

function respond(res, status, body) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    Connection: "close",
  });
  res.end(JSON.stringify(body));
}

module.exports = { startManagedRelayPilot };
