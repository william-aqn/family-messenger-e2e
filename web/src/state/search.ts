// The search under the chat list: chats, people and messages.
//
// Chats come from the conversation list already in memory, people from the
// server's directory, and messages from this device — the server holds only
// ciphertext, so a server-side full-text search is not possible and never will
// be. That is what the note under the results says.
import { computed, signal } from '@preact/signals';
import { http } from '../api/http';
import type { DirectoryUser } from '../api/types';
import { conversationTitle, contacts, conversations, hasBot, session, sortedConversations } from './model';
import { allMessages, type StoredMessage } from '../store/db';

export type SearchFilter = 'all' | 'chats' | 'people' | 'messages';

export const query = signal('');
export const filter = signal<SearchFilter>('all');

/** Open while a query is typed: the results replace the conversation list. */
export const searching = computed(() => query.value.trim().length > 0);

export interface ChatHit {
  id: string;
  title: string;
  kind: 'direct' | 'group';
  isBot: boolean;
  members: number;
  retention: number;
}

export interface PersonHit extends DirectoryUser {
  online: boolean;
  lastSeen: number;
  /** Already in a conversation with us: the list says so instead of "no chats in common". */
  known: boolean;
}

export interface MessageHit {
  convId: string;
  seq: number;
  title: string;
  sender: string;
  ts: number;
  body: string;
}

export const chats = signal<ChatHit[]>([]);
export const people = signal<PersonHit[]>([]);
export const messages = signal<MessageHit[]>([]);
/** A search is in flight; the results shown are from the previous query. */
export const busy = signal(false);
/** The directory refused or is switched off: people cannot be searched. */
export const peopleUnavailable = signal(false);

/** How many rows of each kind are worth drawing before the column is a wall of text. */
const MAX_PER_GROUP = 20;

export function normalise(s: string): string {
  return s.trim().replace(/^@/, '').toLowerCase();
}

function matchChats(q: string): ChatHit[] {
  const me = session.value!.accountId;
  return sortedConversations.value
    .map((c) => ({
      id: c.id,
      title: conversationTitle(c, me),
      kind: c.kind,
      isBot: c.kind === 'direct' && hasBot(c),
      members: c.serverMembers.length,
      retention: c.retentionSeconds,
    }))
    .filter((c) => c.title.toLowerCase().includes(q))
    .slice(0, MAX_PER_GROUP);
}

function matchMessages(all: StoredMessage[], q: string): MessageHit[] {
  const me = session.value!.accountId;
  const hits: MessageHit[] = [];
  for (const m of all) {
    if (m.payload?.t !== 'text') continue;
    if (!m.payload.body.toLowerCase().includes(q)) continue;
    const conv = conversations.value.get(m.convId);
    if (!conv || conv.removed) continue;
    hits.push({ convId: m.convId, seq: m.seq, title: conversationTitle(conv, me), sender: m.sender, ts: m.ts, body: m.payload.body });
  }
  // Newest first: in a chat that has been running for years, the useful
  // answer is almost always the recent one.
  hits.sort((a, b) => b.ts - a.ts);
  return hits.slice(0, MAX_PER_GROUP);
}

/**
 * The directory only matches a prefix, and only while the administrator leaves
 * it on. A person who is not in it can still be reached by typing their name
 * in full — that is the exact lookup key discovery uses (PROTOCOL.md §7).
 */
async function matchPeople(q: string): Promise<PersonHit[]> {
  const me = session.value!.accountId;
  const known = new Set<string>();
  for (const c of conversations.value.values()) {
    if (c.removed) continue;
    for (const id of c.serverMembers) if (id !== me) known.add(id);
  }
  const decorate = (u: DirectoryUser & { online?: boolean; last_seen?: number }): PersonHit => ({
    ...u,
    online: u.online ?? false,
    lastSeen: u.last_seen ?? 0,
    known: known.has(u.id),
  });
  try {
    const r = await http.users(q);
    peopleUnavailable.value = false;
    const hits = r.users.filter((u) => u.id !== me);
    if (hits.length) return hits.slice(0, MAX_PER_GROUP).map(decorate);
  } catch {
    // The administrator switched the listing off for everybody.
    peopleUnavailable.value = true;
  }
  // Nothing in the listing: the name may be complete and belong to somebody
  // who asked not to be listed. The exact lookup answers either way — it is
  // where the keys come from, so it cannot be hidden.
  try {
    const u = await http.user(q);
    if (u.id === me) return [];
    return [decorate({ id: u.id, username: u.username, display_name: u.display_name ?? '', is_bot: !!u.is_bot })];
  } catch {
    return [];
  }
}

let runToken = 0;

/** Runs one search. Later calls win: an earlier one that finishes late is dropped. */
export async function run(): Promise<void> {
  const q = normalise(query.value);
  const token = ++runToken;
  if (!q) {
    chats.value = [];
    people.value = [];
    messages.value = [];
    busy.value = false;
    return;
  }
  busy.value = true;
  chats.value = matchChats(q);
  const [stored, found] = await Promise.all([allMessages().catch(() => [] as StoredMessage[]), matchPeople(q)]);
  if (token !== runToken) return;
  messages.value = matchMessages(stored, q);
  people.value = found;
  busy.value = false;
}

export function reset(): void {
  runToken++;
  query.value = '';
  filter.value = 'all';
  chats.value = [];
  people.value = [];
  messages.value = [];
  busy.value = false;
}

/** Splits a string around the match so the hit can be drawn in the accent colour. */
export function highlight(text: string, q: string): [string, string, string] {
  const at = text.toLowerCase().indexOf(normalise(q));
  if (at < 0) return [text, '', ''];
  const end = at + normalise(q).length;
  return [text.slice(0, at), text.slice(at, end), text.slice(end)];
}
