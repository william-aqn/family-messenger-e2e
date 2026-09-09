import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/fingerprint.dart';
import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.convId});

  final String convId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final text = TextEditingController();
  String? error;

  @override
  void initState() {
    super.initState();
    app.markRead(widget.convId);
  }

  Future<void> _send() async {
    final body = text.text.trim();
    if (body.isEmpty) return;
    text.clear();
    setState(() => error = null);
    try {
      await app.sendText(widget.convId, body);
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<void> _attach() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.firstOrNull;
    if (file == null || file.bytes == null) return;
    setState(() => error = null);
    try {
      final mime = _mimeFor(file.name);
      await app.sendFile(widget.convId, file.name, mime, file.bytes!);
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  static String _mimeFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const map = {'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', 'pdf': 'application/pdf', 'txt': 'text/plain', 'mp4': 'video/mp4', 'mp3': 'audio/mpeg'};
    return map[ext] ?? 'application/octet-stream';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final conv = app.conversations[widget.convId];
        if (conv == null) return const Scaffold(body: SizedBox.shrink());
        final list = app.messages[conv.id] ?? const <Message>[];
        if (conv.lastSeq > conv.readSeq) WidgetsBinding.instance.addPostFrameCallback((_) => app.markRead(conv.id));
        return Scaffold(
          appBar: AppBar(
            title: InkWell(
              onTap: () => _showInfo(context, conv),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(app.titleOf(conv), overflow: TextOverflow.ellipsis),
                  Text(conv.kind == 'group' ? '${conv.serverMembers.length} ${t('members').toLowerCase()}' : t('direct'), style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            actions: [
              if (conv.kind == 'direct' && !app.hasBot(conv)) IconButton(icon: const Icon(Icons.call), onPressed: () => app.calls.startCall(conv.id)),
              IconButton(icon: const Icon(Icons.info_outline), onPressed: () => _showInfo(context, conv)),
            ],
          ),
          body: Column(
            children: [
              if (app.hasBot(conv)) MaterialBanner(content: Text('🤖 ${t('bot_notice')}'), actions: const [SizedBox.shrink()]),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: list.length,
                  itemBuilder: (context, i) => _MessageTile(message: list[list.length - 1 - i], convId: conv.id),
                ),
              ),
              if (error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              SafeArea(
                child: Row(
                  children: [
                    IconButton(icon: const Icon(Icons.attach_file), tooltip: t('attach'), onPressed: _attach),
                    Expanded(
                      child: TextField(
                        controller: text,
                        decoration: InputDecoration(hintText: t('write_message'), border: const OutlineInputBorder()),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        minLines: 1,
                        maxLines: 4,
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.send), onPressed: _send),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showInfo(BuildContext context, Conversation conv) async {
    final me = app.session!.accountId;
    final canRetention = conv.kind == 'direct' || conv.role == 'owner';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(conv.kind == 'group' ? t('members') : t('security'), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final id in conv.serverMembers)
                FutureBuilder<String>(
                  future: fingerprint(app.contacts[id]?.signPub ?? Uint8List(32), app.contacts[id]?.encPub ?? Uint8List(32)),
                  builder: (context, snap) => ListTile(
                    dense: true,
                    title: Text('@${app.contacts[id]?.username ?? id.substring(0, 8)}${id == me ? ' (${t('you')})' : ''}${(app.contacts[id]?.isBot ?? false) ? ' 🤖' : ''}'),
                    subtitle: Text(snap.data ?? '', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
                ),
              const Divider(),
              Text('⏱ ${t('disappearing')}', style: Theme.of(context).textTheme.labelLarge),
              DropdownButton<int>(
                value: const [0, 3600, 86400, 604800, 2592000].contains(conv.retentionSeconds) ? conv.retentionSeconds : 0,
                items: [
                  DropdownMenuItem(value: 0, child: Text(t('off'))),
                  DropdownMenuItem(value: 3600, child: Text(t('hour_1'))),
                  DropdownMenuItem(value: 86400, child: Text(t('day_1'))),
                  DropdownMenuItem(value: 604800, child: Text(t('week_1'))),
                  DropdownMenuItem(value: 2592000, child: Text(t('days_30'))),
                ],
                onChanged: canRetention
                    ? (v) async {
                        if (v == null) return;
                        await app.setRetention(conv.id, v);
                        setState(() {});
                      }
                    : null,
              ),
              if (conv.kind == 'group') ...[
                const Divider(),
                if (conv.role == 'owner')
                  TextButton.icon(
                    icon: const Icon(Icons.person_add),
                    label: Text(t('add_member')),
                    onPressed: () async {
                      final c = TextEditingController();
                      final name = await showDialog<String>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(t('add_member')),
                          content: TextField(controller: c, decoration: InputDecoration(labelText: t('username'))),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
                            FilledButton(onPressed: () => Navigator.pop(context, c.text), child: Text(t('create'))),
                          ],
                        ),
                      );
                      if (name != null && name.trim().isNotEmpty) {
                        try {
                          await app.addMember(conv.id, name);
                          setState(() {});
                        } catch (e) {
                          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
                        }
                      }
                    },
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.exit_to_app),
                  label: Text(t('leave_group')),
                  onPressed: () async {
                    await app.leave(conv.id);
                    if (context.mounted) {
                      Navigator.pop(context);
                      Navigator.pop(context);
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.convId});

  final Message message;
  final String convId;

  @override
  Widget build(BuildContext context) {
    final me = app.session!.accountId;
    final mine = message.sender == me;
    final p = message.payload;
    if (p == null) {
      return Center(child: Padding(padding: const EdgeInsets.all(4), child: Text('⚠ ${t('undecryptable')}', style: Theme.of(context).textTheme.bodySmall)));
    }
    final type = p['t'] as String;
    if (type != 'text' && type != 'file') {
      final text = app.previewOf(message);
      if (text.isEmpty) return const SizedBox.shrink();
      return Center(child: Padding(padding: const EdgeInsets.all(4), child: Text(text, style: Theme.of(context).textTheme.bodySmall)));
    }
    final scheme = Theme.of(context).colorScheme;
    final time = TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(message.ts)).format(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: message.failed != null ? Border.all(color: scheme.error) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine) Text(app.usernameOf(message.sender), style: TextStyle(color: scheme.primary, fontSize: 12)),
            if (type == 'text') Text(p['body'] as String? ?? '') else _FileBody(payload: p),
            Text(
              message.failed != null
                  ? message.failed!
                  : message.pending
                      ? t('sending')
                      : time,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _FileBody extends StatefulWidget {
  const _FileBody({required this.payload});

  final Map<String, dynamic> payload;

  @override
  State<_FileBody> createState() => _FileBodyState();
}

class _FileBodyState extends State<_FileBody> {
  bool busy = false;
  Uint8List? image;

  bool get isImage => (widget.payload['mime'] as String? ?? '').startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (isImage && (widget.payload['blob'] as String? ?? '').isNotEmpty) {
      app.fetchFile(widget.payload).then((b) {
        if (mounted) setState(() => image = b);
      }).catchError((_) {});
    }
  }

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      final bytes = await app.fetchFile(widget.payload);
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${widget.payload['name']}');
      await file.writeAsBytes(bytes);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('saved_to', {'path': file.path}))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.payload['name'] as String? ?? 'file';
    final size = (widget.payload['size'] as num?)?.toInt() ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (image != null) ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(image!, fit: BoxFit.contain)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(isImage ? Icons.image : Icons.attach_file, size: 18),
            const SizedBox(width: 6),
            Flexible(child: Text('$name · ${_fmt(size)}', overflow: TextOverflow.ellipsis)),
            TextButton(onPressed: busy ? null : _save, child: Text(t('download'))),
          ],
        ),
      ],
    );
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}
