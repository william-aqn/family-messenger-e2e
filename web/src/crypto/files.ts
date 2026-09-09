// Attachment encryption (PROTOCOL.md §6, payload "file"): the file is
// encrypted with a fresh random key and nonce, uploaded as an opaque blob,
// and the key travels inside the end-to-end encrypted message.
import { randomBytes, utf8Encode } from './bytes';
import { aeadDecrypt, aeadEncrypt, KEY_SIZE, NONCE_SIZE } from './primitives';

export const BLOB_AAD = utf8Encode('msgr-blob-v1');

export interface EncryptedFile {
  key: Uint8Array;
  nonce: Uint8Array;
  ciphertext: Uint8Array;
}

export function encryptFile(data: Uint8Array): EncryptedFile {
  const key = randomBytes(KEY_SIZE);
  const nonce = randomBytes(NONCE_SIZE);
  return { key, nonce, ciphertext: aeadEncrypt(key, nonce, BLOB_AAD, data) };
}

/** Throws when the key does not open the blob. */
export function decryptFile(key: Uint8Array, nonce: Uint8Array, ciphertext: Uint8Array): Uint8Array {
  return aeadDecrypt(key, nonce, BLOB_AAD, ciphertext);
}
