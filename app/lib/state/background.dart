// What Android allows the app once it is off the screen.
//
// The messenger holds its socket open for messages and calls and has no push
// service behind it, so a phone that suspends the app simply does not ring.
// Two of the settings that decide this can be read (see BackgroundAccess.kt);
// the vendor autostart lists cannot, which is why the wording here never says
// more than "Android is not the one standing in the way".
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('family_messenger/background');

class BackgroundAccess extends ChangeNotifier {
  /// Only Android has anything to say here; everywhere else the section of
  /// the settings sheet is not drawn at all.
  static bool get onThisPlatform => !kIsWeb && Platform.isAndroid;

  /// Battery optimisation is off for this app, so the socket may stay open
  /// while the screen is dark. Assumed true until the platform answers, so a
  /// phone that has nothing to complain about never flashes a warning.
  bool unrestricted = true;

  /// The app is set to "Restricted": Android stops it as soon as it leaves
  /// the screen. The worse of the two, and the one with no dialog to fix it.
  bool restricted = false;

  /// The platform has answered at least once. Before that the section stays
  /// quiet rather than claiming that all is well.
  bool known = false;

  bool get fine => unrestricted && !restricted;

  Future<void> refresh() async {
    if (!onThisPlatform) return;
    try {
      final Map<Object?, Object?>? state = await _channel.invokeMethod<Map<Object?, Object?>>('state');
      if (state == null) return;
      unrestricted = state['unrestricted'] == true;
      restricted = state['restricted'] == true;
      known = true;
      notifyListeners();
    } catch (e) {
      // An older build of the Android side, or no activity to ask: saying
      // nothing is better than accusing the phone of something.
      debugPrint('background state unknown: $e');
    }
  }

  /// The system dialog that takes the app out of battery optimisation. The
  /// answer comes back as a changed [unrestricted] on the next [refresh],
  /// which AppState runs when the app returns to the screen.
  Future<void> requestUnrestricted() => _call('requestUnrestricted');

  /// This app's page in the system settings, where "Restricted" is undone.
  Future<void> openAppSettings() => _call('openAppSettings');

  Future<void> _call(String method) async {
    if (!onThisPlatform) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      debugPrint('$method failed: $e');
    }
  }
}
