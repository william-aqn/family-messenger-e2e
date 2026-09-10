import type { ComponentChildren } from 'preact';
import { useEffect, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { AdminSettings, AdminStats, AdminUser, InviteView } from '../api/types';
import { describeError, t } from '../i18n';
import { formatSize } from '../state/attachments';
import { session, showToast } from '../state/model';
import { refreshMe } from '../state/session';
import { Icon } from './Icons';

type Tab = 'overview' | 'users' | 'invites' | 'settings';

function when(ts: number): string {
  return ts ? new Date(ts * 1000).toLocaleString() : '—';
}

/**
 * The update hint carries the shell command between backticks in both
 * dictionaries; the board draws that part monospace, so the string is split on
 * them instead of being duplicated as a second key.
 */
function withCommand(text: string): ComponentChildren[] {
  return text.split('`').map((part, i) => (i % 2 === 1 ? <span class="cmd">{part}</span> : part));
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

function Overview() {
  const [stats, setStats] = useState<AdminStats | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    http.adminStats().then(setStats).catch((e) => setError(describeError(e)));
  }, []);
  const backup = async () => {
    try {
      const { bytes, filename } = await http.adminBackup();
      const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      const url = URL.createObjectURL(new Blob([buffer], { type: 'application/vnd.sqlite3' }));
      const a = document.createElement('a');
      a.href = url;
      a.download = filename ?? 'family-messenger-backup.db';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
    } catch (e) {
      setError(describeError(e));
    }
  };
  if (error)
    return (
      <div class="error">
        <Icon name="alert" size={16} />
        {error}
      </div>
    );
  if (!stats)
    return (
      <div class="placeholder">
        <Icon name="lock" size={24} />
        {t('loading')}
      </div>
    );
  const uptime = `${Math.floor(stats.uptime_seconds / 3600)}h ${Math.floor((stats.uptime_seconds % 3600) / 60)}m`;
  const startedAt = new Date((Date.now() / 1000 - stats.uptime_seconds) * 1000).toLocaleDateString();
  // Ten tiles, five to a row: the bot count and the device total ride under the
  // value they belong to instead of taking tiles of their own.
  const cells: [label: string, value: string, sub?: string][] = [
    [t('stat_users'), String(stats.accounts), `${t('stat_bots')}: ${stats.bots}`],
    [t('stat_conversations'), String(stats.conversations)],
    [t('stat_messages'), String(stats.messages)],
    [t('stat_attachments'), String(stats.blobs), formatSize(stats.blob_bytes)],
    [t('stat_online'), String(stats.online_devices), t('stat_of_devices', { n: stats.devices })],
    [t('stat_db'), formatSize(stats.db_bytes)],
    [t('stat_uptime'), uptime, t('stat_since', { date: startedAt })],
    [t('stat_turn'), stats.turn_enabled ? t('configured') : t('not_configured')],
    [t('server'), stats.version, stats.go_version],
    [t('stat_latest'), stats.latest_version ? (stats.latest_version === stats.version ? t('up_to_date') : stats.latest_version) : t('not_checked_yet')],
  ];
  const updateHint = stats.latest_version && stats.latest_version !== stats.version;
  return (
    <>
      {updateHint && (
        <div class="banner server-update">
          <Icon name="refresh" size={20} />
          <span class="grow">{withCommand(t('update_server_hint', { version: stats.latest_version }))}</span>
          <a href={stats.latest_url} target="_blank" rel="noreferrer">
            {t('release_page')}
          </a>
        </div>
      )}
      <div class="stat-grid">
        {cells.map(([label, value, sub]) => (
          <div class="stat" key={label}>
            {label}
            <div class="stat-value">{value}</div>
            {sub && <div class="stat-sub">{sub}</div>}
          </div>
        ))}
      </div>
      <div class="row gap-16">
        <button type="button" class="primary" onClick={() => void backup()}>
          <Icon name="download" size={16} />
          {t('download_backup')}
        </button>
        <span class="note">{t('backup_hint')}</span>
      </div>
    </>
  );
}

function Users() {
  const me = session.value!;
  const [q, setQ] = useState('');
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [confirmDelete, setConfirmDelete] = useState<AdminUser | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = (query = q) =>
    http
      .adminUsers(query)
      .then((r) => setUsers(r.users))
      .catch((e) => setError(describeError(e)));
  useEffect(() => void load(''), []);
  const act = (fn: () => Promise<unknown>) => {
    setError(null);
    fn()
      .then(() => load())
      .catch((e) => setError(describeError(e)));
  };
  return (
    <>
      <form
        class="row"
        onSubmit={(e) => {
          e.preventDefault();
          void load();
        }}
      >
        <input class="search grow" value={q} onInput={(e) => setQ((e.target as HTMLInputElement).value)} placeholder={t('search_users')} aria-label={t('search_users')} />
      </form>
      <div class="table-wrap">
        <table class="admin-table">
          <thead>
            <tr>
              <th>{t('col_user')}</th>
              <th>{t('col_created')}</th>
              <th>{t('col_last_seen')}</th>
              <th>{t('col_devices')}</th>
              <th>{t('col_actions')}</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id} class={u.disabled ? 'muted' : ''}>
                <td>
                  <div class="cell">
                    <div class="cell-name">
                      @{u.username}
                      {u.is_admin && <span class="tag accent">{t('flag_admin')}</span>}
                      {u.online && <span class="tag ok">{t('flag_online')}</span>}
                      {/* Drawn in --warn; `bad` stays so the e2e suite keeps its selector. */}
                      {u.disabled && <span class="tag bad warn">{t('flag_disabled')}</span>}
                      {u.is_bot && (
                        <span class="tag bot">
                          <Icon name="bot" size={12} />
                          {t('flag_bot')}
                        </span>
                      )}
                    </div>
                    {u.owner_username && <span class="cell-sub">{t('owner_of', { owner: u.owner_username })}</span>}
                  </div>
                </td>
                <td class="muted">{when(u.created_at)}</td>
                <td class="muted">{when(u.last_seen)}</td>
                <td class="muted">{u.devices}</td>
                <td>
                  {u.id !== me.accountId && (
                    <div class="link-row">
                      <button type="button" class="link" onClick={() => act(() => http.adminPatchUser(u.id, { disabled: !u.disabled }))}>
                        {u.disabled ? t('enable') : t('disable')}
                      </button>
                      {!u.is_bot && (
                        <button type="button" class="link" onClick={() => act(() => http.adminPatchUser(u.id, { is_admin: !u.is_admin }))}>
                          {u.is_admin ? t('revoke_admin') : t('make_admin')}
                        </button>
                      )}
                      <button type="button" class="link" onClick={() => act(() => http.adminLogoutUser(u.id))}>
                        {t('sign_out_everywhere')}
                      </button>
                      <button type="button" class="link danger" onClick={() => setConfirmDelete(u)}>
                        {t('delete')}
                      </button>
                    </div>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {error && (
        <div class="error">
          <Icon name="alert" size={16} />
          {error}
        </div>
      )}
      {confirmDelete && (
        <ConfirmDialog
          question={t('confirm_delete_user', { user: confirmDelete.username })}
          confirmLabel={t('delete')}
          onCancel={() => setConfirmDelete(null)}
          onConfirm={() => {
            const user = confirmDelete;
            setConfirmDelete(null);
            act(() => http.adminDeleteUser(user.id));
          }}
        />
      )}
    </>
  );
}

function Invites() {
  const [invites, setInvites] = useState<InviteView[]>([]);
  const [count, setCount] = useState(1);
  const [note, setNote] = useState('');
  const [hours, setHours] = useState(0);
  const [codes, setCodes] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const load = () =>
    http
      .adminInvites()
      .then((r) => setInvites(r.invites))
      .catch((e) => setError(describeError(e)));
  useEffect(() => void load(), []);
  const create = (e: Event) => {
    e.preventDefault();
    setError(null);
    http
      .adminCreateInvites({ count, note, expires_hours: hours })
      .then((r) => {
        setCodes(r.codes);
        return load();
      })
      .catch((err) => setError(describeError(err)));
  };
  return (
    <>
      <form class="form-grid invite" onSubmit={create}>
        <label>
          {t('invite_count')}
          <input type="number" min={1} max={100} value={count} onInput={(e) => setCount(Number((e.target as HTMLInputElement).value))} />
        </label>
        <label>
          {t('invite_note')}
          <input value={note} onInput={(e) => setNote((e.target as HTMLInputElement).value)} />
        </label>
        <label>
          {t('invite_expires_hours')}
          <input type="number" min={0} value={hours} onInput={(e) => setHours(Number((e.target as HTMLInputElement).value))} />
        </label>
        <button type="submit" class="primary">
          {t('create_invites')}
        </button>
      </form>
      {codes.length > 0 && (
        <div class="creds">
          <span class="block-title">{t('new_codes')}</span>
          <div class="code-chips">
            {codes.map((c) => (
              <span class="code-chip" key={c}>
                <code>{c}</code>
                <button
                  type="button"
                  class="icon-btn"
                  title={t('copy')}
                  onClick={() =>
                    navigator.clipboard
                      .writeText(c)
                      .then(() => showToast(t('copied')))
                      .catch(() => {})
                  }
                >
                  <Icon name="copy" size={16} />
                </button>
              </span>
            ))}
          </div>
        </div>
      )}
      <div class="table-wrap">
        <table class="admin-table">
          <thead>
            <tr>
              <th>{t('col_code')}</th>
              <th>{t('invite_note')}</th>
              <th>{t('col_used_by')}</th>
              <th>{t('col_expires')}</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {invites.map((i) => (
              <tr key={i.code}>
                <td>
                  <code class="fp">{i.code}</code>
                </td>
                <td class={i.note ? '' : 'muted'}>{i.note || '—'}</td>
                <td class={i.used_by ? '' : 'muted'}>{i.used_by ? `@${i.used_by}` : t('unused')}</td>
                <td class="muted">{i.expires_at ? when(i.expires_at) : t('never')}</td>
                <td>
                  {!i.used_by && (
                    <button
                      type="button"
                      class="link danger"
                      onClick={() =>
                        http
                          .adminDeleteInvite(i.code)
                          .then(load)
                          .catch((e) => setError(describeError(e)))
                      }
                    >
                      {t('delete')}
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {error && (
        <div class="error">
          <Icon name="alert" size={16} />
          {error}
        </div>
      )}
    </>
  );
}

function SettingsTab() {
  const [s, setS] = useState<AdminSettings | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    http.adminSettings().then(setS).catch((e) => setError(describeError(e)));
  }, []);
  if (!s)
    return error ? (
      <div class="error">
        <Icon name="alert" size={16} />
        {error}
      </div>
    ) : (
      <div class="placeholder">
        <Icon name="lock" size={24} />
        {t('loading')}
      </div>
    );
  const save = (e: Event) => {
    e.preventDefault();
    setError(null);
    http
      .adminSaveSettings(s)
      .then((saved) => {
        setS(saved);
        showToast(t('settings_saved'));
        void refreshMe();
      })
      .catch((err) => setError(describeError(err)));
  };
  const modes: [AdminSettings['registration'], string][] = [
    ['open', t('reg_open')],
    ['invite', t('reg_invite')],
    ['closed', t('reg_closed')],
  ];
  return (
    <form class="section" onSubmit={save}>
      {/* Three toggle buttons instead of a select: the group keeps the label's
          accessible name, every button stays reachable on its own. */}
      <div class="section tight">
        <span class="field-label" id="registration-mode">
          {t('registration_mode')}
        </span>
        <div class="toggle-row" role="group" aria-labelledby="registration-mode">
          {modes.map(([mode, label]) => (
            <button key={mode} type="button" class={s.registration === mode ? 'soft' : ''} aria-pressed={s.registration === mode} onClick={() => setS({ ...s, registration: mode })}>
              {label}
            </button>
          ))}
        </div>
      </div>
      <label>
        {t('announcement')}
        <textarea class="tall" value={s.announcement} rows={3} onInput={(e) => setS({ ...s, announcement: (e.target as HTMLTextAreaElement).value })} />
      </label>
      <div class="form-grid thirds">
        <label>
          {t('max_attachment_mb')}
          <input type="number" min={0} value={Math.round(s.max_attachment_bytes / 1048576)} onInput={(e) => setS({ ...s, max_attachment_bytes: Number((e.target as HTMLInputElement).value) * 1048576 })} />
        </label>
        <label>
          {t('retention_days')}
          <input type="number" min={0} max={3650} value={s.retention_days} onInput={(e) => setS({ ...s, retention_days: Number((e.target as HTMLInputElement).value) })} />
        </label>
        <label>
          {t('max_group_members')}
          <input type="number" min={2} max={100} value={s.max_group_members} onInput={(e) => setS({ ...s, max_group_members: Number((e.target as HTMLInputElement).value) })} />
        </label>
      </div>
      <label class="check large">
        <input type="checkbox" checked={s.allow_bots} onChange={(e) => setS({ ...s, allow_bots: (e.target as HTMLInputElement).checked })} />
        {t('allow_bots')}
      </label>
      <label class="check large">
        <input type="checkbox" checked={s.user_directory} onChange={(e) => setS({ ...s, user_directory: (e.target as HTMLInputElement).checked })} />
        {t('user_directory')}
      </label>
      {error && (
        <div class="error">
          <Icon name="alert" size={16} />
          {error}
        </div>
      )}
      {/* In a row so the button keeps the board's natural width, not the column's. */}
      <div class="row">
        <button type="submit" class="primary">
          {t('save')}
        </button>
      </div>
    </form>
  );
}

export function AdminPanel({ onClose }: { onClose: () => void }) {
  const [tab, setTab] = useState<Tab>('overview');
  const tabs: [Tab, string][] = [
    ['overview', t('tab_overview')],
    ['users', t('tab_users')],
    ['invites', t('tab_invites')],
    ['settings', t('tab_settings')],
  ];
  return (
    <div class="modal-backdrop" onClick={onClose}>
      <div class="card modal wide" onClick={(e) => e.stopPropagation()}>
        <div class="modal-head">
          <h2>{t('admin_panel')}</h2>
          <button type="button" class="icon-btn" title={t('close')} onClick={onClose}>
            <Icon name="x" size={20} />
          </button>
        </div>
        <div class="tabs">
          {tabs.map(([id, label]) => (
            <button key={id} type="button" class={tab === id ? 'active' : ''} onClick={() => setTab(id)}>
              {label}
            </button>
          ))}
        </div>
        {tab === 'overview' && <Overview />}
        {tab === 'users' && <Users />}
        {tab === 'invites' && <Invites />}
        {tab === 'settings' && <SettingsTab />}
      </div>
    </div>
  );
}
