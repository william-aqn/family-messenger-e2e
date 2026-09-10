import { useEffect, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { BotView } from '../api/types';
import { describeError, t } from '../i18n';
import { openDirectWith } from '../state/messaging';
import { serverSettings, showToast } from '../state/model';
import { Icon } from './Icons';

const BOT_API_DOCS = 'https://github.com/william-aqn/family-messenger-e2e/blob/main/docs/BOTS.md';

/** One line of the one-time credentials block: label, value, "Copy". */
function CredRow({ label, value }: { label: string; value: string }) {
  return (
    <div class="cred-row">
      <span class="field-label">{label}</span>
      <code>{value}</code>
      <button
        type="button"
        class="small"
        onClick={() =>
          navigator.clipboard
            .writeText(value)
            .then(() => showToast(t('copied')))
            .catch(() => {})
        }
      >
        {/* The board draws 14; the Icon scale is 12/16/20/…, so 16 is the size. */}
        <Icon name="copy" size={16} />
        {t('copy')}
      </button>
    </div>
  );
}

/**
 * The in-app replacement for `confirm()`: the same small modal the chat uses
 * before deleting a message. Local to this file on purpose — a shared
 * <ConfirmDialog> is a follow-up, once every screen has landed.
 */
function ConfirmDialog({ question, confirmLabel, onCancel, onConfirm }: { question: string; confirmLabel: string; onCancel: () => void; onConfirm: () => void }) {
  return (
    <div
      class="modal-backdrop"
      onClick={(e) => {
        e.stopPropagation();
        onCancel();
      }}
    >
      <div class="card modal confirm" onClick={(e) => e.stopPropagation()}>
        <h3>{question}</h3>
        <div class="row end">
          <button type="button" onClick={onCancel}>
            {t('cancel')}
          </button>
          <button type="button" class="danger fill" onClick={onConfirm}>
            <Icon name="trash" size={20} />
            {confirmLabel}
          </button>
        </div>
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
  const [confirmDelete, setConfirmDelete] = useState<BotView | null>(null);
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
        <div class="modal-head">
          <h2>{t('my_bots')}</h2>
          <button type="button" class="icon-btn" title={t('close')} onClick={onClose}>
            <Icon name="x" size={20} />
          </button>
        </div>
        <p class="intro">{t('bots_intro')}</p>
        {creds && (
          <div class="creds">
            <div class="row">
              <span class="block-title grow">
                {t('bot_credentials')} @{creds.username}
              </span>
              <span class="hint">{t('bot_credentials_hint')}</span>
            </div>
            <CredRow label={t('token')} value={creds.token} />
            <CredRow label={t('webhook_secret')} value={creds.secret} />
            <div class="row end">
              <button type="button" class="small" onClick={() => setCreds(null)}>
                {t('close')}
              </button>
            </div>
          </div>
        )}
        {bots.length > 0 && (
          <div>
            {bots.map((b) =>
              editing?.id === b.id ? (
                <form
                  class="bot-row"
                  key={b.id}
                  onSubmit={(e) => {
                    e.preventDefault();
                    void run(async () => {
                      await http.updateBot(b.id, { display_name: editing.display_name, webhook_url: editing.webhook_url });
                      setEditing(null);
                      await load();
                    });
                  }}
                >
                  <div class="grow">
                    <input value={editing.display_name} onInput={(e) => setEditing({ ...editing, display_name: (e.target as HTMLInputElement).value })} placeholder={t('bot_display_name')} />
                    <input value={editing.webhook_url} onInput={(e) => setEditing({ ...editing, webhook_url: (e.target as HTMLInputElement).value })} placeholder="https://example.com/hook" />
                  </div>
                  <div class="link-row">
                    <button type="button" class="link" onClick={() => setEditing(null)}>
                      {t('cancel')}
                    </button>
                    <button type="submit" class="link strong" disabled={busy}>
                      {t('save')}
                    </button>
                  </div>
                </form>
              ) : (
                <div class="bot-row" key={b.id}>
                  <div class="grow">
                    <span class="bot-name">
                      @{b.username} <span class="muted">· {b.display_name}</span>
                    </span>
                    <span class="bot-hook">
                      {t('webhook_url')}: {b.webhook_url || t('webhook_none')}
                    </span>
                  </div>
                  <div class="link-row">
                    <button
                      type="button"
                      class="link"
                      onClick={() =>
                        void run(async () => {
                          await openDirectWith(b.id);
                          onDone();
                        })
                      }
                    >
                      {t('chat_with_bot')}
                    </button>
                    <button type="button" class="link" onClick={() => setEditing(b)}>
                      {t('rename')}
                    </button>
                    <button
                      type="button"
                      class="link"
                      onClick={() =>
                        void run(async () => {
                          const res = await http.rotateBot(b.id);
                          setCreds({ username: b.username, token: res.token, secret: res.webhook_secret });
                        })
                      }
                    >
                      {t('rotate_credentials')}
                    </button>
                    <button type="button" class="link danger" onClick={() => setConfirmDelete(b)}>
                      {t('delete_bot')}
                    </button>
                  </div>
                </div>
              ),
            )}
          </div>
        )}
        {bots.length === 0 && <p class="note">{t('no_bots')}</p>}
        {error && (
          <div class="error">
            <Icon name="alert" size={16} />
            {error}
          </div>
        )}
        {allowed ? (
          <form class="section ruled" onSubmit={create}>
            <span class="block-title">{t('create_bot')}</span>
            <div class="form-grid bots">
              <label>
                {t('bot_username')}
                <input value={username} onInput={(e) => setUsername((e.target as HTMLInputElement).value)} placeholder="weatherbot" required minLength={4} maxLength={32} pattern="[A-Za-z0-9._]*bot" />
              </label>
              <label>
                {t('bot_display_name')}
                <input value={displayName} onInput={(e) => setDisplayName((e.target as HTMLInputElement).value)} placeholder={t('bot_display_name')} />
              </label>
              <label>
                {t('webhook_url')}
                <input value={webhook} onInput={(e) => setWebhook((e.target as HTMLInputElement).value)} placeholder="https://example.com/hook" />
                <span class="hint">{t('webhook_hint')}</span>
              </label>
            </div>
            <div class="row gap-16">
              <button type="submit" class={busy ? 'primary busy' : 'primary'} disabled={busy}>
                {busy && <span class="spinner" />}
                {t('create_bot')}
              </button>
              <a href={BOT_API_DOCS} target="_blank" rel="noreferrer">
                {t('bot_api_docs')}
              </a>
              <span class="grow" />
              <button type="button" onClick={onClose}>
                {t('back')}
              </button>
            </div>
          </form>
        ) : (
          <div class="section ruled">
            <p class="note">{t('bots_disabled')}</p>
            <div class="row gap-16">
              <a href={BOT_API_DOCS} target="_blank" rel="noreferrer">
                {t('bot_api_docs')}
              </a>
              <span class="grow" />
              <button type="button" onClick={onClose}>
                {t('back')}
              </button>
            </div>
          </div>
        )}
        {confirmDelete && (
          <ConfirmDialog
            question={t('confirm_delete_bot', { name: confirmDelete.username })}
            confirmLabel={t('delete')}
            onCancel={() => setConfirmDelete(null)}
            onConfirm={() => {
              const bot = confirmDelete;
              setConfirmDelete(null);
              void run(async () => {
                await http.deleteBot(bot.id);
                await load();
              });
            }}
          />
        )}
      </div>
    </div>
  );
}
