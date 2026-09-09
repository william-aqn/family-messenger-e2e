package e2e

import (
	"bytes"
	"errors"
	"testing"
)

func mustKeys(t *testing.T) *AccountKeys {
	t.Helper()
	k, err := GenerateAccountKeys()
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func mustID(t *testing.T) ID {
	t.Helper()
	id, err := NewID()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestIDRoundTrip(t *testing.T) {
	id := mustID(t)
	s := id.String()
	if len(s) != 36 {
		t.Fatalf("bad uuid string %q", s)
	}
	back, err := ParseID(s)
	if err != nil || back != id {
		t.Fatalf("ParseID(%q) = %v, %v", s, back, err)
	}
	if _, err := ParseID("not-a-uuid"); err == nil {
		t.Fatal("expected error for malformed id")
	}
}

func TestAccountKeysDeterministic(t *testing.T) {
	k := mustKeys(t)
	again, err := AccountKeysFromSecrets(k.SignSeed, k.EncPriv)
	if err != nil {
		t.Fatal(err)
	}
	if *again != *k {
		t.Fatal("public keys are not a deterministic function of the secrets")
	}
	msg := []byte("hello")
	sig := k.Sign(msg)
	if !Verify(k.SignPub, msg, sig) {
		t.Fatal("signature does not verify")
	}
	if Verify(k.SignPub, []byte("hellp"), sig) {
		t.Fatal("signature verified for a different message")
	}
	if Verify(k.SignPub, msg, sig[:63]) {
		t.Fatal("short signature accepted")
	}
}

func TestKeyBundle(t *testing.T) {
	k := mustKeys(t)
	salt := bytes.Repeat([]byte{7}, SaltSize)
	fast := KDFParams{Time: 1, MemoryKiB: 8 * 1024, Threads: 1}
	authKey, encKey := DeriveKeys("secret password", salt, fast)
	if authKey == encKey {
		t.Fatal("auth and enc keys must differ")
	}
	bundle, err := NewKeyBundle(encKey, k)
	if err != nil {
		t.Fatal(err)
	}
	if len(bundle) != KeyBundleSize {
		t.Fatalf("bundle size %d, want %d", len(bundle), KeyBundleSize)
	}
	got, err := OpenKeyBundle(encKey, bundle, k.SignPub, k.EncPub)
	if err != nil {
		t.Fatal(err)
	}
	if *got != *k {
		t.Fatal("opened bundle does not match original keys")
	}
	if _, err := OpenKeyBundle(authKey, bundle, k.SignPub, k.EncPub); !errors.Is(err, ErrKeyBundle) {
		t.Fatalf("wrong key: err = %v", err)
	}
	other := mustKeys(t)
	if _, err := OpenKeyBundle(encKey, bundle, other.SignPub, k.EncPub); !errors.Is(err, ErrKeyBundle) {
		t.Fatalf("mismatched public key: err = %v", err)
	}
	bundle[NonceSize+3] ^= 1
	if _, err := OpenKeyBundle(encKey, bundle, k.SignPub, k.EncPub); !errors.Is(err, ErrKeyBundle) {
		t.Fatalf("tampered bundle: err = %v", err)
	}
}

func TestSealOpen(t *testing.T) {
	r := mustKeys(t)
	conv, acct := mustID(t), mustID(t)
	var key [32]byte
	for i := range key {
		key[i] = byte(i)
	}
	box, err := Seal(r.EncPub, conv, acct, key)
	if err != nil {
		t.Fatal(err)
	}
	if len(box) != SealedKeySize {
		t.Fatalf("box size %d, want %d", len(box), SealedKeySize)
	}
	got, err := Open(r.EncPriv, conv, acct, box)
	if err != nil {
		t.Fatal(err)
	}
	if got != key {
		t.Fatal("opened key differs")
	}
	if _, err := Open(r.EncPriv, mustID(t), acct, box); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("wrong conversation in aad: err = %v", err)
	}
	if _, err := Open(r.EncPriv, conv, mustID(t), box); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("wrong account in aad: err = %v", err)
	}
	other := mustKeys(t)
	if _, err := Open(other.EncPriv, conv, acct, box); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("wrong recipient key: err = %v", err)
	}
	box[40] ^= 1
	if _, err := Open(r.EncPriv, conv, acct, box); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("tampered box: err = %v", err)
	}
	if _, err := Open(r.EncPriv, conv, acct, box[:SealedKeySize-1]); !errors.Is(err, ErrMalformed) {
		t.Fatalf("short box: err = %v", err)
	}
}

func TestSealRejectsLowOrderPoint(t *testing.T) {
	var zero [32]byte
	if _, err := Seal(zero, mustID(t), mustID(t), zero); err == nil {
		t.Fatal("expected error for all-zero recipient key")
	}
}

func TestEnvelopeRoundTrip(t *testing.T) {
	alice, bob, carol := mustKeys(t), mustKeys(t), mustKeys(t)
	aliceID, bobID, carolID := mustID(t), mustID(t), mustID(t)
	hdr := Header{
		Flags:         FlagUrgent,
		ConvID:        mustID(t),
		SenderAccount: aliceID,
		SenderDevice:  mustID(t),
		ClientMsgID:   mustID(t),
		TimestampMS:   1_757_400_000_123,
	}
	recipients := []Recipient{
		{Account: aliceID, EncPub: alice.EncPub},
		{Account: bobID, EncPub: bob.EncPub},
		{Account: carolID, EncPub: carol.EncPub},
	}
	plaintext := []byte(`{"t":"text","body":"hi all"}`)
	env, sig, err := Encrypt(alice, hdr, recipients, plaintext)
	if err != nil {
		t.Fatal(err)
	}
	wantSize := fixedHeaderSize + 3*recipientEntrySize + NonceSize + 4 + len(plaintext) + TagSize
	if len(env) != wantSize {
		t.Fatalf("envelope size %d, want %d", len(env), wantSize)
	}
	if !VerifyEnvelope(alice.SignPub, env, sig) {
		t.Fatal("signature does not verify")
	}
	if VerifyEnvelope(bob.SignPub, env, sig) {
		t.Fatal("signature verified under the wrong key")
	}
	parsed, err := Parse(env)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Header != hdr {
		t.Fatalf("header mismatch: %+v vs %+v", parsed.Header, hdr)
	}
	if len(parsed.Recipients) != 3 || parsed.Recipients[1].Account != bobID {
		t.Fatal("recipients not parsed correctly")
	}
	if !parsed.IsRecipient(carolID) || parsed.IsRecipient(mustID(t)) {
		t.Fatal("IsRecipient wrong")
	}
	for _, rc := range []struct {
		id   ID
		keys *AccountKeys
	}{{aliceID, alice}, {bobID, bob}, {carolID, carol}} {
		pt, err := parsed.Decrypt(rc.id, rc.keys.EncPriv)
		if err != nil {
			t.Fatalf("decrypt for %s: %v", rc.id, err)
		}
		if !bytes.Equal(pt, plaintext) {
			t.Fatalf("plaintext mismatch for %s", rc.id)
		}
	}
	if _, err := parsed.Decrypt(mustID(t), bob.EncPriv); !errors.Is(err, ErrNotRecipient) {
		t.Fatalf("non-recipient: err = %v", err)
	}
	if _, err := parsed.Decrypt(bobID, carol.EncPriv); !errors.Is(err, ErrDecrypt) {
		t.Fatalf("wrong private key: err = %v", err)
	}
}

func TestEnvelopeTamperDetected(t *testing.T) {
	alice := mustKeys(t)
	aliceID := mustID(t)
	hdr := Header{ConvID: mustID(t), SenderAccount: aliceID, SenderDevice: mustID(t), ClientMsgID: mustID(t)}
	env, sig, err := Encrypt(alice, hdr, []Recipient{{Account: aliceID, EncPub: alice.EncPub}}, []byte("x"))
	if err != nil {
		t.Fatal(err)
	}
	for _, off := range []int{1, 2, 20, 70, 80, len(env) - 1} {
		mod := append([]byte(nil), env...)
		mod[off] ^= 0x80
		if VerifyEnvelope(alice.SignPub, mod, sig) {
			t.Fatalf("signature still verifies after flipping byte %d", off)
		}
		parsed, err := Parse(mod)
		if err != nil {
			continue // structurally invalid is fine too
		}
		if _, err := parsed.Decrypt(aliceID, alice.EncPriv); err == nil {
			t.Fatalf("decrypt succeeded after flipping byte %d", off)
		}
	}
}

func TestEnvelopeEmptyPlaintextAndLimits(t *testing.T) {
	alice := mustKeys(t)
	aliceID := mustID(t)
	hdr := Header{ConvID: mustID(t), SenderAccount: aliceID, SenderDevice: mustID(t), ClientMsgID: mustID(t)}
	self := []Recipient{{Account: aliceID, EncPub: alice.EncPub}}

	env, sig, err := Encrypt(alice, hdr, self, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyEnvelope(alice.SignPub, env, sig) {
		t.Fatal("empty plaintext signature")
	}
	parsed, err := Parse(env)
	if err != nil {
		t.Fatal(err)
	}
	if pt, err := parsed.Decrypt(aliceID, alice.EncPriv); err != nil || len(pt) != 0 {
		t.Fatalf("empty plaintext: %v %v", pt, err)
	}

	if _, _, err := Encrypt(alice, hdr, nil, []byte("x")); !errors.Is(err, ErrRecipients) {
		t.Fatalf("no recipients: err = %v", err)
	}
	many := make([]Recipient, MaxRecipients+1)
	for i := range many {
		many[i] = self[0]
	}
	if _, _, err := Encrypt(alice, hdr, many, []byte("x")); !errors.Is(err, ErrRecipients) {
		t.Fatalf("too many recipients: err = %v", err)
	}
	if _, _, err := Encrypt(alice, hdr, self, make([]byte, MaxEnvelopeSize)); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("oversize: err = %v", err)
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	alice := mustKeys(t)
	aliceID := mustID(t)
	hdr := Header{ConvID: mustID(t), SenderAccount: aliceID, SenderDevice: mustID(t), ClientMsgID: mustID(t)}
	env, _, err := Encrypt(alice, hdr, []Recipient{{Account: aliceID, EncPub: alice.EncPub}}, []byte("payload"))
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string][]byte{
		"empty":      {},
		"truncated":  env[:len(env)-1],
		"extended":   append(append([]byte(nil), env...), 0),
		"short":      env[:minEnvelopeSize-1],
		"version":    append([]byte{2}, env[1:]...),
		"zero recip": append(append([]byte(nil), env[:74]...), append([]byte{0, 0}, env[76:]...)...),
		"too large":  make([]byte, MaxEnvelopeSize+1),
	}
	for name, b := range cases {
		if _, err := Parse(b); err == nil {
			t.Errorf("%s: expected parse error", name)
		}
	}
}

func TestFingerprintFormat(t *testing.T) {
	k := mustKeys(t)
	fp := Fingerprint(k.SignPub, k.EncPub)
	if len(fp) != 32+7 {
		t.Fatalf("fingerprint %q has wrong length", fp)
	}
	if fp != Fingerprint(k.SignPub, k.EncPub) {
		t.Fatal("fingerprint not deterministic")
	}
	other := mustKeys(t)
	if fp == Fingerprint(other.SignPub, other.EncPub) {
		t.Fatal("fingerprint collision")
	}
}
