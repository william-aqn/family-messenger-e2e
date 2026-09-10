import { signal } from '@preact/signals';

export type ConnectionStatus = 'offline' | 'connecting' | 'online';

type Handler = (data: any) => void;

/** A ping goes out after this much silence; the server answers with a pong. */
const PING_AFTER_MS = 15_000;
/** A socket silent for this long is dead: a sleeping laptop or a network change leaves it half open. */
const DEAD_AFTER_MS = 35_000;
/** After a poke (the tab became visible again) a pong must arrive this fast. */
const POKE_DEADLINE_MS = 5_000;

/**
 * WebSocket client with first-frame auth, exponential reconnect and an
 * application-level keepalive. Outgoing messages travel over HTTP, so the
 * socket is the only place where a dead connection shows; without the
 * keepalive a half-open socket would keep the page deaf to messages and
 * call signals while it can still send.
 */
export class WsClient {
  readonly status = signal<ConnectionStatus>('offline');
  private socket: WebSocket | null = null;
  private handlers = new Map<string, Set<Handler>>();
  private token = '';
  private stopped = true;
  private attempt = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private keepalive: ReturnType<typeof setInterval> | null = null;
  private lastFrame = 0;
  private pingSent = 0;

  constructor() {
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') this.poke();
      });
      window.addEventListener('online', () => this.poke());
    }
  }

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
    this.stopKeepalive();
    const socket = this.socket;
    this.socket = null;
    socket?.close();
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

  /** Checks the connection right away: reconnects a socket waiting out its backoff, pings an open one and expects a prompt pong. */
  poke(): void {
    if (this.stopped) return;
    if (!this.socket) {
      if (this.timer) clearTimeout(this.timer);
      this.timer = null;
      this.attempt = 0;
      this.open();
      return;
    }
    if (this.socket.readyState !== WebSocket.OPEN) return; // still connecting: the liveness check times it out
    const sentAt = Date.now();
    this.pingSent = sentAt;
    this.send('ping');
    setTimeout(() => {
      if (this.socket && this.lastFrame < sentAt) this.reopen();
    }, POKE_DEADLINE_MS);
  }

  private open(): void {
    if (this.stopped) return;
    this.status.value = 'connecting';
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const socket = new WebSocket(`${proto}://${location.host}/api/v1/ws`);
    this.socket = socket;
    this.lastFrame = Date.now();
    this.pingSent = 0;
    this.stopKeepalive();
    this.keepalive = setInterval(() => this.checkLiveness(), 5000);
    socket.onopen = () => socket.send(JSON.stringify({ t: 'auth', d: { token: this.token } }));
    socket.onmessage = (ev) => {
      this.lastFrame = Date.now();
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
      if (this.socket !== socket) return; // already replaced by reopen() or closed
      this.socket = null;
      this.stopKeepalive();
      this.status.value = 'offline';
      if (this.stopped) return;
      const delay = Math.min(30000, 1000 * 2 ** this.attempt) * (0.7 + Math.random() * 0.6);
      this.attempt = Math.min(this.attempt + 1, 6);
      this.timer = setTimeout(() => this.open(), delay);
    };
    socket.onerror = () => socket.close();
  }

  /** Pings a quiet socket and drops one that stopped answering; a socket that never says hello times out the same way. */
  private checkLiveness(): void {
    if (!this.socket) return;
    const now = Date.now();
    const silence = now - this.lastFrame;
    if (silence > DEAD_AFTER_MS) {
      this.reopen();
      return;
    }
    if (silence >= PING_AFTER_MS && now - this.pingSent >= PING_AFTER_MS) {
      this.pingSent = now;
      this.send('ping');
    }
  }

  /** Replaces a dead socket with a fresh connection at once (no backoff). */
  private reopen(): void {
    const socket = this.socket;
    this.socket = null;
    this.stopKeepalive();
    socket?.close();
    if (this.stopped) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.attempt = 0;
    this.open();
  }

  private stopKeepalive(): void {
    if (this.keepalive) clearInterval(this.keepalive);
    this.keepalive = null;
  }
}

export const wsClient = new WsClient();
