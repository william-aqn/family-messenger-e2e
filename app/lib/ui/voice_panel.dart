import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../i18n/strings.dart';
import '../main.dart';
import '../state/voice_controller.dart';

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
          color: scheme.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.headset_mic, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${t('voice_channel')} · ${conv == null ? t('group') : app.titleOf(conv)}',
                          style: Theme.of(context).textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(icon: Icon(ch.muted ? Icons.mic_off : Icons.mic), tooltip: ch.muted ? t('unmute') : t('mute'), onPressed: app.voice.toggleMute),
                      IconButton(
                        icon: Icon(ch.sharing ? Icons.stop_screen_share : Icons.screen_share),
                        tooltip: ch.sharing ? t('stop_sharing') : t('share_screen'),
                        onPressed: () => _toggleShare(context),
                      ),
                      IconButton(icon: const Icon(Icons.call_end), color: scheme.error, tooltip: t('voice_leave'), onPressed: app.voice.leave),
                    ],
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      for (final p in people) _ParticipantChip(participant: p, state: p.session == ch.session ? null : (ch.peers[p.session] ?? PeerState.connecting)),
                    ],
                  ),
                  if (streamers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: FilledButton.tonalIcon(
                        icon: const Icon(Icons.monitor),
                        label: Text('${t('voice_screens')} (${streamers.length})'),
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceScreensPage())),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ParticipantChip extends StatelessWidget {
  const _ParticipantChip({required this.participant, required this.state});

  final VoiceParticipant participant;

  /// Null for this device itself.
  final PeerState? state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      null || PeerState.connected => Colors.green,
      PeerState.connecting => Colors.grey,
      PeerState.failed => Colors.red,
    };
    final suffix = state == null ? '' : ' · ${t('voice_state_${state!.name}')}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(
          '${app.usernameOf(participant.account)}${participant.muted ? ' 🔇' : ''}${participant.sharing ? ' 🖥' : ''}$suffix',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Strip under a group's app bar: who is in the channel, join or leave.
class VoiceBar extends StatelessWidget {
  const VoiceBar({super.key, required this.convId});

  final String convId;

  @override
  Widget build(BuildContext context) {
    final voice = app.voice;
    final people = voice.participantsOf(convId);
    final joined = voice.inChannel(convId);
    if (people.isEmpty && !joined) return const SizedBox.shrink();
    final names = people.map((p) => '${app.usernameOf(p.account)}${p.sharing ? ' 🖥' : ''}').join(', ');
    return MaterialBanner(
      leading: const Icon(Icons.headset_mic),
      content: Text(names.isEmpty ? t('voice_empty') : t('voice_in_channel', {'names': names})),
      actions: [
        if (joined)
          TextButton(onPressed: voice.leave, child: Text(t('voice_leave')))
        else
          TextButton(onPressed: () => joinVoice(context, convId), child: Text(t('voice_join'))),
      ],
    );
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
        final streamers = app.voice.streamers();
        // A focused streamer who stopped falls back to the grid.
        final focused = streamers.any((p) => p.session == _focus) ? _focus : null;
        final shown = focused == null ? streamers : streamers.where((p) => p.session == focused).toList();
        final wide = MediaQuery.sizeOf(context).width > 900;
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text(t('voice_screens')),
            actions: [
              IconButton(
                icon: const Icon(Icons.stop_screen_share),
                tooltip: app.voice.channel?.sharing == true ? t('stop_sharing') : t('share_screen'),
                onPressed: () => _toggleShare(context),
              ),
            ],
          ),
          body: streamers.isEmpty
              ? Center(child: Text(t('voice_no_streams'), style: const TextStyle(color: Colors.white70)))
              : Column(
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Row(
                        children: [
                          ChoiceChip(label: Text(t('voice_all_screens')), selected: focused == null, onSelected: (_) => setState(() => _focus = null)),
                          for (final p in streamers) ...[
                            const SizedBox(width: 6),
                            ChoiceChip(label: Text(app.usernameOf(p.account)), selected: focused == p.session, onSelected: (_) => setState(() => _focus = p.session)),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: GridView.count(
                        crossAxisCount: focused != null || !wide ? 1 : 2,
                        childAspectRatio: 16 / 9,
                        padding: const EdgeInsets.all(6),
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
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

class _ScreenTile extends StatelessWidget {
  const _ScreenTile({required this.name, required this.renderer, required this.onTap});

  final String name;
  final RTCVideoRenderer? renderer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = renderer;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (r != null)
              RTCVideoView(r, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
            else
              Center(child: Text(t('voice_waiting_video'), style: const TextStyle(color: Colors.white54))),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
