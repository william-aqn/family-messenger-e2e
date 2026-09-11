// Pinned and muted chats (W19). Both are this person's own view of the list:
// the server never hears about them and the other side cannot tell, so they
// live in this browser, under a key of their own per account.
import { effect, signal } from '@preact/signals';
import { session } from './model';

type Prefs = { pinned: string[]; muted: string[]; hidden: string[] };

const empty: Prefs = { pinned: [], muted: [], hidden: [] };

function key(accountId: string): string {
  return `family-messenger.chats.${accountId}`;
}

function read(accountId: string): Prefs {
  try {
    const raw = localStorage.getItem(key(accountId));
    if (!raw) return empty;
    const p = JSON.parse(raw) as Partial<Prefs>;
    return {
      pinned: Array.isArray(p.pinned) ? p.pinned : [],
      muted: Array.isArray(p.muted) ? p.muted : [],
      hidden: Array.isArray(p.hidden) ? p.hidden : [],
    };
  } catch {
    return empty;
  }
}

/** Chats this person keeps at the top of the list. */
export const pinnedChats = signal<Set<string>>(new Set());
/** Chats that make no sound and raise no notification. */
export const mutedChats = signal<Set<string>>(new Set());
/** Chats removed from the list until something new arrives in them. */
export const hiddenChats = signal<Set<string>>(new Set());

effect(() => {
  const id = session.value?.accountId;
  const p = id ? read(id) : empty;
  pinnedChats.value = new Set(p.pinned);
  mutedChats.value = new Set(p.muted);
  hiddenChats.value = new Set(p.hidden);
});

function save(): void {
  const id = session.peek()?.accountId;
  if (!id) return;
  const prefs: Prefs = {
    pinned: [...pinnedChats.peek()],
    muted: [...mutedChats.peek()],
    hidden: [...hiddenChats.peek()],
  };
  try {
    localStorage.setItem(key(id), JSON.stringify(prefs));
  } catch {
    /* storage unavailable: the setting only lasts this session */
  }
}

function toggle(set: typeof pinnedChats, convId: string, on?: boolean): void {
  const next = new Set(set.peek());
  if (on ?? !next.has(convId)) next.add(convId);
  else next.delete(convId);
  set.value = next;
  save();
}

export function togglePinned(convId: string): void {
  toggle(pinnedChats, convId);
}

export function toggleMuted(convId: string): void {
  toggle(mutedChats, convId);
}

/** Takes the chat out of the list; the next message in it brings it back. */
export function hideChat(convId: string): void {
  toggle(hiddenChats, convId, true);
}

export function unhideChat(convId: string): void {
  if (!hiddenChats.peek().has(convId)) return;
  toggle(hiddenChats, convId, false);
}

/** Everything this person remembered about a chat that is gone for good. */
export function forgetChat(convId: string): void {
  for (const set of [pinnedChats, mutedChats, hiddenChats]) toggle(set, convId, false);
}
