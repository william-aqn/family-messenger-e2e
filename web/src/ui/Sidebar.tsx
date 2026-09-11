import { useEffect, useState } from 'preact/hooks';
import { wsClient } from '../api/ws';
import { describeError, formatWhen, t } from '../i18n';
import { hiddenChats, hideChat, mutedChats, pinnedChats, toggleMuted, togglePinned } from '../state/chatPrefs';
import { markRead, removeMember } from '../state/messaging';
import type { Conversation } from '../store/db';
import { conversationTitle, hasBot, selectedId, session, showToast, sortedConversations, usernameOf } from '../state/model';
import { searching } from '../state/search';
import { Icon } from './Icons';
import { SearchBox, SearchResults } from './Search';
import { NewConversation } from './NewConversation';
import { Settings } from './Settings';

/** The chat the menu is open for, and where on the screen it was opened. */
type Menu = { conv: Conversation; x: number; y: number };

export function Sidebar() {
  const [dialog, setDialog] = useState<'new' | 'settings' | null>(null);
  const [menu, setMenu] = useState<Menu | null>(null);
  const [confirming, setConfirming] = useState<Conversation | null>(null);
  const me = session.value!;
  const status = wsClient.status.value;
  const pins = pinnedChats.value;
  const hidden = hiddenChats.value;
  const visible = sortedConversations.value.filter((c) => !hidden.has(c.id) || c.id === selectedId.value);
  const pinned = visible.filter((c) => pins.has(c.id));
  const rest = visible.filter((c) => !pins.has(c.id));
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
          {visible.length === 0 && (
            <li class="muted empty">
              <Icon name="message" size={24} />
              {t('no_conversations')}
            </li>
          )}
          {/* The headings only appear once something is pinned (W19). */}
          {pinned.length > 0 && <li class="conv-section">{t('pinned_section')}</li>}
          {pinned.map((c) => (
            <ConvRow key={c.id} conv={c} menu={menu} onMenu={setMenu} />
          ))}
          {pinned.length > 0 && rest.length > 0 && <li class="conv-section">{t('all_chats_section')}</li>}
          {rest.map((c) => (
            <ConvRow key={c.id} conv={c} menu={menu} onMenu={setMenu} />
          ))}
        </ul>
      )}
      {menu && (
        <ChatMenu
          menu={menu}
          onClose={() => setMenu(null)}
          onDelete={() => {
            setConfirming(menu.conv);
            setMenu(null);
          }}
        />
      )}
      {confirming && <DeleteChat conv={confirming} onClose={() => setConfirming(null)} />}
      {dialog === 'new' && <NewConversation onClose={() => setDialog(null)} />}
      {dialog === 'settings' && <Settings onClose={() => setDialog(null)} />}
    </aside>
  );
}

function ConvRow({ conv: c, menu, onMenu }: { conv: Conversation; menu: Menu | null; onMenu: (m: Menu) => void }) {
  const me = session.value!;
  const unread = Math.max(0, c.lastSeq - c.readSeq);
  const isGroup = c.kind === 'group';
  const isBot = !isGroup && hasBot(c);
  const title = conversationTitle(c, me.accountId);
  const classes = [selectedId.value === c.id && 'selected', menu?.conv.id === c.id && 'menu-open'].filter(Boolean).join(' ');
  return (
    <li
      class={classes}
      onClick={() => (selectedId.value = c.id)}
      onContextMenu={(e) => {
        e.preventDefault();
        onMenu({ conv: c, x: e.clientX, y: e.clientY });
      }}
    >
      <div class="conv-row">
        {isGroup && <Icon name="users" size={16} />}
        {isBot && <Icon name="bot" size={16} />}
        <span class="conv-title">{title}</span>
        {mutedChats.value.has(c.id) && <Icon name="bell-off" size={16} />}
        {c.retentionSeconds > 0 && <Icon name="timer" size={16} />}
        {pinnedChats.value.has(c.id) && <Icon name="pin" size={16} class="pinned" />}
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
}

/** W19: the chat's own menu, on a right click anywhere in its row. */
function ChatMenu({ menu, onClose, onDelete }: { menu: Menu; onClose: () => void; onDelete: () => void }) {
  const c = menu.conv;
  const isPinned = pinnedChats.value.has(c.id);
  const isMuted = mutedChats.value.has(c.id);
  useEffect(() => {
    const close = () => onClose();
    // The next click anywhere, a key, or a scroll puts the menu away.
    document.addEventListener('click', close);
    document.addEventListener('keydown', close);
    window.addEventListener('resize', close);
    return () => {
      document.removeEventListener('click', close);
      document.removeEventListener('keydown', close);
      window.removeEventListener('resize', close);
    };
  }, [onClose]);
  const run = (fn: () => void) => (e: MouseEvent) => {
    e.stopPropagation();
    fn();
    onClose();
  };
  // Kept inside the window: the menu is 200 wide and at most five rows tall.
  const left = Math.min(menu.x, window.innerWidth - 216);
  const top = Math.min(menu.y, window.innerHeight - 200);
  return (
    <div class="popover chat-menu" style={{ left: `${left}px`, top: `${top}px` }} onClick={(e) => e.stopPropagation()}>
      <button type="button" onClick={run(() => togglePinned(c.id))}>
        <Icon name="pin" size={16} />
        {t(isPinned ? 'unpin_chat' : 'pin_chat')}
      </button>
      <button type="button" onClick={run(() => toggleMuted(c.id))}>
        <Icon name="bell-off" size={16} />
        {t(isMuted ? 'unmute_chat' : 'mute_chat')}
      </button>
      <button type="button" disabled={c.lastSeq <= c.readSeq} onClick={run(() => void markRead(c.id, c.lastSeq))}>
        <Icon name="check" size={16} />
        {t('mark_read')}
      </button>
      <button type="button" class="danger" onClick={run(onDelete)}>
        <Icon name="trash" size={16} />
        {t('delete_chat')}
      </button>
    </div>
  );
}

/** Leaving a group is on the server; a direct chat only leaves this list. */
function DeleteChat({ conv, onClose }: { conv: Conversation; onClose: () => void }) {
  const [busy, setBusy] = useState(false);
  const me = session.value!;
  const isGroup = conv.kind === 'group';
  const confirm = async () => {
    setBusy(true);
    try {
      if (isGroup) await removeMember(conv.id, me.accountId);
      else hideChat(conv.id);
      if (selectedId.value === conv.id) selectedId.value = null;
      onClose();
    } catch (e) {
      showToast(describeError(e));
      setBusy(false);
    }
  };
  return (
    <div class="modal-backdrop" onClick={onClose}>
      <div class="card modal confirm" onClick={(e) => e.stopPropagation()}>
        <div class="modal-head">
          <h2>{t(isGroup ? 'confirm_delete_chat' : 'confirm_clear_chat')}</h2>
        </div>
        <div class="row end">
          <button type="button" onClick={onClose} disabled={busy}>
            {t('cancel')}
          </button>
          <button type="button" class="danger fill" onClick={() => void confirm()} disabled={busy}>
            {t('delete_chat')}
          </button>
        </div>
      </div>
    </div>
  );
}
