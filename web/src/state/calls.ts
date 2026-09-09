// 1:1 calls with camera video and screen sharing over WebRTC. Signaling
// travels inside ephemeral, signed and encrypted envelopes (PROTOCOL.md §6).
// Every call negotiates three slots up front (audio, camera video, screen
// video), so cameras and screens switch on and off with replaceTrack only.
import { signal } from '@preact/signals';
import { http } from '../api/http';
import type { Payload } from '../api/types';
import { newUuid } from '../crypto/ids';
import { t } from '../i18n';
import { FLAG_EPHEMERAL, FLAG_URGENT, sendPayload } from './messaging';
import { conversations, otherMember, session, showToast } from './model';
import { voice } from './voice';

export type CallStatus = 'ringing-out' | 'ringing-in' | 'connecting' | 'active' | 'ended';

/** Why a call ended; translated with t('reason_' + key) in the UI. */
export type EndReason =
  | 'no_answer'
  | 'missed'
  | 'declined'
  | 'busy'
  | 'answered_elsewhere'
  | 'declined_elsewhere'
  | 'connection_failed'
  | 'could_not_start'
  | 'could_not_answer'
  | 'ended';

export interface CallState {
  id: string;
  convId: string;
  peer: string;
  direction: 'in' | 'out';
  status: CallStatus;
  muted: boolean;
  /** Our camera is on. */
  video: boolean;
  /** Our screen is shared. */
  sharing: boolean;
  /** The peer's camera / screen are on (from the call.video / call.share signals). */
  remoteVideo: boolean;
  remoteSharing: boolean;
  startedAt: number | null;
  endReason: EndReason | null;
  /** Microphone. */
  localStream: MediaStream | null;
  /** Camera preview. */
  localCamera: MediaStream | null;
  remoteAudio: MediaStream;
  remoteCamera: MediaStream | null;
  remoteScreen: MediaStream | null;
}

export const call = signal<CallState | null>(null);

const RING_TIMEOUT_MS = 45_000;

let pc: RTCPeerConnection | null = null;
let cameraSender: RTCRtpSender | null = null;
let screenSender: RTCRtpSender | null = null;
let cameraStream: MediaStream | null = null;
let screenTrack: MediaStreamTrack | null = null;
/** Placeholder stream announced for the screen slot, so receivers get it apart from the camera. */
let screenSlot: MediaStream | null = null;
let pendingOffer: RTCSessionDescriptionInit | null = null;
let queuedIce: RTCIceCandidateInit[] = [];
let outgoingIce: RTCIceCandidateInit[] = [];
let iceFlushTimer: ReturnType<typeof setTimeout> | null = null;
let ringTimer: ReturnType<typeof setTimeout> | null = null;
let endTimer: ReturnType<typeof setTimeout> | null = null;

function update(patch: Partial<CallState>): void {
  if (call.value) call.value = { ...call.value, ...patch };
}

async function sendSignal(convId: string, payload: Payload): Promise<void> {
  try {
    await sendPayload(convId, payload, FLAG_EPHEMERAL | FLAG_URGENT);
  } catch (e) {
    console.error('call signaling failed', e);
  }
}

export async function iceServers(): Promise<RTCIceServer[]> {
  try {
    const res = await http.turn();
    return res.ice_servers.map((s) => ({ urls: s.urls, username: s.username, credential: s.credential }));
  } catch {
    return [];
  }
}

function freshState(id: string, convId: string, peer: string, direction: 'in' | 'out', status: CallStatus): CallState {
  return {
    id,
    convId,
    peer,
    direction,
    status,
    muted: false,
    video: false,
    sharing: false,
    remoteVideo: false,
    remoteSharing: false,
    startedAt: null,
    endReason: null,
    localStream: null,
    localCamera: null,
    remoteAudio: new MediaStream(),
    remoteCamera: null,
    remoteScreen: null,
  };
}

async function createPeer(convId: string, callId: string): Promise<RTCPeerConnection> {
  const peer = new RTCPeerConnection({ iceServers: await iceServers() });
  pc = peer;
  screenSlot = new MediaStream();
  const remoteAudio = call.value?.remoteAudio ?? new MediaStream();
  peer.ontrack = (ev) => {
    if (ev.track.kind === 'audio') {
      remoteAudio.addTrack(ev.track);
      update({ remoteAudio });
      return;
    }
    // Video slots are told apart by their order: camera first, screen second.
    const videos = peer.getTransceivers().filter((tr) => tr.receiver.track.kind === 'video');
    const screen = videos.indexOf(ev.transceiver) === 1;
    // Whether the slot is in use comes from the call.video / call.share
    // signals only: browsers unmute every receiver once the transport is up,
    // frames or not, so the track's mute state says nothing.
    const stream = new MediaStream([ev.track]);
    update(screen ? { remoteScreen: stream } : { remoteCamera: stream });
  };
  peer.onicecandidate = (ev) => {
    if (!ev.candidate) return;
    outgoingIce.push(ev.candidate.toJSON());
    if (!iceFlushTimer) {
      iceFlushTimer = setTimeout(() => {
        iceFlushTimer = null;
        const batch = outgoingIce.splice(0);
        if (batch.length && call.value?.id === callId) void sendSignal(convId, { t: 'call.ice', call: callId, candidates: batch });
      }, 150);
    }
  };
  peer.onconnectionstatechange = () => {
    if (pc !== peer) return;
    switch (peer.connectionState) {
      case 'connected':
        if (call.value && call.value.status !== 'active') update({ status: 'active', startedAt: call.value.startedAt ?? Date.now() });
        break;
      case 'failed':
        endCall('connection_failed', true);
        break;
      case 'disconnected':
        if (call.value?.status === 'active') showToast(t('call_interrupted'));
        break;
    }
  };
  const mic = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
  for (const track of mic.getAudioTracks()) peer.addTrack(track, mic);
  update({ localStream: mic });
  return peer;
}

/**
 * Finds (or adds) the two video transceivers in slot order and attaches the
 * current camera and screen tracks. Each slot announces its own stream so
 * native receivers get the tracks in separate streams.
 */
function ensureVideoSlots(peer: RTCPeerConnection): void {
  const videos = peer.getTransceivers().filter((tr) => tr.receiver.track.kind === 'video');
  const mic = call.value?.localStream;
  const slotStreams = [mic ? [mic] : [], screenSlot ? [screenSlot] : []];
  if (videos.length < 1) videos.push(peer.addTransceiver('video', { direction: 'sendrecv', streams: slotStreams[0] }));
  if (videos.length < 2) videos.push(peer.addTransceiver('video', { direction: 'sendrecv', streams: slotStreams[1] }));
  videos.slice(0, 2).forEach((tx, i) => {
    if (tx.direction !== 'sendrecv') tx.direction = 'sendrecv';
    // Transceivers created from a remote offer have no stream yet ("msid:-"),
    // and native receivers (the Flutter app) drop tracks without one.
    if (typeof tx.sender.setStreams === 'function') tx.sender.setStreams(...slotStreams[i]);
  });
  cameraSender = videos[0].sender;
  screenSender = videos[1].sender;
  const cam = cameraStream?.getVideoTracks()[0];
  if (cam && cameraSender.track !== cam) void cameraSender.replaceTrack(cam).catch(() => {});
  if (screenTrack && screenSender.track !== screenTrack) void screenSender.replaceTrack(screenTrack).catch(() => {});
}

export async function startCall(convId: string, video = false): Promise<void> {
  const s = session.value;
  const conv = conversations.value.get(convId);
  if (!s || !conv || conv.kind !== 'direct') return;
  if (call.value && call.value.status !== 'ended') {
    showToast(t('already_in_call'));
    return;
  }
  if (voice.value) {
    showToast(t('voice_leave_first'));
    return;
  }
  const peerId = otherMember(conv, s.accountId);
  if (!peerId) return;
  const id = newUuid();
  call.value = freshState(id, convId, peerId, 'out', 'ringing-out');
  try {
    const peer = await createPeer(convId, id);
    if (video) await enableCamera(false);
    ensureVideoSlots(peer);
    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    await sendSignal(convId, { t: 'call.offer', call: id, sdp: offer.sdp ?? '', video: call.value?.video === true });
    ringTimer = setTimeout(() => {
      if (call.value?.id === id && call.value.status === 'ringing-out') {
        void sendSignal(convId, { t: 'call.hangup', call: id });
        endCall('no_answer', false);
      }
    }, RING_TIMEOUT_MS);
  } catch (e) {
    console.error('call start failed', e);
    endCall('could_not_start', true);
  }
}

export function handleCallSignal(sender: string, senderDevice: string, convId: string, payload: Payload): void {
  const s = session.value;
  if (!s) return;
  const current = call.value;
  if (sender === s.accountId) {
    // Our own other device: it answered or dismissed the same incoming call.
    if (senderDevice === s.deviceId) return;
    if (current && 'call' in payload && payload.call === current.id && current.status === 'ringing-in') {
      if (payload.t === 'call.answer') endCall('answered_elsewhere', false);
      if (payload.t === 'call.reject') endCall('declined_elsewhere', false);
    }
    return;
  }
  switch (payload.t) {
    case 'call.offer':
      // Busy while in another call or in a group voice channel.
      if ((current && current.status !== 'ended') || voice.value) {
        if (current?.id !== payload.call) void sendSignal(convId, { t: 'call.reject', call: payload.call, reason: 'busy' });
        return;
      }
      pendingOffer = { type: 'offer', sdp: payload.sdp };
      queuedIce = [];
      call.value = { ...freshState(payload.call, convId, sender, 'in', 'ringing-in'), remoteVideo: payload.video === true };
      ringTimer = setTimeout(() => {
        if (call.value?.id === payload.call && call.value.status === 'ringing-in') endCall('missed', false);
      }, RING_TIMEOUT_MS);
      break;
    case 'call.answer':
      if (current?.id === payload.call && current.status === 'ringing-out' && pc) {
        clearRing();
        update({ status: 'connecting', remoteVideo: payload.video === true });
        void pc
          .setRemoteDescription({ type: 'answer', sdp: payload.sdp })
          .then(flushQueuedIce)
          .catch(() => endCall('connection_failed', true));
      }
      break;
    case 'call.ice':
      if (current?.id === payload.call) {
        if (pc?.remoteDescription) {
          for (const c of payload.candidates) void pc.addIceCandidate(c).catch(() => {});
        } else {
          queuedIce.push(...payload.candidates);
        }
      }
      break;
    case 'call.reject':
      if (current?.id === payload.call) endCall(payload.reason === 'busy' ? 'busy' : 'declined', false);
      break;
    case 'call.hangup':
      if (current?.id === payload.call) endCall(current.status === 'ringing-in' ? 'missed' : 'ended', false);
      break;
    case 'call.video':
      if (current?.id === payload.call) update({ remoteVideo: payload.on });
      break;
    case 'call.share':
      if (current?.id === payload.call) update({ remoteSharing: payload.on });
      break;
  }
}

async function flushQueuedIce(): Promise<void> {
  if (!pc) return;
  const batch = queuedIce.splice(0);
  for (const c of batch) await pc.addIceCandidate(c).catch(() => {});
}

export async function acceptCall(): Promise<void> {
  const current = call.value;
  if (!current || current.status !== 'ringing-in' || !pendingOffer) return;
  clearRing();
  update({ status: 'connecting' });
  try {
    const peer = await createPeer(current.convId, current.id);
    await peer.setRemoteDescription(pendingOffer);
    // A video call is answered with the camera on (audio only if it fails).
    if (current.remoteVideo) await enableCamera(false);
    ensureVideoSlots(peer);
    const answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    await sendSignal(current.convId, { t: 'call.answer', call: current.id, sdp: answer.sdp ?? '', video: call.value?.video === true });
    await flushQueuedIce();
  } catch (e) {
    console.error('answer failed', e);
    endCall('could_not_answer', true);
  }
}

export function rejectCall(): void {
  const current = call.value;
  if (!current || current.status !== 'ringing-in') return;
  void sendSignal(current.convId, { t: 'call.reject', call: current.id, reason: 'declined' });
  endCall('declined', false);
}

export function hangup(): void {
  const current = call.value;
  if (!current || current.status === 'ended') return;
  void sendSignal(current.convId, { t: 'call.hangup', call: current.id });
  endCall('ended', false);
}

export function toggleMute(): void {
  const current = call.value;
  if (!current?.localStream) return;
  const muted = !current.muted;
  for (const track of current.localStream.getAudioTracks()) track.enabled = !muted;
  update({ muted });
}

async function enableCamera(notify: boolean): Promise<boolean> {
  const current = call.value;
  if (!current) return false;
  if (cameraStream) return true;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { width: { ideal: 1280 }, height: { ideal: 720 }, facingMode: 'user' } });
    if (!call.value || call.value.status === 'ended') {
      stream.getTracks().forEach((track) => track.stop());
      return false;
    }
    cameraStream = stream;
    const track = stream.getVideoTracks()[0];
    if (cameraSender && track) void cameraSender.replaceTrack(track).catch(() => {});
    update({ video: true, localCamera: stream });
    if (notify) void sendSignal(current.convId, { t: 'call.video', call: current.id, on: true });
    return true;
  } catch {
    showToast(t('camera_failed'));
    return false;
  }
}

function disableCamera(notify: boolean): void {
  const current = call.value;
  if (cameraStream) {
    cameraStream.getTracks().forEach((track) => track.stop());
    cameraStream = null;
  }
  if (cameraSender && pc) void cameraSender.replaceTrack(null).catch(() => {});
  if (!current) return;
  update({ video: false, localCamera: null });
  if (notify && current.status !== 'ended') void sendSignal(current.convId, { t: 'call.video', call: current.id, on: false });
}

/** Switches our camera on or off during a call (an audio call becomes a video call). */
export async function toggleCamera(): Promise<void> {
  const current = call.value;
  if (!current || current.status === 'ended') return;
  if (current.video) disableCamera(true);
  else await enableCamera(true);
}

export async function startScreenShare(): Promise<void> {
  const current = call.value;
  if (!current || !pc || current.sharing) return;
  if (!navigator.mediaDevices?.getDisplayMedia) {
    showToast(t('screen_share_unavailable'));
    return;
  }
  try {
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: 15, max: 30 } }, audio: false });
    const track = stream.getVideoTracks()[0];
    if (!track) return;
    screenTrack = track;
    if (screenSender) await screenSender.replaceTrack(track);
    track.onended = () => void stopScreenShare();
    update({ sharing: true });
    void sendSignal(current.convId, { t: 'call.share', call: current.id, on: true });
  } catch (e) {
    if (!(e instanceof DOMException && e.name === 'NotAllowedError')) showToast(t('screen_share_failed'));
  }
}

export async function stopScreenShare(): Promise<void> {
  const current = call.value;
  const wasSharing = screenTrack !== null || !!current?.sharing;
  if (screenTrack) {
    screenTrack.stop();
    screenTrack = null;
  }
  if (screenSender && pc) await screenSender.replaceTrack(null).catch(() => {});
  update({ sharing: false });
  if (wasSharing && current && current.status !== 'ended') void sendSignal(current.convId, { t: 'call.share', call: current.id, on: false });
}

function clearRing(): void {
  if (ringTimer) clearTimeout(ringTimer);
  ringTimer = null;
}

function endCall(reason: EndReason, notify: boolean): void {
  clearRing();
  if (iceFlushTimer) clearTimeout(iceFlushTimer);
  iceFlushTimer = null;
  outgoingIce = [];
  queuedIce = [];
  pendingOffer = null;
  if (screenTrack) {
    screenTrack.stop();
    screenTrack = null;
  }
  if (cameraStream) {
    cameraStream.getTracks().forEach((track) => track.stop());
    cameraStream = null;
  }
  cameraSender = null;
  screenSender = null;
  screenSlot = null;
  const current = call.value;
  current?.localStream?.getTracks().forEach((track) => track.stop());
  pc?.close();
  pc = null;
  if (current && current.status !== 'ended') {
    call.value = { ...current, status: 'ended', endReason: reason, localStream: null, localCamera: null, video: false, sharing: false };
    if (notify) showToast(t('call_ended_reason', { reason: t(`reason_${reason}` as 'reason_no_answer') }));
    if (endTimer) clearTimeout(endTimer);
    endTimer = setTimeout(() => {
      if (call.value?.status === 'ended') call.value = null;
    }, 3000);
  }
}

export function dismissEndedCall(): void {
  if (call.value?.status === 'ended') call.value = null;
}
