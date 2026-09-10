import 'package:flutter/material.dart';

import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool registerMode = false;
  final server = TextEditingController(text: app.serverUrl);
  final username = TextEditingController();
  final password = TextEditingController();
  final invite = TextEditingController();
  String? error;
  bool busy = false;

  Future<void> submit() async {
    setState(() {
      error = null;
      busy = true;
    });
    try {
      if (registerMode) {
        if (password.text.length < AppState.minPasswordLength) throw StateError(t('password_too_short', {'n': AppState.minPasswordLength}));
        await app.register(server.text, username.text, password.text, invite.text);
      } else {
        await app.login(server.text, username.text, password.text);
      }
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('app_name'), style: Theme.of(context).textTheme.headlineMedium),
                        Text(appVersion, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                    DropdownButton<String>(
                      value: L10n.current,
                      items: [for (final c in L10n.codes) DropdownMenuItem(value: c, child: Text(languageNames[c] ?? c))],
                      onChanged: (v) => v == null ? null : app.setLanguage(v).then((_) => setState(() {})),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SegmentedButton<bool>(
                  segments: [ButtonSegment(value: false, label: Text(t('sign_in'))), ButtonSegment(value: true, label: Text(t('create_account')))],
                  selected: {registerMode},
                  onSelectionChanged: (s) => setState(() => registerMode = s.first),
                ),
                const SizedBox(height: 16),
                TextField(controller: server, decoration: InputDecoration(labelText: t('server_url'), hintText: t('server_hint')), keyboardType: TextInputType.url, autocorrect: false),
                const SizedBox(height: 12),
                TextField(controller: username, decoration: InputDecoration(labelText: t('username')), autocorrect: false),
                const SizedBox(height: 12),
                TextField(controller: password, decoration: InputDecoration(labelText: t('password')), obscureText: true),
                if (registerMode) ...[
                  const SizedBox(height: 12),
                  TextField(controller: invite, decoration: InputDecoration(labelText: t('invite_code')), autocorrect: false),
                  const SizedBox(height: 8),
                  Text(t('password_warning'), style: TextStyle(color: Theme.of(context).colorScheme.tertiary, fontSize: 12)),
                ],
                if (error != null) ...[const SizedBox(height: 12), Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: Text(busy ? (app.busyText ?? '…') : (registerMode ? t('create_account') : t('sign_in'))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
