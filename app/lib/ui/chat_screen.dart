import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/fingerprint.dart';
import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';
import 'voice_panel.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.convId});

  final String convId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final text = TextEditingController();
  final inputFocus = FocusNode();
  String? error;

  /// The message whose text is being rewritten in the composer, if any.
  Message? editing;

  @override
  void initState() {
    super.initState();
    app.markRead(widget.convId);
  }

  @override
  void dispose() {
    text.dispose();
    inputFocus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = text.text.trim();
    if (body.isEmpty) return;
    final target = editing;
    text.clear();
    setState(() {
      error = null;
      editing = null;
    });
    try {
      if (target != null) {
        if ((target.payload?['body'] as String?) != body) await app.editText(widget.convId, target, body);
      } else {
        await app.sendText(widget.convId, body);
      }
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  void _startEdit(Message m) {
    if (!app.canEdit(m)) return;
    setState(() {
      editing = m;
      error = null;
      text.text = (m.payload?['body'] as String?) ?? '';
      text.selection = TextSelection.collapsed(offset: text.text.length);
    });
    inputFocus.requestFocus();
  }

  void _cancelEdit() {
    setState(() {
      editing = null;
      text.clear();
    });
  }

  /// Long press or right click on a message: copy, edit (own text) and
  /// delete (own messages, or any message for an administrator).
  Future<void> _showActions(BuildContext context, Message m) async {
    final canEdit = app.canEdit(m);
    final canDelete = app.canDelete(m);
    final body = m.type == 'text' ? ((m.payload?['body'] as String?) ?? '') : '';
    if (body.isEmpty && !canEdit && !canDelete) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (body.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(t('copy')),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: body));
                  if (sheet.mounted) Navigator.pop(sheet);
                },
              ),
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit),
                title: Text(t('edit')),
                onTap: () {
                  Navigator.pop(sheet);
                  _startEdit(m);
                },
              ),
            if (canDelete)
              ListTile(
                leading: Icon(Icons.delete, color: Theme.of(sheet).colorScheme.error),
                title: Text(t('delete'), style: TextStyle(color: Theme.of(sheet).colorScheme.error)),
                onTap: () {
                  Navigator.pop(sheet);
                  _confirmDelete(m);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        content: Text(t('confirm_delete_message')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(t('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.deleteMessage(widget.convId, m);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _startCall(BuildContext context, String convId, {required bool video}) {
    if (app.voice.channel != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('voice_leave_first'))));
      return;
    }
    app.calls.startCall(convId, video: video);
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
      listenable: Listenable.merge([app, app.voice]),
      builder: (context, _) {
        final conv = app.conversations[widget.convId];
        if (conv == null) return const Scaffold(body: SizedBox.shrink());
        final list = app.messages[conv.id] ?? const <Message>[];
        if (conv.lastSeq > conv.readSeq) WidgetsBinding.instance.addPostFrameCallback((_) => app.markRead(conv.id));
        final inVoice = app.voice.inChannel(conv.id);
        final voiceCount = app.voice.participantsOf(conv.id).length;
        return Scaffold(
          bottomNavigationBar: const VoicePanel(),
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
              if (conv.kind == 'direct' && !app.hasBot(conv)) ...[
                IconButton(icon: const Icon(Icons.call), tooltip: t('call'), onPressed: () => _startCall(context, conv.id, video: false)),
                IconButton(icon: const Icon(Icons.videocam), tooltip: t('video_call'), onPressed: () => _startCall(context, conv.id, video: true)),
              ],
              if (conv.kind == 'group')
                IconButton(
                  tooltip: t('voice_channel'),
                  icon: Badge.count(
                    count: voiceCount,
                    isLabelVisible: voiceCount > 0,
                    child: Icon(inVoice ? Icons.headset_mic : Icons.headset_mic_outlined),
                  ),
                  onPressed: () => inVoice ? app.voice.leave() : joinVoice(context, conv.id),
                ),
              IconButton(icon: const Icon(Icons.info_outline), onPressed: () => _showInfo(context, conv)),
            ],
          ),
          body: Column(
            children: [
              if (conv.kind == 'group') VoiceBar(convId: conv.id),
              if (app.hasBot(conv)) MaterialBanner(content: Text('🤖 ${t('bot_notice')}'), actions: const [SizedBox.shrink()]),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: list.length,
                  itemBuilder: (context, i) => _MessageTile(message: list[list.length - 1 - i], onActions: (m) => _showActions(context, m)),
                ),
              ),
              if (error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              if (editing != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.edit, size: 18),
                  title: Text(t('editing_message')),
                  subtitle: Text((editing!.payload?['body'] as String?) ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(icon: const Icon(Icons.close), tooltip: t('cancel'), onPressed: _cancelEdit),
                ),
              SafeArea(
                child: Row(
                  children: [
                    IconButton(icon: const Icon(Icons.attach_file), tooltip: t('attach'), onPressed: _attach),
                    Expanded(
                      child: TextField(
                        controller: text,
                        focusNode: inputFocus,
                        decoration: InputDecoration(hintText: t('write_message'), border: const OutlineInputBorder()),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        minLines: 1,
                        maxLines: 4,
                      ),
                    ),
                    IconButton(icon: Icon(editing != null ? Icons.check : Icons.send), tooltip: editing != null ? t('edit') : t('send'), onPressed: _send),
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
  const _MessageTile({required this.message, required this.onActions});

  final Message message;
  final void Function(Message) onActions;

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
    final meta = message.failed != null
        ? message.failed!
        : message.pending
            ? t('sending')
            : message.edited
                ? '$time · ${t('edited')}'
                : time;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: message.pending ? null : () => onActions(message),
        onSecondaryTap: message.pending ? null : () => onActions(message),
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
              Text(meta, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
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
