package api

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Where releases are published; MSGR_UPDATE_REPO overrides it for forks and
// MSGR_UPDATE_CHECK=0 disables the check entirely.
const defaultUpdateRepo = "william-aqn/family-messenger-e2e"

// updateAPIBase is the GitHub API origin; tests point it at a local server.
var updateAPIBase = "https://api.github.com"

type releaseInfo struct {
	Tag string `json:"tag_name"`
	URL string `json:"html_url"`
}

type updateChecker struct {
	mu      sync.RWMutex
	latest  releaseInfo
	checked time.Time
}

// StartUpdateChecker asks GitHub for the newest release now and then every
// six hours; the admin panel shows the result next to the running version.
// Only the real server binary calls it, tests never reach the network.
func (s *Server) StartUpdateChecker(ctx context.Context) {
	if os.Getenv("MSGR_UPDATE_CHECK") == "0" {
		return
	}
	repo := os.Getenv("MSGR_UPDATE_REPO")
	if repo == "" {
		repo = defaultUpdateRepo
	}
	go func() {
		timer := time.NewTimer(15 * time.Second)
		defer timer.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-timer.C:
			}
			s.checkUpdate(ctx, repo)
			timer.Reset(6 * time.Hour)
		}
	}()
}

func (s *Server) checkUpdate(ctx context.Context, repo string) {
	reqCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, updateAPIBase+"/repos/"+repo+"/releases/latest", nil)
	if err != nil {
		return
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "family-messenger-server/"+Version)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		s.log.Debug("update check failed", "err", err)
		return
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		s.log.Debug("update check failed", "status", res.StatusCode)
		return
	}
	var info releaseInfo
	if err := json.NewDecoder(res.Body).Decode(&info); err != nil || info.Tag == "" {
		return
	}
	s.updates.mu.Lock()
	s.updates.latest = info
	s.updates.checked = time.Now()
	s.updates.mu.Unlock()
	if info.Tag != Version {
		s.log.Info("a newer release is available", "running", Version, "latest", info.Tag, "url", info.URL)
	}
}

// latestRelease returns the newest known release (empty before the first check).
func (s *Server) latestRelease() releaseInfo {
	s.updates.mu.RLock()
	defer s.updates.mu.RUnlock()
	return s.updates.latest
}

// isReleaseVersion tells whether a version string names a published release
// (a tag such as v0.2.0) rather than a development build (a commit hash).
func isReleaseVersion(v string) bool {
	return strings.HasPrefix(v, "v") && strings.Contains(v, ".")
}
