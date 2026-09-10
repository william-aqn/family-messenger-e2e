import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'state/app_state.dart';
import 'state/updater.dart';
import 'theme.dart';
import 'ui/call_screen.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';

/// Replaced by integration tests with an instance that does not persist.
/// `FAMILY_MESSENGER_EPHEMERAL=1` in the environment does the same for a
/// normal launch: the app starts signed out and saves nothing, so a test
/// account can be driven through the real UI without touching the session
/// stored on the machine.
AppState app = AppState(persist: kIsWeb || Platform.environment['FAMILY_MESSENGER_EPHEMERAL'] != '1');

/// Build identification, passed by the build scripts as `--dart-define=APP_VERSION=` plus `git describe`.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// Looks for newer releases on GitHub and installs them.
final Updater updater = Updater(appVersion);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && Platform.isWindows) {
    // The Windows runner puts the build number into the window title.
    unawaited(const MethodChannel('family_messenger/window').invokeMethod<void>('setTitle', 'Family Messenger $appVersion').catchError((Object _) {}));
  }
  // The product theme is dark chrome edge to edge; the status bar draws its
  // icons light over it.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: cBg0,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  app.init();
  runApp(const FamilyMessengerApp());
  updater.start();
}

class FamilyMessengerApp extends StatelessWidget {
  const FamilyMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Messenger $appVersion',
      debugShowCheckedModeBanner: false,
      // Crimson Lab is the product theme and the only one the UI selects; the
      // SpecMash variants stay in `fmTheme()` for the guideline. The app is
      // dark-only, so both slots point at the same theme.
      theme: fmCrimson(),
      darkTheme: fmCrimson(),
      themeMode: ThemeMode.dark,
      builder: (context, child) => ListenableBuilder(
        listenable: app.calls,
        builder: (context, _) => Stack(
          children: [
            ?child,
            // The call screen sits above the Navigator, so it brings its own
            // Overlay: tooltips (and anything else that floats) need one.
            if (app.calls.call != null) Overlay(initialEntries: [OverlayEntry(builder: (_) => const CallScreen())]),
          ],
        ),
      ),
      home: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          if (app.booting) return const _BootScreen();
          if (!app.signedIn) return const LoginScreen();
          return const HomeScreen();
        },
      ),
    );
  }
}

/// Shown while the stored session is unlocked: the brand lock over the
/// conversation canvas, and a sand spinner. No text — the dictionaries have no
/// key for it, and the screen lives for a fraction of a second.
class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: cBg1,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.lock, size: 24, color: sand),
            SizedBox(height: 20),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2, color: sand),
            ),
          ],
        ),
      ),
    );
  }
}
