package store

import (
	"context"
	"database/sql"
	"errors"
)

// Device is a logged-in client of an account. Devices hold no key material of
// their own; they are only authentication sessions (PROTOCOL.md §3).
type Device struct {
	ID        string
	AccountID string
	Name      string
	TokenHash []byte
	PushToken string
	CreatedAt int64
	LastSeen  int64
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func insertDevice(ctx context.Context, x execer, d *Device) error {
	var push any
	if d.PushToken != "" {
		push = d.PushToken
	}
	_, err := x.ExecContext(ctx, `INSERT INTO devices (id, account_id, name, token_hash, push_token, created_at, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		d.ID, d.AccountID, d.Name, d.TokenHash, push, d.CreatedAt, d.LastSeen)
	return err
}

// CreateDevice registers a new device session.
func (s *Store) CreateDevice(ctx context.Context, d *Device) error {
	return insertDevice(ctx, s.db, d)
}

// DeviceByTokenHash resolves an auth token to its device and account.
func (s *Store) DeviceByTokenHash(ctx context.Context, hash []byte) (*Device, *Account, error) {
	row := s.db.QueryRowContext(ctx, `SELECT d.id, d.account_id, d.name, d.token_hash, COALESCE(d.push_token, ''), d.created_at, d.last_seen, `+
		prefixColumns("a", accountColumns)+
		` FROM devices d JOIN accounts a ON a.id = d.account_id WHERE d.token_hash = ?`, hash)
	var d Device
	var a Account
	err := row.Scan(&d.ID, &d.AccountID, &d.Name, &d.TokenHash, &d.PushToken, &d.CreatedAt, &d.LastSeen,
		&a.ID, &a.Username, &a.DisplayName, &a.Salt, &a.AuthHash, &a.SignPub, &a.EncPub, &a.KeyBundle, &a.CreatedAt, &a.IsAdmin, &a.Disabled, &a.IsBot)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, ErrNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	return &d, &a, nil
}

// DevicesByAccount lists the devices of an account.
func (s *Store) DevicesByAccount(ctx context.Context, accountID string) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, account_id, name, token_hash, COALESCE(push_token, ''), created_at, last_seen FROM devices WHERE account_id = ? ORDER BY created_at`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.ID, &d.AccountID, &d.Name, &d.TokenHash, &d.PushToken, &d.CreatedAt, &d.LastSeen); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// DeleteDevice removes a device session of the given account.
func (s *Store) DeleteDevice(ctx context.Context, accountID, deviceID string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM devices WHERE id = ? AND account_id = ?`, deviceID, accountID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// TouchDevice updates the last-seen timestamp.
func (s *Store) TouchDevice(ctx context.Context, deviceID string, ts int64) error {
	_, err := s.db.ExecContext(ctx, `UPDATE devices SET last_seen = ? WHERE id = ?`, ts, deviceID)
	return err
}
