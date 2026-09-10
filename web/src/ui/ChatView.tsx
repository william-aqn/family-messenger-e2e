import { useEffect, useRef, useState } from 'preact/hooks';
import type { FilePayload, Payload } from '../api/types';
import { describeError, formatDuration, t } from '../i18n';
import { downloadFile, fileUrl, formatSize, sendFile } from '../state/attachments';
import { startCall } from '../state/calls';
import { deleteMessage, dismissPending, editText, markRead, sendText, unverifiedMembers } from '../state/messaging';
import { conversationTitle, hasBot, messages, pending, selectedConversation, selectedId, session, showToast, usernameOf } from '../state/model';
import { effectiveRetention, ensureMessagesLoaded } from '../state/sync';
import { joinVoice, leaveVoice, participantsOf, voice } from '../state/voice';
import type { StoredMessage } from '../store/db';
import { MemberPanel } from './MemberPanel';
import { VoiceBar } from './VoiceOverlay';

function describeEvent(p: Payload, sender: string, me: string): string | null {
  const who = usernameOf(sender, me);
  switch (p.t) {
    case 'conv.create':
      return p.kind === 'group' ? (p.name ? t('ev_created_group', { who, name: p.name }) : t('ev_created_group_unnamed', { who })) : t('ev_started_chat', { who });
    case 'member.add':
      return t('ev_added', { who, member: p.member.username });
    case 'member.remove':
      return p.id === sender ? t('ev_left', { who }) : t('ev_removed', { who, member: usernameOf(p.id, me) });
    case 'conv.rename':
      return t('ev_renamed', { who, name: p.name });
    case 'conv.retention':
      return p.seconds > 0 ? t('ev_retention_set', { who, duration: formatDuration(p.seconds) }) : t('ev_retention_off', { who });
    default:
      return null;
  }
}

function FileBubble({ p, onOpen }: { p: FilePayload; onOpen: (url: string) => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const isImage = p.mime.startsWith('image/');
  const act = async (fn: () => Promise<void>) => {
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
  return (
    <div class="file">
      {isImage && p.thumb && (
        <img
          class="thumb"
          src={`data:image/jpeg;base64,${p.thumb}`}
          alt={p.name}
          width={p.width && p.height ? Math.min(320, p.width) : undefined}
          onClick={() => act(async () => onOpen(await fileUrl(p)))}
        />
      )}
      <div class="file-card">
        <span class="file-icon">{isImage ? '🖼' : '📎'}</span>
        <span class="file-name" title={p.name}>
          {p.name}
        </span>
        <span class="muted small">{formatSize(p.size)}</span>
        {isImage && !p.thumb && (
          <button class="link" disabled={busy} onClick={() => act(async () => onOpen(await fileUrl(p)))}>
            {t('open')}
          </button>
        )}
        <button class="link" disabled={busy} onClick={() => act(() => downloadFile(p))}>
          {busy ? '…' : t('download')}
        </button>
      </div>
      {error && <div class="error small">{error}</div>}
    </div>
  );
}

function Bubble({ m, me, isAdmin, onOpen, onEdit }: { m: StoredMessage; me: string; isAdmin: boolean; onOpen: (url: string) => void; onEdit: (m: StoredMessage) => void }) {
  const mine = m.sender === me;
  const [menu, setMenu] = useState(false);
  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(false);
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [menu]);
  if (m.error || !m.payload) {
    return (
      <div class="system error-text" title={m.error}>
        ⚠ {t('undecryptable', { user: usernameOf(m.sender, me), reason: m.error ?? t('unknown_payload') })}
      </div>
    );
  }
  if (m.payload.t !== 'text' && m.payload.t !== 'file') {
    const text = describeEvent(m.payload, m.sender, me);
    return text ? <div class="system">{text}</div> : null;
  }
  // Senders edit and delete their own messages; administrators may delete anyone's.
  const canEdit = mine && m.payload.t === 'text';
  const canDelete = mine || isAdmin;
  const remove = async () => {
    if (!confirm(t('confirm_delete_message'))) return;
    try {
      await deleteMessage(m.convId, m);
    } catch (e) {
      showToast(describeError(e));
    }
  };
  return (
    <div
      class={`bubble ${mine ? 'mine' : ''} ${menu ? 'menu-open' : ''}`}
      onContextMenu={(e) => {
        if (!canDelete) return;
        e.preventDefault();
        setMenu(true);
      }}
    >
      {!mine && <div class="author">{usernameOf(m.sender, me)}</div>}
      {m.payload.t === 'text' ? <div class="body">{m.payload.body}</div> : <FileBubble p={m.payload} onOpen={onOpen} />}
      <div class="meta">
        {m.edited && <span class="edited">{t('edited')} ·</span>}
        <span>{new Date(m.ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
        {canDelete && (
          <button
            type="button"
            class="more"
            title={t('message_actions')}
            onClick={(e) => {
              e.stopPropagation();
              setMenu((v) => !v);
            }}
          >
            ⋯
          </button>
        )}
      </div>
      {menu && (
        <div class="msg-menu" onClick={(e) => e.stopPropagation()}>
          {canEdit && (
            <button
              type="button"
              onClick={() => {
                setMenu(false);
                onEdit(m);
              }}
            >
              ✎ {t('edit')}
            </button>
          )}
          <button
            type="button"
            class="danger"
            onClick={() => {
              setMenu(false);
              void remove();
            }}
          >
            🗑 {t('delete')}
          </button>
        </div>
      )}
    </div>
  );
}

export function ChatView() {
  const conv = selectedConversation.value;
  const me = session.value!;
  const [showMembers, setShowMembers] = useState(false);
  const [text, setText] = useState('');
  const [editing, setEditing] = useState<StoredMessage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const [lightbox, setLightbox] = useState<string | null>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const fileInput = useRef<HTMLInputElement>(null);
  const list = conv ? (messages.value.get(conv.id) ?? []) : [];
  const mine = conv ? pending.value.filter((p) => p.convId === conv.id) : [];

  useEffect(() => {
    if (conv) void ensureMessagesLoaded(conv.id);
    setShowMembers(false);
    setError(null);
    setLightbox(null);
    setEditing(null);
    setText('');
  }, [conv?.id]);

  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
    if (conv && conv.lastSeq > conv.readSeq && document.visibilityState === 'visible') void markRead(conv.id, conv.lastSeq);
  }, [conv?.id, list.length, mine.length, conv?.lastSeq]);

  if (!conv) {
    return (
      <main class="chat empty-state">
        <div class="muted">{t('select_conversation')}</div>
      </main>
    );
  }

  const startEdit = (m: StoredMessage) => {
    if (m.payload?.t !== 'text') return;
    setEditing(m);
    setText(m.payload.body);
    requestAnimationFrame(() => {
      const el = inputRef.current;
      if (!el) return;
      el.focus();
      el.setSelectionRange(el.value.length, el.value.length);
    });
  };

  const cancelEdit = () => {
    setEditing(null);
    setText('');
  };

  const submit = async (e: Event) => {
    e.preventDefault();
    const body = text.trim();
    if (!body) return;
    setText('');
    setError(null);
    if (editing) {
      const target = editing;
      setEditing(null);
      if (target.payload?.t === 'text' && target.payload.body === body) return;
      try {
        await editText(conv.id, target, body);
      } catch (err) {
        setError(describeError(err));
      }
      return;
    }
    try {
      await sendText(conv.id, body);
    } catch (err) {
      setError(describeError(err));
    }
  };

  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape' && editing) {
      e.preventDefault();
      e.stopPropagation(); // Escape otherwise closes the conversation
      cancelEdit();
      return;
    }
    if (e.key === 'ArrowUp' && !text && !editing) {
      // Up in an empty composer edits our last message, as in most messengers.
      const last = [...list].reverse().find((m) => m.sender === me.accountId && m.payload?.t === 'text');
      if (last) {
        e.preventDefault();
        startEdit(last);
      }
    }
  };

  const sendFiles = async (files: FileList | File[] | null) => {
    if (!files) return;
    setError(null);
    for (const f of Array.from(files)) {
      try {
        await sendFile(conv.id, f);
      } catch (err) {
        setError(describeError(err));
      }
    }
  };

  const onPaste = (e: ClipboardEvent) => {
    const files = Array.from(e.clipboardData?.files ?? []);
    if (files.length) {
      e.preventDefault();
      void sendFiles(files);
    }
  };

  const unverified = unverifiedMembers(conv);
  const retention = effectiveRetention(conv);
  return (
    <main
      class={`chat ${dragging ? 'dropzone' : ''}`}
      onDragOver={(e) => {
        e.preventDefault();
        setDragging(true);
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={(e) => {
        e.preventDefault();
        setDragging(false);
        void sendFiles(e.dataTransfer?.files ?? null);
      }}
    >
      <header class="chat-header">
        <button class="back" onClick={() => (selectedId.value = null)} title={t('back')}>
          ←
        </button>
        <div class="chat-title" onClick={() => setShowMembers((v) => !v)}>
          <strong>{conversationTitle(conv, me.accountId)}</strong>
          <span class="muted small">
            {conv.kind === 'group' ? t('members_count', { n: conv.serverMembers.length }) : t('direct_chat')}
            {unverified.length > 0 && ` · ⚠ ${t('unverified_members')}`}
            {retention > 0 && ` · ⏱ ${t('disappearing_badge', { duration: formatDuration(retention) })}`}
          </span>
        </div>
        <div class="actions">
          {conv.kind === 'direct' && !hasBot(conv) && (
            <>
              <button title={t('voice_call')} onClick={() => void startCall(conv.id)}>
                📞
              </button>
              <button title={t('video_call')} onClick={() => void startCall(conv.id, true)}>
                📹
              </button>
            </>
          )}
          {conv.kind === 'group' && (
            <button
              title={t('voice_channel')}
              class={voice.value?.convId === conv.id ? 'active' : ''}
              onClick={() => void (voice.value?.convId === conv.id ? leaveVoice() : joinVoice(conv.id))}
            >
              🎙{participantsOf(conv.id).length > 0 && <span class="badge">{participantsOf(conv.id).length}</span>}
            </button>
          )}
          <button title={t('members_security')} onClick={() => setShowMembers((v) => !v)}>
            ℹ
          </button>
        </div>
      </header>
      {conv.kind === 'group' && <VoiceBar convId={conv.id} />}
      {hasBot(conv) && <div class="notice small">🤖 {t('bot_notice')}</div>}
      <div class="chat-body">
        <div class="messages" ref={listRef}>
          {list.map((m) => (
            <Bubble key={m.seq} m={m} me={me.accountId} isAdmin={me.isAdmin} onOpen={setLightbox} onEdit={startEdit} />
          ))}
          {mine.map((p) => (
            <div key={p.clientMsgId} class={`bubble mine pending ${p.failed ? 'failed' : ''}`}>
              <div class="body">{p.payload.t === 'text' ? p.payload.body : p.payload.t === 'file' ? `📎 ${p.payload.name}` : '…'}</div>
              <div class="meta">
                {p.failed ? (
                  <>
                    {t('failed', { reason: p.failed })}{' '}
                    <button class="link" onClick={() => dismissPending(p.clientMsgId)}>
                      {t('dismiss')}
                    </button>
                  </>
                ) : p.uploading ? (
                  t('uploading', { name: p.payload.t === 'file' ? p.payload.name : '' })
                ) : (
                  t('sending')
                )}
              </div>
            </div>
          ))}
        </div>
        {showMembers && <MemberPanel conv={conv} onClose={() => setShowMembers(false)} />}
      </div>
      {editing && (
        <div class="editing-bar">
          <span>✎ {t('editing_message')}</span>
          <button type="button" class="link" onClick={cancelEdit}>
            {t('cancel')}
          </button>
        </div>
      )}
      <form class="composer" onSubmit={submit}>
        <input ref={fileInput} type="file" multiple hidden onChange={(e) => void sendFiles((e.target as HTMLInputElement).files).then(() => ((e.target as HTMLInputElement).value = ''))} />
        <button type="button" title={t('attach_file')} onClick={() => fileInput.current?.click()}>
          📎
        </button>
        <input
          ref={inputRef}
          value={text}
          onInput={(e) => setText((e.target as HTMLInputElement).value)}
          onPaste={onPaste}
          onKeyDown={onKey}
          placeholder={t('write_message')}
          autocomplete="off"
          autofocus
        />
        <button type="submit" class="primary" disabled={!text.trim()}>
          {editing ? t('save') : t('send')}
        </button>
      </form>
      {error && <div class="error composer-error">{error}</div>}
      {lightbox && (
        <div class="lightbox" onClick={() => setLightbox(null)}>
          <img src={lightbox} alt="" />
        </div>
      )}
    </main>
  );
}
