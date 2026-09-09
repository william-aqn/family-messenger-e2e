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
