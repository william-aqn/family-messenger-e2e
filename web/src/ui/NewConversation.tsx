import { useEffect, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { DirectoryUser } from '../api/types';
import { describeError, t } from '../i18n';
import { createGroup } from '../state/messaging';
import { serverSettings, session } from '../state/model';
import { Icon } from './Icons';

const MAX_SUGGESTIONS = 12;

/** Usernames from the server's directory matching what is being typed. */
function Suggestions({ users, query, exclude, onPick }: { users: DirectoryUser[] | null; query: string; exclude: Set<string>; onPick: (u: DirectoryUser) => void }) {
  if (!users) return null;
  const q = query.trim().replace(/^@/, '').toLowerCase();
  const matches = users.filter((u) => {
    const name = u.username.toLowerCase();
    return name.startsWith(q) && name !== q && !exclude.has(name);
  });
  if (!matches.length) return null;
  return (
    <div class="suggestions">
      {matches.slice(0, MAX_SUGGESTIONS).map((u) => (
        <button type="button" key={u.id} onClick={() => onPick(u)} title={u.display_name || u.username}>
          {u.is_bot && <Icon name="bot" size={16} />}
          {u.username}
        </button>
      ))}
      {matches.length > MAX_SUGGESTIONS && <span class="muted">{t('more_users', { n: matches.length - MAX_SUGGESTIONS })}</span>}
    </div>
  );
}

const SEPARATOR = /[\s,]+/;

export function NewConversation({ onClose }: { onClose: () => void }) {
  const [name, setName] = useState('');
  const [members, setMembers] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [directory, setDirectory] = useState<DirectoryUser[] | null>(null);
  const directoryOn = serverSettings.value?.user_directory !== false;

  useEffect(() => {
    if (!directoryOn) return;
    let cancelled = false;
    const me = session.value?.accountId;
    http
      .users('')
      .then((r) => {
        if (!cancelled) setDirectory(r.users.filter((u) => u.id !== me));
      })
      .catch(() => {
        // Disabled meanwhile or unreachable: the dialog works without suggestions.
        if (!cancelled) setDirectory(null);
      });
    return () => {
      cancelled = true;
    };
  }, [directoryOn]);

  const submit = async (e: Event) => {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      await createGroup(name, members.split(SEPARATOR).filter(Boolean));
      onClose();
    } catch (err) {
      setError(describeError(err));
    } finally {
      setBusy(false);
    }
  };

  // Group members: complete names before the last separator, the last token is being typed.
  const tokens = members.split(SEPARATOR).filter(Boolean);
  const typing = members.length > 0 && !/[\s,]$/.test(members) ? (tokens[tokens.length - 1] ?? '') : '';
  const chosen = new Set((typing ? tokens.slice(0, -1) : tokens).map((x) => x.replace(/^@/, '').toLowerCase()));
  const pickMember = (u: DirectoryUser) => {
    const done = typing ? tokens.slice(0, -1) : tokens;
    setMembers([...done, u.username].join(', ') + ', ');
  };

  return (
    <div class="modal-backdrop" onClick={onClose}>
      <form class="card modal" onClick={(e) => e.stopPropagation()} onSubmit={submit}>
        <div class="modal-head">
          <h2>{t('new_group')}</h2>
          <button type="button" class="icon-btn" title={t('close')} onClick={onClose}>
            <Icon name="x" size={20} />
          </button>
        </div>
        {/* The Direct tab is gone: a one-to-one chat starts from the search,
            where you can see the person before writing to them. */}
        <div class="notice small neutral">
          <Icon name="search" size={16} />
          {t('dm_from_search_hint')}
        </div>
        <label>
          {t('group_name')}
          <input value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} placeholder={t('group_name_placeholder')} required autofocus />
        </label>
        <label>
          {t('members')} <span class="muted">{t('members_hint')}</span>
          <input value={members} onInput={(e) => setMembers((e.target as HTMLInputElement).value)} placeholder="bob, carol" autocomplete="off" />
        </label>
        <Suggestions users={directory} query={typing} exclude={chosen} onPick={pickMember} />
        {error && (
          <div class="error">
            <Icon name="alert" size={16} />
            {error}
          </div>
        )}
        <div class="row end">
          <button type="button" onClick={onClose}>
            {t('cancel')}
          </button>
          <button type="submit" class={busy ? 'primary busy' : 'primary'} disabled={busy}>
            {busy && <span class="spinner" />}
            {busy ? t('creating') : t('create')}
          </button>
        </div>
      </form>
    </div>
  );
}
