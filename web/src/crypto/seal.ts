// Sealed message keys, PROTOCOL.md §4.
import { concat, randomBytes } from './bytes';
import { aeadDecrypt, aeadEncrypt, hkdfSha256, KEY_SIZE, NONCE_SIZE, TAG_SIZE, x25519Public, x25519Shared } from './primitives';

export const SEALED_KEY_SIZE = 32 + KEY_SIZE + TAG_SIZE; // 80
const INFO = 'msgr-seal-v1';
const ZERO_NONCE = new Uint8Array(NONCE_SIZE);

function sealKey(ss: Uint8Array, ephPub: Uint8Array, recipientEncPub: Uint8Array): Uint8Array {
  return hkdfSha256(ss, concat(ephPub, recipientEncPub), INFO, KEY_SIZE);
}

/** Deterministic variant used by the shared test vectors. */
export function sealWith(
  ephPriv: Uint8Array,
  recipientEncPub: Uint8Array,
  convId: Uint8Array,
  recipientAccount: Uint8Array,
  key: Uint8Array,
): Uint8Array {
  const ephPub = x25519Public(ephPriv);
  const ss = x25519Shared(ephPriv, recipientEncPub);
  const k = sealKey(ss, ephPub, recipientEncPub);
  return concat(ephPub, aeadEncrypt(k, ZERO_NONCE, concat(convId, recipientAccount), key));
}

export function seal(recipientEncPub: Uint8Array, convId: Uint8Array, recipientAccount: Uint8Array, key: Uint8Array): Uint8Array {
  return sealWith(randomBytes(32), recipientEncPub, convId, recipientAccount, key);
}

/** Throws when the box is malformed or does not authenticate. */
export function open(encPriv: Uint8Array, convId: Uint8Array, recipientAccount: Uint8Array, box: Uint8Array): Uint8Array {
  if (box.length !== SEALED_KEY_SIZE) throw new Error('malformed sealed key');
  const ephPub = box.subarray(0, 32);
  const ss = x25519Shared(encPriv, ephPub);
  const k = sealKey(ss, ephPub, x25519Public(encPriv));
  return aeadDecrypt(k, ZERO_NONCE, concat(convId, recipientAccount), box.subarray(32));
}
