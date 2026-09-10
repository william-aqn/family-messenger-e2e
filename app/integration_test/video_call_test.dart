// A real video call between this app and a browser peer, driven the way a
// person would use the app: the call screen and its buttons are checked, not
// only the controller state. The browser side lives in web/tests/peer;
// scripts/app-video-call-test.ps1 starts a local server, the peer and this
// test together. Values come from --dart-define.
//
// The flow: sign up, open the chat, video call the peer (frames both ways),
// share the screen and stop, hang up, call again in the same process, then
// answer a call from the peer with the button and let the peer hang up.
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
  await tester.pump();
}

// ignore: avoid_print
void say(String line) => print(line);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Render like the real app (the window is watched from outside).
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('video calls with a browser peer', (tester) async {
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

    // Open the chat from the list.
    await tester.tap(find.text(peer).first);
    await tester.pumpAndSettle();

    final calls = m.app.calls;
    String state() =>
        'status=${calls.call?.status} video=${calls.call?.video} remoteVideo=${calls.call?.remoteVideo} sharing=${calls.call?.sharing} '
        'local=${calls.localCamera.videoWidth}x${calls.localCamera.videoHeight} remote=${calls.remoteCamera.videoWidth}x${calls.remoteCamera.videoHeight} '
        'remoteStream=${calls.remoteCamera.srcObject != null} remoteStreams=${calls.debugRemoteStreams}';

    Future<void> expectActiveCallScreen() async {
      // The screen must follow the state: a call overlay that stayed on
      // "Calling…" for the whole call once passed the state checks.
      await tester.pump();
      expect(find.textContaining(t('in_call')), findsOneWidget, reason: 'the call screen must show the active call');
      expect(find.text(t('camera_off')), findsOneWidget, reason: 'the camera button must reflect the camera being on');
      expect(find.textContaining(t('calling')), findsNothing, reason: 'the ringing status must be gone');
    }

    Future<void> expectFramesBothWays() async {
      await waitFor(tester, () => calls.localCamera.videoWidth > 0, 'frames from our camera');
      await waitFor(tester, () => (calls.call?.remoteVideo ?? false) && calls.remoteCamera.videoWidth > 0, 'frames from the peer camera');
    }

    Future<void> hangUpAndWaitForTheOverlay() async {
      calls.hangup();
      await waitFor(tester, () => calls.call?.status == CallStatus.ended, 'the call to end', timeout: const Duration(seconds: 20));
      expect(find.textContaining(t('call_ended')), findsOneWidget, reason: 'the end of the call must be shown');
      await waitFor(tester, () => calls.call == null, 'the call overlay to go away', timeout: const Duration(seconds: 20));
      expect(find.textContaining(t('in_call')), findsNothing, reason: 'the overlay must be gone after the call');
      expect(find.byTooltip(t('video_call')), findsOneWidget, reason: 'the chat screen must be back');
    }

    try {
      // Call 1: we call, the peer answers.
      await tester.tap(find.byTooltip(t('video_call')));
      await tester.pump();
      await waitFor(tester, () => calls.call?.status == CallStatus.active, 'the peer to answer', timeout: const Duration(seconds: 180));
      expect(calls.call!.video, isTrue, reason: 'our camera must be on in a video call');
      await expectActiveCallScreen();
      await expectFramesBothWays();
      say('VIDEO OK ${state()}');

      // Screen sharing: the peer sees the screen beside the camera, then only the camera again.
      await tester.tap(find.text(t('share_screen')));
      await waitFor(tester, () => calls.call?.sharing == true, 'sharing to start', timeout: const Duration(seconds: 30));
      expect(find.text(t('stop_sharing')), findsOneWidget, reason: 'the share button must flip');
      say('SHARE ON');
      await Future<void>.delayed(const Duration(seconds: 8));
      await tester.tap(find.text(t('stop_sharing')));
      await waitFor(tester, () => calls.call?.sharing == false, 'sharing to stop', timeout: const Duration(seconds: 20));
      expect(find.text(t('share_screen')), findsOneWidget, reason: 'the share button must flip back');
      say('SHARE OFF');
      await Future<void>.delayed(const Duration(seconds: 4));
      await hangUpAndWaitForTheOverlay();
      say('CALL 1 ENDED');

      // Call 2: another outgoing call in the same process (this once aborted the app).
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.tap(find.byTooltip(t('video_call')));
      await tester.pump();
      await waitFor(tester, () => calls.call?.status == CallStatus.active, 'the peer to answer the second call', timeout: const Duration(seconds: 120));
      await expectActiveCallScreen();
      await expectFramesBothWays();
      say('CALL 2 OK ${state()}');
      await Future<void>.delayed(const Duration(seconds: 4));
      await hangUpAndWaitForTheOverlay();
      say('CALL 2 ENDED');

      // Call 3: the peer calls, we answer with the button, the peer hangs up.
      await waitFor(tester, () => calls.call?.status == CallStatus.ringingIn, 'the peer to call us', timeout: const Duration(seconds: 120));
      expect(find.textContaining(t('incoming_video_call')), findsOneWidget, reason: 'the incoming call must be announced');
      await tester.tap(find.text(t('answer')));
      await waitFor(tester, () => calls.call?.status == CallStatus.active, 'the incoming call to connect', timeout: const Duration(seconds: 60));
      await expectActiveCallScreen();
      await expectFramesBothWays();
      say('CALL 3 OK (incoming) ${state()}');
      await waitFor(tester, () => calls.call == null || calls.call!.status == CallStatus.ended, 'the peer to hang up', timeout: const Duration(seconds: 90));
      expect(find.textContaining(t('call_ended')), findsOneWidget, reason: 'the end of the call must be shown');
      say('CALL 3 ENDED BY THE PEER');
      await waitFor(tester, () => calls.call == null, 'the ended overlay to go away', timeout: const Duration(seconds: 20));
    } catch (e) {
      say('CALL STATE ${state()}');
      rethrow;
    }

    // Let the last signals leave before the token is revoked.
    await Future<void>.delayed(const Duration(seconds: 2));
    await m.app.logout();
  });
}
