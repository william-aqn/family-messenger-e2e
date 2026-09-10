import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../i18n/strings.dart';
import '../main.dart';
import '../state/call_controller.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _fullscreen = false;

  /// A problem to show inside the overlay (a snack bar would hide behind it).
  String? _notice;
  Timer? _noticeTimer;

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  Future<void> _toggleCamera() async {
    final err = await app.calls.toggleCamera();
    if (err == null || !mounted) return;
    final detail = app.calls.cameraError;
    _showNotice(detail == null ? t(err) : '${t(err)}: $detail');
  }

  @override
  Widget build(BuildContext context) {
    // The app inserts this screen as a const widget, so it has to follow the
    // call state itself; otherwise "Calling…" stays on screen for the whole call.
    return ListenableBuilder(listenable: app.calls, builder: (context, _) => _overlay(context));
  }

  Widget _overlay(BuildContext context) {
    final calls = app.calls;
    final c = calls.call;
    if (c == null) return const SizedBox.shrink();
    final peer = app.usernameOf(c.peer);
    final String status;
    switch (c.status) {
      case CallStatus.ringingOut:
        status = '${t('calling')} $peer';
      case CallStatus.ringingIn:
        status = '${c.remoteVideo ? t('incoming_video_call') : t('incoming_call')}: $peer';
      case CallStatus.connecting:
        status = t('connecting');
      case CallStatus.active:
        status = '${t('in_call')}: $peer';
      case CallStatus.ended:
        status = '${t('call_ended')}${c.endReason != null && c.endReason != 'ended' ? ' (${c.endReason})' : ''}';
    }
    final remoteMedia = calls.renderersReady && (c.remoteVideo || c.remoteSharing);
    final stage = _Stage(calls: calls, call: c);
    if (_fullscreen && remoteMedia) {
      // Only the remote video, edge to edge, with a way back.
      return Material(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(onDoubleTap: () => setState(() => _fullscreen = false), child: stage),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton.filledTonal(
                  icon: const Icon(Icons.fullscreen_exit),
                  tooltip: t('exit_fullscreen'),
                  onPressed: () => setState(() => _fullscreen = false),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final live = c.status == CallStatus.active || c.status == CallStatus.connecting || c.status == CallStatus.ringingOut;
    return Material(
      color: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        child: Column(
          children: [
            Padding(padding: const EdgeInsets.all(16), child: Text(status, style: const TextStyle(color: Colors.white, fontSize: 18))),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_notice!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent, fontSize: 13)),
              ),
            Expanded(
              child: remoteMedia || c.video
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(onDoubleTap: remoteMedia ? () => setState(() => _fullscreen = true) : null, child: stage),
                        if (remoteMedia)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: IconButton.filledTonal(
                              icon: const Icon(Icons.fullscreen),
                              tooltip: t('fullscreen'),
                              onPressed: () => setState(() => _fullscreen = true),
                            ),
                          ),
                      ],
                    )
                  : const Center(child: Icon(Icons.person, size: 96, color: Colors.white54)),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (c.status == CallStatus.ringingIn) ...[
                    FilledButton.icon(icon: const Icon(Icons.call), label: Text(t('answer')), onPressed: calls.accept),
                    OutlinedButton.icon(icon: const Icon(Icons.call_end), label: Text(t('decline')), onPressed: calls.reject),
                  ],
                  if (live) ...[
                    OutlinedButton.icon(icon: Icon(c.muted ? Icons.mic_off : Icons.mic), label: Text(c.muted ? t('unmute') : t('mute')), onPressed: calls.toggleMute),
                    OutlinedButton.icon(
                      icon: Icon(c.video ? Icons.videocam_off : Icons.videocam),
                      label: Text(c.video ? t('camera_off') : t('camera_on')),
                      onPressed: _toggleCamera,
                    ),
                    if (c.video && (Platform.isAndroid || Platform.isIOS))
                      OutlinedButton.icon(icon: const Icon(Icons.cameraswitch), label: Text(t('switch_camera')), onPressed: calls.switchCamera),
                    OutlinedButton.icon(
                      icon: Icon(c.sharing ? Icons.stop_screen_share : Icons.screen_share),
                      label: Text(c.sharing ? t('stop_sharing') : t('share_screen')),
                      onPressed: c.status == CallStatus.active ? (c.sharing ? calls.stopScreenShare : calls.startScreenShare) : null,
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      icon: const Icon(Icons.call_end),
                      label: Text(t('hang_up')),
                      onPressed: calls.hangup,
                    ),
                  ],
                  if (c.status == CallStatus.ended) OutlinedButton(onPressed: calls.dismiss, child: const Text('OK')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The remote screen (if shared) or camera fills the stage; with both, the
/// camera sits in a corner. Our own camera preview is mirrored in the other
/// corner.
class _Stage extends StatelessWidget {
  const _Stage({required this.calls, required this.call});

  final CallController calls;
  final CallInfo call;

  @override
  Widget build(BuildContext context) {
    final c = call;
    final ready = calls.renderersReady;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (ready && c.remoteSharing)
          RTCVideoView(calls.remoteScreen, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
        else if (ready && c.remoteVideo)
          RTCVideoView(calls.remoteCamera, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
        else
          const Center(child: Icon(Icons.person, size: 96, color: Colors.white54)),
        if (ready && c.remoteSharing && c.remoteVideo)
          Positioned(
            top: 8,
            left: 8,
            width: 160,
            height: 110,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: RTCVideoView(calls.remoteCamera, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            ),
          ),
        if (ready && c.video)
          Positioned(
            bottom: 8,
            right: 8,
            width: 120,
            height: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: RTCVideoView(calls.localCamera, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
            ),
          ),
      ],
    );
  }
}
