// W02 search block and W02b results: the field with its filter chips, and the
// three groups that replace the conversation list while something is typed.
import type { ComponentChildren } from 'preact';
import { useEffect, useRef } from 'preact/hooks';
import { formatWhen, t } from '../i18n';
import { openDirectWith } from '../state/messaging';
import { selectedId, showToast, usernameOf, session } from '../state/model';
import {
  busy,
  chats,
  type ChatHit,
  filter,
  highlight,
  type MessageHit,
  messages,
  people,
  peopleUnavailable,
  type PersonHit,
  query,
  reset,
  run,
  type SearchFilter,
} from '../state/search';
import { historyLoad, loadAllHistory } from '../state/sync';
import { Icon } from './Icons';

const FILTERS: SearchFilter[] = ['all', 'chats', 'people', 'messages'];
const LABEL = { all: 'filter_all', chats: 'filter_chats', people: 'filter_people', messages: 'filter_messages' } as const;

/** The matched part of a string, drawn in the accent colour rather than on a background. */
function Marked({ text }: { text: string }) {
  const [before, hit, after] = highlight(text, query.value);
  if (!hit) return <>{text}</>;
  return (
    <>
      {before}
      <span class="hit">{hit}</span>
      {after}
    </>
  );
}

export function SearchBox() {
  const input = useRef<HTMLInputElement>(null);
  // The search runs as the query is typed, one run behind at worst.
  useEffect(() => {
    const id = setTimeout(() => void run(), 120);
    return () => clearTimeout(id);
  }, [query.value]);
  const active = query.value.length > 0;
  return (
    <div class="search">
      <div class={active ? 'search-field active' : 'search-field'} onClick={() => input.current?.focus()}>
        <Icon name="search" size={16} />
        <input
          ref={input}
          type="search"
          value={query.value}
          placeholder={t('search_placeholder')}
          aria-label={t('search_placeholder')}
          onInput={(e) => (query.value = (e.target as HTMLInputElement).value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              e.stopPropagation(); // Escape otherwise closes the conversation
              reset();
            }
          }}
        />
        {active && (
          <button type="button" class="clear" title={t('search_clear')} onClick={reset}>
            <Icon name="x" size={12} />
          </button>
        )}
      </div>
      <div class="chips">
        {FILTERS.map((f) => (
          <button key={f} type="button" class={filter.value === f ? 'chip active' : 'chip'} aria-pressed={filter.value === f} onClick={() => (filter.value = f)}>
            {t(LABEL[f])}
          </button>
        ))}
      </div>
    </div>
  );
}

function ChatRow({ c }: { c: ChatHit }) {
  return (
    <li class="hit-row chat" onClick={() => ((selectedId.value = c.id), reset())}>
      {c.kind === 'group' && <Icon name="users" size={16} />}
      {c.isBot && <Icon name="bot" size={16} />}
      <div class="lines">
        <span class="line-1">
          <Marked text={c.title} />
        </span>
        <span class="line-2">{c.kind === 'group' ? t('members_count', { n: c.members }) : t('direct_chat')}</span>
      </div>
      {c.retention > 0 && <Icon name="timer" size={16} />}
    </li>
  );
}

function PersonRow({ p }: { p: PersonHit }) {
  const write = async () => {
    try {
      selectedId.value = await openDirectWith(p.id);
      reset();
    } catch (e) {
      showToast(e instanceof Error ? e.message : String(e));
    }
  };
  return (
    <li class="hit-row person">
      <span class={p.online ? 'dot online' : 'dot idle'} />
      <div class="lines">
        <span class="line-1">
          @<Marked text={p.username} />
        </span>
        {/* A stranger is told so; somebody already in a chat gets the more
            useful line, when they were last about. */}
        <span class="line-2">{!p.known ? t('search_no_common') : p.lastSeen ? t('search_last_seen', { date: formatWhen(p.lastSeen * 1000) }) : ''}</span>
      </div>
      <button type="button" class="link" onClick={write}>
        {t('search_write')}
      </button>
    </li>
  );
}

function MessageRow({ m }: { m: MessageHit }) {
  const me = session.value!.accountId;
  return (
    <li class="hit-row message" onClick={() => ((selectedId.value = m.convId), reset())}>
      <span class="line-1">
        <span class="where">
          {m.title} · {usernameOf(m.sender, me)}
        </span>
        <span class="when">{formatWhen(m.ts)}</span>
      </span>
      <span class="snippet">
        <Marked text={m.body} />
      </span>
    </li>
  );
}

function Group({ label, n, first, children }: { label: string; n: number; first: boolean; children: ComponentChildren }) {
  if (!n) return null;
  return (
    <>
      <li class={first ? 'hit-group' : 'hit-group ruled'}>{label}</li>
      {children}
    </>
  );
}

export function SearchResults() {
  const f = filter.value;
  const showChats = f === 'all' || f === 'chats';
  const showPeople = f === 'all' || f === 'people';
  const showMessages = f === 'all' || f === 'messages';
  const shown = (showChats ? chats.value.length : 0) + (showPeople ? people.value.length : 0) + (showMessages ? messages.value.length : 0);
  const loading = historyLoad.value;
  return (
    <div class="results">
      <ul class="hits">
        {showChats && (
          <Group label={t('search_group_chats', { n: chats.value.length })} n={chats.value.length} first>
            {chats.value.map((c) => (
              <ChatRow key={c.id} c={c} />
            ))}
          </Group>
        )}
        {showPeople && (
          <Group label={t('search_group_people', { n: people.value.length })} n={people.value.length} first={!showChats || !chats.value.length}>
            {people.value.map((p) => (
              <PersonRow key={p.id} p={p} />
            ))}
          </Group>
        )}
        {showMessages && (
          <Group
            label={t('search_group_messages', { n: messages.value.length })}
            n={messages.value.length}
            first={(!showChats || !chats.value.length) && (!showPeople || !people.value.length)}
          >
            {messages.value.map((m) => (
              <MessageRow key={`${m.convId}:${m.seq}`} m={m} />
            ))}
          </Group>
        )}
        {!shown && !busy.value && <li class="hit-empty">{t('search_nothing_found')}</li>}
        {showPeople && peopleUnavailable.value && <li class="hit-note">{t('search_people_off')}</li>}
      </ul>
      {showMessages && (
        <div class="results-foot">
          <p class="note">{t('search_local_note')}</p>
          {loading ? (
            <span class="note busy">{t('search_loading_history', { done: loading.done, total: loading.total })}</span>
          ) : (
            <button type="button" class="link" title={t('search_load_history_hint')} onClick={() => void loadAllHistory()}>
              {t('search_load_history')}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
