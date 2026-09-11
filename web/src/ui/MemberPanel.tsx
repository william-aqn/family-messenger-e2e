import { useState } from 'preact/hooks';
import { fingerprint } from '../crypto/fingerprint';
import { describeError, t } from '../i18n';
import { acceptNewKeys, addMember, removeMember, renameGroup, setRetention, setVerified, unverifiedMembers } from '../state/messaging';
import { contacts, session } from '../state/model';
import { keys } from '../state/session';
import type { Conversation } from '../store/db';
import { Icon } from './Icons';

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
  const title = conv.kind === 'group' ? t('members') : t('security');

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
      <div class="panel-head">
        <h3>{title}</h3>
        <button type="button" class="icon-btn" title={t('close')} onClick={onClose}>
          <Icon name="x" size={20} />
        </button>
      </div>
      {/* The phone sheet has no head of its own — the chat header serves as one. */}
      <div class="panel-title">{title}</div>
      {/* Only the roster scrolls: the timer and the group actions below — "Leave
          group" among them — stay where they can be reached. */}
      <div class="panel-scroll">
      <p class="panel-hint">{t('safety_hint')}</p>
      <div class="member">
        <div class="member-name">
          <span>
            @{me.username} <span class="muted">({t('you')})</span>
          </span>
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
                <span>@{c.username}</span>
                <span class="tags">
                  {c.isBot && (
                    <span class="tag bot">
                      <Icon name="bot" size={12} />
                      {t('bot')}
                    </span>
                  )}
                  {c.verified && !c.isBot && <span class="tag ok">{t('verified')}</span>}
                  {unverified.has(id) && <span class="tag warn">{t('not_in_roster')}</span>}
                  {c.pendingKeys && <span class="tag bad">{t('keys_changed')}</span>}
                </span>
                {conv.kind === 'group' && isOwner && (
                  <button type="button" class="link danger" onClick={() => run(() => removeMember(conv.id, id))}>
                    {t('remove')}
                  </button>
                )}
              </div>
              {c.pendingKeys ? (
                <>
                  <code class="fp old">{fingerprint(c.signPub, c.encPub)}</code>
                  <code class="fp">
                    <span class="fp-label">{t('new_keys')}</span> {fingerprint(c.pendingKeys.signPub, c.pendingKeys.encPub)}
                  </code>
                  <button type="button" class="soft small" onClick={() => run(() => acceptNewKeys(id))}>
                    {t('accept_new_keys')}
                  </button>
                </>
              ) : (
                <code class="fp">{fingerprint(c.signPub, c.encPub)}</code>
              )}
              {!c.isBot && (
                <label class="check">
                  <input type="checkbox" checked={c.verified} onChange={(e) => run(() => setVerified(id, (e.target as HTMLInputElement).checked))} />
                  {t('i_verified')}
                </label>
              )}
            </div>
          );
        })}
      </div>
      <div class="section">
        <span class="muted">
          <Icon name="timer" size={16} />
          {t('disappearing_messages')}
        </span>
        <select
          class="small"
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
        {!canSetRetention && <p class="hint">{t('retention_owner_only')}</p>}
      </div>
      {conv.kind === 'group' && (
        <div class="section group">
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
              <input
                class="small"
                value={newMember}
                onInput={(e) => setNewMember((e.target as HTMLInputElement).value)}
                placeholder={t('username_to_add')}
              />
              <button type="submit" class="small" disabled={!newMember.trim()}>
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
            <input class="small" value={newName} onInput={(e) => setNewName((e.target as HTMLInputElement).value)} placeholder={t('group_name_field')} />
            <button type="submit" class="small" disabled={!newName.trim() || newName.trim() === conv.name}>
              {t('rename')}
            </button>
          </form>
          <button type="button" class="danger" onClick={() => run(() => removeMember(conv.id, me.accountId))}>
            {t('leave_group')}
          </button>
        </div>
      )}
      {error && (
        <div class="section">
          <div class="error">
            <Icon name="alert" size={16} />
            {error}
          </div>
        </div>
      )}
    </aside>
  );
}
