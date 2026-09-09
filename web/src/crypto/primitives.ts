// Thin wrappers over the audited @noble libraries and hash-wasm so that the
// protocol code reads like PROTOCOL.md. Every function here has an exact
// counterpart in pkg/e2e (Go) and the Dart client.
import { ed25519, x25519 } from '@noble/curves/ed25519.js';
import { xchacha20poly1305 } from '@noble/ciphers/chacha.js';
import { hkdf } from '@noble/hashes/hkdf.js';
import { sha256 } from '@noble/hashes/sha2.js';
import { argon2id } from 'hash-wasm';
import { utf8Encode } from './bytes';

export const NONCE_SIZE = 24;
export const TAG_SIZE = 16;
export const KEY_SIZE = 32;

export { sha256 };

export function ed25519Public(seed: Uint8Array): Uint8Array {
  return ed25519.getPublicKey(seed);
}

export function sign(seed: Uint8Array, message: Uint8Array): Uint8Array {
  return ed25519.sign(message, seed);
}

export function verify(publicKey: Uint8Array, message: Uint8Array, signature: Uint8Array): boolean {
  if (signature.length !== 64 || publicKey.length !== 32) return false;
  try {
    return ed25519.verify(signature, message, publicKey);
  } catch {
    return false;
  }
}

export function x25519Public(priv: Uint8Array): Uint8Array {
  return x25519.getPublicKey(priv);
}

/** X25519 shared secret; rejects low-order public keys like Go's crypto/ecdh. */
export function x25519Shared(priv: Uint8Array, pub: Uint8Array): Uint8Array {
  const ss = x25519.getSharedSecret(priv, pub);
  let acc = 0;
  for (const b of ss) acc |= b;
  if (acc === 0) throw new Error('invalid public key (low order point)');
  return ss;
}

export function aeadEncrypt(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array, plaintext: Uint8Array): Uint8Array {
  return xchacha20poly1305(key, nonce, aad).encrypt(plaintext);
}

/** Throws on authentication failure. */
export function aeadDecrypt(key: Uint8Array, nonce: Uint8Array, aad: Uint8Array, ciphertext: Uint8Array): Uint8Array {
  return xchacha20poly1305(key, nonce, aad).decrypt(ciphertext);
}

export function hkdfSha256(ikm: Uint8Array, salt: Uint8Array, info: string, length: number): Uint8Array {
  return hkdf(sha256, ikm, salt, utf8Encode(info), length);
}

export interface KdfParams {
  t: number; // iterations
  m: number; // memory in KiB
  p: number; // parallelism
}

export async function argon2idHash(password: string, salt: Uint8Array, params: KdfParams, length: number): Promise<Uint8Array> {
  return argon2id({
    password: utf8Encode(password), // bytes: hash-wasm rejects the empty string
    salt,
    iterations: params.t,
    memorySize: params.m,
    parallelism: params.p,
    hashLength: length,
    outputType: 'binary',
  });
}
