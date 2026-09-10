import { useState } from 'preact/hooks';
import { wsClient } from '../api/ws';
import { t } from '../i18n';
import { conversationTitle, hasBot, selectedId, session, sortedConversations, usernameOf } from '../state/model';
import { Icon } from './Icons';
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
        <Icon name="lock" size={16} />
        <span class="brand">{t('app_name')}</span>
        <div class="actions">
          <button type="button" class="icon-btn" title={t('new_chat')} onClick={() => setDialog('new')}>
            <Icon name="plus" size={20} />
          </button>
          <button type="button" class="icon-btn" title={t('settings')} onClick={() => setDialog('settings')}>
            <Icon name="settings" size={20} />
          </button>
        </div>
      </header>
      <div class="me">
        <span class={`dot ${status}`} title={status} />
        <strong>@{me.username}</strong>
      </div>
      <ul class="conv-list">
        {sortedConversations.value.length === 0 && (
          <li class="muted empty">
            <Icon name="message" size={24} />
            {t('no_conversations')}
          </li>
        )}
        {sortedConversations.value.map((c) => {
          const unread = Math.max(0, c.lastSeq - c.readSeq);
          const isGroup = c.kind === 'group';
          const isBot = !isGroup && hasBot(c);
          const title = conversationTitle(c, me.accountId);
          return (
            <li key={c.id} class={selectedId.value === c.id ? 'selected' : ''} onClick={() => (selectedId.value = c.id)}>
              <div class="conv-row">
                {isGroup && <Icon name="users" size={16} />}
                {isBot && <Icon name="bot" size={16} />}
                <span class="conv-title">{title}</span>
                {c.retentionSeconds > 0 && <Icon name="timer" size={16} />}
                {c.lastMessage && <span class="conv-time">{formatTime(c.lastMessage.ts)}</span>}
              </div>
              <div class="conv-row">
                <span class="conv-preview">
                  {c.lastMessage ? `${isGroup ? usernameOf(c.lastMessage.sender, me.accountId) + ': ' : ''}${c.lastMessage.text}` : ''}
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
