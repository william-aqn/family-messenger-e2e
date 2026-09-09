import { useState } from 'preact/hooks';
import { describeError, t } from '../i18n';
import { createDirect, createGroup } from '../state/messaging';

export function NewConversation({ onClose }: { onClose: () => void }) {
  const [kind, setKind] = useState<'direct' | 'group'>('direct');
  const [username, setUsername] = useState('');
  const [name, setName] = useState('');
  const [members, setMembers] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: Event) => {
    e.preventDefault();
    setError(null);
    setBusy(true);
    try {
      if (kind === 'direct') await createDirect(username);
      else await createGroup(name, members.split(/[\s,]+/).filter(Boolean));
      onClose();
    } catch (err) {
      setError(describeError(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div class="modal-backdrop" onClick={onClose}>
      <form class="card modal" onClick={(e) => e.stopPropagation()} onSubmit={submit}>
        <h2>{t('new_conversation')}</h2>
        <div class="tabs">
          <button type="button" class={kind === 'direct' ? 'active' : ''} onClick={() => setKind('direct')}>
            {t('direct')}
          </button>
          <button type="button" class={kind === 'group' ? 'active' : ''} onClick={() => setKind('group')}>
            {t('group')}
          </button>
        </div>
        {kind === 'direct' ? (
          <label>
            {t('username')}
            <input value={username} onInput={(e) => setUsername((e.target as HTMLInputElement).value)} placeholder="bob" required autofocus />
          </label>
        ) : (
          <>
            <label>
              {t('group_name')}
              <input value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} placeholder={t('group_name_placeholder')} required autofocus />
            </label>
            <label>
              {t('members')} <span class="muted">{t('members_hint')}</span>
              <input value={members} onInput={(e) => setMembers((e.target as HTMLInputElement).value)} placeholder="bob, carol" />
            </label>
          </>
        )}
        {error && <div class="error">{error}</div>}
        <div class="row end">
          <button type="button" onClick={onClose}>
            {t('cancel')}
          </button>
          <button type="submit" class="primary" disabled={busy}>
            {busy ? t('creating') : t('create')}
          </button>
        </div>
      </form>
    </div>
  );
}
