import { useEffect, useState } from 'preact/hooks';
import { http } from '../api/http';
import type { DeviceView, Visibility as VisibilityFlags } from '../api/types';
import { wsClient } from '../api/ws';
import { fingerprint } from '../crypto/fingerprint';
import { describeError, lang, languages, setLang, t } from '../i18n';
import { setUiScale, uiScale, uiScales } from '../state/appearance';
import { serverSettings, serverVersion, session, showToast, visibility } from '../state/model';
import { authBusy, changePassword, keys, logout, MIN_PASSWORD_LENGTH } from '../state/session';
import { AdminPanel } from './AdminPanel';
import { BotsDialog } from './BotsDialog';
import { Icon } from './Icons';

/**
 * The smallest copy helper: BotsDialog has one, but it is a whole <CopyField>
 * row local to that file, and this board draws a bare icon button.
 */
function copyToClipboard(value: string) {
  navigator.clipboard
    .writeText(value)
    .then(() => showToast(t('copied')))
    .catch(() => {});
}

export function Settings({ onClose }: { onClose: () => void }) {
  const me = session.value!;
  const k = keys.value!;
  const [devices, setDevices] = useState<DeviceView[]>([]);
  const [next, setNext] = useState('');
  const [repeat, setRepeat] = useState('');
  // No current password is asked for: this device proves itself with the
  // account keys it already holds (PROTOCOL.md §3.2), which is what lets
  // somebody who forgot the password set a new one. The password cannot be
  // reset, so a typo in the new one would lock the account and it has to be
  // typed twice. Other devices are signed out by default, which is the point
  // of changing a leaked password.
  const [signOutOthers, setSignOutOthers] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [sub, setSub] = useState<'bots' | 'admin' | null>(null);
  const [notifications, setNotifications] = useState(typeof Notification !== 'undefined' ? Notification.permission : 'denied');

  const vis = visibility.value;
  /**
   * Optimistic: the checkbox moves at once and the server's answer replaces
   * it. A refusal puts the old value back — it is one flag, not a form.
   */
  const setVisibility = (patch: Partial<VisibilityFlags>) => {
    const before = visibility.value;
    if (before) visibility.value = { ...before, ...patch };
    http
      .patchMe(patch)
      .then((v) => (visibility.value = v))
      .catch((e) => {
        visibility.value = before;
        showToast(describeError(e));
      });
  };

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
      const signedOut = await changePassword(next, signOutOthers);
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

  const fp = fingerprint(k.signPub, k.encPub);
  const status = wsClient.status.value;

  return (
    <div class="modal-backdrop" onClick={onClose}>
      <div class="card modal" onClick={(e) => e.stopPropagation()}>
        <div class="modal-head">
          <h2>{t('settings')}</h2>
          <button type="button" class="icon-btn" title={t('close')} onClick={onClose}>
            <Icon name="x" size={20} />
          </button>
        </div>

        <div class="settings-account">
          <span class={`dot ${status}`} title={status} />
          <span>@{me.username}</span>
        </div>

        <div class="section tight">
          <span class="field-label">{t('your_safety_number')}</span>
          <p class="hint">{t('safety_number_hint')}</p>
          <div class="fp-row">
            <code class="fp">{fp}</code>
            <button type="button" class="icon-btn boxed" title={t('copy')} onClick={() => copyToClipboard(fp)}>
              <Icon name="copy" size={16} />
            </button>
          </div>
        </div>

        {/* Stays the first <select> of the modal — the e2e suite picks it that way. */}
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

        {/* Buttons and not a <select>: the modal's first one belongs to the
            language above, and a letter at each size says more than a list. */}
        <div class="section tight">
          <div class="row">
            <span class="field-label grow">{t('ui_scale')}</span>
            <span class="note">{Math.round(uiScale.value * 100)}%</span>
          </div>
          <div class="size-steps">
            {uiScales.map((scale) => (
              <button
                key={scale}
                type="button"
                class={scale === uiScale.value ? 'size-step active' : 'size-step'}
                style={{ fontSize: `${12 * scale}px` }}
                aria-pressed={scale === uiScale.value}
                aria-label={`${Math.round(scale * 100)}%`}
                title={`${Math.round(scale * 100)}%`}
                onClick={() => setUiScale(scale)}
              >
                {t('ui_scale_sample')}
              </button>
            ))}
          </div>
          {/* The page is already drawn at the chosen scale, so a real bubble
              is the preview — no copy of the sizes to keep in step. */}
          <div class="size-preview">
            <div class="bubble">
              <div class="body">{t('ui_scale_preview')}</div>
              <div class="meta">
                <span>{new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
              </div>
            </div>
          </div>
        </div>

        {/* Server-enforced policy, not protocol: the server reads these in
            plaintext and could ignore them (PROTOCOL.md §10). */}
        <div class="section">
          <span class="field-label">{t('visibility')}</span>
          <label class="check">
            <input type="checkbox" checked={vis?.find_me_in_search ?? true} disabled={!vis} onChange={(e) => setVisibility({ find_me_in_search: (e.target as HTMLInputElement).checked })} />
            {t('find_me_in_search')}
          </label>
          <p class="hint">{t('find_me_in_search_hint')}</p>
          <label class="check">
            <input type="checkbox" checked={vis?.show_online ?? true} disabled={!vis} onChange={(e) => setVisibility({ show_online: (e.target as HTMLInputElement).checked })} />
            {t('show_online')}
          </label>
          <label class="check">
            <input type="checkbox" checked={vis?.allow_group_add ?? true} disabled={!vis} onChange={(e) => setVisibility({ allow_group_add: (e.target as HTMLInputElement).checked })} />
            {t('allow_group_add')}
          </label>
        </div>

        <div class="section">
          <span class="field-label">{t('devices')}</span>
          <ul class="devices">
            {devices.map((d) => (
              <li key={d.id}>
                <span class="grow ellipsis">{d.name}</span>
                {d.current ? (
                  <span class="tag faint">{t('this_device')}</span>
                ) : (
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

        <div class="row wrap">
          <span class="field-label grow">{t('notifications')}</span>
          {notifications === 'granted' ? (
            <span class="tags">
              <span class="tag ok">{t('enabled')}</span>
            </span>
          ) : (
            <>
              {notifications === 'denied' && <span class="note">{t('notifications_blocked')}</span>}
              <button type="button" class="small" onClick={() => Notification.requestPermission().then(setNotifications)} disabled={notifications === 'denied'}>
                {t('enable_notifications')}
              </button>
            </>
          )}
        </div>

        <div class="btn-row">
          {(serverSettings.value?.allow_bots ?? true) && (
            <button type="button" onClick={() => setSub('bots')}>
              <Icon name="bot" size={16} />
              {t('my_bots')}
            </button>
          )}
          {me.isAdmin && (
            <button type="button" onClick={() => setSub('admin')}>
              <Icon name="settings" size={16} />
              {t('admin_panel')}
            </button>
          )}
        </div>

        <form class="section ruled" onSubmit={submitPassword}>
          <span class="block-title">{t('change_password')}</span>
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
          <div class="banner alert">
            <Icon name="alert" size={20} />
            <span class="grow">{t('password_change_warning')}</span>
          </div>
          <button type="submit" class={authBusy.value ? 'primary busy' : 'primary'} disabled={!next || !repeat || !!authBusy.value}>
            {authBusy.value ? (
              <>
                <span class="spinner" />
                {authBusy.value}
              </>
            ) : (
              t('change_password')
            )}
          </button>
          {error && (
            <div class="error">
              <Icon name="alert" size={16} />
              {error}
            </div>
          )}
        </form>

        <div class="row ruled">
          <span class="muted small grow">
            {t('server')} {serverVersion.value}
          </span>
          <button type="button" class="danger" onClick={() => void logout()}>
            {t('sign_out')}
          </button>
          <button type="button" onClick={onClose}>
            {t('close')}
          </button>
        </div>
      </div>
    </div>
  );
}
