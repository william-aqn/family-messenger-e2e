// Package e2e implements the messenger end-to-end encryption protocol v1
// (see protocol/PROTOCOL.md). It is the reference implementation: the web
// (TypeScript) and mobile (Dart) clients must produce byte-identical results
// for the shared test vectors in protocol/testvectors.
package e2e

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"strings"
)

// ID is a 16-byte identifier (UUID bytes) used for accounts, devices,
// conversations and messages.
type ID [16]byte

// ErrInvalidID is returned by ParseID for malformed input.
var ErrInvalidID = errors.New("e2e: invalid id")

// NewID returns a random ID with UUID version 4 bits set.
func NewID() (ID, error) {
	var id ID
	if _, err := rand.Read(id[:]); err != nil {
		return ID{}, err
	}
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	return id, nil
}

// String formats the ID as a lowercase UUID (8-4-4-4-12).
func (id ID) String() string {
	h := hex.EncodeToString(id[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// IsZero reports whether the ID is all zeros.
func (id ID) IsZero() bool { return id == ID{} }

// ParseID parses a UUID string, with or without dashes, case-insensitively.
func ParseID(s string) (ID, error) {
	s = strings.ReplaceAll(s, "-", "")
	var id ID
	if len(s) != 32 {
		return id, ErrInvalidID
	}
	if _, err := hex.Decode(id[:], []byte(s)); err != nil {
		return ID{}, ErrInvalidID
	}
	return id, nil
}

// MarshalText implements encoding.TextMarshaler (UUID string form).
func (id ID) MarshalText() ([]byte, error) { return []byte(id.String()), nil }

// UnmarshalText implements encoding.TextUnmarshaler.
func (id *ID) UnmarshalText(b []byte) error {
	p, err := ParseID(string(b))
	if err != nil {
		return err
	}
	*id = p
	return nil
}
