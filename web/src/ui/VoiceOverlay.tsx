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
  toggleVoiceCamera,
  toggleVoiceMute,
  voice,
  voiceCameras,
  type VoiceParticipant,
  voiceSelfCamera,
  voiceStreams,
} from '../state/voice';
import { exitFullscreen, isFullscreen, toggleFullscreen, useFullscreen } from './fullscreen';
import { Icon } from './Icons';

/** One track of the channel: somebody's camera, or somebody's screen. */
interface Tile {
  key: string;
  kind: 'camera' | 'screen';
  p: VoiceParticipant;
  stream: MediaStream | null;
  self: boolean;
}

/**
 * Every participant is a tile whether or not their camera is on, and every
 * shared screen is a tile of its own — that is what makes the channel show
 * faces and screens side by side instead of screens alone.
 */
function tilesOf(people: VoiceParticipant[], selfSession: string): Tile[] {
  const out: Tile[] = [];
  for (const p of people) {
    const self = p.session === selfSession;
    out.push({
      key: `${p.session}:camera`,
      kind: 'camera',
      p,
      stream: (self ? voiceSelfCamera.value : (voiceCameras.value.get(p.session) ?? null)) ?? null,
      self,
    });
    // Our own screen is not looped back: the browser is already showing it.
    if (p.sharing && !self) out.push({ key: `${p.session}:screen`, kind: 'screen', p, stream: voiceStreams.value.get(p.session) ?? null, self });
  }
  return out;
}

function VoiceTile({ tile, pinned, onPin }: { tile: Tile; pinned: boolean; onPin: () => void }) {
  const ref = useRef<HTMLVideoElement>(null);
  const me = session.value!;
  const stream = tile.stream;
  const name = tile.self ? me.username : usernameOf(tile.p.account, me.accountId);
  // The track is negotiated up front and starts carrying frames later, so the
  // stream is usually here before the tile is live. The element only exists
  // once it is, which is why the effect has to watch both.
  const live = !!stream && (tile.kind === 'camera' ? tile.self || tile.p.camera : tile.p.sharing);
  useEffect(() => {
    const el = ref.current;
    if (el && stream && el.srcObject !== stream) {
      el.srcObject = stream;
      void el.play().catch(() => {});
    }
  }, [stream, live]);
  const classes = ['voice-video', tile.kind, tile.self && 'self', pinned && 'pinned', !live && 'idle'].filter(Boolean).join(' ');
  return (
    <div class={classes} onDblClick={onPin}>
      {live ? (
        <video ref={ref} autoplay playsInline muted />
      ) : tile.kind === 'camera' ? (
        <span class="voice-avatar">{name.slice(0, 1).toUpperCase()}</span>
      ) : (
        <span class="voice-waiting">{t('voice_waiting_video')}</span>
      )}
      <span class="voice-label">
        {tile.kind === 'screen' && <Icon name="monitor" size={12} />}
        {tile.kind === 'screen' ? t('screen_of', { name }) : name}
        {tile.self && <span class="muted"> ({t('you')})</span>}
        {tile.kind === 'camera' && tile.p.muted && <Icon name="mic-off" size={12} />}
        {tile.kind === 'camera' && !live && <Icon name="video-off" size={12} />}
      </span>
      <button type="button" class="voice-pin" title={pinned ? t('unpin_tile') : t('pin_tile')} onClick={onPin}>
        <Icon name="pin" size={12} />
      </button>
    </div>
  );
}

/** Floating panel while this device is in a group's voice channel. */
export function VoiceOverlay() {
  const v = voice.value!;
  const me = session.value!;
  const conv = conversations.value.get(v.convId);
  const people = [...participantsOf(v.convId)].sort((a, b) => Number(b.session === v.session) - Number(a.session === v.session));
  const tiles = tilesOf(people, v.session);
  const screens = tiles.filter((x) => x.kind === 'screen').length;
  const cameras = tiles.filter((x) => x.kind === 'camera' && x.stream).length;
  const anyVideo = screens > 0 || cameras > 0;
  const [pin, setPin] = useState<string | null>(null);
  // A pinned tile that went away falls back to the grid.
  const pinned = pin && tiles.some((x) => x.key === pin) ? pin : null;
  const speaker = pinned !== null;
  const ordered = pinned ? [...tiles].sort((a, b) => Number(b.key === pinned) - Number(a.key === pinned)) : tiles;
  const screensRef = useRef<HTMLDivElement>(null);
  const fullscreen = useFullscreen(screensRef);
  useEffect(() => {
    if (!anyVideo && isFullscreen(screensRef.current)) exitFullscreen();
  }, [anyVideo]);

  return (
    <div class={`call voice ${anyVideo ? 'call-video' : ''}`}>
      <div class="call-status">
        <Icon name="headphones" size={20} />
        <span class="grow">{t('voice_title', { group: conv ? conversationTitle(conv, me.accountId) : t('group') })}</span>
        {anyVideo && (
          <button type="button" class="small" title={fullscreen ? t('exit_fullscreen') : t('fullscreen')} onClick={() => toggleFullscreen(screensRef.current)}>
            <Icon name="maximize" size={16} />
            {fullscreen ? t('exit_fullscreen') : t('fullscreen')}
          </button>
        )}
      </div>
      {anyVideo && (
        <div ref={screensRef} class="voice-screens">
          <div class="voice-tabs">
            <button type="button" class={speaker ? '' : 'active'} onClick={() => setPin(null)}>
              {t('grid_mode')}
            </button>
            <button type="button" class={speaker ? 'active' : ''} onClick={() => setPin(pinned ?? (tiles.find((x) => x.stream)?.key ?? null))}>
              {t('speaker_mode')}
            </button>
            <span class="voice-counts">
              <Icon name="monitor" size={16} />
              {screens}
              <Icon name="video" size={16} />
              {cameras}
              <span class="muted">{t('voice_tiles', { tiles: tiles.length, people: people.length })}</span>
            </span>
            {/* Only reachable inside full screen, where the card header is hidden. */}
            {fullscreen && (
              <button type="button" class="voice-fs" onClick={() => toggleFullscreen(screensRef.current)}>
                {t('exit_fullscreen')}
              </button>
            )}
          </div>
          <div class={`voice-grid ${speaker ? 'focus' : ''}`}>
            {ordered.map((tile) => (
              <VoiceTile key={tile.key} tile={tile} pinned={tile.key === pinned} onPin={() => setPin(tile.key === pinned ? null : tile.key)} />
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
              <span title={p.camera ? t('camera_on') : t('camera_off')}>
                <Icon name={p.camera ? 'video' : 'video-off'} size={16} />
              </span>
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
        <button type="button" class={v.camera ? 'soft' : ''} onClick={toggleVoiceCamera}>
          <Icon name={v.camera ? 'video-off' : 'video'} size={16} />
          {v.camera ? t('camera_off') : t('camera_on')}
        </button>
        <button type="button" class={v.sharing ? 'soft' : ''} onClick={() => void (v.sharing ? stopVoiceShare() : startVoiceShare())}>
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
                  {p.camera && (
                    <span title={t('camera_on')}>
                      {' '}
                      <Icon name="video" size={16} class="inline" />
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
