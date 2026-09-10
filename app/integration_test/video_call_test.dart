// A real video call between this app and a browser peer. The browser side
// lives in web/tests/peer; scripts/app-video-call-test.ps1 starts a local
// server, the peer and this test together. Values come from --dart-define.
import 'dart:async';

import 'package:family_messenger_e2e/i18n/strings.dart';
import 'package:family_messenger_e2e/main.dart' as m;
import 'package:family_messenger_e2e/state/app_state.dart';
import 'package:family_messenger_e2e/state/call_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const server = String.fromEnvironment('TEST_SERVER', defaultValue: 'http://127.0.0.1:18082');
const me = String.fromEnvironment('TEST_USER', defaultValue: 'appalice');
const peer = String.fromEnvironment('TEST_PEER', defaultValue: 'appbob');

Future<void> waitFor(WidgetTester tester, bool Function() condition, String what, {Duration timeout = const Duration(seconds: 120)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video call with a browser peer', (tester) async {
    L10n.set('en');
    m.app = AppState(persist: false);
    await m.app.init();
    await tester.pumpWidget(const m.FamilyMessengerApp());
    await tester.pump();

    // Sign up (the test server runs with open registration).
    await m.app.register(server, me, '$me-password-123', '');
    await waitFor(tester, () => m.app.signedIn, 'sign-in');

    // The peer registers on its own; retry until it exists.
    String? convId;
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (convId == null) {
      try {
        convId = await m.app.createDirect(peer);
      } catch (e) {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    await waitFor(tester, () => m.app.conversations.containsKey(convId), 'conversation');
    await tester.pumpAndSettle();

    // Open the chat from the list and start a video call from the app bar.
    await tester.tap(find.text(peer).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Video call'));
    await tester.pump();

    final calls = m.app.calls;
    String state() =>
        'status=${calls.call?.status} video=${calls.call?.video} remoteVideo=${calls.call?.remoteVideo} '
        'local=${calls.localCamera.videoWidth}x${calls.localCamera.videoHeight} remote=${calls.remoteCamera.videoWidth}x${calls.remoteCamera.videoHeight} '
        'remoteStream=${calls.remoteCamera.srcObject != null} remoteStreams=${calls.debugRemoteStreams}';
    try {
      await waitFor(tester, () => calls.call?.status == CallStatus.active, 'the peer to answer', timeout: const Duration(seconds: 180));
      expect(calls.call!.video, isTrue, reason: 'our camera must be on in a video call');
      // The screen must follow the state: a call overlay that stayed on
      // "Calling…" for the whole call once passed the state checks above.
      await tester.pump();
      expect(find.textContaining(t('in_call')), findsOneWidget, reason: 'the call screen must show the active call');
      expect(find.text(t('camera_off')), findsOneWidget, reason: 'the camera button must reflect the camera being on');
      expect(find.textContaining(t('calling')), findsNothing, reason: 'the ringing status must be gone');
      await waitFor(tester, () => calls.localCamera.videoWidth > 0, 'frames from our camera');
      await waitFor(tester, () => (calls.call?.remoteVideo ?? false) && calls.remoteCamera.videoWidth > 0, 'frames from the peer camera');
    } catch (e) {
      // ignore: avoid_print
      print('CALL STATE ${state()}');
      rethrow;
    }
    // ignore: avoid_print
    print('VIDEO OK ${state()}');

    // Both directions verified: hold the call so the peer can run its own
    // checks, then end it; the peer waits for that.
    await Future<void>.delayed(const Duration(seconds: 6));
    calls.hangup();
    await waitFor(tester, () => calls.call == null || calls.call!.status == CallStatus.ended, 'the call to end');
    // Let the hang-up signal leave before the token is revoked.
    await Future<void>.delayed(const Duration(seconds: 2));
    await m.app.logout();
  });
}
