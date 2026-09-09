import { signal } from '@preact/signals';

export type ConnectionStatus = 'offline' | 'connecting' | 'online';

type Handler = (data: any) => void;

/** WebSocket client with first-frame auth and exponential reconnect. */
export class WsClient {
  readonly status = signal<ConnectionStatus>('offline');
  private socket: WebSocket | null = null;
  private handlers = new Map<string, Set<Handler>>();
  private token = '';
  private stopped = true;
  private attempt = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;

  connect(token: string): void {
    this.token = token;
    this.stopped = false;
    this.attempt = 0;
    this.open();
  }

  close(): void {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.socket?.close();
    this.socket = null;
    this.status.value = 'offline';
  }

  on(type: string, handler: Handler): () => void {
    let set = this.handlers.get(type);
    if (!set) {
      set = new Set();
      this.handlers.set(type, set);
    }
    set.add(handler);
    return () => set!.delete(handler);
  }

  send(type: string, data?: unknown): boolean {
    if (this.socket?.readyState !== WebSocket.OPEN) return false;
    this.socket.send(JSON.stringify({ t: type, d: data }));
    return true;
  }

  private open(): void {
    if (this.stopped) return;
    this.status.value = 'connecting';
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const socket = new WebSocket(`${proto}://${location.host}/api/v1/ws`);
    this.socket = socket;
    socket.onopen = () => socket.send(JSON.stringify({ t: 'auth', d: { token: this.token } }));
    socket.onmessage = (ev) => {
      let frame: { t: string; d?: unknown };
      try {
        frame = JSON.parse(String(ev.data));
      } catch {
        return;
      }
      if (frame.t === 'hello') {
        this.attempt = 0;
        this.status.value = 'online';
      }
      for (const h of this.handlers.get(frame.t) ?? []) {
        try {
          h(frame.d);
        } catch (e) {
          console.error('ws handler failed', frame.t, e);
        }
      }
    };
    socket.onclose = () => {
      if (this.socket === socket) this.socket = null;
      this.status.value = 'offline';
      if (this.stopped) return;
      const delay = Math.min(30000, 1000 * 2 ** this.attempt) * (0.7 + Math.random() * 0.6);
      this.attempt = Math.min(this.attempt + 1, 6);
      this.timer = setTimeout(() => this.open(), delay);
    };
    socket.onerror = () => socket.close();
  }
}

export const wsClient = new WsClient();
