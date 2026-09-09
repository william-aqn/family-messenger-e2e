import { expect, test } from '@playwright/test';
import { openDirect, register, run, selectConversation, send } from './helpers';

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

  await alicePage.getByTitle('New chat').click();
  await alicePage.getByRole('button', { name: 'Group' }).click();
  await alicePage.getByPlaceholder('Weekend plans').fill('Team');
  await alicePage.getByPlaceholder('bob, carol').fill(`${bob}, ${carol}`);
  await alicePage.getByRole('button', { name: 'Create' }).click();
  await send(alicePage, 'Hello team');

  for (const page of [bobPage, carolPage]) {
    await selectConversation(page, 'Team');
    await expect(page.locator('.system', { hasText: 'created the group' })).toBeVisible();
    await expect(page.locator('.bubble', { hasText: 'Hello team' })).toBeVisible();
  }
  await send(carolPage, 'Hi from Carol');
  await expect(bobPage.locator('.bubble', { hasText: 'Hi from Carol' })).toBeVisible();
  await expect(alicePage.locator('.bubble', { hasText: 'Hi from Carol' })).toBeVisible();

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

  await alicePage.getByTitle('New chat').click();
  await alicePage.getByRole('button', { name: 'Group' }).click();
  await alicePage.getByPlaceholder('Weekend plans').fill('Voice');
  await alicePage.getByPlaceholder('bob, carol').fill(`${bob}, ${carol}`);
  await alicePage.getByRole('button', { name: 'Create' }).click();
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

  // Mute state is shared.
  await bobPage.locator('.voice').getByRole('button', { name: 'Mute' }).click();
  await expect(alicePage.locator('.voice-list li', { hasText: bob })).toContainText('🔇', { timeout: 10_000 });

  // Bob leaves: Alice keeps the channel, everybody's presence updates.
  await bobPage.locator('.voice').getByRole('button', { name: 'Leave channel' }).click();
  await expect(bobPage.locator('.voice')).toHaveCount(0);
  await expect(alicePage.locator('.voice-list li', { hasText: bob })).toHaveCount(0, { timeout: 10_000 });
  await expect(carolPage.locator('.voice-bar')).not.toContainText(bob, { timeout: 10_000 });
  await expect(alicePage.locator('.voice-list li.self')).toHaveCount(1);
});

test('voice call with screen sharing', async ({ browser }) => {
  const alice = `calice${run}`;
  const bob = `cbob${run}`;
  const alicePage = await register(browser, alice);
  const bobPage = await register(browser, bob);
  await openDirect(alicePage, bob);
  await selectConversation(bobPage, alice);

  await alicePage.getByTitle('Voice call').click();
  await expect(bobPage.locator('.call-status', { hasText: 'is calling' })).toBeVisible({ timeout: 15_000 });
  await bobPage.getByRole('button', { name: 'Answer' }).click();
  await expect(alicePage.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 30_000 });
  await expect(bobPage.locator('.call-status', { hasText: 'In call with' })).toBeVisible({ timeout: 30_000 });

  await alicePage.getByRole('button', { name: 'Share screen' }).click();
  await expect(alicePage.getByRole('button', { name: 'Stop sharing' })).toBeVisible({ timeout: 15_000 });
  await expect(bobPage.locator('.call-screen:not(.hidden) video')).toBeVisible({ timeout: 20_000 });
  await expect
    .poll(async () => bobPage.locator('.call video').evaluate((v) => (v as HTMLVideoElement).videoWidth), { timeout: 20_000 })
    .toBeGreaterThan(0);

  // The viewer can go full screen; stopping the share hides it and leaves full screen.
  await bobPage.getByRole('button', { name: 'Full screen' }).click();
  await expect.poll(() => bobPage.evaluate(() => document.fullscreenElement?.classList.contains('call-screen') ?? false)).toBe(true);
  await alicePage.getByRole('button', { name: 'Stop sharing' }).click();
  await expect(bobPage.locator('.call-screen')).toBeHidden({ timeout: 10_000 });
  await expect.poll(() => bobPage.evaluate(() => document.fullscreenElement === null)).toBe(true);
  await expect(alicePage.getByRole('button', { name: 'Share screen' })).toBeVisible();

  await bobPage.getByRole('button', { name: 'Hang up' }).click();
  await expect(alicePage.locator('.call-status', { hasText: 'Call ended' })).toBeVisible({ timeout: 10_000 });
});
