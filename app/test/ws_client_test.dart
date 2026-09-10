// The WebSocket client must notice a connection that died without a close
// frame (mobile networks do that): it pings a quiet socket and reopens one
// that stops answering. A fake server here answers pings only while told to.
import 'dart:convert';
import 'dart:io';

import 'package:family_messenger_e2e/api/ws_client.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitUntil(bool Function() condition, String what, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late HttpServer server;
  var answerPings = true;
  var connections = 0;
  var pings = 0;

  setUp(() async {
    answerPings = true;
    connections = 0;
    pings = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      connections++;
      ws.listen((data) {
        final j = jsonDecode(data as String) as Map<String, dynamic>;
        switch (j['t']) {
          case 'auth':
            ws.add(jsonEncode({'t': 'hello', 'd': {'version': 'test'}}));
          case 'ping':
            pings++;
            if (answerPings) ws.add(jsonEncode({'t': 'pong', 'd': {}}));
        }
      });
    });
  });

  tearDown(() => server.close(force: true));

  WsClient newClient() => WsClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'token',
        pingAfter: const Duration(milliseconds: 200),
        deadAfter: const Duration(milliseconds: 600),
        pokeDeadline: const Duration(milliseconds: 150),
        checkEvery: const Duration(milliseconds: 50),
      );

  test('a quiet socket is pinged and stays connected while pongs come back', () async {
    final client = newClient();
    client.connect();
    await waitUntil(() => client.status == WsStatus.online, 'the first connection');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(pings, greaterThanOrEqualTo(2), reason: 'pings must go out during silence');
    expect(connections, 1, reason: 'an answering socket must not be reopened');
    expect(client.status, WsStatus.online);
    client.close();
  });

  test('a socket that stops answering is replaced without waiting for a close frame', () async {
    final client = newClient();
    client.connect();
    await waitUntil(() => client.status == WsStatus.online, 'the first connection');
    answerPings = false;
    await waitUntil(() => connections == 2, 'a reconnect after the pongs stopped', timeout: const Duration(seconds: 5));
    answerPings = true;
    await waitUntil(() => client.status == WsStatus.online, 'the new connection to say hello');
    expect(connections, 2);
    client.close();
  });

  test('poke() reconnects right away when the pong does not arrive in time', () async {
    final client = newClient();
    client.connect();
    await waitUntil(() => client.status == WsStatus.online, 'the first connection');
    answerPings = false;
    final before = DateTime.now();
    client.poke();
    await waitUntil(() => connections == 2, 'a reconnect after the poke', timeout: const Duration(seconds: 2));
    expect(DateTime.now().difference(before), lessThan(const Duration(milliseconds: 500)), reason: 'the poke deadline is short');
    client.close();
  });
}
