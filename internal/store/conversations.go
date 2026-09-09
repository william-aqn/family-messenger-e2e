package store

import (
	"context"
	"database/sql"
	"errors"
)

// Conversation is a direct chat or a group. The server stores no name: names
// travel inside signed end-to-end events.
type Conversation struct {
	ID               string
	Kind             string // "direct" or "group"
	CreatedBy        string
	CreatedAt        int64
	LastSeq          int64
	RetentionSeconds int64 // 0 = keep forever
}

// Member is an account's membership in a conversation, joined with the
// account's public identity.
type Member struct {
	ConvID      string
	AccountID   string
	Role        string // "owner" or "member"
	JoinedSeq   int64
	ReadSeq     int64
	Username    string
	DisplayName string
	SignPub     []byte
	EncPub      []byte
	IsBot       bool
}

// ConversationWithMembers is a conversation as seen by one account.
type ConversationWithMembers struct {
	Conversation
	Members []Member
	Me      Member
}

func directKey(a, b string) string {
	if a > b {
		a, b = b, a
	}
	return a + ":" + b
}

// CreateDirect returns the direct conversation between a and b, creating it
// if needed. created reports whether a new conversation was inserted.
func (s *Store) CreateDirect(ctx context.Context, newID, a, b string, now int64) (id string, created bool, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", false, err
	}
	defer tx.Rollback()
	key := directKey(a, b)
	err = tx.QueryRowContext(ctx, `SELECT id FROM conversations WHERE direct_key = ?`, key).Scan(&id)
	if err == nil {
		return id, false, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return "", false, err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO conversations (id, kind, direct_key, created_by, created_at, last_seq) VALUES (?, 'direct', ?, ?, ?, 0)`, newID, key, a, now); err != nil {
		return "", false, err
	}
	for _, m := range []string{a, b} {
		if _, err := tx.ExecContext(ctx, `INSERT INTO members (conv_id, account_id, role, joined_seq, read_seq) VALUES (?, ?, 'member', 0, 0)`, newID, m); err != nil {
			return "", false, err
		}
	}
	return newID, true, tx.Commit()
}

// CreateGroup creates a group with creator as owner and the given members.
func (s *Store) CreateGroup(ctx context.Context, id, creator string, members []string, now int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO conversations (id, kind, direct_key, created_by, created_at, last_seq) VALUES (?, 'group', NULL, ?, ?, 0)`, id, creator, now); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO members (conv_id, account_id, role, joined_seq, read_seq) VALUES (?, ?, 'owner', 0, 0)`, id, creator); err != nil {
		return err
	}
	for _, m := range uniqueStrings(members) {
		if m == creator {
			continue
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO members (conv_id, account_id, role, joined_seq, read_seq) VALUES (?, ?, 'member', 0, 0)`, id, m); err != nil {
			return err
		}
	}
	return tx.Commit()
}

const convColumns = `c.id, c.kind, c.created_by, c.created_at, c.last_seq, c.retention_seconds, m.account_id, m.role, m.joined_seq, m.read_seq`

func scanConv(row interface{ Scan(...any) error }) (*ConversationWithMembers, error) {
	var c ConversationWithMembers
	if err := row.Scan(&c.ID, &c.Kind, &c.CreatedBy, &c.CreatedAt, &c.LastSeq, &c.RetentionSeconds, &c.Me.AccountID, &c.Me.Role, &c.Me.JoinedSeq, &c.Me.ReadSeq); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	c.Me.ConvID = c.ID
	return &c, nil
}

// ConversationsForAccount lists every conversation the account belongs to,
// with all members.
func (s *Store) ConversationsForAccount(ctx context.Context, accountID string) ([]ConversationWithMembers, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+convColumns+` FROM conversations c JOIN members m ON m.conv_id = c.id WHERE m.account_id = ? ORDER BY c.created_at, c.id`, accountID)
	if err != nil {
		return nil, err
	}
	var convs []ConversationWithMembers
	for rows.Next() {
		c, err := scanConv(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		convs = append(convs, *c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(convs) == 0 {
		return nil, nil
	}
	ids := make([]string, len(convs))
	for i := range convs {
		ids[i] = convs[i].ID
	}
	members, err := s.membersOf(ctx, ids)
	if err != nil {
		return nil, err
	}
	for i := range convs {
		convs[i].Members = members[convs[i].ID]
	}
	return convs, nil
}

// ConversationForAccount returns one conversation if the account is a member;
// otherwise ErrNotFound (membership is not revealed).
func (s *Store) ConversationForAccount(ctx context.Context, convID, accountID string) (*ConversationWithMembers, error) {
	c, err := scanConv(s.db.QueryRowContext(ctx, `SELECT `+convColumns+` FROM conversations c JOIN members m ON m.conv_id = c.id WHERE c.id = ? AND m.account_id = ?`, convID, accountID))
	if err != nil {
		return nil, err
	}
	members, err := s.membersOf(ctx, []string{convID})
	if err != nil {
		return nil, err
	}
	c.Members = members[convID]
	return c, nil
}

func (s *Store) membersOf(ctx context.Context, convIDs []string) (map[string][]Member, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT m.conv_id, m.account_id, m.role, m.joined_seq, m.read_seq, a.username, a.display_name, a.sign_pub, a.enc_pub, a.is_bot `+
		`FROM members m JOIN accounts a ON a.id = m.account_id WHERE m.conv_id IN (`+placeholders(len(convIDs))+`) ORDER BY m.conv_id, a.username`, stringArgs(convIDs)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string][]Member, len(convIDs))
	for rows.Next() {
		var m Member
		if err := rows.Scan(&m.ConvID, &m.AccountID, &m.Role, &m.JoinedSeq, &m.ReadSeq, &m.Username, &m.DisplayName, &m.SignPub, &m.EncPub, &m.IsBot); err != nil {
			return nil, err
		}
		out[m.ConvID] = append(out[m.ConvID], m)
	}
	return out, rows.Err()
}

// MemberAccountIDs lists the account ids of a conversation's members.
func (s *Store) MemberAccountIDs(ctx context.Context, convID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT account_id FROM members WHERE conv_id = ?`, convID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// AddMember adds an account to a group; it only sees messages after the
// current last_seq.
func (s *Store) AddMember(ctx context.Context, convID, accountID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var lastSeq int64
	if err := tx.QueryRowContext(ctx, `SELECT last_seq FROM conversations WHERE id = ?`, convID).Scan(&lastSeq); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO members (conv_id, account_id, role, joined_seq, read_seq) VALUES (?, ?, 'member', ?, ?)`, convID, accountID, lastSeq, lastSeq)
	if isUniqueViolation(err) {
		return ErrConflict
	}
	if err != nil {
		return err
	}
	return tx.Commit()
}

// RemoveMember removes an account from a conversation.
func (s *Store) RemoveMember(ctx context.Context, convID, accountID string) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM members WHERE conv_id = ? AND account_id = ?`, convID, accountID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// MarkRead advances the account's read position (never backwards, never past
// the last message).
func (s *Store) MarkRead(ctx context.Context, convID, accountID string, seq int64) error {
	res, err := s.db.ExecContext(ctx, `UPDATE members SET read_seq = MAX(read_seq, MIN(?, (SELECT last_seq FROM conversations WHERE id = ?))) WHERE conv_id = ? AND account_id = ?`, seq, convID, convID, accountID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetRetention sets the disappearing-messages timer of a conversation.
func (s *Store) SetRetention(ctx context.Context, convID string, seconds int64) error {
	res, err := s.db.ExecContext(ctx, `UPDATE conversations SET retention_seconds = ? WHERE id = ?`, seconds, convID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// PurgeExpired deletes messages and attachments older than the effective
// retention of their conversation (the per-conversation timer, capped by
// globalSeconds when it is positive). It returns the number of deleted
// messages and the ids of deleted blobs, whose files the caller removes.
func (s *Store) PurgeExpired(ctx context.Context, nowMS int64, globalSeconds int64) (int64, []string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, retention_seconds FROM conversations WHERE retention_seconds > 0 OR ? > 0`, globalSeconds)
	if err != nil {
		return 0, nil, err
	}
	type cutoff struct {
		id string
		ms int64
	}
	var cutoffs []cutoff
	for rows.Next() {
		var id string
		var ret int64
		if err := rows.Scan(&id, &ret); err != nil {
			rows.Close()
			return 0, nil, err
		}
		if globalSeconds > 0 && (ret == 0 || ret > globalSeconds) {
			ret = globalSeconds
		}
		if ret > 0 {
			cutoffs = append(cutoffs, cutoff{id, nowMS - ret*1000})
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, nil, err
	}
	var deleted int64
	var blobs []string
	for _, c := range cutoffs {
		res, err := s.db.ExecContext(ctx, `DELETE FROM messages WHERE conv_id = ? AND server_ts < ?`, c.id, c.ms)
		if err != nil {
			return deleted, blobs, err
		}
		n, _ := res.RowsAffected()
		deleted += n
		brows, err := s.db.QueryContext(ctx, `SELECT id FROM blobs WHERE conv_id = ? AND created_at < ?`, c.id, c.ms)
		if err != nil {
			return deleted, blobs, err
		}
		var ids []string
		for brows.Next() {
			var id string
			if err := brows.Scan(&id); err != nil {
				brows.Close()
				return deleted, blobs, err
			}
			ids = append(ids, id)
		}
		brows.Close()
		if len(ids) > 0 {
			if err := s.DeleteBlobs(ctx, ids); err != nil {
				return deleted, blobs, err
			}
			blobs = append(blobs, ids...)
		}
	}
	return deleted, blobs, nil
}
