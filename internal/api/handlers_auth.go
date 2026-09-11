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
	"github.com/william-aqn/family-messenger-e2e/internal/ws"
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
	s.challenges.forget(p.DeviceID)
	if err := s.store.DeleteDevice(r.Context(), p.AccountID, p.DeviceID); err != nil && !errors.Is(err, store.ErrNotFound) {
		writeError(w, s.log, err)
		return
	}
	s.hub.CloseDevice(p.DeviceID)
	w.WriteHeader(http.StatusNoContent)
}

// passwordChallenge hands the calling device the random bytes it must sign to
// change the password (PROTOCOL.md §3.2).
func (s *Server) passwordChallenge(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	value, expires, err := s.challenges.issue(p.DeviceID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"challenge": value[:], "expires_at": expires.Unix()})
}

// passwordRequest changes the password (PROTOCOL.md §3.2). The client sends
// the material derived from the new password plus a proof that it may do so:
// normally a signature over a fresh challenge made with the account's signing
// key, which a signed-in device holds without knowing any password. Clients
// too old to sign still prove the old password with its auth key instead.
// With sign_out_others every other device session is revoked, which is the
// point of changing a leaked password.
type passwordRequest struct {
	Challenge     []byte `json:"challenge"`
	Sig           []byte `json:"sig"`
	AuthKey       []byte `json:"auth_key"`
	NewSalt       []byte `json:"new_salt"`
	NewAuthKey    []byte `json:"new_auth_key"`
	NewKeyBundle  []byte `json:"new_key_bundle"`
	SignOutOthers bool   `json:"sign_out_others"`
}

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	var req passwordRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	if len(req.NewAuthKey) != 32 || len(req.NewSalt) != e2e.SaltSize || len(req.NewKeyBundle) != e2e.KeyBundleSize {
		writeError(w, s.log, badRequest("invalid_request", "new_auth_key, new_salt or new_key_bundle has the wrong size"))
		return
	}
	acct, err := s.store.AccountByID(r.Context(), p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	proof, apiErr := s.checkPasswordProof(r, acct, &req)
	if apiErr != nil {
		s.log.Warn("password change refused", "account", p.AccountID, "device", p.DeviceID, "ip", auth.ClientIP(r), "reason", apiErr.Code)
		writeError(w, s.log, apiErr)
		return
	}
	// The new material and the eviction land in one transaction, so a
	// half-applied change (new password, devices still in) cannot happen.
	keep := ""
	if req.SignOutOthers {
		keep = p.DeviceID
	}
	gone, err := s.store.UpdatePassword(r.Context(), p.AccountID, req.NewSalt, authHash(req.NewAuthKey), req.NewKeyBundle, keep)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	for _, id := range gone {
		s.challenges.forget(id)
		s.hub.CloseDevice(id)
	}
	// Prevention is gone with the old-password prompt, so detection has to
	// carry the weight: every device that is still connected hears about the
	// change at once and shows it. The device that made it gets the frame
	// too and recognises its own id.
	s.hub.SendToAccount(p.AccountID, ws.NewFrame("event", map[string]any{
		"kind": "password.changed", "device_id": p.DeviceID, "at": time.Now().Unix(), "proof": proof,
	}))
	s.log.Info("password changed", "account", p.AccountID, "device", p.DeviceID, "proof", proof, "other_devices_signed_out", len(gone))
	writeJSON(w, http.StatusOK, map[string]any{"signed_out_devices": len(gone)})
}

// checkPasswordProof decides whether this request may change the password and
// says which proof carried it. A signature is the current form; an auth key
// is what app builds from before the signature existed still send.
func (s *Server) checkPasswordProof(r *http.Request, acct *store.Account, req *passwordRequest) (string, *apiError) {
	p := principal(r)
	switch {
	case len(req.Sig) > 0 && len(req.AuthKey) > 0:
		// Never let a caller offer two proofs and have the server pick: it
		// would hide which one actually carried the change.
		return "", badRequest("invalid_request", "send either a challenge signature or the current auth_key, not both")
	case len(req.Sig) > 0:
		// Everything that does not depend on the challenge is checked first,
		// so a request that could never succeed does not burn one.
		account, err := e2e.ParseID(p.AccountID)
		if err != nil {
			return "", &apiError{http.StatusInternalServerError, "internal", "internal error"}
		}
		device, err := e2e.ParseID(p.DeviceID)
		if err != nil {
			return "", &apiError{http.StatusInternalServerError, "internal", "internal error"}
		}
		// Never pad a short key into the array: an all-zero Ed25519 public
		// key is a small-order point and would verify crafted signatures.
		if len(acct.SignPub) != 32 {
			return "", &apiError{http.StatusForbidden, "no_signing_key", "this account has no signing key"}
		}
		if !s.challenges.take(p.DeviceID, req.Challenge) {
			return "", &apiError{http.StatusUnauthorized, "challenge_expired", "this password-change challenge is unknown or has expired; ask for a new one"}
		}
		var signPub [32]byte
		copy(signPub[:], acct.SignPub)
		if !e2e.VerifyPasswordChange(signPub, req.Sig, req.Challenge, account, device, req.NewSalt, req.NewAuthKey, req.NewKeyBundle, req.SignOutOthers) {
			return "", &apiError{http.StatusUnauthorized, "invalid_signature", "the password-change proof does not verify under this account's key"}
		}
		return "signature", nil
	case len(req.AuthKey) == 32:
		if subtle.ConstantTimeCompare(authHash(req.AuthKey), acct.AuthHash) != 1 {
			return "", &apiError{http.StatusUnauthorized, "invalid_credentials", "current password is wrong"}
		}
		// Current clients never take this path; seeing it means an app build
		// from before the signature is still in use. It is also the only way
		// the endpoint can still be asked whether a password is right, so it
		// is worth noticing in the journal.
		s.log.Warn("password changed by an old client proving the current password", "account", p.AccountID, "device", p.DeviceID)
		return "password", nil
	default:
		return "", badRequest("invalid_request", "a challenge signature (sig) or the current auth_key is required")
	}
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
	s.challenges.forget(id)
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
