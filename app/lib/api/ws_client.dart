import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

/// One WebSocket frame: {"t": type, "d": data}.
class Frame {
  const Frame(this.type, this.data);

  final String type;
  final dynamic data;
}

enum WsStatus { offline, connecting, online }

/// WebSocket client with first-frame authentication, reconnects and an
/// application-level keepalive. Outgoing messages travel over HTTP, so the
/// socket is the only place where a dead connection shows: mobile networks
/// drop it without a close frame, and a silently dead socket would keep the
/// app deaf to incoming messages and call signals while it can still send.
class WsClient {
  WsClient({
    required this.baseUrl,
    required this.token,
    this.pingAfter = const Duration(seconds: 15),
    this.deadAfter = const Duration(seconds: 35),
    this.pokeDeadline = const Duration(seconds: 5),
    this.checkEvery = const Duration(seconds: 5),
  });

  final String baseUrl;
  final String token;

  /// A ping goes out after this much silence; the server answers with a pong.
  final Duration pingAfter;

  /// A socket silent for this long is dead and gets reopened.
  final Duration deadAfter;

  /// After [poke] (the app came back to the foreground) a pong must arrive this fast.
  final Duration pokeDeadline;

  /// How often the liveness check runs.
  final Duration checkEvery;

  final StreamController<Frame> _frames = StreamController.broadcast();
  final StreamController<WsStatus> _status = StreamController.broadcast();
  WebSocketChannel? _channel;
  bool _stopped = true;
  int _attempt = 0;
  Timer? _timer;
  Timer? _keepalive;
  DateTime _lastFrame = DateTime.now();
  DateTime? _pingSent;
  WsStatus status = WsStatus.offline;

  Stream<Frame> get frames => _frames.stream;
  Stream<WsStatus> get statusChanges => _status.stream;

  void connect() {
    _stopped = false;
    _attempt = 0;
    _open();
  }

  void close() {
    _stopped = true;
    _timer?.cancel();
    _keepalive?.cancel();
    final ch = _channel;
    _channel = null;
    ch?.sink.close();
    _setStatus(WsStatus.offline);
  }

  void send(String type, Object? data) {
    _channel?.sink.add(jsonEncode({'t': type, 'd': data}));
  }

  /// Checks the connection right away: reconnects a socket that is waiting
  /// out its backoff and pings an open one, expecting the pong within
  /// [pokeDeadline]. Called when the app returns to the foreground.
  void poke() {
    if (_stopped) return;
    if (_channel == null) {
      _timer?.cancel();
      _attempt = 0;
      _open();
      return;
    }
    final sentAt = DateTime.now();
    _pingSent = sentAt;
    send('ping', null);
    Timer(pokeDeadline, () {
      if (_channel != null && !_lastFrame.isAfter(sentAt)) _reopen();
    });
  }

  void _setStatus(WsStatus s) {
    status = s;
    _status.add(s);
  }

  void _open() {
    if (_stopped) return;
    _setStatus(WsStatus.connecting);
    final wsBase = baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final channel = WebSocketChannel.connect(Uri.parse('$wsBase/api/v1/ws'));
    _channel = channel;
    _lastFrame = DateTime.now();
    _pingSent = null;
    _keepalive?.cancel();
    _keepalive = Timer.periodic(checkEvery, (_) => _checkLiveness());
    // The connection is opened lazily, and a failure to open it is delivered
    // three times: on `ready`, on the sink's `done`, and on the stream. Only
    // the stream was being listened to, so every attempt against an
    // unreachable server also logged an unhandled exception, once per retry
    // for as long as the app stayed offline. The reconnect is driven from
    // the stream below; these two only need to be seen, not acted on.
    unawaited(channel.ready.catchError((Object _) {}));
    unawaited(channel.sink.done.catchError((Object _) {}));
    channel.sink.add(jsonEncode({
      't': 'auth',
      'd': {'token': token},
    }));
    channel.stream.listen(
      (raw) {
        _lastFrame = DateTime.now();
        Map<String, dynamic> j;
        try {
          j = jsonDecode(raw as String) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        final type = j['t'] as String? ?? '';
        if (type == 'hello') {
          _attempt = 0;
          _setStatus(WsStatus.online);
        }
        _frames.add(Frame(type, j['d']));
      },
      onDone: () => _onClosed(channel),
      onError: (_) => _onClosed(channel),
      cancelOnError: true,
    );
  }

  /// Pings a quiet socket and drops one that stopped answering. Also acts
  /// as a connect timeout: a socket that never says hello is reopened.
  void _checkLiveness() {
    if (_channel == null) return;
    final now = DateTime.now();
    final silence = now.difference(_lastFrame);
    if (silence > deadAfter) {
      _reopen();
      return;
    }
    if (silence >= pingAfter && (_pingSent == null || now.difference(_pingSent!) >= pingAfter)) {
      _pingSent = now;
      send('ping', null);
    }
  }

  /// Replaces a dead socket with a fresh connection at once (no backoff).
  void _reopen() {
    final ch = _channel;
    _channel = null;
    _keepalive?.cancel();
    ch?.sink.close();
    if (_stopped) return;
    _timer?.cancel();
    _attempt = 0;
    _open();
  }

  void _onClosed(WebSocketChannel channel) {
    if (_channel != channel) return; // already replaced by _reopen or closed
    _channel = null;
    _keepalive?.cancel();
    _setStatus(WsStatus.offline);
    if (_stopped) return;
    // 1008 (policy violation) is how the server refuses a token: the device was
    // signed out elsewhere (a password change, "sign out" from another device,
    // an administrator). The app checks with /me and signs itself out instead
    // of reconnecting forever.
    if (channel.closeCode == 1008) _frames.add(Frame('revoked', channel.closeReason));
    final delay = min(30000, 1000 * (1 << _attempt)) * (0.7 + Random().nextDouble() * 0.6);
    _attempt = min(_attempt + 1, 6);
    _timer = Timer(Duration(milliseconds: delay.toInt()), _open);
  }
}
