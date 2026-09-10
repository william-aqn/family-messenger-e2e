import { useEffect, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { DeviceView } from '../api/types';
import { fingerprint } from '../crypto/fingerprint';
import { describeError, lang, languages, setLang, t } from '../i18n';
import { serverSettings, serverVersion, session, showToast } from '../state/model';
import { authBusy, changePassword, keys, logout, MIN_PASSWORD_LENGTH } from '../state/session';
import { AdminPanel } from './AdminPanel';
import { BotsDialog } from './BotsDialog';
import { Icon } from './Icons';

export function Settings({ onClose }: { onClose: () => void }) {
  const me = session.value!;
  const k = keys.value!;
  const [devices, setDevices] = useState<DeviceView[]>([]);
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [repeat, setRepeat] = useState('');
  // The password cannot be reset, so a typo in the new one would lock the
  // account: it has to be typed twice. Other devices are signed out by
  // default, which is the point of changing a leaked password.
  const [signOutOthers, setSignOutOthers] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sub, setSub] = useState<'bots' | 'admin' | null>(null);
  const [notifications, setNotifications] = useState(typeof Notification !== 'undefined' ? Notification.permission : 'denied');

  const loadDevices = () =>
    http
      .devices()
      .then((r) => setDevices(r.devices))
      .catch(() => {});
  useEffect(() => void loadDevices(), []);

  const submitPassword = async (e: Event) => {
    e.preventDefault();
    setError(null);
    if (next !== repeat) {
      setError(t('passwords_differ'));
      return;
    }
    try {
      const signedOut = await changePassword(current, next, signOutOthers);
      setCurrent('');
      setNext('');
      setRepeat('');
      showToast(signedOut > 0 ? t('password_changed_signed_out', { n: signedOut }) : t('password_changed'));
      void loadDevices();
    } catch (err) {
      setError(describeError(err));
    }
  };

  if (sub === 'bots') return <BotsDialog onClose={() => setSub(null)} onDone={onClose} />;
  if (sub === 'admin') return <AdminPanel onClose={() => setSub(null)} />;

  return (
    <div class="modal-backdrop" onClick={onClose}>
      <div class="card modal" onClick={(e) => e.stopPropagation()}>
        <div class="modal-head">
          <h2>@{me.username}</h2>
          <button type="button" class="icon-btn" title={t('close')} onClick={onClose}>
            <Icon name="x" size={20} />
          </button>
        </div>
        <div class="section">
          <div class="muted small">{t('your_safety_number')}</div>
          <code class="fp">{fingerprint(k.signPub, k.encPub)}</code>
        </div>
        <label>
          {t('language')}
          <select value={lang.value} onChange={(e) => setLang((e.target as HTMLSelectElement).value)}>
            {Object.entries(languages).map(([code, l]) => (
              <option key={code} value={code}>
                {l.name}
              </option>
            ))}
          </select>
        </label>
        <div class="section">
          <div class="muted small">{t('devices')}</div>
          <ul class="devices">
            {devices.map((d) => (
              <li key={d.id}>
                <span>
                  {d.name}
                  {d.current && <span class="tag ok">{t('this_device')}</span>}
                </span>
                {!d.current && (
                  <button
                    type="button"
                    class="link danger"
                    onClick={() =>
                      http
                        .deleteDevice(d.id)
                        .then(loadDevices)
                        .catch((e) => setError(describeError(e)))
                    }
                  >
                    {t('sign_out_device')}
                  </button>
                )}
              </li>
            ))}
          </ul>
        </div>
        <div class="section">
          <div class="muted small">{t('notifications')}</div>
          {notifications === 'granted' ? (
            <span class="tags">
              <span class="tag ok">{t('enabled')}</span>
            </span>
          ) : (
            <button type="button" onClick={() => Notification.requestPermission().then(setNotifications)} disabled={notifications === 'denied'}>
              {notifications === 'denied' ? t('notifications_blocked') : t('enable_notifications')}
            </button>
          )}
        </div>
        <div class="row wrap">
          {(serverSettings.value?.allow_bots ?? true) && (
            <button type="button" onClick={() => setSub('bots')}>
              <Icon name="bot" size={20} />
              {t('my_bots')}
            </button>
          )}
          {me.isAdmin && (
            <button type="button" onClick={() => setSub('admin')}>
              <Icon name="settings" size={20} />
              {t('admin_panel')}
            </button>
          )}
        </div>
        <form class="section" onSubmit={submitPassword}>
          <div class="muted small">{t('change_password')}</div>
          <label>
            <span>{t('current_password')}</span>
            <input
              type="password"
              aria-label={t('current_password')}
              value={current}
              onInput={(e) => setCurrent((e.target as HTMLInputElement).value)}
              autocomplete="current-password"
            />
          </label>
          <label>
            <span>{t('new_password')}</span>
            <input
              type="password"
              aria-label={t('new_password')}
              value={next}
              onInput={(e) => setNext((e.target as HTMLInputElement).value)}
              autocomplete="new-password"
              minLength={MIN_PASSWORD_LENGTH}
            />
          </label>
          <label>
            <span>{t('repeat_password')}</span>
            <input
              type="password"
              aria-label={t('repeat_password')}
              value={repeat}
              onInput={(e) => setRepeat((e.target as HTMLInputElement).value)}
              autocomplete="new-password"
            />
          </label>
          <label class="check">
            <input type="checkbox" checked={signOutOthers} onChange={(e) => setSignOutOthers((e.target as HTMLInputElement).checked)} />
            {t('sign_out_other_devices')}
          </label>
          <p class="hint">{t('password_warning')}</p>
          <button type="submit" class={authBusy.value ? 'primary busy' : 'primary'} disabled={!current || !next || !repeat || !!authBusy.value}>
            {authBusy.value ? (
              <>
                <span class="spinner" />
                {authBusy.value}
              </>
            ) : (
              t('change_password')
            )}
          </button>
        </form>
        {error && (
          <div class="error">
            <Icon name="alert" size={16} />
            {error}
          </div>
        )}
        <div class="row between">
          <span class="muted small">
            {t('server')} {serverVersion.value}
          </span>
          <button type="button" class="danger" onClick={() => void logout()}>
            <Icon name="log-out" size={20} />
            {t('sign_out')}
          </button>
        </div>
      </div>
    </div>
  );
}
