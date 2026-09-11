// The search block under the chat list (A02 / A03 / X01) and the results that
// take the list's place while something is typed.
//
// Chats and messages are matched on this device — the server holds ciphertext
// and could not search it — and people come from the directory, with the exact
// lookup behind it for anybody who is not listed.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../i18n/strings.dart';
import '../main.dart';
import '../state/chat_search.dart';
import '../theme.dart';

/// "HH:MM" today, "9 Sep" otherwise — the conversation list's own format.
String searchTime(int ms) {
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

/// The field and its filter chips. [compact] is the desktop column, where the
/// design draws 36 instead of the phone's 44.
class SearchBlock extends StatefulWidget {
  const SearchBlock({super.key, this.compact = false});

  final bool compact;

  @override
  State<SearchBlock> createState() => _SearchBlockState();
}

class _SearchBlockState extends State<SearchBlock> {
  final TextEditingController _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _text.text = app.search.query;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: app.search,
      builder: (BuildContext context, Widget? _) {
        // Cleared from elsewhere (a result was opened, Escape): follow it.
        if (app.search.query.isEmpty && _text.text.isNotEmpty) _text.clear();
        final bool active = app.search.query.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: <Widget>[
              Container(
                constraints: BoxConstraints(minHeight: widget.compact ? 36 : 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(fmRadius),
                  border: Border.all(color: active ? scheme.primary : FmColors.of(context).ring, width: 2),
                ),
                child: Row(
                  spacing: 8,
                  children: <Widget>[
                    Icon(LucideIcons.search, size: 16, color: active ? scheme.primary : scheme.onSurfaceVariant),
                    Expanded(
                      child: TextField(
                        controller: _text,
                        onChanged: (String v) => unawaitedSearch(v),
                        textInputAction: TextInputAction.search,
                        style: theme.inputDecorationTheme.hintStyle?.copyWith(color: active ? scheme.primary : scheme.onSurface),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          hintText: t('search_placeholder'),
                        ),
                      ),
                    ),
                    if (active)
                      IconButton(
                        icon: const Icon(LucideIcons.x, size: 14),
                        color: scheme.primary,
                        tooltip: t('search_clear'),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        onPressed: () {
                          _text.clear();
                          app.search.clear();
                        },
                      ),
                  ],
                ),
              ),
              Row(
                spacing: 6,
                children: <Widget>[
                  for (final SearchFilter f in SearchFilter.values) _FilterChip(filter: f, compact: widget.compact),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void unawaitedSearch(String v) {
    // The search is cheap and runs as the query is typed; the controller drops
    // an earlier run that finishes late.
    app.search.search(v);
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.filter, required this.compact});

  final SearchFilter filter;
  final bool compact;

  static const Map<SearchFilter, String> _labels = <SearchFilter, String>{
    SearchFilter.all: 'filter_all',
    SearchFilter.chats: 'filter_chats',
    SearchFilter.people: 'filter_people',
    SearchFilter.messages: 'filter_messages',
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool selected = app.search.filter == filter;
    return InkWell(
      onTap: () => app.search.setFilter(filter),
      borderRadius: BorderRadius.circular(fmRadius),
      child: Container(
        constraints: BoxConstraints(minHeight: compact ? 24 : 28),
        padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? sandA(.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(fmRadius),
        ),
        child: Text(
          t(_labels[filter]!),
          style: theme.textTheme.labelLarge?.copyWith(
            fontSize: compact ? 12 : 13,
            fontWeight: FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// The three groups of results. Replaces the conversation list in the column.
class SearchResults extends StatelessWidget {
  const SearchResults({super.key, required this.onOpen, this.reserveFab = false});

  /// Opens a conversation the way the surrounding layout does — a route on the
  /// phone, the right pane on the desktop.
  final void Function(String convId) onOpen;

  /// Keeps the note at the bottom clear of the floating button the phone
  /// layout draws over this corner.
  final bool reserveFab;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[app, app.search]),
      builder: (BuildContext context, Widget? _) {
        final ChatSearch s = app.search;
        final bool showChats = s.filter == SearchFilter.all || s.filter == SearchFilter.chats;
        final bool showPeople = s.filter == SearchFilter.all || s.filter == SearchFilter.people;
        final bool showMessages = s.filter == SearchFilter.all || s.filter == SearchFilter.messages;
        final List<Widget> rows = <Widget>[];
        if (showChats && s.chats.isNotEmpty) {
          rows.add(_GroupHeader(label: t('search_group_chats', {'n': s.chats.length}), first: rows.isEmpty));
          rows.addAll([for (final ChatHit c in s.chats) _ChatRow(hit: c, onOpen: onOpen)]);
        }
        if (showPeople && s.people.isNotEmpty) {
          rows.add(_GroupHeader(label: t('search_group_people', {'n': s.people.length}), first: rows.isEmpty));
          rows.addAll([for (final PersonHit p in s.people) _PersonRow(hit: p, onOpen: onOpen)]);
        }
        if (showMessages && s.messages.isNotEmpty) {
          rows.add(_GroupHeader(label: t('search_group_messages', {'n': s.messages.length}), first: rows.isEmpty));
          rows.addAll([for (final MessageHit m in s.messages) _MessageRow(hit: m, onOpen: onOpen)]);
        }
        if (rows.isEmpty && !s.busy) rows.add(_Centred(text: t('search_nothing_found')));
        if (showPeople && s.peopleUnavailable) rows.add(_Note(text: t('search_people_off')));
        return Expanded(
          child: Column(
            children: <Widget>[
              Expanded(child: ListView(padding: EdgeInsets.zero, children: rows)),
              if (showMessages) _ResultsFoot(reserveFab: reserveFab),
            ],
          ),
        );
      },
    );
  }
}

class _ResultsFoot extends StatelessWidget {
  const _ResultsFoot({required this.reserveFab});

  final bool reserveFab;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ({int done, int total})? load = app.search.historyLoad;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 14, reserveFab ? 88 : 20, 14),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: FmColors.of(context).ring))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: <Widget>[
          Text(t('search_local_note'), style: theme.textTheme.bodySmall?.copyWith(height: 1.5, color: Theme.of(context).colorScheme.outline)),
          if (load != null)
            Text(
              t('search_loading_history', {'done': load.done, 'total': load.total}),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
            )
          else
            Tooltip(
              message: t('search_load_history_hint'),
              child: InkWell(
                onTap: () => app.search.loadAllHistory(),
                child: Text(
                  t('search_load_history'),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, decoration: TextDecoration.underline),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.first});

  final String label;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      decoration: first ? null : BoxDecoration(border: Border(top: BorderSide(color: FmColors.of(context).ring))),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.04 * 12, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// A match is drawn in the accent colour, never on a background.
class _Marked extends StatelessWidget {
  const _Marked({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final String q = app.search.query.trim().replaceFirst('@', '').toLowerCase();
    final int at = q.isEmpty ? -1 : text.toLowerCase().indexOf(q);
    if (at < 0) return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    final TextStyle hit = (style ?? const TextStyle()).copyWith(color: Theme.of(context).colorScheme.primary);
    return Text.rich(
      TextSpan(children: <InlineSpan>[
        TextSpan(text: text.substring(0, at)),
        TextSpan(text: text.substring(at, at + q.length), style: hit),
        TextSpan(text: text.substring(at + q.length)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.child, this.onTap, this.minHeight = 56});

  final Widget child;
  final VoidCallback? onTap;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      hoverColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Container(
        constraints: BoxConstraints(minHeight: minHeight),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: child,
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.hit, required this.onOpen});

  final ChatHit hit;
  final void Function(String convId) onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool group = hit.conv.kind == 'group';
    return _Row(
      onTap: () {
        app.search.clear();
        onOpen(hit.conv.id);
      },
      child: Row(
        spacing: 8,
        children: <Widget>[
          Icon(group ? LucideIcons.users : (app.hasBot(hit.conv) ? LucideIcons.bot : LucideIcons.user), size: 16, color: scheme.onSurfaceVariant),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: <Widget>[
                _Marked(text: hit.title, style: theme.textTheme.titleMedium),
                Text(
                  group ? t('members_count', {'n': hit.conv.serverMembers.length}) : t('direct'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (hit.conv.retentionSeconds > 0) Icon(LucideIcons.timer, size: 16, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _PersonRow extends StatefulWidget {
  const _PersonRow({required this.hit, required this.onOpen});

  final PersonHit hit;
  final void Function(String convId) onOpen;

  @override
  State<_PersonRow> createState() => _PersonRowState();
}

class _PersonRowState extends State<_PersonRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final PersonHit p = widget.hit;
    final String second = !p.known
        ? t('search_no_common')
        : p.entry.lastSeen > 0
            ? t('search_last_seen', {'date': searchTime(p.entry.lastSeen * 1000)})
            : '';
    return _Row(
      child: Row(
        spacing: 8,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: p.entry.online ? FmColors.of(context).ok : scheme.outline, shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: <Widget>[
                _Marked(text: '@${p.entry.username}', style: theme.textTheme.titleMedium),
                if (second.isNotEmpty)
                  Text(second, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _write,
            child: Text(t('search_write')),
          ),
        ],
      ),
    );
  }

  Future<void> _write() async {
    setState(() => _busy = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final String id = await app.createDirect(widget.hit.entry.username);
      app.search.clear();
      widget.onOpen(id);
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.hit, required this.onOpen});

  final MessageHit hit;
  final void Function(String convId) onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return _Row(
      minHeight: 64,
      onTap: () {
        app.search.clear();
        onOpen(hit.message.convId);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: <Widget>[
          Row(
            spacing: 8,
            children: <Widget>[
              Expanded(
                child: Text(
                  '${hit.title} · ${app.usernameOf(hit.message.sender)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              Text(searchTime(hit.message.ts), style: theme.textTheme.bodySmall?.copyWith(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          _Marked(text: hit.body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.4, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _Centred extends StatelessWidget {
  const _Centred({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4, color: Theme.of(context).colorScheme.outline)),
    );
  }
}
