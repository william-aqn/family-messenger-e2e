// Wire models of the server's JSON API.

class Session {
  const Session({
    required this.accountId,
    required this.username,
    required this.deviceId,
    required this.token,
    required this.signPub,
    required this.encPub,
    required this.keyBundle,
    required this.salt,
    required this.isAdmin,
  });

  factory Session.fromJson(Map<String, dynamic> j) => Session(
        accountId: j['account_id'] as String,
        username: j['username'] as String,
        deviceId: j['device_id'] as String,
        token: j['token'] as String,
        signPub: j['sign_pub'] as String,
        encPub: j['enc_pub'] as String,
        keyBundle: j['key_bundle'] as String,
        salt: j['salt'] as String,
        isAdmin: j['is_admin'] == true,
      );

  final String accountId;
  final String username;
  final String deviceId;
  final String token;
  final String signPub;
  final String encPub;
  final String keyBundle;
  final String salt;
  final bool isAdmin;
}

class MemberView {
  const MemberView({required this.id, required this.username, required this.role, required this.signPub, required this.encPub, required this.isBot, required this.displayName});

  factory MemberView.fromJson(Map<String, dynamic> j) => MemberView(
        id: j['id'] as String,
        username: j['username'] as String,
        role: j['role'] as String,
        signPub: j['sign_pub'] as String,
        encPub: j['enc_pub'] as String,
        isBot: j['is_bot'] == true,
        displayName: (j['display_name'] as String?) ?? '',
      );

  final String id;
  final String username;
  final String role;
  final String signPub;
  final String encPub;
  final bool isBot;
  final String displayName;
}

class ConversationView {
  const ConversationView({
    required this.id,
    required this.kind,
    required this.createdBy,
    required this.createdAt,
    required this.lastSeq,
    required this.readSeq,
    required this.joinedSeq,
    required this.role,
    required this.retentionSeconds,
    required this.members,
  });

  factory ConversationView.fromJson(Map<String, dynamic> j) => ConversationView(
        id: j['id'] as String,
        kind: j['kind'] as String,
        createdBy: j['created_by'] as String,
        createdAt: (j['created_at'] as num).toInt(),
        lastSeq: (j['last_seq'] as num).toInt(),
        readSeq: (j['read_seq'] as num).toInt(),
        joinedSeq: (j['joined_seq'] as num).toInt(),
        role: j['role'] as String,
        retentionSeconds: ((j['retention_seconds'] as num?) ?? 0).toInt(),
        members: [for (final m in j['members'] as List<dynamic>) MemberView.fromJson(m as Map<String, dynamic>)],
      );

  final String id;
  final String kind;
  final String createdBy;
  final int createdAt;
  final int lastSeq;
  final int readSeq;
  final int joinedSeq;
  final String role;
  final int retentionSeconds;
  final List<MemberView> members;
}

class MessageView {
  const MessageView({
    required this.convId,
    required this.seq,
    required this.senderAccount,
    required this.senderDevice,
    required this.clientMsgId,
    required this.env,
    required this.sig,
    required this.serverTs,
    this.deletedSeq,
    this.deletedSender,
  });

  factory MessageView.fromJson(Map<String, dynamic> j) => MessageView(
        convId: j['conv_id'] as String,
        seq: ((j['seq'] as num?) ?? 0).toInt(),
        senderAccount: j['sender_account'] as String,
        senderDevice: j['sender_device'] as String,
        clientMsgId: j['client_msg_id'] as String,
        env: (j['env'] as String?) ?? '',
        sig: (j['sig'] as String?) ?? '',
        serverTs: ((j['server_ts'] as num?) ?? 0).toInt(),
        deletedSeq: (j['deleted_seq'] as num?)?.toInt(),
        deletedSender: j['deleted_sender'] as String?,
      );

  final String convId;
  final int seq;
  final String senderAccount;
  final String senderDevice;
  final String clientMsgId;
  final String env;
  final String sig;
  final int serverTs;

  /// Set on a deletion record (PROTOCOL.md §6.3): the message at that
  /// sequence number was removed by [senderAccount].
  final int? deletedSeq;
  final String? deletedSender;

  bool get isDeletion => (deletedSeq ?? 0) > 0;
}

class UserView {
  const UserView({required this.id, required this.username, required this.signPub, required this.encPub, required this.isBot, required this.displayName});

  factory UserView.fromJson(Map<String, dynamic> j) => UserView(
        id: j['id'] as String,
        username: j['username'] as String,
        signPub: j['sign_pub'] as String,
        encPub: j['enc_pub'] as String,
        isBot: j['is_bot'] == true,
        displayName: (j['display_name'] as String?) ?? '',
      );

  final String id;
  final String username;
  final String signPub;
  final String encPub;
  final bool isBot;
  final String displayName;
}

/// An entry of the user directory (GET /users), when the administrator allows it.
class DirectoryEntry {
  const DirectoryEntry({required this.id, required this.username, required this.displayName, required this.isBot});

  factory DirectoryEntry.fromJson(Map<String, dynamic> j) => DirectoryEntry(
        id: j['id'] as String,
        username: j['username'] as String,
        displayName: (j['display_name'] as String?) ?? '',
        isBot: j['is_bot'] == true,
      );

  final String id;
  final String username;
  final String displayName;
  final bool isBot;
}

class ServerSettings {
  const ServerSettings({
    required this.registration,
    required this.announcement,
    required this.allowBots,
    required this.maxAttachmentBytes,
    required this.retentionDays,
    required this.userDirectory,
  });

  factory ServerSettings.fromJson(Map<String, dynamic> j) => ServerSettings(
        registration: (j['registration'] as String?) ?? 'invite',
        announcement: (j['announcement'] as String?) ?? '',
        allowBots: j['allow_bots'] == true,
        maxAttachmentBytes: ((j['max_attachment_bytes'] as num?) ?? 50 * 1024 * 1024).toInt(),
        retentionDays: ((j['retention_days'] as num?) ?? 0).toInt(),
        userDirectory: j['user_directory'] != false,
      );

  final String registration;
  final String announcement;
  final bool allowBots;
  final int maxAttachmentBytes;
  final int retentionDays;
  /// Members may list users and get name suggestions (default on).
  final bool userDirectory;
}

class IceServer {
  const IceServer({required this.urls, this.username, this.credential});

  factory IceServer.fromJson(Map<String, dynamic> j) => IceServer(
        urls: [for (final u in j['urls'] as List<dynamic>) u as String],
        username: j['username'] as String?,
        credential: j['credential'] as String?,
      );

  final List<String> urls;
  final String? username;
  final String? credential;

  Map<String, dynamic> toRtc() => {
        'urls': urls,
        if (username != null) 'username': username,
        if (credential != null) 'credential': credential,
      };
}

class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => message;
}
