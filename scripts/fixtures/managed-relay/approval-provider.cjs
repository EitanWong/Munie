// Disposable loopback Responses fixture. No real credentials or model calls.
const { execFileSync } = require('node:child_process');
const { randomBytes, X509Certificate } = require('node:crypto');
const fs = require('node:fs');
const https = require('node:https');
const path = require('node:path');

const PROMPT = 'Munie signed simulator stop probe';
const COMMAND = '/bin/sh managed-stop.sh';
const MAX_REQUEST = 256 * 1024;

function createTLS(directory) {
  const working = fs.mkdtempSync(path.join(directory, 'approval-tls-'));
  const write = (name, contents) => fs.writeFileSync(path.join(working, name), contents, { mode: 0o600, flag: 'wx' });
  const read = (name) => fs.readFileSync(path.join(working, name));
  const openssl = (...args) => execFileSync('/usr/bin/openssl', args, {
    cwd: working, env: { OPENSSL_CONF: '/dev/null' }, stdio: 'ignore', timeout: 5000,
  });
  try {
    write('ca.cnf', '[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ca\n'
      + '[dn]\nCN=Munie Simulator Approval Root\n[ca]\n'
      + 'basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign\nsubjectKeyIdentifier=hash\n');
    write('server.cnf', '[req]\nprompt=no\ndistinguished_name=dn\n[dn]\nCN=Munie Simulator Approval Server\n'
      + '[leaf]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n'
      + 'extendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n');
    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-sha256',
      '-config', 'ca.cnf', '-keyout', 'ca.key', '-out', 'ca.pem');
    openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-config', 'server.cnf', '-keyout', 'server.key', '-out', 'server.csr');
    openssl('x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
      '-set_serial', '0x' + randomBytes(16).toString('hex'), '-days', '1', '-sha256',
      '-extfile', 'server.cnf', '-extensions', 'leaf', '-out', 'server.pem');
    openssl('verify', '-CAfile', 'ca.pem', '-purpose', 'sslserver', 'server.pem');
    const key = read('server.key'), cert = read('server.pem');
    if (new X509Certificate(cert).checkIP('127.0.0.1') !== '127.0.0.1') throw new Error('Approval TLS certificate is not for loopback');
    fs.writeFileSync(path.join(directory, 'approval-provider-ca.pem'), read('ca.pem'), { mode: 0o600, flag: 'wx' });
    return { key, cert, minVersion: 'TLSv1.3', maxVersion: 'TLSv1.3', ALPNProtocols: ['http/1.1'], handshakeTimeout: 2000 };
  } finally {
    fs.rmSync(working, { recursive: true });
  }
}

async function startApprovalProvider(directory, project) {
  let requests = 0;
  let accepted = 0;
  const server = https.createServer({ ...createTLS(directory), headersTimeout: 2000, requestTimeout: 3000 }, async (request, response) => {
    requests++;
    try {
      const size = Number(request.headers['content-length']);
      if (requests !== 1 || request.method !== 'POST' || request.url !== '/v1/responses'
          || request.headers.host !== '127.0.0.1:' + server.address().port
          || request.headers.authorization != null || request.headers.cookie != null
          || request.headers['transfer-encoding'] != null
          || !Number.isSafeInteger(size) || size <= 0 || size > MAX_REQUEST) {
        throw new Error('Unexpected Responses request');
      }
      let total = 0;
      const chunks = [];
      for await (const chunk of request) {
        total += chunk.length;
        if (total > size) throw new Error('Responses request size exceeded');
        chunks.push(chunk);
      }
      const body = JSON.parse(Buffer.concat(chunks));
      const prompts = body.input?.filter((item) => item.type === 'message' && item.role === 'user')
        .flatMap((item) => item.content?.filter((part) => part.type === 'input_text').map((part) => part.text) ?? []);
      if (total !== size || body.model !== 'munie-fixture' || body.stream !== true
          || !body.tools?.some((tool) => tool.name === 'exec_command')
          || prompts?.filter((prompt) => prompt === PROMPT).length !== 1) {
        throw new Error('Unexpected Responses fixture input');
      }
      const id = 'resp_managed_stop_probe';
      const item = {
        type: 'function_call', id: 'fc_managed_stop_probe', call_id: 'call_managed_stop_probe', name: 'exec_command',
        arguments: JSON.stringify({ cmd: COMMAND, shell: '/bin/sh', login: false, workdir: project,
          yield_time_ms: 10_000, max_output_tokens: 1000 }),
      };
      // Same finite Responses SSE sequence as scripts/probe-codex-turns.py.
      const events = [
        { type: 'response.created', response: { id } },
        { type: 'response.output_item.done', output_index: 0, item },
        { type: 'response.completed', response: { id, status: 'completed', output: [item],
          usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } },
      ];
      const data = events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join('');
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Content-Length': Buffer.byteLength(data) });
      response.end(data);
      accepted++;
    } catch {
      response.writeHead(400, { Connection: 'close' });
      response.end();
    }
  });
  server.setTimeout(3000, (socket) => socket.destroy());
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    port: server.address().port,
    async close({ verifySubmission }) {
      await new Promise((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
        server.closeAllConnections();
      });
      if (verifySubmission && (requests !== 1 || accepted !== 1)) {
        throw new Error(`Expected one synthetic provider submission; received ${requests}, accepted ${accepted}`);
      }
    },
  };
}

module.exports = { startApprovalProvider };
