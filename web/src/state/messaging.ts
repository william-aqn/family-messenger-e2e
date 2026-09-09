// Outgoing messages, conversation management and key trust actions.
import { http } from '../api/http';
import type { MemberInfo, Payload, SendResult } from '../api/types';
import { b64decode, b64encode, utf8Encode } from '../crypto/bytes';
import { encrypt, FLAG_EPHEMERAL, FLAG_URGENT, type Recipient } from '../crypto/envelope';
import { newUuid } from '../crypto/ids';
import { t } from '../i18n';
import type { Contact, Conversation } from '../store/db';
import { putContact, putConversation } from '../store/db';
import { contacts, conversations, pending, selectedId, session, setContact, setConversation } from './model';
import { keys } from './session';
import { observeKeys, refreshConversation, upsertFromServer } from './sync';

export { FLAG_EPHEMERAL, FLAG_URGENT };

/** Member ids new messages are sealed to: the signed roster when known, intersected with the server list. */
export function sealingMembers(conv: Conversation, me: string): string[] {
  const base = conv.roster ?? conv.serverMembers;
  const server = new Set(conv.serverMembers);
  const ids = base.filter((id) => server.has(id));
  // Bots are added server-side; they are always part of the server list.
  for (const id of conv.serverMembers) {
    if (!ids.includes(id) && contacts.value.get(id)?.isBot) ids.push(id);
  }
  if (!ids.includes(me)) ids.push(me);
  return ids;
}

/** Server members that no signed membership event vouches for (bots excluded). */
export function unverifiedMembers(conv: Conversation): string[] {
  if (!conv.roster) return [];
  const roster = new Set(conv.roster);
  return conv.serverMembers.filter((id) => !roster.has(id) && !contacts.value.get(id)?.isBot);
}

function recipientsFor(conv: Conversation, me: string): Recipient[] {
  const out: Recipient[] = [];
  for (const id of sealingMembers(conv, me)) {
    const c = contacts.value.get(id);
    if (!c) throw new Error(`No keys known for member ${id.slice(0, 8)}; try reconnecting`);
    if (c.pendingKeys) throw new Error(`${c.username}: ${t('keys_changed')}`);
    out.push({ account: id, encPub: c.encPub });
  }
  return out;
}

export async function sendPayload(convId: string, payload: Payload, flags = 0): Promise<SendResult> {
  const s = session.value;
  const k = keys.value;
  const conv = conversations.value.get(convId);
  if (!s || !k || !conv) throw new Error('not ready');
  const recipients = recipientsFor(conv, s.accountId);
  const clientMsgId = newUuid();
  const ts = Date.now();
  const { env, sig } = encrypt(
    k.signSeed,
    { flags, convId, senderAccount: s.accountId, senderDevice: s.deviceId, clientMsgId, timestampMs: ts },
    recipients,
    utf8Encode(JSON.stringify(payload)),
  );
  const ephemeral = (flags & FLAG_EPHEMERAL) !== 0;
  if (!ephemeral) pending.value = [...pending.value, { clientMsgId, convId, payload, ts }];
  try {
    return await http.send(convId, b64encode(env), b64encode(sig));
  } catch (e) {
    if (!ephemeral) {
      const reason = e instanceof Error ? e.message : String(e);
      pending.value = pending.value.map((p) => (p.clientMsgId === clientMsgId ? { ...p, failed: reason } : p));
    }
    throw e;
  }
}

export function sendText(convId: string, body: string): Promise<SendResult> {
  return sendPayload(convId, { t: 'text', body });
}

export function dismissPending(clientMsgId: string): void {
  pending.value = pending.value.filter((p) => p.clientMsgId !== clientMsgId);
}

function memberInfo(id: string): MemberInfo {
  const c = contacts.value.get(id);
  if (!c) throw new Error('unknown member');
  return { id, username: c.username, sign_pub: b64encode(c.signPub), enc_pub: b64encode(c.encPub) };
}

async function lookupUser(username: string): Promise<string> {
  const u = await http.user(username.trim().replace(/^@/, ''));
  const signPub = b64decode(u.sign_pub);
  const encPub = b64decode(u.enc_pub);
  if (signPub.length !== 32 || encPub.length !== 32) throw new Error('invalid key from server');
  await observeKeys(u.id, u.username, signPub, encPub, { isBot: !!u.is_bot, displayName: u.display_name });
  return u.id;
}

export async function createDirect(username: string): Promise<string> {
  const s = session.value!;
  const id = await lookupUser(username);
  if (id === s.accountId) throw new Error(t('that_is_you'));
  return openDirectWith(id);
}

/** Opens (creating if needed) the direct conversation with a known account. */
export async function openDirectWith(accountId: string): Promise<string> {
  const s = session.value!;
  const cv = await http.createDirect(accountId);
  const conv = await upsertFromServer(cv);
  if (cv.last_seq === 0) {
    await sendPayload(conv.id, { t: 'conv.create', kind: 'direct', members: [memberInfo(s.accountId), memberInfo(accountId)] });
  }
  selectedId.value = conv.id;
  return conv.id;
}

export async function createGroup(name: string, usernames: string[]): Promise<string> {
  const s = session.value!;
  const ids: string[] = [];
  for (const u of usernames) {
    const id = await lookupUser(u);
    if (id !== s.accountId && !ids.includes(id)) ids.push(id);
  }
  const cv = await http.createGroup(ids);
  const conv = await upsertFromServer(cv);
  const members = [s.accountId, ...ids].map(memberInfo);
  await sendPayload(conv.id, { t: 'conv.create', kind: 'group', name: name.trim(), members });
  selectedId.value = conv.id;
  return conv.id;
}

export async function addMember(convId: string, username: string): Promise<void> {
  const s = session.value!;
  const id = await lookupUser(username);
  const cv = await http.addMember(convId, id);
  const conv = await upsertFromServer(cv);
  const roster = new Set(conv.roster ?? conv.serverMembers.filter((m) => m !== id));
  roster.add(s.accountId);
  roster.add(id);
  await sendPayload(convId, { t: 'member.add', member: memberInfo(id), members: [...roster].map(memberInfo) });
}

/** Removes another member (owner) or leaves the group (self). The signed event goes out first. */
export async function removeMember(convId: string, accountId: string): Promise<void> {
  const s = session.value!;
  const conv = conversations.value.get(convId);
  if (!conv) return;
  const remaining = sealingMembers(conv, s.accountId).filter((m) => m !== accountId);
  try {
    await sendPayload(convId, { t: 'member.remove', id: accountId, members: remaining.map(memberInfo) });
  } catch (e) {
    console.warn('membership event not sent', e);
  }
  await http.removeMember(convId, accountId);
  if (accountId === s.accountId) {
    await putConversation({ ...conv, removed: true });
    setConversation({ ...conv, removed: true });
    if (selectedId.value === convId) selectedId.value = null;
  } else {
    await refreshConversation(convId);
  }
}

export async function renameGroup(convId: string, name: string): Promise<void> {
  await sendPayload(convId, { t: 'conv.rename', name: name.trim() });
}

/** Sets the disappearing-messages timer: server-enforced plus a signed event for the history. */
export async function setRetention(convId: string, seconds: number): Promise<void> {
  await http.setRetention(convId, seconds);
  const conv = conversations.value.get(convId);
  if (conv) {
    const next = { ...conv, retentionSeconds: seconds };
    setConversation(next);
    await putConversation(next);
  }
  try {
    await sendPayload(convId, { t: 'conv.retention', seconds });
  } catch (e) {
    console.warn('retention event not sent', e);
  }
}

export async function markRead(convId: string, seq: number): Promise<void> {
  const conv = conversations.value.get(convId);
  if (!conv || seq <= conv.readSeq) return;
  const next = { ...conv, readSeq: seq };
  setConversation(next);
  await putConversation(next);
  try {
    await http.markRead(convId, seq);
  } catch {
    /* best effort */
  }
}

export async function setVerified(contactId: string, verified: boolean): Promise<void> {
  const c = contacts.value.get(contactId);
  if (!c) return;
  const next: Contact = { ...c, verified };
  setContact(next);
  await putContact(next);
}

export async function acceptNewKeys(contactId: string): Promise<void> {
  const c = contacts.value.get(contactId);
  if (!c?.pendingKeys) return;
  const next: Contact = { ...c, signPub: c.pendingKeys.signPub, encPub: c.pendingKeys.encPub, verified: false, pendingKeys: null };
  setContact(next);
  await putContact(next);
}
