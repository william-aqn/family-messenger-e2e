import { useEffect } from 'preact/hooks';
import { wsClient } from '../api/ws';
import { t } from '../i18n';
import { call } from '../state/calls';
import { selectedId, serverSettings, session, toast } from '../state/model';
import { booting } from '../state/session';
import { voice } from '../state/voice';
import { CallOverlay } from './CallOverlay';
import { VoiceOverlay } from './VoiceOverlay';
import { ChatView } from './ChatView';
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

  if (booting.value) return <div class="center muted">{t('loading')}</div>;
  if (!session.value) return <Login />;
  const announcement = serverSettings.value?.announcement;
  return (
    <div class={`app ${selectedId.value ? 'has-selection' : ''}`}>
      <Sidebar />
      <ChatView />
      {call.value && <CallOverlay />}
      {voice.value && <VoiceOverlay />}
      {toast.value && <div class="toast">{toast.value}</div>}
      {wsClient.status.value !== 'online' && <div class="banner">{wsClient.status.value === 'connecting' ? t('connecting') : t('offline')}</div>}
      {announcement && <div class="announcement">{announcement}</div>}
    </div>
  );
}
