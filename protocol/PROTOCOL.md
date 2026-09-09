# Messenger E2E protocol, version 1

This document is the single source of truth for the cryptographic protocol and
the wire formats. The Go package `pkg/e2e` is the reference implementation; the
web (TypeScript) and mobile (Dart) clients must produce byte-identical results
for the shared test vectors in `protocol/testvectors/`.

All integers are big-endian. `||` denotes concatenation. Sizes are in bytes.

## 1. Primitives

| Purpose | Primitive | Go | TypeScript | Dart |
|---|---|---|---|---|
| Key agreement | X25519 (RFC 7748) | `crypto/ecdh` | `@noble/curves/ed25519.js` (`x25519`) | `sodium` (`crypto_scalarmult`) |
| Signatures | Ed25519 (RFC 8032), 32-byte seed keys | `crypto/ed25519` | `@noble/curves/ed25519.js` (`ed25519`) | `sodium` (`crypto_sign`) |
| AEAD | XChaCha20-Poly1305 (24-byte nonce, 16-byte tag) | `x/crypto/chacha20poly1305.NewX` | `@noble/ciphers/chacha.js` | `sodium` (`crypto_aead_xchacha20poly1305_ietf`) |
| KDF | HKDF-SHA256 (RFC 5869) | `crypto/hkdf` | `@noble/hashes/hkdf.js` | `sodium` (`crypto_kdf_hkdf_sha256`) |
| Password hashing | Argon2id (RFC 9106) | `x/crypto/argon2` | `hash-wasm` | `sodium` (`crypto_pwhash`) |
| Hash | SHA-256 | `crypto/sha256` | `@noble/hashes/sha2.js` | `sodium` (`crypto_hash_sha256`) |

Randomness always comes from the platform CSPRNG (`crypto/rand`,
`crypto.getRandomValues`, `sodium.randombytes_buf`).

## 2. Identifiers

Accounts, devices, conversations and messages are identified by 16-byte IDs
(UUID bytes). In JSON they are written as lowercase UUID strings
(`8-4-4-4-12`); in binary structures they are the raw 16 bytes. The server
generates account, device and conversation IDs (UUIDv7); clients generate
message IDs (`client_msg_id`, UUIDv4).

## 3. Account keys

Every account owns exactly one long-term key pair set, shared by all of the
account's devices:

- `sign_seed` (32) → Ed25519 key pair, public key `sign_pub` (32).
- `enc_priv` (32) → X25519 key pair, public key `enc_pub` (32).

The keys are generated on the client at registration and never leave the client
in the clear.

### 3.1 Password-derived keys

```
salt     = random(16)                       (generated at registration, stored by the server)
out      = Argon2id(password=UTF-8(password), salt, t=3, m=65536 KiB, p=1, tagLength=64)
authKey  = out[0:32]                        (sent to the server as the login secret)
encKey   = out[32:64]                       (never leaves the client)
```

The password is used exactly as typed (no normalisation, no trimming). The
server stores `auth_hash = SHA-256(authKey)` and compares in constant time. The
server never learns `password` or `encKey`.

For an unknown username `GET /auth/params` returns a deterministic fake salt
`HMAC-SHA256(server_secret, username)[0:16]` so that account existence is not
revealed.

### 3.2 Key bundle (encrypted backup of the private keys)

```
nonce  = random(24)
bundle = nonce || XChaCha20-Poly1305(key=encKey, nonce, aad="msgr-keybundle-v1",
                                     plaintext = sign_seed || enc_priv)
```

`bundle` is exactly 104 bytes and is stored by the server next to the public
keys. On login the client downloads it, decrypts it with `encKey`, derives the
public keys from the secrets and **must** check that they equal the public keys
returned by the server. A password change re-encrypts the bundle with the new
`encKey` and replaces `salt`, `auth_hash` and `bundle` atomically.

### 3.3 Fingerprint (safety number)

```
fp = SHA-256("msgr-fp-v1" || sign_pub || enc_pub)[0:16]
```

Displayed as 32 lowercase hex characters in 8 groups of 4 separated by single
spaces, e.g. `3f1a 9c0e 77b2 …`. Two users compare fingerprints out of band and
mark the contact as verified locally.

## 4. Sealed key (`msgr-seal-v1`)

Encrypts a 32-byte message key to one recipient account. Output is exactly 80
bytes.

```
eph_priv = random(32); eph_pub = X25519(eph_priv, basepoint)
ss       = X25519(eph_priv, recipient_enc_pub)         (must not be all zeros)
key      = HKDF-SHA256(ikm=ss, salt=eph_pub || recipient_enc_pub, info="msgr-seal-v1", L=32)
aad      = conv_id (16) || recipient_account_id (16)
box      = eph_pub || XChaCha20-Poly1305(key, nonce=0x00*24, aad, plaintext=message_key)
```

The all-zero nonce is safe because `key` is unique per ephemeral key. The
recipient recomputes `ss = X25519(enc_priv, eph_pub)` and the same `key`.

## 5. Message envelope

Every message (chat text, membership event, call signaling) is one envelope.
A fresh random 32-byte `message_key` encrypts the plaintext; the key is sealed
to every recipient account. The sender always includes its own account as a
recipient so its other devices can read the message.

```
offset  size  field
0       1     version = 0x01
1       1     flags: bit0 EPHEMERAL (server relays but does not store)
                     bit1 URGENT    (call: ring all devices, high-priority push)
2       16    conv_id
18      16    sender_account_id
34      16    sender_device_id
50      16    client_msg_id          (idempotency key, unique per sender account)
66      8     ts_ms                  (sender clock, milliseconds since Unix epoch)
74      2     n_recipients           (1 ≤ n ≤ 100)
76      96×n  recipients: account_id (16) || sealed_key (80)
+0      24    nonce
+24     4     ct_len                 (= len(plaintext) + 16)
+28     ct    ciphertext
```

```
aad = envelope[0 : offset of ct_len]          (everything through the nonce)
ct  = XChaCha20-Poly1305(message_key, nonce, aad, plaintext)
sig = Ed25519.sign(sender sign key, "msgr-env-v1" || envelope)
```

Limits: envelope ≤ 65536 bytes, ≤ 100 recipients. Larger payloads (files) use
attachments (future).

Wire form (WebSocket and HTTP): `{"env": "<base64>", "sig": "<base64>"}` with
standard base64 (RFC 4648, with padding). The server adds `seq` (per-conversation
sequence number assigned by the server) and `server_ts`.

### 5.1 Server checks

The server parses the envelope header without decrypting anything:

1. `version == 1`, sizes consistent, `n_recipients` within limits.
2. `sender_account_id` and `sender_device_id` equal the authenticated device.
3. The signature verifies under the sender's stored `sign_pub`.
4. Every recipient account is a current member of `conv_id`, and the sender is a
   member.
5. `client_msg_id` has not been seen from this sender (duplicates return the
   original `seq`).

Non-ephemeral envelopes are stored verbatim and delivered to every device of
every member. Ephemeral envelopes are relayed to currently connected devices
only.

### 5.2 Client processing

1. Parse; look up the sender's public keys (see §7); verify `sig`.
2. Find own `account_id` in the recipients, open the sealed key, decrypt with the
   AAD. Any failure → the message is shown as undecryptable, never as text.
3. Drop the envelope if `(sender_account_id, client_msg_id)` was already seen.
4. Apply the plaintext by type (§6). Unknown types are ignored.

Messages are ordered by the server `seq`; `ts_ms` is display information only.

## 6. Plaintext payloads

UTF-8 JSON objects with a `t` field. Public keys are standard base64.

| `t` | Fields | Notes |
|---|---|---|
| `text` | `body` (string), optional `reply` (client_msg_id) | Chat message |
| `conv.create` | `kind` (`direct`/`group`), `name`, `members[]` = `{id, username, sign_pub, enc_pub}` | Sent by the creator; `members` includes the creator |
| `member.add` | `member` = `{id, username, sign_pub, enc_pub}`, `members[]` = the full roster after the change | Sent by an owner after the server-side add; sealed to the new member too |
| `member.remove` | `id`, `members[]` = the remaining roster | Sent by an owner (or by the leaving member) **before** the server-side removal; sealed to the removed member too |
| `conv.rename` | `name` | |
| `conv.retention` | `seconds` (0 = off) | Signed record of a disappearing-messages change; the server-side timer is set with `PUT /conversations/{id}/retention` |
| `file` | `blob`, `key`, `nonce`, `name`, `mime`, `size`, optional `thumb` (base64 JPEG ≤ 40 KB), `width`, `height` | Attachment, see §6.1 |
| `call.offer` | `call` (uuid), `sdp` | EPHEMERAL + URGENT, `direct` conversations only |
| `call.answer` | `call`, `sdp` | EPHEMERAL + URGENT; other devices of the callee stop ringing |
| `call.ice` | `call`, `candidates[]` = `{candidate, sdpMid, sdpMLineIndex}` | EPHEMERAL |
| `call.reject` | `call`, `reason` (`declined`/`busy`/`timeout`) | EPHEMERAL + URGENT |
| `call.hangup` | `call` | EPHEMERAL + URGENT |

Every membership event carries the complete roster, so a device that joins
later or syncs from scratch reconstructs membership from the latest event
alone. Clients seal new messages to that roster intersected with the server's
member list (falling back to the server list while no signed event has been
received yet), always including themselves, and flag server members that no
signed event vouches for as unverified.

### 6.1 Attachments

Files never reach the server in the clear:

```
key   = random(32); nonce = random(24)
blob  = XChaCha20-Poly1305(key, nonce, aad="msgr-blob-v1", file bytes)   (ciphertext || tag)
```

The client uploads `blob` with `POST /conversations/{id}/blobs` (raw body,
size limited by the server setting `max_attachment_bytes`) and receives a
blob id; `key`, `nonce` and the metadata travel inside the `file` payload of
a normal envelope. Members download `GET /blobs/{id}` and decrypt locally.
The server stores only the blob id, the conversation, the uploader and the
size, enforces membership on download and deletes blobs together with
expired messages.

### 6.2 Disappearing messages

A conversation may carry a retention timer (`retention_seconds`, set by any
member of a direct chat or by the group owner). The server deletes stored
envelopes and blobs older than the timer, an administrator may cap all
conversations with a server-wide limit, and clients delete their local copies
on the same schedule. The timer is server-visible metadata; the signed
`conv.retention` event records who changed it. As with any messenger, a
recipient who copied a message before it expired still has it.

## 7. Key discovery and trust

Public keys are fetched from the server (`GET /users/{username}`,
`GET /conversations/{id}`, and inside membership events). The first key seen for
an account is trusted (TOFU) and cached locally with a `verified` flag set by
fingerprint comparison. If the server or an event ever presents different keys
for a known account, the client blocks sending to that account until the user
explicitly accepts the new keys.

## 8. Transport summary

- HTTPS JSON API under `/api/v1`, bearer device token.
- WebSocket `/api/v1/ws` with JSON frames `{"t": type, "d": data}`:
  client → server `send` `{env, sig}`; server → client `ack` `{client_msg_id, seq}`,
  `message` `{conv_id, seq, env, sig, server_ts}`, `signal` `{env, sig}` (ephemeral),
  `event` `{kind, ...}`.
- Calls: WebRTC 1:1, DTLS-SRTP. Because the SDP (with the DTLS fingerprint)
  travels inside signed and encrypted envelopes, the server cannot substitute
  media keys. ICE servers: STUN plus TURN with time-limited credentials from
  `GET /turn` (`username = "<expiry>:<account_id>"`,
  `credential = base64(HMAC-SHA1(turn_secret, username))`).

## 9. Bots

A bot is an account whose keys are held by the server (`bots` table). The
server bridges the bot's conversations to plain JSON: it decrypts envelopes
addressed to the bot, queues them as updates (polled by the bot or pushed to
its webhook with an HMAC-SHA256 signature) and signs and encrypts the bot's
replies with the bot's keys exactly like a client would. To every other
participant a bot is an ordinary account; clients mark bots with a badge and
warn that the server can read conversations that include one. The Bot API is
described in `docs/BOTS.md`.

## 10. Security properties and limits

- Confidentiality and integrity of message content end to end; the server sees
  metadata only (participants, sizes, timing, flags).
- No forward secrecy against compromise of the account keys: by design the
  server keeps ciphertext so that new devices can read history. Mitigations:
  strong password policy (≥ 12 characters), Argon2id with 64 MiB, and planned
  retention limits / recovery keys.
- Compromise of one device compromises the account keys (all devices share
  them). Rotating account keys is not supported in v1.
- Sender authenticity comes from the Ed25519 signature; the server cannot forge
  or re-route messages (`conv_id` and sender are signed) but can drop or delay
  them.
- Trust on first use: verify fingerprints to rule out key substitution by the
  server.
- Conversations that include a bot are readable by the server by design (§9).
- Disappearing messages and server-side retention limit how long ciphertext
  is stored; they cannot prevent a recipient from keeping a copy.
