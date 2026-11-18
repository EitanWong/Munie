// Local protocol fixture only. It does not open a Codex account or start an app-server.
const { generateKeyPairSync, randomUUID } = require('node:crypto');
const { writeFileSync, renameSync } = require('node:fs');
const path = require('node:path');

async function main() {
  const [macTree, readyPath] = process.argv.slice(2);
  const fromMac = (file) => require(path.resolve(macTree, 'apps', file));
  const { startManagedRelayPilot } = fromMac('MunieRemodexRelay/managed-relay-pilot.js');
  const { managedAdmissionTranscript } = fromMac('MunieRemodexRelay/managed-admission.js');
  const { createManagedRelayClient } = fromMac('MunieRemodexBridge/src/managed-relay-client.js');
  const { createBridgeSecureTransport } = fromMac('MunieRemodexBridge/src/secure-transport.js');
  const base64 = (key) => Buffer.from(key, 'base64url').toString('base64');
  const mac = generateKeyPairSync('ed25519');
  const phone = generateKeyPairSync('ed25519');
  const macKey = mac.publicKey.export({ format: 'jwk' }).x;
  const phoneKey = phone.publicKey.export({ format: 'jwk' }).x;
  const macDeviceId = randomUUID(), phoneDeviceId = randomUUID(), sessionId = randomUUID();
  const audience = 'munie-loopback.invalid';
  const relay = await startManagedRelayPilot({ audience, allowedMacKeys: [macKey] });
  const state = {
    version: 1, macDeviceId, macIdentityPublicKey: base64(macKey),
    macIdentityPrivateKey: base64(mac.privateKey.export({ format: 'jwk' }).d),
    trustedPhones: { [phoneDeviceId]: base64(phoneKey) },
  };
  const secure = createBridgeSecureTransport({
    sessionId, relayUrl: relay.origin, deviceState: state, persistTrustedPhone: false,
  });
  let attached = 0;
  const client = createManagedRelayClient({
    origin: relay.origin, audience, encodeChallenge: managedAdmissionTranscript, sessionId,
    attachPhone(_, route) {
      const number = ++attached;
      secure.bindLiveSendWireMessage(route.send);
      return {
        receive(text) {
          return secure.handleIncomingWireMessage(text, {
            sendControlMessage: (message) => route.send(JSON.stringify(message)),
            onApplicationMessage: (payload) => {
              const request = JSON.parse(payload);
              if (request.method === 'initialized') {
                console.log(`initialized route=${number}`);
              }
              if (request.id == null) return;
              if (request.method === 'initialize') {
                route.send(JSON.stringify({id: request.id, result: {remodexRuntimeSettingsVersion: 999}}));
                console.log(`initialize route=${number} plaintext predecessor sent`);
                secure.sendUnbufferedApplicationMessage(JSON.stringify({
                  id: request.id, result: {remodexRuntimeSettingsVersion: 2},
                }));
                return;
              }
              secure.sendUnbufferedApplicationMessage(JSON.stringify({id: request.id, result: {}}));
            },
          });
        },
        detach() { secure.invalidateMobileRoute(); },
      };
    },
  });
  const stop = async () => { client.stop(); await relay.close(); };
  process.once('SIGTERM', () => void stop());
  client.replaceTrust(state);
  const deadline = Date.now() + 4000;
  while (Date.now() < deadline) {
    const response = await fetch(`${relay.origin}/v1/managed/challenge`, {
      method: 'POST', body: JSON.stringify({ role: 'phone', macKey, phoneKey }),
      signal: AbortSignal.timeout(1000),
    });
    await response.body.cancel();
    if (response.ok) {
      writeFileSync(`${readyPath}.new`, JSON.stringify({
        origin: relay.origin, macDeviceId, macIdentityPublicKey: base64(macKey), phoneDeviceId,
        phoneIdentityPublicKey: base64(phoneKey),
        phoneIdentityPrivateKey: base64(phone.privateKey.export({ format: 'jwk' }).d),
      }), {mode: 0o600});
      renameSync(`${readyPath}.new`, readyPath);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  await stop();
  throw new Error('Mac pilot did not register');
}

main().catch((error) => { console.error(error); process.exit(1); });
