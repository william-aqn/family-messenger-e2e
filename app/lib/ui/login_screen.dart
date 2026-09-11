import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/invite_link.dart';
import '../i18n/strings.dart';
import '../main.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'scan_screen.dart';

/// Sign-in / create-account screen (artboard A01).
///
/// Layout: the canvas colour, a 420-wide column, the brand row with the
/// language select, the Sign in / Create account tabs, labelled fields, the
/// error line and the full-width primary button, with the encryption note
/// pinned to the bottom.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// The design draws the scheme as a grey prefix inside the field, so the
  /// controller carries the host alone whenever it is an https address;
  /// `AppState` puts the scheme back before the URL is used.
  static const String _https = 'https://';

  bool registerMode = false;
  final server = TextEditingController(text: _stripHttps(app.serverUrl));
  final username = TextEditingController();
  final password = TextEditingController();
  final invite = TextEditingController();
  final usernameFocus = FocusNode();
  String? error;
  bool busy = false;

  /// Whether an invitation was read from a QR code (artboard A18): the scanner
  /// button gives way to the success banner.
  bool inviteScanned = false;

  /// What the scanner put into the two fields. The "from QR" tag marks a field
  /// only while it still carries that value — both stay editable.
  String? scannedServer;
  String? scannedInvite;

  static String _stripHttps(String url) => url.startsWith(_https) ? url.substring(_https.length) : url;

  @override
  void dispose() {
    usernameFocus.dispose();
    super.dispose();
  }

  /// Opens the scanner (A17) and fills the two fields from what it read. A QR
  /// that carries a bare code leaves the server address alone.
  Future<void> openScanner() async {
    final InviteLink? link = await scanInvite(context);
    if (link == null || !mounted) return;
    setState(() {
      if (link.server.isNotEmpty) {
        server.text = _stripHttps(link.server);
        scannedServer = server.text;
      }
      invite.text = link.code;
      scannedInvite = link.code;
      inviteScanned = true;
      error = null;
    });
    usernameFocus.requestFocus();
  }

  /// The prefix stands in for a scheme the text does not already carry.
  static bool _needsSchemePrefix(String text) {
    final String v = text.trimLeft();
    return !v.startsWith(_https) && !v.startsWith('http://');
  }

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
      // StateError carries a message already written for the user; its
      // toString prefixes "Bad state:", which does not belong on screen.
      setState(() => error = e is StateError ? e.message : e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme text = theme.textTheme;
    final ColorScheme scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _brandRow(theme),
                                const SizedBox(height: 20),
                                _tabs(theme),
                                if (registerMode) ...[
                                  const SizedBox(height: 20),
                                  if (inviteScanned)
                                    _scannedBanner(theme)
                                  else if (scannerSupported) ...[
                                    _scanButton(theme),
                                    const SizedBox(height: 20),
                                    _manualDivider(theme),
                                  ],
                                ],
                                const SizedBox(height: 20),
                                _field(
                                  theme,
                                  label: t('server_url'),
                                  controller: server,
                                  keyboardType: TextInputType.url,
                                  prefix: true,
                                  suffix: registerMode ? _fromQrTag(theme, server, scannedServer) : null,
                                ),
                                const SizedBox(height: 20),
                                _field(theme, label: t('username'), controller: username, focusNode: usernameFocus),
                                const SizedBox(height: 20),
                                _field(theme, label: t('password'), controller: password, obscure: true),
                                if (registerMode) ...[
                                  const SizedBox(height: 20),
                                  _field(
                                    theme,
                                    label: t('invite_code'),
                                    controller: invite,
                                    suffix: _fromQrTag(theme, invite, scannedInvite, fallback: scannerSupported ? _scanIconButton(theme) : null),
                                  ),
                                  const SizedBox(height: 20),
                                  _alertBanner(theme, t('password_warning')),
                                ],
                                if (error != null) ...[
                                  const SizedBox(height: 20),
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Icon(LucideIcons.alertTriangle, size: 16, color: scheme.error),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(error!, style: text.bodyMedium?.copyWith(color: scheme.error))),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 20),
                                _submitButton(theme),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // The encryption note sits at the bottom of the screen, below the
            // scrolling form.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: _footer(theme),
            ),
          ],
        ),
      ),
    );
  }

  /// Lock mark, product name, the encryption line with the version, and the
  /// language select on the right.
  Widget _brandRow(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.lock, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Flexible(child: Text(t('app_name'), style: theme.textTheme.headlineSmall)),
                ],
              ),
              const SizedBox(height: 6),
              Text('${t('e2e_hint')} · $appVersion', style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
        const SizedBox(width: 16),
        _languageSelect(theme),
      ],
    );
  }

  /// A 32-high bordered select: globe, the language name, a chevron.
  Widget _languageSelect(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? style = theme.inputDecorationTheme.labelStyle?.copyWith(color: scheme.primary);
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(fmRadius),
        border: Border.all(color: scheme.outline, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.globe, size: 14, color: scheme.primary),
          const SizedBox(width: 6),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: L10n.current,
              isDense: true,
              style: style,
              iconSize: 12,
              icon: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(LucideIcons.chevronDown, size: 12, color: scheme.primary),
              ),
              dropdownColor: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(fmRadius),
              focusColor: Colors.transparent,
              items: [for (final c in L10n.codes) DropdownMenuItem<String>(value: c, child: Text(languageNames[c] ?? c))],
              onChanged: (v) => v == null ? null : app.setLanguage(v).then((_) => setState(() {})),
            ),
          ),
        ],
      ),
    );
  }

  /// Sign in / Create account: two tabs over a hairline, the active one
  /// carrying a 2px accent rail.
  Widget _tabs(ThemeData theme) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(height: 1, color: theme.colorScheme.outlineVariant),
        ),
        Row(
          children: [
            _tab(theme, t('sign_in'), selected: !registerMode, onTap: () => setState(() => registerMode = false)),
            const SizedBox(width: 24),
            _tab(theme, t('create_account'), selected: registerMode, onTap: () => setState(() => registerMode = true)),
          ],
        ),
      ],
    );
  }

  Widget _tab(ThemeData theme, String label, {required bool selected, required VoidCallback onTap}) {
    final ColorScheme scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      hoverColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 2)),
        ),
        child: Text(
          label,
          style: theme.textTheme.titleMedium?.copyWith(color: selected ? scheme.onSurface : scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  /// A16: the scanner comes first on the Create account tab, as the largest
  /// thing on the screen.
  Widget _scanButton(ThemeData theme) {
    return SizedBox(
      height: 56,
      child: FilledButton(
        onPressed: openScanner,
        style: FilledButton.styleFrom(textStyle: theme.textTheme.titleLarge),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(LucideIcons.qrCode, size: 22),
            const SizedBox(width: 10),
            Flexible(child: Text(t('scan_invite'), overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }

  /// A16: two hairlines with the way out to typing between them.
  Widget _manualDivider(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      children: <Widget>[
        Expanded(child: Container(height: 1, color: scheme.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            t('enter_code_manually'),
            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, color: scheme.outline),
          ),
        ),
        Expanded(child: Container(height: 1, color: scheme.outlineVariant)),
      ],
    );
  }

  /// The same scanner from inside the invite field (A16).
  Widget _scanIconButton(ThemeData theme) {
    return IconButton(
      onPressed: openScanner,
      color: theme.colorScheme.primary,
      tooltip: t('scan_invite'),
      icon: const Icon(LucideIcons.qrCode, size: 20),
    );
  }

  /// A18: the "from QR" tag, shown while [controller] still holds exactly what
  /// the scanner put there. Falls back to [fallback] (the scanner button on the
  /// invite field) once the value is the user's own.
  Widget? _fromQrTag(ThemeData theme, TextEditingController controller, String? scanned, {Widget? fallback}) {
    if (scanned == null) return fallback;
    final ColorScheme scheme = theme.colorScheme;
    final Widget tag = Padding(
      padding: const EdgeInsets.only(left: 8, right: 12),
      child: Container(
        height: 20,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: FmColors.of(context).tagBot,
          borderRadius: BorderRadius.circular(fmPillRadius),
        ),
        child: Text(
          t('from_qr'),
          style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w500, color: scheme.primary),
        ),
      ),
    );
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, Widget? child) =>
          value.text == scanned ? tag : (fallback ?? const SizedBox.shrink()),
    );
  }

  /// A18: the success banner over the form, with the way back to the scanner.
  Widget _scannedBanner(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    final Color ok = FmColors.of(context).ok;
    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(fmRadius)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(width: 2, color: ok),
            Expanded(
              child: Container(
                color: Color.alphaBlend(ok.withValues(alpha: .15), scheme.surface),
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                child: Row(
                  children: <Widget>[
                    Icon(LucideIcons.check, size: 20, color: ok),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(t('invite_scanned'), style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface)),
                    ),
                    TextButton(
                      onPressed: openScanner,
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.primary,
                        textStyle: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                      child: Text(t('scan_again')),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A label over a 48-high field, as the artboard draws it.
  Widget _field(
    ThemeData theme, {
    required String label,
    required TextEditingController controller,
    bool obscure = false,
    bool prefix = false,
    TextInputType? keyboardType,
    FocusNode? focusNode,
    Widget? suffix,
  }) {
    final TextStyle? value = theme.inputDecorationTheme.hintStyle?.copyWith(color: theme.colorScheme.primary);
    Widget input(String? prefixText) => TextField(
          controller: controller,
          focusNode: focusNode,
          style: value,
          obscureText: obscure,
          autocorrect: false,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            prefixText: prefixText,
            suffixIcon: suffix,
            // The trailing tag and the scanner button carry their own size; the
            // field must not reserve a 48 box for them.
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            // No label inside the field: the prefix has to stay visible while
            // the field is empty and unfocused.
            floatingLabelBehavior: FloatingLabelBehavior.always,
            constraints: const BoxConstraints(minHeight: 48),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.inputDecorationTheme.labelStyle),
        const SizedBox(height: 4),
        if (prefix)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (BuildContext context, TextEditingValue text, Widget? child) =>
                input(_needsSchemePrefix(text.text) ? _https : null),
          )
        else
          input(null),
      ],
    );
  }

  /// Alarm banner: the danger wash with a 2px rail on the left.
  Widget _alertBanner(ThemeData theme, String message) {
    final ColorScheme scheme = theme.colorScheme;
    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(fmRadius)),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 2, color: scheme.error),
            Expanded(
              child: Container(
                color: scheme.errorContainer,
                padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.alertTriangle, size: 20, color: scheme.error),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Full-width primary button; while busy it carries the progress text under
  /// a 4px linear progress.
  Widget _submitButton(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (busy) ...[
          Opacity(
            opacity: .7,
            child: LinearProgressIndicator(
              minHeight: 4,
              borderRadius: BorderRadius.circular(fmRadius),
            ),
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: busy ? null : submit,
            style: FilledButton.styleFrom(textStyle: theme.textTheme.titleLarge),
            child: Text(busy ? (app.busyText ?? '…') : (registerMode ? t('create_account') : t('sign_in'))),
          ),
        ),
      ],
    );
  }

  Widget _footer(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(LucideIcons.lock, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            t('encrypted_server_hint'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
          ),
        ),
      ],
    );
  }
}
