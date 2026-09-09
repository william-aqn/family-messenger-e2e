ALTER TABLE accounts ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN is_bot INTEGER NOT NULL DEFAULT 0;
ALTER TABLE accounts ADD COLUMN display_name TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN deleted_at INTEGER;

ALTER TABLE invites ADD COLUMN note TEXT NOT NULL DEFAULT '';
ALTER TABLE invites ADD COLUMN expires_at INTEGER;

ALTER TABLE conversations ADD COLUMN retention_seconds INTEGER NOT NULL DEFAULT 0;

CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE bots (
  account_id     TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  owner_id       TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id      TEXT NOT NULL,
  webhook_url    TEXT NOT NULL DEFAULT '',
  webhook_secret TEXT NOT NULL,
  sign_seed      BLOB NOT NULL,
  enc_priv       BLOB NOT NULL,
  created_at     INTEGER NOT NULL
);
CREATE INDEX bots_owner ON bots(owner_id);

CREATE TABLE bot_updates (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  bot_id     TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  payload    TEXT NOT NULL
);
CREATE INDEX bot_updates_bot ON bot_updates(bot_id, id);

CREATE TABLE blobs (
  id         TEXT PRIMARY KEY,
  conv_id    TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  uploader   TEXT NOT NULL,
  size       INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX blobs_conv ON blobs(conv_id);
