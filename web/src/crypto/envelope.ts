// Message envelopes, PROTOCOL.md §5.
import { concat, randomBytes, utf8Encode } from './bytes';
import { bytesToUuid, uuidToBytes } from './ids';
import { aeadDecrypt, aeadEncrypt, KEY_SIZE, NONCE_SIZE, sign, TAG_SIZE, verify } from './primitives';
import { open, SEALED_KEY_SIZE, sealWith } from './seal';

export const VERSION = 1;
export const FLAG_EPHEMERAL = 1 << 0;
export const FLAG_URGENT = 1 << 1;
export const MAX_RECIPIENTS = 100;
export const MAX_ENVELOPE_SIZE = 64 * 1024;

const FIXED_HEADER = 1 + 1 + 4 * 16 + 8 + 2; // 76
const RECIPIENT_ENTRY = 16 + SEALED_KEY_SIZE; // 96
const MIN_ENVELOPE = FIXED_HEADER + RECIPIENT_ENTRY + NONCE_SIZE + 4 + TAG_SIZE;
const SIG_PREFIX = utf8Encode('msgr-env-v1');

export interface Header {
  flags: number;
  convId: string;
  senderAccount: string;
  senderDevice: string;
  clientMsgId: string;
  timestampMs: number;
}

export interface Recipient {
  account: string;
  encPub: Uint8Array;
}

export interface SealedRecipient {
  account: string;
  sealedKey: Uint8Array;
}

export interface ParsedEnvelope extends Header {
  recipients: SealedRecipient[];
  nonce: Uint8Array;
  ciphertext: Uint8Array;
  raw: Uint8Array;
  aadLen: number;
}

/** Every random input of encrypt(), injectable for the test vectors. */
export interface Randomness {
  key: Uint8Array;
  nonce: Uint8Array;
  ephemeral: Uint8Array[];
}

export function encryptWith(
  signSeed: Uint8Array,
  hdr: Header,
  recipients: Recipient[],
  plaintext: Uint8Array,
  r: Randomness,
): { env: Uint8Array; sig: Uint8Array } {
  const n = recipients.length;
  if (n < 1 || n > MAX_RECIPIENTS) throw new Error('invalid recipient count');
  if (r.ephemeral.length !== n) throw new Error('ephemeral key count mismatch');
  const size = FIXED_HEADER + n * RECIPIENT_ENTRY + NONCE_SIZE + 4 + plaintext.length + TAG_SIZE;
  if (size > MAX_ENVELOPE_SIZE) throw new Error('envelope too large');

  const buf = new Uint8Array(size);
  const view = new DataView(buf.buffer);
  let off = 0;
  buf[off++] = VERSION;
  buf[off++] = hdr.flags & 0xff;
  const convId = uuidToBytes(hdr.convId);
  buf.set(convId, off);
  off += 16;
  buf.set(uuidToBytes(hdr.senderAccount), off);
  off += 16;
  buf.set(uuidToBytes(hdr.senderDevice), off);
  off += 16;
  buf.set(uuidToBytes(hdr.clientMsgId), off);
  off += 16;
  view.setBigUint64(off, BigInt(Math.max(0, Math.floor(hdr.timestampMs))));
  off += 8;
  view.setUint16(off, n);
  off += 2;
  recipients.forEach((rc, i) => {
    const account = uuidToBytes(rc.account);
    buf.set(account, off);
    off += 16;
    buf.set(sealWith(r.ephemeral[i], rc.encPub, convId, account, r.key), off);
    off += SEALED_KEY_SIZE;
  });
  buf.set(r.nonce, off);
  off += NONCE_SIZE;
  const aad = buf.slice(0, off);
  view.setUint32(off, plaintext.length + TAG_SIZE);
  off += 4;
  buf.set(aeadEncrypt(r.key, r.nonce, aad, plaintext), off);
  return { env: buf, sig: sign(signSeed, concat(SIG_PREFIX, buf)) };
}

export function encrypt(signSeed: Uint8Array, hdr: Header, recipients: Recipient[], plaintext: Uint8Array) {
  return encryptWith(signSeed, hdr, recipients, plaintext, {
    key: randomBytes(KEY_SIZE),
    nonce: randomBytes(NONCE_SIZE),
    ephemeral: recipients.map(() => randomBytes(32)),
  });
}

export function verifyEnvelope(senderSignPub: Uint8Array, env: Uint8Array, sig: Uint8Array): boolean {
  return verify(senderSignPub, concat(SIG_PREFIX, env), sig);
}

/** Structural validation only; verify the signature separately. */
export function parse(env: Uint8Array): ParsedEnvelope {
  if (env.length > MAX_ENVELOPE_SIZE) throw new Error('envelope too large');
  if (env.length < MIN_ENVELOPE) throw new Error('malformed envelope');
  if (env[0] !== VERSION) throw new Error('unsupported envelope version');
  const view = new DataView(env.buffer, env.byteOffset, env.byteLength);
  const n = view.getUint16(74);
  if (n < 1 || n > MAX_RECIPIENTS) throw new Error('invalid recipient count');
  let off = FIXED_HEADER;
  if (env.length < off + n * RECIPIENT_ENTRY + NONCE_SIZE + 4 + TAG_SIZE) throw new Error('malformed envelope');
  const recipients: SealedRecipient[] = [];
  for (let i = 0; i < n; i++) {
    recipients.push({ account: bytesToUuid(env.subarray(off, off + 16)), sealedKey: env.subarray(off + 16, off + RECIPIENT_ENTRY) });
    off += RECIPIENT_ENTRY;
  }
  const nonce = env.subarray(off, off + NONCE_SIZE);
  off += NONCE_SIZE;
  const aadLen = off;
  const ctLen = view.getUint32(off);
  off += 4;
  if (ctLen < TAG_SIZE || env.length - off !== ctLen) throw new Error('malformed envelope');
  return {
    flags: env[1],
    convId: bytesToUuid(env.subarray(2, 18)),
    senderAccount: bytesToUuid(env.subarray(18, 34)),
    senderDevice: bytesToUuid(env.subarray(34, 50)),
    clientMsgId: bytesToUuid(env.subarray(50, 66)),
    timestampMs: Number(view.getBigUint64(66)),
    recipients,
    nonce,
    ciphertext: env.subarray(off),
    raw: env,
    aadLen,
  };
}

export function isRecipient(e: ParsedEnvelope, account: string): boolean {
  return e.recipients.some((r) => r.account === account);
}

/** Throws when the account is not a recipient or authentication fails. */
export function decrypt(e: ParsedEnvelope, account: string, encPriv: Uint8Array): Uint8Array {
  const rc = e.recipients.find((r) => r.account === account);
  if (!rc) throw new Error('not a recipient of this envelope');
  const key = open(encPriv, uuidToBytes(e.convId), uuidToBytes(account), rc.sealedKey);
  return aeadDecrypt(key, e.nonce, e.raw.subarray(0, e.aadLen), e.ciphertext);
}
