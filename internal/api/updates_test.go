package api

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/config"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
)

// The checker parses GitHub's "latest release" answer and keeps the last
// good result when the API is unreachable.
func TestUpdateChecker(t *testing.T) {
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/acme/messenger/releases/latest" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"tag_name": "v9.9.9", "html_url": "https://github.com/acme/messenger/releases/tag/v9.9.9", "assets": []}`)
	}))
	defer gh.Close()
	old := updateAPIBase
	updateAPIBase = gh.URL
	defer func() { updateAPIBase = old }()

	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	cfg := &config.Config{Addr: ":0", DataDir: t.TempDir(), Registration: "open", ServerSecret: []byte("test-secret"), TURNTTL: time.Hour}
	srv, err := New(cfg, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()

	if got := srv.latestRelease(); got.Tag != "" {
		t.Fatalf("a release is known before the first check: %+v", got)
	}
	srv.checkUpdate(context.Background(), "acme/messenger")
	got := srv.latestRelease()
	if got.Tag != "v9.9.9" || got.URL != "https://github.com/acme/messenger/releases/tag/v9.9.9" {
		t.Fatalf("latest release: %+v", got)
	}

	// A wrong repository (404) and an unreachable API keep the last result.
	srv.checkUpdate(context.Background(), "acme/other")
	updateAPIBase = "http://127.0.0.1:1"
	srv.checkUpdate(context.Background(), "acme/messenger")
	if got := srv.latestRelease(); got.Tag != "v9.9.9" {
		t.Fatalf("a failed check replaced the last result: %+v", got)
	}
}

func TestIsReleaseVersion(t *testing.T) {
	for v, want := range map[string]bool{"v0.2.0": true, "v1.0.0-rc1": true, "dev": false, "8260434": false, "": false, "version": false} {
		if got := isReleaseVersion(v); got != want {
			t.Errorf("isReleaseVersion(%q) = %v, want %v", v, got, want)
		}
	}
}
