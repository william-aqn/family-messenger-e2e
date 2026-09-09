package api

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// StartJanitor runs the periodic clean-up (disappearing messages, global
// retention, stale bot updates, orphaned attachment files) until ctx ends.
func (s *Server) StartJanitor(ctx context.Context) {
	go func() {
		purge := time.NewTicker(time.Minute)
		sweep := time.NewTicker(time.Hour)
		defer purge.Stop()
		defer sweep.Stop()
		s.RunJanitorOnce(ctx, time.Now())
		for {
			select {
			case <-ctx.Done():
				return
			case <-purge.C:
				s.RunJanitorOnce(ctx, time.Now())
			case <-sweep.C:
				s.sweepOrphanBlobs(ctx)
			}
		}
	}()
}

// RunJanitorOnce purges expired data as of now and returns the number of
// deleted messages.
func (s *Server) RunJanitorOnce(ctx context.Context, now time.Time) int64 {
	global := s.settings.Get().RetentionDays * 24 * 3600
	deleted, blobs, err := s.store.PurgeExpired(ctx, now.UnixMilli(), global)
	if err != nil {
		s.log.Error("retention purge failed", "err", err)
	}
	for _, id := range blobs {
		if err := os.Remove(s.blobPath(id)); err != nil && !os.IsNotExist(err) {
			s.log.Warn("cannot delete attachment file", "id", id, "err", err)
		}
	}
	if deleted > 0 || len(blobs) > 0 {
		s.log.Info("retention purge", "messages", deleted, "attachments", len(blobs))
	}
	if _, err := s.store.PurgeBotUpdates(ctx, now.Add(-7*24*time.Hour).UnixMilli()); err != nil {
		s.log.Error("bot update purge failed", "err", err)
	}
	return deleted
}

// sweepOrphanBlobs deletes attachment files without a metadata row (left
// behind by cascading deletes) once they are older than an hour.
func (s *Server) sweepOrphanBlobs(ctx context.Context) {
	known, err := s.store.AllBlobIDs(ctx)
	if err != nil {
		s.log.Error("blob sweep failed", "err", err)
		return
	}
	entries, err := os.ReadDir(s.blobDir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-time.Hour)
	for _, e := range entries {
		name := e.Name()
		id := strings.TrimSuffix(name, ".tmp")
		if _, ok := known[id]; ok && !strings.HasSuffix(name, ".tmp") {
			continue
		}
		info, err := e.Info()
		if err != nil || info.ModTime().After(cutoff) {
			continue
		}
		_ = os.Remove(filepath.Join(s.blobDir, name))
	}
}
