// Group voice channels. Every member of a group can join its channel at any
// time (no ringing). Audio flows in a full mesh of 1:1 WebRTC connections, so
// it stays end-to-end encrypted like calls and the server never touches media;
// signaling travels inside ephemeral envelopes of the group (PROTOCOL.md §6).
// Every pair also negotiates a video track, so any participant can stream
// their screen to everybody else and viewers pick one stream or watch them all.
import { effect, signal } from '@preact/signals';
import type { Payload } from '../api/types';
import { newUuid } from '../crypto/ids';
import { t } from '../i18n';
import { call, iceServers } from './calls';
import { FLAG_EPHEMERAL, sendPayload } from './messaging';
import { conversationTitle, conversations, session, showToast, usernameOf } from './model';

export type PeerState = 'connecting' | 'connected' | 'failed';

export interface VoiceParticipant {
  session: string;
  account: string;
  device: string;
  muted: boolean;
  /** Streaming their screen (from the join/here/share signals). */
  sharing: boolean;
  /** Last join or heartbeat, ms since epoch. */
  seen: number;
}

export interface VoiceState {
  convId: string;
  session: string;
  muted: boolean;
  sharing: boolean;
  joinedAt: number;
  /** Connection state per remote session. */
  peers: Record<string, PeerState>;
}

/** The channel this device is in, if any. */
export const voice = signal<VoiceState | null>(null);
/** Who is in which group's channel, by conversation id (learned from voice.* signals). */
export const voiceRooms = signal<Map<string, VoiceParticipant[]>>(new Map());
/**
 * Remote video streams by session. Every connected peer has one (the track is
 * negotiated up front); it carries frames only while that peer is sharing.
 */
export const voiceStreams = signal<Map<string, MediaStream>>(new Map());

const HEARTBEAT_MS = 20_000;
const EXPIRE_MS = 65_000;
const ICE_REFRESH_MS = 20 * 60_000;

interface Peer {
  pc: RTCPeerConnection;
  audio: HTMLAudioElement;
  videoSender: RTCRtpSender | null;
  queued: RTCIceCandidateInit[];
  outgoing: RTCIceCandidateInit[];
  flush: ReturnType<typeof setTimeout> | null;
}

const peers = new Map<string, Peer>();
let localStream: MediaStream | null = null;
let screenTrack: MediaStreamTrack | null = null;
let heartbeat: ReturnType<typeof setInterval> | null = null;
let pruneTimer: ReturnType<typeof setInterval> | null = null;
let cachedIce: RTCIceServer[] = [];
let iceFetchedAt = 0;

export function participantsOf(convId: string): VoiceParticipant[] {
  return voiceRooms.value.get(convId) ?? [];
}

function setParticipant(convId: string, p: VoiceParticipant): void {
  const rooms = new Map(voiceRooms.value);
  const list = (rooms.get(convId) ?? []).filter((x) => x.session !== p.session);
  list.push(p);
  rooms.set(convId, list);
  voiceRooms.value = rooms;
  if (!pruneTimer) pruneTimer = setInterval(prune, 15_000);
}

function removeParticipant(convId: string, sessionId: string): void {
  const rooms = new Map(voiceRooms.value);
  const list = (rooms.get(convId) ?? []).filter((x) => x.session !== sessionId);
  if (list.length) rooms.set(convId, list);
  else rooms.delete(convId);
  voiceRooms.value = rooms;
}

/** Our own entry in the room list, from the current state. */
function updateSelf(): void {
  const v = voice.value;
  const me = session.value;
  if (!v || !me) return;
  setParticipant(v.convId, { session: v.session, account: me.accountId, device: me.deviceId, muted: v.muted, sharing: v.sharing, seen: Date.now() });
}

function setPeerState(sessionId: string, state: PeerState | null): void {
  const v = voice.value;
  if (!v) return;
  const next = { ...v.peers };
  if (state) next[sessionId] = state;
  else delete next[sessionId];
  voice.value = { ...v, peers: next };
}

function publishStream(sessionId: string, stream: MediaStream | null): void {
  const next = new Map(voiceStreams.value);
  if (stream) next.set(sessionId, stream);
  else next.delete(sessionId);
  voiceStreams.value = next;
}

async function signalTo(convId: string, payload: Payload): Promise<void> {
  try {
    await sendPayload(convId, payload, FLAG_EPHEMERAL);
  } catch (e) {
    console.error('voice signaling failed', e);
  }
}

async function refreshIce(): Promise<void> {
  if (Date.now() - iceFetchedAt < ICE_REFRESH_MS) return;
  cachedIce = await iceServers();
  iceFetchedAt = Date.now();
}

function presence(): Payload {
  const v = voice.value!;
  return { t: 'voice.here', session: v.session, muted: v.muted, sharing: v.sharing };
}

export async function joinVoice(convId: string): Promise<void> {
  const s = session.value;
  const conv = conversations.value.get(convId);
  if (!s || !conv || conv.kind !== 'group') return;
  if (call.value && call.value.status !== 'ended') {
    showToast(t('already_in_call'));
    return;
  }
  if (voice.value?.convId === convId) return;
  if (voice.value) await leaveVoice();
  let mic: MediaStream;
  try {
    mic = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
  } catch {
    showToast(t('voice_mic_failed'));
    return;
  }
  await refreshIce();
  localStream = mic;
  const id = newUuid();
  voice.value = { convId, session: id, muted: false, sharing: false, joinedAt: Date.now(), peers: {} };
  updateSelf();
  await signalTo(convId, { t: 'voice.join', session: id, muted: false, sharing: false });
  for (const p of participantsOf(convId)) maybeConnect(p);
  heartbeat = setInterval(() => {
    const v = voice.value;
    if (!v) return;
    prune();
    void refreshIce();
    void signalTo(v.convId, presence());
    // Retries connections that failed or were never established.
    for (const p of participantsOf(v.convId)) maybeConnect(p);
  }, HEARTBEAT_MS);
}

export async function leaveVoice(): Promise<void> {
  const v = voice.value;
  if (!v) return;
  if (heartbeat) clearInterval(heartbeat);
  heartbeat = null;
  if (screenTrack) {
    screenTrack.stop();
    screenTrack = null;
  }
  for (const id of [...peers.keys()]) closePeer(id);
  voiceStreams.value = new Map();
  localStream?.getTracks().forEach((track) => track.stop());
  localStream = null;
  removeParticipant(v.convId, v.session);
  voice.value = null;
  await signalTo(v.convId, { t: 'voice.leave', session: v.session });
}

export function toggleVoiceMute(): void {
  const v = voice.value;
  if (!v || !localStream) return;
  const muted = !v.muted;
  for (const track of localStream.getAudioTracks()) track.enabled = !muted;
  voice.value = { ...v, muted };
  updateSelf();
  void signalTo(v.convId, presence());
}

/** Streams this screen to every participant (each pair has its own video track). */
export async function startVoiceShare(): Promise<void> {
  const v = voice.value;
  if (!v || v.sharing) return;
  if (!navigator.mediaDevices?.getDisplayMedia) {
    showToast(t('screen_share_unavailable'));
    return;
  }
  try {
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: { ideal: 15, max: 30 } }, audio: false });
    const track = stream.getVideoTracks()[0];
    if (!track || !voice.value) {
      track?.stop();
      return;
    }
    screenTrack = track;
    for (const p of peers.values()) if (p.videoSender) void p.videoSender.replaceTrack(track).catch(() => {});
    track.onended = () => void stopVoiceShare();
    voice.value = { ...voice.value, sharing: true };
    updateSelf();
    void signalTo(v.convId, { t: 'voice.share', session: v.session, on: true });
  } catch (e) {
    if (!(e instanceof DOMException && e.name === 'NotAllowedError')) showToast(t('screen_share_failed'));
  }
}

export async function stopVoiceShare(): Promise<void> {
  const v = voice.value;
  const wasSharing = screenTrack !== null || !!v?.sharing;
  if (screenTrack) {
    screenTrack.stop();
    screenTrack = null;
  }
  for (const p of peers.values()) if (p.videoSender) void p.videoSender.replaceTrack(null).catch(() => {});
  if (!v) return;
  voice.value = { ...v, sharing: false };
  updateSelf();
  if (wasSharing) void signalTo(v.convId, { t: 'voice.share', session: v.session, on: false });
}

function closePeer(sessionId: string): void {
  const p = peers.get(sessionId);
  if (!p) return;
  peers.delete(sessionId);
  if (p.flush) clearTimeout(p.flush);
  p.pc.onconnectionstatechange = null;
  p.pc.close();
  p.audio.pause();
  p.audio.srcObject = null;
  publishStream(sessionId, null);
  setPeerState(sessionId, null);
}

function createPeer(convId: string, remote: string): Peer {
  closePeer(remote);
  const pc = new RTCPeerConnection({ iceServers: cachedIce });
  const audio = new Audio();
  audio.autoplay = true;
  const peer: Peer = { pc, audio, videoSender: null, queued: [], outgoing: [], flush: null };
  peers.set(remote, peer);
  setPeerState(remote, 'connecting');
  if (localStream) for (const track of localStream.getAudioTracks()) pc.addTrack(track, localStream);
  pc.ontrack = (ev) => {
    if (ev.track.kind === 'audio') {
      audio.srcObject = ev.streams[0] ?? new MediaStream([ev.track]);
      void audio.play().catch(() => {});
    } else {
      publishStream(remote, new MediaStream([ev.track]));
    }
  };
  pc.onicecandidate = (ev) => {
    if (!ev.candidate) return;
    peer.outgoing.push(ev.candidate.toJSON());
    if (!peer.flush) {
      peer.flush = setTimeout(() => {
        peer.flush = null;
        const batch = peer.outgoing.splice(0);
        const v = voice.value;
        if (batch.length && v && peers.get(remote) === peer) void signalTo(convId, { t: 'voice.ice', session: v.session, to: remote, candidates: batch });
      }, 150);
    }
  };
  pc.onconnectionstatechange = () => {
    if (peers.get(remote) !== peer) return;
    switch (pc.connectionState) {
      case 'connected':
        setPeerState(remote, 'connected');
        break;
      case 'disconnected':
        setPeerState(remote, 'connecting');
        break;
      case 'failed':
      case 'closed':
        // Gone for good: the next heartbeat from either side starts over.
        closePeer(remote);
        setPeerState(remote, 'failed');
        break;
    }
  };
  return peer;
}

/** The pair's video transceiver: negotiated once, fed with the screen track while sharing. */
function ensureVideo(peer: Peer): void {
  let tx = peer.pc.getTransceivers().find((tr) => tr.receiver.track.kind === 'video');
  // With the mic stream announced as the track's stream the m-line carries an
  // msid, so native receivers (the Flutter app) get the track inside a stream;
  // a transceiver created from a remote offer needs it set explicitly.
  if (!tx) tx = peer.pc.addTransceiver('video', { direction: 'sendrecv', streams: localStream ? [localStream] : [] });
  else {
    if (tx.direction !== 'sendrecv') tx.direction = 'sendrecv';
    if (localStream && typeof tx.sender.setStreams === 'function') tx.sender.setStreams(localStream);
  }
  peer.videoSender = tx.sender;
  if (screenTrack && tx.sender.track !== screenTrack) void tx.sender.replaceTrack(screenTrack).catch(() => {});
}

function maybeConnect(p: VoiceParticipant): void {
  const v = voice.value;
  if (!v || p.session === v.session || peers.has(p.session)) return;
  if (Date.now() - p.seen > EXPIRE_MS) return;
  // Both sides learn each other's session from join/here; the smaller session
  // id sends the offer (ids are UUIDv7, so the earlier participant does).
  if (v.session < p.session) void offerTo(v.convId, p.session);
}

async function offerTo(convId: string, remote: string): Promise<void> {
  const v = voice.value;
  if (!v) return;
  const peer = createPeer(convId, remote);
  try {
    ensureVideo(peer);
    const offer = await peer.pc.createOffer();
    await peer.pc.setLocalDescription(offer);
    await signalTo(convId, { t: 'voice.offer', session: v.session, to: remote, sdp: offer.sdp ?? '' });
  } catch (e) {
    console.error('voice offer failed', e);
    closePeer(remote);
  }
}

async function acceptOffer(convId: string, remote: string, sdp: string): Promise<void> {
  const v = voice.value;
  if (!v) return;
  const peer = createPeer(convId, remote);
  try {
    await peer.pc.setRemoteDescription({ type: 'offer', sdp });
    ensureVideo(peer);
    const answer = await peer.pc.createAnswer();
    await peer.pc.setLocalDescription(answer);
    await signalTo(convId, { t: 'voice.answer', session: v.session, to: remote, sdp: answer.sdp ?? '' });
    await flushIce(remote);
  } catch (e) {
    console.error('voice answer failed', e);
    closePeer(remote);
  }
}

async function flushIce(remote: string): Promise<void> {
  const p = peers.get(remote);
  if (!p) return;
  const batch = p.queued.splice(0);
  for (const c of batch) await p.pc.addIceCandidate(c).catch(() => {});
}

/** Forgets sessions whose heartbeat stopped (closed tab, lost network). */
function prune(): void {
  const v = voice.value;
  const now = Date.now();
  const rooms = new Map(voiceRooms.value);
  let changed = false;
  for (const [convId, list] of rooms) {
    const keep = list.filter((p) => now - p.seen <= EXPIRE_MS || (v !== null && v.convId === convId && p.session === v.session));
    if (keep.length === list.length) continue;
    changed = true;
    for (const gone of list) if (!keep.includes(gone)) closePeer(gone.session);
    if (keep.length) rooms.set(convId, keep);
    else rooms.delete(convId);
  }
  if (changed) voiceRooms.value = rooms;
}

export function handleVoiceSignal(sender: string, senderDevice: string, convId: string, payload: Payload): void {
  const me = session.value;
  if (!me || !('session' in payload)) return;
  const v = voice.value;
  if (v && payload.session === v.session) return; // our own signal echoed back
  const here = v !== null && v.convId === convId;
  switch (payload.t) {
    case 'voice.join':
    case 'voice.here': {
      const known = participantsOf(convId).some((p) => p.session === payload.session);
      const participant: VoiceParticipant = {
        session: payload.session,
        account: sender,
        device: senderDevice,
        muted: payload.muted,
        sharing: payload.sharing === true,
        seen: Date.now(),
      };
      setParticipant(convId, participant);
      if (payload.t === 'voice.join') {
        if (here) void signalTo(convId, presence()); // tell the newcomer we are here
        else if (!known && sender !== me.accountId) {
          const conv = conversations.value.get(convId);
          if (conv) showToast(t('voice_joined_toast', { who: usernameOf(sender, me.accountId), group: conversationTitle(conv, me.accountId) }));
        }
      }
      if (here) maybeConnect(participant);
      break;
    }
    case 'voice.share': {
      const existing = participantsOf(convId).find((p) => p.session === payload.session);
      if (existing) setParticipant(convId, { ...existing, sharing: payload.on, seen: Date.now() });
      break;
    }
    case 'voice.leave':
      removeParticipant(convId, payload.session);
      closePeer(payload.session);
      break;
    case 'voice.offer':
      if (v && here && payload.to === v.session) void acceptOffer(convId, payload.session, payload.sdp);
      break;
    case 'voice.answer': {
      if (!v || !here || payload.to !== v.session) return;
      const p = peers.get(payload.session);
      if (p && p.pc.signalingState === 'have-local-offer') {
        void p.pc
          .setRemoteDescription({ type: 'answer', sdp: payload.sdp })
          .then(() => flushIce(payload.session))
          .catch(() => closePeer(payload.session));
      }
      break;
    }
    case 'voice.ice': {
      if (!v || !here || payload.to !== v.session) return;
      const p = peers.get(payload.session);
      if (!p) return;
      if (p.pc.remoteDescription) for (const c of payload.candidates) void p.pc.addIceCandidate(c).catch(() => {});
      else p.queued.push(...payload.candidates);
      break;
    }
  }
}

// Best effort: tell the others when the tab closes; they would notice after
// the heartbeat timeout anyway.
window.addEventListener('pagehide', () => {
  const v = voice.value;
  if (v) void signalTo(v.convId, { t: 'voice.leave', session: v.session });
});

// Logging out drops the channel.
effect(() => {
  if (!session.value && voice.value) void leaveVoice();
});
