package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/auth"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
	"github.com/william-aqn/family-messenger-e2e/pkg/e2e"
)

var usernameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9_.]{2,31}$`)

type registerRequest struct {
	Username   string `json:"username"`
	Salt       []byte `json:"salt"`
	AuthKey    []byte `json:"auth_key"`
	SignPub    []byte `json:"sign_pub"`
	EncPub     []byte `json:"enc_pub"`
	KeyBundle  []byte `json:"key_bundle"`
	Invite     string `json:"invite"`
	DeviceName string `json:"device_name"`
}

type sessionResponse struct {
	AccountID string        `json:"account_id"`
	Username  string        `json:"username"`
	DeviceID  string        `json:"device_id"`
	Token     string        `json:"token"`
	SignPub   []byte        `json:"sign_pub"`
	EncPub    []byte        `json:"enc_pub"`
	KeyBundle []byte        `json:"key_bundle"`
	Salt      []byte        `json:"salt"`
	KDF       e2e.KDFParams `json:"kdf"`
	IsAdmin   bool          `json:"is_admin"`
}

func normalizeUsername(s string) (string, bool) {
	s = strings.ToLower(strings.TrimSpace(s))
	return s, usernameRe.MatchString(s)
}

func deviceName(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return "device"
	}
	if len(s) > 64 {
		s = s[:64]
	}
	return s
}

func authHash(authKey []byte) []byte {
	var k [32]byte
	copy(k[:], authKey)
	h := e2e.AuthHash(k)
	return h[:]
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	username, ok := normalizeUsername(req.Username)
	if !ok {
		writeError(w, s.log, badRequest("invalid_username", "username must be 3-32 characters: a-z, 0-9, '_' or '.'"))
		return
	}
	if strings.HasSuffix(username, "bot") {
		writeError(w, s.log, badRequest("invalid_username", "usernames ending in 'bot' are reserved for bots"))
		return
	}
	if len(req.Salt) != e2e.SaltSize || len(req.AuthKey) != 32 || len(req.SignPub) != 32 || len(req.EncPub) != 32 || len(req.KeyBundle) != e2e.KeyBundleSize {
		writeError(w, s.log, badRequest("invalid_keys", "salt, auth_key, sign_pub, enc_pub or key_bundle has the wrong size"))
		return
	}
	mode := s.settings.Get().Registration
	switch mode {
	case "closed":
		writeError(w, s.log, forbidden("registration_closed", "registration is closed"))
		return
	case "invite":
		if strings.TrimSpace(req.Invite) == "" {
			writeError(w, s.log, forbidden("invite_required", "an invite code is required"))
			return
		}
	}
	now := time.Now().Unix()
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	acct := &store.Account{
		ID: newID(), Username: username, Salt: req.Salt, AuthHash: authHash(req.AuthKey),
		SignPub: req.SignPub, EncPub: req.EncPub, KeyBundle: req.KeyBundle, CreatedAt: now,
	}
	dev := &store.Device{ID: newID(), AccountID: acct.ID, Name: deviceName(req.DeviceName), TokenHash: tokenHash, CreatedAt: now, LastSeen: now}
	if err := s.store.CreateAccount(r.Context(), acct, dev, strings.TrimSpace(req.Invite), mode == "invite"); err != nil {
		if errors.Is(err, store.ErrConflict) {
			writeError(w, s.log, conflict("username_taken", "this username is already taken"))
			return
		}
		writeError(w, s.log, err)
		return
	}
	s.log.Info("account registered", "username", username, "account", acct.ID, "admin", acct.IsAdmin)
	writeJSON(w, http.StatusCreated, sessionResponse{
		AccountID: acct.ID, Username: acct.Username, DeviceID: dev.ID, Token: token,
		SignPub: acct.SignPub, EncPub: acct.EncPub, KeyBundle: acct.KeyBundle, Salt: acct.Salt, KDF: e2e.DefaultKDFParams, IsAdmin: acct.IsAdmin,
	})
}

func (s *Server) authParams(w http.ResponseWriter, r *http.Request) {
	username, ok := normalizeUsername(r.URL.Query().Get("username"))
	if !ok {
		writeError(w, s.log, badRequest("invalid_username", "invalid username"))
		return
	}
	var salt []byte
	acct, err := s.store.AccountByUsername(r.Context(), username)
	switch {
	case err == nil && !acct.IsBot:
		salt = acct.Salt
	case err == nil || errors.Is(err, store.ErrNotFound):
		// Deterministic fake salt: does not reveal whether the account exists.
		mac := hmac.New(sha256.New, s.cfg.ServerSecret)
		mac.Write([]byte("salt:" + username))
		salt = mac.Sum(nil)[:e2e.SaltSize]
	default:
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"salt": salt, "kdf": e2e.DefaultKDFParams})
}

type loginRequest struct {
	Username   string `json:"username"`
	AuthKey    []byte `json:"auth_key"`
	DeviceName string `json:"device_name"`
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	username, ok := normalizeUsername(req.Username)
	if !ok || len(req.AuthKey) != 32 {
		writeError(w, s.log, badRequest("invalid_request", "username and a 32-byte auth_key are required"))
		return
	}
	invalid := &apiError{http.StatusUnauthorized, "invalid_credentials", "wrong username or password"}
	acct, err := s.store.AccountByUsername(r.Context(), username)
	if errors.Is(err, store.ErrNotFound) || (err == nil && acct.IsBot) {
		subtle.ConstantTimeCompare(authHash(req.AuthKey), make([]byte, 32)) // keep timing similar
		writeError(w, s.log, invalid)
		return
	}
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	if subtle.ConstantTimeCompare(authHash(req.AuthKey), acct.AuthHash) != 1 {
		writeError(w, s.log, invalid)
		return
	}
	if acct.Disabled {
		writeError(w, s.log, forbidden("account_disabled", "this account has been disabled"))
		return
	}
	now := time.Now().Unix()
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	dev := &store.Device{ID: newID(), AccountID: acct.ID, Name: deviceName(req.DeviceName), TokenHash: tokenHash, CreatedAt: now, LastSeen: now}
	if err := s.store.CreateDevice(r.Context(), dev); err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, sessionResponse{
		AccountID: acct.ID, Username: acct.Username, DeviceID: dev.ID, Token: token,
		SignPub: acct.SignPub, EncPub: acct.EncPub, KeyBundle: acct.KeyBundle, Salt: acct.Salt, KDF: e2e.DefaultKDFParams, IsAdmin: acct.IsAdmin,
	})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	if err := s.store.DeleteDevice(r.Context(), p.AccountID, p.DeviceID); err != nil && !errors.Is(err, store.ErrNotFound) {
		writeError(w, s.log, err)
		return
	}
	s.hub.CloseDevice(p.DeviceID)
	w.WriteHeader(http.StatusNoContent)
}

type passwordRequest struct {
	AuthKey      []byte `json:"auth_key"`
	NewSalt      []byte `json:"new_salt"`
	NewAuthKey   []byte `json:"new_auth_key"`
	NewKeyBundle []byte `json:"new_key_bundle"`
}

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	var req passwordRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	if len(req.AuthKey) != 32 || len(req.NewAuthKey) != 32 || len(req.NewSalt) != e2e.SaltSize || len(req.NewKeyBundle) != e2e.KeyBundleSize {
		writeError(w, s.log, badRequest("invalid_request", "auth_key, new_auth_key, new_salt or new_key_bundle has the wrong size"))
		return
	}
	acct, err := s.store.AccountByID(r.Context(), p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	if subtle.ConstantTimeCompare(authHash(req.AuthKey), acct.AuthHash) != 1 {
		writeError(w, s.log, &apiError{http.StatusUnauthorized, "invalid_credentials", "current password is wrong"})
		return
	}
	if err := s.store.UpdatePassword(r.Context(), p.AccountID, req.NewSalt, authHash(req.NewAuthKey), req.NewKeyBundle); err != nil {
		writeError(w, s.log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type deviceView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"created_at"`
	LastSeen  int64  `json:"last_seen"`
	Current   bool   `json:"current"`
}

func (s *Server) deviceViews(r *http.Request) ([]deviceView, error) {
	p := principal(r)
	devs, err := s.store.DevicesByAccount(r.Context(), p.AccountID)
	if err != nil {
		return nil, err
	}
	out := make([]deviceView, 0, len(devs))
	for _, d := range devs {
		out = append(out, deviceView{ID: d.ID, Name: d.Name, CreatedAt: d.CreatedAt, LastSeen: d.LastSeen, Current: d.ID == p.DeviceID})
	}
	return out, nil
}

// publicSettings is the subset of runtime settings every client may see.
func (s *Server) publicSettings() map[string]any {
	st := s.settings.Get()
	return map[string]any{
		"registration":         st.Registration,
		"announcement":         st.Announcement,
		"allow_bots":           st.AllowBots,
		"max_attachment_bytes": st.MaxAttachmentBytes,
		"max_group_members":    st.MaxGroupMembers,
		"retention_days":       st.RetentionDays,
		"user_directory":       st.UserDirectory,
	}
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	acct, err := s.store.AccountByID(r.Context(), p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	devs, err := s.deviceViews(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"account": map[string]any{
			"id": acct.ID, "username": acct.Username, "display_name": acct.DisplayName, "sign_pub": acct.SignPub, "enc_pub": acct.EncPub,
			"created_at": acct.CreatedAt, "is_admin": acct.IsAdmin, "is_bot": acct.IsBot,
		},
		"device_id": p.DeviceID,
		"devices":   devs,
		"settings":  s.publicSettings(),
		"version":   Version,
	})
}

func (s *Server) listDevices(w http.ResponseWriter, r *http.Request) {
	devs, err := s.deviceViews(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devs})
}

func (s *Server) deleteDevice(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	id := r.PathValue("id")
	if err := s.store.DeleteDevice(r.Context(), p.AccountID, id); err != nil {
		writeError(w, s.log, err)
		return
	}
	s.hub.CloseDevice(id)
	w.WriteHeader(http.StatusNoContent)
}

func userView(a *store.Account) map[string]any {
	return map[string]any{
		"id": a.ID, "username": a.Username, "display_name": a.DisplayName, "sign_pub": a.SignPub, "enc_pub": a.EncPub, "is_bot": a.IsBot,
	}
}

func (s *Server) getUser(w http.ResponseWriter, r *http.Request) {
	username, ok := normalizeUsername(r.PathValue("username"))
	if !ok {
		writeError(w, s.log, notFound("user_not_found", "no such user"))
		return
	}
	acct, err := s.store.AccountByUsername(r.Context(), username)
	if errors.Is(err, store.ErrNotFound) || (err == nil && acct.Disabled) {
		writeError(w, s.log, notFound("user_not_found", "no such user"))
		return
	}
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, userView(acct))
}
