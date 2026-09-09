import { expect, test } from '@playwright/test';
import { register, selectConversation } from '../e2e/helpers';

// The browser side of app/integration_test/video_call_test.dart: registers
// the peer, waits for the app to open a chat and call, answers with the fake
// camera, checks that video arrives from the app, then hangs up.
const me = process.env.TEST_PEER ?? 'appbob';
const app = process.env.TEST_USER ?? 'appalice';

test('answers the video call from the app', async ({ browser }) => {
  const page = await register(browser, me);
  await expect(page.locator('.conv-list li', { hasText: app })).toBeVisible({ timeout: 180_000 });
  await selectConversation(page, app);

  await expect(page.locator('.call-status', { hasText: 'video call' })).toBeVisible({ timeout: 180_000 });
  await page.getByRole('button', { name: 'Answer' }).click();
  await expect(page.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 60_000 });

  await expect(page.locator('video.call-main')).toBeVisible({ timeout: 30_000 });
  await expect
    .poll(async () => page.locator('video.call-main').evaluate((v) => (v as HTMLVideoElement).videoWidth), { timeout: 30_000 })
    .toBeGreaterThan(0);
  const size = await page.locator('video.call-main').evaluate((v) => `${(v as HTMLVideoElement).videoWidth}x${(v as HTMLVideoElement).videoHeight}`);
  console.log(`PEER video from the app: ${size}`);

  // The app checks our frames and hangs up.
  await expect(page.locator('.call-status', { hasText: 'Call ended' })).toBeVisible({ timeout: 180_000 });
});
