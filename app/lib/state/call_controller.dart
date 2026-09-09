// 1:1 calls with camera video and screen sharing over WebRTC (flutter_webrtc).
// Signaling travels inside ephemeral, signed and encrypted envelopes
// (PROTOCOL.md §6). Every call negotiates three slots up front (audio, camera
// video, screen video), so cameras and screens switch with replaceTrack only.
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

/// Constraints for capturing the screen. Desktop platforms need an explicit
/// source (the primary screen here); phones show the system prompt.
Future<Map<String, dynamic>> displayMediaConstraints() async {
  if (Platform.isAndroid || Platform.isIOS) return {'video': true, 'audio': false};
  final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
  if (sources.isEmpty) throw StateError('no screen to capture');
  return {
    'video': {
      'deviceId': {'exact': sources.first.id},
      'mandatory': {'frameRate': 15.0},
    },
    'audio': false,
  };
}

/// The stream a remote video track arrived in, or a fresh one wrapping the
/// track when the sender announced none ("msid:-"). Renderers need a stream.
Future<MediaStream?> remoteStreamFor(RTCTrackEvent event, String label) async {
  if (event.streams.isNotEmpty) return event.streams.first;
  try {
    final stream = await createLocalMediaStream(label);
    await stream.addTrack(event.track);
    return stream;
  } catch (e) {
    debugPrint('could not wrap a remote track: $e');
    return null;
  }
}

class CallInfo {
  CallInfo({required this.id, required this.convId, required this.peer, required this.incoming, required this.status});

  final String id;
  final String convId;
  final String peer;
  final bool incoming;
  CallStatus status;
  bool muted = false;
  /// Our camera is on.
  bool video = false;
  /// Our screen is shared.
  bool sharing = false;
  /// The peer's camera / screen are on (from the call.video / call.share signals).
  bool remoteVideo = false;
  bool remoteSharing = false;
  String? endReason;
  DateTime? startedAt;
}

class CallController extends ChangeNotifier {
  CallController(this.app);

  final AppState app;
  final RTCVideoRenderer remoteCamera = RTCVideoRenderer();
  final RTCVideoRenderer remoteScreen = RTCVideoRenderer();
  final RTCVideoRenderer localCamera = RTCVideoRenderer();
  bool _renderersReady = false;

  CallInfo? call;
  RTCPeerConnection? _pc;
  MediaStream? _local; // microphone
  MediaStream? _camera;
  MediaStream? _screen;
  MediaStream? _screenSlot; // placeholder announced for the screen slot
  RTCRtpTransceiver? _cameraTx;
  RTCRtpTransceiver? _screenTx;
  /// Remote streams of the video slots (0 = camera, 1 = screen).
  final Map<int, MediaStream> _remoteStreams = {};
  int _videoTracksSeen = 0;

  int get debugRemoteStreams => _remoteStreams.length;
  String? _pendingOfferSdp;
  final List<Map<String, dynamic>> _queuedIce = [];
  final List<Map<String, dynamic>> _outgoingIce = [];
  Timer? _iceTimer;
  Timer? _ringTimer;
  Timer? _endTimer;

  bool get renderersReady => _renderersReady;

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    await remoteCamera.initialize();
    await remoteScreen.initialize();
    await localCamera.initialize();
    _renderersReady = true;
  }

  Future<void> _signal(String convId, Map<String, dynamic> payload) async {
    try {
      await app.sendPayload(convId, payload, flags: flagEphemeral | flagUrgent);
    } catch (e) {
      debugPrint('signaling failed: $e');
    }
  }

  Future<RTCPeerConnection> _createPeer(String convId, String callId) async {
    await _ensureRenderers();
    List<Map<String, dynamic>> ice = [];
    try {
      ice = (await app.api!.turn()).map((s) => s.toRtc()).toList();
    } catch (_) {}
    final pc = await createPeerConnection({'iceServers': ice, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind != 'video') return;
      unawaited(_storeRemoteVideo(pc, event));
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
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }
    return pc;
  }

  /// Finds (or adds) the two video transceivers in slot order and attaches
  /// the current camera and screen tracks. Each slot announces its own stream
  /// so receivers get the tracks in separate streams.
  Future<void> _ensureVideoSlots(RTCPeerConnection pc) async {
    final videos = <RTCRtpTransceiver>[];
    for (final tx in await pc.getTransceivers()) {
      if (tx.receiver.track?.kind == 'video') videos.add(tx);
    }
    if (videos.isEmpty) {
      videos.add(await pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeVideo, init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [?_local])));
    }
    if (videos.length < 2) {
      _screenSlot ??= await createLocalMediaStream('screen-slot');
      videos.add(await pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeVideo, init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv, streams: [_screenSlot!])));
    }
    _screenSlot ??= await createLocalMediaStream('screen-slot');
    final slotStreams = [_local, _screenSlot];
    for (var i = 0; i < 2; i++) {
      await videos[i].setDirection(TransceiverDirection.SendRecv);
      // Transceivers created from a remote offer carry no stream ("msid:-");
      // receivers want the track inside one.
      final s = slotStreams[i];
      if (s != null) {
        try {
          await videos[i].sender.setStreams([s]);
        } catch (_) {}
      }
    }
    _cameraTx = videos[0];
    _screenTx = videos[1];
    final cam = _camera?.getVideoTracks().firstOrNull;
    if (cam != null) await _cameraTx!.sender.replaceTrack(cam);
    final scr = _screen?.getVideoTracks().firstOrNull;
    if (scr != null) await _screenTx!.sender.replaceTrack(scr);
    _bindRemoteVideo();
  }

  /// Files a remote video track under its slot: the position of its
  /// transceiver among the video transceivers (camera first, screen second),
  /// or the order of arrival when the transceiver cannot be matched.
  Future<void> _storeRemoteVideo(RTCPeerConnection pc, RTCTrackEvent event) async {
    var slot = -1;
    try {
      final videos = <RTCRtpTransceiver>[];
      for (final tx in await pc.getTransceivers()) {
        if (tx.receiver.track?.kind == 'video') videos.add(tx);
      }
      slot = videos.indexWhere((tx) => tx.receiver.track?.id == event.track.id);
      if (slot < 0 && event.transceiver != null) slot = videos.indexWhere((tx) => tx.mid == event.transceiver!.mid);
    } catch (_) {}
    if (slot < 0) slot = _videoTracksSeen;
    _videoTracksSeen++;
    final stream = await remoteStreamFor(event, 'call-slot-$slot');
    if (_pc != pc || stream == null) return;
    _remoteStreams[slot] = stream;
    _bindRemoteVideo();
  }

  /// Routes the remote streams of the two video slots to their renderers.
  void _bindRemoteVideo() {
    if (!_renderersReady) return;
    remoteCamera.srcObject = _remoteStreams[0];
    remoteScreen.srcObject = _remoteStreams[1];
    notifyListeners();
  }

  Future<void> startCall(String convId, {bool video = false}) async {
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
      if (video) await _enableCamera(notify: false);
      await _ensureVideoSlots(pc);
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _signal(convId, {'t': 'call.offer', 'call': id, 'sdp': offer.sdp, 'video': call?.video == true});
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
        call = CallInfo(id: callId!, convId: convId, peer: sender, incoming: true, status: CallStatus.ringingIn)..remoteVideo = payload['video'] == true;
        _ringTimer = Timer(const Duration(seconds: 45), () {
          if (call?.id == callId && call!.status == CallStatus.ringingIn) _end('missed');
        });
        notifyListeners();
      case 'call.answer':
        if (current?.id == callId && current!.status == CallStatus.ringingOut && _pc != null) {
          _ringTimer?.cancel();
          current.status = CallStatus.connecting;
          current.remoteVideo = payload['video'] == true;
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
      case 'call.video':
        if (current?.id == callId) {
          current!.remoteVideo = payload['on'] == true;
          notifyListeners();
        }
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
      // A video call is answered with the camera on (audio only if it fails).
      if (current.remoteVideo) await _enableCamera(notify: false);
      await _ensureVideoSlots(pc);
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await _signal(current.convId, {'t': 'call.answer', 'call': current.id, 'sdp': answer.sdp, 'video': current.video});
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

  /// Test mode: `--dart-define=FAKE_CAMERA=screen` feeds the screen instead
  /// of a camera, so video calls can be exercised on machines without one.
  static const String fakeCamera = String.fromEnvironment('FAKE_CAMERA');

  Future<bool> _enableCamera({required bool notify}) async {
    final current = call;
    if (current == null) return false;
    if (_camera != null) return true;
    try {
      final stream = fakeCamera == 'screen'
          ? await navigator.mediaDevices.getDisplayMedia(await displayMediaConstraints())
          : await navigator.mediaDevices.getUserMedia({
              'audio': false,
              'video': {'facingMode': 'user', 'width': 1280, 'height': 720},
            });
      if (call != current || current.status == CallStatus.ended) {
        await _disposeStream(stream);
        return false;
      }
      _camera = stream;
      final track = stream.getVideoTracks().firstOrNull;
      if (track != null && _cameraTx != null) await _cameraTx!.sender.replaceTrack(track);
      if (_renderersReady) localCamera.srcObject = stream;
      current.video = true;
      notifyListeners();
      if (notify) await _signal(current.convId, {'t': 'call.video', 'call': current.id, 'on': true});
      return true;
    } catch (e) {
      debugPrint('camera failed: $e');
      return false;
    }
  }

  Future<void> _disableCamera({required bool notify}) async {
    final current = call;
    final cam = _camera;
    _camera = null;
    if (_renderersReady) localCamera.srcObject = null;
    try {
      await _cameraTx?.sender.replaceTrack(null);
    } catch (_) {}
    await _disposeStream(cam);
    if (current == null) return;
    current.video = false;
    notifyListeners();
    if (notify && current.status != CallStatus.ended) await _signal(current.convId, {'t': 'call.video', 'call': current.id, 'on': false});
  }

  /// Switches our camera on or off during a call (an audio call becomes a
  /// video call). Returns a translation key on failure.
  Future<String?> toggleCamera() async {
    final current = call;
    if (current == null || current.status == CallStatus.ended) return null;
    if (current.video) {
      await _disableCamera(notify: true);
      return null;
    }
    return await _enableCamera(notify: true) ? null : 'camera_failed';
  }

  /// Front / back camera on phones.
  Future<void> switchCamera() async {
    final track = _camera?.getVideoTracks().firstOrNull;
    if (track != null) await Helper.switchCamera(track);
  }

  Future<void> startScreenShare() async {
    final current = call;
    if (current == null || _pc == null || current.sharing) return;
    try {
      if (!await enableScreenCaptureService()) return;
      final stream = await navigator.mediaDevices.getDisplayMedia(await displayMediaConstraints());
      final track = stream.getVideoTracks().first;
      _screen = stream;
      if (_screenTx != null) await _screenTx!.sender.replaceTrack(track);
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
    final screen = _screen;
    _screen = null;
    try {
      await _screenTx?.sender.replaceTrack(null);
    } catch (_) {}
    await _disposeStream(screen);
    await disableScreenCaptureService();
    current?.sharing = false;
    notifyListeners();
    if (wasSharing && current != null && current.status != CallStatus.ended) {
      await _signal(current.convId, {'t': 'call.share', 'call': current.id, 'on': false});
    }
  }

  Future<void> _disposeStream(MediaStream? stream) async {
    if (stream == null) return;
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  }

  void _end(String reason) {
    _ringTimer?.cancel();
    _iceTimer?.cancel();
    _iceTimer = null;
    _outgoingIce.clear();
    _queuedIce.clear();
    _pendingOfferSdp = null;
    _cameraTx = null;
    _screenTx = null;
    _remoteStreams.clear();
    _videoTracksSeen = 0;
    final local = _local;
    _local = null;
    final camera = _camera;
    _camera = null;
    final screen = _screen;
    _screen = null;
    final slot = _screenSlot;
    _screenSlot = null;
    final pc = _pc;
    _pc = null;
    unawaited(() async {
      await _disposeStream(local);
      await _disposeStream(camera);
      await _disposeStream(screen);
      await slot?.dispose();
      await disableScreenCaptureService();
      await pc?.close();
      if (_renderersReady) {
        remoteCamera.srcObject = null;
        remoteScreen.srcObject = null;
        localCamera.srcObject = null;
      }
    }());
    final current = call;
    if (current != null && current.status != CallStatus.ended) {
      current.status = CallStatus.ended;
      current.endReason = reason;
      current.video = false;
      current.sharing = false;
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
