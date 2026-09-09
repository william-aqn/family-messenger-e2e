import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../main.dart';
import '../state/voice_controller.dart';

/// Joins the voice channel of [convId] and reports a refusal in a snack bar.
Future<void> joinVoice(BuildContext context, String convId) async {
  final err = await app.voice.join(convId);
  if (err != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t(err))));
}

/// Bottom bar shown on every screen while this device is in a voice channel:
/// the group, every participant with its connection state, mute and leave.
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
        Text('${app.usernameOf(participant.account)}${participant.muted ? ' 🔇' : ''}$suffix', style: Theme.of(context).textTheme.bodySmall),
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
    final names = people.map((p) => app.usernameOf(p.account)).join(', ');
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
