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
import { Icon } from './Icons';
import { MemberPanel } from './MemberPanel';
import { VoiceBar } from './VoiceOverlay';

/** What the lightbox shows: the decrypted object URL plus the payload behind it. */
type LightboxItem = { url: string; file: FilePayload };

/** An image with a thumbnail becomes a media bubble; anything else is a file card. */
function isMedia(p: Payload): boolean {
  return p.t === 'file' && p.mime.startsWith('image/') && !!p.thumb;
}

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

function Attachment({ p, onOpen }: { p: FilePayload; onOpen: (item: LightboxItem) => void }) {
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
  const open = () => act(async () => onOpen({ url: await fileUrl(p), file: p }));
  // A thumbnail fills the bubble on its own — the bubble carries the .media padding.
  if (isImage && p.thumb) {
    return (
      <>
        <img class="thumb" src={`data:image/jpeg;base64,${p.thumb}`} alt={p.name} onClick={open} />
        {error && (
          <div class="error small">
            <Icon name="alert" size={16} />
            {error}
          </div>
        )}
      </>
    );
  }
  return (
    <div class="file">
      <div class="file-card">
        <span class="file-icon">
          <Icon name={isImage ? 'image' : 'file'} size={20} />
        </span>
        <span class="file-name" title={p.name}>
          {p.name}
        </span>
        <span class="file-meta">
          <span>{formatSize(p.size)} ·</span>
          {isImage && (
            <button type="button" class="link" disabled={busy} onClick={open}>
              {t('open')}
            </button>
          )}
          <button type="button" class="link" disabled={busy} onClick={() => act(() => downloadFile(p))}>
            {busy ? '…' : t('download')}
          </button>
        </span>
      </div>
      {error && (
        <div class="error small">
          <Icon name="alert" size={16} />
          {error}
        </div>
      )}
    </div>
  );
}

function Bubble({
  m,
  me,
  isAdmin,
  isEditing,
  showAuthor,
  onOpen,
  onEdit,
}: {
  m: StoredMessage;
  me: string;
  isAdmin: boolean;
  isEditing: boolean;
  /** Off in a one-to-one chat: only one other person writes there, and the header already names them. */
  showAuthor: boolean;
  onOpen: (item: LightboxItem) => void;
  onEdit: (m: StoredMessage) => void;
}) {
  const mine = m.sender === me;
  const [menu, setMenu] = useState(false);
  const [confirming, setConfirming] = useState(false);
  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(false);
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [menu]);
  if (m.error || !m.payload) {
    return (
      <div class="system error-text" title={m.error}>
        <Icon name="alert" size={16} />
        {t('undecryptable', { user: usernameOf(m.sender, me), reason: m.error ?? t('unknown_payload') })}
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
    try {
      await deleteMessage(m.convId, m);
    } catch (e) {
      showToast(describeError(e));
    }
  };
  const classes = ['bubble', mine && 'mine', isMedia(m.payload) && 'media', isEditing && 'editing', menu && 'menu-open'].filter(Boolean).join(' ');
  return (
    <div
      class={classes}
      onContextMenu={(e) => {
        if (!canDelete) return;
        e.preventDefault();
        setMenu(true);
      }}
    >
      {!mine && showAuthor && <div class="author">{usernameOf(m.sender, me)}</div>}
      {m.payload.t === 'text' ? <div class="body">{m.payload.body}</div> : <Attachment p={m.payload} onOpen={onOpen} />}
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
            <Icon name="more" size={16} />
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
              <Icon name="pencil" size={16} />
              {t('edit')}
            </button>
          )}
          <button
            type="button"
            class="danger"
            onClick={() => {
              setMenu(false);
              setConfirming(true);
            }}
          >
            <Icon name="trash" size={16} />
            {t('delete')}
          </button>
        </div>
      )}
      {confirming && (
        <div class="modal-backdrop" onClick={() => setConfirming(false)}>
          <div class="card modal confirm" onClick={(e) => e.stopPropagation()}>
            <div class="modal-head">
              <h2>{t('confirm_delete_message')}</h2>
            </div>
            <div class="row end">
              <button type="button" onClick={() => setConfirming(false)}>
                {t('cancel')}
              </button>
              <button
                type="button"
                class="danger fill"
                onClick={() => {
                  setConfirming(false);
                  void remove();
                }}
              >
                {t('delete')}
              </button>
            </div>
          </div>
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
  const [lightbox, setLightbox] = useState<LightboxItem | null>(null);
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
        <div class="placeholder">
          <Icon name="message" size={24} />
          {t('select_conversation')}
        </div>
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
  const inVoice = voice.value?.convId === conv.id;
  const voiceCount = participantsOf(conv.id).length;
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
        <button type="button" class="icon-btn touch back" onClick={() => (selectedId.value = null)} title={t('back')}>
          <Icon name="arrow-left" size={20} />
        </button>
        <div class="chat-title" onClick={() => setShowMembers((v) => !v)}>
          <strong>{conversationTitle(conv, me.accountId)}</strong>
          <span class="chat-sub">
            <span>{conv.kind === 'group' ? t('members_count', { n: conv.serverMembers.length }) : t('direct_chat')}</span>
            {unverified.length > 0 && (
              <span class="tag warn">
                <Icon name="alert" size={12} />
                {t('unverified_members')}
              </span>
            )}
            {retention > 0 && (
              <span>
                <Icon name="timer" size={12} class="inline" /> {t('disappearing_badge', { duration: formatDuration(retention) })}
              </span>
            )}
          </span>
        </div>
        <div class="actions">
          {conv.kind === 'direct' && !hasBot(conv) && (
            <>
              <button type="button" class="icon-btn" title={t('voice_call')} onClick={() => void startCall(conv.id)}>
                <Icon name="phone" size={20} />
              </button>
              <button type="button" class="icon-btn" title={t('video_call')} onClick={() => void startCall(conv.id, true)}>
                <Icon name="video" size={20} />
              </button>
            </>
          )}
          {conv.kind === 'group' && (
            <button
              type="button"
              title={t('voice_channel')}
              class={`icon-btn wide ${inVoice ? 'active' : ''}`}
              onClick={() => void (inVoice ? leaveVoice() : joinVoice(conv.id))}
            >
              <Icon name="headphones" size={20} />
              {voiceCount > 0 && <span class="badge">{voiceCount}</span>}
            </button>
          )}
          <button type="button" class={`icon-btn ${showMembers ? 'active' : ''}`} title={t('members_security')} onClick={() => setShowMembers((v) => !v)}>
            <Icon name="info" size={20} />
          </button>
        </div>
      </header>
      {conv.kind === 'group' && <VoiceBar convId={conv.id} />}
      {hasBot(conv) && (
        <div class="notice small neutral">
          <Icon name="bot" size={16} />
          {t('bot_notice')}
        </div>
      )}
      <div class="chat-body">
        <div class="messages" ref={listRef}>
          {list.map((m) => (
            <Bubble
              key={m.seq}
              m={m}
              me={me.accountId}
              isAdmin={me.isAdmin}
              isEditing={editing?.seq === m.seq}
              showAuthor={conv.kind !== 'direct'}
              onOpen={setLightbox}
              onEdit={startEdit}
            />
          ))}
          {mine.map((p) => (
            <div key={p.clientMsgId} class={`bubble mine pending ${p.failed ? 'failed' : ''}`}>
              <div class="body">
                {p.payload.t === 'text' ? (
                  p.payload.body
                ) : p.payload.t === 'file' ? (
                  <>
                    <Icon name="paperclip" size={16} class="inline" /> {p.payload.name}
                  </>
                ) : (
                  '…'
                )}
              </div>
              <div class="meta">
                {p.failed ? (
                  <>
                    {t('failed', { reason: p.failed })}{' '}
                    <button type="button" class="link" onClick={() => dismissPending(p.clientMsgId)}>
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
        {dragging && (
          <div class="dropzone-hint">
            <Icon name="upload" size={24} />
            {t('drop_files_hint')}
          </div>
        )}
      </div>
      {editing && (
        <div class="editing-bar">
          <Icon name="pencil" size={16} />
          <span>{t('editing_message')}</span>
          <button type="button" class="link" onClick={cancelEdit}>
            {t('cancel')}
          </button>
        </div>
      )}
      <form class="composer" onSubmit={submit}>
        <input
          ref={fileInput}
          type="file"
          class="hidden-input"
          multiple
          hidden
          onChange={(e) => void sendFiles((e.target as HTMLInputElement).files).then(() => ((e.target as HTMLInputElement).value = ''))}
        />
        <button type="button" class="icon-btn touch" title={t('attach_file')} onClick={() => fileInput.current?.click()}>
          <Icon name="paperclip" size={20} />
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
        <button type="submit" class="primary" title={editing ? t('save') : t('send')} disabled={!text.trim()}>
          <Icon name="send" size={20} class="send-icon" />
          <span class="send-label">{editing ? t('save') : t('send')}</span>
        </button>
      </form>
      {error && (
        <div class="error composer-error">
          <Icon name="alert" size={16} />
          {error}
        </div>
      )}
      {lightbox && (
        <div class="lightbox" onClick={() => setLightbox(null)}>
          <img src={lightbox.url} alt={lightbox.file.name} />
          <button type="button" class="icon-btn" title={t('close')} onClick={() => setLightbox(null)}>
            <Icon name="x" size={20} />
          </button>
          <span class="caption" onClick={(e) => e.stopPropagation()}>
            {lightbox.file.name} · {formatSize(lightbox.file.size)} ·{' '}
            <button type="button" class="link" onClick={() => void downloadFile(lightbox.file)}>
              {t('download')}
            </button>
          </span>
        </div>
      )}
    </main>
  );
}
