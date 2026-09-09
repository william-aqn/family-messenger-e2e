import { bytesToHex, concat, utf8Encode } from './bytes';
import { sha256 } from './primitives';

/** Safety number of an account, PROTOCOL.md §3.3: 8 groups of 4 hex chars. */
export function fingerprint(signPub: Uint8Array, encPub: Uint8Array): string {
  const h = sha256(concat(utf8Encode('msgr-fp-v1'), signPub, encPub));
  const hex = bytesToHex(h.subarray(0, 16));
  const groups: string[] = [];
  for (let i = 0; i < hex.length; i += 4) groups.push(hex.slice(i, i + 4));
  return groups.join(' ');
}
