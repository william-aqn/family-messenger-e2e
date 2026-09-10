import { createServer, type Server } from 'node:http';
import { readFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { login, makePng, openDirect, password, register, run, selectConversation, send } from './helpers';

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
  await adminPage.getByLabel('Registration').selectOption('invite');
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

    // The user directory suggests names in the new-chat dialog, until the
    // administrator switches it off.
    await page.getByTitle('New chat').click();
    await expect(page.locator('.suggestions button', { hasText: admin })).toBeVisible();
    await page.getByLabel('Username').fill(admin.slice(0, 5));
    await page.locator('.suggestions button', { hasText: admin }).click();
    await expect(page.getByLabel('Username')).toHaveValue(admin);
    await page.getByRole('button', { name: 'Cancel' }).click();

    await adminPage.getByRole('button', { name: 'Settings', exact: true }).last().click();
    await adminPage.getByLabel('Show the user list', { exact: false }).uncheck();
    await adminPage.getByRole('button', { name: 'Save' }).click();
    await expect(adminPage.locator('.toast', { hasText: 'Settings saved' })).toBeVisible();
    await page.getByTitle('New chat').click();
    await page.getByLabel('Username').fill(admin.slice(0, 5));
    await expect(page.locator('.suggestions')).toHaveCount(0);
    await page.getByRole('button', { name: 'Cancel' }).click();
    await adminPage.getByLabel('Show the user list', { exact: false }).check();
    await adminPage.getByRole('button', { name: 'Save' }).click();
    await expect(adminPage.locator('.toast', { hasText: 'Settings saved' })).toBeVisible();

    await adminPage.getByRole('button', { name: 'Users', exact: true }).click();
    await expect(adminPage.locator('.admin-table tr', { hasText: invited })).toBeVisible();
    await adminPage.locator('.admin-table tr', { hasText: invited }).getByRole('button', { name: 'Disable' }).click();
    await expect(adminPage.locator('.admin-table tr', { hasText: invited }).locator('.tag.bad')).toBeVisible();
  } finally {
    await adminPage.getByRole('button', { name: 'Settings', exact: true }).last().click();
    await adminPage.getByLabel('Registration').selectOption('open');
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
  await page.getByRole('button', { name: 'Закрыть' }).click();
  await expect(page.getByText('Пока нет чатов')).toBeVisible();
  await page.reload();
  await expect(page.getByText('Пока нет чатов')).toBeVisible();
  await page.getByTitle('Настройки').click();
  await page.locator('.modal select').first().selectOption('en');
  await expect(page.getByRole('button', { name: 'Sign out', exact: true })).toBeVisible();
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

  // Deleting removes the message on both sides.
  alicePage.once('dialog', (d) => void d.accept());
  const edited = alicePage.locator('.bubble.mine', { hasText: 'fixed message' });
  await edited.hover();
  await edited.getByTitle('Message actions').click();
  await alicePage.getByRole('button', { name: 'Delete' }).click();
  await expect(alicePage.locator('.bubble', { hasText: 'fixed message' })).toHaveCount(0);
  await expect(bobPage.locator('.bubble', { hasText: 'fixed message' })).toHaveCount(0, { timeout: 10_000 });

  // The administrator (the first account on this server) removes Bob's message in a chat with him.
  const adminPage = await login(browser, `admin${run}`);
  await openDirect(adminPage, bob);
  await selectConversation(bobPage, `admin${run}`);
  await send(bobPage, 'rude remark');
  const remark = adminPage.locator('.bubble:not(.mine)', { hasText: 'rude remark' });
  await expect(remark).toBeVisible();
  adminPage.once('dialog', (d) => void d.accept());
  await remark.hover();
  await remark.getByTitle('Message actions').click();
  await expect(adminPage.getByRole('button', { name: 'Edit' })).toHaveCount(0);
  await adminPage.getByRole('button', { name: 'Delete' }).click();
  await expect(adminPage.locator('.bubble', { hasText: 'rude remark' })).toHaveCount(0);
  await expect(bobPage.locator('.bubble', { hasText: 'rude remark' })).toHaveCount(0, { timeout: 10_000 });
});
