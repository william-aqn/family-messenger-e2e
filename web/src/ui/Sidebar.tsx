import { useState } from 'preact/hooks';
import { wsClient } from '../api/ws';
import { t } from '../i18n';
import { conversationTitle, selectedId, session, sortedConversations, usernameOf } from '../state/model';
import { NewConversation } from './NewConversation';
import { Settings } from './Settings';

function formatTime(ts: number): string {
  const d = new Date(ts);
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}

export function Sidebar() {
  const [dialog, setDialog] = useState<'new' | 'settings' | null>(null);
  const me = session.value!;
  const status = wsClient.status.value;
  return (
    <aside class="sidebar">
      <header class="sidebar-header">
        <div class="me">
          <span class={`dot ${status}`} title={status} />
          <strong>@{me.username}</strong>
        </div>
        <div class="actions">
          <button title={t('new_chat')} onClick={() => setDialog('new')}>
            ＋
          </button>
          <button title={t('settings')} onClick={() => setDialog('settings')}>
            ⚙
          </button>
        </div>
      </header>
      <ul class="conv-list">
        {sortedConversations.value.length === 0 && <li class="muted empty">{t('no_conversations')}</li>}
        {sortedConversations.value.map((c) => {
          const unread = Math.max(0, c.lastSeq - c.readSeq);
          return (
            <li key={c.id} class={selectedId.value === c.id ? 'selected' : ''} onClick={() => (selectedId.value = c.id)}>
              <div class="conv-row">
                <span class="conv-title">
                  {c.kind === 'group' ? '👥 ' : ''}
                  {conversationTitle(c, me.accountId)}
                  {c.retentionSeconds > 0 && <span class="muted"> ⏱</span>}
                </span>
                {c.lastMessage && <span class="conv-time muted">{formatTime(c.lastMessage.ts)}</span>}
              </div>
              <div class="conv-row">
                <span class="conv-preview muted">
                  {c.lastMessage ? `${c.kind === 'group' ? usernameOf(c.lastMessage.sender, me.accountId) + ': ' : ''}${c.lastMessage.text}` : ''}
                </span>
                {unread > 0 && <span class="badge">{unread}</span>}
              </div>
            </li>
          );
        })}
      </ul>
      {dialog === 'new' && <NewConversation onClose={() => setDialog(null)} />}
      {dialog === 'settings' && <Settings onClose={() => setDialog(null)} />}
    </aside>
  );
}
