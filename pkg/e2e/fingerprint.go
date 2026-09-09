package e2e

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// Fingerprint returns the safety number of an account's public keys:
// the first 16 bytes of SHA-256("msgr-fp-v1" || sign_pub || enc_pub) as
// lowercase hex in 8 groups of 4 characters (PROTOCOL.md §3.3).
func Fingerprint(signPub, encPub [32]byte) string {
	h := sha256.New()
	h.Write([]byte("msgr-fp-v1"))
	h.Write(signPub[:])
	h.Write(encPub[:])
	hx := hex.EncodeToString(h.Sum(nil)[:16])
	groups := make([]string, 0, 8)
	for i := 0; i < len(hx); i += 4 {
		groups = append(groups, hx[i:i+4])
	}
	return strings.Join(groups, " ")
}
