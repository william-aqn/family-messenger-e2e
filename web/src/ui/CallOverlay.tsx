import { useEffect, useRef, useState } from 'preact/hooks';
import { t } from '../i18n';
import { acceptCall, call, dismissEndedCall, hangup, rejectCall, startScreenShare, stopScreenShare, toggleCamera, toggleMute } from '../state/calls';
import { session, usernameOf } from '../state/model';
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
  let statusText: string;
  switch (c.status) {
    case 'ringing-out':
      statusText = t('calling', { peer });
      break;
    case 'ringing-in':
      statusText = c.remoteVideo ? t('incoming_video_call', { peer }) : t('incoming_call', { peer });
      break;
    case 'connecting':
      statusText = t('call_connecting');
      break;
    case 'active':
      statusText = t('in_call', { peer, time: elapsed });
      break;
    default:
      statusText = c.endReason && c.endReason !== 'ended' ? t('call_ended_reason', { reason: t(`reason_${c.endReason}` as 'reason_missed') }) : t('call_ended');
  }
  const stage = remoteMedia || c.localCamera !== null;
  const live = c.status === 'active' || c.status === 'connecting' || c.status === 'ringing-out';

  return (
    <div class={`call ${remoteMedia ? 'call-video' : ''}`}>
      <audio ref={audioRef} autoplay />
      <div class="call-status">{statusText}</div>
      <div ref={screenRef} class={`call-screen ${stage ? '' : 'hidden'}`} onDblClick={toggle}>
        <div class={`call-stage ${c.remoteSharing && c.remoteVideo ? 'both' : ''}`}>
          {c.remoteSharing && <video class="call-main" ref={screenVideo} autoplay playsInline muted />}
          {c.remoteVideo && <video class={c.remoteSharing ? 'call-pip' : 'call-main'} ref={cameraVideo} autoplay playsInline muted />}
        </div>
        {c.localCamera && <video class={`call-self ${remoteMedia ? '' : 'alone'}`} ref={selfVideo} autoplay playsInline muted />}
        {remoteMedia && (
          <div class="call-screen-tools">
            <button type="button" onClick={toggle} title={fullscreen ? t('exit_fullscreen') : t('fullscreen')}>
              {fullscreen ? t('exit_fullscreen') : t('fullscreen')}
            </button>
          </div>
        )}
      </div>
      <div class="call-actions">
        {c.status === 'ringing-in' && (
          <>
            <button class="primary" onClick={() => void acceptCall()}>
              {t('answer')}
            </button>
            <button class="danger" onClick={rejectCall}>
              {t('decline')}
            </button>
          </>
        )}
        {live && (
          <>
            <button onClick={toggleMute} disabled={!c.localStream}>
              {c.muted ? t('unmute') : t('mute')}
            </button>
            <button onClick={() => void toggleCamera()} disabled={!c.localStream}>
              {c.video ? t('camera_off') : t('camera_on')}
            </button>
            <button onClick={() => void (c.sharing ? stopScreenShare() : startScreenShare())} disabled={c.status !== 'active'}>
              {c.sharing ? t('stop_sharing') : t('share_screen')}
            </button>
            <button class="danger" onClick={hangup}>
              {t('hang_up')}
            </button>
          </>
        )}
        {c.status === 'ended' && <button onClick={dismissEndedCall}>{t('close')}</button>}
      </div>
    </div>
  );
}
