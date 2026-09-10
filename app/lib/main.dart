import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state/app_state.dart';
import 'state/updater.dart';
import 'ui/call_screen.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';

/// Replaced by integration tests with an instance that does not persist.
AppState app = AppState();

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F8CFF), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      builder: (context, child) => ListenableBuilder(
        listenable: app.calls,
        builder: (context, _) => Stack(
          children: [
            ?child,
            if (app.calls.call != null) const CallScreen(),
          ],
        ),
      ),
      home: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          if (app.booting) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          if (!app.signedIn) return const LoginScreen();
          return const HomeScreen();
        },
      ),
    );
  }
}
