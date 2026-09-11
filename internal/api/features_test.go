package api_test

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/william-aqn/family-messenger-e2e/internal/api"
	"github.com/william-aqn/family-messenger-e2e/internal/config"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
)

type testEnv struct {
	ts  *httptest.Server
	st  *store.Store
	srv *api.Server
	cfg *config.Config
}

func newTestEnv(t *testing.T, registration string) *testEnv {
	t.Helper()
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{Addr: ":0", DataDir: t.TempDir(), Registration: registration, ServerSecret: []byte("test-secret"), TURNTTL: time.Hour}
	srv, err := api.New(cfg, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(func() {
		srv.Close()
		ts.Close()
		st.Close()
	})
	return &testEnv{ts: ts, st: st, srv: srv, cfg: cfg}
}

func to32b(b []byte) (out [32]byte) {
	copy(out[:], b)
	return out
}

// raw performs a non-JSON request and returns the status and body.
func (c *client) raw(method, path string, body []byte, contentType string) (int, []byte) {
	c.t.Helper()
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, c.base+path, rd)
	if err != nil {
		c.t.Fatal(err)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	req.Header.Set("X-Forwarded-For", c.ip)
	res, err := c.http.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	return res.StatusCode, data
}

func TestAdminPanel(t *testing.T) {
	env := newTestEnv(t, "open")
	base := env.ts.URL
	alice := register(t, base, "alice", "alice-password-123")
	bob := register(t, base, "bob", "bob-password-123")

	var me struct {
		Account struct {
			IsAdmin bool `json:"is_admin"`
		} `json:"account"`
		Settings map[string]any `json:"settings"`
	}
	alice.must("GET", "/api/v1/me", nil, &me, http.StatusOK)
	if !me.Account.IsAdmin {
		t.Fatal("the first account must be an administrator")
	}
	bob.must("GET", "/api/v1/me", nil, &me, http.StatusOK)
	if me.Account.IsAdmin {
		t.Fatal("the second account must not be an administrator")
	}
	if status := bob.do("GET", "/api/v1/admin/stats", nil, nil); status != http.StatusForbidden {
		t.Fatalf("non-admin stats status %d", status)
	}
	var stats struct {
		Accounts int64  `json:"accounts"`
		Version  string `json:"version"`
	}
	alice.must("GET", "/api/v1/admin/stats", nil, &stats, http.StatusOK)
	if stats.Accounts != 2 || stats.Version == "" {
		t.Fatalf("stats: %+v", stats)
	}

	var st map[string]any
	alice.must("GET", "/api/v1/admin/settings", nil, &st, http.StatusOK)
	if st["registration"] != "open" {
		t.Fatalf("default settings: %v", st)
	}
	alice.must("PUT", "/api/v1/admin/settings", map[string]any{"registration": "invite", "announcement": "Welcome!"}, &st, http.StatusOK)
	if st["registration"] != "invite" || st["announcement"] != "Welcome!" {
		t.Fatalf("updated settings: %v", st)
	}
	if status := alice.do("PUT", "/api/v1/admin/settings", map[string]any{"registration": "weird"}, nil); status != http.StatusBadRequest {
		t.Fatalf("invalid settings status %d", status)
	}
	var info struct {
		Registration string `json:"registration"`
		Announcement string `json:"announcement"`
	}
	newClient(t, base, "").must("GET", "/api/v1/info", nil, &info, http.StatusOK)
	if info.Registration != "invite" || info.Announcement != "Welcome!" {
		t.Fatalf("public info: %+v", info)
	}

	carolBody, _ := registerBody(t, "carol", "carol-password-123", "")
	anon := newClient(t, base, "")
	if status := anon.do("POST", "/api/v1/auth/register", carolBody, nil); status != http.StatusForbidden {
		t.Fatalf("registration without invite status %d", status)
	}
	var created struct {
		Codes []string `json:"codes"`
	}
	alice.must("POST", "/api/v1/admin/invites", map[string]any{"count": 2, "note": "friends", "expires_hours": 24}, &created, http.StatusCreated)
	if len(created.Codes) != 2 {
		t.Fatalf("invites: %+v", created)
	}
	carolBody["invite"] = created.Codes[0]
	var carolSess session
	anon.must("POST", "/api/v1/auth/register", carolBody, &carolSess, http.StatusCreated)
	carol := newClient(t, base, "carol")
	carol.token, carol.accountID = carolSess.Token, carolSess.AccountID
	var invites struct {
		Invites []struct {
			Code   string `json:"code"`
			Note   string `json:"note"`
			UsedBy string `json:"used_by"`
		} `json:"invites"`
	}
	alice.must("GET", "/api/v1/admin/invites", nil, &invites, http.StatusOK)
	used, unused := 0, 0
	for _, i := range invites.Invites {
		if i.Note != "friends" {
			t.Fatalf("invite note lost: %+v", i)
		}
		if i.UsedBy == "carol" {
			used++
		} else if i.UsedBy == "" {
			unused++
		}
	}
	if used != 1 || unused != 1 {
		t.Fatalf("invite usage: %+v", invites)
	}
	alice.must("DELETE", "/api/v1/admin/invites/"+created.Codes[1], nil, nil, http.StatusNoContent)
	if status := alice.do("DELETE", "/api/v1/admin/invites/"+created.Codes[0], nil, nil); status != http.StatusNotFound {
		t.Fatalf("deleting a used invite status %d", status)
	}
	if err := env.st.CreateInvite(context.Background(), "expired1", "", "", time.Now().Unix()-10); err != nil {
		t.Fatal(err)
	}
	daveBody, _ := registerBody(t, "dave", "dave-password-123", "expired1")
	if status := anon.do("POST", "/api/v1/auth/register", daveBody, nil); status != http.StatusForbidden {
		t.Fatalf("expired invite status %d", status)
	}

	var users struct {
		Users []struct {
			ID       string `json:"id"`
			Username string `json:"username"`
			Disabled bool   `json:"disabled"`
			IsAdmin  bool   `json:"is_admin"`
		} `json:"users"`
	}
	alice.must("GET", "/api/v1/admin/users?q=bo", nil, &users, http.StatusOK)
	if len(users.Users) != 1 || users.Users[0].Username != "bob" {
		t.Fatalf("user search: %+v", users)
	}

	alice.must("PATCH", "/api/v1/admin/users/"+bob.accountID, map[string]any{"disabled": true}, nil, http.StatusOK)
	if status := bob.do("GET", "/api/v1/me", nil, nil); status != http.StatusForbidden && status != http.StatusUnauthorized {
		t.Fatalf("disabled account status %d", status)
	}
	if _, status := login(t, base, "bob", "bob-password-123"); status != http.StatusForbidden {
		t.Fatalf("disabled login status %d", status)
	}
	if status := alice.do("GET", "/api/v1/users/bob", nil, nil); status != http.StatusNotFound {
		t.Fatalf("disabled user lookup status %d", status)
	}
	alice.must("PATCH", "/api/v1/admin/users/"+bob.accountID, map[string]any{"disabled": false, "is_admin": true}, nil, http.StatusOK)
	bob2, status := login(t, base, "bob", "bob-password-123")
	if status != http.StatusOK {
		t.Fatalf("re-enabled login status %d", status)
	}
	bob2.must("GET", "/api/v1/admin/stats", nil, &stats, http.StatusOK)
	if status := alice.do("PATCH", "/api/v1/admin/users/"+alice.accountID, map[string]any{"is_admin": false}, nil); status != http.StatusBadRequest {
		t.Fatalf("self lockout status %d", status)
	}

	alice.must("POST", "/api/v1/admin/users/"+carol.accountID+"/logout", nil, nil, http.StatusNoContent)
	if status := carol.do("GET", "/api/v1/me", nil, nil); status != http.StatusUnauthorized {
		t.Fatalf("token after forced logout status %d", status)
	}
	alice.must("DELETE", "/api/v1/admin/users/"+carol.accountID, nil, nil, http.StatusNoContent)
	if status := alice.do("DELETE", "/api/v1/admin/users/"+carol.accountID, nil, nil); status != http.StatusNotFound {
		t.Fatalf("deleting twice status %d", status)
	}
	if status := alice.do("DELETE", "/api/v1/admin/users/"+alice.accountID, nil, nil); status != http.StatusBadRequest {
		t.Fatalf("self delete status %d", status)
	}

	status, body := alice.raw("POST", "/api/v1/admin/backup", nil, "")
	if status != http.StatusOK || !bytes.HasPrefix(body, []byte("SQLite format 3\x00")) {
		t.Fatalf("backup: status %d, %d bytes", status, len(body))
	}
}

func TestBots(t *testing.T) {
	env := newTestEnv(t, "open")
	base := env.ts.URL
	alice := register(t, base, "alice", "alice-password-123")
	bob := register(t, base, "bob", "bob-password-123")

	var mu sync.Mutex
	var received []map[string]any
	var secret string
	hook := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mac := hmac.New(sha256.New, []byte(secret))
		mac.Write(body)
		if r.Header.Get("X-Messenger-Signature") != "sha256="+hex.EncodeToString(mac.Sum(nil)) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		var u map[string]any
		_ = json.Unmarshal(body, &u)
		mu.Lock()
		received = append(received, u)
		mu.Unlock()
		if u["type"] == "message" {
			text := u["message"].(map[string]any)["text"].(string)
			_ = json.NewEncoder(w).Encode(map[string]string{"reply": "echo: " + text})
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer hook.Close()

	var created struct {
		Bot struct {
			ID       string `json:"id"`
			Username string `json:"username"`
			SignPub  []byte `json:"sign_pub"`
			EncPub   []byte `json:"enc_pub"`
		} `json:"bot"`
		Token         string `json:"token"`
		WebhookSecret string `json:"webhook_secret"`
	}
	alice.must("POST", "/api/v1/bots", map[string]any{"username": "echobot", "display_name": "Echo", "webhook_url": hook.URL}, &created, http.StatusCreated)
	secret = created.WebhookSecret
	if status := alice.do("POST", "/api/v1/bots", map[string]any{"username": "nosuffix"}, nil); status != http.StatusBadRequest {
		t.Fatalf("bot username without suffix status %d", status)
	}
	if status := alice.do("POST", "/api/v1/bots", map[string]any{"username": "otherbot", "webhook_url": "ftp://x"}, nil); status != http.StatusBadRequest {
		t.Fatalf("bad webhook status %d", status)
	}
	var list struct {
		Bots []struct {
			ID string `json:"id"`
		} `json:"bots"`
	}
	bob.must("GET", "/api/v1/bots", nil, &list, http.StatusOK)
	if len(list.Bots) != 0 {
		t.Fatal("bob must not see alice's bots")
	}
	alice.must("GET", "/api/v1/bots", nil, &list, http.StatusOK)
	if len(list.Bots) != 1 || list.Bots[0].ID != created.Bot.ID {
		t.Fatalf("owner bot list: %+v", list)
	}

	botc := newClient(t, base, "echobot")
	botc.token = created.Token
	botc.accountID = created.Bot.ID
	var bme struct {
		Owner string `json:"owner"`
	}
	botc.must("GET", "/api/v1/bot/me", nil, &bme, http.StatusOK)
	if bme.Owner != "alice" {
		t.Fatalf("bot owner %q", bme.Owner)
	}
	if status := botc.do("POST", "/api/v1/bots", map[string]any{"username": "subbot"}, nil); status != http.StatusForbidden {
		t.Fatalf("bot creating bots status %d", status)
	}
	if status := alice.do("GET", "/api/v1/bot/updates", nil, nil); status != http.StatusForbidden {
		t.Fatalf("human on bot api status %d", status)
	}
	if _, status := login(t, base, "echobot", "whatever-password"); status != http.StatusUnauthorized {
		t.Fatalf("bot password login status %d", status)
	}

	var u struct {
		ID    string `json:"id"`
		IsBot bool   `json:"is_bot"`
	}
	alice.must("GET", "/api/v1/users/echobot", nil, &u, http.StatusOK)
	if !u.IsBot || u.ID != created.Bot.ID {
		t.Fatalf("bot lookup: %+v", u)
	}
	var conv convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": created.Bot.ID}, &conv, http.StatusCreated)

	var ups struct {
		Updates []map[string]any `json:"updates"`
		Next    int64            `json:"next"`
	}
	botc.must("GET", "/api/v1/bot/updates", nil, &ups, http.StatusOK)
	if len(ups.Updates) != 1 || ups.Updates[0]["type"] != "joined" || ups.Updates[0]["conversation"].(map[string]any)["id"] != conv.ID {
		t.Fatalf("joined update: %+v", ups)
	}
	cursor := ups.Next

	aliceWS := alice.connectWS()
	alice.must("POST", "/api/v1/conversations/"+conv.ID+"/messages", alice.envelope(conv.ID, 0, conv.Members, `{"t":"text","body":"hello bot"}`), nil, http.StatusCreated)
	aliceWS.expectMessage() // own echo of the sent message
	botc.must("GET", "/api/v1/bot/updates?after="+itoa64(cursor), nil, &ups, http.StatusOK)
	if len(ups.Updates) != 1 || ups.Updates[0]["type"] != "message" {
		t.Fatalf("message update: %+v", ups)
	}
	msg := ups.Updates[0]["message"].(map[string]any)
	if msg["text"] != "hello bot" || ups.Updates[0]["from"].(map[string]any)["username"] != "alice" {
		t.Fatalf("message update content: %+v", ups.Updates[0])
	}
	cursor = ups.Next

	env.srv.WaitForWebhooks()
	reply := aliceWS.expectMessage()
	if reply.SenderAccount != created.Bot.ID {
		t.Fatalf("expected the webhook reply from the bot, got sender %s", reply.SenderAccount)
	}
	if pt := alice.decrypt(to32b(created.Bot.SignPub), reply.Env, reply.Sig); pt != `{"t":"text","body":"echo: hello bot"}` {
		t.Fatalf("webhook reply decrypted to %q", pt)
	}

	alice.must("POST", "/api/v1/conversations/"+conv.ID+"/messages", alice.envelope(conv.ID, 0, conv.Members, `{"t":"text","body":"/start now please"}`), nil, http.StatusCreated)
	botc.must("GET", "/api/v1/bot/updates?after="+itoa64(cursor), nil, &ups, http.StatusOK)
	if len(ups.Updates) != 1 || ups.Updates[0]["type"] != "command" {
		t.Fatalf("command update: %+v", ups)
	}
	msg = ups.Updates[0]["message"].(map[string]any)
	if msg["command"] != "start" || msg["args"] != "now please" {
		t.Fatalf("command parsing: %+v", msg)
	}
	cursor = ups.Next
	aliceWS.expectMessage()
	env.srv.WaitForWebhooks()

	// Long polling returns as soon as an update is queued.
	done := make(chan struct{})
	go func() {
		defer close(done)
		var polled struct {
			Updates []map[string]any `json:"updates"`
		}
		botc.must("GET", "/api/v1/bot/updates?wait=10&after="+itoa64(cursor), nil, &polled, http.StatusOK)
		if len(polled.Updates) != 1 || polled.Updates[0]["message"].(map[string]any)["text"] != "wake up" {
			t.Errorf("long poll result: %+v", polled)
		}
	}()
	time.Sleep(200 * time.Millisecond)
	start := time.Now()
	alice.must("POST", "/api/v1/conversations/"+conv.ID+"/messages", alice.envelope(conv.ID, 0, conv.Members, `{"t":"text","body":"wake up"}`), nil, http.StatusCreated)
	select {
	case <-done:
		if time.Since(start) > 5*time.Second {
			t.Fatal("long poll did not wake up promptly")
		}
	case <-time.After(15 * time.Second):
		t.Fatal("long poll never returned")
	}
	aliceWS.expectMessage()
	env.srv.WaitForWebhooks()
	aliceWS.expectMessage() // webhook echo of "wake up"

	var sent struct {
		ConversationID string `json:"conversation_id"`
		Seq            int64  `json:"seq"`
	}
	botc.must("POST", "/api/v1/bot/messages", map[string]any{"username": "alice", "text": "direct hello"}, &sent, http.StatusCreated)
	if sent.ConversationID != conv.ID {
		t.Fatalf("bot direct message went to %s, want %s", sent.ConversationID, conv.ID)
	}
	if m := aliceWS.expectMessage(); alice.decrypt(to32b(created.Bot.SignPub), m.Env, m.Sig) != `{"t":"text","body":"direct hello"}` {
		t.Fatal("bot direct message not received")
	}

	var group convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "group", "member_ids": []string{bob.accountID, created.Bot.ID}}, &group, http.StatusCreated)
	bobWS := bob.connectWS()
	botc.must("POST", "/api/v1/bot/messages", map[string]any{"conversation_id": group.ID, "text": "hi group"}, &sent, http.StatusCreated)
	if m := bobWS.expectMessage(); bob.decrypt(to32b(created.Bot.SignPub), m.Env, m.Sig) != `{"t":"text","body":"hi group"}` {
		t.Fatal("bot group message not received by bob")
	}
	var direct convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": bob.accountID}, &direct, http.StatusCreated)
	if status := botc.do("POST", "/api/v1/bot/messages", map[string]any{"conversation_id": direct.ID, "text": "intruder"}, nil); status != http.StatusNotFound {
		t.Fatalf("bot sending to a foreign conversation status %d", status)
	}
	var bobSent struct {
		ClientMsgID string `json:"client_msg_id"`
		Seq         int64  `json:"seq"`
	}
	bob.must("POST", "/api/v1/conversations/"+group.ID+"/messages", bob.envelope(group.ID, 0, group.Members, `{"t":"text","body":"bob in group"}`), &bobSent, http.StatusCreated)
	botc.must("GET", "/api/v1/bot/updates?after="+itoa64(cursor+1), nil, &ups, http.StatusOK)
	var sawGroup bool
	for _, up := range ups.Updates {
		if up["type"] == "message" && up["conversation"].(map[string]any)["kind"] == "group" && up["message"].(map[string]any)["text"] == "bob in group" {
			sawGroup = true
		}
	}
	if !sawGroup {
		t.Fatalf("group message update missing: %+v", ups.Updates)
	}
	env.srv.WaitForWebhooks()

	// Edits and deletions reach the bot as "edited" and "deleted" updates
	// that name the original message.
	bob.must("POST", "/api/v1/conversations/"+group.ID+"/messages", bob.envelope(group.ID, 0, group.Members, `{"t":"text.edit","ref":"`+bobSent.ClientMsgID+`","body":"bob edited"}`), nil, http.StatusCreated)
	bob.must("DELETE", "/api/v1/conversations/"+group.ID+"/messages/"+itoa64(bobSent.Seq), nil, nil, http.StatusNoContent)
	botc.must("GET", "/api/v1/bot/updates?after=0", nil, &ups, http.StatusOK)
	var sawEdit, sawDelete bool
	for _, up := range ups.Updates {
		m, _ := up["message"].(map[string]any)
		if m == nil || m["id"] != bobSent.ClientMsgID {
			continue
		}
		if up["type"] == "edited" && m["text"] == "bob edited" {
			sawEdit = true
		}
		if up["type"] == "deleted" && m["seq"] == float64(bobSent.Seq) && up["from"].(map[string]any)["username"] == "bob" {
			sawDelete = true
		}
	}
	if !sawEdit || !sawDelete {
		t.Fatalf("edit/delete updates missing (edit=%v delete=%v): %+v", sawEdit, sawDelete, ups.Updates)
	}
	env.srv.WaitForWebhooks()

	mu.Lock()
	types := map[string]int{}
	for _, r := range received {
		types[r["type"].(string)]++
	}
	mu.Unlock()
	if types["joined"] < 2 || types["message"] < 2 || types["command"] < 1 {
		t.Fatalf("webhook deliveries: %v", types)
	}

	var rot struct {
		Token string `json:"token"`
	}
	alice.must("POST", "/api/v1/bots/"+created.Bot.ID+"/rotate", nil, &rot, http.StatusOK)
	if status := botc.do("GET", "/api/v1/bot/me", nil, nil); status != http.StatusUnauthorized {
		t.Fatalf("old bot token status %d", status)
	}
	botc.token = rot.Token
	botc.must("GET", "/api/v1/bot/me", nil, nil, http.StatusOK)
	if status := bob.do("POST", "/api/v1/bots/"+created.Bot.ID+"/rotate", nil, nil); status != http.StatusNotFound {
		t.Fatalf("non-owner rotate status %d", status)
	}

	alice.must("PUT", "/api/v1/admin/settings", map[string]any{"allow_bots": false}, nil, http.StatusOK)
	if status := alice.do("POST", "/api/v1/bots", map[string]any{"username": "latebot"}, nil); status != http.StatusForbidden {
		t.Fatalf("bots disabled status %d", status)
	}

	alice.must("DELETE", "/api/v1/bots/"+created.Bot.ID, nil, nil, http.StatusNoContent)
	if status := alice.do("GET", "/api/v1/users/echobot", nil, nil); status != http.StatusNotFound {
		t.Fatalf("deleted bot lookup status %d", status)
	}
	if status := botc.do("GET", "/api/v1/bot/me", nil, nil); status != http.StatusUnauthorized {
		t.Fatalf("deleted bot token status %d", status)
	}
}

func itoa64(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func TestAttachmentsAndRetention(t *testing.T) {
	env := newTestEnv(t, "open")
	base := env.ts.URL
	alice := register(t, base, "alice", "alice-password-123")
	bob := register(t, base, "bob", "bob-password-123")
	carol := register(t, base, "carol", "carol-password-123")
	var conv convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": bob.accountID}, &conv, http.StatusCreated)

	data := make([]byte, 1000)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	status, body := alice.raw("POST", "/api/v1/conversations/"+conv.ID+"/blobs", data, "application/octet-stream")
	if status != http.StatusCreated {
		t.Fatalf("upload status %d: %s", status, body)
	}
	var up struct {
		ID   string `json:"id"`
		Size int64  `json:"size"`
	}
	if err := json.Unmarshal(body, &up); err != nil || up.Size != 1000 || len(up.ID) != 32 {
		t.Fatalf("upload response: %s %v", body, err)
	}
	if status, got := bob.raw("GET", "/api/v1/blobs/"+up.ID, nil, ""); status != http.StatusOK || !bytes.Equal(got, data) {
		t.Fatalf("download by member: status %d, %d bytes", status, len(got))
	}
	if status, _ := carol.raw("GET", "/api/v1/blobs/"+up.ID, nil, ""); status != http.StatusNotFound {
		t.Fatalf("download by outsider status %d", status)
	}
	if status, _ := newClient(t, base, "").raw("GET", "/api/v1/blobs/"+up.ID, nil, ""); status != http.StatusUnauthorized {
		t.Fatalf("anonymous download status %d", status)
	}
	if status, _ := carol.raw("POST", "/api/v1/conversations/"+conv.ID+"/blobs", data, "application/octet-stream"); status != http.StatusNotFound {
		t.Fatalf("upload by outsider status %d", status)
	}
	if status, _ := alice.raw("POST", "/api/v1/conversations/"+conv.ID+"/blobs", []byte{}, "application/octet-stream"); status != http.StatusBadRequest {
		t.Fatalf("empty upload status %d", status)
	}
	alice.must("PUT", "/api/v1/admin/settings", map[string]any{"max_attachment_bytes": 512}, nil, http.StatusOK)
	if status, _ := alice.raw("POST", "/api/v1/conversations/"+conv.ID+"/blobs", data, "application/octet-stream"); status != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize upload status %d", status)
	}
	alice.must("PUT", "/api/v1/admin/settings", map[string]any{"max_attachment_bytes": 50 << 20}, nil, http.StatusOK)

	if status := alice.do("PUT", "/api/v1/conversations/"+conv.ID+"/retention", map[string]any{"seconds": 30}, nil); status != http.StatusBadRequest {
		t.Fatalf("too short retention status %d", status)
	}
	bob.must("PUT", "/api/v1/conversations/"+conv.ID+"/retention", map[string]any{"seconds": 60}, nil, http.StatusNoContent)
	var view struct {
		RetentionSeconds int64 `json:"retention_seconds"`
	}
	alice.must("GET", "/api/v1/conversations/"+conv.ID, nil, &view, http.StatusOK)
	if view.RetentionSeconds != 60 {
		t.Fatalf("retention not stored: %+v", view)
	}
	var group convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "group", "member_ids": []string{bob.accountID}}, &group, http.StatusCreated)
	if status := bob.do("PUT", "/api/v1/conversations/"+group.ID+"/retention", map[string]any{"seconds": 3600}, nil); status != http.StatusForbidden {
		t.Fatalf("non-owner group retention status %d", status)
	}
	alice.must("PUT", "/api/v1/conversations/"+group.ID+"/retention", map[string]any{"seconds": 3600}, nil, http.StatusNoContent)

	alice.must("POST", "/api/v1/conversations/"+conv.ID+"/messages", alice.envelope(conv.ID, 0, conv.Members, `{"t":"text","body":"vanishing"}`), nil, http.StatusCreated)
	alice.must("POST", "/api/v1/conversations/"+group.ID+"/messages", alice.envelope(group.ID, 0, group.Members, `{"t":"text","body":"stays for an hour"}`), nil, http.StatusCreated)
	blobFile := filepath.Join(env.cfg.DataDir, "blobs", up.ID)
	if _, err := os.Stat(blobFile); err != nil {
		t.Fatalf("blob file missing before purge: %v", err)
	}
	if deleted := env.srv.RunJanitorOnce(context.Background(), time.Now().Add(30*time.Second)); deleted != 0 {
		t.Fatalf("nothing should expire yet, deleted %d", deleted)
	}
	if deleted := env.srv.RunJanitorOnce(context.Background(), time.Now().Add(2*time.Minute)); deleted != 1 {
		t.Fatalf("expected exactly the direct message to expire, deleted %d", deleted)
	}
	var hist struct {
		Messages []msgView `json:"messages"`
	}
	alice.must("GET", "/api/v1/conversations/"+conv.ID+"/messages", nil, &hist, http.StatusOK)
	if len(hist.Messages) != 0 {
		t.Fatalf("expired message still listed: %d", len(hist.Messages))
	}
	if status, _ := bob.raw("GET", "/api/v1/blobs/"+up.ID, nil, ""); status != http.StatusNotFound {
		t.Fatalf("expired blob download status %d", status)
	}
	if _, err := os.Stat(blobFile); !os.IsNotExist(err) {
		t.Fatalf("blob file not removed: %v", err)
	}
	alice.must("GET", "/api/v1/conversations/"+group.ID+"/messages", nil, &hist, http.StatusOK)
	if len(hist.Messages) != 1 {
		t.Fatalf("group message must survive: %d", len(hist.Messages))
	}

	// The global retention cap applies to conversations without a timer.
	var plain convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": carol.accountID}, &plain, http.StatusCreated)
	alice.must("POST", "/api/v1/conversations/"+plain.ID+"/messages", alice.envelope(plain.ID, 0, plain.Members, `{"t":"text","body":"old"}`), nil, http.StatusCreated)
	alice.must("PUT", "/api/v1/admin/settings", map[string]any{"retention_days": 1}, nil, http.StatusOK)
	if deleted := env.srv.RunJanitorOnce(context.Background(), time.Now().Add(48*time.Hour)); deleted < 1 {
		t.Fatalf("global retention did not purge, deleted %d", deleted)
	}
	alice.must("GET", "/api/v1/conversations/"+plain.ID+"/messages", nil, &hist, http.StatusOK)
	if len(hist.Messages) != 0 {
		t.Fatalf("message survived the global retention: %d", len(hist.Messages))
	}
}

func TestMessageDeletion(t *testing.T) {
	env := newTestEnv(t, "open")
	base := env.ts.URL
	admin := register(t, base, "admin", "admin-password-123") // the first account administers the server
	alice := register(t, base, "alice", "alice-password-123")
	bob := register(t, base, "bob", "bob-password-123")
	carol := register(t, base, "carol", "carol-password-123")

	var conv convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": bob.accountID}, &conv, http.StatusCreated)
	msgs := "/api/v1/conversations/" + conv.ID + "/messages"
	bobWS := bob.connectWS()
	for _, m := range []struct {
		c    *client
		body string
	}{{alice, "first"}, {alice, "second"}, {bob, "from bob"}} {
		m.c.must("POST", msgs, m.c.envelope(conv.ID, 0, conv.Members, `{"t":"text","body":"`+m.body+`"}`), nil, http.StatusCreated)
		bobWS.expectMessage()
	}

	// Only the sender or an administrator may delete; outsiders learn nothing.
	if status := bob.do("DELETE", msgs+"/1", nil, nil); status != http.StatusForbidden {
		t.Fatalf("deleting someone else's message status %d", status)
	}
	if status := carol.do("DELETE", msgs+"/1", nil, nil); status != http.StatusNotFound {
		t.Fatalf("outsider delete status %d", status)
	}
	if status := alice.do("DELETE", msgs+"/99", nil, nil); status != http.StatusNotFound {
		t.Fatalf("unknown seq status %d", status)
	}
	alice.must("DELETE", msgs+"/1", nil, nil, http.StatusNoContent)
	rec := bobWS.expectMessage()
	if rec.Seq != 4 || rec.DeletedSeq != 1 || rec.DeletedSender != alice.accountID || rec.SenderAccount != alice.accountID || len(rec.Env) != 0 || len(rec.Sig) != 0 {
		t.Fatalf("deletion record: %+v", rec)
	}
	var hist struct {
		Messages []msgView `json:"messages"`
		LastSeq  int64     `json:"last_seq"`
	}
	bob.must("GET", msgs, nil, &hist, http.StatusOK)
	if len(hist.Messages) != 3 || hist.Messages[0].Seq != 2 || hist.Messages[2].Seq != 4 || hist.Messages[2].DeletedSeq != 1 || hist.LastSeq != 4 {
		t.Fatalf("history after deletion: %+v last_seq=%d", hist.Messages, hist.LastSeq)
	}
	if status := alice.do("DELETE", msgs+"/4", nil, nil); status != http.StatusNotFound {
		t.Fatalf("deleting a deletion record status %d", status)
	}
	if status := alice.do("DELETE", msgs+"/1", nil, nil); status != http.StatusNotFound {
		t.Fatalf("deleting twice status %d", status)
	}
	// The administrator is not a member of the chat but may remove any message.
	if status := alice.do("DELETE", msgs+"/3", nil, nil); status != http.StatusForbidden {
		t.Fatalf("non-admin deleting bob's message status %d", status)
	}
	admin.must("DELETE", msgs+"/3", nil, nil, http.StatusNoContent)
	rec = bobWS.expectMessage()
	if rec.Seq != 5 || rec.DeletedSeq != 3 || rec.SenderAccount != admin.accountID || rec.DeletedSender != bob.accountID {
		t.Fatalf("admin deletion record: %+v", rec)
	}
	var stats struct {
		Messages int64 `json:"messages"`
	}
	admin.must("GET", "/api/v1/admin/stats", nil, &stats, http.StatusOK)
	if stats.Messages != 1 {
		t.Fatalf("stats count %d messages, want 1", stats.Messages)
	}

	// Attachments: the uploader or an administrator drops the ciphertext.
	data := make([]byte, 100)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	upload := func(c *client) string {
		t.Helper()
		status, body := c.raw("POST", "/api/v1/conversations/"+conv.ID+"/blobs", data, "application/octet-stream")
		if status != http.StatusCreated {
			t.Fatalf("upload status %d: %s", status, body)
		}
		var up struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(body, &up); err != nil {
			t.Fatal(err)
		}
		return up.ID
	}
	blob := upload(alice)
	if status, _ := bob.raw("DELETE", "/api/v1/blobs/"+blob, nil, ""); status != http.StatusForbidden {
		t.Fatalf("deleting someone else's attachment status %d", status)
	}
	if status, _ := carol.raw("DELETE", "/api/v1/blobs/"+blob, nil, ""); status != http.StatusNotFound {
		t.Fatalf("outsider attachment delete status %d", status)
	}
	alice.must("DELETE", "/api/v1/blobs/"+blob, nil, nil, http.StatusNoContent)
	if _, err := os.Stat(filepath.Join(env.cfg.DataDir, "blobs", blob)); !os.IsNotExist(err) {
		t.Fatalf("attachment file not removed: %v", err)
	}
	if status, _ := bob.raw("GET", "/api/v1/blobs/"+blob, nil, ""); status != http.StatusNotFound {
		t.Fatalf("deleted attachment download status %d", status)
	}
	if status, _ := alice.raw("DELETE", "/api/v1/blobs/"+blob, nil, ""); status != http.StatusNotFound {
		t.Fatalf("deleting an attachment twice status %d", status)
	}
	blob = upload(bob)
	admin.must("DELETE", "/api/v1/blobs/"+blob, nil, nil, http.StatusNoContent)
	if _, err := os.Stat(filepath.Join(env.cfg.DataDir, "blobs", blob)); !os.IsNotExist(err) {
		t.Fatalf("attachment file not removed by the administrator: %v", err)
	}
}

func TestUserDirectory(t *testing.T) {
	env := newTestEnv(t, "open")
	base := env.ts.URL
	alice := register(t, base, "alice", "alice-password-123")
	bob := register(t, base, "bob", "bob-password-123")
	register(t, base, "bobby", "bobby-password-123")

	var dir struct {
		Users []struct {
			Username string `json:"username"`
			IsBot    bool   `json:"is_bot"`
		} `json:"users"`
	}
	bob.must("GET", "/api/v1/users?q=bo", nil, &dir, http.StatusOK)
	if len(dir.Users) != 2 || dir.Users[0].Username != "bob" || dir.Users[1].Username != "bobby" {
		t.Fatalf("prefix search: %+v", dir.Users)
	}
	bob.must("GET", "/api/v1/users", nil, &dir, http.StatusOK)
	if len(dir.Users) != 3 {
		t.Fatalf("full directory: %+v", dir.Users)
	}
	var info struct {
		UserDirectory bool `json:"user_directory"`
	}
	bob.must("GET", "/api/v1/info", nil, &info, http.StatusOK)
	if !info.UserDirectory {
		t.Fatal("the directory must be enabled by default")
	}

	// The administrator switches it off: listing stops, exact lookups still work.
	alice.must("PUT", "/api/v1/admin/settings", map[string]any{"user_directory": false}, nil, http.StatusOK)
	if status := bob.do("GET", "/api/v1/users", nil, nil); status != http.StatusForbidden {
		t.Fatalf("disabled directory status %d", status)
	}
	bob.must("GET", "/api/v1/info", nil, &info, http.StatusOK)
	if info.UserDirectory {
		t.Fatal("info must report the directory as disabled")
	}
	bob.must("GET", "/api/v1/users/alice", nil, nil, http.StatusOK)
}
