// Wire types of the server's JSON API. Byte fields are standard base64.

export interface KdfParams {
  t: number;
  m: number;
  p: number;
}

export interface ApiSession {
  account_id: string;
  username: string;
  device_id: string;
  token: string;
  sign_pub: string;
  enc_pub: string;
  key_bundle: string;
  salt: string;
  kdf: KdfParams;
  is_admin: boolean;
}

export interface MemberView {
  id: string;
  username: string;
  display_name?: string;
  role: 'owner' | 'member';
  joined_seq: number;
  sign_pub: string;
  enc_pub: string;
  is_bot?: boolean;
}

export interface ConversationView {
  id: string;
  kind: 'direct' | 'group';
  created_by: string;
  created_at: number;
  last_seq: number;
  read_seq: number;
  joined_seq: number;
  role: 'owner' | 'member';
  retention_seconds: number;
  members: MemberView[];
}

export interface MessageView {
  conv_id: string;
  seq: number;
  sender_account: string;
  sender_device: string;
  client_msg_id: string;
  env: string;
  sig: string;
  server_ts: number;
}

export interface UserView {
  id: string;
  username: string;
  display_name?: string;
  sign_pub: string;
  enc_pub: string;
  is_bot?: boolean;
}

export interface SendResult {
  conv_id: string;
  client_msg_id: string;
  seq: number;
  server_ts: number;
  duplicate?: boolean;
  ephemeral?: boolean;
}

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export interface DeviceView {
  id: string;
  name: string;
  created_at: number;
  last_seen: number;
  current: boolean;
}

export interface ServerSettings {
  registration: 'open' | 'invite' | 'closed';
  announcement: string;
  allow_bots: boolean;
  max_attachment_bytes: number;
  max_group_members: number;
  retention_days: number;
}

export interface MeView {
  account: { id: string; username: string; display_name: string; sign_pub: string; enc_pub: string; created_at: number; is_admin: boolean; is_bot: boolean };
  device_id: string;
  devices: DeviceView[];
  settings: ServerSettings;
  version: string;
}

export interface ServerInfo {
  registration: 'open' | 'invite' | 'closed';
  announcement: string;
  version: string;
}

export interface EventPayload {
  kind: string;
  conv_id?: string;
  actor?: string;
  account?: string;
  seq?: number;
}

/** A member as carried inside signed membership events (PROTOCOL.md §6). */
export interface MemberInfo {
  id: string;
  username: string;
  sign_pub: string;
  enc_pub: string;
}

export interface FilePayload {
  t: 'file';
  blob: string;
  key: string;
  nonce: string;
  name: string;
  mime: string;
  size: number;
  thumb?: string; // base64 JPEG thumbnail for images
  width?: number;
  height?: number;
}

export type Payload =
  | { t: 'text'; body: string; reply?: string }
  | FilePayload
  | { t: 'conv.create'; kind: 'direct' | 'group'; name?: string; members: MemberInfo[] }
  | { t: 'member.add'; member: MemberInfo; members: MemberInfo[] }
  | { t: 'member.remove'; id: string; members: MemberInfo[] }
  | { t: 'conv.rename'; name: string }
  | { t: 'conv.retention'; seconds: number }
  | { t: 'call.offer'; call: string; sdp: string }
  | { t: 'call.answer'; call: string; sdp: string }
  | { t: 'call.ice'; call: string; candidates: RTCIceCandidateInit[] }
  | { t: 'call.reject'; call: string; reason: string }
  | { t: 'call.hangup'; call: string }
  | { t: 'call.share'; call: string; on: boolean };

// Bots
export interface BotView {
  id: string;
  username: string;
  display_name: string;
  webhook_url: string;
  created_at: number;
  sign_pub: string;
  enc_pub: string;
}

// Admin
export interface AdminStats {
  accounts: number;
  bots: number;
  conversations: number;
  messages: number;
  blobs: number;
  blob_bytes: number;
  devices: number;
  invites: number;
  unused_invites: number;
  online_devices: number;
  db_bytes: number;
  uptime_seconds: number;
  version: string;
  go_version: string;
  turn_enabled: boolean;
}

export interface AdminSettings {
  registration: 'open' | 'invite' | 'closed';
  max_attachment_bytes: number;
  retention_days: number;
  allow_bots: boolean;
  max_group_members: number;
  announcement: string;
}

export interface AdminUser {
  id: string;
  username: string;
  display_name: string;
  created_at: number;
  last_seen: number;
  devices: number;
  online: boolean;
  is_admin: boolean;
  disabled: boolean;
  is_bot: boolean;
  owner_username?: string;
}

export interface InviteView {
  code: string;
  note: string;
  created_at: number;
  used_by?: string;
  used_at?: number;
  expires_at?: number;
}
