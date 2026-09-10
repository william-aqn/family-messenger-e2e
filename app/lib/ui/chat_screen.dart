import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/fingerprint.dart';
import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'voice_panel.dart';

/// Vertical rhythm of the message list (A05: a 10px gap between rows).
const double _rowGap = 10;

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

  /// The message the actions sheet is open for; it wears an accent ring (A07).
  Message? selected;

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
    setState(() => selected = m);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            _SheetLabel(t('message_actions')),
            if (body.isNotEmpty)
              _ActionRow(
                icon: LucideIcons.copy,
                label: t('copy'),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: body));
                  if (sheet.mounted) Navigator.pop(sheet);
                },
              ),
            if (canEdit)
              _ActionRow(
                icon: LucideIcons.pencil,
                label: t('edit'),
                onTap: () {
                  Navigator.pop(sheet);
                  _startEdit(m);
                },
              ),
            if (canDelete)
              _ActionRow(
                icon: LucideIcons.trash2,
                label: t('delete'),
                danger: true,
                onTap: () {
                  Navigator.pop(sheet);
                  _confirmDelete(m);
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (mounted) setState(() => selected = null);
  }

  Future<void> _confirmDelete(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) {
        final scheme = Theme.of(dialog).colorScheme;
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(fmRadius),
            side: BorderSide(color: FmColors.of(dialog).ringStrong),
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          buttonPadding: const EdgeInsets.symmetric(horizontal: 6),
          content: Text(
            t('confirm_delete_message'),
            style: Theme.of(dialog).textTheme.titleLarge?.copyWith(fontSize: 20, height: 1.3),
          ),
          actions: [
            OutlinedButton(
              style: _secondaryButton(scheme),
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onSurface,
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(t('delete')),
            ),
          ],
        );
      },
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

  /// `AppState.titleOf` still marks a bot with an emoji; the interface draws
  /// that mark as a Lucide icon, so it never reaches the screen.
  static String _titleOf(Conversation conv) => app.titleOf(conv).replaceFirst('🤖 ', '');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([app, app.voice]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final conv = app.conversations[widget.convId];
        if (conv == null) return const Scaffold(body: SizedBox.shrink());
        final list = app.messages[conv.id] ?? const <Message>[];
        if (conv.lastSeq > conv.readSeq) WidgetsBinding.instance.addPostFrameCallback((_) => app.markRead(conv.id));
        final inVoice = app.voice.inChannel(conv.id);
        final voiceCount = app.voice.participantsOf(conv.id).length;
        return Scaffold(
          bottomNavigationBar: const VoicePanel(),
          appBar: AppBar(
            automaticallyImplyLeading: false,
            // The same test the default back button uses, so a sheet or a
            // dialog on top of this route does not summon an arrow.
            leading: (ModalRoute.of(context)?.impliesAppBarDismissal ?? false)
                ? IconButton(
                    icon: const Icon(LucideIcons.arrowLeft),
                    tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                    onPressed: () => Navigator.maybePop(context),
                  )
                : null,
            titleSpacing: 4,
            title: InkWell(
              onTap: () => _showInfo(context, conv),
              borderRadius: BorderRadius.circular(fmRadius),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(_titleOf(conv), overflow: TextOverflow.ellipsis),
                  Text(
                    conv.kind == 'group' ? t('members_count', {'n': conv.serverMembers.length}) : t('direct'),
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            actions: [
              if (conv.kind == 'direct' && !app.hasBot(conv)) ...[
                IconButton(icon: const Icon(LucideIcons.phone), tooltip: t('call'), onPressed: () => _startCall(context, conv.id, video: false)),
                IconButton(icon: const Icon(LucideIcons.video), tooltip: t('video_call'), onPressed: () => _startCall(context, conv.id, video: true)),
              ],
              if (conv.kind == 'group')
                _VoiceAction(
                  count: voiceCount,
                  onPressed: () => inVoice ? app.voice.leave() : joinVoice(context, conv.id),
                ),
              IconButton(
                icon: const Icon(LucideIcons.info),
                tooltip: t('members'),
                onPressed: () => _showInfo(context, conv),
              ),
            ],
          ),
          body: Column(
            children: [
              if (conv.kind == 'group') VoiceBar(convId: conv.id),
              if (app.hasBot(conv))
                _Banner(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  background: scheme.surfaceContainerHighest,
                  rail: sandA(.5),
                  icon: LucideIcons.bot,
                  child: Text(t('bot_notice'), style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.4, color: scheme.onSurface)),
                ),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final m = list[list.length - 1 - i];
                    return _MessageTile(
                      message: m,
                      marked: m.clientMsgId == editing?.clientMsgId || m.clientMsgId == selected?.clientMsgId,
                      onActions: (m) => _showActions(context, m),
                    );
                  },
                ),
              ),
              _Footer(
                error: error,
                editing: editing,
                controller: text,
                focus: inputFocus,
                onCancelEdit: _cancelEdit,
                onAttach: _attach,
                onSend: _send,
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
        builder: (context, setState) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final roster = conv.roster;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _SheetHandle(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      conv.kind == 'group' ? t('members') : t('security'),
                      style: theme.textTheme.titleLarge?.copyWith(fontSize: 20),
                    ),
                  ),
                  _SheetRow(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text(
                      t('safety_hint'),
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.4),
                    ),
                  ),
                  for (final id in conv.serverMembers)
                    _MemberRow(
                      id: id,
                      isMe: id == me,
                      notInRoster: roster != null && !roster.contains(id) && !(app.contacts[id]?.isBot ?? false),
                    ),
                  _SheetRow(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 6,
                          children: [
                            Icon(LucideIcons.timer, size: 16, color: scheme.onSurfaceVariant),
                            Text(t('disappearing'), style: theme.inputDecorationTheme.labelStyle),
                          ],
                        ),
                        DropdownButtonFormField<int>(
                          initialValue: const [0, 3600, 86400, 604800, 2592000].contains(conv.retentionSeconds) ? conv.retentionSeconds : 0,
                          isDense: true,
                          icon: const Icon(LucideIcons.chevronDown, size: 12),
                          iconEnabledColor: scheme.primary,
                          borderRadius: BorderRadius.circular(fmRadius),
                          style: theme.inputDecorationTheme.hintStyle?.copyWith(color: scheme.primary),
                          decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                          ),
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
                      ],
                    ),
                  ),
                  if (conv.kind == 'group')
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Row(
                        spacing: 12,
                        children: [
                          if (conv.role == 'owner')
                            Expanded(
                              child: OutlinedButton(
                                style: _secondaryButton(scheme).copyWith(
                                  padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 8)),
                                ),
                                onPressed: () async {
                                  final c = TextEditingController();
                                  final name = await showDialog<String>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(t('add_member')),
                                      content: TextField(controller: c, decoration: InputDecoration(labelText: t('username'))),
                                      actions: [
                                        OutlinedButton(style: _secondaryButton(Theme.of(context).colorScheme), onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
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
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  spacing: 6,
                                  children: [
                                    const Icon(LucideIcons.plus, size: 16),
                                    Flexible(child: Text(t('add_member'), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                  ],
                                ),
                              ),
                            ),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: scheme.error,
                                side: BorderSide(color: scheme.error, width: 2),
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                              ),
                              onPressed: () async {
                                await app.leave(conv.id);
                                if (context.mounted) {
                                  Navigator.pop(context);
                                  Navigator.pop(context);
                                }
                              },
                              child: Text(t('leave_group'), overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The secondary button of the design system: a 2px accent-tinted outline,
/// sand label, 48 high on touch.
ButtonStyle _secondaryButton(ColorScheme scheme) => OutlinedButton.styleFrom(
      foregroundColor: scheme.primary,
      side: BorderSide(color: scheme.outline, width: 2),
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 20),
    );

// ───── App bar ─────────────────────────────────────────────────────────────

/// Headphones plus the count of people already in the channel, drawn as the
/// design's small pill rather than a corner badge.
class _VoiceAction extends StatelessWidget {
  const _VoiceAction({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: t('voice_channel'),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(fmRadius),
        hoverColor: scheme.surfaceContainerHigh,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                const Icon(LucideIcons.headphones),
                if (count > 0)
                  Container(
                    height: 20,
                    constraints: const BoxConstraints(minWidth: 20),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(fmPillRadius)),
                    child: Text(
                      '$count',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w500, color: scheme.onPrimary),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───── Banners ─────────────────────────────────────────────────────────────

/// The design system's banner: a 2px rail on the left, a tinted body with a
/// 4px radius on the right, an icon and free content.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.background,
    required this.rail,
    required this.icon,
    required this.child,
    this.iconColor,
    this.margin = EdgeInsets.zero,
  });

  final Color background;
  final Color rail;
  final IconData icon;
  final Widget child;
  final Color? iconColor;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    const BorderRadius shape = BorderRadius.horizontal(right: Radius.circular(fmRadius));
    return Container(
      margin: margin,
      padding: const EdgeInsets.only(left: 2),
      decoration: BoxDecoration(color: rail, borderRadius: shape),
      child: Container(
        decoration: BoxDecoration(color: background, borderRadius: shape),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: 8,
          children: [
            Icon(icon, size: 16, color: iconColor ?? Theme.of(context).colorScheme.primary),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}


/// A text link: underlined, turning accent on hover and press.
class _Link extends StatelessWidget {
  const _Link({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered) || states.contains(WidgetState.pressed) ? scheme.primary : scheme.onSurface,
        ),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        padding: const WidgetStatePropertyAll<EdgeInsets>(EdgeInsets.symmetric(horizontal: 8)),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 32)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          theme.textTheme.bodyMedium?.copyWith(decoration: TextDecoration.underline),
        ),
      ),
      child: Text(label),
    );
  }
}

// ───── Composer ────────────────────────────────────────────────────────────

/// The error line, the editing strip and the composer: one block under the
/// message list, carrying the ring that separates it from the canvas.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.error,
    required this.editing,
    required this.controller,
    required this.focus,
    required this.onCancelEdit,
    required this.onAttach,
    required this.onSend,
  });

  final String? error;
  final Message? editing;
  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onCancelEdit;
  final VoidCallback onAttach;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(
                  spacing: 8,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.alertTriangle, size: 16, color: scheme.error),
                    Expanded(child: Text(error!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error))),
                  ],
                ),
              ),
            if (editing != null)
              Container(
                color: scheme.surfaceContainerHigh,
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  spacing: 10,
                  children: [
                    Icon(LucideIcons.pencil, size: 16, color: scheme.primary),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 2,
                        children: [
                          Text(
                            t('editing_message'),
                            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, fontWeight: FontWeight.w500, color: scheme.primary),
                          ),
                          Text(
                            (editing!.payload?['body'] as String?) ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(LucideIcons.x, size: 16),
                      color: scheme.primary,
                      tooltip: t('cancel'),
                      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                      onPressed: onCancelEdit,
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                spacing: 8,
                children: [
                  IconButton(
                    icon: const Icon(LucideIcons.paperclip),
                    color: scheme.primary,
                    tooltip: t('attach'),
                    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
                    onPressed: onAttach,
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focus,
                      style: theme.inputDecorationTheme.hintStyle?.copyWith(color: scheme.primary),
                      decoration: InputDecoration(
                        hintText: t('write_message'),
                        contentPadding: const EdgeInsets.all(12),
                        constraints: const BoxConstraints(minHeight: 48),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      minLines: 1,
                      maxLines: 4,
                    ),
                  ),
                  Tooltip(
                    message: editing != null ? t('edit') : t('send'),
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        fixedSize: const Size(48, 48),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: onSend,
                      child: Icon(editing != null ? LucideIcons.check : LucideIcons.send, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───── Message rows ────────────────────────────────────────────────────────

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.onActions, this.marked = false});

  final Message message;
  final void Function(Message) onActions;

  /// Being edited, or the one the actions sheet is open for: an accent ring.
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final me = app.session!.accountId;
    final mine = message.sender == me;
    final p = message.payload;
    if (p == null) {
      return _centred(
        _Banner(
          background: scheme.errorContainer,
          rail: scheme.error,
          icon: LucideIcons.alertTriangle,
          iconColor: scheme.error,
          child: Text(t('undecryptable'), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onErrorContainer)),
        ),
      );
    }
    final type = p['t'] as String;
    if (type != 'text' && type != 'file') {
      final text = app.previewOf(message);
      if (text.isEmpty) return const SizedBox.shrink();
      return _centred(Text(text, textAlign: TextAlign.center, style: theme.textTheme.labelSmall));
    }
    final time = TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(message.ts)).format(context);
    final meta = message.failed != null
        ? message.failed!
        : message.pending
            ? t('sending')
            : message.edited
                ? '$time · ${t('edited')}'
                : time;
    // An image with a blob keeps the design's 4px bubble padding whether or
    // not the preview has arrived yet, so the row never jumps.
    final image = type == 'file' && (p['mime'] as String? ?? '').startsWith('image/') && ((p['blob'] as String?) ?? '').isNotEmpty;
    final inset = image ? const EdgeInsets.symmetric(horizontal: 8) : EdgeInsets.zero;
    final Border? border = message.failed != null
        ? Border.all(color: scheme.error, width: 2)
        : marked
            ? Border.all(color: scheme.primary, width: 2)
            : mine
                ? null
                : Border.all(color: FmColors.of(context).ring);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Opacity(
        opacity: message.pending ? .7 : 1,
        child: GestureDetector(
          onLongPress: message.pending ? null : () => onActions(message),
          onSecondaryTap: message.pending ? null : () => onActions(message),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: _rowGap / 2),
            padding: image ? const EdgeInsets.all(4) : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
            decoration: BoxDecoration(
              color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(fmRadius),
              border: border,
            ),
            // IntrinsicWidth so the bubble hugs its content: the meta row below
            // is right-aligned, and an Align with no width factor would
            // otherwise stretch every bubble to the full 78% it may occupy.
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  if (!mine)
                    Padding(
                      padding: inset.add(image ? const EdgeInsets.only(top: 2) : EdgeInsets.zero),
                      child: Text(
                        app.usernameOf(message.sender),
                        style: theme.textTheme.labelLarge?.copyWith(fontSize: 14, color: scheme.tertiary),
                      ),
                    ),
                  if (type == 'text')
                    Text(p['body'] as String? ?? '', style: theme.textTheme.bodyLarge)
                  else
                    _FileBody(payload: p, inset: inset),
                  Padding(
                    padding: inset,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        meta,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: message.failed != null
                              ? scheme.error
                              : mine
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// System lines and the undecryptable banner sit in the middle of the canvas.
  Widget _centred(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: _rowGap / 2),
        child: Align(alignment: Alignment.center, child: child),
      );
}

class _FileBody extends StatefulWidget {
  const _FileBody({required this.payload, this.inset = EdgeInsets.zero});

  final Map<String, dynamic> payload;

  /// Horizontal padding the image bubble applies to everything but the image.
  final EdgeInsets inset;

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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = widget.payload['name'] as String? ?? 'file';
    final size = (widget.payload['size'] as num?)?.toInt() ?? 0;
    if (image != null) {
      // The design draws the picture alone; the app has no lightbox, so the
      // name and the download link stay under it.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(fmRadius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260, maxHeight: 220),
              child: Image.memory(image!, fit: BoxFit.contain),
            ),
          ),
          Padding(
            padding: widget.inset,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                Flexible(
                  child: Text('$name · ${_fmt(size)}', overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
                ),
                _Link(label: t('download'), onPressed: busy ? null : _save),
              ],
            ),
          ),
        ],
      );
    }
    return Padding(
      padding: widget.inset,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(fmRadius)),
            child: Icon(isImage ? LucideIcons.image : LucideIcons.file, size: 20, color: scheme.primary),
          ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                Text(name, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge?.copyWith(fontSize: 14)),
                Text(_fmt(size), style: theme.textTheme.labelSmall),
              ],
            ),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.primary,
              side: BorderSide(color: scheme.outline, width: 2),
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 14),
            ),
            onPressed: busy ? null : _save,
            child: Text(t('download')),
          ),
        ],
      ),
    );
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}

// ───── Bottom sheets ───────────────────────────────────────────────────────

/// The 32x4 grip every bottom sheet opens with.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Center(
        child: Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outline,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// The small Roboto caption over a sheet's rows ("Message actions").
class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Text(label, style: Theme.of(context).inputDecorationTheme.helperStyle?.copyWith(fontSize: 13)),
    );
  }
}

/// A sheet row with the divider that separates it from the next one.
class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.child, this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 12)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      ),
      child: child,
    );
  }
}

/// A07: one 56px action with its icon.
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.icon, required this.label, required this.onTap, this.danger = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Color colour = danger ? scheme.error : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      hoverColor: scheme.surfaceContainerHigh,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            spacing: 16,
            children: [
              Icon(icon, size: 20, color: danger ? scheme.error : scheme.primary),
              Text(label, style: theme.textTheme.bodyLarge?.copyWith(color: colour)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A06: a member with their tags and safety number.
class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.id, required this.isMe, required this.notInRoster});

  final String id;
  final bool isMe;
  final bool notInRoster;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fm = FmColors.of(context);
    final contact = app.contacts[id];
    final name = contact?.username ?? id.substring(0, 8);
    return _SheetRow(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text.rich(
                TextSpan(
                  text: '@$name',
                  children: isMe
                      ? [
                          TextSpan(
                            text: ' (${t('you')})',
                            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 16),
                          ),
                        ]
                      : const [],
                ),
                style: theme.textTheme.titleMedium,
              ),
              if (contact?.keysChanged ?? false) _Tag(label: t('keys_changed'), background: scheme.error, foreground: scheme.onError),
              // Text on the warning tag is the canvas colour, as on the web.
              if (notInRoster) _Tag(label: t('not_in_roster'), background: fm.warn, foreground: scheme.surface),
              if (contact?.isBot ?? false) _Tag(label: t('bot'), background: fm.tagBot, foreground: scheme.primary, icon: LucideIcons.bot),
            ],
          ),
          FutureBuilder<String>(
            future: fingerprint(contact?.signPub ?? Uint8List(32), contact?.encPub ?? Uint8List(32)),
            builder: (context, snap) => Text(
              snap.data ?? '',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// The 20px pill the design keeps for small tags only.
class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.background, required this.foreground, this.icon});

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(fmPillRadius)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          if (icon != null) Icon(icon, size: 12, color: foreground),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w500, color: foreground),
          ),
        ],
      ),
    );
  }
}
