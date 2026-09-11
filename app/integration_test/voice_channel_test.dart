// A real group voice channel between this app, the same app on another
// platform and a browser peer — everybody with a camera and a shared screen at
// the same time, which is what the channel's two video slots per pair are for.
//
// The browser side lives in web/tests/peer/app-voice-peer.spec.ts;
// scripts/app-voice-channel-test.ps1 starts the server, the peer, the Android
// app and the Windows app together. Values come from --dart-define.
//
// The flow, driven through the UI the way a person would: sign up, open the
// group, join the channel from the chat, switch the camera on and share the
// screen from the panel, open "Video and screens" and check that both the
// camera and the screen of everybody else are carrying frames there.
//
// Roles: the host creates the group once all three accounts exist, a guest
// waits for it to arrive.
import 'dart:async';

import 'package:family_messenger_e2e/i18n/strings.dart';
import 'package:family_messenger_e2e/main.dart' as m;
import 'package:family_messenger_e2e/state/app_state.dart';
import 'package:family_messenger_e2e/state/voice_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

const server = String.fromEnvironment('TEST_SERVER', defaultValue: 'http://127.0.0.1:18082');
const me = String.fromEnvironment('TEST_USER', defaultValue: 'appalice');
const peer = String.fromEnvironment('TEST_PEER', defaultValue: 'appbob');
const other = String.fromEnvironment('TEST_OTHER', defaultValue: 'appcarol');
const group = String.fromEnvironment('TEST_GROUP', defaultValue: 'Channel');
const role = String.fromEnvironment('TEST_ROLE', defaultValue: 'host');

/// How many other participants the rig puts in the channel.
const expected = int.fromEnvironment('TEST_PEERS', defaultValue: 2);

Future<void> waitFor(WidgetTester tester, bool Function() condition, String what, {Duration timeout = const Duration(seconds: 300)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  await tester.pump();
}

// ignore: avoid_print
void say(String line) => print('[$role] $line');

/// Everybody in the channel except us.
List<VoiceParticipant> others(String convId) {
  final ch = m.app.voice.channel;
  return m.app.voice.participantsOf(convId).where((p) => p.session != ch?.session).toList();
}

/// The tiles of everybody else that are carrying frames, as "name:kind WxH".
List<String> liveTiles(String convId) {
  final out = <String>[];
  for (final p in others(convId)) {
    for (final screen in [false, true]) {
      final r = m.app.voice.renderers[VoiceController.tileKey(p.session, screen: screen)];
      if (r != null && r.videoWidth > 0) {
        out.add('${m.app.usernameOf(p.account)}:${screen ? 'screen' : 'camera'} ${r.videoWidth}x${r.videoHeight}');
      }
    }
  }
  return out;
}

/// Whatever the app is complaining about on screen, so a failure says why.
String complaints() {
  final texts = find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)).evaluate();
  return texts.map((e) => (e.widget as Text).data ?? '').join(' | ');
}

String peerStates(String convId) =>
    others(convId).map((p) => '${m.app.usernameOf(p.account)}=${m.app.voice.channel?.peers[p.session]?.name ?? '-'}'
        '${p.camera ? '+cam' : ''}${p.sharing ? '+screen' : ''}').join(' ');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Render like the real app (the window is watched from outside).
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('a group voice channel with a camera and a screen from everybody', (tester) async {
    L10n.set('en');
    m.app = AppState(persist: false);
    await m.app.init();
    await tester.pumpWidget(const m.FamilyMessengerApp());
    await tester.pump();

    await m.app.register(server, me, '$me-password-123', '');
    await waitFor(tester, () => m.app.signedIn, 'sign-in');
    say('signed in as $me');

    String? convId;
    if (role == 'host') {
      // Whoever else is taking part registers on their own; retry until they
      // all exist. An empty name is a side the rig left out.
      final members = [peer, other].where((n) => n.isNotEmpty).toList();
      final deadline = DateTime.now().add(const Duration(seconds: 420));
      while (convId == null) {
        try {
          convId = await m.app.createGroup(group, members);
        } catch (e) {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(seconds: 2));
          await tester.pump();
        }
      }
      say('group created');
    } else {
      // Not just any group: its name arrives in the conv.create payload a
      // moment after the conversation itself, and the list shows the name.
      await waitFor(
        tester,
        () => m.app.conversations.values.any((c) => !c.removed && m.app.titleOf(c) == group),
        'the group to arrive',
        timeout: const Duration(seconds: 420),
      );
      convId = m.app.conversations.values.firstWhere((c) => !c.removed && m.app.titleOf(c) == group).id;
      say('group received');
    }
    final conv = convId;

    try {
      // Open the group from the chat list and join its channel from the header
      // (the bar over the messages only appears once somebody else is in).
      await waitFor(tester, () => find.text(group).evaluate().isNotEmpty, 'the group in the list');
      await tester.tap(find.text(group).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(t('voice_channel')).first);
      await waitFor(tester, () => m.app.voice.channel != null, 'the channel');
      await tester.pumpAndSettle();
      expect(find.textContaining(t('voice_channel')), findsWidgets, reason: 'the channel panel must be on the screen');
      say('in the channel');

      // The browser peer and, when the rig runs it, the app on the other platform.
      await waitFor(tester, () => others(conv).length >= expected, 'everybody else to join');
      await waitFor(
        tester,
        () => others(conv).every((p) => m.app.voice.channel!.peers[p.session] == PeerState.connected),
        'every pair to connect',
      );
      say('connected: ${peerStates(conv)}');

      // Camera and screen, from the panel's buttons.
      await tester.tap(find.byTooltip(t('camera_on')).first);
      await waitFor(tester, () => m.app.voice.channel?.camera == true, 'our camera');
      await tester.pumpAndSettle();
      // The rig watches for this line: Android's capture consent dialog
      // cannot be granted up front and has to be tapped away from outside.
      say('SHARING THE SCREEN');
      await tester.tap(find.byTooltip(t('share_screen')).first);
      await waitFor(tester, () => m.app.voice.channel?.sharing == true, 'our screen');
      await tester.pumpAndSettle();
      say('our camera and screen are on');

      // A camera and a screen from each of the others.
      await waitFor(tester, () => liveTiles(conv).length >= expected * 2, 'frames from everybody');
      say('TILES ${liveTiles(conv).join(' | ')}');

      // And the same on the screen: the tiles page shows them.
      // The chip reads "Video and screens (n)" — match everything before the count.
      final tilesChip = t('video_and_screens', {'n': ''}).split('(').first.trim();
      await tester.tap(find.textContaining(tilesChip).first);
      await tester.pumpAndSettle();
      expect(find.text(t('voice_screens')), findsOneWidget, reason: 'the tiles page must open');
      expect(find.byType(RTCVideoView), findsAtLeastNWidgets(3), reason: 'the tiles must be rendering video');
      expect(find.text(t('voice_waiting_video')), findsNothing, reason: 'no tile may still be waiting for video');
      say('CHANNEL OK');

      // Hold while the others check their own side.
      await Future<void>.delayed(const Duration(seconds: 15));
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
    } catch (e) {
      say('CHANNEL STATE peers=[${peerStates(conv)}] tiles=[${liveTiles(conv).join(' | ')}] said=[${complaints()}]');
      rethrow;
    } finally {
      await m.app.voice.leave();
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
  }, timeout: const Timeout(Duration(minutes: 25)));
}
