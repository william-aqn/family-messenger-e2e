// Sync engine: keeps local state equal to the server's view and turns
// envelopes into decrypted messages (PROTOCOL.md §5.2, §7).
import { http } from '../api/http';
import type { ConversationView, EventPayload, MemberInfo, MessageView, Payload } from '../api/types';
import { wsClient } from '../api/ws';
import { b64decode, equal, utf8Decode } from '../crypto/bytes';
import { decrypt, parse, verifyEnvelope } from '../crypto/envelope';
import { formatDuration, t } from '../i18n';
import {
  allContacts,
  allConversations,
  type Contact,
  type Conversation,
  deleteMessagesBefore,
  messagesFor,
  putContact,
  putConversation,
  putMessage,
  type StoredMessage,
} from '../store/db';
import { handleCallSignal } from './calls';
import {
  contacts,
  conversations,
  messages,
  pending,
  selectedId,
  serverSettings,
  session,
  setContact,
  setConversation,
  setMessages,
  syncing,
} from './model';
import { keys } from './session';

const unsubscribers: (() => void)[] = [];
const locks = new Map<string, Promise<void>>();
let purgeTimer: ReturnType<typeof setInterval> | null = null;

/** Serialises work per conversation so backfills and live frames don't race. */
function withLock<T>(convId: string, fn: () => Promise<T>): Promise<T> {
  const prev = locks.get(convId) ?? Promise.resolve();
  const run = prev.then(fn, fn);
  locks.set(
    convId,
    run.then(
      () => undefined,
      () => undefined,
    ),
  );
  return run;
}

export async function loadLocalState(): Promise<void> {
  const cs = new Map<string, Contact>();
  for (const c of await allContacts()) cs.set(c.id, c);
  contacts.value = cs;
  const convs = new Map<string, Conversation>();
  for (const c of await allConversations()) convs.set(c.id, { ...c, retentionSeconds: c.retentionSeconds ?? 0 });
  conversations.value = convs;
}

export function startSync(): void {
  const s = session.value;
  if (!s) return;
  stopSync();
  unsubscribers.push(
    wsClient.on('hello', () => void fullSync()),
    wsClient.on('message', (d: MessageView) => void onLiveMessage(d)),
    wsClient.on('signal', (d: MessageView) => void handleIncoming(d, false)),
    wsClient.on('event', (d: EventPayload) => void onEvent(d)),
  );
  wsClient.connect(s.token);
  purgeTimer = setInterval(() => void purgeExpired(), 60_000);
}

export function stopSync(): void {
  for (const u of unsubscribers.splice(0)) u();
  wsClient.close();
  if (purgeTimer) clearInterval(purgeTimer);
  purgeTimer = null;
}

export async function fullSync(): Promise<void> {
  if (syncing.value) return;
  syncing.value = true;
  try {
    const { conversations: list } = await http.conversations();
    const seen = new Set<string>();
    for (const cv of list) {
      seen.add(cv.id);
      await upsertFromServer(cv);
    }
    for (const c of conversations.value.values()) {
      if (!seen.has(c.id) && !c.removed) await persistConversation({ ...c, removed: true });
    }
    for (const cv of list) await withLock(cv.id, () => backfill(cv.id));
    await purgeExpired();
  } catch (e) {
    console.error('sync failed', e);
  } finally {
    syncing.value = false;
  }
}

export async function refreshConversation(id: string): Promise<void> {
  try {
    const cv = await http.conversation(id);
    await upsertFromServer(cv);
    await withLock(id, () => backfill(id));
  } catch (e) {
    console.error('refresh conversation failed', e);
  }
}

async function persistConversation(c: Conversation): Promise<void> {
  setConversation(c);
  await putConversation(c);
}

export async function upsertFromServer(cv: ConversationView): Promise<Conversation> {
  for (const m of cv.members) {
    await observeKeys(m.id, m.username, b64decode(m.sign_pub), b64decode(m.enc_pub), { isBot: !!m.is_bot, displayName: m.display_name });
  }
  const existing = conversations.value.get(cv.id);
  const conv: Conversation = existing
    ? { ...existing }
    : {
        id: cv.id,
        kind: cv.kind,
        name: '',
        createdBy: cv.created_by,
        createdAt: cv.created_at,
        role: cv.role,
        joinedSeq: cv.joined_seq,
        lastSeq: cv.last_seq,
        readSeq: cv.read_seq,
        syncedSeq: cv.joined_seq,
        serverMembers: [],
        roster: null,
        rosterSeq: 0,
        retentionSeconds: 0,
        lastMessage: null,
        updatedAt: cv.created_at * 1000,
        removed: false,
      };
  conv.kind = cv.kind;
  conv.role = cv.role;
  conv.joinedSeq = cv.joined_seq;
  conv.lastSeq = Math.max(conv.lastSeq, cv.last_seq);
  conv.readSeq = Math.max(conv.readSeq, cv.read_seq);
  conv.serverMembers = cv.members.map((m) => m.id);
  conv.retentionSeconds = cv.retention_seconds ?? 0;
  conv.removed = false;
  await persistConversation(conv);
  return conv;
}

/** Trust on first use; later differences are flagged, never silently accepted. */
export async function observeKeys(
  id: string,
  username: string,
  signPub: Uint8Array,
  encPub: Uint8Array,
  extra: { isBot?: boolean; displayName?: string } = {},
): Promise<void> {
  const existing = contacts.value.get(id);
  if (!existing) {
    const c: Contact = { id, username, signPub, encPub, verified: false, pendingKeys: null, firstSeen: Date.now(), isBot: !!extra.isBot, displayName: extra.displayName };
    setContact(c);
    await putContact(c);
    return;
  }
  if (!equal(existing.signPub, signPub) || !equal(existing.encPub, encPub)) {
    if (!existing.pendingKeys || !equal(existing.pendingKeys.signPub, signPub) || !equal(existing.pendingKeys.encPub, encPub)) {
      const c = { ...existing, pendingKeys: { signPub, encPub } };
      setContact(c);
      await putContact(c);
    }
    return;
  }
  const isBot = extra.isBot ?? existing.isBot;
  const displayName = extra.displayName ?? existing.displayName;
  if (existing.username !== username || existing.isBot !== isBot || existing.displayName !== displayName) {
    const c = { ...existing, username, isBot, displayName };
    setContact(c);
    await putContact(c);
  }
}

async function backfill(convId: string): Promise<void> {
  const conv = conversations.value.get(convId);
  if (!conv) return;
  let after = Math.max(conv.syncedSeq, conv.joinedSeq);
  for (;;) {
    const page = await http.messages(convId, after, 200);
    for (const m of page.messages) {
      await handleIncoming(m, true);
      after = Math.max(after, m.seq);
    }
    if (!page.has_more) break;
  }
}

async function onLiveMessage(view: MessageView): Promise<void> {
  await withLock(view.conv_id, async () => {
    let conv = conversations.value.get(view.conv_id);
    if (!conv || conv.removed) {
      await refreshConversationInline(view.conv_id);
      conv = conversations.value.get(view.conv_id);
      if (!conv) return;
    }
    if (view.seq > Math.max(conv.syncedSeq, conv.joinedSeq) + 1) await backfill(view.conv_id);
    await handleIncoming(view, true);
  });
}

async function refreshConversationInline(id: string): Promise<void> {
  try {
    await upsertFromServer(await http.conversation(id));
  } catch (e) {
    console.error('conversation lookup failed', e);
  }
}

async function onEvent(ev: EventPayload): Promise<void> {
  if (!ev.conv_id) return;
  switch (ev.kind) {
    case 'conv.updated':
    case 'member.added':
    case 'member.removed':
      await refreshConversation(ev.conv_id);
      break;
    case 'conv.removed': {
      const c = conversations.value.get(ev.conv_id);
      if (c) await persistConversation({ ...c, removed: true });
      if (selectedId.value === ev.conv_id) selectedId.value = null;
      break;
    }
    case 'read.updated': {
      const c = conversations.value.get(ev.conv_id);
      if (c && ev.seq !== undefined && ev.seq > c.readSeq) await persistConversation({ ...c, readSeq: ev.seq });
      break;
    }
  }
}

function memberInfoKeys(m: MemberInfo): { signPub: Uint8Array; encPub: Uint8Array } | null {
  try {
    const signPub = b64decode(m.sign_pub);
    const encPub = b64decode(m.enc_pub);
    if (signPub.length !== 32 || encPub.length !== 32) return null;
    return { signPub, encPub };
  } catch {
    return null;
  }
}

/** Verifies, decrypts and applies one envelope (stored message or ephemeral signal). */
export async function handleIncoming(view: MessageView, stored: boolean): Promise<void> {
  const s = session.value;
  const k = keys.value;
  if (!s || !k) return;
  let payload: Payload | null = null;
  let error: string | undefined;
  let ts = view.server_ts;
  try {
    let sender = contacts.value.get(view.sender_account);
    if (!sender) {
      await refreshConversationInline(view.conv_id);
      sender = contacts.value.get(view.sender_account);
    }
    if (!sender) throw new Error('unknown sender');
    const env = b64decode(view.env);
    const sig = b64decode(view.sig);
    if (!verifyEnvelope(sender.signPub, env, sig)) throw new Error('invalid signature');
    const parsed = parse(env);
    if (parsed.senderAccount !== view.sender_account || parsed.convId !== view.conv_id) throw new Error('envelope header mismatch');
    ts = parsed.timestampMs;
    payload = JSON.parse(utf8Decode(decrypt(parsed, s.accountId, k.encPriv))) as Payload;
    if (!payload || typeof payload.t !== 'string') throw new Error('malformed payload');
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }
  if (!stored) {
    if (payload && payload.t.startsWith('call.')) handleCallSignal(view.sender_account, view.sender_device, view.conv_id, payload);
    return;
  }
  await applyStored({
    convId: view.conv_id,
    seq: view.seq,
    clientMsgId: view.client_msg_id,
    sender: view.sender_account,
    senderDevice: view.sender_device,
    ts,
    serverTs: view.server_ts,
    payload,
    error,
  });
}

function previewOf(p: Payload | null, error?: string): string {
  if (!p) return error ? t('preview_unreadable') : '';
  switch (p.t) {
    case 'text':
      return p.body;
    case 'file':
      return p.mime.startsWith('image/') ? `📷 ${t('preview_photo')}` : `📎 ${t('preview_file', { name: p.name })}`;
    case 'conv.create':
      return p.kind === 'group' ? t('preview_group_created') : t('preview_chat_started');
    case 'member.add':
      return t('preview_joined', { name: p.member.username });
    case 'member.remove':
      return t('preview_left');
    case 'conv.rename':
      return t('preview_renamed', { name: p.name });
    case 'conv.retention':
      return p.seconds > 0 ? `⏱ ${formatDuration(p.seconds)}` : '';
    default:
      return '';
  }
}

async function applyStored(msg: StoredMessage): Promise<void> {
  const s = session.value!;
  const conv = conversations.value.get(msg.convId);
  if (!conv) return;
  if (isExpired(conv, msg.serverTs)) return;
  await putMessage(msg);
  const loaded = messages.value.get(msg.convId);
  if (loaded && !loaded.some((m) => m.seq === msg.seq)) {
    setMessages(msg.convId, [...loaded, msg].sort((a, b) => a.seq - b.seq));
  }
  if (pending.value.some((p) => p.clientMsgId === msg.clientMsgId)) {
    pending.value = pending.value.filter((p) => p.clientMsgId !== msg.clientMsgId);
  }
  const next: Conversation = { ...conv, syncedSeq: Math.max(conv.syncedSeq, msg.seq), lastSeq: Math.max(conv.lastSeq, msg.seq) };
  const p = msg.payload;
  if (p && msg.seq > conv.rosterSeq) {
    switch (p.t) {
      case 'conv.create':
        if (p.name) next.name = p.name;
        next.roster = await applyRoster(p.members);
        next.rosterSeq = msg.seq;
        break;
      case 'member.add':
      case 'member.remove':
        next.roster = await applyRoster(p.members);
        next.rosterSeq = msg.seq;
        break;
      case 'conv.rename':
        next.name = p.name;
        break;
    }
  }
  const preview = previewOf(p, msg.error);
  if (preview && (!conv.lastMessage || msg.seq >= conv.syncedSeq)) {
    next.lastMessage = { text: preview, ts: msg.ts, sender: msg.sender };
    next.updatedAt = Math.max(conv.updatedAt, msg.serverTs);
  }
  if (msg.sender === s.accountId && msg.seq > next.readSeq) next.readSeq = msg.seq;
  await persistConversation(next);
  if ((p?.t === 'text' || p?.t === 'file') && msg.sender !== s.accountId && msg.seq > conv.readSeq) {
    maybeNotify(next, msg, p.t === 'text' ? p.body : preview);
  }
}

async function applyRoster(members: MemberInfo[]): Promise<string[]> {
  const ids: string[] = [];
  for (const m of members) {
    const k = memberInfoKeys(m);
    if (!k || !m.id) continue;
    await observeKeys(m.id, m.username, k.signPub, k.encPub);
    ids.push(m.id);
  }
  return ids;
}

function maybeNotify(conv: Conversation, msg: StoredMessage, body: string): void {
  if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
  if (document.visibilityState === 'visible' && selectedId.value === conv.id) return;
  if (Date.now() - msg.serverTs > 60_000) return; // backfilled history, not a live message
  const from = contacts.value.get(msg.sender)?.username ?? 'New message';
  try {
    const n = new Notification(from, { body: body.slice(0, 140), tag: conv.id, silent: false });
    n.onclick = () => {
      window.focus();
      selectedId.value = conv.id;
    };
  } catch {
    /* notifications unavailable */
  }
}

/** Effective retention in seconds: the conversation timer capped by the server-wide limit. */
export function effectiveRetention(conv: Conversation): number {
  const global = (serverSettings.value?.retention_days ?? 0) * 86400;
  let r = conv.retentionSeconds;
  if (global > 0 && (r === 0 || r > global)) r = global;
  return r;
}

function isExpired(conv: Conversation, serverTs: number): boolean {
  const r = effectiveRetention(conv);
  return r > 0 && serverTs < Date.now() - r * 1000;
}

/** Deletes local copies of expired messages (the server purges its own). */
export async function purgeExpired(): Promise<void> {
  for (const conv of conversations.value.values()) {
    const r = effectiveRetention(conv);
    if (r <= 0) continue;
    const cutoff = Date.now() - r * 1000;
    const deleted = await deleteMessagesBefore(conv.id, cutoff);
    const loaded = messages.value.get(conv.id);
    if (loaded && loaded.some((m) => m.serverTs < cutoff)) {
      setMessages(
        conv.id,
        loaded.filter((m) => m.serverTs >= cutoff),
      );
    }
    if (deleted > 0 && conv.lastMessage && conv.lastMessage.ts < cutoff) {
      await persistConversation({ ...conv, lastMessage: null });
    }
  }
}

/** Loads a conversation's decrypted history from IndexedDB into memory. */
export async function ensureMessagesLoaded(convId: string): Promise<void> {
  if (messages.value.has(convId)) return;
  setMessages(convId, await messagesFor(convId));
}
