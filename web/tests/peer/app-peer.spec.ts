import { expect, type Page, test } from '@playwright/test';
import { register, selectConversation } from '../e2e/helpers';

// The browser side of app/integration_test/video_call_test.dart: registers
// the peer, waits for the app to open a chat, then walks through the app's
// scenario with it: answers a video call (camera, then the shared screen),
// answers a second call, and finally calls the app itself and hangs up.
const me = process.env.TEST_PEER ?? 'appbob';
const app = process.env.TEST_USER ?? 'appalice';

const videoWidth = (v: Element) => (v as HTMLVideoElement).videoWidth;

async function expectFrames(page: Page, selector: string, what: string): Promise<void> {
  await expect(page.locator(selector).first()).toBeVisible({ timeout: 30_000 });
  await expect.poll(async () => page.locator(selector).first().evaluate(videoWidth), { timeout: 30_000 }).toBeGreaterThan(0);
  const size = await page.locator(selector).first().evaluate((v) => `${(v as HTMLVideoElement).videoWidth}x${(v as HTMLVideoElement).videoHeight}`);
  console.log(`PEER ${what} from the app: ${size}`);
}

async function answer(page: Page): Promise<void> {
  await expect(page.locator('.call-status', { hasText: 'video call' })).toBeVisible({ timeout: 180_000 });
  await page.getByRole('button', { name: 'Answer' }).click();
  await expect(page.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 60_000 });
}

async function waitForEnd(page: Page): Promise<void> {
  await expect(page.locator('.call-status', { hasText: 'Call ended' })).toBeVisible({ timeout: 180_000 });
  await page.getByRole('button', { name: 'Close' }).click();
  await expect(page.locator('.call-status')).toHaveCount(0);
}

test('video calls with the app', async ({ browser }) => {
  const page = await register(browser, me);
  await expect(page.locator('.conv-list li', { hasText: app })).toBeVisible({ timeout: 180_000 });
  await selectConversation(page, app);

  // Call 1: camera, then the shared screen beside it, then the camera alone again.
  await answer(page);
  await expectFrames(page, 'video.call-main', 'camera');
  await expect(page.locator('.call-stage.both')).toBeVisible({ timeout: 60_000 });
  await expectFrames(page, 'video.call-main', 'screen');
  await expectFrames(page, 'video.call-pip', 'camera beside the screen');
  await expect(page.locator('.call-stage.both')).toHaveCount(0, { timeout: 60_000 });
  console.log('PEER screen sharing stopped');
  await waitForEnd(page);
  console.log('PEER call 1 ended');

  // Call 2: the app calls again.
  await answer(page);
  await expectFrames(page, 'video.call-main', 'camera (call 2)');
  await waitForEnd(page);
  console.log('PEER call 2 ended');

  // Call 3: we call (once the app's ended-call overlay has gone); the app answers with its button; we hang up.
  await page.waitForTimeout(6000);
  await page.getByTitle('Video call').click();
  await expect(page.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 120_000 });
  await expectFrames(page, 'video.call-main', 'camera (call 3, incoming for the app)');
  await page.waitForTimeout(5000);
  await page.getByRole('button', { name: 'Hang up' }).click();
  await expect(page.locator('.call-status', { hasText: 'Call ended' })).toBeVisible({ timeout: 10_000 });
  console.log('PEER call 3 hung up');
});
