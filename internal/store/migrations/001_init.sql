CREATE TABLE accounts (
  id         TEXT PRIMARY KEY,
  username   TEXT NOT NULL UNIQUE,
  salt       BLOB NOT NULL,
  auth_hash  BLOB NOT NULL,
  sign_pub   BLOB NOT NULL,
  enc_pub    BLOB NOT NULL,
  key_bundle BLOB NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE devices (
  id         TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  token_hash BLOB NOT NULL UNIQUE,
  push_token TEXT,
  created_at INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL
);
CREATE INDEX devices_account ON devices(account_id);

CREATE TABLE invites (
  code       TEXT PRIMARY KEY,
  created_by TEXT,
  created_at INTEGER NOT NULL,
  used_by    TEXT REFERENCES accounts(id),
  used_at    INTEGER
);

CREATE TABLE conversations (
  id         TEXT PRIMARY KEY,
  kind       TEXT NOT NULL CHECK (kind IN ('direct', 'group')),
  direct_key TEXT UNIQUE,
  created_by TEXT NOT NULL REFERENCES accounts(id),
  created_at INTEGER NOT NULL,
  last_seq   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE members (
  conv_id    TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  role       TEXT NOT NULL CHECK (role IN ('owner', 'member')),
  joined_seq INTEGER NOT NULL DEFAULT 0,
  read_seq   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (conv_id, account_id)
);
CREATE INDEX members_account ON members(account_id);

CREATE TABLE messages (
  conv_id        TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  seq            INTEGER NOT NULL,
  sender_account TEXT NOT NULL,
  sender_device  TEXT NOT NULL,
  client_id      TEXT NOT NULL,
  env            BLOB NOT NULL,
  sig            BLOB NOT NULL,
  server_ts      INTEGER NOT NULL,
  PRIMARY KEY (conv_id, seq),
  UNIQUE (sender_account, client_id)
);
