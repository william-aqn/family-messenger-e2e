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

  @override
  Widget build(BuildContext context) {
    final calls = app.calls;
    final c = calls.call;
    if (c == null) return const SizedBox.shrink();
    final peer = app.usernameOf(c.peer);
    final String status;
    switch (c.status) {
      case CallStatus.ringingOut:
        status = '${t('calling')} $peer';
      case CallStatus.ringingIn:
        status = '${t('incoming_call')}: $peer';
      case CallStatus.connecting:
        status = t('connecting');
      case CallStatus.active:
        status = '${t('in_call')}: $peer';
      case CallStatus.ended:
        status = '${t('call_ended')}${c.endReason != null && c.endReason != 'ended' ? ' (${c.endReason})' : ''}';
    }
    final video = calls.remoteVideo;
    if (_fullscreen && video) {
      // Only the shared screen, edge to edge, with a way back.
      return Material(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(onDoubleTap: () => setState(() => _fullscreen = false), child: RTCVideoView(calls.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)),
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
    return Material(
      color: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        child: Column(
          children: [
            Padding(padding: const EdgeInsets.all(16), child: Text(status, style: const TextStyle(color: Colors.white, fontSize: 18))),
            Expanded(
              child: video
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(onDoubleTap: () => setState(() => _fullscreen = true), child: RTCVideoView(calls.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)),
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
                  if (c.status == CallStatus.active || c.status == CallStatus.connecting || c.status == CallStatus.ringingOut) ...[
                    OutlinedButton.icon(icon: Icon(c.muted ? Icons.mic_off : Icons.mic), label: Text(c.muted ? t('unmute') : t('mute')), onPressed: calls.toggleMute),
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
