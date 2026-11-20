const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const { EventEmitter, once } = require("node:events");
const { PassThrough } = require("node:stream");
const { startCustomProviderBroker } = require("../src/custom-provider-broker");

const FIXTURE_KEY = "synthetic-not-a-live-provider-key";
const BASE = "https://provider.invalid/api/v1/";
const PAYLOAD = JSON.stringify({ model: "fixture-only", input: "fixed input", stream: true });

function intercept() {
  const requests = [];
  const started = new EventEmitter();
  function requestUpstream(endpoint, options, callback) {
    const request = new EventEmitter();
    let stream;
    let destroyed = false;
    request.setTimeout = (timeout) => { request.idleTimeout = timeout; };
    request.destroy = (error) => {
      if (destroyed) return;
      destroyed = true;
      if (stream) stream.destroy();
      queueMicrotask(() => request.emit("error", error));
    };
    options.signal.addEventListener("abort", () => request.destroy(options.signal.reason), { once: true });
    request.end = (body) => {
      const observed = {
        endpoint: endpoint.href,
        options,
        body,
        get destroyed() { return destroyed; },
        get idleTimeout() { return request.idleTimeout; },
        respond(statusCode, headers) {
          stream = new PassThrough();
          stream.statusCode = statusCode;
          stream.headers = headers;
          callback(stream);
          return stream;
        },
        fail(error) { request.destroy(error); },
      };
      requests.push(observed);
      started.emit("started");
    };
    return request;
  }
  async function at(index) {
    while (!requests[index]) await once(started, "started");
    return requests[index];
  }
  return { requestUpstream, requests, at };
}

async function setup(t, profile = { baseURL: BASE, apiKey: FIXTURE_KEY }) {
  const upstream = intercept();
  const broker = await startCustomProviderBroker(profile, { requestUpstream: upstream.requestUpstream });
  t.after(() => broker.stop());
  return { broker, upstream };
}

test("the selected model is enforced before upstream and known denial stays secret-free", async (t) => {
  const { broker, upstream } = await setup(t, { baseURL: BASE, apiKey: FIXTURE_KEY, model: "selected/model" });
  assert.equal((await send(broker, { body: '{"model":"different/model"}' }).result).status, 400);
  assert.equal(upstream.requests.length, 0);
  const pending = send(broker, { body: '{"model":"selected/model"}' });
  const request = await upstream.at(0);
  const response = request.respond(401, { "content-type": "application/json" });
  response.end(JSON.stringify({ error: { message: FIXTURE_KEY } }));
  const denied = await pending.result;
  assert.equal(denied.status, 401);
  assert.equal(denied.text, '{"error":{"code":"authentication_required"}}');
});

function send(broker, { path = "/responses", method = "POST", body = PAYLOAD, headers = {} } = {}) {
  let text = "";
  let status = null;
  let responseHeaders = null;
  const firstChunk = new EventEmitter();
  const result = new Promise((resolve) => {
    const request = http.request(broker.baseURL, {
      method,
      path,
      agent: false,
      headers: {
        authorization: "Bearer " + broker.capability,
        "content-type": "application/json",
        ...headers,
      },
    }, (response) => {
      status = response.statusCode;
      responseHeaders = response.headers;
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        text += chunk;
        firstChunk.emit("data", chunk);
      });
      response.on("end", () => resolve({ status, headers: responseHeaders, text, ended: true }));
      response.on("error", () => resolve({ status, headers: responseHeaders, text, ended: false }));
    });
    request.on("error", () => resolve({ status, headers: responseHeaders, text, ended: false }));
    request.end(body);
  });
  return { result, firstChunk };
}

test("targets one selected HTTPS Responses endpoint and streams through without forwarding local credentials", { timeout: 5000 }, async (t) => {
  const { broker, upstream } = await setup(t);
  assert.match(broker.baseURL, /^http:\/\/127\.0\.0\.1:\d+$/u);
  assert.match(broker.capability, /^[a-f0-9]{64}$/u);
  assert.equal(JSON.stringify(broker).includes(broker.capability), false);
  const local = send(broker, {
    headers: { cookie: "local-session=secret", "x-api-key": "unrelated", "x-provider": "other.invalid" },
  });
  const request = await upstream.at(0);
  assert.equal(request.endpoint, "https://provider.invalid/api/v1/responses");
  assert.equal(request.options.method, "POST");
  assert.equal(request.options.agent, false);
  assert.equal(request.options.rejectUnauthorized, true);
  assert.equal(request.options.headers.authorization, "Bearer " + FIXTURE_KEY);
  assert.equal(request.options.headers.cookie, undefined);
  assert.equal(request.options.headers["x-api-key"], undefined);
  assert.equal(request.options.headers["x-provider"], undefined);
  assert.equal(request.body.toString(), PAYLOAD);
  assert.equal(request.idleTimeout, 90_000);
  const stream = request.respond(200, { "content-type": "text/event-stream; charset=utf-8", "set-cookie": "upstream=secret" });
  const chunk = once(local.firstChunk, "data");
  stream.write(": heartbeat\n\n");
  assert.equal((await chunk)[0], ": heartbeat\n\n");
  stream.end("data: completed\n\n");
  const outcome = await local.result;
  assert.equal(outcome.status, 200);
  assert.equal(outcome.headers["content-type"], "text/event-stream");
  assert.equal(outcome.headers["set-cookie"], undefined);
  assert.equal(outcome.text, ": heartbeat\n\ndata: completed\n\n");
  assert.equal(outcome.ended, true);
});

test("rejects ambiguous and unauthorized local requests without contacting the provider", { timeout: 5000 }, async (t) => {
  const { broker, upstream } = await setup(t);
  for (const [options, status] of [
    [{ path: "/responses/" }, 404],
    [{ path: "/responses?alternate=1" }, 404],
    [{ path: "/%72esponses" }, 404],
    [{ path: "https://other.invalid/responses" }, 404],
    [{ path: "/v1/responses" }, 404],
    [{ headers: { host: "rebound.invalid" } }, 404],
    [{ method: "GET" }, 405],
    [{ headers: { authorization: "Bearer wrong" } }, 401],
    [{ headers: { authorization: ["Bearer " + broker.capability, "Bearer extra"] } }, 401],
    [{ headers: { "content-type": "text/plain" } }, 415],
    [{ headers: { "content-encoding": "gzip" } }, 415],
    [{ body: "" }, 400],
    [{ body: JSON.stringify([FIXTURE_KEY, broker.capability]) }, 400],
    [{ headers: { "content-length": 8 * 1024 * 1024 + 1 }, body: "" }, 413],
  ]) {
    assert.equal((await send(broker, options).result).status, status);
  }
  assert.equal(upstream.requests.length, 0);
});

test("enforces the request body ceiling with chunked transfer", { timeout: 5000 }, async (t) => {
  const { broker, upstream } = await setup(t);
  const body = Buffer.alloc(8 * 1024 * 1024 + 1, "x");
  assert.equal((await send(broker, { body, headers: { "transfer-encoding": "chunked" } }).result).status, 413);
  assert.equal(upstream.requests.length, 0);
});

test("rejects malformed provider profiles without listening or accessing HTTPS", async () => {
  for (const baseURL of [
    "https://127.1/v1",
    "https://0177.0.0.1/v1",
    "https://0x7f000001/v1",
    "http://provider.invalid/v1",
    "https://other.invalid@provider.invalid/v1",
    "https://provider.invalid/v1?",
    "https://provider.invalid/v1#",
    "https://provider.invalid/v1/../v2",
    "https://provider.invalid/v1/%2e%2e",
    "https://provider.invalid/v1%2f",
    "https://provider.invalid/v1//nested",
    "https://provider.invalid\\v1",
    "https://provider.invalid/v1\n",
  ]) {
    await assert.rejects(startCustomProviderBroker({ baseURL, apiKey: FIXTURE_KEY }), /custom provider base URL/u);
  }
  await assert.rejects(startCustomProviderBroker({ baseURL: BASE, apiKey: "contains\nnewline" }), /custom provider API key/u);
});

test("does not follow redirects or expose remote errors, headers, or values in diagnostics", { timeout: 5000 }, async (t) => {
  const { broker, upstream } = await setup(t);
  const cases = [
    (request) => request.respond(307, { location: "https://unapproved.invalid/", "set-cookie": FIXTURE_KEY }),
    (request) => request.respond(401, { "content-type": "application/json", "www-authenticate": FIXTURE_KEY }),
    (request) => request.respond(200, { "content-type": "application/json", "content-encoding": "gzip" }),
    (request) => request.respond(200, { "content-type": "application/json", "content-length": String(64 * 1024 * 1024 + 1) }),
    (request) => request.fail(new Error(FIXTURE_KEY)),
  ];
  for (const [index, provider] of cases.entries()) {
    const local = send(broker);
    const stream = provider(await upstream.at(index));
    stream?.end(FIXTURE_KEY);
    const result = await local.result;
    assert.equal(result.status, index === 1 ? 401 : 502);
    assert.equal(result.ended, true);
    assert.equal(result.text, index === 1
      ? '{"error":{"code":"authentication_required"}}'
      : '{"error":{"code":"provider_unavailable"}}');
    assert.equal(result.headers.location, undefined);
    assert.equal(result.headers["set-cookie"], undefined);
    assert.equal(result.headers["www-authenticate"], undefined);
    assert.equal(upstream.requests.length, index + 1);
  }
});

test("aborts successful responses reflecting either secret even when split between chunks", { timeout: 5000 }, async (t) => {
  const { broker, upstream } = await setup(t);
  for (const [index, secret] of [FIXTURE_KEY, broker.capability].entries()) {
    const local = send(broker);
    const stream = (await upstream.at(index)).respond(200, { "content-type": "text/event-stream" });
    const chunk = once(local.firstChunk, "data");
    stream.write("data: " + secret.slice(0, 8));
    assert.equal((await chunk)[0], "data: ");
    stream.end(secret.slice(8) + "\n\n");
    const result = await local.result;
    assert.equal(result.ended, false);
    assert.equal(result.text, "data: ");
  }
});

test("aborts an escaped JSON reflection of the configured API key", async (t) => {
  const key = 'test-escaped-"\\-credential';
  const { broker, upstream } = await setup(t, { baseURL: BASE, apiKey: key });
  const local = send(broker);
  const stream = (await upstream.at(0)).respond(200, { "content-type": "application/json" });
  stream.end(JSON.stringify({ text: key }));
  const reply = await local.result;
  assert.equal(reply.ended, false);
  assert.equal(reply.text, "");
});

test("bounds concurrent work and closes outstanding provider requests on stop", { timeout: 5000 }, async (t) => {
  const { broker, upstream } = await setup(t);
  const requests = Array.from({ length: 4 }, () => send(broker));
  await upstream.at(3);
  const overflow = await send(broker).result;
  assert.equal(overflow.status, 503);
  assert.equal(upstream.requests.length, 4);
  await Promise.all([broker.stop(), broker.stop()]);
  await Promise.all(requests.map(({ result }) => result));
  assert.ok(upstream.requests.every(({ options, destroyed }) => options.signal.aborted && destroyed));
  assert.equal((await send(broker).result).status, null);
});
