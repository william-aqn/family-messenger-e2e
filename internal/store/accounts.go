package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"
)

// Account is a registered user or bot. The server never sees private keys of
// users: KeyBundle is the client-encrypted backup (PROTOCOL.md §3.2). Bots
// have empty password material; their keys live in the bots table.
type Account struct {
	ID          string
	Username    string
	DisplayName string
	Salt        []byte
	AuthHash    []byte
	SignPub     []byte
	EncPub      []byte
	KeyBundle   []byte
	CreatedAt   int64
	IsAdmin     bool
	Disabled    bool
	IsBot       bool
}

const accountColumns = `id, username, display_name, salt, auth_hash, sign_pub, enc_pub, key_bundle, created_at, is_admin, disabled, is_bot`

func scanAccount(row interface{ Scan(...any) error }) (*Account, error) {
	var a Account
	if err := row.Scan(&a.ID, &a.Username, &a.DisplayName, &a.Salt, &a.AuthHash, &a.SignPub, &a.EncPub, &a.KeyBundle, &a.CreatedAt, &a.IsAdmin, &a.Disabled, &a.IsBot); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &a, nil
}

func insertAccount(ctx context.Context, x execer, a *Account) error {
	_, err := x.ExecContext(ctx, `INSERT INTO accounts (`+accountColumns+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.ID, a.Username, a.DisplayName, a.Salt, a.AuthHash, a.SignPub, a.EncPub, a.KeyBundle, a.CreatedAt, a.IsAdmin, a.Disabled, a.IsBot)
	if isUniqueViolation(err) {
		return ErrConflict
	}
	return err
}

// CreateAccount inserts an account together with its first device. When
// requireInvite is set the invite code must exist, be unused and unexpired;
// it is consumed in the same transaction. The very first human account of a
// server becomes an administrator.
func (s *Store) CreateAccount(ctx context.Context, a *Account, d *Device, invite string, requireInvite bool) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var existing int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE is_bot = 0 AND deleted_at IS NULL`).Scan(&existing); err != nil {
		return err
	}
	if existing == 0 && !a.IsBot {
		a.IsAdmin = true
	}
	if err := insertAccount(ctx, tx, a); err != nil {
		return err
	}
	if requireInvite {
		// The account row must exist first: invites.used_by references it.
		now := time.Now().Unix()
		res, err := tx.ExecContext(ctx, `UPDATE invites SET used_by = ?, used_at = ? WHERE code = ? AND used_by IS NULL AND (expires_at IS NULL OR expires_at > ?)`, a.ID, now, invite, now)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n != 1 {
			return ErrInvite // rolls back the account insert
		}
	}
	if err := insertDevice(ctx, tx, d); err != nil {
		return err
	}
	return tx.Commit()
}

// AccountByUsername looks up an account by its (lowercase) username.
func (s *Store) AccountByUsername(ctx context.Context, username string) (*Account, error) {
	return scanAccount(s.db.QueryRowContext(ctx, `SELECT `+accountColumns+` FROM accounts WHERE username = ? AND deleted_at IS NULL`, username))
}

// AccountByID looks up an account by id.
func (s *Store) AccountByID(ctx context.Context, id string) (*Account, error) {
	return scanAccount(s.db.QueryRowContext(ctx, `SELECT `+accountColumns+` FROM accounts WHERE id = ? AND deleted_at IS NULL`, id))
}

// AccountsByIDs returns the accounts that exist among ids (order unspecified).
func (s *Store) AccountsByIDs(ctx context.Context, ids []string) ([]Account, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+accountColumns+` FROM accounts WHERE deleted_at IS NULL AND id IN (`+placeholders(len(ids))+`)`, stringArgs(ids)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Account
	for rows.Next() {
		a, err := scanAccount(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *a)
	}
	return out, rows.Err()
}

// UpdatePassword replaces the password-derived material of an account and,
// in the same transaction, signs out every device except keep (pass an empty
// keep to leave the sessions alone). It returns the ids of the devices it
// removed, so the caller can close their sockets after the commit.
//
// The generation it replaces is kept in prev_* (migration 004): a password
// change cannot be undone by the account itself, and since it no longer
// needs the old password, the server's owner needs a way back.
func (s *Store) UpdatePassword(ctx context.Context, id string, salt, authHash, keyBundle []byte, keep string) ([]string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `UPDATE accounts SET
			prev_salt = salt, prev_auth_hash = auth_hash, prev_key_bundle = key_bundle,
			salt = ?, auth_hash = ?, key_bundle = ?, password_changed_at = ?
		WHERE id = ? AND deleted_at IS NULL`,
		salt, authHash, keyBundle, time.Now().Unix(), id)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, ErrNotFound
	}
	if keep == "" {
		return nil, tx.Commit()
	}
	rows, err := tx.QueryContext(ctx, `SELECT id FROM devices WHERE account_id = ? AND id <> ?`, id, keep)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, d)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM devices WHERE account_id = ? AND id <> ?`, id, keep); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return ids, nil
}

// AccountSummary is an account as listed in the admin panel.
type AccountSummary struct {
	Account
	LastSeen      int64
	Devices       int
	OwnerUsername string // for bots
}

// ListAccounts returns accounts matching the optional username filter.
func (s *Store) ListAccounts(ctx context.Context, query string, limit, offset int) ([]AccountSummary, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	q := `SELECT ` + prefixColumns("a", accountColumns) + `,
		COALESCE((SELECT MAX(last_seen) FROM devices d WHERE d.account_id = a.id), 0),
		(SELECT COUNT(*) FROM devices d WHERE d.account_id = a.id),
		COALESCE((SELECT o.username FROM bots b JOIN accounts o ON o.id = b.owner_id WHERE b.account_id = a.id), '')
		FROM accounts a`
	args := []any{}
	if query != "" {
		q += ` WHERE a.username LIKE ? ESCAPE '\'`
		args = append(args, "%"+escapeLike(query)+"%")
	}
	if query != "" {
		q += ` AND a.deleted_at IS NULL`
	} else {
		q += ` WHERE a.deleted_at IS NULL`
	}
	q += ` ORDER BY a.created_at, a.id LIMIT ? OFFSET ?`
	args = append(args, limit, offset)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AccountSummary
	for rows.Next() {
		var a AccountSummary
		if err := rows.Scan(&a.ID, &a.Username, &a.DisplayName, &a.Salt, &a.AuthHash, &a.SignPub, &a.EncPub, &a.KeyBundle, &a.CreatedAt, &a.IsAdmin, &a.Disabled, &a.IsBot,
			&a.LastSeen, &a.Devices, &a.OwnerUsername); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func prefixColumns(prefix, cols string) string {
	parts := strings.Split(cols, ", ")
	for i, p := range parts {
		parts[i] = prefix + "." + p
	}
	return strings.Join(parts, ", ")
}

func escapeLike(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(s)
}

// SetAccountFlags updates the administrative flags of an account.
// DirectoryEntry is what every member may learn about another account.
type DirectoryEntry struct {
	ID          string `json:"id"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name"`
	IsBot       bool   `json:"is_bot"`
}

// Directory lists active accounts whose username starts with prefix (all
// accounts for an empty prefix), sorted by username.
func (s *Store) Directory(ctx context.Context, prefix string, limit int) ([]DirectoryEntry, error) {
	if limit <= 0 || limit > 500 {
		limit = 500
	}
	pattern := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(strings.ToLower(prefix)) + "%"
	rows, err := s.db.QueryContext(ctx, `SELECT id, username, display_name, is_bot FROM accounts
		WHERE deleted_at IS NULL AND disabled = 0 AND lower(username) LIKE ? ESCAPE '\'
		ORDER BY username LIMIT ?`, pattern, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []DirectoryEntry{}
	for rows.Next() {
		var e DirectoryEntry
		if err := rows.Scan(&e.ID, &e.Username, &e.DisplayName, &e.IsBot); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *Store) SetAccountFlags(ctx context.Context, id string, disabled, isAdmin bool) error {
	res, err := s.db.ExecContext(ctx, `UPDATE accounts SET disabled = ?, is_admin = ? WHERE id = ?`, disabled, isAdmin, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// DeleteAccount tombstones an account: devices, memberships, bot keys and
// pending bot updates are removed, the username is freed and the row stays
// (disabled, anonymised) so that stored messages and invites keep valid
// references and old signatures remain verifiable.
func (s *Store) DeleteAccount(ctx context.Context, id string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM accounts WHERE id = ? AND deleted_at IS NULL`, id).Scan(&exists); err != nil {
		return err
	}
	if exists == 0 {
		return ErrNotFound
	}
	for _, q := range []string{
		`DELETE FROM devices WHERE account_id = ?`,
		`DELETE FROM members WHERE account_id = ?`,
		`DELETE FROM bots WHERE account_id = ? OR owner_id = ?`,
		`DELETE FROM bot_updates WHERE bot_id = ?`,
	} {
		args := []any{id}
		if strings.Count(q, "?") == 2 {
			args = append(args, id)
		}
		if _, err := tx.ExecContext(ctx, q, args...); err != nil {
			return err
		}
	}
	// Ids are UUIDs, but never let a short one panic the handler.
	flat := strings.ReplaceAll(id, "-", "")
	tombstone := "~deleted-" + flat[:min(12, len(flat))]
	// The previous generation goes with the current one: it holds an earlier
	// key_bundle, which is the account's secrets under an earlier password,
	// and leaving it behind would defeat the point of the tombstone.
	if _, err := tx.ExecContext(ctx, `UPDATE accounts SET username = ?, display_name = '', salt = X'', auth_hash = X'', key_bundle = X'',
			prev_salt = NULL, prev_auth_hash = NULL, prev_key_bundle = NULL,
			is_admin = 0, disabled = 1, deleted_at = ? WHERE id = ?`,
		tombstone, time.Now().Unix(), id); err != nil {
		return err
	}
	return tx.Commit()
}

// DeleteAllDevices signs an account out everywhere and returns the device ids.
func (s *Store) DeleteAllDevices(ctx context.Context, accountID string) ([]string, error) {
	devs, err := s.DevicesByAccount(ctx, accountID)
	if err != nil {
		return nil, err
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM devices WHERE account_id = ?`, accountID); err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(devs))
	for _, d := range devs {
		ids = append(ids, d.ID)
	}
	return ids, nil
}

// Invite is a registration code.
type Invite struct {
	Code           string
	Note           string
	CreatedBy      string
	CreatedAt      int64
	UsedBy         string
	UsedByUsername string
	UsedAt         int64
	ExpiresAt      int64 // 0 = never
}

// CreateInvite stores a new invite code. createdBy may be empty (CLI);
// expiresAt of zero means the code never expires.
func (s *Store) CreateInvite(ctx context.Context, code, createdBy, note string, expiresAt int64) error {
	var by, exp any
	if createdBy != "" {
		by = createdBy
	}
	if expiresAt > 0 {
		exp = expiresAt
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO invites (code, created_by, created_at, note, expires_at) VALUES (?, ?, ?, ?, ?)`, code, by, time.Now().Unix(), note, exp)
	if isUniqueViolation(err) {
		return ErrConflict
	}
	return err
}

// ListInvites returns every invite, newest first.
func (s *Store) ListInvites(ctx context.Context) ([]Invite, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT i.code, i.note, COALESCE(i.created_by, ''), i.created_at, COALESCE(i.used_by, ''), COALESCE(u.username, ''), COALESCE(i.used_at, 0), COALESCE(i.expires_at, 0)
		FROM invites i LEFT JOIN accounts u ON u.id = i.used_by ORDER BY i.created_at DESC, i.code`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Invite
	for rows.Next() {
		var i Invite
		if err := rows.Scan(&i.Code, &i.Note, &i.CreatedBy, &i.CreatedAt, &i.UsedBy, &i.UsedByUsername, &i.UsedAt, &i.ExpiresAt); err != nil {
			return nil, err
		}
		out = append(out, i)
	}
	return out, rows.Err()
}

// DeleteInvite removes an unused invite code.
func (s *Store) DeleteInvite(ctx context.Context, code string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM invites WHERE code = ? AND used_by IS NULL`, code)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// LoadSettings returns every stored setting.
func (s *Store) LoadSettings(ctx context.Context) (map[string]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT key, value FROM settings`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, err
		}
		out[k] = v
	}
	return out, rows.Err()
}

// SaveSettings upserts the given settings.
func (s *Store) SaveSettings(ctx context.Context, kv map[string]string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for k, v := range kv {
		if _, err := tx.ExecContext(ctx, `INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, k, v); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// Stats are the counters shown in the admin overview.
type Stats struct {
	Accounts      int64
	Bots          int64
	Conversations int64
	Messages      int64
	Blobs         int64
	BlobBytes     int64
	Devices       int64
	Invites       int64
	UnusedInvites int64
}

// Stats counts rows for the admin overview.
func (s *Store) Stats(ctx context.Context) (*Stats, error) {
	var st Stats
	err := s.db.QueryRowContext(ctx, `SELECT
		(SELECT COUNT(*) FROM accounts WHERE is_bot = 0 AND deleted_at IS NULL),
		(SELECT COUNT(*) FROM accounts WHERE is_bot = 1 AND deleted_at IS NULL),
		(SELECT COUNT(*) FROM conversations),
		(SELECT COUNT(*) FROM messages WHERE deleted_seq IS NULL),
		(SELECT COUNT(*) FROM blobs),
		COALESCE((SELECT SUM(size) FROM blobs), 0),
		(SELECT COUNT(*) FROM devices),
		(SELECT COUNT(*) FROM invites),
		(SELECT COUNT(*) FROM invites WHERE used_by IS NULL)`).Scan(
		&st.Accounts, &st.Bots, &st.Conversations, &st.Messages, &st.Blobs, &st.BlobBytes, &st.Devices, &st.Invites, &st.UnusedInvites)
	if err != nil {
		return nil, err
	}
	return &st, nil
}

// Backup writes a consistent snapshot of the database to path (VACUUM INTO).
func (s *Store) Backup(ctx context.Context, path string) error {
	_, err := s.db.ExecContext(ctx, `VACUUM INTO ?`, path)
	return err
}
