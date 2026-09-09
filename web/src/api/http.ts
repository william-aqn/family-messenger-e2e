import type {
  AdminSettings,
  AdminStats,
  AdminUser,
  ApiSession,
  BotView,
  ConversationView,
  DeviceView,
  DirectoryUser,
  IceServer,
  InviteView,
  KdfParams,
  MeView,
  MessageView,
  SendResult,
  ServerInfo,
  UserView,
} from './types';

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
  ) {
    super(message);
  }
}

let token: string | null = null;

export function setToken(t: string | null): void {
  token = t;
}

export function getToken(): string | null {
  return token;
}

function authHeaders(extra?: Record<string, string>): Record<string, string> {
  const headers: Record<string, string> = { Accept: 'application/json', ...(extra ?? {}) };
  if (token) headers.Authorization = `Bearer ${token}`;
  return headers;
}

async function toError(res: Response): Promise<ApiError> {
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    /* non-JSON error page */
  }
  return new ApiError(res.status, data?.error?.code ?? 'error', data?.error?.message ?? res.statusText);
}

export async function api<T>(method: string, path: string, body?: unknown): Promise<T> {
  const headers = authHeaders();
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  let res: Response;
  try {
    res = await fetch(`/api/v1${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch {
    throw new ApiError(0, 'network', 'Cannot reach the server');
  }
  if (!res.ok) throw await toError(res);
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

/** Raw request returning bytes (attachments, backups). */
export async function apiBytes(method: string, path: string, body?: Uint8Array): Promise<{ bytes: Uint8Array; filename?: string }> {
  const headers = authHeaders();
  if (body) headers['Content-Type'] = 'application/octet-stream';
  let res: Response;
  try {
    res = await fetch(`/api/v1${path}`, { method, headers, body: body as BodyInit | undefined });
  } catch {
    throw new ApiError(0, 'network', 'Cannot reach the server');
  }
  if (!res.ok) throw await toError(res);
  const disposition = res.headers.get('Content-Disposition') ?? '';
  const match = /filename="([^"]+)"/.exec(disposition);
  return { bytes: new Uint8Array(await res.arrayBuffer()), filename: match?.[1] };
}

export const http = {
  info: () => api<ServerInfo>('GET', '/info'),
  authParams: (username: string) => api<{ salt: string; kdf: KdfParams }>('GET', `/auth/params?username=${encodeURIComponent(username)}`),
  register: (body: Record<string, unknown>) => api<ApiSession>('POST', '/auth/register', body),
  login: (body: Record<string, unknown>) => api<ApiSession>('POST', '/auth/login', body),
  logout: () => api<void>('POST', '/auth/logout'),
  changePassword: (body: Record<string, unknown>) => api<void>('POST', '/auth/password', body),
  me: () => api<MeView>('GET', '/me'),
  deleteDevice: (id: string) => api<void>('DELETE', `/devices/${id}`),
  user: (username: string) => api<UserView>('GET', `/users/${encodeURIComponent(username)}`),
  users: (prefix: string) => api<{ users: DirectoryUser[] }>('GET', `/users?q=${encodeURIComponent(prefix)}&limit=200`),
  conversations: () => api<{ conversations: ConversationView[] }>('GET', '/conversations'),
  conversation: (id: string) => api<ConversationView>('GET', `/conversations/${id}`),
  createDirect: (accountId: string) => api<ConversationView>('POST', '/conversations', { kind: 'direct', account_id: accountId }),
  createGroup: (memberIds: string[]) => api<ConversationView>('POST', '/conversations', { kind: 'group', member_ids: memberIds }),
  addMember: (convId: string, accountId: string) => api<ConversationView>('POST', `/conversations/${convId}/members`, { account_id: accountId }),
  removeMember: (convId: string, accountId: string) => api<void>('DELETE', `/conversations/${convId}/members/${accountId}`),
  messages: (convId: string, after: number, limit = 200) =>
    api<{ messages: MessageView[]; has_more: boolean; last_seq: number }>('GET', `/conversations/${convId}/messages?after=${after}&limit=${limit}`),
  send: (convId: string, env: string, sig: string) => api<SendResult>('POST', `/conversations/${convId}/messages`, { env, sig }),
  markRead: (convId: string, seq: number) => api<void>('PUT', `/conversations/${convId}/read`, { seq }),
  setRetention: (convId: string, seconds: number) => api<void>('PUT', `/conversations/${convId}/retention`, { seconds }),
  uploadBlob: async (convId: string, data: Uint8Array) => {
    const headers = authHeaders({ 'Content-Type': 'application/octet-stream' });
    let res: Response;
    try {
      res = await fetch(`/api/v1/conversations/${convId}/blobs`, { method: 'POST', headers, body: data as BodyInit });
    } catch {
      throw new ApiError(0, 'network', 'Cannot reach the server');
    }
    if (!res.ok) throw await toError(res);
    return (await res.json()) as { id: string; size: number };
  },
  downloadBlob: async (id: string) => (await apiBytes('GET', `/blobs/${id}`)).bytes,
  turn: () => api<{ ice_servers: IceServer[]; ttl: number }>('GET', '/turn'),
  devices: () => api<{ devices: DeviceView[] }>('GET', '/devices'),

  bots: () => api<{ bots: BotView[] }>('GET', '/bots'),
  createBot: (body: { username: string; display_name: string; webhook_url: string }) =>
    api<{ bot: BotView; token: string; webhook_secret: string }>('POST', '/bots', body),
  updateBot: (id: string, body: { display_name?: string; webhook_url?: string }) => api<BotView>('PATCH', `/bots/${id}`, body),
  rotateBot: (id: string) => api<{ token: string; webhook_secret: string }>('POST', `/bots/${id}/rotate`),
  deleteBot: (id: string) => api<void>('DELETE', `/bots/${id}`),

  adminStats: () => api<AdminStats>('GET', '/admin/stats'),
  adminSettings: () => api<AdminSettings>('GET', '/admin/settings'),
  adminSaveSettings: (s: AdminSettings) => api<AdminSettings>('PUT', '/admin/settings', s),
  adminUsers: (q: string) => api<{ users: AdminUser[] }>('GET', `/admin/users?q=${encodeURIComponent(q)}&limit=200`),
  adminPatchUser: (id: string, body: { disabled?: boolean; is_admin?: boolean }) => api<AdminUser>('PATCH', `/admin/users/${id}`, body),
  adminDeleteUser: (id: string) => api<void>('DELETE', `/admin/users/${id}`),
  adminLogoutUser: (id: string) => api<void>('POST', `/admin/users/${id}/logout`),
  adminInvites: () => api<{ invites: InviteView[] }>('GET', '/admin/invites'),
  adminCreateInvites: (body: { count: number; note: string; expires_hours: number }) => api<{ codes: string[] }>('POST', '/admin/invites', body),
  adminDeleteInvite: (code: string) => api<void>('DELETE', `/admin/invites/${code}`),
  adminBackup: () => apiBytes('POST', '/admin/backup'),
};
