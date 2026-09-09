import { useEffect, useRef, useState } from 'preact/hooks';
import { t } from '../i18n';
import { acceptCall, call, dismissEndedCall, hangup, rejectCall, startScreenShare, stopScreenShare, toggleMute } from '../state/calls';
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

export function CallOverlay() {
  const c = call.value!;
  const me = session.value!;
  const audioRef = useRef<HTMLAudioElement>(null);
  const videoRef = useRef<HTMLVideoElement>(null);
  const screenRef = useRef<HTMLDivElement>(null);
  const fullscreen = useFullscreen(screenRef);
  const elapsed = useElapsed(c.startedAt);

  useEffect(() => {
    if (audioRef.current && audioRef.current.srcObject !== c.remoteStream) {
      audioRef.current.srcObject = c.remoteStream;
      void audioRef.current.play().catch(() => {});
    }
    if (videoRef.current && videoRef.current.srcObject !== c.remoteStream) {
      videoRef.current.srcObject = c.remoteStream;
      void videoRef.current.play().catch(() => {});
    }
  }, [c.remoteStream, c.remoteSharing]);

  // Leave full screen as soon as the peer stops sharing or the call ends.
  useEffect(() => {
    if ((!c.remoteSharing || c.status === 'ended') && isFullscreen(screenRef.current)) exitFullscreen();
  }, [c.remoteSharing, c.status]);

  const toggle = () => {
    if (c.remoteSharing) toggleFullscreen(screenRef.current);
  };

  const peer = usernameOf(c.peer, me.accountId);
  let statusText: string;
  switch (c.status) {
    case 'ringing-out':
      statusText = t('calling', { peer });
      break;
    case 'ringing-in':
      statusText = t('incoming_call', { peer });
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

  return (
    <div class={`call ${c.remoteSharing ? 'call-video' : ''}`}>
      <audio ref={audioRef} autoplay />
      <div class="call-status">{statusText}</div>
      <div ref={screenRef} class={`call-screen ${c.remoteSharing ? '' : 'hidden'}`} onDblClick={toggle}>
        <video ref={videoRef} autoplay playsInline muted />
        <div class="call-screen-tools">
          <button type="button" onClick={toggle} title={fullscreen ? t('exit_fullscreen') : t('fullscreen')}>
            {fullscreen ? t('exit_fullscreen') : t('fullscreen')}
          </button>
        </div>
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
        {(c.status === 'active' || c.status === 'connecting' || c.status === 'ringing-out') && (
          <>
            <button onClick={toggleMute} disabled={!c.localStream}>
              {c.muted ? t('unmute') : t('mute')}
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
