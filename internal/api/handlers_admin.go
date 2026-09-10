package api

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/settings"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
)

func (s *Server) adminStats(w http.ResponseWriter, r *http.Request) {
	st, err := s.store.Stats(r.Context())
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	var dbBytes int64
	if fi, err := os.Stat(s.cfg.DBPath()); err == nil {
		dbBytes = fi.Size()
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"accounts":       st.Accounts,
		"bots":           st.Bots,
		"conversations":  st.Conversations,
		"messages":       st.Messages,
		"blobs":          st.Blobs,
		"blob_bytes":     st.BlobBytes,
		"devices":        st.Devices,
		"invites":        st.Invites,
		"unused_invites": st.UnusedInvites,
		"online_devices": s.hub.ConnectionCount(),
		"db_bytes":       dbBytes,
		"uptime_seconds": int64(time.Since(s.started).Seconds()),
		"latest_version": s.latestRelease().Tag,
		"latest_url":     s.latestRelease().URL,
		"is_release":     isReleaseVersion(Version),
		"version":        Version,
		"go_version":     runtime.Version(),
		"turn_enabled":   s.cfg.TURNSecret != "" && len(s.cfg.TURNURLs) > 0,
	})
}

func (s *Server) adminGetSettings(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.settings.Get())
}

func (s *Server) adminPutSettings(w http.ResponseWriter, r *http.Request) {
	next := s.settings.Get()
	if err := decodeJSON(w, r, &next); err != nil {
		writeError(w, s.log, err)
		return
	}
	if err := s.settings.Update(r.Context(), next); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, s.log, err)
			return
		}
		writeError(w, s.log, badRequest("invalid_settings", err.Error()))
		return
	}
	s.log.Info("settings updated", "by", principal(r).Username)
	writeJSON(w, http.StatusOK, s.settings.Get())
}

type adminUserView struct {
	ID            string `json:"id"`
	Username      string `json:"username"`
	DisplayName   string `json:"display_name"`
	CreatedAt     int64  `json:"created_at"`
	LastSeen      int64  `json:"last_seen"`
	Devices       int    `json:"devices"`
	Online        bool   `json:"online"`
	IsAdmin       bool   `json:"is_admin"`
	Disabled      bool   `json:"disabled"`
	IsBot         bool   `json:"is_bot"`
	OwnerUsername string `json:"owner_username,omitempty"`
}

func (s *Server) adminListUsers(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	offset, _ := strconv.Atoi(q.Get("offset"))
	accts, err := s.store.ListAccounts(r.Context(), strings.ToLower(strings.TrimSpace(q.Get("q"))), limit, offset)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	out := make([]adminUserView, 0, len(accts))
	for _, a := range accts {
		out = append(out, adminUserView{
			ID: a.ID, Username: a.Username, DisplayName: a.DisplayName, CreatedAt: a.CreatedAt, LastSeen: a.LastSeen, Devices: a.Devices,
			Online: s.hub.Online(a.ID), IsAdmin: a.IsAdmin, Disabled: a.Disabled, IsBot: a.IsBot, OwnerUsername: a.OwnerUsername,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": out})
}

type adminPatchUserRequest struct {
	Disabled *bool `json:"disabled"`
	IsAdmin  *bool `json:"is_admin"`
}

func (s *Server) adminPatchUser(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id := r.PathValue("id")
	var req adminPatchUserRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	acct, err := s.store.AccountByID(r.Context(), id)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	disabled, isAdmin := acct.Disabled, acct.IsAdmin
	if req.Disabled != nil {
		disabled = *req.Disabled
	}
	if req.IsAdmin != nil {
		isAdmin = *req.IsAdmin
	}
	if acct.ID == p.AccountID && (disabled || !isAdmin) {
		writeError(w, s.log, badRequest("self_lockout", "you cannot disable yourself or drop your own admin rights"))
		return
	}
	if acct.IsBot && isAdmin {
		writeError(w, s.log, badRequest("invalid_request", "bots cannot be administrators"))
		return
	}
	if err := s.store.SetAccountFlags(r.Context(), id, disabled, isAdmin); err != nil {
		writeError(w, s.log, err)
		return
	}
	if disabled && !acct.Disabled {
		s.signOutEverywhere(r, id)
	}
	s.log.Info("account flags changed", "by", p.Username, "account", acct.Username, "disabled", disabled, "admin", isAdmin)
	updated, err := s.store.AccountByID(r.Context(), id)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": updated.ID, "username": updated.Username, "is_admin": updated.IsAdmin, "disabled": updated.Disabled, "is_bot": updated.IsBot})
}

func (s *Server) signOutEverywhere(r *http.Request, accountID string) {
	ids, err := s.store.DeleteAllDevices(r.Context(), accountID)
	if err != nil {
		s.log.Error("sign out everywhere failed", "err", err)
		return
	}
	for _, d := range ids {
		s.hub.CloseDevice(d)
	}
}

func (s *Server) adminDeleteUser(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id := r.PathValue("id")
	if id == p.AccountID {
		writeError(w, s.log, badRequest("self_lockout", "you cannot delete your own account here"))
		return
	}
	acct, err := s.store.AccountByID(r.Context(), id)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	convs, _ := s.store.ConversationsForAccount(r.Context(), id)
	s.signOutEverywhere(r, id)
	// Bots owned by the account go with it.
	if bots, err := s.store.BotsByOwner(r.Context(), id); err == nil {
		for _, b := range bots {
			s.hub.CloseDevice(b.DeviceID)
			_ = s.store.DeleteAccount(r.Context(), b.AccountID)
		}
	}
	if err := s.store.DeleteAccount(r.Context(), id); err != nil {
		writeError(w, s.log, err)
		return
	}
	for i := range convs {
		s.notify(memberIDs(&convs[i]), eventPayload{Kind: "member.removed", ConvID: convs[i].ID, Actor: p.AccountID, Account: id})
	}
	s.log.Warn("account deleted", "by", p.Username, "account", acct.Username)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminLogoutUser(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := s.store.AccountByID(r.Context(), id); err != nil {
		writeError(w, s.log, err)
		return
	}
	s.signOutEverywhere(r, id)
	w.WriteHeader(http.StatusNoContent)
}

type inviteView struct {
	Code           string `json:"code"`
	Note           string `json:"note"`
	CreatedAt      int64  `json:"created_at"`
	UsedByUsername string `json:"used_by,omitempty"`
	UsedAt         int64  `json:"used_at,omitempty"`
	ExpiresAt      int64  `json:"expires_at,omitempty"`
}

func (s *Server) adminListInvites(w http.ResponseWriter, r *http.Request) {
	invites, err := s.store.ListInvites(r.Context())
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	out := make([]inviteView, 0, len(invites))
	for _, i := range invites {
		out = append(out, inviteView{Code: i.Code, Note: i.Note, CreatedAt: i.CreatedAt, UsedByUsername: i.UsedByUsername, UsedAt: i.UsedAt, ExpiresAt: i.ExpiresAt})
	}
	writeJSON(w, http.StatusOK, map[string]any{"invites": out})
}

type createInvitesRequest struct {
	Count        int    `json:"count"`
	Note         string `json:"note"`
	ExpiresHours int64  `json:"expires_hours"`
}

func (s *Server) adminCreateInvites(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	var req createInvitesRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	if req.Count <= 0 {
		req.Count = 1
	}
	if req.Count > 100 {
		writeError(w, s.log, badRequest("invalid_request", "at most 100 invites per request"))
		return
	}
	if len(req.Note) > 200 {
		req.Note = req.Note[:200]
	}
	var expires int64
	if req.ExpiresHours > 0 {
		expires = time.Now().Add(time.Duration(req.ExpiresHours) * time.Hour).Unix()
	}
	codes := make([]string, 0, req.Count)
	for i := 0; i < req.Count; i++ {
		code, err := store.NewInviteCode()
		if err != nil {
			writeError(w, s.log, err)
			return
		}
		if err := s.store.CreateInvite(r.Context(), code, p.AccountID, req.Note, expires); err != nil {
			writeError(w, s.log, err)
			return
		}
		codes = append(codes, code)
	}
	writeJSON(w, http.StatusCreated, map[string]any{"codes": codes, "expires_at": expires})
}

func (s *Server) adminDeleteInvite(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteInvite(r.Context(), r.PathValue("code")); err != nil {
		writeError(w, s.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// adminBackup streams a consistent SQLite snapshot (VACUUM INTO) as a download.
func (s *Server) adminBackup(w http.ResponseWriter, r *http.Request) {
	name := fmt.Sprintf("family-messenger-backup-%s.db", time.Now().UTC().Format("20060102-150405"))
	path := filepath.Join(s.cfg.DataDir, name)
	if err := s.store.Backup(r.Context(), filepath.ToSlash(path)); err != nil {
		writeError(w, s.log, err)
		return
	}
	defer os.Remove(path)
	f, err := os.Open(path)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.sqlite3")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Header().Set("Cache-Control", "no-store")
	http.ServeContent(w, r, name, fi.ModTime(), f)
}

// settingsForTests exposes the manager to the test package.
func (s *Server) Settings() *settings.Manager { return s.settings }
