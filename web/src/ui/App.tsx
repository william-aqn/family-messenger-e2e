import { useEffect } from 'preact/hooks';
import { wsClient } from '../api/ws';
import { t } from '../i18n';
import { call } from '../state/calls';
import { selectedId, serverSettings, serverVersion, session, toast, updateAvailable } from '../state/model';
import { booting } from '../state/session';
import { dbBlocked } from '../store/db';
import { voice } from '../state/voice';
import { CallOverlay } from './CallOverlay';
import { VoiceOverlay } from './VoiceOverlay';
import { ChatView } from './ChatView';
import { Icon, IconSprite } from './Icons';
import { Login } from './Login';
import { Sidebar } from './Sidebar';

export function App() {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') selectedId.value = null;
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  // The sprite is mounted in every branch: an <Icon> is a <use> reference and
  // renders nothing without it, and the loading and login screens use icons too.
  if (booting.value)
    return (
      <>
        <IconSprite />
        <div class="center">
          <div class="placeholder">
            <Icon name="lock" size={24} />
            <span class="muted">{t('loading')}</span>
            {dbBlocked.value && (
              <div class="banner alert">
                <Icon name="alert" size={20} />
                <span class="grow">{t('db_blocked')}</span>
              </div>
            )}
          </div>
        </div>
      </>
    );
  if (!session.value)
    return (
      <>
        <IconSprite />
        <Login />
      </>
    );
  const announcement = serverSettings.value?.announcement;
  const status = wsClient.status.value;
  return (
    <>
      <IconSprite />
      <div class={`app ${selectedId.value ? 'has-selection' : ''}`}>
        <Sidebar />
        <ChatView />
        {call.value && <CallOverlay />}
        {voice.value && <VoiceOverlay />}
        {toast.value && <div class="toast">{toast.value}</div>}
        {status === 'connecting' && (
          <div class="banner busy floating">
            <span class="spinner muted" />
            {t('connecting')}
          </div>
        )}
        {status !== 'connecting' && status !== 'online' && (
          <div class="banner alert floating">
            <Icon name="wifi-off" size={20} />
            {t('offline')}
          </div>
        )}
        {updateAvailable.value && (
          <div class="banner update floating bottom">
            <Icon name="refresh" size={20} />
            <span class="grow">{t('update_available', { version: serverVersion.value })}</span>
            <button type="button" class="link strong" onClick={() => location.reload()}>
              {t('reload_page')}
            </button>
          </div>
        )}
        {announcement && (
          <div class="announcement">
            <Icon name="info" size={20} />
            <span class="grow">{announcement}</span>
          </div>
        )}
      </div>
    </>
  );
}
