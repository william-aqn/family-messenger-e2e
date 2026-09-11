import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../i18n/strings.dart';
import '../main.dart';
import '../state/call_controller.dart';
import '../theme.dart';

/// The 1:1 call, full screen on the chrome above every route (A08–A10).
///
/// Three layouts: the incoming call (a caption, the peer, one large Answer),
/// the outgoing call and the end of the call (a caption, the peer, a single
/// square button), and the live call (a 56 header with the timer, the video
/// stage and a row of icon-only controls).
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

  /// Redraws the header once a second so the call timer runs.
  Timer? _ticker;

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  /// Runs the one-second redraw only while a call is being timed.
  void _syncTicker(bool running) {
    if (running == (_ticker != null)) return;
    if (running) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// The call so far, MM:SS (H:MM:SS past the hour) — the same figure the web
  /// client shows, taken from the call's own `startedAt`.
  String _elapsed(DateTime since) {
    final Duration d = DateTime.now().difference(since);
    String two(int n) => n.toString().padLeft(2, '0');
    final String ms = '${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
    return d.inHours > 0 ? '${d.inHours}:$ms' : ms;
  }

  Future<void> _toggleCamera() async {
    final err = await app.calls.toggleCamera();
    if (err == null || !mounted) return;
    final detail = app.calls.cameraError;
    _showNotice(detail == null ? t(err) : '${t(err)}: $detail');
  }

  Future<void> _toggleShare() async {
    final calls = app.calls;
    if (calls.call?.sharing ?? false) {
      await calls.stopScreenShare();
      return;
    }
    final err = await calls.startScreenShare();
    if (err != null && mounted) _showNotice('${t('voice_share_failed')}: $err');
  }

  @override
  Widget build(BuildContext context) {
    // The app inserts this screen as a const widget, so it has to follow the
    // call state itself; otherwise "Calling…" stays on screen for the whole call.
    return ListenableBuilder(listenable: app.calls, builder: (context, _) => _overlay(context));
  }

  Widget _overlay(BuildContext context) {
    final FmColors fm = context.fm;
    final calls = app.calls;
    final c = calls.call;
    if (c == null) {
      _syncTicker(false);
      return const SizedBox.shrink();
    }
    _syncTicker(c.status == CallStatus.active && c.startedAt != null);
    final peer = app.usernameOf(c.peer);
    // Remote video is only there once the call is up; while it rings, the offer merely announces it.
    final remoteMedia = calls.renderersReady && (c.remoteVideo || c.remoteSharing) && (c.status == CallStatus.active || c.status == CallStatus.connecting);
    final stage = _Stage(calls: calls, call: c, peer: peer);

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
                child: _CallButton(
                  icon: LucideIcons.x,
                  tooltip: t('exit_fullscreen'),
                  size: 44,
                  iconSize: 22,
                  background: fm.chrome.withValues(alpha: .85),
                  onPressed: () => setState(() => _fullscreen = false),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final Widget body;
    switch (c.status) {
      case CallStatus.ringingIn:
        body = _incoming(context, c, peer, calls);
      case CallStatus.ringingOut:
        body = _calling(context, t('calling'), peer, calls);
      case CallStatus.connecting:
      case CallStatus.active:
        body = _live(context, c, peer, calls, stage: stage, remoteMedia: remoteMedia);
      case CallStatus.ended:
        body = _ended(context, c, peer, calls);
    }
    return Material(
      color: fm.chrome,
      child: SafeArea(child: body),
    );
  }

  /// A08 — the incoming call: one tap answers.
  Widget _incoming(BuildContext context, CallInfo c, String peer, CallController calls) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.lock, size: 14, color: scheme.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      c.remoteVideo ? t('incoming_video_call') : t('incoming_call'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(peer, textAlign: TextAlign.center, style: _peerStyle(theme)),
            ],
          ),
        ),
        Expanded(child: Center(child: _avatarTile(context, LucideIcons.user, size: 160, iconSize: 72))),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
          child: Column(
            children: [
              SizedBox(
                height: 64,
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(LucideIcons.phone, size: 24),
                  label: Text(t('answer')),
                  style: FilledButton.styleFrom(
                    textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 20),
                    iconAlignment: IconAlignment.start,
                  ),
                  onPressed: calls.accept,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 56,
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: Icon(LucideIcons.phoneOff, size: 22, color: scheme.error),
                  label: Text(t('decline')),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: scheme.error, width: 2),
                    textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 18),
                  ),
                  onPressed: calls.reject,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A10 (top) — the outgoing call: the caption, the peer and one hang-up.
  Widget _calling(BuildContext context, String caption, String peer, CallController calls) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
          child: Column(
            children: [
              Text(caption, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Text(peer, textAlign: TextAlign.center, style: _peerStyle(theme)),
            ],
          ),
        ),
        Expanded(child: Center(child: _avatarTile(context, LucideIcons.user, size: 120, iconSize: 56))),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: _CallButton(
            icon: LucideIcons.phoneOff,
            tooltip: t('hang_up'),
            size: 64,
            iconSize: 26,
            danger: true,
            onPressed: calls.hangup,
          ),
        ),
      ],
    );
  }

  /// A10 (bottom) — the call is over: the reason and a way out.
  Widget _ended(BuildContext context, CallInfo c, String peer, CallController calls) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String reason = c.endReason != null && c.endReason != 'ended' ? '${c.endReason} · $peer' : peer;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
          child: Column(
            children: [
              Text(t('call_ended'), textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                reason,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Expanded(child: Center(child: _avatarTile(context, LucideIcons.phoneOff, size: 120, iconSize: 56))),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: SizedBox(
            height: 56,
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: context.fm.ringStrong, width: 2),
                textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 18),
              ),
              onPressed: calls.dismiss,
              child: Text(t('close')),
            ),
          ),
        ),
      ],
    );
  }

  /// A09 — the live call: header with the timer, the stage, the controls.
  Widget _live(
    BuildContext context,
    CallInfo c,
    String peer,
    CallController calls, {
    required Widget stage,
    required bool remoteMedia,
  }) {
    final ThemeData theme = Theme.of(context);
    final bool active = c.status == CallStatus.active;
    final DateTime? since = c.startedAt;
    final String subtitle = active && since != null ? '${_elapsed(since)} · ${t('e2e_hint')}' : t('e2e_hint');
    final bool phone = Platform.isAndroid || Platform.isIOS;
    return Column(
      children: [
        ConstrainedBox(
          // A minimum, not the 56 A09 draws: the title and the line under it
          // need more than that at the larger text sizes, and a fixed height
          // cuts them off mid-letter.
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        active ? '${t('in_call')}: $peer' : t('connecting'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13)),
                    ],
                  ),
                ),
                if (remoteMedia)
                  _CallButton(
                    icon: LucideIcons.maximize,
                    tooltip: t('fullscreen'),
                    size: 44,
                    iconSize: 22,
                    bordered: false,
                    onPressed: () => setState(() => _fullscreen = true),
                  ),
              ],
            ),
          ),
        ),
        if (_notice != null) _banner(context, _notice!),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: GestureDetector(
              onDoubleTap: remoteMedia ? () => setState(() => _fullscreen = true) : null,
              child: stage,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              _CallButton(
                icon: c.muted ? LucideIcons.micOff : LucideIcons.mic,
                tooltip: c.muted ? t('unmute') : t('mute'),
                onPressed: calls.toggleMute,
              ),
              _CallButton(
                icon: c.video ? LucideIcons.video : LucideIcons.videoOff,
                tooltip: c.video ? t('camera_off') : t('camera_on'),
                onPressed: _toggleCamera,
              ),
              if (c.video && phone)
                _CallButton(
                  icon: LucideIcons.switchCamera,
                  tooltip: t('switch_camera'),
                  onPressed: calls.switchCamera,
                ),
              _CallButton(
                icon: c.sharing ? LucideIcons.monitorOff : LucideIcons.monitor,
                tooltip: c.sharing ? t('stop_sharing') : t('share_screen'),
                onPressed: active ? _toggleShare : null,
              ),
              _CallButton(
                icon: LucideIcons.phoneOff,
                tooltip: t('hang_up'),
                danger: true,
                onPressed: calls.hangup,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Camera and screen-share failures: the banner with the accent rail (8 s).
  Widget _banner(BuildContext context, String text) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(left: BorderSide(color: scheme.primary, width: 2)),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(fmRadius)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, color: scheme.primary)),
          ),
        ],
      ),
    );
  }

  /// The peer's name on the ringing and ended screens: 32/500.
  TextStyle? _peerStyle(ThemeData theme) => theme.textTheme.headlineSmall?.copyWith(fontSize: 32, height: 1.1);

  /// The square placeholder that stands in for a picture of the peer.
  Widget _avatarTile(BuildContext context, IconData icon, {required double size, required double iconSize}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(fmRadius)),
      child: Icon(icon, size: iconSize, color: scheme.onSurfaceVariant),
    );
  }
}

/// A square icon-only call control: 60×60 with a 2px accent-halftone border,
/// or the danger fill for hanging up. Icon-only in the design, so every one
/// of them carries the tooltip that used to be its label.
class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 60,
    this.iconSize = 24,
    this.danger = false,
    this.bordered = true,
    this.background,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool danger;
  final bool bordered;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: iconSize),
        style: IconButton.styleFrom(
          backgroundColor: danger ? scheme.error : (background ?? Colors.transparent),
          foregroundColor: scheme.onSurface,
          disabledForegroundColor: scheme.onSurface.withValues(alpha: .4),
          side: danger || !bordered ? BorderSide.none : BorderSide(color: context.fm.ringStrong, width: 2),
          shape: fmShape,
          padding: EdgeInsets.zero,
          fixedSize: Size(size, size),
          minimumSize: Size(size, size),
        ),
      ),
    );
  }
}

/// The remote screen (if shared) or camera fills the stage; with both, the
/// camera sits in a corner. Our own camera preview is mirrored in the other
/// corner. Each picture carries the name of whoever it shows.
class _Stage extends StatelessWidget {
  const _Stage({required this.calls, required this.call, required this.peer});

  final CallController calls;
  final CallInfo call;
  final String peer;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final c = call;
    final ready = calls.renderersReady;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(fmRadius)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(fmRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready && c.remoteSharing)
              RTCVideoView(calls.remoteScreen, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
            else if (ready && c.remoteVideo)
              RTCVideoView(calls.remoteCamera, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
            else
              _placeholder(context, c.remoteSharing ? LucideIcons.monitor : LucideIcons.user, peer),
            if (ready && c.remoteSharing && c.remoteVideo)
              Positioned(
                top: 12,
                left: 12,
                width: 160,
                height: 110,
                child: _tile(
                  context,
                  label: peer,
                  child: RTCVideoView(calls.remoteCamera, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),
            if (ready && c.video)
              Positioned(
                bottom: 12,
                right: 12,
                width: 120,
                height: 160,
                child: _tile(
                  context,
                  label: t('you'),
                  border: Border.all(color: scheme.onSurface, width: 2),
                  child: RTCVideoView(calls.localCamera, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Nothing to show yet: the icon of what is expected and whose it is.
  Widget _placeholder(BuildContext context, IconData icon, String label) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(label, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  /// A corner picture with its name plate.
  Widget _tile(BuildContext context, {required Widget child, required String label, BoxBorder? border}) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(fmRadius),
        border: border,
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          Positioned(
            left: 8,
            bottom: 6,
            child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurface)),
          ),
        ],
      ),
    );
  }
}
