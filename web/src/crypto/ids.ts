import { bytesToHex, hexToBytes } from './bytes';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Parses a canonical UUID string into its 16 bytes. */
export function uuidToBytes(id: string): Uint8Array {
  const s = id.toLowerCase();
  if (!UUID_RE.test(s)) throw new Error(`invalid uuid: ${id}`);
  return hexToBytes(s.replace(/-/g, ''));
}

export function bytesToUuid(b: Uint8Array): string {
  if (b.length !== 16) throw new Error('uuid must be 16 bytes');
  const h = bytesToHex(b);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export function isUuid(s: string): boolean {
  return UUID_RE.test(s.toLowerCase());
}

export function newUuid(): string {
  return crypto.randomUUID();
}
