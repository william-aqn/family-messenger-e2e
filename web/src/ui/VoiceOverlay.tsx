import { t } from '../i18n';
import { conversationTitle, conversations, session, usernameOf } from '../state/model';
import { joinVoice, leaveVoice, participantsOf, toggleVoiceMute, voice } from '../state/voice';

/** Floating panel while this device is in a group's voice channel. */
export function VoiceOverlay() {
  const v = voice.value!;
  const me = session.value!;
  const conv = conversations.value.get(v.convId);
  const people = [...participantsOf(v.convId)].sort((a, b) => Number(b.session === v.session) - Number(a.session === v.session));
  return (
    <div class="call voice">
      <div class="call-status">🎙 {t('voice_title', { group: conv ? conversationTitle(conv, me.accountId) : t('group') })}</div>
      <ul class="voice-list">
        {people.map((p) => {
          const self = p.session === v.session;
          const state = self ? null : (v.peers[p.session] ?? 'connecting');
          return (
            <li key={p.session} class={state ?? 'self'}>
              <span class="voice-name">{usernameOf(p.account, me.accountId)}</span>
              {p.muted && <span title={t('mute')}>🔇</span>}
              {state && <span class="muted small">{t(`voice_state_${state}` as 'voice_state_connected')}</span>}
            </li>
          );
        })}
      </ul>
      <div class="call-actions">
        <button onClick={toggleVoiceMute}>{v.muted ? t('unmute') : t('mute')}</button>
        <button class="danger" onClick={() => void leaveVoice()}>
          {t('voice_leave')}
        </button>
      </div>
    </div>
  );
}

/** Strip under a group's header: who is in the voice channel, join/leave. */
export function VoiceBar({ convId }: { convId: string }) {
  const me = session.value!;
  const joinedHere = voice.value?.convId === convId;
  const people = participantsOf(convId);
  if (!people.length && !joinedHere) return null;
  const names = people.map((p) => usernameOf(p.account, me.accountId)).join(', ');
  return (
    <div class="notice small voice-bar">
      <span>🎙 {names ? t('voice_in_channel', { names }) : t('voice_empty')}</span>
      {joinedHere ? (
        <button class="link" onClick={() => void leaveVoice()}>
          {t('voice_leave')}
        </button>
      ) : (
        <button class="link" onClick={() => void joinVoice(convId)}>
          {t('voice_join')}
        </button>
      )}
    </div>
  );
}
