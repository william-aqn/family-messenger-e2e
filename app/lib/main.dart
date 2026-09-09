import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'ui/call_screen.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';

final AppState app = AppState();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  app.init();
  runApp(const FamilyMessengerApp());
}

class FamilyMessengerApp extends StatelessWidget {
  const FamilyMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Messenger',
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
