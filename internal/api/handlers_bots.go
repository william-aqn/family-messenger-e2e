package api

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/chacha20poly1305"

	"github.com/william-aqn/family-messenger-e2e/internal/auth"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
	"github.com/william-aqn/family-messenger-e2e/pkg/e2e"
)

// botView is a bot as shown to its owner (no secrets).
type botView struct {
	ID          string `json:"id"`
	Username    string `json:"username"`
	DisplayName string `json:"display_name"`
	WebhookURL  string `json:"webhook_url"`
	CreatedAt   int64  `json:"created_at"`
	SignPub     []byte `json:"sign_pub"`
	EncPub      []byte `json:"enc_pub"`
}

func toBotView(b *store.Bot) botView {
	return botView{ID: b.AccountID, Username: b.Username, DisplayName: b.DisplayName, WebhookURL: b.WebhookURL, CreatedAt: b.CreatedAt, SignPub: b.SignPub, EncPub: b.EncPub}
}

func randomHex(n int) (string, error) {
	raw := make([]byte, n)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

func validWebhookURL(s string) bool {
	if s == "" {
		return true
	}
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}

type createBotRequest struct {
	Username    string `json:"username"`
	DisplayName string `json:"display_name"`
	WebhookURL  string `json:"webhook_url"`
}

// createBot registers a bot account owned by the caller. The server keeps
// the bot's keys and bridges its conversations to plain JSON (see docs/BOTS.md).
func (s *Server) createBot(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	if !s.settings.Get().AllowBots {
		writeError(w, s.log, forbidden("bots_disabled", "bots are disabled on this server"))
		return
	}
	var req createBotRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	username, ok := normalizeUsername(req.Username)
	if !ok || !strings.HasSuffix(username, "bot") {
		writeError(w, s.log, badRequest("invalid_username", "bot usernames must be 3-32 characters (a-z, 0-9, '_' or '.') and end with 'bot'"))
		return
	}
	req.WebhookURL = strings.TrimSpace(req.WebhookURL)
	if !validWebhookURL(req.WebhookURL) {
		writeError(w, s.log, badRequest("invalid_webhook", "webhook_url must be an http(s) URL"))
		return
	}
	name := strings.TrimSpace(req.DisplayName)
	if name == "" {
		name = username
	}
	if len(name) > 64 {
		name = name[:64]
	}
	keys, err := e2e.GenerateAccountKeys()
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	secret, err := randomHex(32)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	now := time.Now().Unix()
	acct := &store.Account{
		ID: newID(), Username: username, DisplayName: name, Salt: []byte{}, AuthHash: []byte{}, KeyBundle: []byte{},
		SignPub: keys.SignPub[:], EncPub: keys.EncPub[:], CreatedAt: now, IsBot: true,
	}
	dev := &store.Device{ID: newID(), AccountID: acct.ID, Name: "bridge", TokenHash: tokenHash, CreatedAt: now, LastSeen: now}
	bot := &store.Bot{
		AccountID: acct.ID, OwnerID: p.AccountID, DeviceID: dev.ID, WebhookURL: req.WebhookURL, WebhookSecret: secret,
		SignSeed: keys.SignSeed[:], EncPriv: keys.EncPriv[:], CreatedAt: now,
	}
	if err := s.store.CreateBot(r.Context(), acct, dev, bot); err != nil {
		if errors.Is(err, store.ErrConflict) {
			writeError(w, s.log, conflict("username_taken", "this username is already taken"))
			return
		}
		writeError(w, s.log, err)
		return
	}
	full, err := s.store.BotByAccount(r.Context(), acct.ID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	s.log.Info("bot created", "bot", username, "owner", p.Username)
	writeJSON(w, http.StatusCreated, map[string]any{"bot": toBotView(full), "token": token, "webhook_secret": secret})
}

func (s *Server) listBots(w http.ResponseWriter, r *http.Request) {
	bots, err := s.store.BotsByOwner(r.Context(), principal(r).AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	out := make([]botView, 0, len(bots))
	for i := range bots {
		out = append(out, toBotView(&bots[i]))
	}
	writeJSON(w, http.StatusOK, map[string]any{"bots": out})
}

// ownedBot loads the bot from the path and checks that the caller owns it.
func (s *Server) ownedBot(r *http.Request) (*store.Bot, error) {
	bot, err := s.store.BotByAccount(r.Context(), r.PathValue("id"))
	if err != nil {
		return nil, notFound("not_found", "no such bot")
	}
	if bot.OwnerID != principal(r).AccountID {
		return nil, notFound("not_found", "no such bot")
	}
	return bot, nil
}

type updateBotRequest struct {
	DisplayName *string `json:"display_name"`
	WebhookURL  *string `json:"webhook_url"`
}

func (s *Server) updateBot(w http.ResponseWriter, r *http.Request) {
	bot, err := s.ownedBot(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	var req updateBotRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	name, hook := bot.DisplayName, bot.WebhookURL
	if req.DisplayName != nil {
		name = strings.TrimSpace(*req.DisplayName)
		if name == "" {
			name = bot.Username
		}
		if len(name) > 64 {
			name = name[:64]
		}
	}
	if req.WebhookURL != nil {
		hook = strings.TrimSpace(*req.WebhookURL)
		if !validWebhookURL(hook) {
			writeError(w, s.log, badRequest("invalid_webhook", "webhook_url must be an http(s) URL"))
			return
		}
	}
	if err := s.store.UpdateBot(r.Context(), bot.AccountID, name, hook); err != nil {
		writeError(w, s.log, err)
		return
	}
	updated, err := s.store.BotByAccount(r.Context(), bot.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusOK, toBotView(updated))
}

func (s *Server) rotateBot(w http.ResponseWriter, r *http.Request) {
	bot, err := s.ownedBot(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	token, tokenHash, err := auth.NewToken()
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	secret, err := randomHex(32)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	if err := s.store.RotateBotCredentials(r.Context(), bot.AccountID, tokenHash, secret); err != nil {
		writeError(w, s.log, err)
		return
	}
	s.hub.CloseDevice(bot.DeviceID)
	writeJSON(w, http.StatusOK, map[string]any{"token": token, "webhook_secret": secret})
}

func (s *Server) deleteBot(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	bot, err := s.ownedBot(r)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	convs, _ := s.store.ConversationsForAccount(r.Context(), bot.AccountID)
	s.hub.CloseDevice(bot.DeviceID)
	if err := s.store.DeleteAccount(r.Context(), bot.AccountID); err != nil {
		writeError(w, s.log, err)
		return
	}
	for i := range convs {
		s.notify(memberIDs(&convs[i]), eventPayload{Kind: "member.removed", ConvID: convs[i].ID, Actor: p.AccountID, Account: bot.AccountID})
	}
	s.log.Info("bot deleted", "bot", bot.Username, "owner", p.Username)
	w.WriteHeader(http.StatusNoContent)
}

// --- Bot API (authenticated with the bot token) ---

func (s *Server) botMe(w http.ResponseWriter, r *http.Request) {
	bot, err := s.store.BotByAccount(r.Context(), principal(r).AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	owner := ""
	if o, err := s.store.AccountByID(r.Context(), bot.OwnerID); err == nil {
		owner = o.Username
	}
	writeJSON(w, http.StatusOK, map[string]any{"bot": toBotView(bot), "owner": owner, "webhook_configured": bot.WebhookURL != ""})
}

type botSendRequest struct {
	ConversationID string `json:"conversation_id"`
	Username       string `json:"username"`
	Text           string `json:"text"`
}

// botSendMessage sends a text message as the bot, either into a conversation
// it belongs to or to a user (creating the direct chat if needed).
func (s *Server) botSendMessage(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	var req botSendRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, s.log, err)
		return
	}
	text := strings.TrimSpace(req.Text)
	if text == "" || len(text) > 16000 {
		writeError(w, s.log, badRequest("invalid_request", "text must be 1-16000 characters"))
		return
	}
	bot, err := s.store.BotByAccount(r.Context(), p.AccountID)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	var convID string
	switch {
	case req.ConversationID != "":
		id, err := e2e.ParseID(req.ConversationID)
		if err != nil {
			writeError(w, s.log, notFound("not_found", "no such conversation"))
			return
		}
		if _, err := s.store.ConversationForAccount(r.Context(), id.String(), p.AccountID); err != nil {
			writeError(w, s.log, err)
			return
		}
		convID = id.String()
	case req.Username != "":
		username, ok := normalizeUsername(req.Username)
		if !ok {
			writeError(w, s.log, notFound("user_not_found", "no such user"))
			return
		}
		target, err := s.store.AccountByUsername(r.Context(), username)
		if errors.Is(err, store.ErrNotFound) || (err == nil && (target.Disabled || target.IsBot)) {
			writeError(w, s.log, notFound("user_not_found", "no such user"))
			return
		}
		if err != nil {
			writeError(w, s.log, err)
			return
		}
		id, created, err := s.store.CreateDirect(r.Context(), newID(), p.AccountID, target.ID, time.Now().Unix())
		if err != nil {
			writeError(w, s.log, err)
			return
		}
		if created {
			s.notify([]string{target.ID}, eventPayload{Kind: "conv.updated", ConvID: id, Actor: p.AccountID})
		}
		convID = id
	default:
		writeError(w, s.log, badRequest("invalid_request", "conversation_id or username is required"))
		return
	}
	res, err := s.bots.sendAsBot(r.Context(), bot, convID, text)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"conversation_id": convID, "seq": res.Seq, "message_id": res.ClientMsgID, "server_ts": res.ServerTS})
}

// botUpdates returns queued updates, optionally long-polling for new ones.
func (s *Server) botUpdates(w http.ResponseWriter, r *http.Request) {
	p := principal(r)
	after := queryInt(r, "after", 0)
	limit := int(queryInt(r, "limit", 100))
	wait := queryInt(r, "wait", 0)
	if wait < 0 {
		wait = 0
	}
	if wait > 30 {
		wait = 30
	}
	deadline := time.Now().Add(time.Duration(wait) * time.Second)
	for {
		ups, err := s.store.BotUpdates(r.Context(), p.AccountID, after, limit)
		if err != nil {
			writeError(w, s.log, err)
			return
		}
		if len(ups) > 0 || !time.Now().Before(deadline) {
			out := make([]json.RawMessage, 0, len(ups))
			next := after
			for _, u := range ups {
				out = append(out, withUpdateID(u))
				next = u.ID
			}
			w.Header().Set("Cache-Control", "no-store")
			writeJSON(w, http.StatusOK, map[string]any{"updates": out, "next": next})
			return
		}
		if !s.bots.waitFor(r.Context(), p.AccountID, time.Until(deadline)) {
			writeJSON(w, http.StatusOK, map[string]any{"updates": []json.RawMessage{}, "next": after})
			return
		}
	}
}

func withUpdateID(u store.BotUpdate) json.RawMessage {
	var m map[string]any
	if err := json.Unmarshal([]byte(u.Payload), &m); err != nil {
		return json.RawMessage(`{"id":` + strconv.FormatInt(u.ID, 10) + `}`)
	}
	m["id"] = u.ID
	b, _ := json.Marshal(m)
	return b
}

func decodeKeyParam(s string) []byte {
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b
	}
	if b, err := base64.RawURLEncoding.DecodeString(s); err == nil {
		return b
	}
	if b, err := base64.URLEncoding.DecodeString(s); err == nil {
		return b
	}
	return nil
}

// botFile decrypts an attachment for a bot (bots are server-side, so the
// server may do the decryption for them) and streams the plaintext.
func (s *Server) botFile(w http.ResponseWriter, r *http.Request) {
	b, err := s.blobForMember(r, r.PathValue("id"))
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	q := r.URL.Query()
	key := decodeKeyParam(q.Get("key"))
	nonce := decodeKeyParam(q.Get("nonce"))
	if len(key) != 32 || len(nonce) != chacha20poly1305.NonceSizeX {
		writeError(w, s.log, badRequest("invalid_request", "key and nonce query parameters are required"))
		return
	}
	data, err := os.ReadFile(s.blobPath(b.ID))
	if err != nil {
		writeError(w, s.log, notFound("not_found", "attachment data is gone"))
		return
	}
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		writeError(w, s.log, err)
		return
	}
	plain, err := aead.Open(nil, nonce, data, []byte("msgr-blob-v1"))
	if err != nil {
		writeError(w, s.log, badRequest("decrypt_failed", "the key does not open this attachment"))
		return
	}
	mime := q.Get("mime")
	if mime == "" || strings.ContainsAny(mime, "\r\n") {
		mime = "application/octet-stream"
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if name := q.Get("name"); name != "" && !strings.ContainsAny(name, "\r\n\"") {
		w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	}
	w.Header().Set("Cache-Control", "no-store")
	_, _ = io.Copy(w, strings.NewReader(string(plain)))
}
