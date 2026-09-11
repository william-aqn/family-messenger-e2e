// The search under the chat list: chats, people and messages.
//
// Chats and messages are matched against what this device already holds —
// the server keeps ciphertext and could not search it — and people come from
// the server's directory, with the exact lookup as the fallback for anybody
// who is not listed.
import 'package:flutter/foundation.dart';

import '../api/models.dart';
import 'app_state.dart';

enum SearchFilter { all, chats, people, messages }

class ChatHit {
  const ChatHit(this.conv, this.title);

  final Conversation conv;
  final String title;
}

class PersonHit {
  const PersonHit(this.entry, {required this.known});

  final DirectoryEntry entry;

  /// Already in a conversation with us, so the row says when they were last
  /// about instead of "no chats in common".
  final bool known;
}

class MessageHit {
  const MessageHit(this.message, this.title, this.body);

  final Message message;
  final String title;
  final String body;
}

/// How many rows of one kind are worth drawing before the column is a wall.
const int _maxPerGroup = 20;

class ChatSearch extends ChangeNotifier {
  ChatSearch(this._app);

  final AppState _app;

  String query = '';
  SearchFilter filter = SearchFilter.all;
  List<ChatHit> chats = const [];
  List<PersonHit> people = const [];
  List<MessageHit> messages = const [];

  /// The administrator switched the directory off: only an exact name works.
  bool peopleUnavailable = false;
  bool busy = false;

  /// How far "load the whole history" has got, or null when it is not running.
  ({int done, int total})? historyLoad;

  bool get active => query.trim().isNotEmpty;

  void setFilter(SearchFilter f) {
    filter = f;
    notifyListeners();
  }

  int _token = 0;

  void clear() {
    _token++;
    query = '';
    filter = SearchFilter.all;
    chats = const [];
    people = const [];
    messages = const [];
    busy = false;
    notifyListeners();
  }

  Future<void> search(String raw) async {
    query = raw;
    final String q = raw.trim().replaceFirst('@', '').toLowerCase();
    final int token = ++_token;
    if (q.isEmpty) {
      chats = const [];
      people = const [];
      messages = const [];
      busy = false;
      notifyListeners();
      return;
    }
    busy = true;
    chats = _matchChats(q);
    messages = _matchMessages(q);
    notifyListeners();
    final List<PersonHit> found = await _matchPeople(q);
    if (token != _token) return;
    people = found;
    busy = false;
    notifyListeners();
  }

  List<ChatHit> _matchChats(String q) {
    final List<ChatHit> out = [];
    for (final Conversation c in _app.sortedConversations) {
      final String title = _app.titleOf(c).replaceFirst('🤖 ', '');
      if (!title.toLowerCase().contains(q)) continue;
      out.add(ChatHit(c, title));
      if (out.length >= _maxPerGroup) break;
    }
    return out;
  }

  List<MessageHit> _matchMessages(String q) {
    final List<MessageHit> out = [];
    for (final MapEntry<String, List<Message>> e in _app.messages.entries) {
      final Conversation? conv = _app.conversations[e.key];
      if (conv == null || conv.removed) continue;
      final String title = _app.titleOf(conv).replaceFirst('🤖 ', '');
      for (final Message m in e.value) {
        final String body = (m.payload?['body'] as String?) ?? '';
        if (m.type != 'text' || !body.toLowerCase().contains(q)) continue;
        out.add(MessageHit(m, title, body));
      }
    }
    // Newest first: in a chat that has run for years the useful answer is
    // almost always the recent one.
    out.sort((MessageHit a, MessageHit b) => b.message.ts.compareTo(a.message.ts));
    return out.length > _maxPerGroup ? out.sublist(0, _maxPerGroup) : out;
  }

  Future<List<PersonHit>> _matchPeople(String q) async {
    final String me = _app.session?.accountId ?? '';
    final Set<String> known = {
      for (final Conversation c in _app.conversations.values)
        if (!c.removed)
          for (final String id in c.serverMembers)
            if (id != me) id,
    };
    PersonHit hit(DirectoryEntry e) => PersonHit(e, known: known.contains(e.id));
    try {
      final List<DirectoryEntry> list = await _app.api!.users(q);
      peopleUnavailable = false;
      final List<DirectoryEntry> others = list.where((DirectoryEntry e) => e.id != me).toList();
      if (others.isNotEmpty) {
        return [for (final DirectoryEntry e in others.take(_maxPerGroup)) hit(e)];
      }
    } catch (_) {
      peopleUnavailable = true;
    }
    // Nothing listed: the name may be complete and belong to somebody who
    // asked not to be listed. The exact lookup answers either way — it is
    // where the keys come from (PROTOCOL.md §7).
    try {
      final UserView u = await _app.api!.user(q);
      if (u.id == me) return const [];
      return [hit(DirectoryEntry(id: u.id, username: u.username, displayName: u.displayName, isBot: u.isBot))];
    } catch (_) {
      return const [];
    }
  }

  /// Fetches and decrypts everything the server still holds, so the message
  /// search has something to find. A sync does this already; a device that has
  /// just been added, or a list that has not finished syncing, is where it
  /// earns its place.
  Future<void> loadAllHistory() async {
    if (historyLoad != null) return;
    final List<Conversation> list = _app.sortedConversations;
    historyLoad = (done: 0, total: list.length);
    notifyListeners();
    try {
      for (int i = 0; i < list.length; i++) {
        await _app.loadHistory(list[i].id);
        historyLoad = (done: i + 1, total: list.length);
        notifyListeners();
      }
    } finally {
      historyLoad = null;
      // Whatever arrived is worth searching again.
      if (active) await search(query);
      notifyListeners();
    }
  }
}
