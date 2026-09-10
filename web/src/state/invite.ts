// Invitation links: `<origin>/#/join?code=<code>`. The QR code on an invite
// carries this link, so a phone camera opens registration with the server
// address and the code already filled in. The same parser also accepts a bare
// code, because the mobile scanner may read either.

/**
 * Invite codes are 16 lowercase base32 characters on the server
 * (`store.NewInviteCode`), but the parser stays lenient: dashes and case are
 * accepted so a code typed or printed by hand still resolves.
 */
const CODE_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$/;

/** Builds the invitation link for `code`. `origin` defaults to this page's. */
export function inviteLink(code: string, origin?: string): string {
  const base = trimSlashes(origin ?? (typeof location === 'undefined' ? '' : location.origin));
  return `${base}/#/join?code=${encodeURIComponent(code.trim())}`;
}

export interface ParsedInvite {
  /** Server origin from the link, without a trailing slash; '' if the value was a bare code. */
  server: string;
  code: string;
}

/**
 * Reads an invitation link or a bare invite code. Returns null when the value
 * carries no usable code.
 */
export function parseInviteLink(value: string): ParsedInvite | null {
  const s = (value ?? '').trim();
  if (!s) return null;

  // A bare code: no scheme, no path, no query and no fragment.
  if (!/[/?#:]/.test(s)) return CODE_RE.test(s) ? { server: '', code: s } : null;

  const hash = s.indexOf('#');
  const base = hash < 0 ? s : s.slice(0, hash);
  const fragment = hash < 0 ? '' : s.slice(hash + 1);

  // The code lives in the fragment (`#/join?code=…`); a link that carries it in
  // the ordinary query string is accepted too.
  const raw = queryParam(fragment, 'code') ?? queryParam(base, 'code');
  if (raw === null) return null;
  let code: string;
  try {
    code = decodeURIComponent(raw).trim();
  } catch {
    code = raw.trim();
  }
  if (!CODE_RE.test(code)) return null;

  const q = base.indexOf('?');
  // A link without a fragment ('…/join?code=…', what a server-side deep link
  // looks like) still names the server in front of that path.
  let server = trimSlashes(q < 0 ? base : base.slice(0, q)).replace(/\/join$/, '');
  if (server && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(server)) server = `https://${server}`;
  return { server, code };
}

/** Value of `name` in the query part of `part`, or null. */
function queryParam(part: string, name: string): string | null {
  const q = part.indexOf('?');
  const query = q >= 0 ? part.slice(q + 1) : part.includes('=') ? part : '';
  for (const pair of query.split('&')) {
    const eq = pair.indexOf('=');
    if (eq >= 0 && pair.slice(0, eq) === name) return pair.slice(eq + 1);
  }
  return null;
}

function trimSlashes(origin: string): string {
  return origin.trim().replace(/\/+$/, '');
}
