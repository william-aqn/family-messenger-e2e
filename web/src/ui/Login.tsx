import { useEffect, useRef, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { ServerInfo } from '../api/types';
import { describeError, lang, languages, setLang, t } from '../i18n';
import { parseInviteLink } from '../state/invite';
import { APP_VERSION } from '../state/model';
import { authBusy, login, MIN_PASSWORD_LENGTH, register } from '../state/session';
import { Icon } from './Icons';

export function Login() {
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [invite, setInvite] = useState('');
  const [fromLink, setFromLink] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<ServerInfo | null>(null);
  const usernameRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    http
      .info()
      .then(setInfo)
      .catch(() => {});
  }, []);

  // An invitation QR points a phone camera at `<server>/#/join?code=<code>`.
  // Landing here means the code is already known: open "Create account" with the
  // field filled in and let the visitor start typing their name straight away.
  useEffect(() => {
    const parsed = parseInviteLink(location.href);
    if (!parsed) return;
    setMode('register');
    setInvite(parsed.code);
    setFromLink(true);
    usernameRef.current?.focus();
    // Drop the join route, so a reload or a copied address is an ordinary visit.
    const url = new URL(location.href);
    url.hash = '';
    url.searchParams.delete('code');
    history.replaceState(null, '', `${url.pathname}${url.search}`);
  }, []);

  const submit = async (e: Event) => {
    e.preventDefault();
    setError(null);
    try {
      if (mode === 'login') await login(username.trim(), password);
      else await register(username.trim(), password, invite);
    } catch (err) {
      setError(describeError(err));
    }
  };

  const busy = authBusy.value;
  const registration = info?.registration ?? 'invite';
  const isRegister = mode === 'register';
  return (
    <div class="login-screen">
      <div class="login-bar">
        <Icon name="lock" size={20} />
        <span class="brand">{t('app_name')}</span>
        <span class="version">{APP_VERSION}</span>
      </div>
      <div class="center">
        <form class="card login" onSubmit={submit}>
          <div class="modal-head">
            <div class="brand-block">
              <h1>{t('app_name')}</h1>
              <span class="tagline">{t('tagline')}</span>
            </div>
            <div class="lang-select">
              <Icon name="globe" size={16} />
              <select class="lang" value={lang.value} onChange={(e) => setLang((e.target as HTMLSelectElement).value)} aria-label={t('language')}>
                {Object.entries(languages).map(([code, l]) => (
                  <option key={code} value={code}>
                    {l.name}
                  </option>
                ))}
              </select>
            </div>
          </div>
          {info?.announcement && (
            <div class="banner notice neutral">
              <Icon name="info" size={20} />
              <span class="grow">{info.announcement}</span>
            </div>
          )}
          <div class="tabs">
            <button type="button" class={mode === 'login' ? 'active' : ''} onClick={() => setMode('login')}>
              {t('tab_sign_in')}
            </button>
            <button type="button" class={isRegister ? 'active' : ''} onClick={() => setMode('register')}>
              {t('tab_create_account')}
            </button>
          </div>
          {isRegister && fromLink && (
            <div class="banner ok">
              <Icon name="check" size={20} />
              <span class="grow">{t('invite_scanned')}</span>
            </div>
          )}
          <label>
            <span>{t('username')}</span>
            <input
              ref={usernameRef}
              value={username}
              onInput={(e) => setUsername((e.target as HTMLInputElement).value)}
              autocomplete="username"
              required
              minLength={3}
              maxLength={32}
              pattern="[A-Za-z0-9._]+"
              placeholder="alice"
            />
          </label>
          <label>
            <span>{t('password')}</span>
            <input
              type="password"
              value={password}
              onInput={(e) => setPassword((e.target as HTMLInputElement).value)}
              autocomplete={isRegister ? 'new-password' : 'current-password'}
              required
              minLength={isRegister ? MIN_PASSWORD_LENGTH : 1}
              aria-invalid={error ? 'true' : undefined}
            />
            {/* The leading space keeps the label's accessible name readable: "Password at least 12 characters". */}
            {isRegister && <span class="hint"> {t('password_min', { n: MIN_PASSWORD_LENGTH })}</span>}
          </label>
          {isRegister && registration === 'closed' && (
            <div class="error">
              <Icon name="alert" size={16} />
              {t('registration_closed')}
            </div>
          )}
          {isRegister && registration !== 'open' && (
            <label>
              <span>
                {t('invite_code')} <span class="muted">{t('invite_hint')}</span>
                {fromLink && <span class="tag bot">{t('from_qr')}</span>}
              </span>
              <input
                value={invite}
                onInput={(e) => {
                  setInvite((e.target as HTMLInputElement).value);
                  setFromLink(false);
                }}
                autocomplete="off"
                required={registration === 'invite'}
                placeholder="k3n8xq2p7v4m9wsc"
              />
            </label>
          )}
          {isRegister && (
            <div class="banner alert">
              <Icon name="alert" size={20} />
              <span class="grow">{t('password_warning')}</span>
            </div>
          )}
          {error && (
            <div class="error">
              <Icon name="alert" size={16} />
              {error}
            </div>
          )}
          <button type="submit" class={busy ? 'primary busy' : 'primary'} disabled={!!busy || (isRegister && registration === 'closed')}>
            {busy ? (
              <>
                <span class="spinner" />
                {busy}
              </>
            ) : (
              isRegister ? t('tab_create_account') : t('tab_sign_in')
            )}
          </button>
        </form>
      </div>
    </div>
  );
}
