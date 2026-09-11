import { useState } from 'preact/hooks';
import { wsClient } from '../api/ws';
import { formatWhen, t } from '../i18n';
import { conversationTitle, hasBot, selectedId, session, sortedConversations, usernameOf } from '../state/model';
import { searching } from '../state/search';
import { Icon } from './Icons';
import { SearchBox, SearchResults } from './Search';
import { NewConversation } from './NewConversation';
import { Settings } from './Settings';

export function Sidebar() {
  const [dialog, setDialog] = useState<'new' | 'settings' | null>(null);
  const me = session.value!;
  const status = wsClient.status.value;
  return (
    <aside class="sidebar">
      {/* Who you are and whether the socket is up. The product name, the lock
          and the separate account row are gone: the window title says the one,
          and the server version moved into the settings modal. */}
      <header class="sidebar-header">
        {/* Only in the one-column layout (M02): on the desktop the window
            title already says what this is. */}
        <Icon name="lock" size={16} class="brand-lock" />
        <div class="who">
          <strong>@{me.username}</strong>
          <span class="presence">
            <span class={`dot ${status}`} />
            {t(`status_${status}` as 'status_online')}
          </span>
        </div>
        <div class="actions">
          <button type="button" class="icon-btn" title={t('new_group')} onClick={() => setDialog('new')}>
            <Icon name="plus" size={20} />
          </button>
          <button type="button" class="icon-btn" title={t('settings')} onClick={() => setDialog('settings')}>
            <Icon name="settings" size={20} />
          </button>
        </div>
      </header>
      <SearchBox />
      {searching.value ? (
        <SearchResults />
      ) : (
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
                  {c.lastMessage && <span class="conv-time">{formatWhen(c.lastMessage.ts)}</span>}
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
      )}
      {dialog === 'new' && <NewConversation onClose={() => setDialog(null)} />}
      {dialog === 'settings' && <Settings onClose={() => setDialog(null)} />}
    </aside>
  );
}
