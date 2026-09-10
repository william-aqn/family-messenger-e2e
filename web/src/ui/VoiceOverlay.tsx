import { Fragment } from 'preact';
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
import { Icon } from './Icons';

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
      {stream ? <video ref={ref} autoplay playsInline muted /> : <span class="voice-waiting">{t('voice_waiting_video')}</span>}
      <span class="voice-label">
        <Icon name="monitor" size={12} />
        {usernameOf(p.account, me.accountId)}
      </span>
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
      <div class="call-status">
        <Icon name="headphones" size={20} />
        <span class="grow">{t('voice_title', { group: conv ? conversationTitle(conv, me.accountId) : t('group') })}</span>
        {streamers.length > 0 && (
          <button type="button" class="small" title={fullscreen ? t('exit_fullscreen') : t('fullscreen')} onClick={() => toggleFullscreen(screensRef.current)}>
            <Icon name="maximize" size={16} />
            {fullscreen ? t('exit_fullscreen') : t('fullscreen')}
          </button>
        )}
      </div>
      {streamers.length > 0 && (
        <div ref={screensRef} class="voice-screens">
          <div class="voice-tabs">
            <button type="button" class={focused ? '' : 'active'} onClick={() => setFocus(null)}>
              {t('voice_all_screens')}
            </button>
            {streamers.map((p) => (
              <button type="button" key={p.session} class={focused === p.session ? 'active' : ''} onClick={() => setFocus(p.session)}>
                <Icon name="monitor" size={16} />
                {usernameOf(p.account, me.accountId)}
              </button>
            ))}
            {/* Only reachable inside full screen, where the card header is hidden. */}
            {fullscreen && (
              <button type="button" class="voice-fs" onClick={() => toggleFullscreen(screensRef.current)}>
                {t('exit_fullscreen')}
              </button>
            )}
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
              <span class="dot" />
              <span class="voice-name">
                {self ? me.username : usernameOf(p.account, me.accountId)}
                {self && <span class="muted"> ({t('you')})</span>}
              </span>
              {p.muted && (
                <span title={t('mute')}>
                  <Icon name="mic-off" size={16} />
                </span>
              )}
              {p.sharing && (
                <span title={t('share_screen')}>
                  <Icon name="monitor" size={16} />
                </span>
              )}
              {state && <span class="voice-state">{t(`voice_state_${state}` as 'voice_state_connected')}</span>}
            </li>
          );
        })}
      </ul>
      <div class="call-actions">
        <button type="button" class={v.muted ? 'soft' : ''} onClick={toggleVoiceMute}>
          <Icon name={v.muted ? 'mic-off' : 'mic'} size={16} />
          {v.muted ? t('unmute') : t('mute')}
        </button>
        <button type="button" onClick={() => void (v.sharing ? stopVoiceShare() : startVoiceShare())}>
          <Icon name={v.sharing ? 'monitor-off' : 'monitor'} size={16} />
          {v.sharing ? t('stop_sharing') : t('share_screen')}
        </button>
        <span class="grow" />
        <button type="button" class="danger fill" onClick={() => void leaveVoice()}>
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
  // The sentence carries a monitor glyph beside every sharer, so it is split
  // around its {names} placeholder and rebuilt from the participant list.
  const [before = '', after = ''] = t('voice_in_channel').split('{names}');
  return (
    <div class="banner live voice-bar">
      <Icon name="headphones" size={20} />
      <span class="grow">
        <span>
          {people.length === 0 ? (
            t('voice_empty')
          ) : (
            <>
              {before}
              {people.map((p, i) => (
                <Fragment key={p.session}>
                  {i > 0 && ', '}
                  {usernameOf(p.account, me.accountId)}
                  {p.sharing && (
                    <span title={t('share_screen')}>
                      {' '}
                      <Icon name="monitor" size={16} class="inline" />
                    </span>
                  )}
                </Fragment>
              ))}
              {after}
            </>
          )}
        </span>
      </span>
      {joinedHere ? (
        <button type="button" class="link" onClick={() => void leaveVoice()}>
          {t('voice_leave')}
        </button>
      ) : (
        <button type="button" class="link" onClick={() => void joinVoice(convId)}>
          {t('voice_join')}
        </button>
      )}
    </div>
  );
}
