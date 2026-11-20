// Mac-owned Responses API adapter. The native client receives a loopback
// capability; the selected provider's key stays in the broker process.
const http = require("node:http");
const https = require("node:https");
const { randomBytes, timingSafeEqual } = require("node:crypto");
const { isIPv4 } = require("node:net");
const { Transform } = require("node:stream");
const { pipeline } = require("node:stream/promises");

const LOOPBACK = "127.0.0.1";
const RESPONSES_PATH = "/responses";
const MAX_REQUEST_BYTES = 8 * 1024 * 1024;
const MAX_RESPONSE_BYTES = 64 * 1024 * 1024;
const MAX_ACTIVE = 4;
const MAX_SOCKETS = 16;
const REQUEST_DEADLINE_MS = 10 * 60_000;
const UPSTREAM_IDLE_MS = 90_000;

function providerEndpoint(baseURL) {
  // URL normalizations can hide a fragment, path separator, or dot segment.
  // Use an ordinary authority and unambiguous directory path only.
  const match = typeof baseURL === "string" && baseURL.length <= 2048
    && /^https:\/\/([^/?#\\\s]+)(\/[^?#\\\s]*)?$/iu.exec(baseURL);
  if (!match || match[0] !== baseURL || match[1].includes("@") || match[1].includes("%")) {
    throw new Error("The custom provider base URL must be HTTPS without credentials, query, or fragment.");
  }
  const pathname = match[2] || "";
  if (pathname.includes("//") || pathname.split("/").some((segment) =>
    segment === "." || segment === ".." || !/^[A-Za-z0-9._~-]*$/u.test(segment))) {
    throw new Error("The custom provider base URL has an unsupported path.");
  }
  const url = URL.parse(baseURL);
  if (!url || url.protocol !== "https:" || !url.hostname || url.username || url.password) {
    throw new Error("The custom provider base URL is invalid.");
  }
  if (isIPv4(url.hostname) && match[1].split(":")[0] !== url.hostname) {
    throw new Error("The custom provider base URL must use a canonical IPv4 address.");
  }
  url.pathname = pathname.replace(/\/$/u, "") + RESPONSES_PATH;
  return url;
}

function bearerKey(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 512
    || /[^\x21-\x7e]/u.test(value)) {
    throw new Error("The custom provider API key is invalid.");
  }
  return value;
}

function reply(response, status) {
  if (response.destroyed) return;
  if (response.headersSent) {
    response.destroy();
    return;
  }
  response.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
    connection: "close",
  });
  const code = status === 401 ? "authentication_required"
    : status === 403 ? "provider_denied"
    : status === 429 ? "provider_rate_limited"
    : status === 502 ? "provider_unavailable"
    : status === 504 ? "provider_timeout" : "broker_request_rejected";
  response.end(JSON.stringify({ error: { code } }));
}

function requestError(status) {
  return Object.assign(new Error("The broker request was rejected."), { status });
}

function isAuthorized(request, expected) {
  const values = request.headersDistinct.authorization;
  if (!values || values.length !== 1) return false;
  const actual = Buffer.from(values[0], "latin1");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function readBody(request, signal) {
  return new Promise((resolve, reject) => {
    let bytes = 0;
    const parts = [];
    function finish(error) {
      request.off("data", onData);
      request.off("end", onEnd);
      request.off("error", onError);
      signal.removeEventListener("abort", onAbort);
      if (error) {
        request.pause();
        reject(error);
      } else {
        resolve(Buffer.concat(parts, bytes));
      }
    }
    function onData(chunk) {
      bytes += chunk.length;
      if (bytes > MAX_REQUEST_BYTES) finish(requestError(413));
      else parts.push(chunk);
    }
    function onEnd() { finish(bytes === 0 ? requestError(400) : null); }
    function onError() { finish(requestError(400)); }
    function onAbort() { finish(signal.reason); }
    request.on("data", onData);
    request.once("end", onEnd);
    request.once("error", onError);
    signal.addEventListener("abort", onAbort, { once: true });
    if (signal.aborted) onAbort();
  });
}

// Retain only a suffix that could be the start of a reflected secret. Ordinary
// chunks are forwarded immediately, including short event-stream heartbeats.
function screenResponse(secrets) {
  let bytes = 0;
  let suffix = Buffer.alloc(0);
  return new Transform({
    transform(chunk, _encoding, callback) {
      bytes += chunk.length;
      if (bytes > MAX_RESPONSE_BYTES) return callback(requestError(502));
      const combined = suffix.length ? Buffer.concat([suffix, chunk]) : chunk;
      let keep = 0;
      for (const secret of secrets) {
        if (combined.includes(secret)) return callback(requestError(502));
        for (let length = Math.min(combined.length, secret.length - 1); length > keep; length--) {
          if (combined.subarray(-length).equals(secret.subarray(0, length))) {
            keep = length;
            break;
          }
        }
      }
      suffix = keep ? Buffer.from(combined.subarray(-keep)) : Buffer.alloc(0);
      callback(null, combined.subarray(0, combined.length - keep));
    },
    flush(callback) { callback(null, suffix); },
  });
}

function openProvider(requestUpstream, endpoint, key, body, signal) {
  return new Promise((resolve, reject) => {
    const upstream = requestUpstream(endpoint, {
      method: "POST",
      agent: false,
      rejectUnauthorized: true,
      maxHeaderSize: 16 * 1024,
      signal,
      headers: {
        authorization: "Bearer " + key,
        accept: "text/event-stream, application/json",
        "accept-encoding": "identity",
        "content-type": "application/json",
        "content-length": body.length,
      },
    }, resolve);
    upstream.setTimeout(UPSTREAM_IDLE_MS, () => upstream.destroy(requestError(504)));
    upstream.on("error", reject);
    upstream.end(body);
  });
}

function responseContentType(upstream) {
  if (upstream.statusCode !== 200) return null;
  const encoding = upstream.headers["content-encoding"];
  if (encoding != null && encoding !== "identity") return null;
  const mime = upstream.headers["content-type"]?.split(";", 1)[0].trim().toLowerCase();
  if (mime !== "text/event-stream" && mime !== "application/json") return null;
  const length = upstream.headers["content-length"];
  if (length != null && (!/^\d+$/u.test(length) || Number(length) > MAX_RESPONSE_BYTES)) return null;
  return mime;
}

async function startCustomProviderBroker({ baseURL, apiKey, model = null }, { requestUpstream = https.request } = {}) {
  const endpoint = providerEndpoint(baseURL);
  const key = bearerKey(apiKey);
  const capability = randomBytes(32).toString("hex");
  const expected = Buffer.from("Bearer " + capability);
  const secrets = [...new Set([key, JSON.stringify(key).slice(1, -1), capability])].map((value) => Buffer.from(value));
  const active = new Set();
  let address;
  let stopping;

  async function handle(request, response) {
    if (stopping) return reply(response, 503);
    const hosts = request.headersDistinct.host;
    if (!hosts || hosts.length !== 1 || hosts[0] !== address
      || request.url !== RESPONSES_PATH || request.headers.upgrade != null) return reply(response, 404);
    if (request.method !== "POST") return reply(response, 405);
    if (!isAuthorized(request, expected)) return reply(response, 401);
    const types = request.headersDistinct["content-type"];
    if (!types || types.length !== 1 || !/^application\/json(?:;\s*charset=utf-8)?$/iu.test(types[0])
      || request.headers["content-encoding"] != null) return reply(response, 415);
    const length = request.headers["content-length"];
    if (length != null && Number(length) > MAX_REQUEST_BYTES) return reply(response, 413);
    if (active.size >= MAX_ACTIVE) return reply(response, 503);

    const controller = new AbortController();
    active.add(controller);
    const timer = setTimeout(() => controller.abort(requestError(504)), REQUEST_DEADLINE_MS);
    const onClose = () => {
      if (!response.writableFinished) controller.abort(requestError(502));
    };
    response.on("close", onClose);
    try {
      let body = await readBody(request, controller.signal);
      if (secrets.some((secret) => body.includes(secret))) return reply(response, 400);
      if (model !== null) {
        let decoded;
        try { decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body)); }
        catch { return reply(response, 400); }
        if (!decoded || typeof decoded !== "object" || Array.isArray(decoded) || decoded.model !== model) {
          return reply(response, 400);
        }
        // Serialize once so duplicate keys and escape spellings cannot change provider interpretation.
        body = Buffer.from(JSON.stringify(decoded));
        if (body.length > MAX_REQUEST_BYTES || secrets.some((secret) => body.includes(secret))) return reply(response, 400);
      }
      const upstream = await openProvider(requestUpstream, endpoint, key, body, controller.signal);
      const mime = responseContentType(upstream);
      if (!mime) {
        const upstreamStatus = upstream.statusCode;
        upstream.destroy();
        return reply(response, [401, 403, 429].includes(upstreamStatus) ? upstreamStatus : 502);
      }
      response.setHeader("content-type", mime);
      response.setHeader("cache-control", "no-store");
      response.setHeader("connection", "close");
      return await pipeline(upstream, screenResponse(secrets), response, { signal: controller.signal });
    } catch (error) {
      // Do not return upstream status text, bodies, URLs, or diagnostic errors.
      const status = controller.signal.reason?.status ?? error?.status;
      return reply(response, [400, 413, 504].includes(status) ? status : 502);
    } finally {
      clearTimeout(timer);
      response.off("close", onClose);
      active.delete(controller);
    }
  }

  const server = http.createServer({
    maxHeaderSize: 8192,
    headersTimeout: 5000,
    requestTimeout: 30_000,
    connectionsCheckingInterval: 1000,
  }, handle);
  server.maxConnections = MAX_SOCKETS;
  server.maxRequestsPerSocket = 1;
  server.on("checkContinue", (_request, response) => reply(response, 417));
  server.on("checkExpectation", (_request, response) => reply(response, 417));
  await new Promise((resolve, reject) => {
    server.once("error", () => reject(new Error("The custom provider broker could not listen on loopback.")));
    server.listen(0, LOOPBACK, resolve);
  });
  address = LOOPBACK + ":" + server.address().port;

  function stop() {
    if (!stopping) {
      stopping = new Promise((resolve) => server.close(resolve));
      for (const controller of active) controller.abort(requestError(502));
      server.closeAllConnections();
    }
    return stopping;
  }

  const broker = { baseURL: "http://" + address, stop };
  Object.defineProperty(broker, "capability", { value: capability });
  return Object.freeze(broker);
}

module.exports = { startCustomProviderBroker, providerEndpoint };
