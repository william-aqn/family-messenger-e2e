// Group voice channels: any member of a group joins its channel at any time
// (no ringing). Audio flows in a full mesh of 1:1 WebRTC connections, so it
// stays end-to-end encrypted and the server never touches media; signaling
// travels inside ephemeral envelopes of the group (PROTOCOL.md §6). Every pair
// also negotiates a video track, so a participant can stream its screen to
// everybody else. Mirrors web/src/state/voice.ts.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../crypto/envelope.dart';
import '../crypto/ids.dart';
import 'app_state.dart';
import 'call_controller.dart';

enum PeerState { connecting, connected, failed }

class VoiceParticipant {
  VoiceParticipant({required this.session, required this.account, required this.device, required this.muted, required this.sharing, required this.seen});

  final String session;
  final String account;
  final String device;
  bool muted;
  /// Streaming their screen (from the join/here/share signals).
  bool sharing;
  /// Last join or heartbeat, ms since epoch.
  int seen;
}

/// This device's membership in a group's voice channel.
class VoiceChannel {
  VoiceChannel({required this.convId, required this.session});

  final String convId;
  final String session;
  bool muted = false;
  bool sharing = false;
  /// Connection state per remote session.
  final Map<String, PeerState> peers = {};
}

class _Peer {
  _Peer(this.pc);

  final RTCPeerConnection pc;
  RTCRtpTransceiver? videoTx;
  final List<Map<String, dynamic>> queued = [];
  final List<Map<String, dynamic>> outgoing = [];
  Timer? flush;
  bool remoteSet = false;
  bool closed = false;
}

class VoiceController extends ChangeNotifier {
  VoiceController(this.app);

  final AppState app;

  /// The channel this device is in, if any.
  VoiceChannel? channel;

  /// Who is in which group's channel, by conversation id (from voice.* signals).
  final Map<String, List<VoiceParticipant>> rooms = {};

  /// Video of every connected peer, by session; it shows frames only while
  /// that peer is sharing its screen.
  final Map<String, RTCVideoRenderer> renderers = {};

  static const _heartbeat = Duration(seconds: 20);
  static const _expireMs = 65000;
  static const _iceRefreshMs = 20 * 60 * 1000;

  final Map<String, _Peer> _peers = {};
  final Set<String> _connecting = {};
  MediaStream? _local;
  MediaStream? _screen;
  Timer? _heartbeatTimer;
  Timer? _pruneTimer;
  List<Map<String, dynamic>> _ice = [];
  int _iceFetchedAt = 0;

  List<VoiceParticipant> participantsOf(String convId) => rooms[convId] ?? const [];
  bool inChannel(String convId) => channel?.convId == convId;

  /// Participants streaming their screen, other than this device.
  List<VoiceParticipant> streamers() {
    final ch = channel;
    if (ch == null) return const [];
    return participantsOf(ch.convId).where((p) => p.sharing && p.session != ch.session).toList();
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> _signal(String convId, Map<String, dynamic> payload) async {
    try {
      await app.sendPayload(convId, payload, flags: flagEphemeral);
    } catch (e) {
      debugPrint('voice signaling failed: $e');
    }
  }

  Map<String, dynamic> _presence() => {'t': 'voice.here', 'session': channel!.session, 'muted': channel!.muted, 'sharing': channel!.sharing};

  void _setParticipant(String convId, VoiceParticipant p) {
    final list = rooms.putIfAbsent(convId, () => []);
    list.removeWhere((x) => x.session == p.session);
    list.add(p);
    _pruneTimer ??= Timer.periodic(const Duration(seconds: 15), (_) => _prune());
    notifyListeners();
  }

  void _removeParticipant(String convId, String session) {
    final list = rooms[convId];
    if (list == null) return;
    list.removeWhere((x) => x.session == session);
    if (list.isEmpty) rooms.remove(convId);
    notifyListeners();
  }

  /// Our own entry in the room list, from the current state.
  void _updateSelf() {
    final ch = channel;
    final me = app.session;
    if (ch == null || me == null) return;
    _setParticipant(ch.convId, VoiceParticipant(session: ch.session, account: me.accountId, device: me.deviceId, muted: ch.muted, sharing: ch.sharing, seen: _now()));
  }

  Future<void> _refreshIce() async {
    final now = _now();
    if (now - _iceFetchedAt < _iceRefreshMs) return;
    try {
      _ice = (await app.api!.turn()).map((s) => s.toRtc()).toList();
      _iceFetchedAt = now;
    } catch (_) {}
  }

  /// Joins the channel of [convId]. Returns a translation key describing why
  /// it did not happen, or null on success.
  Future<String?> join(String convId) async {
    final me = app.session;
    final conv = app.conversations[convId];
    if (me == null || conv == null || conv.kind != 'group') return null;
    final call = app.calls.call;
    if (call != null && call.status != CallStatus.ended) return 'already_in_call';
    if (channel?.convId == convId) return null;
    if (channel != null) await leave();
    MediaStream mic;
    try {
      mic = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    } catch (_) {
      return 'voice_mic_failed';
    }
    await _refreshIce();
    _local = mic;
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }
    final id = newUuid();
    channel = VoiceChannel(convId: convId, session: id);
    _updateSelf();
    await _signal(convId, {'t': 'voice.join', 'session': id, 'muted': false, 'sharing': false});
    for (final p in List.of(participantsOf(convId))) {
      _maybeConnect(p);
    }
    _heartbeatTimer = Timer.periodic(_heartbeat, (_) {
      final ch = channel;
      if (ch == null) return;
      _prune();
      unawaited(_refreshIce());
      unawaited(_signal(ch.convId, _presence()));
      // Retries connections that failed or were never established.
      for (final p in List.of(participantsOf(ch.convId))) {
        _maybeConnect(p);
      }
    });
    notifyListeners();
    return null;
  }

  Future<void> leave() async {
    final ch = channel;
    if (ch == null) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final screen = _screen;
    _screen = null;
    for (final id in List.of(_peers.keys)) {
      _closePeer(id);
    }
    final local = _local;
    _local = null;
    channel = null;
    _removeParticipant(ch.convId, ch.session);
    notifyListeners();
    await _signal(ch.convId, {'t': 'voice.leave', 'session': ch.session});
    await _dispose(screen);
    await _dispose(local);
    await disableScreenCaptureService();
  }

  Future<void> _dispose(MediaStream? stream) async {
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  Future<void> toggleMute() async {
    final ch = channel;
    final local = _local;
    if (ch == null || local == null) return;
    ch.muted = !ch.muted;
    for (final track in local.getAudioTracks()) {
      track.enabled = !ch.muted;
    }
    _updateSelf();
    await _signal(ch.convId, _presence());
  }

  /// Streams this screen to every participant. Returns a translation key on
  /// failure, null on success.
  Future<String?> startScreenShare() async {
    final ch = channel;
    if (ch == null || ch.sharing) return null;
    try {
      if (!await enableScreenCaptureService()) return 'voice_share_failed';
      final stream = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      final track = stream.getVideoTracks().first;
      _screen = stream;
      for (final p in _peers.values) {
        final tx = p.videoTx;
        if (tx == null) continue;
        try {
          await tx.sender.replaceTrack(track);
        } catch (_) {}
      }
      track.onEnded = () => stopScreenShare();
      ch.sharing = true;
      _updateSelf();
      await _signal(ch.convId, {'t': 'voice.share', 'session': ch.session, 'on': true});
      return null;
    } catch (e) {
      debugPrint('voice screen share failed: $e');
      return 'voice_share_failed';
    }
  }

  Future<void> stopScreenShare() async {
    final ch = channel;
    final wasSharing = _screen != null || (ch?.sharing ?? false);
    final screen = _screen;
    _screen = null;
    for (final p in _peers.values) {
      final tx = p.videoTx;
      if (tx == null) continue;
      try {
        await tx.sender.replaceTrack(null);
      } catch (_) {}
    }
    await _dispose(screen);
    await disableScreenCaptureService();
    if (ch != null) {
      ch.sharing = false;
      _updateSelf();
      if (wasSharing) await _signal(ch.convId, {'t': 'voice.share', 'session': ch.session, 'on': false});
    }
    notifyListeners();
  }

  void _setPeerState(String session, PeerState? state) {
    final ch = channel;
    if (ch == null) return;
    if (state == null) {
      ch.peers.remove(session);
    } else {
      ch.peers[session] = state;
    }
    notifyListeners();
  }

  Future<void> _attachRenderer(String remote, MediaStream stream) async {
    var r = renderers[remote];
    if (r == null) {
      r = RTCVideoRenderer();
      await r.initialize();
      renderers[remote] = r;
    }
    r.srcObject = stream;
    notifyListeners();
  }

  void _dropRenderer(String remote) {
    final r = renderers.remove(remote);
    if (r == null) return;
    r.srcObject = null;
    unawaited(r.dispose());
    notifyListeners();
  }

  void _closePeer(String session) {
    final p = _peers.remove(session);
    if (p == null) return;
    p.closed = true;
    p.flush?.cancel();
    unawaited(p.pc.close());
    _dropRenderer(session);
    _setPeerState(session, null);
  }

  Future<_Peer> _createPeer(String convId, String remote) async {
    _closePeer(remote);
    final pc = await createPeerConnection({'iceServers': _ice, 'sdpSemantics': 'unified-plan'});
    final peer = _Peer(pc);
    _peers[remote] = peer;
    _setPeerState(remote, PeerState.connecting);
    final local = _local;
    if (local != null) {
      for (final track in local.getAudioTracks()) {
        await pc.addTrack(track, local);
      }
    }
    // Remote audio plays through the platform automatically; video goes to a renderer.
    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind != 'video' || event.streams.isEmpty) return;
      if (_peers[remote] == peer) unawaited(_attachRenderer(remote, event.streams.first));
    };
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null || peer.closed) return;
      peer.outgoing.add({'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
      peer.flush ??= Timer(const Duration(milliseconds: 150), () {
        peer.flush = null;
        final batch = List<Map<String, dynamic>>.from(peer.outgoing);
        peer.outgoing.clear();
        final ch = channel;
        if (batch.isNotEmpty && ch != null && _peers[remote] == peer) {
          _signal(convId, {'t': 'voice.ice', 'session': ch.session, 'to': remote, 'candidates': batch});
        }
      });
    };
    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (_peers[remote] != peer) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setPeerState(remote, PeerState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _setPeerState(remote, PeerState.connecting);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          // Gone for good: the next heartbeat from either side starts over.
          _closePeer(remote);
          _setPeerState(remote, PeerState.failed);
        default:
          break;
      }
    };
    return peer;
  }

  /// The pair's video transceiver: negotiated once, fed with the screen track
  /// while sharing. The mic stream is announced as the track's stream so the
  /// m-line carries an msid and receivers get the track inside a stream.
  Future<void> _ensureVideo(_Peer peer) async {
    var tx = peer.videoTx;
    if (tx == null) {
      for (final candidate in await peer.pc.getTransceivers()) {
        if (candidate.receiver.track?.kind == 'video') {
          tx = candidate;
          await tx.setDirection(TransceiverDirection.SendRecv);
          break;
        }
      }
      tx ??= await peer.pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [?_local]),
      );
      peer.videoTx = tx;
    }
    final track = _screen?.getVideoTracks().firstOrNull;
    if (track != null) await tx.sender.replaceTrack(track);
  }

  void _maybeConnect(VoiceParticipant p) {
    final ch = channel;
    if (ch == null || p.session == ch.session || _peers.containsKey(p.session) || _connecting.contains(p.session)) return;
    if (_now() - p.seen > _expireMs) return;
    // Both sides know each other after join/here; the smaller session id
    // (UUIDv7, so the earlier participant) sends the offer: no glare.
    if (ch.session.compareTo(p.session) < 0) unawaited(_offerTo(ch.convId, p.session));
  }

  Future<void> _offerTo(String convId, String remote) async {
    _connecting.add(remote);
    try {
      final ch = channel;
      if (ch == null) return;
      final peer = await _createPeer(convId, remote);
      await _ensureVideo(peer);
      final offer = await peer.pc.createOffer({});
      await peer.pc.setLocalDescription(offer);
      await _signal(convId, {'t': 'voice.offer', 'session': ch.session, 'to': remote, 'sdp': offer.sdp});
    } catch (e) {
      debugPrint('voice offer failed: $e');
      _closePeer(remote);
    } finally {
      _connecting.remove(remote);
    }
  }

  Future<void> _acceptOffer(String convId, String remote, String sdp) async {
    _connecting.add(remote);
    try {
      final ch = channel;
      if (ch == null) return;
      final peer = await _createPeer(convId, remote);
      await peer.pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      peer.remoteSet = true;
      await _ensureVideo(peer);
      final answer = await peer.pc.createAnswer({});
      await peer.pc.setLocalDescription(answer);
      await _signal(convId, {'t': 'voice.answer', 'session': ch.session, 'to': remote, 'sdp': answer.sdp});
      await _flushIce(remote);
    } catch (e) {
      debugPrint('voice answer failed: $e');
      _closePeer(remote);
    } finally {
      _connecting.remove(remote);
    }
  }

  Future<void> _acceptAnswer(String remote, String sdp) async {
    final p = _peers[remote];
    if (p == null || p.remoteSet) return;
    try {
      await p.pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      p.remoteSet = true;
      await _flushIce(remote);
    } catch (e) {
      debugPrint('voice answer rejected: $e');
      _closePeer(remote);
    }
  }

  Future<void> _flushIce(String remote) async {
    final p = _peers[remote];
    if (p == null) return;
    final batch = List<Map<String, dynamic>>.from(p.queued);
    p.queued.clear();
    for (final c in batch) {
      await _addIce(p, c);
    }
  }

  Future<void> _addIce(_Peer p, Map<String, dynamic> c) async {
    try {
      await p.pc.addCandidate(RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt()));
    } catch (_) {}
  }

  /// Forgets sessions whose heartbeat stopped (closed app, lost network).
  void _prune() {
    final ch = channel;
    final now = _now();
    var changed = false;
    for (final convId in List.of(rooms.keys)) {
      final list = rooms[convId]!;
      final gone = list.where((p) => now - p.seen > _expireMs && !(ch != null && ch.convId == convId && p.session == ch.session)).toList();
      if (gone.isEmpty) continue;
      changed = true;
      for (final p in gone) {
        list.remove(p);
        _closePeer(p.session);
      }
      if (list.isEmpty) rooms.remove(convId);
    }
    if (changed) notifyListeners();
  }

  void handleSignal(String sender, String senderDevice, String convId, Map<String, dynamic> payload) {
    final me = app.session;
    final session = payload['session'] as String?;
    if (me == null || session == null) return;
    final ch = channel;
    if (ch != null && session == ch.session) return; // our own signal echoed back
    final here = ch != null && ch.convId == convId;
    switch (payload['t']) {
      case 'voice.join':
      case 'voice.here':
        final p = VoiceParticipant(session: session, account: sender, device: senderDevice, muted: payload['muted'] == true, sharing: payload['sharing'] == true, seen: _now());
        _setParticipant(convId, p);
        if (payload['t'] == 'voice.join' && here) unawaited(_signal(convId, _presence())); // tell the newcomer we are here
        if (here) _maybeConnect(p);
      case 'voice.share':
        for (final p in participantsOf(convId)) {
          if (p.session == session) {
            p.sharing = payload['on'] == true;
            p.seen = _now();
            notifyListeners();
          }
        }
      case 'voice.leave':
        _removeParticipant(convId, session);
        _closePeer(session);
      case 'voice.offer':
        if (here && payload['to'] == ch.session) unawaited(_acceptOffer(convId, session, (payload['sdp'] as String?) ?? ''));
      case 'voice.answer':
        if (here && payload['to'] == ch.session) unawaited(_acceptAnswer(session, (payload['sdp'] as String?) ?? ''));
      case 'voice.ice':
        if (!here || payload['to'] != ch.session) return;
        final p = _peers[session];
        if (p == null) return;
        final list = ((payload['candidates'] as List<dynamic>?) ?? []).cast<Map<String, dynamic>>();
        if (p.remoteSet) {
          for (final c in list) {
            unawaited(_addIce(p, c));
          }
        } else {
          p.queued.addAll(list);
        }
    }
  }
}
