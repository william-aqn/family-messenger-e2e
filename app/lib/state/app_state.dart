// Application state: session, contacts, conversations, decrypted messages
// and the sync engine (PROTOCOL.md §5.2, §7). Messages are kept in memory
// and re-synced from the server on start; the server keeps the history.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/ws_client.dart';
import '../crypto/account.dart';
import '../crypto/bytes.dart';
import '../crypto/envelope.dart';
import '../crypto/files.dart';
import '../crypto/ids.dart';
import '../crypto/primitives.dart';
import '../i18n/strings.dart';
import 'call_controller.dart';
import 'voice_controller.dart';

class Contact {
  Contact({required this.id, required this.username, required this.signPub, required this.encPub, this.isBot = false, this.displayName = ''});

  final String id;
  String username;
  final Uint8List signPub;
  final Uint8List encPub;
  bool isBot;
  String displayName;
  bool keysChanged = false;
}

class Conversation {
  Conversation({required this.id, required this.kind, required this.role, required this.joinedSeq});

  final String id;
  String kind;
  String name = '';
  String role;
  int joinedSeq;
  int lastSeq = 0;
  int readSeq = 0;
  int syncedSeq = 0;
  int retentionSeconds = 0;
  List<String> serverMembers = [];
  List<String>? roster;
  int rosterSeq = 0;
  String preview = '';
  /// Sequence number of the message behind [preview], so that edits and
  /// deletions can refresh it.
  int previewSeq = 0;
  int updatedAt = 0;
  bool removed = false;
}

class Message {
  Message({
    required this.convId,
    required this.seq,
    required this.clientMsgId,
    required this.sender,
    required this.ts,
    required this.serverTs,
    this.payload,
    this.error,
    this.pending = false,
  });

  final String convId;
  int seq;
  final String clientMsgId;
  final String sender;
  final int ts;
  int serverTs;
  final Map<String, dynamic>? payload;
  final String? error;
  bool pending;
  String? failed;

  /// The sender replaced the text with a later `text.edit` (PROTOCOL.md §6.3).
  bool edited = false;

  String get type => (payload?['t'] as String?) ?? '';
}

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({this.persist = true}) {
    calls = CallController(this);
    voice = VoiceController(this);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back in the foreground: a socket that died meanwhile would still look
    // open, so check it before the user sends anything or makes a call.
    if (state == AppLifecycleState.resumed) _ws?.poke();
  }

  /// Keep the session in secure storage (off in integration tests, which
  /// must not touch the device's real session).
  final bool persist;

  static const _storage = FlutterSecureStorage();

  late final CallController calls;
  late final VoiceController voice;
  ApiClient? api;
  WsClient? _ws;
  StreamSubscription<Frame>? _frameSub;
  StreamSubscription<WsStatus>? _statusSub;
  Timer? _purgeTimer;

  String serverUrl = '';
  Session? session;
  AccountKeys? keys;
  ServerSettings? settings;
  WsStatus wsStatus = WsStatus.offline;
  bool booting = true;
  bool syncing = false;
  String? busyText;

  final Map<String, Contact> contacts = {};
  final Map<String, Conversation> conversations = {};
  final Map<String, List<Message>> messages = {};
  final Map<String, Future<Uint8List>> _fileCache = {};
  final Map<String, Future<void>> _locks = {};

  bool get signedIn => session != null && keys != null && api != null;

  List<Conversation> get sortedConversations => conversations.values.where((c) => !c.removed).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  // ---------- session ----------

  Future<void> init() async {
    if (!persist) {
      booting = false;
      notifyListeners();
      return;
    }
    try {
      final lang = await _storage.read(key: 'lang');
      if (lang != null) L10n.set(lang);
      final server = await _storage.read(key: 'server');
      final token = await _storage.read(key: 'token');
      final sessionJson = await _storage.read(key: 'session');
      final signSeed = await _storage.read(key: 'sign_seed');
      final encPriv = await _storage.read(key: 'enc_priv');
      if (server != null && token != null && sessionJson != null && signSeed != null && encPriv != null) {
        serverUrl = server;
        session = Session.fromJson(jsonDecode(sessionJson) as Map<String, dynamic>);
        keys = await keysFromSecrets(b64decode(signSeed), b64decode(encPriv));
        api = ApiClient(server, token: token);
        _startSync();
        unawaited(refreshMe());
      }
    } catch (e) {
      debugPrint('restore failed: $e');
    } finally {
      booting = false;
      notifyListeners();
    }
  }

  Future<void> setLanguage(String code) async {
    L10n.set(code);
    if (persist) await _storage.write(key: 'lang', value: code);
    notifyListeners();
  }

  static String _deviceName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'iOS app';
      case TargetPlatform.android:
        return 'Android app';
      case TargetPlatform.windows:
        return 'Windows app';
      case TargetPlatform.linux:
        return 'Linux app';
      case TargetPlatform.macOS:
        return 'macOS app';
      case TargetPlatform.fuchsia:
        return 'app';
    }
  }

  String _normalizeServer(String s) {
    var v = s.trim();
    if (v.isEmpty) throw const ApiException(0, 'invalid_server', 'Server URL is required');
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'https://$v';
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  Future<void> register(String server, String username, String password, String invite) async {
    final base = _normalizeServer(server);
    _busy(t('deriving_key'));
    try {
      final k = await generateKeys();
      final salt = randomBytes(saltSize);
      final derived = await deriveKeys(password, salt);
      final bundle = await newKeyBundle(derived.encKey, k);
      final client = ApiClient(base);
      final sess = await client.register({
        'username': username.trim(),
        'salt': b64encode(salt),
        'auth_key': b64encode(derived.authKey),
        'sign_pub': b64encode(k.signPub),
        'enc_pub': b64encode(k.encPub),
        'key_bundle': b64encode(bundle),
        'invite': invite.trim(),
        'device_name': _deviceName(),
      });
      await _establish(base, sess, k);
    } finally {
      _busy(null);
    }
  }

  Future<void> login(String server, String username, String password) async {
    final base = _normalizeServer(server);
    _busy(t('deriving_key'));
    try {
      final client = ApiClient(base);
      final params = await client.authParams(username.trim());
      final kdf = KdfParams.fromJson(params['kdf'] as Map<String, dynamic>);
      final derived = await deriveKeys(password, b64decode(params['salt'] as String), kdf);
      final sess = await client.login({
        'username': username.trim(),
        'auth_key': b64encode(derived.authKey),
        'device_name': _deviceName(),
      });
      final k = await openKeyBundle(derived.encKey, b64decode(sess.keyBundle), b64decode(sess.signPub), b64decode(sess.encPub));
      await _establish(base, sess, k);
    } finally {
      _busy(null);
    }
  }

  Future<void> _establish(String base, Session sess, AccountKeys k) async {
    _stopSync();
    contacts.clear();
    conversations.clear();
    messages.clear();
    serverUrl = base;
    session = sess;
    keys = k;
    api = ApiClient(base, token: sess.token);
    if (persist) {
      await _storage.write(key: 'server', value: base);
      await _storage.write(key: 'token', value: sess.token);
      await _storage.write(
        key: 'session',
        value: jsonEncode({
          'account_id': sess.accountId,
          'username': sess.username,
          'device_id': sess.deviceId,
          'token': sess.token,
          'sign_pub': sess.signPub,
          'enc_pub': sess.encPub,
          'key_bundle': sess.keyBundle,
          'salt': sess.salt,
          'is_admin': sess.isAdmin,
        }),
      );
      await _storage.write(key: 'sign_seed', value: b64encode(k.signSeed));
      await _storage.write(key: 'enc_priv', value: b64encode(k.encPriv));
    }
    _startSync();
    unawaited(refreshMe());
    notifyListeners();
  }

  Future<void> logout() async {
    await voice.leave();
    _stopSync();
    try {
      await api?.logout();
    } catch (_) {}
    session = null;
    keys = null;
    api = null;
    contacts.clear();
    conversations.clear();
    messages.clear();
    if (persist) {
      for (final k in ['server', 'token', 'session', 'sign_seed', 'enc_priv']) {
        await _storage.delete(key: k);
      }
    }
    notifyListeners();
  }

  Future<void> refreshMe() async {
    try {
      final me = await api!.me();
      settings = ServerSettings.fromJson(me['settings'] as Map<String, dynamic>);
      notifyListeners();
    } on ApiException catch (e) {
      if (e.status == 401 || e.status == 403) await logout();
    } catch (_) {}
  }

  /// Shortest password accepted at registration and at a password change.
  static const int minPasswordLength = 12;

  /// Changes the password (PROTOCOL.md §3.2): proves the current one with its
  /// auth key, re-encrypts the key bundle with the new one and, when asked,
  /// signs every other device out. Returns how many devices were signed out.
  Future<int> changePassword(String current, String next, {bool signOutOthers = true}) async {
    final client = api;
    final k = keys;
    final sess = session;
    if (client == null || k == null || sess == null) throw StateError('not signed in');
    if (next.length < minPasswordLength) throw StateError(t('password_too_short', {'n': minPasswordLength}));
    _busy(t('deriving_key'));
    try {
      final params = await client.authParams(sess.username);
      final kdf = KdfParams.fromJson(params['kdf'] as Map<String, dynamic>);
      final cur = await deriveKeys(current, b64decode(params['salt'] as String), kdf);
      final salt = randomBytes(saltSize);
      final fresh = await deriveKeys(next, salt);
      final bundle = await newKeyBundle(fresh.encKey, k);
      _busy(t('changing_password'));
      return await client.changePassword({
        'auth_key': b64encode(cur.authKey),
        'new_salt': b64encode(salt),
        'new_auth_key': b64encode(fresh.authKey),
        'new_key_bundle': b64encode(bundle),
        'sign_out_others': signOutOthers,
      });
    } finally {
      _busy(null);
    }
  }

  void _busy(String? text) {
    busyText = text;
    notifyListeners();
  }

  // ---------- sync ----------

  void _startSync() {
    _stopSync();
    final ws = WsClient(baseUrl: serverUrl, token: session!.token);
    _ws = ws;
    _statusSub = ws.statusChanges.listen((s) {
      debugPrint('ws: $s');
      wsStatus = s;
      notifyListeners();
    });
    _frameSub = ws.frames.listen(_onFrame);
    ws.connect();
    _purgeTimer = Timer.periodic(const Duration(minutes: 1), (_) => _purgeExpired());
  }

  void _stopSync() {
    _frameSub?.cancel();
    _statusSub?.cancel();
    _purgeTimer?.cancel();
    _ws?.close();
    _ws = null;
    wsStatus = WsStatus.offline;
  }

  void _onFrame(Frame f) {
    switch (f.type) {
      case 'hello':
        unawaited(fullSync());
      case 'message':
        unawaited(_onLiveMessage(MessageView.fromJson(f.data as Map<String, dynamic>)));
      case 'signal':
        unawaited(handleIncoming(MessageView.fromJson(f.data as Map<String, dynamic>), stored: false));
      case 'event':
        unawaited(_onEvent(f.data as Map<String, dynamic>));
      case 'revoked':
        // The server refused the token: /me answers 401 and refreshMe signs out.
        unawaited(refreshMe());
    }
  }

  Future<T> _withLock<T>(String convId, Future<T> Function() fn) {
    final prev = _locks[convId] ?? Future.value();
    final run = prev.then((_) => fn(), onError: (_) => fn());
    _locks[convId] = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> fullSync() async {
    if (syncing || api == null) return;
    syncing = true;
    notifyListeners();
    try {
      final list = await api!.conversations();
      final seen = <String>{};
      for (final cv in list) {
        seen.add(cv.id);
        _upsert(cv);
      }
      for (final c in conversations.values) {
        if (!seen.contains(c.id)) c.removed = true;
      }
      notifyListeners();
      for (final cv in list) {
        await _withLock(cv.id, () => _backfill(cv.id));
      }
      _purgeExpired();
    } catch (e) {
      debugPrint('sync failed: $e');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> refreshConversation(String id) async {
    try {
      _upsert(await api!.conversation(id));
      await _withLock(id, () => _backfill(id));
    } catch (e) {
      debugPrint('refresh failed: $e');
    }
    notifyListeners();
  }

  Conversation _upsert(ConversationView cv) {
    for (final m in cv.members) {
      _observeKeys(m.id, m.username, b64decode(m.signPub), b64decode(m.encPub), isBot: m.isBot, displayName: m.displayName);
    }
    final conv = conversations.putIfAbsent(cv.id, () {
      final c = Conversation(id: cv.id, kind: cv.kind, role: cv.role, joinedSeq: cv.joinedSeq);
      c.syncedSeq = cv.joinedSeq;
      c.updatedAt = cv.createdAt * 1000;
      return c;
    });
    conv.kind = cv.kind;
    conv.role = cv.role;
    conv.joinedSeq = cv.joinedSeq;
    if (cv.lastSeq > conv.lastSeq) conv.lastSeq = cv.lastSeq;
    if (cv.readSeq > conv.readSeq) conv.readSeq = cv.readSeq;
    conv.serverMembers = [for (final m in cv.members) m.id];
    conv.retentionSeconds = cv.retentionSeconds;
    conv.removed = false;
    return conv;
  }

  void _observeKeys(String id, String username, Uint8List signPub, Uint8List encPub, {bool? isBot, String? displayName}) {
    final existing = contacts[id];
    if (existing == null) {
      contacts[id] = Contact(id: id, username: username, signPub: signPub, encPub: encPub, isBot: isBot ?? false, displayName: displayName ?? '');
      return;
    }
    if (!bytesEqual(existing.signPub, signPub) || !bytesEqual(existing.encPub, encPub)) {
      existing.keysChanged = true; // trust on first use: never silently accept new keys
      return;
    }
    existing.username = username;
    if (isBot != null) existing.isBot = isBot;
    if (displayName != null) existing.displayName = displayName;
  }

  Future<void> _backfill(String convId) async {
    final conv = conversations[convId];
    if (conv == null) return;
    var after = conv.syncedSeq > conv.joinedSeq ? conv.syncedSeq : conv.joinedSeq;
    while (true) {
      final page = await api!.messages(convId, after);
      for (final m in page.messages) {
        await handleIncoming(m, stored: true);
        if (m.seq > after) after = m.seq;
      }
      if (!page.hasMore) break;
    }
  }

  Future<void> _onLiveMessage(MessageView view) => _withLock(view.convId, () async {
        var conv = conversations[view.convId];
        if (conv == null || conv.removed) {
          try {
            _upsert(await api!.conversation(view.convId));
          } catch (_) {}
          conv = conversations[view.convId];
          if (conv == null) return;
        }
        final base = conv.syncedSeq > conv.joinedSeq ? conv.syncedSeq : conv.joinedSeq;
        if (view.seq > base + 1) await _backfill(view.convId);
        await handleIncoming(view, stored: true);
      });

  Future<void> _onEvent(Map<String, dynamic> ev) async {
    final convId = ev['conv_id'] as String?;
    if (convId == null) return;
    switch (ev['kind']) {
      case 'conv.updated':
      case 'member.added':
      case 'member.removed':
        await refreshConversation(convId);
      case 'conv.removed':
        conversations[convId]?.removed = true;
        notifyListeners();
      case 'read.updated':
        final seq = (ev['seq'] as num?)?.toInt() ?? 0;
        final c = conversations[convId];
        if (c != null && seq > c.readSeq) {
          c.readSeq = seq;
          notifyListeners();
        }
    }
  }

  /// Verifies, decrypts and applies one envelope.
  Future<void> handleIncoming(MessageView view, {required bool stored}) async {
    final s = session;
    final k = keys;
    if (s == null || k == null) return;
    if (stored && view.isDeletion) {
      _applyDeletion(view);
      return;
    }
    Map<String, dynamic>? payload;
    String? error;
    var ts = view.serverTs;
    try {
      var sender = contacts[view.senderAccount];
      if (sender == null) {
        try {
          _upsert(await api!.conversation(view.convId));
        } catch (_) {}
        sender = contacts[view.senderAccount];
      }
      if (sender == null) throw StateError('unknown sender');
      final env = b64decode(view.env);
      final sig = b64decode(view.sig);
      if (!await verifyEnvelope(sender.signPub, env, sig)) throw StateError('invalid signature');
      final parsed = parse(env);
      if (parsed.header.senderAccount != view.senderAccount || parsed.header.convId != view.convId) throw StateError('header mismatch');
      ts = parsed.header.timestampMs;
      payload = jsonDecode(utf8Decode(await decrypt(parsed, s.accountId, k.encPriv))) as Map<String, dynamic>;
      if (payload['t'] is! String) throw StateError('malformed payload');
    } catch (e) {
      error = e.toString();
    }
    if (!stored) {
      if (error != null) debugPrint('signal from ${view.senderAccount} dropped: $error');
      final type = payload?['t'] as String?;
      if (type != null && type.startsWith('call.')) calls.handleSignal(view.senderAccount, view.senderDevice, view.convId, payload!);
      if (type != null && type.startsWith('voice.')) voice.handleSignal(view.senderAccount, view.senderDevice, view.convId, payload!);
      return;
    }
    _applyStored(Message(convId: view.convId, seq: view.seq, clientMsgId: view.clientMsgId, sender: view.senderAccount, ts: ts, serverTs: view.serverTs, payload: payload, error: error));
  }

  void _applyStored(Message msg) {
    final conv = conversations[msg.convId];
    if (conv == null) return;
    final r = effectiveRetention(conv);
    if (r > 0 && msg.serverTs < DateTime.now().millisecondsSinceEpoch - r * 1000) return;
    if (msg.type == 'text.edit') {
      _applyEdit(conv, msg);
      _advanceSilently(conv, msg.seq);
      return;
    }
    final list = messages.putIfAbsent(msg.convId, () => []);
    list.removeWhere((m) => m.clientMsgId == msg.clientMsgId && (m.pending || m.seq == msg.seq));
    if (!list.any((m) => m.seq == msg.seq)) {
      list.add(msg);
      list.sort((a, b) => a.seq.compareTo(b.seq));
    }
    if (msg.seq > conv.syncedSeq) conv.syncedSeq = msg.seq;
    if (msg.seq > conv.lastSeq) conv.lastSeq = msg.seq;
    final p = msg.payload;
    if (p != null && msg.seq > conv.rosterSeq) {
      switch (p['t']) {
        case 'conv.create':
          if (p['name'] is String && (p['name'] as String).isNotEmpty) conv.name = p['name'] as String;
          conv.roster = _applyRoster(p['members']);
          conv.rosterSeq = msg.seq;
        case 'member.add':
        case 'member.remove':
          conv.roster = _applyRoster(p['members']);
          conv.rosterSeq = msg.seq;
        case 'conv.rename':
          conv.name = (p['name'] as String?) ?? conv.name;
      }
    }
    final preview = previewOf(msg);
    if (preview.isNotEmpty) {
      conv.preview = preview;
      conv.previewSeq = msg.seq;
      if (msg.serverTs > conv.updatedAt) conv.updatedAt = msg.serverTs;
    }
    if (msg.sender == session!.accountId && msg.seq > conv.readSeq) conv.readSeq = msg.seq;
    notifyListeners();
  }

  List<String> _applyRoster(dynamic members) {
    final ids = <String>[];
    if (members is! List) return ids;
    for (final m in members) {
      if (m is! Map<String, dynamic>) continue;
      try {
        final signPub = b64decode(m['sign_pub'] as String);
        final encPub = b64decode(m['enc_pub'] as String);
        if (signPub.length != 32 || encPub.length != 32) continue;
        _observeKeys(m['id'] as String, m['username'] as String, signPub, encPub);
        ids.add(m['id'] as String);
      } catch (_) {}
    }
    return ids;
  }

  /// Applies a `text.edit` (PROTOCOL.md §6.3): only the sender may rewrite
  /// its own earlier text message.
  void _applyEdit(Conversation conv, Message edit) {
    final ref = edit.payload!['ref'];
    final body = edit.payload!['body'];
    if (ref is! String || body is! String) return;
    for (final m in messages[conv.id] ?? const <Message>[]) {
      if (m.clientMsgId == ref && m.sender == edit.sender && m.type == 'text' && !m.pending && m.seq < edit.seq) {
        _setBody(conv, m, body, edited: true);
        return;
      }
    }
  }

  void _setBody(Conversation? conv, Message m, String body, {required bool edited}) {
    m.payload!['body'] = body;
    m.edited = edited;
    if (conv != null && conv.previewSeq == m.seq) conv.preview = body;
    notifyListeners();
  }

  /// Applies a deletion record: the message at deletedSeq is gone for everyone.
  void _applyDeletion(MessageView view) {
    final conv = conversations[view.convId];
    if (conv == null) return;
    _removeLocal(conv, view.deletedSeq!);
    _advanceSilently(conv, view.seq);
  }

  void _removeLocal(Conversation conv, int seq) {
    messages[conv.id]?.removeWhere((m) => m.seq == seq && !m.pending);
    if (conv.previewSeq == seq) _refreshPreview(conv);
    notifyListeners();
  }

  void _refreshPreview(Conversation conv) {
    conv.preview = '';
    conv.previewSeq = 0;
    for (final m in (messages[conv.id] ?? const <Message>[]).reversed) {
      if (m.pending) continue;
      final text = previewOf(m);
      if (text.isNotEmpty) {
        conv.preview = text;
        conv.previewSeq = m.seq;
        return;
      }
    }
  }

  /// Records a sequence entry with nothing new to read (an edit or a
  /// deletion): it never shows as unread.
  void _advanceSilently(Conversation conv, int seq) {
    if (seq > conv.syncedSeq) conv.syncedSeq = seq;
    if (seq > conv.lastSeq) conv.lastSeq = seq;
    if (conv.readSeq >= seq - 1 && conv.readSeq < seq) {
      conv.readSeq = seq;
      final client = api;
      if (client != null) unawaited(client.markRead(conv.id, seq).catchError((_) {}));
    }
    notifyListeners();
  }

  String previewOf(Message m) {
    final p = m.payload;
    if (p == null) return m.error != null ? t('undecryptable') : '';
    switch (p['t']) {
      case 'text':
        return (p['body'] as String?) ?? '';
      case 'file':
        return '📎 ${p['name'] ?? ''}';
      case 'conv.create':
        return p['kind'] == 'group' ? t('created_group', {'who': usernameOf(m.sender)}) : t('started_chat', {'who': usernameOf(m.sender)});
      case 'member.add':
        return t('added', {'who': usernameOf(m.sender), 'member': (p['member'] as Map<String, dynamic>?)?['username'] ?? ''});
      case 'member.remove':
        return t('left', {'who': usernameOf(m.sender)});
      case 'conv.rename':
        return t('renamed', {'who': usernameOf(m.sender)});
      case 'conv.retention':
        return t('retention_set', {'who': usernameOf(m.sender)});
      default:
        return '';
    }
  }

  int effectiveRetention(Conversation conv) {
    final global = (settings?.retentionDays ?? 0) * 86400;
    var r = conv.retentionSeconds;
    if (global > 0 && (r == 0 || r > global)) r = global;
    return r;
  }

  void _purgeExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final conv in conversations.values) {
      final r = effectiveRetention(conv);
      if (r <= 0) continue;
      final cutoff = now - r * 1000;
      final list = messages[conv.id];
      if (list != null && list.any((m) => !m.pending && m.serverTs < cutoff)) {
        list.removeWhere((m) => !m.pending && m.serverTs < cutoff);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // ---------- sending ----------

  List<String> sealingMembers(Conversation conv) {
    final server = conv.serverMembers.toSet();
    final ids = (conv.roster ?? conv.serverMembers).where(server.contains).toList();
    for (final id in conv.serverMembers) {
      if (!ids.contains(id) && (contacts[id]?.isBot ?? false)) ids.add(id);
    }
    if (!ids.contains(session!.accountId)) ids.add(session!.accountId);
    return ids;
  }

  /// Encrypts, signs and sends a payload. Stored messages show as pending
  /// bubbles until the server echoes them; [track] false skips that for
  /// payloads that change an existing message instead of adding one.
  Future<Map<String, dynamic>> sendPayload(String convId, Map<String, dynamic> payload, {int flags = 0, bool track = true}) async {
    final conv = conversations[convId];
    if (conv == null) throw StateError('unknown conversation');
    final recipients = <Recipient>[];
    for (final id in sealingMembers(conv)) {
      final c = contacts[id];
      if (c == null) throw StateError('no keys for member $id');
      if (c.keysChanged) throw StateError('${c.username}: keys changed');
      recipients.add(Recipient(account: id, encPub: c.encPub));
    }
    final clientMsgId = newUuid();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ephemeral = flags & flagEphemeral != 0;
    Message? pending;
    if (!ephemeral && track) {
      pending = Message(convId: convId, seq: 1 << 40, clientMsgId: clientMsgId, sender: session!.accountId, ts: ts, serverTs: ts, payload: payload, pending: true);
      messages.putIfAbsent(convId, () => []).add(pending);
      notifyListeners();
    }
    try {
      final out = await encrypt(
        keys!.signSeed,
        Header(flags: flags, convId: convId, senderAccount: session!.accountId, senderDevice: session!.deviceId, clientMsgId: clientMsgId, timestampMs: ts),
        recipients,
        utf8Encode(jsonEncode(payload)),
      );
      return await api!.send(convId, b64encode(out.env), b64encode(out.sig));
    } catch (e) {
      if (pending != null) {
        pending.failed = e.toString();
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> sendText(String convId, String body) => sendPayload(convId, {'t': 'text', 'body': body});

  void dismissPending(String convId, String clientMsgId) {
    messages[convId]?.removeWhere((m) => m.clientMsgId == clientMsgId && m.pending);
    notifyListeners();
  }

  /// Senders edit their own text messages.
  bool canEdit(Message m) => !m.pending && m.sender == session?.accountId && m.type == 'text';

  /// Senders delete their own messages; administrators delete anyone's.
  bool canDelete(Message m) => !m.pending && (m.sender == session?.accountId || (session?.isAdmin ?? false));

  /// Rewrites one of our own text messages: applied locally at once, then
  /// sent as a signed `text.edit` (PROTOCOL.md §6.3).
  Future<void> editText(String convId, Message original, String body) async {
    if (!canEdit(original)) throw StateError('only your own text messages can be edited');
    final conv = conversations[convId];
    final previous = original.payload!['body'];
    final wasEdited = original.edited;
    _setBody(conv, original, body, edited: true);
    try {
      await sendPayload(convId, {'t': 'text.edit', 'ref': original.clientMsgId, 'body': body}, track: false);
    } catch (_) {
      _setBody(conv, original, previous is String ? previous : '', edited: wasEdited);
      rethrow;
    }
  }

  /// Deletes a message for everyone: our own, or anyone's when we administer
  /// the server. The attachment goes with it.
  Future<void> deleteMessage(String convId, Message m) async {
    await api!.deleteMessage(convId, m.seq);
    final conv = conversations[convId];
    if (conv != null) _removeLocal(conv, m.seq);
    final blob = m.type == 'file' ? m.payload!['blob'] : null;
    if (blob is String && blob.isNotEmpty) unawaited(api!.deleteBlob(blob).catchError((_) {}));
  }

  Future<void> sendFile(String convId, String name, String mime, Uint8List data) async {
    final limit = settings?.maxAttachmentBytes ?? 50 * 1024 * 1024;
    if (limit <= 0 || data.length > limit) throw StateError(t('file_too_large'));
    final enc = await encryptFile(data);
    final blobId = await api!.uploadBlob(convId, enc.ciphertext);
    await sendPayload(convId, {
      't': 'file',
      'blob': blobId,
      'key': b64encode(enc.key),
      'nonce': b64encode(enc.nonce),
      'name': name,
      'mime': mime,
      'size': data.length,
    });
  }

  /// Downloads and decrypts an attachment (cached per blob id).
  Future<Uint8List> fetchFile(Map<String, dynamic> payload) {
    final blob = payload['blob'] as String;
    return _fileCache.putIfAbsent(blob, () async {
      try {
        final bytes = await api!.downloadBlob(blob);
        return await decryptFile(b64decode(payload['key'] as String), b64decode(payload['nonce'] as String), bytes);
      } catch (e) {
        _fileCache.remove(blob);
        rethrow;
      }
    });
  }

  Map<String, dynamic> _memberInfo(String id) {
    final c = contacts[id]!;
    return {'id': id, 'username': c.username, 'sign_pub': b64encode(c.signPub), 'enc_pub': b64encode(c.encPub)};
  }

  Future<String> _lookup(String username) async {
    final u = await api!.user(username.trim().replaceFirst(RegExp(r'^@'), ''));
    _observeKeys(u.id, u.username, b64decode(u.signPub), b64decode(u.encPub), isBot: u.isBot, displayName: u.displayName);
    return u.id;
  }

  Future<String> createDirect(String username) async {
    final id = await _lookup(username);
    if (id == session!.accountId) throw StateError(t('you'));
    final cv = await api!.createDirect(id);
    final conv = _upsert(cv);
    if (cv.lastSeq == 0) {
      await sendPayload(conv.id, {'t': 'conv.create', 'kind': 'direct', 'members': [_memberInfo(session!.accountId), _memberInfo(id)]});
    }
    notifyListeners();
    return conv.id;
  }

  Future<String> createGroup(String name, List<String> usernames) async {
    final ids = <String>[];
    for (final u in usernames) {
      final id = await _lookup(u);
      if (id != session!.accountId && !ids.contains(id)) ids.add(id);
    }
    final cv = await api!.createGroup(ids);
    final conv = _upsert(cv);
    await sendPayload(conv.id, {
      't': 'conv.create',
      'kind': 'group',
      'name': name.trim(),
      'members': [session!.accountId, ...ids].map(_memberInfo).toList(),
    });
    notifyListeners();
    return conv.id;
  }

  Future<void> addMember(String convId, String username) async {
    final id = await _lookup(username);
    final conv = _upsert(await api!.addMember(convId, id));
    final roster = {...(conv.roster ?? conv.serverMembers.where((m) => m != id)), session!.accountId, id};
    await sendPayload(convId, {'t': 'member.add', 'member': _memberInfo(id), 'members': roster.map(_memberInfo).toList()});
    notifyListeners();
  }

  Future<void> leave(String convId) async {
    final conv = conversations[convId];
    if (conv == null) return;
    final remaining = sealingMembers(conv).where((m) => m != session!.accountId).toList();
    try {
      await sendPayload(convId, {'t': 'member.remove', 'id': session!.accountId, 'members': remaining.map(_memberInfo).toList()});
    } catch (_) {}
    await api!.removeMember(convId, session!.accountId);
    conv.removed = true;
    notifyListeners();
  }

  Future<void> setRetention(String convId, int seconds) async {
    await api!.setRetention(convId, seconds);
    conversations[convId]?.retentionSeconds = seconds;
    notifyListeners();
    try {
      await sendPayload(convId, {'t': 'conv.retention', 'seconds': seconds});
    } catch (_) {}
  }

  Future<void> markRead(String convId) async {
    final conv = conversations[convId];
    if (conv == null || conv.lastSeq <= conv.readSeq) return;
    conv.readSeq = conv.lastSeq;
    notifyListeners();
    try {
      await api!.markRead(convId, conv.lastSeq);
    } catch (_) {}
  }

  // ---------- helpers ----------

  String usernameOf(String id) {
    if (id == session?.accountId) return t('you');
    return contacts[id]?.username ?? id.substring(0, 8);
  }

  String? otherMember(Conversation c) {
    final me = session?.accountId;
    for (final id in c.serverMembers) {
      if (id != me) return id;
    }
    return null;
  }

  String titleOf(Conversation c) {
    if (c.kind == 'direct') {
      final other = otherMember(c);
      final contact = other == null ? null : contacts[other];
      if (contact == null) return t('direct');
      return contact.isBot ? '🤖 ${contact.displayName.isNotEmpty ? contact.displayName : contact.username}' : contact.username;
    }
    return c.name.isNotEmpty ? c.name : t('group');
  }

  bool hasBot(Conversation c) => c.serverMembers.any((id) => contacts[id]?.isBot ?? false);
}
