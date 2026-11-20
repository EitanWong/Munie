// Simulator-only interoperability fixture using the signed Mac backend.
const { generateKeyPairSync, randomUUID } = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');

const base64 = (key) => Buffer.from(key, 'base64url').toString('base64');

async function main() {
  const [resources, readyPath] = process.argv.slice(2);
  if (fs.readFileSync(path.join(resources, 'Runtime/codex-resources/munie-stdio-policy'), 'utf8') !== '1\n') {
    throw new Error('A signed bundle with the pinned preview policy is required');
  }
  const { createDesktopHost } = require(path.join(resources, 'Host/MunieRemodexBridge/src/desktop-host.js'));
  const { startManagedRelayPilot } = require(path.join(resources, 'Host/MunieRemodexRelay/managed-relay-pilot.js'));
  const temp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'munie-packed-phone-')));
  let host, relay, shutdown, published = false, stopRequested = false;
  const close = () => shutdown ??= (async () => {
    try {
      if (host && !(await host.run('stop')).cleanupConfirmed) throw new Error('Runtime cleanup unconfirmed');
    } finally {
      if (relay) await relay.close();
    }
    fs.rmSync(temp, { recursive: true, force: true });
    console.log('Signed preview stopped and disposable state removed.');
  })();
  process.once('SIGTERM', () => {
    stopRequested = true;
    if (published) void close().catch((error) => { console.error(error.message); process.exitCode = 1; });
  });
  const requireStarting = () => {
    if (stopRequested) throw new Error('Signed preview startup cancelled');
  };
  try {
    const home = path.join(temp, 'codex'), project = path.join(temp, 'project'), state = path.join(temp, 'state');
    fs.mkdirSync(home, { mode: 0o700 });
    fs.mkdirSync(project, { mode: 0o700 });
    fs.writeFileSync(path.join(home, 'config.toml'),
      'cli_auth_credentials_store="file"\nanalytics.enabled=false\nfeedback.enabled=false\n'
      + 'model_provider="munie_fixture"\n[model_providers.munie_fixture]\n'
      + 'name="Disposable preview"\nbase_url="http://127.0.0.1:9/v1"\nwire_api="responses"\n');
    const mac = generateKeyPairSync('ed25519'), phone = generateKeyPairSync('ed25519');
    const macDeviceId = randomUUID(), phoneDeviceId = randomUUID();
    const macKey = mac.publicKey.export({ format: 'jwk' }).x, phoneKey = phone.publicKey.export({ format: 'jwk' }).x;
    relay = await startManagedRelayPilot({ audience: 'munie-loopback.invalid', allowedMacKeys: [macKey] });
    requireStarting();
    host = createDesktopHost({ env: {
      CODEX_HOME: home, MUNIE_HOST_STATE_DIR: state, MUNIE_DEVELOPER_MANAGED_RELAY: relay.origin,
      MUNIE_CODEX_BINARY: path.join(resources, 'Runtime/bin/codex'),
      MUNIE_GUARDIAN_BINARY: path.join(resources, 'Runtime/bin/MunieCodexGuardian'),
    } });
    fs.writeFileSync(path.join(state, 'bridge', 'device-state.json'), JSON.stringify({
      version: 1, macDeviceId, macIdentityPublicKey: base64(macKey),
      macIdentityPrivateKey: base64(mac.privateKey.export({ format: 'jwk' }).d),
      trustedPhones: { [phoneDeviceId]: base64(phoneKey) },
    }), { mode: 0o600 });
    await host.run('project/set', { path: project });
    const started = await host.run('start');
    requireStarting();
    if (started.state !== 'running') throw new Error('Signed preview did not start');

    const closedLAN = net.createServer();
    await new Promise((resolve, reject) => {
      closedLAN.once('error', reject);
      closedLAN.listen(0, '127.0.0.1', resolve);
    });
    const lanURL = `ws://127.0.0.1:${closedLAN.address().port}/relay`;
    await new Promise((resolve, reject) => closedLAN.close((error) => error ? reject(error) : resolve()));
    for (let retry = 0; retry < 50; retry++) {
      requireStarting();
      const check = await fetch(`${relay.origin}/v1/managed/challenge`, {
        method: 'POST', body: JSON.stringify({ role: 'phone', macKey, phoneKey }),
        signal: AbortSignal.timeout(1000),
      });
      await check.body.cancel();
      requireStarting();
      if (check.ok) {
        fs.writeFileSync(`${readyPath}.new`, JSON.stringify({
          origin: relay.origin, lanURL, macDeviceId, macIdentityPublicKey: base64(macKey),
          phoneDeviceId, phoneIdentityPublicKey: base64(phoneKey),
          phoneIdentityPrivateKey: base64(phone.privateKey.export({ format: 'jwk' }).d),
          authorizedProject: project,
        }), { mode: 0o600 });
        fs.renameSync(`${readyPath}.new`, readyPath);
        published = true;
        console.log('Signed preview ready for the simulator fixture.');
        return;
      }
      await delay(60);
    }
    throw new Error('Signed preview did not register with the loopback relay');
  } catch (error) {
    await close();
    throw error;
  }
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
