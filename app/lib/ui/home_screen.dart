import 'package:flutter/material.dart';

import '../api/ws_client.dart';
import '../crypto/fingerprint.dart';
import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';
import 'chat_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final list = app.sortedConversations;
        return Scaffold(
          appBar: AppBar(
            title: Text('@${app.session!.username}'),
            actions: [
              if (app.wsStatus != WsStatus.online) const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.cloud_off, size: 20)),
              IconButton(icon: const Icon(Icons.settings), onPressed: () => _showSettings(context)),
            ],
          ),
          body: Column(
            children: [
              if ((app.settings?.announcement ?? '').isNotEmpty)
                MaterialBanner(content: Text(app.settings!.announcement), actions: const [SizedBox.shrink()]),
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
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(t('new_chat')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: [ButtonSegment(value: false, label: Text(t('direct'))), ButtonSegment(value: true, label: Text(t('group')))],
                selected: {group},
                onSelectionChanged: (s) => setState(() => group = s.first),
              ),
              const SizedBox(height: 12),
              if (!group) TextField(controller: username, decoration: InputDecoration(labelText: t('username')), autocorrect: false),
              if (group) ...[
                TextField(controller: name, decoration: InputDecoration(labelText: t('group_name'))),
                TextField(controller: members, decoration: InputDecoration(labelText: t('members_hint')), autocorrect: false),
              ],
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            ],
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
        ),
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

extension ConversationX on Conversation {
  bool get isGroup => kind == 'group';
}
