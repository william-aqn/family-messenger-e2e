import { useEffect, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { DeviceView } from '../api/types';
import { fingerprint } from '../crypto/fingerprint';
import { describeError, lang, languages, setLang, t } from '../i18n';
import { serverSettings, serverVersion, session, showToast } from '../state/model';
import { authBusy, changePassword, keys, logout } from '../state/session';
import { AdminPanel } from './AdminPanel';
import { BotsDialog } from './BotsDialog';

export function Settings({ onClose }: { onClose: () => void }) {
  const me = session.value!;
  const k = keys.value!;
  const [devices, setDevices] = useState<DeviceView[]>([]);
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
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
    try {
      await changePassword(current, next);
      setCurrent('');
      setNext('');
      showToast(t('password_changed'));
    } catch (err) {
      setError(describeError(err));
    }
  };

  if (sub === 'bots') return <BotsDialog onClose={() => setSub(null)} onDone={onClose} />;
  if (sub === 'admin') return <AdminPanel onClose={() => setSub(null)} />;

  return (
    <div class="modal-backdrop" onClick={onClose}>
      <div class="card modal" onClick={(e) => e.stopPropagation()}>
        <h2>@{me.username}</h2>
        <div class="section">
          <div class="muted small">{t('your_safety_number')}</div>
          <code class="fp">{fingerprint(k.signPub, k.encPub)}</code>
        </div>
        <div class="section">
          <div class="muted small">{t('language')}</div>
          <select value={lang.value} onChange={(e) => setLang((e.target as HTMLSelectElement).value)}>
            {Object.entries(languages).map(([code, l]) => (
              <option key={code} value={code}>
                {l.name}
              </option>
            ))}
          </select>
        </div>
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
                    class="link"
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
            <span class="tag ok">{t('enabled')}</span>
          ) : (
            <button onClick={() => Notification.requestPermission().then(setNotifications)} disabled={notifications === 'denied'}>
              {notifications === 'denied' ? t('notifications_blocked') : t('enable_notifications')}
            </button>
          )}
        </div>
        <div class="section row wrap">
          {(serverSettings.value?.allow_bots ?? true) && <button onClick={() => setSub('bots')}>🤖 {t('my_bots')}</button>}
          {me.isAdmin && <button onClick={() => setSub('admin')}>🛠 {t('admin_panel')}</button>}
        </div>
        <form class="section" onSubmit={submitPassword}>
          <div class="muted small">{t('change_password')}</div>
          <input type="password" placeholder={t('current_password')} value={current} onInput={(e) => setCurrent((e.target as HTMLInputElement).value)} autocomplete="current-password" />
          <input type="password" placeholder={t('new_password')} value={next} onInput={(e) => setNext((e.target as HTMLInputElement).value)} autocomplete="new-password" />
          <button type="submit" disabled={!current || !next || !!authBusy.value}>
            {authBusy.value ?? t('change_password')}
          </button>
        </form>
        {error && <div class="error">{error}</div>}
        <div class="row between">
          <span class="muted small">
            {t('server')} {serverVersion.value}
          </span>
          <div class="row">
            <button class="danger" onClick={() => void logout()}>
              {t('sign_out')}
            </button>
            <button onClick={onClose}>{t('close')}</button>
          </div>
        </div>
      </div>
    </div>
  );
}
