import { useEffect, useRef, useState } from 'preact/hooks';
import { t } from '../i18n';
import { conversationTitle, conversations, session, usernameOf } from '../state/model';
import {
  joinVoice,
  leaveVoice,
  participantsOf,
  startVoiceShare,
  stopVoiceShare,
  toggleVoiceMute,
  voice,
  type VoiceParticipant,
  voiceStreams,
} from '../state/voice';
import { exitFullscreen, isFullscreen, toggleFullscreen, useFullscreen } from './fullscreen';

/** One participant's screen. */
function VoiceVideo({ p, stream, onToggle }: { p: VoiceParticipant; stream: MediaStream | null; onToggle: () => void }) {
  const ref = useRef<HTMLVideoElement>(null);
  const me = session.value!;
  useEffect(() => {
    const el = ref.current;
    if (el && stream && el.srcObject !== stream) {
      el.srcObject = stream;
      void el.play().catch(() => {});
    }
  }, [stream]);
  return (
    <div class="voice-video" onDblClick={onToggle}>
      {stream ? <video ref={ref} autoplay playsInline muted /> : <div class="voice-waiting muted small">{t('voice_waiting_video')}</div>}
      <span class="voice-label">{usernameOf(p.account, me.accountId)}</span>
    </div>
  );
}

/** Floating panel while this device is in a group's voice channel. */
export function VoiceOverlay() {
  const v = voice.value!;
  const me = session.value!;
  const conv = conversations.value.get(v.convId);
  const people = [...participantsOf(v.convId)].sort((a, b) => Number(b.session === v.session) - Number(a.session === v.session));
  const streamers = people.filter((p) => p.sharing && p.session !== v.session);
  const [focus, setFocus] = useState<string | null>(null);
  // A focused streamer who stopped falls back to the grid.
  const focused = focus && streamers.some((p) => p.session === focus) ? focus : null;
  const shown = focused ? streamers.filter((p) => p.session === focused) : streamers;
  const screensRef = useRef<HTMLDivElement>(null);
  const fullscreen = useFullscreen(screensRef);
  useEffect(() => {
    if (!streamers.length && isFullscreen(screensRef.current)) exitFullscreen();
  }, [streamers.length]);

  return (
    <div class={`call voice ${streamers.length ? 'call-video' : ''}`}>
      <div class="call-status">🎙 {t('voice_title', { group: conv ? conversationTitle(conv, me.accountId) : t('group') })}</div>
      {streamers.length > 0 && (
        <div ref={screensRef} class="voice-screens">
          <div class="voice-tabs">
            <button type="button" class={focused ? '' : 'active'} onClick={() => setFocus(null)}>
              {t('voice_all_screens')}
            </button>
            {streamers.map((p) => (
              <button type="button" key={p.session} class={focused === p.session ? 'active' : ''} onClick={() => setFocus(p.session)}>
                🖥 {usernameOf(p.account, me.accountId)}
              </button>
            ))}
            <button type="button" class="voice-fs" onClick={() => toggleFullscreen(screensRef.current)} title={fullscreen ? t('exit_fullscreen') : t('fullscreen')}>
              {fullscreen ? t('exit_fullscreen') : t('fullscreen')}
            </button>
          </div>
          <div class={`voice-grid ${focused ? 'focus' : ''}`}>
            {shown.map((p) => (
              <VoiceVideo key={p.session} p={p} stream={voiceStreams.value.get(p.session) ?? null} onToggle={() => setFocus(focused ? null : p.session)} />
            ))}
          </div>
        </div>
      )}
      <ul class="voice-list">
        {people.map((p) => {
          const self = p.session === v.session;
          const state = self ? null : (v.peers[p.session] ?? 'connecting');
          return (
            <li key={p.session} class={state ?? 'self'}>
              <span class="voice-name">{usernameOf(p.account, me.accountId)}</span>
              {p.muted && <span title={t('mute')}>🔇</span>}
              {p.sharing && <span title={t('share_screen')}>🖥</span>}
              {state && <span class="muted small">{t(`voice_state_${state}` as 'voice_state_connected')}</span>}
            </li>
          );
        })}
      </ul>
      <div class="call-actions">
        <button onClick={toggleVoiceMute}>{v.muted ? t('unmute') : t('mute')}</button>
        <button onClick={() => void (v.sharing ? stopVoiceShare() : startVoiceShare())}>{v.sharing ? t('stop_sharing') : t('share_screen')}</button>
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
  const names = people.map((p) => `${usernameOf(p.account, me.accountId)}${p.sharing ? ' 🖥' : ''}`).join(', ');
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
