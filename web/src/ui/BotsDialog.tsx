import { useEffect, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { BotView } from '../api/types';
import { describeError, t } from '../i18n';
import { openDirectWith } from '../state/messaging';
import { serverSettings, showToast } from '../state/model';

function CopyField({ label, value }: { label: string; value: string }) {
  return (
    <div class="section">
      <div class="muted small">{label}</div>
      <div class="row">
        <code class="fp">{value}</code>
        <button
          onClick={() =>
            navigator.clipboard
              .writeText(value)
              .then(() => showToast(t('copied')))
              .catch(() => {})
          }
        >
          {t('copy')}
        </button>
      </div>
    </div>
  );
}

export function BotsDialog({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [bots, setBots] = useState<BotView[]>([]);
  const [username, setUsername] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [webhook, setWebhook] = useState('');
  const [creds, setCreds] = useState<{ username: string; token: string; secret: string } | null>(null);
  const [editing, setEditing] = useState<BotView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const allowed = serverSettings.value?.allow_bots ?? true;

  const load = () =>
    http
      .bots()
      .then((r) => setBots(r.bots))
      .catch((e) => setError(describeError(e)));
  useEffect(() => void load(), []);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(describeError(e));
    } finally {
      setBusy(false);
    }
  };

  const create = (e: Event) => {
    e.preventDefault();
    void run(async () => {
      const res = await http.createBot({ username: username.trim(), display_name: displayName.trim(), webhook_url: webhook.trim() });
      setCreds({ username: res.bot.username, token: res.token, secret: res.webhook_secret });
      setUsername('');
      setDisplayName('');
      setWebhook('');
      await load();
    });
  };

  return (
    <div class="modal-backdrop" onClick={onClose}>
      <div class="card modal wide" onClick={(e) => e.stopPropagation()}>
        <h2>🤖 {t('my_bots')}</h2>
        <p class="muted small">{t('bots_intro')}</p>
        {creds && (
          <div class="creds">
            <strong>
              {t('bot_credentials')}: @{creds.username}
            </strong>
            <div class="hint">{t('bot_credentials_hint')}</div>
            <CopyField label={t('token')} value={creds.token} />
            <CopyField label={t('webhook_secret')} value={creds.secret} />
            <button onClick={() => setCreds(null)}>{t('close')}</button>
          </div>
        )}
        {bots.length === 0 && <div class="muted">{t('no_bots')}</div>}
        {bots.map((b) => (
          <div class="member" key={b.id}>
            <div class="member-name">
              @{b.username} <span class="muted">· {b.display_name}</span>
            </div>
            {editing?.id === b.id ? (
              <form
                class="section"
                onSubmit={(e) => {
                  e.preventDefault();
                  void run(async () => {
                    await http.updateBot(b.id, { display_name: editing.display_name, webhook_url: editing.webhook_url });
                    setEditing(null);
                    await load();
                  });
                }}
              >
                <input value={editing.display_name} onInput={(e) => setEditing({ ...editing, display_name: (e.target as HTMLInputElement).value })} placeholder={t('bot_display_name')} />
                <input value={editing.webhook_url} onInput={(e) => setEditing({ ...editing, webhook_url: (e.target as HTMLInputElement).value })} placeholder="https://example.com/hook" />
                <div class="row end">
                  <button type="button" onClick={() => setEditing(null)}>
                    {t('cancel')}
                  </button>
                  <button type="submit" class="primary" disabled={busy}>
                    {t('save')}
                  </button>
                </div>
              </form>
            ) : (
              <>
                <div class="muted small">
                  {t('webhook_url')}: {b.webhook_url || '—'}
                </div>
                <div class="row wrap">
                  <button
                    onClick={() =>
                      void run(async () => {
                        await openDirectWith(b.id);
                        onDone();
                      })
                    }
                  >
                    {t('chat_with_bot')}
                  </button>
                  <button onClick={() => setEditing(b)}>{t('rename')}</button>
                  <button
                    onClick={() =>
                      void run(async () => {
                        const res = await http.rotateBot(b.id);
                        setCreds({ username: b.username, token: res.token, secret: res.webhook_secret });
                      })
                    }
                  >
                    {t('rotate_credentials')}
                  </button>
                  <button
                    class="danger"
                    onClick={() => {
                      if (!confirm(t('confirm_delete_bot', { name: b.username }))) return;
                      void run(async () => {
                        await http.deleteBot(b.id);
                        await load();
                      });
                    }}
                  >
                    {t('delete_bot')}
                  </button>
                </div>
              </>
            )}
          </div>
        ))}
        {allowed ? (
          <form class="section" onSubmit={create}>
            <div class="muted small">{t('create_bot')}</div>
            <input value={username} onInput={(e) => setUsername((e.target as HTMLInputElement).value)} placeholder="weatherbot" required minLength={4} maxLength={32} pattern="[A-Za-z0-9._]*bot" />
            <input value={displayName} onInput={(e) => setDisplayName((e.target as HTMLInputElement).value)} placeholder={t('bot_display_name')} />
            <input value={webhook} onInput={(e) => setWebhook((e.target as HTMLInputElement).value)} placeholder="https://example.com/hook" />
            <div class="muted small">{t('webhook_hint')}</div>
            <button type="submit" class="primary" disabled={busy}>
              {t('create_bot')}
            </button>
          </form>
        ) : (
          <div class="muted">{t('bots_disabled')}</div>
        )}
        <a class="small" href="https://github.com/william-aqn/family-messenger-e2e/blob/main/docs/BOTS.md" target="_blank" rel="noreferrer">
          {t('bot_api_docs')}
        </a>
        {error && <div class="error">{error}</div>}
        <div class="row end">
          <button onClick={onClose}>{t('back')}</button>
        </div>
      </div>
    </div>
  );
}
