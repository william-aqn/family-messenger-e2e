// Local persistence in IndexedDB. Everything here is already decrypted;
// the browser profile is the trust boundary.
import { type DBSchema, type IDBPDatabase, openDB } from 'idb';
import type { Payload } from '../api/types';

export interface Contact {
  id: string;
  username: string;
  displayName?: string;
  isBot?: boolean;
  signPub: Uint8Array;
  encPub: Uint8Array;
  verified: boolean;
  /** Keys the server or an event presented that differ from the pinned ones. */
  pendingKeys: { signPub: Uint8Array; encPub: Uint8Array } | null;
  firstSeen: number;
}

export interface Conversation {
  id: string;
  kind: 'direct' | 'group';
  name: string;
  createdBy: string;
  createdAt: number;
  role: 'owner' | 'member';
  joinedSeq: number;
  lastSeq: number;
  readSeq: number;
  /** Highest seq whose envelope has been processed locally. */
  syncedSeq: number;
  /** Member ids according to the server (routing). */
  serverMembers: string[];
  /** Member ids according to the latest signed membership event, if any. */
  roster: string[] | null;
  rosterSeq: number;
  /** Disappearing-messages timer in seconds, 0 = off (server-enforced). */
  retentionSeconds: number;
  /** Preview of the newest message; seq names it so that edits and deletions can refresh the preview. */
  lastMessage: { text: string; ts: number; sender: string; seq?: number } | null;
  updatedAt: number;
  removed: boolean;
}

export interface StoredMessage {
  convId: string;
  seq: number;
  clientMsgId: string;
  sender: string;
  senderDevice: string;
  ts: number;
  serverTs: number;
  payload: Payload | null;
  error?: string;
  /** The sender replaced the text with a later `text.edit` (PROTOCOL.md §6.3). */
  edited?: boolean;
}

interface MsgrDB extends DBSchema {
  meta: { key: string; value: unknown };
  contacts: { key: string; value: Contact };
  conversations: { key: string; value: Conversation };
  messages: { key: [string, number]; value: StoredMessage; indexes: { byConv: string; byClient: string } };
}

let dbp: Promise<IDBPDatabase<MsgrDB>> | null = null;

function getDB(): Promise<IDBPDatabase<MsgrDB>> {
  dbp ??= openDB<MsgrDB>('family-messenger', 2, {
    upgrade(db, oldVersion, _newVersion, tx) {
      if (oldVersion < 1) {
        db.createObjectStore('meta');
        db.createObjectStore('contacts', { keyPath: 'id' });
        db.createObjectStore('conversations', { keyPath: 'id' });
        const messages = db.createObjectStore('messages', { keyPath: ['convId', 'seq'] });
        messages.createIndex('byConv', 'convId');
      }
      if (oldVersion < 2) {
        // Version 2: edits refer to messages by client id.
        tx.objectStore('messages').createIndex('byClient', 'clientMsgId');
      }
    },
  });
  return dbp;
}

export async function getMeta<T>(key: string): Promise<T | undefined> {
  return (await (await getDB()).get('meta', key)) as T | undefined;
}

export async function setMeta(key: string, value: unknown): Promise<void> {
  await (await getDB()).put('meta', value, key);
}

export async function putContact(c: Contact): Promise<void> {
  await (await getDB()).put('contacts', c);
}

export async function allContacts(): Promise<Contact[]> {
  return (await getDB()).getAll('contacts');
}

export async function putConversation(c: Conversation): Promise<void> {
  await (await getDB()).put('conversations', c);
}

export async function allConversations(): Promise<Conversation[]> {
  return (await getDB()).getAll('conversations');
}

export async function putMessage(m: StoredMessage): Promise<void> {
  await (await getDB()).put('messages', m);
}

export async function getMessage(convId: string, seq: number): Promise<StoredMessage | undefined> {
  return (await getDB()).get('messages', [convId, seq]);
}

/** Finds a sender's message by its client id (unique per sender, PROTOCOL.md §2). */
export async function messageByClientId(convId: string, sender: string, clientMsgId: string): Promise<StoredMessage | undefined> {
  const list = await (await getDB()).getAllFromIndex('messages', 'byClient', clientMsgId);
  return list.find((m) => m.convId === convId && m.sender === sender);
}

export async function deleteStoredMessage(convId: string, seq: number): Promise<void> {
  await (await getDB()).delete('messages', [convId, seq]);
}

export async function messagesFor(convId: string): Promise<StoredMessage[]> {
  const list = await (await getDB()).getAllFromIndex('messages', 'byConv', convId);
  return list.sort((a, b) => a.seq - b.seq);
}

/** Deletes messages of a conversation older than the given server time. */
export async function deleteMessagesBefore(convId: string, serverTs: number): Promise<number> {
  const db = await getDB();
  const tx = db.transaction('messages', 'readwrite');
  let deleted = 0;
  for (const m of await tx.store.index('byConv').getAll(convId)) {
    if (m.serverTs < serverTs) {
      await tx.store.delete([m.convId, m.seq]);
      deleted++;
    }
  }
  await tx.done;
  return deleted;
}

export async function clearAll(): Promise<void> {
  const db = await getDB();
  const tx = db.transaction(['meta', 'contacts', 'conversations', 'messages'], 'readwrite');
  await Promise.all([
    tx.objectStore('meta').clear(),
    tx.objectStore('contacts').clear(),
    tx.objectStore('conversations').clear(),
    tx.objectStore('messages').clear(),
    tx.done,
  ]);
}
