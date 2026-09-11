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
  /** Set on a deletion record (PROTOCOL.md §6.3): the message at that seq was removed by sender_account. */
  deleted_seq?: number;
  deleted_sender?: string;
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
  /** Members may list users and get name suggestions (admin setting, default on). */
  user_directory: boolean;
}

export interface DirectoryUser {
  id: string;
  username: string;
  display_name: string;
  is_bot: boolean;
  /** Absent when the account hides its presence, or has never signed in. */
  online?: boolean;
  last_seen?: number;
}

export interface Visibility {
  find_me_in_search: boolean;
  show_online: boolean;
  allow_group_add: boolean;
}

export interface MeView {
  account: {
    id: string;
    username: string;
    display_name: string;
    sign_pub: string;
    enc_pub: string;
    created_at: number;
    is_admin: boolean;
    is_bot: boolean;
  } & Visibility;
  device_id: string;
  devices: DeviceView[];
  settings: ServerSettings;
  version: string;
}

export interface ServerInfo {
  registration: 'open' | 'invite' | 'closed';
  announcement: string;
  user_directory: boolean;
  version: string;
}

export interface EventPayload {
  kind: string;
  conv_id?: string;
  actor?: string;
  account?: string;
  seq?: number;
  /** password.changed: which device made the change, and when. */
  device_id?: string;
  at?: number;
  proof?: string;
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
  // Rewrites the sender's own earlier text message `ref` (PROTOCOL.md §6.3).
  | { t: 'text.edit'; ref: string; body: string }
  | FilePayload
  | { t: 'conv.create'; kind: 'direct' | 'group'; name?: string; members: MemberInfo[] }
  | { t: 'member.add'; member: MemberInfo; members: MemberInfo[] }
  | { t: 'member.remove'; id: string; members: MemberInfo[] }
  | { t: 'conv.rename'; name: string }
  | { t: 'conv.retention'; seconds: number }
  // Offers and answers are retransmitted until the call connects; the repeats
  // carry every ICE candidate gathered so far, so a lost signal does no harm.
  | { t: 'call.offer'; call: string; sdp: string; video?: boolean; candidates?: RTCIceCandidateInit[] }
  | { t: 'call.answer'; call: string; sdp: string; video?: boolean; candidates?: RTCIceCandidateInit[] }
  | { t: 'call.video'; call: string; on: boolean }
  | { t: 'call.ice'; call: string; candidates: RTCIceCandidateInit[] }
  | { t: 'call.reject'; call: string; reason: string }
  | { t: 'call.hangup'; call: string }
  | { t: 'call.share'; call: string; on: boolean }
  // Group voice channel (mesh); `session` identifies one participant, `to` the target session.
  | { t: 'voice.join'; session: string; muted: boolean; sharing?: boolean }
  | { t: 'voice.here'; session: string; muted: boolean; sharing?: boolean }
  | { t: 'voice.share'; session: string; on: boolean }
  | { t: 'voice.leave'; session: string }
  | { t: 'voice.offer'; session: string; to: string; sdp: string }
  | { t: 'voice.answer'; session: string; to: string; sdp: string }
  | { t: 'voice.ice'; session: string; to: string; candidates: RTCIceCandidateInit[] };

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
  /** Newest published release (empty until the server checked GitHub). */
  latest_version: string;
  latest_url: string;
  /** The running build is a published release (a tag), not a development build. */
  is_release: boolean;
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
  user_directory: boolean;
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
