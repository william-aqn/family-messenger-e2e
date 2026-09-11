// Home: the conversation list with its banners, the new-chat dialog and the
// settings sheet (artboards A02, A03, A04).
//
// Above [_twoPaneWidth] the screen becomes the desktop layout of X01: the
// 320px list on the left and the existing [ChatScreen] embedded on the right,
// selected by id instead of pushed as a route. Below that width the list
// pushes a route exactly as it always did.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../api/invite_link.dart';
import '../api/models.dart';
import '../api/ws_client.dart';
import '../crypto/fingerprint.dart';
import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';
import '../state/updater.dart';
import '../theme.dart';
import 'chat_screen.dart';
import 'search_panel.dart';
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
      // The search controller is in the list because its results take the place
      // of the conversation list in both layouts.
      listenable: Listenable.merge(<Listenable>[app, app.search, updater]),
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
            // The product name and the version have gone: the version lives in
            // the settings sheet, and this line is worth the connection status.
            _presence(context),
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
      body: Column(
        children: <Widget>[
          const SearchBlock(),
          ..._banners(context),
          if (app.search.active)
            SearchResults(onOpen: (String id) => _open(context, id, twoPane: false), reserveFab: true)
          else
            Expanded(child: _list(context, list, twoPane: false)),
        ],
      ),
      // 56 square on the canvas, 16 from the right and 24 from the bottom;
      // when a voice channel is joined the Scaffold lifts it above the panel.
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: FloatingActionButton(
          tooltip: t('new_group'),
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
                  const SearchBlock(compact: true),
                  ..._banners(context),
                  if (app.search.active)
                    SearchResults(onOpen: (String id) => _open(context, id, twoPane: true))
                  else
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

  /// The connection status with its dot, under the account name on both
  /// layouts.
  Widget _presence(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (String label, Color colour) = switch (app.wsStatus) {
      WsStatus.online => (t('status_online'), context.fm.ok),
      WsStatus.connecting => (t('status_connecting'), context.fm.busy),
      WsStatus.offline => (t('status_offline'), context.fm.offline),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: <Widget>[
        Container(width: 8, height: 8, decoration: BoxDecoration(color: colour, shape: BoxShape.circle)),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall)),
      ],
    );
  }

  /// The 56px list header of X01: the account over its presence, then the
  /// "new group" and "settings" buttons.
  Widget _desktopHeader(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return ConstrainedBox(
      // A minimum, not the 56 X01 draws: the account over its presence needs
      // more than that once the text-size setting is turned up.
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('@${app.session!.username}', style: text.titleMedium, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  _presence(context),
                ],
              ),
            ),
            if (app.wsStatus != WsStatus.online) _offlineMark(context),
            IconButton(
              style: IconButton.styleFrom(minimumSize: const Size(40, 40), padding: EdgeInsets.zero),
              icon: Icon(LucideIcons.plus, color: scheme.onSurface),
              tooltip: t('new_group'),
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
      // Somebody changed this account's password from another device. Since
      // a change no longer needs the old password, this banner is the only
      // warning the owner gets (PROTOCOL.md §3.2).
      if (app.passwordChangedElsewhereAt != null)
        _Banner(
          rail: scheme.error,
          icon: LucideIcons.alertTriangle,
          iconColor: scheme.error,
          text: t('password_changed_elsewhere'),
          actions: <Widget>[_LinkButton(label: t('dismiss'), onPressed: app.dismissPasswordChanged)],
        ),
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
          // Suggestions for the name being typed — the last comma-separated
          // token of the member list.
          final String raw = members.text;
          final List<String> tokens = raw.split(RegExp(r'[\s,]+')).where((String s) => s.isNotEmpty).toList();
          final String typing = raw.isNotEmpty && !RegExp(r'[\s,]$').hasMatch(raw) ? (tokens.lastOrNull ?? '') : '';
          final List<String> done = typing.isNotEmpty ? tokens.sublist(0, tokens.length - 1) : tokens;
          final Set<String> chosen = done.map((String s) => s.replaceFirst('@', '').toLowerCase()).toSet();
          final String q = typing.trim().replaceFirst('@', '').toLowerCase();
          final List<DirectoryEntry> matches = directory.where((DirectoryEntry u) {
            final String n = u.username.toLowerCase();
            return n.startsWith(q) && n != q && !chosen.contains(n);
          }).take(12).toList();
          void pick(DirectoryEntry u) {
            final TextEditingController field = members;
            field.text = '${<String>[...done, u.username].join(', ')}, ';
            field.selection = TextSelection.collapsed(offset: field.text.length);
            setState(() {});
          }

          return Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(t('new_group'), style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 18),
                    // A one-to-one chat starts from the search now, where you
                    // see the person before writing to them.
                    _Banner(
                      rail: sandA(.5),
                      icon: LucideIcons.search,
                      iconColor: scheme.primary,
                      text: t('dm_from_search_hint'),
                    ),
                    const SizedBox(height: 18),
                    _LabelledField(label: t('group_name'), controller: name, autofocus: true),
                    const SizedBox(height: 18),
                    _LabelledField(label: t('members_hint'), controller: members, onChanged: (_) => setState(() {})),
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
                              final String id = await app.createGroup(
                                name.text,
                                members.text.split(RegExp(r'[\s,]+')).where((String s) => s.isNotEmpty).toList(),
                              );
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

  // ───── settings sheet (A13) ──────────────────────────────────────────────

  Future<void> _showSettings(BuildContext context) async {
    final k = app.keys!;
    final String fp = await fingerprint(k.signPub, k.encPub);
    if (!context.mounted) return;
    // The sheet's own context dies with the sheet: anything opened after
    // closing it (the update dialog, the password dialog) needs the screen's.
    final BuildContext screen = context;
    // Same for the confirmation of the copy: the messenger has to outlive the
    // sheet's own element.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      // The sheet is as tall as A13 draws it, not the default 9/16 of the
      // screen, which cuts the last button off.
      isScrollControlled: true,
      // A13 draws its own 32x4 grip, tighter than the Material handle.
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(fmRadius)),
        side: BorderSide(color: FmColors.of(context).ringStrong),
      ),
      // The sheet listens to `app` so the text-size buttons redraw it at the
      // size they just picked, and scrolls because at the largest size (or on
      // a short screen) the sections no longer fit between the grip and the
      // sign-out button.
      builder: (BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (BuildContext context, Widget? _) {
          final ThemeData theme = Theme.of(context);
          final ColorScheme scheme = theme.colorScheme;
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const _SheetHandle(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: Text(t('settings'), style: theme.textTheme.headlineSmall?.copyWith(fontSize: 22)),
                    ),
                    // The safety number with the 44px copy button beside it.
                    _SheetSection(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        spacing: 6,
                        children: <Widget>[
                          Text(t('safety_number'), style: theme.inputDecorationTheme.labelStyle),
                          Text(t('safety_number_hint'), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          Row(
                            spacing: 12,
                            children: <Widget>[
                              // Roboto 13 grouped by four: the style the theme
                              // keeps for safety numbers, in the accent colour.
                              Expanded(child: SelectableText(fp, style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary))),
                              IconButton(
                                icon: const Icon(LucideIcons.copy, size: 20),
                                color: scheme.primary,
                                tooltip: t('copy'),
                                onPressed: () async {
                                  await Clipboard.setData(ClipboardData(text: fp));
                                  messenger
                                    ..clearSnackBars()
                                    ..showSnackBar(SnackBar(content: Text(t('copied'))));
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // The 48px language select; picking one closes the sheet.
                    _SheetSection(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: <Widget>[
                          Text(t('language'), style: theme.inputDecorationTheme.labelStyle),
                          Container(
                            // A minimum, not a height: the largest text size
                            // needs more than 48 and would otherwise be cut.
                            constraints: const BoxConstraints(minHeight: 48),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(fmRadius),
                              border: Border.all(color: scheme.outline, width: 2),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: L10n.current,
                                isExpanded: true,
                                // The 48 belongs to the box around it, not to the
                                // button's own 48-high item.
                                isDense: true,
                                style: theme.inputDecorationTheme.hintStyle?.copyWith(color: scheme.primary),
                                iconSize: 12,
                                icon: Icon(LucideIcons.chevronDown, size: 12, color: scheme.primary),
                                dropdownColor: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(fmRadius),
                                focusColor: Colors.transparent,
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
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The text size, five steps drawn at the size they set.
                    _SheetSection(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(child: Text(t('ui_scale'), style: theme.inputDecorationTheme.labelStyle)),
                              Text('${(app.textScale * 100).round()}%', style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary)),
                            ],
                          ),
                          // Not const, and the current size is a parameter:
                          // a const widget is canonicalised and the sheet
                          // rebuilding around it would not touch the row, so
                          // the ring would stay on whichever step was current
                          // when the sheet opened.
                          _TextSizePicker(current: app.textScale),
                          // The sheet is already drawn at the chosen size, so
                          // a real bubble is the preview and there is no copy
                          // of the sizes to keep in step.
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(fmRadius),
                                  border: Border.all(color: FmColors.of(context).ring),
                                ),
                                child: Text(t('ui_scale_preview'), style: theme.textTheme.bodyLarge),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Server policy, not protocol: the server reads these in
                    // plaintext and could ignore them (PROTOCOL.md §10).
                    _SheetSection(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: <Widget>[
                          Text(t('visibility'), style: theme.inputDecorationTheme.labelStyle),
                          _VisibilityCheck(
                            label: t('find_me_in_search'),
                            value: app.visibility.findMeInSearch,
                            onChanged: (bool v) => app.setVisibility(<String, dynamic>{'find_me_in_search': v}),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 32),
                            child: Text(t('find_me_in_search_hint'), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          ),
                          _VisibilityCheck(
                            label: t('show_online'),
                            value: app.visibility.showOnline,
                            onChanged: (bool v) => app.setVisibility(<String, dynamic>{'show_online': v}),
                          ),
                          _VisibilityCheck(
                            label: t('allow_group_add'),
                            value: app.visibility.allowGroupAdd,
                            onChanged: (bool v) => app.setVisibility(<String, dynamic>{'allow_group_add': v}),
                          ),
                        ],
                      ),
                    ),
                    // "<server> · @user" behind a lock, with the build under it
                    // — the app bar used to carry the version and no longer does.
                    _SheetSection(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        spacing: 4,
                        children: <Widget>[
                          Row(
                            spacing: 8,
                            children: <Widget>[
                              Icon(LucideIcons.lock, size: 16, color: scheme.outline),
                              Expanded(
                                child: Text(
                                  '${app.serverUrl} · @${app.session!.username}',
                                  style: theme.inputDecorationTheme.labelStyle,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 24),
                            child: Text('${t('app_name')} $appVersion', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        spacing: 12,
                        children: <Widget>[
                          // A19, administrators only: the invitation to show a
                          // relative who is standing next to you.
                          if (app.session?.isAdmin ?? false)
                            OutlinedButton(
                              style: _secondaryButton(scheme),
                              onPressed: () {
                                Navigator.pop(context);
                                _showInvite(screen);
                              },
                              child: _iconLabel(LucideIcons.qrCode, t('invite_share_title')),
                            ),
                          OutlinedButton(
                            style: _secondaryButton(scheme),
                            onPressed: () {
                              Navigator.pop(context);
                              _changePassword(screen);
                            },
                            child: _iconLabel(LucideIcons.lock, t('change_password')),
                          ),
                          OutlinedButton(
                            style: _secondaryButton(scheme),
                            onPressed: () {
                              Navigator.pop(context);
                              _checkUpdates(screen);
                            },
                            child: _iconLabel(LucideIcons.refreshCw, t('check_updates')),
                          ),
                          // Destructive outline, and no confirmation: A13.
                          OutlinedButton(
                            style: _dangerButton(scheme),
                            onPressed: () {
                              Navigator.pop(context);
                              app.logout();
                            },
                            child: _iconLabel(LucideIcons.logOut, t('sign_out')),
                          ),
                        ],
                      ),
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
}

// ───── components ──────────────────────────────────────────────────────────

/// One line of the "Visibility" block: a checkbox and its label, tappable
/// across the whole row.
class _VisibilityCheck extends StatelessWidget {
  const _VisibilityCheck({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        spacing: 8,
        children: <Widget>[
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(value: value, onChanged: (bool? v) => onChanged(v ?? false)),
          ),
          Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
        ],
      ),
    );
  }
}

/// The five text sizes of the settings sheet, each drawn as a letter of the
/// size it sets.
///
/// The samples are the one place in the app that ignores the setting they
/// control: scaled like everything else, all five boxes would grow together
/// and the row would say nothing about the difference between them.
class _TextSizePicker extends StatelessWidget {
  const _TextSizePicker({required this.current});

  final double current;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return MediaQuery.withNoTextScaling(
      child: Row(
        spacing: 8,
        children: <Widget>[
          for (final double scale in AppState.textScales)
            Expanded(
              child: _TextSizeStep(
                scale: scale,
                selected: (scale - current).abs() < 0.001,
                scheme: scheme,
              ),
            ),
        ],
      ),
    );
  }
}

class _TextSizeStep extends StatelessWidget {
  const _TextSizeStep({required this.scale, required this.selected, required this.scheme});

  final double scale;
  final bool selected;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => app.setTextScale(scale),
      borderRadius: BorderRadius.circular(fmRadius),
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(fmRadius),
          border: Border.all(color: selected ? scheme.primary : scheme.outline, width: 2),
        ),
        child: Text(
          t('ui_scale_sample'),
          semanticsLabel: '${(scale * 100).round()}%',
          style: TextStyle(fontSize: 12 * scale, color: selected ? scheme.primary : scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// The 32x4 grip A13 opens the settings sheet with.
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

/// A block of the settings sheet, closed by the hairline that separates it
/// from the next one.
class _SheetSection extends StatelessWidget {
  const _SheetSection({required this.child, this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 12)});

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

/// The label of a full-width sheet button: its icon 10px in front of the text.
Widget _iconLabel(IconData icon, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 10,
      children: <Widget>[
        Icon(icon, size: 20),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ],
    );

/// Secondary button: 48 high, a 2px border, accent text.
ButtonStyle _secondaryButton(ColorScheme scheme) => OutlinedButton.styleFrom(
      foregroundColor: scheme.primary,
      side: BorderSide(color: scheme.outline, width: 2),
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 20),
    );

/// The destructive variant of it: everything in the danger colour.
ButtonStyle _dangerButton(ColorScheme scheme) => OutlinedButton.styleFrom(
      foregroundColor: scheme.error,
      side: BorderSide(color: scheme.error, width: 2),
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 20),
    );

/// The design system's 4px linear progress: the accent over the chrome-3
/// track. [value] null while the work has no measurable progress.
Widget _progressBar(ThemeData theme, double? value) => LinearProgressIndicator(
      value: value,
      minHeight: 4,
      backgroundColor: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(2),
    );

/// Alarm banner (A14): the danger wash behind a 2px rail.
Widget _alertBanner(ThemeData theme, String message) {
  final ColorScheme scheme = theme.colorScheme;
  return ClipRRect(
    borderRadius: const BorderRadius.horizontal(right: Radius.circular(fmRadius)),
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(width: 2, color: scheme.error),
          Expanded(
            child: Container(
              color: scheme.errorContainer,
              padding: const EdgeInsets.fromLTRB(10, 12, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: <Widget>[
                  Icon(LucideIcons.alertTriangle, size: 20, color: scheme.error),
                  Expanded(
                    child: Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, height: 1.4, color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

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
      // Minimums, not a height: the number inside is scaled by the text-size
      // setting and would spill out of a 20px pill.
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
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
/// app cannot install one. The desktop swaps its own folder and starts itself
/// again; Android hands the APK to the system installer, which asks the user
/// and replaces the package — so the two announce different things up front.
Future<void> _installUpdate(BuildContext context) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  if (Updater.canSelfInstall && updater.latest?.assetUrl != null) {
    messenger.showSnackBar(SnackBar(
      content: Text(Updater.restartsItself ? t('update_restart') : t('update_installer_opening')),
      duration: const Duration(seconds: 4),
    ));
  }
  // The updater hands back a finished line: a missing permission is not a
  // failure, and a sentence of ours does not want "Update failed:" in front.
  final String? err = await updater.install();
  if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
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
        final ThemeData theme = Theme.of(context);
        final ColorScheme scheme = theme.colorScheme;
        final ReleaseInfo? latest = updater.latest;
        final bool available = updater.available != null;
        // A15 draws exactly one status line under "Installed: v…".
        final String text;
        Color colour = scheme.onSurface;
        if (updater.checking) {
          text = t('update_checking');
        } else if (updater.installError != null) {
          // A refused install is not a failed check, and on Android the first
          // one is refused until the user allows this app to install packages.
          text = updater.installError!;
          colour = scheme.error;
        } else if (updater.error != null) {
          text = t('update_check_failed', <String, Object?>{'error': updater.error});
          colour = scheme.error;
        } else if (latest == null) {
          text = t('update_no_release');
        } else if (available) {
          text = t('update_available', <String, Object?>{'version': latest.tag});
          colour = scheme.primary;
        } else if (!updater.isReleaseBuild) {
          text = '${t('update_dev_build')}\n${t('update_latest', <String, Object?>{'version': latest.tag})}';
        } else {
          text = t('update_none');
        }
        final Widget status = Text(text, style: theme.textTheme.bodyLarge?.copyWith(color: colour, height: 1.4));
        final double? progress = updater.progress;
        return AlertDialog(
          title: Text(t('check_updates')),
          titleTextStyle: theme.textTheme.headlineSmall?.copyWith(fontSize: 22),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          buttonPadding: EdgeInsets.zero,
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: <Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: <Widget>[
                    _installedLine(theme),
                    if (available)
                      Row(
                        spacing: 8,
                        children: <Widget>[
                          Icon(LucideIcons.refreshCw, size: 16, color: scheme.primary),
                          Expanded(child: status),
                        ],
                      )
                    else
                      status,
                  ],
                ),
                if (updater.checking) _progressBar(theme, null),
                // While installing the bar carries the percentage the updater
                // already reports.
                if (updater.installing)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: <Widget>[
                      _progressBar(theme, progress),
                      Text(
                        updater.handedOver
                            ? t('update_waiting_installer')
                            : progress == null
                                ? t('update_downloading')
                                : t('update_downloading_percent', <String, Object?>{'percent': (progress * 100).round()}),
                        style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                OutlinedButton(
                  style: _secondaryButton(scheme),
                  onPressed: () => Navigator.pop(context),
                  child: Text(t('cancel')),
                ),
                if (latest != null && !updater.checking && !updater.installing)
                  OutlinedButton(
                    style: _secondaryButton(scheme),
                    onPressed: () => updater.openReleasePage(),
                    child: Text(t('update_open_page')),
                  ),
                if (available && !updater.checking && !updater.installing && Updater.canSelfInstall && latest?.assetUrl != null)
                  FilledButton(
                    onPressed: () => _installUpdate(context),
                    child: Text(t('update_install')),
                  ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

/// "Installed: v0.2.3" — the label muted, the version in the body colour.
Widget _installedLine(ThemeData theme) {
  final String line = t('update_installed', <String, Object?>{'version': appVersion});
  final TextStyle? label = theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant);
  final int at = line.indexOf(appVersion);
  if (at < 0) return Text(line, style: label);
  return Text.rich(
    TextSpan(
      text: line.substring(0, at),
      children: <InlineSpan>[
        TextSpan(text: appVersion, style: TextStyle(color: theme.colorScheme.onSurface)),
        TextSpan(text: line.substring(at + appVersion.length)),
      ],
    ),
    style: label,
  );
}

/// Change-password dialog from the settings sheet (PROTOCOL.md §3.2). No
/// current password is asked for: this device proves itself with the account
/// keys it already holds, which is what lets somebody who forgot the password
/// set a new one. The new password is typed twice because it cannot be reset,
/// and other devices are signed out by default: that is the remedy for a
/// leaked password.
Future<void> _changePassword(BuildContext context) async {
  final TextEditingController next = TextEditingController();
  final TextEditingController repeat = TextEditingController();
  var signOutOthers = true;
  var busy = false;
  // Problems with a field are shown under that field, anything else above
  // the fields: with the keyboard up only the top of the dialog is visible.
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
            nextError = next.text.length < AppState.minPasswordLength ? t('password_too_short', <String, Object?>{'n': AppState.minPasswordLength}) : null;
            repeatError = next.text != repeat.text ? t('passwords_differ') : null;
            error = null;
          });
          if (nextError != null || repeatError != null) return;
          setState(() => busy = true);
          try {
            final int n = await app.changePassword(next.text, signOutOthers: signOutOthers);
            if (context.mounted) Navigator.pop(context);
            messenger.showSnackBar(SnackBar(
              content: Text(n > 0 ? t('password_changed_signed_out', <String, Object?>{'n': n}) : t('password_changed')),
              duration: const Duration(seconds: 6), // worth reading: how many devices were signed out
            ));
          } catch (e) {
            if (!context.mounted) return;
            setState(() {
              busy = false;
              error = switch (e) {
                ApiException(code: 'challenge_expired') => t('challenge_expired'),
                ApiException(code: 'invalid_signature') => t('invalid_signature'),
                StateError() => e.message,
                _ => e.toString(),
              };
            });
          }
        }

        final ColorScheme scheme = theme.colorScheme;
        // 48-high fields, with a field's own problem under it in 13px danger.
        InputDecoration field(String label, String? errorText, {String? helperText}) => InputDecoration(
              labelText: label,
              helperText: helperText,
              errorText: errorText,
              constraints: const BoxConstraints(minHeight: 48),
              errorStyle: theme.inputDecorationTheme.errorStyle?.copyWith(fontSize: 13),
            );

        return AlertDialog(
          title: Text(t('change_password')),
          titleTextStyle: theme.textTheme.headlineSmall?.copyWith(fontSize: 22),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          buttonPadding: EdgeInsets.zero,
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: <Widget>[
                  if (error != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 8,
                      children: <Widget>[
                        Icon(LucideIcons.alertTriangle, size: 16, color: scheme.error),
                        Expanded(child: Text(error!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error))),
                      ],
                    ),
                  TextField(
                    controller: next,
                    decoration: field(
                      t('new_password'),
                      nextError,
                      helperText: t('password_min', <String, Object?>{'n': AppState.minPasswordLength}),
                    ),
                    obscureText: true,
                    autofocus: true,
                    enabled: !busy,
                  ),
                  TextField(
                    controller: repeat,
                    decoration: field(t('repeat_password'), repeatError),
                    obscureText: true,
                    enabled: !busy,
                    onSubmitted: (_) => busy ? null : submit(),
                  ),
                  // The checkbox row of A14: 22px box, 14px label, 44 tall.
                  InkWell(
                    onTap: busy ? null : () => setState(() => signOutOthers = !signOutOthers),
                    borderRadius: BorderRadius.circular(fmRadius),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: Row(
                        spacing: 10,
                        children: <Widget>[
                          Checkbox(
                            value: signOutOthers,
                            onChanged: busy ? null : (bool? v) => setState(() => signOutOthers = v ?? true),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            // A14 keeps the box outlined once it is ticked;
                            // Material drops the border in that state.
                            side: WidgetStateBorderSide.resolveWith(
                              (Set<WidgetState> s) => BorderSide(
                                color: s.contains(WidgetState.disabled) ? scheme.outline.withValues(alpha: .4) : scheme.outline,
                                width: 2,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(t('sign_out_other_devices'), style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _alertBanner(theme, t('password_change_warning')),
                  if (busy)
                    ListenableBuilder(
                      listenable: app,
                      builder: (BuildContext context, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: <Widget>[
                          _progressBar(theme, null),
                          Text(app.busyText ?? '…', style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                OutlinedButton(
                  style: _secondaryButton(scheme),
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: Text(t('cancel')),
                ),
                // While the key is being derived the button keeps its colour
                // at .7 instead of going grey.
                Opacity(
                  opacity: busy ? .7 : 1,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      disabledBackgroundColor: scheme.primary,
                      disabledForegroundColor: scheme.onPrimary,
                    ),
                    onPressed: busy ? null : submit,
                    child: Text(t('change_password')),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

/// A19: the administrator's own invitation, opened from the settings sheet.
Future<void> _showInvite(BuildContext context) async {
  // The sheet keeps the confirmation of the copy on the screen's messenger,
  // the way the settings sheet does, so it survives the sheet's own element.
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  await showModalBottomSheet<void>(
    context: context,
    // As tall as the QR needs; the default 9/16 would cut the buttons off.
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(fmRadius)),
      side: BorderSide(color: FmColors.of(context).ringStrong),
    ),
    builder: (BuildContext context) => _InviteSheet(messenger: messenger),
  );
}

/// The sheet of A19: the invitation link as a QR code on a sand plate, with
/// the code, its expiry and the two actions under it.
///
/// The invitation itself comes from the admin API: an unused code is reused,
/// and only when there is none does the sheet create a single new one, so
/// opening it twice does not fill the invite list.
class _InviteSheet extends StatefulWidget {
  const _InviteSheet({required this.messenger});

  final ScaffoldMessengerState messenger;

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  String? _code;

  /// Unix seconds; 0 when the invitation lasts until it is used.
  int _expiresAt = 0;
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final List<Map<String, dynamic>> invites = await app.api!.adminInvites();
      final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      Map<String, dynamic>? pick;
      for (final Map<String, dynamic> i in invites) {
        final bool used = ((i['used_by'] as String?) ?? '').isNotEmpty || _int(i['used_at']) > 0;
        final int expires = _int(i['expires_at']);
        if (used || (expires > 0 && expires <= now)) continue;
        if (pick == null || _outlives(i, pick)) pick = i;
      }
      String code;
      int expires;
      if (pick != null) {
        code = pick['code'] as String;
        expires = _int(pick['expires_at']);
      } else {
        // No expiry: an invitation shown from a phone is used on the spot or
        // sent on, and a dead code is worse than an old one.
        final List<String> codes = await app.api!.adminCreateInvites();
        if (codes.isEmpty) throw StateError('the server created no invite code');
        code = codes.first;
        expires = 0;
      }
      if (!mounted) return;
      setState(() {
        _code = code;
        _expiresAt = expires;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  /// True when [a] stays valid longer than [b]: one that never runs out beats
  /// one that does, then the later expiry, then the newer code.
  static bool _outlives(Map<String, dynamic> a, Map<String, dynamic> b) {
    final int ea = _int(a['expires_at']);
    final int eb = _int(b['expires_at']);
    if (ea == 0 || eb == 0) return ea == 0 && eb != 0;
    if (ea != eb) return ea > eb;
    return _int(a['created_at']) > _int(b['created_at']);
  }

  static int _int(Object? v) => (v as num?)?.toInt() ?? 0;

  Future<void> _copy(String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    widget.messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(t('copied'))));
  }

  Future<void> _share(String link) async {
    // The share sheet of iPadOS is a popover and anchors on the widget that
    // opened it; every other platform ignores the rectangle.
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(ShareParams(
        text: link,
        subject: t('invite_share_title'),
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? code = _code;
    // The plate is 16 inside the sheet's 24: 252 is 28 modules at the 9px the
    // design draws, and a longer server address only shrinks them.
    final double qr = math.min(252.0, math.max(120.0, MediaQuery.sizeOf(context).width - 80));
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: <Widget>[
            const _SheetHandle(),
            Text(t('invite_share_title'), style: theme.textTheme.headlineSmall?.copyWith(fontSize: 22)),
            Text(t('invite_share_hint'), style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
            if (_error != null) _alertBanner(theme, _error!),
            if (_busy)
              SizedBox(
                height: qr + 32,
                child: const Center(child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 2))),
              ),
            if (code != null) ..._invitation(theme, scheme, code, qr),
          ],
        ),
      ),
    );
  }

  /// The plate, the code, its expiry and the two 48-high actions.
  List<Widget> _invitation(ThemeData theme, ColorScheme scheme, String code, double qr) {
    final String link = inviteLink(code, app.serverUrl);
    return <Widget>[
      Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: sand, borderRadius: BorderRadius.circular(fmRadius)),
          // Dark modules on the sand plate, whatever the theme: a camera
          // cannot read a light-on-dark code, so these two are functional
          // colours rather than decoration.
          child: QrImageView(
            data: link,
            size: qr,
            padding: EdgeInsets.zero,
            backgroundColor: sand,
            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: cBg1),
            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: cBg1),
            errorStateBuilder: (BuildContext context, Object? error) => SizedBox(
              width: qr,
              height: qr,
              child: const Center(child: Icon(LucideIcons.alertTriangle, size: 24, color: cBg1)),
            ),
          ),
        ),
      ),
      // The code itself: Roboto 16 with the design's +.04em, in the accent.
      Text(
        code,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(fontSize: 16, letterSpacing: 16 * .04, color: scheme.primary),
      ),
      // The board draws a validity line under the code; a code that never
      // expires says so rather than leaving the gap empty.
      Text(
        _expiresAt > 0 ? t('invite_expires_at', <String, Object?>{'date': _inviteDate(_expiresAt)}) : t('invite_no_expiry'),
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(fontSize: 13, letterSpacing: 0, color: scheme.onSurfaceVariant),
      ),
      Row(
        spacing: 12,
        children: <Widget>[
          Expanded(
            child: OutlinedButton(
              // Tighter than the sheet's other buttons: two of them share the
              // row, and "Копировать ссылку" does not fit the usual padding.
              style: _secondaryButton(scheme).copyWith(padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 8))),
              onPressed: () => _copy(link),
              child: _iconLabel(LucideIcons.copy, t('copy_link')),
            ),
          ),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: () => _share(link),
              child: Text(t('share'), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    ];
  }
}

/// "12 Sep, 14:20" for the expiry line of A19, in the abbreviated months the
/// conversation list already dates its rows with.
String _inviteDate(int seconds) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  final String time = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  final List<String> months = t('months_short').split(',');
  if (months.length < 12) return '${d.day}.${d.month.toString().padLeft(2, '0')}, $time';
  return '${d.day} ${months[d.month - 1]}, $time';
}

extension ConversationX on Conversation {
  bool get isGroup => kind == 'group';
}
