import { useState } from 'preact/hooks';
import { fingerprint } from '../crypto/fingerprint';
import { describeError, t } from '../i18n';
import { acceptNewKeys, addMember, removeMember, renameGroup, setRetention, setVerified, unverifiedMembers } from '../state/messaging';
import { contacts, session } from '../state/model';
import { keys } from '../state/session';
import type { Conversation } from '../store/db';

const RETENTION_OPTIONS = [0, 3600, 86400, 7 * 86400, 30 * 86400];

export function MemberPanel({ conv, onClose }: { conv: Conversation; onClose: () => void }) {
  const me = session.value!;
  const myKeys = keys.value!;
  const [newMember, setNewMember] = useState('');
  const [newName, setNewName] = useState(conv.name);
  const [error, setError] = useState<string | null>(null);
  const unverified = new Set(unverifiedMembers(conv));
  const isOwner = conv.role === 'owner';
  const canSetRetention = conv.kind === 'direct' || isOwner;

  const run = async (fn: () => Promise<void>) => {
    setError(null);
    try {
      await fn();
    } catch (e) {
      setError(describeError(e));
    }
  };

  const retentionLabel = (s: number) => {
    switch (s) {
      case 0:
        return t('retention_off');
      case 3600:
        return t('duration_1h');
      case 86400:
        return t('duration_1d');
      case 7 * 86400:
        return t('duration_1w');
      case 30 * 86400:
        return t('duration_30d');
      default:
        return t('duration_custom', { n: s });
    }
  };
  const retentionOptions = RETENTION_OPTIONS.includes(conv.retentionSeconds) ? RETENTION_OPTIONS : [...RETENTION_OPTIONS, conv.retentionSeconds];

  return (
    <aside class="panel">
      <header>
        <strong>{conv.kind === 'group' ? t('members') : t('security')}</strong>
        <button onClick={onClose}>✕</button>
      </header>
      <p class="muted small">{t('safety_hint')}</p>
      <div class="member">
        <div class="member-name">
          @{me.username} ({t('you')})
        </div>
        <code class="fp">{fingerprint(myKeys.signPub, myKeys.encPub)}</code>
      </div>
      {conv.serverMembers
        .filter((id) => id !== me.accountId)
        .map((id) => {
          const c = contacts.value.get(id);
          if (!c) return null;
          return (
            <div class="member" key={id}>
              <div class="member-name">
                @{c.username}
                {c.isBot && <span class="tag bot">🤖 {t('bot')}</span>}
                {c.verified && !c.isBot && <span class="tag ok">{t('verified')}</span>}
                {unverified.has(id) && <span class="tag warn">{t('not_in_roster')}</span>}
                {c.pendingKeys && <span class="tag bad">{t('keys_changed')}</span>}
              </div>
              <code class="fp">{fingerprint(c.signPub, c.encPub)}</code>
              {c.pendingKeys && (
                <div class="row">
                  <code class="fp small">
                    {t('new_keys')} {fingerprint(c.pendingKeys.signPub, c.pendingKeys.encPub)}
                  </code>
                  <button onClick={() => run(() => acceptNewKeys(id))}>{t('accept_new_keys')}</button>
                </div>
              )}
              <div class="row">
                {!c.isBot && (
                  <label class="check">
                    <input type="checkbox" checked={c.verified} onChange={(e) => run(() => setVerified(id, (e.target as HTMLInputElement).checked))} />
                    {t('i_verified')}
                  </label>
                )}
                {conv.kind === 'group' && isOwner && (
                  <button class="danger" onClick={() => run(() => removeMember(conv.id, id))}>
                    {t('remove')}
                  </button>
                )}
              </div>
            </div>
          );
        })}
      <div class="section">
        <div class="muted small">⏱ {t('disappearing_messages')}</div>
        <select
          value={conv.retentionSeconds}
          disabled={!canSetRetention}
          onChange={(e) => run(() => setRetention(conv.id, Number((e.target as HTMLSelectElement).value)))}
        >
          {retentionOptions.map((s) => (
            <option key={s} value={s}>
              {retentionLabel(s)}
            </option>
          ))}
        </select>
        {!canSetRetention && <span class="muted small">{t('retention_owner_only')}</span>}
      </div>
      {conv.kind === 'group' && (
        <>
          {isOwner && (
            <form
              class="row"
              onSubmit={(e) => {
                e.preventDefault();
                void run(async () => {
                  await addMember(conv.id, newMember);
                  setNewMember('');
                });
              }}
            >
              <input value={newMember} onInput={(e) => setNewMember((e.target as HTMLInputElement).value)} placeholder={t('username_to_add')} />
              <button type="submit" disabled={!newMember.trim()}>
                {t('add')}
              </button>
            </form>
          )}
          <form
            class="row"
            onSubmit={(e) => {
              e.preventDefault();
              void run(() => renameGroup(conv.id, newName));
            }}
          >
            <input value={newName} onInput={(e) => setNewName((e.target as HTMLInputElement).value)} placeholder={t('group_name_field')} />
            <button type="submit" disabled={!newName.trim() || newName.trim() === conv.name}>
              {t('rename')}
            </button>
          </form>
          <button class="danger" onClick={() => run(() => removeMember(conv.id, me.accountId))}>
            {t('leave_group')}
          </button>
        </>
      )}
      {error && <div class="error">{error}</div>}
    </aside>
  );
}
