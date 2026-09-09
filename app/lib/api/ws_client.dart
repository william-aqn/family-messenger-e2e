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

/// WebSocket client with first-frame authentication and reconnects.
class WsClient {
  WsClient({required this.baseUrl, required this.token});

  final String baseUrl;
  final String token;

  final StreamController<Frame> _frames = StreamController.broadcast();
  final StreamController<WsStatus> _status = StreamController.broadcast();
  WebSocketChannel? _channel;
  bool _stopped = true;
  int _attempt = 0;
  Timer? _timer;
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
    _channel?.sink.close();
    _channel = null;
    _setStatus(WsStatus.offline);
  }

  void send(String type, Object? data) {
    _channel?.sink.add(jsonEncode({'t': type, 'd': data}));
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
    channel.sink.add(jsonEncode({
      't': 'auth',
      'd': {'token': token},
    }));
    channel.stream.listen(
      (raw) {
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
      onDone: _onClosed,
      onError: (_) => _onClosed(),
      cancelOnError: true,
    );
  }

  void _onClosed() {
    _channel = null;
    _setStatus(WsStatus.offline);
    if (_stopped) return;
    final delay = min(30000, 1000 * (1 << _attempt)) * (0.7 + Random().nextDouble() * 0.6);
    _attempt = min(_attempt + 1, 6);
    _timer = Timer(Duration(milliseconds: delay.toInt()), _open);
  }
}
