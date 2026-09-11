import { createServer, type Server } from 'node:http';
import { readFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { login, makePng, newContext, openDirect, password, register, run, selectConversation, send } from './helpers';

// The first account registered on a fresh server becomes the administrator,
// so this file runs its admin scenario first (files run alphabetically and
// Playwright empties test-results, where the server keeps its database).
test.describe.configure({ mode: 'serial' });

test('admin panel: invites, registration mode and announcement', async ({ browser }) => {
  const admin = `admin${run}`;
  const adminPage = await register(browser, admin);
  await adminPage.getByTitle('Settings').click();
  await adminPage.getByRole('button', { name: 'Admin panel' }).click();
  await expect(adminPage.locator('.stat', { hasText: 'Users' })).toBeVisible();

  await adminPage.getByRole('button', { name: 'Invites', exact: true }).click();
  await adminPage.getByRole('button', { name: 'Create invites' }).click();
  const code = (await adminPage.locator('.creds code').first().textContent())?.trim();
  expect(code).toMatch(/^[a-z0-9]{16}$/);

  await adminPage.getByRole('button', { name: 'Settings', exact: true }).last().click();
  // Registration is three toggle buttons inside a group labelled "Registration".
  await adminPage.getByLabel('Registration').getByRole('button', { name: 'by invite', exact: true }).click();
  await adminPage.getByLabel('Announcement', { exact: false }).fill('Maintenance tonight');
  await adminPage.getByRole('button', { name: 'Save' }).click();
  await expect(adminPage.locator('.toast', { hasText: 'Settings saved' })).toBeVisible();
  await expect(adminPage.locator('.announcement', { hasText: 'Maintenance tonight' })).toBeVisible();

  try {
    const ctx = await browser.newContext({ locale: 'en-US' });
    const page = await ctx.newPage();
    await page.goto('/');
    await expect(page.locator('.notice', { hasText: 'Maintenance tonight' })).toBeVisible();
    await page.getByRole('button', { name: 'Create account' }).first().click();
    const invited = `invited${run}`;
    await page.getByLabel('Username').fill(invited);
    await page.getByLabel('Password').fill(password(invited));
    await page.getByLabel('Invite code', { exact: false }).fill('wrongcode');
    await page.getByRole('button', { name: 'Create account' }).last().click();
    await expect(page.locator('.error')).toBeVisible();
    await page.getByLabel('Invite code', { exact: false }).fill(code!);
    await page.getByRole('button', { name: 'Create account' }).last().click();
    await expect(page.getByText(`@${invited}`)).toBeVisible({ timeout: 60_000 });

    // The user directory finds people in the search and suggests names in the
    // new-group dialog, until the administrator switches it off.
    await page.getByPlaceholder('Search chats, people, messages').fill(admin.slice(0, 5));
    await expect(page.locator('.hit-row.person', { hasText: admin })).toBeVisible();
    await page.getByTitle('New group').click();
    await expect(page.locator('.suggestions button', { hasText: admin })).toBeVisible();
    await page.getByPlaceholder('bob, carol').fill(admin.slice(0, 5));
    await page.locator('.suggestions button', { hasText: admin }).click();
    await expect(page.getByPlaceholder('bob, carol')).toHaveValue(`${admin}, `);
    await page.getByRole('button', { name: 'Cancel' }).click();

    await adminPage.getByRole('button', { name: 'Settings', exact: true }).last().click();
    await adminPage.getByLabel('Show the user list', { exact: false }).uncheck();
    await adminPage.getByRole('button', { name: 'Save' }).click();
    await expect(adminPage.locator('.toast', { hasText: 'Settings saved' })).toBeVisible();
    await page.getByTitle('New group').click();
    await page.getByPlaceholder('bob, carol').fill(admin.slice(0, 5));
    await expect(page.locator('.suggestions')).toHaveCount(0);
    await page.getByRole('button', { name: 'Cancel' }).click();
    // Cleared first: the same query would not re-run the search.
    await page.getByPlaceholder('Search chats, people, messages').fill('');
    await page.getByPlaceholder('Search chats, people, messages').fill(admin.slice(0, 5));
    await expect(page.locator('.hit-note', { hasText: 'type the whole name' })).toBeVisible();
    await page.getByPlaceholder('Search chats, people, messages').fill('');
    await adminPage.getByLabel('Show the user list', { exact: false }).check();
    await adminPage.getByRole('button', { name: 'Save' }).click();
    await expect(adminPage.locator('.toast', { hasText: 'Settings saved' })).toBeVisible();

    await adminPage.getByRole('button', { name: 'Users', exact: true }).click();
    await expect(adminPage.locator('.admin-table tr', { hasText: invited })).toBeVisible();
    await adminPage.locator('.admin-table tr', { hasText: invited }).getByRole('button', { name: 'Disable' }).click();
    await expect(adminPage.locator('.admin-table tr', { hasText: invited }).locator('.tag.bad')).toBeVisible();
  } finally {
    await adminPage.getByRole('button', { name: 'Settings', exact: true }).last().click();
    await adminPage.getByLabel('Registration').getByRole('button', { name: 'open', exact: true }).click();
    await adminPage.getByLabel('Announcement', { exact: false }).fill('');
    await adminPage.getByRole('button', { name: 'Save' }).click();
    await expect(adminPage.locator('.toast', { hasText: 'Settings saved' })).toBeVisible();
  }
});

test('attachments: image with thumbnail and a document download', async ({ browser }) => {
  const alice = `falice${run}`;
  const bob = `fbob${run}`;
  const alicePage = await register(browser, alice);
  const bobPage = await register(browser, bob);
  await openDirect(alicePage, bob);

  await alicePage.locator('input[type=file]').setInputFiles([
    { name: 'photo.png', mimeType: 'image/png', buffer: makePng(64, 48) },
    { name: 'notes.txt', mimeType: 'text/plain', buffer: Buffer.from('hello attachments') },
  ]);
  await expect(alicePage.locator('.bubble.mine:not(.pending) img.thumb')).toBeVisible({ timeout: 20_000 });
  await expect(alicePage.locator('.bubble.mine:not(.pending) .file-card', { hasText: 'notes.txt' })).toBeVisible({ timeout: 20_000 });

  await selectConversation(bobPage, alice);
  await expect(bobPage.locator('img.thumb')).toBeVisible();
  const [download] = await Promise.all([
    bobPage.waitForEvent('download'),
    bobPage.locator('.file-card', { hasText: 'notes.txt' }).getByRole('button', { name: 'Download' }).click(),
  ]);
  expect(download.suggestedFilename()).toBe('notes.txt');
  const path = await download.path();
  expect(readFileSync(path!, 'utf8')).toBe('hello attachments');
  await expect(bobPage.locator('.conv-list li', { hasText: 'File: notes.txt' })).toBeVisible();
});

test('disappearing messages timer is shown to both sides', async ({ browser }) => {
  const alice = `ralice${run}`;
  const bob = `rbob${run}`;
  const alicePage = await register(browser, alice);
  const bobPage = await register(browser, bob);
  await openDirect(alicePage, bob);
  await send(alicePage, 'before the timer');
  await selectConversation(bobPage, alice);

  await alicePage.getByTitle('Members and security').click();
  await alicePage.locator('.panel select').selectOption('3600');
  await expect(alicePage.locator('.chat-header', { hasText: 'messages disappear after 1 hour' })).toBeVisible();
  await expect(alicePage.locator('.system', { hasText: 'set messages to disappear after 1 hour' })).toBeVisible();
  await expect(bobPage.locator('.chat-header', { hasText: 'messages disappear after 1 hour' })).toBeVisible({ timeout: 10_000 });
  await expect(bobPage.locator('.system', { hasText: 'set messages to disappear after 1 hour' })).toBeVisible();
});

test('language switch to Russian persists', async ({ browser }) => {
  const alice = `lalice${run}`;
  const page = await register(browser, alice);
  await page.getByTitle('Settings').click();
  await page.locator('.modal select').first().selectOption('ru');
  await expect(page.getByRole('button', { name: 'Выйти', exact: true })).toBeVisible();
  // The modal has two ways out: the x in its head and the footer button.
  await page.locator('.modal').getByRole('button', { name: 'Закрыть' }).last().click();
  await expect(page.getByText('Пока нет чатов')).toBeVisible();
  await page.reload();
  await expect(page.getByText('Пока нет чатов')).toBeVisible();
  await page.getByTitle('Настройки').click();
  await page.locator('.modal select').first().selectOption('en');
  await expect(page.getByRole('button', { name: 'Sign out', exact: true })).toBeVisible();
});

test('text size: the whole interface grows and the choice survives a reload', async ({ browser }) => {
  const alice = `talice${run}`;
  const page = await register(browser, alice);
  const headerHeight = async () => (await page.locator('.sidebar-header').boundingBox())!.height;

  const before = await headerHeight();
  await page.getByTitle('Settings').click();
  await expect(page.locator('.size-step.active')).toHaveText('A');
  // The steps are 100 / 115 / 130 / 145 / 160 per cent; take the largest.
  await page.locator('.size-step').last().click();
  await expect(page.locator('.modal', { hasText: '160%' })).toBeVisible();
  await page.locator('.modal').getByRole('button', { name: 'Close' }).last().click();

  // Not the text alone: the header is drawn 1.6 times as tall, so the design's
  // proportions are kept.
  expect(await headerHeight()).toBeCloseTo(before * 1.6, 0);

  await page.reload();
  await expect(page.getByText('No conversations yet')).toBeVisible();
  expect(await headerHeight()).toBeCloseTo(before * 1.6, 0);

  // A phone at the largest size is the tightest the layout ever gets: the
  // window is worth 390 / 1.6 = 244 pixels to it. Nothing may stick out
  // sideways — least of all the control the setting is changed with.
  await page.setViewportSize({ width: 390, height: 844 });
  // The sidebar column has to give way to the window, or it hangs over the
  // right edge and takes the settings button — the way back — with it.
  const gear = (await page.getByTitle('Settings').boundingBox())!;
  expect(gear.x + gear.width).toBeLessThanOrEqual(390);

  await page.getByTitle('Settings').click();
  await expect(page.locator('.size-steps')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)).toBeLessThanOrEqual(0);
  const steps = (await page.locator('.size-steps').boundingBox())!;
  const modal = (await page.locator('.modal').boundingBox())!;
  expect(steps.x + steps.width).toBeLessThanOrEqual(modal.x + modal.width + 1);

  await page.locator('.size-step').first().click();
  await page.locator('.modal').getByRole('button', { name: 'Close' }).last().click();
  await page.setViewportSize({ width: 1280, height: 720 });
  expect(await headerHeight()).toBeCloseTo(before, 0);
});

test('search finds chats, people and messages, and starts a chat from a person', async ({ browser }) => {
  const alice = `salice${run}`;
  const bob = `sbob${run}`;
  const alicePage = await register(browser, alice, '203.0.113.30');
  const bobPage = await register(browser, bob, '203.0.113.31');
  const search = alicePage.getByPlaceholder('Search chats, people, messages');

  // A person nobody has talked to yet, found in the directory.
  await search.fill(bob);
  await expect(alicePage.locator('.hit-group', { hasText: 'People · 1' })).toBeVisible();
  await expect(alicePage.locator('.hit-row.person', { hasText: 'no chats in common' })).toBeVisible();
  await alicePage.locator('.hit-row.person').getByRole('button', { name: 'Message' }).click();
  await expect(alicePage.getByPlaceholder('Write a message…')).toBeVisible();
  // Starting the chat clears the search and leaves the list behind it.
  await expect(search).toHaveValue('');
  await send(alicePage, 'the barrel is in the barn');

  await selectConversation(bobPage, alice);
  await expect(bobPage.locator('.bubble', { hasText: 'barrel' })).toBeVisible();

  // A word from the message: the chat by its title, the message by its text.
  await search.fill('barn');
  await expect(alicePage.locator('.hit-group', { hasText: 'Messages · 1' })).toBeVisible();
  await expect(alicePage.locator('.hit-row.message .hit')).toHaveText('barn');
  await expect(alicePage.locator('.results-foot', { hasText: 'runs on your device' })).toBeVisible();
  await search.fill(bob.slice(0, 4));
  await expect(alicePage.locator('.hit-group', { hasText: 'Chats · 1' })).toBeVisible();

  // The chips narrow it to one group.
  await alicePage.getByRole('button', { name: 'People', exact: true }).click();
  await expect(alicePage.locator('.hit-group')).toHaveCount(1);
  await expect(alicePage.locator('.hit-group')).toContainText('People');

  // Escape clears the search and the conversation list comes back.
  await search.press('Escape');
  await expect(alicePage.locator('.conv-list li', { hasText: bob })).toBeVisible();
});

test('visibility: hiding from search leaves the exact name working', async ({ browser }) => {
  const alice = `hidealice${run}`;
  const hidden = `vhidden${run}`;
  const alicePage = await register(browser, alice, '203.0.113.40');
  const hiddenPage = await register(browser, hidden, '203.0.113.41');

  await hiddenPage.getByTitle('Settings').click();
  await hiddenPage.getByLabel('Let people find me in search').uncheck();
  await expect(hiddenPage.locator('.hint', { hasText: 'exact name' })).toBeVisible();
  await hiddenPage.locator('.modal').getByRole('button', { name: 'Close' }).last().click();

  const search = alicePage.getByPlaceholder('Search chats, people, messages');
  await search.fill(hidden.slice(0, 4));
  await expect(alicePage.locator('.hit-row.person')).toHaveCount(0);
  // The whole name still answers: that is where key discovery looks.
  await search.fill(hidden);
  await expect(alicePage.locator('.hit-row.person', { hasText: hidden })).toBeVisible();

  // And the setting survives a reload of the settings modal.
  await hiddenPage.reload();
  await hiddenPage.getByTitle('Settings').click();
  await expect(hiddenPage.getByLabel('Let people find me in search')).not.toBeChecked();
});

test('bots: a webhook echo bot answers in a direct chat', async ({ browser }) => {
  const received: string[] = [];
  const hook: Server = createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', () => {
      const update = JSON.parse(body);
      received.push(update.type);
      res.setHeader('Content-Type', 'application/json');
      if (update.type === 'message') res.end(JSON.stringify({ reply: `echo: ${update.message.text}` }));
      else res.end('{}');
    });
  });
  await new Promise<void>((resolve) => hook.listen(0, '127.0.0.1', resolve));
  const port = (hook.address() as { port: number }).port;
  try {
    const alice = `balice${run}`;
    const page = await register(browser, alice);
    await page.getByTitle('Settings').click();
    await page.getByRole('button', { name: 'My bots' }).click();
    await page.getByPlaceholder('weatherbot').fill(`echo${run}bot`);
    await page.getByPlaceholder('Display name').fill('Echo');
    await page.getByPlaceholder('https://example.com/hook').last().fill(`http://127.0.0.1:${port}/hook`);
    await page.getByRole('button', { name: 'Create bot' }).click();
    await expect(page.locator('.creds', { hasText: 'Bot credentials' })).toBeVisible();
    const token = (await page.locator('.creds code').first().textContent())?.trim();
    expect(token?.length).toBeGreaterThan(20);
    await page.locator('.creds').getByRole('button', { name: 'Close' }).click();
    await page.getByRole('button', { name: 'Open chat' }).click();
    await expect(page.locator('.notice', { hasText: 'includes a bot' })).toBeVisible();
    await send(page, 'ping');
    await expect(page.locator('.bubble:not(.mine)', { hasText: 'echo: ping' })).toBeVisible({ timeout: 15_000 });
    expect(received).toContain('joined');
    expect(received).toContain('message');
  } finally {
    hook.close();
  }
});

test('messages: edit and delete your own, the administrator deletes anyone’s', async ({ browser }) => {
  const alice = `ealice${run}`;
  const bob = `ebob${run}`;
  const alicePage = await register(browser, alice);
  const bobPage = await register(browser, bob);
  await openDirect(alicePage, bob);
  await send(alicePage, 'typo mesage');
  await selectConversation(bobPage, alice);
  await expect(bobPage.locator('.bubble', { hasText: 'typo mesage' })).toBeVisible();

  // Edit through the message menu: both sides see the new text and the marker.
  const bubble = alicePage.locator('.bubble.mine', { hasText: 'typo mesage' });
  await bubble.hover();
  await bubble.getByTitle('Message actions').click();
  await alicePage.getByRole('button', { name: 'Edit' }).click();
  await expect(alicePage.getByPlaceholder('Write a message…')).toHaveValue('typo mesage');
  await alicePage.getByPlaceholder('Write a message…').fill('fixed message');
  await alicePage.getByRole('button', { name: 'Save' }).click();
  await expect(alicePage.locator('.bubble.mine', { hasText: 'fixed message' })).toContainText('edited');
  await expect(bobPage.locator('.bubble', { hasText: 'fixed message' })).toContainText('edited', { timeout: 10_000 });
  await expect(bobPage.locator('.bubble', { hasText: 'typo mesage' })).toHaveCount(0);
  await expect(bobPage.locator('.conv-list li', { hasText: 'fixed message' })).toBeVisible();

  // Bob has no menu on Alice's message; Up in the empty composer edits his own last one.
  await send(bobPage, 'bob text');
  await expect(bobPage.locator('.bubble:not(.mine)', { hasText: 'fixed message' }).getByTitle('Message actions')).toHaveCount(0);
  await bobPage.getByPlaceholder('Write a message…').press('ArrowUp');
  await expect(bobPage.getByPlaceholder('Write a message…')).toHaveValue('bob text');
  await bobPage.getByPlaceholder('Write a message…').press('Escape');
  await expect(bobPage.getByPlaceholder('Write a message…')).toHaveValue('');
  await expect(bobPage.getByPlaceholder('Write a message…')).toBeVisible();

  // Deleting removes the message on both sides. The menu item opens the app's
  // own confirmation dialog, which replaced the browser's confirm().
  const edited = alicePage.locator('.bubble.mine', { hasText: 'fixed message' });
  await edited.hover();
  await edited.getByTitle('Message actions').click();
  await alicePage.getByRole('button', { name: 'Delete' }).click();
  await alicePage.locator('.modal').getByRole('button', { name: 'Delete' }).click();
  await expect(alicePage.locator('.bubble', { hasText: 'fixed message' })).toHaveCount(0);
  await expect(bobPage.locator('.bubble', { hasText: 'fixed message' })).toHaveCount(0, { timeout: 10_000 });

  // The administrator (the first account on this server) removes Bob's message in a chat with him.
  const adminPage = await login(browser, `admin${run}`);
  await openDirect(adminPage, bob);
  await selectConversation(bobPage, `admin${run}`);
  await send(bobPage, 'rude remark');
  const remark = adminPage.locator('.bubble:not(.mine)', { hasText: 'rude remark' });
  await expect(remark).toBeVisible();
  await remark.hover();
  await remark.getByTitle('Message actions').click();
  await expect(adminPage.getByRole('button', { name: 'Edit' })).toHaveCount(0);
  await adminPage.getByRole('button', { name: 'Delete' }).click();
  await adminPage.locator('.modal').getByRole('button', { name: 'Delete' }).click();
  await expect(adminPage.locator('.bubble', { hasText: 'rude remark' })).toHaveCount(0);
  await expect(bobPage.locator('.bubble', { hasText: 'rude remark' })).toHaveCount(0, { timeout: 10_000 });
});

test('password change: no old password, other devices warned then signed out', async ({ browser }) => {
  const name = `pw${run}`;
  // Three devices on three addresses: the login limiter counts per client address.
  const page = await register(browser, name, '203.0.113.1');
  const phone = await login(browser, name, '203.0.113.2');
  const newPassword = `${name}-new-password-${run}`;
  const laterPassword = `${name}-later-password-${run}`;

  await page.getByTitle('Settings').click();
  const fpBefore = (await page.locator('code.fp').textContent())?.trim();
  expect(fpBefore).toMatch(/^[0-9a-f]{4}( [0-9a-f]{4}){7}$/);
  await expect(page.locator('.devices li')).toHaveCount(2);
  // The old password is never asked for: this device proves itself with the
  // account keys it already holds.
  await expect(page.getByLabel('current password')).toHaveCount(0);
  await page.getByLabel('new password', { exact: true }).fill(newPassword);
  await page.getByLabel('repeat the new password').fill(`${newPassword}-typo`);
  await page.getByRole('button', { name: 'Change password' }).click();
  await expect(page.locator('.error', { hasText: 'typed differently' })).toBeVisible();
  await page.getByLabel('repeat the new password').fill(newPassword);

  // Leave the other device signed in first: it must hear about the change.
  await page.getByLabel('Sign out of every other device').uncheck();
  await page.getByRole('button', { name: 'Change password' }).click();
  await expect(page.locator('.toast', { hasText: 'Password changed' })).toBeVisible({ timeout: 60_000 });
  await expect(page.locator('.devices li')).toHaveCount(2);
  await expect(phone.locator('.banner.alert', { hasText: 'changed from another device' })).toBeVisible({ timeout: 20_000 });

  // Now the same again with the eviction, from the device that was warned:
  // it still holds the keys, so it can take the account back without ever
  // knowing the password that was just set.
  await phone.getByTitle('Settings').click();
  await phone.getByLabel('new password', { exact: true }).fill(laterPassword);
  await phone.getByLabel('repeat the new password').fill(laterPassword);
  await phone.getByRole('button', { name: 'Change password' }).click();
  await expect(phone.locator('.toast', { hasText: 'Password changed; 1 other device(s) signed out' })).toBeVisible({ timeout: 60_000 });
  await expect(phone.locator('.devices li')).toHaveCount(1);

  // The revoked device notices by itself and returns to the login screen.
  await expect(page.getByRole('button', { name: 'Sign in' }).last()).toBeVisible({ timeout: 20_000 });

  // The old password is refused; the new one signs in and unlocks the same keys.
  const again = await (await newContext(browser, '203.0.113.3')).newPage();
  await again.goto('/');
  await again.getByLabel('Username').fill(name);
  await again.getByLabel('Password').fill(password(name));
  await again.getByRole('button', { name: 'Sign in' }).last().click();
  await expect(again.locator('.error', { hasText: 'Wrong username or password' })).toBeVisible({ timeout: 60_000 });
  await again.getByLabel('Password').fill(laterPassword);
  await again.getByRole('button', { name: 'Sign in' }).last().click();
  await expect(again.getByText(`@${name}`)).toBeVisible({ timeout: 60_000 });
  await again.getByTitle('Settings').click();
  await expect(again.locator('code.fp')).toHaveText(fpBefore!);
});
