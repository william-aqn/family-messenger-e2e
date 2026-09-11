import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

/// JSON client for the server API (see protocol/PROTOCOL.md §8).
class ApiClient {
  ApiClient(this.baseUrl, {this.token});

  /// Origin of the server, e.g. https://chat.example.com (no trailing slash).
  final String baseUrl;
  String? token;
  final http.Client _http = http.Client();

  Uri _uri(String path) => Uri.parse('$baseUrl/api/v1$path');

  Map<String, String> _headers({bool json = false, String? contentType}) => {
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
        'Content-Type': ?contentType,
        'Authorization': ?token == null ? null : 'Bearer $token',
      };

  Never _throw(http.Response res) {
    String code = 'error';
    String message = 'HTTP ${res.statusCode}';
    try {
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final err = j['error'] as Map<String, dynamic>?;
      if (err != null) {
        code = (err['code'] as String?) ?? code;
        message = (err['message'] as String?) ?? message;
      }
    } catch (_) {
      // non-JSON error body
    }
    throw ApiException(res.statusCode, code, message);
  }

  Future<dynamic> _json(String method, String path, {Object? body}) async {
    late http.Response res;
    final headers = _headers(json: body != null);
    final encoded = body == null ? null : jsonEncode(body);
    try {
      switch (method) {
        case 'GET':
          res = await _http.get(_uri(path), headers: headers);
        case 'POST':
          res = await _http.post(_uri(path), headers: headers, body: encoded);
        case 'PUT':
          res = await _http.put(_uri(path), headers: headers, body: encoded);
        case 'PATCH':
          res = await _http.patch(_uri(path), headers: headers, body: encoded);
        case 'DELETE':
          res = await _http.delete(_uri(path), headers: headers, body: encoded);
        default:
          throw ArgumentError(method);
      }
    } on http.ClientException catch (e) {
      throw ApiException(0, 'network', 'Cannot reach the server: ${e.message}');
    }
    if (res.statusCode >= 300) _throw(res);
    if (res.statusCode == 204 || res.body.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<Map<String, dynamic>> info() async => (await _json('GET', '/info')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> authParams(String username) async =>
      (await _json('GET', '/auth/params?username=${Uri.encodeQueryComponent(username)}')) as Map<String, dynamic>;

  Future<Session> register(Map<String, dynamic> body) async => Session.fromJson((await _json('POST', '/auth/register', body: body)) as Map<String, dynamic>);

  Future<Session> login(Map<String, dynamic> body) async => Session.fromJson((await _json('POST', '/auth/login', body: body)) as Map<String, dynamic>);

  Future<void> logout() => _json('POST', '/auth/logout');

  /// Asks for the random bytes this device must sign to change the password
  /// (PROTOCOL.md §3.2). Returns the challenge, base64.
  Future<String> passwordChallenge() async =>
      ((await _json('POST', '/auth/password/challenge')) as Map<String, dynamic>)['challenge'] as String;

  /// Changes the password (PROTOCOL.md §3.2); returns how many other devices
  /// the server signed out.
  Future<int> changePassword(Map<String, dynamic> body) async {
    final res = await _json('POST', '/auth/password', body: body);
    return ((res as Map<String, dynamic>?)?['signed_out_devices'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, dynamic>> me() async => (await _json('GET', '/me')) as Map<String, dynamic>;

  Future<UserView> user(String username) async => UserView.fromJson((await _json('GET', '/users/${Uri.encodeComponent(username)}')) as Map<String, dynamic>);

  /// Active accounts whose username starts with [prefix]; 403 when the
  /// administrator disabled the directory.
  Future<List<DirectoryEntry>> users(String prefix) async {
    final res = (await _json('GET', '/users?q=${Uri.encodeQueryComponent(prefix)}&limit=200')) as Map<String, dynamic>;
    return ((res['users'] as List<dynamic>?) ?? []).cast<Map<String, dynamic>>().map(DirectoryEntry.fromJson).toList();
  }

  Future<List<ConversationView>> conversations() async {
    final j = (await _json('GET', '/conversations')) as Map<String, dynamic>;
    return [for (final c in j['conversations'] as List<dynamic>) ConversationView.fromJson(c as Map<String, dynamic>)];
  }

  Future<ConversationView> conversation(String id) async => ConversationView.fromJson((await _json('GET', '/conversations/$id')) as Map<String, dynamic>);

  Future<ConversationView> createDirect(String accountId) async =>
      ConversationView.fromJson((await _json('POST', '/conversations', body: {'kind': 'direct', 'account_id': accountId})) as Map<String, dynamic>);

  Future<ConversationView> createGroup(List<String> memberIds) async =>
      ConversationView.fromJson((await _json('POST', '/conversations', body: {'kind': 'group', 'member_ids': memberIds})) as Map<String, dynamic>);

  Future<ConversationView> addMember(String convId, String accountId) async =>
      ConversationView.fromJson((await _json('POST', '/conversations/$convId/members', body: {'account_id': accountId})) as Map<String, dynamic>);

  Future<void> removeMember(String convId, String accountId) => _json('DELETE', '/conversations/$convId/members/$accountId');

  Future<({List<MessageView> messages, bool hasMore})> messages(String convId, int after, {int limit = 200}) async {
    final j = (await _json('GET', '/conversations/$convId/messages?after=$after&limit=$limit')) as Map<String, dynamic>;
    return (
      messages: [for (final m in j['messages'] as List<dynamic>) MessageView.fromJson(m as Map<String, dynamic>)],
      hasMore: j['has_more'] == true,
    );
  }

  Future<Map<String, dynamic>> send(String convId, String env, String sig) async =>
      (await _json('POST', '/conversations/$convId/messages', body: {'env': env, 'sig': sig})) as Map<String, dynamic>;

  Future<void> deleteMessage(String convId, int seq) => _json('DELETE', '/conversations/$convId/messages/$seq');

  Future<void> markRead(String convId, int seq) => _json('PUT', '/conversations/$convId/read', body: {'seq': seq});

  Future<void> setRetention(String convId, int seconds) => _json('PUT', '/conversations/$convId/retention', body: {'seconds': seconds});

  Future<List<IceServer>> turn() async {
    final j = (await _json('GET', '/turn')) as Map<String, dynamic>;
    return [for (final s in j['ice_servers'] as List<dynamic>) IceServer.fromJson(s as Map<String, dynamic>)];
  }

  Future<String> uploadBlob(String convId, Uint8List data) async {
    final res = await _http.post(_uri('/conversations/$convId/blobs'), headers: _headers(contentType: 'application/octet-stream'), body: data);
    if (res.statusCode >= 300) _throw(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['id'] as String;
  }

  Future<Uint8List> downloadBlob(String id) async {
    final res = await _http.get(_uri('/blobs/$id'), headers: _headers());
    if (res.statusCode >= 300) _throw(res);
    return res.bodyBytes;
  }

  Future<void> deleteBlob(String id) => _json('DELETE', '/blobs/$id');

  Future<List<Map<String, dynamic>>> devices() async {
    final j = (await _json('GET', '/devices')) as Map<String, dynamic>;
    return (j['devices'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<void> deleteDevice(String id) => _json('DELETE', '/devices/$id');

  // ───── administrator ─────────────────────────────────────────────────────

  /// Every invite code with its note, expiry and use, newest last. Rows carry
  /// `code`, `note`, `created_at`, and `used_by` / `used_at` / `expires_at`
  /// only when they are set (see internal/api/handlers_admin.go). 403 for an
  /// account that is not an administrator.
  Future<List<Map<String, dynamic>>> adminInvites() async {
    final j = (await _json('GET', '/admin/invites')) as Map<String, dynamic>;
    return ((j['invites'] as List<dynamic>?) ?? const <dynamic>[]).cast<Map<String, dynamic>>();
  }

  /// Creates [count] invite codes and returns them. [expiresHours] 0 makes
  /// them last until they are used.
  Future<List<String>> adminCreateInvites({int count = 1, String note = '', int expiresHours = 0}) async {
    final j = (await _json('POST', '/admin/invites', body: <String, dynamic>{
      'count': count,
      'note': note,
      'expires_hours': expiresHours,
    })) as Map<String, dynamic>;
    return ((j['codes'] as List<dynamic>?) ?? const <dynamic>[]).cast<String>();
  }
}
