// A browser peer for trying calls by hand against a running server: signs in,
// opens the chat with PEER_WITH, answers the next incoming call, keeps it up
// and saves screenshots of what it sees. Uses Chromium's fake camera and a
// silent microphone, so it works on a machine without either.
//
//   cd web && BASE_URL=http://127.0.0.1:8080 PEER_USER=ann PEER_PASSWORD=... PEER_WITH=ben node tests/peer/live-peer.mjs
//
// Environment: BASE_URL (server), PEER_USER / PEER_PASSWORD (an existing
// account), PEER_WITH (the other side's username), SHOT_DIR (screenshots,
// default .), PW_CHANNEL (msedge by default), HOLD_SECONDS (how long to stay
// in the call before hanging up, default 60), PEER_MODE=call to place the
// video call from the browser instead of answering one.
import path from 'node:path';
import { chromium } from '@playwright/test';

const base = process.env.BASE_URL ?? 'http://127.0.0.1:8080';
const me = process.env.PEER_USER;
const password = process.env.PEER_PASSWORD;
const other = process.env.PEER_WITH;
const shots = process.env.SHOT_DIR ?? '.';
const hold = Number(process.env.HOLD_SECONDS ?? '60') * 1000;
if (!me || !password || !other) {
  console.error('PEER_USER, PEER_PASSWORD and PEER_WITH are required');
  process.exit(2);
}
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const silence = path.resolve('tests/peer/silence.wav');

const browser = await chromium.launch({
  channel: process.env.PW_CHANNEL ?? 'msedge',
  headless: false,
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', `--use-file-for-fake-audio-capture=${silence}`, '--window-size=1100,800'],
});
const context = await browser.newContext({ permissions: ['camera', 'microphone'], locale: 'en-US', viewport: { width: 1100, height: 760 } });
const page = await context.newPage();
try {
  await page.goto(base);
  await page.getByLabel('Username').fill(me);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).last().click();
  await page.getByText(`@${me}`).waitFor({ timeout: 60_000 });
  log(`signed in as ${me}`);

  const conv = page.locator('.conv-list li', { hasText: other }).first();
  if (await conv.count()) {
    await conv.click();
  } else {
    // A direct chat starts from the search now: find the person, press Message.
    await page.getByPlaceholder('Search chats, people, messages').fill(other);
    await page.locator('.hit-row.person', { hasText: other }).getByRole('button', { name: 'Message' }).click();
  }
  await page.getByPlaceholder('Write a message…').waitFor();

  if (process.env.PEER_MODE === 'call') {
    // The browser calls; the other side has up to two minutes to answer.
    log(`chat with ${other} open, starting a video call`);
    await page.getByTitle('Video call').click();
    await page.locator('.call-status', { hasText: 'In call with' }).waitFor({ timeout: 120_000 });
    log('the other side answered');
  } else {
    log(`chat with ${other} open, waiting for a call`);
    await page.locator('.call-status', { hasText: /calling|video call/i }).waitFor({ timeout: 10 * 60_000 });
    log('incoming call:', (await page.locator('.call-status').textContent())?.trim());
    await page.getByRole('button', { name: 'Answer' }).click();
    await page.locator('.call-status', { hasText: 'In call with' }).waitFor({ timeout: 60_000 });
    log('answered');
  }

  const started = Date.now();
  let shot = 0;
  while (Date.now() - started < hold) {
    await page.waitForTimeout(5000);
    const status = (await page.locator('.call-status').textContent())?.trim();
    const sizeOf = async (selector) => {
      const video = page.locator(selector);
      return (await video.count()) ? await video.first().evaluate((v) => `${v.videoWidth}x${v.videoHeight}`) : 'none';
    };
    // With a shared screen the stage shows the screen as call-main and the camera as call-pip.
    const both = (await page.locator('.call-stage.both').count()) > 0;
    const size = `${both ? 'screen' : 'camera'} ${await sizeOf('video.call-main')}${both ? ` + camera ${await sizeOf('video.call-pip')}` : ''}`;
    const file = path.join(shots, `browser-call-${++shot}.png`);
    await page.screenshot({ path: file });
    log(`${status} | remote ${size} | ${file}`);
    if (status?.includes('Call ended')) break;
  }
  if (!(await page.locator('.call-status', { hasText: 'Call ended' }).count())) {
    await page.getByRole('button', { name: 'Hang up' }).click();
    log('hung up');
    await page.waitForTimeout(1500);
  }
} finally {
  await browser.close();
}
