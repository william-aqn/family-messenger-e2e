package api

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/store"
)

var blobIDRe = regexp.MustCompile(`^[0-9a-f]{32}$`)

func (s *Server) blobPath(id string) string { return filepath.Join(s.blobDir, id) }

// uploadBlob stores an already encrypted attachment for a conversation.
// The server never sees the content key; it only enforces membership and
// size limits (PROTOCOL.md §6, payload type "file").
func (s *Server) uploadBlob(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id, err := convIDParam(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	if _, err := s.store.ConversationForAccount(r.Context(), id, p.AccountID); err != nil {
		writeError(w, s.log, err)
		return
	}
	limit := s.settings.Get().MaxAttachmentBytes
	if limit <= 0 {
		writeError(w, s.log, forbidden("attachments_disabled", "attachments are disabled on this server"))
		return
	}
	if r.ContentLength > limit {
		writeError(w, s.log, &apiError{http.StatusRequestEntityTooLarge, "too_large", "attachment exceeds the server limit"})
		return
	}
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		writeError(w, s.log, err)
		return
	}
	blobID := hex.EncodeToString(raw)
	tmp := s.blobPath(blobID) + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	n, err := io.Copy(f, http.MaxBytesReader(w, r.Body, limit))
	closeErr := f.Close()
	if err != nil || closeErr != nil {
		os.Remove(tmp)
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, s.log, &apiError{http.StatusRequestEntityTooLarge, "too_large", "attachment exceeds the server limit"})
			return
		}
		writeError(w, s.log, badRequest("upload_failed", "could not read the upload"))
		return
	}
	if n == 0 {
		os.Remove(tmp)
		writeError(w, s.log, badRequest("empty_upload", "the attachment is empty"))
		return
	}
	if err := os.Rename(tmp, s.blobPath(blobID)); err != nil {
		os.Remove(tmp)
		writeError(w, s.log, err)
		return
	}
	b := &store.Blob{ID: blobID, ConvID: id, Uploader: p.AccountID, Size: n, CreatedAt: time.Now().UnixMilli()}
	if err := s.store.CreateBlob(r.Context(), b); err != nil {
		os.Remove(s.blobPath(blobID))
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": blobID, "size": n})
}

// blobForMember returns the blob if the principal is a member of its conversation.
func (s *Server) blobForMember(r *http.Request, id string) (*store.Blob, error) {
	if !blobIDRe.MatchString(id) {
		return nil, notFound("not_found", "no such attachment")
	}
	b, err := s.store.Blob(r.Context(), id)
	if err != nil {
		return nil, err
	}
	if _, err := s.store.ConversationForAccount(r.Context(), b.ConvID, principal(r).AccountID); err != nil {
		return nil, notFound("not_found", "no such attachment")
	}
	return b, nil
}

func (s *Server) downloadBlob(w http.ResponseWriter, r *http.Request) {
	b, err := s.blobForMember(r, r.PathValue("id"))
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	f, err := os.Open(s.blobPath(b.ID))
	if err != nil {
		writeError(w, s.log, notFound("not_found", "attachment data is gone"))
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, b.ID, time.UnixMilli(b.CreatedAt), f)
}
