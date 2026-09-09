import { useEffect, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { ServerInfo } from '../api/types';
import { describeError, lang, languages, setLang, t } from '../i18n';
import { authBusy, login, MIN_PASSWORD_LENGTH, register } from '../state/session';

export function Login() {
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [invite, setInvite] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<ServerInfo | null>(null);

  useEffect(() => {
    http
      .info()
      .then(setInfo)
      .catch(() => {});
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
  return (
    <div class="center">
      <form class="card login" onSubmit={submit}>
        <div class="row between">
          <h1>{t('app_name')}</h1>
          <select class="lang" value={lang.value} onChange={(e) => setLang((e.target as HTMLSelectElement).value)} aria-label={t('language')}>
            {Object.entries(languages).map(([code, l]) => (
              <option key={code} value={code}>
                {l.name}
              </option>
            ))}
          </select>
        </div>
        <p class="muted">{t('tagline')}</p>
        {info?.announcement && <div class="notice">{info.announcement}</div>}
        <div class="tabs">
          <button type="button" class={mode === 'login' ? 'active' : ''} onClick={() => setMode('login')}>
            {t('tab_sign_in')}
          </button>
          <button type="button" class={mode === 'register' ? 'active' : ''} onClick={() => setMode('register')}>
            {t('tab_create_account')}
          </button>
        </div>
        <label>
          {t('username')}
          <input
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
          {t('password')}
          <input
            type="password"
            value={password}
            onInput={(e) => setPassword((e.target as HTMLInputElement).value)}
            autocomplete={mode === 'login' ? 'current-password' : 'new-password'}
            required
            minLength={mode === 'register' ? MIN_PASSWORD_LENGTH : 1}
            placeholder={mode === 'register' ? t('password_min', { n: MIN_PASSWORD_LENGTH }) : ''}
          />
        </label>
        {mode === 'register' && registration === 'closed' && <div class="error">{t('registration_closed')}</div>}
        {mode === 'register' && registration !== 'open' && (
          <label>
            {t('invite_code')} <span class="muted">{t('invite_hint')}</span>
            <input value={invite} onInput={(e) => setInvite((e.target as HTMLInputElement).value)} autocomplete="off" required={registration === 'invite'} />
          </label>
        )}
        {mode === 'register' && <p class="hint">{t('password_warning')}</p>}
        {error && <div class="error">{error}</div>}
        <button type="submit" class="primary" disabled={!!busy || (mode === 'register' && registration === 'closed')}>
          {busy ?? (mode === 'login' ? t('tab_sign_in') : t('tab_create_account'))}
        </button>
      </form>
    </div>
  );
}
