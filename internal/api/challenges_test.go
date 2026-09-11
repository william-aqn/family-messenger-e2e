package api

import (
	"testing"
	"time"
)

func TestChallengeStore(t *testing.T) {
	c := newChallengeStore(time.Minute)

	v, expires, err := c.issue("device-a")
	if err != nil {
		t.Fatal(err)
	}
	if expires.Before(time.Now()) {
		t.Fatal("a fresh challenge is already expired")
	}
	if v == ([challengeSize]byte{}) {
		t.Fatal("challenge is all zeros")
	}

	// A wrong guess must not consume the pending challenge: a racing retry
	// would otherwise destroy a challenge the device is about to use.
	wrong := v
	wrong[0] ^= 1
	if c.take("device-a", wrong[:]) {
		t.Fatal("a wrong challenge was accepted")
	}
	if !c.take("device-a", v[:]) {
		t.Fatal("the pending challenge was not accepted after a wrong guess")
	}
	// Single use.
	if c.take("device-a", v[:]) {
		t.Fatal("a challenge was accepted twice")
	}

	// Challenges belong to one device only.
	a, _, err := c.issue("device-a")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := c.issue("device-b"); err != nil {
		t.Fatal(err)
	}
	if c.take("device-b", a[:]) {
		t.Fatal("device B used device A's challenge")
	}
	if !c.take("device-a", a[:]) {
		t.Fatal("device A's own challenge stopped working")
	}

	// Issuing again replaces the pending one.
	first, _, err := c.issue("device-c")
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := c.issue("device-c")
	if err != nil {
		t.Fatal(err)
	}
	if c.take("device-c", first[:]) {
		t.Fatal("a replaced challenge was still accepted")
	}
	if !c.take("device-c", second[:]) {
		t.Fatal("the newest challenge was rejected")
	}

	// Expiry.
	short := newChallengeStore(time.Nanosecond)
	e, _, err := short.issue("device-d")
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond)
	if short.take("device-d", e[:]) {
		t.Fatal("an expired challenge was accepted")
	}

	// forget drops the pending challenge of a device that went away.
	f, _, err := c.issue("device-e")
	if err != nil {
		t.Fatal(err)
	}
	c.forget("device-e")
	if c.take("device-e", f[:]) {
		t.Fatal("a forgotten challenge was still accepted")
	}
	if c.take("device-e", make([]byte, 3)) {
		t.Fatal("a short value was accepted")
	}
}
