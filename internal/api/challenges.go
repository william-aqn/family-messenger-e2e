package api

// A password change proves possession of the account's signing key rather
// than knowledge of the old password (PROTOCOL.md §3.2): the server hands out
// a random challenge, the client signs it together with the new password
// material, and the server verifies the signature under the account's stored
// sign_pub. The pending challenges live here.
//
// They are kept in memory, one per device, single use and short lived. A
// restart forgets them, which costs a client one extra round trip; the server
// is a single process, so there is nothing to share.

import (
	"crypto/rand"
	"sync"
	"time"
)

// challengeSize is the number of random bytes a challenge carries.
const challengeSize = 32

// challengeTTL is how long a challenge stays usable.
const challengeTTL = 5 * time.Minute

// maxChallenges bounds the map; above it, expired entries are swept.
const maxChallenges = 10000

type pendingChallenge struct {
	value   [challengeSize]byte
	expires time.Time
}

// challengeStore holds at most one pending challenge per device.
type challengeStore struct {
	mu       sync.Mutex
	ttl      time.Duration
	byDevice map[string]pendingChallenge
}

func newChallengeStore(ttl time.Duration) *challengeStore {
	return &challengeStore{ttl: ttl, byDevice: make(map[string]pendingChallenge)}
}

// issue creates a fresh challenge for a device, replacing any pending one.
func (c *challengeStore) issue(deviceID string) ([challengeSize]byte, time.Time, error) {
	var value [challengeSize]byte
	if _, err := rand.Read(value[:]); err != nil {
		return value, time.Time{}, err
	}
	now := time.Now()
	expires := now.Add(c.ttl)
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.byDevice) > maxChallenges {
		for id, p := range c.byDevice {
			if now.After(p.expires) {
				delete(c.byDevice, id)
			}
		}
	}
	c.byDevice[deviceID] = pendingChallenge{value: value, expires: expires}
	return value, expires, nil
}

// take reports whether value is the device's pending, unexpired challenge and
// consumes it when it is. A challenge that matched is gone even if the
// signature that came with it turns out to be wrong: one challenge allows one
// attempt, and clients ask for a fresh one per attempt anyway.
func (c *challengeStore) take(deviceID string, value []byte) bool {
	if len(value) != challengeSize {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	p, ok := c.byDevice[deviceID]
	if !ok {
		return false
	}
	if time.Now().After(p.expires) {
		delete(c.byDevice, deviceID)
		return false
	}
	// A wrong guess must not consume the pending challenge, so compare first.
	// Guessing 32 random bytes is hopeless; this only keeps a racing retry
	// from destroying a challenge the device is about to use.
	var got [challengeSize]byte
	copy(got[:], value)
	if got != p.value {
		return false
	}
	delete(c.byDevice, deviceID)
	return true
}

// forget drops a device's pending challenge (used when the device goes away).
func (c *challengeStore) forget(deviceID string) {
	c.mu.Lock()
	delete(c.byDevice, deviceID)
	c.mu.Unlock()
}
