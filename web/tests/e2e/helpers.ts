import { deflateSync } from 'node:zlib';
import { expect, type Browser, type Page } from '@playwright/test';

export const run = Date.now().toString(36);
export const password = (name: string) => `${name}-password-${run}`;

export async function register(browser: Browser, name: string): Promise<Page> {
  const ctx = await browser.newContext({ permissions: ['microphone'], locale: 'en-US' });
  const page = await ctx.newPage();
  await page.goto('/');
  await page.getByRole('button', { name: 'Create account' }).first().click();
  await page.getByLabel('Username').fill(name);
  await page.getByLabel('Password').fill(password(name));
  await page.getByRole('button', { name: 'Create account' }).last().click();
  await expect(page.getByText(`@${name}`)).toBeVisible({ timeout: 60_000 });
  return page;
}

export async function openDirect(page: Page, peer: string): Promise<void> {
  await page.getByTitle('New chat').click();
  await page.getByPlaceholder('bob').fill(peer);
  await page.getByRole('button', { name: 'Create' }).click();
  await expect(page.getByPlaceholder('Write a message…')).toBeVisible();
}

export async function send(page: Page, text: string): Promise<void> {
  await page.getByPlaceholder('Write a message…').fill(text);
  await page.getByRole('button', { name: 'Send' }).click();
  await expect(page.locator('.bubble.mine:not(.pending)', { hasText: text })).toBeVisible();
}

export async function selectConversation(page: Page, title: string): Promise<void> {
  await page.locator('.conv-list li', { hasText: title }).first().click();
  await expect(page.getByPlaceholder('Write a message…')).toBeVisible();
}

const crcTable = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Buffer): Buffer {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

/** Builds a valid RGBA PNG with a colour gradient (for attachment tests). */
export function makePng(width: number, height: number): Buffer {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 4 + 1);
    raw[row] = 0; // filter: none
    for (let x = 0; x < width; x++) {
      const p = row + 1 + x * 4;
      raw[p] = Math.round((255 * x) / Math.max(1, width - 1));
      raw[p + 1] = Math.round((255 * y) / Math.max(1, height - 1));
      raw[p + 2] = 128;
      raw[p + 3] = 255;
    }
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}
