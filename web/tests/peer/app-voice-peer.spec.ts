import { expect, type Page, test } from '@playwright/test';
import { register, selectConversation } from '../e2e/helpers';

// The browser side of app/integration_test/voice_channel_test.dart: registers
// the peer, waits for the app to create the group, joins its voice channel,
// turns the camera on and shares the screen — so every pair has to carry a
// camera and a screen at the same time, which is what the channel's two video
// slots per pair are for.
//
// scripts/app-voice-channel-test.ps1 runs this against two apps (Android and
// Windows), so by default two other participants are expected.
const me = process.env.TEST_PEER ?? 'appbob';
const group = process.env.TEST_GROUP ?? 'Channel';
const peers = Number(process.env.TEST_PEERS ?? '2');
const shot = process.env.TEST_SHOT;

/** Waits until `count` videos matching `selector` are carrying frames. */
async function expectFrames(page: Page, selector: string, what: string, count: number): Promise<void> {
  await expect
    .poll(async () => (await page.locator(selector).all()).length, { timeout: 180_000, message: `${count} ${what} tiles` })
    .toBeGreaterThanOrEqual(count);
  await expect
    .poll(
      async () => {
        const sizes = await page.locator(selector).evaluateAll((vs) => vs.map((v) => (v as HTMLVideoElement).videoWidth));
        return sizes.filter((w) => w > 0).length;
      },
      { timeout: 180_000, message: `frames in ${count} ${what} tiles` },
    )
    .toBeGreaterThanOrEqual(count);
  // The callback runs in the page, so it cannot reach anything defined here.
  const sizes = await page.locator(selector).evaluateAll((vs) => vs.map((v) => `${(v as HTMLVideoElement).videoWidth}x${(v as HTMLVideoElement).videoHeight}`));
  console.log(`PEER ${what}: ${sizes.join(' | ')}`);
}

test('a group voice channel with the apps', async ({ browser }) => {
  const page = await register(browser, me);
  // The client reports signalling and WebRTC trouble to the console; without
  // this the peer's half of a failure is invisible in the rig's logs.
  page.on('console', (m) => {
    if (m.type() === 'error' || m.type() === 'warning') console.log(`PEER console ${m.type()}: ${m.text()}`);
  });
  page.on('pageerror', (e) => console.log(`PEER pageerror: ${e.message}`));
  console.log(`PEER signed in as ${me}`);
  // The host app registers, creates the group and joins the channel on its own.
  await expect(page.locator('.conv-list li', { hasText: group })).toBeVisible({ timeout: 420_000 });
  await selectConversation(page, group);
  console.log('PEER the group is here');

  await page.getByRole('button', { name: 'Join voice' }).click();
  await expect(page.locator('.voice')).toBeVisible({ timeout: 60_000 });
  await expect(page.locator('.voice-list li.connected')).toHaveCount(peers, { timeout: 300_000 });
  console.log(`PEER connected to ${peers} peers`);

  await page.locator('.voice').getByRole('button', { name: 'Camera on' }).click();
  await expect(page.locator('.voice').getByRole('button', { name: 'Camera off' })).toBeVisible({ timeout: 30_000 });
  await page.locator('.voice').getByRole('button', { name: 'Share screen' }).click();
  await expect(page.locator('.voice').getByRole('button', { name: 'Stop sharing' })).toBeVisible({ timeout: 30_000 });
  console.log('PEER camera and screen on');

  // Everybody else's camera is a tile of its own, beside our own tile...
  await expectFrames(page, '.voice-video.camera:not(.self) video', 'camera', peers);
  // ...and so is everybody else's screen.
  await expectFrames(page, '.voice-video.screen video', 'screen', peers);
  if (shot) await page.locator('.voice-screens').screenshot({ path: shot });
  console.log('PEER CHANNEL OK');

  // Hold while the apps check their own side, then leave.
  await page.waitForTimeout(20_000);
  await page.locator('.voice').getByRole('button', { name: 'Leave channel' }).click();
  await expect(page.locator('.voice')).toHaveCount(0);
  console.log('PEER left the channel');
});
