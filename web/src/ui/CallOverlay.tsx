import { useEffect, useRef, useState } from 'preact/hooks';
import { t } from '../i18n';
import { acceptCall, call, dismissEndedCall, hangup, rejectCall, startScreenShare, stopScreenShare, toggleCamera, toggleMute } from '../state/calls';
import { session, usernameOf } from '../state/model';
import { Icon } from './Icons';
import { exitFullscreen, isFullscreen, toggleFullscreen, useFullscreen } from './fullscreen';

function useElapsed(since: number | null): string {
  const [, tick] = useState(0);
  useEffect(() => {
    if (!since) return;
    const timer = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(timer);
  }, [since]);
  if (!since) return '';
  const s = Math.floor((Date.now() - since) / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

/** Keeps a media element bound to a stream (the element may mount later than the stream). */
function useMedia<T extends HTMLMediaElement>(stream: MediaStream | null) {
  const ref = useRef<T>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || el.srcObject === stream) return;
    el.srcObject = stream;
    if (stream) void el.play().catch(() => {});
  });
  return ref;
}

export function CallOverlay() {
  const c = call.value!;
  const me = session.value!;
  const remoteMedia = c.remoteVideo || c.remoteSharing;
  const audioRef = useMedia<HTMLAudioElement>(c.remoteAudio);
  const screenVideo = useMedia<HTMLVideoElement>(c.remoteSharing ? c.remoteScreen : null);
  const cameraVideo = useMedia<HTMLVideoElement>(c.remoteVideo ? c.remoteCamera : null);
  const selfVideo = useMedia<HTMLVideoElement>(c.localCamera);
  const screenRef = useRef<HTMLDivElement>(null);
  const fullscreen = useFullscreen(screenRef);
  const elapsed = useElapsed(c.startedAt);

  // Leave full screen as soon as nothing remote is shown or the call ends.
  useEffect(() => {
    if ((!remoteMedia || c.status === 'ended') && isFullscreen(screenRef.current)) exitFullscreen();
  }, [remoteMedia, c.status]);

  const toggle = () => {
    if (remoteMedia) toggleFullscreen(screenRef.current);
  };

  const peer = usernameOf(c.peer, me.accountId);
  const incoming = c.status === 'ringing-in';

  // The status row: the state tile, the headline the e2e tests read, and a sub-line.
  let statusText: string;
  let subText = '';
  let tileState = '';
  let tileIcon: 'phone' | 'phone-off' | 'video' = 'phone';
  switch (c.status) {
    case 'ringing-out':
      statusText = t('calling', { peer });
      subText = c.video ? t('video_call') : t('voice_call');
      tileIcon = c.video ? 'video' : 'phone';
      break;
    case 'ringing-in':
      statusText = t('incoming_call', { peer });
      subText = c.remoteVideo ? t('incoming_video_call', { peer }) : t('voice_call');
      tileState = 'incoming';
      tileIcon = c.remoteVideo ? 'video' : 'phone';
      break;
    case 'connecting':
      statusText = t('call_connecting');
      subText = t('e2e_hint');
      break;
    case 'active':
      statusText = t('in_call', { peer, time: elapsed });
      subText = t('e2e_hint');
      tileState = 'active';
      break;
    default:
      statusText = t('call_ended');
      subText = c.endReason && c.endReason !== 'ended' ? t(`reason_${c.endReason}` as 'reason_missed') : '';
      tileState = 'ended';
      tileIcon = 'phone-off';
  }

  // No stage while the call is still ringing in: nothing is playing yet, and
  // the design draws an incoming call as the compact 340 card.
  const stage = !incoming && (remoteMedia || c.localCamera !== null);
  const live = c.status === 'active' || c.status === 'connecting' || c.status === 'ringing-out';
  // The four in-call controls; while the call still rings out only "Hang up" is offered.
  const controls = c.status === 'active' || c.status === 'connecting';

  const muteLabel = c.muted ? t('unmute') : t('mute');
  const muteIcon = c.muted ? 'mic' : 'mic-off';
  const cameraLabel = c.video ? t('camera_off') : t('camera_on');
  const cameraIcon = c.video ? 'video-off' : 'video';
  const shareLabel = c.sharing ? t('stop_sharing') : t('share_screen');
  const shareIcon = c.sharing ? 'monitor-off' : 'monitor';
  const fullscreenLabel = fullscreen ? t('exit_fullscreen') : t('fullscreen');

  return (
    <div class={`call ${incoming ? 'incoming' : ''} ${remoteMedia && !incoming ? 'call-video' : ''}`}>
      <audio ref={audioRef} autoplay />
      <div class="call-status">
        <span class={`call-tile ${tileState}`}>
          <Icon name={tileIcon} size={20} />
        </span>
        <span class="call-text">
          <strong>{statusText}</strong>
          {subText && <span class="call-sub">{subText}</span>}
        </span>
      </div>
      <div ref={screenRef} class={`call-screen ${stage ? '' : 'hidden'}`} onDblClick={toggle}>
        <div class={`call-stage ${c.remoteSharing && c.remoteVideo ? 'both' : ''}`}>
          {c.remoteSharing && <video class="call-main" ref={screenVideo} autoplay playsInline muted />}
          {c.remoteVideo && <video class={c.remoteSharing ? 'call-pip' : 'call-main'} ref={cameraVideo} autoplay playsInline muted />}
          {remoteMedia && !incoming && (
            <span class="plate">
              <Icon name={c.remoteSharing ? 'monitor' : 'user'} size={12} />
              {peer}
            </span>
          )}
        </div>
        {c.localCamera && <video class={`call-self ${remoteMedia ? '' : 'alone'}`} ref={selfVideo} autoplay playsInline muted />}
        {remoteMedia && (
          <div class="call-screen-tools">
            <button type="button" class="small" onClick={toggle} title={fullscreenLabel}>
              <Icon name="maximize" size={16} />
              {fullscreenLabel}
            </button>
          </div>
        )}
        {/* The full-screen chrome: the status top left and the floating cluster at the bottom. */}
        {fullscreen && <span class="call-fs-status">{statusText}</span>}
        {fullscreen && controls && (
          <div class="call-fs-bar">
            <button type="button" class="fs-btn" onClick={toggleMute} disabled={!c.localStream} title={muteLabel}>
              <Icon name={muteIcon} size={20} />
            </button>
            <button type="button" class="fs-btn" onClick={() => void toggleCamera()} disabled={!c.localStream} title={cameraLabel}>
              <Icon name={cameraIcon} size={20} />
            </button>
            <button
              type="button"
              class={`fs-btn ${c.sharing ? 'active' : ''}`}
              onClick={() => void (c.sharing ? stopScreenShare() : startScreenShare())}
              disabled={c.status !== 'active'}
              title={shareLabel}
            >
              <Icon name={shareIcon} size={20} />
            </button>
            <button type="button" class="danger fill" onClick={hangup}>
              <Icon name="phone-off" size={20} />
              {t('hang_up')}
            </button>
          </div>
        )}
      </div>
      <div class={`call-actions ${controls ? 'live' : ''}`}>
        {incoming && (
          <>
            <button type="button" class="primary" onClick={() => void acceptCall()}>
              <Icon name="phone" size={20} />
              {t('answer')}
            </button>
            <button type="button" class="danger fill" onClick={rejectCall}>
              <Icon name="phone-off" size={20} />
              {t('decline')}
            </button>
          </>
        )}
        {controls && (
          <>
            <button type="button" onClick={toggleMute} disabled={!c.localStream}>
              <Icon name={muteIcon} size={16} />
              {muteLabel}
            </button>
            <button type="button" onClick={() => void toggleCamera()} disabled={!c.localStream}>
              <Icon name={cameraIcon} size={16} />
              {cameraLabel}
            </button>
            <button type="button" class={c.sharing ? 'soft' : ''} onClick={() => void (c.sharing ? stopScreenShare() : startScreenShare())} disabled={c.status !== 'active'}>
              <Icon name={shareIcon} size={16} />
              {shareLabel}
            </button>
            {remoteMedia && <span class="grow" />}
            <button type="button" class="danger fill" onClick={hangup}>
              <Icon name="phone-off" size={16} />
              {t('hang_up')}
            </button>
          </>
        )}
        {live && !controls && (
          <button type="button" class="danger fill" onClick={hangup}>
            <Icon name="phone-off" size={20} />
            {t('hang_up')}
          </button>
        )}
        {c.status === 'ended' && (
          <button type="button" onClick={dismissEndedCall}>
            {t('close')}
          </button>
        )}
      </div>
    </div>
  );
}
