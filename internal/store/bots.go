package store

import (
	"context"
	"database/sql"
	"errors"
)

// Bot is a server-side bot bridge: the server holds the bot's keys and
// translates between the encrypted conversation and plain JSON webhooks.
type Bot struct {
	AccountID     string
	OwnerID       string
	DeviceID      string
	WebhookURL    string
	WebhookSecret string
	SignSeed      []byte
	EncPriv       []byte
	CreatedAt     int64
	// Joined from accounts.
	Username    string
	DisplayName string
	SignPub     []byte
	EncPub      []byte
	Disabled    bool
}

const botColumns = `b.account_id, b.owner_id, b.device_id, b.webhook_url, b.webhook_secret, b.sign_seed, b.enc_priv, b.created_at, a.username, a.display_name, a.sign_pub, a.enc_pub, a.disabled`

func scanBot(row interface{ Scan(...any) error }) (*Bot, error) {
	var b Bot
	if err := row.Scan(&b.AccountID, &b.OwnerID, &b.DeviceID, &b.WebhookURL, &b.WebhookSecret, &b.SignSeed, &b.EncPriv, &b.CreatedAt, &b.Username, &b.DisplayName, &b.SignPub, &b.EncPub, &b.Disabled); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &b, nil
}

// CreateBot inserts the bot account, its bridge device and the bot row.
func (s *Store) CreateBot(ctx context.Context, a *Account, d *Device, b *Bot) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := insertAccount(ctx, tx, a); err != nil {
		return err
	}
	if err := insertDevice(ctx, tx, d); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO bots (account_id, owner_id, device_id, webhook_url, webhook_secret, sign_seed, enc_priv, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		b.AccountID, b.OwnerID, b.DeviceID, b.WebhookURL, b.WebhookSecret, b.SignSeed, b.EncPriv, b.CreatedAt); err != nil {
		return err
	}
	return tx.Commit()
}

// BotByAccount returns the bot with the given account id.
func (s *Store) BotByAccount(ctx context.Context, accountID string) (*Bot, error) {
	return scanBot(s.db.QueryRowContext(ctx, `SELECT `+botColumns+` FROM bots b JOIN accounts a ON a.id = b.account_id WHERE b.account_id = ?`, accountID))
}

// BotsByOwner lists the bots a user created.
func (s *Store) BotsByOwner(ctx context.Context, ownerID string) ([]Bot, error) {
	return s.queryBots(ctx, `SELECT `+botColumns+` FROM bots b JOIN accounts a ON a.id = b.account_id WHERE b.owner_id = ? ORDER BY b.created_at`, ownerID)
}

// BotsAmong returns the bots whose account ids are in ids.
func (s *Store) BotsAmong(ctx context.Context, ids []string) ([]Bot, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	return s.queryBots(ctx, `SELECT `+botColumns+` FROM bots b JOIN accounts a ON a.id = b.account_id WHERE b.account_id IN (`+placeholders(len(ids))+`)`, stringArgs(ids)...)
}

func (s *Store) queryBots(ctx context.Context, query string, args ...any) ([]Bot, error) {
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Bot
	for rows.Next() {
		b, err := scanBot(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *b)
	}
	return out, rows.Err()
}

// UpdateBot changes the display name and webhook URL.
func (s *Store) UpdateBot(ctx context.Context, accountID, displayName, webhookURL string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `UPDATE bots SET webhook_url = ? WHERE account_id = ?`, webhookURL, accountID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `UPDATE accounts SET display_name = ? WHERE id = ?`, displayName, accountID); err != nil {
		return err
	}
	return tx.Commit()
}

// RotateBotCredentials replaces the bridge device token hash and the webhook secret.
func (s *Store) RotateBotCredentials(ctx context.Context, accountID string, tokenHash []byte, secret string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var deviceID string
	if err := tx.QueryRowContext(ctx, `SELECT device_id FROM bots WHERE account_id = ?`, accountID).Scan(&deviceID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE bots SET webhook_secret = ? WHERE account_id = ?`, secret, accountID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE devices SET token_hash = ? WHERE id = ?`, tokenHash, deviceID); err != nil {
		return err
	}
	return tx.Commit()
}

// AddBotUpdate queues an update for the bot and returns its id.
func (s *Store) AddBotUpdate(ctx context.Context, botID string, createdAt int64, payload string) (int64, error) {
	res, err := s.db.ExecContext(ctx, `INSERT INTO bot_updates (bot_id, created_at, payload) VALUES (?, ?, ?)`, botID, createdAt, payload)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// BotUpdate is a queued update as stored.
type BotUpdate struct {
	ID        int64
	CreatedAt int64
	Payload   string
}

// BotUpdates returns up to limit updates with id > after.
func (s *Store) BotUpdates(ctx context.Context, botID string, after int64, limit int) ([]BotUpdate, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, created_at, payload FROM bot_updates WHERE bot_id = ? AND id > ? ORDER BY id LIMIT ?`, botID, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BotUpdate
	for rows.Next() {
		var u BotUpdate
		if err := rows.Scan(&u.ID, &u.CreatedAt, &u.Payload); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// PurgeBotUpdates deletes updates created before the given time.
func (s *Store) PurgeBotUpdates(ctx context.Context, before int64) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM bot_updates WHERE created_at < ?`, before)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}
