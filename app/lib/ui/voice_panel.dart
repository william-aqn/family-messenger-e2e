import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../i18n/strings.dart';
import '../main.dart';
import '../state/voice_controller.dart';
import '../theme.dart';

/// Joins the voice channel of [convId] and reports a refusal in a snack bar.
Future<void> joinVoice(BuildContext context, String convId) async {
  final err = await app.voice.join(convId);
  if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t(err))));
}

Future<void> _toggleCamera(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final err = await app.voice.toggleCamera();
  if (err != null) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(t(err))));
  }
}

Future<void> _toggleShare(BuildContext context) async {
  final ch = app.voice.channel;
  if (ch == null) return;
  if (ch.sharing) {
    await app.voice.stopScreenShare();
    return;
  }
  final err = await app.voice.startScreenShare();
  if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t(err))));
}

/// Bottom bar shown on every screen while this device is in a voice channel:
/// the group, every participant with its connection state, mute, screen
/// sharing, the streamed screens and leave.
class VoicePanel extends StatelessWidget {
  const VoicePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.voice,
      builder: (context, _) {
        final ch = app.voice.channel;
        if (ch == null) return const SizedBox.shrink();
        final conv = app.conversations[ch.convId];
        final people = List.of(app.voice.participantsOf(ch.convId))..sort((a, b) => (b.session == ch.session ? 1 : 0) - (a.session == ch.session ? 1 : 0));
        // One tile per participant, plus one for every shared screen: the
        // number the "Video and screens" button carries.
        final tileCount = people.length + app.voice.streamers().length;
        final scheme = Theme.of(context).colorScheme;
        return Material(
          // Chrome 2 with the ring on top: the design system's stand-in for
          // the shadow this panel used to cast.
          color: scheme.surfaceContainerHighest,
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: context.fm.ring))),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(LucideIcons.headphones, size: 20, color: scheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${t('voice_channel')} · ${conv == null ? t('group') : app.titleOf(conv)}',
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: Icon(ch.muted ? LucideIcons.micOff : LucideIcons.mic),
                          color: scheme.onSurface,
                          tooltip: ch.muted ? t('unmute') : t('mute'),
                          onPressed: app.voice.toggleMute,
                        ),
                        IconButton(
                          icon: Icon(ch.camera ? LucideIcons.videoOff : LucideIcons.video),
                          color: ch.camera ? scheme.primary : scheme.onSurface,
                          tooltip: ch.camera ? t('camera_off') : t('camera_on'),
                          onPressed: () => _toggleCamera(context),
                        ),
                        IconButton(
                          icon: Icon(ch.sharing ? LucideIcons.monitorOff : LucideIcons.monitor),
                          // Active button: the accent, as everywhere else.
                          color: ch.sharing ? scheme.primary : scheme.onSurface,
                          tooltip: ch.sharing ? t('stop_sharing') : t('share_screen'),
                          onPressed: () => _toggleShare(context),
                        ),
                        IconButton(
                          icon: const Icon(LucideIcons.logOut),
                          color: scheme.error,
                          tooltip: t('voice_leave'),
                          onPressed: app.voice.leave,
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      // One Wrap for the participants and the tiles button
                      // together: at the larger text sizes the button no
                      // longer fits beside them and has to move to its own
                      // line rather than run off the edge.
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final p in people)
                            _ParticipantChip(participant: p, state: p.session == ch.session ? null : (ch.peers[p.session] ?? PeerState.connecting)),
                          if (tileCount > 0)
                            _VoiceChip(
                              icon: LucideIcons.video,
                              label: t('video_and_screens', {'n': tileCount}),
                              selected: true,
                              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceScreensPage())),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One participant: the 8px state dot, the name, mute and sharing glyphs and
/// the connection state, in a 28px chip with the design system's ring.
class _ParticipantChip extends StatelessWidget {
  const _ParticipantChip({required this.participant, required this.state});

  final VoiceParticipant participant;

  /// Null for this device itself.
  final PeerState? state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fm = context.fm;
    final dot = switch (state) {
      null || PeerState.connected => fm.ok,
      // The design draws the waiting dot faint, not busy.
      PeerState.connecting => scheme.outline,
      PeerState.failed => fm.offline,
    };
    final settled = state == null || state == PeerState.connected;
    final text = settled ? scheme.onSurface : scheme.onSurfaceVariant;
    final name = Theme.of(context).textTheme.labelSmall!.copyWith(fontSize: 13, color: text);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: fm.ringStrong),
        borderRadius: BorderRadius.circular(fmRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(app.usernameOf(participant.account), style: name),
          if (participant.muted) ...[
            const SizedBox(width: 6),
            Icon(LucideIcons.micOff, size: 12, color: scheme.onSurfaceVariant),
          ],
          if (participant.sharing) ...[
            const SizedBox(width: 6),
            Icon(LucideIcons.monitor, size: 12, color: scheme.onSurfaceVariant),
          ],
          if (state != null) Text(' · ${t('voice_state_${state!.name}')}', style: name.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// A 32px chip: soft accent when selected, a 1px ring when not. Used for the
/// "Screens (N)" action in the panel and for the filters on the screens page.
class _VoiceChip extends StatelessWidget {
  const _VoiceChip({this.icon, required this.label, required this.selected, required this.onTap});

  final IconData? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).chipTheme.labelStyle?.copyWith(color: selected ? scheme.primary : scheme.onSurface);
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(fmRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(fmRadius),
        // Motion is a colour change only.
        hoverColor: selected ? scheme.primary.withValues(alpha: .25) : scheme.surfaceContainerHigh,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: selected ? null : Border.all(color: context.fm.ringStrong),
            borderRadius: BorderRadius.circular(fmRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: selected ? scheme.primary : scheme.onSurface),
                const SizedBox(width: 6),
              ],
              Text(label, style: style),
            ],
          ),
        ),
      ),
    );
  }
}

/// Strip under a group's app bar: who is in the channel, join or leave.
class VoiceBar extends StatelessWidget {
  const VoiceBar({super.key, required this.convId});

  final String convId;

  /// Marks where the names go inside the translated sentence, so the sharing
  /// glyph can be inlined without splitting the string in the dictionaries.
  static const String _namesSlot = '{names}';

  @override
  Widget build(BuildContext context) {
    final voice = app.voice;
    final people = voice.participantsOf(convId);
    final joined = voice.inChannel(convId);
    if (people.isEmpty && !joined) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final body = Theme.of(context).textTheme.bodyMedium!.copyWith(color: scheme.onSurface);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: ClipRRect(
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(fmRadius)),
        child: Stack(
          children: [
            Container(
              // Soft accent with the accent rail on the left.
              color: scheme.primaryContainer,
              padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
              child: Row(
                children: [
                  Icon(LucideIcons.headphones, size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: people.isEmpty
                        ? Text(t('voice_empty'), style: body)
                        : Text.rich(TextSpan(children: _sentence(context, people)), style: body),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: joined ? voice.leave : () => joinVoice(context, convId),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.primary,
                      textStyle: body.copyWith(fontWeight: FontWeight.w500),
                      minimumSize: const Size(0, 24),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(joined ? t('voice_leave') : t('voice_join')),
                  ),
                ],
              ),
            ),
            Positioned(left: 0, top: 0, bottom: 0, child: Container(width: 2, color: scheme.primary)),
          ],
        ),
      ),
    );
  }

  /// "In the voice channel: sergey, dima" with a monitor icon after everyone
  /// who is streaming a screen.
  List<InlineSpan> _sentence(BuildContext context, List<VoiceParticipant> people) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final line = t('voice_in_channel');
    final at = line.indexOf(_namesSlot);
    final names = <InlineSpan>[];
    for (final p in people) {
      if (names.isNotEmpty) names.add(const TextSpan(text: ', '));
      names.add(TextSpan(text: app.usernameOf(p.account)));
      if (p.sharing) {
        names.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Icon(LucideIcons.monitor, size: 16, color: muted),
          ),
        ));
      }
    }
    if (at < 0) return names;
    return [
      if (at > 0) TextSpan(text: line.substring(0, at)),
      ...names,
      TextSpan(text: line.substring(at + _namesSlot.length)),
    ];
  }
}

/// The screens streamed into the channel: all of them in a grid, or one
/// picked with the chips (or a tap on a tile).
class VoiceScreensPage extends StatefulWidget {
  const VoiceScreensPage({super.key});

  @override
  State<VoiceScreensPage> createState() => _VoiceScreensPageState();
}

class _VoiceScreensPageState extends State<VoiceScreensPage> {
  /// The tile on the stage in speaker mode, by its renderer key.
  String? _pinned;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.voice,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final tiles = _tiles();
        // A pinned tile that went away falls back to the grid.
        final pinned = tiles.any((x) => x.key == _pinned) ? _pinned : null;
        final stage = pinned == null ? null : tiles.firstWhere((x) => x.key == pinned);
        final rest = pinned == null ? tiles : tiles.where((x) => x.key != pinned).toList();
        final screens = tiles.where((x) => x.screen).length;
        final cameras = tiles.where((x) => !x.screen && x.live).length;
        final wide = MediaQuery.sizeOf(context).width > 900;
        final sharing = app.voice.channel?.sharing == true;
        final cameraOn = app.voice.channel?.camera == true;
        final gap = wide ? 16.0 : 12.0;
        return Scaffold(
          backgroundColor: context.fm.chrome,
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(LucideIcons.arrowLeft),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: Text(t('voice_screens')),
            actions: [
              IconButton(
                icon: Icon(cameraOn ? LucideIcons.videoOff : LucideIcons.video),
                color: cameraOn ? scheme.primary : scheme.onSurface,
                tooltip: cameraOn ? t('camera_off') : t('camera_on'),
                onPressed: () => _toggleCamera(context),
              ),
              // Wide windows get the labelled secondary button of the design,
              // phones the icon button.
              if (wide)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: OutlinedButton.icon(
                    icon: Icon(sharing ? LucideIcons.monitorOff : LucideIcons.monitor, size: 16),
                    label: Text(sharing ? t('stop_sharing') : t('share_screen')),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      textStyle: Theme.of(context).chipTheme.labelStyle,
                      side: BorderSide(color: scheme.primary.withValues(alpha: .4), width: 2),
                    ),
                    onPressed: () => _toggleShare(context),
                  ),
                )
              else
                IconButton(
                  icon: Icon(sharing ? LucideIcons.monitorOff : LucideIcons.monitor),
                  color: scheme.onSurface,
                  tooltip: sharing ? t('stop_sharing') : t('share_screen'),
                  onPressed: () => _toggleShare(context),
                ),
            ],
          ),
          body: tiles.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(t('voice_no_streams'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(wide ? 24 : 16, 12, wide ? 24 : 16, 4),
                      child: Row(
                        children: [
                          _VoiceChip(label: t('grid_mode'), selected: pinned == null, onTap: () => setState(() => _pinned = null)),
                          const SizedBox(width: 8),
                          _VoiceChip(
                            label: t('speaker_mode'),
                            selected: pinned != null,
                            onTap: () => setState(() => _pinned = pinned ?? tiles.firstWhere((x) => x.live, orElse: () => tiles.first).key),
                          ),
                          const Spacer(),
                          Icon(LucideIcons.monitor, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text('$screens', style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(width: 8),
                          Icon(LucideIcons.video, size: 16, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text('$cameras', style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                    if (stage != null)
                      Padding(
                        padding: EdgeInsets.fromLTRB(wide ? 24 : 16, gap, wide ? 24 : 16, 0),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: _VoiceTile(tile: stage, pinned: true, onPin: () => setState(() => _pinned = null)),
                        ),
                      ),
                    Expanded(
                      child: GridView.count(
                        crossAxisCount: wide ? 3 : 2,
                        childAspectRatio: 16 / 9,
                        padding: EdgeInsets.fromLTRB(wide ? 24 : 16, gap, wide ? 24 : 16, wide ? 24 : 16),
                        mainAxisSpacing: gap,
                        crossAxisSpacing: gap,
                        children: [
                          for (final tile in rest)
                            _VoiceTile(tile: tile, pinned: false, onPin: () => setState(() => _pinned = tile.key)),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// Every participant is a tile whether or not their camera is on, and every
  /// shared screen is a tile of its own.
  List<_Tile> _tiles() {
    final ch = app.voice.channel;
    if (ch == null) return const [];
    final out = <_Tile>[];
    for (final p in app.voice.participantsOf(ch.convId)) {
      final self = p.session == ch.session;
      final key = self ? VoiceController.selfTile : VoiceController.tileKey(p.session, screen: false);
      out.add(_Tile(
        key: key,
        name: self ? (app.session?.username ?? '') : app.usernameOf(p.account),
        screen: false,
        self: self,
        muted: p.muted,
        live: self ? ch.camera : p.camera,
        renderer: app.voice.renderers[key],
      ));
      // Our own screen is not looped back: the machine is already showing it.
      if (p.sharing && !self) {
        final screenKey = VoiceController.tileKey(p.session, screen: true);
        out.add(_Tile(
          key: screenKey,
          name: app.usernameOf(p.account),
          screen: true,
          self: false,
          muted: p.muted,
          live: true,
          renderer: app.voice.renderers[screenKey],
        ));
      }
    }
    return out;
  }

  Future<void> _toggleCamera(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await app.voice.toggleCamera();
    if (error != null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(t(error))));
    }
  }
}

/// One track of the channel: somebody's camera, or somebody's screen.
class _Tile {
  const _Tile({
    required this.key,
    required this.name,
    required this.screen,
    required this.self,
    required this.muted,
    required this.live,
    required this.renderer,
  });

  final String key;
  final String name;
  final bool screen;
  final bool self;
  final bool muted;

  /// The track is carrying frames — the camera or the screen is on.
  final bool live;
  final RTCVideoRenderer? renderer;
}

/// One 16:9 tile: a camera, a screen, or the initial of somebody who has
/// neither on, with the name plate in the bottom left corner and the pin in
/// the top right.
class _VoiceTile extends StatelessWidget {
  const _VoiceTile({required this.tile, required this.pinned, required this.onPin});

  final _Tile tile;
  final bool pinned;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = tile.renderer;
    final live = tile.live && r != null;
    return GestureDetector(
      onTap: onPin,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(fmRadius),
        child: Container(
          decoration: BoxDecoration(
            color: live ? context.fm.chrome : scheme.surfaceContainerHigh,
            border: tile.self
                ? Border.all(color: scheme.primary, width: 2)
                : pinned
                    ? Border.all(color: scheme.primary.withValues(alpha: .5), width: 2)
                    : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (live)
                RTCVideoView(r, mirror: tile.self, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
              else if (tile.screen)
                Center(child: Text(t('voice_waiting_video'), style: Theme.of(context).textTheme.bodyMedium))
              else
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: context.fm.chrome, shape: BoxShape.circle),
                    child: Text(
                      tile.name.isEmpty ? '?' : tile.name.substring(0, 1).toUpperCase(),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 22, color: scheme.primary),
                    ),
                  ),
                ),
              Positioned(
                left: 12,
                bottom: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: context.fm.chrome.withValues(alpha: .9),
                    borderRadius: BorderRadius.circular(fmRadius),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      if (tile.screen) Icon(LucideIcons.monitor, size: 12, color: scheme.primary),
                      Text(
                        tile.screen ? t('screen_of', {'name': tile.name}) : (tile.self ? '${tile.name} (${t('you')})' : tile.name),
                        style: Theme.of(context).textTheme.labelSmall!.copyWith(fontSize: 13, color: scheme.onSurface),
                      ),
                      if (!tile.screen && tile.muted) Icon(LucideIcons.micOff, size: 12, color: scheme.onSurfaceVariant),
                      if (!tile.screen && !live) Icon(LucideIcons.videoOff, size: 12, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 8,
                child: IconButton(
                  icon: Icon(LucideIcons.pin, size: 14, color: pinned ? scheme.primary : scheme.onSurface),
                  tooltip: pinned ? t('unpin_tile') : t('pin_tile'),
                  style: IconButton.styleFrom(
                    backgroundColor: context.fm.chrome.withValues(alpha: .9),
                    minimumSize: const Size(28, 28),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: onPin,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
