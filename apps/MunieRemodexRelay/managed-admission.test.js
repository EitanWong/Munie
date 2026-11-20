const assert = require("node:assert/strict");
const { createPublicKey, generateKeyPairSync, sign, verify } = require("node:crypto");
const test = require("node:test");
const { createManagedRelayAdmission, managedAdmissionTranscript, ISSUANCE_LIMIT_REACHED } = require("./managed-admission");

function device() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  return {
    key: publicKey.export({ format: "jwk" }).x,
    sign: (challenge) => sign(null, managedAdmissionTranscript(challenge), privateKey).toString("base64url"),
  };
}

function setup(options) {
  const mac = device();
  const phone = device();
  const admission = createManagedRelayAdmission({ audience: "fixture.invalid", allowedMacKeys: [mac.key], ...options });
  const issue = (role, selectedPhone = phone) => admission.issue({ role, macKey: mac.key, phoneKey: selectedPhone.key });
  const register = (selectedPhone = phone) => {
    const challenge = issue("mac", selectedPhone);
    return admission.admit(challenge.id, mac.sign(challenge));
  };
  return { mac, phone, admission, issue, register };
}

test("known Mac and the registered phone prove key possession before admission", () => {
  const { admission, mac, phone, issue, register } = setup();
  assert.equal(issue("phone"), null);
  const unknown = device();
  assert.equal(admission.issue({ role: "mac", macKey: unknown.key, phoneKey: phone.key }), null);

  const macChallenge = issue("mac");
  assert.equal(admission.admit(macChallenge.id, phone.sign(macChallenge)), null);
  assert.equal(admission.admit(macChallenge.id, mac.sign(macChallenge)), null);
  const registration = register();
  assert.ok(registration);
  assert.equal(issue("phone", unknown), null);

  const phoneChallenge = issue("phone");
  const signature = phone.sign(phoneChallenge);
  assert.equal(admission.admit(phoneChallenge.id, signature), registration);
  assert.equal(admission.admit(phoneChallenge.id, signature), null);
});

test("transcript binds service, role, pair, generation, nonce and server deadline", () => {
  const { admission, phone, issue, register } = setup();
  const registration = register();
  for (const override of [
    { audience: "other.invalid" }, { role: "mac" }, { macKey: device().key }, { phoneKey: device().key },
    { generation: "other" }, { id: "other" }, { expiresAt: 1 },
  ]) {
    const challenge = issue("phone");
    assert.equal(admission.admit(challenge.id, phone.sign({ ...challenge, ...override })), null);
  }
  const challenge = issue("phone");
  assert.equal(admission.admit(challenge.id, phone.sign(challenge)), registration);
});

test("replacing or revoking the generation invalidates outstanding proofs and stale cleanup", () => {
  const { admission, mac, phone, issue, register } = setup();
  const beforeFirstRegistration = issue("mac");
  const original = register();
  assert.equal(admission.isCurrent(original), true);
  const pendingPhone = issue("phone");
  const pendingMac = issue("mac");
  const replacementPhone = device();
  const replacement = register(replacementPhone);
  assert.notEqual(replacement, original);
  assert.equal(admission.isCurrent(original), false);
  assert.equal(admission.isCurrent(replacement), true);
  assert.equal(admission.admit(pendingPhone.id, phone.sign(pendingPhone)), null);
  assert.equal(admission.admit(pendingMac.id, mac.sign(pendingMac)), null);
  assert.equal(admission.deactivate(original), false);
  assert.equal(issue("phone"), null);
  const pendingReplacement = issue("phone", replacementPhone);
  assert.equal(admission.deactivate(replacement), true);
  assert.equal(admission.isCurrent(replacement), false);
  assert.equal(admission.admit(beforeFirstRegistration.id, mac.sign(beforeFirstRegistration)), null);
  assert.equal(admission.admit(pendingReplacement.id, replacementPhone.sign(pendingReplacement)), null);
  assert.equal(issue("phone", replacementPhone), null);
});

test("challenge count is bounded and expiration uses only the service clock", () => {
  let time = 1_000;
  const { admission, mac, issue } = setup({ capacity: 1, now: () => time });
  const expired = issue("mac");
  assert.equal(issue("mac"), null);
  time = expired.expiresAt;
  assert.equal(admission.admit(expired.id, mac.sign(expired)), null);
  const discarded = issue("mac");
  time = discarded.expiresAt;
  const current = issue("mac");
  assert.ok(current);
  assert.equal(admission.admit(discarded.id, mac.sign(discarded)), null);
  assert.ok(admission.admit(current.id, mac.sign(current)));
});

test("capacity denials do not debit a different Mac's issuance budgets", () => {
  const mac = device();
  const other = device();
  const phone = device();
  const admission = createManagedRelayAdmission({
    audience: "fixture.invalid", allowedMacKeys: [mac.key, other.key], capacity: 2, now: () => 1_000,
  });
  const issue = (role, identity = mac) => admission.issue({ role, macKey: identity.key, phoneKey: phone.key });
  const first = issue("mac");
  const registered = admission.admit(first.id, mac.sign(first));
  assert.ok(registered);
  const otherFirst = issue("mac", other);
  assert.ok(admission.admit(otherFirst.id, other.sign(otherFirst)));
  assert.ok(issue("phone"));
  assert.ok(issue("mac"));
  assert.equal(issue("mac", other), null);
  assert.equal(issue("phone", other), null);
  assert.equal(admission.deactivate(registered), true);
  for (const [role, remaining] of [["mac", 15], ["phone", 16]]) {
    for (let count = 0; count < remaining; count += 1) {
      const challenge = issue(role, other);
      assert.ok(challenge, `${role} slot ${count + 1} after capacity clears`);
      assert.equal(admission.admit(challenge.id, "invalid proof"), null);
    }
    assert.equal(issue(role, other), ISSUANCE_LIMIT_REACHED);
  }
});

test("each configured Mac has a separate budget per role and invalid requests do not debit it", () => {
  const macs = [device(), device()];
  const phone = device();
  const outsider = device();
  const admission = createManagedRelayAdmission({
    audience: "fixture.invalid", allowedMacKeys: macs.map((mac) => mac.key), now: () => 1_000,
  });
  for (const [index, mac] of macs.entries()) {
    const issue = (role, macKey = mac.key, phoneKey = phone.key) => admission.issue({ role, macKey, phoneKey });
    assert.equal(issue("phone"), null);
    assert.equal(issue("mac", outsider.key), null);
    assert.equal(issue("phone", outsider.key), null);
    assert.equal(issue("mac", mac.key, "not a key"), null);
    assert.equal(issue("invalid"), null);

    const first = issue("mac");
    assert.ok(first);
    assert.ok(admission.admit(first.id, mac.sign(first)));
    assert.equal(issue("phone", mac.key, "not a key"), null);
    assert.equal(issue("phone", mac.key, outsider.key), null);

    for (const [role, alreadyIssued] of [["mac", 1], ["phone", 0]]) {
      for (let count = alreadyIssued; count < 16; count += 1) {
        assert.ok(issue(role), `Mac ${index + 1}, ${role} slot ${count + 1}`);
      }
      assert.equal(issue(role), ISSUANCE_LIMIT_REACHED);
    }
  }
});

test("successful and failed proofs stay charged until their exact rolling-window boundary", () => {
  const start = 1_000;
  const later = start + 2_000;
  let time = start;
  const { admission, mac, phone, issue, register } = setup({ now: () => time });
  const registration = register();
  const first = issue("phone");
  assert.ok(first);
  assert.equal(admission.admit(first.id, phone.sign(first)), registration);

  time = later;
  const rejected = issue("phone");
  assert.ok(rejected);
  assert.equal(admission.admit(rejected.id, mac.sign(rejected)), null);
  for (let count = 2; count < 16; count += 1) assert.ok(issue("phone"));
  assert.equal(issue("phone"), ISSUANCE_LIMIT_REACHED);

  time = start + 14_999;
  assert.equal(issue("phone"), ISSUANCE_LIMIT_REACHED);
  time = start + 15_000;
  assert.ok(issue("phone"));
  assert.equal(issue("phone"), ISSUANCE_LIMIT_REACHED);

  time = later + 14_999;
  assert.equal(issue("phone"), ISSUANCE_LIMIT_REACHED);
  time = later + 15_000;
  for (let count = 0; count < 15; count += 1) assert.ok(issue("phone"));
  assert.equal(issue("phone"), ISSUANCE_LIMIT_REACHED);
});

test("replacement and deactivation do not reset either role's issuance budget", () => {
  const { admission, issue, register } = setup({ now: () => 1_000 });
  const original = register();
  assert.ok(original);
  // Leave the last two Mac slots for replacement and re-registration.
  for (let count = 1; count < 14; count += 1) assert.ok(issue("mac"));
  for (let count = 0; count < 16; count += 1) assert.ok(issue("phone"));
  assert.equal(issue("phone"), ISSUANCE_LIMIT_REACHED);

  const replacementPhone = device();
  const replacement = register(replacementPhone);
  assert.ok(replacement);
  assert.equal(admission.isCurrent(original), false);
  assert.equal(issue("phone", replacementPhone), ISSUANCE_LIMIT_REACHED);
  assert.equal(admission.deactivate(replacement), true);
  assert.ok(register(replacementPhone));
  assert.equal(issue("phone", replacementPhone), ISSUANCE_LIMIT_REACHED);
  assert.equal(issue("mac", replacementPhone), ISSUANCE_LIMIT_REACHED);
});

test("a prepared proof still requires a current and unexpired generation at commit", () => {
  let time = 1000;
  const { admission, mac, phone, issue, register } = setup({ now: () => time });
  const macChallenge = issue("mac");
  const preparedMac = admission.prepare(macChallenge.id, mac.sign(macChallenge), "mac");
  assert.ok(preparedMac);
  assert.equal(issue("phone"), null);
  time = macChallenge.expiresAt;
  assert.equal(preparedMac(), null);
  const original = register();
  const phoneChallenge = issue("phone");
  const preparedPhone = admission.prepare(phoneChallenge.id, phone.sign(phoneChallenge), "phone");
  assert.ok(preparedPhone);
  assert.equal(admission.deactivate(original), true);
  assert.equal(preparedPhone(), null);
  const replacement = register();
  const freshPhone = issue("phone");
  const preparedFresh = admission.prepare(freshPhone.id, phone.sign(freshPhone), "phone");
  assert.equal(preparedFresh(), replacement);
  assert.equal(preparedFresh(), null);
});

test("transcript and signature match the fixed UTF-8 interoperability vector", () => {
  // Phone key is RFC 8032 test vector 1; the expected signature was produced
  // against the literal wire bytes below, independently of the module encoder.
  const challenge = {
    audience: "fixture.invalid", role: "phone",
    macKey: "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE",
    phoneKey: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
    id: "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI",
    generation: "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM", expiresAt: 1_700_000_015_000,
  };
  const expected = '["munie-managed-relay-admission-v1","fixture.invalid","phone",'
    + '"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE","11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",'
    + '"AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI","AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM",1700000015000]';
  const encoded = managedAdmissionTranscript(challenge);
  assert.deepEqual(encoded, Buffer.from(expected, "utf8"));
  const key = createPublicKey({ format: "jwk", key: { kty: "OKP", crv: "Ed25519", x: challenge.phoneKey } });
  const proof = "msSyjjcp-fZARTs0JiQsRJF0yDDF3vxXbHvX0x7x_bg1lBih3CrK2ry4p2Inyhzm2murmscpUj5lSghCR-IXDw";
  assert.equal(verify(null, encoded, key, Buffer.from(proof, "base64url")), true);
});

test("noncanonical key encodings and malformed signatures fail closed", () => {
  const { mac, admission, issue } = setup();
  assert.throws(() => createManagedRelayAdmission({ audience: "fixture.invalid", allowedMacKeys: [`${mac.key}=`] }), TypeError);
  assert.equal(admission.issue({ role: "mac", macKey: mac.key, phoneKey: "not a key" }), null);
  const challenge = issue("mac");
  assert.equal(admission.admit(challenge.id, `${mac.sign(challenge)}=`), null);
  assert.equal(issue("phone"), null);
});
