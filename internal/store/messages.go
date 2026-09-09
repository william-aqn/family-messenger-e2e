package store

import (
	"context"
	"database/sql"
	"errors"
)

// Message is a stored envelope. The server never sees its plaintext.
type Message struct {
	ConvID        string
	Seq           int64
	SenderAccount string
	SenderDevice  string
	ClientID      string
	Env           []byte
	Sig           []byte
	ServerTS      int64
}

type querier interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

// validateSend checks that sender and every recipient are members and returns
// the full member list for fan-out.
func validateSend(ctx context.Context, q querier, convID, sender string, recipients []string) ([]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT account_id FROM members WHERE conv_id = ?`, convID)
	if err != nil {
		return nil, err
	}
	members := make([]string, 0, 8)
	set := make(map[string]struct{}, 8)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		members = append(members, id)
		set[id] = struct{}{}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if _, ok := set[sender]; !ok {
		return nil, ErrNotMember
	}
	for _, r := range recipients {
		if _, ok := set[r]; !ok {
			return nil, ErrRecipient
		}
	}
	return members, nil
}

// ValidateSend performs the membership checks for an ephemeral (unstored)
// envelope and returns the member list.
func (s *Store) ValidateSend(ctx context.Context, convID, sender string, recipients []string) ([]string, error) {
	return validateSend(ctx, s.db, convID, sender, recipients)
}

// AppendMessage validates membership, assigns the next sequence number and
// stores the envelope. Re-sending the same client id returns the original
// sequence number with duplicate=true.
func (s *Store) AppendMessage(ctx context.Context, m *Message, recipients []string) (seq int64, duplicate bool, members []string, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, false, nil, err
	}
	defer tx.Rollback()
	members, err = validateSend(ctx, tx, m.ConvID, m.SenderAccount, recipients)
	if err != nil {
		return 0, false, nil, err
	}
	var existingConv string
	err = tx.QueryRowContext(ctx, `SELECT conv_id, seq FROM messages WHERE sender_account = ? AND client_id = ?`, m.SenderAccount, m.ClientID).Scan(&existingConv, &seq)
	if err == nil {
		if existingConv != m.ConvID {
			return 0, false, nil, ErrConvMismatch
		}
		return seq, true, members, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil, err
	}
	var lastSeq int64
	if err := tx.QueryRowContext(ctx, `SELECT last_seq FROM conversations WHERE id = ?`, m.ConvID).Scan(&lastSeq); err != nil {
		return 0, false, nil, err
	}
	seq = lastSeq + 1
	if _, err := tx.ExecContext(ctx, `INSERT INTO messages (conv_id, seq, sender_account, sender_device, client_id, env, sig, server_ts) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		m.ConvID, seq, m.SenderAccount, m.SenderDevice, m.ClientID, m.Env, m.Sig, m.ServerTS); err != nil {
		return 0, false, nil, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE conversations SET last_seq = ? WHERE id = ?`, seq, m.ConvID); err != nil {
		return 0, false, nil, err
	}
	if err := tx.Commit(); err != nil {
		return 0, false, nil, err
	}
	m.Seq = seq
	return seq, false, members, nil
}

// Messages returns up to limit messages with seq > max(after, minSeq) in
// ascending order.
func (s *Store) Messages(ctx context.Context, convID string, after, minSeq, limit int64) ([]Message, error) {
	if after < minSeq {
		after = minSeq
	}
	rows, err := s.db.QueryContext(ctx, `SELECT conv_id, seq, sender_account, sender_device, client_id, env, sig, server_ts FROM messages WHERE conv_id = ? AND seq > ? ORDER BY seq LIMIT ?`, convID, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ConvID, &m.Seq, &m.SenderAccount, &m.SenderDevice, &m.ClientID, &m.Env, &m.Sig, &m.ServerTS); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
