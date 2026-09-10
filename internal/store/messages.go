package store

import (
	"context"
	"database/sql"
	"errors"
)

// Message is a stored envelope. The server never sees its plaintext.
//
// A row with DeletedSeq set is a deletion record instead of a message: it
// carries no envelope and tells clients that the message at DeletedSeq was
// removed (PROTOCOL.md §6.3). Records take a sequence number of their own so
// that every device learns about the deletion in order, even one that was
// offline when it happened.
type Message struct {
	ConvID        string
	Seq           int64
	SenderAccount string
	SenderDevice  string
	ClientID      string
	Env           []byte
	Sig           []byte
	ServerTS      int64
	DeletedSeq    int64  // deletion records only: the removed message
	DeletedSender string // deletion records only: who had sent it
}

// IsDeletion reports whether the row is a deletion record.
func (m *Message) IsDeletion() bool { return m.DeletedSeq != 0 }

const messageColumns = `conv_id, seq, sender_account, sender_device, client_id, env, sig, server_ts, deleted_seq, deleted_sender`

func scanMessage(row interface{ Scan(...any) error }) (*Message, error) {
	var m Message
	var deletedSeq sql.NullInt64
	var deletedSender sql.NullString
	if err := row.Scan(&m.ConvID, &m.Seq, &m.SenderAccount, &m.SenderDevice, &m.ClientID, &m.Env, &m.Sig, &m.ServerTS, &deletedSeq, &deletedSender); err != nil {
		return nil, err
	}
	m.DeletedSeq = deletedSeq.Int64
	m.DeletedSender = deletedSender.String
	// Empty blobs may scan as nil; clients expect strings, never null.
	if m.Env == nil {
		m.Env = []byte{}
	}
	if m.Sig == nil {
		m.Sig = []byte{}
	}
	return &m, nil
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

// Messages returns up to limit messages (deletion records included) with
// seq > max(after, minSeq) in ascending order.
func (s *Store) Messages(ctx context.Context, convID string, after, minSeq, limit int64) ([]Message, error) {
	if after < minSeq {
		after = minSeq
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+messageColumns+` FROM messages WHERE conv_id = ? AND seq > ? ORDER BY seq LIMIT ?`, convID, after, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		m, err := scanMessage(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *m)
	}
	return out, rows.Err()
}

// Message returns one stored message. Deletion records are not messages and
// come back as ErrNotFound.
func (s *Store) Message(ctx context.Context, convID string, seq int64) (*Message, error) {
	m, err := scanMessage(s.db.QueryRowContext(ctx, `SELECT `+messageColumns+` FROM messages WHERE conv_id = ? AND seq = ? AND deleted_seq IS NULL`, convID, seq))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return m, err
}

// DeleteMessage removes a stored message and appends a deletion record in
// its place at the next sequence number, attributed to actor. It returns the
// record, or ErrNotFound when there is no such message (records included).
func (s *Store) DeleteMessage(ctx context.Context, convID string, seq int64, actor, actorDevice, recordID string, now int64) (*Message, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var sender string
	err = tx.QueryRowContext(ctx, `SELECT sender_account FROM messages WHERE conv_id = ? AND seq = ? AND deleted_seq IS NULL`, convID, seq).Scan(&sender)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM messages WHERE conv_id = ? AND seq = ?`, convID, seq); err != nil {
		return nil, err
	}
	var lastSeq int64
	if err := tx.QueryRowContext(ctx, `SELECT last_seq FROM conversations WHERE id = ?`, convID).Scan(&lastSeq); err != nil {
		return nil, err
	}
	rec := &Message{ConvID: convID, Seq: lastSeq + 1, SenderAccount: actor, SenderDevice: actorDevice, ClientID: recordID, Env: []byte{}, Sig: []byte{}, ServerTS: now, DeletedSeq: seq, DeletedSender: sender}
	if _, err := tx.ExecContext(ctx, `INSERT INTO messages (conv_id, seq, sender_account, sender_device, client_id, env, sig, server_ts, deleted_seq, deleted_sender) VALUES (?, ?, ?, ?, ?, X'', X'', ?, ?, ?)`,
		rec.ConvID, rec.Seq, rec.SenderAccount, rec.SenderDevice, rec.ClientID, rec.ServerTS, rec.DeletedSeq, rec.DeletedSender); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE conversations SET last_seq = ? WHERE id = ?`, rec.Seq, convID); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return rec, nil
}
