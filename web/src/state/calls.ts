// 1:1 voice calls with screen sharing over WebRTC. Signaling travels inside
// ephemeral, signed and encrypted envelopes (PROTOCOL.md §8).
import { signal } from '@preact/signals';
import { http } from '../api/http';
import type { Payload } from '../api/types';
import { newUuid } from '../crypto/ids';
import { t } from '../i18n';
import { FLAG_EPHEMERAL, FLAG_URGENT, sendPayload } from './messaging';
import { conversations, otherMember, session, showToast } from './model';

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
  sharing: boolean;
  remoteSharing: boolean;
  startedAt: number | null;
  endReason: EndReason | null;
  localStream: MediaStream | null;
  remoteStream: MediaStream;
}

export const call = signal<CallState | null>(null);

const RING_TIMEOUT_MS = 45_000;

let pc: RTCPeerConnection | null = null;
let videoSender: RTCRtpSender | null = null;
let screenTrack: MediaStreamTrack | null = null;
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

async function iceServers(): Promise<RTCIceServer[]> {
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
    sharing: false,
    remoteSharing: false,
    startedAt: null,
    endReason: null,
    localStream: null,
    remoteStream: new MediaStream(),
  };
}

async function createPeer(convId: string, callId: string): Promise<RTCPeerConnection> {
  const peer = new RTCPeerConnection({ iceServers: await iceServers() });
  pc = peer;
  const remoteStream = call.value?.remoteStream ?? new MediaStream();
  peer.ontrack = (ev) => {
    remoteStream.addTrack(ev.track);
    if (ev.track.kind === 'video') {
      const setRemoteSharing = () => update({ remoteSharing: !ev.track.muted && ev.track.readyState === 'live' });
      ev.track.onunmute = setRemoteSharing;
      ev.track.onmute = setRemoteSharing;
      ev.track.onended = setRemoteSharing;
      setRemoteSharing();
    }
    update({ remoteStream });
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

function ensureVideoSender(peer: RTCPeerConnection): RTCRtpSender {
  let tx = peer.getTransceivers().find((tr) => tr.receiver.track.kind === 'video');
  if (!tx) tx = peer.addTransceiver('video', { direction: 'sendrecv' });
  else if (tx.direction !== 'sendrecv') tx.direction = 'sendrecv';
  videoSender = tx.sender;
  return tx.sender;
}

export async function startCall(convId: string): Promise<void> {
  const s = session.value;
  const conv = conversations.value.get(convId);
  if (!s || !conv || conv.kind !== 'direct') return;
  if (call.value && call.value.status !== 'ended') {
    showToast(t('already_in_call'));
    return;
  }
  const peerId = otherMember(conv, s.accountId);
  if (!peerId) return;
  const id = newUuid();
  call.value = freshState(id, convId, peerId, 'out', 'ringing-out');
  try {
    const peer = await createPeer(convId, id);
    ensureVideoSender(peer);
    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    await sendSignal(convId, { t: 'call.offer', call: id, sdp: offer.sdp ?? '' });
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
      if (current && current.status !== 'ended') {
        if (current.id !== payload.call) void sendSignal(convId, { t: 'call.reject', call: payload.call, reason: 'busy' });
        return;
      }
      pendingOffer = { type: 'offer', sdp: payload.sdp };
      queuedIce = [];
      call.value = freshState(payload.call, convId, sender, 'in', 'ringing-in');
      ringTimer = setTimeout(() => {
        if (call.value?.id === payload.call && call.value.status === 'ringing-in') endCall('missed', false);
      }, RING_TIMEOUT_MS);
      break;
    case 'call.answer':
      if (current?.id === payload.call && current.status === 'ringing-out' && pc) {
        clearRing();
        update({ status: 'connecting' });
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
    ensureVideoSender(peer);
    const answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    await sendSignal(current.convId, { t: 'call.answer', call: current.id, sdp: answer.sdp ?? '' });
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

export async function startScreenShare(): Promise<void> {
  const current = call.value;
  if (!current || !pc || current.sharing) return;
  if (!navigator.mediaDevices?.getDisplayMedia) {
    showToast(t('screen_share_unavailable'));
    return;
  }
  try {
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
    const track = stream.getVideoTracks()[0];
    if (!track) return;
    screenTrack = track;
    await ensureVideoSender(pc).replaceTrack(track);
    track.onended = () => void stopScreenShare();
    update({ sharing: true });
  } catch (e) {
    if (!(e instanceof DOMException && e.name === 'NotAllowedError')) showToast(t('screen_share_failed'));
  }
}

export async function stopScreenShare(): Promise<void> {
  if (screenTrack) {
    screenTrack.stop();
    screenTrack = null;
  }
  if (videoSender && pc) await videoSender.replaceTrack(null).catch(() => {});
  update({ sharing: false });
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
  videoSender = null;
  const current = call.value;
  current?.localStream?.getTracks().forEach((track) => track.stop());
  pc?.close();
  pc = null;
  if (current && current.status !== 'ended') {
    call.value = { ...current, status: 'ended', endReason: reason, localStream: null };
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
