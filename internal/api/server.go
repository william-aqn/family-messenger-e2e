// Package api wires the HTTP and WebSocket API of the messenger server.
package api

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/auth"
	"github.com/william-aqn/family-messenger-e2e/internal/config"
	"github.com/william-aqn/family-messenger-e2e/internal/settings"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
	"github.com/william-aqn/family-messenger-e2e/internal/webui"
	"github.com/william-aqn/family-messenger-e2e/internal/ws"
)

// Version is stamped by the build (-ldflags "-X ...api.Version=...").
var Version = "dev"

// Server holds the dependencies of every handler.
type Server struct {
	cfg      *config.Config
	store    *store.Store
	hub      *ws.Hub
	auth     *auth.Authenticator
	limiter  *auth.Limiter
	settings *settings.Manager
	bots     *botBridge
	log      *slog.Logger
	web      http.Handler
	blobDir  string
	started  time.Time
}

// New creates a Server, loading runtime settings and preparing the blob
// directory.
func New(cfg *config.Config, st *store.Store, log *slog.Logger) (*Server, error) {
	mgr, err := settings.Load(context.Background(), st, settings.Defaults(cfg.Registration))
	if err != nil {
		return nil, fmt.Errorf("load settings: %w", err)
	}
	blobDir := filepath.Join(cfg.DataDir, "blobs")
	if err := os.MkdirAll(blobDir, 0o700); err != nil {
		return nil, fmt.Errorf("create blob dir: %w", err)
	}
	s := &Server{
		cfg:      cfg,
		store:    st,
		hub:      ws.NewHub(),
		auth:     auth.New(st),
		limiter:  auth.NewLimiter(20, 10.0/60.0),
		settings: mgr,
		log:      log,
		web:      webui.Handler(cfg.WebDir),
		blobDir:  blobDir,
		started:  time.Now(),
	}
	s.bots = newBotBridge(s)
	return s, nil
}

// Handler builds the HTTP routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	lim := func(h http.HandlerFunc) http.Handler { return s.limiter.Middleware(h) }
	authed := func(h http.HandlerFunc) http.Handler { return s.auth.Middleware(h) }
	admin := func(h http.HandlerFunc) http.Handler { return s.auth.Middleware(s.requireAdmin(h)) }
	bot := func(h http.HandlerFunc) http.Handler { return s.auth.Middleware(s.requireBot(h)) }
	human := func(h http.HandlerFunc) http.Handler { return s.auth.Middleware(s.requireHuman(h)) }

	mux.HandleFunc("GET /api/v1/info", s.info)
	mux.Handle("POST /api/v1/auth/register", lim(s.register))
	mux.Handle("GET /api/v1/auth/params", lim(s.authParams))
	mux.Handle("POST /api/v1/auth/login", lim(s.login))
	mux.Handle("POST /api/v1/auth/logout", authed(s.logout))
	mux.Handle("POST /api/v1/auth/password", human(s.changePassword))
	mux.Handle("GET /api/v1/me", authed(s.me))
	mux.Handle("GET /api/v1/devices", authed(s.listDevices))
	mux.Handle("DELETE /api/v1/devices/{id}", authed(s.deleteDevice))
	mux.Handle("GET /api/v1/users", authed(s.listUsers))
	mux.Handle("GET /api/v1/users/{username}", authed(s.getUser))
	mux.Handle("GET /api/v1/conversations", authed(s.listConversations))
	mux.Handle("POST /api/v1/conversations", authed(s.createConversation))
	mux.Handle("GET /api/v1/conversations/{id}", authed(s.getConversation))
	mux.Handle("POST /api/v1/conversations/{id}/members", authed(s.addMember))
	mux.Handle("DELETE /api/v1/conversations/{id}/members/{account}", authed(s.removeMember))
	mux.Handle("GET /api/v1/conversations/{id}/messages", authed(s.listMessages))
	mux.Handle("POST /api/v1/conversations/{id}/messages", authed(s.sendMessage))
	mux.Handle("PUT /api/v1/conversations/{id}/read", authed(s.markRead))
	mux.Handle("PUT /api/v1/conversations/{id}/retention", authed(s.setRetention))
	mux.Handle("POST /api/v1/conversations/{id}/blobs", authed(s.uploadBlob))
	mux.Handle("GET /api/v1/blobs/{id}", authed(s.downloadBlob))
	mux.Handle("GET /api/v1/turn", authed(s.turn))
	mux.HandleFunc("GET /api/v1/ws", s.handleWS)

	// Bot management (by their owners) and the Bot API (by the bots).
	mux.Handle("GET /api/v1/bots", human(s.listBots))
	mux.Handle("POST /api/v1/bots", human(s.createBot))
	mux.Handle("PATCH /api/v1/bots/{id}", human(s.updateBot))
	mux.Handle("POST /api/v1/bots/{id}/rotate", human(s.rotateBot))
	mux.Handle("DELETE /api/v1/bots/{id}", human(s.deleteBot))
	mux.Handle("GET /api/v1/bot/me", bot(s.botMe))
	mux.Handle("POST /api/v1/bot/messages", bot(s.botSendMessage))
	mux.Handle("GET /api/v1/bot/updates", bot(s.botUpdates))
	mux.Handle("GET /api/v1/bot/files/{id}", bot(s.botFile))

	// Administration.
	mux.Handle("GET /api/v1/admin/stats", admin(s.adminStats))
	mux.Handle("GET /api/v1/admin/settings", admin(s.adminGetSettings))
	mux.Handle("PUT /api/v1/admin/settings", admin(s.adminPutSettings))
	mux.Handle("GET /api/v1/admin/users", admin(s.adminListUsers))
	mux.Handle("PATCH /api/v1/admin/users/{id}", admin(s.adminPatchUser))
	mux.Handle("DELETE /api/v1/admin/users/{id}", admin(s.adminDeleteUser))
	mux.Handle("POST /api/v1/admin/users/{id}/logout", admin(s.adminLogoutUser))
	mux.Handle("GET /api/v1/admin/invites", admin(s.adminListInvites))
	mux.Handle("POST /api/v1/admin/invites", admin(s.adminCreateInvites))
	mux.Handle("DELETE /api/v1/admin/invites/{code}", admin(s.adminDeleteInvite))
	mux.Handle("POST /api/v1/admin/backup", admin(s.adminBackup))

	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, s.log, notFound("not_found", "no such endpoint"))
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "time": time.Now().UnixMilli(), "version": Version})
	})
	mux.Handle("/", s.web)
	return s.recoverer(mux)
}

// Close disconnects all WebSocket clients.
func (s *Server) Close() { s.hub.CloseAll() }

func (s *Server) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !principal(r).IsAdmin {
			writeError(w, s.log, forbidden("admin_only", "administrator access required"))
			return
		}
		next(w, r)
	}
}

func (s *Server) requireBot(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !principal(r).IsBot {
			writeError(w, s.log, forbidden("bots_only", "this endpoint is for bot tokens"))
			return
		}
		next(w, r)
	}
}

func (s *Server) requireHuman(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if principal(r).IsBot {
			writeError(w, s.log, forbidden("humans_only", "bots cannot use this endpoint"))
			return
		}
		next(w, r)
	}
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				if rec == http.ErrAbortHandler {
					panic(rec)
				}
				s.log.Error("panic in handler", "err", rec, "path", r.URL.Path, "stack", string(debug.Stack()))
				writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]string{"code": "internal", "message": "internal error"}})
			}
		}()
		start := time.Now()
		next.ServeHTTP(w, r)
		if s.cfg.Debug {
			s.log.Debug("request", "method", r.Method, "path", r.URL.Path, "ip", auth.ClientIP(r), "dur", time.Since(start))
		}
	})
}

// info is the public server description shown before login.
func (s *Server) info(w http.ResponseWriter, r *http.Request) {
	st := s.settings.Get()
	writeJSON(w, http.StatusOK, map[string]any{
		"registration":   st.Registration,
		"announcement":   st.Announcement,
		"user_directory": st.UserDirectory,
		"version":        Version,
	})
}
