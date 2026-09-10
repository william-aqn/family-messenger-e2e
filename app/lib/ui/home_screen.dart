import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/ws_client.dart';
import '../crypto/fingerprint.dart';
import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';
import '../state/updater.dart';
import 'chat_screen.dart';
import 'voice_panel.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, updater]),
      builder: (context, _) {
        final list = app.sortedConversations;
        final update = updater.dismissed ? null : updater.available;
        return Scaffold(
          bottomNavigationBar: const VoicePanel(),
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('@${app.session!.username}'),
                Text(appVersion, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            actions: [
              if (app.wsStatus != WsStatus.online) const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.cloud_off, size: 20)),
              IconButton(icon: const Icon(Icons.settings), onPressed: () => _showSettings(context)),
            ],
          ),
          body: Column(
            children: [
              if ((app.settings?.announcement ?? '').isNotEmpty)
                MaterialBanner(content: Text(app.settings!.announcement), actions: const [SizedBox.shrink()]),
              if (update != null)
                MaterialBanner(
                  leading: const Icon(Icons.system_update),
                  content: Text(t('update_available', {'version': update.tag})),
                  actions: [
                    TextButton(onPressed: updater.dismiss, child: Text(t('update_later'))),
                    FilledButton(
                      onPressed: () => _installUpdate(context),
                      child: Text(Updater.canSelfInstall && update.assetUrl != null ? t('update_install') : t('update_open_page')),
                    ),
                  ],
                ),
              Expanded(
                child: list.isEmpty
                    ? Center(child: Text(t('no_conversations')))
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final c = list[i];
                          final unread = c.lastSeq - c.readSeq;
                          return ListTile(
                            leading: CircleAvatar(child: Icon(c.kind == 'group' ? Icons.group : Icons.person)),
                            title: Text('${app.titleOf(c)}${c.retentionSeconds > 0 ? ' ⏱' : ''}'),
                            subtitle: Text(c.preview, maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: unread > 0 ? Badge(label: Text('$unread')) : null,
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(convId: c.id))),
                          );
                        },
                      ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(onPressed: () => _newConversation(context), child: const Icon(Icons.add)),
        );
      },
    );
  }

  Future<void> _newConversation(BuildContext context) async {
    var group = false;
    final username = TextEditingController();
    final name = TextEditingController();
    final members = TextEditingController();
    String? error;
    // The user directory (when the administrator allows it) feeds name suggestions.
    var directory = const <DirectoryEntry>[];
    if (app.settings?.userDirectory != false) {
      try {
        directory = (await app.api!.users('')).where((u) => u.id != app.session!.accountId).toList();
      } catch (_) {}
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          // Suggestions for the name being typed (the last comma-separated token of a group).
          final raw = group ? members.text : username.text;
          final tokens = raw.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList();
          final typing = group ? (raw.isNotEmpty && !RegExp(r'[\s,]$').hasMatch(raw) ? (tokens.lastOrNull ?? '') : '') : raw;
          final done = group && typing.isNotEmpty ? tokens.sublist(0, tokens.length - 1) : (group ? tokens : const <String>[]);
          final chosen = done.map((s) => s.replaceFirst('@', '').toLowerCase()).toSet();
          final q = typing.trim().replaceFirst('@', '').toLowerCase();
          final matches = directory.where((u) {
            final n = u.username.toLowerCase();
            return n.startsWith(q) && n != q && !chosen.contains(n);
          }).take(12).toList();
          void pick(DirectoryEntry u) {
            final field = group ? members : username;
            field.text = group ? '${[...done, u.username].join(', ')}, ' : u.username;
            field.selection = TextSelection.collapsed(offset: field.text.length);
            setState(() {});
          }

          return AlertDialog(
            title: Text(t('new_chat')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<bool>(
                    segments: [ButtonSegment(value: false, label: Text(t('direct'))), ButtonSegment(value: true, label: Text(t('group')))],
                    selected: {group},
                    onSelectionChanged: (s) => setState(() => group = s.first),
                  ),
                  const SizedBox(height: 12),
                  if (!group) TextField(controller: username, decoration: InputDecoration(labelText: t('username')), autocorrect: false, onChanged: (_) => setState(() {})),
                  if (group) ...[
                    TextField(controller: name, decoration: InputDecoration(labelText: t('group_name'))),
                    TextField(controller: members, decoration: InputDecoration(labelText: t('members_hint')), autocorrect: false, onChanged: (_) => setState(() {})),
                  ],
                  if (matches.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [for (final u in matches) ActionChip(label: Text('${u.isBot ? '🤖 ' : ''}${u.username}'), onPressed: () => pick(u))],
                      ),
                    ),
                  if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
              FilledButton(
                onPressed: () async {
                  try {
                    final id = group
                        ? await app.createGroup(name.text, members.text.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList())
                        : await app.createDirect(username.text);
                    if (context.mounted) {
                      Navigator.pop(context);
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(convId: id)));
                    }
                  } catch (e) {
                    setState(() => error = e.toString());
                  }
                },
                child: Text(t('create')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    final k = app.keys!;
    final fp = await fingerprint(k.signPub, k.encPub);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t('settings'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(t('safety_number'), style: Theme.of(context).textTheme.labelMedium),
            SelectableText(fp, style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(t('language')),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: L10n.current,
                  items: [for (final c in L10n.codes) DropdownMenuItem(value: c, child: Text(languageNames[c] ?? c))],
                  onChanged: (v) {
                    if (v != null) {
                      app.setLanguage(v);
                      Navigator.pop(context);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('${app.serverUrl} · ${app.session!.username}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.system_update),
              label: Text(t('check_updates')),
              onPressed: () {
                Navigator.pop(context);
                _checkUpdates(context);
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              label: Text(t('sign_out')),
              onPressed: () {
                Navigator.pop(context);
                app.logout();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Downloads and installs the pending release, or opens its page where the
/// app cannot replace itself.
Future<void> _installUpdate(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  if (Updater.canSelfInstall && updater.latest?.assetUrl != null) {
    messenger.showSnackBar(SnackBar(content: Text(t('update_restart')), duration: const Duration(seconds: 4)));
  }
  final err = await updater.install();
  if (err != null) messenger.showSnackBar(SnackBar(content: Text(t('update_failed', {'error': err}))));
}

/// Manual check from the settings sheet: shows the result in a dialog.
Future<void> _checkUpdates(BuildContext context) async {
  await updater.check(manual: true);
  if (!context.mounted) return;
  final latest = updater.latest;
  final String text;
  if (updater.error != null) {
    text = t('update_failed', {'error': updater.error});
  } else if (latest == null) {
    text = t('update_no_release');
  } else if (updater.available != null) {
    text = t('update_available', {'version': latest.tag});
  } else if (!updater.isReleaseBuild) {
    text = '${t('update_dev_build')}\n${t('update_latest', {'version': latest.tag})}';
  } else {
    text = t('update_none');
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t('check_updates')),
      content: ListenableBuilder(
        listenable: updater,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('update_installed', {'version': appVersion})),
            const SizedBox(height: 8),
            Text(text),
            if (updater.installing) ...[
              const SizedBox(height: 12),
              Text(t('update_downloading')),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: updater.progress),
            ],
          ],
        ),
      ),
      actions: [
        if (latest != null)
          TextButton(
            onPressed: () => updater.openReleasePage(),
            child: Text(t('update_open_page')),
          ),
        if (updater.available != null && Updater.canSelfInstall && latest?.assetUrl != null)
          FilledButton(
            onPressed: updater.installing ? null : () => _installUpdate(context),
            child: Text(t('update_install')),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
      ],
    ),
  );
}

extension ConversationX on Conversation {
  bool get isGroup => kind == 'group';
}
