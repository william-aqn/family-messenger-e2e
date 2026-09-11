package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStoreFlow(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	now := time.Now().Unix()

	newAccount := func(name string) (*Account, *Device) {
		a := &Account{ID: name + "-id", Username: name, Salt: []byte("salt"), AuthHash: []byte("hash"), SignPub: []byte("sp"), EncPub: []byte("ep"), KeyBundle: []byte("kb"), CreatedAt: now}
		d := &Device{ID: name + "-dev", AccountID: a.ID, Name: "dev", TokenHash: []byte(name + "-token"), CreatedAt: now, LastSeen: now}
		return a, d
	}
	create := func(name string) *Account {
		t.Helper()
		a, d := newAccount(name)
		if err := s.CreateAccount(ctx, a, d, "", false); err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		return a
	}
	alice, bob := create("alice"), create("bob")

	dupA, dupD := newAccount("alice")
	dupA.ID, dupD.ID, dupD.TokenHash = "other", "other-dev", []byte("other")
	if err := s.CreateAccount(ctx, dupA, dupD, "", false); !errors.Is(err, ErrConflict) {
		t.Fatalf("duplicate username: %v", err)
	}

	carol, carolDev := newAccount("carol")
	if err := s.CreateAccount(ctx, carol, carolDev, "nope", true); !errors.Is(err, ErrInvite) {
		t.Fatalf("bad invite: %v", err)
	}
	if err := s.CreateInvite(ctx, "code1", "", "", 0); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateAccount(ctx, carol, carolDev, "code1", true); err != nil {
		t.Fatalf("invite registration: %v", err)
	}
	dave, daveDev := newAccount("dave")
	if err := s.CreateAccount(ctx, dave, daveDev, "code1", true); !errors.Is(err, ErrInvite) {
		t.Fatalf("reused invite: %v", err)
	}

	if _, acct, err := s.DeviceByTokenHash(ctx, []byte("alice-token")); err != nil || acct.Username != "alice" {
		t.Fatalf("device lookup: %v", err)
	}
	if _, _, err := s.DeviceByTokenHash(ctx, []byte("missing")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing token: %v", err)
	}

	convID, created, err := s.CreateDirect(ctx, "c1", alice.ID, bob.ID, now)
	if err != nil || !created || convID != "c1" {
		t.Fatalf("create direct: %s %v %v", convID, created, err)
	}
	again, created, err := s.CreateDirect(ctx, "c2", bob.ID, alice.ID, now)
	if err != nil || created || again != "c1" {
		t.Fatalf("direct must be unique per pair: %s %v %v", again, created, err)
	}

	msg := func(sender, clientID string) *Message {
		return &Message{ConvID: convID, SenderAccount: sender, SenderDevice: sender + "-dev", ClientID: clientID, Env: []byte("env"), Sig: []byte("sig"), ServerTS: now}
	}
	seq, dup, members, err := s.AppendMessage(ctx, msg(alice.ID, "m1"), []string{alice.ID, bob.ID})
	if err != nil || seq != 1 || dup || len(members) != 2 {
		t.Fatalf("append: seq=%d dup=%v members=%v err=%v", seq, dup, members, err)
	}
	seq, dup, _, err = s.AppendMessage(ctx, msg(alice.ID, "m1"), []string{alice.ID, bob.ID})
	if err != nil || seq != 1 || !dup {
		t.Fatalf("duplicate append: seq=%d dup=%v err=%v", seq, dup, err)
	}
	if seq, _, _, err = s.AppendMessage(ctx, msg(bob.ID, "m2"), []string{alice.ID}); err != nil || seq != 2 {
		t.Fatalf("second append: seq=%d err=%v", seq, err)
	}
	if _, _, _, err = s.AppendMessage(ctx, msg(carol.ID, "m3"), nil); !errors.Is(err, ErrNotMember) {
		t.Fatalf("non-member send: %v", err)
	}
	if _, _, _, err = s.AppendMessage(ctx, msg(alice.ID, "m4"), []string{carol.ID}); !errors.Is(err, ErrRecipient) {
		t.Fatalf("recipient not member: %v", err)
	}
	if _, _, _, err = s.AppendMessage(ctx, &Message{ConvID: "other", SenderAccount: alice.ID, SenderDevice: "d", ClientID: "m1", Env: []byte("e"), Sig: []byte("s")}, nil); err == nil {
		t.Fatal("client id reuse in another conversation must fail")
	}

	msgs, err := s.Messages(ctx, convID, 0, 0, 10)
	if err != nil || len(msgs) != 2 || msgs[0].Seq != 1 || msgs[1].Seq != 2 {
		t.Fatalf("history: %v %v", msgs, err)
	}
	if msgs, _ = s.Messages(ctx, convID, 1, 0, 10); len(msgs) != 1 || msgs[0].Seq != 2 {
		t.Fatalf("history after=1: %v", msgs)
	}

	convs, err := s.ConversationsForAccount(ctx, alice.ID)
	if err != nil || len(convs) != 1 || len(convs[0].Members) != 2 || convs[0].LastSeq != 2 || convs[0].Me.AccountID != alice.ID {
		t.Fatalf("conversations: %+v %v", convs, err)
	}
	if _, err := s.ConversationForAccount(ctx, convID, carol.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("non-member view: %v", err)
	}

	if err := s.CreateGroup(ctx, "g1", alice.ID, []string{bob.ID, alice.ID}, now); err != nil {
		t.Fatal(err)
	}
	if seq, _, _, err = s.AppendMessage(ctx, &Message{ConvID: "g1", SenderAccount: alice.ID, SenderDevice: "d", ClientID: "g-1", Env: []byte("e"), Sig: []byte("s")}, nil); err != nil || seq != 1 {
		t.Fatalf("group append: %d %v", seq, err)
	}
	if err := s.AddMember(ctx, "g1", carol.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.AddMember(ctx, "g1", carol.ID); !errors.Is(err, ErrConflict) {
		t.Fatalf("double add: %v", err)
	}
	cg, err := s.ConversationForAccount(ctx, "g1", carol.ID)
	if err != nil || cg.Me.JoinedSeq != 1 || len(cg.Members) != 3 {
		t.Fatalf("carol group view: %+v %v", cg, err)
	}
	if msgs, _ = s.Messages(ctx, "g1", 0, cg.Me.JoinedSeq, 10); len(msgs) != 0 {
		t.Fatalf("carol must not see history before joining: %v", msgs)
	}
	if err := s.RemoveMember(ctx, "g1", carol.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.RemoveMember(ctx, "g1", carol.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("double remove: %v", err)
	}

	if err := s.MarkRead(ctx, convID, alice.ID, 99); err != nil {
		t.Fatal(err)
	}
	c, err := s.ConversationForAccount(ctx, convID, alice.ID)
	if err != nil || c.Me.ReadSeq != 2 {
		t.Fatalf("read marker must clamp to last_seq: %+v %v", c.Me, err)
	}

	if err := s.DeleteDevice(ctx, alice.ID, "alice-dev"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.DeviceByTokenHash(ctx, []byte("alice-token")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted device still resolves: %v", err)
	}
}

func TestDeleteMessage(t *testing.T) {
	s, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	now := time.Now().Unix()
	for _, name := range []string{"alice", "bob"} {
		a := &Account{ID: name + "-id", Username: name, Salt: []byte("salt"), AuthHash: []byte("hash"), SignPub: []byte("sp"), EncPub: []byte("ep"), KeyBundle: []byte("kb"), CreatedAt: now}
		d := &Device{ID: name + "-dev", AccountID: a.ID, Name: "dev", TokenHash: []byte(name + "-token"), CreatedAt: now, LastSeen: now}
		if err := s.CreateAccount(ctx, a, d, "", false); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := s.CreateDirect(ctx, "c1", "alice-id", "bob-id", now); err != nil {
		t.Fatal(err)
	}
	for i, sender := range []string{"alice-id", "bob-id"} {
		m := &Message{ConvID: "c1", SenderAccount: sender, SenderDevice: sender + "-dev", ClientID: "m" + string(rune('1'+i)), Env: []byte("env"), Sig: []byte("sig"), ServerTS: now}
		if _, _, _, err := s.AppendMessage(ctx, m, []string{"alice-id", "bob-id"}); err != nil {
			t.Fatal(err)
		}
	}

	rec, err := s.DeleteMessage(ctx, "c1", 1, "bob-id", "bob-dev", "rec-1", now+5)
	if err != nil || rec.Seq != 3 || rec.DeletedSeq != 1 || rec.DeletedSender != "alice-id" || rec.SenderAccount != "bob-id" || !rec.IsDeletion() {
		t.Fatalf("deletion record: %+v %v", rec, err)
	}
	if _, err := s.Message(ctx, "c1", 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleted message still readable: %v", err)
	}
	if _, err := s.Message(ctx, "c1", 3); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a deletion record must not count as a message: %v", err)
	}
	if _, err := s.DeleteMessage(ctx, "c1", 3, "bob-id", "bob-dev", "rec-2", now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleting a record: %v", err)
	}
	if _, err := s.DeleteMessage(ctx, "c1", 1, "bob-id", "bob-dev", "rec-3", now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("deleting twice: %v", err)
	}
	msgs, err := s.Messages(ctx, "c1", 0, 0, 10)
	if err != nil || len(msgs) != 2 || msgs[0].Seq != 2 || msgs[1].Seq != 3 || msgs[1].DeletedSeq != 1 || len(msgs[1].Env) != 0 || msgs[1].Env == nil {
		t.Fatalf("history after deletion: %+v %v", msgs, err)
	}
	convs, err := s.ConversationsForAccount(ctx, "alice-id")
	if err != nil || len(convs) != 1 || convs[0].LastSeq != 3 {
		t.Fatalf("last_seq after deletion: %+v %v", convs, err)
	}
	st, err := s.Stats(ctx)
	if err != nil || st.Messages != 1 {
		t.Fatalf("stats must not count deletion records: %+v %v", st, err)
	}
}

func TestOpenTwiceKeepsData(t *testing.T) {
	// A plain temp dir instead of t.TempDir(): on Windows the SQLite files may
	// still be releasing when the test's cleanup runs, which would fail it.
	dir, err := os.MkdirTemp("", "store-persist")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "persist.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.CreateInvite(context.Background(), "abc", "", "", 0); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.CreateInvite(context.Background(), "abc", "", "", 0); !errors.Is(err, ErrConflict) {
		t.Fatalf("invite did not persist across reopen: %v", err)
	}
}

// A password change keeps the generation it replaces, and signs the other
// devices out in the same transaction (PROTOCOL.md §3.2, migration 004).
func TestUpdatePasswordKeepsPreviousGeneration(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "pw.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	now := time.Now().Unix()

	acct := &Account{
		ID: "acct-1", Username: "alice", Salt: []byte("salt-one"), AuthHash: []byte("hash-one"),
		SignPub: make([]byte, 32), EncPub: make([]byte, 32), KeyBundle: []byte("bundle-one"), CreatedAt: now,
	}
	first := &Device{ID: "dev-1", AccountID: acct.ID, Name: "laptop", TokenHash: []byte("t1"), CreatedAt: now, LastSeen: now}
	if err := s.CreateAccount(ctx, acct, first, "", false); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"dev-2", "dev-3"} {
		if err := s.CreateDevice(ctx, &Device{ID: id, AccountID: acct.ID, Name: id, TokenHash: []byte(id), CreatedAt: now, LastSeen: now}); err != nil {
			t.Fatal(err)
		}
	}

	// Without a device to keep, the sessions are left alone.
	gone, err := s.UpdatePassword(ctx, acct.ID, []byte("salt-two"), []byte("hash-two"), []byte("bundle-two"), "")
	if err != nil {
		t.Fatal(err)
	}
	if len(gone) != 0 {
		t.Fatalf("no eviction was asked for, got %v", gone)
	}
	devs, err := s.DevicesByAccount(ctx, acct.ID)
	if err != nil || len(devs) != 3 {
		t.Fatalf("devices: %d (%v)", len(devs), err)
	}

	// The generation that was replaced is still there to put back by hand.
	var prevSalt, prevHash, prevBundle []byte
	var changedAt int64
	row := s.db.QueryRowContext(ctx, `SELECT prev_salt, prev_auth_hash, prev_key_bundle, COALESCE(password_changed_at, 0) FROM accounts WHERE id = ?`, acct.ID)
	if err := row.Scan(&prevSalt, &prevHash, &prevBundle, &changedAt); err != nil {
		t.Fatal(err)
	}
	if string(prevSalt) != "salt-one" || string(prevHash) != "hash-one" || string(prevBundle) != "bundle-one" {
		t.Fatalf("previous generation not kept: %q %q %q", prevSalt, prevHash, prevBundle)
	}
	if changedAt == 0 {
		t.Fatal("password_changed_at was not stamped")
	}

	// With a device to keep, the others go in the same transaction.
	gone, err = s.UpdatePassword(ctx, acct.ID, []byte("salt-three"), []byte("hash-three"), []byte("bundle-three"), "dev-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(gone) != 2 {
		t.Fatalf("evicted %v, want dev-2 and dev-3", gone)
	}
	devs, err = s.DevicesByAccount(ctx, acct.ID)
	if err != nil || len(devs) != 1 || devs[0].ID != "dev-1" {
		t.Fatalf("devices after eviction: %+v (%v)", devs, err)
	}
	got, err := s.AccountByID(ctx, acct.ID)
	if err != nil {
		t.Fatal(err)
	}
	if string(got.Salt) != "salt-three" || string(got.KeyBundle) != "bundle-three" {
		t.Fatalf("current generation: %q %q", got.Salt, got.KeyBundle)
	}

	if _, err := s.UpdatePassword(ctx, "nobody", []byte("s"), []byte("h"), []byte("b"), ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown account: %v", err)
	}
}
