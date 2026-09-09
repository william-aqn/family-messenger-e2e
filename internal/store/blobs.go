package store

import (
	"context"
	"database/sql"
	"errors"
)

// Blob is an encrypted attachment stored on disk; the row keeps metadata.
type Blob struct {
	ID        string
	ConvID    string
	Uploader  string
	Size      int64
	CreatedAt int64
}

// CreateBlob records an uploaded attachment.
func (s *Store) CreateBlob(ctx context.Context, b *Blob) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO blobs (id, conv_id, uploader, size, created_at) VALUES (?, ?, ?, ?, ?)`, b.ID, b.ConvID, b.Uploader, b.Size, b.CreatedAt)
	return err
}

// Blob returns the metadata of an attachment.
func (s *Store) Blob(ctx context.Context, id string) (*Blob, error) {
	var b Blob
	err := s.db.QueryRowContext(ctx, `SELECT id, conv_id, uploader, size, created_at FROM blobs WHERE id = ?`, id).Scan(&b.ID, &b.ConvID, &b.Uploader, &b.Size, &b.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &b, nil
}

// DeleteBlobs removes metadata rows; the caller deletes the files.
func (s *Store) DeleteBlobs(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM blobs WHERE id IN (`+placeholders(len(ids))+`)`, stringArgs(ids)...)
	return err
}

// AllBlobIDs lists every attachment id (used to sweep orphaned files).
func (s *Store) AllBlobIDs(ctx context.Context) (map[string]struct{}, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id FROM blobs`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]struct{}{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = struct{}{}
	}
	return out, rows.Err()
}
