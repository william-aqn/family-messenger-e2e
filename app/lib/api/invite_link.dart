// Invitation links: `<origin>/#/join?code=<code>`. The QR code on an invite
// carries this link, so a phone camera opens registration with the server
// address and the code already filled in. The same parser also accepts a bare
// code, because the scanner may read either. Mirrors web/src/state/invite.ts.

/// Invite codes are 16 lowercase base32 characters on the server
/// (`store.NewInviteCode`), but the parser stays lenient: dashes and case are
/// accepted so a code typed or printed by hand still resolves.
final RegExp _codeRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$');

final RegExp _schemeRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');

/// Builds the invitation link for [code] on [origin].
String inviteLink(String code, String origin) {
  final base = _trimSlashes(origin);
  return '$base/#/join?code=${Uri.encodeComponent(code.trim())}';
}

/// A server address and invite code read from an invitation link.
class InviteLink {
  const InviteLink(this.server, this.code);

  /// Server origin from the link, without a trailing slash; empty when the
  /// value was a bare code and the caller has to keep the address it has.
  final String server;
  final String code;

  @override
  String toString() => 'InviteLink($server, $code)';

  @override
  bool operator ==(Object other) =>
      other is InviteLink && other.server == server && other.code == code;

  @override
  int get hashCode => Object.hash(server, code);
}

/// Reads an invitation link or a bare invite code. Returns null when the value
/// carries no usable code.
InviteLink? parseInviteLink(String value) {
  final s = value.trim();
  if (s.isEmpty) return null;

  // A bare code: no scheme, no path, no query and no fragment.
  if (!RegExp(r'[/?#:]').hasMatch(s)) {
    return _codeRe.hasMatch(s) ? InviteLink('', s) : null;
  }

  final hash = s.indexOf('#');
  final base = hash < 0 ? s : s.substring(0, hash);
  final fragment = hash < 0 ? '' : s.substring(hash + 1);

  // The code lives in the fragment (`#/join?code=…`); a link that carries it in
  // the ordinary query string is accepted too.
  final raw = _queryParam(fragment, 'code') ?? _queryParam(base, 'code');
  if (raw == null) return null;
  String code;
  try {
    code = Uri.decodeComponent(raw).trim();
  } on ArgumentError {
    code = raw.trim();
  } on FormatException {
    code = raw.trim();
  }
  if (!_codeRe.hasMatch(code)) return null;

  final q = base.indexOf('?');
  // A link without a fragment ('…/join?code=…', what a server-side deep link
  // looks like) still names the server in front of that path.
  var server = _trimSlashes(q < 0 ? base : base.substring(0, q))
      .replaceFirst(RegExp(r'/join$'), '');
  if (server.isNotEmpty && !_schemeRe.hasMatch(server)) {
    server = 'https://$server';
  }
  return InviteLink(server, code);
}

/// Value of [name] in the query part of [part], or null.
String? _queryParam(String part, String name) {
  final q = part.indexOf('?');
  final query = q >= 0
      ? part.substring(q + 1)
      : part.contains('=')
          ? part
          : '';
  for (final pair in query.split('&')) {
    final eq = pair.indexOf('=');
    if (eq >= 0 && pair.substring(0, eq) == name) return pair.substring(eq + 1);
  }
  return null;
}

String _trimSlashes(String origin) =>
    origin.trim().replaceFirst(RegExp(r'/+$'), '');
