package api

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/auth"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
	"github.com/william-aqn/family-messenger-e2e/pkg/e2e"
)

// botBridge is the server-side end of every bot: it decrypts messages sent
// to bots, queues them as JSON updates (polled or pushed to a webhook) and
// encrypts the bots' replies. Conversations with bots are therefore
// readable by the server, which the clients make visible with a badge.
type botBridge struct {
	s      *Server
	client *http.Client

	mu      sync.Mutex
	waiters map[string][]chan struct{}
	wg      sync.WaitGroup
}

func newBotBridge(s *Server) *botBridge {
	return &botBridge{s: s, client: &http.Client{Timeout: 10 * time.Second}, waiters: make(map[string][]chan struct{})}
}

type botRef struct {
	ID       string `json:"id"`
	Username string `json:"username"`
}

type botConvRef struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"`
	Members int    `json:"members"`
}

type botFileInfo struct {
	Blob        string `json:"blob"`
	Key         string `json:"key"`
	Nonce       string `json:"nonce"`
	Name        string `json:"name"`
	Mime        string `json:"mime"`
	Size        int64  `json:"size"`
	DownloadURL string `json:"download_url"`
}

type botMessageInfo struct {
	ID      string       `json:"id"`
	Seq     int64        `json:"seq"`
	TS      int64        `json:"ts"`
	Text    string       `json:"text,omitempty"`
	Command string       `json:"command,omitempty"`
	Args    string       `json:"args,omitempty"`
	File    *botFileInfo `json:"file,omitempty"`
}

// botUpdate is the JSON object bots receive (docs/BOTS.md).
type botUpdate struct {
	ID           int64           `json:"id"`
	Type         string          `json:"type"`
	CreatedAt    int64           `json:"created_at"`
	Bot          botRef          `json:"bot"`
	Conversation botConvRef      `json:"conversation"`
	From         *botRef         `json:"from,omitempty"`
	Message      *botMessageInfo `json:"message,omitempty"`
}

func to32(b []byte) (out [32]byte) {
	copy(out[:], b)
	return out
}

// onStored is called synchronously after a message was stored and fanned
// out. Messages from bots are not delivered to other bots.
func (b *botBridge) onStored(ctx context.Context, p *auth.Principal, e *e2e.Envelope, convID string, seq, serverTS int64, members []string) {
	if p.IsBot {
		return
	}
	bots, err := b.s.store.BotsAmong(ctx, members)
	if err != nil {
		b.s.log.Error("bot lookup failed", "err", err)
		return
	}
	if len(bots) == 0 {
		return
	}
	conv, err := b.s.store.ConversationForAccount(ctx, convID, bots[0].AccountID)
	if err != nil {
		return
	}
	for i := range bots {
		bot := &bots[i]
		if bot.Disabled || !e.IsRecipient(mustID(bot.AccountID)) {
			continue
		}
		keys, err := e2e.AccountKeysFromSecrets(to32(bot.SignSeed), to32(bot.EncPriv))
		if err != nil {
			continue
		}
		pt, err := e.Decrypt(mustID(bot.AccountID), keys.EncPriv)
		if err != nil {
			b.s.log.Warn("bot cannot decrypt message", "bot", bot.Username, "err", err)
			continue
		}
		var payload map[string]any
		if err := json.Unmarshal(pt, &payload); err != nil {
			continue
		}
		upd := botUpdate{
			CreatedAt:    serverTS,
			Bot:          botRef{ID: bot.AccountID, Username: bot.Username},
			Conversation: botConvRef{ID: convID, Kind: conv.Kind, Members: len(conv.Members)},
			From:         &botRef{ID: p.AccountID, Username: p.Username},
			Message:      &botMessageInfo{ID: e.ClientMsgID.String(), Seq: seq, TS: int64(e.TimestampMS)},
		}
		t, _ := payload["t"].(string)
		switch t {
		case "text":
			body, _ := payload["body"].(string)
			upd.Type = "message"
			upd.Message.Text = body
			if strings.HasPrefix(body, "/") && len(body) > 1 {
				cmd, args, _ := strings.Cut(strings.TrimPrefix(body, "/"), " ")
				cmd, _, _ = strings.Cut(cmd, "@") // "/start@weatherbot"
				upd.Type = "command"
				upd.Message.Command = cmd
				upd.Message.Args = strings.TrimSpace(args)
			}
		case "file":
			upd.Type = "file"
			f := &botFileInfo{}
			f.Blob, _ = payload["blob"].(string)
			f.Key, _ = payload["key"].(string)
			f.Nonce, _ = payload["nonce"].(string)
			f.Name, _ = payload["name"].(string)
			f.Mime, _ = payload["mime"].(string)
			if size, ok := payload["size"].(float64); ok {
				f.Size = int64(size)
			}
			f.DownloadURL = "/api/v1/bot/files/" + f.Blob + "?key=" + url.QueryEscape(f.Key) + "&nonce=" + url.QueryEscape(f.Nonce) + "&mime=" + url.QueryEscape(f.Mime) + "&name=" + url.QueryEscape(f.Name)
			upd.Message.File = f
		default:
			continue
		}
		b.enqueue(ctx, bot, upd)
	}
}

// onJoined queues a "joined" update when a bot is added to a conversation.
func (b *botBridge) onJoined(ctx context.Context, botID string, conv *store.ConversationWithMembers, actor *auth.Principal) {
	bot, err := b.s.store.BotByAccount(ctx, botID)
	if err != nil {
		return
	}
	b.enqueue(ctx, bot, botUpdate{
		Type:         "joined",
		CreatedAt:    time.Now().UnixMilli(),
		Bot:          botRef{ID: bot.AccountID, Username: bot.Username},
		Conversation: botConvRef{ID: conv.ID, Kind: conv.Kind, Members: len(conv.Members)},
		From:         &botRef{ID: actor.AccountID, Username: actor.Username},
	})
}

func (b *botBridge) enqueue(ctx context.Context, bot *store.Bot, upd botUpdate) {
	if upd.CreatedAt == 0 {
		upd.CreatedAt = time.Now().UnixMilli()
	}
	payload, err := json.Marshal(upd)
	if err != nil {
		return
	}
	id, err := b.s.store.AddBotUpdate(ctx, bot.AccountID, upd.CreatedAt, string(payload))
	if err != nil {
		b.s.log.Error("cannot queue bot update", "err", err)
		return
	}
	upd.ID = id
	b.wake(bot.AccountID)
	if bot.WebhookURL != "" {
		b.wg.Add(1)
		go b.deliver(*bot, upd)
	}
}

func (b *botBridge) wake(botID string) {
	b.mu.Lock()
	for _, ch := range b.waiters[botID] {
		close(ch)
	}
	delete(b.waiters, botID)
	b.mu.Unlock()
}

// waitFor blocks until an update is queued for the bot, the timeout passes
// or the request is cancelled; it reports whether a wake-up happened.
func (b *botBridge) waitFor(ctx context.Context, botID string, timeout time.Duration) bool {
	if timeout <= 0 {
		return false
	}
	ch := make(chan struct{})
	b.mu.Lock()
	b.waiters[botID] = append(b.waiters[botID], ch)
	b.mu.Unlock()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-ch:
		return true
	case <-timer.C:
	case <-ctx.Done():
	}
	b.mu.Lock()
	list := b.waiters[botID]
	for i, c := range list {
		if c == ch {
			b.waiters[botID] = append(list[:i], list[i+1:]...)
			break
		}
	}
	b.mu.Unlock()
	return false
}

// deliver POSTs the update to the bot's webhook with an HMAC signature,
// retrying transient failures. A JSON response {"reply": "..."} is sent
// back into the conversation as the bot.
func (b *botBridge) deliver(bot store.Bot, upd botUpdate) {
	defer b.wg.Done()
	body, err := json.Marshal(upd)
	if err != nil {
		return
	}
	mac := hmac.New(sha256.New, []byte(bot.WebhookSecret))
	mac.Write(body)
	signature := "sha256=" + hex.EncodeToString(mac.Sum(nil))
	delays := []time.Duration{0, time.Second, 5 * time.Second, 30 * time.Second}
	for attempt, delay := range delays {
		if delay > 0 {
			time.Sleep(delay)
		}
		req, err := http.NewRequest(http.MethodPost, bot.WebhookURL, bytes.NewReader(body))
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("User-Agent", "family-messenger-bot-bridge/"+Version)
		req.Header.Set("X-Messenger-Bot", bot.Username)
		req.Header.Set("X-Messenger-Signature", signature)
		res, err := b.client.Do(req)
		if err != nil {
			b.s.log.Warn("webhook request failed", "bot", bot.Username, "attempt", attempt+1, "err", err)
			continue
		}
		respBody, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
		res.Body.Close()
		if res.StatusCode >= 500 || res.StatusCode == http.StatusTooManyRequests {
			b.s.log.Warn("webhook returned error", "bot", bot.Username, "status", res.StatusCode, "attempt", attempt+1)
			continue
		}
		if res.StatusCode >= 300 {
			b.s.log.Warn("webhook rejected update", "bot", bot.Username, "status", res.StatusCode)
			return
		}
		var reply struct {
			Reply string `json:"reply"`
		}
		if json.Unmarshal(respBody, &reply) == nil && strings.TrimSpace(reply.Reply) != "" && upd.Conversation.ID != "" {
			if _, err := b.sendAsBot(context.Background(), &bot, upd.Conversation.ID, strings.TrimSpace(reply.Reply)); err != nil {
				b.s.log.Warn("webhook reply failed", "bot", bot.Username, "err", err)
			}
		}
		return
	}
	b.s.log.Error("webhook delivery gave up", "bot", bot.Username, "update", upd.ID)
}

// sendAsBot encrypts a text message with the bot's keys to every member of
// the conversation and stores it through the normal message path.
func (b *botBridge) sendAsBot(ctx context.Context, bot *store.Bot, convID, text string) (*sendResult, error) {
	members, err := b.s.store.MemberAccountIDs(ctx, convID)
	if err != nil {
		return nil, err
	}
	accts, err := b.s.store.AccountsByIDs(ctx, members)
	if err != nil {
		return nil, err
	}
	keys, err := e2e.AccountKeysFromSecrets(to32(bot.SignSeed), to32(bot.EncPriv))
	if err != nil {
		return nil, err
	}
	recipients := make([]e2e.Recipient, 0, len(accts))
	for _, a := range accts {
		recipients = append(recipients, e2e.Recipient{Account: mustID(a.ID), EncPub: to32(a.EncPub)})
	}
	msgID, err := e2e.NewID()
	if err != nil {
		return nil, err
	}
	hdr := e2e.Header{ConvID: mustID(convID), SenderAccount: mustID(bot.AccountID), SenderDevice: mustID(bot.DeviceID), ClientMsgID: msgID, TimestampMS: uint64(time.Now().UnixMilli())}
	plaintext, err := json.Marshal(struct {
		T    string `json:"t"`
		Body string `json:"body"`
	}{"text", text})
	if err != nil {
		return nil, err
	}
	env, sig, err := e2e.Encrypt(keys, hdr, recipients, plaintext)
	if err != nil {
		return nil, err
	}
	p := &auth.Principal{AccountID: bot.AccountID, DeviceID: bot.DeviceID, Username: bot.Username, SignPub: keys.SignPub[:], EncPub: keys.EncPub[:], IsBot: true}
	return b.s.sendEnvelope(ctx, p, convID, env, sig)
}

// WaitForWebhooks blocks until in-flight webhook deliveries finish (tests).
func (s *Server) WaitForWebhooks() { s.bots.wg.Wait() }

func mustID(s string) e2e.ID {
	id, err := e2e.ParseID(s)
	if err != nil {
		panic("invalid id in database: " + s)
	}
	return id
}
