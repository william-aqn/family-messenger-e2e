// Home: the conversation list with its banners, the new-chat dialog and the
// settings sheet (artboards A02, A03, A04).
//
// Above [_twoPaneWidth] the screen becomes the desktop layout of X01: the
// 320px list on the left and the existing [ChatScreen] embedded on the right,
// selected by id instead of pushed as a route. Below that width the list
// pushes a route exactly as it always did.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/models.dart';
import '../api/ws_client.dart';
import '../crypto/fingerprint.dart';
import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';
import '../state/updater.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'voice_panel.dart';

/// Width at which the phone layout gives way to the two-pane desktop one.
const double _twoPaneWidth = 900;

/// Width of the conversation list beside the chat (X01).
const double _listWidth = 320;

/// Hover and press are a colour change over this long, nothing else.
const Duration _fade = Duration(milliseconds: 120);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The conversation shown in the right pane of the two-pane layout. The
  /// phone layout pushes a route instead and never sets this.
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final bool twoPane = MediaQuery.sizeOf(context).width >= _twoPaneWidth;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[app, updater]),
      builder: (BuildContext context, _) {
        final List<Conversation> list = app.sortedConversations;
        // A conversation that was left or removed must not stay in the pane.
        final Conversation? open = _selected == null ? null : app.conversations[_selected];
        final String? selectedId = open == null || open.removed ? null : open.id;
        return twoPane ? _desktop(context, list, selectedId) : _phone(context, list);
      },
    );
  }

  // ───── layouts ───────────────────────────────────────────────────────────

  /// A02 / A03: one column under a 56px app bar, with the FAB bottom right.
  Widget _phone(BuildContext context, List<Conversation> list) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: context.fm.chrome,
      bottomNavigationBar: const VoicePanel(),
      appBar: AppBar(
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('@${app.session!.username}', style: text.titleLarge),
            const SizedBox(height: 2),
            Text('${t('app_name')} $appVersion', style: text.labelSmall),
          ],
        ),
        actions: <Widget>[
          if (app.wsStatus != WsStatus.online) _offlineMark(context),
          IconButton(
            icon: Icon(LucideIcons.settings, color: scheme.onSurface),
            tooltip: t('settings'),
            onPressed: () => _showSettings(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: <Widget>[..._banners(context), Expanded(child: _list(context, list, twoPane: false))]),
      // 56 square on the canvas, 16 from the right and 24 from the bottom;
      // when a voice channel is joined the Scaffold lifts it above the panel.
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: FloatingActionButton(
          tooltip: t('new_chat'),
          onPressed: () => _newConversation(context, twoPane: false),
          child: const Icon(LucideIcons.plus),
        ),
      ),
    );
  }

  /// X01: the list beside the chat. The embedded [ChatScreen] brings its own
  /// app bar, composer and voice panel, so this screen adds none of them.
  Widget _desktop(BuildContext context, List<Conversation> list, String? selectedId) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: context.fm.chrome,
      // With a chat open the panel belongs to that pane; with none open this
      // is the only place left to leave the channel from.
      bottomNavigationBar: selectedId == null ? const VoicePanel() : null,
      body: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: _listWidth,
              child: Column(
                children: <Widget>[
                  _desktopHeader(context),
                  Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
                  ..._banners(context),
                  Expanded(child: _list(context, list, twoPane: true, selectedId: selectedId)),
                ],
              ),
            ),
            Expanded(
              child: selectedId == null
                  ? _noSelection(context)
                  // The existing widget, untouched: keyed so that picking
                  // another conversation gives it a fresh state.
                  : ChatScreen(key: ValueKey<String>(selectedId), convId: selectedId),
            ),
          ],
        ),
      ),
    );
  }

  /// The 56px list header of X01: the account over its presence, then the
  /// "new chat" and "settings" buttons.
  Widget _desktopHeader(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final String presence = switch (app.wsStatus) {
      WsStatus.online => t('online'),
      WsStatus.connecting => t('connecting'),
      WsStatus.offline => t('offline'),
    };
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text('@${app.session!.username}', style: text.titleMedium, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(presence, style: text.labelSmall, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (app.wsStatus != WsStatus.online) _offlineMark(context),
            IconButton(
              style: IconButton.styleFrom(minimumSize: const Size(40, 40), padding: EdgeInsets.zero),
              icon: Icon(LucideIcons.plus, color: scheme.onSurface),
              tooltip: t('new_chat'),
              onPressed: () => _newConversation(context, twoPane: true),
            ),
            IconButton(
              style: IconButton.styleFrom(minimumSize: const Size(40, 40), padding: EdgeInsets.zero),
              icon: Icon(LucideIcons.settings, color: scheme.onSurface),
              tooltip: t('settings'),
              onPressed: () => _showSettings(context),
            ),
          ],
        ),
      ),
    );
  }

  /// The cloud with a stroke through it: the socket is not online.
  Widget _offlineMark(BuildContext context) {
    return Tooltip(
      message: t('offline'),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(LucideIcons.cloudOff, color: Theme.of(context).colorScheme.primary),
      ),
    );
  }

  // ───── list ──────────────────────────────────────────────────────────────

  /// Rows are 76 high on a phone and 72 in the desktop column (A02 / X01).
  Widget _list(BuildContext context, List<Conversation> list, {required bool twoPane, String? selectedId}) {
    if (list.isEmpty) return _empty(context);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: list.length,
      itemBuilder: (BuildContext context, int i) {
        final Conversation c = list[i];
        return _ConversationRow(
          conv: c,
          compact: twoPane,
          selected: c.id == selectedId,
          onTap: () => _open(context, c.id, twoPane: twoPane),
        );
      },
    );
  }

  /// A03: nothing to show yet.
  Widget _empty(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LucideIcons.messageSquare, size: 32, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              t('no_conversations'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  /// The right pane of the two-pane layout before anything is picked.
  Widget _noSelection(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LucideIcons.messageSquare, size: 24, color: scheme.outline),
            const SizedBox(height: 12),
            Text(t('select_conversation'), style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  /// Opens a conversation: the right pane on the desktop, a route on a phone.
  void _open(BuildContext context, String id, {required bool twoPane}) {
    if (twoPane) {
      setState(() => _selected = id);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(convId: id)));
  }

  // ───── banners ───────────────────────────────────────────────────────────

  List<Widget> _banners(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String announcement = app.settings?.announcement ?? '';
    final ReleaseInfo? update = updater.dismissed ? null : updater.available;
    return <Widget>[
      if (announcement.isNotEmpty)
        _Banner(
          // A neutral banner carries a half-strength rail.
          rail: scheme.primary.withValues(alpha: .5),
          icon: LucideIcons.info,
          iconColor: scheme.onSurfaceVariant,
          text: announcement,
        ),
      if (update != null)
        _Banner(
          rail: scheme.primary,
          icon: LucideIcons.refreshCw,
          iconColor: scheme.primary,
          text: t('update_available', <String, Object?>{'version': update.tag}),
          actions: <Widget>[
            _LinkButton(label: t('update_later'), onPressed: updater.dismiss),
            _LinkButton(
              label: Updater.canSelfInstall && update.assetUrl != null ? t('update_install') : t('update_open_page'),
              strong: true,
              onPressed: () => _installUpdate(context),
            ),
          ],
        ),
    ];
  }

  // ───── new chat (A04) ────────────────────────────────────────────────────

  Future<void> _newConversation(BuildContext context, {required bool twoPane}) async {
    var group = false;
    final TextEditingController username = TextEditingController();
    final TextEditingController name = TextEditingController();
    final TextEditingController members = TextEditingController();
    String? error;
    // The user directory (when the administrator allows it) feeds name suggestions.
    var directory = const <DirectoryEntry>[];
    if (app.settings?.userDirectory != false) {
      try {
        directory = (await app.api!.users('')).where((DirectoryEntry u) => u.id != app.session!.accountId).toList();
      } catch (_) {}
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          final ThemeData theme = Theme.of(context);
          final ColorScheme scheme = theme.colorScheme;
          // Suggestions for the name being typed (the last comma-separated token of a group).
          final String raw = group ? members.text : username.text;
          final List<String> tokens = raw.split(RegExp(r'[\s,]+')).where((String s) => s.isNotEmpty).toList();
          final String typing = group ? (raw.isNotEmpty && !RegExp(r'[\s,]$').hasMatch(raw) ? (tokens.lastOrNull ?? '') : '') : raw;
          final List<String> done = group && typing.isNotEmpty ? tokens.sublist(0, tokens.length - 1) : (group ? tokens : const <String>[]);
          final Set<String> chosen = done.map((String s) => s.replaceFirst('@', '').toLowerCase()).toSet();
          final String q = typing.trim().replaceFirst('@', '').toLowerCase();
          final List<DirectoryEntry> matches = directory.where((DirectoryEntry u) {
            final String n = u.username.toLowerCase();
            return n.startsWith(q) && n != q && !chosen.contains(n);
          }).take(12).toList();
          void pick(DirectoryEntry u) {
            final TextEditingController field = group ? members : username;
            field.text = group ? '${<String>[...done, u.username].join(', ')}, ' : u.username;
            field.selection = TextSelection.collapsed(offset: field.text.length);
            setState(() {});
          }

          Widget tab(String label, bool active, VoidCallback onTap) => InkWell(
                onTap: onTap,
                hoverColor: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: active ? scheme.primary : Colors.transparent, width: 2)),
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.titleMedium?.copyWith(color: active ? scheme.onSurface : scheme.onSurfaceVariant),
                  ),
                ),
              );

          return Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(t('new_chat'), style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 18),
                    Container(
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
                      child: Row(
                        children: <Widget>[
                          tab(t('direct'), !group, () => setState(() => group = false)),
                          const SizedBox(width: 24),
                          tab(t('group'), group, () => setState(() => group = true)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (!group)
                      _LabelledField(
                        label: t('username'),
                        controller: username,
                        autofocus: true,
                        onChanged: (_) => setState(() {}),
                      ),
                    if (group) ...<Widget>[
                      _LabelledField(label: t('group_name'), controller: name, autofocus: true),
                      const SizedBox(height: 18),
                      _LabelledField(label: t('members_hint'), controller: members, onChanged: (_) => setState(() {})),
                    ],
                    if (matches.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final DirectoryEntry u in matches)
                            _SuggestionChip(label: u.username, bot: u.isBot, onPressed: () => pick(u)),
                        ],
                      ),
                    ],
                    if (error != null) ...<Widget>[
                      const SizedBox(height: 18),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(LucideIcons.alertTriangle, size: 16, color: scheme.error),
                          const SizedBox(width: 8),
                          Expanded(child: Text(error!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error))),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.primary,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                          ),
                          onPressed: () => Navigator.pop(context),
                          child: Text(t('cancel')),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () async {
                            try {
                              final String id = group
                                  ? await app.createGroup(name.text, members.text.split(RegExp(r'[\s,]+')).where((String s) => s.isNotEmpty).toList())
                                  : await app.createDirect(username.text);
                              if (context.mounted) {
                                Navigator.pop(context);
                                _open(context, id, twoPane: twoPane);
                              }
                            } catch (e) {
                              setState(() => error = e.toString());
                            }
                          },
                          child: Text(t('create')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ───── settings sheet ────────────────────────────────────────────────────

  Future<void> _showSettings(BuildContext context) async {
    final k = app.keys!;
    final String fp = await fingerprint(k.signPub, k.encPub);
    if (!context.mounted) return;
    // The sheet's own context dies with the sheet: anything opened after
    // closing it (the update dialog, the password dialog) needs the screen's.
    final BuildContext screen = context;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) {
        final ThemeData theme = Theme.of(context);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(t('settings'), style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(t('safety_number'), style: theme.inputDecorationTheme.labelStyle),
                const SizedBox(height: 4),
                // Roboto 13 grouped by four: the style the theme keeps for
                // safety numbers.
                SelectableText(fp, style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Text(t('language'), style: theme.textTheme.bodyMedium),
                    const SizedBox(width: 12),
                    DropdownButton<String>(
                      value: L10n.current,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(fmRadius),
                      icon: Icon(LucideIcons.chevronDown, size: 16, color: theme.colorScheme.onSurfaceVariant),
                      style: theme.textTheme.titleMedium,
                      items: <DropdownMenuItem<String>>[
                        for (final String c in L10n.codes) DropdownMenuItem<String>(value: c, child: Text(languageNames[c] ?? c)),
                      ],
                      onChanged: (String? v) {
                        if (v != null) {
                          app.setLanguage(v);
                          Navigator.pop(context);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('${app.serverUrl} · ${app.session!.username}', style: theme.textTheme.labelSmall),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(LucideIcons.lock, size: 20),
                  label: Text(t('change_password')),
                  onPressed: () {
                    Navigator.pop(context);
                    _changePassword(screen);
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(LucideIcons.refreshCw, size: 20),
                  label: Text(t('check_updates')),
                  onPressed: () {
                    Navigator.pop(context);
                    _checkUpdates(screen);
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(LucideIcons.logOut, size: 20),
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
      },
    );
  }
}

// ───── components ──────────────────────────────────────────────────────────

/// The design system's banner: a 2px rail, an icon, the text and the actions
/// as links. Radius 4 on the right only, the rail stays square.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.rail,
    required this.icon,
    required this.iconColor,
    required this.text,
    this.actions = const <Widget>[],
  });

  final Color rail;
  final IconData icon;
  final Color iconColor;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(width: 2, color: rail),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.only(topRight: Radius.circular(fmRadius), bottomRight: Radius.circular(fmRadius)),
                ),
                padding: EdgeInsets.fromLTRB(16, 12, actions.isEmpty ? 16 : 8, 12),
                child: Row(
                  crossAxisAlignment: actions.isEmpty ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                  children: <Widget>[
                    Icon(icon, size: 20, color: iconColor),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface, height: 1.4),
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A banner action: an underlined link, muted or 500, accent on hover.
class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onPressed, this.strong = false});

  final String label;
  final VoidCallback onPressed;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color rest = strong ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant;
    return TextButton(
      onPressed: onPressed,
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.pressed) ? theme.colorScheme.primary : rest,
        ),
        textStyle: WidgetStatePropertyAll<TextStyle?>(
          theme.textTheme.bodyMedium?.copyWith(
            fontWeight: strong ? FontWeight.w500 : FontWeight.w400,
            decoration: TextDecoration.underline,
          ),
        ),
        backgroundColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.symmetric(horizontal: 8)),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 36)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: WidgetStatePropertyAll<OutlinedBorder>(fmShape),
        animationDuration: _fade,
      ),
      child: Text(label),
    );
  }
}

/// One row of the conversation list (A02 on a phone, X01 on the desktop):
/// the type icon, the title with the disappearing-messages timer, the time,
/// the preview and the unread badge. No avatar: the design draws none.
class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.conv, required this.compact, required this.selected, required this.onTap});

  final Conversation conv;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  /// AppState marks a direct bot chat with an emoji in the title; the row
  /// draws a Lucide icon instead, so the prefix goes.
  static final RegExp _botPrefix = RegExp(r'^\u{1F916}\s*', unicode: true);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final int unread = conv.lastSeq - conv.readSeq;
    final bool bot = !conv.isGroup && app.hasBot(conv);
    final IconData? type = conv.isGroup ? LucideIcons.users : (bot ? LucideIcons.bot : null);
    final String title = app.titleOf(conv).replaceFirst(_botPrefix, '');
    final String time = _rowTime(conv.updatedAt);
    return Material(
      color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
      animationDuration: _fade,
      child: InkWell(
        onTap: onTap,
        hoverColor: scheme.surfaceContainerHigh,
        child: Container(
          constraints: BoxConstraints(minHeight: compact ? 72 : 76),
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 12 : 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (type != null) ...<Widget>[
                    Icon(type, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: Text(title, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (conv.retentionSeconds > 0) ...<Widget>[
                    const SizedBox(width: 8),
                    Icon(LucideIcons.timer, size: 16, color: scheme.onSurfaceVariant),
                  ],
                  if (time.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(time, style: theme.textTheme.labelSmall),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(child: Text(conv.preview, style: theme.textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (unread > 0) ...<Widget>[const SizedBox(width: 8), _UnreadBadge(count: unread)],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The unread count: the only pill in the list, accent on the accent's own
/// ink colour.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      height: 20,
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(fmPillRadius)),
      child: Text(
        '$count',
        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimary, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// A field with its label above it, as every form in the design draws it.
class _LabelledField extends StatelessWidget {
  const _LabelledField({required this.label, required this.controller, this.onChanged, this.autofocus = false});

  final String label;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: theme.inputDecorationTheme.labelStyle),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          autofocus: autofocus,
          autocorrect: false,
          onChanged: onChanged,
          // The typed value is accent-coloured, in the form typeface.
          style: theme.inputDecorationTheme.hintStyle?.copyWith(color: theme.colorScheme.primary),
        ),
      ],
    );
  }
}

/// A directory suggestion under the field: a small secondary button, with the
/// bot icon in front of a bot's name.
class _SuggestionChip extends StatefulWidget {
  const _SuggestionChip({required this.label, required this.bot, required this.onPressed});

  final String label;
  final bool bot;
  final VoidCallback onPressed;

  @override
  State<_SuggestionChip> createState() => _SuggestionChipState();
}

class _SuggestionChipState extends State<_SuggestionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onPressed,
        onHover: (bool v) => setState(() => _hovered = v),
        borderRadius: BorderRadius.circular(fmRadius),
        child: AnimatedContainer(
          duration: _fade,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border.all(color: _hovered ? scheme.primary : scheme.outline, width: 2),
            borderRadius: BorderRadius.circular(fmRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.bot) ...<Widget>[
                Icon(LucideIcons.bot, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
              ],
              Text(widget.label, style: theme.chipTheme.labelStyle?.copyWith(color: scheme.primary)),
            ],
          ),
        ),
      ),
    );
  }
}

// ───── helpers ─────────────────────────────────────────────────────────────

/// `HH:MM` for today, `9 Sep` for anything older; empty when the conversation
/// has never been touched.
String _rowTime(int ms) {
  if (ms <= 0) return '';
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  final DateTime now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  final List<String> months = t('months_short').split(',');
  if (months.length < 12) return '${d.day}.${d.month.toString().padLeft(2, '0')}';
  return '${d.day} ${months[d.month - 1]}';
}

/// Downloads and installs the pending release, or opens its page where the
/// app cannot replace itself.
Future<void> _installUpdate(BuildContext context) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  if (Updater.canSelfInstall && updater.latest?.assetUrl != null) {
    messenger.showSnackBar(SnackBar(content: Text(t('update_restart')), duration: const Duration(seconds: 4)));
  }
  final String? err = await updater.install();
  if (err != null) messenger.showSnackBar(SnackBar(content: Text(t('update_failed', <String, Object?>{'error': err}))));
}

/// Manual check from the settings sheet. The dialog opens at once and follows
/// the updater: a progress bar while GitHub is asked, then the verdict. (It
/// used to wait for the check and then open on the context of the settings
/// sheet, which was closed by then, so nothing ever appeared.)
Future<void> _checkUpdates(BuildContext context) async {
  unawaited(updater.check(manual: true));
  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => ListenableBuilder(
      listenable: updater,
      builder: (BuildContext context, _) {
        final ReleaseInfo? latest = updater.latest;
        final String text;
        if (updater.checking) {
          text = t('update_checking');
        } else if (updater.error != null) {
          text = t('update_check_failed', <String, Object?>{'error': updater.error});
        } else if (latest == null) {
          text = t('update_no_release');
        } else if (updater.available != null) {
          text = t('update_available', <String, Object?>{'version': latest.tag});
        } else if (!updater.isReleaseBuild) {
          text = '${t('update_dev_build')}\n${t('update_latest', <String, Object?>{'version': latest.tag})}';
        } else {
          text = t('update_none');
        }
        return AlertDialog(
          title: Text(t('check_updates')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t('update_installed', <String, Object?>{'version': appVersion}), style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              Text(text),
              if (updater.checking) ...<Widget>[const SizedBox(height: 12), const LinearProgressIndicator()],
              if (updater.installing) ...<Widget>[
                const SizedBox(height: 12),
                Text(t('update_downloading'), style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: updater.progress),
              ],
            ],
          ),
          actions: <Widget>[
            if (latest != null && !updater.checking)
              TextButton(
                onPressed: () => updater.openReleasePage(),
                child: Text(t('update_open_page')),
              ),
            if (updater.available != null && !updater.checking && Updater.canSelfInstall && latest?.assetUrl != null)
              FilledButton(
                onPressed: updater.installing ? null : () => _installUpdate(context),
                child: Text(t('update_install')),
              ),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(t('cancel'))),
          ],
        );
      },
    ),
  );
}

/// Change-password dialog from the settings sheet (PROTOCOL.md §3.2). The
/// new password is typed twice because it cannot be reset, and other devices
/// are signed out by default: that is the remedy for a leaked password.
Future<void> _changePassword(BuildContext context) async {
  final TextEditingController current = TextEditingController();
  final TextEditingController next = TextEditingController();
  final TextEditingController repeat = TextEditingController();
  var signOutOthers = true;
  var busy = false;
  // Problems with a field are shown under that field, anything else above
  // the fields: with the keyboard up only the top of the dialog is visible.
  String? currentError;
  String? nextError;
  String? repeatError;
  String? error;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) {
        final ThemeData theme = Theme.of(context);
        Future<void> submit() async {
          setState(() {
            currentError = null; // an empty or wrong one is the server's verdict
            nextError = next.text.length < AppState.minPasswordLength ? t('password_too_short', <String, Object?>{'n': AppState.minPasswordLength}) : null;
            repeatError = next.text != repeat.text ? t('passwords_differ') : null;
            error = null;
          });
          if (currentError != null || nextError != null || repeatError != null) return;
          setState(() => busy = true);
          try {
            final int n = await app.changePassword(current.text, next.text, signOutOthers: signOutOthers);
            if (context.mounted) Navigator.pop(context);
            messenger.showSnackBar(SnackBar(
              content: Text(n > 0 ? t('password_changed_signed_out', <String, Object?>{'n': n}) : t('password_changed')),
              duration: const Duration(seconds: 6), // worth reading: how many devices were signed out
            ));
          } catch (e) {
            if (!context.mounted) return;
            setState(() {
              busy = false;
              if (e is ApiException && e.code == 'invalid_credentials') {
                currentError = t('wrong_current_password');
              } else {
                error = e is StateError ? e.message : e.toString();
              }
            });
          }
        }

        return AlertDialog(
          title: Text(t('change_password')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(LucideIcons.alertTriangle, size: 16, color: theme.colorScheme.error),
                        const SizedBox(width: 8),
                        Expanded(child: Text(error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error))),
                      ],
                    ),
                  ),
                TextField(
                  controller: current,
                  decoration: InputDecoration(labelText: t('current_password'), errorText: currentError),
                  obscureText: true,
                  autofocus: true,
                  enabled: !busy,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: next,
                  decoration: InputDecoration(
                    labelText: t('new_password'),
                    helperText: t('password_min', <String, Object?>{'n': AppState.minPasswordLength}),
                    errorText: nextError,
                  ),
                  obscureText: true,
                  enabled: !busy,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: repeat,
                  decoration: InputDecoration(labelText: t('repeat_password'), errorText: repeatError),
                  obscureText: true,
                  enabled: !busy,
                  onSubmitted: (_) => busy ? null : submit(),
                ),
                CheckboxListTile(
                  value: signOutOthers,
                  onChanged: busy ? null : (bool? v) => setState(() => signOutOthers = v ?? true),
                  title: Text(t('sign_out_other_devices'), style: theme.textTheme.bodyLarge),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                Text(t('password_warning'), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.tertiary)),
                if (busy) ...<Widget>[
                  const SizedBox(height: 12),
                  ListenableBuilder(
                    listenable: app,
                    builder: (BuildContext context, _) => Text(app.busyText ?? '…', style: theme.textTheme.bodyMedium),
                  ),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: Text(t('cancel'))),
            FilledButton(onPressed: busy ? null : submit, child: Text(t('change_password'))),
          ],
        );
      },
    ),
  );
}

extension ConversationX on Conversation {
  bool get isGroup => kind == 'group';
}
