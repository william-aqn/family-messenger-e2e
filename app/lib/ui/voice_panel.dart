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
        final streamers = app.voice.streamers();
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
                      child: Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final p in people)
                                  _ParticipantChip(participant: p, state: p.session == ch.session ? null : (ch.peers[p.session] ?? PeerState.connecting)),
                              ],
                            ),
                          ),
                          if (streamers.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            _VoiceChip(
                              icon: LucideIcons.monitor,
                              label: '${t('voice_screens')} (${streamers.length})',
                              selected: true,
                              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceScreensPage())),
                            ),
                          ],
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
  String? _focus;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.voice,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final streamers = app.voice.streamers();
        // A focused streamer who stopped falls back to the grid.
        final focused = streamers.any((p) => p.session == _focus) ? _focus : null;
        final shown = focused == null ? streamers : streamers.where((p) => p.session == focused).toList();
        final wide = MediaQuery.sizeOf(context).width > 900;
        final sharing = app.voice.channel?.sharing == true;
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
          body: streamers.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(t('voice_no_streams'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                  ),
                )
              : Column(
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.fromLTRB(wide ? 24 : 16, 12, wide ? 24 : 16, 4),
                      child: Row(
                        children: [
                          _VoiceChip(label: t('voice_all_screens'), selected: focused == null, onTap: () => setState(() => _focus = null)),
                          for (final p in streamers) ...[
                            const SizedBox(width: 8),
                            _VoiceChip(
                              icon: LucideIcons.monitor,
                              label: app.usernameOf(p.account),
                              selected: focused == p.session,
                              onTap: () => setState(() => _focus = p.session),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: GridView.count(
                        crossAxisCount: focused != null || !wide ? 1 : 2,
                        childAspectRatio: 16 / 9,
                        padding: EdgeInsets.fromLTRB(wide ? 24 : 16, gap, wide ? 24 : 16, wide ? 24 : 16),
                        mainAxisSpacing: gap,
                        crossAxisSpacing: gap,
                        children: [
                          for (final p in shown)
                            _ScreenTile(
                              name: app.usernameOf(p.account),
                              renderer: app.voice.renderers[p.session],
                              onTap: () => setState(() => _focus = focused == null ? p.session : null),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

/// One 16:9 tile: the screen itself or the waiting placeholder, with the name
/// plate in the bottom left corner.
class _ScreenTile extends StatelessWidget {
  const _ScreenTile({required this.name, required this.renderer, required this.onTap});

  final String name;
  final RTCVideoRenderer? renderer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = renderer;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(fmRadius),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (r != null)
                RTCVideoView(r, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
              else
                Center(child: Text(t('voice_waiting_video'), style: Theme.of(context).textTheme.bodyMedium)),
              Positioned(
                left: 12,
                bottom: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: context.fm.chrome.withValues(alpha: .85),
                    borderRadius: BorderRadius.circular(fmRadius),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.monitor, size: 12, color: scheme.onSurface),
                      const SizedBox(width: 6),
                      Text(name, style: Theme.of(context).textTheme.labelSmall!.copyWith(fontSize: 13, color: scheme.onSurface)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
