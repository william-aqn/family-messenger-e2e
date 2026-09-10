package api_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/william-aqn/family-messenger-e2e/internal/api"
	"github.com/william-aqn/family-messenger-e2e/internal/config"
	"github.com/william-aqn/family-messenger-e2e/internal/store"
	"github.com/william-aqn/family-messenger-e2e/internal/ws"
	"github.com/william-aqn/family-messenger-e2e/pkg/e2e"
)

// fastKDF keeps the tests quick; the server never sees KDF parameters.
var fastKDF = e2e.KDFParams{Time: 1, MemoryKiB: 8 * 1024, Threads: 1}

func newTestServer(t *testing.T, registration string) (*httptest.Server, *store.Store) {
	t.Helper()
	st, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{
		Addr: ":0", DataDir: t.TempDir(), Registration: registration, ServerSecret: []byte("test-secret"),
		TURNSecret: "turn-secret", TURNURLs: []string{"turn:turn.example.com:3478?transport=udp"}, TURNTTL: time.Hour,
		STUNURLs: []string{"stun:stun.example.com:3478"},
	}
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
	return ts, st
}

type session struct {
	AccountID string `json:"account_id"`
	Username  string `json:"username"`
	DeviceID  string `json:"device_id"`
	Token     string `json:"token"`
	SignPub   []byte `json:"sign_pub"`
	EncPub    []byte `json:"enc_pub"`
	KeyBundle []byte `json:"key_bundle"`
	Salt      []byte `json:"salt"`
}

type memberView struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Role     string `json:"role"`
	SignPub  []byte `json:"sign_pub"`
	EncPub   []byte `json:"enc_pub"`
}

type convView struct {
	ID        string       `json:"id"`
	Kind      string       `json:"kind"`
	LastSeq   int64        `json:"last_seq"`
	ReadSeq   int64        `json:"read_seq"`
	JoinedSeq int64        `json:"joined_seq"`
	Role      string       `json:"role"`
	Members   []memberView `json:"members"`
}

type msgView struct {
	ConvID        string `json:"conv_id"`
	Seq           int64  `json:"seq"`
	SenderAccount string `json:"sender_account"`
	ClientMsgID   string `json:"client_msg_id"`
	Env           []byte `json:"env"`
	Sig           []byte `json:"sig"`
	DeletedSeq    int64  `json:"deleted_seq"`
	DeletedSender string `json:"deleted_sender"`
}

type client struct {
	t         *testing.T
	base      string
	http      *http.Client
	username  string
	token     string
	accountID string
	deviceID  string
	keys      *e2e.AccountKeys
}

func newClient(t *testing.T, base, username string) *client {
	return &client{t: t, base: base, http: &http.Client{Timeout: 10 * time.Second}, username: username}
}

// do performs a JSON request and returns the status code; 2xx bodies are
// decoded into out.
func (c *client) do(method, path string, body, out any) int {
	c.t.Helper()
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			c.t.Fatal(err)
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.base+path, rd)
	if err != nil {
		c.t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	res, err := c.http.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	if res.StatusCode >= 300 {
		c.t.Logf("%s %s -> %d %s", method, path, res.StatusCode, strings.TrimSpace(string(data)))
	} else if out != nil && len(data) > 0 {
		if err := json.Unmarshal(data, out); err != nil {
			c.t.Fatalf("%s %s: decode: %v (%s)", method, path, err, data)
		}
	}
	return res.StatusCode
}

func (c *client) must(method, path string, body, out any, want int) {
	c.t.Helper()
	if got := c.do(method, path, body, out); got != want {
		c.t.Fatalf("%s %s: status %d, want %d", method, path, got, want)
	}
}

func registerBody(t *testing.T, username, password, invite string) (map[string]any, *e2e.AccountKeys) {
	t.Helper()
	keys, err := e2e.GenerateAccountKeys()
	if err != nil {
		t.Fatal(err)
	}
	salt := make([]byte, e2e.SaltSize)
	if _, err := rand.Read(salt); err != nil {
		t.Fatal(err)
	}
	authKey, encKey := e2e.DeriveKeys(password, salt, fastKDF)
	bundle, err := e2e.NewKeyBundle(encKey, keys)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{
		"username": username, "salt": salt, "auth_key": authKey[:], "sign_pub": keys.SignPub[:], "enc_pub": keys.EncPub[:],
		"key_bundle": bundle, "invite": invite, "device_name": "test",
	}, keys
}

func register(t *testing.T, base, username, password string) *client {
	t.Helper()
	c := newClient(t, base, username)
	body, keys := registerBody(t, username, password, "")
	var sess session
	c.must("POST", "/api/v1/auth/register", body, &sess, http.StatusCreated)
	c.token, c.accountID, c.deviceID, c.keys = sess.Token, sess.AccountID, sess.DeviceID, keys
	return c
}

// login performs the full second-device flow: params → KDF → login → open bundle.
func login(t *testing.T, base, username, password string) (*client, int) {
	t.Helper()
	c := newClient(t, base, username)
	var params struct {
		Salt []byte `json:"salt"`
	}
	c.must("GET", "/api/v1/auth/params?username="+username, nil, &params, http.StatusOK)
	authKey, encKey := e2e.DeriveKeys(password, params.Salt, fastKDF)
	var sess session
	status := c.do("POST", "/api/v1/auth/login", map[string]any{"username": username, "auth_key": authKey[:], "device_name": "second"}, &sess)
	if status != http.StatusOK {
		return c, status
	}
	var signPub, encPub [32]byte
	copy(signPub[:], sess.SignPub)
	copy(encPub[:], sess.EncPub)
	keys, err := e2e.OpenKeyBundle(encKey, sess.KeyBundle, signPub, encPub)
	if err != nil {
		t.Fatalf("open key bundle: %v", err)
	}
	c.token, c.accountID, c.deviceID, c.keys = sess.Token, sess.AccountID, sess.DeviceID, keys
	return c, status
}

// envelope builds a signed envelope sealed to members.
func (c *client) envelope(convID string, flags uint8, members []memberView, plaintext string) map[string]any {
	c.t.Helper()
	env, sig := c.rawEnvelope(convID, flags, members, plaintext)
	return map[string]any{"env": env, "sig": sig}
}

func (c *client) rawEnvelope(convID string, flags uint8, members []memberView, plaintext string) ([]byte, []byte) {
	c.t.Helper()
	conv, _ := e2e.ParseID(convID)
	acct, _ := e2e.ParseID(c.accountID)
	dev, _ := e2e.ParseID(c.deviceID)
	msgID, _ := e2e.NewID()
	hdr := e2e.Header{Flags: flags, ConvID: conv, SenderAccount: acct, SenderDevice: dev, ClientMsgID: msgID, TimestampMS: uint64(time.Now().UnixMilli())}
	recipients := make([]e2e.Recipient, 0, len(members))
	for _, m := range members {
		id, _ := e2e.ParseID(m.ID)
		var pub [32]byte
		copy(pub[:], m.EncPub)
		recipients = append(recipients, e2e.Recipient{Account: id, EncPub: pub})
	}
	env, sig, err := e2e.Encrypt(c.keys, hdr, recipients, []byte(plaintext))
	if err != nil {
		c.t.Fatal(err)
	}
	return env, sig
}

func (c *client) decrypt(senderSignPub [32]byte, env, sig []byte) string {
	c.t.Helper()
	if !e2e.VerifyEnvelope(senderSignPub, env, sig) {
		c.t.Fatal("envelope signature does not verify")
	}
	parsed, err := e2e.Parse(env)
	if err != nil {
		c.t.Fatal(err)
	}
	acct, _ := e2e.ParseID(c.accountID)
	pt, err := parsed.Decrypt(acct, c.keys.EncPriv)
	if err != nil {
		c.t.Fatalf("decrypt: %v", err)
	}
	return string(pt)
}

type wsClient struct {
	t       *testing.T
	c       *websocket.Conn
	frames  chan ws.Frame
	pending []ws.Frame // frames received while waiting for another type
}

func (c *client) connectWS() *wsClient {
	c.t.Helper()
	url := "ws" + strings.TrimPrefix(c.base, "http") + "/api/v1/ws"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		c.t.Fatal(err)
	}
	w := &wsClient{t: c.t, c: conn, frames: make(chan ws.Frame, 64)}
	c.t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "") })
	w.send(ws.NewFrame("auth", map[string]string{"token": c.token}))
	go func() {
		for {
			_, data, err := conn.Read(context.Background())
			if err != nil {
				close(w.frames)
				return
			}
			var f ws.Frame
			if json.Unmarshal(data, &f) == nil {
				w.frames <- f
			}
		}
	}()
	// Every connection learns the server's build, so clients can tell when
	// the page or app they run is older than the server.
	var hello struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(w.expect("hello"), &hello); err != nil || hello.Version == "" {
		c.t.Fatalf("hello frame without a server version (%v)", err)
	}
	return w
}

func (w *wsClient) send(f ws.Frame) {
	w.t.Helper()
	b, _ := json.Marshal(f)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := w.c.Write(ctx, websocket.MessageText, b); err != nil {
		w.t.Fatal(err)
	}
}

// expect returns the payload of the oldest unconsumed frame of the given
// type. Frames of other types are kept for later expectations, because the
// server may deliver a sender's own message before the ack.
func (w *wsClient) expect(typ string) json.RawMessage {
	w.t.Helper()
	for i, f := range w.pending {
		if f.T == typ {
			w.pending = append(w.pending[:i], w.pending[i+1:]...)
			return f.D
		}
	}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case f, ok := <-w.frames:
			if !ok {
				w.t.Fatalf("connection closed while waiting for %q", typ)
			}
			if f.T == typ {
				return f.D
			}
			w.pending = append(w.pending, f)
		case <-deadline:
			w.t.Fatalf("timeout waiting for %q frame (pending: %d)", typ, len(w.pending))
		}
	}
}

func (w *wsClient) expectMessage() msgView {
	w.t.Helper()
	var m msgView
	if err := json.Unmarshal(w.expect("message"), &m); err != nil {
		w.t.Fatal(err)
	}
	return m
}

func TestMessagingFlow(t *testing.T) {
	ts, _ := newTestServer(t, "open")
	alice := register(t, ts.URL, "alice", "alice-password-123")
	bob := register(t, ts.URL, "bob", "bob-password-123")

	var bobInfo struct {
		ID     string `json:"id"`
		EncPub []byte `json:"enc_pub"`
	}
	alice.must("GET", "/api/v1/users/bob", nil, &bobInfo, http.StatusOK)
	if bobInfo.ID != bob.accountID || !bytes.Equal(bobInfo.EncPub, bob.keys.EncPub[:]) {
		t.Fatal("user lookup returned wrong identity")
	}
	alice.must("GET", "/api/v1/users/nobody", nil, nil, http.StatusNotFound)
	if newClient(t, ts.URL, "").do("GET", "/api/v1/users/bob", nil, nil) != http.StatusUnauthorized {
		t.Fatal("unauthenticated request must be rejected")
	}

	var conv convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": bob.accountID}, &conv, http.StatusCreated)
	var conv2 convView
	bob.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": alice.accountID}, &conv2, http.StatusOK)
	if conv2.ID != conv.ID || len(conv.Members) != 2 || conv.Kind != "direct" {
		t.Fatalf("direct conversation not idempotent: %+v %+v", conv, conv2)
	}

	bobWS := bob.connectWS()

	const hello = `{"t":"text","body":"hello bob"}`
	var res struct {
		Seq       int64 `json:"seq"`
		Duplicate bool  `json:"duplicate"`
	}
	alice.must("POST", "/api/v1/conversations/"+conv.ID+"/messages", alice.envelope(conv.ID, 0, conv.Members, hello), &res, http.StatusCreated)
	if res.Seq != 1 {
		t.Fatalf("first message seq = %d", res.Seq)
	}
	got := bobWS.expectMessage()
	if got.Seq != 1 || got.SenderAccount != alice.accountID {
		t.Fatalf("bob received %+v", got)
	}
	if pt := bob.decrypt(alice.keys.SignPub, got.Env, got.Sig); pt != hello {
		t.Fatalf("decrypted %q", pt)
	}

	dupEnv := alice.envelope(conv.ID, 0, conv.Members, `{"t":"text","body":"second"}`)
	alice.must("POST", "/api/v1/conversations/"+conv.ID+"/messages", dupEnv, &res, http.StatusCreated)
	if res.Seq != 2 {
		t.Fatalf("second message seq = %d", res.Seq)
	}
	alice.must("POST", "/api/v1/conversations/"+conv.ID+"/messages", dupEnv, &res, http.StatusOK)
	if res.Seq != 2 || !res.Duplicate {
		t.Fatalf("resend must be idempotent: %+v", res)
	}
	bobWS.expectMessage()

	bob2, status := login(t, ts.URL, "bob", "bob-password-123")
	if status != http.StatusOK {
		t.Fatalf("login status %d", status)
	}
	if bob2.keys.EncPriv != bob.keys.EncPriv || bob2.keys.SignSeed != bob.keys.SignSeed {
		t.Fatal("key bundle round trip lost the account keys")
	}
	var hist struct {
		Messages []msgView `json:"messages"`
		HasMore  bool      `json:"has_more"`
		LastSeq  int64     `json:"last_seq"`
	}
	bob2.must("GET", "/api/v1/conversations/"+conv.ID+"/messages?after=0&limit=10", nil, &hist, http.StatusOK)
	if len(hist.Messages) != 2 || hist.HasMore || hist.LastSeq != 2 {
		t.Fatalf("history: %+v", hist)
	}
	if pt := bob2.decrypt(alice.keys.SignPub, hist.Messages[0].Env, hist.Messages[0].Sig); pt != hello {
		t.Fatalf("second device decrypted %q", pt)
	}
	bob2.must("GET", "/api/v1/conversations/"+conv.ID+"/messages?after=0&limit=1", nil, &hist, http.StatusOK)
	if len(hist.Messages) != 1 || !hist.HasMore {
		t.Fatalf("paging: %+v", hist)
	}

	if _, status := login(t, ts.URL, "bob", "wrong-password"); status != http.StatusUnauthorized {
		t.Fatalf("wrong password status %d", status)
	}
	if _, status := login(t, ts.URL, "ghost", "whatever"); status != http.StatusUnauthorized {
		t.Fatalf("unknown user status %d", status)
	}

	aliceWS := alice.connectWS()
	env, sig := bob.rawEnvelope(conv.ID, 0, conv.Members, `{"t":"text","body":"hi alice"}`)
	bobWS.send(ws.NewFrame("send", map[string]any{"ref": "r1", "conv_id": conv.ID, "env": env, "sig": sig}))
	var ack struct {
		Ref string `json:"ref"`
		Seq int64  `json:"seq"`
	}
	if err := json.Unmarshal(bobWS.expect("ack"), &ack); err != nil || ack.Ref != "r1" || ack.Seq != 3 {
		t.Fatalf("ack: %+v %v", ack, err)
	}
	if m := aliceWS.expectMessage(); m.Seq != 3 || alice.decrypt(bob.keys.SignPub, m.Env, m.Sig) != `{"t":"text","body":"hi alice"}` {
		t.Fatalf("alice received %+v", m)
	}
	if m := bobWS.expectMessage(); m.Seq != 3 {
		t.Fatalf("sender's own device must receive its message for multi-device sync, got %+v", m)
	}

	env, sig = bob.rawEnvelope(conv.ID, e2e.FlagEphemeral|e2e.FlagUrgent, conv.Members, `{"t":"call.offer","call":"x","sdp":"v=0"}`)
	bobWS.send(ws.NewFrame("send", map[string]any{"ref": "r2", "conv_id": conv.ID, "env": env, "sig": sig}))
	var eack struct {
		Ref       string `json:"ref"`
		Seq       int64  `json:"seq"`
		Ephemeral bool   `json:"ephemeral"`
	}
	if err := json.Unmarshal(bobWS.expect("ack"), &eack); err != nil || !eack.Ephemeral || eack.Seq != 0 {
		t.Fatalf("ephemeral ack: %+v %v", eack, err)
	}
	var sigMsg msgView
	if err := json.Unmarshal(aliceWS.expect("signal"), &sigMsg); err != nil || alice.decrypt(bob.keys.SignPub, sigMsg.Env, sigMsg.Sig) != `{"t":"call.offer","call":"x","sdp":"v=0"}` {
		t.Fatalf("signal: %+v %v", sigMsg, err)
	}
	alice.must("GET", "/api/v1/conversations/"+conv.ID+"/messages?after=0", nil, &hist, http.StatusOK)
	if len(hist.Messages) != 3 {
		t.Fatalf("ephemeral envelope must not be stored, history has %d", len(hist.Messages))
	}

	carol := register(t, ts.URL, "carol", "carol-password-123")
	if status := carol.do("POST", "/api/v1/conversations/"+conv.ID+"/messages", carol.envelope(conv.ID, 0, conv.Members, "x"), nil); status != http.StatusNotFound && status != http.StatusForbidden {
		t.Fatalf("non-member send status %d", status)
	}
	forged, forgedSig := bob.rawEnvelope(conv.ID, 0, conv.Members, "x")
	bobAsAlice := *bob
	bobAsAlice.accountID = alice.accountID
	forged, forgedSig = bobAsAlice.rawEnvelope(conv.ID, 0, conv.Members, "x")
	if status := bob.do("POST", "/api/v1/conversations/"+conv.ID+"/messages", map[string]any{"env": forged, "sig": forgedSig}, nil); status != http.StatusForbidden {
		t.Fatalf("forged sender status %d", status)
	}
	env, sig = alice.rawEnvelope(conv.ID, 0, conv.Members, "x")
	sig[0] ^= 1
	if status := alice.do("POST", "/api/v1/conversations/"+conv.ID+"/messages", map[string]any{"env": env, "sig": sig}, nil); status != http.StatusBadRequest {
		t.Fatalf("bad signature status %d", status)
	}
	var otherConv convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": carol.accountID}, &otherConv, http.StatusCreated)
	env, sig = alice.rawEnvelope(otherConv.ID, 0, otherConv.Members, "x")
	if status := alice.do("POST", "/api/v1/conversations/"+conv.ID+"/messages", map[string]any{"env": env, "sig": sig}, nil); status != http.StatusBadRequest {
		t.Fatalf("envelope for another conversation status %d", status)
	}

	alice.must("PUT", "/api/v1/conversations/"+conv.ID+"/read", map[string]any{"seq": 3}, nil, http.StatusNoContent)
	var list struct {
		Conversations []convView `json:"conversations"`
	}
	alice.must("GET", "/api/v1/conversations", nil, &list, http.StatusOK)
	if len(list.Conversations) != 2 || list.Conversations[0].ReadSeq != 3 || list.Conversations[0].LastSeq != 3 {
		t.Fatalf("conversation list: %+v", list)
	}

	var turnRes struct {
		ICEServers []struct {
			URLs       []string `json:"urls"`
			Username   string   `json:"username"`
			Credential string   `json:"credential"`
		} `json:"ice_servers"`
		TTL int `json:"ttl"`
	}
	alice.must("GET", "/api/v1/turn", nil, &turnRes, http.StatusOK)
	if len(turnRes.ICEServers) != 2 || turnRes.TTL != 3600 || !strings.HasSuffix(turnRes.ICEServers[1].Username, ":"+alice.accountID) || turnRes.ICEServers[1].Credential == "" {
		t.Fatalf("turn: %+v", turnRes)
	}

	var me struct {
		Devices []struct {
			ID      string `json:"id"`
			Current bool   `json:"current"`
		} `json:"devices"`
	}
	bob2.must("GET", "/api/v1/me", nil, &me, http.StatusOK)
	if len(me.Devices) != 2 {
		t.Fatalf("bob should have two devices: %+v", me)
	}
	bob2.must("POST", "/api/v1/auth/logout", nil, nil, http.StatusNoContent)
	if bob2.do("GET", "/api/v1/me", nil, nil) != http.StatusUnauthorized {
		t.Fatal("token must be invalid after logout")
	}

	if newClient(t, ts.URL, "").do("GET", "/healthz", nil, nil) != http.StatusOK {
		t.Fatal("healthz")
	}
}

func TestGroupMembership(t *testing.T) {
	ts, _ := newTestServer(t, "open")
	alice := register(t, ts.URL, "alice", "alice-password-123")
	bob := register(t, ts.URL, "bob", "bob-password-123")
	carol := register(t, ts.URL, "carol", "carol-password-123")

	var g convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "group", "member_ids": []string{bob.accountID}}, &g, http.StatusCreated)
	if g.Role != "owner" || len(g.Members) != 2 || g.Kind != "group" {
		t.Fatalf("group: %+v", g)
	}
	alice.must("POST", "/api/v1/conversations/"+g.ID+"/messages", alice.envelope(g.ID, 0, g.Members, `{"t":"conv.create"}`), nil, http.StatusCreated)

	if status := bob.do("POST", "/api/v1/conversations/"+g.ID+"/members", map[string]any{"account_id": carol.accountID}, nil); status != http.StatusForbidden {
		t.Fatalf("non-owner add status %d", status)
	}
	if status := carol.do("GET", "/api/v1/conversations/"+g.ID, nil, nil); status != http.StatusNotFound {
		t.Fatalf("outsider view status %d", status)
	}

	carolWS := carol.connectWS()
	var updated convView
	alice.must("POST", "/api/v1/conversations/"+g.ID+"/members", map[string]any{"account_id": carol.accountID}, &updated, http.StatusOK)
	if len(updated.Members) != 3 {
		t.Fatalf("members after add: %+v", updated.Members)
	}
	var ev struct {
		Kind    string `json:"kind"`
		Account string `json:"account"`
	}
	if err := json.Unmarshal(carolWS.expect("event"), &ev); err != nil || ev.Kind != "member.added" || ev.Account != carol.accountID {
		t.Fatalf("event: %+v %v", ev, err)
	}
	if status := alice.do("POST", "/api/v1/conversations/"+g.ID+"/members", map[string]any{"account_id": carol.accountID}, nil); status != http.StatusConflict {
		t.Fatalf("double add status %d", status)
	}

	var cg convView
	carol.must("GET", "/api/v1/conversations/"+g.ID, nil, &cg, http.StatusOK)
	if cg.JoinedSeq != 1 || cg.Role != "member" {
		t.Fatalf("carol view: %+v", cg)
	}
	var hist struct {
		Messages []msgView `json:"messages"`
	}
	carol.must("GET", "/api/v1/conversations/"+g.ID+"/messages", nil, &hist, http.StatusOK)
	if len(hist.Messages) != 0 {
		t.Fatalf("carol must not see messages from before she joined: %d", len(hist.Messages))
	}

	alice.must("POST", "/api/v1/conversations/"+g.ID+"/messages", alice.envelope(g.ID, 0, updated.Members, `{"t":"member.add"}`), nil, http.StatusCreated)
	if m := carolWS.expectMessage(); m.Seq != 2 || carol.decrypt(alice.keys.SignPub, m.Env, m.Sig) != `{"t":"member.add"}` {
		t.Fatalf("carol received %+v", m)
	}
	carol.must("GET", "/api/v1/conversations/"+g.ID+"/messages", nil, &hist, http.StatusOK)
	if len(hist.Messages) != 1 {
		t.Fatalf("carol history: %d", len(hist.Messages))
	}

	stranger := memberView{ID: "0190f6e0-0000-7000-8000-000000000000", EncPub: carol.keys.EncPub[:]}
	if status := alice.do("POST", "/api/v1/conversations/"+g.ID+"/messages", alice.envelope(g.ID, 0, append(updated.Members, stranger), "x"), nil); status != http.StatusBadRequest {
		t.Fatalf("recipient outside the group status %d", status)
	}

	bobWS := bob.connectWS()
	carol.must("DELETE", "/api/v1/conversations/"+g.ID+"/members/"+carol.accountID, nil, nil, http.StatusNoContent)
	if status := carol.do("GET", "/api/v1/conversations/"+g.ID, nil, nil); status != http.StatusNotFound {
		t.Fatalf("after leaving status %d", status)
	}
	if err := json.Unmarshal(bobWS.expect("event"), &ev); err != nil || ev.Kind != "member.removed" || ev.Account != carol.accountID {
		t.Fatalf("removal event: %+v %v", ev, err)
	}
	if status := bob.do("DELETE", "/api/v1/conversations/"+g.ID+"/members/"+alice.accountID, nil, nil); status != http.StatusForbidden {
		t.Fatalf("non-owner remove status %d", status)
	}
	alice.must("DELETE", "/api/v1/conversations/"+g.ID+"/members/"+bob.accountID, nil, nil, http.StatusNoContent)
	if err := json.Unmarshal(bobWS.expect("event"), &ev); err != nil || ev.Kind != "conv.removed" {
		t.Fatalf("conv.removed event: %+v %v", ev, err)
	}
	var list struct {
		Conversations []convView `json:"conversations"`
	}
	bob.must("GET", "/api/v1/conversations", nil, &list, http.StatusOK)
	if len(list.Conversations) != 0 {
		t.Fatalf("bob still lists the group: %+v", list)
	}

	var direct convView
	alice.must("POST", "/api/v1/conversations", map[string]any{"kind": "direct", "account_id": bob.accountID}, &direct, http.StatusCreated)
	if status := alice.do("DELETE", "/api/v1/conversations/"+direct.ID+"/members/"+alice.accountID, nil, nil); status != http.StatusBadRequest {
		t.Fatalf("leaving a direct conversation status %d", status)
	}
}

func TestRegistrationModes(t *testing.T) {
	ts, st := newTestServer(t, "invite")
	c := newClient(t, ts.URL, "dave")
	body, _ := registerBody(t, "dave", "dave-password-123", "")
	if status := c.do("POST", "/api/v1/auth/register", body, nil); status != http.StatusForbidden {
		t.Fatalf("no invite status %d", status)
	}
	body["invite"] = "wrong"
	if status := c.do("POST", "/api/v1/auth/register", body, nil); status != http.StatusForbidden {
		t.Fatalf("wrong invite status %d", status)
	}
	if err := st.CreateInvite(context.Background(), "welcome1", "", "", 0); err != nil {
		t.Fatal(err)
	}
	body["invite"] = "welcome1"
	c.must("POST", "/api/v1/auth/register", body, nil, http.StatusCreated)
	body2, _ := registerBody(t, "erin", "erin-password-123", "welcome1")
	if status := c.do("POST", "/api/v1/auth/register", body2, nil); status != http.StatusForbidden {
		t.Fatalf("reused invite status %d", status)
	}
	body3, _ := registerBody(t, "Dave", "x-password-123", "")
	if err := st.CreateInvite(context.Background(), "welcome2", "", "", 0); err != nil {
		t.Fatal(err)
	}
	body3["invite"] = "welcome2"
	if status := c.do("POST", "/api/v1/auth/register", body3, nil); status != http.StatusConflict {
		t.Fatalf("usernames must be case-insensitive, status %d", status)
	}
	body4, _ := registerBody(t, "no", "x-password-123", "welcome2")
	if status := c.do("POST", "/api/v1/auth/register", body4, nil); status != http.StatusBadRequest {
		t.Fatalf("short username status %d", status)
	}

	closed, _ := newTestServer(t, "closed")
	body5, _ := registerBody(t, "frank", "frank-password-123", "")
	if status := newClient(t, closed.URL, "frank").do("POST", "/api/v1/auth/register", body5, nil); status != http.StatusForbidden {
		t.Fatalf("closed registration status %d", status)
	}
}
