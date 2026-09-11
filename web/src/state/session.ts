// Registration, login and logout flows (PROTOCOL.md §3).
import { signal } from '@preact/signals';
import { ApiError, http, setToken } from '../api/http';
import type { ApiSession } from '../api/types';
import { wsClient } from '../api/ws';
import { type AccountKeys, checkKdfParams, deriveKeys, generateKeys, keysFromSecrets, newKeyBundle, openKeyBundle, SALT_SIZE, signPasswordChange } from '../crypto/account';
import { b64decode, b64encode, randomBytes } from '../crypto/bytes';
import { uuidToBytes } from '../crypto/ids';
import { t } from '../i18n';
import { clearAll, getMeta, setMeta } from '../store/db';
import { resetState, serverSettings, serverVersion, session, type SessionInfo } from './model';
import { loadLocalState, startSync, stopSync } from './sync';

export const keys = signal<AccountKeys | null>(null);
export const booting = signal(true);
/** Progress text while a login or registration is running. */
export const authBusy = signal<string | null>(null);

export const MIN_PASSWORD_LENGTH = 12;

function deviceName(): string {
  const ua = navigator.userAgent;
  const os = /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' : /Mac/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : 'web';
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'browser';
  return `${browser} on ${os}`;
}

/** Refreshes admin flag and server settings from /me. */
export async function refreshMe(): Promise<void> {
  try {
    const me = await http.me();
    serverSettings.value = me.settings;
    serverVersion.value = me.version;
    const s = session.value;
    if (s && s.isAdmin !== me.account.is_admin) {
      const next = { ...s, isAdmin: me.account.is_admin };
      session.value = next;
      await setMeta('session', next);
    }
  } catch (e) {
    if (e instanceof ApiError && (e.status === 401 || e.status === 403)) await logout();
  }
}

export async function restoreSession(): Promise<void> {
  try {
    const s = await getMeta<SessionInfo>('session');
    const k = await getMeta<{ signSeed: Uint8Array; encPriv: Uint8Array }>('keys');
    if (s && k) {
      setToken(s.token);
      keys.value = keysFromSecrets(k.signSeed, k.encPriv);
      session.value = { ...s, isAdmin: s.isAdmin ?? false };
      await loadLocalState();
      startSync();
      void refreshMe();
    }
  } catch (e) {
    console.error('restore session failed', e);
  } finally {
    booting.value = false;
  }
}

async function establish(sess: ApiSession, k: AccountKeys): Promise<void> {
  await clearAll();
  const info: SessionInfo = { accountId: sess.account_id, deviceId: sess.device_id, username: sess.username, token: sess.token, isAdmin: !!sess.is_admin };
  await setMeta('session', info);
  await setMeta('keys', { signSeed: k.signSeed, encPriv: k.encPriv });
  setToken(sess.token);
  keys.value = k;
  session.value = info;
  await loadLocalState();
  startSync();
  void refreshMe();
}

export function validatePassword(password: string): string | null {
  if (password.length < MIN_PASSWORD_LENGTH) return t('password_too_short', { n: MIN_PASSWORD_LENGTH });
  return null;
}

export async function register(username: string, password: string, invite: string): Promise<void> {
  const problem = validatePassword(password);
  if (problem) throw new Error(problem);
  authBusy.value = t('generating_keys');
  try {
    const k = generateKeys();
    const salt = randomBytes(SALT_SIZE);
    authBusy.value = t('deriving_key');
    const { authKey, encKey } = await deriveKeys(password, salt);
    const bundle = newKeyBundle(encKey, k);
    authBusy.value = t('registering');
    const sess = await http.register({
      username,
      salt: b64encode(salt),
      auth_key: b64encode(authKey),
      sign_pub: b64encode(k.signPub),
      enc_pub: b64encode(k.encPub),
      key_bundle: b64encode(bundle),
      invite: invite.trim(),
      device_name: deviceName(),
    });
    await establish(sess, k);
  } finally {
    authBusy.value = null;
  }
}

export async function login(username: string, password: string): Promise<void> {
  authBusy.value = t('fetching_params');
  try {
    const params = await http.authParams(username);
    // Refuse to sign in against a server that asks for a cheap derivation:
    // it would be asking for the password, not for the login secret.
    try {
      checkKdfParams(params.kdf);
    } catch {
      throw new Error(t('weak_kdf'));
    }
    authBusy.value = t('deriving_key');
    const { authKey, encKey } = await deriveKeys(password, b64decode(params.salt), params.kdf);
    authBusy.value = t('signing_in');
    const sess = await http.login({ username, auth_key: b64encode(authKey), device_name: deviceName() });
    let k: AccountKeys;
    try {
      k = openKeyBundle(encKey, b64decode(sess.key_bundle), b64decode(sess.sign_pub), b64decode(sess.enc_pub));
    } catch {
      throw new Error(t('key_unlock_failed'));
    }
    await establish(sess, k);
  } finally {
    authBusy.value = null;
  }
}

export async function logout(): Promise<void> {
  stopSync();
  try {
    await http.logout();
  } catch {
    /* token may already be invalid */
  }
  setToken(null);
  keys.value = null;
  resetState();
  await clearAll();
}

/**
 * Changes the password (PROTOCOL.md §3.2). The new key bundle is built from
 * the account keys this device already holds, so the old password is not
 * needed; the server is satisfied instead by a signature over a challenge it
 * just issued, which only a device holding the account's signing key can
 * make. When asked, every other device is signed out. Returns how many were.
 */
export async function changePassword(next: string, signOutOthers = true): Promise<number> {
  const problem = validatePassword(next);
  if (problem) throw new Error(problem);
  const s = session.value;
  const k = keys.value;
  if (!s || !k) throw new Error('not signed in');
  authBusy.value = t('deriving_key');
  try {
    const salt = randomBytes(SALT_SIZE);
    const fresh = await deriveKeys(next, salt);
    const bundle = newKeyBundle(fresh.encKey, k);
    // Open what we are about to upload. Nothing can unlock the account if
    // this bundle is wrong, so never send one that does not come back.
    openKeyBundle(fresh.encKey, bundle, k.signPub, k.encPub);
    authBusy.value = t('changing_password');
    // A fresh challenge per attempt: the server consumes it on use. Another
    // tab or a server restart can take it first, which is a lost race and
    // not a failure, so try once more before telling the user.
    const attempt = async (): Promise<number> => {
      const { challenge } = await http.passwordChallenge();
      const sig = signPasswordChange(
        k.signSeed,
        b64decode(challenge),
        uuidToBytes(s.accountId),
        uuidToBytes(s.deviceId),
        salt,
        fresh.authKey,
        bundle,
        signOutOthers,
      );
      const res = await http.changePassword({
        challenge,
        sig: b64encode(sig),
        new_salt: b64encode(salt),
        new_auth_key: b64encode(fresh.authKey),
        new_key_bundle: b64encode(bundle),
        sign_out_others: signOutOthers,
      });
      return res?.signed_out_devices ?? 0;
    };
    try {
      return await attempt();
    } catch (e) {
      if (e instanceof ApiError && e.code === 'challenge_expired') return await attempt();
      throw e;
    }
  } finally {
    authBusy.value = null;
  }
}

// A device whose session was revoked (a password change elsewhere, "sign out"
// from another device, an administrator) has its socket closed with 1008 and
// must not sit in "reconnecting" forever: /me answers 401 and signs it out.
wsClient.on('revoked', () => void refreshMe());
