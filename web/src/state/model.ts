// Reactive application state (Preact signals). Persistence lives in store/db.
import { computed, signal } from '@preact/signals';
import type { Payload, ServerSettings } from '../api/types';
import type { Contact, Conversation, StoredMessage } from '../store/db';
import { t } from '../i18n';

export interface SessionInfo {
  accountId: string;
  deviceId: string;
  username: string;
  token: string;
  isAdmin: boolean;
}

export interface PendingMessage {
  clientMsgId: string;
  convId: string;
  payload: Payload;
  ts: number;
  failed?: string;
  uploading?: boolean;
}

export const session = signal<SessionInfo | null>(null);
export const conversations = signal<Map<string, Conversation>>(new Map());
export const contacts = signal<Map<string, Contact>>(new Map());
/** Decrypted messages of conversations that have been opened, by conversation id. */
export const messages = signal<Map<string, StoredMessage[]>>(new Map());
export const pending = signal<PendingMessage[]>([]);
export const selectedId = signal<string | null>(null);
export const syncing = signal(false);
export const toast = signal<string | null>(null);
export const serverSettings = signal<ServerSettings | null>(null);
export const serverVersion = signal<string>('');

/** This bundle's build number; the server reports its own, and they match unless the server was updated. */
export const APP_VERSION = __APP_VERSION__;

/** A newer client is being served: the page should be reloaded. Development builds never nag. */
export const updateAvailable = computed(() => APP_VERSION !== 'dev' && serverVersion.value !== '' && serverVersion.value !== 'dev' && serverVersion.value !== APP_VERSION);

export function setConversation(c: Conversation): void {
  const m = new Map(conversations.value);
  m.set(c.id, c);
  conversations.value = m;
}

export function setContact(c: Contact): void {
  const m = new Map(contacts.value);
  m.set(c.id, c);
  contacts.value = m;
}

export function setMessages(convId: string, list: StoredMessage[]): void {
  const m = new Map(messages.value);
  m.set(convId, list);
  messages.value = m;
}

export function resetState(): void {
  session.value = null;
  conversations.value = new Map();
  contacts.value = new Map();
  messages.value = new Map();
  pending.value = [];
  selectedId.value = null;
  serverSettings.value = null;
}

export const sortedConversations = computed(() =>
  [...conversations.value.values()].filter((c) => !c.removed).sort((a, b) => b.updatedAt - a.updatedAt),
);

export const selectedConversation = computed(() => (selectedId.value ? (conversations.value.get(selectedId.value) ?? null) : null));

export function otherMember(c: Conversation, me: string): string | undefined {
  return c.serverMembers.find((id) => id !== me) ?? c.roster?.find((id) => id !== me);
}

export function conversationTitle(c: Conversation, me: string): string {
  if (c.kind === 'direct') {
    const other = otherMember(c, me);
    const contact = other ? contacts.value.get(other) : undefined;
    if (!contact) return t('direct_chat');
    return contact.isBot ? `🤖 ${contact.displayName || contact.username}` : contact.username;
  }
  return c.name || t('group');
}

export function hasBot(c: Conversation): boolean {
  return c.serverMembers.some((id) => contacts.value.get(id)?.isBot);
}

export function usernameOf(id: string, me: string): string {
  if (id === me) return t('you');
  return contacts.value.get(id)?.username ?? id.slice(0, 8);
}

let toastTimer: ReturnType<typeof setTimeout> | null = null;
export function showToast(text: string): void {
  toast.value = text;
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (toast.value = null), 4000);
}
