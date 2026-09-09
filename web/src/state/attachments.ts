// Encrypted attachments: files are encrypted locally, uploaded as opaque
// blobs and described (with the key) inside an end-to-end encrypted message.
import { http } from '../api/http';
import type { FilePayload } from '../api/types';
import { b64decode, b64encode } from '../crypto/bytes';
import { decryptFile, encryptFile } from '../crypto/files';
import { newUuid } from '../crypto/ids';
import { t } from '../i18n';
import { sendPayload } from './messaging';
import { pending, serverSettings } from './model';

const MAX_THUMB_EDGE = 320;
const MAX_THUMB_B64 = 40_000;

async function makeThumbnail(file: File): Promise<{ thumb?: string; width: number; height: number } | null> {
  if (!file.type.startsWith('image/')) return null;
  try {
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, MAX_THUMB_EDGE / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    const ctx = canvas.getContext('2d');
    if (!ctx) return { width: bitmap.width, height: bitmap.height };
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const dataUrl = canvas.toDataURL('image/jpeg', 0.6);
    const thumb = dataUrl.slice(dataUrl.indexOf(',') + 1);
    return { thumb: thumb.length <= MAX_THUMB_B64 ? thumb : undefined, width: bitmap.width, height: bitmap.height };
  } catch {
    return null;
  }
}

export function attachmentLimit(): number {
  return serverSettings.value?.max_attachment_bytes ?? 50 * 1024 * 1024;
}

/** Encrypts, uploads and announces a file in the conversation. */
export async function sendFile(convId: string, file: File): Promise<void> {
  const limit = attachmentLimit();
  if (limit <= 0) throw new Error(t('attachments_disabled'));
  if (file.size > limit) throw new Error(t('file_too_large', { mb: Math.floor(limit / 1048576) }));
  const tempId = newUuid();
  const meta = await makeThumbnail(file);
  const base: FilePayload = {
    t: 'file',
    blob: '',
    key: '',
    nonce: '',
    name: file.name || 'file',
    mime: file.type || 'application/octet-stream',
    size: file.size,
    thumb: meta?.thumb,
    width: meta?.width,
    height: meta?.height,
  };
  pending.value = [...pending.value, { clientMsgId: tempId, convId, payload: base, ts: Date.now(), uploading: true }];
  try {
    const data = new Uint8Array(await file.arrayBuffer());
    const { key, nonce, ciphertext } = encryptFile(data);
    const { id } = await http.uploadBlob(convId, ciphertext);
    pending.value = pending.value.filter((p) => p.clientMsgId !== tempId);
    await sendPayload(convId, { ...base, blob: id, key: b64encode(key), nonce: b64encode(nonce) });
  } catch (e) {
    const reason = e instanceof Error ? e.message : String(e);
    pending.value = pending.value.map((p) => (p.clientMsgId === tempId ? { ...p, uploading: false, failed: reason } : p));
    throw e;
  }
}

const urlCache = new Map<string, Promise<string>>();

/** Downloads and decrypts an attachment once, returning an object URL. */
export function fileUrl(p: FilePayload): Promise<string> {
  let cached = urlCache.get(p.blob);
  if (!cached) {
    cached = (async () => {
      const bytes = await http.downloadBlob(p.blob);
      const plain = decryptFile(b64decode(p.key), b64decode(p.nonce), bytes);
      const buffer = plain.buffer.slice(plain.byteOffset, plain.byteOffset + plain.byteLength) as ArrayBuffer;
      return URL.createObjectURL(new Blob([buffer], { type: p.mime || 'application/octet-stream' }));
    })();
    cached.catch(() => urlCache.delete(p.blob));
    urlCache.set(p.blob, cached);
  }
  return cached;
}

export async function downloadFile(p: FilePayload): Promise<void> {
  const url = await fileUrl(p);
  const a = document.createElement('a');
  a.href = url;
  a.download = p.name;
  document.body.appendChild(a);
  a.click();
  a.remove();
}

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(1)} MB`;
  return `${(bytes / 1073741824).toFixed(2)} GB`;
}
