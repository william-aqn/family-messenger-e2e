import { expect, test } from '@playwright/test';
import { createGroup, openDirect, register, run, selectConversation, send } from './helpers';

test('direct chat: messages flow both ways and survive a reload', async ({ browser }) => {
  const alice = `alice${run}`;
  const bob = `bob${run}`;
  const alicePage = await register(browser, alice);
  const bobPage = await register(browser, bob);

  await openDirect(alicePage, bob);
  await send(alicePage, 'Привет, Боб! 🔐');

  await selectConversation(bobPage, alice);
  await expect(bobPage.locator('.bubble', { hasText: 'Привет, Боб! 🔐' })).toBeVisible();
  await expect(bobPage.locator('.system', { hasText: 'started the chat' })).toBeVisible();
  // One other person writes here and the header names them: no sender above
  // the bubble, unlike a group.
  await expect(bobPage.locator('.bubble .author')).toHaveCount(0);
  await send(bobPage, 'Hi Alice, all good.');
  await expect(alicePage.locator('.bubble', { hasText: 'Hi Alice, all good.' })).toBeVisible();

  await alicePage.reload();
  await selectConversation(alicePage, bob);
  await expect(alicePage.locator('.bubble', { hasText: 'Hi Alice, all good.' })).toBeVisible();

  await alicePage.getByTitle('Members and security').click();
  await expect(alicePage.locator('code.fp')).toHaveCount(2);
});

test('group chat with a signed roster', async ({ browser }) => {
  const alice = `galice${run}`;
  const bob = `gbob${run}`;
  const carol = `gcarol${run}`;
  const alicePage = await register(browser, alice);
  const bobPage = await register(browser, bob);
  const carolPage = await register(browser, carol);

  await createGroup(alicePage, 'Team', [bob, carol]);
  await send(alicePage, 'Hello team');

  for (const page of [bobPage, carolPage]) {
    await selectConversation(page, 'Team');
    await expect(page.locator('.system', { hasText: 'created the group' })).toBeVisible();
    await expect(page.locator('.bubble', { hasText: 'Hello team' })).toBeVisible();
  }
  await send(carolPage, 'Hi from Carol');
  await expect(bobPage.locator('.bubble', { hasText: 'Hi from Carol' })).toBeVisible();
  await expect(alicePage.locator('.bubble', { hasText: 'Hi from Carol' })).toBeVisible();
  // Three people write here, so every incoming bubble says who did.
  await expect(bobPage.locator('.bubble .author', { hasText: carol })).toBeVisible();

  // Carol leaves; the remaining members see the signed event.
  await carolPage.getByTitle('Members and security').click();
  await carolPage.getByRole('button', { name: 'Leave group' }).click();
  await expect(alicePage.locator('.system', { hasText: 'left' })).toBeVisible();
  await expect(carolPage.locator('.conv-list li', { hasText: 'Team' })).toHaveCount(0);
});

test('group voice channel: join, mesh connection, presence and leave', async ({ browser }) => {
  const alice = `valice${run}`;
  const bob = `vbob${run}`;
  const carol = `vcarol${run}`;
  const alicePage = await register(browser, alice);
  const bobPage = await register(browser, bob);
  const carolPage = await register(browser, carol);

  await createGroup(alicePage, 'Voice', [bob, carol]);
  await send(alicePage, 'voice test');
  for (const page of [bobPage, carolPage]) {
    await selectConversation(page, 'Voice');
    await expect(page.locator('.bubble', { hasText: 'voice test' })).toBeVisible();
  }

  // Alice joins; the others see her in the channel without joining.
  await alicePage.getByTitle('Voice channel').click();
  await expect(alicePage.locator('.voice .call-status')).toContainText('Voice channel · Voice', { timeout: 15_000 });
  await expect(bobPage.locator('.voice-bar')).toContainText(alice, { timeout: 15_000 });
  await expect(carolPage.locator('.voice-bar')).toContainText(alice, { timeout: 15_000 });

  // Bob joins from the bar: both ends report a connected peer.
  await bobPage.getByRole('button', { name: 'Join voice' }).click();
  await expect(bobPage.locator('.voice-list li.connected', { hasText: alice })).toBeVisible({ timeout: 30_000 });
  await expect(alicePage.locator('.voice-list li.connected', { hasText: bob })).toBeVisible({ timeout: 30_000 });
  await expect(carolPage.locator('.voice-bar')).toContainText(bob, { timeout: 15_000 });

  // Alice streams her screen into the channel; Bob sees it, focuses it, and it
  // disappears when she stops.
  await alicePage.locator('.voice').getByRole('button', { name: 'Share screen' }).click();
  await expect(alicePage.locator('.voice').getByRole('button', { name: 'Stop sharing' })).toBeVisible({ timeout: 15_000 });
  await expect(bobPage.locator('.voice-video video')).toBeVisible({ timeout: 20_000 });
  await expect
    .poll(async () => bobPage.locator('.voice-video video').evaluate((v) => (v as HTMLVideoElement).videoWidth), { timeout: 20_000 })
    .toBeGreaterThan(0);
  // The sharer is marked with a monitor icon (an emoji before the redesign).
  await expect(carolPage.locator('.voice-bar use[href="#i-monitor"]')).toHaveCount(1);
  await bobPage.locator('.voice-tabs button', { hasText: alice }).click();
  await expect(bobPage.locator('.voice-grid.focus')).toBeVisible();
  await alicePage.locator('.voice').getByRole('button', { name: 'Stop sharing' }).click();
  await expect(bobPage.locator('.voice-video')).toHaveCount(0, { timeout: 10_000 });

  // Mute state is shared.
  await bobPage.locator('.voice').getByRole('button', { name: 'Mute' }).click();
  await expect(alicePage.locator('.voice-list li', { hasText: bob }).locator('use[href="#i-mic-off"]')).toHaveCount(1, { timeout: 10_000 });

  // Bob leaves: Alice keeps the channel, everybody's presence updates.
  await bobPage.locator('.voice').getByRole('button', { name: 'Leave channel' }).click();
  await expect(bobPage.locator('.voice')).toHaveCount(0);
  await expect(alicePage.locator('.voice-list li', { hasText: bob })).toHaveCount(0, { timeout: 10_000 });
  await expect(carolPage.locator('.voice-bar')).not.toContainText(bob, { timeout: 10_000 });
  await expect(alicePage.locator('.voice-list li.self')).toHaveCount(1);
});

const videoWidth = (v: Element) => (v as HTMLVideoElement).videoWidth;

test('voice call: screen sharing and a camera switched on mid-call', async ({ browser }) => {
  const alice = `calice${run}`;
  const bob = `cbob${run}`;
  // Its own address: by this point in the file the shared 127.0.0.1 has spent
  // the auth limiter’s burst.
  const alicePage = await register(browser, alice, '203.0.113.20');
  const bobPage = await register(browser, bob, '203.0.113.21');
  await openDirect(alicePage, bob);
  await selectConversation(bobPage, alice);

  await alicePage.getByTitle('Voice call').click();
  await expect(bobPage.locator('.call-status', { hasText: 'is calling' })).toBeVisible({ timeout: 15_000 });
  await bobPage.getByRole('button', { name: 'Answer' }).click();
  await expect(alicePage.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 30_000 });
  await expect(bobPage.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 30_000 });
  await expect(bobPage.locator('.call-screen')).toBeHidden();

  await alicePage.getByRole('button', { name: 'Share screen' }).click();
  await expect(alicePage.getByRole('button', { name: 'Stop sharing' })).toBeVisible({ timeout: 15_000 });
  await expect(bobPage.locator('.call-screen:not(.hidden) video.call-main')).toBeVisible({ timeout: 20_000 });
  await expect.poll(async () => bobPage.locator('video.call-main').evaluate(videoWidth), { timeout: 20_000 }).toBeGreaterThan(0);

  // The viewer can go full screen; stopping the share hides it and leaves full screen.
  await bobPage.getByRole('button', { name: 'Full screen' }).click();
  await expect.poll(() => bobPage.evaluate(() => document.fullscreenElement?.classList.contains('call-screen') ?? false)).toBe(true);
  await alicePage.getByRole('button', { name: 'Stop sharing' }).click();
  await expect(bobPage.locator('.call-screen')).toBeHidden({ timeout: 10_000 });
  await expect.poll(() => bobPage.evaluate(() => document.fullscreenElement === null)).toBe(true);
  await expect(alicePage.getByRole('button', { name: 'Share screen' })).toBeVisible();

  // Bob switches his camera on in the audio call: Alice sees it, then it goes away.
  await bobPage.getByRole('button', { name: 'Camera on' }).click();
  await expect(bobPage.locator('video.call-self')).toBeVisible({ timeout: 15_000 });
  await expect(alicePage.locator('video.call-main')).toBeVisible({ timeout: 20_000 });
  await expect.poll(async () => alicePage.locator('video.call-main').evaluate(videoWidth), { timeout: 20_000 }).toBeGreaterThan(0);
  await bobPage.getByRole('button', { name: 'Camera off' }).click();
  await expect(alicePage.locator('video.call-main')).toHaveCount(0, { timeout: 10_000 });

  await bobPage.getByRole('button', { name: 'Hang up' }).click();
  await expect(alicePage.locator('.call-status', { hasText: 'Call ended' })).toBeVisible({ timeout: 10_000 });
});

test('video call: both cameras, a screen on top of the camera, full screen', async ({ browser }) => {
  const alice = `vcalice${run}`;
  const bob = `vcbob${run}`;
  // Own client addresses: this is the last test of the run, and by then the
  // shared 127.0.0.1 has spent the server's registration allowance.
  const alicePage = await register(browser, alice, '203.0.113.10');
  const bobPage = await register(browser, bob, '203.0.113.11');
  await openDirect(alicePage, bob);
  await selectConversation(bobPage, alice);

  await alicePage.getByTitle('Video call').click();
  await expect(bobPage.locator('.call-status', { hasText: 'video call' })).toBeVisible({ timeout: 15_000 });
  await bobPage.getByRole('button', { name: 'Answer' }).click();
  await expect(alicePage.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 30_000 });
  await expect(bobPage.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 30_000 });

  // Both cameras are on: each side sees the other's camera and its own preview.
  for (const page of [alicePage, bobPage]) {
    await expect(page.locator('video.call-main')).toBeVisible({ timeout: 20_000 });
    await expect.poll(async () => page.locator('video.call-main').evaluate(videoWidth), { timeout: 20_000 }).toBeGreaterThan(0);
    await expect(page.locator('video.call-self')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Camera off' })).toBeVisible();
  }

  // Alice adds her screen: Bob gets the screen on the stage and the camera beside it.
  await alicePage.getByRole('button', { name: 'Share screen' }).click();
  await expect(bobPage.locator('.call-stage.both')).toBeVisible({ timeout: 20_000 });
  await expect.poll(async () => bobPage.locator('video.call-pip').evaluate(videoWidth), { timeout: 20_000 }).toBeGreaterThan(0);
  await expect.poll(async () => bobPage.locator('video.call-main').evaluate(videoWidth), { timeout: 20_000 }).toBeGreaterThan(0);
  await bobPage.getByRole('button', { name: 'Full screen' }).click();
  await expect.poll(() => bobPage.evaluate(() => document.fullscreenElement?.classList.contains('call-screen') ?? false)).toBe(true);

  // The screen stops but the camera stays, so full screen stays too; the camera off ends it.
  await alicePage.getByRole('button', { name: 'Stop sharing' }).click();
  await expect(bobPage.locator('.call-stage.both')).toHaveCount(0, { timeout: 10_000 });
  await expect(bobPage.locator('video.call-main')).toBeVisible();
  await expect.poll(() => bobPage.evaluate(() => document.fullscreenElement?.classList.contains('call-screen') ?? false)).toBe(true);
  await alicePage.getByRole('button', { name: 'Camera off' }).click();
  await expect(bobPage.locator('video.call-main')).toHaveCount(0, { timeout: 10_000 });
  await expect.poll(() => bobPage.evaluate(() => document.fullscreenElement === null)).toBe(true);
  await expect(alicePage.getByRole('button', { name: 'Camera on' })).toBeVisible();

  await bobPage.getByRole('button', { name: 'Hang up' }).click();
  await expect(alicePage.locator('.call-status', { hasText: 'Call ended' })).toBeVisible({ timeout: 10_000 });
});
