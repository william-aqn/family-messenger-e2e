// A browser peer for trying a group voice channel by hand against a running
// server: signs in, opens GROUP, joins its voice channel, turns the camera on
// and saves screenshots of the tiles it sees. Uses Chromium's fake camera and
// a silent microphone, so it works on a machine without either.
//
//   cd web && BASE_URL=http://127.0.0.1:8080 PEER_USER=ann PEER_PASSWORD=... GROUP=Banya node tests/peer/live-voice-peer.mjs
//
// Environment: BASE_URL, PEER_USER / PEER_PASSWORD (an existing account),
// GROUP (the group whose channel to join), SHOT_DIR (screenshots, default .),
// PW_CHANNEL (msedge by default), HOLD_SECONDS (default 60), PEER_CAMERA=0 to
// stay audio-only, PEER_SHARE=1 to share the screen as well.
import path from 'node:path';
import { chromium } from '@playwright/test';

const base = process.env.BASE_URL ?? 'http://127.0.0.1:8080';
const me = process.env.PEER_USER;
const password = process.env.PEER_PASSWORD;
const group = process.env.GROUP;
const shots = process.env.SHOT_DIR ?? '.';
const hold = Number(process.env.HOLD_SECONDS ?? '60') * 1000;
if (!me || !password || !group) {
  console.error('PEER_USER, PEER_PASSWORD and GROUP are required');
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

  await page.locator('.conv-list li', { hasText: group }).first().click();
  await page.getByPlaceholder('Write a message…').waitFor({ timeout: 30_000 });
  log(`group ${group} open`);

  const join = page.getByRole('button', { name: 'Join voice' });
  const channel = page.getByTitle('Voice channel');
  if (await join.count()) await join.click();
  else await channel.click();
  await page.locator('.voice').waitFor({ timeout: 60_000 });
  log('in the channel');

  if (process.env.PEER_CAMERA !== '0') {
    await page.locator('.voice').getByRole('button', { name: 'Camera on' }).click();
    await page.locator('.voice').getByRole('button', { name: 'Camera off' }).waitFor({ timeout: 30_000 });
    log('camera on');
  }
  if (process.env.PEER_SHARE === '1') {
    await page.locator('.voice').getByRole('button', { name: 'Share screen' }).click();
    await page.locator('.voice').getByRole('button', { name: 'Stop sharing' }).waitFor({ timeout: 30_000 });
    log('screen shared');
  }

  const until = Date.now() + hold;
  for (let i = 1; Date.now() < until; i++) {
    await page.waitForTimeout(5000);
    const tiles = await page.evaluate(() =>
      [...document.querySelectorAll('.voice-video')].map((el) => {
        const v = el.querySelector('video');
        return `${el.className.replace('voice-video ', '')}${v ? ` ${v.videoWidth}x${v.videoHeight}` : ' no video'}`;
      }),
    );
    const file = path.join(shots, `voice-peer-${i}.png`);
    await page.locator('.voice').screenshot({ path: file });
    log(`tiles: ${tiles.join(' | ')} -> ${file}`);
  }
  await page.locator('.voice').getByRole('button', { name: 'Leave channel' }).click();
  log('left the channel');
} catch (e) {
  console.error('peer failed:', e);
  process.exitCode = 1;
} finally {
  await browser.close();
}
