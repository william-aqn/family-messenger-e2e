// 1:1 voice calls with screen sharing over WebRTC (flutter_webrtc). Signaling
// travels inside ephemeral, signed and encrypted envelopes (PROTOCOL.md §8).
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../crypto/envelope.dart';
import '../crypto/ids.dart';
import 'app_state.dart';

enum CallStatus { ringingOut, ringingIn, connecting, active, ended }

/// Android needs a foreground service of type mediaProjection before the
/// system allows screen capture (flutter_background provides it). Shared by
/// 1:1 calls and group voice channels.
Future<bool> enableScreenCaptureService() async {
  if (!Platform.isAndroid) return true;
  const config = FlutterBackgroundAndroidConfig(
    notificationTitle: 'Screen sharing',
    notificationText: 'Family Messenger is sharing your screen',
    notificationImportance: AndroidNotificationImportance.normal,
    notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
  );
  final ok = await FlutterBackground.initialize(androidConfig: config);
  if (!ok) return false;
  if (!FlutterBackground.isBackgroundExecutionEnabled) return FlutterBackground.enableBackgroundExecution();
  return true;
}

Future<void> disableScreenCaptureService() async {
  if (Platform.isAndroid && FlutterBackground.isBackgroundExecutionEnabled) await FlutterBackground.disableBackgroundExecution();
}

class CallInfo {
  CallInfo({required this.id, required this.convId, required this.peer, required this.incoming, required this.status});

  final String id;
  final String convId;
  final String peer;
  final bool incoming;
  CallStatus status;
  bool muted = false;
  bool sharing = false;
  // Set from the peer's call.share signal (track mute events are unreliable).
  bool remoteSharing = false;
  String? endReason;
  DateTime? startedAt;
}

class CallController extends ChangeNotifier {
  CallController(this.app);

  final AppState app;
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _rendererReady = false;

  CallInfo? call;
  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _screen;
  RTCRtpTransceiver? _videoTx;
  String? _pendingOfferSdp;
  final List<Map<String, dynamic>> _queuedIce = [];
  final List<Map<String, dynamic>> _outgoingIce = [];
  Timer? _iceTimer;
  Timer? _ringTimer;
  Timer? _endTimer;

  bool get remoteVideo => _rendererReady && (call?.remoteSharing ?? false);

  Future<void> _ensureRenderer() async {
    if (_rendererReady) return;
    await remoteRenderer.initialize();
    remoteRenderer.onResize = notifyListeners;
    _rendererReady = true;
  }

  Future<void> _signal(String convId, Map<String, dynamic> payload) async {
    try {
      await app.sendPayload(convId, payload, flags: flagEphemeral | flagUrgent);
    } catch (e) {
      debugPrint('signaling failed: $e');
    }
  }

  Future<RTCPeerConnection> _createPeer(String convId, String callId) async {
    await _ensureRenderer();
    List<Map<String, dynamic>> ice = [];
    try {
      ice = (await app.api!.turn()).map((s) => s.toRtc()).toList();
    } catch (_) {}
    final pc = await createPeerConnection({'iceServers': ice, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
      }
      notifyListeners();
    };
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null) return;
      _outgoingIce.add({'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
      _iceTimer ??= Timer(const Duration(milliseconds: 150), () {
        _iceTimer = null;
        final batch = List<Map<String, dynamic>>.from(_outgoingIce);
        _outgoingIce.clear();
        if (batch.isNotEmpty && call?.id == callId) _signal(convId, {'t': 'call.ice', 'call': callId, 'candidates': batch});
      });
    };
    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (_pc != pc) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          if (call != null && call!.status != CallStatus.active) {
            call!.status = CallStatus.active;
            call!.startedAt ??= DateTime.now();
            notifyListeners();
          }
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _end('connection failed');
        default:
          break;
      }
    };
    final mic = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    _local = mic;
    for (final track in mic.getAudioTracks()) {
      await pc.addTrack(track, mic);
    }
    await Helper.setSpeakerphoneOn(true);
    return pc;
  }

  Future<RTCRtpTransceiver> _ensureVideoTransceiver(RTCPeerConnection pc) async {
    if (_videoTx != null) return _videoTx!;
    for (final tx in await pc.getTransceivers()) {
      if (tx.receiver.track?.kind == 'video') {
        await tx.setDirection(TransceiverDirection.SendRecv);
        _videoTx = tx;
        return tx;
      }
    }
    _videoTx = await pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeVideo, init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv));
    return _videoTx!;
  }

  Future<void> startCall(String convId) async {
    final conv = app.conversations[convId];
    final peer = conv == null ? null : app.otherMember(conv);
    if (conv == null || conv.kind != 'direct' || peer == null) return;
    if (call != null && call!.status != CallStatus.ended) return;
    if (app.voice.channel != null) return; // leave the voice channel first (the UI says so)
    final id = newUuid();
    call = CallInfo(id: id, convId: convId, peer: peer, incoming: false, status: CallStatus.ringingOut);
    notifyListeners();
    try {
      final pc = await _createPeer(convId, id);
      await _ensureVideoTransceiver(pc);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _signal(convId, {'t': 'call.offer', 'call': id, 'sdp': offer.sdp});
      _ringTimer = Timer(const Duration(seconds: 45), () {
        if (call?.id == id && call!.status == CallStatus.ringingOut) {
          _signal(convId, {'t': 'call.hangup', 'call': id});
          _end('no answer');
        }
      });
    } catch (e) {
      _end('could not start: $e');
    }
  }

  void handleSignal(String sender, String senderDevice, String convId, Map<String, dynamic> payload) {
    final me = app.session;
    if (me == null) return;
    final current = call;
    final callId = payload['call'] as String?;
    if (sender == me.accountId) {
      if (senderDevice == me.deviceId) return;
      if (current != null && callId == current.id && current.status == CallStatus.ringingIn) {
        if (payload['t'] == 'call.answer') _end('answered on another device');
        if (payload['t'] == 'call.reject') _end('declined on another device');
      }
      return;
    }
    switch (payload['t']) {
      case 'call.offer':
        // Busy while in another call or in a group voice channel.
        if ((current != null && current.status != CallStatus.ended) || app.voice.channel != null) {
          if (current?.id != callId) _signal(convId, {'t': 'call.reject', 'call': callId, 'reason': 'busy'});
          return;
        }
        _pendingOfferSdp = payload['sdp'] as String?;
        _queuedIce.clear();
        call = CallInfo(id: callId!, convId: convId, peer: sender, incoming: true, status: CallStatus.ringingIn);
        _ringTimer = Timer(const Duration(seconds: 45), () {
          if (call?.id == callId && call!.status == CallStatus.ringingIn) _end('missed');
        });
        notifyListeners();
      case 'call.answer':
        if (current?.id == callId && current!.status == CallStatus.ringingOut && _pc != null) {
          _ringTimer?.cancel();
          current.status = CallStatus.connecting;
          notifyListeners();
          _pc!.setRemoteDescription(RTCSessionDescription(payload['sdp'] as String?, 'answer')).then((_) => _flushIce()).catchError((_) => _end('connection failed'));
        }
      case 'call.ice':
        if (current?.id == callId) {
          final list = (payload['candidates'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
          if (_pc != null && current!.status != CallStatus.ringingIn) {
            for (final c in list) {
              _addIce(c);
            }
          } else {
            _queuedIce.addAll(list);
          }
        }
      case 'call.reject':
        if (current?.id == callId) _end(payload['reason'] == 'busy' ? 'busy' : 'declined');
      case 'call.hangup':
        if (current?.id == callId) _end(current!.status == CallStatus.ringingIn ? 'missed' : 'ended');
      case 'call.share':
        if (current?.id == callId) {
          current!.remoteSharing = payload['on'] == true;
          notifyListeners();
        }
    }
  }

  Future<void> _addIce(Map<String, dynamic> c) async {
    try {
      await _pc?.addCandidate(RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt()));
    } catch (_) {}
  }

  Future<void> _flushIce() async {
    final batch = List<Map<String, dynamic>>.from(_queuedIce);
    _queuedIce.clear();
    for (final c in batch) {
      await _addIce(c);
    }
  }

  Future<void> accept() async {
    final current = call;
    final sdp = _pendingOfferSdp;
    if (current == null || current.status != CallStatus.ringingIn || sdp == null) return;
    _ringTimer?.cancel();
    current.status = CallStatus.connecting;
    notifyListeners();
    try {
      final pc = await _createPeer(current.convId, current.id);
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      await _ensureVideoTransceiver(pc);
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await _signal(current.convId, {'t': 'call.answer', 'call': current.id, 'sdp': answer.sdp});
      await _flushIce();
    } catch (e) {
      _end('could not answer: $e');
    }
  }

  void reject() {
    final current = call;
    if (current == null || current.status != CallStatus.ringingIn) return;
    _signal(current.convId, {'t': 'call.reject', 'call': current.id, 'reason': 'declined'});
    _end('declined');
  }

  void hangup() {
    final current = call;
    if (current == null || current.status == CallStatus.ended) return;
    _signal(current.convId, {'t': 'call.hangup', 'call': current.id});
    _end('ended');
  }

  void toggleMute() {
    final current = call;
    if (current == null || _local == null) return;
    current.muted = !current.muted;
    for (final t in _local!.getAudioTracks()) {
      t.enabled = !current.muted;
    }
    notifyListeners();
  }

  Future<void> startScreenShare() async {
    final current = call;
    final pc = _pc;
    if (current == null || pc == null || current.sharing) return;
    try {
      if (!await enableScreenCaptureService()) return;
      final stream = await navigator.mediaDevices.getDisplayMedia({'video': true, 'audio': false});
      final track = stream.getVideoTracks().first;
      _screen = stream;
      final tx = await _ensureVideoTransceiver(pc);
      await tx.sender.replaceTrack(track);
      track.onEnded = () => stopScreenShare();
      current.sharing = true;
      notifyListeners();
      await _signal(current.convId, {'t': 'call.share', 'call': current.id, 'on': true});
    } catch (e) {
      debugPrint('screen share failed: $e');
    }
  }

  Future<void> stopScreenShare() async {
    final current = call;
    final wasSharing = _screen != null || (current?.sharing ?? false);
    if (_screen != null) {
      for (final t in _screen!.getTracks()) {
        await t.stop();
      }
      await _screen!.dispose();
      _screen = null;
    }
    try {
      await _videoTx?.sender.replaceTrack(null);
    } catch (_) {}
    await disableScreenCaptureService();
    current?.sharing = false;
    notifyListeners();
    if (wasSharing && current != null && current.status != CallStatus.ended) {
      await _signal(current.convId, {'t': 'call.share', 'call': current.id, 'on': false});
    }
  }

  void _end(String reason) {
    _ringTimer?.cancel();
    _iceTimer?.cancel();
    _iceTimer = null;
    _outgoingIce.clear();
    _queuedIce.clear();
    _pendingOfferSdp = null;
    _videoTx = null;
    final local = _local;
    _local = null;
    final screen = _screen;
    _screen = null;
    final pc = _pc;
    _pc = null;
    unawaited(() async {
      if (local != null) {
        for (final t in local.getTracks()) {
          await t.stop();
        }
        await local.dispose();
      }
      if (screen != null) {
        for (final t in screen.getTracks()) {
          await t.stop();
        }
        await screen.dispose();
      }
      await disableScreenCaptureService();
      await pc?.close();
      if (_rendererReady) remoteRenderer.srcObject = null;
    }());
    final current = call;
    if (current != null && current.status != CallStatus.ended) {
      current.status = CallStatus.ended;
      current.endReason = reason;
      notifyListeners();
      _endTimer?.cancel();
      _endTimer = Timer(const Duration(seconds: 3), () {
        if (call?.status == CallStatus.ended) {
          call = null;
          notifyListeners();
        }
      });
    }
  }

  void dismiss() {
    if (call?.status == CallStatus.ended) {
      call = null;
      notifyListeners();
    }
  }
}
