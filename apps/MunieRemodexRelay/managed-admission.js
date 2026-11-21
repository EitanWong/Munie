const { createPublicKey, randomBytes, verify } = require("node:crypto");
const { performance } = require("node:perf_hooks");

const ISSUANCE_WINDOW_MS = 15_000;
const MAX_ISSUED_PER_ROLE = 16;
const ISSUANCE_LIMIT_REACHED = Symbol("Managed relay challenge issuance limit reached");

// Reconnect-only pilot core. A caller must bind admitted generations to its live
// sockets; the LAN relay does not use this module.
function createManagedRelayAdmission({
  audience,
  allowedMacKeys,
  now = () => Math.trunc(performance.timeOrigin + performance.now()),
  capacity = 256,
} = {}) {
  if (typeof audience !== "string" || !/^[a-z0-9.-]{1,253}$/.test(audience)
      || !Array.isArray(allowedMacKeys) || allowedMacKeys.some((key) => !decode(key, 32))
      || !Number.isSafeInteger(capacity) || capacity < 1) {
    throw new TypeError("Invalid managed relay admission configuration");
  }
  const devices = new Map(allowedMacKeys.map((key) => [key, { registration: null }]));
  const challenges = new Map();
  // Budgets outlive registration generations and are only allocated for configured Macs.
  const issuances = new Map([...devices.keys()].map((key) => [key, { mac: [], phone: [] }]));

  function issue({ role, macKey, phoneKey }) {
    const state = devices.get(macKey);
    if (!state || !decode(phoneKey, 32) || !["mac", "phone"].includes(role)) {
      return null;
    }
    const { registration } = state;
    if (role === "phone" && registration?.phoneKey !== phoneKey) return null;

    const time = now();
    const recent = issuances.get(macKey)[role];
    while (recent.length && recent[0] <= time - ISSUANCE_WINDOW_MS) recent.shift();
    if (recent.length >= MAX_ISSUED_PER_ROLE) return ISSUANCE_LIMIT_REACHED;

    for (const [id, previous] of challenges) {
      if (previous.challenge.expiresAt <= time || devices.get(previous.challenge.macKey) !== previous.state) {
        challenges.delete(id);
      }
    }
    if (challenges.size >= capacity) return null;

    const id = randomBytes(32).toString("base64url");
    const challenge = Object.freeze({
      audience, role, macKey, phoneKey, id,
      generation: registration?.generation ?? "",
      expiresAt: time + 15_000,
    });
    challenges.set(id, { challenge, state });
    recent.push(time);
    return challenge;
  }

  function prepare(id, proof, expectedRole) {
    const pending = challenges.get(id);
    if (!pending) return null;
    challenges.delete(id);
    const { challenge, state } = pending;
    const { expiresAt, role, macKey, phoneKey } = challenge;
    if ((expectedRole !== undefined && role !== expectedRole)
        || expiresAt <= now() || devices.get(macKey) !== state) return null;
    const signature = decode(proof, 64);
    if (!signature || !validSignature(challenge, signature)) return null;

    let consumed = false;
    return () => {
      if (consumed) return null;
      consumed = true;
      if (expiresAt <= now() || devices.get(macKey) !== state) return null;
      if (role === "phone") return state.registration;
      const admitted = Object.freeze({ macKey, phoneKey, generation: id });
      devices.set(macKey, { registration: admitted });
      return admitted;
    };
  }

  function admit(id, proof) {
    return prepare(id, proof)?.() ?? null;
  }

  function isCurrent(registration) {
    return Boolean(registration && devices.get(registration.macKey)?.registration === registration);
  }

  function deactivate(registration) {
    if (!isCurrent(registration)) return false;
    devices.set(registration.macKey, { registration: null });
    return true;
  }

  return { issue, prepare, admit, isCurrent, deactivate };
}

function managedAdmissionTranscript(challenge) {
  return Buffer.from(JSON.stringify([
    "munie-managed-relay-admission-v1", challenge.audience, challenge.role,
    challenge.macKey, challenge.phoneKey, challenge.id, challenge.generation, challenge.expiresAt,
  ]), "utf8");
}

function validSignature(challenge, signature) {
  try {
    const key = createPublicKey({ format: "jwk", key: {
      kty: "OKP", crv: "Ed25519", x: challenge.role === "mac" ? challenge.macKey : challenge.phoneKey,
    } });
    return verify(null, managedAdmissionTranscript(challenge), key, signature);
  } catch {
    return false;
  }
}

function decode(value, length) {
  if (typeof value !== "string" || value.length !== Math.ceil(length * 4 / 3)) return null;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length === length && bytes.toString("base64url") === value ? bytes : null;
}

module.exports = { createManagedRelayAdmission, managedAdmissionTranscript, ISSUANCE_LIMIT_REACHED };
