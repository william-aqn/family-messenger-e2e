// Cross-language conformance: the same JSON vectors are checked by pkg/e2e
// (Go) and the Dart client. Regenerate them with
//   go test ./pkg/e2e -run TestVectors -update
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { bytesToHex, hexToBytes, utf8Encode } from '../src/crypto/bytes';
import { deriveKeys, generateKeys, keysFromSecrets, openKeyBundle, sealKeyBundle } from '../src/crypto/account';
import { decrypt, encrypt, encryptWith, FLAG_EPHEMERAL, parse, verifyEnvelope, type Header } from '../src/crypto/envelope';
import { fingerprint } from '../src/crypto/fingerprint';
import { bytesToUuid, newUuid } from '../src/crypto/ids';
import { sha256, sign, verify } from '../src/crypto/primitives';
import { open, sealWith } from '../src/crypto/seal';

function load<T>(name: string): T {
  const path = fileURLToPath(new URL(`../../protocol/testvectors/${name}`, import.meta.url));
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

const h = hexToBytes;

interface KdfVectors {
  params: { t: number; m: number; p: number };
  cases: { password: string; salt: string; auth_key: string; enc_key: string; auth_hash: string }[];
}

describe('kdf vectors', () => {
  const v = load<KdfVectors>('kdf.json');
  v.cases.forEach((c, i) => {
    it(`case ${i}`, async () => {
      const { authKey, encKey } = await deriveKeys(c.password, h(c.salt), v.params);
      expect(bytesToHex(authKey)).toBe(c.auth_key);
      expect(bytesToHex(encKey)).toBe(c.enc_key);
      expect(bytesToHex(sha256(authKey))).toBe(c.auth_hash);
    });
  });
});

interface KeysVectors {
  cases: {
    sign_seed: string;
    sign_pub: string;
    enc_priv: string;
    enc_pub: string;
    fingerprint: string;
    message: string;
    signature: string;
    bundle_enc_key: string;
    bundle_nonce: string;
    bundle: string;
  }[];
}

describe('keys vectors', () => {
  const v = load<KeysVectors>('keys.json');
  v.cases.forEach((c, i) => {
    it(`case ${i}`, () => {
      const keys = keysFromSecrets(h(c.sign_seed), h(c.enc_priv));
      expect(bytesToHex(keys.signPub)).toBe(c.sign_pub);
      expect(bytesToHex(keys.encPub)).toBe(c.enc_pub);
      expect(fingerprint(keys.signPub, keys.encPub)).toBe(c.fingerprint);
      expect(bytesToHex(sign(keys.signSeed, h(c.message)))).toBe(c.signature);
      expect(verify(keys.signPub, h(c.message), h(c.signature))).toBe(true);
      expect(bytesToHex(sealKeyBundle(h(c.bundle_enc_key), h(c.bundle_nonce), keys))).toBe(c.bundle);
      const opened = openKeyBundle(h(c.bundle_enc_key), h(c.bundle), keys.signPub, keys.encPub);
      expect(bytesToHex(opened.signSeed)).toBe(c.sign_seed);
      expect(bytesToHex(opened.encPriv)).toBe(c.enc_priv);
    });
  });
});

interface SealVectors {
  cases: {
    recipient_enc_priv: string;
    recipient_enc_pub: string;
    ephemeral_priv: string;
    conv_id: string;
    recipient_account: string;
    key: string;
    box: string;
  }[];
}

describe('seal vectors', () => {
  const v = load<SealVectors>('seal.json');
  v.cases.forEach((c, i) => {
    it(`case ${i}`, () => {
      const box = sealWith(h(c.ephemeral_priv), h(c.recipient_enc_pub), h(c.conv_id), h(c.recipient_account), h(c.key));
      expect(bytesToHex(box)).toBe(c.box);
      expect(bytesToHex(open(h(c.recipient_enc_priv), h(c.conv_id), h(c.recipient_account), h(c.box)))).toBe(c.key);
      expect(() => open(h(c.recipient_enc_priv), h(c.recipient_account), h(c.conv_id), h(c.box))).toThrow();
    });
  });
});

interface EnvVectors {
  cases: {
    name: string;
    sender_sign_seed: string;
    sender_sign_pub: string;
    flags: number;
    conv_id: string;
    sender_account: string;
    sender_device: string;
    client_msg_id: string;
    ts_ms: number;
    recipients: { account: string; enc_priv: string; enc_pub: string; ephemeral_priv: string }[];
    message_key: string;
    nonce: string;
    plaintext: string;
    envelope: string;
    signature: string;
  }[];
}

describe('envelope vectors', () => {
  const v = load<EnvVectors>('envelope.json');
  for (const c of v.cases) {
    it(c.name, () => {
      const hdr: Header = {
        flags: c.flags,
        convId: bytesToUuid(h(c.conv_id)),
        senderAccount: bytesToUuid(h(c.sender_account)),
        senderDevice: bytesToUuid(h(c.sender_device)),
        clientMsgId: bytesToUuid(h(c.client_msg_id)),
        timestampMs: c.ts_ms,
      };
      const recipients = c.recipients.map((r) => ({ account: bytesToUuid(h(r.account)), encPub: h(r.enc_pub) }));
      const { env, sig } = encryptWith(h(c.sender_sign_seed), hdr, recipients, h(c.plaintext), {
        key: h(c.message_key),
        nonce: h(c.nonce),
        ephemeral: c.recipients.map((r) => h(r.ephemeral_priv)),
      });
      expect(bytesToHex(env)).toBe(c.envelope);
      expect(bytesToHex(sig)).toBe(c.signature);
      expect(verifyEnvelope(h(c.sender_sign_pub), h(c.envelope), h(c.signature))).toBe(true);
      const parsed = parse(h(c.envelope));
      expect(parsed.flags).toBe(c.flags);
      expect(parsed.convId).toBe(hdr.convId);
      expect(parsed.senderAccount).toBe(hdr.senderAccount);
      expect(parsed.clientMsgId).toBe(hdr.clientMsgId);
      expect(parsed.timestampMs).toBe(c.ts_ms);
      for (const r of c.recipients) {
        expect(bytesToHex(decrypt(parsed, bytesToUuid(h(r.account)), h(r.enc_priv)))).toBe(c.plaintext);
      }
    });
  }
});

describe('round trips', () => {
  it('encrypts, parses, verifies and decrypts for every recipient', () => {
    const alice = generateKeys();
    const bob = generateKeys();
    const ids = { alice: newUuid(), bob: newUuid() };
    const hdr: Header = {
      flags: FLAG_EPHEMERAL,
      convId: newUuid(),
      senderAccount: ids.alice,
      senderDevice: newUuid(),
      clientMsgId: newUuid(),
      timestampMs: Date.now(),
    };
    const pt = utf8Encode('{"t":"text","body":"привет"}');
    const { env, sig } = encrypt(alice.signSeed, hdr, [{ account: ids.alice, encPub: alice.encPub }, { account: ids.bob, encPub: bob.encPub }], pt);
    expect(verifyEnvelope(alice.signPub, env, sig)).toBe(true);
    expect(verifyEnvelope(bob.signPub, env, sig)).toBe(false);
    const parsed = parse(env);
    expect(parsed.senderAccount).toBe(ids.alice);
    expect(bytesToHex(decrypt(parsed, ids.bob, bob.encPriv))).toBe(bytesToHex(pt));
    expect(bytesToHex(decrypt(parsed, ids.alice, alice.encPriv))).toBe(bytesToHex(pt));
    expect(() => decrypt(parsed, ids.bob, alice.encPriv)).toThrow();
    expect(() => decrypt(parsed, newUuid(), bob.encPriv)).toThrow();
    const tampered = env.slice();
    tampered[tampered.length - 1] ^= 1;
    expect(verifyEnvelope(alice.signPub, tampered, sig)).toBe(false);
    expect(() => decrypt(parse(tampered), ids.bob, bob.encPriv)).toThrow();
  });
});
