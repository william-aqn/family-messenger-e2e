// Account keys, password-derived keys and the encrypted key bundle,
// PROTOCOL.md §3.
import { concat, equal, randomBytes, utf8Encode } from './bytes';
import { aeadDecrypt, aeadEncrypt, argon2idHash, ed25519Public, type KdfParams, NONCE_SIZE, TAG_SIZE, x25519Public } from './primitives';

export interface AccountKeys {
  signSeed: Uint8Array;
  signPub: Uint8Array;
  encPriv: Uint8Array;
  encPub: Uint8Array;
}

export const SALT_SIZE = 16;
export const KEY_BUNDLE_SIZE = NONCE_SIZE + 64 + TAG_SIZE; // 104
export const DEFAULT_KDF: KdfParams = { t: 3, m: 64 * 1024, p: 1 };
const BUNDLE_AAD = utf8Encode('msgr-keybundle-v1');

export function keysFromSecrets(signSeed: Uint8Array, encPriv: Uint8Array): AccountKeys {
  if (signSeed.length !== 32 || encPriv.length !== 32) throw new Error('secrets must be 32 bytes');
  return { signSeed, signPub: ed25519Public(signSeed), encPriv, encPub: x25519Public(encPriv) };
}

export function generateKeys(): AccountKeys {
  return keysFromSecrets(randomBytes(32), randomBytes(32));
}

/** Argon2id over the password: authKey goes to the server, encKey stays local. */
export async function deriveKeys(
  password: string,
  salt: Uint8Array,
  params: KdfParams = DEFAULT_KDF,
): Promise<{ authKey: Uint8Array; encKey: Uint8Array }> {
  const out = await argon2idHash(password, salt, params, 64);
  return { authKey: out.slice(0, 32), encKey: out.slice(32, 64) };
}

export function sealKeyBundle(encKey: Uint8Array, nonce: Uint8Array, keys: AccountKeys): Uint8Array {
  return concat(nonce, aeadEncrypt(encKey, nonce, BUNDLE_AAD, concat(keys.signSeed, keys.encPriv)));
}

export function newKeyBundle(encKey: Uint8Array, keys: AccountKeys): Uint8Array {
  return sealKeyBundle(encKey, randomBytes(NONCE_SIZE), keys);
}

/** Throws when the bundle cannot be opened or does not match the public keys. */
export function openKeyBundle(encKey: Uint8Array, bundle: Uint8Array, signPub: Uint8Array, encPub: Uint8Array): AccountKeys {
  if (bundle.length !== KEY_BUNDLE_SIZE) throw new Error('malformed key bundle');
  const secrets = aeadDecrypt(encKey, bundle.subarray(0, NONCE_SIZE), BUNDLE_AAD, bundle.subarray(NONCE_SIZE));
  const keys = keysFromSecrets(secrets.slice(0, 32), secrets.slice(32, 64));
  if (!equal(keys.signPub, signPub) || !equal(keys.encPub, encPub)) throw new Error('key bundle does not match the public keys');
  return keys;
}
